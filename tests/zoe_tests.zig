//! zoe's editor core: the gap buffer, the line index, the motions and the
//! modal state machine.
//!
//! The editor cases are written as vim-notation key scripts (see
//! `zoe/keys.zig`) so they go in through the same `feedText`/`feedKey`
//! pair glyphwire's input notifications land on, rather than calling the
//! edit functions directly -- a normal-mode command that stopped being
//! dispatched off committed text would fail here.

const std = @import("std");
const testz = @import("testz");

const zoe = @import("zoe_support");
const GapBuffer = zoe.GapBuffer;
const Buffer = zoe.Buffer;
const Editor = zoe.Editor;
const motion = zoe.motion;
const keys = zoe.keys;

/// Builds an editor over `text`, runs `script`, and asserts the buffer
/// matches `expected`. Most cases below are one call to this.
fn expectEdit(alloc: std.mem.Allocator, text: []const u8, script: []const u8, expected: []const u8) !void {
    var ed = try Editor.initFromText(alloc, text, null);
    defer ed.deinit();
    _ = try keys.feed(&ed, script);

    const got = try ed.buf.text(alloc);
    defer alloc.free(got);
    try testz.expectEqualStr(got, expected);
}

fn expectText(alloc: std.mem.Allocator, buf: *const Buffer, expected: []const u8) !void {
    const got = try buf.text(alloc);
    defer alloc.free(got);
    try testz.expectEqualStr(got, expected);
}

// ─── GapBuffer ──────────────────────────────────────────────────────────

pub fn gapInsertAtEndTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var gap = try GapBuffer.initFrom(alloc, "hello");
    defer gap.deinit();
    try gap.insert(5, " world");
    try testz.expectEqual(gap.len(), 11);

    const out = try gap.read(alloc, 0, gap.len());
    defer alloc.free(out);
    try testz.expectEqualStr(out, "hello world");
}

pub fn gapInsertInMiddleMovesGapTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var gap = try GapBuffer.initFrom(alloc, "held");
    defer gap.deinit();
    try gap.insert(3, "lo wor");

    const out = try gap.read(alloc, 0, gap.len());
    defer alloc.free(out);
    try testz.expectEqualStr(out, "hello word");
}

pub fn gapMoveLeftThenRightRoundTripsTest(_: std.Io, alloc: std.mem.Allocator) !void {
    // Moving the gap further than its own width is the case where the
    // source and destination ranges overlap -- the copy direction has to
    // be right or bytes are duplicated over each other.
    var gap = try GapBuffer.initFrom(alloc, "abcdefghijklmnopqrstuvwxyz");
    defer gap.deinit();
    gap.moveGapTo(0);
    gap.moveGapTo(26);
    gap.moveGapTo(13);

    const out = try gap.read(alloc, 0, gap.len());
    defer alloc.free(out);
    try testz.expectEqualStr(out, "abcdefghijklmnopqrstuvwxyz");
}

pub fn gapReadStraddlingTheGapTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var gap = try GapBuffer.initFrom(alloc, "abcdef");
    defer gap.deinit();
    gap.moveGapTo(3);

    const out = try gap.read(alloc, 1, 5);
    defer alloc.free(out);
    try testz.expectEqualStr(out, "bcde");
}

pub fn gapDeleteClampsPastTheEndTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var gap = try GapBuffer.initFrom(alloc, "abcdef");
    defer gap.deinit();
    gap.delete(4, 100);
    try testz.expectEqual(gap.len(), 4);

    const out = try gap.read(alloc, 0, gap.len());
    defer alloc.free(out);
    try testz.expectEqualStr(out, "abcd");
}

pub fn gapGrowsPastInitialCapacityTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var gap = try GapBuffer.init(alloc);
    defer gap.deinit();
    var i: usize = 0;
    while (i < 500) : (i += 1) try gap.insert(gap.len(), "x");
    try testz.expectEqual(gap.len(), 500);
    try testz.expectEqual(gap.byteAt(499), 'x');
}

// ─── Buffer line index ──────────────────────────────────────────────────

pub fn bufferEmptyIsOneLineTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var buf = try Buffer.init(alloc);
    defer buf.deinit();
    try testz.expectEqual(buf.lineCount(), 1);
    try testz.expectEqual(buf.lineLen(0), 0);
}

pub fn bufferTrailingNewlineMakesAFinalEmptyLineTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var buf = try Buffer.initFromText(alloc, "a\nb\n");
    defer buf.deinit();
    try testz.expectEqual(buf.lineCount(), 3);
    try testz.expectEqual(buf.lineLen(2), 0);
}

pub fn bufferLineBoundsTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var buf = try Buffer.initFromText(alloc, "alpha\nbeta\ngamma");
    defer buf.deinit();
    try testz.expectEqual(buf.lineCount(), 3);
    try testz.expectEqual(buf.lineStart(1), 6);
    try testz.expectEqual(buf.lineEnd(1), 10);
    try testz.expectEqual(buf.lineLen(1), 4);
    try testz.expectEqual(buf.lineEnd(2), 16);
}

pub fn bufferLineAtIsBinarySearchedTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var buf = try Buffer.initFromText(alloc, "a\nbb\nccc\ndddd");
    defer buf.deinit();
    try testz.expectEqual(buf.lineAt(0), 0);
    try testz.expectEqual(buf.lineAt(1), 0); // the newline belongs to its line
    try testz.expectEqual(buf.lineAt(2), 1);
    try testz.expectEqual(buf.lineAt(5), 2);
    try testz.expectEqual(buf.lineAt(9), 3);
    try testz.expectEqual(buf.lineAt(999), 3); // clamped
}

pub fn bufferPosOffsetRoundTripTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var buf = try Buffer.initFromText(alloc, "alpha\nbeta\ngamma");
    defer buf.deinit();
    const pos = buf.posOf(8);
    try testz.expectEqual(pos.line, 1);
    try testz.expectEqual(pos.col, 2);
    try testz.expectEqual(buf.offsetOf(pos), 8);
    // A column past the line's end clamps to it rather than spilling.
    try testz.expectEqual(buf.offsetOf(.{ .line = 1, .col = 99 }), 10);
}

pub fn bufferEditsReindexLinesTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var buf = try Buffer.initFromText(alloc, "one\ntwo");
    defer buf.deinit();
    try buf.insert(3, "\nmid");
    try testz.expectEqual(buf.lineCount(), 3);
    try expectText(alloc, &buf, "one\nmid\ntwo");

    try buf.delete(3, 4);
    try testz.expectEqual(buf.lineCount(), 2);
    try expectText(alloc, &buf, "one\ntwo");
}

pub fn bufferDirtyFlagTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var buf = try Buffer.initFromText(alloc, "x");
    defer buf.deinit();
    try testz.expectFalse(buf.dirty);
    try buf.insert(1, "y");
    try testz.expectTrue(buf.dirty);
    buf.markClean();
    try testz.expectFalse(buf.dirty);
}

pub fn bufferEditCounterBumpsOnRealMutationsOnlyTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var buf = try Buffer.initFromText(alloc, "abc");
    defer buf.deinit();
    try testz.expectEqual(buf.edits, 0);
    try buf.insert(1, "X");
    try buf.delete(0, 1);
    try testz.expectEqual(buf.edits, 2);
    // The no-op guards don't count.
    try buf.insert(0, "");
    try buf.delete(99, 3);
    try testz.expectEqual(buf.edits, 2);
}

// ─── Buffer-pane render planning ────────────────────────────────────────

