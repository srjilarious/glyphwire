// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: MPL-2.0

//! `Server`'s in-process API: what glyphwire-host calls on the server it
//! runs in the same process, rather than over a socket. Reporting input
//! (`reportKey`, `reportMouseButton`, ...), focus and panes, the window
//! theme, selection and the clipboard. `Server` methods moved out of
//! server.zig and aliased back, so a caller still writes
//! `server.reportKey(...)`; server.zig keeps the socket half (accept,
//! framing, connections, fan-out).
//!
//! Each takes `ctx_mutex` itself unless its doc comment says the caller
//! holds it. A caller reading `session` / `ctx` directly takes it with
//! `Server.lockSession`.

const std = @import("std");
const core = @import("core.zig");
const dispatch = @import("dispatch.zig");
const rpc = @import("rpc.zig");
const protocol = @import("protocol.zig");
const wire = @import("wire.zig");
const server = @import("server.zig");

const Server = server.Server;

/// The session's visibility change-counter (see
/// `core.Session.visible_gen`) -- glyphwire-host polls this each
/// frame and, when it moves, drops its per-layer render-batch cache
/// so it starts compositing the newly-visible context cleanly.
pub fn visibleContextGen(self: *Server) u64 {
    return self.session.visible_gen.load(.monotonic);
}

/// Whether glyphwire-host may start one of its own mouse text
/// selections on `layer` of the currently-visible context (`null` =
/// the root layer).
///
/// A context the host itself owns -- the root/shell one -- selects
/// everywhere, which is what a terminal does. A context a client
/// created over the wire (`create_context`: zoe, salacommander,
/// gw-read) paints its own panes and is listening for
/// `mouse_button`, so the host stands down and forwards the drag
/// instead of consuming it for a selection the client never asked
/// for -- *except* on a layer that client has opted in with
/// `set_property "mouse_select"`, which is how salacommander gets a
/// selectable embedded shell panel without giving up clicks in its
/// file panes. See `core.Layer.mouse_select`.
pub fn mouseSelectAllowed(self: *Server, layer: ?core.LayerHandle) bool {
    const session_lock = self.lockSession();
    defer session_lock.unlock();
    // The manager's raised overlay is a pane's base context, but what
    // is on it is the manager's own drawing, and a drag across it is
    // the manager's (gmux's layout mode), so it is treated as drawn by
    // a client.
    if (!self.ctx.connection_owned and !self.session.isOverlayPane(self.ctx.pane)) return true;
    const handle = layer orelse return false;
    const l = self.ctx.layers.getPtr(handle) orelse return false;
    return l.mouse_select;
}

/// Whether the program drawing on `layer` (null = root) of the
/// visible context has asked for mouse events -- glyphwire-host then
/// forwards a press there raw instead of starting a selection. See
/// `core.Layer.mouse_report`.
pub fn mouseReportOn(self: *Server, layer: ?core.LayerHandle) bool {
    const session_lock = self.lockSession();
    defer session_lock.unlock();
    const l = self.ctx.layerPtr(layer) orelse return false;
    return l.mouse_report;
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
        const session_lock = self.lockSession();
        defer session_lock.unlock();
        break :blk .{
            .handle = self.session.focusedContextHandle(),
            .cols = self.ctx.root.width,
            .rows = self.ctx.root.height,
        };
    };
    const body = try rpc.contextNotification(alloc, info.handle, info.cols, info.rows);
    defer alloc.free(body);
    self.broadcast(null, .context, body);
}

// ─── Panes ─────────────────────────────────────────────────────────

/// Registers the `spawn_in_pane` implementation (see
/// `dispatch.PaneSpawner`). Call once at startup, before serving.
pub fn setPaneSpawner(self: *Server, spawner: dispatch.PaneSpawner) void {
    self.pane_spawner = spawner;
}

