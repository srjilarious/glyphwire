// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: MPL-2.0

const std = @import("std");
const sdl = @import("sdl3");
const core = @import("core.zig");

const NumKeys = @typeInfo(Key).@"enum".field_names.len;
const NumMouseButtons = @typeInfo(MouseButton).@"enum".field_names.len;

/// Number of bytes of `bytes[0..n]` that end on a UTF-8 sequence
/// boundary: `n` itself unless it lands mid-sequence, in which case the
/// partial trailing sequence is dropped. Truncating typed text on a raw
/// byte count would put a half-encoded codepoint on the wire, which for
/// CJK input (3 bytes per character) is not a hypothetical.
fn utf8Boundary(bytes: []const u8, n: usize) usize {
    var end = @min(n, bytes.len);
    if (end == bytes.len) return end; // nothing dropped, nothing to split
    // `bytes[end]` is the first byte that would be dropped. A continuation
    // byte there (0b10xxxxxx) means the cut landed inside a sequence: back
    // up over the continuations and off the lead byte that started it.
    while (end > 0 and bytes[end] & 0xC0 == 0x80) end -= 1;
    return end;
}

fn FixedBuffer(comptime capacity: usize) type {
    return struct {
        bytes: [capacity]u8 = undefined,
        len: usize = 0,

        const Self = @This();

        /// Appends as much of `bytes` as fits, cutting on a UTF-8
        /// boundary rather than mid-sequence when it doesn't all fit.
        fn appendSlice(self: *Self, bytes: []const u8) void {
            const room = capacity - self.len;
            const n = if (bytes.len <= room) bytes.len else utf8Boundary(bytes, room);
            @memcpy(self.bytes[self.len..][0..n], bytes[0..n]);
            self.len += n;
        }

        fn clear(self: *Self) void {
            self.len = 0;
        }

        fn slice(self: *const Self) []const u8 {
            return self.bytes[0..self.len];
        }
    };
}

/// Key identities forwarded to glyphwire by name (`@tagName`), so the
/// field names here are wire-visible and must match what the rest of
/// glyphwire matches on -- notably `src/key_encode.zig`'s `F1`..`F12`
/// entries, hence the uppercase function keys. Every name here is one SDL
/// actually reports: there is no `F25`, and no `world_1`/`world_2`, both
/// of which the old GLFW backend declared and no SDL keycode maps to.
///
/// These come from SDL's *keycode* (`event.key.key`), which is resolved
/// through the active OS layout, where zglfw's are physical positions. So
/// on a Dvorak or AZERTY layout a key reports the identity on its keycap
/// rather than its QWERTY position -- the right behaviour for a terminal,
/// and what other terminals do. SDL3's default `SDL_HINT_KEYCODE_OPTIONS`
/// (`"french_numbers,latin_letters"`) keeps Ctrl-chords on the Latin
/// letters under a non-Latin layout such as Russian.
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
};

/// Mouse buttons, also forwarded by name (see `Key`). `x1`/`x2` are the
/// two side buttons; the old GLFW backend called the same physical
/// buttons `four`/`five` and declared `six`..`eight` on top, which no
/// platform ever reported. `host/input.zig` forwards every field of this
/// enum, so these names are wire-visible too.
pub const MouseButton = enum {
    left,
    right,
    middle,
    x1,
    x2,
};

/// One line per raw key event when `InputManager.key_debug` is on.
///
/// Both SDL identities are printed because they answer different
/// questions: the **keycode** is the symbol the layout produces (what
/// `mapKey` switches on, and what a laptop's Fn layer rewrites), the
/// **scancode** is the physical key. A key that reports `unknown` here
/// never reaches glyphwire at all; a key that maps but does nothing is a
/// binding problem further up.
fn logKeyEvent(ev: sdl.SDL_KeyboardEvent, mapped: Key) void {
    const key_name = sdl.SDL_GetKeyName(ev.key);
    const scan_name = sdl.SDL_GetScancodeName(ev.scancode);
    std.log.info(
        "key {s}: keycode=0x{X} ({s}) scancode={d} ({s}) mods=0x{X} repeat={} -> {t}",
        .{
            if (ev.down) "down" else "up",
            ev.key,
            if (key_name) |n| std.mem.span(n) else "",
            ev.scancode,
            if (scan_name) |n| std.mem.span(n) else "",
            ev.mod,
            ev.repeat,
            mapped,
        },
    );
}

/// The other half of `logKeyEvent`'s trace, once a tick: every repeat
/// `Keyboard.tickRepeatsAt` just fired, with how long its key had been
/// held, and every key whose press and release both landed in this tick
/// (a tap, or a release and re-press, inside one event batch). Repeats
/// are logged for every key, including ones the host never forwards.
fn logKeyTick(kb: *const Keyboard) void {
    for (0..NumKeys) |idx| {
        const key: Key = @enumFromInt(idx);
        if (kb.repeat_bits.isSet(idx)) {
            std.log.info("key repeat {t}: held={d:.1}ms", .{ key, kb.heldMs(idx) });
        }
        if (kb.pressed_bits.isSet(idx) and kb.released_bits.isSet(idx)) {
            std.log.info("key {t}: pressed and released in one tick, now {s}", .{ key, if (kb.curr.isSet(idx)) "down" else "up" });
        }
    }
}

