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

pub fn getPropertySizeReturnsLayerDimensionsTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 96, 40, 0);
    defer ctx.deinit();
    var d = dispatch.Dispatcher.init(&ctx);

    const get_msg =
        \\{"jsonrpc":"2.0","id":7,"method":"get_property","params":{"property":"size"}}
    ;
    const get_decoded = try roundTripThroughWire(alloc, get_msg);
    defer alloc.free(get_decoded);

    const response_body = (try d.handle(alloc, get_decoded)).response.?;
    defer alloc.free(response_body);

    const Response = struct {
        id: i64,
        result: struct { cols: usize, rows: usize },
    };
    const parsed = try std.json.parseFromSlice(Response, alloc, response_body, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    try testz.expectEqual(parsed.value.id, 7);
    try testz.expectEqual(parsed.value.result.cols, 96);
    try testz.expectEqual(parsed.value.result.rows, 40);
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

/// `write_text`'s `transparent_bg: true` leaves a cell's existing
/// background alone instead of resetting it to `default_style.bg` -- the
/// wire-level counterpart of core_tests.zig's
/// `writeTextNullBgLeavesExistingBackgroundUntouchedTest`.
pub fn writeTextTransparentBgLeavesExistingBackgroundUntouchedTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 10, 3, 0);
    defer ctx.deinit();
    var d = dispatch.Dispatcher.init(&ctx);

    const png = fakePngBytes(32, 32);
    const load_resp = try d.handleLoadImage(alloc, .{ .id = .{ .integer = 1 }, .bytes = png.len }, &png);
    alloc.free(load_resp);
    try ctx.registerIcon("panel-fill", 1);

    // draw_icon defaults to the cursor, same starting point (0, 0) a fresh
    // context's cursor already sits at -- write_text (cursor-implicit,
    // no row/col params of its own) then lands on the very cell draw_icon
    // just painted.
    const bg_message =
        \\{"jsonrpc":"2.0","method":"draw_icon","params":{"name":"panel-fill"}}
    ;
    try testz.expectTrue((try d.handle(alloc, bg_message)).response == null);

    const write_msg =
        \\{"jsonrpc":"2.0","method":"write_text","params":{"text":"h","transparent_bg":true}}
    ;
    try testz.expectTrue((try d.handle(alloc, write_msg)).response == null);

    try testz.expectEqualStr("h", ctx.root.cell(0, 0).grapheme());
    try testz.expectEqual(ctx.root.cell(0, 0).style.bg.icon.handle, 1);
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

    try ctx.root.writeText("hello", glyphwire.default_style.fg, glyphwire.default_style.bg);
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

    try ctx.root.writeText("hello", glyphwire.default_style.fg, glyphwire.default_style.bg);
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
        .image, .icon => return error.TestUnexpectedResult,
    }
}

/// draw_image with row/col omitted anchors at the layer's current cursor
/// -- the same convention decisions.md already documents for write_text,
/// now actually wired in for the draw_* family too.
pub fn drawImageOmittedRowColUsesCursorTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 10, 10, 0);
    defer ctx.deinit();
    var d = dispatch.Dispatcher.init(&ctx);
    ctx.root.setProperty(.{ .cursor = .{ .row = 4, .col = 5 } });

    const png = fakePngBytes(12, 12);
    const load_resp = try d.handleLoadImage(alloc, .{ .id = .{ .integer = 1 }, .bytes = png.len }, &png);
    alloc.free(load_resp);

    const draw_message =
        \\{"jsonrpc":"2.0","method":"draw_image","params":{"handle":1,"row_span":1,"col_span":1}}
    ;
    try testz.expectTrue((try d.handle(alloc, draw_message)).response == null);

    try testz.expectEqual(ctx.root.cell(4, 5).style.bg.image.handle, 1);
}

pub fn drawIconAppliesScaleAndAlignParamsTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 10, 10, 0);
    defer ctx.deinit();
    var d = dispatch.Dispatcher.init(&ctx);

    const png = fakePngBytes(32, 32);
    const load_resp = try d.handleLoadImage(alloc, .{ .id = .{ .integer = 1 }, .bytes = png.len }, &png);
    alloc.free(load_resp);
    try ctx.registerIcon("folder", 1);

    const draw_message =
        \\{"jsonrpc":"2.0","method":"draw_icon","params":{"row":2,"col":3,"name":"folder","scale":"natural","h_align":"start","v_align":"end"}}
    ;
    const result = try d.handle(alloc, draw_message);
    try testz.expectTrue(result.response == null);

    const icon = ctx.root.cell(2, 3).style.bg.icon;
    try testz.expectEqual(icon.handle, 1);
    try testz.expectEqual(icon.scale, .natural);
    try testz.expectEqual(icon.h_align, .start);
    try testz.expectEqual(icon.v_align, .end);
}

pub fn drawIconAppliesMaxWidthAndHeightParamsTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 10, 10, 0);
    defer ctx.deinit();
    var d = dispatch.Dispatcher.init(&ctx);

    const png = fakePngBytes(32, 32);
    const load_resp = try d.handleLoadImage(alloc, .{ .id = .{ .integer = 1 }, .bytes = png.len }, &png);
    alloc.free(load_resp);
    try ctx.registerIcon("folder", 1);

    const draw_message =
        \\{"jsonrpc":"2.0","method":"draw_icon","params":{"row":2,"col":3,"name":"folder","scale":"natural","max_w":40,"max_h":60}}
    ;
    const result = try d.handle(alloc, draw_message);
    try testz.expectTrue(result.response == null);

    const icon = ctx.root.cell(2, 3).style.bg.icon;
    try testz.expectEqual(icon.max_w, 40);
    try testz.expectEqual(icon.max_h, 60);
}

pub fn drawIconStretchScaleParsesTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 10, 10, 0);
    defer ctx.deinit();
    var d = dispatch.Dispatcher.init(&ctx);

    const png = fakePngBytes(32, 32);
    const load_resp = try d.handleLoadImage(alloc, .{ .id = .{ .integer = 1 }, .bytes = png.len }, &png);
    alloc.free(load_resp);
    try ctx.registerIcon("folder", 1);

    const draw_message =
        \\{"jsonrpc":"2.0","method":"draw_icon","params":{"row":2,"col":3,"name":"folder","scale":"stretch"}}
    ;
    const result = try d.handle(alloc, draw_message);
    try testz.expectTrue(result.response == null);

    try testz.expectEqual(ctx.root.cell(2, 3).style.bg.icon.scale, .stretch);
}

pub fn createMetadataReturnsHandleTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 80, 24, 0);
    defer ctx.deinit();
    var d = dispatch.Dispatcher.init(&ctx);

    const message =
        \\{"jsonrpc":"2.0","id":1,"method":"create_metadata","params":{"json":"{\"path\":\"/tmp/a\"}"}}
    ;
    const result = try d.handle(alloc, message);
    defer if (result.response) |r| alloc.free(r);
    try testz.expectTrue(result.response != null);
    try testz.expectTrue(std.mem.indexOf(u8, result.response.?, "\"handle\":1") != null);
}

pub fn writeTextTaggedThenGetMetadataRoundTripsTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 80, 24, 0);
    defer ctx.deinit();
    var d = dispatch.Dispatcher.init(&ctx);

    const create_message =
        \\{"jsonrpc":"2.0","id":1,"method":"create_metadata","params":{"json":"{\"path\":\"/tmp/a\"}"}}
    ;
    const create_result = try d.handle(alloc, create_message);
    defer if (create_result.response) |r| alloc.free(r);

    const write_message =
        \\{"jsonrpc":"2.0","method":"write_text","params":{"text":"a","metadata_id":1}}
    ;
    try testz.expectTrue((try d.handle(alloc, write_message)).response == null);

    const get_message =
        \\{"jsonrpc":"2.0","id":2,"method":"get_metadata","params":{"row":0,"col":0}}
    ;
    const get_result = try d.handle(alloc, get_message);
    defer if (get_result.response) |r| alloc.free(r);
    try testz.expectTrue(get_result.response != null);
    try testz.expectTrue(std.mem.indexOf(u8, get_result.response.?, "\"id\":1") != null);
    try testz.expectTrue(std.mem.indexOf(u8, get_result.response.?, "\\\"path\\\":\\\"/tmp/a\\\"") != null);
}

