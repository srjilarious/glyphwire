const std = @import("std");
const testz = @import("testz");
const glyphwire = @import("glyphwire");

pub fn writeTextAdvancesCursorTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var layer = try glyphwire.Layer.init(alloc, 80, 24, 0);
    defer layer.deinit();

    try layer.writeText("hello", glyphwire.default_style);

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
    try layer.writeText("h", style);

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
        .image => return error.TestUnexpectedResult,
    }
}

pub fn writeTextWrapsAtLayerEdgeTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var layer = try glyphwire.Layer.init(alloc, 3, 2, 0);
    defer layer.deinit();

    try layer.writeText("hello", glyphwire.default_style);

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

    try layer.writeText("hello", glyphwire.default_style);

    const before = layer.getProperty(.cursor);
    try testz.expectEqual(before.cursor.row, 0);
    try testz.expectEqual(before.cursor.col, 5);

    layer.setProperty(.{ .cursor = .{ .row = 3, .col = 7 } });

    const after = layer.getProperty(.cursor);
    try testz.expectEqual(after.cursor.row, 3);
    try testz.expectEqual(after.cursor.col, 7);
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

    try layer.writeText("abcdefghij", glyphwire.default_style);

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

    try layer.writeText("abcdefghij", glyphwire.default_style);

    try testz.expectEqualStr("g", layer.cell(0, 0).grapheme());
    try testz.expectEqualStr("j", layer.cell(1, 0).grapheme());
    try testz.expectTrue(layer.scrollbackRow(0) == null);
}

pub fn insertCellsShiftsRowRightTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var layer = try glyphwire.Layer.init(alloc, 10, 5, 0);
    defer layer.deinit();

    try layer.writeText("hello", glyphwire.default_style);
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

    try layer.writeText("abcde", glyphwire.default_style);
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

    try layer.writeText("hello", glyphwire.default_style);
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

    try layer.writeText("abcde", glyphwire.default_style);
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
