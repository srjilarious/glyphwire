// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: GPL-3.0-or-later

const std = @import("std");
const testz = @import("testz");

// gw-read is an executable (no importable module), but its pure pieces
// are gathered into the `read_support` module (see build.zig) precisely
// so they can be exercised here.
const pages = @import("read_support").pages;
const zoom = @import("read_support").zoom;
const cache = @import("read_support").cache;
const state = @import("read_support").state;
const rconfig = @import("read_support").config;
const mokuro = @import("read_support").mokuro;
const archive = @import("read_support").archive;
const dict = @import("read_support").dict;

// ─── pages.isPage ───────────────────────────────────────────────────────

pub fn isPageAcceptsTheFourSupportedFormatsTest(_: std.Io, _: std.mem.Allocator) !void {
    try testz.expectTrue(pages.isPage("001.png"));
    try testz.expectTrue(pages.isPage("001.jpg"));
    try testz.expectTrue(pages.isPage("001.jpeg"));
    try testz.expectTrue(pages.isPage("001.bmp"));
    try testz.expectTrue(pages.isPage("001.gif"));
    // Case is folded: scanners emit .JPG as often as .jpg.
    try testz.expectTrue(pages.isPage("001.JPG"));
    try testz.expectTrue(pages.isPage("vol1/ch02/003.PNG"));
}

pub fn isPageRejectsUnsupportedAndNonImageEntriesTest(_: std.Io, _: std.mem.Allocator) !void {
    // stb_image has no WebP decoder, so a .webp page can't be shown.
    try testz.expectFalse(pages.isPage("001.webp"));
    try testz.expectFalse(pages.isPage("ComicInfo.xml"));
    try testz.expectFalse(pages.isPage("notes"));
    try testz.expectFalse(pages.isPage(""));
    // A directory entry, which every zip writes alongside its files.
    try testz.expectFalse(pages.isPage("chapter01/"));
}

pub fn isPageRejectsMacOsSidecarsAndResourceForksTest(_: std.Io, _: std.mem.Allocator) !void {
    // The two things a Mac-zipped archive adds that would otherwise
    // double every page in the book.
    try testz.expectFalse(pages.isPage("__MACOSX/001.png"));
    try testz.expectFalse(pages.isPage("__MACOSX/vol1/._001.jpg"));
    try testz.expectFalse(pages.isPage("._001.png"));
    try testz.expectFalse(pages.isPage(".hidden/001.png"));
    // ...but a leading `__` on the *file* is just an odd filename.
    try testz.expectTrue(pages.isPage("__cover.png"));
}

// ─── pages.order ────────────────────────────────────────────────────────

pub fn orderComparesDigitRunsAsNumbersTest(_: std.Io, _: std.mem.Allocator) !void {
    // The whole reason this isn't std.mem.order: byte-wise, "10" < "2".
    try testz.expectTrue(pages.order("page2.png", "page10.png") == .lt);
    try testz.expectTrue(pages.order("page10.png", "page2.png") == .gt);
    try testz.expectTrue(pages.order("page9.png", "page10.png") == .lt);
    try testz.expectTrue(pages.order("page100.png", "page99.png") == .gt);
}

pub fn orderHandlesZeroPaddingAndHugeNumbersTest(_: std.Io, _: std.mem.Allocator) !void {
    // Padding doesn't change the value, only the tie-break.
    try testz.expectTrue(pages.order("p007.png", "p8.png") == .lt);
    try testz.expectTrue(pages.order("p01.png", "p1.png") == .lt);
    try testz.expectTrue(pages.order("p1.png", "p01.png") == .gt);
    try testz.expectTrue(pages.order("p000.png", "p0.png") == .lt);
    // Runs longer than any integer type still compare correctly, which is
    // why the comparison never parses them.
    try testz.expectTrue(pages.order(
        "f99999999999999999999999999999999999998.png",
        "f99999999999999999999999999999999999999.png",
    ) == .lt);
}

pub fn orderFoldsCaseButStaysTotalTest(_: std.Io, _: std.mem.Allocator) !void {
    // Byte-wise, every uppercase name sorts ahead of every lowercase one,
    // which scatters a mixed-case archive. Folded, they interleave.
    // Byte-wise "Cover" sorts before *every* lowercase name; folded it
    // lands where a reader expects it, after "chapter1" and before "d".
    try testz.expectTrue(pages.order("Cover.png", "chapter1.png") == .gt);
    try testz.expectTrue(pages.order("Cover.png", "dregs.png") == .lt);
    try testz.expectTrue(pages.order("apple.png", "Banana.png") == .lt);
    // A pure-case difference is still an order, not a tie.
    try testz.expectTrue(pages.order("A.png", "a.png") != .eq);
    try testz.expectTrue(pages.order("a.png", "a.png") == .eq);
}

pub fn orderSortsARealisticArchiveListingTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var names = [_][]const u8{
        "ch02/p10.jpg",
        "ch1/p2.jpg",
        "ch1/p10.jpg",
        "ch1/p1.jpg",
        "ch02/p9.jpg",
        "cover.jpg",
    };
    _ = alloc;
    std.mem.sort([]const u8, &names, {}, pages.lessThan);

    try testz.expectEqualStr(names[0], "ch1/p1.jpg");
    try testz.expectEqualStr(names[1], "ch1/p2.jpg");
    try testz.expectEqualStr(names[2], "ch1/p10.jpg");
    // "ch02" and "ch1" share the "ch" prefix, then compare 02 vs 1
    // numerically -- so chapter 1 really does come first.
    try testz.expectEqualStr(names[3], "ch02/p9.jpg");
    try testz.expectEqualStr(names[4], "ch02/p10.jpg");
    try testz.expectEqualStr(names[5], "cover.jpg");
}

// ─── zoom.layout ────────────────────────────────────────────────────────

const cell: zoom.Size = .{ .w = 10, .h = 20 };
// A portrait page, the shape a manga scan actually is.
const page: zoom.Size = .{ .w = 1200, .h = 1800 };
// 80x30 cells = 800x600 px.
const window: zoom.View = .{ .cols = 80, .rows = 30 };

pub fn fitScreenShowsTheWholePageWithNoOverflowTest(_: std.Io, _: std.mem.Allocator) !void {
    const l = zoom.layout(.fit_screen, 1.0, page, window, cell, .{});
    // Height is the binding axis: 600/1800 = 0.333 vs 800/1200 = 0.667.
    try testz.expectTrue(@abs(l.scale - (600.0 / 1800.0)) < 0.0001);
    // The defining property of fit-screen: nothing to pan on either axis.
    try testz.expectEqual(l.max_pan_row, 0);
    try testz.expectEqual(l.max_pan_col, 0);
    try testz.expectEqual(l.rows, 30);
}

