//! `glyphwire --ssh <dest>`: run the host locally, the shell (and the
//! `gw-ls` / `gw-view` / `zoe` it launches) on a remote box, reached over
//! one `ssh` connection.
//!
//! The host keeps owning the `Context`, the renderer, and the `Server`.
//! `ssh -T <dest> -- gw-agent --stdio` gives us a byte-stream trunk to a
//! `gw-agent` on the far side (see `src/mux.zig`); `gw-agent` opens a
//! normal `GLYPHWIRE_SOCK` there and every remote client dials it. This
//! module's demux loop turns each mux channel back into a
//! `Server.servePreconnected` connection, so a remote `gw-shell` drives
//! the local grid exactly as a local one would.
//!
//! `ssh` auth prompts (host key, password, passphrase) are surfaced in
//! the window: the host points `SSH_ASKPASS` at `gw-agent` and hands it a
//! Unix socket (`GLYPHWIRE_ASKPASS_SOCK`); each prompt relayed back is
//! drawn onto the grid by a small in-process client that connects to the
//! host's own socket, and the line the user types is sent back.

const std = @import("std");
const glyphwire = @import("glyphwire");
const mux = glyphwire.mux;

/// Spawns `func` on a detached thread, swallowing a spawn failure (a
/// missing helper thread only degrades logging or reconnection tidiness,
/// never correctness of the live session).
fn spawnDetached(comptime func: anytype, args: anytype) void {
    if (std.Thread.spawn(.{}, func, args)) |t| {
        t.detach();
    } else |err| {
        std.log.warn("glyphwire: could not spawn remote helper thread: {t}", .{err});
    }
}

pub const Options = struct {
    /// The `ssh` destination, e.g. `user@host` or a `~/.ssh/config` alias.
    dest: []const u8,
    /// The command run on the far side. `gw-agent` by default; overridable
    /// with `--remote-command` for a box that installs it elsewhere.
    remote_command: []const u8 = "gw-agent",
    /// Extra arguments inserted before `dest` in the `ssh` invocation
    /// (everything after `--` on the `glyphwire --ssh` command line).
    ssh_args: []const []const u8 = &.{},
    /// Absolute path to this build's `gw-agent`, used as the `SSH_ASKPASS`
    /// helper (its `--askpass` behaviour).
    agent_path: []const u8,
    /// The host's own `GLYPHWIRE_SOCK` and `GLYPHWIRE_CTX`, so the
    /// auth-prompt client can draw onto the grid like any other client.
    host_sock: []const u8,
    ctx_id: []const u8,
};

