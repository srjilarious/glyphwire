// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: MPL-2.0

//! The model behind zoe's Ctrl+P file finder and salacommander's F3
//! search: every file under a root, the query typed against it, and the
//! ranked subset that answers. It lives in `applib` rather than
//! either program so the two rank and hide paths identically; the popup
//! each one draws around it is its own.
//!
//! The listing is read **once**, when the popup opens, and thrown away
//! when it closes. A finder that stayed live would need a directory
//! watcher to stay honest, and a stale list is worse than a re-walk that
//! costs a few milliseconds on the repositories zoe is used on. Reopening
//! is therefore also how you pick up a file that appeared since.
//!
//! Matching is `applib.fuzzy`, the same subsequence matcher
//! `gw-hist`'s Ctrl+R search uses -- there is no reason for zoe to rank
//! differently from the shell, and one matcher is one set of surprises.
//! Ranking is over the whole path relative to the root, so `zoeui`
//! finds `zoe/ui.zig`.
//!
//! Directories are left out unless `Options.include_dirs` says otherwise:
//! an editor opens files, but a file manager's search is as often after a
//! folder. A listed directory carries a trailing `/`, which is what tells
//! the two apart in the popup and in `selected`.
//!
//! Everything here is pure apart from `scan`, so `tests/zoe_tests.zig`
//! can build a finder out of `addPath` calls and exercise the ranking and
//! the cursor without touching a filesystem.

const std = @import("std");
const fuzzy = @import("fuzzy.zig");
const gitignore = @import("gitignore.zig");
const lineedit = @import("lineedit.zig");

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

pub const Options = struct {
    /// Which paths the walk may collect -- the caller's own hidden-file
    /// flag, so the popup and the listing behind it agree about which
    /// files exist.
    visible: gitignore.Visibility = .{},
    /// List directories too, each with a trailing `/`. They are walked
    /// into either way.
    include_dirs: bool = false,
};

/// One folder of a multi-folder walk (`Finder.initRoots`).
pub const RootSpec = struct {
    path: []const u8,
    /// Prefixed onto every path found under `path`, so the list says
    /// which folder a hit is in and a query can name it.
    label: []const u8,
};

