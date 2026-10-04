// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: MPL-2.0

//! Pure key/mouse-event -> byte encoders for the B0 "dumb PTY" fallback
//! (`pty.zig`). `charFromKeyName` turns a wire key name (`"a"`, `"three"`,
//! `"slash"`, ...) plus shift into the character the prompt's line editor
//! inserts; `toPtyBytes` turns a key event into the bytes a terminal
//! would send down a pty's stdin; `encodeMouse` turns a mouse event into
//! an xterm mouse report. All pure -- no libc, no IO -- so
//! `tests/shell_tests.zig` can `@import` them.
//!
//! Was `shell/keyencode.zig`; moved to `src/` alongside `pty.zig` and
//! re-exported from `glyphwire.zig` as `key_encode`.

const std = @import("std");

/// The character a printable key produces, honouring shift. Digit and
/// punctuation keys arrive by name (`"zero"`, `"slash"`); letter keys
/// arrive as the single lowercase byte. Returns null for any key that
/// isn't a plain printable (arrows, `"enter"`, `"f1"`, modifiers, ...).
pub fn charFromKeyName(key: []const u8, shift: bool) ?u8 {
    if (key.len == 1) {
        const ch = key[0];
        if (ch >= 'a' and ch <= 'z') return if (shift) ch - 32 else ch;
    }

    const Entry = struct { name: []const u8, plain: u8, shifted: u8 };
    const table = [_]Entry{
        .{ .name = "zero", .plain = '0', .shifted = ')' },
        .{ .name = "one", .plain = '1', .shifted = '!' },
        .{ .name = "two", .plain = '2', .shifted = '@' },
        .{ .name = "three", .plain = '3', .shifted = '#' },
        .{ .name = "four", .plain = '4', .shifted = '$' },
        .{ .name = "five", .plain = '5', .shifted = '%' },
        .{ .name = "six", .plain = '6', .shifted = '^' },
        .{ .name = "seven", .plain = '7', .shifted = '&' },
        .{ .name = "eight", .plain = '8', .shifted = '*' },
        .{ .name = "nine", .plain = '9', .shifted = '(' },
        .{ .name = "space", .plain = ' ', .shifted = ' ' },
        .{ .name = "apostrophe", .plain = '\'', .shifted = '"' },
        .{ .name = "comma", .plain = ',', .shifted = '<' },
        .{ .name = "minus", .plain = '-', .shifted = '_' },
        .{ .name = "period", .plain = '.', .shifted = '>' },
        .{ .name = "slash", .plain = '/', .shifted = '?' },
        .{ .name = "semicolon", .plain = ';', .shifted = ':' },
        .{ .name = "equal", .plain = '=', .shifted = '+' },
        .{ .name = "left_bracket", .plain = '[', .shifted = '{' },
        .{ .name = "backslash", .plain = '\\', .shifted = '|' },
        .{ .name = "right_bracket", .plain = ']', .shifted = '}' },
        .{ .name = "grave_accent", .plain = '`', .shifted = '~' },
    };
    for (table) |e| {
        if (std.mem.eql(u8, key, e.name)) return if (shift) e.shifted else e.plain;
    }
    return null;
}

pub const Mods = struct { ctrl: bool = false, shift: bool = false, alt: bool = false };

/// Cursor-key mode (DECCKM, `ESC [ ? 1 h`/`l`): in `.application` the
/// arrows and Home/End are sent as `ESC O x` (SS3) instead of `ESC [ x`.
/// Tracked from the child's own output by `pty.ModeTracker`.
pub const CursorKeyMode = enum { normal, application };

/// How the child asked for keys to be encoded. Both fields are tracked
/// from its own output by `pty.ModeTracker`.
pub const EncodeOpts = struct {
    cursor_mode: CursorKeyMode = .normal,
    /// The kitty keyboard protocol flags currently in effect
    /// (`KittyKeyboard.flags`). Only bit 0, "disambiguate escape codes",
    /// changes anything here -- it is the only one glyphwire supports.
    kitty_flags: u8 = 0,
};

/// The xterm modifier parameter: 1 + shift(1) + alt(2) + ctrl(4). The
/// same number the kitty keyboard protocol uses, so both encodings share
/// it. 1 means "no modifiers".
fn modParam(mods: Mods) u8 {
    return 1 + @as(u8, if (mods.shift) 1 else 0) + @as(u8, if (mods.alt) 2 else 0) + @as(u8, if (mods.ctrl) 4 else 0);
}

