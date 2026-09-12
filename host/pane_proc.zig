//! The host's `spawn_in_pane` implementation: one PTY-backed child process
//! per pane, and the plumbing that makes a pane look like a whole host to
//! whatever runs in it.
//!
//! This lives in the host rather than in `src/` on purpose. A pane is a
//! sequestered host, and only the thing that actually *is* the host knows
//! what a child needs in order to find it: the socket path, which pane it
//! has been seated in, and how big its terminal is. A window manager that
//! forked its own children would have to reconstruct all of that, and
//! would be the only process able to reap them, which is exactly what makes
//! detach/reattach impossible. See `dispatch.PaneSpawner`.
//!
//! **Two kinds of program, one rule.** A glyphwire-aware child (`gw-shell`,
//! `zoe`) connects back over `GLYPHWIRE_SOCK`, binds itself to the pane with
//! `attach_pane`, and draws through the protocol; its PTY carries almost
//! nothing. A plain child (`bash`, `vim`) knows nothing about any of that
//! and just writes bytes to its terminal, which arrive here and are written
//! onto the pane's base context root layer.
//!
//! What must never happen is *both* at once on the same surface, which is
//! what garbled the previous layer-per-pane design: two writers, no
//! arbitration. Here there is exactly one writer per surface -- this module
//! for a PTY child, or the child's own connection for an aware one -- and
//! which it is doesn't need deciding, because an aware child's PTY simply
//! stays quiet.

const std = @import("std");
const glyphwire = @import("glyphwire");

const Pty = glyphwire.pty.Pty;

/// How much PTY output one pane buffers between drains. A full buffer
/// drops the oldest bytes rather than blocking the reader thread: a pane
/// producing output faster than the window can draw it is already showing
/// the user a blur, and stalling its PTY would stall the program.
const pane_buf_capacity: usize = 256 * 1024;

/// One pane's child process.
const Proc = struct {
    pane: glyphwire.PaneHandle,
    /// The base context of that pane -- where plain PTY output is written.
    context: glyphwire.ContextHandle,
    pty: Pty,
    /// The pty master fd, copied out so the reader thread can poll it
    /// without touching `pty` (which the main loop reaps).
    master: std.c.fd_t,
    /// Guards `out` between the reader thread and the main loop's drain.
    mutex: std.Io.Mutex = .init,
    out: std.ArrayList(u8) = .empty,
    /// Set by the reader thread at EOF. With `pty.reaped()` this is how
    /// `pump` notices the child is gone.
    eof: std.atomic.Value(bool) = .init(false),
    /// Set once the exit has been reported, so `pane_exit` is sent once.
    reported: bool = false,
    /// Tells the reader thread to stop, for a kill that happens while the
    /// child is still producing output.
    stop: std.atomic.Value(bool) = .init(false),
    reader: ?std.Thread = null,
};

