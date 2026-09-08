const std = @import("std");
const glyphwire = @import("glyphwire");

const app_mod = @import("app.zig");
const geometry = @import("geometry.zig");
const panes_mod = @import("panes.zig");

const App = app_mod.App;
const Engine = app_mod.Engine;

/// True while a full-screen program owns the root layer's display --
/// it's on the alternate screen, has set a DECSTBM scroll region, or
/// has set DECCKM application cursor keys (`less -X` / `bat` / git's
/// pager, and `vim` / `htop` / `nano` / `fzf`, all set DECCKM;
/// `ls` / `cat` / `grep` don't). In that state the host's scrollback
/// view is meaningless: scrolling it drags the program's own fixed
/// rows (a status line) out of place and reveals stale scrollback
/// underneath. The wheel is redirected to the program instead (see
/// `Scroll.handleScroll`), the scrollbar goes inert, and `render` pins the
/// view to the live tail.
///
/// This is the `Scroll.screenOwnedByProgram` predicate on an
/// already-locked root layer -- for `render.zig`, which holds `ctx_mutex`
/// itself (the mutex isn't reentrant).
pub fn rootOwned(root: *const glyphwire.Layer) bool {
    return root.on_alt or root.regionActive() or root.app_cursor_keys;
}

/// Mouse-wheel and scrollbar interaction against the root layer's
/// scrollback view. Holds only the drag state the scrollbar thumb needs;
/// the drawing lives in `render.zig`.
pub const Scroll = struct {
    app: *App,

    /// True while the left button is held on the scrollbar thumb after
    /// grabbing it -- see `handleScrollbar`. `scrollbar_grab_dy` is the
    /// pixel offset between the pointer and the thumb's top edge at grab
    /// time, so the thumb tracks the pointer without jumping.
    scrollbar_drag: bool = false,
    scrollbar_grab_dy: f32 = 0,

    /// The pane scrollbar thumb currently being dragged, if any -- the
    /// per-layer counterpart of `scrollbar_drag`. `grab` is the pixel
    /// offset between the pointer and the thumb's leading edge at grab
    /// time, on the bar's own axis, so the thumb tracks the pointer
    /// without jumping.
    pane_drag: ?PaneDrag = null,

    pub const PaneDrag = struct {
        layer: glyphwire.LayerHandle,
        vertical: bool,
        grab: f32,
    };

    /// One pane's bar geometry, resolved under `ctx_mutex` so the
    /// interaction code below can work from a snapshot instead of holding
    /// the lock across a whole drag.
    const PaneBars = struct {
        layer: glyphwire.LayerHandle,
        state: glyphwire.ScrollbarState,
        bars: geometry.PaneScrollbars,
    };

    /// The pane whose scrollbar (either axis) contains `(px, py)`.
    /// Topmost first, same reason as `panes.scrollablePaneAt`.
    fn paneBarAt(self: *Scroll, px: f32, py: f32) ?PaneBars {
        const server = self.app.server;
        server.ctx_mutex.lockUncancelable(server.io);
        defer server.ctx_mutex.unlock(server.io);

        var i = server.ctx.layer_order.items.len;
        while (i > 0) {
            i -= 1;
            const handle = server.ctx.layer_order.items[i];
            const layer = server.ctx.layers.getPtr(handle) orelse continue;
            if (!layer.visible) continue;
            const state = layer.scrollbarState();
            if (!state.vertical and !state.horizontal) continue;

            const rect = geometry.layerRect(layer.pos, layer.viewportCols(), layer.viewportRows());
            const bars = geometry.paneScrollbars(
                rect,
                state,
                layer.viewportCols(),
                layer.viewportRows(),
            );
            if (bars.vertical) |v| {
                if (v.track.contains(px, py)) return .{ .layer = handle, .state = state, .bars = bars };
            }
            if (bars.horizontal) |h| {
                if (h.track.contains(px, py)) return .{ .layer = handle, .state = state, .bars = bars };
            }
        }
        return null;
    }

    /// The bar geometry for a pane currently being dragged. Re-read each
    /// frame rather than cached with the drag: the pane can be resized
    /// (or the font zoomed) mid-drag, and a stale track would send the
    /// thumb somewhere the content isn't.
    fn paneBarsFor(self: *Scroll, handle: glyphwire.LayerHandle) ?PaneBars {
        const server = self.app.server;
        server.ctx_mutex.lockUncancelable(server.io);
        defer server.ctx_mutex.unlock(server.io);

        const layer = server.ctx.layers.getPtr(handle) orelse return null;
        const state = layer.scrollbarState();
        const rect = geometry.layerRect(layer.pos, layer.viewportCols(), layer.viewportRows());
        return .{
            .layer = handle,
            .state = state,
            .bars = geometry.paneScrollbars(
                rect,
                state,
                layer.viewportCols(),
                layer.viewportRows(),
            ),
        };
    }

    /// Maps a thumb's leading edge to a scroll offset: how far along its
    /// travel the thumb sits, times how far the content can go.
    fn offsetFromThumb(lead: f32, track_start: f32, track_len: f32, thumb_len: f32, max: usize) usize {
        const travel = @max(track_len - thumb_len, 0);
        if (travel <= 0 or max == 0) return 0;
        const frac = std.math.clamp((lead - track_start) / travel, 0, 1);
        return @intFromFloat(@round(frac * @as(f32, @floatFromInt(max))));
    }

    /// Pane scrollbars get the left button before the window's own bar
    /// does, since they sit inside the panes that cover it. Same
    /// true-means-consumed contract as `handleScrollbar`.
    pub fn handlePaneScrollbar(self: *Scroll, eng: *app_mod.Engine) bool {
        if (!eng.inputs.mouse_enabled) return false;
        const pos = eng.inputs.mouse.pos();

        if (eng.inputs.mouse.pressed(.left)) {
            const hit = self.paneBarAt(pos.x, pos.y) orelse return false;
            // Vertical wins a corner overlap; it is the axis a pointer in
            // the bottom-right corner of a pane is far more likely to
            // have been reaching for.
            if (hit.bars.vertical) |v| {
                if (v.track.contains(pos.x, pos.y)) {
                    if (v.thumb.contains(pos.x, pos.y)) {
                        self.pane_drag = .{ .layer = hit.layer, .vertical = true, .grab = pos.y - v.thumb.y };
                    } else {
                        // One viewport-height page toward the click.
                        self.pagePane(hit, true, pos.y < v.thumb.y);
                    }
                    return true;
                }
            }
            if (hit.bars.horizontal) |h| {
                if (h.track.contains(pos.x, pos.y)) {
                    if (h.thumb.contains(pos.x, pos.y)) {
                        self.pane_drag = .{ .layer = hit.layer, .vertical = false, .grab = pos.x - h.thumb.x };
                    } else {
                        self.pagePane(hit, false, pos.x < h.thumb.x);
                    }
                    return true;
                }
            }
            return false;
        }

        const drag = self.pane_drag orelse return false;
        if (!eng.inputs.mouse.down(.left)) {
            self.pane_drag = null;
            return true;
        }

        const live = self.paneBarsFor(drag.layer) orelse {
            self.pane_drag = null;
            return true;
        };
        if (drag.vertical) {
            const v = live.bars.vertical orelse return true;
            const offset = offsetFromThumb(pos.y - drag.grab, v.track.y, v.track.h, v.thumb.h, live.state.max_row);
            self.movePane(drag.layer, .{ .row = offset, .col = live.state.col });
        } else {
            const h = live.bars.horizontal orelse return true;
            const offset = offsetFromThumb(pos.x - drag.grab, h.track.x, h.track.w, h.thumb.w, live.state.max_col);
            self.movePane(drag.layer, .{ .row = live.state.row, .col = offset });
        }
        return true;
    }

    /// A track click: one viewport-worth toward the pointer.
    fn pagePane(self: *Scroll, hit: PaneBars, vertical: bool, backward: bool) void {
        const server = self.app.server;
        const page: i64 = page: {
            server.ctx_mutex.lockUncancelable(server.io);
            defer server.ctx_mutex.unlock(server.io);
            const layer = server.ctx.layers.getPtr(hit.layer) orelse break :page 1;
            const n = if (vertical) layer.viewportRows() else layer.viewportCols();
            break :page @intCast(@max(n, 2) - 1);
        };
        const step: i64 = if (backward) -page else page;
        const delta: glyphwire.CellPos.Delta = if (vertical) .{ .row = step } else .{ .col = step };
        server.reportScrollOffset(self.app.alloc, hit.layer, null, delta) catch {};
    }

    fn movePane(self: *Scroll, handle: glyphwire.LayerHandle, off: glyphwire.CellPos) void {
        self.app.server.reportScrollOffset(self.app.alloc, handle, off, null) catch {};
    }

    /// True while a full-screen program owns the root layer's display.

    /// Takes a short `ctx_mutex` snapshot; see `rootOwned` for the
    /// predicate and why it's separated out.
    pub fn screenOwnedByProgram(self: *Scroll) bool {
        const server = self.app.server;
        server.ctx_mutex.lockUncancelable(server.io);
        defer server.ctx_mutex.unlock(server.io);
        return rootOwned(&server.ctx.root);
    }

    /// Scrolls the root layer's view back into its scrollback on wheel-up,
    /// forward toward the live tail on wheel-down -- the missing piece
    /// that made `cat`ing anything longer than the window blast straight
    /// past with no way to look back at it (the ring buffer already
    /// retained the history via `Context.createLayer`'s `scrollback_rows`;
    /// nothing ever read it for display). Goes through
    /// `Server.reportScroll`, which owns the clamp to `history_len` and
    /// broadcasts a `scroll` notification so glyphwire-shell stays in sync
    /// -- the wheel, the scrollbar, and glyphwire-shell's browse cursor
    /// all move the same `root.view_scroll` field, which `render` reads
    /// directly each frame.
    ///
    /// While a full-screen program owns the screen
    /// (`screenOwnedByProgram`), the wheel instead sends arrow-key events
    /// -- xterm's `alternateScroll` -- so a wheel over `less`/`bat` pages
    /// the program rather than uselessly scrolling a frozen scrollback.
    pub fn handleScroll(self: *Scroll, eng: *Engine) void {
        if (!eng.inputs.mouse_enabled) return;
        const wheel = eng.inputs.mouse.scroll();
        if (wheel.y == 0 and wheel.x == 0) return;

        // Shift+wheel is horizontal, the convention every browser and
        // editor uses -- and the only horizontal scroll available on a
        // mouse with no tilt wheel.
        const shifted = eng.inputs.keyboard.shift();
        const wheel_y: f32 = if (shifted) 0 else wheel.y;
        const wheel_x: f32 = if (shifted) -wheel.y else wheel.x;

        const delta: i64 = @intFromFloat(@round(wheel_y * geometry.scroll_rows_per_tick));
        const delta_x: i64 = @intFromFloat(@round(wheel_x * geometry.scroll_rows_per_tick));

        // A scrollable pane under the pointer takes the wheel first: in a
        // TUI the panes cover the root layer, and a wheel over a file tree
        // means the tree, not the shell's scrollback behind it. A pane
        // with nothing to scroll doesn't match, so the wheel falls through
        // to the root exactly as it did before splits existed.
        const pane = pane: {
            const server = self.app.server;
            const pos = eng.inputs.mouse.pos();
            server.ctx_mutex.lockUncancelable(server.io);
            defer server.ctx_mutex.unlock(server.io);
            break :pane panes_mod.scrollablePaneAt(server.ctx, pos.x, pos.y);
        };
        if (pane) |hit| {
            // Wheel *up* shows earlier content, which is a *smaller*
            // offset -- the opposite sign from the root layer's
            // scrollback, where a bigger offset means further back.
            self.app.server.reportScrollOffset(self.app.alloc, hit.layer, null, .{
                .row = -delta,
                .col = delta_x,
            }) catch |err| {
                std.log.err("glyphwire-host: reportScrollOffset(wheel) failed: {t}", .{err});
            };
            return;
        }

        if (delta == 0) return;

        if (self.screenOwnedByProgram()) {
            const key: []const u8 = if (delta > 0) "up" else "down";
            var n: i64 = @intCast(@abs(delta));
            while (n > 0) : (n -= 1) {
                self.app.server.reportKey(self.app.alloc, key, true) catch break;
                self.app.server.reportKey(self.app.alloc, key, false) catch break;
            }
            return;
        }

        // Freeze the caret at its current buffer cell for the duration of
        // this mouse-driven scroll (see `caret.Caret.pin`).
        self.app.caret.pinIfUnpinned();
        self.app.server.reportScroll(self.app.alloc, null, delta) catch |err| {
            std.log.err("glyphwire-host: reportScroll(wheel) failed: {t}", .{err});
        };
    }

    /// Handles the scrollbar's own mouse interaction, before the grid sees
    /// the click. Returns true when the left button this frame belongs to
    /// the scrollbar (a press that landed on the bar, or an in-progress
    /// thumb drag, or the release ending one) -- the caller then tells
    /// `reportMouseEvents` to drop the left button so it isn't also
    /// delivered to glyphwire-shell as a grid click.
    ///
    /// - Press on the thumb: start dragging it (records the grab offset).
    /// - Press on the track above/below the thumb: page the view one
    ///   screenful toward the click.
    /// - Drag: map the pointer to a row offset and push it through
    ///   `Server.reportScroll`.
    pub fn handleScrollbar(self: *Scroll, eng: *Engine) bool {
        if (!eng.inputs.mouse_enabled) return false;
        // No scrollback to drive while a full-screen program owns the
        // screen -- leave the left button for the program (mouse
        // reporting) / selection.
        if (self.screenOwnedByProgram()) {
            self.scrollbar_drag = false;
            return false;
        }

        const server = self.app.server;
        const pos = eng.inputs.mouse.pos();
        const fb = eng.window_state.framebuffer_size;

        var history_len: usize = undefined;
        var height: usize = undefined;
        var view_scroll: usize = undefined;
        var enabled: bool = undefined;
        {
            server.ctx_mutex.lockUncancelable(server.io);
            defer server.ctx_mutex.unlock(server.io);
            history_len = server.ctx.root.history_len;
            height = server.ctx.root.height;
            view_scroll = server.ctx.root.view_scroll;
            enabled = server.ctx.window_scrollbar;
        }
        // The bar isn't drawn for this context (`core.Context.window_scrollbar`),
        // so a click in its gutter falls through to selection / the grid.
        if (!enabled) {
            self.scrollbar_drag = false;
            return false;
        }
        const geom = geometry.scrollbarGeom(fb.x, fb.y, history_len, height, view_scroll);
        const on_bar = pos.x >= geom.left;

        if (eng.inputs.mouse.pressed(.left)) {
            if (!on_bar) return false;
            if (pos.y >= geom.thumb_top and pos.y <= geom.thumb_top + geom.thumb_h) {
                self.scrollbar_drag = true;
                self.scrollbar_grab_dy = pos.y - geom.thumb_top;
            } else {
                // One screenful per track click, toward the pointer.
                const page: i64 = @intCast(@max(height, 2) - 1);
                const delta: i64 = if (pos.y < geom.thumb_top) page else -page;
                self.app.caret.pinIfUnpinned();
                server.reportScroll(self.app.alloc, null, delta) catch {};
            }
            return true;
        }

        if (self.scrollbar_drag) {
            if (eng.inputs.mouse.down(.left)) {
                const total: f32 = @floatFromInt(history_len + height);
                const max_top = @max(geom.track_h - geom.thumb_h, 0);
                const thumb_top = std.math.clamp(pos.y - self.scrollbar_grab_dy, 0, max_top);
                const top_frac: f32 = if (geom.track_h > 0) thumb_top / geom.track_h else 0;
                const rows_above_top: i64 = @intFromFloat(@round(top_frac * total));
                const target: i64 = std.math.clamp(
                    @as(i64, @intCast(history_len)) - rows_above_top,
                    0,
                    @as(i64, @intCast(history_len)),
                );
                self.app.caret.pinIfUnpinned();
                server.reportScroll(self.app.alloc, @intCast(target), null) catch {};
                return true;
            }
            // Button released -- end the drag and swallow this release.
            self.scrollbar_drag = false;
            return true;
        }

        return false;
    }
};
