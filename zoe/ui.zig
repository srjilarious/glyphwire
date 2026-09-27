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
//! See docs/investigations/zoe-editor.md for what a full diff would add.
//!
//! **The caret is drawn by two parties.** Insert mode uses the host's own
//! caret as a thin bar on the buffer layer (`set_caret_shape`), the way
//! nvim does; every other mode is zoe's inverted cell, which keeps the
//! character under it readable, and the host's caret is hidden. See
//! `syncCaret`. Ctrl+` opens a `gw-shell` panel over the bottom of the
//! window (`src/shellpanel.zig`) that takes the keyboard and the caret
//! until it is closed.

const std = @import("std");
const glyphwire = @import("glyphwire");
const ls_icons = @import("ls_support").icons;

const editor = @import("editor.zig");
const display = @import("display.zig");
const search = @import("search.zig");
const tree_mod = @import("tree.zig");
const finder_mod = @import("finder.zig");
const filetype = @import("filetype.zig");
const syntax = @import("syntax.zig");
const langconf = @import("langconf.zig");
const tabs = @import("tabs.zig");
const lsp = @import("lsp.zig");
const diag = @import("diag.zig");
const shellpanel = glyphwire.shellpanel;

const Editor = editor.Editor;
const Tree = tree_mod.Tree;
const Finder = finder_mod.Finder;
const lineedit = glyphwire.lineedit;
const Color = glyphwire.Color;

/// Cells the tree pane occupies until a divider drag says otherwise.
const default_tree_cols: usize = 28;

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

// The palette. Flat and dark; the panes have to paint their own
// background because a cell whose background is pure black draws nothing
// (see `host/render.zig`), which would leave the shell's scrollback
// showing through.
const bg_buffer = Color{ .r = 24, .g = 24, .b = 29, .a = 255 };
const bg_tree = Color{ .r = 20, .g = 20, .b = 25, .a = 255 };
const bg_status = Color{ .r = 46, .g = 46, .b = 56, .a = 255 };
const bg_cursor = Color{ .r = 220, .g = 220, .b = 230, .a = 255 };
const bg_selected = Color{ .r = 48, .g = 62, .b = 84, .a = 255 };
// Search matches. Amber rather than another blue so a `/` highlight is
// never mistaken for a selection, and two weights of it: every match gets
// the dim one, the match the cursor is on gets the bright one, which is
// how you tell where `n` just landed in a screen full of hits.
const bg_match = Color{ .r = 84, .g = 68, .b = 34, .a = 255 };
const bg_match_current = Color{ .r = 150, .g = 116, .b = 42, .a = 255 };
const fg_text = Color{ .r = 210, .g = 210, .b = 218, .a = 255 };
const fg_dim = Color{ .r = 92, .g = 92, .b = 104, .a = 255 };
const fg_dir = Color{ .r = 132, .g = 176, .b = 232, .a = 255 };
/// A tree row that is only on screen because Ctrl+H is on -- a dotfile or
/// something `.gitignore` excludes. Dimmed rather than marked, so the
/// listing still reads as one list, and kept distinct for files and
/// directories so the shape of the tree survives the dimming. Roughly
/// halfway from the normal colour to the pane background, which is enough
/// to be obvious next to a real entry and still readable on its own.
const fg_hidden = Color{ .r = 112, .g = 112, .b = 120, .a = 255 };
const fg_hidden_dir = Color{ .r = 84, .g = 108, .b = 142, .a = 255 };
const fg_status = Color{ .r = 226, .g = 226, .b = 236, .a = 255 };
const fg_mode = Color{ .r = 150, .g = 220, .b = 160, .a = 255 };
const fg_error = Color{ .r = 240, .g = 140, .b = 140, .a = 255 };
const fg_cursor = Color{ .r = 24, .g = 24, .b = 29, .a = 255 };
// The space dots and tab arrows `:set whitespace=on` paints. Faint on
// purpose: bright enough to read the indentation off, dim enough to
// disappear when you stop looking for it. Not a theme group -- the theme
// maps tree-sitter captures, and whitespace has none.
const fg_whitespace = Color{ .r = 62, .g = 62, .b = 72, .a = 255 };
// The tab strip. The active tab takes the buffer's own background so it
// reads as the front of the pane below it, the way a tabbed window does;
// the rest sit on a bar darker than either.
const bg_tab_bar = Color{ .r = 16, .g = 16, .b = 20, .a = 255 };
const bg_tab = Color{ .r = 34, .g = 34, .b = 41, .a = 255 };

// The Ctrl+` shell panel: darker than the buffer, so it reads as a
// terminal laid over the editor and not as more of it. Opaque for the
// same reason -- the shell only writes the cells it uses.
const bg_shell = Color{ .r = 14, .g = 15, .b = 18, .a = 255 };

// The Ctrl+P finder popup. Lighter than the panes it floats over, so it
// reads as being in front of them rather than as another pane -- the
// same trick salacommander's dialogs use.
const bg_finder = Color{ .r = 38, .g = 38, .b = 46, .a = 255 };
const bg_finder_header = Color{ .r = 40, .g = 90, .b = 170, .a = 255 };
const fg_finder_header = Color{ .r = 235, .g = 240, .b = 250, .a = 255 };
const bg_finder_selected = Color{ .r = 70, .g = 120, .b = 200, .a = 255 };
const fg_finder_selected = Color{ .r = 245, .g = 250, .b = 255, .a = 255 };

/// Rows the finder popup spends on its header: the title/count bar and
/// the query line under it. The rest of its height is the match list.
const finder_header_rows: usize = 2;

/// The popup's preferred size, in cells. Clamped down to what the buffer
/// pane can actually hold (`finderRect`), so a narrow window shrinks it
/// rather than pushing it off the edge.
const finder_max_cols: usize = 84;
const finder_max_rows: usize = 20;
const finder_min_cols: usize = 24;
const finder_min_rows: usize = 4;

/// Diagnostic colours: the squiggle under the text, and the mark in the
/// sign column. Red/amber/blue/grey by severity, which is the convention
/// every editor and every compiler shares -- worth following exactly
/// because it is read at a glance and never looked up.
const fg_diag_error = Color{ .r = 232, .g = 92, .b = 92, .a = 255 };
const fg_diag_warning = Color{ .r = 226, .g = 176, .b = 74, .a = 255 };
const fg_diag_info = Color{ .r = 108, .g = 164, .b = 232, .a = 255 };
const fg_diag_hint = Color{ .r = 132, .g = 132, .b = 148, .a = 255 };

/// The sign-column glyph. Solid for an error, hollow for everything else,
/// so severity still reads on a display where the colours are hard to tell
/// apart -- and both are one cell wide in every font, which a fancier
/// symbol from a Nerd Font range would not be.
const sign_error = "\u{25cf}"; // ●
const sign_other = "\u{25cb}"; // ○

/// The hover popup's size limits, clamped to the pane like the finder's.
const hover_max_cols: usize = 76;
const hover_max_rows: usize = 14;
const bg_hover = Color{ .r = 34, .g = 34, .b = 42, .a = 255 };
const fg_hover = Color{ .r = 214, .g = 214, .b = 222, .a = 255 };

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