pub fn getMetadataUntaggedCellReturnsNullTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 80, 24, 0);
    defer ctx.deinit();
    var d = dispatch.Dispatcher.init(&ctx);

    const message =
        \\{"jsonrpc":"2.0","id":1,"method":"get_metadata","params":{"row":0,"col":0}}
    ;
    const result = try d.handle(alloc, message);
    defer if (result.response) |r| alloc.free(r);
    try testz.expectTrue(result.response != null);
    try testz.expectTrue(std.mem.indexOf(u8, result.response.?, "\"id\":null") != null);
    try testz.expectTrue(std.mem.indexOf(u8, result.response.?, "\"json\":null") != null);
}

pub fn writeTextUnknownMetadataIdErrorsTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 80, 24, 0);
    defer ctx.deinit();
    var d = dispatch.Dispatcher.init(&ctx);

    const message =
        \\{"jsonrpc":"2.0","method":"write_text","params":{"text":"a","metadata_id":99}}
    ;
    try testz.expectError(d.handle(alloc, message), dispatch.DispatchError.UnknownMetadata);
}

pub fn drawIconUnknownMetadataIdErrorsTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 80, 24, 0);
    defer ctx.deinit();
    var d = dispatch.Dispatcher.init(&ctx);

    const png = fakePngBytes(32, 32);
    const load_resp = try d.handleLoadImage(alloc, .{ .id = .{ .integer = 1 }, .bytes = png.len }, &png);
    alloc.free(load_resp);
    try ctx.registerIcon("folder", 1);

    const message =
        \\{"jsonrpc":"2.0","method":"draw_icon","params":{"row":0,"col":0,"name":"folder","metadata_id":99}}
    ;
    try testz.expectError(d.handle(alloc, message), dispatch.DispatchError.UnknownMetadata);
}

pub fn destroyMetadataThenGetMetadataReportsDanglingTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 80, 24, 0);
    defer ctx.deinit();
    var d = dispatch.Dispatcher.init(&ctx);

    const id = try ctx.createMetadata("{}");
    try ctx.root.writeTextTagged("a", glyphwire.default_style.fg, glyphwire.default_style.bg, id);

    var msg_buf: [128]u8 = undefined;
    const destroy_message = try std.fmt.bufPrint(&msg_buf, "{{\"jsonrpc\":\"2.0\",\"method\":\"destroy_metadata\",\"params\":{{\"id\":{d}}}}}", .{id});
    try testz.expectTrue((try d.handle(alloc, destroy_message)).response == null);

    const get_message =
        \\{"jsonrpc":"2.0","id":2,"method":"get_metadata","params":{"row":0,"col":0}}
    ;
    const get_result = try d.handle(alloc, get_message);
    defer if (get_result.response) |r| alloc.free(r);
    try testz.expectTrue(std.mem.indexOf(u8, get_result.response.?, "\"id\":1") != null);
    try testz.expectTrue(std.mem.indexOf(u8, get_result.response.?, "\"json\":null") != null);
}

pub fn destroyMetadataUnknownIdErrorsTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 80, 24, 0);
    defer ctx.deinit();
    var d = dispatch.Dispatcher.init(&ctx);

    const message =
        \\{"jsonrpc":"2.0","method":"destroy_metadata","params":{"id":99}}
    ;
    try testz.expectError(d.handle(alloc, message), dispatch.DispatchError.UnknownMetadata);
}

