// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: GPL-3.0-or-later

//! Directory scanning and per-entry classification shared by the tools
//! that list files: `gw-ls` (`ls/main.zig`) and `salacommander`. Moved
//! out of `ls/main.zig` so the file manager reads a directory, picks an
//! icon and resolves an owner name exactly the way `gw-ls` does, rather
//! than growing a second copy of each.
//!
//! Not pure the way `format.zig`/`icons.zig` are: `listDir` does IO and
//! `ownerIds`/`userName` call into libc, so a binary that uses those links
//! libc (every current consumer already does, for its Lua config).

const std = @import("std");
const builtin = @import("builtin");
const lsfmt = @import("format.zig");
const lsicons = @import("icons.zig");

/// `dir_path` as an absolute, `.`/`..`-normalized path -- resolved against
/// the process's actual cwd if it wasn't already absolute. Every entry's
/// metadata tag (`writeGrid`) embeds its full path this way rather than
/// possibly-relative, since whatever reads it back later (glyphwire-shell's
/// `browseEnter`, eventually other tools) can't be assumed to share this
/// process's cwd.
pub fn resolveAbsolutePath(io: std.Io, alloc: std.mem.Allocator, dir_path: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(dir_path)) return std.fs.path.resolve(alloc, &.{dir_path});
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = try std.process.currentPath(io, &cwd_buf);
    return std.fs.path.resolve(alloc, &.{ cwd_buf[0..cwd_len], dir_path });
}

pub const EntryKind = enum { file, directory, sym_link, other };

pub const FileEntry = struct {
    name: []const u8,
    kind: EntryKind,
    link_target: ?[]const u8, // non-null for symlinks; caller owns memory
    /// For a symlink whose target exists and is itself a plain
    /// directory or file, the target's kind -- what `entryMetadataJson`
    /// tags the entry's *action* metadata with (so activating it behaves
    /// like its target), while `kind` above stays `.sym_link` for
    /// coloring/icon/`-l` type-column purposes. Null for a non-symlink, a
    /// broken symlink, or one pointing at something else (device, fifo,
    /// socket) -- those keep reporting themselves as a plain symlink.
    link_target_kind: ?EntryKind = null,
    /// Absolute, `.`/`..`-normalized path to this entry -- what the
    /// metadata tag's `path` field carries for `glyphwire-shell`'s
    /// `browseEnter`. Stored per entry rather than joined on the fly in
    /// `writeGrid`/`writeLongTable` because a single listing can now mix
    /// entries from different directories (the "loose files" block a
    /// multi-operand run builds -- see `classifyAndList`). Caller owns.
    abs_path: []const u8,
    size: u64 = 0,
    mtime_sec: i64 = 0,
    /// Raw POSIX mode bits (file type nibble + setuid/setgid/sticky +
    /// user/group/all rwx), only populated with `-l` -- see `FileMode`.
    mode: u16 = 0,
    /// Owner / group ids, only populated with `-l` via a raw `statx(2)`
    /// (`std.Io.File.Stat` has no uid/gid). `formatOwnerGroup` resolves
    /// them to names for the Owner column; both stay 0 on a non-Linux
    /// target or a failed stat.
    uid: u32 = 0,
    gid: u32 = 0,
};

/// Follows a symlink (already known to be one, `name` relative to `dir`)
/// via a stat *with* `follow_symlinks = true` -- the target's kind if it
/// resolves to a plain directory or file, else null (a broken link, or a
/// target that's something else again -- device, fifo, socket).
pub fn followSymlinkKind(io: std.Io, dir: std.Io.Dir, name: []const u8) ?EntryKind {
    const st = dir.statFile(io, name, .{ .follow_symlinks = true }) catch return null;
    return switch (st.kind) {
        .directory => .directory,
        .file => .file,
        else => null,
    };
}

/// What `listDir` reads per entry.
pub const ListOptions = struct {
    /// Include dotfiles.
    show_hidden: bool = false,
    /// Stat every entry for size/mtime/mode/owner. Off for a plain `gw-ls`
    /// listing, which shows none of them; a stat is a syscall per entry.
    stat: bool = false,
};

