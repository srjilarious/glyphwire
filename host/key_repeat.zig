// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: MPL-2.0

//! glyphwire's typematic key-repeat *policy*: which keys a held press
//! repeats for, and what timing those repeats run at.
//!
//! The mechanism itself lives in the engine -- `host_eng`'s `Keyboard`
//! tracks a hold timer for every key and answers `repeated(key)` (see
//! `Keyboard.tickRepeats`). The host only decides which of those repeats
//! are worth putting on the wire, and hands the engine the timing the
//! focused program asked for.

const std = @import("std");
const host_eng = @import("host_eng");
const glyphwire = @import("glyphwire");

const Key = host_eng.input.Key;

// Session-wide default timing, overridable from `host.conf`
// (`key_repeat_delay_ms` / `key_repeat_interval_ms`) and, per program,
// by the `set_key_repeat` notification. Taken from the protocol's own
// defaults rather than restated, so the value a partial `set_key_repeat`
// fills in and the value the host starts at can't drift apart.
pub const delay_ms_default = glyphwire.KeyRepeat.default_delay_ms;
pub const interval_ms_default = glyphwire.KeyRepeat.default_interval_ms;

// Clamp ranges. A zero `delay_ms` is allowed and means "no initial hold"
// -- the first repeat lands one interval after the press, which is what
// a modal editor like zoe asks for. The interval floor keeps a client
// from asking for a repeat rate the update loop can't distinguish from
// "every tick" anyway.
pub const delay_ms_min: f64 = 0;
pub const delay_ms_max: f64 = 5000;
pub const interval_ms_min: f64 = 10;
pub const interval_ms_max: f64 = 2000;

/// Resolved repeat timing: the `host.conf` default, or what a program
/// asked for with `set_key_repeat`. Both fields are already clamped.
pub const Timing = struct {
    delay_ms: f64 = delay_ms_default,
    interval_ms: f64 = interval_ms_default,
};

/// `key_repeat_delay_ms` clamped to `[delay_ms_min, delay_ms_max]`.
pub fn clampDelayMs(ms: f64) f64 {
    return std.math.clamp(ms, delay_ms_min, delay_ms_max);
}

/// `key_repeat_interval_ms` clamped to `[interval_ms_min, interval_ms_max]`.
pub fn clampIntervalMs(ms: f64) f64 {
    return std.math.clamp(ms, interval_ms_min, interval_ms_max);
}

/// The engine timing to run with: the focused context's `set_key_repeat`
/// override when it has one, otherwise the session default from
/// `host.conf`. An override's fields are clamped here rather than at the
/// wire edge, so a client can't hand the engine a nonsense cadence.
pub fn resolve(default: Timing, override: ?glyphwire.KeyRepeat) host_eng.input.KeyRepeat {
    const t: Timing = if (override) |o| .{
        .delay_ms = clampDelayMs(o.delay_ms),
        .interval_ms = clampIntervalMs(o.interval_ms),
    } else default;
    return .{ .delay_ms = t.delay_ms, .interval_ms = t.interval_ms, .enabled = true };
}

/// Whether a held `key` should repeat onto the wire.
///
/// Named keys (the arrows, page/home/end, the editing keys, escape/tab/
/// enter, the function keys) always do: nothing *types* them, so a
/// synthesized repeat is the only way a program hears that one is being
/// held. Text-producing keys do not, because the OS already repeats them
/// down the separate `text` stream (`Keyboard.text`) -- repeating them
/// here as well would deliver a held `j` twice over. The exception is a
/// text key held with Ctrl or Alt: that's a chord, not typing, no text
/// event fires for it, and a held Ctrl+U is expected to keep deleting.
///
/// Modifiers and the lock/system keys never repeat -- `reportKeyEvents`
/// doesn't forward them by name at all, and a repeating CapsLock would
/// mean nothing if it did.
pub fn repeatsKey(key: Key, ctrl: bool, alt: bool) bool {
    return switch (key) {
        .unknown,
        .caps_lock,
        .scroll_lock,
        .num_lock,
        .print_screen,
        .pause,
        .menu,
        .left_shift,
        .left_control,
        .left_alt,
        .left_super,
        .right_shift,
        .right_control,
        .right_alt,
        .right_super,
        => false,

        .escape,
        .enter,
        .tab,
        .backspace,
        .insert,
        .delete,
        .right,
        .left,
        .down,
        .up,
        .page_up,
        .page_down,
        .home,
        .end,
        .kp_enter,
        .F1,
        .F2,
        .F3,
        .F4,
        .F5,
        .F6,
        .F7,
        .F8,
        .F9,
        .F10,
        .F11,
        .F12,
        .F13,
        .F14,
        .F15,
        .F16,
        .F17,
        .F18,
        .F19,
        .F20,
        .F21,
        .F22,
        .F23,
        .F24,
        => true,

        // Everything left types something: letters, digits, punctuation,
        // space and the keypad's number/operator keys.
        else => ctrl or alt,
    };
}
