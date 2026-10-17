// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: GPL-3.0-or-later

//! Code folding by indentation: which lines can fold, how far each fold
//! reaches, and which lines the closed ones hide.
//!
//! **A fold is a line and the more-indented block under it**, the rule
//! VS Code's "indentation" folding strategy uses. A line starts a fold
//! when the next non-blank line is indented further; the fold runs to
//! the last line of that deeper block. Blank lines inside the block
//! belong to it, blank lines trailing it don't, and the line that
//! closes the block (`}` back at the outer indent) stays visible, so a
//! folded function still shows its closing brace. It needs no grammar,
//! so every file folds, and the same way.
//!
//! **Only closed folds are stored**, as the line each one starts on, in
//! `Buffer.closed_folds` -- the buffer is what moves them when lines
//! are inserted or deleted above them (see `Buffer.insert`). Where a
//! fold ends is never stored: it is worked out from the text whenever
//! it is needed, so an edit inside a closed fold's block can't leave a
//! stale end behind. A stored start that stops being a fold (its block
//! was dedented away) is dropped the next time the ranges are built.
//!
//! **Hidden lines are what the rest of zoe sees.** `hiddenRanges` turns
//! the closed starts into sorted, disjoint runs of hidden lines (a fold
//! closed inside another closed fold is covered by the outer one), and
//! the row layout, the vertical motions and the gutter all read those
//! runs. Nothing here does IO or allocates except into the caller's
//! list.

const std = @import("std");
const buffer = @import("buffer.zig");
const display = @import("display.zig");

const Buffer = buffer.Buffer;

/// A run of hidden lines, `first` through `last` inclusive: the lines
/// under one closed fold, whose own first line stays on screen at
/// `first - 1`.
pub const Range = struct { first: usize, last: usize };

/// The display width of `line`'s leading whitespace, or null for a line
/// with nothing else on it. A blank line has no indent of its own: it
/// takes on whatever block it sits in.
pub fn indentOf(buf: *const Buffer, line: usize, tab_width: usize) ?usize {
    const start = buf.lineStart(line);
    const end = buf.lineEnd(line);
    var col: usize = 0;
    var i = start;
    while (i < end) : (i += 1) {
        switch (buf.byteAt(i)) {
            ' ' => col += 1,
            '\t' => col += display.tabStop(col, tab_width),
            '\r' => {},
            else => return col,
        }
    }
    return null;
}

/// The next line after `line` with something on it, or null.
fn nextNonBlank(buf: *const Buffer, line: usize, tab_width: usize) ?struct { line: usize, indent: usize } {
    var l = line + 1;
    while (l < buf.lineCount()) : (l += 1) {
        if (indentOf(buf, l, tab_width)) |ind| return .{ .line = l, .indent = ind };
    }
    return null;
}

/// The last line of the fold starting at `line`, or null when `line`
/// doesn't start one: it is blank, or the next non-blank line is not
/// indented further than it is.
pub fn foldEnd(buf: *const Buffer, line: usize, tab_width: usize) ?usize {
    if (line >= buf.lineCount()) return null;
    const base = indentOf(buf, line, tab_width) orelse return null;
    const first = nextNonBlank(buf, line, tab_width) orelse return null;
    if (first.indent <= base) return null;
    // Walk the deeper block, remembering its last non-blank line so the
    // blank lines after it are left out.
    var last = first.line;
    var l = first.line + 1;
    while (l < buf.lineCount()) : (l += 1) {
        const ind = indentOf(buf, l, tab_width) orelse continue;
        if (ind <= base) break;
        last = l;
    }
    return last;
}

/// Whether `line` starts a fold. Cheaper than `foldEnd`: it only looks
/// as far as the next non-blank line, which is what the gutter needs
/// for every row it paints.
pub fn isFoldStart(buf: *const Buffer, line: usize, tab_width: usize) bool {
    if (line >= buf.lineCount()) return false;
    const base = indentOf(buf, line, tab_width) orelse return false;
    const next = nextNonBlank(buf, line, tab_width) orelse return false;
    return next.indent > base;
}

/// The fold `line` belongs to, as its start line: `line` itself when it
/// starts one, else the nearest fold above it that reaches down over it.
/// Null for a line no fold covers (top-level code between blocks).
pub fn foldAt(buf: *const Buffer, line: usize, tab_width: usize) ?usize {
    if (line >= buf.lineCount()) return null;
    if (isFoldStart(buf, line, tab_width)) return line;
    return enclosingFold(buf, line, tab_width);
}

/// The nearest fold that strictly contains `line`: the closest line above
/// it, indented less, whose fold reaches `line`. A blank line takes the
/// indent of the block it sits in (the next non-blank line's).
pub fn enclosingFold(buf: *const Buffer, line: usize, tab_width: usize) ?usize {
    var want = indentOf(buf, line, tab_width) orelse blk: {
        const next = nextNonBlank(buf, line, tab_width) orelse return null;
        break :blk next.indent;
    };
    var l = line;
    while (l > 0) {
        l -= 1;
        const ind = indentOf(buf, l, tab_width) orelse continue;
        if (ind >= want) continue;
        if (foldEnd(buf, l, tab_width)) |end| {
            if (end >= line) return l;
        }
        // Indented less but its fold stops short (`line` is in the blank
        // run trailing a block): look further out.
        want = ind;
    }
    return null;
}

