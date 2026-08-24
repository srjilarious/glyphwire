const std = @import("std");
const core = @import("core.zig");
const wire = @import("wire.zig");
const dispatch = @import("dispatch.zig");

/// A Unix-domain socket server serving one `Context` to any number of
/// client connections, one at a time (Milestone 4: real IPC — accept, read
/// frames, dispatch, write frames back. No concurrent connections,
/// multiple contexts, or capability negotiation yet).
pub const Server = struct {
    io: std.Io,
    ctx: *core.Context,
    listener: std.Io.net.Server,
    /// Optional lock held around each dispatched message. Needed when the
    /// `Context` is also read concurrently by something outside this
    /// server's own thread (e.g. a renderer running the socket server
    /// in-process on a background thread while its own game loop reads
    /// `ctx` every frame). Null keeps single-threaded callers (unit tests,
    /// the standalone `glyphwire-server` binary) lock-free.
    mutex: ?*std.Io.Mutex = null,

    pub fn bind(io: std.Io, ctx: *core.Context, socket_path: []const u8) !Server {
        const addr = try std.Io.net.UnixAddress.init(socket_path);
        const listener = try addr.listen(io, .{});
        return .{ .io = io, .ctx = ctx, .listener = listener };
    }

    pub fn deinit(self: *Server) void {
        self.listener.deinit(self.io);
    }

    /// Accepts connections forever, serving each one to completion (until
    /// the peer disconnects) before accepting the next.
    pub fn serveForever(self: *Server, alloc: std.mem.Allocator) !void {
        while (true) try self.acceptOne(alloc);
    }

    /// Accepts and serves exactly one connection to completion. Exposed
    /// separately from `serveForever` so tests can drive a known number of
    /// connections deterministically.
    pub fn acceptOne(self: *Server, alloc: std.mem.Allocator) !void {
        var stream = try self.listener.accept(self.io);
        defer stream.close(self.io);
        try self.serveConnection(alloc, &stream);
    }

    fn serveConnection(self: *Server, alloc: std.mem.Allocator, stream: *std.Io.net.Stream) !void {
        var d = dispatch.Dispatcher.init(self.ctx);
        var decoder: wire.FrameDecoder = .{};
        defer decoder.deinit(alloc);

        var read_buf: [4096]u8 = undefined;
        while (true) {
            var data: [1][]u8 = .{&read_buf};
            const n = try stream.read(self.io, &data);
            if (n == 0) return; // peer closed the connection

            try decoder.feed(alloc, read_buf[0..n]);

            while (try decoder.next(alloc)) |body| {
                defer alloc.free(body);
                const response = if (self.mutex) |m| blk: {
                    m.lockUncancelable(self.io);
                    defer m.unlock(self.io);
                    break :blk try d.handle(alloc, body);
                } else try d.handle(alloc, body);

                if (response) |r| {
                    defer alloc.free(r);
                    try self.sendFrame(stream, r);
                }
            }
        }
    }

    fn sendFrame(self: *Server, stream: *std.Io.net.Stream, body: []const u8) !void {
        var write_buf: [4096]u8 = undefined;
        var w = stream.writer(self.io, &write_buf);
        try wire.writeFrame(&w.interface, body);
        try w.interface.flush();
    }
};
