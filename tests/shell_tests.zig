const std = @import("std");
const testz = @import("testz");

// glyphwire-shell is an executable (no importable module), but its pure
// prompt helpers are gathered into the `shell_support` module (see
// build.zig) precisely so they can be exercised here.
const wordsplit = @import("shell_support").wordsplit;

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
