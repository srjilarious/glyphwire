const std = @import("std");
const testz = @import("testz");

// The "is it time to write the file yet?" policy shared by the shell's
// lazily-flushed history and `zj` database (see shell/flushgate.zig).
// Pure: the caller passes the clock in.
const FlushGate = @import("shell_support").flushgate.FlushGate;

pub fn cleanGateNeverFlushesTest(_: std.Io, _: std.mem.Allocator) !void {
    var g = FlushGate{};
    try testz.expectFalse(g.shouldFlush(0));
    try testz.expectFalse(g.shouldFlush(999_999_999));
}

pub fn dirtyCountTriggersFlushTest(_: std.Io, _: std.mem.Allocator) !void {
    var g = FlushGate{ .max_dirty = 3, .max_age_ms = 1_000_000 };
    g.note();
    g.note();
    try testz.expectFalse(g.shouldFlush(0)); // 2 < 3, and no time passed
    g.note();
    try testz.expectTrue(g.shouldFlush(0)); // 3 >= 3
}

pub fn ageTriggersFlushWhenDirtyTest(_: std.Io, _: std.mem.Allocator) !void {
    var g = FlushGate{ .max_dirty = 100, .max_age_ms = 500 };
    g.reset(1_000);
    g.note();
    try testz.expectFalse(g.shouldFlush(1_400)); // 400ms < 500ms
    try testz.expectTrue(g.shouldFlush(1_500)); // 500ms elapsed
}

pub fn ageAloneDoesNotFlushWhenCleanTest(_: std.Io, _: std.mem.Allocator) !void {
    var g = FlushGate{ .max_age_ms = 10 };
    g.reset(0);
    // Lots of time passes but nothing changed.
    try testz.expectFalse(g.shouldFlush(1_000_000));
}

pub fn resetClearsDirtyAndRestartsClockTest(_: std.Io, _: std.mem.Allocator) !void {
    var g = FlushGate{ .max_dirty = 2, .max_age_ms = 100 };
    g.note();
    g.note();
    try testz.expectTrue(g.shouldFlush(50));
    g.reset(50);
    try testz.expectFalse(g.shouldFlush(50)); // dirty cleared
    try testz.expectFalse(g.shouldFlush(149)); // clock restarted at 50
    g.note();
    try testz.expectTrue(g.shouldFlush(150)); // now 100ms since reset
}
