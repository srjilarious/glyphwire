// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: GPL-3.0-or-later

//! Per-line highlight spans, kept between frames.
//!
//! Computing a row's colours means running tree-sitter queries, which is
//! the expensive half of painting it; writing the row out is cheap. So
//! each buffer slot keeps the spans of every line it has painted, and a
//! repaint -- a scroll back over rows seen before, a selection drag that
//! redraws the whole pane every motion -- reads them from here.
//!
//! The cache is invalidated precisely rather than flushed per edit, the
//! way editors that tokenize per line do it:
//!
//!   - Each edit from the buffer's journal (`applyEdit`) drops the lines
//!     it replaced and shifts the lines below when it changed the line
//!     count, so a line's entry follows its text.
//!   - The highlighter's changed ranges after a reparse (`invalidate`)
//!     drop the lines whose colours may have moved without their text
//!     changing -- the rest of a block comment that was just opened.
//!   - Anything the highlighter can't describe as ranges (a whole-buffer
//!     parse, a language switch) moves its `generation`, which empties the
//!     cache wholesale (`sync`).

const std = @import("std");
const syntax = @import("applib").syntax;

pub const SpanCache = struct {
    /// One entry per buffer line; null when not computed or invalidated.
    /// Each non-null slice is owned.
    lines: std.ArrayList(?[]syntax.Span) = .empty,
    /// The `Highlighter.generation` the entries were computed under.
    generation: u64 = 0,

    pub fn deinit(self: *SpanCache, alloc: std.mem.Allocator) void {
        for (self.lines.items) |e| if (e) |s| alloc.free(s);
        self.lines.deinit(alloc);
        self.* = undefined;
    }

    /// Drops every entry, keeping one (empty) slot per line.
    pub fn clear(self: *SpanCache, alloc: std.mem.Allocator) void {
        for (self.lines.items) |*e| {
            if (e.*) |s| alloc.free(s);
            e.* = null;
        }
    }

    /// Drops every entry *and* the line slots, so the next `sync` sizes
    /// the cache afresh. For when an edit couldn't be followed.
    pub fn reset(self: *SpanCache, alloc: std.mem.Allocator) void {
        self.clear(alloc);
        self.lines.clearRetainingCapacity();
    }

    /// Brings the cache in line with the highlighter and the buffer
    /// before it is read: empty if the highlighter's `generation` moved,
    /// and empty again (resized) if the line count no longer matches --
    /// which the edit journal should have kept in step, so a mismatch
    /// means an edit went unseen and nothing here can be trusted.
    pub fn sync(self: *SpanCache, alloc: std.mem.Allocator, generation: u64, line_count: usize) !void {
        if (generation != self.generation or self.lines.items.len != line_count) {
            self.clear(alloc);
            self.generation = generation;
        }
        if (self.lines.items.len != line_count) {
            try self.lines.resize(alloc, line_count);
            @memset(self.lines.items, null);
        }
    }

    /// Follows one buffer mutation: lines `start_line..=old_end_line` are
    /// replaced by `start_line..=new_end_line`, all uncomputed, and every
    /// line below moves with them. A no-op on an empty cache (nothing
    /// computed yet, nothing to keep in step).
    pub fn applyEdit(
        self: *SpanCache,
        alloc: std.mem.Allocator,
        start_line: usize,
        old_end_line: usize,
        new_end_line: usize,
    ) !void {
        if (self.lines.items.len == 0) return;
        const lo = @min(start_line, self.lines.items.len);
        const old_hi = @min(old_end_line + 1, self.lines.items.len);
        for (self.lines.items[lo..old_hi]) |e| if (e) |s| alloc.free(s);
        const fresh = new_end_line + 1 - start_line;
        const nulls = try alloc.alloc(?[]syntax.Span, fresh);
        defer alloc.free(nulls);
        @memset(nulls, null);
        try self.lines.replaceRange(alloc, lo, old_hi - lo, nulls);
    }

    /// Drops lines `lo..=hi` (clamped to the buffer).
    pub fn invalidate(self: *SpanCache, alloc: std.mem.Allocator, lo: usize, hi: usize) void {
        if (lo >= self.lines.items.len) return;
        const end = @min(hi + 1, self.lines.items.len);
        for (self.lines.items[lo..end]) |*e| {
            if (e.*) |s| alloc.free(s);
            e.* = null;
        }
    }

    /// The cached spans of `line`, or null when they need computing.
    pub fn get(self: *const SpanCache, line: usize) ?[]const syntax.Span {
        if (line >= self.lines.items.len) return null;
        return self.lines.items[line];
    }

    /// Stores a copy of `spans` for `line`.
    pub fn put(self: *SpanCache, alloc: std.mem.Allocator, line: usize, spans: []const syntax.Span) !void {
        if (line >= self.lines.items.len) return;
        const copy = try alloc.dupe(syntax.Span, spans);
        if (self.lines.items[line]) |old| alloc.free(old);
        self.lines.items[line] = copy;
    }
};