pub const Finder = struct {
    alloc: std.mem.Allocator,
    /// The directory the walk started from, owned. Paths are stored
    /// relative to it and joined back onto it to open. The first folder
    /// of a multi-folder walk.
    root: []u8,
    /// Every file found, relative to `root`, owned, alphabetical. In a
    /// multi-folder walk each is `<label>/<path under its folder>`.
    paths: std.ArrayList([]u8) = .empty,
    /// Multi-folder walks only (empty otherwise): every folder, owned,
    /// and parallel to `paths` the index of the one each path is under.
    /// Kept as an index rather than worked back out of the label, since
    /// two workspace folders can share a name.
    roots: std.ArrayList(Root) = .empty,
    root_of: std.ArrayList(usize) = .empty,
    /// The current answer: indices into `paths`, best first.
    matches: std.ArrayList(Match) = .empty,
    query: lineedit.LineEdit = .empty,
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
    /// What the walk was allowed to collect. See `Options`.
    opts: Options = .{},

    pub const Root = struct {
        path: []u8,
        label: []u8,
    };

    /// Walks `root` and builds the listing. A directory that can't be
    /// read is skipped rather than failing the whole scan, the same rule
    /// the file tree uses -- an unreadable folder should read as an empty
    /// one, not stop the finder opening.
    pub fn init(alloc: std.mem.Allocator, io: std.Io, root: []const u8, opts: Options) !Finder {
        var self: Finder = .{ .alloc = alloc, .root = try alloc.dupe(u8, root), .opts = opts };
        errdefer self.deinit();

        // Pushed on the way into each directory and popped on the way out,
        // so a nested `.gitignore` is in scope for exactly its own subtree.
        var ignores: gitignore.Stack = .{ .alloc = alloc };
        defer ignores.deinit();
        try self.scan(io, &ignores, self.root, "", 0);

        self.sortPaths();
        try self.refilter();
        return self;
    }

    /// Walks several folders into one list, each path prefixed with its
    /// folder's label -- zoe's Ctrl+P over a workspace. One folder is
    /// exactly `init`, with no prefix.
    pub fn initRoots(alloc: std.mem.Allocator, io: std.Io, specs: []const RootSpec, opts: Options) !Finder {
        std.debug.assert(specs.len > 0);
        if (specs.len == 1) return init(alloc, io, specs[0].path, opts);

        var self: Finder = .{ .alloc = alloc, .root = try alloc.dupe(u8, specs[0].path), .opts = opts };
        errdefer self.deinit();
        for (specs, 0..) |spec, i| {
            const path = try alloc.dupe(u8, spec.path);
            errdefer alloc.free(path);
            const label = try alloc.dupe(u8, spec.label);
            errdefer alloc.free(label);
            try self.roots.append(alloc, .{ .path = path, .label = label });

            const start = self.paths.items.len;
            var ignores: gitignore.Stack = .{ .alloc = alloc };
            defer ignores.deinit();
            try self.scan(io, &ignores, spec.path, "", 0);

            // Prefixed after the walk rather than during it: the walk's
            // relative paths are what `.gitignore` patterns match.
            for (self.paths.items[start..]) |*p| {
                const labelled = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ spec.label, p.* });
                alloc.free(p.*);
                p.* = labelled;
            }
            try self.root_of.appendNTimes(alloc, i, self.paths.items.len - start);
            if (self.truncated) break;
        }

        self.sortPaths();
        try self.refilter();
        return self;
    }

    /// The walk returns entries in whatever order the filesystem hands
    /// them over, which is neither stable nor meaningful. Sorting once
    /// after it is what makes an empty query show the tree in a sensible
    /// order -- and `refilter` then leaves that order alone.
    pub fn sortPaths(self: *Finder) void {
        if (self.root_of.items.len == 0) {
            std.mem.sort([]u8, self.paths.items, {}, lessThanPath);
            return;
        }
        // Sorted grouped by folder, then by path: `root_of` has to move
        // with its path, and grouping keeps a workspace folder's files
        // together under an empty query even when labels sort otherwise.
        // Grouped already by construction, so each group sorts alone.
        var start: usize = 0;
        while (start < self.paths.items.len) {
            var end = start + 1;
            while (end < self.paths.items.len and self.root_of.items[end] == self.root_of.items[start]) end += 1;
            std.mem.sort([]u8, self.paths.items[start..end], {}, lessThanPath);
            start = end;
        }
    }

    pub fn deinit(self: *Finder) void {
        for (self.paths.items) |p| self.alloc.free(p);
        self.paths.deinit(self.alloc);
        for (self.roots.items) |r| {
            self.alloc.free(r.path);
            self.alloc.free(r.label);
        }
        self.roots.deinit(self.alloc);
        self.root_of.deinit(self.alloc);
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

    fn scan(self: *Finder, io: std.Io, ignores: *gitignore.Stack, dir: []const u8, rel: []const u8, depth: usize) !void {
        if (depth >= max_depth) return;

        const pushed = try ignores.pushDir(io, dir, rel);
        defer if (pushed) ignores.pop();

        var handle = std.Io.Dir.cwd().openDir(io, dir, .{ .iterate = true }) catch return;
        defer handle.close(io);

        var it = handle.iterate();
        while (it.next(io) catch null) |raw| {
            if (self.paths.items.len >= max_files) {
                self.truncated = true;
                return;
            }
            const child_rel = if (rel.len == 0)
                try self.alloc.dupe(u8, raw.name)
            else
                try std.fs.path.join(self.alloc, &.{ rel, raw.name });
            errdefer self.alloc.free(child_rel);

            // Dotfiles and `.gitignore`d paths are skipped, the same rule
            // the tree pane uses -- which is what keeps `.git/` out of the
            // listing without the finder having to know what git is, and
            // `zig-out/` out without it having to know what zig is. An
            // ignored directory is not walked either, which is most of
            // what makes this scan cheap on a tree that has been built.
            const hidden = self.opts.visible.isHidden(ignores, raw.name, child_rel, raw.kind == .directory);
            if (self.opts.visible.skips(hidden)) {
                self.alloc.free(child_rel);
                continue;
            }

            // Only a real directory is descended into. A symlink reports
            // as `.sym_link` whatever it points at, so it is listed as a
            // file and never followed -- which is also how a link back up
            // the tree can't turn the walk into a loop.
            if (raw.kind == .directory) {
                defer self.alloc.free(child_rel);
                if (self.opts.include_dirs) {
                    const listed = try std.fmt.allocPrint(self.alloc, "{s}/", .{child_rel});
                    errdefer self.alloc.free(listed);
                    try self.paths.append(self.alloc, listed);
                }
                const child_dir = try std.fs.path.join(self.alloc, &.{ dir, raw.name });
                defer self.alloc.free(child_dir);
                try self.scan(io, ignores, child_dir, child_rel, depth + 1);
            } else {
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
        if (self.cursor >= self.matches.items.len) return null;
        return try self.absPath(alloc, self.matches.items[self.cursor].index);
    }

    /// `paths[index]` joined back onto the folder it was found in, the
    /// label dropped. Caller owns the result.
    pub fn absPath(self: *const Finder, alloc: std.mem.Allocator, index: usize) ![]u8 {
        const p = self.paths.items[index];
        if (self.root_of.items.len == 0) return std.fs.path.join(alloc, &.{ self.root, p });
        const r = self.roots.items[self.root_of.items[index]];
        return std.fs.path.join(alloc, &.{ r.path, p[r.label.len + 1 ..] });
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
