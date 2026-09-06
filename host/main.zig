const std = @import("std");
const glyphwire = @import("glyphwire");
const host_eng = @import("host_eng");

const app_mod = @import("app.zig");
const config = @import("config.zig");
const config_load = @import("config_load.zig");
const geometry = @import("geometry.zig");
const icons = @import("icons.zig");

pub const panic = host_eng.system.panic;
pub const std_options = host_eng.system.std_options;

/// glyphwire entry point. This file is deliberately thin: startup
/// wiring (config, fonts, icons, the in-process `Server` + its thread, the
/// gw-shell child) and then handing off to the engine's app runner.
/// Everything the running window does lives in `app.App` and the concern
/// sub-structs it owns (`caret.zig`, `input.zig`, `selection.zig`,
/// `scroll.zig`, `window_sizing.zig`, `render.zig`); the values `host.conf`
/// resolves live in `config.zig` / `config_load.zig`; shared pixel/cell
/// geometry lives in `geometry.zig`.
///
/// The initial grid size is `geometry.initial_grid_cols` x
/// `initial_grid_rows`; after startup the window is user-resizable and
/// `geometry.grid_cols` / `grid_rows` track its live size. `host.conf`'s
/// `grid_cols` / `grid_rows` (and `--grid-cols` / `--grid-rows`, which win
/// over the file) override the initial size here in `main`.
/// Waits for gw-shell to exit, then flags `shell_exited` so
/// `App.update` ends the window loop -- the shell process actually
/// terminating (via its `exit` builtin, a crash, or an external kill) is
/// what quits the host now, not a keypress. Not joined by `main`, same as
/// `serveForeverThread`: nothing needs its result once the run loop below
/// is what keeps the process alive.
fn reapChild(io: std.Io, child_in: std.process.Child, shell_exited: *std.atomic.Value(bool)) void {
    var child = child_in;
    _ = child.wait(io) catch {};
    shell_exited.store(true, .monotonic);
}

/// Runs `Server.serveForever` for the lifetime of the process, on its own
/// thread -- not joined, same as the reaped child processes below: it
/// keeps serving gw-shell (and any other socket client) for as long
/// as the process runs, and there's nothing to hand its result to once the
/// window/render loop below is what actually keeps the process alive.
fn serveForeverThread(server: *glyphwire.server.Server, alloc: std.mem.Allocator) void {
    server.serveForever(alloc) catch |err| {
        std.log.err("glyphwire server stopped: {t}", .{err});
    };
}

fn socketPath(alloc: std.mem.Allocator, environ_map: *const std.process.Environ.Map) ![]const u8 {
    const dir = environ_map.get("XDG_RUNTIME_DIR") orelse "/tmp";
    const pid = std.os.linux.getpid();
    return std.fmt.allocPrint(alloc, "{s}/glyphwire-{d}.sock", .{ dir, pid });
}

/// Resolves a sibling binary from this process's executable directory. The
/// `zig build glyphwire` run step sets `GLYPHWIRE_BIN_DIR` because Zig may
/// execute the just-built binary from its cache rather than `zig-out/bin`;
/// installed runs use the executable directory directly.
fn resolveSibling(alloc: std.mem.Allocator, io: std.Io, environ_map: *const std.process.Environ.Map, name: []const u8) ![]const u8 {
    if (environ_map.get("GLYPHWIRE_BIN_DIR")) |dir| {
        return std.fs.path.join(alloc, &.{ dir, name });
    }
    const exe_dir = try std.process.executableDirPathAlloc(io, alloc);
    return std.fs.path.join(alloc, &.{ exe_dir, name });
}

/// Resolves bundled assets. Runtime intentionally has two ways to find
/// them: an explicit environment override, then the installed
/// `<prefix>/bin/glyphwire` -> `<prefix>/share/glyphwire/assets` layout.
fn resolveAssetDir(alloc: std.mem.Allocator, io: std.Io, environ_map: *const std.process.Environ.Map) ![]const u8 {
    if (environ_map.get("GLYPHWIRE_ASSET_DIR")) |dir| {
        return alloc.dupe(u8, dir);
    }
    const exe_dir = try std.process.executableDirPathAlloc(io, alloc);
    return std.fs.path.resolve(alloc, &.{ exe_dir, "..", "share", "glyphwire", "assets" });
}