fn keyIndex(key: Key) usize {
    return @intFromEnum(key);
}

fn buttonIndex(button: MouseButton) usize {
    return @intFromEnum(button);
}

fn mapKey(key: sdl.SDL_Keycode) Key {
    return switch (key) {
        sdl.SDLK_SPACE => .space,
        sdl.SDLK_APOSTROPHE => .apostrophe,
        sdl.SDLK_COMMA => .comma,
        sdl.SDLK_MINUS => .minus,
        sdl.SDLK_PERIOD => .period,
        sdl.SDLK_SLASH => .slash,
        sdl.SDLK_0 => .zero,
        sdl.SDLK_1 => .one,
        sdl.SDLK_2 => .two,
        sdl.SDLK_3 => .three,
        sdl.SDLK_4 => .four,
        sdl.SDLK_5 => .five,
        sdl.SDLK_6 => .six,
        sdl.SDLK_7 => .seven,
        sdl.SDLK_8 => .eight,
        sdl.SDLK_9 => .nine,
        sdl.SDLK_SEMICOLON => .semicolon,
        sdl.SDLK_EQUALS => .equal,
        sdl.SDLK_A => .a,
        sdl.SDLK_B => .b,
        sdl.SDLK_C => .c,
        sdl.SDLK_D => .d,
        sdl.SDLK_E => .e,
        sdl.SDLK_F => .f,
        sdl.SDLK_G => .g,
        sdl.SDLK_H => .h,
        sdl.SDLK_I => .i,
        sdl.SDLK_J => .j,
        sdl.SDLK_K => .k,
        sdl.SDLK_L => .l,
        sdl.SDLK_M => .m,
        sdl.SDLK_N => .n,
        sdl.SDLK_O => .o,
        sdl.SDLK_P => .p,
        sdl.SDLK_Q => .q,
        sdl.SDLK_R => .r,
        sdl.SDLK_S => .s,
        sdl.SDLK_T => .t,
        sdl.SDLK_U => .u,
        sdl.SDLK_V => .v,
        sdl.SDLK_W => .w,
        sdl.SDLK_X => .x,
        sdl.SDLK_Y => .y,
        sdl.SDLK_Z => .z,
        sdl.SDLK_LEFTBRACKET => .left_bracket,
        sdl.SDLK_BACKSLASH => .backslash,
        sdl.SDLK_RIGHTBRACKET => .right_bracket,
        sdl.SDLK_GRAVE => .grave_accent,
        sdl.SDLK_ESCAPE => .escape,
        sdl.SDLK_RETURN => .enter,
        sdl.SDLK_TAB => .tab,
        sdl.SDLK_BACKSPACE => .backspace,
        sdl.SDLK_INSERT => .insert,
        sdl.SDLK_DELETE => .delete,
        sdl.SDLK_RIGHT => .right,
        sdl.SDLK_LEFT => .left,
        sdl.SDLK_DOWN => .down,
        sdl.SDLK_UP => .up,
        sdl.SDLK_PAGEUP => .page_up,
        sdl.SDLK_PAGEDOWN => .page_down,
        sdl.SDLK_HOME => .home,
        sdl.SDLK_END => .end,
        sdl.SDLK_CAPSLOCK => .caps_lock,
        sdl.SDLK_SCROLLLOCK => .scroll_lock,
        sdl.SDLK_NUMLOCKCLEAR => .num_lock,
        sdl.SDLK_PRINTSCREEN => .print_screen,
        sdl.SDLK_PAUSE => .pause,
        sdl.SDLK_F1 => .F1,
        sdl.SDLK_F2 => .F2,
        sdl.SDLK_F3 => .F3,
        sdl.SDLK_F4 => .F4,
        sdl.SDLK_F5 => .F5,
        sdl.SDLK_F6 => .F6,
        sdl.SDLK_F7 => .F7,
        sdl.SDLK_F8 => .F8,
        sdl.SDLK_F9 => .F9,
        sdl.SDLK_F10 => .F10,
        sdl.SDLK_F11 => .F11,
        sdl.SDLK_F12 => .F12,
        sdl.SDLK_F13 => .F13,
        sdl.SDLK_F14 => .F14,
        sdl.SDLK_F15 => .F15,
        sdl.SDLK_F16 => .F16,
        sdl.SDLK_F17 => .F17,
        sdl.SDLK_F18 => .F18,
        sdl.SDLK_F19 => .F19,
        sdl.SDLK_F20 => .F20,
        sdl.SDLK_F21 => .F21,
        sdl.SDLK_F22 => .F22,
        sdl.SDLK_F23 => .F23,
        sdl.SDLK_F24 => .F24,
        sdl.SDLK_KP_0 => .kp_0,
        sdl.SDLK_KP_1 => .kp_1,
        sdl.SDLK_KP_2 => .kp_2,
        sdl.SDLK_KP_3 => .kp_3,
        sdl.SDLK_KP_4 => .kp_4,
        sdl.SDLK_KP_5 => .kp_5,
        sdl.SDLK_KP_6 => .kp_6,
        sdl.SDLK_KP_7 => .kp_7,
        sdl.SDLK_KP_8 => .kp_8,
        sdl.SDLK_KP_9 => .kp_9,
        sdl.SDLK_KP_PERIOD => .kp_decimal,
        sdl.SDLK_KP_DIVIDE => .kp_divide,
        sdl.SDLK_KP_MULTIPLY => .kp_multiply,
        sdl.SDLK_KP_MINUS => .kp_subtract,
        sdl.SDLK_KP_PLUS => .kp_add,
        sdl.SDLK_KP_ENTER => .kp_enter,
        sdl.SDLK_KP_EQUALS => .kp_equal,
        sdl.SDLK_LSHIFT => .left_shift,
        sdl.SDLK_LCTRL => .left_control,
        sdl.SDLK_LALT => .left_alt,
        sdl.SDLK_LGUI => .left_super,
        sdl.SDLK_RSHIFT => .right_shift,
        sdl.SDLK_RCTRL => .right_control,
        sdl.SDLK_RALT => .right_alt,
        sdl.SDLK_RGUI => .right_super,
        sdl.SDLK_APPLICATION => .menu,
        else => .unknown,
    };
}

