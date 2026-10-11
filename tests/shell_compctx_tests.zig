// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: GPL-3.0-or-later

//! `shell/compctx.zig`: what Tab completion is completing -- the word
//! under the caret read with the shell's quoting rules, the command it
//! belongs to, the escaping that puts a completion back -- and the fish
//! `complete -C` output parser.

const std = @import("std");
const testz = @import("testz");

const compctx = @import("shell_support").compctx;

fn scanPlain(alloc: std.mem.Allocator, before: []const u8) !compctx.Context {
    return compctx.scan(alloc, before, .{});
}

// ─── scan ──────────────────────────────────────────────────────────────

pub fn scanCommandPositionTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var a = try scanPlain(alloc, "gi");
    defer a.deinit(alloc);
    try testz.expectTrue(a.commandPosition());
    try testz.expectEqualStr("gi", a.word);
    try testz.expectEqual(@as(usize, 0), a.word_start);

    // Assignments before the command keep it in command position.
    var b = try scanPlain(alloc, "FOO=1 BAR='a b' ma");
    defer b.deinit(alloc);
    try testz.expectTrue(b.commandPosition());
    try testz.expectEqualStr("ma", b.word);

    // Every operator that starts a new command resets it.
    for ([_][]const u8{ "ls | gr", "make && ./ru", "false || ec", "cd x; l" }) |line| {
        var c = try scanPlain(alloc, line);
        defer c.deinit(alloc);
        try testz.expectTrue(c.commandPosition());
    }
}

pub fn scanArgumentWordsTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var a = try scanPlain(alloc, "ls | tar -x -f ");
    defer a.deinit(alloc);
    try testz.expectFalse(a.commandPosition());
    try testz.expectEqualStr("", a.word);
    try testz.expectEqual(@as(usize, 3), a.words.len);
    try testz.expectEqualStr("tar", a.words[0]);
    try testz.expectEqualStr("-f", a.words[2]);
    try testz.expectEqual(@as(usize, 15), a.word_start);
    // The command fish is handed starts after the `|`.
    try testz.expectEqual(@as(usize, 4), a.cmd_start);
}

pub fn scanQuotedWordTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var a = try scanPlain(alloc, "cat 'My Fi");
    defer a.deinit(alloc);
    try testz.expectEqualStr("My Fi", a.word);
    try testz.expectEqual(@as(u8, '\''), a.open_quote);
    try testz.expectEqual(@as(usize, 4), a.word_start);

    var b = try scanPlain(alloc, "cat \"a b/c");
    defer b.deinit(alloc);
    try testz.expectEqualStr("a b/c", b.word);
    try testz.expectEqual(@as(u8, '"'), b.open_quote);

    // An escaped blank is part of the word, a closed quote leaves none open.
    var c = try scanPlain(alloc, "cat My\\ Fi 'x'y");
    defer c.deinit(alloc);
    try testz.expectEqualStr("xy", c.word);
    try testz.expectEqual(@as(u8, 0), c.open_quote);
    try testz.expectEqualStr("My Fi", c.words[1]);
}

pub fn scanRedirectTargetTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var a = try scanPlain(alloc, "make 2> bu");
    defer a.deinit(alloc);
    try testz.expectTrue(a.after_redirect);
    try testz.expectFalse(a.commandPosition());
    // `2` is the fd designator, not an argument.
    try testz.expectEqual(@as(usize, 1), a.words.len);

    // A finished redirect target isn't a word either.
    var b = try scanPlain(alloc, "sort < in.txt -");
    defer b.deinit(alloc);
    try testz.expectFalse(b.after_redirect);
    try testz.expectEqual(@as(usize, 1), b.words.len);
    try testz.expectEqualStr("-", b.word);
}

pub fn scanExpandsTheWordTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var env = std.process.Environ.Map.init(alloc);
    defer env.deinit();
    try env.put("HOME", "/home/j");
    try env.put("D", "/srv");

    var a = try compctx.scan(alloc, "ls ~/co", .{ .env = &env });
    defer a.deinit(alloc);
    try testz.expectEqualStr("/home/j/co", a.word);

    var b = try compctx.scan(alloc, "ls \"$D/x", .{ .env = &env });
    defer b.deinit(alloc);
    try testz.expectEqualStr("/srv/x", b.word);
}

// ─── escapeInsert ──────────────────────────────────────────────────────

pub fn escapeInsertFollowsTheOpenQuoteTest(_: std.Io, alloc: std.mem.Allocator) !void {
    const bare = try compctx.escapeInsert(alloc, "it's $5 (a).txt", 0);
    defer alloc.free(bare);
    try testz.expectEqualStr("it\\'s\\ \\$5\\ \\(a\\).txt", bare);

    const single = try compctx.escapeInsert(alloc, "it's $5", '\'');
    defer alloc.free(single);
    try testz.expectEqualStr("it'\\''s $5", single);

    const double = try compctx.escapeInsert(alloc, "say \"$x\" \\ `y`", '"');
    defer alloc.free(double);
    try testz.expectEqualStr("say \\\"\\$x\\\" \\\\ \\`y\\`", double);
}

// ─── parseFishOutput ───────────────────────────────────────────────────

pub fn parseFishOutputSplitsTokenAndDescriptionTest(_: std.Io, alloc: std.mem.Allocator) !void {
    const out = "checkout\tSwitch branches\ncherry-pick\tApply commits\r\nsrc/\n\n\tstray\nplain\n";
    const items = try compctx.parseFishOutput(alloc, out);
    defer alloc.free(items);
    try testz.expectEqual(@as(usize, 4), items.len);
    try testz.expectEqualStr("checkout", items[0].text);
    try testz.expectEqualStr("Switch branches", items[0].desc);
    try testz.expectEqualStr("Apply commits", items[1].desc);
    try testz.expectEqualStr("src/", items[2].text);
    try testz.expectEqualStr("", items[2].desc);
    try testz.expectEqualStr("plain", items[3].text);
}
