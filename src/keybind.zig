// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: MPL-2.0

//! Named actions bound to key chords -- the piece every full-screen
//! client ends up hand-rolling as a chain of `if (k.alt() and eq(key,
//! "left"))` tests. A client declares its actions as an enum, lists its
//! default chords as text (`"alt+up"`, `"ctrl+r"`, `"F5"`), and lets a
//! user's config rebind them by action *name*; the key handler then asks
//! the keymap which action a `KeyEvent` means and switches on that.
//!
//! Chord text is `mod+mod+key`, case-insensitive. Modifiers are `ctrl`
//! (`control`), `alt` (`meta`, `opt`), `shift` and `super` (`cmd`,
//! `win`). The key is a glyphwire key name -- the host's `Key` enum
//! spelled as its tag (`up`, `page_down`, `insert`, `F5`, `kp_add`) --
//! or one of the friendlier aliases `normalizeKey` accepts (`esc`,
//! `pgdn`, `del`, `1`, `-`, ...). A chord matches only when its modifier
//! set is exactly the event's, so `F5` and `shift+F5` are different
//! bindings.
//!
//! Nothing here knows about Lua or any one tool's config format: a tool
//! reads its own `keys = { ["alt+up"] = "upToParentDir" }` table and
//! hands each pair to `Keymap.bindNamed`.

const std = @import("std");
const core = @import("core.zig");

pub const Mods = core.Mods;

/// Longest key name a chord stores. The longest real one is
/// `grave_accent`/`print_screen`; this leaves room for a key glyphwire
/// grows later.
pub const max_key_len = 24;

pub const ParseError = error{
    EmptyChord,
    UnknownModifier,
    KeyNameTooLong,
};

pub const Chord = struct {
    key_buf: [max_key_len]u8 = undefined,
    key_len: u8 = 0,
    mods: Mods = .{},

    /// The chord's key name, lower-cased and normalized (`"page_up"`,
    /// `"f5"`).
    pub fn key(self: *const Chord) []const u8 {
        return self.key_buf[0..self.key_len];
    }

    /// Parses chord text such as `"ctrl+shift+F5"`. The last `+`-separated
    /// part is the key; every earlier part must be a modifier.
    pub fn parse(text: []const u8) ParseError!Chord {
        const trimmed = std.mem.trim(u8, text, " \t");
        if (trimmed.len == 0) return error.EmptyChord;

        var chord: Chord = .{};
        var key_part: []const u8 = trimmed;
        // A literal `+` key can't be written this way (`"ctrl++"` parses
        // as an empty key); spell it `kp_add` or `shift+equal`.
        if (std.mem.lastIndexOfScalar(u8, trimmed, '+')) |last| {
            key_part = trimmed[last + 1 ..];
            var mods_it = std.mem.splitScalar(u8, trimmed[0..last], '+');
            while (mods_it.next()) |raw| {
                const m = std.mem.trim(u8, raw, " \t");
                if (eqlAny(m, &.{ "ctrl", "control" })) {
                    chord.mods.ctrl = true;
                } else if (eqlAny(m, &.{ "alt", "meta", "opt", "option" })) {
                    chord.mods.alt = true;
                } else if (eqlAny(m, &.{"shift"})) {
                    chord.mods.shift = true;
                } else if (eqlAny(m, &.{ "super", "cmd", "win" })) {
                    chord.mods.super = true;
                } else {
                    return error.UnknownModifier;
                }
            }
        }
        key_part = std.mem.trim(u8, key_part, " \t");
        if (key_part.len == 0) return error.EmptyChord;

        var lower_buf: [max_key_len]u8 = undefined;
        if (key_part.len > lower_buf.len) return error.KeyNameTooLong;
        const lower = std.ascii.lowerString(&lower_buf, key_part);
        const name = normalizeKey(lower);
        if (name.len > max_key_len) return error.KeyNameTooLong;
        @memcpy(chord.key_buf[0..name.len], name);
        chord.key_len = @intCast(name.len);
        return chord;
    }

    /// True when a key event with this `key_name` and `mods` is this chord.
    /// `key_name` is compared case-insensitively, since the host spells
    /// function keys `F5` while chords are stored lower-case.
    pub fn matches(self: *const Chord, key_name: []const u8, mods: Mods) bool {
        return std.ascii.eqlIgnoreCase(self.key(), key_name) and std.meta.eql(self.mods, mods);
    }

    pub fn eql(self: *const Chord, other: *const Chord) bool {
        return std.mem.eql(u8, self.key(), other.key()) and std.meta.eql(self.mods, other.mods);
    }

    /// The chord as text, for a help line or a function-key bar:
    /// `"Alt+Up"`, `"Ctrl+R"`, `"F5"`. The key's first letter is
    /// upper-cased and `_` becomes a space; the result borrows `buf`.
    pub fn format(self: *const Chord, buf: []u8) []const u8 {
        var w: std.Io.Writer = .fixed(buf);
        if (self.mods.ctrl) w.writeAll("Ctrl+") catch return buf[0..w.end];
        if (self.mods.alt) w.writeAll("Alt+") catch return buf[0..w.end];
        if (self.mods.shift) w.writeAll("Shift+") catch return buf[0..w.end];
        if (self.mods.super) w.writeAll("Super+") catch return buf[0..w.end];
        for (self.key(), 0..) |c, i| {
            const out: u8 = if (c == '_') ' ' else if (i == 0) std.ascii.toUpper(c) else c;
            w.writeByte(out) catch break;
        }
        return buf[0..w.end];
    }
};

