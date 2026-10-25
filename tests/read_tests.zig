// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: GPL-3.0-or-later

const std = @import("std");
const testz = @import("testz");

// gw-read is an executable (no importable module), but its pure pieces
// are gathered into the `read_support` module (see build.zig) precisely
// so they can be exercised here.
const zoom = @import("read_support").zoom;
const cache = @import("read_support").cache;
const state = @import("read_support").state;
const rconfig = @import("read_support").config;
const ractions = @import("read_support").actions;
const mokuro = @import("read_support").mokuro;
const place = @import("read_support").place;
const anki = @import("read_support").anki;

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
    // Not given, so the default -- and a file without the key reads the same.
    try testz.expectEqualStr(mark.layout, "auto");
}

pub fn stateRoundTripsTheOcrLayoutTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var store: state.Store = .init(alloc);
    defer store.deinit();
    try store.record("/books/vol2.cbz", .{ .page = 1, .mode = "fit_screen", .direction = "rtl", .layout = "vertical" });

    const json = try state.serialize(alloc, &store);
    defer alloc.free(json);
    var back = state.parse(alloc, json);
    defer back.deinit();
    try testz.expectEqualStr(back.get("/books/vol2.cbz").?.layout, "vertical");

    var old = state.parse(alloc,
        \\{ "/books/old.cbz": { "page": 4, "mode": "fit_screen", "direction": "rtl" } }
    );
    defer old.deinit();
    try testz.expectEqualStr(old.get("/books/old.cbz").?.layout, "auto");
}

pub fn configReadsOcrLayoutKeysTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var result = rconfig.load(alloc,
        \\config = {
        \\  ocr_layout = "vertical",
        \\  ocr_dialog_rows = 500,
        \\  ocr_dialog_placement = "bubble",
        \\}
    );
    defer result.deinit(alloc);
    try testz.expectTrue(result.err == null);
    try testz.expectTrue(result.config.ocr_layout == .vertical);
    try testz.expectTrue(result.config.ocr_dialog_placement == .bubble);
    try testz.expectEqual(result.config.ocr_dialog_rows, rconfig.ocr_dialog_rows_max);
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

/// `theme` is read in the same Lua run as everything else (review C5).
pub fn configReadsThemeInSameRunTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var result = rconfig.load(alloc, "config = { theme = { base = \"nord\" } }");
    defer result.deinit(alloc);
    const t = result.config.theme orelse return error.TestExpectedTheme;
    try testz.expectEqualStr(t.parsed.name.?, "config");

    var none = rconfig.load(alloc, "config = { mode = \"fit\" }");
    defer none.deinit(alloc);
    try testz.expectTrue(none.config.theme == null);
}

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

pub fn configReadsFrequencyDictionarySettingsTest(_: std.Io, alloc: std.mem.Allocator) !void {
    // Default: no frequency list, and rank order for when one arrives --
    // lower is more common, which is how every popular Japanese frequency
    // list is numbered.
    const defaults: rconfig.ReadConfig = .{};
    try testz.expectEqualStr(defaults.frequency_dictionary, "");
    try testz.expectTrue(defaults.frequency_order == .rank);

    var result = rconfig.load(alloc,
        \\config = {
        \\  frequency_dictionary = "/dicts/jpdb",
        \\  frequency_order = "count",
        \\}
    );
    defer result.deinit(alloc);
    try testz.expectTrue(result.err == null);
    try testz.expectEqualStr(result.config.frequency_dictionary, "/dicts/jpdb");
    try testz.expectTrue(result.config.frequency_order == .count);
}

pub fn configIgnoresAnUnknownFrequencyOrderTest(_: std.Io, alloc: std.mem.Allocator) !void {
    // Getting the direction wrong inverts every ranking, so a spelling
    // that isn't one of the two keeps the default rather than being
    // guessed at.
    var result = rconfig.load(alloc,
        \\config = { frequency_order = "descending" }
    );
    defer result.deinit(alloc);
    try testz.expectTrue(result.config.frequency_order == .rank);
}

