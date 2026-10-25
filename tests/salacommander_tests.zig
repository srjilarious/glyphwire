// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: GPL-3.0-or-later

const std = @import("std");
const testz = @import("testz");
const glyphwire = @import("glyphwire");

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
    try testz.expectEqual(p.list.selected, 0);

    try testz.expectTrue(try p.upToParentDir());
    try testz.expectEqualStr(p.path, s.path);
    try testz.expectEqualStr(rowName(&p, p.list.selected), "beta");
}

pub fn paneEnterOnParentRowGoesUpTest(io: std.Io, alloc: std.mem.Allocator) !void {
    var s = try Scratch.init(io, alloc, "enterparent");
    defer s.deinit();
    try s.mkdir("sub");
    const sub = try s.abs("sub");
    defer alloc.free(sub);

    var p = try Pane.init(alloc, io, sub, .{});
    defer p.deinit();
    try testz.expectTrue(p.isParentRow(p.list.selected));
    try testz.expectTrue((try p.enter()) == .changed_dir);
    try testz.expectEqualStr(p.path, s.path);
    try testz.expectEqualStr(rowName(&p, p.list.selected), "sub");
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
    try testz.expectEqualStr(rowName(&p, p.list.selected), "d");
    try testz.expectTrue(p.isMarked(p.rowOf("b").?));
    try testz.expectFalse(p.isMarked(p.rowOf("a").?));
    try testz.expectEqual(p.markedCount(), 1);
}

pub fn paneSortBySizeKeepsDirectoriesFirstTest(io: std.Io, alloc: std.mem.Allocator) !void {
    var s = try Scratch.init(io, alloc, "sortsize");
    defer s.deinit();
    try s.mkdir("adir");
    try s.file("big", "1234567890");
    try s.file("mid", "12345");
    try s.file("small", "1");

    var p = try Pane.init(alloc, io, s.path, .{});
    defer p.deinit();
    p.setSort(.{ .key = .size, .dir = .ascending });
    // The `..` row, then the directory -- a sort orders within the two
    // groups, it never lifts a file above a directory.
    try testz.expectEqualStr(rowName(&p, 0), "..");
    try testz.expectEqualStr(rowName(&p, 1), "adir");
    try testz.expectEqualStr(rowName(&p, 2), "small");
    try testz.expectEqualStr(rowName(&p, 3), "mid");
    try testz.expectEqualStr(rowName(&p, 4), "big");

    p.setSort(p.sort.cycled(.size)); // same column: flip
    try testz.expectEqualStr(rowName(&p, 1), "adir");
    try testz.expectEqualStr(rowName(&p, 2), "big");
    try testz.expectEqualStr(rowName(&p, 4), "small");

    p.setSort(p.sort.cycled(.name)); // a different column starts ascending
    try testz.expectEqualStr(rowName(&p, 2), "big");
    try testz.expectEqualStr(rowName(&p, 3), "mid");
    try testz.expectEqualStr(rowName(&p, 4), "small");
}

pub fn paneSortKeepsCursorAndMarksOnTheirEntriesTest(io: std.Io, alloc: std.mem.Allocator) !void {
    var s = try Scratch.init(io, alloc, "sortmarks");
    defer s.deinit();
    try s.file("a", "1234567890");
    try s.file("b", "1");
    try s.file("c", "12345");

    var p = try Pane.init(alloc, io, s.path, .{});
    defer p.deinit();
    p.setCursor(p.rowOf("a").?);
    p.toggleMark(p.rowOf("c").?);

    p.setSort(.{ .key = .size, .dir = .ascending });
    try testz.expectEqualStr(rowName(&p, 1), "b");
    // Both followed their entry rather than staying on a row index.
    try testz.expectEqualStr(rowName(&p, p.list.selected), "a");
    try testz.expectTrue(p.isMarked(p.rowOf("c").?));
    try testz.expectEqual(p.markedCount(), 1);
}

pub fn paneSortByExtGroupsBySuffixTest(io: std.Io, alloc: std.mem.Allocator) !void {
    var s = try Scratch.init(io, alloc, "sortext");
    defer s.deinit();
    try s.file("b.txt", "");
    try s.file("a.zig", "");
    try s.file("c.txt", "");
    try s.file("plain", "");

    var p = try Pane.init(alloc, io, s.path, .{});
    defer p.deinit();
    p.setSort(.{ .key = .ext, .dir = .ascending });
    // No extension sorts before every extension, then `.txt` (by name
    // within the group), then `.zig`.
    try testz.expectEqualStr(rowName(&p, 1), "plain");
    try testz.expectEqualStr(rowName(&p, 2), "b.txt");
    try testz.expectEqualStr(rowName(&p, 3), "c.txt");
    try testz.expectEqualStr(rowName(&p, 4), "a.zig");
}

pub fn paneSortSurvivesAReloadTest(io: std.Io, alloc: std.mem.Allocator) !void {
    var s = try Scratch.init(io, alloc, "sortreload");
    defer s.deinit();
    try s.file("a", "1234567890");
    try s.file("b", "1");

    var p = try Pane.init(alloc, io, s.path, .{});
    defer p.deinit();
    p.setSort(.{ .key = .size, .dir = .descending });
    try testz.expectEqualStr(rowName(&p, 1), "a");

    try s.file("c", "12345");
    try p.reload();
    try testz.expectEqualStr(rowName(&p, 1), "a");
    try testz.expectEqualStr(rowName(&p, 2), "c");
    try testz.expectEqualStr(rowName(&p, 3), "b");
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
    try testz.expectEqual(p.list.top, 8);
    p.cursorEnd();
    p.scrollIntoView(5);
    try testz.expectEqual(p.list.top, 16);

    // A wheel scroll to the top drags the cursor back on screen.
    p.scrollTo(0, 5);
    try testz.expectEqual(p.list.top, 0);
    try testz.expectEqual(p.list.selected, 4);
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

// ─── Trash ──────────────────────────────────────────────────────────────

const trash = @import("applib").trash;

fn trashOptions(home_trash: ?[]const u8) trash.Options {
    return .{ .home_trash = home_trash, .deletion_date = "2026-10-11T09:30:00", .uid = trash.currentUid() };
}

pub fn trashMovesIntoHomeTrashWithInfoTest(io: std.Io, alloc: std.mem.Allocator) !void {
    var s = try Scratch.init(io, alloc, "trashhome");
    defer s.deinit();
    try s.mkdir("work/sub");
    try s.file("work/sub/a b%.txt", "alpha");
    const home_trash = try s.abs("Trash");
    defer alloc.free(home_trash);
    const victim = try s.abs("work/sub/a b%.txt");
    defer alloc.free(victim);

    // The trash doesn't exist yet: it's made on demand, files/ and info/.
    try trash.moveToTrash(io, alloc, victim, trashOptions(home_trash));
    try testz.expectFalse(s.exists("work/sub/a b%.txt"));
    const got = try s.read("Trash/files/a b%.txt");
    defer alloc.free(got);
    try testz.expectEqualStr(got, "alpha");

    // The home trash records the absolute path, URL-escaped.
    const info = try s.read("Trash/info/a b%.txt.trashinfo");
    defer alloc.free(info);
    const escaped = try trash.escapePath(alloc, victim);
    defer alloc.free(escaped);
    const want = try std.fmt.allocPrint(alloc, "[Trash Info]\nPath={s}\nDeletionDate=2026-10-11T09:30:00\n", .{escaped});
    defer alloc.free(want);
    try testz.expectEqualStr(info, want);
    try testz.expectTrue(std.mem.indexOf(u8, info, "a%20b%25.txt") != null);
}

pub fn trashSameNameTwiceGetsNumberedTest(io: std.Io, alloc: std.mem.Allocator) !void {
    var s = try Scratch.init(io, alloc, "trashtwice");
    defer s.deinit();
    try s.mkdir("one");
    try s.mkdir("two");
    try s.file("one/notes.md", "first");
    try s.file("two/notes.md", "second");
    try s.mkdir("tree/deep");
    const home_trash = try s.abs("Trash");
    defer alloc.free(home_trash);
    const first = try s.abs("one/notes.md");
    defer alloc.free(first);
    const second = try s.abs("two/notes.md");
    defer alloc.free(second);
    const tree = try s.abs("tree");
    defer alloc.free(tree);

    const r = (fileops.Operation{ .kind = .trash, .sources = &.{ first, second, tree }, .trash = trashOptions(home_trash) }).run(io, alloc, fileops.quiet_hooks);
    try testz.expectEqual(r.done, 3);
    try testz.expectEqual(r.failed, 0);
    const a = try s.read("Trash/files/notes.md");
    defer alloc.free(a);
    try testz.expectEqualStr(a, "first");
    // The second keeps its extension behind the number.
    const b = try s.read("Trash/files/notes.2.md");
    defer alloc.free(b);
    try testz.expectEqualStr(b, "second");
    try testz.expectTrue(s.exists("Trash/info/notes.2.md.trashinfo"));
    // A directory goes in whole.
    try testz.expectTrue(s.exists("Trash/files/tree/deep"));
}

/// Hooks that answer "can't trash" with `answer` and count the calls.
const NoTrashScript = struct {
    answer: fileops.NoTrash,
    asked: usize = 0,
    last_err: ?anyerror = null,

    fn hooks(self: *NoTrashScript) fileops.Hooks {
        var h = fileops.quiet_hooks;
        h.ctx = self;
        h.onNoTrash = onNoTrash;
        return h;
    }
    fn onNoTrash(ctx: *anyopaque, _: []const u8, err: anyerror) fileops.NoTrash {
        const self: *NoTrashScript = @ptrCast(@alignCast(ctx));
        self.asked += 1;
        self.last_err = err;
        return self.answer;
    }
};

pub fn trashInsideTrashOffersDeleteTest(io: std.Io, alloc: std.mem.Allocator) !void {
    var s = try Scratch.init(io, alloc, "trashintrash");
    defer s.deinit();
    try s.mkdir("Trash/files");
    try s.mkdir("Trash/info");
    try s.file("Trash/files/old.txt", "");
    try s.file("Trash/files/older.txt", "");
    const home_trash = try s.abs("Trash");
    defer alloc.free(home_trash);
    const old = try s.abs("Trash/files/old.txt");
    defer alloc.free(old);
    const older = try s.abs("Trash/files/older.txt");
    defer alloc.free(older);

    // Skip leaves it be.
    var skip: NoTrashScript = .{ .answer = .skip };
    const r1 = (fileops.Operation{ .kind = .trash, .sources = &.{old}, .trash = trashOptions(home_trash) }).run(io, alloc, skip.hooks());
    try testz.expectEqual(skip.asked, 1);
    try testz.expectTrue(skip.last_err.? == error.InTrash);
    try testz.expectEqual(r1.skipped, 1);
    try testz.expectTrue(s.exists("Trash/files/old.txt"));

    // "All" deletes this one and the next without asking again.
    var all: NoTrashScript = .{ .answer = .delete_all };
    const r2 = (fileops.Operation{ .kind = .trash, .sources = &.{ old, older }, .trash = trashOptions(home_trash) }).run(io, alloc, all.hooks());
    try testz.expectEqual(all.asked, 1);
    try testz.expectEqual(r2.done, 2);
    try testz.expectFalse(s.exists("Trash/files/old.txt"));
    try testz.expectFalse(s.exists("Trash/files/older.txt"));
}

pub fn trashTopdirPrefersStickySharedTrashTest(io: std.Io, alloc: std.mem.Allocator) !void {
    var s = try Scratch.init(io, alloc, "trashtop");
    defer s.deinit();
    const uid = trash.currentUid();

    // No `.Trash`: `.Trash-$uid`, made with files/ and info/.
    const own = try trash.topdirTrash(io, alloc, s.path, uid);
    defer alloc.free(own);
    const own_want = try std.fmt.allocPrint(alloc, "{s}/.Trash-{d}", .{ s.path, uid });
    defer alloc.free(own_want);
    try testz.expectEqualStr(own, own_want);
    const own_files = try std.fmt.allocPrint(alloc, ".Trash-{d}/files", .{uid});
    defer alloc.free(own_files);
    try testz.expectTrue(s.exists(own_files));

    // A `.Trash` without the sticky bit is passed over...
    try s.mkdir(".Trash");
    const still_own = try trash.topdirTrash(io, alloc, s.path, uid);
    defer alloc.free(still_own);
    try testz.expectEqualStr(still_own, own_want);

    // ...and with it, `$uid` inside it is used.
    const shared = try s.abs(".Trash");
    defer alloc.free(shared);
    try std.Io.Dir.cwd().setFilePermissions(io, shared, .fromMode(0o1777), .{});
    const in_shared = try trash.topdirTrash(io, alloc, s.path, uid);
    defer alloc.free(in_shared);
    const shared_want = try std.fmt.allocPrint(alloc, "{s}/.Trash/{d}", .{ s.path, uid });
    defer alloc.free(shared_want);
    try testz.expectEqualStr(in_shared, shared_want);
}

pub fn trashTextHelpersTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var buf: [64]u8 = undefined;
    // 2026-10-11 12:34:56 UTC, shown two hours east.
    try testz.expectEqualStr(trash.formatDeletionDate(&buf, 1_791_722_096, 2 * 3600), "2026-10-11T14:34:56");
    try testz.expectEqualStr(trash.candidateName(&buf, "a.tar.gz", 1).?, "a.tar.gz");
    try testz.expectEqualStr(trash.candidateName(&buf, "a.tar.gz", 3).?, "a.tar.3.gz");
    try testz.expectEqualStr(trash.candidateName(&buf, "Makefile", 2).?, "Makefile.2");
    const e = try trash.escapePath(alloc, "/home/me/ä b/(x)~");
    defer alloc.free(e);
    try testz.expectEqualStr(e, "/home/me/%C3%A4%20b/(x)~");

    const p1 = (try trash.homeTrashPath(alloc, "/x/data", "/home/me")).?;
    defer alloc.free(p1);
    try testz.expectEqualStr(p1, "/x/data/Trash");
    const p2 = (try trash.homeTrashPath(alloc, "", "/home/me")).?;
    defer alloc.free(p2);
    try testz.expectEqualStr(p2, "/home/me/.local/share/Trash");
    try testz.expectTrue((try trash.homeTrashPath(alloc, null, null)) == null);
}

