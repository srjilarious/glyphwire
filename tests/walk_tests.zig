// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: GPL-3.0-or-later

//! `applib/walk.zig`, the `.gitignore`-aware walk behind the fuzzy finder
//! and zoe's `/` tree search.

const std = @import("std");
const testz = @import("testz");
const walk = @import("applib").walk;

/// A throwaway directory under the cwd, named per thread so parallel
/// runs don't share one.
const Scratch = struct {
    io: std.Io,
    alloc: std.mem.Allocator,
    path: []u8,

    fn init(io: std.Io, alloc: std.mem.Allocator) !Scratch {
        const path = try std.fmt.allocPrint(alloc, "walk-test-{d}", .{std.Thread.getCurrentId()});
        errdefer alloc.free(path);
        std.Io.Dir.cwd().deleteTree(io, path) catch {};
        try std.Io.Dir.cwd().createDirPath(io, path);
        return .{ .io = io, .alloc = alloc, .path = path };
    }

    fn deinit(self: *Scratch) void {
        std.Io.Dir.cwd().deleteTree(self.io, self.path) catch {};
        self.alloc.free(self.path);
    }

    fn file(self: *Scratch, name: []const u8, data: []const u8) !void {
        const p = try std.fs.path.join(self.alloc, &.{ self.path, name });
        defer self.alloc.free(p);
        if (std.fs.path.dirname(p)) |d| try std.Io.Dir.cwd().createDirPath(self.io, d);
        try std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = p, .data = data });
    }
};

/// Collects every reported path (dirs with a trailing `/`), stopping
/// after `cap`.
const Collector = struct {
    alloc: std.mem.Allocator,
    cap: usize = std.math.maxInt(usize),
    paths: std.ArrayList([]u8) = .empty,

    fn deinit(self: *Collector) void {
        for (self.paths.items) |p| self.alloc.free(p);
        self.paths.deinit(self.alloc);
    }

    fn add(self: *Collector, e: walk.Entry) !walk.Next {
        if (self.paths.items.len >= self.cap) return .stop;
        const p = if (e.kind == .directory)
            try std.fmt.allocPrint(self.alloc, "{s}/", .{e.rel})
        else
            try self.alloc.dupe(u8, e.rel);
        try self.paths.append(self.alloc, p);
        return .go;
    }

    fn has(self: *const Collector, want: []const u8) bool {
        for (self.paths.items) |p| if (std.mem.eql(u8, p, want)) return true;
        return false;
    }

    fn indexOf(self: *const Collector, want: []const u8) ?usize {
        for (self.paths.items, 0..) |p, i| if (std.mem.eql(u8, p, want)) return i;
        return null;
    }
};

pub fn walkSkipsHiddenAndIgnoredPathsTest(io: std.Io, alloc: std.mem.Allocator) !void {
    var s = try Scratch.init(io, alloc);
    defer s.deinit();
    try s.file(".gitignore", "build/\n*.log\n");
    try s.file("a.txt", "");
    try s.file("x.log", "");
    try s.file(".hidden", "");
    try s.file("build/out.bin", "");
    try s.file("src/main.zig", "");
    // A nested ignore file covers its own subtree only.
    try s.file("src/.gitignore", "gen.zig\n");
    try s.file("src/gen.zig", "");
    try s.file("docs/gen.zig", "");

    var c: Collector = .{ .alloc = alloc };
    defer c.deinit();
    const truncated = try walk.walk(alloc, io, s.path, .{}, &c, Collector.add);
    try testz.expectTrue(!truncated);

    try testz.expectTrue(c.has("a.txt"));
    try testz.expectTrue(c.has("src/"));
    try testz.expectTrue(c.has("src/main.zig"));
    try testz.expectTrue(c.has("docs/gen.zig"));
    try testz.expectTrue(!c.has("x.log"));
    try testz.expectTrue(!c.has(".hidden"));
    try testz.expectTrue(!c.has("build/"));
    try testz.expectTrue(!c.has("build/out.bin"));
    try testz.expectTrue(!c.has("src/gen.zig"));
    // A directory comes before what's in it.
    try testz.expectTrue(c.indexOf("src/").? < c.indexOf("src/main.zig").?);
}

pub fn walkShowsHiddenWhenAskedTest(io: std.Io, alloc: std.mem.Allocator) !void {
    var s = try Scratch.init(io, alloc);
    defer s.deinit();
    try s.file(".hidden", "");

    var c: Collector = .{ .alloc = alloc };
    defer c.deinit();
    _ = try walk.walk(alloc, io, s.path, .{ .visible = .{ .show_hidden = true } }, &c, Collector.add);
    try testz.expectTrue(c.has(".hidden"));
}

/// A callback's `.stop` ends the whole walk and is reported back.
pub fn walkStopsWhenTheCallbackSaysSoTest(io: std.Io, alloc: std.mem.Allocator) !void {
    var s = try Scratch.init(io, alloc);
    defer s.deinit();
    try s.file("a/1", "");
    try s.file("a/2", "");
    try s.file("b/3", "");

    var c: Collector = .{ .alloc = alloc, .cap = 2 };
    defer c.deinit();
    try testz.expectTrue(try walk.walk(alloc, io, s.path, .{}, &c, Collector.add));
    try testz.expectEqual(c.paths.items.len, 2);
}

pub fn walkStopsAtMaxDepthTest(io: std.Io, alloc: std.mem.Allocator) !void {
    var s = try Scratch.init(io, alloc);
    defer s.deinit();
    try s.file("a/b/c.txt", "");

    var c: Collector = .{ .alloc = alloc };
    defer c.deinit();
    _ = try walk.walk(alloc, io, s.path, .{ .max_depth = 2 }, &c, Collector.add);
    try testz.expectTrue(c.has("a/b/"));
    try testz.expectTrue(!c.has("a/b/c.txt"));
}

/// A root that can't be read is an empty walk, not an error.
pub fn walkOfAMissingRootIsEmptyTest(io: std.Io, alloc: std.mem.Allocator) !void {
    var c: Collector = .{ .alloc = alloc };
    defer c.deinit();
    try testz.expectTrue(!try walk.walk(alloc, io, "/nonexistent-walk-test-root", .{}, &c, Collector.add));
    try testz.expectEqual(c.paths.items.len, 0);
}
