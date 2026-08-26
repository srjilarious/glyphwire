const std = @import("std");
const glyphwire = @import("glyphwire");
const zargs = @import("zargunaught");

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
/// Deliberately narrower than lsz: no terminal-width grid packing (doesn't
/// mean anything over a fixed-size cell grid), no full permission-bit/
/// owner/group columns (would need the same raw `fstatat`/`getpwuid`/
/// `getgrgid` C bindings lsz uses -- `-l` here sticks to what
/// `std.Io.Dir.statFile`'s cross-platform `Stat` already gives: size and
/// modified time) -- directory/symlink/file coloring plus a trailing `/`
/// or ` -> target` covers the rest of what lsz's coloring conveys. lsz
/// itself stays the terminal tool; this is a demonstration client, not a
/// replacement.
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
    const dir_path: []const u8 = if (args.positional.items.len > 0) args.positional.items[0] else ".";

    const entries = try listDir(io, alloc, dir_path, show_hidden, long_list);
    defer freeEntries(alloc, entries);

    if (glyphwire.Client.connectFromEnv(io, alloc, init.environ_map)) |connected| {
        var client = connected;
        defer client.deinit();
        const abs_dir_path = try resolveAbsolutePath(io, alloc, dir_path);
        defer alloc.free(abs_dir_path);
        // Large icons by default in both views; `-S` opts into small ones
        // (also in both); `-L` wins if both are given, so it can force
        // large back on even under an inherited/aliased `-S`. Resolved
        // here rather than threaded through as three-way state, so
        // `writeGrid`/`writeLongTable` only ever see a plain `large: bool`.
        const large = large_flag or !small_flag;
        if (long_list) {
            try writeLongTable(&client, entries, abs_dir_path, large);
        } else {
            try writeGrid(&client, entries, abs_dir_path, large);
        }
    } else |_| {
        try writePlain(io, entries, long_list);
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
    size: u64 = 0,
    mtime_sec: i64 = 0,
    /// Raw POSIX mode bits (file type nibble + setuid/setgid/sticky +
    /// user/group/all rwx), only populated with `-l` -- see `FileMode`.
    mode: u16 = 0,
};

fn listDir(io: std.Io, alloc: std.mem.Allocator, dir_path: []const u8, show_hidden: bool, long_list: bool) ![]FileEntry {
    var entries: std.ArrayList(FileEntry) = .empty;
    errdefer freeEntries(alloc, entries.items);

    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch |err| {
        std.log.err("glyphwire-ls: cannot open {s}: {t}", .{ dir_path, err });
        return entries.toOwnedSlice(alloc);
    };
    defer dir.close(io);

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
        try entries.append(alloc, .{
            .name = name_copy,
            .kind = kind,
            .link_target = link_target,
            .size = size,
            .mtime_sec = mtime_sec,
            .mode = mode,
        });
    }

    std.mem.sort(FileEntry, entries.items, {}, struct {
        fn lessThan(_: void, a: FileEntry, b: FileEntry) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.lessThan);

    return entries.toOwnedSlice(alloc);
}

fn freeEntries(alloc: std.mem.Allocator, entries: []const FileEntry) void {
    for (entries) |e| {
        alloc.free(e.name);
        if (e.link_target) |t| alloc.free(t);
    }
    alloc.free(entries);
}

// ── Styling ────────────────────────────────────────────────────────────────

fn rgb(r: u8, g: u8, b: u8) glyphwire.Color {
    return .{ .r = r, .g = g, .b = b, .a = 255 };
}

const dir_color = rgb(98, 114, 164);
const symlink_color = rgb(139, 233, 253);
const file_color = rgb(220, 220, 220);
const detail_color = rgb(120, 120, 120);

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

const KBytes: u64 = 1024;
const MBytes: u64 = 1024 * KBytes;
const GBytes: u64 = 1024 * MBytes;

/// Bitfield view of `FileEntry.mode`'s raw POSIX mode bits -- lifted from
/// lsz's identical `FileMode` (/home/jeffdw/code/lsz/src/main.zig), same
/// field layout (LSB first: all/other bits, then group, then user, then
/// setuid/setgid/sticky, then the file-type nibble in the top 4 bits,
/// matching `st_mode`'s standard POSIX layout).
const FileMode = packed struct(u16) {
    all_x: bool,
    all_w: bool,
    all_r: bool,
    group_x: bool,
    group_w: bool,
    group_r: bool,
    user_x: bool,
    user_w: bool,
    user_r: bool,
    sticky: bool,
    setgid: bool,
    setuid: bool,
    type: u4,
};

