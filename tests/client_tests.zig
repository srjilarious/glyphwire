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
    defer srv.deinit(alloc);

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
    defer srv.deinit(alloc);

    // errdefer, not a plain trailing statement: an early `try` failure
    // below (setCursor/writeText) must still join this thread, or it's
    // left running against this function's about-to-be-invalid stack and
    // per-test allocator -- see inputListenerReceivesReportedInputTest's
    // doc comment for what that corrupts. On the success path this is
    // joined explicitly instead (see below), deliberately before the
    // assertion, so errdefer never fires there.
    const thread = try std.Thread.spawn(.{}, serveOne, .{ &srv, alloc });
    errdefer thread.join();

    // Same reasoning, and registered after thread's errdefer so (LIFO) it
    // unwinds first: the server thread's acceptOne only returns once this
    // connection closes.
    var client = try glyphwire.Client.connect(io, alloc, socket_path);
    errdefer client.deinit();

    try client.setCursor(1, 3);
    try client.writeText("x", null, null);

    // Explicit sequencing, not just eventual cleanup: the assertion below
    // reads ctx directly rather than over the wire, so it must wait for
    // the connection to actually close and the server thread to finish
    // dispatching everything first.
    client.deinit();
    thread.join();

    try testz.expectEqualStr("x", ctx.root.cell(1, 3).grapheme());
}

/// Exercises the full client-library path (not just the raw-socket
/// dispatch-level version in server_tests.zig): a subscribed
/// `InputListener` on one connection receives what a `Client` on another
/// connection reports, via the real background reader thread.
pub fn inputListenerReceivesReportedInputTest(_: std.Io, alloc: std.mem.Allocator) !void {
    // See e2e_tests.zig's comment: testz's default Io (global_single_threaded)
    // has deliberate limitations beyond just its failing allocator. This
    // test needs a real Io backing genuine cross-thread synchronization
    // (Io.Mutex contention between the broadcast and the connection
    // threads), so it builds its own instead of reusing the one testz passed in.
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var ctx = try glyphwire.Context.init(alloc, 80, 24, 0);
    defer ctx.deinit();

    const socket_path = try std.fmt.allocPrint(alloc, "/tmp/glyphwire-client-test-{d}.sock", .{std.Thread.getCurrentId()});
    defer alloc.free(socket_path);
    defer std.Io.Dir.deleteFileAbsolute(io, socket_path) catch {};

    var srv = try glyphwire.server.Server.bind(io, &ctx, socket_path);
    defer srv.deinit(alloc);

    // Which of these two threads' acceptOne ends up serving the listener's
    // connection vs the reporter's is a race (both just call accept() on
    // the same listener). All four of these are `defer`, not plain
    // trailing statements: this test's remaining assertions read only
    // `listener`'s mutex-guarded local cache (not `ctx` directly), so
    // unlike clientSetCursorThenWriteTextPositionsAtCursorTest there's no
    // ordering requirement forcing an explicit mid-function close/join --
    // but an early `try` failure below still must not leave any of these
    // running against this function's about-to-be-invalid stack and
    // per-test allocator. That's exactly what happened before this was
    // fixed: an assertion failure here left thread1/thread2 orphaned,
    // and they went on to corrupt an unrelated *later* test's memory
    // (segfaults/hangs that didn't point back to their real cause).
    const thread1 = try std.Thread.spawn(.{}, serveOne, .{ &srv, alloc });
    defer thread1.join();
    const thread2 = try std.Thread.spawn(.{}, serveOne, .{ &srv, alloc });
    defer thread2.join();

    const listener = try glyphwire.InputListener.connect(io, alloc, socket_path, &.{ "key", "mouse_button" });
    defer listener.deinit();
    try testz.expectTrue(!listener.isKeyDown("a"));

    var reporter = try glyphwire.Client.connect(io, alloc, socket_path);
    defer reporter.deinit();
    try reporter.reportKey("a", true);
    try reporter.reportMouseButton("left", true, .{ .x = 12, .y = 34 }, .{ .row = 1, .col = 2 });

    // The listener's background thread updates asynchronously; poll
    // briefly rather than assuming it's already landed.
    var attempts: usize = 0;
    while (!listener.isKeyDown("a") and attempts < 100) : (attempts += 1) {
        std.Io.sleep(io, .fromMilliseconds(10), .awake) catch {};
    }

    try testz.expectTrue(listener.isKeyDown("a"));
    try testz.expectTrue(listener.isMouseButtonDown("left"));
    try testz.expectEqual(listener.cursorCell().row, 1);
    try testz.expectEqual(listener.cursorCell().col, 2);
    try testz.expectEqual(listener.cursorPixel().x, 12);
    try testz.expectEqual(listener.cursorPixel().y, 34);
}

fn serveOne(server: *glyphwire.server.Server, alloc: std.mem.Allocator) void {
    server.acceptOne(alloc) catch |err| {
        std.debug.print("test server connection failed: {t}\n", .{err});
    };
}
