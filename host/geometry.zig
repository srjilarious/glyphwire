const std = @import("std");
const glyphwire = @import("glyphwire");

// The grid's initial size in cells; the window opens at this many cells
// times the measured cell pixel size. After that the window is
// user-resizable and `grid_cols`/`grid_rows` track its live size (see
// `window_sizing.WindowSizing.syncWindowSize`) -- `var`, not `const`, for
// that reason. `host.conf`'s `grid_cols` / `grid_rows` (and `--grid-cols` /
// `--grid-rows`, which win over the file) override the initial size at
// startup; see `config_load.loadConfig` and `main`.
pub const initial_grid_cols = 120;
pub const initial_grid_rows = 50;
pub var grid_cols: usize = initial_grid_cols;
pub var grid_rows: usize = initial_grid_rows;

// Floor the live grid size at something a shell prompt stays usable in,
// so dragging the window very small clips the render rather than
// collapsing the root layer to a degenerate size. A configured
// `grid_cols` / `grid_rows` is clamped up to these too.
pub const min_grid_cols = 16;
pub const min_grid_rows = 4;

// Blank margin, in pixels, kept on both sides of the composited layers:
// one strip against the window's left border, and one between the grid's
// right edge and the always-on scrollbar. Every layer's screen origin is
// shifted right by this, `cellFromPixel` subtracts it back out, and both
// the initial window width and `syncWindowSize`'s cell math reserve
// `2 * content_pad_px` (plus the scrollbar) so no column is lost to it.
pub const content_pad_px: i32 = 2;

// Cell size in pixels, set from the loaded font's own metrics at startup
// -- see `main`. `var` (not `const`) because `renderer.measureFontFile`
// has to run before the window exists (see the comment there), so these
// can't be comptime/const like the rest of this block.
pub var cell_w: i32 = undefined;
pub var cell_h: i32 = undefined;

// Scrollbar geometry, in pixels. Always drawn on the window's right
// edge (per the design decision -- a persistent scroll indicator, not
// an auto-hiding one). The thumb never shrinks below `scrollbar_min_thumb_px`
// so it stays grabbable even with a very deep scrollback.
pub const scrollbar_width_px: i32 = 12;
pub const scrollbar_min_thumb_px: f32 = 24;

/// How many grid rows one full wheel "tick" (`scroll().y` of magnitude
/// 1) scrolls the view by -- picked to feel like a normal terminal
/// scrollback, not tied to any particular OS's wheel step size.
pub const scroll_rows_per_tick: f32 = 3.0;

pub const ScrollbarGeom = struct {
    /// Left edge of the bar in window pixels.
    left: f32,
    track_h: f32,
    thumb_top: f32,
    thumb_h: f32,
};

/// Pure geometry: where the scrollbar track and thumb sit for a given
/// framebuffer size and scroll state. The thumb's *height* is the
/// visible fraction (`height / (history_len + height)`) of the track;
/// its *position* runs from flush-bottom at `view_scroll == 0` (live
/// tail) to flush-top at `view_scroll == history_len` (oldest retained
/// row).
pub fn scrollbarGeom(fb_w: i32, fb_h: i32, history_len: usize, height: usize, view_scroll: usize) ScrollbarGeom {
    const track_h: f32 = @floatFromInt(fb_h);
    const total: f32 = @floatFromInt(history_len + height);
    const view_h: f32 = @floatFromInt(height);

    var thumb_h: f32 = if (total > 0) track_h * (view_h / total) else track_h;
    thumb_h = std.math.clamp(thumb_h, @min(scrollbar_min_thumb_px, track_h), track_h);

    const rows_above_top: f32 = @floatFromInt(history_len - view_scroll);
    const top_frac: f32 = if (total > 0) rows_above_top / total else 0;
    var thumb_top = track_h * top_frac;
    const max_top = @max(track_h - thumb_h, 0);
    thumb_top = std.math.clamp(thumb_top, 0, max_top);

    return .{
        .left = @floatFromInt(fb_w - scrollbar_width_px),
        .track_h = track_h,
        .thumb_top = thumb_top,
        .thumb_h = thumb_h,
    };
}

/// Converts a pixel position (window-local, matching what
/// `eng.inputs.mouse.pos()` reports since host doesn't set a scaled
/// `logicalSize`) to a grid cell position, clamped to the grid bounds.
/// Subtracts `content_pad_px` first, since the layers are composited
/// shifted right by that much (see `render.Renderer.render`); a click in
/// the thin left margin just clamps to column 0.
pub fn cellFromPixel(x: f32, y: f32) glyphwire.CellPos {
    const col_f = (x - @as(f32, @floatFromInt(content_pad_px))) / @as(f32, @floatFromInt(cell_w));
    const row_f = y / @as(f32, @floatFromInt(cell_h));
    const max_col: f32 = @floatFromInt(grid_cols - 1);
    const max_row: f32 = @floatFromInt(grid_rows - 1);
    const col: usize = @intFromFloat(std.math.clamp(col_f, 0, max_col));
    const row: usize = @intFromFloat(std.math.clamp(row_f, 0, max_row));
    return .{ .row = row, .col = col };
}