pub fn fitScreenCentersAPageNarrowerThanTheWindowTest(_: std.Io, _: std.mem.Allocator) !void {
    const l = zoom.layout(.fit_screen, 1.0, page, window, cell, .{});
    // 1200 * 0.333 = 400px = 40 cells, in an 80-cell window.
    try testz.expectEqual(l.cols, 40);
    try testz.expectEqual(l.col, 20);
    try testz.expectEqual(l.row, 0);
}

pub fn fitWidthOverflowsVerticallyAndReportsThePanRangeTest(_: std.Io, _: std.mem.Allocator) !void {
    const l = zoom.layout(.fit_width, 1.0, page, window, cell, .{});
    // 800/1200 = 0.667, so the page is 1800 * 0.667 = 1200px = 60 rows.
    try testz.expectEqual(l.cols, 80);
    try testz.expectEqual(l.rows, 60);
    // 60 rows of content in a 30-row window: 30 rows of pan.
    try testz.expectEqual(l.max_pan_row, 30);
    try testz.expectEqual(l.max_pan_col, 0);
    // No centring on an axis that overflows.
    try testz.expectEqual(l.row, 0);
    try testz.expectEqual(l.col, 0);
}

pub fn upscaleOffLeavesASmallPageAtNaturalSizeTest(_: std.Io, _: std.mem.Allocator) !void {
    const small: zoom.Size = .{ .w = 300, .h = 400 };
    const on = zoom.layout(.fit_screen, 1.0, small, window, cell, .{ .upscale = true });
    const off = zoom.layout(.fit_screen, 1.0, small, window, cell, .{ .upscale = false });
    try testz.expectTrue(on.scale > 1.0);
    try testz.expectTrue(off.scale == 1.0);
    // ...and the explicit modes ignore the flag entirely.
    const natural = zoom.layout(.natural, 1.0, small, window, cell, .{ .upscale = false });
    try testz.expectTrue(natural.scale == 1.0);
}

pub fn maxScaleCapsEveryModeIncludingFitTest(_: std.Io, _: std.mem.Allocator) !void {
    const tiny: zoom.Size = .{ .w = 40, .h = 40 };
    // Fitting a 40px page into 600px wants 15x; the cap is what keeps a
    // pathological page from covering a million server-side cells.
    const l = zoom.layout(.fit_screen, 1.0, tiny, window, cell, .{ .max_scale = 4.0 });
    try testz.expectTrue(l.scale == 4.0);
    const free = zoom.layout(.free, 99.0, page, window, cell, .{ .max_scale = 4.0 });
    try testz.expectTrue(free.scale == 4.0);
}

pub fn degenerateSizesYieldAOneCellLayoutTest(_: std.Io, _: std.mem.Allocator) !void {
    // A page whose header didn't measure shouldn't divide by zero -- the
    // reader has to stay up to report it.
    const l = zoom.layout(.fit_screen, 1.0, .{ .w = 0, .h = 0 }, window, cell, .{});
    try testz.expectEqual(l.cols, 1);
    try testz.expectEqual(l.rows, 1);
    try testz.expectEqual(l.max_pan_row, 0);
}

pub fn zoomStepIsMultiplicativeAndClampedTest(_: std.Io, _: std.mem.Allocator) !void {
    const limits: zoom.Limits = .{ .min_scale = 0.5, .max_scale = 2.0, .step = 2.0 };
    try testz.expectTrue(zoom.step(1.0, .in, limits) == 2.0);
    try testz.expectTrue(zoom.step(1.0, .out, limits) == 0.5);
    // Already at the ceiling: another `+` is a no-op, not an overflow.
    try testz.expectTrue(zoom.step(2.0, .in, limits) == 2.0);
    try testz.expectTrue(zoom.step(0.5, .out, limits) == 0.5);
}

pub fn clampPanStopsAtBothEdgesTest(_: std.Io, _: std.mem.Allocator) !void {
    try testz.expectEqual(zoom.clampPan(5, 10), 5);
    try testz.expectEqual(zoom.clampPan(50, 10), 10);
    // Panning left off the start clamps to 0 rather than wrapping a usize.
    try testz.expectEqual(zoom.clampPan(-3, 10), 0);
    try testz.expectEqual(zoom.clampPan(7, 0), 0);
}

// ─── cache (the image-handle LRU) ───────────────────────────────────────

fn entry(page_index: usize, handle: u32) cache.Entry {
    return .{ .page = page_index, .handle = handle, .width = 100, .height = 200 };
}

pub fn cacheHoldsUpToCapacityWithoutEvictingTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var c: cache.Cache = .init(3);
    defer c.deinit(alloc);

    try testz.expectTrue(try c.put(alloc, entry(0, 10)) == null);
    try testz.expectTrue(try c.put(alloc, entry(1, 11)) == null);
    try testz.expectTrue(try c.put(alloc, entry(2, 12)) == null);
    try testz.expectEqual(c.len(), 3);
    try testz.expectTrue(c.get(0) != null);
    try testz.expectTrue(c.get(2) != null);
}

pub fn cacheEvictsTheLeastRecentlyUsedPageTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var c: cache.Cache = .init(3);
    defer c.deinit(alloc);

    _ = try c.put(alloc, entry(0, 10));
    _ = try c.put(alloc, entry(1, 11));
    _ = try c.put(alloc, entry(2, 12));
    // Touching page 0 makes page 1 the oldest, which is the whole point:
    // "go back two pages" shouldn't have thrown page 0 away.
    _ = c.get(0);

    const evicted = try c.put(alloc, entry(3, 13));
    try testz.expectTrue(evicted != null);
    try testz.expectEqual(evicted.?.page, 1);
    // The caller destroys that handle; the cache must not still hand it out.
    try testz.expectTrue(c.get(1) == null);
    try testz.expectTrue(c.get(0) != null);
    try testz.expectTrue(c.get(3) != null);
}

pub fn cacheContainsDoesNotDisturbRecencyTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var c: cache.Cache = .init(2);
    defer c.deinit(alloc);

    _ = try c.put(alloc, entry(0, 10));
    _ = try c.put(alloc, entry(1, 11));
    // A prefetch probe must not promote page 0 over page 1 -- only what
    // the reader actually looked at should count as recent.
    try testz.expectTrue(c.contains(0));

    const evicted = try c.put(alloc, entry(2, 12));
    try testz.expectEqual(evicted.?.page, 0);
}

