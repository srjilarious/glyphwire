//! Cursor motions over a `Buffer`.
//!
//! Every function here is pure: buffer in, byte offset out, no editor
//! state touched. That split is what lets `editor.zig`'s operator-pending
//! handling (`d` + a motion) reuse the exact same code the bare motion
//! keys run -- vim's `dw` deletes to wherever `w` would have gone, and
//! here it literally does.
//!
//! Two conventions worth stating up front:
//!
//!  - **Codepoints, not bytes.** `h`/`l` and the up/down column snap step
//!    whole UTF-8 codepoints, so a cursor never lands mid-sequence.
//!    Grapheme clusters (a base plus combining marks) and East Asian
//!    display width are still one step each; both belong with the
//!    renderer, which is where glyphwire's `stringWidth` already lives.
//!  - **`allow_eol`.** Normal mode puts the cursor *on* a character, so
//!    the rightmost legal offset is the line's last codepoint. Insert
//!    mode and operator-pending `$` go one further, to the newline
//!    itself. Callers pass which they want rather than there being two
//!    copies of each motion.

const std = @import("std");
const Buffer = @import("buffer.zig").Buffer;

/// vim's three character classes. Bytes >= 0x80 are all `word`, so a run
/// of CJK or accented text is one word rather than one word per byte --
/// close enough to vim's per-script classes for `w`/`b`/`e` to feel right
/// without a Unicode table.
pub const CharClass = enum { blank, punct, word };

/// `big` is vim's WORD (`W`/`B`/`E`): punctuation counts as part of the
/// word, so only whitespace separates.
pub fn classOf(b: u8, big: bool) CharClass {
    if (b == ' ' or b == '\t' or b == '\n' or b == '\r') return .blank;
    if (big) return .word;
    if (b >= 0x80) return .word;
    if (std.ascii.isAlphanumeric(b) or b == '_') return .word;
    return .punct;
}

fn isContinuation(b: u8) bool {
    return b & 0xC0 == 0x80;
}

/// The line's rightmost legal cursor offset -- see the `allow_eol` note
/// in this file's header.
pub fn lineLimit(buf: *const Buffer, line: usize, allow_eol: bool) usize {
    const end = buf.lineEnd(line);
    if (allow_eol) return end;
    const start = buf.lineStart(line);
    if (end == start) return start;
    return prevCodepoint(buf, end);
}

pub fn prevCodepoint(buf: *const Buffer, off: usize) usize {
    if (off == 0) return 0;
    var i = @min(off, buf.len()) - 1;
    while (i > 0 and isContinuation(buf.byteAt(i))) i -= 1;
    return i;
}

pub fn nextCodepoint(buf: *const Buffer, off: usize) usize {
    const n = buf.len();
    if (off >= n) return n;
    const seq = std.unicode.utf8ByteSequenceLength(buf.byteAt(off)) catch 1;
    return @min(off + seq, n);
}

/// Snaps `off` back to the nearest codepoint boundary at or before it,
/// never crossing out of the line it lands in.
fn snapInLine(buf: *const Buffer, line: usize, off: usize) usize {
    const start = buf.lineStart(line);
    var i = off;
    while (i > start and isContinuation(buf.byteAt(i))) i -= 1;
    return i;
}

/// `h` -- stops at the line start, never wrapping to the previous line.
pub fn left(buf: *const Buffer, off: usize, count: usize) usize {
    const start = buf.lineStart(buf.lineAt(off));
    var i = @min(off, buf.len());
    var n: usize = 0;
    while (n < count and i > start) : (n += 1) i = prevCodepoint(buf, i);
    return @max(i, start);
}

/// `l` -- stops at the line's last character (or the newline when
/// `allow_eol`), never wrapping to the next line.
pub fn right(buf: *const Buffer, off: usize, count: usize, allow_eol: bool) usize {
    const limit = lineLimit(buf, buf.lineAt(off), allow_eol);
    var i = @min(off, buf.len());
    var n: usize = 0;
    while (n < count and i < limit) : (n += 1) i = nextCodepoint(buf, i);
    return @min(i, limit);
}

/// The offset `count` lines down (`j`), landing on byte column `col` --
/// the "sticky" column the editor remembers so a walk through a short
/// line and back out returns to where it started.
pub fn down(buf: *const Buffer, off: usize, count: usize, col: usize, allow_eol: bool) usize {
    const line = @min(buf.lineAt(off) + count, buf.lineCount() - 1);
    return atColumn(buf, line, col, allow_eol);
}

/// `k`.
pub fn up(buf: *const Buffer, off: usize, count: usize, col: usize, allow_eol: bool) usize {
    const line = buf.lineAt(off) -| count;
    return atColumn(buf, line, col, allow_eol);
}

