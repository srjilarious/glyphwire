// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: GPL-3.0-or-later

//! Where gw-read's floating panels go: the OCR dialog relative to the
//! bubble it shows, and the lookup / AI panel relative to the dialog.
//!
//! Pure -- window cells in, window cells out -- so `tests/read_tests.zig`
//! can pin every rule down without a display server. `ui.zig` turns the
//! page layout and the bubble's box into the `Rect`s these take.
//!
//! **Margins first.** A page fitted to a window of a different shape
//! leaves empty columns either side of it, and a dialog placed there
//! covers no artwork at all. So the dialog tries the margin on its
//! bubble's side of the page, then the other one (`marginOrder`,
//! `inMargin`), and only then sits over the page next to the bubble
//! (`nearBubble`). Making a dialog *fit* a margin -- re-wrapping it
//! narrower -- is the caller's job; this only says whether it fits.

const std = @import("std");

/// A rect in window cells. Signed, because a bubble on a panned page can
/// start off screen.
pub const Rect = struct { row: i64, col: i64, rows: i64, cols: i64 };

/// The window area the page gets (all of it bar the status row).
pub const View = @import("glyphwire").zoom.View;

pub const Spot = struct { row: usize, col: usize };

/// A placed panel that may have been cut short to fit: `rows` is how
/// many rows of it show (the rest scroll).
pub const Slot = struct { row: usize, col: usize, rows: usize };

pub const Side = enum { left, right };

/// The empty columns either side of the page: `left` cells from the
/// window's left edge, `right` cells from `right_start` to its right edge.
/// Both zero when the page fills the window's width (zoomed, or a page
/// wider than the window's shape).
pub const Margins = struct {
    left: usize = 0,
    right: usize = 0,
    right_start: usize = 0,

    pub fn width(self: Margins, side: Side) usize {
        return switch (side) {
            .left => self.left,
            .right => self.right,
        };
    }
};

/// Narrowest margin worth re-wrapping a horizontal dialog into: the two
/// border and two pad cells, and room for a few characters a line.
pub const min_margin_cols: usize = 16;

/// The margins around a page whose left edge is at window column
/// `page_col` and which is `page_cols` cells wide.
pub fn margins(view: View, page_col: i64, page_cols: usize) Margins {
    const cols: i64 = @intCast(view.cols);
    const left: usize = @intCast(std.math.clamp(page_col, 0, cols));
    const right_start: usize = @intCast(std.math.clamp(page_col + @as(i64, @intCast(page_cols)), 0, cols));
    return .{ .left = left, .right = view.cols - right_start, .right_start = right_start };
}

/// The two margins in the order to try them: the one on the bubble's
/// side of the page first, so the dialog lands as near the bubble as a
/// margin can be.
pub fn marginOrder(page_col: i64, page_cols: usize, bubble: Rect) [2]Side {
    const page_mid = 2 * page_col + @as(i64, @intCast(page_cols));
    const bubble_mid = 2 * bubble.col + bubble.cols;
    return if (bubble_mid > page_mid) .{ .right, .left } else .{ .left, .right };
}

/// A `rows` x `cols` box in margin `side`: centred across the margin, its
/// top level with the bubble's (`bubble_row`) and pulled back on screen
/// if that would run it off the bottom. Null when it doesn't fit -- wider
/// than the margin, or taller than the window.
pub fn inMargin(m: Margins, side: Side, view: View, bubble_row: i64, rows: usize, cols: usize) ?Spot {
    const w = m.width(side);
    if (cols == 0 or cols > w or rows > view.rows) return null;
    const start = switch (side) {
        .left => 0,
        .right => m.right_start,
    };
    const max_row: i64 = @intCast(view.rows - rows);
    return .{
        .row = @intCast(std.math.clamp(bubble_row, 0, max_row)),
        .col = start + (w - cols) / 2,
    };
}

/// Over the page next to the bubble: below it when there is room, above
/// it when there isn't, left-aligned with it, and always wholly on
/// screen.
///
/// Below-first because a manga bubble's tail points down more often
/// than not, so the panel lands on the artwork you have already looked
/// past rather than on the panel you are about to read.
pub fn nearBubble(view: View, bubble: Rect, rows: usize, cols: usize) Spot {
    const max_row: i64 = @as(i64, @intCast(view.rows)) - @as(i64, @intCast(rows));
    const max_col: i64 = @as(i64, @intCast(view.cols)) - @as(i64, @intCast(cols));

    var row = bubble.row + bubble.rows;
    if (row > max_row) {
        const above = bubble.row - @as(i64, @intCast(rows));
        // Only move above if that actually fits; otherwise leave it below
        // and let the clamp pin it to the bottom edge, which is still
        // better than half off the top.
        if (above >= 0) row = above;
    }
    return .{
        .row = @intCast(std.math.clamp(row, 0, @max(max_row, 0))),
        .col = @intCast(std.math.clamp(bubble.col, 0, @max(max_col, 0))),
    };
}

/// A side panel `cols` wide and (ideally) `rows` tall beside `anchor` --
/// right of it, else left -- with its top level with the anchor's,
/// pulled up if it would run off the bottom, and cut to the window's
/// height. Null when neither side has `cols` columns free.
///
/// For a tall, narrow anchor: a vertical dialog, or one squeezed into a
/// margin. Stacking a panel under one of those leaves it no room at all.
pub fn beside(view: View, anchor: Slot, anchor_cols: usize, rows: usize, cols: usize) ?Slot {
    const shown = @max(@min(rows, view.rows), 1);
    const row = @min(anchor.row, view.rows -| shown);
    const right = anchor.col + anchor_cols;
    if (right + cols <= view.cols) return .{ .row = row, .col = right, .rows = shown };
    if (cols <= anchor.col) return .{ .row = row, .col = anchor.col - cols, .rows = shown };
    return null;
}

/// A side panel stacked under `anchor` (`anchor_rows` tall), or over it
/// when there's no room below, at the anchor's column. When it fits on
/// neither side whole, it takes the roomier one cut to fit -- if that is
/// at least `min_rows` -- and failing that the bottom of the window.
pub fn stacked(view: View, anchor: Slot, anchor_rows: usize, rows: usize, cols: usize, min_rows: usize) Slot {
    const col = @min(anchor.col, view.cols -| cols);
    const below = anchor.row + anchor_rows;
    const below_space = view.rows -| below;
    const above_space = @min(anchor.row, view.rows);

    if (rows <= below_space) return .{ .row = below, .col = col, .rows = rows };
    if (rows <= above_space) return .{ .row = anchor.row - rows, .col = col, .rows = rows };
    if (below_space >= above_space and below_space >= min_rows)
        return .{ .row = below, .col = col, .rows = below_space };
    if (above_space >= min_rows) return .{ .row = 0, .col = col, .rows = above_space };
    const fit = @max(@min(rows, view.rows), 1);
    return .{ .row = view.rows -| fit, .col = col, .rows = fit };
}