pub fn cacheReinsertReturnsTheOldHandleToDestroyTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var c: cache.Cache = .init(4);
    defer c.deinit(alloc);

    _ = try c.put(alloc, entry(0, 10));
    const replaced = try c.put(alloc, entry(0, 99));
    try testz.expectTrue(replaced != null);
    try testz.expectEqual(replaced.?.handle, 10);
    try testz.expectEqual(c.len(), 1);
    try testz.expectEqual(c.get(0).?.handle, 99);
    // Re-putting the identical handle isn't a leak, so nothing comes back.
    try testz.expectTrue(try c.put(alloc, entry(0, 99)) == null);
}

pub fn cacheDrainHandsBackEverythingItHeldTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var c: cache.Cache = .init(4);
    defer c.deinit(alloc);
    _ = try c.put(alloc, entry(0, 10));
    _ = try c.put(alloc, entry(1, 11));

    var out: std.ArrayList(cache.Entry) = .empty;
    defer out.deinit(alloc);
    try c.drain(alloc, &out);

    try testz.expectEqual(out.items.len, 2);
    try testz.expectEqual(c.len(), 0);
}

pub fn cacheCapacityIsClampedToAUsableRangeTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var zero: cache.Cache = .init(0);
    defer zero.deinit(alloc);
    // A zero-capacity cache would evict every page the instant it loaded.
    try testz.expectEqual(zero.capacity, 1);

    var huge: cache.Cache = .init(10_000);
    defer huge.deinit(alloc);
    try testz.expectEqual(huge.capacity, cache.max_capacity);
}

// ─── state (the resume file) ────────────────────────────────────────────

pub fn stateRoundTripsABookmarkTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var store: state.Store = .init(alloc);
    defer store.deinit();
    try store.record("/books/vol1.cbz", .{ .page = 42, .mode = "fit_width", .direction = "ltr" });

    const json = try state.serialize(alloc, &store);
    defer alloc.free(json);

    var back = state.parse(alloc, json);
    defer back.deinit();

    const mark = back.get("/books/vol1.cbz").?;
    try testz.expectEqual(mark.page, 42);
    try testz.expectEqualStr(mark.mode, "fit_width");
    try testz.expectEqualStr(mark.direction, "ltr");
}

pub fn stateEscapesPathsThatNeedItTest(_: std.Io, alloc: std.mem.Allocator) !void {
    // A real library has quotes and backslashes in filenames; the state
    // file has to survive them rather than emitting invalid JSON.
    const path = "/books/\"odd\" \\ name.cbz";
    var store: state.Store = .init(alloc);
    defer store.deinit();
    try store.record(path, .{ .page = 3, .mode = "fit_screen", .direction = "rtl" });

    const json = try state.serialize(alloc, &store);
    defer alloc.free(json);

    var back = state.parse(alloc, json);
    defer back.deinit();
    try testz.expectEqual(back.get(path).?.page, 3);
}

pub fn stateRecordReplacesRatherThanDuplicatesTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var store: state.Store = .init(alloc);
    defer store.deinit();
    try store.record("/a.cbz", .{ .page = 1, .mode = "fit_screen", .direction = "rtl" });
    try store.record("/a.cbz", .{ .page = 9, .mode = "natural", .direction = "rtl" });

    try testz.expectEqual(store.entries.count(), 1);
    try testz.expectEqual(store.get("/a.cbz").?.page, 9);
}

pub fn stateTreatsGarbageAsAnEmptyStoreTest(_: std.Io, alloc: std.mem.Allocator) !void {
    // Losing your place is a nuisance; refusing to open a book because a
    // state file got truncated is not acceptable.
    for ([_][]const u8{ "", "not json", "[1,2,3]", "{\"a\": 5}", "{\"a\": {\"page\": \"x\"}}" }) |bad| {
        var store = state.parse(alloc, bad);
        defer store.deinit();
        // The last case parses the entry but rejects the bad field,
        // falling back to page 0 rather than dropping the whole file.
        if (store.get("a")) |mark| try testz.expectEqual(mark.page, 0);
    }
}

pub fn stateTrimsToTheNewestEntriesOnSaveTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var store: state.Store = .init(alloc);
    defer store.deinit();

    var i: usize = 0;
    while (i < state.Store.max_entries + 10) : (i += 1) {
        var buf: [64]u8 = undefined;
        const path = try std.fmt.bufPrint(&buf, "/book{d}.cbz", .{i});
        try store.record(path, .{ .page = i, .mode = "fit_screen", .direction = "rtl" });
    }

    const json = try state.serialize(alloc, &store);
    defer alloc.free(json);
    var back = state.parse(alloc, json);
    defer back.deinit();

    try testz.expectEqual(back.entries.count(), state.Store.max_entries);
    // The oldest went; the newest stayed.
    try testz.expectTrue(back.get("/book0.cbz") == null);
    try testz.expectTrue(back.get("/book509.cbz") != null);
}

// ─── config (read.conf.lua) ─────────────────────────────────────────────

pub fn configDefaultsAreMangaShapedTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var result = rconfig.load(alloc, "");
    defer result.deinit(alloc);
    try testz.expectTrue(result.err == null);
    // The reader was built for manga, so right-to-left and whole-page.
    try testz.expectTrue(result.config.direction == .rtl);
    try testz.expectTrue(result.config.mode == .fit_screen);
    try testz.expectEqual(result.config.jump_pages, 5);
}

pub fn configReadsEveryKeyTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var result = rconfig.load(alloc,
        \\config = {
        \\  direction = "ltr",
        \\  mode = "fit-width",
        \\  cache_pages = 12,
        \\  prefetch = 2,
        \\  jump_pages = 10,
        \\  pan_step = 6,
        \\  max_zoom = 8.0,
        \\  upscale = false,
        \\  remember_position = false,
        \\}
    );
    defer result.deinit(alloc);

    try testz.expectTrue(result.err == null);
    try testz.expectTrue(result.config.direction == .ltr);
    try testz.expectTrue(result.config.mode == .fit_width);
    try testz.expectEqual(result.config.cache_pages, 12);
    try testz.expectEqual(result.config.prefetch, 2);
    try testz.expectEqual(result.config.jump_pages, 10);
    try testz.expectEqual(result.config.pan_step, 6);
    try testz.expectTrue(result.config.max_zoom == 8.0);
    try testz.expectFalse(result.config.upscale);
    try testz.expectFalse(result.config.remember_position);
}

pub fn configClampsOutOfRangeValuesTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var result = rconfig.load(alloc,
        \\config = { pan_step = 9999, max_zoom = 1000, cache_pages = 500 }
    );
    defer result.deinit(alloc);
    try testz.expectEqual(result.config.pan_step, rconfig.pan_step_max);
    try testz.expectTrue(result.config.max_zoom == rconfig.zoom_max_ceiling);
    try testz.expectEqual(result.config.cache_pages, 64);
}

