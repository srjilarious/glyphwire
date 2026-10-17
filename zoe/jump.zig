// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: GPL-3.0-or-later

//! The `jump` action's labels (Shift+Enter): every word start on the
//! focused pane's visible rows gets a two-letter label drawn over it,
//! the first letter typed hides every label it doesn't start and leaves
//! the second letter of the rest, and the second letter moves the
//! cursor there. Backspace takes the first letter back.
//!
//! Pure: `zoe/ui.zig` hands in the candidates it read off its row map
//! and draws what `shown` says; nothing here knows about panes or the
//! editor.

const std = @import("std");
const motion = @import("motion.zig");
const display = @import("display.zig");

/// Label letters, the home row first. Labels go out in order -- `aa`,
/// `as`, `ad`, ... -- to the targets nearest the cursor, so the closest
/// two dozen all start with `a`.
pub const alphabet = "asdfghjklqwertyuiopzxcvbnm";

/// Every two-letter label there is. Targets past this many (only on a
/// very large pane) go without, the farthest first.
pub const max_targets = alphabet.len * alphabet.len;

/// A word start on screen: its buffer offset, and the screen row and
/// text column (from the pane's left edge, gutter excluded) its label
/// is drawn at.
pub const Target = struct {
    off: usize,
    row: usize,
    col: usize,
};

/// Whether byte `i` of `text` (one line, no newline) starts a word: a
/// `motion.CharClass.word` byte after a non-word one or the line start.
/// Every byte of a multi-byte codepoint classes as `word`, so a start is
/// never mid-codepoint.
pub fn isWordStart(text: []const u8, i: usize) bool {
    if (motion.classOf(text[i], false) != .word) return false;
    return i == 0 or motion.classOf(text[i - 1], false) != .word;
}

/// Appends the word starts screen row `row` shows: the row is display
/// columns `[left, left + cols)` of `text`, the line at buffer offset
/// `line_start`. One walk of the line's cells, so a long unwrapped line
/// costs its length, not its length squared.
pub fn collectRow(
    alloc: std.mem.Allocator,
    out: *std.ArrayList(Target),
    text: []const u8,
    line_start: usize,
    row: usize,
    left: usize,
    cols: usize,
    opts: display.Opts,
) !void {
    var it = display.Cells{ .text = text, .opts = opts };
    while (it.next()) |cell| {
        if (cell.col >= left + cols) break;
        if (cell.col < left or !isWordStart(text, cell.src)) continue;
        try out.append(alloc, .{ .off = line_start + cell.src, .row = row, .col = cell.col - left });
    }
}

/// What a typed letter did.
pub const Step = union(enum) {
    /// The first letter matched some labels; they now show their second.
    narrowed,
    /// The label was complete: move here.
    chosen: usize,
    /// No label goes that way. The jump is over.
    miss,
};

pub const Jump = struct {
    /// Nearest first; a target's index is its label's (`labelOf`).
    targets: std.ArrayList(Target) = .empty,
    /// The first letter, once typed, as its index in `alphabet`.
    first: ?usize = null,

    pub fn deinit(self: *Jump, alloc: std.mem.Allocator) void {
        self.targets.deinit(alloc);
    }

    /// Takes the candidates, nearest to the cursor cell first and cut to
    /// `max_targets`. Rows are counted twice over in the distance, as a
    /// cell is about twice as tall as it is wide.
    pub fn init(alloc: std.mem.Allocator, candidates: []const Target, cursor_row: usize, cursor_col: usize) !Jump {
        var j: Jump = .{};
        errdefer j.deinit(alloc);
        try j.targets.appendSlice(alloc, candidates);
        const Ctx = struct {
            row: usize,
            col: usize,
            fn dist(c: @This(), t: Target) usize {
                const dr = 2 * (@max(t.row, c.row) - @min(t.row, c.row));
                const dc = @max(t.col, c.col) - @min(t.col, c.col);
                return dr * dr + dc * dc;
            }
            fn less(c: @This(), a: Target, b: Target) bool {
                const da = c.dist(a);
                const db = c.dist(b);
                if (da != db) return da < db;
                if (a.row != b.row) return a.row < b.row;
                return a.col < b.col;
            }
        };
        std.mem.sort(Target, j.targets.items, Ctx{ .row = cursor_row, .col = cursor_col }, Ctx.less);
        if (j.targets.items.len > max_targets) j.targets.shrinkRetainingCapacity(max_targets);
        return j;
    }

    /// Target `i`'s two letters.
    pub fn labelOf(i: usize) [2]u8 {
        return .{ alphabet[i / alphabet.len], alphabet[i % alphabet.len] };
    }

    /// What to draw over target `i` now: both letters before anything is
    /// typed, the second once its first letter has been, nothing for a
    /// target the typed letter ruled out. Points into `out`.
    pub fn shown(self: *const Jump, i: usize, out: *[2]u8) ?[]const u8 {
        out.* = labelOf(i);
        const f = self.first orelse return out[0..2];
        if (i / alphabet.len != f) return null;
        return out[1..2];
    }

    /// A typed letter.
    pub fn key(self: *Jump, c: u8) Step {
        const at = std.mem.indexOfScalar(u8, alphabet, c) orelse return .miss;
        if (self.first) |f| {
            const i = f * alphabet.len + at;
            if (i >= self.targets.items.len) return .miss;
            return .{ .chosen = self.targets.items[i].off };
        }
        if (at * alphabet.len >= self.targets.items.len) return .miss;
        self.first = at;
        return .narrowed;
    }

    /// Backspace: the first letter taken back. False with none typed,
    /// which ends the jump.
    pub fn back(self: *Jump) bool {
        if (self.first == null) return false;
        self.first = null;
        return true;
    }
};
