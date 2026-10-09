// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: MPL-2.0

//! A panel background built from one image: the four corners are drawn at
//! their native pixel size, the four edges stretch along their long axis,
//! and the center stretches both ways. The art is an Android-style
//! `.9.png` -- a 1px guide border around the real image whose black pixels
//! on the top row and left column mark the stretchable span (see
//! `parseNinePatch`). Replaced `draw_box`'s nine-separate-tiles model,
//! where every piece was one whole cell: a corner there took the cell's
//! aspect ratio (usually ~1:2), so rounded or alpha-feathered corners
//! squashed, and nothing could line up finer than a cell.
//!
//! Placed by cell rect (`row`/`col`/`rows`/`cols`) rather than pixels,
//! because the thing a client wants framed is a run of cells; the host
//! turns it into pixels at render time with the live cell metrics, so a
//! font resize keeps the frame on its cells with the corners still at
//! native size. A component of the layer it's drawn on (`Layer.nine_patches`),
//! like `Rect`, and drawn under every cell background -- see decisions.md's
//! Nine-patch section.

const std = @import("std");
const core = @import("core.zig");

const ImageHandle = core.ImageHandle;

pub const NinePatchHandle = u32;

pub const NinePatchError = error{UnknownNinePatch};

/// Why `parseNinePatch` rejected an image.
pub const NinePatchParseError = error{
    /// Smaller than 3x3: no room for a guide border and any art.
    NinePatchTooSmall,
    /// The top row or left column has no black guide pixel, so there is
    /// no stretchable span on that axis.
    NinePatchMissingStretch,
    /// A guide row/column has more than one black run. Android allows
    /// several stretch segments; one is all glyphwire's art needs.
    NinePatchSplitStretch,
};

/// The fixed (non-stretching) border widths of a nine-patch's art, in
/// source pixels: `left`/`right` are the corner widths, `top`/`bottom`
/// the corner heights. Everything between them stretches.
pub const NinePatchInsets = struct {
    left: u32,
    top: u32,
    right: u32,
    bottom: u32,
};

/// A registered nine-patch: the loaded `.9.png` (guide border and all --
/// the renderer samples only inside it) plus what `parseNinePatch` read
/// out of the guides. `width`/`height` are the art's size *without* the
/// 1px guide border.
pub const NinePatchStyle = struct {
    image: ImageHandle,
    width: u32,
    height: u32,
    insets: NinePatchInsets,
};

/// Reads a `.9.png`'s stretch guides from its decoded RGBA8 pixels
/// (`w * h * 4` bytes). A guide pixel is opaque black; the top row
/// (excluding its two corner pixels) marks the horizontal stretch span and
/// the left column the vertical one. The right/bottom guides (Android's
/// content padding) are ignored -- placement is by cell rect, so there is
/// no content box to pad. Pure so it can be tested headlessly; the host
/// decodes the PNG and calls this (the core never decodes pixels).
pub fn parseNinePatch(rgba: []const u8, w: u32, h: u32) NinePatchParseError!NinePatchStyle {
    if (w < 3 or h < 3) return NinePatchParseError.NinePatchTooSmall;
    const h_span = try guideSpan(rgba, w, 1, w - 1, .row);
    const v_span = try guideSpan(rgba, w, 1, h - 1, .column);
    const inner_w = w - 2;
    const inner_h = h - 2;
    return .{
        .image = 0,
        .width = inner_w,
        .height = inner_h,
        .insets = .{
            .left = h_span.first - 1,
            .right = inner_w - h_span.last,
            .top = v_span.first - 1,
            .bottom = inner_h - v_span.last,
        },
    };
}

