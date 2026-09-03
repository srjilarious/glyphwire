const std = @import("std");
const testz = @import("testz");

// glyphwire-shell is an executable (no importable module), but its pure
// prompt helpers are gathered into the `shell_support` module (see
// build.zig) precisely so they can be exercised here.
const wordsplit = @import("shell_support").wordsplit;
const complete = @import("shell_support").complete;
const glob = @import("shell_support").glob;
const handshake = @import("shell_support").handshake;
const history = @import("shell_support").history;
const keyencode = @import("shell_support").keyencode;
const lineedit = @import("shell_support").lineedit;

// ─── wordsplit.split ────────────────────────────────────────────────────

pub fn splitPlainWordsTest(_: std.Io, alloc: std.mem.Allocator) !void {
    const toks = try wordsplit.split(alloc, "ls  -l   -a");
    defer wordsplit.freeTokens(alloc, toks);
    try testz.expectEqual(toks.len, 3);
    try testz.expectEqualStr("ls", toks[0]);
    try testz.expectEqualStr("-l", toks[1]);
    try testz.expectEqualStr("-a", toks[2]);
}

pub fn splitEmptyAndWhitespaceYieldsNoTokensTest(_: std.Io, alloc: std.mem.Allocator) !void {
    const a = try wordsplit.split(alloc, "");
    defer wordsplit.freeTokens(alloc, a);
    try testz.expectEqual(a.len, 0);

    const b = try wordsplit.split(alloc, "   \t  ");
    defer wordsplit.freeTokens(alloc, b);
    try testz.expectEqual(b.len, 0);
}

pub fn splitSingleQuotesKeepSpacesLiteralTest(_: std.Io, alloc: std.mem.Allocator) !void {
    const toks = try wordsplit.split(alloc, "cat 'my file.txt'");
    defer wordsplit.freeTokens(alloc, toks);
    try testz.expectEqual(toks.len, 2);
    try testz.expectEqualStr("cat", toks[0]);
    try testz.expectEqualStr("my file.txt", toks[1]);
}

pub fn splitDoubleQuotesKeepSpacesLiteralTest(_: std.Io, alloc: std.mem.Allocator) !void {
    const toks = try wordsplit.split(alloc, "echo \"a  b  c\"");
    defer wordsplit.freeTokens(alloc, toks);
    try testz.expectEqual(toks.len, 2);
    try testz.expectEqualStr("a  b  c", toks[1]);
}

pub fn splitAdjacentQuotedAndBareRunsJoinTest(_: std.Io, alloc: std.mem.Allocator) !void {
    const toks = try wordsplit.split(alloc, "ll='ls -l'");
    defer wordsplit.freeTokens(alloc, toks);
    try testz.expectEqual(toks.len, 1);
    try testz.expectEqualStr("ll=ls -l", toks[0]);
}

pub fn splitEmptyQuotesAreOneEmptyTokenTest(_: std.Io, alloc: std.mem.Allocator) !void {
    const toks = try wordsplit.split(alloc, "echo ''");
    defer wordsplit.freeTokens(alloc, toks);
    try testz.expectEqual(toks.len, 2);
    try testz.expectEqualStr("", toks[1]);
}

pub fn splitBackslashEscapesSpaceTest(_: std.Io, alloc: std.mem.Allocator) !void {
    const toks = try wordsplit.split(alloc, "touch my\\ file");
    defer wordsplit.freeTokens(alloc, toks);
    try testz.expectEqual(toks.len, 2);
    try testz.expectEqualStr("my file", toks[1]);
}

pub fn splitBackslashEscapesQuoteTest(_: std.Io, alloc: std.mem.Allocator) !void {
    const toks = try wordsplit.split(alloc, "echo it\\'s");
    defer wordsplit.freeTokens(alloc, toks);
    try testz.expectEqual(toks.len, 2);
    try testz.expectEqualStr("it's", toks[1]);
}

// ─── wordsplit.splitArgs (the `quoted` flag) ───────────────────────────

pub fn splitArgsFlagsQuotedTokensTest(_: std.Io, alloc: std.mem.Allocator) !void {
    const args = try wordsplit.splitArgs(alloc, "echo * '*' \"*\" \\*");
    defer wordsplit.freeArgs(alloc, args);
    try testz.expectEqual(args.len, 5);
    try testz.expectEqualStr("echo", args[0].text);
    try testz.expectTrue(!args[0].quoted);
    try testz.expectEqualStr("*", args[1].text);
    try testz.expectTrue(!args[1].quoted); // bare -> a glob pattern
    try testz.expectTrue(args[2].quoted); // '*'  -> literal
    try testz.expectTrue(args[3].quoted); // "*"  -> literal
    try testz.expectTrue(args[4].quoted); // \*   -> literal
}