/// Reads `dir_path` into a name-sorted (`sortEntries`) slice the caller
/// frees with `freeEntries`. A directory that can't be opened is an error
/// (`gw-ls` logs it and lists nothing; salacommander stays where it was).
pub fn listDir(io: std.Io, alloc: std.mem.Allocator, dir_path: []const u8, opts: ListOptions) ![]FileEntry {
    var entries: std.ArrayList(FileEntry) = .empty;
    errdefer {
        for (entries.items) |e| freeEntry(alloc, e);
        entries.deinit(alloc);
    }

    var dir = try std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
    defer dir.close(io);

    // Resolved once here; each entry's `abs_path` is this joined with the
    // entry name (see `FileEntry.abs_path`).
    const dir_abs = try resolveAbsolutePath(io, alloc, dir_path);
    defer alloc.free(dir_abs);

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (!opts.show_hidden and std.mem.startsWith(u8, entry.name, ".")) continue;

        const kind: EntryKind = switch (entry.kind) {
            .directory => .directory,
            .file => .file,
            .sym_link => .sym_link,
            else => .other,
        };

        var link_target: ?[]const u8 = null;
        var link_target_kind: ?EntryKind = null;
        if (kind == .sym_link) {
            var target_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            if (dir.readLink(io, entry.name, &target_buf)) |len| {
                link_target = try alloc.dupe(u8, target_buf[0..len]);
            } else |_| {}
            link_target_kind = followSymlinkKind(io, dir, entry.name);
        }
        errdefer if (link_target) |t| alloc.free(t);

        // Only stat when -l actually needs it -- a plain listing has no
        // use for size/mtime/mode/owner, and stat is a syscall per entry.
        var size: u64 = 0;
        var mtime_sec: i64 = 0;
        var mode: u16 = 0;
        var uid: u32 = 0;
        var gid: u32 = 0;
        if (opts.stat) {
            if (dir.statFile(io, entry.name, .{ .follow_symlinks = false })) |st| {
                size = st.size;
                mtime_sec = st.mtime.toSeconds();
                // `Stat.permissions` wraps the same raw POSIX mode bits
                // `fstatat`'s `st_mode` gives (see `std.Io.File.statFromPosix`
                // in std's Threaded.zig backend) -- no manual `fstatat`
                // binding needed just for permission bits.
                mode = @truncate(st.permissions.toMode());
            } else |_| {}
            // uid/gid aren't in `std.Io.File.Stat`, so a second, raw
            // `statx(2)` just for those two -- relative to this open
            // directory's handle, same "don't follow symlinks" choice.
            const ids = ownerIds(dir.handle, entry.name);
            uid = ids.uid;
            gid = ids.gid;
        }

        const name_copy = try alloc.dupe(u8, entry.name);
        errdefer alloc.free(name_copy);
        const abs_path = try std.fs.path.join(alloc, &.{ dir_abs, entry.name });
        errdefer alloc.free(abs_path);
        try entries.append(alloc, .{
            .name = name_copy,
            .kind = kind,
            .link_target = link_target,
            .link_target_kind = link_target_kind,
            .abs_path = abs_path,
            .size = size,
            .mtime_sec = mtime_sec,
            .mode = mode,
            .uid = uid,
            .gid = gid,
        });
    }

    sortEntries(entries.items);
    return entries.toOwnedSlice(alloc);
}

/// Case-insensitive by name (ASCII fold), with a raw-byte tie-break so
/// `"Foo"`/`"foo"` keep a fixed order -- matches the `case_insensitive`
/// Name column in the `-l` table, so the plain listing and a Name-header
/// click show the same order.
pub fn sortEntries(entries: []FileEntry) void {
    std.mem.sort(FileEntry, entries, {}, struct {
        fn lessThan(_: void, a: FileEntry, b: FileEntry) bool {
            return nameLessThan(a.name, b.name);
        }
    }.lessThan);
}

/// `sortEntries`'s name order, for a caller sorting on more than the name
/// (salacommander puts directories first, then this).
pub fn nameLessThan(a: []const u8, b: []const u8) bool {
    const n = @min(a.len, b.len);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const la = std.ascii.toLower(a[i]);
        const lb = std.ascii.toLower(b[i]);
        if (la != lb) return la < lb;
    }
    if (a.len != b.len) return a.len < b.len;
    return std.mem.lessThan(u8, a, b);
}

pub fn freeEntries(alloc: std.mem.Allocator, entries: []const FileEntry) void {
    for (entries) |e| freeEntry(alloc, e);
    alloc.free(entries);
}

/// Frees the strings one entry owns (not the entry itself).
pub fn freeEntry(alloc: std.mem.Allocator, e: FileEntry) void {
    alloc.free(e.name);
    if (e.link_target) |t| alloc.free(t);
    alloc.free(e.abs_path);
}

