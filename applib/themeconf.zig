// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: MPL-2.0

//! Reading `config.theme` and `config.themes` out of a Lua config: the
//! shared `theme.lua` (glyphwire-host, and every program for the themes
//! it defines) and a program's own config (`zoe.conf.lua`, ...), whose
//! `theme` overrides the window's for that program alone.
//!
//! Its own build module rather than part of `applib`: it is the one
//! piece that needs `ziglua`, and every other `applib` user would
//! otherwise have to link the Lua C library for nothing. It depends on
//! nothing but `glyphwire` (the themes are `glyphwire.theme`), so the
//! host can use it too.
//!
//! The shapes it accepts:
//!
//!   theme = "tokyo-night"                    -- a built-in or `themes` name
//!   theme = { base = "nord", keyword = "bright_magenta", ... }
//!   themes = { mine = { base = "...", palette = { ... }, ... } }
//!
//! A theme table: `base` (a theme name), `dark` (boolean), `panel_style`
//! (a nine-patch style name), `palette = {...}` (`#rrggbb` by
//! `theme.Palette` field, re-derives everything), `slots = {...}`
//! (`#rrggbb` by slot name: `red`, `dim_red`, `bright_red`), `roles =
//! {...}`, and every other key a role too. A role's value is a slot name,
//! another role's name, `#rrggbb`, or a slot number 0-23. zoe's old `ui =
//! {...}` table and dotted capture names (`["string.escape"]`) still
//! work. Bad names and colours are logged and skipped, never fatal.

const std = @import("std");
const ziglua = @import("ziglua");
const glyphwire = @import("glyphwire");

const theme = glyphwire.theme;
const Lua = ziglua.Lua;

/// The shared theme config, in glyphwire's config directory.
pub const shared_conf_name = "theme.lua";

/// What `config` said about themes. Strings are in the caller's arena.
pub const Parsed = struct {
    /// The theme to run with. Null when `config.theme` is absent.
    name: ?[]const u8 = null,
    /// `config.themes`, plus the table form of `config.theme` as a theme
    /// named `table_theme_name`.
    customs: []const theme.Custom = &.{},
    /// The file this came from, for log lines.
    source: []const u8 = shared_conf_name,

    /// `name` resolved against this config's themes and then `shared`'s
    /// (so a program config can use a theme `theme.lua` defined), or null
    /// when `name` is absent. An unknown name is logged and is `default`.
    pub fn resolve(self: Parsed, arena: std.mem.Allocator, shared: Parsed) ?theme.Theme {
        const n = self.name orelse return null;
        const all = std.mem.concat(arena, theme.Custom, &.{ shared.customs, self.customs }) catch self.customs;
        if (theme.resolve(n, all)) |t| return t;
        std.log.warn("{s}: theme \"{s}\" is not a built-in or a `themes` entry, or its `base` chain loops; using \"{s}\"", .{ self.source, n, theme.default_name });
        return theme.initDefault();
    }

    /// `resolve`, or `default` when no theme is named.
    pub fn resolveOrDefault(self: Parsed, arena: std.mem.Allocator, shared: Parsed) theme.Theme {
        return self.resolve(arena, shared) orelse theme.initDefault();
    }
};

/// What the table form of `config.theme` is called once parsed, which is
/// also what `:theme` switches back to it by.
pub const table_theme_name = "config";

/// Reads `theme` / `themes` from the `config` table on top of `lua`'s
/// stack. Leaves the stack as it found it. `source` names the file in
/// log lines.
pub fn read(lua: *Lua, a: std.mem.Allocator, source: []const u8) Parsed {
    var customs: std.ArrayList(theme.Custom) = .empty;
    var out: Parsed = .{ .source = source };

    if (lua.getField(-1, "themes") == .table) {
        lua.pushNil();
        while (lua.next(-2)) {
            defer lua.pop(1);
            if (lua.typeOf(-2) != .string) continue;
            const name = dupe(lua, a, -2) orelse continue;
            if (lua.typeOf(-1) != .table) {
                std.log.warn("{s}: themes.{s} is not a table; ignored", .{ source, name });
                continue;
            }
            customs.append(a, readTable(lua, a, source, name)) catch continue;
        }
    }
    lua.pop(1);

    switch (lua.getField(-1, "theme")) {
        .string => out.name = dupe(lua, a, -1),
        .table => {
            customs.append(a, readTable(lua, a, source, table_theme_name)) catch {};
            out.name = table_theme_name;
        },
        .nil => {},
        else => std.log.warn("{s}: `theme` is neither a name nor a table; ignored", .{source}),
    }
    lua.pop(1);

    out.customs = customs.toOwnedSlice(a) catch &.{};
    return out;
}

