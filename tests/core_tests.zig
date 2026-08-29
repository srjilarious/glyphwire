const std = @import("std");
const testz = @import("testz");
const glyphwire = @import("glyphwire");

pub fn writeTextAdvancesCursorTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var layer = try glyphwire.Layer.init(alloc, 80, 24, 0);
    defer layer.deinit();

    try layer.writeText("hello", glyphwire.default_style.fg, glyphwire.default_style.bg);

    try testz.expectEqualStr("h", layer.cell(0, 0).grapheme());
    try testz.expectEqualStr("e", layer.cell(0, 1).grapheme());
    try testz.expectEqualStr("l", layer.cell(0, 2).grapheme());
    try testz.expectEqualStr("l", layer.cell(0, 3).grapheme());
    try testz.expectEqualStr("o", layer.cell(0, 4).grapheme());

    try testz.expectEqual(layer.cursor.row, 0);
    try testz.expectEqual(layer.cursor.col, 5);
}

pub fn writeTextAppliesStyleTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var layer = try glyphwire.Layer.init(alloc, 80, 24, 0);
    defer layer.deinit();

    const style: glyphwire.Style = .{
        .fg = .{ .r = 10, .g = 20, .b = 30 },
        .bg = .{ .color = .{ .r = 1, .g = 2, .b = 3 } },
    };
    try layer.writeText("h", style.fg, style.bg);

    const c = layer.cell(0, 0);
    try testz.expectEqual(c.style.fg.r, 10);
    try testz.expectEqual(c.style.fg.g, 20);
    try testz.expectEqual(c.style.fg.b, 30);
    switch (c.style.bg) {
        .color => |bg| {
            try testz.expectEqual(bg.r, 1);
            try testz.expectEqual(bg.g, 2);
            try testz.expectEqual(bg.b, 3);
        },
        .image, .icon => return error.TestUnexpectedResult,
    }
}

pub fn writeTextNullBgLeavesExistingBackgroundUntouchedTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var layer = try glyphwire.Layer.init(alloc, 80, 24, 0);
    defer layer.deinit();

    // As `drawBox`'s fill would leave a cell -- `write_text`'s
    // `transparent_bg: true` (a `null` `bg` at this layer) has to survive
    // it, not reset it to `default_style.bg` the way omitting `bg`
    // otherwise does (`writeTextAppliesStyleTest`'s sibling case).
    layer.drawIcon(9, 0, 0, .{});

    try layer.writeText("h", .{ .r = 10, .g = 20, .b = 30 }, null);

    const c = layer.cell(0, 0);
    try testz.expectEqualStr("h", c.grapheme());
    try testz.expectEqual(c.style.fg.r, 10);
    try testz.expectEqual(c.style.bg.icon.handle, 9);
}

pub fn writeTextWrapsAtLayerEdgeTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var layer = try glyphwire.Layer.init(alloc, 3, 2, 0);
    defer layer.deinit();

    try layer.writeText("hello", glyphwire.default_style.fg, glyphwire.default_style.bg);

    try testz.expectEqualStr("h", layer.cell(0, 0).grapheme());
    try testz.expectEqualStr("e", layer.cell(0, 1).grapheme());
    try testz.expectEqualStr("l", layer.cell(0, 2).grapheme());
    try testz.expectEqualStr("l", layer.cell(1, 0).grapheme());
    try testz.expectEqualStr("o", layer.cell(1, 1).grapheme());

    try testz.expectEqual(layer.cursor.row, 1);
    try testz.expectEqual(layer.cursor.col, 2);
}

pub fn getSetCursorPropertyTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var layer = try glyphwire.Layer.init(alloc, 80, 24, 0);
    defer layer.deinit();

    try layer.writeText("hello", glyphwire.default_style.fg, glyphwire.default_style.bg);

    const before = layer.getProperty(.cursor);
    try testz.expectEqual(before.cursor.row, 0);
    try testz.expectEqual(before.cursor.col, 5);

    layer.setProperty(.{ .cursor = .{ .row = 3, .col = 7 } });

    const after = layer.getProperty(.cursor);
    try testz.expectEqual(after.cursor.row, 3);
    try testz.expectEqual(after.cursor.col, 7);
}

/// The regression: an explicit set_property(cursor) naming a row at or
/// past the bottom used to just take that row literally (no scrolling),
/// unlike write_text's cursor advancing past the edge (which scrolls via
/// putAtCursor). That mismatch is what let glyphwire-ls's icons silently
/// stop landing once enough rows had scrolled -- see Layer.resolveRow.
pub fn setCursorPastBottomScrollsLikeWritingPastItWouldTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var layer = try glyphwire.Layer.init(alloc, 5, 3, 10);
    defer layer.deinit();

    try layer.writeText("a", glyphwire.default_style.fg, glyphwire.default_style.bg);
    try testz.expectEqual(layer.cursor.row, 0);

    // Row 3 is one past the last valid row (0..2) -- should scroll once
    // and land on the new bottom row (2), the same place writing a 4th
    // line's worth of text would land.
    layer.setProperty(.{ .cursor = .{ .row = 3, .col = 0 } });

    try testz.expectEqual(layer.cursor.row, 2);
    try testz.expectEqual(layer.cursor.col, 0);
    // The scroll actually happened (not just clamped in place): row 0's
    // "a" is now history, not the live top row.
    try testz.expectEqual(layer.history_len, 1);
}

/// A row far past the bottom still resolves sanely (scrolls until it
/// fits, landing on the last row) rather than hanging -- the loop in
/// resolveRow is capped at `capacity()` iterations specifically so this
/// can't spin forever for a hostile/buggy client-supplied row.
pub fn setCursorFarPastBottomStillTerminatesTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var layer = try glyphwire.Layer.init(alloc, 5, 3, 5);
    defer layer.deinit();

    layer.setProperty(.{ .cursor = .{ .row = 1_000_000, .col = 1 } });

    try testz.expectEqual(layer.cursor.row, 2);
    try testz.expectEqual(layer.cursor.col, 1);
}

pub fn contextCreatesRootLayerAtSizeTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 80, 24, 0);
    defer ctx.deinit();

    try testz.expectEqual(ctx.root.width, 80);
    try testz.expectEqual(ctx.root.height, 24);
    try testz.expectEqual(ctx.root.cursor.row, 0);
    try testz.expectEqual(ctx.root.cursor.col, 0);
}

pub fn scrollingRetainsScrolledOffRowsAsHistoryTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    // width=3, height=2, scrollback=2 (capacity=4 rows). Writing 10
    // characters wraps across 4 logical rows, forcing the viewport to
    // scroll twice.
    var layer = try glyphwire.Layer.init(alloc, 3, 2, 2);
    defer layer.deinit();

    try layer.writeText("abcdefghij", glyphwire.default_style.fg, glyphwire.default_style.bg);

    // Viewport now shows the last two rows written.
    try testz.expectEqualStr("g", layer.cell(0, 0).grapheme());
    try testz.expectEqualStr("h", layer.cell(0, 1).grapheme());
    try testz.expectEqualStr("i", layer.cell(0, 2).grapheme());
    try testz.expectEqualStr("j", layer.cell(1, 0).grapheme());
    try testz.expectEqual(layer.cell(1, 1).grapheme().len, 0);
    try testz.expectEqual(layer.cell(1, 2).grapheme().len, 0);
    try testz.expectEqual(layer.cursor.row, 1);
    try testz.expectEqual(layer.cursor.col, 1);

    // The two rows that scrolled off are retained, most recent first.
    const most_recent = layer.scrollbackRow(0).?;
    try testz.expectEqualStr("d", most_recent[0].grapheme());
    try testz.expectEqualStr("e", most_recent[1].grapheme());
    try testz.expectEqualStr("f", most_recent[2].grapheme());

    const older = layer.scrollbackRow(1).?;
    try testz.expectEqualStr("a", older[0].grapheme());
    try testz.expectEqualStr("b", older[1].grapheme());
    try testz.expectEqualStr("c", older[2].grapheme());

    try testz.expectTrue(layer.scrollbackRow(2) == null);
}

/// Regression test for glyphwire-host: `cat`ing anything longer than the
/// window used to blast straight past with no way to scroll back, because
/// nothing read the scrollback the ring buffer was already retaining.
/// `viewRow` is the pure row-mapping logic the fix (mouse wheel ->
/// `App.scroll_offset` -> `renderLayer`) is built on -- same layer/write
/// as `scrollingRetainsScrolledOffRowsAsHistoryTest` above.
pub fn viewRowAtZeroOffsetMatchesLiveViewportTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var layer = try glyphwire.Layer.init(alloc, 3, 2, 2);
    defer layer.deinit();
    try layer.writeText("abcdefghij", glyphwire.default_style.fg, glyphwire.default_style.bg);

    const row0 = layer.viewRow(0, 0);
    try testz.expectEqualStr("g", row0[0].grapheme());
    try testz.expectEqualStr("h", row0[1].grapheme());
    try testz.expectEqualStr("i", row0[2].grapheme());

    const row1 = layer.viewRow(0, 1);
    try testz.expectEqualStr("j", row1[0].grapheme());
}

