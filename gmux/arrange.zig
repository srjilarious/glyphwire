// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: GPL-3.0-or-later

//! Layout mode's half that needs no server: where a dragged pane would
//! land, what to highlight for it, and the tree edit a drop makes. `ui.zig`
//! turns the edited tree back into wire calls (`Ui.syncWire`).
//!
//! **Drop zones.** Over another pane, the quarter nearest each edge drops
//! the dragged pane beside it on that side, and the middle swaps the two.
//! The outermost `window_edge_cells` of the window drop it as a new
//! full-height column or full-width row there instead, which is the only
//! way to get a pane out from under the root split. The pane being dragged
//! is no target: dropping it on itself does nothing.
//!
//! **Sizes after a drop.** The tree is binary, so a pane dropped between
//! two others in a column would naively get half of one of them (50/25/25).
//! Instead every split in the same-axis run the pane lands in is evened
//! out: each item of the run -- a pane, or a subtree split the other way --
//! gets an equal share. The run it left is evened the same way, so pulling
//! one of four columns out leaves three even ones rather than one that
//! swallowed its neighbour's slot. Every other split keeps the ratio the
//! user gave it, measured off the panes' rects from before the move
//! (`childWeights`), since a resync re-sends every split's children.

const std = @import("std");
const splittree = @import("applib").splittree;
const layout = @import("layout.zig");

const PaneId = layout.PaneId;
const Tree = layout.Tree;
const Node = layout.Node;
pub const Rect = splittree.Rect;

/// How close to the window's border the pointer must be for a window-edge
/// drop, in cells.
pub const window_edge_cells: usize = 1;

pub const Edge = enum {
    left,
    right,
    top,
    bottom,

    /// The split axis a drop on this edge makes: beside is a row, above
    /// or below a column.
    pub fn axis(self: Edge) layout.Axis {
        return switch (self) {
            .left, .right => .row,
            .top, .bottom => .column,
        };
    }

    /// Which half of the new split the dropped pane takes.
    pub fn side(self: Edge) splittree.Side {
        return switch (self) {
            .left, .top => .before,
            .right, .bottom => .after,
        };
    }
};

pub const Zone = union(enum) {
    edge: Edge,
    center,
};

/// Where a drop would go.
pub const Drop = union(enum) {
    /// Beside `pane` on `zone`'s side, or swapped with it at the centre.
    pane: struct { pane: PaneId, zone: Zone },
    /// A new column or row along a window edge.
    window: Edge,

    pub fn eql(a: Drop, b: Drop) bool {
        return switch (a) {
            .pane => |p| switch (b) {
                .pane => |q| p.pane == q.pane and std.meta.eql(p.zone, q.zone),
                .window => false,
            },
            .window => |e| switch (b) {
                .window => |f| e == f,
                .pane => false,
            },
        };
    }
};

pub const PaneRect = struct { pane: PaneId, rect: Rect };

/// The zone of `rect` that cell (`row`, `col`) falls in: the middle half
/// on both axes is the centre, anything else the nearest edge. Distances
/// are compared as fractions of the pane's size, so a wide, short pane
/// still has a left and right zone and not just a top and bottom one.
pub fn zoneIn(rect: Rect, row: usize, col: usize) Zone {
    const fx = (@as(f32, @floatFromInt(col -| rect.col)) + 0.5) / @as(f32, @floatFromInt(@max(rect.cols, 1)));
    const fy = (@as(f32, @floatFromInt(row -| rect.row)) + 0.5) / @as(f32, @floatFromInt(@max(rect.rows, 1)));
    if (fx > 0.25 and fx < 0.75 and fy > 0.25 and fy < 0.75) return .center;
    const dists = [_]struct { d: f32, e: Edge }{
        .{ .d = fx, .e = .left },
        .{ .d = 1 - fx, .e = .right },
        .{ .d = fy, .e = .top },
        .{ .d = 1 - fy, .e = .bottom },
    };
    var best = dists[0];
    for (dists[1..]) |c| if (c.d < best.d) {
        best = c;
    };
    return .{ .edge = best.e };
}

