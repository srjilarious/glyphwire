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

/// `reportLayerScroll` is the pane-ring counterpart of `reportScroll`
/// (root-only) -- glyphwire-host's wheel over a `gmux` pane that has a
/// scrollback ring but no viewport slack. Moves that layer's own
/// `view_scroll`, leaves the root untouched, and broadcasts `scroll`
/// carrying the layer's handle.
pub fn reportLayerScrollMovesANonRootLayersRingTest(io: std.Io, alloc: std.mem.Allocator) !void {
    var ctx = try glyphwire.Context.init(alloc, 80, 24, 0);
    defer ctx.deinit();
    const pane = try ctx.createLayer(4, 2, 5);
    // 3 rows of content over a 2-tall viewport => history_len 1.
    try ctx.layerPtr(pane).?.writeText("aaaabbbbcccc", glyphwire.default_style.fg, glyphwire.default_style.bg);

    const socket_path = try std.fmt.allocPrint(alloc, "/tmp/glyphwire-layer-scroll-test-{d}.sock", .{std.Thread.getCurrentId()});
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

    // delta past history clamps to history_len (1); the root is untouched.
    try srv.reportLayerScroll(alloc, pane, null, 9);

    const notif_body = try readOneFrame(io, alloc, &stream, &decoder);
    defer alloc.free(notif_body);

    const Notification = struct {
        method: []const u8,
        params: struct { layer: ?glyphwire.LayerHandle = null, offset: usize, max: usize },
    };
    const parsed = try std.json.parseFromSlice(Notification, alloc, notif_body, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    try testz.expectEqualStr("scroll", parsed.value.method);
    try testz.expectEqual(parsed.value.params.layer.?, pane);
    try testz.expectEqual(parsed.value.params.offset, 1);
    try testz.expectEqual(ctx.layerPtr(pane).?.view_scroll, 1);
    try testz.expectEqual(ctx.root.view_scroll, 0);
}

/// An unknown layer handle is a silent no-op, not an error -- the same
/// "fire and forget from an in-process caller" shape every other
/// `Server.report*` method has.
pub fn reportLayerScrollOnUnknownLayerIsANoOpTest(io: std.Io, alloc: std.mem.Allocator) !void {
    var ctx = try glyphwire.Context.init(alloc, 80, 24, 0);
    defer ctx.deinit();

    const socket_path = try std.fmt.allocPrint(alloc, "/tmp/glyphwire-layer-scroll-unknown-test-{d}.sock", .{std.Thread.getCurrentId()});
    defer alloc.free(socket_path);
    defer std.Io.Dir.deleteFileAbsolute(io, socket_path) catch {};
    var srv = try glyphwire.server.Server.bind(io, &ctx, socket_path);
    defer srv.deinit(alloc);

    try srv.reportLayerScroll(alloc, 99, null, 1);
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

/// A counter for `wakeCallbackFiresOnSocketDispatchTest`. File-scope
/// because `setWakeCallback` takes a bare fn pointer; the `?*anyopaque`
/// context is the test's own local `std.atomic.Value(u32)`.
fn countWake(ctx: ?*anyopaque) void {
    const c: *std.atomic.Value(u32) = @ptrCast(@alignCast(ctx.?));
    _ = c.fetchAdd(1, .monotonic);
}

/// A front end that only redraws on demand (glyphwire-host) registers a
/// wake hook so a socket client's dispatch -- which runs on that
/// connection's thread -- can nudge the render loop. Every dispatched
/// frame fires it; a second round trip on the same connection is the sync
/// point that proves the first one's wake ran.
pub fn wakeCallbackFiresOnSocketDispatchTest(io: std.Io, alloc: std.mem.Allocator) !void {
    var ctx = try glyphwire.Context.init(alloc, 80, 24, 0);
    defer ctx.deinit();

    const socket_path = try std.fmt.allocPrint(alloc, "/tmp/glyphwire-wake-test-{d}.sock", .{std.Thread.getCurrentId()});
    defer alloc.free(socket_path);
    defer std.Io.Dir.deleteFileAbsolute(io, socket_path) catch {};

    var srv = try glyphwire.server.Server.bind(io, &ctx, socket_path);
    defer srv.deinit(alloc);

    var wake_count: std.atomic.Value(u32) = .init(0);
    srv.setWakeCallback(&wake_count, countWake);

    const accept_thread = try std.Thread.spawn(.{}, acceptOnce, .{ &srv, alloc });
    defer accept_thread.join();

    const addr = try std.Io.net.UnixAddress.init(socket_path);
    var stream = try addr.connect(io);
    defer stream.close(io);
    var decoder: wire.FrameDecoder = .{};
    defer decoder.deinit(alloc);

    var write_buf: [4096]u8 = undefined;
    var w = stream.writer(io, &write_buf);

    // A notification (no id): dispatched, no response frame.
    try wire.writeFrame(&w.interface,
        \\{"jsonrpc":"2.0","method":"write_text","params":{"text":"hi"}}
    );
    try w.interface.flush();

    // The server handles one frame at a time per connection, so by the
    // time this request's response is in hand the earlier notification's
    // post-dispatch `wake()` has run.
    try wire.writeFrame(&w.interface,
        \\{"jsonrpc":"2.0","id":2,"method":"get_property","params":{"property":"cursor"}}
    );
    try w.interface.flush();
    const r2 = try readOneFrame(io, alloc, &stream, &decoder);
    alloc.free(r2);

    try testz.expectTrue(wake_count.load(.monotonic) >= 1);
}

/// The headless server (`server/main.zig`) and any repaint-every-frame
/// front end never call `setWakeCallback`; dispatch must not depend on a
/// hook being present.
pub fn dispatchWorksWithNoWakeCallbackTest(io: std.Io, alloc: std.mem.Allocator) !void {
    var ctx = try glyphwire.Context.init(alloc, 80, 24, 0);
    defer ctx.deinit();

    const socket_path = try std.fmt.allocPrint(alloc, "/tmp/glyphwire-nowake-test-{d}.sock", .{std.Thread.getCurrentId()});
    defer alloc.free(socket_path);
    defer std.Io.Dir.deleteFileAbsolute(io, socket_path) catch {};

    var srv = try glyphwire.server.Server.bind(io, &ctx, socket_path);
    defer srv.deinit(alloc);

    const thread = try std.Thread.spawn(.{}, serveConnections, .{ &srv, alloc, @as(usize, 2) });
    defer thread.join();

    try sendMessage(io, socket_path,
        \\{"jsonrpc":"2.0","method":"write_text","params":{"text":"ok"}}
    );

    // A second connection's round trip both syncs against the write above
    // and exercises the null-hook path once more.
    const response_body = try requestMessage(io, alloc, socket_path,
        \\{"jsonrpc":"2.0","id":1,"method":"get_property","params":{"property":"cursor"}}
    );
    defer alloc.free(response_body);

    try testz.expectEqualStr("o", ctx.root.cell(0, 0).grapheme());
    try testz.expectEqualStr("k", ctx.root.cell(0, 1).grapheme());
}

// ─── Panes ──────────────────────────────────────────────────────────────

/// The load-bearing guarantee of the whole pane design: a keystroke reaches
/// the program in the *focused* pane and no other. Two connections, each
/// bound to its own pane, and only one of them hears the key.
///
/// Proved by ordering rather than by a read timeout (`std.Io.net.Stream` has
/// none): the key is reported while pane A has focus, then focus moves and a
/// second key is reported. If the gate were broken, B's first read would
/// return the first key rather than the second.
pub fn inputReachesOnlyTheFocusedPanesClientTest(io: std.Io, alloc: std.mem.Allocator) !void {
    var ctx = try glyphwire.Context.init(alloc, 40, 10, 0);
    defer ctx.deinit();

    const socket_path = try std.fmt.allocPrint(alloc, "/tmp/glyphwire-pane-focus-test-{d}.sock", .{std.Thread.getCurrentId()});
    defer alloc.free(socket_path);
    defer std.Io.Dir.deleteFileAbsolute(io, socket_path) catch {};

    var srv = try glyphwire.server.Server.bind(io, &ctx, socket_path);
    defer srv.deinit(alloc);

    // Two panes side by side, both mapped, root focused.
    const made = try srv.session.createPane(0, 0);
    const split = try srv.session.createPaneSplit(.row, true);
    try srv.session.setPaneSplitChildren(split, &.{
        .{ .target = .{ .pane = glyphwire.root_pane_handle }, .size = .{ .weight = 1 } },
        .{ .target = .{ .pane = made.pane }, .size = .{ .weight = 1 } },
    });
    try srv.session.setRootPaneSplit(split);
    try srv.session.layoutPanes(null, null);

    const t_a = try std.Thread.spawn(.{}, acceptOnce, .{ &srv, alloc });
    defer t_a.join();
    const addr = try std.Io.net.UnixAddress.init(socket_path);
    var a = try addr.connect(io);
    defer a.close(io);
    var a_dec: wire.FrameDecoder = .{};
    defer a_dec.deinit(alloc);

    // The root pane's client. `pane` folded into `subscribe`, exactly as a
    // real client does it.
    var a_buf: [4096]u8 = undefined;
    var a_w = a.writer(io, &a_buf);
    try wire.writeFrame(&a_w.interface,
        \\{"jsonrpc":"2.0","id":1,"method":"subscribe","params":{"events":["key"],"pane":0}}
    );
    try a_w.interface.flush();
    alloc.free(try readOneFrame(io, alloc, &a, &a_dec));

    const t_b = try std.Thread.spawn(.{}, acceptOnce, .{ &srv, alloc });
    defer t_b.join();
    var b = try addr.connect(io);
    defer b.close(io);
    var b_dec: wire.FrameDecoder = .{};
    defer b_dec.deinit(alloc);

    var b_buf: [4096]u8 = undefined;
    var b_w = b.writer(io, &b_buf);
    try wire.writeFrame(&b_w.interface,
        \\{"jsonrpc":"2.0","id":1,"method":"subscribe","params":{"events":["key"],"pane":1}}
    );
    try b_w.interface.flush();
    alloc.free(try readOneFrame(io, alloc, &b, &b_dec));

    // Root pane has focus: `a` gets this, `b` must not.
    try srv.reportKey(alloc, "x", true);
    const a_got = try readOneFrame(io, alloc, &a, &a_dec);
    defer alloc.free(a_got);
    try testz.expectTrue(std.mem.indexOf(u8, a_got, "\"key\":\"x\"") != null);

    // Focus moves to the other pane, and now only `b` hears.
    try srv.session.focusPane(made.pane);
    srv.ctx = srv.session.focusedContext();
    try srv.reportKey(alloc, "y", true);

    const b_got = try readOneFrame(io, alloc, &b, &b_dec);
    defer alloc.free(b_got);
    // `y`, not `x`: the first key never reached this connection at all.
    try testz.expectTrue(std.mem.indexOf(u8, b_got, "\"key\":\"y\"") != null);
    try testz.expectTrue(std.mem.indexOf(u8, b_got, "\"key\":\"x\"") == null);
}

/// A pane-tree change sends each client *its own* context's new size, not
/// the window's -- the per-connection `resize` that replaces one broadcast.
pub fn paneLayoutSendsEachClientItsOwnSizeTest(io: std.Io, alloc: std.mem.Allocator) !void {
    var ctx = try glyphwire.Context.init(alloc, 41, 10, 0);
    defer ctx.deinit();

    const socket_path = try std.fmt.allocPrint(alloc, "/tmp/glyphwire-pane-resize-test-{d}.sock", .{std.Thread.getCurrentId()});
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
        \\{"jsonrpc":"2.0","id":1,"method":"subscribe","params":{"events":["resize"],"pane":0}}
    );
    try w.interface.flush();
    alloc.free(try readOneFrame(io, alloc, &stream, &decoder));

    // Split the window in two. The client is in the left pane, so it must
    // be told 20 columns, not the window's 41.
    const made = try srv.session.createPane(0, 0);
    const split = try srv.session.createPaneSplit(.row, true);
    try srv.session.setPaneSplitChildren(split, &.{
        .{ .target = .{ .pane = glyphwire.root_pane_handle }, .size = .{ .weight = 1 } },
        .{ .target = .{ .pane = made.pane }, .size = .{ .weight = 1 } },
    });
    try srv.session.setRootPaneSplit(split);
    try srv.applyPaneLayout(alloc);

    const body = try readOneFrame(io, alloc, &stream, &decoder);
    defer alloc.free(body);
    const Notification = struct {
        method: []const u8,
        params: struct { cols: usize, rows: usize },
    };
    const parsed = try std.json.parseFromSlice(Notification, alloc, body, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    try testz.expectEqualStr("resize", parsed.value.method);
    try testz.expectEqual(parsed.value.params.cols, 20);
    try testz.expectEqual(parsed.value.params.rows, 10);
}

/// The prefix chord never reaches the program in the focused pane, and the
/// key after it is addressed to the manager instead. Same ordering trick as
/// the focus test: the program's next read must see the key that followed
/// the whole prefix sequence, not anything inside it.
pub fn thePrefixSequenceNeverReachesTheProgramTest(io: std.Io, alloc: std.mem.Allocator) !void {
    var ctx = try glyphwire.Context.init(alloc, 40, 10, 0);
    defer ctx.deinit();

    const socket_path = try std.fmt.allocPrint(alloc, "/tmp/glyphwire-prefix-test-{d}.sock", .{std.Thread.getCurrentId()});
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
        \\{"jsonrpc":"2.0","id":1,"method":"subscribe","params":{"events":["key","text"]}}
    );
    try w.interface.flush();
    alloc.free(try readOneFrame(io, alloc, &stream, &decoder));

    srv.session.window_prefix = glyphwire.WindowPrefix.init("b", true, false, false);

    // Ctrl-B then `q`: the whole sequence is withheld from this program.
    try srv.reportKey(alloc, "left_control", true);
    alloc.free(try readOneFrame(io, alloc, &stream, &decoder)); // the modifier itself passes
    try srv.reportKey(alloc, "b", true);
    try srv.reportKey(alloc, "b", false);
    try srv.reportText(alloc, "q");

    // An ordinary keystroke afterwards, which must be the next thing the
    // program sees.
    try srv.reportText(alloc, "z");
    const body = try readOneFrame(io, alloc, &stream, &decoder);
    defer alloc.free(body);
    try testz.expectTrue(std.mem.indexOf(u8, body, "\"text\":\"z\"") != null);
    try testz.expectTrue(std.mem.indexOf(u8, body, "\"q\"") == null);
    try testz.expectTrue(std.mem.indexOf(u8, body, "\"b\"") == null);
}
