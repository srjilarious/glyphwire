// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: GPL-3.0-or-later

//! Unsaved-change backups: a copy of every modified buffer, kept on disk
//! so that quitting, a closed window or a crash never loses typing.
//!
//! **Where.** One directory for every buffer,
//! `$XDG_STATE_HOME/glyphwire/zoe/backups` (else
//! `~/.local/state/glyphwire/zoe/backups`), the same root gw-shell's crash
//! logs use -- not a `.foo.zoebak` beside each file. A file beside the
//! original shows up in `git status`, the sidebar and every build
//! watcher, and can't be written at all in a directory zoe may only read;
//! a backup is zoe's private state, so it lives where zoe's state lives.
//! The directory is `0700` and each file `0600`: a backup is a copy of
//! whatever was being edited, secrets included.
//!
//! **Names.** A buffer with a file is `f-<hash of its absolute path>`; an
//! untitled one is `u-<hash of its scope>-<id>`, its id random and kept
//! for the slot's life, so its backup keeps one name across writes and
//! sessions. The scope is the `.zoe-workspace` the session has open, else
//! its folder list: untitled buffers come back with the workspace (or
//! directory) they were typed in. The hash only picks the name; the
//! header carries the path itself, and a backup whose path doesn't match
//! is someone else's collision, not this file's.
//!
//! **Format.** A few `key value` header lines, a blank line, then the
//! buffer's bytes untouched:
//!
//!     zoe-backup 1
//!     pid 4242
//!     disk 1834 1760000000123456789
//!     path /home/me/src/main.zig
//!
//!     <text>
//!
//! `disk` is the file's size and mtime as of zoe's last read or write of
//! it (`Slot.disk`), or `-` for a file not on disk then. Reopening the
//! file compares it against the file now: unchanged means the backup is
//! edits on top of exactly what is on disk, and is restored without
//! asking; changed means someone else wrote the file since, and the user
//! decides (`decide`). An untitled buffer has `scope` in place of
//! `path`. `pid` is the zoe that wrote it, so a second zoe opening the
//! same file leaves a live one's backup alone (`ownerAlive`).
//!
//! Everything but the `*File` / `dirPath` / `list` / `ownerAlive` IO
//! wrappers is pure, which `tests/zoe_tests.zig` leans on.

const std = @import("std");
const diskwatch = @import("diskwatch.zig");

/// The `zoe-backup` version `serialize` writes; a file with any other is
/// left alone rather than half-read.
pub const format_version: u32 = 1;

/// How long after a change the backup is written. Not a debounce that
/// waits for typing to stop -- an hour of steady typing would then never
/// be backed up -- but a deadline armed by the first change and met
/// whatever happens after it: at most this much typing is ever at risk.
pub const delay_ms: i64 = 1000;

pub const extension = ".zoebak";
/// Name prefixes: a buffer with a file, and an untitled one.
pub const file_prefix = "f-";
pub const untitled_prefix = "u-";

pub const Header = struct {
    /// The zoe that wrote it.
    pid: i32 = 0,
    /// The file's stamp when the buffer last matched it, or null when it
    /// wasn't on disk.
    disk: ?diskwatch.Stamp = null,
    /// A buffer with a file: its absolute path.
    path: ?[]const u8 = null,
    /// An untitled buffer: the session it belongs to (`scopeKey`).
    scope: ?[]const u8 = null,
};

pub const Parsed = struct {
    /// Borrows from the bytes `parse` was given.
    header: Header,
    text: []const u8,
};

/// The backup file's bytes for `text`. Null `path` and `scope` both is a
/// caller bug; a value holding a newline can't be put in a header line
/// and is refused (`error.Unrepresentable`) -- such a file just goes
/// without a backup.
pub fn serialize(alloc: std.mem.Allocator, h: Header, text: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    const w = &out.writer;
    try w.print("zoe-backup {d}\npid {d}\n", .{ format_version, h.pid });
    if (h.disk) |d| try w.print("disk {d} {d}\n", .{ d.size, d.mtime_ns }) else try w.writeAll("disk -\n");
    if (h.path) |p| {
        if (std.mem.indexOfScalar(u8, p, '\n') != null) return error.Unrepresentable;
        try w.print("path {s}\n", .{p});
    }
    if (h.scope) |s| {
        if (std.mem.indexOfScalar(u8, s, '\n') != null) return error.Unrepresentable;
        try w.print("scope {s}\n", .{s});
    }
    try w.writeAll("\n");
    try w.writeAll(text);
    return out.toOwnedSlice();
}

