// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: MPL-2.0

//! The host's side of both split trees: the divider geometry it draws and
//! hit-tests, and the drag that resizes things.
//!
//! There are two levels, and they are hit-tested together because a mouse
//! doesn't know the difference:
//!
//! - **Pane dividers** are the bands between whole panes, from the
//!   session's pane tree (`core.Session`). Dragging one resizes two
//!   programs' surfaces against each other.
//! - **Layer dividers** are the bands inside one context, from that
//!   context's own split tree (`core.Context`). Dragging one resizes two
//!   panes *within* one program (zoe's sidebar against its buffer).
//!
//! A third kind of band rides along: a floating layer's `resize_edge`
//! (the Ctrl+` shell panel's top). It belongs to no tree, so it isn't in
//! the band cache -- it is found live by `edgeAt` -- and finishing its
//! drag resizes nothing here, it only tells the layer's client.
//!
//! `core` owns both trees and both layout walks; this is the part that
//! needs a mouse and a framebuffer. Both `render.zig` (drawing the bands)
//! and `scroll.zig` (routing a wheel tick) read through here, which is why
//! the caches live in one place rather than in either of them.

const std = @import("std");
const glyphwire = @import("glyphwire");

const app_mod = @import("app.zig");
const geometry = @import("geometry.zig");
const hit = @import("hit.zig");

const App = app_mod.App;

/// A layer's on-screen viewport rect, plus what it belongs to.
pub const PaneHit = struct {
    /// The context the layer lives in -- needed because layer handles are
    /// per-context, so a bare handle is ambiguous once more than one pane
    /// is on screen.
    context: glyphwire.ContextHandle,
    layer: glyphwire.LayerHandle,
    rect: geometry.RectPx,
    /// True when the pane has viewport slack over a larger content grid
    /// (a file tree, an editor buffer) -- a wheel moves its `scroll_offset`.
    /// False when it only has a scrollback ring (a terminal pane) -- a
    /// wheel moves its `view_scroll` through `Server.reportLayerScrollIn`.
    scrolls_viewport: bool,
};

/// The topmost visible, scrollable layer whose viewport contains
/// `(px, py)`, searched within whichever pane's context is under that
/// point.
///
/// Walks `layer_order` backwards because later entries composite on top,
/// so the last match is the one the user is actually pointing at. The "has
/// something to scroll" test (`scrollsAnywhere` for a viewport over a
/// bigger content grid, `hasScrollback` for a terminal-style layer with a
/// retained ring) is on purpose: a wheel over a layer with nothing to
/// scroll should fall through to the context's root scrollback underneath
/// rather than being silently swallowed.
///
/// The caller must hold `ctx_mutex`.
pub fn scrollablePaneAt(
    ctx_handle: glyphwire.ContextHandle,
    ctx: *glyphwire.Context,
    px: f32,
    py: f32,
) ?PaneHit {
    const origin = geometry.contextOrigin(ctx);
    var i = ctx.layer_order.items.len;
    while (i > 0) {
        i -= 1;
        const handle = ctx.layer_order.items[i];
        const layer = ctx.layers.getPtr(handle) orelse continue;
        if (!layer.visible) continue;
        const slack = layer.scrollsAnywhere();
        if (!slack and !layer.hasScrollback()) continue;
        const rect = geometry.layerRectIn(origin, layer.pos, layer.viewportCols(), layer.viewportRows());
        if (rect.contains(px, py)) return .{
            .context = ctx_handle,
            .layer = handle,
            .rect = rect,
            .scrolls_viewport = slack,
        };
    }
    return null;
}

/// One draggable band, at either level, already in **window** cells.
pub const Band = struct {
    /// Which tree this band belongs to.
    level: Level,
    /// `SplitHandle` for `.layer`, `PaneSplitHandle` for `.pane` -- both
    /// are `u32`, and the level says which map to look it up in.
    split: u32,
    index: usize,
    axis: glyphwire.SplitAxis,
    rect: glyphwire.CellRect,

    pub const Level = union(enum) {
        /// The window-level pane tree, owned by the session.
        pane,
        /// One context's own layer split tree.
        layer: glyphwire.ContextHandle,
        /// A floating layer's `resize_edge`. Never in `bands` -- see
        /// `Panes.edgeAt` -- but a drag of one rides the same `Drag`.
        edge: Edge,
    };

    pub const Edge = struct {
        context: glyphwire.ContextHandle,
        layer: glyphwire.LayerHandle,
        /// The layer's height when the drag started; the drag's travel
        /// is applied to this.
        rows: usize,
    };
};