pub fn tagMetadataSetsCellIdOverWireTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 80, 24, 0);
    defer ctx.deinit();
    var d = dispatch.Dispatcher.init(&ctx);

    const create_message =
        \\{"jsonrpc":"2.0","id":1,"method":"create_metadata","params":{"json":"{}"}}
    ;
    const create_result = try d.handle(alloc, create_message);
    defer if (create_result.response) |r| alloc.free(r);

    const tag_message =
        \\{"jsonrpc":"2.0","method":"tag_metadata","params":{"row":2,"col":3,"metadata_id":1}}
    ;
    try testz.expectTrue((try d.handle(alloc, tag_message)).response == null);

    try testz.expectEqual(ctx.root.cell(2, 3).metadata_id.?, 1);
    // No grapheme/bg touched -- tag_metadata only ever sets the id.
    switch (ctx.root.cell(2, 3).style.bg) {
        .color => {},
        .image, .icon => return error.TestUnexpectedResult,
    }
}

pub fn tagMetadataUnknownIdErrorsTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 80, 24, 0);
    defer ctx.deinit();
    var d = dispatch.Dispatcher.init(&ctx);

    const message =
        \\{"jsonrpc":"2.0","method":"tag_metadata","params":{"row":0,"col":0,"metadata_id":99}}
    ;
    try testz.expectError(d.handle(alloc, message), dispatch.DispatchError.UnknownMetadata);
}

pub fn getCellsIncludesMetadataIdTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 80, 24, 0);
    defer ctx.deinit();
    var d = dispatch.Dispatcher.init(&ctx);

    const id = try ctx.createMetadata("{}");
    try ctx.root.writeTextTagged("a", glyphwire.default_style.fg, glyphwire.default_style.bg, id);

    const message =
        \\{"jsonrpc":"2.0","id":1,"method":"get_cells","params":{}}
    ;
    const result = try d.handle(alloc, message);
    defer if (result.response) |r| alloc.free(r);
    try testz.expectTrue(std.mem.indexOf(u8, result.response.?, "\"metadata_id\":1") != null);
}

pub fn drawIconInvalidScaleErrorsTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 10, 10, 0);
    defer ctx.deinit();
    var d = dispatch.Dispatcher.init(&ctx);

    const png = fakePngBytes(32, 32);
    const load_resp = try d.handleLoadImage(alloc, .{ .id = .{ .integer = 1 }, .bytes = png.len }, &png);
    alloc.free(load_resp);
    try ctx.registerIcon("folder", 1);

    const draw_message =
        \\{"jsonrpc":"2.0","method":"draw_icon","params":{"row":2,"col":3,"name":"folder","scale":"huge"}}
    ;
    try testz.expectError(d.handle(alloc, draw_message), dispatch.DispatchError.InvalidIconOption);
}

pub fn drawIconMarksExactlyOneCellTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 10, 10, 0);
    defer ctx.deinit();
    var d = dispatch.Dispatcher.init(&ctx);

    const png = fakePngBytes(32, 32);
    const load_resp = try d.handleLoadImage(alloc, .{ .id = .{ .integer = 1 }, .bytes = png.len }, &png);
    alloc.free(load_resp);
    try ctx.registerIcon("folder", 1);

    const draw_message =
        \\{"jsonrpc":"2.0","method":"draw_icon","params":{"row":2,"col":3,"name":"folder"}}
    ;
    const result = try d.handle(alloc, draw_message);
    try testz.expectTrue(result.response == null);

    try testz.expectEqual(ctx.root.cell(2, 3).style.bg.icon.handle, 1);
    // Confirm the neighboring cell wasn't touched -- draw_icon always
    // scopes to exactly one cell.
    switch (ctx.root.cell(2, 4).style.bg) {
        .color => {},
        .image, .icon => return error.TestUnexpectedResult,
    }
}