fn mapMouseButton(button: u8) ?MouseButton {
    return switch (button) {
        sdl.SDL_BUTTON_LEFT => .left,
        sdl.SDL_BUTTON_RIGHT => .right,
        sdl.SDL_BUTTON_MIDDLE => .middle,
        sdl.SDL_BUTTON_X1 => .x1,
        sdl.SDL_BUTTON_X2 => .x2,
        else => null,
    };
}

/// Typematic key-repeat timing: how long a key must be held before it
/// starts repeating, and how often it repeats after that. `Keyboard`
/// synthesizes the repeats itself rather than passing the OS's through,
/// because the cadence has to be retimeable at runtime -- glyphwire lets
/// the focused program pick its own (see `host/key_repeat.zig`), and an
/// editor wants a far shorter initial hold than a shell does.
///
/// `delay_ms` equal to `interval_ms` means "no distinct initial hold":
/// the first repeat lands one interval after the press, same as every
/// one after it. `enabled = false` turns repeats off entirely, and
/// `repeated` then never reports true.
pub const KeyRepeat = struct {
    delay_ms: f64 = 500,
    interval_ms: f64 = 40,
    enabled: bool = true,
};

pub const Keyboard = struct {
    curr: std.StaticBitSet(NumKeys) = std.StaticBitSet(NumKeys).empty,
    /// Keys that went down / came up since the last `finishTick`,
    /// recorded as the events arrive rather than read off a diff of
    /// `curr` between ticks. A diff can't see a key that went up and
    /// down again inside one event batch -- release Down and press it
    /// again while the loop is busy drawing a frame, and `curr` never
    /// changes: the release and the fresh press both vanish, and the old
    /// hold, long past its initial delay, carries straight on repeating.
    /// Both bits set means both happened; `curr` says which came last.
    pressed_bits: std.StaticBitSet(NumKeys) = std.StaticBitSet(NumKeys).empty,
    released_bits: std.StaticBitSet(NumKeys) = std.StaticBitSet(NumKeys).empty,
    mods: sdl.SDL_Keymod = 0,
    text_buf: FixedBuffer(1024) = .{},

    /// The IME's in-progress composition ("preedit"), from
    /// `SDL_EVENT_TEXT_EDITING`. Unlike `text_buf` this is *not* per-tick
    /// state: it persists across frames for as long as the user is
    /// composing, is replaced wholesale by each editing event, and is
    /// cleared when the IME commits (a `SDL_EVENT_TEXT_INPUT`, which
    /// carries the committed text through `text_buf`) or cancels (an
    /// editing event with an empty string). The application is expected
    /// to draw it at the caret -- until it does, typing Japanese/Chinese/
    /// Korean shows nothing at all until the commit lands.
    preedit_buf: FixedBuffer(256) = .{},
    /// Caret position within the composition, as a codepoint index, or -1
    /// when the IME didn't report one. SDL reports this in codepoints, not
    /// bytes; `preeditCursorByte` converts. (SDL also reports a selection
    /// length alongside it, for IMEs that highlight a clause within the
    /// composition; nothing here draws that, so it isn't kept.)
    preedit_cursor: i32 = -1,

    /// Typematic repeat timing. Applies from the next press onward: a key
    /// already held when this changes keeps the schedule its press
    /// started, so a mid-hold retime can't fire a burst of catch-up
    /// repeats.
    repeat: KeyRepeat = .{},
    /// The keyboard's clock, in ms: the time `tickRepeatsAt` was last
    /// run at. The engine loop feeds it wall time (SDL's tick counter,
    /// the same base as an event's timestamp); `set` stamps a press at it.
    now_ms: f64 = 0,
    /// Per-key press time, and the hold time its next repeat is due at,
    /// both in ms and both only meaningful while the key is down. The
    /// hold is measured from the press *event's* own timestamp, not
    /// counted up in tick steps: the loop runs its catch-up ticks after
    /// draining the events, so counting would credit a fresh press with
    /// the idle time before it happened. Every key is tracked; which
    /// keys a repeat actually *means* something for is the application's
    /// call -- `repeated` is only a query.
    pressed_at_ms: [NumKeys]f64 = @splat(0),
    next_repeat_ms: [NumKeys]f64 = @splat(0),
    /// Keys whose repeat fired during this tick's `tickRepeats`. Cleared
    /// at the start of each tick, like `pressed`/`released`'s edges.
    repeat_bits: std.StaticBitSet(NumKeys) = std.StaticBitSet(NumKeys).empty,
    /// Keys held across a `cancelRepeats`, which stay quiet until they
    /// are pressed again. Distinct from simply pushing their next repeat
    /// far out: a suppressed key has no schedule at all, so nothing --
    /// including the idle-wait deadline -- treats it as pending.
    repeat_suppressed: std.StaticBitSet(NumKeys) = std.StaticBitSet(NumKeys).empty,

    /// Committed text that a held key is repeating, and the key it came
    /// from -- what `textRepeated` re-emits on each of that key's
    /// repeats. Set by `noteCommittedText` only for text that arrived on
    /// a fresh press (see there), cleared when that key comes up.
    /// Persists across ticks for as long as the key is held, unlike
    /// `text_buf`.
    text_repeat_key: ?Key = null,
    text_repeat_buf: FixedBuffer(64) = .{},
    /// The most recent fresh (non-OS-repeat) key press, so a
    /// `SDL_EVENT_TEXT_INPUT` that follows it can be attributed to the
    /// key that produced it. Held until that key comes up (rather than
    /// cleared each tick) because the text event doesn't have to land in
    /// the same event batch as its press.
    pending_press: ?Key = null,
    /// The last key-down seen, and whether it was one of the OS's own
    /// auto-repeats. A text event following an OS-repeated key-down is
    /// the desktop repeating a held printable key at *its* rate; see
    /// `absorbRepeatedText` for why that one is swallowed.
    last_down_key: ?Key = null,
    last_down_was_os_repeat: bool = false,

    /// Records a key going down or up at the keyboard's current clock.
    /// See `setAt`.
    pub fn set(self: *Keyboard, key: Key, down_value: bool) void {
        self.setAt(key, down_value, self.now_ms);
    }

    /// Records a key going down or up at `at_ms` (the event's timestamp),
    /// latching the edge into `pressed_bits` / `released_bits`. A
    /// key-down for a key already down -- the OS auto-repeating it -- is
    /// no edge and leaves its hold alone.
    pub fn setAt(self: *Keyboard, key: Key, down_value: bool, at_ms: f64) void {
        const idx = keyIndex(key);
        if (down_value == self.curr.isSet(idx)) return;
        if (down_value) {
            self.curr.set(idx);
            self.pressed_bits.set(idx);
            self.pressed_at_ms[idx] = at_ms;
        } else {
            self.curr.unset(idx);
            self.released_bits.set(idx);
        }
    }

    pub fn down(self: *const Keyboard, key: Key) bool {
        return self.curr.isSet(keyIndex(key));
    }

    /// Whether `key` went down this tick. Can be true together with
    /// `released` -- a tap, or a release and re-press, inside one event
    /// batch -- and `down` then says which came last.
    pub fn pressed(self: *const Keyboard, key: Key) bool {
        return self.pressed_bits.isSet(keyIndex(key));
    }

    /// Whether `key` came up this tick. See `pressed`.
    pub fn released(self: *const Keyboard, key: Key) bool {
        return self.released_bits.isSet(keyIndex(key));
    }

    /// Whether `key`'s typematic repeat fired this tick -- the held-key
    /// counterpart of `pressed`. False on the press itself (that edge is
    /// `pressed`'s to report) and false for a key that is up. Driven by
    /// `tickRepeats`, which `InputManager.update` runs once per tick.
    pub fn repeated(self: *const Keyboard, key: Key) bool {
        return self.repeat_bits.isSet(keyIndex(key));
    }

    /// Milliseconds until `key`'s next typematic repeat is due, or null
    /// when it is up, when repeats are off, or when it hasn't been held
    /// long enough for the press tick to have started its schedule.
    ///
    /// For an app that blocks on the OS event queue when idle
    /// (`redrawOnDemand`): the hold timer only advances while the loop is
    /// running, so a loop parked in `waitEvents` has to be woken for the
    /// repeat, or it sleeps through the schedule and then fires the whole
    /// backlog in one frame. See `host/app.zig`'s `idleTimeoutMs`.
    pub fn repeatDueMs(self: *const Keyboard, key: Key) ?f64 {
        if (!self.repeat.enabled) return null;
        const idx = keyIndex(key);
        if (!self.curr.isSet(idx)) return null;
        if (self.repeat_suppressed.isSet(idx)) return null;
        return @max(0, self.next_repeat_ms[idx] - self.heldMs(idx));
    }

    /// Stops everything currently held from repeating until it is
    /// pressed again, and forgets what a held key was typing.
    ///
    /// The boundary this exists for is a program changing what its keys
    /// *mean* mid-hold. zoe pressing `i` is the case that matters: `i`
    /// types, so it forms a text repeat, and the keystroke that switched
    /// the editor into insert mode would then go on repeating itself
    /// into the buffer it just opened. Nothing downstream can catch
    /// that -- a repeat is deliberately indistinguishable from a fresh
    /// press on the wire -- so the program says so instead, by retiming
    /// its repeat (see `host/input.zig`'s `syncRepeatTiming`).
    pub fn cancelRepeats(self: *Keyboard) void {
        self.repeat_suppressed = self.curr;
        self.repeat_bits = std.StaticBitSet(NumKeys).empty;
        self.clearTextRepeat();
    }

    /// How long the key at `idx` has been held as of `now_ms`.
    fn heldMs(self: *const Keyboard, idx: usize) f64 {
        return @max(0, self.now_ms - self.pressed_at_ms[idx]);
    }

    /// `tickRepeatsAt`, `delta_ms` past the keyboard's current clock.
    pub fn tickRepeats(self: *Keyboard, delta_ms: f64) void {
        self.tickRepeatsAt(self.now_ms + delta_ms);
    }

    /// Moves the keyboard's clock to `now_ms` and republishes
    /// `repeat_bits` for this tick. A key pressed this tick starts its
    /// schedule over at `repeat.delay_ms`, measured from its press; a key
    /// that is up has its schedule cleared, so a re-press always waits
    /// the full initial hold again.
    ///
    /// At most one repeat per key per tick, and a stall drops the repeats
    /// it slept through rather than firing them as a burst: the schedule
    /// picks up one interval from now. A program that redraws on every
    /// repeat would otherwise take a hitch as a jump of several lines
    /// at once, and overshoot what the user was scrolling to. The engine
    /// loop runs every tick of one frame at the same `now_ms`, so a frame
    /// that catches up on several ticks still fires a key once.
    pub fn tickRepeatsAt(self: *Keyboard, now_ms: f64) void {
        self.now_ms = now_ms;
        self.repeat_bits = std.StaticBitSet(NumKeys).empty;
        for (0..NumKeys) |idx| {
            if (!self.curr.isSet(idx)) {
                self.next_repeat_ms[idx] = 0;
                self.repeat_suppressed.unset(idx);
                continue;
            }
            if (self.pressed_bits.isSet(idx)) {
                // The press edge itself -- start the hold schedule, and
                // lift any suppression: a fresh press is exactly what
                // `cancelRepeats` was waiting for.
                self.next_repeat_ms[idx] = self.repeat.delay_ms;
                self.repeat_suppressed.unset(idx);
                continue;
            }
            if (self.repeat_suppressed.isSet(idx)) continue;
            if (!self.repeat.enabled) continue;
            const held = self.heldMs(idx);
            if (held < self.next_repeat_ms[idx]) continue;
            self.repeat_bits.set(idx);
            self.next_repeat_ms[idx] += self.repeat.interval_ms;
            if (self.next_repeat_ms[idx] <= held) self.next_repeat_ms[idx] = held + self.repeat.interval_ms;
        }
    }

    pub fn ctrl(self: *const Keyboard) bool {
        return (self.mods & sdl.SDL_KMOD_CTRL) != 0 or self.down(.left_control) or self.down(.right_control);
    }

    pub fn alt(self: *const Keyboard) bool {
        return (self.mods & sdl.SDL_KMOD_ALT) != 0 or self.down(.left_alt) or self.down(.right_alt);
    }

    pub fn shift(self: *const Keyboard) bool {
        return (self.mods & sdl.SDL_KMOD_SHIFT) != 0 or self.down(.left_shift) or self.down(.right_shift);
    }

    pub fn super(self: *const Keyboard) bool {
        return (self.mods & sdl.SDL_KMOD_GUI) != 0 or self.down(.left_super) or self.down(.right_super);
    }

    /// Copies this tick's typed text into `out` as UTF-8 and returns the
    /// number of bytes written. Non-destructive: repeated calls in the
    /// same tick return the same text; the buffer is cleared by
    /// `finishTick`. If `out` is too small the text is cut on a UTF-8
    /// boundary, never mid-sequence.
    pub fn text(self: *Keyboard, out: []u8) usize {
        const buf = self.text_buf.slice();
        const n = if (buf.len <= out.len) buf.len else utf8Boundary(buf, out.len);
        @memcpy(out[0..n], buf[0..n]);
        return n;
    }

    /// The IME's in-progress composition, or an empty slice when nothing
    /// is being composed. Valid until the next `handleEvent` call.
    pub fn preedit(self: *const Keyboard) []const u8 {
        return self.preedit_buf.slice();
    }

    /// Caret offset within `preedit()` in *bytes*, clamped into range.
    /// SDL reports it in codepoints; this walks the composition to convert
    /// so callers can slice the text directly. Null when the IME didn't
    /// report a position.
    pub fn preeditCursorByte(self: *const Keyboard) ?usize {
        if (self.preedit_cursor < 0) return null;
        const composing = self.preedit_buf.slice();
        var remaining: usize = @intCast(self.preedit_cursor);
        var i: usize = 0;
        while (remaining > 0 and i < composing.len) : (remaining -= 1) {
            i += std.unicode.utf8ByteSequenceLength(composing[i]) catch return i;
        }
        return @min(i, composing.len);
    }

    /// Appends typed UTF-8 to this tick's text buffer. Driven by
    /// `InputManager.handleEvent` on `SDL_EVENT_TEXT_INPUT`; public so a
    /// test can drive the same path without an SDL event queue.
    pub fn pushText(self: *Keyboard, utf8: []const u8) void {
        self.text_buf.appendSlice(utf8);
    }

    /// Records a key-down, so a text event that follows can be attributed
    /// to the key that produced it, and so the text event following one
    /// of the OS's own auto-repeats can be told apart from a freshly
    /// typed one. `os_repeat` is SDL's `event.key.repeat`.
    pub fn noteKeyDown(self: *Keyboard, key: Key, os_repeat: bool) void {
        self.last_down_key = key;
        self.last_down_was_os_repeat = os_repeat;
        if (!os_repeat) self.pending_press = key;
    }

    /// Records a key-up: a released key can no longer be repeating its
    /// text, and the next text event must not be attributed to it.
    pub fn noteKeyUp(self: *Keyboard, key: Key) void {
        self.last_down_was_os_repeat = false;
        if (self.last_down_key == key) self.last_down_key = null;
        if (self.pending_press == key) self.pending_press = null;
        if (self.text_repeat_key == key) self.clearTextRepeat();
    }

    /// Remembers `utf8` as the text a held key repeats, when it can be
    /// attributed to a press of a key that is still down -- which is what
    /// makes it safe to re-send later.
    ///
    /// Text that fails that test is deliberately *not* remembered: an IME
    /// commit (which lands while a composition is in flight, often with
    /// no key event of its own since the IME consumed the keys) belongs
    /// to a finished composition rather than to a key being held, and
    /// re-sending it on a hold would type characters nobody asked for.
    /// Such text still reaches the application normally -- it just never
    /// repeats on this clock, and its OS repeats (if any) are left alone.
    pub fn noteCommittedText(self: *Keyboard, utf8: []const u8) void {
        // Called before `clearPreedit`, so a composition still in flight
        // here means this commit came from the IME.
        if (self.preedit_buf.len != 0) {
            self.clearTextRepeat();
            return;
        }
        const key = self.pending_press orelse {
            self.clearTextRepeat();
            return;
        };
        if (!self.down(key)) {
            self.clearTextRepeat();
            return;
        }
        self.text_repeat_key = key;
        self.text_repeat_buf.clear();
        self.text_repeat_buf.appendSlice(utf8);
    }

    /// Swallows a text event that is the OS auto-repeating a key this
    /// keyboard is already repeating on its own clock, returning whether
    /// it did. Two cadences for one held key -- the desktop's for the
    /// letter it types, ours for everything else -- is the thing this
    /// whole mechanism exists to avoid, so the OS's copy is dropped and
    /// `textRepeated` emits on schedule instead.
    ///
    /// The swallowed text isn't wasted: it refreshes what that key
    /// repeats, so a Shift pressed part-way through a hold switches the
    /// repeat from `a` to `A` once the OS's own repeat stream reports it.
    /// Text that can't be matched to a key being repeated here is left
    /// alone and delivered normally -- never drop input this can't
    /// reproduce itself.
    pub fn absorbRepeatedText(self: *Keyboard, utf8: []const u8) bool {
        if (!self.last_down_was_os_repeat) return false;
        const key = self.text_repeat_key orelse return false;
        if (self.last_down_key != key or !self.down(key)) return false;
        self.text_repeat_buf.clear();
        self.text_repeat_buf.appendSlice(utf8);
        return true;
    }

    /// The text to re-send this tick because the key that typed it is
    /// held and its repeat just fired, or an empty slice. The text half
    /// of `repeated`: a held printable key repeats through here, at the
    /// same cadence as a held arrow, rather than at whatever rate the
    /// desktop's own auto-repeat runs at.
    pub fn textRepeated(self: *const Keyboard) []const u8 {
        const key = self.text_repeat_key orelse return "";
        if (!self.repeated(key)) return "";
        return self.text_repeat_buf.slice();
    }

    /// Forgets what a held key was repeating.
    pub fn clearTextRepeat(self: *Keyboard) void {
        self.text_repeat_key = null;
        self.text_repeat_buf.clear();
    }

    /// Replaces the IME composition and its caret. See `pushText` for why
    /// this is public.
    pub fn setPreedit(self: *Keyboard, composing: []const u8, cursor: i32) void {
        self.preedit_buf.clear();
        self.preedit_buf.appendSlice(composing);
        self.preedit_cursor = cursor;
    }

    /// Ends any composition in flight.
    pub fn clearPreedit(self: *Keyboard) void {
        self.preedit_buf.clear();
        self.preedit_cursor = -1;
    }

    /// Ends the tick: this tick's press/release edges and typed text are
    /// dropped. The preedit deliberately survives -- it belongs to the
    /// IME's composition, not to one tick.
    pub fn finishTick(self: *Keyboard) void {
        self.pressed_bits = std.StaticBitSet(NumKeys).empty;
        self.released_bits = std.StaticBitSet(NumKeys).empty;
        self.text_buf.clear();
    }

    /// Drops every key, the modifier bits and any composition in flight.
    /// Called when the window loses focus: this state is event-driven, so
    /// a key held as focus leaves never sees its key-up and would stay
    /// down forever. Every key that was down reads as `released` on the
    /// next tick, so whoever was told about the press hears the release
    /// too -- glyphwire's session dedupes a press of a key it thinks is
    /// still down, so a missing release would eat that key's next press.
    pub fn clear(self: *Keyboard) void {
        self.released_bits.setUnion(self.curr);
        self.curr = std.StaticBitSet(NumKeys).empty;
        self.mods = 0;
        self.text_buf.clear();
        self.clearPreedit();
        self.repeat_bits = std.StaticBitSet(NumKeys).empty;
        self.repeat_suppressed = std.StaticBitSet(NumKeys).empty;
        self.pressed_at_ms = @splat(0);
        self.next_repeat_ms = @splat(0);
        self.clearTextRepeat();
        self.pending_press = null;
        self.last_down_key = null;
        self.last_down_was_os_repeat = false;
    }
};