pub fn configRaisesACacheTooSmallForItsPrefetchTest(_: std.Io, alloc: std.mem.Allocator) !void {
    // Otherwise every prefetched page evicts the one being read.
    var result = rconfig.load(alloc,
        \\config = { cache_pages = 1, prefetch = 4 }
    );
    defer result.deinit(alloc);
    try testz.expectEqual(result.config.cache_pages, 6);
}

pub fn configKeepsDefaultsForBadTypesAndUnknownKeysTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var result = rconfig.load(alloc,
        \\config = { direction = 7, mode = "sideways", nonsense = true, pan_step = "wide" }
    );
    defer result.deinit(alloc);
    try testz.expectTrue(result.err == null);
    try testz.expectTrue(result.config.direction == .rtl);
    try testz.expectTrue(result.config.mode == .fit_screen);
    try testz.expectEqual(result.config.pan_step, 3);
}

pub fn configReportsALuaErrorButKeepsWhatParsedTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var result = rconfig.load(alloc, "config = { this is not lua");
    defer result.deinit(alloc);
    try testz.expectTrue(result.err != null);
    try testz.expectEqual(result.config.jump_pages, 5);
}

pub fn parseModeAcceptsBothSpellingsTest(_: std.Io, _: std.mem.Allocator) !void {
    // Config files read better hyphenated; the enum's own tag names use
    // underscores, and the state file stores those.
    try testz.expectTrue(rconfig.parseMode("fit").? == .fit_screen);
    try testz.expectTrue(rconfig.parseMode("fit-screen").? == .fit_screen);
    try testz.expectTrue(rconfig.parseMode("fit_screen").? == .fit_screen);
    try testz.expectTrue(rconfig.parseMode("fit-height").? == .fit_height);
    try testz.expectTrue(rconfig.parseMode("1:1").? == .natural);
    try testz.expectTrue(rconfig.parseMode("upside-down") == null);
}

pub fn parseTitleScaleAcceptsItsThreeValuesTest(_: std.Io, _: std.mem.Allocator) !void {
    try testz.expectTrue(rconfig.parseTitleScale("1x").? == .x1);
    try testz.expectTrue(rconfig.parseTitleScale("1.5x").? == .x1_5);
    try testz.expectTrue(rconfig.parseTitleScale("2x").? == .x2);
    try testz.expectTrue(rconfig.parseTitleScale("huge") == null);
}

pub fn configReadsDictionaryTitleScaleTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var result = rconfig.load(alloc,
        \\config = { dictionary_title_scale = "2x" }
    );
    defer result.deinit(alloc);
    try testz.expectTrue(result.err == null);
    try testz.expectTrue(result.config.dictionary_title_scale == .x2);
}

pub fn directionParsesAndRoundTripsThroughItsNameTest(_: std.Io, _: std.mem.Allocator) !void {
    // state.zig stores the name, so the pair has to be inverse.
    try testz.expectTrue(rconfig.Direction.parse(rconfig.Direction.rtl.name()).? == .rtl);
    try testz.expectTrue(rconfig.Direction.parse(rconfig.Direction.ltr.name()).? == .ltr);
    try testz.expectTrue(rconfig.Direction.parse("sideways") == null);
}

// ─── mokuro: parsing ────────────────────────────────────────────────────

/// A minimal but realistic `.mokuro` file: two pages, three bubbles.
const mokuro_sample =
    \\{
    \\  "version": "0.1.7",
    \\  "title": "テスト巻",
    \\  "pages": [
    \\    {
    \\      "version": "0.1.7",
    \\      "img_width": 1200,
    \\      "img_height": 1700,
    \\      "img_path": "001.jpg",
    \\      "blocks": [
    \\        { "box": [800, 100, 1100, 500], "vertical": true, "font_size": 30,
    \\          "lines": ["おはよう", "ございます"] },
    \\        { "box": [100, 150, 400, 520], "vertical": true, "font_size": 28,
    \\          "lines": ["いってきます"] },
    \\        { "box": [300, 1100, 900, 1500], "vertical": false, "font_size": 24,
    \\          "lines": ["hello", "world"] }
    \\      ]
    \\    },
    \\    {
    \\      "img_width": 1200,
    \\      "img_height": 1700,
    \\      "img_path": "002.jpg",
    \\      "blocks": []
    \\    }
    \\  ]
    \\}
;

pub fn mokuroParsesPagesBlocksAndBoxesTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var vol = try mokuro.parse(alloc, mokuro_sample);
    defer vol.deinit();

    try testz.expectEqualStr(vol.title, "テスト巻");
    try testz.expectEqual(vol.pages.len, 2);
    try testz.expectEqual(vol.pages[0].img_width, 1200);
    try testz.expectEqual(vol.pages[0].img_height, 1700);
    try testz.expectEqual(vol.pages[0].blocks.len, 3);
    try testz.expectEqual(vol.pages[1].blocks.len, 0);

    const b = vol.pages[0].blocks[0];
    try testz.expectEqual(b.box.x1, 800);
    try testz.expectEqual(b.box.y2, 500);
    try testz.expectTrue(b.vertical);
    try testz.expectEqual(b.lines.len, 2);
    try testz.expectEqualStr(b.lines[1], "ございます");
    // Only one of the two pages carries text.
    try testz.expectEqual(vol.pagesWithText(), 1);
}

pub fn mokuroDropsBlocksWithNoBoxOrNoTextTest(_: std.Io, alloc: std.mem.Allocator) !void {
    // Per the module's error policy: a bad block is dropped, the volume
    // still opens. Four blocks in, one survives.
    const json =
        \\{"pages": [{"img_path": "a.png", "blocks": [
        \\  {"lines": ["no box"]},
        \\  {"box": [1, 2, 3], "lines": ["short box"]},
        \\  {"box": [0, 0, 10, 10], "lines": []},
        \\  {"box": [0, 0, 10, 10], "lines": ["kept"]}
        \\]}]}
    ;
    var vol = try mokuro.parse(alloc, json);
    defer vol.deinit();
    try testz.expectEqual(vol.pages.len, 1);
    try testz.expectEqual(vol.pages[0].blocks.len, 1);
    try testz.expectEqualStr(vol.pages[0].blocks[0].lines[0], "kept");
}

pub fn mokuroTreatsGarbageAsAnEmptyVolumeRatherThanAnErrorTest(_: std.Io, alloc: std.mem.Allocator) !void {
    const bad = [_][]const u8{ "", "not json at all", "[1,2,3]", "{}", "{\"pages\": 7}" };
    for (bad) |src| {
        var vol = try mokuro.parse(alloc, src);
        defer vol.deinit();
        try testz.expectEqual(vol.pages.len, 0);
    }
}

