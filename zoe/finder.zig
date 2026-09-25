// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: GPL-3.0-or-later

//! The model behind zoe's Ctrl+P file finder: every file under the tree
//! root, the query typed against it, and the ranked subset that answers.
//!
//! The listing is read **once**, when the popup opens, and thrown away
//! when it closes. A finder that stayed live would need a directory
//! watcher to stay honest, and a stale list is worse than a re-walk that
//! costs a few milliseconds on the repositories zoe is used on. Reopening
//! is therefore also how you pick up a file that appeared since.
//!
//! Matching is `shell_support.fuzzy`, the same subsequence matcher
//! `gw-hist`'s Ctrl+R search uses -- there is no reason for zoe to rank
//! differently from the shell, and one matcher is one set of surprises.
//! Ranking is over the whole path relative to the root, so `zoeui`
//! finds `zoe/ui.zig`.
//!
//! Everything here is pure apart from `scan`, so `tests/zoe_tests.zig`
//! can build a finder out of `addPath` calls and exercise the ranking and
//! the cursor without touching a filesystem.

const std = @import("std");
const glyphwire = @import("glyphwire");
const fuzzy = @import("shell_support").fuzzy;

/// The walk stops after this many files and says so (`truncated`), rather
/// than spending an unbounded amount of time and memory on a root that
/// turns out to be `/`. Generous enough that a real repository fits:
/// glyphwire itself is a few thousand files.
pub const max_files: usize = 20_000;

/// How deep the walk goes. A guard against a pathological tree rather
/// than a limit anyone should hit -- source trees are not this deep.
pub const max_depth: usize = 16;

/// A match: the index of the path in `paths`, plus what it scored, kept
/// so the sort doesn't re-run the matcher on every comparison.
pub const Match = struct {
    index: usize,
    score: usize,
};

