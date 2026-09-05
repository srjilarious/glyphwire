//! Low-level pipeline spawner: forks a run of commands wired stdout->stdin
//! with `pipe(2)`, all in one process group, and hands the parent the fds
//! to pump. `shell/main.zig` layers policy on top (alias/glob resolution,
//! grid mirroring or capture, keystroke forwarding, Ctrl-C).
//!
//! This is the pipe-based counterpart to `pty.zig`. `pty.zig` gives a
//! *single* interactive child a real terminal (line buffering, `isatty()`,
//! job-control Ctrl-C); a pipeline can't work that way -- each stage's
//! stdout has to be an ordinary pipe -- so a multi-stage command, or one
//! with a file redirect, comes here instead. Piped stages see `!isatty()`
//! and lose auto-colour, exactly as in bash.
//!
//! Linux only (libc `fork`/`execvp`/`pipe2`/`dup2` -- this reduced
//! `std.posix` has none); other platforms get a stub whose `spawn`
//! returns `error.Unsupported`, the same shape `pty.zig` uses.
//!
//! What the caller gets back (`Spawned`): the pid list, the process-group
//! id, and three fds -- the write end of stage 0's stdin (unless it has a
//! `<` redirect), the read end of the last stage's stdout (unless it has a
//! `>` redirect), and the read end of a single stderr pipe shared by every
//! stage (unless a stage redirects its own fd 2). Drain the two read fds
//! onto the grid (or into buffers), feed / forward to the write fd, then
//! `wait()`; `deinit` kills anything still alive and closes the fds.

const std = @import("std");
const builtin = @import("builtin");

pub const SpawnError = error{ OutOfMemory, PipeFailed, ForkFailed, Unsupported };

/// How one redirect rewires an fd of a stage. Mirrors
/// `shell/parse.zig`'s `RedirMode`; kept separate so this module has no
/// dependency on the shell's parser.
pub const RedirMode = enum { read, write, append, dup };

pub const Redir = struct {
    /// The fd being redirected (0 for `<`, 1 for `>`/`>>`, 2 for `2>`...).
    fd: u8,
    mode: RedirMode,
    /// `mode == .dup`: the fd `fd` is pointed at (`2>&1` -> fd 2, dup_fd 1).
    dup_fd: u8 = 0,
    /// `mode != .dup`: NUL-terminated target path for `open(2)`.
    path: ?[*:0]const u8 = null,
    /// `&>` / `&>>`: after opening on fd 1, also send fd 2 there.
    also_stderr: bool = false,
};

pub const Stage = struct {
    /// NULL-terminated argv for `execvp`; `argv[0]` must be non-null.
    argv: [*:null]const ?[*:0]const u8,
    /// Applied in order, after the pipe wiring, so a `>` on a non-final
    /// stage overrides its pipe (matching bash).
    redirs: []const Redir = &.{},
};

pub const Options = struct {
    /// The fd handed to stage 0 as stdin when it has no `<` redirect.
    /// `-1` -> a pipe is created and its write end returned as `stdin_w`.
    stage0_stdin: i32 = -1,
};

pub const Spawned = if (builtin.os.tag == .linux) SpawnedLinux else SpawnedStub;

const SpawnedStub = struct {
    pids: []i32 = &.{},
    pgid: i32 = -1,
    stdin_w: i32 = -1,
    stdout_r: i32 = -1,
    stderr_r: i32 = -1,
    exit_code: u8 = 0,

    pub fn signal(_: *SpawnedStub, _: std.posix.SIG) void {}
    pub fn reapAll(_: *SpawnedStub) bool {
        return true;
    }
    pub fn wait(_: *SpawnedStub) u8 {
        return 0;
    }
    pub fn deinit(_: *SpawnedStub, _: std.mem.Allocator) void {}
};

pub fn spawn(alloc: std.mem.Allocator, stages: []const Stage, opts: Options) SpawnError!Spawned {
    if (builtin.os.tag != .linux) return error.Unsupported;
    return spawnLinux(alloc, stages, opts);
}

// --- Linux implementation ------------------------------------------------

const c = std.c;

extern "c" fn pipe2(fds: *[2]i32, flags: i32) i32;
extern "c" fn fork() c.pid_t;
extern "c" fn setpgid(pid: c.pid_t, pgid: c.pid_t) i32;
extern "c" fn execvp(file: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) i32;
extern "c" fn open(path: [*:0]const u8, flags: i32, mode: c_uint) i32;

// <asm-generic/fcntl.h> -- the generic values, correct for every Linux
// target glyphwire builds for (x86_64 / aarch64 / riscv64).
const O_RDONLY: i32 = 0o0;
const O_WRONLY: i32 = 0o1;
const O_CREAT: i32 = 0o100;
const O_TRUNC: i32 = 0o1000;
const O_APPEND: i32 = 0o2000;
const WNOHANG: i32 = 1;

