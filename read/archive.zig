// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: GPL-3.0-or-later

//! Opening a book and pulling one page's bytes out of it.
//!
//! Three sources, one interface:
//!
//! - **`.cbz` / `.zip`** -- read in process with `std.zip`. The central
//!   directory is walked once at open time and each page entry kept, so a
//!   page read is a seek and an inflate with no rescan.
//! - **`.cbr` / `.cb7` (RAR, 7z)** -- there is no RAR decoder in Zig's
//!   std and vendoring one drags in a licence this tree doesn't want, so
//!   these are unpacked once into a temp directory by whichever of
//!   `bsdtar` / `unrar` / `7z` is on `PATH` and then read as a directory.
//!   The temp tree is removed on `deinit`.
//! - **A plain directory** -- read directly. Free, given the extractor
//!   path needs it anyway, and it's how a `mokuro`-processed volume
//!   already sits on disk.
//!
//! The format is decided by the file's own magic bytes, not its
//! extension: `.cbz` files that are actually RAR are common enough that
//! trusting the name gets books wrong (`gw-view` sniffs image containers
//! the same way and for the same reason).

const std = @import("std");
const pages = @import("pages.zig");

/// What the magic bytes said the file is.
pub const Format = enum {
    zip,
    rar,
    sevenzip,
    /// The path was a directory, not an archive at all.
    directory,

    pub fn label(self: Format) []const u8 {
        return switch (self) {
            .zip => "cbz",
            .rar => "cbr",
            .sevenzip => "cb7",
            .directory => "dir",
        };
    }
};

pub const OpenError = error{
    /// `std.zip` couldn't read the central directory, or a page read hit
    /// a stream error partway through.
    Streaming,
    /// The path is neither a directory nor a container we recognise.
    UnknownArchiveFormat,
    /// A RAR/7z book, but none of the external extractors are installed.
    NoExtractorAvailable,
    /// The extractor ran and failed (a corrupt or encrypted archive).
    ExtractFailed,
    /// The archive opened fine but holds no image this reader can decode.
    NoPages,
} || std.mem.Allocator.Error || std.Io.File.OpenError || std.Io.Dir.OpenError ||
    std.Io.Dir.StatFileError;

/// One page, in reading order. `name` is what the statusline shows and
/// what the page sort ran on -- the entry path inside the archive, or the
/// path relative to the directory root.
pub const Page = struct {
    name: []u8,
    ref: Ref,

    const Ref = union(enum) {
        /// A central-directory record, ready to `extractTo`.
        zip: std.zip.Iterator.Entry,
        /// An owned path on disk, absolute or relative to the cwd.
        file: []u8,
    };
};

