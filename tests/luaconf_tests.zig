// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: GPL-3.0-or-later

const std = @import("std");
const testz = @import("testz");
const luaconf = @import("luaconf");

const Lua = luaconf.Lua;

const conf: luaconf.Conf = .{ .prog = "test", .name = "test.conf.lua" };

const Mode = enum { small, large };

/// Everything the readers can return, null meaning "kept the default".
const Out = struct {
    alloc: std.mem.Allocator,
    count: ?u32 = null,
    ratio: ?f32 = null,
    flag: ?bool = null,
    name: ?[]const u8 = null,
    mode: ?Mode = null,
    list: ?[]const []const u8 = null,
    applied: bool = false,

    fn deinit(self: *Out) void {
        if (self.name) |n| self.alloc.free(n);
        if (self.list) |l| {
            for (l) |s| self.alloc.free(s);
            self.alloc.free(l);
        }
    }

    fn apply(self: *Out, lua: *Lua) void {
        self.applied = true;
        self.count = conf.uint(lua, u32, "count", .{ .min = 2, .max = 10 });
        self.ratio = conf.number(lua, f32, "ratio", .{ .min = 0, .max = 1 });
        self.flag = conf.boolean(lua, "flag");
        if (conf.string(lua, "name")) |s| self.name = self.alloc.dupe(u8, s) catch null;
        self.mode = conf.enumValue(lua, Mode, "mode");
        self.list = conf.stringList(lua, self.alloc, "list");
    }
};

fn parse(alloc: std.mem.Allocator, src: [:0]const u8) Out {
    var out: Out = .{ .alloc = alloc };
    const err = conf.run(alloc, src, &out, Out.apply);
    if (err) |e| alloc.free(e);
    return out;
}

pub fn readsEveryFieldTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var out = parse(alloc,
        \\config = { count = 4, ratio = 0.5, flag = true, name = "x",
        \\           mode = "large", list = { "a", "b" } }
    );
    defer out.deinit();
    try testz.expectEqual(out.count.?, 4);
    try testz.expectEqual(out.ratio.?, 0.5);
    try testz.expectEqual(out.flag.?, true);
    try testz.expectEqualStr(out.name.?, "x");
    try testz.expectEqual(out.mode.?, .large);
    try testz.expectEqual(out.list.?.len, 2);
    try testz.expectEqualStr(out.list.?[1], "b");
}

pub fn absentKeysKeepDefaultsTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var out = parse(alloc, "config = {}");
    defer out.deinit();
    try testz.expectTrue(out.applied);
    try testz.expectTrue(out.count == null);
    try testz.expectTrue(out.ratio == null);
    try testz.expectTrue(out.flag == null);
    try testz.expectTrue(out.name == null);
    try testz.expectTrue(out.mode == null);
    try testz.expectTrue(out.list == null);
}

/// Out of range clamps, the one policy every config shares.
pub fn outOfRangeClampsTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var hi = parse(alloc, "config = { count = 9000, ratio = 3 }");
    defer hi.deinit();
    try testz.expectEqual(hi.count.?, 10);
    try testz.expectEqual(hi.ratio.?, 1);

    var lo = parse(alloc, "config = { count = 0, ratio = -1 }");
    defer lo.deinit();
    try testz.expectEqual(lo.count.?, 2);
    try testz.expectEqual(lo.ratio.?, 0);
}

/// A wrong type, or a count that isn't a whole number >= 0, is ignored.
pub fn badValuesAreIgnoredTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var out = parse(alloc,
        \\config = { count = 1.5, ratio = "half", flag = 1, name = 7,
        \\           mode = "huge", list = "a" }
    );
    defer out.deinit();
    try testz.expectTrue(out.count == null);
    try testz.expectTrue(out.ratio == null);
    try testz.expectTrue(out.flag == null);
    try testz.expectTrue(out.name == null);
    try testz.expectTrue(out.mode == null);
    try testz.expectTrue(out.list == null);

    var neg = parse(alloc, "config = { count = -3 }");
    defer neg.deinit();
    try testz.expectTrue(neg.count == null);
}

pub fn listSkipsNonStringsTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var out = parse(alloc, "config = { list = { \"a\", 2, \"c\" } }");
    defer out.deinit();
    try testz.expectEqual(out.list.?.len, 2);
    try testz.expectEqualStr(out.list.?[0], "a");
    try testz.expectEqualStr(out.list.?[1], "c");
}

/// A script error comes back as an owned message and `apply` never runs.
pub fn scriptErrorIsReturnedTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var out: Out = .{ .alloc = alloc };
    const err = conf.run(alloc, "config = { count = 4 }\nerror('boom')", &out, Out.apply);
    try testz.expectTrue(err != null);
    defer alloc.free(err.?);
    try testz.expectTrue(std.mem.indexOf(u8, err.?, "boom") != null);
    try testz.expectTrue(!out.applied);
}

/// No `config`, or a `config` that isn't a table, never reaches `apply`.
pub fn missingOrNonTableConfigTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var none = parse(alloc, "local x = 1");
    defer none.deinit();
    try testz.expectTrue(!none.applied);

    var wrong = parse(alloc, "config = 5");
    defer wrong.deinit();
    try testz.expectTrue(!wrong.applied);
}

const KeyAction = enum { up, help, quit };

const KeysOut = struct {
    alloc: std.mem.Allocator,
    keys: []@import("applib").keybind.Override(KeyAction) = &.{},

    fn apply(self: *KeysOut, lua: *Lua) void {
        self.keys = conf.keys(lua, self.alloc, KeyAction);
    }
};

/// Parsed and validated as read: a bad chord or an unknown action is
/// dropped, `false` comes back as a null action, and the result is sorted
/// so the same file always applies the same way.
pub fn keysReadsChordsAndActionsTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var out: KeysOut = .{ .alloc = alloc };
    const err = conf.run(alloc,
        \\config = { keys = {
        \\  ["up"] = "up", ["?"] = "help", ["F10"] = false,
        \\  ["hyper+x"] = "quit", ["q"] = "nope", ["w"] = true,
        \\} }
    , &out, KeysOut.apply);
    try testz.expectTrue(err == null);
    defer alloc.free(out.keys);
    try testz.expectEqual(out.keys.len, 3);
    try testz.expectEqualStr(out.keys[0].chord.key(), "?");
    try testz.expectTrue(out.keys[0].chord.text);
    try testz.expectEqualStr(out.keys[1].chord.key(), "f10");
    try testz.expectTrue(out.keys[1].action == null);
    try testz.expectEqual(out.keys[2].action.?, .up);
}

pub fn readInMissingFileIsFileNotFoundTest(io: std.Io, alloc: std.mem.Allocator) !void {
    const missing: luaconf.Conf = .{ .prog = "test", .name = "no-such-file.conf.lua" };
    try testz.expectError(missing.readIn(alloc, io, "/nonexistent-glyphwire-dir"), error.FileNotFound);
}
