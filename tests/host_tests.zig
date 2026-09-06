const std = @import("std");
const testz = @import("testz");

// The engine-free pieces of glyphwire-host, reached through the
// `host_support` module (see build.zig) -- no window, no GL. The engine
// backend's own tests live in `host_eng_tests.zig`.
const hs = @import("host_support");
const geometry = hs.geometry;
const config = hs.config;
const key_repeat = hs.key_repeat;

// ─── geometry.scrollbarGeom ───────────────────────────────────────────

pub fn scrollbarGeomNoHistoryFillsTrackTest(_: std.Io, _: std.mem.Allocator) !void {
    // No scrollback: the thumb is the whole track, flush at the top, and
    // the bar sits `scrollbar_width_px` in from the right edge.
    const g = geometry.scrollbarGeom(800, 400, 0, 100, 0);
    try testz.expectEqual(g.left, 788.0);
    try testz.expectEqual(g.track_h, 400.0);
    try testz.expectEqual(g.thumb_h, 400.0);
    try testz.expectEqual(g.thumb_top, 0.0);
}

pub fn scrollbarGeomLiveTailThumbFlushBottomTest(_: std.Io, _: std.mem.Allocator) !void {
    // 300 rows of history, 100 visible, viewing the live tail: the thumb
    // is 1/4 of the track and pinned to the bottom.
    const g = geometry.scrollbarGeom(800, 400, 300, 100, 0);
    try testz.expectEqual(g.thumb_h, 100.0);
    try testz.expectEqual(g.thumb_top, 300.0); // track_h - thumb_h
}

pub fn scrollbarGeomOldestRowThumbFlushTopTest(_: std.Io, _: std.mem.Allocator) !void {
    // Same buffer, scrolled all the way back: thumb flush to the top.
    const g = geometry.scrollbarGeom(800, 400, 300, 100, 300);
    try testz.expectEqual(g.thumb_h, 100.0);
    try testz.expectEqual(g.thumb_top, 0.0);
}

pub fn scrollbarGeomDeepHistoryClampsThumbToMinTest(_: std.Io, _: std.mem.Allocator) !void {
    // A very deep scrollback would give a sub-pixel thumb; it's clamped
    // up to `scrollbar_min_thumb_px` and its top is clamped into the
    // track.
    const g = geometry.scrollbarGeom(800, 400, 10_000, 100, 0);
    try testz.expectEqual(g.thumb_h, 24.0);
    try testz.expectEqual(g.thumb_top, 376.0); // track_h - thumb_h
}

// ─── geometry.cellFromPixel ──────────────────────────────────────────

/// `cellFromPixel` reads the module-level cell/grid globals; set a known
/// layout before each case (no other test in the suite touches these).
fn setGrid(cell_w: i32, cell_h: i32, cols: usize, rows: usize) void {
    geometry.cell_w = cell_w;
    geometry.cell_h = cell_h;
    geometry.grid_cols = cols;
    geometry.grid_rows = rows;
}

pub fn cellFromPixelSubtractsContentPadTest(_: std.Io, _: std.mem.Allocator) !void {
    setGrid(10, 20, 100, 50);
    // x == content_pad_px lands on column 0, not -1.
    const c = geometry.cellFromPixel(2, 0);
    try testz.expectEqual(c.col, 0);
    try testz.expectEqual(c.row, 0);
}

pub fn cellFromPixelMapsInteriorPixelTest(_: std.Io, _: std.mem.Allocator) !void {
    setGrid(10, 20, 100, 50);
    const c = geometry.cellFromPixel(23, 45);
    try testz.expectEqual(c.col, 2); // (23 - 2) / 10 = 2.1
    try testz.expectEqual(c.row, 2); // 45 / 20 = 2.25
}

pub fn cellFromPixelClampsBelowZeroTest(_: std.Io, _: std.mem.Allocator) !void {
    setGrid(10, 20, 100, 50);
    const c = geometry.cellFromPixel(0, 0); // (0 - 2) / 10 is negative
    try testz.expectEqual(c.col, 0);
    try testz.expectEqual(c.row, 0);
}