pub const Remote = struct {
    io: std.Io,
    alloc: std.mem.Allocator,
    opts: Options,
    server: *glyphwire.server.Server,
    /// Shared with `host/main.zig`'s quit flag: set when `ssh` exits, so
    /// the window loop ends the same way a local `gw-shell` exiting ends it.
    session_exited: *std.atomic.Value(bool),

    ssh: std.process.Child = undefined,

    trunk_read_buf: [64 * 1024]u8 = undefined,
    trunk_write_buf: [64 * 1024]u8 = undefined,
    trunk_reader: std.Io.File.Reader = undefined,
    trunk_writer: std.Io.File.Writer = undefined,
    trunk: mux.Trunk = undefined,

    channels_mutex: std.Io.Mutex = .init,
    channels: std.AutoHashMapUnmanaged(u32, *mux.Channel) = .empty,

    askpass_sock_path: []const u8 = "",
    /// Last few `ssh` stderr lines, kept for the failure message.
    stderr_tail: [1024]u8 = undefined,
    stderr_tail_len: usize = 0,
    stderr_mutex: std.Io.Mutex = .init,

    /// Spawns the askpass responder, then `ssh`, then blocks until the
    /// agent's `hello` frame arrives (auth prompts happen in between and
    /// are handled on the responder thread). On success the demux is
    /// running and remote clients can connect; on failure `ssh` has exited
    /// and the returned error carries the stderr tail in the log.
    pub fn start(
        alloc: std.mem.Allocator,
        io: std.Io,
        server: *glyphwire.server.Server,
        session_exited: *std.atomic.Value(bool),
        environ_map: *const std.process.Environ.Map,
        opts: Options,
    ) !*Remote {
        const self = try alloc.create(Remote);
        errdefer alloc.destroy(self);
        self.* = .{
            .io = io,
            .alloc = alloc,
            .opts = opts,
            .server = server,
            .session_exited = session_exited,
        };

        try self.startAskpassResponder(environ_map);

        // ssh -T -o BatchMode=no <ssh_args...> <dest> -- <remote_command> --stdio
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(alloc);
        try argv.appendSlice(alloc, &.{ "ssh", "-T", "-o", "BatchMode=no" });
        try argv.appendSlice(alloc, opts.ssh_args);
        try argv.append(alloc, opts.dest);
        try argv.appendSlice(alloc, &.{ "--", opts.remote_command, "--stdio" });

        var ssh_env = try environ_map.clone(alloc);
        defer ssh_env.deinit();
        try ssh_env.put("SSH_ASKPASS", opts.agent_path);
        try ssh_env.put("SSH_ASKPASS_REQUIRE", "force");
        try ssh_env.put("GLYPHWIRE_ASKPASS_SOCK", self.askpass_sock_path);

        self.ssh = std.process.spawn(io, .{
            .argv = argv.items,
            .environ_map = &ssh_env,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .pipe,
        }) catch |err| {
            std.log.err("glyphwire: could not launch ssh: {t}", .{err});
            return err;
        };

        self.trunk_reader = self.ssh.stdout.?.readerStreaming(io, &self.trunk_read_buf);
        self.trunk_writer = self.ssh.stdin.?.writerStreaming(io, &self.trunk_write_buf);
        self.trunk = .{ .io = io, .reader = &self.trunk_reader.interface, .writer = &self.trunk_writer.interface };

        spawnDetached(stderrPump, .{self});
        spawnDetached(reaper, .{self});

        // Block here through the whole auth handshake; the responder
        // thread drives the prompt UI in parallel. `hello` lands once the
        // agent is actually up.
        const hdr = self.trunk.recvHeader() catch |err| {
            self.session_exited.store(true, .monotonic);
            self.logStderrTail();
            std.log.err("glyphwire: remote session did not start ({t})", .{err});
            return error.RemoteStartFailed;
        };
        if (hdr.kind != .hello) {
            self.session_exited.store(true, .monotonic);
            std.log.err("glyphwire: unexpected first trunk frame '{s}'", .{@tagName(hdr.kind)});
            return error.RemoteStartFailed;
        }

        var t = try std.Thread.spawn(.{}, demuxLoop, .{self});
        t.detach();
        return self;
    }

    fn startAskpassResponder(self: *Remote, environ_map: *const std.process.Environ.Map) !void {
        const dir = environ_map.get("XDG_RUNTIME_DIR") orelse "/tmp";
        const pid = std.os.linux.getpid();
        self.askpass_sock_path = try std.fmt.allocPrint(self.alloc, "{s}/glyphwire-askpass-{d}.sock", .{ dir, pid });
        std.Io.Dir.cwd().deleteFile(self.io, self.askpass_sock_path) catch {};
        const addr = try std.Io.net.UnixAddress.init(self.askpass_sock_path);
        const listener = try addr.listen(self.io, .{});
        var t = try std.Thread.spawn(.{}, askpassResponder, .{ self, listener });
        t.detach();
    }

    fn removeChannel(self: *Remote, id: u32) ?*mux.Channel {
        self.channels_mutex.lockUncancelable(self.io);
        defer self.channels_mutex.unlock(self.io);
        if (self.channels.fetchRemove(id)) |kv| return kv.value;
        return null;
    }

    fn logStderrTail(self: *Remote) void {
        self.stderr_mutex.lockUncancelable(self.io);
        defer self.stderr_mutex.unlock(self.io);
        if (self.stderr_tail_len != 0) {
            std.log.err("glyphwire: ssh: {s}", .{std.mem.trim(u8, self.stderr_tail[0..self.stderr_tail_len], " \r\n")});
        }
    }
};

// ─── trunk demux ───────────────────────────────────────────────────────

