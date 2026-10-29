// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: GPL-3.0-or-later

const std = @import("std");
const testz = @import("testz");
const glyphwire = @import("glyphwire");
const helpers = @import("session_helpers.zig");
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

/// Whether a broadcast's MessagePack body, in the JSON form a JSON
/// subscriber is sent, contains `needle`.
fn expectPushHas(alloc: std.mem.Allocator, body: []const u8, needle: []const u8) !void {
    const json = try glyphwire.codec.msgpackToJson(alloc, body);
    defer alloc.free(json);
    try testz.expectTrue(std.mem.indexOf(u8, json, needle) != null);
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

pub fn moveContentNotificationShiftsGridTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 8, 4, 0);
    defer ctx.deinit();
    var d = dispatch.Dispatcher.init(&ctx);

    const seed = try roundTripThroughWire(alloc,
        \\{"method":"write_text","params":{"text":"r0\nr1\nr2\nr3"}}
    );
    defer alloc.free(seed);
    try testz.expectTrue((try d.handle(alloc, seed)).response == null);

    const up = try roundTripThroughWire(alloc,
        \\{"method":"move_content","params":{"count":1,"direction":"up"}}
    );
    defer alloc.free(up);
    try testz.expectTrue((try d.handle(alloc, up)).response == null);
    try testz.expectEqualStr("r", ctx.root.cell(0, 0).grapheme());
    try testz.expectEqualStr("1", ctx.root.cell(0, 1).grapheme());
    try testz.expectEqual(ctx.root.cell(3, 0).grapheme().len, 0);

    // A bad direction is a dispatch error, not a silent no-op.
    const bad = try roundTripThroughWire(alloc,
        \\{"method":"move_content","params":{"count":1,"direction":"sideways"}}
    );
    defer alloc.free(bad);
    try testz.expectError(d.handle(alloc, bad), dispatch.DispatchError.InvalidMoveDirection);
}

pub fn contentExtentAndVirtualOffsetRoundTripOverWireTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 80, 24, 0);
    defer ctx.deinit();
    var d = dispatch.Dispatcher.init(&ctx);

    // A created (non-root) layer, viewport-sized, that scrolls itself.
    const mk = try roundTripThroughWire(alloc,
        \\{"method":"create_layer","id":1,"params":{"width":40,"height":10}}
    );
    defer alloc.free(mk);
    const mk_body = (try d.handle(alloc, mk)).response.?;
    defer alloc.free(mk_body);

    // Refused until the layer is explicitly client-scrolled.
    const set_extent = try roundTripThroughWire(alloc,
        \\{"method":"set_property","params":{"layer":1,"property":"content_extent","cols":40,"rows":500}}
    );
    defer alloc.free(set_extent);
    try testz.expectError(d.handle(alloc, set_extent), dispatch.DispatchError.WrongScrollMode);

    const set_mode = try roundTripThroughWire(alloc,
        \\{"method":"set_property","params":{"layer":1,"property":"scroll_mode","mode":"client"}}
    );
    defer alloc.free(set_mode);
    try testz.expectTrue((try d.handle(alloc, set_mode)).response == null);
    try testz.expectTrue((try d.handle(alloc, set_extent)).response == null);

    const set_off = try roundTripThroughWire(alloc,
        \\{"method":"set_property","params":{"layer":1,"property":"scroll_offset","row":9999,"col":0}}
    );
    defer alloc.free(set_off);
    try testz.expectTrue((try d.handle(alloc, set_off)).response == null);

    const layer = ctx.layerPtr(1).?;
    try testz.expectEqual(layer.content_off.row, 490); // 500 - 10, clamped
    try testz.expectEqual(layer.scroll_off.row, 0); // real grid never moved

    const get = try roundTripThroughWire(alloc,
        \\{"method":"get_property","id":2,"params":{"layer":1,"property":"content_extent"}}
    );
    defer alloc.free(get);
    const get_body = (try d.handle(alloc, get)).response.?;
    defer alloc.free(get_body);
    try testz.expectTrue(std.mem.indexOf(u8, get_body, "\"rows\":500") != null);
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

/// `write_text`'s `masked: true` draws its ●s, but `get_cells` reports
/// those cells exactly as it reports a never-written one: no grapheme
/// and the default (transparent) background, even with a `bg` given.
/// Unmasked text either side is untouched.
pub fn getCellsBlanksMaskedCellsTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 10, 3, 0);
    defer ctx.deinit();
    var d = dispatch.Dispatcher.init(&ctx);

    try testz.expectTrue((try d.handle(alloc,
        \\{"jsonrpc":"2.0","method":"write_text","params":{"text":"pw:"}}
    )).response == null);
    try testz.expectTrue((try d.handle(alloc,
        \\{"jsonrpc":"2.0","method":"write_text","params":{"text":"\u25cf\u25cf\u25cf","bg":{"r":40,"g":40,"b":90},"masked":true}}
    )).response == null);
    try testz.expectTrue((try d.handle(alloc,
        \\{"jsonrpc":"2.0","method":"write_text","params":{"text":"!"}}
    )).response == null);

    const response_body = (try d.handle(alloc,
        \\{"jsonrpc":"2.0","id":1,"method":"get_cells","params":{}}
    )).response.?;
    defer alloc.free(response_body);

    const CellJson = struct { g: []const u8, bg: ?struct { r: u8, g: u8, b: u8, a: u8 } };
    const Response = struct {
        result: struct { cells: []CellJson },
    };
    const parsed = try std.json.parseFromSlice(Response, alloc, response_body, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    const cells = parsed.value.result.cells;
    const untouched = cells[9];
    try testz.expectEqualStr(":", cells[2].g);
    for (cells[3..6]) |c| {
        try testz.expectEqualStr("", c.g);
        try testz.expectEqual(c.bg.?.r, untouched.bg.?.r);
        try testz.expectEqual(c.bg.?.a, untouched.bg.?.a);
    }
    try testz.expectEqualStr("!", cells[6].g);
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
    var session = try glyphwire.Session.init(alloc, &ctx);
    defer session.deinit();
    var d = try helpers.managerConnection(&session, 7);

    const press_msg =
        \\{"jsonrpc":"2.0","method":"report_key","params":{"key":"a","pressed":true}}
    ;
    const press_result = try d.handle(alloc, press_msg);
    try testz.expectTrue(press_result.response == null);
    try testz.expectTrue(session.input.isKeyDown("a"));

    const broadcast = press_result.broadcast.?;
    defer alloc.free(broadcast.body);
    try testz.expectEqual(broadcast.event, .key);
    try expectPushHas(alloc, broadcast.body, "key_down");

    // A redundant press-while-down report changes nothing, so it queues
    // no broadcast -- avoids spamming subscribers with no-op events.
    const redundant_result = try d.handle(alloc, press_msg);
    try testz.expectTrue(redundant_result.broadcast == null);

    const release_msg =
        \\{"jsonrpc":"2.0","method":"report_key","params":{"key":"a","pressed":false}}
    ;
    const release_result = try d.handle(alloc, release_msg);
    try testz.expectTrue(!session.input.isKeyDown("a"));
    const release_broadcast = release_result.broadcast.?;
    defer alloc.free(release_broadcast.body);
    try expectPushHas(alloc, release_broadcast.body, "key_up");
}

pub fn reportKeyStampsModifiersHeldAtRoutingTimeTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 80, 24, 0);
    defer ctx.deinit();
    var session = try glyphwire.Session.init(alloc, &ctx);
    defer session.deinit();
    var d = try helpers.managerConnection(&session, 7);

    const ctrl_down = try d.handle(alloc,
        \\{"jsonrpc":"2.0","method":"report_key","params":{"key":"left_control","pressed":true}}
    );
    defer alloc.free(ctrl_down.broadcast.?.body);
    // A modifier's own press already counts itself.
    try expectPushHas(alloc, ctrl_down.broadcast.?.body, "\"ctrl\":true");

    const w_down = try d.handle(alloc,
        \\{"jsonrpc":"2.0","method":"report_key","params":{"key":"w","pressed":true}}
    );
    defer alloc.free(w_down.broadcast.?.body);
    try expectPushHas(alloc, w_down.broadcast.?.body, "\"key\":\"w\",\"mods\":{\"ctrl\":true,\"alt\":false,\"shift\":false,\"super\":false}");

    const ctrl_up = try d.handle(alloc,
        \\{"jsonrpc":"2.0","method":"report_key","params":{"key":"left_control","pressed":false}}
    );
    defer alloc.free(ctrl_up.broadcast.?.body);
    try expectPushHas(alloc, ctrl_up.broadcast.?.body, "\"ctrl\":false");
}

pub fn writeTextRowColPlacesTheRunInOneMessageTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 40, 10, 0);
    defer ctx.deinit();
    var d = dispatch.Dispatcher.init(&ctx);

    _ = try d.handle(alloc,
        \\{"jsonrpc":"2.0","method":"write_text","params":{"row":3,"col":5,"text":"hi"}}
    );
    try testz.expectEqualStr("h", ctx.root.cell(3, 5).grapheme());
    try testz.expectEqualStr("i", ctx.root.cell(3, 6).grapheme());

    // Only `row` given: the column comes from the cursor, like draw_icon.
    _ = try d.handle(alloc,
        \\{"jsonrpc":"2.0","method":"write_text","params":{"row":6,"text":"x","max_cols":4,"pad":true,"bg":{"r":9,"g":9,"b":9}}}
    );
    try testz.expectEqualStr("x", ctx.root.cell(6, 7).grapheme());
    try testz.expectEqual(ctx.root.cell(6, 10).style.bg.color.r, 9);
    try testz.expectEqual(ctx.root.cell(6, 11).style.bg.color.a, 0);
}

/// `selectable: false` marks every cell the write touches, its padding
/// included, and the next plain write is selectable again.
pub fn writeTextSelectableFalseMarksChromeTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 40, 10, 0);
    defer ctx.deinit();
    var d = dispatch.Dispatcher.init(&ctx);

    _ = try d.handle(alloc,
        \\{"jsonrpc":"2.0","method":"write_text","params":{"row":0,"col":0,"text":"|","max_cols":2,"pad":true,"selectable":false}}
    );
    _ = try d.handle(alloc,
        \\{"jsonrpc":"2.0","method":"write_text","params":{"text":"ab"}}
    );
    try testz.expectFalse(ctx.root.cell(0, 0).selectable);
    try testz.expectFalse(ctx.root.cell(0, 1).selectable);
    try testz.expectTrue(ctx.root.cell(0, 2).selectable);
    try testz.expectTrue(ctx.root.cell(0, 3).selectable);
}

pub fn writeTextSpansInheritTheMessageDefaultsTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 40, 10, 0);
    defer ctx.deinit();
    var d = dispatch.Dispatcher.init(&ctx);

    _ = try d.handle(alloc,
        \\{"jsonrpc":"2.0","method":"write_text","params":{"row":1,"col":0,"fg":{"r":10,"g":10,"b":10},"bg":{"r":5,"g":5,"b":5},"max_cols":8,"pad":true,"spans":[{"text":"ab"},{"text":"cd","fg":{"r":250,"g":0,"b":0}},{"text":"e","transparent_bg":true}]}}
    );
    try testz.expectEqualStr("a", ctx.root.cell(1, 0).grapheme());
    try testz.expectEqual(ctx.root.cell(1, 0).style.fg.r, 10);
    try testz.expectEqual(ctx.root.cell(1, 2).style.fg.r, 250);
    try testz.expectEqual(ctx.root.cell(1, 2).style.bg.color.r, 5);
    // `transparent_bg` on a span leaves the cell's own (default) background.
    try testz.expectEqual(ctx.root.cell(1, 4).style.bg.color.a, 0);
    // The pad uses the message's own bg, across the whole write.
    try testz.expectEqual(ctx.root.cell(1, 7).style.bg.color.r, 5);
    try testz.expectEqual(ctx.root.cell(1, 8).style.bg.color.a, 0);

    try testz.expectError(d.handle(alloc,
        \\{"jsonrpc":"2.0","method":"write_text","params":{"text":"x","spans":[{"text":"y"}]}}
    ), dispatch.DispatchError.InvalidSpans);
    try testz.expectError(d.handle(alloc,
        \\{"jsonrpc":"2.0","method":"write_text","params":{"row":0}}
    ), dispatch.DispatchError.InvalidSpans);
    try testz.expectError(d.handle(alloc,
        \\{"jsonrpc":"2.0","method":"write_text","params":{"spans":[{"text":"y","scale":"x9"}]}}
    ), dispatch.DispatchError.InvalidTextScale);
}

/// `set_bg` takes `clear`'s region and repaints only the background, so
/// a client moving a highlight never resends the row's text.
pub fn setBgOverWireKeepsTextTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 40, 10, 0);
    defer ctx.deinit();
    var d = dispatch.Dispatcher.init(&ctx);

    _ = try d.handle(alloc,
        \\{"jsonrpc":"2.0","method":"write_text","params":{"row":2,"col":0,"text":"row two","fg":{"r":9,"g":9,"b":9}}}
    );
    _ = try d.handle(alloc,
        \\{"jsonrpc":"2.0","method":"set_bg","params":{"row":2,"rows":1,"cols":8,"bg":{"r":1,"g":2,"b":3}}}
    );
    try testz.expectEqualStr("r", ctx.root.cell(2, 0).grapheme());
    try testz.expectEqual(ctx.root.cell(2, 0).style.fg.r, 9);
    try testz.expectEqual(ctx.root.cell(2, 0).style.bg.color.b, 3);
    try testz.expectEqual(ctx.root.cell(2, 7).style.bg.color.b, 3);
    // `cols` stopped it: column 8 and the next row are untouched.
    try testz.expectEqual(ctx.root.cell(2, 8).style.bg.color.a, 0);
    try testz.expectEqual(ctx.root.cell(3, 0).style.bg.color.a, 0);

    // `rows`/`cols` default to the rest of the layer, as `clear`'s do.
    _ = try d.handle(alloc,
        \\{"jsonrpc":"2.0","method":"set_bg","params":{"bg":{"r":4,"g":5,"b":6}}}
    );
    try testz.expectEqual(ctx.root.cell(9, 39).style.bg.color.g, 5);
    try testz.expectEqualStr("w", ctx.root.cell(2, 2).grapheme());

    // `bg` is required -- the call means "paint this background".
    try testz.expectError(d.handle(alloc,
        \\{"jsonrpc":"2.0","method":"set_bg","params":{"row":1}}
    ), error.MissingField);
}

/// `set_fg` is `set_bg` for the text colour: the region's foreground
/// changes and nothing else does.
pub fn setFgOverWireKeepsTextAndBackgroundTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 40, 10, 0);
    defer ctx.deinit();
    var d = dispatch.Dispatcher.init(&ctx);

    _ = try d.handle(alloc,
        \\{"jsonrpc":"2.0","method":"write_text","params":{"row":2,"col":0,"text":"row two","fg":{"r":9,"g":9,"b":9},"bg":{"r":1,"g":2,"b":3}}}
    );
    _ = try d.handle(alloc,
        \\{"jsonrpc":"2.0","method":"set_fg","params":{"row":2,"col":4,"rows":1,"cols":3,"fg":{"role":"list_cursor_fg"}}}
    );
    try testz.expectEqualStr("t", ctx.root.cell(2, 4).grapheme());
    try testz.expectTrue(ctx.root.cell(2, 4).style.fg.eql(glyphwire.Color.role(.list_cursor_fg)));
    try testz.expectTrue(ctx.root.cell(2, 6).style.fg.eql(glyphwire.Color.role(.list_cursor_fg)));
    try testz.expectEqual(ctx.root.cell(2, 4).style.bg.color.b, 3);
    // Outside the region: the old colour, and a blank cell stays blank.
    try testz.expectEqual(ctx.root.cell(2, 3).style.fg.r, 9);
    try testz.expectTrue(ctx.root.cell(2, 7).style.fg.eql(ctx.root.cell(9, 0).style.fg));

    // `fg` is required, as `set_bg`'s `bg` is.
    try testz.expectError(d.handle(alloc,
        \\{"jsonrpc":"2.0","method":"set_fg","params":{"row":1}}
    ), error.MissingField);
}

pub fn clearBgAndLayerBackgroundOverWireTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 40, 10, 0);
    defer ctx.deinit();
    var d = dispatch.Dispatcher.init(&ctx);

    _ = try d.handle(alloc,
        \\{"jsonrpc":"2.0","method":"clear","params":{"row":2,"rows":1,"bg":{"r":1,"g":2,"b":3}}}
    );
    try testz.expectEqual(ctx.root.cell(2, 39).style.bg.color.b, 3);
    try testz.expectEqual(ctx.root.cell(3, 0).style.bg.color.a, 0);

    const mk = try d.handle(alloc,
        \\{"jsonrpc":"2.0","id":1,"method":"create_layer","params":{"width":10,"height":4}}
    );
    alloc.free(mk.response.?);
    _ = try d.handle(alloc,
        \\{"jsonrpc":"2.0","method":"set_property","params":{"layer":1,"property":"background","color":{"r":20,"g":30,"b":40}}}
    );
    try testz.expectEqual(ctx.layerPtr(1).?.background.?.g, 30);

    const get = try d.handle(alloc,
        \\{"jsonrpc":"2.0","id":2,"method":"get_property","params":{"layer":1,"property":"background"}}
    );
    defer alloc.free(get.response.?);
    try testz.expectTrue(std.mem.indexOf(u8, get.response.?, "\"b\":40") != null);

    // No `color` clears it back to see-through.
    _ = try d.handle(alloc,
        \\{"jsonrpc":"2.0","method":"set_property","params":{"layer":1,"property":"background"}}
    );
    try testz.expectTrue(ctx.layerPtr(1).?.background == null);
}

/// `shadow` round-trips through `set_property` / `get_property`, fills
/// omitted fields with the core defaults, clamps an oversized blur, and
/// clears with no `shadow` object.
pub fn shadowPropertyRoundTripsTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 40, 10, 0);
    defer ctx.deinit();
    var d = dispatch.Dispatcher.init(&ctx);

    const mk = try d.handle(alloc,
        \\{"jsonrpc":"2.0","id":1,"method":"create_layer","params":{"width":10,"height":4}}
    );
    alloc.free(mk.response.?);
    _ = try d.handle(alloc,
        \\{"jsonrpc":"2.0","method":"set_property","params":{"layer":1,"property":"shadow","shadow":{"y":6,"blur":500,"radius":6}}}
    );
    const sh = ctx.layerPtr(1).?.shadow.?;
    try testz.expectEqual(sh.x, 0);
    try testz.expectEqual(sh.y, 6);
    try testz.expectEqual(sh.blur, glyphwire.Shadow.max_blur);
    try testz.expectEqual(sh.radius, 6);
    try testz.expectEqual(sh.color.a, 128);

    const get = try d.handle(alloc,
        \\{"jsonrpc":"2.0","id":2,"method":"get_property","params":{"layer":1,"property":"shadow"}}
    );
    defer alloc.free(get.response.?);
    try testz.expectTrue(std.mem.indexOf(u8, get.response.?, "\"radius\":6") != null);

    _ = try d.handle(alloc,
        \\{"jsonrpc":"2.0","method":"set_property","params":{"layer":1,"property":"shadow"}}
    );
    try testz.expectTrue(ctx.layerPtr(1).?.shadow == null);
}

pub fn scrollModeRejectsAnUnknownModeTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 40, 10, 0);
    defer ctx.deinit();
    var d = dispatch.Dispatcher.init(&ctx);
    try testz.expectError(d.handle(alloc,
        \\{"jsonrpc":"2.0","method":"set_property","params":{"property":"scroll_mode","mode":"sideways"}}
    ), dispatch.DispatchError.InvalidScrollMode);
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
    try testz.expectEqual(ctx.pointer.cursor_cell.row, @as(usize, 2));
    const b = first.broadcast.?;
    defer alloc.free(b.body);
    try testz.expectEqual(b.event, .mouse_move);
    try expectPushHas(alloc, b.body, "\"method\":\"mouse_move\"");

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
    try testz.expectEqual(b.event, .terminal_reply);
    try expectPushHas(alloc, b.body, "\"method\":\"terminal_reply\"");
    // Cursor was at 1;1 -> reply "\x1b[1;1R", JSON-escaped in the body.
    try expectPushHas(alloc, b.body, "1;1R");

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
    try testz.expectTrue(d.subscriptions.hasStream(.terminal));
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
    try testz.expectTrue(d.subscriptions.hasStream(.mouse_move));
    try testz.expectFalse(d.subscriptions.hasStream(.mouse_button));
}

/// `focus` is its own stream: a client that paints its own cursor asks
/// for it by name, and asking for it brings nothing else along.
pub fn subscribeFocusEventTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 80, 24, 0);
    defer ctx.deinit();
    var d = dispatch.Dispatcher.init(&ctx);

    const sub =
        \\{"jsonrpc":"2.0","id":1,"method":"subscribe","params":{"events":["focus"]}}
    ;
    const result = try d.handle(alloc, sub);
    if (result.response) |r| alloc.free(r);
    try testz.expectTrue(d.subscriptions.hasStream(.focus));
    try testz.expectTrue(d.subscriptions.has(.focus));
    try testz.expectFalse(d.subscriptions.hasStream(.shutdown));
}

