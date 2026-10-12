// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: MPL-2.0

const std = @import("std");
const glyphwire = @import("glyphwire");

// The grid's initial size in cells; the window opens at this many cells
// times the measured cell pixel size. After that the window is
// user-resizable and `grid_cols`/`grid_rows` track its live size (see
// `window_sizing.WindowSizing.syncWindowSize`) -- `var`, not `const`, for
// that reason. `host.conf.lua`'s `grid_cols` / `grid_rows` (and `--grid-cols` /
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

// How long the window size must hold still before `syncWindowSize`
// commits a new grid size (one `reportResize` + `resize` broadcast, and
// the client reflow that follows). During a drag-resize the old grid is
// drawn clipped/letterboxed into the new framebuffer instead, so a
// TUI's panes and a shell's reflow don't churn on every intermediate
// pixel size.
pub const resize_settle_ms: i64 = 120;

pub const GridSize = struct { cols: usize, rows: usize };

/// What `WindowSizing.syncWindowSize` should do with a freshly measured
/// grid size, given the committed size and the pending-resize state.
/// Pure, so `tests/host_tests.zig` covers the debounce with no window.
pub const ResizeSettleStep = enum {
    /// The measured size matches the committed one -- drop any pending.
    settled,
    /// The size is still moving -- (re)start the settle timer.
    restart,
    /// A new size, holding steady but not long enough yet -- keep waiting.
    wait,
    /// Held steady past `resize_settle_ms` -- commit it now.
    commit,
};

pub fn resizeSettleStep(
    committed: GridSize,
    target: GridSize,
    pending: ?GridSize,
    elapsed_ms: f64,
) ResizeSettleStep {
    if (target.cols == committed.cols and target.rows == committed.rows) return .settled;
    const p = pending orelse return .restart;
    if (p.cols != target.cols or p.rows != target.rows) return .restart;
    if (elapsed_ms < @as(f64, @floatFromInt(resize_settle_ms))) return .wait;
    return .commit;
}

pub const PxSize = struct { w: i32, h: i32 };

/// How many whole cells of `cell_px_w` x `cell_px_h` fit a framebuffer of
/// `fb` pixels, after the right `gutter` and a `content_pad_px` margin on
/// each side. A leftover fractional cell is floored away (the render
/// letterboxes it), and the result never drops below `min_grid_*`, so a
/// window too small for the minimum grid clips rather than collapsing.
pub fn gridForFramebuffer(fb: PxSize, gutter: i32, cell_px_w: i32, cell_px_h: i32) GridSize {
    return .{
        .cols = @intCast(@max(@divTrunc(fb.w - 2 * content_pad_px - gutter, cell_px_w), min_grid_cols)),
        .rows = @intCast(@max(@divTrunc(fb.h, cell_px_h), min_grid_rows)),
    };
}

/// The framebuffer size that holds exactly `grid` -- the inverse of
/// `gridForFramebuffer`, so feeding the result back in returns `grid`.
pub fn framebufferForGrid(grid: GridSize, gutter: i32, cell_px_w: i32, cell_px_h: i32) PxSize {
    return .{
        .w = @as(i32, @intCast(grid.cols)) * cell_px_w + 2 * content_pad_px + gutter,
        .h = @as(i32, @intCast(grid.rows)) * cell_px_h,
    };
}

/// What a font-size step does to the window: the grid it now holds and
/// the framebuffer it must grow to, if any. The window is kept as it is
/// and the grid follows the new cell size, except where even
/// `min_grid_*` no longer fits -- then only the short axis grows, just
/// enough to hold the minimum. `grow` is null when the window can stay.
pub const FontStepFit = struct {
    grid: GridSize,
    grow: ?PxSize,
};

pub fn fontStepFit(fb: PxSize, gutter: i32, cell_px_w: i32, cell_px_h: i32) FontStepFit {
    const grid = gridForFramebuffer(fb, gutter, cell_px_w, cell_px_h);
    const need = framebufferForGrid(grid, gutter, cell_px_w, cell_px_h);
    if (need.w <= fb.w and need.h <= fb.h) return .{ .grid = grid, .grow = null };
    return .{ .grid = grid, .grow = .{ .w = @max(fb.w, need.w), .h = @max(fb.h, need.h) } };
}

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

