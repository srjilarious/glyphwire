// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: GPL-3.0-or-later

//! The Super+F-key forms of rename, edit, copy, move, make directory and
//! delete: the same operations, run as root.
//!
//! The file operations run inside salacommander (`fileops.zig`), and a
//! process can't become root partway through, so the sudo forms start
//! salacommander again as a helper -- `sudo -n -- salacommander --fileop
//! <op> ...` -- which runs the very same `fileops.Operation` and sends
//! its questions back over a pipe. The commander answers them with its
//! usual dialogs, so a root copy asks "File exists" exactly as an
//! ordinary one does. Edit is the exception: it is `sudoedit`, which runs
//! the editor as you on a copy and writes it back as root, rather than
//! running an editor as root.
//!
//! The password is asked for in a masked dialog and checked with `sudo
//! -S -v`, which reads it from a pipe and only refreshes sudo's
//! timestamp; the helper and sudoedit then run under `sudo -n`, so no
//! password ever travels down the pipe the helper talks over. That needs
//! sudo to remember a success for a while (its default); with
//! `timestamp_timeout=0` the `-n` run fails and says so in the bar.
//!
//! The helper's messages are NUL-terminated fields, a fixed number per
//! kind of message, and its answers come back the same way. NUL is the
//! one byte a path can't hold, so a name with a newline or bytes that
//! aren't UTF-8 goes through untouched.

const std = @import("std");
const builtin = @import("builtin");
const fileops = @import("applib").fileops;
const attrs = @import("attrs.zig");

/// The first argument that turns salacommander into the helper.
pub const helper_flag = "--fileop";

/// What the helper can be asked to do. `copy`/`move` take a destination
/// then sources, `delete` takes sources, `mkdir` a path, and `rename` a
/// directory, the old name and the new one. `chmod`/`chown` take what
/// `attrs.helperArgs` writes.
pub const Op = enum { copy, move, delete, mkdir, rename, chmod, chown };

// ── The helper (root side) ──────────────────────────────────────────────

/// The helper's `main`: `args` is everything after `helper_flag`. Talks
/// over stdin/stdout and returns the exit status.
pub fn helperMain(io: std.Io, alloc: std.mem.Allocator, args: []const [:0]const u8) u8 {
    const plain = alloc.alloc([]const u8, args.len) catch return 1;
    defer alloc.free(plain);
    for (args, plain) |a, *p| p.* = a;

    var in_buf: [2 * std.fs.max_path_bytes]u8 = undefined;
    var in = std.Io.File.stdin().readerStreaming(io, &in_buf);
    var out_buf: [2 * std.fs.max_path_bytes]u8 = undefined;
    var out = std.Io.File.stdout().writerStreaming(io, &out_buf);
    return serve(io, alloc, plain, &in.interface, &out.interface);
}

/// Runs the operation `args` names, reporting over `out` and reading the
/// answers to its questions from `in`, and ends with a `done` message.
/// 0 when it got as far as `done`; 2 for arguments it can't make sense
/// of, which sends nothing at all.
pub fn serve(io: std.Io, alloc: std.mem.Allocator, args: []const []const u8, in: *std.Io.Reader, out: *std.Io.Writer) u8 {
    if (args.len == 0) return 2;
    const op = std.meta.stringToEnum(Op, args[0]) orelse return 2;
    const rest = args[1..];

    var remote: Remote = .{ .in = in, .out = out };
    const result: fileops.Result = switch (op) {
        .copy, .move => blk: {
            if (rest.len < 2) return 2;
            const kind: fileops.Kind = if (op == .copy) .copy else .move;
            break :blk (fileops.Operation{ .kind = kind, .dest = rest[0], .sources = rest[1..] }).run(io, alloc, remote.hooks());
        },
        .delete => blk: {
            if (rest.len < 1) return 2;
            break :blk (fileops.Operation{ .kind = .delete, .sources = rest }).run(io, alloc, remote.hooks());
        },
        .mkdir => blk: {
            if (rest.len != 1) return 2;
            break :blk single(fileops.makeDir(io, rest[0]));
        },
        .rename => blk: {
            if (rest.len != 3) return 2;
            break :blk single(fileops.renameInDir(io, alloc, rest[0], rest[1], rest[2]));
        },
        .chmod, .chown => blk: {
            const kind: fileops.Kind = if (op == .chmod) .chmod else .chown;
            const attr_op = attrs.parseHelperArgs(kind, rest) orelse return 2;
            break :blk attr_op.run(io, alloc, remote.hooks());
        },
    };

    var nums: [3][24]u8 = undefined;
    remote.send(&.{
        "done",
        std.fmt.bufPrint(&nums[0], "{d}", .{result.done}) catch unreachable,
        std.fmt.bufPrint(&nums[1], "{d}", .{result.skipped}) catch unreachable,
        std.fmt.bufPrint(&nums[2], "{d}", .{result.failed}) catch unreachable,
        if (result.cancelled) "1" else "0",
        if (result.first_error) |e| @errorName(e) else "",
    });
    return 0;
}