/// Event names subscribe to their stream too. These three were once
/// routed by name but missing from what `subscribe` accepted, so asking for
/// them by name silently subscribed to nothing.
pub fn subscribeByEventNameTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 80, 24, 0);
    defer ctx.deinit();
    var d = dispatch.Dispatcher.init(&ctx);

    const sub =
        \\{"jsonrpc":"2.0","id":1,"method":"subscribe","params":{"events":["terminal_reply","window_key_down"]}}
    ;
    const result = try d.handle(alloc, sub);
    if (result.response) |r| alloc.free(r);
    try testz.expectTrue(d.subscriptions.hasStream(.terminal));
    try testz.expectTrue(d.subscriptions.has(.terminal_reply));
    try testz.expectTrue(d.subscriptions.hasStream(.window_keys));
    try testz.expectTrue(d.subscriptions.has(.window_key_up));
    try testz.expectTrue(d.subscriptions.has(.window_text));
    try testz.expectFalse(d.subscriptions.hasStream(.key));
}

/// Every pushed event's own name subscribes to the stream it is routed
/// on, so no event can be routed by a name `subscribe` doesn't accept.
pub fn everyPushEventNameSubscribesItsStreamTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    _ = alloc;
    for (std.enums.values(dispatch.PushEvent)) |event| {
        const stream = dispatch.Stream.fromName(@tagName(event)) orelse return error.TestUnexpectedResult;
        try testz.expectEqual(stream, event.route().stream);
    }
}

/// An unknown name is skipped, not an error: the known names alongside it
/// still subscribe, so a client written for a newer host keeps working.
/// `window_key`, the name both window-key events once went by, still works.
pub fn subscribeSkipsUnknownNamesTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 80, 24, 0);
    defer ctx.deinit();
    var d = dispatch.Dispatcher.init(&ctx);

    const sub =
        \\{"jsonrpc":"2.0","id":1,"method":"subscribe","params":{"events":["no_such_stream","key","window_key"]}}
    ;
    const result = try d.handle(alloc, sub);
    const r = result.response orelse return error.TestUnexpectedResult;
    defer alloc.free(r);
    try testz.expectTrue(std.mem.indexOf(u8, r, "\"error\"") == null);
    try testz.expectTrue(d.subscriptions.hasStream(.key));
    try testz.expectTrue(d.subscriptions.hasStream(.window_keys));
    try testz.expectEqual(d.subscriptions.streams.count(), 2);
}

pub fn reportTextQueuesTextBroadcastTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 80, 24, 0);
    defer ctx.deinit();
    var session = try glyphwire.Session.init(alloc, &ctx);
    defer session.deinit();
    var d = try helpers.managerConnection(&session, 7);

    // A multi-byte codepoint (an AZERTY 'é') round-trips through JSON into
    // the broadcast body verbatim.
    const msg =
        \\{"jsonrpc":"2.0","method":"report_text","params":{"text":"e\u00e9"}}
    ;
    const result = try d.handle(alloc, msg);
    try testz.expectTrue(result.response == null);
    const broadcast = result.broadcast.?;
    defer alloc.free(broadcast.body);
    try testz.expectEqual(broadcast.event, .text);
    try expectPushHas(alloc, broadcast.body, "\"method\":\"text\"");
    try expectPushHas(alloc, broadcast.body, "e\u{00e9}");

    // report_text touches no input down-set -- text is transient.
    try testz.expectEqual(session.input.keys_down.count(), 0);

    // An empty string queues nothing.
    const empty_result = try d.handle(alloc,
        \\{"jsonrpc":"2.0","method":"report_text","params":{"text":""}}
    );
    try testz.expectTrue(empty_result.broadcast == null);
}

pub fn reportMouseButtonCarriesClicksTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 80, 24, 0);
    defer ctx.deinit();
    var session = try glyphwire.Session.init(alloc, &ctx);
    defer session.deinit();
    var d = try helpers.managerConnection(&session, 7);

    const Notif = struct { params: struct { clicks: u8 } };

    // Passed through from the reporter...
    const dbl = try d.handle(alloc,
        \\{"jsonrpc":"2.0","method":"report_mouse_button","params":{"button":"left","pressed":true,"px":{"x":1,"y":1},"cell":{"row":0,"col":0},"clicks":2}}
    );
    defer alloc.free(dbl.broadcast.?.body);
    const a = try glyphwire.msgpack.decode(Notif, alloc, dbl.broadcast.?.body, .{});
    defer a.deinit();
    try testz.expectEqual(a.value.params.clicks, 2);

    // ...and 1 from one that doesn't count.
    const plain = try d.handle(alloc,
        \\{"jsonrpc":"2.0","method":"report_mouse_button","params":{"button":"left","pressed":false,"px":{"x":1,"y":1},"cell":{"row":0,"col":0}}}
    );
    defer alloc.free(plain.broadcast.?.body);
    const b = try glyphwire.msgpack.decode(Notif, alloc, plain.broadcast.?.body, .{});
    defer b.deinit();
    try testz.expectEqual(b.value.params.clicks, 1);
}

pub fn subscribeThenGetInputStateReflectsReportedInputTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 80, 24, 0);
    defer ctx.deinit();
    var session = try glyphwire.Session.init(alloc, &ctx);
    defer session.deinit();
    var d = try helpers.managerConnection(&session, 7);

    const sub_msg =
        \\{"jsonrpc":"2.0","id":1,"method":"subscribe","params":{"events":["key","mouse_button"]}}
    ;
    const sub_result = try d.handle(alloc, sub_msg);
    defer alloc.free(sub_result.response.?);
    try testz.expectTrue(d.subscriptions.hasStream(.key));
    try testz.expectTrue(d.subscriptions.hasStream(.mouse_button));

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
    const hdr = (try dispatch.peekImagePayload(alloc, message)).?;
    try testz.expectEqual(hdr.bytes, 24);
    try testz.expectEqual(hdr.id.integer, 7);
    try testz.expectEqual(hdr.format, .png);
}

pub fn peekLoadImageRejectsUnknownFormatTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    const message =
        \\{"jsonrpc":"2.0","id":7,"method":"load_image","params":{"format":"webp","bytes":24}}
    ;
    try testz.expectError(dispatch.peekImagePayload(alloc, message), dispatch.DispatchError.UnsupportedImageFormat);
}

pub fn peekLoadImageReturnsNullForOtherMethodsTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    const message =
        \\{"jsonrpc":"2.0","method":"write_text","params":{"text":"hi"}}
    ;
    try testz.expectTrue(try dispatch.peekImagePayload(alloc, message) == null);
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

/// `draw_image`'s optional source rect (sprite-sheet support): sampling
/// starts at `(src_x, src_y)` instead of the image's own origin, and
/// clips at the sprite's own edge (`src_x + src_w`), not the sheet's.
pub fn drawImageSourceRectSamplesSubRegionOfSheetTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 10, 10, 0);
    defer ctx.deinit();
    var d = dispatch.Dispatcher.init(&ctx);

    // A 48x24px sheet: two 24x24px sprites side by side. Ask for the
    // second one only.
    const png = fakePngBytes(48, 24);
    const load_resp = try d.handleLoadImage(alloc, .{ .id = .{ .integer = 1 }, .format = .png, .bytes = png.len }, &png);
    alloc.free(load_resp);

    const draw_message =
        \\{"jsonrpc":"2.0","method":"draw_image","params":{"handle":1,"row":0,"col":0,"row_span":2,"col_span":2,"src_x":24,"src_y":0,"src_w":24,"src_h":24}}
    ;
    try testz.expectTrue((try d.handle(alloc, draw_message)).response == null);

    try testz.expectEqual(ctx.root.cell(0, 0).style.bg.image.offset_x, 24);
    try testz.expectEqual(ctx.root.cell(0, 1).style.bg.image.offset_x, 36);
    try testz.expectEqual(ctx.root.cell(0, 0).style.bg.image.src_right, 48);
}

/// `create_rect` allocates a fresh handle and stores every field exactly
/// as given -- see rect.zig's header.
pub fn createRectReturnsHandleAndStoresItTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 20, 10, 0);
    defer ctx.deinit();
    var d = dispatch.Dispatcher.init(&ctx);

    const message =
        \\{"jsonrpc":"2.0","id":1,"method":"create_rect","params":{"x":10,"y":20,"w":30,"h":15,"color":{"r":200,"g":50,"b":50,"a":255},"line_width":2,"filled":true}}
    ;
    const result = try d.handle(alloc, message);
    defer if (result.response) |r| alloc.free(r);
    try testz.expectTrue(result.response != null);
    try testz.expectTrue(std.mem.indexOf(u8, result.response.?, "\"handle\":1") != null);

    const r = ctx.root.rects.get(1) orelse return error.TestUnexpectedResult;
    try testz.expectEqual(r.x, 10);
    try testz.expectEqual(r.y, 20);
    try testz.expectEqual(r.w, 30);
    try testz.expectEqual(r.h, 15);
    try testz.expectEqual(r.color.r, 200);
    try testz.expectEqual(r.line_width, 2);
    try testz.expectTrue(r.filled);
}

/// `update_rect` merges only the fields the caller actually sent -- see
/// `core.RectUpdate`'s doc comment for why this is a merge and not a
/// replace.
pub fn updateRectMergesOnlyProvidedFieldsTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 20, 10, 0);
    defer ctx.deinit();
    var d = dispatch.Dispatcher.init(&ctx);

    const create_message =
        \\{"jsonrpc":"2.0","id":1,"method":"create_rect","params":{"x":0,"y":0,"w":10,"h":10,"color":{"r":1,"g":2,"b":3,"a":255},"filled":false}}
    ;
    const create_result = try d.handle(alloc, create_message);
    if (create_result.response) |r| alloc.free(r);

    // Move it (x/y only) -- everything else must survive untouched.
    const update_message =
        \\{"jsonrpc":"2.0","method":"update_rect","params":{"rect":1,"x":40,"y":50}}
    ;
    try testz.expectTrue((try d.handle(alloc, update_message)).response == null);

    const r = ctx.root.rects.get(1) orelse return error.TestUnexpectedResult;
    try testz.expectEqual(r.x, 40);
    try testz.expectEqual(r.y, 50);
    try testz.expectEqual(r.w, 10);
    try testz.expectEqual(r.color.r, 1);
    try testz.expectTrue(!r.filled);
}

/// `destroy_rect` removes the rect immediately, and a second destroy (or
/// any `update_rect`) against the now-unknown handle errors rather than
/// silently no-op-ing.
pub fn destroyRectRemovesItAndDoubleDestroyErrorsTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 20, 10, 0);
    defer ctx.deinit();
    var d = dispatch.Dispatcher.init(&ctx);

    const create_message =
        \\{"jsonrpc":"2.0","id":1,"method":"create_rect","params":{"x":0,"y":0,"w":5,"h":5,"color":{"r":1,"g":1,"b":1,"a":255}}}
    ;
    const create_result = try d.handle(alloc, create_message);
    if (create_result.response) |r| alloc.free(r);

    const destroy_message =
        \\{"jsonrpc":"2.0","method":"destroy_rect","params":{"rect":1}}
    ;
    try testz.expectTrue((try d.handle(alloc, destroy_message)).response == null);
    try testz.expectTrue(ctx.root.rects.get(1) == null);

    try testz.expectError(d.handle(alloc, destroy_message), dispatch.DispatchError.UnknownRect);
}

pub fn updateRectUnknownHandleErrorsTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 20, 10, 0);
    defer ctx.deinit();
    var d = dispatch.Dispatcher.init(&ctx);

    const message =
        \\{"jsonrpc":"2.0","method":"update_rect","params":{"rect":99,"x":1}}
    ;
    try testz.expectError(d.handle(alloc, message), dispatch.DispatchError.UnknownRect);
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

/// `write_text`'s `scale` field ("x1"/"x1_5"/"x2") is threaded through to
/// `Cell.text_scale` -- see `core.TextScale`.
pub fn writeTextScaleSetsCellTextScaleTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 80, 24, 0);
    defer ctx.deinit();
    var d = dispatch.Dispatcher.init(&ctx);

    const write_message =
        \\{"jsonrpc":"2.0","method":"write_text","params":{"text":"a","scale":"x1_5"}}
    ;
    try testz.expectTrue((try d.handle(alloc, write_message)).response == null);
    try testz.expectEqual(ctx.root.cell(0, 0).text_scale, glyphwire.TextScale.x1_5);
}

/// `"x3"` parses like the other scales and lands on the cell.
pub fn writeTextScaleX3SetsCellTextScaleTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 80, 24, 0);
    defer ctx.deinit();
    var d = dispatch.Dispatcher.init(&ctx);

    const write_message =
        \\{"jsonrpc":"2.0","method":"write_text","params":{"text":"a","scale":"x3"}}
    ;
    try testz.expectTrue((try d.handle(alloc, write_message)).response == null);
    try testz.expectEqual(ctx.root.cell(0, 0).text_scale, glyphwire.TextScale.x3);
}

/// An unrecognized `scale` value is rejected rather than silently falling
/// back to `.x1` -- same convention `draw_icon`'s `scale` already follows.
pub fn writeTextBadScaleIsRejectedTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 80, 24, 0);
    defer ctx.deinit();
    var d = dispatch.Dispatcher.init(&ctx);

    const write_message =
        \\{"jsonrpc":"2.0","method":"write_text","params":{"text":"a","scale":"huge"}}
    ;
    try testz.expectError(d.handle(alloc, write_message), dispatch.DispatchError.InvalidTextScale);
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
    try testz.expectEqual(result.broadcast.?.event, .scroll);
    try expectPushHas(alloc, result.broadcast.?.body, "\"offset\":1");
}

/// `scroll_view` on a non-root layer carries that layer's handle in the
/// broadcast `scroll` notification -- root-only was the old shape (before
/// `gmux` panes could have their own scrollback ring), and a subscriber
/// needs to know which layer moved when it isn't the root.
pub fn scrollViewOnANonRootLayerCarriesItsHandleTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 80, 24, 0);
    defer ctx.deinit();
    var d = dispatch.Dispatcher.init(&ctx);
    const pane = try ctx.createLayer(4, 2, 5);
    try ctx.layerPtr(pane).?.writeText("aaaabbbbcccc", glyphwire.default_style.fg, glyphwire.default_style.bg);

    const message =
        \\{"jsonrpc":"2.0","id":7,"method":"scroll_view","params":{"layer":1,"delta":9}}
    ;
    const result = try d.handle(alloc, message);
    defer if (result.response) |r| alloc.free(r);
    defer if (result.broadcast) |b| alloc.free(b.body);

    try testz.expectTrue(result.broadcast != null);
    try testz.expectEqual(result.broadcast.?.event, .scroll);
    try expectPushHas(alloc, result.broadcast.?.body, "\"layer\":1");
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
/// already-drawn background (as a plain `draw_icon` would leave) alone, unlike a
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

/// Registers a `dialog` nine-patch style. The image handle is never
/// resolved by dispatch, so any number does.
fn registerTestNinePatch(ctx: *glyphwire.Context) !void {
    try ctx.registerNinePatchStyle("dialog", .{ .image = 42, .width = 10, .height = 8, .insets = .{ .left = 3, .top = 2, .right = 3, .bottom = 3 } });
}

/// `create_nine_patch` resolves `style` by name and stores the cell rect
/// on the layer, answering with a fresh handle.
pub fn createNinePatchReturnsHandleAndStoresItTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 20, 10, 0);
    defer ctx.deinit();
    var d = dispatch.Dispatcher.init(&ctx);
    try registerTestNinePatch(&ctx);

    const message =
        \\{"jsonrpc":"2.0","id":1,"method":"create_nine_patch","params":{"row":1,"col":2,"rows":4,"cols":6,"style":"dialog"}}
    ;
    const result = try d.handle(alloc, message);
    defer if (result.response) |r| alloc.free(r);
    try testz.expectTrue(std.mem.indexOf(u8, result.response.?, "\"handle\":1") != null);

    const np = ctx.root.nine_patches.get(1) orelse return error.TestUnexpectedResult;
    try testz.expectEqual(np.row, 1);
    try testz.expectEqual(np.col, 2);
    try testz.expectEqual(np.rows, 4);
    try testz.expectEqual(np.cols, 6);
    try testz.expectEqual(np.style.image, 42);
    // It's a layer object, not cells: nothing in the grid changed.
    switch (ctx.root.cell(1, 2).style.bg) {
        .color => {},
        .image, .icon => return error.TestUnexpectedResult,
    }
}

pub fn createNinePatchUnknownStyleErrorsTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 20, 10, 0);
    defer ctx.deinit();
    var d = dispatch.Dispatcher.init(&ctx);

    const message =
        \\{"jsonrpc":"2.0","id":1,"method":"create_nine_patch","params":{"row":0,"col":0,"rows":3,"cols":3,"style":"not-a-style"}}
    ;
    try testz.expectError(d.handle(alloc, message), dispatch.DispatchError.UnknownNinePatchStyle);
}

/// `update_nine_patch` merges only what was sent; `destroy_nine_patch`
/// removes it, and a second destroy is `UnknownNinePatch`.
pub fn updateAndDestroyNinePatchTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 20, 10, 0);
    defer ctx.deinit();
    var d = dispatch.Dispatcher.init(&ctx);
    try registerTestNinePatch(&ctx);

    const create =
        \\{"jsonrpc":"2.0","id":1,"method":"create_nine_patch","params":{"row":1,"col":2,"rows":4,"cols":6,"style":"dialog"}}
    ;
    const created = try d.handle(alloc, create);
    defer if (created.response) |r| alloc.free(r);

    const update =
        \\{"jsonrpc":"2.0","method":"update_nine_patch","params":{"nine_patch":1,"cols":9}}
    ;
    try testz.expectTrue((try d.handle(alloc, update)).response == null);
    const np = ctx.root.nine_patches.get(1).?;
    try testz.expectEqual(np.cols, 9);
    try testz.expectEqual(np.rows, 4);

    const bad_style =
        \\{"jsonrpc":"2.0","method":"update_nine_patch","params":{"nine_patch":1,"style":"nope"}}
    ;
    try testz.expectError(d.handle(alloc, bad_style), dispatch.DispatchError.UnknownNinePatchStyle);

    const destroy =
        \\{"jsonrpc":"2.0","method":"destroy_nine_patch","params":{"nine_patch":1}}
    ;
    try testz.expectTrue((try d.handle(alloc, destroy)).response == null);
    try testz.expectEqual(ctx.root.nine_patches.count(), 0);
    try testz.expectError(d.handle(alloc, destroy), dispatch.DispatchError.UnknownNinePatch);
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

/// `sync` changes nothing and answers `{}` -- standalone, and as the last
/// sub-request of a batch, where its response comes back after the
/// sub-messages before it have applied.
pub fn syncAnswersEmptyAloneAndInBatchTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 20, 5, 0);
    defer ctx.deinit();
    var d = dispatch.Dispatcher.init(&ctx);

    const alone = try roundTripThroughWire(alloc,
        \\{"jsonrpc":"2.0","id":4,"method":"sync","params":{}}
    );
    defer alloc.free(alone);
    const r1 = try d.handle(alloc, alone);
    const body1 = r1.response.?;
    defer alloc.free(body1);
    const p1 = try std.json.parseFromSlice(std.json.Value, alloc, body1, .{});
    defer p1.deinit();
    try testz.expectEqual(p1.value.object.get("id").?.integer, 4);
    try testz.expectEqual(p1.value.object.get("result").?.object.count(), 0);

    const batched = try roundTripThroughWire(alloc,
        \\{"jsonrpc":"2.0","id":9,"method":"batch","params":{"messages":[
        \\  {"method":"write_text","params":{"text":"ok"}},
        \\  {"method":"sync","params":{},"id":1}
        \\]}}
    );
    defer alloc.free(batched);
    const r2 = try d.handle(alloc, batched);
    const body2 = r2.response.?;
    defer alloc.free(body2);
    const p2 = try std.json.parseFromSlice(BatchResponseJson, alloc, body2, .{ .ignore_unknown_fields = true });
    defer p2.deinit();
    try testz.expectEqual(p2.value.result.responses.len, 1);
    try testz.expectEqual(p2.value.result.responses[0].id, 1);
    try testz.expectEqualStr("o", ctx.root.cell(0, 0).grapheme());
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
    try testz.expectEqual(broadcast.event, .selection);
    try expectPushHas(alloc, broadcast.body, "\"active\":true");

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
    try expectPushHas(alloc, broadcast.body, "\"active\":false");

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
    try testz.expectEqual(ctx.root.sel.highlighted_ids.items.len, 1);
    try testz.expectEqual(ctx.root.sel.highlighted_ids.items[0], 1);
    try testz.expectTrue(std.mem.indexOf(u8, on.response.?, "\"id\":1") != null);
    try testz.expectTrue(std.mem.indexOf(u8, on.response.?, "\\\"path\\\":\\\"/tmp/d\\\"") != null);

    // A cell with no tag: no change.
    const untagged = try d.handle(alloc,
        \\{"jsonrpc":"2.0","id":3,"method":"toggle_highlight","params":{"row":0,"col":5}}
    );
    defer if (untagged.response) |r| alloc.free(r);
    try testz.expectEqual(ctx.root.sel.highlighted_ids.items.len, 1);

    // Toggling the same tagged cell again removes the id.
    const off = try d.handle(alloc,
        \\{"jsonrpc":"2.0","id":4,"method":"toggle_highlight","params":{"row":0,"col":0}}
    );
    defer if (off.response) |r| alloc.free(r);
    try testz.expectEqual(ctx.root.sel.highlighted_ids.items.len, 0);
    try testz.expectTrue(std.mem.indexOf(u8, off.response.?, "\"entries\":[]") != null);
}

