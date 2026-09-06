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
//! owns `top_line`/`left_col`, and it redraws the visible rows. See
//! docs/investigations/zoe-editor.md for what that costs and what would
//! fix it.

const std = @import("std");
const glyphwire = @import("glyphwire");
const ls_icons = @import("ls_support").icons;

const editor = @import("editor.zig");
const tree_mod = @import("tree.zig");

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
    /// The tree pane's scroll offset, mirrored from `scroll_offset`
    /// notifications so a click can be resolved to the right entry.
    tree_scroll: glyphwire.CellPos = .{},

    focus: Focus = .buffer,
    tree_visible: bool = true,
    /// Set by anything that changes what should be on screen; cleared by
    /// `render`. One redraw per input burst rather than one per event.
    dirty: bool = true,
    quit: bool = false,

    pub fn init(
        alloc: std.mem.Allocator,
        io: std.Io,
        client: *glyphwire.Client,
        listener: *glyphwire.InputListener,
        ed: *Editor,
        root_dir: []const u8,
    ) !*Ui {
        const self = try alloc.create(Ui);
        errdefer alloc.destroy(self);

        const size = try client.getSize();

        // Content sizes are provisional: every `layout` notification
        // resizes them to match the panes they landed in.
        const tree_layer = try client.createLayer(default_tree_cols, size.rows, 0);
        const buffer_layer = try client.createLayer(size.cols, size.rows, 0);
        const status_layer = try client.createLayer(size.cols, 1, 0);

        // Only the tree is host-scrolled, so only the tree gets bars.
        try client.setLayerScrollbars(tree_layer, true, true);

        const pane_split = try client.createSplit(.row);
        const root_split = try client.createSplit(.column);

        self.* = .{
            .alloc = alloc,
            .io = io,
            .client = client,
            .listener = listener,
            .ed = ed,
            .tree = try Tree.init(alloc, io, root_dir),
            .tree_layer = tree_layer,
            .buffer_layer = buffer_layer,
            .status_layer = status_layer,
            .pane_split = pane_split,
            .root_split = root_split,
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

        // The `layout` broadcast goes to *other* connections, and the
        // listener is one -- but reading the bounds back directly avoids
        // a startup frame drawn against guesses.
        try self.readBounds();
        return self;
    }

    /// Tears down what `init` built on the server, not just this
    /// process's own memory -- otherwise the split tree and its layers
    /// outlive the connection that made them: nothing else ever destroys
    /// them, so the host keeps compositing zoe's last frame over the
    /// shell forever after zoe exits. Best-effort (the connection may
    /// already be going away) and order matters: the root has to stop
    /// pointing at `root_split` before the splits themselves can go.
    pub fn deinit(self: *Ui) void {
        self.client.setRootSplit(null) catch {};
        self.client.destroySplit(self.pane_split) catch {};
        self.client.destroySplit(self.root_split) catch {};
        self.client.destroyLayer(self.tree_layer) catch {};
        self.client.destroyLayer(self.buffer_layer) catch {};
        self.client.destroyLayer(self.status_layer) catch {};
        self.tree.deinit();
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
            self.dirty = true;
        }
        while (self.listener.pollScrollOffsetEvent()) |ev| {
            if (ev.layer == self.tree_layer) self.tree_scroll = .{ .row = ev.row, .col = ev.col };
        }
        while (self.listener.pollMouseButtonEvent()) |ev| {
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
        self.top_line = 0;
        self.left_col = 0;
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

    fn renderBuffer(self: *Ui, batch: *glyphwire.client.Client.Batch) !void {
        const b = self.buffer_bounds;
        if (b.cols == 0 or b.rows == 0) return;
        self.scrollBufferToCursor();

        const cursor = self.ed.pos();
        var pad: std.ArrayList(u8) = .empty;
        defer pad.deinit(self.alloc);

        var r: usize = 0;
        while (r < b.rows) : (r += 1) {
            const line = self.top_line + r;
            pad.clearRetainingCapacity();

            if (line < self.ed.buf.lineCount()) {
                const text = try self.ed.buf.lineText(self.alloc, line);
                defer self.alloc.free(text);
                const visible = sliceCols(text, self.left_col, b.cols);
                try pad.appendSlice(self.alloc, visible);
                try padTo(self.alloc, &pad, glyphwire.stringWidth(visible), b.cols);
                try writeAt(batch, self.buffer_layer, r, 0, pad.items, fg_text, bg_buffer);
            } else {
                // vim's marker for "past the end of the buffer".
                try pad.append(self.alloc, '~');
                try padTo(self.alloc, &pad, 1, b.cols);
                try writeAt(batch, self.buffer_layer, r, 0, pad.items, fg_dim, bg_buffer);
            }
        }

        // The caret is a block drawn as one inverted cell. The host's own
        // caret renderer only knows about the root layer, and a client
        // that owns its pane knows better than the host where its cursor
        // is anyway.
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
                // underneath it.
                try batch.notify("draw_icon", .{
                    .layer = self.tree_layer,
                    .row = r,
                    .col = e.depth * tree_mod.indent_cols,
                    .name = iconFor(e),
                    .scale = "fit",
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

/// Pads `line` with spaces from `width` display cells out to `target`.
fn padTo(alloc: std.mem.Allocator, line: *std.ArrayList(u8), width: usize, target: usize) !void {
    if (width >= target) return;
    try line.appendNTimes(alloc, ' ', target - width);
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
