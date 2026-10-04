// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: MPL-2.0

//! The small, single-entry file operations a listing offers in place:
//! make a directory, make an empty file, rename an entry where it stands.
//! salacommander's F7 and F2 and zoe's sidebar (`a`, `r`/F2, F7,
//! Shift+F4) share them, so both refuse the same names and neither ever
//! replaces something that already exists -- a create or rename that
//! would collide is an error the caller shows, and nothing is touched.
//!
//! The multi-source copy/move/delete machinery stays in
//! `salacommander/fileops.zig`; nothing else needs it.

const std = @import("std");

/// Creates `path` and any missing parents, the way MC's F7 accepts
/// `a/b/c`. An existing entry at `path` is `error.PathAlreadyExists`, so
/// the caller can say so rather than silently doing nothing.
pub fn makeDir(io: std.Io, path: []const u8) !void {
    if (exists(io, path)) return error.PathAlreadyExists;
    try std.Io.Dir.cwd().createDirPath(io, path);
}

/// Creates `path` as an empty file, making any missing parent
/// directories first (so `sub/new.zig` works from a listing of the
/// parent). An existing entry is `error.PathAlreadyExists`; the create
/// itself is exclusive too, so a file that appears between the check and
/// the create is still never truncated.
pub fn makeFile(io: std.Io, path: []const u8) !void {
    if (exists(io, path)) return error.PathAlreadyExists;
    const cwd = std.Io.Dir.cwd();
    if (std.fs.path.dirname(path)) |parent| try cwd.createDirPath(io, parent);
    const f = try cwd.createFile(io, path, .{ .exclusive = true });
    f.close(io);
}

/// Checks a name typed into a rename field. A rename stays within the
/// entry's directory and nothing else -- moving is another operation --
/// so a `/` is refused rather than read as a path, as are `.` and `..`,
/// which name directories that already exist. NUL can't be in a filename
/// at all.
pub fn checkNewName(name: []const u8) error{ EmptyName, InvalidName }!void {
    if (name.len == 0) return error.EmptyName;
    if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return error.InvalidName;
    if (std.mem.indexOfAny(u8, name, "/\x00") != null) return error.InvalidName;
}

/// Checks a path typed to create something under a listing's directory
/// (zoe's `a`: `new.zig`, `sub/dir/`, `sub/new.zig`). It has to stay
/// under that directory, so an absolute path and any `.` or `..`
/// component are refused, as is an empty one (just slashes) and NUL. A
/// trailing `/` is allowed -- it is what asks for a directory.
pub fn checkNewPath(path: []const u8) error{ EmptyName, InvalidName }!void {
    const body = std.mem.trimEnd(u8, path, "/");
    if (body.len == 0) return error.EmptyName;
    if (body[0] == '/' or std.mem.indexOfScalar(u8, body, 0) != null) return error.InvalidName;
    var it = std.mem.splitScalar(u8, body, '/');
    while (it.next()) |seg| {
        if (seg.len == 0 or std.mem.eql(u8, seg, ".") or std.mem.eql(u8, seg, "..")) return error.InvalidName;
    }
}

/// Renames `old` to `new` inside `dir`. Never replaces anything: an
/// existing `new` is `error.PathAlreadyExists` and nothing is touched,
/// so the field can stay open for another try. `new` is checked with
/// `checkNewName` first.
pub fn renameInDir(io: std.Io, alloc: std.mem.Allocator, dir: []const u8, old: []const u8, new: []const u8) !void {
    try checkNewName(new);
    const src = try std.fs.path.join(alloc, &.{ dir, old });
    defer alloc.free(src);
    const dest = try std.fs.path.join(alloc, &.{ dir, new });
    defer alloc.free(dest);
    if (exists(io, dest)) return error.PathAlreadyExists;
    const cwd = std.Io.Dir.cwd();
    try std.Io.Dir.rename(cwd, src, cwd, dest, io);
}

/// Where a rename field puts the caret in `name`: before the extension,
/// so the part usually changed is right there and the extension is kept
/// by default. At the end for a directory (`src.old` is a name, not a
/// type), for a dotfile with no second dot, and for a name with no dot
/// at all.
pub fn renameCaret(name: []const u8, is_dir: bool) usize {
    if (is_dir) return name.len;
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return name.len;
    if (dot == 0) return name.len;
    return dot;
}

/// Whether anything -- file, directory, dangling symlink -- is at `path`.
pub fn exists(io: std.Io, path: []const u8) bool {
    _ = std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch return false;
    return true;
}
