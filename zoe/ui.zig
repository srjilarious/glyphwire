// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: GPL-3.0-or-later

//! zoe's glyphwire client: four panes in a split tree, the render pass
//! that fills them, and the input loop that drives the editor.
//!
//! The layout is a `column` split holding a `row` split (the tree beside
//! a column of tab strip over buffer) above a one-row statusline. The
//! host owns it: zoe describes it once at startup, and after that a
//! divider drag or a window resize arrives as a `layout` notification
//! saying where each pane ended up, and that notification is the *only*
//! thing zoe takes pane geometry from. A resize also brings a `resize`,
//! which zoe repaints on but reads nothing from -- asking the server
//! where a pane is cannot answer that after a pane has grown, since
//! `get_property`'s viewport is clamped to the layer's own grid. See the
//! `.resize` arm of `handleEvent`.
//!
//! **Every open buffer is a `Slot`**, and the tab strip lists them. A
//! slot holds its own editor, scroll position, redraw bookkeeping and
//! parse tree, so switching tabs is a pointer swap (`setActive`) and one
//! repaint -- nothing is re-read or re-parsed. See decisions.md's "zoe
//! multiple buffers"; the strip's own geometry is `zoe/tabs.zig`.
//!
//! **The two panes scroll differently, on purpose.** The tree is a layer
//! whose *content* is the whole listing -- every entry, at its full width
//! -- shown through a viewport the size of the pane. The host scrolls it
//! and draws its scrollbars, and zoe only rewrites it when the tree
//! itself changes (an expand or collapse), never on a scroll tick -- and
//! moving the cursor in it is two `set_bg`s rather than a rewrite either
//! (`TreeDirty`).
//!
//! The buffer pane can't work that way: a 100k-line file as a cell grid
//! is hundreds of megabytes. So its content grid is exactly pane-sized, zoe
//! owns `top_line`/`left_col`, and it repaints the visible rows -- but on
//! a pure scroll of less than a screen it shifts the rows it already drew
//! with one `move_content` and repaints only the exposed band
//! (`planBufferRender`), rather than rewriting the whole pane every tick.
//!
//! **The caret is drawn by two parties.** Insert mode uses the host's own
//! caret as a thin bar on the buffer layer (`set_caret_shape`), the way
//! nvim does; every other mode is zoe's inverted cell, which keeps the
//! character under it readable, and the host's caret is hidden. See
//! `syncCaret`. Ctrl+` opens a `gw-shell` panel docked along an edge of
//! the window or floating in the middle (`shell_position`, `:shell`;
//! `applib/shellpanel.zig`) that takes the keyboard and the caret until
//! it is closed or clicked away from: a click on the panes gives them back
//! while the panel stays up, and a click on the panel (or Ctrl+` again)
//! returns them to the shell.

const std = @import("std");
const glyphwire = @import("glyphwire");
const ls_icons = @import("applib").icons;

const editor = @import("editor.zig");
const motion = @import("motion.zig");
const diskwatch = @import("diskwatch.zig");
const inotify_mod = @import("inotify.zig");
const display = @import("display.zig");
const softwrap = @import("wrap.zig");
const search = @import("search.zig");
const tree_mod = @import("tree.zig");
const finder_mod = @import("applib").finder;
const finderpopup = @import("applib").finderpopup;
const palette_mod = @import("applib").palette;
const filetype = @import("applib").filetype;
const homepath = @import("applib").homepath;
const syntax = @import("applib").syntax;
const themes = @import("applib").theme;
pub const role = glyphwire.Color.role;
const langconf = @import("langconf.zig");
const actions = @import("actions.zig");
const ext = @import("ext.zig");
const tabs = @import("tabs.zig");
const groups = @import("groups.zig");
const lsp = @import("lsp.zig");
const zoe_workspace = @import("workspace.zig");
const hangup = @import("hangup.zig");
const profile = @import("profile.zig");
const SpanCache = @import("spancache.zig").SpanCache;
const selection_diff = @import("selection_diff.zig");
const diag = @import("diag.zig");
const hover_mod = @import("hover.zig");
const complete = @import("complete.zig");
const cmdhistory = @import("cmdhistory.zig");
const pathmenu = @import("pathmenu.zig");
const pathcomplete = @import("applib").pathcomplete;
const fsops = @import("applib").fsops;
const buffer_mod = @import("buffer.zig");
const shellpanel = @import("applib").shellpanel;

const Editor = editor.Editor;
pub const Tree = tree_mod.Tree;
const Finder = finder_mod.Finder;
const lineedit = @import("applib").lineedit;
const treepane = @import("treepane.zig");
const lspglue = @import("lspglue.zig");
const completionui = @import("completionui.zig");
const cmdline = @import("cmdline.zig");
const render_ui = @import("render.zig");
pub const Color = glyphwire.Color;

/// Cells the tree pane occupies until a divider drag says otherwise.
const default_tree_cols: usize = 28;

/// The most editor groups the directional search looks at. Far more
/// than fit on a screen; past it, Ctrl+hjkl just can't reach the extras.
const max_groups: usize = 32;

/// Blank rows the tree's content grid keeps below the last entry.
///
/// One, and it exists for the horizontal scrollbar: the host draws that
/// bar *over* the bottom row of the pane, so a listing that ends exactly
/// at the viewport's last row has its final entry sitting under the bar
/// and unreadable, with nothing to scroll to that would move it. A
/// trailing blank row is what the bar covers instead.
pub const tree_trailing_rows: usize = 1;

/// Rows the tree keeps between its cursor and either edge of the pane --
/// vim's `scrolloff`, for the sidebar.
///
/// Three, and the bottom edge is the reason. The host draws the
/// horizontal scrollbar over the pane's last row, so a cursor that is
/// merely *on screen* can be highlighted and unreadable at the same time.
/// A margin also means you can see what you are about to move onto rather
/// than scrolling one row at a time against the edge. See
/// `scrollTreeToCursor`, which caps it in a short pane and lets the end
/// of the listing override it.
pub const tree_scroll_margin: usize = 3;

/// The most zoe will read into a buffer. Every open buffer holds its
/// text for as long as it is open, so this is also the per-tab ceiling.
const max_file_bytes: usize = 64 * 1024 * 1024;

/// How long a whole-buffer parse may hold up the frame that needs it
/// before zoe draws a highlighted prefix instead and finishes the parse
/// in the background (`Highlighter.beginParse`). Files that parse inside
/// it -- most of them -- are drawn once, fully coloured.
pub const first_parse_budget_ms: i64 = 8;

/// One slice of a background parse, run between events: short enough
/// that a key typed meanwhile waits no longer than this.
pub const parse_slice_ms: i64 = 10;

// The colours are theme role references (`role(.bg)`, `role(.keyword)`)
// the host resolves against this context's theme -- the window's, or the
// one `zoe.conf.lua` names (`Ui.th`) -- so a switch recolours everything
// already drawn. Every pane still paints its own background, because a
// cell with no background shows whatever is under the context.

/// The Ctrl+P finder popup's look (`applib/finderpopup.zig`, shared with
/// salacommander's F3): the theme's panel nine-patch and a drop shadow,
/// with the theme's text colours.
fn finderStyle(th: *const themes.Stored) finderpopup.Style {
    return .{
        .frame_style = th.panelStyle(),
        .bg = role(.popup_bg),
        .header_bg = role(.finder_header_bg),
        .header_fg = role(.finder_header_fg),
        .selected_bg = role(.finder_selected_bg),
        .selected_fg = role(.finder_selected_fg),
        .text_fg = role(.fg),
        .dim_fg = role(.fg_dim),
        .max_cols = 84,
        .max_rows = 20,
    };
}

/// The Ctrl+Shift+P command palette's look: the finder's colours, in the
/// palette's top-anchored shape (`applib/palette.zig`).
fn paletteStyle(th: *const themes.Stored) palette_mod.Style {
    var s = palette_mod.default_style;
    const f = finderStyle(th);
    s.frame_style = f.frame_style;
    s.bg = f.bg;
    s.selected_bg = f.selected_bg;
    s.selected_fg = f.selected_fg;
    s.text_fg = f.text_fg;
    s.dim_fg = f.dim_fg;
    return s;
}

/// The sign-column glyph. Solid for an error, hollow for everything else,
/// so severity still reads on a display where the colours are hard to tell
/// apart -- and both are one cell wide in every font, which a fancier
/// symbol from a Nerd Font range would not be.
pub const sign_error = "\u{25cf}"; // ●
pub const sign_other = "\u{25cb}"; // ○

/// The hover popup's size limits, clamped to the pane like the finder's.
pub const hover_max_cols: usize = 76;
pub const hover_max_rows: usize = 14;
// The popup's background and border are the theme's `panel_style`
// nine-patch, the one the finder's frame uses; `bg_popup` is the flat
// fallback for a host without it.

/// The rows the popup's drop shadow (`glyphwire.Shadow.dialog`, drawn by
/// the host) reaches below it: `hoverRect` keeps that row clear of the line
/// being described when the popup goes above the cursor.
pub const hover_shadow_rows: usize = 1;

/// The tab tooltip (a hovered tab's full path, `zoe/tabs.zig`): the hover
/// popup's panel and text colour, so the two read as the same kind of
/// thing. Its layer is created with room for this many columns and
/// resized to fit each path.
const tab_tip_initial_cols: usize = 40;

/// The completion popup. Narrower and shorter than the hover: it sits under
/// the line being typed, and every row of it covers code.
pub const complete_max_cols: usize = 60;
pub const complete_max_rows: usize = 10;
/// The kind column (`fn`, `var`, `struct`), padded to this width.
pub const complete_kind_cols: usize = 6;

/// How long typing has to pause before an identifier being typed asks for
/// completions. A trigger character (`.`) doesn't wait. Short enough that
/// the popup is there by the time you look for it; long enough that a word
/// typed at speed is one request, not one per letter.
pub const complete_auto_delay_ms: u64 = 80;

/// How long after the last edit a `didChange` goes out. Long enough that a
/// burst of typing is one message and a server isn't re-analysing the file
/// on every keystroke; short enough that pausing to look at the screen
/// gets you current diagnostics. 150ms is roughly where every editor with
/// this knob has landed.
pub const lsp_change_debounce_ms: u64 = 150;

/// Entries the jumplist keeps. vim's default is 100; there is no reason to
/// differ, and a bounded list is what keeps `gd` from being a memory leak
/// in a long session.
const max_jumps: usize = 100;

/// One place the cursor was before a jump, for Ctrl+O / Ctrl+I. The path is
/// owned; a scratch buffer with no path can't be returned to and is not
/// recorded.
const Jump = struct {
    path: []const u8,
    offset: usize,
};

/// The jumplist: where `gd` came from, so Ctrl+O gets you back.
///
/// zoe had none before LSP, which was fine while nothing moved the cursor
/// somewhere it hadn't been asked to -- and stops being fine the moment
/// `gd` can open another file. vim's model: a stack with a cursor into it,
/// where Ctrl+O steps back through what you left and Ctrl+I returns, and a
/// fresh jump truncates whatever Ctrl+O had walked past.
const JumpList = struct {
    entries: std.ArrayList(Jump) = .empty,
    /// How far back Ctrl+O has walked; 0 is "at the newest entry".
    back: usize = 0,

    fn deinit(self: *JumpList, alloc: std.mem.Allocator) void {
        for (self.entries.items) |e| alloc.free(e.path);
        self.entries.deinit(alloc);
    }

    /// Records where a jump is leaving from. A new jump discards anything
    /// Ctrl+O had stepped back past, the way vim's does -- the branch you
    /// walked back through is not a place forward navigation should return
    /// to.
    fn push(self: *JumpList, alloc: std.mem.Allocator, path: []const u8, offset: usize) !void {
        while (self.back > 0) {
            const dropped = self.entries.pop() orelse break;
            alloc.free(dropped.path);
            self.back -= 1;
        }
        try self.entries.append(alloc, .{ .path = try alloc.dupe(u8, path), .offset = offset });
        if (self.entries.items.len > max_jumps) {
            const oldest = self.entries.orderedRemove(0);
            alloc.free(oldest.path);
        }
    }

    /// The entry Ctrl+O should go to, or null at the end of the list.
    fn stepBack(self: *JumpList) ?Jump {
        if (self.back >= self.entries.items.len) return null;
        self.back += 1;
        return self.entries.items[self.entries.items.len - self.back];
    }

    /// The entry Ctrl+I should return to.
    fn stepForward(self: *JumpList) ?Jump {
        if (self.back == 0) return null;
        self.back -= 1;
        if (self.back == 0) return null;
        return self.entries.items[self.entries.items.len - self.back];
    }
};

/// An open hover popup: the reply cut into prose, rules and code lines
/// (`zoe/hover.zig`), with each code line's syntax colours worked out once
/// when the reply lands rather than on every redraw. `scroll` is the first
/// wrapped row shown, since a hover on a documented function easily runs
/// past the popup.
const Hover = struct {
    doc: hover_mod.Doc,
    /// One entry per `doc.lines`: the colour spans of a code line, empty for
    /// anything else (or for a block whose language has no grammar). In the
    /// doc's arena, so `doc.deinit` frees them.
    spans: []const []const syntax.Span,
    scroll: usize = 0,

    pub fn deinit(self: *Hover) void {
        self.doc.deinit();
    }
};

/// A pane's bounds, mirrored from the last `layout` notification.
pub const Bounds = struct {
    row: usize = 0,
    col: usize = 0,
    cols: usize = 0,
    rows: usize = 0,
};

const Focus = enum { buffer, tree };

/// How much of the tree pane the next frame owes, lowest first --
/// `markTreeDirty` only ever raises it, so a full repaint already owed
/// survives however many cursor moves land on top of it.
///
/// The `selection` level is the whole point: the tree layer holds the
/// *entire* listing (the host scrolls a viewport over it), so a cursor
/// move changes nothing but which row is highlighted. That is two
/// `set_bg`s, which leave the text and the per-entry icons already on the
/// layer exactly where they are -- see `renderTreeSelection`.
pub const TreeDirty = enum(u2) {
    none,
    selection,
    full,
};

/// The sidebar's in-place name field: `a` / Shift+F4 and F7 make an
/// entry, `r` / F2 rename one. While it is up it owns the keyboard the
/// way a tree search does, Enter commits and Escape abandons it.
///
/// A rename edits the entry's own row. A create has no row yet, so the
/// pane draws a virtual one at the top of the directory it will land in
/// (`row`), pushing the rows below it down one; `treeRowEntry` is the
/// mapping. Nothing in `Tree` knows about it -- the entry only exists
/// once the create has happened and the tree is re-read.
pub const TreeEdit = struct {
    kind: Kind,
    field: lineedit.LineEdit = .{},
    /// The directory the entry is made in or renamed within. Owned.
    dir: []u8,
    /// A rename's current name. Owned; empty for a create.
    old_name: []u8,
    /// The pane row the field is drawn on.
    row: usize,
    /// Its nesting, for the indent.
    depth: usize,
    /// Why the last Enter didn't take (a name that exists, one with a `/`
    /// in a rename), shown on the statusline with the field kept open for
    /// another try -- salacommander's F2 does the same. Static text.
    err: ?[]const u8 = null,

    pub const Kind = enum {
        /// `a` / Shift+F4: a file, or a directory when the name ends in
        /// `/`. Missing parents along the way are made too.
        create,
        /// F7: a directory, slash or not.
        create_dir,
        rename,
    };

    pub fn deinit(self: *TreeEdit, alloc: std.mem.Allocator) void {
        self.field.deinit(alloc);
        alloc.free(self.dir);
        alloc.free(self.old_name);
    }

    /// Whether the field is a virtual row spliced into the listing.
    pub fn inserts(self: *const TreeEdit) bool {
        return self.kind != .rename;
    }
};

/// Which set of names a tree-pane search is walking.
///
/// The two scopes answer different questions, which is why the trigger
/// key picks one rather than the search widening on its own: `f` is "find
/// something I can already see", `/` is "find it anywhere under the root,
/// and open whatever folders that takes".
pub const FindScope = enum {
    /// `f`: the flattened listing -- exactly the rows on screen.
    visible,
    /// `/`: every path under the tree root, collapsed folders included.
    deep,
};

/// An in-progress tree-pane search. Prefix-matched against entry names,
/// case-insensitively, with Tab stepping through the candidates -- the
/// same shape as salacommander's type-to-find, and deliberately not the
/// fuzzy ranking Ctrl+P uses: a prefix says exactly where the cursor will
/// land, which is what makes Tab predictable.
pub const TreeFind = struct {
    scope: FindScope,
    /// What has been typed, owned. Only characters that keep at least one
    /// candidate are kept, so the query always describes where the cursor
    /// is (`typeToFind` in salacommander does the same).
    query: std.ArrayList(u8) = .empty,
    /// `.deep` only: the whole-tree listing, read when the search started.
    deep: ?tree_mod.DeepList = null,
    /// The current candidates -- entry indices for `.visible`, `deep`
    /// path indices for `.deep` -- and which one the cursor is on.
    hits: std.ArrayList(usize) = .empty,
    pick: usize = 0,
    /// `.visible` only: the row the cursor was on when the search
    /// started. Candidates are ordered forward from here, so "the next
    /// match" means the next one after where you were -- and stays
    /// meaning that as the prefix grows, rather than re-anchoring on
    /// whatever the last keystroke found.
    anchor: usize = 0,

    pub fn deinit(self: *TreeFind, alloc: std.mem.Allocator) void {
        self.query.deinit(alloc);
        self.hits.deinit(alloc);
        if (self.deep) |*d| d.deinit();
        self.* = undefined;
    }
};

/// What zoe's command line named, once `main` has looked at it on disk.
/// The distinction is the whole reason it looks: `zoe build.zig` opens a
/// buffer, but `zoe src/` is a place to work -- there is nothing to read
/// out of a directory, and treating it as a file used to leave you in an
/// empty buffer named after it that `:w` would then refuse.
pub const FileTarget = struct {
    path: []const u8,
    /// 1-based line to start the cursor on (`zoe --line N`), or
    /// null for the top.
    line: ?usize = null,
};

pub const Target = union(enum) {
    /// No argument: an empty scratch buffer, tree on the cwd.
    none,
    /// A file to open -- or a name that doesn't exist yet, which is how
    /// `zoe newfile.txt` creates one.
    file: FileTarget,
    /// A directory. `main` has already changed into it, so it *is* the
    /// cwd by the time the UI starts and there is nothing left to carry
    /// here: the tree roots on it like any other cwd, and the buffer
    /// starts empty.
    directory,
    /// Several folders (`zoe a b`, `zoe x.code-workspace`). Like
    /// `directory` -- `main` has changed into the first one, the buffer
    /// starts empty and the focus on the tree -- with the folders
    /// themselves passed to `Ui.init` separately.
    workspace,
};

/// A drop-target highlight and the layer it is on.
const DropShown = struct {
    layer: glyphwire.LayerHandle,
    target: glyphwire.DropTarget,
};

/// What a `.zoe-workspace` on the command line adds beyond its folders.
/// All borrowed for the length of `Ui.init`.
pub const WorkspaceStart = struct {
    /// The workspace file, absolute: where a bare `:wssave` writes.
    file: ?[]const u8 = null,
    /// The theme to start in, by name, over `zoe.conf.lua`'s and the
    /// window's. One that doesn't resolve is reported and ignored.
    theme: ?[]const u8 = null,
    /// The editor groups and tabs to bring back.
    editors: ?*const zoe_workspace.EditorNode = null,
};

/// Which way a Ctrl+direction chord moves the focus.
pub const Direction = groups.Direction;

/// A key that only modifies others. The host reports each one as a key
/// of its own, under its `left_*` / `right_*` name.
fn isModifierKey(key: []const u8) bool {
    const names = [_][]const u8{ "control", "alt", "shift", "super" };
    for (names) |n| {
        if (std.mem.endsWith(u8, key, n) and
            (std.mem.startsWith(u8, key, "left_") or std.mem.startsWith(u8, key, "right_"))) return true;
    }
    return false;
}

/// The direction a key names under Ctrl, for the focus chords: vim's
/// `hjkl` and the arrow keys both, since the panes are navigated with
/// either. Null for every other key, which is what lets `handleInput`
/// use this as the test for "is this a focus chord at all".
///
/// The vertical pair moves between editor groups stacked by `:split`.
pub fn focusDirection(key: []const u8) ?Direction {
    const eq = std.mem.eql;
    // `h` is deliberately absent: Ctrl+H toggles hidden files, the
    // binding every file manager uses for it, and focusing left is
    // already Ctrl+Left and Ctrl+W. `l` stays -- nothing wants Ctrl+L.
    if (eq(u8, key, "left")) return .left;
    if (eq(u8, key, "l") or eq(u8, key, "right")) return .right;
    if (eq(u8, key, "k") or eq(u8, key, "up")) return .up;
    if (eq(u8, key, "j") or eq(u8, key, "down")) return .down;
    return null;
}

/// The slice of editor state the buffer pane draws from. `handleInput`
/// takes one before dispatching a keystroke and one after; if they match,
/// the buffer pane is untouched and `render` can skip it -- which is what
/// keeps a `:` line keystroke from triggering a full syntax repaint.
const EdSnapshot = struct {
    cursor: usize,
    edits: u64,
    line_numbers: editor.LineNumbers,
    /// The display settings `:set` can change mid-session. Only
    /// `tab_width` and `show_whitespace` move a glyph, but `expand_tab` rides
    /// along so the `:set` propagation below has one place to look.
    tab_width: usize,
    expand_tab: bool,
    show_whitespace: bool,
    wrap: bool,
    auto_indent: bool,
    auto_close: bool,
    fold_column: bool,
    /// `Buffer.folds_gen`: a fold opening or closing redraws the pane
    /// without the cursor or the text having moved.
    folds_gen: u64,
    /// The mode and selection anchor so a bare `v` / `V` / `<esc>` / `o`
    /// -- which can change the highlighted range without moving the
    /// cursor -- still repaints the buffer pane.
    mode: editor.Mode,
    anchor: ?usize,
    /// The search highlight, as a digest of the pattern plus where the
    /// current match is. Like the selection it covers whole rows the
    /// caret never touches, so it has to force a repaint of its own --
    /// and a *digest* rather than the pattern itself because the snapshot
    /// outlives the frame, while the `ArrayList` behind the pattern can
    /// reallocate under it.
    match_hash: u64,
    match: ?usize,
    /// The modified flag, which the tab strip shows as a `+`. Left out of
    /// `eql` -- it only ever moves together with `edits`, and it is
    /// compared on its own so a keystroke that dirties the buffer
    /// redraws the strip.
    dirty: bool,

    fn of(ed: *const Editor) EdSnapshot {
        return .{
            .cursor = ed.cursor,
            .edits = ed.buf.edits,
            .line_numbers = ed.line_numbers,
            .tab_width = ed.tab_width,
            .expand_tab = ed.expand_tab,
            .show_whitespace = ed.show_whitespace,
            .wrap = ed.wrap,
            .auto_indent = ed.auto_indent,
            .auto_close = ed.auto_close,
            .fold_column = ed.fold_column,
            .folds_gen = ed.buf.folds_gen,
            .mode = ed.mode,
            .anchor = ed.select_anchor,
            .match_hash = matchHash(ed),
            .match = ed.search_match,
            .dirty = ed.buf.dirty,
        };
    }
    fn eql(a: EdSnapshot, b: EdSnapshot) bool {
        return a.cursor == b.cursor and a.edits == b.edits and
            a.line_numbers == b.line_numbers and a.mode == b.mode and a.anchor == b.anchor and
            a.match_hash == b.match_hash and a.match == b.match and
            a.tab_width == b.tab_width and a.expand_tab == b.expand_tab and
            a.show_whitespace == b.show_whitespace and a.wrap == b.wrap and
            a.auto_indent == b.auto_indent and a.auto_close == b.auto_close and
            a.fold_column == b.fold_column and a.folds_gen == b.folds_gen;
    }

    /// Zero when nothing is highlighted, otherwise a hash of the pattern
    /// and the one option that isn't derived from it.
    fn matchHash(ed: *const Editor) u64 {
        const pat = ed.highlightPattern() orelse return 0;
        var h = std.hash.Wyhash.init(@intFromBool(ed.highlightOpts().whole_word));
        h.update(pat);
        return h.final();
    }
};

/// One open buffer: its editor, plus everything about *how it is being
/// looked at* -- the scroll position, the between-frame bookkeeping the
/// buffer pane's incremental redraw keeps, and its own syntax tree.
///
/// All of it is per buffer, deliberately: switching tabs is then a
/// pointer swap and a repaint, never a re-read or a reparse, which is
/// what makes it feel instant on a big file. The cost is that every open
/// buffer holds its text and its tree-sitter tree for as long as it is
/// open -- see decisions.md's "zoe multiple buffers".
pub const Slot = struct {
    ed: Editor,

    /// First buffer line and display column shown in the buffer pane --
    /// zoe's own scroll position, since that pane isn't host-scrolled.
    top_line: usize = 0,
    left_col: usize = 0,
    /// With `wrap` on, which of `top_line`'s screen rows is the pane's
    /// first -- a long line can be scrolled part-way past. Always zero
    /// unwrapped, where `left_col` does the sideways job instead.
    top_sub: usize = 0,
    prev_top_sub: usize = 0,
    /// A digest of which (line, row-of-line) each screen row showed last
    /// frame. With `wrap` on, an edit that changes how many rows a line
    /// takes moves every row below it, which the localised repaint can't
    /// express; a changed digest sends it down the full path instead.
    prev_row_hash: u64 = 0,
    /// `Buffer.folds_gen` when the layer was last drawn. A fold opening
    /// or closing moves every row below it, so a change forces a full
    /// repaint.
    prev_folds_gen: u64 = 0,
    /// The scroll position and edit count the buffer layer's cells
    /// currently reflect. `renderBuffer` diffs against these to shift the
    /// rows it already drew (`move_content`) on a pure scroll instead of
    /// rewriting every visible row.
    prev_top_line: usize = 0,
    prev_left_col: usize = 0,
    prev_cursor_line: usize = 0,
    prev_edits: u64 = 0,
    /// The selection the buffer pane's cells currently show, so
    /// `renderBuffer` can repaint just the rows a changed selection
    /// covers differently -- including clearing it when it goes away.
    prev_sel: ?editor.Editor.SelSpan = null,
    /// Forces a full buffer repaint next frame -- set whenever the pane's
    /// bounds change or its content is replaced wholesale, cases a row
    /// shift can't express. True on a fresh slot, and on every switch
    /// *to* a slot: the layer's cells belong to whichever buffer drew
    /// last.
    full_redraw: bool = true,
    /// The `(content rows, content cols, scroll row, scroll col)` last
    /// pushed to the buffer layer for its host-drawn scrollbar. Re-pushed
    /// only when one of them changes -- see `syncBufferScrollbar`.
    pushed_bar: [4]usize = .{ std.math.maxInt(usize), 0, 0, 0 },

    /// This buffer's own tree-sitter state -- null when highlighting is
    /// off entirely, or when no grammar matched its extension. Per slot
    /// so a tab switch doesn't throw a parse tree away.
    hl: ?syntax.Highlighter = null,
    /// The `Buffer.edits` value `hl`'s tree reflects; a mismatch in
    /// `renderBuffer` triggers a reparse.
    hl_edits: u64 = 0,
    /// `hl`'s spans for the lines painted so far, kept in step with the
    /// buffer by `syncHighlight` and filled per frame by `fillSpanCache`.
    spans: SpanCache = .{},

    /// The `Buffer.edits` value the language servers have been told about.
    /// A mismatch arms the `didChange` debounce -- deliberately a separate
    /// watermark from `hl_edits` rather than a second consumer of
    /// `Buffer.pending_edits`, which the highlighter drains alone.
    lsp_sent_edits: u64 = 0,
    /// The LSP document version to send next. Monotonic per buffer, as the
    /// protocol requires; a server uses it to discard a stale reply.
    lsp_version: i64 = 1,
    /// Whether `didOpen` has been sent for this buffer. A scratch buffer
    /// with no path never is, and neither is one whose extension no
    /// configured server claims.
    lsp_opened: bool = false,
    /// `ed.path` resolved to an absolute path, owned, filled on first use
    /// (`Ui.slotAbs`). The diagnostic store is keyed by absolute path, and
    /// the sign column asks it a question per visible row per frame --
    /// resolving the cwd that many times a frame is the kind of cost that
    /// only shows up as the editor feeling slightly heavy. Invalidated by
    /// whatever changes `ed.path`.
    abs_path: ?[]u8 = null,

    /// The file's size and mtime as of zoe's last read or write of it --
    /// what `Ui.checkDisk` compares against to notice a change made
    /// outside zoe. Null for a scratch buffer, or a `[New]` one until its
    /// first `:w`. `disk_warned` is the changed stamp already reported
    /// for a modified buffer, so it is reported once, not every poll.
    disk: ?diskwatch.Stamp = null,
    disk_warned: ?diskwatch.Stamp = null,
    /// The file was on disk and the last check found it gone
    /// (`diskwatch.gone`): its tab carries `tabs.gone_mark`. Cleared when
    /// it comes back or a `:w` writes it again.
    gone: bool = false,

    pub fn deinit(self: *Slot, alloc: std.mem.Allocator) void {
        if (self.hl) |*h| h.deinit();
        self.spans.deinit(alloc);
        if (self.abs_path) |p| alloc.free(p);
        self.ed.deinit();
        alloc.destroy(self);
    }
};

