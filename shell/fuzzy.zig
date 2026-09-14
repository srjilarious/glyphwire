// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: GPL-3.0-or-later

//! Minimal subsequence fuzzy matching for `gw-hist`'s Ctrl+R history
//! search: `query`'s characters just have to appear in `text` in order,
//! the same rule fzf/McFly use in their simplest mode. Deliberately no
//! contextual scoring (directory, frequency, recency-weighted decay) --
//! see `docs/decisions.md`'s "Shell result pipe / Ctrl+R history search"
//! entry for why that was left out of this round.

const std = @import("std");

/// Case-insensitive subsequence match: true if every character of
/// `query` appears in `text`, in order, possibly with other characters
/// between them. An empty `query` matches everything, so a freshly
/// opened search shows the whole history.
pub fn matches(text: []const u8, query: []const u8) bool {
    if (query.len == 0) return true;
    var ti: usize = 0;
    for (query) |qc| {
        const want = std.ascii.toLower(qc);
        while (true) {
            if (ti >= text.len) return false;
            const got = std.ascii.toLower(text[ti]);
            ti += 1;
            if (got == want) break;
        }
    }
    return true;
}

/// Index just past the earliest position where `query` completes as a
/// subsequence of `text`, greedily taking the first available occurrence
/// of each character -- i.e. the smallest `end` for which
/// `text[0..end]` alone already satisfies `matches`. `null` if `query`
/// doesn't match `text` at all.
fn forwardEnd(text: []const u8, query: []const u8) ?usize {
    var ti: usize = 0;
    for (query) |qc| {
        const want = std.ascii.toLower(qc);
        while (ti < text.len and std.ascii.toLower(text[ti]) != want) : (ti += 1) {}
        if (ti >= text.len) return null;
        ti += 1;
    }
    return ti - 1;
}

/// Given `end` (from `forwardEnd`), walks `query` backward from its last
/// character to find the latest possible start of a subsequence match
/// that still ends at `end` -- the other half of squeezing the match
/// into its tightest span.
fn backwardStart(text: []const u8, query: []const u8, end: usize) usize {
    var ti: usize = end;
    var qi: usize = query.len;
    while (qi > 0) {
        qi -= 1;
        const want = std.ascii.toLower(query[qi]);
        while (std.ascii.toLower(text[ti]) != want) : (ti -= 1) {}
        if (qi > 0) ti -= 1;
    }
    return ti;
}

/// Lower is a better match: the length of the tightest contiguous span
/// of `text` that contains `query` as a subsequence -- `"gls"` matching
/// inside `"git log -s"` (span 5, `"log -s"`... narrower once tightened)
/// scores better than the same three letters spread across a much longer
/// line. `0` for an empty query (everything matches equally well);
/// `null` if `query` doesn't match at all (see `matches`).
///
/// Ties (e.g. two lines that both contain `query` as one contiguous
/// substring) are left to the caller to break -- `gw-hist` does that by
/// a stable sort over history already ordered newest-first, so an
/// earlier tie wins on recency.
pub fn score(text: []const u8, query: []const u8) ?usize {
    if (query.len == 0) return 0;
    const end = forwardEnd(text, query) orelse return null;
    const start = backwardStart(text, query, end);
    return end - start + 1;
}
