//! `gw-agent` -- the remote half of a `glyphwire --ssh <dest>` session.
//!
//! Launched by the local host as `ssh -T <dest> -- gw-agent --stdio`, so
//! its stdin/stdout are the trunk to the host (see `src/mux.zig`). It:
//!
//!   1. opens a normal `GLYPHWIRE_SOCK` Unix socket on the remote box,
//!   2. spawns the remote `gw-shell` pointed at it,
//!   3. bridges every client that dials that socket (`gw-shell`, and the
//!      `gw-ls` / `gw-view` / `zoe` it launches, each plus its
//!      `InputListener`) onto its own mux channel on the trunk.
//!
//! The host turns each channel back into a `Server` connection, so the
//! remote clients drive the host's grid exactly as local ones do -- image
//! side-channel and all. The agent never parses the glyphwire protocol;
//! it shuttles bytes.
//!
//! `gw-agent --askpass <prompt>` is a second mode: the `SSH_ASKPASS`
//! helper the host points `ssh` at, so password / passphrase / host-key
//! prompts surface in the glyphwire window instead of a dead tty. It just
//! relays the prompt over `GLYPHWIRE_ASKPASS_SOCK` and prints the reply.

const std = @import("std");
const glyphwire = @import("glyphwire");
const mux = glyphwire.mux;

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    if (args.len >= 2 and std.mem.eql(u8, args[1], "--stdio")) {
        return runStdio(init);
    }
    if (args.len >= 2 and std.mem.eql(u8, args[1], "--askpass")) {
        return runAskpass(init, if (args.len >= 3) args[2] else "");
    }
    // Invoked as `SSH_ASKPASS`: `ssh` runs us as `gw-agent "<prompt>"`
    // (one bare argument) with `GLYPHWIRE_ASKPASS_SOCK` set for us alone.
    if (args.len == 2 and !std.mem.startsWith(u8, args[1], "-") and
        init.environ_map.get("GLYPHWIRE_ASKPASS_SOCK") != null)
    {
        return runAskpass(init, args[1]);
    }

    var buf: [256]u8 = undefined;
    var w = std.Io.File.stderr().writer(init.io, &buf);
    try w.interface.print(
        "usage: {s} --stdio            (trunk endpoint, run over ssh)\n" ++
        "       {s} --askpass <text>   (SSH_ASKPASS helper)\n",
        .{ args[0], args[0] },
    );
    try w.interface.flush();
    return error.BadUsage;
}

// ─── --stdio: the trunk endpoint ────────────────────────────────────────

const Channel = struct {
    id: u32,
    sock: std.Io.net.Stream,
};

const Agent = struct {
    io: std.Io,
    alloc: std.mem.Allocator,
    trunk: *mux.Trunk,
    listener: *std.Io.net.Server,

    mutex: std.Io.Mutex = .init,
    channels: std.AutoHashMapUnmanaged(u32, *Channel) = .empty,
    next_id: std.atomic.Value(u32) = .init(1),

    fn add(self: *Agent, sock: std.Io.net.Stream) !*Channel {
        const ch = try self.alloc.create(Channel);
        ch.* = .{ .id = self.next_id.fetchAdd(1, .monotonic), .sock = sock };
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try self.channels.put(self.alloc, ch.id, ch);
        return ch;
    }

    /// Force the socket for `id` to EOF (host said `close`, or shutdown).
    /// The channel's own `sockReader` does the map removal + free.
    fn shutdownChannel(self: *Agent, id: u32) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.channels.get(id)) |ch| ch.sock.shutdown(self.io, .both) catch {};
    }

    fn remove(self: *Agent, id: u32) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.channels.fetchRemove(id)) |kv| {
            kv.value.sock.close(self.io);
            self.alloc.destroy(kv.value);
        }
    }
};

