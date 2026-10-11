// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: MPL-2.0

//! Moving files to the desktop trash, the freedesktop.org Trash
//! specification (1.0) -- the same trash Dolphin, Nautilus, `gio trash`
//! and `trash-put` use, so whatever salacommander's F8 throws away shows
//! up in the desktop's trash can and can be restored from there.
//!
//! A trash directory holds `files/` (the trashed entries, renamed) and
//! `info/` (one `<name>.trashinfo` per entry: where it came from and
//! when). Which trash an entry goes to depends on where it lives:
//!
//!   * on the same filesystem as the **home trash**
//!     (`$XDG_DATA_HOME/Trash`, else `~/.local/share/Trash`), there;
//!   * otherwise in a trash at the top of the entry's own mount
//!     (`$topdir`): `$topdir/.Trash/$uid` when the admin has made a
//!     sticky, non-symlink `$topdir/.Trash`, else `$topdir/.Trash-$uid`,
//!     created on the spot.
//!
//! Trashing is always a `rename`, never a copy: an entry that can't be
//! renamed into any trash is `error.NoTrash`, and what to do about that
//! (salacommander offers to delete it outright) is the caller's call.
//!
//! The optional `directorysizes` cache isn't written; readers of it fall
//! back to walking the trashed directory.
//!
//! Linux only: the filesystem a path lives on comes from `statx(2)`,
//! which `std.Io.File.Stat` doesn't expose.

const std = @import("std");
const builtin = @import("builtin");

pub const Error = error{
    /// No trash on the entry's filesystem could be found or made.
    NoTrash,
    /// The entry is a trash directory, or inside one.
    InTrash,
};

/// The trash a person's own files go to: `$XDG_DATA_HOME/Trash`, else
/// `$HOME/.local/share/Trash`. Null with neither set. Owned by `alloc`.
pub fn homeTrashPath(alloc: std.mem.Allocator, xdg_data_home: ?[]const u8, home: ?[]const u8) !?[]u8 {
    if (xdg_data_home) |x| {
        if (x.len > 0) return try std.fs.path.join(alloc, &.{ x, "Trash" });
    }
    if (home) |h| {
        if (h.len > 0) return try std.fs.path.join(alloc, &.{ h, ".local", "share", "Trash" });
    }
    return null;
}

pub const Options = struct {
    /// `homeTrashPath`. Null leaves only a trash at the top of the
    /// entry's mount.
    home_trash: ?[]const u8,
    /// The `.trashinfo`'s `DeletionDate`, as `formatDeletionDate` writes
    /// it.
    deletion_date: []const u8,
    /// Whose `$topdir/.Trash-$uid` to use (`currentUid`).
    uid: u32,
};

/// Moves `path` (absolute) into the trash for its filesystem, with a
/// `.trashinfo` naming where it came from. A link is trashed itself,
/// not what it points at.
pub fn moveToTrash(io: std.Io, alloc: std.mem.Allocator, path: []const u8, opts: Options) !void {
    const st = try statNoFollow(path);

    if (opts.home_trash) |home_trash| home: {
        if (isWithin(path, home_trash)) return error.InTrash;
        ensureTrashDir(io, home_trash) catch break :home;
        const trash_st = statNoFollow(home_trash) catch break :home;
        if (!sameDevice(st, trash_st)) break :home;
        // A bind mount of the same filesystem still refuses the rename
        // (`EXDEV`); the entry's own mount is the next place to try.
        trashInto(io, alloc, path, home_trash, path, opts.deletion_date) catch |err| switch (err) {
            error.CrossDevice => break :home,
            else => return err,
        };
        return;
    }

    const topdir = try mountTop(alloc, path, st);
    defer alloc.free(topdir);
    const trash = topdirTrash(io, alloc, topdir, opts.uid) catch return error.NoTrash;
    defer alloc.free(trash);
    if (isWithin(path, trash) or isTrashRoot(topdir, path)) return error.InTrash;

    // A topdir trash records the path relative to the topdir, so the
    // entry can be restored wherever the disk is mounted next time.
    const rel = if (std.mem.eql(u8, topdir, "/")) path[1..] else path[topdir.len + 1 ..];
    trashInto(io, alloc, path, trash, rel, opts.deletion_date) catch |err| switch (err) {
        error.CrossDevice => return error.NoTrash,
        else => return err,
    };
}

