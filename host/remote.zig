//! Remote sessions: run the host locally, the shell (and the `gw-ls` /
//! `gw-view` / `zoe` it launches) on a remote box, reached over one `ssh`
//! connection.
//!
//! The host keeps owning the `Context`, the renderer, and the `Server`.
//! `ssh -T <dest> -- gw-agent --stdio` gives us a byte-stream trunk to a
//! `gw-agent` on the far side (see `src/mux.zig`); `gw-agent` opens a
//! normal `GLYPHWIRE_SOCK` there and every remote client dials it. This
//! module's demux loop turns each mux channel back into a
//! `Server.servePreconnected` connection, so a remote `gw-shell` drives
//! the local grid exactly as a local one would.
//!
//! There are two ways in, and they differ only in what a session is seated
//! in and what its ending means:
//!
//!   - `glyphwire --ssh <dest>` replaces the window's own shell. The
//!     session owns the root pane, and `ssh` exiting ends the window --
//!     the same quit flag a local `gw-shell` exiting sets.
//!   - `gwssh <dest>`, typed into a shell in any pane, seats a session in
//!     *that* pane (`start_remote` -- see `dispatch.RemoteStarter`). The
//!     shell that ran it is not replaced: it sits behind the session the
//!     way it sits behind `ssh` in an ordinary terminal, and gets the pane
//!     back when the `remote_exit` notification says the session ended.
//!
//! `Remotes` is the registry the second kind needs: sessions come and go,
//! several can be live at once in different panes, and `stop_remote` /
//! `destroy_pane` have to find one by id or by pane.
//!
//! The pane and context a session is seated in are passed on to `gw-agent`,
//! which puts them in the remote shell's environment (`GLYPHWIRE_PANE` /
//! `GLYPHWIRE_CTX`) -- so a remote client binds itself to the right
//! rectangle through exactly the handshake a locally spawned one uses, and
//! `gw-agent` still never parses a byte of the protocol.
//!
//! `ssh` auth prompts (host key, password, passphrase) are surfaced in
//! the window: the host points `SSH_ASKPASS` at `gw-agent` and hands it a
//! Unix socket (`GLYPHWIRE_ASKPASS_SOCK`); each prompt relayed back is
//! drawn onto the grid by a small in-process client that connects to the
//! host's own socket, attaches to the session's pane, and sends back the
//! line the user types.

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
    /// The host's own `GLYPHWIRE_SOCK`, so the auth-prompt client can draw
    /// onto the grid like any other client.
    host_sock: []const u8,
    /// The pane the remote clients are seated in and the context they draw
    /// on. Handed to `gw-agent`, which puts them in the remote shell's
    /// environment so it binds itself the way a `spawn_in_pane` child does.
    pane: glyphwire.PaneHandle = glyphwire.root_pane_handle,
    ctx: glyphwire.ContextHandle,
};

/// Everything a `Remote` needs that outlives the request that asked for
/// it: the strings from a `start_remote` body are freed the moment the
/// dispatcher returns, but the session runs on its own thread for as long
/// as the user stays connected. One arena per session, freed whole when
/// the session ends.
const OwnedOptions = struct {
    arena: std.heap.ArenaAllocator,
    opts: Options,

    fn init(alloc: std.mem.Allocator, src: Options) !OwnedOptions {
        var arena = std.heap.ArenaAllocator.init(alloc);
        errdefer arena.deinit();
        const a = arena.allocator();

        const args = try a.alloc([]const u8, src.ssh_args.len);
        for (src.ssh_args, args) |in, *out| out.* = try a.dupe(u8, in);

        return .{
            .arena = arena,
            .opts = .{
                .dest = try a.dupe(u8, src.dest),
                .remote_command = try a.dupe(u8, src.remote_command),
                .ssh_args = args,
                .agent_path = try a.dupe(u8, src.agent_path),
                .host_sock = try a.dupe(u8, src.host_sock),
                .pane = src.pane,
                .ctx = src.ctx,
            },
        };
    }

    fn deinit(self: *OwnedOptions) void {
        self.arena.deinit();
    }
};