/// One editor group: a tab strip over a buffer pane, with its own list
/// of open buffers. `:vsplit` / `:split` make more; each sits in the
/// layout tree (`zoe/groups.zig`) as one leaf, and in the host's split
/// tree as `col_split`.
///
/// A file is open in at most one group: opening one that is already
/// open elsewhere focuses its tab there (`openFile`). That is what lets
/// a `Slot` -- editor, undo, parse tree, language-server document --
/// stay the one owner of its buffer.
pub const Group = struct {
    id: groups.GroupId,
    tabs_layer: glyphwire.LayerHandle,
    buffer_layer: glyphwire.LayerHandle,
    /// The tab strip stacked over the buffer pane. A column split of its
    /// own so the strip starts where the buffer does -- the file tree
    /// keeps its full height, and hiding the tree widens the strip with
    /// the pane it belongs to. Not resizable: the strip is one row.
    col_split: glyphwire.SplitHandle,

    /// This group's open buffers, in tab order, and the one shown. Heap
    /// slots rather than values in the list: `Ui.buf` points into it,
    /// and a list resize would move values out from under that pointer.
    ///
    /// Never empty -- closing the last buffer either closes the group or
    /// leaves a fresh scratch one (`closeBuffer`), so the strip always
    /// has something to draw.
    buffers: std.ArrayList(*Slot) = .empty,
    active: usize = 0,

    tabs_bounds: Bounds = .{},
    buffer_bounds: Bounds = .{},

    /// The tab strip's horizontal scroll, in strip columns, and the tab
    /// spans the last layout produced (also strip coordinates -- subtract
    /// `tab_scroll` for screen columns). `renderTabs` refills the spans;
    /// a click reads them back through `tabs.hit`.
    tab_scroll: usize = 0,
    tab_spans: std.ArrayList(tabs.Span) = .empty,
    /// The strip's total width, so a scroll can be clamped without
    /// re-running the layout.
    tab_total: usize = 0,
    /// The `(width, scroll)` last pushed to the tabs layer as its content
    /// extent and offset, so a still strip is silent on the wire.
    pushed_tab_bar: [2]usize = .{ std.math.maxInt(usize), 0 },

    buffer_dirty: bool = true,
    tabs_dirty: bool = true,

    pub fn slot(self: *const Group) *Slot {
        return self.buffers.items[self.active];
    }

    /// The group's whole area, strip and pane together, for Ctrl+hjkl.
    pub fn rect(self: *const Group) groups.Rect {
        const t = self.tabs_bounds;
        const b = self.buffer_bounds;
        return .{ .row = t.row, .col = b.col, .cols = b.cols, .rows = t.rows + b.rows };
    }

    pub fn contains(self: *const Group, cell: glyphwire.CellPos) bool {
        const r = self.rect();
        return r.cols > 0 and cell.row >= r.row and cell.row < r.row + r.rows and
            cell.col >= r.col and cell.col < r.col + r.cols;
    }

    pub fn markRedraw(self: *Group) void {
        if (self.buffers.items.len > 0) self.slot().full_redraw = true;
        self.buffer_dirty = true;
        self.tabs_dirty = true;
    }
};

