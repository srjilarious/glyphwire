// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: MPL-2.0

const std = @import("std");
const glyphwire = @import("glyphwire");
const luaconf = @import("luaconf");

const config = @import("config.zig");
const geometry = @import("geometry.zig");
const key_repeat = @import("key_repeat.zig");
const dividers = @import("dividers.zig");

const HostConfig = config.HostConfig;

/// `host.conf.lua` is a Lua script, so this file needs a Lua state -- but
/// nothing about parsing a config file belongs to the graphics engine, so
/// it goes through `luaconf` like every other program's config instead of
/// an engine scripting subsystem. `luaconf`'s `ziglua` is the same module
/// `host_eng` links, so this binary still carries one Lua C library.
const Lua = luaconf.Lua;

const conf: luaconf.Conf = .{ .prog = "glyphwire-host", .name = config.host_conf_name };

/// A string field from the `config` table, as a process-lifetime
/// (`arena`) null-terminated copy.
fn strField(lua: *Lua, arena: std.mem.Allocator, key: [:0]const u8) ?[:0]const u8 {
    const s = conf.string(lua, key) orelse return null;
    return arena.dupeSentinel(u8, s, 0) catch null;
}

/// `font_fallback`: one font (`"Noto Sans CJK JP"`) or a list tried in
/// order (`{ "Noto Sans CJK JP", "Adwaita Mono" }`). Null when absent,
/// empty, or neither shape, so the default stands.
fn readFallbacks(lua: *Lua, arena: std.mem.Allocator) ?[]const [:0]const u8 {
    const key = "font_fallback";
    const t = lua.getField(-1, key);
    lua.pop(1);
    if (t == .string) {
        const one = strField(lua, arena, key) orelse return null;
        return arena.dupe([:0]const u8, &.{one}) catch null;
    }
    const list = conf.stringList(lua, arena, key) orelse return null;
    if (list.len == 0) return null;
    const out = arena.alloc([:0]const u8, list.len) catch return null;
    for (list, out) |s, *o| o.* = arena.dupeSentinel(u8, s, 0) catch return null;
    return out;
}

/// Resolves everything `host.conf.lua` controls for this run: starts from
/// the `*_default` constants and overlays whatever the global `config`
/// table in `~/.config/glyphwire/host.conf.lua` (see
/// `glyphwire.configDirPath`) sets -- font fields (`font_face`,
/// `font_face_name`, `font_fallback`, `font_size`), caret fields
/// (`cursor_shape`, `cursor_blink`, `cursor_blink_ms`), key repeat
/// (`key_repeat_delay_ms`, `key_repeat_interval_ms`), and grid fields
/// (`grid_cols`, `grid_rows`, `scrollback_rows`), any subset.
/// A missing file (or no config home at all) is the normal case and is
/// silent; a file that fails to read/parse logs a warning and the
/// defaults stand.
/// `font_size` is clamped to `[min_font_size, max_font_size]`,
/// `cursor_blink_ms` to `[cursor_blink_ms_min, cursor_blink_ms_max]`,
/// `grid_cols` / `grid_rows` up to `min_grid_*`, and `scrollback_rows`
/// down to `scrollback_rows_max` (the same bounds as the `config.clamp*`
/// helpers). A `--grid-cols` / `--grid-rows` flag still wins over
/// `grid_cols` / `grid_rows` (applied later, in `main`). `gpa` is used
/// only for transient work (the source buffer, the Lua state); returned
/// strings are `arena`-allocated so they outlive this call.
pub fn loadConfig(
    arena: std.mem.Allocator,
    gpa: std.mem.Allocator,
    io: std.Io,
    environ_map: *const std.process.Environ.Map,
) HostConfig {
    const src = conf.read(gpa, io, environ_map) orelse return .{};
    defer gpa.free(src);
    return parseSource(arena, gpa, src);
}

/// The parse half of `loadConfig`, over config text already in hand, so
/// `tests/host_tests.zig` can run it against a string.
pub fn parseSource(arena: std.mem.Allocator, gpa: std.mem.Allocator, src: [:0]const u8) HostConfig {
    var cfg: HostConfig = .{};
    var ctx: Apply = .{ .arena = arena, .cfg = &cfg };
    conf.runLogged(gpa, src, &ctx, Apply.apply);
    return cfg;
}

