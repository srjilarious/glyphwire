const std = @import("std");

const config = @import("config.zig");
const App = @import("app.zig").App;

const CursorShape = config.CursorShape;

/// Caret appearance + blink phase + mouse-scroll pin state. The caret is a
/// property of the rendering front end, not the shared grid model, so all
/// of this is host-local (see `config.CursorConfig`). Drawing lives in
/// `render.zig`; this struct owns only the state and the logic that moves
/// it.
pub const Caret = struct {
    app: *App,

    /// Caret appearance from `host.conf` (see `config.CursorConfig`).
    shape: CursorShape,
    blink: bool,
    blink_ms: f64,

    /// Milliseconds since the caret's blink phase last reset. Advanced by
    /// `deltaTimeMs` every `update`, zeroed whenever the caret moves or the
    /// window scrolls (see `tickBlink`) so the caret is solid the instant
    /// the user does anything and only blinks once things settle.
    blink_elapsed_ms: f64 = 0,
    /// The `(row, col, view_scroll)` the blink phase was last reset for --
    /// compared each `update` to detect caret movement / scrolling.
    blink_ref: struct { row: usize = 0, col: usize = 0, scroll: usize = 0 } = .{},

    /// Set the moment a host-driven scroll (mouse wheel or scrollbar, not
    /// a client `scroll_view` -- so not glyphwire-shell's keyboard browse)
    /// moves the root view off a resting spot. While set, the caret is
    /// drawn pinned to the buffer cell it pointed at then: it rides the
    /// content up/down as the view scrolls and clips off-screen once that
    /// cell leaves the viewport, instead of staying glued to the live
    /// prompt's grid cell. `row`/`col` are that cell's viewport position
    /// and `base_scroll` the `view_scroll` in effect when it was captured,
    /// so its current screen row is `row + view_scroll - base_scroll`.
    /// Cleared by `clearPinForKey` (any forwarded key/text, which also
    /// snaps the view back to the live tail) or, when the client itself
    /// moves the cursor, by `reconcilePin`.
    pin: ?struct { row: usize, col: usize, base_scroll: usize } = null,

    /// Advances the caret's blink phase and resets it whenever the caret
    /// has moved or the window has scrolled since the last tick -- so the
    /// caret shows solid the moment anything happens and resumes blinking
    /// only once it settles. A no-op past the phase advance when
    /// `blink` is off. Called at the end of `update`, after every
    /// caret-moving path (key forwarding, arrow repeat, scroll) has run.
    pub fn tickBlink(self: *Caret, delta_ms: f64) void {
        const server = self.app.server;
        const now: @TypeOf(self.blink_ref) = blk: {
            server.ctx_mutex.lockUncancelable(server.io);
            defer server.ctx_mutex.unlock(server.io);
            const root = &server.ctx.root;
            break :blk .{ .row = root.cursor.row, .col = root.cursor.col, .scroll = root.view_scroll };
        };
        if (now.row != self.blink_ref.row or now.col != self.blink_ref.col or now.scroll != self.blink_ref.scroll) {
            self.blink_ref = now;
            self.blink_elapsed_ms = 0;
            return;
        }
        self.blink_elapsed_ms += delta_ms;
    }

    /// Whether the caret should be painted this frame: never while the
    /// root layer has DECTCEM cursor-hide set (`CSI ? 25 l` from a
    /// foregrounded program), otherwise always unless blinking is enabled
    /// and the phase clock is in its "off" half.
    pub fn visible(self: *const Caret) bool {
        if (!self.app.server.ctx.root.cursor_visible) return false;
        if (!self.blink) return true;
        const period = self.blink_ms * 2;
        return @mod(self.blink_elapsed_ms, period) < self.blink_ms;
    }

    /// Where the caret sits on screen this frame, as a root-layer cell, or
    /// null when it has nothing to point at (pinned to a buffer cell that
    /// has scrolled out of the viewport, or a cursor past the grid bounds).
    /// Normally just the live grid cursor; a mouse-driven scroll pins it to
    /// the buffer cell it was on when the scroll began (see `pin`).
    ///
    /// `view_offset` is the root view offset already resolved by the caller
    /// (0 while a full-screen program owns the screen). Callers must hold
    /// `ctx_mutex` -- this reads `root` without taking it, so it can be
    /// used from inside `render`'s existing locked section.
    pub fn screenCell(
        self: *const Caret,
        root: *const @import("glyphwire").Layer,
        view_offset: usize,
    ) ?struct { row: usize, col: usize } {
        var crow: usize = root.cursor.row;
        var ccol: usize = root.cursor.col;
        if (self.pin) |pin| {
            const sr = @as(isize, @intCast(pin.row)) +
                @as(isize, @intCast(view_offset)) -
                @as(isize, @intCast(pin.base_scroll));
            if (sr < 0 or sr >= @as(isize, @intCast(root.height))) return null;
            crow = @intCast(sr);
            ccol = pin.col;
        }
        if (crow >= root.height or ccol >= root.width) return null;
        return .{ .row = crow, .col = ccol };
    }

    /// Captures `pin` from the root layer's current cursor + view offset,
    /// unless one is already pinned. Called by the host's own scroll paths
    /// (`scroll.handleScroll`, `scroll.handleScrollbar`) just before they
    /// move the view, so the caret freezes at the buffer cell it was on
    /// when a mouse scroll began -- see `pin`.
    pub fn pinIfUnpinned(self: *Caret) void {
        if (self.pin != null) return;
        const server = self.app.server;
        server.ctx_mutex.lockUncancelable(server.io);
        defer server.ctx_mutex.unlock(server.io);
        const root = &server.ctx.root;
        self.pin = .{
            .row = root.cursor.row,
            .col = root.cursor.col,
            .base_scroll = root.view_scroll,
        };
    }

    /// Clears a caret pin because the keyboard was used, and snaps the
    /// root view back to the live tail so the just-pressed key's effect is
    /// on screen ("a key press scrolls the cursor back into view"). A
    /// no-op when nothing is pinned or no key/text arrived this frame.
    pub fn clearPinForKey(self: *Caret, any_key_or_text: bool) void {
        if (!any_key_or_text or self.pin == null) return;
        self.pin = null;
        self.app.server.reportScroll(self.app.alloc, 0, null) catch |err| {
            std.log.err("glyphwire-host: reportScroll(caret snap-back) failed: {t}", .{err});
        };
    }

    /// Drops a caret pin the client itself invalidated: if a connected
    /// client (glyphwire-shell's keyboard browse, or its type-to-snap-back)
    /// has moved the grid cursor away from where it was pinned, or the
    /// view is back at/above where the pin was captured, the caret should
    /// go back to tracking `layer.cursor` normally. Unlike `clearPinForKey`
    /// this does *not* touch the view -- the client is managing it.
    pub fn reconcilePin(self: *Caret) void {
        const pin = self.pin orelse return;
        const server = self.app.server;
        server.ctx_mutex.lockUncancelable(server.io);
        defer server.ctx_mutex.unlock(server.io);
        const root = &server.ctx.root;
        if (root.cursor.row != pin.row or root.cursor.col != pin.col or root.view_scroll <= pin.base_scroll) {
            self.pin = null;
        }
    }
};
