// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: GPL-3.0-or-later

//! The kill-job key (`keys{ kill_job = "super+delete" }`): stopping a
//! foreground program from the keyboard when Ctrl+C won't do it.
//!
//! Ctrl+C sends SIGINT, which a program is free to ignore, and several of
//! glyphwire's own do on purpose (zoe and gw-hist take Ctrl+C as a key).
//! The kill-job key sends SIGTERM to the job's whole process group, and
//! SIGKILL `kill_grace_ms` later if anything in it is still running: a
//! program that cleans up on SIGTERM gets the chance, and one that is
//! wedged goes anyway. Pressing the key again before then sends SIGKILL
//! at once.
//!
//! It is the shell's own key, never the program's: a press is swallowed
//! rather than forwarded. Super+Delete is the default because almost
//! nothing running under a shell wants it, unlike Ctrl+C or Ctrl+\.
//!
//! Pure: the foreground loops (`jobs.foregroundJob`,
//! `Prompt.pumpPipeline`) feed it key presses and the time and send
//! whatever signal it answers, so the timing has unit tests.

const std = @import("std");

/// How long after SIGTERM the job gets before SIGKILL.
pub const kill_grace_ms: i64 = 3000;

/// The default `keys{ kill_job }` chord.
pub const default_chord = "super+delete";

pub const Signal = enum { term, kill };

pub const JobStop = struct {
    /// When SIGTERM went, in the caller's milliseconds; null before the
    /// key is pressed.
    term_at: ?i64 = null,
    /// Set once SIGKILL has gone, so it goes once.
    killed: bool = false,

    /// The key was pressed at `now_ms`: the signal to send, if any.
    pub fn press(self: *JobStop, now_ms: i64) ?Signal {
        if (self.killed) return null;
        if (self.term_at == null) {
            self.term_at = now_ms;
            return .term;
        }
        self.killed = true;
        return .kill;
    }

    /// The time is `now_ms` and the job is still running: SIGKILL once
    /// the grace after SIGTERM has run out, otherwise nothing.
    pub fn tick(self: *JobStop, now_ms: i64) ?Signal {
        const t = self.term_at orelse return null;
        if (self.killed or now_ms - t < kill_grace_ms) return null;
        self.killed = true;
        return .kill;
    }

    /// The strongest signal sent so far, for the line the shell prints
    /// once the job is gone. Null when the key was never pressed.
    pub fn sent(self: *const JobStop) ?Signal {
        if (self.killed) return .kill;
        if (self.term_at != null) return .term;
        return null;
    }
};

/// The line the shell prints under a job the key stopped.
pub fn notice(sig: Signal) []const u8 {
    return switch (sig) {
        .term => "stopped (SIGTERM)",
        .kill => "killed (SIGKILL)",
    };
}

pub fn posixSignal(sig: Signal) std.posix.SIG {
    return switch (sig) {
        .term => std.posix.SIG.TERM,
        .kill => std.posix.SIG.KILL,
    };
}