/// The trash at the top of a mount, made if need be: `$topdir/.Trash/$uid`
/// when `$topdir/.Trash` is a directory with the sticky bit (and not a
/// link -- the spec's guard against another user planting one), else
/// `$topdir/.Trash-$uid`. Either has its `files/` and `info/` once this
/// returns. Owned by `alloc`.
pub fn topdirTrash(io: std.Io, alloc: std.mem.Allocator, topdir: []const u8, uid: u32) ![]u8 {
    var uid_buf: [16]u8 = undefined;
    const uid_text = std.fmt.bufPrint(&uid_buf, "{d}", .{uid}) catch unreachable;

    const shared = try std.fs.path.join(alloc, &.{ topdir, ".Trash" });
    defer alloc.free(shared);
    if (isStickyDir(shared)) {
        const mine = try std.fs.path.join(alloc, &.{ shared, uid_text });
        errdefer alloc.free(mine);
        if (ensureOwnTrashDir(io, mine, uid)) return mine else |_| {}
        alloc.free(mine);
    }

    const name = try std.fmt.allocPrint(alloc, ".Trash-{s}", .{uid_text});
    defer alloc.free(name);
    const own = try std.fs.path.join(alloc, &.{ topdir, name });
    errdefer alloc.free(own);
    try ensureOwnTrashDir(io, own, uid);
    return own;
}

/// `.trashinfo`'s `DeletionDate`: `YYYY-MM-DDThh:mm:ss` in local time,
/// which is `epoch_secs` shifted by `utc_offset_secs` (`localUtcOffset`).
/// Borrows `buf`, which needs 19 bytes.
pub fn formatDeletionDate(buf: []u8, epoch_secs: i64, utc_offset_secs: i64) []const u8 {
    const local: u64 = @intCast(@max(epoch_secs + utc_offset_secs, 0));
    const es: std.time.epoch.EpochSeconds = .{ .secs = local };
    const day = es.getEpochDay().calculateYearDay();
    const md = day.calculateMonthDay();
    const ds = es.getDaySeconds();
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}", .{
        day.year,
        md.month.numeric(),
        md.day_index + 1,
        ds.getHoursIntoDay(),
        ds.getMinutesIntoHour(),
        ds.getSecondsIntoMinute(),
    }) catch buf[0..0];
}

/// Seconds east of UTC at `epoch_secs`, from libc's `localtime_r` (std
/// has no time zones). 0, i.e. UTC, without libc.
pub fn localUtcOffset(epoch_secs: i64) i64 {
    if (!builtin.link_libc) return 0;
    var tm: libc.Tm = undefined;
    const t: c_long = @intCast(epoch_secs);
    if (libc.localtime_r(&t, &tm) == null) return 0;
    return tm.gmtoff;
}

const libc = struct {
    /// glibc's `struct tm`: nine `int`s, then `tm_gmtoff` / `tm_zone`.
    const Tm = extern struct {
        sec: c_int,
        min: c_int,
        hour: c_int,
        mday: c_int,
        mon: c_int,
        year: c_int,
        wday: c_int,
        yday: c_int,
        isdst: c_int,
        gmtoff: c_long,
        zone: ?[*:0]const u8,
    };
    extern "c" fn localtime_r(timep: *const c_long, result: *Tm) ?*Tm;
};

/// The real uid, for `Options.uid`.
pub fn currentUid() u32 {
    return std.os.linux.getuid();
}

