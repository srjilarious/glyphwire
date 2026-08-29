const std = @import("std");
const glyphwire = @import("glyphwire");
const zargs = @import("zargunaught");
const gridlayout = @import("ls_support").gridlayout;
const lsfmt = @import("ls_support").format;

/// glyphwire-ls: a directory listing built on `lsz`'s core scanning logic
/// (see /home/jeffdw/code/lsz/src/main.zig) but re-targeted to draw over a
/// glyphwire connection instead of ANSI escapes -- the first real-world
/// client meant to be launched from glyphwire-shell's prompt (see
/// shell/main.zig's `runCommand`), to exercise the shell/client path
/// against something more than the styled-text demo. Falls back to a
/// plain newline-per-entry stdout listing (the same content a
/// non-glyphwire `ls` would produce) when no session is available, per
/// decisions.md's Discovery & Connection.
///
/// Deliberately narrower than lsz: no full permission-bit/
/// owner/group columns (would need the same raw `fstatat`/`getpwuid`/
/// `getgrgid` C bindings lsz uses -- `-l` here sticks to what
/// `std.Io.Dir.statFile`'s cross-platform `Stat` already gives: size and
/// modified time) -- directory/symlink/file coloring plus a trailing `/`
/// or ` -> target` covers the rest of what lsz's coloring conveys. lsz
/// itself stays the terminal tool; this is a demonstration client, not a
/// replacement.
///
/// The plain (non `-l`) listing *does* now pack into columns like a
/// terminal `ls`: `get_property("size")` exposes the layer's width in
/// cells (it didn't when this was first written), so `writeGrid` fits as
/// many entry columns across it as the longest name allows and fills
/// them column-major (see `ls_support`/`gridlayout.zig`). The `-l`
/// listing stays a single server-side `Table`.
///
/// Each entry does get a per-type icon (`draw_icon`, see `iconForEntry`):
/// a real Nerd-Font-style per-extension glyph set was ruled out for lsz's
/// terminal output (the bundled JetBrainsMono-Regular.ttf isn't
/// Nerd-Font-patched, so those glyphs would render as tofu), but that
/// limitation doesn't apply here -- glyphwire's icons are small bitmap
/// images (the default Oxygen-icon registry, see core.zig's
/// `default_icon_manifest`), not font glyphs, so no font patching is
/// needed. Requires whatever's serving the connection to have actually
/// loaded that registry (glyphwire-host does, at startup); run against a
/// bare `glyphwire-server` with nothing registered, `draw_icon` would
/// error server-side and drop the connection -- not handled specially
/// here since glyphwire-ls is meant to run under glyphwire-host anyway.
///
/// Arg parsing is zargunaught, the same library and pattern lsz itself
/// uses (`zargs.ArgParser` + `hasOption`/`positional`), ported over
/// rather than hand-rolling another arg loop.
pub fn main(init: std.process.Init) !void {
    const alloc = init.gpa;
    const io = init.io;

    var parser = try zargs.ArgParser.init(alloc, .{
        .name = "ls",
        .description = "Lists the contents of a directory, drawn over a glyphwire connection.",
        .opts = &.{
            .{ .longName = "hidden", .shortName = "a", .description = "Show hidden files and directories", .maxNumParams = 0 },
            .{ .longName = "long", .shortName = "l", .description = "Long listing: adds size and modified time", .maxNumParams = 0 },
            .{ .longName = "large", .shortName = "L", .description = "Large format (the default): bigger, naturally-scaled icons (3-line-tall rows in a long listing). Wins over -S if both are given", .maxNumParams = 0 },
            .{ .longName = "small", .shortName = "S", .description = "Small format: icons fit into one cell/line, in both the normal and long (-l) listing", .maxNumParams = 0 },
            .{ .longName = "human", .shortName = "h", .description = "Human-readable sizes (KB/MB/GB) -- the default; the explicit opposite of --bytes", .maxNumParams = 0 },
            .{ .longName = "bytes", .description = "Show sizes as a raw byte count instead of KB/MB/GB (wins unless -h is also given)", .maxNumParams = 0 },
            .{ .longName = "help", .description = "Print help" },
        },
    });
    defer parser.deinit();

    var args = parser.parse(init.minimal.args) catch |err| {
        std.debug.print("glyphwire-ls: error parsing args: {t}\n", .{err});
        return;
    };
    defer args.deinit();

    if (args.hasOption("help")) {
        var stdout = try zargs.print.Printer.stdout(alloc);
        defer stdout.deinit();
        var help = try zargs.help.HelpFormatter.init(&parser, stdout, zargs.help.DefaultTheme, alloc);
        defer help.deinit();
        help.printHelpText() catch |err| std.debug.print("glyphwire-ls: error printing help: {t}\n", .{err});
        try stdout.flush();
        return;
    }

    const show_hidden = args.hasOption("hidden");
    const long_list = args.hasOption("long");
    const large_flag = args.hasOption("large");
    const small_flag = args.hasOption("small");
    // `--bytes` shows raw byte counts; `-h`/`--human` is the explicit
    // opposite and wins if both are passed (so `ls -h` under an aliased
    // `--bytes` still gets the readable format).
    const raw_bytes = args.hasOption("bytes") and !args.hasOption("human");

    const default_operand = [_][]const u8{"."};
    const operands: []const []const u8 = if (args.positional.items.len > 0) args.positional.items else &default_operand;

    const listings = try classifyAndList(io, alloc, operands, show_hidden, long_list);
    defer freeListings(alloc, listings);

    if (glyphwire.Client.connectFromEnv(io, alloc, init.environ_map)) |connected| {
        var client = connected;
        defer client.deinit();
        // Large icons by default in both views; `-S` opts into small ones
        // (also in both); `-L` wins if both are given, so it can force
        // large back on even under an inherited/aliased `-S`. Resolved
        // here rather than threaded through as three-way state, so
        // `writeGrid`/`writeLongTable` only ever see a plain `large: bool`.
        const large = large_flag or !small_flag;
        for (listings, 0..) |listing, i| {
            // A blank separator row between blocks (only when there's more
            // than one).
            if (i > 0) {
                const c = try client.getCursor();
                try client.setCursor(c.row + 1, 0);
            }
            if (listing.header) |h| {
                const c = try client.getCursor();
                try client.setCursor(c.row, 0);
                try client.writeText(h, header_color, null);
                const c2 = try client.getCursor();
                try client.setCursor(c2.row + 1, 0);
            }
            if (long_list) {
                try writeLongTable(&client, listing.entries, large, raw_bytes);
            } else {
                try writeGrid(&client, listing.entries, large);
            }
        }
    } else |_| {
        try writePlain(io, listings, long_list, raw_bytes);
    }
}

