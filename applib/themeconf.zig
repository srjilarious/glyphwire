// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: MPL-2.0

//! Reading `config.theme` and `config.themes` out of a Lua config, for
//! zoe (`zoe/langconf.zig`, inside its full `zoe.conf.lua` parse) and
//! gw-grep (`loadZoeTheme`, which runs `zoe.conf.lua` for the theme
//! alone so grep results match the editor).
//!
//! Its own build module rather than part of `applib`: it is the one
//! piece that needs `ziglua`, and every other `applib` user would
//! otherwise have to link the Lua C library for nothing.
//!
//! The shapes it accepts:
//!
//!   theme = "tokyo-night"                    -- a built-in or `themes` name
//!   theme = { base = "nord", keyword = "#81a1c1", ui = { ... } }
//!   theme = { keyword = "#c678dd" }          -- overrides on `default`
//!   themes = { mine = { base = "...", palette = { ... }, ... } }
//!
//! A theme table: `base` (a theme name), `dark` (boolean), `panel_style`
//! (a nine-patch style name), `palette = {...}` and `ui = {...}`
//! (`#rrggbb` by `theme.Palette` / `theme.Ui` field name), and every
//! other key a capture-group colour (`keyword`, `["string.escape"]`).
//! Bad names and colours are logged and skipped, never fatal.

const std = @import("std");
const ziglua = @import("ziglua");
const glyphwire = @import("glyphwire");
const applib = @import("applib");

const theme = applib.theme;
const syntax = applib.syntax;
const Lua = ziglua.Lua;

const conf_name = "zoe.conf.lua";

/// What `config` said about themes. Strings are in the caller's arena.
pub const Parsed = struct {
    /// The theme to start in. Null when `config.theme` is absent.
    name: ?[]const u8 = null,
    /// `config.themes`, plus the table form of `config.theme` as a theme
    /// named `table_theme_name`.
    customs: []const theme.Custom = &.{},

    /// The theme to run with: `name` if it resolves, otherwise `default`
    /// (logging why).
    pub fn resolveOrDefault(self: Parsed) theme.Theme {
        const n = self.name orelse theme.default_name;
        if (theme.resolve(n, self.customs)) |t| return t;
        std.log.warn("{s}: theme \"{s}\" is not a built-in or a `themes` entry, or its `base` chain loops; using \"{s}\"", .{ conf_name, n, theme.default_name });
        return theme.initDefault();
    }
};

/// What the table form of `config.theme` is called once parsed, which is
/// also what `:theme` switches back to it by.
pub const table_theme_name = "config";

/// Reads `theme` / `themes` from the `config` table on top of `lua`'s
/// stack. Leaves the stack as it found it.
pub fn read(lua: *Lua, a: std.mem.Allocator) Parsed {
    var customs: std.ArrayList(theme.Custom) = .empty;
    var out: Parsed = .{};

    if (lua.getField(-1, "themes") == .table) {
        lua.pushNil();
        while (lua.next(-2)) {
            defer lua.pop(1);
            if (lua.typeOf(-2) != .string) continue;
            const name = dupe(lua, a, -2) orelse continue;
            if (lua.typeOf(-1) != .table) {
                std.log.warn("{s}: themes.{s} is not a table; ignored", .{ conf_name, name });
                continue;
            }
            customs.append(a, readTable(lua, a, name)) catch continue;
        }
    }
    lua.pop(1);

    switch (lua.getField(-1, "theme")) {
        .string => out.name = dupe(lua, a, -1),
        .table => {
            customs.append(a, readTable(lua, a, table_theme_name)) catch {};
            out.name = table_theme_name;
        },
        .nil => {},
        else => std.log.warn("{s}: `theme` is neither a name nor a table; ignored", .{conf_name}),
    }
    lua.pop(1);

    out.customs = customs.toOwnedSlice(a) catch &.{};
    return out;
}

