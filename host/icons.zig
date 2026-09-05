const std = @import("std");
const glyphwire = @import("glyphwire");

/// Recursively walks `root` and registers every `.png` under it into
/// `ctx`'s flat icon catalog, named by its path beneath `root` with the
/// extension removed (`core.iconName` -- so `oxygen/folder.png` ->
/// `oxygen/folder`, `box/tl.png` -> `box/tl`). This replaces the old
/// hand-maintained `default_*_manifest` arrays: the file layout under a
/// directory is the manifest now.
///
/// Called twice at startup: once on the bundled `assets/icons/`, then
/// once on `~/.config/glyphwire/icons/` (`warn_if_absent = false` --
/// that directory is optional). `registerIcon` overwrites by name, so a
/// user file at the same relative path replaces the bundled icon, and a
/// new relative path just adds one. The real file I/O lives here rather
/// than in `core.zig` (headless-first). Logs and skips anything that
/// can't be read/decoded rather than failing startup.
pub fn loadIconsFromDir(io: std.Io, alloc: std.mem.Allocator, ctx: *glyphwire.Context, root: []const u8, prefix: []const u8, warn_if_absent: bool) void {
    var dir = std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch |err| {
        if (warn_if_absent or err != error.FileNotFound) {
            std.log.warn("glyphwire-host: couldn't open icon directory '{s}': {t}", .{ root, err });
        }
        return;
    };
    defer dir.close(io);
    scanIconDir(io, alloc, ctx, dir, prefix);
}

/// One directory level of `loadIconsFromDir`'s walk. `prefix` is the path
/// from the scan root to `dir` (empty at the root), used to build each
/// icon's catalog name.
fn scanIconDir(io: std.Io, alloc: std.mem.Allocator, ctx: *glyphwire.Context, dir: std.Io.Dir, prefix: []const u8) void {
    var it = dir.iterate();
    while (it.next(io) catch |err| {
        std.log.warn("glyphwire-host: icon directory iteration failed under '{s}': {t}", .{ prefix, err });
        return;
    }) |entry| {
        // The file-type icon *themes* live under `filetype/<theme>/` and
        // are loaded separately, under the canonical `file/` prefix, by
        // whichever one `host.conf`'s `icon_theme` selects -- so the
        // generic walk skips the whole subtree.
        if (prefix.len == 0 and entry.kind == .directory and std.mem.eql(u8, entry.name, "filetype")) continue;

        // `entry.name` is only valid until the next `it.next`, so build
        // the relative path (and use it) before iterating further.
        const rel = if (prefix.len == 0)
            alloc.dupe(u8, entry.name) catch continue
        else
            std.fmt.allocPrint(alloc, "{s}/{s}", .{ prefix, entry.name }) catch continue;
        defer alloc.free(rel);

        switch (entry.kind) {
            .directory => {
                var sub = dir.openDir(io, entry.name, .{ .iterate = true }) catch |err| {
                    std.log.warn("glyphwire-host: couldn't open icon subdirectory '{s}': {t}", .{ rel, err });
                    continue;
                };
                defer sub.close(io);
                scanIconDir(io, alloc, ctx, sub, rel);
            },
            .file, .sym_link => {
                const name = glyphwire.iconName(rel) orelse continue;
                const bytes = dir.readFileAlloc(io, entry.name, alloc, .limited(16 * 1024 * 1024)) catch |err| {
                    std.log.warn("glyphwire-host: couldn't read icon '{s}': {t}", .{ rel, err });
                    continue;
                };
                defer alloc.free(bytes);

                const handle = ctx.loadImage(.png, bytes) catch |err| {
                    std.log.warn("glyphwire-host: couldn't load icon '{s}': {t}", .{ rel, err });
                    continue;
                };
                const replacing = ctx.iconHandle(name) != null;
                ctx.registerIcon(name, handle) catch |err| {
                    std.log.warn("glyphwire-host: couldn't register icon '{s}': {t}", .{ name, err });
                    continue;
                };
                if (replacing) std.log.info("glyphwire-host: icon '{s}' overridden by a user file", .{name});
            },
            else => {},
        }
    }
}

/// Loads one file-type icon theme -- every `.png` directly under
/// `assets/icons/filetype/<theme>/` -- registering each under the
/// canonical `file/<name>` and, for back-compat with configs / demos that
/// still say `oxygen/<name>`, that name too (`registerIcon` is
/// last-write-wins, and the user-icon scan still runs after this to
/// override either). Returns whether the directory existed and held at
/// least one icon, so `main` can fall back to `oxygen`. Not recursive: a
/// theme is a flat set of buckets.
pub fn loadFiletypeTheme(io: std.Io, alloc: std.mem.Allocator, ctx: *glyphwire.Context, theme_dir: []const u8) bool {
    var dir = std.Io.Dir.cwd().openDir(io, theme_dir, .{ .iterate = true }) catch return false;
    defer dir.close(io);

    var loaded: usize = 0;
    var it = dir.iterate();
    while (it.next(io) catch return loaded > 0) |entry| {
        if (entry.kind != .file and entry.kind != .sym_link) continue;
        const base = glyphwire.iconName(entry.name) orelse continue; // strips `.png`

        const bytes = dir.readFileAlloc(io, entry.name, alloc, .limited(16 * 1024 * 1024)) catch |err| {
            std.log.warn("glyphwire-host: couldn't read theme icon '{s}/{s}': {t}", .{ theme_dir, entry.name, err });
            continue;
        };
        defer alloc.free(bytes);

        const handle = ctx.loadImage(.png, bytes) catch |err| {
            std.log.warn("glyphwire-host: couldn't load theme icon '{s}/{s}': {t}", .{ theme_dir, entry.name, err });
            continue;
        };

        for ([_][]const u8{ "file", "oxygen" }) |ns| {
            const name = std.fmt.allocPrint(alloc, "{s}/{s}", .{ ns, base }) catch continue;
            defer alloc.free(name);
            ctx.registerIcon(name, handle) catch |err| {
                std.log.warn("glyphwire-host: couldn't register '{s}': {t}", .{ name, err });
            };
        }
        loaded += 1;
    }
    return loaded > 0;
}