pub const Ui = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    client: *glyphwire.Client,
    listener: *glyphwire.InputListener,
    tree: Tree,

    /// Every editor group, in no particular order (`layout` has the
    /// on-screen arrangement), and the one with the keyboard. Never
    /// empty: closing the last group is refused, and closing its last
    /// tab leaves a scratch buffer instead.
    ///
    /// Everything that acts on "the" buffer pane -- the editing keys, the
    /// render helpers -- reaches it through `grp`. `render` points `grp`
    /// at each dirty group in turn to draw it (`renderGroup`), so the
    /// same helpers paint every group; outside that, `grp` is always the
    /// focused one.
    group_list: std.ArrayList(*Group) = .empty,
    grp: *Group,
    /// The groups' arrangement, mirrored one-for-one in host splits. See
    /// `zoe/groups.zig`.
    layout: groups.Layout,
    next_group_id: groups.GroupId = 1,
    /// False while `renderGroup` is drawing a group that doesn't have the
    /// keyboard, which then gets no caret.
    render_focused: bool = true,
    /// The active buffer of `grp`, always `grp.buffers.items[grp.active]`.
    /// Kept as a pointer because nearly every line of the render and
    /// dispatch paths reaches through it; `setActive`, `focusGroup` and
    /// `renderGroup` are its only writers.
    buf: *Slot,

    /// zoe's own context -- an alt-screen-style full-window surface, not
    /// a set of layers stacked over the shell's scrollback. Everything
    /// below (layers, splits) lives in it, and `destroyContext` on exit
    /// tears the whole thing down and drops visibility back to the shell.
    context: glyphwire.ContextHandle,
    tree_layer: glyphwire.LayerHandle,
    status_layer: glyphwire.LayerHandle,
    pane_split: glyphwire.SplitHandle,
    root_split: glyphwire.SplitHandle,

    tree_bounds: Bounds = .{},
    status_bounds: Bounds = .{},

    /// Session cell height in px, for natural-sizing tree icons to the
    /// row height. Re-read on every `resize`, which a font-size step
    /// always sends.
    cell_px_h: u32 = 0,
    /// The tree pane's scroll offset, mirrored from `scroll_offset`
    /// notifications so a click can be resolved to the right entry.
    tree_scroll: glyphwire.CellPos = .{},
    /// A scroll offset the cursor needs the host to move to, held until
    /// the frame it belongs to goes out. Pushing it straight from
    /// `scrollTreeToCursor` put a notification on the wire *outside* the
    /// render batch, so a held-down `j` interleaved scrolls and repaints
    /// instead of sending one coherent frame per key.
    tree_scroll_pending: ?glyphwire.CellPos = null,
    /// The row `set_bg` last painted as the selected one, and whether it
    /// was painted focused. `renderTreeSelection` needs both to know what
    /// to paint back to the pane colour.
    tree_painted: struct { row: usize = 0, focused: bool = false } = .{},

    /// An in-progress tree-pane search (`f` or `/`), null the rest of the
    /// time. See `TreeFind`.
    find: ?TreeFind = null,
    /// The sidebar's name field, non-null while a create or rename is
    /// being typed. See `TreeEdit`.
    tree_edit: ?TreeEdit = null,
    /// Only the field's row needs repainting (a keystroke in it).
    tree_edit_dirty: bool = false,

    /// An in-progress left-button drag in the buffer pane. `anchor` is
    /// the buffer byte offset the press landed on; `moved` flips true the
    /// first time the pointer changes cell, which is when the drag turns
    /// into a visual selection (a press+release with no move is a plain
    /// click). Null when no button is down over the pane.
    ///
    /// A double-click (`unit = .word`) or triple-click (`.line`) selects
    /// on the press and starts out `moved`, so its release keeps the
    /// selection; dragging on from there grows it a whole word or line
    /// at a time. `word` is the `[start, end)` span the press landed on,
    /// which a word drag always keeps selected.
    drag: ?struct {
        anchor: usize,
        moved: bool,
        unit: enum { char, word, line } = .char,
        word: struct { start: usize, end: usize } = .{ .start = 0, .end = 0 },
    } = null,
    /// A left-button press on a tab, which becomes a tab drag the first
    /// time the pointer leaves the cell it pressed (`moved`). Released
    /// over a tab strip it drops the tab there -- another group's, or its
    /// own to reorder it; over another group's pane, at the end of that
    /// group's tabs. Null when no button is down over a tab.
    tab_drag: ?struct {
        slot: *Slot,
        start: glyphwire.CellPos,
        moved: bool = false,
    } = null,
    /// The drop-target highlight a tab drag is showing (`set_drop_target`):
    /// the slot between two tabs on a strip, or a whole pane. Kept so a
    /// pointer move that stays on the same target sends nothing, and so
    /// the layer showing it can be cleared when the target moves off it.
    drop_shown: ?DropShown = null,

    /// The Ctrl+P file finder popup. Its layers float *outside* the split
    /// tree -- placed over the buffer pane by `render`, hidden the rest of
    /// the time -- which is why no `layout` notification mentions them.
    finder: finderpopup.Popup,
    /// The Ctrl+Shift+P command palette, floating like the finder (over
    /// it: it's created after). Modal while open, the same way.
    palette: palette_mod.Popup,

    /// The language servers, and everything they have said. The pool is
    /// null when `config.lsp.enabled` is false; it exists but holds no
    /// server when none of the configured binaries is installed, which is
    /// the ordinary case on a machine with only one toolchain.
    lsp_pool: ?lsp.Pool = null,
    diags: diag.Store,
    /// Whether a sign column is reserved in the gutter. Decided once at
    /// startup from "did any server actually start", and never changed
    /// after: a gutter that appears the first time a diagnostic arrives
    /// would reflow every line of the pane under the user's cursor.
    signs: bool = false,
    /// A `didChange` waiting on the debounce, with the deadline it goes out
    /// at. `run` shortens its wait to this, which is the only thing that
    /// makes the loop time-bound at all -- see `lsp_change_debounce_ms`.
    lsp_change_due: ?std.Io.Clock.Timestamp = null,
    /// The hover popup, non-null while it is up. One float layer, placed
    /// against the cursor like the finder is against the pane.
    hover: ?Hover = null,
    hover_layer: glyphwire.LayerHandle,
    /// The hover layer's `hover_panel_style` nine-patch, covering the whole
    /// layer; its border lands in the popup's one-cell frame, which is left
    /// transparent. Null when the host has no such style: the layer then
    /// paints `bg_popup` and the popup has no border.
    hover_panel_patch: ?glyphwire.NinePatchHandle,
    hover_rect: Bounds = .{},
    hover_dirty: bool = false,
    /// The newest outstanding `hover` / `definition` request id. A reply
    /// carrying anything else is stale -- the user asked again, or moved on
    /// -- and is dropped rather than popping a popup for a cursor position
    /// that is two jumps old.
    hover_request: ?i64 = null,
    definition_request: ?i64 = null,
    /// The highlighter hover code blocks are coloured with: its own, since a
    /// buffer's is bound to that buffer's text and tree. Built on the first
    /// hover with a fenced block; its language is set per block and cleared
    /// again afterwards.
    hover_hl: ?syntax.Highlighter = null,

    /// The tab tooltip. `tab_tip_index` is the tab the pointer is resting
    /// on (only tabs with a file behind them count) in group
    /// `tab_tip_group`, whether or not its tooltip is up yet; `tab_tip_due` is when it goes up, armed on the
    /// move onto the tab. A keystroke or click takes it down and disarms
    /// it without forgetting the tab, so it stays down until the pointer
    /// moves onto another one.
    tab_tip_layer: glyphwire.LayerHandle,
    /// The layer's `hover_panel_style` nine-patch, as for the hover popup;
    /// null draws it flat in `bg_popup`.
    tab_tip_patch: ?glyphwire.NinePatchHandle,
    tab_tip_index: ?usize = null,
    tab_tip_group: ?*Group = null,
    tab_tip_due: ?std.Io.Clock.Timestamp = null,
    /// When the open files are next stat'ed for outside changes (see
    /// `checkDisk`). Under `file_watch = "poll"` always armed, the one
    /// timer that runs with nothing else going on; under `"inotify"`
    /// armed `settle_ms` out when the watcher reports a change; under
    /// `"off"` never.
    disk_check_due: ?std.Io.Clock.Timestamp = null,
    /// `config.file_watch`, after any fallback (`startFileWatch`).
    file_watch: diskwatch.Mode = .poll,
    /// The inotify watcher, under `file_watch = .inotify` only.
    inotify: ?*inotify_mod.Watcher = null,
    /// The last check had to skip the tree (`checkTreeDisk`), so under
    /// inotify the next one is armed without waiting for an event.
    disk_check_retry: bool = false,
    tab_tip_shown: bool = false,
    /// The context title last sent (`syncTitle`): `zoe` and the focused
    /// buffer's file, which glyphwire-host shows in the window title.
    title_buf: [glyphwire.Context.max_title_len]u8 = undefined,
    title_len: usize = 0,
    tab_tip_dirty: bool = false,

    /// The completion popup, non-null while it is up (insert mode only).
    /// See `zoe/complete.zig` for the model and `afterInsertEdit` for when
    /// it opens, narrows and closes.
    completion: ?complete.Menu = null,
    completion_layer: glyphwire.LayerHandle,
    completion_dirty: bool = false,
    /// The `:` line's filename popup (Tab on a path argument), non-null
    /// while it is up. See `zoe/pathmenu.zig`. A layer of its own rather
    /// than the completion popup's: it hangs over the statusline, not
    /// under a word in the buffer.
    path_menu: ?pathmenu.Menu = null,
    path_menu_layer: glyphwire.LayerHandle,
    path_menu_dirty: bool = false,
    /// The newest outstanding completion request, and where the word it is
    /// for starts -- a reply for a word the cursor has since left is
    /// dropped, the same staleness rule hover has.
    completion_request: ?i64 = null,
    completion_req_start: usize = 0,
    completion_req_line: usize = 0,
    /// An identifier-driven request waiting on `complete_auto_delay_ms`, so
    /// a burst of typing asks once, when it pauses, instead of per key.
    completion_due: ?std.Io.Clock.Timestamp = null,
    /// The word start the last request came back empty for. Typing more of
    /// that word doesn't ask again: a server with nothing for `fo` has
    /// nothing for `foo` either (unless it said its list was incomplete).
    completion_empty_at: ?usize = null,
    /// Ctrl+Space was just taken as "complete here". The host reports the
    /// key before the text in the same frame, and some layouts also commit
    /// a " " for the chord, which this drops.
    swallow_space_text: bool = false,
    /// A window command (`windowCommand`) just took a printable key; the
    /// `text` the host sends for the same key is dropped.
    swallow_window_text: bool = false,
    jumps: JumpList = .{},
    /// Ctrl+`: a `gw-shell` drawing into a layer docked along an edge
    /// (above the statusline) or floating in the middle, for running
    /// builds and tests without leaving the editor. It floats outside the split tree like the finder and takes
    /// every keystroke but Ctrl+` while it is open. Rooted at the tree's
    /// directory. See `applib/shellpanel.zig`.
    shell: shellpanel.Panel,
    /// Whether the host is drawing the caret (`true`, insert mode's bar
    /// or the unfocused box) or zoe's own inverted cell is (`false`), as
    /// last sent to the host; null when unknown and the next `syncCaret`
    /// must send it. Nulled whenever the shell panel takes the caret or
    /// gives it back.
    caret_host: ?bool = null,
    /// The shape last asked of the host, so a mode change inside the
    /// host-drawn cases still re-sends it.
    caret_shape: ?glyphwire.CaretShape = null,
    /// Whether zoe is what's being typed into -- the window has the
    /// keyboard and zoe's pane has focus -- from `focus` notifications.
    /// Assumed true until told otherwise: the host reports changes, and
    /// tells a program that starts out of focus straight away.
    has_focus: bool = true,
    /// Whether the host's key repeat is currently the shell's -- its own
    /// default, with a hold before the first repeat -- rather than the
    /// editor's per-mode cadence. See `syncKeyRepeat`.
    key_repeat_shell: bool = false,
    /// Where the popup last landed, for hit-testing a click, and how many
    /// list rows that left. Recomputed every time it is drawn.

    focus: Focus = .buffer,
    tree_visible: bool = true,
    /// Per-pane redraw flags, set by whatever changed that pane's
    /// contents and cleared by `render`. Split three ways because a
    /// keystroke on the `:` line only touches the status row -- redrawing
    /// the buffer (a fresh syntax pass per visible row) and the whole
    /// file tree (a `draw_icon` per entry) on every such keystroke is
    /// what made the command line feel laggy.
    /// The buffer pane's and tab strip's flags are per group
    /// (`Group.buffer_dirty`, `Group.tabs_dirty`).
    ///
    /// The tree's own flag has three levels rather than two: moving the
    /// cursor changes exactly two rows' background, and repainting the
    /// whole listing (a `write_text` *and* a `draw_icon` per entry) for
    /// that is what made holding `j` down heavy. See `TreeDirty`.
    tree_dirty: TreeDirty = .full,
    status_dirty: bool = true,
    quit: bool = false,
    /// Ctrl+W was pressed and the next key is a window command (`v`,
    /// `s`, `q`, `w`, a direction) -- vim's prefix.
    window_prefix: bool = false,
    /// Every key binding: the defaults with `zoe.conf.lua`'s `keys` over
    /// them. Each buffer's `Editor` points here (`Editor.keymaps`), which
    /// is safe because `Ui` lives on the heap and outlives its slots.
    keymaps: actions.Keymaps = .{},
    /// The Lua extensions `zoe.conf.lua` turned on, and the commands and
    /// bindings they added (`zoe/ext.zig`). Null with no config file.
    extensions: ?*ext.Runtime = null,
    /// The `:` and `/` lines' histories, shared by every buffer the same
    /// way `keymaps` is (`Editor.cmd_history`). See `zoe/cmdhistory.zig`.
    cmd_history: cmdhistory.History,
    search_history: cmdhistory.History,
    /// Where each is persisted (`zoe_history`, `zoe_search_history` in
    /// the config directory). Owned; null when there is no config
    /// directory or `GLYPHWIRE_NO_HISTORY` is set, and history is then
    /// this session's only.
    cmd_history_file: ?[]u8 = null,
    search_history_file: ?[]u8 = null,

    /// The process environment, kept for `:cd` (`$HOME`) and passed on
    /// to the highlighter setup.
    environ: *const std.process.Environ.Map,
    /// The working directory before the last `:cd`, for `:cd -`. Owned.
    prev_cwd: ?[]u8 = null,

    /// The theme this context's colours resolve against, as the host has
    /// it: `zoe.conf.lua`'s `theme` or the window's at startup, then
    /// whatever `:theme` switched to (see the colour note at the top of
    /// this file).
    th: themes.Stored,
    /// Whether `th` is this context's own theme (`zoe.conf.lua`'s, a
    /// workspace's, or `:theme <name>`) rather than the window's it
    /// follows. Only an own theme is written by `:wssave`: one that
    /// follows the window should go on following it when reopened.
    theme_own: bool,
    /// The `.zoe-workspace` this session was opened from or last saved
    /// to, absolute and owned: where a bare `:wssave` writes.
    ws_file: ?[]u8 = null,

    /// tree-sitter syntax highlighting: the config, the grammar registry
    /// every buffer's highlighter resolves through, and the search path
    /// it was built from. `grammars` is null when highlighting is off --
    /// no grammar directory resolved -- and every buffer then renders in
    /// plain `fg_text`; `hl_config` is the parsed config either way, and
    /// its arena backs `grammars`' language table, so it outlives the
    /// registry.
    /// Each buffer's own parse tree lives in its `Slot`. See applib/syntax.zig.
    hl_config: ?langconf.Config = null,
    grammars: ?syntax.Registry = null,
    hl_search_dirs: []const []const u8 = &.{},
    /// The mode the key-repeat cadence was last sent for, so
    /// `syncKeyRepeat` sends once per mode change. Tracks the *mode*
    /// rather than the cadence because the send is also what stops a
    /// held key repeating across the change -- which matters even when
    /// both modes are configured to the same numbers.
    key_repeat_mode_sent: ?editor.Mode = null,
    /// Reused span buffer for `renderRowSpans` and `fillSpanRun`.
    hl_scratch: std.ArrayList(syntax.Span) = .empty,
    /// `fillSpanRun`'s line list and per-line bounds into `hl_scratch`.
    hl_lines: std.ArrayList(syntax.LineRange) = .empty,
    /// What each screen row of the buffer pane being drawn shows -- see
    /// `RowView`. Rebuilt by `layoutRows` for whichever group a caller
    /// is about to paint or hit-test, never read stale.
    row_map: std.ArrayList(RowView) = .empty,
    /// Where the focused group's caret was last drawn: its screen row in
    /// the buffer pane, and the display column that row starts at. The
    /// hover and completion popups hang off it, which with `wrap` on is
    /// no longer simply `line - top_line`.
    caret_at: struct { row: usize = 0, left: usize = 0 } = .{},
    hl_bounds: std.ArrayList(usize) = .empty,
    /// Buffer lines an incremental reparse says need repainting for a
    /// highlighting reason (edited lines plus tree-sitter's changed
    /// ranges). Filled by `syncHighlight`, consumed by `renderChangedRows`.
    hl_dirty_lines: std.ArrayList(usize) = .empty,
    /// Scratch for `Highlighter.reparseIncremental`'s changed-range output.
    hl_changed: std.ArrayList(syntax.ByteRange) = .empty,
    /// `ZOE_PROFILE=<path>` frame timing; a no-op without it.
    prof: profile.Profile,

    pub fn init(
        alloc: std.mem.Allocator,
        io: std.Io,
        client: *glyphwire.Client,
        listener: *glyphwire.InputListener,
        target: Target,
        /// The sidebar's folders, at least one: just the cwd, or a
        /// workspace's list. Copied.
        folders: []const Tree.RootSpec,
        start: WorkspaceStart,
        environ: *const std.process.Environ.Map,
    ) !*Ui {
        const self = try alloc.create(Ui);
        errdefer alloc.destroy(self);

        // The config comes first: its theme colours every layer created
        // below. Owned here until `loadConfig` hands it to `self`.
        var cfg_owned: ?langconf.Config = langconf.load(alloc, io, environ);
        errdefer if (cfg_owned) |*c| c.deinit();
        // A workspace's theme wins over `zoe.conf.lua`'s; one that doesn't
        // resolve falls back to the usual choice, and says so once the
        // first buffer exists to carry the message.
        const ws_theme: ?themes.Theme = if (start.theme) |name| cfg_owned.?.findTheme(name) else null;
        const own_theme = ws_theme orelse cfg_owned.?.ownTheme();

        var keymaps = try actions.Keymaps.initDefaults(alloc, actions.defaults);
        errdefer keymaps.deinit(alloc);
        try keymaps.apply(alloc, cfg_owned.?.keys);

        // A dedicated context for the editor, shown immediately. From
        // here on every layer/split call on `client` targets it, not the
        // shell's context. The paired listener joins it too so its input
        // subscriptions follow this context's visibility. No window
        // scrollbar: zoe's root has no scrollback, and each pane draws
        // its own bar -- the always-on right-edge one would just sit
        // there permanently full.
        const context = try client.createContext(null, null, 0, false);
        errdefer client.destroyContext(context) catch {};
        try listener.attachContext(context);
        // What the context switcher, the shell's `jobs` and the window
        // title call this one. `render` keeps it on the focused buffer's
        // file from the first frame on (`syncTitle`).
        try client.setContextTitle("zoe");
        // `zoe.conf.lua`'s own theme for this context, or the window's.
        // Either way the resolved copy is kept for what the host can't
        // recolour: the popups' nine-patch frame, and whether `variable`
        // gets a span at all.
        const th: themes.Stored = if (own_theme) |t| blk: {
            try client.setTheme(&t);
            break :blk .init(t);
        } else try client.getTheme();
        // `zoe.conf.lua`'s `divider_style` / `divider_chars` for the
        // tree|editor band and every `:split`. Sent only when set, so a
        // zoe without one draws whatever the host's `pane_divider_style`
        // is.
        if (!cfg_owned.?.divider_style.inherits()) try client.setDividerStyle(&cfg_owned.?.divider_style);

        const size = try client.getSize();
        const metrics = try client.getCellMetrics();

        // Content sizes are provisional: every `layout` notification
        // resizes them to match the panes they landed in.
        const tree_layer = try client.createLayer(default_tree_cols, size.rows, 0);
        // The first editor group; `:vsplit` / `:split` add more.
        const first_group = try makeGroup(alloc, client, 1, size);
        errdefer alloc.destroy(first_group);
        const status_layer = try client.createLayer(size.cols, 1, 0);

        // The tree is host-scrolled (both bars).
        try client.setLayerScrollbars(tree_layer, true, true);
        // Each pane's resting colour, so a cell nothing has written yet
        // (a frame racing a resize) is the pane's colour rather than
        // whatever is behind zoe.
        try client.setLayerBackground(tree_layer, role(.sidebar_bg));
        try client.setLayerBackground(status_layer, role(.status_bg));

        // The Ctrl+` shell panel. `gw-shell --embed` draws its prompt and
        // its commands' output here, so it carries scrollback of its own
        // for the shell's Ctrl+Up browsing. Created before the finder so
        // the popup still composites over it, and outside the split tree:
        // `Panel.place` puts it where `shell_position` says when it opens.
        const shell_layers = try shellpanel.createLayers(client, size.cols);
        const shell_layer = shell_layers.shell;
        try client.setLayerBackground(shell_layer, role(.shell_bg));
        try client.setLayerScrollbars(shell_layer, true, false);
        // Output the user may want to copy: the host's drag-to-select,
        // which zoe's own drag handling would otherwise never allow here.
        try client.setLayerMouseSelect(shell_layer, true);

        // Every floating popup below gets the same host-drawn drop shadow
        // (`glyphwire.Shadow.dialog`): it follows the layer as it moves and
        // resizes and hides with it, so nothing here tracks it again.
        //
        // The finder popup, created here so it composites over every
        // pane (creation order is the initial stacking -- see
        // `raise_layer` in docs/api.md) but under the hover and completion
        // popups below. It stays invisible until Ctrl+P.
        var finder = try finderpopup.Popup.init(alloc, client, finderStyle(&th));
        errdefer finder.deinit();
        var palette = try palette_mod.Popup.init(alloc, client, paletteStyle(&th));
        errdefer palette.deinit();
        // The hover popup, floating like the finder's layers and placed
        // against the cursor rather than the pane -- `hoverRect`.
        const hover_layer = try client.createLayer(hover_max_cols, 1, 0);
        try client.setLayerVisible(hover_layer, false);
        try client.setLayerShadow(hover_layer, glyphwire.Shadow.dialog);
        const hover_panel_patch: ?glyphwire.NinePatchHandle = client.createNinePatch(hover_layer, 0, 0, 1, hover_max_cols, th.panelStyle()) catch |err| blk: {
            std.log.warn("zoe: no '{s}' nine-patch for the hover popup ({t}); drawing it flat", .{ th.panelStyle(), err });
            break :blk null;
        };
        if (hover_panel_patch == null) try client.setLayerBackground(hover_layer, role(.popup_bg));
        // The completion popup: one more float, placed under the word being
        // completed (`completionRect`).
        const completion_layer = try client.createLayer(complete_max_cols, 1, 0);
        try client.setLayerVisible(completion_layer, false);
        try client.setLayerBackground(completion_layer, role(.popup_bg));
        try client.setLayerShadow(completion_layer, glyphwire.Shadow.dialog);
        // The `:` line's filename popup, styled the same way.
        const path_menu_layer = try client.createLayer(complete_max_cols, 1, 0);
        try client.setLayerVisible(path_menu_layer, false);
        try client.setLayerBackground(path_menu_layer, role(.popup_bg));
        try client.setLayerShadow(path_menu_layer, glyphwire.Shadow.dialog);
        // The tab tooltip, last so it sits over everything: it hangs from
        // the tab strip over the top of the buffer and, for a long path,
        // over the file tree.
        const tab_tip_layer = try client.createLayer(tab_tip_initial_cols, tabs.tip_rows, 0);
        try client.setLayerVisible(tab_tip_layer, false);
        try client.setLayerShadow(tab_tip_layer, glyphwire.Shadow.dialog);
        const tab_tip_patch: ?glyphwire.NinePatchHandle = client.createNinePatch(tab_tip_layer, 0, 0, tabs.tip_rows, tab_tip_initial_cols, th.panelStyle()) catch |err| blk: {
            std.log.warn("zoe: no '{s}' nine-patch for the tab tooltip ({t}); drawing it flat", .{ th.panelStyle(), err });
            break :blk null;
        };
        if (tab_tip_patch == null) try client.setLayerBackground(tab_tip_layer, role(.popup_bg));

        // The tree|editor split stays user-resizable, as do the splits
        // between editor groups. The column splits are not: what they
        // stack above and below is a single fixed row each -- a group's
        // tab strip and the command line -- so a drag handle on either is
        // a wasted row.
        const pane_split = try client.createSplit(.row, true);
        const root_split = try client.createSplit(.column, false);

        self.* = .{
            .alloc = alloc,
            .io = io,
            .keymaps = keymaps,
            .cmd_history = .init(alloc),
            .search_history = .init(alloc),
            .client = client,
            .listener = listener,
            .tree = try Tree.initRoots(alloc, io, folders, .{}),
            // Set a few lines below, before anything can read it: the
            // first buffer builds its highlighter against the grammar
            // registry, which has to be at its final address in `self`
            // first (a `Highlighter` holds a pointer to it).
            .buf = undefined,
            .context = context,
            .tree_layer = tree_layer,
            .status_layer = status_layer,
            .finder = finder,
            .palette = palette,
            .hover_layer = hover_layer,
            .hover_panel_patch = hover_panel_patch,
            .completion_layer = completion_layer,
            .path_menu_layer = path_menu_layer,
            .tab_tip_layer = tab_tip_layer,
            .tab_tip_patch = tab_tip_patch,
            .diags = diag.Store.init(alloc),
            .shell = shellpanel.Panel.init(alloc, io, client, context, shell_layers),
            .pane_split = pane_split,
            .grp = first_group,
            .layout = try groups.Layout.init(alloc, first_group.id),
            .next_group_id = first_group.id + 1,
            .root_split = root_split,
            .cell_px_h = metrics.h,
            .environ = environ,
            .prof = .init(io, environ.get("ZOE_PROFILE")),
            .th = th,
            .theme_own = own_theme != null,
        };
        errdefer self.tree.deinit();
        errdefer self.layout.deinit();
        try self.group_list.append(alloc, first_group);
        if (start.file) |f| self.ws_file = try alloc.dupe(u8, f);

        // Best-effort: highlighting off is a valid state, never a reason
        // to fail bringing the editor up. Done before the first buffer,
        // which builds its own highlighter against what this leaves.
        self.loadConfig(cfg_owned.?, environ);
        cfg_owned = null;
        if (self.hl_config) |*cfg| {
            self.shell.setPosition(cfg.shell_position, cfg.shell_float_percent, self.winSize());
            // Borrowed from the config's arena, which outlives the tree.
            self.tree.visible.unignore = cfg.unignore;
            self.file_watch = cfg.file_watch;
        }
        self.shell.setFrameStyle(self.th.panelStyle());
        // Best-effort too: a history that can't be read is an empty one.
        self.loadHistories();

        // After the config (which carries the server list) and before the
        // first buffer (which announces itself to whatever started).
        self.startLsp(folders, environ);

        const target_path: ?[]const u8 = switch (target) {
            .file => |f| f.path,
            .none, .directory, .workspace => null,
        };
        // `zoe some.png` is refused the same way opening it later would
        // be -- but zoe still comes up, on an empty buffer with the error
        // in the statusline, rather than not starting at all.
        var refused: ?[]const u8 = null;
        const first = self.newSlot(target_path) catch |err| switch (err) {
            error.NotTextFile => blk: {
                refused = target_path;
                break :blk try self.newSlot(null);
            },
            else => return err,
        };
        errdefer first.deinit(alloc);
        if (refused) |p| first.ed.setStatus("E484: \"{s}\" is not a text file", .{p});
        if (refused == null) switch (target) {
            .file => |f| if (f.line) |line| first.ed.gotoStartLine(line),
            .none, .directory, .workspace => {},
        };
        try self.grp.buffers.append(alloc, first);
        self.buf = first;
        self.grp.active = 0;

        // `zoe <dir>` names a place to work, not a file to open: the tree
        // is already rooted there (the directory `main` changed into), so
        // start the focus on it -- picking something out of it is the
        // next thing that happens, and an empty scratch buffer has
        // nothing to look at. A workspace is the same thing, several
        // times over.
        if (target == .directory or target == .workspace) self.focus = .tree;

        try self.applySplitChildren();
        try client.setSplitChildren(root_split, &.{
            glyphwire.SplitChildInput.splitWeighted(pane_split, 1),
            // The statusline is `fixed`, not a weight: one row is one row
            // whatever the window does.
            glyphwire.SplitChildInput.layerFixed(status_layer, 1),
        });
        try client.setRootSplit(root_split);

        // A saved workspace's groups and tabs, once the first group is on
        // screen to grow them from. Best-effort: a layout that can't be
        // rebuilt still leaves a working editor over the right folders.
        if (start.editors) |e| self.restoreEditors(e) catch |err| {
            self.buf.ed.setStatus("E: couldn't restore the workspace's editors ({t})", .{err});
        };
        if (start.theme != null and ws_theme == null) {
            self.buf.ed.setStatus("E185: Cannot find color scheme '{s}' (workspace theme ignored)", .{start.theme.?});
        }
        // Last, so a command can't be bound before the window it acts on
        // is whole, and a problem loading one has a statusline to say so.
        self.startExtensions();
        errdefer if (self.extensions) |rt| rt.deinit();

        // The `layout` broadcast goes to *other* connections, and the
        // listener is one -- but reading the bounds back directly avoids
        // a startup frame drawn against guesses.
        try self.readBounds();
        return self;
    }

    /// Creates an editor group's two layers -- its tab strip and its
    /// buffer pane -- and the column split that stacks them. Its buffer
    /// list starts empty; the caller gives it its first tab before
    /// anything can draw it.
    pub fn makeGroup(alloc: std.mem.Allocator, client: *glyphwire.Client, id: groups.GroupId, size: anytype) !*Group {
        // Content sizes are provisional, like every pane's: the `layout`
        // that places the group resizes them.
        const tabs_layer = try client.createLayer(size.cols, 1, 0);
        const buffer_layer = try client.createLayer(size.cols, size.rows, 0);

        // The buffer is in `client` scroll mode: it redraws its own
        // visible rows, and a `content_extent` (pushed each frame from
        // the line count -- see `syncBufferScrollbar`) lets the host draw
        // a proportional vertical bar and turn a wheel or thumb drag over
        // the pane into a `scroll_offset` zoe then follows.
        try client.setLayerScrollMode(buffer_layer, .client);
        try client.setLayerScrollMode(tabs_layer, .client);
        try client.setLayerScrollbars(buffer_layer, true, false);
        // The tab strip scrolls sideways but draws no bar of its own: it
        // is one row tall, and a horizontal bar under it would double its
        // height for a scrollbar nothing needs to see. It still reports a
        // `content_extent` (`syncTabScrollbar`), which is what makes the
        // host treat it as scrollable and route a shift+wheel over it
        // back as a `scroll_offset`.
        try client.setLayerScrollbars(tabs_layer, false, false);
        try client.setLayerBackground(tabs_layer, role(.tab_bar_bg));
        try client.setLayerBackground(buffer_layer, role(.bg));

        const col_split = try client.createSplit(.column, false);
        try client.setSplitChildren(col_split, &.{
            // One row, whatever the window does -- same reasoning as the
            // statusline.
            glyphwire.SplitChildInput.layerFixed(tabs_layer, 1),
            glyphwire.SplitChildInput.layerWeighted(buffer_layer, 1),
        });

        const g = try alloc.create(Group);
        g.* = .{ .id = id, .tabs_layer = tabs_layer, .buffer_layer = buffer_layer, .col_split = col_split };
        return g;
    }

    /// Takes ownership of the loaded `zoe.conf.lua` and resolves the
    /// grammar search path into a registry. A failure there leaves
    /// `grammars` null, and every buffer then renders unhighlighted --
    /// each buffer's own `Highlighter` is built against this in `newSlot`.
    pub fn loadConfig(self: *Ui, cfg: langconf.Config, environ: *const std.process.Environ.Map) void {
        // Kept even without grammars: the editor settings in it still
        // apply, and `:theme` resolves against its `themes`.
        self.hl_config = cfg;
        const dirs = syntax.searchDirs(self.alloc, self.io, environ, cfg.grammar_dirs) catch return;

        self.hl_search_dirs = dirs;
        self.grammars = syntax.Registry.init(self.alloc, self.io, dirs, cfg.langs);
    }

    /// Tells glyphwire-host, once per mode change, what cadence to repeat
    /// held keys at.
    ///
    /// Two cadences, because the host repeats *typed* characters on this
    /// clock too (`Keyboard.textRepeated`) and a held letter means
    /// opposite things either side of `i`. In normal and visual mode a
    /// repeat is a motion -- `j`, an arrow, PageDown. In insert and
    /// command mode the same key types, and a hold short enough to feel
    /// instant while navigating would turn one ordinary ~100ms keystroke
    /// into several characters.
    ///
    /// Sent on every mode change, not only when the numbers differ: the
    /// message is also what stops a key held across the change from
    /// repeating (`Keyboard.cancelRepeats`), and the key that needs that
    /// most is `i` itself -- it types, so it would otherwise go on
    /// typing `i` into the buffer it just opened. That holds even when
    /// both modes are configured to the same cadence.
    ///
    /// Best-effort: a failure leaves the host on whatever cadence it was
    /// already using, and the next mode change tries again.
    pub fn syncKeyRepeat(self: *Ui) void {
        // The shell panel wants the host's own cadence, hold and all: an
        // editor's no-hold repeat re-runs a command a held Enter at a
        // time. Clearing the override does that, and going back to the
        // per-mode cadence afterwards means forgetting what was sent.
        if (self.shell.isFocused()) {
            if (self.key_repeat_shell) return;
            self.client.setKeyRepeat(null, null) catch |err| {
                std.log.warn("zoe: set_key_repeat failed ({t}); keeping the host's cadence", .{err});
                return;
            };
            self.key_repeat_shell = true;
            self.key_repeat_mode_sent = null;
            return;
        }
        self.key_repeat_shell = false;

        const mode = self.buf.ed.mode;
        if (self.key_repeat_mode_sent) |sent| {
            if (sent == mode) return;
        }
        const want = self.keyRepeatForMode();
        self.client.setKeyRepeat(want.delay_ms, want.interval_ms) catch |err| {
            std.log.warn("zoe: set_key_repeat failed ({t}); keeping the host's cadence", .{err});
            return;
        };
        self.key_repeat_mode_sent = mode;
    }

    /// The cadence the editor's current mode wants, from `zoe.conf.lua` --
    /// or from the same defaults `zoe.conf.lua` would have left in place, if
    /// the config failed to load at all.
    pub fn keyRepeatForMode(self: *Ui) langconf.KeyRepeat {
        const typing = switch (self.buf.ed.mode) {
            // The `/` line is typed into, like the `:` line, so it wants
            // the typing cadence rather than the normal-mode one.
            .insert, .command, .search => true,
            .normal, .visual, .visual_line, .select => false,
        };
        const cfg = self.hl_config orelse return if (typing) .{
            .delay_ms = langconf.key_repeat_insert_delay_ms_default,
            .interval_ms = langconf.key_repeat_insert_interval_ms_default,
        } else .{
            .delay_ms = langconf.key_repeat_delay_ms_default,
            .interval_ms = langconf.key_repeat_interval_ms_default,
        };
        return if (typing) .{
            .delay_ms = cfg.key_repeat_insert_delay_ms,
            .interval_ms = cfg.key_repeat_insert_interval_ms,
        } else .{
            .delay_ms = cfg.key_repeat_delay_ms,
            .interval_ms = cfg.key_repeat_interval_ms,
        };
    }

    /// Ctrl+`: shows the shell panel (starting the shell the first time)
    /// or hides it again. Hiding leaves the shell running, history and
    /// any job in it included. On a panel that is up but was clicked
    /// away from, it hands the keyboard back to the shell instead, the
    /// way VS Code's terminal toggle does.
    pub fn toggleShell(self: *Ui) void {
        if (self.shell.isOpen() and !self.shell.isFocused()) {
            self.focusShell();
            return;
        }
        if (self.shell.isOpen()) {
            self.shell.close();
            self.shellClosed();
            return;
        }
        var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
        self.shell.open(self.shellDir(&dir_buf), self.winSize()) catch |err| {
            self.buf.ed.setStatus("can't start gw-shell: {t}", .{err});
            self.status_dirty = true;
            return;
        };
        // The shell takes the caret; what zoe last sent no longer stands.
        self.caret_host = null;
    }

    /// Where the shell panel starts: the workspace folder holding the
    /// active buffer's file, so in a workspace the shell lands in the
    /// project being edited. A scratch buffer, or a file outside every
    /// folder, falls back to the first folder -- which with a single
    /// folder is the only answer there ever was. `buf` holds the
    /// absolute form of a relative buffer path while it is looked up.
    pub fn shellDir(self: *const Ui, buf: []u8) []const u8 {
        const fallback = self.tree.primaryRoot();
        const p = self.buf.ed.path orelse return fallback;
        const abs = homepath.absoluteBuf(self.io, p, buf) orelse return fallback;
        const loc = self.tree.locate(abs) orelse return fallback;
        return self.tree.roots.items[loc.root].path;
    }

    /// The panel went away -- Ctrl+` closed it, or its shell exited. Zoe
    /// has the host caret back and has to send it afresh. Nothing is
    /// repainted: the panel is a layer over the panes, and hiding it
    /// shows them exactly as they were.
    pub fn shellClosed(self: *Ui) void {
        self.caret_host = null;
    }

    /// The open panel takes the keyboard back: a click on it, or Ctrl+`.
    /// Popups go the way a keystroke would send them, since the next
    /// keystroke is the shell's.
    pub fn focusShell(self: *Ui) void {
        if (self.shell.isFocused()) return;
        _ = self.closeHover();
        self.closeCompletion();
        self.dismissTabTip();
        self.shell.focus();
        // The shell takes the caret; what zoe last sent no longer stands.
        self.caret_host = null;
    }

    /// A click outside the open panel: zoe has the keyboard and the
    /// caret again, and the panel stays where it is.
    pub fn blurShell(self: *Ui) void {
        if (!self.shell.isFocused()) return;
        self.shell.blur();
        self.shellClosed();
        self.status_dirty = true;
    }

    /// The whole window in cells. The statusline is the last row of the
    /// root split, so its bounds are the window's bottom edge.
    pub fn winSize(self: *const Ui) shellpanel.WinSize {
        return .{
            .cols = self.status_bounds.cols,
            .rows = self.status_bounds.row + self.status_bounds.rows,
        };
    }

    /// Puts the open panel back where it sits after a resize.
    pub fn replaceShell(self: *Ui) void {
        if (!self.shell.isOpen()) return;
        self.shell.place(self.winSize()) catch |err| {
            std.log.warn("zoe: can't resize the shell panel ({t})", .{err});
        };
    }

    /// Hands the caret to whoever should draw it for the current mode.
    ///
    /// The host draws it in two cases, both of them shapes that leave the
    /// character underneath readable: insert mode, as a thin bar on the
    /// buffer layer (nvim's insert cursor), and a window that has lost
    /// the keyboard, as a hollow box (every terminal's convention). Every
    /// other mode is zoe's own inverted cell (see `renderBuffer`), which
    /// is a filled block the host has no equivalent for -- its `block`
    /// paints over the glyph rather than inverting it -- and the host's
    /// caret is hidden. Sent only when the answer changes.
    ///
    /// Not at all while the shell panel is up: the shell owns the caret
    /// then, and `shellClosed` makes the next call send it afresh.
    pub fn syncCaret(self: *Ui) void {
        if (self.shell.isFocused()) return;
        const shape = self.caretShape();
        const host = shape != null;
        if (self.caret_host == host and self.caret_shape == shape) return;
        self.sendCaret(shape) catch |err| {
            std.log.warn("zoe: can't set the caret ({t}); it may show in the wrong shape", .{err});
            return;
        };
        self.caret_host = host;
        self.caret_shape = shape;
    }

    /// The shape the host should draw the caret in, or null when the
    /// caret is zoe's own inverted cell. Read by `renderBuffer` too, so
    /// the two can never disagree about who is drawing it.
    pub fn caretShape(self: *const Ui) ?glyphwire.CaretShape {
        if (!self.has_focus) return .box;
        if (self.buf.ed.mode == .insert or self.buf.ed.mode == .select) return .line;
        return null;
    }

    /// `shape` non-null hands the host the caret, on the buffer layer, in
    /// that shape; null takes it back for `renderBuffer` to draw.
    pub fn sendCaret(self: *Ui, shape: ?glyphwire.CaretShape) !void {
        if (shape) |s| {
            try self.client.setCaretLayer(self.grp.buffer_layer);
            try self.client.setCaretShape(s);
            try self.client.setCaretVisible(true);
        } else {
            try self.client.setCaretVisible(false);
            try self.client.setCaretShape(null);
            try self.client.setCaretLayer(null);
        }
    }

    /// Opens `path` -- or an empty scratch buffer when null -- as a new,
    /// unlisted slot: the caller adds it to `buffers`. A path that can't
    /// be read is a new empty buffer carrying that name, which is how
    /// `zoe newfile.txt` creates one.
    ///
    /// `error.NotTextFile` for a file that isn't text (see filetype.zig).
    /// The caller decides what that looks like, because the two callers
    /// want different things: `openFile` reports it and opens no tab at
    /// all, while `init` still has to bring the editor up.
    pub fn newSlot(self: *Ui, path: ?[]const u8) !*Slot {
        const slot = try self.alloc.create(Slot);
        errdefer self.alloc.destroy(slot);

        const text: ?[]u8 = if (path) |p|
            std.Io.Dir.cwd().readFileAlloc(self.io, p, self.alloc, .limited(max_file_bytes)) catch null
        else
            null;
        defer if (text) |t| self.alloc.free(t);

        // Read, then refused: the sniff needs the bytes, and a file zoe
        // is willing to hold in a buffer is one it can afford to have
        // read twice as far as this costs.
        if (text) |t| {
            if (filetype.looksBinary(t)) return error.NotTextFile;
        }

        slot.* = .{ .ed = try Editor.initFromText(self.alloc, text orelse "", path) };
        errdefer slot.ed.deinit();
        if (text != null) slot.disk = self.diskStamp(path.?);
        slot.ed.keymaps = &self.keymaps;
        slot.ed.cmd_history = &self.cmd_history;
        slot.ed.search_history = &self.search_history;
        slot.ed.line_comment = self.lineCommentFor(path);
        slot.ed.colon_block = self.colonBlockFor(path);

        // Same line vim shows on opening: the file and its length, or
        // that it doesn't exist yet.
        if (path) |p| {
            if (text == null) {
                slot.ed.setStatus("\"{s}\" [New]", .{p});
            } else {
                slot.ed.setStatus("\"{s}\" {d}L", .{ p, slot.ed.buf.lineCount() });
            }
        }

        if (self.hl_config) |cfg| {
            // `page_lines` and the line-number gutter ride in on the same
            // config load, whether or not highlighting itself ends up
            // enabled below.
            slot.ed.page_lines = cfg.page_lines;
            slot.ed.line_numbers = cfg.line_numbers;
            slot.ed.tab_width = cfg.tab_width;
            slot.ed.expand_tab = cfg.expand_tab;
            slot.ed.show_whitespace = cfg.show_whitespace;
            slot.ed.wrap = cfg.wrap;
            slot.ed.auto_indent = cfg.auto_indent;
            slot.ed.auto_close = cfg.auto_close;
            slot.ed.fold_column = cfg.fold_column;

            if (syntax.Highlighter.init(self.alloc, syntax.Theme.fromTheme(&self.th.theme))) |h| {
                slot.hl = h;
                // The highlighter resolves injected grammars through the
                // shared registry; `injections` is the `zoe.conf.lua` switch.
                const reg: ?*syntax.Registry = if (self.grammars) |*g| g else null;
                slot.hl.?.configureInjections(reg, cfg.injections);
                // From here on `Buffer` keeps the edit journal the
                // incremental reparse replays.
                slot.ed.buf.track_edits = true;
                self.selectHighlightLanguage(slot, path);
            } else |_| {}
        }

        // The language servers hear about it here rather than at each call
        // site, so `:e`, Ctrl+P, the file tree and the first buffer `init`
        // opens all announce it the same way. A no-op without a server, or
        // for a scratch buffer with no path.
        self.lspDidOpen(slot);

        // A `:set lineno=…` typed this session beats the config default,
        // so a buffer opened afterwards matches the ones already open.
        if (self.grp.buffers.items.len > 0) {
            slot.ed.line_numbers = self.buf.ed.line_numbers;
            slot.ed.page_lines = self.buf.ed.page_lines;
            slot.ed.tab_width = self.buf.ed.tab_width;
            slot.ed.expand_tab = self.buf.ed.expand_tab;
            slot.ed.show_whitespace = self.buf.ed.show_whitespace;
            slot.ed.wrap = self.buf.ed.wrap;
            slot.ed.auto_indent = self.buf.ed.auto_indent;
            slot.ed.auto_close = self.buf.ed.auto_close;
            slot.ed.fold_column = self.buf.ed.fold_column;
        }
        return slot;
    }

    /// Points a slot's highlighter at the grammar for `path` (by
    /// extension), or clears it. Cheap and idempotent.
    pub fn selectHighlightLanguage(self: *Ui, slot: *Slot, path: ?[]const u8) void {
        const h = if (slot.hl) |*x| x else return;
        const reg = if (self.grammars) |*x| x else return;

        h.clearLanguage();
        const p = path orelse return;
        const name = reg.nameForPath(p) orelse return;
        const grammar = reg.get(name) orelse return;
        h.setLanguage(name, grammar) catch return;

        // Nudge `hl_edits` off the buffer's value so the next
        // `renderBuffer` parses.
        slot.hl_edits = slot.ed.buf.edits -% 1;
    }

    /// Tears down what `init` built on the server, not just this
    /// process's own memory -- otherwise zoe's context (and every layer,
    /// split and table in it) outlives the connection that made it and
    /// the host keeps compositing zoe's last frame over the shell.
    /// Destroying the context does all of that in one call and pops
    /// visibility back to the shell; the connection closing would cull it
    /// anyway (see `Client.destroyContext`), this just makes the switch
    /// immediate. Best-effort -- the connection may already be going away.
    pub fn deinit(self: *Ui) void {
        // Before the context goes: the shell draws on a layer inside it,
        // and this is what tells it to leave.
        self.shell.deinit();
        // Each server gets `shutdown`/`exit` and then, if it has not gone,
        // a kill -- bounded, so quitting zoe never waits on a language
        // server that has stopped listening. See `lsp.Server.deinit`.
        if (self.lsp_pool) |*p| p.deinit();
        // Joined before the listener it wakes goes away.
        if (self.inotify) |w| w.stop();
        self.diags.deinit();
        if (self.hover) |*h| h.deinit();
        if (self.hover_hl) |*h| h.deinit();
        if (self.completion) |*m| m.deinit();
        if (self.path_menu) |*m| m.deinit();
        self.jumps.deinit(self.alloc);
        // Before anything a command could reach: the Lua state goes first.
        if (self.extensions) |rt| rt.deinit();
        self.keymaps.deinit(self.alloc);
        self.cmd_history.deinit();
        self.search_history.deinit();
        if (self.cmd_history_file) |p| self.alloc.free(p);
        if (self.search_history_file) |p| self.alloc.free(p);
        self.client.destroyContext(self.context) catch {};
        self.tree.deinit();
        self.finder.deinit();
        self.palette.deinit();
        if (self.find) |*f| f.deinit(self.alloc);
        if (self.tree_edit) |*te| te.deinit(self.alloc);
        if (self.prev_cwd) |p| self.alloc.free(p);
        if (self.ws_file) |p| self.alloc.free(p);

        // Every open buffer's text and parse tree, not just the visible
        // one -- that is the bargain multiple buffers made.
        for (self.group_list.items) |g| {
            for (g.buffers.items) |slot| slot.deinit(self.alloc);
            g.buffers.deinit(self.alloc);
            g.tab_spans.deinit(self.alloc);
            self.alloc.destroy(g);
        }
        self.group_list.deinit(self.alloc);
        self.layout.deinit();

        self.hl_scratch.deinit(self.alloc);
        self.hl_lines.deinit(self.alloc);
        self.row_map.deinit(self.alloc);
        self.hl_bounds.deinit(self.alloc);
        self.hl_dirty_lines.deinit(self.alloc);
        self.hl_changed.deinit(self.alloc);
        self.prof.deinit();
        if (self.grammars) |*g| g.deinit();
        for (self.hl_search_dirs) |d| self.alloc.free(d);
        self.alloc.free(self.hl_search_dirs);
        if (self.hl_config) |*c| c.deinit();

        self.alloc.destroy(self);
    }

    /// The row split's children -- just the buffer when the tree is
    /// hidden. Toggling the sidebar rebuilds this rather than hiding the
    /// layer, so the buffer actually reclaims the columns instead of
    /// leaving a gap where the tree was.
    pub fn applySplitChildren(self: *Ui) !void {
        const editors = self.layoutChild(self.layout.root);
        if (self.tree_visible) {
            try self.client.setSplitChildren(self.pane_split, &.{
                glyphwire.SplitChildInput.layerFixed(self.tree_layer, default_tree_cols),
                editors,
            });
        } else {
            try self.client.setSplitChildren(self.pane_split, &.{editors});
        }
    }

    // ── Editor groups ───────────────────────────────────────────────────
    //
    // The arrangement is `layout` (zoe/groups.zig), and each of its nodes
    // is one host split: a group is its `col_split`, a split node its
    // own resizable split of two. A change sends a fresh split's list and
    // swaps the one slot it touched in the list holding it with
    // `replace_split_child`, never re-sending that list: the slot keeps
    // its size, so splitting a group halves that group and leaves every
    // proportion the user dragged elsewhere (the sidebar's width too)
    // alone.

    pub fn groupById(self: *const Ui, id: groups.GroupId) *Group {
        for (self.group_list.items) |g| {
            if (g.id == id) return g;
        }
        unreachable; // every id in `layout` has a group
    }

    /// The host split child a layout node stands for.
    pub fn layoutChild(self: *const Ui, node: *const groups.Node) glyphwire.SplitChildInput {
        return self.layoutChildWeighted(node, 1);
    }

    pub fn layoutChildWeighted(self: *const Ui, node: *const groups.Node, weight: f32) glyphwire.SplitChildInput {
        return switch (node.kind) {
            .leaf => |id| glyphwire.SplitChildInput.splitWeighted(self.groupById(id).col_split, weight),
            .split => |s| glyphwire.SplitChildInput.splitWeighted(s.handle, weight),
        };
    }

    pub fn sendSplit(self: *Ui, node: *const groups.Node) !void {
        const s = node.kind.split;
        try self.client.setSplitChildren(s.handle, &.{ self.layoutChild(s.first), self.layoutChild(s.second) });
    }

    /// Points the slot that holds `node` -- in its parent split, or in
    /// the tree|editor split when it is the layout's root -- at whatever
    /// `node` now is, keeping the slot's size.
    pub fn replaceInListHolding(self: *Ui, node: *const groups.Node) !void {
        const child: glyphwire.SplitChildInput = .{ .split = self.layoutChild(node).split.? };
        if (node.parent) |p| {
            try self.client.replaceSplitChild(p.kind.split.handle, node.slot().?.index(), child);
        } else {
            // The editors follow the sidebar when it is shown (see
            // `applySplitChildren`).
            const index: usize = if (self.tree_visible) 1 else 0;
            try self.client.replaceSplitChild(self.pane_split, index, child);
        }
    }

    pub const SlotAt = struct { group: *Group, index: usize };

    /// The group holding `slot`, and the slot's tab index there.
    pub fn findSlot(self: *const Ui, slot: *const Slot) ?SlotAt {
        for (self.group_list.items) |g| {
            for (g.buffers.items, 0..) |s, i| {
                if (s == slot) return .{ .group = g, .index = i };
            }
        }
        return null;
    }

    /// Gives `g` the keyboard. The group that had it is repainted too,
    /// to take its caret off.
    pub fn focusGroup(self: *Ui, g: *Group) void {
        if (g != self.grp) {
            self.grp.markRedraw();
            self.grp = g;
            self.buf = g.slot();
            g.markRedraw();
            // The host's caret, when it is drawing one, sits on a group's
            // buffer layer: point it at the new one.
            self.caret_host = null;
            self.closeCompletion();
            _ = self.closeHover();
        }
        self.setFocus(.buffer);
        self.status_dirty = true;
    }

    /// `:vsplit` / `:split` and Ctrl+W v / s: a new group beside (or
    /// under) the focused one, which gets the keyboard.
    ///
    /// A file is only ever open in one group, so the new group can't show
    /// a second view of the current buffer the way vim's would. It takes
    /// the current tab instead -- "put this file over there" -- and the
    /// group it left keeps the rest of its tabs, or a scratch buffer if
    /// that was its only one. `:vsplit <path>` opens that file in the
    /// new group instead (moving its tab there if it is open already).
    /// `side` is where the new group goes: after (right of / below) the
    /// focused one for every command, before it only for Ctrl+W Shift+H /
    /// K moving a tab off the left or top edge.
    pub fn splitGroup(self: *Ui, orientation: groups.Orientation, side: groups.Side, path: ?[]const u8) !void {
        if (self.focus == .tree) self.setFocus(.buffer);
        const from = self.grp;

        // Resolve what the new group will show before creating anything,
        // so a refused file leaves the layout untouched.
        var fresh: ?*Slot = null;
        var moved: ?*Slot = null;
        if (path) |p| {
            if (self.findPath(p)) |hit| {
                moved = hit.group.buffers.items[hit.index];
            } else {
                fresh = self.newSlot(p) catch |err| switch (err) {
                    error.NotTextFile => {
                        self.buf.ed.setStatus("E484: \"{s}\" is not a text file", .{p});
                        self.status_dirty = true;
                        return;
                    },
                    else => return err,
                };
            }
        } else {
            moved = self.buf;
        }
        errdefer if (fresh) |f| f.deinit(self.alloc);

        const g = try self.insertGroup(from, orientation, side);
        // Should filling it fail, the group must not stay on screen with
        // no tab: every other path assumes a group has one.
        errdefer if (g.buffers.items.len == 0) {
            if (self.layout.remove(g.id)) |removed| {
                self.dropGroup(g, removed) catch {};
            } else |_| {}
        };

        if (fresh) |f| {
            try g.buffers.append(self.alloc, f);
            fresh = null;
        } else if (moved) |m| {
            try self.moveSlot(m, g, null);
        }
        self.focusGroup(g);
        // Every group's pane just changed size; the `layout` that follows
        // repaints them, but the new one has never drawn at all.
        for (self.group_list.items) |each| each.markRedraw();
    }

    /// A new, empty group split off `from` on `side`, in the layout and on
    /// screen. Its buffer list is empty: the caller gives it a tab before
    /// anything draws, or takes it back out.
    pub fn insertGroup(self: *Ui, from: *Group, orientation: groups.Orientation, side: groups.Side) !*Group {
        const size = try self.client.getSize();
        const g = try makeGroup(self.alloc, self.client, self.next_group_id, size);
        self.next_group_id += 1;
        // Created after the popups and the shell panel, so the new layers
        // would composite over them; split panes never overlap one
        // another, so the bottom of the stack is a safe place for them.
        self.client.lowerLayer(g.buffer_layer, null) catch {};
        self.client.lowerLayer(g.tabs_layer, null) catch {};
        try self.group_list.append(self.alloc, g);

        const handle = try self.client.createSplit(orientation.axis(), true);
        const node = try self.layout.split(from.id, g.id, orientation, handle, side);
        errdefer if (self.layout.remove(g.id)) |removed| {
            self.dropGroup(g, removed) catch {};
        } else |_| {};
        try self.sendSplit(node);
        try self.replaceInListHolding(node);
        return g;
    }

    /// Moves `slot` from whichever group holds it into `to`'s tabs at
    /// `index` (the end when null), as `to`'s shown tab. A group the move
    /// leaves empty gets a scratch buffer rather than closing -- callers
    /// that want it gone instead use `moveTab`.
    pub fn moveSlot(self: *Ui, slot: *Slot, to: *Group, index: ?usize) !void {
        const at = self.findSlot(slot) orelse return;
        const from = at.group;
        if (from == to) return;
        const dest = @min(index orelse to.buffers.items.len, to.buffers.items.len);
        try to.buffers.insert(self.alloc, dest, slot);
        _ = from.buffers.orderedRemove(at.index);
        if (from.buffers.items.len == 0) {
            const scratch = try self.newSlot(null);
            from.buffers.append(self.alloc, scratch) catch |err| {
                scratch.deinit(self.alloc);
                return err;
            };
        }
        // The same index rule closing a tab uses: a tab left of the shown
        // one going shifts it down, and the shown one going leaves
        // whatever slid into its place.
        if (from.active > at.index) from.active -= 1;
        from.active = @min(from.active, from.buffers.items.len - 1);
        from.markRedraw();

        to.active = dest;
        // The layer it lands on has never shown this buffer.
        slot.full_redraw = true;
        slot.pushed_bar = .{ std.math.maxInt(usize), 0, 0, 0 };
        to.markRedraw();
        if (from == self.grp) self.buf = from.slot();
        if (to == self.grp) self.buf = to.slot();
    }

    /// Ctrl+W Shift+H/J/K/L and a tab dragged onto another group: moves
    /// `slot` into group `to` at `index` (the end when null) and gives
    /// `to` the keyboard, so the moved tab is where you keep working.
    ///
    /// Unlike `moveSlot`, a group the move leaves without tabs closes --
    /// the same thing closing its last tab does -- rather than being
    /// handed a scratch buffer nobody asked for. Within one group it is a
    /// reorder.
    pub fn moveTab(self: *Ui, slot: *Slot, to: *Group, index: ?usize) !void {
        const at = self.findSlot(slot) orelse return;
        const from = at.group;
        if (from == to) {
            self.reorderTab(from, at.index, index orelse from.buffers.items.len);
            return;
        }
        if (from.buffers.items.len > 1) {
            try self.moveSlot(slot, to, index);
            self.focusGroup(to);
            return;
        }

        // Its only tab: take it out by hand, so `moveSlot` doesn't leave a
        // scratch buffer behind, and close the group it leaves.
        const dest = @min(index orelse to.buffers.items.len, to.buffers.items.len);
        try to.buffers.insert(self.alloc, dest, slot);
        _ = from.buffers.orderedRemove(at.index);
        to.active = dest;
        slot.full_redraw = true;
        slot.pushed_bar = .{ std.math.maxInt(usize), 0, 0, 0 };
        // Before the group goes: `grp` must not be left pointing at it.
        self.focusGroup(to);
        const removed = self.layout.remove(from.id) catch return;
        try self.dropGroup(from, removed);
    }

    /// Moves group `g`'s tab at `from_i` so it lands in front of what is
    /// at `to_i` now (`to_i` may be the tab count: the end), keeping it
    /// the shown tab if it was.
    pub fn reorderTab(self: *Ui, g: *Group, from_i: usize, to_i: usize) void {
        const n = g.buffers.items.len;
        if (from_i >= n) return;
        // Removing it first shifts everything right of it down one.
        const dest = if (to_i > from_i) @min(to_i - 1, n - 1) else to_i;
        if (dest == from_i) return;
        const shown = g.slot();
        const slot = g.buffers.orderedRemove(from_i);
        // Can't fail: the list just gave the slot's capacity back.
        g.buffers.insertAssumeCapacity(dest, slot);
        for (g.buffers.items, 0..) |each, i| {
            if (each == shown) g.active = i;
        }
        g.tabs_dirty = true;
        self.status_dirty = true;
    }

    /// Ctrl+W Shift+H/J/K/L: moves the shown tab to the group that way.
    /// With no group that way, splits one off on that side for it -- as
    /// long as there is a tab left behind; a group's only tab has nowhere
    /// new to go.
    pub fn moveTabToward(self: *Ui, dir: groups.Direction) !void {
        if (self.focus == .tree) return;
        if (self.groupFacing(self.grp.rect(), self.grp, dir)) |g| {
            try self.moveTab(self.buf, g, null);
            return;
        }
        if (self.grp.buffers.items.len < 2) return;
        const orientation: groups.Orientation = switch (dir) {
            .left, .right => .vertical,
            .up, .down => .horizontal,
        };
        const side: groups.Side = switch (dir) {
            .left, .up => .before,
            .right, .down => .after,
        };
        try self.splitGroup(orientation, side, null);
    }

    /// `:close` and Ctrl+W q / c: closes the focused group, its tabs
    /// moving to the group that grows into its space -- nothing is
    /// abandoned, so nothing needs a `!`. The last group can't be
    /// closed (`:q` is how zoe goes away).
    pub fn closeGroup(self: *Ui) !void {
        if (self.group_list.items.len < 2) {
            self.buf.ed.setStatus("E444: Cannot close last window", .{});
            self.status_dirty = true;
            return;
        }
        const g = self.grp;
        const shown = self.buf;
        const removed = self.layout.remove(g.id) catch return;
        const to = self.groupById(removed.focus);

        // Its tabs go along to `to` -- except a lone, untouched scratch
        // buffer: carrying an empty `[No Name]` over is just clutter.
        const lone = g.buffers.items.len == 1;
        for (g.buffers.items) |slot| {
            if (lone and slot.ed.path == null and !slot.ed.buf.dirty and slot.ed.buf.len() == 0) {
                slot.deinit(self.alloc);
                continue;
            }
            slot.full_redraw = true;
            slot.pushed_bar = .{ std.math.maxInt(usize), 0, 0, 0 };
            try to.buffers.append(self.alloc, slot);
        }
        // `to` shows what `g` was showing, if that came along.
        for (to.buffers.items, 0..) |slot, i| {
            if (slot == shown) to.active = i;
        }
        g.buffers.clearRetainingCapacity();
        // Before the group goes: `grp` must not be left pointing at it.
        self.focusGroup(to);
        try self.dropGroup(g, removed);
    }

    /// The other way a group goes: its last tab was closed. Nothing to
    /// carry over, and focus goes where `closeGroup`'s would.
    pub fn closeEmptyGroup(self: *Ui, g: *Group) !void {
        const removed = self.layout.remove(g.id) catch return;
        // Before the group goes: `grp` must not be left pointing at it.
        // (`buf` already doesn't point anywhere -- its slot was the one
        // just closed -- and `focusGroup` replaces it without reading it.)
        self.focusGroup(self.groupById(removed.focus));
        try self.dropGroup(g, removed);
    }

    /// Takes an emptied group off the screen and frees it: its sibling
    /// takes the parent split's place (and size) in the host tree, and
    /// the group's own layers and split go. `g` must already be out of
    /// `layout`, its buffers gone, and `grp` pointing at another group.
    pub fn dropGroup(self: *Ui, g: *Group, removed: groups.Layout.Removed) !void {
        try self.replaceInListHolding(removed.replacement);
        self.client.destroySplit(removed.handle) catch {};
        self.client.destroySplit(g.col_split) catch {};
        self.client.destroyLayer(g.tabs_layer) catch {};
        self.client.destroyLayer(g.buffer_layer) catch {};
        // Its highlight went with the layer it was on.
        if (self.drop_shown) |d| {
            if (d.layer == g.tabs_layer or d.layer == g.buffer_layer) self.drop_shown = null;
        }
        if (self.tab_tip_group == g) {
            self.tab_tip_group = null;
            self.tab_tip_index = null;
            self.dismissTabTip();
        }
        for (self.group_list.items, 0..) |each, i| {
            if (each == g) {
                _ = self.group_list.orderedRemove(i);
                break;
            }
        }
        g.buffers.deinit(self.alloc);
        g.tab_spans.deinit(self.alloc);
        self.alloc.destroy(g);
        for (self.group_list.items) |each| each.markRedraw();
    }

    /// Ctrl+hjkl and Ctrl+W hjkl: the group (or the file tree) that way.
    pub fn focusToward(self: *Ui, dir: groups.Direction) void {
        if (self.focus == .tree) {
            // Out of the sidebar: whichever group faces it.
            if (dir != .right) return;
            const t = self.tree_bounds;
            const from: groups.Rect = .{ .row = t.row, .col = t.col, .cols = t.cols, .rows = t.rows };
            self.focusGroup(self.groupFacing(from, null, dir) orelse self.grp);
            return;
        }
        if (self.groupFacing(self.grp.rect(), self.grp, dir)) |g| {
            self.focusGroup(g);
        } else if (dir == .left and self.tree_visible) {
            self.setFocus(.tree);
        }
    }

    /// The group lying `dir` of the rect `from` -- a group's own (`self`
    /// is that group, left out of the search) or the file tree's.
    pub fn groupFacing(self: *Ui, from: groups.Rect, self_group: ?*Group, dir: groups.Direction) ?*Group {
        var rects: [max_groups + 1]groups.Rect = undefined;
        var owners: [max_groups + 1]?*Group = undefined;
        rects[0] = from;
        owners[0] = null;
        var n: usize = 1;
        for (self.group_list.items) |g| {
            if (n == rects.len) break;
            if (g == self_group) continue;
            rects[n] = g.rect();
            owners[n] = g;
            n += 1;
        }
        const hit = groups.neighbor(rects[0..n], 0, dir) orelse return null;
        return owners[hit];
    }

    /// Ctrl+W w / Ctrl+W Ctrl+W: the next group in reading order, with
    /// the file tree as the stop after the last one when it is showing --
    /// the same tree/buffer toggle the bare Ctrl+W was when there was
    /// only one group.
    pub fn cycleFocus(self: *Ui) !void {
        var order: std.ArrayList(groups.GroupId) = .empty;
        defer order.deinit(self.alloc);
        try self.layout.leavesInOrder(self.alloc, &order);
        if (self.focus == .tree) {
            self.focusGroup(self.groupById(order.items[0]));
            return;
        }
        const here = std.mem.indexOfScalar(groups.GroupId, order.items, self.grp.id) orelse 0;
        if (here + 1 < order.items.len) {
            self.focusGroup(self.groupById(order.items[here + 1]));
        } else if (self.tree_visible) {
            self.setFocus(.tree);
        } else {
            self.focusGroup(self.groupById(order.items[0]));
        }
    }

    /// Runs a window-level action (`Action.isUi`). False when it doesn't
    /// apply where the keyboard is -- the clipboard chords and the jumplist
    /// with the tree focused, Ctrl+Space outside insert mode -- so the key
    /// goes on to the tree or the editor as if unbound.
    pub fn performUi(self: *Ui, action: actions.Action) !bool {
        const in_buffer = self.focus == .buffer;
        switch (action) {
            .save => {
                self.save(null);
                self.status_dirty = true;
            },
            // The file finder, in every mode -- the chord every editor
            // with one uses. Insert mode included: vim's meaning of Ctrl+P
            // (previous completion) only applies with the completion popup
            // up, and `completionKey` takes it first then.
            .findFile => try self.openFinder(),
            .commandPalette => try self.openPalette(),
            .toggleTree => try self.toggleTree(),
            // Dotfiles and everything `.gitignore` excludes, in one flag --
            // the sidebar, both tree searches and Ctrl+P alike. Global so
            // it works from either pane: which files exist is a
            // session-wide question, not a sidebar-local one.
            .toggleHidden => try self.toggleHidden(),
            .toggleShell => self.toggleShell(),
            .nextTab => self.stepBuffer(true),
            .prevTab => self.stepBuffer(false),
            // vim's window prefix: the next key splits (`v`, `s`), closes
            // (`q`, `c`) or moves (`w`, a direction). See `windowCommand`.
            .windowPrefix => {
                self.window_prefix = true;
                self.status_dirty = true;
            },
            // To the editor group on that side, or from the leftmost one
            // into the file tree.
            .focusLeft => self.focusToward(.left),
            .focusRight => self.focusToward(.right),
            .focusUp => self.focusToward(.up),
            .focusDown => self.focusToward(.down),
            .moveTabLeft => try self.moveTabToward(.left),
            .moveTabRight => try self.moveTabToward(.right),
            .moveTabUp => try self.moveTabToward(.up),
            .moveTabDown => try self.moveTabToward(.down),
            // vim's jumplist chords, and the way back from a `gd` that
            // opened another file.
            .jumpBack, .jumpForward => {
                if (!in_buffer) return false;
                self.jumpStep(action == .jumpBack);
            },
            // Through the system clipboard. (Ctrl+Shift+C is swallowed by
            // glyphwire-host, which broadcasts a `copy_request` instead --
            // see the `.copy_request` arm.)
            .cut => {
                if (!in_buffer) return false;
                try self.applyOutcome(try self.buf.ed.clipboardCut());
                self.buf.full_redraw = true;
                self.grp.buffer_dirty = true;
                self.status_dirty = true;
            },
            .paste => {
                if (!in_buffer) return false;
                try self.pasteFromClipboard(true);
            },
            // Completions here and now, whatever has (or hasn't) been
            // typed. The space the chord also types is swallowed.
            .complete => {
                if (!in_buffer or self.buf.ed.mode != .insert) return false;
                self.swallow_space_text = true;
                self.closeCompletion();
                self.completion_empty_at = null;
                self.requestCompletion(null, true);
            },
            else => return false,
        }
        return true;
    }

    /// The key after Ctrl+W. Returns false for one that isn't a window
    /// command, which is then handled as itself -- vim would drop it, but
    /// a key that does something is less surprising than one that
    /// silently vanishes.
    pub fn windowCommand(self: *Ui, k: glyphwire.KeyEvent) !bool {
        const eq = std.mem.eql;
        const key = k.key;
        // Shift+H/J/K/L (or a Shift+arrow): take the shown tab that way.
        if (k.shift()) {
            const dir: ?groups.Direction = if (eq(u8, key, "h")) .left else focusDirection(key);
            if (dir) |d| {
                try self.moveTabToward(d);
                return true;
            }
        }
        if (eq(u8, key, "v")) {
            try self.splitGroup(.vertical, .after, null);
        } else if (eq(u8, key, "s")) {
            try self.splitGroup(.horizontal, .after, null);
        } else if (eq(u8, key, "q") or eq(u8, key, "c")) {
            try self.closeGroup();
        } else if (eq(u8, key, "w")) {
            try self.cycleFocus();
        } else if (eq(u8, key, "h")) {
            // Plain `h` here, not Ctrl+H (hidden files), so the whole of
            // vim's hjkl is available behind the prefix.
            self.focusToward(.left);
        } else if (focusDirection(key)) |dir| {
            self.focusToward(dir);
        } else {
            return false;
        }
        return true;
    }

    /// Reads each pane's bounds straight from the server -- used once at
    /// startup; after that `layout` notifications keep them current.
    ///
    /// **Startup only, and it cannot be used to recover from a resize.**
    /// `boundsOf` gets its size from `get_property("viewport")`, which
    /// the server answers with `Layer.viewportCols`/`viewportRows` --
    /// clamped to the layer's own content grid. It can therefore report a
    /// pane that shrank but never one that grew, and feeding the answer
    /// back into `syncContentSizes` latches the layer at its smallest
    /// size for good. It works here only because `init` has just created
    /// every layer at the full window size, so nothing is clamped yet.
    pub fn readBounds(self: *Ui) !void {
        self.tree_bounds = try self.boundsOf(self.tree_layer);
        for (self.group_list.items) |g| {
            g.tabs_bounds = try self.boundsOf(g.tabs_layer);
            g.buffer_bounds = try self.boundsOf(g.buffer_layer);
        }
        self.status_bounds = try self.boundsOf(self.status_layer);
        try self.syncContentSizes();
    }

    pub fn boundsOf(self: *Ui, layer: glyphwire.LayerHandle) !Bounds {
        const cell = try self.client.getLayerCellPosition(layer);
        const vp = try self.client.getLayerViewport(layer);
        return .{ .row = cell.row, .col = cell.col, .cols = vp.cols, .rows = vp.rows };
    }

    /// Keeps each layer's content grid in step with its pane.
    ///
    /// The buffer and statusline are exactly pane-sized: they're
    /// client-scrolled, so any extra content grid would just be memory
    /// nothing draws. The tree's is the larger of its listing and its
    /// pane on each axis -- larger so there is something to scroll,
    /// but never smaller, or the pane would be transparent below the last
    /// entry and the shell's scrollback would show through.
    pub fn syncContentSizes(self: *Ui) !void {
        for (self.group_list.items) |g| {
            if (g.buffer_bounds.cols > 0) {
                try self.client.setLayerSize(g.buffer_layer, g.buffer_bounds.cols, g.buffer_bounds.rows);
            }
            // The tab strip is client-scrolled the same way the buffer
            // is: its grid is exactly the pane, and a strip wider than
            // that is reported as a `content_extent` rather than drawn
            // into cells nothing shows.
            if (g.tabs_bounds.cols > 0) {
                try self.client.setLayerSize(g.tabs_layer, g.tabs_bounds.cols, 1);
            }
        }
        if (self.status_bounds.cols > 0) {
            try self.client.setLayerSize(self.status_layer, self.status_bounds.cols, 1);
        }
        if (self.tree_visible and self.tree_bounds.cols > 0) {
            try self.client.setLayerSize(
                self.tree_layer,
                self.treeContentCols(),
                self.treeContentRows(),
            );
        }
    }

    // ── Tree pane (treepane.zig) ────────────────────────────────────────
    pub const treeContentRows = treepane.treeContentRows;
    pub const treeListedRows = treepane.treeListedRows;
    pub const treeRowEntry = treepane.treeRowEntry;
    pub const treeContentCols = treepane.treeContentCols;
    pub const clampTreeScroll = treepane.clampTreeScroll;
    pub const endsTreeSearch = treepane.endsTreeSearch;
    pub const treeKey = treepane.treeKey;
    pub const treePageRows = treepane.treePageRows;
    pub const treeText = treepane.treeText;
    pub const treeMove = treepane.treeMove;
    pub const treeGoto = treepane.treeGoto;
    pub const scrollTreeToCursor = treepane.scrollTreeToCursor;
    pub const scrollTreeToRow = treepane.scrollTreeToRow;
    pub const treeScrollTop = treepane.treeScrollTop;
    pub const treeActivate = treepane.treeActivate;
    pub const startFind = treepane.startFind;
    pub const cancelFind = treepane.cancelFind;
    pub const findKey = treepane.findKey;
    pub const findText = treepane.findText;
    pub const refilterFind = treepane.refilterFind;
    pub const applyFind = treepane.applyFind;
    pub const startTreeCreate = treepane.startTreeCreate;
    pub const startTreeRename = treepane.startTreeRename;
    pub const showTreeEdit = treepane.showTreeEdit;
    pub const cancelTreeEdit = treepane.cancelTreeEdit;
    pub const treeEditKey = treepane.treeEditKey;
    pub const treeEditText = treepane.treeEditText;
    pub const commitTreeEdit = treepane.commitTreeEdit;
    pub const treeEditError = treepane.treeEditError;
    pub const retargetBuffers = treepane.retargetBuffers;

    // ── Loop ────────────────────────────────────────────────────────────

    pub fn run(self: *Ui) !void {
        self.startFileWatch();
        while (!self.quit) {
            // The window closed (SIGHUP) or zoe was told to stop: leave
            // the way `:q` would, minus the dirty-buffer guard -- there's
            // no one left to answer it.
            if (hangup.requested()) {
                _ = self.autosaveWorkspace();
                break;
            }
            // Before the frame: everything the language servers have said
            // since the last turn, so an arriving diagnostic is drawn in the
            // frame it arrived for rather than the one after.
            self.drainLsp();
            if (self.anyGroupDirty() or self.tree_dirty != .none or
                self.status_dirty or self.finder.dirty or self.palette.dirty or self.hover_dirty or self.completion_dirty or
                self.path_menu_dirty or self.tree_edit_dirty or self.tab_tip_dirty or self.tree_scroll_pending != null)
                try self.render();
            if (self.quit) break;
            // After the frame, not before: entering insert mode's frame
            // is what places the host's bar on the buffer layer's cursor,
            // and pointing the caret there first would flash it at
            // wherever that cursor last was.
            self.syncCaret();

            // Every notification wakes this -- layout and scroll included
            // -- so it blocks outright instead of polling on a timer. Then
            // everything already queued is folded into the same frame, in
            // the order it arrived (a drag's moves before its release, a
            // resize after the keystroke that preceded it).
            //
            // A language server's output arrives here too, without a
            // notification behind it: its reader thread parks the message and
            // calls `InputListener.wake`, which releases this with no event.
            // So the editor stays event-driven with a server attached -- no
            // polling interval, no latency floor.
            //
            // The one timed wait is the `didChange` debounce: while one is
            // armed, wait no longer than its deadline (see `armLspChange`).
            //
            // A background parse (a big file's highlighting) turns the wait
            // into a poll: take what has queued, then give the parse one
            // slice, so keys never sit behind more than one slice of it.
            //
            // So is an outstanding request's timeout: with one out, wait no
            // longer than it has left, so a server that never answers is
            // reported without needing a keystroke to notice.
            //
            // And the disk check: the open files are stat'ed for changes
            // made outside zoe (see `checkDisk`) once a second when
            // polling, so an idle zoe wakes on that beat too; or shortly
            // after inotify reports something, its thread having already
            // woken this wait (`armDiskCheck`).
            self.armLspChange();
            self.armDiskCheck();
            const timeout: std.Io.Timeout = if (self.nextLspDeadline()) |due|
                .{ .deadline = due }
            else
                .none;
            const parsing = self.highlightPending();
            const next = if (parsing) self.listener.pollNext() else try self.listener.next(timeout);
            if (next) |first| {
                const t_input = self.prof.now();
                try self.handleEvent(first);
                self.prof.events += 1;
                while (!self.quit) {
                    const ev = self.listener.pollNext() orelse break;
                    try self.handleEvent(ev);
                    self.prof.events += 1;
                }
                self.prof.add(.input, t_input);
            }
            if (parsing and !self.quit) {
                const t_parse = self.prof.now();
                self.stepHighlight();
                self.prof.add(.parse, t_parse);
            }
            // A wake with nothing queued, or the deadline passing: either way
            // this is where the debounced change goes out.
            if (self.lspChangeDue()) self.lspFlushChange();
            // The popup closes if its reason went away in that batch (insert
            // mode left, a click moved the cursor), before a delayed request
            // gets the chance to reopen it.
            self.syncCompletion();
            if (self.completionDue()) self.requestCompletion(null, false);
            if (self.tabTipDue()) self.showTabTip();
            if (self.diskCheckDue()) {
                self.checkDisk();
                try self.checkTreeDisk();
            }
            // After the events, before the frame they produced: a mode
            // change in that batch retimes the host's key repeat before
            // the user can hold anything down in the new mode.
            self.syncKeyRepeat();
        }
    }

    pub fn handleEvent(self: *Ui, ev: glyphwire.Event) !void {
        defer ev.deinit(self.alloc);
        // `exit` typed into the shell panel (or a shell that died): the
        // panel closes itself and the keyboard is the editor's again.
        if (self.shell.reapIfExited()) self.shellClosed();
        switch (ev) {
            .layout => |l| {
                if (l.boundsFor(self.tree_layer)) |b| self.tree_bounds = toBounds(b);
                for (self.group_list.items) |g| {
                    if (l.boundsFor(g.tabs_layer)) |b| g.tabs_bounds = toBounds(b);
                    if (l.boundsFor(g.buffer_layer)) |b| g.buffer_bounds = toBounds(b);
                }
                if (l.boundsFor(self.status_layer)) |b| self.status_bounds = toBounds(b);
                try self.syncContentSizes();
                // The buffer layers' grids were resized: the rows they
                // hold no longer line up with the panes, so the next frame
                // can't shift them -- it has to repaint. Every pane moved.
                for (self.group_list.items) |g| g.markRedraw();
                self.markTreeDirty(.full);
                self.status_dirty = true;
                // The popup is outside the split tree, so this
                // notification never mentions it -- but it is placed
                // against the buffer pane, which just moved.
                if (self.finder.isOpen()) self.finder.dirty = true;
                if (self.palette.isOpen()) self.palette.dirty = true;
                self.replaceShell();
            },
            // The shell panel's top edge was dragged. It floats over the
            // panes rather than squeezing them, so nothing else moves.
            .layer_resize => |lr| _ = self.shell.handleLayerResize(lr, self.winSize()),
            // The window (or this pane) changed size. Repaint, but take
            // no geometry from it: the `layout` that comes with it
            // carries the new pane rects, and is the only thing that
            // moves `*_bounds`.
            //
            // Nothing here reads the bounds back from the server, and
            // nothing ever should. `get_property`'s `viewport` is
            // `Layer.viewportCols`/`viewportRows`, which are **clamped to
            // the content grid** -- so a layer whose grid is 60 wide
            // reports a 60-wide viewport however wide its pane just
            // became. Feed that into `setLayerSize` and the pane latches
            // at whatever size it last shrank to: the grid can never grow
            // again, the area past it stays transparent, and the
            // scrollbar keeps measuring the small grid. Only `layout`
            // carries the true, unclamped rect.
            .resize => {
                // A font-size step arrives as a resize too, so the tree
                // icons' row height is re-read here, not only at startup.
                if (self.client.getCellMetrics()) |m| {
                    self.cell_px_h = m.h;
                } else |_| {}
                self.buf.full_redraw = true;
                self.grp.buffer_dirty = true;
                self.markTreeDirty(.full);
                self.grp.tabs_dirty = true;
                self.status_dirty = true;
                if (self.finder.isOpen()) self.finder.dirty = true;
                if (self.palette.isOpen()) self.palette.dirty = true;
                self.replaceShell();
            },
            .scroll_offset => |so| {
                // A wheel or thumb drag over the finder popup's list (the
                // checks below are for other layers, so it falls through).
                _ = self.finder.scrolled(so);
                _ = self.palette.scrolled(so);
                if (so.layer == self.tree_layer) self.tree_scroll = .{ .row = so.row, .col = so.col };
                // A wheel or thumb drag over the buffer pane: the host moved
                // the virtual offset and told us where. Follow it, and drag
                // the cursor along so it stays on screen (like vim's Ctrl-E /
                // Ctrl-Y). `pushed_bar` is updated so `syncBufferScrollbar`
                // doesn't immediately echo this straight back.
                //
                // The hover stays up through a scroll, deliberately: reading
                // the code around a definition with its docs still open is
                // what the wheel is for here. Only a button press closes it.
                //
                // Any group's pane, not just the focused one: the wheel
                // scrolls whatever is under the pointer.
                for (self.group_list.items) |g| {
                    if (so.layer == g.buffer_layer) self.scrollGroupTo(g, so.row, so.col);
                    // A shift+wheel or thumb drag over a tab strip. Only
                    // the column matters -- the strip is one row tall --
                    // and the offset is recorded as already pushed so
                    // `syncTabScrollbar` doesn't echo it straight back.
                    if (so.layer == g.tabs_layer and so.col != g.tab_scroll) {
                        g.tab_scroll = so.col;
                        g.pushed_tab_bar[1] = so.col;
                        g.tabs_dirty = true;
                    }
                }
            },
            // Focus came back or went away: the window, or a move to or
            // from this pane. Who draws the cursor changes with it
            // (`caretShape`), so the row it sits on has to be repainted --
            // zoe's own inverted cell has to come off before the host's
            // hollow box goes on, and back on afterwards.
            .focus => |f| {
                if (f.focused == self.has_focus) return;
                self.has_focus = f.focused;
                self.buf.full_redraw = true;
                self.grp.buffer_dirty = true;
            },
            // Only sent while this context follows the window theme, so
            // the host's copy is the one to take.
            .theme => try self.themeChanged(try self.client.getTheme()),
            .mouse_move => |m| {
                if (!self.shell.isFocused()) try self.handleMouseDrag(m);
                // The strip is never under the shell panel, so hovering a
                // tab works with it open too.
                self.trackTabHover(m.cell);
            },
            // `defer ev.deinit` above frees the button string.
            //
            // With the panel up, a press decides who has the keyboard: on
            // the panel it is the shell's (and the click is its selection,
            // not a move of the buffer cursor underneath), anywhere else
            // it is zoe's and the click does what it always does. The
            // panel stays on screen either way. A release follows its
            // press, so it reaches zoe only when the press did.
            .mouse_button => |m| {
                if (m.pressed and self.shell.isOpen()) {
                    if (self.shell.contains(m.cell)) self.focusShell() else self.blurShell();
                }
                if (!self.shell.isFocused()) try self.handleMouseButton(m);
            },
            else => if (ev.asInput()) |input| try self.handleInput(input),
        }
    }

    pub fn toBounds(b: glyphwire.LayoutBounds) Bounds {
        return .{ .row = b.row, .col = b.col, .cols = b.cols, .rows = b.rows };
    }

    pub fn handleInput(self: *Ui, ev: glyphwire.InputEvent) !void {
        // A keystroke on the `:` line, or a normal-mode key that turns
        // out to do nothing, leaves the buffer pane exactly as it was.
        // Snapshot the parts of the editor the buffer pane draws from so
        // `render` can skip repainting it (and re-running the syntax
        // pass) when none of them moved.
        const before = EdSnapshot.of(&self.buf.ed);
        // The editor's row motions break lines where the pane does, and a
        // resize, a split or a gutter widening can all move that.
        self.buf.ed.wrap_cols = self.textCols();

        switch (ev) {
            .key => |k| {
                // Every physical keystroke is two notifications, a press
                // and a release (see `KeyInput.reportKeyEvents`); acting
                // on both doubles every named-key command (arrows moved
                // two cells, a single Backspace deleted two characters,
                // ...). Only the press edge is a command -- a release
                // carries no motion/edit of its own.
                if (!k.pressed) return;

                // With the shell panel focused the keyboard is the
                // shell's: both programs are sent every keystroke (one
                // context, one input stream), so the only one taken here
                // is the key that closes it.
                if (self.shell.isFocused()) {
                    if (k.ctrl() and std.mem.eql(u8, k.key, "grave_accent")) self.toggleShell();
                    return;
                }

                // The Ctrl+P and Ctrl+Shift+P popups are modal: while
                // one is open it is the only thing reading keys, so
                // nothing below here runs.
                if (self.palette.isOpen()) {
                    try self.paletteKey(k);
                    return;
                }
                if (self.finder.isOpen()) {
                    try self.finderKey(k);
                    return;
                }

                // The key after Ctrl+W. A modifier pressed on the way to
                // it (letting go of Ctrl, reaching for Shift) is not it.
                if (self.window_prefix and !isModifierKey(k.key)) {
                    self.window_prefix = false;
                    self.status_dirty = true;
                    if (std.mem.eql(u8, k.key, "escape")) return;
                    // With or without Ctrl still held: Ctrl+W Ctrl+W is
                    // vim's cycle, the same as Ctrl+W w.
                    if (try self.windowCommand(k)) {
                        // A printable key also arrives as `text` straight
                        // after this, which would otherwise reach the
                        // editor (`v` entering visual mode).
                        if (!k.ctrl() and k.key.len == 1) self.swallow_window_text = true;
                        return;
                    }
                }

                // A leftover status/error message (`:q` on a dirty
                // buffer, an unknown command, ...) would otherwise sit in
                // the statusline forever -- nothing else ever clears it,
                // so it permanently hides the mode indicator underneath.
                // Vim clears it on the next keystroke; this is that.
                self.buf.ed.status.clearRetainingCapacity();

                // The hover popup is transient chrome, not a mode: the next
                // keystroke dismisses it and then does whatever it was going
                // to do. Escape is the exception -- it only dismisses, so
                // it doesn't also leave insert mode on the way out.
                // The tab tooltip goes the same way, without swallowing
                // anything: it was never what the keystroke was for.
                self.dismissTabTip();
                if (self.hover != null) {
                    _ = self.closeHover();
                    if (std.mem.eql(u8, k.key, "escape")) return;
                }
                self.swallow_space_text = false;
                // The completion popup reads its keys before the bindings
                // below: with it up, Ctrl+N / Ctrl+P move through it
                // rather than toggling the sidebar or opening the finder.
                if (self.completion != null and self.focus == .buffer and self.buf.ed.mode == .insert) {
                    if (try self.completionKey(k)) return;
                }
                // The same for the `:` line's filename popup, which also
                // owns Tab there whether it is up or not.
                if (self.focus == .buffer and self.buf.ed.mode == .command) {
                    if (try self.cmdlineKey(k)) return;
                }

                // Everything else is a binding (`actions.zig`), looked up
                // for the editor's mode -- the tree has no mode of its own
                // and reads the global table. The modifiers come off the
                // event itself, as they were when the host generated it:
                // asking the live down-set here would read a quick Ctrl+W
                // as a plain `w` whenever a heavy redraw left this loop
                // behind. The window-level actions are taken here, before
                // the editor sees the key, so they work in any mode.
                const scope = self.keyScope();
                // An extension's command is a binding like any other, and
                // runs from the tree as well as a buffer.
                if (self.extCommandFor(scope, k.key, k.mods)) |cmd| {
                    self.runExtCommand(cmd);
                    return;
                }
                const action = self.keymaps.lookup(scope, k.key, k.mods);
                if (action) |a| {
                    if (a.isUi() and try self.performUi(a)) return;
                }
                if (self.focus == .tree) {
                    try self.treeKey(k);
                    self.status_dirty = true;
                    return;
                }
                const was_insert = self.buf.ed.mode == .insert;
                try self.applyOutcome(try self.buf.ed.feedKey(k.key, k.mods));
                // An Enter on the `:` or `/` line just recorded it.
                self.flushHistories();
                try self.syncPathMenu();
                // Out of insert mode (into select mode, say), the popup has
                // nothing left to complete.
                if (self.completion != null and self.buf.ed.mode != .insert) self.closeCompletion();
                if (was_insert) {
                    if (action) |a| switch (a) {
                        .backspace, .deleteForward, .deleteWordBack, .deleteWordForward => self.afterInsertEdit(null),
                        else => {},
                    };
                }
            },
            .text => |t| {
                // Typed text is the shell's while its panel has focus -- it
                // has a line editor of its own.
                if (self.shell.isFocused()) return;
                if (self.palette.isOpen()) {
                    try self.palette.text(t.text);
                    return;
                }
                if (self.finder.isOpen()) {
                    try self.finder.text(t.text);
                    return;
                }
                if (self.swallow_space_text) {
                    self.swallow_space_text = false;
                    if (std.mem.eql(u8, t.text, " ")) return;
                }
                if (self.swallow_window_text) {
                    self.swallow_window_text = false;
                    return;
                }
                self.buf.ed.status.clearRetainingCapacity();
                if (self.focus == .tree) {
                    try self.treeText(t.text);
                    self.status_dirty = true;
                    return;
                }
                const was_insert = self.buf.ed.mode == .insert;
                try self.applyOutcome(try self.buf.ed.feedText(t.text));
                if (was_insert) self.afterInsertEdit(t.text);
                try self.syncPathMenu();
            },
            .paste => |t| {
                if (self.shell.isFocused()) return;
                if (self.palette.isOpen()) {
                    try self.palette.text(t.text);
                    return;
                }
                if (self.finder.isOpen()) {
                    try self.finder.text(t.text);
                    return;
                }
                self.buf.ed.status.clearRetainingCapacity();
                // A paste is not typing: it neither narrows nor opens the
                // popup.
                self.closeCompletion();
                if (self.focus == .buffer) {
                    // Insert mode and the two typed lines (`:` and `/`)
                    // all want the text *typed*, which is what `feedText`
                    // does for them -- a pasted search pattern belongs on
                    // the prompt, not in the buffer.
                    const typed = switch (self.buf.ed.mode) {
                        // Over a select-mode selection a paste is typing
                        // too: it replaces the selection.
                        .insert, .command, .search, .select => true,
                        .normal, .visual, .visual_line => false,
                    };
                    if (typed) {
                        try self.applyOutcome(try self.buf.ed.feedText(t.text));
                        try self.syncPathMenu();
                    } else {
                        // Normal / visual mode: splice the pasted text in
                        // like `p`, replacing any selection first, rather
                        // than obeying each character as a command.
                        try self.buf.ed.dropSelection();
                        try self.buf.ed.putText(t.text, true);
                        self.buf.full_redraw = true;
                        self.grp.buffer_dirty = true;
                    }
                }
            },
            // Ctrl+Shift+C with no host selection: glyphwire-host asks its
            // `"clipboard"` subscribers to supply the copy. Only answer
            // when zoe's context is the visible one -- the request is a
            // broadcast, and a backgrounded zoe would otherwise race the
            // shell's own answer.
            //
            // While the shell panel is up the request is its business
            // (it copies its own selection), not the buffer's.
            .copy_request => if (self.isVisible() and !self.shell.isFocused()) {
                try self.applyOutcome(try self.buf.ed.clipboardCopy());
                self.grp.buffer_dirty = true;
                self.status_dirty = true;
            },
            // The host closing already ends zoe's run loop when the shell
            // that spawned it exits; nothing persistent to flush here that
            // isn't already the user's explicit `:w`.
            .shutdown => {},
            // A window manager's own commands (see `InputEvent.window_key`).
            // Never delivered here: this program is not one.
            .window_key, .window_text => {},
        }

        // Any keystroke can change the status row -- the mode word, the
        // `:` line, the cursor position, a just-cleared error -- and it
        // is one row, so always redraw it. The buffer pane redraws only
        // when the editor state it shows actually moved.
        self.status_dirty = true;
        const after = EdSnapshot.of(&self.buf.ed);
        if (!after.eql(before)) self.grp.buffer_dirty = true;
        // The tab's `+` marker is the only thing the strip draws that a
        // keystroke can change.
        if (after.dirty != before.dirty) self.grp.tabs_dirty = true;
        // A `:set` moves the text origin or the width of a glyph, which a
        // row shift can't express -- the whole pane has to be
        // re-laid-out. These settings live on the `Editor`, and there is
        // one per buffer, so each is pushed to all of them: `:set` reads
        // as a session-wide switch, not a per-tab one.
        if (after.line_numbers != before.line_numbers or
            after.tab_width != before.tab_width or
            after.expand_tab != before.expand_tab or
            after.show_whitespace != before.show_whitespace or
            after.wrap != before.wrap or
            after.auto_indent != before.auto_indent or
            after.auto_close != before.auto_close or
            after.fold_column != before.fold_column)
        {
            self.buf.full_redraw = true;
            for (self.group_list.items) |g| {
                for (g.buffers.items) |slot| {
                    slot.ed.line_numbers = after.line_numbers;
                    slot.ed.tab_width = after.tab_width;
                    slot.ed.expand_tab = after.expand_tab;
                    slot.ed.show_whitespace = after.show_whitespace;
                    slot.ed.wrap = after.wrap;
                    slot.ed.auto_indent = after.auto_indent;
                    slot.ed.auto_close = after.auto_close;
                    slot.ed.fold_column = after.fold_column;
                    slot.full_redraw = true;
                }
                // The groups not being typed in show it too.
                g.buffer_dirty = true;
            }
        }
        // A visual selection touches whole rows, not just the caret's,
        // but `renderBuffer` diffs it against what the pane shows
        // (`Slot.prev_sel`) and repaints just the rows whose highlight
        // changed, so nothing beyond `buffer_dirty` (set above whenever
        // the mode, anchor or cursor moved) is needed here.
        // The search highlight is the same story: a new pattern, or `n`
        // moving which match is the current one, changes rows all over
        // the pane.
        if (after.match_hash != before.match_hash or after.match != before.match) {
            self.buf.full_redraw = true;
        }
    }

    /// Moves the focused pane. Only the tree's selected-row highlight
    /// depends on focus -- the buffer draws its caret the same either way
    /// -- and the statusline names the pane.
    pub fn setFocus(self: *Ui, to: Focus) void {
        if (self.focus == to) return;
        self.focus = to;
        // Leaving the tree abandons any search in it -- the prefix
        // describes where the tree cursor is, and the tree cursor stops
        // being what the keyboard drives.
        if (to != .tree) {
            self.cancelFind();
            // A half-typed name is abandoned the same way.
            self.cancelTreeEdit();
        }
        // Only the highlight appears or disappears: the listing itself is
        // untouched by a focus change.
        self.markTreeDirty(.selection);
        self.status_dirty = true;
    }

    pub fn toggleTree(self: *Ui) !void {
        self.tree_visible = !self.tree_visible;
        // Ctrl+B is also the shortest way *to* the sidebar, so showing it
        // focuses it: opening a pane you then have to Ctrl+W into is two
        // chords for one intention. Hiding it hands focus back.
        if (self.tree_visible) {
            self.focus = .tree;
        } else if (self.focus == .tree) {
            self.focus = .buffer;
            self.cancelFind();
        }
        // Dropping the layer from the split reclaims its columns but
        // leaves the layer itself mapped, and the host draws every mapped
        // layer's scrollbars in a pass of their own, over the top of
        // everything -- so a hidden sidebar left its scrollbar floating
        // down the middle of the buffer. Hiding the layer is what the
        // `visibility` property is for (see core.zig): the tree keeps its
        // cells, its scroll position and its metadata for when it comes
        // back.
        self.client.setLayerVisible(self.tree_layer, self.tree_visible) catch {};
        try self.applySplitChildren();
        // The buffer pane -- and the strip above it -- is about to be
        // re-laid-out wider or narrower.
        self.buf.full_redraw = true;
        self.grp.buffer_dirty = true;
        self.markTreeDirty(.full);
        self.grp.tabs_dirty = true;
        self.status_dirty = true;
    }

    /// Ctrl+H: flips "show everything" and re-reads the tree under it.
    ///
    /// The listing has to be rebuilt rather than re-filtered, because the
    /// rows that were hidden were never read (see `Tree.reload`) -- which
    /// is also why the open folders and the cursor are restored by path.
    /// A search in progress is dropped: its candidates are indices into
    /// the listing that is about to be replaced.
    pub fn toggleHidden(self: *Ui) !void {
        self.cancelFind();
        self.cancelTreeEdit();
        self.tree.visible.show_hidden = !self.tree.visible.show_hidden;
        self.tree.reload(self.io) catch {};
        self.clampTreeScroll();
        try self.syncContentSizes();
        self.scrollTreeToCursor();
        self.markTreeDirty(.full);
        self.buf.ed.setStatus("hidden files {s}", .{
            if (self.tree.visible.show_hidden) "shown" else "hidden",
        });
        self.status_dirty = true;
    }

    // ── Tree pane input ─────────────────────────────────────────────────

    // ── Tree pane search ────────────────────────────────────────────────

    // ── Sidebar create / rename ─────────────────────────────────────────

    /// A left-button press or release. In the buffer pane a press moves
    /// the caret and arms a drag (which turns into a visual selection the
    /// moment the pointer moves); a release with no move is a plain click
    /// that clears any selection. Elsewhere it falls through to the tree.
    /// glyphwire-host forwards these raw now that zoe owns its context --
    /// it only keeps drags that land on its own chrome (dividers,
    /// scrollbars).
    pub fn handleMouseButton(self: *Ui, ev: glyphwire.MouseButtonEvent) !void {
        // A click dismisses the popups the way a keystroke does, with any
        // button, and then does whatever it was going to do.
        if (ev.pressed) {
            _ = self.closeHover();
            self.closeCompletion();
            self.dismissTabTip();
        }
        if (!std.mem.eql(u8, ev.button, "left")) return;

        // While the finder is up it owns the pointer too: a result row
        // opens that file, anywhere outside the popup dismisses it, and
        // the click is swallowed either way -- a modal popup whose buffer
        // moves its cursor behind it is a trap. The release that follows
        // lands here with the popup already closed and nothing dragging,
        // so it does nothing.
        if (self.palette.isOpen()) {
            if (ev.pressed and self.palette.click(ev.cell) == .accept) try self.acceptPalette();
            return;
        }
        if (self.finder.isOpen()) {
            if (ev.pressed and self.finder.click(ev.cell) == .accept) try self.acceptFinder();
            return;
        }

        if (ev.pressed) {
            // A press anywhere in a group -- its strip or its pane -- gives
            // it the keyboard first, so what follows acts on that group.
            if (self.groupAt(ev.cell)) |g| {
                if (g != self.grp) self.focusGroup(g);
            }
            if (tabAt(self.grp, ev.cell)) |h| {
                if (h.close) {
                    try self.closeBuffer(h.index, false);
                } else {
                    self.setActive(h.index);
                    self.tab_drag = .{ .slot = self.buf, .start = ev.cell };
                }
                return;
            }
            if (self.foldMarkerAt(ev.cell)) |line| {
                try self.buf.ed.toggleFoldAt(line);
                self.focus = .buffer;
                self.grp.buffer_dirty = true;
                self.status_dirty = true;
                return;
            }
            if (self.cellInBuffer(ev.cell)) |byte| {
                self.drag = .{ .anchor = byte, .moved = false };
                if (self.buf.ed.hasSelection()) self.buf.ed.exitVisual();
                self.buf.ed.moveCursorTo(byte);
                // The host counted the clicks: a double selects the word
                // under the pointer, a triple its line, both on the press.
                switch (ev.clicks) {
                    2 => {
                        const w = motion.wordAt(&self.buf.ed.buf, byte);
                        self.drag = .{ .anchor = byte, .moved = true, .unit = .word, .word = .{ .start = w.start, .end = w.end } };
                        self.buf.ed.setVisualSelection(w.start, self.lastByteOf(w.start, w.end));
                    },
                    3 => {
                        self.drag = .{ .anchor = byte, .moved = true, .unit = .line };
                        self.buf.ed.setVisualLineSelection(byte, byte);
                    },
                    else => {},
                }
                self.focus = .buffer;
                self.buf.full_redraw = true;
                self.grp.buffer_dirty = true;
                self.status_dirty = true;
            } else {
                try self.handleTreeClick(ev);
            }
            return;
        }

        // Released.
        if (self.tab_drag) |td| {
            self.tab_drag = null;
            self.showDropTarget(null);
            if (td.moved) try self.dropTab(td.slot, ev.cell);
            return;
        }
        if (self.drag) |d| {
            self.drag = null;
            // A plain click (no drag): make sure no selection lingers.
            if (!d.moved and self.buf.ed.hasSelection()) {
                self.buf.ed.exitVisual();
            }
            // A selection dropped here is repainted by `renderBuffer`'s
            // selection diff, like any other change to it.
            self.grp.buffer_dirty = true;
            self.status_dirty = true;
        }
    }

    /// A pointer move with the left button down: extend the buffer-pane
    /// selection to the cell under the pointer, entering visual mode on
    /// the first real move.
    pub fn handleMouseDrag(self: *Ui, ev: glyphwire.MouseMoveEvent) !void {
        if (self.tab_drag) |*td| {
            // Closed from the keyboard with the button still down.
            if (self.findSlot(td.slot) == null) {
                self.tab_drag = null;
                self.showDropTarget(null);
                return;
            }
            if (!td.moved and (ev.cell.row != td.start.row or ev.cell.col != td.start.col)) {
                td.moved = true;
                // There is no ghost tab; the status line and the drop
                // target are what show a drag is on.
                self.buf.ed.setStatus("Moving tab \"{s}\" -- release over a tab strip or editor pane", .{tabs.labelFor(td.slot.ed.path)});
                self.status_dirty = true;
            }
            if (td.moved) self.showDropTarget(self.tabDropTarget(ev.cell));
            return;
        }
        if (self.drag) |*d| {
            const byte = self.cellToBufferByte(ev.cell);
            if (!d.moved) {
                if (byte == d.anchor) return;
                d.moved = true;
            } else if (motion.clampNormal(&self.buf.ed.buf, byte) == self.buf.ed.cursor) {
                // A new cell, but the same selection end -- past the end
                // of a line, or across the columns of one tab. Nothing to
                // redraw.
                return;
            }
            switch (d.unit) {
                .char => self.buf.ed.setVisualSelection(d.anchor, byte),
                .line => self.buf.ed.setVisualLineSelection(d.anchor, byte),
                // Whole words both ways: the far end of the word the
                // double-click landed on stays the anchor, and the moving
                // end snaps to the edge of the word under the pointer.
                .word => {
                    const w = motion.wordAt(&self.buf.ed.buf, byte);
                    if (byte < d.word.start) {
                        self.buf.ed.setVisualSelection(self.lastByteOf(d.word.start, d.word.end), w.start);
                    } else {
                        self.buf.ed.setVisualSelection(d.word.start, self.lastByteOf(w.start, w.end));
                    }
                },
            }
            // Just dirty: `renderBuffer` repaints the rows whose highlight
            // the step changed, not the whole pane.
            self.grp.buffer_dirty = true;
            self.status_dirty = true;
        }
    }

    /// Where a dragged tab lands when the button comes up over `cell`: on
    /// a tab strip, in front of the tab whose left half is under the
    /// pointer (`tabs.dropIndex`); on a group's pane, at the end of its
    /// tabs. Anywhere else -- the tree, the statusline, its own pane --
    /// it stays put.
    pub fn dropTab(self: *Ui, slot: *Slot, cell: glyphwire.CellPos) !void {
        self.buf.ed.status.clearRetainingCapacity();
        self.status_dirty = true;
        const to = self.groupAt(cell) orelse return;
        const strip = to.tabs_bounds;
        const on_strip = cell.row >= strip.row and cell.row < strip.row + strip.rows and
            cell.col >= strip.col and cell.col < strip.col + strip.cols;
        if (on_strip) {
            const index = tabs.dropIndex(to.tab_spans.items, cell.col - strip.col + to.tab_scroll);
            try self.moveTab(slot, to, index);
        } else if (to != self.grp) {
            try self.moveTab(slot, to, null);
        }
    }

    /// What a dragged tab released over `cell` would do, as the highlight
    /// that shows it -- the same cases `dropTab` acts on. On a strip, a
    /// bar at the gap the tab would land in (`tabs.dropIndex`), in screen
    /// columns since the strip is client-scrolled; on another group's
    /// pane, the whole pane. Null where the drop does nothing.
    pub fn tabDropTarget(self: *const Ui, cell: glyphwire.CellPos) ?DropShown {
        const to = self.groupAt(cell) orelse return null;
        const strip = to.tabs_bounds;
        const on_strip = cell.row >= strip.row and cell.row < strip.row + strip.rows and
            cell.col >= strip.col and cell.col < strip.col + strip.cols;
        if (on_strip) {
            const spans = to.tab_spans.items;
            const index = tabs.dropIndex(spans, cell.col - strip.col + to.tab_scroll);
            // The left edge of the tab it would go in front of, or the
            // right edge of the last one for the end.
            const at: usize = if (index < spans.len)
                spans[index].start
            else if (spans.len > 0)
                spans[spans.len - 1].end
            else
                0;
            return .{ .layer = to.tabs_layer, .target = .{ .insert = .{ .row = 0, .col = at -| to.tab_scroll, .rows = strip.rows } } };
        }
        if (to != self.grp) return .{ .layer = to.buffer_layer, .target = .layer };
        return null;
    }

    /// Moves the drop-target highlight to `want`, clearing it off the
    /// layer it was on if that changed. Silent when nothing did.
    pub fn showDropTarget(self: *Ui, want: ?DropShown) void {
        if (std.meta.eql(self.drop_shown, want)) return;
        if (self.drop_shown) |old| {
            if (want == null or want.?.layer != old.layer) self.client.setDropTarget(old.layer, null) catch {};
        }
        if (want) |w| self.client.setDropTarget(w.layer, w.target) catch {};
        self.drop_shown = want;
    }

    /// The offset of the last character in the `[start, end)` span of the
    /// active buffer -- where a visual selection, whose ends are both
    /// inclusive, has to stop to cover exactly that span. `start` for an
    /// empty one.
    pub fn lastByteOf(self: *const Ui, start: usize, end: usize) usize {
        if (end <= start) return start;
        return motion.prevCodepoint(&self.buf.ed.buf, end);
    }

    /// The tab under a root-grid cell, or null when the cell isn't in
    /// the strip. Screen columns are strip columns less the scroll, so
    /// the spans `renderTabs` recorded answer this directly.
    pub fn tabAt(g: *const Group, cell: glyphwire.CellPos) ?tabs.Hit {
        const b = g.tabs_bounds;
        if (b.cols == 0 or b.rows == 0) return null;
        if (cell.row < b.row or cell.row >= b.row + b.rows) return null;
        if (cell.col < b.col or cell.col >= b.col + b.cols) return null;
        return tabs.hit(g.tab_spans.items, cell.col - b.col + g.tab_scroll);
    }

    /// The group whose strip or pane is under `cell`, if any.
    pub fn groupAt(self: *const Ui, cell: glyphwire.CellPos) ?*Group {
        for (self.group_list.items) |g| {
            if (g.contains(cell)) return g;
        }
        return null;
    }

    /// Follows the pointer for the tab tooltip. Moving onto a tab arms its
    /// tooltip after `tab_tooltip_delay_ms`; moving off one takes it down.
    /// Moving straight from one tab to the next while a tooltip is up
    /// shows the next one at once -- the user is already reading paths, so
    /// making them wait again for each is only slower.
    ///
    /// The host has no pointer-left-the-window event, so a pointer that
    /// leaves the window from the strip leaves the tooltip up until the
    /// next move, key or click.
    pub fn trackTabHover(self: *Ui, cell: glyphwire.CellPos) void {
        var over_group: ?*Group = null;
        const over: ?usize = blk: {
            // A drag and the two popups own the pointer while they last.
            if (self.drag != null or self.tab_drag != null or self.finder.isOpen() or self.palette.isOpen()) break :blk null;
            const g = self.groupAt(cell) orelse break :blk null;
            const h = tabAt(g, cell) orelse break :blk null;
            if (h.index >= g.buffers.items.len) break :blk null;
            // `[No Name]` has no path to show.
            if (g.buffers.items[h.index].ed.path == null) break :blk null;
            over_group = g;
            break :blk h.index;
        };
        if (over == self.tab_tip_index and over_group == self.tab_tip_group) return;
        const was_shown = self.tab_tip_shown;
        self.tab_tip_index = over;
        self.tab_tip_group = over_group;
        self.tab_tip_due = null;
        if (was_shown) {
            self.tab_tip_shown = false;
            self.tab_tip_dirty = true;
        }
        if (over == null) return;
        const delay = self.tabTipDelayMs();
        if (was_shown or delay == 0) {
            self.showTabTip();
            return;
        }
        self.tab_tip_due = std.Io.Clock.Timestamp.fromNow(self.io, .{
            .raw = .fromMilliseconds(delay),
            .clock = .awake,
        });
    }

    pub fn tabTipDelayMs(self: *const Ui) i64 {
        const ms = if (self.hl_config) |cfg| cfg.tab_tooltip_delay_ms else langconf.tab_tooltip_delay_ms_default;
        return @intFromFloat(ms);
    }

    pub fn tabTipDue(self: *Ui) bool {
        const due = self.tab_tip_due orelse return false;
        return due.raw.durationTo(std.Io.Clock.awake.now(self.io)).toMilliseconds() >= 0;
    }

    pub fn showTabTip(self: *Ui) void {
        self.tab_tip_due = null;
        if (self.tab_tip_index == null) return;
        self.tab_tip_shown = true;
        self.tab_tip_dirty = true;
    }

    /// Takes the tooltip down (or stops it going up) for a key or click. The
    /// hovered tab is kept, so it doesn't come straight back on the next
    /// pointer move within the same tab.
    pub fn dismissTabTip(self: *Ui) void {
        self.tab_tip_due = null;
        if (!self.tab_tip_shown) return;
        self.tab_tip_shown = false;
        self.tab_tip_dirty = true;
    }

    /// The buffer line whose fold-column cell `cell` is, or null when
    /// it isn't one: off the column, a wrapped line's continuation row,
    /// or below the buffer's end.
    pub fn foldMarkerAt(self: *Ui, cell: glyphwire.CellPos) ?usize {
        if (self.foldWidth() == 0) return null;
        const b = self.grp.buffer_bounds;
        if (cell.row < b.row or cell.row >= b.row + b.rows) return null;
        if (cell.col != b.col + self.signWidth()) return null;
        self.layoutRows() catch return null;
        const r = cell.row - b.row;
        if (r >= self.row_map.items.len) return null;
        const rv = self.row_map.items[r];
        if (rv.sub > 0 or rv.line >= self.buf.ed.buf.lineCount()) return null;
        return rv.line;
    }

    /// The buffer byte offset under grid cell `cell`, or null if the
    /// cell isn't inside the buffer pane -- the test a press uses to
    /// decide between a buffer drag and a tree click.
    pub fn cellInBuffer(self: *Ui, cell: glyphwire.CellPos) ?usize {
        const b = self.grp.buffer_bounds;
        if (b.cols == 0 or b.rows == 0) return null;
        if (cell.row < b.row or cell.row >= b.row + b.rows) return null;
        if (cell.col < b.col or cell.col >= b.col + b.cols) return null;
        return self.cellToBufferByte(cell);
    }

    /// The buffer byte offset under grid cell `cell`, clamping the cell
    /// into the buffer pane first so a drag that wanders out of the pane
    /// still tracks its nearest edge.
    pub fn cellToBufferByte(self: *Ui, cell: glyphwire.CellPos) usize {
        const b = self.grp.buffer_bounds;
        const rows = @max(b.rows, 1);
        const screen_row = std.math.clamp(cell.row, b.row, b.row + rows - 1) - b.row;
        const last_line = self.buf.ed.buf.lineCount() - 1;
        self.layoutRows() catch return self.buf.ed.buf.lineStart(@min(self.buf.top_line, last_line));
        var rv: RowView = if (screen_row < self.row_map.items.len)
            self.row_map.items[screen_row]
        else
            .{ .line = last_line + 1, .sub = 0, .left = self.buf.left_col, .cols = self.textCols(), .last = true };
        const line = @min(rv.line, last_line);

        const line_text = self.buf.ed.buf.lineText(self.alloc, line) catch
            return self.buf.ed.buf.lineStart(line);
        defer self.alloc.free(line_text);
        const opts = self.displayOpts();
        // Below the end of the buffer: the last line's last row, as if
        // the click had landed on it.
        if (rv.line > last_line and self.buf.ed.wrap) {
            const place = softwrap.rowAt(line_text, opts, self.textCols(), std.math.maxInt(usize));
            rv = .{ .line = line, .sub = place.index, .left = place.row.start_col, .cols = place.row.end_col - place.row.start_col, .last = true };
        }

        const text_left = b.col + self.gutterWidth();
        const rel_col = if (cell.col > text_left) cell.col - text_left else 0;
        var dcol = rv.left + rel_col;
        // Past the end of a wrapped row that isn't its line's last is
        // still that row, not the start of the next one.
        if (!rv.last and rv.cols > 0 and dcol >= rv.left + rv.cols) dcol = rv.left + rv.cols - 1;

        return self.buf.ed.buf.lineStart(line) + display.byteAtCol(line_text, dcol, opts);
    }

    /// Whether zoe's context is the one currently on screen. Used to
    /// ignore broadcasts (`copy_request`) meant for whoever is visible.
    /// Assumes visible until the first `context` notification arrives.
    pub fn isVisible(self: *Ui) bool {
        const vc = self.listener.visibleContext() orelse return true;
        return vc.context == self.context;
    }

    pub fn handleTreeClick(self: *Ui, ev: glyphwire.MouseButtonEvent) !void {
        if (!self.tree_visible) return;
        // The click reports a root-grid cell; the panes are laid out on
        // that same grid, so a hit test is just the pane's bounds.
        const b = self.tree_bounds;
        if (ev.cell.row < b.row or ev.cell.row >= b.row + b.rows) return;
        if (ev.cell.col < b.col or ev.cell.col >= b.col + b.cols) return;
        // A click abandons a name being typed -- and takes the virtual
        // row with it, so the index below is the tree's own.
        self.cancelTreeEdit();

        const index = self.tree_scroll.row + (ev.cell.row - b.row);
        if (index >= self.tree.len()) return;
        // A click is a new starting point, so it drops any search the way
        // every other cursor move does.
        self.cancelFind();
        self.setFocus(.tree);
        self.treeGoto(index);
        try self.treeActivate();
        self.status_dirty = true;
    }

    // ── `:` line filename completion ────────────────────────────────────

    // ── Command line (cmdline.zig) ──────────────────────────────────────
    pub const cmdlineKey = cmdline.cmdlineKey;
    pub const completePath = cmdline.completePath;
    pub const acceptPathPick = cmdline.acceptPathPick;
    pub const syncPathMenu = cmdline.syncPathMenu;
    pub const closePathMenu = cmdline.closePathMenu;
    pub const scanPathMatches = cmdline.scanPathMatches;
    pub const replaceCmdline = cmdline.replaceCmdline;
    pub const pathMenuRows = cmdline.pathMenuRows;
    pub const renderPathMenu = cmdline.renderPathMenu;
    pub const loadHistories = cmdline.loadHistories;
    pub const loadHistory = cmdline.loadHistory;
    pub const flushHistories = cmdline.flushHistories;
    pub const flushHistory = cmdline.flushHistory;

    // ── Command-line history ────────────────────────────────────────────

    // ── Editor outcomes ─────────────────────────────────────────────────

    /// A path typed on the `:` line, with `~` read the way the shell reads
    /// it. Without this `:e ~/x` opened an empty buffer for a file
    /// literally named `./~/x`, which `:w` then had no directory to write.
    pub fn expandArg(self: *const Ui, arg: ?[]const u8, buf: []u8) ?[]const u8 {
        const a = arg orelse return null;
        return homepath.expandHome(a, self.environ.get("HOME"), buf);
    }

    pub fn applyOutcome(self: *Ui, outcome: editor.Outcome) !void {
        var home_buf: [std.fs.max_path_bytes]u8 = undefined;
        switch (outcome) {
            .none => {},
            .write => |target| self.save(self.expandArg(target, &home_buf)),
            .write_quit => |target| {
                self.save(self.expandArg(target, &home_buf));
                if (self.buf.ed.buf.dirty) return;
                if (self.refuseQuitForDirtyBuffer()) return;
                if (!self.autosaveWorkspace()) return;
                self.quit = true;
            },
            // `:q!` leaves the workspace file as it was, the way it
            // leaves every other file.
            .quit => |q| {
                if (!q.force) {
                    if (self.refuseQuitForDirtyBuffer()) return;
                    if (!self.autosaveWorkspace()) return;
                }
                self.quit = true;
            },
            // `:e <path>` opens a tab; a bare `:e` re-reads this one.
            .edit => |target| {
                if (self.expandArg(target, &home_buf)) |t| try self.openFile(t) else try self.reloadCurrent();
            },
            .buffer_step => |b| self.stepBuffer(b.forward),
            .buffer_close => |b| try self.closeBuffer(self.grp.active, b.force),
            .split => |sp| try self.splitGroup(if (sp.vertical) .vertical else .horizontal, .after, self.expandArg(sp.path, &home_buf)),
            .close_group => try self.closeGroup(),
            .chdir => |target| self.changeDir(target),
            .add_folder => |target| try self.addFolder(self.expandArg(target, &home_buf)),
            .remove_folder => |target| try self.removeFolder(self.expandArg(target, &home_buf)),
            .ws_save => |target| _ = self.workspaceSave(self.expandArg(target, &home_buf)),
            .ws_open => |o| {
                const path = self.expandArg(o.path, &home_buf) orelse {
                    self.buf.ed.setStatus("E471: Argument required", .{});
                    self.status_dirty = true;
                    return;
                };
                if (!o.force and self.refuseQuitForDirtyBuffer()) return;
                try self.workspaceOpen(path);
            },
            .pwd => {
                var buf: [std.fs.max_path_bytes]u8 = undefined;
                const n = std.process.currentPath(self.io, &buf) catch {
                    self.buf.ed.setStatus("E: cannot read working directory", .{});
                    return;
                };
                self.buf.ed.setStatus("{s}", .{buf[0..n]});
            },
            // The editor filled `ed.yank`; mirror it to the system
            // clipboard (glyphwire-host pushes it on to the OS).
            .set_clipboard => |text| self.client.setClipboard(text) catch {},
            // `p` / `P`: the editor can't read the clipboard, so pull it
            // here and hand the text back.
            .paste => |p| try self.pasteFromClipboard(p.after),

            // The language-server commands. The editor core named them; the
            // servers, the diagnostics and the jumplist all live here.
            .lsp_hover => self.requestLsp(.hover),
            .lsp_definition => self.requestLsp(.definition),
            .diag_step => |d| self.stepDiagnostic(d.forward),
            .lsp_status => |arg| self.lspStatus(arg),
            .diag_list => self.diagList(),
            .theme => |arg| self.themeCommand(arg),
            .shell_position => |arg| self.shellPositionCommand(arg),
        }
    }

    /// Fetches the system clipboard and splices it into the buffer at the
    /// cursor (`p` / `P`, and the Ctrl+Shift+P chord). A visual-mode `p`
    /// has already dropped the selection, so this is always a plain
    /// insert.
    pub fn pasteFromClipboard(self: *Ui, after: bool) !void {
        const text = self.client.getClipboard() catch return;
        defer self.alloc.free(text);
        if (text.len == 0) return;
        try self.buf.ed.putText(text, after);
        // A paste can add lines and move the text origin; repaint the pane.
        self.buf.full_redraw = true;
        self.grp.buffer_dirty = true;
        self.status_dirty = true;
    }

    /// `:cd` -- change the process working directory and re-root the
    /// file tree there. `target` is null for `$HOME`, `"-"` for the
    /// previous directory, `~/...` for a home-relative path, or a plain
    /// path. The previous directory is remembered for the next `:cd -`.
    pub fn changeDir(self: *Ui, target: ?[]const u8) void {
        var home_buf: [std.fs.max_path_bytes]u8 = undefined;
        const dest: []const u8 = blk: {
            const t = target orelse break :blk self.environ.get("HOME") orelse {
                self.buf.ed.setStatus("E: $HOME not set", .{});
                return;
            };
            if (std.mem.eql(u8, t, "-")) break :blk self.prev_cwd orelse {
                self.buf.ed.setStatus("E: no previous directory", .{});
                return;
            };
            break :blk homepath.expandHome(t, self.environ.get("HOME"), &home_buf);
        };

        // Remember the current directory before leaving it.
        var cur_buf: [std.fs.max_path_bytes]u8 = undefined;
        const cur_n = std.process.currentPath(self.io, &cur_buf) catch 0;

        std.process.setCurrentPath(self.io, dest) catch {
            self.buf.ed.setStatus("E344: Can't chdir to \"{s}\"", .{dest});
            return;
        };

        if (cur_n > 0) {
            if (self.alloc.dupe(u8, cur_buf[0..cur_n])) |owned| {
                if (self.prev_cwd) |p| self.alloc.free(p);
                self.prev_cwd = owned;
            } else |_| {}
        }

        var new_buf: [std.fs.max_path_bytes]u8 = undefined;
        const new_n = std.process.currentPath(self.io, &new_buf) catch 0;
        const new_root = if (new_n > 0) new_buf[0..new_n] else dest;

        // A workspace's folders aren't the cwd, so `:cd` leaves them be:
        // it moves where relative paths resolve and nothing else.
        if (self.tree.multiRoot()) {
            self.buf.ed.setStatus("{s}", .{new_root});
            self.status_dirty = true;
            return;
        }

        // Re-root the tree at the resolved absolute cwd. (A name field
        // can't be up -- `:cd` is typed in the buffer pane, and leaving
        // the tree closed it -- but its rows are about to vanish.)
        self.cancelTreeEdit();

        if (Tree.init(self.alloc, self.io, new_root, self.tree.visible)) |fresh| {
            // A search's candidates are indices into the listing that is
            // about to be replaced.
            self.cancelFind();
            self.tree.deinit();
            self.tree = fresh;
            self.tree_scroll = .{};
            self.tree_scroll_pending = null;
            self.client.setLayerScrollOffset(self.tree_layer, 0, 0) catch {};
            self.syncContentSizes() catch {};
        } else |_| {}

        self.markTreeDirty(.full);
        self.status_dirty = true;
        self.buf.ed.setStatus("{s}", .{new_root});
    }

    // ── Workspace folders ───────────────────────────────────────────────

    /// `:addfolder <dir>` -- another folder in the sidebar, at the end,
    /// open. The first one added to a single-folder tree turns it into a
    /// workspace: the existing folder gets a header of its own.
    pub fn addFolder(self: *Ui, target: ?[]const u8) !void {
        self.status_dirty = true;
        const t = target orelse {
            self.buf.ed.setStatus("E471: Argument required", .{});
            return;
        };
        // Normalized, so `../x` and `x/` name the folder the same way the
        // tree's root list does and a duplicate is caught.
        const abs = homepath.absolute(self.io, self.alloc, t) catch |err| {
            self.buf.ed.setStatus("E: {s}: {t}", .{ t, err });
            return;
        };
        defer self.alloc.free(abs);
        const st = std.Io.Dir.cwd().statFile(self.io, abs, .{}) catch {
            self.buf.ed.setStatus("E: no such directory: {s}", .{abs});
            return;
        };
        if (st.kind != .directory) {
            self.buf.ed.setStatus("E: not a directory: {s}", .{abs});
            return;
        }

        // Row indices are about to move under both.
        self.cancelFind();
        self.cancelTreeEdit();
        const name = zoe_workspace.defaultName(abs);
        if (!try self.tree.addRoot(self.io, .{ .path = abs, .name = name })) {
            self.buf.ed.setStatus("\"{s}\" is already in the workspace", .{abs});
            return;
        }
        if (self.lsp_pool) |*pool| pool.addFolder(abs, name) catch {};
        if (self.tree.headerRow(self.tree.roots.items.len - 1)) |row| self.tree.cursor = row;
        try self.treeChanged();
        self.buf.ed.setStatus("added folder {s}", .{abs});
    }

    /// `:rmfolder [dir]` -- takes a folder out of the sidebar (never off
    /// the disk): the one named, or the one the tree's cursor is in.
    /// The last folder stays.
    pub fn removeFolder(self: *Ui, target: ?[]const u8) !void {
        self.status_dirty = true;
        const index: usize = if (target) |t| blk: {
            const abs = homepath.absolute(self.io, self.alloc, t) catch |err| {
                self.buf.ed.setStatus("E: {s}: {t}", .{ t, err });
                return;
            };
            defer self.alloc.free(abs);
            break :blk self.tree.rootIndex(abs) orelse {
                self.buf.ed.setStatus("E: not a workspace folder: {s}", .{abs});
                return;
            };
        } else blk: {
            const e = self.tree.at(self.tree.cursor) orelse {
                self.buf.ed.setStatus("E471: Argument required", .{});
                return;
            };
            break :blk e.root;
        };
        if (!self.tree.multiRoot()) {
            self.buf.ed.setStatus("E: can't remove the only folder", .{});
            return;
        }

        self.cancelFind();
        self.cancelTreeEdit();
        const path = try self.alloc.dupe(u8, self.tree.roots.items[index].path);
        defer self.alloc.free(path);
        try self.tree.removeRoot(self.io, index);
        if (self.lsp_pool) |*pool| pool.removeFolder(path);
        try self.treeChanged();
        self.buf.ed.setStatus("removed folder {s}", .{path});
    }

    // ── Workspace files ─────────────────────────────────────────────────
    //
    // `:wssave` writes the session to a `.zoe-workspace` (zoe/workspace.zig):
    // the sidebar's folders, the editor groups with their tabs, which group
    // has the keyboard, and the theme when it is this editor's own.
    // `:wsopen` and `zoe x.zoe-workspace` bring one back.

    /// `:wssave [file]`: the named file, or the one this session was
    /// opened from or last saved to. A name with no workspace extension
    /// gets `.zoe-workspace`. False when nothing was written; the
    /// status line says why.
    pub fn workspaceSave(self: *Ui, target: ?[]const u8) bool {
        self.status_dirty = true;
        const path = target orelse self.ws_file orelse {
            self.buf.ed.setStatus("E32: No workspace file name (:wssave <file>)", .{});
            return false;
        };
        var arena_state = std.heap.ArenaAllocator.init(self.alloc);
        defer arena_state.deinit();
        const snap = self.workspaceSnapshot(arena_state.allocator()) catch |err| {
            self.buf.ed.setStatus("E: can't save the workspace ({t})", .{err});
            return false;
        };
        var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
        const cwd_n = std.process.currentPath(self.io, &cwd_buf) catch {
            self.buf.ed.setStatus("E: cannot read working directory", .{});
            return false;
        };
        const abs = zoe_workspace.save(self.alloc, self.io, cwd_buf[0..cwd_n], path, snap) catch |err| {
            switch (err) {
                error.VscodeWorkspace => self.buf.ed.setStatus("E: zoe doesn't write .code-workspace files; save to a .zoe-workspace", .{}),
                else => self.buf.ed.setStatus("E212: Can't write workspace {s} ({t})", .{ path, err }),
            }
            return false;
        };
        // `path` may be the old `ws_file`; it isn't read past `save`.
        if (self.ws_file) |old| self.alloc.free(old);
        self.ws_file = abs;
        self.buf.ed.setStatus("workspace saved: {s}", .{abs});
        return true;
    }

    /// On the way out (`:q`, `:wq`, the window closing): rewrites the
    /// `.zoe-workspace` this session was opened from or last saved to,
    /// unless `workspace_autosave = false`. A session with no such file
    /// (plain directories, a `.code-workspace`) has nothing to write.
    /// False when the write failed, which `:q` takes as a reason to stay;
    /// `:q!` doesn't ask.
    pub fn autosaveWorkspace(self: *Ui) bool {
        if (self.ws_file == null) return true;
        if (self.hl_config) |cfg| if (!cfg.workspace_autosave) return true;
        return self.workspaceSave(null);
    }

    /// What `:wssave` writes, borrowing from the tree, the slots and `th`
    /// -- valid until any of them changes. `arena` holds the rest.
    pub fn workspaceSnapshot(self: *Ui, arena: std.mem.Allocator) !zoe_workspace.Snapshot {
        const folders = try arena.alloc(zoe_workspace.FolderSpec, self.tree.roots.items.len);
        for (self.tree.roots.items, folders) |r, *f| f.* = .{ .path = r.path, .name = r.name };
        return .{
            .folders = folders,
            .theme = if (self.theme_own) self.th.name() else null,
            .editors = try self.snapshotNode(arena, self.layout.root),
        };
    }

    pub fn snapshotNode(self: *Ui, arena: std.mem.Allocator, node: *const groups.Node) !*const zoe_workspace.EditorNode {
        const out = try arena.create(zoe_workspace.EditorNode);
        switch (node.kind) {
            .split => |s| {
                const ratio = try self.splitRatio(s.handle);
                out.* = .{ .split = .{
                    .orientation = switch (s.axis) {
                        .vertical => .vertical,
                        .horizontal => .horizontal,
                    },
                    .ratio = ratio,
                    .first = try self.snapshotNode(arena, s.first),
                    .second = try self.snapshotNode(arena, s.second),
                } };
            },
            .leaf => |id| {
                const g = self.groupById(id);
                var files: std.ArrayList([]const u8) = .empty;
                var active: usize = 0;
                for (g.buffers.items, 0..) |slot, i| {
                    // A scratch buffer has no file to come back from.
                    const abs = self.slotAbs(slot) orelse continue;
                    if (i == g.active) active = files.items.len;
                    try files.append(arena, abs);
                }
                out.* = .{ .group = .{ .files = files.items, .active = active, .focused = g == self.grp } };
            },
        }
        return out;
    }

    /// The first child's share of a two-child split, as the host holds
    /// it now: the weights the user dragged the band to, read back with
    /// `get_split`. A split whose children aren't both weighted (none of
    /// zoe's, today) falls back to the cells each took at the last layout.
    pub fn splitRatio(self: *Ui, handle: glyphwire.SplitHandle) !f32 {
        var state = try self.client.getSplit(handle);
        defer state.deinit();
        const children = state.value().children;
        if (children.len != 2) return 0.5;
        const a = children[0];
        const b = children[1];
        if (a.weight != null and b.weight != null) {
            const wa = @max(a.weight.?, 0);
            const wb = @max(b.weight.?, 0);
            return if (wa + wb <= 0) 0.5 else wa / (wa + wb);
        }
        const total = a.extent + b.extent;
        return if (total == 0) 0.5 else @as(f32, @floatFromInt(a.extent)) / @as(f32, @floatFromInt(total));
    }

    /// `:wsopen <file>`: the workspace's folders replace the sidebar's,
    /// every tab closes and its editor groups come back in their place,
    /// and its theme (or, when it names none, zoe's usual choice) applies.
    /// The caller has already refused it over a modified buffer.
    pub fn workspaceOpen(self: *Ui, path: []const u8) !void {
        self.status_dirty = true;
        var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
        const cwd_n = std.process.currentPath(self.io, &cwd_buf) catch {
            self.buf.ed.setStatus("E: cannot read working directory", .{});
            return;
        };
        const cwd = cwd_buf[0..cwd_n];
        var ws = zoe_workspace.load(self.alloc, self.io, cwd, path) catch |err| {
            self.buf.ed.setStatus("E: can't read workspace {s} ({t})", .{ path, err });
            return;
        };
        defer ws.deinit();
        // From here on only `abs` names the file: `path` may borrow the
        // `:` line of an editor `resetEditors` is about to free.
        const abs = try std.fs.path.resolve(self.alloc, &.{ cwd, path });
        errdefer self.alloc.free(abs);

        try self.replaceFolders(ws.folders.items);
        // The first folder becomes the cwd, as it does on the command line.
        std.process.setCurrentPath(self.io, ws.folders.items[0].path) catch {};
        try self.resetEditors();
        var restore_err: ?anyerror = null;
        if (ws.editors) |e| self.restoreEditors(e.root) catch |err| {
            restore_err = err;
        };
        const theme_found = self.applyWorkspaceTheme(ws.theme);

        if (!theme_found) {
            self.buf.ed.setStatus("E185: Cannot find color scheme '{s}' (workspace theme ignored)", .{ws.theme.?});
        } else if (restore_err) |err| {
            self.buf.ed.setStatus("E: couldn't restore the workspace's editors ({t})", .{err});
        } else {
            self.buf.ed.setStatus("workspace: {s}", .{abs});
        }

        // Only zoe's own format is somewhere a bare `:wssave` may write.
        if (self.ws_file) |old| self.alloc.free(old);
        self.ws_file = null;
        if (zoe_workspace.formatOf(abs) == .zoe) self.ws_file = abs else self.alloc.free(abs);
    }

    /// Re-roots the sidebar on `folders`, telling the language servers
    /// which folders came and went.
    pub fn replaceFolders(self: *Ui, folders: []const zoe_workspace.Folder) !void {
        const specs = try self.alloc.alloc(Tree.RootSpec, folders.len);
        defer self.alloc.free(specs);
        for (folders, specs) |f, *s| s.* = .{ .path = f.path, .name = f.name };
        const fresh = try Tree.initRoots(self.alloc, self.io, specs, self.tree.visible);

        // Row indices are about to mean nothing.
        self.cancelFind();
        self.cancelTreeEdit();
        if (self.lsp_pool) |*pool| {
            // New folders first, so a server never sees an empty workspace.
            for (folders) |f| {
                if (self.tree.rootIndex(f.path) == null) pool.addFolder(f.path, f.name) catch {};
            }
            for (self.tree.roots.items) |r| {
                const kept = for (folders) |f| {
                    if (std.mem.eql(u8, f.path, r.path)) break true;
                } else false;
                if (!kept) pool.removeFolder(r.path);
            }
        }
        self.tree.deinit();
        self.tree = fresh;
        self.tree_scroll = .{};
        self.tree_scroll_pending = null;
        self.client.setLayerScrollOffset(self.tree_layer, 0, 0) catch {};
        try self.treeChanged();
    }

    /// Closes every tab and every group but one, leaving the single group
    /// with one scratch buffer that a fresh zoe starts with. Modified
    /// buffers are thrown away: callers check first.
    pub fn resetEditors(self: *Ui) !void {
        self.tab_drag = null;
        self.showDropTarget(null);
        self.drag = null;
        _ = self.closeHover();
        self.closeCompletion();
        self.dismissTabTip();
        self.tab_tip_group = null;
        self.tab_tip_index = null;
        while (self.group_list.items.len > 1) {
            const g = self.group_list.items[self.group_list.items.len - 1];
            const removed = self.layout.remove(g.id) catch break;
            // While `g` still has its tabs: `focusGroup` repaints it.
            if (g == self.grp) self.focusGroup(self.groupById(removed.focus));
            self.releaseSlots(g);
            try self.dropGroup(g, removed);
        }
        const g = self.grp;
        const fresh = try self.newSlot(null);
        self.releaseSlots(g);
        g.buffers.append(self.alloc, fresh) catch |err| {
            fresh.deinit(self.alloc);
            return err;
        };
        g.active = 0;
        g.tab_scroll = 0;
        self.buf = fresh;
        g.markRedraw();
    }

    /// Closes and frees every buffer in `g`, leaving its list empty.
    pub fn releaseSlots(self: *Ui, g: *Group) void {
        for (g.buffers.items) |slot| {
            self.lspDidClose(slot);
            slot.deinit(self.alloc);
        }
        g.buffers.clearRetainingCapacity();
    }

    /// Rebuilds a saved `editors` tree from the single group zoe has at
    /// startup (or after `resetEditors`): each split grows a group off the
    /// one before it, each group opens its files, and the saved group gets
    /// the keyboard. The split proportions go on last, once every split
    /// they name exists: each new split starts out at even weights.
    pub fn restoreEditors(self: *Ui, root: *const zoe_workspace.EditorNode) !void {
        std.debug.assert(self.group_list.items.len == 1);
        var focus: ?*Group = null;
        try self.restoreNode(root, self.grp, &focus);
        try self.applyRatios(self.layout.root, root);
        if (focus) |g| self.focusGroup(g);
        for (self.group_list.items) |each| each.markRedraw();
    }

    pub fn restoreNode(self: *Ui, node: *const zoe_workspace.EditorNode, g: *Group, focus: *?*Group) !void {
        switch (node.*) {
            .split => |s| {
                // `g` keeps the first half, as `:vsplit` / `:split` leave
                // it, so the layout grows the same shape the file has.
                const g2 = try self.insertGroup(g, switch (s.orientation) {
                    .vertical => .vertical,
                    .horizontal => .horizontal,
                }, .after);
                const scratch = try self.newSlot(null);
                g2.buffers.append(self.alloc, scratch) catch |err| {
                    scratch.deinit(self.alloc);
                    return err;
                };
                try self.restoreNode(s.first, g, focus);
                try self.restoreNode(s.second, g2, focus);
            },
            .group => |spec| {
                if (spec.focused) focus.* = g;
                try self.fillGroup(g, spec);
            },
        }
    }

    /// Opens a saved group's files as `g`'s tabs. A file gone since the
    /// save is skipped rather than coming back as an empty `[New]` buffer,
    /// and so is one already open in another group (a file is only ever
    /// open in one). The untouched scratch buffer `g` started with makes
    /// way once anything real opens.
    pub fn fillGroup(self: *Ui, g: *Group, spec: zoe_workspace.EditorGroup) !void {
        const scratch: ?*Slot = if (g.buffers.items.len == 1 and isPristineScratch(g.buffers.items[0])) g.buffers.items[0] else null;
        var shown: ?*Slot = null;
        for (spec.files, 0..) |path, i| {
            _ = std.Io.Dir.cwd().statFile(self.io, path, .{}) catch continue;
            if (self.findPath(path) != null) continue;
            const slot = self.newSlot(path) catch |err| switch (err) {
                error.NotTextFile => continue,
                else => return err,
            };
            g.buffers.append(self.alloc, slot) catch |err| {
                slot.deinit(self.alloc);
                return err;
            };
            if (i == spec.active) shown = slot;
        }
        if (scratch) |s| {
            if (g.buffers.items.len > 1) {
                _ = g.buffers.orderedRemove(0);
                s.deinit(self.alloc);
            }
        }
        g.active = 0;
        for (g.buffers.items, 0..) |s, i| {
            if (s == shown) g.active = i;
        }
        if (g == self.grp) self.buf = g.slot();
        g.markRedraw();
    }

    pub fn isPristineScratch(slot: *const Slot) bool {
        return slot.ed.path == null and !slot.ed.buf.dirty and slot.ed.buf.len() == 0;
    }

    /// Sends each saved split's proportions to the host split that
    /// stands for it. `node` and `spec` have the same shape, since
    /// `restoreNode` built one from the other.
    pub fn applyRatios(self: *Ui, node: *const groups.Node, spec: *const zoe_workspace.EditorNode) !void {
        const s = switch (node.kind) {
            .split => |s| s,
            .leaf => return,
        };
        const ss = switch (spec.*) {
            .split => |x| x,
            .group => return,
        };
        try self.client.setSplitChildren(s.handle, &.{
            self.layoutChildWeighted(s.first, ss.ratio),
            self.layoutChildWeighted(s.second, 1 - ss.ratio),
        });
        try self.applyRatios(s.first, ss.first);
        try self.applyRatios(s.second, ss.second);
    }

    /// A workspace's theme by name, or -- when it names none -- the choice
    /// zoe makes at startup: `zoe.conf.lua`'s own theme, else the window's.
    /// False when `name` doesn't resolve, in which case the usual choice
    /// applies instead.
    pub fn applyWorkspaceTheme(self: *Ui, name: ?[]const u8) bool {
        var found = true;
        const want: ?themes.Theme = blk: {
            if (name) |n| {
                const t = if (self.hl_config) |*cfg| cfg.findTheme(n) else themes.resolve(n, &.{});
                if (t) |theme| break :blk theme;
                found = false;
            }
            break :blk if (self.hl_config) |*cfg| cfg.ownTheme() else null;
        };
        if (want) |t| {
            self.applyTheme(t) catch return found;
            self.theme_own = true;
        } else {
            self.followWindowTheme() catch return found;
            self.theme_own = false;
        }
        return found;
    }

    /// After the listing changed shape under code that isn't a plain
    /// expand or collapse: the viewport pulled back, the grid resized, the
    /// cursor followed, everything repainted.
    pub fn treeChanged(self: *Ui) !void {
        self.clampTreeScroll();
        try self.syncContentSizes();
        self.scrollTreeToCursor();
        self.markTreeDirty(.full);
    }

    // ── Finder ──────────────────────────────────────────────────────────

    /// Ctrl+P. Walks the tree root and opens the popup over the buffer
    /// pane. The walk happens here, on every open, rather than being kept
    /// up to date in the background -- see applib/finder.zig.
    pub fn openFinder(self: *Ui) !void {
        // The popup is modal, so a tree search underneath it would have
        // the statusline to itself with no way left to type into it.
        self.cancelFind();
        // Every workspace folder, each hit prefixed with its folder's
        // name; one folder lists exactly as it always has.
        var specs: std.ArrayList(finder_mod.RootSpec) = .empty;
        defer specs.deinit(self.alloc);
        for (self.tree.roots.items) |r| try specs.append(self.alloc, .{ .path = r.path, .label = r.name });
        const f = Finder.initRoots(self.alloc, self.io, specs.items, .{ .visible = self.tree.visible }) catch |err| {
            self.buf.ed.setStatus("E484: Can't scan {s}: {s}", .{ self.tree.primaryRoot(), @errorName(err) });
            self.status_dirty = true;
            return;
        };
        try self.finder.open(f, "Find file");
    }

    /// Opens whatever the popup is on and closes it. A file that isn't
    /// text is refused by `openFile` the same way it would be from the
    /// tree -- the popup still closes, and the error lands in the
    /// statusline behind it.
    pub fn acceptFinder(self: *Ui) !void {
        const path = (try self.finder.selectedPath(self.alloc)) orelse return self.finder.close();
        defer self.alloc.free(path);
        self.finder.close();
        try self.openFile(path);
        self.setFocus(.buffer);
    }

    /// A keystroke while the popup is open. It takes every key; see
    /// `finderpopup.applyKey`.
    pub fn finderKey(self: *Ui, k: glyphwire.KeyEvent) !void {
        if (try self.finder.key(k) == .accept) try self.acceptFinder();
    }

    // ── Command palette ─────────────────────────────────────────────────

    /// Ctrl+Shift+P. Lists every action `inPalette` admits, each with the
    /// chord that runs it where the keyboard is now -- the tree reads the
    /// global table, a buffer its mode's.
    pub fn openPalette(self: *Ui) !void {
        // Modal, like the finder: a tree search left running under it
        // would have nothing to type into, and the hover and completion
        // popups would float over it.
        self.cancelFind();
        _ = self.closeHover();
        self.closeCompletion();
        if (self.finder.isOpen()) self.finder.close();

        const scope = self.keyScope();
        var list = palette_mod.List.init(self.alloc);
        errdefer list.deinit();
        for (std.enums.values(actions.Action)) |a| {
            if (!a.inPalette()) continue;
            try list.add(@intFromEnum(a), @tagName(a), a.paletteLabel(), self.keymaps.chordFor(scope, a));
        }
        // Extension commands after the actions, numbered on from them.
        if (self.extensions) |rt| for (rt.commands.items, 0..) |c, i| {
            const id: u32 = @intCast(i);
            try list.add(ext_palette_base + id, c.name, c.label, rt.chordFor(scope, id));
        };
        try self.palette.open(list);
    }

    /// The first palette id that is an extension command, not an action.
    const ext_palette_base: u32 = std.enums.values(actions.Action).len;

    /// The keymap table a key is looked up in where the keyboard is: the
    /// tree has no mode of its own and reads the global one.
    fn keyScope(self: *const Ui) actions.Scope {
        return if (self.focus == .tree) .global else self.buf.ed.keyScope();
    }

    /// Runs whatever the palette is on, closed first so the action sees
    /// the editor as it was before Ctrl+Shift+P: the same mode, the same
    /// focus. A window action goes to `performUi`, the rest to the
    /// editor, and one that doesn't apply where the keyboard is says so
    /// in the statusline rather than doing nothing silently.
    pub fn acceptPalette(self: *Ui) !void {
        const id = self.palette.selected() orelse return self.palette.close();
        self.palette.close();
        self.status_dirty = true;
        if (id >= ext_palette_base) return self.runExtCommand(id - ext_palette_base);
        const action: actions.Action = @enumFromInt(id);
        if (action.isUi()) {
            if (!try self.performUi(action)) self.paletteNotHere(action);
            return;
        }
        if (self.focus != .buffer) return self.paletteNotHere(action);
        try self.applyOutcome(try self.buf.ed.runAction(action));
        try self.syncPathMenu();
    }

    fn paletteNotHere(self: *Ui, action: actions.Action) void {
        var buf: [palette_mod.max_label_len]u8 = undefined;
        const label = action.paletteLabel() orelse palette_mod.labelFromName(&buf, @tagName(action));
        self.buf.ed.setStatus("{s}: not available here", .{label});
    }

    /// A keystroke while the palette is open. Ctrl+Shift+P again closes
    /// it; everything else is the palette's (`popupframe.applyKey`).
    pub fn paletteKey(self: *Ui, k: glyphwire.KeyEvent) !void {
        if (self.keymaps.lookup(self.keyScope(), k.key, k.mods) == .commandPalette) return self.palette.close();
        if (try self.palette.key(k) == .accept) try self.acceptPalette();
    }

    // ── Extensions ──────────────────────────────────────────────────────

    /// Loads the extensions `zoe.conf.lua` lists (`zoe/ext.zig`) and binds
    /// the `keys` that name their commands. Best-effort like the rest of
    /// the config: each problem is logged, and the first is put in the
    /// statusline so a typo isn't silent.
    fn startExtensions(self: *Ui) void {
        const cfg = if (self.hl_config) |*c| c else return;
        const source = cfg.source orelse return;
        const rt = ext.Runtime.init(self.alloc, self.io, self.environ.get("HOME"), .{
            .ctx = self,
            .vtable = &ext_host,
        }) catch |err| {
            std.log.warn("zoe: extensions not loaded ({t})", .{err});
            return;
        };
        const dir = ext.userDir(self.alloc, self.environ);
        defer if (dir) |d| self.alloc.free(d);
        rt.load(source, dir);
        rt.resolveKeys(cfg.command_keys, cfg.keys);
        for (rt.problems.items) |p| std.log.warn("zoe: {s}", .{p});
        if (rt.problems.items.len > 0) {
            const more = rt.problems.items.len - 1;
            if (more == 0)
                self.buf.ed.setStatus("{s}", .{rt.problems.items[0]})
            else
                self.buf.ed.setStatus("{s} (+{d} more in the log)", .{ rt.problems.items[0], more });
        }
        self.extensions = rt;
    }

    /// The extension command a key runs where the keyboard is, if any.
    /// A scope's own table is read before `global`'s, extension bindings
    /// and built-in ones together, so a mode can still take a chord back
    /// from a global command. Never in the `:` or `/` line, which own
    /// their keys.
    fn extCommandFor(self: *Ui, scope: actions.Scope, key: []const u8, mods: glyphwire.Mods) ?u32 {
        const rt = self.extensions orelse return null;
        if (self.focus == .buffer and (self.buf.ed.mode == .command or self.buf.ed.mode == .search)) return null;
        if (rt.lookup(scope, key, mods)) |cmd| return cmd;
        if (scope == .global) return null;
        if (self.keymaps.table(scope).lookup(key, mods) != null) return null;
        return rt.lookup(.global, key, mods);
    }

    /// Runs extension command `cmd`. It may have edited the buffer,
    /// opened another or said something, so everything it could touch is
    /// redrawn.
    fn runExtCommand(self: *Ui, cmd: u32) void {
        const rt = self.extensions orelse return;
        rt.run(cmd);
        self.grp.buffer_dirty = true;
        self.grp.tabs_dirty = true;
        self.status_dirty = true;
    }

    const ext_host: ext.Host.VTable = .{
        .editor = extEditor,
        .open = extOpen,
        .message = extMessage,
    };

    fn extEditor(ctx: *anyopaque) ?*Editor {
        const self: *Ui = @ptrCast(@alignCast(ctx));
        return if (self.focus == .buffer) &self.buf.ed else null;
    }

    fn extOpen(ctx: *anyopaque, path: []const u8) anyerror!void {
        const self: *Ui = @ptrCast(@alignCast(ctx));
        // Opened into the buffer pane even from the tree, the way Enter
        // on a file there leaves the keyboard -- a command that opens a
        // file means to work in it.
        try self.openFile(path);
        if (self.focus == .tree) self.setFocus(.buffer);
    }

    fn extMessage(ctx: *anyopaque, text: []const u8) void {
        const self: *Ui = @ptrCast(@alignCast(ctx));
        self.buf.ed.setStatus("{s}", .{text});
        self.status_dirty = true;
    }

    // ── Buffers ─────────────────────────────────────────────────────────

    /// Opens `path` in a new tab, or switches to it when it is already
    /// open -- both `:e` and Enter on a file in the tree land here. The
    /// buffer being left keeps its text, its cursor and its parse tree,
    /// so coming back to it is a switch rather than a reload.
    pub fn openFile(self: *Ui, path: []const u8) !void {
        // Open in another group already: that group and tab get the
        // focus, since a file is never open in two.
        if (self.findPath(path)) |at| {
            if (at.group != self.grp) {
                const keep_tree = self.focus == .tree;
                self.focusGroup(at.group);
                // Picking a file in the tree leaves the keyboard there, as
                // it does when the file opens in the focused group.
                if (keep_tree) self.setFocus(.tree);
            }
            self.setActive(at.index);
            self.buf.ed.setStatus("\"{s}\"", .{path});
            return;
        }

        const slot = self.newSlot(path) catch |err| switch (err) {
            error.NotTextFile => {
                self.buf.ed.setStatus("E484: \"{s}\" is not a text file", .{path});
                self.status_dirty = true;
                return;
            },
            else => return err,
        };
        errdefer slot.deinit(self.alloc);
        // Inserted next to the current tab rather than at the far end:
        // the file you just opened belongs beside the one you opened it
        // from, and `:bp` goes back to it.
        try self.grp.buffers.insert(self.alloc, self.grp.active + 1, slot);
        self.setActive(self.grp.active + 1);
    }

    /// A bare `:e` -- re-reads the current buffer from disk, in place.
    /// The tab stays where it is and keeps its position in the strip;
    /// only the text and the cursor reset. `:e <path>` is the other
    /// thing entirely, a tab of its own.
    pub fn reloadCurrent(self: *Ui) !void {
        const path = self.buf.ed.path orelse {
            self.buf.ed.setStatus("E32: No file name", .{});
            return;
        };
        const bytes = std.Io.Dir.cwd().readFileAlloc(self.io, path, self.alloc, .limited(max_file_bytes)) catch {
            self.buf.ed.setStatus("E484: Can't open file {s}", .{path});
            return;
        };
        defer self.alloc.free(bytes);
        if (filetype.looksBinary(bytes)) {
            self.buf.ed.setStatus("E484: \"{s}\" is not a text file", .{path});
            self.status_dirty = true;
            return;
        }

        // `loadText` re-owns the path, freeing the string `path` points
        // at, so everything below reads it back off the editor.
        try self.buf.ed.loadText(bytes, path);
        self.buf.disk = self.diskStamp(self.buf.ed.path.?);
        self.buf.disk_warned = null;
        self.buf.gone = false;
        self.selectHighlightLanguage(self.buf, self.buf.ed.path);
        // Wholly different contents: the servers' copy is stale in a way the
        // edit watermark can't express, so force the next flush to send.
        self.buf.lsp_sent_edits = self.buf.ed.buf.edits -% 1;
        self.buf.top_line = 0;
        self.buf.top_sub = 0;
        self.buf.left_col = 0;
        // Fresh contents -- nothing on screen carries over.
        self.buf.full_redraw = true;
        self.buf.ed.setStatus("\"{s}\" {d}L", .{ self.buf.ed.path.?, self.buf.ed.buf.lineCount() });
        self.grp.buffer_dirty = true;
        self.grp.tabs_dirty = true;
        self.status_dirty = true;
    }

    /// `path`'s current size and mtime, or null when it can't be stat'ed
    /// (gone, or never written).
    pub fn diskStamp(self: *Ui, path: []const u8) ?diskwatch.Stamp {
        const st = std.Io.Dir.cwd().statFile(self.io, path, .{}) catch return null;
        return .{ .size = st.size, .mtime_ns = st.mtime.nanoseconds };
    }

    /// Starts the inotify watcher when `file_watch` asks for one. One
    /// that can't start (not Linux, out of instances) falls back to
    /// polling and says so, rather than leaving zoe blind to the disk.
    pub fn startFileWatch(self: *Ui) void {
        if (self.file_watch != .inotify) return;
        self.inotify = inotify_mod.Watcher.start(self.alloc, self.listener) catch |err| {
            self.file_watch = .poll;
            self.buf.ed.setStatus("file_watch: inotify unavailable ({s}), polling", .{@errorName(err)});
            self.status_dirty = true;
            return;
        };
    }

    /// Arms the disk check for whatever `file_watch` says wakes it. A
    /// check already armed is left alone, which under inotify also leaves
    /// the watcher's flag set: it stops waking the loop until this turn
    /// comes round again after the check (see `Watcher.takeChanged`).
    pub fn armDiskCheck(self: *Ui) void {
        if (self.disk_check_due != null) return;
        const ms: i64 = switch (self.file_watch) {
            .off => return,
            .poll => diskwatch.poll_ms,
            .inotify => blk: {
                const w = self.inotify orelse return;
                self.syncWatches(w);
                // A tree re-read skipped for an open search or name field
                // retries on the poller's beat: no event may come to
                // prompt it otherwise.
                if (self.disk_check_retry) break :blk diskwatch.poll_ms;
                if (!w.takeChanged()) return;
                break :blk diskwatch.settle_ms;
            },
        };
        self.disk_check_due = std.Io.Clock.Timestamp.fromNow(self.io, .{
            .raw = .fromMilliseconds(ms),
            .clock = .awake,
        });
    }

    /// Points the inotify watches at the directories the disk check
    /// stats: every open buffer's, and the tree's roots and expanded
    /// folders. Run every loop turn, which costs a map lookup per
    /// directory -- cheaper than hooking every place a buffer opens,
    /// closes or is renamed. A watch that can't be added is skipped (see
    /// `zoe/inotify.zig`).
    fn syncWatches(self: *Ui, w: *inotify_mod.Watcher) void {
        w.begin();
        for (self.group_list.items) |g| {
            for (g.buffers.items) |slot| {
                const abs = self.slotAbs(slot) orelse continue;
                const dir = std.fs.path.dirname(abs) orelse continue;
                w.want(dir) catch {};
            }
        }
        for (self.tree.roots.items) |r| w.want(r.path) catch {};
        for (self.tree.entries.items) |e| {
            if (e.is_dir and e.expanded) w.want(e.path) catch {};
        }
        w.sweep() catch {};
    }

    /// Whether the disk check has come due. Disarms it, so the next loop
    /// turn arms the next one.
    pub fn diskCheckDue(self: *Ui) bool {
        const due = self.disk_check_due orelse return false;
        if (due.raw.durationTo(std.Io.Clock.awake.now(self.io)).toMilliseconds() < 0) return false;
        self.disk_check_due = null;
        return true;
    }

    /// Stats every open buffer's file and follows the ones that changed
    /// outside zoe: a clean buffer reloads in place, a modified one gets
    /// one W11 warning per change and is otherwise left alone, and one
    /// whose file is gone marks its tab. See `zoe/diskwatch.zig` for the
    /// rules.
    pub fn checkDisk(self: *Ui) void {
        for (self.group_list.items) |g| {
            for (g.buffers.items) |slot| {
                const path = slot.ed.path orelse continue;
                const current = self.diskStamp(path);
                const gone = diskwatch.gone(slot.disk, current);
                if (gone != slot.gone) {
                    slot.gone = gone;
                    g.tabs_dirty = true;
                }
                switch (diskwatch.decide(slot.disk, slot.disk_warned, current, slot.ed.buf.dirty)) {
                    .none => {},
                    .reload => self.reloadFromDisk(g, slot, current.?),
                    .warn => {
                        slot.disk_warned = current;
                        // On whichever buffer is showing: the status
                        // line is the active buffer's, and this is news
                        // the user needs before their next `:w`
                        // overwrites someone else's change.
                        self.buf.ed.setStatus("W11: \"{s}\" changed on disk since editing started", .{path});
                        self.status_dirty = true;
                    },
                }
            }
        }
    }

    /// The sidebar's half of the disk check: a folder on screen that
    /// gained, lost or renamed an entry is re-read, keeping what was open
    /// and the cursor's entry (`Tree.changedOnDisk`, `Tree.reload`).
    /// Skipped while a tree search or a name field is up -- both hold row
    /// indices a re-read would shift -- and caught on the next beat once
    /// they close (`disk_check_retry` makes sure there is one).
    pub fn checkTreeDisk(self: *Ui) !void {
        self.disk_check_retry = self.find != null or self.tree_edit != null;
        if (self.disk_check_retry) return;
        if (!self.tree.changedOnDisk(self.io)) return;
        try self.refreshTree(null);
    }

    /// Re-reads the tree and repaints it, with the cursor on `onto` (an
    /// absolute path) when given -- the entry a create or rename just
    /// made -- or else on the entry it was on.
    pub fn refreshTree(self: *Ui, onto: ?[]const u8) !void {
        if (onto) |p| try self.tree.reloadOnto(self.io, p) else try self.tree.reload(self.io);
        try self.treeChanged();
    }

    /// Re-reads `slot`'s file after an outside change, keeping the view:
    /// the cursor stays on the same line and column and the pane on the
    /// same scroll position, clamped to the new text. Unlike a bare `:e`,
    /// which starts the file over at the top. Insert mode survives too --
    /// a reload is something that happened to the user, not something
    /// they asked for. A file that can't be read or has turned binary is
    /// skipped; `stamp` is recorded either way so it isn't retried every
    /// second.
    pub fn reloadFromDisk(self: *Ui, g: *Group, slot: *Slot, stamp: diskwatch.Stamp) void {
        slot.disk = stamp;
        slot.disk_warned = null;
        const path = slot.ed.path orelse return;
        const bytes = std.Io.Dir.cwd().readFileAlloc(self.io, path, self.alloc, .limited(max_file_bytes)) catch return;
        defer self.alloc.free(bytes);
        if (filetype.looksBinary(bytes)) return;

        const pos = slot.ed.buf.posOf(slot.ed.cursor);
        const was_insert = slot.ed.mode == .insert;
        const active = slot == self.buf;
        if (active) {
            // Byte offsets into the old text are meaningless now.
            self.drag = null;
            _ = self.closeHover();
            self.closeCompletion();
        }

        // Null path: `loadText` keeps the one it has.
        slot.ed.loadText(bytes, null) catch return;
        self.selectHighlightLanguage(slot, slot.ed.path);
        // Same as `reloadCurrent`: the servers' copy is stale in a way the
        // edit watermark can't express. A background buffer's goes out
        // when it is next made active, like any of its edits would.
        slot.lsp_sent_edits = slot.ed.buf.edits -% 1;

        const last_line = slot.ed.buf.lineCount() - 1;
        const line = @min(pos.line, last_line);
        slot.ed.moveCursorTo(motion.atColumn(&slot.ed.buf, line, pos.col, false));
        if (was_insert) slot.ed.mode = .insert;
        slot.top_line = @min(slot.top_line, last_line);
        slot.full_redraw = true;
        g.buffer_dirty = true;
        g.tabs_dirty = true;
        if (active) {
            slot.ed.setStatus("\"{s}\" {d}L reloaded (changed on disk)", .{ path, slot.ed.buf.lineCount() });
            self.status_dirty = true;
        }
    }

    /// Whether `:q` / `:wq` has to be refused because some *other* tab
    /// holds unsaved changes, reporting the first one it finds. An
    /// `Editor` only knows its own modified flag, and `:q` takes the
    /// whole editor down with every buffer in it, so this guard can only
    /// live here. `:q!` skips it, the way `!` always does.
    pub fn refuseQuitForDirtyBuffer(self: *Ui) bool {
        for (self.group_list.items) |g| {
            for (g.buffers.items) |slot| {
                if (!slot.ed.buf.dirty) continue;
                self.buf.ed.setStatus(
                    "E162: No write since last change for buffer \"{s}\"",
                    .{slot.ed.path orelse "[No Name]"},
                );
                self.status_dirty = true;
                return true;
            }
        }
        return false;
    }

    /// The group and tab holding `path`, if one is open anywhere. Paths
    /// are compared as they were given, so `:e ./x.zig` and `:e x.zig`
    /// are two tabs -- resolving them would mean touching the filesystem
    /// for what is a convenience. The tree is self-consistent, so
    /// clicking the same entry twice always finds the tab it opened.
    pub fn findPath(self: *const Ui, path: []const u8) ?SlotAt {
        for (self.group_list.items) |g| {
            for (g.buffers.items, 0..) |slot, i| {
                const p = slot.ed.path orelse continue;
                if (std.mem.eql(u8, p, path)) return .{ .group = g, .index = i };
            }
        }
        return null;
    }

    /// Makes tab `index` the one being edited -- the only writer of the
    /// `active` / `buf` pair. Focus is left alone: opening a file from
    /// the tree shouldn't yank the keyboard out of the tree.
    pub fn setActive(self: *Ui, index: usize) void {
        self.grp.active = @min(index, self.grp.buffers.items.len - 1);
        self.buf = self.grp.buffers.items[self.grp.active];
        // The buffer layer's cells belong to whichever buffer drew last,
        // and its scrollbar to that buffer's line count. Neither carries
        // over, so the incoming buffer repaints and re-pushes its extent.
        self.buf.full_redraw = true;
        self.buf.pushed_bar = .{ std.math.maxInt(usize), 0, 0, 0 };
        self.grp.buffer_dirty = true;
        self.grp.tabs_dirty = true;
        self.status_dirty = true;
    }

    /// `:bn` / `:bp`, and Ctrl+Tab / Ctrl+Shift+Tab. Wraps at both ends,
    /// so two buffers can be flipped between with one chord.
    pub fn stepBuffer(self: *Ui, forward: bool) void {
        const n = self.grp.buffers.items.len;
        if (n < 2) return;
        self.setActive(if (forward) (self.grp.active + 1) % n else (self.grp.active + n - 1) % n);
    }

    /// Closes tab `index` of the focused group. A modified buffer refuses
    /// unless `force`, the same E37 guard `:q` uses and what the tab's `×`
    /// reports when it can't close. Closing a group's last buffer closes
    /// the group, unless it is the only one: that is left an empty
    /// scratch buffer, so `buf` always points somewhere.
    pub fn closeBuffer(self: *Ui, index: usize, force: bool) !void {
        if (index >= self.grp.buffers.items.len) return;
        const slot = self.grp.buffers.items[index];
        if (slot.ed.buf.dirty and !force) {
            self.buf.ed.setStatus("E37: No write since last change (add ! to override)", .{});
            self.status_dirty = true;
            return;
        }

        // While the slot still exists: `didClose` needs its path, and the
        // stored diagnostics go with it.
        self.lspDidClose(slot);

        const closed_active = index == self.grp.active;
        _ = self.grp.buffers.orderedRemove(index);
        slot.deinit(self.alloc);

        if (self.grp.buffers.items.len == 0) {
            // A group that has run out of tabs closes, like a VS Code
            // editor group; only the last one is left with a scratch
            // buffer, because there has to be somewhere to type.
            if (self.group_list.items.len > 1) return self.closeEmptyGroup(self.grp);
            const fresh = try self.newSlot(null);
            errdefer fresh.deinit(self.alloc);
            try self.grp.buffers.append(self.alloc, fresh);
        }

        // Closing the active tab focuses whatever slid into its place
        // (or the new last tab); closing one to its left just shifts its
        // index down.
        const target = if (closed_active)
            @min(index, self.grp.buffers.items.len - 1)
        else if (self.grp.active > index)
            self.grp.active - 1
        else
            self.grp.active;
        self.setActive(target);
    }

    /// The line-comment marker for `path`'s language (Ctrl+/), from the
    /// config's languages or the built-in ones.
    pub fn lineCommentFor(self: *const Ui, path: ?[]const u8) ?[]const u8 {
        const p = path orelse return null;
        const langs = if (self.hl_config) |cfg| cfg.langs else &syntax.default_langs;
        return syntax.lineCommentFor(langs, p);
    }

    /// Whether a line ending in `:` opens a block in `path`'s language,
    /// for auto-indent. Python is the one bundled language that does.
    pub fn colonBlockFor(self: *const Ui, path: ?[]const u8) bool {
        const p = path orelse return false;
        const langs = if (self.hl_config) |cfg| cfg.langs else &syntax.default_langs;
        const lang = syntax.languageFor(langs, p) orelse return false;
        return std.mem.eql(u8, lang, "python");
    }

    pub fn save(self: *Ui, target: ?[]const u8) void {
        const dest = target orelse self.buf.ed.path orelse {
            self.buf.ed.setStatus("E32: No file name", .{});
            return;
        };
        const bytes = self.buf.ed.buf.text(self.alloc) catch return;
        defer self.alloc.free(bytes);

        std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = dest, .data = bytes }) catch {
            self.buf.ed.setStatus("E212: Can't open file for writing: {s}", .{dest});
            return;
        };
        if (target) |t| {
            self.buf.ed.setPath(t) catch {};
            // Saved under a new extension, it may be another language now.
            self.buf.ed.line_comment = self.lineCommentFor(t);
            self.buf.ed.colon_block = self.colonBlockFor(t);
            // The buffer is a different file now, so the cached absolute
            // path and whatever the servers were told about the old name
            // both stop being true.
            self.invalidateAbs(self.buf);
            self.buf.lsp_opened = false;
        }
        self.buf.ed.markSaved();
        // Our own write moves the mtime too; this is the version on disk
        // now, not an outside change to react to.
        self.buf.disk = self.diskStamp(self.buf.ed.path orelse dest);
        self.buf.disk_warned = null;
        // A deleted file just came back.
        self.buf.gone = false;
        self.lspDidSave();
        // The tab loses its `+` (and any deleted mark), and a `:w <name>`
        // also renamed it.
        self.grp.tabs_dirty = true;
        self.buf.ed.setStatus("\"{s}\" {d}L written", .{ dest, self.buf.ed.buf.lineCount() });
    }

    // ── Language servers ────────────────────────────────────────────────
    //
    // `zoe/lsp.zig`
    // owns the processes and the protocol, `zoe/diag.zig` owns what they
    // said, and everything here is the editor's half -- when to tell them
    // about a buffer, what to do with an answer, and how a diagnostic gets
    // onto the screen.

    // ── Language servers (lspglue.zig) ─────────────────────────────────
    pub const startLsp = lspglue.startLsp;
    pub const lspGrammarFor = lspglue.lspGrammarFor;
    pub const lspDidOpen = lspglue.lspDidOpen;
    pub const lspDidClose = lspglue.lspDidClose;
    pub const lspDidSave = lspglue.lspDidSave;
    pub const armLspChange = lspglue.armLspChange;
    pub const lspFlushChange = lspglue.lspFlushChange;
    pub const nextLspDeadline = lspglue.nextLspDeadline;
    pub const earlier = lspglue.earlier;
    pub const lspChangeDue = lspglue.lspChangeDue;
    pub const slotAbs = lspglue.slotAbs;
    pub const invalidateAbs = lspglue.invalidateAbs;
    pub const drainLsp = lspglue.drainLsp;
    pub const handleLspEvent = lspglue.handleLspEvent;
    pub const applyTimeout = lspglue.applyTimeout;
    pub const applyDiagnostics = lspglue.applyDiagnostics;
    pub const byteColumn = lspglue.byteColumn;
    pub const slotForPath = lspglue.slotForPath;
    pub const requestLsp = lspglue.requestLsp;
    pub const applyHover = lspglue.applyHover;
    pub const highlightHoverBlocks = lspglue.highlightHoverBlocks;
    pub const applyDefinition = lspglue.applyDefinition;
    pub const stepDiagnostic = lspglue.stepDiagnostic;
    pub const lspStatus = lspglue.lspStatus;
    pub const restartLsp = lspglue.restartLsp;
    pub const diagList = lspglue.diagList;

    /// Names this context `zoe <file>` after the focused buffer (`~` for
    /// `$HOME`), or `zoe <cwd>` for a buffer with no file yet. Only sends
    /// when it changed, so the per-frame call is a string compare.
    pub fn syncTitle(self: *Ui) void {
        var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
        const where = self.slotAbs(self.buf) orelse blk: {
            const n = std.process.currentPath(self.io, &cwd_buf) catch 0;
            break :blk cwd_buf[0..n];
        };
        var home_buf: [std.fs.max_path_bytes]u8 = undefined;
        const shown = homepath.collapseHome(where, self.environ.get("HOME"), &home_buf);
        var next: [glyphwire.Context.max_title_len]u8 = undefined;
        const title = std.fmt.bufPrint(&next, "zoe {s}", .{shown}) catch "zoe";
        if (std.mem.eql(u8, title, self.title_buf[0..self.title_len])) return;
        self.client.setContextTitle(title) catch return;
        @memcpy(self.title_buf[0..title.len], title);
        self.title_len = title.len;
    }

    // ── Completion ──────────────────────────────────────────────────────

    // ── Completion (completionui.zig) ───────────────────────────────────
    pub const requestCompletion = completionui.requestCompletion;
    pub const applyCompletion = completionui.applyCompletion;
    pub const refilterCompletion = completionui.refilterCompletion;
    pub const closeCompletion = completionui.closeCompletion;
    pub const isCompletionTrigger = completionui.isCompletionTrigger;
    pub const afterInsertEdit = completionui.afterInsertEdit;
    pub const armCompletion = completionui.armCompletion;
    pub const completionDue = completionui.completionDue;
    pub const syncCompletion = completionui.syncCompletion;
    pub const acceptCompletion = completionui.acceptCompletion;
    pub const completionKey = completionui.completionKey;
    pub const renderCompletion = completionui.renderCompletion;

    // ── Jumps and themes ────────────────────────────────────────────────

    /// Moves the cursor to a (line, byte column) pair, clamped into the
    /// buffer. Shared by `gd`, `]d` and the jumplist.
    pub fn gotoLineColumn(self: *Ui, line: u32, column: u32) void {
        const lines = self.buf.ed.buf.lineCount();
        const target_line = @min(@as(usize, line), lines -| 1);
        const start = self.buf.ed.buf.lineStart(target_line);
        const end = self.buf.ed.buf.lineEnd(target_line);
        self.buf.ed.setCursor(@min(start + column, end));
        self.buf.full_redraw = true;
        self.grp.buffer_dirty = true;
        self.status_dirty = true;
    }

    /// `:theme` reports the current theme; `:theme <name>` switches this
    /// editor to a built-in or one of `zoe.conf.lua`'s or `theme.lua`'s
    /// `themes`; `:theme window` goes back to following the window's.
    pub fn themeCommand(self: *Ui, arg: ?[]const u8) void {
        self.status_dirty = true;
        const name = arg orelse {
            self.buf.ed.setStatus("theme: {s}", .{self.th.name()});
            return;
        };
        const switched = if (std.mem.eql(u8, name, "window"))
            self.followWindowTheme()
        else blk: {
            const t = (if (self.hl_config) |*cfg| cfg.findTheme(name) else themes.resolve(name, &.{})) orelse {
                self.buf.ed.setStatus("E185: Cannot find color scheme '{s}'", .{name});
                return;
            };
            break :blk self.applyTheme(t);
        };
        switched catch |err| {
            self.buf.ed.setStatus("E: theme switch failed ({t})", .{err});
            return;
        };
        self.theme_own = !std.mem.eql(u8, name, "window");
        self.buf.ed.setStatus("theme: {s}", .{self.th.name()});
    }

    /// `:shell <position>` moves the Ctrl+` panel (`bottom`, `top`,
    /// `left`, `right`, `float`) for the rest of the run, open or not;
    /// `:shell` alone names where it is. The float size stays the
    /// configured one.
    pub fn shellPositionCommand(self: *Ui, arg: ?[]const u8) void {
        self.status_dirty = true;
        const name = arg orelse {
            self.buf.ed.setStatus("shell: {t}", .{self.shell.position});
            return;
        };
        const pos = std.meta.stringToEnum(shellpanel.Position, name) orelse {
            self.buf.ed.setStatus("E475: Invalid argument: {s} (bottom, top, left, right or float)", .{name});
            return;
        };
        self.shell.setPosition(pos, self.shell.float_percent, self.winSize());
        self.buf.ed.setStatus("shell: {t}", .{pos});
    }

    pub fn followWindowTheme(self: *Ui) !void {
        try self.client.setTheme(null);
        const st = try self.client.getTheme();
        try self.themeChanged(st);
    }

    /// `:theme <name>`: `t` becomes this context's own theme.
    pub fn applyTheme(self: *Ui, t: themes.Theme) !void {
        try self.client.setTheme(&t);
        try self.themeChanged(.init(t));
    }

    /// Catches up with a theme the host now resolves this context's
    /// colours against. Every colour zoe draws is a role reference, so
    /// what is on screen recolours by itself; what can't is the popups'
    /// nine-patch frame (art, picked by name) and which capture groups
    /// get a span at all, so every buffer is repainted once with the
    /// highlighters' new capture table (their parse trees are kept). The
    /// popups are closed rather than redrawn in place; they come back in
    /// the new frame when next asked for.
    pub fn themeChanged(self: *Ui, st: themes.Stored) !void {
        const frame_changed = !std.mem.eql(u8, st.panelStyle(), self.th.panelStyle());
        self.th = st;
        const c = self.client;
        const syn = syntax.Theme.fromTheme(&self.th.theme);

        for (self.group_list.items) |g| {
            g.buffer_dirty = true;
            g.tabs_dirty = true;
            for (g.buffers.items) |slot| {
                if (slot.hl) |*h| h.setTheme(syn);
                slot.full_redraw = true;
            }
        }
        if (self.hover_hl) |*h| h.setTheme(syn);

        _ = self.closeHover();
        self.closeCompletion();
        self.dismissTabTip();
        if (frame_changed) {
            self.hover_panel_patch = try self.swapPanelPatch(self.hover_layer, self.hover_panel_patch, 1, hover_max_cols);
            self.tab_tip_patch = try self.swapPanelPatch(self.tab_tip_layer, self.tab_tip_patch, tabs.tip_rows, tab_tip_initial_cols);
            self.shell.setFrameStyle(self.th.panelStyle());
        }
        try c.setLayerBackground(self.hover_layer, if (self.hover_panel_patch == null) role(.popup_bg) else null);
        try c.setLayerBackground(self.tab_tip_layer, if (self.tab_tip_patch == null) role(.popup_bg) else null);
        try self.finder.setStyle(finderStyle(&self.th));
        try self.palette.setStyle(paletteStyle(&self.th));

        self.tree_dirty = .full;
        self.status_dirty = true;
    }

    /// Replaces a popup layer's panel nine-patch with the current theme's
    /// `panel_style`, sized like `init` sizes it (the popup's own render
    /// resizes it to fit). Null when the host has no such style, which
    /// draws the popup flat.
    pub fn swapPanelPatch(
        self: *Ui,
        layer: glyphwire.LayerHandle,
        old: ?glyphwire.NinePatchHandle,
        rows: usize,
        cols: usize,
    ) !?glyphwire.NinePatchHandle {
        if (old) |p| try self.client.destroyNinePatch(layer, p);
        return self.client.createNinePatch(layer, 0, 0, rows, cols, self.th.panelStyle()) catch |err| blk: {
            std.log.warn("zoe: no '{s}' nine-patch for a popup ({t}); drawing it flat", .{ self.th.panelStyle(), err });
            break :blk null;
        };
    }

    /// Records where the cursor is, before something moves it somewhere
    /// else entirely.
    pub fn pushJump(self: *Ui) void {
        const path = self.buf.ed.path orelse return;
        self.jumps.push(self.alloc, path, self.buf.ed.cursor) catch {};
    }

    /// Ctrl+O / Ctrl+I.
    pub fn jumpStep(self: *Ui, back: bool) void {
        const entry = (if (back) self.jumps.stepBack() else self.jumps.stepForward()) orelse {
            // `setStatus` takes a comptime format, so the two messages are
            // two calls rather than one with a runtime string.
            if (back) {
                self.buf.ed.setStatus("At the oldest jump", .{});
            } else {
                self.buf.ed.setStatus("At the newest jump", .{});
            }
            self.status_dirty = true;
            return;
        };
        // The file may have been closed since; reopening it is what the user
        // meant either way.
        self.openFile(entry.path) catch {
            self.buf.ed.setStatus("E484: Can't open {s}", .{entry.path});
            self.status_dirty = true;
            return;
        };
        self.buf.ed.setCursor(entry.offset);
        self.buf.full_redraw = true;
        self.grp.buffer_dirty = true;
        self.status_dirty = true;
    }

    /// The severity's colour, for the squiggle and the sign alike.
    pub fn diagColor(_: *const Ui, severity: lsp.Severity) Color {
        return switch (severity) {
            .err => role(.diag_error),
            .warning => role(.diag_warning),
            .information => role(.diag_info),
            .hint => role(.diag_hint),
        };
    }

    // ── Render ──────────────────────────────────────────────────────────

    // ── Render (render.zig) ─────────────────────────────────────────────
    pub const render = render_ui.render;
    pub const anyGroupDirty = render_ui.anyGroupDirty;
    pub const renderGroup = render_ui.renderGroup;
    pub const markTreeDirty = render_ui.markTreeDirty;
    pub const writeAt = render_ui.writeAt;
    pub const renderBuffer = render_ui.renderBuffer;
    pub const caretCell = render_ui.caretCell;
    pub const repaintSelectionChange = render_ui.repaintSelectionChange;
    pub const repaintCaretRows = render_ui.repaintCaretRows;
    pub const syncHighlight = render_ui.syncHighlight;
    pub const parsePrefixEnd = render_ui.parsePrefixEnd;
    pub const parseBudget = render_ui.parseBudget;
    pub const highlightPending = render_ui.highlightPending;
    pub const stepHighlight = render_ui.stepHighlight;
    pub const addDirtyLine = render_ui.addDirtyLine;
    pub const renderChangedRows = render_ui.renderChangedRows;
    pub const dirtyLineListed = render_ui.dirtyLineListed;
    pub const renderBufferRows = render_ui.renderBufferRows;
    pub const gutterWidth = render_ui.gutterWidth;
    pub const foldWidth = render_ui.foldWidth;
    pub const signWidth = render_ui.signWidth;
    pub const textCols = render_ui.textCols;
    pub const renderGutterCell = render_ui.renderGutterCell;
    pub const diagSeverityForLine = render_ui.diagSeverityForLine;
    pub const renderBufferRow = render_ui.renderBufferRow;
    pub const paintDiagnosticRow = render_ui.paintDiagnosticRow;
    pub const paintFoldTail = render_ui.paintFoldTail;
    pub const hoverRect = render_ui.hoverRect;
    pub const renderHover = render_ui.renderHover;
    pub const hideHover = render_ui.hideHover;
    pub const renderTabTip = render_ui.renderTabTip;
    pub const closeHover = render_ui.closeHover;
    pub const paintMatchRow = render_ui.paintMatchRow;
    pub const paintRowSpan = render_ui.paintRowSpan;
    pub const paintSelectionRow = render_ui.paintSelectionRow;
    pub const renderRowSpans = render_ui.renderRowSpans;
    pub const span_run_gap = render_ui.span_run_gap;
    pub const fillSpanCache = render_ui.fillSpanCache;
    pub const fillSpanRun = render_ui.fillSpanRun;
    pub const rowSpansImpl = render_ui.rowSpansImpl;
    pub const RowRange = render_ui.RowRange;
    pub const flushRowGroup = render_ui.flushRowGroup;
    pub const writeSpaces = render_ui.writeSpaces;
    pub const BufLines = render_ui.BufLines;
    pub const layoutRows = render_ui.layoutRows;
    pub const RowPos = render_ui.RowPos;
    pub const lineRows = render_ui.lineRows;
    pub const cursorRowPos = render_ui.cursorRowPos;
    pub const rowsBetween = render_ui.rowsBetween;
    pub const rowsBack = render_ui.rowsBack;
    pub const rowPosBefore = render_ui.rowPosBefore;
    pub const scrollBufferToCursor = render_ui.scrollBufferToCursor;
    pub const scrollWrappedToCursor = render_ui.scrollWrappedToCursor;
    pub const scrollRowsToCursor = render_ui.scrollRowsToCursor;
    pub const wrappedScrollDelta = render_ui.wrappedScrollDelta;
    pub const scrollGroupTo = render_ui.scrollGroupTo;
    pub const lastWholeLine = render_ui.lastWholeLine;
    pub const syncBufferScrollbar = render_ui.syncBufferScrollbar;
    pub const displayOpts = render_ui.displayOpts;
    pub const cursorDisplayCol = render_ui.cursorDisplayCol;
    pub const cursorGrapheme = render_ui.cursorGrapheme;
    pub const renderTree = render_ui.renderTree;
    pub const renderTreeEditRow = render_ui.renderTreeEditRow;
    pub const renderTreeSelection = render_ui.renderTreeSelection;
    pub const iconFor = render_ui.iconFor;
    pub const renderTabs = render_ui.renderTabs;
    pub const writeStripRun = render_ui.writeStripRun;
    pub const syncTabScrollbar = render_ui.syncTabScrollbar;
    pub const cursorDiagnostic = render_ui.cursorDiagnostic;
    pub const renderStatus = render_ui.renderStatus;
    pub const modeName = render_ui.modeName;

};

pub const RowView = render_ui.RowView;
pub const layoutRowMap = render_ui.layoutRowMap;
pub const rowMapHash = render_ui.rowMapHash;
pub const BufferRenderState = render_ui.BufferRenderState;
pub const BufferRender = render_ui.BufferRender;
pub const planBufferRender = render_ui.planBufferRender;
pub const gutterWidthFor = render_ui.gutterWidthFor;
pub const gutterCellText = render_ui.gutterCellText;
pub const selEql = render_ui.selEql;
pub const spanColorAt = render_ui.spanColorAt;
pub const colorOptEql = render_ui.colorOptEql;
pub const HoverRow = render_ui.HoverRow;
pub const spaces = render_ui.spaces;
pub const wrapHover = render_ui.wrapHover;
pub const colorRuns = render_ui.colorRuns;

// ── Hover rows ─────────────────────────────────────────────────────────────
