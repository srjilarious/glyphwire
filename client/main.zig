const std = @import("std");
const glyphwire = @import("glyphwire");

/// Smallest possible glyphwire-aware program (Milestone 6): checks for
/// discovery, connects if possible, sends write_text("hello") with no
/// positioning, and exits. Falls back to printing "hello" straight to
/// stdout — the same content a plain, non-glyphwire-aware program would
/// produce — when discovery isn't available. Per decisions.md's Discovery
/// & Connection: "if either check fails ... it prints its fallback
/// message to stdout and degrades ... never partially assuming the grid
/// is present."
pub fn main(init: std.process.Init) !void {
    sendHello(init) catch return fallback(init.io);
}

fn fallback(io: std.Io) !void {
    var buf: [16]u8 = undefined;
    var w = std.Io.File.stdout().writer(io, &buf);
    try w.interface.writeAll("hello\n");
    try w.interface.flush();
}

fn sendHello(init: std.process.Init) !void {
    var client = try glyphwire.Client.connectFromEnv(init.io, init.gpa, init.environ_map);
    defer client.deinit();

    try client.writeText("hello", null, null);
}