/// `dir_path` as an absolute, `.`/`..`-normalized path -- resolved against
/// the process's actual cwd if it wasn't already absolute. Every entry's
/// metadata tag (`writeGrid`) embeds its full path this way rather than
/// possibly-relative, since whatever reads it back later (glyphwire-shell's
/// `browseEnter`, eventually other tools) can't be assumed to share this
/// process's cwd.
fn resolveAbsolutePath(io: std.Io, alloc: std.mem.Allocator, dir_path: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(dir_path)) return std.fs.path.resolve(alloc, &.{dir_path});
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = try std.process.currentPath(io, &cwd_buf);
    return std.fs.path.resolve(alloc, &.{ cwd_buf[0..cwd_len], dir_path });
}

const EntryKind = enum { file, directory, sym_link, other };

const FileEntry = struct {
    name: []const u8,
    kind: EntryKind,
    link_target: ?[]const u8, // non-null for symlinks; caller owns memory
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
};

/// One rendered block: a group of entries under an optional header. A
/// single-operand run produces exactly one (headerless) `Listing`;
/// multiple operands produce the coreutils layout -- one headerless block
/// for all the non-directory operands, then one headed block per
/// directory operand (see `classifyAndList`).
const Listing = struct {
    /// `"<operand>:"` printed above the entries, or null for a lone
    /// unlabeled block.
    header: ?[]const u8,
    entries: []FileEntry,
};

fn listDir(io: std.Io, alloc: std.mem.Allocator, dir_path: []const u8, show_hidden: bool, long_list: bool) ![]FileEntry {
    var entries: std.ArrayList(FileEntry) = .empty;
    errdefer freeEntries(alloc, entries.items);

    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch |err| {
        std.log.err("glyphwire-ls: cannot open {s}: {t}", .{ dir_path, err });
        return entries.toOwnedSlice(alloc);
    };
    defer dir.close(io);

    // Resolved once here; each entry's `abs_path` is this joined with the
    // entry name (see `FileEntry.abs_path`).
    const dir_abs = try resolveAbsolutePath(io, alloc, dir_path);
    defer alloc.free(dir_abs);

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (!show_hidden and std.mem.startsWith(u8, entry.name, ".")) continue;

        const kind: EntryKind = switch (entry.kind) {
            .directory => .directory,
            .file => .file,
            .sym_link => .sym_link,
            else => .other,
        };

        var link_target: ?[]const u8 = null;
        if (kind == .sym_link) {
            var target_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            if (dir.readLink(io, entry.name, &target_buf)) |len| {
                link_target = try alloc.dupe(u8, target_buf[0..len]);
            } else |_| {}
        }
        errdefer if (link_target) |t| alloc.free(t);

        // Only stat when -l actually needs it -- a plain listing has no
        // use for size/mtime/mode, and stat is a syscall per entry.
        var size: u64 = 0;
        var mtime_sec: i64 = 0;
        var mode: u16 = 0;
        if (long_list) {
            if (dir.statFile(io, entry.name, .{ .follow_symlinks = false })) |st| {
                size = st.size;
                mtime_sec = st.mtime.toSeconds();
                // `Stat.permissions` wraps the same raw POSIX mode bits
                // `fstatat`'s `st_mode` gives (see `std.Io.File.statFromPosix`
                // in std's Threaded.zig backend) -- no libc/manual `fstatat`
                // binding needed just for permission bits, unlike lsz's
                // getpwuid/getgrgid (owner/group *names*, not asked for
                // here), which do need libc.
                mode = @truncate(st.permissions.toMode());
            } else |_| {}
        }

        const name_copy = try alloc.dupe(u8, entry.name);
        errdefer alloc.free(name_copy);
        const abs_path = try std.fs.path.join(alloc, &.{ dir_abs, entry.name });
        errdefer alloc.free(abs_path);
        try entries.append(alloc, .{
            .name = name_copy,
            .kind = kind,
            .link_target = link_target,
            .abs_path = abs_path,
            .size = size,
            .mtime_sec = mtime_sec,
            .mode = mode,
        });
    }

    sortEntries(entries.items);
    return entries.toOwnedSlice(alloc);
}

