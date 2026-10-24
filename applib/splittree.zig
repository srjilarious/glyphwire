// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: MPL-2.0

//! A binary split tree over opaque leaf ids, mirroring a host split tree
//! node for node: gmux's panes (`gmux/layout.zig`) and zoe's editor groups
//! (`zoe/groups.zig`) are both one. Plus `neighbor`, the geometry both use
//! to move focus left / right / up / down between leaves.
//!
//! Pure structure: no wire calls, so splitting and closing are testable
//! without a server. Each program turns what an edit reports into its own
//! `create_*split` / `set_*split_children` / `replace_*split_child` /
//! `destroy_*split` calls, and keeps whatever handle the host gave a split
//! in `Split.handle`.
//!
//! **Binary, not n-ary.** Splitting a leaf turns it into a split holding
//! the old leaf and the new one; removing a leaf puts its sibling where
//! their split was. Every split therefore has exactly one divider (one
//! neighbour to grow into on a keyboard resize), and an edit changes what
//! sits in exactly one slot of at most one surviving split. A caller sends
//! that as one `replace_*split_child`, which keeps the slot's size: the
//! proportions the user dragged belong to the host, and re-sending the
//! whole list would reset them.
//!
//! **Nodes never move.** A split happens in place (the leaf's node becomes
//! the split) and a removal collapses the sibling into the parent's node,
//! so a parent's pointer to its child stays valid across every edit.

const std = @import("std");

/// Which half of a new split the new leaf takes: `.after` puts it right
/// of / below the old one, `.before` left of / above.
pub const Side = enum { before, after };

/// Which child of its parent split a node is.
pub const Slot = enum {
    first,
    second,

    /// The slot's position in the host split's child list, as
    /// `replace_*split_child` names it.
    pub fn index(self: Slot) usize {
        return switch (self) {
            .first => 0,
            .second => 1,
        };
    }
};

