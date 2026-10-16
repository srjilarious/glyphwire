// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: GPL-3.0-or-later

//! `applib/splittree.zig`, the binary split tree gmux's panes and zoe's
//! editor groups both are, and `neighbor`, their directional focus.

const std = @import("std");
const testz = @import("testz");
const splittree = @import("applib").splittree;

const Axis = enum { row, column };
const Tree = splittree.SplitTree(u32, Axis, u32);

fn order(alloc: std.mem.Allocator, tree: *const Tree) ![]u32 {
    var out: std.ArrayList(u32) = .empty;
    try tree.leavesInOrder(alloc, &out);
    return out.toOwnedSlice(alloc);
}

pub fn initIsABareLeafTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var tree = try Tree.init(alloc, 1);
    defer tree.deinit();
    try testz.expectEqual(tree.count(), 1);
    try testz.expectEqual(tree.root.firstLeaf(), 1);
    try testz.expectEqual(tree.root.kind.leaf, 1);
    try testz.expectTrue(tree.root.slot() == null);
}

pub fn splitTurnsTheLeafIntoASplitInPlaceTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var tree = try Tree.init(alloc, 1);
    defer tree.deinit();
    const root_before = tree.root;

    const s = try tree.split(1, 2, .row, 100, .after);
    // In place: the root node is still the root, now a split, so its
    // parent's pointer (here, the root slot) never changes.
    try testz.expectTrue(s == root_before);
    try testz.expectTrue(s.parent == null);
    try testz.expectEqual(s.kind.split.handle, 100);
    try testz.expectEqual(s.kind.split.axis, .row);
    try testz.expectEqual(tree.count(), 2);

    // Splitting the second half again nests under it and reports it as
    // the parent whose list changed.
    const inner = try tree.split(2, 3, .column, 101, .after);
    try testz.expectTrue(inner.parent.? == s);
    try testz.expectTrue(inner.slot().? == .second);
    const ids = try order(alloc, &tree);
    defer alloc.free(ids);
    try testz.expectEqual(ids.len, 3);
    try testz.expectEqual(ids[0], 1);
    try testz.expectEqual(ids[1], 2);
    try testz.expectEqual(ids[2], 3);
}

pub fn splitBeforePutsTheNewLeafFirstTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var tree = try Tree.init(alloc, 1);
    defer tree.deinit();
    // zoe's Ctrl+W Shift+H with nothing to the left: the new group goes left.
    const s = try tree.split(1, 2, .row, 100, .before);
    try testz.expectEqual(s.kind.split.first.kind.leaf, 2);
    try testz.expectEqual(s.kind.split.second.kind.leaf, 1);
    const ids = try order(alloc, &tree);
    defer alloc.free(ids);
    try testz.expectEqual(ids[0], 2);
    try testz.expectEqual(ids[1], 1);
}

pub fn unknownLeafIsAnErrorTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var tree = try Tree.init(alloc, 1);
    defer tree.deinit();
    try testz.expectError(tree.split(99, 2, .row, 100, .after), error.UnknownLeaf);
    _ = try tree.split(1, 2, .row, 100, .after);
    try testz.expectError(tree.remove(99), error.UnknownLeaf);
    try testz.expectEqual(tree.count(), 2);
}

pub fn removingTheOnlyLeafIsAnErrorAndLeavesTheTreeTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var tree = try Tree.init(alloc, 1);
    defer tree.deinit();
    try testz.expectError(tree.remove(1), error.LastLeaf);
    try testz.expectEqual(tree.count(), 1);
    try testz.expectEqual(tree.root.kind.leaf, 1);
}

pub fn removeCollapsesIntoTheSiblingTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var tree = try Tree.init(alloc, 1);
    defer tree.deinit();
    _ = try tree.split(1, 2, .row, 100, .after);
    _ = try tree.split(2, 3, .column, 101, .after);

    // Removing 1: the {2 over 3} subtree takes the whole root, focus goes
    // to its first leaf, and the root's split is the one destroyed.
    const r = try tree.remove(1);
    try testz.expectEqual(r.handle, 100);
    try testz.expectEqual(r.focus, 2);
    try testz.expectTrue(r.replacement == tree.root);
    try testz.expectTrue(tree.root.parent == null);
    try testz.expectEqual(tree.root.kind.split.handle, 101);
    // The moved-up split's children point at their new parent.
    try testz.expectTrue(tree.root.kind.split.first.parent.? == tree.root);
    try testz.expectTrue(tree.root.kind.split.second.parent.? == tree.root);

    const r2 = try tree.remove(3);
    try testz.expectEqual(r2.handle, 101);
    try testz.expectEqual(r2.focus, 2);
    try testz.expectEqual(tree.count(), 1);
    try testz.expectEqual(tree.root.kind.leaf, 2);
}

