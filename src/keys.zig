// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: MPL-2.0

//! Key and mouse-button identities, shared by everything that handles
//! input: glyphwire-host's engine (`host_eng.input` uses these enums
//! directly), the session's routing and modifier tracking, `key_encode`,
//! `applib.keybind` and the client's `KeyEvent` / `MouseButtonEvent`.
//!
//! **The wire keeps names.** `key_down` / `report_key` and friends carry
//! the `@tagName` of these members, so the field names below are
//! wire-visible: renaming one is a protocol change. A name is turned into
//! a member once, where it is decoded (`Key.fromName`), and from then on
//! input is compared as an enum: no per-event allocation and no `deinit`.
//!
//! A name this build doesn't know (a newer host's key) decodes to
//! `unknown` rather than failing, so an old program keeps running and
//! simply never matches it.

const std = @import("std");

/// Key identities. Uppercase function keys because `F1`..`F24` are what
/// the wire has always carried. Every name is one SDL actually reports:
/// there is no `F25`, and no `world_1` / `world_2`, both of which the old
/// GLFW backend declared and no SDL keycode maps to.
///
/// glyphwire-host takes these from SDL's *keycode* (`event.key.key`),
/// which is resolved through the active OS layout, where zglfw's were
/// physical positions. So on a Dvorak or AZERTY layout a key reports the
/// identity on its keycap rather than its QWERTY position -- the right
/// behaviour for a terminal, and what other terminals do. SDL3's default
/// `SDL_HINT_KEYCODE_OPTIONS` (`"french_numbers,latin_letters"`) keeps
/// Ctrl-chords on the Latin letters under a non-Latin layout such as
/// Russian.
pub const Key = enum {
    unknown,
    space,
    apostrophe,
    comma,
    minus,
    period,
    slash,
    zero,
    one,
    two,
    three,
    four,
    five,
    six,
    seven,
    eight,
    nine,
    semicolon,
    equal,
    a,
    b,
    c,
    d,
    e,
    f,
    g,
    h,
    i,
    j,
    k,
    l,
    m,
    n,
    o,
    p,
    q,
    r,
    s,
    t,
    u,
    v,
    w,
    x,
    y,
    z,
    left_bracket,
    backslash,
    right_bracket,
    grave_accent,
    escape,
    enter,
    tab,
    backspace,
    insert,
    delete,
    right,
    left,
    down,
    up,
    page_up,
    page_down,
    home,
    end,
    caps_lock,
    scroll_lock,
    num_lock,
    print_screen,
    pause,
    F1,
    F2,
    F3,
    F4,
    F5,
    F6,
    F7,
    F8,
    F9,
    F10,
    F11,
    F12,
    F13,
    F14,
    F15,
    F16,
    F17,
    F18,
    F19,
    F20,
    F21,
    F22,
    F23,
    F24,
    kp_0,
    kp_1,
    kp_2,
    kp_3,
    kp_4,
    kp_5,
    kp_6,
    kp_7,
    kp_8,
    kp_9,
    kp_decimal,
    kp_divide,
    kp_multiply,
    kp_subtract,
    kp_add,
    kp_enter,
    kp_equal,
    left_shift,
    left_control,
    left_alt,
    left_super,
    right_shift,
    right_control,
    right_alt,
    right_super,
    menu,

    /// The member a wire name decodes to, exact match; `unknown` for a
    /// name this build doesn't have.
    pub fn fromName(wire_name: []const u8) Key {
        return std.meta.stringToEnum(Key, wire_name) orelse .unknown;
    }

    /// The wire name (`@tagName`).
    pub fn name(self: Key) []const u8 {
        return @tagName(self);
    }

    /// `a`..`z`.
    pub fn isLetter(self: Key) bool {
        return @intFromEnum(self) >= @intFromEnum(Key.a) and @intFromEnum(self) <= @intFromEnum(Key.z);
    }

    /// `zero`..`nine` (the main row, not the keypad).
    pub fn isDigit(self: Key) bool {
        return @intFromEnum(self) >= @intFromEnum(Key.zero) and @intFromEnum(self) <= @intFromEnum(Key.nine);
    }

    /// The digit `zero`..`nine` stand for, or null.
    pub fn digit(self: Key) ?u8 {
        if (!self.isDigit()) return null;
        return @intCast(@intFromEnum(self) - @intFromEnum(Key.zero));
    }

    /// The letter `a`..`z` stand for (lowercase), or null.
    pub fn letter(self: Key) ?u8 {
        if (!self.isLetter()) return null;
        return 'a' + @as(u8, @intCast(@intFromEnum(self) - @intFromEnum(Key.a)));
    }

    /// `F1`..`F24`'s number, or null.
    pub fn functionNumber(self: Key) ?u8 {
        if (@intFromEnum(self) < @intFromEnum(Key.F1) or @intFromEnum(self) > @intFromEnum(Key.F24)) return null;
        return @intCast(@intFromEnum(self) - @intFromEnum(Key.F1) + 1);
    }

    /// Either side's Shift, Control, Alt or Super.
    pub fn isModifier(self: Key) bool {
        return switch (self) {
            .left_shift, .right_shift, .left_control, .right_control, .left_alt, .right_alt, .left_super, .right_super => true,
            else => false,
        };
    }
};

/// Mouse buttons, also carried by name (see `Key`). `x1` / `x2` are the
/// two side buttons; the old GLFW backend called the same physical
/// buttons `four` / `five`. `wheel_up` / `wheel_down` are never held:
/// glyphwire-host sends one press and release per notch over a program
/// that asked for the mouse (`Server.reportWheelTapIn`). `unknown` is
/// only ever a decoded name this build doesn't have.
pub const MouseButton = enum {
    unknown,
    left,
    right,
    middle,
    x1,
    x2,
    wheel_up,
    wheel_down,

    pub fn fromName(wire_name: []const u8) MouseButton {
        return std.meta.stringToEnum(MouseButton, wire_name) orelse .unknown;
    }

    pub fn name(self: MouseButton) []const u8 {
        return @tagName(self);
    }
};