fn sortEntries(entries: []FileEntry) void {
    std.mem.sort(FileEntry, entries, {}, struct {
        fn lessThan(_: void, a: FileEntry, b: FileEntry) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.lessThan);
}

/// Build a `FileEntry` for a single path named directly on the command
/// line that isn't a directory (a file, a symlink, a device node). Stats
/// it without following symlinks -- a symlink operand shows as
/// `name -> target`, same "don't follow" choice `listDir` makes for a
/// directory's contents -- so a symlink that happens to point at a
/// directory is listed as the link itself, not expanded. Returns null
/// (after logging) if the path can't be stat'd. Caller owns every slice
/// in the result, same as `listDir`'s entries.
fn statOperand(io: std.Io, alloc: std.mem.Allocator, path: []const u8, long_list: bool) !?FileEntry {
    const st = std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch |err| {
        std.log.err("glyphwire-ls: cannot access {s}: {t}", .{ path, err });
        return null;
    };

    const kind: EntryKind = switch (st.kind) {
        .directory => .directory,
        .file => .file,
        .sym_link => .sym_link,
        else => .other,
    };

    var link_target: ?[]const u8 = null;
    if (kind == .sym_link) {
        var target_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        if (std.Io.Dir.cwd().readLink(io, path, &target_buf)) |len| {
            link_target = try alloc.dupe(u8, target_buf[0..len]);
        } else |_| {}
    }
    errdefer if (link_target) |t| alloc.free(t);

    const name_copy = try alloc.dupe(u8, path);
    errdefer alloc.free(name_copy);
    const abs_path = try resolveAbsolutePath(io, alloc, path);

    return .{
        .name = name_copy,
        .kind = kind,
        .link_target = link_target,
        .abs_path = abs_path,
        .size = if (long_list) st.size else 0,
        .mtime_sec = if (long_list) st.mtime.toSeconds() else 0,
        .mode = if (long_list) @truncate(st.permissions.toMode()) else 0,
    };
}

/// Split the command-line operands (default `["."]`) into the coreutils
/// render layout: one headerless `Listing` for every non-directory
/// operand (collected together, name-sorted), followed by one `Listing`
/// per directory operand holding that directory's contents. Headers
/// (`"<operand>:"`) are attached only when there's more than one block to
/// draw -- a lone directory (the common `ls` / `ls somedir` case) stays
/// unlabeled. Directory operands are listed in the order given.
fn classifyAndList(io: std.Io, alloc: std.mem.Allocator, operands: []const []const u8, show_hidden: bool, long_list: bool) ![]Listing {
    var listings: std.ArrayList(Listing) = .empty;
    errdefer {
        for (listings.items) |l| {
            if (l.header) |h| alloc.free(h);
            freeEntries(alloc, l.entries);
        }
        listings.deinit(alloc);
    }

    var loose: std.ArrayList(FileEntry) = .empty;
    errdefer freeEntries(alloc, loose.items);
    var dir_ops: std.ArrayList([]const u8) = .empty;
    defer dir_ops.deinit(alloc);

    for (operands) |op| {
        const is_dir = blk: {
            const st = std.Io.Dir.cwd().statFile(io, op, .{ .follow_symlinks = false }) catch break :blk false;
            break :blk st.kind == .directory;
        };
        if (is_dir) {
            try dir_ops.append(alloc, op);
        } else if (try statOperand(io, alloc, op, long_list)) |entry| {
            try loose.append(alloc, entry);
        }
    }
    sortEntries(loose.items);

    const block_count = dir_ops.items.len + @as(usize, if (loose.items.len > 0) 1 else 0);
    const need_headers = block_count > 1;

    if (loose.items.len > 0) {
        const owned = try loose.toOwnedSlice(alloc); // `loose` is now empty
        listings.append(alloc, .{ .header = null, .entries = owned }) catch |err| {
            freeEntries(alloc, owned);
            return err;
        };
    } else {
        loose.clearAndFree(alloc); // leaves `loose` in the empty state
    }

    for (dir_ops.items) |dir_op| {
        const entries = try listDir(io, alloc, dir_op, show_hidden, long_list);
        const header: ?[]const u8 = if (need_headers)
            std.fmt.allocPrint(alloc, "{s}:", .{dir_op}) catch |err| {
                freeEntries(alloc, entries);
                return err;
            }
        else
            null;
        listings.append(alloc, .{ .header = header, .entries = entries }) catch |err| {
            if (header) |h| alloc.free(h);
            freeEntries(alloc, entries);
            return err;
        };
    }

    return listings.toOwnedSlice(alloc);
}

fn freeEntries(alloc: std.mem.Allocator, entries: []const FileEntry) void {
    for (entries) |e| {
        alloc.free(e.name);
        if (e.link_target) |t| alloc.free(t);
        alloc.free(e.abs_path);
    }
    alloc.free(entries);
}

fn freeListings(alloc: std.mem.Allocator, listings: []Listing) void {
    for (listings) |l| {
        if (l.header) |h| alloc.free(h);
        freeEntries(alloc, l.entries);
    }
    alloc.free(listings);
}

// ── Styling ────────────────────────────────────────────────────────────────

fn rgb(r: u8, g: u8, b: u8) glyphwire.Color {
    return .{ .r = r, .g = g, .b = b, .a = 255 };
}

const dir_color = rgb(98, 114, 164);
const symlink_color = rgb(139, 233, 253);
const file_color = rgb(220, 220, 220);
const detail_color = rgb(120, 120, 120);
/// The `<operand>:` header printed above each block in a multi-operand
/// listing, and the `total ...` summary line (`-l`).
const header_color = rgb(200, 200, 200);

/// Foreground color for a `-l` Size cell, ramped by magnitude so a large
/// file stands out without reading the digits: sub-KB stays the same dim
/// gray the other detail columns use, KB-range is green, MB-range amber,
/// GB-and-up red. A table cell carries one foreground color for its whole
/// text (see `writeLongTable`'s `TableCellInput`), so this is chosen once
/// per entry, not per digit -- the same reason `formatPermBits` doesn't
/// color its flags individually.
fn sizeColor(size: u64) glyphwire.Color {
    if (size < lsfmt.KBytes) return detail_color;
    if (size < lsfmt.MBytes) return rgb(120, 190, 120);
    if (size < lsfmt.GBytes) return rgb(220, 180, 100);
    return rgb(225, 120, 110);
}

// ── Icons ──────────────────────────────────────────────────────────────────

/// Extension (including the leading `.`, case-insensitive) -> default
/// icon-registry name (`core.default_icon_manifest`). Coarse, extension-
/// based classification -- the same thing a mime-type lookup would give
/// for these, without needing an actual mime database dependency just for
/// a handful of buckets.
const extension_icons = [_]struct { ext: []const u8, icon: []const u8 }{
    .{ .ext = ".png", .icon = "image" },
    .{ .ext = ".jpg", .icon = "image" },
    .{ .ext = ".jpeg", .icon = "image" },
    .{ .ext = ".gif", .icon = "image" },
    .{ .ext = ".bmp", .icon = "image" },
    .{ .ext = ".svg", .icon = "image" },
    .{ .ext = ".webp", .icon = "image" },

    .{ .ext = ".mp3", .icon = "audio" },
    .{ .ext = ".wav", .icon = "audio" },
    .{ .ext = ".flac", .icon = "audio" },
    .{ .ext = ".ogg", .icon = "audio" },
    .{ .ext = ".m4a", .icon = "audio" },

    .{ .ext = ".mp4", .icon = "video" },
    .{ .ext = ".mkv", .icon = "video" },
    .{ .ext = ".mov", .icon = "video" },
    .{ .ext = ".webm", .icon = "video" },
    .{ .ext = ".avi", .icon = "video" },

    .{ .ext = ".zip", .icon = "archive" },
    .{ .ext = ".tar", .icon = "archive" },
    .{ .ext = ".gz", .icon = "archive" },
    .{ .ext = ".tgz", .icon = "archive" },
    .{ .ext = ".xz", .icon = "archive" },
    .{ .ext = ".bz2", .icon = "archive" },
    .{ .ext = ".7z", .icon = "archive" },
    .{ .ext = ".rar", .icon = "archive" },

    .{ .ext = ".sh", .icon = "executable" },
    .{ .ext = ".bin", .icon = "executable" },
    .{ .ext = ".exe", .icon = "executable" },
    .{ .ext = ".appimage", .icon = "executable" },

    .{ .ext = ".iso", .icon = "media-optical" },
};

/// The icon-registry name (see `core.default_icon_manifest`) for one
/// entry: `"folder"` for directories, an extension-derived bucket for
/// regular files (`extension_icons`, falling back to `"file"` for an
/// unrecognized extension), `"unknown"` for anything else (device files,
/// sockets, ...). Symlinks reuse `"file"` -- there's no dedicated symlink
/// icon in the bundled set yet.
fn iconForEntry(entry: FileEntry) []const u8 {
    return switch (entry.kind) {
        .directory => "folder",
        .sym_link => "file",
        .other => "unknown",
        .file => iconForExtension(entry.name),
    };
}

fn iconForExtension(name: []const u8) []const u8 {
    const ext = std.fs.path.extension(name);
    for (extension_icons) |e| {
        if (std.ascii.eqlIgnoreCase(ext, e.ext)) return e.icon;
    }
    return "file";
}

/// Real MIME types, unlike `extension_icons`' coarser display buckets --
/// this is the `mimetype` field every entry's metadata tag carries (see
/// `writeGrid`), and `glyphwire-shell`'s `browseEnter` specifically checks
/// for the literal string `"directory"` to decide whether Enter should
/// auto-`cd`. Not exhaustive, just the same common types `extension_icons`
/// already covers plus a handful of text/code extensions worth having a
/// real type for.
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

    .{ .ext = ".c", .mime = "text/x-c" },
    .{ .ext = ".h", .mime = "text/x-c" },
    .{ .ext = ".cpp", .mime = "text/x-c++" },
    .{ .ext = ".py", .mime = "text/x-python" },
    .{ .ext = ".zig", .mime = "text/plain" },
    .{ .ext = ".rs", .mime = "text/rust" },
    .{ .ext = ".go", .mime = "text/x-go" },
};

