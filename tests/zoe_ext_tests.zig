// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: GPL-3.0-or-later

//! zoe's Lua extensions (`zoe/ext.zig`) and the bundled `task_journal`
//! extension, run against a fake host: a bare `Editor` standing in for
//! the focused buffer, and `open` reading the file into it.

const std = @import("std");
const testz = @import("testz");

const zoe = @import("zoe_support");
const Editor = zoe.Editor;
const keys = zoe.keys;
const ext = zoe.ext;
const extlist = zoe.extlist;
const actions = zoe.actions;
const keybind = @import("applib").keybind;

/// The window a runtime acts on, minus the window.
const Fake = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    ed: Editor,
    focused: bool = true,
    opened: std.ArrayList([]u8) = .empty,
    message: std.ArrayList(u8) = .empty,

    fn init(io: std.Io, alloc: std.mem.Allocator, text: []const u8) !Fake {
        return .{ .alloc = alloc, .io = io, .ed = try Editor.initFromText(alloc, text, null) };
    }

    fn deinit(self: *Fake) void {
        self.ed.deinit();
        for (self.opened.items) |p| self.alloc.free(p);
        self.opened.deinit(self.alloc);
        self.message.deinit(self.alloc);
    }

    fn host(self: *Fake) ext.Host {
        return .{ .ctx = self, .vtable = &vtable };
    }

    const vtable: ext.Host.VTable = .{ .editor = editor, .open = open, .message = say };

    fn editor(ctx: *anyopaque) ?*Editor {
        const self: *Fake = @ptrCast(@alignCast(ctx));
        return if (self.focused) &self.ed else null;
    }

    fn open(ctx: *anyopaque, path: []const u8) anyerror!void {
        const self: *Fake = @ptrCast(@alignCast(ctx));
        try self.opened.append(self.alloc, try self.alloc.dupe(u8, path));
        const text = std.Io.Dir.cwd().readFileAlloc(self.io, path, self.alloc, .limited(1 << 20)) catch try self.alloc.dupe(u8, "");
        defer self.alloc.free(text);
        try self.ed.loadText(text, path);
    }

    fn say(ctx: *anyopaque, text: []const u8) void {
        const self: *Fake = @ptrCast(@alignCast(ctx));
        self.message.clearRetainingCapacity();
        self.message.appendSlice(self.alloc, text) catch {};
    }

    fn contents(self: *Fake) ![]u8 {
        return self.ed.buf.text(self.alloc);
    }

    fn lastOpened(self: *Fake) []const u8 {
        return self.opened.items[self.opened.items.len - 1];
    }
};

/// A scratch directory under the cwd, removed by `deinit`.
const Scratch = struct {
    io: std.Io,
    alloc: std.mem.Allocator,
    /// Absolute.
    path: []u8,
    dir: std.Io.Dir,

    fn init(io: std.Io, alloc: std.mem.Allocator, label: []const u8) !Scratch {
        const rel = try std.fmt.allocPrint(alloc, "zoe-ext-test-{s}-{d}", .{ label, std.Thread.getCurrentId() });
        defer alloc.free(rel);
        std.Io.Dir.cwd().deleteTree(io, rel) catch {};
        try std.Io.Dir.cwd().createDirPath(io, rel);
        const cwd = try std.process.currentPathAlloc(io, alloc);
        defer alloc.free(cwd);
        const path = try std.fs.path.join(alloc, &.{ cwd, rel });
        errdefer alloc.free(path);
        return .{ .io = io, .alloc = alloc, .path = path, .dir = try std.Io.Dir.cwd().openDir(io, path, .{}) };
    }

    fn deinit(self: *Scratch) void {
        self.dir.close(self.io);
        std.Io.Dir.cwd().deleteTree(self.io, self.path) catch {};
        self.alloc.free(self.path);
    }

    fn file(self: *Scratch, name: []const u8, contents: []const u8) !void {
        try self.dir.writeFile(self.io, .{ .sub_path = name, .data = contents });
    }

    fn read(self: *Scratch, name: []const u8) ![]u8 {
        return self.dir.readFileAlloc(self.io, name, self.alloc, .limited(1 << 20));
    }
};

/// A runtime over `fake`, with `config` (a `zoe.conf.lua`) loaded and
/// extensions found in `user_dir`.
fn start(io: std.Io, alloc: std.mem.Allocator, fake: *Fake, config: [:0]const u8, user_dir: ?[]const u8) !*ext.Runtime {
    const rt = try ext.Runtime.init(alloc, io, null, fake.host());
    rt.load(config, user_dir);
    return rt;
}