/// An open book. Heap-allocated by `open` because the zip reader holds a
/// pointer into its own buffer and the page entries reference it -- a
/// by-value `Archive` that got copied would leave both dangling.
pub const Archive = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    format: Format,
    /// The path the user named, owned -- the statusline title and the key
    /// the resume state is stored under.
    path: []u8,
    pages: std.ArrayList(Page) = .empty,
    /// Entries that looked like images but aren't in a format the host
    /// can decode (`.webp`, mostly). Counted rather than listed so the
    /// statusline can say "3 skipped" without holding the names.
    skipped: usize = 0,

    /// Live only for `.zip`. `reader` points into `read_buf`, and every
    /// `Page.Ref.zip` seek goes through it.
    file: ?std.Io.File = null,
    reader: std.Io.File.Reader = undefined,
    read_buf: []u8 = &.{},

    /// Set for an archive that was unpacked to a temp tree, which
    /// `deinit` then removes. Owned.
    temp_dir: ?[]u8 = null,

    /// Buffer for the zip reader. 64 KiB is a compromise: big enough that
    /// inflating a multi-megabyte page isn't a syscall per few KB, small
    /// enough to be unremarkable for a process that holds one book.
    const zip_read_buf_len = 64 * 1024;

    pub fn deinit(self: *Archive) void {
        const alloc = self.alloc;
        for (self.pages.items) |p| {
            alloc.free(p.name);
            switch (p.ref) {
                .file => |f| alloc.free(f),
                .zip => {},
            }
        }
        self.pages.deinit(alloc);
        if (self.file) |f| f.close(self.io);
        if (self.read_buf.len > 0) alloc.free(self.read_buf);
        if (self.temp_dir) |d| {
            // Best effort: a temp tree left behind is untidy, not a
            // reason to fail on the way out.
            std.Io.Dir.cwd().deleteTree(self.io, d) catch {};
            alloc.free(d);
        }
        alloc.free(self.path);
        alloc.destroy(self);
    }

    pub fn count(self: *const Archive) usize {
        return self.pages.items.len;
    }

    /// The bytes of page `index`, freshly allocated -- the caller owns
    /// them and normally hands them straight to `load_image` and frees
    /// them again. Nothing is cached here; the reader's LRU caches the
    /// server-side handle instead (see cache.zig).
    pub fn readPage(self: *Archive, alloc: std.mem.Allocator, index: usize) ![]u8 {
        if (index >= self.pages.items.len) return error.PageOutOfRange;
        switch (self.pages.items[index].ref) {
            .file => |path| return std.Io.Dir.cwd().readFileAlloc(
                self.io,
                path,
                alloc,
                .limited(max_page_bytes),
            ),
            .zip => |entry| {
                var out: std.Io.Writer.Allocating = .init(alloc);
                errdefer out.deinit();
                try entry.extractTo(&self.reader, &out.writer);
                return out.toOwnedSlice();
            },
        }
    }
};

/// Ceiling on one page's decompressed size. A 64 MiB page is already a
/// wildly oversized scan; the limit is here so a zip bomb reports an
/// error instead of eating the machine.
pub const max_page_bytes: usize = 64 * 1024 * 1024;

/// Opens `path` -- an archive or a directory -- and builds the page list.
pub fn open(alloc: std.mem.Allocator, io: std.Io, path: []const u8) OpenError!*Archive {
    const self = try alloc.create(Archive);
    errdefer alloc.destroy(self);

    self.* = .{
        .alloc = alloc,
        .io = io,
        .format = .directory,
        .path = try alloc.dupe(u8, path),
    };
    errdefer alloc.free(self.path);

    const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch |err| switch (err) {
        error.IsDir => {
            try indexDirectory(self, path, path);
            if (self.pages.items.len == 0) return error.NoPages;
            return self;
        },
        else => return err,
    };
    if (stat.kind == .directory) {
        try indexDirectory(self, path, path);
        if (self.pages.items.len == 0) return error.NoPages;
        return self;
    }

    self.format = try sniff(io, path);
    switch (self.format) {
        .zip => try indexZip(self, path),
        .rar, .sevenzip => {
            const dir = try extractExternally(self, path);
            try indexDirectory(self, dir, dir);
        },
        // `sniff` never reports `.directory` for a regular file.
        .directory => unreachable,
    }

    if (self.pages.items.len == 0) return error.NoPages;
    return self;
}

/// Reads the first few bytes and matches them against the container
/// signatures. `error.UnknownArchiveFormat` for anything else -- notably
/// a bare image file, which is `gw-view`'s job, not this one's.
fn sniff(io: std.Io, path: []const u8) OpenError!Format {
    var buf: [8]u8 = undefined;
    const file = try std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_only });
    defer file.close(io);

    var r = file.reader(io, &.{});
    const n = r.interface.readSliceShort(&buf) catch return error.UnknownArchiveFormat;
    const head = buf[0..n];

    // "PK\x03\x04" is a local file header; "PK\x05\x06" is an empty
    // archive's end record, which is still a zip (just one with no pages,
    // caught later as `NoPages`).
    if (std.mem.startsWith(u8, head, "PK\x03\x04")) return .zip;
    if (std.mem.startsWith(u8, head, "PK\x05\x06")) return .zip;
    // RAR 1.5-4.x and RAR 5.0 share the first six bytes.
    if (std.mem.startsWith(u8, head, "Rar!\x1a\x07")) return .rar;
    if (std.mem.startsWith(u8, head, "7z\xbc\xaf\x27\x1c")) return .sevenzip;
    return error.UnknownArchiveFormat;
}

