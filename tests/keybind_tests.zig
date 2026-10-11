// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: GPL-3.0-or-later

const std = @import("std");
const testz = @import("testz");
const glyphwire = @import("glyphwire");

const keybind = @import("applib").keybind;
const Chord = keybind.Chord;

const TestAction = enum { up, parent, copy, quit };
const TestKeymap = keybind.Keymap(TestAction);

const test_defaults = [_]keybind.Default(TestAction){
    .{ .chord = "up", .action = .up },
    .{ .chord = "alt+up", .action = .parent },
    .{ .chord = "F5", .action = .copy },
    .{ .chord = "F10", .action = .quit },
    .{ .chord = "ctrl+q", .action = .quit },
};

// ─── Chord.parse ────────────────────────────────────────────────────────

pub fn chordParsesModifierAndKeyTest(_: std.Io, _: std.mem.Allocator) !void {
    const c = try Chord.parse("alt+up");
    try testz.expectEqualStr(c.key(), "up");
    try testz.expectTrue(c.mods.alt);
    try testz.expectFalse(c.mods.ctrl);
    try testz.expectFalse(c.mods.shift);
}

pub fn chordIsCaseInsensitiveAndMatchesHostSpellingTest(_: std.Io, _: std.mem.Allocator) !void {
    // The host sends function keys as `F5`; chords are stored lower-case.
    const c = try Chord.parse("Ctrl+Shift+F5");
    try testz.expectEqualStr(c.key(), "f5");
    try testz.expectTrue(c.matches("F5", .{ .ctrl = true, .shift = true }));
}

pub fn chordNeedsTheExactModifierSetTest(_: std.Io, _: std.mem.Allocator) !void {
    const c = try Chord.parse("F5");
    try testz.expectTrue(c.matches("F5", .{}));
    try testz.expectFalse(c.matches("F5", .{ .shift = true }));
    try testz.expectFalse(c.matches("F6", .{}));
}

pub fn chordNormalizesAliasesTest(_: std.Io, _: std.mem.Allocator) !void {
    try testz.expectEqualStr((try Chord.parse("pgdn")).key(), "page_down");
    try testz.expectEqualStr((try Chord.parse("esc")).key(), "escape");
    try testz.expectEqualStr((try Chord.parse("ctrl+1")).key(), "one");
    try testz.expectEqualStr((try Chord.parse("ins")).key(), "insert");
}

pub fn chordRejectsUnknownModifierAndEmptyKeyTest(_: std.Io, _: std.mem.Allocator) !void {
    try testz.expectError(Chord.parse("hyper+x"), error.UnknownModifier);
    try testz.expectError(Chord.parse(""), error.EmptyChord);
    try testz.expectError(Chord.parse("ctrl+"), error.EmptyChord);
}

pub fn chordFormatsForDisplayTest(_: std.Io, _: std.mem.Allocator) !void {
    var buf: [32]u8 = undefined;
    const c = try Chord.parse("alt+page_up");
    try testz.expectEqualStr(c.format(&buf), "Alt+Page up");
    const f = try Chord.parse("F5");
    try testz.expectEqualStr(f.format(&buf), "F5");
}

// ─── Keymap ─────────────────────────────────────────────────────────────

pub fn keymapLooksUpDefaultsTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var km = try TestKeymap.initDefaults(alloc, &test_defaults);
    defer km.deinit(alloc);
    try testz.expectEqual(km.lookup("up", .{}).?, TestAction.up);
    try testz.expectEqual(km.lookup("up", .{ .alt = true }).?, TestAction.parent);
    try testz.expectEqual(km.lookup("F5", .{}).?, TestAction.copy);
    try testz.expectTrue(km.lookup("down", .{}) == null);
}

pub fn keymapRebindReplacesTheChordsActionTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var km = try TestKeymap.initDefaults(alloc, &test_defaults);
    defer km.deinit(alloc);
    try km.bindNamed(alloc, "F5", "quit");
    try testz.expectEqual(km.lookup("F5", .{}).?, TestAction.quit);
    // Rebinding reused the slot rather than adding a shadowed second one.
    try testz.expectEqual(km.bindings.items.len, test_defaults.len);
}

pub fn keymapBindNamedRejectsUnknownActionTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var km = try TestKeymap.initDefaults(alloc, &test_defaults);
    defer km.deinit(alloc);
    try testz.expectError(km.bindNamed(alloc, "F6", "noSuchAction"), error.UnknownAction);
    try testz.expectTrue(km.lookup("F6", .{}) == null);
}

pub fn keymapUnbindDropsOnlyThatChordTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var km = try TestKeymap.initDefaults(alloc, &test_defaults);
    defer km.deinit(alloc);
    try km.unbindText("F10");
    try testz.expectTrue(km.lookup("F10", .{}) == null);
    try testz.expectEqual(km.lookup("q", .{ .ctrl = true }).?, TestAction.quit);
    try testz.expectEqualStr(km.chordFor(.quit).?.key(), "q");
}

// ─── Typed-character bindings ───────────────────────────────────────────

/// Punctuation, an uppercase letter or a non-ASCII character alone is
/// the character typed; a lowercase letter or digit alone is still a key.
pub fn chordParsesTypedCharactersTest(_: std.Io, _: std.mem.Allocator) !void {
    for ([_][]const u8{ "?", "%", "]", "\\", "H", "ä", "-", "+" }) |s| {
        const c = try Chord.parse(s);
        try testz.expectTrue(c.text);
        try testz.expectEqualStr(c.key(), s);
    }
    try testz.expectTrue(!(try Chord.parse("q")).text);
    try testz.expectEqualStr((try Chord.parse("1")).key(), "one");
    // With a modifier, punctuation is the key alias it always was.
    const slash = try Chord.parse("ctrl+/");
    try testz.expectTrue(!slash.text);
    try testz.expectEqualStr(slash.key(), "slash");
    // After a modifier `+` is still the separator.
    try testz.expectError(Chord.parse("ctrl++"), error.UnknownModifier);
}

