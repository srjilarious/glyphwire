// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: GPL-3.0-or-later

//! Soft wrapping: how one buffer line is cut into screen rows.
//!
//! With `:set wrap=on` a line wider than the buffer pane continues on
//! the rows below it instead of running off the right edge. Each of
//! those rows is a `Row` here -- a range of the line's *display* columns
//! (and the bytes behind them) -- and everything that turns a screen row
//! back into text or a position asks `Rows` for it, so the painter, the
//! caret, a mouse click and `j`/`k` all agree on where a line breaks.
//!
//! Breaks fall at word boundaries, like vim's `linebreak`: a row ends
//! just after the last space or tab that fits. A run with no whitespace
//! in it (a long URL, a minified line) is cut at the pane edge instead,
//! and a single character wider than the pane gets a row to itself.
//!
//! Columns are the line's own, not the row's: a row starting at column
//! 80 reports `start_col = 80`, and a tab still takes its width from its
//! position in the whole line. That keeps `display.zig` the one answer
//! to "which column is this byte on" -- a row is just a window onto it.

const std = @import("std");
const display = @import("display.zig");

/// One screen row of a wrapped line. `[start_col, end_col)` are display
/// columns of the line; `[start_byte, end_byte)` the bytes they show.
pub const Row = struct {
    start_col: usize,
    end_col: usize,
    start_byte: usize,
    end_byte: usize,
};

/// Walks the rows a line wraps into, top to bottom. The text is the line
/// *without* its newline. An empty line is one empty row; every line is
/// at least one row.
pub const Rows = struct {
    text: []const u8,
    opts: display.Opts,
    /// Columns per row -- the buffer pane's text width. Zero is treated
    /// as one, so a degenerate split can't loop forever.
    width: usize,
    cells: display.Cells = undefined,
    started: bool = false,
    done: bool = false,

    pub fn init(text: []const u8, opts: display.Opts, width: usize) Rows {
        return .{
            .text = text,
            .opts = opts,
            .width = @max(width, 1),
            .cells = .{ .text = text, .opts = opts },
        };
    }

    pub fn next(self: *Rows) ?Row {
        if (self.done) return null;
        const start_byte = self.cells.i;
        const start_col = self.cells.col;
        if (start_byte >= self.text.len) {
            self.done = true;
            // Only an empty line gets an empty row: a line that fills its
            // last row exactly ends there, rather than with a blank one.
            if (self.started) return null;
            self.started = true;
            return .{ .start_col = 0, .end_col = 0, .start_byte = 0, .end_byte = 0 };
        }
        self.started = true;

        const limit = start_col + self.width;
        // Just after the last whitespace cell on this row: where a word
        // break would put the row's end.
        var brk: ?struct { byte: usize, col: usize } = null;
        while (true) {
            const before = self.cells;
            const cell = self.cells.next() orelse {
                self.done = true;
                return .{ .start_col = start_col, .end_col = self.cells.col, .start_byte = start_byte, .end_byte = self.text.len };
            };
            if (cell.col + cell.width > limit and cell.col > start_col) {
                // This cell doesn't fit. Back up to the last word break if
                // the row has one, else cut right before the cell.
                if (brk) |b| {
                    self.cells = .{ .text = self.text, .opts = self.opts, .i = b.byte, .col = b.col };
                } else {
                    self.cells = before;
                }
                return .{ .start_col = start_col, .end_col = self.cells.col, .start_byte = start_byte, .end_byte = self.cells.i };
            }
            const c = self.text[cell.src];
            if (c == ' ' or c == '\t') brk = .{ .byte = self.cells.i, .col = self.cells.col };
        }
    }
};

/// How many screen rows `text` takes at `width` columns. At least one.
pub fn rowCount(text: []const u8, opts: display.Opts, width: usize) usize {
    var it = Rows.init(text, opts, width);
    var n: usize = 0;
    while (it.next() != null) n += 1;
    return n;
}

/// Where display column `col` of `text` lands: which row, and that row.
/// A column at or past the end of the line -- the insert-mode caret after
/// the last character -- belongs to the last row.
pub const Place = struct { index: usize, row: Row };

pub fn rowOfCol(text: []const u8, opts: display.Opts, width: usize, col: usize) Place {
    var it = Rows.init(text, opts, width);
    var index: usize = 0;
    var last: Row = .{ .start_col = 0, .end_col = 0, .start_byte = 0, .end_byte = 0 };
    while (it.next()) |row| : (index += 1) {
        last = row;
        if (col < row.end_col) return .{ .index = index, .row = row };
    }
    return .{ .index = index -| 1, .row = last };
}

/// Row `index` of `text` (clamped to the last row).
pub fn rowAt(text: []const u8, opts: display.Opts, width: usize, index: usize) Place {
    var it = Rows.init(text, opts, width);
    var i: usize = 0;
    var last: Row = .{ .start_col = 0, .end_col = 0, .start_byte = 0, .end_byte = 0 };
    while (it.next()) |row| : (i += 1) {
        last = row;
        if (i == index) return .{ .index = i, .row = row };
    }
    return .{ .index = i -| 1, .row = last };
}
