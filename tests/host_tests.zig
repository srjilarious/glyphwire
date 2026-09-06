const std = @import("std");
const testz = @import("testz");

// The engine-free pieces of glyphwire-host, reached through the
// `host_support` module (see build.zig) -- no window, no GL. The engine
// backend's own tests live in `host_eng_tests.zig`.
const glyphwire = @import("glyphwire");
const hs = @import("host_support");
const geometry = hs.geometry;
const config = hs.config;
const key_repeat = hs.key_repeat;
const redraw = hs.redraw;

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

// ─── geometry.paneScrollbars ──────────────────────────────────────────

const pane_rect: geometry.RectPx = .{ .x = 100, .y = 50, .w = 300, .h = 200 };

fn barState(vertical: bool, horizontal: bool, row: usize, col: usize, max_row: usize, max_col: usize) glyphwire.ScrollbarState {
    return .{
        .vertical = vertical,
        .horizontal = horizontal,
        .row = row,
        .col = col,
        .max_row = max_row,
        .max_col = max_col,
    };
}

pub fn paneScrollbarsOmittedWhenNotOptedInTest(_: std.Io, _: std.mem.Allocator) !void {
    const bars = geometry.paneScrollbars(pane_rect, barState(false, false, 0, 0, 100, 100), 30, 20, 130, 120);
    try testz.expectTrue(bars.vertical == null);
    try testz.expectTrue(bars.horizontal == null);
}

pub fn paneScrollbarsOmittedWhenNothingToScrollTest(_: std.Io, _: std.mem.Allocator) !void {
    // Opted in, but the viewport covers the content -- a bar that can't
    // move shouldn't be drawn.
    const bars = geometry.paneScrollbars(pane_rect, barState(true, true, 0, 0, 0, 0), 30, 20, 30, 20);
    try testz.expectTrue(bars.vertical == null);
    try testz.expectTrue(bars.horizontal == null);
}

pub fn paneVerticalBarSitsOnTheRightEdgeTest(_: std.Io, _: std.mem.Allocator) !void {
    const bars = geometry.paneScrollbars(pane_rect, barState(true, false, 0, 0, 80, 0), 30, 20, 30, 100);
    const v = bars.vertical.?;
    try testz.expectEqual(v.track.x, 400.0 - geometry.pane_scrollbar_px);
    try testz.expectEqual(v.track.y, 50.0);
    // No horizontal bar to make room for, so the track is the full height.
    try testz.expectEqual(v.track.h, 200.0);
    // Viewport is 20 of 100 rows, so the thumb is a fifth of the track,
    // flush at the top for offset 0.
    try testz.expectEqual(v.thumb.h, 40.0);
    try testz.expectEqual(v.thumb.y, 50.0);
}

pub fn paneVerticalThumbTravelsWithTheOffsetTest(_: std.Io, _: std.mem.Allocator) !void {
    // Fully scrolled: the thumb is flush at the bottom of its travel.
    const bars = geometry.paneScrollbars(pane_rect, barState(true, false, 80, 0, 80, 0), 30, 20, 30, 100);
    const v = bars.vertical.?;
    try testz.expectEqual(v.thumb.y, 50.0 + 200.0 - 40.0);

    // Halfway along.
    const mid = geometry.paneScrollbars(pane_rect, barState(true, false, 40, 0, 80, 0), 30, 20, 30, 100);
    try testz.expectEqual(mid.vertical.?.thumb.y, 50.0 + 80.0);
}

pub fn paneBarsMakeRoomForEachOtherTest(_: std.Io, _: std.mem.Allocator) !void {
    const bars = geometry.paneScrollbars(pane_rect, barState(true, true, 0, 0, 80, 70), 30, 20, 100, 100);
    const v = bars.vertical.?;
    const h = bars.horizontal.?;
    // Each track stops short of the other so they don't overlap in the
    // corner.
    try testz.expectEqual(v.track.h, 200.0 - geometry.pane_scrollbar_px);
    try testz.expectEqual(h.track.w, 300.0 - geometry.pane_scrollbar_px);
    try testz.expectEqual(h.track.y, 50.0 + 200.0 - geometry.pane_scrollbar_px);
}

pub fn paneThumbNeverShrinksBelowTheMinimumTest(_: std.Io, _: std.mem.Allocator) !void {
    // 20 rows visible out of 100_000: the honest fraction would be a
    // fraction of a pixel, so the thumb is floored at something grabbable.
    const bars = geometry.paneScrollbars(pane_rect, barState(true, false, 0, 0, 99_980, 0), 30, 20, 30, 100_000);
    try testz.expectEqual(bars.vertical.?.thumb.h, geometry.scrollbar_min_thumb_px);
}

// ─── geometry.layerRect / cellRectPx ──────────────────────────────────

