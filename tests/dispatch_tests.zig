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

/// `get_cells` tags the two halves of a wide character: `"lead"` on the
/// cell holding the grapheme, `"spacer"` on its blank right neighbour;
/// an ordinary cell has no `wide` field.
pub fn getCellsMarksWideCharacterHalvesTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 10, 3, 0);
    defer ctx.deinit();
    var d = dispatch.Dispatcher.init(&ctx);

    // "aあ" -- one narrow, one wide.
    const write_msg =
        \\{"jsonrpc":"2.0","method":"write_text","params":{"text":"a\u3042","fg":{"r":255,"g":255,"b":255}}}
    ;
    try testz.expectTrue((try d.handle(alloc, write_msg)).response == null);

    const response_body = (try d.handle(alloc,
        \\{"jsonrpc":"2.0","id":1,"method":"get_cells","params":{}}
    )).response.?;
    defer alloc.free(response_body);

    const CellJson = struct { g: []const u8, wide: ?[]const u8 = null };
    const Response = struct {
        result: struct { cells: []CellJson },
    };
    const parsed = try std.json.parseFromSlice(Response, alloc, response_body, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    const cells = parsed.value.result.cells;
    try testz.expectEqualStr("a", cells[0].g);
    try testz.expectTrue(cells[0].wide == null);
    try testz.expectEqualStr("\u{3042}", cells[1].g);
    try testz.expectEqualStr("lead", cells[1].wide.?);
    try testz.expectEqualStr("", cells[2].g);
    try testz.expectEqualStr("spacer", cells[2].wide.?);
    try testz.expectTrue(cells[3].wide == null);
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
    const load_resp = try d.handleLoadImage(alloc, .{ .id = .{ .integer = 1 }, .format = .png, .bytes = png.len }, &png);
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

pub fn reportMouseMoveBroadcastsOnlyOnCellChangeTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 80, 24, 0);
    defer ctx.deinit();
    var d = dispatch.Dispatcher.init(&ctx);

    const to_2_1 =
        \\{"jsonrpc":"2.0","method":"report_mouse_move","params":{"px":{"x":12.5,"y":30.0},"cell":{"row":2,"col":1}}}
    ;
    const first = try d.handle(alloc, to_2_1);
    try testz.expectTrue(first.response == null);
    try testz.expectEqual(ctx.input.cursor_cell.row, @as(usize, 2));
    const b = first.broadcast.?;
    defer alloc.free(b.body);
    try testz.expectEqualStr("mouse_move", b.event);
    try testz.expectTrue(std.mem.indexOf(u8, b.body, "\"method\":\"mouse_move\"") != null);

    // Same cell, different pixel -> cursor_px updates but no broadcast.
    const same_cell =
        \\{"jsonrpc":"2.0","method":"report_mouse_move","params":{"px":{"x":13.0,"y":31.0},"cell":{"row":2,"col":1}}}
    ;
    const repeat = try d.handle(alloc, same_cell);
    try testz.expectTrue(repeat.broadcast == null);

    // New cell -> broadcast again.
    const to_2_2 =
        \\{"jsonrpc":"2.0","method":"report_mouse_move","params":{"px":{"x":20.0,"y":31.0},"cell":{"row":2,"col":2}}}
    ;
    const moved = try d.handle(alloc, to_2_2);
    if (moved.broadcast) |bb| alloc.free(bb.body);
    try testz.expectTrue(moved.broadcast != null);
}

pub fn writeTextWithTerminalQueryBroadcastsReplyTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 80, 24, 0);
    defer ctx.deinit();
    var d = dispatch.Dispatcher.init(&ctx);

    // A mirrored `write_text` carrying `CSI 6n` -> a `terminal_reply`
    // broadcast with the CPR bytes for a `"terminal"` subscriber to send
    // to the pty master.
    const msg =
        \\{"jsonrpc":"2.0","method":"write_text","params":{"text":"\u001b[6n"}}
    ;
    const result = try d.handle(alloc, msg);
    const b = result.broadcast.?;
    defer alloc.free(b.body);
    try testz.expectEqualStr("terminal_reply", b.event);
    try testz.expectTrue(std.mem.indexOf(u8, b.body, "\"method\":\"terminal_reply\"") != null);
    // Cursor was at 1;1 -> reply "\x1b[1;1R", JSON-escaped in the body.
    try testz.expectTrue(std.mem.indexOf(u8, b.body, "1;1R") != null);

    // Plain text with no query -> no broadcast.
    const plain =
        \\{"jsonrpc":"2.0","method":"write_text","params":{"text":"hi"}}
    ;
    const plain_result = try d.handle(alloc, plain);
    try testz.expectTrue(plain_result.broadcast == null);
}

pub fn subscribeTerminalEventTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 80, 24, 0);
    defer ctx.deinit();
    var d = dispatch.Dispatcher.init(&ctx);

    const sub =
        \\{"jsonrpc":"2.0","id":1,"method":"subscribe","params":{"events":["terminal"]}}
    ;
    const result = try d.handle(alloc, sub);
    if (result.response) |r| alloc.free(r);
    try testz.expectTrue(d.subscriptions.terminal);
}

pub fn subscribeMouseMoveEventTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 80, 24, 0);
    defer ctx.deinit();
    var d = dispatch.Dispatcher.init(&ctx);

    const sub =
        \\{"jsonrpc":"2.0","id":1,"method":"subscribe","params":{"events":["mouse_move"]}}
    ;
    const result = try d.handle(alloc, sub);
    if (result.response) |r| alloc.free(r);
    try testz.expectTrue(d.subscriptions.mouse_move);
    try testz.expectFalse(d.subscriptions.mouse_button);
}

pub fn reportTextQueuesTextBroadcastTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 80, 24, 0);
    defer ctx.deinit();
    var d = dispatch.Dispatcher.init(&ctx);

    // A multi-byte codepoint (an AZERTY 'é') round-trips through JSON into
    // the broadcast body verbatim.
    const msg =
        \\{"jsonrpc":"2.0","method":"report_text","params":{"text":"e\u00e9"}}
    ;
    const result = try d.handle(alloc, msg);
    try testz.expectTrue(result.response == null);
    const broadcast = result.broadcast.?;
    defer alloc.free(broadcast.body);
    try testz.expectEqualStr("text", broadcast.event);
    try testz.expectTrue(std.mem.indexOf(u8, broadcast.body, "\"method\":\"text\"") != null);
    try testz.expectTrue(std.mem.indexOf(u8, broadcast.body, "e\u{00e9}") != null);

    // report_text touches no input down-set -- text is transient.
    try testz.expectEqual(ctx.input.keys_down.count(), 0);

    // An empty string queues nothing.
    const empty_result = try d.handle(alloc,
        \\{"jsonrpc":"2.0","method":"report_text","params":{"text":""}}
    );
    try testz.expectTrue(empty_result.broadcast == null);
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
    try testz.expectEqual(hdr.format, .png);
}

pub fn peekLoadImageRejectsUnknownFormatTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    const message =
        \\{"jsonrpc":"2.0","id":7,"method":"load_image","params":{"format":"webp","bytes":24}}
    ;
    try testz.expectError(dispatch.peekLoadImage(alloc, message), dispatch.DispatchError.UnsupportedImageFormat);
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
    const load_resp = try d.handleLoadImage(alloc, .{ .id = .{ .integer = 1 }, .format = .png, .bytes = png.len }, &png);
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
    const load_resp = try d.handleLoadImage(alloc, .{ .id = .{ .integer = 1 }, .format = .png, .bytes = png.len }, &png);
    alloc.free(load_resp);

    const draw_message =
        \\{"jsonrpc":"2.0","method":"draw_image","params":{"handle":1,"row":0,"col":0,"row_span":1,"col_span":2}}
    ;
    const result = try d.handle(alloc, draw_message);
    try testz.expectTrue(result.response == null);

    try testz.expectEqual(ctx.root.cell(0, 0).style.bg.image.handle, 1);
    try testz.expectEqual(ctx.root.cell(0, 1).style.bg.image.offset_x, 12);
    try testz.expectEqual(ctx.root.cell(0, 0).style.bg.image.scale, 1.0);
    switch (ctx.root.cell(1, 0).style.bg) {
        .color => {},
        .image, .icon => return error.TestUnexpectedResult,
    }
}

