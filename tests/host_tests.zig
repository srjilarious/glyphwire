// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: GPL-3.0-or-later

const std = @import("std");
const testz = @import("testz");

// The engine-free pieces of glyphwire-host, reached through the
// `host_support` module (see build.zig) -- no window, no GL. The engine
// backend's own tests live in `host_eng_tests.zig`.
const glyphwire = @import("glyphwire");
const hs = @import("host_support");
const geometry = hs.geometry;
const config = hs.config;
const system_font = hs.system_font;
const key_repeat = hs.key_repeat;
const redraw = hs.redraw;
const modal_list = hs.modal_list;

// ─── modal_list ───────────────────────────────────────────────────────

pub fn modalListLayoutCentresAndFramesTheListTest(_: std.Io, _: std.mem.Allocator) !void {
    const rows = [_]modal_list.Row{ .{ .text = "shell", .tag = "  (current)" }, .{ .text = "zoe main.zig" } };
    const view: modal_list.View = .{ .pane = 0, .title = "Switch to", .foot = "Enter switch  Esc close", .rows = &rows, .selected = 1 };
    const lay = modal_list.layout(.{ .row = 0, .col = 0, .rows = 30, .cols = 80 }, view).?;
    // Title, both rows, footer; the frame one cell out all round.
    try testz.expectEqual(lay.content.rows, 4);
    try testz.expectEqual(lay.visible, 2);
    try testz.expectEqual(lay.first, 0);
    try testz.expectEqual(lay.frame.rows, lay.content.rows + 2);
    try testz.expectEqual(lay.frame.cols, lay.content.cols + 2);
    try testz.expectEqual(lay.content.row, lay.frame.row + 1);
    // Wide enough for the longest line (the footer) plus a margin.
    try testz.expectEqual(lay.content.cols, "Enter switch  Esc close".len + 2);
    // Centred across.
    try testz.expectEqual(lay.frame.col, (80 - lay.frame.cols) / 2);
}

pub fn modalListLayoutScrollsToTheSelectionTest(_: std.Io, _: std.mem.Allocator) !void {
    var rows: [20]modal_list.Row = undefined;
    for (&rows) |*r| r.* = .{ .text = "theme" };
    const view: modal_list.View = .{ .pane = 0, .title = "Theme", .foot = "", .rows = &rows, .selected = 15 };
    // A 10-row pane fits 6 entries.
    const lay = modal_list.layout(.{ .row = 5, .col = 40, .rows = 10, .cols = 40 }, view).?;
    try testz.expectEqual(lay.visible, 6);
    try testz.expectEqual(lay.first, 10);
    // Inside the pane.
    try testz.expectTrue(lay.frame.row >= 5 and lay.frame.row + lay.frame.rows <= 15);
    try testz.expectTrue(lay.frame.col >= 40 and lay.frame.col + lay.frame.cols <= 80);
    // Too small for a frame at all.
    try testz.expectTrue(modal_list.layout(.{ .rows = 4, .cols = 40 }, view) == null);
}

pub fn modalListWrapMoveWrapsBothWaysTest(_: std.Io, _: std.mem.Allocator) !void {
    try testz.expectEqual(modal_list.wrapMove(0, 5, -1), 4);
    try testz.expectEqual(modal_list.wrapMove(4, 5, 1), 0);
    try testz.expectEqual(modal_list.wrapMove(2, 5, 1), 3);
    try testz.expectEqual(modal_list.wrapMove(0, 0, 1), 0);
}

pub fn themeNamesPutsConfigThemesFirstOnceTest(_: std.Io, alloc: std.mem.Allocator) !void {
    const customs = [_]glyphwire.theme.Custom{
        .{ .name = "mine", .base = "nord" },
        // Shadows the built-in: listed once, here.
        .{ .name = "dracula", .base = "dracula" },
        // Defined twice: once.
        .{ .name = "mine", .base = "monokai" },
        // A base that never reaches a built-in can't be picked.
        .{ .name = "broken", .base = "nowhere" },
    };
    const names = try modal_list.themeNames(alloc, &customs);
    defer alloc.free(names);
    try testz.expectEqualStr(names[0], "mine");
    try testz.expectEqualStr(names[1], "dracula");
    try testz.expectEqual(names.len, 2 + glyphwire.theme.builtins.len - 1);
    for (names, 0..) |n, i| {
        try testz.expectFalse(std.mem.eql(u8, n, "broken"));
        for (names[i + 1 ..]) |other| try testz.expectFalse(std.mem.eql(u8, n, other));
    }
}