// ─── Directory history ──────────────────────────────────────────────────

pub fn paneBackForwardRestoresCursorTest(io: std.Io, alloc: std.mem.Allocator) !void {
    var s = try Scratch.init(io, alloc, "histback");
    defer s.deinit();
    try s.mkdir("a/inner");
    try s.mkdir("b");
    try s.file("a/x.txt", "");
    try s.file("a/y.txt", "");

    var p = try Pane.init(alloc, io, s.path, .{});
    defer p.deinit();
    try testz.expectFalse(try p.back());

    const a = try s.abs("a");
    defer alloc.free(a);
    const b = try s.abs("b");
    defer alloc.free(b);
    try p.load(a);
    p.setCursor(p.rowOf("y.txt").?);
    try p.load(b);

    // Back to `a`, on the entry it was left on.
    try testz.expectTrue(try p.back());
    try testz.expectEqualStr(p.path, a);
    try testz.expectEqualStr(p.current().?.name, "y.txt");
    try testz.expectTrue(try p.back());
    try testz.expectEqualStr(p.path, s.path);
    try testz.expectFalse(try p.back());

    try testz.expectTrue(try p.forward());
    try testz.expectTrue(try p.forward());
    try testz.expectEqualStr(p.path, b);
    try testz.expectFalse(try p.forward());

    // Going somewhere new from the middle drops what was ahead.
    try testz.expectTrue(try p.back());
    const inner = try s.abs("a/inner");
    defer alloc.free(inner);
    try p.load(inner);
    try testz.expectFalse(try p.forward());
    try testz.expectTrue(try p.back());
    try testz.expectEqualStr(p.path, a);
}

/// `visits` moves on every trip the pane takes, back to where it was
/// included, and never on a reread: what Shift+F4's landing checks to
/// leave alone a pane the user has since moved.
pub fn paneVisitsCountTripsNotRereadsTest(io: std.Io, alloc: std.mem.Allocator) !void {
    var s = try Scratch.init(io, alloc, "visits");
    defer s.deinit();
    try s.mkdir("a");

    var p = try Pane.init(alloc, io, s.path, .{});
    defer p.deinit();
    const start = p.visits;
    try p.reload();
    try testz.expectEqual(p.visits, start);

    const a = try s.abs("a");
    defer alloc.free(a);
    try p.load(a);
    try testz.expectEqual(p.visits, start + 1);
    try testz.expectTrue(try p.back());
    try testz.expectEqualStr(p.path, s.path);
    try testz.expectEqual(p.visits, start + 2);
    try testz.expectTrue(try p.forward());
    try testz.expectTrue(try p.upToParentDir());
    try testz.expectEqual(p.visits, start + 4);
}

pub fn paneHistoryRecentIsNewestFirstWithoutRepeatsTest(io: std.Io, alloc: std.mem.Allocator) !void {
    var s = try Scratch.init(io, alloc, "histrecent");
    defer s.deinit();
    try s.mkdir("a");
    try s.mkdir("b");
    const a = try s.abs("a");
    defer alloc.free(a);
    const b = try s.abs("b");
    defer alloc.free(b);

    var p = try Pane.init(alloc, io, s.path, .{});
    defer p.deinit();
    try p.load(a);
    try p.load(b);
    try p.load(a);
    // Loading where it already is changes nothing on the trail.
    try p.load(a);

    const recent = p.history.recent.items;
    try testz.expectEqual(recent.len, 3);
    try testz.expectEqualStr(recent[0], a);
    try testz.expectEqualStr(recent[1], b);
    try testz.expectEqualStr(recent[2], s.path);
    try testz.expectEqual(p.history.trail.items.len, 4);

    // Back counts as a visit for the list, without growing the trail.
    try testz.expectTrue(try p.back());
    try testz.expectEqualStr(p.history.recent.items[0], b);
    try testz.expectEqual(p.history.trail.items.len, 4);
}

pub fn paneBackToVanishedDirStaysPutTest(io: std.Io, alloc: std.mem.Allocator) !void {
    var s = try Scratch.init(io, alloc, "histgone");
    defer s.deinit();
    try s.mkdir("gone");
    try s.mkdir("here");
    const gone = try s.abs("gone");
    defer alloc.free(gone);
    const here = try s.abs("here");
    defer alloc.free(here);

    var p = try Pane.init(alloc, io, gone, .{});
    defer p.deinit();
    try p.load(here);
    try s.dir.deleteTree(io, "gone");
    if (p.back()) |_| return error.BackShouldHaveFailed else |_| {}
    try testz.expectEqualStr(p.path, here);
    try testz.expectEqualStr(p.history.current().?.path, here);
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

pub fn renameInDirRenamesInPlaceTest(io: std.Io, alloc: std.mem.Allocator) !void {
    var s = try Scratch.init(io, alloc, "f2");
    defer s.deinit();
    try s.file("old.txt", "body");
    try fileops.renameInDir(io, alloc, s.path, "old.txt", "new.txt");
    try testz.expectFalse(s.exists("old.txt"));
    const got = try s.read("new.txt");
    defer alloc.free(got);
    try testz.expectEqualStr(got, "body");
}

pub fn renameInDirNeverReplacesTest(io: std.Io, alloc: std.mem.Allocator) !void {
    // F6 onto an existing file asks; F2 just refuses, and both files are
    // left exactly as they were.
    var s = try Scratch.init(io, alloc, "f2-taken");
    defer s.deinit();
    try s.file("a.txt", "a");
    try s.file("b.txt", "b");
    try testz.expectError(fileops.renameInDir(io, alloc, s.path, "a.txt", "b.txt"), error.PathAlreadyExists);
    const got = try s.read("b.txt");
    defer alloc.free(got);
    try testz.expectEqualStr(got, "b");
    try testz.expectTrue(s.exists("a.txt"));
}

pub fn renameInDirTakesANameNotAPathTest(io: std.Io, alloc: std.mem.Allocator) !void {
    var s = try Scratch.init(io, alloc, "f2-name");
    defer s.deinit();
    try s.file("a.txt", "a");
    try s.mkdir("sub");
    try testz.expectError(fileops.renameInDir(io, alloc, s.path, "a.txt", "sub/a.txt"), error.InvalidName);
    try testz.expectError(fileops.renameInDir(io, alloc, s.path, "a.txt", ".."), error.InvalidName);
    try testz.expectError(fileops.renameInDir(io, alloc, s.path, "a.txt", ""), error.EmptyName);
    try testz.expectTrue(s.exists("a.txt"));
    try testz.expectFalse(s.exists("sub/a.txt"));
}

pub fn makeFileCreatesParentsAndNeverTruncatesTest(io: std.Io, alloc: std.mem.Allocator) !void {
    const fsops = @import("applib").fsops;
    var s = try Scratch.init(io, alloc, "mkfile");
    defer s.deinit();
    const nested = try s.abs("a/b/new.zig");
    defer alloc.free(nested);
    try fsops.makeFile(io, nested);
    try testz.expectTrue(s.exists("a/b/new.zig"));

    try s.file("keep.txt", "body");
    const keep = try s.abs("keep.txt");
    defer alloc.free(keep);
    try testz.expectError(fsops.makeFile(io, keep), error.PathAlreadyExists);
    const after = try s.dir.readFileAlloc(io, "keep.txt", alloc, .limited(64));
    defer alloc.free(after);
    try testz.expectEqualStr(after, "body");
}

pub fn numberedNameGoesBeforeTheExtensionTest(_: std.Io, alloc: std.mem.Allocator) !void {
    const fsops = @import("applib").fsops;
    const cases = [_]struct { name: []const u8, is_dir: bool, want: []const u8 }{
        .{ .name = "notes.txt", .is_dir = false, .want = "notes (2).txt" },
        .{ .name = "a.tar.gz", .is_dir = false, .want = "a.tar (2).gz" },
        .{ .name = "src.old", .is_dir = true, .want = "src.old (2)" },
        .{ .name = ".bashrc", .is_dir = false, .want = ".bashrc (2)" },
        .{ .name = "Makefile", .is_dir = false, .want = "Makefile (2)" },
    };
    for (cases) |c| {
        const got = try fsops.numberedName(alloc, c.name, c.is_dir, 2);
        defer alloc.free(got);
        try testz.expectEqualStr(got, c.want);
    }
}

pub fn freeNameSkipsTakenNumbersTest(io: std.Io, alloc: std.mem.Allocator) !void {
    const fsops = @import("applib").fsops;
    var s = try Scratch.init(io, alloc, "freename");
    defer s.deinit();
    try s.file("a.txt", "a");
    try s.file("a (1).txt", "a");
    const got = try fsops.freeName(io, alloc, s.path, "a.txt", false);
    defer alloc.free(got);
    try testz.expectEqualStr(got, "a (2).txt");
}

/// zoe's sidebar `p` runs a single-source copy or move *to* a free
/// name in the same folder: the copy is a sibling, the move a rename.
pub fn copyAndMoveToAFreeSiblingNameTest(io: std.Io, alloc: std.mem.Allocator) !void {
    var s = try Scratch.init(io, alloc, "sibling");
    defer s.deinit();
    try s.mkdir("d");
    try s.file("d/x.txt", "x");
    const src = try s.abs("d");
    defer alloc.free(src);
    const copy = try s.abs("d (1)");
    defer alloc.free(copy);
    const r = (fileops.Operation{ .kind = .copy, .sources = &.{src}, .dest = copy }).run(io, alloc, fileops.quiet_hooks);
    try testz.expectEqual(r.failed, 0);
    try testz.expectTrue(s.exists("d/x.txt"));
    try testz.expectTrue(s.exists("d (1)/x.txt"));

    const moved = try s.abs("e");
    defer alloc.free(moved);
    const m = (fileops.Operation{ .kind = .move, .sources = &.{copy}, .dest = moved }).run(io, alloc, fileops.quiet_hooks);
    try testz.expectEqual(m.failed, 0);
    try testz.expectFalse(s.exists("d (1)"));
    try testz.expectTrue(s.exists("e/x.txt"));
}

pub fn checkNewPathStaysUnderTheDirectoryTest(_: std.Io, _: std.mem.Allocator) !void {
    const fsops = @import("applib").fsops;
    try fsops.checkNewPath("new.zig");
    try fsops.checkNewPath("sub/dir/");
    try fsops.checkNewPath("sub/new.zig");
    try testz.expectError(fsops.checkNewPath("/etc/x"), error.InvalidName);
    try testz.expectError(fsops.checkNewPath("../x"), error.InvalidName);
    try testz.expectError(fsops.checkNewPath("a/./b"), error.InvalidName);
    try testz.expectError(fsops.checkNewPath("a//b"), error.InvalidName);
    try testz.expectError(fsops.checkNewPath("/"), error.EmptyName);
    try testz.expectError(fsops.checkNewPath(""), error.EmptyName);
}

pub fn renameCaretSitsBeforeTheExtensionTest(_: std.Io, _: std.mem.Allocator) !void {
    try testz.expectEqual(sala.ui.renameCaret("photo.jpg", false), 5);
    try testz.expectEqual(sala.ui.renameCaret("notes.tar.gz", false), 9);
    // No extension to keep: the caret goes to the end.
    try testz.expectEqual(sala.ui.renameCaret("Makefile", false), 8);
    try testz.expectEqual(sala.ui.renameCaret(".bashrc", false), 7);
    // A dot in a directory name isn't an extension.
    try testz.expectEqual(sala.ui.renameCaret("src.old", true), 7);
}

pub fn renameFieldKeepsTextKeysTest(_: std.Io, _: std.mem.Allocator) !void {
    // Keys whose text arrives on the `text` stream stay in the F2 field
    // instead of being read as their bindings (Space marks, keypad `+`
    // marks all) -- those would drop the rename mid-word.
    try testz.expectTrue(sala.ui.typesText("a", .{}));
    try testz.expectTrue(sala.ui.typesText("A", .{ .shift = true }));
    try testz.expectTrue(sala.ui.typesText("space", .{}));
    try testz.expectTrue(sala.ui.typesText("kp_add", .{}));
    try testz.expectFalse(sala.ui.typesText("kp_enter", .{}));
    try testz.expectFalse(sala.ui.typesText("tab", .{}));
    try testz.expectFalse(sala.ui.typesText("F5", .{}));
    try testz.expectFalse(sala.ui.typesText("d", .{ .alt = true }));
    try testz.expectFalse(sala.ui.typesText("`", .{ .ctrl = true }));
}

pub fn isWithinComparesWholeComponentsTest(_: std.Io, _: std.mem.Allocator) !void {
    try testz.expectTrue(fileops.isWithin("/a/b", "/a/b"));
    try testz.expectTrue(fileops.isWithin("/a/b/c", "/a/b"));
    try testz.expectFalse(fileops.isWithin("/a/bc", "/a/b"));
    try testz.expectTrue(fileops.isWithin("/anything", "/"));
}

// ─── Dialogs ────────────────────────────────────────────────────────────

pub fn dialogFieldIsTheSharedLineEditTest(_: std.Io, alloc: std.mem.Allocator) !void {
    // `dialog.LineEdit` is glyphwire's shared field (see the `lineedit`
    // group for its own coverage); what is pinned here is that a dialog's
    // field really is that type, with the word jumps the shell prompt has
    // and not the thinner set salacommander used to carry.
    var e = try dialog.LineEdit.init(alloc, "/home/me/code");
    defer e.deinit(alloc);
    _ = try e.insert(alloc, "é!");
    try testz.expectEqualStr(e.text(), "/home/me/codeé!");
    try testz.expectEqual(e.handleKey("backspace", .{}), .edited); // the `!`
    try testz.expectTrue(e.deleteBackward()); // the two-byte `é`, whole
    try testz.expectEqualStr(e.text(), "/home/me/code");

    // Ctrl+Backspace takes one path segment, which the old field had no
    // key for at all.
    try testz.expectEqual(e.handleKey("backspace", .{ .ctrl = true }), .edited);
    try testz.expectEqualStr(e.text(), "/home/me/");
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
    try testz.expectEqual(conflict.handleKey("s", .{}).?, dialog.Button.skip);
    try testz.expectEqual(conflict.handleKey("a", .{}).?, dialog.Button.overwrite_all);

    var input = try dialog.Dialog.init(alloc, "t", "m", &dialog.ok_cancel, .{ .input = "/tmp" });
    defer input.deinit(alloc);
    // `o` would be OK's hotkey; in a text field it's just typing.
    try testz.expectTrue(input.handleKey("o", .{}) == null);
    try input.handleText(alloc, "/x");
    try testz.expectEqualStr(input.inputText(), "/tmp/x");
    try testz.expectEqual(input.handleKey("enter", .{}).?, dialog.Button.ok);
}

pub fn dialogEscapeAndFocusTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var d = try dialog.Dialog.init(alloc, "Delete", "sure?", &dialog.yes_no, .{ .focus = 1 });
    defer d.deinit(alloc);
    // Delete starts on No, so Enter alone is safe.
    try testz.expectEqual(d.handleKey("enter", .{}).?, dialog.Button.no);
    try testz.expectTrue(d.handleKey("tab", .{}) == null);
    try testz.expectEqual(d.handleKey("enter", .{}).?, dialog.Button.yes);
    try testz.expectEqual(d.handleKey("escape", .{}).?, dialog.Button.no);
}