fn run(rt: *ext.Runtime, name: []const u8) !void {
    const cmd = rt.find(name) orelse return error.NoSuchCommand;
    rt.run(cmd);
}

fn expectText(fake: *Fake, expected: []const u8) !void {
    const got = try fake.contents();
    defer fake.alloc.free(got);
    try testz.expectEqualStr(got, expected);
}

fn expectNoProblems(rt: *ext.Runtime) !void {
    if (rt.problems.items.len > 0) {
        std.debug.print("unexpected problem: {s}\n", .{rt.problems.items[0]});
        return error.TestUnexpectedProblem;
    }
}

fn expectProblem(rt: *ext.Runtime, needle: []const u8) !void {
    for (rt.problems.items) |p| {
        if (std.mem.indexOf(u8, p, needle) != null) return;
    }
    std.debug.print("no problem mentions \"{s}\"\n", .{needle});
    return error.TestExpectedProblem;
}

// ── Editor.setLineText ──────────────────────────────────────────────────

pub fn setLineKeepsTheCursorOnItsCharacterTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var ed = try Editor.initFromText(alloc, "- [ ] buy milk\n", null);
    defer ed.deinit();
    ed.setCursor(10); // the `m`
    ed.beginScriptEdit();
    try ed.setLineText(0, "- [◔] buy milk");
    ed.endScriptEdit();
    const got = try ed.buf.text(alloc);
    defer alloc.free(got);
    try testz.expectEqualStr(got, "- [◔] buy milk\n");
    // `◔` is three bytes where the space was one.
    try testz.expectEqual(ed.cursor, @as(usize, 12));
}

pub fn setLineInsertingAtTheCursorPushesItOnTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var ed = try Editor.initFromText(alloc, "buy\n", null);
    defer ed.deinit();
    ed.beginScriptEdit();
    try ed.setLineText(0, "- [ ] buy");
    ed.endScriptEdit();
    try testz.expectEqual(ed.cursor, @as(usize, 6));
}

pub fn setLineSplitsOnCodepointsAndUndoesWholeTest(_: std.Io, alloc: std.mem.Allocator) !void {
    // `◔` and `◑` share their first two bytes: a byte-level diff would
    // rewrite half a character.
    var ed = try Editor.initFromText(alloc, "[◔]\n", null);
    defer ed.deinit();
    ed.beginScriptEdit();
    try ed.setLineText(0, "[◑]");
    ed.endScriptEdit();
    try testz.expectEqual(ed.cursor, @as(usize, 0));
    const got = try ed.buf.text(alloc);
    defer alloc.free(got);
    try testz.expectEqualStr(got, "[◑]\n");

    _ = try keys.feed(&ed, "u");
    const back = try ed.buf.text(alloc);
    defer alloc.free(back);
    try testz.expectEqualStr(back, "[◔]\n");
}

// ── The runtime ─────────────────────────────────────────────────────────

pub fn extensionCommandEditsTheLineTest(io: std.Io, alloc: std.mem.Allocator) !void {
    var s = try Scratch.init(io, alloc, "edit");
    defer s.deinit();
    try s.file("shout.lua",
        \\local opts = ...
        \\zoe.command("shout", function()
        \\    zoe.set_line(zoe.line():upper() .. opts.suffix)
        \\end, "Shout the Line")
    );
    var fake = try Fake.init(io, alloc, "hello\nworld\n");
    defer fake.deinit();
    const rt = try start(io, alloc, &fake, "config = { extensions = { shout = { suffix = \"!\" } } }", s.path);
    defer rt.deinit();
    try expectNoProblems(rt);

    try testz.expectEqualStr(rt.commands.items[0].label.?, "Shout the Line");
    try run(rt, "shout");
    try expectText(&fake, "HELLO!\nworld\n");
}

pub fn extensionListShapesBothLoadTest(io: std.Io, alloc: std.mem.Allocator) !void {
    var s = try Scratch.init(io, alloc, "shapes");
    defer s.deinit();
    try s.file("a.lua", "zoe.command(\"cmdA\", function() end)");
    try s.file("b.lua", "zoe.command(\"cmdB\", function() end)");
    try s.file("c.lua", "zoe.command(\"cmdC\", function() end)");
    var fake = try Fake.init(io, alloc, "");
    defer fake.deinit();
    // `a` twice (listed and keyed) loads once; `c = false` is off.
    const rt = try start(io, alloc, &fake, "config = { extensions = { \"a\", \"b\", a = {}, c = false } }", s.path);
    defer rt.deinit();
    try expectNoProblems(rt);
    try testz.expectEqual(rt.commands.items.len, @as(usize, 2));
    try testz.expectTrue(rt.find("cmdC") == null);
}