/// What a drop at window cell (`row`, `col`) would do with `dragged`, or
/// null for nothing (over the dragged pane itself, or a divider band).
pub fn dropAt(panes: []const PaneRect, window: Rect, dragged: PaneId, row: usize, col: usize) ?Drop {
    if (panes.len < 2) return null;
    if (col < window.col + window_edge_cells) return .{ .window = .left };
    if (col + window_edge_cells >= window.col + window.cols) return .{ .window = .right };
    if (row < window.row + window_edge_cells) return .{ .window = .top };
    if (row + window_edge_cells >= window.row + window.rows) return .{ .window = .bottom };
    for (panes) |p| {
        if (!contains(p.rect, row, col)) continue;
        if (p.pane == dragged) return null;
        return .{ .pane = .{ .pane = p.pane, .zone = zoneIn(p.rect, row, col) } };
    }
    return null;
}

fn contains(r: Rect, row: usize, col: usize) bool {
    return row >= r.row and row < r.row + r.rows and col >= r.col and col < r.col + r.cols;
}

/// The cells to wash for `drop`: the half of the target pane the dropped
/// one will take, all of it for a swap, and for a window edge the strip a
/// new item of `root_run` would get once the run is evened out.
pub fn highlight(drop: Drop, panes: []const PaneRect, window: Rect, root_run: usize) Rect {
    switch (drop) {
        .pane => |p| {
            const r = for (panes) |pr| {
                if (pr.pane == p.pane) break pr.rect;
            } else return .{};
            return switch (p.zone) {
                .center => r,
                .edge => |e| part(r, e, 2),
            };
        },
        .window => |e| return part(window, e, root_run + 1),
    }
}

/// One `n`th of `r` against edge `e`.
fn part(r: Rect, e: Edge, n: usize) Rect {
    var out = r;
    switch (e) {
        .left, .right => out.cols = @max(r.cols / n, 1),
        .top, .bottom => out.rows = @max(r.rows / n, 1),
    }
    switch (e) {
        .right => out.col = r.col + r.cols - out.cols,
        .bottom => out.row = r.row + r.rows - out.rows,
        else => {},
    }
    return out;
}

// ── Tree edits ──────────────────────────────────────────────────────────

/// What `move` did, for `ui.zig` to put on the wire.
pub const Moved = struct {
    /// The split the drop created (its handle is the one passed in).
    made: *Node,
    /// The split the dragged pane left, now gone: destroy it on the host.
    removed_handle: u32,
    /// The runs to even out (`evenedTop`): the one the pane landed in,
    /// and the one it left, if that still exists.
    runs: [2]?Run,
};

/// A same-axis run of splits, by its top-most split.
pub const Run = struct { top: *Node, axis: layout.Axis };

/// Moves `dragged` to `drop`, a split-making drop (not a centre swap; see
/// `Tree.swapLeaves`), under the host split `handle` already created for
/// it. The tree must hold at least two panes and `dragged` must not be
/// the drop's target.
pub fn move(tree: *Tree, dragged: PaneId, drop: Drop, handle: u32) !Moved {
    const leaf = tree.find(dragged) orelse return error.UnknownLeaf;
    const left_axis = (leaf.parent orelse return error.LastLeaf).kind.split.axis;
    const removal = try tree.remove(dragged);

    const made = switch (drop) {
        .pane => |p| switch (p.zone) {
            .edge => |e| try tree.split(p.pane, dragged, e.axis(), handle, e.side()),
            .center => unreachable, // a swap, not a move
        },
        .window => |e| try tree.wrapRoot(dragged, e.axis(), handle, e.side()),
    };
    const landed = made.kind.split.axis;

    // The run the pane left: the node that took its split's place, if it
    // is a split along the same axis, else its parent if that one is.
    // Found after the insert, since a drop next to that very node can
    // turn it from a leaf into a split.
    const r = removal.replacement;
    const left_from: ?*Node = blk: {
        if (r.kind == .split and r.kind.split.axis == left_axis) break :blk r;
        if (r.parent) |p| if (p.kind.split.axis == left_axis) break :blk p;
        break :blk null;
    };
    return .{
        .made = made,
        .removed_handle = removal.handle,
        .runs = .{
            .{ .top = runTop(made, landed), .axis = landed },
            if (left_from) |n| .{ .top = runTop(n, left_axis), .axis = left_axis } else null,
        },
    };
}