/// Every pane that has a program in it.
pub const PaneProcs = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    server: *glyphwire.server.Server,
    /// The socket children connect back on, and the environment to base
    /// theirs on. Both borrowed for the process lifetime.
    socket_path: []const u8,
    environ: *const std.process.Environ.Map,

    mutex: std.Io.Mutex = .init,
    procs: std.AutoHashMapUnmanaged(glyphwire.PaneHandle, *Proc) = .empty,

    pub fn init(
        alloc: std.mem.Allocator,
        io: std.Io,
        server: *glyphwire.server.Server,
        socket_path: []const u8,
        environ: *const std.process.Environ.Map,
    ) PaneProcs {
        return .{
            .alloc = alloc,
            .io = io,
            .server = server,
            .socket_path = socket_path,
            .environ = environ,
        };
    }

    pub fn deinit(self: *PaneProcs) void {
        var it = self.procs.valueIterator();
        while (it.next()) |p| self.destroyProc(p.*);
        self.procs.deinit(self.alloc);
    }

    /// The `dispatch.PaneSpawner` this registers with the server.
    pub fn spawner(self: *PaneProcs) glyphwire.PaneSpawner {
        return .{
            .ctx = self,
            .spawn_fn = spawnThunk,
            .kill_fn = killThunk,
        };
    }

    fn spawnThunk(
        ctx: ?*anyopaque,
        pane: glyphwire.PaneHandle,
        context: glyphwire.ContextHandle,
        argv: []const []const u8,
        cols: usize,
        rows: usize,
    ) anyerror!i32 {
        const self: *PaneProcs = @ptrCast(@alignCast(ctx.?));
        return self.spawn(pane, context, argv, cols, rows);
    }

    fn killThunk(ctx: ?*anyopaque, pane: glyphwire.PaneHandle) void {
        const self: *PaneProcs = @ptrCast(@alignCast(ctx.?));
        self.kill(pane);
    }

    /// Starts `argv` in `pane`. One program per pane: an existing one is
    /// stopped first, so a manager respawning into a pane can't leak the
    /// child that was there.
    pub fn spawn(
        self: *PaneProcs,
        pane: glyphwire.PaneHandle,
        context: glyphwire.ContextHandle,
        argv: []const []const u8,
        cols: usize,
        rows: usize,
    ) !i32 {
        if (argv.len == 0) return error.EmptyArgv;
        self.kill(pane);

        const proc = try self.alloc.create(Proc);
        errdefer self.alloc.destroy(proc);

        // argv and env both have to be NUL-terminated and built before the
        // fork -- see `pty.zig`'s async-signal-safety note.
        const argv_z = try self.alloc.allocSentinel(?[*:0]const u8, argv.len, null);
        defer self.alloc.free(argv_z);
        var made: usize = 0;
        defer for (0..made) |i| self.alloc.free(std.mem.span(argv_z[i].?));
        for (argv, 0..) |a, i| {
            // argv[0] prefers this build's own sibling binary over whatever
            // `PATH` finds -- see `resolveProgram`.
            const resolved = if (i == 0) try self.resolveProgram(a) else null;
            defer if (resolved) |r| self.alloc.free(r);
            const src = resolved orelse a;
            const dup = try self.alloc.allocSentinel(u8, src.len, 0);
            @memcpy(dup, src);
            argv_z[i] = dup.ptr;
            made += 1;
        }

        const env = try self.paneEnv(pane, context);
        defer self.freePaneEnv(env);

        const pty = try Pty.spawn(argv_z.ptr, @intCast(cols), @intCast(rows), env.envp.ptr);
        proc.* = .{ .pane = pane, .context = context, .pty = pty, .master = pty.master };

        proc.reader = std.Thread.spawn(.{}, readerLoop, .{ self, proc }) catch |err| blk: {
            std.log.warn("glyphwire-host: pane {d} reader thread failed ({t}); output will not be shown", .{ pane, err });
            break :blk null;
        };

        {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            try self.procs.put(self.alloc, pane, proc);
        }
        return proc.pty.pid;
    }

    /// Resolves a bare program name against the directory this build's
    /// binaries live in, falling back to `PATH` (by returning null) when
    /// there is no such sibling.
    ///
    /// The same `GLYPHWIRE_BIN_DIR`-then-exe-dir rule `host/main.zig` uses
    /// to find its own `gw-shell`, applied to whatever a window manager
    /// asks to spawn. Without it a `gmux` from a work tree would run
    /// whichever `gw-shell` happens to be installed system-wide, which is a
    /// genuinely confusing failure: the two speak different versions of the
    /// protocol and the symptom is a pane that draws in the wrong place.
    ///
    /// Only argv[0], and only a bare name: an explicit path or a program
    /// with no sibling here goes through `PATH` untouched.
    fn resolveProgram(self: *PaneProcs, name: []const u8) !?[]const u8 {
        if (std.mem.indexOfScalar(u8, name, '/') != null) return null;

        const dir = if (self.environ.get("GLYPHWIRE_BIN_DIR")) |d|
            try self.alloc.dupe(u8, d)
        else
            try std.process.executableDirPathAlloc(self.io, self.alloc);
        defer self.alloc.free(dir);

        const candidate = try std.fs.path.join(self.alloc, &.{ dir, name });
        errdefer self.alloc.free(candidate);
        std.Io.Dir.cwd().access(self.io, candidate, .{}) catch {
            self.alloc.free(candidate);
            return null;
        };
        return candidate;
    }

    const PaneEnv = struct {
        envp: [:null]?[*:0]const u8,
        /// The strings `envp`'s extra entries point at, owned here.
        owned: [3][:0]u8,
    };

    /// The three variables that make a pane findable, composed onto the
    /// host's own environment.
    ///
    /// `GLYPHWIRE_PANE` is the whole handshake: a child's `Client` /
    /// `InputListener` read it and send `attach_pane` as their first
    /// message, so by the time anything else on that connection is
    /// processed it is bound to the right pane. Being the first message on
    /// the same ordered stream is what makes it race-free, rather than
    /// hopeful.
    fn paneEnv(self: *PaneProcs, pane: glyphwire.PaneHandle, context: glyphwire.ContextHandle) !PaneEnv {
        const sock = try std.fmt.allocPrintSentinel(self.alloc, "GLYPHWIRE_SOCK={s}", .{self.socket_path}, 0);
        errdefer self.alloc.free(sock);
        const pane_var = try std.fmt.allocPrintSentinel(self.alloc, "GLYPHWIRE_PANE={d}", .{pane}, 0);
        errdefer self.alloc.free(pane_var);
        const ctx_var = try std.fmt.allocPrintSentinel(self.alloc, "GLYPHWIRE_CTX={d}", .{context}, 0);
        errdefer self.alloc.free(ctx_var);

        const envp = try glyphwire.pty.buildEnvWith(self.alloc, &.{ sock, pane_var, ctx_var });
        return .{ .envp = envp, .owned = .{ sock, pane_var, ctx_var } };
    }

    fn freePaneEnv(self: *PaneProcs, env: PaneEnv) void {
        self.alloc.free(env.envp);
        for (env.owned) |s| self.alloc.free(s);
    }

    /// Stops and reaps whatever is running in `pane`. Safe to call for a
    /// pane with nothing in it.
    pub fn kill(self: *PaneProcs, pane: glyphwire.PaneHandle) void {
        const proc = blk: {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            const kv = self.procs.fetchRemove(pane) orelse return;
            break :blk kv.value;
        };
        proc.pty.signalGroup(std.posix.SIG.HUP);
        self.destroyProc(proc);
    }

    fn destroyProc(self: *PaneProcs, proc: *Proc) void {
        // Reap before joining: the reader thread only unblocks from its
        // `poll` once the child is gone and the master reports EOF.
        proc.stop.store(true, .monotonic);
        proc.pty.wait();
        if (proc.reader) |t| t.join();
        proc.pty.deinit();
        proc.out.deinit(self.alloc);
        self.alloc.destroy(proc);
    }

    /// Writes `bytes` to the pane's PTY -- how a window manager forwards
    /// input to a plain child. Aware children get their input over the
    /// wire instead and ignore this.
    pub fn write(self: *PaneProcs, pane: glyphwire.PaneHandle, bytes: []const u8) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const proc = self.procs.get(pane) orelse return;
        proc.pty.writeAll(bytes);
    }

    /// Tells every pane's PTY its new size. Called after a pane relayout,
    /// so a plain child's `SIGWINCH` and `ioctl(TIOCGWINSZ)` agree with the
    /// pane it is actually drawing into.
    pub fn syncSizes(self: *PaneProcs) void {
        const server = self.server;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        var it = self.procs.valueIterator();
        while (it.next()) |p| {
            const size = blk: {
                server.ctx_mutex.lockUncancelable(server.io);
                defer server.ctx_mutex.unlock(server.io);
                const pane = server.session.panePtr(p.*.pane) orelse continue;
                break :blk .{ .cols = @max(pane.rect.cols, 1), .rows = @max(pane.rect.rows, 1) };
            };
            p.*.pty.resize(@intCast(size.cols), @intCast(size.rows));
        }
    }

    /// Drains every pane's PTY output onto its base context, and reports
    /// any child that has exited. Called once per host iteration.
    ///
    /// **The wire write happens here, on the main loop, never on a reader
    /// thread.** With N panes producing output at once, N reader threads
    /// writing into the same `Context` would race on `ctx_mutex` in ways
    /// that reorder one program's own output, and the buffer-per-pane makes
    /// the ordering-within-a-pane guarantee trivial instead.
    pub fn pump(self: *PaneProcs, alloc: std.mem.Allocator) void {
        var dead: [8]glyphwire.PaneHandle = undefined;
        var exits: [8]struct { pane: glyphwire.PaneHandle, status: i64 } = undefined;
        var n_dead: usize = 0;

        {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);

            var it = self.procs.valueIterator();
            while (it.next()) |pp| {
                const proc = pp.*;
                self.drainOne(proc);

                if (n_dead >= dead.len) continue; // caught next iteration
                const gone = proc.eof.load(.monotonic) or proc.pty.reaped();
                if (gone and !proc.reported) {
                    proc.reported = true;
                    dead[n_dead] = proc.pane;
                    exits[n_dead] = .{ .pane = proc.pane, .status = proc.pty.exit_code };
                    n_dead += 1;
                }
            }
        }

        // Outside the lock: `reportPaneExit` broadcasts, and a subscriber's
        // handler can come back through this module.
        for (exits[0..n_dead]) |e| {
            self.server.reportPaneExit(alloc, e.pane, e.status) catch |err| {
                std.log.err("glyphwire-host: pane_exit for pane {d} failed: {t}", .{ e.pane, err });
            };
        }
    }

    /// Moves one pane's buffered PTY bytes onto its base context's root
    /// layer. Caller holds `self.mutex`.
    fn drainOne(self: *PaneProcs, proc: *Proc) void {
        proc.mutex.lockUncancelable(self.io);
        if (proc.out.items.len == 0) {
            proc.mutex.unlock(self.io);
            return;
        }
        const chunk = proc.out.toOwnedSlice(self.alloc) catch {
            proc.out.clearRetainingCapacity();
            proc.mutex.unlock(self.io);
            return;
        };
        proc.mutex.unlock(self.io);
        defer self.alloc.free(chunk);

        const server = self.server;
        server.ctx_mutex.lockUncancelable(server.io);
        defer server.ctx_mutex.unlock(server.io);
        const ctx = server.session.contextPtr(proc.context) orelse return;
        // `pty_mode` keeps the escape-sequence machine alive across calls,
        // so a `CSI` split across two `read()`s still parses as one -- see
        // `core.Layer.pty_mode`.
        ctx.root.pty_mode = true;
        ctx.root.writeText(chunk, glyphwire.default_style.fg, null) catch {};
    }
};