/// `"directory"` for directories -- the exact value `glyphwire-shell`'s
/// `browseEnter` checks for auto-`cd` -- `"inode/symlink"` for symlinks
/// (not resolved to the target's own type: same "treat uniformly, don't
/// follow" choice `iconForEntry` already makes for symlinks), an
/// extension-derived real MIME type for regular files
/// (`extension_mimetypes`, falling back to `"application/octet-stream"`
/// for an unrecognized extension), and that same generic fallback for
/// anything else (device files, sockets, ...).
fn mimetypeForEntry(entry: FileEntry) []const u8 {
    return switch (entry.kind) {
        .directory => "directory",
        .sym_link => "inode/symlink",
        .other => "application/octet-stream",
        .file => mimetypeForExtension(entry.name),
    };
}

fn mimetypeForExtension(name: []const u8) []const u8 {
    const ext = std.fs.path.extension(name);
    for (extension_mimetypes) |e| {
        if (std.ascii.eqlIgnoreCase(ext, e.ext)) return e.mime;
    }
    return "application/octet-stream";
}

// ── Long-listing formatting ─────────────────────────────────────────────────
//
// The size / permission-bit / timestamp formatters live in the pure
// `ls_support` module (`ls/format.zig`, re-exported here as `lsfmt`) so
// `tests/ls_tests.zig` can exercise them directly.

// ── glyphwire output ──────────────────────────────────────────────────────

/// Native pixel size of the bundled Oxygen icon set (decisions.md's Icon
/// section: "kept at Oxygen's native 32x32") -- needed up front to reserve
/// enough columns for a `.natural`-scaled icon before the name starts.
const icon_native_px = 32;

/// Floor/cap `writeLongTable`'s Name column is clamped to after sizing it
/// from the actual listing (`maxDisplayLen`) -- the floor keeps a listing
/// of all-short names from squeezing the "Name" header itself; the cap
/// keeps one absurdly long symlink target from stretching the whole
/// table (and pushing Size/Perms toward or past the layer's right edge)
/// well past anything a directory listing needs -- `writeCellRun`
/// already truncates-with-ellipsis past this anyway, same as it would
/// for a wider column.
const min_name_width = 8;
const max_name_width = 40;

