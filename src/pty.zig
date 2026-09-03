//! Shared pty support: `Pty` allocates a pseudo-terminal, runs a command
//! with the slave as its controlling terminal, and exposes the master fd
//! for a read loop (master -> grid, `shell/main.zig`'s `ptyReaderThread`)
//! and keystroke injection (`key_encode.toPtyBytes` -> `Pty.writeAll`).
//! `ModeTracker` sniffs the master byte stream for the handful of DEC
//! private modes the input path has to honour (application cursor keys,
//! bracketed paste, mouse reporting) so the key/mouse encoder can match
//! what the child asked for -- no wire round trip.
//!
//! Was `shell/pty.zig`; moved here so more than glyphwire-shell can reach
//! it. The `Pty` half is Linux-only (libc `openpty`/`fork`/`execvp`/
//! `ioctl`/`waitpid` -- this reduced-`std.posix` Zig has none of them);
//! other platforms get a stub whose `spawn` returns `error.Unsupported`,
//! the same degrade-off-Linux shape `file_watcher.zig` uses. `ModeTracker`
//! is pure and platform-independent.
//!
//! The point of the pty is not VT emulation -- `core.Layer` already
//! interprets SGR colour + simple cursor/erase (Phase A). It's that a
//! child on a real tty **line-buffers stdout** instead of block-buffering
//! it into a pipe (so output appears as it happens, not at exit),
//! `isatty()` is true (so `ls`/`grep`/`git` auto-colour and show
//! progress), stdin actually works, and Ctrl-C reaches the child as a
//! real SIGINT via the tty line discipline. Full-screen apps (`vim`,
//! `htop`, `less`'s alternate screen) still need more -- see
//! `docs/investigations/libghostty-vt-fallback.md` §7a, tiers B1/B2.

const std = @import("std");
const builtin = @import("builtin");
const c = std.c;

pub const SpawnError = error{ OpenptyFailed, PipeFailed, ForkFailed, CommandNotFound, Unsupported };

/// The real pty on Linux; a stub returning `error.Unsupported` from
/// `spawn` everywhere else. Callers only ever name `Pty`.
pub const Pty = if (builtin.os.tag == .linux) PtyLinux else PtyStub;

const PtyStub = struct {
    master: c.fd_t = -1,
    pid: c.pid_t = -1,
    exit_code: u8 = 0,

    pub fn spawn(_: [*:null]const ?[*:0]const u8, _: u16, _: u16) SpawnError!PtyStub {
        return error.Unsupported;
    }
    pub fn resize(_: PtyStub, _: u16, _: u16) void {}
    pub fn writeAll(_: PtyStub, _: []const u8) void {}
    pub fn reaped(_: *PtyStub) bool {
        return true;
    }
    pub fn signalGroup(_: PtyStub, _: std.posix.SIG) void {}
    pub fn wait(_: *PtyStub) void {}
    pub fn deinit(_: PtyStub) void {}
};

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

