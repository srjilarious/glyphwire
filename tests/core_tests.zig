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
    const handle = try ctx.loadImage(.png, &bytes);

    const info = ctx.imageInfo(handle).?;
    try testz.expectEqual(info.width, 48);
    try testz.expectEqual(info.height, 24);
    try testz.expectTrue(ctx.imageInfo(handle + 1) == null);
}

/// A minimal JPEG byte stream `jpegDimensions` can walk: SOI, a stub APP0
/// segment (to exercise the segment-length skip), then an SOF0 frame
/// header carrying `precision(1) height(2) width(2)` and enough trailing
/// bytes to satisfy its declared length. Not a decodable JPEG.
fn fakeJpegBytes(width: u16, height: u16) [23]u8 {
    var bytes: [23]u8 = undefined;
    bytes[0] = 0xFF;
    bytes[1] = 0xD8; // SOI
    bytes[2] = 0xFF;
    bytes[3] = 0xE0; // APP0
    std.mem.writeInt(u16, bytes[4..6], 4, .big); // APP0 length (covers itself + 2)
    bytes[6] = 0;
    bytes[7] = 0;
    bytes[8] = 0xFF;
    bytes[9] = 0xC0; // SOF0
    std.mem.writeInt(u16, bytes[10..12], 11, .big); // SOF0 length: 2 + precision + h + w + 4 stub
    bytes[12] = 8; // sample precision
    std.mem.writeInt(u16, bytes[13..15], height, .big);
    std.mem.writeInt(u16, bytes[15..17], width, .big);
    @memset(bytes[17..23], 0); // component stub bytes the length accounts for
    return bytes;
}

pub fn jpegDimensionsParsesSofTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    _ = alloc;
    const bytes = fakeJpegBytes(640, 400);
    const info = try glyphwire.jpegDimensions(&bytes);
    try testz.expectEqual(info.width, 640);
    try testz.expectEqual(info.height, 400);
}

pub fn jpegDimensionsRejectsNonJpegTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    _ = alloc;
    const png = fakePngBytes(16, 16);
    try testz.expectError(glyphwire.jpegDimensions(&png), glyphwire.ImageError.InvalidJpeg);
}

/// A BMP with a 40-byte BITMAPINFOHEADER: the 14-byte file header ("BM" +
/// sizes we don't read), then the DIB header size, then little-endian i32
/// width and height.
fn fakeBmpBytes(width: i32, height: i32) [26]u8 {
    var bytes = std.mem.zeroes([26]u8);
    bytes[0] = 'B';
    bytes[1] = 'M';
    std.mem.writeInt(u32, bytes[14..18], 40, .little);
    std.mem.writeInt(i32, bytes[18..22], width, .little);
    std.mem.writeInt(i32, bytes[22..26], height, .little);
    return bytes;
}

pub fn bmpDimensionsParsesInfoHeaderTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    _ = alloc;
    const bytes = fakeBmpBytes(100, 50);
    const info = try glyphwire.bmpDimensions(&bytes);
    try testz.expectEqual(info.width, 100);
    try testz.expectEqual(info.height, 50);
}

pub fn bmpDimensionsTopDownHeightIsAbsoluteTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    _ = alloc;
    const bytes = fakeBmpBytes(100, -50); // negative height = top-down row order
    const info = try glyphwire.bmpDimensions(&bytes);
    try testz.expectEqual(info.width, 100);
    try testz.expectEqual(info.height, 50);
}

pub fn gifDimensionsParsesScreenDescriptorTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    _ = alloc;
    var bytes = std.mem.zeroes([10]u8);
    @memcpy(bytes[0..6], "GIF89a");
    std.mem.writeInt(u16, bytes[6..8], 320, .little);
    std.mem.writeInt(u16, bytes[8..10], 240, .little);
    const info = try glyphwire.gifDimensions(&bytes);
    try testz.expectEqual(info.width, 320);
    try testz.expectEqual(info.height, 240);
}

pub fn detectImageFormatSniffsMagicBytesTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    _ = alloc;
    const png = fakePngBytes(8, 8);
    const jpeg = fakeJpegBytes(8, 8);
    const bmp = fakeBmpBytes(8, 8);
    var gif = std.mem.zeroes([10]u8);
    @memcpy(gif[0..6], "GIF87a");

    try testz.expectEqual(glyphwire.detectImageFormat(&png).?, .png);
    try testz.expectEqual(glyphwire.detectImageFormat(&jpeg).?, .jpeg);
    try testz.expectEqual(glyphwire.detectImageFormat(&bmp).?, .bmp);
    try testz.expectEqual(glyphwire.detectImageFormat(&gif).?, .gif);
    try testz.expectTrue(glyphwire.detectImageFormat("not an image") == null);
}

pub fn imageFormatFromMimetypeTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    _ = alloc;
    try testz.expectEqual(glyphwire.ImageFormat.fromMimetype("image/png").?, .png);
    try testz.expectEqual(glyphwire.ImageFormat.fromMimetype("image/jpeg").?, .jpeg);
    try testz.expectEqual(glyphwire.ImageFormat.fromMimetype("image/jpg").?, .jpeg);
    try testz.expectEqual(glyphwire.ImageFormat.fromMimetype("image/bmp").?, .bmp);
    try testz.expectEqual(glyphwire.ImageFormat.fromMimetype("image/gif").?, .gif);
    // Tagged image/... by glyphwire-ls, but glyphwire-view can't open them.
    try testz.expectTrue(glyphwire.ImageFormat.fromMimetype("image/svg+xml") == null);
    try testz.expectTrue(glyphwire.ImageFormat.fromMimetype("image/webp") == null);
    try testz.expectTrue(glyphwire.ImageFormat.fromMimetype("directory") == null);
}

pub fn contextLoadImageDeclaredFormatMismatchFailsTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 80, 24, 0);
    defer ctx.deinit();

    // PNG bytes handed over as a JPEG: the JPEG header parser rejects them.
    const png = fakePngBytes(48, 24);
    try testz.expectError(ctx.loadImage(.jpeg, &png), glyphwire.ImageError.InvalidJpeg);
}

pub fn contextLoadImageStoresDeclaredFormatTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 80, 24, 0);
    defer ctx.deinit();

    const gif = blk: {
        var bytes = std.mem.zeroes([10]u8);
        @memcpy(bytes[0..6], "GIF89a");
        std.mem.writeInt(u16, bytes[6..8], 12, .little);
        std.mem.writeInt(u16, bytes[8..10], 34, .little);
        break :blk bytes;
    };
    const handle = try ctx.loadImage(.gif, &gif);
    const info = ctx.imageInfo(handle).?;
    try testz.expectEqual(info.width, 12);
    try testz.expectEqual(info.height, 34);
}

pub fn layerDrawImageMarksCoveredCellsWithOffsetsTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var layer = try glyphwire.Layer.init(alloc, 5, 5, 0);
    defer layer.deinit();

    // A 2x2-cell span at 12px cells covers a 24x24px image exactly.
    layer.drawImage(1, 1, 1, 2, 2, 24, 24, 12, 12, 1.0);

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
    layer.drawImage(1, 0, 2, 2, 2, 12, 12, 12, 12, 1.0);

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

    layer.drawImage(1, 1, 0, 3, 1, 10, 30, 10, 10, 1.0);

    try testz.expectEqual(layer.cell(0, 0).style.bg.image.offset_y, 0);
    try testz.expectEqual(layer.cell(1, 0).style.bg.image.offset_y, 10);
    try testz.expectEqual(layer.cell(2, 0).style.bg.image.offset_y, 20);

    const history_top = layer.scrollbackRow(0) orelse return error.TestUnexpectedResult;
    switch (history_top[0].style.bg) {
        .color => |c| try testz.expectEqual(c.r, 9),
        .image, .icon => return error.TestUnexpectedResult,
    }
}

pub fn layerDrawImageScaledStepsSourceOffsetsByCellOverScaleTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var layer = try glyphwire.Layer.init(alloc, 6, 6, 0);
    defer layer.deinit();

    // A 96x48px image at scale 0.5 renders 48x24px -- 4x2 cells at 12px.
    // Each cell samples cell_px / scale = 24 source pixels, so the stored
    // per-cell offsets step by 24, not 12, and every cell records the
    // scale for the renderer.
    layer.drawImage(1, 0, 0, 2, 4, 96, 48, 12, 12, 0.5);

    try testz.expectEqual(layer.cell(0, 0).style.bg.image.offset_x, 0);
    try testz.expectEqual(layer.cell(0, 1).style.bg.image.offset_x, 24);
    try testz.expectEqual(layer.cell(0, 2).style.bg.image.offset_x, 48);
    try testz.expectEqual(layer.cell(0, 3).style.bg.image.offset_x, 72);
    try testz.expectEqual(layer.cell(0, 0).style.bg.image.offset_y, 0);
    try testz.expectEqual(layer.cell(1, 0).style.bg.image.offset_y, 24);
    try testz.expectEqual(layer.cell(0, 0).style.bg.image.scale, 0.5);
    try testz.expectEqual(layer.cell(1, 3).style.bg.image.scale, 0.5);
}

pub fn layerDrawImageScaledStopsAtImageEdgeInSourceSpaceTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var layer = try glyphwire.Layer.init(alloc, 8, 8, 0);
    defer layer.deinit();

    // A 60x12px image at scale 0.5 samples 24 source px per cell, so only
    // cells 0, 1 and 2 (offsets 0, 24, 48) actually reach the image; a
    // col_span of 5 leaves cells 3 and 4 (offset 96, past width 60)
    // untouched -- the same "cell past the image's edge is left as it was"
    // contract the unscaled path has.
    layer.drawImage(1, 0, 0, 1, 5, 60, 12, 12, 12, 0.5);

    try testz.expectEqual(layer.cell(0, 0).style.bg.image.offset_x, 0);
    try testz.expectEqual(layer.cell(0, 1).style.bg.image.offset_x, 24);
    try testz.expectEqual(layer.cell(0, 2).style.bg.image.offset_x, 48);
    switch (layer.cell(0, 3).style.bg) {
        .color => {},
        .image, .icon => return error.TestUnexpectedResult,
    }
    switch (layer.cell(0, 4).style.bg) {
        .color => {},
        .image, .icon => return error.TestUnexpectedResult,
    }
}

pub fn layerDrawImageScaleOfOneMatchesUnscaledOffsetsTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var layer = try glyphwire.Layer.init(alloc, 5, 5, 0);
    defer layer.deinit();

    // scale 1.0 must be byte-identical to the pre-scale behavior: a 2x2
    // span over a 24x24px image at 12px cells still steps offsets by 12.
    layer.drawImage(1, 1, 1, 2, 2, 24, 24, 12, 12, 1.0);

    try testz.expectEqual(layer.cell(1, 1).style.bg.image.offset_x, 0);
    try testz.expectEqual(layer.cell(1, 2).style.bg.image.offset_x, 12);
    try testz.expectEqual(layer.cell(2, 1).style.bg.image.offset_y, 12);
    try testz.expectEqual(layer.cell(1, 1).style.bg.image.scale, 1.0);
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
    const handle = try ctx.loadImage(.png, &png);
    try ctx.registerIcon("folder", handle);

    try testz.expectEqual(ctx.iconHandle("folder").?, handle);
    try testz.expectTrue(ctx.iconHandle("not-registered") == null);
}

pub fn contextRegisterIconTwiceUnderSameNameOverwritesTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 80, 24, 0);
    defer ctx.deinit();

    const png_a = fakePngBytes(16, 16);
    const handle_a = try ctx.loadImage(.png, &png_a);
    try ctx.registerIcon("icon", handle_a);

    const png_b = fakePngBytes(32, 32);
    const handle_b = try ctx.loadImage(.png, &png_b);
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