pub const Mouse = struct {
    curr: std.StaticBitSet(NumMouseButtons) = std.StaticBitSet(NumMouseButtons).empty,
    prev: std.StaticBitSet(NumMouseButtons) = std.StaticBitSet(NumMouseButtons).empty,
    raw_pos_value: core.Vec2F = .{ .x = 0, .y = 0 },
    logical_pos: core.Vec2F = .{ .x = -1, .y = -1 },
    scroll_delta: core.Vec2F = .{ .x = 0, .y = 0 },

    pub fn set(self: *Mouse, button: MouseButton, down_value: bool) void {
        if (down_value) {
            self.curr.set(buttonIndex(button));
        } else {
            self.curr.unset(buttonIndex(button));
        }
    }

    pub fn down(self: *const Mouse, button: MouseButton) bool {
        return self.curr.isSet(buttonIndex(button));
    }

    pub fn pressed(self: *const Mouse, button: MouseButton) bool {
        const idx = buttonIndex(button);
        return self.curr.isSet(idx) and !self.prev.isSet(idx);
    }

    pub fn released(self: *const Mouse, button: MouseButton) bool {
        const idx = buttonIndex(button);
        return !self.curr.isSet(idx) and self.prev.isSet(idx);
    }

    pub fn rawPos(self: *const Mouse) core.Vec2F {
        return self.raw_pos_value;
    }

    pub fn pos(self: *const Mouse) core.Vec2F {
        return self.logical_pos;
    }

    pub fn scroll(self: *const Mouse) core.Vec2F {
        return self.scroll_delta;
    }

    pub fn finishTick(self: *Mouse) void {
        self.prev = self.curr;
        self.scroll_delta = .{ .x = 0, .y = 0 };
    }

    /// Drops every button and the pending scroll delta, for the same
    /// focus-loss reason as `Keyboard.clear`. The cursor position is left
    /// alone: it stays wherever the pointer last was, which is still true
    /// when focus comes back.
    pub fn clear(self: *Mouse) void {
        self.curr = std.StaticBitSet(NumMouseButtons).empty;
        self.prev = self.curr;
        self.scroll_delta = .{ .x = 0, .y = 0 };
    }
};