/// `-l`'s permission column: a type character (`d`/`l`/`-`/... , same
/// mapping lsz's `printLongEntry` uses) followed by the classic 9-character
/// `rwxrwxrwx` triad (user, group, all -- `-` for an unset bit). Unlike
/// lsz's version, this doesn't color each flag individually: a table cell
/// carries one foreground color for its whole text (see `Table.cellStyled`),
/// not per-character styling, and the type-character-plus-string shape
/// reads clearly enough in the table's default color already.
fn formatPermBits(buf: *[10]u8, mode: u16) []const u8 {
    const fm: FileMode = @bitCast(mode);
    buf[0] = switch (fm.type) {
        4 => 'd',
        8 => '-',
        10 => 'l',
        1 => 'p',
        2 => 'c',
        6 => 'b',
        12 => 's',
        else => '?',
    };
    buf[1] = if (fm.user_r) 'r' else '-';
    buf[2] = if (fm.user_w) 'w' else '-';
    buf[3] = if (fm.user_x) 'x' else '-';
    buf[4] = if (fm.group_r) 'r' else '-';
    buf[5] = if (fm.group_w) 'w' else '-';
    buf[6] = if (fm.group_x) 'x' else '-';
    buf[7] = if (fm.all_r) 'r' else '-';
    buf[8] = if (fm.all_w) 'w' else '-';
    buf[9] = if (fm.all_x) 'x' else '-';
    return buf;
}

/// Human-readable size, right-padded to a fixed width so the timestamp
/// that follows lines up across rows -- e.g. `  512 B`, ` 12.3 KB`.
fn formatSize(buf: []u8, size: u64) []const u8 {
    if (size < KBytes) return std.fmt.bufPrint(buf, "{d:>4} B ", .{size}) catch buf[0..0];
    if (size < MBytes) return std.fmt.bufPrint(buf, "{d:>5.1} KB", .{@as(f64, @floatFromInt(size)) / @as(f64, @floatFromInt(KBytes))}) catch buf[0..0];
    if (size < GBytes) return std.fmt.bufPrint(buf, "{d:>5.1} MB", .{@as(f64, @floatFromInt(size)) / @as(f64, @floatFromInt(MBytes))}) catch buf[0..0];
    return std.fmt.bufPrint(buf, "{d:>5.1} GB", .{@as(f64, @floatFromInt(size)) / @as(f64, @floatFromInt(GBytes))}) catch buf[0..0];
}

/// `YYYY-MM-DD HH:MM`, purely from `std.time.epoch` -- no libc needed.
fn formatTimestamp(buf: []u8, sec: i64) []const u8 {
    if (sec < 0) return "";
    const epoch: std.time.epoch.EpochSeconds = .{ .secs = @intCast(sec) };
    const epoch_day = epoch.getEpochDay();
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_secs = epoch.getDaySeconds();
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        day_secs.getHoursIntoDay(),
        day_secs.getMinutesIntoHour(),
    }) catch buf[0..0];
}

// ── glyphwire output ──────────────────────────────────────────────────────

/// Native pixel size of the bundled Oxygen icon set (decisions.md's Icon
/// section: "kept at Oxygen's native 32x32") -- needed up front to reserve
/// enough columns for a `.natural`-scaled icon before the name starts.
const icon_native_px = 32;

