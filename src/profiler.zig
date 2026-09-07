//! A tiny, allocation-free frame-timing profiler shared by glyphwire-host
//! (`host/profiler.zig`) and any other client that wants the same
//! machinery.
//!
//! `Profiler(Span, Counter)` collects, per `Span` enum member, the
//! durations handed to `record`, and per `Counter` enum member the
//! per-frame totals fed through `add`. Both are summarised over a
//! **fixed time window** (`window_ms`, default 1s -- an FPS-counter-style
//! accumulate-then-reset, not a lifetime average): at each window
//! boundary the current window's avg / p95 / max ms per span, mean
//! per-frame value per counter, and drawn / skipped frames-per-second
//! are published, and the accumulators reset. `snapshot` returns the
//! last published window as `core.ProfileSnapshot`; `writeSummary`
//! renders it as a text table.
//!
//! Everything is a cheap early-return when `enabled` is false, so a build
//! that wires the calls in unconditionally pays effectively nothing until
//! `host.conf` / `shell.conf` turns profiling on.
//!
//! It reads the monotonic clock (`std.Io.Clock.awake`, via the `io` it is
//! constructed with) for the window / summary cadence and the `frame`
//! span period. Every other duration is measured by the caller and
//! passed in as nanoseconds. This reduced std has no `std.time.Timer`,
//! hence the explicit `std.Io.Timestamp` arithmetic.

const std = @import("std");
const core = @import("core.zig");

/// Cap on the per-span sample ring kept for the p95 estimate within one
/// window. A window longer than this many frames gets p95 over its most
/// recent `p95_cap` samples.
pub const p95_cap = 512;

fn nsToMs(ns: u64) f32 {
    return @as(f32, @floatFromInt(ns)) / std.time.ns_per_ms;
}

fn durNs(d: std.Io.Duration) u64 {
    return if (d.nanoseconds <= 0) 0 else @intCast(d.nanoseconds);
}

