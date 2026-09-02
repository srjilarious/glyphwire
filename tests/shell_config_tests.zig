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

// ─── powerline segments ──────────────────────────────────────────────

pub fn configReadsPowerlineSegmentsTest(_: std.Io, alloc: std.mem.Allocator) !void {
    const src =
        \\prompt {
        \\  left_segments = {
        \\    { text = "{icon:distro/arch}", fg = "#000", bg = "#d0d0d0" },
        \\    { " {cwd} ", fg = "#ffffff", bg = "#3a3a3a" },
        \\    { " {exit_code} ", bg = "#d70000", when = "error" },
        \\  },
        \\  right_segments = {
        \\    { " {time} ", fg = "#fff", bg = "#5f87af" },
        \\  },
        \\  head = "H", sep = "S", tail = "T",
        \\  lines = 2, input = "> ", time_format = "%H:%M",
        \\}
    ;
    var res = try config.load(alloc, src);
    defer res.deinit();

    try testz.expectEqual(res.err, null);
    const p = res.config.prompt;

    const left = p.left_segments.?;
    try testz.expectEqual(left.len, 3);
    try testz.expectEqualStr("{icon:distro/arch}", left[0].text);
    try testz.expectEqualStr("#000", left[0].fg.?);
    try testz.expectEqualStr("#d0d0d0", left[0].bg.?);
    try testz.expectEqual(left[0].when, .always);
    // positional text (`[1]`), no `fg`
    try testz.expectEqualStr(" {cwd} ", left[1].text);
    try testz.expectEqual(left[2].when, .err);
    try testz.expectEqual(left[2].fg, null);

    try testz.expectEqual(p.right_segments.?.len, 1);
    try testz.expectEqualStr("H", p.head.?);
    try testz.expectEqualStr("S", p.sep.?);
    try testz.expectEqualStr("T", p.tail.?);
    try testz.expectEqual(p.lines.?, 2);
    try testz.expectEqualStr("> ", p.input.?);
    try testz.expectEqualStr("%H:%M", p.time_format.?);
}

pub fn configPowerlineSegmentsMergeAcrossCallsTest(_: std.Io, alloc: std.mem.Allocator) !void {
    const src =
        \\prompt { left_segments = { { "a" }, { "b" } } }
        \\prompt { left_segments = { { "c" } } }
    ;
    var res = try config.load(alloc, src);
    defer res.deinit();

    try testz.expectEqual(res.err, null);
    // Second call replaces the list wholesale.
    try testz.expectEqual(res.config.prompt.left_segments.?.len, 1);
    try testz.expectEqualStr("c", res.config.prompt.left_segments.?[0].text);
}

pub fn configPowerlineRejectsBadWhenTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var res = try config.load(alloc, "prompt { left_segments = { { \"x\", when = \"sometimes\" } } }");
    defer res.deinit();
    try testz.expectTrue(res.err != null);
}

pub fn configPowerlineRejectsZeroLinesTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var res = try config.load(alloc, "prompt { lines = 0 }");
    defer res.deinit();
    try testz.expectTrue(res.err != null);
}

pub fn configReadsScrolloffTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var res = try config.load(alloc, "prompt { scrolloff = 12 }");
    defer res.deinit();
    try testz.expectEqual(res.err, null);
    try testz.expectEqual(res.config.prompt.scrolloff.?, @as(u32, 12));
}

pub fn configScrolloffDefaultsNullWhenUnsetTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var res = try config.load(alloc, "prompt { lines = 2 }");
    defer res.deinit();
    try testz.expectEqual(res.err, null);
    try testz.expectEqual(res.config.prompt.scrolloff, null);
}

pub fn configPromptRejectsNegativeScrolloffTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var res = try config.load(alloc, "prompt { scrolloff = -1 }");
    defer res.deinit();
    try testz.expectTrue(res.err != null);
}

// ─── prompt{ commands = { ... } } -- on-demand command vars ────────────