/// Registers the `start_remote` implementation (see
/// `dispatch.RemoteStarter`). Call once at startup, before serving.
pub fn setRemoteStarter(self: *Server, starter: dispatch.RemoteStarter) void {
    self.remote_starter = starter;
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

/// The handle `contextOrFocused` resolves to -- what a notification
/// about that context is scoped to (see `broadcastIn`).
fn scopeOf(self: *Server, context: ?core.ContextHandle) core.ContextHandle {
    return context orelse self.session.focused_context.load(.monotonic);
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
    const session_lock = self.lockSession();
    defer session_lock.unlock();
    const pane = self.session.panePtr(self.session.focusedPaneHandle()) orelse return null;
    if (!pane.rect.contains(cell.row, cell.col)) return null;
    return .{ .row = cell.row - pane.rect.row, .col = cell.col - pane.rect.col };
}

/// `focusedCell`, but clamped into the focused pane rather than
/// refusing when the pointer is outside it.
///
/// For the *release* half of a button the client already saw pressed.
/// A press claims the button: the pointer wandering into a neighbour
/// pane (or into a divider band) before the user lets go must not
/// swallow the release, because the pair is what the client -- and
/// `Session.input`'s down-set -- balances on. A release reported
/// against a clamped cell is the same rule a pointer grab follows
/// everywhere else: the event goes to whoever took the press, at the
/// nearest cell that is theirs. Null only when the focused pane has
/// gone away entirely.
pub fn focusedCellClamped(self: *Server, cell: core.CellPos) ?core.CellPos {
    const session_lock = self.lockSession();
    defer session_lock.unlock();
    const pane = self.session.panePtr(self.session.focusedPaneHandle()) orelse return null;
    const r = pane.rect;
    const row = std.math.clamp(cell.row, r.row, r.row + (r.rows -| 1));
    const col = std.math.clamp(cell.col, r.col, r.col + (r.cols -| 1));
    return .{ .row = row - r.row, .col = col - r.col };
}

/// Click-to-focus: moves focus to whichever pane contains a window
/// cell. A no-op in a divider band, or when that pane already has
/// focus. Returns true when focus actually moved.
pub fn focusPaneAt(self: *Server, alloc: std.mem.Allocator, cell: core.CellPos) !bool {
    const target = blk: {
        const session_lock = self.lockSession();
        defer session_lock.unlock();
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
        const session_lock = self.lockSession();
        defer session_lock.unlock();
        if (self.session.focusedPaneHandle() == pane) break :blk false;
        self.session.focusPane(pane) catch break :blk false;
        self.ctx = self.session.focusedContext();
        break :blk true;
    };
    if (!changed) return;
    try self.reportContext(alloc);
    try self.reportPaneFocusIfChanged(alloc);
    try self.syncConnectionFocus(alloc);
}

/// Sends each `"focus"` subscriber whose focus changed a `focus`
/// notification. A connection has focus when the window does *and*
/// its context is the one on screen in the focused pane: it is the
/// program being typed into. Window focus alone left a zoe in a pane
/// you'd moved away from drawing the solid, active cursor. Sent only
/// on a change per connection, so calling this after every possible
/// change point is cheap.
pub fn syncConnectionFocus(self: *Server, alloc: std.mem.Allocator) !void {
    const focused_ctx, const window = blk: {
        const session_lock = self.lockSession();
        defer session_lock.unlock();
        break :blk .{ self.session.focusedContextHandle(), self.window_focused };
    };
    const on = try rpc.focusNotification(alloc, true);
    defer alloc.free(on);
    const off = try rpc.focusNotification(alloc, false);
    defer alloc.free(off);

    self.registry_mutex.lockUncancelable(self.io);
    defer self.registry_mutex.unlock(self.io);
    for (self.connections.items) |conn| {
        if (!conn.route.attached) continue;
        if (!conn.route.subscriptions.has(.focus)) continue;
        const has = window and conn.route.active_ctx == focused_ctx;
        if (has == conn.focus_sent) continue;
        conn.send(self.io, if (has) on else off) catch |err| {
            std.log.err("glyphwire: focus to a connection failed: {t}", .{err});
            continue;
        };
        conn.focus_sent = has;
    }
}

/// Broadcasts `pane_focus` when the focused pane differs from the one
/// last reported. Focus moves from more than one place -- the
/// manager's own `focus_pane`, the host's click-to-focus, a fallback
/// when the focused pane is destroyed or unmapped -- and a manager
/// tracking it only from its own commands acted on a stale pane (gmux
/// zooming the pane it last focused, not the one just clicked). One
/// check after every change point, rather than a notification at each,
/// so a new path that moves focus can't forget to say so.
pub fn reportPaneFocusIfChanged(self: *Server, alloc: std.mem.Allocator) !void {
    const pane = blk: {
        const session_lock = self.lockSession();
        defer session_lock.unlock();
        const now = self.session.focusedPaneHandle();
        if (now == self.reported_focus_pane) return;
        self.reported_focus_pane = now;
        break :blk now;
    };
    const body = try rpc.paneFocusNotification(alloc, pane);
    defer alloc.free(body);
    self.broadcast(null, .pane_focus, body);
}

/// Brings `context` to the top of its pane's stack (the host's own
/// context switcher -- the in-process counterpart of the
/// `activate_context` message). A no-op for an unknown handle or one
/// already on screen. Returns whether anything changed.
pub fn activateContext(self: *Server, alloc: std.mem.Allocator, context: core.ContextHandle) !bool {
    const changed = blk: {
        const session_lock = self.lockSession();
        defer session_lock.unlock();
        const before = self.session.focusedContextHandle();
        self.session.activateContext(context) catch break :blk false;
        self.ctx = self.session.focusedContext();
        break :blk self.session.focusedContextHandle() != before;
    };
    if (changed) {
        try self.reportContext(alloc);
        try self.reportPaneFocusIfChanged(alloc);
        try self.syncConnectionFocus(alloc);
        // The context brought forward may have missed a resize while
        // it was backgrounded.
        try self.reportLayout(alloc);
    }
    return changed;
}

/// Makes a context in `pane` for a shell the host is about to spawn
/// there (the context switcher's "new shell") and puts it on top. It
/// has the scrollback of the pane's base context, since it is a shell's
/// screen just like that one, and is flagged `spawned_shell` so other
/// shells' job control leaves it alone. Owned by no connection: the
/// host destroys it with `destroyShellContext` when the shell exits.
pub fn createShellContext(self: *Server, alloc: std.mem.Allocator, pane: core.PaneHandle) !core.ContextHandle {
    const handle = blk: {
        const session_lock = self.lockSession();
        defer session_lock.unlock();
        const p = self.session.panePtr(pane) orelse return error.UnknownPane;
        const scrollback = if (self.session.contextPtr(p.base)) |c| c.root.scrollback_rows else 0;
        const h = try self.session.createContext(pane, null, null, scrollback);
        self.session.contextPtr(h).?.spawned_shell = true;
        self.ctx = self.session.focusedContext();
        break :blk h;
    };
    try reportStackChange(self, alloc);
    return handle;
}

/// Destroys a context `createShellContext` made, once its shell has
/// exited. Its pane shows whatever was under it. A no-op for a handle
/// that is already gone (its pane went first).
pub fn destroyShellContext(self: *Server, alloc: std.mem.Allocator, context: core.ContextHandle) !void {
    {
        const session_lock = self.lockSession();
        defer session_lock.unlock();
        self.session.destroyContext(context) catch return;
        self.ctx = self.session.focusedContext();
    }
    try reportStackChange(self, alloc);
}

/// What follows a pane stack changing outside any connection's
/// dispatch. Unconditional, unlike `activateContext`'s: the stack may
/// be a pane without focus, and the shells in it still have to hear
/// that their stack moved (`context` is what makes a waiting shell
/// re-read it).
fn reportStackChange(self: *Server, alloc: std.mem.Allocator) !void {
    try self.reportContext(alloc);
    try self.reportPaneFocusIfChanged(alloc);
    try self.syncConnectionFocus(alloc);
    try self.reportLayout(alloc);
}

/// Replaces the window theme (`core.Session.setTheme`) and sends a
/// `theme` notification to every `"theme"` subscriber whose context
/// follows it. glyphwire-host's theme switcher. A context with its
/// own theme hears nothing: nothing it drew changed.
pub fn setWindowTheme(self: *Server, alloc: std.mem.Allocator, t: core.theme.Theme) !void {
    var followers: std.ArrayList(core.ContextHandle) = .empty;
    defer followers.deinit(alloc);
    var name_buf: [core.theme.Stored.max_name_len]u8 = undefined;
    var panel_buf: [core.theme.Stored.max_name_len]u8 = undefined;
    var name: []const u8 = "";
    var panel: []const u8 = "";
    var dark = true;
    {
        const session_lock = self.lockSession();
        defer session_lock.unlock();
        self.session.setTheme(t);
        var it = self.session.contexts.iterator();
        while (it.next()) |e| {
            if (!e.value_ptr.*.theme_own) try followers.append(alloc, e.key_ptr.*);
        }
        // Copied out from under the lock: the stored strings are what
        // the session keeps, `t`'s may be borrowed.
        const st = &self.session.theme;
        name = name_buf[0..st.name().len];
        @memcpy(name_buf[0..name.len], st.name());
        panel = panel_buf[0..st.panelStyle().len];
        @memcpy(panel_buf[0..panel.len], st.panelStyle());
        dark = st.theme.dark;
    }

    const body = try rpc.themeNotification(alloc, name, dark, panel);
    defer alloc.free(body);

    self.registry_mutex.lockUncancelable(self.io);
    defer self.registry_mutex.unlock(self.io);
    for (self.connections.items) |conn| {
        if (!conn.route.attached) continue;
        if (!conn.route.subscriptions.has(.theme)) continue;
        if (std.mem.indexOfScalar(core.ContextHandle, followers.items, conn.route.active_ctx) == null) continue;
        conn.send(self.io, body) catch |err| {
            std.log.err("glyphwire theme notification to a connection failed: {t}", .{err});
        };
    }
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
        const session_lock = self.lockSession();
        defer session_lock.unlock();
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
        self.broadcast(null, .pane_layout, body);
    }
    try reportContextSizes(self, alloc);
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
        if (!conn.route.attached) continue;
        if (!conn.route.subscriptions.has(.resize)) continue;
        const size = blk: {
            const session_lock = self.lockSession();
            defer session_lock.unlock();
            const ctx = self.session.contextPtr(conn.route.active_ctx) orelse continue;
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
    self.broadcast(null, .pane_exit, body);
}

/// Tells every `remote`-subscribed connection that the remote session
/// `session` has ended. Broadcast rather than addressed: the waiter is
/// the requesting program's `InputListener`, a different connection
/// from the `Client` that sent `start_remote`, so the session id in the
/// body is what pairs the two up.
pub fn reportRemoteExit(self: *Server, alloc: std.mem.Allocator, session: u64, status: i64, started: bool) !void {
    const body = try rpc.remoteExitNotification(alloc, session, status, started);
    defer alloc.free(body);
    self.broadcast(null, .remote_exit, body);
}

/// In-process equivalent of a connected client's `report_key` request
/// (see dispatch.zig's `handleReportKey`) -- for whatever process owns
/// this `Server` and its `Context` directly (glyphwire-host) to report
/// input it captured itself, without a loopback connection to its own
/// socket. Updates the session's down-set and, if that's a real
/// change, broadcasts `key_down`/`key_up` to every subscribed
/// connection.
pub fn reportKey(self: *Server, alloc: std.mem.Allocator, key: []const u8, pressed: bool) !void {
    const decision = decision: {
        const session_lock = self.lockSession();
        defer session_lock.unlock();
        // The down-set is updated either way, even for a key the
        // prefix swallows: a program asking `get_input_state` should
        // see the real keyboard, and a release must find the press it
        // pairs with whichever context has focus by then (see
        // `core.InputState`). The prefix itself matches `Session.mods`.
        const changed = try self.session.input.setKey(key, pressed);
        const route = self.session.routeKey(key, pressed);
        // Read after `routeKey` has folded this key in, so a
        // modifier's own event reports itself.
        break :decision .{ .changed = changed, .route = route, .mods = self.session.mods };
    };

    switch (decision.route) {
        .swallow => return,
        .manager => {
            const body = try rpc.windowKeyNotification(alloc, key, pressed, decision.mods);
            defer alloc.free(body);
            self.deliverToManager(if (pressed) .window_key_down else .window_key_up, body);
            return;
        },
        .pass => {},
    }
    if (!decision.changed) return;

    const body = try rpc.keyNotification(alloc, key, pressed, decision.mods);
    defer alloc.free(body);
    self.broadcast(null, .key, body);
}

/// A synthetic key press-and-release delivered to `context`'s clients
/// only, whether or not that context has focus -- glyphwire-host's
/// wheel over a full-screen program (`less`, `htop`) in a pane, which
/// becomes arrow keys. `reportKey` would hand them to the *focused*
/// pane, so a wheel over htop moved the cursor in the salacommander
/// next to it. Bypasses the prefix and `Session.input`: no physical
/// key went down, so there is nothing to route or to keep pressed.
pub fn reportKeyTapIn(self: *Server, alloc: std.mem.Allocator, context: core.ContextHandle, key: []const u8) !void {
    const down = try rpc.keyNotification(alloc, key, true, .{});
    defer alloc.free(down);
    const up = try rpc.keyNotification(alloc, key, false, .{});
    defer alloc.free(up);
    sendTapToContext(self, context, .key, down, up);
}

/// A wheel notch (`wheel_up` / `wheel_down`) as a `mouse_button`
/// press-and-release delivered to `context`'s clients only -- the
/// wheel over a mouse-reporting program (htop, vim `mouse=a`) in any
/// pane, focused or not. Pointing at a pane and scrolling it shouldn't
/// first require clicking it. `cell` is in that context's own frame.
/// Bypasses `Session.input` like `reportKeyTapIn`: a wheel notch has no
/// held state to record.
pub fn reportWheelTapIn(
    self: *Server,
    alloc: std.mem.Allocator,
    context: core.ContextHandle,
    button: []const u8,
    px: core.PxPos,
    cell: core.CellPos,
) !void {
    const mods = blk: {
        const session_lock = self.lockSession();
        defer session_lock.unlock();
        break :blk self.session.mods;
    };
    const down = try rpc.mouseButtonNotification(alloc, button, true, px, cell, 0, mods, 1);
    defer alloc.free(down);
    const up = try rpc.mouseButtonNotification(alloc, button, false, px, cell, 0, mods, 1);
    defer alloc.free(up);
    sendTapToContext(self, context, .mouse_button, down, up);
}

/// Sends a press/release pair to every `event` subscriber whose
/// context is `context`, skipping the focus gate -- the addressed
/// delivery behind `reportKeyTapIn` / `reportWheelTapIn`.
fn sendTapToContext(self: *Server, context: core.ContextHandle, event: dispatch.PushEvent, down: []const u8, up: []const u8) void {
    self.registry_mutex.lockUncancelable(self.io);
    defer self.registry_mutex.unlock(self.io);
    for (self.connections.items) |conn| {
        if (conn.route.active_ctx != context) continue;
        if (!conn.route.attached) continue;
        if (!conn.route.subscriptions.has(event)) continue;
        conn.send(self.io, down) catch |err| {
            std.log.err("glyphwire: {t} tap to a connection failed: {t}", .{ event, err });
            continue;
        };
        conn.send(self.io, up) catch {};
    }
}

/// Re-broadcasts `key_down` for an already-held `key`, for a caller
/// driving its own typematic repeat (glyphwire-host's `App`, on an
/// arrow key held past the initial delay). Deliberately doesn't touch
/// `session.input`'s down-set: the key's already marked down from the
/// original press, so routing this through `reportKey`/`setKey` would
/// see no state change and silently swallow the repeat. Every
/// subscriber just sees another `key_down` for the same key, same as
/// `reportKey`'s -- no separate "this was a repeat" signal, since
/// nothing here needs to tell the difference from a fresh press.
pub fn reportKeyRepeat(self: *Server, alloc: std.mem.Allocator, key: []const u8) !void {
    // A held key while the prefix is armed must not repeat-fire a
    // window command, and must not reach the program either. Dropping
    // the repeat is the whole handling needed: prefix commands are
    // one-shot, so a repeat has nothing to mean. The same goes once the
    // command has fired, while the key is still held: its press was
    // withheld, so its repeats are too (`Session.isSwallowedKey`).
    const mods = mods: {
        const session_lock = self.lockSession();
        defer session_lock.unlock();
        if (self.session.prefix_armed) return;
        if (self.session.isSwallowedKey(key)) return;
        break :mods self.session.mods;
    };
    const body = try rpc.keyRepeatNotification(alloc, key, mods);
    defer alloc.free(body);
    self.broadcast(null, .key, body);
}

/// In-process equivalent of a connected client's `report_text`
/// notification (see `handleReportText`) -- committed text input
/// (`text` is a UTF-8 string of one or more codepoints, already
/// resolved through the OS layout / dead keys / IME). No `ctx` state
/// to touch, so no lock: just fans a `text` notification out to every
/// `"text"` subscriber. An empty string is a no-op.
pub fn reportText(self: *Server, alloc: std.mem.Allocator, text: []const u8) !void {
    if (text.len == 0) return;

    const route = route: {
        const session_lock = self.lockSession();
        defer session_lock.unlock();
        break :route self.session.routeText();
    };
    // Most window commands arrive here rather than through `reportKey`:
    // a plain printable key with no modifiers is delivered as text.
    if (route == .manager) {
        const body = try rpc.windowTextNotification(alloc, text);
        defer alloc.free(body);
        self.deliverToManager(.window_text, body);
        return;
    }

    const body = try rpc.textNotification(alloc, text);
    defer alloc.free(body);
    self.broadcast(null, .text, body);
}

/// In-process equivalent of `report_mouse_button` -- see `reportKey`.
/// `view_offset` is the root layer's current scrollback view offset
/// (see `core.Layer.view_scroll`), carried through into the broadcast
/// so a subscriber (glyphwire-shell) can resolve `cell` against the
/// same scrolled-back row the user actually clicked. `clicks` is the
/// press's count from the host's `core.ClickCounter` (1 = single).
pub fn reportMouseButton(self: *Server, alloc: std.mem.Allocator, button: []const u8, pressed: bool, px: core.PxPos, cell: core.CellPos, view_offset: usize, clicks: u8) !void {
    const changed, const mods = changed: {
        const session_lock = self.lockSession();
        defer session_lock.unlock();
        self.ctx.pointer.cursor_px = px;
        self.ctx.pointer.cursor_cell = cell;
        break :changed .{ try self.session.input.setMouseButton(button, pressed), self.session.mods };
    };
    if (!changed) return;

    const body = try rpc.mouseButtonNotification(alloc, button, pressed, px, cell, view_offset, mods, clicks);
    defer alloc.free(body);
    self.broadcast(null, .mouse_button, body);
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
        const session_lock = self.lockSession();
        defer session_lock.unlock();
        const ctx = contextOrFocused(self, context) orelse return;
        const before = ctx.root.view_scroll;
        const after = ctx.root.scrollView(offset, delta);
        break :blk .{ .changed = before != after, .offset = after, .max = ctx.root.history_len, .context = scopeOf(self, context) };
    };
    if (!result.changed) return;

    const body = try rpc.scrollNotification(alloc, null, result.offset, result.max);
    defer alloc.free(body);
    self.broadcastIn(null, result.context, .scroll, body);
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
        const session_lock = self.lockSession();
        defer session_lock.unlock();
        const ctx = contextOrFocused(self, context) orelse break :blk null;
        const l = ctx.layers.getPtr(layer) orelse break :blk null;
        const before = l.view_scroll;
        const after = l.scrollView(offset, delta);
        break :blk .{ .changed = before != after, .offset = after, .max = l.history_len, .context = scopeOf(self, context) };
    };
    const r = result orelse return;
    if (!r.changed) return;

    const body = try rpc.scrollNotification(alloc, layer, r.offset, r.max);
    defer alloc.free(body);
    self.broadcastIn(null, r.context, .scroll, body);
}

