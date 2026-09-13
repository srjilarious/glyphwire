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

pub fn directionParsesAndRoundTripsThroughItsNameTest(_: std.Io, _: std.mem.Allocator) !void {
    // state.zig stores the name, so the pair has to be inverse.
    try testz.expectTrue(rconfig.Direction.parse(rconfig.Direction.rtl.name()).? == .rtl);
    try testz.expectTrue(rconfig.Direction.parse(rconfig.Direction.ltr.name()).? == .ltr);
    try testz.expectTrue(rconfig.Direction.parse("sideways") == null);
}