pub fn layerPtyModeCarriesPartialCsiAcrossCallsTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var layer = try glyphwire.Layer.init(alloc, 80, 4, 0);
    defer layer.deinit();
    layer.setProperty(.{ .pty_mode = true });

    // The default-mode trade (`writeTextDoesNotCarryPartialEscSequence...`)
    // draws "2mX" literally when a CSI is split across two writes. A
    // `pty_mode` layer keeps the machine armed: "\x1b[1" leaves it
    // mid-CSI, "2mX" finishes `ESC [ 1 2 m` (SGR) and only "X" prints.
    try layer.writeText("\x1b[1", glyphwire.default_style.fg, glyphwire.default_style.bg);
    try testz.expectEqual(layer.esc_state, glyphwire.EscState.csi);
    try layer.writeText("2mX", glyphwire.default_style.fg, glyphwire.default_style.bg);

    try testz.expectEqualStr("X", layer.cell(0, 0).grapheme());
    try testz.expectEqual(layer.cursor.col, 1);
    try testz.expectEqual(layer.esc_state, glyphwire.EscState.ground);
}

pub fn layerPtyModeKeepsSgrColourAcrossCallsTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var layer = try glyphwire.Layer.init(alloc, 80, 4, 0);
    defer layer.deinit();
    layer.setProperty(.{ .pty_mode = true });

    // A colour set in one chunk stays in effect for the next -- a program
    // that emits `ESC [ 31 m` then its text in separate `write()`s still
    // comes out red, where a default-mode layer would reset the pen
    // between the two.
    try layer.writeText("\x1b[31m", glyphwire.default_style.fg, glyphwire.default_style.bg);
    layer.cursor = .{ .row = 1, .col = 0 };
    try layer.writeText("still-red", glyphwire.default_style.fg, glyphwire.default_style.bg);
    try testz.expectEqual(layer.cell(1, 0).style.fg.r, 205);

    // Re-setting the property is the "program exited" re-arm: it drops
    // the lingering pen, so the following write is back to the default.
    layer.setProperty(.{ .pty_mode = true });
    layer.cursor = .{ .row = 2, .col = 0 };
    try layer.writeText("plain", glyphwire.default_style.fg, glyphwire.default_style.bg);
    try testz.expectEqual(layer.cell(2, 0).style.fg.r, glyphwire.default_style.fg.r);
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

    // An unhandled CSI (`ESC [ 99 z`) and a `>`-prefixed device query
    // that isn't a DA (`ESC [ > 1 m`) are still recognized and dropped --
    // none of their bytes are drawn and the cursor is untouched. (`?25` /
    // `6n` now *do* things -- see the DECTCEM and reply-path tests.)
    try layer.writeText("\x1b[99zA\x1b[>1mB", glyphwire.default_style.fg, glyphwire.default_style.bg);
    try testz.expectEqualStr("A", layer.cell(0, 0).grapheme());
    try testz.expectEqualStr("B", layer.cell(0, 1).grapheme());
    try testz.expectEqual(layer.cursor.col, 2);
}

// --- VT100 alternate charset (ACS line drawing) -----------------------------

pub fn writeTextInterpretsXtermStyleAcsCharsetTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var layer = try glyphwire.Layer.init(alloc, 20, 2, 0);
    defer layer.deinit();

    // xterm-style `smacs`/`rmacs`: redesignate G0 directly, no SO/SI.
    // While G0 is line drawing, "qql" draws horizontal-line, horizontal-
    // line, upper-left-corner; `ESC ( B` (`rmacs`) reverts G0 to ASCII so
    // the trailing "q" prints literally.
    try layer.writeText("\x1b(0qql\x1b(Bq", glyphwire.default_style.fg, glyphwire.default_style.bg);
    try testz.expectEqualStr("\u{2500}", layer.cell(0, 0).grapheme());
    try testz.expectEqualStr("\u{2500}", layer.cell(0, 1).grapheme());
    try testz.expectEqualStr("\u{250c}", layer.cell(0, 2).grapheme());
    try testz.expectEqualStr("q", layer.cell(0, 3).grapheme());
}

pub fn writeTextInterpretsScreenStyleAcsCharsetTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var layer = try glyphwire.Layer.init(alloc, 20, 2, 0);
    defer layer.deinit();

    // screen/tmux-style: designate G1 once (`ESC ) 0`), then shift in/out
    // with SO (0x0E) / SI (0x0F) around each run of line-drawing bytes.
    try layer.writeText("\x1b)0\x0ejkl\x0fm", glyphwire.default_style.fg, glyphwire.default_style.bg);
    try testz.expectEqualStr("\u{2518}", layer.cell(0, 0).grapheme());
    try testz.expectEqualStr("\u{2510}", layer.cell(0, 1).grapheme());
    try testz.expectEqualStr("\u{250c}", layer.cell(0, 2).grapheme());
    try testz.expectEqualStr("m", layer.cell(0, 3).grapheme());
}

pub fn acsCharsetDoesNotCarryAcrossCallsTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var layer = try glyphwire.Layer.init(alloc, 20, 2, 0);
    defer layer.deinit();

    // Designating G0 as line drawing and leaving it shifted in (no
    // `ESC ( B`) must not bleed into the next `writeText` call -- the
    // same call-scoped reset as the SGR pen and CSI machine (see
    // `EscState` / `writeTextSgrColourDoesNotCarryAcrossCallsTest`).
    try layer.writeText("\x1b(0", glyphwire.default_style.fg, glyphwire.default_style.bg);
    layer.cursor = .{ .row = 1, .col = 0 };
    try layer.writeText("q", glyphwire.default_style.fg, glyphwire.default_style.bg);
    try testz.expectEqualStr("q", layer.cell(1, 0).grapheme());
}

// --- B1 screen model: alt screen, DECTCEM, scroll region, IL/DL, ICH/DCH,
//     DECSC/DECRC, terminal query replies -------------------------------------

pub fn altScreenIsolatesContentAndCursorTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var layer = try glyphwire.Layer.init(alloc, 10, 3, 4);
    defer layer.deinit();

    try layer.writeText("primary\x1b[2;3HP", glyphwire.default_style.fg, glyphwire.default_style.bg);
    try testz.expectEqual(layer.cursor.row, 1);
    try testz.expectEqual(layer.cursor.col, 3);

    // Enter the alt screen: cleared, cursor homed, primary stashed.
    try layer.writeText("\x1b[?1049h", glyphwire.default_style.fg, glyphwire.default_style.bg);
    try testz.expectEqual(layer.on_alt, true);
    try testz.expectEqual(layer.cursor.row, 0);
    try testz.expectEqual(layer.cursor.col, 0);
    try testz.expectEqual(layer.cell(0, 0).grapheme().len, 0);

    try layer.writeText("ALT", glyphwire.default_style.fg, glyphwire.default_style.bg);
    try testz.expectEqualStr("A", layer.cell(0, 0).grapheme());

    // Back to primary: its content and cursor are exactly as they were.
    try layer.writeText("\x1b[?1049l", glyphwire.default_style.fg, glyphwire.default_style.bg);
    try testz.expectEqual(layer.on_alt, false);
    try testz.expectEqual(layer.cursor.row, 1);
    try testz.expectEqual(layer.cursor.col, 3);
    try testz.expectEqualStr("p", layer.cell(0, 0).grapheme());
    try testz.expectEqualStr("P", layer.cell(1, 2).grapheme());
}

pub fn altScreenHasNoScrollbackTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var layer = try glyphwire.Layer.init(alloc, 8, 2, 8);
    defer layer.deinit();

    try layer.writeText("\x1b[?1049h", glyphwire.default_style.fg, glyphwire.default_style.bg);
    // Three lines on a 2-row alt screen: the first is discarded, not
    // pushed into history.
    try layer.writeText("one\ntwo\nthree", glyphwire.default_style.fg, glyphwire.default_style.bg);
    try testz.expectEqual(layer.history_len, 0);
    try testz.expectEqualStr("t", layer.cell(0, 0).grapheme()); // "two"
    try testz.expectEqualStr("t", layer.cell(1, 0).grapheme()); // "three"
}

pub fn dectcemAndDecckmTrackModeStateTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var layer = try glyphwire.Layer.init(alloc, 10, 2, 0);
    defer layer.deinit();

    // DECTCEM (?25) -> cursor_visible.
    try testz.expectEqual(layer.cursor_visible, true);
    try layer.writeText("\x1b[?25l", glyphwire.default_style.fg, glyphwire.default_style.bg);
    try testz.expectEqual(layer.cursor_visible, false);
    try layer.writeText("\x1b[?25h", glyphwire.default_style.fg, glyphwire.default_style.bg);
    try testz.expectEqual(layer.cursor_visible, true);

    // DECCKM (?1) -> app_cursor_keys, read by the host to tell a
    // full-screen program owns the primary screen.
    try testz.expectEqual(layer.app_cursor_keys, false);
    try layer.writeText("\x1b[?1h", glyphwire.default_style.fg, glyphwire.default_style.bg);
    try testz.expectEqual(layer.app_cursor_keys, true);
    try layer.writeText("\x1b[?1l", glyphwire.default_style.fg, glyphwire.default_style.bg);
    try testz.expectEqual(layer.app_cursor_keys, false);
}

pub fn scrollRegionConfinesLineFeedTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var layer = try glyphwire.Layer.init(alloc, 6, 5, 6);
    defer layer.deinit();

    // Rows: 0 "AA", 1 "BB", 2 "CC", 3 "DD", 4 "EE".
    try layer.writeText("AA\nBB\nCC\nDD\nEE", glyphwire.default_style.fg, glyphwire.default_style.bg);
    // Region rows 2..4 (1-based 3;5), cursor homed inside it by DECSTBM.
    try layer.writeText("\x1b[3;5r", glyphwire.default_style.fg, glyphwire.default_style.bg);
    try testz.expectEqual(layer.scroll_top, 2);
    try testz.expectEqual(layer.scroll_bot, 4);
    try testz.expectEqual(layer.cursor.row, 2);

    // Move to the bottom margin and line-feed: rows 2..4 scroll up, rows
    // 0..1 and the scrollback are untouched.
    try layer.writeText("\x1b[5;1H\n", glyphwire.default_style.fg, glyphwire.default_style.bg);
    try testz.expectEqualStr("A", layer.cell(0, 0).grapheme());
    try testz.expectEqualStr("B", layer.cell(1, 0).grapheme());
    try testz.expectEqualStr("D", layer.cell(2, 0).grapheme()); // was row 3
    try testz.expectEqualStr("E", layer.cell(3, 0).grapheme()); // was row 4
    try testz.expectEqual(layer.cell(4, 0).grapheme().len, 0); // blanked
    try testz.expectEqual(layer.history_len, 0);
}

pub fn scrollUpDownAndReverseIndexTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var layer = try glyphwire.Layer.init(alloc, 4, 4, 0);
    defer layer.deinit();

    try layer.writeText("11\n22\n33\n44", glyphwire.default_style.fg, glyphwire.default_style.bg);
    // SU 1: everything moves up a row, bottom blanked.
    try layer.writeText("\x1b[S", glyphwire.default_style.fg, glyphwire.default_style.bg);
    try testz.expectEqualStr("2", layer.cell(0, 0).grapheme());
    try testz.expectEqual(layer.cell(3, 0).grapheme().len, 0);
    // SD 1: back down, top blanked.
    try layer.writeText("\x1b[T", glyphwire.default_style.fg, glyphwire.default_style.bg);
    try testz.expectEqual(layer.cell(0, 0).grapheme().len, 0);
    try testz.expectEqualStr("2", layer.cell(1, 0).grapheme());
    // RI at the top margin scrolls down too.
    try layer.writeText("\x1b[H\x1bM", glyphwire.default_style.fg, glyphwire.default_style.bg);
    try testz.expectEqual(layer.cell(0, 0).grapheme().len, 0);
    try testz.expectEqualStr("2", layer.cell(2, 0).grapheme());
}

pub fn moveContentShiftsBandInPlaceTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var layer = try glyphwire.Layer.init(alloc, 4, 5, 0);
    defer layer.deinit();

    try layer.writeText("11\n22\n33\n44\n55", glyphwire.default_style.fg, glyphwire.default_style.bg);
    const gen0 = layer.renderGeneration();

    // Whole grid up 2: rows climb, the bottom two blank.
    layer.moveContent(null, null, 2, .up);
    try testz.expectEqualStr("3", layer.cell(0, 0).grapheme());
    try testz.expectEqualStr("5", layer.cell(2, 0).grapheme());
    try testz.expectEqual(layer.cell(3, 0).grapheme().len, 0);
    try testz.expectEqual(layer.cell(4, 0).grapheme().len, 0);
    try testz.expectTrue(layer.renderGeneration() != gen0);

    // Back down 2: what's left slides back, the top two blank.
    layer.moveContent(null, null, 2, .down);
    try testz.expectEqual(layer.cell(0, 0).grapheme().len, 0);
    try testz.expectEqual(layer.cell(1, 0).grapheme().len, 0);
    try testz.expectEqualStr("3", layer.cell(2, 0).grapheme());

    // A bounded band leaves the rows outside it untouched.
    var band = try glyphwire.Layer.init(alloc, 4, 5, 0);
    defer band.deinit();
    try band.writeText("aa\nbb\ncc\ndd\nee", glyphwire.default_style.fg, glyphwire.default_style.bg);
    band.moveContent(1, 3, 1, .up);
    try testz.expectEqualStr("a", band.cell(0, 0).grapheme()); // outside the band
    try testz.expectEqualStr("c", band.cell(1, 0).grapheme());
    try testz.expectEqual(band.cell(3, 0).grapheme().len, 0); // blanked at bot
    try testz.expectEqualStr("e", band.cell(4, 0).grapheme()); // outside the band

    // Out of range / zero count: no-op, no crash.
    band.moveContent(2, 99, 1, .up);
    band.moveContent(null, null, 0, .up);
    try testz.expectEqualStr("a", band.cell(0, 0).grapheme());
}

pub fn insertAndDeleteLinesTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var layer = try glyphwire.Layer.init(alloc, 4, 4, 0);
    defer layer.deinit();

    try layer.writeText("aa\nbb\ncc\ndd", glyphwire.default_style.fg, glyphwire.default_style.bg);
    // Cursor to row 1 (0-based), insert one line: bb/cc/dd shift down, a
    // blank appears at row 1, dd falls off the bottom.
    try layer.writeText("\x1b[2;1H\x1b[L", glyphwire.default_style.fg, glyphwire.default_style.bg);
    try testz.expectEqualStr("a", layer.cell(0, 0).grapheme());
    try testz.expectEqual(layer.cell(1, 0).grapheme().len, 0);
    try testz.expectEqualStr("b", layer.cell(2, 0).grapheme());
    try testz.expectEqualStr("c", layer.cell(3, 0).grapheme());

    // Delete that blank line again: bb/cc climb back, bottom blanks.
    try layer.writeText("\x1b[M", glyphwire.default_style.fg, glyphwire.default_style.bg);
    try testz.expectEqualStr("b", layer.cell(1, 0).grapheme());
    try testz.expectEqualStr("c", layer.cell(2, 0).grapheme());
    try testz.expectEqual(layer.cell(3, 0).grapheme().len, 0);
}

pub fn ichDchEchWireToCellPrimitivesTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var layer = try glyphwire.Layer.init(alloc, 10, 2, 0);
    defer layer.deinit();

    try layer.writeText("abcdef\x1b[1;1H", glyphwire.default_style.fg, glyphwire.default_style.bg);
    // ICH 2 at col 0: "abcdef" -> "  abcdef" (clipped to width).
    try layer.writeText("\x1b[2@", glyphwire.default_style.fg, glyphwire.default_style.bg);
    try testz.expectEqual(layer.cell(0, 0).grapheme().len, 0);
    try testz.expectEqualStr("a", layer.cell(0, 2).grapheme());
    // DCH 2 at col 0: back to "abcdef".
    try layer.writeText("\x1b[2P", glyphwire.default_style.fg, glyphwire.default_style.bg);
    try testz.expectEqualStr("a", layer.cell(0, 0).grapheme());
    try testz.expectEqualStr("c", layer.cell(0, 2).grapheme());
    // ECH 3 at col 2: blanks 3 cells in place without shifting.
    try layer.writeText("\x1b[1;3H\x1b[3X", glyphwire.default_style.fg, glyphwire.default_style.bg);
    try testz.expectEqualStr("b", layer.cell(0, 1).grapheme());
    try testz.expectEqual(layer.cell(0, 2).grapheme().len, 0);
    try testz.expectEqual(layer.cell(0, 4).grapheme().len, 0);
    try testz.expectEqualStr("f", layer.cell(0, 5).grapheme());
}

pub fn decscDecrcSaveAndRestoreCursorTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var layer = try glyphwire.Layer.init(alloc, 10, 4, 0);
    defer layer.deinit();

    try layer.writeText("\x1b[2;4H\x1b7", glyphwire.default_style.fg, glyphwire.default_style.bg); // DECSC
    try layer.writeText("\x1b[4;9Hxx", glyphwire.default_style.fg, glyphwire.default_style.bg);
    try layer.writeText("\x1b8", glyphwire.default_style.fg, glyphwire.default_style.bg); // DECRC
    try testz.expectEqual(layer.cursor.row, 1);
    try testz.expectEqual(layer.cursor.col, 3);

    // `CSI u` restores the same save slot.
    try layer.writeText("\x1b[1;1H\x1b[u", glyphwire.default_style.fg, glyphwire.default_style.bg);
    try testz.expectEqual(layer.cursor.row, 1);
    try testz.expectEqual(layer.cursor.col, 3);
}

pub fn absoluteCursorMovesClampAndNeverScrollTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var layer = try glyphwire.Layer.init(alloc, 8, 4, 6);
    defer layer.deinit();

    try layer.writeText("r0\nr1\nr2\nr3", glyphwire.default_style.fg, glyphwire.default_style.bg);
    try testz.expectEqual(layer.history_len, 0);

    // A full-screen program parking on (and past) its last row -- e.g.
    // `less`'s status line -- must clamp, not push the layer into
    // scrollback a row at a time.
    try layer.writeText("\x1b[99;1H", glyphwire.default_style.fg, glyphwire.default_style.bg); // CUP past the bottom
    try layer.writeText("\x1b[50B", glyphwire.default_style.fg, glyphwire.default_style.bg); // CUD past the bottom
    try layer.writeText("\x1b[40d", glyphwire.default_style.fg, glyphwire.default_style.bg); // VPA past the bottom
    try testz.expectEqual(layer.cursor.row, 3);
    try testz.expectEqual(layer.history_len, 0); // nothing scrolled
    try testz.expectEqualStr("r", layer.cell(0, 0).grapheme()); // row 0 still "r0"
}

pub fn decstrSoftResetRestoresRegionAndCursorVisibleWithoutMovingTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var layer = try glyphwire.Layer.init(alloc, 10, 6, 0);
    defer layer.deinit();

    // A pager-ish state: scroll region set, cursor hidden, cursor parked
    // mid-screen, a cursor saved.
    try layer.writeText("\x1b[2;5r\x1b[?25l\x1b[4;3H\x1b7", glyphwire.default_style.fg, glyphwire.default_style.bg);
    try testz.expectEqual(layer.regionActive(), true);
    try testz.expectEqual(layer.cursor_visible, false);

    // `CSI ! p` (DECSTR): region back to full, caret shown, saved cursor
    // dropped -- but the cursor itself does NOT move and the screen isn't
    // cleared. This is what glyphwire-shell sends after a pty child exits.
    try layer.writeText("\x1b[!p", glyphwire.default_style.fg, glyphwire.default_style.bg);
    try testz.expectEqual(layer.regionActive(), false);
    try testz.expectEqual(layer.cursor_visible, true);
    try testz.expectEqual(layer.saved_cursor, null);
    // Cursor stayed where `\x1b[4;3H` put it (row 3, col 2).
    try testz.expectEqual(layer.cursor.row, 3);
    try testz.expectEqual(layer.cursor.col, 2);
}

pub fn terminalQueryRepliesAreQueuedTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var layer = try glyphwire.Layer.init(alloc, 40, 10, 0);
    defer layer.deinit();

    // CPR: reports the 1-based cursor position after the "hi".
    try layer.writeText("\x1b[3;5Hhi\x1b[6n", glyphwire.default_style.fg, glyphwire.default_style.bg);
    try testz.expectEqualStr("\x1b[3;7R", layer.takeReply().?);
    try testz.expectEqual(layer.takeReply(), null); // drained

    // Primary DA.
    try layer.writeText("\x1b[c", glyphwire.default_style.fg, glyphwire.default_style.bg);
    try testz.expectEqualStr("\x1b[?1;2c", layer.takeReply().?);

    // DECRQM for DECTCEM: 2 (reset) after hiding the cursor, 1 (set) after.
    try layer.writeText("\x1b[?25l\x1b[?25$p", glyphwire.default_style.fg, glyphwire.default_style.bg);
    try testz.expectEqualStr("\x1b[?25;2$y", layer.takeReply().?);
    try layer.writeText("\x1b[?25h\x1b[?25$p", glyphwire.default_style.fg, glyphwire.default_style.bg);
    try testz.expectEqualStr("\x1b[?25;1$y", layer.takeReply().?);
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

// --- East Asian wide characters -----------------------------------------

pub fn codepointWidthClassifiesWideAndNarrowTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    _ = alloc;
    try testz.expectEqual(glyphwire.codepointWidth('A'), @as(u2, 1));
    try testz.expectEqual(glyphwire.codepointWidth(' '), @as(u2, 1));
    try testz.expectEqual(glyphwire.codepointWidth(0x3042), @as(u2, 2)); // HIRAGANA A
    try testz.expectEqual(glyphwire.codepointWidth(0x4E16), @as(u2, 2)); // CJK 世
    try testz.expectEqual(glyphwire.codepointWidth(0x30AB), @as(u2, 2)); // KATAKANA KA
    try testz.expectEqual(glyphwire.codepointWidth(0xAC00), @as(u2, 2)); // Hangul GA
    // Ambiguous width is treated as narrow.
    try testz.expectEqual(glyphwire.codepointWidth(0x041F), @as(u2, 1)); // CYRILLIC PE
    try testz.expectEqual(glyphwire.codepointWidth(0x0393), @as(u2, 1)); // GREEK GAMMA
}

pub fn writeTextWideCharTakesTwoCellsTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var layer = try glyphwire.Layer.init(alloc, 80, 24, 0);
    defer layer.deinit();

    // "あい" -- two wide characters.
    try layer.writeText("\u{3042}\u{3044}", glyphwire.default_style.fg, glyphwire.default_style.bg);

    try testz.expectEqualStr("\u{3042}", layer.cell(0, 0).grapheme());
    try testz.expectEqual(layer.cell(0, 0).wide, glyphwire.CellWidth.wide_lead);
    try testz.expectEqual(layer.cell(0, 1).grapheme().len, @as(usize, 0));
    try testz.expectEqual(layer.cell(0, 1).wide, glyphwire.CellWidth.wide_spacer);
    try testz.expectEqualStr("\u{3044}", layer.cell(0, 2).grapheme());
    try testz.expectEqual(layer.cell(0, 2).wide, glyphwire.CellWidth.wide_lead);
    try testz.expectEqual(layer.cell(0, 3).wide, glyphwire.CellWidth.wide_spacer);

    try testz.expectEqual(layer.cursor.col, @as(usize, 4));
}

