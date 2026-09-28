// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: GPL-3.0-or-later

//! What gw-shell keeps of a glyphwire-aware child's own output, so a
//! program that dies can still be diagnosed.
//!
//! A plain child's output is mirrored onto the shell's grid as it runs.
//! An aware child's is not: once the handshake resolves it draws over its
//! own wire connection, and whatever it still writes to its pty (a panic
//! message, a stack trace, `std.log` warnings) goes to the shell's real
//! stdout -- wherever the host was started from, usually nowhere anyone
//! is looking. A crashed zoe just vanished back to the prompt.
//!
//! So the pty reader also feeds that output into a `Tail`, and when the
//! child exits badly (`shouldReport`) the shell prints the tail into its
//! scrollback and writes it to a log file under `logDir`.
//!
//! Pure: no IO, no libc. The shell does the drawing and the file write.

const std = @import("std");

/// The last `capacity` bytes an aware child wrote to its pty. Enough for
/// a Zig panic with a deep stack trace plus whatever was logged before
/// it; older bytes fall off the front.
pub const Tail = struct {
    pub const capacity = 32 * 1024;

    buf: [capacity]u8 = undefined,
    /// Index of the oldest byte once the buffer has wrapped.
    start: usize = 0,
    len: usize = 0,

    pub fn append(self: *Tail, bytes: []const u8) void {
        // Only the last `capacity` bytes of an oversized write can survive.
        const src = if (bytes.len > capacity) bytes[bytes.len - capacity ..] else bytes;
        for (src) |b| {
            const end = (self.start + self.len) % capacity;
            self.buf[end] = b;
            if (self.len < capacity) {
                self.len += 1;
            } else {
                self.start = (self.start + 1) % capacity;
            }
        }
    }

    /// The kept bytes in order, copied into `out` (at least `capacity`
    /// long). Returns the filled prefix.
    pub fn contents(self: *const Tail, out: []u8) []u8 {
        std.debug.assert(out.len >= self.len);
        const first = @min(self.len, capacity - self.start);
        @memcpy(out[0..first], self.buf[self.start..][0..first]);
        @memcpy(out[first..self.len], self.buf[0 .. self.len - first]);
        return out[0..self.len];
    }
};

/// How a child ended, from its wait status.
pub const Exit = union(enum) {
    /// `exit(code)`.
    code: u8,
    /// Killed by this signal number.
    signal: u8,
};

/// Signals that mean the program itself went wrong, as opposed to
/// something outside asking it to stop (SIGINT, SIGTERM, SIGHUP, SIGKILL
/// and friends). Linux numbering.
fn isCrashSignal(sig: u8) bool {
    return switch (sig) {
        4, // SIGILL -- also how a ReleaseSafe build reports a C UBSan trap
        5, // SIGTRAP
        6, // SIGABRT -- Zig's panic handler ends here
        7, // SIGBUS
        8, // SIGFPE
        11, // SIGSEGV
        31, // SIGSYS
        => true,
        else => false,
    };
}

/// Whether an aware child's exit deserves a crash report. A crash signal
/// always does, even with nothing captured. A nonzero exit does only when
/// the child left output behind (Zig's `error: X` and its return trace,
/// or a program's own message before `exit(1)`): a quiet nonzero exit is
/// just a status, and `{exit}` already shows it. A signal from outside is
/// someone stopping the program on purpose.
pub fn shouldReport(exit: Exit, captured_len: usize) bool {
    return switch (exit) {
        .signal => |s| isCrashSignal(s),
        .code => |c| c != 0 and captured_len > 0,
    };
}

fn signalName(sig: u8) ?[]const u8 {
    return switch (sig) {
        4 => "SIGILL",
        5 => "SIGTRAP",
        6 => "SIGABRT",
        7 => "SIGBUS",
        8 => "SIGFPE",
        11 => "SIGSEGV",
        31 => "SIGSYS",
        else => null,
    };
}

/// One line saying how `program` ended, e.g. `zoe crashed (SIGILL)` or
/// `gw-read exited with status 1`.
pub fn describe(buf: []u8, program: []const u8, exit: Exit) []const u8 {
    return switch (exit) {
        .signal => |s| if (signalName(s)) |name|
            std.fmt.bufPrint(buf, "{s} crashed ({s})", .{ program, name }) catch program
        else
            std.fmt.bufPrint(buf, "{s} was killed by signal {d}", .{ program, s }) catch program,
        .code => |c| std.fmt.bufPrint(buf, "{s} exited with status {d}", .{ program, c }) catch program,
    };
}

/// The trailing `max_lines` lines of `text` (a final newline doesn't
/// count as starting an empty line). The scrollback gets this much; the
/// log file gets everything.
pub fn lastLines(text: []const u8, max_lines: usize) []const u8 {
    if (max_lines == 0) return text[text.len..];
    const body = std.mem.trimEnd(u8, text, "\n");
    var seen: usize = 0;
    var i = body.len;
    while (i > 0) {
        i -= 1;
        if (body[i] == '\n') {
            seen += 1;
            if (seen == max_lines) return text[i + 1 ..];
        }
    }
    return text;
}

/// Copies `text` into `out` without its ANSI escape sequences (CSI, OSC,
/// charset designations and two-byte `ESC x`) and carriage returns: a
/// panic written to a pty is coloured, and a log file should read cleanly
/// in any editor.
/// `out` must be at least `text.len` long.
pub fn stripAnsi(text: []const u8, out: []u8) []u8 {
    var n: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        const b = text[i];
        if (b == '\r') {
            i += 1;
            continue;
        }
        if (b != 0x1b) {
            out[n] = b;
            n += 1;
            i += 1;
            continue;
        }
        i += 1;
        if (i >= text.len) break;
        switch (text[i]) {
            '[' => {
                // CSI: parameters and intermediates up to a final byte in @..~.
                i += 1;
                while (i < text.len and !(text[i] >= 0x40 and text[i] <= 0x7e)) i += 1;
                i += 1;
            },
            ']' => {
                // OSC: up to BEL or ST (`ESC \`).
                i += 1;
                while (i < text.len) : (i += 1) {
                    if (text[i] == 0x07) {
                        i += 1;
                        break;
                    }
                    if (text[i] == 0x1b and i + 1 < text.len and text[i + 1] == '\\') {
                        i += 2;
                        break;
                    }
                }
            },
            // Charset designation (`ESC ( B`): one more byte names the set.
            '(', ')', '*', '+' => i += 2,
            else => i += 1,
        }
    }
    return out[0..n];
}

/// Where crash logs go: `$XDG_STATE_HOME/glyphwire/crashes`, else
/// `$HOME/.local/state/glyphwire/crashes`. Null with neither set.
pub fn logDir(alloc: std.mem.Allocator, environ: *const std.process.Environ.Map) !?[]u8 {
    if (environ.get("XDG_STATE_HOME")) |xdg| {
        if (xdg.len > 0) return try std.fs.path.join(alloc, &.{ xdg, "glyphwire", "crashes" });
    }
    const home = environ.get("HOME") orelse return null;
    return try std.fs.path.join(alloc, &.{ home, ".local", "state", "glyphwire", "crashes" });
}

/// The log file's name: the program's basename, a sortable local
/// timestamp (`stamp`, e.g. `20260927-221530`) and the pid, so two
/// crashes in the same second never share a file.
pub fn logName(buf: []u8, program: []const u8, stamp: []const u8, pid: i32) []const u8 {
    const base = std.fs.path.basename(program);
    return std.fmt.bufPrint(buf, "{s}-{s}-{d}.log", .{ base, stamp, pid }) catch "crash.log";
}
