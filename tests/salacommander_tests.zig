// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: GPL-3.0-or-later

const std = @import("std");
const testz = @import("testz");

// salacommander's windowless pieces, gathered in `salacommander_support`
// (see build.zig) so they can be exercised here against real temporary
// directories.
const sala = @import("salacommander_support");
const Pane = sala.pane.Pane;
const fileops = sala.fileops;
const dialog = sala.dialog;
const actions = sala.actions;
const openaction = sala.openaction;
const config = sala.config;

/// A scratch directory under the cwd, removed by `deinit`. `label` keeps
/// tests that run on the same thread from sharing one.
const Scratch = struct {
    io: std.Io,
    alloc: std.mem.Allocator,
    /// Absolute.
    path: []u8,
    dir: std.Io.Dir,

    fn init(io: std.Io, alloc: std.mem.Allocator, label: []const u8) !Scratch {
        const rel = try std.fmt.allocPrint(alloc, "salacommander-test-{s}-{d}", .{ label, std.Thread.getCurrentId() });
        defer alloc.free(rel);
        std.Io.Dir.cwd().deleteTree(io, rel) catch {};
        try std.Io.Dir.cwd().createDirPath(io, rel);
        const cwd = try std.process.currentPathAlloc(io, alloc);
        defer alloc.free(cwd);
        const path = try std.fs.path.join(alloc, &.{ cwd, rel });
        errdefer alloc.free(path);
        return .{ .io = io, .alloc = alloc, .path = path, .dir = try std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) };
    }

    fn deinit(self: *Scratch) void {
        self.dir.close(self.io);
        std.Io.Dir.cwd().deleteTree(self.io, self.path) catch {};
        self.alloc.free(self.path);
    }

    fn file(self: *Scratch, name: []const u8, contents: []const u8) !void {
        try self.dir.writeFile(self.io, .{ .sub_path = name, .data = contents });
    }

    fn mkdir(self: *Scratch, name: []const u8) !void {
        try self.dir.createDirPath(self.io, name);
    }

    /// Absolute path of `name` inside the scratch dir. Caller frees.
    fn abs(self: *Scratch, name: []const u8) ![]u8 {
        return std.fs.path.join(self.alloc, &.{ self.path, name });
    }

    fn exists(self: *Scratch, name: []const u8) bool {
        _ = self.dir.statFile(self.io, name, .{ .follow_symlinks = false }) catch return false;
        return true;
    }

    fn read(self: *Scratch, name: []const u8) ![]u8 {
        return self.dir.readFileAlloc(self.io, name, self.alloc, .limited(1 << 20));
    }
};

fn rowName(p: *const Pane, row: usize) []const u8 {
    return if (p.entryAt(row)) |e| e.name else "..";
}

// ─── Pane ───────────────────────────────────────────────────────────────

pub fn paneListsParentThenDirsThenFilesTest(io: std.Io, alloc: std.mem.Allocator) !void {
    var s = try Scratch.init(io, alloc, "order");
    defer s.deinit();
    try s.file("b.txt", "");
    try s.file("A.txt", "");
    try s.mkdir("zdir");
    try s.file(".hidden", "");

    var p = try Pane.init(alloc, io, s.path, .{});
    defer p.deinit();
    try testz.expectEqual(p.rowCount(), 4);
    try testz.expectEqualStr(rowName(&p, 0), "..");
    try testz.expectEqualStr(rowName(&p, 1), "zdir");
    try testz.expectEqualStr(rowName(&p, 2), "A.txt");
    try testz.expectEqualStr(rowName(&p, 3), "b.txt");

    try p.setShowHidden(true);
    try testz.expectEqual(p.rowCount(), 5);
    try testz.expectTrue(p.rowOf(".hidden") != null);
}

pub fn paneMarksSkipTheParentRowTest(io: std.Io, alloc: std.mem.Allocator) !void {
    var s = try Scratch.init(io, alloc, "marks");
    defer s.deinit();
    try s.file("a", "12345");
    try s.file("b", "123");

    var p = try Pane.init(alloc, io, s.path, .{});
    defer p.deinit();
    p.toggleMark(0); // `..`
    try testz.expectEqual(p.markedCount(), 0);
    p.toggleMark(1);
    p.toggleMark(2);
    try testz.expectEqual(p.markedCount(), 2);
    try testz.expectEqual(p.markedBytes(), 8);
    p.invertMarks();
    try testz.expectEqual(p.markedCount(), 0);
}