/// In-process equivalent of `report_mouse_move` -- see `reportKey`.
/// Keeps `get_input_state`'s cursor fields current every call, and
/// broadcasts a `mouse_move` notification (`{px, cell}`) to
/// `"mouse_move"` subscribers only when the pointer crossed into a
/// new cell -- matching `handleReportMouseMove` and keeping the
/// per-pixel motion the host reports off the wire. Cheap to call
/// every frame.
pub fn reportMouseMove(self: *Server, alloc: std.mem.Allocator, px: core.PxPos, cell: core.CellPos) !void {
    const cell_changed, const mods = changed: {
        const session_lock = self.lockSession();
        defer session_lock.unlock();
        const before = self.ctx.pointer.cursor_cell;
        self.ctx.pointer.cursor_px = px;
        self.ctx.pointer.cursor_cell = cell;
        break :changed .{ before.row != cell.row or before.col != cell.col, self.session.mods };
    };
    if (!cell_changed) return;

    const body = try rpc.mouseMoveNotification(alloc, px, cell, mods);
    defer alloc.free(body);
    self.broadcast(null, .mouse_move, body);
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
        const session_lock = self.lockSession();
        defer session_lock.unlock();
        if (cols == self.session.window_cols and rows == self.session.window_rows) return;
        try self.session.resizeWindow(cols, rows);
    }
    // `applyPaneLayout` is idempotent and does the rest: the
    // `pane_layout` broadcast for the manager, a tailored `resize` for
    // every client (its own pane's size, not the window's), and the
    // per-context `layout` for layer trees.
    try self.applyPaneLayout(alloc);
}

