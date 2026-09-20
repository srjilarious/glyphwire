// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: GPL-3.0-or-later

//! `src/lineedit.zig`: the one-line text field shared by gw-shell's
//! prompt, salacommander's path row and dialog fields, and zoe's `:`
//! command line. The pure UTF-8 / display-width helpers came from
//! gw-shell (they were `shell/lineedit.zig`), so their tests did too --
//! `LineEdit` itself is exercised below them.

const std = @import("std");
const testz = @import("testz");
const glyphwire = @import("glyphwire");

const lineedit = glyphwire.lineedit;
const LineEdit = glyphwire.LineEdit;

// ─── lineedit: codepoint / display-width helpers ───────────────────────

pub fn lineeditPrevBoundaryStepsWholeCodepointsTest(_: std.Io, _: std.mem.Allocator) !void {
    // "日本語": 3 codepoints, 3 bytes each -> 9 bytes total.
    const buf = "日本語";
    try testz.expectEqual(lineedit.prevBoundary(buf, 9), @as(usize, 6));
    try testz.expectEqual(lineedit.prevBoundary(buf, 6), @as(usize, 3));
    try testz.expectEqual(lineedit.prevBoundary(buf, 3), @as(usize, 0));
    try testz.expectEqual(lineedit.prevBoundary(buf, 0), @as(usize, 0));
}

pub fn lineeditNextBoundaryStepsWholeCodepointsTest(_: std.Io, _: std.mem.Allocator) !void {
    const buf = "日本語";
    try testz.expectEqual(lineedit.nextBoundary(buf, 0), @as(usize, 3));
    try testz.expectEqual(lineedit.nextBoundary(buf, 3), @as(usize, 6));
    try testz.expectEqual(lineedit.nextBoundary(buf, 6), @as(usize, 9));
    try testz.expectEqual(lineedit.nextBoundary(buf, 9), @as(usize, 9));
}

pub fn lineeditBoundariesWalkMixedAsciiAndWideTest(_: std.Io, _: std.mem.Allocator) !void {
    // "aあb": a=1 byte, あ=3 bytes, b=1 byte -> boundaries at 0,1,4,5.
    const buf = "aあb";
    try testz.expectEqual(buf.len, @as(usize, 5));
    try testz.expectEqual(lineedit.nextBoundary(buf, 0), @as(usize, 1));
    try testz.expectEqual(lineedit.nextBoundary(buf, 1), @as(usize, 4));
    try testz.expectEqual(lineedit.nextBoundary(buf, 4), @as(usize, 5));
    try testz.expectEqual(lineedit.prevBoundary(buf, 5), @as(usize, 4));
    try testz.expectEqual(lineedit.prevBoundary(buf, 4), @as(usize, 1));
    try testz.expectEqual(lineedit.prevBoundary(buf, 1), @as(usize, 0));
}

pub fn lineeditNextBoundaryAdvancesOnInvalidLeadByteTest(_: std.Io, _: std.mem.Allocator) !void {
    // A stray 0xFF is not a valid UTF-8 lead byte; advance one byte
    // rather than looping forever.
    const buf = "\xff\xff";
    try testz.expectEqual(lineedit.nextBoundary(buf, 0), @as(usize, 1));
    try testz.expectEqual(lineedit.nextBoundary(buf, 1), @as(usize, 2));
}

pub fn lineeditDisplayColSumsWideCharsAsTwoTest(_: std.Io, _: std.mem.Allocator) !void {
    const buf = "aあb";
    try testz.expectEqual(lineedit.displayCol(buf, 0), @as(usize, 0));
    try testz.expectEqual(lineedit.displayCol(buf, 1), @as(usize, 1)); // past "a"
    try testz.expectEqual(lineedit.displayCol(buf, 4), @as(usize, 3)); // past "aあ"
    try testz.expectEqual(lineedit.displayCol(buf, 5), @as(usize, 4)); // past "aあb"
}

pub fn lineeditDisplayColIsByteCountForAsciiTest(_: std.Io, _: std.mem.Allocator) !void {
    const buf = "ls -l";
    try testz.expectEqual(lineedit.displayCol(buf, 3), @as(usize, 3));
    try testz.expectEqual(lineedit.displayCol(buf, buf.len), @as(usize, 5));
}

