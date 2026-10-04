// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: MPL-2.0

//! Spelling a path the way a person reads it: `$HOME` as `~`. The
//! shell's prompt and Alt+D line show the working directory this way,
//! and zoe's tab tooltip shows a buffer's file this way. `expandHome`
//! reads it back the other way, for a path typed on zoe's `:` line.
//! Pure -- the caller looks `$HOME` up and passes it in.

const std = @import("std");

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
    if (h.len == 0 or path.len == 0 or path[0] != '~') return path;
    if (path.len > 1 and path[1] != '/') return path;
    const rest = path[1..];
    if (h.len + rest.len > buf.len) return path;
    @memcpy(buf[0..h.len], h);
    @memcpy(buf[h.len .. h.len + rest.len], rest);
    return buf[0 .. h.len + rest.len];
}