/// `foreground: true` lands in `fg_icon`, not `style.bg` -- and leaves an
/// already-drawn background (as `draw_box` would leave) alone, unlike a
/// plain `draw_icon` at the same cell.
pub fn drawIconForegroundSetsFgIconOverExistingBgTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 10, 10, 0);
    defer ctx.deinit();
    var d = dispatch.Dispatcher.init(&ctx);

    const bg_png = fakePngBytes(32, 32);
    const bg_load_resp = try d.handleLoadImage(alloc, .{ .id = .{ .integer = 1 }, .bytes = bg_png.len }, &bg_png);
    alloc.free(bg_load_resp);
    try ctx.registerIcon("panel-fill", 1);

    const bg_message =
        \\{"jsonrpc":"2.0","method":"draw_icon","params":{"row":2,"col":3,"name":"panel-fill"}}
    ;
    try testz.expectTrue((try d.handle(alloc, bg_message)).response == null);

    const fg_png = fakePngBytes(32, 32);
    const fg_load_resp = try d.handleLoadImage(alloc, .{ .id = .{ .integer = 2 }, .bytes = fg_png.len }, &fg_png);
    alloc.free(fg_load_resp);
    try ctx.registerIcon("badge", 2);

    const fg_message =
        \\{"jsonrpc":"2.0","method":"draw_icon","params":{"row":2,"col":3,"name":"badge","foreground":true}}
    ;
    try testz.expectTrue((try d.handle(alloc, fg_message)).response == null);

    try testz.expectEqual(ctx.root.cell(2, 3).style.bg.icon.handle, 1);
    try testz.expectEqual(ctx.root.cell(2, 3).fg_icon.?.handle, 2);
}

/// Reproduces the actual glyphwire-ls regression end to end at the
/// dispatch level: draw_icon(row, ...) then set_property(cursor, row,
/// ...) then write_text, repeated for enough rows to push past the
/// bottom of a small grid. Before Layer.resolveRow, draw_icon's raw row
/// silently no-op'd once it exceeded height while write_text kept
/// self-correcting via the cursor -- so text kept appearing but icons
/// stopped. This drives it exactly the way glyphwire-ls does (a fresh
/// get_property(cursor) read before each row, mirroring writeGrid) and
/// asserts every row still ends up icon-backed.
pub fn drawIconKeepsLandingAcrossAScrollBoundaryTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 10, 3, 20);
    defer ctx.deinit();
    var d = dispatch.Dispatcher.init(&ctx);

    const png = fakePngBytes(32, 32);
    const load_resp = try d.handleLoadImage(alloc, .{ .id = .{ .integer = 1 }, .bytes = png.len }, &png);
    alloc.free(load_resp);
    try ctx.registerIcon("folder", 1);

    var name_buf: [128]u8 = undefined;
    var i: usize = 0;
    while (i < 6) : (i += 1) { // 3-row grid -- guarantees at least one scroll
        const row = ctx.root.cursor.row;

        const draw_msg = try std.fmt.bufPrint(&name_buf, "{{\"jsonrpc\":\"2.0\",\"method\":\"draw_icon\",\"params\":{{\"row\":{d},\"col\":0,\"name\":\"folder\"}}}}", .{row});
        try testz.expectTrue((try d.handle(alloc, draw_msg)).response == null);

        // Every entry lands on the *current* cursor row, same as
        // glyphwire-ls's writeGrid -- confirms the icon actually marked
        // whatever row write_text is about to use, not a stale one.
        try testz.expectEqual(ctx.root.cell(row, 0).style.bg.icon.handle, 1);

        const set_msg = try std.fmt.bufPrint(&name_buf, "{{\"jsonrpc\":\"2.0\",\"method\":\"set_property\",\"params\":{{\"property\":\"cursor\",\"row\":{d},\"col\":0}}}}", .{row + 1});
        try testz.expectTrue((try d.handle(alloc, set_msg)).response == null);
    }
}

pub fn drawIconUnknownNameErrorsTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 10, 10, 0);
    defer ctx.deinit();
    var d = dispatch.Dispatcher.init(&ctx);

    const message =
        \\{"jsonrpc":"2.0","method":"draw_icon","params":{"row":0,"col":0,"name":"not-registered"}}
    ;
    try testz.expectError(d.handle(alloc, message), dispatch.DispatchError.UnknownIcon);
}