pub fn viewRowScrolledBackShowsHistoryAboveLiveRowsTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var layer = try glyphwire.Layer.init(alloc, 3, 2, 2);
    defer layer.deinit();
    try layer.writeText("abcdefghij", glyphwire.default_style.fg, glyphwire.default_style.bg);

    // Scrolled back 1 row: top row reveals the most recently scrolled-off
    // history row ("def"), bottom row shows the live top row ("ghi") --
    // the live bottom row ("j") has scrolled below the visible window.
    const row0 = layer.viewRow(1, 0);
    try testz.expectEqualStr("d", row0[0].grapheme());
    try testz.expectEqualStr("e", row0[1].grapheme());
    try testz.expectEqualStr("f", row0[2].grapheme());

    const row1 = layer.viewRow(1, 1);
    try testz.expectEqualStr("g", row1[0].grapheme());
    try testz.expectEqualStr("h", row1[1].grapheme());
    try testz.expectEqualStr("i", row1[2].grapheme());
}

pub fn viewRowScrolledToTopOfHistoryShowsOldestRowsTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var layer = try glyphwire.Layer.init(alloc, 3, 2, 2);
    defer layer.deinit();
    try layer.writeText("abcdefghij", glyphwire.default_style.fg, glyphwire.default_style.bg);

    // Scrolled back the full retained history (history_len == 2): shows
    // the two oldest rows still retained, "abc" then "def".
    const row0 = layer.viewRow(2, 0);
    try testz.expectEqualStr("a", row0[0].grapheme());
    try testz.expectEqualStr("b", row0[1].grapheme());
    try testz.expectEqualStr("c", row0[2].grapheme());

    const row1 = layer.viewRow(2, 1);
    try testz.expectEqualStr("d", row1[0].grapheme());
    try testz.expectEqualStr("e", row1[1].grapheme());
    try testz.expectEqualStr("f", row1[2].grapheme());
}

/// An offset past what's actually retained clamps to `history_len` rather
/// than panicking -- guards against a stale `App.scroll_offset` (e.g. if
/// scrollback were ever trimmed) reading past `scrollbackRow`'s range.
pub fn viewRowClampsOffsetPastRetainedHistoryTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var layer = try glyphwire.Layer.init(alloc, 3, 2, 2);
    defer layer.deinit();
    try layer.writeText("abcdefghij", glyphwire.default_style.fg, glyphwire.default_style.bg);

    const row0 = layer.viewRow(100, 0);
    try testz.expectEqualStr("a", row0[0].grapheme());

    const row1 = layer.viewRow(100, 1);
    try testz.expectEqualStr("d", row1[0].grapheme());
}

/// `scrollView` moves `view_scroll` and clamps to `0..history_len` --
/// the primitive glyphwire-host's wheel/scrollbar and glyphwire-shell's
/// browse cursor all drive (via `Server.reportScroll` / the `scroll_view`
/// wire method).
pub fn scrollViewClampsToRetainedHistoryTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var layer = try glyphwire.Layer.init(alloc, 3, 2, 4);
    defer layer.deinit();
    try layer.writeText("abcdefghij", glyphwire.default_style.fg, glyphwire.default_style.bg);
    // 10 chars over a 3-wide, 2-tall viewport => 4 rows written, 2 scrolled
    // off, so history_len == 2.
    try testz.expectEqual(layer.history_len, 2);

    try testz.expectEqual(layer.scrollView(1, null), 1);
    try testz.expectEqual(layer.view_scroll, 1);
    // Absolute past history clamps down; delta past 0 clamps up.
    try testz.expectEqual(layer.scrollView(99, null), 2);
    try testz.expectEqual(layer.scrollView(null, -99), 0);
    // Pure query (both null) leaves it unchanged.
    try testz.expectEqual(layer.scrollView(null, null), 0);
}

/// While the view is scrolled back, a fresh scroll (new output) bumps
/// `view_scroll` in step so the rows the user is looking at stay put on
/// screen instead of sliding down toward the tail -- terminal-style. Caps
/// at `history_len`, so once scrollback is full the oldest viewed row is
/// evicted and the view drifts.
pub fn scrollOneKeepsScrolledBackViewPinnedToContentTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var layer = try glyphwire.Layer.init(alloc, 3, 2, 10);
    defer layer.deinit();
    try layer.writeText("abcdefghi", glyphwire.default_style.fg, glyphwire.default_style.bg); // 3 rows, history_len 1

    // Scroll back to the oldest retained row ("abc" at viewport row 0).
    _ = layer.scrollView(1, null);
    try testz.expectEqualStr("a", layer.viewRow(layer.view_scroll, 0)[0].grapheme());

    // A row of new output scrolls the live tail; view_scroll follows so
    // "abc" is still what the top row shows.
    try layer.writeText("jkl", glyphwire.default_style.fg, glyphwire.default_style.bg);
    try testz.expectEqual(layer.view_scroll, 2);
    try testz.expectEqualStr("a", layer.viewRow(layer.view_scroll, 0)[0].grapheme());
}

/// A view scrolled deeper than the post-resize `history_len` is clamped
/// back into range rather than left dangling past `scrollbackRow`'s
/// bounds.
pub fn layerResizeClampsScrollViewIntoNewHistoryTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var layer = try glyphwire.Layer.init(alloc, 3, 4, 10);
    defer layer.deinit();
    // 6 rows of content over a 4-tall viewport => history_len 2.
    try layer.writeText("aaabbbcccdddeeefff", glyphwire.default_style.fg, glyphwire.default_style.bg);
    _ = layer.scrollView(2, null);
    try testz.expectEqual(layer.view_scroll, 2);

    // Grow the viewport tall enough to pull all history back down:
    // history_len goes to 0, so view_scroll must clamp to 0.
    try layer.resize(3, 8);
    try testz.expectEqual(layer.history_len, 0);
    try testz.expectEqual(layer.view_scroll, 0);
}

/// A client that emits one `set_property(cursor)` + `write_text` pair per
/// line (glyphwire-shell's `writeCapturedText` did this before
/// `Layer.writeText` grew its own `\n` handling; other clients still
/// drive explicit cursor moves this way) must not hand `resolveRow` an
/// ever-growing absolute row count with no ceiling: once the grid has
/// scrolled once, naming a row two past the bottom, then three, and so on
/// makes `resolveRow` -- which scrolls once per row of overshoot a single
/// call names -- trigger more scrolls than the one line each call
/// represents, opening a widening run of blank rows nothing wrote into
/// (exactly what made `cat`ing a longer file show real content
/// interspersed with growing gaps once scrollback made it visible). This
/// drives `Layer` with that call pattern, target row capped at `height`
/// once the grid has scrolled, so every line past the bottom asks for
/// exactly the one scroll it should.
pub fn manyLinesPastBottomCursorCappedAtHeightLeavesNoBlankRowsTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var layer = try glyphwire.Layer.init(alloc, 10, 4, 20);
    defer layer.deinit();

    var row: usize = 0; // the client's locally-tracked "next row"
    var line: usize = 0;
    while (line < 12) : (line += 1) {
        if (line > 0) {
            row = @min(row + 1, layer.height); // the fix
            layer.setProperty(.{ .cursor = .{ .row = row, .col = 0 } });
        }
        var buf: [8]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, "L{d}", .{line}) catch unreachable;
        try layer.writeText(text, glyphwire.default_style.fg, glyphwire.default_style.bg);
    }

    // No blank rows: every visible row has real content.
    var r: usize = 0;
    while (r < layer.height) : (r += 1) {
        try testz.expectTrue(layer.cell(r, 0).grapheme().len > 0);
    }

    // The live viewport shows the last 4 lines written (L8..L11), in
    // order -- not scattered among blank rows.
    try testz.expectEqualStr("L", layer.cell(0, 0).grapheme());
    try testz.expectEqualStr("8", layer.cell(0, 1).grapheme());
    try testz.expectEqualStr("L", layer.cell(1, 0).grapheme());
    try testz.expectEqualStr("9", layer.cell(1, 1).grapheme());
    try testz.expectEqualStr("L", layer.cell(2, 0).grapheme());
    try testz.expectEqualStr("1", layer.cell(2, 1).grapheme());
    try testz.expectEqualStr("0", layer.cell(2, 2).grapheme());
    try testz.expectEqualStr("L", layer.cell(3, 0).grapheme());
    try testz.expectEqualStr("1", layer.cell(3, 1).grapheme());
    try testz.expectEqualStr("1", layer.cell(3, 2).grapheme());
}