/// A one-shot operation's outcome as a `Result`, so the commander reads
/// it the way it reads a copy's.
fn single(outcome: anyerror!void) fileops.Result {
    outcome catch |err| return .{ .failed = 1, .first_error = err };
    return .{ .done = 1 };
}

/// The helper's end of the pipe, as `fileops.Hooks`. A pipe that breaks
/// (the commander went away) cancels the operation at its next question.
const Remote = struct {
    in: *std.Io.Reader,
    out: *std.Io.Writer,
    broken: bool = false,

    fn hooks(self: *Remote) fileops.Hooks {
        return .{ .ctx = self, .onConflict = onConflict, .onProgress = onProgress, .onError = onError };
    }

    fn send(self: *Remote, fields: []const []const u8) void {
        writeFields(self.out, fields) catch {
            self.broken = true;
        };
    }

    /// The answer to the question just sent, or null if there is none.
    fn answer(self: *Remote) ?[]const u8 {
        if (self.broken) return null;
        return (self.in.takeDelimiter(0) catch return null) orelse null;
    }

    fn onConflict(ctx: *anyopaque, src: []const u8, dest: []const u8) fileops.Conflict {
        const self: *Remote = @ptrCast(@alignCast(ctx));
        self.send(&.{ "conflict", src, dest });
        const a = self.answer() orelse return .cancel;
        return std.meta.stringToEnum(fileops.Conflict, a) orelse .cancel;
    }

    fn onProgress(ctx: *anyopaque, kind: fileops.Kind, index: usize, total: usize, path: []const u8) void {
        const self: *Remote = @ptrCast(@alignCast(ctx));
        var nums: [2][24]u8 = undefined;
        self.send(&.{
            "progress",
            @tagName(kind),
            std.fmt.bufPrint(&nums[0], "{d}", .{index}) catch unreachable,
            std.fmt.bufPrint(&nums[1], "{d}", .{total}) catch unreachable,
            path,
        });
    }

    fn onError(ctx: *anyopaque, path: []const u8, err: anyerror) bool {
        const self: *Remote = @ptrCast(@alignCast(ctx));
        self.send(&.{ "error", path, @errorName(err) });
        const a = self.answer() orelse return false;
        return std.mem.eql(u8, a, "continue");
    }
};

fn writeFields(w: *std.Io.Writer, fields: []const []const u8) !void {
    for (fields) |f| {
        try w.writeAll(f);
        try w.writeByte(0);
    }
    try w.flush();
}

// ── The commander's side ────────────────────────────────────────────────

