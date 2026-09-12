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
const gmux = @import("gmux_support");

pub fn main(init: std.process.Init) !void {
    const alloc = init.gpa;
    const io = init.io;

    var client = glyphwire.Client.connectFromEnv(io, alloc, init.environ_map) catch {
        try write(io, "gmux: no glyphwire session (GLYPHWIRE_SOCK not set)\n");
        return error.NoSession;
    };
    defer client.deinit();

    // Deliberately *not* subscribed to `key` / `text`: gmux never wants a
    // program's keystrokes, and could not receive them anyway (it is never
    // in the focused pane). `window_keys` is the prefix-command stream the
    // session addresses to us; `panes` carries pane rects and exits.
    const listener = glyphwire.InputListener.connectFromEnv(io, alloc, init.environ_map, &.{
        "window_keys",
        "panes",
        "shutdown",
    }) catch {
        try write(io, "gmux: no glyphwire session (GLYPHWIRE_SOCK not set)\n");
        return error.NoSession;
    };
    defer listener.deinit();

    var cfg = gmux.config.load(alloc, io, init.environ_map);
    defer cfg.deinit();

    const ui = gmux.ui.Ui.init(alloc, io, &client, listener, &cfg) catch |err| switch (err) {
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