pub fn inputStateTracksKeyAndMouseButtonDownSetsTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var input = glyphwire.InputState.init(alloc);
    defer input.deinit();

    try testz.expectTrue(!input.isKeyDown("a"));

    try testz.expectTrue(try input.setKey("a", true));
    try testz.expectTrue(input.isKeyDown("a"));
    // Redundant press-while-down reports no change.
    try testz.expectTrue(!try input.setKey("a", true));

    try testz.expectTrue(try input.setKey("a", false));
    try testz.expectTrue(!input.isKeyDown("a"));
    // Redundant release-while-up reports no change.
    try testz.expectTrue(!try input.setKey("a", false));

    try testz.expectTrue(!input.isMouseButtonDown("left"));
    try testz.expectTrue(try input.setMouseButton("left", true));
    try testz.expectTrue(input.isMouseButtonDown("left"));
}

pub fn scrollingWithNoScrollbackKeepsNoHistoryTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    // A layer with scrollback_rows=0 (e.g. a small popup notification)
    // still scrolls its viewport, it just never retains history.
    var layer = try glyphwire.Layer.init(alloc, 3, 2, 0);
    defer layer.deinit();

    try layer.writeText("abcdefghij", glyphwire.default_style.fg, glyphwire.default_style.bg);

    try testz.expectEqualStr("g", layer.cell(0, 0).grapheme());
    try testz.expectEqualStr("j", layer.cell(1, 0).grapheme());
    try testz.expectTrue(layer.scrollbackRow(0) == null);
}

pub fn layerResizeGrowHeightPullsScrolledOffRowsBackIntoViewportTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    // width=3, height=2, scrollback=4. "abcdefghij" wraps to four rows
    // (abc/def/ghi/j..); the viewport shows the last two, with abc/def
    // retained as history.
    var layer = try glyphwire.Layer.init(alloc, 3, 2, 4);
    defer layer.deinit();
    try layer.writeText("abcdefghij", glyphwire.default_style.fg, glyphwire.default_style.bg);
    try testz.expectEqualStr("g", layer.cell(0, 0).grapheme());
    try testz.expectEqualStr("j", layer.cell(1, 0).grapheme());

    // Growing to height 4 brings both history rows back down into the
    // now-taller viewport, newest still at the bottom.
    try layer.resize(3, 4);
    try testz.expectEqual(layer.height, 4);
    try testz.expectEqualStr("a", layer.cell(0, 0).grapheme());
    try testz.expectEqualStr("d", layer.cell(1, 0).grapheme());
    try testz.expectEqualStr("g", layer.cell(2, 0).grapheme());
    try testz.expectEqualStr("j", layer.cell(3, 0).grapheme());
    // History is now exhausted -- every retained row is back on screen.
    try testz.expectTrue(layer.scrollbackRow(0) == null);
}

pub fn layerResizeGrowHeightBeyondContentBlankPadsAtTopTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    // Only two rows of content and no scrollback: growing the viewport
    // past what history can fill leaves blank rows at the top, content
    // still anchored to the bottom.
    var layer = try glyphwire.Layer.init(alloc, 3, 2, 0);
    defer layer.deinit();
    try layer.writeText("abcdef", glyphwire.default_style.fg, glyphwire.default_style.bg);

    try layer.resize(3, 4);
    try testz.expectEqual(layer.height, 4);
    try testz.expectEqual(layer.cell(0, 0).grapheme().len, 0);
    try testz.expectEqual(layer.cell(1, 0).grapheme().len, 0);
    try testz.expectEqualStr("a", layer.cell(2, 0).grapheme());
    try testz.expectEqualStr("d", layer.cell(3, 0).grapheme());
}

pub fn layerResizeShrinkHeightPushesTopRowsIntoHistoryNonDestructivelyTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    // width=3, height=4, scrollback=4. "abcdefghijkl" exactly fills the
    // four viewport rows (abc/def/ghi/jkl), no history yet.
    var layer = try glyphwire.Layer.init(alloc, 3, 4, 4);
    defer layer.deinit();
    try layer.writeText("abcdefghijkl", glyphwire.default_style.fg, glyphwire.default_style.bg);

    // Shrinking to height 2 keeps the bottom two rows visible and pushes
    // the top two up into history rather than discarding them.
    try layer.resize(3, 2);
    try testz.expectEqual(layer.height, 2);
    try testz.expectEqualStr("g", layer.cell(0, 0).grapheme());
    try testz.expectEqualStr("j", layer.cell(1, 0).grapheme());
    try testz.expectEqualStr("d", layer.scrollbackRow(0).?[0].grapheme());
    try testz.expectEqualStr("a", layer.scrollbackRow(1).?[0].grapheme());
    try testz.expectTrue(layer.scrollbackRow(2) == null);

    // Growing back restores every row into the viewport -- proof the
    // shrink lost nothing.
    try layer.resize(3, 4);
    try testz.expectEqualStr("a", layer.cell(0, 0).grapheme());
    try testz.expectEqualStr("d", layer.cell(1, 0).grapheme());
    try testz.expectEqualStr("g", layer.cell(2, 0).grapheme());
    try testz.expectEqualStr("j", layer.cell(3, 0).grapheme());
}

pub fn layerResizeWidthClipsAndBlankPadsRowsWithoutReflowTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var layer = try glyphwire.Layer.init(alloc, 4, 2, 0);
    defer layer.deinit();
    try layer.writeText("abcdefgh", glyphwire.default_style.fg, glyphwire.default_style.bg);
    try testz.expectEqualStr("d", layer.cell(0, 3).grapheme());
    try testz.expectEqualStr("e", layer.cell(1, 0).grapheme());

    // Wider: each row keeps its cells and gains blank ones on the right
    // (no reflow -- "efgh" does not pull up onto row 0).
    try layer.resize(6, 2);
    try testz.expectEqual(layer.width, 6);
    try testz.expectEqualStr("d", layer.cell(0, 3).grapheme());
    try testz.expectEqual(layer.cell(0, 4).grapheme().len, 0);
    try testz.expectEqualStr("e", layer.cell(1, 0).grapheme());

    // Narrower: each row is clipped on the right.
    try layer.resize(2, 2);
    try testz.expectEqual(layer.width, 2);
    try testz.expectEqualStr("a", layer.cell(0, 0).grapheme());
    try testz.expectEqualStr("b", layer.cell(0, 1).grapheme());
    try testz.expectEqualStr("e", layer.cell(1, 0).grapheme());
}

pub fn layerResizeClampsCursorIntoNewBoundsTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var layer = try glyphwire.Layer.init(alloc, 10, 5, 0);
    defer layer.deinit();
    layer.setProperty(.{ .cursor = .{ .row = 4, .col = 9 } });

    try layer.resize(4, 2);
    try testz.expectEqual(layer.cursor.row, 1);
    try testz.expectEqual(layer.cursor.col, 3);
}

pub fn layerResizeToSameSizeIsANoOpTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var layer = try glyphwire.Layer.init(alloc, 8, 4, 2);
    defer layer.deinit();
    try layer.writeText("hello", glyphwire.default_style.fg, glyphwire.default_style.bg);

    try layer.resize(8, 4);
    try testz.expectEqualStr("h", layer.cell(0, 0).grapheme());
    try testz.expectEqual(layer.cursor.col, 5);
}

pub fn contextResizeResizesRootAndBaseSizeTrackingLayersOnlyTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 20, 10, 0);
    defer ctx.deinit();

    // A layer created with no explicit size tracks the context; one
    // created at an explicit size (a popup) does not.
    const tracking = try ctx.createLayer(null, null, 0);
    const popup = try ctx.createLayer(45, 3, 0);

    try ctx.resize(30, 12);
    try testz.expectEqual(ctx.root.width, 30);
    try testz.expectEqual(ctx.root.height, 12);

    const tracking_layer = ctx.layerPtr(tracking).?;
    try testz.expectEqual(tracking_layer.width, 30);
    try testz.expectEqual(tracking_layer.height, 12);

    const popup_layer = ctx.layerPtr(popup).?;
    try testz.expectEqual(popup_layer.width, 45);
    try testz.expectEqual(popup_layer.height, 3);
}

pub fn insertCellsShiftsRowRightTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var layer = try glyphwire.Layer.init(alloc, 10, 5, 0);
    defer layer.deinit();

    try layer.writeText("hello", glyphwire.default_style.fg, glyphwire.default_style.bg);
    layer.setProperty(.{ .cursor = .{ .row = 0, .col = 1 } });

    layer.insertCells(1);

    try testz.expectEqualStr("h", layer.cell(0, 0).grapheme());
    try testz.expectEqual(layer.cell(0, 1).grapheme().len, 0);
    try testz.expectEqualStr("e", layer.cell(0, 2).grapheme());
    try testz.expectEqualStr("l", layer.cell(0, 3).grapheme());
    try testz.expectEqualStr("l", layer.cell(0, 4).grapheme());
    try testz.expectEqualStr("o", layer.cell(0, 5).grapheme());
    try testz.expectEqual(layer.cell(0, 6).grapheme().len, 0);

    // insertCells doesn't move the cursor -- matches ECMA-48's ICH.
    try testz.expectEqual(layer.cursor.row, 0);
    try testz.expectEqual(layer.cursor.col, 1);
}