/// A font-size step: new cell pixel metrics for every context, and
/// the window's new size in cells now that the same pixels hold a
/// different number of them. Applied under one lock so no client can
/// read the new metrics against the old grid, or the reverse.
///
/// Unlike `reportResize` this always tells every client, even when the
/// grid came out the same size: the cells themselves changed, and a
/// client that sizes anything in pixels (an image, a rect) has to
/// re-read `get_cell_metrics`. A `resize` is that signal -- there is
/// no separate cell-metrics notification, and every client that works
/// in pixels already re-reads the metrics on `resize`.
///
/// Every context is caught up, backgrounded ones included: the metrics
/// through `Session.setCellMetricsAll`, and the size through the pane
/// layout, which resizes each context in a mapped pane whether or not
/// it is the one on screen. A context in an unmapped pane keeps its
/// cell size until its pane is laid out again, as with any resize.
pub fn reportFontStep(
    self: *Server,
    alloc: std.mem.Allocator,
    cell_px_w: u32,
    cell_px_h: u32,
    cols: usize,
    rows: usize,
) !void {
    {
        const session_lock = self.lockSession();
        defer session_lock.unlock();
        self.session.setCellMetricsAll(cell_px_w, cell_px_h);
        try self.session.resizeWindow(cols, rows);
    }
    // Idempotent over an unchanged grid, but its per-connection
    // `resize` always goes out -- which is the point here.
    try self.applyPaneLayout(alloc);
}

