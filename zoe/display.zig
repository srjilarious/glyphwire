// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: GPL-3.0-or-later

//! The one place a buffer line's *bytes* are turned into *display cells*.
//!
//! `buffer.zig` and `editor.zig` think in byte offsets; the buffer pane
//! thinks in columns. Everything that crosses between them -- painting a
//! row, placing the caret, clipping a selection, resolving a mouse click
//! -- goes through `Cells` here, so there is exactly one answer to "which
//! column is this byte on".
//!
//! Two characters don't render as themselves:
//!
//!  - **A tab** occupies the cells out to the next `tab_width` stop, so
//!    its width depends on where it starts. It paints as blanks, or --
//!    with `show_whitespace` on -- a faint arrow in its first cell and
//!    blanks for the rest of the run.
//!  - **A space**, with `show_whitespace` on, paints as a faint middle
//!    dot. Only a real `0x20` gets one: the cells *after* a tab's arrow
//!    stay empty, so four spaces and one tab still read differently.
//!
//! A `Cell` carries the source byte it came from, which is what lets the
//! renderer look a syntax colour up per column without keeping a second
//! byte-to-column map around. It also carries `glyph_cols` separately
//! from `width`, because a marker is one cell standing in for a run that
//! may be several -- the columns past the glyph are blanks the painter
//! still has to write, or they would be transparent.

const std = @import("std");
const glyphwire = @import("glyphwire");

/// What a space is drawn with under `show_whitespace`: U+00B7 MIDDLE
/// DOT. One cell wide (it is not in glyphwire's wide table) and present
/// in every font zoe is likely to fall back through.
pub const space_marker = "\u{00b7}";

/// What a tab is drawn with under `show_whitespace`: U+2192 RIGHTWARDS
/// ARROW in the tab's *first* cell, the rest of the run left blank --
/// the spelling vim's `listchars` and every GUI editor settled on. Also
/// one cell wide, so it can't overflow the run even at `tab_width = 1`.
pub const tab_marker = "\u{2192}";

/// The display settings a line is laid out under. Both come from the
/// `Editor` (`zoe.conf`, or `:set` at runtime) -- see `editor.Editor`.
pub const Opts = struct {
    /// Cells between tab stops. Clamped to at least 1 wherever it is
    /// used, so a config of `0` can't divide by zero.
    tab_width: usize = 4,
    /// Paint whitespace: each space as `space_marker`, each tab as
    /// `tab_marker` followed by blanks.
    show_whitespace: bool = false,
};

/// One character of a line, placed. `width` is the cells it occupies --
/// 2 for CJK, 0 for a combining mark, and out-to-the-next-stop for a tab.
pub const Cell = struct {
    /// Byte offset of the character within the line it came from.
    src: usize,
    /// Display column its leftmost cell sits on.
    col: usize,
    /// Cells occupied, counting from `col`.
    width: usize,
    /// What to draw at `col`. Empty means "blanks the whole way" -- an
    /// expanded tab with no marker.
    bytes: []const u8,
    /// Columns `bytes` itself occupies, out of `width`. Equal to `width`
    /// for an ordinary character; 1 for a tab's arrow, whose run is
    /// wider than its glyph; 0 for an unmarked tab. The difference is
    /// blanks the painter must still write, or the cells stay unpainted.
    glyph_cols: usize,
    /// This is a whitespace marker standing in for the source character,
    /// so it takes the dim marker colour rather than the syntax colour
    /// the byte under it would have had.
    marker: bool,
};

