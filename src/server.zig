const std = @import("std");
const core = @import("core.zig");
const wire = @import("wire.zig");
const dispatch = @import("dispatch.zig");
const rpc = @import("rpc.zig");

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
/// needed one process reporting input while others stay connected to
/// receive it). Fans out `key_down`/`key_up`/`mouse_button` notifications
/// to whichever connections subscribed -- see dispatch.zig's
/// `Subscriptions`/`Broadcast`.
///
/// Meant to be embedded, not just run standalone: whatever process owns
/// `ctx` can bind a `Server` alongside it and read/write `ctx` directly
/// (see `reportKey`/`reportMouseButton`/`reportMouseMove`, and `ctx`/
/// `ctx_mutex` below) while still serving other, separate client processes
/// over the socket the normal way -- glyphwire-host does exactly this: it
/// owns the `Context` and renders it directly, but glyphwire-shell (a
/// separate process, no pixzig dependency) still only ever sees it through
/// this wire protocol. `server/main.zig` is the headless case: a `Server`
/// with no in-process owner at all, just serving connections.
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
    /// Guards `connection_threads`. Separate from `registry_mutex`: that
    /// one is held for the duration of a `broadcast` fan-out, and `deinit`
    /// joining threads while holding the same lock a thread needs to reach
    /// `unregisterConnection` would deadlock.
    threads_mutex: std.Io.Mutex = .init,
    /// One handle per `serveConnectionThread` spawned by `serveForever`.
    /// Not touched by `acceptOne`/`serveOne`-style tests (their caller
    /// already owns and joins those threads directly) -- only `serveForever`
    /// spawns threads this struct itself is responsible for reaping. See
    /// `deinit`.
    connection_threads: std.ArrayList(std.Thread) = .empty,

    pub fn bind(io: std.Io, ctx: *core.Context, socket_path: []const u8) !Server {
        const addr = try std.Io.net.UnixAddress.init(socket_path);
        const listener = try addr.listen(io, .{});
        return .{ .io = io, .ctx = ctx, .listener = listener };
    }

    /// Joins every `serveForever`-spawned connection thread before freeing
    /// anything they touch (`connections`, and this `Server` itself once
    /// the caller's stack frame that owns it returns). Each such thread
    /// only returns once its connection's peer closes -- production usage
    /// (glyphwire-host) never calls `deinit` at all, so this only matters
    /// for tests, which close every client they spawned before reaching
    /// here; if a peer were still open this would hang, which is correct
    /// (a genuine bug, not something to paper over).
    pub fn deinit(self: *Server, alloc: std.mem.Allocator) void {
        self.threads_mutex.lockUncancelable(self.io);
        for (self.connection_threads.items) |t| t.join();
        self.connection_threads.deinit(alloc);
        self.threads_mutex.unlock(self.io);

        self.listener.deinit(self.io);
        self.connections.deinit(alloc);
    }

    /// Accepts connections forever, serving each one on its own thread so
    /// multiple clients can be connected at once. Each thread's handle is
    /// recorded in `connection_threads` so `deinit` can join it -- without
    /// that, a thread still unwinding through `unregisterConnection` after
    /// this `Server`'s owner has already moved on (a test function
    /// returning, freeing its stack-local `Server`) touches freed memory.
    pub fn serveForever(self: *Server, alloc: std.mem.Allocator) !void {
        while (true) {
            const stream = try self.listener.accept(self.io);
            const t = try std.Thread.spawn(.{}, serveConnectionThread, .{ self, alloc, stream });
            self.threads_mutex.lockUncancelable(self.io);
            try self.connection_threads.append(alloc, t);
            self.threads_mutex.unlock(self.io);
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

                // `load_image` is special: its JSON header frame declares a
                // raw byte count that follows directly on the wire, not
                // wrapped in another frame -- see wire.zig's `readRaw` and
                // decisions.md's binary side-channel framing. That payload
                // has to be pulled off this connection's stream (and
                // decoder buffer) before dispatch can respond, so it can't
                // go through `Dispatcher.handle`'s normal single-frame path.
                if (try dispatch.peekLoadImage(alloc, body)) |hdr| {
                    const raw = try wire.readRaw(self.io, &stream, &decoder, alloc, hdr.bytes);
                    defer alloc.free(raw);

                    const resp = blk: {
                        self.ctx_mutex.lockUncancelable(self.io);
                        defer self.ctx_mutex.unlock(self.io);
                        break :blk try d.handleLoadImage(alloc, hdr, raw);
                    };
                    defer alloc.free(resp);
                    try conn.send(self.io, resp);
                    continue;
                }

                const handle_result = blk: {
                    self.ctx_mutex.lockUncancelable(self.io);
                    defer self.ctx_mutex.unlock(self.io);
                    break :blk d.handle(alloc, body);
                };

                // A notification's dispatch error (e.g. draw_icon naming
                // an unregistered icon) has no response channel to report
                // on anyway -- log and move on rather than severing the
                // whole connection over it. A request's error still
                // propagates: see dispatch.zig's `isNotification` doc
                // comment for why.
                const result = handle_result catch |err| result: {
                    if (dispatch.isNotification(alloc, body) catch true) {
                        std.log.warn("glyphwire: notification failed: {t}", .{err});
                        break :result dispatch.HandleResult{};
                    }
                    return err;
                };
                conn.subscriptions = d.subscriptions;

                if (result.response) |r| {
                    defer alloc.free(r);
                    try conn.send(self.io, r);
                }
                if (result.broadcast) |b| {
                    defer alloc.free(b.body);
                    self.broadcast(&conn, b.event, b.body);
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

    /// Fans `body` out to every connection subscribed to `event`, except
    /// `sender` (null when the caller isn't itself a connection -- see
    /// `reportKey`/`reportMouseButton`, called by whatever process owns
    /// this `Server` in-process and captures input directly, e.g.
    /// glyphwire-host reading its own window's keyboard).
    fn broadcast(self: *Server, sender: ?*Connection, event: []const u8, body: []const u8) void {
        self.registry_mutex.lockUncancelable(self.io);
        defer self.registry_mutex.unlock(self.io);

        for (self.connections.items) |other| {
            if (sender != null and other == sender.?) continue;
            if (!other.subscriptions.has(event)) continue;
            other.send(self.io, body) catch |err| {
                std.log.err("glyphwire broadcast to a connection failed: {t}", .{err});
            };
        }
    }

    /// In-process equivalent of a connected client's `report_key` request
    /// (see dispatch.zig's `handleReportKey`) -- for whatever process owns
    /// this `Server` and its `Context` directly (glyphwire-host) to report
    /// input it captured itself, without a loopback connection to its own
    /// socket. Updates `ctx.input`'s down-set and, if that's a real
    /// change, broadcasts `key_down`/`key_up` to every subscribed
    /// connection.
    pub fn reportKey(self: *Server, alloc: std.mem.Allocator, key: []const u8, pressed: bool) !void {
        const changed = changed: {
            self.ctx_mutex.lockUncancelable(self.io);
            defer self.ctx_mutex.unlock(self.io);
            break :changed try self.ctx.input.setKey(key, pressed);
        };
        if (!changed) return;

        const body = try rpc.keyNotification(alloc, key, pressed);
        defer alloc.free(body);
        self.broadcast(null, "key", body);
    }

    /// Re-broadcasts `key_down` for an already-held `key`, for a caller
    /// driving its own typematic repeat (glyphwire-host's `App`, on an
    /// arrow key held past the initial delay). Deliberately doesn't touch
    /// `ctx.input`'s down-set: the key's already marked down from the
    /// original press, so routing this through `reportKey`/`setKey` would
    /// see no state change and silently swallow the repeat. Every
    /// subscriber just sees another `key_down` for the same key, same as
    /// `reportKey`'s -- no separate "this was a repeat" signal, since
    /// nothing here needs to tell the difference from a fresh press.
    pub fn reportKeyRepeat(self: *Server, alloc: std.mem.Allocator, key: []const u8) !void {
        const body = try rpc.keyRepeatNotification(alloc, key);
        defer alloc.free(body);
        self.broadcast(null, "key", body);
    }

    /// In-process equivalent of `report_mouse_button` -- see `reportKey`.
    /// `view_offset` is the root layer's current scrollback view offset
    /// (see `core.Layer.view_scroll`), carried through into the broadcast
    /// so a subscriber (glyphwire-shell) can resolve `cell` against the
    /// same scrolled-back row the user actually clicked.
    pub fn reportMouseButton(self: *Server, alloc: std.mem.Allocator, button: []const u8, pressed: bool, px: core.PxPos, cell: core.CellPos, view_offset: usize) !void {
        const changed = changed: {
            self.ctx_mutex.lockUncancelable(self.io);
            defer self.ctx_mutex.unlock(self.io);
            self.ctx.input.cursor_px = px;
            self.ctx.input.cursor_cell = cell;
            break :changed try self.ctx.input.setMouseButton(button, pressed);
        };
        if (!changed) return;

        const body = try rpc.mouseButtonNotification(alloc, button, pressed, px, cell, view_offset);
        defer alloc.free(body);
        self.broadcast(null, "mouse_button", body);
    }

    /// In-process scroll of the root layer's scrollback view (see
    /// `core.Layer.scrollView`) -- glyphwire-host's mouse wheel and
    /// scrollbar drive this directly rather than over a loopback
    /// connection, same pattern as `reportKey`/`reportResize`. `offset`
    /// (absolute target, rows) and/or `delta` (added after) are clamped
    /// internally to the retained history; omitting both is a no-op.
    /// Broadcasts a `scroll` notification (`{offset, max}`) to every
    /// `"scroll"` subscriber only when the value actually changes, so
    /// glyphwire-shell can keep its own view of the scroll state current
    /// (e.g. to snap back to the live tail when the user starts typing).
    /// Cheap to call every frame.
    pub fn reportScroll(self: *Server, alloc: std.mem.Allocator, offset: ?usize, delta: ?i64) !void {
        const result = blk: {
            self.ctx_mutex.lockUncancelable(self.io);
            defer self.ctx_mutex.unlock(self.io);
            const before = self.ctx.root.view_scroll;
            const after = self.ctx.root.scrollView(offset, delta);
            break :blk .{ .changed = before != after, .offset = after, .max = self.ctx.root.history_len };
        };
        if (!result.changed) return;

        const body = try rpc.scrollNotification(alloc, result.offset, result.max);
        defer alloc.free(body);
        self.broadcast(null, "scroll", body);
    }

    /// In-process equivalent of `report_mouse_move` -- see `reportKey`.
    /// Doesn't broadcast (no live move-event stream, matching
    /// `handleReportMouseMove`), just keeps `get_input_state`'s cursor
    /// fields current.
    pub fn reportMouseMove(self: *Server, px: core.PxPos, cell: core.CellPos) void {
        self.ctx_mutex.lockUncancelable(self.io);
        defer self.ctx_mutex.unlock(self.io);
        self.ctx.input.cursor_px = px;
        self.ctx.input.cursor_cell = cell;
    }

    /// Applies a new window size, in cells, to the context (resizing the
    /// root layer and every base-size-tracking layer -- see
    /// `Context.resize`) and, if that was a real change, broadcasts a
    /// `resize` notification (`{cols, rows}`) to every connection
    /// subscribed to `"resize"`. For the process that owns this `Server`
    /// and captures its own window events (glyphwire-host), same in-process
    /// path as `reportKey`. No broadcast when the size is unchanged, so
    /// this is cheap to call every frame.
    pub fn reportResize(self: *Server, alloc: std.mem.Allocator, cols: usize, rows: usize) !void {
        {
            self.ctx_mutex.lockUncancelable(self.io);
            defer self.ctx_mutex.unlock(self.io);
            if (cols == self.ctx.root.width and rows == self.ctx.root.height) return;
            try self.ctx.resize(cols, rows);
        }

        const body = try rpc.resizeNotification(alloc, cols, rows);
        defer alloc.free(body);
        self.broadcast(null, "resize", body);
    }
};