/// Walks the zip's central directory once, keeping every entry that is a
/// page, then sorts them into reading order.
fn indexZip(self: *Archive, path: []const u8) OpenError!void {
    const alloc = self.alloc;

    self.read_buf = try alloc.alloc(u8, Archive.zip_read_buf_len);
    const file = try std.Io.Dir.cwd().openFile(self.io, path, .{ .mode = .read_only });
    self.file = file;
    self.reader = file.reader(self.io, self.read_buf);

    var it = std.zip.Iterator.init(&self.reader) catch return error.UnknownArchiveFormat;
    var name_buf: [std.fs.max_path_bytes]u8 = undefined;

    while (it.next() catch return error.UnknownArchiveFormat) |entry| {
        const name = entry.getFilename(&self.reader, &name_buf, .{}) catch continue;
        if (name.len == 0 or name[name.len - 1] == '/') continue;
        if (!pages.isPage(name)) {
            if (looksLikeImage(name)) self.skipped += 1;
            continue;
        }
        const owned = try alloc.dupe(u8, name);
        errdefer alloc.free(owned);
        try self.pages.append(alloc, .{ .name = owned, .ref = .{ .zip = entry } });
    }

    std.mem.sort(Page, self.pages.items, {}, pageLessThan);
}

/// Recursively collects every page under `dir`. `root` is the directory
/// the book was opened at, so `Page.name` comes out relative to it (the
/// statusline shows `ch01/002.png`, not the whole temp path).
fn indexDirectory(self: *Archive, root: []const u8, dir: []const u8) OpenError!void {
    const alloc = self.alloc;

    var handle = std.Io.Dir.cwd().openDir(self.io, dir, .{ .iterate = true }) catch return;
    defer handle.close(self.io);

    var it = handle.iterate();
    while (it.next(self.io) catch null) |raw| {
        if (raw.name.len == 0 or raw.name[0] == '.') continue;
        if (std.mem.startsWith(u8, raw.name, "__")) continue;

        const full = try std.fs.path.join(alloc, &.{ dir, raw.name });
        errdefer alloc.free(full);

        if (raw.kind == .directory) {
            try indexDirectory(self, root, full);
            alloc.free(full);
            continue;
        }
        if (!pages.hasPageExtension(raw.name)) {
            if (looksLikeImage(raw.name)) self.skipped += 1;
            alloc.free(full);
            continue;
        }

        // `full` starts with `root` by construction; +1 drops the
        // separator. A `root` that is itself the whole path (a single
        // file) can't reach here, so the slice is always in range.
        const rel = if (full.len > root.len + 1) full[root.len + 1 ..] else full;
        const name = try alloc.dupe(u8, rel);
        errdefer alloc.free(name);
        try self.pages.append(alloc, .{ .name = name, .ref = .{ .file = full } });
    }

    // Sorting the whole list after every directory is redundant, but the
    // lists are hundreds of entries at most and it keeps the recursion
    // from needing a "sort once at the top" caller distinct from itself.
    std.mem.sort(Page, self.pages.items, {}, pageLessThan);
}

fn pageLessThan(_: void, a: Page, b: Page) bool {
    return pages.order(a.name, b.name) == .lt;
}

/// An entry that is plainly a picture but not one glyphwire-host can
/// decode -- counted as skipped so the reader can say so rather than
/// silently dropping half a book of `.webp` pages.
fn looksLikeImage(name: []const u8) bool {
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return false;
    var lower: [8]u8 = undefined;
    const ext = name[dot..];
    if (ext.len > lower.len) return false;
    for (ext, 0..) |c, i| lower[i] = std.ascii.toLower(c);
    const e = lower[0..ext.len];
    for ([_][]const u8{ ".webp", ".avif", ".jxl", ".tif", ".tiff", ".heic" }) |candidate| {
        if (std.mem.eql(u8, e, candidate)) return true;
    }
    return false;
}

