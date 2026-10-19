// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: GPL-3.0-or-later

//! Setting up a session the way a real one starts, for the test groups
//! that drive one: every connection the host serves has to be let into a
//! context (`core.AccessToken`), and only the window manager may inject
//! input. These do the letting-in, so each test says what it's about
//! rather than repeating it. Not a test group of its own.

const std = @import("std");
const glyphwire = @import("glyphwire");
const dispatch = glyphwire.dispatch;

/// A dispatcher for socket connection `cid`, with access to the context it
/// starts on, as a program the host started there has once it attached
/// with its `GLYPHWIRE_TOKEN`. A test that needs a spawner or remote
/// starter sets `spawner` / `remote_starter` on the result.
pub fn attachedConnection(session: *glyphwire.Session, cid: glyphwire.ConnId) !dispatch.Dispatcher {
    const d = dispatch.Dispatcher.initForConnection(session, cid, null, null);
    try session.addContextMember(session.focusedContextHandle(), cid);
    return d;
}

/// `attachedConnection`, holding the window-manager role too: what a test
/// injecting `report_*` input needs.
pub fn managerConnection(session: *glyphwire.Session, cid: glyphwire.ConnId) !dispatch.Dispatcher {
    const d = try attachedConnection(session, cid);
    if (session.claimManager(cid, 0) == null) return error.ManagerRoleTaken;
    return d;
}

/// Binds a `Server` on `ctx` and tells this process's client library the
/// root context's token, as glyphwire-host's `GLYPHWIRE_TOKEN` would, so
/// every `Client` / `InputListener` the test opens is let in.
pub fn bindServer(io: std.Io, ctx: *glyphwire.Context, socket_path: []const u8) !glyphwire.server.Server {
    const srv = try glyphwire.server.Server.bind(io, ctx, socket_path);
    glyphwire.client.noteContext(glyphwire.root_context_handle, ctx.token);
    return srv;
}

/// A `Client` holding the window-manager role, for a test that injects
/// input over the socket.
pub fn connectReporter(io: std.Io, alloc: std.mem.Allocator, socket_path: []const u8) !glyphwire.Client {
    var client = try glyphwire.Client.connect(io, alloc, socket_path);
    errdefer client.deinit();
    _ = try client.requestWindowManager();
    return client;
}

/// The discovery variables glyphwire-host gives its shell: the socket,
/// and the root context with the token `bindServer` noted.
pub fn putSessionEnv(env: *std.process.Environ.Map, socket_path: []const u8) !void {
    try env.put("GLYPHWIRE_SOCK", socket_path);
    try env.put("GLYPHWIRE_CTX", glyphwire.default_context_id);
    if (glyphwire.client.processToken()) |token| try env.put("GLYPHWIRE_TOKEN", &token);
}