/// The host's window gained or lost the keyboard (glyphwire-host
/// calls this on the edge only). Every connection's `focus` follows
/// it, combined with which pane has focus -- see
/// `syncConnectionFocus`.
pub fn reportFocus(self: *Server, alloc: std.mem.Allocator, focused: bool) !void {
    {
        const session_lock = self.lockSession();
        defer session_lock.unlock();
        self.window_focused = focused;
    }
    try self.syncConnectionFocus(alloc);
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
    self.broadcast(null, .shutdown, body);
}

/// Re-lays-out the split tree against the current context size and
/// broadcasts a `layout` notification for every pane whose bounds
/// moved. Silent when there is no split tree, or when the layout came
/// out identical -- which is what makes it safe to call after any
/// change that *might* have moved something.
pub fn reportLayout(self: *Server, alloc: std.mem.Allocator) !void {
    // One notification per pane's on-screen context, each delivered to
    // that context's clients only. A resize moves the layer trees in
    // every pane at once, but layer handles are per-context -- every
    // context numbers its layers from 1 -- so one pooled `layout` told
    // the zoe in one pane to move its layers to where the zoe in the
    // other pane's layers were, and the last entry won.
    var per_context: std.ArrayList(ContextLayout) = .empty;
    defer {
        for (per_context.items) |*cl| cl.bounds.deinit(cl.bounds_alloc);
        per_context.deinit(alloc);
    }
    {
        const session_lock = self.lockSession();
        defer session_lock.unlock();
        var it = self.session.panes.valueIterator();
        while (it.next()) |pane| {
            if (!pane.mapped) continue;
            const handle = pane.top();
            const ctx = self.session.contextPtr(handle) orelse continue;
            // `layoutSplits` appends through the context's own
            // allocator, so that is what frees it.
            var changed: std.ArrayList(core.LayerBounds) = .empty;
            errdefer changed.deinit(ctx.alloc);
            try ctx.layoutSplits(&changed, null);
            if (changed.items.len == 0) {
                changed.deinit(ctx.alloc);
                continue;
            }
            try per_context.append(alloc, .{ .context = handle, .bounds = changed, .bounds_alloc = ctx.alloc });
        }
    }

    for (per_context.items) |cl| {
        const bounds = try alloc.alloc(protocol.LayoutBounds, cl.bounds.items.len);
        defer alloc.free(bounds);
        for (cl.bounds.items, 0..) |b, i| {
            bounds[i] = .{ .layer = b.layer, .row = b.row, .col = b.col, .cols = b.cols, .rows = b.rows };
        }
        const body = try rpc.layoutNotification(alloc, bounds);
        defer alloc.free(body);
        self.broadcastIn(null, cl.context, .layout, body);
    }
}