fn demuxLoop(self: *Remote) void {
    const io = self.io;
    var payload: [mux.max_payload]u8 = undefined;
    while (true) {
        const hdr = self.trunk.recvHeader() catch break;
        if (hdr.len != 0) self.trunk_reader.interface.readSliceAll(payload[0..hdr.len]) catch break;
        switch (hdr.kind) {
            .open => {
                const ch = self.alloc.create(mux.Channel) catch break;
                ch.* = .{ .id = hdr.channel, .trunk = &self.trunk, .io = io, .alloc = self.alloc };
                self.channels_mutex.lockUncancelable(io);
                self.channels.put(self.alloc, hdr.channel, ch) catch {
                    self.channels_mutex.unlock(io);
                    self.alloc.destroy(ch);
                    continue;
                };
                self.channels_mutex.unlock(io);
                var t = std.Thread.spawn(.{}, serveChannel, .{ self, ch }) catch {
                    _ = self.removeChannel(hdr.channel);
                    ch.deinit();
                    self.alloc.destroy(ch);
                    continue;
                };
                t.detach();
            },
            .data => {
                self.channels_mutex.lockUncancelable(io);
                defer self.channels_mutex.unlock(io);
                if (self.channels.get(hdr.channel)) |ch| ch.feed(payload[0..hdr.len]) catch {};
            },
            .close => {
                if (self.removeChannel(hdr.channel)) |ch| ch.closePeer();
            },
            .hello => {}, // already consumed one in `start`; ignore extras
        }
    }

    // Trunk gone: fail every live connection so its `serveConnection`
    // returns, then end the session.
    self.channels_mutex.lockUncancelable(self.io);
    var it = self.channels.valueIterator();
    while (it.next()) |ch| ch.*.closePeer();
    self.channels_mutex.unlock(self.io);
    self.session_exited.store(true, .monotonic);
}

fn serveChannel(self: *Remote, ch: *mux.Channel) void {
    const stream = glyphwire.ConnStream{ .channel = ch };
    self.server.servePreconnected(self.alloc, stream) catch |err| {
        std.log.err("glyphwire: remote connection error: {t}", .{err});
    };
    _ = self.removeChannel(ch.id);
    ch.deinit();
    self.alloc.destroy(ch);
}

// ─── ssh plumbing ──────────────────────────────────────────────────────

fn reaper(self: *Remote) void {
    _ = self.ssh.wait(self.io) catch {};
    self.session_exited.store(true, .monotonic);
}

fn stderrPump(self: *Remote) void {
    const io = self.io;
    const err_file = self.ssh.stderr orelse return;
    var rbuf: [4096]u8 = undefined;
    var r = err_file.readerStreaming(io, &rbuf);
    while (true) {
        const line = r.interface.takeDelimiterInclusive('\n') catch break;
        const trimmed = std.mem.trim(u8, line, " \r\n");
        if (trimmed.len == 0) continue;
        std.log.info("glyphwire: ssh: {s}", .{trimmed});

        self.stderr_mutex.lockUncancelable(io);
        const keep = @min(trimmed.len, self.stderr_tail.len);
        @memcpy(self.stderr_tail[0..keep], trimmed[trimmed.len - keep ..]);
        self.stderr_tail_len = keep;
        self.stderr_mutex.unlock(io);
    }
}

// ─── askpass: draw the prompt, read the answer ─────────────────────────

fn askpassResponder(self: *Remote, listener_in: std.Io.net.Server) void {
    const io = self.io;
    var listener = listener_in;
    defer listener.deinit(io);

    while (true) {
        const conn = listener.accept(io) catch return;
        defer conn.close(io);

        var prompt_buf: [1024]u8 = undefined;
        var prompt_len: usize = 0;
        while (prompt_len < prompt_buf.len) {
            var data: [1][]u8 = .{prompt_buf[prompt_len..]};
            const n = conn.read(io, &data) catch break;
            if (n == 0) break;
            prompt_len += n;
        }
        const prompt = prompt_buf[0..prompt_len];

        // A fresh client per prompt: it disconnects right after, so it
        // never sits subscribed to key/text queueing broadcasts for the
        // rest of the session.
        var ui = AuthClient.connect(self.io, self.alloc, self.opts.host_sock) catch |err| {
            std.log.warn("glyphwire: askpass UI unavailable ({t}); ssh prompt cannot be answered", .{err});
            _ = conn.shutdown(io, .send) catch {};
            continue;
        };
        defer ui.deinit();

        var answer_buf: [512]u8 = undefined;
        const answer = ui.run(prompt, &answer_buf) catch |err| {
            std.log.warn("glyphwire: askpass prompt aborted ({t})", .{err});
            _ = conn.shutdown(io, .send) catch {};
            continue;
        };

        var out_buf: [512]u8 = undefined;
        var w = conn.writer(io, &out_buf);
        w.interface.writeAll(answer) catch {};
        w.interface.flush() catch {};
        _ = conn.shutdown(io, .send) catch {};
    }
}