pub fn paneSelectionIsMarksElseCursorTest(io: std.Io, alloc: std.mem.Allocator) !void {
    var s = try Scratch.init(io, alloc, "selection");
    defer s.deinit();
    try s.file("a", "");
    try s.file("b", "");
    try s.file("c", "");

    var p = try Pane.init(alloc, io, s.path, .{});
    defer p.deinit();

    // On `..` with nothing marked: nothing to act on.
    const none = try p.selection(alloc);
    defer alloc.free(none);
    try testz.expectEqual(none.len, 0);

    p.setCursor(2);
    const one = try p.selection(alloc);
    defer alloc.free(one);
    try testz.expectEqual(one.len, 1);
    try testz.expectEqualStr(std.fs.path.basename(one[0]), "b");

    p.toggleMark(1);
    p.toggleMark(3);
    const marked = try p.selection(alloc);
    defer alloc.free(marked);
    try testz.expectEqual(marked.len, 2);
    try testz.expectEqualStr(std.fs.path.basename(marked[0]), "a");
    try testz.expectEqualStr(std.fs.path.basename(marked[1]), "c");
}

pub fn paneUpToParentLandsOnTheDirLeftTest(io: std.Io, alloc: std.mem.Allocator) !void {
    var s = try Scratch.init(io, alloc, "updir");
    defer s.deinit();
    try s.mkdir("alpha");
    try s.mkdir("beta/inner");

    var p = try Pane.init(alloc, io, s.path, .{});
    defer p.deinit();
    p.setCursor(p.rowOf("beta").?);
    try testz.expectTrue((try p.enter()) == .changed_dir);
    try testz.expectEqualStr(std.fs.path.basename(p.path), "beta");
    try testz.expectEqual(p.cursor, 0);

    try testz.expectTrue(try p.upToParentDir());
    try testz.expectEqualStr(p.path, s.path);
    try testz.expectEqualStr(rowName(&p, p.cursor), "beta");
}

pub fn paneEnterOnParentRowGoesUpTest(io: std.Io, alloc: std.mem.Allocator) !void {
    var s = try Scratch.init(io, alloc, "enterparent");
    defer s.deinit();
    try s.mkdir("sub");
    const sub = try s.abs("sub");
    defer alloc.free(sub);

    var p = try Pane.init(alloc, io, sub, .{});
    defer p.deinit();
    try testz.expectTrue(p.isParentRow(p.cursor));
    try testz.expectTrue((try p.enter()) == .changed_dir);
    try testz.expectEqualStr(p.path, s.path);
    try testz.expectEqualStr(rowName(&p, p.cursor), "sub");
}

pub fn paneReloadKeepsCursorAndMarksByNameTest(io: std.Io, alloc: std.mem.Allocator) !void {
    var s = try Scratch.init(io, alloc, "reload");
    defer s.deinit();
    try s.file("b", "");
    try s.file("d", "");

    var p = try Pane.init(alloc, io, s.path, .{});
    defer p.deinit();
    p.setCursor(p.rowOf("d").?);
    p.toggleMark(p.rowOf("b").?);

    // New entries sort in ahead of both.
    try s.file("a", "");
    try s.file("c", "");
    try p.reload();
    try testz.expectEqualStr(rowName(&p, p.cursor), "d");
    try testz.expectTrue(p.isMarked(p.rowOf("b").?));
    try testz.expectFalse(p.isMarked(p.rowOf("a").?));
    try testz.expectEqual(p.markedCount(), 1);
}

