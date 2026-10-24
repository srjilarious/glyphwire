// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: GPL-3.0-or-later

//! F1's attribute changes: chmod and chown over the selection, through
//! the same `fileops.Hooks` the copies use, so a failure asks "carry
//! on?" in the usual dialog and the sudo helper can run them as root.
//!
//! Every selected path gets the same absolute mode, or the same
//! owner/group -- the dialog starts from the first entry's, and what it
//! says is what each file ends up with. `recursive` goes down into
//! directories, and `filter` limits the change to files only or to
//! directories only, at the top level as well as below it: "make every
//! file under here 0644 but leave the directories alone" is one pass.
//!
//! The walk never follows a symlink. chmod skips links outright (Linux
//! can't change a link's own mode, and following it would reach outside
//! the tree); chown changes the link itself, as `chown -h` does.
//! Directories are changed after their contents, so a mode that takes
//! away our own `x` doesn't lock the walk out halfway down.

const std = @import("std");
const builtin = @import("builtin");
const fileops = @import("applib").fileops;

/// Which entries a change applies to. The tag names cross the sudo
/// helper's pipe, so renaming one breaks a helper of another version.
pub const Filter = enum {
    all,
    /// Everything that isn't a directory.
    files,
    dirs,

    pub fn label(self: Filter) []const u8 {
        return switch (self) {
            .all => "All",
            .files => "Files only",
            .dirs => "Directories only",
        };
    }

    fn admits(self: Filter, is_dir: bool) bool {
        return switch (self) {
            .all => true,
            .files => !is_dir,
            .dirs => is_dir,
        };
    }
};

/// Owner and group as ids; null leaves that one as it is.
pub const Owner = struct {
    uid: ?u32 = null,
    gid: ?u32 = null,
};

pub const Change = union(enum) {
    /// The permission bits, setuid/setgid/sticky included.
    mode: u12,
    owner: Owner,

    pub fn kind(self: Change) fileops.Kind {
        return switch (self) {
            .mode => .chmod,
            .owner => .chown,
        };
    }
};

pub const Operation = struct {
    change: Change,
    /// Absolute paths. Borrowed.
    sources: []const []const u8,
    recursive: bool = false,
    filter: Filter = .all,

    pub fn run(self: Operation, io: std.Io, alloc: std.mem.Allocator, hooks: fileops.Hooks) fileops.Result {
        var runner: Runner = .{ .io = io, .alloc = alloc, .hooks = hooks, .op = self };
        for (self.sources, 0..) |src, i| {
            hooks.onProgress(hooks.ctx, self.change.kind(), i, self.sources.len, src);
            runner.applyTree(src, 0) catch {
                runner.result.cancelled = true;
                break;
            };
        }
        return runner.result;
    }
};

/// How deep `recursive` goes. A guard against a pathological tree; a
/// directory past it is reported as an error rather than walked.
pub const max_depth = 64;