/// Same as `toPtyBytesOpts` with only a cursor-key mode -- the legacy
/// encoding, no kitty keyboard protocol.
pub fn toPtyBytes(key: []const u8, mods: Mods, cursor_mode: CursorKeyMode, buf: []u8) ?[]const u8 {
    return toPtyBytesOpts(key, mods, .{ .cursor_mode = cursor_mode }, buf);
}

/// The byte sequence a real terminal sends when `key` is pressed with
/// `mods` held, written into `buf` (32 bytes covers every case). Returns
/// null for a key with nothing to send (a bare modifier, an unhandled
/// key -- `F13` and up are still out of scope, as is the keypad).
///
/// The legacy encoding is xterm's: text as itself, Enter `CR`, Backspace
/// `DEL`, the arrows and navigation keys as `CSI` (or `SS3` in
/// application-cursor mode), `F1`-`F12` the classic VT220 mapping,
/// `Ctrl`-letter the matching C0 byte, `Alt`-<key> an `ESC` prefix. A
/// navigation or function key with a modifier held takes xterm's
/// `CSI 1 ; m X` / `CSI n ; m ~` form (`Ctrl+Left` is `CSI 1;5D`), which
/// is what vim, nvim and readline bind word motion to. `Shift+Tab` is
/// `CSI Z`, `Ctrl+Backspace` is `BS`.
///
/// With kitty flag 1 ("disambiguate", `EncodeOpts.kitty_flags`) the keys
/// that are ambiguous in the legacy encoding switch to `CSI code ; m u`:
/// `Escape` always, and any text key, Enter, Tab or Backspace with Ctrl
/// or Alt held -- and Enter/Tab/Backspace with Shift too, which is what
/// gives a program `Shift+Enter`. Unmodified Enter/Tab/Backspace and
/// plain or shifted text stay legacy, as the protocol requires, so a
/// shell is still usable if a program dies without popping its flags.
pub fn toPtyBytesOpts(key: []const u8, mods: Mods, opts: EncodeOpts, buf: []u8) ?[]const u8 {
    const eql = std.mem.eql;
    const kitty = opts.kitty_flags & KittyKeyboard.disambiguate != 0;
    const m = modParam(mods);

    // Enter / Tab / Backspace / Escape: the keys whose legacy byte is
    // also a control character, which is why they lose their modifiers
    // there and why the kitty protocol has codes for them.
    const Control = struct { name: []const u8, code: u8 };
    const controls = [_]Control{
        .{ .name = "enter", .code = '\r' },
        .{ .name = "tab", .code = '\t' },
        .{ .name = "backspace", .code = 0x7f },
        .{ .name = "escape", .code = 0x1b },
    };
    for (controls) |ctl| {
        if (!eql(u8, key, ctl.name)) continue;
        if (kitty and (m != 1 or ctl.code == 0x1b)) return csiU(ctl.code, m, buf);
        return legacyControl(ctl.code, mods, buf);
    }

    // Navigation and function keys. `seq` is the unmodified form (`ss3`
    // its application-cursor variant); a modifier switches to `CSI num ;
    // m final`. F3's modified form is `CSI 13 ; m ~` under the kitty
    // protocol, because xterm's `CSI 1 ; m R` collides with a cursor
    // position report.
    const Named = struct { name: []const u8, seq: []const u8, ss3: ?[]const u8 = null, num: u8, final: u8 };
    const named = [_]Named{
        .{ .name = "up", .seq = "\x1b[A", .ss3 = "\x1bOA", .num = 1, .final = 'A' },
        .{ .name = "down", .seq = "\x1b[B", .ss3 = "\x1bOB", .num = 1, .final = 'B' },
        .{ .name = "right", .seq = "\x1b[C", .ss3 = "\x1bOC", .num = 1, .final = 'C' },
        .{ .name = "left", .seq = "\x1b[D", .ss3 = "\x1bOD", .num = 1, .final = 'D' },
        .{ .name = "home", .seq = "\x1b[H", .ss3 = "\x1bOH", .num = 1, .final = 'H' },
        .{ .name = "end", .seq = "\x1b[F", .ss3 = "\x1bOF", .num = 1, .final = 'F' },
        .{ .name = "insert", .seq = "\x1b[2~", .num = 2, .final = '~' },
        .{ .name = "delete", .seq = "\x1b[3~", .num = 3, .final = '~' },
        .{ .name = "page_up", .seq = "\x1b[5~", .num = 5, .final = '~' },
        .{ .name = "page_down", .seq = "\x1b[6~", .num = 6, .final = '~' },
        // Function keys: the classic xterm/VT220 mapping every terminfo
        // entry's `kf1`..`kf12` expects. `F1`-`F4` are SS3 (unaffected by
        // cursor-key mode -- that only applies to the arrows/Home/End
        // above); `F5` and up are `CSI n ~`, skipping 16 and 22 for the
        // same historical VT220 reasons xterm does. Named in uppercase
        // (`"F1"`, not `"f1"`) to match the host's key names.
        .{ .name = "F1", .seq = "\x1bOP", .num = 1, .final = 'P' },
        .{ .name = "F2", .seq = "\x1bOQ", .num = 1, .final = 'Q' },
        .{ .name = "F3", .seq = "\x1bOR", .num = 1, .final = 'R' },
        .{ .name = "F4", .seq = "\x1bOS", .num = 1, .final = 'S' },
        .{ .name = "F5", .seq = "\x1b[15~", .num = 15, .final = '~' },
        .{ .name = "F6", .seq = "\x1b[17~", .num = 17, .final = '~' },
        .{ .name = "F7", .seq = "\x1b[18~", .num = 18, .final = '~' },
        .{ .name = "F8", .seq = "\x1b[19~", .num = 19, .final = '~' },
        .{ .name = "F9", .seq = "\x1b[20~", .num = 20, .final = '~' },
        .{ .name = "F10", .seq = "\x1b[21~", .num = 21, .final = '~' },
        .{ .name = "F11", .seq = "\x1b[23~", .num = 23, .final = '~' },
        .{ .name = "F12", .seq = "\x1b[24~", .num = 24, .final = '~' },
    };
    for (named) |n| {
        if (!eql(u8, key, n.name)) continue;
        if (m == 1) {
            const seq = if (opts.cursor_mode == .application) (n.ss3 orelse n.seq) else n.seq;
            @memcpy(buf[0..seq.len], seq);
            return buf[0..seq.len];
        }
        const num: u8, const final: u8 = if (kitty and n.final == 'R') .{ 13, '~' } else .{ n.num, n.final };
        return std.fmt.bufPrint(buf, "\x1b[{d};{d}{c}", .{ num, m, final }) catch null;
    }

    const base = charFromKeyName(key, mods.shift) orelse return null;

    // Kitty: a text key with Ctrl or Alt held is `CSI code ; m u`, the
    // code being the *unshifted* key (shift rides in `m`). Plain and
    // shifted text are left to the legacy path -- they arrive as `text`
    // events in practice anyway.
    if (kitty and (mods.ctrl or mods.alt)) {
        const unshifted = charFromKeyName(key, false) orelse base;
        return csiU(unshifted, m, buf);
    }

    var out: u8 = base;
    if (mods.ctrl) {
        // Ctrl-<letter> and a few Ctrl-<punct> map to a C0 control byte;
        // anything else with Ctrl held is swallowed (a real terminal
        // sends nothing).
        const lower = std.ascii.toLower(base);
        out = if (lower >= 'a' and lower <= 'z') lower - 'a' + 1 else switch (base) {
            ' ', '@' => 0x00, // Ctrl-Space / Ctrl-@ = NUL
            '[' => 0x1b,
            '\\' => 0x1c,
            ']' => 0x1d,
            '^' => 0x1e,
            '_', '/' => 0x1f,
            else => return null,
        };
    }
    // Alt prefixes ESC to whatever the rest of the chord made, so
    // Ctrl+Alt+x is `ESC ^X`.
    if (mods.alt) {
        buf[0] = 0x1b;
        buf[1] = out;
        return buf[0..2];
    }
    buf[0] = out;
    return buf[0..1];
}

