const std = @import("std");
const testz = @import("testz");
const glyphwire = @import("glyphwire");
const wire = glyphwire.wire;

fn serveConnections(server: *glyphwire.server.Server, alloc: std.mem.Allocator, count: usize) void {
    var i: usize = 0;
    while (i < count) : (i += 1) {
        server.acceptOne(alloc) catch |err| {
            std.debug.print("test server connection failed: {t}\n", .{err});
            return;
        };
    }
}

fn sendMessage(io: std.Io, socket_path: []const u8, body: []const u8) !void {
    const addr = try std.Io.net.UnixAddress.init(socket_path);
    var stream = try addr.connect(io);
    defer stream.close(io);

    var write_buf: [4096]u8 = undefined;
    var w = stream.writer(io, &write_buf);
    try wire.writeFrame(&w.interface, body);
    try w.interface.flush();
}

/// Sends `body` and reads back exactly one framed response.
fn requestMessage(io: std.Io, alloc: std.mem.Allocator, socket_path: []const u8, body: []const u8) ![]u8 {
    const addr = try std.Io.net.UnixAddress.init(socket_path);
    var stream = try addr.connect(io);
    defer stream.close(io);

    var write_buf: [4096]u8 = undefined;
    var w = stream.writer(io, &write_buf);
    try wire.writeFrame(&w.interface, body);
    try w.interface.flush();

    var decoder: wire.FrameDecoder = .{};
    defer decoder.deinit(alloc);

    var read_buf: [4096]u8 = undefined;
    while (true) {
        var data: [1][]u8 = .{&read_buf};
        const n = try stream.read(io, &data);
        if (n == 0) return error.ConnectionClosedBeforeResponse;

        try decoder.feed(alloc, read_buf[0..n]);
        if (try decoder.next(alloc)) |body_out| return body_out;
    }
}

pub fn socketWriteTextThenGetPropertyRoundTripTest(io: std.Io, alloc: std.mem.Allocator) !void {
    var ctx = try glyphwire.Context.init(alloc, 80, 24, 0);
    defer ctx.deinit();

    const socket_path = try std.fmt.allocPrint(alloc, "/tmp/glyphwire-test-{d}.sock", .{std.Thread.getCurrentId()});
    defer alloc.free(socket_path);
    defer std.Io.Dir.deleteFileAbsolute(io, socket_path) catch {};

    var srv = try glyphwire.server.Server.bind(io, &ctx, socket_path);
    defer srv.deinit();

    // Two client connections are expected: one to write "hello", a second
    // to inspect the resulting cursor. Both are served to completion
    // before this call returns.
    const thread = try std.Thread.spawn(.{}, serveConnections, .{ &srv, alloc, @as(usize, 2) });
    defer thread.join();

    try sendMessage(io, socket_path,
        \\{"jsonrpc":"2.0","method":"write_text","params":{"text":"hello"}}
    );

    const response_body = try requestMessage(io, alloc, socket_path,
        \\{"jsonrpc":"2.0","id":1,"method":"get_property","params":{"property":"cursor"}}
    );
    defer alloc.free(response_body);

    const Response = struct {
        id: i64,
        result: struct { row: usize, col: usize },
    };
    const parsed = try std.json.parseFromSlice(Response, alloc, response_body, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    try testz.expectEqual(parsed.value.id, 1);
    try testz.expectEqual(parsed.value.result.row, 0);
    try testz.expectEqual(parsed.value.result.col, 5);

    // Confirm the actual core state, not just what the response claims.
    try testz.expectEqualStr("h", ctx.root.cell(0, 0).grapheme());
    try testz.expectEqualStr("o", ctx.root.cell(0, 4).grapheme());
}
