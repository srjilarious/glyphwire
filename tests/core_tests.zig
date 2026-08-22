const std = @import("std");
const testz = @import("testz");
const glyphwire = @import("glyphwire");

pub fn writeTextAdvancesCursorTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var layer = try glyphwire.Layer.init(alloc, 80, 24);
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
    var layer = try glyphwire.Layer.init(alloc, 80, 24);
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
    var layer = try glyphwire.Layer.init(alloc, 3, 2);
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
    var layer = try glyphwire.Layer.init(alloc, 80, 24);
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
    var ctx = try glyphwire.Context.init(alloc, 80, 24);
    defer ctx.deinit();

    try testz.expectEqual(ctx.root.width, 80);
    try testz.expectEqual(ctx.root.height, 24);
    try testz.expectEqual(ctx.root.cursor.row, 0);
    try testz.expectEqual(ctx.root.cursor.col, 0);
}