/// A minimal glyphwire client that draws one `ssh` prompt onto the host's
/// own grid and returns the line the user types. Reused across the two or
/// three prompts a single connection attempt produces.
const AuthClient = struct {
    io: std.Io,
    alloc: std.mem.Allocator,
    client: glyphwire.Client,
    listener: *glyphwire.InputListener,

    fn connect(io: std.Io, alloc: std.mem.Allocator, sock: []const u8) !AuthClient {
        var client = try glyphwire.Client.connect(io, alloc, sock);
        errdefer client.deinit();
        const listener = try glyphwire.InputListener.connect(io, alloc, sock, &.{ "text", "key" });
        return .{ .io = io, .alloc = alloc, .client = client, .listener = listener };
    }

    fn deinit(self: *AuthClient) void {
        self.clearGrid();
        self.listener.deinit();
        self.client.deinit();
    }

    fn clearGrid(self: *AuthClient) void {
        self.client.clear(0, 0, null, null) catch {};
    }

    fn run(self: *AuthClient, prompt: []const u8, out: []u8) ![]const u8 {
        const masked = containsAnyCase(prompt, "password") or containsAnyCase(prompt, "passphrase");

        self.clearGrid();
        self.client.setCursor(1, 0) catch {};
        self.client.writeText(trimForGrid(prompt), null, null) catch {};

        var line: std.ArrayList(u8) = .empty;
        defer line.deinit(self.alloc);

        while (true) {
            const ev = (try self.listener.waitInputEvent(.{ .duration = .{ .raw = .fromMilliseconds(60_000), .clock = .awake } })) orelse continue;
            defer ev.deinit(self.alloc);
            switch (ev) {
                .text => |t| {
                    for (t.text) |b| {
                        if (b >= 0x20 and b != 0x7f) try line.append(self.alloc, b);
                    }
                    try self.redrawInput(line.items, masked);
                },
                .key => |k| {
                    if (!k.pressed) continue;
                    if (eqIgnoreCase(k.key, "enter") or eqIgnoreCase(k.key, "return") or eqIgnoreCase(k.key, "kp_enter")) {
                        break;
                    } else if (eqIgnoreCase(k.key, "backspace")) {
                        if (line.items.len != 0) line.items.len -= 1;
                        try self.redrawInput(line.items, masked);
                    } else if (eqIgnoreCase(k.key, "escape")) {
                        return error.PromptCanceled;
                    }
                },
                .shutdown => return error.PromptCanceled,
                else => {},
            }
        }

        const n = @min(out.len, line.items.len);
        @memcpy(out[0..n], line.items[0..n]);
        self.clearGrid();
        return out[0..n];
    }

    fn redrawInput(self: *AuthClient, text: []const u8, masked: bool) !void {
        self.client.clear(3, 0, 1, null) catch {};
        self.client.setCursor(3, 0) catch {};
        if (masked) {
            var buf: [128]u8 = undefined;
            const n = @min(buf.len, text.len);
            @memset(buf[0..n], '*');
            self.client.writeText(buf[0..n], null, null) catch {};
        } else {
            self.client.writeText(trimForGrid(text), null, null) catch {};
        }
    }
};

fn trimForGrid(s: []const u8) []const u8 {
    return if (s.len > 200) s[0..200] else s;
}

fn eqIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (std.ascii.toLower(x) != std.ascii.toLower(y)) return false;
    }
    return true;
}

fn containsAnyCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or haystack.len < needle.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (eqIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}