pub fn writeTextWideCharWrapsWhenItWontFitTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var layer = try glyphwire.Layer.init(alloc, 2, 2, 0);
    defer layer.deinit();

    // 'a' fills column 0; the wide "あ" needs two cells, can't fit column 1
    // alone, so it wraps to the next row.
    try layer.writeText("a\u{3042}", glyphwire.default_style.fg, glyphwire.default_style.bg);

    try testz.expectEqualStr("a", layer.cell(0, 0).grapheme());
    try testz.expectEqualStr("\u{3042}", layer.cell(1, 0).grapheme());
    try testz.expectEqual(layer.cell(1, 0).wide, glyphwire.CellWidth.wide_lead);
    try testz.expectEqual(layer.cell(1, 1).wide, glyphwire.CellWidth.wide_spacer);
    try testz.expectEqual(layer.cursor.row, @as(usize, 1));
    try testz.expectEqual(layer.cursor.col, @as(usize, 2));
}

pub fn writeTextOverwritingHalfAWideCharBlanksItsPartnerTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var layer = try glyphwire.Layer.init(alloc, 80, 24, 0);
    defer layer.deinit();

    try layer.writeText("\u{3042}\u{3044}", glyphwire.default_style.fg, glyphwire.default_style.bg);

    // Overwrite the spacer half of the first wide char with a narrow 'x'.
    layer.setProperty(.{ .cursor = .{ .row = 0, .col = 1 } });
    try layer.writeText("x", glyphwire.default_style.fg, glyphwire.default_style.bg);

    // The lead it belonged to is now a blank narrow cell, no orphan glyph.
    try testz.expectEqual(layer.cell(0, 0).grapheme().len, @as(usize, 0));
    try testz.expectEqual(layer.cell(0, 0).wide, glyphwire.CellWidth.narrow);
    try testz.expectEqualStr("x", layer.cell(0, 1).grapheme());
    try testz.expectEqual(layer.cell(0, 1).wide, glyphwire.CellWidth.narrow);
    // The second wide char is untouched.
    try testz.expectEqualStr("\u{3044}", layer.cell(0, 2).grapheme());
    try testz.expectEqual(layer.cell(0, 2).wide, glyphwire.CellWidth.wide_lead);
}

// ─── bundled icon naming ────────────────────────────────────────────────

/// `core.iconName` derives an icon's catalog name from its path under
/// `assets/icons/`: the path minus a trailing `.png` (case-insensitive),
/// or null for anything that isn't a `.png`. `glyphwire-host` walks the
/// tree at startup and registers every `.png` under this name -- there's
/// no hand-maintained manifest.
pub fn iconNameDerivesFromPathTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    _ = alloc;

    try testz.expectEqualStr("oxygen/folder", glyphwire.iconName("oxygen/folder.png").?);
    try testz.expectEqualStr("box/tl", glyphwire.iconName("box/tl.png").?);
    try testz.expectEqualStr("dialog/fill", glyphwire.iconName("dialog/fill.png").?);
    try testz.expectEqualStr("notify/info", glyphwire.iconName("notify/info.png").?);
    try testz.expectEqualStr("status/error", glyphwire.iconName("status/error.png").?);
    try testz.expectEqualStr("distro/arch", glyphwire.iconName("distro/arch.png").?);
    // A bare filename with no subdirectory is still a valid name.
    try testz.expectEqualStr("plain", glyphwire.iconName("plain.png").?);
    // Extension match is case-insensitive.
    try testz.expectEqualStr("oxygen/folder", glyphwire.iconName("oxygen/folder.PNG").?);

    // Non-`.png` files in the tree (READMEs, licenses) are skipped.
    try testz.expectTrue(glyphwire.iconName("oxygen/README.txt") == null);
    try testz.expectTrue(glyphwire.iconName("oxygen/OXYGEN-LICENSE.txt") == null);
    try testz.expectTrue(glyphwire.iconName("no-extension") == null);
    try testz.expectTrue(glyphwire.iconName("trailingdotpng") == null);
}

// ─── selection & clipboard ─────────────────────────────────────────────

/// A linear selection spanning three rows: the first row is clipped to
/// the start column, the last to the end column, the middle row is taken
/// whole, and each row's trailing blanks are trimmed. Rows join with
/// `\n`.
pub fn selectionTextSpansRowsLinearlyTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var layer = try glyphwire.Layer.init(alloc, 20, 6, 0);
    defer layer.deinit();

    try layer.writeText("abcdefgh\n", glyphwire.default_style.fg, glyphwire.default_style.bg);
    try layer.writeText("second line\n", glyphwire.default_style.fg, glyphwire.default_style.bg);
    try layer.writeText("third row here", glyphwire.default_style.fg, glyphwire.default_style.bg);

    // From row 0 col 2 ("cdefgh") through row 2 col 4 ("third"). All ends
    // are live-viewport rows, so `above` is 0/-1/-2.
    layer.setSelection(.{ .above = 0, .col = 2 }, .{ .above = -2, .col = 4 });

    const text = (try layer.selectionText(alloc)).?;
    defer alloc.free(text);
    try testz.expectEqualStr("cdefgh\nsecond line\nthird", text);
}

/// The selection endpoints can be given in either order -- `ordered`
/// sorts them into reading order before extraction.
pub fn selectionTextIsOrderIndependentTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var layer = try glyphwire.Layer.init(alloc, 20, 4, 0);
    defer layer.deinit();
    try layer.writeText("one\ntwo", glyphwire.default_style.fg, glyphwire.default_style.bg);

    // active end before anchor end in reading order.
    layer.setSelection(.{ .above = -1, .col = 3 }, .{ .above = 0, .col = 0 });
    const text = (try layer.selectionText(alloc)).?;
    defer alloc.free(text);
    try testz.expectEqualStr("one\ntwo", text);
}

/// A zero-width selection is "nothing selected" as far as text goes; a
/// cleared selection returns null.
pub fn selectionTextEmptyForZeroWidthTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var layer = try glyphwire.Layer.init(alloc, 10, 3, 0);
    defer layer.deinit();
    try layer.writeText("hello", glyphwire.default_style.fg, glyphwire.default_style.bg);

    layer.setSelection(.{ .above = 0, .col = 2 }, .{ .above = 0, .col = 2 });
    const text = (try layer.selectionText(alloc)).?;
    defer alloc.free(text);
    try testz.expectEqualStr("", text);

    layer.clearSelection();
    try testz.expectTrue((try layer.selectionText(alloc)) == null);
}

/// `selectionColRange` reports the selected span per row for the
/// renderer: clipped on the first/last row, full width between, null
/// outside.
pub fn selectionColRangeClipsEndsTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var layer = try glyphwire.Layer.init(alloc, 10, 5, 0);
    defer layer.deinit();

    layer.setSelection(.{ .above = 0, .col = 3 }, .{ .above = -2, .col = 6 });

    try testz.expectTrue(layer.selectionColRange(1) == null); // above the selection
    const first = layer.selectionColRange(0).?;
    try testz.expectEqual(first.start, 3);
    try testz.expectEqual(first.end, 10);
    const mid = layer.selectionColRange(-1).?;
    try testz.expectEqual(mid.start, 0);
    try testz.expectEqual(mid.end, 10);
    const last = layer.selectionColRange(-2).?;
    try testz.expectEqual(last.start, 0);
    try testz.expectEqual(last.end, 7); // end col + 1
    try testz.expectTrue(layer.selectionColRange(-3) == null); // below
}

/// A selection stays pinned to its content as fresh output scrolls rows
/// into history (`scrollOne` bumps both ends' `above`), and is dropped
/// once an end scrolls off the top of retained scrollback.
pub fn selectionFollowsScrollAndDropsOnEvictionTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var layer = try glyphwire.Layer.init(alloc, 10, 3, 2); // 2 rows scrollback
    defer layer.deinit();

    try layer.writeText("row0\nrow1", glyphwire.default_style.fg, glyphwire.default_style.bg);
    layer.setSelection(.{ .above = 0, .col = 0 }, .{ .above = 0, .col = 4 });

    // Two newlines past the bottom scroll once: the selected row is now
    // one row further above the viewport top.
    try layer.writeText("\n\n", glyphwire.default_style.fg, glyphwire.default_style.bg);
    try testz.expectEqual(layer.selection.?.anchor.above, 1);
    const text = (try layer.selectionText(alloc)).?;
    defer alloc.free(text);
    try testz.expectEqualStr("row0", text);

    // Enough further newlines evict that row from the 2-row scrollback.
    try layer.writeText("\n\n\n", glyphwire.default_style.fg, glyphwire.default_style.bg);
    try testz.expectTrue(layer.selection == null);
}

/// `resize` rebuilds the ring buffer, so it drops any selection.
pub fn selectionClearedByResizeTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var layer = try glyphwire.Layer.init(alloc, 10, 3, 0);
    defer layer.deinit();
    layer.setSelection(.{ .above = 0, .col = 0 }, .{ .above = 0, .col = 2 });
    try layer.resize(12, 4);
    try testz.expectTrue(layer.selection == null);
}

// ─── highlights ───────────────────────────────────────────────────────

/// `toggleHighlightId` flips membership; `isHighlighted` is the per-cell
/// test the renderer runs, and an untagged (`null`) cell is never hit.
pub fn highlightToggleAndMembershipTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var layer = try glyphwire.Layer.init(alloc, 10, 3, 0);
    defer layer.deinit();

    try testz.expectFalse(layer.isHighlighted(7));
    try testz.expectFalse(layer.isHighlighted(null));

    try layer.toggleHighlightId(7);
    try layer.toggleHighlightId(9);
    try testz.expectTrue(layer.isHighlighted(7));
    try testz.expectTrue(layer.isHighlighted(9));
    try testz.expectFalse(layer.isHighlighted(8));
    try testz.expectEqual(layer.highlighted_ids.items.len, 2);

    try layer.toggleHighlightId(7); // off again
    try testz.expectFalse(layer.isHighlighted(7));
    try testz.expectTrue(layer.isHighlighted(9));
    try testz.expectEqual(layer.highlighted_ids.items.len, 1);
}

/// `setHighlightIds` replaces the whole set; `clearHighlightIds` empties it.
pub fn highlightSetAndClearIdsTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var layer = try glyphwire.Layer.init(alloc, 10, 3, 0);
    defer layer.deinit();

    try layer.toggleHighlightId(1);
    try layer.setHighlightIds(&.{ 4, 5, 6 });
    try testz.expectEqual(layer.highlighted_ids.items.len, 3);
    try testz.expectFalse(layer.isHighlighted(1));
    try testz.expectTrue(layer.isHighlighted(5));

    layer.clearHighlightIds();
    try testz.expectEqual(layer.highlighted_ids.items.len, 0);
}

/// Highlights are keyed by metadata id, not rows, so a `resize` leaves the
/// set intact (the tagged cells keep their tags through the reflow).
pub fn highlightSurvivesResizeTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var layer = try glyphwire.Layer.init(alloc, 10, 3, 0);
    defer layer.deinit();
    try layer.setHighlightIds(&.{ 2, 3 });
    try layer.resize(12, 4);
    try testz.expectEqual(layer.highlighted_ids.items.len, 2);
    try testz.expectTrue(layer.isHighlighted(3));
}

