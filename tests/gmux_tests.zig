// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: GPL-3.0-or-later

//! gmux's own layer over the split tree. The tree itself is covered in
//! splittree_tests.zig.

const std = @import("std");
const testz = @import("testz");
const gmux = @import("gmux_support");

const layout = gmux.layout;

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

/// What `set_pane_split_children` is sent: a pane child by its pane id, a
/// split child by its wire handle.
pub fn childRefsReadsCurrentChildrenTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var tree = try layout.Tree.init(alloc, 1);
    defer tree.deinit();
    const split = try tree.split(1, 2, .row, 42, .after);
    _ = try tree.split(2, 3, .column, 43, .after);

    const refs = layout.childRefs(split);
    try expectChildRefPane(refs[0], 1);
    try expectChildRefSplit(refs[1], 43);
}
