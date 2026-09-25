// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: GPL-3.0-or-later

const std = @import("std");

/// The `$PWD`-style logical working directory glyphwire-shell shows in its
/// prompt and exports to spawned children, kept the way bash/fish keep
/// theirs: purely as a string, never round-tripped through the real
/// filesystem. `cd`ing into a symlinked directory (`~/download ->
/// /mnt/shares/downloads`) then shows `~/download`, not the physical
/// target -- the kernel resolves the symlink when the shell actually
/// `chdir`s there, but the *displayed* path keeps whatever name was typed.
///
/// `resolve` is `Prompt.chdir`'s one piece of non-trivial logic, pulled
/// out here (no IO, no allocator-owned state beyond the one return value)
/// so it can be tested without a real filesystem.

/// The new logical path after `cd`ing from `base` (the current `$PWD`) to
/// `target`. An absolute `target` replaces `base` outright; a relative one
/// is joined onto it. Either way the join is lexical only -- `.`/`..`
/// components collapse against the string, exactly like `std.fs.path`
/// join/resolve and POSIX's own `cd` algorithm, never by consulting the
/// filesystem -- so `cd ..` from inside a symlinked directory returns to
/// the symlink's *own* parent, not the parent of whatever it points at.
/// Caller owns the result.
pub fn resolve(alloc: std.mem.Allocator, base: []const u8, target: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(target)) return std.fs.path.resolve(alloc, &.{target});
    return std.fs.path.resolve(alloc, &.{ base, target });
}

/// Returns `path` with a leading `home` replaced by `~` (`~` alone for
/// exactly `home`), written into `buf`. Falls back to `path` unchanged
/// when `home` is null or empty, isn't a prefix, or `buf` is too small.
///
/// Here rather than on `Prompt` -- where it started, as the prompt's
/// `{cwd}` token -- because Alt+D's `cd ~/...` line (`Prompt.cdCwdLine`)
/// needs the same spelling, and a pure two-slices-in function is testable
/// without a live prompt the way the rest of this file is.
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