/// Reads the helper's messages from `in` until its `done`, putting each
/// question to `hooks` and writing the answer to `out`. Null when the
/// helper stopped before `done` -- sudo refused to run it, say.
pub fn drive(alloc: std.mem.Allocator, in: *std.Io.Reader, out: *std.Io.Writer, hooks: fileops.Hooks) !?fileops.Result {
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    while (true) {
        _ = arena.reset(.retain_capacity);
        const a = arena.allocator();
        const tag = (try readField(a, in)) orelse return null;

        if (std.mem.eql(u8, tag, "progress")) {
            const f = (try readFields(a, in, 4)) orelse return null;
            const kind = std.meta.stringToEnum(fileops.Kind, f[0]) orelse return error.BadHelperMessage;
            hooks.onProgress(hooks.ctx, kind, try parseCount(f[1]), try parseCount(f[2]), f[3]);
        } else if (std.mem.eql(u8, tag, "conflict")) {
            const f = (try readFields(a, in, 2)) orelse return null;
            const choice = hooks.onConflict(hooks.ctx, f[0], f[1]);
            try writeFields(out, &.{@tagName(choice)});
        } else if (std.mem.eql(u8, tag, "error")) {
            const f = (try readFields(a, in, 2)) orelse return null;
            const go_on = hooks.onError(hooks.ctx, f[0], errorFromName(f[1]));
            try writeFields(out, &.{if (go_on) "continue" else "abort"});
        } else if (std.mem.eql(u8, tag, "done")) {
            const f = (try readFields(a, in, 5)) orelse return null;
            return .{
                .done = try parseCount(f[0]),
                .skipped = try parseCount(f[1]),
                .failed = try parseCount(f[2]),
                .cancelled = std.mem.eql(u8, f[3], "1"),
                .first_error = if (f[4].len == 0) null else errorFromName(f[4]),
            };
        } else return error.BadHelperMessage;
    }
}

fn readField(alloc: std.mem.Allocator, in: *std.Io.Reader) !?[]u8 {
    const f = (in.takeDelimiter(0) catch |err| switch (err) {
        error.ReadFailed => return null,
        else => |e| return e,
    }) orelse return null;
    return try alloc.dupe(u8, f);
}

fn readFields(alloc: std.mem.Allocator, in: *std.Io.Reader, comptime n: usize) !?[n][]u8 {
    var out: [n][]u8 = undefined;
    for (&out) |*f| f.* = (try readField(alloc, in)) orelse return null;
    return out;
}

fn parseCount(s: []const u8) !usize {
    return std.fmt.parseInt(usize, s, 10) catch error.BadHelperMessage;
}

/// The errors a file operation can report, so a name the helper sends
/// comes back as the same error here.
const KnownError = std.Io.Dir.DeleteTreeError || std.Io.Dir.RenameError ||
    std.Io.Dir.CopyFileError || std.Io.Dir.CreateDirPathError ||
    std.Io.Dir.SetFilePermissionsError || std.Io.Dir.SetFileOwnerError ||
    std.Io.Dir.OpenError || std.Io.Dir.StatFileError ||
    fileops.Error || error{ EmptyName, InvalidName, PathAlreadyExists, OutOfMemory };

/// `name` as an error, or `error.Unexpected` for one this side doesn't
/// know of.
pub fn errorFromName(name: []const u8) anyerror {
    inline for (@typeInfo(KnownError).error_set.error_names.?) |e| {
        if (std.mem.eql(u8, name, e)) return @field(KnownError, e);
    }
    return error.Unexpected;
}

/// What running the helper came to.
pub const Outcome = union(enum) {
    result: fileops.Result,
    /// It never got as far as `done`: sudo's own complaint (or what went
    /// wrong starting it), owned.
    failed: []u8,

    pub fn deinit(self: Outcome, alloc: std.mem.Allocator) void {
        if (self == .failed) alloc.free(self.failed);
    }
};

