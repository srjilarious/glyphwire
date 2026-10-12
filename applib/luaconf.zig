// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: MPL-2.0

//! The skeleton every glyphwire program's Lua config shares: read
//! `<config dir>/<name>.conf.lua`, run it, find the global `config`
//! table, and read typed fields out of it with one set of warnings.
//!
//! A program declares its file once,
//!
//!   const conf: luaconf.Conf = .{ .prog = "gw-read", .name = "read.conf.lua" };
//!
//! then `conf.read` fetches the source, `conf.run` executes it and hands
//! the `config` table to the program's own `apply`, and the field readers
//! (`conf.uint`, `conf.string`, ...) pull values off it.
//!
//! One policy for bad values, everywhere: a value of the wrong type is
//! ignored (the default stands) with a warning; a number outside its
//! range is clamped into it, also with a warning. An absent key is
//! silent. Config files are capped at `max_source_bytes`.
//!
//! Its own build module, like `themeconf`, because it needs `ziglua`,
//! which `applib` keeps out of the programs that don't embed Lua.

const std = @import("std");
const ziglua = @import("ziglua");
const glyphwire = @import("glyphwire");
const keybind = @import("keybind");

pub const Lua = ziglua.Lua;

/// The most of a config file any program reads.
pub const max_source_bytes: usize = 256 * 1024;

/// Bounds for a numeric field. A value outside them is clamped and
/// warned about.
pub fn Range(comptime T: type) type {
    return struct {
        min: T = if (@typeInfo(T) == .float) -std.math.inf(T) else std.math.minInt(T),
        max: T = if (@typeInfo(T) == .float) std.math.inf(T) else std.math.maxInt(T),
    };
}

pub const ReadError = error{ FileNotFound, ReadFailed, OutOfMemory };