fn runStdio(init: std.process.Init) !void {
    const io = init.io;
    const alloc = init.gpa;
    const arena = init.arena.allocator();

    const sock_path = try socketPath(arena, init.environ_map);
    std.Io.Dir.cwd().deleteFile(io, sock_path) catch {};
    const addr = try std.Io.net.UnixAddress.init(sock_path);
    var listener = try addr.listen(io, .{});
    defer listener.deinit(io);

    // The remote shell (and everything it spawns) talks to us, not to a
    // real terminal: its own stdio is nulled so nothing it prints can
    // corrupt the trunk, and it finds us through the environment the same
    // way a local `gw-shell` finds the host.
    var shell_env = try init.environ_map.clone(arena);
    try shell_env.put("GLYPHWIRE_SOCK", sock_path);
    try shell_env.put("GLYPHWIRE_CTX", glyphwire.default_context_id);

    // Prefer a `gw-shell` sitting next to this binary; fall back to PATH
    // (a non-login `ssh -T` session may have a minimal PATH that misses
    // the install prefix).
    const shell_cmd: []const u8 = blk: {
        const dir = std.process.executableDirPathAlloc(io, arena) catch break :blk "gw-shell";
        break :blk std.fs.path.join(arena, &.{ dir, "gw-shell" }) catch "gw-shell";
    };

    var shell_child = std.process.spawn(io, .{
        .argv = &.{shell_cmd},
        .environ_map = &shell_env,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .inherit,
    }) catch |err| {
        std.log.err("gw-agent: could not spawn gw-shell: {t}", .{err});
        return err;
    };

    var trunk_read_buf: [64 * 1024]u8 = undefined;
    var trunk_write_buf: [64 * 1024]u8 = undefined;
    var tr = std.Io.File.stdin().reader(io, &trunk_read_buf);
    var tw = std.Io.File.stdout().writer(io, &trunk_write_buf);
    var trunk: mux.Trunk = .{ .io = io, .reader = &tr.interface, .writer = &tw.interface };

    var agent: Agent = .{ .io = io, .alloc = alloc, .trunk = &trunk, .listener = &listener };

    try trunk.send(.hello, 0, "");

    var accept_thread = try std.Thread.spawn(.{}, acceptLoop, .{&agent});
    accept_thread.detach();

    var reaper_thread = try std.Thread.spawn(.{}, shellReaper, .{ io, &shell_child });
    reaper_thread.detach();

    // Trunk read loop -- the one consumer of the trunk reader.
    var payload: [mux.max_payload]u8 = undefined;
    while (true) {
        const hdr = trunk.recvHeader() catch break;
        if (hdr.len != 0) tr.interface.readSliceAll(payload[0..hdr.len]) catch break;
        switch (hdr.kind) {
            .data => {
                agent.mutex.lockUncancelable(io);
                const maybe = agent.channels.get(hdr.channel);
                agent.mutex.unlock(io);
                if (maybe) |ch| writeAllStream(io, ch.sock, payload[0..hdr.len]) catch {
                    agent.shutdownChannel(hdr.channel);
                };
            },
            .close => agent.shutdownChannel(hdr.channel),
            .hello, .open => {}, // host->agent only ever sends data/close
        }
    }

    // Trunk gone: nothing more can reach the shell. Let the OS reclaim the
    // socket, channel threads, and the shell (same shortcut the host takes
    // on window close).
    std.process.exit(0);
}

fn acceptLoop(agent: *Agent) void {
    while (true) {
        const sock = agent.listener.accept(agent.io) catch return;
        const ch = agent.add(sock) catch {
            sock.close(agent.io);
            continue;
        };
        agent.trunk.send(.open, ch.id, "") catch return;
        var t = std.Thread.spawn(.{}, sockReader, .{ agent, ch }) catch {
            agent.remove(ch.id);
            continue;
        };
        t.detach();
    }
}

fn sockReader(agent: *Agent, ch: *Channel) void {
    const io = agent.io;
    var buf: [mux.max_payload]u8 = undefined;
    while (true) {
        var data: [1][]u8 = .{&buf};
        const n = ch.sock.read(io, &data) catch break;
        if (n == 0) break;
        agent.trunk.sendData(ch.id, buf[0..n]) catch break;
    }
    agent.trunk.send(.close, ch.id, "") catch {};
    agent.remove(ch.id);
}

fn shellReaper(io: std.Io, child: *std.process.Child) void {
    _ = child.wait(io) catch {};
    // Shell exited (its `exit` builtin, a crash, a kill): the session is
    // over. Dropping stdout closes the trunk so the host's demux sees EOF.
    std.process.exit(0);
}

fn writeAllStream(io: std.Io, sock: std.Io.net.Stream, bytes: []const u8) !void {
    var buf: [4096]u8 = undefined;
    var w = sock.writer(io, &buf);
    try w.interface.writeAll(bytes);
    try w.interface.flush();
}

fn socketPath(alloc: std.mem.Allocator, environ_map: *const std.process.Environ.Map) ![]const u8 {
    const dir = environ_map.get("XDG_RUNTIME_DIR") orelse "/tmp";
    const pid = std.os.linux.getpid();
    return std.fmt.allocPrint(alloc, "{s}/glyphwire-agent-{d}.sock", .{ dir, pid });
}

// ─── --askpass: the SSH_ASKPASS helper ─────────────────────────────────

/// Relays one `ssh` prompt to the host over `GLYPHWIRE_ASKPASS_SOCK` and
/// prints the answer on stdout for `ssh` to read. Exits non-zero (so
/// `ssh` falls back to its own tty handling, or fails) when there is no
/// socket to talk to.
fn runAskpass(init: std.process.Init, prompt: []const u8) !void {
    const io = init.io;
    const sock_path = init.environ_map.get("GLYPHWIRE_ASKPASS_SOCK") orelse {
        return error.NoAskpassSocket;
    };

    const addr = try std.Io.net.UnixAddress.init(sock_path);
    const sock = try addr.connect(io);
    defer sock.close(io);

    {
        var buf: [512]u8 = undefined;
        var w = sock.writer(io, &buf);
        try w.interface.writeAll(prompt);
        try w.interface.flush();
    }
    try sock.shutdown(io, .send);

    var reply_buf: [1024]u8 = undefined;
    var total: usize = 0;
    while (total < reply_buf.len) {
        var data: [1][]u8 = .{reply_buf[total..]};
        const n = sock.read(io, &data) catch break;
        if (n == 0) break;
        total += n;
    }

    var out_buf: [1024]u8 = undefined;
    var w = std.Io.File.stdout().writer(io, &out_buf);
    try w.interface.writeAll(reply_buf[0..total]);
    if (total == 0 or reply_buf[total - 1] != '\n') try w.interface.writeAll("\n");
    try w.interface.flush();
}