pub fn userExtensionShadowsTheBundledOneTest(io: std.Io, alloc: std.mem.Allocator) !void {
    var s = try Scratch.init(io, alloc, "shadow");
    defer s.deinit();
    try s.file("task_journal.lua", "zoe.command(\"mine\", function() end)");
    var fake = try Fake.init(io, alloc, "");
    defer fake.deinit();
    const rt = try start(io, alloc, &fake, "config = { extensions = { \"task_journal\" } }", s.path);
    defer rt.deinit();
    try expectNoProblems(rt);
    try testz.expectTrue(rt.find("mine") != null);
    try testz.expectTrue(rt.find("taskToggle") == null);
}

pub fn extensionLoadProblemsAreCollectedTest(io: std.Io, alloc: std.mem.Allocator) !void {
    var s = try Scratch.init(io, alloc, "problems");
    defer s.deinit();
    try s.file("broken.lua", "zoe.command(\"x\", function() end"); // unclosed
    try s.file("twice.lua", "zoe.command(\"dup\", function() end) zoe.command(\"dup\", function() end)");
    try s.file("builtin.lua", "zoe.command(\"save\", function() end)");
    try s.file("thrower.lua", "error(\"nope\", 0)");
    var fake = try Fake.init(io, alloc, "");
    defer fake.deinit();
    const rt = try start(io, alloc,
        &fake,
        "config = { extensions = { \"missing\", \"broken\", \"twice\", \"builtin\", \"thrower\", \"../evil\" } }",
        s.path,
    );
    defer rt.deinit();
    try expectProblem(rt, "\"missing\": not found");
    try expectProblem(rt, "broken.lua");
    try expectProblem(rt, "\"dup\" is already registered");
    try expectProblem(rt, "\"save\" is a built-in action");
    try expectProblem(rt, "\"thrower\": nope");
    try expectProblem(rt, "\"../evil\": names are");
    // The first `dup` still registered before the second failed.
    try testz.expectTrue(rt.find("dup") != null);
}

pub fn commandErrorGoesToTheStatuslineTest(io: std.Io, alloc: std.mem.Allocator) !void {
    var s = try Scratch.init(io, alloc, "cmderr");
    defer s.deinit();
    try s.file("e.lua",
        \\zoe.command("boom", function() error("it broke", 0) end)
        \\zoe.command("late", function() zoe.command("more", function() end) end)
        \\zoe.command("where", function() zoe.line() end)
    );
    var fake = try Fake.init(io, alloc, "x\n");
    defer fake.deinit();
    const rt = try start(io, alloc, &fake, "config = { extensions = { \"e\" } }", s.path);
    defer rt.deinit();
    try expectNoProblems(rt);

    try run(rt, "boom");
    try testz.expectEqualStr(fake.message.items, "boom: it broke");
    try run(rt, "late");
    try testz.expectTrue(std.mem.indexOf(u8, fake.message.items, "only an extension loading") != null);
    fake.focused = false;
    try run(rt, "where");
    try testz.expectEqualStr(fake.message.items, "where: zoe.line: no text buffer has the focus");
}

pub fn runawayCommandIsStoppedTest(io: std.Io, alloc: std.mem.Allocator) !void {
    var s = try Scratch.init(io, alloc, "runaway");
    defer s.deinit();
    try s.file("spin.lua", "zoe.command(\"spin\", function() while true do end end)");
    var fake = try Fake.init(io, alloc, "");
    defer fake.deinit();
    const rt = try start(io, alloc, &fake, "config = { extensions = { \"spin\" } }", s.path);
    defer rt.deinit();
    rt.step_limit = 1_000_000;
    try run(rt, "spin");
    try testz.expectTrue(std.mem.indexOf(u8, fake.message.items, "ran too long") != null);
    // And the state is still usable afterwards.
    try run(rt, "spin");
    try testz.expectTrue(std.mem.indexOf(u8, fake.message.items, "ran too long") != null);
}

