const std = @import("std");
const testz = @import("testz");
const glyphwire = @import("glyphwire");
const wire = glyphwire.wire;
const dispatch = glyphwire.dispatch;

/// Frames `body` and feeds it through a `FrameDecoder`, returning the
/// decoded body. Exercises wire framing + reassembly the way a real
/// in-process harness would, without a real socket (Milestone 3).
fn roundTripThroughWire(alloc: std.mem.Allocator, body: []const u8) ![]u8 {
    var aw = std.Io.Writer.Allocating.init(alloc);
    defer aw.deinit();
    try wire.writeFrame(&aw.writer, body);

    var decoder: wire.FrameDecoder = .{};
    defer decoder.deinit(alloc);
    try decoder.feed(alloc, aw.writer.buffered());

    return (try decoder.next(alloc)).?;
}

pub fn writeTextNotificationUpdatesCoreStateTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 80, 24, 0);
    defer ctx.deinit();
    var d = dispatch.Dispatcher.init(&ctx);

    const message =
        \\{"jsonrpc":"2.0","method":"write_text","params":{"text":"hello"}}
    ;
    const decoded = try roundTripThroughWire(alloc, message);
    defer alloc.free(decoded);

    const response = try d.handle(alloc, decoded);
    try testz.expectTrue(response == null);

    try testz.expectEqualStr("h", ctx.root.cell(0, 0).grapheme());
    try testz.expectEqualStr("o", ctx.root.cell(0, 4).grapheme());
    try testz.expectEqual(ctx.root.cursor.row, 0);
    try testz.expectEqual(ctx.root.cursor.col, 5);
}

pub fn getPropertyRequestReturnsDecodedResponseTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 80, 24, 0);
    defer ctx.deinit();
    var d = dispatch.Dispatcher.init(&ctx);

    const write_msg =
        \\{"jsonrpc":"2.0","method":"write_text","params":{"text":"hello"}}
    ;
    const write_decoded = try roundTripThroughWire(alloc, write_msg);
    defer alloc.free(write_decoded);
    try testz.expectTrue(try d.handle(alloc, write_decoded) == null);

    const get_msg =
        \\{"jsonrpc":"2.0","id":1,"method":"get_property","params":{"property":"cursor"}}
    ;
    const get_decoded = try roundTripThroughWire(alloc, get_msg);
    defer alloc.free(get_decoded);

    const response_body = (try d.handle(alloc, get_decoded)).?;
    defer alloc.free(response_body);

    // Frame the response and decode it back, proving the response side of
    // the wire round trip too, not just the request side.
    const response_decoded = try roundTripThroughWire(alloc, response_body);
    defer alloc.free(response_decoded);

    const Response = struct {
        id: i64,
        result: struct { row: usize, col: usize },
    };
    const parsed = try std.json.parseFromSlice(Response, alloc, response_decoded, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    try testz.expectEqual(parsed.value.id, 1);
    try testz.expectEqual(parsed.value.result.row, 0);
    try testz.expectEqual(parsed.value.result.col, 5);
}

pub fn setPropertyNotificationMovesCursorTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 80, 24, 0);
    defer ctx.deinit();
    var d = dispatch.Dispatcher.init(&ctx);

    const message =
        \\{"jsonrpc":"2.0","method":"set_property","params":{"property":"cursor","row":3,"col":7}}
    ;
    const decoded = try roundTripThroughWire(alloc, message);
    defer alloc.free(decoded);

    try testz.expectTrue(try d.handle(alloc, decoded) == null);
    try testz.expectEqual(ctx.root.cursor.row, 3);
    try testz.expectEqual(ctx.root.cursor.col, 7);
}

pub fn revisionPropertyBumpsOnWriteTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 80, 24, 0);
    defer ctx.deinit();
    var d = dispatch.Dispatcher.init(&ctx);

    const get_msg =
        \\{"jsonrpc":"2.0","id":1,"method":"get_property","params":{"property":"revision"}}
    ;

    const before_body = (try d.handle(alloc, get_msg)).?;
    defer alloc.free(before_body);
    const Response = struct { id: i64, result: struct { revision: u64 } };
    const before = try std.json.parseFromSlice(Response, alloc, before_body, .{ .ignore_unknown_fields = true });
    defer before.deinit();
    try testz.expectEqual(before.value.result.revision, 0);

    const write_msg =
        \\{"jsonrpc":"2.0","method":"write_text","params":{"text":"hi"}}
    ;
    try testz.expectTrue(try d.handle(alloc, write_msg) == null);

    const after_body = (try d.handle(alloc, get_msg)).?;
    defer alloc.free(after_body);
    const after = try std.json.parseFromSlice(Response, alloc, after_body, .{ .ignore_unknown_fields = true });
    defer after.deinit();
    try testz.expectEqual(after.value.result.revision, 1);
}

pub fn getCellsRequestReturnsGridSnapshotTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 10, 3, 0);
    defer ctx.deinit();
    var d = dispatch.Dispatcher.init(&ctx);

    const write_msg =
        \\{"jsonrpc":"2.0","method":"write_text","params":{"text":"hi","fg":{"r":0,"g":255,"b":255},"bg":{"r":40,"g":40,"b":90}}}
    ;
    try testz.expectTrue(try d.handle(alloc, write_msg) == null);

    const get_cells_msg =
        \\{"jsonrpc":"2.0","id":1,"method":"get_cells","params":{}}
    ;
    const response_body = (try d.handle(alloc, get_cells_msg)).?;
    defer alloc.free(response_body);

    const CellJson = struct { g: []const u8, fg: struct { r: u8, g: u8, b: u8, a: u8 }, bg: ?struct { r: u8, g: u8, b: u8, a: u8 } };
    const Response = struct {
        id: i64,
        result: struct { cols: usize, rows: usize, revision: u64, cells: []CellJson },
    };
    const parsed = try std.json.parseFromSlice(Response, alloc, response_body, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    try testz.expectEqual(parsed.value.result.cols, 10);
    try testz.expectEqual(parsed.value.result.rows, 3);
    try testz.expectEqual(parsed.value.result.revision, 1);
    try testz.expectEqual(parsed.value.result.cells.len, 30);

    const h = parsed.value.result.cells[0];
    try testz.expectEqualStr("h", h.g);
    try testz.expectEqual(h.fg.g, 255);
    try testz.expectEqual(h.fg.b, 255);
    try testz.expectEqual(h.bg.?.r, 40);
    try testz.expectEqual(h.bg.?.b, 90);

    // Untouched cell still reports the default style.
    const blank = parsed.value.result.cells[2];
    try testz.expectEqualStr("", blank.g);
}

pub fn unknownMethodErrorsTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 80, 24, 0);
    defer ctx.deinit();
    var d = dispatch.Dispatcher.init(&ctx);

    const message =
        \\{"jsonrpc":"2.0","method":"draw_image","params":{}}
    ;
    try testz.expectError(d.handle(alloc, message), dispatch.DispatchError.UnknownMethod);
}
