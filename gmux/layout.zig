//! gmux's pane-arrangement tree: a binary nested split tree over opaque
//! `PaneId`s, with no glyphwire dependency at all -- just structure, so
//! `tests/gmux_tests.zig` can exercise split/kill/promote without a
//! server. `ui.zig` is the half that turns a mutation into the matching
//! `create_pane_split`/`set_pane_split_children`/`set_root_pane_split`/
//! `destroy_pane_split` wire calls.
//!
//! The ids here are real `glyphwire.PaneHandle`s and the `wire_id`s are
//! `glyphwire.PaneSplitHandle`s, but this file never says so: it is pure
//! structure over `u32`, which is what keeps it unit-testable without a
//! server and unchanged by the move from layer-panes to context-panes.
//!
//! **Binary, not N-ary** (user's call): splitting a pane always turns one
//! leaf into a 2-child `Split`; closing a pane always removes a leaf and
//! promotes its sibling subtree up into the parent's place. Every
//! internal node therefore has exactly one divider, which is what makes
//! keyboard resize ("grow the focused pane along its parent's axis")
//! unambiguous -- there's only ever one neighbour to grow into.
//!
//! **Minimal edits, not a rebuild-the-whole-tree-every-time approach.**
//! glyphwire has no way to read a split's current (possibly
//! mouse-dragged) child weights back, so `ui.zig` must never call
//! `set_pane_split_children` on a node it isn't actually changing --
//! doing so would silently reset a divider the user just dragged back to
//! a 1:1 split. `SplitNode.wire_id` is scratch space for `ui.zig` to
//! track which live pane-split handle each node corresponds to, so a
//! `split`/`kill` touches only the nodes on the direct path between the
//! edit and its nearest surviving ancestor -- everywhere else in the tree
//! is untouched, wire handle and all.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Axis = enum { row, column };
pub const PaneId = u32;

/// One node: a pane, or a 2-way split of two subtrees.
pub const Node = union(enum) {
    leaf: PaneId,
    split: SplitNode,

    fn destroyTree(node: *Node, alloc: Allocator) void {
        switch (node.*) {
            .leaf => {},
            .split => |*s| {
                s.a.destroyTree(alloc);
                alloc.destroy(s.a);
                s.b.destroyTree(alloc);
                alloc.destroy(s.b);
            },
        }
        node.* = undefined;
    }
};

pub const SplitNode = struct {
    axis: Axis,
    a: *Node,
    b: *Node,
    /// The `create_pane_split` handle this node currently maps to on the
    /// wire, or 0 before `ui.zig` has created one. Never read or written by
    /// this file except to carry it along during a structural edit --
    /// see the module doc comment.
    wire_id: u32 = 0,
};

/// A pane leaf, or a live split, described by whatever it currently is --
/// what `set_pane_split_children` wants for one child slot. Reads straight off
/// a `Node` with no allocation.
pub const ChildRef = union(enum) { pane: PaneId, split: u32 };

pub fn childRef(node: *const Node) ChildRef {
    return switch (node.*) {
        .leaf => |id| .{ .pane = id },
        .split => |*s| .{ .split = s.wire_id },
    };
}

/// The two child refs of a split node, in `a`/`b` order -- what a caller
/// pushes via `set_pane_split_children` after touching either child.
pub fn childRefs(s: *const SplitNode) [2]ChildRef {
    return .{ childRef(s.a), childRef(s.b) };
}

pub const SplitResult = struct {
    /// The freshly-allocated `.split` node now sitting where `pane`'s leaf
    /// used to be. Its `wire_id` is 0 -- the caller creates the real split
    /// and fills it in before pushing anything that references it.
    node: *Node,
    /// The node's parent, if `pane` had one -- the caller pushes this
    /// parent's (unchanged otherwise) children after the new split has a
    /// wire id. Null means `pane` was the tree root: `tree.root` now
    /// points at `node`, and the caller installs it as the wire root
    /// directly instead (no parent to notify).
    parent: ?*SplitNode,
};