pub fn planBufferRenderShiftsOnPureSubScreenScrollTest(_: std.Io, _: std.mem.Allocator) !void {
    const plan = zoe.ui.planBufferRender;

    // Scrolled down 3 lines on a 20-row pane: shift up 3, repaint the
    // bottom 3.
    switch (plan(.{ .prev_top = 10, .top = 13, .prev_left = 0, .left = 0, .prev_edits = 4, .edits = 4, .rows = 20, .force_full = false })) {
        .full => return error.TestExpectedShift,
        .shift => |s| {
            try testz.expectEqual(s.count, 3);
            try testz.expectEqual(s.dir, .up);
            try testz.expectEqual(s.exposed_lo, 17);
            try testz.expectEqual(s.exposed_hi, 20);
        },
    }

    // Scrolled up 2: shift down 2, repaint the top 2.
    switch (plan(.{ .prev_top = 10, .top = 8, .prev_left = 0, .left = 0, .prev_edits = 4, .edits = 4, .rows = 20, .force_full = false })) {
        .full => return error.TestExpectedShift,
        .shift => |s| {
            try testz.expectEqual(s.dir, .down);
            try testz.expectEqual(s.exposed_lo, 0);
            try testz.expectEqual(s.exposed_hi, 2);
        },
    }
}

pub fn planBufferRenderFallsBackToFullTest(_: std.Io, _: std.mem.Allocator) !void {
    const plan = zoe.ui.planBufferRender;
    const S = zoe.ui.BufferRenderState;
    const expectFull = struct {
        fn f(s: S) !void {
            try testz.expectTrue(plan(s) == .full);
        }
    }.f;

    // No scroll.
    try expectFull(.{ .prev_top = 10, .top = 10, .prev_left = 0, .left = 0, .prev_edits = 4, .edits = 4, .rows = 20, .force_full = false });
    // An edit landed.
    try expectFull(.{ .prev_top = 10, .top = 13, .prev_left = 0, .left = 0, .prev_edits = 4, .edits = 5, .rows = 20, .force_full = false });
    // Horizontal scroll.
    try expectFull(.{ .prev_top = 10, .top = 13, .prev_left = 0, .left = 4, .prev_edits = 4, .edits = 4, .rows = 20, .force_full = false });
    // Jump of a screen or more -- nothing to keep.
    try expectFull(.{ .prev_top = 10, .top = 40, .prev_left = 0, .left = 0, .prev_edits = 4, .edits = 4, .rows = 20, .force_full = false });
    // Forced.
    try expectFull(.{ .prev_top = 10, .top = 13, .prev_left = 0, .left = 0, .prev_edits = 4, .edits = 4, .rows = 20, .force_full = true });
}

// ─── Motions ────────────────────────────────────────────────────────────

pub fn motionLeftRightStopAtLineEdgesTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var buf = try Buffer.initFromText(alloc, "ab\ncd");
    defer buf.deinit();
    // Normal mode stops on the last character, not the newline.
    try testz.expectEqual(motion.right(&buf, 0, 5, false), 1);
    try testz.expectEqual(motion.right(&buf, 0, 5, true), 2);
    try testz.expectEqual(motion.left(&buf, 1, 5), 0);
    // No wrapping onto the previous line.
    try testz.expectEqual(motion.left(&buf, 3, 5), 3);
}

pub fn motionStepsWholeCodepointsTest(_: std.Io, alloc: std.mem.Allocator) !void {
    // "héllo" -- the e-acute is two bytes, so one `l` must move two.
    var buf = try Buffer.initFromText(alloc, "h\u{00e9}llo");
    defer buf.deinit();
    try testz.expectEqual(motion.right(&buf, 0, 1, false), 1);
    try testz.expectEqual(motion.right(&buf, 1, 1, false), 3);
    try testz.expectEqual(motion.left(&buf, 3, 1), 1);
}

pub fn motionStickyColumnSnapsToCodepointTest(_: std.Io, alloc: std.mem.Allocator) !void {
    // Column 2 of line 1 is mid-sequence; `j` must land on the start of
    // the two-byte character rather than inside it.
    var buf = try Buffer.initFromText(alloc, "abcd\nx\u{00e9}z");
    defer buf.deinit();
    try testz.expectEqual(motion.down(&buf, 2, 1, 2, false), 6);
}

pub fn motionWordForwardTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var buf = try Buffer.initFromText(alloc, "foo bar.baz qux");
    defer buf.deinit();
    try testz.expectEqual(motion.wordForward(&buf, 0, 1, false), 4); // foo -> bar
    try testz.expectEqual(motion.wordForward(&buf, 4, 1, false), 7); // bar -> .
    try testz.expectEqual(motion.wordForward(&buf, 7, 1, false), 8); // . -> baz
    // WORD ignores the punctuation split.
    try testz.expectEqual(motion.wordForward(&buf, 4, 1, true), 12);
    // Counts chain.
    try testz.expectEqual(motion.wordForward(&buf, 0, 3, false), 8);
}

pub fn motionWordStopsOnEmptyLineTest(_: std.Io, alloc: std.mem.Allocator) !void {
    // vim treats a blank line as a word of its own.
    var buf = try Buffer.initFromText(alloc, "foo\n\nbar");
    defer buf.deinit();
    try testz.expectEqual(motion.wordForward(&buf, 0, 1, false), 4);
    try testz.expectEqual(motion.wordBackward(&buf, 5, 1, false), 4);
}

pub fn motionWordBackwardAndEndTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var buf = try Buffer.initFromText(alloc, "foo bar baz");
    defer buf.deinit();
    try testz.expectEqual(motion.wordBackward(&buf, 9, 1, false), 8);
    try testz.expectEqual(motion.wordBackward(&buf, 8, 1, false), 4);
    try testz.expectEqual(motion.wordBackward(&buf, 0, 1, false), 0);
    // `e` always advances, so sitting on a word's last character moves on.
    try testz.expectEqual(motion.wordEnd(&buf, 0, 1, false), 2);
    try testz.expectEqual(motion.wordEnd(&buf, 2, 1, false), 6);
}

pub fn motionFirstNonBlankAndGotoLineTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var buf = try Buffer.initFromText(alloc, "one\n    two\nthree");
    defer buf.deinit();
    try testz.expectEqual(motion.firstNonBlank(&buf, 4), 8);
    try testz.expectEqual(motion.gotoLine(&buf, 1), 8);
    try testz.expectEqual(motion.gotoLine(&buf, 99), 12); // clamped to the last
}

pub fn motionClampNormalPullsOffTheNewlineTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var buf = try Buffer.initFromText(alloc, "abc\ndef");
    defer buf.deinit();
    try testz.expectEqual(motion.clampNormal(&buf, 3), 2);
    // An empty line has exactly one legal position.
    var empty = try Buffer.initFromText(alloc, "\nx");
    defer empty.deinit();
    try testz.expectEqual(motion.clampNormal(&empty, 0), 0);
}

// ─── Editor: modes ──────────────────────────────────────────────────────

pub fn editorStartsInNormalModeAndIgnoresTextTest(_: std.Io, alloc: std.mem.Allocator) !void {
    // "zzz" is not a command, so nothing is typed into the buffer -- the
    // whole point of a modal editor.
    try expectEdit(alloc, "abc", "zzz", "abc");
}

pub fn editorInsertModeTypesTextTest(_: std.Io, alloc: std.mem.Allocator) !void {
    try expectEdit(alloc, "world", "ihello <esc>", "hello world");
}

pub fn editorEscapeStepsCursorBackTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var ed = try Editor.initFromText(alloc, "abc", null);
    defer ed.deinit();
    _ = try keys.feed(&ed, "A!<esc>");
    try testz.expectEqual(ed.mode, .normal);
    // "abc!" with the cursor left on the `!`, not past it.
    try testz.expectEqual(ed.cursor, 3);
}

pub fn editorAppendAtLineEndTest(_: std.Io, alloc: std.mem.Allocator) !void {
    try expectEdit(alloc, "ab\ncd", "A!<esc>", "ab!\ncd");
    try expectEdit(alloc, "ab\ncd", "a!<esc>", "a!b\ncd");
    try expectEdit(alloc, "  ab", "Ix<esc>", "  xab");
}

pub fn editorOpenLineBelowAndAboveTest(_: std.Io, alloc: std.mem.Allocator) !void {
    try expectEdit(alloc, "one\ntwo", "onew<esc>", "one\nnew\ntwo");
    try expectEdit(alloc, "one\ntwo", "Onew<esc>", "new\none\ntwo");
}

