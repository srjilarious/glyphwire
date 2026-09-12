//! zoe's glyphwire client: four panes in a split tree, the render pass
//! that fills them, and the input loop that drives the editor.
//!
//! The layout is a `column` split holding a `row` split (the tree beside
//! a column of tab strip over buffer) above a one-row statusline. The
//! host owns it: zoe describes it once at startup, and after that a
//! window resize or a divider drag arrives as a `layout` notification
//! saying where each pane ended up.
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
//! itself changes (an expand or collapse), never on a scroll tick. The
//! buffer pane can't work that way: a 100k-line file as a cell grid is
//! hundreds of megabytes. So its content grid is exactly pane-sized, zoe
//! owns `top_line`/`left_col`, and it repaints the visible rows -- but on
//! a pure scroll of less than a screen it shifts the rows it already drew
//! with one `move_content` and repaints only the exposed band
//! (`planBufferRender`), rather than rewriting the whole pane every tick.
//! See docs/investigations/zoe-editor.md for what a full diff would add.

const std = @import("std");
const glyphwire = @import("glyphwire");
const ls_icons = @import("ls_support").icons;

const editor = @import("editor.zig");
const tree_mod = @import("tree.zig");
const syntax = @import("syntax.zig");
const langconf = @import("langconf.zig");
const tabs = @import("tabs.zig");

const Editor = editor.Editor;
const Tree = tree_mod.Tree;
const Color = glyphwire.Color;

/// Cells the tree pane occupies until a divider drag says otherwise.
const default_tree_cols: usize = 28;

/// The most zoe will read into a buffer. Every open buffer holds its
/// text for as long as it is open, so this is also the per-tab ceiling.
const max_file_bytes: usize = 64 * 1024 * 1024;

// The palette. Flat and dark; the panes have to paint their own
// background because a cell whose background is pure black draws nothing
// (see `host/render.zig`), which would leave the shell's scrollback
// showing through.
const bg_buffer = Color{ .r = 24, .g = 24, .b = 29, .a = 255 };
const bg_tree = Color{ .r = 20, .g = 20, .b = 25, .a = 255 };
const bg_status = Color{ .r = 46, .g = 46, .b = 56, .a = 255 };
const bg_cursor = Color{ .r = 220, .g = 220, .b = 230, .a = 255 };
const bg_selected = Color{ .r = 48, .g = 62, .b = 84, .a = 255 };
const fg_text = Color{ .r = 210, .g = 210, .b = 218, .a = 255 };
const fg_dim = Color{ .r = 92, .g = 92, .b = 104, .a = 255 };
const fg_dir = Color{ .r = 132, .g = 176, .b = 232, .a = 255 };
const fg_status = Color{ .r = 226, .g = 226, .b = 236, .a = 255 };
const fg_mode = Color{ .r = 150, .g = 220, .b = 160, .a = 255 };
const fg_error = Color{ .r = 240, .g = 140, .b = 140, .a = 255 };
const fg_cursor = Color{ .r = 24, .g = 24, .b = 29, .a = 255 };
// The tab strip. The active tab takes the buffer's own background so it
// reads as the front of the pane below it, the way a tabbed window does;
// the rest sit on a bar darker than either.
const bg_tab_bar = Color{ .r = 16, .g = 16, .b = 20, .a = 255 };
const bg_tab = Color{ .r = 34, .g = 34, .b = 41, .a = 255 };

/// A pane's bounds, mirrored from the last `layout` notification.
const Bounds = struct {
    row: usize = 0,
    col: usize = 0,
    cols: usize = 0,
    rows: usize = 0,
};

const Focus = enum { buffer, tree };