// ─── wordsplit.quoteArg ───────────────────────────────────────────────

/// `quoteArg` output must re-split (via `split`) to exactly the one
/// original token -- that round trip is the whole contract.
fn expectQuoteArgRoundTrips(alloc: std.mem.Allocator, original: []const u8) !void {
    const quoted = try wordsplit.quoteArg(alloc, original);
    defer alloc.free(quoted);
    const toks = try wordsplit.split(alloc, quoted);
    defer wordsplit.freeTokens(alloc, toks);
    try testz.expectEqual(toks.len, 1);
    try testz.expectEqualStr(original, toks[0]);
}

pub fn quoteArgWrapsPlainPathTest(_: std.Io, alloc: std.mem.Allocator) !void {
    const quoted = try wordsplit.quoteArg(alloc, "photo.png");
    defer alloc.free(quoted);
    try testz.expectEqualStr("'photo.png'", quoted);
    try expectQuoteArgRoundTrips(alloc, "photo.png");
}

pub fn quoteArgRoundTripsSpacesTest(_: std.Io, alloc: std.mem.Allocator) !void {
    try expectQuoteArgRoundTrips(alloc, "my holiday pics/beach 2.jpg");
}

pub fn quoteArgRoundTripsEmbeddedSingleQuoteTest(_: std.Io, alloc: std.mem.Allocator) !void {
    const quoted = try wordsplit.quoteArg(alloc, "it's a photo.gif");
    defer alloc.free(quoted);
    try testz.expectEqualStr("'it'\\''s a photo.gif'", quoted);
    try expectQuoteArgRoundTrips(alloc, "it's a photo.gif");
}

pub fn quoteArgRoundTripsShellMetacharactersTest(_: std.Io, alloc: std.mem.Allocator) !void {
    try expectQuoteArgRoundTrips(alloc, "weird $name *.bmp;rm -rf~ (x).png");
}

// ─── glob.hasWildcard ─────────────────────────────────────────────────

pub fn hasWildcardTest(_: std.Io, _: std.mem.Allocator) !void {
    try testz.expectTrue(glob.hasWildcard("*.zig"));
    try testz.expectTrue(glob.hasWildcard("co?e"));
    try testz.expectTrue(glob.hasWildcard("f[ab]x"));
    try testz.expectTrue(!glob.hasWildcard("plain.txt"));
    try testz.expectTrue(!glob.hasWildcard("a\\*b")); // escaped star
    try testz.expectTrue(!glob.hasWildcard("f[ab")); // no closing ]
}

// ─── glob.match ───────────────────────────────────────────────────────

pub fn globMatchStarTest(_: std.Io, _: std.mem.Allocator) !void {
    try testz.expectTrue(glob.match("*.zig", "core.zig"));
    try testz.expectTrue(!glob.match("*.zig", "core.c"));
    try testz.expectTrue(glob.match("core.*", "core.zig"));
    try testz.expectTrue(glob.match("*", "anything"));
    try testz.expectTrue(glob.match("*", ""));
    try testz.expectTrue(glob.match("a*b*c", "axxbxxc"));
    try testz.expectTrue(!glob.match("a*b*c", "axxbxx"));
}

pub fn globMatchQuestionTest(_: std.Io, _: std.mem.Allocator) !void {
    try testz.expectTrue(glob.match("c?re.zig", "core.zig"));
    try testz.expectTrue(!glob.match("c?re.zig", "cre.zig"));
    try testz.expectTrue(!glob.match("c?re.zig", "coore.zig"));
}

pub fn globMatchClassTest(_: std.Io, _: std.mem.Allocator) !void {
    try testz.expectTrue(glob.match("[abc]at", "bat"));
    try testz.expectTrue(!glob.match("[abc]at", "dat"));
    try testz.expectTrue(glob.match("[!abc]at", "dat"));
    try testz.expectTrue(!glob.match("[!abc]at", "bat"));
    try testz.expectTrue(glob.match("[a-z].txt", "m.txt"));
    try testz.expectTrue(!glob.match("[a-z].txt", "M.txt"));
}

pub fn globMatchMalformedClassIsLiteralTest(_: std.Io, _: std.mem.Allocator) !void {
    try testz.expectTrue(glob.match("file[", "file["));
    try testz.expectTrue(!glob.match("file[", "file"));
}