/// `setClipboard` replaces the buffer and bumps the serial each call;
/// `clipboardText` reads it back.
pub fn contextClipboardBufferRoundTripsTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 10, 3, 0);
    defer ctx.deinit();

    try testz.expectEqualStr("", ctx.clipboardText());
    try testz.expectEqual(ctx.clipboard_serial, 0);

    try ctx.setClipboard("hello");
    try testz.expectEqualStr("hello", ctx.clipboardText());
    try testz.expectEqual(ctx.clipboard_serial, 1);

    try ctx.setClipboard("world!");
    try testz.expectEqualStr("world!", ctx.clipboardText());
    try testz.expectEqual(ctx.clipboard_serial, 2);
}

// ── Layer.render_gen (host static-batch invalidation) ────────────────
//
// `renderGeneration()` must move on *any* change that alters what the
// renderer composites -- a superset of `revision` (which is cell content
// only). glyphwire-host caches a quad batch per layer and rebuilds only
// when this counter has moved (see host/render.zig).

pub fn renderGenBumpsOnContentWriteTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var layer = try glyphwire.Layer.init(alloc, 20, 4, 4);
    defer layer.deinit();

    const g0 = layer.renderGeneration();
    try layer.writeText("hi", glyphwire.default_style.fg, glyphwire.default_style.bg);
    try testz.expectTrue(layer.renderGeneration() != g0);

    const g1 = layer.renderGeneration();
    layer.clear(0, 0, 1, 2);
    try testz.expectTrue(layer.renderGeneration() != g1);
}

pub fn renderGenBumpsOnViewAndResizeTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var layer = try glyphwire.Layer.init(alloc, 6, 2, 8);
    defer layer.deinit();
    // Build some history so `scrollView` has room to move.
    try layer.writeText("abcdefghijklmnop", glyphwire.default_style.fg, glyphwire.default_style.bg);

    const g0 = layer.renderGeneration();
    _ = layer.scrollView(2, null);
    try testz.expectTrue(layer.renderGeneration() != g0);

    const g1 = layer.renderGeneration();
    try layer.resize(10, 3);
    try testz.expectTrue(layer.renderGeneration() != g1);
}

pub fn renderGenBumpsOnCursorPropertyTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var layer = try glyphwire.Layer.init(alloc, 20, 4, 0);
    defer layer.deinit();

    const g0 = layer.renderGeneration();
    layer.setProperty(.{ .cursor = .{ .row = 1, .col = 3 } });
    try testz.expectTrue(layer.renderGeneration() != g0);
}

pub fn renderGenBumpsOnSelectionAndHighlightTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var layer = try glyphwire.Layer.init(alloc, 20, 4, 0);
    defer layer.deinit();

    const g0 = layer.renderGeneration();
    layer.setSelection(.{ .above = 0, .col = 0 }, .{ .above = 0, .col = 4 });
    try testz.expectTrue(layer.renderGeneration() != g0);

    const g1 = layer.renderGeneration();
    layer.updateSelectionActive(.{ .above = 0, .col = 6 });
    try testz.expectTrue(layer.renderGeneration() != g1);

    const g2 = layer.renderGeneration();
    layer.clearSelection();
    try testz.expectTrue(layer.renderGeneration() != g2);

    const g3 = layer.renderGeneration();
    try layer.setHighlightIds(&.{ 1, 2 });
    try testz.expectTrue(layer.renderGeneration() != g3);

    const g4 = layer.renderGeneration();
    try layer.toggleHighlightId(1);
    try testz.expectTrue(layer.renderGeneration() != g4);

    const g5 = layer.renderGeneration();
    layer.clearHighlightIds();
    try testz.expectTrue(layer.renderGeneration() != g5);
}

pub fn renderGenStableAcrossPureReadsTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var layer = try glyphwire.Layer.init(alloc, 8, 3, 4);
    defer layer.deinit();
    try layer.writeText("abcdefgh", glyphwire.default_style.fg, glyphwire.default_style.bg);

    const g0 = layer.renderGeneration();
    _ = layer.viewRow(0, 0);
    _ = layer.getProperty(.revision);
    _ = layer.getProperty(.cursor);
    _ = layer.capacity();
    _ = layer.renderGeneration();
    _ = layer.selectionColRange(0);
    // A no-op `updateSelectionActive` (nothing selected) must not bump.
    layer.updateSelectionActive(.{ .above = 0, .col = 2 });
    try testz.expectEqual(layer.renderGeneration(), g0);
}

// ─── Layer geometry, visibility and stacking ────────────────────────────

pub fn setLayerSizeResizesAndTakesOverLayoutTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 40, 20, 0);
    defer ctx.deinit();

    // Created with no explicit size, so it was tracking the context...
    const pane = try ctx.createLayer(null, null, 0);
    try testz.expectTrue(ctx.layerPtr(pane).?.tracks_context_size);

    // ...until the client sets its own size, which is the client saying
    // it owns the layout from here on.
    try ctx.setLayerProperty(pane, .{ .size = .{ .cols = 12, .rows = 20 } });
    try testz.expectEqual(ctx.layerPtr(pane).?.width, 12);
    try testz.expectFalse(ctx.layerPtr(pane).?.tracks_context_size);

    try ctx.resize(60, 30);
    try testz.expectEqual(ctx.layerPtr(pane).?.width, 12);
    try testz.expectEqual(ctx.layerPtr(pane).?.height, 20);
}

pub fn setLayerSizeClampsDegenerateDimensionsTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 40, 20, 0);
    defer ctx.deinit();
    const pane = try ctx.createLayer(10, 10, 0);

    try ctx.setLayerProperty(pane, .{ .size = .{ .cols = 0, .rows = 0 } });
    try testz.expectEqual(ctx.layerPtr(pane).?.width, 1);
    try testz.expectEqual(ctx.layerPtr(pane).?.height, 1);
}

pub fn rootRefusesSizeAndVisibilityWritesTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 40, 20, 0);
    defer ctx.deinit();

    // The host owns the window size, and a hidden root would blank the
    // session with no wire path back.
    try testz.expectError(ctx.setLayerProperty(null, .{ .size = .{ .cols = 5, .rows = 5 } }), error.ReadOnlyProperty);
    try testz.expectError(ctx.setLayerProperty(null, .{ .visibility = false }), error.ReadOnlyProperty);
    try testz.expectEqual(ctx.root.width, 40);
    try testz.expectTrue(ctx.root.visible);
}

pub fn layerVisibilityTogglesWithoutLosingContentTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 40, 20, 0);
    defer ctx.deinit();
    const tree = try ctx.createLayer(20, 20, 0);

    const layer = ctx.layerPtr(tree).?;
    try layer.writeText("src/", glyphwire.default_style.fg, glyphwire.default_style.bg);

    try ctx.setLayerProperty(tree, .{ .visibility = false });
    try testz.expectFalse((try ctx.getLayerProperty(tree, .visibility)).visibility);
    // Hiding is a compositing decision, not a destruction: the cells stay.
    try testz.expectEqualStr(ctx.layerPtr(tree).?.cell(0, 0).grapheme(), "s");

    try ctx.setLayerProperty(tree, .{ .visibility = true });
    try testz.expectTrue((try ctx.getLayerProperty(tree, .visibility)).visibility);
}

pub fn cellPositionResolvesAgainstCellMetricsTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 40, 20, 0);
    defer ctx.deinit();
    ctx.setCellMetrics(10, 20);

    const pane = try ctx.createLayer(20, 20, 0);
    try ctx.setLayerProperty(pane, .{ .cell_position = .{ .row = 2, .col = 3 } });
    try testz.expectEqual(ctx.layerPtr(pane).?.pos.x, 30.0);
    try testz.expectEqual(ctx.layerPtr(pane).?.pos.y, 40.0);

    // A font-size change re-derives it, so the layer keeps its column
    // instead of drifting off the grid.
    ctx.setCellMetrics(14, 28);
    try testz.expectEqual(ctx.layerPtr(pane).?.pos.x, 42.0);
    try testz.expectEqual(ctx.layerPtr(pane).?.pos.y, 56.0);

    const cell = (try ctx.getLayerProperty(pane, .cell_position)).cell_position;
    try testz.expectEqual(cell.row, 2);
    try testz.expectEqual(cell.col, 3);
}

pub fn pixelPositionUnsticksCellPlacementTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 40, 20, 0);
    defer ctx.deinit();
    ctx.setCellMetrics(10, 20);

    const pane = try ctx.createLayer(20, 20, 0);
    try ctx.setLayerProperty(pane, .{ .cell_position = .{ .row = 1, .col = 1 } });
    try ctx.setLayerProperty(pane, .{ .position = .{ .x = 7, .y = 9 } });

    ctx.setCellMetrics(20, 40);
    try testz.expectEqual(ctx.layerPtr(pane).?.pos.x, 7.0);

    // A pixel-placed layer still answers `cell_position`, with the cell
    // its corner lands in.
    const cell = (try ctx.getLayerProperty(pane, .cell_position)).cell_position;
    try testz.expectEqual(cell.row, 0);
    try testz.expectEqual(cell.col, 0);
}

pub fn raiseAndLowerLayerRestackTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 40, 20, 0);
    defer ctx.deinit();

    const a = try ctx.createLayer(4, 4, 0);
    const b = try ctx.createLayer(4, 4, 0);
    const c = try ctx.createLayer(4, 4, 0);
    try testz.expectEqual(ctx.layer_order.items[0], a);
    try testz.expectEqual(ctx.layer_order.items[2], c);

    // To the top, then to the bottom.
    try ctx.raiseLayer(a, null);
    try testz.expectEqual(ctx.layer_order.items[2], a);
    try ctx.lowerLayer(a, null);
    try testz.expectEqual(ctx.layer_order.items[0], a);

    // Directly above a named layer.
    try ctx.raiseLayer(a, b);
    try testz.expectEqual(ctx.layer_order.items[0], b);
    try testz.expectEqual(ctx.layer_order.items[1], a);
    try testz.expectEqual(ctx.layer_order.items[2], c);

    // Below a named layer.
    try ctx.lowerLayer(c, b);
    try testz.expectEqual(ctx.layer_order.items[0], c);
}

pub fn restackingRejectsUnknownHandlesIntactTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 40, 20, 0);
    defer ctx.deinit();
    const a = try ctx.createLayer(4, 4, 0);
    const b = try ctx.createLayer(4, 4, 0);

    // The root is never in the stacking order, so it's unknown here.
    try testz.expectError(ctx.raiseLayer(glyphwire.root_layer_handle, null), error.UnknownLayer);
    try testz.expectError(ctx.raiseLayer(a, 999), error.UnknownLayer);

    // A rejected restack leaves the order exactly as it was.
    try testz.expectEqual(ctx.layer_order.items.len, 2);
    try testz.expectEqual(ctx.layer_order.items[0], a);
    try testz.expectEqual(ctx.layer_order.items[1], b);

    // Raising a layer above itself is a no-op, not an error.
    try ctx.raiseLayer(a, a);
    try testz.expectEqual(ctx.layer_order.items[0], a);
}

// ─── Layer viewport and scroll offset ───────────────────────────────────

pub fn viewportDefaultsToTheWholeContentGridTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var layer = try glyphwire.Layer.init(alloc, 40, 10, 0);
    defer layer.deinit();

    // Every layer that predates viewports behaves as one covering all of
    // its content: nothing to scroll, no offset.
    try testz.expectEqual(layer.viewportCols(), 40);
    try testz.expectEqual(layer.viewportRows(), 10);
    try testz.expectFalse(layer.scrollsAnywhere());
    try testz.expectEqual(layer.maxScroll().row, 0);
    try testz.expectEqual(layer.maxScroll().col, 0);
}

