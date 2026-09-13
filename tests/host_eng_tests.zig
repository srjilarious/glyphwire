// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: GPL-3.0-or-later

const std = @import("std");
const testz = @import("testz");

// The SDL3 engine backend's input layer. `Keyboard` / `Mouse` are plain
// state machines fed by `InputManager.handleEvent`, so everything below
// runs without a window, a GL context or an SDL event queue.
const host_eng = @import("host_eng");
const Key = host_eng.input.Key;
const MouseButton = host_eng.input.MouseButton;

// ─── wire-visible enum names ──────────────────────────────────────────

pub fn keyNamesAreWireStableTest(_: std.Io, _: std.mem.Allocator) !void {
    // `host/input.zig` forwards each key by `@tagName`, and
    // `src/key_encode.zig` matches on those strings, so a rename here is
    // a silent protocol change. These are the spellings that have to hold.
    try testz.expectEqualStr(@tagName(Key.escape), "escape");
    try testz.expectEqualStr(@tagName(Key.enter), "enter");
    try testz.expectEqualStr(@tagName(Key.backspace), "backspace");
    try testz.expectEqualStr(@tagName(Key.left_control), "left_control");
    try testz.expectEqualStr(@tagName(Key.page_up), "page_up");
    try testz.expectEqualStr(@tagName(Key.grave_accent), "grave_accent");
    try testz.expectEqualStr(@tagName(Key.kp_subtract), "kp_subtract");
    // Uppercase, matching key_encode's F1..F12 entries.
    try testz.expectEqualStr(@tagName(Key.F1), "F1");
    try testz.expectEqualStr(@tagName(Key.F12), "F12");
}

pub fn keyEnumHasNoPhantomKeysTest(_: std.Io, _: std.mem.Allocator) !void {
    // F25 and world_1/world_2 came from the old GLFW backend's enum; no
    // SDL keycode maps to any of them, so declaring them only invites an
    // invented mapping like the `SDLK_EXECUTE => .F25` this replaced.
    inline for (@typeInfo(Key).@"enum".field_names) |field_name| {
        try testz.expectNotEqualStr(field_name, "F25");
        try testz.expectNotEqualStr(field_name, "world_1");
        try testz.expectNotEqualStr(field_name, "world_2");
    }
    // F24 is the last real one, and `unknown` must stay index 0 so the
    // bitsets can be indexed by `@intFromEnum` directly.
    try testz.expectEqual(@intFromEnum(Key.unknown), 0);
}

pub fn mouseButtonNamesAreWireStableTest(_: std.Io, _: std.mem.Allocator) !void {
    // `host/input.zig` forwards every field of this enum by name too.
    const fields = @typeInfo(MouseButton).@"enum".field_names;
    try testz.expectEqual(fields.len, 5);
    try testz.expectEqualStr(@tagName(MouseButton.left), "left");
    try testz.expectEqualStr(@tagName(MouseButton.right), "right");
    try testz.expectEqualStr(@tagName(MouseButton.middle), "middle");
    try testz.expectEqualStr(@tagName(MouseButton.x1), "x1");
    try testz.expectEqualStr(@tagName(MouseButton.x2), "x2");
}

// ─── focus-loss resync ────────────────────────────────────────────────

pub fn keyboardClearDropsHeldKeysTest(_: std.Io, _: std.mem.Allocator) !void {
    var kb = host_eng.input.Keyboard{};
    kb.set(.a, true);
    kb.set(.left_shift, true);
    try testz.expectTrue(kb.down(.a));

    kb.clear();
    try testz.expectFalse(kb.down(.a));
    try testz.expectFalse(kb.down(.left_shift));
    try testz.expectFalse(kb.shift());
}

pub fn keyboardClearLeavesNoReleaseEdgeTest(_: std.Io, _: std.mem.Allocator) !void {
    // The resync clears `prev` alongside `curr`. If it only cleared
    // `curr`, the tick after focus loss would report a `released` edge for
    // every key that had been held, and `host/input.zig` would forward a
    // key-up the shell never saw a key-down for.
    var kb = host_eng.input.Keyboard{};
    kb.set(.a, true);
    kb.finishTick(); // `a` is now down in both curr and prev

    kb.clear();
    try testz.expectFalse(kb.released(.a));
    try testz.expectFalse(kb.pressed(.a));
}

