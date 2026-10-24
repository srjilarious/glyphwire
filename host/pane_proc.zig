// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: MPL-2.0

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
//!
//! **Spawned shells.** The context switcher's "new shell" also starts its
//! `gw-shell` here (`spawnShell`), but on a context the host makes for it
//! rather than on the pane's base, and any number per pane. They are kept
//! apart from the one-per-pane programs (`shells`), and a pane outlives
//! its own program while any of them still runs (`deferred_exits`).

const std = @import("std");
const glyphwire = @import("glyphwire");

const Pty = glyphwire.pty.Pty;

/// How much PTY output one pane buffers between drains. A full buffer
/// drops the oldest bytes rather than blocking the reader thread: a pane
/// producing output faster than the window can draw it is already showing
/// the user a blur, and stalling its PTY would stall the program.
const pane_buf_capacity: usize = 256 * 1024;

/// One pane's child process, or one shell spawned into a pane.
const Proc = struct {
    pane: glyphwire.PaneHandle,
    /// Where plain PTY output is written: the pane's base context, or the
    /// context made for a spawned shell.
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

    /// Guards `procs`, `shells` and `deferred_exits`.
    ///
    /// **Lock order: the server's `ctx_mutex` before this one**, never
    /// the reverse. The dispatcher runs `spawn` and `kill` (through
    /// `dispatch.PaneSpawner`) already holding `ctx_mutex`, so anything
    /// here that needs both takes `ctx_mutex` first; the other order
    /// deadlocks the moment a split lands while a pane is producing
    /// output. A `Proc`'s own `mutex` is a leaf under either.
    mutex: std.Io.Mutex = .init,
    procs: std.AutoHashMapUnmanaged(glyphwire.PaneHandle, *Proc) = .empty,
    /// Shells the context switcher spawned (`spawnShell`), by the context
    /// each one draws on.
    shells: std.AutoHashMapUnmanaged(glyphwire.ContextHandle, *Proc) = .empty,
    /// Panes whose program exited while spawned shells were still running
    /// in them, with its exit status. Such a pane lives on until the last
    /// of those shells exits, and only then is its `pane_exit` sent.
    deferred_exits: std.AutoHashMapUnmanaged(glyphwire.PaneHandle, i64) = .empty,
    /// The root pane's first shell, which `main` starts rather than this
    /// module, so `shellCwd` can still read its directory. Set by `main`.
    root_shell_pid: ?std.posix.pid_t = null,

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
        var sit = self.shells.valueIterator();
        while (sit.next()) |p| self.destroyProc(p.*);
        self.shells.deinit(self.alloc);
        self.deferred_exits.deinit(self.alloc);
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
        cwd: glyphwire.SpawnCwd,
    ) anyerror!i32 {
        const self: *PaneProcs = @ptrCast(@alignCast(ctx.?));
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        // The dispatcher calls this holding `ctx_mutex`, so the locked
        // variant: `shellCwd` would take it again and hang the host.
        const from = if (cwd.from) |p| self.shellCwdLocked(p, &buf) else null;
        return self.spawn(pane, context, argv, cols, rows, from orelse cwd.path);
    }

    fn killThunk(ctx: ?*anyopaque, pane: glyphwire.PaneHandle) void {
        const self: *PaneProcs = @ptrCast(@alignCast(ctx.?));
        self.kill(pane);
    }

    /// Starts `argv` in `pane`, in `cwd` (null: the host's own directory).
    /// One program per pane: an existing one is stopped first, so a
    /// manager respawning into a pane can't leak the child that was there.
    /// Shells spawned into the pane are left alone.
    pub fn spawn(
        self: *PaneProcs,
        pane: glyphwire.PaneHandle,
        context: glyphwire.ContextHandle,
        argv: []const []const u8,
        cols: usize,
        rows: usize,
        cwd: ?[]const u8,
    ) !i32 {
        if (argv.len == 0) return error.EmptyArgv;
        self.killProgram(pane);

        const proc = try self.start(pane, context, argv, cols, rows, cwd);
        errdefer self.stopProc(proc);
        {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            try self.procs.put(self.alloc, pane, proc);
            _ = self.deferred_exits.remove(pane);
        }
        return proc.pty.pid;
    }

    /// Starts a `gw-shell` in `pane` on a context of its own, put on top
    /// of the pane: the context switcher's "new shell". It starts in `cwd`
    /// (null: the host's own directory). Returns that context, which goes
    /// when the shell exits (`pump`).
    pub fn spawnShell(self: *PaneProcs, pane: glyphwire.PaneHandle, cwd: ?[]const u8) !glyphwire.ContextHandle {
        const server = self.server;
        const size = blk: {
            server.ctx_mutex.lockUncancelable(server.io);
            defer server.ctx_mutex.unlock(server.io);
            const p = server.session.panePtr(pane) orelse return error.UnknownPane;
            break :blk .{ .cols = @max(p.rect.cols, 1), .rows = @max(p.rect.rows, 1) };
        };

        const context = try server.createShellContext(self.alloc, pane);
        errdefer server.destroyShellContext(self.alloc, context) catch {};

        var handle_buf: [24]u8 = undefined;
        const handle_arg = try std.fmt.bufPrint(&handle_buf, "{d}", .{context});
        const proc = try self.start(pane, context, &.{ "gw-shell", "--context", handle_arg }, size.cols, size.rows, cwd);
        errdefer self.stopProc(proc);

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try self.shells.put(self.alloc, context, proc);
        return context;
    }

    /// Forks `argv` onto a fresh PTY in `cwd` and starts its reader. The
    /// caller files the result in `procs` or `shells`.
    fn start(
        self: *PaneProcs,
        pane: glyphwire.PaneHandle,
        context: glyphwire.ContextHandle,
        argv: []const []const u8,
        cols: usize,
        rows: usize,
        cwd: ?[]const u8,
    ) !*Proc {
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

        const cwd_z: ?[:0]u8 = if (cwd) |d| blk: {
            const z = try self.alloc.allocSentinel(u8, d.len, 0);
            @memcpy(z, d);
            break :blk z;
        } else null;
        defer if (cwd_z) |d| self.alloc.free(d);

        const pty = try Pty.spawnIn(argv_z.ptr, @intCast(cols), @intCast(rows), env.envp.ptr, if (cwd_z) |d| d.ptr else null);
        proc.* = .{ .pane = pane, .context = context, .pty = pty, .master = pty.master };

        proc.reader = std.Thread.spawn(.{}, readerLoop, .{ self, proc }) catch |err| blk: {
            std.log.warn("glyphwire-host: pane {d} reader thread failed ({t}); output will not be shown", .{ pane, err });
            break :blk null;
        };
        return proc;
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

        // Absolute, because the child `chdir`s before it execs: a dev
        // run's relative `GLYPHWIRE_BIN_DIR=zig-out/bin` would otherwise
        // be looked up from the pane's start directory and fail.
        var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
        const cwd_len = try std.process.currentPath(self.io, &cwd_buf);
        const candidate = try std.fs.path.resolve(self.alloc, &.{ cwd_buf[0..cwd_len], dir, name });
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

    /// Stops and reaps whatever is running in `pane`, spawned shells
    /// included: the pane is going away. Safe to call for a pane with
    /// nothing in it.
    pub fn kill(self: *PaneProcs, pane: glyphwire.PaneHandle) void {
        self.killProgram(pane);
        var doomed: std.ArrayList(*Proc) = .empty;
        defer doomed.deinit(self.alloc);
        {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            _ = self.deferred_exits.remove(pane);
            var it = self.shells.valueIterator();
            while (it.next()) |p| {
                if (p.*.pane == pane) doomed.append(self.alloc, p.*) catch {};
            }
            for (doomed.items) |p| _ = self.shells.remove(p.context);
        }
        for (doomed.items) |p| self.stopProc(p);
    }

    /// Stops and reaps `pane`'s own program, leaving its spawned shells.
    fn killProgram(self: *PaneProcs, pane: glyphwire.PaneHandle) void {
        const proc = blk: {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            const kv = self.procs.fetchRemove(pane) orelse return;
            break :blk kv.value;
        };
        self.stopProc(proc);
    }

    /// Hangs up `proc`'s process group, then reaps and frees it. `proc`
    /// is already out of `procs` / `shells`.
    fn stopProc(self: *PaneProcs, proc: *Proc) void {
        proc.pty.signalGroup(std.posix.SIG.HUP);
        self.destroyProc(proc);
    }

    /// Whether anything is left in `pane` above its base context: a
    /// spawned shell's context, or a program's own screen. Either is a
    /// glyphwire program still alive there, so a pane whose own program
    /// has exited stays open while this holds. The one rule for every
    /// pane, the root one included (`App.update`).
    pub fn paneHeld(self: *PaneProcs, pane: glyphwire.PaneHandle) bool {
        const server = self.server;
        server.ctx_mutex.lockUncancelable(server.io);
        defer server.ctx_mutex.unlock(server.io);
        return self.paneHeldLocked(pane);
    }

    /// `paneHeld` for a caller already holding `ctx_mutex`.
    fn paneHeldLocked(self: *PaneProcs, pane: glyphwire.PaneHandle) bool {
        const p = self.server.session.panePtr(pane) orelse return false;
        for (p.stack.items) |h| {
            if (h != p.base) return true;
        }
        return false;
    }

    /// Whether `pane`'s own program has exited while the pane is held
    /// open (`paneHeld`).
    pub fn programExited(self: *PaneProcs, pane: glyphwire.PaneHandle) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.deferred_exits.contains(pane);
    }

    /// The pid of the shell drawing on `context` if it is a spawned one,
    /// or of `pane`'s own program if `context` is the base it was started
    /// on. Null for anything else (a program's own context, or the root
    /// pane's first shell, which `main` started).
    pub fn pidFor(self: *PaneProcs, pane: glyphwire.PaneHandle, context: glyphwire.ContextHandle) ?std.posix.pid_t {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.shells.get(context)) |p| return p.pty.pid;
        const p = self.procs.get(pane) orelse return null;
        return if (p.context == context) p.pty.pid else null;
    }

    /// How many contexts of one pane's stack `shellCwd` looks through,
    /// from the top. A stack deeper than this is not a real session.
    const max_stack_scan = 32;

    /// The working directory of the topmost context in `pane` whose
    /// process the host started (a spawned shell, the pane's own program,
    /// or the root pane's first shell), read from `/proc/<pid>/cwd`. A
    /// program's own screen is skipped: the shell under it is what a new
    /// shell should feel like a sibling of. Null when there is none.
    pub fn shellCwd(self: *PaneProcs, pane: glyphwire.PaneHandle, buf: []u8) ?[]const u8 {
        // Copied out first, and searched after the lock is dropped: the
        // `/proc` reads needn't hold up every connection.
        var top: StackTop = undefined;
        {
            const server = self.server;
            server.ctx_mutex.lockUncancelable(server.io);
            defer server.ctx_mutex.unlock(server.io);
            top = self.stackTop(pane) orelse return null;
        }
        return self.cwdIn(pane, &top, buf);
    }

    /// `shellCwd` for a caller already holding `ctx_mutex`: the
    /// `spawn_in_pane` hook, which the dispatcher runs under it.
    pub fn shellCwdLocked(self: *PaneProcs, pane: glyphwire.PaneHandle, buf: []u8) ?[]const u8 {
        var top = self.stackTop(pane) orelse return null;
        return self.cwdIn(pane, &top, buf);
    }

    /// The top of one pane's context stack, topmost first.
    const StackTop = struct {
        handles: [max_stack_scan]glyphwire.ContextHandle,
        len: usize,
        base: glyphwire.ContextHandle,
    };

    /// `pane`'s `StackTop`, or null for a pane that's gone. Caller holds
    /// `ctx_mutex`.
    fn stackTop(self: *PaneProcs, pane: glyphwire.PaneHandle) ?StackTop {
        const p = self.server.session.panePtr(pane) orelse return null;
        var top: StackTop = .{ .handles = undefined, .len = 0, .base = p.base };
        const stack = p.stack.items;
        top.len = @min(stack.len, top.handles.len);
        for (0..top.len) |i| top.handles[i] = stack[stack.len - 1 - i];
        return top;
    }

    /// The directory of the first context in `top` the host started a
    /// process for. Takes `self.mutex` (`pidFor`), inside `ctx_mutex` when
    /// the caller holds it: the order on `mutex`.
    fn cwdIn(self: *PaneProcs, pane: glyphwire.PaneHandle, top: *const StackTop, buf: []u8) ?[]const u8 {
        for (top.handles[0..top.len]) |h| {
            var pid = self.pidFor(pane, h);
            if (pid == null and pane == glyphwire.root_pane_handle and h == top.base) pid = self.root_shell_pid;
            const known = pid orelse continue;
            if (procCwd(known, buf)) |dir| return dir;
        }
        return null;
    }

    fn procCwd(pid: std.posix.pid_t, buf: []u8) ?[]const u8 {
        var path_buf: [64]u8 = undefined;
        const path = std.fmt.bufPrintSentinel(&path_buf, "/proc/{d}/cwd", .{pid}, 0) catch return null;
        const n = std.c.readlink(path.ptr, buf.ptr, buf.len);
        if (n <= 0) return null;
        return buf[0..@intCast(n)];
    }

    /// `pane`'s own program has exited but the pane is held open: if its
    /// dead screen is the one showing, bring up whatever was shown most
    /// recently before it. Also called by the host for the root pane,
    /// whose first shell isn't one of `procs`.
    pub fn bringForwardOverBase(self: *PaneProcs, alloc: std.mem.Allocator, pane: glyphwire.PaneHandle) void {
        const server = self.server;
        const target = blk: {
            server.ctx_mutex.lockUncancelable(server.io);
            defer server.ctx_mutex.unlock(server.io);
            const p = server.session.panePtr(pane) orelse return;
            const stack = p.stack.items;
            if (stack.len < 2 or stack[stack.len - 1] != p.base) return;
            break :blk stack[stack.len - 2];
        };
        _ = server.activateContext(alloc, target) catch |err| {
            std.log.err("glyphwire-host: bringing a context forward in pane {d} failed: {t}", .{ pane, err });
        };
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

    /// Tells every pane's PTY, and every spawned shell's, its new size.
    /// Called after a pane relayout,
    /// so a plain child's `SIGWINCH` and `ioctl(TIOCGWINSZ)` agree with the
    /// pane it is actually drawing into.
    pub fn syncSizes(self: *PaneProcs) void {
        const server = self.server;
        // `ctx_mutex` first: see the lock order on `mutex`.
        server.ctx_mutex.lockUncancelable(server.io);
        defer server.ctx_mutex.unlock(server.io);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        var it = self.procs.valueIterator();
        while (it.next()) |p| syncSize(server, p.*);
        var sit = self.shells.valueIterator();
        while (sit.next()) |p| syncSize(server, p.*);
    }

    /// Caller holds `ctx_mutex`.
    fn syncSize(server: *glyphwire.server.Server, proc: *Proc) void {
        const pane = server.session.panePtr(proc.pane) orelse return;
        proc.pty.resize(@intCast(@max(pane.rect.cols, 1)), @intCast(@max(pane.rect.rows, 1)));
    }

    /// Drains every PTY's output onto its context, and deals with any
    /// child that has exited: a pane's program is reported (`pane_exit`),
    /// unless spawned shells still keep its pane open, and a spawned shell
    /// takes its context with it. Called once per host iteration.
    ///
    /// **The wire write happens here, on the main loop, never on a reader
    /// thread.** With N panes producing output at once, N reader threads
    /// writing into the same `Context` would race on `ctx_mutex` in ways
    /// that reorder one program's own output, and the buffer-per-pane makes
    /// the ordering-within-a-pane guarantee trivial instead.
    pub fn pump(self: *PaneProcs, alloc: std.mem.Allocator) void {
        // Fixed-size: whatever doesn't fit is caught next iteration.
        var exits: [8]struct { pane: glyphwire.PaneHandle, status: i64 } = undefined;
        var n_exits: usize = 0;
        // Panes whose program just exited while spawned shells live on.
        var fresh: [8]glyphwire.PaneHandle = undefined;
        var n_fresh: usize = 0;
        // Spawned shells to finish: exited, or their context went with
        // their pane (`hangup`).
        var done: [8]struct { proc: *Proc, hangup: bool } = undefined;
        var n_done: usize = 0;

        const server = self.server;
        {
            // `ctx_mutex` first: see the lock order on `mutex`.
            server.ctx_mutex.lockUncancelable(server.io);
            defer server.ctx_mutex.unlock(server.io);
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);

            // A program that exits goes to `deferred_exits` first; the
            // pass below decides whether its pane is still held open.
            var it = self.procs.valueIterator();
            while (it.next()) |pp| {
                const proc = pp.*;
                self.drainOne(proc);

                if (n_fresh >= fresh.len) continue;
                const gone = proc.eof.load(.monotonic) or proc.pty.reaped();
                if (gone and !proc.reported) {
                    self.deferred_exits.put(self.alloc, proc.pane, proc.pty.exit_code) catch continue;
                    proc.reported = true;
                    fresh[n_fresh] = proc.pane;
                    n_fresh += 1;
                }
            }

            var sit = self.shells.valueIterator();
            while (sit.next()) |pp| {
                const proc = pp.*;
                self.drainOne(proc);

                if (n_done >= done.len) break;
                const gone = proc.eof.load(.monotonic) or proc.pty.reaped();
                if (gone or server.session.contextPtr(proc.context) == null) {
                    done[n_done] = .{ .proc = proc, .hangup = !gone };
                    n_done += 1;
                }
            }
            for (done[0..n_done]) |d| _ = self.shells.remove(d.proc.context);
        }

        // Outside the lock: these broadcast, and a subscriber's handler
        // can come back through this module.
        for (done[0..n_done]) |d| {
            const context = d.proc.context;
            if (d.hangup) self.stopProc(d.proc) else self.destroyProc(d.proc);
            server.destroyShellContext(alloc, context) catch |err| {
                std.log.err("glyphwire-host: dropping spawned shell context {d} failed: {t}", .{ context, err });
            };
        }

        // After the contexts above are gone, so the last spawned shell
        // exiting closes its pane in this same pass: a pane whose program
        // has exited goes once nothing holds it open.
        {
            server.ctx_mutex.lockUncancelable(server.io);
            defer server.ctx_mutex.unlock(server.io);
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            var dit = self.deferred_exits.iterator();
            while (dit.next()) |e| {
                if (n_exits >= exits.len) break;
                if (self.paneHeldLocked(e.key_ptr.*)) continue;
                exits[n_exits] = .{ .pane = e.key_ptr.*, .status = e.value_ptr.* };
                n_exits += 1;
            }
            for (exits[0..n_exits]) |e| _ = self.deferred_exits.remove(e.pane);
        }
        for (fresh[0..n_fresh]) |pane| {
            if (self.programExited(pane)) self.bringForwardOverBase(alloc, pane);
        }
        for (exits[0..n_exits]) |e| {
            server.reportPaneExit(alloc, e.pane, e.status) catch |err| {
                std.log.err("glyphwire-host: pane_exit for pane {d} failed: {t}", .{ e.pane, err });
            };
        }
    }

    /// Moves one child's buffered PTY bytes onto its context's root
    /// layer. Caller holds `ctx_mutex`, then `self.mutex`.
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

        // A glyphwire-aware child (`gw-shell`, `zoe`) writes
        // `handshake_marker` to its stdout, this PTY, as it connects. That
        // is a signal for a shell that launched it, not text: written out
        // it would sit on the screen as `glyphwire-handshake-v1`.
        const marker = glyphwire.handshake_marker;
        var text: []const u8 = chunk;
        var cleaned: ?[]u8 = null;
        defer if (cleaned) |c| self.alloc.free(c);
        if (std.mem.indexOf(u8, chunk, marker) != null) {
            const out = self.alloc.alloc(u8, chunk.len) catch return;
            const count = std.mem.replace(u8, chunk, marker, "", out);
            cleaned = out;
            text = out[0 .. chunk.len - count * marker.len];
        }
        if (text.len == 0) return;

        const ctx = self.server.session.contextPtr(proc.context) orelse return;
        // `pty_mode` keeps the escape-sequence machine alive across calls,
        // so a `CSI` split across two `read()`s still parses as one -- see
        // `core.Layer.pty_mode`.
        ctx.root.pty_mode = true;
        ctx.root.writeText(text, glyphwire.default_style.fg, null) catch {};
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
    // An idle window is parked waiting for events; without this a child
    // that exits quietly would sit unreaped (and its pane or spawned
    // shell's context on screen) until the next keypress.
    self.server.wake();
}