pub fn editorBackspaceJoinsLinesTest(_: std.Io, alloc: std.mem.Allocator) !void {
    try expectEdit(alloc, "ab\ncd", "ji<bs><esc>", "abcd");
}

pub fn editorEnterSplitsLineTest(_: std.Io, alloc: std.mem.Allocator) !void {
    try expectEdit(alloc, "abcd", "lli<cr><esc>", "ab\ncd");
}

pub fn editorInsertModeAcceptsMultibyteTextTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var ed = try Editor.initFromText(alloc, "", null);
    defer ed.deinit();
    _ = try keys.feed(&ed, "i");
    _ = try ed.feedText("\u{65e5}\u{672c}"); // committed IME text
    _ = try keys.feed(&ed, "<esc>");
    try expectText(alloc, &ed.buf, "\u{65e5}\u{672c}");
}

// ─── Editor: motions and counts ─────────────────────────────────────────

pub fn editorCountedMotionTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var ed = try Editor.initFromText(alloc, "abcdefgh", null);
    defer ed.deinit();
    _ = try keys.feed(&ed, "3l");
    try testz.expectEqual(ed.cursor, 3);
    _ = try keys.feed(&ed, "12l"); // clamped to the line's last character
    try testz.expectEqual(ed.cursor, 7);
}

pub fn editorZeroIsLineStartNotACountTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var ed = try Editor.initFromText(alloc, "abcdef", null);
    defer ed.deinit();
    _ = try keys.feed(&ed, "4l0");
    try testz.expectEqual(ed.cursor, 0);
    // But `0` after a digit is part of the count.
    _ = try keys.feed(&ed, "10l");
    try testz.expectEqual(ed.cursor, 5);
}

pub fn editorGotoLineTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var ed = try Editor.initFromText(alloc, "one\ntwo\nthree\nfour", null);
    defer ed.deinit();
    _ = try keys.feed(&ed, "G");
    try testz.expectEqual(ed.pos().line, 3);
    _ = try keys.feed(&ed, "gg");
    try testz.expectEqual(ed.pos().line, 0);
    _ = try keys.feed(&ed, "3G");
    try testz.expectEqual(ed.pos().line, 2);
    _ = try keys.feed(&ed, "2gg");
    try testz.expectEqual(ed.pos().line, 1);
}

pub fn editorStickyColumnSurvivesAShortLineTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var ed = try Editor.initFromText(alloc, "abcdef\nx\nabcdef", null);
    defer ed.deinit();
    _ = try keys.feed(&ed, "4l"); // column 4 of line 0
    _ = try keys.feed(&ed, "j");
    try testz.expectEqual(ed.pos().col, 0); // clamped on the short line
    _ = try keys.feed(&ed, "j");
    try testz.expectEqual(ed.pos().col, 4); // and back out again
}

/// `"l0\nl1\n...\nl<n-1>"` -- a buffer tall enough to page through.
fn numberedLines(alloc: std.mem.Allocator, n: usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (i > 0) try out.append(alloc, '\n');
        try out.print(alloc, "l{d}", .{i});
    }
    return out.toOwnedSlice(alloc);
}

pub fn editorPageDownAndUpMoveByPageLinesTest(_: std.Io, alloc: std.mem.Allocator) !void {
    const text = try numberedLines(alloc, 40);
    defer alloc.free(text);
    var ed = try Editor.initFromText(alloc, text, null);
    defer ed.deinit();
    // Default page is 10 lines.
    _ = try keys.feed(&ed, "<page_down>");
    try testz.expectEqual(ed.pos().line, 10);
    _ = try keys.feed(&ed, "<page_down>");
    try testz.expectEqual(ed.pos().line, 20);
    _ = try keys.feed(&ed, "<page_up>");
    try testz.expectEqual(ed.pos().line, 10);
    // Clamped at the ends, never wrapping.
    _ = try keys.feed(&ed, "<page_up>");
    _ = try keys.feed(&ed, "<page_up>");
    try testz.expectEqual(ed.pos().line, 0);
}

pub fn editorPageLinesIsConfigurableTest(_: std.Io, alloc: std.mem.Allocator) !void {
    const text = try numberedLines(alloc, 40);
    defer alloc.free(text);
    var ed = try Editor.initFromText(alloc, text, null);
    defer ed.deinit();
    ed.page_lines = 15; // what `zoe.conf`'s `page_lines` would set
    _ = try keys.feed(&ed, "<page_down>");
    try testz.expectEqual(ed.pos().line, 15);
}

pub fn editorCtrlDAndCtrlUPageInNormalModeTest(_: std.Io, alloc: std.mem.Allocator) !void {
    const text = try numberedLines(alloc, 40);
    defer alloc.free(text);
    var ed = try Editor.initFromText(alloc, text, null);
    defer ed.deinit();
    // Ctrl carries no character, so these arrive as named keys.
    _ = try ed.feedKey("d", .{ .ctrl = true });
    try testz.expectEqual(ed.pos().line, 10);
    _ = try ed.feedKey("u", .{ .ctrl = true });
    try testz.expectEqual(ed.pos().line, 0);
    // Plain `d` (via the text stream) is still the delete operator.
    _ = try keys.feed(&ed, "d");
    try testz.expectEqual(ed.operator.?, 'd');
}

// ─── Editor: edits ──────────────────────────────────────────────────────

pub fn editorDeleteCharTest(_: std.Io, alloc: std.mem.Allocator) !void {
    try expectEdit(alloc, "abcdef", "x", "bcdef");
    try expectEdit(alloc, "abcdef", "3x", "def");
    try expectEdit(alloc, "abcdef", "llX", "acdef");
    // `x` never eats the newline out from under the line.
    try expectEdit(alloc, "ab\ncd", "l5x", "a\ncd");
}

pub fn editorDeleteToLineEndTest(_: std.Io, alloc: std.mem.Allocator) !void {
    try expectEdit(alloc, "abcdef\nxyz", "llD", "ab\nxyz");
    try expectEdit(alloc, "abcdef", "llC!<esc>", "ab!");
}

pub fn editorSubstituteTest(_: std.Io, alloc: std.mem.Allocator) !void {
    try expectEdit(alloc, "abc", "sX<esc>", "Xbc");
}

pub fn editorDeleteLineTest(_: std.Io, alloc: std.mem.Allocator) !void {
    try expectEdit(alloc, "one\ntwo\nthree", "jdd", "one\nthree");
    try expectEdit(alloc, "one\ntwo\nthree", "2dd", "three");
    // The last line takes the newline *before* it, leaving no blank line.
    try expectEdit(alloc, "one\ntwo", "jdd", "one");
    // Deleting the only line leaves an empty buffer, not a stray newline.
    try expectEdit(alloc, "only", "dd", "");
}

pub fn editorDeleteWordTest(_: std.Io, alloc: std.mem.Allocator) !void {
    try expectEdit(alloc, "foo bar baz", "dw", "bar baz");
    try expectEdit(alloc, "foo bar baz", "2dw", "baz");
    // `dw` on the last word of a line stops at the line end rather than
    // pulling the next line up.
    try expectEdit(alloc, "foo bar\nbaz", "wdw", "foo \nbaz");
}

pub fn editorDeleteWithMotionsTest(_: std.Io, alloc: std.mem.Allocator) !void {
    try expectEdit(alloc, "foo bar", "$db", "foo r");
    try expectEdit(alloc, "abcdef", "3ld0", "def");
    try expectEdit(alloc, "abcdef", "lld$", "ab");
    try expectEdit(alloc, "abcdef", "2dl", "cdef");
    try expectEdit(alloc, "abcdef", "3l2dh", "adef");
    try expectEdit(alloc, "foo bar", "de", " bar");
}

