// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: MPL-2.0

//! Cell-writing helpers shared by the layer components that compile into
//! ordinary cells -- `Table` and `Outline` -- plus `Context`, which clears a
//! component's painted extent when it is destroyed. The cell writers take
//! a signed row (see `Layer.rowAtSigned`), so a component that has partly
//! scrolled into scrollback still repaints in place.

const std = @import("std");
const core = @import("core.zig");

const Color = core.Color;
const Decoration = core.Decoration;
const HAlign = core.HAlign;
const IconScale = core.IconScale;
const ImageHandle = core.ImageHandle;
const Layer = core.Layer;
const MetadataHandle = core.MetadataHandle;
const VAlign = core.VAlign;
const default_style = core.default_style;

/// Where a layer component (`Table`, `Outline`) last painted -- used to
/// blank that whole region before repainting a possibly-smaller one (fewer
/// rows, a narrower style, a collapsed node) so a shrinking component
/// doesn't leave stale cells behind past its new content's edge.
pub const PaintedExtent = struct {
    row: usize = 0,
    col: usize = 0,
    rows: usize = 0,
    cols: usize = 0,
};

pub fn clearExtent(layer: *Layer, extent: PaintedExtent) void {
    if (extent.rows == 0 or extent.cols == 0) return;
    layer.clear(extent.row, extent.col, extent.rows, extent.cols);
}

/// Scrolls `layer` just far enough that a `piece_h`-row table piece about
/// to be drawn at `cur_row.*` sits fully above the viewport's bottom edge
/// -- the "make room for the next line" a terminal does as output flows
/// past the bottom. Each scrolled-off row keeps whatever the table already
/// wrote into it (`Table.render` draws top-down), so only real content
/// ever reaches scrollback. `scrolled.*` accumulates the total so
/// `render` can locate the table's top afterwards; scrolling stops once
/// that total reaches the layer's capacity, past which the excess rows
/// just clip (a table longer than viewport + scrollback).
pub fn tableMakeRoom(layer: *Layer, cur_row: *usize, scrolled: *usize, piece_h: usize) void {
    const past_bottom = cur_row.* + piece_h;
    if (past_bottom <= layer.height) return;
    const want = past_bottom - layer.height;
    const budget = layer.capacity() -| scrolled.*;
    const n = @min(want, budget);
    var i: usize = 0;
    while (i < n) : (i += 1) layer.scrollOne();
    scrolled.* += n;
    cur_row.* -|= n;
}

pub fn setCellText(layer: *Layer, row: i64, col: usize, grapheme: []const u8, fg: Color, bg: ?Color, metadata_id: ?MetadataHandle, deco: Decoration) void {
    const c = layer.cellSigned(row, col) orelse return;
    c.setGrapheme(grapheme);
    c.style = .{
        .fg = fg,
        .bg = if (bg) |b| .{ .color = b } else default_style.bg,
        .underline = deco.underline,
        .strike = deco.strike,
    };
    c.metadata_id = metadata_id;
    c.meta_focus = false;
    c.wide = .narrow;
    c.under_scaled = 0;
    c.selectable = true;
    c.masked = false;
    c.copy_alt = 0;
}

/// Writes a 2-cell wide grapheme: the lead cell at `(row, col)` holds it,
/// `(row, col + 1)` becomes a blank spacer carrying the lead's resolved
/// style + `metadata_id`. Caller guarantees `col + 1` is in range. Used
/// by `writeCellRun` so table cells advance the same way `writeText` does.
pub fn setCellWide(layer: *Layer, row: i64, col: usize, grapheme: []const u8, fg: Color, bg: ?Color, metadata_id: ?MetadataHandle, deco: Decoration) void {
    if (col + 1 >= layer.width) return;
    const cells = layer.rowAtSigned(row) orelse return;
    const lead = &cells[col];
    lead.setGrapheme(grapheme);
    lead.style = .{
        .fg = fg,
        .bg = if (bg) |b| .{ .color = b } else default_style.bg,
        .underline = deco.underline,
        .strike = deco.strike,
    };
    lead.metadata_id = metadata_id;
    lead.meta_focus = false;
    lead.wide = .wide_lead;
    lead.under_scaled = 0;
    lead.selectable = true;
    lead.masked = false;
    lead.copy_alt = 0;
    cells[col + 1] = .{ .style = lead.style, .metadata_id = metadata_id, .wide = .wide_spacer };
}

pub fn setCellIcon(layer: *Layer, row: i64, col: usize, handle: ImageHandle, scale: IconScale, h_align: HAlign, v_align: VAlign, max_h: ?u32, metadata_id: ?MetadataHandle) void {
    const c = layer.cellSigned(row, col) orelse return;
    c.style.bg = .{ .icon = .{ .handle = handle, .scale = scale, .h_align = h_align, .v_align = v_align, .max_h = max_h } };
    c.metadata_id = metadata_id;
    c.meta_focus = false;
}

/// Like `setCellIcon`, but writes the icon into `Cell.fg_icon` instead of
/// `style.bg` -- see that field's doc comment. Leaves whatever background
/// the cell already carries (a `fillRowBg` `alt_row_bg` stripe, or the
/// default) in place, so `glyphwire-host`'s render pass composites the
/// icon *over* it rather than replacing it. Table body icons always take
/// this path: an icon should sit above its row's background, and a
/// `.natural`-scaled one that overflows past its anchor cell has to paint
/// over the neighboring rows'/columns' backgrounds too -- the host defers
/// `.natural` `fg_icon`s past the whole grid for exactly that, the same
/// way it already does for `style.bg`'s `.icon` overflow.
pub fn setCellIconOver(layer: *Layer, row: i64, col: usize, handle: ImageHandle, scale: IconScale, h_align: HAlign, v_align: VAlign, max_h: ?u32, metadata_id: ?MetadataHandle) void {
    const c = layer.cellSigned(row, col) orelse return;
    c.fg_icon = .{ .handle = handle, .scale = scale, .h_align = h_align, .v_align = v_align, .max_h = max_h };
    c.metadata_id = metadata_id;
    c.meta_focus = false;
}
