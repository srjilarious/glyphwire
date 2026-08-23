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

    const result = try d.handle(alloc, decoded);
    try testz.expectTrue(result.response == null);

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
    try testz.expectTrue((try d.handle(alloc, write_decoded)).response == null);

    const get_msg =
        \\{"jsonrpc":"2.0","id":1,"method":"get_property","params":{"property":"cursor"}}
    ;
    const get_decoded = try roundTripThroughWire(alloc, get_msg);
    defer alloc.free(get_decoded);

    const response_body = (try d.handle(alloc, get_decoded)).response.?;
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

    try testz.expectTrue((try d.handle(alloc, decoded)).response == null);
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

    const before_body = (try d.handle(alloc, get_msg)).response.?;
    defer alloc.free(before_body);
    const Response = struct { id: i64, result: struct { revision: u64 } };
    const before = try std.json.parseFromSlice(Response, alloc, before_body, .{ .ignore_unknown_fields = true });
    defer before.deinit();
    try testz.expectEqual(before.value.result.revision, 0);

    const write_msg =
        \\{"jsonrpc":"2.0","method":"write_text","params":{"text":"hi"}}
    ;
    try testz.expectTrue((try d.handle(alloc, write_msg)).response == null);

    const after_body = (try d.handle(alloc, get_msg)).response.?;
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
    try testz.expectTrue((try d.handle(alloc, write_msg)).response == null);

    const get_cells_msg =
        \\{"jsonrpc":"2.0","id":1,"method":"get_cells","params":{}}
    ;
    const response_body = (try d.handle(alloc, get_cells_msg)).response.?;
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

pub fn reportKeyUpdatesInputStateAndQueuesBroadcastTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 80, 24, 0);
    defer ctx.deinit();
    var d = dispatch.Dispatcher.init(&ctx);

    const press_msg =
        \\{"jsonrpc":"2.0","method":"report_key","params":{"key":"a","pressed":true}}
    ;
    const press_result = try d.handle(alloc, press_msg);
    try testz.expectTrue(press_result.response == null);
    try testz.expectTrue(ctx.input.isKeyDown("a"));

    const broadcast = press_result.broadcast.?;
    defer alloc.free(broadcast.body);
    try testz.expectEqualStr("key", broadcast.event);
    try testz.expectTrue(std.mem.indexOf(u8, broadcast.body, "key_down") != null);

    // A redundant press-while-down report changes nothing, so it queues
    // no broadcast -- avoids spamming subscribers with no-op events.
    const redundant_result = try d.handle(alloc, press_msg);
    try testz.expectTrue(redundant_result.broadcast == null);

    const release_msg =
        \\{"jsonrpc":"2.0","method":"report_key","params":{"key":"a","pressed":false}}
    ;
    const release_result = try d.handle(alloc, release_msg);
    try testz.expectTrue(!ctx.input.isKeyDown("a"));
    const release_broadcast = release_result.broadcast.?;
    defer alloc.free(release_broadcast.body);
    try testz.expectTrue(std.mem.indexOf(u8, release_broadcast.body, "key_up") != null);
}

