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
    inline for (@typeInfo(Key).@"enum".fields) |field| {
        try testz.expectNotEqualStr(field.name, "F25");
        try testz.expectNotEqualStr(field.name, "world_1");
        try testz.expectNotEqualStr(field.name, "world_2");
    }
    // F24 is the last real one, and `unknown` must stay index 0 so the
    // bitsets can be indexed by `@intFromEnum` directly.
    try testz.expectEqual(@intFromEnum(Key.unknown), 0);
}

pub fn mouseButtonNamesAreWireStableTest(_: std.Io, _: std.mem.Allocator) !void {
    // `host/input.zig` forwards every field of this enum by name too.
    const fields = @typeInfo(MouseButton).@"enum".fields;
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