fn readerLoop(self: *PaneProcs, proc: *Proc) void {
    var buf: [8192]u8 = undefined;
    while (!proc.stop.load(.monotonic)) {
        // Poll with a timeout rather than a bare blocking read, so a kill
        // that happens while the child is idle still lets this thread
        // notice `stop` and return instead of parking forever.
        var pfd = [_]std.posix.pollfd{.{ .fd = proc.master, .events = std.posix.POLL.IN, .revents = 0 }};
        const ready = std.posix.poll(&pfd, 100) catch break;
        if (ready == 0) continue;
        const n_raw = std.c.read(proc.master, &buf, buf.len);
        if (n_raw <= 0) break;
        const n: usize = @intCast(n_raw);

        proc.mutex.lockUncancelable(self.io);
        // Over capacity, drop the oldest half rather than stalling the
        // child. See `pane_buf_capacity`.
        if (proc.out.items.len + n > pane_buf_capacity) {
            const keep = proc.out.items.len / 2;
            std.mem.copyForwards(u8, proc.out.items[0..keep], proc.out.items[proc.out.items.len - keep ..]);
            proc.out.shrinkRetainingCapacity(keep);
        }
        proc.out.appendSlice(self.alloc, buf[0..n]) catch {};
        proc.mutex.unlock(self.io);
    }
    proc.eof.store(true, .monotonic);
}
