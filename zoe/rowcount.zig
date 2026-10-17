// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: GPL-3.0-or-later

//! How many screen rows each buffer line wraps into, kept between frames.
//!
//! The buffer pane's host-drawn scrollbar is measured in screen rows, not
//! buffer lines: the host clamps a wheel or thumb drag to `extent - rows`,
//! so an extent of the line count stops a wrapped buffer short of its last
//! screen. Counting rows means wrapping every line once, which is too much
//! to redo per keystroke, so each slot keeps the counts here and follows
//! the buffer's edit journal the way `SpanCache` does:
//!
//!   - Each edit (`applyEdit`) forgets the lines it replaced and shifts
//!     the ones below when it changed the line count.
//!   - Anything that rewraps every line -- a narrower pane, a different
//!     tab width, whitespace shown or not -- changes the `Key`, which
//!     empties the cache wholesale (`sync`).
//!
//! Closed folds are not stored: they hide lines without rewrapping them,
//! so the queries take the hidden ranges and skip over them.

const std = @import("std");
const fold = @import("fold.zig");

pub const RowCounts = struct {
    /// Rows per buffer line; 0 when not computed (a wrapped line is
    /// always at least one row).
    counts: std.ArrayList(u32) = .empty,
    /// The wrapping the counts were taken under.
    key: Key = .{},

    /// What a line's row count depends on besides its own text.
    pub const Key = struct {
        cols: usize = 0,
        tab_width: usize = 0,
        show_whitespace: bool = false,
    };

    pub fn deinit(self: *RowCounts, alloc: std.mem.Allocator) void {
        self.counts.deinit(alloc);
        self.* = undefined;
    }

    /// Forgets every count *and* the line slots, so the next `sync`
    /// sizes the cache afresh. For when an edit couldn't be followed, or
    /// wrapping was turned off and nothing is keeping it in step.
    pub fn reset(self: *RowCounts) void {
        self.counts.clearRetainingCapacity();
    }

    /// Brings the cache in line with the pane before it is read: emptied
    /// when the wrapping changed, and again when the line count no longer
    /// matches -- which the edit journal should have kept in step, so a
    /// mismatch means an edit went unseen.
    pub fn sync(self: *RowCounts, alloc: std.mem.Allocator, key: Key, line_count: usize) !void {
        if (!std.meta.eql(key, self.key) or self.counts.items.len != line_count) {
            self.key = key;
            try self.counts.resize(alloc, line_count);
            @memset(self.counts.items, 0);
        }
    }

    /// Follows one buffer mutation: lines `start_line..=old_end_line` are
    /// replaced by `start_line..=new_end_line`, all uncounted, and every
    /// line below moves with them. A no-op on an empty cache.
    pub fn applyEdit(
        self: *RowCounts,
        alloc: std.mem.Allocator,
        start_line: usize,
        old_end_line: usize,
        new_end_line: usize,
    ) !void {
        if (self.counts.items.len == 0) return;
        const lo = @min(start_line, self.counts.items.len);
        const old_hi = @min(old_end_line + 1, self.counts.items.len);
        const fresh = new_end_line + 1 - start_line;
        const zeros = try alloc.alloc(u32, fresh);
        defer alloc.free(zeros);
        @memset(zeros, 0);
        try self.counts.replaceRange(alloc, lo, old_hi - lo, zeros);
    }

    /// Counts every line not yet counted, asking `ctx.lineRows(line)`.
    pub fn fill(self: *RowCounts, ctx: anytype) void {
        for (self.counts.items, 0..) |*c, line| {
            if (c.* == 0) c.* = @intCast(@max(1, ctx.lineRows(line)));
        }
    }

    /// Screen rows the whole buffer takes, closed folds left out.
    /// Expects a `fill`ed cache.
    pub fn total(self: *const RowCounts, hidden: []const fold.Range) usize {
        return self.rowsAbove(hidden, self.counts.items.len);
    }

    /// Screen rows above buffer line `line` (lines `0..line`), closed
    /// folds left out: the row `line`'s first row sits on.
    pub fn rowsAbove(self: *const RowCounts, hidden: []const fold.Range, line: usize) usize {
        const end = @min(line, self.counts.items.len);
        var n: usize = 0;
        for (self.counts.items[0..end]) |c| n += c;
        for (hidden) |r| {
            if (r.first >= end) break;
            for (self.counts.items[r.first..@min(r.last + 1, end)]) |c| n -= c;
        }
        return n;
    }

    pub const Place = struct { line: usize, sub: usize };

    /// The line and wrapped row that screen row `row` shows, skipping
    /// closed folds. Past the end it is the last line's last row.
    pub fn placeOf(self: *const RowCounts, hidden: []const fold.Range, row: usize) Place {
        const items = self.counts.items;
        if (items.len == 0) return .{ .line = 0, .sub = 0 };
        var left = row;
        var last: Place = .{ .line = 0, .sub = 0 };
        var line: usize = 0;
        while (line < items.len) : (line += 1) {
            if (fold.rangeOf(hidden, line)) |r| {
                line = r.last;
                continue;
            }
            const c = items[line];
            if (left < c) return .{ .line = line, .sub = left };
            left -= c;
            last = .{ .line = line, .sub = c -| 1 };
        }
        return last;
    }
};

/// Lines closed folds hide above buffer line `line` (lines `0..line`).
/// Unwrapped, every other line is one row, so this is all the bar needs
/// there: no `RowCounts` to keep.
pub fn hiddenBefore(hidden: []const fold.Range, line: usize) usize {
    var n: usize = 0;
    for (hidden) |r| {
        if (r.first >= line) break;
        n += @min(r.last + 1, line) - r.first;
    }
    return n;
}

/// The buffer line screen row `row` shows in an unwrapped pane, skipping
/// closed folds. Clamped to the last line of a `line_count`-line buffer.
pub fn unwrappedLineOf(hidden: []const fold.Range, row: usize, line_count: usize) usize {
    var line = row;
    for (hidden) |r| {
        if (r.first > line) break;
        line += r.last - r.first + 1;
    }
    return @min(line, line_count -| 1);
}
