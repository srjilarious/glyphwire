const std = @import("std");
const testz = @import("testz");
const glyphwire = @import("glyphwire");
const wire = glyphwire.wire;

/// Proves real inter-process discovery still works end to end: a separately
/// spawned OS process (the real `glyphwire-demo` binary, not a library call)
/// finds a socket purely via the `GLYPHWIRE_SOCK` env var and writes several
/// styled `write_text` runs that land correctly in the server's `Context`.
///
/// Superseded milestone-7's `shellSpawnsServerAndExecsClientTest`, which
/// spawned `glyphwire-shell` itself and waited for it to exit. That no
/// longer applies: glyphwire-shell is now the pixzig-windowed renderer (see
/// slice_plan.md, Milestone 8) and stays open rendering the grid rather than
/// exiting after launching a child, so it can't be driven headlessly from a
/// test. The `Server`/discovery-env-var mechanism this test cares about is
/// unchanged, so it's exercised directly against a library-bound `Server`
/// instead of going through the shell binary.
pub fn demoClientWritesStyledTextOverRealSocketTest(_: std.Io, alloc: std.mem.Allocator) !void {
    // testz hands every test `global_single_threaded`'s Io, which uses a
    // deliberately failing allocator (fine for the socket-only tests
    // elsewhere in this suite, since raw socket syscalls need no
    // allocation) -- but std.process.spawn needs a real arena internally
    // for argv/env blocks, so this test builds its own Io backed by a real
    // allocator instead of reusing the one testz passed in.
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var ctx = try glyphwire.Context.init(alloc, 120, 50, 0);
    defer ctx.deinit();

    const socket_path = try std.fmt.allocPrint(alloc, "/tmp/glyphwire-e2e-test-{d}.sock", .{std.Thread.getCurrentId()});
    defer alloc.free(socket_path);
    defer std.Io.Dir.deleteFileAbsolute(io, socket_path) catch {};

    var srv = try glyphwire.server.Server.bind(io, &ctx, socket_path);
    defer srv.deinit();

    const thread = try std.Thread.spawn(.{}, serveOne, .{ &srv, alloc });

    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = try std.process.currentPath(io, &cwd_buf);
    const demo_path = try std.fmt.allocPrint(alloc, "{s}/zig-out/bin/glyphwire-demo", .{cwd_buf[0..cwd_len]});
    defer alloc.free(demo_path);

    var environ_map = std.process.Environ.Map.init(alloc);
    defer environ_map.deinit();
    try environ_map.put("GLYPHWIRE_SOCK", socket_path);

    var child = try std.process.spawn(io, .{
        .argv = &.{demo_path},
        .environ_map = &environ_map,
    });
    const term = try child.wait(io);
    switch (term) {
        .exited => |code| try testz.expectEqual(code, 0),
        else => return error.TestUnexpectedResult,
    }

    thread.join();

    // "glyphwire" written at row 0, col 0 in cyan (see demo/main.zig).
    const c00 = ctx.root.cell(0, 0);
    try testz.expectEqualStr("g", c00.grapheme());
    try testz.expectEqual(c00.style.fg.r, 0);
    try testz.expectEqual(c00.style.fg.g, 255);
    try testz.expectEqual(c00.style.fg.b, 255);

    // "colored text over pixzig" at row 2, col 0 with a navy background.
    const c20 = ctx.root.cell(2, 0);
    try testz.expectEqualStr("c", c20.grapheme());
    switch (c20.style.bg) {
        .color => |bg| {
            try testz.expectEqual(bg.r, 40);
            try testz.expectEqual(bg.g, 40);
            try testz.expectEqual(bg.b, 90);
        },
        .image => return error.TestUnexpectedResult,
    }

    // A bg-only color swatch (space glyph, red background) at row 6, col 0.
    const c60 = ctx.root.cell(6, 0);
    try testz.expectEqualStr(" ", c60.grapheme());
    switch (c60.style.bg) {
        .color => |bg| {
            try testz.expectEqual(bg.r, 255);
            try testz.expectEqual(bg.g, 85);
            try testz.expectEqual(bg.b, 85);
        },
        .image => return error.TestUnexpectedResult,
    }
}

fn serveOne(server: *glyphwire.server.Server, alloc: std.mem.Allocator) void {
    server.acceptOne(alloc) catch |err| {
        std.debug.print("test server connection failed: {t}\n", .{err});
    };
}