pub fn mokuroNormalisesAnInvertedBoxTest(_: std.Io, alloc: std.mem.Allocator) !void {
    // A box written bottom-right first still describes the same region.
    const json =
        \\{"pages": [{"img_path": "a.png", "blocks": [
        \\  {"box": [90, 80, 10, 20], "lines": ["x"]}
        \\]}]}
    ;
    var vol = try mokuro.parse(alloc, json);
    defer vol.deinit();
    const box = vol.pages[0].blocks[0].box;
    try testz.expectEqual(box.x1, 10);
    try testz.expectEqual(box.y1, 20);
    try testz.expectEqual(box.x2, 90);
    try testz.expectEqual(box.y2, 80);
    try testz.expectTrue(box.contains(50, 50));
    try testz.expectFalse(box.contains(5, 50));
}

// ─── mokuro: matching a page to an archive entry ────────────────────────

pub fn mokuroMatchesAPageByPathThenBasenameThenStemTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var vol = try mokuro.parse(alloc, mokuro_sample);
    defer vol.deinit();

    // Exact, as mokuro wrote it.
    try testz.expectTrue(vol.pageFor("001.jpg") != null);
    // The archive nests its pages under a folder; mokuro doesn't.
    try testz.expectTrue(vol.pageFor("Vol1/images/001.jpg") != null);
    // Re-encoded to PNG after the OCR run: the stem still matches.
    try testz.expectTrue(vol.pageFor("Vol1/001.png") != null);
    // A page the sidecar simply doesn't cover.
    try testz.expectTrue(vol.pageFor("cover.jpg") == null);
}

pub fn mokuroPageMatchIsExactNotAPrefixTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var vol = try mokuro.parse(alloc, mokuro_sample);
    defer vol.deinit();
    // `0010.jpg` shares a prefix with `001.jpg` and must not match it --
    // a fuzzy match here would put the wrong page's text on the screen.
    try testz.expectTrue(vol.pageFor("0010.jpg") == null);
    try testz.expectTrue(vol.pageFor("001.jpg.bak") == null);
}

// ─── mokuro: reading order ──────────────────────────────────────────────

pub fn mokuroReadingOrderGoesRightToLeftThenDownForMangaTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var vol = try mokuro.parse(alloc, mokuro_sample);
    defer vol.deinit();
    const pg = &vol.pages[0];

    var buf: [8]usize = undefined;
    var bands: [8]u32 = undefined;
    const order = mokuro.readingOrder(pg, .rtl, &buf, &bands);
    try testz.expectEqual(order.len, 3);
    // Blocks 0 and 1 share a band near the top: their tops are 100 and
    // 150, a 50px gap against a ~106px tolerance on a 1700px page --
    // and note a *quantising* band would have split them, since 106
    // falls between the two. Block 0 is further right, so it leads.
    // Block 2 is far down the page and gets its own band.
    try testz.expectEqual(order[0], 0);
    try testz.expectEqual(order[1], 1);
    try testz.expectEqual(order[2], 2);
}

pub fn mokuroReadingOrderFlipsForALeftToRightBookTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var vol = try mokuro.parse(alloc, mokuro_sample);
    defer vol.deinit();
    const pg = &vol.pages[0];

    var buf: [8]usize = undefined;
    var bands: [8]u32 = undefined;
    const order = mokuro.readingOrder(pg, .ltr, &buf, &bands);
    // Same band, opposite sweep: the left-hand bubble now leads.
    try testz.expectEqual(order[0], 1);
    try testz.expectEqual(order[1], 0);
    try testz.expectEqual(order[2], 2);
}

pub fn mokuroReadingOrderIsBandedNotPurelyHorizontalTest(_: std.Io, alloc: std.mem.Allocator) !void {
    // A bubble low on the page but far right must not jump ahead of one
    // high up and slightly left: reading order is across-then-down, and
    // the banding is what encodes that.
    const json =
        \\{"pages": [{"img_path": "a.png", "img_width": 1000, "img_height": 1600,
        \\ "blocks": [
        \\   {"box": [10, 1400, 300, 1550], "lines": ["low left"]},
        \\   {"box": [700, 1400, 990, 1550], "lines": ["low right"]},
        \\   {"box": [400, 20, 600, 200], "lines": ["high middle"]}
        \\]}]}
    ;
    var vol = try mokuro.parse(alloc, json);
    defer vol.deinit();

    var buf: [8]usize = undefined;
    var bands: [8]u32 = undefined;
    const order = mokuro.readingOrder(&vol.pages[0], .rtl, &buf, &bands);
    try testz.expectEqual(order[0], 2); // the top band first...
    try testz.expectEqual(order[1], 1); // ...then across the bottom one,
    try testz.expectEqual(order[2], 0); // right to left.
}

// ─── mokuro: hit testing ────────────────────────────────────────────────

pub fn mokuroBlockAtFindsTheBubbleUnderAPixelTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var vol = try mokuro.parse(alloc, mokuro_sample);
    defer vol.deinit();
    const pg = &vol.pages[0];

    try testz.expectEqual(mokuro.blockAt(pg, 900, 200).?, 0);
    try testz.expectEqual(mokuro.blockAt(pg, 200, 300).?, 1);
    try testz.expectEqual(mokuro.blockAt(pg, 500, 1200).?, 2);
    // The gutter between bubbles is nobody's.
    try testz.expectTrue(mokuro.blockAt(pg, 600, 800) == null);
    // The exclusive far edge belongs to the next pixel, not this box.
    try testz.expectTrue(mokuro.blockAt(pg, 1100, 100) == null);
}

pub fn mokuroBlockAtPrefersTheSmallestContainingBoxTest(_: std.Io, alloc: std.mem.Allocator) !void {
    // mokuro nests boxes; the inner one is the text you were pointing at
    // and would be unreachable if the first or largest match won.
    const json =
        \\{"pages": [{"img_path": "a.png", "blocks": [
        \\  {"box": [0, 0, 1000, 1000], "lines": ["outer"]},
        \\  {"box": [400, 400, 600, 600], "lines": ["inner"]}
        \\]}]}
    ;
    var vol = try mokuro.parse(alloc, json);
    defer vol.deinit();
    const pg = &vol.pages[0];
    try testz.expectEqual(mokuro.blockAt(pg, 500, 500).?, 1);
    try testz.expectEqual(mokuro.blockAt(pg, 100, 100).?, 0);
}

// ─── mokuro: joining and wrapping ───────────────────────────────────────

pub fn mokuroJoinsJapaneseColumnsWithNoSeparatorTest(_: std.Io, alloc: std.mem.Allocator) !void {
    const lines = [_][]const u8{ "おはよう", "ございます" };
    const joined = try mokuro.joinLines(alloc, &lines);
    defer alloc.free(joined);
    // A space here would be wrong: the columns are one sentence.
    try testz.expectEqualStr(joined, "おはようございます");
}