/// Builds a profiler over a caller-supplied set of timed phases (`Span`)
/// and per-frame counters (`Counter`). Both must be plain enums whose
/// members are dense from 0; `Span` may have at most
/// `core.profile_max_phases` members and `Counter` at most
/// `core.profile_max_counters`. A `Span` member literally named `frame`
/// carries no special meaning here -- `frameBoundary` returns the wall
/// period since its previous call and the caller records it.
pub fn Profiler(comptime Span: type, comptime Counter: type) type {
    const span_fields = @typeInfo(Span).@"enum".fields;
    const counter_fields = @typeInfo(Counter).@"enum".fields;

    if (span_fields.len > core.profile_max_phases)
        @compileError("profiler Span has more members than core.ProfileSnapshot.phases holds");
    if (counter_fields.len > core.profile_max_counters)
        @compileError("profiler Counter has more members than core.ProfileSnapshot.counters holds");
    inline for (span_fields, 0..) |f, i| {
        if (f.value != i) @compileError("profiler Span enum members must be dense from 0");
    }
    inline for (counter_fields, 0..) |f, i| {
        if (f.value != i) @compileError("profiler Counter enum members must be dense from 0");
    }

    return struct {
        const Self = @This();
        pub const span_count = span_fields.len;
        pub const counter_count = counter_fields.len;

        io: std.Io,
        enabled: bool = false,
        /// Length of the summary window in ns. 0 means "publish on every
        /// `frameBoundary`" (raw per-frame stats; used by the tests).
        window_ns: u64 = std.time.ns_per_s,

        // ── Current window: per span ────────────────────────────────────
        w_n: [span_count]u32 = std.mem.zeroes([span_count]u32),
        w_sum: [span_count]u64 = std.mem.zeroes([span_count]u64),
        w_max: [span_count]u64 = std.mem.zeroes([span_count]u64),
        // Ring of recent samples, for the p95 estimate.
        w_ring: [span_count][p95_cap]u64 = std.mem.zeroes([span_count][p95_cap]u64),
        w_ring_head: [span_count]u32 = std.mem.zeroes([span_count]u32),
        w_ring_len: [span_count]u32 = std.mem.zeroes([span_count]u32),

        // ── Current window: per counter + frame tallies ─────────────────
        c_frame: [counter_count]u64 = std.mem.zeroes([counter_count]u64),
        w_csum: [counter_count]u64 = std.mem.zeroes([counter_count]u64),
        w_frames: u32 = 0,
        w_drawn: u32 = 0,
        w_skipped: u32 = 0,
        w_since: std.Io.Timestamp = .{ .nanoseconds = 0 },

        // Per-iteration anchor for the `frame` span period `frameBoundary`
        // returns (distinct from the window anchor above).
        frame_since: ?std.Io.Timestamp = null,

        // ── Last published window ───────────────────────────────────────
        p_avg_ms: [span_count]f32 = std.mem.zeroes([span_count]f32),
        p_p95_ms: [span_count]f32 = std.mem.zeroes([span_count]f32),
        p_max_ms: [span_count]f32 = std.mem.zeroes([span_count]f32),
        p_per_frame: [counter_count]f32 = std.mem.zeroes([counter_count]f32),
        p_fps: f32 = 0,
        p_skip: f32 = 0,

        // Optional periodic text-summary dump to `std.log`.
        log_interval_ns: u64 = 0,
        log_since: std.Io.Timestamp = .{ .nanoseconds = 0 },

        /// `window_ms` is the summary window (<= 0 publishes every
        /// `frameBoundary`). `log_interval_ms <= 0` disables the periodic
        /// `std.log` table; a positive value is its cadence.
        pub fn init(io: std.Io, enabled: bool, window_ms: f64, log_interval_ms: f64) Self {
            var self: Self = .{ .io = io, .enabled = enabled };
            if (!enabled) return self;
            self.window_ns = if (window_ms > 0) @intFromFloat(window_ms * std.time.ns_per_ms) else 0;
            const now = self.nowTs();
            self.w_since = now;
            if (log_interval_ms > 0) {
                self.log_interval_ns = @intFromFloat(log_interval_ms * std.time.ns_per_ms);
                self.log_since = now;
            }
            return self;
        }

        /// A monotonic timestamp for `recordSince` / caller-side spans.
        pub fn nowTs(self: *Self) std.Io.Timestamp {
            return std.Io.Timestamp.now(self.io, .awake);
        }

        /// Nanoseconds elapsed since `from` (clamped at 0).
        pub fn elapsedNs(self: *Self, from: std.Io.Timestamp) u64 {
            return durNs(from.durationTo(self.nowTs()));
        }

        /// Records one duration sample for `span` into the current window.
        pub fn record(self: *Self, span: Span, ns: u64) void {
            if (!self.enabled) return;
            const i = @intFromEnum(span);
            self.w_n[i] += 1;
            self.w_sum[i] += ns;
            if (ns > self.w_max[i]) self.w_max[i] = ns;
            self.w_ring[i][self.w_ring_head[i]] = ns;
            self.w_ring_head[i] = (self.w_ring_head[i] + 1) % p95_cap;
            if (self.w_ring_len[i] < p95_cap) self.w_ring_len[i] += 1;
        }

        /// Adds `n` to `counter`'s running total for the frame in
        /// progress (folded into the window by `frameBoundary`).
        pub fn add(self: *Self, counter: Counter, n: u64) void {
            if (!self.enabled) return;
            self.c_frame[@intFromEnum(counter)] += n;
        }

        /// A frame the renderer actually drew.
        pub fn markDrawn(self: *Self) void {
            if (self.enabled) self.w_drawn += 1;
        }

        /// A loop iteration where `needsRedraw` reported nothing moved, so
        /// `render` was skipped.
        pub fn markSkipped(self: *Self) void {
            if (self.enabled) self.w_skipped += 1;
        }

        /// Call exactly once per main-loop iteration, after the last
        /// `add`/`record` of the previous frame. Folds the per-frame
        /// counter totals into the window, publishes + resets the window
        /// if `window_ns` has elapsed, fires the periodic summary, and
        /// returns the wall period (ns) since the previous call -- the
        /// caller records that as its `frame` span.
        pub fn frameBoundary(self: *Self) u64 {
            if (!self.enabled) return 0;
            for (0..counter_count) |k| {
                self.w_csum[k] += self.c_frame[k];
                self.c_frame[k] = 0;
            }
            self.w_frames += 1;

            const now = self.nowTs();
            const period: u64 = if (self.frame_since) |prev| durNs(prev.durationTo(now)) else 0;
            self.frame_since = now;

            const win_elapsed = durNs(self.w_since.durationTo(now));
            if (win_elapsed >= self.window_ns) {
                self.publish(win_elapsed);
                self.w_since = now;
            }
            self.tickLog(now);
            return period;
        }

        /// Closes the current stat window now, regardless of elapsed
        /// time, publishing what it holds. Useful right before reading a
        /// final `snapshot`.
        pub fn publishNow(self: *Self) void {
            if (!self.enabled) return;
            const now = self.nowTs();
            self.publish(durNs(self.w_since.durationTo(now)));
            self.w_since = now;
        }

        fn publish(self: *Self, win_elapsed_ns: u64) void {
            const secs = @as(f64, @floatFromInt(win_elapsed_ns)) / std.time.ns_per_s;
            for (0..span_count) |i| {
                const n = self.w_n[i];
                if (n > 0) {
                    self.p_avg_ms[i] = nsToMs(self.w_sum[i] / n);
                    self.p_max_ms[i] = nsToMs(self.w_max[i]);
                    self.p_p95_ms[i] = nsToMs(self.percentile(i, 95));
                } else {
                    self.p_avg_ms[i] = 0;
                    self.p_max_ms[i] = 0;
                    self.p_p95_ms[i] = 0;
                }
                self.w_n[i] = 0;
                self.w_sum[i] = 0;
                self.w_max[i] = 0;
                self.w_ring_head[i] = 0;
                self.w_ring_len[i] = 0;
            }
            for (0..counter_count) |k| {
                self.p_per_frame[k] = if (self.w_frames > 0)
                    @as(f32, @floatFromInt(self.w_csum[k])) / @as(f32, @floatFromInt(self.w_frames))
                else
                    0;
                self.w_csum[k] = 0;
            }
            if (secs > 0) {
                self.p_fps = @floatCast(@as(f64, @floatFromInt(self.w_drawn)) / secs);
                self.p_skip = @floatCast(@as(f64, @floatFromInt(self.w_skipped)) / secs);
            }
            self.w_frames = 0;
            self.w_drawn = 0;
            self.w_skipped = 0;
        }

        fn percentile(self: *Self, i: usize, pct: usize) u64 {
            const n = self.w_ring_len[i];
            if (n == 0) return 0;
            var tmp: [p95_cap]u64 = undefined;
            @memcpy(tmp[0..n], self.w_ring[i][0..n]);
            std.mem.sort(u64, tmp[0..n], {}, std.sort.asc(u64));
            return tmp[@min((n * pct) / 100, n - 1)];
        }

        fn tickLog(self: *Self, now: std.Io.Timestamp) void {
            if (self.log_interval_ns == 0) return;
            if (durNs(self.log_since.durationTo(now)) < self.log_interval_ns) return;
            self.log_since = now;
            var buf: [2048]u8 = undefined;
            var w = std.Io.Writer.fixed(&buf);
            const snap = self.snapshot();
            writeSummary(&snap, &w) catch return;
            std.log.scoped(.profiler).info("\n{s}", .{w.buffered()});
        }

        /// The last published window as plain data -- what the wire
        /// property returns and the HUD / summary render from.
        pub fn snapshot(self: *Self) core.ProfileSnapshot {
            var snap: core.ProfileSnapshot = .{ .active = self.enabled };
            if (!self.enabled) return snap;

            inline for (span_fields, 0..) |f, i| {
                snap.phases[i] = .{
                    .name = f.name,
                    .avg_ms = self.p_avg_ms[i],
                    .p95_ms = self.p_p95_ms[i],
                    .max_ms = self.p_max_ms[i],
                };
            }
            snap.phase_count = span_count;

            inline for (counter_fields, 0..) |f, k| {
                snap.counters[k] = .{ .name = f.name, .per_frame = self.p_per_frame[k] };
            }
            snap.counter_count = counter_count;

            snap.fps = self.p_fps;
            snap.skips_per_sec = self.p_skip;
            return snap;
        }
    };
}

/// Renders a snapshot as an aligned plain-text table (used for the
/// periodic `std.log` dump and reachable for a probe text view).
pub fn writeSummary(snap: *const core.ProfileSnapshot, w: *std.Io.Writer) !void {
    if (!snap.active) {
        try w.writeAll("profiler inactive\n");
        return;
    }
    try w.print("profiler  fps {d:.1}  skip/s {d:.1}\n", .{ snap.fps, snap.skips_per_sec });
    for (snap.phaseSlice()) |ph| {
        try w.print("  {s:<14} {d:>8.2} avg  {d:>8.2} p95  {d:>8.2} max  (ms)\n", .{
            ph.name, ph.avg_ms, ph.p95_ms, ph.max_ms,
        });
    }
    for (snap.counterSlice()) |c| {
        try w.print("  {s:<14} {d:>10.1} /frame\n", .{ c.name, c.per_frame });
    }
}
