const std = @import("std");
const core = @import("core.zig");
const wire = @import("wire.zig");
const dispatch = @import("dispatch.zig");
const rpc = @import("rpc.zig");
const protocol = @import("protocol.zig");

/// Tracks one accepted connection long enough for *other* connections'
/// dispatch to push a notification to it -- see `Server.broadcastToOthers`.
/// Lives on the stack frame of whichever call is serving it (`acceptOne`
/// or a `serveForever`-spawned thread), registered in `Server.connections`
/// for exactly that lifetime.
pub const Connection = struct {
    stream: std.Io.net.Stream,
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
    /// The currently-visible context -- a cached, always-live pointer
    /// into `session` (never null; the root context can't leave the
    /// visibility stack). Re-pointed under `ctx_mutex` on every
    /// visibility change, so every existing `server.ctx.*` access (the
    /// host's caret/scroll/selection/render, the in-process `report*`
    /// methods) keeps meaning "the context on screen right now" with no
    /// change. Dispatch does *not* go through this -- a connection acts
    /// on its own `Dispatcher.ctx`, which may be a backgrounded context.
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

        var conn: Connection = .{ .stream = stream, .id = self.next_conn_id.fetchAdd(1, .monotonic) };
        try self.registerConnection(alloc, &conn);
        defer self.unregisterConnection(alloc, &conn);

        // `initForConnection` reads the visibility stack to inherit the
        // context that's visible now -- take `ctx_mutex` so it can't race
        // another connection's `create_context`.
        var d = blk: {
            self.ctx_mutex.lockUncancelable(self.io);
            defer self.ctx_mutex.unlock(self.io);
            break :blk dispatch.Dispatcher.initForConnection(&self.session, conn.id);
        };
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
                    self.wake();
                    continue;
                }

                const handle_result = blk: {
                    self.ctx_mutex.lockUncancelable(self.io);
                    defer self.ctx_mutex.unlock(self.io);
                    const r = d.handle(alloc, body);
                    // A `create_context` / `activate_context` /
                    // `destroy_context` in this frame may have moved the
                    // visible context -- keep `self.ctx` (the host's view
                    // and the in-process `report*` path) pointing at it.
                    self.ctx = self.session.visibleContext();
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

                if (result.response) |r| {
                    defer alloc.free(r);
                    try conn.send(self.io, r);
                }
                if (result.broadcast) |b| {
                    defer alloc.free(b.body);
                    self.broadcast(&conn, b.event, b.body);
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
            // takes its layers/splits/tables with it. A visible context
            // going this way pops visibility back to whatever was under
            // it: the alt-screen auto-restore on a program's exit.
            const visible_before = self.session.visibleStackTop();
            self.session.reapConnection(conn.id, &culled_ctx) catch |err| {
                std.log.err("glyphwire: context cull for closed connection {d} failed: {t}", .{ conn.id, err });
            };
            self.ctx = self.session.visibleContext();
            context_switched = self.session.visibleStackTop() != visible_before;
        }
        for (culled.items) |h| {
            std.log.debug("glyphwire: culled orphaned layer {d} (owning connection {d} closed)", .{ h, conn.id });
        }
        for (culled_ctx.items) |h| {
            std.log.debug("glyphwire: culled orphaned context {d} (owning connection {d} closed)", .{ h, conn.id });
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
        // screen -- a backgrounded full-screen editor shouldn't see the
        // keystrokes meant for the shell that's now visible, and vice
        // versa. Every other event (`resize`, `layout`, `scroll`,
        // `selection`, `context`, ...) still fans out to all subscribers:
        // a backgrounded client wants to know its panes moved so it can
        // redraw before it's shown again. `visible_handle` is the
        // lock-free denormalised copy of the visibility-stack top.
        const gated = isVisibleGatedEvent(event);
        const visible = self.session.visible_handle.load(.monotonic);

        for (self.connections.items) |other| {
            if (sender != null and other == sender.?) continue;
            if (!other.subscriptions.has(event)) continue;
            if (gated and other.active_ctx != visible) continue;
            other.send(self.io, body) catch |err| {
                std.log.err("glyphwire broadcast to a connection failed: {t}", .{err});
            };
        }
    }

    /// Whether `event` is a raw input stream that only the visible
    /// context's client should receive (see `broadcast`).
    fn isVisibleGatedEvent(event: []const u8) bool {
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
                .handle = self.session.visibleStackTop(),
                .cols = self.ctx.root.width,
                .rows = self.ctx.root.height,
            };
        };
        const body = try rpc.contextNotification(alloc, info.handle, info.cols, info.rows);
        defer alloc.free(body);
        self.broadcast(null, "context", body);
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
            // Every context tracks the one window, so a backgrounded one
            // is resized too rather than showing a stale grid when it's
            // next made visible (`Session.resizeAll` is a no-op per
            // context whose size is already current).
            try self.session.resizeAll(cols, rows);
        }

        const body = try rpc.resizeNotification(alloc, cols, rows);
        defer alloc.free(body);
        self.broadcast(null, "resize", body);

        // The window changing size re-lays-out any split tree, which is a
        // separate notification: `resize` is "the window is this big now",
        // `layout` is "and here is where each of your panes ended up".
        try self.reportLayout(alloc);
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
            try self.ctx.layoutSplits(&changed, null);
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
        const result = blk: {
            self.ctx_mutex.lockUncancelable(self.io);
            defer self.ctx_mutex.unlock(self.io);
            const layer = self.ctx.layerPtr(layer_handle) orelse return;
            const before = layer.scroll_off;
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
