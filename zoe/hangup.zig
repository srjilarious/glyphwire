// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: GPL-3.0-or-later

//! Turning SIGHUP / SIGTERM into an orderly exit.
//!
//! Closing zoe's window (or its pane) makes glyphwire-host send SIGHUP to
//! the pane's process group, and by default that kills zoe on the spot.
//! zoe wants one last turn first -- to rewrite its `.zoe-workspace` (see
//! `Ui.autosaveWorkspace`) -- so `watch` catches both signals and the run
//! loop quits the way `:q` does.
//!
//! The handler itself only writes a byte down a pipe: nothing else is
//! async-signal-safe, and `InputListener.wake` takes a mutex. A watcher
//! thread blocks on the pipe's other end and does the waking. The handler
//! is installed with `RESETHAND`, so a second signal, if zoe is wedged,
//! kills it the ordinary way.

const std = @import("std");
const glyphwire = @import("glyphwire");
const posix = std.posix;

/// Set once a SIGHUP / SIGTERM has arrived.
var requested_flag: std.atomic.Value(bool) = .init(false);
/// The pipe the handler writes to and the watcher reads.
var pipe_fds: [2]posix.fd_t = .{ -1, -1 };

/// Whether a SIGHUP / SIGTERM has asked zoe to go.
pub fn requested() bool {
    return requested_flag.load(.acquire);
}

/// Installs the handlers and starts the thread that wakes `listener`
/// when one fires. Call once, before the run loop.
pub fn watch(listener: *glyphwire.InputListener) !void {
    if (posix.Sigaction == void) return;
    // Close-on-exec: the shell panel and the language servers have no
    // business holding either end.
    if (std.c.pipe2(&pipe_fds, .{ .CLOEXEC = true }) != 0) return error.PipeFailed;
    const thread = try std.Thread.spawn(.{}, watchThread, .{listener});
    thread.detach();

    const act: posix.Sigaction = .{
        .handler = .{ .handler = onSignal },
        .mask = posix.sigemptyset(),
        .flags = posix.SA.RESTART | posix.SA.RESETHAND,
    };
    posix.sigaction(.HUP, &act, null);
    posix.sigaction(.TERM, &act, null);
}

fn onSignal(_: posix.SIG) callconv(.c) void {
    const byte: [1]u8 = .{1};
    _ = std.c.write(pipe_fds[1], &byte, 1);
}

fn watchThread(listener: *glyphwire.InputListener) void {
    var byte: [1]u8 = undefined;
    while (true) {
        const n = std.c.read(pipe_fds[0], &byte, 1);
        if (n > 0) break;
        // Only an interrupted read is worth another try.
        if (n < 0 and std.c._errno().* == @intFromEnum(posix.E.INTR)) continue;
        return;
    }
    requested_flag.store(true, .release);
    listener.wake();
}