pub fn keymapLookupTextMatchesTypedBindingsOnlyTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var km: TestKeymap = .{};
    defer km.deinit(alloc);
    try km.bind(alloc, try Chord.parse("?"), .up);
    try km.bind(alloc, try Chord.parse("H"), .parent);
    try km.bind(alloc, try Chord.parse("h"), .copy);
    try testz.expectEqual(km.lookupText("?").?, TestAction.up);
    try testz.expectEqual(km.lookupText("H").?, TestAction.parent);
    // Case matters for typed text; `h` is a key binding, not text.
    try testz.expectTrue(km.lookupText("h") == null);
    try testz.expectEqual(km.lookup("h", .{}).?, TestAction.copy);
    // A typed binding never answers a key press.
    try testz.expectTrue(km.lookup("?", .{}) == null);
    var buf: [16]u8 = undefined;
    try testz.expectEqualStr((try Chord.parse("%")).format(&buf), "%");
}

pub fn keymapApplyBindsAndUnbindsTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var km = try TestKeymap.initDefaults(alloc, &test_defaults);
    defer km.deinit(alloc);
    try km.apply(alloc, &.{
        .{ .chord = try Chord.parse("ctrl+up"), .action = .parent },
        .{ .chord = try Chord.parse("F10"), .action = null },
    });
    try testz.expectEqual(km.lookup("up", .{ .ctrl = true }).?, TestAction.parent);
    try testz.expectTrue(km.lookup("F10", .{}) == null);
}

// ─── Scoped keymaps ─────────────────────────────────────────────────────

const ScopedAction = enum { none, save, left, quit };
const TestScope = enum { global, normal, card };

fn testParent(s: TestScope) ?TestScope {
    return switch (s) {
        .global, .card => null,
        .normal => .global,
    };
}

const TestScoped = keybind.Scoped(TestScope, ScopedAction, testParent, .none);

const scoped_global = [_]keybind.Default(ScopedAction){
    .{ .chord = "ctrl+s", .action = .save },
    .{ .chord = "q", .action = .quit },
};
const scoped_normal = [_]keybind.Default(ScopedAction){
    .{ .chord = "h", .action = .left },
};

fn scopedDefaults() TestScoped.Defaults {
    return .init(.{ .global = &scoped_global, .normal = &scoped_normal, .card = &.{} });
}

/// A mode table falls back to its parent; one with no parent doesn't.
pub fn scopedLookupFallsBackToTheParentTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var km = try TestScoped.initDefaults(alloc, scopedDefaults());
    defer km.deinit(alloc);
    try testz.expectEqual(km.lookup(.normal, "h", .{}).?, ScopedAction.left);
    try testz.expectEqual(km.lookup(.normal, "s", .{ .ctrl = true }).?, ScopedAction.save);
    try testz.expectTrue(km.lookup(.global, "h", .{}) == null);
    try testz.expectTrue(km.lookup(.card, "q", .{}) == null);
}

/// `false` in a mode table binds `none`, hiding the parent's binding
/// there rather than falling through to it.
pub fn scopedFalseHidesTheParentBindingTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var km = try TestScoped.initDefaults(alloc, scopedDefaults());
    defer km.deinit(alloc);
    try km.apply(alloc, &.{
        .{ .scope = .normal, .chord = try Chord.parse("q"), .action = null },
        .{ .scope = .card, .chord = try Chord.parse("?"), .action = .quit },
    });
    try testz.expectEqual(km.lookup(.normal, "q", .{}).?, ScopedAction.none);
    try testz.expectEqual(km.lookup(.global, "q", .{}).?, ScopedAction.quit);
    try testz.expectEqual(km.lookupText(.card, "?").?, ScopedAction.quit);
}

/// `chordFor` labels an action with the chord that runs it in a mode:
/// a parent's binding counts, unless the mode table gave that chord to
/// something else.
pub fn scopedChordForSkipsAShadowedParentChordTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var km = try TestScoped.initDefaults(alloc, scopedDefaults());
    defer km.deinit(alloc);
    var buf: [32]u8 = undefined;
    try testz.expectEqualStr(km.chordFor(.normal, .save).?.format(&buf), "Ctrl+S");
    try testz.expectEqualStr(km.chordFor(.normal, .left).?.format(&buf), "H");
    try testz.expectTrue(km.chordFor(.global, .left) == null);

    // `q` hidden in normal mode, and quit given a chord of its own there.
    try km.apply(alloc, &.{
        .{ .scope = .normal, .chord = try Chord.parse("q"), .action = null },
        .{ .scope = .normal, .chord = try Chord.parse("ctrl+q"), .action = .quit },
    });
    try testz.expectEqualStr(km.chordFor(.normal, .quit).?.format(&buf), "Ctrl+Q");
    try testz.expectEqualStr(km.chordFor(.global, .quit).?.format(&buf), "Q");
    try km.apply(alloc, &.{.{ .scope = .normal, .chord = try Chord.parse("ctrl+q"), .action = null }});
    try testz.expectTrue(km.chordFor(.normal, .quit) == null);
}