/// The plain (non `-l`) listing: writes one entry per row starting at the
/// layer's current cursor row, leaving the cursor at the start of the row
/// after the last entry -- glyphwire-shell resyncs from
/// `get_property(cursor)` after this process exits (see
/// `Prompt.submitLine`), so there's no fixed row count it needs to guess.
/// Each row gets a leading icon (`iconForEntry`) before the name, drawn at
/// the cursor rather than naming its row/col explicitly -- the loop always
/// enters each iteration with the cursor already sitting at that row's
/// start (see the trailing `setCursor` below), so there's nothing to add
/// by repeating it. See `writeLongTable` for `-l`, which renders as a
/// server-side `Table` instead of this per-row layout.
///
/// `large` (`-L`, see `main`) picks between two icon renderings:
///
/// - `false` (default): `.fit`-scaled into the icon's single anchor cell,
///   same as a `-l` table's icon at its default `row_height`. One
///   physical row per entry.
/// - `true`: `.natural` sized (capped to `max_icon_h`, computed below)
///   instead of `.fit`: at this font's actual cell size a `.fit`-shrunk
///   32x32 icon comes out only a few pixels tall, unrecognizable.
///   `h_align = .start`/`v_align = .center` then place it flush against
///   the row's left edge, vertically centered -- growing only rightward
///   and vertically (never leftward off-grid, since the icon sits in
///   column 0). `icon_col_width` (computed from the icon's own native
///   width, not a fixed constant, since a smaller/larger cell size
///   changes how many columns that native width actually spans) reserves
///   enough room before the name starts that it doesn't collide with the
///   wider icon. Vertically, `max_icon_h` -- two cell-heights -- combined
///   with centered alignment puts a quarter of the icon above the entry's
///   own row, half on it, and a quarter below, which is why the loop
///   below skips an *extra* row per entry in this mode: without it, one
///   entry's icon would overlap the next entry's text.
///
/// Reads the cursor back before *each* entry rather than tracking a local
/// row counter across the whole loop: the grid can scroll mid-listing
/// (once enough entries have pushed the cursor to the bottom), and only
/// the server knows the post-scroll row. A local counter drifts out of
/// sync the moment that happens -- `write_text`'s cursor-based
/// positioning self-corrects for it, and now `draw_icon` does too by
/// drawing at the cursor, but the row is still needed below to position
/// the *name* one column over and to advance to the next row. Costs one
/// extra request per entry; fine for what a directory listing needs over
/// a local socket.
/// `abs_dir_path` is the absolute (resolved against cwd if `dir_path` was
/// relative) form of whatever directory was listed -- see `main`'s
/// `resolveAbsolutePath` call. Every entry's metadata tag (below) embeds
/// its full path, and a relative one would be ambiguous the moment
/// anything reading it back (glyphwire-shell's `browseEnter`, eventually
/// other tools) has a different cwd than this process did.
fn writeGrid(client: *glyphwire.Client, entries: []const FileEntry, abs_dir_path: []const u8, large: bool) !void {
    const alloc = client.alloc;
    var buf: [std.Io.Dir.max_path_bytes + 8]u8 = undefined;

    // Small mode: the icon stays inside its one anchor cell, so the name
    // just needs to start one column over (plus a one-column gap), and
    // each entry only ever occupies its own single physical row.
    var icon_col_width: usize = 2;
    var max_icon_h: u32 = 0;
    var icon_cols_spanned: usize = 1;
    var row_step: usize = 1;

    if (large) {
        const metrics = try client.getCellMetrics();
        const cell_w: usize = metrics.w;
        const cell_h: usize = metrics.h;
        icon_col_width = (icon_native_px + cell_w - 1) / cell_w + 1;
        max_icon_h = @intCast(2 * cell_h);
        // How many columns (from the anchor at col 0) the icon's rendered
        // width actually reaches, so every cell it visually covers -- not
        // just its anchor cell -- can be tagged below. `.natural` scale
        // with only `max_h` set ties width to the same cap (square icons,
        // uniform scale-down -- see `core.IconScale`'s doc comment), so
        // the rendered pixel width is never more than `max_icon_h`, same
        // as the height.
        const icon_render_px: usize = @min(icon_native_px, max_icon_h);
        icon_cols_spanned = (icon_render_px + cell_w - 1) / cell_w;
        row_step = 2;
    }

    for (entries) |entry| {
        const cur = try client.getCursor();
        const row = cur.row;

        // Every cell this entry's row touches (icon, name, and -l's
        // size/time columns) shares one metadata id -- see
        // decisions.md's Metadata section on tagging a whole run rather
        // than copying the same blob per cell. `mimetype`/`path` are the
        // two fields glyphwire-shell's `browseEnter` (word for word) and
        // any future context-menu client are expected to read.
        const full_path = try std.fs.path.join(alloc, &.{ abs_dir_path, entry.name });
        defer alloc.free(full_path);
        const json = try std.json.Stringify.valueAlloc(alloc, .{ .mimetype = mimetypeForEntry(entry), .path = full_path }, .{});
        defer alloc.free(json);
        const metadata_id = try client.createMetadata(json);

        if (large) {
            try client.drawIconStyled(null, null, iconForEntry(entry), .{
                .scale = .natural,
                .h_align = .start,
                .v_align = .center,
                .max_h = max_icon_h,
                .metadata_id = metadata_id,
            });
            // draw_icon only ever tags its own anchor cell (col 0) -- see
            // core.IconScale's doc comment on why overflow has no
            // automatic data-model footprint. Tag the rest of the icon's
            // own row here so browsing (glyphwire-shell's browseEnter)
            // resolves correctly anywhere the icon actually renders, not
            // just its leftmost cell.
            var icon_col: usize = 1;
            while (icon_col < icon_cols_spanned) : (icon_col += 1) {
                try client.tagMetadata(null, row, icon_col, metadata_id);
            }
        } else {
            try client.drawIconStyled(null, null, iconForEntry(entry), .{ .metadata_id = metadata_id });
        }
        try client.setCursor(row, icon_col_width);
        switch (entry.kind) {
            .directory => {
                const text = std.fmt.bufPrint(&buf, "{s}/", .{entry.name}) catch entry.name;
                try client.writeTextTagged(text, dir_color, null, metadata_id);
            },
            .sym_link => {
                const text = if (entry.link_target) |tgt|
                    std.fmt.bufPrint(&buf, "{s} -> {s}", .{ entry.name, tgt }) catch entry.name
                else
                    entry.name;
                try client.writeTextTagged(text, symlink_color, null, metadata_id);
            },
            else => try client.writeTextTagged(entry.name, file_color, null, metadata_id),
        }

        // set_property(cursor) scrolls-and-clamps a row at or past the
        // bottom (Layer.resolveRow), so it's always safe to just name the
        // next row directly here -- the *next* iteration's getCursor()
        // reads back wherever that actually landed. `row_step` is 2, not
        // 1, in large mode: leaves a blank row so this entry's icon (up
        // to `max_icon_h` tall, see `writeGrid`'s doc comment) doesn't
        // collide with the next entry's text.
        try client.setCursor(row + row_step, 0);
    }
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
/// lexically on `"1.2 KB"`), and Perms. Every cell in an entry's row
/// shares one metadata tag, same `mimetype`/`path` shape `writeGrid`'s
/// tags already have.
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
/// Leaves the cursor on the row just below whatever the table actually
/// painted (`tableGetState`'s `painted` extent, not a size this client
/// computed itself -- see that field's doc comment on why: recomputing
/// the same layout math `Table.render` already did would drift the
/// moment that layout changes) -- without this, glyphwire-shell's next
/// prompt would land back on the table's own last row and overwrite it,
/// the same "leave the cursor after the last thing drawn" contract
/// `writeGrid` already honors for the plain listing.
fn writeLongTable(client: *glyphwire.Client, entries: []const FileEntry, abs_dir_path: []const u8, large: bool) !void {
    const alloc = client.alloc;

    var name_width: usize = 33;
    if (large) {
        const metrics = try client.getCellMetrics();
        const max_icon_h: u32 = @intCast(large_table_row_height * metrics.h);
        const icon_render_px: usize = @min(icon_native_px, max_icon_h);
        const icon_col_width = (icon_render_px + metrics.w - 1) / metrics.w + 1;
        name_width = icon_col_width + 32;
    }

    const table = try client.createTable(null, null, null, &.{
        .{ .name = "Name", .width = name_width, .sortable = true },
        .{ .name = "Size", .width = 8, .kind = .number, .h_align = .end, .sortable = true },
        .{ .name = "Perms", .width = 10, .sortable = true },
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

    for (entries, 0..) |entry, i| {
        const full_path = try std.fs.path.join(alloc, &.{ abs_dir_path, entry.name });
        defer alloc.free(full_path);
        const json = try std.json.Stringify.valueAlloc(alloc, .{ .mimetype = mimetypeForEntry(entry), .path = full_path }, .{});
        defer alloc.free(json);
        const metadata_id = try client.createMetadata(json);

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

        var size_buf: [16]u8 = undefined;
        const size_text = try alloc.dupe(u8, formatSize(&size_buf, entry.size));
        try scratch.append(alloc, size_text);

        var perm_buf: [10]u8 = undefined;
        const perm_text = try alloc.dupe(u8, formatPermBits(&perm_buf, entry.mode));
        try scratch.append(alloc, perm_text);

        const row = try alloc.alloc(glyphwire.Client.TableCellInput, 3);
        row[0] = .{ .display = name_text, .icon = iconForEntry(entry), .fg = name_fg, .metadata_id = metadata_id };
        row[1] = .{ .display = size_text, .sort_key = .{ .number = @floatFromInt(entry.size) }, .fg = detail_color, .metadata_id = metadata_id };
        row[2] = .{ .display = perm_text, .fg = detail_color, .metadata_id = metadata_id };
        rows[i] = row;
    }

    try client.tableSetRows(null, table, rows);

    const state = try client.tableGetState(null, table);
    try client.setCursor(state.painted.row + state.painted.rows, 0);
}

fn writePlain(io: std.Io, entries: []const FileEntry, long_list: bool) !void {
    var buf: [4096]u8 = undefined;
    var w = std.Io.File.stdout().writer(io, &buf);
    for (entries) |entry| {
        switch (entry.kind) {
            .directory => try w.interface.print("{s}/", .{entry.name}),
            .sym_link => if (entry.link_target) |tgt|
                try w.interface.print("{s} -> {s}", .{ entry.name, tgt })
            else
                try w.interface.print("{s}", .{entry.name}),
            else => try w.interface.print("{s}", .{entry.name}),
        }
        if (long_list) {
            var size_buf: [16]u8 = undefined;
            var time_buf: [20]u8 = undefined;
            try w.interface.print("  {s}  {s}", .{ formatSize(&size_buf, entry.size), formatTimestamp(&time_buf, entry.mtime_sec) });
        }
        try w.interface.print("\n", .{});
    }
    try w.interface.flush();
}
