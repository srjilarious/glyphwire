// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: MPL-2.0

//! Keeping Ctrl+C for a program that has a use of its own for it.
//!
//! glyphwire-shell turns Ctrl+C into a SIGINT to a foreground
//! glyphwire-aware program's whole process group, the way a terminal's
//! line discipline does for a plain one, so a one-shot tool like `gw-grep`
//! can be stopped. An interactive program that binds Ctrl+C itself (zoe's
//! vim-style cancel, gw-hist's and the finder popup's dismiss) or would
//! lose work to it calls `keep` at startup: the key still arrives on its
//! own listener, and the signal does nothing.
//!
//! A no-op **handler** rather than `SIG_IGN`, on purpose. An ignored
//! signal stays ignored across `exec`, so everything the program ran --
//! an embedded `gw-shell` panel and every command typed into it -- would
//! be un-interruptible too. A caught signal goes back to its default on
//! `exec`, so children start out normal. A helper that must outlive a
//! Ctrl+C aimed at its parent (a language server, an embedded panel's
//! shell) is started in a process group of its own instead (`pgid = 0`),
//! where the parent's group signal never reaches it.

const std = @import("std");
const posix = std.posix;

/// Makes SIGINT a no-op for this process. See the module comment.
pub fn keep() void {
    if (posix.Sigaction == void) return;
    const act: posix.Sigaction = .{
        .handler = .{ .handler = ignoreSignal },
        .mask = posix.sigemptyset(),
        // Restart whatever blocking call it landed in, so a Ctrl+C never
        // surfaces as a spurious `error.Interrupted` somewhere.
        .flags = posix.SA.RESTART,
    };
    posix.sigaction(.INT, &act, null);
}

fn ignoreSignal(_: posix.SIG) callconv(.c) void {}