pub fn keyboardClearDropsCompositionTest(_: std.Io, _: std.mem.Allocator) !void {
    // A composition in flight when focus leaves has no way to finish: the
    // IME's commit lands in whatever window took focus. Dropping it here
    // is what stops it being drawn at the caret forever.
    var kb = host_eng.input.Keyboard{};
    kb.setPreedit("にほんご", 2);
    try testz.expectEqual(kb.preedit().len, 12);

    kb.clear();
    try testz.expectEqual(kb.preedit().len, 0);
    try testz.expectTrue(kb.preeditCursorByte() == null);
}

pub fn mouseClearDropsButtonsAndScrollTest(_: std.Io, _: std.mem.Allocator) !void {
    var mouse = host_eng.input.Mouse{};
    mouse.set(.left, true);
    mouse.scroll_delta = .{ .x = 0, .y = 3 };
    mouse.raw_pos_value = .{ .x = 120, .y = 40 };

    mouse.clear();
    try testz.expectFalse(mouse.down(.left));
    try testz.expectFalse(mouse.released(.left));
    try testz.expectEqual(mouse.scroll().y, 0);
    // The cursor position deliberately survives: it is still where the
    // pointer was, and will be again when focus comes back.
    try testz.expectEqual(mouse.rawPos().x, 120);
}

// ─── IME composition ──────────────────────────────────────────────────

pub fn preeditCursorByteConvertsCodepointsTest(_: std.Io, _: std.mem.Allocator) !void {
    // SDL reports the composition caret as a codepoint index; callers
    // slice the text with it, so it has to come back as a byte offset.
    // Each of these kana is 3 UTF-8 bytes.
    var kb = host_eng.input.Keyboard{};
    kb.setPreedit("にほんご", 2);
    try testz.expectEqual(kb.preeditCursorByte().?, 6);

    kb.setPreedit("にほんご", 0);
    try testz.expectEqual(kb.preeditCursorByte().?, 0);
}

pub fn preeditCursorByteClampsPastEndTest(_: std.Io, _: std.mem.Allocator) !void {
    // An IME that reports a caret past the composition it sent must not
    // produce an out-of-range slice index.
    var kb = host_eng.input.Keyboard{};
    kb.setPreedit("にほ", 9);
    try testz.expectEqual(kb.preeditCursorByte().?, 6);
}

pub fn preeditAbsentWhenNotComposingTest(_: std.Io, _: std.mem.Allocator) !void {
    var kb = host_eng.input.Keyboard{};
    try testz.expectEqual(kb.preedit().len, 0);
    try testz.expectTrue(kb.preeditCursorByte() == null);
}

// ─── typed text ───────────────────────────────────────────────────────

pub fn textSurvivesRepeatedReadsTest(_: std.Io, _: std.mem.Allocator) !void {
    // `text()` is non-destructive within a tick -- `host/input.zig` reads
    // it once, but `finishTick` is what actually drops it.
    var kb = host_eng.input.Keyboard{};
    kb.pushText("hi");

    var buf: [16]u8 = undefined;
    try testz.expectEqualStr(buf[0..kb.text(&buf)], "hi");
    try testz.expectEqualStr(buf[0..kb.text(&buf)], "hi");

    kb.finishTick();
    try testz.expectEqual(kb.text(&buf), 0);
}

pub fn textCutsOnUtf8BoundaryTest(_: std.Io, _: std.mem.Allocator) !void {
    // "にほんご" is 4 x 3 bytes. Into a 7-byte buffer that is two whole
    // kana plus one byte, and the odd byte has to be dropped rather than
    // handed over as half a codepoint.
    var kb = host_eng.input.Keyboard{};
    kb.pushText("にほんご");

    var buf: [7]u8 = undefined;
    const n = kb.text(&buf);
    try testz.expectEqual(n, 6);
    try testz.expectTrue(std.unicode.utf8ValidateSlice(buf[0..n]));
}

// ─── modifiers ────────────────────────────────────────────────────────

pub fn modifiersFollowPhysicalKeysTest(_: std.Io, _: std.mem.Allocator) !void {
    // With no SDL modifier bits seen, the physical keys still answer --
    // this is the path a synthesized/injected key event takes.
    var kb = host_eng.input.Keyboard{};
    try testz.expectFalse(kb.ctrl());

    kb.set(.right_control, true);
    try testz.expectTrue(kb.ctrl());

    kb.set(.right_control, false);
    try testz.expectFalse(kb.ctrl());
}

