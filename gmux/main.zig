// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: GPL-3.0-or-later

//! `gmux` -- a terminal multiplexer for glyphwire: a split tree of panes,
//! each running a program of its own. See `ui.zig` for the client and
//! `docs/decisions.md`'s gmux section for the design.
//!
//! gmux is a pure window manager: it draws nothing, owns no context, and
//! never touches a program's input or output. It asks the server for panes
//! and tells it where they go; the panes do the rest.
//!
//! Launched from a glyphwire-aware shell (`GLYPHWIRE_SOCK` set), same as
//! `zoe`. Outside one, there's nothing to run against -- gmux has no
//! headless mode.

const std = @import("std");
const glyphwire = @import("glyphwire");
const build_info = @import("build_info");
const gmux = @import("gmux_support");
const interrupt = @import("applib").interrupt;
const cli = @import("applib").cli;

pub fn main(init: std.process.Init) !void {
    const alloc = init.gpa;
    const io = init.io;
    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    if (argv.len >= 2 and glyphwire.version.isFlag(argv[1])) glyphwire.version.printAndExit(io, .of(build_info));

    // A Ctrl+C typed into a pane is that pane's program's business;
    // the shell that started gmux sees the key too and must not take the
    // whole multiplexer down with it.
    // See `applib.interrupt`.
    interrupt.keep();

    // `window_keys` is the prefix-command stream the session addresses to
    // us; `panes` carries pane rects and exits. The raw input streams are
    // gmux's own overlay's (the palette, layout mode): the listener binds
    // to that pane before anything can focus it (`Ui.init`), and the
    // session gates raw input on focus, so a program's keystrokes still
    // never arrive here. `resize` and `theme` follow the overlay too.
    var conn = cli.connectOrFail(io, alloc, init.environ_map, "gmux", &.{
        .window_keys,
        .panes,
        .shutdown,
        .key,
        .text,
        .clipboard,
        .mouse_button,
        .mouse_move,
        .scroll,
        .resize,
        .theme,
    });
    defer conn.deinit();

    var cfg = gmux.config.load(alloc, io, init.environ_map);
    defer cfg.deinit();

    const ui = gmux.ui.Ui.init(alloc, io, &conn.client, conn.listener, &cfg) catch |err| switch (err) {
        error.WindowManagerTaken => {
            try write(io, "gmux: a multiplexer is already running in this window\n");
            return err;
        },
        else => return err,
    };
    defer ui.deinit();

    try ui.run();
}

fn write(io: std.Io, text: []const u8) !void {
    var buf: [256]u8 = undefined;
    var w = std.Io.File.stdout().writer(io, &buf);
    try w.interface.writeAll(text);
    try w.interface.flush();
}
