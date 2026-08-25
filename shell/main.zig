const std = @import("std");
const glyphwire = @import("glyphwire");

const c = struct {
    extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
    extern "c" fn execvp(file: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;
};

/// glyphwire-shell: sets up discovery for a child command and execs into
/// it -- see decisions.md, Discovery & Connection. Deliberately has no
/// pixzig dependency and no special access to the Context: it relates to
/// the server exactly the way any other program does, purely through the
/// socket (see src/client.zig for a real client of it). The window/render
/// side lives entirely in glyphwire-host now.
///
/// Dual-mode for discovery: if GLYPHWIRE_SOCK is already set (inherited
/// from a parent -- typically glyphwire-host, which owns starting the
/// server these days), trusts it and execs straight into the child.
/// Otherwise spawns its own server, exactly like the original milestone-5
/// launcher, so `zig build shell -- <cmd>` still works standalone.
pub fn main(init: std.process.Init) !void {
    const alloc = init.arena.allocator();
    const args = try init.minimal.args.toSlice(alloc);
    if (args.len < 2) {
        std.debug.print("usage: {s} <command> [args...]\n", .{args[0]});
        return error.MissingCommand;
    }

    if (init.environ_map.get("GLYPHWIRE_SOCK") == null) {
        try spawnOwnServer(init.io, alloc, init.environ_map);
    }

    const child_argv = try alloc.allocSentinel(?[*:0]const u8, args.len - 1, null);
    for (args[1..], 0..) |arg, i| child_argv[i] = arg.ptr;

    _ = c.execvp(args[1].ptr, child_argv.ptr);
    // execvp only returns on failure.
    std.debug.print("failed to exec {s}\n", .{args[1]});
    return error.ExecFailed;
}

fn spawnOwnServer(io: std.Io, alloc: std.mem.Allocator, environ_map: *const std.process.Environ.Map) !void {
    const socket_path = try socketPath(alloc, environ_map);

    // Relies on PATH resolution (std.process.spawn resolves argv[0] via the
    // parent's PATH when it contains no '/'), the same way any installed
    // pair of binaries would find each other — no self-exe lookup needed.
    var server_child = try std.process.spawn(io, .{
        .argv = &.{ "glyphwire-server", socket_path },
    });
    // Deliberately not waited on here: it keeps running as a background
    // process (later an orphan, reparented by the kernel) after this
    // process execs into the child command below.
    _ = &server_child;

    try waitForSocketReady(io, socket_path);

    const socket_path_z = try alloc.dupeZ(u8, socket_path);
    if (c.setenv("GLYPHWIRE_SOCK", socket_path_z, 1) != 0) return error.SetEnvFailed;
    if (c.setenv("GLYPHWIRE_CTX", glyphwire.default_context_id, 1) != 0) return error.SetEnvFailed;
}

fn socketPath(alloc: std.mem.Allocator, environ_map: *const std.process.Environ.Map) ![]const u8 {
    const dir = environ_map.get("XDG_RUNTIME_DIR") orelse "/tmp";
    const pid = std.os.linux.getpid();
    return std.fmt.allocPrint(alloc, "{s}/glyphwire-{d}.sock", .{ dir, pid });
}

fn waitForSocketReady(io: std.Io, socket_path: []const u8) !void {
    const addr = try std.Io.net.UnixAddress.init(socket_path);
    var attempt: usize = 0;
    while (attempt < 100) : (attempt += 1) {
        if (addr.connect(io)) |stream| {
            var s = stream;
            s.close(io);
            return;
        } else |_| {
            try std.Io.sleep(io, .fromMilliseconds(10), .awake);
        }
    }
    return error.ServerNeverCameUp;
}
