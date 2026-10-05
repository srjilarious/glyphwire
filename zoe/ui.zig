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
//! `syncCaret`. Ctrl+` opens a `gw-shell` panel over the bottom of the
//! window (`applib/shellpanel.zig`) that takes the keyboard and the caret
//! until it is closed or clicked away from: a click on the panes above
//! gives them back while the panel stays up, and a click on the panel (or
//! Ctrl+` again) returns them to the shell.

const std = @import("std");
const glyphwire = @import("glyphwire");
const ls_icons = @import("applib").icons;

const editor = @import("editor.zig");
const motion = @import("motion.zig");
const diskwatch = @import("diskwatch.zig");
const display = @import("display.zig");
const softwrap = @import("wrap.zig");
const search = @import("search.zig");
const tree_mod = @import("tree.zig");
const finder_mod = @import("applib").finder;
const finderpopup = @import("applib").finderpopup;
const filetype = @import("applib").filetype;
const homepath = @import("applib").homepath;
const syntax = @import("applib").syntax;
const themes = @import("applib").theme;
const role = glyphwire.Color.role;
const langconf = @import("langconf.zig");
const actions = @import("actions.zig");
const tabs = @import("tabs.zig");
const groups = @import("groups.zig");
const lsp = @import("lsp.zig");
const zoe_workspace = @import("workspace.zig");
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
const Tree = tree_mod.Tree;
const Finder = finder_mod.Finder;
const lineedit = @import("applib").lineedit;
const Color = glyphwire.Color;

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
const tree_trailing_rows: usize = 1;

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
const tree_scroll_margin: usize = 3;

/// The most zoe will read into a buffer. Every open buffer holds its
/// text for as long as it is open, so this is also the per-tab ceiling.
const max_file_bytes: usize = 64 * 1024 * 1024;

/// How long a whole-buffer parse may hold up the frame that needs it
/// before zoe draws a highlighted prefix instead and finishes the parse
/// in the background (`Highlighter.beginParse`). Files that parse inside
/// it -- most of them -- are drawn once, fully coloured.
const first_parse_budget_ms: i64 = 8;

/// One slice of a background parse, run between events: short enough
/// that a key typed meanwhile waits no longer than this.
const parse_slice_ms: i64 = 10;

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

/// The sign-column glyph. Solid for an error, hollow for everything else,
/// so severity still reads on a display where the colours are hard to tell
/// apart -- and both are one cell wide in every font, which a fancier
/// symbol from a Nerd Font range would not be.
const sign_error = "\u{25cf}"; // ●
const sign_other = "\u{25cb}"; // ○

/// The hover popup's size limits, clamped to the pane like the finder's.
const hover_max_cols: usize = 76;
const hover_max_rows: usize = 14;
// The popup's background and border are the theme's `panel_style`
// nine-patch, the one the finder's frame uses; `bg_popup` is the flat
// fallback for a host without it.

/// The rows the popup's drop shadow (`glyphwire.Shadow.dialog`, drawn by
/// the host) reaches below it: `hoverRect` keeps that row clear of the line
/// being described when the popup goes above the cursor.
const hover_shadow_rows: usize = 1;

/// The tab tooltip (a hovered tab's full path, `zoe/tabs.zig`): the hover
/// popup's panel and text colour, so the two read as the same kind of
/// thing. Its layer is created with room for this many columns and
/// resized to fit each path.
const tab_tip_initial_cols: usize = 40;

/// The completion popup. Narrower and shorter than the hover: it sits under
/// the line being typed, and every row of it covers code.
const complete_max_cols: usize = 60;
const complete_max_rows: usize = 10;
/// The kind column (`fn`, `var`, `struct`), padded to this width.
const complete_kind_cols: usize = 6;

/// How long typing has to pause before an identifier being typed asks for
/// completions. A trigger character (`.`) doesn't wait. Short enough that
/// the popup is there by the time you look for it; long enough that a word
/// typed at speed is one request, not one per letter.
const complete_auto_delay_ms: u64 = 80;

/// How long after the last edit a `didChange` goes out. Long enough that a
/// burst of typing is one message and a server isn't re-analysing the file
/// on every keystroke; short enough that pausing to look at the screen
/// gets you current diagnostics. 150ms is roughly where every editor with
/// this knob has landed.
const lsp_change_debounce_ms: u64 = 150;

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

    fn deinit(self: *Hover) void {
        self.doc.deinit();
    }
};