pub fn splitUnterminatedQuoteRunsToEndOfLineTest(_: std.Io, alloc: std.mem.Allocator) !void {
    const toks = try wordsplit.split(alloc, "echo 'no close");
    defer wordsplit.freeTokens(alloc, toks);
    try testz.expectEqual(toks.len, 2);
    try testz.expectEqualStr("no close", toks[1]);
}

pub fn splitDoubleQuoteBackslashEscapesTest(_: std.Io, alloc: std.mem.Allocator) !void {
    const toks = try wordsplit.split(alloc, "echo \"a\\\"b\\\\c\"");
    defer wordsplit.freeTokens(alloc, toks);
    try testz.expectEqual(toks.len, 2);
    try testz.expectEqualStr("a\"b\\c", toks[1]);
}

// ─── wordsplit.parseAliasDef ───────────────────────────────────────────

pub fn parseAliasRestOfLineValueTest(_: std.Io, _: std.mem.Allocator) !void {
    const def = wordsplit.parseAliasDef("alias ll=ls -l").?;
    try testz.expectEqualStr("ll", def.name);
    try testz.expectEqualStr("ls -l", def.value);
}

pub fn parseAliasStripsWrappingQuotesTest(_: std.Io, _: std.mem.Allocator) !void {
    const single = wordsplit.parseAliasDef("alias ll='ls -l'").?;
    try testz.expectEqualStr("ll", single.name);
    try testz.expectEqualStr("ls -l", single.value);

    const double = wordsplit.parseAliasDef("alias g=\"git status\"").?;
    try testz.expectEqualStr("git status", double.value);
}

pub fn parseAliasKeepsInnerEqualsInValueTest(_: std.Io, _: std.mem.Allocator) !void {
    const def = wordsplit.parseAliasDef("alias e=env FOO=bar").?;
    try testz.expectEqualStr("e", def.name);
    try testz.expectEqualStr("env FOO=bar", def.value);
}

pub fn parseAliasQuotedValueKeepsEdgeSpacesTest(_: std.Io, _: std.mem.Allocator) !void {
    const def = wordsplit.parseAliasDef("alias pad=' ls '").?;
    try testz.expectEqualStr(" ls ", def.value);
}

pub fn parseAliasBareReturnsNullTest(_: std.Io, _: std.mem.Allocator) !void {
    try testz.expectTrue(wordsplit.parseAliasDef("alias") == null);
    try testz.expectTrue(wordsplit.parseAliasDef("alias   ") == null);
    try testz.expectTrue(wordsplit.parseAliasDef("alias noequals") == null);
}

// ─── complete.wordRange ────────────────────────────────────────────────

pub fn wordRangeAtEndOfLineTest(_: std.Io, _: std.mem.Allocator) !void {
    const line = "cat src/co";
    const wr = complete.wordRange(line, line.len);
    try testz.expectEqual(wr.start, 4);
    try testz.expectEqual(wr.end, line.len);
    try testz.expectEqualStr("src/co", line[wr.start..wr.end]);
}

pub fn wordRangeMidWordExtendsBothWaysTest(_: std.Io, _: std.mem.Allocator) !void {
    const line = "ls README.md here";
    // cursor sits between "READ" and "ME.md"
    const wr = complete.wordRange(line, 7);
    try testz.expectEqualStr("README.md", line[wr.start..wr.end]);
}

pub fn wordRangeEmptyWhenOnWhitespaceTest(_: std.Io, _: std.mem.Allocator) !void {
    const line = "ls ";
    const wr = complete.wordRange(line, 3);
    try testz.expectEqual(wr.start, 3);
    try testz.expectEqual(wr.end, 3);
}

pub fn wordRangeKeepsEscapedSpaceInWordTest(_: std.Io, _: std.mem.Allocator) !void {
    const line = "cat my\\ fi";
    const wr = complete.wordRange(line, line.len);
    try testz.expectEqualStr("my\\ fi", line[wr.start..wr.end]);
}

// ─── complete.dirPrefix ────────────────────────────────────────────────

pub fn dirPrefixSplitsOnLastSlashTest(_: std.Io, _: std.mem.Allocator) !void {
    const a = complete.dirPrefix("src/co");
    try testz.expectEqualStr("src/", a.dir);
    try testz.expectEqualStr("co", a.prefix);

    const b = complete.dirPrefix("co");
    try testz.expectEqualStr("", b.dir);
    try testz.expectEqualStr("co", b.prefix);

    const c = complete.dirPrefix("build/");
    try testz.expectEqualStr("build/", c.dir);
    try testz.expectEqualStr("", c.prefix);

    const d = complete.dirPrefix("/etc/pa");
    try testz.expectEqualStr("/etc/", d.dir);
    try testz.expectEqualStr("pa", d.prefix);
}

