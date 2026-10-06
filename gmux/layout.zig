// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: GPL-3.0-or-later

//! gmux's pane-arrangement tree: `applib/splittree.zig` over pane ids,
//! with `ui.zig` as the half that turns a mutation into the matching
//! `create_pane_split` / `set_pane_split_children` / `set_root_pane_split`
//! / `destroy_pane_split` wire calls. See `splittree` for why it is
//! binary and why an edit re-sends only the child lists it changed.
//!
//! The ids are real `glyphwire.PaneHandle`s and a split's handle a
//! `glyphwire.PaneSplitHandle`, but this file only says `u32`, which is
//! what keeps it unit-testable without a server.

const splittree = @import("applib").splittree;

pub const Axis = enum { row, column };
pub const PaneId = u32;

/// A split's `handle` is the `create_pane_split` handle it maps to on the
/// wire. A single pane is a bare leaf root: `ui.zig` wraps one in a wire
/// split only when it needs an actual root, since `set_root_pane_split`
/// takes a split handle even for one pane.
pub const Tree = splittree.SplitTree(PaneId, Axis, u32);
pub const Node = Tree.Node;

/// A pane leaf, or a live split, described by whatever it currently is --
/// what `set_pane_split_children` wants for one child slot.
pub const ChildRef = union(enum) { pane: PaneId, split: u32 };

pub fn childRef(node: *const Node) ChildRef {
    return switch (node.kind) {
        .leaf => |id| .{ .pane = id },
        .split => |s| .{ .split = s.handle },
    };
}

/// The two child refs of split node `node`, first then second -- what a
/// caller pushes via `set_pane_split_children` after touching either
/// child.
pub fn childRefs(node: *const Node) [2]ChildRef {
    const s = node.kind.split;
    return .{ childRef(s.first), childRef(s.second) };
}
