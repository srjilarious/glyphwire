// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: GPL-3.0-or-later

//! How zoe's editor groups are arranged: the binary tree `:vsplit` /
//! `:split` grow and `:close` shrinks, and the geometry Ctrl+hjkl uses
//! to move between them. Both are `applib/splittree.zig`; this file names
//! them in zoe's terms.
//!
//! An editor group is one tab strip over one buffer pane (`Group` in
//! `zoe/ui.zig`). The tree knows them only by id, and `ui.zig` turns what
//! an edit reports into `create_split` / `set_split_children` /
//! `destroy_split` calls. Every split is one host split with two
//! children, created `resizable` so the user can drag the band between
//! them; see `splittree` for why it stays binary (vim's n-ary `:vsplit`
//! would mean re-sending lists whose proportions the user dragged).

const std = @import("std");
const glyphwire = @import("glyphwire");
const splittree = @import("applib").splittree;

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

pub const Layout = splittree.SplitTree(GroupId, Orientation, glyphwire.SplitHandle);
pub const Node = Layout.Node;
pub const Side = splittree.Side;

/// A group's whole on-screen area (tab strip and buffer pane) in cells.
pub const Rect = splittree.Rect;
pub const Direction = splittree.Direction;
pub const neighbor = splittree.neighbor;