pub const Finder = struct {
    alloc: std.mem.Allocator,
    /// The directory the walk started from, owned. Paths are stored
    /// relative to it and joined back onto it to open.
    root: []u8,
    /// Every file found, relative to `root`, owned, alphabetical.
    paths: std.ArrayList([]u8) = .empty,
    /// The current answer: indices into `paths`, best first.
    matches: std.ArrayList(Match) = .empty,
    query: glyphwire.LineEdit = .empty,
    /// The highlighted row, in `matches` indices.
    cursor: usize = 0,
    /// The first match drawn in the list's row 0 -- the popup's own
    /// scroll, mirrored to the host as a `scroll_offset`.
    top: usize = 0,
    /// The walk hit `max_files` and stopped early, so the list is a
    /// prefix of the tree rather than the whole of it. Shown in the
    /// header: a finder that silently can't see half your files is worse
    /// than one that admits it.
    truncated: bool = false,

    /// Walks `root` and builds the listing. A directory that can't be
    /// read is skipped rather than failing the whole scan, the same rule
    /// the file tree uses -- an unreadable folder should read as an empty
    /// one, not stop the finder opening.
    pub fn init(alloc: std.mem.Allocator, io: std.Io, root: []const u8) !Finder {
        var self: Finder = .{ .alloc = alloc, .root = try alloc.dupe(u8, root) };
        errdefer self.deinit();
        try self.scan(io, self.root, "", 0);
        self.sortPaths();
        try self.refilter();
        return self;
    }

    /// The walk returns entries in whatever order the filesystem hands
    /// them over, which is neither stable nor meaningful. Sorting once
    /// after it is what makes an empty query show the tree in a sensible
    /// order -- and `refilter` then leaves that order alone.
    pub fn sortPaths(self: *Finder) void {
        std.mem.sort([]u8, self.paths.items, {}, lessThanPath);
    }

    pub fn deinit(self: *Finder) void {
        for (self.paths.items) |p| self.alloc.free(p);
        self.paths.deinit(self.alloc);
        self.matches.deinit(self.alloc);
        self.query.deinit(self.alloc);
        self.alloc.free(self.root);
        self.* = undefined;
    }

    fn lessThanPath(_: void, a: []u8, b: []u8) bool {
        return std.mem.lessThan(u8, a, b);
    }

    /// Adds one path, relative to the root. `scan` is the only caller in
    /// the program; tests use it to build a listing directly.
    pub fn addPath(self: *Finder, rel: []const u8) !void {
        const owned = try self.alloc.dupe(u8, rel);
        errdefer self.alloc.free(owned);
        try self.paths.append(self.alloc, owned);
    }

    fn scan(self: *Finder, io: std.Io, dir: []const u8, rel: []const u8, depth: usize) !void {
        if (depth >= max_depth) return;

        var handle = std.Io.Dir.cwd().openDir(io, dir, .{ .iterate = true }) catch return;
        defer handle.close(io);

        var it = handle.iterate();
        while (it.next(io) catch null) |raw| {
            if (self.paths.items.len >= max_files) {
                self.truncated = true;
                return;
            }
            // Dotfiles are hidden, the same rule the tree pane uses --
            // which is also what keeps `.git/` out of the listing without
            // the finder having to know what git is.
            if (raw.name.len > 0 and raw.name[0] == '.') continue;

            const child_rel = if (rel.len == 0)
                try self.alloc.dupe(u8, raw.name)
            else
                try std.fs.path.join(self.alloc, &.{ rel, raw.name });

            // Only a real directory is descended into. A symlink reports
            // as `.sym_link` whatever it points at, so it is listed as a
            // file and never followed -- which is also how a link back up
            // the tree can't turn the walk into a loop.
            if (raw.kind == .directory) {
                defer self.alloc.free(child_rel);
                const child_dir = try std.fs.path.join(self.alloc, &.{ dir, raw.name });
                defer self.alloc.free(child_dir);
                try self.scan(io, child_dir, child_rel, depth + 1);
            } else {
                errdefer self.alloc.free(child_rel);
                try self.paths.append(self.alloc, child_rel);
            }
        }
    }

    /// Rebuilds `matches` for the current query and puts the cursor back
    /// on the best one. An empty query matches everything and keeps the
    /// listing's own alphabetical order: there is nothing to rank by, and
    /// shuffling the tree into some other order the moment the popup
    /// opens would be noise.
    pub fn refilter(self: *Finder) !void {
        const q = self.query.text();
        self.matches.clearRetainingCapacity();
        for (self.paths.items, 0..) |p, i| {
            const s = fuzzy.score(p, q) orelse continue;
            try self.matches.append(self.alloc, .{ .index = i, .score = s });
        }
        if (q.len > 0) std.mem.sort(Match, self.matches.items, self, lessThanMatch);
        self.cursor = 0;
        self.top = 0;
    }

    /// Tighter match first; then the shorter path, so a file near the
    /// root beats the same name buried under four directories; then
    /// alphabetically, so the order never depends on the walk.
    fn lessThanMatch(self: *const Finder, a: Match, b: Match) bool {
        if (a.score != b.score) return a.score < b.score;
        const pa = self.paths.items[a.index];
        const pb = self.paths.items[b.index];
        if (pa.len != pb.len) return pa.len < pb.len;
        return std.mem.lessThan(u8, pa, pb);
    }

    pub fn matchCount(self: *const Finder) usize {
        return self.matches.items.len;
    }

    /// The path at `row` of the current answer, relative to the root.
    pub fn matchAt(self: *const Finder, row: usize) ?[]const u8 {
        if (row >= self.matches.items.len) return null;
        return self.paths.items[self.matches.items[row].index];
    }

    /// The highlighted path, relative to the root.
    pub fn selected(self: *const Finder) ?[]const u8 {
        return self.matchAt(self.cursor);
    }

    /// The highlighted path as the caller should open it: joined onto the
    /// root, so it names the same file the tree pane would have named and
    /// lands in the same tab rather than a second one under a different
    /// spelling. Caller owns the result.
    pub fn selectedPath(self: *const Finder, alloc: std.mem.Allocator) !?[]u8 {
        const rel = self.selected() orelse return null;
        return try std.fs.path.join(alloc, &.{ self.root, rel });
    }

    /// Moves the cursor `delta` rows, clamped at both ends. Clamped
    /// rather than wrapping: a finder's list is ranked, so running off
    /// the top of it back to the worst match is never what was meant.
    pub fn moveCursor(self: *Finder, delta: isize) void {
        const n = self.matches.items.len;
        if (n == 0) {
            self.cursor = 0;
            return;
        }
        if (delta < 0) {
            self.cursor -|= @intCast(-delta);
        } else {
            self.cursor = @min(self.cursor + @as(usize, @intCast(delta)), n - 1);
        }
    }

    /// Keeps `top` covering the cursor for a list `rows` tall, and pulls
    /// it back off the end when the answer shrank under it.
    pub fn follow(self: *Finder, rows: usize) void {
        if (rows == 0 or self.matches.items.len == 0) {
            self.top = 0;
            return;
        }
        if (self.cursor < self.top) self.top = self.cursor;
        if (self.cursor >= self.top + rows) self.top = self.cursor - rows + 1;
        self.top = @min(self.top, self.matches.items.len -| rows);
    }

    /// Follows a host-side scroll (the wheel, a scrollbar drag) without
    /// moving the cursor -- scrolling past a row and picking it are two
    /// different gestures, the same split `gw-hist` makes.
    pub fn scrollTo(self: *Finder, row: usize, rows: usize) void {
        self.top = row;
        self.clampScroll(rows);
    }

    /// Pulls `top` back inside a list `rows` tall: the popup got shorter,
    /// or the answer did. Distinct from `follow`, which also drags the
    /// view onto the cursor -- doing that every frame would undo a wheel
    /// scroll the moment it was drawn.
    pub fn clampScroll(self: *Finder, rows: usize) void {
        self.top = @min(self.top, self.matches.items.len -| rows);
    }
};