pub fn editorLinewiseDeleteMotionsTest(_: std.Io, alloc: std.mem.Allocator) !void {
    try expectEdit(alloc, "one\ntwo\nthree\nfour", "dj", "three\nfour");
    try expectEdit(alloc, "one\ntwo\nthree\nfour", "2jdk", "one\nfour");
    try expectEdit(alloc, "one\ntwo\nthree\nfour", "jdG", "one");
    try expectEdit(alloc, "one\ntwo\nthree\nfour", "2jdgg", "four");
}

pub fn editorOperatorCountsMultiplyTest(_: std.Io, alloc: std.mem.Allocator) !void {
    // vim's rule: the count before the operator times the motion's own.
    try expectEdit(alloc, "a b c d e f g", "2d3w", "g");
}

pub fn editorEscapeCancelsAPendingOperatorTest(_: std.Io, alloc: std.mem.Allocator) !void {
    // The `d` is abandoned, so the following `w` is a plain motion.
    var ed = try Editor.initFromText(alloc, "foo bar", null);
    defer ed.deinit();
    _ = try keys.feed(&ed, "d<esc>w");
    try expectText(alloc, &ed.buf, "foo bar");
    try testz.expectEqual(ed.cursor, 4);
}

// ─── Editor: visual mode & clipboard ────────────────────────────────────

/// Runs `script` and asserts the resulting outcome is a `set_clipboard`
/// carrying `expected`.
fn expectClipboard(alloc: std.mem.Allocator, text: []const u8, script: []const u8, expected: []const u8) !void {
    var ed = try Editor.initFromText(alloc, text, null);
    defer ed.deinit();
    switch (try keys.feed(&ed, script)) {
        .set_clipboard => |got| try testz.expectEqualStr(got, expected),
        else => try testz.fail(),
    }
}

pub fn visualCharwiseYankReportsSelectionTest(_: std.Io, alloc: std.mem.Allocator) !void {
    // `v` from the start, `e` to the end of "foo", `y` yanks it inclusive.
    try expectClipboard(alloc, "foo bar", "vey", "foo");
}

pub fn visualCharwiseYankLeavesNormalModeAtSelectionStartTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var ed = try Editor.initFromText(alloc, "foo bar", null);
    defer ed.deinit();
    _ = try keys.feed(&ed, "llvey");
    try testz.expectEqual(ed.mode, .normal);
    try testz.expectTrue(ed.select_anchor == null);
    try testz.expectEqual(ed.cursor, 2);
}

pub fn visualLinewiseYankTakesWholeLinesTest(_: std.Io, alloc: std.mem.Allocator) !void {
    try expectClipboard(alloc, "one\ntwo\nthree", "Vjy", "one\ntwo\n");
}

pub fn visualDeleteRemovesSelectionAndYanksTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var ed = try Editor.initFromText(alloc, "hello world", null);
    defer ed.deinit();
    switch (try keys.feed(&ed, "vlld")) {
        .set_clipboard => |got| try testz.expectEqualStr(got, "hel"),
        else => try testz.fail(),
    }
    try expectText(alloc, &ed.buf, "lo world");
    try testz.expectEqual(ed.mode, .normal);
}

pub fn visualChangeEntersInsertModeTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var ed = try Editor.initFromText(alloc, "hello", null);
    defer ed.deinit();
    _ = try keys.feed(&ed, "vlc");
    try testz.expectEqual(ed.mode, .insert);
    try expectText(alloc, &ed.buf, "llo");
}

pub fn visualModeSwitchesCharwiseToLinewiseTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var ed = try Editor.initFromText(alloc, "one\ntwo", null);
    defer ed.deinit();
    _ = try keys.feed(&ed, "vV");
    try testz.expectEqual(ed.mode, .visual_line);
    // A second `v`/`V` on the matching submode leaves visual mode.
    _ = try keys.feed(&ed, "V");
    try testz.expectEqual(ed.mode, .normal);
}

pub fn visualCountedGotoLineExtendsSelectionTest(_: std.Io, alloc: std.mem.Allocator) !void {
    // `3gg` while visual keeps the count for the `gg` and grows the
    // selection to line 3.
    var ed = try Editor.initFromText(alloc, "one\ntwo\nthree\nfour", null);
    defer ed.deinit();
    _ = try keys.feed(&ed, "v3gg");
    const span = ed.selectionSpan().?;
    try testz.expectEqual(span.lo, 0);
    try testz.expectEqual(ed.buf.lineAt(span.hi -| 1), 2); // through line 3
}

pub fn visualEscapeReturnsToNormalTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var ed = try Editor.initFromText(alloc, "abc", null);
    defer ed.deinit();
    _ = try keys.feed(&ed, "vl<esc>");
    try testz.expectEqual(ed.mode, .normal);
    try testz.expectTrue(ed.select_anchor == null);
}

pub fn visualPasteReturnsAPasteOutcomeTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var ed = try Editor.initFromText(alloc, "hello", null);
    defer ed.deinit();
    // `vll` selects "hel"; `p` drops it and asks the host to splice the
    // clipboard in.
    switch (try keys.feed(&ed, "vllp")) {
        .paste => |p| try testz.expectTrue(!p.after),
        else => try testz.fail(),
    }
    try expectText(alloc, &ed.buf, "lo");
    try testz.expectEqual(ed.mode, .normal);
}

pub fn normalDeleteFeedsTheClipboardTest(_: std.Io, alloc: std.mem.Allocator) !void {
    // vim's unnamed register: `x`, `dd`, `dw` all land on the clipboard.
    try expectClipboard(alloc, "abc", "x", "a");
    try expectClipboard(alloc, "one\ntwo", "dd", "one\n");
    try expectClipboard(alloc, "foo bar", "dw", "foo ");
}

pub fn normalYankOperatorReportsClipboardTest(_: std.Io, alloc: std.mem.Allocator) !void {
    try expectClipboard(alloc, "one\ntwo\nthree", "yy", "one\n");
    try expectClipboard(alloc, "foo bar baz", "yw", "foo ");
    try expectClipboard(alloc, "one\ntwo\nthree", "yj", "one\ntwo\n");
}

pub fn normalYankLeavesBufferUnchangedTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var ed = try Editor.initFromText(alloc, "one\ntwo", null);
    defer ed.deinit();
    _ = try keys.feed(&ed, "jyy");
    try expectText(alloc, &ed.buf, "one\ntwo");
}

pub fn normalPasteAndPutTextCharwiseTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var ed = try Editor.initFromText(alloc, "abc", null);
    defer ed.deinit();
    switch (try keys.feed(&ed, "p")) {
        .paste => |p| try testz.expectTrue(p.after),
        else => try testz.fail(),
    }
    // The host would call `putText` with whatever the clipboard held.
    try ed.putText("XY", true);
    try expectText(alloc, &ed.buf, "aXYbc");
    try testz.expectEqual(ed.cursor, 2);
}

pub fn putTextLinewisePastesWholeLinesBelowTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var ed = try Editor.initFromText(alloc, "one\ntwo", null);
    defer ed.deinit();
    try ed.putText("new\n", true); // `p` on line 1
    try expectText(alloc, &ed.buf, "one\nnew\ntwo");
}

pub fn putTextLinewiseAboveTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var ed = try Editor.initFromText(alloc, "one\ntwo", null);
    defer ed.deinit();
    try ed.putText("new\n", false); // `P` on line 1
    try expectText(alloc, &ed.buf, "new\none\ntwo");
}

pub fn putTextLinewiseOnLastLineAddsTheSeparatorTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var ed = try Editor.initFromText(alloc, "one\ntwo", null);
    defer ed.deinit();
    _ = try keys.feed(&ed, "j"); // on "two", the last line, no trailing \n
    try ed.putText("new\n", true);
    try expectText(alloc, &ed.buf, "one\ntwo\nnew\n");
}