// ─── Repaint cost ───────────────────────────────────────────────────────

pub fn navigationKeysTakeTheCheapRepaintTest(_: std.Io, _: std.mem.Allocator) !void {
    // A full pane repaint is a ~54 KB frame; over a remote session that
    // is what made moving the cursor lag. A navigation key moves nothing
    // but the highlight, so it owes two rows' `set_bg`/`set_fg` and no
    // text at all -- the cheapest level there is, and the lag comes back
    // if one of these slips off it.
    const bg_only = [_]sala.ui.Action{
        .cursorUp, .cursorDown, .pageUp,
        .pageDown, .cursorHome, .cursorEnd,
    };
    for (bg_only) |a| try testz.expectEqual(sala.ui.Ui.dirtyFor(a), .bg);

    // A mark changes its row's foreground and puts a `*` in column 0, so
    // the two toggles still need the rows themselves -- but not the pane.
    const rows = [_]sala.ui.Action{ .toggleMark, .toggleMarkAndDown };
    for (rows) |a| try testz.expectEqual(sala.ui.Ui.dirtyFor(a), .rows);

    // Opening the F3 popup draws over the pane and changes nothing in it.
    try testz.expectEqual(sala.ui.Ui.dirtyFor(.find), .none);
}

pub fn ListingChangesTakeTheFullRepaintTest(_: std.Io, _: std.mem.Allocator) !void {
    // Anything that can reorder, refilter or replace the listing -- or
    // turn the title row into a text field -- has to redraw all of it.
    const full = [_]sala.ui.Action{
        .activate,   .upToParentDir,      .editPath,   .switchPane,
        .swapPanes,  .markAll,            .unmarkAll,  .invertMarks,
        .sortByName, .sortBySize,         .toggleView, .toggleHidden,
        .refresh,    .otherPaneToSameDir, .rename,     .edit,
    };
    for (full) |a| try testz.expectEqual(sala.ui.Ui.dirtyFor(a), .full);
}

// ─── Tabs ───────────────────────────────────────────────────────────────

const tabs = sala.tabs;

/// The strip in order, the shown tab included, for comparing against.
fn tabOrder(set: *tabs.TabSet(u32), shown: *u32, out: []u32) []u32 {
    for (0..set.count()) |k| out[k] = set.at(shown, k).*;
    return out[0..set.count()];
}

pub fn tabsOpenAfterTheShownOneTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var set: tabs.TabSet(u32) = .{};
    defer set.deinit(alloc);
    var shown: u32 = 1;
    try testz.expectEqual(set.count(), 1);

    try set.open(alloc, &shown, 2);
    try testz.expectEqual(shown, 2);
    try testz.expectEqual(set.active, 1);
    // From the first tab, a new one goes between it and the rest.
    try testz.expectTrue(set.switchTo(&shown, 0));
    try set.open(alloc, &shown, 3);
    var buf: [8]u32 = undefined;
    try std.testing.expectEqualSlices(u32, &.{ 1, 3, 2 }, tabOrder(&set, &shown, &buf));
    try testz.expectEqual(set.active, 1);
}

pub fn tabsSwitchKeepsTheStripOrderTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var set: tabs.TabSet(u32) = .{};
    defer set.deinit(alloc);
    var shown: u32 = 0;
    for (1..5) |n| try set.open(alloc, &shown, @intCast(n));
    var buf: [8]u32 = undefined;
    try std.testing.expectEqualSlices(u32, &.{ 0, 1, 2, 3, 4 }, tabOrder(&set, &shown, &buf));

    // Every jump, left and right, leaves the order alone and shows `k`.
    for ([_]usize{ 0, 3, 1, 4, 2, 0, 4 }) |k| {
        try testz.expectTrue(set.switchTo(&shown, k));
        try testz.expectEqual(shown, @as(u32, @intCast(k)));
        try testz.expectEqual(set.active, k);
        try std.testing.expectEqualSlices(u32, &.{ 0, 1, 2, 3, 4 }, tabOrder(&set, &shown, &buf));
    }
    try testz.expectFalse(set.switchTo(&shown, 4));
    try testz.expectFalse(set.switchTo(&shown, 5));
}

pub fn tabsStepWrapsTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var set: tabs.TabSet(u32) = .{};
    defer set.deinit(alloc);
    var shown: u32 = 0;
    try testz.expectFalse(set.step(&shown, true));
    try set.open(alloc, &shown, 1);
    try set.open(alloc, &shown, 2);
    try testz.expectTrue(set.step(&shown, true));
    try testz.expectEqual(shown, 0);
    try testz.expectTrue(set.step(&shown, false));
    try testz.expectEqual(shown, 2);
    try testz.expectTrue(set.step(&shown, false));
    try testz.expectEqual(shown, 1);
}

pub fn tabsCloseShowsTheRightNeighbourTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var set: tabs.TabSet(u32) = .{};
    defer set.deinit(alloc);
    var shown: u32 = 0;
    for (1..4) |n| try set.open(alloc, &shown, @intCast(n));
    _ = set.switchTo(&shown, 1);
    var buf: [8]u32 = undefined;

    // The shown one: its right neighbour slides in.
    try testz.expectEqual(set.close(&shown, 1).?, 1);
    try testz.expectEqual(shown, 2);
    try std.testing.expectEqualSlices(u32, &.{ 0, 2, 3 }, tabOrder(&set, &shown, &buf));
    // One to its left: the shown tab stays, one slot further left.
    try testz.expectEqual(set.close(&shown, 0).?, 0);
    try testz.expectEqual(shown, 2);
    try testz.expectEqual(set.active, 0);
    // The last one while shown: its left neighbour.
    _ = set.switchTo(&shown, 1);
    try testz.expectEqual(set.close(&shown, 1).?, 3);
    try testz.expectEqual(shown, 2);
    try testz.expectEqual(set.active, 0);
    // A side's only tab never closes.
    try testz.expectEqual(set.close(&shown, 0), null);
    try testz.expectEqual(set.count(), 1);
}

pub fn tabStripLayoutAndHitsTest(_: std.Io, _: std.mem.Allocator) !void {
    try testz.expectEqualStr(tabs.labelFor("/home/me/src"), "src");
    try testz.expectEqualStr(tabs.labelFor("/"), "/");

    var spans: [3]tabs.Span = undefined;
    // ` src │ / │ docs `
    const total = tabs.layout(&.{ "src", "/", "docs" }, &spans);
    try testz.expectEqual(total, 5 + 1 + 3 + 1 + 6);
    try testz.expectEqual(spans[1].start, 6);
    try testz.expectEqual(tabs.hit(&spans, 0), 0);
    try testz.expectEqual(tabs.hit(&spans, 5), null); // the separator
    try testz.expectEqual(tabs.hit(&spans, 7), 1);
    try testz.expectEqual(tabs.hit(&spans, total), null);
}

/// Panes move in and out of a set by value, each keeping its own
/// directory, cursor and history; nothing leaks or is freed twice.
pub fn tabsHoldWholePanesTest(io: std.Io, alloc: std.mem.Allocator) !void {
    var s = try Scratch.init(io, alloc, "tabs");
    defer s.deinit();
    try s.mkdir("one");
    try s.mkdir("two");
    try s.file("one/a", "");
    try s.file("one/b", "");

    const one = try s.abs("one");
    defer alloc.free(one);
    const two = try s.abs("two");
    defer alloc.free(two);

    var shown = try Pane.init(alloc, io, one, .{});
    var set: tabs.TabSet(Pane) = .{};
    defer {
        shown.deinit();
        for (set.others.items) |*p| p.deinit();
        set.deinit(alloc);
    }
    shown.setCursor(2);

    try set.open(alloc, &shown, try Pane.init(alloc, io, one, .{}));
    try shown.load(two);
    try testz.expectEqualStr(shown.path, two);

    try testz.expectTrue(set.step(&shown, false));
    try testz.expectEqualStr(shown.path, one);
    try testz.expectEqual(shown.list.selected, 2);
    try testz.expectEqualStr(set.at(&shown, 1).path, two);
    // The hidden tab's own history went one -> two.
    try testz.expectTrue(set.at(&shown, 1).history.backTarget() != null);

    var gone = set.close(&shown, 0).?;
    gone.deinit();
    try testz.expectEqualStr(shown.path, two);
}

