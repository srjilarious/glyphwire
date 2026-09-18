// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: GPL-3.0-or-later

const std = @import("std");
const testz = @import("testz");
const glyphwire = @import("glyphwire");

const keybind = glyphwire.keybind;
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