/// `CSI code u`, or `CSI code ; m u` when a modifier is held.
fn csiU(code: u21, m: u8, buf: []u8) ?[]const u8 {
    if (m == 1) return std.fmt.bufPrint(buf, "\x1b[{d}u", .{code}) catch null;
    return std.fmt.bufPrint(buf, "\x1b[{d};{d}u", .{ code, m }) catch null;
}

/// The legacy bytes for Enter / Tab / Backspace / Escape (`code` is the
/// unmodified byte). The modifiers xterm can express here: Shift+Tab is
/// `CSI Z` (back-tab), Ctrl+Backspace is `BS`, and Alt prefixes `ESC`.
/// Anything else -- Shift+Enter, Ctrl+Tab -- has no legacy spelling and
/// sends the plain key.
fn legacyControl(code: u8, mods: Mods, buf: []u8) []const u8 {
    if (code == '\t' and mods.shift) {
        const seq = "\x1b[Z";
        @memcpy(buf[0..seq.len], seq);
        return buf[0..seq.len];
    }
    const byte: u8 = if (code == 0x7f and mods.ctrl) 0x08 else code;
    if (mods.alt) {
        buf[0] = 0x1b;
        buf[1] = byte;
        return buf[0..2];
    }
    buf[0] = byte;
    return buf[0..1];
}

