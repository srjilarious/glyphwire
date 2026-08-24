const std = @import("std");
const glyphwire = @import("glyphwire");

/// Minimal glyphwire server executable: binds a Unix domain socket and
/// serves one auto-created `Context` to whoever connects. No
/// `create_context` yet — see decisions.md, Object Model.
pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 2) {
        std.debug.print("usage: {s} <socket-path>\n", .{args[0]});
        return error.MissingSocketPath;
    }
    const socket_path = args[1];

    // Scrollback is a per-layer creation parameter (see core.zig); until
    // `create_context` exists over the wire, this default stands in for
    // what a real shell would specify when allocating its root context.
    const default_scrollback_rows = 1000;
    var ctx = try glyphwire.Context.init(init.gpa, 80, 24, default_scrollback_rows);
    defer ctx.deinit();

    var srv = try glyphwire.server.Server.bind(init.io, &ctx, socket_path);
    defer srv.deinit();

    std.debug.print("glyphwire server listening on {s}\n", .{socket_path});
    try srv.serveForever(init.gpa);
}