const ContextLayout = struct {
    context: core.ContextHandle,
    bounds: std.ArrayList(core.LayerBounds),
    bounds_alloc: std.mem.Allocator,
};

/// Broadcasts a `layer_resize` notification -- glyphwire-host's drag
/// of a layer's `resize_edge` ended and the user wants it `cols` x
/// `rows`. Touches no context state: the client that owns the layer
/// is the one that resizes it (see `core.ResizeEdge`).
pub fn reportLayerResize(self: *Server, alloc: std.mem.Allocator, context: core.ContextHandle, layer: core.LayerHandle, cols: usize, rows: usize) !void {
    const body = try rpc.layerResizeNotification(alloc, context, layer, cols, rows);
    defer alloc.free(body);
    self.broadcast(null, .layer_resize, body);
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
        const session_lock = self.lockSession();
        defer session_lock.unlock();
        const ctx = contextOrFocused(self, context) orelse return;
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
            .context = scopeOf(self, context),
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
    self.broadcastIn(null, result.context, .scroll_offset, body);
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
        const session_lock = self.lockSession();
        defer session_lock.unlock();
        const layer = self.ctx.layerPtr(layer_handle) orelse return;
        layer.sel.set(anchor, active);
        break :blk layer.sel.range;
    };
    const body = try rpc.selectionNotification(alloc, snapshot);
    defer alloc.free(body);
    self.broadcast(null, .selection, body);
}