// ─── Kitty keyboard protocol ────────────────────────────────────────────

/// The kitty keyboard protocol's per-screen flag stack
/// (https://sw.kovidgoyal.net/kitty/keyboard-protocol/), fed the
/// `CSI > f u` (push), `CSI < n u` (pop), `CSI = f ; mode u` (set) and
/// `CSI ? u` (query) sequences a program writes. Pure state, no IO: two
/// readers of the same pty stream each keep one -- `pty.ModeTracker`, to
/// encode keys, and `core.Layer`, to answer the query -- and they stay
/// in step because they see the same bytes.
///
/// Only flag 1 ("disambiguate escape codes") is supported, and the flags
/// are masked to it on the way in, so a query reports what glyphwire
/// will actually do rather than echoing what the program asked for --
/// the protocol's way for a program to discover a partial
/// implementation. The main and alternate screens keep separate stacks,
/// as the protocol requires; the alternate one starts empty each time
/// the screen is entered.
pub const KittyKeyboard = struct {
    /// Flag 1: report Escape, and keys with Ctrl/Alt (Shift too for
    /// Enter/Tab/Backspace), as `CSI u` sequences.
    pub const disambiguate: u8 = 0b1;
    pub const supported: u8 = disambiguate;
    /// Entries kept per screen. The protocol leaves the depth to the
    /// terminal; a push past it drops the oldest entry.
    pub const depth = 8;

    pub const Stack = struct {
        /// The flags in effect now.
        current: u8 = 0,
        /// Earlier `current` values, oldest first; a pop restores the
        /// last one.
        saved: [depth]u8 = @splat(0),
        len: usize = 0,

        fn push(self: *Stack, new_flags: u8) void {
            if (self.len == depth) {
                std.mem.copyForwards(u8, self.saved[0 .. depth - 1], self.saved[1..depth]);
                self.len -= 1;
            }
            self.saved[self.len] = self.current;
            self.len += 1;
            self.current = new_flags & supported;
        }

        /// Pops `n` entries; popping the stack empty resets the flags.
        fn pop(self: *Stack, n: usize) void {
            var i: usize = 0;
            while (i < n) : (i += 1) {
                if (self.len == 0) {
                    self.current = 0;
                    return;
                }
                self.len -= 1;
                self.current = self.saved[self.len];
            }
        }
    };

    main: Stack = .{},
    alt: Stack = .{},

    pub fn flags(self: *const KittyKeyboard, on_alt: bool) u8 {
        return if (on_alt) self.alt.current else self.main.current;
    }

    /// The alternate screen was just entered: its stack starts over.
    pub fn enterAlt(self: *KittyKeyboard) void {
        self.alt = .{};
    }

    /// Applies one `CSI <lead> <params> u` sequence (`lead` is `>`, `<`
    /// or `=`; `params` the bytes after it). Returns false for a lead
    /// that isn't one of the protocol's, so the caller can try its own
    /// meaning for the sequence (`CSI u` alone is DECRC in ANSI.SYS form).
    /// A query (`?`) changes nothing; the caller answers it with `flags`.
    pub fn apply(self: *KittyKeyboard, lead: u8, params: []const u8, on_alt: bool) bool {
        const stack = if (on_alt) &self.alt else &self.main;
        switch (lead) {
            '>' => stack.push(@truncate(param(params, 0, 0))),
            '<' => stack.pop(@max(param(params, 0, 1), 1)),
            '=' => {
                const f: u8 = @as(u8, @truncate(param(params, 0, 0))) & supported;
                switch (param(params, 1, 1)) {
                    1 => stack.current = f,
                    2 => stack.current |= f,
                    3 => stack.current &= ~f,
                    else => {},
                }
            },
            '?' => {},
            else => return false,
        }
        return true;
    }

    /// The `index`-th `;`-separated number in `params`, or `default_val`
    /// when it is missing, empty or not a number.
    fn param(params: []const u8, index: usize, default_val: usize) usize {
        var it = std.mem.splitScalar(u8, params, ';');
        var i: usize = 0;
        while (it.next()) |tok| : (i += 1) {
            if (i == index) return std.fmt.parseInt(usize, tok, 10) catch default_val;
        }
        return default_val;
    }
};