/// Runs the helper as root -- `exe` is salacommander's own path -- for
/// `args` (`Op` first), asking `hooks` its questions. Credentials must
/// already be cached (`hasCachedCredentials` / `checkPassword`).
pub fn run(io: std.Io, alloc: std.mem.Allocator, exe: []const u8, args: []const []const u8, hooks: fileops.Hooks) !Outcome {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(alloc);
    try argv.appendSlice(alloc, &.{ "sudo", "-n", "--", exe, helper_flag });
    try argv.appendSlice(alloc, args);

    var child = std.process.spawn(io, .{
        .argv = argv.items,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
    }) catch |err| return .{ .failed = try std.fmt.allocPrint(alloc, "can't run sudo: {t}", .{err}) };

    const driven = blk: {
        var in_buf: [2 * std.fs.max_path_bytes]u8 = undefined;
        var in = child.stdout.?.readerStreaming(io, &in_buf);
        var out_buf: [256]u8 = undefined;
        var out = child.stdin.?.writerStreaming(io, &out_buf);
        break :blk drive(alloc, &in.interface, &out.interface, hooks);
    };
    child.stdin.?.close(io);
    child.stdin = null;

    const complaint = try readAll(io, alloc, child.stderr.?);
    defer alloc.free(complaint);
    _ = child.wait(io) catch {};

    if (driven) |maybe| {
        if (maybe) |result| return .{ .result = result };
    } else |err| {
        return .{ .failed = try std.fmt.allocPrint(alloc, "sudo helper: {t}", .{err}) };
    }
    const line = lastLine(complaint);
    return .{ .failed = try alloc.dupe(u8, if (line.len > 0) line else "sudo failed") };
}