/// `draw_image`'s optional `scale` (glyphwire-view's `--size fit-width`):
/// each covered cell samples `cell_px / scale` source pixels, so the
/// stored per-cell offsets step by that, and the scale rides along on
/// every cell for the renderer.
pub fn drawImageScaleShrinksSourceStepAndRecordsScaleTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 10, 10, 0);
    defer ctx.deinit();
    var d = dispatch.Dispatcher.init(&ctx);

    const png = fakePngBytes(96, 24); // renders 48x12px at scale 0.5 -> 4x1 cells
    const load_resp = try d.handleLoadImage(alloc, .{ .id = .{ .integer = 1 }, .format = .png, .bytes = png.len }, &png);
    alloc.free(load_resp);

    const draw_message =
        \\{"jsonrpc":"2.0","method":"draw_image","params":{"handle":1,"row":0,"col":0,"row_span":1,"col_span":4,"scale":0.5}}
    ;
    try testz.expectTrue((try d.handle(alloc, draw_message)).response == null);

    try testz.expectEqual(ctx.root.cell(0, 0).style.bg.image.offset_x, 0);
    try testz.expectEqual(ctx.root.cell(0, 1).style.bg.image.offset_x, 24);
    try testz.expectEqual(ctx.root.cell(0, 2).style.bg.image.offset_x, 48);
    try testz.expectEqual(ctx.root.cell(0, 3).style.bg.image.offset_x, 72);
    try testz.expectEqual(ctx.root.cell(0, 0).style.bg.image.scale, 0.5);
    try testz.expectEqual(ctx.root.cell(0, 3).style.bg.image.scale, 0.5);
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
    const load_resp = try d.handleLoadImage(alloc, .{ .id = .{ .integer = 1 }, .format = .png, .bytes = png.len }, &png);
    alloc.free(load_resp);

    const draw_message =
        \\{"jsonrpc":"2.0","method":"draw_image","params":{"handle":1,"row_span":1,"col_span":1}}
    ;
    try testz.expectTrue((try d.handle(alloc, draw_message)).response == null);

    try testz.expectEqual(ctx.root.cell(4, 5).style.bg.image.handle, 1);
}

/// Regression test for the "extra blank space before the prompt" bug:
/// glyphwire-view (view/main.zig) issues `draw_image` then a
/// `set_property` cursor move to just past the image's bottom edge,
/// computed as `@min(cur.row + rows, grid_rows)` -- clamped to the
/// layer's own row count, so it asks for at most the one further scroll
/// `Layer.drawImage` didn't already do itself. Before that clamp existed,
/// the un-clamped `cur.row + rows` re-derived its own overshoot against
/// the *already-scrolled* viewport from scratch, scrolling several rows
/// further than necessary. This exercises the real `Dispatcher`/`Layer`
/// code path with the corrected (clamped) value and checks it performs
/// *no more* than the one additional scroll actually needed.
pub fn setPropertyCursorAfterScrollingDrawImageScrollsExactlyOnceMoreTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 5, 5, 10);
    defer ctx.deinit();
    var d = dispatch.Dispatcher.init(&ctx);
    ctx.root.setProperty(.{ .cursor = .{ .row = 1, .col = 0 } });

    // 1 cell wide, 8 cells tall at the default 12px cells -- taller than
    // the 5-row layer, anchored at row 1, so drawing it has to scroll
    // partway through (see `Layer.drawImage`'s doc comment).
    const png = fakePngBytes(12, 96);
    const load_resp = try d.handleLoadImage(alloc, .{ .id = .{ .integer = 1 }, .format = .png, .bytes = png.len }, &png);
    alloc.free(load_resp);

    const draw_message =
        \\{"jsonrpc":"2.0","method":"draw_image","params":{"handle":1,"row_span":8,"col_span":1}}
    ;
    try testz.expectTrue((try d.handle(alloc, draw_message)).response == null);

    const scrolls_from_draw = ctx.root.history_len;
    try testz.expectTrue(scrolls_from_draw > 0);

    // The fixed client-side formula: `@min(cur.row + rows, grid_rows)` --
    // here that's `@min(1 + 8, 5) == 5`, one past the layer's last row.
    const set_cursor_message =
        \\{"jsonrpc":"2.0","method":"set_property","params":{"property":"cursor","row":5,"col":0}}
    ;
    try testz.expectTrue((try d.handle(alloc, set_cursor_message)).response == null);

    try testz.expectEqual(ctx.root.history_len, scrolls_from_draw + 1);
    try testz.expectEqual(ctx.root.cursor.row, 4);
    try testz.expectEqual(ctx.root.cursor.col, 0);
}

pub fn drawIconAppliesScaleAndAlignParamsTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 10, 10, 0);
    defer ctx.deinit();
    var d = dispatch.Dispatcher.init(&ctx);

    const png = fakePngBytes(32, 32);
    const load_resp = try d.handleLoadImage(alloc, .{ .id = .{ .integer = 1 }, .format = .png, .bytes = png.len }, &png);
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
    const load_resp = try d.handleLoadImage(alloc, .{ .id = .{ .integer = 1 }, .format = .png, .bytes = png.len }, &png);
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
    const load_resp = try d.handleLoadImage(alloc, .{ .id = .{ .integer = 1 }, .format = .png, .bytes = png.len }, &png);
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

/// `scroll_view` moves the root layer's scrollback view offset, returns
/// the clamped `{offset, max}`, and queues a `scroll` broadcast for other
/// subscribers.
pub fn scrollViewMovesOffsetClampsAndBroadcastsTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 4, 2, 5);
    defer ctx.deinit();
    var d = dispatch.Dispatcher.init(&ctx);

    // 3 rows of content over a 2-tall viewport => history_len 1.
    try ctx.root.writeText("aaaabbbbcccc", glyphwire.default_style.fg, glyphwire.default_style.bg);
    try testz.expectEqual(ctx.root.history_len, 1);

    const message =
        \\{"jsonrpc":"2.0","id":7,"method":"scroll_view","params":{"delta":9}}
    ;
    const result = try d.handle(alloc, message);
    defer if (result.response) |r| alloc.free(r);
    defer if (result.broadcast) |b| alloc.free(b.body);

    try testz.expectTrue(result.response != null);
    // delta 9 clamps to history_len (1).
    try testz.expectTrue(std.mem.indexOf(u8, result.response.?, "\"offset\":1") != null);
    try testz.expectTrue(std.mem.indexOf(u8, result.response.?, "\"max\":1") != null);
    try testz.expectEqual(ctx.root.view_scroll, 1);

    try testz.expectTrue(result.broadcast != null);
    try testz.expectEqualStr("scroll", result.broadcast.?.event);
    try testz.expectTrue(std.mem.indexOf(u8, result.broadcast.?.body, "\"offset\":1") != null);
}

/// `get_property("scroll")` reports the same `{offset, max}` a preceding
/// `scroll_view` landed on.
pub fn getPropertyScrollReportsOffsetAndMaxTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 4, 2, 5);
    defer ctx.deinit();
    var d = dispatch.Dispatcher.init(&ctx);

    try ctx.root.writeText("aaaabbbbccccdddd", glyphwire.default_style.fg, glyphwire.default_style.bg); // history_len 2
    _ = ctx.root.scrollView(1, null);

    const message =
        \\{"jsonrpc":"2.0","id":3,"method":"get_property","params":{"property":"scroll"}}
    ;
    const result = try d.handle(alloc, message);
    defer if (result.response) |r| alloc.free(r);
    try testz.expectTrue(std.mem.indexOf(u8, result.response.?, "\"offset\":1") != null);
    try testz.expectTrue(std.mem.indexOf(u8, result.response.?, "\"max\":2") != null);
}