// ── Icons ──────────────────────────────────────────────────────────────────

/// The icon-catalog name for one entry (see `ls/icons.zig` for the tables
/// and the `dev/*` vs `file/*` split), keyed off the entry's *effective*
/// kind -- a symlink whose target resolves (`FileEntry.link_target_kind`)
/// picks its icon exactly like a real entry of that kind would, same as
/// `entryMetadataJson` resolves its `open_actions` kind:
///
///   * directory (real, or a symlink to one) -- its `dev/*` tool logo if
///     the basename is well-known (`.vscode`, `.claude`, `.git`,
///     `node_modules`, ...), else `"file/folder"`.
///   * regular file (real, or a symlink to one) -- its `dev/*` logo by
///     exact basename (`Dockerfile`, ...) or by extension (`.zig` ->
///     `dev/zig`, `.ex` -> `dev/elixir`, ...), falling back through the
///     coarse `file/*` file-type buckets to `"file/file"` for an
///     unrecognized one.
///   * a symlink whose target doesn't resolve to a file or directory
///     (broken, or pointing at a device/fifo/socket) -- `"file/file"`
///     (no dedicated symlink icon in the bundled set yet).
///   * anything else (device files, sockets, ...) -- `"file/unknown"`.
pub fn iconForEntry(entry: FileEntry) []const u8 {
    const effective_kind = entry.link_target_kind orelse entry.kind;
    return switch (effective_kind) {
        .directory => lsicons.iconForDirName(entry.name) orelse "file/folder",
        .sym_link => "file/file",
        .other => "file/unknown",
        .file => lsicons.iconForFileName(entry.name) orelse lsicons.iconForExtension(entry.name),
    };
}