pub fn configOwnsTheDictionaryPathAndFreesItTest(_: std.Io, alloc: std.mem.Allocator) !void {
    // The leak gw-read reported on exit: the duped path was never freed.
    // `deinit` on the result now frees it; the testing allocator fails
    // the test if anything is left.
    var result = rconfig.load(alloc,
        \\config = { dictionary = "/dicts/jitendex", ai_model = "gpt-5-mini" }
    );
    defer result.deinit(alloc);
    try testz.expectEqualStr(result.config.dictionary, "/dicts/jitendex");
    try testz.expectEqualStr(result.config.ai_model, "gpt-5-mini");
}

pub fn configTakeConfigHandsOwnershipOutTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var result = rconfig.load(alloc,
        \\config = { dictionary = "/dicts/jitendex" }
    );
    var conf = result.takeConfig();
    // Nothing left for the result to free twice.
    result.deinit(alloc);
    defer conf.deinit(alloc);
    try testz.expectEqualStr(conf.dictionary, "/dicts/jitendex");
}

pub fn configReadsOcrTextScaleTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var result = rconfig.load(alloc,
        \\config = { ocr_text_scale = "2x" }
    );
    defer result.deinit(alloc);
    try testz.expectTrue(result.config.ocr_text_scale == .x2);
}

pub fn configAiDefaultsAreOffAndCautiousTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var result = rconfig.load(alloc, "");
    defer result.deinit(alloc);
    const c = result.config;
    try testz.expectFalse(c.ai_lookup);
    try testz.expectTrue(c.ai_provider == .openai);
    try testz.expectEqualStr(c.aiModel(), "gpt-5");
    try testz.expectEqualStr(c.aiEndpoint(), "https://api.openai.com/v1/responses");
    try testz.expectEqualStr(c.aiApiKeyEnv(), "OPENAI_API_KEY");
    try testz.expectTrue(c.ai_include_neighbor_dialog);
    try testz.expectFalse(c.ai_include_book_info);
    try testz.expectTrue(c.ai_confirm_before_send);
    try testz.expectTrue(c.ai_cache);
}

pub fn configReadsAiSettingsTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var result = rconfig.load(alloc,
        \\config = {
        \\  ai_lookup = true,
        \\  ai_provider = "ollama",
        \\  ai_prompt = "N3 learner, brief.",
        \\  ai_include_neighbor_dialog = false,
        \\  ai_confirm_before_send = false,
        \\}
    );
    defer result.deinit(alloc);
    const c = result.config;
    try testz.expectTrue(c.ai_lookup);
    try testz.expectTrue(c.ai_provider == .ollama);
    // No model/endpoint set: the provider's own defaults.
    try testz.expectEqualStr(c.aiModel(), "qwen2.5");
    try testz.expectEqualStr(c.aiEndpoint(), "http://localhost:11434/api/chat");
    try testz.expectEqualStr(c.ai_prompt, "N3 learner, brief.");
    try testz.expectFalse(c.ai_include_neighbor_dialog);
    try testz.expectFalse(c.ai_confirm_before_send);
}

pub fn configClaudeProvidersDefaultToOpus55Test(_: std.Io, alloc: std.mem.Allocator) !void {
    var api = rconfig.load(alloc,
        \\config = { ai_provider = "anthropic" }
    );
    defer api.deinit(alloc);
    try testz.expectEqualStr(api.config.aiModel(), "claude-opus-5-5");
    try testz.expectEqualStr(api.config.aiEndpoint(), "https://api.anthropic.com/v1/messages");
    try testz.expectEqualStr(api.config.aiApiKeyEnv(), "ANTHROPIC_API_KEY");

    var cli = rconfig.load(alloc,
        \\config = { ai_provider = "claude_code" }
    );
    defer cli.deinit(alloc);
    try testz.expectEqualStr(cli.config.aiModel(), "claude-opus-5-5");
    try testz.expectEqualStr(cli.config.aiEndpoint(), "claude");
    // The CLI brings its own login: no key to look for.
    try testz.expectEqualStr(cli.config.aiApiKeyEnv(), "");
    try testz.expectFalse(cli.config.ai_provider.needsKey());
}

pub fn configIgnoresAnUnknownAiProviderTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var result = rconfig.load(alloc,
        \\config = { ai_provider = "carrier-pigeon" }
    );
    defer result.deinit(alloc);
    try testz.expectTrue(result.config.ai_provider == .openai);
}

pub fn directionParsesAndRoundTripsThroughItsNameTest(_: std.Io, _: std.mem.Allocator) !void {
    // state.zig stores the name, so the pair has to be inverse.
    try testz.expectTrue(rconfig.Direction.parse(rconfig.Direction.rtl.name()).? == .rtl);
    try testz.expectTrue(rconfig.Direction.parse(rconfig.Direction.ltr.name()).? == .ltr);
    try testz.expectTrue(rconfig.Direction.parse("sideways") == null);
}

// ─── mokuro: joining and wrapping ───────────────────────────────────────

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

// ─── mokuro: byte spans back to wrapped cells ───────────────────────────
//
// `charEnd` and `spanCells` are what turn a selection's inclusive end
// into a byte range and a lookup hit's byte range back into a highlight.

pub fn mokuroCharEndSkipsAWholeCodepointTest(_: std.Io, _: std.mem.Allocator) !void {
    const text = "猫a";
    try testz.expectEqual(mokuro.charEnd(text, 0), 3);
    try testz.expectEqual(mokuro.charEnd(text, 3), 4);
    try testz.expectEqual(mokuro.charEnd(text, 4), 4);
}

pub fn mokuroSpanCellsCoversTheLastWideCharacterTest(_: std.Io, alloc: std.mem.Allocator) !void {
    const joined = "面白いね";
    const rows = try mokuro.wrap(alloc, joined, 100);
    defer alloc.free(rows);
    // 白い: bytes 3..9, columns 2..5 -- the last column is い's right half.
    const span = mokuro.spanCells(joined, rows, 3, 9).?;
    try testz.expectEqual(span.first.row, 0);
    try testz.expectEqual(span.first.col, 2);
    try testz.expectEqual(span.last.row, 0);
    try testz.expectEqual(span.last.col, 5);
}

pub fn mokuroSpanCellsCrossesAWrapTest(_: std.Io, alloc: std.mem.Allocator) !void {
    // Two wide characters per row: 面白 / いね.
    const joined = "面白いね";
    const rows = try mokuro.wrap(alloc, joined, 4);
    defer alloc.free(rows);
    try testz.expectEqual(rows.len, 2);
    const span = mokuro.spanCells(joined, rows, 3, 9).?;
    try testz.expectEqual(span.first.row, 0);
    try testz.expectEqual(span.first.col, 2);
    try testz.expectEqual(span.last.row, 1);
    try testz.expectEqual(span.last.col, 1);
}

pub fn mokuroSpanCellsRejectsAnEmptySpanTest(_: std.Io, alloc: std.mem.Allocator) !void {
    const joined = "猫";
    const rows = try mokuro.wrap(alloc, joined, 10);
    defer alloc.free(rows);
    try testz.expectTrue(mokuro.spanCells(joined, rows, 0, 0) == null);
}

// ─── place: where the dialog and side panel go ──────────────────────────

pub fn placeMarginsAroundAFittedPageTest(_: std.Io, _: std.mem.Allocator) !void {
    // A 100-column window, the page 40 wide starting at column 30.
    const m = place.margins(.{ .cols = 100, .rows = 30 }, 30, 40);
    try testz.expectEqual(m.left, 30);
    try testz.expectEqual(m.right, 30);
    try testz.expectEqual(m.right_start, 70);
    // A zoomed page panned past both edges leaves none.
    const none = place.margins(.{ .cols = 100, .rows = 30 }, -50, 300);
    try testz.expectEqual(none.left, 0);
    try testz.expectEqual(none.right, 0);
}