/// An open hover popup. `text` is owned; `scroll` is the first line shown,
/// since a hover on a documented function easily runs past the popup.
const Hover = struct {
    text: []const u8,
    scroll: usize = 0,

    fn deinit(self: *Hover, alloc: std.mem.Allocator) void {
        alloc.free(self.text);
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
pub const Target = union(enum) {
    /// No argument: an empty scratch buffer, tree on the cwd.
    none,
    /// A file to open -- or a name that doesn't exist yet, which is how
    /// `zoe newfile.txt` creates one.
    file: []const u8,
    /// A directory. `main` has already changed into it, so it *is* the
    /// cwd by the time the UI starts and there is nothing left to carry
    /// here: the tree roots on it like any other cwd, and the buffer
    /// starts empty.
    directory,
};

/// Which way a Ctrl+direction chord moves the focus.
pub const Direction = enum { left, right, up, down };

/// The direction a key names under Ctrl, for the focus chords: vim's
/// `hjkl` and the arrow keys both, since the panes are navigated with
/// either. Null for every other key, which is what lets `handleInput`
/// use this as the test for "is this a focus chord at all".
///
/// Claiming the vertical pair now costs nothing and keeps the mapping
/// whole: zoe will grow buffer panes stacked over each other, and having
/// Ctrl+j mean something else in the meantime would be a worse surprise
/// than it meaning nothing.
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
            a.show_whitespace == b.show_whitespace;
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
    /// The scroll position and edit count the buffer layer's cells
    /// currently reflect. `renderBuffer` diffs against these to shift the
    /// rows it already drew (`move_content`) on a pure scroll instead of
    /// rewriting every visible row.
    prev_top_line: usize = 0,
    prev_left_col: usize = 0,
    prev_cursor_line: usize = 0,
    prev_edits: u64 = 0,
    /// Whether the buffer pane's cells currently carry a selection
    /// highlight, so `renderBuffer` repaints once more to clear it when
    /// the selection goes away.
    prev_sel_active: bool = false,
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

    /// The `Buffer.edits` value the language servers have been told about.
    /// A mismatch arms the `didChange` debounce -- deliberately a separate
    /// watermark from `hl_edits` rather than a second consumer of
    /// `Buffer.pending_edits`, which the highlighter drains alone (see
    /// `docs/investigations/zoe-lsp.md`).
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

    fn deinit(self: *Slot, alloc: std.mem.Allocator) void {
        if (self.hl) |*h| h.deinit();
        if (self.abs_path) |p| alloc.free(p);
        self.ed.deinit();
        alloc.destroy(self);
    }
};

pub const Ui = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    client: *glyphwire.Client,
    listener: *glyphwire.InputListener,
    tree: Tree,

    /// Every open buffer, in tab order, and the one being edited. Heap
    /// slots rather than values in the list: `buf` points into it, and a
    /// list resize would move values out from under that pointer.
    ///
    /// Never empty -- closing the last buffer leaves a fresh scratch one
    /// (`closeBuffer`), so `buf` is always valid and the strip always has
    /// something to draw.
    buffers: std.ArrayList(*Slot) = .empty,
    /// The active buffer, always `buffers.items[active]`. Kept as a
    /// pointer because nearly every line of the render and dispatch paths
    /// reaches through it; `setActive` is the only writer of the pair.
    buf: *Slot,
    active: usize = 0,

    /// zoe's own context -- an alt-screen-style full-window surface, not
    /// a set of layers stacked over the shell's scrollback. Everything
    /// below (layers, splits) lives in it, and `destroyContext` on exit
    /// tears the whole thing down and drops visibility back to the shell.
    context: glyphwire.ContextHandle,
    tree_layer: glyphwire.LayerHandle,
    tabs_layer: glyphwire.LayerHandle,
    buffer_layer: glyphwire.LayerHandle,
    status_layer: glyphwire.LayerHandle,
    pane_split: glyphwire.SplitHandle,
    /// The tab strip stacked over the buffer pane. A column split of its
    /// own so the strip starts where the buffer does -- the file tree
    /// keeps its full height, and hiding the tree widens the strip with
    /// the pane it belongs to.
    buffer_col_split: glyphwire.SplitHandle,
    root_split: glyphwire.SplitHandle,

    tree_bounds: Bounds = .{},
    tabs_bounds: Bounds = .{},
    buffer_bounds: Bounds = .{},
    status_bounds: Bounds = .{},

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

    /// Session cell height in px, for natural-sizing tree icons to the
    /// row height. Read once at startup; a runtime font-zoom isn't
    /// announced to clients, so it can lag until the next launch.
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


    /// An in-progress left-button drag in the buffer pane. `anchor` is
    /// the buffer byte offset the press landed on; `moved` flips true the
    /// first time the pointer changes cell, which is when the drag turns
    /// into a visual selection (a press+release with no move is a plain
    /// click). Null when no button is down over the pane.
    drag: ?struct { anchor: usize, moved: bool } = null,

    /// The Ctrl+P file finder, non-null exactly while the popup is open.
    /// Its two layers float *outside* the split tree -- they are
    /// hand-positioned over the buffer pane and hidden the rest of the
    /// time, which is why no `layout` notification ever mentions them and
    /// `finderRect` has to work their geometry out itself.
    finder: ?Finder = null,
    finder_layer: glyphwire.LayerHandle,
    finder_list_layer: glyphwire.LayerHandle,

    /// The language servers, and everything they have said. The pool is
    /// null when `config.lsp.enabled` is false; it exists but holds no
    /// server when none of the configured binaries is installed, which is
    /// the ordinary case on a machine with only one toolchain. See
    /// `docs/investigations/zoe-lsp.md`.
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
    hover_rect: Bounds = .{},
    hover_dirty: bool = false,
    /// The newest outstanding `hover` / `definition` request id. A reply
    /// carrying anything else is stale -- the user asked again, or moved on
    /// -- and is dropped rather than popping a popup for a cursor position
    /// that is two jumps old.
    hover_request: ?i64 = null,
    definition_request: ?i64 = null,
    jumps: JumpList = .{},
    /// Ctrl+`: a `gw-shell` drawing into a layer across the bottom, above
    /// the statusline, for running builds and tests without leaving the
    /// editor. It floats outside the split tree like the finder and takes
    /// every keystroke but Ctrl+` while it is open. Rooted at the tree's
    /// directory. See `src/shellpanel.zig`.
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
    /// Whether the host's window has the keyboard, from `focus`
    /// notifications. Assumed true until told otherwise -- a window that
    /// has just been opened has it, and the host only reports changes.
    window_focused: bool = true,
    /// Whether the host's key repeat is currently the shell's -- its own
    /// default, with a hold before the first repeat -- rather than the
    /// editor's per-mode cadence. See `syncKeyRepeat`.
    key_repeat_shell: bool = false,
    /// Where the popup last landed, for hit-testing a click, and how many
    /// list rows that left. Recomputed every time it is drawn.
    finder_rect: Bounds = .{},
    finder_list_rows: usize = 0,

    focus: Focus = .buffer,
    tree_visible: bool = true,
    /// Per-pane redraw flags, set by whatever changed that pane's
    /// contents and cleared by `render`. Split three ways because a
    /// keystroke on the `:` line only touches the status row -- redrawing
    /// the buffer (a fresh syntax pass per visible row) and the whole
    /// file tree (a `draw_icon` per entry) on every such keystroke is
    /// what made the command line feel laggy.
    buffer_dirty: bool = true,
    /// The tree's own flag has three levels rather than two: moving the
    /// cursor changes exactly two rows' background, and repainting the
    /// whole listing (a `write_text` *and* a `draw_icon` per entry) for
    /// that is what made holding `j` down heavy. See `TreeDirty`.
    tree_dirty: TreeDirty = .full,
    tabs_dirty: bool = true,
    status_dirty: bool = true,
    finder_dirty: bool = false,
    quit: bool = false,

    /// The process environment, kept for `:cd` (`$HOME`) and passed on
    /// to the highlighter setup.
    environ: *const std.process.Environ.Map,
    /// The working directory before the last `:cd`, for `:cd -`. Owned.
    prev_cwd: ?[]u8 = null,

    /// tree-sitter syntax highlighting: the config, the grammar registry
    /// every buffer's highlighter resolves through, and the search path
    /// it was built from. All null / empty when highlighting is off -- no
    /// grammar directory resolved, or the config failed to load -- and
    /// every buffer then renders in plain `fg_text`. `hl_config`'s arena
    /// backs `grammars`' language table, so it outlives the registry.
    /// Each buffer's own parse tree lives in its `Slot`. See syntax.zig.
    hl_config: ?langconf.Config = null,
    grammars: ?syntax.Registry = null,
    hl_search_dirs: []const []const u8 = &.{},
    /// The mode the key-repeat cadence was last sent for, so
    /// `syncKeyRepeat` sends once per mode change. Tracks the *mode*
    /// rather than the cadence because the send is also what stops a
    /// held key repeating across the change -- which matters even when
    /// both modes are configured to the same numbers.
    key_repeat_mode_sent: ?editor.Mode = null,
    /// Reused span buffer for `renderRowSpans`.
    hl_scratch: std.ArrayList(syntax.Span) = .empty,
    /// Buffer lines an incremental reparse says need repainting for a
    /// highlighting reason (edited lines plus tree-sitter's changed
    /// ranges). Filled by `syncHighlight`, consumed by `renderChangedRows`.
    hl_dirty_lines: std.ArrayList(usize) = .empty,
    /// Scratch for `Highlighter.reparseIncremental`'s changed-range output.
    hl_changed: std.ArrayList(syntax.ByteRange) = .empty,

    pub fn init(
        alloc: std.mem.Allocator,
        io: std.Io,
        client: *glyphwire.Client,
        listener: *glyphwire.InputListener,
        target: Target,
        root_dir: []const u8,
        environ: *const std.process.Environ.Map,
    ) !*Ui {
        const self = try alloc.create(Ui);
        errdefer alloc.destroy(self);

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
        // What the context switcher and the shell's `jobs` call this one.
        // The starting file only: telling two editors apart is what it is
        // for, and following every buffer switch isn't needed for that.
        switch (target) {
            .file => |f| {
                var title_buf: [glyphwire.Context.max_title_len]u8 = undefined;
                const title = std.fmt.bufPrint(&title_buf, "zoe {s}", .{std.fs.path.basename(f)}) catch "zoe";
                try client.setContextTitle(title);
            },
            else => try client.setContextTitle("zoe"),
        }

        const size = try client.getSize();
        const metrics = try client.getCellMetrics();

        // Content sizes are provisional: every `layout` notification
        // resizes them to match the panes they landed in.
        const tree_layer = try client.createLayer(default_tree_cols, size.rows, 0);
        const tabs_layer = try client.createLayer(size.cols, 1, 0);
        const buffer_layer = try client.createLayer(size.cols, size.rows, 0);
        const status_layer = try client.createLayer(size.cols, 1, 0);

        // The tree is host-scrolled (both bars). The buffer is in
        // `client` scroll mode: it redraws its own visible rows, and a
        // `content_extent` (pushed each frame from the line count -- see
        // `syncBufferScrollbar`) lets the host draw a proportional
        // vertical bar and turn a wheel or thumb drag over the pane into
        // a `scroll_offset` zoe then follows.
        try client.setLayerScrollMode(buffer_layer, .client);
        try client.setLayerScrollMode(tabs_layer, .client);
        try client.setLayerScrollbars(tree_layer, true, true);
        try client.setLayerScrollbars(buffer_layer, true, false);
        // Each pane's resting colour, so a cell nothing has written yet
        // (a frame racing a resize, the columns past a short tab strip)
        // is the pane's colour rather than whatever is behind zoe.
        try client.setLayerBackground(tree_layer, bg_tree);
        try client.setLayerBackground(tabs_layer, bg_tab_bar);
        try client.setLayerBackground(buffer_layer, bg_buffer);
        try client.setLayerBackground(status_layer, bg_status);
        // The tab strip scrolls sideways but draws no bar of its own: it
        // is one row tall, and a horizontal bar under it would double its
        // height for a scrollbar nothing needs to see. It still reports a
        // `content_extent` (`syncTabScrollbar`), which is what makes the
        // host treat it as scrollable and route a shift+wheel over it
        // back as a `scroll_offset`.
        try client.setLayerScrollbars(tabs_layer, false, false);

        // The Ctrl+` shell panel. `gw-shell --embed` draws its prompt and
        // its commands' output here, so it carries scrollback of its own
        // for the shell's Ctrl+Up browsing. Created before the finder so
        // the popup still composites over it, and outside the split tree:
        // `Panel.place` puts it across the bottom when it opens.
        const shell_layer = try client.createLayer(size.cols, 1, shellpanel.scrollback_rows);
        try client.setLayerBackground(shell_layer, bg_shell);
        try client.setLayerScrollbars(shell_layer, true, false);
        // Output the user may want to copy: the host's drag-to-select,
        // which zoe's own drag handling would otherwise never allow here.
        try client.setLayerMouseSelect(shell_layer, true);
        try client.setLayerVisible(shell_layer, false);

        // The finder popup, created last so it composites over every
        // pane (creation order is the initial stacking -- see
        // `raise_layer` in docs/api.md). Neither layer joins the split
        // tree: the popup floats, so it is placed by cell position and
        // sized by `renderFinder`, and stays invisible until Ctrl+P.
        const finder_layer = try client.createLayer(finder_min_cols, finder_header_rows, 0);
        const finder_list_layer = try client.createLayer(finder_min_cols, 1, 0);
        // The hover popup, floating like the finder's layers and placed
        // against the cursor rather than the pane -- `hoverRect`.
        const hover_layer = try client.createLayer(hover_max_cols, 1, 0);
        try client.setLayerVisible(hover_layer, false);
        try client.setLayerBackground(hover_layer, bg_hover);
        try client.setLayerVisible(finder_layer, false);
        try client.setLayerVisible(finder_list_layer, false);
        try client.setLayerBackground(finder_layer, bg_finder);
        try client.setLayerBackground(finder_list_layer, bg_finder);
        // The list is sized to its visible rows and reports the match
        // count as its `content_extent`, so the host's bar is
        // proportional to the whole answer rather than to the dozen rows
        // on screen -- the arrangement gw-hist's result list uses.
        try client.setLayerScrollMode(finder_list_layer, .client);
        try client.setLayerScrollbars(finder_list_layer, true, false);

        // The tree|buffer split stays user-resizable. The two column
        // splits are not: what they stack above and below is a single
        // fixed row each -- the tab strip and the command line -- so a
        // drag handle on either is a wasted row.
        const pane_split = try client.createSplit(.row, true);
        const buffer_col_split = try client.createSplit(.column, false);
        const root_split = try client.createSplit(.column, false);

        self.* = .{
            .alloc = alloc,
            .io = io,
            .client = client,
            .listener = listener,
            .tree = try Tree.init(alloc, io, root_dir, .{}),
            // Set a few lines below, before anything can read it: the
            // first buffer builds its highlighter against the grammar
            // registry, which has to be at its final address in `self`
            // first (a `Highlighter` holds a pointer to it).
            .buf = undefined,
            .context = context,
            .tree_layer = tree_layer,
            .tabs_layer = tabs_layer,
            .buffer_layer = buffer_layer,
            .status_layer = status_layer,
            .finder_layer = finder_layer,
            .finder_list_layer = finder_list_layer,
            .hover_layer = hover_layer,
            .diags = diag.Store.init(alloc),
            .shell = shellpanel.Panel.init(alloc, io, client, context, shell_layer),
            .pane_split = pane_split,
            .buffer_col_split = buffer_col_split,
            .root_split = root_split,
            .cell_px_h = metrics.h,
            .environ = environ,
        };
        errdefer self.tree.deinit();

        // Best-effort: highlighting off is a valid state, never a reason
        // to fail bringing the editor up. Done before the first buffer,
        // which builds its own highlighter against what this leaves.
        self.loadConfig(environ);

        // After the config (which carries the server list) and before the
        // first buffer (which announces itself to whatever started).
        self.startLsp(root_dir, environ);


        const target_path: ?[]const u8 = switch (target) {
            .file => |p| p,
            .none, .directory => null,
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
        try self.buffers.append(alloc, first);
        self.buf = first;
        self.active = 0;

        // `zoe <dir>` names a place to work, not a file to open: the tree
        // is already rooted there (`root_dir` is the directory `main`
        // changed into), so start the focus on it -- picking something
        // out of it is the next thing that happens, and an empty scratch
        // buffer has nothing to look at.
        if (target == .directory) self.focus = .tree;

        try client.setSplitChildren(buffer_col_split, &.{
            // One row, whatever the window does -- same reasoning as the
            // statusline below.
            glyphwire.SplitChildInput.layerFixed(tabs_layer, 1),
            glyphwire.SplitChildInput.layerWeighted(buffer_layer, 1),
        });
        try self.applySplitChildren();
        try client.setSplitChildren(root_split, &.{
            glyphwire.SplitChildInput.splitWeighted(pane_split, 1),
            // The statusline is `fixed`, not a weight: one row is one row
            // whatever the window does.
            glyphwire.SplitChildInput.layerFixed(status_layer, 1),
        });
        try client.setRootSplit(root_split);

        // The `layout` broadcast goes to *other* connections, and the
        // listener is one -- but reading the bounds back directly avoids
        // a startup frame drawn against guesses.
        try self.readBounds();
        return self;
    }

    /// Loads `zoe.conf.lua` and resolves the grammar search path into a
    /// registry. Any failure leaves all of it null, and every buffer then
    /// renders unhighlighted -- each buffer's own `Highlighter` is built
    /// against this in `newSlot`.
    fn loadConfig(self: *Ui, environ: *const std.process.Environ.Map) void {
        var cfg = langconf.load(self.alloc, self.io, environ);

        const dirs = syntax.searchDirs(self.alloc, self.io, environ, cfg.grammar_dirs) catch {
            cfg.deinit();
            return;
        };

        self.hl_search_dirs = dirs;
        self.grammars = syntax.Registry.init(self.alloc, self.io, dirs, cfg.langs);
        self.hl_config = cfg;
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
        if (self.shell.isOpen()) {
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
            .normal, .visual, .visual_line => false,
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
    /// any job in it included.
    fn toggleShell(self: *Ui) void {
        if (self.shell.isOpen()) {
            self.shell.close();
            self.shellClosed();
            return;
        }
        self.shell.open(self.tree.root, self.winSize()) catch |err| {
            self.buf.ed.setStatus("can't start gw-shell: {t}", .{err});
            self.status_dirty = true;
            return;
        };
        // The shell takes the caret; what zoe last sent no longer stands.
        self.caret_host = null;
    }

    /// The panel went away -- Ctrl+` closed it, or its shell exited. Zoe
    /// has the host caret back and has to send it afresh. Nothing is
    /// repainted: the panel is a layer over the panes, and hiding it
    /// shows them exactly as they were.
    fn shellClosed(self: *Ui) void {
        self.caret_host = null;
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
        if (self.shell.isOpen()) return;
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
        if (!self.window_focused) return .box;
        if (self.buf.ed.mode == .insert) return .line;
        return null;
    }

    /// `shape` non-null hands the host the caret, on the buffer layer, in
    /// that shape; null takes it back for `renderBuffer` to draw.
    fn sendCaret(self: *Ui, shape: ?glyphwire.CaretShape) !void {
        if (shape) |s| {
            try self.client.setCaretLayer(self.buffer_layer);
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

            if (syntax.Highlighter.init(self.alloc, cfg.theme)) |h| {
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
        if (self.buffers.items.len > 0) {
            slot.ed.line_numbers = self.buf.ed.line_numbers;
            slot.ed.page_lines = self.buf.ed.page_lines;
            slot.ed.tab_width = self.buf.ed.tab_width;
            slot.ed.expand_tab = self.buf.ed.expand_tab;
            slot.ed.show_whitespace = self.buf.ed.show_whitespace;
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
        if (self.hover) |*h| h.deinit(self.alloc);
        self.jumps.deinit(self.alloc);
        self.client.destroyContext(self.context) catch {};
        self.tree.deinit();
        if (self.finder) |*f| f.deinit();
        if (self.find) |*f| f.deinit(self.alloc);
        if (self.prev_cwd) |p| self.alloc.free(p);

        // Every open buffer's text and parse tree, not just the visible
        // one -- that is the bargain multiple buffers made.
        for (self.buffers.items) |slot| slot.deinit(self.alloc);
        self.buffers.deinit(self.alloc);
        self.tab_spans.deinit(self.alloc);

        self.hl_scratch.deinit(self.alloc);
        self.hl_dirty_lines.deinit(self.alloc);
        self.hl_changed.deinit(self.alloc);
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
        if (self.tree_visible) {
            try self.client.setSplitChildren(self.pane_split, &.{
                glyphwire.SplitChildInput.layerFixed(self.tree_layer, default_tree_cols),
                glyphwire.SplitChildInput.splitWeighted(self.buffer_col_split, 1),
            });
        } else {
            try self.client.setSplitChildren(self.pane_split, &.{
                glyphwire.SplitChildInput.splitWeighted(self.buffer_col_split, 1),
            });
        }
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
        self.tabs_bounds = try self.boundsOf(self.tabs_layer);
        self.buffer_bounds = try self.boundsOf(self.buffer_layer);
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
        if (self.buffer_bounds.cols > 0) {
            try self.client.setLayerSize(self.buffer_layer, self.buffer_bounds.cols, self.buffer_bounds.rows);
        }
        if (self.status_bounds.cols > 0) {
            try self.client.setLayerSize(self.status_layer, self.status_bounds.cols, 1);
        }
        // The tab strip is client-scrolled the same way the buffer is:
        // its grid is exactly the pane, and a strip wider than that is
        // reported as a `content_extent` rather than drawn into cells
        // nothing shows.
        if (self.tabs_bounds.cols > 0) {
            try self.client.setLayerSize(self.tabs_layer, self.tabs_bounds.cols, 1);
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
        return @max(self.tree.len() + tree_trailing_rows, self.tree_scroll.row + self.tree_bounds.rows);
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
            if (self.buffer_dirty or self.tree_dirty != .none or self.tabs_dirty or
                self.status_dirty or self.finder_dirty or self.hover_dirty or
                self.tree_scroll_pending != null)
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
            self.armLspChange();
            const timeout: std.Io.Timeout = if (self.lsp_change_due) |due|
                .{ .deadline = due }
            else
                .none;
            const parsing = self.highlightPending();
            const next = if (parsing) self.listener.pollNext() else try self.listener.next(timeout);
            if (next) |first| {
                try self.handleEvent(first);
                while (!self.quit) {
                    const ev = self.listener.pollNext() orelse break;
                    try self.handleEvent(ev);
                }
            }
            if (parsing and !self.quit) self.stepHighlight();
            // A wake with nothing queued, or the deadline passing: either way
            // this is where the debounced change goes out.
            if (self.lspChangeDue()) self.lspFlushChange();
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
                if (l.boundsFor(self.tabs_layer)) |b| self.tabs_bounds = toBounds(b);
                if (l.boundsFor(self.buffer_layer)) |b| self.buffer_bounds = toBounds(b);
                if (l.boundsFor(self.status_layer)) |b| self.status_bounds = toBounds(b);
                try self.syncContentSizes();
                // The buffer layer's grid was resized: the rows it holds no
                // longer line up with the panes, so the next frame can't
                // shift them -- it has to repaint. Every pane moved.
                self.buf.full_redraw = true;
                self.buffer_dirty = true;
                self.markTreeDirty(.full);
                self.tabs_dirty = true;
                self.status_dirty = true;
                // The popup is outside the split tree, so this
                // notification never mentions it -- but it is placed
                // against the buffer pane, which just moved.
                self.finder_dirty = self.finder != null;
                self.replaceShell();
            },
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
                self.buf.full_redraw = true;
                self.buffer_dirty = true;
                self.markTreeDirty(.full);
                self.tabs_dirty = true;
                self.status_dirty = true;
                self.finder_dirty = self.finder != null;
                self.replaceShell();
            },
            .scroll_offset => |so| {
                // A wheel or thumb drag over the finder popup: follow it
                // without moving the cursor, the way gw-hist's list does
                // -- scrolling past a row and picking it are two
                // different gestures.
                if (so.layer == self.finder_list_layer) {
                    if (self.finder) |*f| {
                        f.scrollTo(so.row, self.finder_list_rows);
                        self.finder_dirty = true;
                    }
                }
                if (so.layer == self.tree_layer) self.tree_scroll = .{ .row = so.row, .col = so.col };
                // A wheel or thumb drag over the buffer pane: the host moved
                // the virtual offset and told us where. Follow it, and drag
                // the cursor along so it stays on screen (like vim's Ctrl-E /
                // Ctrl-Y). `pushed_bar` is updated so `syncBufferScrollbar`
                // doesn't immediately echo this straight back.
                if (so.layer == self.buffer_layer) self.scrollBufferTo(so.row, so.col);
                // A shift+wheel or thumb drag over the tab strip. Only the
                // column matters -- the strip is one row tall -- and the
                // offset is recorded as already pushed so `syncTabScrollbar`
                // doesn't echo it straight back.
                if (so.layer == self.tabs_layer and so.col != self.tab_scroll) {
                    self.tab_scroll = so.col;
                    self.pushed_tab_bar[1] = so.col;
                    self.tabs_dirty = true;
                }
            },
            // The pointer belongs to the shell panel too while it is up:
            // a click on its output is the host's selection, not a move
            // of the buffer cursor underneath.
            // The window came back or went away. Who draws the cursor
            // changes with it (`caretShape`), so the row it sits on has
            // to be repainted -- zoe's own inverted cell has to come off
            // before the host's box goes on, and back on afterwards.
            .focus => |f| {
                if (f.focused == self.window_focused) return;
                self.window_focused = f.focused;
                self.buf.full_redraw = true;
                self.buffer_dirty = true;
            },
            .mouse_move => |m| if (!self.shell.isOpen()) try self.handleMouseDrag(m),
            // `defer ev.deinit` above frees the button string.
            .mouse_button => |m| if (!self.shell.isOpen()) try self.handleMouseButton(m),
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

        switch (ev) {
            .key => |k| {
                // Every physical keystroke is two notifications, a press
                // and a release (see `KeyInput.reportKeyEvents`); acting
                // on both doubles every named-key command (arrows moved
                // two cells, a single Backspace deleted two characters,
                // ...). Only the press edge is a command -- a release
                // carries no motion/edit of its own.
                if (!k.pressed) return;

                // With the shell panel up the keyboard is the shell's:
                // both programs are sent every keystroke (one context,
                // one input stream), so the only one taken here is the
                // key that closes it.
                if (self.shell.isOpen()) {
                    if (k.ctrl() and std.mem.eql(u8, k.key, "grave_accent")) self.toggleShell();
                    return;
                }

                // The Ctrl+P popup is modal: while it is open it is the
                // only thing reading keys, so nothing below here runs.
                if (self.finder != null) {
                    try self.finderKey(k);
                    return;
                }

                // A leftover status/error message (`:q` on a dirty
                // buffer, an unknown command, ...) would otherwise sit in
                // the statusline forever -- nothing else ever clears it,
                // so it permanently hides the mode indicator underneath.
                // Vim clears it on the next keystroke; this is that.
                self.buf.ed.status.clearRetainingCapacity();

                // Ctrl+w switches panes, Ctrl+n toggles the sidebar --
                // taken before the editor sees them so they work in any
                // mode. The modifiers come off the event itself, as they
                // were when the host generated it: asking the live
                // down-set here would read a quick Ctrl+W as a plain `w`
                // whenever a heavy redraw left this loop behind.
                const ctrl = k.ctrl();
                // The hover popup is transient chrome, not a mode: the next
                // keystroke dismisses it and then does whatever it was going
                // to do. Escape is the exception -- it only dismisses, so
                // it doesn't also leave insert mode on the way out.
                if (self.hover != null) {
                    _ = self.closeHover();
                    if (std.mem.eql(u8, k.key, "escape")) return;
                }
                if (ctrl) {
                    if (std.mem.eql(u8, k.key, "w")) {
                        self.setFocus(if (self.focus == .buffer) .tree else .buffer);
                        return;
                    }
                    // Ctrl+O / Ctrl+I walk the jumplist -- vim's chords, and
                    // the way back from a `gd` that opened another file.
                    if (self.focus == .buffer and std.mem.eql(u8, k.key, "o")) {
                        self.jumpStep(true);
                        return;
                    }
                    if (self.focus == .buffer and std.mem.eql(u8, k.key, "i")) {
                        self.jumpStep(false);
                        return;
                    }
                    // Ctrl + a direction moves focus that way rather than
                    // cycling, so it keeps meaning the same thing once
                    // there is more than one buffer pane to move between.
                    // The vertical pair is claimed now and does nothing
                    // yet -- there is nothing above or below either pane.
                    if (focusDirection(k.key)) |dir| {
                        switch (dir) {
                            .left => if (self.tree_visible) self.setFocus(.tree),
                            .right => self.setFocus(.buffer),
                            .up, .down => {},
                        }
                        return;
                    }
                    if (std.mem.eql(u8, k.key, "n")) {
                        try self.toggleTree();
                        return;
                    }
                    // Ctrl+` opens the shell panel, in every mode. (The
                    // finder above is modal, so it never gets here.)
                    if (std.mem.eql(u8, k.key, "grave_accent")) {
                        self.toggleShell();
                        return;
                    }
                    // Ctrl+H shows or hides dotfiles and everything
                    // `.gitignore` excludes, in one flag -- the sidebar,
                    // both tree searches and Ctrl+P alike. Taken here so
                    // it works from either pane: which files exist is a
                    // session-wide question, not a sidebar-local one.
                    if (std.mem.eql(u8, k.key, "h")) {
                        try self.toggleHidden();
                        return;
                    }
                    // Ctrl+P opens the file finder, in every mode -- the
                    // chord every editor with one uses. Insert mode
                    // included: zoe has no keyword completion for the
                    // vim meaning of Ctrl+P to collide with.
                    if (std.mem.eql(u8, k.key, "p") and !k.shift()) {
                        try self.openFinder();
                        return;
                    }
                    // Ctrl+Tab / Ctrl+Shift+Tab walk the tab strip, the
                    // chord every tabbed application uses. Taken here so
                    // they work in insert mode too, where a bare Tab is
                    // still a Tab.
                    if (std.mem.eql(u8, k.key, "tab")) {
                        self.stepBuffer(!k.shift());
                        return;
                    }
                    // Ctrl+Shift+X cut and Ctrl+Shift+P paste, both
                    // through the system clipboard. (Ctrl+Shift+C is
                    // swallowed by glyphwire-host, which broadcasts a
                    // `copy_request` instead -- see the `.copy_request`
                    // arm.)
                    if (k.shift() and self.focus == .buffer) {
                        if (std.mem.eql(u8, k.key, "x")) {
                            try self.applyOutcome(try self.buf.ed.clipboardCut());
                            self.buf.full_redraw = true;
                            self.buffer_dirty = true;
                            self.status_dirty = true;
                            return;
                        }
                        if (std.mem.eql(u8, k.key, "p")) {
                            try self.pasteFromClipboard(true);
                            return;
                        }
                    }
                }
                if (self.focus == .tree) {
                    try self.treeKey(k);
                    self.status_dirty = true;
                    return;
                }
                try self.applyOutcome(try self.buf.ed.feedKey(k.key, .{ .ctrl = ctrl }));
            },
            .text => |t| {
                // Typed text is the shell's while its panel is up -- it
                // has a line editor of its own.
                if (self.shell.isOpen()) return;
                if (self.finder != null) {
                    try self.finderText(t.text);
                    return;
                }
                self.buf.ed.status.clearRetainingCapacity();
                if (self.focus == .tree) {
                    try self.treeText(t.text);
                    self.status_dirty = true;
                    return;
                }
                try self.applyOutcome(try self.buf.ed.feedText(t.text));
            },
            .paste => |t| {
                if (self.shell.isOpen()) return;
                if (self.finder != null) {
                    try self.finderText(t.text);
                    return;
                }
                self.buf.ed.status.clearRetainingCapacity();
                if (self.focus == .buffer) {
                    // Insert mode and the two typed lines (`:` and `/`)
                    // all want the text *typed*, which is what `feedText`
                    // does for them -- a pasted search pattern belongs on
                    // the prompt, not in the buffer.
                    const typed = switch (self.buf.ed.mode) {
                        .insert, .command, .search => true,
                        .normal, .visual, .visual_line => false,
                    };
                    if (typed) {
                        try self.applyOutcome(try self.buf.ed.feedText(t.text));
                    } else {
                        // Normal / visual mode: splice the pasted text in
                        // like `p`, replacing any selection first, rather
                        // than obeying each character as a command.
                        try self.buf.ed.dropSelection();
                        try self.buf.ed.putText(t.text, true);
                        self.buf.full_redraw = true;
                        self.buffer_dirty = true;
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
            .copy_request => if (self.isVisible() and !self.shell.isOpen()) {
                try self.applyOutcome(try self.buf.ed.clipboardCopy());
                self.buffer_dirty = true;
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
        if (!after.eql(before)) self.buffer_dirty = true;
        // The tab's `+` marker is the only thing the strip draws that a
        // keystroke can change.
        if (after.dirty != before.dirty) self.tabs_dirty = true;
        // A `:set` moves the text origin or the width of a glyph, which a
        // row shift can't express -- the whole pane has to be
        // re-laid-out. These settings live on the `Editor`, and there is
        // one per buffer, so each is pushed to all of them: `:set` reads
        // as a session-wide switch, not a per-tab one.
        if (after.line_numbers != before.line_numbers or
            after.tab_width != before.tab_width or
            after.expand_tab != before.expand_tab or
            after.show_whitespace != before.show_whitespace)
        {
            self.buf.full_redraw = true;
            for (self.buffers.items) |slot| {
                slot.ed.line_numbers = after.line_numbers;
                slot.ed.tab_width = after.tab_width;
                slot.ed.expand_tab = after.expand_tab;
                slot.ed.show_whitespace = after.show_whitespace;
                slot.full_redraw = true;
            }
        }
        // A visual selection touches whole rows, not just the caret's:
        // any change to the anchor or the mode (entering/leaving visual,
        // or a motion that grew the selection over rows the caret didn't
        // land on) needs the pane repainted so the highlight follows.
        if (after.mode != before.mode or after.anchor != before.anchor or
            (after.mode == .visual or after.mode == .visual_line))
        {
            self.buf.full_redraw = true;
        }
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
        if (to != .tree) self.cancelFind();
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
        self.buffer_dirty = true;
        self.markTreeDirty(.full);
        self.tabs_dirty = true;
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
        const rows = self.tree_bounds.rows;
        if (rows == 0) return;
        const top = treeScrollTop(self.tree.cursor, self.tree_scroll.row, rows, self.tree.len());
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
        if (scope == .deep) find.deep = try tree_mod.deepList(self.alloc, self.io, self.tree.root, self.tree.visible);
        self.find = find;
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
                const rel = f.deep.?.paths.items[hit];
                const index = (try self.tree.reveal(self.io, rel)) orelse return;
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
        if (!std.mem.eql(u8, ev.button, "left")) return;

        // While the finder is up it owns the pointer too -- see
        // `finderClick`. The release that follows lands here with the
        // popup already closed and nothing dragging, so it does nothing.
        if (self.finder != null) {
            if (ev.pressed) try self.finderClick(ev.cell);
            return;
        }

        if (ev.pressed) {
            if (self.tabAt(ev.cell)) |h| {
                if (h.close) {
                    try self.closeBuffer(h.index, false);
                } else {
                    self.setActive(h.index);
                }
                return;
            }
            if (self.cellInBuffer(ev.cell)) |byte| {
                self.drag = .{ .anchor = byte, .moved = false };
                if (self.buf.ed.mode == .visual or self.buf.ed.mode == .visual_line) self.buf.ed.exitVisual();
                self.buf.ed.moveCursorTo(byte);
                self.focus = .buffer;
                self.buf.full_redraw = true;
                self.buffer_dirty = true;
                self.status_dirty = true;
            } else {
                try self.handleTreeClick(ev);
            }
            return;
        }

        // Released.
        if (self.drag) |d| {
            self.drag = null;
            // A plain click (no drag): make sure no selection lingers.
            if (!d.moved and (self.buf.ed.mode == .visual or self.buf.ed.mode == .visual_line)) {
                self.buf.ed.exitVisual();
            }
            self.buf.full_redraw = true;
            self.buffer_dirty = true;
            self.status_dirty = true;
        }
    }

    /// A pointer move with the left button down: extend the buffer-pane
    /// selection to the cell under the pointer, entering visual mode on
    /// the first real move.
    fn handleMouseDrag(self: *Ui, ev: glyphwire.MouseMoveEvent) !void {
        if (self.drag) |*d| {
            const byte = self.cellToBufferByte(ev.cell);
            if (!d.moved) {
                if (byte == d.anchor) return;
                d.moved = true;
            }
            self.buf.ed.setVisualSelection(d.anchor, byte);
            self.buf.full_redraw = true;
            self.buffer_dirty = true;
            self.status_dirty = true;
        }
    }

    /// The tab under a root-grid cell, or null when the cell isn't in
    /// the strip. Screen columns are strip columns less the scroll, so
    /// the spans `renderTabs` recorded answer this directly.
    fn tabAt(self: *Ui, cell: glyphwire.CellPos) ?tabs.Hit {
        const b = self.tabs_bounds;
        if (b.cols == 0 or b.rows == 0) return null;
        if (cell.row < b.row or cell.row >= b.row + b.rows) return null;
        if (cell.col < b.col or cell.col >= b.col + b.cols) return null;
        return tabs.hit(self.tab_spans.items, cell.col - b.col + self.tab_scroll);
    }

    /// The buffer byte offset under grid cell `cell`, or null if the
    /// cell isn't inside the buffer pane -- the test a press uses to
    /// decide between a buffer drag and a tree click.
    fn cellInBuffer(self: *Ui, cell: glyphwire.CellPos) ?usize {
        const b = self.buffer_bounds;
        if (b.cols == 0 or b.rows == 0) return null;
        if (cell.row < b.row or cell.row >= b.row + b.rows) return null;
        if (cell.col < b.col or cell.col >= b.col + b.cols) return null;
        return self.cellToBufferByte(cell);
    }

    /// The buffer byte offset under grid cell `cell`, clamping the cell
    /// into the buffer pane first so a drag that wanders out of the pane
    /// still tracks its nearest edge.
    fn cellToBufferByte(self: *Ui, cell: glyphwire.CellPos) usize {
        const b = self.buffer_bounds;
        const rows = @max(b.rows, 1);
        const screen_row = std.math.clamp(cell.row, b.row, b.row + rows - 1) - b.row;
        const line = @min(self.buf.top_line + screen_row, self.buf.ed.buf.lineCount() - 1);

        const text_left = b.col + self.gutterWidth();
        const rel_col = if (cell.col > text_left) cell.col - text_left else 0;
        const dcol = self.buf.left_col + rel_col;

        const line_text = self.buf.ed.buf.lineText(self.alloc, line) catch
            return self.buf.ed.buf.lineStart(line);
        defer self.alloc.free(line_text);
        return self.buf.ed.buf.lineStart(line) +
            display.byteAtCol(line_text, dcol, self.displayOpts());
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

    // ── Editor outcomes ─────────────────────────────────────────────────

    fn applyOutcome(self: *Ui, outcome: editor.Outcome) !void {
        switch (outcome) {
            .none => {},
            .write => |target| self.save(target),
            .write_quit => |target| {
                self.save(target);
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
                if (target) |t| try self.openFile(t) else try self.reloadCurrent();
            },
            .buffer_step => |b| self.stepBuffer(b.forward),
            .buffer_close => |b| try self.closeBuffer(self.active, b.force),
            .chdir => |target| self.changeDir(target),
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
        self.buffer_dirty = true;
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
            if (std.mem.eql(u8, t, "~") or std.mem.startsWith(u8, t, "~/")) {
                const h = self.environ.get("HOME") orelse break :blk t;
                const rest = if (t.len > 1) t[2..] else "";
                break :blk std.fmt.bufPrint(&home_buf, "{s}/{s}", .{ h, rest }) catch t;
            }
            break :blk t;
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

        // Re-root the tree at the resolved absolute cwd.
        var new_buf: [std.fs.max_path_bytes]u8 = undefined;
        const new_n = std.process.currentPath(self.io, &new_buf) catch 0;
        const new_root = if (new_n > 0) new_buf[0..new_n] else dest;

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

    // ── Finder ──────────────────────────────────────────────────────────

    /// Ctrl+P. Walks the tree root and opens the popup over the buffer
    /// pane. The walk happens here, on every open, rather than being kept
    /// up to date in the background -- see finder.zig.
    fn openFinder(self: *Ui) !void {
        if (self.finder) |*f| f.deinit();
        // The popup is modal, so a tree search underneath it would have
        // the statusline to itself with no way left to type into it.
        self.cancelFind();
        self.finder = Finder.init(self.alloc, self.io, self.tree.root, self.tree.visible) catch |err| {
            self.finder = null;
            self.buf.ed.setStatus("E484: Can't scan {s}: {s}", .{ self.tree.root, @errorName(err) });
            self.status_dirty = true;
            return;
        };
        self.finder_dirty = true;
    }

    fn closeFinder(self: *Ui) void {
        if (self.finder) |*f| f.deinit();
        self.finder = null;
        self.client.setLayerVisible(self.finder_layer, false) catch {};
        self.client.setLayerVisible(self.finder_list_layer, false) catch {};
    }

    /// Opens whatever the popup is on and closes it. A file that isn't
    /// text is refused by `openFile` the same way it would be from the
    /// tree -- the popup still closes, and the error lands in the
    /// statusline behind it.
    fn acceptFinder(self: *Ui) !void {
        const f = if (self.finder) |*open| open else return;
        const path = try f.selectedPath(self.alloc);
        self.closeFinder();
        const p = path orelse return;
        defer self.alloc.free(p);
        try self.openFile(p);
        self.setFocus(.buffer);
    }

    /// A keystroke while the popup is open. It takes every key it knows
    /// and swallows the rest: the popup is modal, and letting a stray
    /// chord through to the buffer underneath -- which you cannot see
    /// well enough to check -- is worse than it doing nothing.
    fn finderKey(self: *Ui, k: glyphwire.KeyEvent) !void {
        const f = if (self.finder) |*open| open else return;
        const eq = std.mem.eql;
        const ctrl = k.ctrl();
        const rows = @max(self.finder_list_rows, 1);

        if (eq(u8, k.key, "escape") or (ctrl and eq(u8, k.key, "c"))) {
            self.closeFinder();
            return;
        }
        if (eq(u8, k.key, "enter") or eq(u8, k.key, "kp_enter")) {
            try self.acceptFinder();
            return;
        }

        // Moving the cursor is tested before the field gets the key:
        // Ctrl+N / Ctrl+P are the vertical pair (Ctrl+K is the field's
        // own kill-to-end, so the vim-ish Ctrl+J / Ctrl+K can't be), and
        // a page is however many rows the popup ended up with.
        const step: ?isize = if (eq(u8, k.key, "up") or (ctrl and eq(u8, k.key, "p")))
            -1
        else if (eq(u8, k.key, "down") or (ctrl and eq(u8, k.key, "n")))
            1
        else if (eq(u8, k.key, "page_up"))
            -@as(isize, @intCast(rows))
        else if (eq(u8, k.key, "page_down"))
            @as(isize, @intCast(rows))
        else
            null;
        if (step) |d| {
            f.moveCursor(d);
            f.follow(rows);
            self.finder_dirty = true;
            return;
        }

        // Everything else is the query field's: backspace, the word
        // deletes, Ctrl+U, the caret motions. Enter and Escape never
        // reach it -- they are answered above.
        switch (f.query.handleKey(k.key, k.mods)) {
            .edited => {
                try f.refilter();
                f.follow(rows);
                self.finder_dirty = true;
            },
            .moved => self.finder_dirty = true,
            .ignored, .submit, .cancel => {},
        }
    }

    /// Typed characters (and a paste) while the popup is open: the query,
    /// never the buffer.
    fn finderText(self: *Ui, text: []const u8) !void {
        const f = if (self.finder) |*open| open else return;
        if (try f.query.insert(self.alloc, text)) {
            try f.refilter();
            f.follow(@max(self.finder_list_rows, 1));
            self.finder_dirty = true;
        }
    }

    /// A left click while the popup is open: a list row picks that file,
    /// anywhere else dismisses it. The click is swallowed either way --
    /// a modal popup whose buffer moves its cursor behind it is a trap.
    fn finderClick(self: *Ui, cell: glyphwire.CellPos) !void {
        const f = if (self.finder) |*open| open else return;
        const r = self.finder_rect;
        const inside = cell.row >= r.row and cell.row < r.row + r.rows and
            cell.col >= r.col and cell.col < r.col + r.cols;
        if (!inside) {
            self.closeFinder();
            return;
        }

        const list_row0 = r.row + finder_header_rows;
        if (cell.row < list_row0) return; // The title bar or the query line.
        const row = f.top + (cell.row - list_row0);
        if (row >= f.matchCount()) return;
        f.cursor = row;
        try self.acceptFinder();
    }

    /// Where the popup goes: centred over the buffer pane, at its
    /// preferred size or as much of it as the pane can hold. Recomputed
    /// per frame rather than cached, so a resize or a divider drag moves
    /// it with the pane without any bookkeeping of its own -- the popup
    /// is outside the split tree, so nothing else would tell it.
    fn finderRect(self: *const Ui) Bounds {
        const b = self.buffer_bounds;
        // Never bigger than the pane, and never below the minimum unless
        // the pane itself is smaller than that -- in which case the popup
        // is the pane, which at least stays readable.
        const cols = @min(@max(finder_min_cols, @min(finder_max_cols, b.cols -| 4)), b.cols);
        const rows = @min(@max(finder_min_rows, @min(finder_max_rows, b.rows -| 2)), b.rows);
        return .{
            .row = b.row + (b.rows -| rows) / 2,
            .col = b.col + (b.cols -| cols) / 2,
            .cols = cols,
            .rows = rows,
        };
    }

    fn renderFinder(self: *Ui, batch: *glyphwire.client.Client.Batch) !void {
        const f = if (self.finder) |*open| open else return;
        const r = self.finderRect();
        self.finder_rect = r;

        // A pane with no room for a title bar, a query line and a row of
        // results: draw nothing rather than something unreadable. The
        // finder stays open, so widening the window brings it back.
        if (r.cols == 0 or r.rows <= finder_header_rows) {
            self.finder_list_rows = 0;
            try batch.setLayerVisible(self.finder_layer, false);
            try batch.setLayerVisible(self.finder_list_layer, false);
            return;
        }

        const list_rows = r.rows - finder_header_rows;
        self.finder_list_rows = list_rows;
        // Clamped, not `follow`ed: the view is dragged onto the cursor by
        // whatever moved the cursor. Doing it here as well would undo a
        // wheel scroll on the very frame it was drawn.
        f.clampScroll(list_rows);

        try batch.setLayerSize(self.finder_layer, r.cols, finder_header_rows);
        try batch.setLayerCellPosition(self.finder_layer, r.row, r.col);
        try batch.setLayerSize(self.finder_list_layer, r.cols, list_rows);
        try batch.setLayerCellPosition(self.finder_list_layer, r.row + finder_header_rows, r.col);

        try self.renderFinderHeader(batch, f, r.cols);
        try self.renderFinderList(batch, f, r.cols, list_rows);

        // The list layer is exactly its visible rows; the host is told
        // the real total so its scrollbar is proportional to the whole
        // answer and a wheel over the popup comes back as a
        // `scroll_offset` (the `.client` scroll mode set in `init`).
        try batch.setLayerContentExtent(self.finder_list_layer, r.cols, f.matchCount());
        try batch.setLayerScrollOffset(self.finder_list_layer, f.top, 0);

        try batch.setLayerVisible(self.finder_layer, true);
        try batch.setLayerVisible(self.finder_list_layer, true);
    }

    /// The title bar and the query line under it.
    fn renderFinderHeader(
        self: *Ui,
        batch: *glyphwire.client.Client.Batch,
        f: *const Finder,
        cols: usize,
    ) !void {
        var title: std.ArrayList(u8) = .empty;
        defer title.deinit(self.alloc);
        try title.print(self.alloc, " Find file{s}", .{if (f.truncated) " (partial)" else ""});
        // The count, right-aligned, so the title beside it never shifts
        // as you type -- the same reasoning as the statusline's position.
        var right: [48]u8 = undefined;
        const tail = std.fmt.bufPrint(&right, "{d}/{d} ", .{
            if (f.matchCount() == 0) 0 else f.cursor + 1,
            f.matchCount(),
        }) catch "";
        const used = glyphwire.stringWidth(title.items) + glyphwire.stringWidth(tail);
        if (used < cols) try title.appendNTimes(self.alloc, ' ', cols - used);
        try title.appendSlice(self.alloc, tail);
        try batch.writeTextOpts(title.items, .{
            .layer = self.finder_layer,
            .row = 0,
            .col = 0,
            .fg = fg_finder_header,
            .bg = bg_finder_header,
            .max_cols = cols,
            .pad = true,
        });

        // The query, behind a `> ` prompt. The caret is drawn rather than
        // asked for: a text layer's cursor property is the next *write*
        // position, not a visual marker (same as the `:` line).
        const prompt = "> ";
        try batch.writeTextOpts(prompt, .{
            .layer = self.finder_layer,
            .row = 1,
            .col = 0,
            .fg = fg_dim,
            .bg = bg_finder,
        });
        const field_cols = cols -| prompt.len;
        try batch.writeTextOpts(f.query.text(), .{
            .layer = self.finder_layer,
            .row = 1,
            .col = prompt.len,
            .fg = fg_text,
            .bg = bg_finder,
            .max_cols = field_cols,
            .pad = true,
        });
        const caret_col = prompt.len + f.query.caretCol();
        if (caret_col < cols) {
            const q = f.query.text();
            const under = if (f.query.caret < q.len)
                q[f.query.caret..lineedit.nextBoundary(q, f.query.caret)]
            else
                " ";
            try batch.writeTextOpts(under, .{
                .layer = self.finder_layer,
                .row = 1,
                .col = caret_col,
                .fg = bg_finder,
                .bg = fg_text,
            });
        }
    }

    /// The visible slice of the answer, one path per row.
    fn renderFinderList(
        self: *Ui,
        batch: *glyphwire.client.Client.Batch,
        f: *const Finder,
        cols: usize,
        rows: usize,
    ) !void {
        try batch.clearArea(.{ .layer = self.finder_list_layer, .bg = bg_finder });

        if (f.matchCount() == 0) {
            try batch.writeTextOpts("  No matching files", .{
                .layer = self.finder_list_layer,
                .row = 0,
                .col = 0,
                .fg = fg_dim,
                .bg = bg_finder,
                .max_cols = cols,
            });
            return;
        }

        var i: usize = 0;
        while (i < rows) : (i += 1) {
            const path = f.matchAt(f.top + i) orelse break;
            const selected = f.top + i == f.cursor;
            const bg = if (selected) bg_finder_selected else bg_finder;
            // The directory part is dimmed and the filename isn't: what
            // you are looking for is nearly always the name, and the
            // directories are there to tell two of them apart.
            const split = if (std.mem.lastIndexOfScalar(u8, path, '/')) |at| at + 1 else 0;
            const dir_fg = if (selected) fg_finder_selected else fg_dim;
            const name_fg = if (selected) fg_finder_selected else fg_text;
            try batch.writeSpans(&.{
                .{ .text = " " },
                .{ .text = path[0..split], .fg = dir_fg },
                .{ .text = path[split..], .fg = name_fg },
            }, .{
                .layer = self.finder_list_layer,
                .row = i,
                .col = 0,
                .fg = name_fg,
                .bg = bg,
                .max_cols = cols,
                .pad = true,
            });
        }
    }

    // ── Buffers ─────────────────────────────────────────────────────────

    /// Opens `path` in a new tab, or switches to it when it is already
    /// open -- both `:e` and Enter on a file in the tree land here. The
    /// buffer being left keeps its text, its cursor and its parse tree,
    /// so coming back to it is a switch rather than a reload.
    fn openFile(self: *Ui, path: []const u8) !void {
        if (self.indexOfPath(path)) |i| {
            self.setActive(i);
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
        try self.buffers.insert(self.alloc, self.active + 1, slot);
        self.setActive(self.active + 1);
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
        self.selectHighlightLanguage(self.buf, self.buf.ed.path);
        // Wholly different contents: the servers' copy is stale in a way the
        // edit watermark can't express, so force the next flush to send.
        self.buf.lsp_sent_edits = self.buf.ed.buf.edits -% 1;
        self.buf.top_line = 0;
        self.buf.left_col = 0;
        // Fresh contents -- nothing on screen carries over.
        self.buf.full_redraw = true;
        self.buf.ed.setStatus("\"{s}\" {d}L", .{ self.buf.ed.path.?, self.buf.ed.buf.lineCount() });
        self.buffer_dirty = true;
        self.tabs_dirty = true;
        self.status_dirty = true;
    }

    /// Whether `:q` / `:wq` has to be refused because some *other* tab
    /// holds unsaved changes, reporting the first one it finds. An
    /// `Editor` only knows its own modified flag, and `:q` takes the
    /// whole editor down with every buffer in it, so this guard can only
    /// live here. `:q!` skips it, the way `!` always does.
    fn refuseQuitForDirtyBuffer(self: *Ui) bool {
        for (self.buffers.items) |slot| {
            if (!slot.ed.buf.dirty) continue;
            self.buf.ed.setStatus(
                "E162: No write since last change for buffer \"{s}\"",
                .{slot.ed.path orelse "[No Name]"},
            );
            self.status_dirty = true;
            return true;
        }
        return false;
    }

    /// The tab holding `path`, if one is open. Paths are compared as
    /// they were given, so `:e ./x.zig` and `:e x.zig` are two tabs --
    /// resolving them would mean touching the filesystem for what is a
    /// convenience. The tree is self-consistent, so clicking the same
    /// entry twice always finds the tab it opened.
    fn indexOfPath(self: *Ui, path: []const u8) ?usize {
        for (self.buffers.items, 0..) |slot, i| {
            const p = slot.ed.path orelse continue;
            if (std.mem.eql(u8, p, path)) return i;
        }
        return null;
    }

    /// Makes tab `index` the one being edited -- the only writer of the
    /// `active` / `buf` pair. Focus is left alone: opening a file from
    /// the tree shouldn't yank the keyboard out of the tree.
    fn setActive(self: *Ui, index: usize) void {
        self.active = @min(index, self.buffers.items.len - 1);
        self.buf = self.buffers.items[self.active];
        // The buffer layer's cells belong to whichever buffer drew last,
        // and its scrollbar to that buffer's line count. Neither carries
        // over, so the incoming buffer repaints and re-pushes its extent.
        self.buf.full_redraw = true;
        self.buf.pushed_bar = .{ std.math.maxInt(usize), 0, 0, 0 };
        self.buffer_dirty = true;
        self.tabs_dirty = true;
        self.status_dirty = true;
    }

    /// `:bn` / `:bp`, and Ctrl+Tab / Ctrl+Shift+Tab. Wraps at both ends,
    /// so two buffers can be flipped between with one chord.
    fn stepBuffer(self: *Ui, forward: bool) void {
        const n = self.buffers.items.len;
        if (n < 2) return;
        self.setActive(if (forward) (self.active + 1) % n else (self.active + n - 1) % n);
    }

    /// Closes tab `index`. A modified buffer refuses unless `force`, the
    /// same E37 guard `:q` uses and what the tab's `×` reports when it
    /// can't close. Closing the last buffer leaves an empty scratch one:
    /// `buf` always points somewhere, and the strip always has a tab.
    fn closeBuffer(self: *Ui, index: usize, force: bool) !void {
        if (index >= self.buffers.items.len) return;
        const slot = self.buffers.items[index];
        if (slot.ed.buf.dirty and !force) {
            self.buf.ed.setStatus("E37: No write since last change (add ! to override)", .{});
            self.status_dirty = true;
            return;
        }

        // While the slot still exists: `didClose` needs its path, and the
        // stored diagnostics go with it.
        self.lspDidClose(slot);

        const closed_active = index == self.active;
        _ = self.buffers.orderedRemove(index);
        slot.deinit(self.alloc);

        if (self.buffers.items.len == 0) {
            const fresh = try self.newSlot(null);
            errdefer fresh.deinit(self.alloc);
            try self.buffers.append(self.alloc, fresh);
        }

        // Closing the active tab focuses whatever slid into its place
        // (or the new last tab); closing one to its left just shifts its
        // index down.
        const target = if (closed_active)
            @min(index, self.buffers.items.len - 1)
        else if (self.active > index)
            self.active - 1
        else
            self.active;
        self.setActive(target);
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
            // The buffer is a different file now, so the cached absolute
            // path and whatever the servers were told about the old name
            // both stop being true.
            self.invalidateAbs(self.buf);
            self.buf.lsp_opened = false;
        }
        self.buf.ed.markSaved();
        self.lspDidSave();
        // The tab loses its `+`, and a `:w <name>` also renamed it.
        self.tabs_dirty = true;
        self.buf.ed.setStatus("\"{s}\" {d}L written", .{ dest, self.buf.ed.buf.lineCount() });
    }

    // ── Language servers ────────────────────────────────────────────────
    //
    // See `docs/investigations/zoe-lsp.md`. The short version: `zoe/lsp.zig`
    // owns the processes and the protocol, `zoe/diag.zig` owns what they
    // said, and everything here is the editor's half -- when to tell them
    // about a buffer, what to do with an answer, and how a diagnostic gets
    // onto the screen.

    /// Starts the configured servers, if any. Best-effort in every
    /// direction: LSP is not part of the editor's correctness, so a server
    /// that isn't installed, won't spawn or won't answer leaves zoe exactly
    /// as it was without one.
    fn startLsp(self: *Ui, root_dir: []const u8, environ: *const std.process.Environ.Map) void {
        lsp.debug = environ.get("GLYPHWIRE_LSP_DEBUG") != null;
        const cfg = self.hl_config orelse {
            // No config means no server list, and also no grammar registry --
            // so this is the same failure that turns highlighting off.
            std.log.warn("zoe: no config loaded; language servers are off", .{});
            return;
        };
        if (!cfg.lsp_enabled) return;

        var pool = lsp.Pool.init(self.alloc, self.io, lsp.Waker.fromListener(self.listener), root_dir) catch return;
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
        while (pool.nextEvent() catch null) |ev| {
            defer ev.deinit(self.alloc);
            switch (ev) {
                .diagnostics => |d| self.applyDiagnostics(d.path, d.server, d.items),
                .hover => |h| self.applyHover(h.request_id, h.text),
                .definition => |d| self.applyDefinition(d.request_id, d.target),
                .died => |d| {
                    // Its marks will never be refreshed again, so they go
                    // rather than growing stale on screen.
                    self.diags.clearServer(d.server);
                    self.buf.ed.setStatus("LSP: {s} exited (:lsp restart)", .{d.server});
                    self.status_dirty = true;
                    self.buf.full_redraw = true;
                    self.buffer_dirty = true;
                },
            }
        }
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
        if (slot != null and slot.? == self.buf) {
            self.buf.full_redraw = true;
            self.buffer_dirty = true;
            self.status_dirty = true;
        }
    }

    /// The byte column in `slot`'s line for an LSP position under `enc`.
    fn byteColumn(self: *Ui, slot: *Slot, pos: lsp.Position, enc: lsp.PositionEncoding) u32 {
        if (pos.line >= slot.ed.buf.lineCount()) return pos.character;
        const text = slot.ed.buf.lineText(self.alloc, pos.line) catch return pos.character;
        defer self.alloc.free(text);
        return @intCast(lsp.characterToByte(text, pos.character, enc));
    }

    fn slotForPath(self: *Ui, abs: []const u8) ?*Slot {
        for (self.buffers.items) |slot| {
            const slot_abs = self.slotAbs(slot) orelse continue;
            if (std.mem.eql(u8, slot_abs, abs)) return slot;
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
        // Owned by the event, which frees it on return -- take a copy.
        const owned = self.alloc.dupe(u8, t) catch return;
        if (self.hover) |*h| h.deinit(self.alloc);
        self.hover = .{ .text = owned };
        self.hover_dirty = true;
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
        self.buffer_dirty = true;
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
        for (self.buffers.items) |slot| slot.lsp_opened = false;

        var root_buf: [std.fs.max_path_bytes]u8 = undefined;
        const n = std.process.currentPath(self.io, &root_buf) catch 0;
        self.startLsp(if (n > 0) root_buf[0..n] else ".", self.environ);
        for (self.buffers.items) |slot| self.lspDidOpen(slot);

        self.buf.full_redraw = true;
        self.buffer_dirty = true;
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
        self.buffer_dirty = true;
        self.status_dirty = true;
    }

    /// The severity's colour, for the squiggle and the sign alike.
    fn diagColor(severity: lsp.Severity) Color {
        return switch (severity) {
            .err => fg_diag_error,
            .warning => fg_diag_warning,
            .information => fg_diag_info,
            .hint => fg_diag_hint,
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
        var batch = self.client.batch();
        defer batch.deinit();

        // Before the rows, so the host has scrolled to where the cursor
        // is by the time the frame it belongs to lands.
        if (self.tree_scroll_pending) |p| {
            self.tree_scroll_pending = null;
            try batch.setLayerScrollOffset(self.tree_layer, p.row, p.col);
        }

        if (self.buffer_dirty) try self.renderBuffer(&batch);
        if (self.tree_visible) switch (self.tree_dirty) {
            .none => {},
            .selection => try self.renderTreeSelection(&batch),
            .full => try self.renderTree(&batch),
        };
        if (self.tabs_dirty) try self.renderTabs(&batch);
        if (self.status_dirty) try self.renderStatus(&batch);
        // Last in the frame, as they are last in the compositing order. The
        // hover popup after the finder: both float, and a hover raised while
        // the finder is open is the newer of the two.
        if (self.finder_dirty) try self.renderFinder(&batch);
        if (self.hover_dirty) try self.renderHover(&batch);

        _ = try batch.send();

        self.buffer_dirty = false;
        self.tree_dirty = .none;
        self.tabs_dirty = false;
        self.status_dirty = false;
        self.finder_dirty = false;
        self.hover_dirty = false;
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
        const b = self.buffer_bounds;
        if (b.cols == 0 or b.rows == 0) return;
        self.scrollBufferToCursor();
        try self.syncBufferScrollbar(batch);

        // A fresh edit (or the first parse after choosing a language)
        // means the tree is stale. `syncHighlight` reparses -- incremental
        // when it can, whole-buffer otherwise -- and reports whether the
        // repaint can be confined to `hl_dirty_lines`.
        var localized = false;
        if (self.buf.hl) |*h| {
            if (h.languageSet() and self.buf.ed.buf.edits != self.buf.hl_edits) {
                localized = self.syncHighlight(h) catch blk: {
                    self.buf.full_redraw = true;
                    break :blk false;
                };
                self.buf.hl_edits = self.buf.ed.buf.edits;
            }
            self.buf.ed.buf.clearEdits();
        }

        // A visual selection spans whole rows the incremental paths don't
        // know to touch. While one is active -- and once more the frame it
        // clears -- repaint the whole pane so the highlight is always
        // current. `handleInput` already forces this for a keyboard
        // selection; this covers the mouse-drag and paste paths too.
        const sel_active = self.buf.ed.selectionSpan() != null;
        if (sel_active or self.buf.prev_sel_active) self.buf.full_redraw = true;

        const cursor = self.buf.ed.pos();
        const scrolled = self.buf.top_line != self.buf.prev_top_line or self.buf.left_col != self.buf.prev_left_col;
        const edited = self.buf.ed.buf.edits != self.buf.prev_edits;
        if (!self.buf.full_redraw and !scrolled and !edited and !localized) {
            // Nothing but the caret moved (a bare `h`/`j`/`k`/`l`, a
            // word motion, an on-screen `:23k`): the pane is already
            // right everywhere except the rows the caret left and
            // landed on. Repaint just those -- no per-row syntax pass
            // over the whole viewport.
            try self.repaintCaretRows(batch, cursor.line);
        } else if (localized and !self.buf.full_redraw and !scrolled) {
            try self.renderChangedRows(batch, cursor.line);
        } else switch (planBufferRender(.{
            .prev_top = self.buf.prev_top_line,
            .top = self.buf.top_line,
            .prev_left = self.buf.prev_left_col,
            .left = self.buf.left_col,
            .prev_edits = self.buf.prev_edits,
            .edits = self.buf.ed.buf.edits,
            .rows = b.rows,
            .force_full = self.buf.full_redraw,
        })) {
            .full => try self.renderBufferRows(batch, 0, b.rows),
            .shift => |s| {
                // The scrolled-past rows are still valid where they land;
                // only the newly-uncovered band at one edge needs drawing.
                try batch.moveContent(self.buffer_layer, null, null, s.count, s.dir);
                try self.renderBufferRows(batch, s.exposed_lo, s.exposed_hi);

                // The caret is drawn as an inverted cell over its row;
                // repaint the row it left (to clear that cell) and the row
                // it's on now, unless the exposed band already covered them.
                for ([_]usize{ self.buf.prev_cursor_line, cursor.line }) |line| {
                    if (line < self.buf.top_line or line >= self.buf.top_line + b.rows) continue;
                    const screen_row = line - self.buf.top_line;
                    if (screen_row >= s.exposed_lo and screen_row < s.exposed_hi) continue;
                    try self.renderBufferRow(batch, screen_row);
                }
            },
        }

        // The line-number gutter. Every text path above repainted it for
        // the rows it drew; two cases leave stale numbers it did not
        // touch: a `move_content` scroll slides the old numbers along with
        // the text, and in `.relative` mode moving the caret changes every
        // row's distance. Repaint the whole gutter then -- it is one short
        // write per row, no syntax pass.
        if (self.gutterWidth() > 0 and (scrolled or
            (self.buf.ed.line_numbers == .relative and cursor.line != self.buf.prev_cursor_line)))
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
        if (cursor.line >= self.buf.top_line and cursor.line < self.buf.top_line + b.rows) {
            const display_col = try self.cursorDisplayCol();
            if (display_col >= self.buf.left_col and display_col - self.buf.left_col < self.textCols()) {
                const row = cursor.line - self.buf.top_line;
                const col = self.gutterWidth() + display_col - self.buf.left_col;
                if (self.caretShape() != null) {
                    try batch.setCursorOn(self.buffer_layer, row, col);
                } else {
                    const under = try self.cursorGrapheme();
                    defer self.alloc.free(under);
                    try writeAt(batch, self.buffer_layer, row, col, under, fg_cursor, bg_cursor);
                }
            }
        }

        self.buf.prev_top_line = self.buf.top_line;
        self.buf.prev_left_col = self.buf.left_col;
        self.buf.prev_cursor_line = cursor.line;
        self.buf.prev_edits = self.buf.ed.buf.edits;
        self.buf.prev_sel_active = sel_active;
        self.buf.full_redraw = false;
    }

    /// Repaints the buffer rows the caret just left and just landed on.
    /// Used when nothing else about the pane changed, so every other row
    /// is already correct; `renderBuffer`'s caret pass draws the block
    /// cursor on top afterwards.
    fn repaintCaretRows(self: *Ui, batch: *glyphwire.client.Client.Batch, cursor_line: usize) !void {
        const b = self.buffer_bounds;
        const top = self.buf.top_line;
        try self.repaintRowIfOnScreen(batch, self.buf.prev_cursor_line, top, b.rows);
        if (cursor_line != self.buf.prev_cursor_line)
            try self.repaintRowIfOnScreen(batch, cursor_line, top, b.rows);
    }

    fn repaintRowIfOnScreen(
        self: *Ui,
        batch: *glyphwire.client.Client.Batch,
        line: usize,
        top: usize,
        rows: usize,
    ) !void {
        if (line < top or line >= top + rows) return;
        try self.renderBufferRow(batch, line - top);
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
            _ = try h.beginParse(buf, self.parsePrefixEnd(), self.parseBudget(first_parse_budget_ms));
            self.buf.full_redraw = true;
            return false;
        }

        // Replay the journal onto the retained tree. An edit that spans
        // more than one line changes the line count, which shifts every
        // row below it -- the partial-repaint path can't express that, so
        // reparse incrementally (still the win) but repaint in full.
        var line_count_stable = true;
        for (buf.pending_edits.items) |e| {
            h.applyEdit(e);
            if (e.start_point.line != e.old_end_point.line or
                e.start_point.line != e.new_end_point.line) line_count_stable = false;
        }

        self.hl_changed.clearRetainingCapacity();
        const localized = h.reparseIncremental(buf, &self.hl_changed) catch {
            self.buf.full_redraw = true;
            return false;
        };
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
            if (hi -| lo > self.buffer_bounds.rows) {
                self.buf.full_redraw = true;
                return false;
            }
            var line = lo;
            while (line <= hi) : (line += 1) try self.addDirtyLine(line);
            if (self.hl_dirty_lines.items.len > self.buffer_bounds.rows) {
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
        const last = self.buf.top_line + 2 * @as(usize, self.buffer_bounds.rows);
        return buf.lineEnd(@min(last, buf.lineCount() -| 1));
    }

    fn parseBudget(self: *const Ui, ms: i64) syntax.ParseBudget {
        return .{ .time = .{ .io = self.io, .ms = ms } };
    }

    /// Any buffer, shown or not, with a staged parse still running.
    fn highlightPending(self: *const Ui) bool {
        for (self.buffers.items) |slot| {
            if (slot.hl) |*h| if (h.parsing()) return true;
        }
        return false;
    }

    /// Gives every buffer's parked parse one more slice. One that
    /// finishes on the active buffer repaints the pane: rows past the
    /// prefix were drawn plain, and rows near the cut may change colour.
    /// A background buffer that finishes just has its full tree ready for
    /// when it is next shown (`setActive` repaints then anyway).
    fn stepHighlight(self: *Ui) void {
        for (self.buffers.items) |slot| {
            const h = if (slot.hl) |*x| x else continue;
            if (!h.parsing()) continue;
            const progress = h.continueParse(self.parseBudget(parse_slice_ms)) catch .done;
            if (progress == .done and slot == self.buf) {
                slot.full_redraw = true;
                self.buffer_dirty = true;
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
        const b = self.buffer_bounds;
        const top = self.buf.top_line;

        for (self.hl_dirty_lines.items) |line| {
            if (line < top or line >= top + b.rows) continue;
            try self.renderBufferRow(batch, line - top);
        }
        for ([_]usize{ self.buf.prev_cursor_line, cursor_line }) |line| {
            if (line < top or line >= top + b.rows) continue;
            if (self.dirtyLineListed(line)) continue;
            try self.renderBufferRow(batch, line - top);
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
        return self.buffer_bounds.cols -| self.gutterWidth();
    }

    /// Paints just the line-number cell for buffer screen row `r`, in
    /// `fg_text` on the caret's line and `fg_dim` elsewhere. A no-op when
    /// the gutter is off. Every buffer-text path calls this for the rows
    /// it repaints; `renderBuffer` calls it for the rest when a scroll or
    /// a `.relative` caret move changed numbers it did not otherwise touch.
    fn renderGutterCell(self: *Ui, batch: *glyphwire.client.Client.Batch, r: usize) !void {
        const width = self.gutterWidth();
        if (width == 0) return;
        const line = self.buf.top_line + r;
        const cursor_line = self.buf.ed.pos().line;
        const past_end = line >= self.buf.ed.buf.lineCount();

        // The sign first, in its own cell: the worst severity starting on
        // this line, or a blank. Painted even on a clean line, because this
        // is also what takes yesterday's mark off.
        const signs = self.signWidth();
        if (signs > 0) {
            var sign: []const u8 = " ";
            var sign_fg = fg_dim;
            if (!past_end) {
                if (self.diagSeverityForLine(line)) |sev| {
                    sign = if (sev == .err) sign_error else sign_other;
                    sign_fg = diagColor(sev);
                }
            }
            try writeAt(batch, self.buffer_layer, r, 0, sign, sign_fg, bg_buffer);
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
        const fg = if (!past_end and line == cursor_line) fg_text else fg_dim;
        try writeAt(batch, self.buffer_layer, r, signs, cell, fg, bg_buffer);
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
        const line = self.buf.top_line + r;
        const gutter = self.gutterWidth();
        const cols = self.textCols();

        try self.renderGutterCell(batch, r);

        if (line >= self.buf.ed.buf.lineCount()) {
            // vim's marker for "past the end of the buffer", the rest of
            // the row padded by the host.
            try batch.writeTextOpts("~", .{
                .layer = self.buffer_layer,
                .row = r,
                .col = gutter,
                .fg = fg_dim,
                .bg = bg_buffer,
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
            if (h.ready() and self.renderRowSpans(batch, r, line, text)) painted = true;
        }
        if (!painted) try self.rowSpansImpl(batch, r, text, &.{});

        // Overpaint, in order: search matches, then the selection on top
        // of them. Both are second writes over the text just laid down
        // rather than threaded through every colour run, and the
        // selection wins because it is the thing you are about to act on.
        try self.paintMatchRow(batch, r, line, text);
        try self.paintSelectionRow(batch, r, line, text);
        // Diagnostics last, and through `set_underline` rather than a write:
        // the two overpaints above are full cell writes that would clear a
        // squiggle laid down before them, and the underline is a channel of
        // its own so it doesn't have to fight either of them for the cell.
        // Every path that repaints a row comes through here, so a mark is
        // re-applied whenever the row under it is redrawn.
        try self.paintDiagnosticRow(batch, r, line, text);
    }

    /// Draws every diagnostic starting on buffer `line` as a coloured
    /// underline over its range, clipped to the horizontal scroll.
    ///
    /// A zero-width range -- which is how servers often report "the error is
    /// *here*" -- is widened to one cell, because a squiggle under nothing is
    /// nothing. Worst severity last, so where two diagnostics overlap the
    /// more serious colour is the one left on the cells.
    fn paintDiagnosticRow(
        self: *Ui,
        batch: *glyphwire.client.Client.Batch,
        r: usize,
        line: usize,
        text: []const u8,
    ) !void {
        if (self.lsp_pool == null) return;
        const abs = self.slotAbs(self.buf) orelse return;
        const cols = self.textCols();
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
            if (end_dc <= self.buf.left_col or start_dc >= self.buf.left_col + cols) continue;

            const vis_lo = @max(start_dc, self.buf.left_col);
            const vis_hi = @min(end_dc, self.buf.left_col + cols);
            if (vis_hi <= vis_lo) continue;

            try batch.setUnderline(.{
                .layer = self.buffer_layer,
                .row = r,
                .col = self.gutterWidth() + (vis_lo - self.buf.left_col),
                .rows = 1,
                .cols = vis_hi - vis_lo,
                .underline = .curly,
                .underline_color = diagColor(e.severity),
            });
        }
    }

    /// Where the hover popup goes: under the cursor when there is room
    /// below it, above it otherwise -- so it never covers the identifier it
    /// is describing. Clamped inside the buffer pane like `finderRect`.
    fn hoverRect(self: *const Ui, want_rows: usize) Bounds {
        const b = self.buffer_bounds;
        const cols = @min(hover_max_cols, b.cols);
        const rows = @min(@min(want_rows, hover_max_rows), b.rows);

        const cursor = self.buf.ed.pos();
        const cursor_row = b.row + (cursor.line -| self.buf.top_line);
        // Below if it fits, else above; if neither fits (a two-row pane),
        // below and clipped by the clamp.
        const below = cursor_row + 1 + rows <= b.row + b.rows;
        const row = if (below)
            cursor_row + 1
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
    /// The content is markdown; this slice renders it as plain text with its
    /// blank lines kept, which is what makes a type signature and a sentence
    /// of documentation readable. Running it through the `md/` renderer is a
    /// later slice -- and a bigger one than it looks, since that renderer
    /// draws into a layer of its own.
    fn renderHover(self: *Ui, batch: *glyphwire.client.Client.Batch) !void {
        const h = if (self.hover) |*open| open else {
            try batch.setLayerVisible(self.hover_layer, false);
            return;
        };

        // Wrapped to the popup's width first, so the height is the height of
        // what will actually be drawn rather than of the source text.
        var lines: std.ArrayList([]const u8) = .empty;
        defer lines.deinit(self.alloc);
        const wrap_cols = @min(hover_max_cols, self.buffer_bounds.cols) -| 2;
        if (wrap_cols == 0) {
            try batch.setLayerVisible(self.hover_layer, false);
            return;
        }
        var it = std.mem.splitScalar(u8, h.text, '\n');
        while (it.next()) |raw| {
            if (raw.len == 0) {
                try lines.append(self.alloc, "");
                continue;
            }
            var wrap = glyphwire.WrapIterator.init(raw, wrap_cols);
            while (wrap.next()) |piece| try lines.append(self.alloc, piece);
        }

        const r = self.hoverRect(lines.items.len);
        self.hover_rect = r;
        if (r.cols == 0 or r.rows == 0) {
            try batch.setLayerVisible(self.hover_layer, false);
            return;
        }
        if (h.scroll >= lines.items.len) h.scroll = lines.items.len -| 1;

        try batch.setLayerSize(self.hover_layer, r.cols, r.rows);
        try batch.setLayerCellPosition(self.hover_layer, r.row, r.col);

        var row: usize = 0;
        while (row < r.rows) : (row += 1) {
            const idx = h.scroll + row;
            const body: []const u8 = if (idx < lines.items.len) lines.items[idx] else "";
            // One padded write per row: the leading space is the popup's
            // margin and `pad` fills the rest, so the panel reads as a solid
            // block whatever the text length.
            try batch.writeTextOpts(body, .{
                .layer = self.hover_layer,
                .row = row,
                .col = 1,
                .fg = fg_hover,
                .bg = bg_hover,
                .max_cols = r.cols -| 1,
                .pad = true,
            });
            try writeAt(batch, self.hover_layer, row, 0, " ", fg_hover, bg_hover);
        }
        try batch.setLayerVisible(self.hover_layer, true);
    }

    /// Closes the popup. Returns whether there was one, so a key can be
    /// swallowed by the closing (Escape) or fall through (anything else).
    fn closeHover(self: *Ui) bool {
        if (self.hover) |*h| {
            h.deinit(self.alloc);
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
        line: usize,
        text: []const u8,
    ) !void {
        const pat = self.buf.ed.highlightPattern() orelse return;
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
                text,
                hit - ls,
                hi - ls,
                if (current) bg_match_current else bg_match,
            );
        }
    }

    /// Repaints the byte range `[lo_b, hi_b)` of a row's `text` in `bg`,
    /// keeping the characters themselves. Clipped to the horizontal
    /// scroll; a no-op when none of it is on screen. Shared by the
    /// selection and the search highlight, which differ only in colour
    /// and in how they pick the range.
    fn paintRowSpan(
        self: *Ui,
        batch: *glyphwire.client.Client.Batch,
        r: usize,
        text: []const u8,
        lo_b: usize,
        hi_b: usize,
        bg: Color,
    ) !void {
        const cols = self.textCols();
        if (cols == 0 or hi_b <= lo_b) return;

        const opts = self.displayOpts();
        const start_dc = display.colOfByte(text, @min(lo_b, text.len), opts);
        const end_dc = display.colOfByte(text, @min(hi_b, text.len), opts);
        if (end_dc <= self.buf.left_col or start_dc >= self.buf.left_col + cols) return;

        const vis_lo = @max(start_dc, self.buf.left_col);
        const vis_hi = @min(end_dc, self.buf.left_col + cols);
        if (vis_hi <= vis_lo) return;

        var overlay: std.ArrayList(u8) = .empty;
        defer overlay.deinit(self.alloc);
        try display.appendCols(self.alloc, &overlay, text, vis_lo, vis_hi - vis_lo, opts);

        try writeAt(
            batch,
            self.buffer_layer,
            r,
            self.gutterWidth() + vis_lo - self.buf.left_col,
            overlay.items,
            fg_text,
            bg,
        );
    }

    /// If buffer `line` overlaps the visual selection, repaints its
    /// selected columns with `bg_selected` (keeping the default text
    /// colour). A charwise selection highlights the covered characters; a
    /// linewise one runs to the pane's right edge, like vim. A no-op when
    /// nothing is selected or the selected part is scrolled out of view.
    fn paintSelectionRow(
        self: *Ui,
        batch: *glyphwire.client.Client.Batch,
        r: usize,
        line: usize,
        text: []const u8,
    ) !void {
        const span = self.buf.ed.selectionSpan() orelse return;
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
        const start_dc = display.colOfByte(text, @min(sel_lo_b, text.len), opts);
        const end_dc = if (to_eol)
            self.buf.left_col + cols
        else
            display.colOfByte(text, @min(sel_hi_b, text.len), opts);
        if (end_dc <= self.buf.left_col or start_dc >= self.buf.left_col + cols) return;

        const vis_lo = @max(start_dc, self.buf.left_col);
        const vis_hi = @min(end_dc, self.buf.left_col + cols);
        if (vis_hi <= vis_lo) return;

        // The characters under the highlight, then spaces out to the
        // selection's end (a linewise selection past the text, or the
        // newline slot of a charwise one) -- `appendCols` fills the whole
        // range either way.
        var overlay: std.ArrayList(u8) = .empty;
        defer overlay.deinit(self.alloc);
        try display.appendCols(self.alloc, &overlay, text, vis_lo, vis_hi - vis_lo, opts);

        try writeAt(batch, self.buffer_layer, r, gutter + vis_lo - self.buf.left_col, overlay.items, fg_text, bg_selected);
    }

    /// Paints buffer row `r` (buffer line `line`, whole text `text`) as
    /// tree-sitter colour runs clipped to `[left_col, left_col+cols)`.
    /// Returns false if the highlighter couldn't produce spans, so the
    /// caller can fall back to a plain write.
    fn renderRowSpans(
        self: *Ui,
        batch: *glyphwire.client.Client.Batch,
        r: usize,
        line: usize,
        text: []const u8,
    ) bool {
        const h = &self.buf.hl.?;
        const ls = self.buf.ed.buf.lineStart(line);
        const le = self.buf.ed.buf.lineEnd(line);
        h.lineSpans(ls, le, &self.hl_scratch) catch return false;
        self.rowSpansImpl(batch, r, text, self.hl_scratch.items) catch return false;
        return true;
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
        text: []const u8,
        spans: []const syntax.Span,
    ) !void {
        const cols = self.textCols();
        if (cols == 0) return;
        const left = self.buf.left_col;
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
                fg_whitespace
            else
                spanColorAt(spans, cell.src);

            if (!have_run or lo != dc) {
                if (have_run) try self.flushRowGroup(batch, r, group_dc, row_buf.items, ranges.items, false);
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
            try self.flushRowGroup(batch, r, group_dc, row_buf.items, ranges.items, true);
        } else {
            // An empty line, or one scrolled entirely off to the left.
            try self.writeSpaces(batch, r, gutter, cols);
        }
    }

    /// Where one colour starts within a row's text; it runs to the next
    /// range's start.
    const RowRange = struct { start: usize, color: ?Color };

    /// Writes one contiguous stretch of a buffer row, starting at display
    /// column `start_dc`, as a single `write_text` with one span per
    /// colour range. `pad_row` has the host fill the rest of the pane's
    /// row in the buffer colour.
    fn flushRowGroup(
        self: *Ui,
        batch: *glyphwire.client.Client.Batch,
        r: usize,
        start_dc: usize,
        bytes: []const u8,
        ranges: []const RowRange,
        pad_row: bool,
    ) !void {
        const left = self.buf.left_col;
        if (start_dc < left) return;
        const row_spans = try self.alloc.alloc(glyphwire.client.Client.Span, ranges.len);
        defer self.alloc.free(row_spans);
        for (ranges, row_spans, 0..) |rg, *sp, i| {
            const stop = if (i + 1 < ranges.len) ranges[i + 1].start else bytes.len;
            sp.* = .{ .text = bytes[rg.start..stop], .fg = rg.color orelse fg_text };
        }
        try batch.writeSpans(row_spans, .{
            .layer = self.buffer_layer,
            .row = r,
            .col = self.gutterWidth() + start_dc - left,
            .bg = bg_buffer,
            .max_cols = if (pad_row) left + self.textCols() - start_dc else null,
            .pad = pad_row,
        });
    }

    /// Blanks `n` cells of buffer row `r` to the pane colour -- a fill,
    /// not a run of spaces.
    fn writeSpaces(self: *Ui, batch: *glyphwire.client.Client.Batch, r: usize, col: usize, n: usize) !void {
        if (n == 0) return;
        try batch.clearArea(.{ .layer = self.buffer_layer, .row = r, .col = col, .rows = 1, .cols = n, .bg = bg_buffer });
    }

    /// Keeps the caret inside the buffer pane, both axes.
    fn scrollBufferToCursor(self: *Ui) void {
        const b = self.buffer_bounds;
        if (b.rows == 0 or b.cols == 0) return;
        const pos = self.buf.ed.pos();

        if (pos.line < self.buf.top_line) self.buf.top_line = pos.line;
        if (pos.line >= self.buf.top_line + b.rows) self.buf.top_line = pos.line - b.rows + 1;

        const col = self.cursorDisplayCol() catch return;
        const cols = self.textCols();
        if (col < self.buf.left_col) self.buf.left_col = col;
        if (cols > 0 and col >= self.buf.left_col + cols) self.buf.left_col = col - cols + 1;
    }

    /// Applies a host-driven scroll of the buffer pane (wheel or thumb
    /// drag): moves the view and drags the cursor back onto it, keeping
    /// its column. Records the new position as already pushed so the next
    /// `syncBufferScrollbar` doesn't bounce it back to the host.
    fn scrollBufferTo(self: *Ui, row: usize, col: usize) void {
        const b = self.buffer_bounds;
        if (b.rows == 0) return;
        self.buf.top_line = row;
        self.buf.left_col = col;

        const cur = self.buf.ed.pos();
        const last = self.buf.ed.buf.lineCount() -| 1;
        const clamped_line = std.math.clamp(cur.line, row, @min(row + b.rows - 1, last));
        if (clamped_line != cur.line) {
            self.buf.ed.cursor = self.buf.ed.buf.offsetOf(.{ .line = clamped_line, .col = cur.col });
        }
        self.buf.pushed_bar = .{ self.buf.ed.buf.lineCount(), b.cols, self.buf.top_line, self.buf.left_col };
        // The view moved and the cursor may have been dragged with it;
        // the status row shows both.
        self.buffer_dirty = true;
        self.status_dirty = true;
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
        const b = self.buffer_bounds;
        const now: [4]usize = .{ self.buf.ed.buf.lineCount(), b.cols, self.buf.top_line, self.buf.left_col };
        if (std.mem.eql(usize, &now, &self.buf.pushed_bar)) return;

        if (now[0] != self.buf.pushed_bar[0] or now[1] != self.buf.pushed_bar[1]) {
            try batch.setLayerContentExtent(self.buffer_layer, now[1], now[0]);
        }
        try batch.setLayerScrollOffset(self.buffer_layer, self.buf.top_line, self.buf.left_col);
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

        var r: usize = 0;
        while (r < content_rows) : (r += 1) {
            const entry = self.tree.at(r);
            const selected = self.focus == .tree and r == self.tree.cursor;
            const bg = if (selected) bg_selected else bg_tree;

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
                    .fg = if (e.hidden)
                        (if (e.is_dir) fg_hidden_dir else fg_hidden)
                    else
                        (if (e.is_dir) fg_dir else fg_text),
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
                try batch.clearArea(.{ .layer = self.tree_layer, .row = r, .rows = 1, .cols = content_cols, .bg = bg_tree });
            }
        }

        self.tree_painted = .{ .row = self.tree.cursor, .focused = self.focus == .tree };
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
        const focused = self.focus == .tree;
        const cols = self.treeContentCols();
        const was = self.tree_painted;
        if (was.focused == focused and was.row == self.tree.cursor) return;

        if (was.focused) {
            try batch.setBg(.{ .layer = self.tree_layer, .row = was.row, .rows = 1, .cols = cols, .bg = bg_tree });
        }
        if (focused) {
            try batch.setBg(.{ .layer = self.tree_layer, .row = self.tree.cursor, .rows = 1, .cols = cols, .bg = bg_selected });
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
        const b = self.tabs_bounds;
        if (b.cols == 0 or b.rows == 0) return;

        var labels: std.ArrayList(tabs.Tab) = .empty;
        defer labels.deinit(self.alloc);
        for (self.buffers.items) |slot| {
            try labels.append(self.alloc, .{
                .label = tabs.labelFor(slot.ed.path),
                .dirty = slot.ed.buf.dirty,
            });
        }

        self.tab_total = try tabs.layout(self.alloc, labels.items, &self.tab_spans);
        if (self.active < self.tab_spans.items.len) {
            self.tab_scroll = tabs.scrollToShow(
                self.tab_spans.items[self.active],
                b.cols,
                self.tab_scroll,
                self.tab_total,
            );
        }
        try self.syncTabScrollbar(batch);

        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(self.alloc);

        try batch.clearArea(.{ .layer = self.tabs_layer, .row = 0, .rows = 1, .bg = bg_tab_bar });

        for (self.tab_spans.items, labels.items, 0..) |span, tab, i| {
            const active = i == self.active;
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

            try self.writeStripRun(
                batch,
                span.start,
                text.items,
                if (active) fg_text else fg_dim,
                if (active) bg_buffer else bg_tab,
            );
            if (i + 1 < self.tab_spans.items.len) {
                try self.writeStripRun(batch, span.end, tabs.separator, fg_dim, bg_tab_bar);
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
        const view_lo = self.tab_scroll;
        const view_hi = self.tab_scroll + self.tabs_bounds.cols;
        const lo = @max(start, view_lo);
        const hi = @min(start + width, view_hi);
        if (lo >= hi) return;

        // Tab labels hold no tabs and take no space markers, so the
        // default `Opts` is the plain codepoint-width walk this wants.
        const from = display.byteAtCol(text, lo - start, .{});
        const to = display.byteAtCol(text, hi - start, .{});
        try writeAt(batch, self.tabs_layer, 0, lo - view_lo, text[from..to], fg, bg);
    }

    /// Keeps the tabs layer's virtual extent and offset in step with the
    /// strip, the same arrangement the buffer pane has: the layer's grid
    /// is only pane-wide, and reporting the strip's real width is what
    /// lets the host turn a shift+wheel or a drag over it into the
    /// `scroll_offset` `handleEvent` follows. Silent when nothing moved.
    fn syncTabScrollbar(self: *Ui, batch: *glyphwire.client.Client.Batch) !void {
        const now: [2]usize = .{ self.tab_total, self.tab_scroll };
        if (std.mem.eql(usize, &now, &self.pushed_tab_bar)) return;

        if (now[0] != self.pushed_tab_bar[0]) {
            try batch.setLayerContentExtent(
                self.tabs_layer,
                @max(self.tab_total, self.tabs_bounds.cols),
                1,
            );
        }
        try batch.setLayerScrollOffset(self.tabs_layer, 0, self.tab_scroll);
        self.pushed_tab_bar = now;
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
        var fg = fg_status;

        // A tree search takes the row ahead of everything else: it is the
        // only thing on screen that says what was typed, since the prefix
        // itself is never drawn in the pane. The `/` prompt keeps the key
        // that started it, so the scope the search is running in stays
        // readable while it runs.
        if (self.find) |f| {
            const prompt: []const u8 = if (f.scope == .deep) "/" else "find: ";
            const n = f.hits.items.len;
            if (n == 0) {
                if (f.query.items.len > 0) fg = fg_error;
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
            if (self.buf.ed.search_failed) fg = fg_error;
            try line.append(self.alloc, self.buf.ed.searchPrompt());
            try line.appendSlice(self.alloc, self.buf.ed.cmdline.text());
        } else if (self.buf.ed.status.items.len > 0) {
            if (std.mem.startsWith(u8, self.buf.ed.status.items, "E")) fg = fg_error;
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
            if (self.buffers.items.len > 1) {
                try line.print(self.alloc, "  [{d}/{d}]", .{ self.active + 1, self.buffers.items.len });
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
        const show_mode = self.buf.ed.mode != .command and self.buf.ed.mode != .search and
            self.buf.ed.status.items.len == 0;
        const opts: glyphwire.client.Client.TextOpts = .{
            .layer = self.status_layer,
            .row = 0,
            .col = 0,
            .fg = fg,
            .bg = bg_status,
            .max_cols = b.cols,
            .pad = true,
        };
        if (show_mode) {
            const mode_end = 1 + mode_word.len;
            try batch.writeSpans(&.{
                .{ .text = line.items[0..1] },
                .{ .text = line.items[1..mode_end], .fg = fg_mode },
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
                    .fg = bg_status,
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
        };
    }
};

/// The scroll/edit state `planBufferRender` decides from.
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
    return a.?.r == b.?.r and a.?.g == b.?.g and a.?.b == b.?.b and a.?.a == b.?.a;
}
