const std = @import("std");

/// Single-segment shell glob matching for glyphwire-shell's `*` expansion.
///
/// Supports `*` (any run, including empty), `?` (exactly one character),
/// and `[...]` character classes (`[abc]`, ranges `[a-z]`, negation with
/// a leading `!` or `^`). There is no `/` handling here on purpose: the
/// shell only expands wildcards in the *final* path segment for now (see
/// decisions.md), so a pattern reaching this function never contains a
/// slash. A malformed class (`[` with no closing `]`) is treated as a
/// literal `[`, same as bash.
///
/// The "don't match a leading dot" rule is enforced by the caller
/// (`Prompt.expandGlobs` skips dot-entries unless the pattern's first
/// byte is a literal `.`), not here.

/// Whether `s` contains an unescaped glob metacharacter worth trying to
/// expand: `*`, `?`, or a `[` that has a later `]` to close it.
pub fn hasWildcard(s: []const u8) bool {
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        switch (s[i]) {
            '\\' => i += 1, // skip the escaped byte
            '*', '?' => return true,
            '[' => if (std.mem.indexOfScalarPos(u8, s, i + 1, ']') != null) return true,
            else => {},
        }
    }
    return false;
}

/// Whether `name` matches glob `pattern` (whole-string match).
pub fn match(pattern: []const u8, name: []const u8) bool {
    var p: usize = 0;
    var n: usize = 0;
    // Backtrack point for the most recent `*`: where it is in the
    // pattern, and how much of `name` we've let it consume so far.
    var star_p: ?usize = null;
    var star_n: usize = 0;

    while (n < name.len) {
        if (p < pattern.len) {
            switch (pattern[p]) {
                '*' => {
                    star_p = p;
                    star_n = n;
                    p += 1;
                    continue;
                },
                '?' => {
                    p += 1;
                    n += 1;
                    continue;
                },
                '[' => {
                    var pp = p;
                    if (matchClass(pattern, &pp, name[n])) {
                        p = pp;
                        n += 1;
                        continue;
                    }
                },
                else => {
                    if (pattern[p] == name[n]) {
                        p += 1;
                        n += 1;
                        continue;
                    }
                },
            }
        }

        // Fell through: current pattern position doesn't match `name[n]`.
        // Retry from the last `*`, letting it swallow one more character.
        if (star_p) |sp| {
            p = sp + 1;
            star_n += 1;
            n = star_n;
        } else {
            return false;
        }
    }

    // `name` exhausted -- the rest of the pattern must be all `*`.
    while (p < pattern.len and pattern[p] == '*') p += 1;
    return p == pattern.len;
}

/// `p.*` points at a `[`. If it names a well-formed class, advances
/// `p.*` past the closing `]` and returns whether `ch` is in the class
/// (honouring a leading `!`/`^` negation). If malformed (no `]`),
/// advances `p.*` by one and returns `ch == '['`.
fn matchClass(pattern: []const u8, p: *usize, ch: u8) bool {
    const close = std.mem.indexOfScalarPos(u8, pattern, p.* + 1, ']') orelse {
        p.* += 1;
        return ch == '[';
    };

    var i = p.* + 1;
    var negate = false;
    if (i < close and (pattern[i] == '!' or pattern[i] == '^')) {
        negate = true;
        i += 1;
    }

    var found = false;
    while (i < close) {
        // `a-z` range (but a `-` at either edge is a literal `-`).
        if (i + 2 < close and pattern[i + 1] == '-') {
            if (ch >= pattern[i] and ch <= pattern[i + 2]) found = true;
            i += 3;
        } else {
            if (ch == pattern[i]) found = true;
            i += 1;
        }
    }

    p.* = close + 1;
    return found != negate;
}