pub fn configReadsCommandVarStringFormTest(_: std.Io, alloc: std.mem.Allocator) !void {
    const src =
        \\prompt {
        \\  commands = {
        \\    branch = "git branch --show-current",
        \\  },
        \\}
    ;
    var res = try config.load(alloc, src);
    defer res.deinit();

    try testz.expectEqual(res.err, null);
    const cmds = res.config.prompt.command_vars.?;
    try testz.expectEqual(cmds.len, 1);
    try testz.expectEqualStr("branch", cmds[0].name);
    try testz.expectEqualStr("git branch --show-current", cmds[0].run);
    try testz.expectEqual(cmds[0].when, null);
    try testz.expectEqual(cmds[0].timeout_ms, null);
}

pub fn configReadsCommandVarTableFormTest(_: std.Io, alloc: std.mem.Allocator) !void {
    const src =
        \\prompt {
        \\  commands = {
        \\    dirty = { "git status --porcelain", when = "{is_repo}", timeout_ms = 250 },
        \\  },
        \\}
    ;
    var res = try config.load(alloc, src);
    defer res.deinit();

    try testz.expectEqual(res.err, null);
    const cmds = res.config.prompt.command_vars.?;
    try testz.expectEqual(cmds.len, 1);
    try testz.expectEqualStr("dirty", cmds[0].name);
    try testz.expectEqualStr("git status --porcelain", cmds[0].run);
    try testz.expectEqualStr("{is_repo}", cmds[0].when.?);
    try testz.expectEqual(cmds[0].timeout_ms.?, @as(u64, 250));
}

pub fn configCommandVarTableAcceptsRunKeyTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var res = try config.load(alloc, "prompt { commands = { v = { run = \"echo hi\" } } }");
    defer res.deinit();
    try testz.expectEqual(res.err, null);
    try testz.expectEqualStr("echo hi", res.config.prompt.command_vars.?[0].run);
}

pub fn configCollectsMultipleCommandVarsTest(_: std.Io, alloc: std.mem.Allocator) !void {
    const src =
        \\prompt {
        \\  commands = {
        \\    is_repo = "git rev-parse --is-inside-work-tree",
        \\    branch  = { "git branch --show-current", when = "{is_repo}" },
        \\  },
        \\}
    ;
    var res = try config.load(alloc, src);
    defer res.deinit();

    try testz.expectEqual(res.err, null);
    // Map order isn't defined by Lua, so assert on the set, not indices.
    const cmds = res.config.prompt.command_vars.?;
    try testz.expectEqual(cmds.len, 2);
    var seen_repo = false;
    var seen_branch = false;
    for (cmds) |cv| {
        if (std.mem.eql(u8, cv.name, "is_repo")) seen_repo = true;
        if (std.mem.eql(u8, cv.name, "branch")) seen_branch = true;
    }
    try testz.expectTrue(seen_repo);
    try testz.expectTrue(seen_branch);
}

pub fn configCommandVarsMergeAcrossCallsTest(_: std.Io, alloc: std.mem.Allocator) !void {
    const src =
        \\prompt { commands = { a = "echo a", b = "echo b" } }
        \\prompt { commands = { c = "echo c" } }
    ;
    var res = try config.load(alloc, src);
    defer res.deinit();

    try testz.expectEqual(res.err, null);
    // A later `commands` replaces the map wholesale, like the segment lists.
    try testz.expectEqual(res.config.prompt.command_vars.?.len, 1);
    try testz.expectEqualStr("c", res.config.prompt.command_vars.?[0].name);
}

pub fn configCommandVarRejectsNonStringEntryTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var res = try config.load(alloc, "prompt { commands = { bad = 42 } }");
    defer res.deinit();
    try testz.expectTrue(res.err != null);
}

pub fn configCommandVarRejectsNegativeTimeoutTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var res = try config.load(alloc, "prompt { commands = { v = { \"echo\", timeout_ms = -5 } } }");
    defer res.deinit();
    try testz.expectTrue(res.err != null);
}

// ─── a segment `when` that is a {var} expression, not a keyword ────────

