const std = @import("std");
const testz = @import("testz");
const glyphwire = @import("glyphwire");
const rpc = glyphwire.rpc;

// The bytes these builders emit are the wire contract shared by
// dispatch.zig (socket) and server.zig (in-process), and parsed back by
// client.zig's InputListener -- pin them exactly so a std.json change or
// an accidental field reorder shows up here rather than as a silent
// cross-end mismatch.

pub fn responseWrapsResultInEnvelopeTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    const body = try rpc.response(alloc, .{ .integer = 7 }, .{ .row = 2, .col = 5 });
    defer alloc.free(body);
    try testz.expectEqualStr(
        \\{"jsonrpc":"2.0","id":7,"result":{"row":2,"col":5}}
    , body);
}

pub fn notificationWrapsParamsInEnvelopeTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    const body = try rpc.notification(alloc, "scroll", .{ .offset = 3, .max = 40 });
    defer alloc.free(body);
    try testz.expectEqualStr(
        \\{"jsonrpc":"2.0","method":"scroll","params":{"offset":3,"max":40}}
    , body);
}

pub fn keyNotificationPicksMethodFromPressedTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    const down = try rpc.keyNotification(alloc, "space", true);
    defer alloc.free(down);
    try testz.expectEqualStr(
        \\{"jsonrpc":"2.0","method":"key_down","params":{"key":"space"}}
    , down);

    const up = try rpc.keyNotification(alloc, "space", false);
    defer alloc.free(up);
    try testz.expectEqualStr(
        \\{"jsonrpc":"2.0","method":"key_up","params":{"key":"space"}}
    , up);
}

pub fn keyRepeatNotificationIsAlwaysKeyDownTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    const body = try rpc.keyRepeatNotification(alloc, "left");
    defer alloc.free(body);
    try testz.expectEqualStr(
        \\{"jsonrpc":"2.0","method":"key_down","params":{"key":"left"}}
    , body);
}

pub fn mouseButtonNotificationShapeTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    const body = try rpc.mouseButtonNotification(
        alloc,
        "left",
        true,
        .{ .x = 12.5, .y = 30 },
        .{ .row = 2, .col = 1 },
        4,
    );
    defer alloc.free(body);
    try testz.expectEqualStr(
        \\{"jsonrpc":"2.0","method":"mouse_button","params":{"button":"left","pressed":true,"px":{"x":12.5,"y":30},"cell":{"row":2,"col":1},"view_offset":4}}
    , body);
}

pub fn resizeNotificationShapeTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    const body = try rpc.resizeNotification(alloc, 80, 24);
    defer alloc.free(body);
    try testz.expectEqualStr(
        \\{"jsonrpc":"2.0","method":"resize","params":{"cols":80,"rows":24}}
    , body);
}

pub fn selectionNotificationShapeTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    const active = try rpc.selectionNotification(alloc, .{
        .anchor = .{ .above = 2, .col = 0 },
        .active = .{ .above = -1, .col = 7 },
    });
    defer alloc.free(active);
    try testz.expectEqualStr(
        \\{"jsonrpc":"2.0","method":"selection","params":{"active":true,"anchor":{"above":2,"col":0},"active_end":{"above":-1,"col":7}}}
    , active);

    const cleared = try rpc.selectionNotification(alloc, null);
    defer alloc.free(cleared);
    try testz.expectEqualStr(
        \\{"jsonrpc":"2.0","method":"selection","params":{"active":false,"anchor":null,"active_end":null}}
    , cleared);
}

pub fn copyRequestAndPasteNotificationShapeTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;
    const copy = try rpc.copyRequestNotification(alloc);
    defer alloc.free(copy);
    try testz.expectEqualStr(
        \\{"jsonrpc":"2.0","method":"copy_request","params":{}}
    , copy);

    const paste = try rpc.pasteNotification(alloc, "pasted text");
    defer alloc.free(paste);
    try testz.expectEqualStr(
        \\{"jsonrpc":"2.0","method":"paste","params":{"text":"pasted text"}}
    , paste);
}