/// A pane's bounds, mirrored from the last `layout` notification.
const Bounds = struct {
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
const TreeDirty = enum(u2) {
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
const TreeEdit = struct {
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

    const Kind = enum {
        /// `a` / Shift+F4: a file, or a directory when the name ends in
        /// `/`. Missing parents along the way are made too.
        create,
        /// F7: a directory, slash or not.
        create_dir,
        rename,
    };

    fn deinit(self: *TreeEdit, alloc: std.mem.Allocator) void {
        self.field.deinit(alloc);
        alloc.free(self.dir);
        alloc.free(self.old_name);
    }

    /// Whether the field is a virtual row spliced into the listing.
    fn inserts(self: *const TreeEdit) bool {
        return self.kind != .rename;
    }
};

/// Which set of names a tree-pane search is walking.
///
/// The two scopes answer different questions, which is why the trigger
/// key picks one rather than the search widening on its own: `f` is "find
/// something I can already see", `/` is "find it anywhere under the root,
/// and open whatever folders that takes".
const FindScope = enum {
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
const TreeFind = struct {
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

    fn deinit(self: *TreeFind, alloc: std.mem.Allocator) void {
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
            a.show_whitespace == b.show_whitespace and a.wrap == b.wrap;
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
const Slot = struct {
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

    fn deinit(self: *Slot, alloc: std.mem.Allocator) void {
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
const Group = struct {
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

    fn slot(self: *const Group) *Slot {
        return self.buffers.items[self.active];
    }

    /// The group's whole area, strip and pane together, for Ctrl+hjkl.
    fn rect(self: *const Group) groups.Rect {
        const t = self.tabs_bounds;
        const b = self.buffer_bounds;
        return .{ .row = t.row, .col = b.col, .cols = b.cols, .rows = t.rows + b.rows };
    }

    fn contains(self: *const Group, cell: glyphwire.CellPos) bool {
        const r = self.rect();
        return r.cols > 0 and cell.row >= r.row and cell.row < r.row + r.rows and
            cell.col >= r.col and cell.col < r.col + r.cols;
    }

    fn markRedraw(self: *Group) void {
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
    /// `checkDisk`). Always armed: it is the one timer that runs with
    /// nothing else going on.
    disk_check_due: ?std.Io.Clock.Timestamp = null,
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
    /// Ctrl+`: a `gw-shell` drawing into a layer across the bottom, above
    /// the statusline, for running builds and tests without leaving the
    /// editor. It floats outside the split tree like the finder and takes
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

        var keymaps = try actions.Keymaps.initDefaults(alloc);
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
        // `Panel.place` puts it across the bottom when it opens.
        const shell_layer = try client.createLayer(size.cols, 1, shellpanel.scrollback_rows);
        try client.setLayerBackground(shell_layer, role(.shell_bg));
        try client.setLayerScrollbars(shell_layer, true, false);
        // Output the user may want to copy: the host's drag-to-select,
        // which zoe's own drag handling would otherwise never allow here.
        try client.setLayerMouseSelect(shell_layer, true);
        try client.setLayerVisible(shell_layer, false);

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
            .hover_layer = hover_layer,
            .hover_panel_patch = hover_panel_patch,
            .completion_layer = completion_layer,
            .path_menu_layer = path_menu_layer,
            .tab_tip_layer = tab_tip_layer,
            .tab_tip_patch = tab_tip_patch,
            .diags = diag.Store.init(alloc),
            .shell = shellpanel.Panel.init(alloc, io, client, context, shell_layer),
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
    fn makeGroup(alloc: std.mem.Allocator, client: *glyphwire.Client, id: groups.GroupId, size: anytype) !*Group {
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
    fn loadConfig(self: *Ui, cfg: langconf.Config, environ: *const std.process.Environ.Map) void {
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
    fn syncKeyRepeat(self: *Ui) void {
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
    fn keyRepeatForMode(self: *Ui) langconf.KeyRepeat {
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
    fn toggleShell(self: *Ui) void {
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
    fn shellDir(self: *const Ui, buf: []u8) []const u8 {
        const fallback = self.tree.primaryRoot();
        const p = self.buf.ed.path orelse return fallback;
        const abs = self.absolutePath(p, buf) orelse return fallback;
        const loc = self.tree.locate(abs) orelse return fallback;
        return self.tree.roots.items[loc.root].path;
    }

    /// `path` made absolute against the cwd, into `buf`. Null when it
    /// doesn't fit, or the cwd can't be read.
    fn absolutePath(self: *const Ui, path: []const u8, buf: []u8) ?[]const u8 {
        if (std.fs.path.isAbsolute(path)) return path;
        const n = std.process.currentPath(self.io, buf) catch return null;
        if (n + 1 + path.len > buf.len) return null;
        buf[n] = '/';
        @memcpy(buf[n + 1 ..][0..path.len], path);
        return buf[0 .. n + 1 + path.len];
    }

    /// The panel went away -- Ctrl+` closed it, or its shell exited. Zoe
    /// has the host caret back and has to send it afresh. Nothing is
    /// repainted: the panel is a layer over the panes, and hiding it
    /// shows them exactly as they were.
    fn shellClosed(self: *Ui) void {
        self.caret_host = null;
    }

    /// The open panel takes the keyboard back: a click on it, or Ctrl+`.
    /// Popups go the way a keystroke would send them, since the next
    /// keystroke is the shell's.
    fn focusShell(self: *Ui) void {
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
    fn blurShell(self: *Ui) void {
        if (!self.shell.isFocused()) return;
        self.shell.blur();
        self.shellClosed();
        self.status_dirty = true;
    }

    /// The whole window in cells. The statusline is the last row of the
    /// root split, so its bounds are the window's bottom edge.
    fn winSize(self: *const Ui) shellpanel.WinSize {
        return .{
            .cols = self.status_bounds.cols,
            .rows = self.status_bounds.row + self.status_bounds.rows,
        };
    }

    /// Puts the open panel back across the bottom after a resize.
    fn replaceShell(self: *Ui) void {
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
    fn syncCaret(self: *Ui) void {
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
    fn caretShape(self: *const Ui) ?glyphwire.CaretShape {
        if (!self.has_focus) return .box;
        if (self.buf.ed.mode == .insert or self.buf.ed.mode == .select) return .line;
        return null;
    }

    /// `shape` non-null hands the host the caret, on the buffer layer, in
    /// that shape; null takes it back for `renderBuffer` to draw.
    fn sendCaret(self: *Ui, shape: ?glyphwire.CaretShape) !void {
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
    fn newSlot(self: *Ui, path: ?[]const u8) !*Slot {
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
        }
        return slot;
    }

    /// Points a slot's highlighter at the grammar for `path` (by
    /// extension), or clears it. Cheap and idempotent.
    fn selectHighlightLanguage(self: *Ui, slot: *Slot, path: ?[]const u8) void {
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
        self.diags.deinit();
        if (self.hover) |*h| h.deinit();
        if (self.hover_hl) |*h| h.deinit();
        if (self.completion) |*m| m.deinit();
        if (self.path_menu) |*m| m.deinit();
        self.jumps.deinit(self.alloc);
        self.keymaps.deinit(self.alloc);
        self.cmd_history.deinit();
        self.search_history.deinit();
        if (self.cmd_history_file) |p| self.alloc.free(p);
        if (self.search_history_file) |p| self.alloc.free(p);
        self.client.destroyContext(self.context) catch {};
        self.tree.deinit();
        self.finder.deinit();
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
    fn applySplitChildren(self: *Ui) !void {
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
    // own resizable split of two. Every change below re-sends only the
    // child lists whose shape changed, because `set_split_children`
    // replaces a list wholesale and so resets the proportions the user
    // dragged it to.

    fn groupById(self: *const Ui, id: groups.GroupId) *Group {
        for (self.group_list.items) |g| {
            if (g.id == id) return g;
        }
        unreachable; // every id in `layout` has a group
    }

    /// The host split child a layout node stands for.
    fn layoutChild(self: *const Ui, node: *const groups.Node) glyphwire.SplitChildInput {
        return self.layoutChildWeighted(node, 1);
    }

    fn layoutChildWeighted(self: *const Ui, node: *const groups.Node, weight: f32) glyphwire.SplitChildInput {
        return switch (node.kind) {
            .group => |id| glyphwire.SplitChildInput.splitWeighted(self.groupById(id).col_split, weight),
            .split => |s| glyphwire.SplitChildInput.splitWeighted(s.handle, weight),
        };
    }

    fn sendSplit(self: *Ui, node: *const groups.Node) !void {
        const s = node.kind.split;
        try self.client.setSplitChildren(s.handle, &.{ self.layoutChild(s.first), self.layoutChild(s.second) });
    }

    /// Re-sends the one list that holds `node`: its parent split's, or
    /// the tree|editor split's when it is the layout's root.
    fn sendListHolding(self: *Ui, node: *const groups.Node) !void {
        if (node.parent) |p| try self.sendSplit(p) else try self.applySplitChildren();
    }

    const SlotAt = struct { group: *Group, index: usize };

    /// The group holding `slot`, and the slot's tab index there.
    fn findSlot(self: *const Ui, slot: *const Slot) ?SlotAt {
        for (self.group_list.items) |g| {
            for (g.buffers.items, 0..) |s, i| {
                if (s == slot) return .{ .group = g, .index = i };
            }
        }
        return null;
    }

    /// Gives `g` the keyboard. The group that had it is repainted too,
    /// to take its caret off.
    fn focusGroup(self: *Ui, g: *Group) void {
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
    fn splitGroup(self: *Ui, orientation: groups.Orientation, side: groups.Side, path: ?[]const u8) !void {
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
            if (self.layout.remove(g.id)) |removed| self.dropGroup(g, removed) catch {};
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
    fn insertGroup(self: *Ui, from: *Group, orientation: groups.Orientation, side: groups.Side) !*Group {
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
        const node = try self.layout.splitSide(from.id, g.id, orientation, handle, side);
        errdefer if (self.layout.remove(g.id)) |removed| self.dropGroup(g, removed) catch {};
        try self.sendSplit(node);
        try self.sendListHolding(node);
        return g;
    }

    /// Moves `slot` from whichever group holds it into `to`'s tabs at
    /// `index` (the end when null), as `to`'s shown tab. A group the move
    /// leaves empty gets a scratch buffer rather than closing -- callers
    /// that want it gone instead use `moveTab`.
    fn moveSlot(self: *Ui, slot: *Slot, to: *Group, index: ?usize) !void {
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
    fn moveTab(self: *Ui, slot: *Slot, to: *Group, index: ?usize) !void {
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
        const removed = self.layout.remove(from.id) orelse return;
        try self.dropGroup(from, removed);
    }

    /// Moves group `g`'s tab at `from_i` so it lands in front of what is
    /// at `to_i` now (`to_i` may be the tab count: the end), keeping it
    /// the shown tab if it was.
    fn reorderTab(self: *Ui, g: *Group, from_i: usize, to_i: usize) void {
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
    fn moveTabToward(self: *Ui, dir: groups.Direction) !void {
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
    fn closeGroup(self: *Ui) !void {
        if (self.group_list.items.len < 2) {
            self.buf.ed.setStatus("E444: Cannot close last window", .{});
            self.status_dirty = true;
            return;
        }
        const g = self.grp;
        const shown = self.buf;
        const removed = self.layout.remove(g.id) orelse return;
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
    fn closeEmptyGroup(self: *Ui, g: *Group) !void {
        const removed = self.layout.remove(g.id) orelse return;
        // Before the group goes: `grp` must not be left pointing at it.
        // (`buf` already doesn't point anywhere -- its slot was the one
        // just closed -- and `focusGroup` replaces it without reading it.)
        self.focusGroup(self.groupById(removed.focus));
        try self.dropGroup(g, removed);
    }

    /// Takes an emptied group off the screen and frees it: its sibling
    /// takes the parent split's place in the host tree, and the group's
    /// own layers and split go. `g` must already be out of `layout`, its
    /// buffers gone, and `grp` pointing at another group.
    fn dropGroup(self: *Ui, g: *Group, removed: groups.Layout.Removed) !void {
        try self.sendListHolding(removed.replacement);
        self.client.destroySplit(removed.destroyed) catch {};
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
    fn focusToward(self: *Ui, dir: groups.Direction) void {
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
    fn groupFacing(self: *Ui, from: groups.Rect, self_group: ?*Group, dir: groups.Direction) ?*Group {
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
    fn cycleFocus(self: *Ui) !void {
        var order: std.ArrayList(groups.GroupId) = .empty;
        defer order.deinit(self.alloc);
        try self.layout.groupsInOrder(self.alloc, &order);
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
    fn performUi(self: *Ui, action: actions.Action) !bool {
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
    fn windowCommand(self: *Ui, k: glyphwire.KeyEvent) !bool {
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
    fn readBounds(self: *Ui) !void {
        self.tree_bounds = try self.boundsOf(self.tree_layer);
        for (self.group_list.items) |g| {
            g.tabs_bounds = try self.boundsOf(g.tabs_layer);
            g.buffer_bounds = try self.boundsOf(g.buffer_layer);
        }
        self.status_bounds = try self.boundsOf(self.status_layer);
        try self.syncContentSizes();
    }

    fn boundsOf(self: *Ui, layer: glyphwire.LayerHandle) !Bounds {
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
    fn syncContentSizes(self: *Ui) !void {
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

    /// The tree layer's content grid, which is also exactly what
    /// `renderTree` paints -- one definition, so the grid can never be
    /// bigger than the rows written into it.
    ///
    /// The listing, but never smaller than the viewport *at its current
    /// scroll offset*. Sizing it to the listing alone leaves the rows
    /// past the end transparent whenever the host is still scrolled down
    /// into a listing that just got shorter (a collapsed directory), and
    /// a transparent sidebar row shows the shell's scrollback through it.
    /// `clampTreeScroll` pulls the offset back too, so in practice these
    /// max out at the listing; this is the half that cannot be raced.
    fn treeContentRows(self: *const Ui) usize {
        return @max(self.treeListedRows() + tree_trailing_rows, self.tree_scroll.row + self.tree_bounds.rows);
    }

    /// Rows the listing occupies: the tree's entries, plus the virtual
    /// row a create's name field is drawn on.
    fn treeListedRows(self: *const Ui) usize {
        const extra: usize = if (self.tree_edit) |te| @intFromBool(te.inserts()) else 0;
        return self.tree.len() + extra;
    }

    /// The entry drawn on pane row `r`: the tree's own, shifted down one
    /// past a create's virtual row.
    fn treeRowEntry(self: *const Ui, r: usize) ?tree_mod.Entry {
        if (self.tree_edit) |te| {
            if (te.inserts() and r > te.row) return self.tree.at(r - 1);
        }
        return self.tree.at(r);
    }

    fn treeContentCols(self: *const Ui) usize {
        return @max(self.tree.widestCols(), self.tree_scroll.col + self.tree_bounds.cols);
    }

    /// Pulls the tree's scroll offset back when the listing shrank under
    /// it, so the viewport keeps showing entries rather than the blank
    /// rows past the last one.
    fn clampTreeScroll(self: *Ui) void {
        const rows = self.tree_bounds.rows;
        if (rows == 0) return;
        const max_top = (self.tree.len() + tree_trailing_rows) -| rows;
        if (self.tree_scroll.row <= max_top) return;
        self.tree_scroll.row = max_top;
        // Immediate rather than batched, unlike `scrollTreeToCursor`: the
        // caller is about to shrink the content grid around this offset,
        // and the host has to have pulled the viewport back first.
        self.tree_scroll_pending = null;
        self.client.setLayerScrollOffset(self.tree_layer, max_top, self.tree_scroll.col) catch {};
    }

    // ── Loop ────────────────────────────────────────────────────────────

    pub fn run(self: *Ui) !void {
        while (!self.quit) {
            // Before the frame: everything the language servers have said
            // since the last turn, so an arriving diagnostic is drawn in the
            // frame it arrived for rather than the one after.
            self.drainLsp();
            if (self.anyGroupDirty() or self.tree_dirty != .none or
                self.status_dirty or self.finder.dirty or self.hover_dirty or self.completion_dirty or
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
            // And the disk check: once a second the open files are
            // stat'ed for changes made outside zoe (see `checkDisk`), so
            // an idle zoe wakes on that beat too.
            self.armLspChange();
            if (self.disk_check_due == null) self.disk_check_due = std.Io.Clock.Timestamp.fromNow(self.io, .{
                .raw = .fromMilliseconds(diskwatch.poll_ms),
                .clock = .awake,
            });
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

    fn handleEvent(self: *Ui, ev: glyphwire.Event) !void {
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
                self.replaceShell();
            },
            .scroll_offset => |so| {
                // A wheel or thumb drag over the finder popup's list (the
                // checks below are for other layers, so it falls through).
                _ = self.finder.scrolled(so);
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

    fn toBounds(b: glyphwire.LayoutBounds) Bounds {
        return .{ .row = b.row, .col = b.col, .cols = b.cols, .rows = b.rows };
    }

    fn handleInput(self: *Ui, ev: glyphwire.InputEvent) !void {
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

                // The Ctrl+P popup is modal: while it is open it is the
                // only thing reading keys, so nothing below here runs.
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
                const scope: actions.Scope = if (self.focus == .tree) .global else self.buf.ed.keyScope();
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
            after.wrap != before.wrap)
        {
            self.buf.full_redraw = true;
            for (self.group_list.items) |g| {
                for (g.buffers.items) |slot| {
                    slot.ed.line_numbers = after.line_numbers;
                    slot.ed.tab_width = after.tab_width;
                    slot.ed.expand_tab = after.expand_tab;
                    slot.ed.show_whitespace = after.show_whitespace;
                    slot.ed.wrap = after.wrap;
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
    fn setFocus(self: *Ui, to: Focus) void {
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

    fn toggleTree(self: *Ui) !void {
        self.tree_visible = !self.tree_visible;
        // Ctrl+N is also the shortest way *to* the sidebar, so showing it
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
    fn toggleHidden(self: *Ui) !void {
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

    /// Whether the named key is one of the tree pane's own cursor
    /// commands -- the set a running search is cancelled by.
    ///
    /// This is a *closed list*, not "everything the search didn't
    /// consume", and the difference is the whole point. **Every printable
    /// keystroke is delivered twice**: once as a `key` notification and
    /// once as `text` (it is why the Ctrl+letter chords in `handleInput`
    /// can match on `k.key` at all). Cancelling on any unrecognised key
    /// therefore killed the search on the `key` half of the very
    /// keystroke whose `text` half was about to extend it -- typing in
    /// the tree searched nothing, and the prompt reappearing on the next
    /// trigger looked like a search that had simply found no match.
    ///
    /// `escape` is deliberately absent: while a search is up
    /// `findKey` has already taken it, and with no search there is
    /// nothing to cancel.
    pub fn endsTreeSearch(key: []const u8) bool {
        const commands = [_][]const u8{
            "down", "up", "page_down", "page_up", "home", "end", "enter",
        };
        for (commands) |c| {
            if (std.mem.eql(u8, key, c)) return true;
        }
        return false;
    }

    fn treeKey(self: *Ui, ev: glyphwire.KeyEvent) !void {
        // So does the name field, and it never lets a key through.
        if (self.tree_edit != null) return self.treeEditKey(ev);

        // A search owns the keyboard while it is up, the way the Ctrl+P
        // popup does: Tab steps the candidates, Backspace shortens the
        // prefix, Enter takes the row and Escape drops the search.
        if (self.find != null and try self.findKey(ev)) return;

        // Moving the cursor by hand ends a running search -- the prefix
        // stops describing where the cursor is. Gated on the command set
        // rather than on "anything findKey didn't want", which is the
        // distinction `endsTreeSearch` exists to make.
        const eq = std.mem.eql;
        const key = ev.key;
        if (endsTreeSearch(key)) self.cancelFind();

        if (eq(u8, key, "down")) self.treeMove(1);
        if (eq(u8, key, "up")) self.treeMove(-1);
        if (eq(u8, key, "page_down")) self.treeMove(@intCast(self.treePageRows()));
        if (eq(u8, key, "page_up")) self.treeMove(-@as(i64, @intCast(self.treePageRows())));
        if (eq(u8, key, "home")) self.treeGoto(0);
        if (eq(u8, key, "end")) self.treeGoto(self.tree.len() -| 1);
        if (eq(u8, key, "enter")) try self.treeActivate();
        if (eq(u8, key, "escape")) self.setFocus(.buffer);
        // salacommander's keys for the same three, alongside `a` and `r`
        // (`treeText`): F2 renames, F7 makes a directory, Shift+F4 a file.
        if (eq(u8, key, "F2")) try self.startTreeRename();
        if (eq(u8, key, "F7")) try self.startTreeCreate(.create_dir);
        if (eq(u8, key, "F4") and ev.mods.shift) try self.startTreeCreate(.create);
    }

    /// How far Page Up / Page Down move in the tree: `tree_page_lines`
    /// from `zoe.conf.lua`, or by default a viewport less one row of
    /// overlap, so the entry that was at the edge is still on screen to
    /// read from.
    ///
    /// The *default* is deliberately not the buffer pane's rule. That one
    /// moves a flat `page_lines` (default 10) whatever the pane's height,
    /// because a jump in a file is a jump through text and the window it
    /// happens to be seen through is incidental. A jump in a listing is a
    /// jump through what is on screen, so the screen sets it -- which
    /// also means it stays right when the sidebar is resized, with
    /// nothing to keep in sync. The two are separate keys for that
    /// reason, rather than one governing both panes.
    fn treePageRows(self: *const Ui) usize {
        if (self.hl_config) |cfg| {
            if (cfg.tree_page_lines >= 1) return cfg.tree_page_lines;
        }
        return @max(1, self.tree_bounds.rows -| 1);
    }

    /// Tree navigation reuses vim's own keys, so switching panes doesn't
    /// switch keyboards -- which is also why type-to-find needs a trigger
    /// rather than starting on any letter the way salacommander's does:
    /// here the letters are already commands. `f` searches what is on
    /// screen, `/` searches the whole tree. See `TreeFind`.
    fn treeText(self: *Ui, text: []const u8) !void {
        if (self.tree_edit != null) return self.treeEditText(text);
        if (self.find != null) return self.findText(text);

        var it = (std.unicode.Utf8View.init(text) catch return).iterator();
        while (it.nextCodepointSlice()) |cp| {
            if (cp.len != 1) continue;
            switch (cp[0]) {
                'j' => self.treeMove(1),
                'k' => self.treeMove(-1),
                'g' => self.treeGoto(0),
                'G' => self.treeGoto(self.tree.len() -| 1),
                ' ', 'l' => try self.treeActivate(),
                'h' => self.treeMove(-1),
                'q' => self.setFocus(.buffer),
                'f' => try self.startFind(.visible),
                '/' => try self.startFind(.deep),
                // nvim-tree's: `a` adds (a trailing `/` makes it a
                // folder), `r` renames. Whatever else this chunk held is
                // dropped -- it arrived before the field was there.
                'a' => return self.startTreeCreate(.create),
                'r' => return self.startTreeRename(),
                else => {},
            }
        }
    }

    fn treeMove(self: *Ui, delta: i64) void {
        const n = self.tree.len();
        if (n == 0) return;
        const next = @as(i64, @intCast(self.tree.cursor)) + delta;
        self.treeGoto(@intCast(std.math.clamp(next, 0, @as(i64, @intCast(n - 1)))));
    }

    /// Puts the cursor on `index` and follows it with the viewport. The
    /// one way the cursor moves, so the scroll and the repaint can't be
    /// forgotten at a call site.
    fn treeGoto(self: *Ui, index: usize) void {
        if (self.tree.len() == 0) return;
        self.tree.cursor = @min(index, self.tree.len() - 1);
        self.scrollTreeToCursor();
        // Nothing but the highlight moved -- see `TreeDirty`.
        self.markTreeDirty(.selection);
    }

    /// Keeps the tree's cursor inside the host-scrolled viewport by
    /// queueing a new `scroll_offset`, since the host has no idea zoe has
    /// a cursor. Queued rather than sent so it rides out in the same
    /// batch as the frame it belongs to (`tree_scroll_pending`).
    ///
    /// The cursor is kept `tree_scroll_margin` rows clear of both edges
    /// rather than merely on screen -- vim's `scrolloff`, and here it is
    /// load-bearing rather than a comfort: the host draws the horizontal
    /// scrollbar *over* the pane's bottom row, so a cursor allowed to sit
    /// on that row is a highlighted entry you cannot read. The margin is
    /// capped to half the viewport so it still behaves in a short pane,
    /// and the clamp at the end is what lets the end of the listing win
    /// -- there the trailing blank row (`tree_trailing_rows`) is what
    /// takes the scrollbar instead.
    fn scrollTreeToCursor(self: *Ui) void {
        self.scrollTreeToRow(self.tree.cursor, self.tree.len());
    }

    /// `scrollTreeToCursor` for any row of a `len`-row listing -- the
    /// name field's, which sits in a listing one row longer than the
    /// tree while a create is being typed.
    fn scrollTreeToRow(self: *Ui, row: usize, len: usize) void {
        const rows = self.tree_bounds.rows;
        if (rows == 0) return;
        const top = treeScrollTop(row, self.tree_scroll.row, rows, len);
        if (top == self.tree_scroll.row) return;

        self.tree_scroll.row = top;
        self.tree_scroll_pending = .{ .row = top, .col = self.tree_scroll.col };
    }

    /// Where the tree's viewport has to sit for a cursor at `cursor`,
    /// given the current offset `top`, a `rows`-tall pane and a `len`
    /// entry listing. Pure, so `tests/zoe_tests.zig` can pin the margin
    /// arithmetic -- which is all off-by-ones, and the cost of getting
    /// one wrong is an entry highlighted underneath the scrollbar.
    pub fn treeScrollTop(cursor: usize, top: usize, rows: usize, len: usize) usize {
        const margin = @min(tree_scroll_margin, (rows -| 1) / 2);
        var out = top;
        if (cursor < out + margin) out = cursor -| margin;
        if (cursor + margin >= out + rows) out = (cursor + margin + 1) -| rows;
        // Never past the end of the content: the last entries have
        // nothing below them to scroll into, and the margin gives way to
        // the trailing blank row, which is what takes the scrollbar there.
        return @min(out, (len + tree_trailing_rows) -| rows);
    }

    /// Enter/Space on a directory expands it, on a file opens it.
    fn treeActivate(self: *Ui) !void {
        const entry = self.tree.at(self.tree.cursor) orelse return;
        if (entry.is_dir) {
            try self.tree.toggle(self.io, self.tree.cursor);
            // A collapse can leave the host scrolled past the end of the
            // shortened listing; pull it back before the grid is resized
            // around it.
            self.clampTreeScroll();
            try self.syncContentSizes();
            // A collapse can leave the cursor inside the bottom margin of
            // a listing that just got shorter -- `clampTreeScroll` only
            // pulls the viewport back off the end, it knows nothing about
            // the cursor. Queued after the grid resize, so it rides out
            // with the repaint below.
            self.scrollTreeToCursor();
            // The listing itself changed shape.
            self.markTreeDirty(.full);
            return;
        }
        try self.openFile(entry.path);
        self.setFocus(.buffer);
    }

    // ── Tree pane search ────────────────────────────────────────────────

    /// Opens a search in `scope` (see `FindScope`). A `.deep` one walks
    /// the whole tree first, which is the only expensive thing either
    /// scope does and is why it happens once, here, rather than per
    /// keystroke.
    fn startFind(self: *Ui, scope: FindScope) !void {
        self.cancelFind();
        var find: TreeFind = .{ .scope = scope, .anchor = self.tree.cursor };
        errdefer find.deinit(self.alloc);
        if (scope == .deep) {
            const roots = try self.tree.rootPaths(self.alloc);
            defer self.alloc.free(roots);
            find.deep = try tree_mod.deepListRoots(self.alloc, self.io, roots, self.tree.visible);
        }
        self.find = find;
        self.status_dirty = true;
    }

    // ── Sidebar create / rename ─────────────────────────────────────────

    /// `a` / Shift+F4 (`.create`) and F7 (`.create_dir`): opens the name
    /// field for a new entry in the directory under the cursor -- the row
    /// itself when it is a directory, else the one it is in -- expanding
    /// that directory so the new row has a place among its children.
    fn startTreeCreate(self: *Ui, kind: TreeEdit.Kind) !void {
        self.cancelFind();
        self.cancelTreeEdit();
        const dir = try self.alloc.dupe(u8, self.tree.dirFor(self.tree.cursor));
        errdefer self.alloc.free(dir);
        const old_name = try self.alloc.dupe(u8, "");
        errdefer self.alloc.free(old_name);

        var row: usize = 0;
        var depth: usize = 0;
        if (try self.tree.openDirRow(self.io, dir)) |index| {
            row = index + 1;
            depth = self.tree.entries.items[index].depth + 1;
            self.tree.cursor = index;
        }
        self.tree_edit = .{ .kind = kind, .dir = dir, .old_name = old_name, .row = row, .depth = depth };
        self.showTreeEdit();
    }

    /// `r` / F2: opens the name field over the entry under the cursor,
    /// filled with its name and the caret before a file's extension --
    /// salacommander's F2 rule (`fsops.renameCaret`). Ctrl+U from there
    /// leaves just the extension to type in front of.
    fn startTreeRename(self: *Ui) !void {
        self.cancelFind();
        self.cancelTreeEdit();
        const e = self.tree.at(self.tree.cursor) orelse return;
        // A workspace folder's header is the folder itself, not a name in
        // some parent zoe is showing; `:rmfolder` is what takes it out of
        // the sidebar.
        if (e.is_root) {
            self.buf.ed.setStatus("E: \"{s}\" is a workspace folder; rename it outside zoe", .{e.name});
            self.status_dirty = true;
            return;
        }
        const dir = try self.alloc.dupe(u8, std.fs.path.dirname(e.path) orelse self.tree.roots.items[e.root].path);
        errdefer self.alloc.free(dir);
        const old_name = try self.alloc.dupe(u8, e.name);
        errdefer self.alloc.free(old_name);
        var field = try lineedit.LineEdit.init(self.alloc, e.name);
        errdefer field.deinit(self.alloc);
        _ = field.moveTo(fsops.renameCaret(e.name, e.is_dir));
        self.tree_edit = .{
            .kind = .rename,
            .field = field,
            .dir = dir,
            .old_name = old_name,
            .row = self.tree.cursor,
            .depth = e.depth,
        };
        self.showTreeEdit();
    }

    /// Puts a just-opened field on screen: the keyboard in the tree, the
    /// grid one row longer for a create, the field's row scrolled into
    /// view, and the listing repainted around it. Can't fail: the field
    /// already owns its strings, so the callers' cleanup is behind them.
    fn showTreeEdit(self: *Ui) void {
        const te = &self.tree_edit.?;
        self.setFocus(.tree);
        self.syncContentSizes() catch {};
        self.scrollTreeToRow(te.row, self.treeListedRows());
        self.markTreeDirty(.full);
        self.status_dirty = true;
    }

    /// Closes the name field without doing anything. Safe to call when
    /// there is none.
    fn cancelTreeEdit(self: *Ui) void {
        var te = self.tree_edit orelse return;
        te.deinit(self.alloc);
        self.tree_edit = null;
        self.clampTreeScroll();
        self.syncContentSizes() catch {};
        self.markTreeDirty(.full);
        self.status_dirty = true;
    }

    /// A named key while the field is up. It owns the keyboard: whatever
    /// the field doesn't use is swallowed rather than moving a cursor the
    /// field is drawn relative to.
    fn treeEditKey(self: *Ui, ev: glyphwire.KeyEvent) !void {
        const te = &self.tree_edit.?;
        switch (te.field.handleKey(ev.key, ev.mods)) {
            .submit => try self.commitTreeEdit(),
            .cancel => self.cancelTreeEdit(),
            .edited => {
                te.err = null;
                self.tree_edit_dirty = true;
                self.status_dirty = true;
            },
            .moved => self.tree_edit_dirty = true,
            .ignored => {},
        }
    }

    /// Typed text while the field is up.
    fn treeEditText(self: *Ui, text: []const u8) !void {
        const te = &self.tree_edit.?;
        if (!try te.field.insert(self.alloc, text)) return;
        te.err = null;
        self.tree_edit_dirty = true;
        self.status_dirty = true;
    }

    /// Enter in the field. A name that can't be used (exists already, has
    /// a `..`, or a `/` in a rename) keeps the field open with the reason
    /// on the statusline; anything else closes it, re-reads the tree and
    /// puts the cursor on the result. A new file also opens in a tab, with
    /// the keyboard there -- making one is a prelude to typing in it.
    fn commitTreeEdit(self: *Ui) !void {
        const te = &self.tree_edit.?;
        const name = te.field.text();
        // An empty field, or a rename left as it was, is a change of mind.
        if (name.len == 0 or (te.kind == .rename and std.mem.eql(u8, name, te.old_name))) {
            return self.cancelTreeEdit();
        }

        switch (te.kind) {
            .rename => {
                fsops.renameInDir(self.io, self.alloc, te.dir, te.old_name, name) catch |err| {
                    te.err = treeEditError(err);
                    self.status_dirty = true;
                    return;
                };
                const old_abs = try std.fs.path.join(self.alloc, &.{ te.dir, te.old_name });
                defer self.alloc.free(old_abs);
                const new_abs = try std.fs.path.join(self.alloc, &.{ te.dir, name });
                defer self.alloc.free(new_abs);
                self.retargetBuffers(old_abs, new_abs);
                self.cancelTreeEdit();
                try self.refreshTree(new_abs);
            },
            .create, .create_dir => {
                fsops.checkNewPath(name) catch |err| {
                    te.err = treeEditError(err);
                    self.status_dirty = true;
                    return;
                };
                const as_dir = te.kind == .create_dir or std.mem.endsWith(u8, name, "/");
                const abs = try std.fs.path.join(self.alloc, &.{ te.dir, std.mem.trimEnd(u8, name, "/") });
                defer self.alloc.free(abs);
                const made = if (as_dir) fsops.makeDir(self.io, abs) else fsops.makeFile(self.io, abs);
                made catch |err| {
                    te.err = treeEditError(err);
                    self.status_dirty = true;
                    return;
                };
                self.cancelTreeEdit();
                try self.refreshTree(abs);
                if (!as_dir) {
                    try self.openFile(abs);
                    self.setFocus(.buffer);
                }
            },
        }
    }

    /// The statusline text for a create or rename that didn't take.
    fn treeEditError(err: anyerror) []const u8 {
        return switch (err) {
            error.PathAlreadyExists => "E: that name already exists",
            error.InvalidName => "E: not a usable name (no `/` in a rename, no `.` or `..` parts)",
            error.EmptyName => "E: the name is empty",
            error.AccessDenied, error.PermissionDenied => "E: permission denied",
            error.FileNotFound => "E: it is no longer there",
            else => "E: the filesystem refused it",
        };
    }

    /// After a rename on disk: every open buffer on the renamed file, or
    /// anywhere under a renamed directory, follows it to the new path --
    /// otherwise its next `:w` would quietly recreate the old name. The
    /// language servers are told the old document closed; the buffer
    /// reopens under its new name on the next sync, the same as `:w
    /// <newname>` does it.
    fn retargetBuffers(self: *Ui, old_abs: []const u8, new_abs: []const u8) void {
        for (self.group_list.items) |g| {
            for (g.buffers.items) |slot| {
                const abs = self.slotAbs(slot) orelse continue;
                const rest: []const u8 = if (std.mem.eql(u8, abs, old_abs))
                    ""
                else if (std.mem.startsWith(u8, abs, old_abs) and abs.len > old_abs.len and abs[old_abs.len] == '/')
                    abs[old_abs.len..]
                else
                    continue;
                const moved = std.mem.concat(self.alloc, u8, &.{ new_abs, rest }) catch continue;
                defer self.alloc.free(moved);

                self.lspDidClose(slot);
                slot.ed.setPath(moved) catch continue;
                self.invalidateAbs(slot);
                slot.lsp_opened = false;
                slot.ed.line_comment = self.lineCommentFor(slot.ed.path);
                self.selectHighlightLanguage(slot, slot.ed.path);
                g.tabs_dirty = true;
            }
        }
        self.status_dirty = true;
    }

    fn cancelFind(self: *Ui) void {
        if (self.find) |*f| {
            f.deinit(self.alloc);
            self.find = null;
            self.status_dirty = true;
        }
    }

    /// A named key while a search is up. Returns true when the search
    /// consumed it, false to let the ordinary tree bindings have it.
    fn findKey(self: *Ui, ev: glyphwire.KeyEvent) !bool {
        const eq = std.mem.eql;
        const f = &self.find.?;

        if (eq(u8, ev.key, "escape")) {
            // The cursor stays where the search put it, and so does any
            // folder the search opened to get there: an abandoned search
            // has still told you where the file is.
            self.cancelFind();
            return true;
        }
        if (eq(u8, ev.key, "enter")) {
            self.cancelFind();
            try self.treeActivate();
            return true;
        }
        if (eq(u8, ev.key, "tab")) {
            if (f.hits.items.len == 0) return true;
            const n = f.hits.items.len;
            f.pick = if (ev.shift()) (f.pick + n - 1) % n else (f.pick + 1) % n;
            try self.applyFind();
            return true;
        }
        if (eq(u8, ev.key, "backspace")) {
            if (f.query.items.len == 0) {
                self.cancelFind();
                return true;
            }
            f.query.shrinkRetainingCapacity(lineedit.prevBoundary(f.query.items, f.query.items.len));
            if (f.query.items.len == 0) {
                self.cancelFind();
                return true;
            }
            try self.refilterFind();
            try self.applyFind();
            return true;
        }
        return false;
    }

    /// Typed text while a search is up. A character that would leave no
    /// candidates is dropped rather than appended, so the prefix always
    /// describes where the cursor is -- salacommander's type-to-find
    /// makes the same trade, and it is what stops a typo from stranding
    /// the search on a query nothing matches.
    fn findText(self: *Ui, text: []const u8) !void {
        const f = &self.find.?;
        var it = (std.unicode.Utf8View.init(text) catch return).iterator();
        while (it.nextCodepointSlice()) |cp| {
            // Tab and Enter reach the text stream as well as the key one,
            // and they are the search's own controls -- `findKey` has
            // already acted on them, so they are not also characters to
            // match on. No file name contains one either.
            if (cp.len == 1 and (cp[0] < 0x20 or cp[0] == 0x7f)) continue;
            const before = f.query.items.len;
            try f.query.appendSlice(self.alloc, cp);
            try self.refilterFind();
            if (f.hits.items.len == 0) {
                f.query.shrinkRetainingCapacity(before);
                try self.refilterFind();
                continue;
            }
            try self.applyFind();
        }
        self.status_dirty = true;
    }

    /// Rebuilds the candidate list for the current query and puts the
    /// pick back on the first one. Prefix-matched case-insensitively
    /// against the *name*, not the path: what is being typed is a file
    /// name, in both scopes.
    fn refilterFind(self: *Ui) !void {
        const f = &self.find.?;
        f.hits.clearRetainingCapacity();
        f.pick = 0;
        if (f.query.items.len == 0) return;

        switch (f.scope) {
            // Starting the walk at the row after the anchor is what makes
            // the search read as "forward from where I was", and the wrap
            // is why it still finds everything behind it.
            .visible => {
                const n = self.tree.len();
                const from = if (n == 0) 0 else (@min(f.anchor, n - 1) + 1) % n;
                var i: usize = 0;
                while (i < n) : (i += 1) {
                    const index = (from + i) % n;
                    if (std.ascii.startsWithIgnoreCase(self.tree.entries.items[index].name, f.query.items)) {
                        try f.hits.append(self.alloc, index);
                    }
                }
            },
            .deep => {
                const deep = &f.deep.?;
                for (deep.paths.items, 0..) |_, i| {
                    if (std.ascii.startsWithIgnoreCase(deep.nameAt(i), f.query.items)) {
                        try f.hits.append(self.alloc, i);
                    }
                }
            },
        }
    }

    /// Moves the cursor onto the picked candidate. In `.deep` scope that
    /// means opening whatever folders stand between the root and the hit
    /// (`Tree.reveal`), which changes the listing -- hence the full
    /// repaint and the content resize.
    fn applyFind(self: *Ui) !void {
        const f = &self.find.?;
        self.status_dirty = true;
        if (f.hits.items.len == 0) return;
        const hit = f.hits.items[f.pick];

        switch (f.scope) {
            .visible => self.treeGoto(hit),
            .deep => {
                const deep = &f.deep.?;
                const index = (try self.tree.revealIn(self.io, deep.root_of.items[hit], deep.paths.items[hit])) orelse return;
                try self.syncContentSizes();
                self.treeGoto(index);
                self.markTreeDirty(.full);
            },
        }
    }

    /// A left-button press or release. In the buffer pane a press moves
    /// the caret and arms a drag (which turns into a visual selection the
    /// moment the pointer moves); a release with no move is a plain click
    /// that clears any selection. Elsewhere it falls through to the tree.
    /// glyphwire-host forwards these raw now that zoe owns its context --
    /// it only keeps drags that land on its own chrome (dividers,
    /// scrollbars).
    fn handleMouseButton(self: *Ui, ev: glyphwire.MouseButtonEvent) !void {
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
    fn handleMouseDrag(self: *Ui, ev: glyphwire.MouseMoveEvent) !void {
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
    fn dropTab(self: *Ui, slot: *Slot, cell: glyphwire.CellPos) !void {
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
    fn tabDropTarget(self: *const Ui, cell: glyphwire.CellPos) ?DropShown {
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
    fn showDropTarget(self: *Ui, want: ?DropShown) void {
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
    fn lastByteOf(self: *const Ui, start: usize, end: usize) usize {
        if (end <= start) return start;
        return motion.prevCodepoint(&self.buf.ed.buf, end);
    }

    /// The tab under a root-grid cell, or null when the cell isn't in
    /// the strip. Screen columns are strip columns less the scroll, so
    /// the spans `renderTabs` recorded answer this directly.
    fn tabAt(g: *const Group, cell: glyphwire.CellPos) ?tabs.Hit {
        const b = g.tabs_bounds;
        if (b.cols == 0 or b.rows == 0) return null;
        if (cell.row < b.row or cell.row >= b.row + b.rows) return null;
        if (cell.col < b.col or cell.col >= b.col + b.cols) return null;
        return tabs.hit(g.tab_spans.items, cell.col - b.col + g.tab_scroll);
    }

    /// The group whose strip or pane is under `cell`, if any.
    fn groupAt(self: *const Ui, cell: glyphwire.CellPos) ?*Group {
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
    fn trackTabHover(self: *Ui, cell: glyphwire.CellPos) void {
        var over_group: ?*Group = null;
        const over: ?usize = blk: {
            // A drag and the finder both own the pointer while they last.
            if (self.drag != null or self.tab_drag != null or self.finder.isOpen()) break :blk null;
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

    fn tabTipDelayMs(self: *const Ui) i64 {
        const ms = if (self.hl_config) |cfg| cfg.tab_tooltip_delay_ms else langconf.tab_tooltip_delay_ms_default;
        return @intFromFloat(ms);
    }

    fn tabTipDue(self: *Ui) bool {
        const due = self.tab_tip_due orelse return false;
        return due.raw.durationTo(std.Io.Clock.awake.now(self.io)).toMilliseconds() >= 0;
    }

    fn showTabTip(self: *Ui) void {
        self.tab_tip_due = null;
        if (self.tab_tip_index == null) return;
        self.tab_tip_shown = true;
        self.tab_tip_dirty = true;
    }

    /// Takes the tooltip down (or stops it going up) for a key or click. The
    /// hovered tab is kept, so it doesn't come straight back on the next
    /// pointer move within the same tab.
    fn dismissTabTip(self: *Ui) void {
        self.tab_tip_due = null;
        if (!self.tab_tip_shown) return;
        self.tab_tip_shown = false;
        self.tab_tip_dirty = true;
    }

    /// The buffer byte offset under grid cell `cell`, or null if the
    /// cell isn't inside the buffer pane -- the test a press uses to
    /// decide between a buffer drag and a tree click.
    fn cellInBuffer(self: *Ui, cell: glyphwire.CellPos) ?usize {
        const b = self.grp.buffer_bounds;
        if (b.cols == 0 or b.rows == 0) return null;
        if (cell.row < b.row or cell.row >= b.row + b.rows) return null;
        if (cell.col < b.col or cell.col >= b.col + b.cols) return null;
        return self.cellToBufferByte(cell);
    }

    /// The buffer byte offset under grid cell `cell`, clamping the cell
    /// into the buffer pane first so a drag that wanders out of the pane
    /// still tracks its nearest edge.
    fn cellToBufferByte(self: *Ui, cell: glyphwire.CellPos) usize {
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
    fn isVisible(self: *Ui) bool {
        const vc = self.listener.visibleContext() orelse return true;
        return vc.context == self.context;
    }

    fn handleTreeClick(self: *Ui, ev: glyphwire.MouseButtonEvent) !void {
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

    /// The `:` line's keys that are completion's rather than the line's:
    /// Tab always, and with the popup up the keys that drive it. Returns
    /// whether the key was taken. See `zoe/pathmenu.zig`.
    fn cmdlineKey(self: *Ui, k: glyphwire.KeyEvent) !bool {
        const eq = std.mem.eql;
        const key = k.key;
        if (self.path_menu) |*m| {
            const rows = self.pathMenuRows();
            if ((eq(u8, key, "tab") and !k.mods.shift) or eq(u8, key, "down")) {
                m.move(1, rows);
                self.path_menu_dirty = true;
                return true;
            }
            if ((eq(u8, key, "tab") and k.mods.shift) or eq(u8, key, "up")) {
                m.move(-1, rows);
                self.path_menu_dirty = true;
                return true;
            }
            // Enter takes the pick into the line; it never runs the
            // command, so a pick can still be edited or Tab'd further.
            if (eq(u8, key, "enter")) {
                try self.acceptPathPick();
                return true;
            }
            // Escape closes the popup and leaves the `:` line as it is.
            if (eq(u8, key, "escape")) {
                self.closePathMenu();
                return true;
            }
            return false;
        }
        if (eq(u8, key, "tab") and !k.mods.ctrl and !k.mods.alt) {
            try self.completePath();
            return true;
        }
        return false;
    }

    /// Tab on the `:` line with no popup up. One match is filled in
    /// outright; several fill in their common prefix and open the popup.
    /// Nothing happens off a path argument or with no match.
    fn completePath(self: *Ui) !void {
        const cmd = &self.buf.ed.cmdline;
        const t = pathmenu.target(cmd.text(), cmd.caret) orelse return;
        const matches = try self.scanPathMatches(t);
        if (matches.len == 0) {
            pathcomplete.freeMatches(self.alloc, matches);
            return;
        }
        if (matches.len == 1) {
            defer pathcomplete.freeMatches(self.alloc, matches);
            const ins = try pathmenu.insertion(self.alloc, matches[0]);
            defer self.alloc.free(ins);
            try self.replaceCmdline(t.seg_start, cmd.caret, ins);
            return;
        }

        var names: std.ArrayList([]const u8) = .empty;
        defer names.deinit(self.alloc);
        for (matches) |m| try names.append(self.alloc, m.name);
        const lcp = pathcomplete.commonPrefixLen(names.items);
        if (lcp > t.prefix.len) {
            // `matches` is owned by the popup from here, so copy the
            // prefix out before the line edit could move anything.
            const shared = try self.alloc.dupe(u8, matches[0].name[0..lcp]);
            defer self.alloc.free(shared);
            try self.replaceCmdline(t.seg_start, cmd.caret, shared);
        }
        self.closePathMenu();
        self.path_menu = pathmenu.Menu.init(self.alloc, matches, t.seg_start);
        self.path_menu_dirty = true;
    }

    /// Enter in the popup: the pick replaces the segment. A directory
    /// goes straight on to listing its own entries, the way picking a
    /// folder in a file dialog opens it.
    fn acceptPathPick(self: *Ui) !void {
        const m = self.path_menu orelse return;
        const pick = m.current() orelse return self.closePathMenu();
        const ins = try pathmenu.insertion(self.alloc, pick);
        defer self.alloc.free(ins);
        const is_dir = pick.is_dir;
        const start = m.seg_start;
        self.closePathMenu();
        try self.replaceCmdline(start, self.buf.ed.cmdline.caret, ins);
        if (is_dir) try self.completePath();
        self.status_dirty = true;
    }

    /// After the `:` line changed under an open popup (typing, Backspace,
    /// a caret move): re-list against what the caret is now on, closing
    /// the popup once there is nothing to list or the line is gone.
    fn syncPathMenu(self: *Ui) !void {
        if (self.path_menu == null) return;
        if (self.focus != .buffer or self.buf.ed.mode != .command) return self.closePathMenu();
        const cmd = &self.buf.ed.cmdline;
        const t = pathmenu.target(cmd.text(), cmd.caret) orelse return self.closePathMenu();
        const matches = try self.scanPathMatches(t);
        if (matches.len == 0) {
            pathcomplete.freeMatches(self.alloc, matches);
            return self.closePathMenu();
        }
        self.closePathMenu();
        self.path_menu = pathmenu.Menu.init(self.alloc, matches, t.seg_start);
        self.path_menu_dirty = true;
    }

    fn closePathMenu(self: *Ui) void {
        if (self.path_menu) |*m| {
            m.deinit();
            self.path_menu = null;
            self.path_menu_dirty = true;
        }
    }

    /// The entries `t` can complete to, read from its directory with `~`
    /// expanded. Caller owns the result (`pathcomplete.freeMatches`).
    fn scanPathMatches(self: *Ui, t: pathmenu.Target) ![]pathcomplete.Match {
        var home_buf: [std.fs.max_path_bytes]u8 = undefined;
        const dir = homepath.expandHome(t.dir, self.environ.get("HOME"), &home_buf);
        const all = try pathcomplete.scanDir(self.alloc, self.io, dir, t.prefix);
        return if (t.dirs_only) pathmenu.keepDirs(self.alloc, all) else all;
    }

    /// Replaces bytes `[start, end)` of the `:` line with `text`, leaving
    /// the caret just after it.
    fn replaceCmdline(self: *Ui, start: usize, end: usize, text: []const u8) !void {
        const cmd = &self.buf.ed.cmdline;
        const line = cmd.text();
        const joined = try std.mem.concat(self.alloc, u8, &.{ line[0..start], text, line[end..] });
        defer self.alloc.free(joined);
        try cmd.setText(self.alloc, joined);
        _ = cmd.moveTo(start + text.len);
        self.status_dirty = true;
    }

    /// Rows the popup shows: as many matches as fit above the statusline,
    /// up to the completion popup's limit.
    fn pathMenuRows(self: *const Ui) usize {
        const m = self.path_menu orelse return 0;
        return @min(@min(m.count(), complete_max_rows), self.status_bounds.row);
    }

    /// Draws the filename popup, or hides it: one name per row, a
    /// directory with its `/`, standing on the statusline with its names
    /// lined up over the segment they would replace.
    fn renderPathMenu(self: *Ui, batch: *glyphwire.client.Client.Batch) !void {
        const m = if (self.path_menu) |*x| x else {
            try batch.setLayerVisible(self.path_menu_layer, false);
            return;
        };
        const sb = self.status_bounds;
        const rows = self.pathMenuRows();
        if (rows == 0 or sb.cols < 8) {
            try batch.setLayerVisible(self.path_menu_layer, false);
            return;
        }
        m.follow(rows);

        var want: usize = 12;
        for (0..rows) |r| {
            const it = m.visible(r) orelse break;
            want = @max(want, 1 + display.width(it.name, .{}) + 2);
        }
        const cols = @min(@min(want, complete_max_cols), sb.cols);

        // The names start one cell in, so that cell sits under the `:`
        // line's segment start (itself one past the `:`).
        const seg_col = sb.col + 1 + lineedit.displayCol(self.buf.ed.cmdline.text(), m.seg_start);
        const col = @max(sb.col, @min(seg_col -| 1, sb.col + (sb.cols - cols)));
        try batch.setLayerSize(self.path_menu_layer, cols, rows);
        try batch.setLayerCellPosition(self.path_menu_layer, sb.row - rows, col);

        for (0..rows) |r| {
            const it = m.visible(r) orelse break;
            const selected = m.top + r == m.selected;
            try batch.writeSpans(&.{
                .{ .text = " " },
                .{ .text = it.name, .fg = role(if (it.is_dir) .popup_kind else .popup_label) },
                .{ .text = if (it.is_dir) "/" else "", .fg = role(.popup_kind) },
            }, .{
                .layer = self.path_menu_layer,
                .row = r,
                .col = 0,
                .fg = role(.popup_label),
                .bg = role(if (selected) .popup_selected_bg else .popup_bg),
                .max_cols = cols,
                .pad = true,
                .selectable = false,
            });
        }
        try batch.setLayerVisible(self.path_menu_layer, true);
    }

    // ── Command-line history ────────────────────────────────────────────

    /// Reads `zoe_history` and `zoe_search_history` from the config
    /// directory. Anything going wrong leaves that history empty and
    /// unpersisted rather than failing startup; `GLYPHWIRE_NO_HISTORY`
    /// (what the tests set, as for gw-shell) turns persistence off.
    fn loadHistories(self: *Ui) void {
        if (self.environ.get("GLYPHWIRE_NO_HISTORY")) |v| {
            if (v.len > 0) return;
        }
        const dir = glyphwire.configDirPath(self.alloc, self.environ) catch return;
        defer self.alloc.free(dir);
        self.cmd_history_file = self.loadHistory(&self.cmd_history, dir, "zoe_history");
        self.search_history_file = self.loadHistory(&self.search_history, dir, "zoe_search_history");
    }

    /// Loads one history file into `hist`, returning its path (owned) for
    /// later writes, or null when it can't be used. A missing file is a
    /// first run: empty, but still written to.
    fn loadHistory(self: *Ui, hist: *cmdhistory.History, dir: []const u8, name: []const u8) ?[]u8 {
        const path = std.fs.path.join(self.alloc, &.{ dir, name }) catch return null;
        if (std.Io.Dir.cwd().readFileAlloc(self.io, path, self.alloc, .limited(8 << 20))) |bytes| {
            defer self.alloc.free(bytes);
            hist.load(bytes) catch |err| {
                std.log.warn("zoe: could not load {s}: {t}", .{ path, err });
                self.alloc.free(path);
                return null;
            };
        } else |err| switch (err) {
            error.FileNotFound => {},
            else => {
                std.log.warn("zoe: could not read {s}: {t}", .{ path, err });
                self.alloc.free(path);
                return null;
            },
        }
        return path;
    }

    /// Writes whichever history has lines the file hasn't seen. Run after
    /// every key, so it is a no-op almost always; a submitted `:` or `/`
    /// line is on disk before the next keystroke, which is what lets
    /// another zoe window's Up find it.
    fn flushHistories(self: *Ui) void {
        self.flushHistory(&self.cmd_history, self.cmd_history_file);
        self.flushHistory(&self.search_history, self.search_history_file);
    }

    /// Re-reads the file and merges this session's pending lines onto it
    /// (`history.mergeSerialize`), so two zoes add to the file instead of
    /// the last one to write reverting the other's.
    fn flushHistory(self: *Ui, hist: *cmdhistory.History, file: ?[]const u8) void {
        if (!hist.hasPending()) return;
        // Unpersisted, the pending list is only ever cleared here.
        const path = file orelse return hist.markWritten();
        const cwd = std.Io.Dir.cwd();
        const disk = cwd.readFileAlloc(self.io, path, self.alloc, .limited(8 << 20)) catch |err| switch (err) {
            error.FileNotFound => self.alloc.dupe(u8, "") catch return,
            else => {
                std.log.warn("zoe: could not read {s}: {t}", .{ path, err });
                return;
            },
        };
        defer self.alloc.free(disk);
        const bytes = hist.serializeOnto(disk) catch return;
        defer self.alloc.free(bytes);
        if (std.fs.path.dirname(path)) |d| cwd.createDirPath(self.io, d) catch {};
        cwd.writeFile(self.io, .{ .sub_path = path, .data = bytes }) catch |err| {
            std.log.warn("zoe: could not write {s}: {t}", .{ path, err });
            return;
        };
        hist.markWritten();
    }

    // ── Editor outcomes ─────────────────────────────────────────────────

    /// A path typed on the `:` line, with `~` read the way the shell reads
    /// it. Without this `:e ~/x` opened an empty buffer for a file
    /// literally named `./~/x`, which `:w` then had no directory to write.
    fn expandArg(self: *const Ui, arg: ?[]const u8, buf: []u8) ?[]const u8 {
        const a = arg orelse return null;
        return homepath.expandHome(a, self.environ.get("HOME"), buf);
    }

    fn applyOutcome(self: *Ui, outcome: editor.Outcome) !void {
        var home_buf: [std.fs.max_path_bytes]u8 = undefined;
        switch (outcome) {
            .none => {},
            .write => |target| self.save(self.expandArg(target, &home_buf)),
            .write_quit => |target| {
                self.save(self.expandArg(target, &home_buf));
                if (self.buf.ed.buf.dirty) return;
                if (self.refuseQuitForDirtyBuffer()) return;
                self.quit = true;
            },
            .quit => |q| {
                if (!q.force and self.refuseQuitForDirtyBuffer()) return;
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
            .ws_save => |target| self.workspaceSave(self.expandArg(target, &home_buf)),
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
        }
    }

    /// Fetches the system clipboard and splices it into the buffer at the
    /// cursor (`p` / `P`, and the Ctrl+Shift+P chord). A visual-mode `p`
    /// has already dropped the selection, so this is always a plain
    /// insert.
    fn pasteFromClipboard(self: *Ui, after: bool) !void {
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
    fn changeDir(self: *Ui, target: ?[]const u8) void {
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
    fn addFolder(self: *Ui, target: ?[]const u8) !void {
        self.status_dirty = true;
        const t = target orelse {
            self.buf.ed.setStatus("E471: Argument required", .{});
            return;
        };
        var abs_buf: [std.fs.max_path_bytes]u8 = undefined;
        const joined = self.absolutePath(t, &abs_buf) orelse {
            self.buf.ed.setStatus("E: path too long", .{});
            return;
        };
        // Normalized, so `../x` and `x/` name the folder the same way the
        // tree's root list does and a duplicate is caught.
        const abs = try std.fs.path.resolve(self.alloc, &.{joined});
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
    fn removeFolder(self: *Ui, target: ?[]const u8) !void {
        self.status_dirty = true;
        const index: usize = if (target) |t| blk: {
            var abs_buf: [std.fs.max_path_bytes]u8 = undefined;
            const joined = self.absolutePath(t, &abs_buf) orelse {
                self.buf.ed.setStatus("E: path too long", .{});
                return;
            };
            const abs = try std.fs.path.resolve(self.alloc, &.{joined});
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
    /// gets `.zoe-workspace`.
    fn workspaceSave(self: *Ui, target: ?[]const u8) void {
        self.status_dirty = true;
        const path = target orelse self.ws_file orelse {
            self.buf.ed.setStatus("E32: No workspace file name (:wssave <file>)", .{});
            return;
        };
        var arena_state = std.heap.ArenaAllocator.init(self.alloc);
        defer arena_state.deinit();
        const snap = self.workspaceSnapshot(arena_state.allocator()) catch |err| {
            self.buf.ed.setStatus("E: can't save the workspace ({t})", .{err});
            return;
        };
        var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
        const cwd_n = std.process.currentPath(self.io, &cwd_buf) catch {
            self.buf.ed.setStatus("E: cannot read working directory", .{});
            return;
        };
        const abs = zoe_workspace.save(self.alloc, self.io, cwd_buf[0..cwd_n], path, snap) catch |err| {
            switch (err) {
                error.VscodeWorkspace => self.buf.ed.setStatus("E: zoe doesn't write .code-workspace files; save to a .zoe-workspace", .{}),
                else => self.buf.ed.setStatus("E212: Can't write workspace {s} ({t})", .{ path, err }),
            }
            return;
        };
        // `path` may be the old `ws_file`; it isn't read past `save`.
        if (self.ws_file) |old| self.alloc.free(old);
        self.ws_file = abs;
        self.buf.ed.setStatus("workspace saved: {s}", .{abs});
    }

    /// What `:wssave` writes, borrowing from the tree, the slots and `th`
    /// -- valid until any of them changes. `arena` holds the rest.
    fn workspaceSnapshot(self: *Ui, arena: std.mem.Allocator) !zoe_workspace.Snapshot {
        const folders = try arena.alloc(zoe_workspace.FolderSpec, self.tree.roots.items.len);
        for (self.tree.roots.items, folders) |r, *f| f.* = .{ .path = r.path, .name = r.name };
        return .{
            .folders = folders,
            .theme = if (self.theme_own) self.th.name() else null,
            .editors = try self.snapshotNode(arena, self.layout.root),
        };
    }

    fn snapshotNode(self: *Ui, arena: std.mem.Allocator, node: *const groups.Node) !*const zoe_workspace.EditorNode {
        const out = try arena.create(zoe_workspace.EditorNode);
        switch (node.kind) {
            .split => |s| {
                // The proportions the user dragged the band to, read back
                // off the panes' bounds: zoe never sees the weights.
                const a = self.nodeRect(s.first);
                const b = self.nodeRect(s.second);
                const ea: usize, const eb: usize = switch (s.orientation) {
                    .vertical => .{ a.cols, b.cols },
                    .horizontal => .{ a.rows, b.rows },
                };
                const ratio: f32 = if (ea + eb == 0) 0.5 else @as(f32, @floatFromInt(ea)) / @as(f32, @floatFromInt(ea + eb));
                out.* = .{ .split = .{
                    .orientation = switch (s.orientation) {
                        .vertical => .vertical,
                        .horizontal => .horizontal,
                    },
                    .ratio = ratio,
                    .first = try self.snapshotNode(arena, s.first),
                    .second = try self.snapshotNode(arena, s.second),
                } };
            },
            .group => |id| {
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

    /// The cells a layout node covers: its group's, or the union of every
    /// group under a split.
    fn nodeRect(self: *const Ui, node: *const groups.Node) groups.Rect {
        switch (node.kind) {
            .group => |id| return self.groupById(id).rect(),
            .split => |s| {
                const a = self.nodeRect(s.first);
                const b = self.nodeRect(s.second);
                const row = @min(a.row, b.row);
                const col = @min(a.col, b.col);
                return .{
                    .row = row,
                    .col = col,
                    .rows = @max(a.row + a.rows, b.row + b.rows) - row,
                    .cols = @max(a.col + a.cols, b.col + b.cols) - col,
                };
            },
        }
    }

    /// `:wsopen <file>`: the workspace's folders replace the sidebar's,
    /// every tab closes and its editor groups come back in their place,
    /// and its theme (or, when it names none, zoe's usual choice) applies.
    /// The caller has already refused it over a modified buffer.
    fn workspaceOpen(self: *Ui, path: []const u8) !void {
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
    fn replaceFolders(self: *Ui, folders: []const zoe_workspace.Folder) !void {
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
    fn resetEditors(self: *Ui) !void {
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
            const removed = self.layout.remove(g.id) orelse break;
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
    fn releaseSlots(self: *Ui, g: *Group) void {
        for (g.buffers.items) |slot| {
            self.lspDidClose(slot);
            slot.deinit(self.alloc);
        }
        g.buffers.clearRetainingCapacity();
    }

    /// Rebuilds a saved `editors` tree from the single group zoe has at
    /// startup (or after `resetEditors`): each split grows a group off the
    /// one before it, each group opens its files, and the saved group gets
    /// the keyboard. The split proportions go on last, because building
    /// the tree re-sends lists at even weights as it goes.
    fn restoreEditors(self: *Ui, root: *const zoe_workspace.EditorNode) !void {
        std.debug.assert(self.group_list.items.len == 1);
        var focus: ?*Group = null;
        try self.restoreNode(root, self.grp, &focus);
        try self.applyRatios(self.layout.root, root);
        if (focus) |g| self.focusGroup(g);
        for (self.group_list.items) |each| each.markRedraw();
    }

    fn restoreNode(self: *Ui, node: *const zoe_workspace.EditorNode, g: *Group, focus: *?*Group) !void {
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
    fn fillGroup(self: *Ui, g: *Group, spec: zoe_workspace.EditorGroup) !void {
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

    fn isPristineScratch(slot: *const Slot) bool {
        return slot.ed.path == null and !slot.ed.buf.dirty and slot.ed.buf.len() == 0;
    }

    /// Sends each saved split's proportions to the host split that
    /// stands for it. `node` and `spec` have the same shape, since
    /// `restoreNode` built one from the other.
    fn applyRatios(self: *Ui, node: *const groups.Node, spec: *const zoe_workspace.EditorNode) !void {
        const s = switch (node.kind) {
            .split => |s| s,
            .group => return,
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
    fn applyWorkspaceTheme(self: *Ui, name: ?[]const u8) bool {
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
    fn treeChanged(self: *Ui) !void {
        self.clampTreeScroll();
        try self.syncContentSizes();
        self.scrollTreeToCursor();
        self.markTreeDirty(.full);
    }

    // ── Finder ──────────────────────────────────────────────────────────

    /// Ctrl+P. Walks the tree root and opens the popup over the buffer
    /// pane. The walk happens here, on every open, rather than being kept
    /// up to date in the background -- see applib/finder.zig.
    fn openFinder(self: *Ui) !void {
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
    fn acceptFinder(self: *Ui) !void {
        const path = (try self.finder.selectedPath(self.alloc)) orelse return self.finder.close();
        defer self.alloc.free(path);
        self.finder.close();
        try self.openFile(path);
        self.setFocus(.buffer);
    }

    /// A keystroke while the popup is open. It takes every key; see
    /// `finderpopup.applyKey`.
    fn finderKey(self: *Ui, k: glyphwire.KeyEvent) !void {
        if (try self.finder.key(k) == .accept) try self.acceptFinder();
    }

    // ── Buffers ─────────────────────────────────────────────────────────

    /// Opens `path` in a new tab, or switches to it when it is already
    /// open -- both `:e` and Enter on a file in the tree land here. The
    /// buffer being left keeps its text, its cursor and its parse tree,
    /// so coming back to it is a switch rather than a reload.
    fn openFile(self: *Ui, path: []const u8) !void {
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
    fn reloadCurrent(self: *Ui) !void {
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
    fn diskStamp(self: *Ui, path: []const u8) ?diskwatch.Stamp {
        const st = std.Io.Dir.cwd().statFile(self.io, path, .{}) catch return null;
        return .{ .size = st.size, .mtime_ns = st.mtime.nanoseconds };
    }

    /// Whether the once-a-second disk check has come due. Disarms it, so
    /// the next loop turn arms the next one.
    fn diskCheckDue(self: *Ui) bool {
        const due = self.disk_check_due orelse return false;
        if (due.raw.durationTo(std.Io.Clock.awake.now(self.io)).toMilliseconds() < 0) return false;
        self.disk_check_due = null;
        return true;
    }

    /// Stats every open buffer's file and follows the ones that changed
    /// outside zoe: a clean buffer reloads in place, a modified one gets
    /// one W11 warning per change and is otherwise left alone. See
    /// `zoe/diskwatch.zig` for the rules.
    fn checkDisk(self: *Ui) void {
        for (self.group_list.items) |g| {
            for (g.buffers.items) |slot| {
                const path = slot.ed.path orelse continue;
                const current = self.diskStamp(path);
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
    /// they close.
    fn checkTreeDisk(self: *Ui) !void {
        if (self.find != null or self.tree_edit != null) return;
        if (!self.tree.changedOnDisk(self.io)) return;
        try self.refreshTree(null);
    }

    /// Re-reads the tree and repaints it, with the cursor on `onto` (an
    /// absolute path) when given -- the entry a create or rename just
    /// made -- or else on the entry it was on.
    fn refreshTree(self: *Ui, onto: ?[]const u8) !void {
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
    fn reloadFromDisk(self: *Ui, g: *Group, slot: *Slot, stamp: diskwatch.Stamp) void {
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
    fn refuseQuitForDirtyBuffer(self: *Ui) bool {
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
    fn findPath(self: *const Ui, path: []const u8) ?SlotAt {
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
    fn setActive(self: *Ui, index: usize) void {
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
    fn stepBuffer(self: *Ui, forward: bool) void {
        const n = self.grp.buffers.items.len;
        if (n < 2) return;
        self.setActive(if (forward) (self.grp.active + 1) % n else (self.grp.active + n - 1) % n);
    }

    /// Closes tab `index` of the focused group. A modified buffer refuses
    /// unless `force`, the same E37 guard `:q` uses and what the tab's `×`
    /// reports when it can't close. Closing a group's last buffer closes
    /// the group, unless it is the only one: that is left an empty
    /// scratch buffer, so `buf` always points somewhere.
    fn closeBuffer(self: *Ui, index: usize, force: bool) !void {
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
    fn lineCommentFor(self: *const Ui, path: ?[]const u8) ?[]const u8 {
        const p = path orelse return null;
        const langs = if (self.hl_config) |cfg| cfg.langs else &syntax.default_langs;
        return syntax.lineCommentFor(langs, p);
    }

    fn save(self: *Ui, target: ?[]const u8) void {
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
        self.lspDidSave();
        // The tab loses its `+`, and a `:w <name>` also renamed it.
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

    /// Starts the configured servers, if any. Best-effort in every
    /// direction: LSP is not part of the editor's correctness, so a server
    /// that isn't installed, won't spawn or won't answer leaves zoe exactly
    /// as it was without one.
    fn startLsp(self: *Ui, folders: []const Tree.RootSpec, environ: *const std.process.Environ.Map) void {
        lsp.debug = environ.get("GLYPHWIRE_LSP_DEBUG") != null;
        const cfg = self.hl_config orelse {
            // No config means no server list, and also no grammar registry --
            // so this is the same failure that turns highlighting off.
            std.log.warn("zoe: no config loaded; language servers are off", .{});
            return;
        };
        if (!cfg.lsp_enabled) return;

        // Rooted at the first folder, with every folder in its
        // `workspaceFolders` (added before `start`, so they ride along in
        // `initialize` rather than as a change).
        var pool = lsp.Pool.init(self.alloc, self.io, lsp.Waker.fromListener(self.listener), folders[0].path) catch return;
        for (folders[1..]) |f| pool.addFolder(f.path, f.name) catch {};
        pool.start(cfg.lsp_servers, environ) catch {};
        if (pool.servers.items.len == 0) {
            // Nothing started. Keep the pool anyway so `:lsp` can list what
            // it looked for and didn't find, but don't reserve the gutter
            // column for marks that will never come.
            self.lsp_pool = pool;
            return;
        }
        self.lsp_pool = pool;
        self.signs = true;
    }

    /// The grammar name for `path`, which doubles as the key servers are
    /// registered under. Null when nothing claims the extension -- the same
    /// answer that turns highlighting off for a file.
    fn lspGrammarFor(self: *Ui, path: ?[]const u8) ?[]const u8 {
        const reg = if (self.grammars) |*r| r else return null;
        const p = path orelse return null;
        return reg.nameForPath(p);
    }

    /// Tells every server that serves this buffer's language about it.
    /// A buffer with no path (a scratch one) and a file no server claims are
    /// both simply not announced.
    fn lspDidOpen(self: *Ui, slot: *Slot) void {
        const pool = if (self.lsp_pool) |*p| p else return;
        if (slot.lsp_opened) return;
        const path = slot.ed.path orelse return;
        const grammar = self.lspGrammarFor(path) orelse return;

        const abs = self.slotAbs(slot) orelse return;
        const uri = lsp.pathToUri(self.alloc, abs) catch return;
        defer self.alloc.free(uri);
        const text = slot.ed.buf.text(self.alloc) catch return;
        defer self.alloc.free(text);

        var any = false;
        var it = pool.forLanguage(grammar);
        while (it.next()) |s| {
            s.didOpen(uri, lsp.languageId(grammar), text) catch continue;
            any = true;
        }
        if (!any) return;
        slot.lsp_opened = true;
        slot.lsp_sent_edits = slot.ed.buf.edits;
    }

    /// The counterpart, on `:bd`. The stored diagnostics go too: a closed
    /// buffer's marks would otherwise come back with the next file to reuse
    /// the slot.
    fn lspDidClose(self: *Ui, slot: *Slot) void {
        const pool = if (self.lsp_pool) |*p| p else return;
        if (!slot.lsp_opened) return;
        const path = slot.ed.path orelse return;
        const grammar = self.lspGrammarFor(path) orelse return;

        const abs = self.slotAbs(slot) orelse return;
        const uri = lsp.pathToUri(self.alloc, abs) catch return;
        defer self.alloc.free(uri);

        var it = pool.forLanguage(grammar);
        while (it.next()) |s| s.didClose(uri) catch {};
        self.diags.clearPath(abs);
        slot.lsp_opened = false;
    }

    /// `:w` -- some servers only report on save (and `ruff`'s formatting
    /// checks are among them), so this is not redundant with `didChange`.
    fn lspDidSave(self: *Ui) void {
        const pool = if (self.lsp_pool) |*p| p else return;
        // A `:w <newname>` makes this a file the servers have never seen;
        // announce it rather than saving under a name they don't know.
        if (!self.buf.lsp_opened) {
            self.lspDidOpen(self.buf);
            return;
        }
        const path = self.buf.ed.path orelse return;
        const grammar = self.lspGrammarFor(path) orelse return;
        const abs = self.slotAbs(self.buf) orelse return;
        const uri = lsp.pathToUri(self.alloc, abs) catch return;
        defer self.alloc.free(uri);

        // The save is the newest state, so any debounced change is spent.
        self.lspFlushChange();
        var it = pool.forLanguage(grammar);
        while (it.next()) |s| s.didSave(uri) catch {};
    }

    /// Arms the `didChange` debounce if the active buffer has moved on since
    /// the servers were last told. Called once a frame from `run`, which is
    /// enough: the deadline is what decides when the message goes, not how
    /// often this is called.
    fn armLspChange(self: *Ui) void {
        if (self.lsp_pool == null) return;
        if (!self.buf.lsp_opened) return;
        if (self.buf.ed.buf.edits == self.buf.lsp_sent_edits) return;
        if (self.lsp_change_due != null) return;
        self.lsp_change_due = std.Io.Clock.Timestamp.fromNow(self.io, .{
            .raw = .fromMilliseconds(lsp_change_debounce_ms),
            .clock = .awake,
        });
    }

    /// Sends the active buffer's whole text as a `didChange` and disarms the
    /// debounce. Full text rather than ranges -- see the design note: the
    /// incremental form needs a second consumer of `Buffer.pending_edits`,
    /// which the highlighter currently drains alone.
    fn lspFlushChange(self: *Ui) void {
        self.lsp_change_due = null;
        const pool = if (self.lsp_pool) |*p| p else return;
        if (!self.buf.lsp_opened) return;
        if (self.buf.ed.buf.edits == self.buf.lsp_sent_edits) return;

        const path = self.buf.ed.path orelse return;
        const grammar = self.lspGrammarFor(path) orelse return;
        const abs = self.slotAbs(self.buf) orelse return;
        const uri = lsp.pathToUri(self.alloc, abs) catch return;
        defer self.alloc.free(uri);
        const text = self.buf.ed.buf.text(self.alloc) catch return;
        defer self.alloc.free(text);

        self.buf.lsp_version += 1;
        var it = pool.forLanguage(grammar);
        while (it.next()) |s| s.didChange(uri, self.buf.lsp_version, text) catch {};
        self.buf.lsp_sent_edits = self.buf.ed.buf.edits;
    }

    /// The earliest of the `didChange` debounce, the completion and tab
    /// tooltip delays, and the oldest outstanding request's timeout, or null
    /// for none -- the loop's whole notion of time.
    fn nextLspDeadline(self: *Ui) ?std.Io.Clock.Timestamp {
        var best = earlier(earlier(earlier(self.lsp_change_due, self.completion_due), self.tab_tip_due), self.disk_check_due);
        const pool = if (self.lsp_pool) |*p| p else return best;
        if (pool.nextDeadlineMs()) |req_ms| {
            best = earlier(best, .{
                .raw = .fromNanoseconds(@as(i96, req_ms) * std.time.ns_per_ms),
                .clock = .awake,
            });
        }
        return best;
    }

    fn earlier(a: ?std.Io.Clock.Timestamp, b: ?std.Io.Clock.Timestamp) ?std.Io.Clock.Timestamp {
        const x = a orelse return b;
        const y = b orelse return a;
        return if (x.raw.nanoseconds <= y.raw.nanoseconds) x else y;
    }

    /// Whether the debounce has come due, checked after every wait.
    fn lspChangeDue(self: *Ui) bool {
        const due = self.lsp_change_due orelse return false;
        // Through `.raw`, the clock-free timestamp: the deadline is kept as a
        // `Clock.Timestamp` because that is what `Io.Timeout` takes.
        return due.raw.durationTo(std.Io.Clock.awake.now(self.io)).toMilliseconds() >= 0;
    }

    /// `path` as an absolute path, owned by the caller. Every LSP URI is
    /// absolute, and zoe's buffer paths are whatever was typed -- so this is
    /// also what makes a diagnostic for `./src/main.zig` and one for the
    /// absolute path the same file.
    fn absPath(self: *Ui, path: []const u8) ?[]u8 {
        if (std.fs.path.isAbsolute(path)) return std.fs.path.resolve(self.alloc, &.{path}) catch null;
        var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
        const n = std.process.currentPath(self.io, &cwd_buf) catch return null;
        return std.fs.path.resolve(self.alloc, &.{ cwd_buf[0..n], path }) catch null;
    }

    /// Names this context `zoe <file>` after the focused buffer (`~` for
    /// `$HOME`), or `zoe <cwd>` for a buffer with no file yet. Only sends
    /// when it changed, so the per-frame call is a string compare.
    fn syncTitle(self: *Ui) void {
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

    /// `slot`'s absolute path, resolved once and cached on the slot (see
    /// `Slot.abs_path`). Borrowed -- the slot owns it. Null for a buffer with
    /// no file behind it, which is also "nothing a language server can say
    /// anything about".
    fn slotAbs(self: *Ui, slot: *Slot) ?[]const u8 {
        if (slot.abs_path) |p| return p;
        const path = slot.ed.path orelse return null;
        const abs = self.absPath(path) orelse return null;
        slot.abs_path = abs;
        return abs;
    }

    /// Drops the cached absolute path, for whatever just changed `ed.path`
    /// (`:w <newname>`, `:e`).
    fn invalidateAbs(self: *Ui, slot: *Slot) void {
        if (slot.abs_path) |p| self.alloc.free(p);
        slot.abs_path = null;
    }

    /// Drains everything the servers have said since the last turn round the
    /// loop. Called once per iteration of `run`, before the frame, so an
    /// arriving diagnostic is drawn in the same frame as the keystroke that
    /// happened to wake us.
    fn drainLsp(self: *Ui) void {
        const pool = if (self.lsp_pool) |*p| p else return;
        while (pool.nextEvent() catch null) |ev| self.handleLspEvent(ev);
        // After the replies, so one that landed just inside its deadline
        // counts as answered rather than timed out.
        const now = lsp.nowMs(self.io);
        while (pool.expire(now)) |ev| self.handleLspEvent(ev);
    }

    fn handleLspEvent(self: *Ui, ev: lsp.Event) void {
        var e = ev;
        defer e.deinit(self.alloc);
        switch (e) {
            .diagnostics => |d| self.applyDiagnostics(d.path, d.server, d.items),
            .hover => |h| self.applyHover(h.request_id, h.text),
            .definition => |d| self.applyDefinition(d.request_id, d.target),
            .completion => |*c| {
                // The items move into the popup rather than being copied:
                // a completion list can run to thousands of entries.
                const items = c.items;
                c.items = &.{};
                self.applyCompletion(c.request_id, c.server, items, c.incomplete);
            },
            .timed_out => |t| self.applyTimeout(t.request_id, t.server, t.kind),
            .died => |d| {
                // Its marks will never be refreshed again, so they go
                // rather than growing stale on screen.
                self.diags.clearServer(d.server);
                self.buf.ed.setStatus("LSP: {s} exited (:lsp restart)", .{d.server});
                self.status_dirty = true;
                self.buf.full_redraw = true;
                self.grp.buffer_dirty = true;
            },
        }
    }

    /// A request the server never answered. Said on the statusline only when
    /// it is the one the editor is still waiting on: a stale request timing
    /// out (the user already asked again) is nobody's business.
    fn applyTimeout(self: *Ui, request_id: i64, server: []const u8, kind: lsp.RequestKind) void {
        const slot: *?i64 = switch (kind) {
            .hover => &self.hover_request,
            .definition => &self.definition_request,
            .completion => &self.completion_request,
            .initialize, .shutdown => return,
        };
        if (slot.* != request_id) return;
        slot.* = null;
        self.buf.ed.setStatus("LSP: {s} didn't answer {t}", .{ server, kind });
        self.status_dirty = true;
    }

    // ── Completion ──────────────────────────────────────────────────────

    /// Asks for completions at the cursor. `trigger` is the trigger
    /// character just typed, or null for an identifier being typed or an
    /// explicit Ctrl+Space; `explicit` is the last, which is the only one
    /// that says so on the statusline when nothing can answer.
    fn requestCompletion(self: *Ui, trigger: ?[]const u8, explicit: bool) void {
        self.completion_due = null;
        const pool = if (self.lsp_pool) |*p| p else {
            if (explicit) {
                self.buf.ed.setStatus("LSP: not enabled", .{});
                self.status_dirty = true;
            }
            return;
        };
        if (self.buf.ed.mode != .insert) return;
        const path = self.buf.ed.path orelse return;
        const grammar = self.lspGrammarFor(path) orelse return;
        const abs = self.slotAbs(self.buf) orelse return;
        const uri = lsp.pathToUri(self.alloc, abs) catch return;
        defer self.alloc.free(uri);

        // The server must see what was just typed, or it completes the word
        // as it was before the last few keys.
        self.lspFlushChange();

        const cursor = self.buf.ed.pos();
        const line_text = self.buf.ed.buf.lineText(self.alloc, cursor.line) catch return;
        defer self.alloc.free(line_text);
        const ws = complete.wordStart(line_text, cursor.col);
        // A delayed identifier request whose word has gone by the time it
        // fires (the space after it was typed in the pause).
        if (trigger == null and !explicit and ws == cursor.col and self.completion == null) return;

        var it = pool.forLanguage(grammar);
        while (it.next()) |s| {
            if (!s.ready()) continue;
            const id = s.completionRequest(uri, .{
                .line = @intCast(cursor.line),
                .character = lsp.byteToCharacter(line_text, cursor.col, s.encoding),
            }, trigger) catch continue orelse continue;
            self.completion_request = id;
            self.completion_req_start = self.buf.ed.buf.lineStart(cursor.line) + ws;
            self.completion_req_line = cursor.line;
            return;
        }
        if (explicit) {
            self.buf.ed.setStatus("LSP: no server here can complete", .{});
            self.status_dirty = true;
        }
    }

    /// A completion reply: open (or replace) the popup, filtered by whatever
    /// has been typed since the request went out. Takes ownership of
    /// `items` whatever happens to them.
    fn applyCompletion(
        self: *Ui,
        request_id: i64,
        server: []const u8,
        items: []lsp.CompletionItem,
        incomplete: bool,
    ) void {
        var owned: ?[]lsp.CompletionItem = items;
        defer if (owned) |o| lsp.freeCompletionItems(self.alloc, o);

        if (self.completion_request != request_id) return;
        self.completion_request = null;
        if (self.buf.ed.mode != .insert or self.focus != .buffer) return;

        // Still on the word it was asked about? A reply for a line the
        // cursor has left, or a word backspaced away, is stale.
        const cursor = self.buf.ed.pos();
        const start = self.completion_req_start;
        if (cursor.line != self.completion_req_line or self.buf.ed.cursor < start) return;

        if (items.len == 0) {
            if (!incomplete) self.completion_empty_at = start;
            self.closeCompletion();
            return;
        }

        // Edit ranges are in the server's encoding, and describe the line as
        // it was when the server read it -- convert now, the way diagnostics
        // are, so from here on a range's `character` is a byte column.
        if (self.lsp_pool) |*pool| {
            const enc = pool.encodingOf(server);
            const line_text = self.buf.ed.buf.lineText(self.alloc, cursor.line) catch return;
            defer self.alloc.free(line_text);
            for (items) |*item| {
                if (item.edit_range) |*r| {
                    if (r.start.line != cursor.line) {
                        item.edit_range = null;
                        continue;
                    }
                    r.start.character = @intCast(lsp.characterToByte(line_text, r.start.character, enc));
                }
            }
        }

        self.closeCompletion();
        owned = null;
        self.completion = complete.Menu.init(self.alloc, items, start, cursor.line, incomplete);
        self.refilterCompletion();
    }

    /// Narrows the open popup to what is now typed after its word start,
    /// closing it when nothing matches.
    fn refilterCompletion(self: *Ui) void {
        const m = if (self.completion) |*x| x else return;
        const typed = self.buf.ed.buf.read(self.alloc, m.word_start, self.buf.ed.cursor) catch {
            self.closeCompletion();
            return;
        };
        defer self.alloc.free(typed);
        m.refilter(typed) catch {
            self.closeCompletion();
            return;
        };
        if (m.count() == 0) {
            if (!m.incomplete) self.completion_empty_at = m.word_start;
            self.closeCompletion();
            return;
        }
        self.completion_dirty = true;
    }

    fn closeCompletion(self: *Ui) void {
        if (self.completion) |*m| {
            m.deinit();
            self.completion = null;
            self.completion_dirty = true;
        }
    }

    /// Whether `text` ends in a completion trigger character for any server
    /// on the current buffer.
    fn isCompletionTrigger(self: *Ui, text: []const u8) bool {
        const pool = if (self.lsp_pool) |*p| p else return false;
        const path = self.buf.ed.path orelse return false;
        const grammar = self.lspGrammarFor(path) orelse return false;
        var it = pool.forLanguage(grammar);
        while (it.next()) |s| if (s.ready() and s.isCompletionTrigger(text)) return true;
        return false;
    }

    /// After an insert-mode edit: open, narrow or close the popup.
    ///
    /// `typed` is the text just typed, or null for a deletion. A trigger
    /// character asks at once; an identifier being typed asks after
    /// `complete_auto_delay_ms` of quiet; with the popup already up, typing
    /// only narrows it (and asks again only if the server said its list was
    /// incomplete). A deletion never opens the popup, only narrows or
    /// closes it.
    fn afterInsertEdit(self: *Ui, typed: ?[]const u8) void {
        if (self.lsp_pool == null) return;
        if (self.buf.ed.mode != .insert or self.focus != .buffer) {
            self.closeCompletion();
            return;
        }
        const cursor = self.buf.ed.pos();
        const line_text = self.buf.ed.buf.lineText(self.alloc, cursor.line) catch return;
        defer self.alloc.free(line_text);
        const ws_col = complete.wordStart(line_text, cursor.col);
        const ws = self.buf.ed.buf.lineStart(cursor.line) + ws_col;
        const at_word = ws < self.buf.ed.cursor;
        // The word an empty answer was for is gone; a new one gets asked.
        if (!at_word) self.completion_empty_at = null;

        if (typed) |t| if (self.isCompletionTrigger(t)) {
            self.closeCompletion();
            self.requestCompletion(t, false);
            return;
        };

        if (self.completion) |m| {
            // Left the word: typed a space or punctuation, or deleted past
            // its start.
            if (m.line != cursor.line or m.word_start != ws) {
                self.closeCompletion();
            } else {
                const incomplete = m.incomplete;
                self.refilterCompletion();
                if (incomplete) self.armCompletion();
                return;
            }
        }

        if (typed == null or !at_word) return;
        // `123` is a number being typed, not a name to complete.
        if (std.ascii.isDigit(line_text[ws_col])) return;
        if (self.completion_empty_at == ws) return;
        // Already asked about this word; the reply will be filtered by what
        // has been typed since.
        if (self.completion_request != null and self.completion_req_start == ws) return;
        self.armCompletion();
    }

    fn armCompletion(self: *Ui) void {
        if (self.completion_due != null) return;
        self.completion_due = std.Io.Clock.Timestamp.fromNow(self.io, .{
            .raw = .fromMilliseconds(complete_auto_delay_ms),
            .clock = .awake,
        });
    }

    fn completionDue(self: *Ui) bool {
        const due = self.completion_due orelse return false;
        return due.raw.durationTo(std.Io.Clock.awake.now(self.io)).toMilliseconds() >= 0;
    }

    /// Closes the popup when what it was for has gone: insert mode left, the
    /// sidebar or the finder took the keyboard, or the cursor moved off the
    /// word (a click, an arrow). Run once a turn, so no path that moves the
    /// cursor has to remember the popup exists.
    fn syncCompletion(self: *Ui) void {
        const in_insert = self.buf.ed.mode == .insert and self.focus == .buffer and
            !self.finder.isOpen() and !self.shell.isFocused();
        if (!in_insert) {
            self.completion_due = null;
            self.completion_request = null;
            self.completion_empty_at = null;
            self.closeCompletion();
            return;
        }
        const m = if (self.completion) |*x| x else return;
        const cursor = self.buf.ed.pos();
        if (cursor.line != m.line or self.buf.ed.cursor < m.word_start) self.closeCompletion();
    }

    /// Inserts the selected completion over the word it completes: the
    /// server's edit range when it sent one on this line, else the word
    /// before the cursor.
    fn acceptCompletion(self: *Ui) !void {
        const m = if (self.completion) |*x| x else return;
        const item = m.current() orelse {
            self.closeCompletion();
            return;
        };
        var start = m.word_start;
        if (item.edit_range) |r| {
            start = @min(self.buf.ed.buf.lineStart(m.line) + r.start.character, self.buf.ed.cursor);
        }
        try self.buf.ed.replaceBeforeCursor(start, item.insert);
        // Whatever comes next starts a new word; don't let this one's empty
        // answer (or its request) hold that up.
        self.completion_empty_at = null;
        self.closeCompletion();
        self.buf.full_redraw = true;
        self.grp.buffer_dirty = true;
        self.status_dirty = true;
        self.grp.tabs_dirty = true;
    }

    /// A key while the popup is up. Returns true when the popup took it.
    ///
    /// Up/Down and Ctrl+N/Ctrl+P move (taken before the global Ctrl+N and
    /// Ctrl+P chords, which only apply with the popup closed), Tab and Enter
    /// accept, Escape closes only the popup so a second one leaves insert
    /// mode. Left/Right/Home/End close it and then move as usual.
    fn completionKey(self: *Ui, k: glyphwire.KeyEvent) !bool {
        const eq = std.mem.eql;
        const m = if (self.completion) |*x| x else return false;
        const rows = @min(m.count(), complete_max_rows);
        const ctrl = k.ctrl();
        // Alt+Up/Down moves the line, not the popup's cursor; the popup
        // closes like it does for any other cursor move.
        if (k.alt() and (eq(u8, k.key, "up") or eq(u8, k.key, "down"))) {
            self.closeCompletion();
            return false;
        }
        if (eq(u8, k.key, "down") or (ctrl and eq(u8, k.key, "n"))) {
            m.move(1, rows);
        } else if (eq(u8, k.key, "up") or (ctrl and eq(u8, k.key, "p"))) {
            m.move(-1, rows);
        } else if (eq(u8, k.key, "page_down")) {
            m.move(@intCast(rows), rows);
        } else if (eq(u8, k.key, "page_up")) {
            m.move(-@as(i64, @intCast(rows)), rows);
        } else if (!ctrl and (eq(u8, k.key, "tab") or eq(u8, k.key, "enter") or eq(u8, k.key, "kp_enter"))) {
            try self.acceptCompletion();
            return true;
        } else if (eq(u8, k.key, "escape")) {
            self.closeCompletion();
            return true;
        } else {
            if (eq(u8, k.key, "left") or eq(u8, k.key, "right") or
                eq(u8, k.key, "home") or eq(u8, k.key, "end"))
            {
                self.closeCompletion();
            }
            return false;
        }
        self.completion_dirty = true;
        return true;
    }

    /// Stores one publish, converting each range out of the server's
    /// position encoding into byte columns first.
    ///
    /// Converting here rather than at paint time is the only correct moment:
    /// the positions describe the text the server analysed, and the buffer
    /// may have moved on by the time a row is drawn. It also puts the
    /// encoding question in one place -- from here down, a diagnostic's
    /// `character` is a byte offset in its line, like every other column in
    /// the editor.
    fn applyDiagnostics(self: *Ui, path: []const u8, server: []const u8, items: []lsp.Diagnostic) void {
        const pool = if (self.lsp_pool) |*p| p else return;
        const enc = pool.encodingOf(server);

        // The buffer this is about, if it is open. A server may publish for
        // any file in the project, including ones zoe has never opened;
        // those are stored unconverted (nothing paints them) rather than
        // dropped, so `:diag` could list them later.
        const slot: ?*Slot = self.slotForPath(path);
        if (slot) |sl| {
            for (items) |*d| {
                d.range.start.character = self.byteColumn(sl, d.range.start, enc);
                d.range.end.character = self.byteColumn(sl, d.range.end, enc);
            }
        }

        // `publish` copies, so `items` stays the event's to free either way.
        self.diags.publish(path, server, items) catch return;

        // Every visible row may have gained or lost a mark, and the marks
        // live on cells the row painter owns.
        //
        // Whichever group shows it, focused or not.
        if (slot) |sl| if (self.findSlot(sl)) |at| if (at.group.slot() == sl) {
            sl.full_redraw = true;
            at.group.buffer_dirty = true;
            self.status_dirty = true;
        };
    }

    /// The byte column in `slot`'s line for an LSP position under `enc`.
    fn byteColumn(self: *Ui, slot: *Slot, pos: lsp.Position, enc: lsp.PositionEncoding) u32 {
        if (pos.line >= slot.ed.buf.lineCount()) return pos.character;
        const text = slot.ed.buf.lineText(self.alloc, pos.line) catch return pos.character;
        defer self.alloc.free(text);
        return @intCast(lsp.characterToByte(text, pos.character, enc));
    }

    fn slotForPath(self: *Ui, abs: []const u8) ?*Slot {
        for (self.group_list.items) |g| {
            for (g.buffers.items) |slot| {
                const slot_abs = self.slotAbs(slot) orelse continue;
                if (std.mem.eql(u8, slot_abs, abs)) return slot;
            }
        }
        return null;
    }

    /// `K` and `gd`: ask whichever attached server can answer.
    ///
    /// The first capable server wins rather than all of them being asked.
    /// With basedpyright and ruff both on a Python file only one of them
    /// even claims `hover`, and if two did, two popups for one keystroke is
    /// not an improvement.
    fn requestLsp(self: *Ui, kind: lsp.RequestKind) void {
        const pool = if (self.lsp_pool) |*p| p else {
            self.buf.ed.setStatus("LSP: not enabled", .{});
            self.status_dirty = true;
            return;
        };
        const path = self.buf.ed.path orelse return;
        const grammar = self.lspGrammarFor(path) orelse return;
        const abs = self.slotAbs(self.buf) orelse return;
        const uri = lsp.pathToUri(self.alloc, abs) catch return;
        defer self.alloc.free(uri);

        // Anything typed since the last sync would make the server answer
        // about text that is no longer there.
        self.lspFlushChange();

        const cursor = self.buf.ed.pos();
        // Why nothing could answer, for the message below. "No server" and
        // "the server is still starting up" are very different situations to
        // be in, and one message for both sends you looking for a
        // misconfiguration when the answer is to wait a second.
        var any_server = false;
        var any_starting = false;
        var it = pool.forLanguage(grammar);
        while (it.next()) |s| {
            any_server = true;
            if (s.starting()) {
                any_starting = true;
                continue;
            }
            const line_text = self.buf.ed.buf.lineText(self.alloc, cursor.line) catch continue;
            defer self.alloc.free(line_text);
            const character = lsp.byteToCharacter(line_text, cursor.col, s.encoding);
            const id = s.positionRequest(kind, uri, .{
                .line = @intCast(cursor.line),
                .character = character,
            }) catch continue orelse continue;
            switch (kind) {
                .hover => self.hover_request = id,
                .definition => self.definition_request = id,
                else => {},
            }
            return;
        }
        self.status_dirty = true;
        if (any_starting) {
            self.buf.ed.setStatus("LSP: still starting up, try again", .{});
        } else if (any_server) {
            // A server is attached but doesn't advertise this request -- ruff
            // on a Python file has no hover, for instance.
            self.buf.ed.setStatus("LSP: attached server can't answer that", .{});
        } else {
            self.buf.ed.setStatus("LSP: no server for {s} (:lsp)", .{grammar});
        }
    }

    /// A hover reply. A reply to a request that is no longer the newest is
    /// dropped: the user asked again, or has moved on, and a popup for a
    /// cursor position two jumps back is worse than none.
    fn applyHover(self: *Ui, request_id: i64, text: ?[]const u8) void {
        const want = self.hover_request orelse return;
        if (request_id != want) return;
        self.hover_request = null;

        const t = text orelse {
            self.buf.ed.setStatus("No hover information", .{});
            self.status_dirty = true;
            return;
        };
        // Parsed into the doc's own arena, so nothing is borrowed from the
        // event, which frees `t` on return.
        var doc = hover_mod.parse(self.alloc, t) catch return;
        if (doc.lines.len == 0) {
            doc.deinit();
            self.buf.ed.setStatus("No hover information", .{});
            self.status_dirty = true;
            return;
        }
        const spans = self.highlightHoverBlocks(&doc) catch {
            doc.deinit();
            return;
        };
        if (self.hover) |*h| h.deinit();
        self.hover = .{ .doc = doc, .spans = spans };
        self.hover_dirty = true;
    }

    /// Colours every fenced block in a hover with the grammar its fence
    /// names -- or, for a bare fence, the grammar of the buffer being
    /// hovered, which is what a language server means by one. A block whose
    /// language has no grammar installed stays plain; so does everything
    /// when highlighting is off.
    ///
    /// Each block is parsed on its own, as a tiny buffer, rather than as
    /// part of the whole reply: a signature is a complete fragment in its
    /// language, and the prose around it is not.
    fn highlightHoverBlocks(self: *Ui, doc: *hover_mod.Doc) ![]const []const syntax.Span {
        const a = doc.arena.allocator();
        const out = try a.alloc([]const syntax.Span, doc.lines.len);
        @memset(out, &.{});
        if (doc.blocks.len == 0) return out;

        const reg = if (self.grammars) |*g| g else return out;
        const fallback: ?[]const u8 = if (self.buf.hl) |*bh| bh.lang_name else null;
        if (self.hover_hl == null) {
            self.hover_hl = syntax.Highlighter.init(self.alloc, syntax.Theme.fromTheme(&self.th.theme)) catch return out;
            // No injections: a hover's code block is a signature, and a
            // grammar nested in one is not worth the second parse.
            self.hover_hl.?.configureInjections(reg, false);
        }
        const h = &self.hover_hl.?;
        // The language borrows the block's name out of the doc's arena, so
        // it must not outlive this call.
        defer h.clearLanguage();

        var scratch: std.ArrayList(syntax.Span) = .empty;
        defer scratch.deinit(self.alloc);
        for (doc.blocks) |b| {
            if (b.count == 0) continue;
            const lang = if (b.lang.len > 0) b.lang else fallback orelse continue;
            const grammar = reg.get(lang) orelse continue;
            h.setLanguage(lang, grammar) catch continue;

            const src = try doc.blockSource(self.alloc, b);
            defer self.alloc.free(src);
            var buf = try buffer_mod.Buffer.initFromText(self.alloc, src);
            defer buf.deinit();
            h.reparse(src) catch continue;

            for (b.first..b.first + b.count) |i| {
                const line = i - b.first;
                h.lineSpans(buf.lineStart(line), buf.lineEnd(line), &scratch) catch continue;
                out[i] = try a.dupe(syntax.Span, scratch.items);
            }
        }
        return out;
    }

    /// A definition reply: jump, recording where we came from so Ctrl+O
    /// comes back.
    fn applyDefinition(self: *Ui, request_id: i64, target: ?lsp.Location) void {
        const want = self.definition_request orelse return;
        if (request_id != want) return;
        self.definition_request = null;

        const loc = target orelse {
            self.buf.ed.setStatus("No definition found", .{});
            self.status_dirty = true;
            return;
        };

        self.pushJump();
        // Another file is a tab; the same file is just a cursor move. Either
        // way the target is the range's *start*: a definition's range covers
        // the whole declaration, and landing on its first character is what
        // every editor does.
        const same = if (self.slotAbs(self.buf)) |abs|
            std.mem.eql(u8, abs, loc.path)
        else
            false;

        if (!same) {
            self.openFile(loc.path) catch {
                self.buf.ed.setStatus("E484: Can't open {s}", .{loc.path});
                self.status_dirty = true;
                return;
            };
        }
        self.gotoLineColumn(loc.range.start.line, loc.range.start.character);
    }

    /// Moves the cursor to a (line, byte column) pair, clamped into the
    /// buffer. Shared by `gd`, `]d` and the jumplist.
    fn gotoLineColumn(self: *Ui, line: u32, column: u32) void {
        const lines = self.buf.ed.buf.lineCount();
        const target_line = @min(@as(usize, line), lines -| 1);
        const start = self.buf.ed.buf.lineStart(target_line);
        const end = self.buf.ed.buf.lineEnd(target_line);
        self.buf.ed.setCursor(@min(start + column, end));
        self.buf.full_redraw = true;
        self.grp.buffer_dirty = true;
        self.status_dirty = true;
    }

    /// `]d` / `[d`, wrapping round the file like vim's quickfix stepping
    /// does. A buffer with no diagnostics says so rather than moving the
    /// cursor to nowhere.
    fn stepDiagnostic(self: *Ui, forward: bool) void {
        const abs = self.slotAbs(self.buf) orelse return;

        const cursor = self.buf.ed.pos();
        const dir: diag.Direction = if (forward) .next else .prev;
        const found = self.diags.step(abs, @intCast(cursor.line), @intCast(cursor.col), dir) orelse
            // Off the end: wrap. Doing it here rather than in the store
            // keeps `step` honest for callers that shouldn't wrap.
            (if (forward) self.diags.first(abs) else self.diags.last(abs)) orelse {
                self.buf.ed.setStatus("No diagnostics", .{});
                self.status_dirty = true;
                return;
            };
        self.gotoLineColumn(found.range.start.line, found.range.start.character);
        self.buf.ed.setStatus("{s}: {s}", .{ found.source, found.message });
    }

    /// `:theme` reports the current theme; `:theme <name>` switches this
    /// editor to a built-in or one of `zoe.conf.lua`'s or `theme.lua`'s
    /// `themes`; `:theme window` goes back to following the window's.
    fn themeCommand(self: *Ui, arg: ?[]const u8) void {
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

    fn followWindowTheme(self: *Ui) !void {
        try self.client.setTheme(null);
        const st = try self.client.getTheme();
        try self.themeChanged(st);
    }

    /// `:theme <name>`: `t` becomes this context's own theme.
    fn applyTheme(self: *Ui, t: themes.Theme) !void {
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
    fn themeChanged(self: *Ui, st: themes.Stored) !void {
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
        }
        try c.setLayerBackground(self.hover_layer, if (self.hover_panel_patch == null) role(.popup_bg) else null);
        try c.setLayerBackground(self.tab_tip_layer, if (self.tab_tip_patch == null) role(.popup_bg) else null);
        try self.finder.setStyle(finderStyle(&self.th));

        self.tree_dirty = .full;
        self.status_dirty = true;
    }

    /// Replaces a popup layer's panel nine-patch with the current theme's
    /// `panel_style`, sized like `init` sizes it (the popup's own render
    /// resizes it to fit). Null when the host has no such style, which
    /// draws the popup flat.
    fn swapPanelPatch(
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

    /// `:lsp` / `:lsp restart`.
    fn lspStatus(self: *Ui, arg: ?[]const u8) void {
        self.status_dirty = true;
        const pool = if (self.lsp_pool) |*p| p else {
            self.buf.ed.setStatus("LSP: disabled in zoe.conf.lua", .{});
            return;
        };
        if (arg) |a| {
            if (std.mem.eql(u8, a, "restart")) {
                self.restartLsp();
                return;
            }
            self.buf.ed.setStatus("LSP: unknown argument \"{s}\" (try :lsp restart)", .{a});
            return;
        }

        var msg: std.ArrayList(u8) = .empty;
        defer msg.deinit(self.alloc);
        msg.appendSlice(self.alloc, "LSP:") catch return;
        if (pool.servers.items.len == 0 and pool.missing.items.len == 0) {
            msg.appendSlice(self.alloc, " no servers configured") catch return;
        }
        for (pool.servers.items) |s| {
            const state = if (!s.alive()) "dead" else if (s.state == .starting) "starting" else "ready";
            msg.print(self.alloc, " {s}[{s}]", .{ s.name, state }) catch return;
        }
        // Named rather than silently absent: "nothing happened" with no
        // explanation is the worst answer a feature like this can give.
        for (pool.missing.items) |name| {
            msg.print(self.alloc, " {s}[not installed]", .{name}) catch return;
        }
        self.buf.ed.setStatus("{s}", .{msg.items});
    }

    /// Tears the pool down and starts it again, re-announcing every open
    /// buffer. The recovery path for a server that crashed -- deliberately
    /// manual, because a server that died on a file will die on it again and
    /// a respawn loop is worse than a dead server.
    fn restartLsp(self: *Ui) void {
        if (self.lsp_pool) |*p| p.deinit();
        self.lsp_pool = null;
        self.diags.deinit();
        self.diags = diag.Store.init(self.alloc);
        for (self.group_list.items) |g| {
            for (g.buffers.items) |slot| slot.lsp_opened = false;
        }

        // The sidebar's folders as they stand now -- `:addfolder` and a
        // single-folder `:cd` included.
        var specs: std.ArrayList(Tree.RootSpec) = .empty;
        defer specs.deinit(self.alloc);
        for (self.tree.roots.items) |r| specs.append(self.alloc, .{ .path = r.path, .name = r.name }) catch return;
        self.startLsp(specs.items, self.environ);
        for (self.group_list.items) |g| {
            for (g.buffers.items) |slot| self.lspDidOpen(slot);
            // The sign column's marks went with the old store.
            g.markRedraw();
        }

        self.buf.ed.setStatus("LSP: restarted", .{});
    }

    /// `:diag` -- this buffer's diagnostics, on the statusline. A one-line
    /// summary plus the first message, which is what fits; the popup list
    /// this deserves is the finder's job and a later slice.
    fn diagList(self: *Ui) void {
        self.status_dirty = true;
        const abs = self.slotAbs(self.buf) orelse return;

        const c = self.diags.counts(abs);
        if (c.errors == 0 and c.warnings == 0) {
            self.buf.ed.setStatus("No diagnostics", .{});
            return;
        }
        const first = self.diags.first(abs) orelse return;
        self.buf.ed.setStatus("{d}E {d}W  {d}: {s}: {s}", .{
            c.errors,
            c.warnings,
            first.range.start.line + 1,
            first.source,
            first.message,
        });
    }

    /// Records where the cursor is, before something moves it somewhere
    /// else entirely.
    fn pushJump(self: *Ui) void {
        const path = self.buf.ed.path orelse return;
        self.jumps.push(self.alloc, path, self.buf.ed.cursor) catch {};
    }

    /// Ctrl+O / Ctrl+I.
    fn jumpStep(self: *Ui, back: bool) void {
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
    fn diagColor(_: *const Ui, severity: lsp.Severity) Color {
        return switch (severity) {
            .err => role(.diag_error),
            .warning => role(.diag_warning),
            .information => role(.diag_info),
            .hint => role(.diag_hint),
        };
    }

    // ── Render ──────────────────────────────────────────────────────────

    /// One batch for the whole frame, so the panes go from the previous
    /// state to this one in a single rendered frame rather than a band at
    /// a time (decisions.md's Batch section). Each pane is redrawn only
    /// when its own dirty flag is set: a keystroke on the `:` line marks
    /// just the status row, leaving the buffer's syntax pass and the
    /// tree's per-entry icons untouched.
    fn render(self: *Ui) !void {
        self.syncTitle();
        var batch = self.client.batch();
        defer batch.deinit();
        const t_build = self.prof.now();
        const nested_before = self.prof.nestedNs();

        // Before the rows, so the host has scrolled to where the cursor
        // is by the time the frame it belongs to lands.
        if (self.tree_scroll_pending) |p| {
            self.tree_scroll_pending = null;
            try batch.setLayerScrollOffset(self.tree_layer, p.row, p.col);
        }

        // Read before the groups are drawn, which clears their flags: the
        // completion popup is placed against the focused buffer and has
        // to follow it when it repaints.
        const focused_buffer_dirty = self.grp.buffer_dirty;
        for (self.group_list.items) |g| {
            if (!g.buffer_dirty and !g.tabs_dirty) continue;
            try self.renderGroup(&batch, g);
        }
        if (self.tree_visible) switch (self.tree_dirty) {
            .none => {},
            .selection => try self.renderTreeSelection(&batch),
            .full => try self.renderTree(&batch),
        };
        // A keystroke in the sidebar's name field: its row and nothing
        // else, unless the whole listing was just written anyway.
        if (self.tree_visible and self.tree_edit_dirty and self.tree_dirty != .full)
            try self.renderTreeEditRow(&batch, self.treeContentCols());
        if (self.status_dirty) try self.renderStatus(&batch);
        // Last in the frame, as they are last in the compositing order. The
        // hover popup after the finder: both float, and a hover raised while
        // the finder is open is the newer of the two.
        if (self.finder.dirty) {
            const b = self.grp.buffer_bounds;
            try self.finder.render(&batch, .{ .row = b.row, .col = b.col, .cols = b.cols, .rows = b.rows });
        }
        if (self.hover_dirty) try self.renderHover(&batch);
        // Placed against the word being typed, so it follows a buffer
        // repaint (a scroll, a wrap) as well as its own changes.
        if (self.completion_dirty or (self.completion != null and focused_buffer_dirty))
            try self.renderCompletion(&batch);
        if (self.path_menu_dirty) try self.renderPathMenu(&batch);
        if (self.tab_tip_dirty) try self.renderTabTip(&batch);
        self.prof.addNet(.paint, t_build, nested_before);

        if (self.prof.enabled()) {
            for (batch.msgs.items) |m| self.prof.bytes += m.len;
        }
        const t_send = self.prof.now();
        // Synced: returns once the server has applied the frame, so zoe
        // never has a second one in flight. Input that arrives meanwhile
        // queues on the listener and the run loop folds all of it into
        // the next frame -- which is what keeps a fast mouse drag from
        // turning into a backlog of frames the screen trails behind.
        var results = try batch.sendSynced();
        results.deinit();
        self.prof.add(.send, t_send);
        self.prof.endFrame();

        self.tree_dirty = .none;
        self.tree_edit_dirty = false;
        self.status_dirty = false;
        self.hover_dirty = false;
        self.completion_dirty = false;
        self.path_menu_dirty = false;
        self.tab_tip_dirty = false;
    }

    fn anyGroupDirty(self: *const Ui) bool {
        for (self.group_list.items) |g| {
            if (g.buffer_dirty or g.tabs_dirty) return true;
        }
        return false;
    }

    /// Draws one group's dirty panes into `batch`.
    ///
    /// The render helpers all draw "the" group -- `grp`, and its shown
    /// buffer `buf` -- because that is the one the keyboard edits and
    /// nearly every change is to. A group without the keyboard is drawn
    /// by pointing the pair at it for the duration, so the same code
    /// paints every group; `render_focused` keeps the caret off it.
    fn renderGroup(self: *Ui, batch: *glyphwire.client.Client.Batch, g: *Group) !void {
        const focused_grp = self.grp;
        const focused_buf = self.buf;
        self.grp = g;
        self.buf = g.slot();
        self.render_focused = g == focused_grp;
        defer {
            self.grp = focused_grp;
            self.buf = focused_buf;
            self.render_focused = true;
        }

        if (g.buffer_dirty) try self.renderBuffer(batch);
        if (g.tabs_dirty) {
            try self.renderTabs(batch);
            // The strip was laid out or scrolled again, and the tooltip
            // hangs from its tab.
            if (self.tab_tip_shown and self.tab_tip_group == g) self.tab_tip_dirty = true;
        }
        g.buffer_dirty = false;
        g.tabs_dirty = false;
    }

    /// Raises the tree pane's pending repaint to at least `level`. Never
    /// lowers it: a full repaint already owed stays owed however many
    /// cursor moves land on top of it before the next frame.
    fn markTreeDirty(self: *Ui, level: TreeDirty) void {
        if (@intFromEnum(level) > @intFromEnum(self.tree_dirty)) self.tree_dirty = level;
    }

    /// Writes one run at `(row, col)` on a layer -- a single positioned
    /// `write_text`.
    fn writeAt(
        batch: *glyphwire.client.Client.Batch,
        layer: glyphwire.LayerHandle,
        row: usize,
        col: usize,
        text: []const u8,
        fg: Color,
        bg: Color,
    ) !void {
        try batch.writeTextOpts(text, .{ .layer = layer, .row = row, .col = col, .fg = fg, .bg = bg });
    }

    /// Redraws the buffer pane.
    ///
    /// The pane is exactly viewport-sized (see the module note), so a
    /// scroll can't be a host viewport move -- zoe owns `top_line` and
    /// repaints. But repainting *every* visible row on every scroll tick
    /// is `b.rows` write pairs down the socket per keystroke, which is
    /// what made the pane feel heavy. So: on a pure vertical scroll of
    /// less than a screen, shift the rows already on the layer with one
    /// `move_content` and repaint only the band the scroll exposed. An
    /// edit, a horizontal scroll, a jump of a screen or more, or a
    /// bounds change (`Slot.full_redraw`) still repaints in full --
    /// cases a row shift can't represent -- except that an edit whose
    /// highlighting effect an incremental reparse could bound repaints
    /// only the rows it touched (`renderChangedRows`).
    fn renderBuffer(self: *Ui, batch: *glyphwire.client.Client.Batch) !void {
        const b = self.grp.buffer_bounds;
        if (b.cols == 0 or b.rows == 0) return;
        self.scrollBufferToCursor();
        try self.syncBufferScrollbar(batch);
        // What every screen row shows this frame; all the row painters
        // below read it.
        try self.layoutRows();
        const row_hash = rowMapHash(self.row_map.items);

        // A fresh edit (or the first parse after choosing a language)
        // means the tree is stale. `syncHighlight` reparses -- incremental
        // when it can, whole-buffer otherwise -- and reports whether the
        // repaint can be confined to `hl_dirty_lines`.
        var localized = false;
        if (self.buf.hl) |*h| {
            if (h.languageSet() and self.buf.ed.buf.edits != self.buf.hl_edits) {
                const t_parse = self.prof.now();
                defer self.prof.add(.parse, t_parse);
                localized = self.syncHighlight(h) catch blk: {
                    self.buf.full_redraw = true;
                    break :blk false;
                };
                self.buf.hl_edits = self.buf.ed.buf.edits;
            }
            self.buf.ed.buf.clearEdits();
        }
        // Every row this frame paints reads its colours from the cache;
        // fill in the visible lines it is missing first, a run at a time.
        self.fillSpanCache();

        const cursor = self.buf.ed.pos();
        const scrolled = self.buf.top_line != self.buf.prev_top_line or
            self.buf.top_sub != self.buf.prev_top_sub or
            self.buf.left_col != self.buf.prev_left_col;
        const edited = self.buf.ed.buf.edits != self.buf.prev_edits;
        // Wrapped, an edit that changed how many rows a line takes moved
        // every row below it -- more than the edited lines to repaint.
        if (self.buf.ed.wrap and edited and row_hash != self.buf.prev_row_hash) self.buf.full_redraw = true;

        // A visual selection covers rows the caret never touches. When it
        // changed, the rows to repaint are the ones whose highlight
        // differs between the old span and the new -- one or two for a
        // drag step or a motion. That diff is in byte offsets, which an
        // edit moves, so an edit with a selection on either side of it
        // still repaints in full.
        const sel = self.buf.ed.selectionSpan();
        const sel_changed = !selEql(sel, self.buf.prev_sel);
        if (edited and (sel != null or self.buf.prev_sel != null)) self.buf.full_redraw = true;
        var repainted_full = false;
        // The scroll in screen rows, which wrapped is not the change in
        // `top_line`: measured from a common origin `rows` up so a
        // scroll either way stays unsigned. Too far to shift is a full
        // repaint.
        var prev_top = self.buf.prev_top_line;
        var top = self.buf.top_line;
        if (self.buf.ed.wrap and scrolled and !edited and !self.buf.full_redraw) {
            if (self.wrappedScrollDelta(b.rows)) |d| {
                prev_top = b.rows;
                top = @intCast(@as(i64, @intCast(b.rows)) + d);
            } else self.buf.full_redraw = true;
        }
        if (!self.buf.full_redraw and !scrolled and !edited and !localized) {
            // Nothing but the caret moved (a bare `h`/`j`/`k`/`l`, a
            // word motion, an on-screen `:23k`): the pane is already
            // right everywhere except the rows the caret left and
            // landed on. Repaint just those -- no per-row syntax pass
            // over the whole viewport.
            try self.repaintCaretRows(batch, cursor.line);
        } else if (localized and !self.buf.full_redraw and !scrolled) {
            try self.renderChangedRows(batch, cursor.line);
        } else plan: switch (planBufferRender(.{
            .prev_top = prev_top,
            .top = top,
            .prev_left = self.buf.prev_left_col,
            .left = self.buf.left_col,
            .prev_edits = self.buf.prev_edits,
            .edits = self.buf.ed.buf.edits,
            .rows = b.rows,
            .force_full = self.buf.full_redraw,
        })) {
            .full => {
                try self.renderBufferRows(batch, 0, b.rows);
                repainted_full = true;
                break :plan;
            },
            .shift => |s| {
                // The scrolled-past rows are still valid where they land;
                // only the newly-uncovered band at one edge needs drawing.
                try batch.moveContent(self.grp.buffer_layer, null, null, s.count, s.dir);
                try self.renderBufferRows(batch, s.exposed_lo, s.exposed_hi);

                // The caret is drawn as an inverted cell over its row;
                // repaint the row it left (to clear that cell) and the row
                // it's on now, unless the exposed band already covered them.
                for (self.row_map.items, 0..) |rv, r| {
                    if (rv.line != self.buf.prev_cursor_line and rv.line != cursor.line) continue;
                    if (r >= s.exposed_lo and r < s.exposed_hi) continue;
                    try self.renderBufferRow(batch, r);
                }
            },
        }

        // The rows the selection change covers, wherever the paths above
        // left them (a shift moved them along; the caret rows are
        // already fresh, which a second paint of costs nothing but bytes).
        if (sel_changed and !repainted_full) try self.repaintSelectionChange(batch, self.buf.prev_sel, sel, cursor.line);

        // The line-number gutter. Every text path above repainted it for
        // the rows it drew. A `move_content` scroll slides the old numbers
        // along with their lines, which leaves an `.absolute` gutter right
        // as it is -- each number still sits beside its own line, and the
        // caret's highlighted number rode along with it and was repainted
        // above. Only `.relative` numbers go stale: a scroll or a caret
        // move changes every row's distance. Repaint the whole gutter then.
        if (self.gutterWidth() > 0 and self.buf.ed.line_numbers == .relative and
            (scrolled or cursor.line != self.buf.prev_cursor_line))
        {
            var r: usize = 0;
            while (r < b.rows) : (r += 1) try self.renderGutterCell(batch, r);
        }

        // The caret is a block drawn as one inverted cell, on top of the
        // row just (re)painted. The host's own caret renderer only knows
        // about the root layer, and a client that owns its pane knows
        // better than the host where its cursor is anyway.
        //
        // Unless the host is drawing it (`caretShape`: insert mode's bar,
        // or the hollow box of an unfocused window), in which case all
        // that is left to do here is say which cell it belongs on.
        //
        // Only the group with the keyboard has a caret at all.
        if (self.render_focused) {
            if (try self.caretCell(cursor.line)) |at| {
                const row = at.row;
                const col = at.col;
                self.caret_at = .{ .row = row, .left = at.left };
                if (self.caretShape() != null) {
                    try batch.setCursorOn(self.grp.buffer_layer, row, col);
                } else {
                    const under = try self.cursorGrapheme();
                    defer self.alloc.free(under);
                    try writeAt(batch, self.grp.buffer_layer, row, col, under, role(.cursor_fg), role(.cursor_bg));
                }
            }
        }

        self.buf.prev_top_line = self.buf.top_line;
        self.buf.prev_top_sub = self.buf.top_sub;
        self.buf.prev_row_hash = row_hash;
        self.buf.prev_left_col = self.buf.left_col;
        self.buf.prev_cursor_line = cursor.line;
        self.buf.prev_edits = self.buf.ed.buf.edits;
        self.buf.prev_sel = sel;
        self.buf.full_redraw = false;
    }

    /// Where the caret goes in the buffer pane: its screen row, its pane
    /// column, and the display column its row starts at -- or null when
    /// the caret's line is scrolled out of view (or, unwrapped, its
    /// column is). Wrapped, a caret past the last character of a line
    /// that fills its last row exactly is held on that row's last cell
    /// rather than dropped.
    fn caretCell(self: *Ui, line: usize) !?struct { row: usize, col: usize, left: usize } {
        const dcol = try self.cursorDisplayCol();
        const cols = self.textCols();
        for (self.row_map.items, 0..) |rv, r| {
            if (rv.line != line) continue;
            if (dcol < rv.left) continue;
            if (dcol >= rv.left + rv.cols and !rv.last) continue;
            var rel = dcol - rv.left;
            if (rel >= cols) {
                if (!self.buf.ed.wrap or cols == 0) return null;
                rel = cols - 1;
            }
            return .{ .row = r, .col = self.gutterWidth() + rel, .left = rv.left };
        }
        return null;
    }

    /// Repaints the on-screen rows whose selection highlight differs
    /// between `old` and `new`, skipping the caret's row (repainted
    /// already). Two spans of the same kind differ only where their ends
    /// moved, so only the lines around those two byte ranges change; a
    /// selection appearing, disappearing or switching between charwise and
    /// linewise changes every line either one covers.
    fn repaintSelectionChange(
        self: *Ui,
        batch: *glyphwire.client.Client.Batch,
        old: ?editor.Editor.SelSpan,
        new: ?editor.Editor.SelSpan,
        cursor_line: usize,
    ) !void {
        var ranges: [2]selection_diff.ByteRange = undefined;
        const n = selection_diff.changedRanges(old, new, &ranges);
        const buf = &self.buf.ed.buf;
        for (ranges[0..n]) |range| {
            // A byte either side: whether a line's highlight runs to the
            // pane edge depends on the span reaching its newline, which
            // is the byte just before the next line's start.
            const first = buf.lineAt(range.start -| 1);
            const last = buf.lineAt(range.end);
            for (self.row_map.items, 0..) |rv, r| {
                if (rv.line < first or rv.line > last) continue;
                if (rv.line == cursor_line or rv.line == self.buf.prev_cursor_line) continue;
                try self.renderBufferRow(batch, r);
            }
        }
    }

    /// Repaints the buffer rows the caret just left and just landed on.
    /// Used when nothing else about the pane changed, so every other row
    /// is already correct; `renderBuffer`'s caret pass draws the block
    /// cursor on top afterwards.
    fn repaintCaretRows(self: *Ui, batch: *glyphwire.client.Client.Batch, cursor_line: usize) !void {
        for (self.row_map.items, 0..) |rv, r| {
            if (rv.line == self.buf.prev_cursor_line or rv.line == cursor_line)
                try self.renderBufferRow(batch, r);
        }
    }

    /// Brings the highlighter's tree back in sync with the buffer after
    /// an edit. Returns true when it managed an incremental reparse and
    /// filled `hl_dirty_lines` with a bounded set of buffer lines that
    /// -- together with the edited lines -- covers every highlighting
    /// change, so the caller can repaint just those rows. Returns false
    /// (and sets `Slot.full_redraw`) when the whole visible pane must
    /// be repainted: no retained tree, the edit journal overflowed, the
    /// line count changed, the injection layout shifted, or the change
    /// is simply too broad to localise.
    fn syncHighlight(self: *Ui, h: *syntax.Highlighter) !bool {
        const buf = &self.buf.ed.buf;
        self.hl_dirty_lines.clearRetainingCapacity();

        // A whole-buffer parse: the first one, or one an edit journal can't
        // be replayed onto -- including a prefix tree from a staged parse
        // still running, which an edit restarts. Staged, so a big file
        // draws its first screen highlighted without waiting for the rest
        // (see `beginParse`); `run` finishes it between events.
        if (!h.ready() or h.parsing() or buf.edits_overflowed or buf.pending_edits.items.len == 0) {
            const text = try buf.text(self.alloc);
            defer self.alloc.free(text);
            _ = try h.beginParse(text, self.parsePrefixEnd(), self.parseBudget(first_parse_budget_ms));
            self.buf.full_redraw = true;
            return false;
        }

        // Replay the journal onto the retained tree. An edit that spans
        // more than one line changes the line count, which shifts every
        // row below it -- the partial-repaint path can't express that, so
        // reparse incrementally (still the win) but repaint in full.
        var line_count_stable = true;
        for (buf.pending_edits.items) |e| {
            h.applyEdit(e.toSyntax());
            // The cached lines follow the edit the same way the tree does.
            self.buf.spans.applyEdit(self.alloc, e.start_point.line, e.old_end_point.line, e.new_end_point.line) catch
                self.buf.spans.reset(self.alloc);
            if (e.start_point.line != e.old_end_point.line or
                e.start_point.line != e.new_end_point.line) line_count_stable = false;
        }

        // Read straight out of the gap buffer: no copy per keystroke. The
        // highlighter keeps reading it (predicates, injection parses)
        // until the next edit is replayed onto it, here.
        self.hl_changed.clearRetainingCapacity();
        const localized = h.reparseIncremental(buf.textSource(), &self.hl_changed) catch {
            self.buf.full_redraw = true;
            return false;
        };
        // Lines whose colours may have moved without their text changing
        // lose their cached spans, on screen or not -- a scroll down to
        // them later must not paint the old colours.
        for (self.hl_changed.items) |cr| {
            const lo = buf.lineAt(cr.start);
            const hi = buf.lineAt(if (cr.end > cr.start) cr.end - 1 else cr.start);
            self.buf.spans.invalidate(self.alloc, lo, hi);
        }
        if (!localized or !line_count_stable) {
            self.buf.full_redraw = true;
            return false;
        }

        // Union: every directly-edited line, plus every line overlapping
        // a range tree-sitter flagged as structurally changed.
        for (buf.pending_edits.items) |e| {
            try self.addDirtyLine(e.start_point.line);
        }
        for (self.hl_changed.items) |cr| {
            const lo = buf.lineAt(cr.start);
            const hi = buf.lineAt(if (cr.end > cr.start) cr.end - 1 else cr.start);
            if (hi -| lo > self.grp.buffer_bounds.rows) {
                self.buf.full_redraw = true;
                return false;
            }
            var line = lo;
            while (line <= hi) : (line += 1) try self.addDirtyLine(line);
            if (self.hl_dirty_lines.items.len > self.grp.buffer_bounds.rows) {
                self.buf.full_redraw = true;
                return false;
            }
        }
        return true;
    }

    /// Where a staged parse's provisional prefix ends: the end of the line
    /// one whole screen below the bottom of the pane, so a first scroll
    /// stays coloured and a construct the cut splits (an unterminated
    /// block comment) mis-colours rows nobody is looking at.
    fn parsePrefixEnd(self: *const Ui) usize {
        const buf = &self.buf.ed.buf;
        const last = self.buf.top_line + 2 * @as(usize, self.grp.buffer_bounds.rows);
        return buf.lineEnd(@min(last, buf.lineCount() -| 1));
    }

    fn parseBudget(self: *const Ui, ms: i64) syntax.ParseBudget {
        return .{ .time = .{ .io = self.io, .ms = ms } };
    }

    /// Any buffer, shown or not, with a staged parse still running.
    fn highlightPending(self: *const Ui) bool {
        for (self.group_list.items) |g| {
            for (g.buffers.items) |slot| {
                if (slot.hl) |*h| if (h.parsing()) return true;
            }
        }
        return false;
    }

    /// Gives every buffer's parked parse one more slice. One that
    /// finishes on a group's shown buffer repaints that pane: rows past
    /// the prefix were drawn plain, and rows near the cut may change
    /// colour. A background buffer that finishes just has its full tree
    /// ready for when it is next shown (`setActive` repaints then anyway).
    fn stepHighlight(self: *Ui) void {
        for (self.group_list.items) |g| {
            for (g.buffers.items) |slot| {
                const h = if (slot.hl) |*x| x else continue;
                if (!h.parsing()) continue;
                const progress = h.continueParse(self.parseBudget(parse_slice_ms)) catch .done;
                if (progress == .done and slot == g.slot()) {
                    slot.full_redraw = true;
                    g.buffer_dirty = true;
                }
            }
        }
    }

    /// Adds `line` to `hl_dirty_lines` if it isn't already there. The set
    /// stays small (bounded by the pane height), so a linear scan is fine.
    fn addDirtyLine(self: *Ui, line: usize) !void {
        for (self.hl_dirty_lines.items) |existing| {
            if (existing == line) return;
        }
        try self.hl_dirty_lines.append(self.alloc, line);
    }

    /// Repaints only the on-screen rows an incremental reparse marked
    /// dirty, plus the caret's old and new rows, leaving every other row
    /// as it was. `renderBuffer`'s caret pass runs afterwards.
    fn renderChangedRows(self: *Ui, batch: *glyphwire.client.Client.Batch, cursor_line: usize) !void {
        for (self.row_map.items, 0..) |rv, r| {
            if (self.dirtyLineListed(rv.line) or rv.line == self.buf.prev_cursor_line or rv.line == cursor_line)
                try self.renderBufferRow(batch, r);
        }
    }

    fn dirtyLineListed(self: *const Ui, line: usize) bool {
        for (self.hl_dirty_lines.items) |existing| {
            if (existing == line) return true;
        }
        return false;
    }

    /// Repaints buffer-pane screen rows `[from, to)` from the buffer's
    /// current contents -- plain text, or vim's `~` past the end, without
    /// the caret.
    fn renderBufferRows(self: *Ui, batch: *glyphwire.client.Client.Batch, from: usize, to: usize) !void {
        var r = from;
        while (r < to) : (r += 1) try self.renderBufferRow(batch, r);
    }

    /// Cells the line-number gutter takes in the buffer pane right now --
    /// zero unless `:set`/`zoe.conf.lua` turned it on. Widens by a column each
    /// time the line count crosses a power of ten; an edit that changes
    /// the count already forces a full pane repaint, so it is always safe
    /// to read fresh.
    fn gutterWidth(self: *const Ui) usize {
        return self.signWidth() + gutterWidthFor(self.buf.ed.line_numbers, self.buf.ed.buf.lineCount());
    }

    /// Cells reserved for the diagnostic sign column, left of the line
    /// numbers: one when a language server is attached, none otherwise.
    ///
    /// Fixed for the session (`signs`), not "one when there is something to
    /// show". A column that appeared with the first diagnostic would reflow
    /// every line of the pane sideways while the user was reading it, and
    /// vanish again when the file went clean.
    fn signWidth(self: *const Ui) usize {
        return if (self.signs) 1 else 0;
    }

    /// Buffer-text width: the pane less the gutter. Saturates to zero if
    /// the pane is narrower than the gutter (a degenerate split).
    fn textCols(self: *const Ui) usize {
        return self.grp.buffer_bounds.cols -| self.gutterWidth();
    }

    /// Paints just the line-number cell for buffer screen row `r`, in
    /// `fg_text` on the caret's line and `fg_dim` elsewhere. A no-op when
    /// the gutter is off. Every buffer-text path calls this for the rows
    /// it repaints; `renderBuffer` calls it for the rest when a scroll or
    /// a `.relative` caret move changed numbers it did not otherwise touch.
    fn renderGutterCell(self: *Ui, batch: *glyphwire.client.Client.Batch, r: usize) !void {
        const width = self.gutterWidth();
        if (width == 0) return;
        const rv = self.row_map.items[r];
        const line = rv.line;
        const cursor_line = self.buf.ed.pos().line;
        // A wrapped line's continuation rows get a blank gutter, the
        // same as the rows past the end: one number per line.
        const past_end = line >= self.buf.ed.buf.lineCount() or rv.sub > 0;

        // The sign first, in its own cell: the worst severity starting on
        // this line, or a blank. Painted even on a clean line, because this
        // is also what takes yesterday's mark off. Both glyphs are
        // East Asian "ambiguous" width, which the host draws one cell
        // wide, so the number's span starts right after it.
        const signs = self.signWidth();
        var sign: []const u8 = " ";
        var sign_fg = role(.fg_dim);
        if (signs > 0 and !past_end) {
            if (self.diagSeverityForLine(line)) |sev| {
                sign = if (sev == .err) sign_error else sign_other;
                sign_fg = self.diagColor(sev);
            }
        }

        var buf: [32]u8 = undefined;
        const cell = gutterCellText(
            &buf,
            self.buf.ed.line_numbers,
            width - signs,
            line,
            cursor_line,
            past_end,
        );
        const fg = if (!past_end and line == cursor_line) role(.fg) else role(.fg_dim);

        // Sign and number as one write: the gutter is repainted for every
        // row a frame draws, and a write's fixed fields cost more than the
        // handful of cells it carries.
        const spans = [_]glyphwire.client.Client.Span{
            .{ .text = sign, .fg = sign_fg },
            .{ .text = cell, .fg = fg },
        };
        const first: usize = if (signs > 0) 0 else 1;
        try batch.writeSpans(spans[first..], .{
            .layer = self.grp.buffer_layer,
            .row = r,
            .col = 0,
            .bg = role(.bg),
        });
    }

    /// The worst diagnostic severity starting on buffer `line` of the active
    /// buffer, or null. Runs once per visible row per frame, so it does no
    /// allocation -- the path resolution is the only cost, and it is skipped
    /// entirely when nothing has published anything.
    fn diagSeverityForLine(self: *Ui, line: usize) ?lsp.Severity {
        if (self.lsp_pool == null) return null;
        const abs = self.slotAbs(self.buf) orelse return null;
        return self.diags.worstOnLine(abs, @intCast(line));
    }

    fn renderBufferRow(self: *Ui, batch: *glyphwire.client.Client.Batch, r: usize) !void {
        const rv = self.row_map.items[r];
        const line = rv.line;
        const gutter = self.gutterWidth();
        const cols = self.textCols();

        try self.renderGutterCell(batch, r);

        if (line >= self.buf.ed.buf.lineCount()) {
            // vim's marker for "past the end of the buffer", the rest of
            // the row padded by the host.
            try batch.writeTextOpts("~", .{
                .layer = self.grp.buffer_layer,
                .row = r,
                .col = gutter,
                .fg = role(.fg_dim),
                .bg = role(.bg),
                .max_cols = cols,
                .pad = true,
            });
            return;
        }

        const text = try self.buf.ed.buf.lineText(self.alloc, line);
        defer self.alloc.free(text);

        // Highlighted rows are painted a colour run at a time; on any
        // failure (or with no grammar) the same painter runs with no
        // spans at all, which is exactly a plain row in `fg_text`.
        var painted = false;
        if (self.buf.hl) |*h| {
            if (h.ready() and self.renderRowSpans(batch, r, rv, text)) painted = true;
        }
        if (!painted) try self.rowSpansImpl(batch, r, rv, text, &.{});

        // Overpaint, in order: search matches, then the selection on top
        // of them. Both are second writes over the text just laid down
        // rather than threaded through every colour run, and the
        // selection wins because it is the thing you are about to act on.
        try self.paintMatchRow(batch, r, rv, text);
        try self.paintSelectionRow(batch, r, rv, text);
        // Diagnostics last, and through `set_underline` rather than a write:
        // the two overpaints above are full cell writes that would clear a
        // squiggle laid down before them, and the underline is a channel of
        // its own so it doesn't have to fight either of them for the cell.
        // Every path that repaints a row comes through here, so a mark is
        // re-applied whenever the row under it is redrawn.
        try self.paintDiagnosticRow(batch, r, rv, text);
    }

    /// Draws every diagnostic starting on the row's buffer line as a
    /// coloured underline over its range, clipped to the columns the row
    /// shows.
    ///
    /// A zero-width range -- which is how servers often report "the error is
    /// *here*" -- is widened to one cell, because a squiggle under nothing is
    /// nothing. Worst severity last, so where two diagnostics overlap the
    /// more serious colour is the one left on the cells.
    fn paintDiagnosticRow(
        self: *Ui,
        batch: *glyphwire.client.Client.Batch,
        r: usize,
        rv: RowView,
        text: []const u8,
    ) !void {
        if (self.lsp_pool == null) return;
        const abs = self.slotAbs(self.buf) orelse return;
        const line = rv.line;
        const cols = rv.cols;
        if (cols == 0) return;

        var row: std.ArrayList(diag.Entry) = .empty;
        defer row.deinit(self.alloc);
        self.diags.onLine(abs, @intCast(line), &row, self.alloc) catch return;
        if (row.items.len == 0) return;

        const opts = self.displayOpts();
        // `onLine` gives worst first; paint in reverse so the worst is the
        // one that ends up on any cell two of them share.
        var i = row.items.len;
        while (i > 0) {
            i -= 1;
            const e = row.items[i];
            const lo_b = @min(@as(usize, e.range.start.character), text.len);
            // A range that runs past this line's end (a multi-line
            // diagnostic) is clipped to it: the rows below have their own
            // marks, or deliberately none. See `diag.Store.onLine`.
            const hi_b = if (e.range.end.line > e.range.start.line)
                text.len
            else
                @min(@as(usize, e.range.end.character), text.len);

            const start_dc = display.colOfByte(text, lo_b, opts);
            var end_dc = display.colOfByte(text, @max(hi_b, lo_b), opts);
            if (end_dc <= start_dc) end_dc = start_dc + 1;
            if (end_dc <= rv.left or start_dc >= rv.left + cols) continue;

            const vis_lo = @max(start_dc, rv.left);
            const vis_hi = @min(end_dc, rv.left + cols);
            if (vis_hi <= vis_lo) continue;

            try batch.setUnderline(.{
                .layer = self.grp.buffer_layer,
                .row = r,
                .col = self.gutterWidth() + (vis_lo - rv.left),
                .rows = 1,
                .cols = vis_hi - vis_lo,
                .underline = .curly,
                .underline_color = self.diagColor(e.severity),
            });
        }
    }

    /// Where the hover popup goes: under the cursor when there is room
    /// below it, above it otherwise -- so it never covers the identifier it
    /// is describing. Clamped inside the buffer pane like `finderRect`.
    /// `want_rows` counts the frame's two rows.
    fn hoverRect(self: *const Ui, want_rows: usize) Bounds {
        const b = self.grp.buffer_bounds;
        const cols = @min(hover_max_cols, b.cols);
        const rows = @min(@min(want_rows, hover_max_rows + 2), b.rows);

        // The caret's screen row as last drawn -- not `line - top_line`
        // once lines wrap.
        const cursor_row = b.row + self.caret_at.row;
        // Below if it fits, else above; if neither fits (a two-row pane),
        // below and clipped by the clamp. Above leaves a row for the
        // shadow when there is one to spare, so it doesn't darken the very
        // line being described.
        const below = cursor_row + 1 + rows <= b.row + b.rows;
        const row = if (below)
            cursor_row + 1
        else if (cursor_row >= b.row + rows + hover_shadow_rows)
            cursor_row - rows - hover_shadow_rows
        else if (cursor_row >= b.row + rows)
            cursor_row - rows
        else
            b.row;

        // Left-aligned with the cursor's column, pulled back inside the
        // pane's right edge rather than hanging off it.
        const cursor_col = b.col + self.gutterWidth();
        const col = @min(cursor_col, b.col + (b.cols -| cols));
        return .{ .row = row, .col = col, .cols = cols, .rows = rows };
    }

    /// Draws the hover popup, or hides its layer when there is none.
    ///
    /// The reply arrives as markdown and is drawn as three kinds of row (see
    /// `zoe/hover.zig`): fenced code in its grammar's colours on a darker
    /// band, prose with the markdown punctuation taken off, and a `---` rule
    /// as a line across. Headings, lists and emphasis are not styled -- that
    /// is the `md/` renderer's job, and a bigger one than it looks, since it
    /// draws into a layer of its own.
    ///
    /// The panel is the `hover_panel_style` nine-patch over the whole layer:
    /// its rounded border sits in the outer ring of cells, which nothing
    /// writes to, and prose rows are transparent so its fill shows. The
    /// layer's host-drawn shadow (set once in `init`) stands it off an
    /// editor background of nearly its own colour. A `---` rule runs the
    /// full width, so it meets the border on both sides.
    fn renderHover(self: *Ui, batch: *glyphwire.client.Client.Batch) !void {
        const h = if (self.hover) |*open| open else return self.hideHover(batch);

        // Wrapped to the popup's width first, so the height is the height of
        // what will actually be drawn rather than of the source text. Four
        // columns go to the frame and a one-cell margin inside it each side.
        const wrap_cols = @min(hover_max_cols, self.grp.buffer_bounds.cols) -| 4;
        if (wrap_cols == 0) return self.hideHover(batch);
        var rows: std.ArrayList(HoverRow) = .empty;
        defer rows.deinit(self.alloc);
        try wrapHover(self.alloc, &h.doc, wrap_cols, &rows);

        const r = self.hoverRect(rows.items.len + 2);
        self.hover_rect = r;
        if (r.cols < 4 or r.rows < 3) return self.hideHover(batch);
        if (h.scroll >= rows.items.len) h.scroll = rows.items.len -| 1;

        try batch.setLayerSize(self.hover_layer, r.cols, r.rows);
        try batch.setLayerCellPosition(self.hover_layer, r.row, r.col);
        if (self.hover_panel_patch) |np| try batch.updateNinePatch(self.hover_layer, np, .{ .rows = r.rows, .cols = r.cols });
        // A resize keeps whatever the old cells held, so the frame ring
        // (which is otherwise never written) is blanked every time.
        try batch.clearArea(.{ .layer = self.hover_layer });

        // A rule's run: `cols` wide, so it crosses the frame cells and
        // meets the nine-patch's border at both edges.
        var hline: std.ArrayList(u8) = .empty;
        defer hline.deinit(self.alloc);
        for (0..r.cols) |_| try hline.appendSlice(self.alloc, "\u{2500}");

        var runs: std.ArrayList(glyphwire.client.Client.Span) = .empty;
        defer runs.deinit(self.alloc);
        const inner_rows = r.rows - 2;
        for (0..inner_rows) |i| {
            const row = i + 1;
            const idx = h.scroll + i;
            const hr: ?HoverRow = if (idx < rows.items.len) rows.items[idx] else null;
            const kind: hover_mod.Kind = if (hr) |x| h.doc.lines[x.line].kind else .prose;

            if (kind == .rule) {
                try batch.writeTextOpts(hline.items, .{
                    .layer = self.hover_layer,
                    .row = row,
                    .col = 0,
                    .fg = role(.popup_border),
                    .max_cols = r.cols,
                    .selectable = false,
                });
                continue;
            }

            // Prose is transparent, so the panel is its background.
            const bg: ?Color = if (kind == .code) role(.popup_code_bg) else null;
            runs.clearRetainingCapacity();
            // The inner margin, in the row's own background so a code band
            // runs from frame to frame.
            try runs.append(self.alloc, .{ .text = " " });
            if (hr) |x| {
                const line = h.doc.lines[x.line];
                if (x.indent > 0) try runs.append(self.alloc, .{ .text = spaces[0..@min(x.indent, spaces.len)] });
                try colorRuns(self.alloc, line.text, h.spans[x.line], x.start, x.end, role(.popup_fg), &runs);
            }
            // One padded write inside the frame: `pad` fills the rest,
            // right margin included, so a code band runs edge to edge
            // whatever the text length.
            try batch.writeSpans(runs.items, .{
                .layer = self.hover_layer,
                .row = row,
                .col = 1,
                .fg = role(.popup_fg),
                .bg = bg,
                .max_cols = r.cols - 2,
                .pad = true,
            });
        }
        try batch.setLayerVisible(self.hover_layer, true);
    }

    fn hideHover(self: *Ui, batch: *glyphwire.client.Client.Batch) !void {
        try batch.setLayerVisible(self.hover_layer, false);
    }

    /// Draws the tab tooltip, or hides its layer: the hovered buffer's
    /// absolute path with `$HOME` as `~`, on the hover popup's panel,
    /// hanging from the tab (`tabs.tipRect`). A path wider than the window
    /// loses its head rather than its file name (`tabs.clipHead`).
    fn renderTabTip(self: *Ui, batch: *glyphwire.client.Client.Batch) !void {
        const hide = !self.tab_tip_shown or self.tab_tip_index == null;
        const index = self.tab_tip_index orelse 0;
        const g = self.tab_tip_group orelse return batch.setLayerVisible(self.tab_tip_layer, false);
        // The buffer list or the strip may have changed under a tooltip
        // that is still up.
        if (hide or index >= g.buffers.items.len or index >= g.tab_spans.items.len)
            return batch.setLayerVisible(self.tab_tip_layer, false);
        const slot = g.buffers.items[index];
        const abs = self.slotAbs(slot) orelse return batch.setLayerVisible(self.tab_tip_layer, false);

        var home_buf: [std.fs.max_path_bytes]u8 = undefined;
        const path = homepath.collapseHome(abs, self.environ.get("HOME"), &home_buf);

        // The window's full width: the statusline spans it.
        const area: tabs.TipArea = .{
            .strip_row = g.tabs_bounds.row,
            .strip_col = g.tabs_bounds.col,
            .scroll = g.tab_scroll,
            .area_col = self.status_bounds.col,
            .area_cols = self.status_bounds.cols,
        };
        const r = tabs.tipRect(g.tab_spans.items[index], glyphwire.stringWidth(path), area) orelse
            return batch.setLayerVisible(self.tab_tip_layer, false);
        const clipped = tabs.clipHead(path, r.cols - tabs.tip_chrome_cols);

        try batch.setLayerSize(self.tab_tip_layer, r.cols, tabs.tip_rows);
        try batch.setLayerCellPosition(self.tab_tip_layer, r.row, r.col);
        if (self.tab_tip_patch) |np| try batch.updateNinePatch(self.tab_tip_layer, np, .{ .rows = tabs.tip_rows, .cols = r.cols });
        // A resize keeps whatever the old cells held, so the corner cells
        // (which are otherwise never written) are blanked every time.
        try batch.clearArea(.{ .layer = self.tab_tip_layer });
        // Transparent, so the panel is the text's background. Between the
        // two corner cells, and padded so a shorter path than last time
        // leaves nothing behind.
        const spans = [_]glyphwire.client.Client.Span{
            .{ .text = if (clipped.ellipsis) tabs.tip_ellipsis else "" },
            .{ .text = clipped.tail },
        };
        try batch.writeSpans(&spans, .{
            .layer = self.tab_tip_layer,
            .row = 0,
            .col = 1,
            .fg = role(.popup_fg),
            .max_cols = r.cols - tabs.tip_chrome_cols,
            .pad = true,
        });
        try batch.setLayerVisible(self.tab_tip_layer, true);
    }

    /// Draws the completion popup, or hides it. Each row is the item's kind,
    /// its label, and its detail (a type or signature) dimmed after it; the
    /// label column lines up with the word being typed, so the text you are
    /// finishing sits directly above the text that would finish it.
    fn renderCompletion(self: *Ui, batch: *glyphwire.client.Client.Batch) !void {
        const m = if (self.completion) |*x| x else {
            try batch.setLayerVisible(self.completion_layer, false);
            return;
        };
        const b = self.grp.buffer_bounds;
        const rows = @min(@min(m.count(), complete_max_rows), b.rows);
        if (rows == 0 or b.cols < complete_kind_cols + 8) {
            try batch.setLayerVisible(self.completion_layer, false);
            return;
        }
        m.follow(rows);

        // As wide as the widest visible row wants, within the limits.
        var want: usize = 20;
        for (0..rows) |r| {
            const it = m.visible(r) orelse break;
            var w = 1 + complete_kind_cols + display.width(it.label, .{}) + 1;
            if (it.detail) |d| w += 2 + display.width(d, .{});
            want = @max(want, w);
        }
        const cols = @min(@min(want, complete_max_cols), b.cols);

        // Under the cursor's row if it fits, else above it.
        const cursor_row = b.row + self.caret_at.row;
        const row = if (cursor_row + 1 + rows <= b.row + b.rows)
            cursor_row + 1
        else if (cursor_row >= b.row + rows)
            cursor_row - rows
        else
            b.row;

        // The label column under the word's first character.
        const line_start = self.buf.ed.buf.lineStart(m.line);
        const before = try self.buf.ed.buf.read(self.alloc, line_start, @max(line_start, m.word_start));
        defer self.alloc.free(before);
        // Relative to the caret row's first column: the horizontal scroll
        // unwrapped, the row's start in the line wrapped.
        const word_col = display.width(before, self.displayOpts()) -| self.caret_at.left;
        const label_col = b.col + self.gutterWidth() + word_col;
        const want_col = label_col -| (1 + complete_kind_cols);
        const col = @max(b.col, @min(want_col, b.col + (b.cols -| cols)));

        try batch.setLayerSize(self.completion_layer, cols, rows);
        try batch.setLayerCellPosition(self.completion_layer, row, col);

        var kind_buf: [complete_kind_cols]u8 = undefined;
        for (0..rows) |r| {
            const it = m.visible(r) orelse break;
            const selected = m.top + r == m.selected;
            const bg = if (selected) role(.popup_selected_bg) else role(.popup_bg);

            const kind = complete.kindLabel(it.kind);
            const kn = @min(kind.len, complete_kind_cols);
            @memcpy(kind_buf[0..kn], kind[0..kn]);
            @memset(kind_buf[kn..], ' ');

            var runs: [5]glyphwire.client.Client.Span = undefined;
            var n: usize = 0;
            runs[n] = .{ .text = " " };
            n += 1;
            runs[n] = .{ .text = &kind_buf, .fg = role(.popup_kind) };
            n += 1;
            runs[n] = .{ .text = it.label, .fg = role(.popup_label) };
            n += 1;
            if (it.detail) |d| {
                runs[n] = .{ .text = "  " };
                n += 1;
                runs[n] = .{ .text = d, .fg = role(.popup_detail) };
                n += 1;
            }
            try batch.writeSpans(runs[0..n], .{
                .layer = self.completion_layer,
                .row = r,
                .col = 0,
                .fg = role(.popup_label),
                .bg = bg,
                .max_cols = cols,
                .pad = true,
                .selectable = false,
            });
        }
        try batch.setLayerVisible(self.completion_layer, true);
    }

    /// Closes the popup. Returns whether there was one, so a key can be
    /// swallowed by the closing (Escape) or fall through (anything else).
    fn closeHover(self: *Ui) bool {
        if (self.hover) |*h| {
            h.deinit();
            self.hover = null;
            self.hover_dirty = true;
            return true;
        }
        return false;
    }

    /// Paints every search match on buffer `line` -- `bg_match`, or
    /// `bg_match_current` for the one the cursor is on. A no-op when
    /// there is no pattern to highlight (`:noh`, or no search yet).
    ///
    /// Matches are found per row, at draw time, rather than collected
    /// once into a list: a row is a few dozen bytes, the scan is a
    /// `memchr`-shaped loop over it, and a stored list would have to be
    /// invalidated by every edit.
    fn paintMatchRow(
        self: *Ui,
        batch: *glyphwire.client.Client.Batch,
        r: usize,
        rv: RowView,
        text: []const u8,
    ) !void {
        const pat = self.buf.ed.highlightPattern() orelse return;
        const line = rv.line;
        const opts = self.buf.ed.highlightOpts();
        const ls = self.buf.ed.buf.lineStart(line);
        const line_end = self.buf.ed.buf.lineEnd(line);

        var at = ls;
        while (search.firstIn(&self.buf.ed.buf, pat, opts, at, line_end)) |hit| {
            at = hit + 1;
            // A match running off the end of its line is clipped to it:
            // the rest belongs to the row below, which paints its own.
            const hi = @min(hit + pat.len, line_end);
            const current = self.buf.ed.search_match == hit;
            try self.paintRowSpan(
                batch,
                r,
                rv,
                text,
                hit - ls,
                hi - ls,
                if (current) role(.match_current_bg) else role(.match_bg),
            );
        }
    }

    /// Repaints the byte range `[lo_b, hi_b)` of a row's `text` in `bg`,
    /// keeping the characters themselves. Clipped to the columns the row
    /// shows; a no-op when none of it is on screen. Shared by the
    /// selection and the search highlight, which differ only in colour
    /// and in how they pick the range.
    fn paintRowSpan(
        self: *Ui,
        batch: *glyphwire.client.Client.Batch,
        r: usize,
        rv: RowView,
        text: []const u8,
        lo_b: usize,
        hi_b: usize,
        bg: Color,
    ) !void {
        const cols = rv.cols;
        if (cols == 0 or hi_b <= lo_b) return;

        const opts = self.displayOpts();
        const start_dc = display.colOfByte(text, @min(lo_b, text.len), opts);
        const end_dc = display.colOfByte(text, @min(hi_b, text.len), opts);
        if (end_dc <= rv.left or start_dc >= rv.left + cols) return;

        const vis_lo = @max(start_dc, rv.left);
        const vis_hi = @min(end_dc, rv.left + cols);
        if (vis_hi <= vis_lo) return;

        var overlay: std.ArrayList(u8) = .empty;
        defer overlay.deinit(self.alloc);
        try display.appendCols(self.alloc, &overlay, text, vis_lo, vis_hi - vis_lo, opts);

        try writeAt(
            batch,
            self.grp.buffer_layer,
            r,
            self.gutterWidth() + vis_lo - rv.left,
            overlay.items,
            role(.fg),
            bg,
        );
    }

    /// If the row's buffer line overlaps the visual selection, repaints
    /// its selected columns with `bg_selected` (keeping the default text
    /// colour). A charwise selection highlights the covered characters; a
    /// linewise one runs to the pane's right edge, like vim -- and so
    /// does one that carries on into the next row of a wrapped line,
    /// across the blank a word break left. A no-op when nothing is
    /// selected or the selected part is scrolled out of view.
    fn paintSelectionRow(
        self: *Ui,
        batch: *glyphwire.client.Client.Batch,
        r: usize,
        rv: RowView,
        text: []const u8,
    ) !void {
        const span = self.buf.ed.selectionSpan() orelse return;
        const line = rv.line;
        const ls = self.buf.ed.buf.lineStart(line);
        // One past the line's last byte, including its newline if it has
        // one -- the range a linewise / cross-line selection can cover.
        const line_hi = if (line + 1 < self.buf.ed.buf.lineCount())
            self.buf.ed.buf.lineStart(line + 1)
        else
            self.buf.ed.buf.len();
        if (span.hi <= ls or span.lo > line_hi) return;

        const gutter = self.gutterWidth();
        const cols = self.textCols();
        if (cols == 0) return;

        // Selected byte range within this line's text.
        const sel_lo_b = span.lo -| ls;
        const sel_hi_b = span.hi - ls; // may exceed text.len (newline / EOL)
        const to_eol = span.linewise or sel_hi_b > text.len;

        const opts = self.displayOpts();
        // The row's own columns end at `row_end`; past it is the blank
        // tail of the pane, which the highlight only fills when it runs
        // on beyond the row (to the newline, or into the next row).
        const row_end = rv.left + rv.cols;
        const start_dc = display.colOfByte(text, @min(sel_lo_b, text.len), opts);
        var end_dc = if (to_eol)
            rv.left + cols
        else
            display.colOfByte(text, @min(sel_hi_b, text.len), opts);
        if (end_dc > row_end and !rv.last) end_dc = rv.left + cols;
        // A selection starting on a later row of this line.
        if (start_dc >= row_end and !(rv.last and to_eol)) return;
        if (end_dc <= rv.left) return;

        const vis_lo = @max(start_dc, rv.left);
        const vis_hi = @min(end_dc, rv.left + cols);
        if (vis_hi <= vis_lo) return;

        // The characters under the highlight, then spaces out to the
        // selection's end (a linewise selection past the text, the
        // newline slot of a charwise one, or a wrapped row's tail) --
        // never the next row's characters.
        var overlay: std.ArrayList(u8) = .empty;
        defer overlay.deinit(self.alloc);
        const chars_hi = @max(@min(vis_hi, row_end), vis_lo);
        try display.appendCols(self.alloc, &overlay, text, vis_lo, chars_hi - vis_lo, opts);
        try overlay.appendNTimes(self.alloc, ' ', vis_hi - chars_hi);

        try writeAt(batch, self.grp.buffer_layer, r, gutter + vis_lo - rv.left, overlay.items, role(.fg), role(.selection_bg));
    }

    /// Paints buffer row `r` (showing `rv` of its line, whole text `text`)
    /// as tree-sitter colour runs clipped to the row's columns.
    /// Returns false if the highlighter couldn't produce spans, so the
    /// caller can fall back to a plain write.
    fn renderRowSpans(
        self: *Ui,
        batch: *glyphwire.client.Client.Batch,
        r: usize,
        rv: RowView,
        text: []const u8,
    ) bool {
        const line = rv.line;
        const spans = self.buf.spans.get(line) orelse blk: {
            // `fillSpanCache` covers every visible line, so this is only
            // a row it couldn't fill (an allocation failure): query it on
            // its own rather than paint it plain.
            const h = &self.buf.hl.?;
            const t_spans = self.prof.now();
            h.lineSpans(self.buf.ed.buf.lineStart(line), self.buf.ed.buf.lineEnd(line), &self.hl_scratch) catch return false;
            self.prof.add(.spans, t_spans);
            self.prof.span_lines += 1;
            break :blk self.hl_scratch.items;
        };
        self.rowSpansImpl(batch, r, rv, text, spans) catch return false;
        return true;
    }

    /// How many already-cached lines `fillSpanCache` will re-query to keep
    /// two missing lines in one run. Re-querying a few lines costs less
    /// than a second query's descent from the root.
    const span_run_gap: usize = 8;

    /// Computes the spans of every visible line the cache is missing, one
    /// `linesSpans` query per run of nearby missing lines, so the rows
    /// this frame paints all read from the cache. A scroll by a line
    /// misses one line; a scroll back over rows seen before, a caret move
    /// or a selection repaint misses none.
    fn fillSpanCache(self: *Ui) void {
        const h = if (self.buf.hl) |*x| x else return;
        if (!h.ready()) return;
        const buf = &self.buf.ed.buf;
        self.buf.spans.sync(self.alloc, h.generation, buf.lineCount()) catch return;

        // One past the last line on screen -- fewer than the pane's rows
        // when lines wrap.
        const map = self.row_map.items;
        const last_shown = if (map.len > 0) map[map.len - 1].line else self.buf.top_line;
        const end = @min(last_shown + 1, buf.lineCount());
        var line = self.buf.top_line;
        while (line < end) {
            if (self.buf.spans.get(line) != null) {
                line += 1;
                continue;
            }
            var last_missing = line;
            var next = line + 1;
            while (next < end and next - last_missing <= span_run_gap) : (next += 1) {
                if (self.buf.spans.get(next) == null) last_missing = next;
            }
            self.fillSpanRun(h, line, last_missing + 1) catch return;
            line = last_missing + 1;
        }
    }

    /// Queries buffer lines `[lo, hi)` in one `linesSpans` call and caches
    /// each line's spans.
    fn fillSpanRun(self: *Ui, h: *syntax.Highlighter, lo: usize, hi: usize) !void {
        const t_spans = self.prof.now();
        defer self.prof.add(.spans, t_spans);
        const buf = &self.buf.ed.buf;
        self.hl_lines.clearRetainingCapacity();
        for (lo..hi) |l| try self.hl_lines.append(self.alloc, .{ .start = buf.lineStart(l), .end = buf.lineEnd(l) });
        try h.linesSpans(self.hl_lines.items, &self.hl_scratch, &self.hl_bounds);
        const bounds = self.hl_bounds.items;
        for (lo..hi, 0..) |l, i| try self.buf.spans.put(self.alloc, l, self.hl_scratch.items[bounds[i]..bounds[i + 1]]);
        self.prof.span_lines += @intCast(hi - lo);
    }

    /// Paints one buffer row as colour runs, walking the line's *display*
    /// cells (`zoe/display.zig`) rather than its bytes: a tab covers the
    /// columns out to its stop, and with `:set whitespace=on` a space is
    /// a dot and a tab an arrow, both in the whitespace colour but a run
    /// of their own. `spans` empty is a legitimate call
    /// -- it paints the whole row in `fg_text`, which is the no-grammar
    /// path.
    fn rowSpansImpl(
        self: *Ui,
        batch: *glyphwire.client.Client.Batch,
        r: usize,
        rv: RowView,
        text: []const u8,
        spans: []const syntax.Span,
    ) !void {
        if (self.textCols() == 0) return;
        // The row's own columns; the host pads the rest of the pane.
        const cols = rv.cols;
        const left = rv.left;
        // Text starts after the line-number gutter (zero when it is off).
        const gutter = self.gutterWidth();

        // The row's visible text, and where each colour starts in it. A
        // contiguous stretch of cells goes out as one `write_text` with a
        // span per colour, padded by the host to the pane's edge; only a
        // gap in the display cells (which `display.Cells` doesn't produce
        // in practice) splits it into two writes.
        var row_buf: std.ArrayList(u8) = .empty;
        defer row_buf.deinit(self.alloc);
        var ranges: std.ArrayList(RowRange) = .empty;
        defer ranges.deinit(self.alloc);
        var group_dc = left;
        var run_color: ?Color = null;
        var have_run = false;
        // The next column still to be filled, and so also where the run
        // being built ends -- which is how a gap is spotted.
        var dc = left;

        var it = display.Cells{ .text = text, .opts = self.displayOpts() };
        while (it.next()) |cell| {
            // `@max(width, 1)` keeps a zero-width combining mark sitting
            // exactly on the left edge rather than dropping it.
            if (cell.col + @max(cell.width, 1) <= left) continue;
            if (cell.col >= left + cols) break;

            const lo = @max(cell.col, left);
            const hi = @min(cell.col + cell.width, left + cols);
            // A character straddling either edge of the viewport is
            // painted blank rather than half-drawn -- including a tab the
            // horizontal scroll opened in the middle of, whose arrow is
            // off to the left.
            const clipped = cell.col < left or cell.col + cell.width > left + cols;
            // Nothing visible of its own: a clipped glyph, or a tab with
            // markers off. Colour is irrelevant to a run of blanks, and
            // saying so keeps it from splitting a run in two.
            const blanks = clipped or cell.glyph_cols == 0;

            const color: ?Color = if (blanks)
                null
            else if (cell.marker)
                role(.whitespace)
            else
                spanColorAt(spans, cell.src);

            if (!have_run or lo != dc) {
                if (have_run) try self.flushRowGroup(batch, r, left, group_dc, row_buf.items, ranges.items, false);
                row_buf.clearRetainingCapacity();
                ranges.clearRetainingCapacity();
                try ranges.append(self.alloc, .{ .start = 0, .color = color });
                run_color = color;
                group_dc = lo;
                have_run = true;
                dc = lo;
            } else if (!colorOptEql(color, run_color)) {
                try ranges.append(self.alloc, .{ .start = row_buf.items.len, .color = color });
                run_color = color;
            }

            if (blanks) {
                if (hi > dc) try row_buf.appendNTimes(self.alloc, ' ', hi - dc);
                dc = hi;
            } else {
                try row_buf.appendSlice(self.alloc, cell.bytes);
                // The columns past the glyph -- a tab's run after its
                // arrow. Unwritten cells would be transparent, not blank.
                try row_buf.appendNTimes(self.alloc, ' ', cell.width - cell.glyph_cols);
                dc += cell.width;
            }
        }

        if (have_run) {
            // The last stretch carries the pad for the rest of the row.
            try self.flushRowGroup(batch, r, left, group_dc, row_buf.items, ranges.items, true);
        } else {
            // An empty line, or one scrolled entirely off to the left.
            try self.writeSpaces(batch, r, gutter, self.textCols());
        }
    }

    /// Where one colour starts within a row's text; it runs to the next
    /// range's start.
    const RowRange = struct { start: usize, color: ?Color };

    /// Writes one contiguous stretch of a buffer row whose first column is
    /// display column `left`, starting at display column `start_dc`, as a
    /// single `write_text` with one span per colour range. `pad_row` has
    /// the host fill the rest of the pane's row in the buffer colour.
    fn flushRowGroup(
        self: *Ui,
        batch: *glyphwire.client.Client.Batch,
        r: usize,
        left: usize,
        start_dc: usize,
        bytes: []const u8,
        ranges: []const RowRange,
        pad_row: bool,
    ) !void {
        if (start_dc < left) return;
        const row_spans = try self.alloc.alloc(glyphwire.client.Client.Span, ranges.len);
        defer self.alloc.free(row_spans);
        for (ranges, row_spans, 0..) |rg, *sp, i| {
            const stop = if (i + 1 < ranges.len) ranges[i + 1].start else bytes.len;
            sp.* = .{ .text = bytes[rg.start..stop], .fg = rg.color orelse role(.fg) };
        }
        try batch.writeSpans(row_spans, .{
            .layer = self.grp.buffer_layer,
            .row = r,
            .col = self.gutterWidth() + start_dc - left,
            .bg = role(.bg),
            .max_cols = if (pad_row) left + self.textCols() - start_dc else null,
            .pad = pad_row,
        });
    }

    /// Blanks `n` cells of buffer row `r` to the pane colour -- a fill,
    /// not a run of spaces.
    fn writeSpaces(self: *Ui, batch: *glyphwire.client.Client.Batch, r: usize, col: usize, n: usize) !void {
        if (n == 0) return;
        try batch.clearArea(.{ .layer = self.grp.buffer_layer, .row = r, .col = col, .rows = 1, .cols = n, .bg = role(.bg) });
    }

    /// The active buffer's lines as `layoutRowMap` reads them.
    const BufLines = struct {
        buf: *const buffer_mod.Buffer,
        pub fn count(self: BufLines) usize {
            return self.buf.lineCount();
        }
        pub fn text(self: BufLines, alloc: std.mem.Allocator, line: usize) ![]u8 {
            return self.buf.lineText(alloc, line);
        }
    };

    /// Rebuilds `row_map` for `grp`/`buf` as they stand -- their scroll
    /// position, pane size and `wrap` setting.
    fn layoutRows(self: *Ui) !void {
        try layoutRowMap(
            self.alloc,
            &self.row_map,
            BufLines{ .buf = &self.buf.ed.buf },
            self.buf.top_line,
            self.buf.top_sub,
            self.buf.left_col,
            self.grp.buffer_bounds.rows,
            self.textCols(),
            self.buf.ed.wrap,
            self.displayOpts(),
        );
    }

    /// A screen row of a wrapped buffer: row `sub` of buffer `line`.
    const RowPos = struct { line: usize, sub: usize };

    /// Screen rows buffer `line` wraps into at the pane's text width. A
    /// line past the end (or one that can't be read) counts as one.
    fn lineRows(self: *Ui, line: usize) usize {
        if (line >= self.buf.ed.buf.lineCount()) return 1;
        const text = self.buf.ed.buf.lineText(self.alloc, line) catch return 1;
        defer self.alloc.free(text);
        return softwrap.rowCount(text, self.displayOpts(), self.textCols());
    }

    /// The wrapped screen row the caret sits on.
    fn cursorRowPos(self: *Ui) RowPos {
        const line = self.buf.ed.pos().line;
        const text = self.buf.ed.buf.lineText(self.alloc, line) catch return .{ .line = line, .sub = 0 };
        defer self.alloc.free(text);
        const col = self.cursorDisplayCol() catch return .{ .line = line, .sub = 0 };
        return .{ .line = line, .sub = softwrap.rowOfCol(text, self.displayOpts(), self.textCols(), col).index };
    }

    /// Screen rows from `from` down to `to` (`from` at or above it),
    /// counting stopped at `cap` -- callers only care whether it fits.
    fn rowsBetween(self: *Ui, from: RowPos, to: RowPos, cap: usize) usize {
        if (from.line == to.line) return @min(to.sub -| from.sub, cap);
        var n = self.lineRows(from.line) -| from.sub;
        var line = from.line + 1;
        while (line < to.line and n < cap) : (line += 1) n += self.lineRows(line);
        return @min(n + to.sub, cap);
    }

    /// The screen row `n` rows above `at`, stopping at the buffer's top.
    fn rowsBack(self: *Ui, at: RowPos, n: usize) RowPos {
        var pos = at;
        var left = n;
        while (left > 0) {
            if (pos.sub >= left) {
                pos.sub -= left;
                break;
            }
            left -= pos.sub + 1;
            if (pos.line == 0) return .{ .line = 0, .sub = 0 };
            pos.line -= 1;
            pos.sub = self.lineRows(pos.line) - 1;
        }
        return pos;
    }

    fn rowPosBefore(a: RowPos, b: RowPos) bool {
        return a.line < b.line or (a.line == b.line and a.sub < b.sub);
    }

    /// Keeps the caret inside the buffer pane, both axes.
    fn scrollBufferToCursor(self: *Ui) void {
        const b = self.grp.buffer_bounds;
        if (b.rows == 0 or b.cols == 0) return;
        if (self.buf.ed.wrap) return self.scrollWrappedToCursor();
        self.buf.top_sub = 0;
        const pos = self.buf.ed.pos();

        if (pos.line < self.buf.top_line) self.buf.top_line = pos.line;
        if (pos.line >= self.buf.top_line + b.rows) self.buf.top_line = pos.line - b.rows + 1;

        const col = self.cursorDisplayCol() catch return;
        const cols = self.textCols();
        if (col < self.buf.left_col) self.buf.left_col = col;
        if (cols > 0 and col >= self.buf.left_col + cols) self.buf.left_col = col - cols + 1;
    }

    /// `scrollBufferToCursor` with `wrap` on: there is nothing to scroll
    /// sideways, and the view moves in screen rows, so a long line can sit
    /// part-way off the top of the pane.
    fn scrollWrappedToCursor(self: *Ui) void {
        const rows = self.grp.buffer_bounds.rows;
        self.buf.left_col = 0;
        // An edit or a narrower pane can leave the top row past its
        // line's last one.
        if (self.buf.top_line >= self.buf.ed.buf.lineCount()) {
            self.buf.top_line = self.buf.ed.buf.lineCount() - 1;
            self.buf.top_sub = 0;
        }
        self.buf.top_sub = @min(self.buf.top_sub, self.lineRows(self.buf.top_line) - 1);

        const at = self.cursorRowPos();
        const top: RowPos = .{ .line = self.buf.top_line, .sub = self.buf.top_sub };
        var new_top = top;
        if (rowPosBefore(at, top)) {
            new_top = at;
        } else if (self.rowsBetween(top, at, rows) >= rows) {
            new_top = self.rowsBack(at, rows - 1);
        }
        self.buf.top_line = new_top.line;
        self.buf.top_sub = new_top.sub;
    }

    /// Signed screen rows the wrapped view moved since the layer was last
    /// drawn (positive: scrolled down), or null for a screen or more --
    /// too far for a `move_content` to be worth it. Measured over the
    /// current text, which is only right when nothing was edited since;
    /// an edit takes the full-repaint path before this is asked.
    fn wrappedScrollDelta(self: *Ui, rows: usize) ?i64 {
        const prev: RowPos = .{ .line = self.buf.prev_top_line, .sub = self.buf.prev_top_sub };
        const now: RowPos = .{ .line = self.buf.top_line, .sub = self.buf.top_sub };
        if (prev.line >= self.buf.ed.buf.lineCount()) return null;
        const down = rowPosBefore(prev, now);
        const n = if (down) self.rowsBetween(prev, now, rows) else self.rowsBetween(now, prev, rows);
        if (n >= rows) return null;
        return if (down) @intCast(n) else -@as(i64, @intCast(n));
    }

    /// Applies a host-driven scroll of group `g`'s buffer pane (wheel or
    /// thumb drag): moves the view and drags the cursor back onto it,
    /// keeping its column. Records the new position as already pushed so
    /// the next `syncBufferScrollbar` doesn't bounce it back to the host.
    /// Any group, not only the focused one -- the wheel follows the
    /// pointer, not the keyboard.
    fn scrollGroupTo(self: *Ui, g: *Group, row: usize, col: usize) void {
        const b = g.buffer_bounds;
        if (b.rows == 0) return;
        const slot = g.slot();
        slot.top_line = row;
        // The host scrolls in buffer lines (the bar's extent is the line
        // count), so a wrapped view lands on a line's first row.
        slot.top_sub = 0;
        slot.left_col = if (slot.ed.wrap) 0 else col;

        const cur = slot.ed.pos();
        const last = slot.ed.buf.lineCount() -| 1;
        const clamped_line = std.math.clamp(cur.line, row, @min(self.lastWholeLine(g), last));
        if (clamped_line != cur.line) {
            slot.ed.cursor = slot.ed.buf.offsetOf(.{ .line = clamped_line, .col = cur.col });
        }
        slot.pushed_bar = .{ slot.ed.buf.lineCount(), b.cols, slot.top_line, slot.left_col };
        // The view moved and the cursor may have been dragged with it;
        // the status row shows both.
        g.buffer_dirty = true;
        self.status_dirty = true;
    }

    /// The last buffer line group `g`'s pane shows in full from its
    /// current scroll position -- `top_line + rows - 1` unwrapped. Wrapped,
    /// a line whose rows run off the bottom doesn't count, or a cursor
    /// clamped onto it would scroll the view straight back. Never above
    /// `top_line`, even when that one line is taller than the pane.
    fn lastWholeLine(self: *Ui, g: *Group) usize {
        const slot = g.slot();
        if (!slot.ed.wrap) return slot.top_line + g.buffer_bounds.rows -| 1;
        const focused_grp = self.grp;
        const focused_buf = self.buf;
        self.grp = g;
        self.buf = slot;
        defer {
            self.grp = focused_grp;
            self.buf = focused_buf;
        }
        self.layoutRows() catch return slot.top_line;
        var last = slot.top_line;
        for (self.row_map.items) |rv| {
            if (rv.last and rv.line > last) last = rv.line;
        }
        return last;
    }

    /// Keeps the buffer layer's host-drawn scrollbar in step with zoe's
    /// own scroll state: the content extent is the line count (the width
    /// is just the pane's, so no horizontal bar), and the offset is
    /// `top_line`/`left_col`. Only sent when something changed, so a
    /// still buffer is silent. A wheel or thumb drag over the pane comes
    /// back the other way as a `scroll_offset` notification (see
    /// `handleEvent`). Batched with the frame, so the bar never moves
    /// ahead of the rows it describes.
    fn syncBufferScrollbar(self: *Ui, batch: *glyphwire.client.Client.Batch) !void {
        const b = self.grp.buffer_bounds;
        const now: [4]usize = .{ self.buf.ed.buf.lineCount(), b.cols, self.buf.top_line, self.buf.left_col };
        if (std.mem.eql(usize, &now, &self.buf.pushed_bar)) return;

        if (now[0] != self.buf.pushed_bar[0] or now[1] != self.buf.pushed_bar[1]) {
            try batch.setLayerContentExtent(self.grp.buffer_layer, now[1], now[0]);
        }
        try batch.setLayerScrollOffset(self.grp.buffer_layer, self.buf.top_line, self.buf.left_col);
        self.buf.pushed_bar = now;
    }

    /// How the buffer pane lays a line out, from the active buffer's own
    /// settings. One accessor so every column calculation in this file --
    /// painting, the caret, the selection, a mouse click -- agrees.
    fn displayOpts(self: *const Ui) display.Opts {
        return .{
            .tab_width = self.buf.ed.tab_width,
            .show_whitespace = self.buf.ed.show_whitespace,
        };
    }

    /// The caret's column in *display* cells, which is not its byte
    /// column once a line holds anything multi-byte, double-width, or a
    /// tab.
    fn cursorDisplayCol(self: *Ui) !usize {
        const pos = self.buf.ed.pos();
        const start = self.buf.ed.buf.lineStart(pos.line);
        const text = try self.buf.ed.buf.gap.read(self.alloc, start, start + pos.col);
        defer self.alloc.free(text);
        return display.width(text, self.displayOpts());
    }

    /// The grapheme the caret sits on, or a space at end of line. A tab
    /// reads as a space: the caret is one inverted cell and sits on the
    /// first of the several the tab covers, the way vim draws it.
    fn cursorGrapheme(self: *Ui) ![]u8 {
        const c = self.buf.ed.cursor;
        if (c >= self.buf.ed.buf.len() or self.buf.ed.buf.byteAt(c) == '\n' or
            self.buf.ed.buf.byteAt(c) == '\t')
        {
            return self.alloc.dupe(u8, " ");
        }
        const seq = std.unicode.utf8ByteSequenceLength(self.buf.ed.buf.byteAt(c)) catch 1;
        return self.buf.ed.buf.gap.read(self.alloc, c, c + seq);
    }

    fn renderTree(self: *Ui, batch: *glyphwire.client.Client.Batch) !void {
        const b = self.tree_bounds;
        if (b.cols == 0 or b.rows == 0) return;

        // The whole listing is written, not just the visible slice: the
        // content grid *is* the tree, and the host scrolls a viewport over
        // it. This runs on an expand or collapse, never on a scroll.
        const content_cols = self.treeContentCols();
        const content_rows = self.treeContentRows();

        var line: std.ArrayList(u8) = .empty;
        defer line.deinit(self.alloc);

        // The name field stands in for the highlight while it is up: it is
        // where the keyboard is.
        const editing = self.tree_edit != null;
        var r: usize = 0;
        while (r < content_rows) : (r += 1) {
            if (self.tree_edit) |te| {
                if (r == te.row) {
                    try self.renderTreeEditRow(batch, content_cols);
                    continue;
                }
            }
            const entry = self.treeRowEntry(r);
            const selected = !editing and self.focus == .tree and r == self.tree.cursor;
            const bg = if (selected) role(.selection_bg) else role(.sidebar_bg);

            line.clearRetainingCapacity();
            if (entry) |e| {
                try line.appendNTimes(self.alloc, ' ', e.depth * tree_mod.indent_cols + tree_mod.icon_cols);
                try line.appendSlice(self.alloc, e.name);
                // The host pads the row to the full content width.
                try batch.writeTextOpts(line.items, .{
                    .layer = self.tree_layer,
                    .row = r,
                    .col = 0,
                    // A row that is only here because Ctrl+H is on is
                    // drawn dim, so "show hidden" reads as a listing with
                    // extra, lesser entries rather than as a listing that
                    // mysteriously doubled in length.
                    // A workspace folder's header stands out from the
                    // directories under it, the way VS Code's does.
                    .fg = if (e.is_root)
                        role(.fg_strong)
                    else if (e.hidden)
                        (if (e.is_dir) role(.hidden_dir) else role(.hidden))
                    else
                        (if (e.is_dir) role(.dir) else role(.fg)),
                    .bg = bg,
                    .max_cols = content_cols,
                    .pad = true,
                });

                // The icon composites *over* the row's background rather
                // than replacing it, so a selected row stays highlighted
                // underneath it. Sized exactly like `glyphwire-ls`'s
                // small-table icons: natural, capped in *height* to one
                // row and free to overflow its column in width (a plain
                // `"fit"` shrinks a 32px source to the ~8px a cell is wide
                // and is unreadable). Only `max_h` -- adding `max_w` would
                // shrink it back to the narrow cell width. Falls back to
                // `.fit` if the cell metrics somehow didn't load.
                const natural = self.cell_px_h > 0;
                try batch.drawIconOnStyled(self.tree_layer, r, e.depth * tree_mod.indent_cols, iconFor(e), .{
                    .scale = if (natural) .natural else .fit,
                    .h_align = .start,
                    .v_align = .center,
                    .max_h = if (natural) self.cell_px_h else null,
                    .foreground = true,
                });
            } else {
                try batch.clearArea(.{ .layer = self.tree_layer, .row = r, .rows = 1, .cols = content_cols, .bg = role(.sidebar_bg) });
            }
        }

        self.tree_painted = .{ .row = self.tree.cursor, .focused = !editing and self.focus == .tree };
    }

    /// The name field's row: the icon the entry has (or will have), the
    /// typed name and the caret, on the highlight. The cheap repaint for a
    /// keystroke in the field -- the rest of the listing hasn't moved.
    fn renderTreeEditRow(self: *Ui, batch: *glyphwire.client.Client.Batch, content_cols: usize) !void {
        const te = &(self.tree_edit orelse return);
        const text = te.field.text();
        const indent = te.depth * tree_mod.indent_cols;
        const start = indent + tree_mod.icon_cols;

        var line: std.ArrayList(u8) = .empty;
        defer line.deinit(self.alloc);
        try line.appendNTimes(self.alloc, ' ', start);
        try line.appendSlice(self.alloc, text);
        try batch.writeTextOpts(line.items, .{
            .layer = self.tree_layer,
            .row = te.row,
            .col = 0,
            .fg = role(.fg),
            .bg = role(.selection_bg),
            .max_cols = content_cols,
            .pad = true,
        });

        // The caret, inverted the way the `:` line draws its own.
        const caret_col = start + te.field.caretCol();
        if (caret_col < content_cols) {
            const under = if (te.field.caret < text.len)
                text[te.field.caret..lineedit.nextBoundary(text, te.field.caret)]
            else
                " ";
            try batch.writeTextOpts(under, .{
                .layer = self.tree_layer,
                .row = te.row,
                .col = caret_col,
                .fg = role(.selection_bg),
                .bg = role(.fg),
            });
        }

        // A rename keeps the entry's icon; a create shows what the typed
        // name will make, so a trailing `/` turns it into a folder.
        const icon: []const u8 = switch (te.kind) {
            .rename => if (self.tree.at(te.row)) |e| iconFor(e) else "file/folder",
            .create_dir => "file/folder",
            .create => if (std.mem.endsWith(u8, text, "/"))
                "file/folder"
            else
                ls_icons.iconForFileName(text) orelse ls_icons.iconForExtension(text),
        };
        const natural = self.cell_px_h > 0;
        try batch.drawIconOnStyled(self.tree_layer, te.row, indent, icon, .{
            .scale = if (natural) .natural else .fit,
            .h_align = .start,
            .v_align = .center,
            .max_h = if (natural) self.cell_px_h else null,
            .foreground = true,
        });
    }

    /// The cheap half of the tree repaint: the highlight moved, and
    /// nothing else did.
    ///
    /// The listing is already on the layer in full -- `renderTree` writes
    /// every row, not just the visible ones -- so moving the cursor is
    /// two `set_bg`s: the row that was highlighted back to the pane
    /// colour, the row that now is to the selection colour. `set_bg`
    /// repaints backgrounds only, so the names and the per-entry icons
    /// (drawn `foreground: true`) survive untouched, which is the whole
    /// reason it exists -- see docs/api.md.
    fn renderTreeSelection(self: *Ui, batch: *glyphwire.client.Client.Batch) !void {
        if (self.tree_bounds.cols == 0 or self.tree_bounds.rows == 0) return;
        // The field's start and end repaint in full; there is no
        // highlight to move while it is up.
        if (self.tree_edit != null) return;
        const focused = self.focus == .tree;
        const cols = self.treeContentCols();
        const was = self.tree_painted;
        if (was.focused == focused and was.row == self.tree.cursor) return;

        if (was.focused) {
            try batch.setBg(.{ .layer = self.tree_layer, .row = was.row, .rows = 1, .cols = cols, .bg = role(.sidebar_bg) });
        }
        if (focused) {
            try batch.setBg(.{ .layer = self.tree_layer, .row = self.tree.cursor, .rows = 1, .cols = cols, .bg = role(.selection_bg) });
        }
        self.tree_painted = .{ .row = self.tree.cursor, .focused = focused };
    }

    fn iconFor(e: tree_mod.Entry) []const u8 {
        if (e.is_dir) {
            return ls_icons.iconForDirName(e.name) orelse
                (if (e.expanded) "file/folder-open" else "file/folder");
        }
        return ls_icons.iconForFileName(e.name) orelse ls_icons.iconForExtension(e.name);
    }

    /// Redraws the tab strip.
    ///
    /// The strip is laid out in *strip* columns (`zoe/tabs.zig`), scrolled
    /// so the active tab is fully on screen, then written one run per tab
    /// -- clipped to the pane, since a tab at either edge may be half off
    /// it. The row is painted with the bar's background first, so a tab
    /// that just closed leaves no cells of its own behind.
    fn renderTabs(self: *Ui, batch: *glyphwire.client.Client.Batch) !void {
        const b = self.grp.tabs_bounds;
        if (b.cols == 0 or b.rows == 0) return;

        var labels: std.ArrayList(tabs.Tab) = .empty;
        defer labels.deinit(self.alloc);
        for (self.grp.buffers.items) |slot| {
            try labels.append(self.alloc, .{
                .label = tabs.labelFor(slot.ed.path),
                .dirty = slot.ed.buf.dirty,
            });
        }

        self.grp.tab_total = try tabs.layout(self.alloc, labels.items, &self.grp.tab_spans);
        if (self.grp.active < self.grp.tab_spans.items.len) {
            self.grp.tab_scroll = tabs.scrollToShow(
                self.grp.tab_spans.items[self.grp.active],
                b.cols,
                self.grp.tab_scroll,
                self.grp.tab_total,
            );
        }
        try self.syncTabScrollbar(batch);

        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(self.alloc);

        try batch.clearArea(.{ .layer = self.grp.tabs_layer, .row = 0, .rows = 1, .bg = role(.tab_bar_bg) });

        for (self.grp.tab_spans.items, labels.items, 0..) |span, tab, i| {
            const active = i == self.grp.active;
            text.clearRetainingCapacity();
            try text.append(self.alloc, ' ');
            try text.appendSlice(self.alloc, tab.label);
            if (tab.dirty) {
                try text.append(self.alloc, ' ');
                try text.appendSlice(self.alloc, tabs.dirty_mark);
            }
            try text.append(self.alloc, ' ');
            try text.appendSlice(self.alloc, tabs.close_glyph);
            try text.append(self.alloc, ' ');

            // A group's shown tab joins its pane (`bg_buffer`); only the
            // focused group's is lit, so with several groups up the strip
            // says which one the keyboard is in.
            try self.writeStripRun(
                batch,
                span.start,
                text.items,
                if (active and self.render_focused) role(.fg) else role(.fg_dim),
                if (active) role(.bg) else role(.tab_bg),
            );
            if (i + 1 < self.grp.tab_spans.items.len) {
                try self.writeStripRun(batch, span.end, tabs.separator, role(.fg_dim), role(.tab_bar_bg));
            }
        }
    }

    /// Writes one run of the tab strip, positioned in strip columns and
    /// clipped to the visible window. A run entirely off the pane writes
    /// nothing; one straddling an edge is sliced at a display column, so
    /// a double-width character is never cut in half.
    fn writeStripRun(
        self: *Ui,
        batch: *glyphwire.client.Client.Batch,
        start: usize,
        text: []const u8,
        fg: Color,
        bg: Color,
    ) !void {
        const width = glyphwire.stringWidth(text);
        const view_lo = self.grp.tab_scroll;
        const view_hi = self.grp.tab_scroll + self.grp.tabs_bounds.cols;
        const lo = @max(start, view_lo);
        const hi = @min(start + width, view_hi);
        if (lo >= hi) return;

        // Tab labels hold no tabs and take no space markers, so the
        // default `Opts` is the plain codepoint-width walk this wants.
        const from = display.byteAtCol(text, lo - start, .{});
        const to = display.byteAtCol(text, hi - start, .{});
        try writeAt(batch, self.grp.tabs_layer, 0, lo - view_lo, text[from..to], fg, bg);
    }

    /// Keeps the tabs layer's virtual extent and offset in step with the
    /// strip, the same arrangement the buffer pane has: the layer's grid
    /// is only pane-wide, and reporting the strip's real width is what
    /// lets the host turn a shift+wheel or a drag over it into the
    /// `scroll_offset` `handleEvent` follows. Silent when nothing moved.
    fn syncTabScrollbar(self: *Ui, batch: *glyphwire.client.Client.Batch) !void {
        const now: [2]usize = .{ self.grp.tab_total, self.grp.tab_scroll };
        if (std.mem.eql(usize, &now, &self.grp.pushed_tab_bar)) return;

        if (now[0] != self.grp.pushed_tab_bar[0]) {
            try batch.setLayerContentExtent(
                self.grp.tabs_layer,
                @max(self.grp.tab_total, self.grp.tabs_bounds.cols),
                1,
            );
        }
        try batch.setLayerScrollOffset(self.grp.tabs_layer, 0, self.grp.tab_scroll);
        self.grp.pushed_tab_bar = now;
    }

    /// The diagnostic the statusline should show, if any: whatever covers the
    /// cursor, else the worst on its line (see `diag.Store.atCursor` for why
    /// the fallback is there).
    fn cursorDiagnostic(self: *Ui) ?diag.Entry {
        if (self.lsp_pool == null) return null;
        const abs = self.slotAbs(self.buf) orelse return null;
        const pos = self.buf.ed.pos();
        return self.diags.atCursor(abs, @intCast(pos.line), @intCast(pos.col));
    }

    fn renderStatus(self: *Ui, batch: *glyphwire.client.Client.Batch) !void {
        const b = self.status_bounds;
        if (b.cols == 0) return;

        var line: std.ArrayList(u8) = .empty;
        defer line.deinit(self.alloc);
        var fg = role(.status_fg);

        // A tree search takes the row ahead of everything else: it is the
        // only thing on screen that says what was typed, since the prefix
        // itself is never drawn in the pane. The `/` prompt keeps the key
        // that started it, so the scope the search is running in stays
        // readable while it runs.
        // The sidebar's name field says what Enter will do, or why the
        // last one didn't.
        if (self.tree_edit) |te| {
            if (te.err) |msg| {
                fg = role(.message_error);
                try line.print(self.alloc, " {s}", .{msg});
            } else {
                var home_buf: [std.fs.max_path_bytes]u8 = undefined;
                const where = homepath.collapseHome(te.dir, self.environ.get("HOME"), &home_buf);
                switch (te.kind) {
                    .create => try line.print(self.alloc, " New file in {s}  (end with / for a folder; Enter creates, Esc cancels)", .{where}),
                    .create_dir => try line.print(self.alloc, " New folder in {s}  (Enter creates, Esc cancels)", .{where}),
                    .rename => try line.print(self.alloc, " Rename {s}  (Enter renames, Esc cancels)", .{te.old_name}),
                }
            }
        } else if (self.find) |f| {
            const prompt: []const u8 = if (f.scope == .deep) "/" else "find: ";
            const n = f.hits.items.len;
            if (n == 0) {
                if (f.query.items.len > 0) fg = role(.message_error);
                try line.print(self.alloc, " {s}{s}  (no match)", .{ prompt, f.query.items });
            } else {
                try line.print(self.alloc, " {s}{s}  [{d}/{d}]", .{ prompt, f.query.items, f.pick + 1, n });
            }
            if (f.deep) |d| {
                if (d.truncated) try line.appendSlice(self.alloc, "  (partial)");
            }
        } else if (self.buf.ed.mode == .command) {
            try line.append(self.alloc, ':');
            try line.appendSlice(self.alloc, self.buf.ed.cmdline.text());
        } else if (self.buf.ed.mode == .search) {
            // `/foo` or `?foo`, in the error colour once the pattern
            // stops matching -- the same signal the tree's `/` gives.
            if (self.buf.ed.search_failed) fg = role(.message_error);
            try line.append(self.alloc, self.buf.ed.searchPrompt());
            try line.appendSlice(self.alloc, self.buf.ed.cmdline.text());
        } else if (self.buf.ed.status.items.len > 0) {
            if (std.mem.startsWith(u8, self.buf.ed.status.items, "E")) fg = role(.message_error);
            try line.appendSlice(self.alloc, self.buf.ed.status.items);
        } else {
            const pos = self.buf.ed.pos();
            try line.print(self.alloc, " {s}  {s}{s}", .{
                modeName(self.buf.ed.mode),
                self.buf.ed.path orelse "[No Name]",
                if (self.buf.ed.buf.dirty) " [+]" else "",
            });
            // Which tab this is, once there is more than one. The strip
            // above shows the names; this is the count.
            if (self.grp.buffers.items.len > 1) {
                try line.print(self.alloc, "  [{d}/{d}]", .{ self.grp.active + 1, self.grp.buffers.items.len });
            }
            // The diagnostic under the cursor, with the tool that reported
            // it -- which matters, because two servers publish for the same
            // Python file and "unused import" and "is not defined" come from
            // different places. Truncated by the write's `max_cols`; the
            // position on the right is the thing worth keeping whole.
            if (self.cursorDiagnostic()) |d| {
                try line.print(self.alloc, "  {s}: {s}", .{ d.source, d.message });
            }
            // The position is right-aligned, so the mode and filename on
            // the left don't shift it around as they change length.
            var right: [48]u8 = undefined;
            const tail = std.fmt.bufPrint(&right, "{d}:{d} ", .{ pos.line + 1, pos.col + 1 }) catch "";
            const used = glyphwire.stringWidth(line.items) + glyphwire.stringWidth(tail);
            if (used < b.cols) try line.appendNTimes(self.alloc, ' ', b.cols - used);
            try line.appendSlice(self.alloc, tail);
        }

        // The mode word (right after the leading space, in the normal
        // status form) gets its own colour as a span of the same write.
        const mode_word = modeName(self.buf.ed.mode);
        // Only the plain status form starts with the mode word; the tree's
        // search and name field take the row with text of their own.
        const show_mode = self.buf.ed.mode != .command and self.buf.ed.mode != .search and
            self.buf.ed.status.items.len == 0 and self.find == null and self.tree_edit == null;
        const opts: glyphwire.client.Client.TextOpts = .{
            .layer = self.status_layer,
            .row = 0,
            .col = 0,
            .fg = fg,
            .bg = role(.status_bg),
            .max_cols = b.cols,
            .pad = true,
        };
        if (show_mode) {
            const mode_end = 1 + mode_word.len;
            try batch.writeSpans(&.{
                .{ .text = line.items[0..1] },
                .{ .text = line.items[1..mode_end], .fg = role(.mode) },
                .{ .text = line.items[mode_end..] },
            }, opts);
        } else {
            try batch.writeTextOpts(line.items, opts);
        }

        // The `:` and `/` lines' caret, as the same inverted block the
        // buffer pane draws. Only needed now that the command line is a
        // real field: while it was append-only the caret was always at
        // the end, and the statusline's own trailing blank read as one.
        if (self.buf.ed.mode == .command or self.buf.ed.mode == .search) {
            const cmd = &self.buf.ed.cmdline;
            const col = 1 + cmd.caretCol(); // past the leading `:` or `/`
            if (col < b.cols) {
                const under = if (cmd.caret < cmd.text().len)
                    cmd.text()[cmd.caret..lineedit.nextBoundary(cmd.text(), cmd.caret)]
                else
                    " ";
                try batch.writeTextOpts(under, .{
                    .layer = self.status_layer,
                    .row = 0,
                    .col = col,
                    .fg = role(.status_bg),
                    .bg = fg,
                });
            }
        }
    }

    fn modeName(mode: editor.Mode) []const u8 {
        return switch (mode) {
            .normal => "NORMAL",
            .insert => "INSERT",
            .command => "COMMAND",
            .visual => "VISUAL",
            .visual_line => "V-LINE",
            .search => "SEARCH",
            .select => "SELECT",
        };
    }
};

/// The scroll/edit state `planBufferRender` decides from.
/// What one screen row of the buffer pane shows: a window of display
/// columns onto one buffer line. Unwrapped every row is a whole line
/// seen from `left_col`; with `wrap` on a long line spans several rows,
/// each one a `wrap.Row` of it. The painters only ever see this, so the
/// same row code draws both.
pub const RowView = struct {
    /// The buffer line. At or past the line count means the row is below
    /// the end of the buffer (vim's `~`).
    line: usize,
    /// Which of the line's rows this is; only row 0 is numbered.
    sub: usize,
    /// The first display column of the line the row shows.
    left: usize,
    /// How many of the line's display columns the row shows. The pane is
    /// still `textCols` wide; a wrapped row that breaks early leaves the
    /// rest blank.
    cols: usize,
    /// The line's last row -- where a selection reaching the newline, or
    /// the insert-mode caret after the last character, is drawn.
    last: bool,

    pub fn pastEnd(self: RowView, line_count: usize) bool {
        return self.line >= line_count;
    }
};

/// Fills `out` with the `rows` screen rows of a pane whose first row is
/// row `top_sub` of buffer line `top_line`. `lines` hands back a line's
/// text (without its newline) and how many lines there are; it is a
/// parameter so `tests/zoe_tests.zig` can drive this without a buffer.
/// `width` is the text width; `wrap_on` false gives one row per line,
/// seen from `left`.
pub fn layoutRowMap(
    alloc: std.mem.Allocator,
    out: *std.ArrayList(RowView),
    lines: anytype,
    top_line: usize,
    top_sub: usize,
    left: usize,
    rows: usize,
    width: usize,
    wrap_on: bool,
    opts: display.Opts,
) !void {
    out.clearRetainingCapacity();
    const count = lines.count();
    if (!wrap_on) {
        for (0..rows) |r| try out.append(alloc, .{ .line = top_line + r, .sub = 0, .left = left, .cols = width, .last = true });
        return;
    }
    var line = top_line;
    var skip = top_sub;
    while (out.items.len < rows) : (line += 1) {
        if (line >= count) {
            try out.append(alloc, .{ .line = line, .sub = 0, .left = 0, .cols = width, .last = true });
            continue;
        }
        const text = try lines.text(alloc, line);
        defer alloc.free(text);
        var it = softwrap.Rows.init(text, opts, width);
        var sub: usize = 0;
        var pending: ?softwrap.Row = it.next();
        while (pending) |row| : (sub += 1) {
            pending = it.next();
            if (sub < skip) continue;
            if (out.items.len >= rows) break;
            try out.append(alloc, .{
                .line = line,
                .sub = sub,
                .left = row.start_col,
                .cols = row.end_col - row.start_col,
                .last = pending == null,
            });
        }
        skip = 0;
    }
}

/// A digest of which (line, row-of-line) each screen row shows -- what
/// `Slot.prev_row_hash` compares.
pub fn rowMapHash(map: []const RowView) u64 {
    var h = std.hash.Wyhash.init(0);
    for (map) |rv| {
        h.update(std.mem.asBytes(&rv.line));
        h.update(std.mem.asBytes(&rv.sub));
    }
    return h.final();
}

pub const BufferRenderState = struct {
    /// The scroll position the buffer layer's cells currently reflect.
    prev_top: usize,
    prev_left: usize,
    /// The scroll position this frame wants.
    top: usize,
    left: usize,
    /// `Buffer.edits` last frame vs. now -- any change means an edit.
    prev_edits: u64,
    edits: u64,
    /// Visible rows in the buffer pane.
    rows: usize,
    /// A pane bounds change or a fresh buffer forces a repaint.
    force_full: bool,
};

/// What `renderBuffer` should do this frame. Split out as a pure
/// decision so `tests/zoe_tests.zig` can exercise it without a live
/// client.
pub const BufferRender = union(enum) {
    /// Repaint every visible row.
    full,
    /// Shift the rows already on the layer by `count` in `dir` with one
    /// `move_content`, then repaint screen rows `[exposed_lo, exposed_hi)`.
    shift: struct {
        count: usize,
        dir: glyphwire.Layer.ScrollDir,
        exposed_lo: usize,
        exposed_hi: usize,
    },
};

/// A row shift can express a pure vertical scroll of less than a screen
/// and nothing else. An edit (`edits` moved), a horizontal scroll, a
/// jump of a screen or more, an empty pane, or a forced repaint are all
/// `.full`.
pub fn planBufferRender(s: BufferRenderState) BufferRender {
    const d: i64 = @as(i64, @intCast(s.top)) - @as(i64, @intCast(s.prev_top));
    const shift: usize = @abs(d);
    if (s.force_full or s.edits != s.prev_edits or s.left != s.prev_left or
        s.rows == 0 or shift == 0 or shift >= s.rows)
    {
        return .full;
    }
    return .{ .shift = .{
        .count = shift,
        .dir = if (d > 0) .up else .down,
        .exposed_lo = if (d > 0) s.rows - shift else 0,
        .exposed_hi = if (d > 0) s.rows else shift,
    } };
}

/// Cells the buffer-pane line-number gutter occupies for a file of
/// `line_count` lines shown in `mode`: the widest number's digit count,
/// floored at 3, plus one separator space. Zero when the gutter is off.
pub fn gutterWidthFor(mode: editor.LineNumbers, line_count: usize) usize {
    if (mode == .off) return 0;
    var n = line_count;
    var digits: usize = 1;
    while (n >= 10) : (n /= 10) digits += 1;
    return @max(3, digits) + 1;
}

/// The text of one gutter cell, `width` display cells wide (a
/// `gutterWidthFor` result), for buffer line `line` (0-based) with the
/// caret on `cursor_line`. `past_end` -- the screen row is below the last
/// buffer line -- gives an all-blank cell, like vim leaves beside its
/// `~` markers. The number is right-aligned in the leading `width - 1`
/// cells with the last cell a blank separator; in `.relative` mode the
/// caret's own line still shows its absolute number. Written into `buf`
/// (which must be at least `width` bytes) and returned as a slice, so
/// this needs no allocator.
pub fn gutterCellText(
    buf: []u8,
    mode: editor.LineNumbers,
    width: usize,
    line: usize,
    cursor_line: usize,
    past_end: bool,
) []const u8 {
    if (mode == .off or width == 0) return buf[0..0];
    @memset(buf[0..width], ' ');
    if (past_end) return buf[0..width];

    const value: usize = switch (mode) {
        .off => unreachable,
        .absolute => line + 1,
        .relative => if (line == cursor_line)
            line + 1
        else if (line > cursor_line)
            line - cursor_line
        else
            cursor_line - line,
    };

    var num: [24]u8 = undefined;
    const shown = std.fmt.bufPrint(&num, "{d}", .{value}) catch return buf[0..width];

    // Right-align in the digit field (`width - 1`); the trailing cell
    // stays the blank the memset left. A number wider than the field
    // (a min-width gutter over a huge file) is clamped to what fits.
    const digits = width - 1;
    const n = @min(shown.len, digits);
    @memcpy(buf[digits - n ..][0..n], shown[shown.len - n ..]);
    return buf[0..width];
}


/// The colour of the span covering line-relative byte `off`, or null for
/// "no span here" (the default text colour). Spans are sorted and
/// non-overlapping, so the first hit is the answer.
fn selEql(a: ?editor.Editor.SelSpan, b: ?editor.Editor.SelSpan) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return a.?.lo == b.?.lo and a.?.hi == b.?.hi and a.?.linewise == b.?.linewise;
}

fn spanColorAt(spans: []const syntax.Span, off: usize) ?Color {
    for (spans) |s| {
        if (off < s.start) return null;
        if (off < s.end) return s.color;
    }
    return null;
}

fn colorOptEql(a: ?Color, b: ?Color) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return a.?.eql(b.?);
}

// ── Hover rows ─────────────────────────────────────────────────────────────

/// One drawn row of the hover popup: bytes `[start, end)` of
/// `doc.lines[line]`, shown after `indent` blank cells.
pub const HoverRow = struct {
    line: usize,
    start: usize = 0,
    end: usize = 0,
    indent: usize = 0,
};

const spaces: [32]u8 = @splat(' ');

/// Cuts a hover doc into rows `cols` wide. A line keeps its leading
/// indentation on its first row, and its continuation rows are indented to
/// match, so wrapped code still lines up under the line it came from.
/// Wrapping is on spaces (`WrapIterator`), code included: a long signature
/// is a list of parameters, and breaking between them reads better than
/// clipping it.
pub fn wrapHover(
    alloc: std.mem.Allocator,
    doc: *const hover_mod.Doc,
    cols: usize,
    out: *std.ArrayList(HoverRow),
) !void {
    for (doc.lines, 0..) |line, i| {
        if (line.kind == .rule or line.text.len == 0) {
            try out.append(alloc, .{ .line = i });
            continue;
        }
        var indent: usize = 0;
        while (indent < line.text.len and line.text[indent] == ' ') indent += 1;
        // Deep indentation gives up its alignment rather than the text.
        if (indent > cols / 2) indent = 0;
        const body = line.text[indent..];
        var wrap = glyphwire.WrapIterator.init(body, cols - indent);
        var first = true;
        while (wrap.next()) |piece| {
            const start = indent + (@intFromPtr(piece.ptr) - @intFromPtr(body.ptr));
            try out.append(alloc, .{
                .line = i,
                // The first row carries its own indentation in its bytes.
                .start = if (first) 0 else start,
                .end = start + piece.len,
                .indent = if (first) 0 else indent,
            });
            first = false;
        }
        // All spaces: still a row.
        if (first) try out.append(alloc, .{ .line = i });
    }
}

/// Bytes `[start, end)` of `text` as client spans, coloured by `spans`
/// (offsets into the whole of `text`, sorted, non-overlapping -- what
/// `Highlighter.lineSpans` produces) and `default_fg` in the gaps.
pub fn colorRuns(
    alloc: std.mem.Allocator,
    text: []const u8,
    spans: []const syntax.Span,
    start: usize,
    end: usize,
    default_fg: Color,
    out: *std.ArrayList(glyphwire.client.Client.Span),
) !void {
    var at = start;
    for (spans) |s| {
        if (s.end <= at) continue;
        if (s.start >= end) break;
        if (s.start > at) {
            try out.append(alloc, .{ .text = text[at..s.start], .fg = default_fg });
            at = s.start;
        }
        const stop = @min(s.end, end);
        try out.append(alloc, .{ .text = text[at..stop], .fg = s.color });
        at = stop;
    }
    if (at < end) try out.append(alloc, .{ .text = text[at..end], .fg = default_fg });
}