/// One program's config file: who is reading it (`prog`, the prefix on
/// every log line) and its file name in the config directory.
pub const Conf = struct {
    prog: []const u8,
    name: []const u8,

    /// Logs `<prog>: <name> <message>`.
    pub fn warn(self: Conf, comptime fmt: []const u8, args: anytype) void {
        std.log.warn("{s}: {s} " ++ fmt, .{ self.prog, self.name } ++ args);
    }

    /// Reads `<dir>/<name>`, null-terminated (what Lua takes), owned by
    /// `alloc`. A missing file is `error.FileNotFound` and logs nothing;
    /// any other IO failure is logged here and is `error.ReadFailed`.
    pub fn readIn(self: Conf, alloc: std.mem.Allocator, io: std.Io, dir: []const u8) ReadError![:0]u8 {
        const path = try std.fs.path.join(alloc, &.{ dir, self.name });
        defer alloc.free(path);
        return std.Io.Dir.cwd().readFileAllocOptions(io, path, alloc, .limited(max_source_bytes), .of(u8), 0) catch |err| switch (err) {
            error.FileNotFound => error.FileNotFound,
            error.OutOfMemory => error.OutOfMemory,
            else => {
                std.log.warn("{s}: couldn't read {s} ({t}); using defaults", .{ self.prog, path, err });
                return error.ReadFailed;
            },
        };
    }

    /// `readIn` over glyphwire's config directory
    /// (`glyphwire.configDirPath`). Null when there is no config home, no
    /// file, or the read failed; only the last is logged. A missing file
    /// is the normal case.
    pub fn read(self: Conf, alloc: std.mem.Allocator, io: std.Io, environ: *const std.process.Environ.Map) ?[:0]u8 {
        const dir = glyphwire.configDirPath(alloc, environ) catch return null;
        defer alloc.free(dir);
        return self.readIn(alloc, io, dir) catch null;
    }

    /// Runs `source` and, when it assigned a `config` table, calls
    /// `apply(ctx, lua)` with that table on top of the stack (pop
    /// whatever you push). A `config` that is anything but a table or nil
    /// is warned about and skipped.
    ///
    /// Returns a Lua init failure or the script's error message, owned by
    /// `alloc`, or null when it ran. On an error `apply` is not called and
    /// the caller's defaults stand.
    pub fn run(
        self: Conf,
        alloc: std.mem.Allocator,
        source: [:0]const u8,
        ctx: anytype,
        comptime apply: fn (@TypeOf(ctx), *Lua) void,
    ) ?[]u8 {
        const lua = Lua.init(alloc) catch
            return std.fmt.allocPrint(alloc, "{s}: could not create Lua interpreter", .{self.name}) catch null;
        defer lua.deinit();
        lua.openLibs();

        lua.doString(source) catch {
            const msg = lua.toString(-1) catch "unknown Lua error";
            return alloc.dupe(u8, msg) catch null;
        };

        _ = lua.getGlobal("config") catch return null;
        defer lua.pop(1);
        switch (lua.typeOf(-1)) {
            .table => apply(ctx, lua),
            .nil => {},
            else => self.warn("`config` is not a table; using defaults", .{}),
        }
        return null;
    }

    /// `run`, logging its error -- for a loader with nowhere to hand it.
    pub fn runLogged(
        self: Conf,
        alloc: std.mem.Allocator,
        source: [:0]const u8,
        ctx: anytype,
        comptime apply: fn (@TypeOf(ctx), *Lua) void,
    ) void {
        const err = self.run(alloc, source, ctx, apply) orelse return;
        defer alloc.free(err);
        self.logRunError(err);
    }

    /// How every loader reports a `run` error.
    pub fn logRunError(self: Conf, msg: []const u8) void {
        std.log.warn("{s}: {s}: {s}; using defaults", .{ self.prog, self.name, msg });
    }

    // ── field readers ────────────────────────────────────────────────
    //
    // Each reads `config.<key>` from the table on top of the stack and
    // leaves the stack as it found it. Null means "keep the default":
    // absent (silent) or unusable (warned).

    /// A string. Borrowed from Lua: it lives as long as the `config`
    /// table does, so copy it before `run` returns.
    pub fn string(self: Conf, lua: *Lua, key: [:0]const u8) ?[]const u8 {
        const t = lua.getField(-1, key);
        defer lua.pop(1);
        if (t != .string) {
            if (t != .nil) self.warn("`{s}` is not a string; ignored", .{key});
            return null;
        }
        return lua.toString(-1) catch null;
    }

    pub fn boolean(self: Conf, lua: *Lua, key: [:0]const u8) ?bool {
        const t = lua.getField(-1, key);
        defer lua.pop(1);
        if (t != .boolean) {
            if (t != .nil) self.warn("`{s}` is not true/false; ignored", .{key});
            return null;
        }
        return lua.toBoolean(-1);
    }

    /// A number, clamped into `range`.
    pub fn number(self: Conf, lua: *Lua, comptime T: type, key: [:0]const u8, range: Range(T)) ?T {
        const n = self.rawNumber(lua, key) orelse return null;
        if (std.math.isNan(n)) {
            self.warn("`{s}` is not a number; ignored", .{key});
            return null;
        }
        const lo: f64 = @floatCast(range.min);
        const hi: f64 = @floatCast(range.max);
        const c = std.math.clamp(n, lo, hi);
        if (c != n) self.warn("`{s}` {d} out of range {d}..{d}; clamped to {d}", .{ key, n, lo, hi, c });
        return @floatCast(c);
    }

    /// A whole number >= 0, clamped into `range`. A negative or
    /// fractional value isn't a count at all, so it is ignored rather
    /// than clamped.
    pub fn uint(self: Conf, lua: *Lua, comptime T: type, key: [:0]const u8, range: Range(T)) ?T {
        const n = self.rawNumber(lua, key) orelse return null;
        if (!(n >= 0) or n != @floor(n)) {
            self.warn("`{s}` = {d} is not a whole number; ignored", .{ key, n });
            return null;
        }
        const lo: f64 = @floatFromInt(range.min);
        const hi: f64 = @floatFromInt(range.max);
        const c = std.math.clamp(n, lo, hi);
        if (c != n) self.warn("`{s}` {d} out of range {d}..{d}; clamped to {d}", .{ key, n, range.min, range.max, c });
        return @intFromFloat(c);
    }

    /// A string naming one of `E`'s tags.
    pub fn enumValue(self: Conf, lua: *Lua, comptime E: type, key: [:0]const u8) ?E {
        const s = self.string(lua, key) orelse return null;
        if (std.meta.stringToEnum(E, s)) |v| return v;
        self.warn("`{s}` = '{s}' is not one of {s}; ignored", .{ key, s, comptime tagList(E) });
        return null;
    }

    /// An array of strings, duped into `alloc`. Null when absent or not a
    /// table, so a caller can tell "not mentioned" from "mentioned as
    /// empty". A non-string element is warned about and skipped.
    pub fn stringList(self: Conf, lua: *Lua, alloc: std.mem.Allocator, key: [:0]const u8) ?[]const []const u8 {
        const t = lua.getField(-1, key);
        defer lua.pop(1);
        if (t != .table) {
            if (t != .nil) self.warn("`{s}` is not a list; ignored", .{key});
            return null;
        }
        var out: std.ArrayList([]const u8) = .empty;
        const n = lua.rawLen(-1);
        var i: usize = 1;
        while (i <= n) : (i += 1) {
            defer lua.pop(1);
            if (lua.rawGetIndex(-1, @intCast(i)) != .string) {
                self.warn("`{s}`[{d}] is not a string; ignored", .{ key, i });
                continue;
            }
            const s = lua.toString(-1) catch continue;
            const copy = alloc.dupe(u8, s) catch continue;
            out.append(alloc, copy) catch alloc.free(copy);
        }
        return out.toOwnedSlice(alloc) catch null;
    }

    /// `config.keys` as one flat table of chord -> action name, or `false`
    /// to unbind the chord:
    ///
    ///   keys = { ["alt+up"] = "upToParentDir", ["F10"] = false, ["?"] = "help" }
    ///
    /// Chords are `keybind.Chord.parse` text and names are `Action`'s tag
    /// names. One that doesn't parse or names no action is warned about
    /// and skipped. Owned by `alloc`; empty when the key is absent.
    pub fn keys(self: Conf, lua: *Lua, alloc: std.mem.Allocator, comptime Action: type) []keybind.Override(Action) {
        return self.keysNamed(lua, alloc, "keys", Action);
    }

    /// `keys` for a table under another name, for a program with a
    /// second keymap (salacommander's F1 menu reads `menu_keys`).
    pub fn keysNamed(self: Conf, lua: *Lua, alloc: std.mem.Allocator, comptime field: [:0]const u8, comptime Action: type) []keybind.Override(Action) {
        const t = lua.getField(-1, field);
        defer lua.pop(1);
        if (t != .table) {
            if (t != .nil) self.warn("`" ++ field ++ "` is not a table; ignored", .{});
            return &.{};
        }
        var out: std.ArrayList(keybind.Override(Action)) = .empty;
        self.readKeyTable(lua, alloc, Action, field, &out, {}, {});
        sortOverrides(keybind.Override(Action), out.items);
        return out.toOwnedSlice(alloc) catch &.{};
    }

    /// `config.keys` as one table per mode (`Scope`'s tag names), each
    /// shaped like `keys`'s flat table:
    ///
    ///   keys = { insert = { ["ctrl+d"] = "deleteWordForward" } }
    pub fn scopedKeys(
        self: Conf,
        lua: *Lua,
        alloc: std.mem.Allocator,
        comptime Scope: type,
        comptime Action: type,
    ) []keybind.ScopedOverride(Scope, Action) {
        return self.scopedKeysWith(lua, alloc, Scope, Action, {});
    }

    /// `scopedKeys` for a program whose bindings may also name commands
    /// it only learns of later (zoe's Lua extensions): a name that is no
    /// `Action` goes to `named`, unwarned, for the program to resolve
    /// once it knows them. The names are owned by `alloc`.
    pub fn scopedKeysNamed(
        self: Conf,
        lua: *Lua,
        alloc: std.mem.Allocator,
        comptime Scope: type,
        comptime Action: type,
        named: *std.ArrayList(keybind.ScopedNamed(Scope)),
    ) []keybind.ScopedOverride(Scope, Action) {
        return self.scopedKeysWith(lua, alloc, Scope, Action, named);
    }

    fn scopedKeysWith(
        self: Conf,
        lua: *Lua,
        alloc: std.mem.Allocator,
        comptime Scope: type,
        comptime Action: type,
        named: anytype,
    ) []keybind.ScopedOverride(Scope, Action) {
        const Out = keybind.ScopedOverride(Scope, Action);
        const t = lua.getField(-1, "keys");
        defer lua.pop(1);
        if (t != .table) {
            if (t != .nil) self.warn("`keys` is not a table; ignored", .{});
            return &.{};
        }
        var out: std.ArrayList(Out) = .empty;
        lua.pushNil();
        while (lua.next(-2)) {
            // Key at -2, value at -1. Only read with `toString` on an
            // actual string key: it would convert a number key in place
            // and break `next`.
            defer lua.pop(1);
            if (lua.typeOf(-2) != .string) continue;
            const name = lua.toString(-2) catch continue;
            const scope = std.meta.stringToEnum(Scope, name) orelse {
                self.warn("keys.{s}: not a key table ({s}); ignored", .{ name, comptime tagList(Scope) });
                continue;
            };
            if (lua.typeOf(-1) != .table) {
                self.warn("keys.{s} is not a table; ignored", .{name});
                continue;
            }
            var label_buf: [64]u8 = undefined;
            const label = std.fmt.bufPrint(&label_buf, "keys.{s}", .{name}) catch "keys";
            self.readKeyTable(lua, alloc, Action, label, &out, scope, named);
        }
        sortOverrides(Out, out.items);
        return out.toOwnedSlice(alloc) catch &.{};
    }

    /// One chord -> action table, on top of the stack, appended to `out`
    /// (whose items carry `scope` too when they have the field). A name
    /// that is no `Action` goes to `named` when that is a list rather
    /// than `{}` (`scopedKeysNamed`).
    fn readKeyTable(
        self: Conf,
        lua: *Lua,
        alloc: std.mem.Allocator,
        comptime Action: type,
        label: []const u8,
        out: anytype,
        scope: anytype,
        named: anytype,
    ) void {
        lua.pushNil();
        while (lua.next(-2)) {
            defer lua.pop(1);
            if (lua.typeOf(-2) != .string) {
                self.warn("`{s}` entry with a non-string key; ignored", .{label});
                continue;
            }
            const text = lua.toString(-2) catch continue;
            const chord = keybind.Chord.parse(text) catch |err| {
                self.warn("{s}[\"{s}\"]: {t}; ignored", .{ label, text, err });
                continue;
            };
            const action: ?Action = switch (lua.typeOf(-1)) {
                .string => blk: {
                    const name = lua.toString(-1) catch continue;
                    break :blk std.meta.stringToEnum(Action, name) orelse {
                        if (@TypeOf(named) != void) {
                            const owned = alloc.dupe(u8, name) catch continue;
                            named.append(alloc, .{ .scope = scope, .chord = chord, .name = owned }) catch alloc.free(owned);
                            continue;
                        }
                        self.warn("{s}[\"{s}\"] = \"{s}\": unknown action; ignored", .{ label, text, name });
                        continue;
                    };
                },
                .boolean => if (lua.toBoolean(-1)) {
                    self.warn("{s}[\"{s}\"] = true means nothing; use an action name or false", .{ label, text });
                    continue;
                } else null,
                else => {
                    self.warn("{s}[\"{s}\"] must be an action name or false; ignored", .{ label, text });
                    continue;
                },
            };
            const Item = @typeInfo(@TypeOf(out.items)).pointer.child;
            const item: Item = if (@TypeOf(scope) == void)
                .{ .chord = chord, .action = action }
            else
                .{ .scope = scope, .chord = chord, .action = action };
            out.append(alloc, item) catch return;
        }
    }

    fn rawNumber(self: Conf, lua: *Lua, key: [:0]const u8) ?f64 {
        const t = lua.getField(-1, key);
        defer lua.pop(1);
        if (t != .number) {
            if (t != .nil) self.warn("`{s}` is not a number; ignored", .{key});
            return null;
        }
        return lua.toNumber(-1) catch null;
    }
};

