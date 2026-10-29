// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: MPL-2.0

//! The split tree both layouts share: `Context`'s, which places a
//! context's layers (`create_split`, see context.zig's Splits section),
//! and `Session`'s, which places panes in the window
//! (`create_pane_split`). Each owns one `SplitTree` and keeps its own
//! leaf handling -- a layer gets a viewport, a pane gets mapped and its
//! contexts resized -- plus its own error names, change counters and
//! limits, so the two wire APIs stay exactly as they were. What lives
//! here is everything that was written twice: the splits and the root,
//! the extents math, the layout walk with its divider bands, and the
//! divider drag. Review B3.
//!
//! `applib/splittree.zig` is the client-side model of the same idea and
//! stays separate.

const std = @import("std");

/// Which way a split's children run.
pub const SplitAxis = enum {
    /// Left to right, separated by vertical dividers.
    row,
    /// Top to bottom, separated by horizontal dividers.
    column,
};

/// A rectangle in grid cells.
pub const CellRect = struct {
    row: usize = 0,
    col: usize = 0,
    cols: usize = 0,
    rows: usize = 0,

    pub fn contains(self: CellRect, row: usize, col: usize) bool {
        return row >= self.row and row < self.row + self.rows and
            col >= self.col and col < self.col + self.cols;
    }
};

/// How big a child is along its parent's axis. `fixed` children are
/// measured first and `weight` children share what's left. That's what
/// lets a one-row statusline sit beside a pane that takes "the rest"
/// without the client recomputing a fraction every time the window
/// changes height.
pub const Size = union(enum) { weight: f32, fixed: usize };

pub const Limits = struct {
    /// Recursion cap for the layout walk. A tree this deep is a bug or a
    /// cycle; either way the walk stops rather than smashing the stack.
    max_depth: usize,
    /// Smallest extent a divider drag will leave a child, in cells. Below
    /// this a pane can't show anything and can't be grabbed back.
    min_extent: usize,
};

