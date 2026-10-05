// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: MPL-2.0

//! Resolving a pixel to the layer under it, and to a cell in that layer's
//! own **content** grid -- the coordinate space `Table.col`/`Table.top_live`
//! and `Outline.col`/`Outline.top_live` live in.
//!
//! Split out of `table_sort.zig` once `outline_toggle.zig` needed the same
//! walk. `selection.zig`'s `layerAt` is a third near-copy, kept separate
//! because it wants a scroll-stable `SelectionPoint` rather than a content
//! cell.

const std = @import("std");
const glyphwire = @import("glyphwire");

const geometry = @import("geometry.zig");

pub const LayerTarget = struct {
    layer: *glyphwire.Layer,
    row: usize,
    col: usize,
    is_root: bool,
    /// The layer's own handle, or null for the root layer -- exactly what
    /// `Server.reportLayerScroll` and the `scroll` notification's `layer`
    /// field want, so a caller that has to move this layer's view doesn't
    /// have to re-walk `layer_order` looking for it.
    handle: ?glyphwire.LayerHandle,
};

/// Top-most visible `create_layer` layer whose bounds contain the pixel,
/// else the root layer. Matches how the renderer composites them, so a
/// layer covers what is under it for clicks the same way it does for
/// pixels.
///
/// The caller holds `ctx_mutex`.
pub fn layerUnder(ctx: *glyphwire.Context, px: f32, py: f32) ?LayerTarget {
    const origin = geometry.contextOrigin(ctx);
    var i = ctx.layer_order.items.len;
    while (i > 0) {
        i -= 1;
        const layer = ctx.layers.getPtr(ctx.layer_order.items[i]) orelse continue;
        if (!layer.visible) continue;
        const cols = layer.viewportCols();
        const rows = layer.viewportRows();
        const rect = geometry.layerRectIn(origin, layer.pos, cols, rows);
        if (!rect.contains(px, py)) continue;
        // Viewport cell -> content cell: a host-scrolled pane shows the
        // slice of its grid starting at `scroll_off`. A terminal-style
        // layer (the shell panel) has `scroll_off` zero and uses
        // `view_scroll` instead, which the component's own hit-test
        // applies itself.
        const vcol: usize = @intFromFloat(@max(0, (px - rect.x) / @as(f32, @floatFromInt(geometry.cell_w))));
        const vrow: usize = @intFromFloat(@max(0, (py - rect.y) / @as(f32, @floatFromInt(geometry.cell_h))));
        if (vcol >= cols or vrow >= rows) return null;
        return .{
            .layer = layer,
            .row = layer.scroll_off.row + vrow,
            .col = layer.scroll_off.col + vcol,
            .is_root = false,
            .handle = ctx.layer_order.items[i],
        };
    }
    const cell = geometry.cellFromPixel(px, py);
    return .{ .layer = &ctx.root, .row = cell.row, .col = cell.col, .is_root = true, .handle = null };
}