pub fn lineeditCellWidthCountsGridCellsNotBytesTest(_: std.Io, _: std.mem.Allocator) !void {
    try testz.expectEqual(lineedit.cellWidth("あ"), @as(usize, 2)); // 3 bytes, 2 cells
    try testz.expectEqual(lineedit.cellWidth("ab"), @as(usize, 2));
    try testz.expectEqual(lineedit.cellWidth("日本語"), @as(usize, 6));
    try testz.expectEqual(lineedit.cellWidth(""), @as(usize, 0));
}

// ─── lineedit.wordRight / wordLeft ─────────────────────────────────────

pub fn wordRightStopsOnEachPathSegmentTest(_: std.Io, _: std.mem.Allocator) !void {
    const buf = "cat /home/jeff";
    // "cat" -> space -> "/" -> "home" -> "/" -> "jeff"
    var i: usize = 0;
    i = lineedit.wordRightFrom(buf, i);
    try testz.expectEqualStr("cat", buf[0..i]);
    i = lineedit.wordRightFrom(buf, i);
    try testz.expectEqualStr("cat /", buf[0..i]);
    i = lineedit.wordRightFrom(buf, i);
    try testz.expectEqualStr("cat /home", buf[0..i]);
    i = lineedit.wordRightFrom(buf, i);
    try testz.expectEqualStr("cat /home/", buf[0..i]);
    i = lineedit.wordRightFrom(buf, i);
    try testz.expectEqualStr(buf, buf[0..i]);
}

pub fn wordLeftStopsOnEachPathSegmentTest(_: std.Io, _: std.mem.Allocator) !void {
    const buf = "cat /home/jeff";
    var i: usize = buf.len;
    i = lineedit.wordLeftFrom(buf, i);
    try testz.expectEqualStr("cat /home/", buf[0..i]);
    i = lineedit.wordLeftFrom(buf, i);
    try testz.expectEqualStr("cat /home", buf[0..i]);
    i = lineedit.wordLeftFrom(buf, i);
    try testz.expectEqualStr("cat /", buf[0..i]);
    // Landing here puts the cursor right before the `/`, with the space
    // still to its left -- the space itself is only consumed once the
    // cursor sits immediately after it, one more hop below (mirrors how
    // a lone space between two different-class runs takes its own hop
    // only when a hop starts adjacent to it).
    i = lineedit.wordLeftFrom(buf, i);
    try testz.expectEqualStr("cat ", buf[0..i]);
    i = lineedit.wordLeftFrom(buf, i);
    try testz.expectEqual(i, 0);
}

pub fn wordRightGroupsAPunctuationRunAsOneStopTest(_: std.Io, _: std.mem.Allocator) !void {
    // A run of the same punctuation class (e.g. `--flag`) is one hop, not
    // one stop per character.
    const buf = "run --flag";
    var i: usize = 0;
    i = lineedit.wordRightFrom(buf, i);
    try testz.expectEqualStr("run", buf[0..i]);
    i = lineedit.wordRightFrom(buf, i);
    try testz.expectEqualStr("run --", buf[0..i]);
    i = lineedit.wordRightFrom(buf, i);
    try testz.expectEqualStr(buf, buf[0..i]);
}

pub fn wordRightTreatsUnderscoreAsWordCharTest(_: std.Io, _: std.mem.Allocator) !void {
    const buf = "my_var.txt";
    const i = lineedit.wordRightFrom(buf, 0);
    try testz.expectEqualStr("my_var", buf[0..i]); // underscore stays in the word run
}

pub fn wordRightAtEndOfLineStaysPutTest(_: std.Io, _: std.mem.Allocator) !void {
    const buf = "cat foo";
    try testz.expectEqual(lineedit.wordRightFrom(buf, buf.len), buf.len);
}

pub fn wordLeftAtStartOfLineStaysPutTest(_: std.Io, _: std.mem.Allocator) !void {
    const buf = "cat foo";
    try testz.expectEqual(lineedit.wordLeftFrom(buf, 0), @as(usize, 0));
}

// ─── lineedit.flattenNewlines ─────────────────────────────────────────

