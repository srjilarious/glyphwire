const std = @import("std");
const glyphwire = @import("glyphwire");
const host_eng = @import("host_eng");

const config = @import("config.zig");
const geometry = @import("geometry.zig");

const HostConfig = config.HostConfig;

/// `host.conf` is a Lua script, so this file needs a Lua state -- but
/// nothing about parsing a config file belongs to the graphics engine, so
/// it drives `ziglua` directly (`runConfigScript` below) instead of going
/// through an engine scripting subsystem. It still reaches `ziglua`
/// through the engine facade (`host_eng.ziglua`) rather than importing the
/// module by name: `host_eng` and `glyphwire` are each given a `ziglua`
/// import in `build.zig`, and linking two Lua C libraries into one binary
/// would collide. Going through the facade names the one Lua this binary
/// actually links.
const Lua = host_eng.ziglua.Lua;

/// Owned path to glyphwire's config directory (holds `host.conf`).
/// Shared with glyphwire-shell and glyphwire-ls -- see
/// `glyphwire.configDirPath`.
const configDirPath = glyphwire.configDirPath;

/// Reads a string field named `key` from the `config` table on the Lua
/// stack top and returns a process-lifetime (`arena`) copy of it, or null
/// when the field is absent or not a string. The table stays on the stack;
/// only the field value pushed here is popped.
fn luaStrField(lua: *Lua, arena: std.mem.Allocator, key: [:0]const u8) ?[:0]const u8 {
    _ = lua.getField(-1, key);
    defer lua.pop(1);
    if (!lua.isString(-1)) return null;
    const s = lua.toString(-1) catch return null;
    return std.mem.concatWithSentinel(arena, u8, &.{s}, 0) catch null;
}

/// Like `luaStrField`, for a numeric field.
fn luaNumField(lua: *Lua, key: [:0]const u8) ?f32 {
    _ = lua.getField(-1, key);
    defer lua.pop(1);
    if (!lua.isNumber(-1)) return null;
    const n = lua.toNumber(-1) catch return null;
    return @floatCast(n);
}

/// Like `luaStrField`, for a boolean field. Absent or non-boolean -> null.
fn luaBoolField(lua: *Lua, key: [:0]const u8) ?bool {
    _ = lua.getField(-1, key);
    defer lua.pop(1);
    if (!lua.isBoolean(-1)) return null;
    return lua.toBoolean(-1);
}

/// Like `luaNumField`, for a non-negative whole-number field (`grid_cols`,
/// `grid_rows`, `scrollback_rows`). Absent, non-number, negative, or
/// non-integral -> null (the caller keeps the default).
fn luaUintField(lua: *Lua, key: [:0]const u8) ?usize {
    _ = lua.getField(-1, key);
    defer lua.pop(1);
    if (!lua.isNumber(-1)) return null;
    const n = lua.toNumber(-1) catch return null;
    if (n < 0 or n != @floor(n)) return null;
    return @intFromFloat(n);
}

/// Compiles and runs `code` in `lua`. On a compile or runtime error Lua
/// leaves its message on the stack top; log it and pop before returning so
/// the caller can fall back to defaults with the state still clean.
fn runConfigScript(lua: *Lua, code: [:0]const u8) !void {
    lua.loadString(code) catch {
        std.log.err("glyphwire-host: {s}", .{lua.toString(-1) catch "?"});
        lua.pop(1);
        return error.SyntaxError;
    };
    lua.protectedCall(.{ .args = 0, .results = 0, .msg_handler = 0 }) catch {
        std.log.err("glyphwire-host: {s}", .{lua.toString(-1) catch "?"});
        lua.pop(1);
        return error.ScriptError;
    };
}

