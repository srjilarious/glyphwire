// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: GPL-3.0-or-later

//! How zoe's editor groups are arranged: the binary tree `:vsplit` /
//! `:split` grow and `:close` shrinks, and the geometry Ctrl+hjkl uses
//! to move between them.
//!
//! An editor group is one tab strip over one buffer pane (`Group` in
//! `zoe/ui.zig`). The tree here knows them only by id: it is pure, so
//! the arithmetic of splitting and closing is testable without a
//! server, and `ui.zig` turns what it reports into `create_split` /
//! `set_split_children` / `destroy_split` calls.
//!
//! **Binary, and it mirrors the host's split tree node for node.** Every
//! split here is one host split with exactly two children, created
//! `resizable` so the user can drag the band between them. Splitting a
//! group turns its leaf into a split holding the old group and the new
//! one; closing a group puts its sibling where their split was. An n-ary
//! tree (vim's, where a second `:vsplit` adds a third column beside the
//! two) would need a host split's child list edited in place, and the
//! wire only replaces a list wholesale, which resets the proportions the
//! user dragged. With two children per split, the only list that is ever
//! re-sent is the one whose shape actually changed.

const std = @import("std");
const glyphwire = @import("glyphwire");

pub const GroupId = u32;

/// Which way a split lays its two halves out, in the user's terms:
/// `vertical` is `:vsplit` (side by side, a vertical divider) and
/// `horizontal` is `:split` (stacked, a horizontal divider).
pub const Orientation = enum {
    vertical,
    horizontal,

    /// The host's name for the same thing: a `row` split lays its
    /// children out left to right.
    pub fn axis(self: Orientation) glyphwire.SplitAxis {
        return switch (self) {
            .vertical => .row,
            .horizontal => .column,
        };
    }
};

pub const Node = struct {
    parent: ?*Node = null,
    kind: union(enum) {
        group: GroupId,
        split: Split,
    },

    pub const Split = struct {
        handle: glyphwire.SplitHandle,
        orientation: Orientation,
        first: *Node,
        second: *Node,
    };

    /// The first group in reading order under this node -- where focus
    /// goes when a close hands it to a whole subtree.
    pub fn firstGroup(self: *const Node) GroupId {
        var n = self;
        while (true) switch (n.kind) {
            .group => |id| return id,
            .split => |s| n = s.first,
        };
    }
};

pub const Layout = struct {
    alloc: std.mem.Allocator,
    root: *Node,

    pub fn init(alloc: std.mem.Allocator, first: GroupId) !Layout {
        const root = try alloc.create(Node);
        root.* = .{ .kind = .{ .group = first } };
        return .{ .alloc = alloc, .root = root };
    }

    pub fn deinit(self: *Layout) void {
        destroyTree(self.alloc, self.root);
    }

    fn destroyTree(alloc: std.mem.Allocator, n: *Node) void {
        switch (n.kind) {
            .group => {},
            .split => |s| {
                destroyTree(alloc, s.first);
                destroyTree(alloc, s.second);
            },
        }
        alloc.destroy(n);
    }

    /// The leaf holding `id`, or null.
    pub fn find(self: *const Layout, id: GroupId) ?*Node {
        return findIn(self.root, id);
    }

    fn findIn(n: *Node, id: GroupId) ?*Node {
        return switch (n.kind) {
            .group => |g| if (g == id) n else null,
            .split => |s| findIn(s.first, id) orelse findIn(s.second, id),
        };
    }

    /// How many groups the tree holds.
    pub fn count(self: *const Layout) usize {
        return countIn(self.root);
    }

    fn countIn(n: *const Node) usize {
        return switch (n.kind) {
            .group => 1,
            .split => |s| countIn(s.first) + countIn(s.second),
        };
    }

    /// Splits group `id`'s leaf in two: `id` keeps the first half (left
    /// or top) and `new_id` takes the second, under a host split
    /// `handle` the caller has already created. Returns the new split
    /// node, whose children the caller sends; its parent (null when it is
    /// the root) is the one other list whose child changed.
    pub fn split(self: *Layout, id: GroupId, new_id: GroupId, orientation: Orientation, handle: glyphwire.SplitHandle) !*Node {
        const leaf = self.find(id) orelse return error.UnknownGroup;
        const first = try self.alloc.create(Node);
        errdefer self.alloc.destroy(first);
        const second = try self.alloc.create(Node);
        first.* = .{ .parent = leaf, .kind = .{ .group = id } };
        second.* = .{ .parent = leaf, .kind = .{ .group = new_id } };
        // The leaf becomes the split in place, so its parent's pointer to
        // it -- and so the parent's shape -- is unchanged.
        leaf.kind = .{ .split = .{ .handle = handle, .orientation = orientation, .first = first, .second = second } };
        return leaf;
    }

    pub const Removed = struct {
        /// The host split that held the closed group and its sibling, now
        /// empty: the caller destroys it.
        destroyed: glyphwire.SplitHandle,
        /// The node that took the split's place. The caller re-sends its
        /// parent's children (or the root's slot, when `replacement` has
        /// no parent).
        replacement: *Node,
        /// Where focus goes: the first group of the sibling subtree, the
        /// pane that grew into the space the closed one left.
        focus: GroupId,
    };

    /// Takes group `id` out of the tree, its sibling growing into the
    /// space. Null when `id` is the only group -- there must always be
    /// one -- or isn't in the tree.
    pub fn remove(self: *Layout, id: GroupId) ?Removed {
        const leaf = self.find(id) orelse return null;
        const parent = leaf.parent orelse return null;
        const s = parent.kind.split;
        const sibling = if (s.first == leaf) s.second else s.first;

        // The sibling's contents move up into the parent node, so the
        // grandparent's pointer stays valid and the parent node is the
        // replacement. Its children (if any) are re-parented to it.
        parent.kind = sibling.kind;
        switch (parent.kind) {
            .group => {},
            .split => |ps| {
                ps.first.parent = parent;
                ps.second.parent = parent;
            },
        }
        self.alloc.destroy(leaf);
        self.alloc.destroy(sibling);
        return .{ .destroyed = s.handle, .replacement = parent, .focus = parent.firstGroup() };
    }

    /// Every group id in reading order (left to right, top to bottom).
    pub fn groupsInOrder(self: *const Layout, alloc: std.mem.Allocator, out: *std.ArrayList(GroupId)) !void {
        try appendGroups(alloc, self.root, out);
    }

    fn appendGroups(alloc: std.mem.Allocator, n: *const Node, out: *std.ArrayList(GroupId)) !void {
        switch (n.kind) {
            .group => |id| try out.append(alloc, id),
            .split => |s| {
                try appendGroups(alloc, s.first, out);
                try appendGroups(alloc, s.second, out);
            },
        }
    }
};