/// Removing a leaf two levels deep puts its sibling where their split
/// was; the grandparent keeps its other child (and its handle) untouched.
pub fn removeKeepsTheGrandparentLinkTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var tree = try Tree.init(alloc, 1);
    defer tree.deinit();
    _ = try tree.split(1, 2, .row, 100, .after);
    _ = try tree.split(2, 3, .column, 101, .after);

    const r = try tree.remove(3);
    try testz.expectEqual(r.handle, 101);
    try testz.expectTrue(r.replacement.parent.? == tree.root);
    try testz.expectTrue(tree.root.kind.split.second == r.replacement);
    try testz.expectEqual(r.replacement.kind.leaf, 2);
    try testz.expectEqual(tree.root.kind.split.handle, 100);
    try testz.expectEqual(tree.root.kind.split.first.kind.leaf, 1);
}

/// The slot an edit reports is the host child index a caller passes to
/// `replace_*split_child`: a split in place sits where its leaf did, and
/// a removal's replacement where the removed split did.
pub fn slotIndexNamesTheHostChildTest(_: std.Io, alloc: std.mem.Allocator) !void {
    try testz.expectEqual(splittree.Slot.first.index(), 0);
    try testz.expectEqual(splittree.Slot.second.index(), 1);

    var tree = try Tree.init(alloc, 1);
    defer tree.deinit();
    _ = try tree.split(1, 2, .row, 100, .after);
    const inner = try tree.split(1, 3, .column, 101, .before);
    try testz.expectEqual(inner.slot().?.index(), 0);

    const r = try tree.remove(3);
    try testz.expectEqual(r.replacement.slot().?.index(), 0);
}

pub fn neighborPicksTheFacingPaneTest(_: std.Io, _: std.mem.Allocator) !void {
    // [0 | 1]
    // [0 | 2]   -- 0 is full height on the left, 1 over 2 on the right.
    const rects = [_]splittree.Rect{
        .{ .row = 0, .col = 0, .cols = 40, .rows = 30 },
        .{ .row = 0, .col = 41, .cols = 40, .rows = 15 },
        .{ .row = 16, .col = 41, .cols = 40, .rows = 14 },
    };
    try testz.expectEqual(splittree.neighbor(&rects, 1, .left), 0);
    try testz.expectEqual(splittree.neighbor(&rects, 2, .left), 0);
    try testz.expectEqual(splittree.neighbor(&rects, 1, .down), 2);
    try testz.expectEqual(splittree.neighbor(&rects, 2, .up), 1);
    // Nothing above 1, and nothing right of either.
    try testz.expectTrue(splittree.neighbor(&rects, 1, .up) == null);
    try testz.expectTrue(splittree.neighbor(&rects, 1, .right) == null);
    // From the tall pane, the one sharing more of its rows wins.
    try testz.expectEqual(splittree.neighbor(&rects, 0, .right), 1);
}

/// A pane diagonally off to one side isn't "left" of it.
pub fn neighborNeedsOverlapAcrossTheOtherAxisTest(_: std.Io, _: std.mem.Allocator) !void {
    const rects = [_]splittree.Rect{
        .{ .row = 0, .col = 0, .cols = 10, .rows = 10 },
        .{ .row = 20, .col = 20, .cols = 10, .rows = 10 },
    };
    try testz.expectTrue(splittree.neighbor(&rects, 1, .left) == null);
    try testz.expectTrue(splittree.neighbor(&rects, 0, .down) == null);
}

/// gmux's rotate: ids move one leaf along in reading order, the shape and
/// every node staying where it was.
pub fn rotateMovesIdsAlongReadingOrderTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var tree = try Tree.init(alloc, 1);
    defer tree.deinit();
    _ = try tree.split(1, 2, .row, 100, .after);
    _ = try tree.split(2, 3, .column, 101, .after);
    const root = tree.root;

    var leaves: std.ArrayList(*Tree.Node) = .empty;
    defer leaves.deinit(alloc);
    try tree.rotate(alloc, .after, &leaves);
    try testz.expectTrue(tree.root == root);
    try testz.expectEqual(leaves.items.len, 3);
    const fwd = try order(alloc, &tree);
    defer alloc.free(fwd);
    try testz.expectEqual(fwd[0], 3);
    try testz.expectEqual(fwd[1], 1);
    try testz.expectEqual(fwd[2], 2);
    try testz.expectEqual(leaves.items[0].kind.leaf, 3);
    try testz.expectEqual(tree.root.kind.split.handle, 100);

    leaves.clearRetainingCapacity();
    try tree.rotate(alloc, .before, &leaves);
    leaves.clearRetainingCapacity();
    try tree.rotate(alloc, .before, &leaves);
    const back = try order(alloc, &tree);
    defer alloc.free(back);
    try testz.expectEqual(back[0], 2);
    try testz.expectEqual(back[1], 3);
    try testz.expectEqual(back[2], 1);
}

pub fn rotateOnASingleLeafIsANoOpTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var tree = try Tree.init(alloc, 7);
    defer tree.deinit();
    var leaves: std.ArrayList(*Tree.Node) = .empty;
    defer leaves.deinit(alloc);
    try tree.rotate(alloc, .after, &leaves);
    try testz.expectEqual(tree.root.kind.leaf, 7);
}