/// Lua's table order is unspecified; sorting makes the same config always
/// apply the same way (it only matters when two entries spell one chord
/// differently, where the later one wins).
fn sortOverrides(comptime T: type, items: []T) void {
    std.mem.sort(T, items, {}, struct {
        fn lessThan(_: void, a: T, b: T) bool {
            if (@hasField(T, "scope") and a.scope != b.scope) return @intFromEnum(a.scope) < @intFromEnum(b.scope);
            const ka = a.chord.key();
            const kb = b.chord.key();
            if (!std.mem.eql(u8, ka, kb)) return std.mem.lessThan(u8, ka, kb);
            const ma: u4 = @bitCast(modBits(a.chord));
            const mb: u4 = @bitCast(modBits(b.chord));
            if (ma != mb) return ma < mb;
            const aa: usize = if (a.action) |x| @intFromEnum(x) + 1 else 0;
            const ab: usize = if (b.action) |x| @intFromEnum(x) + 1 else 0;
            return aa < ab;
        }
    }.lessThan);
}

fn modBits(c: keybind.Chord) packed struct { ctrl: bool, alt: bool, shift: bool, super: bool } {
    return .{ .ctrl = c.mods.ctrl, .alt = c.mods.alt, .shift = c.mods.shift, .super = c.mods.super };
}

/// `"'a'/'b'/'c'"` for an enum's tags, for a warning.
fn tagList(comptime E: type) []const u8 {
    comptime {
        var out: []const u8 = "";
        for (@typeInfo(E).@"enum".field_names, 0..) |name, i| {
            out = out ++ (if (i == 0) "" else "/") ++ "'" ++ name ++ "'";
        }
        return out;
    }
}
