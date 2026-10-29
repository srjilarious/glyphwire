// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: MPL-2.0

//! The startup boilerplate every interactive glyphwire client repeats:
//! bail out with a message on stderr, and open the two connections a
//! full-screen program runs on (a `Client` for requests and drawing, an
//! `InputListener` subscribed to the events it handles).
//!
//! `connect` hands the failure back, for a program with a headless
//! fallback (gwmd's dump, gw-read's listing, zoe's message); `connectOrFail`
//! is for one with none. Programs that write into the shell's own layer
//! without a listener (gw-ls, gw-grep) don't use either.

const std = @import("std");
const glyphwire = @import("glyphwire");

/// Prints `fmt` to stderr and exits with status 1. A write error is
/// ignored: there's nowhere left to report it.
pub fn fail(io: std.Io, comptime fmt: []const u8, args: anytype) noreturn {
    var buf: [1024]u8 = undefined;
    var w = std.Io.File.stderr().writer(io, &buf);
    w.interface.print(fmt, args) catch {};
    w.interface.flush() catch {};
    std.process.exit(1);
}

/// The two connections a full-screen client runs on. `client` is held by
/// value, so keep the `Connection` itself where it won't move while
/// something points at `client`.
pub const Connection = struct {
    client: glyphwire.Client,
    listener: *glyphwire.InputListener,

    pub fn deinit(self: *Connection) void {
        self.listener.deinit();
        self.client.deinit();
    }
};

pub const ConnectError = error{
    /// No `GLYPHWIRE_SOCK`, or nothing listening on it.
    NoSession,
    /// The client connected but the listener's subscription failed.
    SubscribeFailed,
};

/// Connects a client and a listener subscribed to `streams`, both from
/// `GLYPHWIRE_SOCK`. On failure nothing is left open.
pub fn connect(
    io: std.Io,
    alloc: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
    streams: []const glyphwire.dispatch.Stream,
) ConnectError!Connection {
    var client = glyphwire.Client.connectFromEnv(io, alloc, environ) catch return error.NoSession;
    errdefer client.deinit();
    const listener = glyphwire.InputListener.connectFromEnv(io, alloc, environ, streams) catch
        return error.SubscribeFailed;
    return .{ .client = client, .listener = listener };
}

/// `connect`, exiting with `<prog>: ...` on stderr when it fails.
pub fn connectOrFail(
    io: std.Io,
    alloc: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
    prog: []const u8,
    streams: []const glyphwire.dispatch.Stream,
) Connection {
    return connect(io, alloc, environ, streams) catch |err| switch (err) {
        error.NoSession => fail(io, "{s}: needs a glyphwire session (GLYPHWIRE_SOCK not set)\n", .{prog}),
        error.SubscribeFailed => fail(io, "{s}: couldn't subscribe to input\n", .{prog}),
    };
}