/// Pixels reserved on the window's right edge for the always-on
/// scrollbar's gutter -- `scrollbar_width_px` when the visible context
/// wants the bar (`core.Context.window_scrollbar`), zero when it doesn't,
/// so a pure-TUI context gets those columns to draw in rather than
/// leaving an unpainted strip down the side of its panes.
///
/// **This reflows the grid on a context switch, and that is the cost of
/// the column.** A full-screen client like zoe opts the bar out for its
/// own context, so the session resizes on the way in and back again on
/// the way out -- the shell's root included, which loses and regains a
/// column of scrollback width each time. The arrangement was dropped once
/// before for exactly that reason and is back deliberately: the blank
/// gutter beside a TUI's panes reads as a bug every time you look at it,
/// and the half of the old damage that was actually dangerous -- a
/// foreground child never hearing about the new size -- was a missing
/// `layout` notification on resize, since fixed.
///
/// `syncWindowSize` and `applyFontSize` (px -> cell count, and cell
/// count -> px when a font step has to grow the window) both read this
/// through `WindowSizing.gutterPx`, so the reserved width and the width
/// the window is sized to always agree.
pub fn rightGutterPx(bar_enabled: bool) i32 {
    return if (bar_enabled) scrollbar_width_px else 0;
}

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


// ── Pane geometry ───────────────────────────────────────────────────────
//
// The block above is the *window's* scrollbar, hard against the right
// edge and driven by the root layer's scrollback. Everything below is for
// a layer's own bounds: a pane inside a split tree, drawn where the
// layout put it, with its own scrollbars over its own content grid.

/// A rectangle in window pixels.
pub const RectPx = struct {
    x: f32 = 0,
    y: f32 = 0,
    w: f32 = 0,
    h: f32 = 0,

    pub fn contains(self: RectPx, px: f32, py: f32) bool {
        return px >= self.x and px < self.x + self.w and
            py >= self.y and py < self.y + self.h;
    }
};

/// Thickness of a pane's scrollbar. Thinner than the window's own bar:
/// it sits *inside* the content rather than in a reserved gutter, so it
/// should cost as few columns of text as possible.
pub const pane_scrollbar_px: f32 = 8;

/// A pane scrollbar, ready to draw: the track and the thumb inside it.
pub const PaneScrollbarGeom = struct {
    track: RectPx,
    thumb: RectPx,
};

/// Both of a pane's bars, either of which may be absent (not opted into,
/// or nothing to scroll on that axis).
pub const PaneScrollbars = struct {
    vertical: ?PaneScrollbarGeom = null,
    horizontal: ?PaneScrollbarGeom = null,
};

/// The window-pixel offset a context's contents composite at: its pane's
/// top-left cell, plus the left content margin.
///
/// Everything inside a context is context-relative (see
/// `core.Context.origin_row`), so this is the single place the pane offset
/// enters the renderer. For a session with one pane it is exactly
/// `content_pad_px, 0` -- the values that used to be hard-coded at every
/// composite site.
pub const Origin = struct { x: i32 = content_pad_px, y: i32 = 0 };

pub fn contextOrigin(ctx: *const glyphwire.Context) Origin {
    return .{
        .x = @as(i32, @intCast(ctx.origin_col)) * cell_w + content_pad_px,
        .y = @as(i32, @intCast(ctx.origin_row)) * cell_h,
    };
}

/// The window-pixel rect a layer's *viewport* occupies -- its
/// context-relative position shifted by its context's origin, sized by the
/// viewport rather than the content grid behind it.
pub fn layerRectIn(origin: Origin, pos: glyphwire.PxPos, view_cols: usize, view_rows: usize) RectPx {
    return .{
        .x = @round(pos.x) + @as(f32, @floatFromInt(origin.x)),
        .y = @round(pos.y) + @as(f32, @floatFromInt(origin.y)),
        .w = @floatFromInt(@as(i32, @intCast(view_cols)) * cell_w),
        .h = @floatFromInt(@as(i32, @intCast(view_rows)) * cell_h),
    };
}