pub fn paneScrollKeepsCursorVisibleTest(io: std.Io, alloc: std.mem.Allocator) !void {
    var s = try Scratch.init(io, alloc, "scroll");
    defer s.deinit();
    var name_buf: [8]u8 = undefined;
    for (0..20) |i| try s.file(try std.fmt.bufPrint(&name_buf, "f{d:0>2}", .{i}), "");

    var p = try Pane.init(alloc, io, s.path, .{});
    defer p.deinit();
    // 21 rows (`..` + 20), 5 visible.
    p.setCursor(12);
    p.scrollIntoView(5);
    try testz.expectEqual(p.top, 8);
    p.cursorEnd();
    p.scrollIntoView(5);
    try testz.expectEqual(p.top, 16);

    // A wheel scroll to the top drags the cursor back on screen.
    p.scrollTo(0, 5);
    try testz.expectEqual(p.top, 0);
    try testz.expectEqual(p.cursor, 4);
}

pub fn paneLoadFailureLeavesPaneUnchangedTest(io: std.Io, alloc: std.mem.Allocator) !void {
    var s = try Scratch.init(io, alloc, "loadfail");
    defer s.deinit();
    try s.file("keep", "");

    var p = try Pane.init(alloc, io, s.path, .{});
    defer p.deinit();
    const missing = try s.abs("missing");
    defer alloc.free(missing);
    if (p.load(missing)) |_| return error.LoadShouldHaveFailed else |_| {}
    try testz.expectEqualStr(p.path, s.path);
    try testz.expectTrue(p.rowOf("keep") != null);
}

// ─── File operations ────────────────────────────────────────────────────

/// Hooks that answer every conflict with `answer` and count the calls.
const Scripted = struct {
    answer: fileops.Conflict,
    conflicts: usize = 0,
    errors: usize = 0,

    fn hooks(self: *Scripted) fileops.Hooks {
        return .{ .ctx = self, .onConflict = onConflict, .onProgress = onProgress, .onError = onError };
    }
    fn onConflict(ctx: *anyopaque, _: []const u8, _: []const u8) fileops.Conflict {
        const self: *Scripted = @ptrCast(@alignCast(ctx));
        self.conflicts += 1;
        return self.answer;
    }
    fn onProgress(_: *anyopaque, _: fileops.Kind, _: usize, _: usize, _: []const u8) void {}
    fn onError(ctx: *anyopaque, _: []const u8, _: anyerror) bool {
        const self: *Scripted = @ptrCast(@alignCast(ctx));
        self.errors += 1;
        return true;
    }
};

pub fn copyFilesIntoDirectoryTest(io: std.Io, alloc: std.mem.Allocator) !void {
    var s = try Scratch.init(io, alloc, "copyfiles");
    defer s.deinit();
    try s.file("a.txt", "alpha");
    try s.file("b.txt", "beta");
    try s.mkdir("dest");
    const a = try s.abs("a.txt");
    defer alloc.free(a);
    const b = try s.abs("b.txt");
    defer alloc.free(b);
    const dest = try s.abs("dest");
    defer alloc.free(dest);

    const r = (fileops.Operation{ .kind = .copy, .sources = &.{ a, b }, .dest = dest }).run(io, alloc, fileops.quiet_hooks);
    try testz.expectEqual(r.done, 2);
    try testz.expectEqual(r.failed, 0);
    const got = try s.read("dest/a.txt");
    defer alloc.free(got);
    try testz.expectEqualStr(got, "alpha");
    try testz.expectTrue(s.exists("a.txt"));
}

pub fn copyDirectoryRecursesTest(io: std.Io, alloc: std.mem.Allocator) !void {
    var s = try Scratch.init(io, alloc, "copytree");
    defer s.deinit();
    try s.mkdir("src/deep/er");
    try s.file("src/top.txt", "t");
    try s.file("src/deep/er/leaf.txt", "leaf");
    try s.mkdir("dest");
    const src = try s.abs("src");
    defer alloc.free(src);
    const dest = try s.abs("dest");
    defer alloc.free(dest);

    const r = (fileops.Operation{ .kind = .copy, .sources = &.{src}, .dest = dest }).run(io, alloc, fileops.quiet_hooks);
    try testz.expectEqual(r.failed, 0);
    const leaf = try s.read("dest/src/deep/er/leaf.txt");
    defer alloc.free(leaf);
    try testz.expectEqualStr(leaf, "leaf");
    try testz.expectTrue(s.exists("dest/src/top.txt"));
}

