const std = @import("std");

/// Pure string helpers for glyphwire-shell's Tab completion. The actual
/// directory scan and the edits to the on-screen line live in
/// `shell/main.zig` (`Prompt.doComplete`); everything here is testable
/// with no filesystem or IO.
/// The `[start, end)` byte range of the "word" the cursor sits in, used
/// to decide what a Tab press should complete. A word boundary is an
/// unescaped space or tab; a `\` immediately before a space keeps that
/// space part of the word (so `my\ file` is one word).
///
/// Quoting is deliberately NOT interpreted here -- a Tab inside `'...'`
/// treats the quote as an ordinary word character. That matches the
/// shell's overall minimal-quoting stance and keeps this function pure
/// string math; revisit if/when completion needs to be quote-aware.
pub const WordRange = struct { start: usize, end: usize };

pub fn wordRange(line: []const u8, cursor: usize) WordRange {
    std.debug.assert(cursor <= line.len);

    var start = cursor;
    while (start > 0) {
        const ch = line[start - 1];
        if (ch == ' ' or ch == '\t') {
            if (start >= 2 and line[start - 2] == '\\') {
                start -= 2;
                continue;
            }
            break;
        }
        start -= 1;
    }

    var end = cursor;
    while (end < line.len and line[end] != ' ' and line[end] != '\t') end += 1;

    return .{ .start = start, .end = end };
}

/// Splits a completion word into its directory portion (keeping the
/// trailing slash, or empty if there is none) and the final-segment
/// prefix to match directory entries against.
///
///   `src/co`  -> { "src/", "co" }
///   `co`      -> { "",     "co" }
///   `/etc/pa` -> { "/etc/", "pa" }
///   `build/`  -> { "build/", "" }
pub const DirPrefix = struct { dir: []const u8, prefix: []const u8 };

pub fn dirPrefix(word: []const u8) DirPrefix {
    if (std.mem.lastIndexOfScalar(u8, word, '/')) |slash| {
        return .{ .dir = word[0 .. slash + 1], .prefix = word[slash + 1 ..] };
    }
    return .{ .dir = "", .prefix = word };
}

/// Byte length of the longest prefix shared by every string in `names`.
/// 0 for an empty list; `names[0].len` for a single-element list.
pub fn commonPrefixLen(names: []const []const u8) usize {
    if (names.len == 0) return 0;
    var n: usize = names[0].len;
    for (names[1..]) |name| {
        var i: usize = 0;
        while (i < n and i < name.len and name[i] == names[0][i]) : (i += 1) {}
        n = i;
    }
    return n;
}

/// The text a fish-style inline hint should draw after a typed completion
/// prefix for one candidate. Returns `null` if `name` is not actually a
/// completion of `prefix`; otherwise the result is owned by `alloc` and
/// includes the same terminator Tab completion would insert (`/` for a
/// directory, a space for anything else).
pub fn candidateSuffix(alloc: std.mem.Allocator, prefix: []const u8, name: []const u8, is_dir: bool) !?[]u8 {
    if (!std.mem.startsWith(u8, name, prefix)) return null;

    const rest = name[prefix.len..];
    const out = try alloc.alloc(u8, rest.len + 1);
    @memcpy(out[0..rest.len], rest);
    out[rest.len] = if (is_dir) '/' else ' ';
    return out;
}