pub fn selectionSpanCharwiseIsInclusiveTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var ed = try Editor.initFromText(alloc, "hello", null);
    defer ed.deinit();
    _ = try keys.feed(&ed, "vll"); // anchor 0, cursor 2
    const span = ed.selectionSpan().?;
    try testz.expectEqual(span.lo, 0);
    try testz.expectEqual(span.hi, 3); // includes the cursor cell
    try testz.expectTrue(!span.linewise);
}

pub fn selectionSpanLinewiseCoversWholeLinesTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var ed = try Editor.initFromText(alloc, "one\ntwo\nthree", null);
    defer ed.deinit();
    _ = try keys.feed(&ed, "jVj"); // lines 1..2
    const span = ed.selectionSpan().?;
    try testz.expectEqual(span.lo, 4);
    try testz.expectEqual(span.hi, 13); // "two\nthree" through the end of the buffer
    try testz.expectTrue(span.linewise);
}

pub fn clipboardCopyWithNoSelectionTakesTheLineTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var ed = try Editor.initFromText(alloc, "one\ntwo", null);
    defer ed.deinit();
    _ = try keys.feed(&ed, "j");
    switch (try ed.clipboardCopy()) {
        .set_clipboard => |got| try testz.expectEqualStr(got, "two\n"),
        else => try testz.fail(),
    }
    try expectText(alloc, &ed.buf, "one\ntwo"); // copy never mutates
}

pub fn clipboardCutWithNoSelectionRemovesTheLineTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var ed = try Editor.initFromText(alloc, "one\ntwo\nthree", null);
    defer ed.deinit();
    _ = try keys.feed(&ed, "j");
    switch (try ed.clipboardCut()) {
        .set_clipboard => |got| try testz.expectEqualStr(got, "two\n"),
        else => try testz.fail(),
    }
    try expectText(alloc, &ed.buf, "one\nthree");
}

pub fn clipboardCopyUsesTheVisualSelectionTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var ed = try Editor.initFromText(alloc, "hello world", null);
    defer ed.deinit();
    _ = try keys.feed(&ed, "vee"); // "hello world" -> through "world"
    switch (try ed.clipboardCopy()) {
        .set_clipboard => |got| try testz.expectEqualStr(got, "hello world"),
        else => try testz.fail(),
    }
    try testz.expectEqual(ed.mode, .normal);
}

pub fn mouseDragBuildsACharwiseSelectionTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var ed = try Editor.initFromText(alloc, "hello world", null);
    defer ed.deinit();
    ed.setVisualSelection(2, 7);
    try testz.expectEqual(ed.mode, .visual);
    const span = ed.selectionSpan().?;
    try testz.expectEqual(span.lo, 2);
    try testz.expectEqual(span.hi, 8);
}

pub fn dropSelectionRemovesSelectedTextWithoutClipboardTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var ed = try Editor.initFromText(alloc, "hello", null);
    defer ed.deinit();
    _ = try keys.feed(&ed, "vll");
    try ed.dropSelection();
    try expectText(alloc, &ed.buf, "lo");
    try testz.expectEqual(ed.mode, .normal);
}

// ─── Editor: command line ───────────────────────────────────────────────

pub fn commandLineWriteReturnsAnOutcomeTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var ed = try Editor.initFromText(alloc, "x", null);
    defer ed.deinit();
    const outcome = try keys.feed(&ed, ":w<cr>");
    switch (outcome) {
        .write => |path| try testz.expectTrue(path == null),
        else => try testz.fail(),
    }
    try testz.expectEqual(ed.mode, .normal);
}

pub fn commandLineWriteCarriesItsArgumentTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var ed = try Editor.initFromText(alloc, "x", null);
    defer ed.deinit();
    const outcome = try keys.feed(&ed, ":w out.txt<cr>");
    switch (outcome) {
        .write => |path| try testz.expectEqualStr(path.?, "out.txt"),
        else => try testz.fail(),
    }
}

pub fn commandLineQuitRefusesADirtyBufferTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var ed = try Editor.initFromText(alloc, "x", null);
    defer ed.deinit();
    _ = try keys.feed(&ed, "iy<esc>");

    const refused = try keys.feed(&ed, ":q<cr>");
    switch (refused) {
        .none => {},
        else => try testz.fail(),
    }
    try testz.expectTrue(std.mem.startsWith(u8, ed.status.items, "E37:"));

    // `!` overrides.
    const forced = try keys.feed(&ed, ":q!<cr>");
    switch (forced) {
        .quit => |q| try testz.expectTrue(q.force),
        else => try testz.fail(),
    }
}

pub fn commandLineQuitAfterSaveIsCleanTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var ed = try Editor.initFromText(alloc, "x", null);
    defer ed.deinit();
    _ = try keys.feed(&ed, "iy<esc>");
    ed.markSaved();

    switch (try keys.feed(&ed, ":q<cr>")) {
        .quit => |q| try testz.expectFalse(q.force),
        else => try testz.fail(),
    }
}

pub fn commandLineGotoLineTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var ed = try Editor.initFromText(alloc, "one\ntwo\nthree", null);
    defer ed.deinit();
    _ = try keys.feed(&ed, ":3<cr>");
    try testz.expectEqual(ed.pos().line, 2);
}

pub fn commandLineDollarAndDotAddressesTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var ed = try Editor.initFromText(alloc, "one\ntwo\nthree\nfour\nfive", null);
    defer ed.deinit();
    _ = try keys.feed(&ed, ":$<cr>");
    try testz.expectEqual(ed.pos().line, 4);
    _ = try keys.feed(&ed, ":2<cr>");
    _ = try keys.feed(&ed, ":.<cr>");
    try testz.expectEqual(ed.pos().line, 1);
}

pub fn commandLineRelativeAddressesTest(_: std.Io, alloc: std.mem.Allocator) !void {
    const text = try numberedLines(alloc, 20);
    defer alloc.free(text);
    var ed = try Editor.initFromText(alloc, text, null);
    defer ed.deinit();
    _ = try keys.feed(&ed, ":10<cr>"); // line 10 == index 9
    _ = try keys.feed(&ed, ":+5<cr>");
    try testz.expectEqual(ed.pos().line, 14);
    _ = try keys.feed(&ed, ":-3<cr>");
    try testz.expectEqual(ed.pos().line, 11);
    _ = try keys.feed(&ed, ":-<cr>"); // bare `-` is one line
    try testz.expectEqual(ed.pos().line, 10);
}

pub fn commandLineCountedMotionTest(_: std.Io, alloc: std.mem.Allocator) !void {
    const text = try numberedLines(alloc, 40);
    defer alloc.free(text);
    var ed = try Editor.initFromText(alloc, text, null);
    defer ed.deinit();
    _ = try keys.feed(&ed, ":25<cr>"); // line index 24
    _ = try keys.feed(&ed, ":23k<cr>");
    try testz.expectEqual(ed.pos().line, 1);
    _ = try keys.feed(&ed, ":10j<cr>");
    try testz.expectEqual(ed.pos().line, 11);
}

pub fn commandLineChdirAndPwdReturnOutcomesTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var ed = try Editor.initFromText(alloc, "x", null);
    defer ed.deinit();
    switch (try keys.feed(&ed, ":cd /tmp<cr>")) {
        .chdir => |dir| try testz.expectEqualStr(dir.?, "/tmp"),
        else => try testz.fail(),
    }
    switch (try keys.feed(&ed, ":cd<cr>")) {
        .chdir => |dir| try testz.expectTrue(dir == null),
        else => try testz.fail(),
    }
    switch (try keys.feed(&ed, ":cd -<cr>")) {
        .chdir => |dir| try testz.expectEqualStr(dir.?, "-"),
        else => try testz.fail(),
    }
    switch (try keys.feed(&ed, ":pwd<cr>")) {
        .pwd => {},
        else => try testz.fail(),
    }
}

pub fn commandLineUnknownCommandReportsE492Test(_: std.Io, alloc: std.mem.Allocator) !void {
    var ed = try Editor.initFromText(alloc, "x", null);
    defer ed.deinit();
    _ = try keys.feed(&ed, ":nope<cr>");
    try testz.expectTrue(std.mem.startsWith(u8, ed.status.items, "E492:"));
    try testz.expectEqual(ed.mode, .normal);
}