/// Divider geometry for both trees, plus the in-progress drag. One per
/// `App`.
pub const Panes = struct {
    app: *App,

    /// Every draggable band currently on screen, pane-level and
    /// layer-level pooled together and all translated into window cells.
    /// Rebuilt only when a layout generation moves: a resize, a tree edit,
    /// or a completed drag. Empty for every session that is neither
    /// multiplexed nor running a TUI.
    bands: std.ArrayList(Band) = .empty,
    /// Scratch reused across rebuilds so a per-frame sync doesn't allocate.
    layer_scratch: std.ArrayList(glyphwire.DividerRect) = .empty,
    pane_scratch: std.ArrayList(glyphwire.PaneDividerRect) = .empty,
    /// The generations `bands` was built at: the session's pane tree, and
    /// the summed layer-tree generations of every on-screen context (a sum
    /// changes whenever any one of them does, which is all this needs to
    /// know).
    pane_gen: u64 = 0,
    layer_gen: u64 = 0,
    built: bool = false,

    /// The divider currently being pulled.
    ///
    /// `pending` is how many cells the pointer has travelled from the grab
    /// point along the split's axis -- not yet applied. The layout isn't
    /// touched until the drag ends: a single `moveDivider` +
    /// `reportLayout` then, rather than one per frame, so the programs
    /// inside the panes don't redraw on every mouse-move.
    drag: ?Drag = null,

    /// While `drag` is set, the previewed band position in pixels --
    /// `render.zig` draws a ghost divider here. Null otherwise.
    preview: ?geometry.RectPx = null,

    pub const Drag = struct {
        level: Band.Level,
        split: u32,
        index: usize,
        axis: glyphwire.SplitAxis,
        grab_px: f32,
        /// The divider's pixel rect at grab time -- the ghost is this,
        /// shifted by `pending` cells along the axis.
        base: geometry.RectPx,
        pending: i64 = 0,
    };

    pub fn deinit(self: *Panes) void {
        const alloc = self.app.alloc;
        self.bands.deinit(alloc);
        self.layer_scratch.deinit(alloc);
        self.pane_scratch.deinit(alloc);
    }

    /// Refreshes the band cache if either layout has moved since it was
    /// built. The caller must hold `ctx_mutex`.
    pub fn syncLocked(self: *Panes) void {
        const server = self.app.server;
        const alloc = self.app.alloc;

        const pane_gen = server.session.pane_layout_gen.load(.monotonic);
        var layer_gen: u64 = 0;
        {
            var it = server.session.panes.valueIterator();
            while (it.next()) |pane| {
                if (!pane.mapped) continue;
                const ctx = server.session.contextPtr(pane.top()) orelse continue;
                layer_gen +%= ctx.layout_gen;
            }
        }
        if (self.built and self.pane_gen == pane_gen and self.layer_gen == layer_gen) return;

        self.bands.clearRetainingCapacity();

        // Pane-level bands first, so a hit test that walks in order finds
        // the outer structure before anything inside a pane. (The two can't
        // actually overlap -- a pane's contents stop at its rect -- but
        // ordering it this way keeps the intent obvious.)
        self.pane_scratch.clearRetainingCapacity();
        server.session.layoutPanes(null, &self.pane_scratch) catch return;
        for (self.pane_scratch.items) |d| {
            self.bands.append(alloc, .{
                .level = .pane,
                .split = d.split,
                .index = d.index,
                .axis = d.axis,
                .rect = d.rect,
            }) catch return;
        }

        var it = server.session.panes.valueIterator();
        while (it.next()) |pane| {
            if (!pane.mapped) continue;
            const ctx_handle = pane.top();
            const ctx = server.session.contextPtr(ctx_handle) orelse continue;
            self.layer_scratch.clearRetainingCapacity();
            // A failed re-layout skips this context's bands rather than
            // abandoning the whole cache; the next frame tries again.
            ctx.layoutSplits(null, &self.layer_scratch) catch continue;
            for (self.layer_scratch.items) |d| {
                self.bands.append(alloc, .{
                    .level = .{ .layer = ctx_handle },
                    .split = d.split,
                    .index = d.index,
                    .axis = d.axis,
                    // Context-relative -> window cells. This is the only
                    // place a layer divider's coordinates leave its
                    // context's frame of reference.
                    .rect = .{
                        .row = d.rect.row + ctx.origin_row,
                        .col = d.rect.col + ctx.origin_col,
                        .cols = d.rect.cols,
                        .rows = d.rect.rows,
                    },
                }) catch return;
            }
        }

        self.pane_gen = pane_gen;
        self.layer_gen = layer_gen;
        self.built = true;
    }

    /// The band under `(px, py)`, if any. Call `syncLocked` first.
    /// Takes `ctx_mutex` itself, briefly, for the occlusion test below --
    /// so the caller must *not* hold it.
    ///
    /// A layer band that something is drawn over is not a hit. A split's
    /// own children sit either side of its band and never on it, so the
    /// only thing that can cover one is a layer that *floats* -- a popup,
    /// the Ctrl+` shell panel -- and a band the user cannot see is not one
    /// they can mean to drag. zoe's tree divider runs the full height of
    /// its split, so without this a click into the column of the panel it
    /// crosses resized the sidebar instead of reaching the shell.
    pub fn dividerAt(self: *const Panes, px: f32, py: f32) ?Band {
        for (self.bands.items) |d| {
            if (!geometry.cellRectPx(d.rect).contains(px, py)) continue;
            switch (d.level) {
                // Pane bands separate whole programs and sit outside every
                // context's own area, so nothing can be over them.
                .pane => return d,
                .layer => |h| if (!self.layerCovers(h, px, py)) return d,
                .edge => unreachable, // never cached; see `edgeAt`
            }
        }
        return null;
    }

    /// A floating layer's `resize_edge` under `(px, py)`, with the
    /// layer's window rect. Takes `ctx_mutex` itself, so the caller must
    /// not hold it.
    ///
    /// Found live rather than cached with the split bands: what moves an
    /// edge is the layer being resized, moved or shown, none of which
    /// bumps a context's `layout_gen`, and there is at most one of these
    /// on screen, so walking the layers on a press is cheap.
    ///
    /// Walked top layer first, and a layer that covers the point without
    /// an edge there ends the search in that context: an edge something
    /// is drawn over (a completion popup over the panel's top row) is not
    /// one the user can mean to grab.
    pub fn edgeAt(self: *const Panes, px: f32, py: f32) ?struct { edge: Band.Edge, rect: geometry.RectPx } {
        const server = self.app.server;
        server.ctx_mutex.lockUncancelable(server.io);
        defer server.ctx_mutex.unlock(server.io);

        var it = server.session.panes.valueIterator();
        while (it.next()) |pane| {
            if (!pane.mapped) continue;
            const ctx_handle = pane.top();
            const ctx = server.session.contextPtr(ctx_handle) orelse continue;
            const origin = geometry.contextOrigin(ctx);
            var i = ctx.layer_order.items.len;
            while (i > 0) {
                i -= 1;
                const handle = ctx.layer_order.items[i];
                const layer = ctx.layers.getPtr(handle) orelse continue;
                if (!layer.visible) continue;
                const rect = geometry.layerRectIn(origin, layer.pos, layer.viewportCols(), layer.viewportRows());
                if (layer.resize_edge == .top and geometry.resizeEdgeHit(rect).contains(px, py)) return .{
                    .edge = .{ .context = ctx_handle, .layer = handle, .rows = layer.viewportRows() },
                    .rect = rect,
                };
                if (rect.contains(px, py)) break;
            }
        }
        return null;
    }

    /// Whether a visible non-root layer of context `h` is drawn over this
    /// pixel -- the occlusion test `dividerAt` runs on a layer band.
    fn layerCovers(self: *const Panes, h: glyphwire.ContextHandle, px: f32, py: f32) bool {
        const server = self.app.server;
        server.ctx_mutex.lockUncancelable(server.io);
        defer server.ctx_mutex.unlock(server.io);
        const ctx = server.session.contextPtr(h) orelse return false;
        const t = hit.layerUnder(ctx, px, py) orelse return false;
        return !t.is_root;
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
        const pressed = eng.inputs.mouse.pressed(.left);
        if (!pressed and self.drag == null) return false;

        if (pressed) {
            const band = self.dividerAt(pos.x, pos.y) orelse {
                const e = self.edgeAt(pos.x, pos.y) orelse return false;
                const base = geometry.resizeEdgeBand(e.rect);
                self.drag = .{
                    .level = .{ .edge = e.edge },
                    .split = 0,
                    .index = 0,
                    // A top edge moves up and down, like the band of a
                    // column split.
                    .axis = .column,
                    .grab_px = pos.y,
                    .base = base,
                };
                self.preview = base;
                return true;
            };
            self.drag = .{
                .level = band.level,
                .split = band.split,
                .index = band.index,
                .axis = band.axis,
                .grab_px = if (band.axis == .row) pos.x else pos.y,
                .base = geometry.cellRectPx(band.rect),
            };
            self.preview = geometry.cellRectPx(band.rect);
            return true;
        }

        const drag = self.drag orelse return false;

        // Pointer travel since the grab, in cells along the split's axis.
        const cur: f32 = if (drag.axis == .row) pos.x else pos.y;
        const cell: f32 = @floatFromInt(if (drag.axis == .row) geometry.cell_w else geometry.cell_h);
        const travelled: i64 = @intFromFloat(@round((cur - drag.grab_px) / @max(cell, 1)));

        if (!eng.inputs.mouse.down(.left)) {
            // Drag ended: apply the whole move once, then re-lay-out once.
            self.drag = null;
            self.preview = null;
            if (travelled != 0) self.applyDrag(drag, travelled);
            return true;
        }

        // Still dragging: just move the ghost. The layout is untouched
        // until release, so nothing downstream redraws mid-drag.
        self.drag.?.pending = travelled;
        var ghost = drag.base;
        const shift_px = @as(f32, @floatFromInt(travelled)) * cell;
        if (drag.axis == .row) {
            ghost.x += shift_px;
        } else {
            ghost.y += shift_px;
        }
        self.preview = ghost;
        return true;
    }

    /// Commits a finished drag to whichever tree it belongs to. A pane
    /// drag goes through the full pane-layout path, which resizes the
    /// programs' contexts and sends each one its own new size; a layer drag
    /// only reshuffles layers inside one context.
    fn applyDrag(self: *Panes, drag: Drag, travelled: i64) void {
        const server = self.app.server;
        switch (drag.level) {
            .pane => {
                {
                    server.ctx_mutex.lockUncancelable(server.io);
                    defer server.ctx_mutex.unlock(server.io);
                    server.session.movePaneDivider(drag.split, drag.index, travelled) catch {};
                }
                server.applyPaneLayout(self.app.alloc) catch |err| {
                    std.log.err("glyphwire-host: pane divider drag failed: {t}", .{err});
                };
            },
            .layer => |ctx_handle| {
                {
                    server.ctx_mutex.lockUncancelable(server.io);
                    defer server.ctx_mutex.unlock(server.io);
                    const ctx = server.session.contextPtr(ctx_handle) orelse return;
                    ctx.moveDivider(drag.split, drag.index, travelled) catch {};
                }
                server.reportLayout(self.app.alloc) catch |err| {
                    std.log.err("glyphwire-host: reportLayout(divider) failed: {t}", .{err});
                };
            },
            .edge => |e| {
                // Dragging a top edge up (negative travel) makes the layer
                // taller. Floored at one row so the edge stays grabbable;
                // every other bound is the client's call.
                const rows: usize = @intCast(@max(@as(i64, @intCast(e.rows)) - travelled, 1));
                if (rows == e.rows) return;
                server.reportLayerResize(self.app.alloc, e.context, e.layer, rows) catch |err| {
                    std.log.err("glyphwire-host: reportLayerResize failed: {t}", .{err});
                };
            },
        }
    }
};