pub fn placeMarginOrderStartsOnTheBubblesSideTest(_: std.Io, _: std.mem.Allocator) !void {
    // Page at 30..70; a bubble at 55..65 is right of the page's middle.
    const right = place.marginOrder(30, 40, .{ .row = 5, .col = 55, .rows = 4, .cols = 10 });
    try testz.expectTrue(right[0] == .right and right[1] == .left);
    const left = place.marginOrder(30, 40, .{ .row = 5, .col = 32, .rows = 4, .cols = 10 });
    try testz.expectTrue(left[0] == .left and left[1] == .right);
}

pub fn placeInMarginCentresAndLevelsWithTheBubbleTest(_: std.Io, _: std.mem.Allocator) !void {
    const view: place.View = .{ .cols = 100, .rows = 30 };
    const m = place.margins(view, 30, 40);
    // 10 wide in a 30-wide right margin: centred, 10 in from 70.
    const spot = place.inMargin(m, .right, view, 6, 8, 10).?;
    try testz.expectEqual(spot.col, 80);
    try testz.expectEqual(spot.row, 6);
    // A bubble near the bottom pulls the box up to stay on screen.
    try testz.expectEqual(place.inMargin(m, .left, view, 28, 8, 10).?.row, 22);
    // Too wide, or taller than the window: doesn't fit.
    try testz.expectTrue(place.inMargin(m, .left, view, 0, 8, 31) == null);
    try testz.expectTrue(place.inMargin(m, .left, view, 0, 31, 10) == null);
}

pub fn placeNearBubbleGoesBelowThenAboveTest(_: std.Io, _: std.mem.Allocator) !void {
    const view: place.View = .{ .cols = 80, .rows = 30 };
    const below = place.nearBubble(view, .{ .row = 2, .col = 10, .rows = 5, .cols = 8 }, 6, 20);
    try testz.expectEqual(below.row, 7);
    try testz.expectEqual(below.col, 10);
    const above = place.nearBubble(view, .{ .row = 20, .col = 70, .rows = 8, .cols = 8 }, 6, 20);
    try testz.expectEqual(above.row, 14);
    try testz.expectEqual(above.col, 60);
}

pub fn placeBesidePrefersTheRightThenTheLeftTest(_: std.Io, _: std.mem.Allocator) !void {
    const view: place.View = .{ .cols = 100, .rows = 30 };
    // A 10-wide dialog at column 40: 50 free to its right.
    const right = place.beside(view, .{ .row = 4, .col = 40, .rows = 20 }, 10, 12, 30).?;
    try testz.expectEqual(right.col, 50);
    try testz.expectEqual(right.row, 4);
    try testz.expectEqual(right.rows, 12);
    // In the right margin: no room right, so it goes left.
    const left = place.beside(view, .{ .row = 4, .col = 85, .rows = 20 }, 10, 12, 30).?;
    try testz.expectEqual(left.col, 55);
    // Taller than what's left below its top: pulled up, then cut to fit.
    const tall = place.beside(view, .{ .row = 25, .col = 40, .rows = 4 }, 10, 40, 30).?;
    try testz.expectEqual(tall.row, 0);
    try testz.expectEqual(tall.rows, 30);
    // Neither side has the width.
    try testz.expectTrue(place.beside(view, .{ .row = 0, .col = 20, .rows = 4 }, 60, 10, 30) == null);
}

pub fn mokuroLayoutFollowsTheBlockOnlyWhenAutoTest(_: std.Io, _: std.mem.Allocator) !void {
    const vertical_block: mokuro.Block = .{ .vertical = true };
    const horizontal_block: mokuro.Block = .{ .vertical = false };
    try testz.expectTrue(mokuro.Layout.auto.isVertical(&vertical_block));
    try testz.expectFalse(mokuro.Layout.auto.isVertical(&horizontal_block));
    try testz.expectTrue(mokuro.Layout.vertical.isVertical(&horizontal_block));
    try testz.expectFalse(mokuro.Layout.horizontal.isVertical(&vertical_block));
    try testz.expectTrue(mokuro.Layout.auto.next() == .vertical);
    try testz.expectTrue(mokuro.Layout.horizontal.next() == .auto);
}