pub fn viewportClampsToTheContentTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var layer = try glyphwire.Layer.init(alloc, 40, 10, 0);
    defer layer.deinit();

    // A viewport bigger than the content is pointless, so it's clamped --
    // there's no scrolling into blank space.
    layer.setProperty(.{ .viewport = .{ .cols = 100, .rows = 100 } });
    try testz.expectEqual(layer.viewportCols(), 40);
    try testz.expectEqual(layer.viewportRows(), 10);
    try testz.expectFalse(layer.scrollsAnywhere());
}

pub fn viewportSmallerThanContentScrollsTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    // A file tree: 90 columns of names, 500 entries, shown 30x40 at a time.
    var layer = try glyphwire.Layer.init(alloc, 90, 500, 0);
    defer layer.deinit();
    layer.setProperty(.{ .viewport = .{ .cols = 30, .rows = 40 } });

    try testz.expectTrue(layer.scrollsAnywhere());
    try testz.expectEqual(layer.maxScroll().row, 460);
    try testz.expectEqual(layer.maxScroll().col, 60);
}

pub fn scrollOffsetClampsToMaxTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var layer = try glyphwire.Layer.init(alloc, 90, 500, 0);
    defer layer.deinit();
    layer.setProperty(.{ .viewport = .{ .cols = 30, .rows = 40 } });

    const landed = layer.setScrollOffset(.{ .row = 9999, .col = 9999 });
    try testz.expectEqual(landed.row, 460);
    try testz.expectEqual(landed.col, 60);
    try testz.expectEqual(layer.scroll_off.row, 460);
}

pub fn scrollOffsetBySaturatesAtBothEndsTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var layer = try glyphwire.Layer.init(alloc, 20, 100, 0);
    defer layer.deinit();
    layer.setProperty(.{ .viewport = .{ .cols = 20, .rows = 10 } });

    _ = layer.scrollOffsetBy(5, 0);
    try testz.expectEqual(layer.scroll_off.row, 5);
    // Past the top is 0, not a wrap into a huge usize.
    _ = layer.scrollOffsetBy(-50, 0);
    try testz.expectEqual(layer.scroll_off.row, 0);
    _ = layer.scrollOffsetBy(1000, 0);
    try testz.expectEqual(layer.scroll_off.row, 90);
}

pub fn shrinkingContentReclampsScrollTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var layer = try glyphwire.Layer.init(alloc, 20, 100, 0);
    defer layer.deinit();
    layer.setProperty(.{ .viewport = .{ .cols = 20, .rows = 10 } });
    _ = layer.setScrollOffset(.{ .row = 90 });

    // The content shrank under the viewport; the offset can't stay past
    // the end of it.
    try layer.resize(20, 30);
    try testz.expectEqual(layer.scroll_off.row, 20);

    // Same when the viewport grows instead.
    layer.setProperty(.{ .viewport = .{ .cols = 20, .rows = 25 } });
    try testz.expectEqual(layer.scroll_off.row, 5);
}

pub fn contentExtentDrivesAVirtualScrollbarTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    // A self-scrolling pane: the real grid is only the viewport size, but
    // it reports a much taller virtual content.
    var layer = try glyphwire.Layer.init(alloc, 30, 20, 0);
    defer layer.deinit();
    try testz.expectFalse(layer.scrollsAnywhere()); // grid == viewport

    layer.setProperty(.{ .content_extent = .{ .cols = 30, .rows = 1000 } });
    try testz.expectTrue(layer.scrollsAnywhere());
    try testz.expectEqual(layer.maxScroll().row, 980);

    // The offset moves the *virtual* position, not the real grid.
    const landed = layer.setScrollOffset(.{ .row = 5000, .col = 0 });
    try testz.expectEqual(landed.row, 980);
    try testz.expectEqual(layer.content_off.row, 980);
    try testz.expectEqual(layer.scroll_off.row, 0);
    try testz.expectEqual(layer.scrollbarState().row, 980);
    try testz.expectEqual(layer.getProperty(.scroll_offset).scroll_offset.row, 980);
    try testz.expectEqual(layer.getProperty(.content_extent).content_extent.rows, 1000);

    // Clearing it drops back to an ordinary pane and zeroes the virtual
    // offset.
    layer.setProperty(.{ .content_extent = .{ .cols = 0, .rows = 0 } });
    try testz.expectFalse(layer.scrollsAnywhere());
    try testz.expectEqual(layer.content_off.row, 0);
    try testz.expectEqual(layer.getProperty(.content_extent).content_extent.rows, 20);
}

pub fn scrollbarStateReportsDerivedMaximaTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var layer = try glyphwire.Layer.init(alloc, 50, 200, 0);
    defer layer.deinit();
    layer.setProperty(.{ .viewport = .{ .cols = 20, .rows = 20 } });
    layer.setProperty(.{ .scrollbars = .{
        .vertical = true,
        .horizontal = false,
        .row = 0,
        .col = 0,
        .max_row = 0,
        .max_col = 0,
    } });
    _ = layer.setScrollOffset(.{ .row = 7, .col = 3 });

    const st = layer.scrollbarState();
    try testz.expectTrue(st.vertical);
    try testz.expectFalse(st.horizontal);
    try testz.expectEqual(st.row, 7);
    try testz.expectEqual(st.col, 3);
    // Derived, never taken from what the client sent.
    try testz.expectEqual(st.max_row, 180);
    try testz.expectEqual(st.max_col, 30);
}

// ─── Split layout ───────────────────────────────────────────────────────

/// The pane arrangement zoe uses: a tree beside a buffer, with a
/// one-row statusline underneath both.
fn buildEditorLayout(ctx: *glyphwire.Context) !struct {
    root: glyphwire.SplitHandle,
    panes: glyphwire.SplitHandle,
    tree: glyphwire.LayerHandle,
    buffer: glyphwire.LayerHandle,
    status: glyphwire.LayerHandle,
} {
    const tree = try ctx.createLayer(30, 200, 0);
    const buffer = try ctx.createLayer(200, 500, 0);
    const status = try ctx.createLayer(200, 1, 0);

    const panes = try ctx.createSplit(.row);
    try ctx.setSplitChildren(panes, &.{
        .{ .target = .{ .layer = tree }, .size = .{ .fixed = 20 } },
        .{ .target = .{ .layer = buffer }, .size = .{ .weight = 1 } },
    });

    const root = try ctx.createSplit(.column);
    try ctx.setSplitChildren(root, &.{
        .{ .target = .{ .split = panes }, .size = .{ .weight = 1 } },
        .{ .target = .{ .layer = status }, .size = .{ .fixed = 1 } },
    });
    try ctx.setRootSplit(root);

    return .{ .root = root, .panes = panes, .tree = tree, .buffer = buffer, .status = status };
}

pub fn splitLayoutPlacesPanesTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 100, 40, 0);
    defer ctx.deinit();
    const l = try buildEditorLayout(&ctx);

    var changed: std.ArrayList(glyphwire.LayerBounds) = .empty;
    defer changed.deinit(alloc);
    try ctx.layoutSplits(&changed, null);

    // Column split: the fixed 1-row statusline is measured first, the
    // nested row split takes the other 38 (one row goes to the divider).
    const status = ctx.layerPtr(l.status).?;
    try testz.expectEqual(status.pos_cells.?.row, 39);
    try testz.expectEqual(status.viewportRows(), 1);
    try testz.expectEqual(status.viewportCols(), 100);

    // Row split: a fixed 20-column tree, a divider, then the rest.
    const tree = ctx.layerPtr(l.tree).?;
    try testz.expectEqual(tree.pos_cells.?.col, 0);
    try testz.expectEqual(tree.viewportCols(), 20);
    try testz.expectEqual(tree.viewportRows(), 38);

    const buffer = ctx.layerPtr(l.buffer).?;
    try testz.expectEqual(buffer.pos_cells.?.col, 21);
    try testz.expectEqual(buffer.viewportCols(), 79);
    try testz.expectEqual(buffer.viewportRows(), 38);

    try testz.expectEqual(changed.items.len, 3);
}

pub fn splitLayoutIsIdempotentTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 100, 40, 0);
    defer ctx.deinit();
    _ = try buildEditorLayout(&ctx);

    var first: std.ArrayList(glyphwire.LayerBounds) = .empty;
    defer first.deinit(alloc);
    try ctx.layoutSplits(&first, null);
    try testz.expectEqual(first.items.len, 3);

    // Re-running with nothing changed reports nothing -- what makes it
    // safe for the host to re-walk the tree for divider geometry alone.
    var second: std.ArrayList(glyphwire.LayerBounds) = .empty;
    defer second.deinit(alloc);
    try ctx.layoutSplits(&second, null);
    try testz.expectEqual(second.items.len, 0);
}

pub fn splitLayoutFollowsAWindowResizeTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 100, 40, 0);
    defer ctx.deinit();
    const l = try buildEditorLayout(&ctx);
    try ctx.layoutSplits(null, null);

    try ctx.resize(60, 20);
    var changed: std.ArrayList(glyphwire.LayerBounds) = .empty;
    defer changed.deinit(alloc);
    try ctx.layoutSplits(&changed, null);

    const status = ctx.layerPtr(l.status).?;
    try testz.expectEqual(status.pos_cells.?.row, 19);
    try testz.expectEqual(status.viewportCols(), 60);

    // The fixed tree keeps its 20 columns; the weighted buffer absorbs
    // the loss, which is the whole point of the two sizing modes.
    try testz.expectEqual(ctx.layerPtr(l.tree).?.viewportCols(), 20);
    try testz.expectEqual(ctx.layerPtr(l.buffer).?.viewportCols(), 39);
}

pub fn splitDividersAreReportedTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 100, 40, 0);
    defer ctx.deinit();
    _ = try buildEditorLayout(&ctx);

    var dividers: std.ArrayList(glyphwire.DividerRect) = .empty;
    defer dividers.deinit(alloc);
    try ctx.layoutSplits(null, &dividers);

    // One per split with two children: the vertical band between tree and
    // buffer, and the horizontal one above the statusline.
    try testz.expectEqual(dividers.items.len, 2);

    var vertical_cols: usize = 0;
    var horizontal_rows: usize = 0;
    for (dividers.items) |d| switch (d.axis) {
        .row => {
            vertical_cols = d.rect.col;
            try testz.expectEqual(d.rect.cols, 1);
            try testz.expectEqual(d.rect.rows, 38);
        },
        .column => {
            horizontal_rows = d.rect.row;
            try testz.expectEqual(d.rect.rows, 1);
            try testz.expectEqual(d.rect.cols, 100);
        },
    };
    try testz.expectEqual(vertical_cols, 20);
    try testz.expectEqual(horizontal_rows, 38);
}

pub fn moveDividerResizesAFixedPaneTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 100, 40, 0);
    defer ctx.deinit();
    const l = try buildEditorLayout(&ctx);
    try ctx.layoutSplits(null, null);

    // Dragging the tree/buffer divider right by 6 cells: the tree is
    // `fixed`, so its cell count changes and the weighted buffer absorbs
    // the difference.
    try ctx.moveDivider(l.panes, 0, 6);
    try ctx.layoutSplits(null, null);
    try testz.expectEqual(ctx.layerPtr(l.tree).?.viewportCols(), 26);
    try testz.expectEqual(ctx.layerPtr(l.buffer).?.viewportCols(), 73);
}

pub fn moveDividerKeepsCombinedWeightTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 100, 10, 0);
    defer ctx.deinit();
    const left = try ctx.createLayer(200, 10, 0);
    const right = try ctx.createLayer(200, 10, 0);

    const split = try ctx.createSplit(.row);
    try ctx.setSplitChildren(split, &.{
        .{ .target = .{ .layer = left }, .size = .{ .weight = 1 } },
        .{ .target = .{ .layer = right }, .size = .{ .weight = 1 } },
    });
    try ctx.setRootSplit(split);
    try ctx.layoutSplits(null, null);

    // 99 usable columns, split evenly: 49 / 50.
    try testz.expectEqual(ctx.layerPtr(left).?.viewportCols(), 49);

    try ctx.moveDivider(split, 0, 20);
    try ctx.layoutSplits(null, null);
    const l_cols = ctx.layerPtr(left).?.viewportCols();
    const r_cols = ctx.layerPtr(right).?.viewportCols();
    try testz.expectEqual(l_cols, 69);
    // The pair still fills the split exactly -- the combined weight was
    // preserved, so nothing leaked out to the rest of the tree.
    try testz.expectEqual(l_cols + r_cols, 99);
}

pub fn moveDividerWontSqueezeAPaneToNothingTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 100, 10, 0);
    defer ctx.deinit();
    const left = try ctx.createLayer(200, 10, 0);
    const right = try ctx.createLayer(200, 10, 0);

    const split = try ctx.createSplit(.row);
    try ctx.setSplitChildren(split, &.{
        .{ .target = .{ .layer = left }, .size = .{ .fixed = 20 } },
        .{ .target = .{ .layer = right }, .size = .{ .weight = 1 } },
    });
    try ctx.setRootSplit(split);
    try ctx.layoutSplits(null, null);

    // A pane dragged to zero could never be grabbed back, so the drag
    // stops one cell short of that at each end.
    try ctx.moveDivider(split, 0, -500);
    try ctx.layoutSplits(null, null);
    try testz.expectEqual(ctx.layerPtr(left).?.viewportCols(), 1);

    try ctx.moveDivider(split, 0, 500);
    try ctx.layoutSplits(null, null);
    try testz.expectEqual(ctx.layerPtr(right).?.viewportCols(), 1);
}

pub fn destroyingTheRootSplitDropsTheLayoutTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 100, 40, 0);
    defer ctx.deinit();
    const l = try buildEditorLayout(&ctx);
    try ctx.layoutSplits(null, null);

    try ctx.destroySplit(l.root);
    try testz.expectTrue(ctx.root_split == null);

    // The layers survive their container, keeping the bounds they had --
    // a destroyed split frees the arrangement, not the panes.
    try testz.expectEqual(ctx.layerPtr(l.status).?.viewportRows(), 1);
    try testz.expectTrue(ctx.layerPtr(l.tree) != null);

    // And laying out again does nothing at all.
    var changed: std.ArrayList(glyphwire.LayerBounds) = .empty;
    defer changed.deinit(alloc);
    try ctx.layoutSplits(&changed, null);
    try testz.expectEqual(changed.items.len, 0);
}

pub fn splitRejectsUnknownHandlesTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 100, 40, 0);
    defer ctx.deinit();

    try testz.expectError(ctx.setRootSplit(77), error.UnknownSplit);
    try testz.expectError(ctx.destroySplit(77), error.UnknownSplit);
    try testz.expectError(ctx.setSplitChildren(77, &.{}), error.UnknownSplit);
    try testz.expectTrue(ctx.root_split == null);
}

pub fn splitCycleStopsAtTheDepthCapTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 100, 40, 0);
    defer ctx.deinit();

    // A split containing itself: the layout walk has to terminate rather
    // than recurse until the stack runs out.
    const split = try ctx.createSplit(.row);
    try ctx.setSplitChildren(split, &.{.{ .target = .{ .split = split } }});
    try ctx.setRootSplit(split);
    try ctx.layoutSplits(null, null);
    try testz.expectTrue(ctx.splits.getPtr(split).?.laid_out);
}

pub fn nonResizableSplitReservesNoGapAndEmitsNoDividerTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 100, 40, 0);
    defer ctx.deinit();
    const body = try ctx.createLayer(100, 40, 0);
    const status = try ctx.createLayer(100, 1, 0);

    const split = try ctx.createSplit(.column);
    ctx.splits.getPtr(split).?.resizable = false;
    try ctx.setSplitChildren(split, &.{
        .{ .target = .{ .layer = body }, .size = .{ .weight = 1 } },
        .{ .target = .{ .layer = status }, .size = .{ .fixed = 1 } },
    });
    try ctx.setRootSplit(split);

    var dividers: std.ArrayList(glyphwire.DividerRect) = .empty;
    defer dividers.deinit(alloc);
    try ctx.layoutSplits(null, &dividers);

    // No `divider_cells` gap: the body takes all 40 rows bar the fixed
    // one-row status line, where a resizable split would have left it 38.
    try testz.expectEqual(ctx.layerPtr(body).?.viewportRows(), 39);
    try testz.expectEqual(ctx.layerPtr(status).?.viewportRows(), 1);
    // And nothing draggable was produced.
    try testz.expectEqual(dividers.items.len, 0);
}

pub fn moveDividerNoOpsOnNonResizableSplitTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 100, 40, 0);
    defer ctx.deinit();
    const body = try ctx.createLayer(100, 40, 0);
    const status = try ctx.createLayer(100, 1, 0);

    const split = try ctx.createSplit(.column);
    ctx.splits.getPtr(split).?.resizable = false;
    try ctx.setSplitChildren(split, &.{
        .{ .target = .{ .layer = body }, .size = .{ .weight = 1 } },
        .{ .target = .{ .layer = status }, .size = .{ .fixed = 1 } },
    });
    try ctx.setRootSplit(split);
    try ctx.layoutSplits(null, null);

    // The drag is silently ignored -- the split has no bands to move.
    try ctx.moveDivider(split, 0, -10);
    try ctx.layoutSplits(null, null);
    try testz.expectEqual(ctx.layerPtr(body).?.viewportRows(), 39);
    try testz.expectEqual(ctx.layerPtr(status).?.viewportRows(), 1);
}

// ── Layer ownership & lifecycle culling (see `core.ConnId`) ──────────────

pub fn addLayerOwnerThenHasOwnerTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 20, 5, 0);
    defer ctx.deinit();

    const h = try ctx.createLayer(null, null, 0);
    // A freshly created layer has no connection owner yet.
    try testz.expectTrue(!ctx.layerHasOwner(h, 1));

    try ctx.addLayerOwner(h, 1);
    try testz.expectTrue(ctx.layerHasOwner(h, 1));
    try testz.expectTrue(!ctx.layerHasOwner(h, 2));

    // The root handle is never connection-owned.
    try testz.expectTrue(!ctx.layerHasOwner(glyphwire.root_layer_handle, 1));
    // Neither is an unknown handle.
    try testz.expectTrue(!ctx.layerHasOwner(999, 1));
}

pub fn addLayerOwnerUnknownHandleErrorsTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 20, 5, 0);
    defer ctx.deinit();

    try testz.expectError(ctx.addLayerOwner(999, 1), error.UnknownLayer);
    // The root layer has no lifecycle and can't be owned.
    try testz.expectError(ctx.addLayerOwner(glyphwire.root_layer_handle, 1), error.UnknownLayer);
}

pub fn removeConnectionOwnershipCullsSoleOwnedLayerTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 20, 5, 0);
    defer ctx.deinit();

    const h = try ctx.createLayer(null, null, 0);
    try ctx.addLayerOwner(h, 7);

    var culled: std.ArrayList(glyphwire.LayerHandle) = .empty;
    defer culled.deinit(alloc);

    // A different connection closing leaves the layer alone.
    try ctx.removeConnectionOwnership(8, &culled);
    try testz.expectEqual(culled.items.len, 0);
    try testz.expectTrue(ctx.layerPtr(h) != null);

    // The owning connection closing culls it.
    try ctx.removeConnectionOwnership(7, &culled);
    try testz.expectEqual(culled.items.len, 1);
    try testz.expectEqual(culled.items[0], h);
    try testz.expectTrue(ctx.layerPtr(h) == null);
}

pub fn removeConnectionOwnershipKeepsLayerWithRemainingOwnerTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 20, 5, 0);
    defer ctx.deinit();

    const h = try ctx.createLayer(null, null, 0);
    try ctx.addLayerOwner(h, 1);
    try ctx.addLayerOwner(h, 2);

    var culled: std.ArrayList(glyphwire.LayerHandle) = .empty;
    defer culled.deinit(alloc);

    try ctx.removeConnectionOwnership(1, &culled);
    try testz.expectEqual(culled.items.len, 0);
    try testz.expectTrue(ctx.layerPtr(h) != null);

    try ctx.removeConnectionOwnership(2, &culled);
    try testz.expectEqual(culled.items.len, 1);
    try testz.expectTrue(ctx.layerPtr(h) == null);
}

pub fn removeConnectionOwnershipLeavesInProcessLayersAloneTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 20, 5, 0);
    defer ctx.deinit();

    // Created in-process: no `addLayerOwner`, so never connection-owned.
    const h = try ctx.createLayer(null, null, 0);

    var culled: std.ArrayList(glyphwire.LayerHandle) = .empty;
    defer culled.deinit(alloc);

    try ctx.removeConnectionOwnership(1, &culled);
    try ctx.removeConnectionOwnership(2, &culled);
    try testz.expectEqual(culled.items.len, 0);
    try testz.expectTrue(ctx.layerPtr(h) != null);
}

// ── Session: multi-context registry + visibility stack (see core.Session) ──

pub fn sessionStartsWithOnlyTheRootContextVisibleTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var root = try glyphwire.Context.init(alloc, 40, 10, 0);
    defer root.deinit();
    var session = try glyphwire.Session.init(alloc, &root);
    defer session.deinit();

    try testz.expectEqual(session.focusedContextHandle(), glyphwire.root_context_handle);
    try testz.expectEqual(session.focusedContext(), &root);
    try testz.expectEqual(session.rootContext(), &root);
}

pub fn sessionCreateContextShowsItAndDefaultsToRootSizeTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var root = try glyphwire.Context.init(alloc, 40, 10, 0);
    defer root.deinit();
    var session = try glyphwire.Session.init(alloc, &root);
    defer session.deinit();

    const before_gen = session.visible_gen.load(.monotonic);
    const h = try session.createContext(glyphwire.root_pane_handle, null, null, 0);
    try testz.expectTrue(h != glyphwire.root_context_handle);
    try testz.expectEqual(session.focusedContextHandle(), h);
    try testz.expectTrue(session.visible_gen.load(.monotonic) != before_gen);

    const ctx = session.contextPtr(h).?;
    try testz.expectEqual(ctx.root.width, @as(usize, 40));
    try testz.expectEqual(ctx.root.height, @as(usize, 10));
    try testz.expectEqual(ctx.asset_fallback, &root);
}

pub fn sessionCreatedContextInheritsRootIconCatalogViaFallbackTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var root = try glyphwire.Context.init(alloc, 20, 5, 0);
    defer root.deinit();
    try root.images.put(7, .{ .bytes = try alloc.dupe(u8, "x"), .format = .png, .width = 1, .height = 1 });
    try root.registerIcon("folder", 7);

    var session = try glyphwire.Session.init(alloc, &root);
    defer session.deinit();
    const h = try session.createContext(glyphwire.root_pane_handle, null, null, 0);
    const ctx = session.contextPtr(h).?;

    try testz.expectEqual(ctx.iconHandle("folder").?, @as(glyphwire.ImageHandle, 7));
    try testz.expectEqual(ctx.imageEntry(7).?.width, @as(u32, 1));
    try testz.expectTrue(ctx.iconHandle("missing") == null);
}