pub fn insertCellsDiscardsCellsPastRowEdgeTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var layer = try glyphwire.Layer.init(alloc, 5, 2, 0);
    defer layer.deinit();

    try layer.writeText("abcde", glyphwire.default_style.fg, glyphwire.default_style.bg);
    layer.setProperty(.{ .cursor = .{ .row = 0, .col = 0 } });

    layer.insertCells(2);

    try testz.expectEqual(layer.cell(0, 0).grapheme().len, 0);
    try testz.expectEqual(layer.cell(0, 1).grapheme().len, 0);
    try testz.expectEqualStr("a", layer.cell(0, 2).grapheme());
    try testz.expectEqualStr("b", layer.cell(0, 3).grapheme());
    try testz.expectEqualStr("c", layer.cell(0, 4).grapheme());
    // "d" and "e" were shifted past the row's right edge and discarded.
}

pub fn deleteCellsShiftsRowLeftAndBlanksTailTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var layer = try glyphwire.Layer.init(alloc, 10, 5, 0);
    defer layer.deinit();

    try layer.writeText("hello", glyphwire.default_style.fg, glyphwire.default_style.bg);
    layer.setProperty(.{ .cursor = .{ .row = 0, .col = 1 } });

    layer.deleteCells(1);

    try testz.expectEqualStr("h", layer.cell(0, 0).grapheme());
    try testz.expectEqualStr("l", layer.cell(0, 1).grapheme());
    try testz.expectEqualStr("l", layer.cell(0, 2).grapheme());
    try testz.expectEqualStr("o", layer.cell(0, 3).grapheme());
    try testz.expectEqual(layer.cell(0, 4).grapheme().len, 0);

    // deleteCells doesn't move the cursor -- matches ECMA-48's DCH.
    try testz.expectEqual(layer.cursor.row, 0);
    try testz.expectEqual(layer.cursor.col, 1);
}

pub fn insertAndDeleteCellsAreNoOpsPastRowEdgeTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var layer = try glyphwire.Layer.init(alloc, 5, 2, 0);
    defer layer.deinit();

    try layer.writeText("abcde", glyphwire.default_style.fg, glyphwire.default_style.bg);
    const revision_before = layer.revision;
    // Cursor is now at (0, 5) -- one past the row's last column.

    layer.insertCells(1);
    layer.deleteCells(1);
    layer.insertCells(0);
    layer.deleteCells(0);

    try testz.expectEqualStr("a", layer.cell(0, 0).grapheme());
    try testz.expectEqualStr("e", layer.cell(0, 4).grapheme());
    try testz.expectEqual(layer.revision, revision_before);
}

/// A minimal byte stream `pngDimensions` accepts: the 8-byte PNG signature
/// followed by exactly an IHDR chunk header (4-byte length, "IHDR", then
/// big-endian width/height) -- 24 bytes total, nothing past what
/// `pngDimensions` actually reads. Not a real, decodable PNG (no further
/// chunks, no CRC) -- fine, since the headless core never decodes pixels.
fn fakePngBytes(width: u32, height: u32) [24]u8 {
    var bytes: [24]u8 = undefined;
    @memcpy(bytes[0..8], &[_]u8{ 0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n' });
    std.mem.writeInt(u32, bytes[8..12], 13, .big); // IHDR chunk length, unchecked
    @memcpy(bytes[12..16], "IHDR");
    std.mem.writeInt(u32, bytes[16..20], width, .big);
    std.mem.writeInt(u32, bytes[20..24], height, .big);
    return bytes;
}

pub fn pngDimensionsParsesIhdrTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    _ = alloc;
    const bytes = fakePngBytes(64, 32);
    const info = try glyphwire.pngDimensions(&bytes);
    try testz.expectEqual(info.width, 64);
    try testz.expectEqual(info.height, 32);
}

pub fn pngDimensionsRejectsBadSignatureTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    _ = alloc;
    var bytes = fakePngBytes(64, 32);
    bytes[0] = 0; // corrupt the signature
    try testz.expectError(glyphwire.pngDimensions(&bytes), glyphwire.ImageError.InvalidPng);
}

pub fn contextLoadImageParsesDimensionsTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 80, 24, 0);
    defer ctx.deinit();

    const bytes = fakePngBytes(48, 24);
    const handle = try ctx.loadImage(&bytes);

    const info = ctx.imageInfo(handle).?;
    try testz.expectEqual(info.width, 48);
    try testz.expectEqual(info.height, 24);
    try testz.expectTrue(ctx.imageInfo(handle + 1) == null);
}

pub fn layerDrawImageMarksCoveredCellsWithOffsetsTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var layer = try glyphwire.Layer.init(alloc, 5, 5, 0);
    defer layer.deinit();

    // A 2x2-cell span at 12px cells covers a 24x24px image exactly.
    layer.drawImage(1, 1, 1, 2, 2, 24, 24, 12, 12);

    const c00 = layer.cell(1, 1).style.bg;
    const c01 = layer.cell(1, 2).style.bg;
    const c10 = layer.cell(2, 1).style.bg;
    const c11 = layer.cell(2, 2).style.bg;

    try testz.expectEqual(c00.image.handle, 1);
    try testz.expectEqual(c00.image.offset_x, 0);
    try testz.expectEqual(c00.image.offset_y, 0);
    try testz.expectEqual(c01.image.offset_x, 12);
    try testz.expectEqual(c01.image.offset_y, 0);
    try testz.expectEqual(c10.image.offset_x, 0);
    try testz.expectEqual(c10.image.offset_y, 12);
    try testz.expectEqual(c11.image.offset_x, 12);
    try testz.expectEqual(c11.image.offset_y, 12);

    // Untouched cells outside the span keep the default color background.
    switch (layer.cell(0, 0).style.bg) {
        .color => {},
        .image, .icon => return error.TestUnexpectedResult,
    }
}

pub fn layerDrawImageLeavesCellsBeyondImageBoundsUntouchedTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var layer = try glyphwire.Layer.init(alloc, 5, 5, 0);
    defer layer.deinit();

    // Pre-mark a cell with a distinct color so an untouched cell is
    // distinguishable from the layer's blank default.
    layer.cell(0, 3).style.bg = .{ .color = .{ .r = 9, .g = 9, .b = 9 } };

    // A 12x12px image (one cell) drawn into a 2x2-cell span: only the
    // top-left cell is actually covered -- the other three cells the
    // image doesn't reach should be left as they were.
    layer.drawImage(1, 0, 2, 2, 2, 12, 12, 12, 12);

    try testz.expectEqual(layer.cell(0, 2).style.bg.image.handle, 1);
    switch (layer.cell(0, 3).style.bg) {
        .color => |c| try testz.expectEqual(c.r, 9),
        .image, .icon => return error.TestUnexpectedResult,
    }
    switch (layer.cell(1, 2).style.bg) {
        .color => {},
        .image, .icon => return error.TestUnexpectedResult,
    }
}

pub fn layerDrawImageScrollsInsteadOfClippingRowSpanPastBottomTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    // 3x3 layer, anchored at row 1 with a row_span of 3: the image's last
    // row (row 3) is one past `height`, so drawing it should scroll the
    // viewport once -- interleaving the image into the flow the way a
    // fourth line of text would -- rather than silently dropping that row
    // the way clamping `row_end` to `self.height` used to.
    var layer = try glyphwire.Layer.init(alloc, 3, 3, 5);
    defer layer.deinit();

    // Marker on the original top row, to confirm it got pushed into
    // scrollback by the forced scroll rather than just being left in
    // place (which would mean nothing actually scrolled).
    layer.cell(0, 0).style.bg = .{ .color = .{ .r = 9, .g = 9, .b = 9 } };

    layer.drawImage(1, 1, 0, 3, 1, 10, 30, 10, 10);

    try testz.expectEqual(layer.cell(0, 0).style.bg.image.offset_y, 0);
    try testz.expectEqual(layer.cell(1, 0).style.bg.image.offset_y, 10);
    try testz.expectEqual(layer.cell(2, 0).style.bg.image.offset_y, 20);

    const history_top = layer.scrollbackRow(0) orelse return error.TestUnexpectedResult;
    switch (history_top[0].style.bg) {
        .color => |c| try testz.expectEqual(c.r, 9),
        .image, .icon => return error.TestUnexpectedResult,
    }
}

pub fn layerDrawIconMarksExactlyOneCellTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var layer = try glyphwire.Layer.init(alloc, 5, 5, 0);
    defer layer.deinit();

    layer.drawIcon(7, 1, 2, .{});

    try testz.expectEqual(layer.cell(1, 2).style.bg.icon.handle, 7);
    switch (layer.cell(1, 3).style.bg) {
        .color => {},
        .image, .icon => return error.TestUnexpectedResult,
    }
}