// ─── Actions and config ─────────────────────────────────────────────────

pub fn tabChordsAreTotalCommandersTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var km = try actions.Keymap.initDefaults(alloc, &actions.defaults);
    defer km.deinit(alloc);
    try testz.expectEqual(km.lookup("t", .{ .ctrl = true }).?, actions.Action.newTab);
    try testz.expectEqual(km.lookup("w", .{ .ctrl = true }).?, actions.Action.closeTab);
    try testz.expectEqual(km.lookup("tab", .{ .ctrl = true }).?, actions.Action.nextTab);
    try testz.expectEqual(km.lookup("tab", .{ .ctrl = true, .shift = true }).?, actions.Action.prevTab);
    // Plain Tab still crosses to the other pane.
    try testz.expectEqual(km.lookup("tab", .{}).?, actions.Action.switchPane);
}

pub fn defaultBindingsCoverTheBasicsTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var km = try actions.Keymap.initDefaults(alloc, &actions.defaults);
    defer km.deinit(alloc);
    try testz.expectEqual(km.lookup("up", .{ .alt = true }).?, actions.Action.upToParentDir);
    try testz.expectEqual(km.lookup("F2", .{}).?, actions.Action.rename);
    try testz.expectEqual(km.lookup("F3", .{}).?, actions.Action.find);
    try testz.expectEqual(km.lookup("F4", .{}).?, actions.Action.edit);
    try testz.expectEqual(km.lookup("F5", .{}).?, actions.Action.copy);
    try testz.expectEqual(km.lookup("F6", .{}).?, actions.Action.move);
    // F8 and Delete trash; Shift is gone for good, Super gone as root.
    try testz.expectEqual(km.lookup("F8", .{}).?, actions.Action.trash);
    try testz.expectEqual(km.lookup("delete", .{}).?, actions.Action.trash);
    try testz.expectEqual(km.lookup("F8", .{ .shift = true }).?, actions.Action.delete);
    try testz.expectEqual(km.lookup("delete", .{ .shift = true }).?, actions.Action.delete);
    try testz.expectEqual(km.lookup("F8", .{ .super = true }).?, actions.Action.sudoDelete);
    try testz.expectEqual(km.lookup("left", .{ .alt = true }).?, actions.Action.historyBack);
    try testz.expectEqual(km.lookup("right", .{ .alt = true }).?, actions.Action.historyForward);
    try testz.expectEqual(km.lookup("down", .{ .alt = true }).?, actions.Action.showHistory);
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
        \\    ["F11"] = "noSuchAction",
        \\  },
        \\}
    );
    defer r.deinit(alloc);
    try testz.expectTrue(r.err == null);
    try testz.expectEqual(r.config.view, sala.pane.ViewMode.large);
    try testz.expectTrue(r.config.show_hidden);
    // The unknown action is dropped (with a warning) as the file is read.
    try testz.expectEqual(r.config.keys.len, 2);

    var km = try actions.Keymap.initDefaults(alloc, &actions.defaults);
    defer km.deinit(alloc);
    try km.apply(alloc, r.config.keys);
    try testz.expectEqual(km.lookup("up", .{ .ctrl = true }).?, actions.Action.upToParentDir);
    // The default Alt+Up binding is still there alongside it.
    try testz.expectEqual(km.lookup("up", .{ .alt = true }).?, actions.Action.upToParentDir);
    try testz.expectTrue(km.lookup("F10", .{}) == null);
    try testz.expectTrue(km.lookup("F11", .{}) == null);
}

/// `theme` comes out of the one Lua run that reads the rest of the
/// config (review C5): no second VM runs the file for it. A config with
/// `themes` but no `theme` follows the window, so keeps nothing.
pub fn configReadsThemeInSameRunTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var r = config.load(alloc,
        \\config = {
        \\  theme = "mine",
        \\  themes = { mine = { base = "nord", keyword = "#010203" } },
        \\}
    );
    defer r.deinit(alloc);
    const t = r.config.theme orelse return error.TestExpectedTheme;
    try testz.expectEqualStr(t.parsed.name.?, "mine");
    try testz.expectEqual(t.parsed.customs.len, 1);

    var none = config.load(alloc, "config = { themes = { mine = { base = \"nord\" } } }");
    defer none.deinit(alloc);
    try testz.expectTrue(none.config.theme == null);
}

/// `page_lines` is how far PageUp/PageDown move, defaulting to 6. A
/// number >= 1 replaces it; 0 is nothing, not "a screenful", so it is
/// clamped up to 1 -- the rule zoe's `page_lines` follows too. A value
/// that isn't a whole number keeps the default.
pub fn configReadsPageLinesTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var def = config.load(alloc, "config = {}");
    defer def.deinit(alloc);
    try testz.expectEqual(def.config.page_lines, 6);

    var set = config.load(alloc, "config = { page_lines = 20 }");
    defer set.deinit(alloc);
    try testz.expectEqual(set.config.page_lines, 20);

    var zero = config.load(alloc, "config = { page_lines = 0 }");
    defer zero.deinit(alloc);
    try testz.expectEqual(zero.config.page_lines, 1);

    for ([_][:0]const u8{
        "config = { page_lines = -3 }",
        "config = { page_lines = 1.5 }",
        "config = { page_lines = \"lots\" }",
    }) |src| {
        var bad = config.load(alloc, src);
        defer bad.deinit(alloc);
        try testz.expectEqual(bad.config.page_lines, 6);
    }
}

/// `editor` is F4's command template: zoe unless the config names one,
/// and a blank one is ignored rather than leaving F4 with nothing to run.
pub fn configReadsEditorTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var def = config.load(alloc, "config = {}");
    defer def.deinit(alloc);
    try testz.expectEqualStr(def.config.editorCommand(), "zoe");

    var set = config.load(alloc, "config = { editor = \"zoe --quiet {sel}\" }");
    defer set.deinit(alloc);
    try testz.expectEqualStr(set.config.editorCommand(), "zoe --quiet {sel}");

    for ([_][:0]const u8{
        "config = { editor = \"\" }",
        "config = { editor = \"   \" }",
        "config = { editor = 3 }",
    }) |src| {
        var bad = config.load(alloc, src);
        defer bad.deinit(alloc);
        try testz.expectEqualStr(bad.config.editorCommand(), "zoe");
    }
}

pub fn configSyntaxErrorKeepsDefaultsTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var r = config.load(alloc, "config = { view = ");
    defer r.deinit(alloc);
    try testz.expectTrue(r.err != null);
    try testz.expectEqual(r.config.view, sala.pane.ViewMode.small);
}

