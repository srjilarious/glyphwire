// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: GPL-3.0-or-later

//! The file-tree model behind zoe's sidebar: a directory walked lazily,
//! flattened into the rows the pane draws.
//!
//! The flattening is the whole trick. A tree is a nested thing, but a
//! layer is a grid of rows, and a *viewport* over that grid is what the
//! host scrolls (see `core.PropertyName.viewport`). So the tree keeps one
//! flat, ordered list of visible entries -- expanding a directory splices
//! its children in after it, collapsing removes the run that follows --
//! and the pane is then just "write row `i` of this list at row `i`".
//! Scrolling costs nothing on this side because the host owns it.
//!
//! Directory reads happen here, so this is the one part of zoe's core
//! that touches the filesystem. Everything the *rendering* needs
//! (`row`, `widestCols`) is pure, which is what `tests/zoe_tests.zig`
//! exercises.
//!
//! The pane's two searches are both served from here. `f` walks the
//! flattened list (`rowStartingWith`) -- the rows already on screen. `/`
//! walks a `DeepList`, every path under the root whether its folder is
//! open or not, and `reveal` then opens whatever it takes for the hit to
//! become a row the cursor can sit on.

const std = @import("std");
const glyphwire = @import("glyphwire");
const gitignore = @import("shell_support").gitignore;

/// What a listing or a walk is allowed to show. Lives with the ignore
/// matcher it consults, in `shell_support`, so salacommander's F3 finder
/// applies the same rule the sidebar does.
pub const Visibility = gitignore.Visibility;

/// Cells of indent per nesting level.
pub const indent_cols: usize = 2;

/// Columns reserved before the name for the entry's icon plus a gap. The
/// icon renders at its natural size capped to the row height (like
/// `glyphwire-ls`'s small-table icons), which is wider than one cell, so
/// this leaves it room without the first letter of the name tucking
/// under it.
pub const icon_cols: usize = 3;

pub const Entry = struct {
    /// The final path component, owned.
    name: []u8,
    /// The full path, owned -- what `:e` and a click both need.
    path: []u8,
    is_dir: bool,
    depth: usize,
    /// Directories only; always false for a file.
    expanded: bool = false,
    /// A dotfile, or excluded by a `.gitignore` -- so it is only on screen
    /// because Ctrl+H is on, and the pane draws it dim. Always computed,
    /// whether or not hidden entries are being shown, so the listing knows
    /// *why* each row is there.
    hidden: bool = false,

    /// Columns this row occupies when drawn.
    pub fn cols(self: Entry) usize {
        return self.depth * indent_cols + icon_cols + glyphwire.stringWidth(self.name);
    }
};