pub fn commandLineSetLinenoChangesTheGutterModeTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var ed = try Editor.initFromText(alloc, "x", null);
    defer ed.deinit();
    try testz.expectEqual(ed.line_numbers, .absolute); // the default

    _ = try keys.feed(&ed, ":set lineno=relative<cr>");
    try testz.expectEqual(ed.line_numbers, .relative);
    try testz.expectEqual(ed.mode, .normal);

    _ = try keys.feed(&ed, ":set lineno=off<cr>");
    try testz.expectEqual(ed.line_numbers, .off);

    // Spaces around the `=` are tolerated.
    _ = try keys.feed(&ed, ":set lineno = absolute<cr>");
    try testz.expectEqual(ed.line_numbers, .absolute);
}

pub fn commandLineSetRejectsUnknownOptionAndValueTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var ed = try Editor.initFromText(alloc, "x", null);
    defer ed.deinit();

    _ = try keys.feed(&ed, ":set wrap=on<cr>");
    try testz.expectTrue(std.mem.startsWith(u8, ed.status.items, "E518:"));

    _ = try keys.feed(&ed, ":set lineno=sideways<cr>");
    try testz.expectTrue(std.mem.startsWith(u8, ed.status.items, "E474:"));
    // A bad value leaves the setting as it was.
    try testz.expectEqual(ed.line_numbers, .absolute);
}

pub fn commandLineEscapeAbandonsTheLineTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var ed = try Editor.initFromText(alloc, "x", null);
    defer ed.deinit();
    _ = try keys.feed(&ed, ":q<esc>");
    try testz.expectEqual(ed.mode, .normal);
    try testz.expectEqual(ed.cmdline.items.len, 0);
}

pub fn commandLineBackspaceOverTheColonLeavesTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var ed = try Editor.initFromText(alloc, "x", null);
    defer ed.deinit();
    _ = try keys.feed(&ed, ":w<bs><bs>");
    try testz.expectEqual(ed.mode, .normal);
}

// ─── Editor: :e and loadText ────────────────────────────────────────────

pub fn editorLoadTextReplacesTheBufferTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var ed = try Editor.initFromText(alloc, "old\ncontent", "a.txt");
    defer ed.deinit();
    _ = try keys.feed(&ed, "jll");

    try ed.loadText("brand new", "b.txt");
    try expectText(alloc, &ed.buf, "brand new");
    try testz.expectEqualStr(ed.path.?, "b.txt");
    // A fresh file starts at the top, unmodified, in normal mode.
    try testz.expectEqual(ed.cursor, 0);
    try testz.expectEqual(ed.mode, .normal);
    try testz.expectFalse(ed.buf.dirty);
}

pub fn commandLineEditReturnsAnOutcomeTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var ed = try Editor.initFromText(alloc, "x", null);
    defer ed.deinit();

    switch (try keys.feed(&ed, ":e notes.md<cr>")) {
        .edit => |path| try testz.expectEqualStr(path.?, "notes.md"),
        else => try testz.fail(),
    }
}

pub fn commandLineEditRefusesADirtyBufferTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var ed = try Editor.initFromText(alloc, "x", null);
    defer ed.deinit();
    _ = try keys.feed(&ed, "iy<esc>");

    // Same rule `:q` has -- unsaved work isn't discarded silently.
    switch (try keys.feed(&ed, ":e other<cr>")) {
        .none => {},
        else => try testz.fail(),
    }
    try testz.expectTrue(std.mem.startsWith(u8, ed.status.items, "E37:"));

    switch (try keys.feed(&ed, ":e! other<cr>")) {
        .edit => |path| try testz.expectEqualStr(path.?, "other"),
        else => try testz.fail(),
    }
}

// ─── Tree flattening ────────────────────────────────────────────────────
//
// The tree's directory reads need a filesystem, so these build the
// flattened list directly -- which is the part the pane actually renders
// and the part expand/collapse has to get right.

fn fakeEntry(alloc: std.mem.Allocator, name: []const u8, is_dir: bool, depth: usize) !zoe.tree.Entry {
    return .{
        .name = try alloc.dupe(u8, name),
        .path = try alloc.dupe(u8, name),
        .is_dir = is_dir,
        .depth = depth,
    };
}

/// `src/` expanded, holding `core.zig` and a nested `sub/` with one file
/// in it, then a top-level `README`.
fn fakeTree(alloc: std.mem.Allocator) !zoe.Tree {
    var t: zoe.Tree = .{ .alloc = alloc, .root = try alloc.dupe(u8, "/tmp") };
    try t.entries.append(alloc, try fakeEntry(alloc, "src", true, 0));
    t.entries.items[0].expanded = true;
    try t.entries.append(alloc, try fakeEntry(alloc, "core.zig", false, 1));
    try t.entries.append(alloc, try fakeEntry(alloc, "sub", true, 1));
    t.entries.items[2].expanded = true;
    try t.entries.append(alloc, try fakeEntry(alloc, "deep.zig", false, 2));
    try t.entries.append(alloc, try fakeEntry(alloc, "README", false, 0));
    return t;
}

pub fn treeWidestColsIncludesIndentAndIconTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var t = try fakeTree(alloc);
    defer t.deinit();

    const ic = zoe.tree.icon_cols;
    // "deep.zig" at depth 2: 2*2 indent + icon + 8 name.
    try testz.expectEqual(t.widestCols(), 4 + ic + 8);
    // "src" at depth 0: icon + 3 name.
    try testz.expectEqual(t.at(0).?.cols(), ic + 3);
}

pub fn treeCollapseRemovesTheWholeSubtreeTest(io: std.Io, alloc: std.mem.Allocator) !void {
    var t = try fakeTree(alloc);
    defer t.deinit();
    try testz.expectEqual(t.len(), 5);

    // Collapsing `src` takes its nested `sub/` and that directory's own
    // child with it -- everything deeper, not just the immediate children.
    try t.toggle(io, 0);
    try testz.expectEqual(t.len(), 2);
    try testz.expectEqualStr(t.at(0).?.name, "src");
    try testz.expectFalse(t.at(0).?.expanded);
    try testz.expectEqualStr(t.at(1).?.name, "README");
}

pub fn treeCollapseOnAFileIsANoOpTest(io: std.Io, alloc: std.mem.Allocator) !void {
    var t = try fakeTree(alloc);
    defer t.deinit();

    try t.toggle(io, 4); // README
    try testz.expectEqual(t.len(), 5);
}

pub fn treeCollapsePullsTheCursorBackTest(io: std.Io, alloc: std.mem.Allocator) !void {
    var t = try fakeTree(alloc);
    defer t.deinit();
    t.cursor = 4;

    try t.toggle(io, 0);
    // The cursor was past the end of the shortened list.
    try testz.expectEqual(t.cursor, 1);
}

// ─── Column slicing for the buffer pane ─────────────────────────────────

pub fn sliceColsClipsToTheViewportTest(_: std.Io, _: std.mem.Allocator) !void {
    try testz.expectEqualStr(zoe.ui.sliceCols("abcdefgh", 0, 4), "abcd");
    try testz.expectEqualStr(zoe.ui.sliceCols("abcdefgh", 2, 3), "cde");
    // Past the end of the line is empty, not an error.
    try testz.expectEqualStr(zoe.ui.sliceCols("abc", 10, 4), "");
}

pub fn sliceColsCountsDisplayWidthTest(_: std.Io, _: std.mem.Allocator) !void {
    // Three double-width characters: six columns, nine bytes. Asking for
    // four columns gets two of them, not four bytes through the middle of
    // one.
    const cjk = "\u{65e5}\u{672c}\u{8a9e}";
    try testz.expectEqualStr(zoe.ui.sliceCols(cjk, 0, 4), "\u{65e5}\u{672c}");
    // A double-width character straddling the right edge is dropped
    // rather than half-drawn.
    try testz.expectEqualStr(zoe.ui.sliceCols(cjk, 0, 3), "\u{65e5}");
    try testz.expectEqualStr(zoe.ui.sliceCols(cjk, 2, 2), "\u{672c}");
}