/// Reads `serialize`'s format back, or null for anything else: another
/// version, a missing line, a truncated header. Unknown keys are skipped
/// so a later version can add one without this refusing the file.
pub fn parse(bytes: []const u8) ?Parsed {
    var h: Header = .{};
    var rest = bytes;
    var first = true;
    while (true) {
        const nl = std.mem.indexOfScalar(u8, rest, '\n') orelse return null;
        const line = rest[0..nl];
        rest = rest[nl + 1 ..];
        if (line.len == 0) break;
        const sp = std.mem.indexOfScalar(u8, line, ' ') orelse return null;
        const key = line[0..sp];
        const val = line[sp + 1 ..];
        if (first) {
            if (!std.mem.eql(u8, key, "zoe-backup")) return null;
            const v = std.fmt.parseInt(u32, val, 10) catch return null;
            if (v != format_version) return null;
            first = false;
        } else if (std.mem.eql(u8, key, "pid")) {
            h.pid = std.fmt.parseInt(i32, val, 10) catch return null;
        } else if (std.mem.eql(u8, key, "disk")) {
            if (!std.mem.eql(u8, val, "-")) {
                const mid = std.mem.indexOfScalar(u8, val, ' ') orelse return null;
                h.disk = .{
                    .size = std.fmt.parseInt(u64, val[0..mid], 10) catch return null,
                    .mtime_ns = std.fmt.parseInt(i96, val[mid + 1 ..], 10) catch return null,
                };
            }
        } else if (std.mem.eql(u8, key, "path")) {
            h.path = val;
        } else if (std.mem.eql(u8, key, "scope")) {
            h.scope = val;
        }
    }
    if (first or (h.path == null and h.scope == null)) return null;
    return .{ .header = h, .text = rest };
}

/// What reopening a file with a backup does.
pub const Recovery = enum {
    /// The file is as it was when the buffer was based on it: put the
    /// edits back without asking.
    restore,
    /// The file changed (or appeared, or vanished) since: the user picks.
    ask,
};

/// `backed` is the header's `disk`, `current` the file's stamp now.
pub fn decide(backed: ?diskwatch.Stamp, current: ?diskwatch.Stamp) Recovery {
    if (backed == null and current == null) return .restore;
    const b = backed orelse return .ask;
    const c = current orelse return .ask;
    return if (b.eql(c)) .restore else .ask;
}

fn hash(bytes: []const u8) u64 {
    return std.hash.Wyhash.hash(0, bytes);
}

/// `f-<16 hex>.zoebak` for the file at absolute path `abs`.
pub fn fileName(buf: *[name_len]u8, abs: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, file_prefix ++ "{x:0>16}" ++ extension, .{hash(abs)}) catch unreachable;
}

/// `u-<16 hex>-<16 hex>.zoebak` for untitled buffer `id` in `scope`.
pub fn untitledName(buf: *[name_len]u8, scope: []const u8, id: u64) []const u8 {
    return std.fmt.bufPrint(buf, untitled_prefix ++ "{x:0>16}-{x:0>16}" ++ extension, .{ hash(scope), id }) catch unreachable;
}

/// The prefix every untitled backup in `scope` shares: `u-<16 hex>-`.
pub fn untitledPrefix(buf: *[name_len]u8, scope: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, untitled_prefix ++ "{x:0>16}-", .{hash(scope)}) catch unreachable;
}

/// The id an untitled backup's name carries, or null for any other name.
pub fn untitledId(name: []const u8) ?u64 {
    if (!std.mem.startsWith(u8, name, untitled_prefix) or !std.mem.endsWith(u8, name, extension)) return null;
    const core = name[untitled_prefix.len .. name.len - extension.len];
    if (core.len != 33 or core[16] != '-') return null;
    return std.fmt.parseInt(u64, core[17..], 16) catch null;
}

/// The longest name any of the above makes.
pub const name_len = untitled_prefix.len + 16 + 1 + 16 + extension.len;

