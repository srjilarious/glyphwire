// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: GPL-3.0-or-later

const std = @import("std");
const testz = @import("testz");
const cli = @import("applib").cli;

/// No `GLYPHWIRE_SOCK` is `NoSession`, the error a program's headless
/// fallback branches on.
pub fn connectWithoutSessionIsNoSessionTest(io: std.Io, alloc: std.mem.Allocator) !void {
    var env: std.process.Environ.Map = .init(alloc);
    defer env.deinit();
    try testz.expectError(cli.connect(io, alloc, &env, &.{"key"}), error.NoSession);
}

/// A socket path nobody listens on is no session either.
pub fn connectToDeadSocketIsNoSessionTest(io: std.Io, alloc: std.mem.Allocator) !void {
    var env: std.process.Environ.Map = .init(alloc);
    defer env.deinit();
    try env.put("GLYPHWIRE_SOCK", "/nonexistent-glyphwire-test.sock");
    try testz.expectError(cli.connect(io, alloc, &env, &.{"key"}), error.NoSession);
}