/// `layerRectIn` for a context at the window origin -- the single-pane
/// case, and what a caller with no context to hand uses.
pub fn layerRect(pos: glyphwire.PxPos, view_cols: usize, view_rows: usize) RectPx {
    return layerRectIn(.{}, pos, view_cols, view_rows);
}

/// A context-relative cell rectangle (a layer divider band, a pane inside
/// a context) in window pixels.
pub fn cellRectPxIn(origin: Origin, rect: glyphwire.CellRect) RectPx {
    return .{
        .x = @floatFromInt(@as(i32, @intCast(rect.col)) * cell_w + origin.x),
        .y = @floatFromInt(@as(i32, @intCast(rect.row)) * cell_h + origin.y),
        .w = @floatFromInt(@as(i32, @intCast(rect.cols)) * cell_w),
        .h = @floatFromInt(@as(i32, @intCast(rect.rows)) * cell_h),
    };
}

pub fn cellRectPx(rect: glyphwire.CellRect) RectPx {
    return cellRectPxIn(.{}, rect);
}

/// Thumb extent and start along a track of `track_len` pixels: the thumb
/// is the visible fraction of the content, positioned by how far `offset`
/// has travelled toward `max`. Floored at `scrollbar_min_thumb_px` so a
/// very long document still leaves something to grab.
fn thumbSpan(track_len: f32, visible: usize, total: usize, offset: usize, max: usize) struct { start: f32, len: f32 } {
    if (total == 0 or track_len <= 0) return .{ .start = 0, .len = track_len };
    const frac = @as(f32, @floatFromInt(visible)) / @as(f32, @floatFromInt(total));
    var len = track_len * frac;
    len = std.math.clamp(len, @min(scrollbar_min_thumb_px, track_len), track_len);

    const travel = @max(track_len - len, 0);
    const start = if (max > 0)
        travel * (@as(f32, @floatFromInt(offset)) / @as(f32, @floatFromInt(max)))
    else
        0;
    return .{ .start = std.math.clamp(start, 0, travel), .len = len };
}

/// Where a pane's scrollbars sit inside `rect`.
///
/// `state` carries the opt-in flags, the offsets, and the reach on each
/// axis (`max_row`/`max_col`), which already account for a self-scrolling
/// pane's virtual `content_extent`; `view_*` is the viewport in cells.
/// The total content on an axis is `view + max` -- what fits plus what
/// can't be reached at once -- so the thumb is that visible fraction of
/// the track. A bar is omitted when it wasn't opted into, or when the
/// axis has nothing to scroll -- a pane wider than its content shouldn't
/// grow a bar that can't move. When both are shown, each track stops
/// short of the other so they don't overlap in the corner.
pub fn paneScrollbars(
    rect: RectPx,
    state: glyphwire.ScrollbarState,
    view_cols: usize,
    view_rows: usize,
) PaneScrollbars {
    const want_v = state.vertical and state.max_row > 0;
    const want_h = state.horizontal and state.max_col > 0;
    if (!want_v and !want_h) return .{};

    const v_inset: f32 = if (want_h) pane_scrollbar_px else 0;
    const h_inset: f32 = if (want_v) pane_scrollbar_px else 0;

    var out: PaneScrollbars = .{};
    if (want_v) {
        const track: RectPx = .{
            .x = rect.x + rect.w - pane_scrollbar_px,
            .y = rect.y,
            .w = pane_scrollbar_px,
            .h = @max(rect.h - v_inset, 0),
        };
        const span = thumbSpan(track.h, view_rows, view_rows + state.max_row, state.row, state.max_row);
        out.vertical = .{
            .track = track,
            .thumb = .{ .x = track.x, .y = track.y + span.start, .w = track.w, .h = span.len },
        };
    }
    if (want_h) {
        const track: RectPx = .{
            .x = rect.x,
            .y = rect.y + rect.h - pane_scrollbar_px,
            .w = @max(rect.w - h_inset, 0),
            .h = pane_scrollbar_px,
        };
        const span = thumbSpan(track.w, view_cols, view_cols + state.max_col, state.col, state.max_col);
        out.horizontal = .{
            .track = track,
            .thumb = .{ .x = track.x + span.start, .y = track.y, .w = span.len, .h = track.h },
        };
    }
    return out;
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