pub fn flattenNewlinesCollapsesRunsToSingleSpaceTest(_: std.Io, alloc: std.mem.Allocator) !void {
    // A pasted multi-select list: each newline (and a CRLF run, and a
    // trailing newline) becomes exactly one space.
    const got = try lineedit.flattenNewlines(alloc, "src\ndocs\r\n\r\nbuild.zig\n");
    defer alloc.free(got);
    try testz.expectEqualStr("src docs build.zig ", got);
}

pub fn flattenNewlinesLeavesNewlineFreeTextAloneTest(_: std.Io, alloc: std.mem.Allocator) !void {
    // No newline: same bytes back, but a fresh allocation the caller owns.
    const src = "ls -l 'my dir'";
    const got = try lineedit.flattenNewlines(alloc, src);
    defer alloc.free(got);
    try testz.expectEqualStr(src, got);
    try testz.expectTrue(got.ptr != src.ptr);

    const empty = try lineedit.flattenNewlines(alloc, "");
    defer alloc.free(empty);
    try testz.expectEqual(empty.len, 0);
}

// ─── LineEdit: movement ────────────────────────────────────────────────

pub fn lineEditStartsWithTheCaretAtTheEndTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var e = try LineEdit.init(alloc, "/home/me/code");
    defer e.deinit(alloc);
    try testz.expectEqualStr("/home/me/code", e.text());
    try testz.expectEqual(e.caret, e.text().len);
}

pub fn lineEditHomeAndEndJumpToTheEndsTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var e = try LineEdit.init(alloc, "ls -l");
    defer e.deinit(alloc);
    try testz.expectTrue(e.home());
    try testz.expectEqual(e.caret, @as(usize, 0));
    // Already there: nothing moved, so a caller can skip the repaint.
    try testz.expectFalse(e.home());
    try testz.expectTrue(e.end());
    try testz.expectEqual(e.caret, @as(usize, 5));
    try testz.expectFalse(e.end());
}

pub fn lineEditArrowsStepWholeCodepointsTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var e = try LineEdit.init(alloc, "aあb"); // 1 + 3 + 1 bytes
    defer e.deinit(alloc);
    try testz.expectTrue(e.left());
    try testz.expectEqual(e.caret, @as(usize, 4));
    try testz.expectTrue(e.left());
    try testz.expectEqual(e.caret, @as(usize, 1)); // over the whole あ
    try testz.expectTrue(e.right());
    try testz.expectEqual(e.caret, @as(usize, 4));
}

pub fn lineEditWordJumpsStopAtPathSeparatorsTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var e = try LineEdit.init(alloc, "/home/jeff");
    defer e.deinit(alloc);
    _ = e.wordLeft();
    try testz.expectEqualStr("/home/", e.text()[0..e.caret]);
    _ = e.wordLeft();
    try testz.expectEqualStr("/home", e.text()[0..e.caret]);
    _ = e.wordRight();
    try testz.expectEqualStr("/home/", e.text()[0..e.caret]);
}

pub fn lineEditMoveToSnapsOffAWideCharactersSecondHalfTest(_: std.Io, alloc: std.mem.Allocator) !void {
    // A click landing inside あ (bytes 1..4) belongs before it: there is
    // no caret offset inside one codepoint.
    var e = try LineEdit.init(alloc, "aあb");
    defer e.deinit(alloc);
    _ = e.moveTo(2);
    try testz.expectEqual(e.caret, @as(usize, 1));
    _ = e.moveTo(3);
    try testz.expectEqual(e.caret, @as(usize, 1));
    // Past the end clamps rather than wrapping or panicking.
    _ = e.moveTo(999);
    try testz.expectEqual(e.caret, e.text().len);
}

// ─── LineEdit: editing ─────────────────────────────────────────────────

pub fn lineEditInsertsAtTheCaretTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var e = try LineEdit.init(alloc, "ls -l");
    defer e.deinit(alloc);
    _ = e.home();
    try testz.expectTrue(try e.insert(alloc, "sudo "));
    try testz.expectEqualStr("sudo ls -l", e.text());
    try testz.expectEqual(e.caret, @as(usize, 5));
}

pub fn lineEditInsertDropsControlCharactersTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var e: LineEdit = .{};
    defer e.deinit(alloc);
    _ = try e.insert(alloc, "a\x07b\x7fc");
    try testz.expectEqualStr("abc", e.text());
    // Nothing but controls changes nothing, so no repaint is owed.
    try testz.expectFalse(try e.insert(alloc, "\x00\x1b"));
}

pub fn lineEditInsertDropsNewlinesUnderTheDefaultPolicyTest(_: std.Io, alloc: std.mem.Allocator) !void {
    // A path field: a pasted newline is a mistake, not a separator.
    var e: LineEdit = .{ .controls = .drop };
    defer e.deinit(alloc);
    _ = try e.insert(alloc, "/home/me\n/tmp\n");
    try testz.expectEqualStr("/home/me/tmp", e.text());
}

pub fn lineEditInsertFlattensNewlineRunsToOneSpaceTest(_: std.Io, alloc: std.mem.Allocator) !void {
    // A command line: a column of copied paths becomes arguments, and a
    // CRLF run is one separator rather than two.
    var e: LineEdit = .{ .controls = .flatten_newlines };
    defer e.deinit(alloc);
    _ = try e.insert(alloc, "src\r\n\r\ndocs\nbuild.zig");
    try testz.expectEqualStr("src docs build.zig", e.text());
    try testz.expectEqual(e.caret, e.text().len);
}

pub fn lineEditDeletesStepWholeCodepointsTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var e = try LineEdit.init(alloc, "aあb");
    defer e.deinit(alloc);
    _ = e.left(); // between あ and b
    try testz.expectTrue(e.deleteBackward());
    try testz.expectEqualStr("ab", e.text());
    try testz.expectEqual(e.caret, @as(usize, 1));
    try testz.expectTrue(e.deleteForward());
    try testz.expectEqualStr("a", e.text());
    // Nothing left in either direction.
    try testz.expectFalse(e.deleteForward());
    _ = e.home();
    try testz.expectFalse(e.deleteBackward());
}

pub fn lineEditCtrlBackspaceEatsOnePathSegmentTest(_: std.Io, alloc: std.mem.Allocator) !void {
    // Class-based, so it stops at the `/` rather than eating the whole
    // path the way bash's whitespace-only unix-word-rubout would.
    var e = try LineEdit.init(alloc, "cat /home/jeff");
    defer e.deinit(alloc);
    try testz.expectTrue(e.deleteWordBackward());
    try testz.expectEqualStr("cat /home/", e.text());
    try testz.expectTrue(e.deleteWordBackward());
    try testz.expectEqualStr("cat /home", e.text());
}

pub fn lineEditCtrlDeleteEatsTheWordAheadTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var e = try LineEdit.init(alloc, "cat foo.txt");
    defer e.deinit(alloc);
    _ = e.home();
    try testz.expectTrue(e.deleteWordForward());
    try testz.expectEqualStr(" foo.txt", e.text());
    try testz.expectEqual(e.caret, @as(usize, 0));
}

pub fn lineEditKillToStartAndEndSplitAtTheCaretTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var e = try LineEdit.init(alloc, "cat foo.txt");
    defer e.deinit(alloc);
    _ = e.moveTo(4);
    try testz.expectTrue(e.killToStart()); // ctrl+u
    try testz.expectEqualStr("foo.txt", e.text());
    try testz.expectEqual(e.caret, @as(usize, 0));

    _ = e.moveTo(3);
    try testz.expectTrue(e.killToEnd()); // ctrl+k
    try testz.expectEqualStr("foo", e.text());
    try testz.expectFalse(e.killToEnd());
}

pub fn lineEditSetTextReplacesTheWholeLineTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var e = try LineEdit.init(alloc, "partial");
    defer e.deinit(alloc);
    _ = e.home();
    try e.setText(alloc, "git status");
    try testz.expectEqualStr("git status", e.text());
    try testz.expectEqual(e.caret, e.text().len); // caret follows to the end
    e.clear();
    try testz.expectTrue(e.isEmpty());
    try testz.expectEqual(e.caret, @as(usize, 0));
}

// ─── LineEdit.handleKey ────────────────────────────────────────────────

