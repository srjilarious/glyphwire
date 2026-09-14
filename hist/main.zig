// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: GPL-3.0-or-later

//! gw-hist: Ctrl+R-style fuzzy history search for glyphwire-shell.
//!
//! Deliberately a *plain* terminal program, not a glyphwire-aware one --
//! no wire connection, no `core.Layer`. It takes over the primary screen
//! the way `vim`/`less` do (`CSI ?1049h`, restored with `?1049l`), reads
//! `~/.config/glyphwire/history` directly, and lets the user fuzzy-filter
//! it live (`shell_support.fuzzy`). This works because `glyphwire-shell`
//! always runs a foreground child on a real pty (`src/pty.zig`), so
//! `stdin`/`stdout` here are a real controlling terminal and raw-mode
//! `termios` behaves exactly as it would for any other full-screen
//! program -- the shell's own foreground loop just forwards keystrokes
//! into the pty and mirrors output back out, the same as it does for
//! `vim` or `htop` (see `shell/main.zig`'s `runCommand`).
//!
//! On Enter, the selected line is written to `$GLYPHWIRE_RESULT_FD` --
//! the shell opens this pipe before spawning every foreground command
//! (see `shell/main.zig`'s `result_fd_env`) so any program, not just this
//! one, can hand a value back to become the next prompt line. That's the
//! generic half of this feature; `gw-hist` is just its first user. Esc /
//! Ctrl+C exit without writing anything, leaving the shell's current
//! line untouched. Run without that env var set (e.g. testing by hand
//! from a real terminal), the pick goes to stdout instead once the
//! terminal is restored.
//!
//! Known limitations, left for later: no live `SIGWINCH` handling (the
//! terminal size is read once at startup), and the query editor is
//! byte-level rather than UTF-8-aware (Backspace over a multi-byte
//! character removes one byte, not one codepoint) -- acceptable for
//! command lines, which are overwhelmingly ASCII.

const std = @import("std");
const glyphwire = @import("glyphwire");
const history = @import("shell_support").history;
const fuzzy = @import("shell_support").fuzzy;

const c = struct {
    extern "c" fn read(fd: c_int, buf: [*]u8, n: usize) isize;
    extern "c" fn write(fd: c_int, buf: [*]const u8, n: usize) isize;
    extern "c" fn close(fd: c_int) c_int;
};

// <asm-generic/ioctls.h> -- same value `src/pty.zig` uses for the set
// side (`TIOCSWINSZ`); this is the get side, one less.
const TIOCGWINSZ: c_int = 0x5413;

fn writeAll(fd: c_int, bytes: []const u8) void {
    var off: usize = 0;
    while (off < bytes.len) {
        const n = c.write(fd, bytes.ptr + off, bytes.len - off);
        if (n <= 0) return;
        off += @intCast(n);
    }
}

pub fn main(init: std.process.Init) !void {
    const alloc = init.gpa;
    const io = init.io;

    const entries = loadHistory(alloc, io, init.environ_map) catch &.{};
    defer if (entries.len > 0) history.freeEntries(alloc, @constCast(entries));

    var ws: std.posix.winsize = .{ .row = 24, .col = 80, .xpixel = 0, .ypixel = 0 };
    _ = std.c.ioctl(0, TIOCGWINSZ, &ws);
    const rows: usize = @max(ws.row, 4);
    const cols: usize = @max(ws.col, 20);

    const orig_termios = std.posix.tcgetattr(0) catch {
        // Not actually a tty (piped stdin, a test harness): nothing this
        // program does makes sense without one.
        return;
    };
    var raw = orig_termios;
    raw.iflag.BRKINT = false;
    raw.iflag.ICRNL = false;
    raw.iflag.INPCK = false;
    raw.iflag.ISTRIP = false;
    raw.iflag.IXON = false;
    raw.oflag.OPOST = false;
    raw.lflag.ECHO = false;
    raw.lflag.ICANON = false;
    raw.lflag.IEXTEN = false;
    raw.lflag.ISIG = false;
    raw.cc[@intFromEnum(std.posix.V.MIN)] = 1;
    raw.cc[@intFromEnum(std.posix.V.TIME)] = 0;
    try std.posix.tcsetattr(0, .FLUSH, raw);
    defer std.posix.tcsetattr(0, .FLUSH, orig_termios) catch {};

    writeAll(1, "\x1b[?1049h");
    defer writeAll(1, "\x1b[?1049l");

    const picked = try runPicker(alloc, entries, rows, cols);
    defer if (picked) |p| alloc.free(p);

    const result_fd = resultFd(init.environ_map);
    if (picked) |p| {
        const out_fd = result_fd orelse 1;
        // Restore the terminal / leave the alt screen (the `defer`s
        // above) before this returns, so a `result_fd`-less manual run
        // prints to a normal, cooked stdout.
        _ = c.write(out_fd, p.ptr, p.len);
        if (result_fd) |fd| _ = c.close(fd);
    }
}

