// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: MPL-2.0

const std = @import("std");
const core = @import("core.zig");
const wire = @import("wire.zig");
const dispatch = @import("dispatch.zig");
const rpc = @import("rpc.zig");
const codec = @import("codec.zig");
const runtime_dir = @import("runtime_dir.zig");
const protocol = @import("protocol.zig");
const conn_stream = @import("conn_stream.zig");
const host_api = @import("host_api.zig");

pub const ConnStream = conn_stream.ConnStream;

/// `Server.max_queued_bytes`'s default: 8 MiB per connection.
pub const default_max_queued_bytes: usize = 8 * 1024 * 1024;

/// Tracks one accepted connection long enough for *other* connections'
/// dispatch to push a notification to it -- see `Server.broadcastIn`.
/// Lives on the stack frame of whichever call is serving it (`acceptOne`
/// or a `serveForever`-spawned thread), registered in `Server.connections`
/// for exactly that lifetime.
///
/// Nothing writes to `stream` but the connection's writer thread
/// (`writerLoop`): `send` and `sendNative` only queue, so a sender never
/// blocks on a peer that has stopped reading -- not the host's input
/// thread, and not another client's dispatch holding `registry_mutex`.
/// See `out` for the limits.
///
/// Locking, field by field: the outbound queue (`out`, `out_bytes`,
/// `out_state`) is guarded by `out_mutex`; `route` and `focus_sent` are
/// read and written under
/// `Server.registry_mutex` (the connection's own thread may read `route`
/// without it, being its only writer); `format` is written once, by the
/// connection's own thread, before anything can read it (see `format`).
/// `alloc` and `id` never change.
pub const Connection = struct {
    stream: ConnStream,
    /// Held for `send`'s framing allocation (`wire.framedAlloc` for a
    /// mux-channel peer). The connection's serving call passes its own
    /// allocator in when it builds the `Connection`.
    alloc: std.mem.Allocator,
    /// This connection's identity for layer ownership (see `core.ConnId`),
    /// assigned from `Server.next_conn_id` when the connection is accepted.
    /// Handed to the connection's `Dispatcher` and, on disconnect, to
    /// `Context.removeConnectionOwnership` so any layer this connection
    /// solely owned is culled.
    id: core.ConnId,
    /// Bodies waiting for the writer thread, oldest first: this
    /// connection's own responses and everything pushed to it, in the
    /// order they were sent. Bounded by `Server.max_queued_bytes`: past
    /// that a `mouse_move` replaces or drops, and anything else
    /// disconnects the client (`enqueue`).
    out: std.ArrayList(Outgoing) = .empty,
    /// The bytes in `out`, for the bound.
    out_bytes: usize = 0,
    out_state: OutState = .open,
    out_mutex: std.Io.Mutex = .init,
    /// Signalled when `out` gains an entry or `out_state` leaves `.open`.
    out_cond: std.Io.Condition = .init,
    /// `Server.max_queued_bytes` when the connection was accepted.
    max_queued_bytes: usize,
    writer: ?std.Thread = null,
    /// What the fan-out reads to decide whether this connection gets a
    /// push. Guarded by `registry_mutex`, the lock every fan-out already
    /// holds while it walks `connections`.
    route: Route = .{},
    /// The last `focus` value sent to this connection (see
    /// `syncConnectionFocus`). Starts true: a client assumes it has focus
    /// until told otherwise, so a fresh one that does is sent nothing.
    /// Guarded by `registry_mutex`.
    focus_sent: bool = true,
    /// How this connection's bodies are encoded (see `wire.Format`), learnt
    /// from its first bytes. Settled before anything can be pushed to it:
    /// every push is gated on a subscription, subscribing takes a frame,
    /// and the `route` carrying that subscription is published under
    /// `registry_mutex` after this was set -- so any reader that sees a
    /// subscription sees the format too. Written only when it changes,
    /// which is on the first frame alone.
    format: wire.Format = .json,

    /// The copy of a connection's `Dispatcher` state that the fan-out
    /// needs, kept here so `broadcastIn` can filter without a `Dispatcher`
    /// per connection. One value rather than separate fields so it is
    /// published in one assignment under `registry_mutex` (`publishRoute`):
    /// a reader always sees the subscriptions and context of the same
    /// moment, never a stream the connection had already unsubscribed from
    /// next to the context it moved to afterwards.
    pub const Route = struct {
        /// `Dispatcher.subscriptions`.
        subscriptions: dispatch.Subscriptions = .{},
        /// `Dispatcher.active_ctx`: so a raw input event (`key` / `text` /
        /// `mouse_*`) can be withheld from a connection whose context isn't
        /// the one on screen in the focused pane, and a context-scoped one
        /// sent only to that context's clients. Starts at the root context
        /// (what a fresh connection inherits).
        active_ctx: core.ContextHandle = core.root_context_handle,
        /// `Dispatcher.attached()`: whether this connection may act on
        /// `active_ctx`. A connection that may not is pushed nothing at all
        /// -- no input, no layout, no selection -- so a process that merely
        /// reached the socket learns nothing about what is on screen until
        /// it presents a token. Starts false: a fresh connection is
        /// attached to nothing.
        attached: bool = false,

        /// `d`'s current route. Reads the session's membership tables
        /// (`attached`), so the caller holds `ctx_mutex`.
        fn of(d: *const dispatch.Dispatcher) Route {
            return .{ .subscriptions = d.subscriptions, .active_ctx = d.active_ctx, .attached = d.attached() };
        }

        fn eql(a: Route, b: Route) bool {
            return std.meta.eql(a, b);
        }
    };

    pub const OutState = enum {
        open,
        /// The connection is closing normally: the writer sends what is
        /// queued, then stops. Nothing more is accepted.
        stopping,
        /// The peer fell too far behind or a write failed: the queue is
        /// dropped and the stream shut down. Nothing more is accepted.
        dead,
    };

    const Outgoing = struct {
        body: []u8,
        kind: Kind,

        const Kind = enum {
            /// Already in the connection's format: a response.
            native,
            /// MessagePack, converted by the writer for a JSON connection.
            push,
            /// A `push` that a newer `mouse_move` may replace: only where
            /// the pointer is now matters.
            mouse_move,
        };
    };

    /// Queues a server-pushed message. `msgpack_body` is always
    /// MessagePack -- the `rpc.zig` builders make one body for every
    /// subscriber -- and the writer converts it for a JSON connection.
    pub fn send(self: *Connection, io: std.Io, msgpack_body: []const u8) !void {
        try self.enqueue(io, msgpack_body, .push);
    }

    /// `send` for a `mouse_move`, which replaces one still waiting in the
    /// queue rather than adding to it.
    pub fn sendMouseMove(self: *Connection, io: std.Io, msgpack_body: []const u8) !void {
        try self.enqueue(io, msgpack_body, .mouse_move);
    }

    /// Queues a body already in this connection's format -- a response its
    /// own `Dispatcher` encoded.
    fn sendNative(self: *Connection, io: std.Io, body: []const u8) !void {
        try self.enqueue(io, body, .native);
    }

    /// Adds a copy of `body` to the queue and wakes the writer. Never
    /// blocks on the peer. A connection that is closing drops it. Past
    /// `max_queued_bytes` a `mouse_move` is dropped, and anything else
    /// means the peer has stopped reading: the connection is cut off
    /// (`out_state = .dead`, the stream shut down so its reader returns)
    /// rather than left to grow without bound or to hold anyone up.
    fn enqueue(self: *Connection, io: std.Io, body: []const u8, kind: Outgoing.Kind) !void {
        self.out_mutex.lockUncancelable(io);
        defer self.out_mutex.unlock(io);
        if (self.out_state != .open) return;

        if (kind == .mouse_move and self.out.items.len > 0) {
            const last = &self.out.items[self.out.items.len - 1];
            if (last.kind == .mouse_move) {
                const copy = try self.alloc.dupe(u8, body);
                self.out_bytes = self.out_bytes - last.body.len + copy.len;
                self.alloc.free(last.body);
                last.body = copy;
                return;
            }
        }

        if (self.out.items.len > 0 and self.out_bytes + body.len > self.max_queued_bytes) {
            if (kind == .mouse_move) return;
            std.log.warn("glyphwire: connection {d} stopped reading ({d} bytes queued); disconnecting it", .{ self.id, self.out_bytes });
            self.cutOffLocked(io);
            return;
        }

        const copy = try self.alloc.dupe(u8, body);
        errdefer self.alloc.free(copy);
        try self.out.append(self.alloc, .{ .body = copy, .kind = kind });
        self.out_bytes += copy.len;
        self.out_cond.signal(io);
    }

    /// Drops the queue, marks the connection dead and shuts its stream
    /// down, which ends the reader's `read` (and any write the writer is
    /// blocked in). Caller holds `out_mutex`.
    fn cutOffLocked(self: *Connection, io: std.Io) void {
        self.out_state = .dead;
        self.freeQueueLocked();
        self.stream.shutdown(io);
        self.out_cond.broadcast(io);
    }

    fn freeQueueLocked(self: *Connection) void {
        for (self.out.items) |item| self.alloc.free(item.body);
        self.out.clearRetainingCapacity();
        self.out_bytes = 0;
    }

    /// Starts the writer thread. Paired with `stopWriter`.
    fn startWriter(self: *Connection, io: std.Io) !void {
        self.writer = try std.Thread.spawn(.{}, writerLoop, .{ self, io });
    }

    /// Stops accepting bodies, lets the writer send what is already
    /// queued, and waits for it. The connection must already be out of
    /// `Server.connections`, so nothing can be queued behind this.
    fn stopWriter(self: *Connection, io: std.Io) void {
        {
            self.out_mutex.lockUncancelable(io);
            defer self.out_mutex.unlock(io);
            if (self.out_state == .open) self.out_state = .stopping;
            self.out_cond.broadcast(io);
        }
        if (self.writer) |t| t.join();
        self.writer = null;
        self.out_mutex.lockUncancelable(io);
        defer self.out_mutex.unlock(io);
        self.freeQueueLocked();
        self.out.deinit(self.alloc);
    }

    /// The writer thread: takes everything queued at once and writes it
    /// outside `out_mutex`, so senders keep queueing (and `mouse_move`
    /// keeps replacing) while a slow peer drains. Ends once the connection
    /// is closing and the queue is empty, or on the first failed write.
    fn writerLoop(self: *Connection, io: std.Io) void {
        var batch: std.ArrayList(Outgoing) = .empty;
        defer batch.deinit(self.alloc);
        while (true) {
            {
                self.out_mutex.lockUncancelable(io);
                defer self.out_mutex.unlock(io);
                while (self.out.items.len == 0 and self.out_state == .open) {
                    self.out_cond.waitUncancelable(io, &self.out_mutex);
                }
                if (self.out.items.len == 0) return;
                std.mem.swap(std.ArrayList(Outgoing), &batch, &self.out);
                self.out_bytes = 0;
            }
            for (batch.items, 0..) |item, i| {
                self.writeOne(io, item) catch |err| {
                    std.log.warn("glyphwire: write to connection {d} failed: {t}", .{ self.id, err });
                    for (batch.items[i..]) |rest| self.alloc.free(rest.body);
                    batch.clearRetainingCapacity();
                    self.out_mutex.lockUncancelable(io);
                    defer self.out_mutex.unlock(io);
                    if (self.out_state != .dead) self.cutOffLocked(io);
                    return;
                };
                self.alloc.free(item.body);
            }
            batch.clearRetainingCapacity();
        }
    }

    fn writeOne(self: *Connection, io: std.Io, item: Outgoing) !void {
        const json: ?[]u8 = if (item.kind != .native and self.format == .json)
            try codec.msgpackToJson(self.alloc, item.body)
        else
            null;
        defer if (json) |j| self.alloc.free(j);
        const framed = try wire.framedAllocAs(self.alloc, self.format, json orelse item.body);
        defer self.alloc.free(framed);
        try self.stream.writeAll(io, framed);
    }
};

