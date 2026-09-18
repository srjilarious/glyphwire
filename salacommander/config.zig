// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: GPL-3.0-or-later

//! Loads salacommander's startup config,
//! `~/.config/glyphwire/salacommander.conf.lua`: a Lua script that assigns
//! a global `config` table, the same shape as every other glyphwire tool's
//! config. See `salacommander.conf.template.lua` for every key.
//!
//! `keys` rebinds actions by name (see `actions.zig`): each entry maps a
//! chord to an action name, or to `false` to unbind that chord. Entries
//! are applied over the built-in defaults, so a config only lists what it
//! changes.

const std = @import("std");
const ziglua = @import("ziglua");
const Lua = ziglua.Lua;
const pane_mod = @import("pane.zig");
const actions = @import("actions.zig");

const conf_name = "salacommander.conf.lua";

pub const KeyOverride = struct {
    /// Owned.
    chord: []u8,
    /// An action name (owned), or null to unbind the chord.
    action: ?[]u8,
};

pub const Config = struct {
    view: pane_mod.ViewMode = .small,
    show_hidden: bool = false,
    /// Icon height caps in pixels, as `gw-ls` has them.
    large_icon_px: u32 = 32,
    small_icon_px: u32 = 16,
    keys: []KeyOverride = &.{},

    pub fn deinit(self: *Config, alloc: std.mem.Allocator) void {
        for (self.keys) |k| {
            alloc.free(k.chord);
            if (k.action) |a| alloc.free(a);
        }
        alloc.free(self.keys);
        self.keys = &.{};
    }
};

pub const icon_px_min: u32 = 8;
pub const icon_px_max: u32 = 128;

pub const LoadResult = struct {
    config: Config = .{},
    /// A Lua load/run failure, owned. `config` still holds whatever was
    /// read before it.
    err: ?[]const u8 = null,

    pub fn deinit(self: *LoadResult, alloc: std.mem.Allocator) void {
        self.config.deinit(alloc);
        if (self.err) |e| alloc.free(e);
    }
};

/// Parses `source` (the file's contents). Unknown keys are ignored; a
/// value of the wrong type keeps the default and is logged.
pub fn load(alloc: std.mem.Allocator, source: [:0]const u8) LoadResult {
    var result: LoadResult = .{};

    const lua = Lua.init(alloc) catch {
        result.err = alloc.dupe(u8, conf_name ++ ": could not create Lua interpreter") catch null;
        return result;
    };
    defer lua.deinit();
    lua.openLibs();

    lua.doString(source) catch {
        const msg = lua.toString(-1) catch conf_name ++ ": unknown Lua error";
        result.err = alloc.dupe(u8, msg) catch null;
        return result;
    };

    _ = lua.getGlobal("config") catch return result;
    defer lua.pop(1);
    if (!lua.isTable(-1)) {
        if (!lua.isNil(-1)) std.log.warn("salacommander: {s} `config` is not a table; using defaults", .{conf_name});
        return result;
    }

    if (stringField(lua, "view")) |v| {
        if (std.meta.stringToEnum(pane_mod.ViewMode, v)) |mode| {
            result.config.view = mode;
        } else {
            std.log.warn("salacommander: {s} `view` must be \"small\" or \"large\"; ignored", .{conf_name});
        }
    }
    if (boolField(lua, "show_hidden")) |v| result.config.show_hidden = v;
    if (uintField(lua, "large_icon_px")) |v| result.config.large_icon_px = std.math.clamp(v, icon_px_min, icon_px_max);
    if (uintField(lua, "small_icon_px")) |v| result.config.small_icon_px = std.math.clamp(v, icon_px_min, icon_px_max);
    result.config.keys = readKeys(alloc, lua) catch &.{};

    return result;
}

/// `load`, reading the file from glyphwire's config directory. A missing
/// file is the normal case: defaults, nothing logged.
pub fn loadFromDir(alloc: std.mem.Allocator, io: std.Io, config_dir: []const u8) Config {
    const path = std.fs.path.join(alloc, &.{ config_dir, conf_name }) catch return .{};
    defer alloc.free(path);

    const src = std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(64 * 1024)) catch |err| {
        if (err != error.FileNotFound) std.log.warn("salacommander: couldn't read {s} ({t}); using defaults", .{ path, err });
        return .{};
    };
    defer alloc.free(src);
    const src_z = std.mem.concatWithSentinel(alloc, u8, &.{src}, 0) catch return .{};
    defer alloc.free(src_z);

    var result = load(alloc, src_z);
    if (result.err) |e| {
        std.log.warn("salacommander: {s}: {s}; using what parsed", .{ conf_name, e });
        alloc.free(e);
        result.err = null;
    }
    return result.config;
}

