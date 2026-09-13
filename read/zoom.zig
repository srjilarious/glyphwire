// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: GPL-3.0-or-later

//! The page's on-screen geometry: how big it is drawn, how many cells
//! that covers, where it sits when it's smaller than the window, and how
//! far it can be panned when it isn't.
//!
//! Pure -- pixels and cells in, pixels and cells out -- so
//! `tests/read_tests.zig` can pin the fit maths down without a display
//! server. `ui.zig` is the only caller; it turns a `Layout` into a
//! `set_property(size)` + `draw_image` + `set_property(cell_position)`
//! triple.
//!
//! **Why the layer is the size of the whole scaled page.** `draw_image`
//! samples from the image's top-left corner outward and has no source
//! offset, so the only way to show the middle of a zoomed page is to draw
//! the whole thing onto a layer bigger than the window and move the
//! window over it (`scroll_offset`, which the host also drives from the
//! wheel and the scrollbars). That costs one server-side cell per covered
//! cell, i.e. it grows with the square of the zoom factor, which is why
//! `Limits.max_scale` exists at all. See docs/decisions.md's "gw-read:
//! zoom, pan and the oversized page layer".

const std = @import("std");

/// How the page is sized against the window. `fit_screen` is the default
/// -- a whole page visible at once is what a comic reader is for.
pub const Mode = enum {
    /// Largest scale at which the whole page fits inside the window.
    fit_screen,
    /// Scaled so the page's width matches the window's; taller pages then
    /// scroll vertically.
    fit_width,
    /// Scaled so the page's height matches the window's.
    fit_height,
    /// One image pixel per screen pixel.
    natural,
    /// Whatever `Zoom.scale` was last stepped to by `+` / `-`.
    free,

    /// The short label the statusline shows.
    pub fn label(self: Mode) []const u8 {
        return switch (self) {
            .fit_screen => "fit",
            .fit_width => "width",
            .fit_height => "height",
            .natural => "1:1",
            .free => "zoom",
        };
    }
};

/// Bounds and step sizes for the free-zoom modes. Kept as data rather
/// than constants because `read.conf.lua` sets `max_zoom` -- the ceiling
/// is a memory decision (see the module comment), and someone with a lot
/// of RAM and a 4K scan may well want to raise it.
pub const Limits = struct {
    /// Below this a page is a smudge, and the cell span rounds to nothing.
    min_scale: f32 = 0.05,
    /// The cap on *every* mode, fit modes included. At 4x a 1600x2400
    /// scan covers roughly 300k cells on an 10x20px grid; each doubling
    /// past that quadruples the server-side cell count.
    max_scale: f32 = 4.0,
    /// Multiplicative step for one `+` / `-` press. 1.25 gives ~3 presses
    /// per doubling, which feels like a zoom rather than a jump.
    step: f32 = 1.25,
    /// Whether a fit mode may scale a page *up* to fill the window. On by
    /// default: a reader that leaves a 900px scan as a postage stamp in
    /// the middle of a 4K window isn't fitting anything.
    upscale: bool = true,
};

/// Everything the UI needs to place one page for one window size.
pub const Layout = struct {
    /// Uniform, aspect-preserving factor handed to `draw_image`'s `scale`.
    scale: f32,
    /// The cell span the scaled page covers -- the page layer's grid size
    /// and the `row_span`/`col_span` `draw_image` is called with.
    cols: usize,
    rows: usize,
    /// The layer's placement within the window, in cells. Non-zero only
    /// on an axis where the page is *smaller* than the window, which is
    /// how a fitted page ends up centred instead of jammed into the
    /// top-left corner.
    col: usize,
    row: usize,
    /// How far the window can be panned over the layer, in cells: the
    /// exclusive upper bound on `scroll_offset` for each axis. Zero on an
    /// axis with no overflow, which is also the UI's test for "an arrow
    /// key on this axis should turn the page instead of panning".
    max_pan_col: usize,
    max_pan_row: usize,
};

