// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: MPL-2.0

//! Spelling a path the way a person reads it: `$HOME` as `~`. The
//! shell's prompt and Alt+D line show the working directory this way,
//! and zoe's tab tooltip shows a buffer's file this way. `expandHome`
//! reads it back the other way, for a path typed on zoe's `:` line or
//! the shell's. The `~` helpers are pure -- the caller looks `$HOME` up
//! and passes it in.
//!
//! `absolute` / `absoluteBuf` make a typed path absolute against the
//! process cwd (gw-grep, gw-read, gwmd, zoe).

const std = @import("std");

/// `path` made absolute against the cwd and normalized (`..`, `.`, a
/// trailing `/`), owned by `alloc`.
pub fn absolute(io: std.Io, alloc: std.mem.Allocator, path: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(path)) return std.fs.path.resolve(alloc, &.{path});
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = try std.process.currentPath(io, &cwd_buf);
    return std.fs.path.resolve(alloc, &.{ cwd_buf[0..cwd_len], path });
}

/// `absolute` into `buf` instead of an allocation. Null when it doesn't
/// fit or the cwd can't be read.
pub fn absoluteBuf(io: std.Io, path: []const u8, buf: []u8) ?[]const u8 {
    var fba: std.heap.FixedBufferAllocator = .init(buf);
    return absolute(io, fba.allocator(), path) catch null;
}

/// Whether `path` starts with a `~` that `expandHome` would expand: `~`
/// alone or `~/...` (not `~user`).
pub fn isHomeRelative(path: []const u8) bool {
    return path.len > 0 and path[0] == '~' and (path.len == 1 or path[1] == '/');
}

/// `expandHome` into a fresh allocation, which the caller always owns: a
/// copy of `path` itself when there's nothing to expand or no `home`.
pub fn expandHomeAlloc(alloc: std.mem.Allocator, path: []const u8, home: ?[]const u8) ![]u8 {
    const h = home orelse return alloc.dupe(u8, path);
    if (h.len == 0 or !isHomeRelative(path)) return alloc.dupe(u8, path);
    return std.mem.concat(alloc, u8, &.{ h, path[1..] });
}

/// Returns `path` with a leading `home` replaced by `~` (`~` alone for
/// exactly `home`), written into `buf`. Falls back to `path` unchanged
/// when `home` is null or empty, isn't a prefix, or `buf` is too small.
pub fn collapseHome(path: []const u8, home: ?[]const u8, buf: []u8) []const u8 {
    const h = home orelse return path;
    if (h.len == 0 or !std.mem.startsWith(u8, path, h)) return path;
    if (path.len == h.len) return "~";
    if (path[h.len] != '/') return path; // `/home/foobar` isn't under `/home/foo`
    const rest = path[h.len..];
    if (rest.len + 1 > buf.len) return path;
    buf[0] = '~';
    @memcpy(buf[1 .. rest.len + 1], rest);
    return buf[0 .. rest.len + 1];
}

/// The other direction, for a path a person typed: a leading `~` (alone,
/// or followed by `/`) becomes `home`, written into `buf`. `~user` is
/// left as it is -- looking up another account's home is the shell's
/// business, not an editor's -- and so is everything when `home` is null
/// or empty or `buf` is too small, leaving the caller with the path it
/// was given rather than half of one.
pub fn expandHome(path: []const u8, home: ?[]const u8, buf: []u8) []const u8 {
    const h = home orelse return path;
    if (h.len == 0 or !isHomeRelative(path)) return path;
    const rest = path[1..];
    if (h.len + rest.len > buf.len) return path;
    @memcpy(buf[0..h.len], h);
    @memcpy(buf[h.len .. h.len + rest.len], rest);
    return buf[0 .. h.len + rest.len];
}