// ─── config: anki ───────────────────────────────────────────────────────

pub fn configAnkiDefaultsToJidoujishoLayoutTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var result = rconfig.load(alloc, "");
    defer result.deinit(alloc);
    try testz.expectTrue(result.config.anki_cards);
    try testz.expectEqualStr(result.config.anki_model, "jidoujisho Kinomoto");
    try testz.expectEqual(result.config.anki_fields.len, anki.default_fields.len);
}

pub fn configAnkiFieldsMapsAndSortsBySourceTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var result = rconfig.load(alloc,
        \\config = {
        \\  anki_deck = "NihingoMine",
        \\  anki_sync_after_add = true,
        \\  anki_image_quality = 500,
        \\  anki_fields = {
        \\    Picture = "image",
        \\    Word = "term",
        \\    Bogus = "nonsense",
        \\    Dropped = false,
        \\    Gloss = "meaning",
        \\  },
        \\}
    );
    defer result.deinit(alloc);
    const c = result.config;
    try testz.expectEqualStr(c.anki_deck, "NihingoMine");
    try testz.expectTrue(c.anki_sync_after_add);
    try testz.expectEqual(c.anki_image_quality, 100);
    // `Bogus` and `Dropped` are skipped; the rest in `Source` order.
    try testz.expectEqual(c.anki_fields.len, 3);
    try testz.expectEqualStr(c.anki_fields[0].field, "Word");
    try testz.expectEqualStr(c.anki_fields[1].field, "Gloss");
    try testz.expectEqualStr(c.anki_fields[2].field, "Picture");
}

// ─── Keys ────────────────────────────────────────────────────────────────

/// The modes' precedence: the AI states fall through to the page, a card
/// takes every key.
pub fn readKeymapModesTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var km = try ractions.Keymaps.initDefaults(alloc, ractions.defaults);
    defer km.deinit(alloc);
    try testz.expectEqual(km.lookup(.page, "q", .{}).?, ractions.Action.quit);
    try testz.expectEqual(km.lookup(.page, "g", .{ .shift = true }).?, ractions.Action.lastPage);
    try testz.expectEqual(km.lookupText(.page, "?").?, ractions.Action.toggleHelp);
    try testz.expectEqual(km.lookupText(.page, "+").?, ractions.Action.zoomIn);
    // Confirm binds `a` and Escape itself, and passes `f` to the page.
    try testz.expectEqual(km.lookup(.confirm, "a", .{}).?, ractions.Action.accept);
    try testz.expectEqual(km.lookup(.confirm, "f", .{}).?, ractions.Action.fitScreen);
    try testz.expectEqual(km.lookup(.busy, "escape", .{}).?, ractions.Action.cancel);
    // A card in progress: no page turn gets through.
    try testz.expectTrue(km.lookup(.card, "space", .{}) == null);
    try testz.expectEqual(km.lookup(.card, "h", .{}).?, ractions.Action.nudgeLeft);
}

pub fn readConfigKeysOverDefaultsTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var result = rconfig.load(alloc,
        \\config = { keys = {
        \\  page = { ["n"] = "nextPage", ["space"] = false, ["x"] = "noSuchAction" },
        \\  card = { ["y"] = "accept" },
        \\} }
    );
    defer result.deinit(alloc);
    try testz.expectEqual(result.config.keys.len, 3);

    var km = try ractions.Keymaps.initDefaults(alloc, ractions.defaults);
    defer km.deinit(alloc);
    try km.apply(alloc, result.config.keys);
    try testz.expectEqual(km.lookup(.page, "n", .{}).?, ractions.Action.nextPage);
    try testz.expectEqual(km.lookup(.page, "space", .{}).?, ractions.Action.none);
    try testz.expectEqual(km.lookup(.card, "y", .{}).?, ractions.Action.accept);
}
