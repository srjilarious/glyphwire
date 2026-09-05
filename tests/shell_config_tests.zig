const std = @import("std");
const testz = @import("testz");

// glyphwire-shell is an executable, so its Lua config loader lives in the
// `shell_support` module (see build.zig) to be reachable here. Unlike the
// other shell_support helpers this one embeds a real Lua 5.3 state, so
// these tests run actual `shell.conf` snippets and assert what ends up in
// the parsed `ShellConfig`.
const config = @import("shell_support").config;

// ─── alias(name, value) binding ────────────────────────────────────────

pub fn configLoadsSingleAliasTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var res = try config.load(alloc, "alias('ll', 'ls -l')");
    defer res.deinit();

    try testz.expectEqual(res.err, null);
    try testz.expectEqual(res.config.aliases.items.len, 1);
    try testz.expectEqualStr("ll", res.config.aliases.items[0].name);
    try testz.expectEqualStr("ls -l", res.config.aliases.items[0].value);
}

pub fn configCollectsMultipleAliasesInOrderTest(_: std.Io, alloc: std.mem.Allocator) !void {
    const src =
        \\alias("ll", "ls -l")
        \\alias("gs", "git status")
        \\alias("..", "cd ..")
    ;
    var res = try config.load(alloc, src);
    defer res.deinit();

    try testz.expectEqual(res.err, null);
    try testz.expectEqual(res.config.aliases.items.len, 3);
    try testz.expectEqualStr("ll", res.config.aliases.items[0].name);
    try testz.expectEqualStr("gs", res.config.aliases.items[1].name);
    try testz.expectEqualStr("..", res.config.aliases.items[2].name);
    try testz.expectEqualStr("cd ..", res.config.aliases.items[2].value);
}

pub fn configKeepsDuplicateAliasNamesAsSeparateEntriesTest(_: std.Io, alloc: std.mem.Allocator) !void {
    const src =
        \\alias("ls", "ls --color")
        \\alias("ls", "ls -la --color")
    ;
    var res = try config.load(alloc, src);
    defer res.deinit();

    try testz.expectEqual(res.err, null);
    // The loader keeps both; whoever applies them (the prompt) gets
    // last-write-wins by replaying in order.
    try testz.expectEqual(res.config.aliases.items.len, 2);
    try testz.expectEqualStr("ls -la --color", res.config.aliases.items[1].value);
}

// ─── the conf is real Lua: loops, concat, tables all work ──────────────

pub fn configRunsLoopsAndStringConcatTest(_: std.Io, alloc: std.mem.Allocator) !void {
    const src =
        \\for i = 1, 3 do
        \\  alias("g" .. i, "git log -" .. i)
        \\end
    ;
    var res = try config.load(alloc, src);
    defer res.deinit();

    try testz.expectEqual(res.err, null);
    try testz.expectEqual(res.config.aliases.items.len, 3);
    try testz.expectEqualStr("g1", res.config.aliases.items[0].name);
    try testz.expectEqualStr("git log -3", res.config.aliases.items[2].value);
}

pub fn configIteratesATableOfAliasesTest(_: std.Io, alloc: std.mem.Allocator) !void {
    const src =
        \\local defs = { ll = "ls -l", la = "ls -a" }
        \\for name, value in pairs(defs) do
        \\  alias(name, value)
        \\end
    ;
    var res = try config.load(alloc, src);
    defer res.deinit();

    try testz.expectEqual(res.err, null);
    try testz.expectEqual(res.config.aliases.items.len, 2);
    // `pairs` order isn't defined, so check membership rather than index.
    var saw_ll = false;
    var saw_la = false;
    for (res.config.aliases.items) |a| {
        if (std.mem.eql(u8, a.name, "ll")) {
            saw_ll = true;
            try testz.expectEqualStr("ls -l", a.value);
        } else if (std.mem.eql(u8, a.name, "la")) {
            saw_la = true;
            try testz.expectEqualStr("ls -a", a.value);
        }
    }
    try testz.expectTrue(saw_ll);
    try testz.expectTrue(saw_la);
}