pub fn osExitIsNotAvailableTest(io: std.Io, alloc: std.mem.Allocator) !void {
    var s = try Scratch.init(io, alloc, "exit");
    defer s.deinit();
    try s.file("quit.lua", "zoe.command(\"quit\", function() os.exit(1) end)");
    var fake = try Fake.init(io, alloc, "");
    defer fake.deinit();
    const rt = try start(io, alloc, &fake, "config = { extensions = { \"quit\" } }", s.path);
    defer rt.deinit();
    try run(rt, "quit");
    try testz.expectTrue(std.mem.indexOf(u8, fake.message.items, "exit") != null);
}

pub fn oneCommandIsOneUndoStepTest(io: std.Io, alloc: std.mem.Allocator) !void {
    var s = try Scratch.init(io, alloc, "undo");
    defer s.deinit();
    try s.file("both.lua",
        \\zoe.command("both", function()
        \\    zoe.set_line(1, "ONE")
        \\    zoe.set_line(2, "TWO")
        \\end)
    );
    var fake = try Fake.init(io, alloc, "one\ntwo\n");
    defer fake.deinit();
    const rt = try start(io, alloc, &fake, "config = { extensions = { \"both\" } }", s.path);
    defer rt.deinit();
    try run(rt, "both");
    try expectText(&fake, "ONE\nTWO\n");
    _ = try keys.feed(&fake.ed, "u");
    try expectText(&fake, "one\ntwo\n");
}

pub fn setLineRefusesALineBreakTest(io: std.Io, alloc: std.mem.Allocator) !void {
    var s = try Scratch.init(io, alloc, "newline");
    defer s.deinit();
    try s.file("nl.lua", "zoe.command(\"nl\", function() zoe.set_line(\"a\\nb\") end)");
    var fake = try Fake.init(io, alloc, "x\n");
    defer fake.deinit();
    const rt = try start(io, alloc, &fake, "config = { extensions = { \"nl\" } }", s.path);
    defer rt.deinit();
    try run(rt, "nl");
    try expectText(&fake, "x\n");
    try testz.expectTrue(std.mem.indexOf(u8, fake.message.items, "line break") != null);
}

pub fn configKeysBindOverAnExtensionsOwnTest(io: std.Io, alloc: std.mem.Allocator) !void {
    var s = try Scratch.init(io, alloc, "keys");
    defer s.deinit();
    try s.file("k.lua",
        \\zoe.command("first", function() end)
        \\zoe.command("second", function() end)
        \\zoe.bind("global", "ctrl+alt+a", "first")
        \\zoe.bind("global", "ctrl+alt+b", "first")
    );
    var fake = try Fake.init(io, alloc, "");
    defer fake.deinit();
    const rt = try start(io, alloc, &fake, "config = { extensions = { \"k\" } }", s.path);
    defer rt.deinit();
    try expectNoProblems(rt);

    const named = [_]actions.NamedOverride{
        .{ .scope = .normal, .chord = try keybind.Chord.parse("ctrl+alt+c"), .name = "second" },
        .{ .scope = .global, .chord = try keybind.Chord.parse("ctrl+alt+b"), .name = "second" },
        .{ .scope = .global, .chord = try keybind.Chord.parse("ctrl+alt+d"), .name = "nothing" },
    };
    // A built-in action (or `false`) on an extension's chord takes it back.
    const plain = [_]actions.Override{
        .{ .scope = .global, .chord = try keybind.Chord.parse("ctrl+alt+a"), .action = .save },
    };
    rt.resolveKeys(&named, &plain);

    const ca: keybind.Mods = .{ .ctrl = true, .alt = true };
    try testz.expectTrue(rt.lookup(.global, "a", ca) == null);
    try testz.expectEqual(rt.lookup(.global, "b", ca).?, rt.find("second").?);
    try testz.expectEqual(rt.lookup(.normal, "c", ca).?, rt.find("second").?);
    try testz.expectTrue(rt.lookup(.global, "c", ca) == null);
    try expectProblem(rt, "\"nothing\": unknown action or command");
}

pub fn langconfHoldsBackCommandNamesTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var env = std.process.Environ.Map.init(alloc);
    defer env.deinit();
    var cfg = zoe.langconf.parseSource(alloc,
        \\config = { keys = { normal = { ["ctrl+t"] = "taskToggle", ["ctrl+s"] = "save" } } }
    , &env, zoe.langconf.defaults(alloc));
    defer cfg.deinit();
    try testz.expectEqual(cfg.keys.len, @as(usize, 1));
    try testz.expectEqual(cfg.command_keys.len, @as(usize, 1));
    try testz.expectEqualStr(cfg.command_keys[0].name, "taskToggle");
    try testz.expectTrue(cfg.source != null);
}