/// The slice of editor state the buffer pane draws from. `handleInput`
/// takes one before dispatching a keystroke and one after; if they match,
/// the buffer pane is untouched and `render` can skip it -- which is what
/// keeps a `:` line keystroke from triggering a full syntax repaint.
const EdSnapshot = struct {
    cursor: usize,
    edits: u64,
    line_numbers: editor.LineNumbers,
    /// The mode and selection anchor so a bare `v` / `V` / `<esc>` / `o`
    /// -- which can change the highlighted range without moving the
    /// cursor -- still repaints the buffer pane.
    mode: editor.Mode,
    anchor: ?usize,
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
            .mode = ed.mode,
            .anchor = ed.select_anchor,
            .dirty = ed.buf.dirty,
        };
    }
    fn eql(a: EdSnapshot, b: EdSnapshot) bool {
        return a.cursor == b.cursor and a.edits == b.edits and
            a.line_numbers == b.line_numbers and a.mode == b.mode and a.anchor == b.anchor;
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

    fn deinit(self: *Slot, alloc: std.mem.Allocator) void {
        if (self.hl) |*h| h.deinit();
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

    /// An in-progress left-button drag in the buffer pane. `anchor` is
    /// the buffer byte offset the press landed on; `moved` flips true the
    /// first time the pointer changes cell, which is when the drag turns
    /// into a visual selection (a press+release with no move is a plain
    /// click). Null when no button is down over the pane.
    drag: ?struct { anchor: usize, moved: bool } = null,

    focus: Focus = .buffer,
    tree_visible: bool = true,
    /// Per-pane redraw flags, set by whatever changed that pane's
    /// contents and cleared by `render`. Split three ways because a
    /// keystroke on the `:` line only touches the status row -- redrawing
    /// the buffer (a fresh syntax pass per visible row) and the whole
    /// file tree (a `draw_icon` per entry) on every such keystroke is
    /// what made the command line feel laggy.
    buffer_dirty: bool = true,
    tree_dirty: bool = true,
    tabs_dirty: bool = true,
    status_dirty: bool = true,
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
        initial_path: ?[]const u8,
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

        const size = try client.getSize();
        const metrics = try client.getCellMetrics();

        // Content sizes are provisional: every `layout` notification
        // resizes them to match the panes they landed in.
        const tree_layer = try client.createLayer(default_tree_cols, size.rows, 0);
        const tabs_layer = try client.createLayer(size.cols, 1, 0);
        const buffer_layer = try client.createLayer(size.cols, size.rows, 0);
        const status_layer = try client.createLayer(size.cols, 1, 0);

        // The tree is host-scrolled (both bars). The buffer scrolls
        // itself, but a `content_extent` (pushed each frame from the line
        // count -- see `syncBufferScrollbar`) lets the host draw a
        // proportional vertical bar and turn a wheel or thumb drag over
        // the pane into a `scroll_offset` zoe then follows.
        try client.setLayerScrollbars(tree_layer, true, true);
        try client.setLayerScrollbars(buffer_layer, true, false);
        // The tab strip scrolls sideways but draws no bar of its own: it
        // is one row tall, and a horizontal bar under it would double its
        // height for a scrollbar nothing needs to see. It still reports a
        // `content_extent` (`syncTabScrollbar`), which is what makes the
        // host treat it as scrollable and route a shift+wheel over it
        // back as a `scroll_offset`.
        try client.setLayerScrollbars(tabs_layer, false, false);

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
            .tree = try Tree.init(alloc, io, root_dir),
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

        const first = try self.newSlot(initial_path);
        errdefer first.deinit(alloc);
        try self.buffers.append(alloc, first);
        self.buf = first;
        self.active = 0;

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

    /// Loads `zoe.conf` and resolves the grammar search path into a
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

    /// Opens `path` -- or an empty scratch buffer when null -- as a new,
    /// unlisted slot: the caller adds it to `buffers`. A path that can't
    /// be read is a new empty buffer carrying that name, which is how
    /// `zoe newfile.txt` creates one.
    fn newSlot(self: *Ui, path: ?[]const u8) !*Slot {
        const slot = try self.alloc.create(Slot);
        errdefer self.alloc.destroy(slot);

        const text: ?[]u8 = if (path) |p|
            std.Io.Dir.cwd().readFileAlloc(self.io, p, self.alloc, .limited(max_file_bytes)) catch null
        else
            null;
        defer if (text) |t| self.alloc.free(t);

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

            if (syntax.Highlighter.init(self.alloc, cfg.theme)) |h| {
                slot.hl = h;
                // The highlighter resolves injected grammars through the
                // shared registry; `injections` is the `zoe.conf` switch.
                const reg: ?*syntax.Registry = if (self.grammars) |*g| g else null;
                slot.hl.?.configureInjections(reg, cfg.injections);
                // From here on `Buffer` keeps the edit journal the
                // incremental reparse replays.
                slot.ed.buf.track_edits = true;
                self.selectHighlightLanguage(slot, path);
            } else |_| {}
        }

        // A `:set lineno=…` typed this session beats the config default,
        // so a buffer opened afterwards matches the ones already open.
        if (self.buffers.items.len > 0) {
            slot.ed.line_numbers = self.buf.ed.line_numbers;
            slot.ed.page_lines = self.buf.ed.page_lines;
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
        self.client.destroyContext(self.context) catch {};
        self.tree.deinit();
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
                @max(self.tree.widestCols(), self.tree_bounds.cols),
                @max(self.tree.len(), self.tree_bounds.rows),
            );
        }
    }

    // ── Loop ────────────────────────────────────────────────────────────

    pub fn run(self: *Ui) !void {
        while (!self.quit) {
            try self.drainEvents();
            if (self.buffer_dirty or self.tree_dirty or self.tabs_dirty or self.status_dirty)
                try self.render();
            if (self.quit) break;

            // Block until something arrives rather than spinning; the
            // timeout is only so the other event queues get looked at.
            //
            // The waiting form *consumes* the event it waited for, so it
            // has to be handled right here -- `drainEvents` above will
            // never see it, and discarding it drops a keystroke on the
            // floor (and leaks its text).
            if (self.listener.waitInputEvent(.{
                .duration = .{ .raw = .fromMilliseconds(20), .clock = .awake },
            }) catch null) |ev| {
                defer ev.deinit(self.alloc);
                try self.handleInput(ev);
            }
        }
    }

    fn drainEvents(self: *Ui) !void {
        while (self.listener.pollLayoutEvent()) |ev| {
            defer ev.deinit(self.alloc);
            if (ev.boundsFor(self.tree_layer)) |b| self.tree_bounds = toBounds(b);
            if (ev.boundsFor(self.tabs_layer)) |b| self.tabs_bounds = toBounds(b);
            if (ev.boundsFor(self.buffer_layer)) |b| self.buffer_bounds = toBounds(b);
            if (ev.boundsFor(self.status_layer)) |b| self.status_bounds = toBounds(b);
            try self.syncContentSizes();
            // The buffer layer's grid was resized: the rows it holds no
            // longer line up with the panes, so the next frame can't
            // shift them -- it has to repaint. Every pane moved.
            self.buf.full_redraw = true;
            self.buffer_dirty = true;
            self.tree_dirty = true;
            self.tabs_dirty = true;
            self.status_dirty = true;
        }
        while (self.listener.pollScrollOffsetEvent()) |ev| {
            if (ev.layer == self.tree_layer) self.tree_scroll = .{ .row = ev.row, .col = ev.col };
            // A wheel or thumb drag over the buffer pane: the host moved
            // the virtual offset and told us where. Follow it, and drag
            // the cursor along so it stays on screen (like vim's Ctrl-E /
            // Ctrl-Y). `pushed_bar` is updated so `syncBufferScrollbar`
            // doesn't immediately echo this straight back.
            if (ev.layer == self.buffer_layer) self.scrollBufferTo(ev.row, ev.col);
            // A shift+wheel or thumb drag over the tab strip. Only the
            // column matters -- the strip is one row tall -- and the
            // offset is recorded as already pushed so `syncTabScrollbar`
            // doesn't echo it straight back.
            if (ev.layer == self.tabs_layer and ev.col != self.tab_scroll) {
                self.tab_scroll = ev.col;
                self.pushed_tab_bar[1] = ev.col;
                self.tabs_dirty = true;
            }
        }
        // Mouse moves before buttons: a drag's pending moves should
        // update the selection before its release closes it out.
        while (self.listener.pollMouseMoveEvent()) |ev| {
            try self.handleMouseDrag(ev);
        }
        while (self.listener.pollMouseButtonEvent()) |ev| {
            defer ev.deinit(self.alloc);
            try self.handleMouseButton(ev);
        }
        while (self.listener.pollInputEvent()) |ev| {
            defer ev.deinit(self.alloc);
            try self.handleInput(ev);
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

                // A leftover status/error message (`:q` on a dirty
                // buffer, an unknown command, ...) would otherwise sit in
                // the statusline forever -- nothing else ever clears it,
                // so it permanently hides the mode indicator underneath.
                // Vim clears it on the next keystroke; this is that.
                self.buf.ed.status.clearRetainingCapacity();

                // Ctrl+w switches panes, Ctrl+n toggles the sidebar --
                // taken before the editor sees them so they work in any
                // mode. Modifiers arrive as their own key events, so the
                // listener's down-set is what answers "was ctrl held".
                const ctrl = self.listener.isKeyDown("left_control") or
                    self.listener.isKeyDown("right_control");
                if (ctrl) {
                    if (std.mem.eql(u8, k.key, "w")) {
                        self.focus = if (self.focus == .buffer) .tree else .buffer;
                        // Only the tree's selected-row highlight depends
                        // on focus; the buffer draws its caret the same
                        // in either pane.
                        self.tree_dirty = true;
                        self.status_dirty = true;
                        return;
                    }
                    if (std.mem.eql(u8, k.key, "n")) {
                        try self.toggleTree();
                        return;
                    }
                    // Ctrl+Tab / Ctrl+Shift+Tab walk the tab strip, the
                    // chord every tabbed application uses. Taken here so
                    // they work in insert mode too, where a bare Tab is
                    // still a Tab.
                    if (std.mem.eql(u8, k.key, "tab")) {
                        const back = self.listener.isKeyDown("left_shift") or
                            self.listener.isKeyDown("right_shift");
                        self.stepBuffer(!back);
                        return;
                    }
                    // Ctrl+Shift+X cut and Ctrl+Shift+P paste, both
                    // through the system clipboard. (Ctrl+Shift+C is
                    // swallowed by glyphwire-host, which broadcasts a
                    // `copy_request` instead -- see the `.copy_request`
                    // arm.)
                    const shift = self.listener.isKeyDown("left_shift") or
                        self.listener.isKeyDown("right_shift");
                    if (shift and self.focus == .buffer) {
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
                    try self.treeKey(k.key);
                    self.status_dirty = true;
                    return;
                }
                try self.applyOutcome(try self.buf.ed.feedKey(k.key, .{ .ctrl = ctrl }));
            },
            .text => |t| {
                self.buf.ed.status.clearRetainingCapacity();
                if (self.focus == .tree) {
                    try self.treeText(t.text);
                    self.status_dirty = true;
                    return;
                }
                try self.applyOutcome(try self.buf.ed.feedText(t.text));
            },
            .paste => |t| {
                self.buf.ed.status.clearRetainingCapacity();
                if (self.focus == .buffer) {
                    if (self.buf.ed.mode == .insert) {
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
            .copy_request => if (self.isVisible()) {
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
        // `:set lineno=…` moves the text origin, which a row shift can't
        // express -- the whole pane has to be re-laid-out. The setting
        // lives on the `Editor`, and there is one per buffer, so it is
        // pushed to all of them: `:set` reads as a session-wide switch,
        // not a per-tab one.
        if (after.line_numbers != before.line_numbers) {
            self.buf.full_redraw = true;
            for (self.buffers.items) |slot| {
                slot.ed.line_numbers = after.line_numbers;
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
    }

    fn toggleTree(self: *Ui) !void {
        self.tree_visible = !self.tree_visible;
        if (!self.tree_visible and self.focus == .tree) self.focus = .buffer;
        try self.applySplitChildren();
        // The buffer pane -- and the strip above it -- is about to be
        // re-laid-out wider or narrower.
        self.buf.full_redraw = true;
        self.buffer_dirty = true;
        self.tree_dirty = true;
        self.tabs_dirty = true;
        self.status_dirty = true;
    }

    // ── Tree pane input ─────────────────────────────────────────────────

    fn treeKey(self: *Ui, key: []const u8) !void {
        const eq = std.mem.eql;
        if (eq(u8, key, "down")) self.treeMove(1);
        if (eq(u8, key, "up")) self.treeMove(-1);
        if (eq(u8, key, "enter")) try self.treeActivate();
        if (eq(u8, key, "escape")) self.focus = .buffer;
        self.tree_dirty = true;
    }

    /// Tree navigation reuses vim's own keys, so switching panes doesn't
    /// switch keyboards.
    fn treeText(self: *Ui, text: []const u8) !void {
        var it = (std.unicode.Utf8View.init(text) catch return).iterator();
        while (it.nextCodepointSlice()) |cp| {
            if (cp.len != 1) continue;
            switch (cp[0]) {
                'j' => self.treeMove(1),
                'k' => self.treeMove(-1),
                'g' => self.tree.cursor = 0,
                'G' => self.tree.cursor = self.tree.len() -| 1,
                ' ', 'l' => try self.treeActivate(),
                'h' => self.treeMove(-1),
                'q' => self.focus = .buffer,
                else => {},
            }
        }
        self.tree_dirty = true;
    }

    fn treeMove(self: *Ui, delta: i64) void {
        const n = self.tree.len();
        if (n == 0) return;
        const next = @as(i64, @intCast(self.tree.cursor)) + delta;
        self.tree.cursor = @intCast(std.math.clamp(next, 0, @as(i64, @intCast(n - 1))));
        self.scrollTreeToCursor();
    }

    /// Keeps the tree's cursor inside the host-scrolled viewport by
    /// pushing a new `scroll_offset`, since the host has no idea zoe has
    /// a cursor.
    fn scrollTreeToCursor(self: *Ui) void {
        const rows = self.tree_bounds.rows;
        if (rows == 0) return;
        var top = self.tree_scroll.row;
        if (self.tree.cursor < top) top = self.tree.cursor;
        if (self.tree.cursor >= top + rows) top = self.tree.cursor - rows + 1;
        if (top == self.tree_scroll.row) return;

        self.tree_scroll.row = top;
        self.client.setLayerScrollOffset(self.tree_layer, top, self.tree_scroll.col) catch {};
    }

    /// Enter/Space on a directory expands it, on a file opens it.
    fn treeActivate(self: *Ui) !void {
        const entry = self.tree.at(self.tree.cursor) orelse return;
        if (entry.is_dir) {
            try self.tree.toggle(self.io, self.tree.cursor);
            try self.syncContentSizes();
            return;
        }
        try self.openFile(entry.path);
        self.focus = .buffer;
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
        return self.buf.ed.buf.lineStart(line) + byteAtDisplayCol(line_text, dcol);
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
        self.tree.cursor = index;
        self.focus = .tree;
        try self.treeActivate();
        self.tree_dirty = true;
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

        if (Tree.init(self.alloc, self.io, new_root)) |fresh| {
            self.tree.deinit();
            self.tree = fresh;
            self.tree_scroll = .{};
            self.client.setLayerScrollOffset(self.tree_layer, 0, 0) catch {};
            self.syncContentSizes() catch {};
        } else |_| {}

        self.tree_dirty = true;
        self.status_dirty = true;
        self.buf.ed.setStatus("{s}", .{new_root});
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

        const slot = try self.newSlot(path);
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

        // `loadText` re-owns the path, freeing the string `path` points
        // at, so everything below reads it back off the editor.
        try self.buf.ed.loadText(bytes, path);
        self.selectHighlightLanguage(self.buf, self.buf.ed.path);
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
        if (target) |t| self.buf.ed.setPath(t) catch {};
        self.buf.ed.markSaved();
        // The tab loses its `+`, and a `:w <name>` also renamed it.
        self.tabs_dirty = true;
        self.buf.ed.setStatus("\"{s}\" {d}L written", .{ dest, self.buf.ed.buf.lineCount() });
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

        if (self.buffer_dirty) try self.renderBuffer(&batch);
        if (self.tree_visible and self.tree_dirty) try self.renderTree(&batch);
        if (self.tabs_dirty) try self.renderTabs(&batch);
        if (self.status_dirty) try self.renderStatus(&batch);

        _ = try batch.send();

        self.buffer_dirty = false;
        self.tree_dirty = false;
        self.tabs_dirty = false;
        self.status_dirty = false;
    }

    /// Places the cursor on a layer, then writes one run there. Every
    /// write below goes through this: `write_text` is cursor-implicit, so
    /// a layer-scoped write is always a pair.
    fn writeAt(
        batch: *glyphwire.client.Client.Batch,
        layer: glyphwire.LayerHandle,
        row: usize,
        col: usize,
        text: []const u8,
        fg: Color,
        bg: Color,
    ) !void {
        try batch.notify("set_property", .{ .layer = layer, .property = "cursor", .row = row, .col = col });
        try batch.notify("write_text", .{
            .layer = layer,
            .text = text,
            .fg = .{ .r = fg.r, .g = fg.g, .b = fg.b, .a = fg.a },
            .bg = .{ .r = bg.r, .g = bg.g, .b = bg.b, .a = bg.a },
        });
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
        try self.syncBufferScrollbar();

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
        if (cursor.line >= self.buf.top_line and cursor.line < self.buf.top_line + b.rows) {
            const display_col = try self.cursorDisplayCol();
            if (display_col >= self.buf.left_col and display_col - self.buf.left_col < self.textCols()) {
                const under = try self.cursorGrapheme();
                defer self.alloc.free(under);
                try writeAt(
                    batch,
                    self.buffer_layer,
                    cursor.line - self.buf.top_line,
                    self.gutterWidth() + display_col - self.buf.left_col,
                    under,
                    fg_cursor,
                    bg_cursor,
                );
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

        if (!h.ready() or buf.edits_overflowed or buf.pending_edits.items.len == 0) {
            try h.reparse(buf);
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
    /// zero unless `:set`/`zoe.conf` turned it on. Widens by a column each
    /// time the line count crosses a power of ten; an edit that changes
    /// the count already forces a full pane repaint, so it is always safe
    /// to read fresh.
    fn gutterWidth(self: *const Ui) usize {
        return gutterWidthFor(self.buf.ed.line_numbers, self.buf.ed.buf.lineCount());
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

        var buf: [32]u8 = undefined;
        const cell = gutterCellText(&buf, self.buf.ed.line_numbers, width, line, cursor_line, past_end);
        const fg = if (!past_end and line == cursor_line) fg_text else fg_dim;
        try writeAt(batch, self.buffer_layer, r, 0, cell, fg, bg_buffer);
    }

    fn renderBufferRow(self: *Ui, batch: *glyphwire.client.Client.Batch, r: usize) !void {
        const line = self.buf.top_line + r;
        const gutter = self.gutterWidth();
        const cols = self.textCols();

        try self.renderGutterCell(batch, r);

        var pad: std.ArrayList(u8) = .empty;
        defer pad.deinit(self.alloc);

        if (line >= self.buf.ed.buf.lineCount()) {
            // vim's marker for "past the end of the buffer".
            try pad.append(self.alloc, '~');
            try padTo(self.alloc, &pad, 1, cols);
            try writeAt(batch, self.buffer_layer, r, gutter, pad.items, fg_dim, bg_buffer);
            return;
        }

        const text = try self.buf.ed.buf.lineText(self.alloc, line);
        defer self.alloc.free(text);

        // Highlighted rows are painted a colour run at a time; on any
        // failure (or with no grammar) fall through to one plain write.
        var painted = false;
        if (self.buf.hl) |*h| {
            if (h.ready() and self.renderRowSpans(batch, r, line, text)) painted = true;
        }
        if (!painted) {
            const visible = sliceCols(text, self.buf.left_col, cols);
            try pad.appendSlice(self.alloc, visible);
            try padTo(self.alloc, &pad, glyphwire.stringWidth(visible), cols);
            try writeAt(batch, self.buffer_layer, r, gutter, pad.items, fg_text, bg_buffer);
        }

        // Overpaint the selected span of this row, if any, with the
        // selection background. Done as a second write over the text just
        // laid down rather than threaded through every colour run.
        try self.paintSelectionRow(batch, r, line, text);
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

        const start_dc = displayColOfByte(text, @min(sel_lo_b, text.len));
        const end_dc = if (to_eol)
            self.buf.left_col + cols
        else
            displayColOfByte(text, @min(sel_hi_b, text.len));
        if (end_dc <= self.buf.left_col or start_dc >= self.buf.left_col + cols) return;

        const vis_lo = @max(start_dc, self.buf.left_col);
        const vis_hi = @min(end_dc, self.buf.left_col + cols);
        if (vis_hi <= vis_lo) return;

        // The characters under the highlight, then spaces out to the
        // selection's end (a linewise selection past the text, or the
        // newline slot of a charwise one).
        var overlay: std.ArrayList(u8) = .empty;
        defer overlay.deinit(self.alloc);
        const chars = sliceCols(text, vis_lo, vis_hi - vis_lo);
        try overlay.appendSlice(self.alloc, chars);
        try padTo(self.alloc, &overlay, glyphwire.stringWidth(chars), vis_hi - vis_lo);

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

    fn rowSpansImpl(
        self: *Ui,
        batch: *glyphwire.client.Client.Batch,
        r: usize,
        text: []const u8,
        spans: []const syntax.Span,
    ) !void {
        const cols = self.textCols();
        const left = self.buf.left_col;
        // Text starts after the line-number gutter (zero when it is off).
        const gutter = self.gutterWidth();

        const visible = sliceCols(text, left, cols);
        if (visible.len == 0) {
            // Line is entirely scrolled off to the left, or empty.
            try self.writeSpaces(batch, r, gutter, cols);
            return;
        }
        const vis_start_bo: usize = @intFromPtr(visible.ptr) - @intFromPtr(text.ptr);
        const vis_start_dc = displayColOfByte(text, vis_start_bo);

        // A double-width char straddling the left edge is dropped by
        // `sliceCols`; fill the gap it leaves so the text starts flush
        // against the gutter.
        if (vis_start_dc > left) {
            try self.writeSpaces(batch, r, gutter, vis_start_dc - left);
        }

        var run_buf: std.ArrayList(u8) = .empty;
        defer run_buf.deinit(self.alloc);
        var run_dc = vis_start_dc;
        var run_color: ?Color = null;
        var have_run = false;

        var dc = vis_start_dc;
        var i: usize = 0;
        while (i < visible.len) {
            const seq = std.unicode.utf8ByteSequenceLength(visible[i]) catch 1;
            const end = @min(i + seq, visible.len);
            const cp = std.unicode.utf8Decode(visible[i..end]) catch 0xFFFD;
            const w = glyphwire.codepointWidth(cp);

            const color = spanColorAt(spans, vis_start_bo + i);
            if (!have_run or !colorOptEql(color, run_color)) {
                if (have_run) try self.flushRun(batch, r, run_dc, run_buf.items, run_color);
                run_buf.clearRetainingCapacity();
                run_dc = dc;
                run_color = color;
                have_run = true;
            }
            try run_buf.appendSlice(self.alloc, visible[i..end]);
            dc += w;
            i = end;
        }
        if (have_run) try self.flushRun(batch, r, run_dc, run_buf.items, run_color);

        // Pad the rest of the row.
        if (dc < left + cols) {
            try self.writeSpaces(batch, r, gutter + dc - left, left + cols - dc);
        }
    }

    fn flushRun(
        self: *Ui,
        batch: *glyphwire.client.Client.Batch,
        r: usize,
        start_dc: usize,
        bytes: []const u8,
        color: ?Color,
    ) !void {
        if (bytes.len == 0 or start_dc < self.buf.left_col) return;
        const col = self.gutterWidth() + start_dc - self.buf.left_col;
        try writeAt(batch, self.buffer_layer, r, col, bytes, color orelse fg_text, bg_buffer);
    }

    fn writeSpaces(self: *Ui, batch: *glyphwire.client.Client.Batch, r: usize, col: usize, n: usize) !void {
        if (n == 0) return;
        var pad: std.ArrayList(u8) = .empty;
        defer pad.deinit(self.alloc);
        try pad.appendNTimes(self.alloc, ' ', n);
        try writeAt(batch, self.buffer_layer, r, col, pad.items, fg_text, bg_buffer);
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
    /// `drainEvents`).
    fn syncBufferScrollbar(self: *Ui) !void {
        const b = self.buffer_bounds;
        const now: [4]usize = .{ self.buf.ed.buf.lineCount(), b.cols, self.buf.top_line, self.buf.left_col };
        if (std.mem.eql(usize, &now, &self.buf.pushed_bar)) return;

        if (now[0] != self.buf.pushed_bar[0] or now[1] != self.buf.pushed_bar[1]) {
            try self.client.setLayerContentExtent(self.buffer_layer, now[1], now[0]);
        }
        try self.client.setLayerScrollOffset(self.buffer_layer, self.buf.top_line, self.buf.left_col);
        self.buf.pushed_bar = now;
    }

    /// The caret's column in *display* cells, which is not its byte
    /// column once a line holds anything multi-byte or double-width.
    fn cursorDisplayCol(self: *Ui) !usize {
        const pos = self.buf.ed.pos();
        const start = self.buf.ed.buf.lineStart(pos.line);
        const text = try self.buf.ed.buf.gap.read(self.alloc, start, start + pos.col);
        defer self.alloc.free(text);
        return glyphwire.stringWidth(text);
    }

    /// The grapheme the caret sits on, or a space at end of line.
    fn cursorGrapheme(self: *Ui) ![]u8 {
        const c = self.buf.ed.cursor;
        if (c >= self.buf.ed.buf.len() or self.buf.ed.buf.byteAt(c) == '\n') {
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
        const content_cols = @max(self.tree.widestCols(), b.cols);
        const content_rows = @max(self.tree.len(), b.rows);

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
                const width = e.depth * tree_mod.indent_cols + tree_mod.icon_cols + glyphwire.stringWidth(e.name);
                try padTo(self.alloc, &line, width, content_cols);
                try writeAt(batch, self.tree_layer, r, 0, line.items, if (e.is_dir) fg_dir else fg_text, bg);

                // The icon composites *over* the row's background rather
                // than replacing it, so a selected row stays highlighted
                // underneath it. Sized exactly like `glyphwire-ls`'s
                // small-table icons: natural, capped in *height* to one
                // row and free to overflow its column in width (a plain
                // `"fit"` shrinks a 32px source to the ~8px a cell is wide
                // and is unreadable). Only `max_h` -- adding `max_w` would
                // shrink it back to the narrow cell width. Falls back to
                // `"fit"` if the cell metrics somehow didn't load.
                const natural = self.cell_px_h > 0;
                try batch.notify("draw_icon", .{
                    .layer = self.tree_layer,
                    .row = r,
                    .col = e.depth * tree_mod.indent_cols,
                    .name = iconFor(e),
                    .scale = if (natural) "natural" else "fit",
                    .h_align = "start",
                    .v_align = "center",
                    .max_h = if (natural) self.cell_px_h else null,
                    .foreground = true,
                });
            } else {
                try padTo(self.alloc, &line, 0, content_cols);
                try writeAt(batch, self.tree_layer, r, 0, line.items, fg_dim, bg_tree);
            }
        }
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
        try self.syncTabScrollbar();

        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(self.alloc);

        try text.appendNTimes(self.alloc, ' ', b.cols);
        try writeAt(batch, self.tabs_layer, 0, 0, text.items, fg_dim, bg_tab_bar);

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

        const slice = text[byteAtDisplayCol(text, lo - start)..byteAtDisplayCol(text, hi - start)];
        try writeAt(batch, self.tabs_layer, 0, lo - view_lo, slice, fg, bg);
    }

    /// Keeps the tabs layer's virtual extent and offset in step with the
    /// strip, the same arrangement the buffer pane has: the layer's grid
    /// is only pane-wide, and reporting the strip's real width is what
    /// lets the host turn a shift+wheel or a drag over it into the
    /// `scroll_offset` `drainEvents` follows. Silent when nothing moved.
    fn syncTabScrollbar(self: *Ui) !void {
        const now: [2]usize = .{ self.tab_total, self.tab_scroll };
        if (std.mem.eql(usize, &now, &self.pushed_tab_bar)) return;

        if (now[0] != self.pushed_tab_bar[0]) {
            try self.client.setLayerContentExtent(
                self.tabs_layer,
                @max(self.tab_total, self.tabs_bounds.cols),
                1,
            );
        }
        try self.client.setLayerScrollOffset(self.tabs_layer, 0, self.tab_scroll);
        self.pushed_tab_bar = now;
    }

    fn renderStatus(self: *Ui, batch: *glyphwire.client.Client.Batch) !void {
        const b = self.status_bounds;
        if (b.cols == 0) return;

        var line: std.ArrayList(u8) = .empty;
        defer line.deinit(self.alloc);
        var fg = fg_status;

        if (self.buf.ed.mode == .command) {
            try line.append(self.alloc, ':');
            try line.appendSlice(self.alloc, self.buf.ed.cmdline.items);
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
            // The position is right-aligned, so the mode and filename on
            // the left don't shift it around as they change length.
            var right: [48]u8 = undefined;
            const tail = std.fmt.bufPrint(&right, "{d}:{d} ", .{ pos.line + 1, pos.col + 1 }) catch "";
            const used = glyphwire.stringWidth(line.items) + glyphwire.stringWidth(tail);
            if (used < b.cols) try line.appendNTimes(self.alloc, ' ', b.cols - used);
            try line.appendSlice(self.alloc, tail);
        }

        try padTo(self.alloc, &line, glyphwire.stringWidth(line.items), b.cols);
        try writeAt(batch, self.status_layer, 0, 0, line.items, fg, bg_status);

        // The mode word gets its own colour, over the top of the run just
        // written -- cheaper than splitting the line into two runs.
        if (self.buf.ed.mode != .command and self.buf.ed.status.items.len == 0) {
            try writeAt(batch, self.status_layer, 0, 1, modeName(self.buf.ed.mode), fg_mode, bg_status);
        }
    }

    fn modeName(mode: editor.Mode) []const u8 {
        return switch (mode) {
            .normal => "NORMAL",
            .insert => "INSERT",
            .command => "COMMAND",
            .visual => "VISUAL",
            .visual_line => "V-LINE",
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

/// Pads `line` with spaces from `width` display cells out to `target`.
fn padTo(alloc: std.mem.Allocator, line: *std.ArrayList(u8), width: usize, target: usize) !void {
    if (width >= target) return;
    try line.appendNTimes(alloc, ' ', target - width);
}

/// The byte offset in `text` at display column `col` -- the inverse of
/// `displayColOfByte`, clamped to the end of the text. A column that
/// falls on the trailing half of a wide character resolves to that
/// character's start. Used to turn a mouse cell into a buffer position.
fn byteAtDisplayCol(text: []const u8, col: usize) usize {
    var c: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        const seq = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
        const end = @min(i + seq, text.len);
        const cp = std.unicode.utf8Decode(text[i..end]) catch 0xFFFD;
        const w = glyphwire.codepointWidth(cp);
        if (c + w > col) return i;
        c += w;
        i = end;
    }
    return text.len;
}

/// The display column at which byte `off` of `text` sits -- the summed
/// width of every codepoint before it. Used to place the first colour
/// run of a horizontally-scrolled row.
fn displayColOfByte(text: []const u8, off: usize) usize {
    var col: usize = 0;
    var i: usize = 0;
    while (i < off and i < text.len) {
        const seq = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
        const end = @min(i + seq, text.len);
        const cp = std.unicode.utf8Decode(text[i..end]) catch 0xFFFD;
        col += glyphwire.codepointWidth(cp);
        i = end;
    }
    return col;
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

/// The slice of `text` starting at display column `start` and at most
/// `max` columns wide.
///
/// Display columns, not bytes: a line of CJK is half as many columns as
/// it is codepoints, and clipping by bytes would cut a character in half.
/// A double-width character straddling either edge is dropped rather than
/// half-drawn.
pub fn sliceCols(text: []const u8, start: usize, max: usize) []const u8 {
    var col: usize = 0;
    var from: ?usize = null;
    var i: usize = 0;

    while (i < text.len) {
        const seq = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
        const end = @min(i + seq, text.len);
        const cp = std.unicode.utf8Decode(text[i..end]) catch 0xFFFD;
        const w = glyphwire.codepointWidth(cp);

        if (from == null and col >= start) from = i;
        if (from != null and col + w > start + max) return text[from.?..i];
        col += w;
        i = end;
    }
    return if (from) |f| text[f..] else text[text.len..];
}