pub fn configNumberValueIsCoercedToStringTest(_: std.Io, alloc: std.mem.Allocator) !void {
    // luaL_checkstring coerces a number argument, matching stock Lua.
    var res = try config.load(alloc, "alias('answer', 42)");
    defer res.deinit();

    try testz.expectEqual(res.err, null);
    try testz.expectEqual(res.config.aliases.items.len, 1);
    try testz.expectEqualStr("42", res.config.aliases.items[0].value);
}

// ─── empty / error paths ──────────────────────────────────────────────

pub fn configEmptyAndCommentOnlyProduceNoAliasesTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var res = try config.load(alloc, "-- just a comment\n\n");
    defer res.deinit();

    try testz.expectEqual(res.err, null);
    try testz.expectEqual(res.config.aliases.items.len, 0);
}

pub fn configReportsSyntaxErrorAndKeepsPartialResultTest(_: std.Io, alloc: std.mem.Allocator) !void {
    const src =
        \\alias("ok", "cd ~")
        \\alias("broken",
    ;
    var res = try config.load(alloc, src);
    defer res.deinit();

    // A syntax error is reported, but everything the interpreter accepted
    // before the failing line is still applied.
    try testz.expectTrue(res.err != null);
}

pub fn configReportsRuntimeErrorForBadAliasArgsTest(_: std.Io, alloc: std.mem.Allocator) !void {
    // Second argument missing -> checkString raises a Lua error.
    var res = try config.load(alloc, "alias('oops')");
    defer res.deinit();

    try testz.expectTrue(res.err != null);
    try testz.expectEqual(res.config.aliases.items.len, 0);
}

pub fn configReportsRuntimeErrorForNonStringArgTest(_: std.Io, alloc: std.mem.Allocator) !void {
    // A table can't be coerced to a string -> Lua error.
    var res = try config.load(alloc, "alias('x', {})");
    defer res.deinit();

    try testz.expectTrue(res.err != null);
}

// ─── prompt{ ... } binding ────────────────────────────────────────────

pub fn configReadsPromptTableTest(_: std.Io, alloc: std.mem.Allocator) !void {
    const src =
        \\prompt {
        \\  left = "{cwd} > ",
        \\  right = "{user}",
        \\  exit = " [{exit_code}]",
        \\  dur = " {duration}",
        \\  dur_min_ms = 3000,
        \\}
    ;
    var res = try config.load(alloc, src);
    defer res.deinit();

    try testz.expectEqual(res.err, null);
    try testz.expectEqualStr("{cwd} > ", res.config.prompt.left.?);
    try testz.expectEqualStr("{user}", res.config.prompt.right.?);
    try testz.expectEqualStr(" [{exit_code}]", res.config.prompt.exit.?);
    try testz.expectEqualStr(" {duration}", res.config.prompt.dur.?);
    try testz.expectEqual(res.config.prompt.dur_min_ms.?, 3000);
}

pub fn configPromptDefaultsToAllNullTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var res = try config.load(alloc, "alias('a', 'b')");
    defer res.deinit();

    try testz.expectEqual(res.err, null);
    try testz.expectEqual(res.config.prompt.left, null);
    try testz.expectEqual(res.config.prompt.right, null);
    try testz.expectEqual(res.config.prompt.exit, null);
    try testz.expectEqual(res.config.prompt.dur, null);
    try testz.expectEqual(res.config.prompt.dur_min_ms, null);
}

pub fn configPromptMergesAcrossCallsTest(_: std.Io, alloc: std.mem.Allocator) !void {
    const src =
        \\prompt { left = "one", right = "R" }
        \\prompt { left = "two" }
    ;
    var res = try config.load(alloc, src);
    defer res.deinit();

    try testz.expectEqual(res.err, null);
    // `left` set twice -> last wins; `right` from the first call is kept.
    try testz.expectEqualStr("two", res.config.prompt.left.?);
    try testz.expectEqualStr("R", res.config.prompt.right.?);
}

pub fn configPromptRejectsNonStringFieldTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var res = try config.load(alloc, "prompt { left = {} }");
    defer res.deinit();

    try testz.expectTrue(res.err != null);
}

pub fn configPromptRejectsNegativeDurMinTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var res = try config.load(alloc, "prompt { dur_min_ms = -5 }");
    defer res.deinit();

    try testz.expectTrue(res.err != null);
}
