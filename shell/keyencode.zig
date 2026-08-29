//! Pure key-event -> byte encoders. `charFromKeyName` turns a wire key
//! name (`"a"`, `"three"`, `"slash"`, ...) plus shift into the character
//! the prompt's line editor inserts; `toPtyBytes` turns a key event into
//! the bytes a terminal would send down a pty's stdin for the
//! B0 "dumb PTY" fallback (`shell/pty.zig`). Both are `@import`-able from
//! `tests/shell_tests.zig` via the `shell_support` module -- no libc, no
//! IO.

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

/// The byte sequence a real terminal sends when `key` is pressed with
/// `mods` held, written into `buf` (needs 3 bytes; give it more for
/// headroom). Returns null for a key with nothing to send (a bare
/// modifier, an unhandled function key). Covers what a line-oriented
/// program or a pager reads: text, Enter (`CR`), Backspace (`DEL`), Tab,
/// the arrows and navigation keys as `CSI` sequences, `Ctrl`-letter as
/// the matching C0 control byte, and `Alt`-<key> as an `ESC` prefix.
/// Application-cursor-keys mode (`ESC O A`) and the kitty/modifyOtherKeys
/// protocols are out of scope for B0.
pub fn toPtyBytes(key: []const u8, mods: Mods, buf: []u8) ?[]const u8 {
    const eql = std.mem.eql;

    // Named keys that map to a fixed sequence regardless of shift.
    const Named = struct { name: []const u8, seq: []const u8 };
    const named = [_]Named{
        .{ .name = "enter", .seq = "\r" },
        .{ .name = "backspace", .seq = "\x7f" },
        .{ .name = "tab", .seq = "\t" },
        .{ .name = "escape", .seq = "\x1b" },
        .{ .name = "up", .seq = "\x1b[A" },
        .{ .name = "down", .seq = "\x1b[B" },
        .{ .name = "right", .seq = "\x1b[C" },
        .{ .name = "left", .seq = "\x1b[D" },
        .{ .name = "home", .seq = "\x1b[H" },
        .{ .name = "end", .seq = "\x1b[F" },
        .{ .name = "delete", .seq = "\x1b[3~" },
        .{ .name = "page_up", .seq = "\x1b[5~" },
        .{ .name = "page_down", .seq = "\x1b[6~" },
        .{ .name = "insert", .seq = "\x1b[2~" },
    };
    for (named) |n| {
        if (eql(u8, key, n.name)) {
            @memcpy(buf[0..n.seq.len], n.seq);
            return buf[0..n.seq.len];
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