pub fn layerRectCoversTheViewportNotTheContentTest(_: std.Io, _: std.mem.Allocator) !void {
    geometry.cell_w = 10;
    geometry.cell_h = 20;
    // A pane at (40px, 60px) showing 30x15 cells of a much bigger grid.
    const r = geometry.layerRect(.{ .x = 40, .y = 60 }, 30, 15);
    try testz.expectEqual(r.x, 40.0 + @as(f32, @floatFromInt(geometry.content_pad_px)));
    try testz.expectEqual(r.y, 60.0);
    try testz.expectEqual(r.w, 300.0);
    try testz.expectEqual(r.h, 300.0);
}

pub fn cellRectPxConvertsADividerBandTest(_: std.Io, _: std.mem.Allocator) !void {
    geometry.cell_w = 10;
    geometry.cell_h = 20;
    const r = geometry.cellRectPx(.{ .row = 2, .col = 20, .cols = 1, .rows = 38 });
    try testz.expectEqual(r.x, 200.0 + @as(f32, @floatFromInt(geometry.content_pad_px)));
    try testz.expectEqual(r.y, 40.0);
    try testz.expectEqual(r.w, 10.0);
    try testz.expectEqual(r.h, 760.0);
}

// ─── redraw.contextSig ───────────────────────────────────────────────
//
// The `Context`-derived half of the host's "only draw when something
// changed" check (see `host/redraw.zig`). A `std.meta.eql` compare of the
// returned value is what `App.needsRedraw` gates the frame on.

pub fn contextSigStableWhenNothingChangesTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var ctx = try glyphwire.Context.init(alloc, 40, 20, 8);
    defer ctx.deinit();
    try ctx.root.writeText("hello", glyphwire.default_style.fg, glyphwire.default_style.bg);

    const a = redraw.contextSig(&ctx);
    const b = redraw.contextSig(&ctx);
    try testz.expectTrue(std.meta.eql(a, b));
}

pub fn contextSigMovesOnCellWriteTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var ctx = try glyphwire.Context.init(alloc, 40, 20, 8);
    defer ctx.deinit();

    const before = redraw.contextSig(&ctx);
    try ctx.root.writeText("x", glyphwire.default_style.fg, glyphwire.default_style.bg);
    const after = redraw.contextSig(&ctx);
    try testz.expectFalse(std.meta.eql(before, after));
}

pub fn contextSigMovesOnScrollViewTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var ctx = try glyphwire.Context.init(alloc, 4, 2, 8);
    defer ctx.deinit();
    // 3 content rows over a 2-row viewport => one row of scrollback.
    try ctx.root.writeText("aaaabbbbcccc", glyphwire.default_style.fg, glyphwire.default_style.bg);

    const at_tail = redraw.contextSig(&ctx);
    _ = ctx.root.scrollView(null, 1);
    const scrolled = redraw.contextSig(&ctx);
    try testz.expectFalse(std.meta.eql(at_tail, scrolled));
}

pub fn contextSigMovesWhenALayerIsCreatedTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var ctx = try glyphwire.Context.init(alloc, 40, 20, 0);
    defer ctx.deinit();

    const before = redraw.contextSig(&ctx);
    _ = try ctx.createLayer(10, 5, 0);
    const after = redraw.contextSig(&ctx);
    try testz.expectFalse(std.meta.eql(before, after));
}

pub fn contextSigMovesOnRaiseLayerWithNoContentChangeTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var ctx = try glyphwire.Context.init(alloc, 40, 20, 0);
    defer ctx.deinit();
    const a = try ctx.createLayer(10, 5, 0);
    _ = try ctx.createLayer(10, 5, 0);

    // Reordering the compositing stack deliberately doesn't bump any
    // layer's render_gen (the host reads layer_order live), so the topo
    // hash is the only thing that can catch it.
    const before = redraw.contextSig(&ctx);
    try ctx.raiseLayer(a, null);
    const after = redraw.contextSig(&ctx);
    try testz.expectFalse(std.meta.eql(before, after));
}

pub fn contextSigMovesOnVisibilityToggleTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var ctx = try glyphwire.Context.init(alloc, 40, 20, 0);
    defer ctx.deinit();
    const tree = try ctx.createLayer(10, 5, 0);

    const shown = redraw.contextSig(&ctx);
    try ctx.setLayerProperty(tree, .{ .visibility = false });
    const hidden = redraw.contextSig(&ctx);
    try testz.expectFalse(std.meta.eql(shown, hidden));
}

pub fn contextSigMovesWhenAFullScreenProgramTakesTheScreenTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var ctx = try glyphwire.Context.init(alloc, 20, 10, 0);
    defer ctx.deinit();

    const before = redraw.contextSig(&ctx);
    // `CSI ? 1049 h` -- enter the alt screen. `rootScreenOwned` flips,
    // which the signature carries in root_view's top bit.
    try ctx.root.writeText("\x1b[?1049h", glyphwire.default_style.fg, glyphwire.default_style.bg);
    const owned = redraw.contextSig(&ctx);
    try testz.expectFalse(std.meta.eql(before, owned));
}