/// `waitpid` status word -> the number shells use for `$?`: the exit code
/// for a normal exit, `128 + signal` for a signalled death. Same decode
/// as `pty.zig` (the macros aren't in this reduced `std.c`).
fn decodeWaitStatus(status: i32) u8 {
    const s: u32 = @bitCast(status);
    const term_sig = s & 0x7f;
    if (term_sig == 0) return @intCast((s >> 8) & 0xff);
    if (term_sig != 0x7f) return @intCast(128 +| term_sig);
    return 0;
}

const SpawnedLinux = struct {
    /// One pid per stage; an entry is zeroed once that stage is reaped.
    pids: []i32,
    pgid: i32,
    stdin_w: i32,
    stdout_r: i32,
    stderr_r: i32,
    /// The last stage's status, valid once it has been reaped.
    exit_code: u8 = 0,

    /// Sends `sig` to the whole pipeline (negative-pid `kill`), so every
    /// stage goes down together -- Ctrl-C, or the `deinit` backstop.
    pub fn signal(self: *SpawnedLinux, sig: std.posix.SIG) void {
        if (self.pgid <= 1) return;
        var any = false;
        for (self.pids) |p| {
            if (p != 0) any = true;
        }
        if (any) std.posix.kill(-self.pgid, sig) catch {};
    }

    /// Non-blocking: reaps whatever stages have exited (WNOHANG). Returns
    /// true once every stage is reaped. Records the last stage's status
    /// into `exit_code` when that one is reaped.
    pub fn reapAll(self: *SpawnedLinux) bool {
        const last = self.pids.len - 1;
        var all = true;
        for (self.pids, 0..) |p, i| {
            if (p == 0) continue;
            var st: i32 = undefined;
            if (c.waitpid(p, &st, WNOHANG) == p) {
                if (i == last) self.exit_code = decodeWaitStatus(st);
                self.pids[i] = 0;
            } else all = false;
        }
        return all;
    }

    /// Blocks until every stage is reaped. Returns the last stage's
    /// status. The error-path / teardown counterpart of `reapAll`.
    pub fn wait(self: *SpawnedLinux) u8 {
        const last = self.pids.len - 1;
        for (self.pids, 0..) |p, i| {
            if (p == 0) continue;
            var st: i32 = undefined;
            while (c.waitpid(p, &st, 0) < 0) {}
            if (i == last) self.exit_code = decodeWaitStatus(st);
            self.pids[i] = 0;
        }
        return self.exit_code;
    }

    /// Kills anything still running, reaps it, closes every still-open fd,
    /// and frees `pids`.
    pub fn deinit(self: *SpawnedLinux, alloc: std.mem.Allocator) void {
        self.signal(std.posix.SIG.KILL);
        _ = self.wait();
        for ([_]i32{ self.stdin_w, self.stdout_r, self.stderr_r }) |fd| {
            if (fd >= 0) _ = c.close(fd);
        }
        alloc.free(self.pids);
    }
};

/// Writes a C string to `fd`, best-effort. Async-signal-safe: only used
/// on the child's exec-failure path.
fn writeStr(fd: i32, s: []const u8) void {
    var off: usize = 0;
    while (off < s.len) {
        const n = c.write(fd, s.ptr + off, s.len - off);
        if (n <= 0) return;
        off += @intCast(n);
    }
}

fn cStrLen(p: [*:0]const u8) usize {
    var i: usize = 0;
    while (p[i] != 0) : (i += 1) {}
    return i;
}