fn bundledAssetPath(alloc: std.mem.Allocator, asset_dir: []const u8, rel_path: []const u8) ![:0]const u8 {
    return std.fs.path.joinZ(alloc, &.{ asset_dir, rel_path });
}

fn resolveDefaultAssetPath(
    alloc: std.mem.Allocator,
    asset_dir: []const u8,
    path: [:0]const u8,
    default_rel_path: []const u8,
) ![:0]const u8 {
    const legacy_prefix = "assets/";
    if (std.mem.eql(u8, path, default_rel_path) or
        (std.mem.startsWith(u8, path, legacy_prefix) and std.mem.eql(u8, path[legacy_prefix.len..], default_rel_path)))
    {
        return bundledAssetPath(alloc, asset_dir, default_rel_path);
    }
    return path;
}

pub fn main(init: std.process.Init) !void {
    std.log.info("glyphwire host starting", .{});
    const alloc = init.gpa;
    // Process-lifetime setup values (args, paths, the shell's argv/environ)
    // that are never freed -- deliberately, they're needed until the
    // process exits below -- so they're allocated from `init.arena`
    // (reclaimed automatically on exit) rather than `alloc`, whose
    // DebugAllocator would otherwise flag every one of them as a leak.
    // Mirrors `server/main.zig`'s `args` allocation.
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);
    const asset_dir = try resolveAssetDir(arena, io, init.environ_map);

    // Font face/size/fallback, caret shape/blink, and initial grid size /
    // scrollback: `~/.config/glyphwire/host.conf` if present, else the
    // `*_default` constants in `config.zig`. Loaded before the arg loop so
    // a `--grid-cols` / `--grid-rows` flag can still override `host.conf`'s
    // `grid_cols` / `grid_rows`.
    const host_cfg = config_load.loadConfig(arena, alloc, io, init.environ_map);
    var font_cfg = host_cfg.font;
    font_cfg.face = try resolveDefaultAssetPath(arena, asset_dir, font_cfg.face, config.font_path_default);
    font_cfg.fallback = try resolveDefaultAssetPath(arena, asset_dir, font_cfg.fallback, config.font_fallback_default);
    if (host_cfg.grid.cols) |v| geometry.grid_cols = v;
    if (host_cfg.grid.rows) |v| geometry.grid_rows = v;
    if (host_cfg.grid.scrollback) |v| config.scrollback_rows = v;

    // Host-only options are pulled out here; everything else is forwarded
    // to gw-shell (an empty forward list = the shell's own
    // interactive prompt, its no-args mode, rather than exec'ing a child).
    //   --screenshot <path>          write the grid region to <path> (PNG) then quit
    //   --screenshot-delay-ms <n>    wait n ms before capturing (default 2500)
    //   --grid-cols <n> / --grid-rows <n>   open at a non-default grid size,
    //                                overriding host.conf's grid_cols / grid_rows
    //                                (handy for a screenshot whose output is
    //                                taller/wider than the default 120x50)
    var screenshot_path: ?[]const u8 = null;
    var screenshot_delay_ms: f64 = 2500;
    var forwarded: std.ArrayList([]const u8) = .empty;
    {
        var i: usize = 1;
        while (i < args.len) : (i += 1) {
            const a = args[i];
            if (std.mem.eql(u8, a, "--screenshot") and i + 1 < args.len) {
                i += 1;
                screenshot_path = args[i];
            } else if (std.mem.eql(u8, a, "--screenshot-delay-ms") and i + 1 < args.len) {
                i += 1;
                screenshot_delay_ms = std.fmt.parseFloat(f64, args[i]) catch screenshot_delay_ms;
            } else if (std.mem.eql(u8, a, "--grid-cols") and i + 1 < args.len) {
                i += 1;
                geometry.grid_cols = @max(geometry.min_grid_cols, std.fmt.parseInt(usize, args[i], 10) catch geometry.grid_cols);
            } else if (std.mem.eql(u8, a, "--grid-rows") and i + 1 < args.len) {
                i += 1;
                geometry.grid_rows = @max(geometry.min_grid_rows, std.fmt.parseInt(usize, args[i], 10) catch geometry.grid_rows);
            } else {
                try forwarded.append(arena, a);
            }
        }
    }
    const shell_child_argv: []const []const u8 = forwarded.items;

    const socket_path = try socketPath(arena, init.environ_map);

    // The primary font may be a `.ttc` collection; find the index of the
    // named face inside it so both the metrics measured here and the atlas
    // packed later (in AppRunner.init) use the same face. A plain `.ttf`
    // has no named faces, so this falls through to face 0.
    const font_face_index: i32 = blk: {
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, font_cfg.face, alloc, .limited(64 * 1024 * 1024)) catch |err| {
            std.log.err("failed to read font '{s}': {t}", .{ font_cfg.face, err });
            return err;
        };
        defer alloc.free(bytes);
        break :blk host_eng.renderer.findFaceIndexByName(bytes, font_cfg.face_name) orelse 0;
    };

    // Measuring metrics needs only the font's own bytes (stb_truetype's
    // InitFont/GetFontVMetrics/GetCodepointHMetrics), not a GL context, so
    // this can run before the window exists -- unlike packing the font into
    // an atlas texture, which does need one (see AppRunner.init below).
    // That means the window can be sized correctly for whatever font is
    // configured instead of a size tuned by hand for one specific font.
    const metrics = try host_eng.renderer.measureFontFileIndexed(font_cfg.face, font_face_index, font_cfg.size, alloc);
    geometry.cell_w = metrics.advance;
    geometry.cell_h = metrics.line_height;

    var ctx = try glyphwire.Context.init(alloc, geometry.grid_cols, geometry.grid_rows, config.scrollback_rows);
    defer ctx.deinit();
    // Context.init defaults these to 12x12 already; set explicitly so they
    // stay tied to this file's own cell_w/cell_h (now measured from
    // `font_path` above) rather than silently relying on the default
    // matching -- see Context's doc comment on cell_px_w/cell_px_h.
    ctx.setCellMetrics(@intCast(geometry.cell_w), @intCast(geometry.cell_h));
    const icons_dir = try std.fs.path.join(arena, &.{ asset_dir, "icons" });
    icons.loadIconsFromDir(io, alloc, &ctx, icons_dir, "", true);
    // The file-type icon set (`file/*`, aliased `oxygen/*`) comes from
    // whichever `<asset-dir>/icons/filetype/<theme>/` `host.conf`'s
    // `icon_theme` names -- Oxygen by default, else Papirus / Material.
    // An unknown or missing theme falls back to Oxygen.
    {
        const theme_dir = try std.fs.path.join(arena, &.{ asset_dir, "icons", "filetype", host_cfg.icon_theme });
        var ok = icons.loadFiletypeTheme(io, alloc, &ctx, theme_dir);
        if (!ok and !std.mem.eql(u8, host_cfg.icon_theme, config.default_icon_theme)) {
            const default_theme_dir = try std.fs.path.join(arena, &.{ asset_dir, "icons", "filetype", config.default_icon_theme });
            std.log.warn("glyphwire: icon_theme '{s}' not found under {s}; using '{s}'", .{ host_cfg.icon_theme, theme_dir, config.default_icon_theme });
            ok = icons.loadFiletypeTheme(io, alloc, &ctx, default_theme_dir);
        }
        if (!ok) std.log.warn("glyphwire: no file-type icon theme loaded under {s}/icons/filetype", .{asset_dir});
    }
    // User icons: new names and overrides of the bundled set, from
    // `~/.config/glyphwire/icons/` (same config dir as `host.conf`, see
    // `glyphwire.configDirPath`). Scanned last so a user file at a bundled
    // relative path -- `file/folder.png` included -- wins. Absent
    // directory is normal -- not warned.
    if (glyphwire.configDirPath(arena, init.environ_map)) |config_dir| {
        const user_icons = try std.fs.path.join(arena, &.{ config_dir, "icons" });
        icons.loadIconsFromDir(io, alloc, &ctx, user_icons, "", false);
    } else |_| {}

    // `.listen()` inside `bind` is synchronous -- the socket is already
    // accept-ready (kernel-queued, even before `serveForever`'s thread
    // starts calling `accept`) by the time this returns, so unlike the
    // old separate-process design, gw-shell can be spawned right
    // below with no wait-for-socket-ready polling loop needed.
    var srv = try glyphwire.server.Server.bind(io, &ctx, socket_path);
    defer srv.deinit(alloc);
    _ = try std.Thread.spawn(.{}, serveForeverThread, .{ &srv, alloc });

    var shell_env = try init.environ_map.clone(arena);
    try shell_env.put("GLYPHWIRE_SOCK", socket_path);
    try shell_env.put("GLYPHWIRE_CTX", glyphwire.default_context_id);

    const shell_path = try resolveSibling(arena, io, init.environ_map, "gw-shell");
    const shell_argv = try std.mem.concat(arena, []const u8, &.{ &.{shell_path}, shell_child_argv });

    // Left false (no other way to quit) if the spawn itself fails --
    // an edge case not worth a fallback keybinding for.
    var shell_exited: std.atomic.Value(bool) = .init(false);
    if (std.process.spawn(io, .{ .argv = shell_argv, .environ_map = &shell_env })) |shell_child| {
        _ = try std.Thread.spawn(.{}, reapChild, .{ io, shell_child, &shell_exited });
    } else |err| {
        std.log.err("failed to spawn gw-shell: {t}", .{err});
    }

    // Font atlas packing (unlike the metrics measured above) does need a GL
    // context, so it still happens here, after the window is created.
    const appRunner = try app_mod.AppRunner.init("glyphwire", alloc, .{
        .windowSize = .{
            // Open wide enough for all `grid_cols` cells *plus* the
            // always-on scrollbar and a `content_pad_px` margin on each
            // side of the grid (see `window_sizing.WindowSizing.syncWindowSize`,
            // which subtracts the same back out when converting a resize
            // to cells).
            .x = @as(i32, @intCast(geometry.grid_cols)) * geometry.cell_w + 2 * geometry.content_pad_px + geometry.scrollbar_width_px,
            .y = @as(i32, @intCast(geometry.grid_rows)) * geometry.cell_h,
        },
        .resizable = true,
        .renderInitOpts = .{ .font = .{ .path = .{ .face = font_cfg.face, .size = font_cfg.size, .face_index = font_face_index } } },
    });

    // Register the fallback face: codepoints the primary lacks are drawn
    // from it, and anything neither face has renders as the atlas's tofu
    // box. Non-fatal -- text still works from the primary alone.
    appRunner.engine.renderer.addDefaultFontFallback(&appRunner.engine.resources, font_cfg.fallback, 0) catch |err| {
        std.log.warn("could not add fallback font '{s}': {t}", .{ font_cfg.fallback, err });
    };

    // And a bundled Powerline-symbols subset (U+E0A0-E0D7) as a further
    // fallback, so a configured powerline shell prompt's separator /
    // rounded-cap glyphs render even though neither the CJK primary nor a
    // plain-Latin fallback covers that Private Use range.
    const powerline_symbols_path = try bundledAssetPath(arena, asset_dir, config.powerline_symbols_font);
    appRunner.engine.renderer.addDefaultFontFallback(&appRunner.engine.resources, powerline_symbols_path, 0) catch |err| {
        std.log.warn("could not add powerline symbols font '{s}': {t}", .{ powerline_symbols_path, err });
    };

    const app = try app_mod.App.init(alloc, appRunner.engine, &srv, &shell_exited, screenshot_path, screenshot_delay_ms, .{
        .path = font_cfg.face,
        .face_index = font_face_index,
        .size = font_cfg.size,
    }, host_cfg.cursor);

    appRunner.run(app);

    // `appRunner.run` only returns once the window closes, but
    // `serveForever`'s thread and any live per-connection threads (e.g.
    // the glyphwire-shell child, which is normally still connected) are
    // never joined -- see their own doc comments. Falling through to the
    // `ctx.deinit()`/`srv.deinit()` defers above would free `ctx` and the
    // listener out from under whichever of those threads is still
    // running, racing a live dispatch against `ctx` (unsynchronized: that
    // free doesn't take `srv.ctx_mutex`) and leaking each open
    // connection's still-alive `FrameDecoder` buffer. Exiting immediately
    // sidesteps all of that and lets the OS reclaim everything at once,
    // the same as how `server/main.zig` is only ever stopped externally.
    std.process.exit(0);
}