/// Whether `Server.lockSession` checks how `ctx_mutex` is taken: in the
/// builds with runtime safety, where a hung test is worth turning into a
/// failed assertion.
const track_locks = std.debug.runtime_safety;
/// This thread holds `ctx_mutex` (through `lockSession`).
threadlocal var session_held: bool = false;
/// How many locks ranked below `ctx_mutex` this thread holds.
threadlocal var below_session: u32 = 0;

/// Marks a lock ranked below `ctx_mutex` as taken on this thread, so a
/// `lockSession` under it fails its assertion instead of deadlocking
/// against a dispatcher holding the two the other way round. Pair with
/// `leaveBelowSession`. Free in builds without runtime safety.
pub fn enterBelowSession() void {
    if (track_locks) below_session += 1;
}

/// Undoes one `enterBelowSession`.
pub fn leaveBelowSession() void {
    if (track_locks) below_session -= 1;
}

/// A Unix-domain socket server serving one `Session` (its contexts and
/// panes) to any number of concurrently connected clients, each on its
/// own thread. Each connection's frames go through its own `Dispatcher`
/// under `ctx_mutex`; whatever a frame produces for other clients (input,
/// layout, selection, pane and context changes, ...) is fanned out to the
/// connections subscribed to it -- see dispatch.zig's `Subscriptions` /
/// `Broadcast` and `broadcastIn`'s delivery rules.
///
/// Meant to be embedded, not just run standalone: whatever process owns
/// `ctx` can bind a `Server` alongside it and read/write `ctx` directly
/// (see `reportKey`/`reportMouseButton`/`reportMouseMove`, and `ctx`/
/// `ctx_mutex` below) while still serving other, separate client processes
/// over the socket the normal way -- glyphwire-host does exactly this: it
/// owns the `Context` and renders it directly, but glyphwire-shell (a
/// separate process, no engine dependency) still only ever sees it through
/// this wire protocol. `server/main.zig` is the headless case: a `Server`
/// with no in-process owner at all, just serving connections.
pub const Server = struct {
    io: std.Io,
    /// Every context the server holds, and which one is visible (see
    /// `core.Session`). Owned by value: `bind` wraps the caller's root
    /// `Context` in a fresh single-context session, and `create_context`
    /// grows it.
    session: core.Session,
    /// The *focused* context: what is on screen in the focused pane, and
    /// therefore where raw input goes. A cached, always-live pointer into
    /// `session` (never null; the root pane's base context can't leave its
    /// stack). Re-pointed under `ctx_mutex` on every visibility or focus
    /// change.
    ///
    /// Most of the host wants exactly this one (the caret, selection, the
    /// in-process `report*` methods -- all of which follow focus), but it
    /// is not the *whole* window: the renderer composites every mapped
    /// pane's context, which it reaches through `session.panes`, not
    /// through here. Dispatch does not go through
    /// this either -- a connection acts on its own `Dispatcher.ctx`, which
    /// may be in another pane or backgrounded within its own.
    ctx: *core.Context,
    /// How `spawn_in_pane` starts a program, or null on a server that
    /// can't (see `dispatch.PaneSpawner`). Registered once at startup by
    /// whatever owns the window; stored by value so the pointer handed to
    /// each `Dispatcher` stays stable.
    pane_spawner: ?dispatch.PaneSpawner = null,
    /// How `start_remote` brings up a remote session, or null on a server
    /// that can't (see `dispatch.RemoteStarter`). Stored by value for the
    /// same reason as `pane_spawner`.
    remote_starter: ?dispatch.RemoteStarter = null,
    /// The focused pane as of the last `pane_focus` notification (see
    /// `reportPaneFocusIfChanged`). Guarded by `ctx_mutex`.
    reported_focus_pane: core.PaneHandle = core.root_pane_handle,
    /// Whether the host's window has the keyboard, as last reported by
    /// `reportFocus`. Half of what a connection's `focus` means -- see
    /// `syncConnectionFocus`. Guarded by `ctx_mutex`.
    window_focused: bool = true,
    listener: std.Io.net.Server,
    /// Guards `session` and `ctx`, and with them every `Dispatcher.handle`
    /// call: concurrent connections all dispatch against the same
    /// session. Taken only through `lockSession`.
    ctx_mutex: std.Io.Mutex = .init,
    /// Guards `connections`: appended on accept, removed on disconnect,
    /// iterated (read-only) by `broadcastToOthers`.
    registry_mutex: std.Io.Mutex = .init,
    connections: std.ArrayList(*Connection) = .empty,
    /// How many bytes may wait to be written to one connection before a
    /// further push (other than a `mouse_move`) disconnects it. Far more
    /// than any client that is reading falls behind by; a client stopped
    /// in a debugger, or wedged, reaches it and is let go rather than
    /// holding memory forever. Read when a connection is accepted.
    max_queued_bytes: usize = default_max_queued_bytes,
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
    /// Source of `Connection.id` values -- a plain monotonic counter,
    /// bumped once per accepted connection. Starts at 1 so 0 is never a
    /// live connection id. Atomic because `serveForever` accepts on one
    /// thread while `acceptOne` (tests) may run on another.
    next_conn_id: std.atomic.Value(core.ConnId) = .init(1),

    /// Optional "the context may have changed" hook. A front end that only
    /// draws on demand (glyphwire-host -- see decisions.md's "Redraw on
    /// change") registers one via `setWakeCallback` so a socket client's
    /// dispatch, which runs on that connection's own thread, can nudge the
    /// render loop out of its wait. Left null for the headless server and
    /// for any front end that repaints every frame regardless -- the
    /// server core never depends on it being set.
    wake_fn: ?*const fn (?*anyopaque) void = null,
    wake_ctx: ?*anyopaque = null,

    /// Registers the `setWakeCallback` hook described on `wake_fn`. Call it
    /// once at startup; `wake_ctx` is passed straight back to `wake_fn` on
    /// every invocation.
    pub fn setWakeCallback(self: *Server, wake_ctx: ?*anyopaque, wake_fn: *const fn (?*anyopaque) void) void {
        self.wake_ctx = wake_ctx;
        self.wake_fn = wake_fn;
    }

    /// Fires the registered wake hook, if any. Called after every frame a
    /// socket connection dispatches -- the in-process `report*` helpers
    /// below don't need it, since whatever calls those (the host's own
    /// update loop) re-checks its redraw state the same iteration anyway.
    /// A spurious wake (a read-only `get_cells`, say) is harmless: the
    /// front end just re-evaluates and goes back to waiting.
    pub fn wake(self: *Server) void {
        if (self.wake_fn) |f| f(self.wake_ctx);
    }

    /// `ctx_mutex`, held; `unlock` lets it go. What `lockSession`
    /// returns, so the usual shape is
    ///
    ///     const session_lock = server.lockSession();
    ///     defer session_lock.unlock();
    ///
    /// and then `server.session` / `server.ctx` are safe to read and
    /// write until the block ends.
    pub const SessionLock = struct {
        server: *Server,

        pub fn unlock(self: SessionLock) void {
            if (track_locks) session_held = false;
            self.server.ctx_mutex.unlock(self.server.io);
        }
    };

    /// Takes `ctx_mutex`, the lock over `session` and `ctx`. Every taker
    /// goes through here -- the dispatcher, the in-process API, and
    /// glyphwire-host reading the session directly -- so who holds it is
    /// one grep, and debug builds can check how it is taken:
    ///
    /// - not twice on one thread (`std.Io.Mutex` isn't reentrant, so that
    ///   is a hang, not a recursion);
    /// - not while holding a lock ranked below it. **Lock order:
    ///   `ctx_mutex` first.** A lock the dispatcher can reach with
    ///   `ctx_mutex` held (glyphwire-host's `PaneProcs.mutex`, under
    ///   `dispatch.PaneSpawner`) is taken after it or not at all, and its
    ///   holder says so with `enterBelowSession` / `leaveBelowSession`.
    pub fn lockSession(self: *Server) SessionLock {
        if (track_locks) {
            std.debug.assert(!session_held);
            std.debug.assert(below_session == 0);
        }
        self.ctx_mutex.lockUncancelable(self.io);
        if (track_locks) session_held = true;
        return .{ .server = self };
    }

    /// `ctx` becomes the session's root context (handle
    /// `core.root_context_handle`). The caller keeps ownership of its
    /// memory -- `Session.deinit` frees only the contexts
    /// `create_context` adds.
    pub fn bind(io: std.Io, ctx: *core.Context, socket_path: []const u8) !Server {
        const addr = try std.Io.net.UnixAddress.init(socket_path);
        const listener = try addr.listen(io, .{});
        runtime_dir.restrictSocket(socket_path);
        const session = try core.Session.init(ctx.alloc, ctx);
        return .{ .io = io, .session = session, .ctx = ctx, .listener = listener };
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
        // Frees every `create_context` context and the session's own
        // bookkeeping; the root context is the caller's to deinit.
        self.session.deinit();
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
            const t = try std.Thread.spawn(.{}, serveConnectionThread, .{ self, alloc, ConnStream{ .net = stream } });
            self.threads_mutex.lockUncancelable(self.io);
            try self.connection_threads.append(alloc, t);
            self.threads_mutex.unlock(self.io);
        }
    }

    fn serveConnectionThread(self: *Server, alloc: std.mem.Allocator, stream: ConnStream) void {
        self.serveConnection(alloc, stream, null) catch |err| {
            std.log.err("glyphwire connection error: {t}", .{err});
        };
    }

    /// Serves one already-connected peer to completion, on the calling
    /// thread -- no `accept`. The host's remote-session demux calls this
    /// per `gw-agent` trunk channel (`stream` = `.channel`), so a remote
    /// `gw-shell` / `gw-ls` / `zoe` drives this `Server`'s context exactly
    /// as a local socket client would.
    ///
    /// The peer starts with access to `grant` -- the context the remote
    /// session was seated on. The user let the session in by logging in
    /// over `ssh`; making every remote program also carry the context's
    /// token would only put that secret on a machine that doesn't need it.
    pub fn servePreconnected(self: *Server, alloc: std.mem.Allocator, stream: ConnStream, grant: core.ContextHandle) !void {
        try self.serveConnection(alloc, stream, grant);
    }

    /// Accepts and serves exactly one connection to completion, on the
    /// calling thread. Exposed separately from `serveForever` so tests can
    /// drive a known number of connections deterministically. Still
    /// registers the connection for broadcast fan-out, same as the
    /// threaded path, so tests can exercise `subscribe`/broadcast by
    /// driving two `acceptOne` calls on two threads.
    pub fn acceptOne(self: *Server, alloc: std.mem.Allocator) !void {
        const stream = try self.listener.accept(self.io);
        try self.serveConnection(alloc, ConnStream{ .net = stream }, null);
    }

    fn serveConnection(self: *Server, alloc: std.mem.Allocator, stream_in: ConnStream, grant: ?core.ContextHandle) !void {
        var stream = stream_in;
        defer stream.close(self.io);

        var conn: Connection = .{
            .stream = stream,
            .alloc = alloc,
            .id = self.next_conn_id.fetchAdd(1, .monotonic),
            .max_queued_bytes = self.max_queued_bytes,
        };
        // Deferred in this order so they run as: leave the registry (no
        // one can queue to it after), flush and stop the writer, close.
        try conn.startWriter(self.io);
        defer conn.stopWriter(self.io);
        try self.registerConnection(alloc, &conn);
        defer self.unregisterConnection(alloc, &conn);

        // `initForConnection` reads the pane table to start this
        // connection in the focused pane -- take `ctx_mutex` so it can't
        // race another connection's `create_context` / `create_pane`. A
        // program seated in a specific pane immediately retargets itself
        // with `attach_pane`, which, being its first message, is ordered
        // ahead of everything else it sends.
        var d = blk: {
            const session_lock = self.lockSession();
            defer session_lock.unlock();
            const sp: ?*const dispatch.PaneSpawner = if (self.pane_spawner) |*s| s else null;
            const rs: ?*const dispatch.RemoteStarter = if (self.remote_starter) |*s| s else null;
            var d = dispatch.Dispatcher.initForConnection(&self.session, conn.id, sp, rs);
            if (grant) |g| {
                try self.session.addContextMember(g, conn.id);
                d.ctx = self.session.contextPtr(g).?;
                d.active_ctx = g;
                d.active_pane = d.ctx.pane;
            }
            break :blk d;
        };
        // Published outside `ctx_mutex`: the fan-out takes `ctx_mutex`
        // inside `registry_mutex` (`reportContextSizes`), so taking them
        // the other way round here could deadlock. Until this lands the
        // connection reads as unattached and is pushed nothing, which is
        // what it is.
        {
            const route = blk: {
                const session_lock = self.lockSession();
                defer session_lock.unlock();
                break :blk Connection.Route.of(&d);
            };
            self.publishRoute(&conn, route);
        }
        var decoder: wire.FrameDecoder = .{ .detect = true };
        defer decoder.deinit(alloc);

        var read_buf: [4096]u8 = undefined;
        while (true) {
            const n = try stream.read(self.io, &read_buf);
            if (n == 0) return; // peer closed the connection

            try decoder.feed(alloc, read_buf[0..n]);

            while (try decoder.next(alloc)) |body| {
                defer alloc.free(body);
                // The first frame settled the format; every later one
                // re-asserts it for free.
                d.format = decoder.format;
                if (conn.format != decoder.format) conn.format = decoder.format;

                // Decoded once, here: the envelope's `id` and `method` are
                // what decide how a failure is reported below, and the
                // dispatcher takes the same envelope rather than parsing
                // the body again. An unparseable body is a failed message
                // of unknown kind -- logged, connection kept.
                const parsed = codec.parseEnvelope(d.format, alloc, body) catch |err| {
                    std.log.warn("glyphwire: unparseable message: {t}", .{err});
                    continue;
                };
                defer parsed.deinit();
                const envelope = parsed.value;

                // `load_image` / `update_image` are special. On JSON the
                // header declares a raw byte count that follows directly
                // on the wire, not wrapped in another frame -- see
                // wire.zig's `readRaw` and decisions.md's binary
                // side-channel framing -- so that payload has to be pulled
                // off this connection's stream (and decoder buffer) before
                // dispatch can respond. On MessagePack the bytes are
                // inside the message already (`hdr.data`).
                if (try dispatch.imagePayloadHeader(alloc, envelope)) |hdr| {
                    const raw = if (hdr.data) |data| data else try wire.readRaw(self.io, &stream, &decoder, alloc, hdr.bytes);
                    defer if (hdr.data == null) alloc.free(raw);

                    const resp = blk: {
                        const session_lock = self.lockSession();
                        defer session_lock.unlock();
                        break :blk d.handleLoadImage(alloc, hdr, raw) catch |err| {
                            std.log.warn("glyphwire: request '{s}' failed: {t}", .{ envelope.method, err });
                            break :blk try codec.errorResponse(d.format, alloc, envelope.id orelse .null, dispatch.errorCode(err), @errorName(err));
                        };
                    };
                    defer alloc.free(resp);
                    try conn.sendNative(self.io, resp);
                    self.wake();
                    continue;
                }

                const handle_result, const route = blk: {
                    const session_lock = self.lockSession();
                    defer session_lock.unlock();
                    const r = d.handleEnvelope(alloc, envelope);
                    // A `create_context` / `activate_context` /
                    // `destroy_context` / `focus_pane` in this frame may
                    // have moved the focused context -- keep `self.ctx`
                    // (the host's caret/selection view and the in-process
                    // `report*` path) pointing at it.
                    self.ctx = self.session.focusedContext();
                    // Read here, under the lock: `attached()` consults the
                    // session's membership tables.
                    break :blk .{ r, Connection.Route.of(&d) };
                };

                // A notification's dispatch error (e.g. draw_icon naming
                // an unregistered icon) has no response channel to report
                // on -- log and move on rather than severing the whole
                // connection over it. A request's is answered with a
                // JSON-RPC error response, and the connection carries on
                // just the same.
                const result = handle_result catch |err| result: {
                    if (envelope.id) |id| {
                        std.log.warn("glyphwire: request '{s}' failed: {t}", .{ envelope.method, err });
                        const err_body = try codec.errorResponse(d.format, alloc, id, dispatch.errorCode(err), @errorName(err));
                        defer alloc.free(err_body);
                        try conn.sendNative(self.io, err_body);
                    } else {
                        std.log.warn("glyphwire: notification '{s}' failed: {t}", .{ envelope.method, err });
                    }
                    break :result dispatch.HandleResult{};
                };
                // Before the response and any broadcast this frame
                // produced, so a client told "subscribed" is already
                // routed as subscribed.
                self.publishRoute(&conn, route);

                if (result.response) |r| {
                    defer alloc.free(r);
                    try conn.sendNative(self.io, r);
                }
                if (result.broadcast) |b| {
                    defer alloc.free(b.body);
                    const scope: ?core.ContextHandle = if (b.event.route().delivery == .context_scoped) d.active_ctx else null;
                    self.broadcastIn(&conn, scope, b.event, b.body);
                    // A `destroy_context` / `activate_context` put another
                    // context on screen. One backgrounded through a window
                    // resize had its tree re-laid-out silently on the way
                    // up (`Session.republish`), so it's owed a `layout` --
                    // the same follow-up the disconnect-cull path sends.
                    if (b.event == .context) {
                        self.reportLayout(alloc) catch |err| {
                            std.log.err("glyphwire: layout after context switch failed: {t}", .{err});
                        };
                    }
                }
                if (result.broadcast_after) |b| {
                    defer alloc.free(b.body);
                    const scope: ?core.ContextHandle = if (b.event.route().delivery == .context_scoped) d.active_ctx else null;
                    self.broadcastIn(&conn, scope, b.event, b.body);
                }
                // A pane-tree edit reshaped the window: re-lay-out, tell
                // the manager the new rects, and tell every *other* client
                // its own context changed size. Done after the response so
                // the manager's `create_pane` handle arrives before the
                // `pane_layout` mentioning it.
                if (result.panes_changed) {
                    self.applyPaneLayout(alloc) catch |err| {
                        std.log.err("glyphwire: pane relayout failed: {t}", .{err});
                    };
                }
                self.reportPaneFocusIfChanged(alloc) catch |err| {
                    std.log.err("glyphwire: pane_focus failed: {t}", .{err});
                };
                self.syncConnectionFocus(alloc) catch |err| {
                    std.log.err("glyphwire: focus failed: {t}", .{err});
                };
                self.wake();
            }
        }
    }

    fn registerConnection(self: *Server, alloc: std.mem.Allocator, conn: *Connection) !void {
        self.registry_mutex.lockUncancelable(self.io);
        defer self.registry_mutex.unlock(self.io);
        try self.connections.append(alloc, conn);
    }

    /// Makes `route` what the fan-out sees for `conn`. Called by `conn`'s
    /// own thread, its only writer, which is why the unlocked comparison
    /// is safe: most frames change nothing, and they skip the lock.
    fn publishRoute(self: *Server, conn: *Connection, route: Connection.Route) void {
        if (conn.route.eql(route)) return;
        self.registry_mutex.lockUncancelable(self.io);
        defer self.registry_mutex.unlock(self.io);
        conn.route = route;
    }

    fn unregisterConnection(self: *Server, alloc: std.mem.Allocator, conn: *Connection) void {
        {
            self.registry_mutex.lockUncancelable(self.io);
            defer self.registry_mutex.unlock(self.io);
            if (std.mem.indexOfScalar(*Connection, self.connections.items, conn)) |idx| {
                _ = self.connections.swapRemove(idx);
            }
        }

        // Cull any layer this connection solely owned. A crashed or
        // killed client's socket is closed by the kernel, so this is the
        // one path that reaps the layers a program left behind when it
        // died without calling `destroy_layer` -- see decisions.md's
        // Layer ownership & lifecycle section.
        var culled: std.ArrayList(core.LayerHandle) = .empty;
        defer culled.deinit(alloc);
        var culled_ctx: std.ArrayList(core.ContextHandle) = .empty;
        defer culled_ctx.deinit(alloc);
        var culled_panes: std.ArrayList(core.PaneHandle) = .empty;
        defer culled_panes.deinit(alloc);
        var context_switched = false;
        {
            const session_lock = self.lockSession();
            defer session_lock.unlock();
            // Layers this connection solely owned, across *every* context
            // (a client may have created layers on more than one).
            var it = self.session.contexts.valueIterator();
            while (it.next()) |ctx| {
                ctx.*.removeConnectionOwnership(conn.id, &culled) catch |err| {
                    std.log.err("glyphwire: layer cull for closed connection {d} failed: {t}", .{ conn.id, err });
                };
            }
            // Images stay -- a picture drawn by a program that has since
            // exited is the normal case (`glyphwire-view` loads, draws and
            // exits) -- but they lose their pin, so the scrollback sweep
            // can reclaim them once they scroll away. See
            // `core.Context.releaseImages`.
            self.session.releaseImages(conn.id);
            // Then contexts this connection solely owned -- destroying one
            // takes its layers/splits/tables with it. An on-screen context
            // going this way pops its pane's stack back to whatever was
            // under it: the alt-screen auto-restore on a program's exit,
            // now at pane scope. Panes the connection created as window
            // manager go too, and the window-manager role is released so
            // the next multiplexer can claim it.
            const visible_before = self.session.focusedContextHandle();
            self.session.reapConnection(conn.id, &culled_ctx, &culled_panes) catch |err| {
                std.log.err("glyphwire: context cull for closed connection {d} failed: {t}", .{ conn.id, err });
            };
            // A pane that just went away had programs running in it; stop
            // them rather than leaving orphans writing to a freed context.
            if (self.pane_spawner) |*sp| {
                for (culled_panes.items) |h| sp.kill(h);
            }
            self.ctx = self.session.focusedContext();
            context_switched = self.session.focusedContextHandle() != visible_before or
                culled_panes.items.len > 0;
        }
        for (culled.items) |h| {
            std.log.debug("glyphwire: culled orphaned layer {d} (owning connection {d} closed)", .{ h, conn.id });
        }
        for (culled_ctx.items) |h| {
            std.log.debug("glyphwire: culled orphaned context {d} (owning connection {d} closed)", .{ h, conn.id });
        }
        for (culled_panes.items) |h| {
            std.log.debug("glyphwire: culled pane {d} (its window manager, connection {d}, closed)", .{ h, conn.id });
        }
        if (culled_panes.items.len > 0) {
            self.applyPaneLayout(alloc) catch |err| {
                std.log.err("glyphwire: pane relayout after cull failed: {t}", .{err});
            };
        }
        if (context_switched) {
            self.reportContext(alloc) catch |err| {
                std.log.err("glyphwire: context notification after cull failed: {t}", .{err});
            };
            // The program underneath (the shell zoe was started from) is
            // the one being typed into again.
            self.syncConnectionFocus(alloc) catch |err| {
                std.log.err("glyphwire: focus after context cull failed: {t}", .{err});
            };
            // The restored context may have missed a window resize while
            // it was backgrounded -- re-lay-out its tree against the
            // current size now that it's the one on screen.
            self.reportLayout(alloc) catch |err| {
                std.log.err("glyphwire: layout after context cull failed: {t}", .{err});
            };
        }
        // A culled context may have been the last thing holding a pane
        // open after its program exited (glyphwire-host's
        // `PaneProcs.pump`), and an idle host is parked until woken.
        if (culled_ctx.items.len > 0) self.wake();
    }

    /// Fans `body` out to every connection subscribed to `event`, except
    /// `sender` (null when the caller isn't itself a connection -- see
    /// `reportKey`/`reportMouseButton`, called by whatever process owns
    /// this `Server` in-process and captures input directly, e.g.
    /// glyphwire-host reading its own window's keyboard).
    pub fn broadcast(self: *Server, sender: ?*Connection, event: dispatch.PushEvent, body: []const u8) void {
        self.broadcastIn(sender, null, event, body);
    }

    /// `broadcast`, limited to connections whose context is `scope` when
    /// one is given. For an event that names a layer: layer handles are
    /// per-context, so a `scroll_offset` or `layout` for layer 3 fanned
    /// out to every pane also moved whatever layer 3 happened to be in
    /// each other pane's program (a second zoe in another pane dragging
    /// the first one's shell panel to its own rows). Null `scope` is plain
    /// `broadcast`.
    pub fn broadcastIn(self: *Server, sender: ?*Connection, scope: ?core.ContextHandle, event: dispatch.PushEvent, body: []const u8) void {
        self.registry_mutex.lockUncancelable(self.io);
        defer self.registry_mutex.unlock(self.io);

        // Each event's `dispatch.Delivery` (`PushEvent.route`) decides who
        // among its stream's subscribers gets it.
        //
        // `focus_gated` (raw input) reaches only the connection whose
        // context is on screen *in the focused pane*. Two things are being
        // excluded at once: a backgrounded full-screen editor (its context
        // isn't on screen in its own pane), and every program in an
        // unfocused pane (its context is perfectly visible, but the
        // keystrokes aren't for it). This single test is what replaces
        // addressing input to individual layers. A pane is a real
        // addressable object with its own visibility, so "who gets this
        // keystroke" is answerable here, once, from state the session
        // already maintains -- rather than needing a multiplexer to relay
        // every keystroke on to its panes.
        //
        // `fan_out` events (`pane_layout`, `selection`, `context`, ...) go
        // to every subscriber, `context_scoped` ones to all of one
        // context's: a backgrounded or unfocused client wants to know its
        // panes moved so it can redraw before it's shown again.
        // `focused_context` is the lock-free denormalised copy of the
        // focused pane's stack top.
        //
        // A `window_manager` event is addressed, not fanned out. Re-routed
        // here rather than only at the `report*` call sites, so a window
        // command can never be broadcast no matter which path produced it
        // (the in-process input loop, or a client's `report_key` /
        // `report_text`).
        const rule = event.route().delivery;
        if (rule == .window_manager) {
            self.deliverToManagerLocked(event, body);
            return;
        }

        const focused = self.session.focused_context.load(.monotonic);

        for (self.connections.items) |other| {
            if (sender != null and other == sender.?) continue;
            if (!other.route.attached) continue;
            if (!other.route.subscriptions.has(event)) continue;
            switch (rule) {
                .focus_gated => if (other.route.active_ctx != focused) continue,
                // `scope` is the context the event came from, which only
                // the caller knows; an unscoped call is a plain fan-out.
                .context_scoped => if (scope) |s| if (other.route.active_ctx != s) continue,
                // `addressed` events are sent by their own methods and
                // never reach here; fanning one out is the harmless reading.
                .fan_out, .addressed => {},
                .window_manager => unreachable,
            }
            const sent = if (event == .mouse_move) other.sendMouseMove(self.io, body) else other.send(self.io, body);
            sent catch |err| {
                std.log.err("glyphwire broadcast to a connection failed: {t}", .{err});
            };
        }
    }

    /// Sends `body` to the window-manager connection only. The targeted
    /// counterpart of `broadcast`, for the two events that are addressed
    /// rather than fanned out (`window_key_down` / `window_key_up` /
    /// `window_text`): a window
    /// command has exactly one recipient by definition.
    pub fn deliverToManager(self: *Server, event: dispatch.PushEvent, body: []const u8) void {
        self.registry_mutex.lockUncancelable(self.io);
        defer self.registry_mutex.unlock(self.io);
        self.deliverToManagerLocked(event, body);
    }

    /// `deliverToManager` with `registry_mutex` already held -- what
    /// `broadcast` uses when it re-routes a window event it was handed.
    fn deliverToManagerLocked(self: *Server, event: dispatch.PushEvent, body: []const u8) void {
        // The role is held by both of a manager's connections (see
        // `core.Session.managers`); only the one that subscribed to the
        // window stream wants this, which is its `InputListener`.
        for (self.session.manager_conns) |slot| {
            const target = slot.load(.monotonic);
            if (target == 0) continue;
            for (self.connections.items) |conn| {
                if (conn.id != target) continue;
                if (!conn.route.subscriptions.has(event)) continue;
                conn.send(self.io, body) catch |err| {
                    std.log.err("glyphwire: window command to the manager failed: {t}", .{err});
                };
            }
        }
    }

    // The in-process API, in host_api.zig.
    pub const visibleContextGen = host_api.visibleContextGen;
    pub const mouseSelectAllowed = host_api.mouseSelectAllowed;
    pub const mouseReportOn = host_api.mouseReportOn;
    pub const reportContext = host_api.reportContext;
    pub const setPaneSpawner = host_api.setPaneSpawner;
    pub const setRemoteStarter = host_api.setRemoteStarter;
    pub const paneLayoutGen = host_api.paneLayoutGen;
    pub const PaneAtCell = host_api.PaneAtCell;
    pub const paneAtCell = host_api.paneAtCell;
    pub const focusedCell = host_api.focusedCell;
    pub const focusedCellClamped = host_api.focusedCellClamped;
    pub const focusPaneAt = host_api.focusPaneAt;
    pub const focusPane = host_api.focusPane;
    pub const syncConnectionFocus = host_api.syncConnectionFocus;
    pub const reportPaneFocusIfChanged = host_api.reportPaneFocusIfChanged;
    pub const activateContext = host_api.activateContext;
    pub const createShellContext = host_api.createShellContext;
    pub const destroyShellContext = host_api.destroyShellContext;
    pub const setWindowTheme = host_api.setWindowTheme;
    pub const applyPaneLayout = host_api.applyPaneLayout;
    pub const reportPaneExit = host_api.reportPaneExit;
    pub const reportRemoteExit = host_api.reportRemoteExit;
    pub const reportKey = host_api.reportKey;
    pub const reportKeyTapIn = host_api.reportKeyTapIn;
    pub const reportWheelTapIn = host_api.reportWheelTapIn;
    pub const reportKeyRepeat = host_api.reportKeyRepeat;
    pub const reportText = host_api.reportText;
    pub const reportMouseButton = host_api.reportMouseButton;
    pub const reportScroll = host_api.reportScroll;
    pub const reportScrollIn = host_api.reportScrollIn;
    pub const reportLayerScroll = host_api.reportLayerScroll;
    pub const reportLayerScrollIn = host_api.reportLayerScrollIn;
    pub const reportMouseMove = host_api.reportMouseMove;
    pub const reportResize = host_api.reportResize;
    pub const reportFontStep = host_api.reportFontStep;
    pub const reportFocus = host_api.reportFocus;
    pub const reportShutdown = host_api.reportShutdown;
    pub const reportLayout = host_api.reportLayout;
    pub const reportLayerResize = host_api.reportLayerResize;
    pub const reportScrollOffset = host_api.reportScrollOffset;
    pub const reportScrollOffsetIn = host_api.reportScrollOffsetIn;
    pub const setSelection = host_api.setSelection;
    pub const clearSelection = host_api.clearSelection;
    pub const clearOtherSelections = host_api.clearOtherSelections;
    pub const clearAllSelections = host_api.clearAllSelections;
    pub const anySelectionText = host_api.anySelectionText;
    pub const selectedLayer = host_api.selectedLayer;
    pub const selectionText = host_api.selectionText;
    pub const selectionUnitAt = host_api.selectionUnitAt;
    pub const setClipboard = host_api.setClipboard;
    pub const requestCopy = host_api.requestCopy;
    pub const broadcastPaste = host_api.broadcastPaste;
    pub const clipboardSerial = host_api.clipboardSerial;
    pub const clipboardText = host_api.clipboardText;
};