/// Byte column `col` of `line`, clamped to the line and snapped to a
/// codepoint boundary.
pub fn atColumn(buf: *const Buffer, line: usize, col: usize, allow_eol: bool) usize {
    const start = buf.lineStart(line);
    const limit = lineLimit(buf, line, allow_eol);
    return snapInLine(buf, line, @min(start + col, limit));
}

/// `0`.
pub fn lineStart(buf: *const Buffer, off: usize) usize {
    return buf.lineStart(buf.lineAt(off));
}

/// `^` -- the first non-whitespace character, or the line's last legal
/// offset for an all-blank line.
pub fn firstNonBlank(buf: *const Buffer, off: usize) usize {
    const line = buf.lineAt(off);
    const start = buf.lineStart(line);
    const end = buf.lineEnd(line);
    var i = start;
    while (i < end and (buf.byteAt(i) == ' ' or buf.byteAt(i) == '\t')) i += 1;
    return @min(i, lineLimit(buf, line, false));
}

/// `$`.
pub fn lineEnd(buf: *const Buffer, off: usize, allow_eol: bool) usize {
    return lineLimit(buf, buf.lineAt(off), allow_eol);
}

/// `gg` / `G` / `:<n>` -- the first non-blank character of `line`
/// (clamped to the last line).
pub fn gotoLine(buf: *const Buffer, line: usize) usize {
    const clamped = @min(line, buf.lineCount() - 1);
    return firstNonBlank(buf, buf.lineStart(clamped));
}

/// Whether `off` is the start of an empty line. vim treats one as a word
/// on its own, which is why `w` stops on a blank line rather than
/// skipping the run of newlines around it.
fn isEmptyLine(buf: *const Buffer, off: usize) bool {
    if (off >= buf.len()) return false;
    if (buf.byteAt(off) != '\n') return false;
    return buf.posOf(off).col == 0;
}

/// `w` / `W`: past the current run, then past any whitespace, stopping
/// early on an empty line.
pub fn wordForward(buf: *const Buffer, off: usize, count: usize, big: bool) usize {
    var i = @min(off, buf.len());
    var n: usize = 0;
    while (n < count) : (n += 1) i = wordForwardOnce(buf, i, big);
    return i;
}

fn wordForwardOnce(buf: *const Buffer, off: usize, big: bool) usize {
    const end = buf.len();
    var i = off;
    if (i >= end) return end;

    const start_class = classOf(buf.byteAt(i), big);
    if (start_class != .blank) {
        while (i < end and classOf(buf.byteAt(i), big) == start_class) i += 1;
    } else {
        // Already on whitespace: still make progress, or a count would
        // spin in place.
        i += 1;
    }

    while (i < end) {
        if (isEmptyLine(buf, i)) return i;
        if (classOf(buf.byteAt(i), big) != .blank) break;
        i += 1;
    }
    return i;
}

/// `b` / `B`: back over whitespace, then to the start of that run.
pub fn wordBackward(buf: *const Buffer, off: usize, count: usize, big: bool) usize {
    var i = @min(off, buf.len());
    var n: usize = 0;
    while (n < count) : (n += 1) i = wordBackwardOnce(buf, i, big);
    return i;
}

fn wordBackwardOnce(buf: *const Buffer, off: usize, big: bool) usize {
    if (off == 0) return 0;
    var i = off - 1;
    while (true) {
        if (isEmptyLine(buf, i)) return i;
        if (classOf(buf.byteAt(i), big) != .blank) break;
        if (i == 0) return 0;
        i -= 1;
    }
    const c = classOf(buf.byteAt(i), big);
    while (i > 0 and classOf(buf.byteAt(i - 1), big) == c) i -= 1;
    return i;
}

/// `e` / `E`: forward to the last character of the next word. Unlike `w`
/// this always advances first, so sitting on a word's last character
/// moves to the next word rather than staying put.
pub fn wordEnd(buf: *const Buffer, off: usize, count: usize, big: bool) usize {
    var i = @min(off, buf.len());
    var n: usize = 0;
    while (n < count) : (n += 1) i = wordEndOnce(buf, i, big);
    return i;
}

fn wordEndOnce(buf: *const Buffer, off: usize, big: bool) usize {
    const end = buf.len();
    if (end == 0) return 0;
    var i = @min(off, end - 1) + 1;
    while (i < end and classOf(buf.byteAt(i), big) == .blank) i += 1;
    if (i >= end) return end - 1;

    const c = classOf(buf.byteAt(i), big);
    while (i + 1 < end and classOf(buf.byteAt(i + 1), big) == c) i += 1;
    return i;
}

/// Pulls an offset back onto a legal normal-mode position: on a
/// character, on a codepoint boundary, within its own line.
pub fn clampNormal(buf: *const Buffer, off: usize) usize {
    const capped = @min(off, buf.len());
    const line = buf.lineAt(capped);
    return snapInLine(buf, line, @min(capped, lineLimit(buf, line, false)));
}
