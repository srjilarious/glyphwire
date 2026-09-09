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

pub const Keyboard = struct {
    curr: std.StaticBitSet(NumKeys) = std.StaticBitSet(NumKeys).empty,
    prev: std.StaticBitSet(NumKeys) = std.StaticBitSet(NumKeys).empty,
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

    pub fn set(self: *Keyboard, key: Key, down_value: bool) void {
        if (down_value) {
            self.curr.set(keyIndex(key));
        } else {
            self.curr.unset(keyIndex(key));
        }
    }

    pub fn down(self: *const Keyboard, key: Key) bool {
        return self.curr.isSet(keyIndex(key));
    }

    pub fn pressed(self: *const Keyboard, key: Key) bool {
        const idx = keyIndex(key);
        return self.curr.isSet(idx) and !self.prev.isSet(idx);
    }

    pub fn released(self: *const Keyboard, key: Key) bool {
        const idx = keyIndex(key);
        return !self.curr.isSet(idx) and self.prev.isSet(idx);
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

    /// Ends the tick: the current key state becomes the previous state for
    /// next tick's edge detection, and this tick's typed text is dropped.
    /// The preedit deliberately survives -- it belongs to the IME's
    /// composition, not to one tick.
    pub fn finishTick(self: *Keyboard) void {
        self.prev = self.curr;
        self.text_buf.clear();
    }

    /// Drops every key, the modifier bits and any composition in flight.
    /// Called when the window loses focus: this state is event-driven, so
    /// a key held as focus leaves never sees its key-up and would stay
    /// down forever. `prev` is cleared alongside `curr` so the resync
    /// doesn't read as a `released` edge on the next tick.
    pub fn clear(self: *Keyboard) void {
        self.curr = std.StaticBitSet(NumKeys).empty;
        self.prev = self.curr;
        self.mods = 0;
        self.text_buf.clear();
        self.clearPreedit();
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
                if (key != .unknown) self.keyboard.set(key, event.key.down);
                self.keyboard.mods = event.key.mod;
            },
            sdl.SDL_EVENT_TEXT_INPUT => {
                self.keyboard.pushText(std.mem.span(event.text.text));
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

    pub fn update(
        self: *InputManager,
        window: *@import("platform_sdl.zig").Window,
        scale_factor: core.Vec2F,
        viewport: *const core.Viewport,
    ) void {
        _ = window;
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