// ── task_journal ────────────────────────────────────────────────────────

fn journal(io: std.Io, alloc: std.mem.Allocator, fake: *Fake, opts: []const u8) !*ext.Runtime {
    const src = try std.fmt.allocPrintSentinel(alloc, "config = {{ extensions = {{ task_journal = {{ {s} }} }} }}", .{opts}, 0);
    defer alloc.free(src);
    const rt = try start(io, alloc, fake, src, null);
    try expectNoProblems(rt);
    return rt;
}

pub fn taskIncreaseCyclesTheStatesTest(io: std.Io, alloc: std.mem.Allocator) !void {
    var fake = try Fake.init(io, alloc, "  buy milk\n");
    defer fake.deinit();
    const rt = try journal(io, alloc, &fake, "");
    defer rt.deinit();
    const steps = [_][]const u8{
        "  - [ ] buy milk\n",
        "  - [◔] buy milk\n",
        "  - [◑] buy milk\n",
        "  - [◕] buy milk\n",
        "  - [✓] buy milk\n",
        "  - [ ] buy milk\n",
    };
    for (steps) |want| {
        try run(rt, "taskIncrease");
        try expectText(&fake, want);
    }
}

pub fn taskDecreaseWrapsToDoneTest(io: std.Io, alloc: std.mem.Allocator) !void {
    var fake = try Fake.init(io, alloc, "- [ ] x\n");
    defer fake.deinit();
    const rt = try journal(io, alloc, &fake, "");
    defer rt.deinit();
    try run(rt, "taskDecrease");
    try expectText(&fake, "- [✓] x\n");
    try run(rt, "taskDecrease");
    try expectText(&fake, "- [◕] x\n");
}

pub fn taskToggleFlipsDoneAndNotStartedTest(io: std.Io, alloc: std.mem.Allocator) !void {
    var fake = try Fake.init(io, alloc, "- [◑] x\n");
    defer fake.deinit();
    const rt = try journal(io, alloc, &fake, "");
    defer rt.deinit();
    try run(rt, "taskToggle");
    try expectText(&fake, "- [✓] x\n");
    try run(rt, "taskToggle");
    try expectText(&fake, "- [ ] x\n");
    // A state that isn't in the list counts as not done.
    try fake.ed.loadText("- [x] y\n", null);
    try run(rt, "taskToggle");
    try expectText(&fake, "- [✓] y\n");
}

pub fn taskPatternAndStatesAreConfigurableTest(io: std.Io, alloc: std.mem.Allocator) !void {
    var fake = try Fake.init(io, alloc, "x\n");
    defer fake.deinit();
    const rt = try journal(io, alloc, &fake, "task_pattern = \"* <$> \", progress_states = { \".\", \"o\", \"O\" }");
    defer rt.deinit();
    try run(rt, "taskIncrease");
    try expectText(&fake, "* <.> x\n");
    try run(rt, "taskIncrease");
    try expectText(&fake, "* <o> x\n");
    try run(rt, "taskToggle");
    try expectText(&fake, "* <O> x\n");
}

pub fn taskTagsToggleIndependentlyTest(io: std.Io, alloc: std.mem.Allocator) !void {
    var fake = try Fake.init(io, alloc, "- [ ] fix it\n");
    defer fake.deinit();
    const rt = try journal(io, alloc, &fake, "tags = { \"MGMT\", \"BUG\" }");
    defer rt.deinit();
    // Only the configured tags get a command.
    try testz.expectTrue(rt.find("taskTag2") == null);

    try run(rt, "taskTag0");
    try expectText(&fake, "- [ ] (MGMT) fix it\n");
    try run(rt, "taskTag1");
    try expectText(&fake, "- [ ] (MGMT, BUG) fix it\n");
    try run(rt, "taskTag0");
    try expectText(&fake, "- [ ] (BUG) fix it\n");
    try run(rt, "taskTag1");
    try expectText(&fake, "- [ ] fix it\n");

    // A plain line becomes a tagged task.
    try fake.ed.loadText("call Bob\n", null);
    try run(rt, "taskTag1");
    try expectText(&fake, "- [ ] (BUG) call Bob\n");
}

