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

pub fn clientClearWipesTheWholeLayerByDefaultTest(io: std.Io, alloc: std.mem.Allocator) !void {
    var ctx = try glyphwire.Context.init(alloc, 10, 3, 0);
    defer ctx.deinit();

    const socket_path = try std.fmt.allocPrint(alloc, "/tmp/glyphwire-client-test-{d}.sock", .{std.Thread.getCurrentId()});
    defer alloc.free(socket_path);
    defer std.Io.Dir.deleteFileAbsolute(io, socket_path) catch {};

    var srv = try glyphwire.server.Server.bind(io, &ctx, socket_path);
    defer srv.deinit(alloc);

    const thread = try std.Thread.spawn(.{}, serveOne, .{ &srv, alloc });
    defer thread.join();

    var client = try glyphwire.Client.connect(io, alloc, socket_path);
    defer client.deinit();

    try client.writeText("hi", null, null);
    try client.clear(0, 0, null, null);

    var snapshot = try client.getCells();
    defer snapshot.deinit();
    try testz.expectEqualStr("", snapshot.cellAt(0, 0).grapheme);
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

/// `Client.default_layer` retargets every root-implicit method (see its
/// doc comment) onto a non-root layer instead -- what `glyphwire-shell`
/// sets from `GLYPHWIRE_LAYER` to run embedded in a `gmux` pane. Checks
/// both write and read paths land on the target layer, and that the root
/// layer is left completely untouched.
pub fn clientDefaultLayerRetargetsRootImplicitCallsTest(io: std.Io, alloc: std.mem.Allocator) !void {
    var ctx = try glyphwire.Context.init(alloc, 10, 3, 0);
    defer ctx.deinit();
    const pane = try ctx.createLayer(6, 2, 0);

    const socket_path = try std.fmt.allocPrint(alloc, "/tmp/glyphwire-client-test-{d}.sock", .{std.Thread.getCurrentId()});
    defer alloc.free(socket_path);
    defer std.Io.Dir.deleteFileAbsolute(io, socket_path) catch {};

    var srv = try glyphwire.server.Server.bind(io, &ctx, socket_path);
    defer srv.deinit(alloc);

    const thread = try std.Thread.spawn(.{}, serveOne, .{ &srv, alloc });
    errdefer thread.join();

    var client = try glyphwire.Client.connect(io, alloc, socket_path);
    errdefer client.deinit();
    client.default_layer = pane;

    const size = try client.getSize();
    try testz.expectEqual(size.cols, 6);
    try testz.expectEqual(size.rows, 2);

    try client.writeText("hi", null, null);
    const cursor = try client.getCursor();
    try testz.expectEqual(cursor.row, 0);
    try testz.expectEqual(cursor.col, 2);

    try client.setCursor(1, 0);
    try client.writeText("x", null, null);
    try client.clear(0, 0, 1, null);

    client.deinit();
    thread.join();

    try testz.expectEqualStr("", ctx.layerPtr(pane).?.cell(0, 0).grapheme());
    try testz.expectEqualStr("x", ctx.layerPtr(pane).?.cell(1, 0).grapheme());
    // The root layer never saw any of it.
    try testz.expectEqualStr("", ctx.root.cell(0, 0).grapheme());
    try testz.expectEqualStr("", ctx.root.cell(1, 0).grapheme());
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
    try reporter.reportMouseButton("left", true, .{ .x = 12, .y = 34 }, .{ .row = 1, .col = 2 }, 0);

    // The listener's background thread updates asynchronously, and the key
    // and mouse-button reports are two separate notifications -- polling
    // only until the first lands doesn't guarantee the second has too, so
    // wait for both.
    var attempts: usize = 0;
    while (!(listener.isKeyDown("a") and listener.isMouseButtonDown("left")) and attempts < 100) : (attempts += 1) {
        std.Io.sleep(io, .fromMilliseconds(10), .awake) catch {};
    }

    try testz.expectTrue(listener.isKeyDown("a"));
    try testz.expectTrue(listener.isMouseButtonDown("left"));
    try testz.expectEqual(listener.cursorCell().row, 1);
    try testz.expectEqual(listener.cursorCell().col, 2);
    try testz.expectEqual(listener.cursorPixel().x, 12);
    try testz.expectEqual(listener.cursorPixel().y, 34);
}

/// `isMouseButtonDown`/`cursorCell` (above) are level state -- this proves
/// the separate edge-event queue (`pollMouseButtonEvent`, mirroring
/// `pollKeyEvent`) a click handler (glyphwire-shell's mouse-driven
/// auto-cd) actually needs also gets populated, with both the press and
/// the release queued as distinct events in order.
pub fn inputListenerQueuesMouseButtonEventsTest(_: std.Io, alloc: std.mem.Allocator) !void {
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

    const thread1 = try std.Thread.spawn(.{}, serveOne, .{ &srv, alloc });
    defer thread1.join();
    const thread2 = try std.Thread.spawn(.{}, serveOne, .{ &srv, alloc });
    defer thread2.join();

    const listener = try glyphwire.InputListener.connect(io, alloc, socket_path, &.{"mouse_button"});
    defer listener.deinit();

    var reporter = try glyphwire.Client.connect(io, alloc, socket_path);
    defer reporter.deinit();
    try reporter.reportMouseButton("left", true, .{ .x = 5, .y = 9 }, .{ .row = 2, .col = 3 }, 0);
    try reporter.reportMouseButton("left", false, .{ .x = 5, .y = 9 }, .{ .row = 2, .col = 3 }, 0);

    var press: ?glyphwire.client.MouseButtonEvent = null;
    var attempts: usize = 0;
    while (press == null and attempts < 100) : (attempts += 1) {
        press = listener.pollMouseButtonEvent();
        if (press == null) std.Io.sleep(io, .fromMilliseconds(10), .awake) catch {};
    }
    try testz.expectTrue(press != null);
    defer alloc.free(press.?.button);
    try testz.expectEqualStr(press.?.button, "left");
    try testz.expectTrue(press.?.pressed);
    try testz.expectEqual(press.?.cell.row, 2);
    try testz.expectEqual(press.?.cell.col, 3);

    var release: ?glyphwire.client.MouseButtonEvent = null;
    attempts = 0;
    while (release == null and attempts < 100) : (attempts += 1) {
        release = listener.pollMouseButtonEvent();
        if (release == null) std.Io.sleep(io, .fromMilliseconds(10), .awake) catch {};
    }
    try testz.expectTrue(release != null);
    defer alloc.free(release.?.button);
    try testz.expectTrue(!release.?.pressed);
}

/// The `text` stream: a `Client.reportText` on one connection reaches a
/// `"text"`-subscribed `InputListener` on another as a queued `TextEvent`,
/// with a multi-byte (CJK) payload intact -- the whole point of the
/// separate stream, since that grapheme is not derivable from a key name.
pub fn inputListenerQueuesTextEventsTest(_: std.Io, alloc: std.mem.Allocator) !void {
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

    const thread1 = try std.Thread.spawn(.{}, serveOne, .{ &srv, alloc });
    defer thread1.join();
    const thread2 = try std.Thread.spawn(.{}, serveOne, .{ &srv, alloc });
    defer thread2.join();

    const listener = try glyphwire.InputListener.connect(io, alloc, socket_path, &.{"text"});
    defer listener.deinit();

    var reporter = try glyphwire.Client.connect(io, alloc, socket_path);
    defer reporter.deinit();
    try reporter.reportText("a\u{3042}b"); // "a", HIRAGANA A, "b"

    var ev: ?glyphwire.InputEvent = null;
    var attempts: usize = 0;
    while (ev == null and attempts < 100) : (attempts += 1) {
        ev = listener.pollInputEvent();
        if (ev == null) std.Io.sleep(io, .fromMilliseconds(10), .awake) catch {};
    }
    try testz.expectTrue(ev != null);
    defer ev.?.deinit(alloc);
    try testz.expectTrue(ev.? == .text);
    try testz.expectEqualStr(ev.?.text.text, "a\u{3042}b");
}

/// A minimal byte stream `pngDimensions` accepts -- see core_tests.zig's
/// identical fixture. Exercises `Client.loadImage` over a real socket, the
/// one path that needs the binary side-channel's raw-byte framing (see
/// wire.zig's `readRaw`/`takeRaw`) rather than plain JSON-RPC frames.
fn fakePngBytes(width: u32, height: u32) [24]u8 {
    var bytes: [24]u8 = undefined;
    @memcpy(bytes[0..8], &[_]u8{ 0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n' });
    std.mem.writeInt(u32, bytes[8..12], 13, .big);
    @memcpy(bytes[12..16], "IHDR");
    std.mem.writeInt(u32, bytes[16..20], width, .big);
    std.mem.writeInt(u32, bytes[20..24], height, .big);
    return bytes;
}

pub fn clientLoadImageDrawImageRoundTripTest(io: std.Io, alloc: std.mem.Allocator) !void {
    var ctx = try glyphwire.Context.init(alloc, 10, 10, 0);
    defer ctx.deinit();

    const socket_path = try std.fmt.allocPrint(alloc, "/tmp/glyphwire-client-test-{d}.sock", .{std.Thread.getCurrentId()});
    defer alloc.free(socket_path);
    defer std.Io.Dir.deleteFileAbsolute(io, socket_path) catch {};

    var srv = try glyphwire.server.Server.bind(io, &ctx, socket_path);
    defer srv.deinit(alloc);

    // Same connection makes every call below, so one acceptOne suffices --
    // see clientWriteTextThenGetCellsRoundTripTest.
    const thread = try std.Thread.spawn(.{}, serveOne, .{ &srv, alloc });
    defer thread.join();

    var client = try glyphwire.Client.connect(io, alloc, socket_path);
    defer client.deinit();

    const metrics = try client.getCellMetrics();
    try testz.expectEqual(metrics.w, 12);
    try testz.expectEqual(metrics.h, 12);

    // 24x12px = exactly a 2x1-cell span at the session's 12px cells.
    const png = fakePngBytes(24, 12);
    const handle = try client.loadImage("png", &png);
    try testz.expectEqual(handle, 1);

    const info = try client.getImageInfo(handle);
    try testz.expectEqual(info.width, 24);
    try testz.expectEqual(info.height, 12);

    try client.drawImage(handle, 0, 0, 1, 2, 1.0);

    var snapshot = try client.getCells();
    defer snapshot.deinit();

    const c00 = snapshot.cellAt(0, 0);
    try testz.expectTrue(c00.bg == null);
    try testz.expectEqual(c00.bg_image.?.handle, handle);
    try testz.expectEqual(c00.bg_image.?.offset_x, 0);
    try testz.expectEqual(c00.bg_image.?.scale, 1.0);

    const c01 = snapshot.cellAt(0, 1);
    try testz.expectEqual(c01.bg_image.?.offset_x, 12);

    // Sending a normal notification right after `load_image`'s raw
    // payload proves the decoder correctly resumed normal frame parsing
    // afterward, rather than the raw bytes bleeding into the next frame's
    // header -- see wire.zig's `takeRaw` leaving any excess buffered.
    try client.writeText("z", null, null);
    const cursor = try client.getCursor();
    try testz.expectEqual(cursor.col, 1);
}

/// A request-form `Client.Batch` (it used a request adder) sends one
/// frame, reads one response, and hands back each sub-request's result
/// keyed by the slot it returned at add time.
pub fn clientBatchRequestFormReturnsSlottedResultsTest(io: std.Io, alloc: std.mem.Allocator) !void {
    var ctx = try glyphwire.Context.init(alloc, 20, 4, 0);
    defer ctx.deinit();

    const socket_path = try std.fmt.allocPrint(alloc, "/tmp/glyphwire-client-test-{d}.sock", .{std.Thread.getCurrentId()});
    defer alloc.free(socket_path);
    defer std.Io.Dir.deleteFileAbsolute(io, socket_path) catch {};

    var srv = try glyphwire.server.Server.bind(io, &ctx, socket_path);
    defer srv.deinit(alloc);
    const thread = try std.Thread.spawn(.{}, serveOne, .{ &srv, alloc });
    defer thread.join();

    var client = try glyphwire.Client.connect(io, alloc, socket_path);
    defer client.deinit();

    var b = client.batch();
    defer b.deinit();
    const slot_a = try b.createMetadata("{\"path\":\"/a\"}");
    try b.writeText("hi", null, null);
    const slot_b = try b.createMetadata("{\"path\":\"/b\"}");
    var results = try b.send();
    defer results.deinit();

    const handle_a = try results.metadataHandle(slot_a);
    const handle_b = try results.metadataHandle(slot_b);
    try testz.expectTrue(handle_a != handle_b);
    try testz.expectEqualStr("{\"path\":\"/a\"}", ctx.metadataJson(handle_a).?);
    try testz.expectEqualStr("{\"path\":\"/b\"}", ctx.metadataJson(handle_b).?);

    // The batched `write_text` applied too.
    try testz.expectEqualStr("h", ctx.root.cell(0, 0).grapheme());
}

/// A notification-form `Client.Batch` (no request adders) sends one
/// frame and returns immediately -- no response is read -- with every
/// sub-message applied in order.
pub fn clientBatchNotificationFormAppliesWithoutReplyTest(io: std.Io, alloc: std.mem.Allocator) !void {
    var ctx = try glyphwire.Context.init(alloc, 20, 4, 0);
    defer ctx.deinit();

    const socket_path = try std.fmt.allocPrint(alloc, "/tmp/glyphwire-client-test-{d}.sock", .{std.Thread.getCurrentId()});
    defer alloc.free(socket_path);
    defer std.Io.Dir.deleteFileAbsolute(io, socket_path) catch {};

    var srv = try glyphwire.server.Server.bind(io, &ctx, socket_path);
    defer srv.deinit(alloc);
    const thread = try std.Thread.spawn(.{}, serveOne, .{ &srv, alloc });
    defer thread.join();

    var client = try glyphwire.Client.connect(io, alloc, socket_path);
    defer client.deinit();

    {
        var b = client.batch();
        defer b.deinit();
        try b.writeText("one", null, null);
        try b.setCursor(2, 1);
        try b.writeText("two", null, null);
        var results = try b.send();
        results.deinit();
    }

    // A following request on the same connection still round-trips, so
    // `send` didn't leave an unread response frame on the socket.
    const cursor = try client.getCursor();
    try testz.expectEqual(cursor.row, 2);
    try testz.expectEqual(cursor.col, 4);
    try testz.expectEqualStr("o", ctx.root.cell(0, 0).grapheme());
    try testz.expectEqualStr("t", ctx.root.cell(2, 1).grapheme());
}

/// `Batch.clear` wipes cells mid-batch, ordered with the surrounding
/// sub-messages: a `clear` then a `write_text` over the same row in one
/// batch leaves only the rewritten text. This is the primitive the
/// shell's prompt redraw leans on -- clear stale prompt rows, then
/// redraw over them, in one frame.
pub fn clientBatchClearThenRedrawInOneBatchTest(io: std.Io, alloc: std.mem.Allocator) !void {
    var ctx = try glyphwire.Context.init(alloc, 20, 4, 0);
    defer ctx.deinit();

    const socket_path = try std.fmt.allocPrint(alloc, "/tmp/glyphwire-client-test-{d}.sock", .{std.Thread.getCurrentId()});
    defer alloc.free(socket_path);
    defer std.Io.Dir.deleteFileAbsolute(io, socket_path) catch {};

    var srv = try glyphwire.server.Server.bind(io, &ctx, socket_path);
    defer srv.deinit(alloc);
    const thread = try std.Thread.spawn(.{}, serveOne, .{ &srv, alloc });
    defer thread.join();

    var client = try glyphwire.Client.connect(io, alloc, socket_path);
    defer client.deinit();

    // Seed two rows outside the batch.
    try client.setCursor(0, 0);
    try client.writeText("stale-left", null, null);
    try client.setCursor(1, 0);
    try client.writeText("keep-me", null, null);

    {
        var b = client.batch();
        defer b.deinit();
        // Wipe just row 0, then redraw a shorter string over it.
        try b.clear(0, 0, 1, null);
        try b.setCursor(0, 0);
        try b.writeText("new", null, null);
        var results = try b.send();
        results.deinit();
    }

    // A round trip forces the server to have applied the notification-form
    // batch before the assertions read `ctx.root` directly.
    _ = try client.getCursor();

    // Row 0: cleared then partly rewritten; the old tail is gone.
    try testz.expectEqualStr(ctx.root.cell(0, 0).grapheme(), "n");
    try testz.expectEqualStr(ctx.root.cell(0, 4).grapheme(), "");
    // Row 1: untouched by a single-row clear.
    try testz.expectEqualStr(ctx.root.cell(1, 0).grapheme(), "k");
}

/// `Client`'s selection and clipboard methods round-trip over a real
/// socket: set a selection, read its text back, then set/get the
/// clipboard.
pub fn clientSelectionAndClipboardRoundTripTest(io: std.Io, alloc: std.mem.Allocator) !void {
    var ctx = try glyphwire.Context.init(alloc, 20, 4, 0);
    defer ctx.deinit();

    const socket_path = try std.fmt.allocPrint(alloc, "/tmp/glyphwire-client-test-{d}.sock", .{std.Thread.getCurrentId()});
    defer alloc.free(socket_path);
    defer std.Io.Dir.deleteFileAbsolute(io, socket_path) catch {};

    var srv = try glyphwire.server.Server.bind(io, &ctx, socket_path);
    defer srv.deinit(alloc);
    const thread = try std.Thread.spawn(.{}, serveOne, .{ &srv, alloc });
    defer thread.join();

    var client = try glyphwire.Client.connect(io, alloc, socket_path);
    defer client.deinit();

    try client.writeText("hello world", null, null);

    const none = try client.getSelection(null);
    try testz.expectTrue(!none.active);

    try client.setSelection(null, .{ .above = 0, .col = 0 }, .{ .above = 0, .col = 5 });
    const some = try client.getSelection(null);
    try testz.expectTrue(some.active);
    try testz.expectEqual(some.active_end.?.col, 5);

    const sel_text = try client.getSelectionText(null);
    defer alloc.free(sel_text);
    try testz.expectEqualStr("hello", sel_text);

    try client.clearSelection(null);
    const cleared = try client.getSelection(null);
    try testz.expectTrue(!cleared.active);

    try client.setClipboard("board contents");
    const clip = try client.getClipboard();
    defer alloc.free(clip);
    try testz.expectEqualStr("board contents", clip);
}

/// A layer created over a connection is culled when that connection
/// closes without `destroy_layer` -- the crash-recovery path from
/// decisions.md's Layer ownership & lifecycle section. Joining the server
/// thread is the barrier: `acceptOne` only returns once `serveConnection`
/// has fully unwound, and the disconnect cull runs in that unwind, so the
/// assertion afterward is race-free.
pub fn clientLayerCulledWhenCreatorDisconnectsTest(io: std.Io, alloc: std.mem.Allocator) !void {
    var ctx = try glyphwire.Context.init(alloc, 10, 3, 0);
    defer ctx.deinit();

    const socket_path = try std.fmt.allocPrint(alloc, "/tmp/glyphwire-client-test-{d}.sock", .{std.Thread.getCurrentId()});
    defer alloc.free(socket_path);
    defer std.Io.Dir.deleteFileAbsolute(io, socket_path) catch {};

    var srv = try glyphwire.server.Server.bind(io, &ctx, socket_path);
    defer srv.deinit(alloc);

    const thread = try std.Thread.spawn(.{}, serveOne, .{ &srv, alloc });
    errdefer thread.join();

    {
        var client = try glyphwire.Client.connect(io, alloc, socket_path);
        errdefer client.deinit();

        const h = try client.createLayer(6, 2, 0);
        try testz.expectEqual(h, 1);

        // The program dies without cleaning up after itself.
        client.deinit();
    }

    thread.join();

    try testz.expectEqual(ctx.layers.count(), 0);
    try testz.expectTrue(ctx.layerPtr(1) == null);
}

fn serveOne(server: *glyphwire.server.Server, alloc: std.mem.Allocator) void {
    server.acceptOne(alloc) catch |err| {
        std.debug.print("test server connection failed: {t}\n", .{err});
    };
}
