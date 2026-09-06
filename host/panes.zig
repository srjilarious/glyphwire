//! The host's side of the split tree: the divider geometry it draws and
//! hit-tests, and the drag that resizes a pane.
//!
//! `core.Context` owns the tree and the layout maths; this is the part
//! that needs a mouse and a framebuffer. Both `render.zig` (drawing the
//! divider bands and each pane's scrollbars) and `scroll.zig` (routing a
//! wheel tick to the pane under the pointer) read through here, which is
//! why the divider cache lives in one place rather than in either of
//! them.

const std = @import("std");
const glyphwire = @import("glyphwire");

const app_mod = @import("app.zig");
const geometry = @import("geometry.zig");

const App = app_mod.App;

/// A layer's on-screen viewport rect, plus the handle it belongs to.
pub const PaneHit = struct {
    layer: glyphwire.LayerHandle,
    rect: geometry.RectPx,
};

/// The topmost visible, scrollable layer whose viewport contains
/// `(px, py)`.
///
/// Walks `layer_order` backwards because later entries composite on top,
/// so the last match is the one the user is actually pointing at.
/// `scrollsAnywhere` is part of the test on purpose: a wheel over a pane
/// with nothing to scroll should fall through to the shell's scrollback
/// underneath rather than being silently swallowed.
///
/// The caller must hold `ctx_mutex`.
pub fn scrollablePaneAt(ctx: *glyphwire.Context, px: f32, py: f32) ?PaneHit {
    var i = ctx.layer_order.items.len;
    while (i > 0) {
        i -= 1;
        const handle = ctx.layer_order.items[i];
        const layer = ctx.layers.getPtr(handle) orelse continue;
        if (!layer.visible) continue;
        if (!layer.scrollsAnywhere()) continue;
        const rect = geometry.layerRect(layer.pos, layer.viewportCols(), layer.viewportRows());
        if (rect.contains(px, py)) return .{ .layer = handle, .rect = rect };
    }
    return null;
}

/// Divider geometry plus the in-progress drag. One per `App`.
pub const Panes = struct {
    app: *App,

    /// The draggable bands of the current layout, recomputed only when
    /// `Context.layout_gen` moves -- a resize, a split edit, or a drag.
    /// Empty when there is no split tree, which is every session that
    /// isn't running a TUI.
    dividers: std.ArrayList(glyphwire.DividerRect) = .empty,
    gen: u64 = 0,
    built: bool = false,

    /// The divider currently being pulled.
    ///
    /// `applied` is how many cells have already been sent to
    /// `moveDivider`, so each frame sends only the difference. Tracking
    /// the total against the grab point (rather than accumulating
    /// per-frame deltas) is what keeps the divider under the pointer when
    /// a drag is clamped at a pane's minimum and then pulled back.
    drag: ?Drag = null,

    pub const Drag = struct {
        split: glyphwire.SplitHandle,
        index: usize,
        axis: glyphwire.SplitAxis,
        grab_px: f32,
        applied: i64 = 0,
    };

    pub fn deinit(self: *Panes) void {
        self.dividers.deinit(self.app.alloc);
    }

    /// Refreshes the divider cache if the layout has moved since it was
    /// built. The caller must hold `ctx_mutex`.
    pub fn syncLocked(self: *Panes) void {
        const ctx = self.app.server.ctx;
        if (self.built and self.gen == ctx.layout_gen) return;

        self.dividers.clearRetainingCapacity();
        // A failed re-layout leaves the previous cache in place rather
        // than a half-built one; the next frame tries again.
        ctx.layoutSplits(null, &self.dividers) catch return;
        self.gen = ctx.layout_gen;
        self.built = true;
    }

    /// The divider band under `(px, py)`, if any. Call `syncLocked`
    /// first.
    pub fn dividerAt(self: *const Panes, px: f32, py: f32) ?glyphwire.DividerRect {
        for (self.dividers.items) |d| {
            if (geometry.cellRectPx(d.rect).contains(px, py)) return d;
        }
        return null;
    }

    /// Mouse handling for the dividers, run before the grid sees the
    /// click (same contract as `Scroll.handleScrollbar`). Returns true
    /// when the left button this frame belongs to a divider -- a press
    /// that landed on one, a drag in progress, or the release ending it
    /// -- so the caller can drop the button rather than also delivering
    /// it as a grid click.
    pub fn handleMouse(self: *Panes, eng: *app_mod.Engine) bool {
        if (!eng.inputs.mouse_enabled) return false;
        const server = self.app.server;
        const pos = eng.inputs.mouse.pos();

        {
            server.ctx_mutex.lockUncancelable(server.io);
            defer server.ctx_mutex.unlock(server.io);
            self.syncLocked();
        }
        if (self.dividers.items.len == 0 and self.drag == null) return false;

        if (eng.inputs.mouse.pressed(.left)) {
            const hit = self.dividerAt(pos.x, pos.y) orelse return false;
            self.drag = .{
                .split = hit.split,
                .index = hit.index,
                .axis = hit.axis,
                .grab_px = if (hit.axis == .row) pos.x else pos.y,
            };
            return true;
        }

        const drag = self.drag orelse return false;
        if (!eng.inputs.mouse.down(.left)) {
            self.drag = null;
            return true;
        }

        // Pointer travel since the grab, in cells along the split's axis.
        const cur: f32 = if (drag.axis == .row) pos.x else pos.y;
        const cell: f32 = @floatFromInt(if (drag.axis == .row) geometry.cell_w else geometry.cell_h);
        const travelled: i64 = @intFromFloat(@round((cur - drag.grab_px) / @max(cell, 1)));
        const delta = travelled - drag.applied;
        if (delta == 0) return true;

        {
            server.ctx_mutex.lockUncancelable(server.io);
            defer server.ctx_mutex.unlock(server.io);
            server.ctx.moveDivider(drag.split, drag.index, delta) catch {};
        }
        self.drag.?.applied = travelled;

        // The tree moved: tell every subscriber where their panes are now.
        server.reportLayout(self.app.alloc) catch |err| {
            std.log.err("glyphwire-host: reportLayout(divider) failed: {t}", .{err});
        };
        return true;
    }
};