// ─── complete.commonPrefixLen ──────────────────────────────────────────

pub fn commonPrefixLenTest(_: std.Io, _: std.mem.Allocator) !void {
    try testz.expectEqual(complete.commonPrefixLen(&.{ "core.zig", "core_test.zig" }), 4);
    try testz.expectEqual(complete.commonPrefixLen(&.{ "abc", "abc" }), 3);
    try testz.expectEqual(complete.commonPrefixLen(&.{ "abc", "xyz" }), 0);
    try testz.expectEqual(complete.commonPrefixLen(&.{"only"}), 4);
    try testz.expectEqual(complete.commonPrefixLen(&.{}), 0);
}

// ─── handshake.aware ──────────────────────────────────────────────────

pub fn handshakeAwareDetectsFullMarkerTest(_: std.Io, _: std.mem.Allocator) !void {
    try testz.expectEqual(handshake.aware(handshake.marker), true);
    // Marker followed by real output still resolves as aware.
    try testz.expectEqual(handshake.aware(handshake.marker ++ "hello"), true);
}

pub fn handshakeAwareTreatsPlainOutputAsNotAwareTest(_: std.Io, _: std.mem.Allocator) !void {
    // At least marker-length and not a match -> definitely a plain program.
    try testz.expectEqual(handshake.aware("this is plain program output!!!"), false);
    // Shorter than the marker but already diverging from it -> plain.
    try testz.expectEqual(handshake.aware("hi\n"), false);
}

pub fn handshakeAwareIsUndecidedOnPartialMarkerPrefixTest(_: std.Io, _: std.mem.Allocator) !void {
    // Nothing read yet, or a leading NUL then part of the marker: could
    // still become the marker once more bytes arrive -- the caller keeps
    // reading, and settles on "not aware" if the stream ends here.
    try testz.expectEqual(handshake.aware(""), null);
    try testz.expectEqual(handshake.aware(handshake.marker[0..1]), null);
    try testz.expectEqual(handshake.aware(handshake.marker[0..10]), null);
    // One byte short is still undecided.
    try testz.expectEqual(handshake.aware(handshake.marker[0 .. handshake.marker.len - 1]), null);
}

// ─── history (persistent command history file) ──────────────────────────

pub fn historyParseSplitsLinesSkippingBlanksTest(_: std.Io, alloc: std.mem.Allocator) !void {
    const entries = try history.parse(alloc, "ls\n\ncd /tmp\n\n\ngit status\n");
    defer history.freeEntries(alloc, entries);
    try testz.expectEqual(entries.len, 3);
    try testz.expectEqualStr("ls", entries[0]);
    try testz.expectEqualStr("cd /tmp", entries[1]);
    try testz.expectEqualStr("git status", entries[2]);
}

pub fn historyParseHandlesNoTrailingNewlineAndCarriageReturnsTest(_: std.Io, alloc: std.mem.Allocator) !void {
    const entries = try history.parse(alloc, "one\r\ntwo\r\nthree");
    defer history.freeEntries(alloc, entries);
    try testz.expectEqual(entries.len, 3);
    try testz.expectEqualStr("one", entries[0]);
    try testz.expectEqualStr("two", entries[1]);
    try testz.expectEqualStr("three", entries[2]);
}

pub fn historyParseCollapsesConsecutiveDuplicatesTest(_: std.Io, alloc: std.mem.Allocator) !void {
    const entries = try history.parse(alloc, "ls\nls\nls\ncd\nls\n");
    defer history.freeEntries(alloc, entries);
    // Runs collapse, but a repeat that isn't back-to-back is kept.
    try testz.expectEqual(entries.len, 3);
    try testz.expectEqualStr("ls", entries[0]);
    try testz.expectEqualStr("cd", entries[1]);
    try testz.expectEqualStr("ls", entries[2]);
}

pub fn historyParseTrimsToMaxEntriesKeepingNewestTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    // max_entries + 10 distinct lines; only the last max_entries survive.
    var i: usize = 0;
    while (i < history.max_entries + 10) : (i += 1) {
        var line: [16]u8 = undefined;
        try buf.appendSlice(alloc, try std.fmt.bufPrint(&line, "cmd{d}\n", .{i}));
    }

    const entries = try history.parse(alloc, buf.items);
    defer history.freeEntries(alloc, entries);
    try testz.expectEqual(entries.len, history.max_entries);
    try testz.expectEqualStr("cmd10", entries[0]);
    var last: [16]u8 = undefined;
    const want = try std.fmt.bufPrint(&last, "cmd{d}", .{history.max_entries + 9});
    try testz.expectEqualStr(want, entries[entries.len - 1]);
}