/// `Id` names a leaf; `Axis` is the caller's own name for a split's
/// direction (the tree only stores it); `Handle` is the host's handle for
/// the split, carried along through edits.
pub fn SplitTree(comptime Id: type, comptime Axis: type, comptime Handle: type) type {
    return struct {
        const Self = @This();

        pub const Node = struct {
            parent: ?*Node = null,
            kind: union(enum) {
                leaf: Id,
                split: Split,
            },

            /// The first leaf in reading order under this node -- where
            /// focus goes when a removal hands it to a whole subtree.
            pub fn firstLeaf(self: *const Node) Id {
                var n = self;
                while (true) switch (n.kind) {
                    .leaf => |id| return id,
                    .split => |s| n = s.first,
                };
            }

            /// Which child of its parent this node is; null for the root.
            pub fn slot(self: *const Node) ?Slot {
                const p = self.parent orelse return null;
                return if (p.kind.split.first == self) .first else .second;
            }
        };

        pub const Split = struct {
            axis: Axis,
            handle: Handle,
            first: *Node,
            second: *Node,
        };

        pub const Removed = struct {
            /// The handle of the split that held the removed leaf and its
            /// sibling, now gone: the caller destroys it on the host.
            handle: Handle,
            /// The node that took the split's place (the sibling's
            /// contents, at the split's address). The caller puts it in
            /// its parent's slot for it, or installs it as the root when
            /// it has no parent.
            replacement: *Node,
            /// Where focus goes: the first leaf of the sibling subtree,
            /// the one that grew into the space.
            focus: Id,
        };

        pub const Error = error{
            OutOfMemory,
            /// No leaf has that id.
            UnknownLeaf,
            /// `remove` on the only leaf: a tree always has one. What
            /// closing the last leaf means is the caller's call.
            LastLeaf,
        };

        alloc: std.mem.Allocator,
        /// Never null. A single leaf is a bare `.leaf` root.
        root: *Node,

        pub fn init(alloc: std.mem.Allocator, first: Id) !Self {
            const root = try alloc.create(Node);
            root.* = .{ .kind = .{ .leaf = first } };
            return .{ .alloc = alloc, .root = root };
        }

        pub fn deinit(self: *Self) void {
            destroyTree(self.alloc, self.root);
            self.* = undefined;
        }

        fn destroyTree(alloc: std.mem.Allocator, n: *Node) void {
            switch (n.kind) {
                .leaf => {},
                .split => |s| {
                    destroyTree(alloc, s.first);
                    destroyTree(alloc, s.second);
                },
            }
            alloc.destroy(n);
        }

        /// The leaf holding `id`, or null.
        pub fn find(self: *const Self, id: Id) ?*Node {
            return findIn(self.root, id);
        }

        fn findIn(n: *Node, id: Id) ?*Node {
            return switch (n.kind) {
                .leaf => |l| if (l == id) n else null,
                .split => |s| findIn(s.first, id) orelse findIn(s.second, id),
            };
        }

        /// How many leaves the tree holds.
        pub fn count(self: *const Self) usize {
            return countIn(self.root);
        }

        fn countIn(n: *const Node) usize {
            return switch (n.kind) {
                .leaf => 1,
                .split => |s| countIn(s.first) + countIn(s.second),
            };
        }

        /// Every leaf id in reading order (`first` before `second`: left
        /// to right, top to bottom).
        pub fn leavesInOrder(self: *const Self, alloc: std.mem.Allocator, out: *std.ArrayList(Id)) !void {
            try appendLeaves(alloc, self.root, out);
        }

        fn appendLeaves(alloc: std.mem.Allocator, n: *const Node, out: *std.ArrayList(Id)) !void {
            switch (n.kind) {
                .leaf => |id| try out.append(alloc, id),
                .split => |s| {
                    try appendLeaves(alloc, s.first, out);
                    try appendLeaves(alloc, s.second, out);
                },
            }
        }

        /// Splits leaf `id` in two along `axis`, `new_id` taking `side`,
        /// under the host split `handle` the caller has already created.
        /// Returns the new split node: the caller sends its children, and
        /// puts its handle in its parent's slot for it (or installs it as
        /// the root when it has none).
        pub fn split(self: *Self, id: Id, new_id: Id, axis: Axis, handle: Handle, side: Side) Error!*Node {
            const leaf = self.find(id) orelse return error.UnknownLeaf;
            const first = try self.alloc.create(Node);
            errdefer self.alloc.destroy(first);
            const second = try self.alloc.create(Node);
            const ids: [2]Id = if (side == .after) .{ id, new_id } else .{ new_id, id };
            first.* = .{ .parent = leaf, .kind = .{ .leaf = ids[0] } };
            second.* = .{ .parent = leaf, .kind = .{ .leaf = ids[1] } };
            // The leaf becomes the split in place, so its parent's pointer
            // to it -- and so the parent's shape -- is unchanged.
            leaf.kind = .{ .split = .{ .axis = axis, .handle = handle, .first = first, .second = second } };
            return leaf;
        }

        /// Puts the whole tree on one side of a new root split along
        /// `axis`, leaf `new_id` on `side` of it, under the host split
        /// `handle` the caller has already created: a full-height column or
        /// full-width row at a window edge. Returns the new root, whose
        /// children the caller sends before installing it. Unlike `split`
        /// this one does move a node -- the old root becomes a child -- but
        /// only the root, which no parent points at.
        pub fn wrapRoot(self: *Self, new_id: Id, axis: Axis, handle: Handle, side: Side) Error!*Node {
            const leaf = try self.alloc.create(Node);
            errdefer self.alloc.destroy(leaf);
            const root = try self.alloc.create(Node);
            const old = self.root;
            const kids: [2]*Node = if (side == .after) .{ old, leaf } else .{ leaf, old };
            leaf.* = .{ .parent = root, .kind = .{ .leaf = new_id } };
            old.parent = root;
            root.* = .{ .kind = .{ .split = .{ .axis = axis, .handle = handle, .first = kids[0], .second = kids[1] } } };
            self.root = root;
            return root;
        }

        /// Trades two leaves' ids, the shape untouched: each pane moves
        /// into the other's slot. Returns both leaf nodes, now holding
        /// their new ids, for the caller to re-send.
        pub fn swapLeaves(self: *Self, a: Id, b: Id) Error![2]*Node {
            const na = self.find(a) orelse return error.UnknownLeaf;
            const nb = self.find(b) orelse return error.UnknownLeaf;
            na.kind = .{ .leaf = b };
            nb.kind = .{ .leaf = a };
            return .{ na, nb };
        }

        /// Takes leaf `id` out of the tree, its sibling growing into the
        /// space. The tree is untouched on an error.
        pub fn remove(self: *Self, id: Id) Error!Removed {
            const leaf = self.find(id) orelse return error.UnknownLeaf;
            const parent = leaf.parent orelse return error.LastLeaf;
            const s = parent.kind.split;
            const sibling = if (s.first == leaf) s.second else s.first;

            // The sibling's contents move up into the parent node, so the
            // grandparent's pointer stays valid and the parent node is the
            // replacement. Its children (if any) are re-parented to it.
            parent.kind = sibling.kind;
            switch (parent.kind) {
                .leaf => {},
                .split => |ps| {
                    ps.first.parent = parent;
                    ps.second.parent = parent;
                },
            }
            self.alloc.destroy(leaf);
            self.alloc.destroy(sibling);
            return .{ .handle = s.handle, .replacement = parent, .focus = parent.firstLeaf() };
        }

        /// Moves every leaf id one leaf along in reading order, the
        /// shape untouched: `.after` sends each id to the next leaf (the
        /// last wraps to the first), `.before` to the previous one (tmux's
        /// `rotate-window -D` / `-U`). Fills `out` with the leaf nodes in
        /// reading order, now holding their new ids, so the caller can
        /// re-send each one's slot. A no-op on a single leaf.
        pub fn rotate(self: *Self, alloc: std.mem.Allocator, dir: Side, out: *std.ArrayList(*Node)) !void {
            try appendLeafNodes(alloc, self.root, out);
            const nodes = out.items;
            if (nodes.len < 2) return;
            switch (dir) {
                .after => {
                    const last = nodes[nodes.len - 1].kind.leaf;
                    var i = nodes.len - 1;
                    while (i > 0) : (i -= 1) nodes[i].kind = .{ .leaf = nodes[i - 1].kind.leaf };
                    nodes[0].kind = .{ .leaf = last };
                },
                .before => {
                    const first = nodes[0].kind.leaf;
                    for (nodes[0 .. nodes.len - 1], nodes[1..]) |n, next| n.kind = .{ .leaf = next.kind.leaf };
                    nodes[nodes.len - 1].kind = .{ .leaf = first };
                },
            }
        }

        fn appendLeafNodes(alloc: std.mem.Allocator, n: *Node, out: *std.ArrayList(*Node)) !void {
            switch (n.kind) {
                .leaf => try out.append(alloc, n),
                .split => |s| {
                    try appendLeafNodes(alloc, s.first, out);
                    try appendLeafNodes(alloc, s.second, out);
                },
            }
        }
    };
}

// ── Directional focus ───────────────────────────────────────────────────

/// A leaf's on-screen area, in cells.
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

/// The rect focus should move to from `rects[from]` going `dir`, as an
/// index into `rects`, or null when nothing lies that way.
///
/// A candidate has to lie wholly on that side and overlap `from` across
/// the other axis -- a pane diagonally off to one side isn't "left". Of
/// those, the nearest edge wins, and between equally near ones the one
/// sharing the most of `from`'s span: the pane you are looking straight
/// at, rather than whichever happens to come first.
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
