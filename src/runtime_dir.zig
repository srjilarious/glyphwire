// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: MPL-2.0

//! Where a glyphwire session's sockets live, and keeping them private.
//!
//! The socket is the outer wall of a session: anything that can connect
//! to it can create a context, and with a token act on one. So it goes in
//! a directory only its owner can enter -- `$XDG_RUNTIME_DIR`, which the
//! login manager makes `0700`, or, without one, a `/tmp/glyphwire-<uid>`
//! made the same way -- and the socket itself is `0600` on top of that,
//! so a lax umask can't open it up either.

const std = @import("std");
const linux = std.os.linux;

pub const Error = error{
    /// `/tmp/glyphwire-<uid>` exists but isn't a directory this user owns
    /// with no access for anyone else -- someone may have made it first
    /// to have our sockets land somewhere they can reach.
    UnsafeRuntimeDir,
    RuntimeDirFailed,
} || std.mem.Allocator.Error;

/// The directory to put this session's sockets in, owned by the caller.
/// `$XDG_RUNTIME_DIR` when set; otherwise `/tmp/glyphwire-<uid>`, created
/// `0700` if missing and refused (`UnsafeRuntimeDir`) when it is someone
/// else's or open to group or others.
pub fn runtimeDir(alloc: std.mem.Allocator, environ_map: *const std.process.Environ.Map) Error![]u8 {
    if (environ_map.get("XDG_RUNTIME_DIR")) |dir| {
        if (dir.len > 0) return alloc.dupe(u8, dir);
    }
    const uid = linux.getuid();
    const path = try std.fmt.allocPrintSentinel(alloc, "/tmp/glyphwire-{d}", .{uid}, 0);
    errdefer alloc.free(path);

    const rc = linux.mkdir(path, 0o700);
    switch (linux.errno(rc)) {
        .SUCCESS, .EXIST => {},
        else => return Error.RuntimeDirFailed,
    }
    // Checked whether we made it or found it: `lstat`, so a symlink
    // planted in its place is refused rather than followed.
    var st: linux.Statx = undefined;
    const src = linux.statx(linux.AT.FDCWD, path, linux.AT.SYMLINK_NOFOLLOW, .{ .TYPE = true, .MODE = true, .UID = true }, &st);
    if (linux.errno(src) != .SUCCESS) return Error.RuntimeDirFailed;
    const is_dir = (st.mode & linux.S.IFMT) == linux.S.IFDIR;
    if (!is_dir or st.uid != uid or (st.mode & 0o077) != 0) return Error.UnsafeRuntimeDir;
    return path[0..path.len];
}

/// `<runtimeDir>/<name>`, owned by the caller.
pub fn socketPath(alloc: std.mem.Allocator, environ_map: *const std.process.Environ.Map, name: []const u8) Error![]u8 {
    const dir = try runtimeDir(alloc, environ_map);
    defer alloc.free(dir);
    return std.fmt.allocPrint(alloc, "{s}/{s}", .{ dir, name });
}

/// Makes the socket at `path` owner-only (`0600`). Called right after
/// binding it; best effort, since the directory it is in is already
/// private and a failure here leaves that wall standing.
pub fn restrictSocket(path: []const u8) void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    if (path.len >= buf.len) return;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    const rc = linux.chmod(buf[0..path.len :0].ptr, 0o600);
    if (linux.errno(rc) != .SUCCESS) std.log.warn("glyphwire: couldn't make {s} owner-only", .{path});
}