pub fn cellFromPixelClampsToGridBoundsTest(_: std.Io, _: std.mem.Allocator) !void {
    setGrid(10, 20, 100, 50);
    const c = geometry.cellFromPixel(100_000, 100_000);
    try testz.expectEqual(c.col, 99); // grid_cols - 1
    try testz.expectEqual(c.row, 49); // grid_rows - 1
}

// ─── config.clamp* ───────────────────────────────────────────────────

pub fn clampFontSizeBoundsTest(_: std.Io, _: std.mem.Allocator) !void {
    try testz.expectEqual(config.clampFontSize(4), config.min_font_size);
    try testz.expectEqual(config.clampFontSize(1000), config.max_font_size);
    try testz.expectEqual(config.clampFontSize(20), 20.0);
}

pub fn clampBlinkMsBoundsTest(_: std.Io, _: std.mem.Allocator) !void {
    try testz.expectEqual(config.clampBlinkMs(50), config.cursor_blink_ms_min);
    try testz.expectEqual(config.clampBlinkMs(9000), config.cursor_blink_ms_max);
    try testz.expectEqual(config.clampBlinkMs(530), 530.0);
}

pub fn clampGridColsRowsFloorTest(_: std.Io, _: std.mem.Allocator) !void {
    try testz.expectEqual(config.clampGridCols(2), @as(usize, geometry.min_grid_cols));
    try testz.expectEqual(config.clampGridCols(200), @as(usize, 200));
    try testz.expectEqual(config.clampGridRows(1), @as(usize, geometry.min_grid_rows));
    try testz.expectEqual(config.clampGridRows(50), @as(usize, 50));
}

pub fn clampScrollbackCeilingTest(_: std.Io, _: std.mem.Allocator) !void {
    try testz.expectEqual(config.clampScrollback(9_999_999), @as(usize, config.scrollback_rows_max));
    try testz.expectEqual(config.clampScrollback(1000), @as(usize, 1000));
}

pub fn cursorShapeFromStrTest(_: std.Io, _: std.mem.Allocator) !void {
    try testz.expectEqual(config.cursorShapeFromStr("block").?, .block);
    try testz.expectEqual(config.cursorShapeFromStr("underline").?, .underline);
    try testz.expectTrue(config.cursorShapeFromStr("diamond") == null);
}

// ─── key_repeat.KeyRepeatState ───────────────────────────────────────

pub fn keyRepeatStartsAtDelayTest(_: std.Io, _: std.mem.Allocator) !void {
    const st: key_repeat.KeyRepeatState = .{};
    try testz.expectEqual(st.held_ms, 0.0);
    try testz.expectEqual(st.next_repeat_ms, key_repeat.key_repeat_delay_ms);
}

pub fn keyRepeatFiresAfterDelayThenAtIntervalTest(_: std.Io, _: std.mem.Allocator) !void {
    var st: key_repeat.KeyRepeatState = .{};
    // Held less than the initial delay: no repeat yet.
    try testz.expectFalse(st.tick(key_repeat.key_repeat_delay_ms - 1));
    // Crossing the delay threshold: one repeat.
    try testz.expectTrue(st.tick(1));
    // Next threshold is one interval further out.
    try testz.expectFalse(st.tick(key_repeat.key_repeat_interval_ms - 1));
    try testz.expectTrue(st.tick(1));
}

pub fn keyRepeatResetReturnsToDelayTest(_: std.Io, _: std.mem.Allocator) !void {
    var st: key_repeat.KeyRepeatState = .{};
    _ = st.tick(key_repeat.key_repeat_delay_ms + 100);
    st.reset();
    try testz.expectEqual(st.held_ms, 0.0);
    try testz.expectEqual(st.next_repeat_ms, key_repeat.key_repeat_delay_ms);
    try testz.expectFalse(st.tick(key_repeat.key_repeat_delay_ms - 1));
}