/// Walks a line's characters left to right, handing back where each one
/// lands. The line is the text *without* its newline.
pub const Cells = struct {
    text: []const u8,
    opts: Opts,
    i: usize = 0,
    col: usize = 0,

    pub fn next(self: *Cells) ?Cell {
        if (self.i >= self.text.len) return null;
        const start = self.i;
        const col = self.col;

        if (self.text[start] == '\t') {
            const w = tabStop(col, self.opts.tab_width);
            const marked = self.opts.show_whitespace;
            self.i += 1;
            self.col += w;
            return .{
                .src = start,
                .col = col,
                .width = w,
                .bytes = if (marked) tab_marker else "",
                .glyph_cols = if (marked) 1 else 0,
                .marker = marked,
            };
        }
        if (self.text[start] == ' ' and self.opts.show_whitespace) {
            self.i += 1;
            self.col += 1;
            return .{
                .src = start,
                .col = col,
                .width = 1,
                .bytes = space_marker,
                .glyph_cols = 1,
                .marker = true,
            };
        }

        const seq = std.unicode.utf8ByteSequenceLength(self.text[start]) catch 1;
        const end = @min(start + seq, self.text.len);
        const cp = std.unicode.utf8Decode(self.text[start..end]) catch 0xFFFD;
        const w = glyphwire.codepointWidth(cp);
        self.i = end;
        self.col += w;
        return .{
            .src = start,
            .col = col,
            .width = w,
            .bytes = self.text[start..end],
            .glyph_cols = w,
            .marker = false,
        };
    }
};

/// Cells from `col` to the next tab stop -- what a tab at that column
/// covers, and so how many spaces an expanding Tab key inserts there.
/// Always at least 1.
pub fn tabStop(col: usize, tab_width: usize) usize {
    const tw = @max(tab_width, 1);
    return tw - (col % tw);
}

/// Total display width of a line.
pub fn width(text: []const u8, opts: Opts) usize {
    var it = Cells{ .text = text, .opts = opts };
    var last: usize = 0;
    while (it.next()) |cell| last = cell.col + cell.width;
    return last;
}

/// The display column byte `off` of `text` sits on. An offset inside a
/// multi-byte character resolves to that character's own column, and one
/// past the end to the width of the whole line.
pub fn colOfByte(text: []const u8, off: usize, opts: Opts) usize {
    var it = Cells{ .text = text, .opts = opts };
    while (it.next()) |cell| {
        if (cell.src >= off) return cell.col;
    }
    return it.col;
}

/// The byte offset of the character shown at display column `col` -- the
/// inverse of `colOfByte`, clamped to the end of the line. A column in
/// the trailing half of a wide character, or anywhere inside an expanded
/// tab, resolves to that character's first byte. Used to turn a mouse
/// cell into a buffer position.
pub fn byteAtCol(text: []const u8, col: usize, opts: Opts) usize {
    var it = Cells{ .text = text, .opts = opts };
    while (it.next()) |cell| {
        if (cell.col + cell.width > col) return cell.src;
    }
    return text.len;
}

/// Appends exactly `max` columns of display bytes to `out`: the part of
/// `text` shown through a viewport starting at column `start`, padded
/// with blanks past the end of the line.
///
/// A character straddling either edge of the viewport is painted as
/// blanks rather than half-drawn -- the same bargain the pre-tab
/// renderer struck with double-width characters, now also covering a tab
/// the viewport starts in the middle of.
pub fn appendCols(
    alloc: std.mem.Allocator,
    out: *std.ArrayList(u8),
    text: []const u8,
    start: usize,
    max: usize,
    opts: Opts,
) !void {
    if (max == 0) return;
    const end = start + max;
    var col = start;

    var it = Cells{ .text = text, .opts = opts };
    while (it.next()) |cell| {
        // `@max(width, 1)` so a zero-width combining mark sitting exactly
        // on the left edge is kept rather than skipped as "ends before
        // the viewport".
        if (cell.col + @max(cell.width, 1) <= start) continue;
        if (cell.col >= end) break;

        // Columns no cell claimed (the viewport opened inside a character
        // that was skipped above).
        if (cell.col > col) {
            try out.appendNTimes(alloc, ' ', cell.col - col);
            col = cell.col;
        }

        const clipped = cell.col < start or cell.col + cell.width > end;
        if (clipped) {
            const hi = @min(cell.col + cell.width, end);
            if (hi > col) {
                try out.appendNTimes(alloc, ' ', hi - col);
                col = hi;
            }
        } else {
            try out.appendSlice(alloc, cell.bytes);
            // The columns past the glyph: a tab's run after its arrow,
            // or the whole run of an unmarked tab.
            try out.appendNTimes(alloc, ' ', cell.width - cell.glyph_cols);
            col += cell.width;
        }
    }

    if (col < end) try out.appendNTimes(alloc, ' ', end - col);
}