pub fn handleKeyMapsTheReadlineChordsTest(_: std.Io, alloc: std.mem.Allocator) !void {
    const ctrl: glyphwire.Mods = .{ .ctrl = true };
    var e = try LineEdit.init(alloc, "cat /home/jeff");
    defer e.deinit(alloc);

    try testz.expectEqual(e.handleKey("a", ctrl), .moved); // ctrl+a
    try testz.expectEqual(e.caret, @as(usize, 0));
    try testz.expectEqual(e.handleKey("e", ctrl), .moved); // ctrl+e
    try testz.expectEqual(e.caret, e.text().len);
    try testz.expectEqual(e.handleKey("left", ctrl), .moved); // word jump
    try testz.expectEqualStr("cat /home/", e.text()[0..e.caret]);
    try testz.expectEqual(e.handleKey("backspace", ctrl), .edited);
    try testz.expectEqualStr("cat /homejeff", e.text());
    try testz.expectEqual(e.handleKey("u", ctrl), .edited); // ctrl+u
    try testz.expectEqualStr("jeff", e.text());
}

pub fn handleKeyReportsEnterAndEscapeWithoutTouchingTheLineTest(_: std.Io, alloc: std.mem.Allocator) !void {
    // What they mean is the caller's: run the command, go to the path,
    // leave the field. The field only names them.
    var e = try LineEdit.init(alloc, "ls");
    defer e.deinit(alloc);
    try testz.expectEqual(e.handleKey("enter", .{}), .submit);
    try testz.expectEqual(e.handleKey("kp_enter", .{}), .submit);
    try testz.expectEqual(e.handleKey("escape", .{}), .cancel);
    try testz.expectEqualStr("ls", e.text());
}

pub fn handleKeyLeavesAltAndSuperChordsToTheApplicationTest(_: std.Io, alloc: std.mem.Allocator) !void {
    // salacommander's Alt+D opens the field; it must not also be eaten by
    // it, and neither should a window-manager super chord.
    var e = try LineEdit.init(alloc, "ls");
    defer e.deinit(alloc);
    try testz.expectEqual(e.handleKey("d", .{ .alt = true }), .ignored);
    try testz.expectEqual(e.handleKey("left", .{ .alt = true }), .ignored);
    try testz.expectEqual(e.handleKey("e", .{ .super = true }), .ignored);
}

pub fn handleKeyIgnoresAKeyThatChangedNothingTest(_: std.Io, alloc: std.mem.Allocator) !void {
    // Backspace at column 0 and Left at column 0 are `.ignored`, not
    // `.edited`/`.moved`: there is nothing to repaint.
    var e = try LineEdit.init(alloc, "ls");
    defer e.deinit(alloc);
    _ = e.home();
    try testz.expectEqual(e.handleKey("backspace", .{}), .ignored);
    try testz.expectEqual(e.handleKey("left", .{}), .ignored);
    try testz.expectEqual(e.handleKey("F5", .{}), .ignored);
    try testz.expectEqualStr("ls", e.text());
}

// ─── LineEdit: display ─────────────────────────────────────────────────

pub fn lineEditCaretColCountsColumnsNotBytesTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var e = try LineEdit.init(alloc, "aあb");
    defer e.deinit(alloc);
    try testz.expectEqual(e.caret, @as(usize, 5)); // bytes
    try testz.expectEqual(e.caretCol(), @as(usize, 4)); // columns: 1 + 2 + 1
    try testz.expectEqual(e.width(), @as(usize, 4));
    _ = e.left();
    try testz.expectEqual(e.caretCol(), @as(usize, 3));
}

pub fn offsetAtColLandsOnBoundariesOnlyTest(_: std.Io, _: std.mem.Allocator) !void {
    const text = "aあb";
    try testz.expectEqual(lineedit.offsetAtCol(text, 0, 0), @as(usize, 0));
    try testz.expectEqual(lineedit.offsetAtCol(text, 0, 1), @as(usize, 1));
    // One column into あ is not far enough to be past it.
    try testz.expectEqual(lineedit.offsetAtCol(text, 0, 2), @as(usize, 1));
    try testz.expectEqual(lineedit.offsetAtCol(text, 0, 3), @as(usize, 4));
    try testz.expectEqual(lineedit.offsetAtCol(text, 0, 99), @as(usize, 5));
}