pub fn mokuroJoinsAsciiLinesWithASpaceTest(_: std.Io, alloc: std.mem.Allocator) !void {
    const lines = [_][]const u8{ "hello", "world" };
    const joined = try mokuro.joinLines(alloc, &lines);
    defer alloc.free(joined);
    try testz.expectEqualStr(joined, "hello world");
}

pub fn mokuroDoesNotDoubleASpaceAtALineSeamTest(_: std.Io, alloc: std.mem.Allocator) !void {
    const lines = [_][]const u8{ "hello ", "world" };
    const joined = try mokuro.joinLines(alloc, &lines);
    defer alloc.free(joined);
    try testz.expectEqualStr(joined, "hello world");
}

pub fn mokuroJoinsAMixedSeamWithoutASpaceTest(_: std.Io, alloc: std.mem.Allocator) !void {
    // One side CJK: no space. Japanese sets no space against a Latin
    // word inside a bubble either.
    const lines = [_][]const u8{ "です", "ne" };
    const joined = try mokuro.joinLines(alloc, &lines);
    defer alloc.free(joined);
    try testz.expectEqualStr(joined, "ですne");
}

pub fn mokuroDisplayWidthCountsCjkAsTwoCellsTest(_: std.Io, _: std.mem.Allocator) !void {
    try testz.expectEqual(mokuro.displayWidth("abc"), 3);
    try testz.expectEqual(mokuro.displayWidth("あい"), 4);
    try testz.expectEqual(mokuro.displayWidth("aあ"), 3);
    try testz.expectEqual(mokuro.displayWidth(""), 0);
}

pub fn mokuroWrapsJapaneseByCellWidthTest(_: std.Io, alloc: std.mem.Allocator) !void {
    // Six kana = 12 cells; at 6 columns that is three kana a row.
    const rows = try mokuro.wrap(alloc, "あいうえおか", 6);
    defer alloc.free(rows);
    try testz.expectEqual(rows.len, 2);
    try testz.expectEqualStr(rows[0], "あいう");
    try testz.expectEqualStr(rows[1], "えおか");
}

pub fn mokuroWrapBreaksAsciiAtASpaceTest(_: std.Io, alloc: std.mem.Allocator) !void {
    const rows = try mokuro.wrap(alloc, "hello brave world", 11);
    defer alloc.free(rows);
    try testz.expectEqual(rows.len, 2);
    // Broken at the space, and the space itself is consumed rather than
    // becoming a leading blank on the next row.
    try testz.expectEqualStr(rows[0], "hello brave");
    try testz.expectEqualStr(rows[1], "world");
}

pub fn mokuroWrapBreaksMidWordWhenAWordIsWiderThanTheBoxTest(_: std.Io, alloc: std.mem.Allocator) !void {
    // No space to back up to: better a hard break than an overflowing row.
    const rows = try mokuro.wrap(alloc, "supercalifragilistic", 8);
    defer alloc.free(rows);
    try testz.expectTrue(rows.len >= 3);
    try testz.expectEqualStr(rows[0], "supercal");
    for (rows) |r| try testz.expectTrue(mokuro.displayWidth(r) <= 8);
}

pub fn mokuroWrapNeverSplitsACodepointTest(_: std.Io, alloc: std.mem.Allocator) !void {
    // An odd column count against two-cell characters is the case that
    // would tempt a byte-wise wrap into cutting a multi-byte sequence.
    const rows = try mokuro.wrap(alloc, "あいうえお", 3);
    defer alloc.free(rows);
    for (rows) |r| try testz.expectTrue(std.unicode.utf8ValidateSlice(r));
    // Every row is one 2-cell character: 3 columns fits one, not two.
    try testz.expectEqual(rows.len, 5);
}

pub fn mokuroColumnToByteLandsOnCjkCharacterStartsTest(_: std.Io, _: std.mem.Allocator) !void {
    // "食べる" -- each character is 2 display columns.
    const text = "食べる";
    try testz.expectEqual(mokuro.columnToByte(text, 0), 0);
    // Column 1 is still inside "食" (columns 0-1); it resolves to the
    // character's start, not into the middle of its bytes.
    try testz.expectEqual(mokuro.columnToByte(text, 1), 0);
    try testz.expectEqual(mokuro.columnToByte(text, 2), "食".len);
    try testz.expectEqual(mokuro.columnToByte(text, 4), "食べ".len);
}

pub fn mokuroColumnToByteClampsPastTheEndTest(_: std.Io, _: std.mem.Allocator) !void {
    const text = "猫";
    try testz.expectEqual(mokuro.columnToByte(text, 100), text.len);
    try testz.expectEqual(mokuro.columnToByte("", 0), 0);
}

// ─── archive: recognising the sidecar's name ────────────────────────────

pub fn mokuroSidecarNameIsRecognisedCaseInsensitivelyTest(_: std.Io, _: std.mem.Allocator) !void {
    try testz.expectTrue(archive.isMokuroName("Vol1.mokuro"));
    try testz.expectTrue(archive.isMokuroName("Vol1.MOKURO"));
    try testz.expectFalse(archive.isMokuroName("Vol1.mokuro.bak"));
    try testz.expectFalse(archive.isMokuroName("mokuro"));
    try testz.expectFalse(archive.isMokuroName(""));
}

// ─── dict: term bank parsing ────────────────────────────────────────────
//
// `dict.openMemory` builds an in-memory (`:memory:`) SQLite database the
// same way `loadFromDir` builds a real one on disk -- see `dict.zig`'s
// module doc comment -- so these pin the parse by querying it straight
// back out with `dict.lookup` rather than reading an in-memory entries
// array (there is no longer one to read).

pub fn dictParsesTermBankRowsTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var d = try dict.openMemory(alloc, &.{
        \\[["食べる","たべる","","v1",0,["to eat"],1,""]]
    }, null);
    defer d.deinit();
    const m = (try dict.lookup(alloc, &d, "食べる")).?;
    defer dict.freeEntries(alloc, m.entries);
    try testz.expectEqual(m.entries.len, 1);
    try testz.expectEqualStr(m.entries[0].term, "食べる");
    try testz.expectEqualStr(m.entries[0].reading, "たべる");
    try testz.expectEqualStr(m.entries[0].rules, "v1");
    try testz.expectEqual(m.entries[0].glossary.len, 1);
    try testz.expectEqualStr(m.entries[0].glossary[0], "to eat");
    try testz.expectEqual(m.entries[0].sequence, 1);
}

pub fn dictDropsRowsShorterThanEightFieldsTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var d = try dict.openMemory(alloc, &.{
        \\[["short","","","",0]]
    }, null);
    defer d.deinit();
    const m = try dict.lookup(alloc, &d, "short");
    try testz.expectTrue(m == null);
}