pub fn sessionActivateMovesAnExistingContextToTheTopTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var root = try glyphwire.Context.init(alloc, 20, 5, 0);
    defer root.deinit();
    var session = try glyphwire.Session.init(alloc, &root);
    defer session.deinit();

    const a = try session.createContext(glyphwire.root_pane_handle, null, null, 0);
    const b = try session.createContext(glyphwire.root_pane_handle, null, null, 0);
    try testz.expectEqual(session.focusedContextHandle(), b);

    try session.activateContext(a);
    try testz.expectEqual(session.focusedContextHandle(), a);
    try testz.expectTrue(session.contextPtr(b) != null);

    try session.activateContext(a); // already visible: no-op, not an error
    try testz.expectEqual(session.focusedContextHandle(), a);

    try testz.expectError(session.activateContext(999), glyphwire.ContextError.UnknownContext);
}

pub fn sessionDestroyVisibleContextFallsBackToWhatWasUnderItTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var root = try glyphwire.Context.init(alloc, 20, 5, 0);
    defer root.deinit();
    var session = try glyphwire.Session.init(alloc, &root);
    defer session.deinit();

    const a = try session.createContext(glyphwire.root_pane_handle, null, null, 0);
    const b = try session.createContext(glyphwire.root_pane_handle, null, null, 0);
    try testz.expectEqual(session.focusedContextHandle(), b);

    try session.destroyContext(b);
    try testz.expectEqual(session.focusedContextHandle(), a);
    try testz.expectTrue(session.contextPtr(b) == null);

    try session.destroyContext(a);
    try testz.expectEqual(session.focusedContextHandle(), glyphwire.root_context_handle);
}

pub fn sessionDestroyRootContextIsRefusedTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var root = try glyphwire.Context.init(alloc, 20, 5, 0);
    defer root.deinit();
    var session = try glyphwire.Session.init(alloc, &root);
    defer session.deinit();

    try testz.expectError(session.destroyContext(glyphwire.root_context_handle), glyphwire.ContextError.RootContextImmutable);
    try testz.expectError(session.destroyContext(999), glyphwire.ContextError.UnknownContext);
}

pub fn sessionReapConnectionCullsContextsThatConnectionSolelyOwnedTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var root = try glyphwire.Context.init(alloc, 20, 5, 0);
    defer root.deinit();
    var session = try glyphwire.Session.init(alloc, &root);
    defer session.deinit();

    const a = try session.createContext(glyphwire.root_pane_handle, null, null, 0);
    try session.addContextOwner(a, 1);
    const b = try session.createContext(glyphwire.root_pane_handle, null, null, 0);
    try session.addContextOwner(b, 1);
    try session.addContextOwner(b, 2);

    var culled: std.ArrayList(glyphwire.ContextHandle) = .empty;
    defer culled.deinit(alloc);
    var culled_panes: std.ArrayList(glyphwire.PaneHandle) = .empty;
    defer culled_panes.deinit(alloc);

    try session.reapConnection(1, &culled, &culled_panes);
    try testz.expectEqual(culled.items.len, 1);
    try testz.expectEqual(culled.items[0], a);
    try testz.expectTrue(session.contextPtr(a) == null);
    try testz.expectTrue(session.contextPtr(b) != null);
    try testz.expectEqual(session.focusedContextHandle(), b);

    culled.clearRetainingCapacity();
    try session.reapConnection(2, &culled, &culled_panes);
    try testz.expectEqual(culled.items.len, 1);
    try testz.expectTrue(session.contextPtr(b) == null);
    try testz.expectEqual(session.focusedContextHandle(), glyphwire.root_context_handle);
}

pub fn sessionReapConnectionLeavesTheRootContextAloneTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var root = try glyphwire.Context.init(alloc, 20, 5, 0);
    defer root.deinit();
    var session = try glyphwire.Session.init(alloc, &root);
    defer session.deinit();

    var culled: std.ArrayList(glyphwire.ContextHandle) = .empty;
    defer culled.deinit(alloc);
    var culled_panes: std.ArrayList(glyphwire.PaneHandle) = .empty;
    defer culled_panes.deinit(alloc);
    try session.reapConnection(1, &culled, &culled_panes);
    try session.reapConnection(2, &culled, &culled_panes);
    try testz.expectEqual(culled.items.len, 0);
    try testz.expectEqual(session.focusedContextHandle(), glyphwire.root_context_handle);
}

pub fn sessionResizeWindowCatchesUpEveryContextTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var root = try glyphwire.Context.init(alloc, 40, 10, 0);
    defer root.deinit();
    var session = try glyphwire.Session.init(alloc, &root);
    defer session.deinit();

    const bg = try session.createContext(glyphwire.root_pane_handle, null, null, 0);
    _ = try session.createContext(glyphwire.root_pane_handle, null, null, 0); // the visible one

    try session.resizeWindow(30, 8);
    try testz.expectEqual(root.root.width, @as(usize, 30));
    try testz.expectEqual(root.root.height, @as(usize, 8));
    try testz.expectEqual(session.contextPtr(bg).?.root.width, @as(usize, 30));
    try testz.expectEqual(session.contextPtr(bg).?.root.height, @as(usize, 8));
}

// ─── adjacentMetadataSpan: Ctrl+PgUp/PgDn scrollback-span navigation ────

pub fn adjacentMetadataSpanNextSkipsCurrentSpanToNextIdTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var layer = try glyphwire.Layer.init(alloc, 20, 3, 0);
    defer layer.deinit();
    const fg = glyphwire.default_style.fg;

    // Row 0: cols 0-3 tagged 1 ("aaa " -- trailing space still id 1), cols
    // 4-6 tagged 2 ("bbb").
    try layer.writeTextTagged("aaa ", fg, null, 1);
    try layer.writeTextTagged("bbb", fg, null, 2);

    const hit = layer.adjacentMetadataSpan(0, 0, .next).?;
    try testz.expectEqual(hit.above, @as(i64, 0));
    try testz.expectEqual(hit.col, @as(usize, 4));
    try testz.expectEqual(hit.id, @as(glyphwire.MetadataHandle, 2));

    // Nothing tagged past span 2.
    try testz.expectTrue(layer.adjacentMetadataSpan(0, 5, .next) == null);
}

pub fn adjacentMetadataSpanPrevLandsOnSpanFirstCharacterTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var layer = try glyphwire.Layer.init(alloc, 20, 3, 0);
    defer layer.deinit();
    const fg = glyphwire.default_style.fg;

    try layer.writeTextTagged("aaa ", fg, null, 1);
    try layer.writeTextTagged("bbb", fg, null, 2);

    // From the middle of span 2, `.prev` walks back over span 2 to the
    // first cell of span 1.
    const hit = layer.adjacentMetadataSpan(0, 6, .prev).?;
    try testz.expectEqual(hit.above, @as(i64, 0));
    try testz.expectEqual(hit.col, @as(usize, 0));
    try testz.expectEqual(hit.id, @as(glyphwire.MetadataHandle, 1));

    try testz.expectTrue(layer.adjacentMetadataSpan(0, 0, .prev) == null);
}

pub fn adjacentMetadataSpanSkipsLeadingIconAndPaddingCellsTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var layer = try glyphwire.Layer.init(alloc, 20, 3, 0);
    defer layer.deinit();
    const fg = glyphwire.default_style.fg;

    // Span 1 is a single "x"; span 2 leads with two blank cells (an icon /
    // padding stand-in) before its first real character at col 3.
    try layer.writeTextTagged("x", fg, null, 1);
    try layer.writeTextTagged("  y", fg, null, 2);

    const hit = layer.adjacentMetadataSpan(0, 0, .next).?;
    try testz.expectEqual(hit.col, @as(usize, 3));
    try testz.expectEqual(hit.id, @as(glyphwire.MetadataHandle, 2));
}

pub fn adjacentMetadataSpanTreatsGappedSameIdRunAsOneSpanTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var layer = try glyphwire.Layer.init(alloc, 20, 3, 0);
    defer layer.deinit();
    const fg = glyphwire.default_style.fg;

    // A `gw-ls -l` style row: one id spread across two runs ("drwx" then
    // "file") with an untagged separator cell between, then a second entry.
    try layer.writeTextTagged("drwx", fg, null, 1);
    try layer.writeTextTagged(" ", fg, null, null); // col 4, untagged gap
    try layer.writeTextTagged("file", fg, null, 1); // cols 5-8, still id 1
    try layer.writeTextTagged(" ", fg, null, null); // col 9, untagged gap
    try layer.writeTextTagged("next", fg, null, 2); // cols 10-13

    // From inside the "file" run, `.next` steps over the whole id-1 group
    // (gap included) to id 2.
    const fwd = layer.adjacentMetadataSpan(0, 6, .next).?;
    try testz.expectEqual(fwd.col, @as(usize, 10));
    try testz.expectEqual(fwd.id, @as(glyphwire.MetadataHandle, 2));

    // From span 2, `.prev` walks back across the gap to the very first
    // cell of the id-1 group.
    const back = layer.adjacentMetadataSpan(0, 12, .prev).?;
    try testz.expectEqual(back.col, @as(usize, 0));
    try testz.expectEqual(back.id, @as(glyphwire.MetadataHandle, 1));
}

pub fn adjacentMetadataSpanWalksIntoRetainedScrollbackTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var layer = try glyphwire.Layer.init(alloc, 3, 2, 4);
    defer layer.deinit();
    const fg = glyphwire.default_style.fg;

    // Each 3-char write fills a row and wraps; the wrap past the bottom
    // scrolls the oldest row into history. End state: viewport row 0 =
    // "ccc" (id 3), row 1 = "ddd" (id 4); history "bbb" (id 2) one row
    // above the viewport, "aaa" (id 1) two rows above.
    try layer.writeTextTagged("aaa", fg, null, 1);
    try layer.writeTextTagged("bbb", fg, null, 2);
    try layer.writeTextTagged("ccc", fg, null, 3);
    try layer.writeTextTagged("ddd", fg, null, 4);

    // `.prev` from the bottom viewport row steps up one span at a time,
    // crossing from the viewport into retained scrollback. `above` is the
    // scroll-stable coordinate: 0 in the viewport, positive into history.
    const s3 = layer.adjacentMetadataSpan(-1, 0, .prev).?;
    try testz.expectEqual(s3.above, @as(i64, 0));
    try testz.expectEqual(s3.id, @as(glyphwire.MetadataHandle, 3));

    const s2 = layer.adjacentMetadataSpan(0, 0, .prev).?;
    try testz.expectEqual(s2.above, @as(i64, 1));
    try testz.expectEqual(s2.id, @as(glyphwire.MetadataHandle, 2));

    const s1 = layer.adjacentMetadataSpan(1, 0, .prev).?;
    try testz.expectEqual(s1.above, @as(i64, 2));
    try testz.expectEqual(s1.id, @as(glyphwire.MetadataHandle, 1));

    // Oldest retained span -- nothing further back.
    try testz.expectTrue(layer.adjacentMetadataSpan(2, 0, .prev) == null);

    // And `.next` climbs back down out of history.
    const down = layer.adjacentMetadataSpan(2, 0, .next).?;
    try testz.expectEqual(down.above, @as(i64, 1));
    try testz.expectEqual(down.id, @as(glyphwire.MetadataHandle, 2));
}

pub fn adjacentMetadataSpanReturnsNullWhenNothingTaggedTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var layer = try glyphwire.Layer.init(alloc, 20, 3, 0);
    defer layer.deinit();
    try layer.writeText("plain untagged text", glyphwire.default_style.fg, null);

    try testz.expectTrue(layer.adjacentMetadataSpan(0, 0, .next) == null);
    try testz.expectTrue(layer.adjacentMetadataSpan(0, 5, .prev) == null);
}
