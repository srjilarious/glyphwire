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
const pty = @import("shell_support").pty;
const lineedit = @import("shell_support").lineedit;
const browsescroll = @import("shell_support").browsescroll;

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

pub fn splitTreatsNewlinesAsSeparatorsTest(_: std.Io, alloc: std.mem.Allocator) !void {
    // A pasted multi-select file list (one path per line, a trailing
    // newline) must split into one token per line, not one giant token.
    const toks = try wordsplit.split(alloc, "src\ndocs\nbuild.zig\n");
    defer wordsplit.freeTokens(alloc, toks);
    try testz.expectEqual(toks.len, 3);
    try testz.expectEqualStr("src", toks[0]);
    try testz.expectEqualStr("docs", toks[1]);
    try testz.expectEqualStr("build.zig", toks[2]);

    // CRLF and blank lines collapse the same way spaces do.
    const crlf = try wordsplit.split(alloc, "a\r\n\r\nb");
    defer wordsplit.freeTokens(alloc, crlf);
    try testz.expectEqual(crlf.len, 2);
    try testz.expectEqualStr("a", crlf[0]);
    try testz.expectEqualStr("b", crlf[1]);
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

// ─── wordsplit.quoteArgIfNeeded ───────────────────────────────────────

pub fn quoteArgIfNeededLeavesPlainPathBareTest(_: std.Io, alloc: std.mem.Allocator) !void {
    for ([_][]const u8{ "photo.png", "src/docs/build.zig", "a_b-c.2", "./rel/path" }) |plain| {
        const got = try wordsplit.quoteArgIfNeeded(alloc, plain);
        defer alloc.free(got);
        try testz.expectEqualStr(plain, got); // untouched, but still an owned copy
    }
}

pub fn quoteArgIfNeededQuotesWhenItHasToTest(_: std.Io, alloc: std.mem.Allocator) !void {
    // Space, glob char, shell metacharacter, and the empty string all
    // force quoting; the result must re-split to the one original token.
    for ([_][]const u8{ "my holiday pics/2.jpg", "shot*.png", "a;b", "" }) |s| {
        const got = try wordsplit.quoteArgIfNeeded(alloc, s);
        defer alloc.free(got);
        try testz.expectTrue(got.len >= 2 and got[0] == '\'');
        const toks = try wordsplit.split(alloc, got);
        defer wordsplit.freeTokens(alloc, toks);
        try testz.expectEqual(toks.len, 1);
        try testz.expectEqualStr(s, toks[0]);
    }
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

// ─── complete.candidateSuffix ─────────────────────────────────────────

pub fn candidateSuffixAddsDirectorySlashTest(_: std.Io, alloc: std.mem.Allocator) !void {
    const got = (try complete.candidateSuffix(alloc, "sr", "src", true)).?;
    defer alloc.free(got);
    try testz.expectEqualStr("c/", got);
}

pub fn candidateSuffixAddsFileSpaceTest(_: std.Io, alloc: std.mem.Allocator) !void {
    const got = (try complete.candidateSuffix(alloc, "build", "build.zig", false)).?;
    defer alloc.free(got);
    try testz.expectEqualStr(".zig ", got);
}

pub fn candidateSuffixRejectsNonMatchTest(_: std.Io, alloc: std.mem.Allocator) !void {
    const got = try complete.candidateSuffix(alloc, "zo", "src", true);
    try testz.expectEqual(got, null);
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
    try testz.expectEqualStr("a", keyencode.toPtyBytes("a", .{}, .normal, &buf).?);
    try testz.expectEqualStr("A", keyencode.toPtyBytes("a", .{ .shift = true }, .normal, &buf).?);
    try testz.expectEqualStr("7", keyencode.toPtyBytes("seven", .{}, .normal, &buf).?);
    try testz.expectEqualStr("&", keyencode.toPtyBytes("seven", .{ .shift = true }, .normal, &buf).?);
    try testz.expectEqualStr(" ", keyencode.toPtyBytes("space", .{}, .normal, &buf).?);
}

pub fn keyencodeNamedKeysMapToSequencesTest(_: std.Io, _: std.mem.Allocator) !void {
    var buf: [8]u8 = undefined;
    try testz.expectEqualStr("\r", keyencode.toPtyBytes("enter", .{}, .normal, &buf).?);
    try testz.expectEqualStr("\x7f", keyencode.toPtyBytes("backspace", .{}, .normal, &buf).?);
    try testz.expectEqualStr("\t", keyencode.toPtyBytes("tab", .{}, .normal, &buf).?);
    try testz.expectEqualStr("\x1b", keyencode.toPtyBytes("escape", .{}, .normal, &buf).?);
    try testz.expectEqualStr("\x1b[A", keyencode.toPtyBytes("up", .{}, .normal, &buf).?);
    try testz.expectEqualStr("\x1b[D", keyencode.toPtyBytes("left", .{}, .normal, &buf).?);
    try testz.expectEqualStr("\x1b[3~", keyencode.toPtyBytes("delete", .{}, .normal, &buf).?);
}

/// `F1`-`F4` are SS3, unaffected by DECCKM (that only retimes the arrows/
/// Home/End); `F5`+ are `CSI n ~`. Names are uppercase, matching zglfw's
/// `Key` enum field name that `host/main.zig` forwards verbatim -- htop's
/// quit key (`F10`) is the motivating case.
pub fn keyencodeFunctionKeysMapToXtermSequencesTest(_: std.Io, _: std.mem.Allocator) !void {
    var buf: [8]u8 = undefined;
    try testz.expectEqualStr("\x1bOP", keyencode.toPtyBytes("F1", .{}, .normal, &buf).?);
    try testz.expectEqualStr("\x1bOS", keyencode.toPtyBytes("F4", .{}, .normal, &buf).?);
    try testz.expectEqualStr("\x1b[15~", keyencode.toPtyBytes("F5", .{}, .normal, &buf).?);
    try testz.expectEqualStr("\x1b[21~", keyencode.toPtyBytes("F10", .{}, .normal, &buf).?);
    try testz.expectEqualStr("\x1b[24~", keyencode.toPtyBytes("F12", .{}, .normal, &buf).?);
    // Application cursor-key mode doesn't affect function keys.
    try testz.expectEqualStr("\x1b[21~", keyencode.toPtyBytes("F10", .{}, .application, &buf).?);
    // F13 and up are still out of scope.
    try testz.expectTrue(keyencode.toPtyBytes("F13", .{}, .normal, &buf) == null);
}

/// DECCKM (`ESC [ ? 1 h`): the arrows and Home/End switch to the `ESC O x`
/// (SS3) form; the `~`-terminated keys don't.
pub fn keyencodeApplicationCursorKeysTest(_: std.Io, _: std.mem.Allocator) !void {
    var buf: [8]u8 = undefined;
    try testz.expectEqualStr("\x1bOA", keyencode.toPtyBytes("up", .{}, .application, &buf).?);
    try testz.expectEqualStr("\x1bOB", keyencode.toPtyBytes("down", .{}, .application, &buf).?);
    try testz.expectEqualStr("\x1bOC", keyencode.toPtyBytes("right", .{}, .application, &buf).?);
    try testz.expectEqualStr("\x1bOD", keyencode.toPtyBytes("left", .{}, .application, &buf).?);
    try testz.expectEqualStr("\x1bOH", keyencode.toPtyBytes("home", .{}, .application, &buf).?);
    try testz.expectEqualStr("\x1bOF", keyencode.toPtyBytes("end", .{}, .application, &buf).?);
    // PageUp and friends are unchanged by cursor-key mode.
    try testz.expectEqualStr("\x1b[5~", keyencode.toPtyBytes("page_up", .{}, .application, &buf).?);
}

pub fn keyencodeCtrlAndAltTest(_: std.Io, _: std.mem.Allocator) !void {
    var buf: [8]u8 = undefined;
    // Ctrl-C / Ctrl-D / Ctrl-Z as their C0 control bytes.
    try testz.expectEqualStr("\x03", keyencode.toPtyBytes("c", .{ .ctrl = true }, .normal, &buf).?);
    try testz.expectEqualStr("\x04", keyencode.toPtyBytes("d", .{ .ctrl = true }, .normal, &buf).?);
    try testz.expectEqualStr("\x1a", keyencode.toPtyBytes("z", .{ .ctrl = true }, .normal, &buf).?);
    // Alt-x = ESC prefix + the char.
    try testz.expectEqualStr("\x1bx", keyencode.toPtyBytes("x", .{ .alt = true }, .normal, &buf).?);
}

pub fn keyencodeReturnsNullForNonPrintableTest(_: std.Io, _: std.mem.Allocator) !void {
    var buf: [8]u8 = undefined;
    // Bare modifiers / unknown function keys -- nothing to send.
    try testz.expectEqual(keyencode.toPtyBytes("left_shift", .{}, .normal, &buf), null);
    try testz.expectEqual(keyencode.toPtyBytes("f5", .{}, .normal, &buf), null);
    // Ctrl with a key that has no control-byte mapping is swallowed.
    try testz.expectEqual(keyencode.toPtyBytes("f5", .{ .ctrl = true }, .normal, &buf), null);
}

// ─── keyencode.encodeMouse ────────────────────────────────────────────

pub fn encodeMouseSgrFormTest(_: std.Io, _: std.mem.Allocator) !void {
    var buf: [16]u8 = undefined;
    // Left press at cell (col=4, row=9) -> 1-based 5;10, final `M`.
    try testz.expectEqualStr("\x1b[<0;5;10M", keyencode.encodeMouse(.sgr, .left, .press, 4, 9, .{}, &buf).?);
    // Release keeps the button code but flips the final byte to `m`.
    try testz.expectEqualStr("\x1b[<0;5;10m", keyencode.encodeMouse(.sgr, .left, .release, 4, 9, .{}, &buf).?);
    // Right button + ctrl held: base 2 + ctrl 16 = 18.
    try testz.expectEqualStr("\x1b[<18;1;1M", keyencode.encodeMouse(.sgr, .right, .press, 0, 0, .{ .ctrl = true }, &buf).?);
    // Motion with a button held adds the 32 bit: left(0) + 32.
    try testz.expectEqualStr("\x1b[<32;3;3M", keyencode.encodeMouse(.sgr, .left, .motion, 2, 2, .{}, &buf).?);
    // Bare motion under ?1003: "no button" (3) + motion (32) = 35.
    try testz.expectEqualStr("\x1b[<35;3;3M", keyencode.encodeMouse(.sgr, .none, .motion, 2, 2, .{}, &buf).?);
    // Wheel up = 64.
    try testz.expectEqualStr("\x1b[<64;5;5M", keyencode.encodeMouse(.sgr, .wheel_up, .press, 4, 4, .{}, &buf).?);
}

pub fn encodeMouseLegacyFormTest(_: std.Io, _: std.mem.Allocator) !void {
    var buf: [16]u8 = undefined;
    // Left press at (0,0): ESC [ M then 32+0, 32+1, 32+1.
    try testz.expectEqualStr("\x1b[M\x20\x21\x21", keyencode.encodeMouse(.legacy, .left, .press, 0, 0, .{}, &buf).?);
    // Release: button bits become 3 -> 32+3 = 35 ('#').
    try testz.expectEqualStr("\x1b[M#\x21\x21", keyencode.encodeMouse(.legacy, .left, .release, 0, 0, .{}, &buf).?);
    // Coordinates clamp at 223 (byte 255).
    const clamped = keyencode.encodeMouse(.legacy, .left, .press, 500, 1, .{}, &buf).?;
    try testz.expectEqual(clamped[4], @as(u8, 255));
}

// ─── pty.ModeTracker ──────────────────────────────────────────────────

pub fn modeTrackerBasicSetAndResetTest(_: std.Io, _: std.mem.Allocator) !void {
    var mt: pty.ModeTracker = .{};
    try testz.expectFalse(mt.appCursor());

    mt.feed("\x1b[?1h");
    try testz.expectTrue(mt.appCursor());
    mt.feed("\x1b[?1l");
    try testz.expectFalse(mt.appCursor());

    mt.feed("\x1b[?2004h");
    try testz.expectTrue(mt.bracketedPaste());

    // A non-private CSI with the same number must not touch the mode.
    mt.feed("\x1b[1h");
    try testz.expectFalse(mt.appCursor());
}

pub fn modeTrackerMultiParamAndSurroundingTextTest(_: std.Io, _: std.mem.Allocator) !void {
    var mt: pty.ModeTracker = .{};
    // The way xterm mouse setup usually arrives: several modes at once,
    // wrapped in ordinary output.
    mt.feed("hello\x1b[?1000;1002;1006hworld");
    try testz.expectTrue(mt.mouseReporting());
    try testz.expectTrue(mt.wantsMotion());
    try testz.expectFalse(mt.wantsAnyMotion());
    try testz.expectTrue(mt.sgrMouse());

    mt.feed("\x1b[?1000;1002;1006l");
    try testz.expectFalse(mt.mouseReporting());
    try testz.expectFalse(mt.sgrMouse());
}

pub fn modeTrackerSequenceSplitAcrossFeedsTest(_: std.Io, _: std.mem.Allocator) !void {
    var mt: pty.ModeTracker = .{};
    // Byte boundaries fall wherever the master read happened to land.
    mt.feed("\x1b[?10");
    mt.feed("03");
    mt.feed("h");
    try testz.expectTrue(mt.mouseReporting());
    try testz.expectTrue(mt.wantsAnyMotion());
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

// ─── browsescroll: scrollback browsing scrolloff math ──────────────────

pub fn browseScrolloffClampLeavesRoomForCursorTest(_: std.Io, _: std.mem.Allocator) !void {
    // Prompt low on the grid: full margin fits.
    try testz.expectEqual(browsescroll.clampScrolloff(8, 24), @as(usize, 8));
    // Prompt high up: clamped to half the rows above it.
    try testz.expectEqual(browsescroll.clampScrolloff(8, 4), @as(usize, 2));
    try testz.expectEqual(browsescroll.clampScrolloff(8, 1), @as(usize, 0));
    try testz.expectEqual(browsescroll.clampScrolloff(0, 24), @as(usize, 0));
}

pub fn browseUpEnteringConsumesTheFirstRowTest(_: std.Io, _: std.mem.Allocator) !void {
    // Entering browse: the caller has already put the cursor one row
    // above the prompt, so a plain Up (count 1) does nothing more.
    const r = browsescroll.up(.{ .bp_row = 19, .view_scroll = 0 }, 1, 8, 100, true);
    try testz.expectEqual(r.bp_row, @as(usize, 19));
    try testz.expectEqual(r.view_scroll, @as(usize, 0));
}

pub fn browseUpEnteringOnRow0ScrollsImmediatelyTest(_: std.Io, _: std.mem.Allocator) !void {
    // Prompt on row 0: there's no row above it for the enter-browse move
    // to land on, so a first Up spends its whole count scrolling.
    const r = browsescroll.up(.{ .bp_row = 0, .view_scroll = 0 }, 1, 0, 5, true);
    try testz.expectEqual(r.bp_row, @as(usize, 0));
    try testz.expectEqual(r.view_scroll, @as(usize, 1));
}

pub fn browseUpMovesCursorUntilMarginThenScrollsTest(_: std.Io, _: std.mem.Allocator) !void {
    // Cursor well below the margin: a 5-row step just moves the cursor.
    var r = browsescroll.up(.{ .bp_row = 19, .view_scroll = 0 }, 5, 8, 100, false);
    try testz.expectEqual(r.bp_row, @as(usize, 14));
    try testz.expectEqual(r.view_scroll, @as(usize, 0));
    // From the margin, another step scrolls the window and holds the row.
    r = browsescroll.up(.{ .bp_row = 8, .view_scroll = 0 }, 5, 8, 100, false);
    try testz.expectEqual(r.bp_row, @as(usize, 8));
    try testz.expectEqual(r.view_scroll, @as(usize, 5));
}

pub fn browseUpStraddlesMarginInOneStepTest(_: std.Io, _: std.mem.Allocator) !void {
    // 5 rows from bp_row 10, margin 8: 2 rows of cursor travel to the
    // margin, then 3 rows of window scroll.
    const r = browsescroll.up(.{ .bp_row = 10, .view_scroll = 0 }, 5, 8, 100, false);
    try testz.expectEqual(r.bp_row, @as(usize, 8));
    try testz.expectEqual(r.view_scroll, @as(usize, 3));
}

pub fn browseUpLetsCursorClimbPastMarginWhenScrollbackExhaustedTest(_: std.Io, _: std.mem.Allocator) !void {
    // view_max 0: nothing to scroll into, so the cursor is allowed all
    // the way to row 0 despite the margin.
    const r = browsescroll.up(.{ .bp_row = 2, .view_scroll = 0 }, 5, 8, 0, false);
    try testz.expectEqual(r.bp_row, @as(usize, 0));
    try testz.expectEqual(r.view_scroll, @as(usize, 0));
}

pub fn browseUpClampsScrollToViewMaxTest(_: std.Io, _: std.mem.Allocator) !void {
    // At the margin with only 2 rows of history left: scroll 2, then the
    // cursor climbs the remaining 1.
    const r = browsescroll.up(.{ .bp_row = 1, .view_scroll = 0 }, 3, 8, 2, false);
    try testz.expectEqual(r.view_scroll, @as(usize, 2));
    try testz.expectEqual(r.bp_row, @as(usize, 0));
}

pub fn browseDownStepsCursorUntilNearBottomThenUnscrollsTest(_: std.Io, _: std.mem.Allocator) !void {
    // bottom 19, margin 8 -> hold_row 11. Cursor at 8 with the view
    // scrolled 5 back: 3 rows of cursor travel to hold_row, then 3 rows
    // of un-scroll (5 -> 2), cursor held at 11.
    const r = browsescroll.down(.{ .bp_row = 8, .view_scroll = 5 }, 6, 8, 19);
    try testz.expectEqual(r.bp_row, @as(usize, 11));
    try testz.expectEqual(r.view_scroll, @as(usize, 2));
    try testz.expectFalse(r.ended);
}

pub fn browseDownAtTailMovesCursorToBottomTest(_: std.Io, _: std.mem.Allocator) !void {
    // View already at the tail: past hold_row the cursor just keeps
    // moving down to the last browsable row (exactly reached here).
    const r = browsescroll.down(.{ .bp_row = 15, .view_scroll = 0 }, 4, 8, 19);
    try testz.expectEqual(r.bp_row, @as(usize, 19));
    try testz.expectFalse(r.ended);
    // One more Down from the last row ends browsing.
    const r2 = browsescroll.down(.{ .bp_row = 19, .view_scroll = 0 }, 1, 8, 19);
    try testz.expectTrue(r2.ended);
}

pub fn browseDownEndsAtThePromptRowTest(_: std.Io, _: std.mem.Allocator) !void {
    // At the last browsable row with the view already at the tail: the
    // next Down ends browsing.
    const r = browsescroll.down(.{ .bp_row = 19, .view_scroll = 0 }, 1, 8, 19);
    try testz.expectTrue(r.ended);
}

// ─── browsescroll.locate: Ctrl+PgUp/PgDn metadata-span jump placement ───

pub fn locateKeepsScrolloffContextAboveTheTargetTest(_: std.Io, _: std.mem.Allocator) !void {
    // Target 50 rows into scrollback, margin 8, plenty of history: land it
    // at screen row 8 with the view scrolled so 8 rows sit above it.
    const r = browsescroll.locate(50, 8, 200, 19);
    try testz.expectEqual(r.bp_row, @as(usize, 8));
    try testz.expectEqual(r.view_scroll, @as(usize, 58));
}

pub fn locateClampsScrollToAvailableHistoryTest(_: std.Io, _: std.mem.Allocator) !void {
    // Only 52 rows of history retained: the view can't scroll the full
    // margin's worth, so the target ends up nearer the top.
    const r = browsescroll.locate(50, 8, 52, 19);
    try testz.expectEqual(r.view_scroll, @as(usize, 52));
    try testz.expectEqual(r.bp_row, @as(usize, 2));
}

pub fn locateForTargetInLiveViewportStillLeavesMarginTest(_: std.Io, _: std.mem.Allocator) !void {
    // Target 3 rows below the viewport top (above -3): scroll back 5 so it
    // shows at screen row 8 (= margin) rather than up against the top.
    const r = browsescroll.locate(-3, 8, 200, 19);
    try testz.expectEqual(r.bp_row, @as(usize, 8));
    try testz.expectEqual(r.view_scroll, @as(usize, 5));
}