/// Resolves everything `host.conf` controls for this run: starts from the
/// `*_default` constants and overlays whatever the global `config` table
/// in `~/.config/glyphwire/host.conf` (see `configDirPath`) sets -- font
/// fields (`font_face`, `font_face_name`, `font_fallback`, `font_size`),
/// caret fields (`cursor_shape`, `cursor_blink`, `cursor_blink_ms`), and
/// grid fields (`grid_cols`, `grid_rows`, `scrollback_rows`), any subset.
/// A missing file (or no config home at all) is the normal case and is
/// silent; a file that fails to read/parse, or a `config` that isn't a
/// table, logs a warning and the defaults stand.
/// `font_size` is clamped to `[min_font_size, max_font_size]`,
/// `cursor_blink_ms` to `[cursor_blink_ms_min, cursor_blink_ms_max]`,
/// `grid_cols` / `grid_rows` up to `min_grid_*`, and `scrollback_rows`
/// down to `scrollback_rows_max` (see the `config.clamp*` helpers). A
/// `--grid-cols` / `--grid-rows` flag still wins over `grid_cols` /
/// `grid_rows` (applied later, in `main`). `gpa` is used only for transient
/// work (the config path, the source buffer, the Lua state); returned
/// strings are `arena`-allocated so they outlive this call.
pub fn loadConfig(
    arena: std.mem.Allocator,
    gpa: std.mem.Allocator,
    io: std.Io,
    environ_map: *const std.process.Environ.Map,
) HostConfig {
    var cfg: HostConfig = .{};

    const config_dir = configDirPath(gpa, environ_map) catch |err| switch (err) {
        // No $GLYPHWIRE_CONFIG_DIR / $XDG_CONFIG_HOME / $HOME -- nowhere to
        // read a config from; run on defaults, same as a missing file.
        error.NoConfigHome => return cfg,
        error.OutOfMemory => return cfg,
    };
    defer gpa.free(config_dir);

    const path = std.fs.path.join(gpa, &.{ config_dir, config.host_conf_name }) catch return cfg;
    defer gpa.free(path);

    const src = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(256 * 1024)) catch |err| {
        if (err != error.FileNotFound)
            std.log.warn("glyphwire-host: couldn't read {s} ({t}); using defaults", .{ path, err });
        return cfg;
    };
    defer gpa.free(src);
    const src_z = std.mem.concatWithSentinel(gpa, u8, &.{src}, 0) catch return cfg;
    defer gpa.free(src_z);

    const lua = Lua.init(gpa) catch |err| {
        std.log.warn("glyphwire-host: Lua init failed ({t}); using defaults", .{err});
        return cfg;
    };
    defer lua.deinit();
    lua.openLibs();

    runConfigScript(lua, src_z) catch |err| {
        std.log.warn("glyphwire-host: {s} failed to run ({t}); using defaults", .{ config.host_conf_name, err });
        return cfg;
    };

    _ = lua.getGlobal("config") catch return cfg;
    defer lua.pop(1);
    if (!lua.isTable(-1)) {
        std.log.warn("glyphwire-host: {s} defines no `config` table; using defaults", .{config.host_conf_name});
        return cfg;
    }

    if (luaStrField(lua, arena, "font_face")) |v| cfg.font.face = v;
    if (luaStrField(lua, arena, "font_face_name")) |v| cfg.font.face_name = v;
    if (luaStrField(lua, arena, "font_fallback")) |v| cfg.font.fallback = v;
    if (luaNumField(lua, "font_size")) |v| cfg.font.size = v;

    if (luaStrField(lua, arena, "icon_theme")) |v| cfg.icon_theme = v;

    const clamped = config.clampFontSize(cfg.font.size);
    if (clamped != cfg.font.size) {
        std.log.warn("glyphwire-host: host.conf font_size {d} out of range; clamped to {d}", .{ cfg.font.size, clamped });
        cfg.font.size = clamped;
    }

    if (luaStrField(lua, arena, "cursor_shape")) |v| {
        if (config.cursorShapeFromStr(v)) |shape| {
            cfg.cursor.shape = shape;
        } else {
            std.log.warn("glyphwire-host: host.conf cursor_shape '{s}' unknown; keeping '{t}'", .{ v, cfg.cursor.shape });
        }
    }
    if (luaBoolField(lua, "cursor_blink")) |v| cfg.cursor.blink = v;
    if (luaNumField(lua, "cursor_blink_ms")) |v| {
        cfg.cursor.blink_ms = config.clampBlinkMs(@as(f64, v));
        if (cfg.cursor.blink_ms != v)
            std.log.warn("glyphwire-host: host.conf cursor_blink_ms {d} out of range; clamped to {d}", .{ v, cfg.cursor.blink_ms });
    }

    if (luaBoolField(lua, "profile")) |v| cfg.profile.enabled = v;
    if (luaBoolField(lua, "profile_hud")) |v| cfg.profile.hud = v;
    if (luaBoolField(lua, "profile_force_redraw")) |v| cfg.profile.force_redraw = v;
    if (luaNumField(lua, "profile_window_ms")) |v| {
        const c = config.clampProfileWindowMs(@as(f64, v));
        if (c != @as(f64, v))
            std.log.warn("glyphwire-host: host.conf profile_window_ms {d} out of range; clamped to {d}", .{ v, c });
        cfg.profile.window_ms = c;
    }
    if (luaNumField(lua, "profile_log_ms")) |v| {
        const c = config.clampProfileLogMs(@as(f64, v));
        if (c != @as(f64, v) and v > 0)
            std.log.warn("glyphwire-host: host.conf profile_log_ms {d} out of range; clamped to {d}", .{ v, c });
        cfg.profile.log_interval_ms = c;
    }

    if (luaUintField(lua, "grid_cols")) |v| {
        const c = config.clampGridCols(v);
        if (c != v)
            std.log.warn("glyphwire-host: host.conf grid_cols {d} below minimum {d}; clamped", .{ v, geometry.min_grid_cols });
        cfg.grid.cols = c;
    }
    if (luaUintField(lua, "grid_rows")) |v| {
        const r = config.clampGridRows(v);
        if (r != v)
            std.log.warn("glyphwire-host: host.conf grid_rows {d} below minimum {d}; clamped", .{ v, geometry.min_grid_rows });
        cfg.grid.rows = r;
    }
    if (luaUintField(lua, "scrollback_rows")) |v| {
        const s = config.clampScrollback(v);
        if (s != v)
            std.log.warn("glyphwire-host: host.conf scrollback_rows {d} above maximum {d}; clamped", .{ v, config.scrollback_rows_max });
        cfg.grid.scrollback = s;
    }

    return cfg;
}