pub fn paneFindsRowsByTypedPrefixTest(io: std.Io, alloc: std.mem.Allocator) !void {
    var s = try Scratch.init(io, alloc, "find");
    defer s.deinit();
    try s.file("README", "");
    try s.file("report.txt", "");
    try s.mkdir("Recipes");

    var p = try Pane.init(alloc, io, s.path, .{});
    defer p.deinit();
    // Directories sort first: `..`, Recipes, README, report.txt.
    try testz.expectEqualStr(rowName(&p, p.rowStartingWith("r").?), "Recipes");
    // ASCII case is ignored, so a typed `re` still refines.
    try testz.expectEqualStr(rowName(&p, p.rowStartingWith("rea").?), "README");
    try testz.expectEqualStr(rowName(&p, p.rowStartingWith("REPO").?), "report.txt");
    try testz.expectTrue(p.rowStartingWith("z") == null);
    // The `..` row has no name to type.
    try testz.expectTrue(p.rowStartingWith(".") == null);
    try testz.expectTrue(p.rowStartingWith("") == null);
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

pub fn shellPanelTakesAThirdOfTheWindowTest(_: std.Io, _: std.mem.Allocator) !void {
    const rowsFor = @import("applib").shellpanel.Panel.rowsFor;
    // A third of the window, once there's a third worth having.
    try testz.expectEqual(rowsFor(45), 15);
    try testz.expectEqual(rowsFor(30), 10);
    // Short windows get the floor, tall ones the ceiling -- a panel is
    // for reading a command's output, not for taking over.
    try testz.expectEqual(rowsFor(12), 6);
    try testz.expectEqual(rowsFor(200), 24);
    // Never taller than the window it sits in: the key bar and a couple
    // of rows of file pane survive whatever happens.
    try testz.expectEqual(rowsFor(6), 3);
    try testz.expectEqual(rowsFor(3), 1);
    try testz.expectEqual(rowsFor(1), 1);
}

pub fn shellPanelKeepsADraggedHeightTest(_: std.Io, _: std.mem.Allocator) !void {
    const rowsForWanted = @import("applib").shellpanel.Panel.rowsForWanted;
    // Nothing dragged: the default share.
    try testz.expectEqual(rowsForWanted(45, null), 15);
    // A dragged height is the user's, past the default's 24-row ceiling
    // and under its 6-row floor alike.
    try testz.expectEqual(rowsForWanted(60, 40), 40);
    try testz.expectEqual(rowsForWanted(45, 3), 3);
    // But never so short there's no prompt and output line ...
    try testz.expectEqual(rowsForWanted(45, 1), 2);
    // ... and never past the key bar and the two rows kept above it.
    try testz.expectEqual(rowsForWanted(30, 40), 27);
    try testz.expectEqual(rowsForWanted(3, 40), 1);
}

pub fn shellPanelDocksAlongEachEdgeTest(_: std.Io, _: std.mem.Allocator) !void {
    const sp = @import("applib").shellpanel;
    const win: sp.WinSize = .{ .cols = 100, .rows = 46 };

    // Bottom: full width, its height off the bar row.
    const bottom = sp.layoutFor(win, .bottom, 80, null, null);
    try testz.expectEqual(bottom.content.rows, 15);
    try testz.expectEqual(bottom.content.row, 46 - 15 - 1);
    try testz.expectEqual(bottom.content.cols, 100);
    try testz.expectTrue(bottom.frame == null);

    // Top: the same height, from the window's top row.
    const top = sp.layoutFor(win, .top, 80, 10, null);
    try testz.expectEqual(top.content.row, 0);
    try testz.expectEqual(top.content.rows, 10);

    // Sides: two fifths of the width, down to the bar row.
    const left = sp.layoutFor(win, .left, 80, null, null);
    try testz.expectEqual(left.content.col, 0);
    try testz.expectEqual(left.content.cols, 40);
    try testz.expectEqual(left.content.rows, 45);
    const right = sp.layoutFor(win, .right, 80, null, 25);
    try testz.expectEqual(right.content.col, 75);
    try testz.expectEqual(right.content.cols, 25);

    // Each docked position drags the edge facing the panes.
    try testz.expectEqual(sp.Position.bottom.resizeEdge(), .top);
    try testz.expectEqual(sp.Position.top.resizeEdge(), .bottom);
    try testz.expectEqual(sp.Position.left.resizeEdge(), .right);
    try testz.expectEqual(sp.Position.right.resizeEdge(), .left);
    try testz.expectEqual(sp.Position.float.resizeEdge(), .none);
}

pub fn shellPanelSideWidthTest(_: std.Io, _: std.mem.Allocator) !void {
    const Panel = @import("applib").shellpanel.Panel;
    try testz.expectEqual(Panel.colsFor(100), 40);
    // Floor and ceiling, as for the height.
    try testz.expectEqual(Panel.colsFor(50), 30);
    try testz.expectEqual(Panel.colsFor(500), 120);
    // Ten columns of pane always survive beside it.
    try testz.expectEqual(Panel.colsFor(35), 25);
    // A dragged width is the user's, within the room there is.
    try testz.expectEqual(Panel.colsForWanted(100, 70), 70);
    try testz.expectEqual(Panel.colsForWanted(100, 95), 90);
    try testz.expectEqual(Panel.colsForWanted(100, 3), 10);
}

pub fn shellPanelFloatsCenteredInAFrameTest(_: std.Io, _: std.mem.Allocator) !void {
    const sp = @import("applib").shellpanel;
    // 51 rows less the bar is 50 to centre in.
    const win: sp.WinSize = .{ .cols = 100, .rows = 51 };
    const l = sp.layoutFor(win, .float, 80, 7, 7);
    // 80% each way, centred, and a dragged size means nothing here.
    try testz.expectEqual(l.content.cols, 80);
    try testz.expectEqual(l.content.rows, 40);
    try testz.expectEqual(l.content.col, 10);
    try testz.expectEqual(l.content.row, 5);
    // The frame is a cell bigger all round.
    const fr = l.frame.?;
    try testz.expectEqual(fr.row, 4);
    try testz.expectEqual(fr.col, 9);
    try testz.expectEqual(fr.cols, 82);
    try testz.expectEqual(fr.rows, 42);

    // 100% still leaves the frame on screen.
    const full = sp.layoutFor(win, .float, 100, null, null);
    try testz.expectEqual(full.content.cols, 98);
    try testz.expectEqual(full.frame.?.col, 0);
    try testz.expectEqual(full.frame.?.row, 0);
    try testz.expectEqual(full.frame.?.rows, 50);
    // Out-of-range percentages are held to 10..100.
    const tiny = sp.layoutFor(win, .float, 1, null, null);
    try testz.expectEqual(tiny.content.cols, 10);
}

pub fn shellPanelConfigTest(_: std.Io, alloc: std.mem.Allocator) !void {
    {
        var r = config.load(alloc, "config = { shell_position = \"left\", shell_float_percent = 60 }");
        defer r.deinit(alloc);
        try testz.expectEqual(r.config.shell_position, .left);
        try testz.expectEqual(r.config.shell_float_percent, 60);
    }
    {
        // An unknown position keeps the default; a size out of range is
        // clamped, as every luaconf range is.
        var r = config.load(alloc, "config = { shell_position = \"diagonal\", shell_float_percent = 300 }");
        defer r.deinit(alloc);
        try testz.expectEqual(r.config.shell_position, .bottom);
        try testz.expectEqual(r.config.shell_float_percent, 100);
    }
}

pub fn shellPanelHitTestIsItsRowsTest(io: std.Io, alloc: std.mem.Allocator) !void {
    const Panel = @import("applib").shellpanel.Panel;
    // `contains` reads only what `place` recorded; no client is touched.
    var p = Panel.init(alloc, io, undefined, .{ .context = 0, .token = @splat('0') }, .{ .frame = 0, .shell = 1 }, null);
    p.bounds = .{ .row = 20, .col = 0, .cols = 600, .rows = 8 };
    // Hidden, it covers nothing.
    try testz.expectFalse(p.contains(.{ .row = 22, .col = 5 }));

    p.visible = true;
    try testz.expectFalse(p.contains(.{ .row = 19, .col = 5 }));
    try testz.expectTrue(p.contains(.{ .row = 20, .col = 0 }));
    try testz.expectTrue(p.contains(.{ .row = 27, .col = 500 }));
    // The row below it is the statusline / key bar, not the panel.
    try testz.expectFalse(p.contains(.{ .row = 28, .col = 5 }));
}

// ─── Open actions ───────────────────────────────────────────────────────

pub fn openActionResolvesByExtensionTest(_: std.Io, _: std.mem.Allocator) !void {
    const none: []const openaction.Action = &.{};
    try testz.expectEqualStr(openaction.resolve(none, "/tmp/notes.md").?, "gwmd {sel}");
    // The key is case-folded, so a shouty extension still matches.
    try testz.expectEqualStr(openaction.resolve(none, "/tmp/Book.CBZ").?, "gw-read {sel}");
    try testz.expectEqualStr(openaction.resolve(none, "/tmp/shot.jpeg").?, "gw-view --interactive {sel}");
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
    try testz.expectEqualStr(openaction.resolve(&user, "/tmp/shot.jpg").?, "gw-view --interactive {sel}");
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
    try testz.expectEqualStr(openaction.resolve(user, "/tmp/x.jpg").?, "gw-view --interactive {sel}");
}

/// Ctrl+Shift+C's clipboard line: space-separated, bare where it can be,
/// quoted where it must be. The destination is the Ctrl+` shell panel
/// (`zip shots.zip ` + paste), so a path with a space has to survive the
/// round trip as one argument rather than two.
pub fn copiedPathsLineQuotesOnlyWhatNeedsItTest(io: std.Io, alloc: std.mem.Allocator) !void {
    _ = io;

    const plain = try sala.ui.pathsLine(alloc, &.{ "/home/j/a.txt", "/home/j/b.zip" });
    defer alloc.free(plain);
    try testz.expectEqualStr(plain, "/home/j/a.txt /home/j/b.zip");

    // A space and a shell metacharacter each force quoting; the neighbours
    // stay bare.
    const mixed = try sala.ui.pathsLine(alloc, &.{ "/home/j/a.txt", "/home/j/my file.txt", "/home/j/a&b" });
    defer alloc.free(mixed);
    try testz.expectEqualStr(mixed, "/home/j/a.txt '/home/j/my file.txt' '/home/j/a&b'");

    // One path is just that path -- no separator, no wrapper.
    const single = try sala.ui.pathsLine(alloc, &.{"/home/j/only"});
    defer alloc.free(single);
    try testz.expectEqualStr(single, "/home/j/only");

    // Nothing selected produces nothing; `copySelectionPaths` returns
    // before this is reached, but an empty line must not be a space.
    const none = try sala.ui.pathsLine(alloc, &.{});
    defer alloc.free(none);
    try testz.expectEqualStr(none, "");
}

// ─── F3 find / F4 edit ──────────────────────────────────────────────────

/// An F3 result is relative to the pane it was searched from: a file
/// sends the pane to its directory with the cursor on it, a directory
/// (trailing `/`, as the finder lists them) is entered.
pub fn findTargetSplitsFilesAndEntersDirsTest(_: std.Io, alloc: std.mem.Allocator) !void {
    const file = try sala.ui.findTarget(alloc, "/home/j", "src/deep/main.zig");
    defer file.deinit(alloc);
    try testz.expectEqualStr(file.dir, "/home/j/src/deep");
    try testz.expectEqualStr(file.name.?, "main.zig");

    const dir = try sala.ui.findTarget(alloc, "/home/j", "src/deep/");
    defer dir.deinit(alloc);
    try testz.expectEqualStr(dir.dir, "/home/j/src/deep");
    try testz.expectTrue(dir.name == null);

    // Searched from `/`: the parent is `/` itself, not an empty string.
    const top = try sala.ui.findTarget(alloc, "/", "etc");
    defer top.deinit(alloc);
    try testz.expectEqualStr(top.dir, "/");
    try testz.expectEqualStr(top.name.?, "etc");
}

pub fn paneRevealPutsTheCursorOnTheFoundEntryTest(io: std.Io, alloc: std.mem.Allocator) !void {
    var s = try Scratch.init(io, alloc, "reveal");
    defer s.deinit();
    try s.mkdir("sub");
    try s.file("sub/a.txt", "");
    try s.file("sub/b.txt", "");
    try s.file("sub/c.txt", "");

    var p = try Pane.init(alloc, io, s.path, .{});
    defer p.deinit();
    const sub = try s.abs("sub");
    defer alloc.free(sub);

    try p.reveal(sub, "c.txt");
    try testz.expectEqualStr(p.path, sub);
    try testz.expectEqualStr(rowName(&p, p.list.selected), "c.txt");

    // Gone since the walk: the pane still goes there, cursor at the top.
    try p.reveal(sub, "vanished.txt");
    try testz.expectEqual(p.list.selected, 0);
}

/// F4's refusal: the same NUL-in-the-head test zoe applies, read from the
/// file rather than from a buffer already loaded. Empty is text (a new
/// file), and a file that can't be opened is an error, not "binary".
pub fn fileLooksBinaryReadsOnlyTheHeadTest(io: std.Io, alloc: std.mem.Allocator) !void {
    const filetype = @import("applib").filetype;
    var s = try Scratch.init(io, alloc, "sniff");
    defer s.deinit();
    try s.file("text.zig", "const std = @import(\"std\");\n");
    try s.file("empty", "");
    try s.file("image.png", "\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR");

    // A NUL past the sniffed head doesn't count: only the head is read.
    const late = try alloc.alloc(u8, filetype.sniff_bytes + 16);
    defer alloc.free(late);
    @memset(late, 'x');
    late[filetype.sniff_bytes + 4] = 0;
    try s.file("late-nul.txt", late);

    const cases = [_]struct { name: []const u8, binary: bool }{
        .{ .name = "text.zig", .binary = false },
        .{ .name = "empty", .binary = false },
        .{ .name = "image.png", .binary = true },
        .{ .name = "late-nul.txt", .binary = false },
    };
    for (cases) |case| {
        const path = try s.abs(case.name);
        defer alloc.free(path);
        try testz.expectEqual(try filetype.fileLooksBinary(io, path), case.binary);
    }

    const missing = try s.abs("nope");
    defer alloc.free(missing);
    if (filetype.fileLooksBinary(io, missing)) |_| {
        return error.ExpectedAnError;
    } else |err| try testz.expectEqual(err, error.FileNotFound);
}

// ─── Drag and drop between the panes ────────────────────────────────────

const drag = sala.drag;

pub fn dragCarriesTheMarkedSetOrTheRowTest(io: std.Io, alloc: std.mem.Allocator) !void {
    var s = try Scratch.init(io, alloc, "drag-carry");
    defer s.deinit();
    try s.file("a", "");
    try s.file("b", "");
    try s.file("c", "");

    var p = try Pane.init(alloc, io, s.path, .{});
    defer p.deinit();
    p.toggleMark(1);
    p.toggleMark(3);

    // On a marked row: the whole marked set.
    const set = try drag.carried(alloc, &p, 3);
    defer alloc.free(set);
    try testz.expectEqual(set.len, 2);
    try testz.expectEqualStr(std.fs.path.basename(set[0]), "a");
    try testz.expectEqualStr(std.fs.path.basename(set[1]), "c");

    // On an unmarked one: that row alone, marks or not.
    const one = try drag.carried(alloc, &p, 2);
    defer alloc.free(one);
    try testz.expectEqual(one.len, 1);
    try testz.expectEqualStr(std.fs.path.basename(one[0]), "b");

    // `..` carries nothing.
    const none = try drag.carried(alloc, &p, 0);
    defer alloc.free(none);
    try testz.expectEqual(none.len, 0);
}

pub fn dropOnAFolderOrTheOtherPaneTest(io: std.Io, alloc: std.mem.Allocator) !void {
    var s = try Scratch.init(io, alloc, "drag-drop");
    defer s.deinit();
    try s.mkdir("left/sub");
    try s.file("left/f", "");
    try s.mkdir("right/inbox");
    try s.file("right/g", "");

    const left_path = try s.abs("left");
    defer alloc.free(left_path);
    const right_path = try s.abs("right");
    defer alloc.free(right_path);
    var panes = [2]Pane{
        try Pane.init(alloc, io, left_path, .{}),
        try Pane.init(alloc, io, right_path, .{}),
    };
    defer for (&panes) |*p| p.deinit();

    const f_row = panes[0].rowOf("f").?;
    const sources = try drag.carried(alloc, &panes[0], f_row);
    defer alloc.free(sources);

    // A folder in the same pane.
    const sub_row = panes[0].rowOf("sub").?;
    const sub = drag.resolve(&panes, 0, sources, .{ .pane = 0, .row = sub_row }).?;
    try testz.expectEqual(sub.pane, 0);
    try testz.expectEqual(sub.row.?, sub_row);
    try testz.expectEqualStr(std.fs.path.basename(sub.dest), "sub");

    // `..` is the parent folder.
    const up = drag.resolve(&panes, 0, sources, .{ .pane = 0, .row = 0 }).?;
    try testz.expectEqualStr(up.dest, s.path);

    // The rest of the source pane drops nothing: the file is already there.
    try testz.expectTrue(drag.resolve(&panes, 0, sources, .{ .pane = 0, .row = f_row }) == null);
    try testz.expectTrue(drag.resolve(&panes, 0, sources, .{ .pane = 0 }) == null);

    // A folder in the other pane, and anywhere else there is its directory.
    const inbox = drag.resolve(&panes, 0, sources, .{ .pane = 1, .row = panes[1].rowOf("inbox").? }).?;
    try testz.expectEqualStr(std.fs.path.basename(inbox.dest), "inbox");
    const other = drag.resolve(&panes, 0, sources, .{ .pane = 1, .row = panes[1].rowOf("g").? }).?;
    try testz.expectTrue(other.row == null);
    try testz.expectEqualStr(other.dest, right_path);
    const empty = drag.resolve(&panes, 0, sources, .{ .pane = 1 }).?;
    try testz.expectEqualStr(empty.dest, right_path);
}

pub fn dropNeverLandsADirInItselfOrWhereItIsTest(io: std.Io, alloc: std.mem.Allocator) !void {
    var s = try Scratch.init(io, alloc, "drag-noop");
    defer s.deinit();
    try s.mkdir("sub/inner");

    // Both panes on the same directory.
    var panes = [2]Pane{
        try Pane.init(alloc, io, s.path, .{}),
        try Pane.init(alloc, io, s.path, .{}),
    };
    defer for (&panes) |*p| p.deinit();

    const sub_row = panes[0].rowOf("sub").?;
    const sources = try drag.carried(alloc, &panes[0], sub_row);
    defer alloc.free(sources);

    // Onto itself, in either pane.
    try testz.expectTrue(drag.resolve(&panes, 0, sources, .{ .pane = 0, .row = sub_row }) == null);
    try testz.expectTrue(drag.resolve(&panes, 0, sources, .{ .pane = 1, .row = sub_row }) == null);
    // The other pane's directory is the one it's already in.
    try testz.expectTrue(drag.resolve(&panes, 0, sources, .{ .pane = 1 }) == null);

    // Into its own child, from the other pane browsed inside it.
    try panes[1].load(sources[0]);
    const inner_row = panes[1].rowOf("inner").?;
    try testz.expectTrue(drag.resolve(&panes, 0, sources, .{ .pane = 1, .row = inner_row }) == null);
}

pub fn dragStartsPastTheSlopTest(_: std.Io, _: std.mem.Allocator) !void {
    try testz.expectFalse(drag.pastThreshold(10, 10, 15, 14));
    try testz.expectTrue(drag.pastThreshold(10, 10, 16, 10));
    try testz.expectTrue(drag.pastThreshold(10, 10, 10, 4));
}

// ─── Masked dialog field (the sudo password) ────────────────────────────

pub fn maskTextIsOneGlyphPerCodepointTest(_: std.Io, _: std.mem.Allocator) !void {
    var buf: [64]u8 = undefined;
    const g = dialog.mask_glyph;
    // Three codepoints, the last two bytes long: three glyphs, and a
    // caret after the first lands after the first glyph.
    const m = dialog.maskText(&buf, "aé!", 1);
    try testz.expectEqualStr(m.text, g ++ g ++ g);
    try testz.expectEqual(m.caret, g.len);
    // A caret at the end of the text is at the end of the mask.
    try testz.expectEqual(dialog.maskText(&buf, "aé!", 4).caret, 3 * g.len);
    try testz.expectEqualStr(dialog.maskText(&buf, "", 0).text, "");
    // Too small a buffer truncates rather than overrunning it.
    var small: [5]u8 = undefined;
    const t = dialog.maskText(&small, "abc", 3);
    try testz.expectEqualStr(t.text, g);
    try testz.expectEqual(t.caret, g.len);
}

/// A masked field's word keys act on the whole field: a password has no
/// words, and stopping at one would give away where its punctuation is.
pub fn maskedDialogWordKeysTakeTheWholeFieldTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var d = try dialog.Dialog.init(alloc, "sudo", "Password for sudo:", &dialog.ok_cancel, .{ .input = "", .masked = true });
    defer d.deinit(alloc);
    try d.handleText(alloc, "hunter/2 x");
    try testz.expectTrue(d.handleKey("left", .{ .ctrl = true }) == null);
    try testz.expectEqual(d.input.?.caret, 0);
    try testz.expectTrue(d.handleKey("right", .{ .ctrl = true }) == null);
    try testz.expectEqual(d.input.?.caret, "hunter/2 x".len);
    try testz.expectTrue(d.handleKey("backspace", .{ .ctrl = true }) == null);
    try testz.expectEqualStr(d.inputText(), "");

    // An unmasked field keeps its word jumps.
    var plain = try dialog.Dialog.init(alloc, "t", "m", &dialog.ok_cancel, .{ .input = "/a/b" });
    defer plain.deinit(alloc);
    try testz.expectTrue(plain.handleKey("backspace", .{ .ctrl = true }) == null);
    try testz.expectEqualStr(plain.inputText(), "/a/");
}