/// In-process `clear_selection` on `layer_handle` (null = root).
pub fn clearSelection(self: *Server, alloc: std.mem.Allocator, layer_handle: ?core.LayerHandle) !void {
    {
        const session_lock = self.lockSession();
        defer session_lock.unlock();
        const layer = self.ctx.layerPtr(layer_handle) orelse return;
        layer.sel.clear();
    }
    const body = try rpc.selectionNotification(alloc, null);
    defer alloc.free(body);
    self.broadcast(null, .selection, body);
}

/// Which layer of the visible context currently holds a selection --
/// the topmost `create_layer` layer with one, else root (reported as
/// `null`, the handle every selection call takes for it), else `null`
/// again when nothing anywhere is selected.
///
/// A selection can be set on any layer, by the host's own drag or by
/// a client's `set_selection`, so "the selection" is not a fixed
/// place. glyphwire-host's copy shortcut asks this rather than
/// assuming root; at most one layer is ever selected in practice
/// (every writer clears the old one first), and topmost-first
/// resolves the tie the way the user's eye does.
pub fn selectedLayer(self: *Server) ?core.LayerHandle {
    const session_lock = self.lockSession();
    defer session_lock.unlock();

    var i = self.ctx.layer_order.items.len;
    while (i > 0) {
        i -= 1;
        const handle = self.ctx.layer_order.items[i];
        const layer = self.ctx.layers.getPtr(handle) orelse continue;
        if (layer.sel.range != null) return handle;
    }
    return null;
}