pub fn drawIconOmittedRowColUsesCursorTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 10, 10, 0);
    defer ctx.deinit();
    var d = dispatch.Dispatcher.init(&ctx);
    ctx.root.setProperty(.{ .cursor = .{ .row = 2, .col = 6 } });

    const png = fakePngBytes(32, 32);
    const load_resp = try d.handleLoadImage(alloc, .{ .id = .{ .integer = 1 }, .bytes = png.len }, &png);
    alloc.free(load_resp);
    try ctx.registerIcon("folder", 1);

    const draw_message =
        \\{"jsonrpc":"2.0","method":"draw_icon","params":{"name":"folder"}}
    ;
    try testz.expectTrue((try d.handle(alloc, draw_message)).response == null);

    try testz.expectEqual(ctx.root.cell(2, 6).style.bg.icon.handle, 1);
}

/// Registers all 9 pieces of a `style`-prefixed box under distinct
/// handles, reusing `fakePngBytes` so each is a real (if minimal) loaded
/// image `ctx.imageInfo` can resolve.
fn registerTestBoxStyle(d: *dispatch.Dispatcher, alloc: std.mem.Allocator, ctx: *glyphwire.Context, style: []const u8) !void {
    const pieces = [_][]const u8{ "tl", "t", "tr", "l", "fill", "r", "bl", "b", "br" };
    for (pieces) |piece| {
        const png = fakePngBytes(12, 12);
        const id: i64 = 1;
        const load_resp = try d.handleLoadImage(alloc, .{ .id = .{ .integer = id }, .bytes = png.len }, &png);
        defer alloc.free(load_resp);

        const parsed = try std.json.parseFromSlice(struct { result: struct { handle: glyphwire.ImageHandle } }, alloc, load_resp, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();

        var name_buf: [64]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "{s}-{s}", .{ style, piece });
        try ctx.registerIcon(name, parsed.value.result.handle);
    }
}

pub fn drawBoxPlacesAllNinePiecesTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 10, 10, 0);
    defer ctx.deinit();
    var d = dispatch.Dispatcher.init(&ctx);
    try registerTestBoxStyle(&d, alloc, &ctx, "box");

    const message =
        \\{"jsonrpc":"2.0","method":"draw_box","params":{"row":1,"col":1,"rows":3,"cols":3,"style":"box"}}
    ;
    const result = try d.handle(alloc, message);
    try testz.expectTrue(result.response == null);

    // All 9 cells got marked as icon-backed -- role-correctness is
    // core_tests.zig's job (layerDrawBoxPlacesEachPieceByRoleTest); this
    // just proves the name-resolution + dispatch wiring reaches Layer.drawBox.
    var r: usize = 1;
    while (r <= 3) : (r += 1) {
        var c: usize = 1;
        while (c <= 3) : (c += 1) {
            switch (ctx.root.cell(r, c).style.bg) {
                .icon => {},
                .color, .image => return error.TestUnexpectedResult,
            }
        }
    }
}

pub fn drawBoxOmittedRowColUsesCursorTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 10, 10, 0);
    defer ctx.deinit();
    var d = dispatch.Dispatcher.init(&ctx);
    try registerTestBoxStyle(&d, alloc, &ctx, "box");
    ctx.root.setProperty(.{ .cursor = .{ .row = 3, .col = 2 } });

    const message =
        \\{"jsonrpc":"2.0","method":"draw_box","params":{"rows":2,"cols":2,"style":"box"}}
    ;
    try testz.expectTrue((try d.handle(alloc, message)).response == null);

    switch (ctx.root.cell(3, 2).style.bg) {
        .icon => {},
        .color, .image => return error.TestUnexpectedResult,
    }
}

pub fn drawBoxUnknownStyleErrorsTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 10, 10, 0);
    defer ctx.deinit();
    var d = dispatch.Dispatcher.init(&ctx);

    const message =
        \\{"jsonrpc":"2.0","method":"draw_box","params":{"row":0,"col":0,"rows":3,"cols":3,"style":"not-a-style"}}
    ;
    try testz.expectError(d.handle(alloc, message), dispatch.DispatchError.UnknownIcon);
}