// ─── sudo helper ────────────────────────────────────────────────────────

/// Collects what the commander's side of `sudo.drive` was asked, and
/// answers conflicts with `answer`.
const Asked = struct {
    conflicts: usize = 0,
    progress: usize = 0,
    errors: usize = 0,
    answer: fileops.Conflict = .overwrite,

    fn hooks(self: *Asked) fileops.Hooks {
        return .{ .ctx = self, .onConflict = onConflict, .onProgress = onProgress, .onError = onError };
    }
    fn onConflict(ctx: *anyopaque, _: []const u8, _: []const u8) fileops.Conflict {
        const self: *Asked = @ptrCast(@alignCast(ctx));
        self.conflicts += 1;
        return self.answer;
    }
    fn onProgress(ctx: *anyopaque, _: fileops.Kind, _: usize, _: usize, _: []const u8) void {
        const self: *Asked = @ptrCast(@alignCast(ctx));
        self.progress += 1;
    }
    fn onError(ctx: *anyopaque, _: []const u8, _: anyerror) bool {
        const self: *Asked = @ptrCast(@alignCast(ctx));
        self.errors += 1;
        return true;
    }
};

/// The helper's messages, replayed into the commander's `drive`: the
/// root side asks "File exists" over the pipe, the answer it was given
/// is the one the commander's hook gives, and both ends agree on the
/// result. The two halves run one after the other here, with the
/// helper's answers scripted -- `drive` must write the same ones back.
pub fn sudoHelperRoundTripsAConflictTest(io: std.Io, alloc: std.mem.Allocator) !void {
    var s = try Scratch.init(io, alloc, "sudo-copy");
    defer s.deinit();
    try s.mkdir("dest");
    try s.file("a.txt", "new");
    try s.file("dest/a.txt", "old");
    const src = try s.abs("a.txt");
    defer alloc.free(src);
    const dest = try s.abs("dest");
    defer alloc.free(dest);

    var helper_in: std.Io.Reader = .fixed("overwrite\x00");
    var helper_out: std.Io.Writer.Allocating = .init(alloc);
    defer helper_out.deinit();
    try testz.expectEqual(sala.sudo.serve(io, alloc, &.{ "copy", dest, src }, &helper_in, &helper_out.writer), 0);
    const copied = try s.read("dest/a.txt");
    defer alloc.free(copied);
    try testz.expectEqualStr(copied, "new");

    var ui_in: std.Io.Reader = .fixed(helper_out.written());
    var ui_out: std.Io.Writer.Allocating = .init(alloc);
    defer ui_out.deinit();
    var asked: Asked = .{};
    const result = (try sala.sudo.drive(alloc, &ui_in, &ui_out.writer, asked.hooks())).?;
    try testz.expectEqual(asked.progress, 1);
    try testz.expectEqual(asked.conflicts, 1);
    try testz.expectEqualStr(ui_out.written(), "overwrite\x00");
    try testz.expectEqual(result.done, 1);
    try testz.expectEqual(result.failed, 0);
    try testz.expectFalse(result.cancelled);
}

/// A one-shot operation's failure crosses the pipe by name and comes
/// back as the same error, which is what lets F7 and F2 say "already
/// exists" for a root run exactly as for their own.
pub fn sudoHelperReportsErrorsByNameTest(io: std.Io, alloc: std.mem.Allocator) !void {
    var s = try Scratch.init(io, alloc, "sudo-mkdir");
    defer s.deinit();
    try s.mkdir("there");
    const there = try s.abs("there");
    defer alloc.free(there);

    var helper_in: std.Io.Reader = .fixed("");
    var helper_out: std.Io.Writer.Allocating = .init(alloc);
    defer helper_out.deinit();
    try testz.expectEqual(sala.sudo.serve(io, alloc, &.{ "mkdir", there }, &helper_in, &helper_out.writer), 0);

    var ui_in: std.Io.Reader = .fixed(helper_out.written());
    var ui_out: std.Io.Writer.Allocating = .init(alloc);
    defer ui_out.deinit();
    var asked: Asked = .{};
    const result = (try sala.sudo.drive(alloc, &ui_in, &ui_out.writer, asked.hooks())).?;
    try testz.expectEqual(result.failed, 1);
    try testz.expectTrue(result.first_error.? == error.PathAlreadyExists);

    try testz.expectTrue(sala.sudo.errorFromName("AccessDenied") == error.AccessDenied);
    try testz.expectTrue(sala.sudo.errorFromName("NoSuchThing") == error.Unexpected);
}

/// Arguments the helper can't read get nothing on the pipe, and the
/// commander reads a helper that stopped before `done` as "didn't run".
pub fn sudoHelperRefusesBadArgumentsTest(io: std.Io, alloc: std.mem.Allocator) !void {
    var helper_in: std.Io.Reader = .fixed("");
    var helper_out: std.Io.Writer.Allocating = .init(alloc);
    defer helper_out.deinit();
    try testz.expectEqual(sala.sudo.serve(io, alloc, &.{"chmod"}, &helper_in, &helper_out.writer), 2);
    try testz.expectEqual(sala.sudo.serve(io, alloc, &.{"copy"}, &helper_in, &helper_out.writer), 2);
    try testz.expectEqual(sala.sudo.serve(io, alloc, &.{ "rename", "/tmp", "a" }, &helper_in, &helper_out.writer), 2);
    try testz.expectEqual(helper_out.written().len, 0);

    var ui_in: std.Io.Reader = .fixed("");
    var ui_out: std.Io.Writer.Allocating = .init(alloc);
    defer ui_out.deinit();
    var asked: Asked = .{};
    try testz.expectTrue((try sala.sudo.drive(alloc, &ui_in, &ui_out.writer, asked.hooks())) == null);
}

/// sudoedit's command line: the editor template without its `{sel}`,
/// behind an `env` carrying the glyphwire variables and the few that
/// find the editor and its config -- nothing else from the environment,
/// and nothing whose value sudo would split on whitespace.
pub fn sudoEditArgvForwardsTheGlyphwireEnvironmentTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var env: std.process.Environ.Map = .init(alloc);
    defer env.deinit();
    try env.put("GLYPHWIRE_SOCK", "/run/user/1000/gw.sock");
    try env.put("HOME", "/home/me");
    try env.put("SECRET_TOKEN", "abc");
    try env.put("GLYPHWIRE_CTX", "has space");

    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    const argv = try sala.sudo.editArgv(arena.allocator(), &env, "zoe --wrap {sel}", "/etc/hosts");
    try testz.expectEqual(argv.len, 7);
    try testz.expectEqualStr(argv[0], "env");
    try testz.expectEqualStr(argv[2], "sudo");
    try testz.expectEqualStr(argv[4], "-e");
    try testz.expectEqualStr(argv[6], "/etc/hosts");

    const editor = argv[1];
    try testz.expectTrue(std.mem.startsWith(u8, editor, "SUDO_EDITOR=env "));
    try testz.expectTrue(std.mem.indexOf(u8, editor, " GLYPHWIRE_SOCK=/run/user/1000/gw.sock") != null);
    try testz.expectTrue(std.mem.indexOf(u8, editor, " HOME=/home/me") != null);
    try testz.expectTrue(std.mem.indexOf(u8, editor, "SECRET_TOKEN") == null);
    try testz.expectTrue(std.mem.indexOf(u8, editor, "GLYPHWIRE_CTX") == null);
    try testz.expectTrue(std.mem.endsWith(u8, editor, " zoe --wrap"));

    try testz.expectError(sala.sudo.editArgv(arena.allocator(), null, "{sel}", "/etc/hosts"), error.EmptyCommand);
}

