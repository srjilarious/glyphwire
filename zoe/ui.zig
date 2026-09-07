//! zoe's glyphwire client: three panes in a split tree, the render pass
//! that fills them, and the input loop that drives the editor.
//!
//! The layout is a `column` split holding a `row` split (tree beside
//! buffer) above a one-row statusline. The host owns it: zoe describes it
//! once at startup, and after that a window resize or a divider drag
//! arrives as a `layout` notification saying where each pane ended up.
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

const Editor = editor.Editor;
const Tree = tree_mod.Tree;
const Color = glyphwire.Color;

/// Cells the tree pane occupies until a divider drag says otherwise.
const default_tree_cols: usize = 28;

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

/// A pane's bounds, mirrored from the last `layout` notification.
const Bounds = struct {
    row: usize = 0,
    col: usize = 0,
    cols: usize = 0,
    rows: usize = 0,
};

const Focus = enum { buffer, tree };

pub const Ui = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    client: *glyphwire.Client,
    listener: *glyphwire.InputListener,
    ed: *Editor,
    tree: Tree,

    /// zoe's own context -- an alt-screen-style full-window surface, not
    /// a set of layers stacked over the shell's scrollback. Everything
    /// below (layers, splits) lives in it, and `destroyContext` on exit
    /// tears the whole thing down and drops visibility back to the shell.
    context: glyphwire.ContextHandle,
    tree_layer: glyphwire.LayerHandle,
    buffer_layer: glyphwire.LayerHandle,
    status_layer: glyphwire.LayerHandle,
    pane_split: glyphwire.SplitHandle,
    root_split: glyphwire.SplitHandle,

    tree_bounds: Bounds = .{},
    buffer_bounds: Bounds = .{},
    status_bounds: Bounds = .{},

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
    /// Forces a full buffer repaint next frame -- set whenever the pane's
    /// bounds change or its content is replaced wholesale, cases a row
    /// shift can't express.
    buffer_full_redraw: bool = true,
    /// The `(content rows, content cols, scroll row, scroll col)` last
    /// pushed to the buffer layer for its host-drawn scrollbar. Re-pushed
    /// only when one of them changes -- see `syncBufferScrollbar`.
    pushed_bar: [4]usize = .{ std.math.maxInt(usize), 0, 0, 0 },
    /// Session cell height in px, for natural-sizing tree icons to the
    /// row height. Read once at startup; a runtime font-zoom isn't
    /// announced to clients, so it can lag until the next launch.
    cell_px_h: u32 = 0,
    /// The tree pane's scroll offset, mirrored from `scroll_offset`
    /// notifications so a click can be resolved to the right entry.
    tree_scroll: glyphwire.CellPos = .{},

    focus: Focus = .buffer,
    tree_visible: bool = true,
    /// Set by anything that changes what should be on screen; cleared by
    /// `render`. One redraw per input burst rather than one per event.
    dirty: bool = true,
    quit: bool = false,

    /// tree-sitter syntax highlighting. All four are null / empty when
    /// highlighting is off -- no grammar directory resolved, or
    /// `Highlighter.init` failed -- and the buffer renders in plain
    /// `fg_text`. `hl_config`'s arena backs `grammars`' language table,
    /// so it outlives the registry. See syntax.zig.
    hl_config: ?langconf.Config = null,
    grammars: ?syntax.Registry = null,
    hl: ?syntax.Highlighter = null,
    hl_search_dirs: []const []const u8 = &.{},
    /// The `Buffer.edits` value the current parse tree reflects; a
    /// mismatch in `renderBuffer` triggers a reparse.
    hl_edits: u64 = 0,
    /// Reused span buffer for `renderRowSpans`.
    hl_scratch: std.ArrayList(syntax.Span) = .empty,

    pub fn init(
        alloc: std.mem.Allocator,
        io: std.Io,
        client: *glyphwire.Client,
        listener: *glyphwire.InputListener,
        ed: *Editor,
        root_dir: []const u8,
        environ: *const std.process.Environ.Map,
    ) !*Ui {
        const self = try alloc.create(Ui);
        errdefer alloc.destroy(self);

        // A dedicated context for the editor, shown immediately. From
        // here on every layer/split call on `client` targets it, not the
        // shell's context. The paired listener joins it too so its input
        // subscriptions follow this context's visibility.
        const context = try client.createContext(null, null, 0);
        errdefer client.destroyContext(context) catch {};
        try listener.attachContext(context);

        const size = try client.getSize();
        const metrics = try client.getCellMetrics();

        // Content sizes are provisional: every `layout` notification
        // resizes them to match the panes they landed in.
        const tree_layer = try client.createLayer(default_tree_cols, size.rows, 0);
        const buffer_layer = try client.createLayer(size.cols, size.rows, 0);
        const status_layer = try client.createLayer(size.cols, 1, 0);

        // The tree is host-scrolled (both bars). The buffer scrolls
        // itself, but a `content_extent` (pushed each frame from the line
        // count -- see `syncBufferScrollbar`) lets the host draw a
        // proportional vertical bar and turn a wheel or thumb drag over
        // the pane into a `scroll_offset` zoe then follows.
        try client.setLayerScrollbars(tree_layer, true, true);
        try client.setLayerScrollbars(buffer_layer, true, false);

        const pane_split = try client.createSplit(.row);
        const root_split = try client.createSplit(.column);

        self.* = .{
            .alloc = alloc,
            .io = io,
            .client = client,
            .listener = listener,
            .ed = ed,
            .tree = try Tree.init(alloc, io, root_dir),
            .context = context,
            .tree_layer = tree_layer,
            .buffer_layer = buffer_layer,
            .status_layer = status_layer,
            .pane_split = pane_split,
            .root_split = root_split,
            .cell_px_h = metrics.h,
        };
        errdefer self.tree.deinit();

        try self.applySplitChildren();
        try client.setSplitChildren(root_split, &.{
            glyphwire.SplitChildInput.splitWeighted(pane_split, 1),
            // The statusline is `fixed`, not a weight: one row is one row
            // whatever the window does.
            glyphwire.SplitChildInput.layerFixed(status_layer, 1),
        });
        try client.setRootSplit(root_split);

        // Best-effort: highlighting off is a valid state, never a reason
        // to fail bringing the editor up.
        self.setupHighlight(environ);

        // The `layout` broadcast goes to *other* connections, and the
        // listener is one -- but reading the bounds back directly avoids
        // a startup frame drawn against guesses.
        try self.readBounds();
        return self;
    }

    /// Loads `zoe.conf`, resolves the grammar search path, and builds the
    /// registry + highlighter. Any failure leaves all of it null and the
    /// buffer renders unhighlighted.
    fn setupHighlight(self: *Ui, environ: *const std.process.Environ.Map) void {
        var cfg = langconf.load(self.alloc, self.io, environ);

        const dirs = syntax.searchDirs(self.alloc, self.io, environ, cfg.grammar_dirs) catch {
            cfg.deinit();
            return;
        };

        const hl = syntax.Highlighter.init(self.alloc, cfg.theme) catch {
            for (dirs) |d| self.alloc.free(d);
            self.alloc.free(dirs);
            cfg.deinit();
            return;
        };

        self.hl_search_dirs = dirs;
        self.grammars = syntax.Registry.init(self.alloc, self.io, dirs, cfg.langs);
        self.hl = hl;
        self.hl_config = cfg;

        self.selectHighlightLanguage(self.ed.path);
    }

    /// Points the highlighter at the grammar for `path` (by extension),
    /// or clears it. Cheap and idempotent -- also called from `openFile`.
    fn selectHighlightLanguage(self: *Ui, path: ?[]const u8) void {
        const h = if (self.hl) |*x| x else return;
        const reg = if (self.grammars) |*x| x else return;

        h.clearLanguage();
        const p = path orelse return;
        const name = reg.nameForPath(p) orelse return;
        const grammar = reg.get(name) orelse return;
        h.setLanguage(name, grammar) catch return;

        // Nudge `hl_edits` off the buffer's value so the next
        // `renderBuffer` parses.
        self.hl_edits = self.ed.buf.edits -% 1;
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

        self.hl_scratch.deinit(self.alloc);
        if (self.hl) |*h| h.deinit();
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
                glyphwire.SplitChildInput.layerWeighted(self.buffer_layer, 1),
            });
        } else {
            try self.client.setSplitChildren(self.pane_split, &.{
                glyphwire.SplitChildInput.layerWeighted(self.buffer_layer, 1),
            });
        }
    }

    /// Reads each pane's bounds straight from the server -- used once at
    /// startup; after that `layout` notifications keep them current.
    fn readBounds(self: *Ui) !void {
        self.tree_bounds = try self.boundsOf(self.tree_layer);
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
            if (self.dirty) try self.render();
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
            if (ev.boundsFor(self.buffer_layer)) |b| self.buffer_bounds = toBounds(b);
            if (ev.boundsFor(self.status_layer)) |b| self.status_bounds = toBounds(b);
            try self.syncContentSizes();
            // The buffer layer's grid was resized: the rows it holds no
            // longer line up with the panes, so the next frame can't
            // shift them -- it has to repaint.
            self.buffer_full_redraw = true;
            self.dirty = true;
        }
        while (self.listener.pollScrollOffsetEvent()) |ev| {
            if (ev.layer == self.tree_layer) self.tree_scroll = .{ .row = ev.row, .col = ev.col };
            // A wheel or thumb drag over the buffer pane: the host moved
            // the virtual offset and told us where. Follow it, and drag
            // the cursor along so it stays on screen (like vim's Ctrl-E /
            // Ctrl-Y). `pushed_bar` is updated so `syncBufferScrollbar`
            // doesn't immediately echo this straight back.
            if (ev.layer == self.buffer_layer) self.scrollBufferTo(ev.row, ev.col);
        }
        while (self.listener.pollMouseButtonEvent()) |ev| {
            defer ev.deinit(self.alloc);
            if (ev.pressed) try self.handleClick(ev);
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
                self.ed.status.clearRetainingCapacity();

                // Ctrl+w switches panes, Ctrl+n toggles the sidebar --
                // taken before the editor sees them so they work in any
                // mode. Modifiers arrive as their own key events, so the
                // listener's down-set is what answers "was ctrl held".
                if (self.listener.isKeyDown("left_control") or self.listener.isKeyDown("right_control")) {
                    if (std.mem.eql(u8, k.key, "w")) {
                        self.focus = if (self.focus == .buffer) .tree else .buffer;
                        self.dirty = true;
                        return;
                    }
                    if (std.mem.eql(u8, k.key, "n")) {
                        try self.toggleTree();
                        return;
                    }
                }
                if (self.focus == .tree) return self.treeKey(k.key);
                try self.applyOutcome(try self.ed.feedKey(k.key, .{}));
            },
            .text => |t| {
                self.ed.status.clearRetainingCapacity();
                if (self.focus == .tree) return self.treeText(t.text);
                try self.applyOutcome(try self.ed.feedText(t.text));
            },
            .paste => |t| {
                self.ed.status.clearRetainingCapacity();
                if (self.focus == .buffer) try self.applyOutcome(try self.ed.feedText(t.text));
            },
            .copy_request => {},
        }
        self.dirty = true;
    }

    fn toggleTree(self: *Ui) !void {
        self.tree_visible = !self.tree_visible;
        if (!self.tree_visible and self.focus == .tree) self.focus = .buffer;
        try self.applySplitChildren();
        // The buffer pane is about to be re-laid-out wider or narrower.
        self.buffer_full_redraw = true;
        self.dirty = true;
    }

    // ── Tree pane input ─────────────────────────────────────────────────

    fn treeKey(self: *Ui, key: []const u8) !void {
        const eq = std.mem.eql;
        if (eq(u8, key, "down")) self.treeMove(1);
        if (eq(u8, key, "up")) self.treeMove(-1);
        if (eq(u8, key, "enter")) try self.treeActivate();
        if (eq(u8, key, "escape")) self.focus = .buffer;
        self.dirty = true;
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
        self.dirty = true;
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

    fn handleClick(self: *Ui, ev: glyphwire.MouseButtonEvent) !void {
        if (!std.mem.eql(u8, ev.button, "left")) return;
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
        self.dirty = true;
    }

    // ── Editor outcomes ─────────────────────────────────────────────────

    fn applyOutcome(self: *Ui, outcome: editor.Outcome) !void {
        switch (outcome) {
            .none => {},
            .write => |target| self.save(target),
            .write_quit => |target| {
                self.save(target);
                if (!self.ed.buf.dirty) self.quit = true;
            },
            .quit => self.quit = true,
            .edit => |target| {
                const path = target orelse self.ed.path orelse {
                    self.ed.setStatus("E32: No file name", .{});
                    return;
                };
                try self.openFile(path);
            },
        }
    }

    fn openFile(self: *Ui, path: []const u8) !void {
        const bytes = std.Io.Dir.cwd().readFileAlloc(self.io, path, self.alloc, .limited(64 * 1024 * 1024)) catch {
            self.ed.setStatus("E484: Can't open file {s}", .{path});
            return;
        };
        defer self.alloc.free(bytes);

        try self.ed.loadText(bytes, path);
        self.selectHighlightLanguage(path);
        self.top_line = 0;
        self.left_col = 0;
        // A whole new buffer -- nothing on screen carries over.
        self.buffer_full_redraw = true;
        self.ed.setStatus("\"{s}\" {d}L", .{ path, self.ed.buf.lineCount() });
        self.dirty = true;
    }

    fn save(self: *Ui, target: ?[]const u8) void {
        const dest = target orelse self.ed.path orelse {
            self.ed.setStatus("E32: No file name", .{});
            return;
        };
        const bytes = self.ed.buf.text(self.alloc) catch return;
        defer self.alloc.free(bytes);

        std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = dest, .data = bytes }) catch {
            self.ed.setStatus("E212: Can't open file for writing: {s}", .{dest});
            return;
        };
        if (target) |t| self.ed.setPath(t) catch {};
        self.ed.markSaved();
        self.ed.setStatus("\"{s}\" {d}L written", .{ dest, self.ed.buf.lineCount() });
    }

    // ── Render ──────────────────────────────────────────────────────────

    /// One batch for the whole frame, so the panes go from the previous
    /// state to this one in a single rendered frame rather than a band at
    /// a time (decisions.md's Batch section).
    fn render(self: *Ui) !void {
        self.dirty = false;
        var batch = self.client.batch();
        defer batch.deinit();

        try self.renderBuffer(&batch);
        if (self.tree_visible) try self.renderTree(&batch);
        try self.renderStatus(&batch);

        _ = try batch.send();
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
    /// bounds change (`buffer_full_redraw`) still repaints in full --
    /// cases a row shift can't represent.
    fn renderBuffer(self: *Ui, batch: *glyphwire.client.Client.Batch) !void {
        const b = self.buffer_bounds;
        if (b.cols == 0 or b.rows == 0) return;
        self.scrollBufferToCursor();
        try self.syncBufferScrollbar();

        // A fresh edit (or the first parse after choosing a language)
        // means the tree is stale: reparse the whole buffer and repaint.
        // Full reparse per edit is the v1 model -- see syntax.zig.
        if (self.hl) |*h| {
            if (h.languageSet() and self.ed.buf.edits != self.hl_edits) {
                h.reparse(&self.ed.buf) catch {};
                self.hl_edits = self.ed.buf.edits;
                self.buffer_full_redraw = true;
            }
        }

        const cursor = self.ed.pos();
        switch (planBufferRender(.{
            .prev_top = self.prev_top_line,
            .top = self.top_line,
            .prev_left = self.prev_left_col,
            .left = self.left_col,
            .prev_edits = self.prev_edits,
            .edits = self.ed.buf.edits,
            .rows = b.rows,
            .force_full = self.buffer_full_redraw,
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
                for ([_]usize{ self.prev_cursor_line, cursor.line }) |line| {
                    if (line < self.top_line or line >= self.top_line + b.rows) continue;
                    const screen_row = line - self.top_line;
                    if (screen_row >= s.exposed_lo and screen_row < s.exposed_hi) continue;
                    try self.renderBufferRow(batch, screen_row);
                }
            },
        }

        // The caret is a block drawn as one inverted cell, on top of the
        // row just (re)painted. The host's own caret renderer only knows
        // about the root layer, and a client that owns its pane knows
        // better than the host where its cursor is anyway.
        if (cursor.line >= self.top_line and cursor.line < self.top_line + b.rows) {
            const display_col = try self.cursorDisplayCol();
            if (display_col >= self.left_col and display_col - self.left_col < b.cols) {
                const under = try self.cursorGrapheme();
                defer self.alloc.free(under);
                try writeAt(
                    batch,
                    self.buffer_layer,
                    cursor.line - self.top_line,
                    display_col - self.left_col,
                    under,
                    fg_cursor,
                    bg_cursor,
                );
            }
        }

        self.prev_top_line = self.top_line;
        self.prev_left_col = self.left_col;
        self.prev_cursor_line = cursor.line;
        self.prev_edits = self.ed.buf.edits;
        self.buffer_full_redraw = false;
    }

    /// Repaints buffer-pane screen rows `[from, to)` from the buffer's
    /// current contents -- plain text, or vim's `~` past the end, without
    /// the caret.
    fn renderBufferRows(self: *Ui, batch: *glyphwire.client.Client.Batch, from: usize, to: usize) !void {
        var r = from;
        while (r < to) : (r += 1) try self.renderBufferRow(batch, r);
    }

    fn renderBufferRow(self: *Ui, batch: *glyphwire.client.Client.Batch, r: usize) !void {
        const b = self.buffer_bounds;
        const line = self.top_line + r;

        var pad: std.ArrayList(u8) = .empty;
        defer pad.deinit(self.alloc);

        if (line >= self.ed.buf.lineCount()) {
            // vim's marker for "past the end of the buffer".
            try pad.append(self.alloc, '~');
            try padTo(self.alloc, &pad, 1, b.cols);
            try writeAt(batch, self.buffer_layer, r, 0, pad.items, fg_dim, bg_buffer);
            return;
        }

        const text = try self.ed.buf.lineText(self.alloc, line);
        defer self.alloc.free(text);

        // Highlighted rows are painted a colour run at a time; on any
        // failure (or with no grammar) fall through to one plain write.
        if (self.hl) |*h| {
            if (h.ready() and self.renderRowSpans(batch, r, line, text)) return;
        }

        const visible = sliceCols(text, self.left_col, b.cols);
        try pad.appendSlice(self.alloc, visible);
        try padTo(self.alloc, &pad, glyphwire.stringWidth(visible), b.cols);
        try writeAt(batch, self.buffer_layer, r, 0, pad.items, fg_text, bg_buffer);
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
        const h = &self.hl.?;
        const ls = self.ed.buf.lineStart(line);
        const le = self.ed.buf.lineEnd(line);
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
        const cols = self.buffer_bounds.cols;
        const left = self.left_col;

        const visible = sliceCols(text, left, cols);
        if (visible.len == 0) {
            // Line is entirely scrolled off to the left, or empty.
            try self.writeSpaces(batch, r, 0, cols);
            return;
        }
        const vis_start_bo: usize = @intFromPtr(visible.ptr) - @intFromPtr(text.ptr);
        const vis_start_dc = displayColOfByte(text, vis_start_bo);

        // A double-width char straddling the left edge is dropped by
        // `sliceCols`; fill the gap it leaves so the row starts at col 0.
        if (vis_start_dc > left) {
            try self.writeSpaces(batch, r, 0, vis_start_dc - left);
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
            try self.writeSpaces(batch, r, dc - left, left + cols - dc);
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
        if (bytes.len == 0 or start_dc < self.left_col) return;
        try writeAt(batch, self.buffer_layer, r, start_dc - self.left_col, bytes, color orelse fg_text, bg_buffer);
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
        const pos = self.ed.pos();

        if (pos.line < self.top_line) self.top_line = pos.line;
        if (pos.line >= self.top_line + b.rows) self.top_line = pos.line - b.rows + 1;

        const col = self.cursorDisplayCol() catch return;
        if (col < self.left_col) self.left_col = col;
        if (col >= self.left_col + b.cols) self.left_col = col - b.cols + 1;
    }

    /// Applies a host-driven scroll of the buffer pane (wheel or thumb
    /// drag): moves the view and drags the cursor back onto it, keeping
    /// its column. Records the new position as already pushed so the next
    /// `syncBufferScrollbar` doesn't bounce it back to the host.
    fn scrollBufferTo(self: *Ui, row: usize, col: usize) void {
        const b = self.buffer_bounds;
        if (b.rows == 0) return;
        self.top_line = row;
        self.left_col = col;

        const cur = self.ed.pos();
        const last = self.ed.buf.lineCount() -| 1;
        const clamped_line = std.math.clamp(cur.line, row, @min(row + b.rows - 1, last));
        if (clamped_line != cur.line) {
            self.ed.cursor = self.ed.buf.offsetOf(.{ .line = clamped_line, .col = cur.col });
        }
        self.pushed_bar = .{ self.ed.buf.lineCount(), b.cols, self.top_line, self.left_col };
        self.dirty = true;
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
        const now: [4]usize = .{ self.ed.buf.lineCount(), b.cols, self.top_line, self.left_col };
        if (std.mem.eql(usize, &now, &self.pushed_bar)) return;

        if (now[0] != self.pushed_bar[0] or now[1] != self.pushed_bar[1]) {
            try self.client.setLayerContentExtent(self.buffer_layer, now[1], now[0]);
        }
        try self.client.setLayerScrollOffset(self.buffer_layer, self.top_line, self.left_col);
        self.pushed_bar = now;
    }

    /// The caret's column in *display* cells, which is not its byte
    /// column once a line holds anything multi-byte or double-width.
    fn cursorDisplayCol(self: *Ui) !usize {
        const pos = self.ed.pos();
        const start = self.ed.buf.lineStart(pos.line);
        const text = try self.ed.buf.gap.read(self.alloc, start, start + pos.col);
        defer self.alloc.free(text);
        return glyphwire.stringWidth(text);
    }

    /// The grapheme the caret sits on, or a space at end of line.
    fn cursorGrapheme(self: *Ui) ![]u8 {
        const c = self.ed.cursor;
        if (c >= self.ed.buf.len() or self.ed.buf.byteAt(c) == '\n') {
            return self.alloc.dupe(u8, " ");
        }
        const seq = std.unicode.utf8ByteSequenceLength(self.ed.buf.byteAt(c)) catch 1;
        return self.ed.buf.gap.read(self.alloc, c, c + seq);
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

    fn renderStatus(self: *Ui, batch: *glyphwire.client.Client.Batch) !void {
        const b = self.status_bounds;
        if (b.cols == 0) return;

        var line: std.ArrayList(u8) = .empty;
        defer line.deinit(self.alloc);
        var fg = fg_status;

        if (self.ed.mode == .command) {
            try line.append(self.alloc, ':');
            try line.appendSlice(self.alloc, self.ed.cmdline.items);
        } else if (self.ed.status.items.len > 0) {
            if (std.mem.startsWith(u8, self.ed.status.items, "E")) fg = fg_error;
            try line.appendSlice(self.alloc, self.ed.status.items);
        } else {
            const pos = self.ed.pos();
            try line.print(self.alloc, " {s}  {s}{s}", .{
                modeName(self.ed.mode),
                self.ed.path orelse "[No Name]",
                if (self.ed.buf.dirty) " [+]" else "",
            });
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
        if (self.ed.mode != .command and self.ed.status.items.len == 0) {
            try writeAt(batch, self.status_layer, 0, 1, modeName(self.ed.mode), fg_mode, bg_status);
        }
    }

    fn modeName(mode: editor.Mode) []const u8 {
        return switch (mode) {
            .normal => "NORMAL",
            .insert => "INSERT",
            .command => "COMMAND",
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

/// Pads `line` with spaces from `width` display cells out to `target`.
fn padTo(alloc: std.mem.Allocator, line: *std.ArrayList(u8), width: usize, target: usize) !void {
    if (width >= target) return;
    try line.appendNTimes(alloc, ' ', target - width);
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