/// `find_metadata` walks from `(above, col)` to the first visible
/// character of the adjacent metadata-id span, skipping the current span
/// and any leading blank/icon cells of the next one; `found:false` when
/// there's nothing further that way, and a bad `direction` is rejected.
pub fn findMetadataWalksToNextSpanFirstCharacterTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 20, 3, 0);
    defer ctx.deinit();
    var d = dispatch.Dispatcher.init(&ctx);

    const m1 = try d.handle(alloc,
        \\{"jsonrpc":"2.0","id":1,"method":"create_metadata","params":{"json":"{\"n\":1}"}}
    );
    defer if (m1.response) |r| alloc.free(r);
    const m2 = try d.handle(alloc,
        \\{"jsonrpc":"2.0","id":2,"method":"create_metadata","params":{"json":"{\"n\":2}"}}
    );
    defer if (m2.response) |r| alloc.free(r);

    // Row 0: cols 0-2 = "aa " tagged 1; cols 3-6 = "  bb" tagged 2 (two
    // leading blank cells before the first real character at col 5).
    try testz.expectTrue((try d.handle(alloc,
        \\{"jsonrpc":"2.0","method":"write_text","params":{"text":"aa ","metadata_id":1}}
    )).response == null);
    try testz.expectTrue((try d.handle(alloc,
        \\{"jsonrpc":"2.0","method":"write_text","params":{"text":"  bb","metadata_id":2}}
    )).response == null);

    const Response = struct {
        result: struct { found: bool, above: i64 = 0, col: usize = 0, id: ?u32 = null },
    };

    const fwd = (try d.handle(alloc,
        \\{"jsonrpc":"2.0","id":3,"method":"find_metadata","params":{"above":0,"col":0,"direction":"next"}}
    )).response.?;
    defer alloc.free(fwd);
    const fwd_p = try std.json.parseFromSlice(Response, alloc, fwd, .{ .ignore_unknown_fields = true });
    defer fwd_p.deinit();
    try testz.expectTrue(fwd_p.value.result.found);
    try testz.expectEqual(fwd_p.value.result.above, @as(i64, 0));
    try testz.expectEqual(fwd_p.value.result.col, @as(usize, 5));
    try testz.expectEqual(fwd_p.value.result.id.?, @as(u32, 2));

    // Past the last span: nothing further.
    const none = (try d.handle(alloc,
        \\{"jsonrpc":"2.0","id":4,"method":"find_metadata","params":{"above":0,"col":6,"direction":"next"}}
    )).response.?;
    defer alloc.free(none);
    const none_p = try std.json.parseFromSlice(Response, alloc, none, .{ .ignore_unknown_fields = true });
    defer none_p.deinit();
    try testz.expectFalse(none_p.value.result.found);

    // An unrecognised direction is rejected.
    try testz.expectError(d.handle(alloc,
        \\{"jsonrpc":"2.0","id":5,"method":"find_metadata","params":{"above":0,"col":0,"direction":"sideways"}}
    ), dispatch.DispatchError.InvalidMetadataDirection);
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
    try testz.expectEqual(ctx.root.sel.highlighted_ids.items.len, 3);
    // No metadata was created, so every entry's json is null (dangling).
    try testz.expectTrue(std.mem.indexOf(u8, set_result.response.?, "\"id\":7") != null);

    const clear_result = try d.handle(alloc,
        \\{"jsonrpc":"2.0","id":2,"method":"clear_highlight","params":{}}
    );
    defer if (clear_result.response) |r| alloc.free(r);
    try testz.expectEqual(ctx.root.sel.highlighted_ids.items.len, 0);
}

/// `set_clipboard` stores the text on the session; `get_clipboard`
/// returns it.
pub fn setClipboardThenGetClipboardRoundTripTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 10, 3, 0);
    defer ctx.deinit();
    var session = try glyphwire.Session.init(alloc, &ctx);
    defer session.deinit();
    var d = try helpers.attachedConnection(&session, 7);

    try testz.expectTrue((try d.handle(alloc,
        \\{"jsonrpc":"2.0","method":"set_clipboard","params":{"text":"clip me"}}
    )).response == null);
    try testz.expectEqualStr("clip me", session.clipboardText());
    try testz.expectEqual(session.clipboard_serial, 1);

    const Response = struct { jsonrpc: []const u8, id: u32, result: struct { text: []const u8 } };
    const body = (try d.handle(alloc,
        \\{"jsonrpc":"2.0","id":9,"method":"get_clipboard","params":{}}
    )).response.?;
    defer alloc.free(body);
    const parsed = try std.json.parseFromSlice(Response, alloc, body, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    try testz.expectEqualStr("clip me", parsed.value.result.text);
}

/// One clipboard per session, whichever context a connection is on and
/// whichever is on screen. Per-context buffers let glyphwire-host push a
/// stale one to the OS on every focus change between gmux panes, and
/// left a backgrounded program's `set_clipboard` stranded until its
/// context came back.
pub fn setClipboardIsSharedAcrossContextsTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 10, 3, 0);
    defer ctx.deinit();
    var session = try glyphwire.Session.init(alloc, &ctx);
    defer session.deinit();
    var shell = try helpers.attachedConnection(&session, 7);
    var program = try helpers.attachedConnection(&session, 8);

    // The program takes the screen with a context of its own, leaving
    // the shell's backgrounded.
    const created = try program.handle(alloc,
        \\{"jsonrpc":"2.0","id":1,"method":"create_context","params":{}}
    );
    if (created.response) |r| alloc.free(r);
    if (created.broadcast) |b| alloc.free(b.body);
    try testz.expectTrue(session.focusedContextHandle() != glyphwire.root_context_handle);

    _ = try shell.handle(alloc,
        \\{"jsonrpc":"2.0","method":"set_clipboard","params":{"text":"from the background"}}
    );
    try testz.expectEqualStr("from the background", session.clipboardText());
    try testz.expectEqual(session.clipboard_serial, 1);

    const Response = struct { jsonrpc: []const u8, id: u32, result: struct { text: []const u8 } };
    const body = (try program.handle(alloc,
        \\{"jsonrpc":"2.0","id":2,"method":"get_clipboard","params":{}}
    )).response.?;
    defer alloc.free(body);
    const parsed = try std.json.parseFromSlice(Response, alloc, body, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    try testz.expectEqualStr("from the background", parsed.value.result.text);
}

/// An OSC 52 inside `write_text` (a pty program's copy, Claude Code's
/// among them) lands on the session clipboard.
pub fn writeTextOsc52SetsTheSessionClipboardTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 10, 3, 0);
    defer ctx.deinit();
    var session = try glyphwire.Session.init(alloc, &ctx);
    defer session.deinit();
    var d = try helpers.attachedConnection(&session, 7);

    const result = try d.handle(alloc,
        \\{"jsonrpc":"2.0","method":"write_text","params":{"text":"\u001b]52;c;Y29waWVk\u0007"}}
    );
    try testz.expectTrue(result.response == null);
    try testz.expectEqualStr("copied", session.clipboardText());
    try testz.expectEqual(session.clipboard_serial, 1);
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
    try testz.expectTrue(d.subscriptions.hasStream(.selection));
    try testz.expectTrue(d.subscriptions.hasStream(.clipboard));
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

pub fn ptyModePropertyRoundTripsTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 80, 24, 0);
    defer ctx.deinit();
    var d = dispatch.Dispatcher.init(&ctx);
    const pane = try ctx.createLayer(20, 20, 0);

    try notifyThrough(alloc, &d,
        \\{"jsonrpc":"2.0","method":"set_property","params":{"layer":1,"property":"pty_mode","enabled":true}}
    );
    try testz.expectTrue(ctx.layerPtr(pane).?.pty_mode);

    const get_msg =
        \\{"jsonrpc":"2.0","id":8,"method":"get_property","params":{"layer":1,"property":"pty_mode"}}
    ;
    const get_decoded = try roundTripThroughWire(alloc, get_msg);
    defer alloc.free(get_decoded);
    const response_body = (try d.handle(alloc, get_decoded)).response.?;
    defer alloc.free(response_body);

    const Response = struct { id: i64, result: struct { enabled: bool } };
    const parsed = try std.json.parseFromSlice(Response, alloc, response_body, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();
    try testz.expectEqual(parsed.value.id, 8);
    try testz.expectTrue(parsed.value.result.enabled);
}

pub fn mouseSelectPropertyRoundTripsTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 80, 24, 0);
    defer ctx.deinit();
    var d = dispatch.Dispatcher.init(&ctx);
    const panel = try ctx.createLayer(20, 20, 0);

    // Off until a client asks for it: the host only selects on a
    // client-owned context's layer that opted in.
    try testz.expectFalse(ctx.layerPtr(panel).?.mouse_select);

    try notifyThrough(alloc, &d,
        \\{"jsonrpc":"2.0","method":"set_property","params":{"layer":1,"property":"mouse_select","enabled":true}}
    );
    try testz.expectTrue(ctx.layerPtr(panel).?.mouse_select);

    const get_msg =
        \\{"jsonrpc":"2.0","id":9,"method":"get_property","params":{"layer":1,"property":"mouse_select"}}
    ;
    const get_decoded = try roundTripThroughWire(alloc, get_msg);
    defer alloc.free(get_decoded);
    const response_body = (try d.handle(alloc, get_decoded)).response.?;
    defer alloc.free(response_body);

    const Response = struct { id: i64, result: struct { enabled: bool } };
    const parsed = try std.json.parseFromSlice(Response, alloc, response_body, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();
    try testz.expectEqual(parsed.value.id, 9);
    try testz.expectTrue(parsed.value.result.enabled);

    try notifyThrough(alloc, &d,
        \\{"jsonrpc":"2.0","method":"set_property","params":{"layer":1,"property":"mouse_select","enabled":false}}
    );
    try testz.expectFalse(ctx.layerPtr(panel).?.mouse_select);
}

pub fn mouseReportPropertyRoundTripsTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 80, 24, 0);
    defer ctx.deinit();
    var d = dispatch.Dispatcher.init(&ctx);

    // Off until a mouse-mode program turns it on, root included.
    try testz.expectFalse(ctx.root.mouse_report);

    try notifyThrough(alloc, &d,
        \\{"jsonrpc":"2.0","method":"set_property","params":{"layer":0,"property":"mouse_report","enabled":true}}
    );
    try testz.expectTrue(ctx.root.mouse_report);

    const get_decoded = try roundTripThroughWire(alloc,
        \\{"jsonrpc":"2.0","id":4,"method":"get_property","params":{"layer":0,"property":"mouse_report"}}
    );
    defer alloc.free(get_decoded);
    const response_body = (try d.handle(alloc, get_decoded)).response.?;
    defer alloc.free(response_body);
    const Response = struct { id: i64, result: struct { enabled: bool } };
    const parsed = try std.json.parseFromSlice(Response, alloc, response_body, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    try testz.expectTrue(parsed.value.result.enabled);

    // Independent of `mouse_select`.
    try testz.expectFalse(ctx.root.mouse_select);

    try notifyThrough(alloc, &d,
        \\{"jsonrpc":"2.0","method":"set_property","params":{"layer":0,"property":"mouse_report","enabled":false}}
    );
    try testz.expectFalse(ctx.root.mouse_report);
}

/// `selection_flow` sets and reports a layer's mode and column grid; an
/// unknown mode is refused and leaves the layer as it was; `{}` with no
/// mode puts it back to horizontal.
pub fn selectionFlowPropertyRoundTripsTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 80, 24, 0);
    defer ctx.deinit();
    var d = dispatch.Dispatcher.init(&ctx);
    const panel = try ctx.createLayer(20, 20, 0);
    try testz.expectEqual(ctx.layerPtr(panel).?.sel.flow.mode, .horizontal);

    try notifyThrough(alloc, &d,
        \\{"jsonrpc":"2.0","method":"set_property","params":{"layer":1,"property":"selection_flow","mode":"vertical_rl","cols":4,"col":2}}
    );
    const flow = ctx.layerPtr(panel).?.sel.flow;
    try testz.expectEqual(flow.mode, .vertical_rl);
    try testz.expectEqual(flow.column_cols, 4);
    try testz.expectEqual(flow.origin_col, 2);

    const get_msg =
        \\{"jsonrpc":"2.0","id":9,"method":"get_property","params":{"layer":1,"property":"selection_flow"}}
    ;
    const get_decoded = try roundTripThroughWire(alloc, get_msg);
    defer alloc.free(get_decoded);
    const response_body = (try d.handle(alloc, get_decoded)).response.?;
    defer alloc.free(response_body);
    const Response = struct { id: i64, result: struct { mode: []const u8, cols: usize, col: usize } };
    const parsed = try std.json.parseFromSlice(Response, alloc, response_body, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();
    try testz.expectEqualStr("vertical_rl", parsed.value.result.mode);
    try testz.expectEqual(parsed.value.result.cols, 4);
    try testz.expectEqual(parsed.value.result.col, 2);

    const bad_msg =
        \\{"jsonrpc":"2.0","method":"set_property","params":{"layer":1,"property":"selection_flow","mode":"sideways"}}
    ;
    const bad_decoded = try roundTripThroughWire(alloc, bad_msg);
    defer alloc.free(bad_decoded);
    try testz.expectError(d.handle(alloc, bad_decoded), dispatch.DispatchError.InvalidSelectionFlow);
    try testz.expectEqual(ctx.layerPtr(panel).?.sel.flow.mode, .vertical_rl);

    try notifyThrough(alloc, &d,
        \\{"jsonrpc":"2.0","method":"set_property","params":{"layer":1,"property":"selection_flow"}}
    );
    try testz.expectEqual(ctx.layerPtr(panel).?.sel.flow.mode, .horizontal);
}

/// `resize_edge` sets and reports a layer's draggable edge; an unknown
/// edge is refused and leaves the layer as it was; omitting `edge` takes
/// it back off.
pub fn resizeEdgePropertyRoundTripsTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 80, 24, 0);
    defer ctx.deinit();
    var d = dispatch.Dispatcher.init(&ctx);
    const panel = try ctx.createLayer(20, 20, 0);
    try testz.expectEqual(ctx.layerPtr(panel).?.resize_edge, .none);

    try notifyThrough(alloc, &d,
        \\{"jsonrpc":"2.0","method":"set_property","params":{"layer":1,"property":"resize_edge","edge":"top"}}
    );
    try testz.expectEqual(ctx.layerPtr(panel).?.resize_edge, .top);

    const get_msg =
        \\{"jsonrpc":"2.0","id":9,"method":"get_property","params":{"layer":1,"property":"resize_edge"}}
    ;
    const get_decoded = try roundTripThroughWire(alloc, get_msg);
    defer alloc.free(get_decoded);
    const response_body = (try d.handle(alloc, get_decoded)).response.?;
    defer alloc.free(response_body);
    const Response = struct { id: i64, result: struct { edge: []const u8 } };
    const parsed = try std.json.parseFromSlice(Response, alloc, response_body, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();
    try testz.expectEqualStr("top", parsed.value.result.edge);

    const bad_msg =
        \\{"jsonrpc":"2.0","method":"set_property","params":{"layer":1,"property":"resize_edge","edge":"diagonal"}}
    ;
    const bad_decoded = try roundTripThroughWire(alloc, bad_msg);
    defer alloc.free(bad_decoded);
    try testz.expectError(d.handle(alloc, bad_decoded), dispatch.DispatchError.InvalidResizeEdge);
    try testz.expectEqual(ctx.layerPtr(panel).?.resize_edge, .top);

    // The side and bottom edges a docked panel's other positions use.
    try notifyThrough(alloc, &d,
        \\{"jsonrpc":"2.0","method":"set_property","params":{"layer":1,"property":"resize_edge","edge":"left"}}
    );
    try testz.expectEqual(ctx.layerPtr(panel).?.resize_edge, .left);
    try notifyThrough(alloc, &d,
        \\{"jsonrpc":"2.0","method":"set_property","params":{"layer":1,"property":"resize_edge","edge":"bottom"}}
    );
    try testz.expectEqual(ctx.layerPtr(panel).?.resize_edge, .bottom);

    try notifyThrough(alloc, &d,
        \\{"jsonrpc":"2.0","method":"set_property","params":{"layer":1,"property":"resize_edge"}}
    );
    try testz.expectEqual(ctx.layerPtr(panel).?.resize_edge, .none);
}

/// `set_divider_style` stores a preset and glyphs on the context; a bad
/// preset or glyph is refused and leaves it as it was; no params goes
/// back to inheriting the host's style.
pub fn setDividerStyleRoundTripsTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 80, 24, 0);
    defer ctx.deinit();
    var d = dispatch.Dispatcher.init(&ctx);
    try testz.expectTrue(ctx.divider_style.inherits());

    try notifyThrough(alloc, &d,
        \\{"jsonrpc":"2.0","method":"set_divider_style","params":{"style":"heavy","chars":{"v":"┇"}}}
    );
    try testz.expectTrue(ctx.divider_style.preset.? == .heavy);
    try testz.expectEqualStr("┇", ctx.divider_style.chars.v.?.slice());
    const gen = ctx.divider_style_gen;

    const bad_style = try roundTripThroughWire(alloc,
        \\{"jsonrpc":"2.0","method":"set_divider_style","params":{"style":"wavy"}}
    );
    defer alloc.free(bad_style);
    try testz.expectError(d.handle(alloc, bad_style), dispatch.DispatchError.UnknownDividerStyle);
    const bad_char = try roundTripThroughWire(alloc,
        \\{"jsonrpc":"2.0","method":"set_divider_style","params":{"chars":{"h":"--"}}}
    );
    defer alloc.free(bad_char);
    try testz.expectError(d.handle(alloc, bad_char), dispatch.DispatchError.InvalidDividerChar);
    try testz.expectTrue(ctx.divider_style.preset.? == .heavy);
    try testz.expectEqual(ctx.divider_style_gen, gen);

    try notifyThrough(alloc, &d,
        \\{"jsonrpc":"2.0","method":"set_divider_style","params":{}}
    );
    try testz.expectTrue(ctx.divider_style.inherits());
}

/// What `Client.setDividerStyle` puts on the wire reads back as the same
/// override.
pub fn dividerStyleWireRoundTripsTest(_: std.Io, _: std.mem.Allocator) !void {
    const ds = glyphwire.divider_style;
    const sent: ds.Override = .{ .preset = .double, .chars = .{ .tl = ds.Glyph.init("╭").? } };
    const on_wire = glyphwire.protocol.DividerStyleWire.fromOverride(&sent);
    try testz.expectEqualStr("double", on_wire.style.?);
    try testz.expectTrue(on_wire.chars.?.h == null);
    const back = try on_wire.toOverride();
    try testz.expectTrue(back.preset.? == .double);
    try testz.expectEqualStr("╭", back.chars.tl.?.slice());
    try testz.expectTrue(back.chars.br == null);

    const none = glyphwire.protocol.DividerStyleWire.fromOverride(&.{});
    try testz.expectTrue(none.style == null and none.chars == null);
}

/// `layer_resize` rides the `layout` stream, and can be asked for by its
/// own name.
pub fn layerResizeSubscribesThroughLayoutTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 80, 24, 0);
    defer ctx.deinit();
    var d = dispatch.Dispatcher.init(&ctx);

    const result = try d.handle(alloc,
        \\{"jsonrpc":"2.0","id":1,"method":"subscribe","params":{"events":["layer_resize"]}}
    );
    if (result.response) |r| alloc.free(r);
    try testz.expectTrue(d.subscriptions.hasStream(.layout));
    try testz.expectTrue(d.subscriptions.has(.layer_resize));
    try testz.expectTrue(d.subscriptions.has(.layout));
}

/// `write_text`'s `copy_text` reaches the cells: a selection over the
/// glyph copies the stand-in's original text.
pub fn writeTextCopyTextIsWhatSelectionCopiesTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 80, 24, 0);
    defer ctx.deinit();
    var d = dispatch.Dispatcher.init(&ctx);
    const panel = try ctx.createLayer(20, 4, 0);

    try notifyThrough(alloc, &d,
        \\{"jsonrpc":"2.0","method":"write_text","params":{"layer":1,"row":0,"col":0,"text":"﹁","copy_text":"「"}}
    );
    try notifyThrough(alloc, &d,
        \\{"jsonrpc":"2.0","method":"write_text","params":{"layer":1,"text":"あ"}}
    );
    const layer = ctx.layerPtr(panel).?;
    layer.sel.set(.{ .above = 0, .col = 0 }, .{ .above = 0, .col = 3 });
    const text = (try layer.sel.text(alloc)).?;
    defer alloc.free(text);
    try testz.expectEqualStr("「あ", text);
}

pub fn setCaretLayerPointsAndClearsTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 80, 24, 0);
    defer ctx.deinit();
    var d = dispatch.Dispatcher.init(&ctx);
    const pane = try ctx.createLayer(20, 20, 0);

    try notifyThrough(alloc, &d,
        \\{"jsonrpc":"2.0","method":"set_caret_layer","params":{"layer":1}}
    );
    try testz.expectEqual(ctx.caret_layer.?, pane);

    // A null layer restores the root cursor.
    try notifyThrough(alloc, &d,
        \\{"jsonrpc":"2.0","method":"set_caret_layer","params":{"layer":null}}
    );
    try testz.expectEqual(ctx.caret_layer, null);
}