// ─── Line-number gutter ────────────────────────────────────────────────

pub fn gutterWidthFloorsAtThreeDigitsTest(_: std.Io, _: std.mem.Allocator) !void {
    // Off means no gutter at all.
    try testz.expectEqual(zoe.ui.gutterWidthFor(.off, 9999), 0);
    // 1..999 lines: three digit cells plus a separator space.
    try testz.expectEqual(zoe.ui.gutterWidthFor(.absolute, 1), 4);
    try testz.expectEqual(zoe.ui.gutterWidthFor(.absolute, 999), 4);
    // A fourth (then fifth) digit widens it a column at a time.
    try testz.expectEqual(zoe.ui.gutterWidthFor(.absolute, 1000), 5);
    try testz.expectEqual(zoe.ui.gutterWidthFor(.relative, 12345), 6);
}

pub fn gutterCellTextRightAlignsAbsoluteNumbersTest(_: std.Io, _: std.mem.Allocator) !void {
    var buf: [32]u8 = undefined;
    // Width 4 = three digit cells + one separator. Line 0 shows "1".
    try testz.expectEqualStr(zoe.ui.gutterCellText(&buf, .absolute, 4, 0, 0, false), "  1 ");
    try testz.expectEqualStr(zoe.ui.gutterCellText(&buf, .absolute, 4, 41, 0, false), " 42 ");
    // Past the last buffer line: a blank cell, like the space beside vim's `~`.
    try testz.expectEqualStr(zoe.ui.gutterCellText(&buf, .absolute, 4, 100, 0, true), "    ");
}

pub fn gutterCellTextRelativeKeepsTheCaretLineAbsoluteTest(_: std.Io, _: std.mem.Allocator) !void {
    var buf: [32]u8 = undefined;
    const cursor_line: usize = 10;
    // The caret's own row shows its absolute number...
    try testz.expectEqualStr(zoe.ui.gutterCellText(&buf, .relative, 4, 10, cursor_line, false), " 11 ");
    // ...every other row shows its distance from the caret.
    try testz.expectEqualStr(zoe.ui.gutterCellText(&buf, .relative, 4, 7, cursor_line, false), "  3 ");
    try testz.expectEqualStr(zoe.ui.gutterCellText(&buf, .relative, 4, 13, cursor_line, false), "  3 ");
}

// ─── Syntax highlighting (tree-sitter) ──────────────────────────────────

const syntax = zoe.syntax;

pub fn themeColorForWalksDottedPrefixesTest(_: std.Io, _: std.mem.Allocator) !void {
    var theme = syntax.Theme.initDefault();
    // An exact group has a colour.
    try testz.expectTrue(theme.colorFor("keyword") != null);
    // A dotted name with no mapping of its own falls back to the nearest
    // prefix that has one: `keyword.function` -> `keyword`.
    try testz.expectEqual(theme.colorFor("keyword.function.macro").?.r, theme.colorFor("keyword").?.r);
    // The walk stops at the *first* known prefix, so a name whose prefix
    // is itself mapped resolves to that, not further up.
    try testz.expectEqual(theme.colorFor("string.special.key").?.r, theme.colorFor("string.special").?.r);
    // `@none` and unknown groups get nothing.
    try testz.expectTrue(theme.colorFor("none") == null);
    try testz.expectTrue(theme.colorFor("nonsense.group") == null);
    // An override by name takes effect for that group and its fallbacks.
    try testz.expectTrue(theme.setByName("keyword", .{ .r = 1, .g = 2, .b = 3 }));
    try testz.expectEqual(theme.colorFor("keyword.function").?.g, 2);
}

const grammar_test_dir = "zig-out/share/glyphwire/grammars";

/// The grammar `.so`s only exist after `zig build` has run the install
/// step; when they don't, the two tests below no-op rather than fail (a
/// bare `zig test` on this file has nothing to load).
fn grammarsInstalled(io: std.Io) bool {
    std.Io.Dir.cwd().access(io, grammar_test_dir ++ "/json/libtree-sitter-json.so", .{}) catch return false;
    return true;
}

pub fn syntaxRegistryLoadsBundledGrammarTest(io: std.Io, alloc: std.mem.Allocator) !void {
    if (!grammarsInstalled(io)) return;

    var reg = syntax.Registry.init(alloc, io, &.{grammar_test_dir}, &syntax.default_langs);
    defer reg.deinit();

    try testz.expectEqualStr(reg.nameForPath("pkg/data.json").?, "json");
    try testz.expectTrue(reg.nameForPath("notes.txt") == null);

    const g = reg.get("json") orelse return error.GrammarMissing;
    try testz.expectTrue(g.language.abiVersion() >= syntax.min_abi_version);
}

pub fn syntaxHighlightsJsonSpansTest(io: std.Io, alloc: std.mem.Allocator) !void {
    if (!grammarsInstalled(io)) return;

    var reg = syntax.Registry.init(alloc, io, &.{grammar_test_dir}, &syntax.default_langs);
    defer reg.deinit();
    const g = reg.get("json") orelse return error.GrammarMissing;

    var hl = try syntax.Highlighter.init(alloc, syntax.Theme.initDefault());
    defer hl.deinit();
    try hl.setLanguage("json", g);

    const src = "{\"a\": 12}";
    var buf = try Buffer.initFromText(alloc, src);
    defer buf.deinit();
    try hl.reparse(&buf);
    try testz.expectTrue(hl.ready());

    var spans: std.ArrayList(syntax.Span) = .empty;
    defer spans.deinit(alloc);
    try hl.lineSpans(0, src.len, &spans);

    // The string key and the number are both captured; every span must
    // sit inside the line and be non-empty.
    try testz.expectTrue(spans.items.len >= 2);
    for (spans.items) |sp| {
        try testz.expectTrue(sp.start < sp.end);
        try testz.expectTrue(sp.end <= src.len);
    }
    // `12` is at bytes 6..8 -- some span must cover it.
    var covers_number = false;
    for (spans.items) |sp| {
        if (sp.start <= 6 and sp.end >= 7) covers_number = true;
    }
    try testz.expectTrue(covers_number);
}

// ─── Incremental reparse: the buffer edit journal ───────────────────────

pub fn bufferJournalsEditsOnlyWhileTrackingTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var buf = try Buffer.initFromText(alloc, "abc\ndef\n");
    defer buf.deinit();

    // Off by default -- nothing is recorded.
    try buf.insert(1, "X");
    try testz.expectEqual(buf.pending_edits.items.len, 0);

    buf.track_edits = true;

    // "aXbc\ndef\n": insert "YY" just before the first newline (offset 4).
    try buf.insert(4, "YY");
    try testz.expectEqual(buf.pending_edits.items.len, 1);
    {
        const e = buf.pending_edits.items[0];
        try testz.expectEqual(e.start_byte, 4);
        try testz.expectEqual(e.old_end_byte, 4);
        try testz.expectEqual(e.new_end_byte, 6);
        try testz.expectEqual(e.start_point.line, 0);
        try testz.expectEqual(e.start_point.col, 4);
        try testz.expectEqual(e.new_end_point.line, 0);
        try testz.expectEqual(e.new_end_point.col, 6);
    }

    // "aXbcYY\ndef\n": delete 3 bytes from offset 5 -- "Y\nd", straddling
    // the newline, so the old end is on the next line.
    try buf.delete(5, 3);
    try testz.expectEqual(buf.pending_edits.items.len, 2);
    {
        const e = buf.pending_edits.items[1];
        try testz.expectEqual(e.start_byte, 5);
        try testz.expectEqual(e.old_end_byte, 8);
        try testz.expectEqual(e.new_end_byte, 5);
        try testz.expectEqual(e.start_point.line, 0);
        try testz.expectEqual(e.old_end_point.line, 1);
        try testz.expectEqual(e.old_end_point.col, 1);
    }

    buf.clearEdits();
    try testz.expectEqual(buf.pending_edits.items.len, 0);
    try testz.expectFalse(buf.edits_overflowed);
}

pub fn bufferJournalOverflowSetsFlagTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var buf = try Buffer.initFromText(alloc, "");
    defer buf.deinit();
    buf.track_edits = true;

    // Way past the 512 cap: the log is dropped and the flag latches.
    var i: usize = 0;
    while (i < 600) : (i += 1) try buf.insert(buf.len(), "x");
    try testz.expectTrue(buf.edits_overflowed);
    try testz.expectEqual(buf.pending_edits.items.len, 0);

    buf.clearEdits();
    try testz.expectFalse(buf.edits_overflowed);
}

// ─── Incremental reparse equivalence ───────────────────────────────────

pub fn syntaxIncrementalReparseMatchesFullTest(io: std.Io, alloc: std.mem.Allocator) !void {
    if (!grammarsInstalled(io)) return;

    var reg = syntax.Registry.init(alloc, io, &.{grammar_test_dir}, &syntax.default_langs);
    defer reg.deinit();
    const g = reg.get("json") orelse return error.GrammarMissing;

    const src = "{\n  \"a\": 1,\n  \"b\": 2\n}\n";
    var buf = try Buffer.initFromText(alloc, src);
    defer buf.deinit();
    buf.track_edits = true;

    var inc = try syntax.Highlighter.init(alloc, syntax.Theme.initDefault());
    defer inc.deinit();
    try inc.setLanguage("json", g);
    try inc.reparse(&buf);

    // Widen the `1` to `123`, an edit contained in one line.
    const at = std.mem.indexOfScalar(u8, src, '1').?;
    try buf.delete(at, 1);
    try buf.insert(at, "123");
    for (buf.pending_edits.items) |e| inc.applyEdit(e);

    var changed: std.ArrayList(syntax.ByteRange) = .empty;
    defer changed.deinit(alloc);
    _ = try inc.reparseIncremental(&buf, &changed);
    buf.clearEdits();
    try testz.expectTrue(changed.items.len >= 1);

    // A fresh full parse of the final text must give identical spans.
    var full = try syntax.Highlighter.init(alloc, syntax.Theme.initDefault());
    defer full.deinit();
    try full.setLanguage("json", g);
    try full.reparse(&buf);

    var a: std.ArrayList(syntax.Span) = .empty;
    defer a.deinit(alloc);
    var b: std.ArrayList(syntax.Span) = .empty;
    defer b.deinit(alloc);

    var line: usize = 0;
    while (line < buf.lineCount()) : (line += 1) {
        const ls = buf.lineStart(line);
        const le = buf.lineEnd(line);
        try inc.lineSpans(ls, le, &a);
        try full.lineSpans(ls, le, &b);
        try testz.expectEqual(a.items.len, b.items.len);
        for (a.items, b.items) |x, y| {
            try testz.expectEqual(x.start, y.start);
            try testz.expectEqual(x.end, y.end);
            try testz.expectEqual(x.color.r, y.color.r);
            try testz.expectEqual(x.color.g, y.color.g);
            try testz.expectEqual(x.color.b, y.color.b);
        }
    }
}

// ─── Injection queries ────────────────────────────────────────────────

fn markdownStackInstalled(io: std.Io) bool {
    std.Io.Dir.cwd().access(io, grammar_test_dir ++ "/markdown/libtree-sitter-markdown.so", .{}) catch return false;
    std.Io.Dir.cwd().access(io, grammar_test_dir ++ "/markdown/injections.scm", .{}) catch return false;
    std.Io.Dir.cwd().access(io, grammar_test_dir ++ "/markdown_inline/libtree-sitter-markdown_inline.so", .{}) catch return false;
    return true;
}

/// The span covering line-relative byte `off`, or null.
fn spanAt(spans: []const syntax.Span, off: usize) ?syntax.Span {
    for (spans) |s| {
        if (off >= s.start and off < s.end) return s;
    }
    return null;
}

pub fn syntaxInjectionHighlightsFencedCodeTest(io: std.Io, alloc: std.mem.Allocator) !void {
    if (!grammarsInstalled(io) or !markdownStackInstalled(io)) return;

    var reg = syntax.Registry.init(alloc, io, &.{grammar_test_dir}, &syntax.default_langs);
    defer reg.deinit();
    const md = reg.get("markdown") orelse return error.GrammarMissing;

    const src = "# Title\n\n```json\n{ \"x\": 42 }\n```\n";
    var buf = try Buffer.initFromText(alloc, src);
    defer buf.deinit();

    // Line 3 (0-based) is the JSON object inside the fence; `42` sits at
    // line-relative bytes 7..9. markdown paints the whole fenced block
    // `@text.literal` (green); only the injected JSON grammar paints `42`
    // with the number colour.
    const ls = buf.lineStart(3);
    const le = buf.lineEnd(3);
    const number = syntax.Theme.initDefault().colorFor("number").?;

    var spans: std.ArrayList(syntax.Span) = .empty;
    defer spans.deinit(alloc);

    var on = try syntax.Highlighter.init(alloc, syntax.Theme.initDefault());
    defer on.deinit();
    on.configureInjections(&reg, true);
    try on.setLanguage("markdown", md);
    try on.reparse(&buf);
    try on.lineSpans(ls, le, &spans);
    const on_span = spanAt(spans.items, 7) orelse return error.NoSpanOverNumber;
    try testz.expectEqual(on_span.color.r, number.r);
    try testz.expectEqual(on_span.color.g, number.g);
    try testz.expectEqual(on_span.color.b, number.b);

    var off = try syntax.Highlighter.init(alloc, syntax.Theme.initDefault());
    defer off.deinit();
    off.configureInjections(&reg, false);
    try off.setLanguage("markdown", md);
    try off.reparse(&buf);
    try off.lineSpans(ls, le, &spans);
    if (spanAt(spans.items, 7)) |s| {
        try testz.expectFalse(s.color.r == number.r and s.color.g == number.g and s.color.b == number.b);
    }
}

pub fn syntaxInjectionSurvivesIncrementalEditTest(io: std.Io, alloc: std.mem.Allocator) !void {
    if (!grammarsInstalled(io) or !markdownStackInstalled(io)) return;

    var reg = syntax.Registry.init(alloc, io, &.{grammar_test_dir}, &syntax.default_langs);
    defer reg.deinit();
    const md = reg.get("markdown") orelse return error.GrammarMissing;

    const src = "```json\n{ \"x\": 1 }\n```\n";
    var buf = try Buffer.initFromText(alloc, src);
    defer buf.deinit();
    buf.track_edits = true;

    var hl = try syntax.Highlighter.init(alloc, syntax.Theme.initDefault());
    defer hl.deinit();
    hl.configureInjections(&reg, true);
    try hl.setLanguage("markdown", md);
    try hl.reparse(&buf);

    var spans: std.ArrayList(syntax.Span) = .empty;
    defer spans.deinit(alloc);
    try hl.lineSpans(buf.lineStart(1), buf.lineEnd(1), &spans);
    const before = spans.items.len;
    try testz.expectTrue(before >= 1);

    // Edit inside the fence, then reparse incrementally: the injection is
    // rebuilt and the JSON grammar still colours the line.
    const at = std.mem.indexOfScalar(u8, src, '1').?;
    try buf.insert(at, "23");
    for (buf.pending_edits.items) |e| hl.applyEdit(e);
    var changed: std.ArrayList(syntax.ByteRange) = .empty;
    defer changed.deinit(alloc);
    _ = try hl.reparseIncremental(&buf, &changed);
    buf.clearEdits();

    try hl.lineSpans(buf.lineStart(1), buf.lineEnd(1), &spans);
    try testz.expectTrue(spans.items.len >= 1);
}
