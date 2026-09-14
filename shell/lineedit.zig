// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: GPL-3.0-or-later

//! Pure UTF-8 / display-width helpers for glyphwire-shell's line editor,
//! plus `flattenNewlines` for sanitizing pasted text into the single-line
//! buffer. No IO.
//!
//! `Prompt` (in `shell/main.zig`) keeps its cursor as a *byte* offset into
//! the line buffer, but the grid it draws to is addressed in *display
//! columns* -- and an East Asian wide character is one codepoint, two
//! columns, and (commonly) three UTF-8 bytes. These functions convert
//! between the two so arrow movement steps whole codepoints and the
//! on-screen caret lands on the right column even with CJK text on the
//! line. Gathered here (rather than inline in `main.zig`) so the test
//! runner can exercise them -- `Prompt` itself isn't importable.
//!
//! Every `offset` argument is assumed to already sit on a codepoint
//! boundary (all of `Prompt`'s call sites hold that: word-jump scans stop
//! on ASCII spaces, ctrl+a/e land on 0/len, and the steppers below only
//! ever produce boundaries). Invalid UTF-8 degrades to byte-at-a-time
//! rather than looping.

const std = @import("std");
const glyphwire = @import("glyphwire");

/// True for a UTF-8 continuation byte (`10xxxxxx`) -- the trailing bytes
/// of a multi-byte codepoint, never a boundary.
fn isContinuation(b: u8) bool {
    return b & 0xC0 == 0x80;
}

/// Byte offset of the start of the codepoint that ends at `offset` -- where
/// a Left arrow or Backspace should move to. Walks back over continuation
/// bytes. Returns 0 when already at the start.
pub fn prevBoundary(buf: []const u8, offset: usize) usize {
    if (offset == 0) return 0;
    var i = offset - 1;
    while (i > 0 and isContinuation(buf[i])) : (i -= 1) {}
    return i;
}

/// Byte offset just past the codepoint that starts at `offset` -- where a
/// Right arrow or forward-Delete boundary sits. Clamps to `buf.len`; a
/// malformed lead byte advances by one so a corrupt buffer can't wedge.
pub fn nextBoundary(buf: []const u8, offset: usize) usize {
    if (offset >= buf.len) return buf.len;
    const len = std.unicode.utf8ByteSequenceLength(buf[offset]) catch 1;
    return @min(offset + len, buf.len);
}

/// Display width, in grid columns, of `buf[0..offset]` -- the caret's
/// column offset from where the line's text starts. Thin wrapper over
/// `glyphwire.stringWidth` that pins the byte range the shell cares about.
pub fn displayCol(buf: []const u8, offset: usize) usize {
    return glyphwire.stringWidth(buf[0..offset]);
}

/// Display width, in grid columns, of the whole slice -- how many cells a
/// run of text occupies once drawn, which is what `insert_cells` /
/// `delete_cells` count in (not bytes).
pub fn cellWidth(text: []const u8) usize {
    return glyphwire.stringWidth(text);
}

/// Character classes a Ctrl+Left/Right hop stops at: letters, digits, and
/// underscore are one "word" class (an identifier/filename segment);
/// every other non-whitespace byte is its own "punct" class. So a path
/// separator or a run of operator characters (`/`, `--`, `&&`) is its own
/// stop rather than being swallowed into the surrounding text the way
/// bash's word-jump skips over it silently.
const WordClass = enum { space, word, punct };

fn wordClass(ch: u8) WordClass {
    if (ch == ' ' or ch == '\t') return .space;
    if ((ch >= 'A' and ch <= 'Z') or (ch >= 'a' and ch <= 'z') or (ch >= '0' and ch <= '9') or ch == '_') return .word;
    return .punct;
}

/// The offset a Ctrl+Right hop lands on: past any whitespace right of
/// `cursor`, then past the following run of one `WordClass` -- e.g.
/// `/home/jeff` takes two hops per path segment, one over the `/`, one
/// over the name.
pub fn wordRight(buf: []const u8, cursor: usize) usize {
    var i = cursor;
    while (i < buf.len and wordClass(buf[i]) == .space) : (i += 1) {}
    if (i >= buf.len) return i;
    const class = wordClass(buf[i]);
    while (i < buf.len and wordClass(buf[i]) == class) : (i += 1) {}
    return i;
}

/// The offset a Ctrl+Left hop lands on: back past any whitespace left of
/// `cursor`, then back past the preceding run of one `WordClass`.
pub fn wordLeft(buf: []const u8, cursor: usize) usize {
    var i = cursor;
    while (i > 0 and wordClass(buf[i - 1]) == .space) : (i -= 1) {}
    if (i == 0) return 0;
    const class = wordClass(buf[i - 1]);
    while (i > 0 and wordClass(buf[i - 1]) == class) : (i -= 1) {}
    return i;
}

/// Every maximal run of `\n` / `\r` in `text` replaced by a single space,
/// as an owned copy (free with `alloc`). The shell's line editor is
/// single-line; pasted text that carries newlines -- a multi-select copy
/// of file paths, a block from another window -- has to arrive as
/// space-separated words so it lands as one editable line and the
/// word-splitter turns it into arguments. Text with no newline still
/// comes back as a fresh allocation, so the caller frees unconditionally.
pub fn flattenNewlines(alloc: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.ensureTotalCapacity(alloc, text.len);

    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == '\n' or text[i] == '\r') {
            while (i < text.len and (text[i] == '\n' or text[i] == '\r')) : (i += 1) {}
            try out.append(alloc, ' ');
        } else {
            try out.append(alloc, text[i]);
            i += 1;
        }
    }
    return out.toOwnedSlice(alloc);
}