/// `get_metadata` with a non-zero `view_offset` resolves `(row, col)`
/// against scrollback (`Layer.viewRow`) rather than the live viewport --
/// the path a click made while glyphwire-host is scrolled back takes so
/// it lands on the row actually under the pointer.
pub fn getMetadataWithViewOffsetResolvesScrollbackRowTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 4, 2, 5);
    defer ctx.deinit();
    var d = dispatch.Dispatcher.init(&ctx);

    const id = try ctx.createMetadata("{\"path\":\"/x\"}");
    try ctx.root.writeTextTagged("AB", glyphwire.default_style.fg, glyphwire.default_style.bg, id); // row 0
    ctx.root.setProperty(.{ .cursor = .{ .row = 1, .col = 0 } });
    try ctx.root.writeText("cd", glyphwire.default_style.fg, glyphwire.default_style.bg); // row 1
    // Name a row past the bottom to scroll row 0 ("AB", tagged) into history.
    ctx.root.setProperty(.{ .cursor = .{ .row = 2, .col = 0 } });
    try testz.expectEqual(ctx.root.history_len, 1);

    // view_offset 0: live viewport row 0 is now "cd", untagged.
    const live_msg =
        \\{"jsonrpc":"2.0","id":1,"method":"get_metadata","params":{"row":0,"col":0}}
    ;
    const live_result = try d.handle(alloc, live_msg);
    defer if (live_result.response) |r| alloc.free(r);
    try testz.expectTrue(std.mem.indexOf(u8, live_result.response.?, "\"id\":null") != null);

    // view_offset 1: the scrolled-off row 0 ("AB"), still carrying `id`.
    const hist_msg =
        \\{"jsonrpc":"2.0","id":2,"method":"get_metadata","params":{"row":0,"col":0,"view_offset":1}}
    ;
    const hist_result = try d.handle(alloc, hist_msg);
    defer if (hist_result.response) |r| alloc.free(r);
    try testz.expectTrue(std.mem.indexOf(u8, hist_result.response.?, "\"id\":1") != null);
    try testz.expectTrue(std.mem.indexOf(u8, hist_result.response.?, "\\\"path\\\":\\\"/x\\\"") != null);
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
    const load_resp = try d.handleLoadImage(alloc, .{ .id = .{ .integer = 1 }, .format = .png, .bytes = png.len }, &png);
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
    const load_resp = try d.handleLoadImage(alloc, .{ .id = .{ .integer = 1 }, .format = .png, .bytes = png.len }, &png);
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
    const load_resp = try d.handleLoadImage(alloc, .{ .id = .{ .integer = 1 }, .format = .png, .bytes = png.len }, &png);
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
    const bg_load_resp = try d.handleLoadImage(alloc, .{ .id = .{ .integer = 1 }, .format = .png, .bytes = bg_png.len }, &bg_png);
    alloc.free(bg_load_resp);
    try ctx.registerIcon("panel-fill", 1);

    const bg_message =
        \\{"jsonrpc":"2.0","method":"draw_icon","params":{"row":2,"col":3,"name":"panel-fill"}}
    ;
    try testz.expectTrue((try d.handle(alloc, bg_message)).response == null);

    const fg_png = fakePngBytes(32, 32);
    const fg_load_resp = try d.handleLoadImage(alloc, .{ .id = .{ .integer = 2 }, .format = .png, .bytes = fg_png.len }, &fg_png);
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
    const load_resp = try d.handleLoadImage(alloc, .{ .id = .{ .integer = 1 }, .format = .png, .bytes = png.len }, &png);
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
    const load_resp = try d.handleLoadImage(alloc, .{ .id = .{ .integer = 1 }, .format = .png, .bytes = png.len }, &png);
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
        const load_resp = try d.handleLoadImage(alloc, .{ .id = .{ .integer = id }, .format = .png, .bytes = png.len }, &png);
        defer alloc.free(load_resp);

        const parsed = try std.json.parseFromSlice(struct { result: struct { handle: glyphwire.ImageHandle } }, alloc, load_resp, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();

        var name_buf: [64]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "{s}/{s}", .{ style, piece });
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

// ─── Batch ───────────────────────────────────────────────────────────────

/// A notification-form `batch` (no outer `id`) applies every sub-message
/// in order, exactly as if each had arrived as its own frame, and
/// produces no response.
pub fn batchNotificationFormAppliesSubMessagesInOrderTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 20, 5, 0);
    defer ctx.deinit();
    var d = dispatch.Dispatcher.init(&ctx);

    const message =
        \\{"jsonrpc":"2.0","method":"batch","params":{"messages":[
        \\  {"method":"write_text","params":{"text":"one"}},
        \\  {"method":"set_property","params":{"property":"cursor","row":2,"col":0}},
        \\  {"method":"write_text","params":{"text":"two"}}
        \\]}}
    ;
    const decoded = try roundTripThroughWire(alloc, message);
    defer alloc.free(decoded);

    const result = try d.handle(alloc, decoded);
    try testz.expectTrue(result.response == null);
    try testz.expectTrue(result.broadcast == null);

    try testz.expectEqualStr("o", ctx.root.cell(0, 0).grapheme());
    try testz.expectEqualStr("e", ctx.root.cell(0, 2).grapheme());
    try testz.expectEqualStr("t", ctx.root.cell(2, 0).grapheme());
    try testz.expectEqualStr("o", ctx.root.cell(2, 2).grapheme());
    try testz.expectEqual(ctx.root.cursor.row, 2);
    try testz.expectEqual(ctx.root.cursor.col, 3);
}

const BatchResponseJson = struct {
    id: i64,
    result: struct {
        responses: []struct { id: i64, result: std.json.Value },
    },
};

/// A request-form `batch` (outer `id` present) returns one response
/// object per sub-message that carried an `id` and produced a result,
/// each tagged with that sub-message's own batch-local id so a caller
/// correlates by matching.
pub fn batchRequestFormReturnsResponsesCorrelatedBySubIdTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 20, 5, 0);
    defer ctx.deinit();
    var d = dispatch.Dispatcher.init(&ctx);

    const message =
        \\{"jsonrpc":"2.0","id":7,"method":"batch","params":{"messages":[
        \\  {"method":"create_metadata","params":{"json":"{\"a\":1}"},"id":1},
        \\  {"method":"write_text","params":{"text":"hi"}},
        \\  {"method":"create_metadata","params":{"json":"{\"b\":2}"},"id":2},
        \\  {"method":"get_property","params":{"property":"cursor"},"id":3}
        \\]}}
    ;
    const decoded = try roundTripThroughWire(alloc, message);
    defer alloc.free(decoded);

    const result = try d.handle(alloc, decoded);
    const body = result.response.?;
    defer alloc.free(body);

    const parsed = try std.json.parseFromSlice(BatchResponseJson, alloc, body, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    try testz.expectEqual(parsed.value.id, 7);
    const responses = parsed.value.result.responses;
    try testz.expectEqual(responses.len, 3);

    try testz.expectEqual(responses[0].id, 1);
    try testz.expectEqual(responses[1].id, 2);
    try testz.expectEqual(responses[2].id, 3);

    const h1 = responses[0].result.object.get("handle").?.integer;
    const h2 = responses[1].result.object.get("handle").?.integer;
    try testz.expectTrue(h1 != h2);
    try testz.expectEqualStr("{\"a\":1}", ctx.metadataJson(@intCast(h1)).?);
    try testz.expectEqualStr("{\"b\":2}", ctx.metadataJson(@intCast(h2)).?);

    // The `write_text` sub-message ran too (cursor advanced), and the
    // trailing `get_property` reports the post-write cursor.
    try testz.expectEqual(responses[2].result.object.get("col").?.integer, 2);
}

/// A sub-message whose handler errors (here: `draw_icon` naming an icon
/// no catalog entry exists for) is logged and skipped; the sub-messages
/// around it still apply, and the batch as a whole doesn't error.
pub fn batchSkipsFailingSubMessageAndContinuesTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 20, 5, 0);
    defer ctx.deinit();
    var d = dispatch.Dispatcher.init(&ctx);

    const message =
        \\{"jsonrpc":"2.0","method":"batch","params":{"messages":[
        \\  {"method":"write_text","params":{"text":"A"}},
        \\  {"method":"draw_icon","params":{"row":1,"col":0,"name":"no-such-icon"}},
        \\  {"method":"set_property","params":{"property":"cursor","row":2,"col":0}},
        \\  {"method":"write_text","params":{"text":"B"}}
        \\]}}
    ;
    const decoded = try roundTripThroughWire(alloc, message);
    defer alloc.free(decoded);

    const result = try d.handle(alloc, decoded);
    try testz.expectTrue(result.response == null);
    try testz.expectEqualStr("A", ctx.root.cell(0, 0).grapheme());
    try testz.expectEqualStr("B", ctx.root.cell(2, 0).grapheme());
}

/// `batch` and `load_image` can't be batched (no nesting; the binary
/// side-channel payload can't be framed inside the messages array) --
/// such a sub-message is skipped, the rest of the batch still runs.
pub fn batchRejectsNestedBatchAndLoadImageSubMessagesTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 20, 5, 0);
    defer ctx.deinit();
    var d = dispatch.Dispatcher.init(&ctx);

    const message =
        \\{"jsonrpc":"2.0","method":"batch","params":{"messages":[
        \\  {"method":"batch","params":{"messages":[]}},
        \\  {"method":"load_image","params":{"bytes":4},"id":9},
        \\  {"method":"write_text","params":{"text":"ok"}}
        \\]}}
    ;
    const decoded = try roundTripThroughWire(alloc, message);
    defer alloc.free(decoded);

    const result = try d.handle(alloc, decoded);
    try testz.expectTrue(result.response == null);
    try testz.expectEqualStr("o", ctx.root.cell(0, 0).grapheme());
    try testz.expectEqualStr("k", ctx.root.cell(0, 1).grapheme());
}

/// A request-form batch whose sub-messages are all notifications still
/// replies (the outer `id` needs an answer) with an empty `responses`
/// array.
pub fn batchRequestFormWithOnlyNotificationsReturnsEmptyResponsesTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 20, 5, 0);
    defer ctx.deinit();
    var d = dispatch.Dispatcher.init(&ctx);

    const message =
        \\{"jsonrpc":"2.0","id":3,"method":"batch","params":{"messages":[
        \\  {"method":"write_text","params":{"text":"x"}}
        \\]}}
    ;
    const decoded = try roundTripThroughWire(alloc, message);
    defer alloc.free(decoded);

    const result = try d.handle(alloc, decoded);
    const body = result.response.?;
    defer alloc.free(body);

    const parsed = try std.json.parseFromSlice(BatchResponseJson, alloc, body, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    try testz.expectEqual(parsed.value.id, 3);
    try testz.expectEqual(parsed.value.result.responses.len, 0);
}

