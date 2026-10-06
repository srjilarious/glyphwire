// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: MPL-2.0

//! The one recursive, `.gitignore`-aware directory walk: the fuzzy
//! finder's listing (`finder.zig`, zoe's Ctrl+P and salacommander's F3)
//! and zoe's `/` tree search (`zoe/tree.zig`'s `DeepList`) both collect
//! from it and keep their own sort.
//!
//! Each directory's `.gitignore` is pushed on the way in and popped on
//! the way out, so a nested one is in scope for exactly its own subtree.
//! A path the caller's `Visibility` hides is skipped, and a hidden
//! directory is not walked either, which is most of what makes the walk
//! cheap on a tree that has been built (`zig-out/`, `.git/`). A directory
//! that can't be read is skipped rather than failing the walk: an
//! unreadable folder reads as an empty one.

const std = @import("std");
const gitignore = @import("gitignore.zig");

pub const Options = struct {
    /// Which paths the walk reports -- the caller's own hidden-file flag.
    visible: gitignore.Visibility = .{},
    /// How deep the walk goes. A guard against a pathological tree rather
    /// than a limit a source tree should reach.
    max_depth: usize = 16,
};

pub const Entry = struct {
    /// The path relative to the walk's root, `/`-separated. Borrowed:
    /// valid only for the callback, so copy it to keep it.
    rel: []const u8,
    kind: std.Io.File.Kind,
};

/// What a callback tells the walk to do next.
pub const Next = enum { go, stop };

/// Calls `onEntry(ctx, entry)` for every visible path under `root`,
/// depth first, a directory before its contents, in the order the
/// filesystem lists them (unsorted). Returns true when `onEntry` stopped
/// the walk early -- a caller's entry cap, so it can say the listing is
/// truncated.
///
/// Only a real directory is descended into. A symlink reports as
/// `.sym_link` whatever it points at, so it is reported but never
/// followed, which is also how a link back up the tree can't turn the
/// walk into a loop.
pub fn walk(
    alloc: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
    opts: Options,
    ctx: anytype,
    comptime onEntry: fn (@TypeOf(ctx), Entry) anyerror!Next,
) !bool {
    var ignores: gitignore.Stack = .{ .alloc = alloc };
    defer ignores.deinit();
    var w: Walker(@TypeOf(ctx), onEntry) = .{
        .alloc = alloc,
        .io = io,
        .opts = opts,
        .ctx = ctx,
        .ignores = &ignores,
    };
    defer w.dir.deinit(alloc);
    defer w.rel.deinit(alloc);
    try w.dir.appendSlice(alloc, root);
    return (try w.scan(0)) == .stop;
}

fn Walker(comptime Ctx: type, comptime onEntry: fn (Ctx, Entry) anyerror!Next) type {
    return struct {
        alloc: std.mem.Allocator,
        io: std.Io,
        opts: Options,
        ctx: Ctx,
        ignores: *gitignore.Stack,
        /// The directory being read, as the walk opens it (`root` joined
        /// with the path below it), grown and shrunk in place.
        dir: std.ArrayList(u8) = .empty,
        /// The same directory relative to the root: what `.gitignore`
        /// patterns match and what `Entry.rel` reports.
        rel: std.ArrayList(u8) = .empty,

        fn scan(self: *@This(), depth: usize) anyerror!Next {
            if (depth >= self.opts.max_depth) return .go;

            const pushed = try self.ignores.pushDir(self.io, self.dir.items, self.rel.items);
            defer if (pushed) self.ignores.pop();

            var handle = std.Io.Dir.cwd().openDir(self.io, self.dir.items, .{ .iterate = true }) catch return .go;
            defer handle.close(self.io);

            const dir_len = self.dir.items.len;
            const rel_len = self.rel.items.len;
            var it = handle.iterate();
            while (it.next(self.io) catch null) |raw| {
                defer {
                    self.dir.shrinkRetainingCapacity(dir_len);
                    self.rel.shrinkRetainingCapacity(rel_len);
                }
                if (rel_len > 0) try self.rel.append(self.alloc, '/');
                try self.rel.appendSlice(self.alloc, raw.name);

                const is_dir = raw.kind == .directory;
                const hidden = self.opts.visible.isHidden(self.ignores, raw.name, self.rel.items, is_dir);
                if (self.opts.visible.skips(hidden)) continue;

                if (try onEntry(self.ctx, .{ .rel = self.rel.items, .kind = raw.kind }) == .stop) return .stop;

                if (is_dir) {
                    if (dir_len > 0 and self.dir.items[dir_len - 1] != '/') try self.dir.append(self.alloc, '/');
                    try self.dir.appendSlice(self.alloc, raw.name);
                    if (try self.scan(depth + 1) == .stop) return .stop;
                }
            }
            return .go;
        }
    };
}