pub fn dictFlattensStructuredContentGlossaryTest(_: std.Io, alloc: std.mem.Allocator) !void {
    // Jitendex-style structured content: a tagged object wrapping the
    // real text rather than a plain string.
    var d = try dict.openMemory(alloc, &.{
        \\[["優しい","やさしい","","adj-i",0,[{"content":"kind, gentle"}],5,""]]
    }, null);
    defer d.deinit();
    const m = (try dict.lookup(alloc, &d, "優しい")).?;
    defer dict.freeEntries(alloc, m.entries);
    try testz.expectEqual(m.entries[0].glossary.len, 1);
    try testz.expectEqualStr(m.entries[0].glossary[0], "kind, gentle");
}

pub fn dictTreatsGarbageAsAnEmptyBankTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var d = try dict.openMemory(alloc, &.{ "", "not json", "{}", "[1,2,3]" }, null);
    defer d.deinit();
    const m = try dict.lookup(alloc, &d, "食べる");
    try testz.expectTrue(m == null);
}

// ─── dict: lookup ───────────────────────────────────────────────────────

const lookup_dict_json =
    \\[
    \\  ["食べる","たべる","","v1",0,["to eat"],1,""],
    \\  ["分かる","わかる","","v5",0,["to understand"],2,""],
    \\  ["ある","ある","","exp",0,["there is (inanimate)"],3,""],
    \\  ["猫","ねこ","","n",0,["cat"],4,""]
    \\]
;

pub fn dictLookupFindsExactDictionaryFormTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var d = try dict.openMemory(alloc, &.{lookup_dict_json}, null);
    defer d.deinit();
    const m = (try dict.lookup(alloc, &d, "猫が好き")).?;
    defer dict.freeEntries(alloc, m.entries);
    try testz.expectTrue(m.reason == null);
    try testz.expectEqualStr("猫が好き"[0..m.len], "猫");
    try testz.expectEqual(m.entries.len, 1);
    try testz.expectEqualStr(m.entries[0].term, "猫");
}

pub fn dictLookupDeinflectsIchidanTeFormTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var d = try dict.openMemory(alloc, &.{lookup_dict_json}, null);
    defer d.deinit();
    const m = (try dict.lookup(alloc, &d, "食べてすぐ")).?;
    defer dict.freeEntries(alloc, m.entries);
    defer alloc.free(m.reason.?);
    try testz.expectEqualStr(m.reason.?, "te-form");
    try testz.expectEqualStr("食べてすぐ"[0..m.len], "食べて");
    try testz.expectEqual(m.entries.len, 1);
    try testz.expectEqualStr(m.entries[0].term, "食べる");
}

pub fn dictLookupDeinflectsGodanRuVerbPastTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var d = try dict.openMemory(alloc, &.{lookup_dict_json}, null);
    defer d.deinit();
    // 分かった -- past of 分かる (godan, not ichidan -- the ambiguous
    // -る class `rules_out` filtering exists to resolve).
    const m = (try dict.lookup(alloc, &d, "分かった")).?;
    defer dict.freeEntries(alloc, m.entries);
    defer alloc.free(m.reason.?);
    try testz.expectEqualStr(m.reason.?, "past");
    try testz.expectEqual(m.entries.len, 1);
    try testz.expectEqualStr(m.entries[0].term, "分かる");
}

// ─── dict: chained deinflection ─────────────────────────────────────────
//
// These exercise `tryDeinflectAtDepth`'s multi-step search -- forms the
// old single-step `lookup` could never reach no matter how the rule
// table was widened, since it only ever tried one rule per candidate.

pub fn dictLookupChainsProgressiveThroughTeFormTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var d = try dict.openMemory(alloc, &.{lookup_dict_json}, null);
    defer d.deinit();
    // 食べている ("is eating") -- the progressive rule strips "ている"
    // down to the te-form "食べて", which isn't itself a headword
    // (`rules_out = &.{}`); the existing te-form rule then reduces that
    // to "食べる". Two chained rule applications, neither of which
    // resolves anything alone.
    const m = (try dict.lookup(alloc, &d, "食べている")).?;
    defer dict.freeEntries(alloc, m.entries);
    defer alloc.free(m.reason.?);
    try testz.expectEqualStr("食べている"[0..m.len], "食べている");
    try testz.expectEqual(m.entries.len, 1);
    try testz.expectEqualStr(m.entries[0].term, "食べる");
    try testz.expectEqualStr(m.reason.?, "te-form, progressive");
}

pub fn dictLookupChainsNegativePastThroughNegativeTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var d = try dict.openMemory(alloc, &.{lookup_dict_json}, null);
    defer d.deinit();
    // 分からなかった -- negative-past of 分かる (godan). The dedicated
    // negative-past rule (`なかった` -> `ない`, non-terminal) collapses
    // this to the plain negative "分からない" one layer in; the existing
    // godan negative rule then reduces that to "分かる", correctly
    // validated against its "v5" tag (not the ichidan "v1" negative rule,
    // which would also match "ない" as a bare suffix but is rejected
    // since 分かる isn't tagged v1). Two chained rule applications.
    const m = (try dict.lookup(alloc, &d, "分からなかった")).?;
    defer dict.freeEntries(alloc, m.entries);
    defer alloc.free(m.reason.?);
    try testz.expectEqualStr("分からなかった"[0..m.len], "分からなかった");
    try testz.expectEqual(m.entries.len, 1);
    try testz.expectEqualStr(m.entries[0].term, "分かる");
}

pub fn dictLookupChainsCausativeThroughNegativeTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var d = try dict.openMemory(alloc, &.{lookup_dict_json}, null);
    defer d.deinit();
    // 食べさせない ("doesn't make [someone] eat") -- the outer negative
    // rule strips "ない" down to the causative form "食べさせる", which
    // isn't itself a headword; the causative rule then reduces that to
    // "食べる", validated against its "v1" tag. Unlike the progressive/
    // negative-past chains above, causative's own `rules_out` is
    // terminal (the real headword's class), not `&.{}` -- it only ever
    // needs an *outer* layer (negative/past/te-form) to strip first
    // because a bare causative form is rarely written alone, not because
    // stripping causative itself leaves something non-terminal.
    const m = (try dict.lookup(alloc, &d, "食べさせない")).?;
    defer dict.freeEntries(alloc, m.entries);
    defer alloc.free(m.reason.?);
    try testz.expectEqualStr("食べさせない"[0..m.len], "食べさせない");
    try testz.expectEqual(m.entries.len, 1);
    try testz.expectEqualStr(m.entries[0].term, "食べる");
    try testz.expectEqualStr(m.reason.?, "causative, negative");
}