/// `mode: "stretch"` reaches `Layer.drawBox` -- role-correctness of the
/// resulting per-cell UV slice is core_tests.zig's job
/// (`layerDrawBoxStretchModeSlicesFillAcrossInteriorTest`); this just
/// proves the wire string parses into `core.Layer.BoxMode` and flows
/// through, unlike the default (omitted `mode`, "tile") which never
/// slices.
pub fn drawBoxStretchModeFlowsThroughTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 10, 10, 0);
    defer ctx.deinit();
    var d = dispatch.Dispatcher.init(&ctx);
    try registerTestBoxStyle(&d, alloc, &ctx, "box");

    const message =
        \\{"jsonrpc":"2.0","method":"draw_box","params":{"row":0,"col":0,"rows":6,"cols":6,"style":"box","mode":"stretch"}}
    ;
    try testz.expectTrue((try d.handle(alloc, message)).response == null);

    // The fill cell in the middle of a 4x4 interior gets a quarter-slice,
    // not the full 0..1 a "tile"-mode (or omitted-mode) draw would give it.
    const fill_mid = ctx.root.cell(2, 2).style.bg.icon;
    try testz.expectEqual(fill_mid.src_l, 0.25);
    try testz.expectEqual(fill_mid.src_r, 0.5);
}

pub fn drawBoxInvalidModeErrorsTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 10, 10, 0);
    defer ctx.deinit();
    var d = dispatch.Dispatcher.init(&ctx);
    try registerTestBoxStyle(&d, alloc, &ctx, "box");

    const message =
        \\{"jsonrpc":"2.0","method":"draw_box","params":{"row":0,"col":0,"rows":3,"cols":3,"style":"box","mode":"not-a-mode"}}
    ;
    try testz.expectError(d.handle(alloc, message), dispatch.DispatchError.InvalidIconOption);
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

pub fn clearWithExplicitRegionOnlyTouchesThatRegionTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 10, 5, 0);
    defer ctx.deinit();
    var d = dispatch.Dispatcher.init(&ctx);
    try ctx.root.writeText("hello", glyphwire.default_style.fg, glyphwire.default_style.bg);

    const message =
        \\{"jsonrpc":"2.0","method":"clear","params":{"row":0,"col":0,"rows":1,"cols":3}}
    ;
    const result = try d.handle(alloc, message);
    try testz.expectTrue(result.response == null);

    try testz.expectEqual(ctx.root.cell(0, 0).grapheme().len, 0);
    try testz.expectEqual(ctx.root.cell(0, 2).grapheme().len, 0);
    try testz.expectEqualStr("l", ctx.root.cell(0, 3).grapheme());
}

pub fn clearWithNoParamsWipesWholeLayerTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 10, 5, 0);
    defer ctx.deinit();
    var d = dispatch.Dispatcher.init(&ctx);
    try ctx.root.writeText("hello", glyphwire.default_style.fg, glyphwire.default_style.bg);

    const message =
        \\{"jsonrpc":"2.0","method":"clear","params":{}}
    ;
    const result = try d.handle(alloc, message);
    try testz.expectTrue(result.response == null);

    try testz.expectEqual(ctx.root.cell(0, 0).grapheme().len, 0);
    try testz.expectEqual(ctx.root.cell(0, 4).grapheme().len, 0);
}

pub fn clearWithRowPastEdgeAndOmittedRowsIsNoOpTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 10, 5, 0);
    defer ctx.deinit();
    var d = dispatch.Dispatcher.init(&ctx);
    const revision_before = ctx.root.revision;

    const message =
        \\{"jsonrpc":"2.0","method":"clear","params":{"row":9}}
    ;
    const result = try d.handle(alloc, message);
    try testz.expectTrue(result.response == null);
    try testz.expectEqual(ctx.root.revision, revision_before);
}

pub fn isNotificationTrueForMessageWithNoIdTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    const message =
        \\{"jsonrpc":"2.0","method":"write_text","params":{"text":"hi"}}
    ;
    try testz.expectTrue(try dispatch.isNotification(alloc, message));
}

pub fn isNotificationFalseForMessageWithIdTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    const message =
        \\{"jsonrpc":"2.0","id":1,"method":"get_property","params":{"property":"cursor"}}
    ;
    try testz.expectTrue(!try dispatch.isNotification(alloc, message));
}