/// `path` as a `.trashinfo` `Path` value: escaped the way a URL path is
/// (RFC 2396), every byte but the unreserved characters and `/` as
/// `%XX`. Owned by `alloc`.
pub fn escapePath(alloc: std.mem.Allocator, path: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    for (path) |c| {
        if (std.ascii.isAlphanumeric(c) or std.mem.indexOfScalar(u8, "-_.!~*'()/", c) != null) {
            try out.append(alloc, c);
        } else {
            try out.print(alloc, "%{X:0>2}", .{c});
        }
    }
    return out.toOwnedSlice(alloc);
}

/// The name an entry called `base` is filed under in a trash on its
/// `attempt`th try: `base` itself first, then `stem.2.ext`,
/// `stem.3.ext`, ... so a trash browser still sees the extension.
/// Borrows `buf`; null when it doesn't fit.
pub fn candidateName(buf: []u8, base: []const u8, attempt: usize) ?[]const u8 {
    if (attempt <= 1) {
        if (base.len > buf.len) return null;
        @memcpy(buf[0..base.len], base);
        return buf[0..base.len];
    }
    const ext = std.fs.path.extension(base);
    const stem = base[0 .. base.len - ext.len];
    return std.fmt.bufPrint(buf, "{s}.{d}{s}", .{ stem, attempt, ext }) catch null;
}

// ── Internals ───────────────────────────────────────────────────────────

/// How many names `trashInto` tries before giving up on a crowded trash.
const max_attempts = 10_000;

/// Files `path` into the trash at `trash` under the first free name:
/// the `.trashinfo` is created exclusively first, which reserves the
/// name, then the entry is renamed into `files/`. A failed rename takes
/// the `.trashinfo` back out. `recorded` is the `Path` written.
fn trashInto(io: std.Io, alloc: std.mem.Allocator, path: []const u8, trash: []const u8, recorded: []const u8, deletion_date: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    const escaped = try escapePath(alloc, recorded);
    defer alloc.free(escaped);
    const info_text = try std.fmt.allocPrint(alloc, "[Trash Info]\nPath={s}\nDeletionDate={s}\n", .{ escaped, deletion_date });
    defer alloc.free(info_text);

    var name_buf: [std.Io.Dir.max_name_bytes]u8 = undefined;
    var info_name_buf: [std.Io.Dir.max_name_bytes + ".trashinfo".len]u8 = undefined;
    const base = std.fs.path.basename(path);
    var attempt: usize = 1;
    while (attempt <= max_attempts) : (attempt += 1) {
        const name = candidateName(&name_buf, base, attempt) orelse return error.NameTooLong;
        const info_name = std.fmt.bufPrint(&info_name_buf, "{s}.trashinfo", .{name}) catch return error.NameTooLong;
        const info_path = try std.fs.path.join(alloc, &.{ trash, "info", info_name });
        defer alloc.free(info_path);
        const dest = try std.fs.path.join(alloc, &.{ trash, "files", name });
        defer alloc.free(dest);

        cwd.writeFile(io, .{ .sub_path = info_path, .data = info_text, .flags = .{ .exclusive = true } }) catch |err| switch (err) {
            error.PathAlreadyExists => continue,
            else => return err,
        };
        // Something left in `files/` without its `.trashinfo` still
        // holds the name.
        if (exists(io, dest)) {
            cwd.deleteFile(io, info_path) catch {};
            continue;
        }
        std.Io.Dir.rename(cwd, path, cwd, dest, io) catch |err| {
            cwd.deleteFile(io, info_path) catch {};
            return err;
        };
        return;
    }
    return error.PathAlreadyExists;
}

/// Makes `trash` and its `files/` and `info/`, owner-only, as the spec
/// asks of the home trash.
fn ensureTrashDir(io: std.Io, trash: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    if (std.fs.path.dirname(trash)) |parent| try cwd.createDirPath(io, parent);
    try makeOwnerDir(io, trash);
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    for ([_][]const u8{ "files", "info" }) |sub| {
        const p = std.fmt.bufPrint(&buf, "{s}/{s}", .{ trash, sub }) catch return error.NameTooLong;
        try makeOwnerDir(io, p);
    }
}