// ─── typematic repeat ─────────────────────────────────────────────────

/// One tick of the engine loop's key handling: the press/hold state is
/// already in `curr`, `tickRepeats` republishes this tick's repeat bits,
/// then `finishTick` rolls `curr` into `prev` for the next tick's edge
/// comparison.
fn repeatTick(kb: *host_eng.input.Keyboard, delta_ms: f64) void {
    kb.tickRepeats(delta_ms);
    kb.finishTick();
}

pub fn keyRepeatWaitsOutInitialDelayTest(_: std.Io, _: std.mem.Allocator) !void {
    var kb = host_eng.input.Keyboard{};
    kb.repeat = .{ .delay_ms = 100, .interval_ms = 20 };

    // The press edge is `pressed`'s to report, never a repeat.
    kb.set(.page_down, true);
    kb.tickRepeats(16);
    try testz.expectFalse(kb.repeated(.page_down));
    kb.finishTick();

    // Still inside the initial hold.
    repeatTick(&kb, 80);
    try testz.expectFalse(kb.repeated(.page_down));

    // Crossing the delay fires the first repeat, then one per interval.
    kb.tickRepeats(20);
    try testz.expectTrue(kb.repeated(.page_down));
    kb.finishTick();
    repeatTick(&kb, 10);
    try testz.expectFalse(kb.repeated(.page_down));
    kb.tickRepeats(10);
    try testz.expectTrue(kb.repeated(.page_down));
}

pub fn keyRepeatEqualDelayAndIntervalHasNoHoldTest(_: std.Io, _: std.mem.Allocator) !void {
    // zoe's setting: `delay_ms == interval_ms`, so the first repeat lands
    // one interval after the press rather than after a longer hold.
    var kb = host_eng.input.Keyboard{};
    kb.repeat = .{ .delay_ms = 30, .interval_ms = 30 };

    kb.set(.down, true);
    repeatTick(&kb, 16);
    kb.tickRepeats(30);
    try testz.expectTrue(kb.repeated(.down));
}

pub fn keyRepeatReleaseResetsHoldTest(_: std.Io, _: std.mem.Allocator) !void {
    var kb = host_eng.input.Keyboard{};
    kb.repeat = .{ .delay_ms = 100, .interval_ms = 20 };

    kb.set(.left, true);
    repeatTick(&kb, 16);
    repeatTick(&kb, 200); // repeating by now
    kb.set(.left, false);
    repeatTick(&kb, 16);

    // A fresh press waits out the whole initial delay again rather than
    // picking up where the last hold left off.
    kb.set(.left, true);
    repeatTick(&kb, 16);
    kb.tickRepeats(90);
    try testz.expectFalse(kb.repeated(.left));
}

pub fn keyRepeatDisabledNeverFiresTest(_: std.Io, _: std.mem.Allocator) !void {
    var kb = host_eng.input.Keyboard{};
    kb.repeat = .{ .delay_ms = 10, .interval_ms = 10, .enabled = false };

    kb.set(.backspace, true);
    repeatTick(&kb, 16);
    kb.tickRepeats(1000);
    try testz.expectFalse(kb.repeated(.backspace));
}

pub fn keyRepeatDueMsTracksTheScheduleTest(_: std.Io, _: std.mem.Allocator) !void {
    // What an idle-blocking event loop waits on: how long it may sleep
    // before this key's next repeat comes due.
    var kb = host_eng.input.Keyboard{};
    kb.repeat = .{ .delay_ms = 100, .interval_ms = 20 };

    // Nothing held: nothing to wake for.
    try testz.expectEqual(kb.repeatDueMs(.down), null);

    kb.set(.down, true);
    repeatTick(&kb, 16); // the press tick starts the schedule
    try testz.expectEqual(kb.repeatDueMs(.down).?, 100.0);

    repeatTick(&kb, 60);
    try testz.expectEqual(kb.repeatDueMs(.down).?, 40.0);

    // After the first repeat the deadline is one interval out.
    repeatTick(&kb, 40);
    try testz.expectEqual(kb.repeatDueMs(.down).?, 20.0);

    kb.set(.down, false);
    repeatTick(&kb, 16);
    try testz.expectEqual(kb.repeatDueMs(.down), null);
}

