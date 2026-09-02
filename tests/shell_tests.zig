const std = @import("std");
const testz = @import("testz");

// glyphwire-shell is an executable (no importable module), but its pure
// prompt helpers are gathered into the `shell_support` module (see
// build.zig) precisely so they can be exercised here.
const wordsplit = @import("shell_support").wordsplit;
const complete = @import("shell_support").complete;
const glob = @import("shell_support").glob;

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