/// `ensureTrashDir` for a trash in a shared place: the directory has to
/// be a real one (not a link) owned by `uid`, or it isn't ours to use.
fn ensureOwnTrashDir(io: std.Io, trash: []const u8, uid: u32) !void {
    try makeOwnerDir(io, trash);
    const st = try statNoFollow(trash);
    if (st.mode & std.posix.S.IFMT != std.posix.S.IFDIR) return error.NoTrash;
    if (st.uid != uid) return error.NoTrash;
    try ensureTrashDir(io, trash);
}

/// `mkdir path 0700`; already being there is fine.
fn makeOwnerDir(io: std.Io, path: []const u8) !void {
    std.Io.Dir.cwd().createDir(io, path, .fromMode(0o700)) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
}

fn isStickyDir(path: []const u8) bool {
    const st = statNoFollow(path) catch return false;
    return st.mode & std.posix.S.IFMT == std.posix.S.IFDIR and st.mode & std.posix.S.ISVTX != 0;
}

/// Whether `path` is one of `topdir`'s trash directories itself.
fn isTrashRoot(topdir: []const u8, path: []const u8) bool {
    const parent = std.fs.path.dirname(path) orelse return false;
    if (!std.mem.eql(u8, parent, topdir)) return false;
    const base = std.fs.path.basename(path);
    return std.mem.eql(u8, base, ".Trash") or std.mem.startsWith(u8, base, ".Trash-");
}

/// The top of the mount `path` (whose own `statNoFollow` is `st`) lives
/// on: its highest ancestor still on the same device. Owned.
fn mountTop(alloc: std.mem.Allocator, path: []const u8, st: Stat) ![]u8 {
    var top: []const u8 = std.fs.path.dirname(path) orelse "/";
    while (std.fs.path.dirname(top)) |parent| {
        const pst = statNoFollow(parent) catch break;
        if (!sameDevice(pst, st)) break;
        top = parent;
    }
    return alloc.dupe(u8, top);
}

/// The few `statx` fields the trash rules need.
const Stat = struct {
    dev_major: u32,
    dev_minor: u32,
    mode: u32,
    uid: u32,
};

fn sameDevice(a: Stat, b: Stat) bool {
    return a.dev_major == b.dev_major and a.dev_minor == b.dev_minor;
}

/// `lstat`, through a raw `statx(2)`: `std.Io.File.Stat` has no device
/// or owner (see also `entries.ownerIds`).
fn statNoFollow(path: []const u8) !Stat {
    if (builtin.os.tag != .linux) return error.Unsupported;
    const linux = std.os.linux;
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    if (path.len >= buf.len) return error.NameTooLong;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    var stx: linux.Statx = undefined;
    const rc = linux.statx(linux.AT.FDCWD, buf[0..path.len :0].ptr, linux.AT.SYMLINK_NOFOLLOW, .{ .TYPE = true, .MODE = true, .UID = true }, &stx);
    switch (linux.errno(rc)) {
        .SUCCESS => {},
        .NOENT, .NOTDIR => return error.FileNotFound,
        .ACCES, .PERM => return error.AccessDenied,
        else => return error.Unexpected,
    }
    return .{ .dev_major = stx.dev_major, .dev_minor = stx.dev_minor, .mode = stx.mode, .uid = stx.uid };
}

fn exists(io: std.Io, path: []const u8) bool {
    _ = std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch return false;
    return true;
}

/// `child` is `parent` or beneath it, on whole components.
fn isWithin(child: []const u8, parent: []const u8) bool {
    if (!std.mem.startsWith(u8, child, parent)) return false;
    if (child.len == parent.len) return true;
    if (parent.len > 0 and parent[parent.len - 1] == '/') return true;
    return child[parent.len] == '/';
}