/// `set_caret_visible` flips the context's caret flag and leaves the root
/// layer's own DECTCEM flag alone.
pub fn setCaretVisibleHidesAndShowsTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 80, 24, 0);
    defer ctx.deinit();
    var d = dispatch.Dispatcher.init(&ctx);
    try testz.expectTrue(ctx.caret_visible);

    try notifyThrough(alloc, &d,
        \\{"jsonrpc":"2.0","method":"set_caret_visible","params":{"visible":false}}
    );
    try testz.expectFalse(ctx.caret_visible);
    try testz.expectTrue(ctx.root.vt.cursor_visible);

    try notifyThrough(alloc, &d,
        \\{"jsonrpc":"2.0","method":"set_caret_visible","params":{"visible":true}}
    );
    try testz.expectTrue(ctx.caret_visible);
}

/// `set_caret_shape` picks one of the four named shapes, `null` (or an
/// absent field) goes back to the host's configured one, and a name the
/// host has no shape for is refused and leaves the setting alone.
pub fn setCaretShapeSetsAndClearsTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 80, 24, 0);
    defer ctx.deinit();
    var d = dispatch.Dispatcher.init(&ctx);
    try testz.expectEqual(ctx.caret_shape, null);

    try notifyThrough(alloc, &d,
        \\{"jsonrpc":"2.0","method":"set_caret_shape","params":{"shape":"line"}}
    );
    try testz.expectEqual(ctx.caret_shape.?, glyphwire.CaretShape.line);

    try notifyThrough(alloc, &d,
        \\{"jsonrpc":"2.0","method":"set_caret_shape","params":{"shape":"underline"}}
    );
    try testz.expectEqual(ctx.caret_shape.?, glyphwire.CaretShape.underline);

    // A shape that doesn't exist is a bad request, not a silent reset.
    const bad = try roundTripThroughWire(alloc,
        \\{"jsonrpc":"2.0","method":"set_caret_shape","params":{"shape":"squiggle"}}
    );
    defer alloc.free(bad);
    if (d.handle(alloc, bad)) |_| return error.ExpectedFailure else |_| {}
    try testz.expectEqual(ctx.caret_shape.?, glyphwire.CaretShape.underline);

    try notifyThrough(alloc, &d,
        \\{"jsonrpc":"2.0","method":"set_caret_shape","params":{"shape":null}}
    );
    try testz.expectEqual(ctx.caret_shape, null);
}

/// `create_metadata`'s optional `drag` reaches the tag; `start_drag`
/// queues its payload for the host; an empty URI list is refused.
pub fn createMetadataDragAndStartDragTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 80, 24, 0);
    defer ctx.deinit();
    var d = dispatch.Dispatcher.init(&ctx);

    const create_msg =
        \\{"jsonrpc":"2.0","id":1,"method":"create_metadata","params":{"json":"{}","drag":{"uris":["file:///tmp/x.txt"],"label":"x.txt","icon":"file/text"}}}
    ;
    const created = try d.handle(alloc, create_msg);
    defer if (created.response) |r| alloc.free(r);
    try testz.expectTrue(std.mem.indexOf(u8, created.response.?, "\"handle\":1") != null);
    const drag = ctx.metadataDrag(1).?;
    try testz.expectEqualStr(drag.uris[0], "file:///tmp/x.txt");
    try testz.expectEqualStr(drag.label.?, "x.txt");

    try notifyThrough(alloc, &d,
        \\{"jsonrpc":"2.0","method":"start_drag","params":{"uris":["file:///a","file:///b"],"label":"2 files"}}
    );
    var req = ctx.takeDragRequest().?;
    defer req.deinit(alloc);
    try testz.expectEqual(req.uris.len, 2);
    try testz.expectTrue(req.icon == null);

    const empty_start = try roundTripThroughWire(alloc,
        \\{"jsonrpc":"2.0","method":"start_drag","params":{"uris":[]}}
    );
    defer alloc.free(empty_start);
    if (d.handle(alloc, empty_start)) |_| return error.ExpectedFailure else |_| {}
    try testz.expectTrue(ctx.takeDragRequest() == null);
}

/// `set_drop_target`'s three shapes land on the layer, `"none"` clears
/// it, a cell shape missing its `row` / `col` or an unknown `mode` is
/// refused and leaves what was there, and repeating the target already
/// shown doesn't invalidate the layer's render cache.
pub fn setDropTargetSetsMovesAndClearsTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 80, 24, 0);
    defer ctx.deinit();
    var d = dispatch.Dispatcher.init(&ctx);
    try testz.expectTrue(ctx.root.drop_target == null);

    try notifyThrough(alloc, &d,
        \\{"jsonrpc":"2.0","method":"set_drop_target","params":{"mode":"layer"}}
    );
    try testz.expectTrue(ctx.root.drop_target.? == .layer);

    try notifyThrough(alloc, &d,
        \\{"jsonrpc":"2.0","method":"set_drop_target","params":{"mode":"cells","row":2,"col":3,"rows":4,"cols":5}}
    );
    const c = ctx.root.drop_target.?.cells;
    try testz.expectEqual(c.row, 2);
    try testz.expectEqual(c.col, 3);
    try testz.expectEqual(c.rows, 4);
    try testz.expectEqual(c.cols, 5);

    // `rows` left out (or null, as `Client.setDropTarget` sends it) is one.
    try notifyThrough(alloc, &d,
        \\{"jsonrpc":"2.0","method":"set_drop_target","params":{"mode":"insert","row":0,"col":12,"rows":null}}
    );
    const ins = ctx.root.drop_target.?.insert;
    try testz.expectEqual(ins.col, 12);
    try testz.expectEqual(ins.rows, 1);

    // The same target again: nothing for the renderer to rebuild.
    const gen = ctx.root.renderGeneration();
    try notifyThrough(alloc, &d,
        \\{"jsonrpc":"2.0","method":"set_drop_target","params":{"mode":"insert","row":0,"col":12}}
    );
    try testz.expectEqual(ctx.root.renderGeneration(), gen);

    const bad_mode = try roundTripThroughWire(alloc,
        \\{"jsonrpc":"2.0","method":"set_drop_target","params":{"mode":"sideways"}}
    );
    defer alloc.free(bad_mode);
    if (d.handle(alloc, bad_mode)) |_| return error.ExpectedFailure else |_| {}
    const no_col = try roundTripThroughWire(alloc,
        \\{"jsonrpc":"2.0","method":"set_drop_target","params":{"mode":"cells","row":1}}
    );
    defer alloc.free(no_col);
    if (d.handle(alloc, no_col)) |_| return error.ExpectedFailure else |_| {}
    try testz.expectEqual(ctx.root.drop_target.?.insert.col, 12);

    try notifyThrough(alloc, &d,
        \\{"jsonrpc":"2.0","method":"set_drop_target","params":{"mode":"none"}}
    );
    try testz.expectTrue(ctx.root.drop_target == null);
}

pub fn setKeyRepeatSetsAndClearsOverrideTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 80, 24, 0);
    defer ctx.deinit();
    var d = dispatch.Dispatcher.init(&ctx);

    // Nothing asked for: the host's own default stands.
    try testz.expectEqual(ctx.key_repeat, null);

    try notifyThrough(alloc, &d,
        \\{"jsonrpc":"2.0","method":"set_key_repeat","params":{"delay_ms":30,"interval_ms":30}}
    );
    try testz.expectEqual(ctx.key_repeat.?.delay_ms, 30.0);
    try testz.expectEqual(ctx.key_repeat.?.interval_ms, 30.0);

    // Empty params clear the override.
    try notifyThrough(alloc, &d,
        \\{"jsonrpc":"2.0","method":"set_key_repeat","params":{}}
    );
    try testz.expectEqual(ctx.key_repeat, null);
}

pub fn setKeyRepeatBumpsGenerationEveryTimeTest(io: std.Io, alloc: std.mem.Allocator) !void {
    // The host cancels whatever is held on each arrival, so an arrival
    // has to be observable even when it sets the same numbers again --
    // zoe retimes on every mode change, and both modes may be
    // configured identically.
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 80, 24, 0);
    defer ctx.deinit();
    var d = dispatch.Dispatcher.init(&ctx);
    try testz.expectEqual(ctx.key_repeat_gen, 0);

    try notifyThrough(alloc, &d,
        \\{"jsonrpc":"2.0","method":"set_key_repeat","params":{"delay_ms":300,"interval_ms":30}}
    );
    try testz.expectEqual(ctx.key_repeat_gen, 1);

    try notifyThrough(alloc, &d,
        \\{"jsonrpc":"2.0","method":"set_key_repeat","params":{"delay_ms":300,"interval_ms":30}}
    );
    try testz.expectEqual(ctx.key_repeat_gen, 2);

    // Clearing the override counts too.
    try notifyThrough(alloc, &d,
        \\{"jsonrpc":"2.0","method":"set_key_repeat","params":{}}
    );
    try testz.expectEqual(ctx.key_repeat_gen, 3);
}

pub fn setKeyRepeatPartialParamsKeepTheOtherFieldTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 80, 24, 0);
    defer ctx.deinit();
    var d = dispatch.Dispatcher.init(&ctx);

    // With no override yet, the unnamed field comes from the protocol's
    // own default, not from whatever the host was running at.
    try notifyThrough(alloc, &d,
        \\{"jsonrpc":"2.0","method":"set_key_repeat","params":{"interval_ms":25}}
    );
    try testz.expectEqual(ctx.key_repeat.?.delay_ms, glyphwire.KeyRepeat.default_delay_ms);
    try testz.expectEqual(ctx.key_repeat.?.interval_ms, 25.0);

    // A second call naming only the delay keeps the interval just set.
    try notifyThrough(alloc, &d,
        \\{"jsonrpc":"2.0","method":"set_key_repeat","params":{"delay_ms":0}}
    );
    try testz.expectEqual(ctx.key_repeat.?.delay_ms, 0.0);
    try testz.expectEqual(ctx.key_repeat.?.interval_ms, 25.0);
}

pub fn setCaretLayerRejectsUnknownHandleTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 80, 24, 0);
    defer ctx.deinit();
    var d = dispatch.Dispatcher.init(&ctx);
    _ = try ctx.createLayer(20, 20, 0);
    try notifyThrough(alloc, &d,
        \\{"jsonrpc":"2.0","method":"set_caret_layer","params":{"layer":1}}
    );

    // An unknown handle is refused and the current setting is left alone
    // (root handle 0 counts as unknown here -- it has no lifecycle).
    const decoded = try roundTripThroughWire(alloc,
        \\{"jsonrpc":"2.0","method":"set_caret_layer","params":{"layer":99}}
    );
    defer alloc.free(decoded);
    try testz.expectError(d.handle(alloc, decoded), dispatch.DispatchError.UnknownLayer);
    try testz.expectEqual(ctx.caret_layer.?, @as(glyphwire.LayerHandle, 1));

    // Destroying the tracked layer drops the dangling handle.
    try ctx.destroyLayer(1);
    try testz.expectEqual(ctx.caret_layer, null);
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
    try testz.expectEqual(ctx.split_tree.node(1).?.axis, .row);
}

pub fn createSplitCarriesTheResizableFlagTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 80, 24, 0);
    defer ctx.deinit();
    var d = dispatch.Dispatcher.init(&ctx);

    // Default (omitted) is resizable.
    {
        const decoded = try roundTripThroughWire(alloc,
            \\{"jsonrpc":"2.0","id":1,"method":"create_split","params":{"axis":"row"}}
        );
        defer alloc.free(decoded);
        const body = (try d.handle(alloc, decoded)).response.?;
        defer alloc.free(body);
    }
    try testz.expectTrue(ctx.split_tree.node(1).?.resizable);

    // Explicit false lands on the split.
    {
        const decoded = try roundTripThroughWire(alloc,
            \\{"jsonrpc":"2.0","id":2,"method":"create_split","params":{"axis":"column","resizable":false}}
        );
        defer alloc.free(decoded);
        const body = (try d.handle(alloc, decoded)).response.?;
        defer alloc.free(body);
    }
    try testz.expectTrue(!ctx.split_tree.node(2).?.resizable);
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
    try testz.expectEqual(broadcast.event, .layout);

    const Notif = struct {
        method: []const u8,
        params: struct {
            layers: []const struct { layer: u32, row: usize, col: usize, cols: usize, rows: usize },
        },
    };
    const parsed = try glyphwire.msgpack.decode(Notif, alloc, broadcast.body, .{});
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

    try testz.expectTrue(d.subscriptions.hasStream(.layout));
    // `scroll_offset` rides the `scroll` subscription -- a client that
    // wants to know the view moved wants both kinds.
    try testz.expectTrue(d.subscriptions.hasStream(.scroll));
    try testz.expectTrue(d.subscriptions.has(.scroll_offset));
}

// ── Layer ownership: create records an owner, destroy enforces it, ──────
//    adopt adds a co-owner (see `core.ConnId` / `Dispatcher.conn_id`).

pub fn createLayerOverConnectionRecordsOwnerTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 40, 10, 0);
    defer ctx.deinit();
    var session = try glyphwire.Session.init(alloc, &ctx);
    defer session.deinit();
    var d = try helpers.attachedConnection(&session, 7);

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

    var owner = try helpers.attachedConnection(&session, 7);
    const create =
        \\{"jsonrpc":"2.0","id":1,"method":"create_layer","params":{"scrollback_rows":0}}
    ;
    const created = try owner.handle(alloc, create);
    if (created.response) |r| alloc.free(r);

    var other = try helpers.attachedConnection(&session, 8);
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
    var d = try helpers.attachedConnection(&session, 7);

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

    var creator = try helpers.attachedConnection(&session, 7);
    const create =
        \\{"jsonrpc":"2.0","id":1,"method":"create_layer","params":{"scrollback_rows":0}}
    ;
    const created = try creator.handle(alloc, create);
    if (created.response) |r| alloc.free(r);

    var adopter = try helpers.attachedConnection(&session, 8);
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
    var d = try helpers.attachedConnection(&session, 8);

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
    var conn = try helpers.attachedConnection(&session, 9);
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
    try testz.expectTrue(d.subscriptions.hasStream(.@"error"));
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
    var d = try helpers.attachedConnection(&session, 7);

    const result = try d.handle(alloc,
        \\{"jsonrpc":"2.0","id":1,"method":"create_context","params":{"scrollback_rows":0}}
    );
    defer if (result.response) |r| alloc.free(r);
    defer if (result.broadcast) |b| alloc.free(b.body);

    try testz.expectTrue(std.mem.indexOf(u8, result.response.?, "\"context\":1") != null);
    try testz.expectTrue(result.broadcast != null);
    try testz.expectEqual(result.broadcast.?.event, .context);
    try expectPushHas(alloc, result.broadcast.?.body, "\"context\":1");

    // The dispatcher now points at the new context, and it's visible.
    try testz.expectEqual(d.active_ctx, @as(glyphwire.ContextHandle, 1));
    try testz.expectEqual(session.focusedContextHandle(), @as(glyphwire.ContextHandle, 1));
    try testz.expectEqual(session.contextPtr(1).?, d.ctx);
}

/// The shell's Enter launches a full-screen program, whose context takes
/// focus before the key comes back up. The release has to clear the same
/// down-set the press went into, or the next Enter once the program has
/// exited is dropped as a redundant press-while-down (the "have to hit
/// Enter twice after gwmd" bug).
pub fn keyReleasedAfterAContextSwitchDoesNotSwallowTheNextPressTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var root = try glyphwire.Context.init(alloc, 40, 10, 0);
    defer root.deinit();
    var session = try glyphwire.Session.init(alloc, &root);
    defer session.deinit();
    var d = try helpers.managerConnection(&session, 7);

    const press =
        \\{"jsonrpc":"2.0","method":"report_key","params":{"key":"enter","pressed":true}}
    ;
    const release =
        \\{"jsonrpc":"2.0","method":"report_key","params":{"key":"enter","pressed":false}}
    ;

    const first_press = try d.handle(alloc, press);
    alloc.free(first_press.broadcast.?.body);

    const created = try d.handle(alloc,
        \\{"jsonrpc":"2.0","id":1,"method":"create_context","params":{"scrollback_rows":0}}
    );
    if (created.response) |r| alloc.free(r);
    if (created.broadcast) |b| alloc.free(b.body);
    try testz.expectEqual(session.focusedContextHandle(), @as(glyphwire.ContextHandle, 1));

    const first_release = try d.handle(alloc, release);
    try testz.expectTrue(first_release.broadcast != null);
    alloc.free(first_release.broadcast.?.body);

    const destroyed = try d.handle(alloc,
        \\{"jsonrpc":"2.0","method":"destroy_context","params":{"context":1}}
    );
    if (destroyed.response) |r| alloc.free(r);
    if (destroyed.broadcast) |b| alloc.free(b.body);
    try testz.expectEqual(session.focusedContextHandle(), glyphwire.root_context_handle);

    const second_press = try d.handle(alloc, press);
    try testz.expectTrue(second_press.broadcast != null);
    defer alloc.free(second_press.broadcast.?.body);
    try expectPushHas(alloc, second_press.broadcast.?.body, "key_down");
}

pub fn createContextAndSetWindowScrollbarToggleTheFlagTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var root = try glyphwire.Context.init(alloc, 40, 10, 0);
    defer root.deinit();
    var session = try glyphwire.Session.init(alloc, &root);
    defer session.deinit();
    var d = try helpers.attachedConnection(&session, 7);

    // A pure-TUI client creates its context with the window bar off.
    const created = try d.handle(alloc,
        \\{"jsonrpc":"2.0","id":1,"method":"create_context","params":{"scrollback_rows":0,"window_scrollbar":false}}
    );
    if (created.response) |r| alloc.free(r);
    if (created.broadcast) |b| alloc.free(b.body);
    try testz.expectTrue(!session.contextPtr(1).?.window_scrollbar);
    // The root context keeps its default.
    try testz.expectTrue(root.window_scrollbar);

    // And it can turn it back on at runtime.
    _ = try d.handle(alloc,
        \\{"jsonrpc":"2.0","method":"set_window_scrollbar","params":{"visible":true}}
    );
    try testz.expectTrue(session.contextPtr(1).?.window_scrollbar);
}

pub fn writeTextAfterCreateContextLandsOnTheNewContextNotRootTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var root = try glyphwire.Context.init(alloc, 40, 10, 0);
    defer root.deinit();
    var session = try glyphwire.Session.init(alloc, &root);
    defer session.deinit();
    var d = try helpers.attachedConnection(&session, 7);

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

    var owner = try helpers.attachedConnection(&session, 7);
    const created = try owner.handle(alloc,
        \\{"jsonrpc":"2.0","id":1,"method":"create_context","params":{"scrollback_rows":0}}
    );
    if (created.response) |r| alloc.free(r);
    if (created.broadcast) |b| alloc.free(b.body);

    var other = try helpers.attachedConnection(&session, 8);
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
    var d = try helpers.attachedConnection(&session, 7);

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
    try testz.expectEqual(session.focusedContextHandle(), glyphwire.root_context_handle);
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
    var d = try helpers.attachedConnection(&session, 7);

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
    try testz.expectEqual(session.focusedContextHandle(), glyphwire.root_context_handle);
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
    try testz.expectEqual(session.focusedContextHandle(), @as(glyphwire.ContextHandle, 1));
}

pub fn attachContextRetargetsWithoutOwningTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var root = try glyphwire.Context.init(alloc, 40, 10, 0);
    defer root.deinit();
    var session = try glyphwire.Session.init(alloc, &root);
    defer session.deinit();

    var creator = try helpers.attachedConnection(&session, 7);
    const created = try creator.handle(alloc,
        \\{"jsonrpc":"2.0","id":1,"method":"create_context","params":{"scrollback_rows":0}}
    );
    if (created.response) |r| alloc.free(r);
    if (created.broadcast) |b| alloc.free(b.body);

    // A second connection (a paired listener) attaches -- retargeted, but
    // not an owner, so it can't destroy it.
    var listener = try helpers.attachedConnection(&session, 8);
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

pub fn attachLayerMakesAnOmittedLayerMeanTheSurfaceTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var root = try glyphwire.Context.init(alloc, 40, 10, 0);
    defer root.deinit();

    // The panel: what a host (salacommander's Ctrl+` layer) creates for
    // the program it is about to launch.
    var d = dispatch.Dispatcher.init(&root);
    const created = try d.handle(alloc,
        \\{"jsonrpc":"2.0","id":1,"method":"create_layer","params":{"width":20,"height":4}}
    );
    if (created.response) |r| alloc.free(r);
    if (created.broadcast) |b| alloc.free(b.body);

    // The program declares it, as `Client.connect` does from
    // GLYPHWIRE_LAYER, and then draws with no layer of its own.
    _ = try d.handle(alloc,
        \\{"jsonrpc":"2.0","method":"attach_layer","params":{"layer":1}}
    );
    _ = try d.handle(alloc,
        \\{"jsonrpc":"2.0","method":"set_property","params":{"property":"cursor","row":1,"col":0}}
    );
    _ = try d.handle(alloc,
        \\{"jsonrpc":"2.0","method":"write_text","params":{"text":"panel"}}
    );

    const panel = root.layerPtr(1).?;
    try testz.expectEqualStr(panel.cell(1, 0).grapheme(), "p");
    // ...and the root layer underneath it was never touched, which is
    // the bug this exists to stop.
    try testz.expectEqualStr(root.layerPtr(null).?.cell(1, 0).grapheme(), "");

    // Null puts it back, and an unknown handle is refused rather than
    // silently redirecting every later draw.
    _ = try d.handle(alloc,
        \\{"jsonrpc":"2.0","method":"attach_layer","params":{}}
    );
    _ = try d.handle(alloc,
        \\{"jsonrpc":"2.0","method":"set_property","params":{"property":"cursor","row":2,"col":0}}
    );
    _ = try d.handle(alloc,
        \\{"jsonrpc":"2.0","method":"write_text","params":{"text":"root"}}
    );
    try testz.expectEqualStr(root.layerPtr(null).?.cell(2, 0).grapheme(), "r");

    try testz.expectError(d.handle(alloc,
        \\{"jsonrpc":"2.0","method":"attach_layer","params":{"layer":999}}
    ), dispatch.DispatchError.UnknownLayer);
}

