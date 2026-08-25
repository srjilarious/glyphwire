const std = @import("std");
const core = @import("core.zig");
const wire = @import("wire.zig");
const dispatch = @import("dispatch.zig");

/// Tracks one accepted connection long enough for *other* connections'
/// dispatch to push a notification to it -- see `Server.broadcastToOthers`.
/// Lives on the stack frame of whichever call is serving it (`acceptOne`
/// or a `serveForever`-spawned thread), registered in `Server.connections`
/// for exactly that lifetime.
pub const Connection = struct {
    stream: std.Io.net.Stream,
    /// Guards writes to `stream`: this connection's own thread writes
    /// responses to its own requests, but another connection's dispatch
    /// may concurrently push a subscribed notification to it too.
    write_mutex: std.Io.Mutex = .init,
    /// Mirrors `Dispatcher.subscriptions` after each `handle` call --
    /// kept here (not read from the `Dispatcher`) so `broadcastToOthers`
    /// can consult it without needing a `Dispatcher` per connection.
    subscriptions: dispatch.Subscriptions = .{},

    fn send(self: *Connection, io: std.Io, body: []const u8) !void {
        self.write_mutex.lockUncancelable(io);
        defer self.write_mutex.unlock(io);

        var write_buf: [4096]u8 = undefined;
        var w = self.stream.writer(io, &write_buf);
        try wire.writeFrame(&w.interface, body);
        try w.interface.flush();
    }
};

/// A Unix-domain socket server serving one `Context` to any number of
/// concurrently connected clients, each on its own thread (Milestone 4
/// added the socket; concurrent connections were added once input events
/// needed one client -- glyphwire-host -- reporting input while others
/// stay connected to receive it). Fans out `key_down`/`key_up`/
/// `mouse_button` notifications to whichever connections subscribed --
/// see dispatch.zig's `Subscriptions`/`Broadcast`.
pub const Server = struct {
    io: std.Io,
    ctx: *core.Context,
    listener: std.Io.net.Server,
    /// Guards every `Dispatcher.handle` call: concurrent connections all
    /// dispatch against the same `Context`.
    ctx_mutex: std.Io.Mutex = .init,
    /// Guards `connections`: appended on accept, removed on disconnect,
    /// iterated (read-only) by `broadcastToOthers`.
    registry_mutex: std.Io.Mutex = .init,
    connections: std.ArrayList(*Connection) = .empty,

    pub fn bind(io: std.Io, ctx: *core.Context, socket_path: []const u8) !Server {
        const addr = try std.Io.net.UnixAddress.init(socket_path);
        const listener = try addr.listen(io, .{});
        return .{ .io = io, .ctx = ctx, .listener = listener };
    }

    pub fn deinit(self: *Server, alloc: std.mem.Allocator) void {
        self.listener.deinit(self.io);
        self.connections.deinit(alloc);
    }

    /// Accepts connections forever, serving each one on its own thread
    /// (not joined -- reaped on process exit, same as other background
    /// threads in this codebase) so multiple clients can be connected at
    /// once.
    pub fn serveForever(self: *Server, alloc: std.mem.Allocator) !void {
        while (true) {
            const stream = try self.listener.accept(self.io);
            _ = try std.Thread.spawn(.{}, serveConnectionThread, .{ self, alloc, stream });
        }
    }

    fn serveConnectionThread(self: *Server, alloc: std.mem.Allocator, stream: std.Io.net.Stream) void {
        self.serveConnection(alloc, stream) catch |err| {
            std.log.err("glyphwire connection error: {t}", .{err});
        };
    }

    /// Accepts and serves exactly one connection to completion, on the
    /// calling thread. Exposed separately from `serveForever` so tests can
    /// drive a known number of connections deterministically. Still
    /// registers the connection for broadcast fan-out, same as the
    /// threaded path, so tests can exercise `subscribe`/broadcast by
    /// driving two `acceptOne` calls on two threads.
    pub fn acceptOne(self: *Server, alloc: std.mem.Allocator) !void {
        const stream = try self.listener.accept(self.io);
        try self.serveConnection(alloc, stream);
    }

    fn serveConnection(self: *Server, alloc: std.mem.Allocator, stream_in: std.Io.net.Stream) !void {
        var stream = stream_in;
        defer stream.close(self.io);

        var conn: Connection = .{ .stream = stream };
        try self.registerConnection(alloc, &conn);
        defer self.unregisterConnection(&conn);

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

                const result = blk: {
                    self.ctx_mutex.lockUncancelable(self.io);
                    defer self.ctx_mutex.unlock(self.io);
                    break :blk try d.handle(alloc, body);
                };
                conn.subscriptions = d.subscriptions;

                if (result.response) |r| {
                    defer alloc.free(r);
                    try conn.send(self.io, r);
                }
                if (result.broadcast) |b| {
                    defer alloc.free(b.body);
                    self.broadcastToOthers(&conn, b.event, b.body);
                }
            }
        }
    }

    fn registerConnection(self: *Server, alloc: std.mem.Allocator, conn: *Connection) !void {
        self.registry_mutex.lockUncancelable(self.io);
        defer self.registry_mutex.unlock(self.io);
        try self.connections.append(alloc, conn);
    }

    fn unregisterConnection(self: *Server, conn: *Connection) void {
        self.registry_mutex.lockUncancelable(self.io);
        defer self.registry_mutex.unlock(self.io);
        if (std.mem.indexOfScalar(*Connection, self.connections.items, conn)) |idx| {
            _ = self.connections.swapRemove(idx);
        }
    }

    fn broadcastToOthers(self: *Server, sender: *Connection, event: []const u8, body: []const u8) void {
        self.registry_mutex.lockUncancelable(self.io);
        defer self.registry_mutex.unlock(self.io);

        for (self.connections.items) |other| {
            if (other == sender) continue;
            if (!other.subscriptions.has(event)) continue;
            other.send(self.io, body) catch |err| {
                std.log.err("glyphwire broadcast to a connection failed: {t}", .{err});
            };
        }
    }
};
