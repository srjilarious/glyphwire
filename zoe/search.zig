// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: GPL-3.0-or-later

//! Literal text search over a `Buffer` -- what `/`, `?`, `n`, `N`, `*`
//! and `#` are built out of.
//!
//! **Literal, not regex.** A pattern is the bytes you typed. vim's regex
//! dialect is a language of its own, and the searches an editor session
//! is actually made of ("where else does `renderBufferRow` appear") are
//! substring searches; a regex engine would be a large amount of code and
//! a large amount of surprise for the cases it does buy. `\<`, `.*` and
//! friends are therefore *not* special here -- they match themselves.
//! `*` / `#` still get vim's whole-word behaviour, through the explicit
//! `whole_word` flag rather than by rewriting the pattern into `\<...\>`.
//!
//! **Smartcase.** A pattern with no uppercase letter in it matches
//! case-insensitively; one uppercase letter anywhere makes the whole
//! pattern case-sensitive. That is vim's `ignorecase`+`smartcase` pair,
//! which is what nearly everyone runs, and it means `/editor` finds
//! `Editor` while `/Editor` does not find `editor`. Folding is ASCII
//! only: a pattern in a script with case beyond ASCII matches exactly,
//! which is the honest behaviour without a Unicode case table.
//!
//! Every function here is pure -- buffer in, byte offset out -- like
//! `motion.zig`, so `editor.zig` holds all of the state (the last
//! pattern, the direction, whether the highlight is on) and `ui.zig` can
//! call straight in to find the matches on a row it is about to draw.
//!
//! Matching is a plain forward scan. The buffers zoe opens are source
//! files, and a scan of one is well under a frame; a search index would
//! have to be maintained against every keystroke to save time that is not
//! being lost.

const std = @import("std");
const Buffer = @import("buffer.zig").Buffer;
const motion = @import("motion.zig");

/// How a pattern is compared. `editor.zig` builds one of these from the
/// pattern (smartcase) and the command that started the search (`*` and
/// `#` set `whole_word`).
pub const Opts = struct {
    ignore_case: bool = false,
    whole_word: bool = false,
};

/// A match, plus whether finding it meant running off the end of the
/// buffer and starting again -- vim reports that on the status line.
pub const Hit = struct {
    at: usize,
    wrapped: bool = false,
};

/// The smartcase verdict for `pat`: fold case unless the pattern itself
/// contains an uppercase letter.
pub fn smartIgnoreCase(pat: []const u8) bool {
    for (pat) |b| {
        if (std.ascii.isUpper(b)) return false;
    }
    return true;
}

/// `Opts` for a pattern typed at the `/` prompt.
pub fn optsFor(pat: []const u8, whole_word: bool) Opts {
    return .{ .ignore_case = smartIgnoreCase(pat), .whole_word = whole_word };
}

fn fold(b: u8, ignore_case: bool) u8 {
    return if (ignore_case) std.ascii.toLower(b) else b;
}

fn isWordByte(b: u8) bool {
    return motion.classOf(b, false) == .word;
}

/// Whether `pat` occurs at exactly `at`.
pub fn matchAt(buf: *const Buffer, pat: []const u8, opts: Opts, at: usize) bool {
    if (pat.len == 0 or at + pat.len > buf.len()) return false;
    for (pat, 0..) |p, i| {
        if (fold(buf.byteAt(at + i), opts.ignore_case) != fold(p, opts.ignore_case)) return false;
    }
    if (!opts.whole_word) return true;
    // vim's `\<pat\>`: word characters must not run into the match from
    // either side. The pattern's own edges are not checked -- `*` only
    // ever builds one out of a word in the first place.
    if (at > 0 and isWordByte(buf.byteAt(at - 1))) return false;
    const after = at + pat.len;
    if (after < buf.len() and isWordByte(buf.byteAt(after))) return false;
    return true;
}

/// The first match starting at or after `from` and before `limit`, or
/// null. This is the one `ui.zig` walks a visible row with.
pub fn firstIn(buf: *const Buffer, pat: []const u8, opts: Opts, from: usize, limit: usize) ?usize {
    if (pat.len == 0) return null;
    const stop = @min(limit, buf.len());
    var i = from;
    while (i < stop) : (i += 1) {
        if (matchAt(buf, pat, opts, i)) return i;
    }
    return null;
}

/// The next match strictly after `from`, wrapping to the top of the
/// buffer if `wrap` and nothing follows -- what `/` and `n` step by. A
/// match *at* `from` is skipped, so repeating a search moves.
pub fn forward(buf: *const Buffer, pat: []const u8, opts: Opts, from: usize, wrap: bool) ?Hit {
    if (pat.len == 0) return null;
    const start = if (from >= buf.len()) buf.len() else from + 1;
    if (firstIn(buf, pat, opts, start, buf.len())) |at| return .{ .at = at };
    if (!wrap) return null;
    // Past the end and round: the tail already searched is included so a
    // single match sitting at or before the cursor is still found.
    if (firstIn(buf, pat, opts, 0, start)) |at| return .{ .at = at, .wrapped = true };
    return null;
}

/// The last match strictly before `from`, wrapping to the bottom if
/// `wrap` and nothing precedes it -- `?` and `N`.
pub fn backward(buf: *const Buffer, pat: []const u8, opts: Opts, from: usize, wrap: bool) ?Hit {
    if (pat.len == 0) return null;
    if (lastIn(buf, pat, opts, 0, from)) |at| return .{ .at = at };
    if (!wrap) return null;
    if (lastIn(buf, pat, opts, from, buf.len())) |at| return .{ .at = at, .wrapped = true };
    return null;
}

/// The last match starting at or after `from` and before `limit`.
fn lastIn(buf: *const Buffer, pat: []const u8, opts: Opts, from: usize, limit: usize) ?usize {
    const stop = @min(limit, buf.len());
    if (stop <= from) return null;
    var i = stop;
    while (i > from) {
        i -= 1;
        if (matchAt(buf, pat, opts, i)) return i;
    }
    return null;
}

/// The word under (or, like vim, next on the line after) `at`, as a byte
/// range -- the pattern `*` and `#` search for. Null when the rest of the
/// line holds no word at all.
pub fn wordAt(buf: *const Buffer, at: usize) ?struct { lo: usize, hi: usize } {
    const line = buf.lineAt(at);
    const line_end = buf.lineEnd(line);

    var start = @min(at, line_end);
    // vim scans forward on the line for the first word character rather
    // than failing when the cursor sits on punctuation or a space.
    while (start < line_end and !isWordByte(buf.byteAt(start))) start += 1;
    if (start >= line_end) return null;

    var lo = start;
    while (lo > buf.lineStart(line) and isWordByte(buf.byteAt(lo - 1))) lo -= 1;
    var hi = start;
    while (hi < line_end and isWordByte(buf.byteAt(hi))) hi += 1;
    return .{ .lo = lo, .hi = hi };
}
