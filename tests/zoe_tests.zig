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

pub fn commandLineUnknownCommandReportsE492Test(_: std.Io, alloc: std.mem.Allocator) !void {
    var ed = try Editor.initFromText(alloc, "x", null);
    defer ed.deinit();
    _ = try keys.feed(&ed, ":nope<cr>");
    try testz.expectTrue(std.mem.startsWith(u8, ed.status.items, "E492:"));
    try testz.expectEqual(ed.mode, .normal);
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