/// The widest an entry's Name-column content (filename plus its
/// `/`/` -> target` suffix) actually is, in **display cells** -- East
/// Asian wide codepoints count 2, matching how `core.writeText` advances
/// the cursor and `gridlayout.truncateToCols` trims, so this agrees with
/// the truncation math that eventually runs against it. Used to size that
/// column to the *real* data instead of a blind constant (see
/// `min_name_width`/`max_name_width`'s doc comment) -- a fixed width wide
/// enough for a rare long name otherwise either clips shorter ones'
/// siblings (Size/Perms pushed past the layer's edge) or wastes width
/// when every name in this particular listing is short.
fn maxDisplayLen(entries: []const FileEntry) usize {
    var max_len: usize = 0;
    for (entries) |entry| {
        var len = gridlayout.displayWidth(entry.name);
        switch (entry.kind) {
            .directory => len += 1, // trailing "/"
            .sym_link => if (entry.link_target) |tgt| {
                len += 4 + gridlayout.displayWidth(tgt); // " -> "
            },
            else => {},
        }
        max_len = @max(max_len, len);
    }
    return max_len;
}

/// The plain (non `-l`) listing: packs entries into columns across the
/// layer's width like a terminal `ls -C`, starting at the layer's current
/// cursor row and leaving the cursor at the start of the row after the
/// last band -- glyphwire-shell resyncs from `get_property(cursor)` after
/// this process exits (see `Prompt.submitLine`), so there's no fixed row
/// count it needs to guess. Each entry gets a leading icon (`iconForEntry`)
/// before its (possibly truncated) name. See `writeLongTable` for `-l`,
/// which renders as a server-side `Table` instead.
///
/// **Column packing.** `get_property("size")` gives the layer width in
/// cells; `gridlayout.compute` (the pure `ls_support` module) turns that
/// plus the longest entry's display width into a `Grid` -- how many entry
/// columns fit, how many rows per column, and the cell stride between
/// blocks. Fill is **column-major**: entry 0,1,2... run down the first
/// column, then continue in the second, matching `ls -C`. A listing whose
/// longest name doesn't leave room for a second column just comes out
/// single-column, same as before this packing existed (and in that case
/// names are left un-truncated, long symlink targets included).
///
/// `large` (`-L`, see `main`) picks between two icon renderings, and the
/// block height (`Grid.block_rows`) follows:
///
/// - `false` (`-S`): `.fit`-scaled into the icon's single anchor cell,
///   same as a `-l` table's icon at its default `row_height`. One
///   physical row per entry (`block_rows == 1`).
/// - `true` (default): `.natural` sized (capped to `max_icon_h`) instead
///   of `.fit`: at this font's actual cell size a `.fit`-shrunk 32x32
///   icon comes out only a few pixels tall, unrecognizable.
///   `h_align = .start`/`v_align = .center` place it flush against the
///   block's left edge, vertically centered -- growing rightward and
///   vertically. `icon_col_width` (from the icon's own native width, not
///   a fixed constant) reserves room before the name so they don't
///   collide. `max_icon_h` -- two cell-heights -- with centered
///   alignment puts a quarter of the icon above the entry's own row,
///   half on it, a quarter below, so `block_rows == 2` leaves a blank
///   row between bands and one band's icon doesn't overlap the next's
///   text.
///
/// Sends the whole listing as two batches (see decisions.md's Batch
/// section) rather than a call per entry: pass 1 is one `batch` request
/// that creates every entry's metadata tag at once (nothing is drawn, so
/// no half-painted grid is ever visible -- this just collapses N
/// `create_metadata` round trips into one); pass 2 is one `batch`
/// notification carrying every `draw_icon`/`set_property`/`write_text`
/// call, so glyphwire-host composites the finished grid in a single
/// frame instead of visibly painting it a band at a time.
///
/// Because pass 2 can't read the cursor back mid-batch (the old
/// per-band `getCursor`), the draw row is tracked locally:
/// `set_property(cursor)` resolves an out-of-bounds row by scrolling and
/// clamping to the last row (`Layer.resolveRow`), so once a band reaches
/// the bottom every later band draws on that same last row while its
/// trailing cursor move scrolls the listing up --
/// `@min(draw_row + block_rows, rows - 1)` reproduces that clamp exactly.
/// Within a band every column's entry is drawn at that one row, so no
/// scroll happens until the band's trailing `setCursor` advances past it.
///
/// Every entry's metadata tag (below) embeds its `abs_path` -- resolved
/// once when the entry was scanned (see `FileEntry.abs_path`) -- so
/// whatever reads it back (glyphwire-shell's `browseEnter`, eventually
/// other tools) doesn't have to share this process's cwd, and a listing
/// that mixes directories (the multi-operand loose-files block) still
/// tags each entry with its own real path.
fn writeGrid(client: *glyphwire.Client, entries: []const FileEntry, large: bool) !void {
    if (entries.len == 0) return;
    const alloc = client.alloc;
    var buf: [std.Io.Dir.max_path_bytes + 8]u8 = undefined;
    var name_buf: [std.Io.Dir.max_path_bytes + 8]u8 = undefined;

    // Small mode: the icon stays inside its one anchor cell, so the name
    // just needs to start one column over (plus a one-column gap), and
    // each entry only ever occupies its own single physical row.
    var icon_col_width: usize = 2;
    var max_icon_h: u32 = 0;
    var icon_cols_spanned: usize = 1;
    var block_rows: usize = 1;

    if (large) {
        const metrics = try client.getCellMetrics();
        const cell_w: usize = metrics.w;
        const cell_h: usize = metrics.h;
        icon_col_width = (icon_native_px + cell_w - 1) / cell_w + 1;
        max_icon_h = @intCast(2 * cell_h);
        // How many columns (from the anchor) the icon's rendered width
        // actually reaches, so every cell it visually covers -- not just
        // its anchor cell -- can be tagged below. `.natural` scale with
        // only `max_h` set ties width to the same cap (square icons,
        // uniform scale-down -- see `core.IconScale`'s doc comment), so
        // the rendered pixel width is never more than `max_icon_h`.
        const icon_render_px: usize = @min(icon_native_px, max_icon_h);
        icon_cols_spanned = (icon_render_px + cell_w - 1) / cell_w;
        block_rows = 2;
    }

    // Fit as many entry columns across the layer as the longest name
    // allows (single-column if it doesn't fit two), then fill them
    // column-major.
    const layer = try client.getSize();
    const grid = gridlayout.compute(entries.len, maxDisplayLen(entries), layer.cols, .{
        .icon_cols = icon_col_width,
        .block_rows = block_rows,
    });

    const start = try client.getCursor();

    // Pass 1: one batch request creating every entry's metadata tag.
    // Each cell an entry's block touches (icon and name) shares one
    // metadata id -- see decisions.md's Metadata section on tagging a
    // whole run rather than copying the same blob per cell. `mimetype`/
    // `path` are the two fields glyphwire-shell's `browseEnter` (word for
    // word) and any future context-menu client are expected to read.
    const metas = try alloc.alloc(glyphwire.MetadataHandle, entries.len);
    defer alloc.free(metas);
    {
        var meta_batch = client.batch();
        defer meta_batch.deinit();
        const slots = try alloc.alloc(glyphwire.Client.Batch.Slot, entries.len);
        defer alloc.free(slots);
        for (entries, 0..) |entry, i| {
            const json = try std.json.Stringify.valueAlloc(alloc, .{ .mimetype = mimetypeForEntry(entry), .path = entry.abs_path }, .{});
            defer alloc.free(json);
            slots[i] = try meta_batch.createMetadata(json);
        }
        var results = try meta_batch.send();
        defer results.deinit();
        for (0..entries.len) |i| metas[i] = try results.metadataHandle(slots[i]);
    }

    // Pass 2: one batch notification with every draw call for the whole
    // listing.
    var draw_batch = client.batch();
    defer draw_batch.deinit();

    var draw_row: usize = start.row;
    var band: usize = 0;
    while (band < grid.rows) : (band += 1) {
        var gcol: usize = 0;
        while (gcol < grid.cols) : (gcol += 1) {
            const index = gcol * grid.rows + band; // column-major
            if (index >= entries.len) break;
            const entry = entries[index];
            const base_col = gcol * grid.block_cols;
            const metadata_id = metas[index];

            if (large) {
                try draw_batch.drawIconStyled(draw_row, base_col, iconForEntry(entry), .{
                    .scale = .natural,
                    .h_align = .start,
                    .v_align = .center,
                    .max_h = max_icon_h,
                    .metadata_id = metadata_id,
                });
                // draw_icon only ever tags its own anchor cell -- see
                // core.IconScale's doc comment on why overflow has no
                // automatic data-model footprint. Tag the rest of the
                // icon's row here so browsing resolves correctly anywhere
                // the icon actually renders, not just its leftmost cell.
                var icon_col: usize = 1;
                while (icon_col < icon_cols_spanned) : (icon_col += 1) {
                    try draw_batch.tagMetadata(null, draw_row, base_col + icon_col, metadata_id);
                }
            } else {
                try draw_batch.drawIconStyled(draw_row, base_col, iconForEntry(entry), .{ .metadata_id = metadata_id });
            }

            try draw_batch.setCursor(draw_row, base_col + icon_col_width);
            const raw_name = switch (entry.kind) {
                .directory => std.fmt.bufPrint(&buf, "{s}/", .{entry.name}) catch entry.name,
                .sym_link => if (entry.link_target) |tgt|
                    std.fmt.bufPrint(&buf, "{s} -> {s}", .{ entry.name, tgt }) catch entry.name
                else
                    entry.name,
                else => entry.name,
            };
            // A multi-column grid clips names to the column's name area
            // (`gridlayout.truncateToCols`, same trailing-`…` shape the
            // server-side table cells use) so a long name doesn't spill
            // into the next column. A single-column listing keeps the
            // full name -- nothing to collide with.
            const name_text = if (grid.cols > 1)
                gridlayout.truncateToCols(&name_buf, raw_name, grid.name_cols)
            else
                raw_name;
            const name_fg: glyphwire.Color = switch (entry.kind) {
                .directory => dir_color,
                .sym_link => symlink_color,
                else => file_color,
            };
            try draw_batch.writeTextTagged(name_text, name_fg, null, metadata_id);
        }

        // Advance past this band. `block_rows` is 2 in large mode: the
        // blank row keeps this band's icons off the next band's text.
        // See this function's doc comment on why the local `draw_row`
        // clamp mirrors `set_property(cursor)`'s server-side scroll.
        try draw_batch.setCursor(draw_row + grid.block_rows, 0);
        draw_row = @min(draw_row + grid.block_rows, layer.rows - 1);
    }

    var draw_results = try draw_batch.send();
    draw_results.deinit();
}