pub fn attachLayerSurvivesItsLayerBeingDestroyedTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var root = try glyphwire.Context.init(alloc, 40, 10, 0);
    defer root.deinit();

    var d = dispatch.Dispatcher.init(&root);
    const created = try d.handle(alloc,
        \\{"jsonrpc":"2.0","id":1,"method":"create_layer","params":{"width":20,"height":4}}
    );
    if (created.response) |r| alloc.free(r);
    if (created.broadcast) |b| alloc.free(b.body);
    _ = try d.handle(alloc,
        \\{"jsonrpc":"2.0","method":"attach_layer","params":{"layer":1}}
    );
    _ = try d.handle(alloc,
        \\{"jsonrpc":"2.0","method":"destroy_layer","params":{"layer":1}}
    );

    // The panel is gone -- the client keeps drawing, on the root layer,
    // rather than failing every message from here on.
    _ = try d.handle(alloc,
        \\{"jsonrpc":"2.0","method":"set_property","params":{"property":"cursor","row":0,"col":0}}
    );
    _ = try d.handle(alloc,
        \\{"jsonrpc":"2.0","method":"write_text","params":{"text":"x"}}
    );
    try testz.expectEqualStr(root.layerPtr(null).?.cell(0, 0).grapheme(), "x");
}

pub fn adoptContextLetsASecondConnectionDestroyItTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var root = try glyphwire.Context.init(alloc, 40, 10, 0);
    defer root.deinit();
    var session = try glyphwire.Session.init(alloc, &root);
    defer session.deinit();

    var creator = try helpers.attachedConnection(&session, 7);
    const created = try creator.handle(alloc,
        \\{"jsonrpc":"2.0","id":1,"method":"create_context","params":{"scrollback_rows":0}}
    );
    if (created.response) |r| alloc.free(r);
    if (created.broadcast) |b| alloc.free(b.body);

    var adopter = try helpers.attachedConnection(&session, 8);
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

const ListContextsResponse = struct { result: glyphwire.protocol.ListContextsResult };

/// Runs `list_contexts` on `d` and returns the parsed result.
fn listContexts(d: *dispatch.Dispatcher, alloc: std.mem.Allocator) !std.json.Parsed(ListContextsResponse) {
    const res = try d.handle(alloc,
        \\{"jsonrpc":"2.0","id":9,"method":"list_contexts"}
    );
    if (res.broadcast) |b| alloc.free(b.body);
    const body = res.response.?;
    defer alloc.free(body);
    return std.json.parseFromSlice(ListContextsResponse, alloc, body, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
}

pub fn createContextTitleIsListedTopFirstWithTheCallersOwnContextTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var root = try glyphwire.Context.init(alloc, 40, 10, 0);
    defer root.deinit();
    var session = try glyphwire.Session.init(alloc, &root);
    defer session.deinit();

    // The shell: inherits the root context and names it.
    var shell = try helpers.attachedConnection(&session, 7);
    _ = try shell.handle(alloc,
        \\{"jsonrpc":"2.0","method":"set_context_title","params":{"title":"gw-shell"}}
    );

    // An editor started from it: its own context, named at creation.
    var editor = try helpers.attachedConnection(&session, 8);
    const created = try editor.handle(alloc,
        \\{"jsonrpc":"2.0","id":1,"method":"create_context","params":{"title":"zoe main.zig"}}
    );
    if (created.response) |r| alloc.free(r);
    if (created.broadcast) |b| alloc.free(b.body);

    var list = try listContexts(&shell, alloc);
    defer list.deinit();
    const r = list.value.result;
    // `current` is the *asking* connection's context, not what's on top.
    try testz.expectEqual(r.current, glyphwire.root_context_handle);
    try testz.expectEqual(r.contexts.len, 2);
    try testz.expectEqual(r.contexts[0].context, 1);
    try testz.expectEqualStr(r.contexts[0].title, "zoe main.zig");
    try testz.expectTrue(r.contexts[0].visible);
    try testz.expectEqual(r.contexts[1].context, glyphwire.root_context_handle);
    try testz.expectEqualStr(r.contexts[1].title, "gw-shell");
    try testz.expectFalse(r.contexts[1].visible);
}

pub fn activateContextReordersListContextsTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var root = try glyphwire.Context.init(alloc, 40, 10, 0);
    defer root.deinit();
    var session = try glyphwire.Session.init(alloc, &root);
    defer session.deinit();

    var a = try helpers.attachedConnection(&session, 7);
    var b = try helpers.attachedConnection(&session, 8);
    inline for (.{ &a, &b }) |d| {
        const created = try d.handle(alloc,
            \\{"jsonrpc":"2.0","id":1,"method":"create_context","params":{}}
        );
        if (created.response) |r| alloc.free(r);
        if (created.broadcast) |bc| alloc.free(bc.body);
    }

    // Bringing the first one back moves it above the second, and the
    // second keeps running underneath -- nothing is destroyed.
    const act = try b.handle(alloc,
        \\{"jsonrpc":"2.0","method":"activate_context","params":{"context":1}}
    );
    if (act.broadcast) |bc| alloc.free(bc.body);

    var list = try listContexts(&b, alloc);
    defer list.deinit();
    const r = list.value.result;
    try testz.expectEqual(r.current, 2);
    try testz.expectEqual(r.contexts.len, 3);
    try testz.expectEqual(r.contexts[0].context, 1);
    try testz.expectEqual(r.contexts[1].context, 2);
    try testz.expectEqual(r.contexts[2].context, glyphwire.root_context_handle);
    // Nobody named these.
    try testz.expectEqualStr(r.contexts[0].title, "");
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

// ─── Panes ──────────────────────────────────────────────────────────────

pub fn paneTreeOpsRequireTheWindowManagerRoleTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var root = try glyphwire.Context.init(alloc, 40, 10, 0);
    defer root.deinit();
    var session = try glyphwire.Session.init(alloc, &root);
    defer session.deinit();
    var d = try helpers.attachedConnection(&session, 7);

    // A program that merely runs inside a pane must not be able to reshape
    // the window around itself.
    try testz.expectError(d.handle(alloc,
        \\{"jsonrpc":"2.0","id":1,"method":"create_pane","params":{}}
    ), error.NotWindowManager);
    try testz.expectError(d.handle(alloc,
        \\{"jsonrpc":"2.0","method":"set_root_pane_split","params":{"split":null}}
    ), error.NotWindowManager);

    // Claim the role, and the same calls go through.
    const role = try d.handle(alloc,
        \\{"jsonrpc":"2.0","id":2,"method":"request_role","params":{"role":"window_manager"}}
    );
    defer if (role.response) |r| alloc.free(r);
    try testz.expectTrue(std.mem.indexOf(u8, role.response.?, "\"granted\":true") != null);

    const made = try d.handle(alloc,
        \\{"jsonrpc":"2.0","id":3,"method":"create_pane","params":{"scrollback_rows":0}}
    );
    defer if (made.response) |r| alloc.free(r);
    try testz.expectTrue(std.mem.indexOf(u8, made.response.?, "\"pane\":1") != null);
    // A pane-tree edit tells the caller to re-lay-out.
    try testz.expectTrue(made.panes_changed);
}

/// `set_overlay_pane` puts a pane over the whole window at once -- so a
/// `focus_pane` right behind it lands -- wins every hit test while raised,
/// keeps the window's size through a relayout, and moves focus off itself
/// when lowered. The root pane can't be raised, and destroying the raised
/// pane lowers it.
pub fn setOverlayPaneRaisesAPaneOverTheWindowTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var root = try glyphwire.Context.init(alloc, 40, 10, 0);
    defer root.deinit();
    var session = try glyphwire.Session.init(alloc, &root);
    defer session.deinit();
    var d = try helpers.attachedConnection(&session, 7);

    try testz.expectError(d.handle(alloc,
        \\{"jsonrpc":"2.0","method":"set_overlay_pane","params":{"pane":1}}
    ), error.NotWindowManager);
    try testz.expectTrue(session.claimManager(7, 0) != null);

    const made = try session.createPane(7, 0);
    try testz.expectFalse(session.panePtr(made.pane).?.mapped);
    try testz.expectError(d.handle(alloc,
        \\{"jsonrpc":"2.0","method":"set_overlay_pane","params":{"pane":0}}
    ), error.RootPaneImmutable);
    try testz.expectError(d.handle(alloc,
        \\{"jsonrpc":"2.0","method":"set_overlay_pane","params":{"pane":9}}
    ), error.UnknownPane);

    const raised = try d.handle(alloc,
        \\{"jsonrpc":"2.0","method":"set_overlay_pane","params":{"pane":1}}
    );
    try testz.expectTrue(raised.panes_changed);
    try testz.expectTrue(session.panePtr(made.pane).?.mapped);
    try session.focusPane(made.pane);
    try testz.expectEqual(session.paneAt(3, 3).?, made.pane);

    try session.layoutPanes(null, null);
    const r = session.panePtr(made.pane).?.rect;
    try testz.expectEqual(r.cols, 40);
    try testz.expectEqual(r.rows, 10);
    try testz.expectEqual(session.paneAt(3, 3).?, made.pane);

    _ = try d.handle(alloc,
        \\{"jsonrpc":"2.0","method":"set_overlay_pane","params":{"pane":null}}
    );
    try testz.expectFalse(session.panePtr(made.pane).?.mapped);
    try testz.expectEqual(session.focusedPaneHandle(), glyphwire.root_pane_handle);
    try testz.expectEqual(session.paneAt(3, 3).?, glyphwire.root_pane_handle);

    try session.setOverlayPane(made.pane);
    try session.destroyPane(made.pane);
    try testz.expectTrue(session.overlay_pane == null);
}

/// A pane-tree edit inside a `batch` still tells the caller to re-lay-out
/// (gmux's rotate sends all its slot swaps as one); without it, the
/// programs in the moved panes never got their `resize`.
pub fn batchedPaneEditReportsPanesChangedTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var root = try glyphwire.Context.init(alloc, 40, 10, 0);
    defer root.deinit();
    var session = try glyphwire.Session.init(alloc, &root);
    defer session.deinit();
    var d = try helpers.attachedConnection(&session, 7);

    const role = try d.handle(alloc,
        \\{"jsonrpc":"2.0","id":1,"method":"request_role","params":{"role":"window_manager"}}
    );
    defer if (role.response) |r| alloc.free(r);

    const quiet = try d.handle(alloc,
        \\{"jsonrpc":"2.0","method":"batch","params":{"messages":[]}}
    );
    try testz.expectTrue(!quiet.panes_changed);

    const notified = try d.handle(alloc,
        \\{"jsonrpc":"2.0","method":"batch","params":{"messages":[
        \\  {"jsonrpc":"2.0","method":"set_root_pane_split","params":{"split":null}}
        \\]}}
    );
    try testz.expectTrue(notified.panes_changed);

    const requested = try d.handle(alloc,
        \\{"jsonrpc":"2.0","id":2,"method":"batch","params":{"messages":[
        \\  {"jsonrpc":"2.0","method":"set_root_pane_split","params":{"split":null}}
        \\]}}
    );
    defer if (requested.response) |r| alloc.free(r);
    try testz.expectTrue(requested.panes_changed);
}

pub fn requestRoleIsRefusedWhenAnotherConnectionHoldsItTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var root = try glyphwire.Context.init(alloc, 40, 10, 0);
    defer root.deinit();
    var session = try glyphwire.Session.init(alloc, &root);
    defer session.deinit();

    var first = try helpers.attachedConnection(&session, 1);
    var second = try helpers.attachedConnection(&session, 2);

    const a = try first.handle(alloc,
        \\{"jsonrpc":"2.0","id":1,"method":"request_role","params":{"role":"window_manager"}}
    );
    defer if (a.response) |r| alloc.free(r);
    try testz.expectTrue(std.mem.indexOf(u8, a.response.?, "\"granted\":true") != null);

    // Answered, not thrown -- a second multiplexer gets to say so cleanly.
    const b = try second.handle(alloc,
        \\{"jsonrpc":"2.0","id":1,"method":"request_role","params":{"role":"window_manager"}}
    );
    defer if (b.response) |r| alloc.free(r);
    try testz.expectTrue(std.mem.indexOf(u8, b.response.?, "\"granted\":false") != null);
}

pub fn subscribeWithAContextBindsTheConnectionAtomicallyTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var root = try glyphwire.Context.init(alloc, 40, 10, 0);
    defer root.deinit();
    var session = try glyphwire.Session.init(alloc, &root);
    defer session.deinit();

    const made = try session.createPane(1, 0);

    // What a program spawned into a pane's listener sends: its context and
    // token ride inside `subscribe`, so there is no window in which it is
    // subscribed but still bound somewhere else.
    var d = dispatch.Dispatcher.initForConnection(&session, 9, null, null);
    try testz.expectEqual(d.active_pane, glyphwire.root_pane_handle);

    const token = session.contextToken(made.context).?;
    const msg = try std.fmt.allocPrint(alloc,
        \\{{"jsonrpc":"2.0","id":1,"method":"subscribe","params":{{"events":["key"],"context":{d},"token":"{s}"}}}}
    , .{ made.context, &token });
    defer alloc.free(msg);
    const resp = try d.handle(alloc, msg);
    defer if (resp.response) |r| alloc.free(r);

    try testz.expectEqual(d.active_pane, made.pane);
    try testz.expectEqual(d.active_ctx, made.context);
    try testz.expectEqual(d.ctx, session.contextPtr(made.context).?);
    try testz.expectTrue(d.subscriptions.has(.key));
}

pub fn subscribeWithAnUnknownPaneStillSubscribesTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var root = try glyphwire.Context.init(alloc, 40, 10, 0);
    defer root.deinit();
    var session = try glyphwire.Session.init(alloc, &root);
    defer session.deinit();
    // Binding by pane is the window manager's.
    var d = try helpers.managerConnection(&session, 9);

    // The pane was destroyed between the spawn and the connect. Leaving the
    // connection where it is beats refusing to subscribe at all.
    const resp = try d.handle(alloc,
        \\{"jsonrpc":"2.0","id":1,"method":"subscribe","params":{"events":["key"],"pane":99}}
    );
    defer if (resp.response) |r| alloc.free(r);
    try testz.expectTrue(d.subscriptions.has(.key));
    try testz.expectEqual(d.active_pane, glyphwire.root_pane_handle);
}

pub fn attachPaneIsTheWindowManagersTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var root = try glyphwire.Context.init(alloc, 40, 10, 0);
    defer root.deinit();
    var session = try glyphwire.Session.init(alloc, &root);
    defer session.deinit();
    const made = try session.createPane(1, 0);

    // Naming a pane is no proof of having been started in it.
    var program = try helpers.attachedConnection(&session, 9);
    try testz.expectError(program.handle(alloc,
        \\{"jsonrpc":"2.0","method":"attach_pane","params":{"pane":1}}
    ), dispatch.DispatchError.NotWindowManager);
    try testz.expectEqual(program.active_pane, glyphwire.root_pane_handle);

    // The manager may, and lands on what is on screen there.
    var manager = try helpers.managerConnection(&session, 4);
    _ = try manager.handle(alloc,
        \\{"jsonrpc":"2.0","method":"attach_pane","params":{"pane":1}}
    );
    try testz.expectEqual(manager.active_pane, made.pane);
    try testz.expectEqual(manager.active_ctx, made.context);
}

pub fn createContextLandsInTheConnectionsOwnPaneTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var root = try glyphwire.Context.init(alloc, 40, 10, 0);
    defer root.deinit();
    var session = try glyphwire.Session.init(alloc, &root);
    defer session.deinit();

    const made = try session.createPane(1, 0);
    var d = dispatch.Dispatcher.initForConnection(&session, 9, null, null);
    const attach = try attachContextMsg(alloc, made.context, &session.contextToken(made.context).?);
    defer alloc.free(attach);
    _ = try d.handle(alloc, attach);

    // A full-screen program in that pane opens its own context. It must
    // cover the pane, not the window.
    const created = try d.handle(alloc,
        \\{"jsonrpc":"2.0","id":1,"method":"create_context","params":{"scrollback_rows":0}}
    );
    defer if (created.response) |r| alloc.free(r);
    defer if (created.broadcast) |b| alloc.free(b.body);

    const ctx = session.contextPtr(d.active_ctx).?;
    try testz.expectEqual(ctx.pane, made.pane);
    try testz.expectEqual(session.panePtr(made.pane).?.top(), d.active_ctx);
    // The root pane, and focus, are untouched.
    try testz.expectEqual(session.rootPane().top(), glyphwire.root_context_handle);
    try testz.expectEqual(session.focusedContextHandle(), glyphwire.root_context_handle);
}

pub fn setWindowPrefixRequiresTheRoleAndRegistersTheChordTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var root = try glyphwire.Context.init(alloc, 40, 10, 0);
    defer root.deinit();
    var session = try glyphwire.Session.init(alloc, &root);
    defer session.deinit();
    var d = try helpers.attachedConnection(&session, 4);

    try testz.expectError(d.handle(alloc,
        \\{"jsonrpc":"2.0","method":"set_window_prefix","params":{"key":"b"}}
    ), error.NotWindowManager);

    try testz.expectTrue(session.claimManager(4, 0) != null);
    _ = try d.handle(alloc,
        \\{"jsonrpc":"2.0","method":"set_window_prefix","params":{"key":"a","ctrl":true}}
    );
    try testz.expectTrue(session.window_prefix != null);
    try testz.expectEqualStr(session.window_prefix.?.key(), "a");
    try testz.expectTrue(session.window_prefix.?.ctrl);

    // Clearing it re-arms nothing.
    session.prefix_armed = true;
    _ = try d.handle(alloc,
        \\{"jsonrpc":"2.0","method":"set_window_prefix","params":{"key":null}}
    );
    try testz.expectTrue(session.window_prefix == null);
    try testz.expectTrue(!session.prefix_armed);
}

const KeyNotif = struct {
    method: []const u8,
    params: struct { key: []const u8, mods: glyphwire.Mods = .{} },
};

/// `send_window_prefix` hands the chord the session holds to the focused
/// pane as a whole keystroke, with the chord's own modifiers, and leaves
/// the real keyboard's state alone.
pub fn sendWindowPrefixDeliversTheChordAsAKeystrokeTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var root = try glyphwire.Context.init(alloc, 40, 10, 0);
    defer root.deinit();
    var session = try glyphwire.Session.init(alloc, &root);
    defer session.deinit();
    var d = try helpers.attachedConnection(&session, 4);
    const send =
        \\{"jsonrpc":"2.0","method":"send_window_prefix"}
    ;

    try testz.expectError(d.handle(alloc, send), error.NotWindowManager);
    try testz.expectTrue(session.claimManager(4, 0) != null);

    // Nothing registered: nothing to send.
    const none = try d.handle(alloc, send);
    try testz.expectTrue(none.broadcast == null);
    try testz.expectTrue(none.broadcast_after == null);

    _ = try d.handle(alloc,
        \\{"jsonrpc":"2.0","method":"set_window_prefix","params":{"key":"b","ctrl":true}}
    );
    const res = try d.handle(alloc, send);
    const down = res.broadcast.?;
    defer alloc.free(down.body);
    const up = res.broadcast_after.?;
    defer alloc.free(up.body);
    try testz.expectEqual(down.event, .key);
    try testz.expectEqual(up.event, .key);

    const pd = try glyphwire.msgpack.decode(KeyNotif, alloc, down.body, .{});
    defer pd.deinit();
    try testz.expectEqualStr(pd.value.method, "key_down");
    try testz.expectEqualStr(pd.value.params.key, "b");
    try testz.expectTrue(pd.value.params.mods.ctrl);
    try testz.expectFalse(pd.value.params.mods.alt);
    const pu = try glyphwire.msgpack.decode(KeyNotif, alloc, up.body, .{});
    defer pu.deinit();
    try testz.expectEqualStr(pu.value.method, "key_up");
    try testz.expectEqualStr(pu.value.params.key, "b");

    // Synthetic: the prefix stays disarmed and nothing is held down.
    try testz.expectFalse(session.prefix_armed);
    try testz.expectFalse(session.mods.ctrl);
    try testz.expectEqual(session.swallowed_key_len, 0);
}

pub fn spawnInPaneWithoutASpawnerIsUnsupportedTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var root = try glyphwire.Context.init(alloc, 40, 10, 0);
    defer root.deinit();
    var session = try glyphwire.Session.init(alloc, &root);
    defer session.deinit();
    var d = try helpers.attachedConnection(&session, 4);
    try testz.expectTrue(session.claimManager(4, 0) != null);
    _ = try session.createPane(4, 0);

    // The headless server has no window to put a program in and no
    // business forking one.
    try testz.expectError(d.handle(alloc,
        \\{"jsonrpc":"2.0","id":1,"method":"spawn_in_pane","params":{"pane":1,"argv":["true"]}}
    ), error.SpawnUnsupported);
}