pub fn sudoLastLineIsTheComplaintTest(_: std.Io, _: std.mem.Allocator) !void {
    try testz.expectEqualStr(sala.sudo.lastLine("sudo: a password is required\n"), "a password is required");
    try testz.expectEqualStr(sala.sudo.lastLine("Sorry, try again.\nsudo: 1 incorrect password attempt\n\n"), "1 incorrect password attempt");
    try testz.expectEqualStr(sala.sudo.lastLine(""), "");
}

/// Super is "as root" on the same function keys, and Shift+F4 is MC's
/// edit-a-new-file.
pub fn sudoActionsHaveSuperChordsTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var km = try actions.Keymap.initDefaults(alloc, &actions.defaults);
    defer km.deinit(alloc);
    try testz.expectEqual(km.lookup("F5", .{ .super = true }).?, actions.Action.sudoCopy);
    try testz.expectEqual(km.lookup("F8", .{ .super = true }).?, actions.Action.sudoDelete);
    try testz.expectEqual(km.lookup("F4", .{ .shift = true }).?, actions.Action.newFile);
    try testz.expectEqual(km.lookup("F4", .{ .super = true, .shift = true }).?, actions.Action.sudoNewFile);
    try testz.expectEqual(km.lookup("F5", .{}).?, actions.Action.copy);
}

// ─── F1: chmod / chown ──────────────────────────────────────────────────

const attrs = sala.attrs;
const attrdialog = sala.attrdialog;

fn modeOf(s: *Scratch, name: []const u8) !u12 {
    const st = try s.dir.statFile(s.io, name, .{ .follow_symlinks = false });
    return @truncate(st.permissions.toMode() & 0o7777);
}

pub fn attrsParseOctalTest(_: std.Io, _: std.mem.Allocator) !void {
    try testz.expectEqual(attrs.parseOctal("755").?, 0o755);
    try testz.expectEqual(attrs.parseOctal("0644").?, 0o644);
    try testz.expectEqual(attrs.parseOctal("4755").?, 0o4755);
    try testz.expectEqual(attrs.parseOctal(" 7 ").?, 0o7);
    try testz.expectTrue(attrs.parseOctal("") == null);
    try testz.expectTrue(attrs.parseOctal("8") == null);
    try testz.expectTrue(attrs.parseOctal("12345") == null);
    var buf: [4]u8 = undefined;
    try testz.expectEqualStr(attrs.formatOctal(&buf, 0o755), "0755");
}

/// "Every file under here, but not the directories": the case the files
/// only filter is for. Directories below keep their mode, and the walk
/// still gets into them.
pub fn chmodRecursiveFilesOnlyLeavesDirectoriesTest(io: std.Io, alloc: std.mem.Allocator) !void {
    var s = try Scratch.init(io, alloc, "chmod-files");
    defer s.deinit();
    try s.mkdir("top/sub");
    try s.file("top/a.txt", "a");
    try s.file("top/sub/b.txt", "b");
    const top_mode = try modeOf(&s, "top");
    const sub_mode = try modeOf(&s, "top/sub");
    const top = try s.abs("top");
    defer alloc.free(top);

    const r = (attrs.Operation{ .change = .{ .mode = 0o600 }, .sources = &.{top}, .recursive = true, .filter = .files }).run(io, alloc, fileops.quiet_hooks);
    try testz.expectEqual(r.done, 2);
    try testz.expectEqual(r.failed, 0);
    try testz.expectEqual(try modeOf(&s, "top/a.txt"), 0o600);
    try testz.expectEqual(try modeOf(&s, "top/sub/b.txt"), 0o600);
    try testz.expectEqual(try modeOf(&s, "top"), top_mode);
    try testz.expectEqual(try modeOf(&s, "top/sub"), sub_mode);
}

/// Directories only, and not recursive: the selected file is left alone
/// and the selected directory changes, but nothing inside it does.
pub fn chmodDirsOnlyTopLevelTest(io: std.Io, alloc: std.mem.Allocator) !void {
    var s = try Scratch.init(io, alloc, "chmod-dirs");
    defer s.deinit();
    try s.mkdir("d/inner");
    try s.file("f.txt", "f");
    const f_mode = try modeOf(&s, "f.txt");
    const inner_mode = try modeOf(&s, "d/inner");
    const d = try s.abs("d");
    defer alloc.free(d);
    const f = try s.abs("f.txt");
    defer alloc.free(f);

    const r = (attrs.Operation{ .change = .{ .mode = 0o711 }, .sources = &.{ d, f }, .filter = .dirs }).run(io, alloc, fileops.quiet_hooks);
    try testz.expectEqual(r.done, 1);
    try testz.expectEqual(try modeOf(&s, "d"), 0o711);
    try testz.expectEqual(try modeOf(&s, "d/inner"), inner_mode);
    try testz.expectEqual(try modeOf(&s, "f.txt"), f_mode);
}

/// A link in the tree is never followed: its target outside keeps its
/// mode.
pub fn chmodSkipsSymlinksTest(io: std.Io, alloc: std.mem.Allocator) !void {
    var s = try Scratch.init(io, alloc, "chmod-link");
    defer s.deinit();
    try s.mkdir("tree");
    try s.file("outside.txt", "o");
    const outside = try s.abs("outside.txt");
    defer alloc.free(outside);
    try s.dir.symLink(io, outside, "tree/link", .{});
    const before = try modeOf(&s, "outside.txt");
    const tree = try s.abs("tree");
    defer alloc.free(tree);

    const r = (attrs.Operation{ .change = .{ .mode = 0o600 }, .sources = &.{tree}, .recursive = true, .filter = .files }).run(io, alloc, fileops.quiet_hooks);
    try testz.expectEqual(r.failed, 0);
    try testz.expectEqual(r.done, 0);
    try testz.expectEqual(try modeOf(&s, "outside.txt"), before);
}

/// chown to the ids a file already has needs no privilege, so the walk
/// can be exercised as an ordinary user.
pub fn chownToOwnIdsTest(io: std.Io, alloc: std.mem.Allocator) !void {
    var s = try Scratch.init(io, alloc, "chown-self");
    defer s.deinit();
    try s.mkdir("d");
    try s.file("d/a.txt", "a");
    const d = try s.abs("d");
    defer alloc.free(d);
    const uid: u32 = std.os.linux.getuid();

    const r = (attrs.Operation{ .change = .{ .owner = .{ .uid = uid } }, .sources = &.{d}, .recursive = true }).run(io, alloc, fileops.quiet_hooks);
    try testz.expectEqual(r.failed, 0);
    try testz.expectEqual(r.done, 2);
}

pub fn attrsHelperArgsRoundTripTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const chmod: attrs.Operation = .{ .change = .{ .mode = 0o4755 }, .sources = &.{ "/x", "/y" }, .recursive = true, .filter = .dirs };
    const cargs = try attrs.helperArgs(a, chmod);
    try testz.expectEqualStr(cargs[0], "chmod");
    const cback = attrs.parseHelperArgs(.chmod, cargs[1..]).?;
    try testz.expectEqual(cback.change.mode, 0o4755);
    try testz.expectTrue(cback.recursive);
    try testz.expectEqual(cback.filter, attrs.Filter.dirs);
    try testz.expectEqual(cback.sources.len, 2);

    const chown: attrs.Operation = .{ .change = .{ .owner = .{ .gid = 100 } }, .sources = &.{"/z"} };
    const oargs = try attrs.helperArgs(a, chown);
    const oback = attrs.parseHelperArgs(.chown, oargs[1..]).?;
    try testz.expectTrue(oback.change.owner.uid == null);
    try testz.expectEqual(oback.change.owner.gid.?, 100);
    try testz.expectFalse(oback.recursive);

    try testz.expectTrue(attrs.parseHelperArgs(.chmod, &.{ "999", "0", "all", "/x" }) == null);
    try testz.expectTrue(attrs.parseHelperArgs(.chmod, &.{ "755", "0", "all" }) == null);
    try testz.expectTrue(attrs.parseHelperArgs(.chown, &.{ "", "", "2", "all", "/x" }) == null);
}

/// The root helper runs a chmod and the commander reads its result, as
/// for a copy.
pub fn sudoHelperRunsChmodTest(io: std.Io, alloc: std.mem.Allocator) !void {
    var s = try Scratch.init(io, alloc, "sudo-chmod");
    defer s.deinit();
    try s.file("a.txt", "a");
    const a = try s.abs("a.txt");
    defer alloc.free(a);

    var helper_in: std.Io.Reader = .fixed("");
    var helper_out: std.Io.Writer.Allocating = .init(alloc);
    defer helper_out.deinit();
    try testz.expectEqual(sala.sudo.serve(io, alloc, &.{ "chmod", "640", "0", "all", a }, &helper_in, &helper_out.writer), 0);
    try testz.expectEqual(try modeOf(&s, "a.txt"), 0o640);

    var ui_in: std.Io.Reader = .fixed(helper_out.written());
    var ui_out: std.Io.Writer.Allocating = .init(alloc);
    defer ui_out.deinit();
    var asked: Asked = .{};
    const result = (try sala.sudo.drive(alloc, &ui_in, &ui_out.writer, asked.hooks())).?;
    try testz.expectEqual(asked.progress, 1);
    try testz.expectEqual(result.done, 1);
}

/// The toggles and the octal field follow each other both ways, and Set
/// won't take a field that isn't octal.
pub fn modeFormKeepsTogglesAndOctalInStepTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var f = try attrdialog.ModeForm.init(alloc, "\"a.txt\"", 0o644, false, false);
    defer f.deinit(alloc);
    try testz.expectEqualStr(f.form.field(f.octal).text(), "0644");
    try testz.expectTrue(f.form.isOn(f.bits[0]));
    try testz.expectFalse(f.form.isOn(f.bits[2]));

    // Owner exec on: the field follows.
    f.form.focus = f.bits[2];
    try testz.expectTrue((try f.handleKey(alloc, "space", .{})) == null);
    try testz.expectEqual(f.mode, 0o744);
    try testz.expectEqualStr(f.form.field(f.octal).text(), "0744");

    // Typed octal: the toggles follow, setuid included.
    f.form.focus = f.octal;
    try f.form.field(f.octal).setText(alloc, "");
    _ = try f.handleText(alloc, "4755");
    try testz.expectEqual(f.mode, 0o4755);
    try testz.expectTrue(f.form.isOn(f.bits[9]));
    try testz.expectTrue(f.form.isOn(f.bits[8]));

    // Not octal: complained about, toggles kept, Set refused.
    _ = try f.handleText(alloc, "9");
    try testz.expectTrue(f.form.err != null);
    try testz.expectEqual(f.mode, 0o4755);
    try testz.expectTrue((try f.handleKey(alloc, "enter", .{})) == null);

    try testz.expectEqual((try f.handleKey(alloc, "escape", .{})).?, attrdialog.Answer.cancel);
}

/// The arrows walk the toggle grid as a grid.
pub fn modeFormArrowsWalkTheGridTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var f = try attrdialog.ModeForm.init(alloc, "x", 0o644, true, false);
    defer f.deinit(alloc);
    f.form.focus = f.bits[0];
    _ = try f.handleKey(alloc, "right", .{});
    try testz.expectEqual(f.form.focus, f.bits[1]);
    _ = try f.handleKey(alloc, "down", .{});
    try testz.expectEqual(f.form.focus, f.bits[4]);
    _ = try f.handleKey(alloc, "left", .{});
    try testz.expectEqual(f.form.focus, f.bits[3]);

    // The filter's radio buttons: picking one turns the others off.
    try testz.expectEqual(f.filter(), attrs.Filter.all);
    const files_radio = f.form.widgets.items[f.scope.?.radios[1]];
    _ = try f.click(alloc, files_radio.row, files_radio.col);
    try testz.expectEqual(f.filter(), attrs.Filter.files);
    try testz.expectFalse(f.form.isOn(f.scope.?.radios[0]));
}

pub fn ownerFormValidatesNamesTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var f = try attrdialog.OwnerForm.init(alloc, "x", "no-such-user-here", "", false, false);
    defer f.deinit(alloc);
    try testz.expectTrue((try f.handleKey(alloc, "enter", .{})) == null);
    try testz.expectTrue(f.form.err != null);

    try f.form.field(f.user).setText(alloc, "");
    try testz.expectTrue((try f.handleKey(alloc, "enter", .{})) == null);
    try testz.expectTrue(f.form.err != null);

    try f.form.field(f.user).setText(alloc, "root");
    try f.form.field(f.group).setText(alloc, "0");
    try testz.expectEqual((try f.handleKey(alloc, "enter", .{})).?, attrdialog.Answer.set);
    try testz.expectEqual(f.owner.uid.?, 0);
    try testz.expectEqual(f.owner.gid.?, 0);
}