/// The top-most split of `node`'s same-axis run: climbs while the parent
/// splits the same way.
pub fn runTop(node: *Node, axis: layout.Axis) *Node {
    var n = node;
    while (n.parent) |p| {
        if (p.kind.split.axis != axis) break;
        n = p;
    }
    return n;
}

/// How many items the run under `node` holds along `axis`: a split that
/// way is the sum of its children, anything else one item.
pub fn runItems(node: *const Node, axis: layout.Axis) usize {
    return switch (node.kind) {
        .leaf => 1,
        .split => |s| if (s.axis != axis) 1 else runItems(s.first, axis) + runItems(s.second, axis),
    };
}

/// How many items a window-edge drop along `axis` joins: the root's run,
/// less `dragged` itself when it is one of them, since it leaves that run
/// before it lands. What the highlight divides the window by.
pub fn windowRun(tree: *const Tree, dragged: PaneId, axis: layout.Axis) usize {
    const n = runItems(tree.root, axis);
    const leaf = tree.find(dragged) orelse return n;
    if (leaf.parent == null) return n;
    var p = leaf.parent;
    while (p) |q| : (p = q.parent) {
        if (q.kind.split.axis != axis) return n;
    }
    return n - 1;
}

/// Every split node under `node`, parents before children.
pub fn splitNodes(alloc: std.mem.Allocator, node: *Node, out: *std.ArrayList(*Node)) !void {
    switch (node.kind) {
        .leaf => {},
        .split => |s| {
            try out.append(alloc, node);
            try splitNodes(alloc, s.first, out);
            try splitNodes(alloc, s.second, out);
        },
    }
}

/// The run `split` belongs to among `runs`, if any.
fn runOf(split: *Node, runs: []const ?Run) ?Run {
    const axis = split.kind.split.axis;
    const top = runTop(split, axis);
    for (runs) |maybe| {
        const r = maybe orelse continue;
        if (r.top == top and r.axis == axis) return r;
    }
    return null;
}

/// The two weights to send for split `node`'s children. In an evened run,
/// each child's item count; otherwise each child's extent along the axis
/// as it was on screen before the move, measured over its panes' old
/// rects in `bounds` -- leaving out `moved`, whose old rect is somewhere
/// else entirely. A child nothing can be measured for gets weight 1.
pub fn childWeights(node: *Node, runs: []const ?Run, bounds: *const std.AutoHashMap(PaneId, Rect), moved: ?PaneId) [2]f32 {
    const s = node.kind.split;
    if (runOf(node, runs) != null) {
        return .{ @floatFromInt(runItems(s.first, s.axis)), @floatFromInt(runItems(s.second, s.axis)) };
    }
    const a = extent(s.first, s.axis, bounds, moved);
    const b = extent(s.second, s.axis, bounds, moved);
    if (a == 0 or b == 0) return .{ 1, 1 };
    return .{ @floatFromInt(a), @floatFromInt(b) };
}

/// The span along `axis` of every pane under `node` but `moved`.
fn extent(node: *const Node, axis: layout.Axis, bounds: *const std.AutoHashMap(PaneId, Rect), moved: ?PaneId) usize {
    var lo: usize = std.math.maxInt(usize);
    var hi: usize = 0;
    span(node, axis, bounds, moved, &lo, &hi);
    return if (hi > lo) hi - lo else 0;
}

fn span(node: *const Node, axis: layout.Axis, bounds: *const std.AutoHashMap(PaneId, Rect), moved: ?PaneId, lo: *usize, hi: *usize) void {
    switch (node.kind) {
        .leaf => |id| {
            if (moved == id) return;
            const r = bounds.get(id) orelse return;
            if (r.cols == 0 or r.rows == 0) return;
            const start, const len = switch (axis) {
                .row => .{ r.col, r.cols },
                .column => .{ r.row, r.rows },
            };
            lo.* = @min(lo.*, start);
            hi.* = @max(hi.*, start + len);
        },
        .split => |s| {
            span(s.first, axis, bounds, moved, lo, hi);
            span(s.second, axis, bounds, moved, lo, hi);
        },
    }
}
