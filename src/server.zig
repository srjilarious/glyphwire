const std = @import("std");
const core = @import("core.zig");
const wire = @import("wire.zig");
const dispatch = @import("dispatch.zig");
const rpc = @import("rpc.zig");
const protocol = @import("protocol.zig");
const conn_stream = @import("conn_stream.zig");

pub const ConnStream = conn_stream.ConnStream;

/// Tracks one accepted connection long enough for *other* connections'
/// dispatch to push a notification to it -- see `Server.broadcastToOthers`.
/// Lives on the stack frame of whichever call is serving it (`acceptOne`
/// or a `serveForever`-spawned thread), registered in `Server.connections`
/// for exactly that lifetime.
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
    /// Guards writes to `stream`: this connection's own thread writes
    /// responses to its own requests, but another connection's dispatch
    /// may concurrently push a subscribed notification to it too.
    write_mutex: std.Io.Mutex = .init,
    /// Mirrors `Dispatcher.subscriptions` after each `handle` call --
    /// kept here (not read from the `Dispatcher`) so `broadcastToOthers`
    /// can consult it without needing a `Dispatcher` per connection.
    subscriptions: dispatch.Subscriptions = .{},
    /// Mirrors `Dispatcher.active_ctx` after each `handle` call, same as
    /// `subscriptions` -- so `broadcast` can withhold a raw input event
    /// (`key`/`text`/`mouse_*`) from a connection whose context isn't the
    /// one currently visible. Starts at the root context (what a fresh
    /// connection inherits).
    active_ctx: core.ContextHandle = core.root_context_handle,
    /// Mirrors `Dispatcher.active_pane`, same as `active_ctx`. What
    /// `reportResize` uses to send each connection *its own pane's* size
    /// rather than the window's.
    active_pane: core.PaneHandle = core.root_pane_handle,

    fn send(self: *Connection, io: std.Io, body: []const u8) !void {
        self.write_mutex.lockUncancelable(io);
        defer self.write_mutex.unlock(io);

        const framed = try wire.framedAlloc(self.alloc, body);
        defer self.alloc.free(framed);
        try self.stream.writeAll(io, framed);
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
    /// Before panes this also meant "the only thing on screen", and most
    /// of the host still wants exactly this one (the caret, selection, the
    /// in-process `report*` methods -- all of which follow focus). What
    /// changed is that it is no longer the *whole* window: the renderer
    /// composites every mapped pane's context, which it reaches through
    /// `session.panes`, not through here. Dispatch does not go through
    /// this either -- a connection acts on its own `Dispatcher.ctx`, which
    /// may be in another pane or backgrounded within its own.
    ctx: *core.Context,
    /// How `spawn_in_pane` starts a program, or null on a server that
    /// can't (see `dispatch.PaneSpawner`). Registered once at startup by
    /// whatever owns the window; stored by value so the pointer handed to
    /// each `Dispatcher` stays stable.
    pane_spawner: ?dispatch.PaneSpawner = null,
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
    fn wake(self: *Server) void {
        if (self.wake_fn) |f| f(self.wake_ctx);
    }

    /// `ctx` becomes the session's root context (handle
    /// `core.root_context_handle`). The caller keeps ownership of its
    /// memory -- `Session.deinit` frees only the contexts
    /// `create_context` adds.
    pub fn bind(io: std.Io, ctx: *core.Context, socket_path: []const u8) !Server {
        const addr = try std.Io.net.UnixAddress.init(socket_path);
        const listener = try addr.listen(io, .{});
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
        self.serveConnection(alloc, stream) catch |err| {
            std.log.err("glyphwire connection error: {t}", .{err});
        };
    }

    /// Serves one already-connected peer to completion, on the calling
    /// thread -- no `accept`. The host's remote-session demux calls this
    /// per `gw-agent` trunk channel (`stream` = `.channel`), so a remote
    /// `gw-shell` / `gw-ls` / `zoe` drives this `Server`'s context exactly
    /// as a local socket client would.
    pub fn servePreconnected(self: *Server, alloc: std.mem.Allocator, stream: ConnStream) !void {
        try self.serveConnection(alloc, stream);
    }

    /// Accepts and serves exactly one connection to completion, on the
    /// calling thread. Exposed separately from `serveForever` so tests can
    /// drive a known number of connections deterministically. Still
    /// registers the connection for broadcast fan-out, same as the
    /// threaded path, so tests can exercise `subscribe`/broadcast by
    /// driving two `acceptOne` calls on two threads.
    pub fn acceptOne(self: *Server, alloc: std.mem.Allocator) !void {
        const stream = try self.listener.accept(self.io);
        try self.serveConnection(alloc, ConnStream{ .net = stream });
    }

    fn serveConnection(self: *Server, alloc: std.mem.Allocator, stream_in: ConnStream) !void {
        var stream = stream_in;
        defer stream.close(self.io);

        var conn: Connection = .{ .stream = stream, .alloc = alloc, .id = self.next_conn_id.fetchAdd(1, .monotonic) };
        try self.registerConnection(alloc, &conn);
        defer self.unregisterConnection(alloc, &conn);

        // `initForConnection` reads the pane table to start this
        // connection in the focused pane -- take `ctx_mutex` so it can't
        // race another connection's `create_context` / `create_pane`. A
        // program seated in a specific pane immediately retargets itself
        // with `attach_pane`, which, being its first message, is ordered
        // ahead of everything else it sends.
        var d = blk: {
            self.ctx_mutex.lockUncancelable(self.io);
            defer self.ctx_mutex.unlock(self.io);
            const sp: ?*const dispatch.PaneSpawner = if (self.pane_spawner) |*s| s else null;
            break :blk dispatch.Dispatcher.initForConnection(&self.session, conn.id, sp);
        };
        var decoder: wire.FrameDecoder = .{};
        defer decoder.deinit(alloc);

        var read_buf: [4096]u8 = undefined;
        while (true) {
            const n = try stream.read(self.io, &read_buf);
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
                    self.wake();
                    continue;
                }

                const handle_result = blk: {
                    self.ctx_mutex.lockUncancelable(self.io);
                    defer self.ctx_mutex.unlock(self.io);
                    const r = d.handle(alloc, body);
                    // A `create_context` / `activate_context` /
                    // `destroy_context` / `focus_pane` in this frame may
                    // have moved the focused context -- keep `self.ctx`
                    // (the host's caret/selection view and the in-process
                    // `report*` path) pointing at it.
                    self.ctx = self.session.focusedContext();
                    break :blk r;
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
                conn.active_ctx = d.active_ctx;
                conn.active_pane = d.active_pane;

                if (result.response) |r| {
                    defer alloc.free(r);
                    try conn.send(self.io, r);
                }
                if (result.broadcast) |b| {
                    defer alloc.free(b.body);
                    self.broadcast(&conn, b.event, b.body);
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
                self.wake();
            }
        }
    }

    fn registerConnection(self: *Server, alloc: std.mem.Allocator, conn: *Connection) !void {
        self.registry_mutex.lockUncancelable(self.io);
        defer self.registry_mutex.unlock(self.io);
        try self.connections.append(alloc, conn);
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
            self.ctx_mutex.lockUncancelable(self.io);
            defer self.ctx_mutex.unlock(self.io);
            // Layers this connection solely owned, across *every* context
            // (a client may have created layers on more than one).
            var it = self.session.contexts.valueIterator();
            while (it.next()) |ctx| {
                ctx.*.removeConnectionOwnership(conn.id, &culled) catch |err| {
                    std.log.err("glyphwire: layer cull for closed connection {d} failed: {t}", .{ conn.id, err });
                };
            }
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
            // The restored context may have missed a window resize while
            // it was backgrounded -- re-lay-out its tree against the
            // current size now that it's the one on screen.
            self.reportLayout(alloc) catch |err| {
                std.log.err("glyphwire: layout after context cull failed: {t}", .{err});
            };
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

        // Raw input streams reach only the connection whose context is on
        // screen *in the focused pane*. Two things are being excluded at
        // once: a backgrounded full-screen editor (its context isn't on
        // screen in its own pane), and every program in an unfocused pane
        // (its context is perfectly visible, but the keystrokes aren't
        // for it).
        //
        // This single test is what replaces addressing input to individual
        // layers. A pane is a real addressable object with its own
        // visibility, so "who gets this keystroke" is answerable here,
        // once, from state the session already maintains -- rather than
        // needing a multiplexer to relay every keystroke on to its panes.
        //
        // Every other event (`resize`, `layout`, `pane_layout`, `scroll`,
        // `selection`, `context`, ...) still fans out to all subscribers:
        // a backgrounded or unfocused client wants to know its panes moved
        // so it can redraw before it's shown again. `focused_context` is
        // the lock-free denormalised copy of the focused pane's stack top.
        const gated = isFocusGatedEvent(event);
        const focused = self.session.focused_context.load(.monotonic);

        for (self.connections.items) |other| {
            if (sender != null and other == sender.?) continue;
            if (!other.subscriptions.has(event)) continue;
            if (gated and other.active_ctx != focused) continue;
            other.send(self.io, body) catch |err| {
                std.log.err("glyphwire broadcast to a connection failed: {t}", .{err});
            };
        }
    }

    /// Whether `event` is a raw input stream that only the focused pane's
    /// on-screen client should receive (see `broadcast`).
    fn isFocusGatedEvent(event: []const u8) bool {
        return std.mem.eql(u8, event, "key") or
            std.mem.eql(u8, event, "text") or
            std.mem.eql(u8, event, "mouse_button") or
            std.mem.eql(u8, event, "mouse_move");
    }

    /// The session's visibility change-counter (see
    /// `core.Session.visible_gen`) -- glyphwire-host polls this each
    /// frame and, when it moves, drops its per-layer render-batch cache
    /// so it starts compositing the newly-visible context cleanly.
    pub fn visibleContextGen(self: *Server) u64 {
        return self.session.visible_gen.load(.monotonic);
    }

    /// Whether the currently-visible context belongs to a connected
    /// client (created over the wire with `create_context`) rather than
    /// being the root/shell context. glyphwire-host uses this to stand
    /// down its own grid selection: a client that owns its context (zoe)
    /// paints its own panes and runs its own mouse/keyboard selection, so
    /// the host forwards raw mouse events into it instead of consuming
    /// drags for a root-layer selection the client never asked for.
    pub fn visibleContextClientOwned(self: *Server) bool {
        self.ctx_mutex.lockUncancelable(self.io);
        defer self.ctx_mutex.unlock(self.io);
        return self.ctx.connection_owned;
    }

    /// Fans a `context` notification (`{context, cols, rows}` -- the
    /// now-visible context's handle and size) out to every `"context"`
    /// subscriber. Sent by `create_context` / `activate_context` /
    /// `destroy_context` and by the disconnect-cull path when a visible
    /// context goes away. glyphwire-host learns of the switch in-process
    /// (`visibleContextGen`); this is for other clients (e.g. a shell
    /// that wants to pause its own output while backgrounded).
    pub fn reportContext(self: *Server, alloc: std.mem.Allocator) !void {
        const info = blk: {
            self.ctx_mutex.lockUncancelable(self.io);
            defer self.ctx_mutex.unlock(self.io);
            break :blk .{
                .handle = self.session.focusedContextHandle(),
                .cols = self.ctx.root.width,
                .rows = self.ctx.root.height,
            };
        };
        const body = try rpc.contextNotification(alloc, info.handle, info.cols, info.rows);
        defer alloc.free(body);
        self.broadcast(null, "context", body);
    }

    // ─── Panes ─────────────────────────────────────────────────────────

    /// Registers the `spawn_in_pane` implementation (see
    /// `dispatch.PaneSpawner`). Call once at startup, before serving.
    pub fn setPaneSpawner(self: *Server, spawner: dispatch.PaneSpawner) void {
        self.pane_spawner = spawner;
    }

    /// The pane-tree layout change-counter -- glyphwire-host caches pane
    /// divider geometry against this exactly as it does
    /// `Context.layout_gen` for layer dividers.
    pub fn paneLayoutGen(self: *Server) u64 {
        return self.session.pane_layout_gen.load(.monotonic);
    }

    /// Resolves an optional context handle: the named context, or the
    /// focused one when null. Null out only for a handle that named a
    /// context which no longer exists. Call under `ctx_mutex`.
    fn contextOrFocused(self: *Server, context: ?core.ContextHandle) ?*core.Context {
        const h = context orelse return self.session.focusedContext();
        return self.session.contextPtr(h);
    }

    /// The pane under a window cell, and the context on screen there --
    /// how the host resolves a mouse position to "whose surface is this".
    /// Null in a divider band between panes. Call under `ctx_mutex`.
    pub const PaneAtCell = struct {
        pane: core.PaneHandle,
        context: core.ContextHandle,
        ctx: *core.Context,
        rect: core.CellRect,
    };

    pub fn paneAtCell(self: *Server, row: usize, col: usize) ?PaneAtCell {
        const handle = self.session.paneAt(row, col) orelse return null;
        const pane = self.session.panePtr(handle) orelse return null;
        const ctx_handle = pane.top();
        return .{
            .pane = handle,
            .context = ctx_handle,
            .ctx = self.session.contextPtr(ctx_handle) orelse return null,
            .rect = pane.rect,
        };
    }

    /// Translates a window cell into the focused context's own coordinate
    /// frame, or null when the pointer isn't inside the focused pane.
    ///
    /// Raw mouse events only ever reach the focused pane's client (see
    /// `broadcast`), and that client's coordinates are context-relative, so
    /// this is the inbound counterpart of the origin the renderer adds on
    /// the way out. Null means "not this client's business": a pointer over
    /// another pane, or in a divider band, reports nothing rather than a
    /// cell outside the client's own grid.
    pub fn focusedCell(self: *Server, cell: core.CellPos) ?core.CellPos {
        self.ctx_mutex.lockUncancelable(self.io);
        defer self.ctx_mutex.unlock(self.io);
        const pane = self.session.panePtr(self.session.focusedPaneHandle()) orelse return null;
        if (!pane.rect.contains(cell.row, cell.col)) return null;
        return .{ .row = cell.row - pane.rect.row, .col = cell.col - pane.rect.col };
    }

    /// Click-to-focus: moves focus to whichever pane contains a window
    /// cell. A no-op in a divider band, or when that pane already has
    /// focus. Returns true when focus actually moved.
    pub fn focusPaneAt(self: *Server, alloc: std.mem.Allocator, cell: core.CellPos) !bool {
        const target = blk: {
            self.ctx_mutex.lockUncancelable(self.io);
            defer self.ctx_mutex.unlock(self.io);
            const at = self.paneAtCell(cell.row, cell.col) orelse break :blk null;
            if (at.pane == self.session.focusedPaneHandle()) break :blk null;
            break :blk at.pane;
        };
        const pane = target orelse return false;
        try self.focusPane(alloc, pane);
        return true;
    }

    /// Moves input focus to `pane` (the host's own click-to-focus path --
    /// the in-process counterpart of the `focus_pane` message). A no-op for
    /// an unknown or unmapped pane, or one that already has focus.
    pub fn focusPane(self: *Server, alloc: std.mem.Allocator, pane: core.PaneHandle) !void {
        const changed = blk: {
            self.ctx_mutex.lockUncancelable(self.io);
            defer self.ctx_mutex.unlock(self.io);
            if (self.session.focusedPaneHandle() == pane) break :blk false;
            self.session.focusPane(pane) catch break :blk false;
            self.ctx = self.session.focusedContext();
            break :blk true;
        };
        if (!changed) return;
        try self.reportContext(alloc);
    }

    /// Re-lays-out the pane tree and tells everyone what moved. Called
    /// after any pane-tree edit (`HandleResult.panes_changed`), after the
    /// window resizes, and after a pane cull.
    ///
    /// Three separate notifications, because three different audiences
    /// need three different things:
    ///
    /// - `pane_layout` to the window manager: every pane's new rect, in
    ///   window cells. The only message in the protocol that reveals where
    ///   panes sit, and only the manager subscribes to it.
    /// - `resize` to each *other* connection: its own context's new cell
    ///   size, with no hint that a pane was involved. This is why it can't
    ///   be one broadcast -- each recipient gets a different body.
    /// - `layout` per affected context: the layer bounds inside it, if it
    ///   has a split tree of its own.
    pub fn applyPaneLayout(self: *Server, alloc: std.mem.Allocator) !void {
        var changed: std.ArrayList(core.PaneBounds) = .empty;
        defer changed.deinit(alloc);
        {
            self.ctx_mutex.lockUncancelable(self.io);
            defer self.ctx_mutex.unlock(self.io);
            try self.session.layoutPanes(&changed, null);
            self.ctx = self.session.focusedContext();
        }

        if (changed.items.len > 0) {
            const bounds = try alloc.alloc(protocol.PaneBounds, changed.items.len);
            defer alloc.free(bounds);
            for (changed.items, 0..) |b, i| {
                bounds[i] = .{ .pane = b.pane, .row = b.row, .col = b.col, .cols = b.cols, .rows = b.rows };
            }
            const body = try rpc.paneLayoutNotification(alloc, bounds);
            defer alloc.free(body);
            self.broadcast(null, "pane_layout", body);
        }
        try self.reportContextSizes(alloc);
        try self.reportLayout(alloc);
    }

    /// Sends each subscribed connection a `resize` carrying *its own*
    /// context's cell size. The per-pane replacement for one window-wide
    /// `resize` broadcast: after panes exist, "the size" is a different
    /// number for every client, and a program must see its pane's size or
    /// it will draw outside its rectangle.
    fn reportContextSizes(self: *Server, alloc: std.mem.Allocator) !void {
        self.registry_mutex.lockUncancelable(self.io);
        defer self.registry_mutex.unlock(self.io);

        for (self.connections.items) |conn| {
            if (!conn.subscriptions.has("resize")) continue;
            const size = blk: {
                self.ctx_mutex.lockUncancelable(self.io);
                defer self.ctx_mutex.unlock(self.io);
                const ctx = self.session.contextPtr(conn.active_ctx) orelse continue;
                break :blk .{ .cols = ctx.root.width, .rows = ctx.root.height };
            };
            const body = try rpc.resizeNotification(alloc, size.cols, size.rows);
            defer alloc.free(body);
            conn.send(self.io, body) catch |err| {
                std.log.err("glyphwire: resize to a connection failed: {t}", .{err});
            };
        }
    }

    /// Broadcasts `pane_exit` -- a program spawned into a pane has
    /// finished. Called by the host's pane process table when it reaps a
    /// child. The window manager needs this to tear the pane down: unlike
    /// a context cull, nothing about the *pane* changes on its own when
    /// the program inside it dies, because the pane belongs to the manager
    /// and not to the program.
    pub fn reportPaneExit(self: *Server, alloc: std.mem.Allocator, pane: core.PaneHandle, status: i64) !void {
        const body = try rpc.paneExitNotification(alloc, pane, status);
        defer alloc.free(body);
        self.broadcast(null, "pane_exit", body);
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

    /// In-process equivalent of a connected client's `report_text`
    /// notification (see `handleReportText`) -- committed text input
    /// (`text` is a UTF-8 string of one or more codepoints, already
    /// resolved through the OS layout / dead keys / IME). No `ctx` state
    /// to touch, so no lock: just fans a `text` notification out to every
    /// `"text"` subscriber. An empty string is a no-op.
    pub fn reportText(self: *Server, alloc: std.mem.Allocator, text: []const u8) !void {
        if (text.len == 0) return;
        const body = try rpc.textNotification(alloc, text);
        defer alloc.free(body);
        self.broadcast(null, "text", body);
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
        return self.reportScrollIn(alloc, null, offset, delta);
    }

    /// `reportScroll` against a named context rather than the focused one.
    /// A wheel tick belongs to the pane under the pointer, which is not
    /// necessarily the pane that has focus -- pointing at a pane and
    /// scrolling it should not first require clicking it.
    pub fn reportScrollIn(
        self: *Server,
        alloc: std.mem.Allocator,
        context: ?core.ContextHandle,
        offset: ?usize,
        delta: ?i64,
    ) !void {
        const result = blk: {
            self.ctx_mutex.lockUncancelable(self.io);
            defer self.ctx_mutex.unlock(self.io);
            const ctx = self.contextOrFocused(context) orelse return;
            const before = ctx.root.view_scroll;
            const after = ctx.root.scrollView(offset, delta);
            break :blk .{ .changed = before != after, .offset = after, .max = ctx.root.history_len };
        };
        if (!result.changed) return;

        const body = try rpc.scrollNotification(alloc, null, result.offset, result.max);
        defer alloc.free(body);
        self.broadcast(null, "scroll", body);
    }

    /// In-process scroll of a **non-root** layer's scrollback ring (see
    /// `core.Layer.scrollView`) -- glyphwire-host's mouse wheel over a
    /// `gmux` pane that carries its own scrollback (`scrollback_rows > 0`,
    /// content grid == viewport, so there is no `scroll_offset` slack for
    /// `reportScrollOffset` to move). `offset` (absolute) and/or `delta`
    /// (relative) are clamped to `0..history_len`. Broadcasts a `scroll`
    /// notification carrying the layer handle, only on an actual change.
    /// A no-op (not an error) for an unknown handle.
    pub fn reportLayerScroll(self: *Server, alloc: std.mem.Allocator, layer: core.LayerHandle, offset: ?usize, delta: ?i64) !void {
        return self.reportLayerScrollIn(alloc, null, layer, offset, delta);
    }

    /// `reportLayerScroll` against a named context -- see `reportScrollIn`.
    pub fn reportLayerScrollIn(
        self: *Server,
        alloc: std.mem.Allocator,
        context: ?core.ContextHandle,
        layer: core.LayerHandle,
        offset: ?usize,
        delta: ?i64,
    ) !void {
        const result = blk: {
            self.ctx_mutex.lockUncancelable(self.io);
            defer self.ctx_mutex.unlock(self.io);
            const ctx = self.contextOrFocused(context) orelse break :blk null;
            const l = ctx.layers.getPtr(layer) orelse break :blk null;
            const before = l.view_scroll;
            const after = l.scrollView(offset, delta);
            break :blk .{ .changed = before != after, .offset = after, .max = l.history_len };
        };
        const r = result orelse return;
        if (!r.changed) return;

        const body = try rpc.scrollNotification(alloc, layer, r.offset, r.max);
        defer alloc.free(body);
        self.broadcast(null, "scroll", body);
    }

    /// In-process equivalent of `report_mouse_move` -- see `reportKey`.
    /// Keeps `get_input_state`'s cursor fields current every call, and
    /// broadcasts a `mouse_move` notification (`{px, cell}`) to
    /// `"mouse_move"` subscribers only when the pointer crossed into a
    /// new cell -- matching `handleReportMouseMove` and keeping the
    /// per-pixel motion the host reports off the wire. Cheap to call
    /// every frame.
    pub fn reportMouseMove(self: *Server, alloc: std.mem.Allocator, px: core.PxPos, cell: core.CellPos) !void {
        const cell_changed = changed: {
            self.ctx_mutex.lockUncancelable(self.io);
            defer self.ctx_mutex.unlock(self.io);
            const before = self.ctx.input.cursor_cell;
            self.ctx.input.cursor_px = px;
            self.ctx.input.cursor_cell = cell;
            break :changed before.row != cell.row or before.col != cell.col;
        };
        if (!cell_changed) return;

        const body = try rpc.mouseMoveNotification(alloc, px, cell);
        defer alloc.free(body);
        self.broadcast(null, "mouse_move", body);
    }

    /// Applies a new window size, in cells. The window is the rect the
    /// pane tree is laid out over, so this re-runs that layout, which is
    /// what resizes each pane's contexts (and, through them, every
    /// base-size-tracking layer). With no pane tree installed the root
    /// pane simply takes the whole window, which is the single-program
    /// case and behaves exactly as it did before panes existed.
    ///
    /// For the process that owns this `Server` and captures its own window
    /// events (glyphwire-host), same in-process path as `reportKey`. A
    /// no-op when the size is unchanged, so this is cheap to call every
    /// frame.
    pub fn reportResize(self: *Server, alloc: std.mem.Allocator, cols: usize, rows: usize) !void {
        {
            self.ctx_mutex.lockUncancelable(self.io);
            defer self.ctx_mutex.unlock(self.io);
            if (cols == self.session.window_cols and rows == self.session.window_rows) return;
            try self.session.resizeWindow(cols, rows);
        }
        // `applyPaneLayout` is idempotent and does the rest: the
        // `pane_layout` broadcast for the manager, a tailored `resize` for
        // every client (its own pane's size, not the window's), and the
        // per-context `layout` for layer trees.
        try self.applyPaneLayout(alloc);
    }

    /// Broadcasts a `shutdown` notification (`{grace_ms}`) to every
    /// connection subscribed to `"shutdown"` -- the window is closing and
    /// a client should flush any persistent state and exit. Sent once, by
    /// glyphwire-host, after its render loop has ended; the server thread
    /// is still up so the notification still reaches a connected client,
    /// and the host then waits up to `grace_ms` for the client's process
    /// to actually exit before it tears down. Touches no context state,
    /// so it needs no lock.
    pub fn reportShutdown(self: *Server, alloc: std.mem.Allocator, grace_ms: u32) !void {
        const body = try rpc.shutdownNotification(alloc, grace_ms);
        defer alloc.free(body);
        self.broadcast(null, "shutdown", body);
    }

    /// Re-lays-out the split tree against the current context size and
    /// broadcasts a `layout` notification for every pane whose bounds
    /// moved. Silent when there is no split tree, or when the layout came
    /// out identical -- which is what makes it safe to call after any
    /// change that *might* have moved something.
    pub fn reportLayout(self: *Server, alloc: std.mem.Allocator) !void {
        var changed: std.ArrayList(core.LayerBounds) = .empty;
        defer changed.deinit(alloc);
        {
            self.ctx_mutex.lockUncancelable(self.io);
            defer self.ctx_mutex.unlock(self.io);
            // Every pane's on-screen context, not just the focused one: a
            // resize moves the layer trees in all of them at once, and each
            // client needs its own bounds. Layer handles are per-context so
            // there is no ambiguity in pooling them into one notification;
            // a client only recognises its own.
            var it = self.session.panes.valueIterator();
            while (it.next()) |pane| {
                if (!pane.mapped) continue;
                const ctx = self.session.contextPtr(pane.top()) orelse continue;
                try ctx.layoutSplits(&changed, null);
            }
        }
        if (changed.items.len == 0) return;

        const bounds = try alloc.alloc(protocol.LayoutBounds, changed.items.len);
        defer alloc.free(bounds);
        for (changed.items, 0..) |b, i| {
            bounds[i] = .{ .layer = b.layer, .row = b.row, .col = b.col, .cols = b.cols, .rows = b.rows };
        }

        const body = try rpc.layoutNotification(alloc, bounds);
        defer alloc.free(body);
        self.broadcast(null, "layout", body);
    }

    /// In-process equivalent of `set_property(layer, "scroll_offset")` --
    /// glyphwire-host's mouse wheel and scrollbar drags over a pane. Pass
    /// `offset` for an absolute move or `delta` for a relative one (the
    /// wheel); both clamp through `Layer.setScrollOffset`. Broadcasts a
    /// `scroll_offset` notification only when the viewport actually moved,
    /// so a wheel spun against the end of the content is silent.
    pub fn reportScrollOffset(
        self: *Server,
        alloc: std.mem.Allocator,
        layer_handle: core.LayerHandle,
        offset: ?core.CellPos,
        delta: ?core.CellPos.Delta,
    ) !void {
        return self.reportScrollOffsetIn(alloc, null, layer_handle, offset, delta);
    }

    /// `reportScrollOffset` against a named context -- see
    /// `reportScrollIn` for why the pointer's pane, not the focused one.
    pub fn reportScrollOffsetIn(
        self: *Server,
        alloc: std.mem.Allocator,
        context: ?core.ContextHandle,
        layer_handle: core.LayerHandle,
        offset: ?core.CellPos,
        delta: ?core.CellPos.Delta,
    ) !void {
        const result = blk: {
            self.ctx_mutex.lockUncancelable(self.io);
            defer self.ctx_mutex.unlock(self.io);
            const ctx = self.contextOrFocused(context) orelse return;
            const layer = ctx.layerPtr(layer_handle) orelse return;
            const before = layer.effectiveScrollOffset();
            var after = before;
            if (offset) |o| after = layer.setScrollOffset(o);
            if (delta) |d| after = layer.scrollOffsetBy(d.row, d.col);
            const max = layer.maxScroll();
            break :blk .{
                .changed = after.row != before.row or after.col != before.col,
                .off = after,
                .max = max,
            };
        };
        if (!result.changed) return;

        const body = try rpc.scrollOffsetNotification(
            alloc,
            layer_handle,
            result.off.row,
            result.off.col,
            result.max.row,
            result.max.col,
        );
        defer alloc.free(body);
        self.broadcast(null, "scroll_offset", body);
    }

    // ── Selection & clipboard (in-process, for glyphwire-host) ──────────
    //
    // Same pattern as `reportKey` / `reportScroll`: glyphwire-host owns
    // the `Context` and drives selection from its own mouse/keyboard
    // capture rather than over a loopback connection. Each mutator takes
    // `ctx_mutex`, applies the change, then fans a `selection`
    // notification out to every other subscriber.

    /// In-process `set_selection` on `layer_handle` (null = root).
    pub fn setSelection(
        self: *Server,
        alloc: std.mem.Allocator,
        layer_handle: ?core.LayerHandle,
        anchor: core.SelectionPoint,
        active: core.SelectionPoint,
    ) !void {
        const snapshot: ?core.Selection = blk: {
            self.ctx_mutex.lockUncancelable(self.io);
            defer self.ctx_mutex.unlock(self.io);
            const layer = self.ctx.layerPtr(layer_handle) orelse return;
            layer.setSelection(anchor, active);
            break :blk layer.selection;
        };
        const body = try rpc.selectionNotification(alloc, snapshot);
        defer alloc.free(body);
        self.broadcast(null, "selection", body);
    }

    /// In-process `clear_selection` on `layer_handle` (null = root).
    pub fn clearSelection(self: *Server, alloc: std.mem.Allocator, layer_handle: ?core.LayerHandle) !void {
        {
            self.ctx_mutex.lockUncancelable(self.io);
            defer self.ctx_mutex.unlock(self.io);
            const layer = self.ctx.layerPtr(layer_handle) orelse return;
            layer.clearSelection();
        }
        const body = try rpc.selectionNotification(alloc, null);
        defer alloc.free(body);
        self.broadcast(null, "selection", body);
    }

    /// The selected text on `layer_handle` (null = root), or null when
    /// nothing is selected. Caller owns the result.
    pub fn selectionText(self: *Server, alloc: std.mem.Allocator, layer_handle: ?core.LayerHandle) !?[]u8 {
        self.ctx_mutex.lockUncancelable(self.io);
        defer self.ctx_mutex.unlock(self.io);
        const layer = self.ctx.layerPtr(layer_handle) orelse return null;
        return layer.selectionText(alloc);
    }

    /// Replaces the session clipboard buffer (and bumps its serial, so
    /// glyphwire-host's next frame pushes it to the OS). Does not
    /// broadcast -- `set_clipboard` has no server->client counterpart.
    pub fn setClipboard(self: *Server, text: []const u8) !void {
        self.ctx_mutex.lockUncancelable(self.io);
        defer self.ctx_mutex.unlock(self.io);
        try self.ctx.setClipboard(text);
    }

    /// Fans a `copy_request` notification out to every `"clipboard"`
    /// subscriber -- the host calls this when the copy shortcut is
    /// pressed with nothing selected, so glyphwire-shell can answer with
    /// its current prompt via `set_clipboard`.
    pub fn requestCopy(self: *Server, alloc: std.mem.Allocator) !void {
        const body = try rpc.copyRequestNotification(alloc);
        defer alloc.free(body);
        self.broadcast(null, "clipboard", body);
    }

    /// Fans a `paste` notification (committed clipboard text) out to
    /// every `"clipboard"` subscriber.
    pub fn broadcastPaste(self: *Server, alloc: std.mem.Allocator, text: []const u8) !void {
        const body = try rpc.pasteNotification(alloc, text);
        defer alloc.free(body);
        self.broadcast(null, "clipboard", body);
    }

    /// The current session clipboard serial (see
    /// `core.Context.clipboard_serial`) -- glyphwire-host polls this each
    /// frame to decide whether to push the buffer to the OS clipboard.
    pub fn clipboardSerial(self: *Server) u64 {
        self.ctx_mutex.lockUncancelable(self.io);
        defer self.ctx_mutex.unlock(self.io);
        return self.ctx.clipboard_serial;
    }

    /// A copy of the current session clipboard buffer. Caller owns it.
    pub fn clipboardText(self: *Server, alloc: std.mem.Allocator) ![]u8 {
        self.ctx_mutex.lockUncancelable(self.io);
        defer self.ctx_mutex.unlock(self.io);
        return alloc.dupe(u8, self.ctx.clipboardText());
    }
};