// ─── selection & clipboard ─────────────────────────────────────────────

/// `set_selection` applies the selection and broadcasts a `selection`
/// notification; `get_selection_text` then returns the selected text.
pub fn setSelectionAppliesAndGetSelectionTextReturnsItTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 20, 4, 0);
    defer ctx.deinit();
    var d = dispatch.Dispatcher.init(&ctx);

    try testz.expectTrue((try d.handle(alloc,
        \\{"jsonrpc":"2.0","method":"write_text","params":{"text":"hello world"}}
    )).response == null);

    const set_result = try d.handle(alloc,
        \\{"jsonrpc":"2.0","method":"set_selection","params":{"anchor":{"above":0,"col":0},"active":{"above":0,"col":5}}}
    );
    const broadcast = set_result.broadcast.?;
    defer alloc.free(broadcast.body);
    try testz.expectEqualStr("selection", broadcast.event);
    try testz.expectTrue(std.mem.indexOf(u8, broadcast.body, "\"active\":true") != null);

    const Response = struct { jsonrpc: []const u8, id: u32, result: struct { text: []const u8 } };
    const text_body = (try d.handle(alloc,
        \\{"jsonrpc":"2.0","id":7,"method":"get_selection_text","params":{}}
    )).response.?;
    defer alloc.free(text_body);
    const parsed = try std.json.parseFromSlice(Response, alloc, text_body, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    try testz.expectEqualStr("hello", parsed.value.result.text);
}

/// `clear_selection` broadcasts an inactive `selection` and
/// `get_selection` then reports nothing selected.
pub fn clearSelectionBroadcastsInactiveTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 10, 3, 0);
    defer ctx.deinit();
    var d = dispatch.Dispatcher.init(&ctx);

    const set_result = try d.handle(alloc,
        \\{"jsonrpc":"2.0","method":"set_selection","params":{"anchor":{"above":0,"col":0},"active":{"above":0,"col":3}}}
    );
    if (set_result.broadcast) |b| alloc.free(b.body);
    const clear_result = try d.handle(alloc,
        \\{"jsonrpc":"2.0","method":"clear_selection","params":{}}
    );
    const broadcast = clear_result.broadcast.?;
    defer alloc.free(broadcast.body);
    try testz.expectTrue(std.mem.indexOf(u8, broadcast.body, "\"active\":false") != null);

    const Response = struct { jsonrpc: []const u8, id: u32, result: struct { active: bool } };
    const body = (try d.handle(alloc,
        \\{"jsonrpc":"2.0","id":1,"method":"get_selection","params":{}}
    )).response.?;
    defer alloc.free(body);
    const parsed = try std.json.parseFromSlice(Response, alloc, body, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    try testz.expectTrue(!parsed.value.result.active);
}

/// `toggle_highlight` resolves the cell to its metadata id, flips it in
/// the layer's highlighted-id set, and answers with a `HighlightState`
/// carrying every highlighted id and its stored blob. Toggling the same
/// cell again removes it; `clear_highlight` empties the set.
pub fn toggleHighlightFlipsIdAndReturnsStateTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 20, 4, 0);
    defer ctx.deinit();
    var d = dispatch.Dispatcher.init(&ctx);

    const create_result = try d.handle(alloc,
        \\{"jsonrpc":"2.0","id":1,"method":"create_metadata","params":{"json":"{\"kind\":\"directory\",\"path\":\"/tmp/d\"}"}}
    );
    defer if (create_result.response) |r| alloc.free(r);

    try testz.expectTrue((try d.handle(alloc,
        \\{"jsonrpc":"2.0","method":"write_text","params":{"text":"d","metadata_id":1}}
    )).response == null);

    // First toggle: id 1 becomes highlighted; response carries it + blob.
    const on = try d.handle(alloc,
        \\{"jsonrpc":"2.0","id":2,"method":"toggle_highlight","params":{"row":0,"col":0}}
    );
    defer if (on.response) |r| alloc.free(r);
    try testz.expectEqual(ctx.root.highlighted_ids.items.len, 1);
    try testz.expectEqual(ctx.root.highlighted_ids.items[0], 1);
    try testz.expectTrue(std.mem.indexOf(u8, on.response.?, "\"id\":1") != null);
    try testz.expectTrue(std.mem.indexOf(u8, on.response.?, "\\\"path\\\":\\\"/tmp/d\\\"") != null);

    // A cell with no tag: no change.
    const untagged = try d.handle(alloc,
        \\{"jsonrpc":"2.0","id":3,"method":"toggle_highlight","params":{"row":0,"col":5}}
    );
    defer if (untagged.response) |r| alloc.free(r);
    try testz.expectEqual(ctx.root.highlighted_ids.items.len, 1);

    // Toggling the same tagged cell again removes the id.
    const off = try d.handle(alloc,
        \\{"jsonrpc":"2.0","id":4,"method":"toggle_highlight","params":{"row":0,"col":0}}
    );
    defer if (off.response) |r| alloc.free(r);
    try testz.expectEqual(ctx.root.highlighted_ids.items.len, 0);
    try testz.expectTrue(std.mem.indexOf(u8, off.response.?, "\"entries\":[]") != null);
}

/// `set_highlight` replaces the id set wholesale; `clear_highlight` empties
/// it. Both answer with the resulting `HighlightState`.
pub fn setAndClearHighlightReplaceTheIdSetTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 20, 4, 0);
    defer ctx.deinit();
    var d = dispatch.Dispatcher.init(&ctx);

    const set_result = try d.handle(alloc,
        \\{"jsonrpc":"2.0","id":1,"method":"set_highlight","params":{"ids":[3,7,9]}}
    );
    defer if (set_result.response) |r| alloc.free(r);
    try testz.expectEqual(ctx.root.highlighted_ids.items.len, 3);
    // No metadata was created, so every entry's json is null (dangling).
    try testz.expectTrue(std.mem.indexOf(u8, set_result.response.?, "\"id\":7") != null);

    const clear_result = try d.handle(alloc,
        \\{"jsonrpc":"2.0","id":2,"method":"clear_highlight","params":{}}
    );
    defer if (clear_result.response) |r| alloc.free(r);
    try testz.expectEqual(ctx.root.highlighted_ids.items.len, 0);
}

/// `set_clipboard` stores the text on the context; `get_clipboard`
/// returns it.
pub fn setClipboardThenGetClipboardRoundTripTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 10, 3, 0);
    defer ctx.deinit();
    var d = dispatch.Dispatcher.init(&ctx);

    try testz.expectTrue((try d.handle(alloc,
        \\{"jsonrpc":"2.0","method":"set_clipboard","params":{"text":"clip me"}}
    )).response == null);
    try testz.expectEqualStr("clip me", ctx.clipboardText());
    try testz.expectEqual(ctx.clipboard_serial, 1);

    const Response = struct { jsonrpc: []const u8, id: u32, result: struct { text: []const u8 } };
    const body = (try d.handle(alloc,
        \\{"jsonrpc":"2.0","id":9,"method":"get_clipboard","params":{}}
    )).response.?;
    defer alloc.free(body);
    const parsed = try std.json.parseFromSlice(Response, alloc, body, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    try testz.expectEqualStr("clip me", parsed.value.result.text);
}

/// A connection can subscribe to the new `selection` and `clipboard`
/// event streams.
pub fn subscribeAcceptsSelectionAndClipboardTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 10, 3, 0);
    defer ctx.deinit();
    var d = dispatch.Dispatcher.init(&ctx);

    const ack = (try d.handle(alloc,
        \\{"jsonrpc":"2.0","id":1,"method":"subscribe","params":{"events":["selection","clipboard"]}}
    )).response.?;
    alloc.free(ack);
    try testz.expectTrue(d.subscriptions.selection);
    try testz.expectTrue(d.subscriptions.clipboard);
}

// ─── Layer geometry, visibility and stacking over the wire ──────────────

/// Runs one JSON body through the framing round trip and the dispatcher,
/// asserting it produced no response (i.e. it was a notification). Any
/// broadcast it did produce is freed here -- the real caller is
/// `Server.serveConnection`, which owns that body.
fn notifyThrough(alloc: std.mem.Allocator, d: *dispatch.Dispatcher, body: []const u8) !void {
    const decoded = try roundTripThroughWire(alloc, body);
    defer alloc.free(decoded);
    const result = try d.handle(alloc, decoded);
    if (result.broadcast) |b| alloc.free(b.body);
    try testz.expectTrue(result.response == null);
}

