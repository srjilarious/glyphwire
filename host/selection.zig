// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: MPL-2.0

const std = @import("std");
const glyphwire = @import("glyphwire");
const host_eng = @import("host_eng");

const app_mod = @import("app.zig");
const geometry = @import("geometry.zig");

const App = app_mod.App;
const Engine = app_mod.Engine;

/// A translucent tint drawn over the selected cells in the `color_bg`
/// render pass, so text painted afterward stays readable on top of it.
pub const selection_highlight_color = host_eng.Color.from(80, 130, 220, 90);

/// Text selection (keyboard mode + mouse drag) and the OS-clipboard
/// bridge. Mirrors the selection's two ends here so a move can be computed
/// without a `get_selection` round trip against the in-process `Context`.
pub const Selection = struct {
    app: *App,

    /// Last `ctx.clipboard_serial` this host pushed to the OS clipboard.
    /// `syncClipboardToOs` compares it each frame so a `set_clipboard`
    /// from a client (or the host's own selection copy) reaches the OS
    /// without diffing bytes every frame.
    clipboard_serial_pushed: u64 = 0,

    /// Keyboard selection mode (toggled by Ctrl+Shift+Space). While set,
    /// the host swallows the arrows / Home / End / Escape / Enter keys
    /// and uses them to move the selection's active end instead of
    /// forwarding them to glyphwire-shell. See `handleKeys`.
    mode: bool = false,
    /// The selection's fixed and moving ends while the host drives it
    /// (keyboard mode or a mouse drag), mirrored here so a move can be
    /// computed without a `get_selection` round trip. In
    /// `glyphwire.SelectionPoint` coordinates.
    anchor: glyphwire.SelectionPoint = .{ .above = 0, .col = 0 },
    active: glyphwire.SelectionPoint = .{ .above = 0, .col = 0 },

    /// Mouse drag-selection state. `mouse_selecting` is set on a
    /// non-scrollbar left press; `mouse_moved` flips true once the
    /// pointer leaves the anchor cell, which is when a real selection is
    /// created -- a press+release with no move stays a plain click and is
    /// forwarded to glyphwire-shell. `mouse_anchor` is where the press
    /// landed, `mouse_last_cell` the cell the pointer was last seen in.
    mouse_selecting: bool = false,
    mouse_moved: bool = false,
    mouse_anchor: glyphwire.SelectionPoint = .{ .above = 0, .col = 0 },
    mouse_last_cell: glyphwire.CellPos = .{},

    /// Which layer of the visible context the current selection lives on
    /// -- null is the root layer, which is what keyboard mode and a drag
    /// over bare scrollback both use. A drag that starts inside a
    /// `create_layer` layer's viewport selects *that* layer's text
    /// instead, so a popup, a sidebar or a reader's text panel is
    /// selectable without the client having to run its own drag loop.
    /// Resolved once at press time and held for the whole drag: a layer
    /// that moves or resizes mid-drag would otherwise switch the
    /// selection to a different grid halfway through.
    layer: ?glyphwire.LayerHandle = null,

    /// Whether `input.KeyInput.reportKeyEvents` should hold this key back
    /// from the wire because `handleKeys` owns it this frame: Ctrl+Shift+
    /// C/V/Space always, and the motion/commit keys while keyboard
    /// selection mode is active.
    pub fn swallows(self: *const Selection, key: app_mod.Key, kb: anytype) bool {
        const cs = kb.ctrl() and kb.shift();
        switch (key) {
            .c, .v, .space => if (cs) return true,
            else => {},
        }
        if (self.mode) switch (key) {
            .left, .right, .up, .down, .home, .end, .escape, .enter, .kp_enter => return true,
            else => {},
        };
        return false;
    }

    /// Root layer's current scrollback view offset -- a short locked read,
    /// used to convert a screen row to a scroll-stable `SelectionPoint`.
    fn rootViewScroll(self: *Selection) usize {
        const server = self.app.server;
        server.ctx_mutex.lockUncancelable(server.io);
        defer server.ctx_mutex.unlock(server.io);
        return server.ctx.root.view_scroll;
    }

    /// A `create_layer` layer's placement and scroll position, snapshotted
    /// under the lock so the pixel maths below runs without holding it.
    const LayerHit = struct {
        handle: glyphwire.LayerHandle,
        rect: geometry.RectPx,
        /// The layer's viewport offset into its own content grid: a
        /// selection point is a *content* coordinate, so this goes back in
        /// on the way from a screen pixel to a point.
        scroll_off: glyphwire.CellPos,
        view_cols: usize,
        view_rows: usize,
    };

    /// The topmost visible `create_layer` layer of the visible context
    /// whose viewport contains `(px, py)`, or null for a point over bare
    /// root. Backwards through `layer_order` because later entries
    /// composite on top, the same walk `panes.scrollablePaneAt` does.
    ///
    /// A zero-sized or scrollbar-only layer is still a hit: unlike the
    /// wheel, which should fall through a layer with nothing to scroll,
    /// a drag over a layer's text is unambiguously about *that* text.
    fn layerAt(self: *Selection, px: f32, py: f32) ?LayerHit {
        const server = self.app.server;
        server.ctx_mutex.lockUncancelable(server.io);
        defer server.ctx_mutex.unlock(server.io);

        const ctx = server.ctx;
        const origin = geometry.contextOrigin(ctx);
        var i = ctx.layer_order.items.len;
        while (i > 0) {
            i -= 1;
            const handle = ctx.layer_order.items[i];
            const layer = ctx.layers.getPtr(handle) orelse continue;
            if (!layer.visible) continue;
            const cols = layer.viewportCols();
            const rows = layer.viewportRows();
            const rect = geometry.layerRectIn(origin, layer.pos, cols, rows);
            if (!rect.contains(px, py)) continue;
            return .{
                .handle = handle,
                .rect = rect,
                .scroll_off = layer.scroll_off,
                .view_cols = cols,
                .view_rows = rows,
            };
        }
        return null;
    }

    /// The `SelectionPoint` for the pixel `(px, py)` on whichever layer
    /// the current drag owns (`self.layer`).
    ///
    /// For root that is the scrollback-anchored form (`above =
    /// view_scroll - row`, see `glyphwire.SelectionPoint`). A
    /// `create_layer` layer has no scrollback ring, so its `above` is
    /// simply the negated *content* row -- the viewport row plus the
    /// layer's own `scroll_off`, which is exactly the coordinate the
    /// renderer's selection-tint pass asks `selectionColRange` for.
    fn pointAtPixel(self: *Selection, px: f32, py: f32) glyphwire.SelectionPoint {
        const handle = self.layer orelse {
            const cell = geometry.cellFromPixel(px, py);
            const vs = self.rootViewScroll();
            return .{ .above = @as(i64, @intCast(vs)) - @as(i64, @intCast(cell.row)), .col = cell.col };
        };
        const hit = self.layerFor(handle) orelse return self.active;
        return pointInLayer(hit, px, py);
    }

    /// `layerAt`, but for a handle already chosen -- re-read each call
    /// rather than cached with the drag for the same reason
    /// `Scroll.paneBarsFor` re-reads its track: the layer can move, resize
    /// or scroll mid-drag, and stale geometry would land the active end on
    /// the wrong cell.
    fn layerFor(self: *Selection, handle: glyphwire.LayerHandle) ?LayerHit {
        const server = self.app.server;
        server.ctx_mutex.lockUncancelable(server.io);
        defer server.ctx_mutex.unlock(server.io);

        const ctx = server.ctx;
        const layer = ctx.layers.getPtr(handle) orelse return null;
        const cols = layer.viewportCols();
        const rows = layer.viewportRows();
        return .{
            .handle = handle,
            .rect = geometry.layerRectIn(geometry.contextOrigin(ctx), layer.pos, cols, rows),
            .scroll_off = layer.scroll_off,
            .view_cols = cols,
            .view_rows = rows,
        };
    }

    /// Pixel -> content-cell point within one layer, clamped to its
    /// viewport so a pointer dragged off the edge pins to the last cell
    /// rather than selecting cells that aren't on screen.
    fn pointInLayer(hit: LayerHit, px: f32, py: f32) glyphwire.SelectionPoint {
        const cw: f32 = @floatFromInt(geometry.cell_w);
        const ch: f32 = @floatFromInt(geometry.cell_h);
        const col_f = (px - hit.rect.x) / cw;
        const row_f = (py - hit.rect.y) / ch;
        const max_col: f32 = @floatFromInt(hit.view_cols -| 1);
        const max_row: f32 = @floatFromInt(hit.view_rows -| 1);
        const col: usize = @intFromFloat(std.math.clamp(col_f, 0, max_col));
        const row: usize = @intFromFloat(std.math.clamp(row_f, 0, max_row));
        const content_row = hit.scroll_off.row + row;
        return .{ .above = -@as(i64, @intCast(content_row)), .col = hit.scroll_off.col + col };
    }

    /// Ctrl+Shift+C / +V / +Space, plus the keyboard-selection-mode
    /// motion keys. Runs before `input.KeyInput.reportKeyEvents` (which
    /// swallows the same keys).
    pub fn handleKeys(self: *Selection, eng: *Engine) void {
        const kb = &eng.inputs.keyboard;
        const cs = kb.ctrl() and kb.shift();

        if (cs and kb.pressed(.c)) {
            self.copyShortcut();
            return;
        }
        if (cs and kb.pressed(.v)) {
            self.pasteShortcut();
            return;
        }
        if (cs and kb.pressed(.space)) {
            self.toggleMode();
            return;
        }
        if (!self.mode) return;

        if (kb.pressed(.escape)) {
            self.endMode(true);
            return;
        }
        if (kb.pressed(.enter) or kb.pressed(.kp_enter)) {
            self.copyShortcut();
            return;
        }

        // Home / End jump to the line edge -- edge-triggered, no repeat
        // (holding them past the edge does nothing anyway).
        if (kb.pressed(.home)) {
            self.moveActive(0, 0, -1);
            return;
        }
        if (kb.pressed(.end)) {
            self.moveActive(0, 0, 1);
            return;
        }

        // Arrows extend on the initial press and then repeat while held,
        // off the engine's own hold timers -- so selection motion runs at
        // whatever cadence the focused program set, same as every other
        // repeating key.
        self.selectArrowRepeat(eng, .left, -1, 0);
        self.selectArrowRepeat(eng, .right, 1, 0);
        self.selectArrowRepeat(eng, .up, 0, -1);
        self.selectArrowRepeat(eng, .down, 0, 1);
    }

    /// One selection-mode arrow: move the active end on the press edge
    /// and on each typematic repeat (`Keyboard.repeated`), driving the
    /// selection instead of the root cursor / a shell key broadcast the
    /// way `input.KeyInput.handleRepeatKeys` does.
    fn selectArrowRepeat(
        self: *Selection,
        eng: *Engine,
        key: app_mod.Key,
        dcol: i64,
        drow: i64,
    ) void {
        const kb = &eng.inputs.keyboard;
        if (kb.pressed(key) or kb.repeated(key)) self.moveActive(dcol, drow, 0);
    }

    /// Enters keyboard selection mode with a zero-width selection at the
    /// root cursor, or leaves it (clearing the selection) if already on.
    fn toggleMode(self: *Selection) void {
        if (self.mode) {
            self.endMode(true);
            return;
        }
        const server = self.app.server;
        var vs: usize = undefined;
        var crow: usize = undefined;
        var ccol: usize = undefined;
        {
            server.ctx_mutex.lockUncancelable(server.io);
            defer server.ctx_mutex.unlock(server.io);
            const root = &server.ctx.root;
            vs = root.view_scroll;
            crow = root.cursor.row;
            ccol = root.cursor.col;
        }
        const p: glyphwire.SelectionPoint = .{
            .above = @as(i64, @intCast(vs)) - @as(i64, @intCast(crow)),
            .col = ccol,
        };
        self.anchor = p;
        self.active = p;
        self.mode = true;
        // Keyboard mode starts at the root cursor and walks the root
        // grid, so it is always a root-layer selection -- a drag is the
        // only gesture that can land on a `create_layer` layer.
        self.layer = null;
        server.setSelection(self.app.alloc, null, p, p) catch |err| {
            std.log.err("glyphwire-host: setSelection (enter select mode) failed: {t}", .{err});
        };
    }

    fn endMode(self: *Selection, clear: bool) void {
        self.mode = false;
        if (clear) self.app.server.clearSelection(self.app.alloc, self.layer) catch |err| {
            std.log.err("glyphwire-host: clearSelection failed: {t}", .{err});
        };
    }

    /// Moves the selection's active end by `drow`/`dcol` cells (or to the
    /// line's start/end when `to_edge` is -1/+1), scrolling the view when
    /// the end walks past the top or bottom of the viewport.
    ///
    /// Root-layer only -- it is reached from keyboard mode, which
    /// `toggleMode` pins to root.
    fn moveActive(self: *Selection, dcol: i64, drow: i64, to_edge: i8) void {
        const server = self.app.server;
        var width: usize = undefined;
        var height: usize = undefined;
        var hist: usize = undefined;
        var vs: usize = undefined;
        {
            server.ctx_mutex.lockUncancelable(server.io);
            defer server.ctx_mutex.unlock(server.io);
            const root = &server.ctx.root;
            width = root.width;
            height = root.height;
            hist = root.history_len;
            vs = root.view_scroll;
        }
        if (width == 0 or height == 0) return;

        // Current active end -> screen row, moved by drow, then re-clamped
        // into the viewport by scrolling.
        var srow: i64 = @as(i64, @intCast(vs)) - self.active.above + drow;
        var new_vs: i64 = @intCast(vs);
        if (srow < 0) {
            new_vs += -srow;
            srow = 0;
        } else if (srow >= @as(i64, @intCast(height))) {
            new_vs -= srow - @as(i64, @intCast(height)) + 1;
            srow = @as(i64, @intCast(height)) - 1;
        }
        new_vs = std.math.clamp(new_vs, 0, @as(i64, @intCast(hist)));

        var col: i64 = @intCast(self.active.col);
        if (to_edge < 0) {
            col = 0;
        } else if (to_edge > 0) {
            col = @as(i64, @intCast(width)) - 1;
        } else {
            col = std.math.clamp(col + dcol, 0, @as(i64, @intCast(width)) - 1);
        }

        self.active = .{ .above = new_vs - srow, .col = @intCast(col) };
        if (new_vs != @as(i64, @intCast(vs))) {
            server.reportScroll(self.app.alloc, @intCast(new_vs), null) catch {};
        }
        server.setSelection(self.app.alloc, null, self.anchor, self.active) catch |err| {
            std.log.err("glyphwire-host: setSelection (move) failed: {t}", .{err});
        };
    }

    /// Ctrl+Shift+C / select-mode Enter: copy the selection to the OS
    /// clipboard, or -- with nothing (or a zero-width selection) --
    /// broadcast `copy_request` so glyphwire-shell answers with its
    /// prompt.
    fn copyShortcut(self: *Selection) void {
        const server = self.app.server;
        // Not `self.layer`: a *client* can set a selection on one of its
        // own layers too (`set_selection` takes a handle), and the copy
        // shortcut has to find that one as well -- a reader that drives
        // its own drag over a text panel would otherwise copy nothing.
        const target = server.selectedLayer();
        const maybe_text = server.selectionText(self.app.alloc, target) catch |err| {
            std.log.err("glyphwire-host: selectionText failed: {t}", .{err});
            return;
        };
        if (maybe_text) |text| {
            defer self.app.alloc.free(text);
            self.layer = target;
            self.endMode(true);
            if (text.len > 0) {
                server.setClipboard(text) catch |err| {
                    std.log.err("glyphwire-host: setClipboard (copy) failed: {t}", .{err});
                };
                return;
            }
            // A zero-width selection: fall through to the prompt copy.
        }
        server.requestCopy(self.app.alloc) catch |err| {
            std.log.err("glyphwire-host: requestCopy failed: {t}", .{err});
        };
    }

    /// Ctrl+Shift+V: read the OS clipboard (main thread) and broadcast it
    /// as a `paste` notification. Also refreshes `ctx.clipboard` so a
    /// later `get_clipboard` sees it.
    fn pasteShortcut(self: *Selection) void {
        const server = self.app.server;
        const s = self.app.window.getClipboardString() orelse return;
        if (s.len == 0) return;
        // `s` is engine-owned and only valid until the next clipboard
        // call; both calls below copy it right away.
        server.setClipboard(s) catch |err| {
            std.log.err("glyphwire-host: setClipboard (paste) failed: {t}", .{err});
            return;
        };
        // The bytes already match the OS clipboard -- don't push them
        // straight back out in `syncClipboardToOs`.
        self.clipboard_serial_pushed = server.clipboardSerial();
        server.broadcastPaste(self.app.alloc, s) catch |err| {
            std.log.err("glyphwire-host: broadcastPaste failed: {t}", .{err});
        };
    }

    /// Pushes `ctx.clipboard` to the OS clipboard when its serial has
    /// moved since the last push -- called once per frame on the main
    /// thread (SDL clipboard writes are main-thread-only).
    pub fn syncClipboardToOs(self: *Selection) void {
        const server = self.app.server;
        const serial = server.clipboardSerial();
        if (serial == self.clipboard_serial_pushed) return;
        const text = server.clipboardText(self.app.alloc) catch return;
        defer self.app.alloc.free(text);
        const z = std.mem.concatWithSentinel(self.app.alloc, u8, &.{text}, 0) catch return;
        defer self.app.alloc.free(z);
        self.app.window.setClipboardString(z);
        self.clipboard_serial_pushed = serial;
    }

    /// Mouse drag-selection. Returns true when the left button this frame
    /// belongs to a selection drag, so `input.KeyInput.reportMouseEvents`
    /// drops it (the shell only ever sees a plain click -- press+release
    /// with no move -- which this forwards synthetically). Given second
    /// refusal after the scrollbar (`skip_left`).
    pub fn handleMouseSelection(self: *Selection, eng: *Engine, skip_left: bool) bool {
        if (!eng.inputs.mouse_enabled) return false;
        const server = self.app.server;
        // A client that owns the visible context (zoe) draws its own panes
        // and runs its own selection. Chrome -- dividers, scrollbars --
        // already got first refusal via `skip_left`, so anything left is a
        // press into the client's content: let it through to the wire
        // rather than starting a host grid selection that would fight it.
        // An in-flight drag still finishes (the visible context can't
        // change mid-drag without the button coming up first).
        if (!self.mouse_selecting and server.visibleContextClientOwned()) return false;
        const m = &eng.inputs.mouse;
        const pos = m.pos();
        const fb = eng.window_state.framebuffer_size;
        const on_scrollbar = pos.x >= @as(f32, @floatFromInt(fb.x - geometry.scrollbar_width_px));
        const cell = geometry.cellFromPixel(pos.x, pos.y);

        if (!self.mouse_selecting) {
            if (skip_left or on_scrollbar) return false;
            if (m.pressed(.left)) {
                self.mouse_selecting = true;
                self.mouse_moved = false;
                self.mouse_last_cell = cell;
                // Which grid this drag is over, decided once at press
                // time; null falls through to root, exactly as before.
                self.layer = if (self.layerAt(pos.x, pos.y)) |hit| hit.handle else null;
                self.mouse_anchor = self.pointAtPixel(pos.x, pos.y);
                return true;
            }
            return false;
        }

        if (m.down(.left)) {
            // Slow auto-scroll while the pointer rests at the top/bottom
            // edge -- this moves content under a stationary pointer, so it
            // also forces a selection update below.
            var edge_scrolled = false;
            // Root only: this drags the *scrollback ring* into view, which
            // a `create_layer` layer doesn't have. A drag off the edge of
            // a popup just pins to its last cell (`pointInLayer` clamps).
            if (self.layer == null) {
                if (pos.y < @as(f32, @floatFromInt(geometry.cell_h))) {
                    server.reportScroll(self.app.alloc, null, 1) catch {};
                    edge_scrolled = true;
                } else if (pos.y > @as(f32, @floatFromInt(@as(i32, @intCast(geometry.grid_rows -| 1)) * geometry.cell_h))) {
                    server.reportScroll(self.app.alloc, null, -1) catch {};
                    edge_scrolled = true;
                }
            }

            const moved_cell = cell.row != self.mouse_last_cell.row or cell.col != self.mouse_last_cell.col;
            if (moved_cell or (self.mouse_moved and edge_scrolled)) {
                self.mouse_last_cell = cell;
                if (!self.mouse_moved) {
                    self.mouse_moved = true;
                    // A drag supersedes any keyboard selection mode.
                    self.mode = false;
                    self.anchor = self.mouse_anchor;
                }
                self.active = self.pointAtPixel(pos.x, pos.y);
                server.setSelection(self.app.alloc, self.layer, self.anchor, self.active) catch |err| {
                    std.log.err("glyphwire-host: setSelection (drag) failed: {t}", .{err});
                };
            }
            return true;
        }

        // Button released.
        self.mouse_selecting = false;
        if (!self.mouse_moved) {
            // A plain click: hand the shell the press+release it activates
            // on, and clear any leftover selection (standard behaviour).
            const vo = self.rootViewScroll();
            server.reportMouseButton(self.app.alloc, "left", true, .{ .x = pos.x, .y = pos.y }, cell, vo) catch {};
            server.reportMouseButton(self.app.alloc, "left", false, .{ .x = pos.x, .y = pos.y }, cell, vo) catch {};
            // Whatever was selected, wherever it was: a plain click
            // clears it, which for a click on a different layer than the
            // last selection means clearing that one, not this one.
            server.clearSelection(self.app.alloc, server.selectedLayer()) catch {};
            self.layer = null;
            self.mode = false;
        }
        return true;
    }
};