/// Whether sudo will run something right now without a password: a
/// timestamp from a recent success, or a NOPASSWD rule.
pub fn hasCachedCredentials(io: std.Io) bool {
    var child = std.process.spawn(io, .{
        .argv = &.{ "sudo", "-n", "true" },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return false;
    const term = child.wait(io) catch return false;
    return term.success();
}

pub const Check = union(enum) {
    ok,
    /// sudo said no; its last line of complaint ("Sorry, try again.",
    /// "... is not in the sudoers file"), owned.
    rejected: []u8,
};

/// Checks `password` with `sudo -S -v`, which reads it from a pipe and
/// on success refreshes the timestamp the `-n` runs after it lean on.
/// One try: a wrong password meets end-of-input when sudo asks again.
pub fn checkPassword(io: std.Io, alloc: std.mem.Allocator, password: []const u8) !Check {
    var child = std.process.spawn(io, .{
        .argv = &.{ "sudo", "-S", "-p", "", "-v" },
        .stdin = .pipe,
        .stdout = .ignore,
        .stderr = .pipe,
    }) catch |err| return .{ .rejected = try std.fmt.allocPrint(alloc, "can't run sudo: {t}", .{err}) };
    {
        // Sized to hold the password and its newline, so nothing is
        // left over to write after the buffer is wiped.
        var buf: [512]u8 = undefined;
        defer std.crypto.secureZero(u8, &buf);
        var w = child.stdin.?.writerStreaming(io, &buf);
        w.interface.writeAll(password) catch {};
        w.interface.writeByte('\n') catch {};
        w.interface.flush() catch {};
    }
    child.stdin.?.close(io);
    child.stdin = null;

    const complaint = try readAll(io, alloc, child.stderr.?);
    defer alloc.free(complaint);
    const term = child.wait(io) catch |err| return .{ .rejected = try std.fmt.allocPrint(alloc, "sudo: {t}", .{err}) };
    if (term.success()) return .ok;
    const line = lastLine(complaint);
    return .{ .rejected = try alloc.dupe(u8, if (line.len > 0) line else "sudo refused") };
}

fn readAll(io: std.Io, alloc: std.mem.Allocator, file: std.Io.File) ![]u8 {
    var buf: [1024]u8 = undefined;
    var r = file.readerStreaming(io, &buf);
    return r.interface.allocRemaining(alloc, .limited(16 * 1024)) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => alloc.dupe(u8, ""),
    };
}

/// The last non-blank line of `text`, trimmed -- sudo's final word on
/// stderr. The "sudo: " prefix goes; the bar already says what ran.
pub fn lastLine(text: []const u8) []const u8 {
    var it = std.mem.splitBackwardsScalar(u8, std.mem.trimEnd(u8, text, " \r\n"), '\n');
    const line = std.mem.trim(u8, it.first(), " \r");
    return if (std.mem.startsWith(u8, line, "sudo: ")) line["sudo: ".len..] else line;
}

// ── sudoedit ────────────────────────────────────────────────────────────

/// The variables passed on to the editor: everything glyphwire's own
/// (the socket the editor connects back over, its context and pane),
/// plus the ones that find the editor and its config. sudo may run the
/// editor in a scrubbed environment, so they ride in `SUDO_EDITOR` itself.
const forwarded = [_][]const u8{ "HOME", "PATH", "XDG_CONFIG_HOME", "XDG_RUNTIME_DIR" };

/// The argv for editing `path` as root: `env SUDO_EDITOR=... sudo -n -e
/// -- path`. `SUDO_EDITOR` is `editor` (F4's template, its `{sel}` words
/// dropped: sudoedit adds the file itself) behind an `env` carrying
/// `forwarded` and every `GLYPHWIRE_*` variable. sudo splits
/// `SUDO_EDITOR` on whitespace, so a value holding any is left out.
/// Everything is allocated in `arena`.
pub fn editArgv(arena: std.mem.Allocator, environ: ?*const std.process.Environ.Map, editor: []const u8, path: []const u8) ![]const []const u8 {
    var cmd: std.ArrayList(u8) = .empty;
    try cmd.appendSlice(arena, "SUDO_EDITOR=env");
    if (environ) |env| {
        var it = env.iterator();
        while (it.next()) |e| {
            const name = e.key_ptr.*;
            const value = e.value_ptr.*;
            const wanted = std.mem.startsWith(u8, name, "GLYPHWIRE_") or for (forwarded) |f| {
                if (std.mem.eql(u8, name, f)) break true;
            } else false;
            if (!wanted or std.mem.indexOfAny(u8, value, " \t\n") != null) continue;
            try cmd.print(arena, " {s}={s}", .{ name, value });
        }
    }
    var words = std.mem.tokenizeScalar(u8, editor, ' ');
    var any = false;
    while (words.next()) |word| {
        if (std.mem.eql(u8, word, "{sel}")) continue;
        try cmd.print(arena, " {s}", .{word});
        any = true;
    }
    if (!any) return error.EmptyCommand;

    const argv = try arena.alloc([]const u8, 7);
    argv[0..7].* = .{ "env", cmd.items, "sudo", "-n", "-e", "--", path };
    return argv;
}

/// Where sudoedit's stderr goes, so its refusal ("editing files in a
/// writable directory is not permitted") can be read back for the bar.
/// A memfd rather than a pipe: the editor writes there too while it
/// runs, and nothing is reading a pipe then. Off Linux it is dropped.
pub const Complaint = struct {
    file: ?std.Io.File = null,

    pub fn open() Complaint {
        if (builtin.os.tag != .linux) return .{};
        const fd = std.posix.memfd_create("salacommander-sudo", std.os.linux.MFD.CLOEXEC) catch return .{};
        return .{ .file = .{ .handle = fd, .flags = .{ .nonblocking = false } } };
    }

    pub fn close(self: Complaint, io: std.Io) void {
        if (self.file) |f| f.close(io);
    }

    pub fn stdio(self: Complaint) std.process.SpawnOptions.StdIo {
        return if (self.file) |f| .{ .file = f } else .ignore;
    }

    /// The last line written (see `lastLine`), read into `buf`.
    pub fn last(self: Complaint, io: std.Io, buf: []u8) []const u8 {
        const f = self.file orelse return "";
        const size = (f.stat(io) catch return "").size;
        const n = f.readPositionalAll(io, buf, size -| buf.len) catch return "";
        return lastLine(buf[0..n]);
    }
};