pub fn setPropertySizeResizesANonRootLayerTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 80, 24, 0);
    defer ctx.deinit();
    var d = dispatch.Dispatcher.init(&ctx);
    const pane = try ctx.createLayer(null, null, 0);

    try notifyThrough(alloc, &d,
        \\{"jsonrpc":"2.0","method":"set_property","params":{"layer":1,"property":"size","cols":24,"rows":10}}
    );

    try testz.expectEqual(ctx.layerPtr(pane).?.width, 24);
    try testz.expectEqual(ctx.layerPtr(pane).?.height, 10);
    // The root is untouched -- the host owns the window size.
    try testz.expectEqual(ctx.root.width, 80);
}

pub fn setPropertySizeOnRootIsRejectedTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 80, 24, 0);
    defer ctx.deinit();
    var d = dispatch.Dispatcher.init(&ctx);

    const body =
        \\{"jsonrpc":"2.0","method":"set_property","params":{"property":"size","cols":5,"rows":5}}
    ;
    const decoded = try roundTripThroughWire(alloc, body);
    defer alloc.free(decoded);

    try testz.expectError(d.handle(alloc, decoded), error.ReadOnlyProperty);
    try testz.expectEqual(ctx.root.width, 80);
}

pub fn visibilityPropertyRoundTripsTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 80, 24, 0);
    defer ctx.deinit();
    var d = dispatch.Dispatcher.init(&ctx);
    _ = try ctx.createLayer(20, 20, 0);

    try notifyThrough(alloc, &d,
        \\{"jsonrpc":"2.0","method":"set_property","params":{"layer":1,"property":"visibility","visible":false}}
    );

    const get_msg =
        \\{"jsonrpc":"2.0","id":4,"method":"get_property","params":{"layer":1,"property":"visibility"}}
    ;
    const get_decoded = try roundTripThroughWire(alloc, get_msg);
    defer alloc.free(get_decoded);
    const response_body = (try d.handle(alloc, get_decoded)).response.?;
    defer alloc.free(response_body);

    const Response = struct { id: i64, result: struct { visible: bool } };
    const parsed = try std.json.parseFromSlice(Response, alloc, response_body, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();
    try testz.expectEqual(parsed.value.id, 4);
    try testz.expectFalse(parsed.value.result.visible);
}

pub fn cellPositionPropertyRoundTripsTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 80, 24, 0);
    defer ctx.deinit();
    ctx.setCellMetrics(9, 18);
    var d = dispatch.Dispatcher.init(&ctx);
    const pane = try ctx.createLayer(20, 20, 0);

    try notifyThrough(alloc, &d,
        \\{"jsonrpc":"2.0","method":"set_property","params":{"layer":1,"property":"cell_position","row":3,"col":4}}
    );
    try testz.expectEqual(ctx.layerPtr(pane).?.pos.x, 36.0);
    try testz.expectEqual(ctx.layerPtr(pane).?.pos.y, 54.0);

    const get_msg =
        \\{"jsonrpc":"2.0","id":5,"method":"get_property","params":{"layer":1,"property":"cell_position"}}
    ;
    const get_decoded = try roundTripThroughWire(alloc, get_msg);
    defer alloc.free(get_decoded);
    const response_body = (try d.handle(alloc, get_decoded)).response.?;
    defer alloc.free(response_body);

    const Response = struct { id: i64, result: struct { row: usize, col: usize } };
    const parsed = try std.json.parseFromSlice(Response, alloc, response_body, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();
    try testz.expectEqual(parsed.value.result.row, 3);
    try testz.expectEqual(parsed.value.result.col, 4);
}

pub fn raiseAndLowerLayerNotificationsTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 80, 24, 0);
    defer ctx.deinit();
    var d = dispatch.Dispatcher.init(&ctx);
    const a = try ctx.createLayer(4, 4, 0);
    const b = try ctx.createLayer(4, 4, 0);

    try notifyThrough(alloc, &d,
        \\{"jsonrpc":"2.0","method":"raise_layer","params":{"layer":1}}
    );
    try testz.expectEqual(ctx.layer_order.items[1], a);

    try notifyThrough(alloc, &d,
        \\{"jsonrpc":"2.0","method":"lower_layer","params":{"layer":1,"below":2}}
    );
    try testz.expectEqual(ctx.layer_order.items[0], a);
    try testz.expectEqual(ctx.layer_order.items[1], b);
}

pub fn raiseLayerRejectsAnUnknownHandleTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 80, 24, 0);
    defer ctx.deinit();
    var d = dispatch.Dispatcher.init(&ctx);

    const body =
        \\{"jsonrpc":"2.0","method":"raise_layer","params":{"layer":42}}
    ;
    const decoded = try roundTripThroughWire(alloc, body);
    defer alloc.free(decoded);
    try testz.expectError(d.handle(alloc, decoded), error.UnknownLayer);
}

// ─── Viewport, scroll offset and splits over the wire ───────────────────

pub fn viewportAndScrollOffsetRoundTripTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 80, 24, 0);
    defer ctx.deinit();
    var d = dispatch.Dispatcher.init(&ctx);
    const pane = try ctx.createLayer(90, 500, 0);

    try notifyThrough(alloc, &d,
        \\{"jsonrpc":"2.0","method":"set_property","params":{"layer":1,"property":"viewport","cols":30,"rows":40}}
    );
    try notifyThrough(alloc, &d,
        \\{"jsonrpc":"2.0","method":"set_property","params":{"layer":1,"property":"scroll_offset","row":100,"col":10}}
    );
    try testz.expectEqual(ctx.layerPtr(pane).?.scroll_off.row, 100);

    const get_msg =
        \\{"jsonrpc":"2.0","id":9,"method":"get_property","params":{"layer":1,"property":"scroll_offset"}}
    ;
    const get_decoded = try roundTripThroughWire(alloc, get_msg);
    defer alloc.free(get_decoded);
    const response_body = (try d.handle(alloc, get_decoded)).response.?;
    defer alloc.free(response_body);

    const Response = struct {
        id: i64,
        result: struct { row: usize, col: usize, max_row: usize, max_col: usize },
    };
    const parsed = try std.json.parseFromSlice(Response, alloc, response_body, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();
    try testz.expectEqual(parsed.value.result.row, 100);
    try testz.expectEqual(parsed.value.result.col, 10);
    try testz.expectEqual(parsed.value.result.max_row, 460);
    try testz.expectEqual(parsed.value.result.max_col, 60);
}

pub fn scrollOffsetIsClampedServerSideTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 80, 24, 0);
    defer ctx.deinit();
    var d = dispatch.Dispatcher.init(&ctx);
    const pane = try ctx.createLayer(40, 100, 0);

    try notifyThrough(alloc, &d,
        \\{"jsonrpc":"2.0","method":"set_property","params":{"layer":1,"property":"viewport","cols":40,"rows":10}}
    );
    try notifyThrough(alloc, &d,
        \\{"jsonrpc":"2.0","method":"set_property","params":{"layer":1,"property":"scroll_offset","row":9999,"col":9999}}
    );

    // A client can't park the viewport off the end of its own content.
    try testz.expectEqual(ctx.layerPtr(pane).?.scroll_off.row, 90);
    try testz.expectEqual(ctx.layerPtr(pane).?.scroll_off.col, 0);
}

pub fn scrollbarsPropertyRoundTripsTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 80, 24, 0);
    defer ctx.deinit();
    var d = dispatch.Dispatcher.init(&ctx);
    _ = try ctx.createLayer(90, 500, 0);

    try notifyThrough(alloc, &d,
        \\{"jsonrpc":"2.0","method":"set_property","params":{"layer":1,"property":"viewport","cols":30,"rows":40}}
    );
    try notifyThrough(alloc, &d,
        \\{"jsonrpc":"2.0","method":"set_property","params":{"layer":1,"property":"scrollbars","vertical":true,"horizontal":true}}
    );

    const get_msg =
        \\{"jsonrpc":"2.0","id":11,"method":"get_property","params":{"layer":1,"property":"scrollbars"}}
    ;
    const get_decoded = try roundTripThroughWire(alloc, get_msg);
    defer alloc.free(get_decoded);
    const response_body = (try d.handle(alloc, get_decoded)).response.?;
    defer alloc.free(response_body);

    const Response = struct {
        result: struct {
            vertical: bool,
            horizontal: bool,
            row: usize,
            col: usize,
            max_row: usize,
            max_col: usize,
        },
    };
    const parsed = try std.json.parseFromSlice(Response, alloc, response_body, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();
    try testz.expectTrue(parsed.value.result.vertical);
    try testz.expectTrue(parsed.value.result.horizontal);
    try testz.expectEqual(parsed.value.result.max_row, 460);
}

pub fn createSplitReturnsAHandleTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 80, 24, 0);
    defer ctx.deinit();
    var d = dispatch.Dispatcher.init(&ctx);

    const msg =
        \\{"jsonrpc":"2.0","id":2,"method":"create_split","params":{"axis":"row"}}
    ;
    const decoded = try roundTripThroughWire(alloc, msg);
    defer alloc.free(decoded);
    const body = (try d.handle(alloc, decoded)).response.?;
    defer alloc.free(body);

    const Response = struct { result: struct { handle: glyphwire.SplitHandle } };
    const parsed = try std.json.parseFromSlice(Response, alloc, body, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();
    try testz.expectEqual(parsed.value.result.handle, 1);
    try testz.expectEqual(ctx.splits.getPtr(1).?.axis, .row);
}

pub fn createSplitRejectsABadAxisTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 80, 24, 0);
    defer ctx.deinit();
    var d = dispatch.Dispatcher.init(&ctx);

    const msg =
        \\{"jsonrpc":"2.0","id":2,"method":"create_split","params":{"axis":"diagonal"}}
    ;
    const decoded = try roundTripThroughWire(alloc, msg);
    defer alloc.free(decoded);
    try testz.expectError(d.handle(alloc, decoded), error.InvalidSplitAxis);
}

pub fn splitChildrenLayOutAndBroadcastTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 100, 40, 0);
    defer ctx.deinit();
    var d = dispatch.Dispatcher.init(&ctx);
    const tree = try ctx.createLayer(30, 200, 0);
    _ = try ctx.createLayer(200, 500, 0);
    _ = try ctx.createSplit(.row);

    try notifyThrough(alloc, &d,
        \\{"jsonrpc":"2.0","method":"set_split_children","params":{"split":1,"children":[{"layer":1,"fixed":20},{"layer":2,"weight":1}]}}
    );

    // Nothing is laid out until a root split is named, so the broadcast
    // comes with `set_root_split`, not before it.
    const msg =
        \\{"jsonrpc":"2.0","method":"set_root_split","params":{"split":1}}
    ;
    const decoded = try roundTripThroughWire(alloc, msg);
    defer alloc.free(decoded);
    const result = try d.handle(alloc, decoded);
    const broadcast = result.broadcast.?;
    defer alloc.free(broadcast.body);
    try testz.expectEqualStr(broadcast.event, "layout");

    const Notif = struct {
        method: []const u8,
        params: struct {
            layers: []const struct { layer: u32, row: usize, col: usize, cols: usize, rows: usize },
        },
    };
    const parsed = try std.json.parseFromSlice(Notif, alloc, broadcast.body, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();
    try testz.expectEqualStr(parsed.value.method, "layout");
    try testz.expectEqual(parsed.value.params.layers.len, 2);
    try testz.expectEqual(parsed.value.params.layers[0].cols, 20);
    try testz.expectEqual(parsed.value.params.layers[1].col, 21);
    try testz.expectEqual(ctx.layerPtr(tree).?.viewportCols(), 20);
}

pub fn splitChildRejectsAnAmbiguousTargetTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 100, 40, 0);
    defer ctx.deinit();
    var d = dispatch.Dispatcher.init(&ctx);
    _ = try ctx.createLayer(10, 10, 0);
    _ = try ctx.createSplit(.row);

    // Both a layer and a split named in one child: malformed, not
    // something to pick a winner for.
    const both =
        \\{"jsonrpc":"2.0","method":"set_split_children","params":{"split":1,"children":[{"layer":1,"split":1}]}}
    ;
    const both_decoded = try roundTripThroughWire(alloc, both);
    defer alloc.free(both_decoded);
    try testz.expectError(d.handle(alloc, both_decoded), error.InvalidSplitChild);

    const neither =
        \\{"jsonrpc":"2.0","method":"set_split_children","params":{"split":1,"children":[{"weight":1}]}}
    ;
    const neither_decoded = try roundTripThroughWire(alloc, neither);
    defer alloc.free(neither_decoded);
    try testz.expectError(d.handle(alloc, neither_decoded), error.InvalidSplitChild);
}

pub fn moveDividerOverTheWireTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 100, 40, 0);
    defer ctx.deinit();
    var d = dispatch.Dispatcher.init(&ctx);
    const tree = try ctx.createLayer(30, 200, 0);
    _ = try ctx.createLayer(200, 500, 0);
    const split = try ctx.createSplit(.row);
    try ctx.setSplitChildren(split, &.{
        .{ .target = .{ .layer = 1 }, .size = .{ .fixed = 20 } },
        .{ .target = .{ .layer = 2 }, .size = .{ .weight = 1 } },
    });
    try ctx.setRootSplit(split);
    try ctx.layoutSplits(null, null);

    try notifyThrough(alloc, &d,
        \\{"jsonrpc":"2.0","method":"move_divider","params":{"split":1,"index":0,"delta":5}}
    );
    try testz.expectEqual(ctx.layerPtr(tree).?.viewportCols(), 25);
}

pub fn splitMessagesRejectUnknownHandlesTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 100, 40, 0);
    defer ctx.deinit();
    var d = dispatch.Dispatcher.init(&ctx);

    const msg =
        \\{"jsonrpc":"2.0","method":"set_root_split","params":{"split":42}}
    ;
    const decoded = try roundTripThroughWire(alloc, msg);
    defer alloc.free(decoded);
    try testz.expectError(d.handle(alloc, decoded), error.UnknownSplit);
}

pub fn scrollAndLayoutAreSubscribableTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 80, 24, 0);
    defer ctx.deinit();
    var d = dispatch.Dispatcher.init(&ctx);

    const msg =
        \\{"jsonrpc":"2.0","id":3,"method":"subscribe","params":{"events":["layout","scroll_offset"]}}
    ;
    const decoded = try roundTripThroughWire(alloc, msg);
    defer alloc.free(decoded);
    const body = (try d.handle(alloc, decoded)).response.?;
    defer alloc.free(body);

    try testz.expectTrue(d.subscriptions.layout);
    // `scroll_offset` rides the `scroll` subscription -- a client that
    // wants to know the view moved wants both kinds.
    try testz.expectTrue(d.subscriptions.scroll);
    try testz.expectTrue(d.subscriptions.has("scroll_offset"));
}

// ── Layer ownership: create records an owner, destroy enforces it, ──────
//    adopt adds a co-owner (see `core.ConnId` / `Dispatcher.conn_id`).

pub fn createLayerOverConnectionRecordsOwnerTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 40, 10, 0);
    defer ctx.deinit();
    var session = try glyphwire.Session.init(alloc, &ctx);
    defer session.deinit();
    var d = dispatch.Dispatcher.initForConnection(&session, 7);

    const create =
        \\{"jsonrpc":"2.0","id":1,"method":"create_layer","params":{"scrollback_rows":0}}
    ;
    const result = try d.handle(alloc, create);
    defer if (result.response) |r| alloc.free(r);
    try testz.expectTrue(std.mem.indexOf(u8, result.response.?, "\"handle\":1") != null);

    try testz.expectTrue(ctx.layerHasOwner(1, 7));
    try testz.expectTrue(!ctx.layerHasOwner(1, 8));
}

pub fn destroyLayerFromNonOwnerConnectionIsRejectedTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 40, 10, 0);
    defer ctx.deinit();
    var session = try glyphwire.Session.init(alloc, &ctx);
    defer session.deinit();

    var owner = dispatch.Dispatcher.initForConnection(&session, 7);
    const create =
        \\{"jsonrpc":"2.0","id":1,"method":"create_layer","params":{"scrollback_rows":0}}
    ;
    const created = try owner.handle(alloc, create);
    if (created.response) |r| alloc.free(r);

    var other = dispatch.Dispatcher.initForConnection(&session, 8);
    const destroy =
        \\{"jsonrpc":"2.0","method":"destroy_layer","params":{"layer":1}}
    ;
    try testz.expectError(other.handle(alloc, destroy), dispatch.DispatchError.LayerPermissionDenied);
    try testz.expectTrue(ctx.layerPtr(1) != null);
}

pub fn destroyLayerFromOwnerConnectionSucceedsTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 40, 10, 0);
    defer ctx.deinit();
    var session = try glyphwire.Session.init(alloc, &ctx);
    defer session.deinit();
    var d = dispatch.Dispatcher.initForConnection(&session, 7);

    const create =
        \\{"jsonrpc":"2.0","id":1,"method":"create_layer","params":{"scrollback_rows":0}}
    ;
    const created = try d.handle(alloc, create);
    if (created.response) |r| alloc.free(r);

    const destroy =
        \\{"jsonrpc":"2.0","method":"destroy_layer","params":{"layer":1}}
    ;
    try testz.expectTrue((try d.handle(alloc, destroy)).response == null);
    try testz.expectTrue(ctx.layerPtr(1) == null);
}

