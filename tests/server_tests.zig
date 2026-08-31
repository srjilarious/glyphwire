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

    return try readOneFrame(io, alloc, &stream, &decoder);
}

/// Reads exactly one framed body off an already-connected `stream`, using
/// (and potentially leaving buffered bytes in) a caller-owned `decoder` --
/// unlike `requestMessage`, meant for a connection multiple frames are
/// read from over its lifetime (e.g. a subscribe ack followed later by a
/// broadcast notification on the same connection).
fn readOneFrame(io: std.Io, alloc: std.mem.Allocator, stream: *std.Io.net.Stream, decoder: *wire.FrameDecoder) ![]u8 {
    if (try decoder.next(alloc)) |body| return body;

    var read_buf: [4096]u8 = undefined;
    while (true) {
        var data: [1][]u8 = .{&read_buf};
        const n = try stream.read(io, &data);
        if (n == 0) return error.ConnectionClosedBeforeResponse;

        try decoder.feed(alloc, read_buf[0..n]);
        if (try decoder.next(alloc)) |body| return body;
    }
}

fn acceptOnce(server: *glyphwire.server.Server, alloc: std.mem.Allocator) void {
    server.acceptOne(alloc) catch |err| {
        std.debug.print("test server connection failed: {t}\n", .{err});
    };
}

