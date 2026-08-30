const std = @import("std");
const builtin = @import("builtin");
const glyphwire = @import("glyphwire");
const zargs = @import("zargunaught");
const gridlayout = @import("ls_support").gridlayout;
const lsfmt = @import("ls_support").format;
const lsicons = @import("ls_support").icons;

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
/// The `-l` listing follows exa's column order: permission bits, size,
/// `owner:group`, modified time, then the icon + name (the name last, and
/// its column stretched so the table fills the layer's width). Size,
/// mtime and the permission bits come from `std.Io.Dir.statFile`'s
/// cross-platform `Stat`; uid/gid need a raw `statx(2)` (Zig's reduced
/// std dropped the libc-independent Linux `stat` wrappers, and
/// `std.Io.File.Stat` omits uid/gid on purpose), and the names come from
/// libc `getpwuid`/`getgrgid` (`glyphwire-ls` already links libc) with a
/// decimal-id fallback. On a non-Linux target the Owner column is `0:0`.
/// lsz itself stays the terminal tool; this is a demonstration client,
/// not a replacement.
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
/// images, not font glyphs, so no font patching is needed. Source files
/// and project directories resolve to the Devicon language/tool logos
/// under `assets/icons/dev/`; everything else falls back to the coarser
/// KDE-Oxygen file-type set under `assets/icons/oxygen/`. Requires
/// whatever's serving the connection to have actually loaded that catalog
/// (glyphwire-host does, at startup); run against a
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
            .{ .longName = "long", .shortName = "l", .description = "Long listing: adds permission bits, size, owner:group, and modified time", .maxNumParams = 0 },
            .{ .longName = "large", .shortName = "L", .description = "Large format (the default): bigger, naturally-scaled icons (3-line-tall rows in a long listing). Wins over -S if both are given", .maxNumParams = 0 },
            .{ .longName = "small", .shortName = "S", .description = "Small format: one physical row per entry, its icon filling that line's height (no overflow into neighboring rows), in both the normal and long (-l) listing", .maxNumParams = 0 },
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
    /// Owner / group ids, only populated with `-l` via a raw `statx(2)`
    /// (`std.Io.File.Stat` has no uid/gid). `formatOwnerGroup` resolves
    /// them to names for the Owner column; both stay 0 on a non-Linux
    /// target or a failed stat.
    uid: u32 = 0,
    gid: u32 = 0,
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
        // use for size/mtime/mode/owner, and stat is a syscall per entry.
        var size: u64 = 0;
        var mtime_sec: i64 = 0;
        var mode: u16 = 0;
        var uid: u32 = 0;
        var gid: u32 = 0;
        if (long_list) {
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

    // uid/gid via a raw `statx(2)` (see `listDir`) -- resolved against the
    // cwd handle since `path` is a bare command-line operand here.
    const ids = if (long_list) ownerIds(std.Io.Dir.cwd().handle, path) else OwnerIds{ .uid = 0, .gid = 0 };

    return .{
        .name = name_copy,
        .kind = kind,
        .link_target = link_target,
        .abs_path = abs_path,
        .size = if (long_list) st.size else 0,
        .mtime_sec = if (long_list) st.mtime.toSeconds() else 0,
        .mode = if (long_list) @truncate(st.permissions.toMode()) else 0,
        .uid = ids.uid,
        .gid = ids.gid,
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

// ── `-l` table cell colors (VSCode Dark+ palette, lsd-inspired) ─────────
//
// The server-side table gives each cell one foreground color for its
// whole text -- no per-character styling, no bold -- so lsd's per-bit
// permission coloring is approximated by splitting the mode into four
// separately-colored cells (type char + three rwx triads) and coloring
// each triad as a unit by how open it is. Owner and group get their own
// name columns so the "brighter for owner, dimmer for group" pair lsd
// uses (it leans on bold there, which a cell can't do) still reads.

/// rwx triad cell, colored as a unit by access level -- `permTriadColor`.
const perm_none = rgb(92, 99, 112); //   `---`  dim slate  (#5C6370)
const perm_read = rgb(106, 153, 85); //  `r--`  comment green (#6A9955)
const perm_rwx = rgb(129, 184, 105); //  `rwx`  brighter green
const perm_write = rgb(215, 186, 125); // `rw-`  gold (#D7BA7D)
const perm_exec = rgb(211, 105, 105); //  `--x`/`r-x`  soft red

/// Owner-name column: the pale yellow VSCode uses for function names
/// (#DCDCAA), standing in for lsd's bold user color.
const owner_color = rgb(220, 220, 170);
/// Group-name column: a dimmer wash of the same yellow -- lsd's
/// non-bold group tone.
const group_color = rgb(178, 174, 128);
/// Time column: a muted steel blue, deliberately not the bright keyword
/// blue (#569CD6) the rest of the palette uses for identifiers.
const time_color = rgb(96, 139, 168);

/// Foreground for one `formatPermTriad` cell, by how much access it
/// grants -- see the color block above on why this is per-triad and not
/// per-bit.
fn permTriadColor(triad: []const u8) glyphwire.Color {
    const has_r = triad.len > 0 and triad[0] == 'r';
    const has_w = triad.len > 1 and triad[1] == 'w';
    const has_x = triad.len > 2 and triad[2] == 'x';
    if (!has_r and !has_w and !has_x) return perm_none;
    if (has_w and has_x) return perm_rwx;
    if (has_w) return perm_write;
    if (has_x) return perm_exec;
    return perm_read;
}

/// Foreground for the permission string's leading type-character cell:
/// reuses the name colors so a `d`/`l` reads the same hue as the entry's
/// own name, and a regular file's `-` stays quietly dim.
fn permTypeColor(kind: EntryKind) glyphwire.Color {
    return switch (kind) {
        .directory => dir_color,
        .sym_link => symlink_color,
        .other => rgb(197, 134, 192), // magenta -- device/socket/fifo
        .file => perm_none,
    };
}

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

/// The icon-catalog name for one entry (see `ls/icons.zig` for the tables
/// and the `dev/*` vs `oxygen/*` split):
///
///   * directory -- its `dev/*` tool logo if the basename is well-known
///     (`.vscode`, `.claude`, `.git`, `node_modules`, ...), else
///     `"oxygen/folder"`.
///   * regular file -- its `dev/*` logo by exact basename (`Dockerfile`,
///     ...) or by extension (`.zig` -> `dev/zig`, `.ex` -> `dev/elixir`,
///     ...), falling back through the coarse `oxygen/*` file-type buckets
///     to `"oxygen/file"` for an unrecognized one.
///   * symlink -- `"oxygen/file"` (no dedicated symlink icon in the
///     bundled set yet).
///   * anything else (device files, sockets, ...) -- `"oxygen/unknown"`.
fn iconForEntry(entry: FileEntry) []const u8 {
    return switch (entry.kind) {
        .directory => lsicons.iconForDirName(entry.name) orelse "oxygen/folder",
        .sym_link => "oxygen/file",
        .other => "oxygen/unknown",
        .file => lsicons.iconForFileName(entry.name) orelse lsicons.iconForExtension(entry.name),
    };
}

/// Real MIME types, unlike `ls/icons.zig`'s coarser display buckets --
/// this is the `mimetype` field every entry's metadata tag carries (see
/// `writeGrid`), and `glyphwire-shell`'s `browseEnter` specifically checks
/// for the literal string `"directory"` to decide whether Enter should
/// auto-`cd`. Not exhaustive, just the same common types `ls/icons.zig`
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
// The size / permission-bit / timestamp / owner:group formatters live in
// the pure `ls_support` module (`ls/format.zig`, re-exported here as
// `lsfmt`) so `tests/ls_tests.zig` can exercise them directly. What can't
// move there is the uid/gid *lookup* below: it needs a raw `statx(2)` and
// libc's `getpwuid`/`getgrgid`, neither of which belongs in a pure module.

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

const OwnerIds = struct { uid: u32, gid: u32 };

/// uid/gid for one entry, via a raw `statx(2)`. `dir_fd` is the handle
/// `name` is resolved against (`std.Io.Dir.handle`); pass
/// `std.Io.Dir.cwd().handle` (`AT.FDCWD`) for an absolute path. Zig's
/// reduced std removed the libc-independent Linux `stat` wrappers and
/// `std.Io.File.Stat` omits uid/gid on purpose, so this raw syscall is
/// the lowest-friction way to get just those two fields. Returns
/// `{ 0, 0 }` on any failure or on a non-Linux target -- the Owner column
/// then reads `0:0`, and uid 0 still resolves to `root` for the name.
fn ownerIds(dir_fd: std.posix.fd_t, name: []const u8) OwnerIds {
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
fn ownerGroupText(buf: []u8, uid: u32, gid: u32) []const u8 {
    var owner_num: [16]u8 = undefined;
    var group_num: [16]u8 = undefined;
    // `getpwuid` and `getgrgid` each return a pointer into their own,
    // distinct libc static buffer, so the first result stays valid across
    // the second call; `formatOwnerGroup`'s `bufPrint` copies both out
    // before either could be reused.
    return lsfmt.formatOwnerGroup(buf, userName(uid, &owner_num), groupName(gid, &group_num));
}

fn userName(uid: u32, num_buf: []u8) []const u8 {
    if (builtin.os.tag == .linux) {
        if (pwlib.getpwuid(uid)) |pw| {
            if (pw.pw_name) |n| return std.mem.span(n);
        }
    }
    return std.fmt.bufPrint(num_buf, "{d}", .{uid}) catch num_buf[0..0];
}

fn groupName(gid: u32, num_buf: []u8) []const u8 {
    if (builtin.os.tag == .linux) {
        if (pwlib.getgrgid(gid)) |gr| {
            if (gr.gr_name) |n| return std.mem.span(n);
        }
    }
    return std.fmt.bufPrint(num_buf, "{d}", .{gid}) catch num_buf[0..0];
}

// ── glyphwire output ──────────────────────────────────────────────────────

/// Native pixel size of the bundled Oxygen icon set (decisions.md's Icon
/// section: "kept at Oxygen's native 32x32"). Used up front to reserve
/// enough columns for a `.natural`-scaled icon before the name starts,
/// and as the hard cap on how large `writeGrid` lets any icon render --
/// so a mixed-resolution set (32px folders next to 48px dev-tool glyphs)
/// still comes out visually uniform.
const icon_native_px = 32;

/// Floor the stretched Name column (`writeLongTable`) is clamped to when
/// the layer is too narrow to give it its leftover-width share -- the
/// table then clips the longest names with a trailing `…`, same as a
/// terminal `ls` in a cramped window. There's no ceiling: Name is the
/// last column and deliberately absorbs whatever width the fixed columns
/// leave so the table fills the layer (exa's layout). Still also the
/// floor `maxDisplayLen` is clamped up to for `writeGrid`'s per-column
/// name area, so an all-short-names listing doesn't squeeze its header.
const min_name_width = 8;

/// The widest an entry's Name content (filename plus its `/`/` -> target`
/// suffix) actually is, in **display cells** -- East Asian wide
/// codepoints count 2, matching how `core.writeText` advances the cursor
/// and `gridlayout.truncateToCols` trims, so this agrees with the
/// truncation math that eventually runs against it. `writeGrid` uses it
/// to size each column's name area to the *real* data instead of a blind
/// constant.
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
/// block height (`Grid.block_rows`) follows. Both draw the icon
/// `.natural` sized (capped to `max_icon_h`) rather than `.fit`: at this
/// font's actual cell size a `.fit`-shrunk 32x32 icon comes out only a
/// few pixels tall, unrecognizable. `h_align = .start`/`v_align = .center`
/// place it flush against the block's left edge, vertically centered.
/// This needs the session's cell pixel size (`get_cell_metrics`); a host
/// that doesn't answer that leaves `max_icon_h == 0` and small mode falls
/// back to the old one-cell `.fit` (large mode can't run without it).
///
/// - `false` (`-S`): `max_icon_h` is **one** cell-height, so the icon
///   fills the entry's own row height without spilling onto the row above
///   or below -- one physical row per entry (`block_rows == 1`). Same
///   "fill the line" rendering the shell prompt's `{icon:...}` uses.
/// - `true` (default): `max_icon_h` is **two** cell-heights; with centered
///   alignment that puts a quarter of the icon above the entry's own row,
///   half on it, a quarter below, so `block_rows == 2` leaves a blank
///   row between bands and one band's icon doesn't overlap the next's
///   text. `icon_col_width` (from the icon's own native width, not a
///   fixed constant) reserves room before the name so they don't collide.
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

    // Both modes draw the icon `.natural` sized rather than `.fit` into
    // one cell (unreadably tiny at this font's cell size). This needs the
    // session's cell pixel metrics: large mode requires them; small mode
    // falls back to the old one-cell `.fit` (`max_icon_h == 0`) without
    // them. `icon_col_width` reserves the leading columns before the name;
    // `icon_cols_spanned` is how many the icon's rendered width visually
    // reaches, so every cell it covers -- not just its anchor -- gets
    // tagged below.
    var icon_col_width: usize = 2;
    var max_icon_h: u32 = 0;
    var icon_cols_spanned: usize = 1;
    var block_rows: usize = 1;

    const metrics = metrics_blk: {
        const m = client.getCellMetrics() catch |err| {
            if (large) return err;
            break :metrics_blk null;
        };
        break :metrics_blk m;
    };

    if (metrics) |m| {
        const cell_w: usize = m.w;
        const cell_h: usize = m.h;
        // Small mode caps the icon to one cell-height so it fills the
        // entry's own row without spilling onto the rows above/below
        // (`block_rows` stays 1); large mode caps it to two and leaves a
        // blank row between bands. Either way, never past `icon_native_px`
        // -- a higher-resolution icon (the 48px dev-tool glyphs, say) then
        // renders at the same on-screen size as every 32px folder/file
        // icon beside it instead of looming larger.
        max_icon_h = @intCast(@min((if (large) @as(usize, 2) else 1) * cell_h, icon_native_px));
        // `.natural` scale with only `max_h` set ties the rendered width
        // to the same cap (square icons, uniform scale-down -- see
        // `core.IconScale`'s doc comment), so the rendered pixel size is
        // never more than `max_icon_h`.
        const icon_render_px: usize = max_icon_h;
        icon_cols_spanned = (icon_render_px + cell_w - 1) / cell_w;
        // Large mode keeps a slightly wider reserve from the icon set's
        // native width (`icon_native_px`, now also the render cap, so this
        // is always enough); small mode only needs the columns the icon
        // actually reaches, plus a one-column gap.
        icon_col_width = if (large)
            (icon_native_px + cell_w - 1) / cell_w + 1
        else
            icon_cols_spanned + 1;
        block_rows = if (large) 2 else 1;
    }

    // Fit as many entry columns across the layer as the longest name
    // allows (single-column if it doesn't fit two), then fill them
    // column-major.
    const layer = try client.getSize();
    const grid = gridlayout.compute(entries.len, maxDisplayLen(entries), layer.cols, .{
        .icon_cols = icon_col_width,
        .block_rows = block_rows,
    });

    // A blank row between whatever's above (the shell's prompt line, or a
    // multi-operand block's `<operand>:` header) and the first band, so the
    // icons aren't crammed right against it. The `-l` table has no
    // equivalent -- it sits directly under its own `total` line, matching a
    // terminal `ls -l`. `set_property(cursor)` past the bottom row just
    // scrolls one line, same as any other output.
    {
        const before = try client.getCursor();
        try client.setCursor(before.row + 1, 0);
    }

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

            if (max_icon_h > 0) {
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

/// Clamp for the User / Group name columns' widths: each is sized to the
/// widest name the listing actually holds, but never so narrow its
/// header is squeezed nor so wide one long name from an unusual id
/// stretches every row (`writeCellRun` clips past this with `…`).
const id_name_col_min = 5;
const id_name_col_max = 16;

/// The `-l` listing: a real server-side table (`Client.createTable`/
/// `tableSetRows`) instead of `writeGrid`'s per-row `write_text`/`draw_icon`
/// layout. Columns follow exa's order, with lsd-style coloring (VSCode
/// Dark+ palette) worked around the table's "one fg per cell" limit by
/// splitting the mode into four cells:
///
/// - **type / usr / grp / oth** -- the permission string as four
///   separately-colored cells: the 1-wide type char (`permTypeColor`,
///   hued like the entry's name) then three 3-wide `rwx` triads, each
///   colored as a unit by access level (`permTriadColor`: green/gold/red/
///   dim). The individual r/w/x bits within a triad still share a color.
/// - **Size** -- typed numerically via `sort_key`, so a future
///   sort-by-size orders by byte count, not lexically on `"1.2 KB"`;
///   colored by magnitude (see `sizeColor`), right-aligned.
/// - **User** / **Group** -- separate name columns (`userName`/
///   `groupName`), each sized to the widest name this listing holds
///   (clamped `id_name_col_min`..`id_name_col_max`). User is drawn in a
///   brighter pale yellow (`owner_color`), Group a dimmer wash
///   (`group_color`) -- lsd leans on bold there, which a cell can't do.
/// - **Time** -- `formatTimestamp` (`YYYY-MM-DD HH:MM`) in a muted steel
///   blue (`time_color`), `sort_key` the raw mtime so a future
///   sort-by-time is chronological.
/// - **Name** -- icon plus colored filename in one cell (per `TableCell`'s
///   doc comment -- no separate icon column). Last, and **stretched**:
///   its width is whatever's left after the fixed columns so the table's
///   total width fills the layer (`client.getSize().cols`), clamped up to
///   `min_name_width` (+ the large-mode icon reserve) when the layer is
///   too narrow to spare it -- the table then clips the longest names
///   with `…`, same as a terminal `ls` in a cramped window.
///
/// Every cell in an entry's row shares one metadata tag, same
/// `mimetype`/`path` shape `writeGrid`'s tags already have.
///
/// `large` (`-L`, see `main`) sets the table's `row_height` to
/// `large_table_row_height`: `core.Table.render` then draws each row's
/// icon `.natural`-scaled and centered across the whole 3-line row block
/// instead of `.fit`-scaled into one cell, same rendering `writeGrid`'s
/// large mode gives its icons -- capped and column-widened using the
/// icon's actual loaded pixel size server-side (see decisions.md's Table
/// section), not a size this client has to guess. The stretched Name
/// column still gets a `min_name_width + icon_reserve` floor so that
/// bigger icon has room even in the narrow-layer clip case -- same
/// `icon_native_px`/cell-metrics estimate `writeGrid` uses for its own
/// `icon_col_width`, capped to `large_table_row_height` cell-heights.
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
/// Leaves the cursor a row below whatever the table actually painted
/// (`tableGetState`'s `painted` extent, not a size this client computed
/// itself -- see that field's doc comment on why: recomputing the same
/// layout math `Table.render` already did would drift the moment that
/// layout changes), so glyphwire-shell's next prompt doesn't land on the
/// table's own last row and overwrite it -- the same "leave the cursor
/// after the last thing drawn" contract `writeGrid` honors. When the
/// table was taller than the window its `painted` footprint fills the
/// whole viewport (it scrolled the layer as it drew, terminal-style), so
/// there's no spare on-screen row: the cursor lands on the last line and
/// one newline is emitted to scroll a blank gap in before the prompt.
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

    // Every heap-allocated display string built below (name, size, owner,
    // time) goes in here -- a batched `tableSetRows` needs them all to
    // outlive the build loop, and they're freed once it returns (it
    // copies what it needs into the outgoing JSON first).
    var scratch: std.ArrayList([]u8) = .empty;
    defer {
        for (scratch.items) |s| alloc.free(s);
        scratch.deinit(alloc);
    }

    // Resolve owner / group *names* for every entry up front: the User
    // and Group columns are each sized to the widest name this listing
    // holds (clamped), and the strings are reused when the rows are built.
    const user_texts = try alloc.alloc([]u8, entries.len);
    const group_texts = try alloc.alloc([]u8, entries.len);
    defer alloc.free(user_texts);
    defer alloc.free(group_texts);
    var max_user_disp: usize = 0;
    var max_group_disp: usize = 0;
    {
        var num_buf: [16]u8 = undefined;
        for (entries, 0..) |entry, i| {
            const u = try alloc.dupe(u8, userName(entry.uid, &num_buf));
            const g = try alloc.dupe(u8, groupName(entry.gid, &num_buf));
            user_texts[i] = u;
            group_texts[i] = g;
            try scratch.append(alloc, u);
            try scratch.append(alloc, g);
            max_user_disp = @max(max_user_disp, gridlayout.displayWidth(u));
            max_group_disp = @max(max_group_disp, gridlayout.displayWidth(g));
        }
    }

    // The permission string is drawn as four cells so each can be colored
    // apart: a 1-wide type char then three 3-wide `rwx` triads. The table
    // forces a 1-col gap between cells, so this renders as
    // `d rwx r-x r-x` -- 13 cells, a touch wider than the old single
    // 10-char column but readably grouped.
    const type_width: usize = 1;
    const triad_width: usize = 3;
    // Raw byte counts run to 10+ digits; the human form never past ~8.
    const size_width: usize = if (raw_bytes) 14 else 8;
    const user_width = std.math.clamp(max_user_disp, id_name_col_min, id_name_col_max);
    const group_width = std.math.clamp(max_group_disp, id_name_col_min, id_name_col_max);
    // "YYYY-MM-DD HH:MM" is 16 chars; +1 for a gap before Name.
    const time_width: usize = 17;

    // The stretched Name column still needs leading columns reserved in
    // its cell for a `.natural`-scaled row icon. Large mode caps the icon
    // to `large_table_row_height` cell-heights; small mode now caps it to
    // one cell-height (`core.Table.writeBodyRow`), not the old one-cell
    // `.fit` -- both want the same `icon_native_px`/cell-metrics estimate
    // `writeGrid` uses. Without cell metrics the server keeps the old
    // `.fit` and `icon_reserve` stays 1 to match.
    var icon_reserve: usize = 1;
    if (large) {
        const metrics = try client.getCellMetrics();
        const max_icon_h: u32 = @intCast(large_table_row_height * metrics.h);
        const icon_render_px: usize = @min(icon_native_px, max_icon_h);
        icon_reserve = (icon_render_px + metrics.w - 1) / metrics.w + 1;
    } else if (client.getCellMetrics() catch null) |metrics| {
        const icon_render_px: usize = @min(icon_native_px, metrics.h);
        icon_reserve = (icon_render_px + metrics.w - 1) / metrics.w + 1;
    }
    const name_floor = icon_reserve + min_name_width;

    // Stretch the last (Name) column so the table's total width fills the
    // layer. `core.Table.render` with `borders = false` lays a table out
    // as `sum(widths) + (n - 1)` cells wide from `cur.col`, so Name takes
    // whatever's left once the eight fixed columns and their eight
    // inter-column separators are subtracted from that span.
    const layer = try client.getSize();
    const span = if (layer.cols > cur.col) layer.cols - cur.col else 0;
    const fixed = type_width + triad_width * 3 + size_width + user_width + group_width + time_width + 8;
    const name_width = if (span > fixed + name_floor) span - fixed else name_floor;

    const table = try client.createTable(null, table_row, cur.col, &.{
        .{ .name = "", .width = type_width },
        .{ .name = "usr", .width = triad_width },
        .{ .name = "grp", .width = triad_width },
        .{ .name = "oth", .width = triad_width },
        .{ .name = "Size", .width = size_width, .kind = .number, .h_align = .end, .sortable = true },
        .{ .name = "User", .width = user_width, .sortable = true },
        .{ .name = "Group", .width = group_width, .sortable = true },
        .{ .name = "Time", .width = time_width, .kind = .number, .sortable = true },
        .{ .name = "Name", .width = name_width, .sortable = true },
    }, .{
        .borders = false,
        .alt_row_bg = rgb(30, 30, 30),
        .row_height = if (large) large_table_row_height else 1,
    });

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

        // The permission string split into its four separately-colored
        // cells: type char, then the user / group / other `rwx` triads.
        var triad_bufs: [3][3]u8 = undefined;
        const type_text = try alloc.dupe(u8, &[_]u8{lsfmt.permTypeChar(entry.mode)});
        const usr_triad = try alloc.dupe(u8, lsfmt.formatPermTriad(&triad_bufs[0], entry.mode, .user));
        const grp_triad = try alloc.dupe(u8, lsfmt.formatPermTriad(&triad_bufs[1], entry.mode, .group));
        const oth_triad = try alloc.dupe(u8, lsfmt.formatPermTriad(&triad_bufs[2], entry.mode, .other));
        try scratch.append(alloc, type_text);
        try scratch.append(alloc, usr_triad);
        try scratch.append(alloc, grp_triad);
        try scratch.append(alloc, oth_triad);

        var time_buf: [20]u8 = undefined;
        const time_text = try alloc.dupe(u8, lsfmt.formatTimestamp(&time_buf, entry.mtime_sec));
        try scratch.append(alloc, time_text);

        // exa's column order: type + rwx triads, Size, User, Group, Time,
        // then icon + Name. `user_texts[i]`/`group_texts[i]` are already
        // in `scratch` from the pre-pass.
        const row = try alloc.alloc(glyphwire.Client.TableCellInput, 9);
        row[0] = .{ .display = type_text, .fg = permTypeColor(entry.kind), .metadata_id = metadata_id };
        row[1] = .{ .display = usr_triad, .fg = permTriadColor(usr_triad), .metadata_id = metadata_id };
        row[2] = .{ .display = grp_triad, .fg = permTriadColor(grp_triad), .metadata_id = metadata_id };
        row[3] = .{ .display = oth_triad, .fg = permTriadColor(oth_triad), .metadata_id = metadata_id };
        row[4] = .{ .display = size_text, .sort_key = .{ .number = @floatFromInt(entry.size) }, .fg = sizeColor(entry.size), .metadata_id = metadata_id };
        row[5] = .{ .display = user_texts[i], .fg = owner_color, .metadata_id = metadata_id };
        row[6] = .{ .display = group_texts[i], .fg = group_color, .metadata_id = metadata_id };
        row[7] = .{ .display = time_text, .sort_key = .{ .number = @floatFromInt(entry.mtime_sec) }, .fg = time_color, .metadata_id = metadata_id };
        row[8] = .{ .display = name_text, .icon = iconForEntry(entry), .fg = name_fg, .metadata_id = metadata_id };
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
    const past_table = state.painted.row + state.painted.rows;
    const layer_bottom = layer.rows -| 1;
    if (past_table <= layer_bottom) {
        // The whole table fits with at least one row to spare below it:
        // park the cursor on that row so glyphwire-shell's `+1` leaves one
        // blank line between the listing and the next prompt.
        try client.setCursor(past_table - trailing_blank, 0);
    } else {
        // The table was taller than the window, so `Table.render` scrolled
        // the layer as it drew (terminal-style) and its footprint now fills
        // the viewport -- there's no on-screen row left for the gap. Land
        // on the last row and emit one newline: that scrolls a blank line
        // in, and the shell's own `+1` then puts the prompt below it, the
        // same one-line gap the fits-in-window case leaves.
        try client.setCursor(layer_bottom, 0);
        try client.writeText("\n", null, null);
    }
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
            // Same exa-style column order the glyphwire `-l` table uses:
            // perms, size, owner:group, time, then the name.
            if (long_list) {
                var perm_buf: [10]u8 = undefined;
                var size_buf: [24]u8 = undefined;
                var owner_buf: [160]u8 = undefined;
                var time_buf: [20]u8 = undefined;
                try w.interface.print("{s}  {s}  {s}  {s}  ", .{
                    lsfmt.formatPermBits(&perm_buf, entry.mode),
                    lsfmt.formatSize(&size_buf, entry.size, raw_bytes),
                    ownerGroupText(&owner_buf, entry.uid, entry.gid),
                    lsfmt.formatTimestamp(&time_buf, entry.mtime_sec),
                });
            }
            switch (entry.kind) {
                .directory => try w.interface.print("{s}/", .{entry.name}),
                .sym_link => if (entry.link_target) |tgt|
                    try w.interface.print("{s} -> {s}", .{ entry.name, tgt })
                else
                    try w.interface.print("{s}", .{entry.name}),
                else => try w.interface.print("{s}", .{entry.name}),
            }
            try w.interface.print("\n", .{});
        }
    }
    try w.interface.flush();
}
