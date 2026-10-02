// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: GPL-3.0-or-later

//! `ZOE_PROFILE=<path>`: a per-frame timing log, for finding out where a
//! sluggish frame went before guessing.
//!
//! One line per frame that drew something, written to `<path>` (replaced
//! each run):
//!
//! ```text
//! frame=812 events=3 input_us=40 parse_us=310 spans_us=95 span_lines=12 paint_us=210 send_us=60 total_us=715 bytes=18234
//! ```
//!
//! - `events` / `input_us`: the queued events folded into this frame and
//!   the time spent handling them (key dispatch, motions, edits).
//! - `parse_us`: tree-sitter -- the frame's incremental reparse plus any
//!   background slice of a staged whole-buffer parse since the last frame.
//! - `spans_us` / `span_lines`: running highlight queries, and how many
//!   buffer lines they produced spans for.
//! - `paint_us`: the rest of building the frame's batch.
//! - `send_us` / `bytes`: framing and writing the batch to the socket.
//! - `total_us`: input through send.
//!
//! Off (no env var, or the file won't open) every call is a branch on a
//! null file and nothing else, so it can stay compiled in.

const std = @import("std");

pub const Phase = enum { input, parse, spans, paint, send };
const phase_count = 5;

pub const Profile = struct {
    io: std.Io,
    file: ?std.Io.File = null,
    frame: u64 = 0,
    events: u32 = 0,
    span_lines: u32 = 0,
    bytes: usize = 0,
    /// Nanoseconds per `Phase`, reset after each logged frame.
    ns: [phase_count]i96 = @splat(0),

    /// Opens `path` for appending when it is set; otherwise a disabled
    /// profile. A path that can't be opened is warned about once and
    /// leaves profiling off rather than failing zoe's start.
    pub fn init(io: std.Io, path: ?[]const u8) Profile {
        var p: Profile = .{ .io = io };
        const target = path orelse return p;
        if (target.len == 0) return p;
        p.file = std.Io.Dir.cwd().createFile(io, target, .{}) catch |err| {
            std.log.warn("zoe: ZOE_PROFILE file '{s}' won't open ({t}); profiling off", .{ target, err });
            return p;
        };
        return p;
    }

    pub fn deinit(self: *Profile) void {
        if (self.file) |f| f.close(self.io);
        self.file = null;
    }

    pub fn enabled(self: *const Profile) bool {
        return self.file != null;
    }

    /// A start mark for `add`; zero (and unused) while disabled.
    pub fn now(self: *const Profile) std.Io.Timestamp {
        if (self.file == null) return .zero;
        return std.Io.Clock.awake.now(self.io);
    }

    /// Charges the time since `since` to `phase`.
    pub fn add(self: *Profile, phase: Phase, since: std.Io.Timestamp) void {
        if (self.file == null) return;
        const d = since.durationTo(std.Io.Clock.awake.now(self.io));
        self.ns[@intFromEnum(phase)] += d.nanoseconds;
    }

    /// Time already charged to the phases that run *inside* building a
    /// frame (parse, spans), so the frame's own `.paint` share can be
    /// worked out net of them with `addNet`.
    pub fn nestedNs(self: *const Profile) i96 {
        return self.ns[@intFromEnum(Phase.parse)] + self.ns[@intFromEnum(Phase.spans)];
    }

    /// Charges the time since `since` to `phase`, less whatever nested
    /// phases were charged meanwhile (`nestedNs` now minus `nested_before`).
    pub fn addNet(self: *Profile, phase: Phase, since: std.Io.Timestamp, nested_before: i96) void {
        if (self.file == null) return;
        const d = since.durationTo(std.Io.Clock.awake.now(self.io));
        self.ns[@intFromEnum(phase)] += d.nanoseconds - (self.nestedNs() - nested_before);
    }

    /// Writes the frame's line and resets the counters for the next one.
    pub fn endFrame(self: *Profile) void {
        const f = self.file orelse return;
        self.frame += 1;
        var line: [256]u8 = undefined;
        const us = struct {
            fn of(ns: i96) i64 {
                return @intCast(@divTrunc(ns, std.time.ns_per_us));
            }
        }.of;
        var total: i96 = 0;
        for (self.ns) |n| total += n;
        const text = std.fmt.bufPrint(
            &line,
            "frame={d} events={d} input_us={d} parse_us={d} spans_us={d} span_lines={d} paint_us={d} send_us={d} total_us={d} bytes={d}\n",
            .{
                self.frame,
                self.events,
                us(self.ns[@intFromEnum(Phase.input)]),
                us(self.ns[@intFromEnum(Phase.parse)]),
                us(self.ns[@intFromEnum(Phase.spans)]),
                self.span_lines,
                us(self.ns[@intFromEnum(Phase.paint)]),
                us(self.ns[@intFromEnum(Phase.send)]),
                us(total),
                self.bytes,
            },
        ) catch return;
        f.writeStreamingAll(self.io, text) catch {};
        self.events = 0;
        self.span_lines = 0;
        self.bytes = 0;
        self.ns = @splat(0);
    }
};