/// One theme table, on top of the stack.
fn readTable(lua: *Lua, a: std.mem.Allocator, source: []const u8, name: []const u8) theme.Custom {
    var c: theme.Custom = .{ .name = name };
    var slots: std.ArrayList(theme.NamedSlot) = .empty;
    var roles: std.ArrayList(theme.NamedRole) = .empty;

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
            c.palette = readPalette(lua, a, source, name);
            continue;
        }
        if (std.mem.eql(u8, key, "slots")) {
            readSlots(lua, a, source, name, &slots);
            continue;
        }
        // `roles` and zoe's old `ui` are the same thing: a table of roles.
        if (std.mem.eql(u8, key, "roles") or std.mem.eql(u8, key, "ui")) {
            readRoles(lua, a, source, name, key, &roles);
            continue;
        }
        if (roleAt(lua, source, name, key)) |nr| roles.append(a, nr) catch {} else |_| {}
    }
    c.slots = slots.toOwnedSlice(a) catch &.{};
    c.roles = roles.toOwnedSlice(a) catch &.{};
    return c;
}

/// A `palette` sub-table (on top of the stack) of `name = "#hex"`.
fn readPalette(lua: *Lua, a: std.mem.Allocator, source: []const u8, theme_name: []const u8) []const theme.NamedColor {
    if (lua.typeOf(-1) != .table) {
        std.log.warn("{s}: theme {s}: `palette` is not a table; ignored", .{ source, theme_name });
        return &.{};
    }
    var out: std.ArrayList(theme.NamedColor) = .empty;
    lua.pushNil();
    while (lua.next(-2)) {
        defer lua.pop(1);
        if (lua.typeOf(-2) != .string) continue;
        const key = lua.toString(-2) catch continue;
        if (!theme.Palette.has(key)) {
            std.log.warn("{s}: theme {s}: palette.{s} is not a palette colour; ignored", .{ source, theme_name, key });
            continue;
        }
        const color = hexAt(lua, source, theme_name, key) orelse continue;
        out.append(a, .{ .name = a.dupe(u8, key) catch continue, .color = color }) catch continue;
    }
    return out.toOwnedSlice(a) catch &.{};
}

/// A `slots` sub-table (on top of the stack) of `slot_name = "#hex"`.
fn readSlots(
    lua: *Lua,
    a: std.mem.Allocator,
    source: []const u8,
    theme_name: []const u8,
    out: *std.ArrayList(theme.NamedSlot),
) void {
    if (lua.typeOf(-1) != .table) {
        std.log.warn("{s}: theme {s}: `slots` is not a table; ignored", .{ source, theme_name });
        return;
    }
    lua.pushNil();
    while (lua.next(-2)) {
        defer lua.pop(1);
        if (lua.typeOf(-2) != .string) continue;
        const key = lua.toString(-2) catch continue;
        const s = theme.slotByName(key) orelse {
            std.log.warn("{s}: theme {s}: slots.{s} is not a slot name (red, dim_red, bright_red, ...); ignored", .{ source, theme_name, key });
            continue;
        };
        const color = hexAt(lua, source, theme_name, key) orelse continue;
        out.append(a, .{ .slot = s, .color = color }) catch continue;
    }
}

/// A `roles` (or `ui`) sub-table, on top of the stack.
fn readRoles(
    lua: *Lua,
    a: std.mem.Allocator,
    source: []const u8,
    theme_name: []const u8,
    what: []const u8,
    out: *std.ArrayList(theme.NamedRole),
) void {
    if (lua.typeOf(-1) != .table) {
        std.log.warn("{s}: theme {s}: `{s}` is not a table; ignored", .{ source, theme_name, what });
        return;
    }
    lua.pushNil();
    while (lua.next(-2)) {
        defer lua.pop(1);
        if (lua.typeOf(-2) != .string) continue;
        const key = lua.toString(-2) catch continue;
        if (roleAt(lua, source, theme_name, key)) |nr| out.append(a, nr) catch {} else |_| {}
    }
}

