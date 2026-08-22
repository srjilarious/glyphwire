const std = @import("std");
const testz = @import("testz");
const glyphwire = @import("glyphwire");
const wire = glyphwire.wire;

/// Milestone 7: proves the real glyphwire-shell / -server / -client
/// binaries work together as separate OS processes, not just as Zig
/// library calls composed in-process (already covered by
/// dispatch_tests.zig and server_tests.zig, including cell-buffer
/// content — there's no wire message to read cells back from a separate
/// process, only get_property("cursor")). This test supplies what those
/// can't: real process spawning, PATH resolution, and env-var
/// propagation through an actual exec chain, then confirms the result
/// the way an external program would have to — a second connection
/// calling get_property("cursor").
pub fn shellSpawnsServerAndExecsClientTest(_: std.Io, alloc: std.mem.Allocator) !void {
    // testz hands every test `global_single_threaded`'s Io, which uses a
    // deliberately failing allocator (fine for the socket-only tests
    // elsewhere in this suite, since raw socket syscalls need no
    // allocation) — but std.process.spawn needs a real arena internally
    // for argv/env blocks, so this test builds its own Io backed by a
    // real allocator instead of reusing the one testz passed in.
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const rio = threaded.io();

    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = try std.process.currentPath(rio, &cwd_buf);
    const bin_dir = try std.fmt.allocPrint(alloc, "{s}/zig-out/bin", .{cwd_buf[0..cwd_len]});
    defer alloc.free(bin_dir);
    const shell_path = try std.fmt.allocPrint(alloc, "{s}/glyphwire-shell", .{bin_dir});
    defer alloc.free(shell_path);

    // Replaces the child's environment outright (see SpawnOptions docs),
    // so only PATH needs to be present: it's what lets the shell binary
    // find `glyphwire-server` to spawn and `glyphwire-client` to exec.
    var environ_map = std.process.Environ.Map.init(alloc);
    defer environ_map.deinit();
    try environ_map.put("PATH", bin_dir);

    var child = try std.process.spawn(rio, .{
        .argv = &.{ shell_path, "glyphwire-client" },
        .environ_map = &environ_map,
        .stderr = .pipe,
    });

    // The server announces its socket path on stderr before the shell
    // execs into the client; read that line to learn where to connect.
    var stderr_buf: [4096]u8 = undefined;
    var stderr_reader = child.stderr.?.reader(rio, &stderr_buf);
    const announce_line = try stderr_reader.interface.takeDelimiterExclusive('\n');

    const prefix = "glyphwire server listening on ";
    try testz.expectTrue(std.mem.startsWith(u8, announce_line, prefix));
    const socket_path = try alloc.dupe(u8, announce_line[prefix.len..]);
    defer alloc.free(socket_path);
    defer std.Io.Dir.deleteFileAbsolute(rio, socket_path) catch {};
    // The server has no shutdown message yet (out of scope for this
    // slice); it outlives the shell/client and must be reaped explicitly.
    defer reapServer(rio, socket_path);

    const term = try child.wait(rio);
    switch (term) {
        .exited => |code| try testz.expectEqual(code, 0),
        else => return error.TestUnexpectedResult,
    }

    // A second, external inspector connection: exactly what a real
    // out-of-process caller would have to do to check state.
    const response_body = try requestCursor(rio, alloc, socket_path);
    defer alloc.free(response_body);

    const Response = struct {
        id: i64,
        result: struct { row: usize, col: usize },
    };
    const parsed = try std.json.parseFromSlice(Response, alloc, response_body, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    try testz.expectEqual(parsed.value.result.row, 0);
    try testz.expectEqual(parsed.value.result.col, 5);
}

fn requestCursor(io: std.Io, alloc: std.mem.Allocator, socket_path: []const u8) ![]u8 {
    const addr = try std.Io.net.UnixAddress.init(socket_path);
    var stream = try addr.connect(io);
    defer stream.close(io);

    var write_buf: [256]u8 = undefined;
    var w = stream.writer(io, &write_buf);
    try wire.writeFrame(&w.interface,
        \\{"jsonrpc":"2.0","id":1,"method":"get_property","params":{"property":"cursor"}}
    );
    try w.interface.flush();

    var decoder: wire.FrameDecoder = .{};
    defer decoder.deinit(alloc);

    var read_buf: [4096]u8 = undefined;
    while (true) {
        var data: [1][]u8 = .{&read_buf};
        const n = try stream.read(io, &data);
        if (n == 0) return error.ConnectionClosedBeforeResponse;

        try decoder.feed(alloc, read_buf[0..n]);
        if (try decoder.next(alloc)) |body| return body;
    }
}

fn reapServer(io: std.Io, socket_path: []const u8) void {
    var pkill = std.process.spawn(io, .{
        .argv = &.{ "pkill", "-f", socket_path },
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return;
    _ = pkill.wait(io) catch {};
}