fn spawnLinux(alloc: std.mem.Allocator, stages: []const Stage, opts: Options) SpawnError!Spawned {
    std.debug.assert(stages.len >= 1);
    const n = stages.len;

    // Inter-stage pipes: pipes[i] connects stage i's stdout to stage
    // i+1's stdin.
    const pipes = try alloc.alloc([2]i32, n - 1);
    defer alloc.free(pipes);
    for (pipes) |*p| p.* = .{ -1, -1 };

    var stderr_p: [2]i32 = .{ -1, -1 };
    var stdout_p: [2]i32 = .{ -1, -1 };
    var stdin_p: [2]i32 = .{ -1, -1 };
    const make_stdin_pipe = opts.stage0_stdin < 0;

    // Close every pipe fd this function opened. Safe to call at any point
    // -- unset ends are -1.
    const closeAll = struct {
        fn f(ps: [][2]i32, se: [2]i32, so: [2]i32, si: [2]i32) void {
            for (ps) |p| {
                if (p[0] >= 0) _ = c.close(p[0]);
                if (p[1] >= 0) _ = c.close(p[1]);
            }
            for ([_]i32{ se[0], se[1], so[0], so[1], si[0], si[1] }) |fd| {
                if (fd >= 0) _ = c.close(fd);
            }
        }
    }.f;
    errdefer closeAll(pipes, stderr_p, stdout_p, stdin_p);

    for (pipes) |*p| {
        if (pipe2(p, 0) != 0) return error.PipeFailed;
    }
    if (pipe2(&stderr_p, 0) != 0) return error.PipeFailed;
    if (pipe2(&stdout_p, 0) != 0) return error.PipeFailed;
    if (make_stdin_pipe and pipe2(&stdin_p, 0) != 0) return error.PipeFailed;

    const pids = try alloc.alloc(i32, n);
    errdefer alloc.free(pids);
    @memset(pids, 0);

    var pgid: c.pid_t = 0;

    for (stages, 0..) |stage, i| {
        const pid = fork();
        if (pid < 0) {
            // Tear down whatever already started.
            if (pgid != 0) {
                std.posix.kill(-pgid, std.posix.SIG.KILL) catch {};
                for (pids) |p| {
                    if (p != 0) {
                        var st: i32 = undefined;
                        while (c.waitpid(p, &st, 0) < 0) {}
                    }
                }
            }
            return error.ForkFailed;
        }

        if (pid == 0) {
            // --- child: only async-signal-safe libc calls until exec ---
            _ = setpgid(0, pgid); // i == 0 -> pgid 0 -> lead a new group

            const in_fd: i32 = if (i == 0)
                (if (make_stdin_pipe) stdin_p[0] else opts.stage0_stdin)
            else
                pipes[i - 1][0];
            const out_fd: i32 = if (i == n - 1) stdout_p[1] else pipes[i][1];

            _ = c.dup2(in_fd, 0);
            _ = c.dup2(out_fd, 1);
            _ = c.dup2(stderr_p[1], 2);

            // Drop every original pipe fd (all are >= 3 -- 0/1/2 are the
            // shell's own stdio); the dup'd 0/1/2 stay.
            for (pipes) |p| {
                if (p[0] > 2) _ = c.close(p[0]);
                if (p[1] > 2) _ = c.close(p[1]);
            }
            for ([_]i32{ stderr_p[0], stderr_p[1], stdout_p[0], stdout_p[1], stdin_p[0], stdin_p[1] }) |fd| {
                if (fd > 2) _ = c.close(fd);
            }
            if (opts.stage0_stdin > 2) _ = c.close(opts.stage0_stdin);

            for (stage.redirs) |r| applyRedir(r);

            _ = execvp(stage.argv[0].?, stage.argv);
            // execvp only returns on failure.
            writeStr(2, stage.argv[0].?[0..cStrLen(stage.argv[0].?)]);
            writeStr(2, ": command not found\n");
            c._exit(127);
        }

        // --- parent ---
        pids[i] = pid;
        if (i == 0) pgid = pid;
        _ = setpgid(pid, pgid); // race-free: also done in the child
    }

    // Parent keeps only the three ends it pumps.
    for (pipes) |p| {
        if (p[0] >= 0) _ = c.close(p[0]);
        if (p[1] >= 0) _ = c.close(p[1]);
    }
    _ = c.close(stderr_p[1]);
    _ = c.close(stdout_p[1]);
    if (make_stdin_pipe) _ = c.close(stdin_p[0]);

    return .{
        .pids = pids,
        .pgid = pgid,
        .stdin_w = if (make_stdin_pipe) stdin_p[1] else -1,
        .stdout_r = stdout_p[0],
        .stderr_r = stderr_p[0],
    };
}

/// Applies one redirect in the freshly forked child. On an `open`
/// failure it reports onto fd 2 (the stderr pipe -> the grid) and exits
/// 127, matching a "command not found".
fn applyRedir(r: Redir) void {
    switch (r.mode) {
        .dup => {
            _ = c.dup2(r.dup_fd, r.fd);
            return;
        },
        .read, .write, .append => {},
    }
    const path = r.path orelse c._exit(127);
    const flags: i32 = switch (r.mode) {
        .read => O_RDONLY,
        .write => O_WRONLY | O_CREAT | O_TRUNC,
        .append => O_WRONLY | O_CREAT | O_APPEND,
        .dup => unreachable,
    };
    const fd = open(path, flags, 0o644);
    if (fd < 0) {
        writeStr(2, path[0..cStrLen(path)]);
        writeStr(2, if (r.mode == .read) ": cannot open\n" else ": cannot create\n");
        c._exit(127);
    }
    _ = c.dup2(fd, r.fd);
    if (fd > 2) _ = c.close(fd);
    // `&>` / `&>>`: stderr follows the file we just put on fd 1.
    if (r.also_stderr and r.fd == 1) _ = c.dup2(1, 2);
}