pub fn historyShouldRecordRejectsBlankAndConsecutiveDupeTest(_: std.Io, _: std.mem.Allocator) !void {
    try testz.expectEqual(history.shouldRecord(null, ""), false);
    try testz.expectEqual(history.shouldRecord(null, "ls"), true);
    try testz.expectEqual(history.shouldRecord("ls", "ls"), false);
    try testz.expectEqual(history.shouldRecord("ls", "ls -l"), true);
}

pub fn historySerializeRoundTripsThroughParseTest(_: std.Io, alloc: std.mem.Allocator) !void {
    const src = [_][]const u8{ "ls", "cd /tmp", "git commit -m 'x y'" };
    const bytes = try history.serialize(alloc, &src);
    defer alloc.free(bytes);
    try testz.expectEqualStr("ls\ncd /tmp\ngit commit -m 'x y'\n", bytes);

    const entries = try history.parse(alloc, bytes);
    defer history.freeEntries(alloc, entries);
    try testz.expectEqual(entries.len, 3);
    try testz.expectEqualStr("git commit -m 'x y'", entries[2]);
}

// ─── keyencode.toPtyBytes ──────────────────────────────────────────────

pub fn keyencodePlainAndShiftedCharsTest(_: std.Io, _: std.mem.Allocator) !void {
    var buf: [8]u8 = undefined;
    try testz.expectEqualStr("a", keyencode.toPtyBytes("a", .{}, &buf).?);
    try testz.expectEqualStr("A", keyencode.toPtyBytes("a", .{ .shift = true }, &buf).?);
    try testz.expectEqualStr("7", keyencode.toPtyBytes("seven", .{}, &buf).?);
    try testz.expectEqualStr("&", keyencode.toPtyBytes("seven", .{ .shift = true }, &buf).?);
    try testz.expectEqualStr(" ", keyencode.toPtyBytes("space", .{}, &buf).?);
}

pub fn keyencodeNamedKeysMapToSequencesTest(_: std.Io, _: std.mem.Allocator) !void {
    var buf: [8]u8 = undefined;
    try testz.expectEqualStr("\r", keyencode.toPtyBytes("enter", .{}, &buf).?);
    try testz.expectEqualStr("\x7f", keyencode.toPtyBytes("backspace", .{}, &buf).?);
    try testz.expectEqualStr("\t", keyencode.toPtyBytes("tab", .{}, &buf).?);
    try testz.expectEqualStr("\x1b", keyencode.toPtyBytes("escape", .{}, &buf).?);
    try testz.expectEqualStr("\x1b[A", keyencode.toPtyBytes("up", .{}, &buf).?);
    try testz.expectEqualStr("\x1b[D", keyencode.toPtyBytes("left", .{}, &buf).?);
    try testz.expectEqualStr("\x1b[3~", keyencode.toPtyBytes("delete", .{}, &buf).?);
}

pub fn keyencodeCtrlAndAltTest(_: std.Io, _: std.mem.Allocator) !void {
    var buf: [8]u8 = undefined;
    // Ctrl-C / Ctrl-D / Ctrl-Z as their C0 control bytes.
    try testz.expectEqualStr("\x03", keyencode.toPtyBytes("c", .{ .ctrl = true }, &buf).?);
    try testz.expectEqualStr("\x04", keyencode.toPtyBytes("d", .{ .ctrl = true }, &buf).?);
    try testz.expectEqualStr("\x1a", keyencode.toPtyBytes("z", .{ .ctrl = true }, &buf).?);
    // Alt-x = ESC prefix + the char.
    try testz.expectEqualStr("\x1bx", keyencode.toPtyBytes("x", .{ .alt = true }, &buf).?);
}

pub fn keyencodeReturnsNullForNonPrintableTest(_: std.Io, _: std.mem.Allocator) !void {
    var buf: [8]u8 = undefined;
    // Bare modifiers / unknown function keys -- nothing to send.
    try testz.expectEqual(keyencode.toPtyBytes("left_shift", .{}, &buf), null);
    try testz.expectEqual(keyencode.toPtyBytes("f5", .{}, &buf), null);
    // Ctrl with a key that has no control-byte mapping is swallowed.
    try testz.expectEqual(keyencode.toPtyBytes("f5", .{ .ctrl = true }, &buf), null);
}

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
