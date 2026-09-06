const std = @import("std");

// Typematic repeat timing for the keys glyphwire-host synthesizes repeats
// for (arrows, plus Backspace/Delete and Ctrl+U -- see
// `input.KeyInput.handleRepeatKeys`) -- how long a key must be held before
// it starts repeating, and how often it repeats after that. Typical OS
// keyboard-repeat values; tune here if they feel off.
pub const key_repeat_delay_ms: f64 = 500;
pub const key_repeat_interval_ms: f64 = 40;

/// Tracks how long one key has been continuously held, to drive its
/// typematic repeat -- the engine's `Keyboard` only edge-detects
/// `pressed`/`released`, with no built-in hold duration, so the host has
/// to track this itself.
pub const KeyRepeatState = struct {
    held_ms: f64 = 0,
    next_repeat_ms: f64 = key_repeat_delay_ms,

    pub fn reset(self: *KeyRepeatState) void {
        self.held_ms = 0;
        self.next_repeat_ms = key_repeat_delay_ms;
    }

    /// Call once per tick while the key is physically down (not on the
    /// initial press -- that edge already fires once, handled separately).
    /// Returns true once held_ms crosses the next scheduled repeat
    /// threshold.
    pub fn tick(self: *KeyRepeatState, delta_ms: f64) bool {
        self.held_ms += delta_ms;
        if (self.held_ms < self.next_repeat_ms) return false;
        self.next_repeat_ms += key_repeat_interval_ms;
        return true;
    }
};