pub fn copyConflictSkipLeavesTargetAloneTest(io: std.Io, alloc: std.mem.Allocator) !void {
    var s = try Scratch.init(io, alloc, "copyskip");
    defer s.deinit();
    try s.file("a.txt", "new");
    try s.mkdir("dest");
    try s.file("dest/a.txt", "old");
    const a = try s.abs("a.txt");
    defer alloc.free(a);
    const dest = try s.abs("dest");
    defer alloc.free(dest);

    var script: Scripted = .{ .answer = .skip };
    const r = (fileops.Operation{ .kind = .copy, .sources = &.{a}, .dest = dest }).run(io, alloc, script.hooks());
    try testz.expectEqual(script.conflicts, 1);
    try testz.expectEqual(r.skipped, 1);
    const got = try s.read("dest/a.txt");
    defer alloc.free(got);
    try testz.expectEqualStr(got, "old");
}

pub fn copyConflictOverwriteAllAsksOnceTest(io: std.Io, alloc: std.mem.Allocator) !void {
    var s = try Scratch.init(io, alloc, "copyall");
    defer s.deinit();
    try s.file("a", "new-a");
    try s.file("b", "new-b");
    try s.mkdir("dest");
    try s.file("dest/a", "old");
    try s.file("dest/b", "old");
    const a = try s.abs("a");
    defer alloc.free(a);
    const b = try s.abs("b");
    defer alloc.free(b);
    const dest = try s.abs("dest");
    defer alloc.free(dest);

    var script: Scripted = .{ .answer = .overwrite_all };
    const r = (fileops.Operation{ .kind = .copy, .sources = &.{ a, b }, .dest = dest }).run(io, alloc, script.hooks());
    try testz.expectEqual(script.conflicts, 1);
    try testz.expectEqual(r.done, 2);
    const got = try s.read("dest/b");
    defer alloc.free(got);
    try testz.expectEqualStr(got, "new-b");
}

pub fn copyConflictCancelStopsTheRunTest(io: std.Io, alloc: std.mem.Allocator) !void {
    var s = try Scratch.init(io, alloc, "copycancel");
    defer s.deinit();
    try s.file("a", "x");
    try s.file("b", "y");
    try s.mkdir("dest");
    try s.file("dest/a", "old");
    const a = try s.abs("a");
    defer alloc.free(a);
    const b = try s.abs("b");
    defer alloc.free(b);
    const dest = try s.abs("dest");
    defer alloc.free(dest);

    var script: Scripted = .{ .answer = .cancel };
    const r = (fileops.Operation{ .kind = .copy, .sources = &.{ a, b }, .dest = dest }).run(io, alloc, script.hooks());
    try testz.expectTrue(r.cancelled);
    try testz.expectFalse(s.exists("dest/b"));
}

pub fn copyDirectoryIntoItselfFailsTest(io: std.Io, alloc: std.mem.Allocator) !void {
    var s = try Scratch.init(io, alloc, "copyself");
    defer s.deinit();
    try s.mkdir("d/inner");
    const d = try s.abs("d");
    defer alloc.free(d);
    const inner = try s.abs("d/inner");
    defer alloc.free(inner);

    var script: Scripted = .{ .answer = .skip };
    const r = (fileops.Operation{ .kind = .copy, .sources = &.{d}, .dest = inner }).run(io, alloc, script.hooks());
    try testz.expectEqual(r.failed, 1);
    try testz.expectEqual(r.first_error.?, error.DestInsideSource);
    try testz.expectFalse(s.exists("d/inner/d"));
}

pub fn severalSourcesNeedADirectoryDestinationTest(io: std.Io, alloc: std.mem.Allocator) !void {
    var s = try Scratch.init(io, alloc, "notdir");
    defer s.deinit();
    try s.file("a", "");
    try s.file("b", "");
    const a = try s.abs("a");
    defer alloc.free(a);
    const b = try s.abs("b");
    defer alloc.free(b);
    const nowhere = try s.abs("nowhere");
    defer alloc.free(nowhere);

    const r = (fileops.Operation{ .kind = .copy, .sources = &.{ a, b }, .dest = nowhere }).run(io, alloc, fileops.quiet_hooks);
    try testz.expectEqual(r.failed, 2);
    try testz.expectEqual(r.first_error.?, error.DestNotDirectory);
}