/// A tree of splits whose leaves are whatever `Child.Target`'s non-split
/// variant names. `Child` is a struct with a `target` (a tagged union
/// with a `split` variant holding a `Handle`, and one leaf variant) and a
/// `size: Size`.
pub fn SplitTree(comptime Child: type, comptime limits: Limits) type {
    return struct {
        const Self = @This();

        pub const Handle = u32;
        pub const Target = @FieldType(Child, "target");

        /// One split: its axis and children, and where it was last laid
        /// out.
        pub const Node = struct {
            axis: SplitAxis,
            children: std.ArrayList(Child) = .empty,
            /// Whether the user may drag the bands between this split's
            /// children. When false the split reserves no gap between its
            /// children (the row/column returns to content), emits no
            /// `Divider` for glyphwire-host to draw or hit-test, and
            /// `moveDivider` is a no-op. What a TUI wants for a structural
            /// split like an editor's buffer-area-over-command-line: the
            /// command line is a fixed one-row child and a resize handle
            /// there is just a wasted row.
            resizable: bool = true,
            /// The cell rect this split occupied at the last `layout`.
            /// `moveDivider` needs it to turn a drag in cells back into
            /// sizes, and there is nowhere else to get it: a split has no
            /// size of its own until the tree is laid out.
            last_rect: CellRect = .{},
            laid_out: bool = false,

            pub fn deinit(self: *Node, alloc: std.mem.Allocator) void {
                self.children.deinit(alloc);
            }
        };

        /// A draggable band between two children of a split.
        pub const Divider = struct {
            split: Handle,
            /// The divider *after* child `index`, so `index` and
            /// `index + 1` are the pair it separates and `index` is always
            /// a valid child.
            index: usize,
            axis: SplitAxis,
            rect: CellRect,
        };

        splits: std.AutoHashMap(Handle, Node),
        next_handle: Handle = 1,
        /// Which split fills the area, or null for no layout.
        root: ?Handle = null,

        pub fn init(alloc: std.mem.Allocator) Self {
            return .{ .splits = std.AutoHashMap(Handle, Node).init(alloc) };
        }

        pub fn deinit(self: *Self, alloc: std.mem.Allocator) void {
            var it = self.splits.valueIterator();
            while (it.next()) |s| s.deinit(alloc);
            self.splits.deinit();
        }

        /// An empty split. It lays out nothing until it has children and
        /// is reached from `root`.
        pub fn create(self: *Self, axis: SplitAxis, resizable: bool) !Handle {
            const handle = self.next_handle;
            try self.splits.put(handle, .{ .axis = axis, .resizable = resizable });
            self.next_handle += 1;
            return handle;
        }

        /// Frees the split, clearing `root` if it was the root. Its
        /// children are not touched. False for an unknown handle.
        pub fn destroy(self: *Self, alloc: std.mem.Allocator, handle: Handle) bool {
            var removed = self.splits.fetchRemove(handle) orelse return false;
            removed.value.deinit(alloc);
            if (self.root == handle) self.root = null;
            return true;
        }

        pub fn node(self: *Self, handle: Handle) ?*Node {
            return self.splits.getPtr(handle);
        }

        pub fn contains(self: *const Self, handle: Handle) bool {
            return self.splits.contains(handle);
        }

        /// Replaces `split`'s child list wholesale.
        pub fn setChildren(alloc: std.mem.Allocator, split: *Node, children: []const Child) !void {
            split.children.clearRetainingCapacity();
            try split.children.appendSlice(alloc, children);
        }

        /// Puts `target` in slot `index`, keeping the slot's size unless
        /// `size` says otherwise. False when `index` is past the end.
        pub fn replaceChild(split: *Node, index: usize, target: Target, size: ?Size) bool {
            if (index >= split.children.items.len) return false;
            const slot = &split.children.items[index];
            slot.target = target;
            if (size) |sz| slot.size = sz;
            return true;
        }

        /// Each child's extent along the split's axis as of the last
        /// `layout`, all zero for a split never laid out.
        ///
        /// `out.len` must equal the child count.
        pub fn laidOutExtents(split: *const Node, gap: usize, out: []usize) void {
            if (!split.laid_out) {
                @memset(out, 0);
                return;
            }
            childExtents(split, split.last_rect, gap, out);
        }

        /// Splits `rect`'s extent along the split's axis across its
        /// children: `fixed` children take their cells first, `weight`
        /// children share what's left. The last weighted child absorbs the
        /// rounding remainder, so the children plus dividers always fill
        /// the split exactly rather than leaving a stray blank column.
        /// `gap_cells` is the gap between two children of a resizable
        /// split.
        ///
        /// `out.len` must equal the child count.
        pub fn childExtents(split: *const Node, rect: CellRect, gap_cells: usize, out: []usize) void {
            const n = split.children.items.len;
            const axis_total: usize = if (split.axis == .row) rect.cols else rect.rows;
            const gap: usize = if (split.resizable) gap_cells else 0;
            var remaining = axis_total -| (n - 1) * gap;

            var fixed_total: usize = 0;
            var weight_total: f32 = 0;
            var last_weighted: ?usize = null;
            for (split.children.items, 0..) |c, i| switch (c.size) {
                .fixed => |f| fixed_total += f,
                .weight => |w| {
                    weight_total += @max(w, 0);
                    last_weighted = i;
                },
            };
            const flexible = remaining -| fixed_total;

            var flexible_used: usize = 0;
            for (split.children.items, 0..) |child, i| {
                const want: usize = switch (child.size) {
                    .fixed => |f| f,
                    .weight => |w| blk: {
                        if (weight_total <= 0) break :blk 0;
                        if (i == last_weighted.?) break :blk flexible -| flexible_used;
                        const share_f = @as(f32, @floatFromInt(flexible)) * (@max(w, 0) / weight_total);
                        const share: usize = @intFromFloat(@floor(share_f));
                        flexible_used += share;
                        break :blk share;
                    },
                };
                // Clamped against what's actually left: a client whose
                // fixed children over-subscribe the area gets truncation
                // at the end rather than children placed outside it.
                out[i] = @min(want, remaining);
                remaining -= out[i];
            }
        }

        /// Lays the tree out over `rect`, calling `placer.place(target,
        /// child_rect)` for every leaf it reaches and appending the bands
        /// between children to `dividers` when given. A no-op with no
        /// root.
        pub fn layout(
            self: *Self,
            alloc: std.mem.Allocator,
            rect: CellRect,
            gap: usize,
            placer: anytype,
            dividers: ?*std.ArrayList(Divider),
        ) !void {
            const root = self.root orelse return;
            try self.layoutNode(alloc, root, rect, gap, placer, dividers, 0);
        }

        fn layoutNode(
            self: *Self,
            alloc: std.mem.Allocator,
            handle: Handle,
            rect: CellRect,
            gap_cells: usize,
            placer: anytype,
            dividers: ?*std.ArrayList(Divider),
            depth: usize,
        ) !void {
            // A cycle or a pathologically deep tree stops here rather than
            // running off the stack -- see `Limits.max_depth`.
            if (depth >= limits.max_depth) return;
            const split = self.splits.getPtr(handle) orelse return;
            split.last_rect = rect;
            split.laid_out = true;

            const n = split.children.items.len;
            if (n == 0) return;

            const extents = try alloc.alloc(usize, n);
            defer alloc.free(extents);
            childExtents(split, rect, gap_cells, extents);

            // A non-resizable split leaves no gap between its children and
            // draws no grab band -- see `Node.resizable`.
            const gap: usize = if (split.resizable) gap_cells else 0;

            var pos: usize = if (split.axis == .row) rect.col else rect.row;
            for (split.children.items, 0..) |child, i| {
                const extent = extents[i];
                const child_rect: CellRect = if (split.axis == .row)
                    .{ .row = rect.row, .col = pos, .cols = extent, .rows = rect.rows }
                else
                    .{ .row = pos, .col = rect.col, .cols = rect.cols, .rows = extent };

                if (child.target == .split) {
                    try self.layoutNode(alloc, child.target.split, child_rect, gap_cells, placer, dividers, depth + 1);
                } else {
                    try placer.place(child.target, child_rect);
                }

                pos += extent;
                if (i + 1 < n and gap > 0) {
                    if (dividers) |out| {
                        const band: CellRect = if (split.axis == .row)
                            .{ .row = rect.row, .col = pos, .cols = gap, .rows = rect.rows }
                        else
                            .{ .row = pos, .col = rect.col, .cols = rect.cols, .rows = gap };
                        try out.append(alloc, .{
                            .split = handle,
                            .index = i,
                            .axis = split.axis,
                            .rect = band,
                        });
                    }
                    pos += gap;
                }
            }
        }

        /// Drags the band after child `index` by `delta` cells along the
        /// split's axis, growing one neighbour and shrinking the other.
        /// Returns whether any size changed; the caller re-lays-out.
        ///
        /// How the sizes change depends on how the pair was declared, so
        /// that a drag doesn't silently convert a child's sizing mode: a
        /// `fixed` neighbour keeps its cells and just gets more or fewer
        /// of them, and a `weight` pair keeps its combined weight and
        /// re-splits it by the new ratio (so the rest of the tree is
        /// undisturbed).
        pub fn moveDivider(alloc: std.mem.Allocator, split: *Node, index: usize, delta: i64, gap: usize) bool {
            if (!split.laid_out) return false;
            // A non-resizable split has no draggable bands -- see
            // `Node.resizable`.
            if (!split.resizable) return false;
            const n = split.children.items.len;
            if (index + 1 >= n) return false;
            if (delta == 0) return false;

            const extents = alloc.alloc(usize, n) catch return false;
            defer alloc.free(extents);
            childExtents(split, split.last_rect, gap, extents);

            const before = extents[index];
            const after = extents[index + 1];
            const pair = before + after;
            if (pair < 2 * limits.min_extent) return false;

            // Clamp the drag so neither neighbour is squeezed out of
            // existence -- a pane at zero cells can't be grabbed back.
            const lo: i64 = @intCast(limits.min_extent);
            const hi: i64 = @intCast(pair - limits.min_extent);
            const want: i64 = @as(i64, @intCast(before)) + delta;
            const new_before: usize = @intCast(std.math.clamp(want, lo, hi));
            const new_after = pair - new_before;
            if (new_before == before) return false;

            const a = &split.children.items[index];
            const b = &split.children.items[index + 1];
            const wa: ?f32 = switch (a.size) {
                .weight => |w| @max(w, 0),
                .fixed => null,
            };
            const wb: ?f32 = switch (b.size) {
                .weight => |w| @max(w, 0),
                .fixed => null,
            };

            // A fixed neighbour just gets a new cell count. A weighted one
            // next to a fixed one needs no change at all -- it already
            // absorbs whatever the fixed one leaves.
            if (wa == null) a.size = .{ .fixed = new_before };
            if (wb == null) b.size = .{ .fixed = new_after };
            if (wa != null and wb != null) {
                const total_w = wa.? + wb.?;
                if (total_w <= 0) return false;
                const frac = @as(f32, @floatFromInt(new_before)) / @as(f32, @floatFromInt(pair));
                a.size = .{ .weight = total_w * frac };
                b.size = .{ .weight = total_w * (1 - frac) };
            }
            return true;
        }
    };
}