pub const Tree = struct {
    alloc: std.mem.Allocator,
    /// The directory the tree is rooted at, owned.
    root: []u8,
    /// Visible entries in draw order -- see the flattening note above.
    entries: std.ArrayList(Entry) = .empty,
    /// The highlighted row, in `entries` indices.
    cursor: usize = 0,
    /// What the listing is allowed to show. Changing it needs a `reload`
    /// -- the entries are the answer to this question, not a view of it.
    visible: Visibility = .{},

    pub fn init(alloc: std.mem.Allocator, io: std.Io, root: []const u8, visible: Visibility) !Tree {
        var self: Tree = .{ .alloc = alloc, .root = try alloc.dupe(u8, root), .visible = visible };
        errdefer alloc.free(self.root);
        try self.readInto(io, self.root, "", 0, 0);
        return self;
    }

    /// Re-reads the whole tree under the current `visible`, putting back
    /// the directories that were open and the row the cursor was on.
    ///
    /// What Ctrl+H runs. A rebuild rather than a filter because the
    /// flattened list *is* the listing: there is no hidden row to reveal,
    /// the row was never read. Restoring by path rather than by index is
    /// the point -- the indices all move when a hidden sibling appears
    /// above them.
    pub fn reload(self: *Tree, io: std.Io) !void {
        var open: std.ArrayList([]u8) = .empty;
        defer {
            for (open.items) |p| self.alloc.free(p);
            open.deinit(self.alloc);
        }
        // In tree order, so a parent is always restored before its child
        // -- though `reveal` would open the ancestors anyway.
        for (self.entries.items) |e| {
            if (!e.is_dir or !e.expanded) continue;
            try open.append(self.alloc, try self.alloc.dupe(u8, relOf(self.root, e.path)));
        }
        const on: ?[]u8 = if (self.at(self.cursor)) |e|
            try self.alloc.dupe(u8, relOf(self.root, e.path))
        else
            null;
        defer if (on) |p| self.alloc.free(p);

        self.clearEntries();
        try self.readInto(io, self.root, "", 0, 0);

        for (open.items) |rel| {
            const index = (try self.reveal(io, rel)) orelse continue;
            const e = self.entries.items[index];
            if (e.is_dir and !e.expanded) try self.toggle(io, index);
        }
        // The cursor's own row may itself have been hidden, in which case
        // there is nothing to go back to and it stays where it lands.
        if (on) |rel| {
            if (try self.reveal(io, rel)) |index| self.cursor = index;
        }
        if (self.cursor >= self.entries.items.len) self.cursor = self.entries.items.len -| 1;
    }

    fn clearEntries(self: *Tree) void {
        for (self.entries.items) |e| {
            self.alloc.free(e.name);
            self.alloc.free(e.path);
        }
        self.entries.clearRetainingCapacity();
    }

    /// `path` relative to `root`, `/` separated. Every entry's `path` was
    /// built by joining onto the root, so this is a slice rather than a
    /// computation; a path that somehow isn't under the root comes back
    /// whole, which matches nothing and hides nothing.
    fn relOf(root: []const u8, path: []const u8) []const u8 {
        if (path.len <= root.len or !std.mem.startsWith(u8, path, root)) return path;
        const rest = path[root.len..];
        return if (rest[0] == '/') rest[1..] else rest;
    }

    pub fn deinit(self: *Tree) void {
        for (self.entries.items) |e| {
            self.alloc.free(e.name);
            self.alloc.free(e.path);
        }
        self.entries.deinit(self.alloc);
        self.alloc.free(self.root);
        self.* = undefined;
    }

    pub fn len(self: *const Tree) usize {
        return self.entries.items.len;
    }

    pub fn at(self: *const Tree, index: usize) ?Entry {
        if (index >= self.entries.items.len) return null;
        return self.entries.items[index];
    }

    /// The widest row, in cells -- the tree pane's content width, and so
    /// what decides whether it needs a horizontal scrollbar.
    pub fn widestCols(self: *const Tree) usize {
        var widest: usize = 1;
        for (self.entries.items) |e| widest = @max(widest, e.cols());
        return widest;
    }

    /// Expands a collapsed directory or collapses an expanded one. A file
    /// is a no-op, so callers can hand this whatever the cursor is on.
    pub fn toggle(self: *Tree, io: std.Io, index: usize) !void {
        if (index >= self.entries.items.len) return;
        if (!self.entries.items[index].is_dir) return;

        if (self.entries.items[index].expanded) {
            self.collapse(index);
        } else {
            const e = self.entries.items[index];
            try self.readInto(io, e.path, relOf(self.root, e.path), e.depth + 1, index + 1);
            self.entries.items[index].expanded = true;
        }
    }

    /// Removes the run of entries nested under `index` -- everything
    /// after it that is deeper than it, which by construction is exactly
    /// its subtree.
    fn collapse(self: *Tree, index: usize) void {
        const end = self.subtreeEnd(index);

        for (self.entries.items[index + 1 .. end]) |e| {
            self.alloc.free(e.name);
            self.alloc.free(e.path);
        }
        self.entries.replaceRange(self.alloc, index + 1, end - index - 1, &.{}) catch {};
        self.entries.items[index].expanded = false;
        if (self.cursor >= self.entries.items.len) self.cursor = self.entries.items.len -| 1;
    }

    /// Reads `dir` and splices its entries in at `insert_at`, directories
    /// first then files, each group alphabetical -- the order every file
    /// browser uses. A directory that can't be read leaves the tree
    /// unchanged rather than failing the whole operation: an unreadable
    /// folder should render as an empty one, not take the editor down.
    ///
    /// `rel_dir` is `dir` relative to the root, and is what the
    /// `.gitignore` files in scope are matched against.
    fn readInto(self: *Tree, io: std.Io, dir: []const u8, rel_dir: []const u8, depth: usize, insert_at: usize) !void {
        var listing: std.ArrayList(Entry) = .empty;
        defer listing.deinit(self.alloc);
        errdefer for (listing.items) |e| {
            self.alloc.free(e.name);
            self.alloc.free(e.path);
        };

        // Every ignore file from the root down to this directory. Expanding
        // a folder re-reads the chain rather than keeping one alive across
        // the session: it is a handful of small files, and a stack held
        // between expansions would have to be invalidated by every edit to
        // any `.gitignore` in the tree.
        // Read even when hidden entries are being *shown*: the chain is
        // what says which of them are hidden, and the pane draws those
        // dim rather than just listing them.
        var ignores: gitignore.Stack = .{ .alloc = self.alloc };
        defer ignores.deinit();
        try self.pushIgnoreChain(io, &ignores, rel_dir);

        var handle = std.Io.Dir.cwd().openDir(io, dir, .{ .iterate = true }) catch return;
        defer handle.close(io);

        var it = handle.iterate();
        while (it.next(io) catch null) |raw| {
            const is_dir = raw.kind == .directory;
            const path = try std.fs.path.join(self.alloc, &.{ dir, raw.name });
            errdefer self.alloc.free(path);

            const hidden = self.visible.isHidden(&ignores, raw.name, relOf(self.root, path), is_dir);
            if (self.visible.skips(hidden)) {
                self.alloc.free(path);
                continue;
            }

            const name = try self.alloc.dupe(u8, raw.name);
            errdefer self.alloc.free(name);

            try listing.append(self.alloc, .{
                .name = name,
                .path = path,
                .is_dir = is_dir,
                .depth = depth,
                .hidden = hidden,
            });
        }

        std.mem.sort(Entry, listing.items, {}, lessThan);
        try self.entries.insertSlice(self.alloc, @min(insert_at, self.entries.items.len), listing.items);
        listing.clearRetainingCapacity();
    }

    /// Directories first, then case-insensitively by name -- so
    /// `Downloads` and `downloads` sit next to each other rather than in
    /// two blocks with every capitalised name in between, which is what a
    /// raw byte compare gives. Names that are equal ignoring case fall
    /// back to the byte order, so the sort stays total and two files
    /// differing only in case keep a repeatable order.
    fn lessThan(_: void, a: Entry, b: Entry) bool {
        if (a.is_dir != b.is_dir) return a.is_dir;
        return switch (std.ascii.orderIgnoreCase(a.name, b.name)) {
            .lt => true,
            .gt => false,
            .eq => std.mem.lessThan(u8, a.name, b.name),
        };
    }

    // ── Type to find ────────────────────────────────────────────────────

    /// The first visible entry at or after `from` whose name starts with
    /// `prefix`, case-insensitively, wrapping back to the top so the
    /// search always covers the whole listing. Null when nothing matches.
    ///
    /// Pure, and the whole of what the tree pane's `f` search needs: the
    /// flattened list *is* what is on screen, so "the next match" is just
    /// the next index.
    pub fn rowStartingWith(self: *const Tree, prefix: []const u8, from: usize) ?usize {
        const n = self.entries.items.len;
        if (n == 0 or prefix.len == 0) return null;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const index = (from + i) % n;
            if (std.ascii.startsWithIgnoreCase(self.entries.items[index].name, prefix)) return index;
        }
        return null;
    }

    /// One past the last entry nested under `index` -- the end of the run
    /// `collapse` removes.
    pub fn subtreeEnd(self: *const Tree, index: usize) usize {
        const depth = self.entries.items[index].depth;
        var end = index + 1;
        while (end < self.entries.items.len and self.entries.items[end].depth > depth) end += 1;
        return end;
    }

    /// Expands whatever it takes for `rel` -- a path relative to the tree
    /// root, `/`-separated -- to be a visible row, and returns its index.
    /// Null if any component is missing: the tree is a snapshot and the
    /// deep listing behind a `/` search is another one, so they can
    /// disagree about a file that has just been removed.
    ///
    /// This is what lets a `/` search land on a file inside a folder that
    /// was never opened: the search finds the path, this turns it into a
    /// row. The expansion stays afterwards -- the row has to remain
    /// visible for the cursor to be on it.
    pub fn reveal(self: *Tree, io: std.Io, rel: []const u8) !?usize {
        // The window of entries the next component must be found in:
        // first the whole listing, then the children of whatever the
        // previous component resolved to.
        var lo: usize = 0;
        var hi: usize = self.entries.items.len;
        var depth: usize = 0;
        var found: ?usize = null;

        var it = std.mem.splitScalar(u8, rel, '/');
        while (it.next()) |seg| {
            if (seg.len == 0) continue;
            const index = self.indexOfName(seg, depth, lo, hi) orelse return null;
            found = index;
            if (it.rest().len == 0) break;

            // More components to go, so this one has to be a directory,
            // and open before its children exist as rows at all.
            if (!self.entries.items[index].is_dir) return null;
            if (!self.entries.items[index].expanded) try self.toggle(io, index);
            lo = index + 1;
            hi = self.subtreeEnd(index);
            depth += 1;
        }
        return found;
    }

    /// Pushes the `.gitignore` of the root and of every directory on the
    /// way down to `rel_dir`, outermost first -- the order `Stack.match`
    /// resolves in.
    fn pushIgnoreChain(self: *Tree, io: std.Io, stack: *gitignore.Stack, rel_dir: []const u8) !void {
        _ = try stack.pushDir(io, self.root, "");
        if (rel_dir.len == 0) return;

        var i: usize = 0;
        while (true) {
            const end = std.mem.indexOfScalarPos(u8, rel_dir, i, '/') orelse rel_dir.len;
            const prefix = rel_dir[0..end];
            const abs = try std.fs.path.join(self.alloc, &.{ self.root, prefix });
            defer self.alloc.free(abs);
            _ = try stack.pushDir(io, abs, prefix);
            if (end == rel_dir.len) return;
            i = end + 1;
        }
    }

    fn indexOfName(self: *const Tree, name: []const u8, depth: usize, lo: usize, hi: usize) ?usize {
        var i = lo;
        const end = @min(hi, self.entries.items.len);
        while (i < end) : (i += 1) {
            const e = self.entries.items[i];
            if (e.depth == depth and std.mem.eql(u8, e.name, name)) return i;
        }
        return null;
    }
};