pub fn taskJournalBadOptionIsAProblemTest(io: std.Io, alloc: std.mem.Allocator) !void {
    var fake = try Fake.init(io, alloc, "");
    defer fake.deinit();
    const rt = try start(io, alloc, &fake, "config = { extensions = { task_journal = { task_pattern = \"no dollar\" } } }", null);
    defer rt.deinit();
    try expectProblem(rt, "task_pattern has no `$`");
}

pub fn taskJournalDefaultKeysAreOptionalTest(io: std.Io, alloc: std.mem.Allocator) !void {
    const mods: keybind.Mods = .{ .ctrl = true, .alt = true, .super = true };
    var fake = try Fake.init(io, alloc, "");
    defer fake.deinit();
    const on = try journal(io, alloc, &fake, "");
    defer on.deinit();
    try testz.expectEqual(on.lookup(.global, "t", mods).?, on.find("journalToday").?);
    try testz.expectEqual(on.lookup(.global, "backslash", mods).?, on.find("taskToggle").?);

    const off = try journal(io, alloc, &fake, "default_keys = false");
    defer off.deinit();
    try testz.expectEqual(off.bindings.items.len, @as(usize, 0));
}

pub fn journalTodayCreatesTheEntryOnceTest(io: std.Io, alloc: std.mem.Allocator) !void {
    var s = try Scratch.init(io, alloc, "today");
    defer s.deinit();
    var fake = try Fake.init(io, alloc, "");
    defer fake.deinit();
    const opts = try std.fmt.allocPrint(alloc, "data_directory = \"{s}/journal/\", entry_template = \"Day $dd.$mm.$yyyy ($date)\\n\"", .{s.path});
    defer alloc.free(opts);
    const rt = try journal(io, alloc, &fake, opts);
    defer rt.deinit();

    try run(rt, "journalToday");
    try testz.expectEqualStr(fake.message.items, "");
    const path = fake.lastOpened();
    // `<dir>/journal/YYYY-MM-DD.md`, the directory made on the way.
    const name = std.fs.path.basename(path);
    try testz.expectEqual(name.len, @as(usize, "YYYY-MM-DD.md".len));
    try testz.expectEqualStr(name[10..], ".md");
    const want = try std.fmt.allocPrint(alloc, "Day {s}.{s}.{s} ({s}/{s}/{s})\n", .{
        name[8..10], name[5..7], name[0..4], name[0..4], name[5..7], name[8..10],
    });
    defer alloc.free(want);
    try expectText(&fake, want);

    // Opening it again leaves what's been written alone.
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = "notes\n" });
    try run(rt, "journalToday");
    try expectText(&fake, "notes\n");
}

pub fn journalTomorrowIsTheNextDayTest(io: std.Io, alloc: std.mem.Allocator) !void {
    var s = try Scratch.init(io, alloc, "tomorrow");
    defer s.deinit();
    var fake = try Fake.init(io, alloc, "");
    defer fake.deinit();
    const opts = try std.fmt.allocPrint(alloc, "data_directory = \"{s}\"", .{s.path});
    defer alloc.free(opts);
    const rt = try journal(io, alloc, &fake, opts);
    defer rt.deinit();

    try run(rt, "journalToday");
    const today = try alloc.dupe(u8, std.fs.path.basename(fake.lastOpened()));
    defer alloc.free(today);
    try run(rt, "journalTomorrow");
    const tomorrow = std.fs.path.basename(fake.lastOpened());
    try testz.expectTrue(std.mem.lessThan(u8, today, tomorrow));
}

pub fn journalStepsThroughEntriesAndWrapsTest(io: std.Io, alloc: std.mem.Allocator) !void {
    var s = try Scratch.init(io, alloc, "step");
    defer s.deinit();
    try s.file("2026-01-02.md", "two\n");
    try s.file("2026-01-01.md", "one\n");
    try s.file("2026-01-03.md", "three\n");
    try s.file("notes.txt", "not an entry\n");
    var fake = try Fake.init(io, alloc, "elsewhere\n");
    defer fake.deinit();
    const opts = try std.fmt.allocPrint(alloc, "data_directory = \"{s}\"", .{s.path});
    defer alloc.free(opts);
    const rt = try journal(io, alloc, &fake, opts);
    defer rt.deinit();

    // From a buffer outside the journal: the latest entry.
    try run(rt, "journalPrevious");
    try expectText(&fake, "three\n");
    try run(rt, "journalNext");
    try expectText(&fake, "one\n");
    try run(rt, "journalPrevious");
    try expectText(&fake, "three\n");
    try run(rt, "journalPrevious");
    try expectText(&fake, "two\n");
}