pub fn dictLookupResolvesBareCausativeInOneStepTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var d = try dict.openMemory(alloc, &.{lookup_dict_json}, null);
    defer d.deinit();
    // 食べさせる alone (no outer negative/past layer) -- causative is
    // terminal, so this resolves in exactly one rule application, same
    // shape as the polite-past test below.
    const m = (try dict.lookup(alloc, &d, "食べさせる")).?;
    defer dict.freeEntries(alloc, m.entries);
    defer alloc.free(m.reason.?);
    try testz.expectEqual(m.entries.len, 1);
    try testz.expectEqualStr(m.entries[0].term, "食べる");
    try testz.expectEqualStr(m.reason.?, "causative");
}

pub fn dictLookupResolvesPolitePastInOneStepTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var d = try dict.openMemory(alloc, &.{lookup_dict_json}, null);
    defer d.deinit();
    // 食べました -- polite past. Unlike the chains above, this is a
    // single terminal rule application: the conjunctive stem directly
    // matches the "v1" headword's rules, with nothing further to unwind.
    const m = (try dict.lookup(alloc, &d, "食べました")).?;
    defer dict.freeEntries(alloc, m.entries);
    defer alloc.free(m.reason.?);
    try testz.expectEqualStr("食べました"[0..m.len], "食べました");
    try testz.expectEqual(m.entries.len, 1);
    try testz.expectEqualStr(m.entries[0].term, "食べる");
    try testz.expectEqualStr(m.reason.?, "polite past");
}

pub fn dictLookupRejectsADeinflectionWhoseTargetHasTheWrongRuleTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var d = try dict.openMemory(alloc, &.{lookup_dict_json}, null);
    defer d.deinit();
    // "あった" strips to "ある" via the godan -た rule, but the only
    // "ある" entry in this dict is tagged "exp", not "v5" -- so the
    // guess must be rejected rather than treated as a hit.
    const m = try dict.lookup(alloc, &d, "あった");
    try testz.expectTrue(m == null);
}

pub fn dictLookupReturnsNullWhenNothingMatchesTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var d = try dict.openMemory(alloc, &.{lookup_dict_json}, null);
    defer d.deinit();
    const m = try dict.lookup(alloc, &d, "xyz123");
    try testz.expectTrue(m == null);
}

pub fn dictOpenMemoryReadsTitleFromIndexJsonTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var d = try dict.openMemory(alloc, &.{lookup_dict_json},
        \\{"title":"Test Dict","format":3,"revision":"1"}
    );
    defer d.deinit();
    try testz.expectEqualStr(d.title, "Test Dict");
}

// ─── dict: loadFromDir builds then reuses index.sqlite3 ─────────────────

pub fn dictLoadFromDirBuildsThenReusesTheSqliteIndexTest(io: std.Io, alloc: std.mem.Allocator) !void {
    const dir_path = "zig-cache/tmp/dict_load_from_dir_test";
    std.Io.Dir.cwd().deleteTree(io, dir_path) catch {};
    try std.Io.Dir.cwd().createDirPath(io, dir_path);
    defer std.Io.Dir.cwd().deleteTree(io, dir_path) catch {};

    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = dir_path ++ "/term_bank_1.json",
        .data = lookup_dict_json,
    });
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = dir_path ++ "/index.json",
        .data =
        \\{"title":"Test Dict","format":3,"revision":"1"}
        ,
    });

    var d = try dict.loadFromDir(alloc, io, dir_path);
    try testz.expectEqualStr(d.title, "Test Dict");
    const m = (try dict.lookup(alloc, &d, "猫")).?;
    try testz.expectEqualStr(m.entries[0].term, "猫");
    dict.freeEntries(alloc, m.entries);
    d.deinit();

    // A second open must find `index.sqlite3` already built and reuse it
    // rather than re-parsing the term bank -- deleting the term bank
    // first means a spurious rebuild would find nothing and this lookup
    // would fail.
    try std.Io.Dir.cwd().deleteFile(io, dir_path ++ "/term_bank_1.json");
    var d2 = try dict.loadFromDir(alloc, io, dir_path);
    defer d2.deinit();
    const m2 = (try dict.lookup(alloc, &d2, "猫")).?;
    defer dict.freeEntries(alloc, m2.entries);
    try testz.expectEqualStr(m2.entries[0].term, "猫");
}

// ─── dict: incremental Builder (progress panel's backing state) ─────────

pub fn dictBuilderStepsOneFileAtATimeThenOpensReadyTest(io: std.Io, alloc: std.mem.Allocator) !void {
    const dir_path = "zig-cache/tmp/dict_builder_step_test";
    std.Io.Dir.cwd().deleteTree(io, dir_path) catch {};
    try std.Io.Dir.cwd().createDirPath(io, dir_path);
    defer std.Io.Dir.cwd().deleteTree(io, dir_path) catch {};

    // Split across two term bank files -- the whole point of `Builder`
    // is that `ui.zig` can watch progress land one file at a time.
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = dir_path ++ "/term_bank_1.json",
        .data =
        \\[["食べる","たべる","","v1",0,["to eat"],1,""]]
        ,
    });
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = dir_path ++ "/term_bank_2.json",
        .data =
        \\[["猫","ねこ","","n",0,["cat"],2,""]]
        ,
    });

    var load = try dict.openOrBeginBuild(alloc, io, dir_path);
    var b = switch (load) {
        .building => |built| built,
        .ready => return error.TestExpectedABuildToStart,
    };
    errdefer b.deinit();

    try testz.expectEqual(b.totalFiles(), 2);
    try testz.expectFalse(b.isDone());
    try testz.expectEqual(b.terms_indexed, 0);

    try b.step();
    try testz.expectEqual(b.file_idx, 1);
    try testz.expectEqual(b.terms_indexed, 1);
    try testz.expectFalse(b.isDone());

    try b.step();
    try testz.expectEqual(b.file_idx, 2);
    try testz.expectEqual(b.terms_indexed, 2);
    try testz.expectTrue(b.isDone());

    var d = try b.finish();
    defer d.deinit();

    const m1 = (try dict.lookup(alloc, &d, "食べる")).?;
    dict.freeEntries(alloc, m1.entries);
    const m2 = (try dict.lookup(alloc, &d, "猫")).?;
    dict.freeEntries(alloc, m2.entries);

    // A dictionary `finish`'d once is a dictionary `isBuilt` from here
    // on -- a second open must not start another build.
    load = try dict.openOrBeginBuild(alloc, io, dir_path);
    switch (load) {
        .ready => |ready| {
            var r = ready;
            r.deinit();
        },
        .building => return error.TestExpectedTheIndexToAlreadyBeBuilt,
    }
}