/// Pixel dimensions, of an image or of the window's content area.
pub const Size = struct { w: u32, h: u32 };

/// The window area the page is laid out against, in cells.
pub const View = struct { cols: usize, rows: usize };

/// Computes the page's geometry.
///
/// `view` is the window area the page gets, in cells; `cell` is the
/// session's cell metrics from `get_cell_metrics`. `free_scale` is only
/// read in `.free` mode. A zero-sized image or window yields a 1x1 layout
/// rather than a divide by zero -- a book whose first page failed to
/// measure should still leave the reader on screen to say so.
pub fn layout(
    mode: Mode,
    free_scale: f32,
    image: Size,
    view: View,
    cell: Size,
    limits: Limits,
) Layout {
    if (image.w == 0 or image.h == 0 or cell.w == 0 or cell.h == 0) {
        return .{ .scale = 1.0, .cols = 1, .rows = 1, .col = 0, .row = 0, .max_pan_col = 0, .max_pan_row = 0 };
    }

    const view_w: f32 = @floatFromInt(view.cols * cell.w);
    const view_h: f32 = @floatFromInt(view.rows * cell.h);
    const img_w: f32 = @floatFromInt(image.w);
    const img_h: f32 = @floatFromInt(image.h);

    const raw: f32 = switch (mode) {
        .fit_screen => @min(view_w / img_w, view_h / img_h),
        .fit_width => view_w / img_w,
        .fit_height => view_h / img_h,
        .natural => 1.0,
        .free => free_scale,
    };

    // `upscale = false` clamps the fit modes back to natural size; the
    // explicit modes (`natural`, `free`) are the user asking for a size
    // by name, so the flag doesn't touch them.
    const fitted = switch (mode) {
        .fit_screen, .fit_width, .fit_height => if (limits.upscale) raw else @min(raw, 1.0),
        .natural, .free => raw,
    };
    const scale = std.math.clamp(fitted, limits.min_scale, limits.max_scale);

    const cols = spanCells(img_w * scale, cell.w);
    const rows = spanCells(img_h * scale, cell.h);

    return .{
        .scale = scale,
        .cols = cols,
        .rows = rows,
        .col = (view.cols -| cols) / 2,
        .row = (view.rows -| rows) / 2,
        .max_pan_col = cols -| view.cols,
        .max_pan_row = rows -| view.rows,
    };
}

/// The next `free` scale after one `+` (`dir = .in`) or `-` (`dir = .out`),
/// clamped to `limits`. Split out so the key handler doesn't repeat the
/// clamp and so the step is testable on its own.
pub fn step(current: f32, dir: enum { in, out }, limits: Limits) f32 {
    const next = switch (dir) {
        .in => current * limits.step,
        .out => current / limits.step,
    };
    return std.math.clamp(next, limits.min_scale, limits.max_scale);
}

/// Clamps a pan offset to what the layout actually allows, so a pan that
/// runs off the edge stops there instead of scrolling the page out of
/// sight. Signed input because a pan step is a delta applied to a `usize`
/// offset and can legitimately go negative before clamping.
pub fn clampPan(offset: i64, max: usize) usize {
    if (offset <= 0) return 0;
    const off: usize = @intCast(offset);
    return @min(off, max);
}

/// Cells needed to cover `px` pixels, at least one. Pages are drawn from
/// their top-left corner, so a partially covered trailing cell still has
/// to exist for the last sliver of the page to land anywhere.
fn spanCells(px: f32, cell_px: u32) usize {
    if (px <= 0) return 1;
    const cells = @ceil(px / @as(f32, @floatFromInt(cell_px)));
    if (cells <= 1) return 1;
    // Guard the float -> int cast: a pathological scale/metric pair
    // shouldn't produce a layer size the server has to reject.
    if (cells >= 1 << 20) return 1 << 20;
    return @intFromFloat(cells);
}