/// The menu is a keymap: its lines are the unmodified chords, and a pick
/// with modifiers held is the same key looked up with them.
pub fn fileOpsMenuPicksByHeldModifiersTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var km = try actions.Keymap.initDefaults(alloc, &actions.menu_defaults);
    defer km.deinit(alloc);
    var menu = attrdialog.Menu.init(&km);
    menu.load();
    try testz.expectEqual(menu.entries.len, 2);
    try testz.expectEqual(menu.entries[0], actions.Action.chmod);
    try testz.expectEqual(menu.entries[1], actions.Action.chown);

    try testz.expectEqual(menu.shown(0, .{}), actions.Action.chmod);
    try testz.expectEqual(menu.shown(0, .{ .super = true }), actions.Action.sudoChmod);
    // A modifier with nothing bound under it picks the plain entry.
    try testz.expectEqual(menu.shown(1, .{ .shift = true }), actions.Action.chown);
    try testz.expectTrue(menu.asRoot(.{ .super = true }));
    try testz.expectFalse(menu.asRoot(.{}));

    try testz.expectEqual(menu.handleKey("o", .{}).?.run, actions.Action.chown);
    try testz.expectTrue(menu.handleKey("down", .{}) == null);
    try testz.expectEqual(menu.handleKey("enter", .{ .super = true }).?.run, actions.Action.sudoChown);
    try testz.expectEqual(menu.click(0, .{ .super = true }).?.run, actions.Action.sudoChmod);
    try testz.expectTrue(menu.handleKey("escape", .{}).? == .cancel);
}

/// Ctrl+arrow toward the other side points that pane at this one's
/// directory.
pub fn ctrlArrowsSendTheDirectoryAcrossTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var km = try actions.Keymap.initDefaults(alloc, &actions.defaults);
    defer km.deinit(alloc);
    try testz.expectEqual(km.lookup("right", .{ .ctrl = true }).?, actions.Action.rightPaneToSameDir);
    try testz.expectEqual(km.lookup("left", .{ .ctrl = true }).?, actions.Action.leftPaneToSameDir);
}

/// With Ctrl held the bar lists Ctrl+H as `H Hidden`, Ctrl+1 as `1`, and
/// so on: the modifiers are said once in front.
pub fn modifiedBarKeyTextTest(_: std.Io, _: std.mem.Allocator) !void {
    var buf: [24]u8 = undefined;
    try testz.expectEqualStr(sala.ui.barKeyText(&buf, "h"), "H");
    try testz.expectEqualStr(sala.ui.barKeyText(&buf, "one"), "1");
    try testz.expectEqualStr(sala.ui.barKeyText(&buf, "grave_accent"), "`");
    try testz.expectEqualStr(sala.ui.barKeyText(&buf, "page_down"), "Page down");
}

/// `menu_keys` rebinds the menu the way `keys` rebinds the panes: here
/// root moves from Super to Alt+Shift.
pub fn configReadsMenuKeysTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var r = config.load(alloc,
        \\config = { menu_keys = { ["alt+shift+m"] = "sudoChmod", ["super+m"] = false } }
    );
    defer r.deinit(alloc);
    try testz.expectTrue(r.err == null);
    var km = try actions.Keymap.initDefaults(alloc, &actions.menu_defaults);
    defer km.deinit(alloc);
    try km.apply(alloc, r.config.menu_keys);
    try testz.expectEqual(actions.menuPick(&km, .chmod, .{ .alt = true, .shift = true }), actions.Action.sudoChmod);
    try testz.expectEqual(actions.menuPick(&km, .chmod, .{ .super = true }), actions.Action.chmod);
}

/// Polls `pollExit` for `pid` for up to two seconds.
fn awaitExit(io: std.Io, pid: std.posix.pid_t) ?std.process.Child.Term {
    for (0..200) |_| {
        if (sala.ui.pollExit(pid)) |term| return term;
        std.Io.sleep(io, .fromMilliseconds(10), .awake) catch {};
    }
    return null;
}

/// A launched program is reaped without blocking the loop: `pollExit`
/// says null while it runs, then hands back its exit code.
pub fn pollExitReportsTheExitCodeTest(_: std.Io, alloc: std.mem.Allocator) !void {
    // testz's Io has a failing allocator, and spawning needs a real one
    // (see e2e_tests.zig).
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var child = try std.process.spawn(io, .{
        .argv = &.{ "sh", "-c", "exit 3" },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    const term = awaitExit(io, child.id.?) orelse {
        _ = child.wait(io) catch {};
        return error.ChildNeverExited;
    };
    try testz.expectTrue(term == .exited);
    try testz.expectEqual(term.exited, 3);
}

/// One still running is left alone; a signal that ends it is told
/// apart from an exit code, which is what makes the bar say "was killed".
pub fn pollExitWaitsForNothingAndSeesSignalsTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var child = try std.process.spawn(io, .{
        .argv = &.{ "sleep", "10" },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    const pid = child.id.?;
    try testz.expectTrue(sala.ui.pollExit(pid) == null);
    try std.posix.kill(pid, .TERM);
    const term = awaitExit(io, pid) orelse {
        _ = child.wait(io) catch {};
        return error.ChildNeverExited;
    };
    try testz.expectTrue(term == .signal);
    try testz.expectEqual(term.signal, std.posix.SIG.TERM);
}

// ─── Session (`session.zig`) ────────────────────────────────────────────

const session = sala.session;

pub fn sessionRoundTripsTabsAndHistoryTest(io: std.Io, alloc: std.mem.Allocator) !void {
    var s = try Scratch.init(io, alloc, "session");
    defer s.deinit();
    try s.mkdir("a/inner");
    try s.mkdir("b");
    try s.file("b/note.txt", "");
    const a = try s.abs("a");
    defer alloc.free(a);
    const inner = try s.abs("a/inner");
    defer alloc.free(inner);
    const b = try s.abs("b");
    defer alloc.free(b);

    // Left: one tab that went a -> a/inner -> back to a, sorted by size.
    // Right: two tabs, the second (b, cursor on note.txt) shown.
    var shown: [2]Pane = .{ try Pane.init(alloc, io, a, .{}), try Pane.init(alloc, io, s.path, .{ .view = .large }) };
    var sets: [2]tabs.TabSet(Pane) = .{ .{}, .{} };
    defer {
        for (&shown) |*p| p.deinit();
        for (&sets) |*set| {
            for (set.others.items) |*p| p.deinit();
            set.deinit(alloc);
        }
    }
    try shown[0].load(inner);
    try testz.expectTrue(try shown[0].back());
    shown[0].setSort(.{ .key = .size, .dir = .descending });
    try sets[1].open(alloc, &shown[1], try Pane.init(alloc, io, b, .{ .show_hidden = true }));
    shown[1].list.selected = shown[1].rowOf("note.txt").?;

    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    const json = try session.serialize(alloc, try session.capture(arena.allocator(), &shown, &sets, 1));
    defer alloc.free(json);

    var loaded = session.parse(alloc, json) orelse return error.TestUnexpectedResult;
    defer loaded.deinit();
    const back = loaded.session();
    try testz.expectEqual(back.active, 1);

    var left = (try session.openSide(alloc, io, &back.sides[0])) orelse return error.TestUnexpectedResult;
    defer left.deinit(alloc);
    try testz.expectEqual(left.set.count(), 1);
    try testz.expectEqualStr(left.shown.path, a);
    try testz.expectTrue(left.shown.sort.key == .size and left.shown.sort.dir == .descending);
    // Back from `a` goes nowhere, and Forward still reaches a/inner.
    try testz.expectTrue(left.shown.history.backTarget() == null);
    try testz.expectEqualStr(left.shown.history.forwardTarget().?.path, inner);
    try testz.expectEqual(left.shown.history.recent.items.len, 2);

    var right = (try session.openSide(alloc, io, &back.sides[1])) orelse return error.TestUnexpectedResult;
    defer right.deinit(alloc);
    try testz.expectEqual(right.set.count(), 2);
    try testz.expectEqual(right.set.active, 1);
    try testz.expectEqualStr(right.shown.path, b);
    try testz.expectTrue(right.shown.show_hidden);
    try testz.expectEqualStr(rowName(&right.shown, right.shown.list.selected), "note.txt");
    try testz.expectEqualStr(right.set.others.items[0].path, s.path);
    try testz.expectTrue(right.set.others.items[0].view == .large);
}

pub fn sessionDropsTabsWhoseDirectoryIsGoneTest(io: std.Io, alloc: std.mem.Allocator) !void {
    var s = try Scratch.init(io, alloc, "session-gone");
    defer s.deinit();
    const gone = try s.abs("gone");
    defer alloc.free(gone);

    var two = [_]session.Tab{ .{ .path = s.path }, .{ .path = gone } };
    // The shown one is the one gone: its neighbour is all there is.
    var r = (try session.openSide(alloc, io, &.{ .tabs = &two, .active = 1 })) orelse return error.TestUnexpectedResult;
    defer r.deinit(alloc);
    try testz.expectEqual(r.set.count(), 1);
    try testz.expectEqualStr(r.shown.path, s.path);

    var none = [_]session.Tab{.{ .path = gone }};
    try testz.expectTrue((try session.openSide(alloc, io, &.{ .tabs = &none })) == null);
}

pub fn sessionFocusOrOpenFindsOrAddsTabTest(io: std.Io, alloc: std.mem.Allocator) !void {
    var s = try Scratch.init(io, alloc, "session-focus");
    defer s.deinit();
    try s.mkdir("a");
    try s.mkdir("b");
    try s.mkdir("c");
    const a = try s.abs("a");
    defer alloc.free(a);
    const b = try s.abs("b");
    defer alloc.free(b);
    const c = try s.abs("c");
    defer alloc.free(c);

    // Restored as a | [b] | c, b shown.
    var three = [_]session.Tab{ .{ .path = a }, .{ .path = b }, .{ .path = c } };
    var r = (try session.openSide(alloc, io, &.{ .tabs = &three, .active = 1 })) orelse return error.TestUnexpectedResult;
    defer r.deinit(alloc);

    // A directory already open is shown, nothing added.
    try r.focusOrOpen(alloc, io, a, .{});
    try testz.expectEqual(r.set.count(), 3);
    try testz.expectEqual(r.set.active, 0);
    try testz.expectEqualStr(r.shown.path, a);

    // The same directory spelled with a trailing `/.` still matches.
    const c_dot = try std.fmt.allocPrint(alloc, "{s}/.", .{c});
    defer alloc.free(c_dot);
    try r.focusOrOpen(alloc, io, c_dot, .{});
    try testz.expectEqual(r.set.count(), 3);
    try testz.expectEqual(r.set.active, 2);

    // One not open becomes a new tab right after the shown one, with
    // the options given.
    try r.focusOrOpen(alloc, io, a, .{});
    try r.focusOrOpen(alloc, io, s.path, .{ .view = .large });
    try testz.expectEqual(r.set.count(), 4);
    try testz.expectEqual(r.set.active, 1);
    try testz.expectEqualStr(r.shown.path, s.path);
    try testz.expectTrue(r.shown.view == .large);
    try testz.expectEqualStr(r.set.at(&r.shown, 0).path, a);
    try testz.expectEqualStr(r.set.at(&r.shown, 2).path, b);
}

pub fn sessionParseRefusesOtherShapesTest(_: std.Io, alloc: std.mem.Allocator) !void {
    for ([_][]const u8{
        "",
        "[]",
        "{\"version\": 2, \"sides\": [{}, {}]}",
        "{\"version\": 1, \"sides\": [{}]}",
        "{\"version\": 1, \"sides\": [{\"tabs\": [{\"path\": \"/\", \"view\": \"huge\"}]}, {}]}",
    }) |json| {
        if (session.parse(alloc, json)) |l| {
            var owned = l;
            owned.deinit();
            return error.TestUnexpectedResult;
        }
    }
    // A field from a later version is passed over.
    var ok = session.parse(alloc, "{\"version\": 1, \"active\": 1, \"sides\": [{}, {\"tabs\": [{\"path\": \"/\", \"future\": 3}]}]}") orelse return error.TestUnexpectedResult;
    defer ok.deinit();
    try testz.expectEqual(ok.session().sides[1].tabs.len, 1);
}