// ── Directional focus ───────────────────────────────────────────────────

/// A group's whole on-screen area (tab strip and buffer pane) in cells.
pub const Rect = struct {
    row: usize = 0,
    col: usize = 0,
    cols: usize = 0,
    rows: usize = 0,

    fn right(self: Rect) usize {
        return self.col + self.cols;
    }

    fn bottom(self: Rect) usize {
        return self.row + self.rows;
    }
};

pub const Direction = enum { left, right, up, down };

/// The rect Ctrl+hjkl should move to from `rects[from]`, as an index
/// into `rects`, or null when nothing lies that way.
///
/// A candidate has to lie wholly on that side and overlap `from` across
/// the other axis -- a pane diagonally off to one side isn't "left". Of
/// those, the nearest edge wins, and between equally near ones the one
/// sharing the most of `from`'s span: the pane you are looking straight
/// at, rather than whichever happens to come first in the tree.
pub fn neighbor(rects: []const Rect, from: usize, dir: Direction) ?usize {
    const a = rects[from];
    var best: ?usize = null;
    var best_gap: usize = 0;
    var best_overlap: usize = 0;
    for (rects, 0..) |b, i| {
        if (i == from or b.cols == 0 or b.rows == 0) continue;
        const gap: usize, const overlap: usize = switch (dir) {
            .left => if (b.right() <= a.col)
                .{ a.col - b.right(), span(a.row, a.bottom(), b.row, b.bottom()) }
            else
                continue,
            .right => if (b.col >= a.right())
                .{ b.col - a.right(), span(a.row, a.bottom(), b.row, b.bottom()) }
            else
                continue,
            .up => if (b.bottom() <= a.row)
                .{ a.row - b.bottom(), span(a.col, a.right(), b.col, b.right()) }
            else
                continue,
            .down => if (b.row >= a.bottom())
                .{ b.row - a.bottom(), span(a.col, a.right(), b.col, b.right()) }
            else
                continue,
        };
        if (overlap == 0) continue;
        if (best == null or gap < best_gap or (gap == best_gap and overlap > best_overlap)) {
            best = i;
            best_gap = gap;
            best_overlap = overlap;
        }
    }
    return best;
}

/// How much of `[a0, a1)` and `[b0, b1)` coincide.
fn span(a0: usize, a1: usize, b0: usize, b1: usize) usize {
    const lo = @max(a0, b0);
    const hi = @min(a1, b1);
    return hi -| lo;
}