pub fn moveSingleSourceRenamesTest(io: std.Io, alloc: std.mem.Allocator) !void {
    var s = try Scratch.init(io, alloc, "rename");
    defer s.deinit();
    try s.file("old.txt", "body");
    const old = try s.abs("old.txt");
    defer alloc.free(old);
    const new = try s.abs("new.txt");
    defer alloc.free(new);

    const r = (fileops.Operation{ .kind = .move, .sources = &.{old}, .dest = new }).run(io, alloc, fileops.quiet_hooks);
    try testz.expectEqual(r.done, 1);
    try testz.expectFalse(s.exists("old.txt"));
    const got = try s.read("new.txt");
    defer alloc.free(got);
    try testz.expectEqualStr(got, "body");
}

pub fn moveDirectoryMergesIntoExistingOneTest(io: std.Io, alloc: std.mem.Allocator) !void {
    var s = try Scratch.init(io, alloc, "movemerge");
    defer s.deinit();
    try s.mkdir("src/stuff");
    try s.file("src/stuff/new.txt", "n");
    try s.mkdir("dest/stuff");
    try s.file("dest/stuff/kept.txt", "k");
    const stuff = try s.abs("src/stuff");
    defer alloc.free(stuff);
    const dest = try s.abs("dest");
    defer alloc.free(dest);

    const r = (fileops.Operation{ .kind = .move, .sources = &.{stuff}, .dest = dest }).run(io, alloc, fileops.quiet_hooks);
    try testz.expectEqual(r.failed, 0);
    try testz.expectTrue(s.exists("dest/stuff/new.txt"));
    try testz.expectTrue(s.exists("dest/stuff/kept.txt"));
    try testz.expectFalse(s.exists("src/stuff"));
}

pub fn moveWithSkippedConflictKeepsTheSourceTest(io: std.Io, alloc: std.mem.Allocator) !void {
    var s = try Scratch.init(io, alloc, "moveskip");
    defer s.deinit();
    try s.mkdir("src/stuff");
    try s.file("src/stuff/clash.txt", "new");
    try s.mkdir("dest/stuff");
    try s.file("dest/stuff/clash.txt", "old");
    const stuff = try s.abs("src/stuff");
    defer alloc.free(stuff);
    const dest = try s.abs("dest");
    defer alloc.free(dest);

    var script: Scripted = .{ .answer = .skip };
    const r = (fileops.Operation{ .kind = .move, .sources = &.{stuff}, .dest = dest }).run(io, alloc, script.hooks());
    try testz.expectEqual(r.skipped, 1);
    // The skipped file was never moved, so the source must survive.
    try testz.expectTrue(s.exists("src/stuff/clash.txt"));
}

pub fn deleteRemovesTreesTest(io: std.Io, alloc: std.mem.Allocator) !void {
    var s = try Scratch.init(io, alloc, "delete");
    defer s.deinit();
    try s.mkdir("tree/a/b");
    try s.file("tree/a/b/c.txt", "");
    try s.file("lone.txt", "");
    const tree = try s.abs("tree");
    defer alloc.free(tree);
    const lone = try s.abs("lone.txt");
    defer alloc.free(lone);

    const r = (fileops.Operation{ .kind = .delete, .sources = &.{ tree, lone } }).run(io, alloc, fileops.quiet_hooks);
    try testz.expectEqual(r.done, 2);
    try testz.expectFalse(s.exists("tree"));
    try testz.expectFalse(s.exists("lone.txt"));
}

pub fn makeDirCreatesParentsAndRefusesExistingTest(io: std.Io, alloc: std.mem.Allocator) !void {
    var s = try Scratch.init(io, alloc, "mkdir");
    defer s.deinit();
    const nested = try s.abs("x/y/z");
    defer alloc.free(nested);
    try fileops.makeDir(io, nested);
    try testz.expectTrue(s.exists("x/y/z"));
    try testz.expectError(fileops.makeDir(io, nested), error.PathAlreadyExists);
}