/// Every line in the buffer that starts a fold, ascending -- what vim's
/// `zM` closes.
pub fn allStarts(alloc: std.mem.Allocator, buf: *const Buffer, tab_width: usize, out: *std.ArrayList(usize)) !void {
    out.clearRetainingCapacity();
    var line: usize = 0;
    while (line < buf.lineCount()) : (line += 1) {
        if (isFoldStart(buf, line, tab_width)) try out.append(alloc, line);
    }
}

/// Fills `out` with the lines `closed` hides, sorted and disjoint, and
/// removes from `closed` any start that no longer starts a fold. `closed`
/// must be sorted ascending (`Buffer.closed_folds` is). A fold closed
/// inside another closed one adds nothing: the outer range covers it.
pub fn hiddenRanges(
    alloc: std.mem.Allocator,
    buf: *const Buffer,
    closed: *std.ArrayList(usize),
    tab_width: usize,
    out: *std.ArrayList(Range),
) !void {
    out.clearRetainingCapacity();
    var i: usize = 0;
    while (i < closed.items.len) {
        const start = closed.items[i];
        const end = foldEnd(buf, start, tab_width) orelse {
            _ = closed.orderedRemove(i);
            continue;
        };
        i += 1;
        if (out.items.len > 0 and start <= out.items[out.items.len - 1].last) continue;
        try out.append(alloc, .{ .first = start + 1, .last = end });
    }
}

/// The hidden run `line` is in, or null when it is on screen.
pub fn rangeOf(ranges: []const Range, line: usize) ?Range {
    var lo: usize = 0;
    var hi: usize = ranges.len;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        const r = ranges[mid];
        if (line < r.first) {
            hi = mid;
        } else if (line > r.last) {
            lo = mid + 1;
        } else return r;
    }
    return null;
}

pub fn isHidden(ranges: []const Range, line: usize) bool {
    return rangeOf(ranges, line) != null;
}

/// The last line of the closed fold `line` heads, or `line` itself when
/// it heads none -- how far a linewise command on `line` reaches, since
/// a closed fold acts as the one line it shows.
pub fn lastOfRow(ranges: []const Range, line: usize) usize {
    const r = rangeOf(ranges, line + 1) orelse return line;
    return if (r.first == line + 1) r.last else line;
}

/// `line` if it is on screen, else the line its hidden run folds under.
pub fn visibleAtOrAbove(ranges: []const Range, line: usize) usize {
    const r = rangeOf(ranges, line) orelse return line;
    return r.first - 1;
}

/// `n` on-screen lines below `line`, stopping at `count - 1` (or the last
/// on-screen line before it). A closed fold counts as one line.
pub fn visibleDown(ranges: []const Range, line: usize, n: usize, count: usize) usize {
    var l = line;
    var left = n;
    while (left > 0) : (left -= 1) {
        const next = lastOfRow(ranges, l) + 1;
        if (next >= count) break;
        l = next;
    }
    return l;
}

/// `n` on-screen lines above `line`, stopping at line 0.
pub fn visibleUp(ranges: []const Range, line: usize, n: usize) usize {
    var l = line;
    var left = n;
    while (left > 0 and l > 0) : (left -= 1) {
        l = visibleAtOrAbove(ranges, l - 1);
    }
    return l;
}

/// On-screen lines between `a` and `b` (either order) -- what relative
/// line numbers count, so `5j` lands where the gutter said 5.
pub fn visibleDistance(ranges: []const Range, a: usize, b: usize) usize {
    const lo = @min(a, b);
    const hi = @max(a, b);
    var d = hi - lo;
    for (ranges) |r| {
        if (r.last < lo or r.first > hi) continue;
        const from = @max(r.first, lo);
        const to = @min(r.last, hi);
        d -= to - from + 1;
    }
    return d;
}

/// The sorted insert of `line` into `closed`, if it isn't there already.
pub fn addClosed(alloc: std.mem.Allocator, closed: *std.ArrayList(usize), line: usize) !void {
    var i: usize = 0;
    while (i < closed.items.len and closed.items[i] < line) i += 1;
    if (i < closed.items.len and closed.items[i] == line) return;
    try closed.insert(alloc, i, line);
}

/// Takes `line` out of `closed`. Returns whether it was there.
pub fn removeClosed(closed: *std.ArrayList(usize), line: usize) bool {
    for (closed.items, 0..) |l, i| {
        if (l == line) {
            _ = closed.orderedRemove(i);
            return true;
        }
    }
    return false;
}

pub fn isClosed(closed: []const usize, line: usize) bool {
    return std.mem.indexOfScalar(usize, closed, line) != null;
}
