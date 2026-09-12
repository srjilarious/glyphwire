const std = @import("std");
const testz = @import("testz");
const gmux = @import("gmux_support");

const layout = gmux.layout;

fn expectLeaf(node: *const layout.Node, want: layout.PaneId) !void {
    switch (node.*) {
        .leaf => |id| try testz.expectEqual(id, want),
        .split => try testz.fail(),
    }
}

fn expectChildRefPane(ref: layout.ChildRef, want: layout.PaneId) !void {
    switch (ref) {
        .pane => |id| try testz.expectEqual(id, want),
        .split => try testz.fail(),
    }
}

fn expectChildRefSplit(ref: layout.ChildRef, want: u32) !void {
    switch (ref) {
        .split => |id| try testz.expectEqual(id, want),
        .pane => try testz.fail(),
    }
}

pub fn initIsABareLeafTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var tree = try layout.Tree.init(alloc, 1);
    defer tree.deinit();

    try testz.expectEqual(tree.leafCount(), 1);
    try testz.expectEqual(layout.Tree.firstLeaf(tree.root), 1);
    try expectLeaf(tree.root, 1);
}

pub fn collectLeavesReturnsAToBOrderTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var tree = try layout.Tree.init(alloc, 1);
    defer tree.deinit();
    _ = try tree.splitLeaf(1, 2, .row);

    var out: std.ArrayList(layout.PaneId) = .empty;
    defer out.deinit(alloc);
    try tree.collectLeaves(&out, alloc);
    try testz.expectEqual(out.items.len, 2);
    try testz.expectEqual(out.items[0], 1);
    try testz.expectEqual(out.items[1], 2);
}

pub fn splitAtRootHasNoParentAndReportsARootNodeTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var tree = try layout.Tree.init(alloc, 1);
    defer tree.deinit();

    const result = try tree.splitLeaf(1, 2, .column);
    try testz.expectTrue(result.parent == null);
    try testz.expectTrue(tree.root == result.node);
    try testz.expectEqual(tree.leafCount(), 2);

    switch (tree.root.*) {
        .split => |s| {
            try testz.expectEqual(s.axis, layout.Axis.column);
            try expectLeaf(s.a, 1);
            try expectLeaf(s.b, 2);
            try testz.expectEqual(s.wire_id, 0); // caller fills this in
        },
        .leaf => try testz.fail(),
    }
}

pub fn splittingAgainReturnsTheImmediateParentTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var tree = try layout.Tree.init(alloc, 1);
    defer tree.deinit();
    const first = try tree.splitLeaf(1, 2, .row);
    first.node.split.wire_id = 10; // pretend `ui.zig` already created the wire split

    // Splitting pane 2 (the `b` child of the root split) should report
    // that same root split back as the parent to notify.
    const second = try tree.splitLeaf(2, 3, .column);
    try testz.expectTrue(second.parent != null);
    try testz.expectEqual(second.parent.?.wire_id, 10);
    try testz.expectEqual(tree.leafCount(), 3);

    var out: std.ArrayList(layout.PaneId) = .empty;
    defer out.deinit(alloc);
    try tree.collectLeaves(&out, alloc);
    try testz.expectEqual(out.items.len, 3);
    try testz.expectEqual(out.items[0], 1);
    try testz.expectEqual(out.items[1], 2);
    try testz.expectEqual(out.items[2], 3);
}

pub fn splitOnAnUnknownPaneIsAnErrorTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var tree = try layout.Tree.init(alloc, 1);
    defer tree.deinit();
    try testz.expectError(tree.splitLeaf(99, 2, .row), layout.TreeError.UnknownPane);
}

pub fn removingTheOnlyPaneIsAnErrorAndLeavesTheTreeUntouchedTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var tree = try layout.Tree.init(alloc, 1);
    defer tree.deinit();
    try testz.expectError(tree.removeLeaf(1), layout.TreeError.LastPane);
    try testz.expectEqual(tree.leafCount(), 1);
}

/// Killing one of two panes at the root promotes the sibling to be the
/// new tree root (no grandparent to notify).
pub fn removeAtRootPromotesTheSiblingToRootTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var tree = try layout.Tree.init(alloc, 1);
    defer tree.deinit();
    const split = try tree.splitLeaf(1, 2, .row);
    split.node.split.wire_id = 7;

    const removal = try tree.removeLeaf(2);
    try testz.expectTrue(removal.parent == null);
    try testz.expectEqual(removal.removed_wire_id, 7);
    try expectLeaf(removal.sibling, 1);
    try testz.expectTrue(tree.root == removal.sibling);
    try testz.expectEqual(tree.leafCount(), 1);
}

/// Killing a pane two levels deep promotes its sibling subtree into the
/// grandparent's slot -- the grandparent's *other* child (a third pane)
/// is left completely alone, wire_id included.
pub fn removeDeepPromotesSiblingIntoGrandparentTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var tree = try layout.Tree.init(alloc, 1);
    defer tree.deinit();
    const outer = try tree.splitLeaf(1, 2, .row); // root: [1 | 2]
    outer.node.split.wire_id = 100;
    const inner = try tree.splitLeaf(2, 3, .column); // root: [1 | [2 / 3]]
    inner.node.split.wire_id = 200;

    const removal = try tree.removeLeaf(3);
    try testz.expectEqual(removal.removed_wire_id, 200);
    try expectLeaf(removal.sibling, 2);
    // The grandparent is the outer (root) split, untouched by this edit
    // except for the one slot that used to point at `inner`.
    try testz.expectTrue(removal.parent != null);
    try testz.expectEqual(removal.parent.?.wire_id, 100);
    try expectLeaf(removal.parent.?.a, 1);
    try expectLeaf(removal.parent.?.b, 2);
    try testz.expectEqual(tree.leafCount(), 2);

    var out: std.ArrayList(layout.PaneId) = .empty;
    defer out.deinit(alloc);
    try tree.collectLeaves(&out, alloc);
    try testz.expectEqual(out.items.len, 2);
    try testz.expectEqual(out.items[0], 1);
    try testz.expectEqual(out.items[1], 2);
}

pub fn removeOnAnUnknownPaneIsAnErrorTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var tree = try layout.Tree.init(alloc, 1);
    defer tree.deinit();
    _ = try tree.splitLeaf(1, 2, .row);
    try testz.expectError(tree.removeLeaf(99), layout.TreeError.UnknownPane);
}

pub fn childRefsReadsCurrentChildrenTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var tree = try layout.Tree.init(alloc, 1);
    defer tree.deinit();
    const split = try tree.splitLeaf(1, 2, .row);
    split.node.split.wire_id = 42;
    const nested = try tree.splitLeaf(2, 3, .column);
    nested.node.split.wire_id = 43;

    const refs = layout.childRefs(&split.node.split);
    try expectChildRefPane(refs[0], 1);
    try expectChildRefSplit(refs[1], 43);
}
