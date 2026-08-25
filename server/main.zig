const std = @import("std");
const glyphwire = @import("glyphwire");

/// Minimal glyphwire server executable: binds a Unix domain socket and
/// serves one auto-created `Context` to whoever connects. No
/// `create_context` yet — see decisions.md, Object Model. `cols`/`rows`
/// are optional CLI args (not part of the wire protocol) so a caller that
/// cares about grid size -- glyphwire-host, sizing its window to match --
/// has a way to specify it; standalone use (tests, `zig build server`)
/// falls back to a plain 80x24 default.
pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 2) {
        std.debug.print("usage: {s} <socket-path> [cols] [rows]\n", .{args[0]});
        return error.MissingSocketPath;
    }
    const socket_path = args[1];
    const cols = if (args.len >= 3) try std.fmt.parseInt(usize, args[2], 10) else 80;
    const rows = if (args.len >= 4) try std.fmt.parseInt(usize, args[3], 10) else 24;

    // Scrollback is a per-layer creation parameter (see core.zig); until
    // `create_context` exists over the wire, this default stands in for
    // what a real shell would specify when allocating its root context.
    const default_scrollback_rows = 1000;
    var ctx = try glyphwire.Context.init(init.gpa, cols, rows, default_scrollback_rows);
    defer ctx.deinit();

    var srv = try glyphwire.server.Server.bind(init.io, &ctx, socket_path);
    defer srv.deinit(init.gpa);

    std.debug.print("glyphwire server listening on {s}\n", .{socket_path});
    try srv.serveForever(init.gpa);
}
