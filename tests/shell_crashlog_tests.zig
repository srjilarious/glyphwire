// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: GPL-3.0-or-later

const std = @import("std");
const testz = @import("testz");

// What gw-shell keeps of a glyphwire-aware child's output and when it
// reports it as a crash (see shell/crashlog.zig).
const crashlog = @import("shell_support").crashlog;

pub fn tailKeepsEverythingUnderCapacityTest(_: std.Io, _: std.mem.Allocator) !void {
    var t = crashlog.Tail{};
    t.append("hello ");
    t.append("world");
    var out: [crashlog.Tail.capacity]u8 = undefined;
    try testz.expectEqualStr(t.contents(&out), "hello world");
}

pub fn tailDropsOldestBytesOnceFullTest(_: std.Io, alloc: std.mem.Allocator) !void {
    const t = try alloc.create(crashlog.Tail);
    defer alloc.destroy(t);
    t.* = .{};
    const cap = crashlog.Tail.capacity;

    const filler = try alloc.alloc(u8, cap);
    defer alloc.free(filler);
    @memset(filler, 'a');
    t.append(filler);
    t.append("XYZ");

    const out = try alloc.alloc(u8, cap);
    defer alloc.free(out);
    const got = t.contents(out);
    try testz.expectEqual(got.len, cap);
    try testz.expectEqualStr(got[cap - 3 ..], "XYZ");
    try testz.expectEqual(got[0], @as(u8, 'a'));
}

pub fn tailKeepsEndOfOversizedWriteTest(_: std.Io, alloc: std.mem.Allocator) !void {
    const t = try alloc.create(crashlog.Tail);
    defer alloc.destroy(t);
    t.* = .{};
    const cap = crashlog.Tail.capacity;

    const big = try alloc.alloc(u8, cap + 10);
    defer alloc.free(big);
    @memset(big, 'b');
    @memcpy(big[big.len - 4 ..], "tail");
    t.append(big);

    const out = try alloc.alloc(u8, cap);
    defer alloc.free(out);
    const got = t.contents(out);
    try testz.expectEqual(got.len, cap);
    try testz.expectEqualStr(got[cap - 4 ..], "tail");
}

pub fn crashSignalsAlwaysReportTest(_: std.Io, _: std.mem.Allocator) !void {
    // SIGILL (a ReleaseSafe UBSan trap), SIGABRT (a Zig panic), SIGSEGV.
    try testz.expectTrue(crashlog.shouldReport(.{ .signal = 4 }, 0));
    try testz.expectTrue(crashlog.shouldReport(.{ .signal = 6 }, 100));
    try testz.expectTrue(crashlog.shouldReport(.{ .signal = 11 }, 0));
}

pub fn stopSignalsNeverReportTest(_: std.Io, _: std.mem.Allocator) !void {
    // SIGHUP, SIGINT, SIGKILL, SIGTERM: someone stopping it on purpose.
    try testz.expectFalse(crashlog.shouldReport(.{ .signal = 1 }, 100));
    try testz.expectFalse(crashlog.shouldReport(.{ .signal = 2 }, 100));
    try testz.expectFalse(crashlog.shouldReport(.{ .signal = 9 }, 100));
    try testz.expectFalse(crashlog.shouldReport(.{ .signal = 15 }, 100));
}

pub fn nonzeroExitReportsOnlyWithOutputTest(_: std.Io, _: std.mem.Allocator) !void {
    try testz.expectTrue(crashlog.shouldReport(.{ .code = 1 }, 12));
    try testz.expectFalse(crashlog.shouldReport(.{ .code = 1 }, 0));
    try testz.expectFalse(crashlog.shouldReport(.{ .code = 0 }, 500));
}

pub fn describeNamesTheSignalTest(_: std.Io, _: std.mem.Allocator) !void {
    var buf: [64]u8 = undefined;
    try testz.expectEqualStr(crashlog.describe(&buf, "zoe", .{ .signal = 4 }), "zoe crashed (SIGILL)");
    try testz.expectEqualStr(crashlog.describe(&buf, "zoe", .{ .signal = 9 }), "zoe was killed by signal 9");
    try testz.expectEqualStr(crashlog.describe(&buf, "gw-read", .{ .code = 1 }), "gw-read exited with status 1");
}

pub fn lastLinesTakesTheEndTest(_: std.Io, _: std.mem.Allocator) !void {
    try testz.expectEqualStr(crashlog.lastLines("a\nb\nc\nd\n", 2), "c\nd\n");
    try testz.expectEqualStr(crashlog.lastLines("a\nb\nc\nd", 2), "c\nd");
    try testz.expectEqualStr(crashlog.lastLines("a\nb\n", 5), "a\nb\n");
    try testz.expectEqualStr(crashlog.lastLines("a\nb\n", 0), "");
}

pub fn stripAnsiRemovesEscapesTest(_: std.Io, _: std.mem.Allocator) !void {
    var out: [128]u8 = undefined;
    const text = "\x1b[1;31merror\x1b[0m: boom\r\n\x1b]0;title\x07at \x1b(Bfoo.zig";
    try testz.expectEqualStr(crashlog.stripAnsi(text, &out), "error: boom\nat foo.zig");
}

pub fn logNameUsesProgramBasenameTest(_: std.Io, _: std.mem.Allocator) !void {
    var buf: [128]u8 = undefined;
    try testz.expectEqualStr(
        crashlog.logName(&buf, "/usr/local/bin/zoe", "20260927-221530", 4242),
        "zoe-20260927-221530-4242.log",
    );
}

pub fn logDirPrefersXdgStateHomeTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var env = std.process.Environ.Map.init(alloc);
    defer env.deinit();
    try env.put("HOME", "/home/u");

    const from_home = (try crashlog.logDir(alloc, &env)).?;
    defer alloc.free(from_home);
    try testz.expectEqualStr(from_home, "/home/u/.local/state/glyphwire/crashes");

    try env.put("XDG_STATE_HOME", "/state");
    const from_xdg = (try crashlog.logDir(alloc, &env)).?;
    defer alloc.free(from_xdg);
    try testz.expectEqualStr(from_xdg, "/state/glyphwire/crashes");
}