pub fn layerDrawIconOverSetsFgIconWithoutTouchingBgTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var layer = try glyphwire.Layer.init(alloc, 5, 5, 0);
    defer layer.deinit();

    // An existing background (as `drawBox`'s fill would leave) survives a
    // `drawIconOver` call on top of it -- the whole point of `fg_icon`
    // over `draw_icon`'s ordinary background-replacing behavior.
    layer.drawIcon(3, 1, 2, .{});
    layer.drawIconOver(7, 1, 2, .{});

    try testz.expectEqual(layer.cell(1, 2).style.bg.icon.handle, 3);
    try testz.expectEqual(layer.cell(1, 2).fg_icon.?.handle, 7);
}

pub fn layerDrawIconOverPastEdgeIsNoOpTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var layer = try glyphwire.Layer.init(alloc, 5, 5, 0);
    defer layer.deinit();

    layer.drawIconOver(7, 1, 10, .{});

    try testz.expectTrue(layer.cell(1, 4).fg_icon == null);
}

pub fn layerDrawIconDefaultsToFitAndCenterTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var layer = try glyphwire.Layer.init(alloc, 5, 5, 0);
    defer layer.deinit();

    layer.drawIcon(7, 1, 2, .{});

    const icon = layer.cell(1, 2).style.bg.icon;
    try testz.expectEqual(icon.scale, .fit);
    try testz.expectEqual(icon.h_align, .center);
    try testz.expectEqual(icon.v_align, .center);
}

pub fn layerDrawIconAppliesScaleAndAlignOptsTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var layer = try glyphwire.Layer.init(alloc, 5, 5, 0);
    defer layer.deinit();

    layer.drawIcon(7, 1, 2, .{ .scale = .natural, .h_align = .start, .v_align = .end });

    const icon = layer.cell(1, 2).style.bg.icon;
    try testz.expectEqual(icon.handle, 7);
    try testz.expectEqual(icon.scale, .natural);
    try testz.expectEqual(icon.h_align, .start);
    try testz.expectEqual(icon.v_align, .end);
}

pub fn layerDrawIconAppliesMaxWidthAndHeightTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var layer = try glyphwire.Layer.init(alloc, 5, 5, 0);
    defer layer.deinit();

    layer.drawIcon(7, 1, 2, .{ .scale = .natural, .max_w = 40, .max_h = 60 });

    const icon = layer.cell(1, 2).style.bg.icon;
    try testz.expectEqual(icon.max_w, 40);
    try testz.expectEqual(icon.max_h, 60);
}

pub fn layerDrawIconTaggedSetsMetadataIdTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var layer = try glyphwire.Layer.init(alloc, 5, 5, 0);
    defer layer.deinit();

    layer.drawIcon(7, 1, 2, .{ .metadata_id = 42 });

    try testz.expectEqual(layer.cell(1, 2).metadata_id.?, 42);
    // A sibling of style.bg, not part of the icon variant itself.
    try testz.expectEqual(layer.cell(1, 2).style.bg.icon.handle, 7);
}

pub fn layerTagMetadataSetsIdWithoutTouchingBgOrGraphemeTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var layer = try glyphwire.Layer.init(alloc, 5, 5, 0);
    defer layer.deinit();

    layer.drawIcon(7, 1, 2, .{ .metadata_id = 42 });
    layer.tagMetadata(1, 3, 42);

    // The neighboring cell got tagged with the same id as the icon's
    // anchor, but its background/grapheme are untouched -- still whatever
    // the layer's default is, not a copy of the icon.
    try testz.expectEqual(layer.cell(1, 3).metadata_id.?, 42);
    switch (layer.cell(1, 3).style.bg) {
        .color => {},
        .image, .icon => return error.TestUnexpectedResult,
    }
    try testz.expectEqual(layer.cell(1, 3).grapheme().len, 0);
}

pub fn layerTagMetadataOverwritesExistingTagTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var layer = try glyphwire.Layer.init(alloc, 5, 5, 0);
    defer layer.deinit();

    try layer.writeTextTagged("a", glyphwire.default_style.fg, glyphwire.default_style.bg, 1);
    layer.tagMetadata(0, 0, 2);

    try testz.expectEqual(layer.cell(0, 0).metadata_id.?, 2);
    // The grapheme write_text put there is still untouched.
    try testz.expectEqualStr(layer.cell(0, 0).grapheme(), "a");
}

pub fn layerWriteTextTaggedMarksEveryCellTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var layer = try glyphwire.Layer.init(alloc, 10, 5, 0);
    defer layer.deinit();

    try layer.writeTextTagged("abc", glyphwire.default_style.fg, glyphwire.default_style.bg, 7);

    try testz.expectEqual(layer.cell(0, 0).metadata_id.?, 7);
    try testz.expectEqual(layer.cell(0, 1).metadata_id.?, 7);
    try testz.expectEqual(layer.cell(0, 2).metadata_id.?, 7);
    // Untouched by this call: no tag.
    try testz.expectTrue(layer.cell(0, 3).metadata_id == null);
}

pub fn layerWriteTextLeavesMetadataUntaggedTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var layer = try glyphwire.Layer.init(alloc, 10, 5, 0);
    defer layer.deinit();

    try layer.writeText("abc", glyphwire.default_style.fg, glyphwire.default_style.bg);

    try testz.expectTrue(layer.cell(0, 0).metadata_id == null);
}

/// The same regression as setCursorPastBottomScrollsLikeWritingPastItWouldTest,
/// but for draw_icon's own anchor row directly (not via set_property) --
/// glyphwire-ls calls drawIcon with an explicit row before it ever calls
/// setCursor for that entry, so drawIcon itself has to resolve a
/// past-the-bottom row the same way, not just rely on setCursor doing it
/// afterward.
pub fn layerDrawIconPastBottomScrollsTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var layer = try glyphwire.Layer.init(alloc, 5, 3, 10);
    defer layer.deinit();

    layer.drawIcon(1, 2, 0, .{}); // valid, the last row (height=3, rows 0..2)
    layer.drawIcon(2, 3, 0, .{}); // one past the bottom -- scrolls once, lands on row 2

    try testz.expectEqual(layer.history_len, 1);
    // The scroll shifted the first icon up into row 1 rather than losing
    // it, and the second landed on the freshly-scrolled-to row 2.
    try testz.expectEqual(layer.cell(1, 0).style.bg.icon.handle, 1);
    try testz.expectEqual(layer.cell(2, 0).style.bg.icon.handle, 2);
}

pub fn layerDrawIconColPastEdgeIsNoOpTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var layer = try glyphwire.Layer.init(alloc, 5, 5, 0);
    defer layer.deinit();
    const revision_before = layer.revision;

    layer.drawIcon(1, 0, 10, .{});

    try testz.expectEqual(layer.revision, revision_before);
}

pub fn contextRegisterIconThenLookUpByNameTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 80, 24, 0);
    defer ctx.deinit();

    const png = fakePngBytes(32, 32);
    const handle = try ctx.loadImage(&png);
    try ctx.registerIcon("folder", handle);

    try testz.expectEqual(ctx.iconHandle("folder").?, handle);
    try testz.expectTrue(ctx.iconHandle("not-registered") == null);
}

pub fn contextRegisterIconTwiceUnderSameNameOverwritesTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 80, 24, 0);
    defer ctx.deinit();

    const png_a = fakePngBytes(16, 16);
    const handle_a = try ctx.loadImage(&png_a);
    try ctx.registerIcon("icon", handle_a);

    const png_b = fakePngBytes(32, 32);
    const handle_b = try ctx.loadImage(&png_b);
    try ctx.registerIcon("icon", handle_b);

    try testz.expectEqual(ctx.iconHandle("icon").?, handle_b);
}

pub fn contextCreateMetadataThenLookUpByIdTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 80, 24, 0);
    defer ctx.deinit();

    const id = try ctx.createMetadata("{\"path\":\"/tmp/afile.txt\"}");

    try testz.expectEqualStr(ctx.metadataJson(id).?, "{\"path\":\"/tmp/afile.txt\"}");
}

pub fn contextDestroyMetadataFreesItAndErrorsOnUnknownIdTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 80, 24, 0);
    defer ctx.deinit();

    const id = try ctx.createMetadata("{}");
    try ctx.destroyMetadata(id);

    // Dangling read: not an error, just gone -- see destroyMetadata's doc
    // comment.
    try testz.expectTrue(ctx.metadataJson(id) == null);

    // Destroying again (or an id that was never created) is an error --
    // same treatment destroyLayer gives an unknown layer handle.
    try testz.expectError(ctx.destroyMetadata(id), glyphwire.MetadataError.UnknownMetadata);
}

