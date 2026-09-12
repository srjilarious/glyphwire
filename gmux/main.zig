//! `gmux` -- a terminal multiplexer for glyphwire: split panes, each
//! seated on its own PTY-driven shell. See `ui.zig` for the client and
//! `docs/decisions.md`'s gmux section for the design.
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

    const listener = glyphwire.InputListener.connectFromEnv(io, alloc, init.environ_map, &.{
        "key",
        "text",
        "paste",
        "layout",
        "mouse_button",
        "context",
    }, null) catch {
        try write(io, "gmux: no glyphwire session (GLYPHWIRE_SOCK not set)\n");
        return error.NoSession;
    };
    defer listener.deinit();

    var cfg = gmux.config.load(alloc, io, init.environ_map);
    defer cfg.deinit();

    const ui = try gmux.ui.Ui.init(alloc, io, &client, listener, &cfg);
    defer ui.deinit();

    try ui.run();
}

fn write(io: std.Io, text: []const u8) !void {
    var buf: [256]u8 = undefined;
    var w = std.Io.File.stdout().writer(io, &buf);
    try w.interface.writeAll(text);
    try w.interface.flush();
}