pub fn adoptLayerLetsSecondConnectionDestroyItTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 40, 10, 0);
    defer ctx.deinit();
    var session = try glyphwire.Session.init(alloc, &ctx);
    defer session.deinit();

    var creator = dispatch.Dispatcher.initForConnection(&session, 7);
    const create =
        \\{"jsonrpc":"2.0","id":1,"method":"create_layer","params":{"scrollback_rows":0}}
    ;
    const created = try creator.handle(alloc, create);
    if (created.response) |r| alloc.free(r);

    var adopter = dispatch.Dispatcher.initForConnection(&session, 8);
    const adopt =
        \\{"jsonrpc":"2.0","method":"adopt_layer","params":{"layer":1}}
    ;
    try testz.expectTrue((try adopter.handle(alloc, adopt)).response == null);
    try testz.expectTrue(ctx.layerHasOwner(1, 7));
    try testz.expectTrue(ctx.layerHasOwner(1, 8));

    const destroy =
        \\{"jsonrpc":"2.0","method":"destroy_layer","params":{"layer":1}}
    ;
    try testz.expectTrue((try adopter.handle(alloc, destroy)).response == null);
    try testz.expectTrue(ctx.layerPtr(1) == null);
}

pub fn adoptLayerUnknownHandleErrorsTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 40, 10, 0);
    defer ctx.deinit();
    var session = try glyphwire.Session.init(alloc, &ctx);
    defer session.deinit();
    var d = dispatch.Dispatcher.initForConnection(&session, 8);

    const adopt =
        \\{"jsonrpc":"2.0","method":"adopt_layer","params":{"layer":999}}
    ;
    try testz.expectError(d.handle(alloc, adopt), dispatch.DispatchError.UnknownLayer);
}

pub fn inProcessDispatcherBypassesLayerOwnershipTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 40, 10, 0);
    defer ctx.deinit();
    var session = try glyphwire.Session.init(alloc, &ctx);
    defer session.deinit();

    // No connection id: `init`, not `initForConnection`.
    var in_process = dispatch.Dispatcher.init(&ctx);
    const create =
        \\{"jsonrpc":"2.0","id":1,"method":"create_layer","params":{"scrollback_rows":0}}
    ;
    const created = try in_process.handle(alloc, create);
    if (created.response) |r| alloc.free(r);

    // The in-process layer has no owners, so a real connection can't
    // destroy it...
    var conn = dispatch.Dispatcher.initForConnection(&session, 9);
    const destroy =
        \\{"jsonrpc":"2.0","method":"destroy_layer","params":{"layer":1}}
    ;
    try testz.expectError(conn.handle(alloc, destroy), dispatch.DispatchError.LayerPermissionDenied);

    // ...but the in-process dispatcher itself still can.
    try testz.expectTrue((try in_process.handle(alloc, destroy)).response == null);
    try testz.expectTrue(ctx.layerPtr(1) == null);
}

// ── Error ring: a client subscribes to "error", then pulls the failed ───
//    notifications it sent with get_errors (see Dispatcher.recordError).

const bad_destroy =
    \\{"jsonrpc":"2.0","method":"destroy_layer","params":{"layer":999}}
;
const subscribe_error =
    \\{"jsonrpc":"2.0","id":9,"method":"subscribe","params":{"events":["error"]}}
;
const get_errors =
    \\{"jsonrpc":"2.0","id":1,"method":"get_errors","params":{}}
;

fn drainErrors(d: *dispatch.Dispatcher, alloc: std.mem.Allocator) ![]u8 {
    const r = try d.handle(alloc, get_errors);
    return r.response.?;
}

pub fn subscribeErrorSetsTheFlagTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 40, 10, 0);
    defer ctx.deinit();
    var d = dispatch.Dispatcher.init(&ctx);

    const ack = (try d.handle(alloc, subscribe_error)).response.?;
    alloc.free(ack);
    try testz.expectTrue(d.subscriptions.error_events);
}

pub fn getErrorsRecordsNothingWithoutSubscriptionTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 40, 10, 0);
    defer ctx.deinit();
    var d = dispatch.Dispatcher.init(&ctx);

    // The notification still fails -- it's just not recorded anywhere.
    try testz.expectError(d.handle(alloc, bad_destroy), dispatch.DispatchError.UnknownLayer);

    const body = try drainErrors(&d, alloc);
    defer alloc.free(body);
    try testz.expectTrue(std.mem.indexOf(u8, body, "\"errors\":[]") != null);
    try testz.expectTrue(std.mem.indexOf(u8, body, "\"dropped\":0") != null);
}

pub fn getErrorsReturnsFailedNotificationWhenSubscribedTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 40, 10, 0);
    defer ctx.deinit();
    var d = dispatch.Dispatcher.init(&ctx);

    const ack = (try d.handle(alloc, subscribe_error)).response.?;
    alloc.free(ack);

    try testz.expectError(d.handle(alloc, bad_destroy), dispatch.DispatchError.UnknownLayer);

    const body = try drainErrors(&d, alloc);
    defer alloc.free(body);
    try testz.expectTrue(std.mem.indexOf(u8, body, "\"method\":\"destroy_layer\"") != null);
    try testz.expectTrue(std.mem.indexOf(u8, body, "\"code\":\"UnknownLayer\"") != null);
    try testz.expectTrue(std.mem.indexOf(u8, body, "\"seq\":1") != null);
    try testz.expectTrue(std.mem.indexOf(u8, body, "\"dropped\":0") != null);
}

pub fn getErrorsDrainsTheRingTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 40, 10, 0);
    defer ctx.deinit();
    var d = dispatch.Dispatcher.init(&ctx);

    const ack = (try d.handle(alloc, subscribe_error)).response.?;
    alloc.free(ack);
    try testz.expectError(d.handle(alloc, bad_destroy), dispatch.DispatchError.UnknownLayer);

    const first = try drainErrors(&d, alloc);
    defer alloc.free(first);
    try testz.expectEqual(std.mem.count(u8, first, "\"method\""), 1);

    const second = try drainErrors(&d, alloc);
    defer alloc.free(second);
    try testz.expectTrue(std.mem.indexOf(u8, second, "\"errors\":[]") != null);
}

pub fn getErrorsRingDropsOldestBeyondCapacityTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 40, 10, 0);
    defer ctx.deinit();
    var d = dispatch.Dispatcher.init(&ctx);

    const ack = (try d.handle(alloc, subscribe_error)).response.?;
    alloc.free(ack);

    // Seven failures into a five-slot ring: the first two are dropped.
    var n: usize = 0;
    while (n < 7) : (n += 1) {
        try testz.expectError(d.handle(alloc, bad_destroy), dispatch.DispatchError.UnknownLayer);
    }

    const body = try drainErrors(&d, alloc);
    defer alloc.free(body);
    try testz.expectEqual(std.mem.count(u8, body, "\"method\""), dispatch.error_ring_capacity);
    try testz.expectTrue(std.mem.indexOf(u8, body, "\"dropped\":2") != null);
    // Oldest kept is seq 3, newest is seq 7.
    try testz.expectTrue(std.mem.indexOf(u8, body, "\"seq\":3") != null);
    try testz.expectTrue(std.mem.indexOf(u8, body, "\"seq\":7") != null);
    try testz.expectTrue(std.mem.indexOf(u8, body, "\"seq\":2") == null);

    // dropped resets with the drain.
    const after = try drainErrors(&d, alloc);
    defer alloc.free(after);
    try testz.expectTrue(std.mem.indexOf(u8, after, "\"dropped\":0") != null);
}

pub fn getErrorsRecordsBatchedNotificationFailureTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 40, 10, 0);
    defer ctx.deinit();
    var d = dispatch.Dispatcher.init(&ctx);

    const ack = (try d.handle(alloc, subscribe_error)).response.?;
    alloc.free(ack);

    // Notification-form batch: sub-message failures are logged and
    // skipped by handleBatch, and (because it routes through
    // dispatchEnvelope) also recorded.
    const batch =
        \\{"jsonrpc":"2.0","method":"batch","params":{"messages":[{"jsonrpc":"2.0","method":"destroy_layer","params":{"layer":999}}]}}
    ;
    try testz.expectTrue((try d.handle(alloc, batch)).response == null);

    const body = try drainErrors(&d, alloc);
    defer alloc.free(body);
    try testz.expectTrue(std.mem.indexOf(u8, body, "\"method\":\"destroy_layer\"") != null);
    try testz.expectTrue(std.mem.indexOf(u8, body, "\"code\":\"UnknownLayer\"") != null);
}

// ── Context management: create/destroy/activate/attach/adopt ───────────

pub fn createContextRetargetsTheConnectionAndBroadcastsTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var root = try glyphwire.Context.init(alloc, 40, 10, 0);
    defer root.deinit();
    var session = try glyphwire.Session.init(alloc, &root);
    defer session.deinit();
    var d = dispatch.Dispatcher.initForConnection(&session, 7);

    const result = try d.handle(alloc,
        \\{"jsonrpc":"2.0","id":1,"method":"create_context","params":{"scrollback_rows":0}}
    );
    defer if (result.response) |r| alloc.free(r);
    defer if (result.broadcast) |b| alloc.free(b.body);

    try testz.expectTrue(std.mem.indexOf(u8, result.response.?, "\"context\":1") != null);
    try testz.expectTrue(result.broadcast != null);
    try testz.expectTrue(std.mem.eql(u8, result.broadcast.?.event, "context"));
    try testz.expectTrue(std.mem.indexOf(u8, result.broadcast.?.body, "\"context\":1") != null);

    // The dispatcher now points at the new context, and it's visible.
    try testz.expectEqual(d.active_ctx, @as(glyphwire.ContextHandle, 1));
    try testz.expectEqual(session.visibleStackTop(), @as(glyphwire.ContextHandle, 1));
    try testz.expectEqual(session.contextPtr(1).?, d.ctx);
}

