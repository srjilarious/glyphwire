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
    const socket_path = init.environ_map.get("GLYPHWIRE_SOCK") orelse return fallback(init.io);

    sendHello(init.io, socket_path) catch return fallback(init.io);
}

fn fallback(io: std.Io) !void {
    var buf: [16]u8 = undefined;
    var w = std.Io.File.stdout().writer(io, &buf);
    try w.interface.writeAll("hello\n");
    try w.interface.flush();
}

fn sendHello(io: std.Io, socket_path: []const u8) !void {
    const addr = try std.Io.net.UnixAddress.init(socket_path);
    var stream = try addr.connect(io);
    defer stream.close(io);

    var write_buf: [256]u8 = undefined;
    var w = stream.writer(io, &write_buf);
    try glyphwire.wire.writeFrame(&w.interface,
        \\{"jsonrpc":"2.0","method":"write_text","params":{"text":"hello"}}
    );
    try w.interface.flush();
}