// ── Deep listing ────────────────────────────────────────────────────────

/// The walk behind a `/` search stops after this many entries: generous
/// enough for a real source tree, and a bound on a root that turns out to
/// be `/`. Deliberately the same shape of guard `zoe/finder.zig` puts on
/// the Ctrl+P scan.
pub const deep_max_entries: usize = 20_000;

/// How deep that walk goes -- a guard against a pathological tree rather
/// than a limit a source tree should reach.
pub const deep_max_depth: usize = 16;

/// Every path under the tree root, whether or not its folder is open:
/// what a `/` search matches against, and what `Tree.reveal` is handed to
/// turn a hit into a row.
///
/// Read once when the search starts and thrown away when it ends, for the
/// reason the Ctrl+P finder rescans on every open: a listing that stayed
/// live would need a directory watcher to stay honest.
pub const DeepList = struct {
    alloc: std.mem.Allocator,
    /// Paths relative to the root, `/`-separated, owned. Sorted
    /// case-insensitively, which inside one directory is the tree's own
    /// order; a directory still sits immediately before its children,
    /// since its path is a prefix of theirs.
    paths: std.ArrayList([]u8) = .empty,
    /// The walk hit `deep_max_entries` and stopped early, so the listing
    /// is a prefix of the tree rather than the whole of it.
    truncated: bool = false,
    /// What the walk was allowed to collect -- the same flag the tree
    /// listing was built under, so a `/` hit always has a row to land on.
    visible: Visibility = .{},

    pub fn deinit(self: *DeepList) void {
        for (self.paths.items) |p| self.alloc.free(p);
        self.paths.deinit(self.alloc);
        self.* = undefined;
    }

    /// The final component of `paths[index]` -- what a query is matched
    /// against, since what is being typed is a name and not a path.
    pub fn nameAt(self: *const DeepList, index: usize) []const u8 {
        const p = self.paths.items[index];
        const slash = std.mem.lastIndexOfScalar(u8, p, '/') orelse return p;
        return p[slash + 1 ..];
    }

    /// Adds one path relative to the root. `deepScan` is the only caller
    /// in the program; tests use it to build a listing directly.
    pub fn addPath(self: *DeepList, rel: []const u8) !void {
        const owned = try self.alloc.dupe(u8, rel);
        errdefer self.alloc.free(owned);
        try self.paths.append(self.alloc, owned);
    }
};

