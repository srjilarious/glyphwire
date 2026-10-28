// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: GPL-3.0-or-later

//! zoe's deadlines: everything `Ui.run` has to wake up for with no input
//! behind it. Each is one slot of an enum-indexed table rather than a
//! `?Timestamp` field of its own, so a new one is a new tag, and
//! `Ui.nextDeadline` (the loop's wait) folds them all without being
//! told it exists.
//!
//! Arming policy stays with each timer's owner: some are left to run
//! out once armed (the `didChange` debounce, the backup sync), the tab
//! tooltip restarts on every move onto a tab. So `arm` just sets the
//! deadline, and the owner checks `armed` first where it wants to.
//!
//! The deadlines are `Clock.Timestamp`s on the awake clock, because
//! that is what `Io.Timeout` takes; `isDue` compares their raw times,
//! so the tests can drive it with made-up ones.

const std = @import("std");

const Timestamp = std.Io.Clock.Timestamp;

pub const Timer = enum {
    /// A `didChange` waiting on the debounce (`armLspChange`).
    lsp_change,
    /// An identifier-driven completion request waiting on
    /// `complete_auto_delay_ms`, so a burst of typing asks once.
    completion,
    /// The tab tooltip going up (`tab_tooltip_delay_ms` after the
    /// pointer comes to rest on a tab).
    tab_tip,
    /// The open files' next stat for outside changes (`armDiskCheck`).
    disk_check,
    /// The backups catching up with the buffers (`armBackup`).
    backup,
};

pub const Timers = struct {
    at: std.EnumArray(Timer, ?Timestamp) = .initFill(null),

    pub fn armed(self: *const Timers, t: Timer) bool {
        return self.at.get(t) != null;
    }

    /// Sets `t` to go off `ms` from now, replacing any deadline it had.
    pub fn armIn(self: *Timers, io: std.Io, t: Timer, ms: i64) void {
        self.at.set(t, Timestamp.fromNow(io, .{ .raw = .fromMilliseconds(ms), .clock = .awake }));
    }

    pub fn disarm(self: *Timers, t: Timer) void {
        self.at.set(t, null);
    }

    /// Whether `t` is armed and its deadline is at or before `now`.
    pub fn isDue(self: *const Timers, t: Timer, now: std.Io.Timestamp) bool {
        const deadline = self.at.get(t) orelse return false;
        return deadline.raw.durationTo(now).toNanoseconds() >= 0;
    }

    /// `isDue` against the awake clock.
    pub fn due(self: *const Timers, io: std.Io, t: Timer) bool {
        return self.isDue(t, std.Io.Clock.awake.now(io));
    }

    /// Whether `t` has come due, disarming it if so: the one-shot check
    /// for a timer whose owner re-arms it on a later turn.
    pub fn take(self: *Timers, io: std.Io, t: Timer) bool {
        if (!self.due(io, t)) return false;
        self.disarm(t);
        return true;
    }

    /// The earliest armed deadline, or null with none armed.
    pub fn next(self: *const Timers) ?Timestamp {
        var best: ?Timestamp = null;
        for (std.enums.values(Timer)) |t| best = earlier(best, self.at.get(t));
        return best;
    }
};

/// The sooner of two optional deadlines.
pub fn earlier(a: ?Timestamp, b: ?Timestamp) ?Timestamp {
    const x = a orelse return b;
    const y = b orelse return a;
    return if (x.raw.nanoseconds <= y.raw.nanoseconds) x else y;
}