pub const InputManager = struct {
    mouse_enabled: bool,
    keyboard: Keyboard = .{},
    mouse: Mouse = .{},
    /// Log every raw SDL key event, mapped or not. Set at startup from
    /// `GLYPHWIRE_KEY_DEBUG` (see `host/main.zig`); off by default,
    /// because this is one log line per press *and* release.
    ///
    /// It exists because a key `mapKey` doesn't recognise is dropped in
    /// silence, which makes "this key does nothing" impossible to tell
    /// apart from "this key arrives and the binding is wrong" -- the
    /// question an Insert that works on an external keyboard but not on a
    /// laptop's Fn layer raises. The line carries the keycode, the
    /// scancode and both of SDL's names, so a keyboard whose Fn layer
    /// reports something unexpected shows exactly what it reports.
    key_debug: bool = false,

    /// `opts.numGamepads` is rejected at compile time by `Engine.init`
    /// rather than silently ignored here -- host_eng carries no gamepad
    /// support at all.
    pub fn init(opts: core.InputOptions) InputManager {
        return .{ .mouse_enabled = opts.mouse };
    }

    /// Seeds the cursor position from SDL rather than leaving it at
    /// (0, 0) until the pointer first moves. Without this a host that
    /// reads `mouse.pos()` before any motion event -- glyphwire's does,
    /// to decide hover -- sees the top-left cell as if the pointer were
    /// parked there. Called once from `Engine.init`.
    pub fn seedMousePos(self: *InputManager) void {
        if (!self.mouse_enabled) return;
        var x: f32 = 0;
        var y: f32 = 0;
        _ = sdl.SDL_GetMouseState(&x, &y);
        self.mouse.raw_pos_value = .{ .x = x, .y = y };
    }

    /// Drops all key and button state. `Engine.pollEvents` calls this on
    /// `SDL_EVENT_WINDOW_FOCUS_LOST`; see `Keyboard.clear`.
    pub fn clear(self: *InputManager) void {
        self.keyboard.clear();
        self.mouse.clear();
    }

    pub fn handleEvent(self: *InputManager, event: sdl.SDL_Event) void {
        switch (event.type) {
            sdl.SDL_EVENT_KEY_DOWN, sdl.SDL_EVENT_KEY_UP => {
                const key = mapKey(event.key.key);
                if (self.key_debug) logKeyEvent(event.key, key);
                // Stamped with the event's own time (SDL's tick counter,
                // in ns), not the tick that drains it -- see
                // `Keyboard.pressed_at_ms`.
                const at_ms = @as(f64, @floatFromInt(event.key.timestamp)) / 1_000_000.0;
                if (key != .unknown) self.keyboard.setAt(key, event.key.down, at_ms);
                self.keyboard.mods = event.key.mod;
                // The down/up bitset alone can't say which key typed the
                // text event that follows, nor whether this key-down was
                // the OS auto-repeating a held key -- both of which the
                // text-repeat path needs.
                if (key != .unknown) {
                    if (event.key.down) {
                        self.keyboard.noteKeyDown(key, event.key.repeat);
                    } else {
                        self.keyboard.noteKeyUp(key);
                    }
                }
            },
            sdl.SDL_EVENT_TEXT_INPUT => {
                const typed = std.mem.span(event.text.text);
                // An OS auto-repeat of a key already repeating on this
                // keyboard's own clock is swallowed (and used to refresh
                // what that repeat types); anything else is fresh input.
                if (!self.keyboard.absorbRepeatedText(typed)) {
                    self.keyboard.pushText(typed);
                    self.keyboard.noteCommittedText(typed);
                }
                // A commit ends the composition. SDL doesn't always follow
                // it with an empty editing event, so drop the preedit here
                // or the committed text would stay ghosted at the caret.
                self.keyboard.clearPreedit();
            },
            sdl.SDL_EVENT_TEXT_EDITING => {
                const composing = if (event.edit.text) |t| std.mem.span(t) else "";
                if (composing.len == 0) {
                    self.keyboard.clearPreedit();
                } else {
                    self.keyboard.setPreedit(composing, event.edit.start);
                }
            },
            sdl.SDL_EVENT_MOUSE_MOTION => {
                self.mouse.raw_pos_value = .{ .x = event.motion.x, .y = event.motion.y };
            },
            sdl.SDL_EVENT_MOUSE_BUTTON_DOWN, sdl.SDL_EVENT_MOUSE_BUTTON_UP => {
                self.mouse.raw_pos_value = .{ .x = event.button.x, .y = event.button.y };
                if (mapMouseButton(event.button.button)) |button| {
                    self.mouse.set(button, event.button.down);
                }
            },
            sdl.SDL_EVENT_MOUSE_WHEEL => {
                var dx = event.wheel.x;
                var dy = event.wheel.y;
                if (event.wheel.direction == sdl.SDL_MOUSEWHEEL_FLIPPED) {
                    dx = -dx;
                    dy = -dy;
                }
                self.mouse.scroll_delta.x += dx;
                self.mouse.scroll_delta.y += dy;
            },
            else => {},
        }
    }

    /// Per-tick input refresh, run before the app's own update: resolves
    /// the mouse position into logical space and moves the keyboard's
    /// typematic repeat clock to `now_ms` -- wall time, on the same base
    /// as an event's timestamp, and the same for every tick of one frame
    /// (see `Keyboard.tickRepeatsAt`). Repeats are ticked here, ahead of
    /// `app.update`, so `keyboard.repeated` answers for the same tick the
    /// app reads `pressed`/`released` on.
    pub fn update(
        self: *InputManager,
        window: *@import("platform_sdl.zig").Window,
        scale_factor: core.Vec2F,
        viewport: *const core.Viewport,
        now_ms: f64,
    ) void {
        _ = window;
        self.keyboard.tickRepeatsAt(now_ms);
        if (self.key_debug) logKeyTick(&self.keyboard);
        if (self.mouse_enabled) {
            const raw = self.mouse.rawPos();
            const fb = core.Vec2F{ .x = raw.x * scale_factor.x, .y = raw.y * scale_factor.y };
            self.mouse.logical_pos = viewport.framebufferToLogical(fb) orelse core.Vec2F{ .x = -1, .y = -1 };
        }
    }

    pub fn finishTick(self: *InputManager) void {
        self.keyboard.finishTick();
        self.mouse.finishTick();
    }
};