/// Walks `root` and collects every path under it. Directories are listed
/// too, so a `/` search can land on a folder; one that can't be read is
/// skipped rather than failing the walk, the rule the rest of the tree
/// uses.
pub fn deepList(alloc: std.mem.Allocator, io: std.Io, root: []const u8, visible: Visibility) !DeepList {
    var self: DeepList = .{ .alloc = alloc, .visible = visible };
    errdefer self.deinit();

    // Unlike the tree's own reads, this walk descends, so it pushes each
    // directory's ignore file on the way in and pops it on the way out
    // rather than re-reading the chain per directory.
    var ignores: gitignore.Stack = .{ .alloc = alloc };
    defer ignores.deinit();
    try deepScan(&self, io, &ignores, root, "", 0);

    std.mem.sort([]u8, self.paths.items, {}, lessThanPath);
    return self;
}

fn lessThanPath(_: void, a: []u8, b: []u8) bool {
    return switch (std.ascii.orderIgnoreCase(a, b)) {
        .lt => true,
        .gt => false,
        .eq => std.mem.lessThan(u8, a, b),
    };
}

fn deepScan(
    self: *DeepList,
    io: std.Io,
    ignores: *gitignore.Stack,
    dir: []const u8,
    rel: []const u8,
    depth: usize,
) !void {
    if (depth >= deep_max_depth) return;

    const pushed = try ignores.pushDir(io, dir, rel);
    defer if (pushed) ignores.pop();

    var handle = std.Io.Dir.cwd().openDir(io, dir, .{ .iterate = true }) catch return;
    defer handle.close(io);

    var it = handle.iterate();
    while (it.next(io) catch null) |raw| {
        if (self.paths.items.len >= deep_max_entries) {
            self.truncated = true;
            return;
        }

        const child_rel = if (rel.len == 0)
            try self.alloc.dupe(u8, raw.name)
        else
            try std.fmt.allocPrint(self.alloc, "{s}/{s}", .{ rel, raw.name });
        errdefer self.alloc.free(child_rel);

        // Skipped here for the reason they are skipped in the listing: a
        // `/` search that landed on a row the tree will never show would
        // have nowhere to put the cursor. An ignored *directory* is not
        // descended into either, which is what keeps `zig-cache/` from
        // costing the walk anything.
        const hidden = self.visible.isHidden(ignores, raw.name, child_rel, raw.kind == .directory);
        if (self.visible.skips(hidden)) {
            self.alloc.free(child_rel);
            continue;
        }
        try self.paths.append(self.alloc, child_rel);

        // Only a real directory is descended into: a symlink reports as
        // `.sym_link` whatever it points at, so it is never followed and
        // a link back up the tree can't turn the walk into a loop.
        if (raw.kind == .directory) {
            const child_dir = try std.fs.path.join(self.alloc, &.{ dir, raw.name });
            defer self.alloc.free(child_dir);
            try deepScan(self, io, ignores, child_dir, child_rel, depth + 1);
        }
    }
}