const Runner = struct {
    io: std.Io,
    alloc: std.mem.Allocator,
    hooks: fileops.Hooks,
    op: Operation,
    result: fileops.Result = .{},

    const Stop = error{Cancelled};

    fn fail(self: *Runner, path: []const u8, err: anyerror) Stop!void {
        self.result.failed += 1;
        if (self.result.first_error == null) self.result.first_error = err;
        if (!self.hooks.onError(self.hooks.ctx, path, err)) return error.Cancelled;
    }

    fn applyTree(self: *Runner, path: []const u8, depth: usize) Stop!void {
        const cwd = std.Io.Dir.cwd();
        const st = cwd.statFile(self.io, path, .{ .follow_symlinks = false }) catch |err| return self.fail(path, err);
        const is_dir = st.kind == .directory;

        if (is_dir and self.op.recursive) {
            if (depth >= max_depth) return self.fail(path, error.NameTooLong);
            try self.applyChildren(path, depth);
        }
        if (!self.op.filter.admits(is_dir)) return;
        if (st.kind == .sym_link and self.op.change == .mode) return;
        self.applyOne(path) catch |err| return self.fail(path, err);
        self.result.done += 1;
    }

    fn applyChildren(self: *Runner, path: []const u8, depth: usize) Stop!void {
        var dir = std.Io.Dir.cwd().openDir(self.io, path, .{ .iterate = true, .follow_symlinks = false }) catch |err| return self.fail(path, err);
        defer dir.close(self.io);
        // Names first, then the changes: nothing here renames or removes,
        // but a directory's own entries are changed while it's open.
        var names: std.ArrayList([]u8) = .empty;
        defer {
            for (names.items) |n| self.alloc.free(n);
            names.deinit(self.alloc);
        }
        var it = dir.iterate();
        while (it.next(self.io) catch |err| return self.fail(path, err)) |entry| {
            const name = self.alloc.dupe(u8, entry.name) catch |err| return self.fail(path, err);
            names.append(self.alloc, name) catch |err| {
                self.alloc.free(name);
                return self.fail(path, err);
            };
        }
        for (names.items) |name| {
            const child = std.fs.path.join(self.alloc, &.{ path, name }) catch |err| return self.fail(path, err);
            defer self.alloc.free(child);
            try self.applyTree(child, depth + 1);
        }
    }

    fn applyOne(self: *Runner, path: []const u8) !void {
        const cwd = std.Io.Dir.cwd();
        switch (self.op.change) {
            .mode => |m| try cwd.setFilePermissions(self.io, path, .fromMode(m), .{}),
            .owner => |o| try lchown(path, o.uid, o.gid),
        }
    }
};

pub const ChownError = error{
    PermissionDenied,
    AccessDenied,
    FileNotFound,
    ReadOnlyFileSystem,
    SymLinkLoop,
    NameTooLong,
    InputOutput,
    Unexpected,
};

/// `fchownat(AT_FDCWD, path, uid, gid, AT_SYMLINK_NOFOLLOW)` straight to
/// the kernel: zig 0.17's threaded `Io` panics with "TODO implement
/// dirSetFileOwner" for `Dir.setFileOwner`. A null id is -1, "unchanged".
fn lchown(path: []const u8, uid: ?u32, gid: ?u32) ChownError!void {
    if (builtin.os.tag != .linux) return error.Unexpected;
    const linux = std.os.linux;
    const path_z = std.posix.toPosixPath(path) catch return error.NameTooLong;
    const unchanged = std.math.maxInt(u32);
    const rc = linux.fchownat(linux.AT.FDCWD, &path_z, uid orelse unchanged, gid orelse unchanged, linux.AT.SYMLINK_NOFOLLOW);
    return switch (linux.errno(rc)) {
        .SUCCESS => {},
        .PERM => error.PermissionDenied,
        .ACCES => error.AccessDenied,
        .NOENT, .NOTDIR => error.FileNotFound,
        .ROFS => error.ReadOnlyFileSystem,
        .LOOP => error.SymLinkLoop,
        .NAMETOOLONG => error.NameTooLong,
        .IO => error.InputOutput,
        else => error.Unexpected,
    };
}

// ── Modes ───────────────────────────────────────────────────────────────

/// The chmod dialog's twelve toggles, in the order it lays them out:
/// owner rwx, group rwx, others rwx, then setuid, setgid, sticky.
pub const mode_bits = [12]u12{ 0o400, 0o200, 0o100, 0o040, 0o020, 0o010, 0o004, 0o002, 0o001, 0o4000, 0o2000, 0o1000 };

/// One to four octal digits (`755`, `0644`, `4755`), or null.
pub fn parseOctal(text: []const u8) ?u12 {
    const t = std.mem.trim(u8, text, " ");
    if (t.len == 0 or t.len > 4) return null;
    var v: u12 = 0;
    for (t) |c| {
        if (c < '0' or c > '7') return null;
        v = (v << 3) | @as(u12, @intCast(c - '0'));
    }
    return v;
}

/// `mode` as four octal digits, `0755`.
pub fn formatOctal(buf: *[4]u8, mode: u12) []const u8 {
    return std.fmt.bufPrint(buf, "{o:0>4}", .{mode}) catch unreachable;
}

// ── Owners ──────────────────────────────────────────────────────────────