fn resultFd(environ_map: *const std.process.Environ.Map) ?c_int {
    const s = environ_map.get("GLYPHWIRE_RESULT_FD") orelse return null;
    return std.fmt.parseInt(c_int, s, 10) catch null;
}

fn loadHistory(alloc: std.mem.Allocator, io: std.Io, environ_map: *const std.process.Environ.Map) ![]const []const u8 {
    if (environ_map.get("GLYPHWIRE_NO_HISTORY")) |v| {
        if (v.len > 0) return &.{};
    }
    const config_dir = try glyphwire.configDirPath(alloc, environ_map);
    defer alloc.free(config_dir);
    const path = try std.fs.path.join(alloc, &.{ config_dir, "history" });
    defer alloc.free(path);

    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(8 << 20)) catch |err| switch (err) {
        error.FileNotFound => return &.{},
        else => return err,
    };
    defer alloc.free(bytes);
    return try history.parse(alloc, bytes);
}

fn writeAt(buf: *std.ArrayList(u8), alloc: std.mem.Allocator, row: usize, col: usize, text: []const u8) !void {
    try buf.print(alloc, "\x1b[{d};{d}H\x1b[K", .{ row, col });
    try buf.appendSlice(alloc, text);
}

/// Runs the picker loop until Enter (returns the owned selected line),
/// or Esc / Ctrl+C (returns `null`). `entries` is oldest-first, same
/// order `history.parse` returns; matches are shown newest-first so the
/// most recent match starts selected, same as a normal Ctrl+R recall.
fn runPicker(alloc: std.mem.Allocator, entries: []const []const u8, rows: usize, cols: usize) !?[]u8 {
    var query: std.ArrayList(u8) = .empty;
    defer query.deinit(alloc);

    var filtered: std.ArrayList([]const u8) = .empty;
    defer filtered.deinit(alloc);

    var selected: usize = 0;
    const list_rows = rows -| 2;

    var frame: std.ArrayList(u8) = .empty;
    defer frame.deinit(alloc);

    while (true) {
        try refilter(alloc, entries, query.items, &filtered);
        if (selected >= filtered.items.len) selected = filtered.items.len -| 1;

        frame.clearRetainingCapacity();
        try frame.appendSlice(alloc, "\x1b[H\x1b[J");
        try writeAt(&frame, alloc, 1, 1, "gw-hist -- fuzzy history search");
        try frame.print(alloc, "\x1b[2;1H\x1b[KSearch: {s}", .{query.items});
        try frame.print(alloc, "\x1b[3;1H\x1b[K{d} match(es) -- Enter picks, Esc/^C cancels, ^R/\x1b[7m\x1bOB\x1b[0m next", .{filtered.items.len});

        var row: usize = 5;
        var shown: usize = 0;
        for (filtered.items, 0..) |line, i| {
            if (shown >= list_rows) break;
            const truncated = line[0..@min(line.len, cols -| 2)];
            if (i == selected) {
                try frame.print(alloc, "\x1b[{d};1H\x1b[K\x1b[7m {s}\x1b[0m", .{ row, truncated });
            } else {
                try frame.print(alloc, "\x1b[{d};1H\x1b[K {s}", .{ row, truncated });
            }
            row += 1;
            shown += 1;
        }
        try frame.print(alloc, "\x1b[2;{d}H", .{9 + query.items.len});
        writeAll(1, frame.items);

        const key = try readKey();
        switch (key) {
            .char => |ch| {
                try query.append(alloc, ch);
                selected = 0;
            },
            .backspace => {
                if (query.items.len > 0) query.items.len -= 1;
                selected = 0;
            },
            .clear_query => {
                query.clearRetainingCapacity();
                selected = 0;
            },
            .up => {
                if (selected > 0) selected -= 1;
            },
            .down, .ctrl_r => {
                if (filtered.items.len > 0) selected = (selected + 1) % filtered.items.len;
            },
            .enter => {
                if (filtered.items.len == 0) continue;
                return try alloc.dupe(u8, filtered.items[selected]);
            },
            .cancel => return null,
        }
    }
}