/// The external unpackers tried, in order. `bsdtar` first: it's
/// libarchive, handles RAR *and* 7z, and is already on most systems as
/// part of the base tools. `unrar` is the reference RAR decoder and
/// handles RAR5 that older libarchive builds don't. `7z` last as the
/// catch-all.
const extractors = [_]struct { exe: []const u8, args: []const []const u8 }{
    .{ .exe = "bsdtar", .args = &.{ "-x", "-f" } },
    .{ .exe = "unrar", .args = &.{ "x", "-y", "-inul" } },
    .{ .exe = "7z", .args = &.{ "x", "-y" } },
};

/// Unpacks a RAR/7z book into a fresh temp directory and returns that
/// path (owned by the archive, removed on `deinit`).
///
/// The whole book is unpacked in one go rather than a page at a time:
/// every one of these tools costs a process spawn and a full archive
/// scan per invocation, so per-page extraction would make each page turn
/// slower than the read it's serving.
fn extractExternally(self: *Archive, path: []const u8) OpenError![]const u8 {
    const alloc = self.alloc;

    // Absolute, because the extractor runs with its cwd set to the temp
    // directory and a relative book path would resolve against that.
    // Same shape as `glyphwire-ls`'s `resolveAbsolutePath`.
    const abs = absolutePath(self.io, alloc, path) catch return error.ExtractFailed;
    defer alloc.free(abs);

    const dir = try makeTempDir(self);
    self.temp_dir = dir;

    for (extractors) |ex| {
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(alloc);
        try argv.append(alloc, ex.exe);
        try argv.appendSlice(alloc, ex.args);
        try argv.append(alloc, abs);

        var child = std.process.spawn(self.io, .{
            .argv = argv.items,
            .cwd = .{ .path = dir },
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
        }) catch continue; // not installed -- try the next one

        const term = child.wait(self.io) catch continue;
        switch (term) {
            // 127 is the shell's "command not found", which a failed
            // `execve` in the forked child also exits with -- treat it as
            // "this extractor isn't really here" and fall through to the
            // next one rather than reporting a corrupt archive.
            .exited => |code| if (code == 0) return dir else if (code != 127) return error.ExtractFailed,
            else => return error.ExtractFailed,
        }
    }
    return error.NoExtractorAvailable;
}

fn absolutePath(io: std.Io, alloc: std.mem.Allocator, path: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(path)) return std.fs.path.resolve(alloc, &.{path});
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = try std.process.currentPath(io, &cwd_buf);
    return std.fs.path.resolve(alloc, &.{ cwd_buf[0..cwd_len], path });
}

/// A private directory under `/tmp`, named from the process id. Not
/// `O_TMPFILE`-style secure -- the contents are pages out of a file the
/// user already has -- just unlikely to collide. The attempt counter
/// covers the two ways a name can already be taken: a second reader in
/// the same pid namespace, and a directory left behind by one that was
/// killed before `deinit` could remove its own.
///
/// `std.os.linux.getpid()` directly, the same as `host/main.zig`,
/// `shell/main.zig` and `agent/main.zig` do -- this reduced std has no
/// portable accessor, and glyphwire is Linux-only today.
fn makeTempDir(self: *Archive) OpenError![]u8 {
    const alloc = self.alloc;
    const pid = std.os.linux.getpid();

    var attempt: u32 = 0;
    while (attempt < 64) : (attempt += 1) {
        const name = try std.fmt.allocPrint(alloc, "/tmp/gw-read-{d}-{d}", .{ pid, attempt });
        errdefer alloc.free(name);
        std.Io.Dir.cwd().createDir(self.io, name, .default_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {
                alloc.free(name);
                continue;
            },
            else => {
                alloc.free(name);
                return error.ExtractFailed;
            },
        };
        return name;
    }
    return error.ExtractFailed;
}
