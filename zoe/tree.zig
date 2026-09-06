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

const std = @import("std");
const glyphwire = @import("glyphwire");

/// Cells of indent per nesting level.
pub const indent_cols: usize = 2;

/// Columns reserved before the name for the entry's icon plus a space.
pub const icon_cols: usize = 2;

pub const Entry = struct {
    /// The final path component, owned.
    name: []u8,
    /// The full path, owned -- what `:e` and a click both need.
    path: []u8,
    is_dir: bool,
    depth: usize,
    /// Directories only; always false for a file.
    expanded: bool = false,

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

    pub fn init(alloc: std.mem.Allocator, io: std.Io, root: []const u8) !Tree {
        var self: Tree = .{ .alloc = alloc, .root = try alloc.dupe(u8, root) };
        errdefer alloc.free(self.root);
        try self.readInto(io, self.root, 0, 0);
        return self;
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
            try self.readInto(io, e.path, e.depth + 1, index + 1);
            self.entries.items[index].expanded = true;
        }
    }

    /// Removes the run of entries nested under `index` -- everything
    /// after it that is deeper than it, which by construction is exactly
    /// its subtree.
    fn collapse(self: *Tree, index: usize) void {
        const depth = self.entries.items[index].depth;
        var end = index + 1;
        while (end < self.entries.items.len and self.entries.items[end].depth > depth) end += 1;

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
    fn readInto(self: *Tree, io: std.Io, dir: []const u8, depth: usize, insert_at: usize) !void {
        var listing: std.ArrayList(Entry) = .empty;
        defer listing.deinit(self.alloc);
        errdefer for (listing.items) |e| {
            self.alloc.free(e.name);
            self.alloc.free(e.path);
        };

        var handle = std.Io.Dir.cwd().openDir(io, dir, .{ .iterate = true }) catch return;
        defer handle.close(io);

        var it = handle.iterate();
        while (it.next(io) catch null) |raw| {
            // Dotfiles are hidden, matching every other tree view; there
            // is no toggle for it yet.
            if (raw.name.len > 0 and raw.name[0] == '.') continue;

            const name = try self.alloc.dupe(u8, raw.name);
            errdefer self.alloc.free(name);
            const path = try std.fs.path.join(self.alloc, &.{ dir, raw.name });
            errdefer self.alloc.free(path);

            try listing.append(self.alloc, .{
                .name = name,
                .path = path,
                .is_dir = raw.kind == .directory,
                .depth = depth,
            });
        }

        std.mem.sort(Entry, listing.items, {}, lessThan);
        try self.entries.insertSlice(self.alloc, @min(insert_at, self.entries.items.len), listing.items);
        listing.clearRetainingCapacity();
    }

    fn lessThan(_: void, a: Entry, b: Entry) bool {
        if (a.is_dir != b.is_dir) return a.is_dir;
        return std.mem.lessThan(u8, a.name, b.name);
    }
};
