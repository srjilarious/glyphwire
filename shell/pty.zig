//! B0 "dumb PTY" support for glyphwire-shell: allocate a
//! pseudo-terminal, run a command with the slave as its controlling
//! terminal, and expose the master fd for a read loop (master -> grid,
//! `shell/main.zig`'s `ptyReaderThread`) and keystroke injection
//! (`keyencode.toPtyBytes` -> `Pty.writeAll`).
//!
//! The point is not VT emulation -- `core.Layer` already interprets SGR
//! colour + simple cursor/erase (Phase A). It's that a child on a real
//! tty **line-buffers stdout** instead of block-buffering it into a pipe
//! (so output appears as it happens, not at exit), `isatty()` is true (so
//! `ls`/`grep`/`git` auto-colour and show progress), stdin actually
//! works, and Ctrl-C reaches the child as a real SIGINT via the tty line
//! discipline. Full-screen apps (`vim`, `htop`, `less`'s alternate
//! screen) still need more -- see `docs/investigations/
//! libghostty-vt-fallback.md` §7a, tiers B1/B2.
//!
//! Linux only (like `file_watcher.zig`). Everything goes through libc,
//! which glyphwire-shell already links for Lua -- this reduced-`std.posix`
//! Zig has no `fork`/`dup2`/`execvp`/`ioctl`/`waitpid`.

const std = @import("std");
const c = std.c;

// <asm-generic/ioctls.h>
const TIOCSCTTY: c_int = 0x540E;
const TIOCSWINSZ: c_int = 0x5414;

/// `struct winsize` from <termios.h>. Pixel fields stay 0 -- glyphwire is
/// a cell grid.
const Winsize = extern struct {
    row: u16,
    col: u16,
    xpixel: u16 = 0,
    ypixel: u16 = 0,
};

// libutil, folded into libc on glibc >= 2.34 (no `-lutil` needed).
extern "c" fn openpty(
    amaster: *c_int,
    aslave: *c_int,
    name: ?[*]u8,
    termp: ?*const anyopaque,
    winp: ?*const Winsize,
) c_int;