pub const Remote = struct {
    io: std.Io,
    alloc: std.mem.Allocator,
    owned: OwnedOptions,
    opts: Options,
    server: *glyphwire.server.Server,
    /// `glyphwire --ssh`'s quit flag: set when `ssh` exits, so the window
    /// loop ends the same way a local `gw-shell` exiting ends it. Null for
    /// a `gwssh` session, which ends only itself -- there the registry
    /// reports `remote_exit` instead and the window carries on.
    session_exited: ?*std.atomic.Value(bool),
    /// The registry this session is enrolled in, and its id there. Null for
    /// the `--ssh` window session, which nothing can name.
    owner: ?*Remotes = null,
    id: u64 = 0,

    ssh: std.process.Child = undefined,
    /// `ssh`'s pid, copied out at spawn so `stop` can signal it without
    /// touching `ssh` (which the reaper thread owns). Zero before spawn.
    ssh_pid: std.posix.pid_t = 0,
    /// Set by the reaper the moment `wait` returns, so `stop` stops
    /// signalling a pid that is no longer ours.
    ssh_reaped: std.atomic.Value(bool) = .init(false),
    /// `ssh`'s wait status, as reported in `remote_exit`. Stays 1 -- "it
    /// didn't work" -- until the reaper decodes the real one, which is the
    /// right answer for a session that never got as far as spawning.
    exit_status: std.atomic.Value(i64) = .init(1),
    /// The host's environment, borrowed for the process lifetime; `ssh`'s
    /// is cloned from it at spawn.
    environ: *const std.process.Environ.Map,
    /// Joined by `finish` so `exit_status` is settled before it is
    /// reported. Null when `ssh` never spawned, or the spawn failed.
    reaper_thread: ?std.Thread = null,
    /// Set once the agent's `hello` lands. Reported as `remote_exit`'s
    /// `started`, which is the only way the shell can tell a connection
    /// that failed from a remote shell that exited with the same number.
    came_up: std.atomic.Value(bool) = .init(false),

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

    /// Creates a session and puts the whole of it -- auth handshake,
    /// demux, teardown -- on one detached thread. Returns as soon as the
    /// thread is running; it does *not* wait for `ssh` to come up.
    ///
    /// That is the load-bearing part. Bringing a session up takes as long
    /// as a human takes to type a passphrase, and the prompt is drawn by a
    /// client of this very server; `start_remote` is dispatched under the
    /// server's context mutex, so blocking there would wedge the window
    /// the prompt has to appear in. A session that fails to start reports
    /// itself the same way one that ends does -- through `remote_exit`,
    /// with a non-zero status.
    pub fn create(
        alloc: std.mem.Allocator,
        io: std.Io,
        server: *glyphwire.server.Server,
        session_exited: ?*std.atomic.Value(bool),
        environ_map: *const std.process.Environ.Map,
        opts: Options,
        owner: ?*Remotes,
        id: u64,
    ) !*Remote {
        var owned = try OwnedOptions.init(alloc, opts);
        errdefer owned.deinit();

        const self = try alloc.create(Remote);
        errdefer alloc.destroy(self);
        self.* = .{
            .io = io,
            .alloc = alloc,
            .owned = owned,
            .opts = owned.opts,
            .server = server,
            .session_exited = session_exited,
            .environ = environ_map,
            .owner = owner,
            .id = id,
        };
        return self;
    }

    /// Puts the session on its thread. Separate from `create` so the
    /// registry can enrol it *first*: the thread can reach `finish` (and
    /// so free the session) before this call returns, and a registry that
    /// enrolled it afterwards would be filing a dangling pointer.
    pub fn launch(self: *Remote) !void {
        var t = try std.Thread.spawn(.{}, run, .{self});
        t.detach();
    }

    /// The session, start to finish, on its own thread.
    fn run(self: *Remote) void {
        self.bringUp() catch {
            self.finish();
            return;
        };
        demuxLoop(self);
        self.finish();
    }

    /// Spawns the askpass responder, then `ssh`, then blocks until the
    /// agent's `hello` frame arrives (auth prompts happen in between and
    /// are handled on the responder thread). On failure `ssh` has exited
    /// and the stderr tail is in the log.
    fn bringUp(self: *Remote) !void {
        const alloc = self.alloc;
        const io = self.io;
        const opts = self.opts;

        try self.startAskpassResponder(self.environ);

        // ssh -T -o BatchMode=no <ssh_args...> <dest> -- <remote_command> --stdio
        //     --pane N --ctx N --name <dest>
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(alloc);
        try argv.appendSlice(alloc, &.{ "ssh", "-T", "-o", "BatchMode=no" });
        try argv.appendSlice(alloc, opts.ssh_args);
        try argv.append(alloc, opts.dest);
        try argv.appendSlice(alloc, &.{ "--", opts.remote_command, "--stdio" });

        // The pane and context the remote shell must bind itself to, and
        // the name it shows as `{remote_dest}` in its prompt. Plain
        // arguments rather than anything cleverer because `gw-agent` only
        // has to copy them into the shell's environment -- it is the same
        // handshake `spawn_in_pane` uses, just carried over the wire.
        var pane_buf: [32]u8 = undefined;
        var ctx_buf: [32]u8 = undefined;
        try argv.appendSlice(alloc, &.{ "--pane", try std.fmt.bufPrint(&pane_buf, "{d}", .{opts.pane}) });
        try argv.appendSlice(alloc, &.{ "--ctx", try std.fmt.bufPrint(&ctx_buf, "{d}", .{opts.ctx}) });
        try argv.appendSlice(alloc, &.{ "--name", opts.dest });

        var ssh_env = try self.environ.clone(alloc);
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
        self.ssh_pid = self.ssh.id orelse 0;

        self.trunk_reader = self.ssh.stdout.?.readerStreaming(io, &self.trunk_read_buf);
        self.trunk_writer = self.ssh.stdin.?.writerStreaming(io, &self.trunk_write_buf);
        self.trunk = .{ .io = io, .reader = &self.trunk_reader.interface, .writer = &self.trunk_writer.interface };

        spawnDetached(stderrPump, .{self});
        // The reaper is joined, not detached: it is the only thing that
        // knows what `ssh` exited with, and `finish` reports that status.
        // Detached, `finish` raced it and read the "didn't work" default
        // even when the remote shell had exited cleanly.
        self.reaper_thread = std.Thread.spawn(.{}, reaper, .{self}) catch |err| blk: {
            std.log.warn("glyphwire: could not spawn remote reaper thread: {t}", .{err});
            break :blk null;
        };

        // Block here through the whole auth handshake; the responder
        // thread drives the prompt UI in parallel. `hello` lands once the
        // agent is actually up.
        const hdr = self.trunk.recvHeader() catch |err| {
            self.logStderrTail();
            std.log.err("glyphwire: remote session did not start ({t})", .{err});
            return error.RemoteStartFailed;
        };
        if (hdr.kind != .hello) {
            std.log.err("glyphwire: unexpected first trunk frame '{s}'", .{@tagName(hdr.kind)});
            return error.RemoteStartFailed;
        }
        self.came_up.store(true, .monotonic);
    }

    /// Asks `ssh` to go away. Safe to call more than once and safe to race
    /// with the reaper: once the reaper has seen `wait` return, the pid is
    /// no longer ours to signal and this does nothing.
    pub fn stop(self: *Remote) void {
        if (self.ssh_reaped.load(.monotonic)) return;
        if (self.ssh_pid == 0) return;
        std.posix.kill(self.ssh_pid, .TERM) catch {};
    }

    /// The session is over, however it ended: fail every live connection
    /// so its `serveConnection` returns, make sure `ssh` is not left
    /// behind, unlink the askpass socket, then tell whoever is waiting.
    ///
    /// The `Remote` itself is *not* freed, here or anywhere. Its askpass
    /// responder is a detached thread parked in `accept` (and possibly
    /// deeper, in an auth prompt a human has not answered), and it reads
    /// `self`; there is no point at which this thread can know that one is
    /// done with it. Waking it reliably means shutting the listening
    /// socket from under a blocked `accept`, and even then a thread inside
    /// a live prompt would have to be waited out. A session is a rare,
    /// user-initiated thing -- a handful over a window's life -- so
    /// retiring one costs a bounded, small leak, and that is the honest
    /// trade against a use-after-free in the teardown path.
    fn finish(self: *Remote) void {
        self.channels_mutex.lockUncancelable(self.io);
        var it = self.channels.valueIterator();
        while (it.next()) |ch| ch.*.closePeer();
        self.channels_mutex.unlock(self.io);

        self.stop();
        // `stop` has asked `ssh` to go, so this is bounded: the reaper is
        // sitting in `wait` and returns as soon as it does. Joining is
        // what makes the reported status the real one -- including the
        // 127 `ssh` passes through when the far side has no `gw-agent`.
        if (self.reaper_thread) |t| {
            t.join();
            self.reaper_thread = null;
        }
        if (self.askpass_sock_path.len != 0) {
            std.Io.Dir.cwd().deleteFile(self.io, self.askpass_sock_path) catch {};
        }
        if (self.session_exited) |flag| flag.store(true, .monotonic);
        if (self.owner) |owner| owner.finished(self);
    }

    /// Frees a session that was never launched -- the only point at which
    /// freeing one is safe, because no thread has seen it yet. See
    /// `finish` for why a session that *ran* is never freed.
    fn destroy(self: *Remote) void {
        const alloc = self.alloc;
        self.channels.deinit(alloc);
        if (self.askpass_sock_path.len != 0) alloc.free(self.askpass_sock_path);
        self.owned.deinit();
        alloc.destroy(self);
    }

    /// One askpass socket per *session*, not per process: several remote
    /// panes can be coming up at once in one window, and a path keyed on
    /// the pid alone would have each new session unlink the live socket
    /// the previous one's `ssh` is about to connect to.
    fn startAskpassResponder(self: *Remote, environ_map: *const std.process.Environ.Map) !void {
        const dir = environ_map.get("XDG_RUNTIME_DIR") orelse "/tmp";
        const pid = std.os.linux.getpid();
        self.askpass_sock_path = try std.fmt.allocPrint(self.alloc, "{s}/glyphwire-askpass-{d}-{d}.sock", .{ dir, pid, self.id });
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

// ─── the session registry (`start_remote`) ─────────────────────────────

/// Every live `gwssh` session, keyed by the id `start_remote` handed back.
/// This is the `dispatch.RemoteStarter` glyphwire-host registers; see that
/// type for why bringing a session up is injected rather than built into
/// `src/`.
pub const Remotes = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    server: *glyphwire.server.Server,
    /// The host's own socket and environment, and this build's `gw-agent`
    /// -- the three things every session needs and none of them knows.
    /// All borrowed for the process lifetime.
    host_sock: []const u8,
    agent_path: []const u8,
    environ: *const std.process.Environ.Map,

    mutex: std.Io.Mutex = .init,
    sessions: std.AutoHashMapUnmanaged(u64, *Remote) = .empty,
    next_id: u64 = 1,

    pub fn init(
        alloc: std.mem.Allocator,
        io: std.Io,
        server: *glyphwire.server.Server,
        host_sock: []const u8,
        agent_path: []const u8,
        environ: *const std.process.Environ.Map,
    ) Remotes {
        return .{
            .alloc = alloc,
            .io = io,
            .server = server,
            .host_sock = host_sock,
            .agent_path = agent_path,
            .environ = environ,
        };
    }

    /// Asks every live session to end. The table is deliberately *not*
    /// freed: each session's thread is detached and calls `finished` --
    /// which locks this mutex and edits this table -- so freeing it here
    /// would pull the map out from under a thread already blocked on the
    /// lock. The process is exiting; the OS reclaims it, the same shortcut
    /// the host takes for its other detached threads on window close.
    pub fn deinit(self: *Remotes) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var it = self.sessions.valueIterator();
        while (it.next()) |r| r.*.stop();
    }

    pub fn starter(self: *Remotes) glyphwire.RemoteStarter {
        return .{
            .ctx = self,
            .start_fn = startThunk,
            .stop_fn = stopThunk,
            .stop_for_pane_fn = stopForPaneThunk,
        };
    }

    fn startThunk(
        ctx: ?*anyopaque,
        dest: []const u8,
        ssh_args: []const []const u8,
        remote_command: ?[]const u8,
        pane: glyphwire.PaneHandle,
        context: glyphwire.ContextHandle,
    ) anyerror!u64 {
        const self: *Remotes = @ptrCast(@alignCast(ctx.?));
        return self.start(dest, ssh_args, remote_command, pane, context);
    }

    fn stopThunk(ctx: ?*anyopaque, session: u64) void {
        const self: *Remotes = @ptrCast(@alignCast(ctx.?));
        self.stop(session);
    }

    fn stopForPaneThunk(ctx: ?*anyopaque, pane: glyphwire.PaneHandle) void {
        const self: *Remotes = @ptrCast(@alignCast(ctx.?));
        self.stopForPane(pane);
    }

    fn start(
        self: *Remotes,
        dest: []const u8,
        ssh_args: []const []const u8,
        remote_command: ?[]const u8,
        pane: glyphwire.PaneHandle,
        context: glyphwire.ContextHandle,
    ) !u64 {
        self.mutex.lockUncancelable(self.io);
        const id = self.next_id;
        self.next_id += 1;
        self.mutex.unlock(self.io);

        const remote = try Remote.create(self.alloc, self.io, self.server, null, self.environ, .{
            .dest = dest,
            .remote_command = remote_command orelse "gw-agent",
            .ssh_args = ssh_args,
            .agent_path = self.agent_path,
            .host_sock = self.host_sock,
            .pane = pane,
            .ctx = context,
        }, self, id);

        // Enrolled before it runs, so the session's own thread can never
        // reach `finished` -- and free it -- ahead of the table entry that
        // names it.
        self.mutex.lockUncancelable(self.io);
        self.sessions.put(self.alloc, id, remote) catch |err| {
            self.mutex.unlock(self.io);
            remote.destroy();
            return err;
        };
        self.mutex.unlock(self.io);

        remote.launch() catch |err| {
            self.mutex.lockUncancelable(self.io);
            _ = self.sessions.remove(id);
            self.mutex.unlock(self.io);
            remote.destroy();
            return err;
        };
        return id;
    }

    fn stop(self: *Remotes, id: u64) void {
        self.mutex.lockUncancelable(self.io);
        const remote = self.sessions.get(id);
        self.mutex.unlock(self.io);
        if (remote) |r| r.stop();
    }

    fn stopForPane(self: *Remotes, pane: glyphwire.PaneHandle) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var it = self.sessions.valueIterator();
        while (it.next()) |r| {
            if (r.*.opts.pane == pane) r.*.stop();
        }
    }

    /// Called by a session's own thread as it ends: drop it from the
    /// table, tell the shell waiting behind it, and free it.
    fn finished(self: *Remotes, remote: *Remote) void {
        self.mutex.lockUncancelable(self.io);
        _ = self.sessions.remove(remote.id);
        self.mutex.unlock(self.io);

        const status = remote.exit_status.load(.monotonic);
        const started = remote.came_up.load(.monotonic);
        self.server.reportRemoteExit(self.alloc, remote.id, status, started) catch |err| {
            // The shell is parked waiting for this. Nothing here can
            // deliver it now, but its listener also fails when the window
            // goes, so it is not wedged forever.
            std.log.err("glyphwire: could not report remote session exit: {t}", .{err});
        };
        // Deliberately not freed -- see `Remote.finish`.
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
            .hello => {}, // already consumed one in `bringUp`; ignore extras
        }
    }
    // Trunk gone. `Remote.finish` does the teardown, for both this exit
    // and the one where the session never came up at all.
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

