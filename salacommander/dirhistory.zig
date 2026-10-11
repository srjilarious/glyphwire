// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: GPL-3.0-or-later

//! Where a pane has been, for the session: Alt+Left/Right step back and
//! forward through it the way a browser does, and Alt+Down lists it.
//!
//! Two lists, because the two jobs want different shapes:
//!
//!   * `trail` -- every directory in the order it was shown, with `pos`
//!     on the one showing now. Back and Forward walk it without changing
//!     it; going anywhere new from the middle drops what was ahead of
//!     `pos`, as a browser drops its forward pages. Each spot remembers
//!     the entry the cursor was on when it was left, so Back lands where
//!     you were.
//!   * `recent` -- each directory once, most recently shown first,
//!     whichever way it was reached. This is what Alt+Down lists, so a
//!     directory dropped from `trail`'s forward end is still there.
//!
//! Both are capped; the oldest falls off. Pure bookkeeping: `Pane` does
//! the loading and tells this what happened.

const std = @import("std");

pub const max_trail = 100;
pub const max_recent = 50;

pub const Spot = struct {
    /// Absolute. Owned.
    path: []u8,
    /// The entry the cursor was on when the pane left here, if any.
    /// Owned.
    cursor: ?[]u8 = null,
};

pub const DirHistory = struct {
    alloc: std.mem.Allocator,
    trail: std.ArrayList(Spot) = .empty,
    /// Index into `trail` of the directory showing now. Meaningless while
    /// `trail` is empty.
    pos: usize = 0,
    /// Owned paths, newest first, no repeats.
    recent: std.ArrayList([]u8) = .empty,

    pub fn init(alloc: std.mem.Allocator) DirHistory {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *DirHistory) void {
        for (self.trail.items) |s| freeSpot(self.alloc, s);
        self.trail.deinit(self.alloc);
        for (self.recent.items) |p| self.alloc.free(p);
        self.recent.deinit(self.alloc);
    }

    /// The pane is leaving the current spot with the cursor on `name`
    /// (null for `..` or an empty listing): remembered for coming back.
    pub fn leave(self: *DirHistory, name: ?[]const u8) !void {
        if (self.trail.items.len == 0) return;
        const spot = &self.trail.items[self.pos];
        const owned = if (name) |n| try self.alloc.dupe(u8, n) else null;
        if (spot.cursor) |old| self.alloc.free(old);
        spot.cursor = owned;
    }

    /// The pane went to `path` some way other than Back/Forward. Anything
    /// ahead of `pos` is dropped and `path` becomes the newest spot --
    /// unless it's where the pane already is (a reload, Alt+O onto the
    /// same directory), which leaves the trail as it was.
    pub fn visit(self: *DirHistory, path: []const u8) !void {
        try self.noteRecent(path);
        if (self.current()) |cur| {
            if (std.mem.eql(u8, cur.path, path)) return;
        }
        const owned = try self.alloc.dupe(u8, path);
        errdefer self.alloc.free(owned);
        if (self.trail.items.len > 0) {
            for (self.trail.items[self.pos + 1 ..]) |s| freeSpot(self.alloc, s);
            self.trail.shrinkRetainingCapacity(self.pos + 1);
        }
        try self.trail.append(self.alloc, .{ .path = owned });
        if (self.trail.items.len > max_trail) {
            freeSpot(self.alloc, self.trail.orderedRemove(0));
        }
        self.pos = self.trail.items.len - 1;
    }

    /// The spot Back would go to, or null at the start of the trail.
    pub fn backTarget(self: *const DirHistory) ?*const Spot {
        if (self.trail.items.len == 0 or self.pos == 0) return null;
        return &self.trail.items[self.pos - 1];
    }

    /// The spot Forward would go to, or null at the end of the trail.
    pub fn forwardTarget(self: *const DirHistory) ?*const Spot {
        if (self.pos + 1 >= self.trail.items.len) return null;
        return &self.trail.items[self.pos + 1];
    }

    /// The pane has loaded `backTarget` (`delta` -1) or `forwardTarget`
    /// (+1): `pos` follows, and the directory counts as just visited
    /// for `recent`.
    pub fn stepped(self: *DirHistory, delta: isize) !void {
        const next: isize = @as(isize, @intCast(self.pos)) + delta;
        std.debug.assert(next >= 0 and next < self.trail.items.len);
        self.pos = @intCast(next);
        try self.noteRecent(self.trail.items[self.pos].path);
    }

    pub fn current(self: *const DirHistory) ?*const Spot {
        if (self.trail.items.len == 0) return null;
        return &self.trail.items[self.pos];
    }

    /// `path` to the front of `recent`, out of wherever it was.
    fn noteRecent(self: *DirHistory, path: []const u8) !void {
        for (self.recent.items, 0..) |p, i| {
            if (!std.mem.eql(u8, p, path)) continue;
            const moved = self.recent.orderedRemove(i);
            try self.recent.insert(self.alloc, 0, moved);
            return;
        }
        const owned = try self.alloc.dupe(u8, path);
        errdefer self.alloc.free(owned);
        try self.recent.insert(self.alloc, 0, owned);
        if (self.recent.items.len > max_recent) self.alloc.free(self.recent.pop().?);
    }
};

fn freeSpot(alloc: std.mem.Allocator, s: Spot) void {
    alloc.free(s.path);
    if (s.cursor) |c| alloc.free(c);
}