pub const RemoveResult = struct {
    /// The node that takes the killed pane's parent's place -- the
    /// sibling subtree, promoted up. Already reparented in the tree
    /// (`tree.root` or the grandparent's slot points at it); the caller
    /// only need push whichever of those two is now stale.
    sibling: *Node,
    /// The killed pane's grandparent, if one exists. Null means the
    /// killed pane's *parent* was the tree root, so `sibling` is now
    /// `tree.root` and the caller installs it as the wire root.
    parent: ?*SplitNode,
    /// The wire handle of the split node that was removed (the killed
    /// pane's immediate parent) -- the caller `destroy_split`s it after
    /// repointing whatever referenced it.
    removed_wire_id: u32,
};

pub const TreeError = error{
    OutOfMemory,
    /// `pane` doesn't name a leaf in this tree.
    UnknownPane,
    /// `removeLeaf` on the tree's one and only pane -- there's no sibling
    /// to promote. The caller decides what "closing the last pane" means
    /// (quit gmux); the tree is left untouched.
    LastPane,
};

pub const Tree = struct {
    alloc: Allocator,
    /// Never null after `init`. A single pane is a bare `.leaf` (no
    /// synthetic wrapper split in the *structure* -- `ui.zig` wraps one
    /// only when it needs an actual wire root, since
    /// `set_root_pane_split` requires a split handle even for one pane).
    root: *Node,

    pub fn init(alloc: Allocator, first_pane: PaneId) !Tree {
        const root = try alloc.create(Node);
        root.* = .{ .leaf = first_pane };
        return .{ .alloc = alloc, .root = root };
    }

    pub fn deinit(self: *Tree) void {
        self.root.destroyTree(self.alloc);
        self.alloc.destroy(self.root);
        self.* = undefined;
    }

    pub fn leafCount(self: *const Tree) usize {
        return countLeaves(self.root);
    }

    fn countLeaves(node: *const Node) usize {
        return switch (node.*) {
            .leaf => 1,
            .split => |*s| countLeaves(s.a) + countLeaves(s.b),
        };
    }

    /// The first leaf found by always descending into `a` -- used to pick
    /// a new focus after a structural edit when the caller doesn't have a
    /// more specific one in mind (e.g. "nearest in that direction").
    pub fn firstLeaf(node: *const Node) PaneId {
        return switch (node.*) {
            .leaf => |id| id,
            .split => |*s| firstLeaf(s.a),
        };
    }

    /// Appends every pane id in the tree, left-to-right / top-to-bottom
    /// (`a` before `b`). Order isn't meaningful beyond "deterministic" --
    /// used by tests and by `ui.zig` to size/show every pane at startup.
    pub fn collectLeaves(self: *const Tree, out: *std.ArrayList(PaneId), out_alloc: Allocator) !void {
        try collectFrom(self.root, out, out_alloc);
    }
    fn collectFrom(node: *const Node, out: *std.ArrayList(PaneId), out_alloc: Allocator) !void {
        switch (node.*) {
            .leaf => |id| try out.append(out_alloc, id),
            .split => |*s| {
                try collectFrom(s.a, out, out_alloc);
                try collectFrom(s.b, out, out_alloc);
            },
        }
    }

    const Located = struct { node: *Node, parent: ?*SplitNode };

    /// Finds `pane`'s leaf node and, if it has one, its parent split.
    fn locate(self: *Tree, pane: PaneId) ?Located {
        return locateFrom(self.root, null, pane);
    }
    fn locateFrom(node: *Node, parent: ?*SplitNode, pane: PaneId) ?Located {
        switch (node.*) {
            .leaf => |id| if (id == pane) return .{ .node = node, .parent = parent } else return null,
            .split => |*s| {
                if (locateFrom(s.a, s, pane)) |found| return found;
                return locateFrom(s.b, s, pane);
            },
        }
    }

    /// Splits `pane`'s leaf into a fresh `Split(axis)` holding `pane` (as
    /// `a`) and `new_pane` (as `b`). See `SplitResult`.
    pub fn splitLeaf(self: *Tree, pane: PaneId, new_pane: PaneId, axis: Axis) TreeError!SplitResult {
        const found = self.locate(pane) orelse return TreeError.UnknownPane;

        const a = try self.alloc.create(Node);
        errdefer self.alloc.destroy(a);
        a.* = .{ .leaf = pane };
        const b = try self.alloc.create(Node);
        errdefer self.alloc.destroy(b);
        b.* = .{ .leaf = new_pane };

        // `found.node` is the old `.leaf(pane)` -- overwritten in place so
        // the parent's `a`/`b` pointer (which already points at this
        // address) doesn't need touching at all.
        found.node.* = .{ .split = .{ .axis = axis, .a = a, .b = b } };
        return .{ .node = found.node, .parent = found.parent };
    }

    /// Removes `pane`'s leaf and promotes its sibling subtree into the
    /// place its parent split used to occupy. See `RemoveResult`.
    /// `error.LastPane` (tree untouched) if `pane` is the tree's only
    /// leaf -- there's no parent split to collapse.
    pub fn removeLeaf(self: *Tree, pane: PaneId) TreeError!RemoveResult {
        const found = self.locate(pane) orelse return TreeError.UnknownPane;
        const parent_split = found.parent orelse return TreeError.LastPane;

        const sibling: *Node = if (parent_split.a == found.node) parent_split.b else parent_split.a;
        const removed_wire_id = parent_split.wire_id;

        // The parent SplitNode's storage lives inside whatever `*Node` its
        // own parent (the grandparent) points at, at the same address --
        // find that address (or the tree root) and repoint it at
        // `sibling`, then free the vacated leaf and the parent's own
        // `Node` box (but not `sibling`, which is now reparented).
        const grandparent = self.locateParentOf(parent_split);

        self.alloc.destroy(found.node); // the killed pane's leaf Node

        if (grandparent) |gp| {
            if (gp.a == asNode(parent_split)) gp.a = sibling else gp.b = sibling;
        } else {
            self.root = sibling;
        }
        // Free the old parent split's own Node box (the union value at
        // that address is stale now that `sibling` replaced it in the
        // tree) -- `asNode` recovers the `*Node` from the `*SplitNode`
        // it's the active field of.
        self.alloc.destroy(asNode(parent_split));

        return .{ .sibling = sibling, .parent = grandparent, .removed_wire_id = removed_wire_id };
    }

    /// Recovers the enclosing `*Node` for a `*SplitNode` known to be that
    /// node's active `.split` field -- safe because `SplitNode` is never
    /// constructed except as `Node.split`'s payload, so it's always the
    /// first (and only) field of that union at the same address.
    fn asNode(s: *SplitNode) *Node {
        return @fieldParentPtr("split", s);
    }

    pub const Slot = enum { a, b };

    /// `pane`'s immediate parent split and which of its two slots `pane`
    /// occupies -- what a keyboard resize command needs (the parent's
    /// axis, and which sign of `move_divider`'s `delta` grows `pane`).
    /// Null if `pane` is the tree's sole root (no parent to resize
    /// against).
    pub fn parentOf(self: *Tree, pane: PaneId) ?struct { parent: *SplitNode, slot: Slot } {
        const found = self.locate(pane) orelse return null;
        const p = found.parent orelse return null;
        return .{ .parent = p, .slot = if (p.a == found.node) .a else .b };
    }

    /// `parent_split`'s own parent split, if any -- a second tree walk
    /// (rather than threading parent pointers everywhere) since the tree
    /// stays small (one node per pane split) and this only runs on a kill.
    fn locateParentOf(self: *Tree, target: *SplitNode) ?*SplitNode {
        return searchParentOf(self.root, null, target);
    }
    fn searchParentOf(node: *Node, parent: ?*SplitNode, target: *SplitNode) ?*SplitNode {
        switch (node.*) {
            .leaf => return null,
            .split => |*s| {
                if (s == target) return parent;
                if (searchParentOf(s.a, s, target)) |found| return found;
                return searchParentOf(s.b, s, target);
            },
        }
    }
};
