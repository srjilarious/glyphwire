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

/// The byte sequence a real terminal sends when `key` is pressed with
/// `mods` held and cursor keys in `cursor_mode`, written into `buf`
/// (needs 3 bytes; give it more for headroom). Returns null for a key
/// with nothing to send (a bare modifier, an unhandled function key).
/// Covers what a line-oriented program or a pager reads: text, Enter
/// (`CR`), Backspace (`DEL`), Tab, the arrows and navigation keys as
/// `CSI` (or `SS3` in application-cursor mode) sequences, `Ctrl`-letter
/// as the matching C0 control byte, and `Alt`-<key> as an `ESC` prefix.
/// The kitty/modifyOtherKeys protocols are still out of scope for B0.
pub fn toPtyBytes(key: []const u8, mods: Mods, cursor_mode: CursorKeyMode, buf: []u8) ?[]const u8 {
    const eql = std.mem.eql;

    // Named keys that map to a fixed sequence regardless of shift. The
    // arrows and Home/End take an `ESC O x` form instead in
    // application-cursor mode; the `~`-terminated keys (Delete, PageUp,
    // ...) don't change.
    const Named = struct { name: []const u8, seq: []const u8, ss3: ?[]const u8 = null };
    const named = [_]Named{
        .{ .name = "enter", .seq = "\r" },
        .{ .name = "backspace", .seq = "\x7f" },
        .{ .name = "tab", .seq = "\t" },
        .{ .name = "escape", .seq = "\x1b" },
        .{ .name = "up", .seq = "\x1b[A", .ss3 = "\x1bOA" },
        .{ .name = "down", .seq = "\x1b[B", .ss3 = "\x1bOB" },
        .{ .name = "right", .seq = "\x1b[C", .ss3 = "\x1bOC" },
        .{ .name = "left", .seq = "\x1b[D", .ss3 = "\x1bOD" },
        .{ .name = "home", .seq = "\x1b[H", .ss3 = "\x1bOH" },
        .{ .name = "end", .seq = "\x1b[F", .ss3 = "\x1bOF" },
        .{ .name = "delete", .seq = "\x1b[3~" },
        .{ .name = "page_up", .seq = "\x1b[5~" },
        .{ .name = "page_down", .seq = "\x1b[6~" },
        .{ .name = "insert", .seq = "\x1b[2~" },
    };
    for (named) |n| {
        if (eql(u8, key, n.name)) {
            const seq = if (cursor_mode == .application) (n.ss3 orelse n.seq) else n.seq;
            @memcpy(buf[0..seq.len], seq);
            return buf[0..seq.len];
        }
    }

    const base = charFromKeyName(key, mods.shift) orelse return null;

    if (mods.ctrl) {
        // Ctrl-<letter> and a few Ctrl-<punct> map to a C0 control byte;
        // anything else with Ctrl held is swallowed (a real terminal
        // sends nothing).
        const lower = std.ascii.toLower(base);
        if (lower >= 'a' and lower <= 'z') {
            buf[0] = lower - 'a' + 1;
            return buf[0..1];
        }
        buf[0] = switch (base) {
            ' ', '@' => 0x00, // Ctrl-Space / Ctrl-@ = NUL
            '[' => 0x1b,
            '\\' => 0x1c,
            ']' => 0x1d,
            '^' => 0x1e,
            '_', '/' => 0x1f,
            else => return null,
        };
        return buf[0..1];
    }

    if (mods.alt) {
        buf[0] = 0x1b;
        buf[1] = base;
        return buf[0..2];
    }

    buf[0] = base;
    return buf[0..1];
}

// ─── Mouse reporting ────────────────────────────────────────────────────

/// `none` is "no button" -- used for a bare pointer-motion report under
/// `?1003` (xterm button code 3 + the motion bit).
pub const MouseButton = enum { left, middle, right, wheel_up, wheel_down, none };

/// Maps a wire mouse-button name (glyphwire-host sends the glfw
/// `MouseButton` enum field names) to a `MouseButton`, or null for one
/// with no xterm encoding (`four`..`eight`). Wheel "buttons" don't come
/// over `mouse_button`; the caller derives them from scroll events.
pub fn mouseButtonFromName(name: []const u8) ?MouseButton {
    if (std.mem.eql(u8, name, "left")) return .left;
    if (std.mem.eql(u8, name, "middle")) return .middle;
    if (std.mem.eql(u8, name, "right")) return .right;
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