const PtyLinux = struct {
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
    pub fn spawn(argv: [*:null]const ?[*:0]const u8, cols: u16, rows: u16) SpawnError!PtyLinux {
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
    pub fn resize(self: PtyLinux, cols: u16, rows: u16) void {
        const ws = Winsize{ .row = rows, .col = cols };
        _ = c.ioctl(self.master, TIOCSWINSZ, &ws);
    }

    /// Writes every byte of `bytes` to the master (the child's stdin).
    /// Best-effort: a short/failed write once the child is gone is
    /// dropped -- there's nothing to recover.
    pub fn writeAll(self: PtyLinux, bytes: []const u8) void {
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
    pub fn reaped(self: *PtyLinux) bool {
        var status: c_int = undefined;
        if (c.waitpid(self.pid, &status, 1) != self.pid) return false; // WNOHANG
        self.exit_code = decodeWaitStatus(status);
        return true;
    }

    /// Sends `sig` to the child's process group (negative pid), so a
    /// whole pipeline started under the pty goes down together.
    pub fn signalGroup(self: PtyLinux, sig: std.posix.SIG) void {
        std.posix.kill(-self.pid, sig) catch {};
    }

    /// Blocks until the child is reaped -- the error-path counterpart of
    /// `reaped`, for when the caller can't spin. Decodes the wait status
    /// into `exit_code`, same as `reaped`.
    pub fn wait(self: *PtyLinux) void {
        var status: c_int = undefined;
        while (c.waitpid(self.pid, &status, 0) < 0) {}
        self.exit_code = decodeWaitStatus(status);
    }

    /// Closes the master. Call after the child has been reaped.
    pub fn deinit(self: PtyLinux) void {
        _ = c.close(self.master);
    }
};

/// Sniffs a pty master byte stream for the DEC private modes the input
/// path has to honour, so `shell/main.zig`'s foreground key loop can
/// encode keys and mouse events the way the running child asked for
/// without a wire round trip. Only `ESC [ ? <params> h` (set) and
/// `... l` (reset) are recognized; every other escape is skipped. The
/// small parser state persists across `feed` calls, so a sequence split
/// across two master reads is still caught.
///
/// The setters run on the reader thread and the getters on the
/// foreground loop, so each mode is an atomic bool -- a torn read just
/// means one keystroke encoded against the previous mode, self-correcting
/// on the next.
pub const ModeTracker = struct {
    /// DECCKM (`?1`): arrows and Home/End are sent as `ESC O x` (SS3)
    /// instead of `ESC [ x` while set.
    app_cursor: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// Bracketed paste (`?2004`): pasted text is wrapped in
    /// `ESC [ 200 ~` ... `ESC [ 201 ~` while set.
    bracketed_paste: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// `?1000` -- report button press/release.
    mouse_button: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// `?1002` -- also report motion while a button is held.
    mouse_drag: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// `?1003` -- report all pointer motion.
    mouse_any: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// `?1006` -- SGR-form reports (`ESC [ < b ; x ; y M|m`) instead of
    /// the legacy `ESC [ M` byte triples.
    mouse_sgr: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    state: enum { ground, esc, csi } = .ground,
    /// Parameter/intermediate bytes of the CSI being parsed. 32 is plenty
    /// for `?1000;1002;1003;1006`; a longer run just stops matching.
    params: [32]u8 = undefined,
    params_len: usize = 0,

    pub fn feed(self: *ModeTracker, bytes: []const u8) void {
        for (bytes) |b| self.step(b);
    }

    fn step(self: *ModeTracker, b: u8) void {
        switch (self.state) {
            .ground => if (b == 0x1b) {
                self.state = .esc;
            },
            .esc => switch (b) {
                '[' => {
                    self.state = .csi;
                    self.params_len = 0;
                },
                0x1b => {}, // ESC ESC -- stay armed
                else => self.state = .ground, // short 2-byte escape
            },
            .csi => {
                if (b >= 0x40 and b <= 0x7e) {
                    if (b == 'h' or b == 'l') self.applyPrivateMode(b == 'h');
                    self.state = .ground;
                    self.params_len = 0;
                } else if (self.params_len < self.params.len) {
                    self.params[self.params_len] = b;
                    self.params_len += 1;
                }
            },
        }
    }

    /// `params` is `? n ; n ; ...` for a private-mode set/reset. Split on
    /// `;`, apply each recognized number; ignore anything not a private
    /// (`?`-led) sequence and any mode we don't model.
    fn applyPrivateMode(self: *ModeTracker, set: bool) void {
        const p = self.params[0..self.params_len];
        if (p.len == 0 or p[0] != '?') return;
        var it = std.mem.splitScalar(u8, p[1..], ';');
        while (it.next()) |tok| {
            const n = std.fmt.parseInt(u32, tok, 10) catch continue;
            switch (n) {
                1 => self.app_cursor.store(set, .monotonic),
                2004 => self.bracketed_paste.store(set, .monotonic),
                1000 => self.mouse_button.store(set, .monotonic),
                1002 => self.mouse_drag.store(set, .monotonic),
                1003 => self.mouse_any.store(set, .monotonic),
                1006 => self.mouse_sgr.store(set, .monotonic),
                else => {},
            }
        }
    }

    pub fn appCursor(self: *const ModeTracker) bool {
        return self.app_cursor.load(.monotonic);
    }
    pub fn bracketedPaste(self: *const ModeTracker) bool {
        return self.bracketed_paste.load(.monotonic);
    }
    /// Any mouse-reporting mode is on -- button events should be encoded
    /// to the child.
    pub fn mouseReporting(self: *const ModeTracker) bool {
        return self.mouse_button.load(.monotonic) or
            self.mouse_drag.load(.monotonic) or
            self.mouse_any.load(.monotonic);
    }
    /// Motion events should be encoded: `?1002` (only meaningful with a
    /// button down -- the caller checks that) or `?1003`.
    pub fn wantsMotion(self: *const ModeTracker) bool {
        return self.mouse_drag.load(.monotonic) or self.mouse_any.load(.monotonic);
    }
    /// Report motion regardless of button state (`?1003`).
    pub fn wantsAnyMotion(self: *const ModeTracker) bool {
        return self.mouse_any.load(.monotonic);
    }
    pub fn sgrMouse(self: *const ModeTracker) bool {
        return self.mouse_sgr.load(.monotonic);
    }
};