/// A `PaneSpawner` that forks nothing and records where it was asked to
/// start the child.
const FakeSpawner = struct {
    calls: usize = 0,
    path: [64]u8 = undefined,
    path_len: ?usize = null,
    from: ?glyphwire.PaneHandle = null,

    fn spawner(self: *FakeSpawner) dispatch.PaneSpawner {
        return .{ .ctx = self, .spawn_fn = spawnFn, .kill_fn = killFn };
    }

    fn spawnFn(
        ctx: ?*anyopaque,
        _: glyphwire.PaneHandle,
        _: glyphwire.ContextHandle,
        _: []const []const u8,
        _: usize,
        _: usize,
        cwd: dispatch.SpawnCwd,
    ) anyerror!i32 {
        const self: *FakeSpawner = @ptrCast(@alignCast(ctx.?));
        self.calls += 1;
        self.path_len = null;
        if (cwd.path) |p| {
            const n = @min(p.len, self.path.len);
            @memcpy(self.path[0..n], p[0..n]);
            self.path_len = n;
        }
        self.from = cwd.from;
        return 1234;
    }

    fn killFn(_: ?*anyopaque, _: glyphwire.PaneHandle) void {}
};

/// `spawn_in_pane`'s `cwd` and `cwd_from` reach the spawner as given,
/// and a request with neither leaves the directory to the host.
pub fn spawnInPanePassesTheStartDirectoryTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var root = try glyphwire.Context.init(alloc, 40, 10, 0);
    defer root.deinit();
    var session = try glyphwire.Session.init(alloc, &root);
    defer session.deinit();

    var fake: FakeSpawner = .{};
    const sp = fake.spawner();
    var d = try helpers.attachedConnection(&session, 4);
    d.spawner = &sp;
    try testz.expectTrue(session.claimManager(4, 0) != null);
    _ = try session.createPane(4, 0);
    _ = try session.createPane(4, 0);

    const plain = try d.handle(alloc,
        \\{"jsonrpc":"2.0","id":1,"method":"spawn_in_pane","params":{"pane":1,"argv":["true"]}}
    );
    if (plain.response) |r| alloc.free(r);
    try testz.expectEqual(fake.calls, 1);
    try testz.expectTrue(fake.path_len == null);
    try testz.expectTrue(fake.from == null);

    const placed = try d.handle(alloc,
        \\{"jsonrpc":"2.0","id":2,"method":"spawn_in_pane","params":{"pane":2,"argv":["true"],"cwd":"/srv/work","cwd_from":1}}
    );
    if (placed.response) |r| alloc.free(r);
    try testz.expectEqual(fake.calls, 2);
    try testz.expectEqualStr(fake.path[0..fake.path_len.?], "/srv/work");
    try testz.expectEqual(fake.from.?, 1);
}

// ─── start_remote / stop_remote ──────────────────────────────────────

/// A `RemoteStarter` that spawns nothing and just records what it was
/// asked for -- enough to check the wiring without an `ssh` anywhere.
const FakeRemotes = struct {
    started: usize = 0,
    stopped: ?u64 = null,
    stopped_pane: ?glyphwire.PaneHandle = null,
    last_dest: [64]u8 = undefined,
    last_dest_len: usize = 0,
    last_pane: glyphwire.PaneHandle = 0,
    last_ctx: glyphwire.ContextHandle = 0,
    last_ssh_args: usize = 0,
    last_remote_command_given: bool = false,
    fail: bool = false,

    fn starter(self: *FakeRemotes) dispatch.RemoteStarter {
        return .{
            .ctx = self,
            .start_fn = startFn,
            .stop_fn = stopFn,
            .stop_for_pane_fn = stopForPaneFn,
        };
    }

    fn dest(self: *const FakeRemotes) []const u8 {
        return self.last_dest[0..self.last_dest_len];
    }

    fn startFn(
        ctx: ?*anyopaque,
        d: []const u8,
        ssh_args: []const []const u8,
        remote_command: ?[]const u8,
        pane: glyphwire.PaneHandle,
        context: glyphwire.ContextHandle,
    ) anyerror!u64 {
        const self: *FakeRemotes = @ptrCast(@alignCast(ctx.?));
        if (self.fail) return error.RemoteStartFailed;
        self.started += 1;
        self.last_dest_len = @min(d.len, self.last_dest.len);
        @memcpy(self.last_dest[0..self.last_dest_len], d[0..self.last_dest_len]);
        self.last_ssh_args = ssh_args.len;
        self.last_remote_command_given = remote_command != null;
        self.last_pane = pane;
        self.last_ctx = context;
        return 42;
    }

    fn stopFn(ctx: ?*anyopaque, session: u64) void {
        const self: *FakeRemotes = @ptrCast(@alignCast(ctx.?));
        self.stopped = session;
    }

    fn stopForPaneFn(ctx: ?*anyopaque, pane: glyphwire.PaneHandle) void {
        const self: *FakeRemotes = @ptrCast(@alignCast(ctx.?));
        self.stopped_pane = pane;
    }
};

/// `start_remote` seats the session in the *caller's own* pane, with no
/// pane parameter to name someone else's and no manager role to claim.
pub fn startRemoteUsesTheCallersOwnPaneTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var root = try glyphwire.Context.init(alloc, 40, 10, 0);
    defer root.deinit();
    var session = try glyphwire.Session.init(alloc, &root);
    defer session.deinit();

    var fake: FakeRemotes = .{};
    const starter = fake.starter();

    // A second pane exists, and the shell connection is seated in it.
    try testz.expectTrue(session.claimManager(4, 0) != null);
    const made = try session.createPane(4, 0);
    const pane = made.pane;

    var shell = dispatch.Dispatcher.initForConnection(&session, 5, null, &starter);
    const attach = try attachContextMsg(alloc, made.context, &session.contextToken(made.context).?);
    defer alloc.free(attach);
    _ = try shell.handle(alloc, attach);

    const res = try shell.handle(alloc,
        \\{"jsonrpc":"2.0","id":1,"method":"start_remote","params":{"dest":"build-box"}}
    );
    defer if (res.response) |r| alloc.free(r);

    try testz.expectEqual(fake.started, 1);
    try testz.expectEqualStr("build-box", fake.dest());
    try testz.expectEqual(fake.last_pane, pane);
    try testz.expectTrue(!fake.last_remote_command_given);
    try testz.expectTrue(res.response != null);
    try testz.expectTrue(std.mem.indexOf(u8, res.response.?, "\"session\":42") != null);
}

pub fn startRemoteCarriesSshArgsAndRemoteCommandTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var root = try glyphwire.Context.init(alloc, 40, 10, 0);
    defer root.deinit();
    var session = try glyphwire.Session.init(alloc, &root);
    defer session.deinit();

    var fake: FakeRemotes = .{};
    const starter = fake.starter();
    var d = try helpers.attachedConnection(&session, 5);
    d.remote_starter = &starter;

    const res = try d.handle(alloc,
        \\{"jsonrpc":"2.0","id":1,"method":"start_remote","params":{"dest":"box","ssh_args":["-p","2222"],"remote_command":"/opt/gw-agent"}}
    );
    defer if (res.response) |r| alloc.free(r);

    try testz.expectEqual(fake.last_ssh_args, 2);
    try testz.expectTrue(fake.last_remote_command_given);
}

pub fn startRemoteWithAnEmptyDestFailsTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var root = try glyphwire.Context.init(alloc, 40, 10, 0);
    defer root.deinit();
    var session = try glyphwire.Session.init(alloc, &root);
    defer session.deinit();

    var fake: FakeRemotes = .{};
    const starter = fake.starter();
    var d = try helpers.attachedConnection(&session, 5);
    d.remote_starter = &starter;

    try testz.expectError(d.handle(alloc,
        \\{"jsonrpc":"2.0","id":1,"method":"start_remote","params":{"dest":""}}
    ), error.RemoteStartFailed);
    try testz.expectEqual(fake.started, 0);
}

/// The headless server has no window for a remote session to draw into
/// and no business spawning `ssh` -- same stance as `spawn_in_pane`.
pub fn startRemoteWithoutAStarterIsUnsupportedTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var root = try glyphwire.Context.init(alloc, 40, 10, 0);
    defer root.deinit();
    var session = try glyphwire.Session.init(alloc, &root);
    defer session.deinit();
    var d = try helpers.attachedConnection(&session, 5);

    try testz.expectError(d.handle(alloc,
        \\{"jsonrpc":"2.0","id":1,"method":"start_remote","params":{"dest":"box"}}
    ), error.RemoteUnsupported);
    try testz.expectError(d.handle(alloc,
        \\{"jsonrpc":"2.0","method":"stop_remote","params":{"session":1}}
    ), error.RemoteUnsupported);
}

pub fn stopRemoteNamesTheSessionTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var root = try glyphwire.Context.init(alloc, 40, 10, 0);
    defer root.deinit();
    var session = try glyphwire.Session.init(alloc, &root);
    defer session.deinit();

    var fake: FakeRemotes = .{};
    const starter = fake.starter();
    var d = try helpers.attachedConnection(&session, 5);
    d.remote_starter = &starter;

    _ = try d.handle(alloc,
        \\{"jsonrpc":"2.0","method":"stop_remote","params":{"session":7}}
    );
    try testz.expectEqual(fake.stopped.?, 7);
}

/// A remote session outlives the pane's own program, so destroying the
/// pane has to end the `ssh` too -- otherwise the trunk stays up feeding
/// clients with nowhere left to draw.
pub fn destroyPaneEndsItsRemoteSessionTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var root = try glyphwire.Context.init(alloc, 40, 10, 0);
    defer root.deinit();
    var session = try glyphwire.Session.init(alloc, &root);
    defer session.deinit();

    var fake: FakeRemotes = .{};
    const starter = fake.starter();
    var d = try helpers.attachedConnection(&session, 4);
    d.remote_starter = &starter;
    try testz.expectTrue(session.claimManager(4, 0) != null);
    const pane = (try session.createPane(4, 0)).pane;

    const destroy = try std.fmt.allocPrint(
        alloc,
        "{{\"jsonrpc\":\"2.0\",\"method\":\"destroy_pane\",\"params\":{{\"pane\":{d}}}}}",
        .{pane},
    );
    defer alloc.free(destroy);
    _ = try d.handle(alloc, destroy);
    try testz.expectEqual(fake.stopped_pane.?, pane);
}

pub fn paneSplitChildNamingBothTargetsIsRejectedTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var root = try glyphwire.Context.init(alloc, 40, 10, 0);
    defer root.deinit();
    var session = try glyphwire.Session.init(alloc, &root);
    defer session.deinit();
    var d = try helpers.attachedConnection(&session, 4);
    try testz.expectTrue(session.claimManager(4, 0) != null);

    const created = try d.handle(alloc,
        \\{"jsonrpc":"2.0","id":1,"method":"create_pane_split","params":{"axis":"row"}}
    );
    defer if (created.response) |r| alloc.free(r);

    try testz.expectError(d.handle(alloc,
        \\{"jsonrpc":"2.0","method":"set_pane_split_children","params":{"split":1,"children":[{"pane":0,"split":1}]}}
    ), error.InvalidPaneSplitChild);
    try testz.expectError(d.handle(alloc,
        \\{"jsonrpc":"2.0","method":"set_pane_split_children","params":{"split":1,"children":[{}]}}
    ), error.InvalidPaneSplitChild);
}

const PaneSplitResponse = struct { result: glyphwire.protocol.GetPaneSplitResult };

/// The window-manager path gmux takes: a pane swapped into a split's slot
/// keeps the slot's size, and `get_pane_split` reads it back.
pub fn replaceAndGetPaneSplitTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var root = try glyphwire.Context.init(alloc, 41, 10, 0);
    defer root.deinit();
    var session = try glyphwire.Session.init(alloc, &root);
    defer session.deinit();
    var d = try helpers.attachedConnection(&session, 4);
    try testz.expectTrue(session.claimManager(4, 0) != null);
    const a = (try session.createPane(4, 0)).pane;
    const b = (try session.createPane(4, 0)).pane;
    const split = try session.createPaneSplit(.row, true);
    try session.setPaneSplitChildren(split, &.{
        .{ .target = .{ .pane = glyphwire.root_pane_handle }, .size = .{ .weight = 3 } },
        .{ .target = .{ .pane = a }, .size = .{ .weight = 1 } },
    });
    try session.setRootPaneSplit(split);

    const replace = try std.fmt.allocPrint(
        alloc,
        "{{\"jsonrpc\":\"2.0\",\"method\":\"replace_pane_split_child\",\"params\":{{\"split\":{d},\"index\":1,\"child\":{{\"pane\":{d}}}}}}}",
        .{ split, b },
    );
    defer alloc.free(replace);
    _ = try d.handle(alloc, replace);
    try session.layoutPanes(null, null);

    const get = try std.fmt.allocPrint(
        alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"get_pane_split\",\"params\":{{\"split\":{d}}}}}",
        .{split},
    );
    defer alloc.free(get);
    const res = try d.handle(alloc, get);
    const body = res.response.?;
    defer alloc.free(body);
    const parsed = try std.json.parseFromSlice(PaneSplitResponse, alloc, body, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    const v = parsed.value.result;
    try testz.expectEqualStr(v.axis, "row");
    try testz.expectEqual(v.children.len, 2);
    try testz.expectEqual(v.children[1].pane.?, b);
    try testz.expectEqual(v.children[0].weight.?, 3);
    try testz.expectEqual(v.children[1].weight.?, 1);
    try testz.expectEqual(v.children[0].extent, 30);
    try testz.expectEqual(v.children[1].extent, 10);

    const past = try std.fmt.allocPrint(
        alloc,
        "{{\"jsonrpc\":\"2.0\",\"method\":\"replace_pane_split_child\",\"params\":{{\"split\":{d},\"index\":2,\"child\":{{\"pane\":{d}}}}}}}",
        .{ split, b },
    );
    defer alloc.free(past);
    try testz.expectError(d.handle(alloc, past), error.PaneSplitChildOutOfRange);
}

pub fn createPaneSplitRejectsABadAxisTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var root = try glyphwire.Context.init(alloc, 40, 10, 0);
    defer root.deinit();
    var session = try glyphwire.Session.init(alloc, &root);
    defer session.deinit();
    var d = try helpers.attachedConnection(&session, 4);
    try testz.expectTrue(session.claimManager(4, 0) != null);

    try testz.expectError(d.handle(alloc,
        \\{"jsonrpc":"2.0","id":1,"method":"create_pane_split","params":{"axis":"diagonal"}}
    ), error.InvalidSplitAxis);
}

// ── Image lifecycle over the wire ────────────────────────────────────

pub fn peekImagePayloadRecognizesUpdateImageTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    const message =
        \\{"jsonrpc":"2.0","id":9,"method":"update_image","params":{"handle":3,"format":"png","bytes":24}}
    ;
    const hdr = (try dispatch.peekImagePayload(alloc, message)).?;
    try testz.expectEqual(hdr.bytes, 24);
    try testz.expectEqual(hdr.id.integer, 9);
    try testz.expectEqual(hdr.format, .png);
    try testz.expectEqual(hdr.target.?, 3);
}

/// `load_image` allocates a handle, so it must not come back with a target
/// -- that's what tells the two apart in server.zig's side-channel branch.
pub fn peekImagePayloadLoadHasNoTargetTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    const message =
        \\{"jsonrpc":"2.0","id":7,"method":"load_image","params":{"format":"png","bytes":24}}
    ;
    const hdr = (try dispatch.peekImagePayload(alloc, message)).?;
    try testz.expectTrue(hdr.target == null);
}

pub fn peekImagePayloadUpdateWithoutHandleErrorsTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    const message =
        \\{"jsonrpc":"2.0","id":9,"method":"update_image","params":{"format":"png","bytes":24}}
    ;
    try testz.expectError(dispatch.peekImagePayload(alloc, message), dispatch.DispatchError.UnknownImage);
}

/// An update answers with the handle it was given, so a page reader's
/// refresh loop reads like its first load.
pub fn updateImageKeepsHandleAndRemeasuresTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 80, 24, 0);
    defer ctx.deinit();
    var d = dispatch.Dispatcher.init(&ctx);

    const first = fakePngBytes(64, 32);
    const load_resp = try d.handleLoadImage(alloc, .{ .id = .{ .integer = 1 }, .format = .png, .bytes = first.len }, &first);
    defer alloc.free(load_resp);
    try testz.expectTrue(std.mem.indexOf(u8, load_resp, "\"handle\":1") != null);

    const second = fakePngBytes(10, 20);
    const update_resp = try d.handleLoadImage(
        alloc,
        .{ .id = .{ .integer = 2 }, .format = .png, .bytes = second.len, .target = 1 },
        &second,
    );
    defer alloc.free(update_resp);
    try testz.expectTrue(std.mem.indexOf(u8, update_resp, "\"handle\":1") != null);

    const info = ctx.imageInfo(1).?;
    try testz.expectEqual(info.width, 10);
    try testz.expectEqual(info.height, 20);
}

pub fn destroyImageReleasesHandleTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 80, 24, 0);
    defer ctx.deinit();
    var d = dispatch.Dispatcher.init(&ctx);

    const png = fakePngBytes(64, 32);
    const load_resp = try d.handleLoadImage(alloc, .{ .id = .{ .integer = 1 }, .format = .png, .bytes = png.len }, &png);
    defer alloc.free(load_resp);
    try testz.expectTrue(ctx.imageInfo(1) != null);

    const message =
        \\{"jsonrpc":"2.0","method":"destroy_image","params":{"handle":1}}
    ;
    const result = try d.handle(alloc, message);
    defer if (result.response) |r| alloc.free(r);
    try testz.expectTrue(ctx.imageInfo(1) == null);
}

pub fn destroyImageUnknownHandleErrorsTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 80, 24, 0);
    defer ctx.deinit();
    var d = dispatch.Dispatcher.init(&ctx);

    const message =
        \\{"jsonrpc":"2.0","method":"destroy_image","params":{"handle":99}}
    ;
    try testz.expectError(d.handle(alloc, message), glyphwire.ImageResourceError.UnknownImage);
}

/// `destroy_image` carries no side-channel payload, so unlike
/// `load_image`/`update_image` it batches like any other notification --
/// which is what lets a client clear a region and release the image it
/// held in one frame.
pub fn destroyImageIsAllowedInBatchTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 80, 24, 0);
    defer ctx.deinit();
    var d = dispatch.Dispatcher.init(&ctx);

    const png = fakePngBytes(64, 32);
    const load_resp = try d.handleLoadImage(alloc, .{ .id = .{ .integer = 1 }, .format = .png, .bytes = png.len }, &png);
    defer alloc.free(load_resp);

    const message =
        \\{"jsonrpc":"2.0","method":"batch","params":{"messages":[
        \\{"method":"clear","params":{}},
        \\{"method":"destroy_image","params":{"handle":1}}]}}
    ;
    const result = try d.handle(alloc, message);
    defer if (result.response) |r| alloc.free(r);
    try testz.expectTrue(ctx.imageInfo(1) == null);
}

pub fn opacityPropertyRoundTripsOverTheWireTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 80, 24, 0);
    defer ctx.deinit();
    var d = dispatch.Dispatcher.init(&ctx);
    const panel = try ctx.createLayer(20, 5, 0);

    try notifyThrough(alloc, &d,
        \\{"jsonrpc":"2.0","method":"set_property","params":{"layer":1,"property":"opacity","value":0.5}}
    );
    try testz.expectTrue(ctx.layerPtr(panel).?.opacity == 0.5);

    const get_msg =
        \\{"jsonrpc":"2.0","id":9,"method":"get_property","params":{"layer":1,"property":"opacity"}}
    ;
    const get_decoded = try roundTripThroughWire(alloc, get_msg);
    defer alloc.free(get_decoded);
    const response_body = (try d.handle(alloc, get_decoded)).response.?;
    defer alloc.free(response_body);

    const Response = struct { id: i64, result: struct { value: f32 } };
    const parsed = try std.json.parseFromSlice(Response, alloc, response_body, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();
    try testz.expectEqual(parsed.value.id, 9);
    try testz.expectTrue(parsed.value.result.value == 0.5);
}

pub fn opacityWithNoValueFieldLeavesTheLayerOpaqueTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 80, 24, 0);
    defer ctx.deinit();
    var d = dispatch.Dispatcher.init(&ctx);
    const panel = try ctx.createLayer(20, 5, 0);

    // `value` defaults to 1.0 rather than 0: naming the property and
    // forgetting the field should not make the layer disappear.
    try notifyThrough(alloc, &d,
        \\{"jsonrpc":"2.0","method":"set_property","params":{"layer":1,"property":"opacity"}}
    );
    try testz.expectTrue(ctx.layerPtr(panel).?.opacity == 1.0);
}

