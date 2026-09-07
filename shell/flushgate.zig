//! A tiny "is it time to write the file yet?" policy, shared by the two
//! bits of persistent shell state that are now kept in memory and flushed
//! lazily rather than rewritten on every change: the command history
//! (`history.zig`) and the `zj` directory database (`zjump.zig`).
//!
//! Both used to hit the disk on every mutation. That is fine for
//! correctness but wasteful, and the reason it was done that way -- an
//! interactive session is normally killed, not exited cleanly -- no
//! longer holds now that the host sends a `shutdown` notification the
//! shell flushes on. This gate is the safety net for the remaining
//! crash/`SIGKILL` case: it forces a flush once enough changes have piled
//! up, or once enough wall-clock time has passed since the last one, so
//! at most `max_dirty` records (or `max_age_ms` of activity) can ever be
//! lost.
//!
//! No IO and no clock of its own: the caller passes `now_ms` in (the same
//! `std.Io.Timestamp` the prompt already reads for its other timers) and
//! does the actual writing.

const std = @import("std");

pub const FlushGate = struct {
    /// Flush once this many un-flushed changes have accumulated.
    max_dirty: u32 = 25,
    /// Flush once this many milliseconds have passed since the last flush,
    /// provided there is at least one un-flushed change.
    max_age_ms: i64 = 120_000,

    /// Un-flushed changes since the last `reset`.
    dirty: u32 = 0,
    /// `now_ms` at the last `reset`. Zero until the first one, which just
    /// means the age test can fire immediately once something is dirty --
    /// harmless, and the caller seeds it with `reset(startup_now)` anyway.
    last_flush_ms: i64 = 0,

    /// Record one change (a recalled history line, a `cd`). Cheap enough
    /// to call unconditionally.
    pub fn note(self: *FlushGate) void {
        self.dirty +|= 1;
    }

    /// Whether the caller should flush now. False when nothing is dirty,
    /// regardless of age.
    pub fn shouldFlush(self: *const FlushGate, now_ms: i64) bool {
        if (self.dirty == 0) return false;
        if (self.dirty >= self.max_dirty) return true;
        return (now_ms -| self.last_flush_ms) >= self.max_age_ms;
    }

    /// Call right after a successful flush: clears the dirty count and
    /// restarts the age clock.
    pub fn reset(self: *FlushGate, now_ms: i64) void {
        self.dirty = 0;
        self.last_flush_ms = now_ms;
    }
};
