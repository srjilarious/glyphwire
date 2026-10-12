// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: GPL-3.0-or-later

//! mokuro OCR for gw-read: gw-yomi's `mokuro` (the parse, reading order,
//! hit testing, joining lines, vertical layout) plus the cell-width
//! helpers only gw-read's character-cell dialog needs -- measuring and
//! wrapping a bubble's text in terminal cells, where a wide (CJK/kana)
//! codepoint takes two.

const std = @import("std");
const glyphwire = @import("glyphwire");
const mokuro = @import("gw_yomi").mokuro;

pub const Box = mokuro.Box;
pub const Block = mokuro.Block;
pub const Page = mokuro.Page;
pub const Volume = mokuro.Volume;
pub const parse = mokuro.parse;
pub const Order = mokuro.Order;
pub const readingOrder = mokuro.readingOrder;
pub const band_fraction = mokuro.band_fraction;
pub const blockAt = mokuro.blockAt;
pub const joinLines = mokuro.joinLines;
pub const charEnd = mokuro.charEnd;
pub const rowOffset = mokuro.rowOffset;
pub const TextCell = mokuro.TextCell;
pub const spanChars = mokuro.spanChars;
pub const Span = mokuro.Span;
pub const spanIn = mokuro.spanIn;
pub const Layout = mokuro.Layout;
pub const charCount = mokuro.charCount;
pub const charToByte = mokuro.charToByte;
pub const wrapVertical = mokuro.wrapVertical;
pub const verticalForm = mokuro.verticalForm;

// ── Cell width ──────────────────────────────────────────────────────────

/// Display width of `text` in cells -- wide (CJK/kana) codepoints count
/// two, matching how `write_text` advances the cursor.
pub fn displayWidth(text: []const u8) usize {
    var w: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        const len = std.unicode.utf8ByteSequenceLength(text[i]) catch return text.len;
        if (i + len > text.len) break;
        const cp = std.unicode.utf8Decode(text[i .. i + len]) catch {
            i += len;
            w += 1;
            continue;
        };
        w += glyphwire.codepointWidth(cp);
        i += len;
    }
    return w;
}

/// The byte offset of the codepoint occupying display column `col` of
/// `text` (`displayWidth`'s column space) -- for turning a dialog click's
/// window column back into a byte offset in the wrapped row it landed
/// on, which is what a dictionary lookup starts from. Clamped to
/// `text.len` when `col` is past the text's own width, e.g. a click in a
/// row's trailing pad; the caller treats that the same as no word there.
pub fn columnToByte(text: []const u8, col: usize) usize {
    var w: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        const len = std.unicode.utf8ByteSequenceLength(text[i]) catch return i;
        const end = @min(i + len, text.len);
        const cp = std.unicode.utf8Decode(text[i..end]) catch {
            // An invalid byte counts as one column-wide -- same fallback
            // `displayWidth` uses.
            if (col < w + 1) return i;
            w += 1;
            i += 1;
            continue;
        };
        const cw = glyphwire.codepointWidth(cp);
        // `col` falls inside *this* codepoint's span -- return its
        // start, not the next codepoint's, so any column over a
        // 2-cell character resolves to the character it's part of.
        if (col < w + cw) return i;
        w += cw;
        i = end;
    }
    return text.len;
}

/// The first and last cells `joined[start..end]` covers once wrapped
/// into `rows` (as `wrap` produced them from `joined`). `last` is the
/// *last column* of the last character -- inclusive, the way a selection
/// end is -- so a span ending on a wide character covers both its cells.
/// Null for an empty span or one that lies past every row.
///
/// A byte `wrap` dropped at a row break (the space an ASCII row broke
/// at) belongs to no row; a span starting on one starts at the next row,
/// and one ending on one ends at the end of the row before.
pub fn spanCells(
    joined: []const u8,
    rows: []const []const u8,
    start: usize,
    end: usize,
) ?mokuro.Span {
    return mokuro.spanIn(joined, rows, start, end, displayWidth);
}

/// Wraps `text` to `cols` display columns, returning the rows. The rows
/// are slices *into* `text`, so they live exactly as long as it does; the
/// slice holding them is the caller's to free.
///
/// Wrapping is per codepoint, not per word: Japanese has no spaces to
/// break at, so a word-wrap would put a whole bubble on one overflowing
/// line. An ASCII bubble does still break at a space when one is
/// available inside the row, so English in a sound effect doesn't get
/// chopped mid-word.
pub fn wrap(alloc: std.mem.Allocator, text: []const u8, cols: usize) std.mem.Allocator.Error![]const []const u8 {
    var rows: std.ArrayList([]const u8) = .empty;
    errdefer rows.deinit(alloc);
    if (cols == 0 or text.len == 0) {
        if (text.len > 0) try rows.append(alloc, text);
        return rows.toOwnedSlice(alloc);
    }

    var start: usize = 0;
    var i: usize = 0;
    var w: usize = 0;
    // Byte offset of the last space seen in the row being built, so an
    // ASCII row can back up to it rather than breaking mid-word.
    var last_space: ?usize = null;

    while (i < text.len) {
        const len = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
        const end = @min(i + len, text.len);
        const cw: usize = blk: {
            const cp = std.unicode.utf8Decode(text[i..end]) catch break :blk 1;
            break :blk glyphwire.codepointWidth(cp);
        };

        if (w + cw > cols and i > start) {
            // The character that overflowed is itself a space: the row
            // already ends on a word boundary, so break right here rather
            // than backing up to an earlier space and losing a whole word
            // off the end of a row that fitted exactly.
            const brk = if (text[i] == ' ')
                i
            else if (last_space) |sp|
                // Back up to the last space -- unless it is the row's own
                // first byte, which would emit an empty row.
                (if (sp > start) sp else i)
            else
                i;
            try rows.append(alloc, text[start..brk]);
            // A space that was broken *at* is consumed, not carried into
            // the next row as a leading blank.
            start = if (brk < text.len and text[brk] == ' ') brk + 1 else brk;
            i = start;
            w = 0;
            last_space = null;
            continue;
        }

        if (text[i] == ' ') last_space = i;
        w += cw;
        i = end;
    }
    if (start < text.len) try rows.append(alloc, text[start..]);
    return rows.toOwnedSlice(alloc);
}