/// `write_text`'s `underline` / `underline_color`, per message and per span,
/// and the `get_cells` fields that read them back. Spans inherit each of the
/// two independently, so one message can mark several ranges in one colour.
pub fn writeTextUnderlineSpansAndReadbackTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 12, 2, 0);
    defer ctx.deinit();
    var d = dispatch.Dispatcher.init(&ctx);

    try notifyThrough(alloc, &d,
        \\{"jsonrpc":"2.0","method":"write_text","params":{"underline_color":{"r":255,"g":0,"b":0},"spans":[{"text":"ok"},{"text":"bad","underline":"curly"},{"text":"x","underline":"single","underline_color":{"r":0,"g":0,"b":255}}]}}
    );

    const get_cells_msg =
        \\{"jsonrpc":"2.0","id":1,"method":"get_cells","params":{}}
    ;
    const response_body = (try d.handle(alloc, get_cells_msg)).response.?;
    defer alloc.free(response_body);

    const CellJson = struct {
        g: []const u8,
        underline: ?[]const u8 = null,
        underline_color: ?struct { r: u8, g: u8, b: u8, a: u8 } = null,
    };
    const Response = struct {
        id: i64,
        result: struct { cells: []CellJson },
    };
    const parsed = try std.json.parseFromSlice(Response, alloc, response_body, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();
    const cells = parsed.value.result.cells;

    // A span that named no style is unmarked, even though the message
    // carried a colour -- a colour alone underlines nothing.
    try testz.expectEqual(cells[0].underline, null);
    // The `curly` span inherits the message's red.
    try testz.expectEqualStr("curly", cells[2].underline.?);
    try testz.expectEqual(cells[2].underline_color.?.r, 255);
    try testz.expectEqualStr("curly", cells[4].underline.?);
    // ...and a span that names its own colour keeps it.
    try testz.expectEqualStr("single", cells[5].underline.?);
    try testz.expectEqual(cells[5].underline_color.?.b, 255);
}

/// An unknown `underline` name is a parse error, the same treatment
/// `scale` gets -- silently drawing no underline would hide the typo.
pub fn writeTextRejectsUnknownUnderlineNameTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 12, 2, 0);
    defer ctx.deinit();
    var d = dispatch.Dispatcher.init(&ctx);

    const msg =
        \\{"jsonrpc":"2.0","method":"write_text","params":{"text":"hi","underline":"squiggly"}}
    ;
    try testz.expectError(d.handle(alloc, msg), dispatch.DispatchError.InvalidUnderline);
}

/// Frees a `HandleResult`'s response and any broadcast body.
fn freeResult(alloc: std.mem.Allocator, r: dispatch.HandleResult) void {
    if (r.response) |b| alloc.free(b);
    if (r.broadcast) |b| alloc.free(b.body);
}

const ActivateResponse = struct {
    result: struct { action: []const u8, offset: usize = 0, row: ?usize = null },
};

fn activateAt(d: *dispatch.Dispatcher, alloc: std.mem.Allocator, row: usize, col: usize, view_offset: usize) !std.json.Parsed(ActivateResponse) {
    const msg = try std.fmt.allocPrint(alloc,
        \\{{"jsonrpc":"2.0","id":9,"method":"activate_at","params":{{"row":{d},"col":{d},"view_offset":{d}}}}}
    , .{ row, col, view_offset });
    defer alloc.free(msg);
    const r = try d.handle(alloc, msg);
    defer freeResult(alloc, r);
    return std.json.parseFromSlice(ActivateResponse, alloc, r.response.?, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
}

/// `activate_at` on a sortable header cycles that column's sort, the
/// keyboard twin of glyphwire-host's header click. A header that isn't
/// sortable, or a body cell, is `"none"` so the shell falls back to the
/// cell's open action.
pub fn activateAtSortsASortableHeaderTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 20, 6, 0);
    defer ctx.deinit();
    var d = dispatch.Dispatcher.init(&ctx);

    freeResult(alloc, try d.handle(alloc,
        \\{"jsonrpc":"2.0","id":1,"method":"create_table","params":{"row":0,"col":0,"columns":[{"name":"Name","width":4},{"name":"Num","width":4,"sortable":true}],"style":{"borders":false,"header_separator":false}}}
    ));
    const handle = ctx.root.table_order.items[0];
    const set_rows = try std.fmt.allocPrint(alloc,
        \\{{"jsonrpc":"2.0","method":"table_set_rows","params":{{"table":{d},"rows":[[{{"display":"c"}},{{"display":"3"}}],[{{"display":"a"}},{{"display":"1"}}]]}}}}
    , .{handle});
    defer alloc.free(set_rows);
    freeResult(alloc, try d.handle(alloc, set_rows));
    const table = ctx.root.tables.getPtr(handle).?;

    // "Num" header starts at column 5 (4 wide + 1 gap).
    {
        const got = try activateAt(&d, alloc, 0, 5, 0);
        defer got.deinit();
        try testz.expectEqualStr("sorted", got.value.result.action);
    }
    try testz.expectEqual(table.sort_column.?, 1);
    try testz.expectTrue(table.sort_dir == .ascending);
    try testz.expectEqualStr("a", ctx.root.cell(1, 0).grapheme());

    // "Name" isn't sortable, and a body row isn't a header.
    {
        const got = try activateAt(&d, alloc, 0, 0, 0);
        defer got.deinit();
        try testz.expectEqualStr("none", got.value.result.action);
    }
    {
        const got = try activateAt(&d, alloc, 1, 5, 0);
        defer got.deinit();
        try testz.expectEqualStr("none", got.value.result.action);
    }
    try testz.expectTrue(table.sort_dir == .ascending);
}

/// `activate_at` on an outline: an untagged collapsible row (a gw-grep
/// file row) toggles from anywhere on it; a tagged row toggles only from
/// its marker and is otherwise `"none"`, leaving Enter to open it. The
/// response's `offset`/`row` point at wherever the toggled node landed.
pub fn activateAtTogglesOutlineNodesTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 20, 6, 20);
    defer ctx.deinit();
    var d = dispatch.Dispatcher.init(&ctx);

    freeResult(alloc, try d.handle(alloc,
        \\{"jsonrpc":"2.0","id":1,"method":"create_metadata","params":{"json":"{\"kind\":\"file\",\"path\":\"/a\"}"}}
    ));
    freeResult(alloc, try d.handle(alloc,
        \\{"jsonrpc":"2.0","id":2,"method":"create_outline","params":{"row":0,"col":0}}
    ));
    const handle = ctx.root.outline_order.items[0];
    const set_nodes = try std.fmt.allocPrint(alloc,
        \\{{"jsonrpc":"2.0","method":"outline_set_nodes","params":{{"outline":{d},"nodes":[
        \\{{"depth":0,"runs":[{{"text":"file"}}],"collapsible":true}},
        \\{{"depth":1,"runs":[{{"text":"hit"}}],"metadata_id":1,"collapsible":true,"collapsed":true}},
        \\{{"depth":2,"runs":[{{"text":"ctx"}}],"metadata_id":1}}]}}}}
    , .{handle});
    defer alloc.free(set_nodes);
    freeResult(alloc, try d.handle(alloc, set_nodes));
    const outline = ctx.root.outlines.getPtr(handle).?;

    // Hit row text (tagged, off the marker): left for the open action.
    {
        const got = try activateAt(&d, alloc, 1, 5, 0);
        defer got.deinit();
        try testz.expectEqualStr("none", got.value.result.action);
    }
    try testz.expectTrue(outline.nodes[1].collapsed);

    // Hit row marker (depth 1 -> columns 2-3): expands it.
    {
        const got = try activateAt(&d, alloc, 1, 2, 0);
        defer got.deinit();
        try testz.expectEqualStr("toggled", got.value.result.action);
        try testz.expectTrue(!outline.nodes[1].collapsed);
        // Wherever the reflow put it, the reported cell shows the hit.
        const row = got.value.result.row.?;
        try testz.expectEqualStr("h", ctx.root.viewRow(got.value.result.offset, row)[4].grapheme());
    }

    // File row text (untagged): Enter anywhere on it collapses the file.
    // The expansion grew upward and pushed the file row into scrollback,
    // so look at it scrolled back far enough to put it on screen row 0.
    try testz.expectTrue(outline.top_live < 0);
    const back: usize = @intCast(-outline.top_live);
    {
        const got = try activateAt(&d, alloc, 0, 3, back);
        defer got.deinit();
        try testz.expectEqualStr("toggled", got.value.result.action);
    }
    try testz.expectTrue(outline.nodes[0].collapsed);
    try testz.expectEqual(outline.visibleRows(), 1);
}

// ─── MessagePack connections ─────────────────────────────────────────────
//
// The same messages as the JSON tests above, encoded as a MessagePack
// client encodes them (`codec.request` / `codec.notification` from typed
// params), through a `Dispatcher` whose connection speaks MessagePack.

pub fn msgpackWriteTextUpdatesCoreStateTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 80, 24, 0);
    defer ctx.deinit();
    var d = dispatch.Dispatcher.init(&ctx);
    d.format = .msgpack;

    const body = try glyphwire.codec.notification(.msgpack, alloc, "write_text", glyphwire.protocol.WriteTextParams{
        .text = "hello",
        .fg = .{ .r = 255, .g = 0, .b = 0 },
    }, .{ .omit_nulls = true });
    defer alloc.free(body);
    const result = try d.handle(alloc, body);
    try testz.expectTrue(result.response == null);

    try testz.expectEqualStr("h", ctx.root.cell(0, 0).grapheme());
    try testz.expectEqualStr("o", ctx.root.cell(0, 4).grapheme());
    try testz.expectEqual(ctx.root.cell(0, 0).style.fg.r, 255);
    try testz.expectEqual(ctx.root.cursor.col, 5);
}

pub fn msgpackRequestIsAnsweredInMsgpackTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 20, 5, 0);
    defer ctx.deinit();
    var d = dispatch.Dispatcher.init(&ctx);
    d.format = .msgpack;

    const body = try glyphwire.codec.request(.msgpack, alloc, 11, "get_property", .{
        .property = @as([]const u8, "cursor"),
    }, .{});
    defer alloc.free(body);
    const result = try d.handle(alloc, body);
    const resp = result.response.?;
    defer alloc.free(resp);

    const parsed = try glyphwire.msgpack.decode(glyphwire.codec.Result(struct { row: usize, col: usize }), alloc, resp, .{});
    defer parsed.deinit();
    try testz.expectEqual(parsed.value.id, 11);
    try testz.expectEqual(parsed.value.result.col, 0);
}

pub fn msgpackBatchRequestFormCorrelatesResponsesTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 20, 5, 0);
    defer ctx.deinit();
    var d = dispatch.Dispatcher.init(&ctx);
    d.format = .msgpack;

    // Each sub-message is its own encoded envelope, spliced in whole.
    const codec = glyphwire.codec;
    const subs = [_][]u8{
        try codec.request(.msgpack, alloc, 1, "create_metadata", .{ .json = @as([]const u8, "{\"a\":1}") }, .{}),
        try codec.notification(.msgpack, alloc, "write_text", .{ .text = @as([]const u8, "hi") }, .{}),
        try codec.notification(.msgpack, alloc, "bogus_method", struct {}{}, .{}),
        try codec.request(.msgpack, alloc, 2, "get_property", .{ .property = @as([]const u8, "cursor") }, .{}),
    };
    defer for (subs) |sub| alloc.free(sub);
    var raws: [subs.len]glyphwire.msgpack.Raw = undefined;
    for (subs, &raws) |sub, *r| r.* = .{ .bytes = sub };
    const body = try codec.request(.msgpack, alloc, 7, "batch", .{ .messages = @as([]const glyphwire.msgpack.Raw, &raws) }, .{});
    defer alloc.free(body);
    const result = try d.handle(alloc, body);
    const resp = result.response.?;
    defer alloc.free(resp);

    const Sub = struct { id: i64, result: glyphwire.msgpack.Raw };
    const T = struct { id: i64, result: struct { responses: []const Sub } };
    const parsed = try glyphwire.msgpack.decode(T, alloc, resp, .{});
    defer parsed.deinit();
    try testz.expectEqual(parsed.value.id, 7);
    const responses = parsed.value.result.responses;
    try testz.expectEqual(responses.len, 2);
    try testz.expectEqual(responses[0].id, 1);
    try testz.expectEqual(responses[1].id, 2);

    // The unknown method was skipped, and the write ahead of it applied.
    const cursor = try glyphwire.msgpack.decodeLeaky(struct { col: usize }, parsed.arena.allocator(), responses[1].result.bytes, .{});
    try testz.expectEqual(cursor.col, 2);
}

pub fn msgpackLoadImageCarriesBytesInlineTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 20, 5, 0);
    defer ctx.deinit();
    var d = dispatch.Dispatcher.init(&ctx);
    d.format = .msgpack;

    const png = fakePngBytes(32, 16);
    const body = try glyphwire.codec.request(.msgpack, alloc, 3, "load_image", .{
        .format = @as([]const u8, "png"),
        .data = glyphwire.msgpack.Bin{ .bytes = &png },
    }, .{});
    defer alloc.free(body);

    const env = try glyphwire.codec.parseEnvelope(.msgpack, alloc, body);
    defer env.deinit();
    const hdr = (try dispatch.imagePayloadHeader(alloc, env.value)).?;
    try testz.expectEqual(hdr.bytes, png.len);
    try testz.expectTrue(std.mem.eql(u8, hdr.data.?, &png));

    const resp = try d.handleLoadImage(alloc, hdr, hdr.data.?);
    defer alloc.free(resp);
    const parsed = try glyphwire.codec.parseResult(struct { handle: glyphwire.ImageHandle }, .msgpack, alloc, resp);
    defer parsed.deinit();
    const info = ctx.imageInfo(parsed.value.result.handle).?;
    try testz.expectEqual(info.width, 32);
    try testz.expectEqual(info.height, 16);
}

pub fn msgpackLoadImageWithoutDataIsRefusedTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    const body = try glyphwire.codec.request(.msgpack, alloc, 3, "load_image", .{
        .format = @as([]const u8, "png"),
        .bytes = @as(usize, 24),
    }, .{});
    defer alloc.free(body);
    const env = try glyphwire.codec.parseEnvelope(.msgpack, alloc, body);
    defer env.deinit();
    try testz.expectError(dispatch.imagePayloadHeader(alloc, env.value), dispatch.DispatchError.MissingImageData);
}

pub fn replaceSplitChildKeepsTheSlotsSizeOverTheWireTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 100, 40, 0);
    defer ctx.deinit();
    var d = dispatch.Dispatcher.init(&ctx);
    _ = try ctx.createLayer(10, 10, 0);
    _ = try ctx.createLayer(10, 10, 0);
    const third = try ctx.createLayer(10, 10, 0);
    _ = try ctx.createSplit(.row);

    try notifyThrough(alloc, &d,
        \\{"jsonrpc":"2.0","method":"set_split_children","params":{"split":1,"children":[{"layer":1,"weight":3},{"layer":2,"fixed":20}]}}
    );
    try notifyThrough(alloc, &d,
        \\{"jsonrpc":"2.0","method":"replace_split_child","params":{"split":1,"index":0,"child":{"layer":3}}}
    );
    const children = ctx.split_tree.node(1).?.children.items;
    try testz.expectEqual(children[0].target.layer, third);
    try testz.expectEqual(children[0].size.weight, 3);
    try testz.expectEqual(children[1].size.fixed, 20);

    try testz.expectError(d.handle(alloc,
        \\{"jsonrpc":"2.0","method":"replace_split_child","params":{"split":1,"index":2,"child":{"layer":3}}}
    ), error.SplitChildOutOfRange);
    try testz.expectError(d.handle(alloc,
        \\{"jsonrpc":"2.0","method":"replace_split_child","params":{"split":1,"index":0,"child":{"layer":3,"split":1}}}
    ), error.InvalidSplitChild);
}

const SplitResponse = struct { result: glyphwire.protocol.GetSplitResult };

/// `get_split` hands back the weights a drag left, not the ones the
/// client sent, plus what each child measured at the last layout.
pub fn getSplitReportsDraggedWeightsAndExtentsTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 100, 40, 0);
    defer ctx.deinit();
    var d = dispatch.Dispatcher.init(&ctx);
    _ = try ctx.createLayer(10, 10, 0);
    _ = try ctx.createLayer(10, 10, 0);
    _ = try ctx.createSplit(.row);
    try notifyThrough(alloc, &d,
        \\{"jsonrpc":"2.0","method":"set_split_children","params":{"split":1,"children":[{"layer":1},{"layer":2}]}}
    );
    try notifyThrough(alloc, &d,
        \\{"jsonrpc":"2.0","method":"set_root_split","params":{"split":1}}
    );
    try notifyThrough(alloc, &d,
        \\{"jsonrpc":"2.0","method":"move_divider","params":{"split":1,"index":0,"delta":20}}
    );

    const res = try d.handle(alloc,
        \\{"jsonrpc":"2.0","id":5,"method":"get_split","params":{"split":1}}
    );
    const body = res.response.?;
    defer alloc.free(body);
    const parsed = try std.json.parseFromSlice(SplitResponse, alloc, body, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    const v = parsed.value.result;
    try testz.expectEqualStr(v.axis, "row");
    try testz.expectTrue(v.resizable);
    try testz.expectEqual(v.children.len, 2);
    try testz.expectEqual(v.children[0].layer.?, 1);
    try testz.expectEqual(v.children[1].layer.?, 2);
    try testz.expectEqual(v.children[0].extent, 69);
    try testz.expectEqual(v.children[1].extent, 30);
    // A drag keeps the pair's combined weight and re-splits it.
    const wa = v.children[0].weight.?;
    const wb = v.children[1].weight.?;
    try testz.expectTrue(@abs(wa + wb - 2) < 0.001);
    try testz.expectTrue(wa > wb);

    try testz.expectError(d.handle(alloc,
        \\{"jsonrpc":"2.0","id":6,"method":"get_split","params":{"split":9}}
    ), error.UnknownSplit);
}

// ─── get_version ────────────────────────────────────────────────────────

const VersionResponse = struct { result: glyphwire.protocol.VersionResult };

/// Runs `get_version` on `d` and returns the parsed result.
fn getVersion(d: *dispatch.Dispatcher, alloc: std.mem.Allocator) !std.json.Parsed(VersionResponse) {
    const res = try d.handle(alloc,
        \\{"jsonrpc":"2.0","id":3,"method":"get_version"}
    );
    const body = res.response.?;
    defer alloc.free(body);
    return std.json.parseFromSlice(VersionResponse, alloc, body, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
}

pub fn getVersionReportsTheSessionsHostTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var root = try glyphwire.Context.init(alloc, 40, 10, 0);
    defer root.deinit();
    var session = try glyphwire.Session.init(alloc, &root);
    defer session.deinit();
    session.host_info = .{ .program = "glyphwire", .version = "1.2.3", .suite_version = "0.9.0", .git = "abc1234-dirty" };

    var d = try helpers.attachedConnection(&session, 1);
    var got = try getVersion(&d, alloc);
    defer got.deinit();
    const v = got.value.result;
    try testz.expectEqualStr(v.program, "glyphwire");
    try testz.expectEqualStr(v.version, "1.2.3");
    try testz.expectEqualStr(v.suite_version, "0.9.0");
    try testz.expectEqualStr(v.git, "abc1234-dirty");
    try testz.expectEqualStr(v.protocol, glyphwire.protocol.protocol_version);
}

pub fn getVersionWithoutASessionStillGivesTheProtocolTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 10, 5, 0);
    defer ctx.deinit();
    var d = dispatch.Dispatcher.init(&ctx);
    var got = try getVersion(&d, alloc);
    defer got.deinit();
    try testz.expectEqualStr(got.value.result.program, "");
    try testz.expectEqualStr(got.value.result.protocol, glyphwire.protocol.protocol_version);
}

pub fn versionLineAndFlagTest(_: std.Io, _: std.mem.Allocator) !void {
    const info: glyphwire.version.Info = .{ .program = "zoe", .version = "0.8.1", .suite_version = "0.8.0", .git = "v0.8.0-3-g1e34abf" };
    var buf: [128]u8 = undefined;
    try testz.expectEqualStr(info.line(&buf), "zoe 0.8.1 (glyphwire 0.8.0, v0.8.0-3-g1e34abf)");
    try testz.expectTrue(glyphwire.version.isFlag("--version"));
    try testz.expectTrue(glyphwire.version.isFlag("-V"));
    try testz.expectFalse(glyphwire.version.isFlag("-v"));
    try testz.expectFalse(glyphwire.version.isFlag("version"));
}

pub fn listContextsFlagsEveryShellsContextTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var root = try glyphwire.Context.init(alloc, 40, 10, 0);
    defer root.deinit();
    var session = try glyphwire.Session.init(alloc, &root);
    defer session.deinit();

    // A program's own screen, from a shell on the base context.
    var program = try helpers.attachedConnection(&session, 7);
    const created = try program.handle(alloc,
        \\{"jsonrpc":"2.0","id":1,"method":"create_context","params":{}}
    );
    if (created.response) |r| alloc.free(r);
    if (created.broadcast) |b| alloc.free(b.body);

    // A shell the host's context switcher spawned, on top of both.
    const spawned = try session.createContext(glyphwire.root_pane_handle, null, null, 0);
    session.contextPtr(spawned).?.spawned_shell = true;

    var list = try listContexts(&program, alloc);
    defer list.deinit();
    const r = list.value.result;
    try testz.expectEqual(r.contexts.len, 3);
    try testz.expectEqual(r.contexts[0].context, spawned);
    try testz.expectTrue(r.contexts[0].shell);
    try testz.expectEqual(r.contexts[1].context, 1);
    try testz.expectFalse(r.contexts[1].shell);
    // The pane's base is a shell's too, flagged or not.
    try testz.expectEqual(r.contexts[2].context, glyphwire.root_context_handle);
    try testz.expectTrue(r.contexts[2].shell);
}

// ── Context access ──────────────────────────────────────────────────────