pub fn keyRepeatDueMsIsNullWhenDisabledTest(_: std.Io, _: std.mem.Allocator) !void {
    // Repeats off: the loop has no repeat deadline to wake for at all.
    var kb = host_eng.input.Keyboard{};
    kb.repeat = .{ .delay_ms = 10, .interval_ms = 10, .enabled = false };
    kb.set(.down, true);
    repeatTick(&kb, 16);
    try testz.expectEqual(kb.repeatDueMs(.down), null);
}

// ─── text repeat ──────────────────────────────────────────────────────

/// A freshly typed character as the event stream delivers it: the key
/// goes down, then the text it committed arrives.
fn typeKey(kb: *host_eng.input.Keyboard, key: host_eng.input.Key, text: []const u8) void {
    kb.set(key, true);
    kb.noteKeyDown(key, false);
    kb.pushText(text);
    kb.noteCommittedText(text);
}

pub fn textRepeatFollowsTheSameClockTest(_: std.Io, _: std.mem.Allocator) !void {
    // A held printable key repeats its text on this clock, not the
    // desktop's -- the whole point of the unification.
    var kb = host_eng.input.Keyboard{};
    kb.repeat = .{ .delay_ms = 100, .interval_ms = 20 };

    typeKey(&kb, .j, "j");
    // The press tick itself types once and repeats nothing.
    try testz.expectEqualStr(kb.textRepeated(), "");
    repeatTick(&kb, 16);

    repeatTick(&kb, 80);
    try testz.expectEqualStr(kb.textRepeated(), "");

    kb.tickRepeats(20);
    try testz.expectEqualStr(kb.textRepeated(), "j");
}

pub fn textRepeatStopsOnReleaseTest(_: std.Io, _: std.mem.Allocator) !void {
    var kb = host_eng.input.Keyboard{};
    kb.repeat = .{ .delay_ms = 10, .interval_ms = 10 };

    typeKey(&kb, .j, "j");
    repeatTick(&kb, 16);
    kb.tickRepeats(20);
    try testz.expectEqualStr(kb.textRepeated(), "j");

    kb.set(.j, false);
    kb.noteKeyUp(.j);
    kb.tickRepeats(20);
    try testz.expectEqualStr(kb.textRepeated(), "");
}

pub fn osTextRepeatIsSwallowedTest(_: std.Io, _: std.mem.Allocator) !void {
    // The desktop's own auto-repeat of a key already repeating here is
    // absorbed rather than delivered -- otherwise one held key would run
    // at two cadences at once.
    var kb = host_eng.input.Keyboard{};
    kb.repeat = .{ .delay_ms = 10, .interval_ms = 10 };

    typeKey(&kb, .j, "j");
    repeatTick(&kb, 16);

    kb.noteKeyDown(.j, true); // SDL key-down carrying `repeat`
    try testz.expectTrue(kb.absorbRepeatedText("j"));

    // Absorbed means not typed: nothing new landed in this tick's text.
    var buf: [8]u8 = undefined;
    try testz.expectEqual(kb.text(&buf), 0);
}

pub fn osTextRepeatRefreshesWhatRepeatsTest(_: std.Io, _: std.mem.Allocator) !void {
    // Shift pressed part-way through a hold: the OS's repeat stream is
    // what reports the change, so the absorbed text updates what this
    // key repeats from here on.
    var kb = host_eng.input.Keyboard{};
    kb.repeat = .{ .delay_ms = 10, .interval_ms = 10 };

    typeKey(&kb, .a, "a");
    repeatTick(&kb, 16);
    kb.tickRepeats(20);
    try testz.expectEqualStr(kb.textRepeated(), "a");
    kb.finishTick();

    kb.noteKeyDown(.a, true);
    try testz.expectTrue(kb.absorbRepeatedText("A"));
    kb.tickRepeats(20);
    try testz.expectEqualStr(kb.textRepeated(), "A");
}