fn eqlAny(s: []const u8, options: []const []const u8) bool {
    for (options) |o| {
        if (std.ascii.eqlIgnoreCase(s, o)) return true;
    }
    return false;
}

/// Maps a lower-cased key alias onto the glyphwire key name the host
/// actually sends. Anything unlisted passes through, so a key the host
/// grows later needs no entry here.
pub fn normalizeKey(lower: []const u8) []const u8 {
    const aliases = [_]struct { from: []const u8, to: []const u8 }{
        .{ .from = "esc", .to = "escape" },
        .{ .from = "return", .to = "enter" },
        .{ .from = "cr", .to = "enter" },
        .{ .from = "del", .to = "delete" },
        .{ .from = "ins", .to = "insert" },
        .{ .from = "bs", .to = "backspace" },
        .{ .from = "pgup", .to = "page_up" },
        .{ .from = "pageup", .to = "page_up" },
        .{ .from = "pgdn", .to = "page_down" },
        .{ .from = "pgdown", .to = "page_down" },
        .{ .from = "pagedown", .to = "page_down" },
        .{ .from = " ", .to = "space" },
        .{ .from = "0", .to = "zero" },
        .{ .from = "1", .to = "one" },
        .{ .from = "2", .to = "two" },
        .{ .from = "3", .to = "three" },
        .{ .from = "4", .to = "four" },
        .{ .from = "5", .to = "five" },
        .{ .from = "6", .to = "six" },
        .{ .from = "7", .to = "seven" },
        .{ .from = "8", .to = "eight" },
        .{ .from = "9", .to = "nine" },
        .{ .from = "-", .to = "minus" },
        .{ .from = "=", .to = "equal" },
        .{ .from = ",", .to = "comma" },
        .{ .from = ".", .to = "period" },
        .{ .from = "/", .to = "slash" },
        .{ .from = "\\", .to = "backslash" },
        .{ .from = ";", .to = "semicolon" },
        .{ .from = "'", .to = "apostrophe" },
        .{ .from = "`", .to = "grave_accent" },
        .{ .from = "[", .to = "left_bracket" },
        .{ .from = "]", .to = "right_bracket" },
    };
    for (aliases) |a| {
        if (std.mem.eql(u8, lower, a.from)) return a.to;
    }
    return lower;
}

/// One default binding, as a tool lists them at comptime.
pub fn Default(comptime Action: type) type {
    return struct {
        chord: []const u8,
        action: Action,
    };
}

pub const BindError = ParseError || error{ UnknownAction, OutOfMemory };

/// Chord -> action lookup for one tool's `Action` enum. A chord maps to
/// at most one action (binding it again replaces the old one); an action
/// may have any number of chords.
pub fn Keymap(comptime Action: type) type {
    return struct {
        const Self = @This();

        pub const Binding = struct {
            chord: Chord,
            action: Action,
        };

        bindings: std.ArrayList(Binding) = .empty,

        pub fn deinit(self: *Self, alloc: std.mem.Allocator) void {
            self.bindings.deinit(alloc);
        }

        /// A keymap holding `defaults`. A default whose chord text doesn't
        /// parse is a programming error in the tool, so it panics in
        /// debug builds rather than silently dropping the binding.
        pub fn initDefaults(alloc: std.mem.Allocator, defaults: []const Default(Action)) !Self {
            var self: Self = .{};
            errdefer self.deinit(alloc);
            for (defaults) |d| {
                const chord = Chord.parse(d.chord) catch |err| std.debug.panic("bad default chord '{s}': {t}", .{ d.chord, err });
                try self.bind(alloc, chord, d.action);
            }
            return self;
        }

        pub fn bind(self: *Self, alloc: std.mem.Allocator, chord: Chord, action: Action) !void {
            for (self.bindings.items) |*b| {
                if (b.chord.eql(&chord)) {
                    b.action = action;
                    return;
                }
            }
            try self.bindings.append(alloc, .{ .chord = chord, .action = action });
        }

        /// Binds chord text to an action given by its enum tag name, the
        /// way a config file names it (`"upToParentDir"`).
        pub fn bindNamed(self: *Self, alloc: std.mem.Allocator, chord_text: []const u8, action_name: []const u8) BindError!void {
            const chord = try Chord.parse(chord_text);
            const action = std.meta.stringToEnum(Action, action_name) orelse return error.UnknownAction;
            try self.bind(alloc, chord, action);
        }

        /// Drops whatever `chord_text` was bound to. Unbinding a chord that
        /// wasn't bound is not an error.
        pub fn unbindText(self: *Self, chord_text: []const u8) ParseError!void {
            const chord = try Chord.parse(chord_text);
            self.unbind(chord);
        }

        pub fn unbind(self: *Self, chord: Chord) void {
            var i: usize = 0;
            while (i < self.bindings.items.len) {
                if (self.bindings.items[i].chord.eql(&chord)) {
                    _ = self.bindings.orderedRemove(i);
                } else i += 1;
            }
        }

        /// The action a key event means, if any.
        pub fn lookup(self: *const Self, key_name: []const u8, mods: Mods) ?Action {
            for (self.bindings.items) |*b| {
                if (b.chord.matches(key_name, mods)) return b.action;
            }
            return null;
        }

        /// The first chord bound to `action`, for labelling it on screen.
        pub fn chordFor(self: *const Self, action: Action) ?Chord {
            for (self.bindings.items) |b| {
                if (b.action == action) return b.chord;
            }
            return null;
        }
    };
}