// ─── Mouse reporting ────────────────────────────────────────────────────

/// `none` is "no button" -- used for a bare pointer-motion report under
/// `?1003` (xterm button code 3 + the motion bit).
pub const MouseButton = enum { left, middle, right, wheel_up, wheel_down, none };

/// Maps a wire mouse-button name (glyphwire-host sends the glfw
/// `MouseButton` enum field names) to a `MouseButton`, or null for one
/// with no xterm encoding (`four`..`eight`). `wheel_up` / `wheel_down`
/// are what glyphwire-host sends, one press+release per notch, over a
/// layer whose program asked for the mouse (`core.Layer.mouse_report`).
pub fn mouseButtonFromName(name: []const u8) ?MouseButton {
    if (std.mem.eql(u8, name, "left")) return .left;
    if (std.mem.eql(u8, name, "middle")) return .middle;
    if (std.mem.eql(u8, name, "right")) return .right;
    if (std.mem.eql(u8, name, "wheel_up")) return .wheel_up;
    if (std.mem.eql(u8, name, "wheel_down")) return .wheel_down;
    return null;
}

pub const MouseAction = enum { press, release, motion };

/// `.legacy` = `ESC [ M` byte triples (X10/normal, `?1000`); `.sgr` =
/// `ESC [ < b ; x ; y M|m` (`?1006`), which the tracker prefers whenever
/// the child set it.
pub const MouseEncoding = enum { legacy, sgr };

/// Encodes one mouse event as an xterm report into `buf` (16 bytes is
/// plenty). `col`/`row` are 0-based cell coordinates; the report uses the
/// 1-based convention. Returns null only if `buf` is too small.
///
/// The low bits of the button byte: 0=left, 1=middle, 2=right, 3=legacy
/// release (SGR keeps the real button and flips the final byte to `m`
/// instead). +32 for a motion event, +64 for a wheel notch. Modifier
/// bits: +4 shift, +8 alt/meta, +16 ctrl.
pub fn encodeMouse(
    enc: MouseEncoding,
    button: MouseButton,
    action: MouseAction,
    col: usize,
    row: usize,
    mods: Mods,
    buf: []u8,
) ?[]const u8 {
    const base: u32 = switch (button) {
        .left => 0,
        .middle => 1,
        .right => 2,
        .wheel_up => 64,
        .wheel_down => 65,
        .none => 3,
    };
    const mod_bits: u32 = (if (mods.shift) @as(u32, 4) else 0) +
        (if (mods.alt) @as(u32, 8) else 0) +
        (if (mods.ctrl) @as(u32, 16) else 0);
    const motion_bit: u32 = if (action == .motion) 32 else 0;

    switch (enc) {
        .sgr => {
            const cb = base + mod_bits + motion_bit;
            const final: u8 = if (action == .release) 'm' else 'M';
            const out = std.fmt.bufPrint(buf, "\x1b[<{d};{d};{d}{c}", .{
                cb, col + 1, row + 1, final,
            }) catch return null;
            return out;
        },
        .legacy => {
            // Release doesn't name a button in the legacy encoding: low
            // bits are 3, modifier bits still ride along.
            const cb = (if (action == .release) @as(u32, 3) else base) + mod_bits + motion_bit;
            if (buf.len < 6) return null;
            // 1-based, offset by 32, clamped to the single-byte ceiling
            // (255 -> column/row 223).
            const cx: u32 = @min(col + 1, 223) + 32;
            const cy: u32 = @min(row + 1, 223) + 32;
            buf[0] = 0x1b;
            buf[1] = '[';
            buf[2] = 'M';
            buf[3] = @intCast(@min(cb, 223) + 32);
            buf[4] = @intCast(cx);
            buf[5] = @intCast(cy);
            return buf[0..6];
        },
    }
}