fn testBoxTiles() glyphwire.Layer.BoxTiles {
    // Distinct handles per piece so a test can tell which piece landed
    // where purely from the handle number -- drawBox draws each with the
    // .icon Background variant (scale-to-fit, same as draw_icon), which
    // is just a handle, not a real loaded image lookup.
    return .{
        .tl = 1,
        .t = 2,
        .tr = 3,
        .l = 4,
        .fill = 5,
        .r = 6,
        .bl = 7,
        .b = 8,
        .br = 9,
    };
}

pub fn layerDrawBoxPlacesEachPieceByRoleTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var layer = try glyphwire.Layer.init(alloc, 10, 10, 0);
    defer layer.deinit();

    // A 4x5 box anchored at (1, 1): rows 1..4, cols 1..5.
    layer.drawBox(testBoxTiles(), .tile, 1, 1, 4, 5);

    try testz.expectEqual(layer.cell(1, 1).style.bg.icon.handle, 1); // tl
    try testz.expectEqual(layer.cell(1, 3).style.bg.icon.handle, 2); // t (interior top col)
    try testz.expectEqual(layer.cell(1, 5).style.bg.icon.handle, 3); // tr
    try testz.expectEqual(layer.cell(2, 1).style.bg.icon.handle, 4); // l
    try testz.expectEqual(layer.cell(2, 3).style.bg.icon.handle, 5); // fill
    try testz.expectEqual(layer.cell(2, 5).style.bg.icon.handle, 6); // r
    try testz.expectEqual(layer.cell(4, 1).style.bg.icon.handle, 7); // bl
    try testz.expectEqual(layer.cell(4, 3).style.bg.icon.handle, 8); // b
    try testz.expectEqual(layer.cell(4, 5).style.bg.icon.handle, 9); // br

    // Every tile stretches to fill its cell exactly, not the aspect-
    // preserved `.fit` a bare `drawIcon` call defaults to -- see
    // `IconScale`'s doc comment on why tiles need this to stay gap-free.
    try testz.expectEqual(layer.cell(1, 1).style.bg.icon.scale, .stretch);
    try testz.expectEqual(layer.cell(2, 3).style.bg.icon.scale, .stretch);

    // Outside the box entirely: untouched.
    switch (layer.cell(0, 0).style.bg) {
        .color => {},
        .image, .icon => return error.TestUnexpectedResult,
    }
}

pub fn layerDrawBoxStretchModeSlicesFillAcrossInteriorTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var layer = try glyphwire.Layer.init(alloc, 10, 10, 0);
    defer layer.deinit();

    // A 6x6 box anchored at (0, 0): a 4x4 interior (rows 1..4, cols 1..4)
    // -- quarter fractions land on exact f32 values, so this can compare
    // with plain equality instead of an epsilon.
    layer.drawBox(testBoxTiles(), .stretch, 0, 0, 6, 6);

    // Corners never slice, `.stretch` or not.
    const tl = layer.cell(0, 0).style.bg.icon;
    try testz.expectEqual(tl.src_l, 0);
    try testz.expectEqual(tl.src_t, 0);
    try testz.expectEqual(tl.src_r, 1);
    try testz.expectEqual(tl.src_b, 1);

    // Fill's interior is 4x4 (rows 1..4, cols 1..4) -- cell (2, 2) is
    // index (1, 1) of 4 on both axes, so it gets the second quarter of
    // the source image both horizontally and vertically.
    const fill_mid = layer.cell(2, 2).style.bg.icon;
    try testz.expectEqual(fill_mid.src_l, 0.25);
    try testz.expectEqual(fill_mid.src_r, 0.5);
    try testz.expectEqual(fill_mid.src_t, 0.25);
    try testz.expectEqual(fill_mid.src_b, 0.5);

    // Top edge only slices horizontally -- full height regardless of
    // position along the run. Cell (0, 1) is the first interior column,
    // index 0 of 4.
    const top_first = layer.cell(0, 1).style.bg.icon;
    try testz.expectEqual(top_first.src_l, 0);
    try testz.expectEqual(top_first.src_r, 0.25);
    try testz.expectEqual(top_first.src_t, 0);
    try testz.expectEqual(top_first.src_b, 1);

    // Left edge only slices vertically -- full width regardless of
    // position along the run. Cell (4, 0) is the last interior row,
    // index 3 of 4.
    const left_last = layer.cell(4, 0).style.bg.icon;
    try testz.expectEqual(left_last.src_l, 0);
    try testz.expectEqual(left_last.src_r, 1);
    try testz.expectEqual(left_last.src_t, 0.75);
    try testz.expectEqual(left_last.src_b, 1);
}

pub fn layerDrawBoxClipsToLayerBoundsTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var layer = try glyphwire.Layer.init(alloc, 5, 5, 0);
    defer layer.deinit();

    // A box requesting more rows/cols than the layer has past its anchor
    // shouldn't panic or write out of bounds.
    layer.drawBox(testBoxTiles(), .tile, 3, 3, 10, 10);

    try testz.expectEqual(layer.cell(3, 3).style.bg.icon.handle, 1); // tl, still placed
    try testz.expectEqual(layer.cell(4, 4).style.bg.icon.handle, 5); // clamped corner lands as fill, not br
}

pub fn layerDrawBoxZeroSizeIsNoOpTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var layer = try glyphwire.Layer.init(alloc, 5, 5, 0);
    defer layer.deinit();
    const revision_before = layer.revision;

    layer.drawBox(testBoxTiles(), .tile, 0, 0, 0, 5);
    layer.drawBox(testBoxTiles(), .tile, 0, 0, 5, 0);

    try testz.expectEqual(layer.revision, revision_before);
    switch (layer.cell(0, 0).style.bg) {
        .color => {},
        .image, .icon => return error.TestUnexpectedResult,
    }
}

pub fn layerClearResetsRegionToBlankTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var layer = try glyphwire.Layer.init(alloc, 5, 5, 0);
    defer layer.deinit();
    try layer.writeText("hello", glyphwire.default_style.fg, glyphwire.default_style.bg);
    layer.drawBox(testBoxTiles(), .tile, 1, 1, 3, 3);

    layer.clear(0, 0, 1, 5);

    try testz.expectEqual(layer.cell(0, 0).grapheme().len, 0);
    // Untouched region keeps its content.
    try testz.expectEqual(layer.cell(1, 1).style.bg.icon.handle, 1);
}

pub fn layerClearWholeLayerViaFullSpanTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var layer = try glyphwire.Layer.init(alloc, 5, 5, 0);
    defer layer.deinit();
    try layer.writeText("hello", glyphwire.default_style.fg, glyphwire.default_style.bg);
    layer.drawBox(testBoxTiles(), .tile, 2, 2, 3, 3);

    layer.clear(0, 0, layer.height, layer.width);

    try testz.expectEqual(layer.cell(0, 0).grapheme().len, 0);
    switch (layer.cell(2, 2).style.bg) {
        .color => {},
        .image, .icon => return error.TestUnexpectedResult,
    }
}

pub fn layerClearOutOfBoundsAnchorIsNoOpTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var layer = try glyphwire.Layer.init(alloc, 5, 5, 0);
    defer layer.deinit();
    const revision_before = layer.revision;

    layer.clear(10, 0, 3, 3);
    layer.clear(0, 10, 3, 3);
    layer.clear(0, 0, 0, 3);
    layer.clear(0, 0, 3, 0);

    try testz.expectEqual(layer.revision, revision_before);
}

// --- C0 control characters and ESC-sequence stripping in writeText -------------

pub fn writeTextNewlineActsAsCarriageReturnLineFeedTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var layer = try glyphwire.Layer.init(alloc, 80, 24, 0);
    defer layer.deinit();

    // "\n" moves to column 0 of the next row (CR + LF), so "b" lands under
    // "a" rather than staircasing after it.
    try layer.writeText("a\nb", glyphwire.default_style.fg, glyphwire.default_style.bg);

    try testz.expectEqualStr("a", layer.cell(0, 0).grapheme());
    try testz.expectEqualStr("b", layer.cell(1, 0).grapheme());
    try testz.expectEqual(layer.cursor.row, 1);
    try testz.expectEqual(layer.cursor.col, 1);
    // The "\n" itself is never drawn as a grapheme.
    try testz.expectEqual(layer.cell(0, 1).grapheme().len, 0);
}

pub fn writeTextCarriageReturnReturnsToColumnZeroTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var layer = try glyphwire.Layer.init(alloc, 80, 24, 0);
    defer layer.deinit();

    // A bare "\r" returns to column 0 of the *same* row -- the classic
    // progress-bar overwrite.
    try layer.writeText("12345\rXY", glyphwire.default_style.fg, glyphwire.default_style.bg);

    try testz.expectEqualStr("X", layer.cell(0, 0).grapheme());
    try testz.expectEqualStr("Y", layer.cell(0, 1).grapheme());
    try testz.expectEqualStr("3", layer.cell(0, 2).grapheme());
    try testz.expectEqual(layer.cursor.row, 0);
    try testz.expectEqual(layer.cursor.col, 2);
}

pub fn writeTextTabAdvancesToNextStopTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var layer = try glyphwire.Layer.init(alloc, 80, 24, 0);
    defer layer.deinit();

    // Stops every `tab_width` (8) columns: from col 1 -> 8, then 9 -> 16.
    try layer.writeText("a\tb\tc", glyphwire.default_style.fg, glyphwire.default_style.bg);

    try testz.expectEqualStr("a", layer.cell(0, 0).grapheme());
    try testz.expectEqualStr("b", layer.cell(0, 8).grapheme());
    try testz.expectEqualStr("c", layer.cell(0, 16).grapheme());
    try testz.expectEqual(layer.cursor.col, 17);
    // Cells the tab skipped over are left untouched, not space-filled.
    try testz.expectEqual(layer.cell(0, 3).grapheme().len, 0);
}

pub fn writeTextTabClampsToLastColumnTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var layer = try glyphwire.Layer.init(alloc, 6, 3, 0);
    defer layer.deinit();

    // Next stop (8) is past the 6-wide layer -- the tab clamps to the last
    // column instead of wrapping to the next row.
    try layer.writeText("ab\tZ", glyphwire.default_style.fg, glyphwire.default_style.bg);

    try testz.expectEqualStr("Z", layer.cell(0, 5).grapheme());
    try testz.expectEqual(layer.cursor.row, 0);
    try testz.expectEqual(layer.cursor.col, 6);
}

pub fn writeTextBackspaceStepsBackNonDestructivelyTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var layer = try glyphwire.Layer.init(alloc, 80, 24, 0);
    defer layer.deinit();

    // "\b" only moves the cursor; it doesn't erase. Writing after it
    // overwrites the stepped-back cell.
    try layer.writeText("abc\x08\x08X", glyphwire.default_style.fg, glyphwire.default_style.bg);

    try testz.expectEqualStr("a", layer.cell(0, 0).grapheme());
    try testz.expectEqualStr("X", layer.cell(0, 1).grapheme());
    try testz.expectEqualStr("c", layer.cell(0, 2).grapheme());
    try testz.expectEqual(layer.cursor.col, 2);
}

pub fn writeTextBackspaceAtColumnZeroIsNoOpTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var layer = try glyphwire.Layer.init(alloc, 80, 24, 0);
    defer layer.deinit();

    // No wrap back onto a previous row -- "\b" at column 0 does nothing.
    try layer.writeText("\x08\x08hi", glyphwire.default_style.fg, glyphwire.default_style.bg);

    try testz.expectEqualStr("h", layer.cell(0, 0).grapheme());
    try testz.expectEqualStr("i", layer.cell(0, 1).grapheme());
    try testz.expectEqual(layer.cursor.row, 0);
    try testz.expectEqual(layer.cursor.col, 2);
}

pub fn writeTextDropsOtherC0AndDelBytesTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var layer = try glyphwire.Layer.init(alloc, 80, 24, 0);
    defer layer.deinit();

    // NUL, BEL, and DEL are swallowed -- neither drawn nor cursor-moving.
    try layer.writeText("a\x00b\x07c\x7fd", glyphwire.default_style.fg, glyphwire.default_style.bg);

    try testz.expectEqualStr("a", layer.cell(0, 0).grapheme());
    try testz.expectEqualStr("b", layer.cell(0, 1).grapheme());
    try testz.expectEqualStr("c", layer.cell(0, 2).grapheme());
    try testz.expectEqualStr("d", layer.cell(0, 3).grapheme());
    try testz.expectEqual(layer.cursor.col, 4);
}

pub fn writeTextInterpretsSgrColourSequenceTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var layer = try glyphwire.Layer.init(alloc, 80, 24, 0);
    defer layer.deinit();

    // An SGR colour sequence's bytes are still kept off the grid (none of
    // "[31m" / "[0m" is drawn), but the colour is now applied: "RED" is
    // red, "!" after the reset is back to default.
    try layer.writeText("\x1b[31mRED\x1b[0m!", glyphwire.default_style.fg, glyphwire.default_style.bg);

    try testz.expectEqualStr("R", layer.cell(0, 0).grapheme());
    try testz.expectEqualStr("E", layer.cell(0, 1).grapheme());
    try testz.expectEqualStr("D", layer.cell(0, 2).grapheme());
    try testz.expectEqualStr("!", layer.cell(0, 3).grapheme());
    try testz.expectEqual(layer.cursor.col, 4);
    try testz.expectEqual(layer.esc_state, glyphwire.EscState.ground);

    // ANSI 31 == palette index 1 == {205, 0, 0}.
    try testz.expectEqual(layer.cell(0, 0).style.fg.r, 205);
    try testz.expectEqual(layer.cell(0, 0).style.fg.g, 0);
    try testz.expectEqual(layer.cell(0, 2).style.fg.r, 205);
    // "!" is drawn after `ESC [ 0 m` reset it to the call's fg argument.
    try testz.expectEqual(layer.cell(0, 3).style.fg.r, glyphwire.default_style.fg.r);
}

pub fn writeTextStripsOscSequenceTerminatedByBelTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var layer = try glyphwire.Layer.init(alloc, 80, 24, 0);
    defer layer.deinit();

    // OSC "set window title" -- ends at the BEL, which must not itself be
    // treated as a stray C0 byte to draw/skip separately.
    try layer.writeText("\x1b]0;title\x07done", glyphwire.default_style.fg, glyphwire.default_style.bg);

    try testz.expectEqualStr("d", layer.cell(0, 0).grapheme());
    try testz.expectEqualStr("o", layer.cell(0, 1).grapheme());
    try testz.expectEqualStr("n", layer.cell(0, 2).grapheme());
    try testz.expectEqualStr("e", layer.cell(0, 3).grapheme());
    try testz.expectEqual(layer.cursor.col, 4);
}

pub fn writeTextDoesNotCarryPartialEscSequenceAcrossCallsTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var layer = try glyphwire.Layer.init(alloc, 80, 24, 0);
    defer layer.deinit();

    // A sequence split across two calls ("\x1b[1" then "2mX") is NOT
    // stripped as one unit: the first call abandons the still-open
    // sequence (esc_state back to .ground) rather than leaving the
    // stripper armed, so the second call's "2mX" draws literally. This
    // is the deliberate trade for never letting an unterminated sequence
    // swallow a later write -- see writeText / EscState.
    try layer.writeText("\x1b[1", glyphwire.default_style.fg, glyphwire.default_style.bg);
    try testz.expectEqual(layer.esc_state, glyphwire.EscState.ground);
    try layer.writeText("2mX", glyphwire.default_style.fg, glyphwire.default_style.bg);

    try testz.expectEqualStr("2", layer.cell(0, 0).grapheme());
    try testz.expectEqualStr("m", layer.cell(0, 1).grapheme());
    try testz.expectEqualStr("X", layer.cell(0, 2).grapheme());
    try testz.expectEqual(layer.cursor.col, 3);
    try testz.expectEqual(layer.esc_state, glyphwire.EscState.ground);
}

pub fn writeTextUnterminatedEscSequenceDoesNotSwallowNextCallTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var layer = try glyphwire.Layer.init(alloc, 80, 24, 0);
    defer layer.deinit();

    // An unterminated OSC ("\x1b]2;still-open", no BEL/ST) ends the call
    // with the stripper mid-sequence. Before the reset-at-end-of-call
    // fix this armed state persisted and ate the whole next write; the
    // shell's own prompt would silently vanish. Now the next call draws
    // in full.
    try layer.writeText("out\x1b]2;still-open", glyphwire.default_style.fg, glyphwire.default_style.bg);
    try testz.expectEqual(layer.esc_state, glyphwire.EscState.ground);

    layer.cursor = .{ .row = 1, .col = 0 };
    try layer.writeText("/home/user > ", glyphwire.default_style.fg, glyphwire.default_style.bg);

    try testz.expectEqualStr("/", layer.cell(1, 0).grapheme());
    try testz.expectEqualStr("h", layer.cell(1, 1).grapheme());
    try testz.expectEqualStr("e", layer.cell(1, 4).grapheme());
    try testz.expectEqual(layer.cursor.col, "/home/user > ".len);

    // A lone trailing ESC is abandoned the same way.
    layer.cursor = .{ .row = 2, .col = 0 };
    try layer.writeText("tail\x1b", glyphwire.default_style.fg, glyphwire.default_style.bg);
    try testz.expectEqual(layer.esc_state, glyphwire.EscState.ground);
    layer.cursor = .{ .row = 3, .col = 0 };
    try layer.writeText("next", glyphwire.default_style.fg, glyphwire.default_style.bg);
    try testz.expectEqualStr("n", layer.cell(3, 0).grapheme());
    try testz.expectEqualStr("t", layer.cell(3, 3).grapheme());
}

// --- SGR interpretation (the Phase A "VT fallback" pen) -----------------------

