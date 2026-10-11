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
//! A binding can instead name a typed character: with no modifier, one
//! punctuation character (`"?"`, `"%"`, `"]"`), one uppercase letter
//! (`"H"`) or one non-ASCII character is that character as the keyboard
//! layout produces it, matched against `text` events (`lookupText`)
//! rather than key presses. That is what keeps `?` meaning "help" on a
//! layout where it isn't Shift+slash. A lowercase letter or a digit alone
//! is still a key (`"q"`, `"1"` = `one`).
//!
//! Nothing here knows about Lua or any one tool's config format: a tool
//! reads its own `keys = { ["alt+up"] = "upToParentDir" }` table
//! (`luaconf.keys` / `luaconf.scopedKeys`) and applies it.

const std = @import("std");
const glyphwire = @import("glyphwire");

pub const Mods = glyphwire.Mods;

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
    /// A typed character rather than a key: `key()` is the character
    /// itself, case and all, and `mods` is empty. See the module doc.
    text: bool = false,

    /// The chord's key name, lower-cased and normalized (`"page_up"`,
    /// `"f5"`), or for a `text` chord the character (`"?"`, `"H"`).
    pub fn key(self: *const Chord) []const u8 {
        return self.key_buf[0..self.key_len];
    }

    /// Parses chord text such as `"ctrl+shift+F5"`. The last `+`-separated
    /// part is the key; every earlier part must be a modifier. A lone
    /// typed-character spelling (`"?"`, `"H"`) is a `text` chord.
    pub fn parse(text: []const u8) ParseError!Chord {
        const trimmed = std.mem.trim(u8, text, " \t");
        if (trimmed.len == 0) return error.EmptyChord;
        if (isTypedChar(trimmed)) {
            var typed: Chord = .{ .text = true };
            @memcpy(typed.key_buf[0..trimmed.len], trimmed);
            typed.key_len = @intCast(trimmed.len);
            return typed;
        }

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
        return !self.text and std.ascii.eqlIgnoreCase(self.key(), key_name) and std.meta.eql(self.mods, mods);
    }

    /// True when a `text` event of exactly `typed` is this chord.
    pub fn matchesText(self: *const Chord, typed: []const u8) bool {
        return self.text and std.mem.eql(u8, self.key(), typed);
    }

    pub fn eql(self: *const Chord, other: *const Chord) bool {
        return self.text == other.text and std.mem.eql(u8, self.key(), other.key()) and std.meta.eql(self.mods, other.mods);
    }

    /// The chord as text, for a help line or a function-key bar:
    /// `"Alt+Up"`, `"Ctrl+R"`, `"F5"`. The key's first letter is
    /// upper-cased and `_` becomes a space; the result borrows `buf`.
    pub fn format(self: *const Chord, buf: []u8) []const u8 {
        var w: std.Io.Writer = .fixed(buf);
        if (self.text) {
            w.writeAll(self.key()) catch {};
            return buf[0..w.end];
        }
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

/// Whether `s` alone spells a typed character rather than a key: one
/// codepoint that is ASCII punctuation, an uppercase letter, or anything
/// non-ASCII. `+` counts when it is the whole string; after a modifier
/// it is still the separator (`ctrl++` doesn't parse).
fn isTypedChar(s: []const u8) bool {
    const len = std.unicode.utf8ByteSequenceLength(s[0]) catch return false;
    if (len != s.len or len > max_key_len) return false;
    if (len > 1) return std.unicode.utf8ValidateSlice(s);
    const c = s[0];
    return std.ascii.isUpper(c) or (std.ascii.isPrint(c) and !std.ascii.isAlphanumeric(c) and c != ' ');
}

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

        /// The action a `text` event means, if any: a typed-character
        /// binding (`"?"`) of exactly `typed`.
        pub fn lookupText(self: *const Self, typed: []const u8) ?Action {
            for (self.bindings.items) |*b| {
                if (b.chord.matchesText(typed)) return b.action;
            }
            return null;
        }

        /// A config's `keys` over the defaults, in order: an override with
        /// an action binds its chord, one without (`false`) unbinds it.
        pub fn apply(self: *Self, alloc: std.mem.Allocator, overrides: []const Override(Action)) !void {
            for (overrides) |o| {
                if (o.action) |a| try self.bind(alloc, o.chord, a) else self.unbind(o.chord);
            }
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

/// One entry of a config's `keys` table, already parsed: the chord and
/// the action it names, or null for `false`.
pub fn Override(comptime Action: type) type {
    return struct {
        chord: Chord,
        action: ?Action,
    };
}

/// `Override` for a `Scoped` keymap: which table the entry is in.
pub fn ScopedOverride(comptime Scope: type, comptime Action: type) type {
    return struct {
        scope: Scope,
        chord: Chord,
        action: ?Action,
    };
}

/// One `Keymap` per mode (`Scope`), looked up most specific first: a
/// key unbound in a mode's own table falls back to `parent(scope)`'s,
/// and so on up. That fallback chain is the whole of a tool's modal
/// precedence, written down in one place rather than implied by the order
/// of an if-chain. zoe's `global` / `normal` / `visual` / `insert`, and
/// gw-read's page / card / AI-panel modes, are both one.
///
/// `none` is the tool's do-nothing action: `false` in a config binds it,
/// so a mode can hide a parent's chord rather than fall through to it.
pub fn Scoped(
    comptime Scope: type,
    comptime Action: type,
    comptime parent: fn (Scope) ?Scope,
    comptime none: Action,
) type {
    return struct {
        const Self = @This();
        pub const Table = Keymap(Action);
        pub const Defaults = std.EnumArray(Scope, []const Default(Action));

        tables: std.EnumArray(Scope, Table) = .initFill(.{}),

        pub fn initDefaults(alloc: std.mem.Allocator, defaults: Defaults) !Self {
            var self: Self = .{};
            errdefer self.deinit(alloc);
            for (std.enums.values(Scope)) |s| {
                self.tables.set(s, try Table.initDefaults(alloc, defaults.get(s)));
            }
            return self;
        }

        pub fn deinit(self: *Self, alloc: std.mem.Allocator) void {
            for (std.enums.values(Scope)) |s| self.tables.getPtr(s).deinit(alloc);
        }

        pub fn table(self: *Self, scope: Scope) *Table {
            return self.tables.getPtr(scope);
        }

        /// The config's `keys`, over the defaults, in order.
        pub fn apply(self: *Self, alloc: std.mem.Allocator, overrides: []const ScopedOverride(Scope, Action)) !void {
            for (overrides) |o| try self.table(o.scope).bind(alloc, o.chord, o.action orelse none);
        }

        /// The action a key means in `scope`: its own table's binding,
        /// else the nearest parent's. Null when none binds it.
        pub fn lookup(self: *const Self, scope: Scope, key_name: []const u8, mods: Mods) ?Action {
            var s: ?Scope = scope;
            while (s) |cur| : (s = parent(cur)) {
                if (self.tables.getPtrConst(cur).lookup(key_name, mods)) |a| return a;
            }
            return null;
        }

        /// `lookup` for a `text` event.
        pub fn lookupText(self: *const Self, scope: Scope, typed: []const u8) ?Action {
            var s: ?Scope = scope;
            while (s) |cur| : (s = parent(cur)) {
                if (self.tables.getPtrConst(cur).lookupText(typed)) |a| return a;
            }
            return null;
        }

        /// The chord that runs `action` in `scope`, for labelling it: the
        /// first one bound to it along the parent chain that a lookup in
        /// `scope` still resolves to it. A parent's chord the mode table
        /// rebinds to something else doesn't count.
        pub fn chordFor(self: *const Self, scope: Scope, action: Action) ?Chord {
            var s: ?Scope = scope;
            while (s) |cur| : (s = parent(cur)) {
                for (self.tables.getPtrConst(cur).bindings.items) |*b| {
                    if (b.action != action) continue;
                    const resolved = if (b.chord.text)
                        self.lookupText(scope, b.chord.key())
                    else
                        self.lookup(scope, b.chord.key(), b.chord.mods);
                    if (resolved == action) return b.chord;
                }
            }
            return null;
        }
    };
}
