const std = @import("std");
const glyphwire = @import("glyphwire");

const app_mod = @import("app.zig");
const geometry = @import("geometry.zig");

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
        const dy = eng.inputs.mouse.scroll().y;
        if (dy == 0) return;

        const delta: i64 = @intFromFloat(@round(dy * geometry.scroll_rows_per_tick));

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
        {
            server.ctx_mutex.lockUncancelable(server.io);
            defer server.ctx_mutex.unlock(server.io);
            history_len = server.ctx.root.history_len;
            height = server.ctx.root.height;
            view_scroll = server.ctx.root.view_scroll;
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