/// The role `key` set to the value on top of the stack. Errors (after
/// logging) for an unknown role or a bad value.
fn roleAt(lua: *Lua, source: []const u8, theme_name: []const u8, key: []const u8) error{Skip}!theme.NamedRole {
    const role = theme.roleByName(key) orelse {
        std.log.warn("{s}: theme {s}: {s} is not a known role; ignored", .{ source, theme_name, key });
        return error.Skip;
    };
    const value: theme.RoleValue = switch (lua.typeOf(-1)) {
        .number => blk: {
            const n = lua.toInteger(-1) catch -1;
            if (n < 0 or n >= theme.slot_count) {
                std.log.warn("{s}: theme {s}: {s} = {d} is not a slot number 0-23; ignored", .{ source, theme_name, key, n });
                return error.Skip;
            }
            break :blk .{ .slot = @intCast(n) };
        },
        .string => blk: {
            const val = lua.toString(-1) catch return error.Skip;
            break :blk theme.parseRoleValue(val) orelse {
                std.log.warn("{s}: theme {s}: {s} = \"{s}\" is not a slot name, a role, or a #rrggbb colour; ignored", .{ source, theme_name, key, val });
                return error.Skip;
            };
        },
        else => {
            std.log.warn("{s}: theme {s}: {s} is not a string or a slot number; ignored", .{ source, theme_name, key });
            return error.Skip;
        },
    };
    return .{ .role = role, .value = value };
}

/// The `#rrggbb` value on top of the stack, or null (logged).
fn hexAt(lua: *Lua, source: []const u8, theme_name: []const u8, key: []const u8) ?glyphwire.Color {
    if (lua.typeOf(-1) != .string) {
        std.log.warn("{s}: theme {s}: {s} is not a \"#rrggbb\" string; ignored", .{ source, theme_name, key });
        return null;
    }
    const val = lua.toString(-1) catch return null;
    return theme.parseHex(val) orelse {
        std.log.warn("{s}: theme {s}: {s} = \"{s}\" is not a #rrggbb colour; ignored", .{ source, theme_name, key, val });
        return null;
    };
}

fn dupe(lua: *Lua, a: std.mem.Allocator, index: i32) ?[]const u8 {
    const s = lua.toString(index) catch return null;
    return a.dupe(u8, s) catch null;
}

/// Runs the Lua config file `conf_name` in glyphwire's config directory
/// and reads its themes. A missing file, or any error, is an empty
/// `Parsed` (follow the window). Everything it borrows is in `arena`.
pub fn loadFile(
    arena: std.mem.Allocator,
    gpa: std.mem.Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
    conf_name: []const u8,
) Parsed {
    const empty: Parsed = .{ .source = conf_name };
    const dir = glyphwire.configDirPath(arena, environ) catch return empty;
    const path = std.fs.path.join(arena, &.{ dir, conf_name }) catch return empty;
    const src = std.Io.Dir.cwd().readFileAllocOptions(io, path, arena, .limited(256 * 1024), .of(u8), 0) catch
        return empty;
    return fromSource(arena, gpa, src, conf_name);
}

/// The shared `theme.lua`: the window's theme (glyphwire-host), and the
/// `themes` every program's own config can name.
pub fn loadShared(
    arena: std.mem.Allocator,
    gpa: std.mem.Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
) Parsed {
    return loadFile(arena, gpa, io, environ, shared_conf_name);
}

/// The theme a program's own config (`conf_name`, e.g.
/// `salacommander.conf.lua`) names, resolved against its `themes` and
/// `theme.lua`'s; null when it names none, and the program should follow
/// the window's. Runs the file for its theme keys alone, so a program
/// whose config parser has no arena to keep theme strings in needn't
/// change it. Strings borrow from `arena`.
pub fn programTheme(
    arena: std.mem.Allocator,
    gpa: std.mem.Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
    conf_name: []const u8,
) ?theme.Theme {
    const own = loadFile(arena, gpa, io, environ, conf_name);
    if (own.name == null) return null;
    return own.resolve(arena, loadShared(arena, gpa, io, environ));
}

/// `loadFile`'s parse, over config text already in hand.
pub fn fromSource(arena: std.mem.Allocator, gpa: std.mem.Allocator, src: [:0]const u8, source: []const u8) Parsed {
    const empty: Parsed = .{ .source = source };
    const lua = Lua.init(gpa) catch return empty;
    defer lua.deinit();
    lua.openLibs();
    lua.doString(src) catch |err| {
        std.log.warn("{s}: {t}; theme settings ignored", .{ source, err });
        return empty;
    };
    _ = lua.getGlobal("config") catch return empty;
    defer lua.pop(1);
    if (lua.typeOf(-1) != .table) return empty;
    return read(lua, arena, source);
}