pub fn isWithinComparesWholeComponentsTest(_: std.Io, _: std.mem.Allocator) !void {
    try testz.expectTrue(fileops.isWithin("/a/b", "/a/b"));
    try testz.expectTrue(fileops.isWithin("/a/b/c", "/a/b"));
    try testz.expectFalse(fileops.isWithin("/a/bc", "/a/b"));
    try testz.expectTrue(fileops.isWithin("/anything", "/"));
}

// ─── Dialogs ────────────────────────────────────────────────────────────

pub fn lineEditHandlesUtf8Test(_: std.Io, alloc: std.mem.Allocator) !void {
    var e = try dialog.LineEdit.init(alloc, "caf");
    defer e.deinit(alloc);
    try e.insert(alloc, "é!");
    try testz.expectEqualStr(e.text(), "café!");
    e.left();
    e.backspace(); // removes the two-byte `é` whole
    try testz.expectEqualStr(e.text(), "caf!");
    e.home();
    e.deleteForward();
    try testz.expectEqualStr(e.text(), "af!");
}

pub fn lineEditHandlesEditingKeysTest(_: std.Io, alloc: std.mem.Allocator) !void {
    // The same field the dialogs use and Alt+D puts on a pane's title
    // row, driven by key name.
    var e = try dialog.LineEdit.init(alloc, "/home/me/code");
    defer e.deinit(alloc);
    try testz.expectTrue(e.handleKey("backspace", false));
    try testz.expectEqualStr(e.text(), "/home/me/cod");
    try testz.expectTrue(e.handleKey("home", false));
    try testz.expectTrue(e.handleKey("delete", false));
    try testz.expectEqualStr(e.text(), "home/me/cod");
    try testz.expectTrue(e.handleKey("u", true));
    try testz.expectEqualStr(e.text(), "");
    // Not the field's: the caller decides what they mean.
    try testz.expectFalse(e.handleKey("enter", false));
    try testz.expectFalse(e.handleKey("d", true));
    try testz.expectFalse(e.handleKey("u", false));
}

pub fn clickColumnFindsTheCaretOffsetTest(_: std.Io, _: std.mem.Allocator) !void {
    // Where a click in the open path field puts the caret.
    const path = "/home/me";
    try testz.expectEqual(sala.ui.offsetAtCol(path, 0, 0), 0);
    try testz.expectEqual(sala.ui.offsetAtCol(path, 0, 5), 5);
    // Past the end clamps there rather than running off it.
    try testz.expectEqual(sala.ui.offsetAtCol(path, 0, 99), path.len);
    // A field scrolled to show the tail counts from where it's drawn.
    try testz.expectEqual(sala.ui.offsetAtCol(path, 6, 2), 8);

    // Wide characters cost the cells they take, and a click on the back
    // half of one lands before it, not inside.
    const wide = "a日本b";
    try testz.expectEqual(sala.ui.offsetAtCol(wide, 0, 1), 1);
    try testz.expectEqual(sala.ui.offsetAtCol(wide, 0, 2), 1);
    try testz.expectEqual(sala.ui.offsetAtCol(wide, 0, 3), 4);
    try testz.expectEqual(sala.ui.offsetAtCol(wide, 0, 5), 7);
}

pub fn dialogHotkeysOnlyWithoutATextFieldTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var conflict = try dialog.Dialog.init(alloc, "t", "m", &dialog.conflict_buttons, .{});
    defer conflict.deinit(alloc);
    try testz.expectEqual(conflict.handleKey("s", false, false).?, dialog.Button.skip);
    try testz.expectEqual(conflict.handleKey("a", false, false).?, dialog.Button.overwrite_all);

    var input = try dialog.Dialog.init(alloc, "t", "m", &dialog.ok_cancel, .{ .input = "/tmp" });
    defer input.deinit(alloc);
    // `o` would be OK's hotkey; in a text field it's just typing.
    try testz.expectTrue(input.handleKey("o", false, false) == null);
    try input.handleText(alloc, "/x");
    try testz.expectEqualStr(input.inputText(), "/tmp/x");
    try testz.expectEqual(input.handleKey("enter", false, false).?, dialog.Button.ok);
}

pub fn dialogEscapeAndFocusTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var d = try dialog.Dialog.init(alloc, "Delete", "sure?", &dialog.yes_no, .{ .focus = 1 });
    defer d.deinit(alloc);
    // Delete starts on No, so Enter alone is safe.
    try testz.expectEqual(d.handleKey("enter", false, false).?, dialog.Button.no);
    try testz.expectTrue(d.handleKey("tab", false, false) == null);
    try testz.expectEqual(d.handleKey("enter", false, false).?, dialog.Button.yes);
    try testz.expectEqual(d.handleKey("escape", false, false).?, dialog.Button.no);
}

// ─── Actions and config ─────────────────────────────────────────────────

pub fn defaultBindingsCoverTheBasicsTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var km = try actions.Keymap.initDefaults(alloc, &actions.defaults);
    defer km.deinit(alloc);
    try testz.expectEqual(km.lookup("up", .{ .alt = true }).?, actions.Action.upToParentDir);
    try testz.expectEqual(km.lookup("F5", .{}).?, actions.Action.copy);
    try testz.expectEqual(km.lookup("F6", .{}).?, actions.Action.move);
    try testz.expectEqual(km.lookup("F8", .{}).?, actions.Action.delete);
    try testz.expectEqual(km.lookup("space", .{}).?, actions.Action.toggleMark);
    try testz.expectEqual(km.lookup("insert", .{}).?, actions.Action.toggleMarkAndDown);
    try testz.expectEqual(km.lookup("d", .{ .alt = true }).?, actions.Action.editPath);
    // Every function-key-bar action has a key to show.
    for (actions.bar_actions) |a| try testz.expectTrue(km.chordFor(a) != null);
}

pub fn configReadsSettingsAndKeysTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var r = config.load(alloc,
        \\config = {
        \\  view = "large",
        \\  show_hidden = true,
        \\  keys = {
        \\    ["ctrl+up"] = "upToParentDir",
        \\    ["F10"] = false,
        \\    ["F2"] = "noSuchAction",
        \\  },
        \\}
    );
    defer r.deinit(alloc);
    try testz.expectTrue(r.err == null);
    try testz.expectEqual(r.config.view, sala.pane.ViewMode.large);
    try testz.expectTrue(r.config.show_hidden);
    try testz.expectEqual(r.config.keys.len, 3);

    var km = try actions.Keymap.initDefaults(alloc, &actions.defaults);
    defer km.deinit(alloc);
    try testz.expectEqual(config.applyKeys(alloc, &km, r.config.keys), 1);
    try testz.expectEqual(km.lookup("up", .{ .ctrl = true }).?, actions.Action.upToParentDir);
    // The default Alt+Up binding is still there alongside it.
    try testz.expectEqual(km.lookup("up", .{ .alt = true }).?, actions.Action.upToParentDir);
    try testz.expectTrue(km.lookup("F10", .{}) == null);
    try testz.expectTrue(km.lookup("F2", .{}) == null);
}

pub fn configSyntaxErrorKeepsDefaultsTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var r = config.load(alloc, "config = { view = ");
    defer r.deinit(alloc);
    try testz.expectTrue(r.err != null);
    try testz.expectEqual(r.config.view, sala.pane.ViewMode.small);
}

pub fn paneTotalBytesCountsListedFilesOnlyTest(io: std.Io, alloc: std.mem.Allocator) !void {
    var s = try Scratch.init(io, alloc, "total");
    defer s.deinit();
    try s.file("a", "12345");
    try s.file("b", "123");
    try s.mkdir("sub");
    try s.file(".hidden", "1234567890");

    var p = try Pane.init(alloc, io, s.path, .{});
    defer p.deinit();
    // The directory's own inode size is left out, and a hidden file only
    // counts once it's listed.
    try testz.expectEqual(p.totalBytes(), 8);
    try p.setShowHidden(true);
    try testz.expectEqual(p.totalBytes(), 18);
}

// ─── Open actions ───────────────────────────────────────────────────────