pub fn writeTextSgr256AndTruecolorForegroundTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var layer = try glyphwire.Layer.init(alloc, 80, 4, 0);
    defer layer.deinit();

    // 256-colour cube: index 208 -> {255, 135, 0}.
    try layer.writeText("\x1b[38;5;208mX", glyphwire.default_style.fg, glyphwire.default_style.bg);
    try testz.expectEqual(layer.cell(0, 0).style.fg.r, 255);
    try testz.expectEqual(layer.cell(0, 0).style.fg.g, 135);
    try testz.expectEqual(layer.cell(0, 0).style.fg.b, 0);

    // Truecolor, colon-separated form.
    layer.cursor = .{ .row = 1, .col = 0 };
    try layer.writeText("\x1b[38:2::12:34:56mY", glyphwire.default_style.fg, glyphwire.default_style.bg);
    try testz.expectEqual(layer.cell(1, 0).style.fg.r, 12);
    try testz.expectEqual(layer.cell(1, 0).style.fg.g, 34);
    try testz.expectEqual(layer.cell(1, 0).style.fg.b, 56);
}

pub fn writeTextSgrBackgroundAndInverseTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var layer = try glyphwire.Layer.init(alloc, 80, 4, 0);
    defer layer.deinit();

    // Green background (42), then inverse (7) swaps it onto the foreground.
    try layer.writeText("\x1b[42mA\x1b[7mB", glyphwire.default_style.fg, glyphwire.default_style.bg);

    // "A": default fg on green bg. ANSI 32 (green) == {0, 205, 0}.
    try testz.expectEqual(layer.cell(0, 0).style.fg.r, glyphwire.default_style.fg.r);
    try testz.expectEqual(layer.cell(0, 0).style.bg.color.g, 205);
    // "B": inverse -> fg is the former bg (green), bg is the former fg.
    try testz.expectEqual(layer.cell(0, 1).style.fg.g, 205);
    try testz.expectEqual(layer.cell(0, 1).style.bg.color.r, glyphwire.default_style.fg.r);
}

pub fn writeTextSgrBoldPromotesBasicForegroundToBrightTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var layer = try glyphwire.Layer.init(alloc, 80, 4, 0);
    defer layer.deinit();

    // `ESC [ 1 ; 31 m` -- bold + red. Bold promotes basic red (index 1,
    // {205,0,0}) to bright red (index 9, {255,0,0}), a common terminal
    // behaviour and the whole of Phase A's "bold" support.
    try layer.writeText("\x1b[1;31mERR", glyphwire.default_style.fg, glyphwire.default_style.bg);
    try testz.expectEqual(layer.cell(0, 0).style.fg.r, 255);
    try testz.expectEqual(layer.cell(0, 0).style.fg.g, 0);

    // Bold with a non-basic (truecolor) fg is left as-is.
    layer.cursor = .{ .row = 1, .col = 0 };
    try layer.writeText("\x1b[1;38;2;10;20;30mZ", glyphwire.default_style.fg, glyphwire.default_style.bg);
    try testz.expectEqual(layer.cell(1, 0).style.fg.r, 10);
    try testz.expectEqual(layer.cell(1, 0).style.fg.b, 30);
}

pub fn writeTextSgrDimDarkensForegroundTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var layer = try glyphwire.Layer.init(alloc, 80, 4, 0);
    defer layer.deinit();

    // Dim (2) scales the resolved fg to 55%. White default fg (255) -> 140.
    try layer.writeText("\x1b[2md", glyphwire.default_style.fg, glyphwire.default_style.bg);
    try testz.expectEqual(layer.cell(0, 0).style.fg.r, 140);
}

pub fn writeTextSgrColourDoesNotCarryAcrossCallsTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var layer = try glyphwire.Layer.init(alloc, 80, 4, 0);
    defer layer.deinit();

    // An SGR colour set in one call and left un-reset (no `ESC [ 0 m`,
    // as a `cat`'d file of raw escapes or an interrupted program would
    // leave it) must NOT bleed into the next call -- otherwise every
    // shell prompt / `ls` listing after such a command renders in that
    // colour. The pen is call-local.
    try layer.writeText("\x1b[31mred", glyphwire.default_style.fg, glyphwire.default_style.bg);
    try testz.expectEqual(layer.cell(0, 0).style.fg.r, 205); // "red" is red

    layer.cursor = .{ .row = 1, .col = 0 };
    try layer.writeText("plain", glyphwire.default_style.fg, glyphwire.default_style.bg);
    try testz.expectEqual(layer.cell(1, 0).style.fg.r, glyphwire.default_style.fg.r);
    try testz.expectEqual(layer.cell(1, 0).style.fg.g, glyphwire.default_style.fg.g);
    try testz.expectEqual(layer.cell(1, 0).style.fg.b, glyphwire.default_style.fg.b);
}

// --- CSI cursor / erase interpretation --------------------------------------

pub fn writeTextInterpretsCsiEraseInLineTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var layer = try glyphwire.Layer.init(alloc, 10, 2, 0);
    defer layer.deinit();

    // Progress-bar shape: draw, carriage-return, erase-to-end-of-line,
    // redraw shorter.
    try layer.writeText("1234567890\r", glyphwire.default_style.fg, glyphwire.default_style.bg);
    try layer.writeText("\x1b[Kabc", glyphwire.default_style.fg, glyphwire.default_style.bg);

    try testz.expectEqualStr("a", layer.cell(0, 0).grapheme());
    try testz.expectEqualStr("c", layer.cell(0, 2).grapheme());
    // The rest of the line was cleared, not left as "4567890".
    try testz.expectEqual(layer.cell(0, 3).grapheme().len, 0);
    try testz.expectEqual(layer.cell(0, 9).grapheme().len, 0);
}

pub fn writeTextInterpretsCsiCursorMovesTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var layer = try glyphwire.Layer.init(alloc, 20, 5, 0);
    defer layer.deinit();

    // Absolute position (1-based), then relative nudges.
    try layer.writeText("\x1b[3;5HX", glyphwire.default_style.fg, glyphwire.default_style.bg);
    try testz.expectEqualStr("X", layer.cell(2, 4).grapheme());
    try testz.expectEqual(layer.cursor.row, 2);
    try testz.expectEqual(layer.cursor.col, 5);

    // Up 2, back 3, then draw.
    try layer.writeText("\x1b[2A\x1b[3DY", glyphwire.default_style.fg, glyphwire.default_style.bg);
    try testz.expectEqualStr("Y", layer.cell(0, 2).grapheme());

    // Column-absolute (CHA), 1-based.
    try layer.writeText("\x1b[10GZ", glyphwire.default_style.fg, glyphwire.default_style.bg);
    try testz.expectEqualStr("Z", layer.cell(0, 9).grapheme());
}

pub fn writeTextInterpretsCsiEraseInDisplayTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var layer = try glyphwire.Layer.init(alloc, 6, 3, 0);
    defer layer.deinit();

    try layer.writeText("aaaaaabbbbbbcccccc", glyphwire.default_style.fg, glyphwire.default_style.bg);
    // Home, then erase whole display (`ESC [ 2 J`).
    try layer.writeText("\x1b[H\x1b[2J", glyphwire.default_style.fg, glyphwire.default_style.bg);

    try testz.expectEqual(layer.cell(0, 0).grapheme().len, 0);
    try testz.expectEqual(layer.cell(1, 3).grapheme().len, 0);
    try testz.expectEqual(layer.cell(2, 5).grapheme().len, 0);
}

pub fn writeTextDiscardsUnhandledCsiAndPrivateSequencesTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var layer = try glyphwire.Layer.init(alloc, 20, 3, 0);
    defer layer.deinit();

    // `ESC [ ? 25 l` (hide cursor) and `ESC [ 6 n` (device status report)
    // are recognized as sequences and dropped -- none of their bytes are
    // drawn, and they don't disturb the cursor.
    try layer.writeText("\x1b[?25lA\x1b[6nB", glyphwire.default_style.fg, glyphwire.default_style.bg);
    try testz.expectEqualStr("A", layer.cell(0, 0).grapheme());
    try testz.expectEqualStr("B", layer.cell(0, 1).grapheme());
    try testz.expectEqual(layer.cursor.col, 2);
}

pub fn writeTextNewlineScrollsAtBottomRowTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var layer = try glyphwire.Layer.init(alloc, 10, 2, 2);
    defer layer.deinit();

    // Cursor starts on the last row; "\n" there scrolls immediately, the
    // same one-row advance `resolveRow` gives explicit cursor moves.
    try layer.writeText("top\nbottom\nthird", glyphwire.default_style.fg, glyphwire.default_style.bg);

    try testz.expectEqualStr("b", layer.cell(0, 0).grapheme());
    try testz.expectEqualStr("t", layer.cell(1, 0).grapheme());
    try testz.expectEqual(layer.cursor.row, 1);
    try testz.expectEqual(layer.history_len, 1);
    try testz.expectEqualStr("t", layer.scrollbackRow(0).?[0].grapheme());
}