pub fn socketWriteTextThenGetPropertyRoundTripTest(io: std.Io, alloc: std.mem.Allocator) !void {
    var ctx = try glyphwire.Context.init(alloc, 80, 24, 0);
    defer ctx.deinit();

    const socket_path = try std.fmt.allocPrint(alloc, "/tmp/glyphwire-test-{d}.sock", .{std.Thread.getCurrentId()});
    defer alloc.free(socket_path);
    defer std.Io.Dir.deleteFileAbsolute(io, socket_path) catch {};

    var srv = try glyphwire.server.Server.bind(io, &ctx, socket_path);
    defer srv.deinit(alloc);

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

/// Proves concurrent connections and the subscribe/broadcast fan-out work
/// together: connection A subscribes to "key" events and stays open;
/// connection B (simulating glyphwire-host) reports a key press; A
/// receives the resulting key_down notification on its still-open
/// connection, not by polling.
pub fn subscribedConnectionReceivesBroadcastKeyEventTest(io: std.Io, alloc: std.mem.Allocator) !void {
    var ctx = try glyphwire.Context.init(alloc, 80, 24, 0);
    defer ctx.deinit();

    const socket_path = try std.fmt.allocPrint(alloc, "/tmp/glyphwire-broadcast-test-{d}.sock", .{std.Thread.getCurrentId()});
    defer alloc.free(socket_path);
    defer std.Io.Dir.deleteFileAbsolute(io, socket_path) catch {};

    var srv = try glyphwire.server.Server.bind(io, &ctx, socket_path);
    defer srv.deinit(alloc);

    // Two genuinely concurrent connections need two threads each blocked
    // in their own acceptOne -- unlike serveConnections above, which
    // serves connections to completion one at a time on a single thread.
    const thread_a = try std.Thread.spawn(.{}, acceptOnce, .{ &srv, alloc });
    const thread_b = try std.Thread.spawn(.{}, acceptOnce, .{ &srv, alloc });
    defer thread_a.join();
    defer thread_b.join();

    const addr = try std.Io.net.UnixAddress.init(socket_path);

    var stream_a = try addr.connect(io);
    defer stream_a.close(io);
    var decoder_a: wire.FrameDecoder = .{};
    defer decoder_a.deinit(alloc);

    var write_buf_a: [4096]u8 = undefined;
    var wa = stream_a.writer(io, &write_buf_a);
    try wire.writeFrame(&wa.interface,
        \\{"jsonrpc":"2.0","id":1,"method":"subscribe","params":{"events":["key"]}}
    );
    try wa.interface.flush();

    // Wait for the subscribe ack before B reports anything, so the
    // subscription is guaranteed to be in effect first.
    const ack = try readOneFrame(io, alloc, &stream_a, &decoder_a);
    alloc.free(ack);

    var stream_b = try addr.connect(io);
    var write_buf_b: [4096]u8 = undefined;
    var wb = stream_b.writer(io, &write_buf_b);
    try wire.writeFrame(&wb.interface,
        \\{"jsonrpc":"2.0","method":"report_key","params":{"key":"a","pressed":true}}
    );
    try wb.interface.flush();
    stream_b.close(io);

    const notif_body = try readOneFrame(io, alloc, &stream_a, &decoder_a);
    defer alloc.free(notif_body);

    const Notification = struct {
        method: []const u8,
        params: struct { key: []const u8 },
    };
    const parsed = try std.json.parseFromSlice(Notification, alloc, notif_body, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    try testz.expectEqualStr("key_down", parsed.value.method);
    try testz.expectEqualStr("a", parsed.value.params.key);
    try testz.expectTrue(ctx.input.isKeyDown("a"));
}

/// `Server.reportResize` (the in-process path glyphwire-host calls when
/// its window changes size) resizes the context's root layer and pushes
/// a `resize` notification to a connection subscribed to `"resize"`.
pub fn reportResizeResizesRootAndBroadcastsToSubscribersTest(io: std.Io, alloc: std.mem.Allocator) !void {
    var ctx = try glyphwire.Context.init(alloc, 80, 24, 0);
    defer ctx.deinit();

    const socket_path = try std.fmt.allocPrint(alloc, "/tmp/glyphwire-resize-test-{d}.sock", .{std.Thread.getCurrentId()});
    defer alloc.free(socket_path);
    defer std.Io.Dir.deleteFileAbsolute(io, socket_path) catch {};

    var srv = try glyphwire.server.Server.bind(io, &ctx, socket_path);
    defer srv.deinit(alloc);

    const accept_thread = try std.Thread.spawn(.{}, acceptOnce, .{ &srv, alloc });
    defer accept_thread.join();

    const addr = try std.Io.net.UnixAddress.init(socket_path);
    var stream = try addr.connect(io);
    defer stream.close(io);
    var decoder: wire.FrameDecoder = .{};
    defer decoder.deinit(alloc);

    var write_buf: [4096]u8 = undefined;
    var w = stream.writer(io, &write_buf);
    try wire.writeFrame(&w.interface,
        \\{"jsonrpc":"2.0","id":1,"method":"subscribe","params":{"events":["resize"]}}
    );
    try w.interface.flush();

    // Wait for the subscribe ack so the subscription is in effect before
    // the resize is reported.
    const ack = try readOneFrame(io, alloc, &stream, &decoder);
    alloc.free(ack);

    try srv.reportResize(alloc, 100, 30);

    const notif_body = try readOneFrame(io, alloc, &stream, &decoder);
    defer alloc.free(notif_body);

    const Notification = struct {
        method: []const u8,
        params: struct { cols: usize, rows: usize },
    };
    const parsed = try std.json.parseFromSlice(Notification, alloc, notif_body, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    try testz.expectEqualStr("resize", parsed.value.method);
    try testz.expectEqual(parsed.value.params.cols, 100);
    try testz.expectEqual(parsed.value.params.rows, 30);
    try testz.expectEqual(ctx.root.width, 100);
    try testz.expectEqual(ctx.root.height, 30);
}

/// `Server.reportScroll` (the in-process path glyphwire-host's mouse
/// wheel / scrollbar call) moves the root layer's scrollback view offset
/// and pushes a `scroll` notification to a `"scroll"` subscriber.
pub fn reportScrollMovesViewOffsetAndBroadcastsToSubscribersTest(io: std.Io, alloc: std.mem.Allocator) !void {
    var ctx = try glyphwire.Context.init(alloc, 4, 2, 5);
    defer ctx.deinit();
    // 3 rows of content over a 2-tall viewport => history_len 1.
    try ctx.root.writeText("aaaabbbbcccc", glyphwire.default_style.fg, glyphwire.default_style.bg);

    const socket_path = try std.fmt.allocPrint(alloc, "/tmp/glyphwire-scroll-test-{d}.sock", .{std.Thread.getCurrentId()});
    defer alloc.free(socket_path);
    defer std.Io.Dir.deleteFileAbsolute(io, socket_path) catch {};

    var srv = try glyphwire.server.Server.bind(io, &ctx, socket_path);
    defer srv.deinit(alloc);

    const accept_thread = try std.Thread.spawn(.{}, acceptOnce, .{ &srv, alloc });
    defer accept_thread.join();

    const addr = try std.Io.net.UnixAddress.init(socket_path);
    var stream = try addr.connect(io);
    defer stream.close(io);
    var decoder: wire.FrameDecoder = .{};
    defer decoder.deinit(alloc);

    var write_buf: [4096]u8 = undefined;
    var w = stream.writer(io, &write_buf);
    try wire.writeFrame(&w.interface,
        \\{"jsonrpc":"2.0","id":1,"method":"subscribe","params":{"events":["scroll"]}}
    );
    try w.interface.flush();

    const ack = try readOneFrame(io, alloc, &stream, &decoder);
    alloc.free(ack);

    // delta past history clamps to history_len (1).
    try srv.reportScroll(alloc, null, 9);

    const notif_body = try readOneFrame(io, alloc, &stream, &decoder);
    defer alloc.free(notif_body);

    const Notification = struct {
        method: []const u8,
        params: struct { offset: usize, max: usize },
    };
    const parsed = try std.json.parseFromSlice(Notification, alloc, notif_body, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    try testz.expectEqualStr("scroll", parsed.value.method);
    try testz.expectEqual(parsed.value.params.offset, 1);
    try testz.expectEqual(parsed.value.params.max, 1);
    try testz.expectEqual(ctx.root.view_scroll, 1);
}

/// A notification whose dispatch fails server-side (here: draw_icon
/// naming an icon nothing registered) has no response channel to report
/// the error on anyway -- should just be logged, not sever the whole
/// connection. Proves it by sending a bad notification, then two more
/// ordinary messages on the *same* connection and confirming both still
/// land.
pub fn badNotificationDoesNotSeverTheConnectionTest(io: std.Io, alloc: std.mem.Allocator) !void {
    var ctx = try glyphwire.Context.init(alloc, 80, 24, 0);
    defer ctx.deinit();

    const socket_path = try std.fmt.allocPrint(alloc, "/tmp/glyphwire-badnotif-test-{d}.sock", .{std.Thread.getCurrentId()});
    defer alloc.free(socket_path);
    defer std.Io.Dir.deleteFileAbsolute(io, socket_path) catch {};

    var srv = try glyphwire.server.Server.bind(io, &ctx, socket_path);
    defer srv.deinit(alloc);

    const thread = try std.Thread.spawn(.{}, acceptOnce, .{ &srv, alloc });
    defer thread.join();

    const addr = try std.Io.net.UnixAddress.init(socket_path);
    var stream = try addr.connect(io);
    defer stream.close(io);

    var write_buf: [4096]u8 = undefined;
    var w = stream.writer(io, &write_buf);

    try wire.writeFrame(&w.interface,
        \\{"jsonrpc":"2.0","method":"draw_icon","params":{"row":0,"col":0,"name":"not-registered"}}
    );
    try w.interface.flush();

    try wire.writeFrame(&w.interface,
        \\{"jsonrpc":"2.0","method":"write_text","params":{"text":"hi"}}
    );
    try w.interface.flush();

    try wire.writeFrame(&w.interface,
        \\{"jsonrpc":"2.0","id":1,"method":"get_property","params":{"property":"cursor"}}
    );
    try w.interface.flush();

    var decoder: wire.FrameDecoder = .{};
    defer decoder.deinit(alloc);
    const response_body = try readOneFrame(io, alloc, &stream, &decoder);
    defer alloc.free(response_body);

    const Response = struct { id: i64, result: struct { row: usize, col: usize } };
    const parsed = try std.json.parseFromSlice(Response, alloc, response_body, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    try testz.expectEqual(parsed.value.result.col, 2);
    try testz.expectEqualStr("h", ctx.root.cell(0, 0).grapheme());
}