/// The single run of black guide pixels between `from` and `to`
/// (exclusive) along the top row or the left column, as `[first, last]`
/// inclusive in full-image coordinates.
fn guideSpan(rgba: []const u8, w: u32, from: u32, to: u32, axis: enum { row, column }) NinePatchParseError!struct { first: u32, last: u32 } {
    var first: ?u32 = null;
    var last: u32 = 0;
    var i = from;
    while (i < to) : (i += 1) {
        const px: usize = if (axis == .row) i else @as(usize, i) * w;
        const p = rgba[px * 4 .. px * 4 + 4];
        const is_guide = p[0] == 0 and p[1] == 0 and p[2] == 0 and p[3] == 255;
        if (!is_guide) continue;
        if (first != null and i != last + 1) return NinePatchParseError.NinePatchSplitStretch;
        if (first == null) first = i;
        last = i;
    }
    return .{ .first = first orelse return NinePatchParseError.NinePatchMissingStretch, .last = last };
}

/// One nine-patch drawn on a layer: which style, and the cell rect it
/// frames, in the layer's own content coordinates (so, like `Rect`, it
/// pans with `scroll_offset`).
pub const NinePatch = struct {
    style: NinePatchStyle,
    row: usize,
    col: usize,
    rows: usize,
    cols: usize,
};

/// `update_nine_patch`'s partial patch, same "`null` leaves it unchanged"
/// convention as `RectUpdate`.
pub const NinePatchUpdate = struct {
    style: ?NinePatchStyle = null,
    row: ?usize = null,
    col: ?usize = null,
    rows: ?usize = null,
    cols: ?usize = null,
};

/// One of the up to nine quads a nine-patch splits into: `src` is in the
/// `.9.png`'s own pixels (guide border included, so the renderer can
/// normalize by the whole texture), `dst` is relative to the patch's
/// top-left corner. Either may be zero-sized, which the renderer skips.
pub const NinePatchQuad = struct {
    src_x: u32,
    src_y: u32,
    src_w: u32,
    src_h: u32,
    dst_x: u32,
    dst_y: u32,
    dst_w: u32,
    dst_h: u32,
};

/// Splits `style` over a `dst_w x dst_h` pixel rect: corners at native
/// size, edges and center stretched to fill what's left. When the rect
/// is narrower (or shorter) than the two corners together, both corners
/// shrink in proportion and the middle column (row) disappears, rather
/// than the corners overlapping. Row-major, top-left first.
pub fn ninePatchQuads(style: NinePatchStyle, dst_w: u32, dst_h: u32) [9]NinePatchQuad {
    const src_cols = [3]u32{ style.insets.left, style.width -| (style.insets.left + style.insets.right), style.insets.right };
    const src_rows = [3]u32{ style.insets.top, style.height -| (style.insets.top + style.insets.bottom), style.insets.bottom };
    const dst_cols = ninePatchSplit(style.insets.left, style.insets.right, dst_w);
    const dst_rows = ninePatchSplit(style.insets.top, style.insets.bottom, dst_h);

    var out: [9]NinePatchQuad = undefined;
    var sy: u32 = 1; // skip the guide row
    var dy: u32 = 0;
    for (0..3) |r| {
        var sx: u32 = 1; // skip the guide column
        var dx: u32 = 0;
        for (0..3) |c| {
            out[r * 3 + c] = .{
                .src_x = sx,
                .src_y = sy,
                .src_w = src_cols[c],
                .src_h = src_rows[r],
                .dst_x = dx,
                .dst_y = dy,
                .dst_w = dst_cols[c],
                .dst_h = dst_rows[r],
            };
            sx += src_cols[c];
            dx += dst_cols[c];
        }
        sy += src_rows[r];
        dy += dst_rows[r];
    }
    return out;
}

/// `ninePatchQuads`' per-axis split of `total` destination pixels into
/// `[start corner, middle, end corner]`.
fn ninePatchSplit(start: u32, end: u32, total: u32) [3]u32 {
    const corners = start + end;
    if (corners <= total) return .{ start, total - corners, end };
    const scaled_start: u32 = @intCast(@as(u64, total) * start / corners);
    return .{ scaled_start, 0, total - scaled_start };
}