pub fn openActionResolvesByExtensionTest(_: std.Io, _: std.mem.Allocator) !void {
    const none: []const openaction.Action = &.{};
    try testz.expectEqualStr(openaction.resolve(none, "/tmp/notes.md").?, "gwmd {sel}");
    // The key is case-folded, so a shouty extension still matches.
    try testz.expectEqualStr(openaction.resolve(none, "/tmp/Book.CBZ").?, "gw-read {sel}");
    try testz.expectEqualStr(openaction.resolve(none, "/tmp/shot.jpeg").?, "gw-view {sel}");
    // Nothing claims these: the caller falls back to xdg-open.
    try testz.expectTrue(openaction.resolve(none, "/tmp/notes.txt") == null);
    try testz.expectTrue(openaction.resolve(none, "/tmp/README") == null);
    try testz.expectTrue(openaction.resolve(none, "/tmp/.bashrc") == null);
    // A dot in a parent directory isn't the file's extension.
    try testz.expectTrue(openaction.resolve(none, "/tmp/v1.2/README") == null);
}

pub fn openActionUserEntriesBeatDefaultsTest(_: std.Io, _: std.mem.Allocator) !void {
    const user = [_]openaction.Action{
        .{ .ext = "md", .command = "zoe {sel}" },
        .{ .ext = "png", .command = null },
        .{ .ext = "md", .command = "gwmd -x {sel}" },
    };
    // The last entry for a key wins, as `resolve` scans last-match.
    try testz.expectEqualStr(openaction.resolve(&user, "/tmp/notes.md").?, "gwmd -x {sel}");
    // `false` shadows the built-in and lands back on the desktop opener.
    try testz.expectTrue(openaction.resolve(&user, "/tmp/shot.png") == null);
    // An extension the table doesn't mention keeps its default.
    try testz.expectEqualStr(openaction.resolve(&user, "/tmp/shot.jpg").?, "gw-view {sel}");
}

pub fn openActionBuildsArgvTest(_: std.Io, _: std.mem.Allocator) !void {
    var buf: [openaction.max_args][]const u8 = undefined;
    const argv = try openaction.buildArgv(&buf, "gw-read {sel}", "/tmp/a b.cbz");
    try testz.expectEqual(argv.len, 2);
    try testz.expectEqualStr(argv[0], "gw-read");
    // The path is one argument, spaces and all: there is no shell to
    // word-split it again.
    try testz.expectEqualStr(argv[1], "/tmp/a b.cbz");

    // A template that never says {sel} gets the path appended.
    const appended = try openaction.buildArgv(&buf, "zathura --mode fullscreen", "/tmp/x.pdf");
    try testz.expectEqual(appended.len, 4);
    try testz.expectEqualStr(appended[3], "/tmp/x.pdf");

    // {sel} can sit anywhere; the rest of the words keep their order.
    const middle = try openaction.buildArgv(&buf, "gw-view {sel} --loop", "/tmp/x.png");
    try testz.expectEqual(middle.len, 3);
    try testz.expectEqualStr(middle[1], "/tmp/x.png");
    try testz.expectEqualStr(middle[2], "--loop");

    try testz.expectError(openaction.buildArgv(&buf, "   ", "/tmp/x.png"), error.EmptyCommand);
}

pub fn configReadsOpenActionsTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var r = config.load(alloc,
        \\config = {
        \\  open_actions = {
        \\    md = "zoe {sel}",
        \\    [".CBZ"] = "gw-read {sel}",
        \\    ["*.pdf"] = "zathura",
        \\    png = false,
        \\    ["a/b"] = "nope",
        \\    [""] = "nope",
        \\  },
        \\}
    );
    defer r.deinit(alloc);
    try testz.expectTrue(r.err == null);
    // The two unusable keys are dropped; the rest normalize to bare
    // lowercase extensions.
    try testz.expectEqual(r.config.open_actions.len, 4);

    const user = try r.config.openActions(alloc);
    defer alloc.free(user);
    try testz.expectEqualStr(openaction.resolve(user, "/tmp/x.md").?, "zoe {sel}");
    try testz.expectEqualStr(openaction.resolve(user, "/tmp/x.cbz").?, "gw-read {sel}");
    try testz.expectEqualStr(openaction.resolve(user, "/tmp/x.pdf").?, "zathura");
    try testz.expectTrue(openaction.resolve(user, "/tmp/x.png") == null);
    // An extension the table doesn't touch keeps its default.
    try testz.expectEqualStr(openaction.resolve(user, "/tmp/x.jpg").?, "gw-view {sel}");
}