/// One theme table, on top of the stack.
fn readTable(lua: *Lua, a: std.mem.Allocator, name: []const u8) theme.Custom {
    var c: theme.Custom = .{ .name = name };
    var syn: std.ArrayList(theme.NamedColor) = .empty;

    lua.pushNil();
    while (lua.next(-2)) {
        defer lua.pop(1);
        // A strict type check, not `isString`: `toString` on a number key
        // converts it in place and breaks `next`.
        if (lua.typeOf(-2) != .string) continue;
        const key = lua.toString(-2) catch continue;

        if (std.mem.eql(u8, key, "base")) {
            if (lua.typeOf(-1) == .string) c.base = dupe(lua, a, -1);
            continue;
        }
        if (std.mem.eql(u8, key, "dark")) {
            if (lua.typeOf(-1) == .boolean) c.dark = lua.toBoolean(-1);
            continue;
        }
        if (std.mem.eql(u8, key, "panel_style")) {
            if (lua.typeOf(-1) == .string) c.panel_style = dupe(lua, a, -1);
            continue;
        }
        if (std.mem.eql(u8, key, "palette")) {
            c.palette = readColors(lua, a, name, "palette", theme.Palette.has);
            continue;
        }
        if (std.mem.eql(u8, key, "ui")) {
            c.ui = readColors(lua, a, name, "ui", theme.Ui.has);
            continue;
        }
        if (!isGroup(key)) {
            std.log.warn("{s}: theme {s}: {s} is not a known highlight group; ignored", .{ conf_name, name, key });
            continue;
        }
        const color = colorAt(lua, name, key) orelse continue;
        syn.append(a, .{ .name = a.dupe(u8, key) catch continue, .color = color }) catch continue;
    }
    c.syntax = syn.toOwnedSlice(a) catch &.{};
    return c;
}

/// A `palette` / `ui` sub-table (on top of the stack) of `name = "#hex"`.
fn readColors(
    lua: *Lua,
    a: std.mem.Allocator,
    theme_name: []const u8,
    comptime what: []const u8,
    comptime known: fn ([]const u8) bool,
) []const theme.NamedColor {
    if (lua.typeOf(-1) != .table) {
        std.log.warn("{s}: theme {s}: `{s}` is not a table; ignored", .{ conf_name, theme_name, what });
        return &.{};
    }
    var out: std.ArrayList(theme.NamedColor) = .empty;
    lua.pushNil();
    while (lua.next(-2)) {
        defer lua.pop(1);
        if (lua.typeOf(-2) != .string) continue;
        const key = lua.toString(-2) catch continue;
        if (!known(key)) {
            std.log.warn("{s}: theme {s}: {s}.{s} is not a known {s} colour; ignored", .{ conf_name, theme_name, what, key, what });
            continue;
        }
        const color = colorAt(lua, theme_name, key) orelse continue;
        out.append(a, .{ .name = a.dupe(u8, key) catch continue, .color = color }) catch continue;
    }
    return out.toOwnedSlice(a) catch &.{};
}

/// The `#rrggbb` value on top of the stack, or null (logged).
fn colorAt(lua: *Lua, theme_name: []const u8, key: []const u8) ?glyphwire.Color {
    if (lua.typeOf(-1) != .string) {
        std.log.warn("{s}: theme {s}: {s} is not a \"#rrggbb\" string; ignored", .{ conf_name, theme_name, key });
        return null;
    }
    const val = lua.toString(-1) catch return null;
    return theme.parseHex(val) orelse {
        std.log.warn("{s}: theme {s}: {s} = \"{s}\" is not a #rrggbb colour; ignored", .{ conf_name, theme_name, key, val });
        return null;
    };
}

fn isGroup(name: []const u8) bool {
    var probe = syntax.Theme{ .colors = .initFill(null) };
    return probe.setByName(name, .{ .r = 0, .g = 0, .b = 0 });
}

fn dupe(lua: *Lua, a: std.mem.Allocator, index: i32) ?[]const u8 {
    const s = lua.toString(index) catch return null;
    return a.dupe(u8, s) catch null;
}

/// The theme `zoe.conf.lua` picks, for a program that wants to match the
/// editor without reading the rest of its config (gw-grep). Runs the
/// whole script -- it is a plain Lua file -- and reads only the theme.
/// No file, or any error, is `default`. Everything the result borrows is
/// in `arena`.
pub fn loadZoeTheme(
    arena: std.mem.Allocator,
    gpa: std.mem.Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
) theme.Theme {
    const dir = glyphwire.configDirPath(arena, environ) catch return theme.initDefault();
    const path = std.fs.path.join(arena, &.{ dir, conf_name }) catch return theme.initDefault();
    const src = std.Io.Dir.cwd().readFileAllocOptions(io, path, arena, .limited(256 * 1024), .of(u8), 0) catch
        return theme.initDefault();
    return fromSource(arena, gpa, src);
}

/// `loadZoeTheme`'s parse, over config text already in hand.
pub fn fromSource(arena: std.mem.Allocator, gpa: std.mem.Allocator, src: [:0]const u8) theme.Theme {
    const lua = Lua.init(gpa) catch return theme.initDefault();
    defer lua.deinit();
    lua.openLibs();
    lua.doString(src) catch return theme.initDefault();
    _ = lua.getGlobal("config") catch return theme.initDefault();
    defer lua.pop(1);
    if (lua.typeOf(-1) != .table) return theme.initDefault();
    return read(lua, arena).resolveOrDefault();
}