/// One-field extern views of glibc's `struct passwd` / `struct group`,
/// just far enough in to reach the id. Their layout up to there is the
/// same on every Linux libc: name, password, then the id.
const pwlib = struct {
    const passwd = extern struct { pw_name: ?[*:0]const u8, pw_passwd: ?[*:0]const u8, pw_uid: c_uint };
    const group = extern struct { gr_name: ?[*:0]const u8, gr_passwd: ?[*:0]const u8, gr_gid: c_uint };
    extern "c" fn getpwnam(name: [*:0]const u8) ?*passwd;
    extern "c" fn getgrnam(name: [*:0]const u8) ?*group;
};

pub const OwnerError = error{ UnknownUser, UnknownGroup };

/// What's typed into the owner field: empty leaves the owner alone, a
/// number is that uid, anything else is looked up as a user name.
pub fn parseUser(text: []const u8) OwnerError!?u32 {
    const t = std.mem.trim(u8, text, " ");
    if (t.len == 0) return null;
    if (std.fmt.parseInt(u32, t, 10)) |n| return n else |_| {}
    var buf: [256]u8 = undefined;
    if (t.len >= buf.len or builtin.os.tag != .linux) return error.UnknownUser;
    @memcpy(buf[0..t.len], t);
    buf[t.len] = 0;
    const pw = pwlib.getpwnam(buf[0..t.len :0]) orelse return error.UnknownUser;
    return pw.pw_uid;
}

/// `parseUser` for the group field.
pub fn parseGroup(text: []const u8) OwnerError!?u32 {
    const t = std.mem.trim(u8, text, " ");
    if (t.len == 0) return null;
    if (std.fmt.parseInt(u32, t, 10)) |n| return n else |_| {}
    var buf: [256]u8 = undefined;
    if (t.len >= buf.len or builtin.os.tag != .linux) return error.UnknownGroup;
    @memcpy(buf[0..t.len], t);
    buf[t.len] = 0;
    const gr = pwlib.getgrnam(buf[0..t.len :0]) orelse return error.UnknownGroup;
    return gr.gr_gid;
}

// ── The sudo helper's arguments ─────────────────────────────────────────

/// `op` as the sudo helper's arguments after its `chmod` / `chown` tag:
/// `<mode>` or `<uid> <gid>` (empty for unchanged), then `<recursive>`
/// (`0`/`1`), `<filter>` and the sources. Strings are allocated in
/// `arena`.
pub fn helperArgs(arena: std.mem.Allocator, op: Operation) ![]const []const u8 {
    var args: std.ArrayList([]const u8) = .empty;
    switch (op.change) {
        .mode => |m| {
            try args.append(arena, "chmod");
            try args.append(arena, try std.fmt.allocPrint(arena, "{o}", .{m}));
        },
        .owner => |o| {
            try args.append(arena, "chown");
            try args.append(arena, if (o.uid) |u| try std.fmt.allocPrint(arena, "{d}", .{u}) else "");
            try args.append(arena, if (o.gid) |g| try std.fmt.allocPrint(arena, "{d}", .{g}) else "");
        },
    }
    try args.append(arena, if (op.recursive) "1" else "0");
    try args.append(arena, @tagName(op.filter));
    try args.appendSlice(arena, op.sources);
    return args.items;
}

/// The reverse of `helperArgs`, `args` starting after the tag. Null for
/// anything malformed. The sources are borrowed from `args`.
pub fn parseHelperArgs(tag: fileops.Kind, args: []const []const u8) ?Operation {
    const fixed: usize = if (tag == .chmod) 3 else 4;
    if (args.len <= fixed) return null;
    const change: Change = switch (tag) {
        .chmod => .{ .mode = parseOctal(args[0]) orelse return null },
        .chown => .{ .owner = .{
            .uid = if (args[0].len == 0) null else std.fmt.parseInt(u32, args[0], 10) catch return null,
            .gid = if (args[1].len == 0) null else std.fmt.parseInt(u32, args[1], 10) catch return null,
        } },
        else => return null,
    };
    const rec = args[fixed - 2];
    if (!std.mem.eql(u8, rec, "0") and !std.mem.eql(u8, rec, "1")) return null;
    return .{
        .change = change,
        .recursive = rec[0] == '1',
        .filter = std.meta.stringToEnum(Filter, args[fixed - 1]) orelse return null,
        .sources = args[fixed..],
    };
}