pub fn journalStepWithNoEntriesSaysSoTest(io: std.Io, alloc: std.mem.Allocator) !void {
    var s = try Scratch.init(io, alloc, "empty");
    defer s.deinit();
    var fake = try Fake.init(io, alloc, "");
    defer fake.deinit();
    const opts = try std.fmt.allocPrint(alloc, "data_directory = \"{s}\"", .{s.path});
    defer alloc.free(opts);
    const rt = try journal(io, alloc, &fake, opts);
    defer rt.deinit();
    try run(rt, "journalNext");
    try testz.expectTrue(std.mem.startsWith(u8, fake.message.items, "No journal entries in "));
    try testz.expectEqual(fake.opened.items.len, @as(usize, 0));
}

// ── The extension list ──────────────────────────────────────────────────

fn enabledEntry(rt: *ext.Runtime, name: []const u8) ?ext.Enabled {
    for (rt.enabled.items) |e| {
        if (std.mem.eql(u8, e.name, name)) return e;
    }
    return null;
}

pub fn runtimeRecordsWhatCameOfEachNameTest(io: std.Io, alloc: std.mem.Allocator) !void {
    var s = try Scratch.init(io, alloc, "enabled");
    defer s.deinit();
    try s.file("two.lua", "zoe.command(\"a\", function() end) zoe.command(\"b\", function() end)");
    try s.file("half.lua", "zoe.command(\"c\", function() end) error(\"boom\", 0)");
    try s.file("quiet.lua", "zoe.command(\"d\", function() end)");
    var fake = try Fake.init(io, alloc, "");
    defer fake.deinit();
    const rt = try start(io, alloc, &fake, "config = { extensions = { \"two\", \"half\", \"gone\", quiet = false, \"../bad\" } }", s.path);
    defer rt.deinit();

    // Sorted, and the invalid name is only a problem.
    try testz.expectEqual(rt.enabled.items.len, @as(usize, 4));
    try testz.expectEqualStr(rt.enabled.items[0].name, "gone");
    try testz.expectEqualStr(rt.enabled.items[3].name, "two");

    const two = enabledEntry(rt, "two").?;
    try testz.expectTrue(two.state == .loaded);
    try testz.expectEqual(two.commands, @as(u32, 2));
    const half = enabledEntry(rt, "half").?;
    try testz.expectTrue(half.state == .failed);
    try testz.expectEqualStr(half.err.?, "boom");
    try testz.expectEqual(half.commands, @as(u32, 1));
    try testz.expectTrue(enabledEntry(rt, "gone").?.state == .not_found);
    try testz.expectTrue(enabledEntry(rt, "quiet").?.state == .off);
    try testz.expectTrue(rt.find("d") == null);
}

pub fn listedAndTurnedOffLoadsTest(io: std.Io, alloc: std.mem.Allocator) !void {
    var s = try Scratch.init(io, alloc, "both");
    defer s.deinit();
    try s.file("a.lua", "zoe.command(\"cmdA\", function() end)");
    var fake = try Fake.init(io, alloc, "");
    defer fake.deinit();
    const rt = try start(io, alloc, &fake, "config = { extensions = { \"a\", a = false } }", s.path);
    defer rt.deinit();
    try testz.expectEqual(rt.enabled.items.len, @as(usize, 1));
    try testz.expectTrue(rt.enabled.items[0].state == .loaded);
}