// PATH-searching exec: `PATH` already has `<cwd>/zig-out/bin` prepended
// (shell startup) and libc's `execvp` reads it from the live environment.
extern "c" fn execvp(file: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;

// A close-on-exec pipe carries the child's exec success/failure back to
// the parent: a successful `execvp` closes the write end (EOF for the
// parent's read), a failed one writes a byte first. Standard fork/exec
// idiom -- without it, `execvp` failing inside the child is invisible to
// the parent (it just sees a child that exited 127).
extern "c" fn pipe2(fds: *[2]c_int, flags: c_int) c_int;
const O_CLOEXEC: c_int = 0o2000000; // Linux

pub const SpawnError = error{ OpenptyFailed, PipeFailed, ForkFailed, CommandNotFound };

/// Turns a `waitpid` status word into a single number: the exit code for
/// a normal `exit()` (`WIFEXITED` -> `WEXITSTATUS`), or `128 + signal`
/// for a signalled death (`WIFSIGNALED` -> `WTERMSIG`), matching the
/// convention shells use for `$?`. The macros aren't in this reduced
/// `std.c`, so the bit math is inline: low 7 bits zero = exited (code in
/// bits 8..15); low 7 bits in `1..0x7e` = killed by that signal.
fn decodeWaitStatus(status: c_int) u8 {
    const s: u32 = @bitCast(status);
    const term_sig = s & 0x7f;
    if (term_sig == 0) return @intCast((s >> 8) & 0xff);
    if (term_sig != 0x7f) return @intCast(128 +| term_sig);
    return 0; // 0x7f = stopped; not expected with our waitpid flags
}

pub const Pty = struct {
    master: c.fd_t,
    pid: c.pid_t,
    /// The child's exit status once it's been reaped (by `reaped` or
    /// `wait`): the exit code for a normal exit, `128 + signal` for a
    /// signalled death, `0` before either has reaped it. `shell/main.zig`
    /// reads this for the prompt's `{exit}` token.
    exit_code: u8 = 0,

    /// Allocates a pty, forks, and in the child: starts a new session,
    /// makes the slave its controlling terminal, wires the slave to
    /// stdin/stdout/stderr, and `execvp`s `argv`. The parent keeps the
    /// master fd and the child pid.
    ///
    /// `argv` is a NULL-terminated array of NUL-terminated C strings
    /// (`argv[0]` must be non-null). The child path between `fork` and
    /// `execvp` calls only async-signal-safe libc functions -- the usual
    /// fork/exec caveat for a process with other live threads (the
    /// `InputListener` runs one).
    pub fn spawn(argv: [*:null]const ?[*:0]const u8, cols: u16, rows: u16) SpawnError!Pty {
        var master: c_int = undefined;
        var slave: c_int = undefined;
        const ws = Winsize{ .row = rows, .col = cols };
        if (openpty(&master, &slave, null, null, &ws) != 0) return error.OpenptyFailed;

        var efd: [2]c_int = undefined; // exec-status pipe: [read, write]
        if (pipe2(&efd, O_CLOEXEC) != 0) {
            _ = c.close(master);
            _ = c.close(slave);
            return error.PipeFailed;
        }

        const pid = c.fork();
        if (pid < 0) {
            _ = c.close(master);
            _ = c.close(slave);
            _ = c.close(efd[0]);
            _ = c.close(efd[1]);
            return error.ForkFailed;
        }

        if (pid == 0) {
            // --- child --- (only async-signal-safe libc calls until exec)
            _ = c.close(efd[0]);
            _ = c.setsid();
            _ = c.ioctl(slave, TIOCSCTTY, @as(c_int, 0));
            _ = c.dup2(slave, 0);
            _ = c.dup2(slave, 1);
            _ = c.dup2(slave, 2);
            if (slave > 2) _ = c.close(slave);
            _ = c.close(master);
            _ = execvp(argv[0].?, argv);
            // execvp only returns on failure: tell the parent, then exit.
            var fail = [1]u8{1};
            _ = c.write(efd[1], &fail, 1);
            c._exit(127);
        }

        // --- parent ---
        _ = c.close(slave);
        _ = c.close(efd[1]);
        // Blocks (briefly) until the child either execs -- O_CLOEXEC
        // closes its `efd[1]`, so this reads EOF (0) -- or fails to exec
        // and writes a byte first (1).
        var got = [1]u8{0};
        const n = c.read(efd[0], &got, 1);
        _ = c.close(efd[0]);
        if (n == 1) {
            var status: c_int = undefined;
            _ = c.waitpid(pid, &status, 0); // reap the 127 exit
            _ = c.close(master);
            return error.CommandNotFound;
        }

        return .{ .master = master, .pid = pid };
    }

    /// Tells the kernel line discipline the terminal's new size; the
    /// child gets a SIGWINCH. Best-effort.
    pub fn resize(self: Pty, cols: u16, rows: u16) void {
        const ws = Winsize{ .row = rows, .col = cols };
        _ = c.ioctl(self.master, TIOCSWINSZ, &ws);
    }

    /// Writes every byte of `bytes` to the master (the child's stdin).
    /// Best-effort: a short/failed write once the child is gone is
    /// dropped -- there's nothing to recover.
    pub fn writeAll(self: Pty, bytes: []const u8) void {
        var off: usize = 0;
        while (off < bytes.len) {
            const n = c.write(self.master, bytes.ptr + off, bytes.len - off);
            if (n <= 0) return;
            off += @intCast(n);
        }
    }

    /// Non-blocking reap. True once the child has exited *and* been
    /// reaped (no zombie left); false while it's still running. On the
    /// reaping call it decodes the wait status into `exit_code`.
    pub fn reaped(self: *Pty) bool {
        var status: c_int = undefined;
        if (c.waitpid(self.pid, &status, 1) != self.pid) return false; // WNOHANG
        self.exit_code = decodeWaitStatus(status);
        return true;
    }

    /// Sends `sig` to the child's process group (negative pid), so a
    /// whole pipeline started under the pty goes down together.
    pub fn signalGroup(self: Pty, sig: std.posix.SIG) void {
        std.posix.kill(-self.pid, sig) catch {};
    }

    /// Blocks until the child is reaped -- the error-path counterpart of
    /// `reaped`, for when the caller can't spin. Decodes the wait status
    /// into `exit_code`, same as `reaped`.
    pub fn wait(self: *Pty) void {
        var status: c_int = undefined;
        while (c.waitpid(self.pid, &status, 0) < 0) {}
        self.exit_code = decodeWaitStatus(status);
    }

    /// Closes the master. Call after the child has been reaped.
    pub fn deinit(self: Pty) void {
        _ = c.close(self.master);
    }
};