/// Body row height, in cells, `writeLongTable`'s `large` mode uses --
/// same "give a `.natural`-scaled icon room to actually read as a
/// picture" idea `writeGrid`'s `max_icon_h` gives its icons, just as a
/// real fixed-height table row (`core.Table.render` centers and caps the
/// icon to this many cell-heights, instead of `writeGrid`'s single-row
/// anchor with overflow into neighboring rows).
const large_table_row_height = 3;

/// The `-l` listing: a real server-side table (`Client.createTable`/
/// `tableSetRows`) instead of `writeGrid`'s per-row `write_text`/`draw_icon`
/// layout -- Name (icon plus colored filename in one cell, per `TableCell`'s
/// doc comment -- no separate icon column needed the way the client-
/// composited prototype this replaced had), Size (typed numerically via
/// `sort_key`, so a future sort-by-size actually orders by byte count, not
/// lexically on `"1.2 KB"`, and colored by magnitude -- see `sizeColor`),
/// and Perms (one blank cell wider than the perm string, for a little
/// right-margin padding). Every cell in an entry's row shares one
/// metadata tag, same `mimetype`/`path` shape `writeGrid`'s tags already
/// have.
///
/// `large` (`-L`, see `main`) sets the table's `row_height` to
/// `large_table_row_height`: `core.Table.render` then draws each row's
/// icon `.natural`-scaled and centered across the whole 3-line row block
/// instead of `.fit`-scaled into one cell, same rendering `writeGrid`'s
/// large mode gives its icons -- capped and column-widened using the
/// icon's actual loaded pixel size server-side (see decisions.md's Table
/// section), not a size this client has to guess. The Name column here
/// still needs to be *wide enough* for that bigger icon, though -- same
/// `icon_native_px`/cell-metrics estimate `writeGrid` uses for its own
/// `icon_col_width` (capped to `large_table_row_height` cell-heights
/// instead of `writeGrid`'s fixed two), since column widths are fixed
/// once at `create_table` time.
///
/// Unlike the client-composited prototype's streaming `row`/`cell`/
/// `endRow` calls (each sent over the wire immediately), every row here
/// is built into one in-memory matrix and sent in a single
/// `tableSetRows` call -- see decisions.md's Table section on why the
/// table itself is now real server state rather than client-composited
/// cells: it stays visible, and re-sortable, after this process exits,
/// which a series of one-shot draw calls could never do. `scratch`
/// tracks every heap-allocated display string built along the way
/// (unlike the old streaming API, a batched `tableSetRows` call means
/// those strings have to outlive the whole loop, not just one iteration)
/// and is freed right after that call returns -- `tableSetRows` itself
/// copies everything it needs into the outgoing JSON before returning.
///
/// Anchored explicitly at the layer's current cursor (`client.getCursor()`,
/// read once up front and passed as `create_table`'s `row`/`col`) rather
/// than relying on that call's own cursor-implicit defaulting (omitted
/// `row`/`col` -- see dispatch.zig's `resolveAnchor`) -- functionally the
/// same anchor either way, but explicit here to match `writeGrid`'s own
/// style (which always reads the cursor back itself rather than leaning
/// on server-side defaults) and to make it visually obvious at the call
/// site that this table starts wherever glyphwire-shell's prompt left
/// off, not at the layer's origin.
///
/// Leaves the cursor on the row just below whatever the table actually
/// painted (`tableGetState`'s `painted` extent, not a size this client
/// computed itself -- see that field's doc comment on why: recomputing
/// the same layout math `Table.render` already did would drift the
/// moment that layout changes) -- without this, glyphwire-shell's next
/// prompt would land back on the table's own last row and overwrite it,
/// the same "leave the cursor after the last thing drawn" contract
/// `writeGrid` already honors for the plain listing.
fn writeLongTable(client: *glyphwire.Client, entries: []const FileEntry, large: bool, raw_bytes: bool) !void {
    const alloc = client.alloc;
    const cur = try client.getCursor();

    // coreutils prints a `total` line above a `-l` listing (there, a
    // count of 512-byte disk blocks). No cross-platform block count is
    // available here -- `std.Io.File.Stat` only gives byte size -- so
    // this sums the entries' byte sizes instead and formats them the
    // same way the Size column does (`--bytes` included). Written at the
    // prompt's cursor; the table starts one row below it.
    var total_bytes: u64 = 0;
    for (entries) |e| total_bytes +|= e.size;
    var total_num_buf: [24]u8 = undefined;
    var total_line_buf: [40]u8 = undefined;
    const total_line = std.fmt.bufPrint(&total_line_buf, "total {s}", .{
        std.mem.trim(u8, lsfmt.formatSize(&total_num_buf, total_bytes, raw_bytes), " "),
    }) catch "total ?";
    try client.setCursor(cur.row, cur.col);
    try client.writeText(total_line, header_color, null);
    const table_row = cur.row + 1;

    // Size the Name column to what this listing actually contains
    // (clamped, see `min_name_width`/`max_name_width`) rather than a
    // blind constant -- a fixed width wide enough for a rare long name
    // otherwise pushes Size/Perms toward (or past) the layer's right
    // edge for every *other*, normally-short-named listing too.
    const name_text_width = std.math.clamp(maxDisplayLen(entries), min_name_width, max_name_width);
    var icon_reserve: usize = 1;
    if (large) {
        const metrics = try client.getCellMetrics();
        const max_icon_h: u32 = @intCast(large_table_row_height * metrics.h);
        const icon_render_px: usize = @min(icon_native_px, max_icon_h);
        icon_reserve = (icon_render_px + metrics.w - 1) / metrics.w + 1;
    }
    const name_width = icon_reserve + name_text_width;

    const table = try client.createTable(null, table_row, cur.col, &.{
        .{ .name = "Name", .width = name_width, .sortable = true },
        // Raw byte counts run to 10+ digits; the human form never past ~8.
        .{ .name = "Size", .width = if (raw_bytes) 14 else 8, .kind = .number, .h_align = .end, .sortable = true },
        // 11, not 10: the perm string (`formatPermBits`) is exactly 10
        // chars and left-aligned, so the extra cell is a trailing blank.
        // Perms is the last column, so this reads as a right margin on
        // every row (the `alt_row_bg` stripe included).
        .{ .name = "Perms", .width = 11, .sortable = true },
    }, .{
        .borders = false,
        .alt_row_bg = rgb(30, 30, 30),
        .row_height = if (large) large_table_row_height else 1,
    });

    var scratch: std.ArrayList([]u8) = .empty;
    defer {
        for (scratch.items) |s| alloc.free(s);
        scratch.deinit(alloc);
    }

    const rows = try alloc.alloc([]glyphwire.Client.TableCellInput, entries.len);
    defer {
        for (rows) |r| alloc.free(r);
        alloc.free(rows);
    }

    // Create every entry's metadata tag in one batch request rather than
    // one round trip per entry -- see decisions.md's Batch section. Unlike
    // `writeGrid`, the drawing here is already a single `tableSetRows`
    // call, so only the `create_metadata` fan-out needed collapsing.
    const metas = try alloc.alloc(glyphwire.MetadataHandle, entries.len);
    defer alloc.free(metas);
    {
        var meta_batch = client.batch();
        defer meta_batch.deinit();
        const slots = try alloc.alloc(glyphwire.Client.Batch.Slot, entries.len);
        defer alloc.free(slots);
        for (entries, 0..) |entry, i| {
            const json = try std.json.Stringify.valueAlloc(alloc, .{ .mimetype = mimetypeForEntry(entry), .path = entry.abs_path }, .{});
            defer alloc.free(json);
            slots[i] = try meta_batch.createMetadata(json);
        }
        var results = try meta_batch.send();
        defer results.deinit();
        for (0..entries.len) |i| metas[i] = try results.metadataHandle(slots[i]);
    }

    for (entries, 0..) |entry, i| {
        const metadata_id = metas[i];

        var name_text: []u8 = undefined;
        var name_fg: glyphwire.Color = undefined;
        switch (entry.kind) {
            .directory => {
                name_text = try std.fmt.allocPrint(alloc, "{s}/", .{entry.name});
                name_fg = dir_color;
            },
            .sym_link => {
                name_text = if (entry.link_target) |tgt|
                    try std.fmt.allocPrint(alloc, "{s} -> {s}", .{ entry.name, tgt })
                else
                    try alloc.dupe(u8, entry.name);
                name_fg = symlink_color;
            },
            else => {
                name_text = try alloc.dupe(u8, entry.name);
                name_fg = file_color;
            },
        }
        try scratch.append(alloc, name_text);

        var size_buf: [24]u8 = undefined;
        const size_text = try alloc.dupe(u8, lsfmt.formatSize(&size_buf, entry.size, raw_bytes));
        try scratch.append(alloc, size_text);

        var perm_buf: [10]u8 = undefined;
        const perm_text = try alloc.dupe(u8, lsfmt.formatPermBits(&perm_buf, entry.mode));
        try scratch.append(alloc, perm_text);

        const row = try alloc.alloc(glyphwire.Client.TableCellInput, 3);
        row[0] = .{ .display = name_text, .icon = iconForEntry(entry), .fg = name_fg, .metadata_id = metadata_id };
        row[1] = .{ .display = size_text, .sort_key = .{ .number = @floatFromInt(entry.size) }, .fg = sizeColor(entry.size), .metadata_id = metadata_id };
        row[2] = .{ .display = perm_text, .fg = detail_color, .metadata_id = metadata_id };
        rows[i] = row;
    }

    try client.tableSetRows(null, table, rows);

    const state = try client.tableGetState(null, table);
    // `painted.row + painted.rows` is the row just past the table's whole
    // footprint. In `large` mode each body row block is
    // `large_table_row_height` cells tall with its text on the *middle*
    // line (`core.Table.writeBodyRow`'s `top_row + row_height / 2`), so
    // the last block carries `row_height - 1 - row_height/2` blank lines
    // below its text -- landing the next shell prompt there leaves a
    // visible gap under the listing (worse the taller the row). Pull the
    // cursor up by exactly those trailing blanks so the prompt sits one
    // line under the last entry's text, same as the non-large listing.
    const trailing_blank: usize = if (large) large_table_row_height - 1 - large_table_row_height / 2 else 0;
    try client.setCursor(state.painted.row + state.painted.rows - trailing_blank, 0);
}