/// Rewrites `out` with every entry of `entries` (oldest-first) that
/// fuzzy-matches `query`, newest-first, sorted by `fuzzy.score` (tighter
/// match first) with a stable sort so equal scores keep the newest-first
/// order -- the recency tiebreak (see `fuzzy.score`'s doc comment).
fn refilter(alloc: std.mem.Allocator, entries: []const []const u8, query: []const u8, out: *std.ArrayList([]const u8)) !void {
    out.clearRetainingCapacity();
    var i: usize = entries.len;
    while (i > 0) {
        i -= 1;
        if (fuzzy.matches(entries[i], query)) try out.append(alloc, entries[i]);
    }
    const Ctx = struct {
        query: []const u8,
        fn lessThan(ctx: @This(), a: []const u8, b: []const u8) bool {
            const sa = fuzzy.score(a, ctx.query) orelse return false;
            const sb = fuzzy.score(b, ctx.query) orelse return false;
            return sa < sb;
        }
    };
    std.mem.sort([]const u8, out.items, Ctx{ .query = query }, Ctx.lessThan);
}

const Key = union(enum) {
    char: u8,
    backspace,
    clear_query,
    up,
    down,
    ctrl_r,
    enter,
    cancel,
};

/// Blocking single-key read off the raw-mode stdin set up in `main`. An
/// arrow key arrives as a 3-byte CSI sequence (`ESC [ A`/`ESC [ B`); a
/// lone Esc press (no follow-up byte) has to be told apart from the
/// start of one, so seeing Esc temporarily shortens `VTIME` to a ~100ms
/// timeout for just the next read instead of blocking forever.
fn readKey() !Key {
    var b: [1]u8 = undefined;
    while (true) {
        const n = c.read(0, &b, 1);
        if (n <= 0) continue;
        switch (b[0]) {
            0x03 => return .cancel, // Ctrl+C
            0x12 => return .ctrl_r, // Ctrl+R
            0x15 => return .clear_query, // Ctrl+U
            0x7f, 0x08 => return .backspace,
            '\r', '\n' => return .enter,
            0x1b => return try readEscape(),
            else => |ch| if (ch >= 0x20 and ch < 0x7f) return .{ .char = ch },
        }
    }
}

fn readEscape() !Key {
    var raw = std.posix.tcgetattr(0) catch return .cancel;
    const saved = raw;
    raw.cc[@intFromEnum(std.posix.V.MIN)] = 0;
    raw.cc[@intFromEnum(std.posix.V.TIME)] = 1; // deciseconds -- ~100ms
    std.posix.tcsetattr(0, .NOW, raw) catch {};
    defer std.posix.tcsetattr(0, .NOW, saved) catch {};

    var b: [2]u8 = undefined;
    if (c.read(0, &b, 1) <= 0) return .cancel; // lone Esc
    if (b[0] != '[') return .cancel;
    if (c.read(0, b[1..2].ptr, 1) <= 0) return .cancel;
    return switch (b[1]) {
        'A' => .up,
        'B' => .down,
        else => .cancel,
    };
}