/// The selected text on `layer_handle` (null = root), or null when
/// nothing is selected. Caller owns the result.
pub fn selectionText(self: *Server, alloc: std.mem.Allocator, layer_handle: ?core.LayerHandle) !?[]u8 {
    const session_lock = self.lockSession();
    defer session_lock.unlock();
    const layer = self.ctx.layerPtr(layer_handle) orelse return null;
    return layer.sel.text(alloc);
}

/// The word or line around `p` on `layer_handle` (null = root) -- what
/// glyphwire-host's double/triple-click selects. Null when the layer
/// is gone. See `core.LayerSelection.unitSpanAt`.
pub fn selectionUnitAt(self: *Server, layer_handle: ?core.LayerHandle, p: core.SelectionPoint, unit: core.SelectUnit) ?core.UnitSpan {
    const session_lock = self.lockSession();
    defer session_lock.unlock();
    const layer = self.ctx.layerPtr(layer_handle) orelse return null;
    return layer.sel.unitSpanAt(p, unit);
}

/// Replaces the session clipboard buffer (and bumps its serial, so
/// glyphwire-host's next frame pushes it to the OS). Does not
/// broadcast -- `set_clipboard` has no server->client counterpart.
pub fn setClipboard(self: *Server, text: []const u8) !void {
    const session_lock = self.lockSession();
    defer session_lock.unlock();
    try self.session.setClipboard(text);
}

/// Sends a `copy_request` notification to the `"clipboard"` subscriber
/// whose context is on screen -- the host calls this when the copy
/// shortcut is pressed with nothing selected, so glyphwire-shell can
/// answer with its current prompt (or salacommander with the active
/// pane's paths) via `set_clipboard`.
///
/// Broadcast under `"copy_request"` rather than the stream name the
/// two clipboard events share, because only this one is focus-gated
/// (`dispatch.Delivery.focus_gated`): the answer is a single clipboard write, so
/// asking every subscriber would just mean the last reply wins.
pub fn requestCopy(self: *Server, alloc: std.mem.Allocator) !void {
    const body = try rpc.copyRequestNotification(alloc);
    defer alloc.free(body);
    self.broadcast(null, .copy_request, body);
}

/// Sends a `paste` notification (committed clipboard text) to the
/// focused pane's on-screen client, the same gate as typed text
/// (`dispatch.Delivery.focus_gated`). It is the answer to one keystroke: fanned
/// out, a path pasted into a shell pane also landed in the zoe buffer
/// next to it.
pub fn broadcastPaste(self: *Server, alloc: std.mem.Allocator, text: []const u8) !void {
    const body = try rpc.pasteNotification(alloc, text);
    defer alloc.free(body);
    self.broadcast(null, .paste, body);
}

/// The current session clipboard serial (see
/// `core.Session.clipboard_serial`) -- glyphwire-host polls this each
/// frame to decide whether to push the buffer to the OS clipboard.
pub fn clipboardSerial(self: *Server) u64 {
    const session_lock = self.lockSession();
    defer session_lock.unlock();
    return self.session.clipboard_serial;
}

/// A copy of the current session clipboard buffer. Caller owns it.
pub fn clipboardText(self: *Server, alloc: std.mem.Allocator) ![]u8 {
    const session_lock = self.lockSession();
    defer session_lock.unlock();
    return alloc.dupe(u8, self.session.clipboardText());
}
