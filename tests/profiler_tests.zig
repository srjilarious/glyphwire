const std = @import("std");
const testz = @import("testz");
const glyphwire = @import("glyphwire");

const Span = enum { frame, work };
const Counter = enum { widgets };
const P = glyphwire.Profiler(Span, Counter);

pub fn disabledProfilerSnapshotIsInactiveTest(io: std.Io, _: std.mem.Allocator) !void {
    var p = P.init(io, false, 0, 0);
    // Every recording call is a no-op while disabled.
    p.record(.work, 5_000_000);
    p.add(.widgets, 42);
    _ = p.frameBoundary();

    const snap = p.snapshot();
    try testz.expectFalse(snap.active);
    try testz.expectEqual(snap.fps, 0);
    try testz.expectEqual(snap.phase_count, 0);
    try testz.expectEqual(snap.counter_count, 0);
}

pub fn spanWindowStatsAreMillisecondsTest(io: std.Io, _: std.mem.Allocator) !void {
    // window_ms = 0 publishes on every frameBoundary.
    var p = P.init(io, true, 0, 0);
    // 1ms, 3ms, 2ms -> avg 2ms, max 3ms, p95 (index 2 of 3) 3ms.
    p.record(.work, 1_000_000);
    p.record(.work, 3_000_000);
    p.record(.work, 2_000_000);
    _ = p.frameBoundary();

    const snap = p.snapshot();
    try testz.expectTrue(snap.active);
    try testz.expectEqual(snap.phase_count, 2);

    // Phases are indexed by enum order: frame = 0, work = 1.
    const work = snap.phases[1];
    try testz.expectEqualStr(work.name, "work");
    try testz.expectTrue(work.avg_ms > 1.99 and work.avg_ms < 2.01);
    try testz.expectTrue(work.max_ms > 2.99 and work.max_ms < 3.01);
    try testz.expectTrue(work.p95_ms > 2.99 and work.p95_ms < 3.01);

    // The untouched `frame` span reads as all-zero.
    try testz.expectEqual(snap.phases[0].avg_ms, 0);
}

pub fn windowResetsSoStaleSamplesDoNotDragTheAverageTest(io: std.Io, _: std.mem.Allocator) !void {
    var p = P.init(io, true, 0, 0);
    // A slow first frame...
    p.record(.work, 20_000_000);
    _ = p.frameBoundary();
    try testz.expectTrue(p.snapshot().phases[1].avg_ms > 19.0);

    // ...must not weigh on a later fast window.
    p.record(.work, 1_000_000);
    _ = p.frameBoundary();
    const avg = p.snapshot().phases[1].avg_ms;
    try testz.expectTrue(avg > 0.99 and avg < 1.01);
}

pub fn counterReportsWindowedPerFrameMeanTest(io: std.Io, _: std.mem.Allocator) !void {
    // A long window so it only closes when we ask.
    var p = P.init(io, true, 60_000, 0);
    p.add(.widgets, 2);
    _ = p.frameBoundary();
    p.add(.widgets, 4);
    _ = p.frameBoundary();
    p.add(.widgets, 6);
    _ = p.frameBoundary();
    p.publishNow();

    const snap = p.snapshot();
    try testz.expectEqual(snap.counter_count, 1);
    const w = snap.counters[0];
    try testz.expectEqualStr(w.name, "widgets");
    // Mean of {2, 4, 6} over the three frames in the window.
    try testz.expectTrue(w.per_frame > 3.99 and w.per_frame < 4.01);
}

pub fn writeSummaryRendersPhasesAndCountersTest(io: std.Io, _: std.mem.Allocator) !void {
    var p = P.init(io, true, 0, 0);
    p.record(.work, 2_000_000);
    p.add(.widgets, 7);
    _ = p.frameBoundary();

    var buf: [1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    const snap = p.snapshot();
    try glyphwire.profiler.writeSummary(&snap, &w);
    const out = w.buffered();

    try testz.expectTrue(std.mem.indexOf(u8, out, "profiler ") != null);
    try testz.expectTrue(std.mem.indexOf(u8, out, "work") != null);
    try testz.expectTrue(std.mem.indexOf(u8, out, "widgets") != null);
    // The lifetime "total" column is gone.
    try testz.expectTrue(std.mem.indexOf(u8, out, "total") == null);
}

pub fn writeSummaryOnInactiveSnapshotSaysInactiveTest(io: std.Io, _: std.mem.Allocator) !void {
    _ = io;
    var buf: [128]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    const snap: glyphwire.ProfileSnapshot = .{};
    try glyphwire.profiler.writeSummary(&snap, &w);
    try testz.expectEqualStr(std.mem.trim(u8, w.buffered(), " \n"), "profiler inactive");
}