pub fn subscribeThenGetInputStateReflectsReportedInputTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 80, 24, 0);
    defer ctx.deinit();
    var d = dispatch.Dispatcher.init(&ctx);

    const sub_msg =
        \\{"jsonrpc":"2.0","id":1,"method":"subscribe","params":{"events":["key","mouse_button"]}}
    ;
    const sub_result = try d.handle(alloc, sub_msg);
    defer alloc.free(sub_result.response.?);
    try testz.expectTrue(d.subscriptions.key);
    try testz.expectTrue(d.subscriptions.mouse_button);

    const key_msg =
        \\{"jsonrpc":"2.0","method":"report_key","params":{"key":"space","pressed":true}}
    ;
    const key_result = try d.handle(alloc, key_msg);
    alloc.free(key_result.broadcast.?.body);

    const mouse_msg =
        \\{"jsonrpc":"2.0","method":"report_mouse_button","params":{"button":"left","pressed":true,"px":{"x":12.5,"y":30.0},"cell":{"row":2,"col":1}}}
    ;
    const mouse_result = try d.handle(alloc, mouse_msg);
    alloc.free(mouse_result.broadcast.?.body);

    const get_msg =
        \\{"jsonrpc":"2.0","id":2,"method":"get_input_state","params":{}}
    ;
    const get_result = try d.handle(alloc, get_msg);
    defer alloc.free(get_result.response.?);

    const Response = struct {
        id: i64,
        result: struct {
            keys_down: [][]const u8,
            mouse_buttons_down: [][]const u8,
            cursor_px: struct { x: f32, y: f32 },
            cursor_cell: struct { row: usize, col: usize },
        },
    };
    const parsed = try std.json.parseFromSlice(Response, alloc, get_result.response.?, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    try testz.expectEqual(parsed.value.result.keys_down.len, 1);
    try testz.expectEqualStr("space", parsed.value.result.keys_down[0]);
    try testz.expectEqual(parsed.value.result.mouse_buttons_down.len, 1);
    try testz.expectEqualStr("left", parsed.value.result.mouse_buttons_down[0]);
    try testz.expectEqual(parsed.value.result.cursor_cell.row, 2);
    try testz.expectEqual(parsed.value.result.cursor_cell.col, 1);
}

pub fn insertCellsNotificationShiftsRowTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 10, 5, 0);
    defer ctx.deinit();
    var d = dispatch.Dispatcher.init(&ctx);

    try ctx.root.writeText("hello", glyphwire.default_style);
    ctx.root.setProperty(.{ .cursor = .{ .row = 0, .col = 1 } });

    const message =
        \\{"jsonrpc":"2.0","method":"insert_cells","params":{"count":1}}
    ;
    try testz.expectTrue((try d.handle(alloc, message)).response == null);

    try testz.expectEqualStr("h", ctx.root.cell(0, 0).grapheme());
    try testz.expectEqual(ctx.root.cell(0, 1).grapheme().len, 0);
    try testz.expectEqualStr("e", ctx.root.cell(0, 2).grapheme());
}

pub fn deleteCellsNotificationShiftsRowTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 10, 5, 0);
    defer ctx.deinit();
    var d = dispatch.Dispatcher.init(&ctx);

    try ctx.root.writeText("hello", glyphwire.default_style);
    ctx.root.setProperty(.{ .cursor = .{ .row = 0, .col = 1 } });

    const message =
        \\{"jsonrpc":"2.0","method":"delete_cells","params":{"count":1}}
    ;
    try testz.expectTrue((try d.handle(alloc, message)).response == null);

    try testz.expectEqualStr("h", ctx.root.cell(0, 0).grapheme());
    try testz.expectEqualStr("l", ctx.root.cell(0, 1).grapheme());
    try testz.expectEqualStr("l", ctx.root.cell(0, 2).grapheme());
    try testz.expectEqualStr("o", ctx.root.cell(0, 3).grapheme());
    try testz.expectEqual(ctx.root.cell(0, 4).grapheme().len, 0);
}

pub fn unknownMethodErrorsTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 80, 24, 0);
    defer ctx.deinit();
    var d = dispatch.Dispatcher.init(&ctx);

    const message =
        \\{"jsonrpc":"2.0","method":"not_a_real_method","params":{}}
    ;
    try testz.expectError(d.handle(alloc, message), dispatch.DispatchError.UnknownMethod);
}