/// Which session untitled buffers belong to: the `.zoe-workspace` file
/// when there is one, else the sidebar's folders joined by tabs (a
/// header value is one line). Written into `buf`, truncated to fit.
pub fn scopeKey(buf: []u8, ws_file: ?[]const u8, folders: []const []const u8) []const u8 {
    if (ws_file) |f| return f[0..@min(f.len, buf.len)];
    var n: usize = 0;
    for (folders, 0..) |f, i| {
        if (i > 0 and n < buf.len) {
            buf[n] = '\t';
            n += 1;
        }
        const take = @min(f.len, buf.len - n);
        @memcpy(buf[n..][0..take], f[0..take]);
        n += take;
    }
    return buf[0..n];
}

/// Where backups go, owned: `$XDG_STATE_HOME/glyphwire/zoe/backups`, else
/// `$HOME/.local/state/glyphwire/zoe/backups`. Null with neither set.
pub fn dirPath(alloc: std.mem.Allocator, environ: *const std.process.Environ.Map) !?[]u8 {
    if (environ.get("XDG_STATE_HOME")) |xdg| {
        if (xdg.len > 0) return try std.fs.path.join(alloc, &.{ xdg, "glyphwire", "zoe", "backups" });
    }
    const home = environ.get("HOME") orelse return null;
    return try std.fs.path.join(alloc, &.{ home, ".local", "state", "glyphwire", "zoe", "backups" });
}

/// Writes `bytes` as `dir/name`, atomically: a crash mid-write leaves the
/// previous backup, never half of one. Creates `dir` (`0700`) first.
pub fn writeFile(io: std.Io, dir: []const u8, name: []const u8, bytes: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    _ = try cwd.createDirPathStatus(io, dir, .fromMode(0o700));
    var d = try cwd.openDir(io, dir, .{});
    defer d.close(io);
    var af = try d.createFileAtomic(io, name, .{ .permissions = .fromMode(0o600), .replace = true });
    defer af.deinit(io);
    try af.file.writeStreamingAll(io, bytes);
    try af.replace(io);
}

/// Reads `dir/name`, owned, or null when it isn't there or can't be read.
pub fn readFile(alloc: std.mem.Allocator, io: std.Io, dir: []const u8, name: []const u8, limit: usize) ?[]u8 {
    const path = std.fs.path.join(alloc, &.{ dir, name }) catch return null;
    defer alloc.free(path);
    return std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(limit)) catch null;
}

/// Deletes `dir/name`. Best-effort: one already gone is the same result.
pub fn deleteFile(alloc: std.mem.Allocator, io: std.Io, dir: []const u8, name: []const u8) void {
    const path = std.fs.path.join(alloc, &.{ dir, name }) catch return;
    defer alloc.free(path);
    std.Io.Dir.cwd().deleteFile(io, path) catch {};
}

/// Every backup's name in `dir`, owned, unsorted. Empty when the
/// directory doesn't exist yet.
pub fn list(alloc: std.mem.Allocator, io: std.Io, dir: []const u8) ![][]u8 {
    var out: std.ArrayList([]u8) = .empty;
    errdefer freeNames(alloc, out.items);
    errdefer out.deinit(alloc);
    var d = std.Io.Dir.cwd().openDir(io, dir, .{ .iterate = true }) catch return out.toOwnedSlice(alloc);
    defer d.close(io);
    var it = d.iterate();
    while (it.next(io) catch null) |e| {
        if (e.kind != .file or !std.mem.endsWith(u8, e.name, extension)) continue;
        const name = try alloc.dupe(u8, e.name);
        errdefer alloc.free(name);
        try out.append(alloc, name);
    }
    return out.toOwnedSlice(alloc);
}

pub fn freeNames(alloc: std.mem.Allocator, names: []const []u8) void {
    for (names) |n| alloc.free(n);
    alloc.free(names);
}

/// Whether the zoe that wrote a backup (`pid`) is still running and
/// isn't this one. Read off `/proc/<pid>/comm`, so a recycled pid that
/// now belongs to some other program doesn't count; without `/proc` the
/// answer is no, and the backup is treated as abandoned.
pub fn ownerAlive(io: std.Io, pid: i32, self_pid: i32) bool {
    if (pid <= 0 or pid == self_pid) return false;
    var path_buf: [32]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "/proc/{d}/comm", .{pid}) catch return false;
    var comm_buf: [32]u8 = undefined;
    const comm = std.Io.Dir.cwd().readFile(io, path, &comm_buf) catch return false;
    return std.mem.eql(u8, std.mem.trimEnd(u8, comm, "\n"), "zoe");
}
