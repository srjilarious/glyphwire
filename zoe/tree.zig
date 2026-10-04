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
//!
//! **Several roots.** A workspace (`zoe/workspace.zig`) puts more than one
//! folder in the sidebar. With one root the listing is that folder's
//! contents at depth 0, exactly as it always was -- the root has no row of
//! its own. With two or more, each root gets a header row at depth 0
//! (`Entry.is_root`, named after the workspace folder) and its contents
//! sit under it at depth 1, so collapsing a header is the ordinary
//! collapse of a directory row. Every entry carries the index of the root
//! it came from (`Entry.root`): its `.gitignore` chain and its path
//! relative to its root both depend on which root that is, and a path
//! prefix can't say for sure when one workspace folder sits inside
//! another.

const std = @import("std");
const glyphwire = @import("glyphwire");
const gitignore = @import("applib").gitignore;

/// What a listing or a walk is allowed to show. Lives with the ignore
/// matcher it consults, in `applib`, so salacommander's F3 finder
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
    /// The final path component, owned. A root header's is the
    /// workspace folder's name instead.
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
    /// An expanded directory's mtime as it was when its children were
    /// read; null for a file, a collapsed directory, or one that couldn't
    /// be stat'ed. What `changedOnDisk` compares against.
    stamp: ?i96 = null,
    /// Index into `Tree.roots` of the folder this entry is under.
    root: usize = 0,
    /// A workspace folder's header row -- only present with two or more
    /// roots. Always a directory; its `path` is the root's.
    is_root: bool = false,

    /// Columns this row occupies when drawn.
    pub fn cols(self: Entry) usize {
        return self.depth * indent_cols + icon_cols + glyphwire.stringWidth(self.name);
    }
};

/// One folder the tree is rooted at.
pub const Root = struct {
    /// Absolute, owned.
    path: []u8,
    /// What its header row says, owned. Unused with a single root, which
    /// has no header.
    name: []u8,
    /// The root's mtime when it was last read -- `Entry.stamp` for a
    /// directory with no row of its own. Single-root only: a header row
    /// is an entry and keeps its own stamp.
    stamp: ?i96 = null,
};

/// A path as the tree addresses it: which root, and where under it.
pub const Located = struct {
    root: usize,
    /// Relative to that root, `/`-separated; empty for the root itself.
    /// Borrowed from whatever absolute path it was cut out of.
    rel: []const u8,
};