/// Same fixture as core_tests.zig's -- a minimal byte stream `pngDimensions`
/// accepts, not a real decodable PNG.
fn fakePngBytes(width: u32, height: u32) [24]u8 {
    var bytes: [24]u8 = undefined;
    @memcpy(bytes[0..8], &[_]u8{ 0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n' });
    std.mem.writeInt(u32, bytes[8..12], 13, .big);
    @memcpy(bytes[12..16], "IHDR");
    std.mem.writeInt(u32, bytes[16..20], width, .big);
    std.mem.writeInt(u32, bytes[20..24], height, .big);
    return bytes;
}

pub fn peekLoadImageExtractsHeaderTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    const message =
        \\{"jsonrpc":"2.0","id":7,"method":"load_image","params":{"format":"png","bytes":24}}
    ;
    const hdr = (try dispatch.peekLoadImage(alloc, message)).?;
    try testz.expectEqual(hdr.bytes, 24);
    try testz.expectEqual(hdr.id.integer, 7);
}

pub fn peekLoadImageReturnsNullForOtherMethodsTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    const message =
        \\{"jsonrpc":"2.0","method":"write_text","params":{"text":"hi"}}
    ;
    try testz.expectTrue(try dispatch.peekLoadImage(alloc, message) == null);
}

pub fn loadImageThenGetImageInfoRoundTripsTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 80, 24, 0);
    defer ctx.deinit();
    var d = dispatch.Dispatcher.init(&ctx);

    const png = fakePngBytes(64, 32);
    const load_resp = try d.handleLoadImage(alloc, .{ .id = .{ .integer = 1 }, .bytes = png.len }, &png);
    defer alloc.free(load_resp);
    try testz.expectTrue(std.mem.indexOf(u8, load_resp, "\"handle\":1") != null);

    const info_message =
        \\{"jsonrpc":"2.0","id":2,"method":"get_image_info","params":{"handle":1}}
    ;
    const result = try d.handle(alloc, info_message);
    defer if (result.response) |r| alloc.free(r);
    try testz.expectTrue(result.response != null);
    try testz.expectTrue(std.mem.indexOf(u8, result.response.?, "\"width\":64") != null);
    try testz.expectTrue(std.mem.indexOf(u8, result.response.?, "\"height\":32") != null);
}

pub fn getImageInfoUnknownHandleErrorsTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 80, 24, 0);
    defer ctx.deinit();
    var d = dispatch.Dispatcher.init(&ctx);

    const message =
        \\{"jsonrpc":"2.0","id":1,"method":"get_image_info","params":{"handle":99}}
    ;
    try testz.expectError(d.handle(alloc, message), dispatch.DispatchError.UnknownImage);
}

pub fn drawImageMarksRootLayerCellsTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 10, 10, 0);
    defer ctx.deinit();
    var d = dispatch.Dispatcher.init(&ctx);

    const png = fakePngBytes(24, 12); // 2 cells wide, 1 cell tall at 12px cells
    const load_resp = try d.handleLoadImage(alloc, .{ .id = .{ .integer = 1 }, .bytes = png.len }, &png);
    alloc.free(load_resp);

    const draw_message =
        \\{"jsonrpc":"2.0","method":"draw_image","params":{"handle":1,"row":0,"col":0,"row_span":1,"col_span":2}}
    ;
    const result = try d.handle(alloc, draw_message);
    try testz.expectTrue(result.response == null);

    try testz.expectEqual(ctx.root.cell(0, 0).style.bg.image.handle, 1);
    try testz.expectEqual(ctx.root.cell(0, 1).style.bg.image.offset_x, 12);
    switch (ctx.root.cell(1, 0).style.bg) {
        .color => {},
        .image => return error.TestUnexpectedResult,
    }
}

pub fn getCellMetricsReturnsSessionDefaultsTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 80, 24, 0);
    defer ctx.deinit();
    var d = dispatch.Dispatcher.init(&ctx);

    const message =
        \\{"jsonrpc":"2.0","id":1,"method":"get_cell_metrics","params":{}}
    ;
    const result = try d.handle(alloc, message);
    defer if (result.response) |r| alloc.free(r);
    try testz.expectTrue(std.mem.indexOf(u8, result.response.?, "\"cell_px_w\":12") != null);
    try testz.expectTrue(std.mem.indexOf(u8, result.response.?, "\"cell_px_h\":12") != null);
}