/// Reaps `ssh` and records what it exited with, so `remote_exit` can tell
/// "the remote shell exited" from "the connection failed". Closing the
/// trunk is what ends the session; this thread only decides the status
/// and retires the pid (see `Remote.stop`).
fn reaper(self: *Remote) void {
    const term = self.ssh.wait(self.io) catch {
        self.ssh_reaped.store(true, .monotonic);
        return;
    };
    self.exit_status.store(waitStatus(term), .monotonic);
    self.ssh_reaped.store(true, .monotonic);
    if (self.session_exited) |flag| flag.store(true, .monotonic);
}

/// A `Term` flattened to the shell convention `pane_exit` already uses:
/// the exit code for a normal exit, `128 + signal` for a signalled death.
fn waitStatus(term: std.process.Child.Term) i64 {
    return switch (term) {
        .exited => |code| @intCast(code),
        .signal => |sig| 128 + @as(i64, @intFromEnum(sig)),
        .stopped, .unknown => 1,
    };
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
        var ui = AuthClient.connect(self.io, self.alloc, self.opts.host_sock, self.opts.pane) catch |err| {
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

    /// Both connections attach to the session's pane, which is what makes
    /// the prompt appear in the rectangle the user ran `gwssh` in rather
    /// than over whatever is in the focused one -- and what gets the typed
    /// line delivered to it, since raw input reaches only the connection
    /// whose context is on screen in the focused pane.
    fn connect(io: std.Io, alloc: std.mem.Allocator, sock: []const u8, pane: glyphwire.PaneHandle) !AuthClient {
        var client = try glyphwire.Client.connect(io, alloc, sock);
        errdefer client.deinit();
        try client.attachPane(pane);
        const listener = try glyphwire.InputListener.connectInPane(io, alloc, sock, &.{ "text", "key" }, pane);
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