const Apply = struct {
    arena: std.mem.Allocator,
    cfg: *HostConfig,

    fn apply(self: *Apply, lua: *Lua) void {
        const cfg = self.cfg;
        const arena = self.arena;

        if (strField(lua, arena, "font_face")) |v| cfg.font.face = v;
        if (strField(lua, arena, "font_face_name")) |v| cfg.font.face_name = v;
        if (readFallbacks(lua, arena)) |v| cfg.font.fallbacks = v;
        if (conf.boolean(lua, "font_emoji")) |v| cfg.font.emoji = v;
        if (conf.number(lua, f32, "font_size", .{ .min = config.min_font_size, .max = config.max_font_size })) |v| cfg.font.size = v;

        if (strField(lua, arena, "icon_theme")) |v| cfg.icon_theme = v;

        readChordField(lua, arena, "context_switcher_key", &cfg.context_switcher);
        readChordField(lua, arena, "theme_switcher_key", &cfg.theme_switcher);

        if (conf.string(lua, "pane_divider_style")) |v| {
            if (dividers.preset(v)) |style| {
                cfg.pane_divider = style;
            } else {
                conf.warn("pane_divider_style '{s}' unknown (single, heavy, double, block); keeping the default", .{v});
            }
        }
        readDividerChars(lua, arena, &cfg.pane_divider);

        if (conf.number(lua, f32, "drop_target_opacity", .{ .min = config.drop_target_opacity_min, .max = 1.0 })) |v|
            cfg.drop_target_opacity = v;

        if (conf.string(lua, "cursor_shape")) |v| {
            if (config.cursorShapeFromStr(v)) |shape| {
                cfg.cursor.shape = shape;
            } else {
                conf.warn("cursor_shape '{s}' unknown; keeping '{t}'", .{ v, cfg.cursor.shape });
            }
        }
        if (conf.boolean(lua, "cursor_blink")) |v| cfg.cursor.blink = v;
        if (conf.number(lua, f64, "cursor_blink_ms", .{ .min = config.cursor_blink_ms_min, .max = config.cursor_blink_ms_max })) |v|
            cfg.cursor.blink_ms = v;

        if (conf.number(lua, f64, "key_repeat_delay_ms", .{ .min = key_repeat.delay_ms_min, .max = key_repeat.delay_ms_max })) |v|
            cfg.key_repeat.delay_ms = v;
        if (conf.number(lua, f64, "key_repeat_interval_ms", .{ .min = key_repeat.interval_ms_min, .max = key_repeat.interval_ms_max })) |v|
            cfg.key_repeat.interval_ms = v;

        if (conf.boolean(lua, "profile")) |v| cfg.profile.enabled = v;
        if (conf.boolean(lua, "profile_hud")) |v| cfg.profile.hud = v;
        if (conf.boolean(lua, "profile_force_redraw")) |v| cfg.profile.force_redraw = v;
        if (conf.number(lua, f64, "profile_window_ms", .{ .min = config.profile_window_ms_min, .max = config.profile_window_ms_max })) |v|
            cfg.profile.window_ms = v;
        // 0 or below means "no periodic summary", so it can't be a plain
        // range: only a positive value is clamped (and warned about).
        if (conf.number(lua, f64, "profile_log_ms", .{})) |v| {
            const c = config.clampProfileLogMs(v);
            if (c != v and v > 0)
                conf.warn("profile_log_ms {d} out of range; clamped to {d}", .{ v, c });
            cfg.profile.log_interval_ms = c;
        }

        if (conf.uint(lua, usize, "grid_cols", .{ .min = geometry.min_grid_cols })) |v| cfg.grid.cols = v;
        if (conf.uint(lua, usize, "grid_rows", .{ .min = geometry.min_grid_rows })) |v| cfg.grid.rows = v;
        if (conf.uint(lua, usize, "scrollback_rows", .{ .max = config.scrollback_rows_max })) |v| cfg.grid.scrollback = v;
    }
};

/// `pane_divider_chars`: a table of glyph overrides keyed by
/// `dividers.Glyphs`' field names (`h`, `v`, `cross`, `t_down`, ...). Any
/// subset; the rest keep the preset's. Over the `block` style it starts
/// from `single`, since naming glyphs only makes sense for a glyph style.
fn readDividerChars(lua: *Lua, arena: std.mem.Allocator, out: *dividers.Style) void {
    _ = lua.getField(-1, "pane_divider_chars");
    defer lua.pop(1);
    if (!lua.isTable(-1)) return;
    var glyphs: dividers.Glyphs = switch (out.*) {
        .glyphs => |g| g,
        .block => dividers.single,
    };
    inline for (@typeInfo(dividers.Glyphs).@"struct".field_names) |name| {
        if (strField(lua, arena, name)) |v| {
            if (glyphwire.stringWidth(v) == 1) {
                @field(glyphs, name) = v;
            } else {
                conf.warn("pane_divider_chars." ++ name ++ " '{s}' isn't one cell wide; keeping the preset's", .{v});
            }
        }
    }
    out.* = .{ .glyphs = glyphs };
}

/// A chord key (`context_switcher_key`, `theme_switcher_key`): a string
/// names the chord, `false` turns its dialog off, and anything else
/// keeps `out` as it was.
fn readChordField(lua: *Lua, arena: std.mem.Allocator, comptime name: [:0]const u8, out: *?config.Chord) void {
    switch (lua.getField(-1, name)) {
        .boolean => {
            if (!lua.toBoolean(-1)) out.* = null;
            lua.pop(1);
        },
        .string => {
            lua.pop(1);
            const v = strField(lua, arena, name) orelse return;
            if (config.parseChord(v)) |chord| {
                out.* = chord;
            } else {
                conf.warn(name ++ " '{s}' not a chord; keeping the default", .{v});
            }
        },
        .nil => lua.pop(1),
        else => {
            lua.pop(1);
            conf.warn(name ++ " must be a chord or false; ignored", .{});
        },
    }
}