pub fn extensionListMergesItsSourcesTest(_: std.Io, alloc: std.mem.Allocator) !void {
    const built_in = [_][]const u8{ "task_journal", "zeta" };
    const user = [_][]const u8{ "task_journal", "mine", "broken" };
    const enabled = [_]ext.Enabled{
        .{ .name = "broken", .state = .failed, .err = "...zoe/extensions/broken.lua:1: oops" },
        .{ .name = "ghost", .state = .not_found },
        .{ .name = "task_journal", .state = .loaded, .commands = 6 },
        .{ .name = "zeta", .state = .off },
    };
    var list = try extlist.build(alloc, &built_in, &user, "/cfg/zoe/extensions", "~/zoe/extensions", &enabled);
    defer list.deinit();

    const names = [_][]const u8{ "broken", "ghost", "mine", "task_journal", "zeta" };
    try testz.expectEqual(list.entries.items.len, names.len);
    for (names, list.entries.items) |n, e| try testz.expectEqualStr(e.name, n);
    try testz.expectEqualStr(list.user_dir.?, "~/zoe/extensions");

    const broken = list.entries.items[0];
    try testz.expectTrue(broken.origin == .user and broken.status == .failed);
    try testz.expectEqualStr(broken.err.?, "line 1: oops");
    try testz.expectEqualStr(broken.path.?, "/cfg/zoe/extensions/broken.lua");

    const ghost = list.entries.items[1];
    try testz.expectTrue(ghost.origin == .none and ghost.status == .not_found);
    try testz.expectTrue(ghost.path == null);

    const mine = list.entries.items[2];
    try testz.expectTrue(mine.origin == .user and mine.status == .not_enabled);

    const tj = list.entries.items[3];
    try testz.expectTrue(tj.origin == .user_over_built_in and tj.status == .loaded);
    var buf: [48]u8 = undefined;
    try testz.expectEqualStr(tj.statusText(&buf), "loaded, 6 commands");

    const zeta = list.entries.items[4];
    try testz.expectTrue(zeta.origin == .built_in and zeta.status == .off);
    try testz.expectTrue(zeta.path == null);
}

pub fn extensionListShortensLuaErrorsTest(_: std.Io, alloc: std.mem.Allocator) !void {
    const cases = [_]struct { in: []const u8, out: []const u8 }{
        .{ .in = "...ions/broken.lua:3: attempt to index a nil value", .out = "line 3: attempt to index a nil value" },
        .{ .in = "task_journal.lua (built in):12: bad option", .out = "task_journal.lua (built in):12: bad option" },
        .{ .in = "nope", .out = "nope" },
        .{ .in = "x.lua:abc", .out = "x.lua:abc" },
    };
    for (cases) |c| {
        const got = try extlist.shortError(alloc, c.in);
        defer alloc.free(got);
        try testz.expectEqualStr(got, c.out);
    }
}

pub fn extensionListRowsAndCursorTest(_: std.Io, alloc: std.mem.Allocator) !void {
    const built_in = [_][]const u8{ "a", "c", "d" };
    const user = [_][]const u8{"b"};
    const enabled = [_]ext.Enabled{
        .{ .name = "b", .state = .failed, .err = "no" },
    };
    var list = try extlist.build(alloc, &built_in, &user, "/x", "/x", &enabled);
    defer list.deinit();

    // a, b and its error row, c, d.
    try testz.expectEqual(list.rowCount(), @as(usize, 5));
    try testz.expectEqual(list.firstRow(2), @as(usize, 3));
    try testz.expectEqual(list.entryAtRow(2).?, @as(usize, 1));
    try testz.expectEqual(list.entryAtRow(3).?, @as(usize, 2));
    try testz.expectTrue(list.entryAtRow(5) == null);

    // Clamped at both ends.
    list.moveCursor(-1);
    try testz.expectEqual(list.selected, @as(usize, 0));
    list.moveCursor(10);
    try testz.expectEqual(list.selected, @as(usize, 3));

    // Two rows tall: following `b` keeps both its rows in view.
    list.selected = 1;
    list.top = 0;
    list.follow(2);
    try testz.expectEqual(list.top, @as(usize, 1));
    list.selected = 3;
    list.follow(2);
    try testz.expectEqual(list.top, @as(usize, 3));
}

pub fn extensionListReadsTheUserDirectoryTest(io: std.Io, alloc: std.mem.Allocator) !void {
    var s = try Scratch.init(io, alloc, "userfiles");
    defer s.deinit();
    try s.file("good.lua", "");
    try s.file("also-good.lua", "");
    try s.file("notes.txt", "");
    try s.file("bad.name.lua", "");
    try s.dir.createDirPath(io, "folder.lua");

    const names = try extlist.userFiles(alloc, io, s.path);
    defer extlist.freeNames(alloc, names);
    ext.sortNames(names);
    try testz.expectEqual(names.len, @as(usize, 2));
    try testz.expectEqualStr(names[0], "also-good");
    try testz.expectEqualStr(names[1], "good");

    const none = try extlist.userFiles(alloc, io, "/nonexistent/zoe-ext-test");
    defer extlist.freeNames(alloc, none);
    try testz.expectEqual(none.len, @as(usize, 0));
}