/// `{"method":"attach_context","params":{"context":<context>,"token":"<token>"}}`,
/// owned by the caller.
fn attachContextMsg(alloc: std.mem.Allocator, context: glyphwire.ContextHandle, token: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc,
        \\{{"jsonrpc":"2.0","method":"attach_context","params":{{"context":{d},"token":"{s}"}}}}
    , .{ context, token });
}

pub fn aFreshConnectionMayNotTouchAnythingTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var root = try glyphwire.Context.init(alloc, 40, 10, 0);
    defer root.deinit();
    var session = try glyphwire.Session.init(alloc, &root);
    defer session.deinit();
    var d = dispatch.Dispatcher.initForConnection(&session, 7, null, null);
    try testz.expectFalse(d.attached());

    // Neither draw on nor read the context that happens to be on screen.
    try testz.expectError(d.handle(alloc,
        \\{"jsonrpc":"2.0","method":"write_text","params":{"text":"hi"}}
    ), dispatch.DispatchError.ContextAccessDenied);
    try testz.expectError(d.handle(alloc,
        \\{"jsonrpc":"2.0","id":1,"method":"get_cells","params":{}}
    ), dispatch.DispatchError.ContextAccessDenied);
    try testz.expectEqual(root.root.revision, 0);

    // What touches no context still works.
    const v = try d.handle(alloc,
        \\{"jsonrpc":"2.0","id":2,"method":"get_version","params":{}}
    );
    defer if (v.response) |r| alloc.free(r);
    try testz.expectTrue(v.response != null);
}

pub fn attachContextNeedsTheRightTokenTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var root = try glyphwire.Context.init(alloc, 40, 10, 0);
    defer root.deinit();
    var session = try glyphwire.Session.init(alloc, &root);
    defer session.deinit();
    var d = dispatch.Dispatcher.initForConnection(&session, 7, null, null);

    try testz.expectError(d.handle(alloc,
        \\{"jsonrpc":"2.0","method":"attach_context","params":{"context":0}}
    ), dispatch.DispatchError.ContextAccessDenied);

    const wrong = try attachContextMsg(alloc, 0, "00000000000000000000000000000000");
    defer alloc.free(wrong);
    try testz.expectError(d.handle(alloc, wrong), dispatch.DispatchError.ContextAccessDenied);
    try testz.expectFalse(d.attached());

    const right = try attachContextMsg(alloc, 0, &root.token);
    defer alloc.free(right);
    _ = try d.handle(alloc, right);
    try testz.expectTrue(d.attached());
    _ = try d.handle(alloc,
        \\{"jsonrpc":"2.0","method":"write_text","params":{"text":"hi"}}
    );
    try testz.expectTrue(root.root.revision > 0);
}

pub fn createContextHandsBackATokenAnotherConnectionCanUseTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var root = try glyphwire.Context.init(alloc, 40, 10, 0);
    defer root.deinit();
    var session = try glyphwire.Session.init(alloc, &root);
    defer session.deinit();

    // A connection with no access at all may still make a context of its
    // own, and is attached to it.
    var maker = dispatch.Dispatcher.initForConnection(&session, 1, null, null);
    const created = try maker.handle(alloc,
        \\{"jsonrpc":"2.0","id":1,"method":"create_context","params":{}}
    );
    defer if (created.response) |r| alloc.free(r);
    defer if (created.broadcast) |b| alloc.free(b.body);
    try testz.expectTrue(maker.attached());

    const Resp = struct { result: glyphwire.protocol.CreateContextResult };
    const parsed = try std.json.parseFromSlice(Resp, alloc, created.response.?, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    const made = parsed.value.result;
    try testz.expectEqual(made.token.len, @sizeOf(glyphwire.AccessToken));
    try testz.expectEqualStr(made.token, &session.contextToken(made.context).?);

    // Its listener joins with that token, and only that one.
    var listener = dispatch.Dispatcher.initForConnection(&session, 2, null, null);
    try testz.expectError(listener.handle(alloc,
        \\{"jsonrpc":"2.0","method":"attach_context","params":{"context":1}}
    ), dispatch.DispatchError.ContextAccessDenied);
    const join = try attachContextMsg(alloc, made.context, made.token);
    defer alloc.free(join);
    _ = try listener.handle(alloc, join);
    try testz.expectEqual(listener.active_ctx, made.context);
    try testz.expectTrue(listener.attached());

    // Access is not ownership: the listener still may not destroy it.
    try testz.expectError(listener.handle(alloc,
        \\{"jsonrpc":"2.0","method":"destroy_context","params":{"context":1}}
    ), dispatch.DispatchError.ContextPermissionDenied);
}

pub fn subscribeWithAWrongTokenIsRefusedTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var root = try glyphwire.Context.init(alloc, 40, 10, 0);
    defer root.deinit();
    var session = try glyphwire.Session.init(alloc, &root);
    defer session.deinit();
    var d = dispatch.Dispatcher.initForConnection(&session, 7, null, null);

    try testz.expectError(d.handle(alloc,
        \\{"jsonrpc":"2.0","id":1,"method":"subscribe","params":{"events":["key"],"context":0,"token":"nope"}}
    ), dispatch.DispatchError.ContextAccessDenied);
    // Refused before it armed anything.
    try testz.expectFalse(d.subscriptions.has(.key));
}

pub fn synthesizedInputNeedsTheWindowManagerRoleTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var root = try glyphwire.Context.init(alloc, 40, 10, 0);
    defer root.deinit();
    var session = try glyphwire.Session.init(alloc, &root);
    defer session.deinit();
    var d = try helpers.attachedConnection(&session, 7);

    // Attached is not enough: typing into whatever has focus is the
    // window manager's business.
    try testz.expectError(d.handle(alloc,
        \\{"jsonrpc":"2.0","method":"report_key","params":{"key":"a","pressed":true}}
    ), dispatch.DispatchError.NotWindowManager);
    try testz.expectError(d.handle(alloc,
        \\{"jsonrpc":"2.0","method":"report_text","params":{"text":"rm -rf ~\n"}}
    ), dispatch.DispatchError.NotWindowManager);

    // The in-process host is the window, and needs no role.
    var host = dispatch.Dispatcher.init(&root);
    const r = try host.handle(alloc,
        \\{"jsonrpc":"2.0","method":"report_key","params":{"key":"a","pressed":true}}
    );
    if (r.broadcast) |b| alloc.free(b.body);
}

pub fn adoptContextNeedsAccessFirstTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var root = try glyphwire.Context.init(alloc, 40, 10, 0);
    defer root.deinit();
    var session = try glyphwire.Session.init(alloc, &root);
    defer session.deinit();
    const other = try session.createContext(glyphwire.root_pane_handle, null, null, 0);
    try session.addContextOwner(other, 1);

    var d = dispatch.Dispatcher.initForConnection(&session, 7, null, null);
    try session.addContextMember(glyphwire.root_context_handle, 7);
    try testz.expectError(d.handle(alloc,
        \\{"jsonrpc":"2.0","method":"adopt_context","params":{"context":1}}
    ), dispatch.DispatchError.ContextAccessDenied);
    try testz.expectFalse(session.contextHasOwner(other, 7));
}

pub fn activateContextRaisesOnlyWithinTheCallersPaneTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var root = try glyphwire.Context.init(alloc, 40, 10, 0);
    defer root.deinit();
    var session = try glyphwire.Session.init(alloc, &root);
    defer session.deinit();

    // The shell, on its pane's base context, and a job's context over it
    // that the shell has no access to: `fg` may still raise it.
    var shell = dispatch.Dispatcher.initForConnection(&session, 7, null, null);
    try session.addContextMember(glyphwire.root_context_handle, 7);
    const job = try session.createContext(glyphwire.root_pane_handle, null, null, 0);
    try session.activateContext(glyphwire.root_context_handle);
    const raised = try shell.handle(alloc,
        \\{"jsonrpc":"2.0","method":"activate_context","params":{"context":1}}
    );
    if (raised.broadcast) |b| alloc.free(b.body);
    try testz.expectEqual(session.rootPane().top(), job);

    // Another pane's is not the shell's to rearrange.
    const made = try session.createPane(1, 0);
    const msg = try std.fmt.allocPrint(alloc,
        \\{{"jsonrpc":"2.0","method":"activate_context","params":{{"context":{d}}}}}
    , .{made.context});
    defer alloc.free(msg);
    try testz.expectError(shell.handle(alloc, msg), dispatch.DispatchError.ContextAccessDenied);
}

pub fn accessGoesWithTheConnectionTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var root = try glyphwire.Context.init(alloc, 40, 10, 0);
    defer root.deinit();
    var session = try glyphwire.Session.init(alloc, &root);
    defer session.deinit();

    try session.grantContext(glyphwire.root_context_handle, 7, &root.token);
    try testz.expectTrue(session.mayAccess(glyphwire.root_context_handle, 7));
    try testz.expectError(session.grantContext(glyphwire.root_context_handle, 8, "x"), error.ContextAccessDenied);

    var culled_contexts: std.ArrayList(glyphwire.ContextHandle) = .empty;
    defer culled_contexts.deinit(alloc);
    var culled_panes: std.ArrayList(glyphwire.PaneHandle) = .empty;
    defer culled_panes.deinit(alloc);
    try session.reapConnection(7, &culled_contexts, &culled_panes);
    try testz.expectFalse(session.mayAccess(glyphwire.root_context_handle, 7));
}

pub fn everyContextGetsItsOwnTokenTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var root = try glyphwire.Context.init(alloc, 40, 10, 0);
    defer root.deinit();
    var session = try glyphwire.Session.init(alloc, &root);
    defer session.deinit();
    const a = try session.createContext(glyphwire.root_pane_handle, null, null, 0);
    const ta = session.contextToken(a).?;
    try testz.expectFalse(std.mem.eql(u8, &ta, &root.token));
    for (ta) |ch| try testz.expectTrue(std.ascii.isHex(ch));
    // A token is only good for its own context.
    try testz.expectError(session.grantContext(glyphwire.root_context_handle, 7, &ta), error.ContextAccessDenied);
}

pub fn failedRequestsMapToJsonRpcCodesTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    _ = alloc;
    try testz.expectEqual(dispatch.errorCode(error.UnknownMethod), -32601);
    try testz.expectEqual(dispatch.errorCode(error.NotARequest), -32600);
    try testz.expectEqual(dispatch.errorCode(error.OutOfMemory), -32603);
    try testz.expectEqual(dispatch.errorCode(error.ContextAccessDenied), -32000);
    try testz.expectEqual(dispatch.errorCode(error.UnknownLayer), -32000);
    try testz.expectEqual(dispatch.errorCode(error.MissingField), -32602);
}

/// `write_text`'s `line_join` reaches the cells: the selection copies the
/// two rows as one line.
pub fn writeTextLineJoinJoinsCopiedRowsTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 80, 24, 0);
    defer ctx.deinit();
    var d = dispatch.Dispatcher.init(&ctx);
    const panel = try ctx.createLayer(20, 4, 0);

    try notifyThrough(alloc, &d,
        \\{"jsonrpc":"2.0","method":"write_text","params":{"layer":1,"row":0,"col":0,"spans":[{"text":"soft"},{"text":" wrap"}],"line_join":"space"}}
    );
    try notifyThrough(alloc, &d,
        \\{"jsonrpc":"2.0","method":"write_text","params":{"layer":1,"row":1,"col":0,"text":"here"}}
    );
    const layer = ctx.layerPtr(panel).?;
    layer.sel.set(.{ .above = 0, .col = 0 }, .{ .above = -1, .col = 19 });
    const text = (try layer.sel.text(alloc)).?;
    defer alloc.free(text);
    try testz.expectEqualStr("soft wrap here", text);
}

/// An unknown `line_join` name is a parse error, like `underline`'s.
pub fn writeTextRejectsUnknownLineJoinTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 12, 2, 0);
    defer ctx.deinit();
    var d = dispatch.Dispatcher.init(&ctx);

    const msg =
        \\{"jsonrpc":"2.0","method":"write_text","params":{"text":"hi","line_join":"tab"}}
    ;
    try testz.expectError(d.handle(alloc, msg), dispatch.DispatchError.InvalidLineJoin);
}

/// `write_text`'s `strikethrough` reaches the cells, and a span inherits
/// the message's unless it says otherwise.
pub fn writeTextStrikethroughPerSpanTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 20, 2, 0);
    defer ctx.deinit();
    var d = dispatch.Dispatcher.init(&ctx);

    try notifyThrough(alloc, &d,
        \\{"jsonrpc":"2.0","method":"write_text","params":{"row":0,"col":0,"strikethrough":true,"spans":[{"text":"a"},{"text":"b","strikethrough":false}]}}
    );
    const layer = ctx.layerPtr(glyphwire.root_layer_handle).?;
    try testz.expectTrue(layer.cell(0, 0).style.strike);
    try testz.expectFalse(layer.cell(0, 1).style.strike);
}

/// Creates a borderless, unruled table at (0, 0) -- header on row 0,
/// body from row 1 -- with `columns` (a JSON array) and sends it `rows`
/// (a JSON array of arrays). Returns its handle.
fn tableWithRows(alloc: std.mem.Allocator, d: *dispatch.Dispatcher, ctx: *glyphwire.Context, columns: []const u8, rows: []const u8) !glyphwire.TableHandle {
    const create = try std.fmt.allocPrint(alloc,
        \\{{"jsonrpc":"2.0","id":1,"method":"create_table","params":{{"row":0,"col":0,"columns":{s},"style":{{"borders":false,"header_separator":false}}}}}}
    , .{columns});
    defer alloc.free(create);
    freeResult(alloc, try d.handle(alloc, create));
    const handle = ctx.root.table_order.items[ctx.root.table_order.items.len - 1];
    const set_rows = try std.fmt.allocPrint(alloc,
        \\{{"jsonrpc":"2.0","method":"table_set_rows","params":{{"table":{d},"rows":{s}}}}}
    , .{ handle, rows });
    defer alloc.free(set_rows);
    try notifyThrough(alloc, d, set_rows);
    return handle;
}

/// A `spans` cell joins its texts into `display` (and so its default sort
/// key), and each glyph takes its own span's colour and line, the cell's
/// `fg` filling in where a span has none. The alignment padding takes the
/// cell's plain ink; a "…" takes the last glyph's, so a cut-off struck
/// run stays struck to the column's edge.
pub fn tableCellSpansStyleTheirOwnTextTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 20, 4, 0);
    defer ctx.deinit();
    var d = dispatch.Dispatcher.init(&ctx);

    // A = cols 0..3, gap 4, B = cols 5..8.
    const handle = try tableWithRows(alloc, &d, &ctx,
        \\[{"name":"A","width":4},{"name":"B","width":4}]
    ,
        \\[[{"fg":{"r":10,"g":10,"b":10},"spans":[{"text":"ab","strikethrough":true,"fg":{"r":250,"g":0,"b":0}},{"text":"c"}]},
        \\  {"spans":[{"text":"x"},{"text":"yzwv","strikethrough":true}]}]]
    );
    const table = ctx.root.tables.getPtr(handle).?;
    try testz.expectEqualStr("abc", table.rows[0].cells[0].display);
    try testz.expectEqualStr("abc", table.rows[0].cells[0].sort_key.text);

    const layer = ctx.layerPtr(glyphwire.root_layer_handle).?;
    try testz.expectTrue(layer.cell(1, 0).style.strike);
    try testz.expectTrue(layer.cell(1, 1).style.strike);
    try testz.expectEqual(layer.cell(1, 1).style.fg.r, 250);
    try testz.expectFalse(layer.cell(1, 2).style.strike);
    try testz.expectEqual(layer.cell(1, 2).style.fg.r, 10);
    try testz.expectEqualStr(" ", layer.cell(1, 3).grapheme());
    try testz.expectFalse(layer.cell(1, 3).style.strike);

    // "xyzwv" is cut to "xyz…".
    try testz.expectFalse(layer.cell(1, 5).style.strike);
    try testz.expectTrue(layer.cell(1, 6).style.strike);
    try testz.expectEqualStr("\u{2026}", layer.cell(1, 8).grapheme());
    try testz.expectTrue(layer.cell(1, 8).style.strike);
}

/// A wrapped `spans` cell keeps each span's style on whichever line its
/// text lands, and a span's `metadata_id` tags only its own glyphs.
pub fn tableCellSpansSurviveWrapAndCarryTheirOwnMetadataTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 20, 6, 0);
    defer ctx.deinit();
    var d = dispatch.Dispatcher.init(&ctx);

    freeResult(alloc, try d.handle(alloc,
        \\{"jsonrpc":"2.0","id":1,"method":"create_metadata","params":{"json":"{}"}}
    ));
    _ = try tableWithRows(alloc, &d, &ctx,
        \\[{"name":"A","width":3,"overflow":"wrap"}]
    ,
        \\[[{"spans":[{"text":"aa "},{"text":"bb","strikethrough":true,"metadata_id":1}]}]]
    );
    const layer = ctx.layerPtr(glyphwire.root_layer_handle).?;
    try testz.expectEqualStr("a", layer.cell(1, 0).grapheme());
    try testz.expectFalse(layer.cell(1, 0).style.strike);
    try testz.expectTrue(layer.cell(1, 0).metadata_id == null);
    try testz.expectEqualStr("b", layer.cell(2, 0).grapheme());
    try testz.expectTrue(layer.cell(2, 1).style.strike);
    try testz.expectEqual(layer.cell(2, 1).metadata_id.?, 1);
    // The padding after "bb" is the cell's: no line, no link.
    try testz.expectFalse(layer.cell(2, 2).style.strike);
    try testz.expectTrue(layer.cell(2, 2).metadata_id == null);
}

/// Re-sorting repaints each row's cells in place, so a struck cell's line
/// moves with its row instead of staying on the screen line it was drawn
/// on.
pub fn tableResortMovesStrikethroughWithItsRowTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 20, 4, 0);
    defer ctx.deinit();
    var d = dispatch.Dispatcher.init(&ctx);

    const handle = try tableWithRows(alloc, &d, &ctx,
        \\[{"name":"A","width":3,"sortable":true}]
    ,
        \\[[{"spans":[{"text":"b","strikethrough":true}]}],[{"display":"a"}]]
    );
    const layer = ctx.layerPtr(glyphwire.root_layer_handle).?;
    try testz.expectTrue(layer.cell(1, 0).style.strike);
    try testz.expectFalse(layer.cell(2, 0).style.strike);

    const sort = try std.fmt.allocPrint(alloc,
        \\{{"jsonrpc":"2.0","method":"table_set_sort","params":{{"table":{d},"column":0,"direction":"ascending"}}}}
    , .{handle});
    defer alloc.free(sort);
    try notifyThrough(alloc, &d, sort);
    try testz.expectEqualStr("a", layer.cell(1, 0).grapheme());
    try testz.expectFalse(layer.cell(1, 0).style.strike);
    try testz.expectTrue(layer.cell(2, 0).style.strike);
}

/// A cell sends exactly one of `display` and `spans`.
pub fn tableCellNeedsExactlyOneOfDisplayAndSpansTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    var ctx = try glyphwire.Context.init(alloc, 20, 4, 0);
    defer ctx.deinit();
    var d = dispatch.Dispatcher.init(&ctx);

    freeResult(alloc, try d.handle(alloc,
        \\{"jsonrpc":"2.0","id":1,"method":"create_table","params":{"row":0,"col":0,"columns":[{"name":"A","width":3}]}}
    ));
    const handle = ctx.root.table_order.items[0];
    for ([_][]const u8{
        \\{"display":"a","spans":[{"text":"a"}]}
        ,
        \\{"fg":{"r":1,"g":1,"b":1}}
    }) |cell| {
        const msg = try std.fmt.allocPrint(alloc,
            \\{{"jsonrpc":"2.0","method":"table_set_rows","params":{{"table":{d},"rows":[[{s}]]}}}}
        , .{ handle, cell });
        defer alloc.free(msg);
        try testz.expectError(d.handle(alloc, msg), dispatch.DispatchError.InvalidSpans);
    }
}

// ─── The spec covers the catalog ────────────────────────────────────────

/// Whether `` `name` `` appears in `doc`.
fn specMentions(doc: []const u8, name: []const u8) bool {
    var buf: [128]u8 = undefined;
    const quoted = std.fmt.bufPrint(&buf, "`{s}`", .{name}) catch return false;
    return std.mem.indexOf(u8, doc, quoted) != null;
}

/// Every method the dispatcher accepts and every event it pushes is
/// named in `docs/protocol.md`. `activate_at` once shipped documented only
/// in `docs/api.md`; this keeps the two lists from drifting again.
pub fn protocolSpecCoversEveryMessageTest(io: std.Io, alloc: std.mem.Allocator) !void {
    const doc = try std.Io.Dir.cwd().readFileAlloc(io, "docs/protocol.md", alloc, .unlimited);
    defer alloc.free(doc);

    var missing: usize = 0;
    for (dispatch.Dispatcher.methodNames()) |name| {
        if (specMentions(doc, name)) continue;
        std.log.err("docs/protocol.md doesn't mention method `{s}`", .{name});
        missing += 1;
    }
    for (std.meta.fieldNames(dispatch.PushEvent)) |name| {
        // An event that covers a pair goes out as `<name>_down` /
        // `<name>_up` (see `PushEvent`).
        var buf: [128]u8 = undefined;
        const down = std.fmt.bufPrint(&buf, "{s}_down", .{name}) catch unreachable;
        if (specMentions(doc, name) or specMentions(doc, down)) continue;
        std.log.err("docs/protocol.md doesn't mention event `{s}`", .{name});
        missing += 1;
    }
    try testz.expectEqual(missing, 0);
}