/// Real MIME types, unlike `ls/icons.zig`'s coarser display buckets --
/// this is the `mimetype` field a regular file's metadata tag carries
/// (see `entryMetadataJson` / `writeGrid`); `glyphwire-shell` keys its
/// `open_actions` table off it (`image/png`, then the `image/*` group,
/// then the entry `kind`). Not exhaustive, just the same common types
/// `ls/icons.zig` already covers plus a handful of text/code extensions
/// worth having a real type for.
const extension_mimetypes = [_]struct { ext: []const u8, mime: []const u8 }{
    .{ .ext = ".png", .mime = "image/png" },
    .{ .ext = ".jpg", .mime = "image/jpeg" },
    .{ .ext = ".jpeg", .mime = "image/jpeg" },
    .{ .ext = ".gif", .mime = "image/gif" },
    .{ .ext = ".bmp", .mime = "image/bmp" },
    .{ .ext = ".svg", .mime = "image/svg+xml" },
    .{ .ext = ".webp", .mime = "image/webp" },

    .{ .ext = ".mp3", .mime = "audio/mpeg" },
    .{ .ext = ".wav", .mime = "audio/wav" },
    .{ .ext = ".flac", .mime = "audio/flac" },
    .{ .ext = ".ogg", .mime = "audio/ogg" },
    .{ .ext = ".m4a", .mime = "audio/mp4" },

    .{ .ext = ".mp4", .mime = "video/mp4" },
    .{ .ext = ".mkv", .mime = "video/x-matroska" },
    .{ .ext = ".mov", .mime = "video/quicktime" },
    .{ .ext = ".webm", .mime = "video/webm" },
    .{ .ext = ".avi", .mime = "video/x-msvideo" },

    .{ .ext = ".zip", .mime = "application/zip" },
    .{ .ext = ".tar", .mime = "application/x-tar" },
    .{ .ext = ".gz", .mime = "application/gzip" },
    .{ .ext = ".tgz", .mime = "application/gzip" },
    .{ .ext = ".xz", .mime = "application/x-xz" },
    .{ .ext = ".bz2", .mime = "application/x-bzip2" },
    .{ .ext = ".7z", .mime = "application/x-7z-compressed" },
    .{ .ext = ".rar", .mime = "application/vnd.rar" },
    .{ .ext = ".iso", .mime = "application/x-iso9660-image" },

    .{ .ext = ".sh", .mime = "application/x-sh" },
    .{ .ext = ".exe", .mime = "application/vnd.microsoft.portable-executable" },
    .{ .ext = ".appimage", .mime = "application/x-executable" },
    .{ .ext = ".bin", .mime = "application/octet-stream" },

    .{ .ext = ".txt", .mime = "text/plain" },
    .{ .ext = ".md", .mime = "text/markdown" },
    .{ .ext = ".json", .mime = "application/json" },
    .{ .ext = ".html", .mime = "text/html" },
    .{ .ext = ".htm", .mime = "text/html" },
    .{ .ext = ".css", .mime = "text/css" },
    .{ .ext = ".js", .mime = "text/javascript" },
    .{ .ext = ".xml", .mime = "application/xml" },
    .{ .ext = ".pdf", .mime = "application/pdf" },
    .{ .ext = ".csv", .mime = "text/csv" },
    .{ .ext = ".yaml", .mime = "application/yaml" },
    .{ .ext = ".yml", .mime = "application/yaml" },
    .{ .ext = ".toml", .mime = "application/toml" },

    .{ .ext = ".doc", .mime = "application/msword" },
    .{ .ext = ".docx", .mime = "application/vnd.openxmlformats-officedocument.wordprocessingml.document" },
    .{ .ext = ".odt", .mime = "application/vnd.oasis.opendocument.text" },
    .{ .ext = ".rtf", .mime = "application/rtf" },
    .{ .ext = ".xls", .mime = "application/vnd.ms-excel" },
    .{ .ext = ".xlsx", .mime = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet" },
    .{ .ext = ".ods", .mime = "application/vnd.oasis.opendocument.spreadsheet" },
    .{ .ext = ".ppt", .mime = "application/vnd.ms-powerpoint" },
    .{ .ext = ".pptx", .mime = "application/vnd.openxmlformats-officedocument.presentationml.presentation" },
    .{ .ext = ".odp", .mime = "application/vnd.oasis.opendocument.presentation" },
    .{ .ext = ".deb", .mime = "application/vnd.debian.binary-package" },
    .{ .ext = ".rpm", .mime = "application/x-rpm" },

    .{ .ext = ".c", .mime = "text/x-c" },
    .{ .ext = ".h", .mime = "text/x-c" },
    .{ .ext = ".cpp", .mime = "text/x-c++" },
    .{ .ext = ".py", .mime = "text/x-python" },
    .{ .ext = ".zig", .mime = "text/x-zig" },
    .{ .ext = ".rs", .mime = "text/rust" },
    .{ .ext = ".go", .mime = "text/x-go" },
};

/// The `kind` string for one of the four `EntryKind` values --
/// `glyphwire-shell`'s `open_actions` accepts each as a fallback key.
/// `entryMetadataJson` is the only caller, and passes a symlink's
/// *effective* kind (see `FileEntry.link_target_kind`) rather than
/// `.sym_link` itself whenever the target resolves to a plain file or
/// directory -- display (icon/color/`-l` type column) still always uses
/// the entry's real `.kind`, untouched by any of this.
pub fn entryKindName(kind: EntryKind) []const u8 {
    return switch (kind) {
        .file => "file",
        .directory => "directory",
        .sym_link => "symlink",
        .other => "other",
    };
}

/// The JSON metadata blob an entry's cells are tagged with (`create_metadata`,
/// one per entry -- see `writeGrid` / `writeLongTable`). Always carries a
/// `kind` and absolute `path`; a regular file additionally carries a real
/// extension-derived `mimetype` (falling back to
/// `"application/octet-stream"` for an unknown extension). No command is
/// embedded: deciding what to *do* on activation is entirely the reader's
/// policy (`shell/openaction.zig`'s `open_actions` table).
///
/// A symlink reports `kind`/`mimetype` as if it *were* its target -- a
/// link to a directory tags `"directory"` (so the shell's default `cd`
/// action fires), a link to a file tags `"file"` plus that mimetype (so
/// e.g. a link to a `.png` triggers the same default image-preview action
/// a real `.png` would) -- alongside a `symlink` boolean (true only for an
/// actual link) so nothing reading the metadata loses the fact. A broken
/// link, or one pointing at something that's neither a file nor a
/// directory (device, fifo, socket), keeps reporting itself plainly as
/// `"symlink"` with no mimetype and no default action, same as before this
/// changed -- see `FileEntry.link_target_kind`.
pub fn entryMetadataJson(alloc: std.mem.Allocator, entry: FileEntry) ![]u8 {
    const effective_kind = entry.link_target_kind orelse entry.kind;
    const kind = entryKindName(effective_kind);
    const symlink = entry.kind == .sym_link;
    return switch (effective_kind) {
        .file => std.json.Stringify.valueAlloc(alloc, .{
            .kind = kind,
            .path = entry.abs_path,
            .mimetype = mimetypeForExtension(entry.name),
            .symlink = symlink,
        }, .{}),
        else => std.json.Stringify.valueAlloc(alloc, .{
            .kind = kind,
            .path = entry.abs_path,
            .symlink = symlink,
        }, .{}),
    };
}

pub fn mimetypeForExtension(name: []const u8) []const u8 {
    const ext = std.fs.path.extension(name);
    for (extension_mimetypes) |e| {
        if (std.ascii.eqlIgnoreCase(ext, e.ext)) return e.mime;
    }
    return "application/octet-stream";
}

/// One-field extern views of glibc's `struct passwd` / `struct group`.
/// Only the leading name pointer is ever read (it's the first member of
/// both structs), so the rest of each layout -- which varies by libc and
/// is why Zig's reduced std dropped its own `stat` wrappers -- doesn't
/// matter here. `glyphwire-ls` already links libc (`build.zig`).
const pwlib = struct {
    const passwd = extern struct { pw_name: ?[*:0]const u8 };
    const group = extern struct { gr_name: ?[*:0]const u8 };
    extern "c" fn getpwuid(uid: c_uint) ?*passwd;
    extern "c" fn getgrgid(gid: c_uint) ?*group;
};

pub const OwnerIds = struct { uid: u32, gid: u32 };

/// uid/gid for one entry, via a raw `statx(2)`. `dir_fd` is the handle
/// `name` is resolved against (`std.Io.Dir.handle`); pass
/// `std.Io.Dir.cwd().handle` (`AT.FDCWD`) for an absolute path. Zig's
/// reduced std removed the libc-independent Linux `stat` wrappers and
/// `std.Io.File.Stat` omits uid/gid on purpose, so this raw syscall is
/// the lowest-friction way to get just those two fields. Returns
/// `{ 0, 0 }` on any failure or on a non-Linux target -- the Owner column
/// then reads `0:0`, and uid 0 still resolves to `root` for the name.
pub fn ownerIds(dir_fd: std.posix.fd_t, name: []const u8) OwnerIds {
    if (builtin.os.tag != .linux) return .{ .uid = 0, .gid = 0 };
    const linux = std.os.linux;
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    if (name.len >= path_buf.len) return .{ .uid = 0, .gid = 0 };
    @memcpy(path_buf[0..name.len], name);
    path_buf[name.len] = 0;
    var stx: linux.Statx = undefined;
    const rc = linux.statx(
        dir_fd,
        path_buf[0..name.len :0].ptr,
        linux.AT.SYMLINK_NOFOLLOW,
        .{ .UID = true, .GID = true },
        &stx,
    );
    if (linux.errno(rc) != .SUCCESS) return .{ .uid = 0, .gid = 0 };
    return .{ .uid = stx.uid, .gid = stx.gid };
}

/// `"owner:group"` for the Owner column, resolving each id to a name and
/// falling back to its decimal form when the lookup returns null (an id
/// with no passwd/group entry -- e.g. a file from another user
/// namespace). The returned slice borrows `buf`, which needs room for
/// two names plus a colon (callers give it 160 bytes).
pub fn ownerGroupText(buf: []u8, uid: u32, gid: u32) []const u8 {
    var owner_num: [16]u8 = undefined;
    var group_num: [16]u8 = undefined;
    // `getpwuid` and `getgrgid` each return a pointer into their own,
    // distinct libc static buffer, so the first result stays valid across
    // the second call; `formatOwnerGroup`'s `bufPrint` copies both out
    // before either could be reused.
    return lsfmt.formatOwnerGroup(buf, userName(uid, &owner_num), groupName(gid, &group_num));
}

pub fn userName(uid: u32, num_buf: []u8) []const u8 {
    if (builtin.os.tag == .linux) {
        if (pwlib.getpwuid(uid)) |pw| {
            if (pw.pw_name) |n| return std.mem.span(n);
        }
    }
    return std.fmt.bufPrint(num_buf, "{d}", .{uid}) catch num_buf[0..0];
}

pub fn groupName(gid: u32, num_buf: []u8) []const u8 {
    if (builtin.os.tag == .linux) {
        if (pwlib.getgrgid(gid)) |gr| {
            if (gr.gr_name) |n| return std.mem.span(n);
        }
    }
    return std.fmt.bufPrint(num_buf, "{d}", .{gid}) catch num_buf[0..0];
}