/// Applies `overrides` to `keymap` in order. A chord that doesn't parse or
/// an action name that doesn't exist is logged and skipped; the rest still
/// apply. Returns how many were skipped.
pub fn applyKeys(alloc: std.mem.Allocator, keymap: *actions.Keymap, overrides: []const KeyOverride) usize {
    var skipped: usize = 0;
    for (overrides) |o| {
        if (o.action) |name| {
            keymap.bindNamed(alloc, o.chord, name) catch |err| {
                std.log.warn("salacommander: {s} keys[\"{s}\"] = \"{s}\": {t}; ignored", .{ conf_name, o.chord, name, err });
                skipped += 1;
            };
        } else {
            keymap.unbindText(o.chord) catch |err| {
                std.log.warn("salacommander: {s} keys[\"{s}\"] = false: {t}; ignored", .{ conf_name, o.chord, err });
                skipped += 1;
            };
        }
    }
    return skipped;
}

/// Reads `config.keys`, a table of chord -> action name / false. Assumes
/// the `config` table is on top of the stack.
fn readKeys(alloc: std.mem.Allocator, lua: *Lua) ![]KeyOverride {
    _ = lua.getField(-1, "keys");
    defer lua.pop(1);
    if (!lua.isTable(-1)) {
        if (!lua.isNil(-1)) std.log.warn("salacommander: {s} `keys` is not a table; ignored", .{conf_name});
        return &.{};
    }

    var out: std.ArrayList(KeyOverride) = .empty;
    errdefer {
        for (out.items) |k| {
            alloc.free(k.chord);
            if (k.action) |a| alloc.free(a);
        }
        out.deinit(alloc);
    }

    lua.pushNil();
    while (lua.next(-2)) {
        // Key at -2, value at -1. Only read with `toString` on an actual
        // string key: it would convert a number key in place and break
        // `next`.
        defer lua.pop(1);
        if (lua.typeOf(-2) != .string) {
            std.log.warn("salacommander: {s} `keys` entry with a non-string key; ignored", .{conf_name});
            continue;
        }
        const chord = lua.toString(-2) catch continue;
        const action: ?[]const u8 = switch (lua.typeOf(-1)) {
            .string => lua.toString(-1) catch continue,
            .boolean => if (lua.toBoolean(-1)) {
                std.log.warn("salacommander: {s} keys[\"{s}\"] = true means nothing; use an action name or false", .{ conf_name, chord });
                continue;
            } else null,
            else => {
                std.log.warn("salacommander: {s} keys[\"{s}\"] must be an action name or false; ignored", .{ conf_name, chord });
                continue;
            },
        };
        const chord_copy = try alloc.dupe(u8, chord);
        errdefer alloc.free(chord_copy);
        const action_copy: ?[]u8 = if (action) |a| try alloc.dupe(u8, a) else null;
        try out.append(alloc, .{ .chord = chord_copy, .action = action_copy });
    }
    // Lua's table order is unspecified; sort so the same config always
    // applies the same way (it only matters if two entries share a chord
    // under different spellings).
    std.mem.sort(KeyOverride, out.items, {}, struct {
        fn lessThan(_: void, a: KeyOverride, b: KeyOverride) bool {
            return std.mem.lessThan(u8, a.chord, b.chord);
        }
    }.lessThan);
    return out.toOwnedSlice(alloc);
}

fn stringField(lua: *Lua, key: [:0]const u8) ?[]const u8 {
    _ = lua.getField(-1, key);
    defer lua.pop(1);
    if (lua.typeOf(-1) != .string) {
        if (!lua.isNil(-1)) std.log.warn("salacommander: {s} `{s}` is not a string; ignored", .{ conf_name, key });
        return null;
    }
    // The string stays alive while `config` does, which outlives the
    // caller's use of it (the whole `load`).
    return lua.toString(-1) catch null;
}

fn boolField(lua: *Lua, key: [:0]const u8) ?bool {
    _ = lua.getField(-1, key);
    defer lua.pop(1);
    if (!lua.isBoolean(-1)) {
        if (!lua.isNil(-1)) std.log.warn("salacommander: {s} `{s}` is not true/false; ignored", .{ conf_name, key });
        return null;
    }
    return lua.toBoolean(-1);
}

fn uintField(lua: *Lua, key: [:0]const u8) ?u32 {
    _ = lua.getField(-1, key);
    defer lua.pop(1);
    if (!lua.isNumber(-1)) {
        if (!lua.isNil(-1)) std.log.warn("salacommander: {s} `{s}` is not a number; ignored", .{ conf_name, key });
        return null;
    }
    const n = lua.toNumber(-1) catch return null;
    if (n < 0 or n != @floor(n) or n > @as(f64, std.math.maxInt(u32))) return null;
    return @intFromFloat(n);
}