/// The no-session fallback: the same content a non-glyphwire `ls` would
/// print to stdout, one entry per line. Mirrors the glyphwire path's
/// block layout -- a blank line between blocks, an `<operand>:` header
/// before a block that has one, and a `total <size>` line before each
/// `-l` block (see `writeLongTable` on why it's a summed byte size, not
/// 512-byte blocks).
fn writePlain(io: std.Io, listings: []const Listing, long_list: bool, raw_bytes: bool) !void {
    var buf: [4096]u8 = undefined;
    var w = std.Io.File.stdout().writer(io, &buf);
    for (listings, 0..) |listing, li| {
        if (li > 0) try w.interface.print("\n", .{});
        if (listing.header) |h| try w.interface.print("{s}\n", .{h});
        if (long_list) {
            var total_bytes: u64 = 0;
            for (listing.entries) |e| total_bytes +|= e.size;
            var total_buf: [24]u8 = undefined;
            try w.interface.print("total {s}\n", .{std.mem.trim(u8, lsfmt.formatSize(&total_buf, total_bytes, raw_bytes), " ")});
        }
        for (listing.entries) |entry| {
            switch (entry.kind) {
                .directory => try w.interface.print("{s}/", .{entry.name}),
                .sym_link => if (entry.link_target) |tgt|
                    try w.interface.print("{s} -> {s}", .{ entry.name, tgt })
                else
                    try w.interface.print("{s}", .{entry.name}),
                else => try w.interface.print("{s}", .{entry.name}),
            }
            if (long_list) {
                var size_buf: [24]u8 = undefined;
                var time_buf: [20]u8 = undefined;
                try w.interface.print("  {s}  {s}", .{ lsfmt.formatSize(&size_buf, entry.size, raw_bytes), lsfmt.formatTimestamp(&time_buf, entry.mtime_sec) });
            }
            try w.interface.print("\n", .{});
        }
    }
    try w.interface.flush();
}