pub fn writeTextAfterCreateContextLandsOnTheNewContextNotRootTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var root = try glyphwire.Context.init(alloc, 40, 10, 0);
    defer root.deinit();
    var session = try glyphwire.Session.init(alloc, &root);
    defer session.deinit();
    var d = dispatch.Dispatcher.initForConnection(&session, 7);

    const created = try d.handle(alloc,
        \\{"jsonrpc":"2.0","id":1,"method":"create_context","params":{"scrollback_rows":0}}
    );
    if (created.response) |r| alloc.free(r);
    if (created.broadcast) |b| alloc.free(b.body);

    _ = try d.handle(alloc,
        \\{"jsonrpc":"2.0","method":"write_text","params":{"text":"hi"}}
    );

    // The shell's root context is untouched; the new context has it.
    try testz.expectEqual(root.root.cell(0, 0).grapheme_len, @as(u8, 0));
    try testz.expectTrue(std.mem.eql(u8, session.contextPtr(1).?.root.cell(0, 0).grapheme(), "h"));
}

pub fn destroyContextFromNonOwnerIsRejectedTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var root = try glyphwire.Context.init(alloc, 40, 10, 0);
    defer root.deinit();
    var session = try glyphwire.Session.init(alloc, &root);
    defer session.deinit();

    var owner = dispatch.Dispatcher.initForConnection(&session, 7);
    const created = try owner.handle(alloc,
        \\{"jsonrpc":"2.0","id":1,"method":"create_context","params":{"scrollback_rows":0}}
    );
    if (created.response) |r| alloc.free(r);
    if (created.broadcast) |b| alloc.free(b.body);

    var other = dispatch.Dispatcher.initForConnection(&session, 8);
    try testz.expectError(other.handle(alloc,
        \\{"jsonrpc":"2.0","method":"destroy_context","params":{"context":1}}
    ), dispatch.DispatchError.ContextPermissionDenied);
    try testz.expectTrue(session.contextPtr(1) != null);
}

pub fn destroyContextFromOwnerRestoresThePreviousVisibleTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var root = try glyphwire.Context.init(alloc, 40, 10, 0);
    defer root.deinit();
    var session = try glyphwire.Session.init(alloc, &root);
    defer session.deinit();
    var d = dispatch.Dispatcher.initForConnection(&session, 7);

    const created = try d.handle(alloc,
        \\{"jsonrpc":"2.0","id":1,"method":"create_context","params":{"scrollback_rows":0}}
    );
    if (created.response) |r| alloc.free(r);
    if (created.broadcast) |b| alloc.free(b.body);

    const gone = try d.handle(alloc,
        \\{"jsonrpc":"2.0","method":"destroy_context","params":{"context":1}}
    );
    defer if (gone.broadcast) |b| alloc.free(b.body);
    try testz.expectTrue(gone.broadcast != null);
    try testz.expectEqual(session.visibleStackTop(), glyphwire.root_context_handle);
    // The dispatcher fell back to the visible (root) context.
    try testz.expectEqual(d.active_ctx, glyphwire.root_context_handle);
    try testz.expectEqual(d.ctx, &root);

    try testz.expectError(d.handle(alloc,
        \\{"jsonrpc":"2.0","method":"destroy_context","params":{"context":0}}
    ), dispatch.DispatchError.RootContextImmutable);
}

pub fn activateContextChangesVisibilityNotWhichContextTheConnectionDrawsOnTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var root = try glyphwire.Context.init(alloc, 40, 10, 0);
    defer root.deinit();
    var session = try glyphwire.Session.init(alloc, &root);
    defer session.deinit();
    var d = dispatch.Dispatcher.initForConnection(&session, 7);

    const created = try d.handle(alloc,
        \\{"jsonrpc":"2.0","id":1,"method":"create_context","params":{"scrollback_rows":0}}
    );
    if (created.response) |r| alloc.free(r);
    if (created.broadcast) |b| alloc.free(b.body);

    // Background self: show root, but keep drawing on context 1.
    const bg = try d.handle(alloc,
        \\{"jsonrpc":"2.0","method":"activate_context","params":{"context":0}}
    );
    if (bg.broadcast) |b| alloc.free(b.body);
    try testz.expectEqual(session.visibleStackTop(), glyphwire.root_context_handle);
    try testz.expectEqual(d.active_ctx, @as(glyphwire.ContextHandle, 1));

    _ = try d.handle(alloc,
        \\{"jsonrpc":"2.0","method":"write_text","params":{"text":"x"}}
    );
    try testz.expectTrue(std.mem.eql(u8, session.contextPtr(1).?.root.cell(0, 0).grapheme(), "x"));
    try testz.expectEqual(root.root.cell(0, 0).grapheme_len, @as(u8, 0));

    // Restore self.
    const fg = try d.handle(alloc,
        \\{"jsonrpc":"2.0","method":"activate_context","params":{"context":1}}
    );
    if (fg.broadcast) |b| alloc.free(b.body);
    try testz.expectEqual(session.visibleStackTop(), @as(glyphwire.ContextHandle, 1));
}

pub fn attachContextRetargetsWithoutOwningTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var root = try glyphwire.Context.init(alloc, 40, 10, 0);
    defer root.deinit();
    var session = try glyphwire.Session.init(alloc, &root);
    defer session.deinit();

    var creator = dispatch.Dispatcher.initForConnection(&session, 7);
    const created = try creator.handle(alloc,
        \\{"jsonrpc":"2.0","id":1,"method":"create_context","params":{"scrollback_rows":0}}
    );
    if (created.response) |r| alloc.free(r);
    if (created.broadcast) |b| alloc.free(b.body);

    // A second connection (a paired listener) attaches -- retargeted, but
    // not an owner, so it can't destroy it.
    var listener = dispatch.Dispatcher.initForConnection(&session, 8);
    _ = try listener.handle(alloc,
        \\{"jsonrpc":"2.0","method":"attach_context","params":{"context":1}}
    );
    try testz.expectEqual(listener.active_ctx, @as(glyphwire.ContextHandle, 1));
    try testz.expectTrue(!session.contextHasOwner(1, 8));

    try testz.expectError(listener.handle(alloc,
        \\{"jsonrpc":"2.0","method":"destroy_context","params":{"context":1}}
    ), dispatch.DispatchError.ContextPermissionDenied);

    try testz.expectError(listener.handle(alloc,
        \\{"jsonrpc":"2.0","method":"attach_context","params":{"context":999}}
    ), dispatch.DispatchError.UnknownContext);
}

pub fn adoptContextLetsASecondConnectionDestroyItTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var root = try glyphwire.Context.init(alloc, 40, 10, 0);
    defer root.deinit();
    var session = try glyphwire.Session.init(alloc, &root);
    defer session.deinit();

    var creator = dispatch.Dispatcher.initForConnection(&session, 7);
    const created = try creator.handle(alloc,
        \\{"jsonrpc":"2.0","id":1,"method":"create_context","params":{"scrollback_rows":0}}
    );
    if (created.response) |r| alloc.free(r);
    if (created.broadcast) |b| alloc.free(b.body);

    var adopter = dispatch.Dispatcher.initForConnection(&session, 8);
    _ = try adopter.handle(alloc,
        \\{"jsonrpc":"2.0","method":"adopt_context","params":{"context":1}}
    );
    try testz.expectTrue(session.contextHasOwner(1, 7));
    try testz.expectTrue(session.contextHasOwner(1, 8));

    const gone = try adopter.handle(alloc,
        \\{"jsonrpc":"2.0","method":"destroy_context","params":{"context":1}}
    );
    if (gone.broadcast) |b| alloc.free(b.body);
    try testz.expectTrue(session.contextPtr(1) == null);
}

pub fn contextMessagesOnASessionlessDispatcherReportNoContextSessionTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 40, 10, 0);
    defer ctx.deinit();
    var d = dispatch.Dispatcher.init(&ctx);

    try testz.expectError(d.handle(alloc,
        \\{"jsonrpc":"2.0","id":1,"method":"create_context","params":{"scrollback_rows":0}}
    ), dispatch.DispatchError.NoContextSession);
    try testz.expectError(d.handle(alloc,
        \\{"jsonrpc":"2.0","method":"activate_context","params":{"context":1}}
    ), dispatch.DispatchError.NoContextSession);
    try testz.expectError(d.handle(alloc,
        \\{"jsonrpc":"2.0","method":"attach_context","params":{"context":1}}
    ), dispatch.DispatchError.NoContextSession);
}