pub const Tree = struct {
    alloc: std.mem.Allocator,
    /// The folders the tree is rooted at, in sidebar order. Never empty
    /// for a tree built by `init` / `initRoots`.
    roots: std.ArrayList(Root) = .empty,
    /// Visible entries in draw order -- see the flattening note above.
    entries: std.ArrayList(Entry) = .empty,
    /// The highlighted row, in `entries` indices.
    cursor: usize = 0,
    /// What the listing is allowed to show. Changing it needs a `reload`
    /// -- the entries are the answer to this question, not a view of it.
    visible: Visibility = .{},

    /// What a root is made from: borrowed strings, copied by the tree.
    pub const RootSpec = struct {
        path: []const u8,
        name: []const u8,
    };

    /// A tree over one folder, the way zoe has always started.
    pub fn init(alloc: std.mem.Allocator, io: std.Io, root: []const u8, visible: Visibility) !Tree {
        return initRoots(alloc, io, &.{.{ .path = root, .name = std.fs.path.basename(root) }}, visible);
    }

    /// A tree over every folder in `specs` (at least one), each header
    /// open -- which is how VS Code first shows a workspace.
    pub fn initRoots(alloc: std.mem.Allocator, io: std.Io, specs: []const RootSpec, visible: Visibility) !Tree {
        std.debug.assert(specs.len > 0);
        var self: Tree = .{ .alloc = alloc, .visible = visible };
        errdefer self.deinit();
        for (specs) |spec| try self.appendRoot(spec);
        try self.rebuild(io);
        try self.openAllHeaders(io);
        return self;
    }

    fn appendRoot(self: *Tree, spec: RootSpec) !void {
        const path = try self.alloc.dupe(u8, spec.path);
        errdefer self.alloc.free(path);
        const name = try self.alloc.dupe(u8, spec.name);
        errdefer self.alloc.free(name);
        try self.roots.append(self.alloc, .{ .path = path, .name = name });
    }

    /// Whether the sidebar shows header rows -- two or more roots.
    pub fn multiRoot(self: *const Tree) bool {
        return self.roots.items.len > 1;
    }

    /// The first root: where the shell panel falls back to, and what a
    /// single-folder `:cd` replaces.
    pub fn primaryRoot(self: *const Tree) []const u8 {
        return self.roots.items[0].path;
    }

    /// Every root's path, in order, for a caller walking all of them.
    /// The slice is the caller's to free; the strings are the tree's.
    pub fn rootPaths(self: *const Tree, alloc: std.mem.Allocator) ![]const []const u8 {
        const out = try alloc.alloc([]const u8, self.roots.items.len);
        for (self.roots.items, out) |r, *o| o.* = r.path;
        return out;
    }

    /// Adds a folder at the end, its header open, keeping what was open
    /// elsewhere. False when it is already a root. The tree turns into a
    /// multi-root one on the second folder, which moves every existing
    /// row down a level under its new header -- `reload` restores by
    /// path, so nothing that was open closes.
    pub fn addRoot(self: *Tree, io: std.Io, spec: RootSpec) !bool {
        if (self.rootIndex(spec.path) != null) return false;
        const was_single = !self.multiRoot();
        try self.appendRoot(spec);
        try self.reload(io);
        // The old root's header is new too, and opening it is what keeps
        // its rows on screen across the change.
        if (was_single) try self.openHeader(io, 0);
        try self.openHeader(io, self.roots.items.len - 1);
        return true;
    }

    /// Drops root `index`. The last root can't go: a sidebar with nothing
    /// in it has no directory for a new file, the shell or Ctrl+P.
    pub fn removeRoot(self: *Tree, io: std.Io, index: usize) !void {
        if (self.roots.items.len <= 1 or index >= self.roots.items.len) return error.LastRoot;
        // Entries name roots by index, so what was open is captured
        // against the old numbering and renumbered before the rebuild;
        // restoring against the shifted list would open folders in the
        // wrong root.
        var open = try self.snapshotOpen();
        defer open.deinit(self.alloc);
        open.dropRoot(self.alloc, index);

        const gone = self.roots.orderedRemove(index);
        self.alloc.free(gone.path);
        self.alloc.free(gone.name);
        try self.restore(io, &open);
    }

    pub fn rootIndex(self: *const Tree, abs: []const u8) ?usize {
        for (self.roots.items, 0..) |r, i| {
            if (std.mem.eql(u8, r.path, abs)) return i;
        }
        return null;
    }

    /// Which root `abs` is under, and where. The longest matching root
    /// wins, so a workspace folder nested inside another claims its own
    /// files. Null for a path under none of them.
    pub fn locate(self: *const Tree, abs: []const u8) ?Located {
        var best: ?Located = null;
        var best_len: usize = 0;
        for (self.roots.items, 0..) |r, i| {
            if (!isUnder(r.path, abs)) continue;
            if (best != null and r.path.len <= best_len) continue;
            best = .{ .root = i, .rel = relOf(r.path, abs) };
            best_len = r.path.len;
        }
        return best;
    }

    /// The header row of root `index`; null with a single root.
    pub fn headerRow(self: *const Tree, index: usize) ?usize {
        if (!self.multiRoot()) return null;
        for (self.entries.items, 0..) |e, i| {
            if (e.is_root and e.root == index) return i;
        }
        return null;
    }

    fn openHeader(self: *Tree, io: std.Io, index: usize) !void {
        const row = self.headerRow(index) orelse return;
        if (!self.entries.items[row].expanded) try self.toggle(io, row);
    }

    /// Opens every header, last first so each toggle's splice lands after
    /// the headers still waiting.
    fn openAllHeaders(self: *Tree, io: std.Io) !void {
        var i = self.roots.items.len;
        while (i > 0) {
            i -= 1;
            try self.openHeader(io, i);
        }
    }

    /// Clears the listing and reads it from the top: a single root's
    /// contents, or one closed header per root.
    fn rebuild(self: *Tree, io: std.Io) !void {
        self.clearEntries();
        if (!self.multiRoot()) {
            const r = &self.roots.items[0];
            r.stamp = try self.readInto(io, r.path, 0, "", 0, 0);
            return;
        }
        for (self.roots.items, 0..) |r, i| {
            const path = try self.alloc.dupe(u8, r.path);
            errdefer self.alloc.free(path);
            const name = try self.alloc.dupe(u8, r.name);
            errdefer self.alloc.free(name);
            try self.entries.append(self.alloc, .{
                .name = name,
                .path = path,
                .is_dir = true,
                .depth = 0,
                .root = i,
                .is_root = true,
            });
        }
    }

    /// Whether a directory the tree is showing has changed on disk since
    /// it was read: the root or any expanded folder gained, lost or
    /// renamed an entry (each of which moves the directory's own mtime),
    /// or has gone. `zoe/ui.zig` asks on the once-a-second disk check
    /// and answers yes with a `reload`, which re-reads everything and
    /// keeps what was open and where the cursor was.
    ///
    /// Polling the directories already on screen rather than watching
    /// with inotify, for the reasons `zoe/diskwatch.zig` gives for files:
    /// a stat per open folder per second costs nothing and works the
    /// same everywhere. A collapsed folder isn't polled -- opening it
    /// reads it fresh anyway.
    pub fn changedOnDisk(self: *const Tree, io: std.Io) bool {
        // With headers, each root is an entry and the loop covers it.
        if (!self.multiRoot()) {
            const r = self.roots.items[0];
            if (dirStamp(io, r.path) != r.stamp) return true;
        }
        for (self.entries.items) |e| {
            if (!e.is_dir or !e.expanded) continue;
            if (dirStamp(io, e.path) != e.stamp) return true;
        }
        return false;
    }

    fn dirStamp(io: std.Io, path: []const u8) ?i96 {
        const st = std.Io.Dir.cwd().statFile(io, path, .{}) catch return null;
        return st.mtime.nanoseconds;
    }

    /// The directory a new entry made from row `index` goes in: the row
    /// itself when it is a directory (a root header included), else the
    /// directory the row is in (the first root for an empty tree).
    /// Borrowed from the tree; valid until it next changes.
    pub fn dirFor(self: *const Tree, index: usize) []const u8 {
        const e = self.at(index) orelse return self.primaryRoot();
        if (e.is_dir) return e.path;
        return std.fs.path.dirname(e.path) orelse self.roots.items[e.root].path;
    }

    /// The row of directory `abs`, expanded so its children are rows --
    /// where a new entry's field goes. Null for a single root itself,
    /// which has no row, and for a directory the tree can't show. A
    /// workspace root answers its header row.
    pub fn openDirRow(self: *Tree, io: std.Io, abs: []const u8) !?usize {
        const index = (try self.revealPath(io, abs)) orelse return null;
        const e = self.entries.items[index];
        if (e.is_dir and !e.expanded) try self.toggle(io, index);
        return index;
    }

    /// Re-reads and moves the cursor onto `abs` (an absolute path under
    /// a root) -- after a create or a rename, so the entry just made is
    /// the one highlighted. A path the tree can't show (hidden while
    /// Ctrl+H is off) leaves the cursor where `reload` put it.
    pub fn reloadOnto(self: *Tree, io: std.Io, abs: []const u8) !void {
        try self.reload(io);
        if (try self.revealPath(io, abs)) |index| self.cursor = index;
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
        var open = try self.snapshotOpen();
        defer open.deinit(self.alloc);
        try self.restore(io, &open);
    }

    /// The open folders and the cursor's entry, by (root, path under it)
    /// -- what survives a rebuild. A header is recorded like any folder,
    /// with an empty path, so a closed one stays closed.
    const OpenSet = struct {
        /// In tree order, so a parent is always restored before its child
        /// -- though `revealIn` would open the ancestors anyway.
        dirs: std.ArrayList(Mark) = .empty,
        cursor: ?Mark = null,

        const Mark = struct { root: usize, rel: []u8 };

        fn deinit(self: *OpenSet, alloc: std.mem.Allocator) void {
            for (self.dirs.items) |m| alloc.free(m.rel);
            self.dirs.deinit(alloc);
            if (self.cursor) |m| alloc.free(m.rel);
        }

        /// Forgets root `index` and renumbers the ones after it, ahead of
        /// that root being removed.
        fn dropRoot(self: *OpenSet, alloc: std.mem.Allocator, index: usize) void {
            var keep: usize = 0;
            for (self.dirs.items) |m| {
                if (m.root == index) {
                    alloc.free(m.rel);
                    continue;
                }
                self.dirs.items[keep] = .{ .root = if (m.root > index) m.root - 1 else m.root, .rel = m.rel };
                keep += 1;
            }
            self.dirs.shrinkRetainingCapacity(keep);
            if (self.cursor) |*m| {
                if (m.root == index) {
                    alloc.free(m.rel);
                    self.cursor = null;
                } else if (m.root > index) m.root -= 1;
            }
        }
    };

    fn snapshotOpen(self: *const Tree) !OpenSet {
        var open: OpenSet = .{};
        errdefer open.deinit(self.alloc);
        for (self.entries.items) |e| {
            if (!e.is_dir or !e.expanded) continue;
            const rel = try self.alloc.dupe(u8, relOf(self.roots.items[e.root].path, e.path));
            errdefer self.alloc.free(rel);
            try open.dirs.append(self.alloc, .{ .root = e.root, .rel = rel });
        }
        if (self.at(self.cursor)) |e| {
            open.cursor = .{ .root = e.root, .rel = try self.alloc.dupe(u8, relOf(self.roots.items[e.root].path, e.path)) };
        }
        return open;
    }

    fn restore(self: *Tree, io: std.Io, open: *const OpenSet) !void {
        try self.rebuild(io);
        for (open.dirs.items) |m| {
            const index = (try self.revealIn(io, m.root, m.rel)) orelse continue;
            const e = self.entries.items[index];
            if (e.is_dir and !e.expanded) try self.toggle(io, index);
        }
        // The cursor's own row may itself have been hidden, in which case
        // there is nothing to go back to and it stays where it lands.
        if (open.cursor) |m| {
            if (try self.revealIn(io, m.root, m.rel)) |index| self.cursor = index;
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

    /// `path` relative to `root`, `/` separated, and empty for the root
    /// itself. Every entry's `path` was built by joining onto its root, so
    /// this is a slice rather than a computation; a path that somehow
    /// isn't under the root comes back whole, which matches nothing and
    /// hides nothing.
    fn relOf(root: []const u8, path: []const u8) []const u8 {
        if (std.mem.eql(u8, path, root)) return "";
        if (path.len <= root.len or !std.mem.startsWith(u8, path, root)) return path;
        const rest = path[root.len..];
        return if (rest[0] == '/') rest[1..] else rest;
    }

    /// Whether `path` is `root` or somewhere below it -- on a component
    /// boundary, so `/src/zoe` is not under `/src/zo`.
    fn isUnder(root: []const u8, path: []const u8) bool {
        if (!std.mem.startsWith(u8, path, root)) return false;
        if (path.len == root.len) return true;
        return path[root.len] == '/' or std.mem.endsWith(u8, root, "/");
    }

    pub fn deinit(self: *Tree) void {
        for (self.entries.items) |e| {
            self.alloc.free(e.name);
            self.alloc.free(e.path);
        }
        self.entries.deinit(self.alloc);
        for (self.roots.items) |r| {
            self.alloc.free(r.path);
            self.alloc.free(r.name);
        }
        self.roots.deinit(self.alloc);
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
            const stamp = try self.readInto(io, e.path, e.root, relOf(self.roots.items[e.root].path, e.path), e.depth + 1, index + 1);
            self.entries.items[index].expanded = true;
            self.entries.items[index].stamp = stamp;
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
        self.entries.items[index].stamp = null;
        if (self.cursor >= self.entries.items.len) self.cursor = self.entries.items.len -| 1;
    }

    /// Reads `dir` and splices its entries in at `insert_at`, directories
    /// first then files, each group alphabetical -- the order every file
    /// browser uses. A directory that can't be read leaves the tree
    /// unchanged rather than failing the whole operation: an unreadable
    /// folder should render as an empty one, not take the editor down.
    ///
    /// `root` is the index of the root `dir` is under, and `rel_dir` is
    /// `dir` relative to it -- what the `.gitignore` files in scope are
    /// matched against.
    ///
    /// Returns `dir`'s mtime, taken *before* the read: a change landing
    /// while the read is under way then moves the mtime past the stamp,
    /// and the next `changedOnDisk` catches it rather than missing it.
    fn readInto(self: *Tree, io: std.Io, dir: []const u8, root: usize, rel_dir: []const u8, depth: usize, insert_at: usize) !?i96 {
        const stamp = dirStamp(io, dir);
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
        try self.pushIgnoreChain(io, &ignores, self.roots.items[root].path, rel_dir);

        var handle = std.Io.Dir.cwd().openDir(io, dir, .{ .iterate = true }) catch return stamp;
        defer handle.close(io);

        var it = handle.iterate();
        while (it.next(io) catch null) |raw| {
            const is_dir = raw.kind == .directory;
            const path = try std.fs.path.join(self.alloc, &.{ dir, raw.name });
            errdefer self.alloc.free(path);

            const hidden = self.visible.isHidden(&ignores, raw.name, relOf(self.roots.items[root].path, path), is_dir);
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
                .root = root,
            });
        }

        std.mem.sort(Entry, listing.items, {}, lessThan);
        try self.entries.insertSlice(self.alloc, @min(insert_at, self.entries.items.len), listing.items);
        listing.clearRetainingCapacity();
        return stamp;
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

    /// `revealIn` against the first root -- the whole tree when there is
    /// only one.
    pub fn reveal(self: *Tree, io: std.Io, rel: []const u8) !?usize {
        return self.revealIn(io, 0, rel);
    }

    /// `revealIn` for an absolute path, under whichever root holds it.
    pub fn revealPath(self: *Tree, io: std.Io, abs: []const u8) !?usize {
        const loc = self.locate(abs) orelse return null;
        return self.revealIn(io, loc.root, loc.rel);
    }

    /// Expands whatever it takes for `rel` -- a path relative to root
    /// `root`, `/`-separated -- to be a visible row, and returns its index.
    /// An empty `rel` is the root itself: its header row with several
    /// roots, nothing with one.
    /// Null if any component is missing: the tree is a snapshot and the
    /// deep listing behind a `/` search is another one, so they can
    /// disagree about a file that has just been removed.
    ///
    /// This is what lets a `/` search land on a file inside a folder that
    /// was never opened: the search finds the path, this turns it into a
    /// row. The expansion stays afterwards -- the row has to remain
    /// visible for the cursor to be on it.
    pub fn revealIn(self: *Tree, io: std.Io, root: usize, rel: []const u8) !?usize {
        // The window of entries the next component must be found in:
        // first the root's listing, then the children of whatever the
        // previous component resolved to. One root's listing is the whole
        // tree; with headers it is the run under the root's header.
        var lo: usize = 0;
        var hi: usize = self.entries.items.len;
        var depth: usize = 0;
        if (self.multiRoot()) {
            const h = self.headerRow(root) orelse return null;
            if (std.mem.trim(u8, rel, "/").len == 0) return h;
            if (!self.entries.items[h].expanded) try self.toggle(io, h);
            lo = h + 1;
            hi = self.subtreeEnd(h);
            depth = 1;
        } else if (root != 0) return null;
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

    /// Pushes the `.gitignore` of `root` and of every directory on the
    /// way down to `rel_dir`, outermost first -- the order `Stack.match`
    /// resolves in.
    fn pushIgnoreChain(self: *Tree, io: std.Io, stack: *gitignore.Stack, root: []const u8, rel_dir: []const u8) !void {
        _ = try stack.pushDir(io, root, "");
        if (rel_dir.len == 0) return;

        var i: usize = 0;
        while (true) {
            const end = std.mem.indexOfScalarPos(u8, rel_dir, i, '/') orelse rel_dir.len;
            const prefix = rel_dir[0..end];
            const abs = try std.fs.path.join(self.alloc, &.{ root, prefix });
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
/// be `/`. Deliberately the same shape of guard `applib/finder.zig` puts on
/// the Ctrl+P scan.
pub const deep_max_entries: usize = 20_000;

/// How deep that walk goes -- a guard against a pathological tree rather
/// than a limit a source tree should reach.
pub const deep_max_depth: usize = 16;

/// Every path under the tree's roots, whether or not its folder is open:
/// what a `/` search matches against, and what `Tree.revealIn` is handed
/// to turn a hit into a row.
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
    /// Parallel to `paths`: the index of the root each path is relative
    /// to. Paths are grouped by root, in root order, each group sorted.
    root_of: std.ArrayList(usize) = .empty,
    /// The walk hit `deep_max_entries` and stopped early, so the listing
    /// is a prefix of the tree rather than the whole of it.
    truncated: bool = false,
    /// What the walk was allowed to collect -- the same flag the tree
    /// listing was built under, so a `/` hit always has a row to land on.
    visible: Visibility = .{},

    pub fn deinit(self: *DeepList) void {
        for (self.paths.items) |p| self.alloc.free(p);
        self.paths.deinit(self.alloc);
        self.root_of.deinit(self.alloc);
        self.* = undefined;
    }

    /// The final component of `paths[index]` -- what a query is matched
    /// against, since what is being typed is a name and not a path.
    pub fn nameAt(self: *const DeepList, index: usize) []const u8 {
        const p = self.paths.items[index];
        const slash = std.mem.lastIndexOfScalar(u8, p, '/') orelse return p;
        return p[slash + 1 ..];
    }

    /// Adds one path relative to the first root. Tests use it to build a
    /// listing directly.
    pub fn addPath(self: *DeepList, rel: []const u8) !void {
        const owned = try self.alloc.dupe(u8, rel);
        errdefer self.alloc.free(owned);
        try self.paths.append(self.alloc, owned);
        try self.root_of.append(self.alloc, 0);
    }
};

/// `deepListRoots` over a single folder.
pub fn deepList(alloc: std.mem.Allocator, io: std.Io, root: []const u8, visible: Visibility) !DeepList {
    return deepListRoots(alloc, io, &.{root}, visible);
}

/// Walks every folder in `roots` and collects every path under each.
/// Directories are listed too, so a `/` search can land on a folder; one
/// that can't be read is skipped rather than failing the walk, the rule
/// the rest of the tree uses. `deep_max_entries` bounds the whole walk,
/// not each root.
pub fn deepListRoots(alloc: std.mem.Allocator, io: std.Io, roots: []const []const u8, visible: Visibility) !DeepList {
    var self: DeepList = .{ .alloc = alloc, .visible = visible };
    errdefer self.deinit();

    for (roots, 0..) |root, i| {
        const start = self.paths.items.len;
        // Unlike the tree's own reads, this walk descends, so it pushes
        // each directory's ignore file on the way in and pops it on the
        // way out rather than re-reading the chain per directory.
        var ignores: gitignore.Stack = .{ .alloc = alloc };
        defer ignores.deinit();
        try deepScan(&self, io, &ignores, root, "", 0);

        std.mem.sort([]u8, self.paths.items[start..], {}, lessThanPath);
        try self.root_of.appendNTimes(alloc, i, self.paths.items.len - start);
        if (self.truncated) break;
    }
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