// ─── geometry.resizeEdge* ─────────────────────────────────────────────

pub fn resizeEdgeBandSitsOnTheLayersTopTest(_: std.Io, _: std.mem.Allocator) !void {
    const rect: geometry.RectPx = .{ .x = 0, .y = 200, .w = 640, .h = 160 };
    const band = geometry.resizeEdgeBand(rect);
    // Over the layer's own first row, full width, a few pixels thick.
    try testz.expectEqual(band.y, 200.0);
    try testz.expectEqual(band.w, 640.0);
    try testz.expectEqual(band.h, geometry.resize_edge_px);
    // The grab target reaches past it both ways.
    const grab = geometry.resizeEdgeHit(rect);
    try testz.expectTrue(grab.contains(10, 200 - geometry.resize_edge_slop_px));
    try testz.expectTrue(grab.contains(10, 200 + geometry.resize_edge_px + geometry.resize_edge_slop_px - 1));
    try testz.expectFalse(grab.contains(10, 200 - geometry.resize_edge_slop_px - 1));
    try testz.expectFalse(grab.contains(10, 220));
}

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

pub fn paneScrollbarFromARingSitsAtTheTailTest(_: std.Io, _: std.mem.Allocator) !void {
    // What `Layer.scrollbarState` now reports for a terminal-style layer
    // (a `gmux` pane, `gw-shell --embed`'s panel): its scrollback, in a
    // viewport offset's sense. 30 rows of history under a 10-row pane,
    // viewing the live tail -- so the thumb is a quarter of the track and
    // pinned to the bottom, exactly as the window's own bar shows the
    // root layer's ring.
    const rect: geometry.RectPx = .{ .x = 0, .y = 0, .w = 200, .h = 400 };
    const live = geometry.paneScrollbars(rect, .{
        .vertical = true,
        .horizontal = false,
        .row = 30,
        .col = 0,
        .max_row = 30,
        .max_col = 0,
    }, 20, 10);
    const v = live.vertical.?;
    try testz.expectEqual(v.thumb.h, 100.0);
    try testz.expectEqual(v.thumb.y, 300.0);

    // Scrolled all the way back: flush to the top.
    const back = geometry.paneScrollbars(rect, .{
        .vertical = true,
        .horizontal = false,
        .row = 0,
        .col = 0,
        .max_row = 30,
        .max_col = 0,
    }, 20, 10);
    try testz.expectEqual(back.vertical.?.thumb.y, 0.0);

    // An empty ring draws no bar at all, the same as a pane with no
    // viewport slack.
    const empty = geometry.paneScrollbars(rect, .{
        .vertical = true,
        .horizontal = false,
        .row = 0,
        .col = 0,
        .max_row = 0,
        .max_col = 0,
    }, 20, 10);
    try testz.expectTrue(empty.vertical == null);
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

pub fn parseChordReadsModifiersAndKeyInAnyCaseTest(_: std.Io, _: std.mem.Allocator) !void {
    const sf12 = config.parseChord("super+f12").?;
    try testz.expectEqual(sf12.key, .F12);
    try testz.expectTrue(sf12.super);
    try testz.expectFalse(sf12.ctrl or sf12.alt or sf12.shift);
    try testz.expectTrue(std.meta.eql(sf12, config.context_switcher_default));

    const cat = config.parseChord("Ctrl + Alt + Tab").?;
    try testz.expectEqual(cat.key, .tab);
    try testz.expectTrue(cat.ctrl and cat.alt);
    try testz.expectFalse(cat.super);

    try testz.expectTrue(config.parseChord("win+grave_accent").?.super);
    try testz.expectTrue(config.parseChord("f12").?.matches(false, false, false, false));
}

pub fn parseChordRejectsMalformedChordsTest(_: std.Io, _: std.mem.Allocator) !void {
    try testz.expectTrue(config.parseChord("") == null);
    try testz.expectTrue(config.parseChord("super+") == null);
    try testz.expectTrue(config.parseChord("super") == null); // no key
    try testz.expectTrue(config.parseChord("a+b") == null); // two keys
    try testz.expectTrue(config.parseChord("hyper+f12") == null);
    try testz.expectTrue(config.parseChord("super+unknown") == null);
}

pub fn cursorShapeFromStrTest(_: std.Io, _: std.mem.Allocator) !void {
    try testz.expectEqual(config.cursorShapeFromStr("block").?, .block);
    try testz.expectEqual(config.cursorShapeFromStr("underline").?, .underline);
    try testz.expectTrue(config.cursorShapeFromStr("diamond") == null);
}

pub fn bundledFontRelPathAcceptsLegacyAssetsPrefixForAnySlotTest(_: std.Io, _: std.mem.Allocator) !void {
    try testz.expectEqualStr(config.bundledFontRelPath("NotoSansCJK-Regular.ttc", config.font_path_default).?, "NotoSansCJK-Regular.ttc");
    try testz.expectEqualStr(config.bundledFontRelPath("assets/NotoSansCJK-Regular.ttc", config.font_fallback_default).?, "NotoSansCJK-Regular.ttc");
    try testz.expectTrue(config.bundledFontRelPath("Noto Sans Mono", config.font_fallback_default) == null);
}

// ─── system_font (fc-match parsing / match judging) ──────────────────

pub fn fcMatchOutputParsesFourFieldsTest(_: std.Io, _: std.mem.Allocator) !void {
    const raw = system_font.parseFcMatchOutput(
        "/usr/share/fonts/TTF/DejaVuSansMono.ttf|DejaVu Sans Mono|DejaVu Sans Mono Book|0\n",
    ).?;
    try testz.expectEqualStr(raw.file, "/usr/share/fonts/TTF/DejaVuSansMono.ttf");
    try testz.expectEqualStr(raw.family, "DejaVu Sans Mono");
    try testz.expectEqualStr(raw.fullname, "DejaVu Sans Mono Book");
    try testz.expectEqual(raw.index, @as(i32, 0));
}

pub fn fcMatchOutputReadsCollectionIndexTest(_: std.Io, _: std.mem.Allocator) !void {
    const raw = system_font.parseFcMatchOutput("/f/NotoSansCJK-Regular.ttc|Noto Sans Mono CJK JP|Noto Sans Mono CJK JP Regular|2").?;
    try testz.expectEqual(raw.index, @as(i32, 2));
}

pub fn fcMatchOutputRejectsShortLineTest(_: std.Io, _: std.mem.Allocator) !void {
    // An old fontconfig that doesn't understand `%{fullname}` leaves the
    // token literal, so the `|` count is wrong -- treat as unparseable.
    try testz.expectTrue(system_font.parseFcMatchOutput("only|three|fields\n") == null);
    try testz.expectTrue(system_font.parseFcMatchOutput("") == null);
    try testz.expectTrue(system_font.parseFcMatchOutput("|empty|file|0") == null);
}

pub fn genericAliasRecognizedTest(_: std.Io, _: std.mem.Allocator) !void {
    try testz.expectTrue(system_font.isGenericAlias("monospace"));
    try testz.expectTrue(system_font.isGenericAlias("Monospace"));
    try testz.expectTrue(system_font.isGenericAlias("sans-serif"));
    try testz.expectFalse(system_font.isGenericAlias("DejaVu Sans Mono"));
}

pub fn nameSatisfiesRequestMatchesFamilyTest(_: std.Io, _: std.mem.Allocator) !void {
    // Exact family.
    try testz.expectTrue(system_font.nameSatisfiesRequest("DejaVu Sans Mono", "DejaVu Sans Mono", "DejaVu Sans Mono Book"));
    // Space/hyphen-insensitive, case-insensitive.
    try testz.expectTrue(system_font.nameSatisfiesRequest("jetbrainsmono", "JetBrains Mono", "JetBrains Mono Regular"));
    try testz.expectTrue(system_font.nameSatisfiesRequest("JetBrains Mono", "JetBrainsMono", "JetBrainsMono-Regular"));
    // Match via the full name when the family alone doesn't carry it.
    try testz.expectTrue(system_font.nameSatisfiesRequest("Fira Code Retina", "Fira Code", "Fira Code Retina"));
    // A generic alias is always satisfied.
    try testz.expectTrue(system_font.nameSatisfiesRequest("monospace", "Noto Sans Mono", "Noto Sans Mono Regular"));
}

pub fn nameSatisfiesRequestRejectsFallbackTest(_: std.Io, _: std.mem.Allocator) !void {
    // fontconfig fell back to its default (Noto Sans) for a font that
    // isn't installed -- the request name is nowhere in the result.
    try testz.expectFalse(system_font.nameSatisfiesRequest("Comic Sans MS", "Noto Sans", "Noto Sans Regular"));
    try testz.expectFalse(system_font.nameSatisfiesRequest("NoSuchFontXYZ", "DejaVu Sans", "DejaVu Sans Book"));
}

// ─── geometry.resizeSettleStep ──────────────────────────────────────

pub fn resizeSettleDebouncesADragTest(_: std.Io, _: std.mem.Allocator) !void {
    const committed: geometry.GridSize = .{ .cols = 100, .rows = 40 };
    const a: geometry.GridSize = .{ .cols = 110, .rows = 40 };
    const b: geometry.GridSize = .{ .cols = 120, .rows = 40 };

    // First measurement of a new size with nothing pending: start timing.
    try testz.expectEqual(geometry.resizeSettleStep(committed, a, null, 0), .restart);
    // Same size, still inside the settle window: keep waiting.
    try testz.expectEqual(geometry.resizeSettleStep(committed, a, a, 50), .wait);
    // The drag moved on to a different size: restart the timer.
    try testz.expectEqual(geometry.resizeSettleStep(committed, b, a, 90), .restart);
    // b held past the settle window: commit it.
    try testz.expectEqual(geometry.resizeSettleStep(committed, b, b, 130), .commit);
    // Snapped back to the committed size mid-drag: drop the pending.
    try testz.expectEqual(geometry.resizeSettleStep(committed, committed, b, 200), .settled);
}

// ─── geometry.gridForFramebuffer / fontStepFit ───────────────────────

fn expectGrid(got: geometry.GridSize, cols: usize, rows: usize) !void {
    try testz.expectEqual(got.cols, cols);
    try testz.expectEqual(got.rows, rows);
}

pub fn gridForFramebufferRoundTripsTest(_: std.Io, _: std.mem.Allocator) !void {
    const gutter = geometry.scrollbar_width_px;
    const grid: geometry.GridSize = .{ .cols = 80, .rows = 24 };
    const fb = geometry.framebufferForGrid(grid, gutter, 10, 20);
    try testz.expectEqual(fb.w, 800 + 2 * geometry.content_pad_px + gutter);
    try testz.expectEqual(fb.h, 480);
    try expectGrid(geometry.gridForFramebuffer(fb, gutter, 10, 20), 80, 24);
    // A leftover part-cell is floored away, not rounded up.
    try expectGrid(geometry.gridForFramebuffer(.{ .w = fb.w + 9, .h = fb.h + 19 }, gutter, 10, 20), 80, 24);
}

pub fn fontStepFitKeepsTheWindowAndReflowsTheGridTest(_: std.Io, _: std.mem.Allocator) !void {
    const gutter = geometry.scrollbar_width_px;
    const fb = geometry.framebufferForGrid(.{ .cols = 80, .rows = 24 }, gutter, 10, 20);

    // Doubling the cell halves the grid; the window stays put.
    const bigger = geometry.fontStepFit(fb, gutter, 20, 40);
    try expectGrid(bigger.grid, 40, 12);
    try testz.expectTrue(bigger.grow == null);

    // Halving it doubles the grid.
    const smaller = geometry.fontStepFit(fb, gutter, 5, 10);
    try expectGrid(smaller.grid, 160, 48);
    try testz.expectTrue(smaller.grow == null);
}

pub fn fontStepFitGrowsOnlyForTheMinimumGridTest(_: std.Io, _: std.mem.Allocator) !void {
    const gutter = geometry.scrollbar_width_px;
    // Wide enough for plenty of columns, but only 2 rows at 40px.
    const fb: geometry.PxSize = .{ .w = 2000, .h = 80 };
    const fit = geometry.fontStepFit(fb, gutter, 20, 40);
    try testz.expectEqual(fit.grid.rows, geometry.min_grid_rows);
    const grow = fit.grow orelse return error.TestExpectedGrow;
    // Only the short axis grows, and just enough for the minimum.
    try testz.expectEqual(grow.w, fb.w);
    try testz.expectEqual(grow.h, @as(i32, geometry.min_grid_rows) * 40);
}

// ─── key_repeat: which keys repeat, and at what timing ───────────────

pub fn keyRepeatNamedKeysRepeatUnmodifiedTest(_: std.Io, _: std.mem.Allocator) !void {
    // Nothing types these, so a held one has to repeat on the key stream
    // -- page_up/page_down included, which is what zoe needs.
    try testz.expectTrue(key_repeat.repeatsKey(.page_up, false, false));
    try testz.expectTrue(key_repeat.repeatsKey(.page_down, false, false));
    try testz.expectTrue(key_repeat.repeatsKey(.up, false, false));
    try testz.expectTrue(key_repeat.repeatsKey(.backspace, false, false));
    try testz.expectTrue(key_repeat.repeatsKey(.home, false, false));
    try testz.expectTrue(key_repeat.repeatsKey(.F5, false, false));
}

pub fn keyRepeatTextKeysRepeatOnlyAsChordTest(_: std.Io, _: std.mem.Allocator) !void {
    // A bare held `u` types through the `text` stream; Ctrl+U is a chord
    // no text event fires for, so that one repeats here.
    try testz.expectFalse(key_repeat.repeatsKey(.u, false, false));
    try testz.expectTrue(key_repeat.repeatsKey(.u, true, false));
    try testz.expectTrue(key_repeat.repeatsKey(.u, false, true));
    try testz.expectFalse(key_repeat.repeatsKey(.space, false, false));
    try testz.expectFalse(key_repeat.repeatsKey(.five, false, false));
}

pub fn keyRepeatModifiersAndLocksNeverRepeatTest(_: std.Io, _: std.mem.Allocator) !void {
    try testz.expectFalse(key_repeat.repeatsKey(.left_control, true, false));
    try testz.expectFalse(key_repeat.repeatsKey(.right_alt, false, true));
    try testz.expectFalse(key_repeat.repeatsKey(.caps_lock, true, true));
    try testz.expectFalse(key_repeat.repeatsKey(.unknown, true, true));
}

pub fn keyRepeatResolveUsesDefaultWithoutOverrideTest(_: std.Io, _: std.mem.Allocator) !void {
    const default: key_repeat.Timing = .{ .delay_ms = 400, .interval_ms = 30 };
    const r = key_repeat.resolve(default, null);
    try testz.expectEqual(r.delay_ms, 400.0);
    try testz.expectEqual(r.interval_ms, 30.0);
    try testz.expectTrue(r.enabled);
}

pub fn keyRepeatResolvePrefersOverrideTest(_: std.Io, _: std.mem.Allocator) !void {
    // zoe's ask: no initial hold at all, so the first repeat lands one
    // interval after the press.
    const r = key_repeat.resolve(.{}, .{ .delay_ms = 30, .interval_ms = 30 });
    try testz.expectEqual(r.delay_ms, 30.0);
    try testz.expectEqual(r.interval_ms, 30.0);
}

pub fn keyRepeatResolveClampsOverrideTest(_: std.Io, _: std.mem.Allocator) !void {
    // A client can't hand the engine a cadence outside the host's range.
    const r = key_repeat.resolve(.{}, .{ .delay_ms = -100, .interval_ms = 0 });
    try testz.expectEqual(r.delay_ms, key_repeat.delay_ms_min);
    try testz.expectEqual(r.interval_ms, key_repeat.interval_ms_min);

    const hi = key_repeat.resolve(.{}, .{ .delay_ms = 99_000, .interval_ms = 99_000 });
    try testz.expectEqual(hi.delay_ms, key_repeat.delay_ms_max);
    try testz.expectEqual(hi.interval_ms, key_repeat.interval_ms_max);
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
    const bars = geometry.paneScrollbars(pane_rect, barState(false, false, 0, 0, 100, 100), 30, 20);
    try testz.expectTrue(bars.vertical == null);
    try testz.expectTrue(bars.horizontal == null);
}

pub fn paneScrollbarsOmittedWhenNothingToScrollTest(_: std.Io, _: std.mem.Allocator) !void {
    // Opted in, but the viewport covers the content -- a bar that can't
    // move shouldn't be drawn.
    const bars = geometry.paneScrollbars(pane_rect, barState(true, true, 0, 0, 0, 0), 30, 20);
    try testz.expectTrue(bars.vertical == null);
    try testz.expectTrue(bars.horizontal == null);
}

pub fn paneVerticalBarSitsOnTheRightEdgeTest(_: std.Io, _: std.mem.Allocator) !void {
    const bars = geometry.paneScrollbars(pane_rect, barState(true, false, 0, 0, 80, 0), 30, 20);
    const v = bars.vertical.?;
    try testz.expectEqual(v.track.x, 400.0 - geometry.pane_scrollbar_px);
    try testz.expectEqual(v.track.y, 50.0);
    // No horizontal bar to make room for, so the track is the full height.
    try testz.expectEqual(v.track.h, 200.0);
    // Total content is view + reach = 20 + 80 = 100 rows, so the thumb is
    // a fifth of the track, flush at the top for offset 0.
    try testz.expectEqual(v.thumb.h, 40.0);
    try testz.expectEqual(v.thumb.y, 50.0);
}

pub fn paneVerticalThumbTravelsWithTheOffsetTest(_: std.Io, _: std.mem.Allocator) !void {
    // Fully scrolled: the thumb is flush at the bottom of its travel.
    const bars = geometry.paneScrollbars(pane_rect, barState(true, false, 80, 0, 80, 0), 30, 20);
    const v = bars.vertical.?;
    try testz.expectEqual(v.thumb.y, 50.0 + 200.0 - 40.0);

    // Halfway along.
    const mid = geometry.paneScrollbars(pane_rect, barState(true, false, 40, 0, 80, 0), 30, 20);
    try testz.expectEqual(mid.vertical.?.thumb.y, 50.0 + 80.0);
}

pub fn paneBarsMakeRoomForEachOtherTest(_: std.Io, _: std.mem.Allocator) !void {
    const bars = geometry.paneScrollbars(pane_rect, barState(true, true, 0, 0, 80, 70), 30, 20);
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
    const bars = geometry.paneScrollbars(pane_rect, barState(true, false, 0, 0, 99_980, 0), 30, 20);
    try testz.expectEqual(bars.vertical.?.thumb.h, geometry.scrollbar_min_thumb_px);
}

pub fn paneThumbFractionFollowsTheVirtualExtentTest(_: std.Io, _: std.mem.Allocator) !void {
    // A self-scrolling pane (zoe's buffer): the real cell grid is exactly
    // the viewport, so the only thing that says "there is more content"
    // is `state.max_row`, derived from the layer's `content_extent`.
    // Viewport 20, reach 60 -> total 80 -> the thumb is a quarter of the
    // 200px track, not the whole track (the pre-fix bug, where the
    // geometry took the viewport-sized real grid as the content and drew
    // a full-height thumb).
    const bars = geometry.paneScrollbars(pane_rect, barState(true, false, 0, 0, 60, 0), 30, 20);
    const v = bars.vertical.?;
    try testz.expectEqual(v.thumb.h, 50.0);
    try testz.expectTrue(v.thumb.h < v.track.h);
}

pub fn rightGutterFollowsTheVisibleContextsBarTest(_: std.Io, _: std.mem.Allocator) !void {
    // A context that opts the window scrollbar out reclaims its columns
    // rather than leaving an unpainted strip beside its panes, so the
    // gutter follows `Context.window_scrollbar`. The cost is a grid
    // reflow when such a context comes and goes -- see
    // `geometry.rightGutterPx`. Both sides of the px<->cell math
    // (`syncWindowSize`, `applyFontSize`) read this one value, so
    // the reserved width and the width the window is sized to agree.
    try testz.expectEqual(geometry.rightGutterPx(true), geometry.scrollbar_width_px);
    try testz.expectEqual(geometry.rightGutterPx(false), 0);
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

// ─── config.effectiveCursorShape ──────────────────────────────────────

/// With the window focused, a client's `set_caret_shape` wins over
/// `host.conf.lua` and no request leaves the configured shape alone.
pub fn cursorShapeFollowsTheClientWhileFocusedTest(_: std.Io, _: std.mem.Allocator) !void {
    try testz.expectEqual(config.effectiveCursorShape(.line, null, true), .line);
    try testz.expectEqual(config.effectiveCursorShape(.underline, null, true), .underline);
    try testz.expectEqual(config.effectiveCursorShape(.line, .block, true), .block);
    try testz.expectEqual(config.effectiveCursorShape(.block, .line, true), .line);
}

/// A window without the keyboard draws a hollow box, whatever anyone
/// asked for -- including a client that explicitly asked for a block.
pub fn cursorShapeIsAHollowBoxWhileUnfocusedTest(_: std.Io, _: std.mem.Allocator) !void {
    try testz.expectEqual(config.effectiveCursorShape(.line, null, false), .box);
    try testz.expectEqual(config.effectiveCursorShape(.underline, null, false), .box);
    try testz.expectEqual(config.effectiveCursorShape(.line, .block, false), .box);
}

/// A client switching the caret's shape (`set_caret_shape`) changes what
/// is drawn without writing a cell, so the frame has to be redrawn for it.
pub fn contextSigMovesOnCaretShapeTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var ctx = try glyphwire.Context.init(alloc, 40, 20, 0);
    defer ctx.deinit();

    const default_shape = redraw.contextSig(&ctx);
    ctx.caret_shape = .line;
    const line = redraw.contextSig(&ctx);
    ctx.caret_shape = .block;
    const block = redraw.contextSig(&ctx);
    try testz.expectFalse(std.meta.eql(default_shape, line));
    try testz.expectFalse(std.meta.eql(line, block));
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

pub fn contextSigMovesWhenTheWindowScrollbarIsToggledTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var ctx = try glyphwire.Context.init(alloc, 20, 10, 0);
    defer ctx.deinit();

    const on = redraw.contextSig(&ctx);
    // `set_window_scrollbar` changes nothing else the renderer hashes, so
    // the flag needs its own bit in the fingerprint or the repaint is
    // missed.
    ctx.window_scrollbar = false;
    const off = redraw.contextSig(&ctx);
    try testz.expectFalse(std.meta.eql(on, off));
}

// ─── shadow.build ─────────────────────────────────────────────────────

fn shadowAlpha(px: []const u8, side: u32, x: u32, y: u32) u8 {
    return px[(@as(usize, y) * side + x) * 4 + 3];
}

pub fn shadowTextureIsSolidInsideAndClearOutsideTest(_: std.Io, alloc: std.mem.Allocator) !void {
    const sh: glyphwire.Shadow = .{ .blur = 6, .radius = 4, .color = .{ .r = 0, .g = 0, .b = 0, .a = 200 } };
    const g = hs.shadow.geometry(sh);
    try testz.expectEqual(g.corner, 16); // radius + 2 * blur
    const px = try hs.shadow.build(alloc, sh);
    defer alloc.free(px);
    try testz.expectEqual(px.len, @as(usize, g.side) * g.side * 4);

    // The 1px ring `ninePatchQuads` skips is empty, as is the art's own
    // outer corner, which is past the blur's reach.
    try testz.expectEqual(shadowAlpha(px, g.side, 0, 0), 0);
    try testz.expectEqual(shadowAlpha(px, g.side, g.side / 2, 0), 0);
    try testz.expectEqual(shadowAlpha(px, g.side, 1, 1), 0);
    // The middle is the full colour.
    try testz.expectEqual(shadowAlpha(px, g.side, g.side / 2, g.side / 2), 200);
}

pub fn shadowTextureMiddleStripIsUniformTest(_: std.Io, alloc: std.mem.Allocator) !void {
    // Every texel of the stretchable strip must match its neighbours
    // along the strip, or stretching it would smear the corners' shape
    // into the edges.
    const sh: glyphwire.Shadow = .{ .blur = 5, .radius = 7 };
    const g = hs.shadow.geometry(sh);
    const px = try hs.shadow.build(alloc, sh);
    defer alloc.free(px);

    const first = 1 + g.corner;
    var y: u32 = 1;
    while (y < 1 + g.corner) : (y += 1) {
        const a = shadowAlpha(px, g.side, first, y);
        var x = first;
        while (x < first + g.middle) : (x += 1) try testz.expectEqual(shadowAlpha(px, g.side, x, y), a);
    }
}

pub fn shadowWithoutBlurIsASharpRoundedRectTest(_: std.Io, alloc: std.mem.Allocator) !void {
    const sh: glyphwire.Shadow = .{ .radius = 0, .color = .{ .r = 10, .g = 20, .b = 30, .a = 255 } };
    const g = hs.shadow.geometry(sh);
    const px = try hs.shadow.build(alloc, sh);
    defer alloc.free(px);
    // No blur and no radius: every art pixel is fully covered.
    try testz.expectEqual(shadowAlpha(px, g.side, 1, 1), 255);
    try testz.expectEqual(px[((1 * @as(usize, g.side)) + 1) * 4 + 2], 30);
    try testz.expectEqual(hs.shadow.outset(sh), 0);
}

// ── Pane divider glyphs ────────────────────────────────────────────────

fn dividerGlyphAt(cells: []const hs.dividers.Cell, row: usize, col: usize) ?[]const u8 {
    for (cells) |c| if (c.row == row and c.col == col) return c.glyph;
    return null;
}

/// The window split side by side, then the right pane split top/bottom:
/// one vertical line with a horizontal one leaving its right side.
pub fn aDividerJunctionGetsATeeTest(_: std.Io, alloc: std.mem.Allocator) !void {
    const lines = [_]hs.dividers.Line{
        .{ .rect = .{ .row = 0, .col = 10, .cols = 1, .rows = 10 }, .vertical = true },
        .{ .rect = .{ .row = 4, .col = 11, .cols = 9, .rows = 1 }, .vertical = false },
    };
    var cells: std.ArrayList(hs.dividers.Cell) = .empty;
    defer cells.deinit(alloc);
    try hs.dividers.layout(alloc, &lines, &hs.dividers.single, &cells);

    try testz.expectEqual(cells.items.len, 19);
    try testz.expectEqualStr("├", dividerGlyphAt(cells.items, 4, 10).?);
    try testz.expectEqualStr("│", dividerGlyphAt(cells.items, 0, 10).?);
    try testz.expectEqualStr("│", dividerGlyphAt(cells.items, 9, 10).?);
    try testz.expectEqualStr("─", dividerGlyphAt(cells.items, 4, 11).?);
    try testz.expectEqualStr("─", dividerGlyphAt(cells.items, 4, 19).?);
}

/// Horizontal lines on both sides of a vertical one meet in a cross, and a
/// vertical line hanging under a horizontal one is a downward tee.
pub fn dividerCrossAndDownTeeTest(_: std.Io, alloc: std.mem.Allocator) !void {
    const lines = [_]hs.dividers.Line{
        .{ .rect = .{ .row = 0, .col = 0, .cols = 21, .rows = 1 }, .vertical = false },
        .{ .rect = .{ .row = 1, .col = 10, .cols = 1, .rows = 9 }, .vertical = true },
        .{ .rect = .{ .row = 5, .col = 0, .cols = 10, .rows = 1 }, .vertical = false },
        .{ .rect = .{ .row = 5, .col = 11, .cols = 10, .rows = 1 }, .vertical = false },
    };
    var cells: std.ArrayList(hs.dividers.Cell) = .empty;
    defer cells.deinit(alloc);
    try hs.dividers.layout(alloc, &lines, &hs.dividers.heavy, &cells);

    try testz.expectEqualStr("╋", dividerGlyphAt(cells.items, 5, 10).?);
    try testz.expectEqualStr("┳", dividerGlyphAt(cells.items, 0, 10).?);
    try testz.expectEqualStr("━", dividerGlyphAt(cells.items, 0, 3).?);
}

/// A band two cells wide is two parallel lines, not a ladder of tees.
pub fn sideBySideDividerCellsDontJoinTest(_: std.Io, alloc: std.mem.Allocator) !void {
    const lines = [_]hs.dividers.Line{
        .{ .rect = .{ .row = 0, .col = 4, .cols = 2, .rows = 3 }, .vertical = true },
    };
    var cells: std.ArrayList(hs.dividers.Cell) = .empty;
    defer cells.deinit(alloc);
    try hs.dividers.layout(alloc, &lines, &hs.dividers.single, &cells);
    for (cells.items) |c| try testz.expectEqualStr("│", c.glyph);
}

// ── Window title ───────────────────────────────────────────────────────

/// The first frame always sets a title, an unchanged one sends nothing,
/// and a context with no title shows just the app name.
pub fn windowTitleFollowsTheContextTitleTest(_: std.Io, _: std.mem.Allocator) !void {
    var wt: hs.window_title.WindowTitle = .{};
    try testz.expectEqualStr("Glyphwire", wt.update("").?);
    try testz.expectTrue(wt.update("") == null);
    try testz.expectEqualStr("Glyphwire - zoe ~/code/x.zig", wt.update("zoe ~/code/x.zig").?);
    try testz.expectTrue(wt.update("zoe ~/code/x.zig") == null);
    try testz.expectEqualStr("Glyphwire - gw-shell ~/code", wt.update("gw-shell ~/code").?);
}

pub fn dividerPresetNamesTest(_: std.Io, _: std.mem.Allocator) !void {
    try testz.expectTrue(hs.dividers.preset("block").? == .block);
    try testz.expectEqualStr("═", hs.dividers.preset("double").?.glyphs.h);
    try testz.expectTrue(hs.dividers.preset("dotted") == null);
}