pub fn imeCommitNeverRepeatsTest(_: std.Io, _: std.mem.Allocator) !void {
    // Text committed out of an IME composition belongs to the
    // composition, not to a held key -- re-sending it on a hold would
    // type characters the user never asked for.
    var kb = host_eng.input.Keyboard{};
    kb.repeat = .{ .delay_ms = 10, .interval_ms = 10 };

    kb.set(.a, true);
    kb.noteKeyDown(.a, false);
    kb.setPreedit("にほん", 3);
    kb.pushText("日本");
    kb.noteCommittedText("日本");
    kb.clearPreedit();
    repeatTick(&kb, 16);

    kb.tickRepeats(100);
    try testz.expectEqualStr(kb.textRepeated(), "");
}

pub fn unattributedTextIsNotSwallowedTest(_: std.Io, _: std.mem.Allocator) !void {
    // Nothing is repeating here, so an OS-repeated text event has to be
    // delivered normally: never drop input this can't reproduce itself.
    var kb = host_eng.input.Keyboard{};
    kb.noteKeyDown(.j, true);
    try testz.expectFalse(kb.absorbRepeatedText("j"));
}

pub fn cancelRepeatsStopsHeldTextTest(_: std.Io, _: std.mem.Allocator) !void {
    // zoe pressing `i`: the key types, switching the editor to insert
    // mode, and the retime that follows must stop it typing itself into
    // the buffer it just opened -- no matter how long it stays held.
    var kb = host_eng.input.Keyboard{};
    kb.repeat = .{ .delay_ms = 30, .interval_ms = 30 };

    typeKey(&kb, .i, "i");
    repeatTick(&kb, 16);

    kb.cancelRepeats();
    kb.tickRepeats(1000);
    try testz.expectEqualStr(kb.textRepeated(), "");
    try testz.expectFalse(kb.repeated(.i));
}

pub fn cancelRepeatsStopsHeldKeysTest(_: std.Io, _: std.mem.Allocator) !void {
    var kb = host_eng.input.Keyboard{};
    kb.repeat = .{ .delay_ms = 30, .interval_ms = 30 };

    kb.set(.down, true);
    kb.noteKeyDown(.down, false);
    repeatTick(&kb, 16);

    kb.cancelRepeats();
    kb.tickRepeats(1000);
    try testz.expectFalse(kb.repeated(.down));
    // Nothing pending means nothing for the idle loop to wake for.
    try testz.expectEqual(kb.repeatDueMs(.down), null);
}

pub fn cancelRepeatsLiftsOnRepressTest(_: std.Io, _: std.mem.Allocator) !void {
    // The suppression is until the key is *pressed again*, not forever:
    // release and re-press and it repeats normally.
    var kb = host_eng.input.Keyboard{};
    kb.repeat = .{ .delay_ms = 30, .interval_ms = 30 };

    typeKey(&kb, .i, "i");
    repeatTick(&kb, 16);
    kb.cancelRepeats();
    repeatTick(&kb, 100);
    try testz.expectEqualStr(kb.textRepeated(), "");

    kb.set(.i, false);
    kb.noteKeyUp(.i);
    repeatTick(&kb, 16);
    typeKey(&kb, .i, "i");
    repeatTick(&kb, 16);
    kb.tickRepeats(40);
    try testz.expectEqualStr(kb.textRepeated(), "i");
}

pub fn textRepeatClearedOnFocusLossTest(_: std.Io, _: std.mem.Allocator) !void {
    var kb = host_eng.input.Keyboard{};
    kb.repeat = .{ .delay_ms = 10, .interval_ms = 10 };

    typeKey(&kb, .j, "j");
    repeatTick(&kb, 16);
    kb.tickRepeats(20);
    try testz.expectEqualStr(kb.textRepeated(), "j");

    kb.clear();
    try testz.expectEqualStr(kb.textRepeated(), "");
}

pub fn keyRepeatClearDropsPendingRepeatTest(_: std.Io, _: std.mem.Allocator) !void {
    // Focus loss drops the hold along with the key itself, so a key held
    // as the window went away can't keep repeating into the next focus.
    var kb = host_eng.input.Keyboard{};
    kb.repeat = .{ .delay_ms = 10, .interval_ms = 10 };

    kb.set(.up, true);
    repeatTick(&kb, 16);
    kb.tickRepeats(100);
    try testz.expectTrue(kb.repeated(.up));

    kb.clear();
    try testz.expectFalse(kb.repeated(.up));
    kb.tickRepeats(1000);
    try testz.expectFalse(kb.repeated(.up));
}