pub fn configSegmentWhenExprIsKeptVerbatimTest(_: std.Io, alloc: std.mem.Allocator) !void {
    const src =
        \\prompt {
        \\  right_segments = {
        \\    { " {branch} ", when = "{is_repo}" },
        \\    { " always ", when = "always" },
        \\  },
        \\}
    ;
    var res = try config.load(alloc, src);
    defer res.deinit();

    try testz.expectEqual(res.err, null);
    const segs = res.config.prompt.right_segments.?;
    try testz.expectEqual(segs.len, 2);
    // The `{...}` form: kept as an expression string, `when` left `.always`
    // so the keyword filter is a pass-through.
    try testz.expectEqualStr("{is_repo}", segs[0].when_expr.?);
    try testz.expectEqual(segs[0].when, .always);
    // The keyword form still parses to the enum, no `when_expr`.
    try testz.expectEqual(segs[1].when_expr, null);
    try testz.expectEqual(segs[1].when, .always);
}

pub fn configSegmentWhenExprNegationIsKeptTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var res = try config.load(alloc, "prompt { left_segments = { { \"x\", when = \"!{is_repo}\" } } }");
    defer res.deinit();
    try testz.expectEqual(res.err, null);
    try testz.expectEqualStr("!{is_repo}", res.config.prompt.left_segments.?[0].when_expr.?);
}

// ─── open_actions{ ["key"] = ... } binding ─────────────────────────────

pub fn configOpenActionsStringValueTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var res = try config.load(alloc,
        \\open_actions { ["directory"] = "cd {sel}", ["image/png"] = "glyphwire-view {selections}" }
    );
    defer res.deinit();

    try testz.expectEqual(res.err, null);
    try testz.expectEqual(res.config.open_actions.items.len, 2);

    var saw_dir = false;
    var saw_png = false;
    for (res.config.open_actions.items) |a| {
        try testz.expectEqual(a.commands.len, 1);
        if (std.mem.eql(u8, a.key, "directory")) {
            saw_dir = true;
            try testz.expectEqualStr("cd {sel}", a.commands[0]);
        } else if (std.mem.eql(u8, a.key, "image/png")) {
            saw_png = true;
            try testz.expectEqualStr("glyphwire-view {selections}", a.commands[0]);
        }
    }
    try testz.expectTrue(saw_dir and saw_png);
}

pub fn configOpenActionsListValueKeepsOrderTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var res = try config.load(alloc,
        \\open_actions { ["application/zip"] = { "ark {sel}", "unzip {sel}" } }
    );
    defer res.deinit();

    try testz.expectEqual(res.err, null);
    try testz.expectEqual(res.config.open_actions.items.len, 1);
    const a = res.config.open_actions.items[0];
    try testz.expectEqualStr("application/zip", a.key);
    try testz.expectEqual(a.commands.len, 2);
    try testz.expectEqualStr("ark {sel}", a.commands[0]);
    try testz.expectEqualStr("unzip {sel}", a.commands[1]);
}

pub fn configOpenActionsAccumulatesAcrossCallsTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var res = try config.load(alloc,
        \\open_actions { [".zig"] = "code {sel}" }
        \\open_actions { ["directory"] = "cd {sel}" }
    );
    defer res.deinit();

    try testz.expectEqual(res.err, null);
    try testz.expectEqual(res.config.open_actions.items.len, 2);
    try testz.expectEqualStr(".zig", res.config.open_actions.items[0].key);
    try testz.expectEqualStr("directory", res.config.open_actions.items[1].key);
}

pub fn configOpenActionsRejectsNonStringValueTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var res = try config.load(alloc, "open_actions { [\"directory\"] = 3 }");
    defer res.deinit();
    try testz.expectTrue(res.err != null);
}

pub fn configOpenActionsRejectsEmptyListTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var res = try config.load(alloc, "open_actions { [\"directory\"] = {} }");
    defer res.deinit();
    try testz.expectTrue(res.err != null);
}
