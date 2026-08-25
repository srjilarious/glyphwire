const std = @import("std");
const testz = @import("testz");
const glyphwire = @import("glyphwire");

pub fn clientWriteTextThenGetCellsRoundTripTest(io: std.Io, alloc: std.mem.Allocator) !void {
    var ctx = try glyphwire.Context.init(alloc, 10, 3, 0);
    defer ctx.deinit();

    const socket_path = try std.fmt.allocPrint(alloc, "/tmp/glyphwire-client-test-{d}.sock", .{std.Thread.getCurrentId()});
    defer alloc.free(socket_path);
    defer std.Io.Dir.deleteFileAbsolute(io, socket_path) catch {};

    var srv = try glyphwire.server.Server.bind(io, &ctx, socket_path);
    defer srv.deinit();

    // One client connection makes every call below over the same socket,
    // so the server only needs to serve one connection to completion.
    const thread = try std.Thread.spawn(.{}, serveOne, .{ &srv, alloc });
    defer thread.join();

    var client = try glyphwire.Client.connect(io, alloc, socket_path);
    defer client.deinit();

    const rev_before = try client.getRevision();
    try testz.expectEqual(rev_before, 0);

    try client.writeText("hi", .{ .r = 0, .g = 255, .b = 255, .a = 255 }, .{ .r = 40, .g = 40, .b = 90, .a = 255 });

    const cursor = try client.getCursor();
    try testz.expectEqual(cursor.row, 0);
    try testz.expectEqual(cursor.col, 2);

    const rev_after = try client.getRevision();
    try testz.expectEqual(rev_after, 1);

    var snapshot = try client.getCells();
    defer snapshot.deinit();

    try testz.expectEqual(snapshot.cols(), 10);
    try testz.expectEqual(snapshot.rows(), 3);
    try testz.expectEqual(snapshot.revision(), 1);

    const h = snapshot.cellAt(0, 0);
    try testz.expectEqualStr("h", h.grapheme);
    try testz.expectEqual(h.fg.g, 255);
    try testz.expectEqual(h.fg.b, 255);
    try testz.expectEqual(h.bg.?.r, 40);
    try testz.expectEqual(h.bg.?.b, 90);

    const blank = snapshot.cellAt(1, 0);
    try testz.expectEqualStr("", blank.grapheme);
}

pub fn clientSetCursorThenWriteTextPositionsAtCursorTest(io: std.Io, alloc: std.mem.Allocator) !void {
    var ctx = try glyphwire.Context.init(alloc, 10, 3, 0);
    defer ctx.deinit();

    const socket_path = try std.fmt.allocPrint(alloc, "/tmp/glyphwire-client-test-{d}.sock", .{std.Thread.getCurrentId()});
    defer alloc.free(socket_path);
    defer std.Io.Dir.deleteFileAbsolute(io, socket_path) catch {};

    var srv = try glyphwire.server.Server.bind(io, &ctx, socket_path);
    defer srv.deinit();

    const thread = try std.Thread.spawn(.{}, serveOne, .{ &srv, alloc });

    var client = try glyphwire.Client.connect(io, alloc, socket_path);
    try client.setCursor(1, 3);
    try client.writeText("x", null, null);
    client.deinit();

    // Only after the connection closes (and the server thread observes
    // that and returns) is the write guaranteed to have been dispatched.
    thread.join();
    try testz.expectEqualStr("x", ctx.root.cell(1, 3).grapheme());
}

fn serveOne(server: *glyphwire.server.Server, alloc: std.mem.Allocator) void {
    server.acceptOne(alloc) catch |err| {
        std.debug.print("test server connection failed: {t}\n", .{err});
    };
}
