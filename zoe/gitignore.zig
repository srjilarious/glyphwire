// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: GPL-3.0-or-later

//! `.gitignore` matching, for the file tree and the two searches over it.
//!
//! A `Stack` is the set of ignore files in scope while a walk is somewhere
//! in the tree: one frame per directory that had a `.gitignore`, pushed on
//! the way down and popped on the way back up. Matching runs the frames
//! **outermost first** and keeps the last verdict, which is what makes a
//! deeper file's `!keep-this` override a parent's `*`.
//!
//! Git's own rule, and the one thing about this that surprises people: the
//! *last* matching pattern wins, not the most specific one. `*.log`
//! followed by `!important.log` keeps the latter; the same two lines in the
//! other order do not.
//!
//! What it does not do: `.git/info/exclude` and the global
//! `core.excludesFile`. Both are per-checkout or per-user settings that
//! rarely change what a source tree looks like, and reading them would mean
//! parsing git config. Everything a repository commits is covered.
//!
//! Pure apart from `Stack.pushDir`, which is the only part that reads a
//! file, so `tests/zoe_tests.zig` exercises the matcher by building
//! patterns directly.

const std = @import("std");

/// The most bytes read from any one `.gitignore`. Generous next to a real
/// one (a few hundred bytes); a guard against a file that isn't really an
/// ignore list.
pub const max_file_bytes: usize = 256 * 1024;

/// One parsed line.
pub const Pattern = struct {
    /// The glob, owned, with the `!` and any trailing `/` stripped and
    /// surrounding whitespace trimmed.
    glob: []u8,
    /// A `!` line: a match here *un*-ignores rather than ignores.
    negated: bool = false,
    /// A trailing `/`: matches directories only.
    dir_only: bool = false,
    /// The glob contained a `/` other than a trailing one, so it is
    /// matched against the path relative to the `.gitignore`'s own
    /// directory rather than against the file name alone. A leading `/`
    /// sets this too (and is stripped), which is exactly what anchoring
    /// means.
    rooted: bool = false,
};

/// The patterns from one `.gitignore`, and where it sat.
pub const Frame = struct {
    /// The directory holding the file, relative to the walk root, `/`
    /// separated and without a trailing slash. Empty for the root's own
    /// `.gitignore`. Owned.
    dir: []u8,
    patterns: []Pattern,
};

/// Whether a path is ignored, and by which kind of rule -- `.none` when no
/// pattern matched at all, which is not the same as an explicit `!`.
pub const Verdict = enum { none, ignored, included };

/// The ignore files in scope, outermost first. Push a directory's frame on
/// the way into it and pop on the way out, and `match` is correct at every
/// point in the walk.
pub const Stack = struct {
    alloc: std.mem.Allocator,
    frames: std.ArrayList(Frame) = .empty,

    pub fn deinit(self: *Stack) void {
        while (self.frames.items.len > 0) self.pop();
        self.frames.deinit(self.alloc);
    }

    /// Reads `dir`'s `.gitignore`, if it has one, and pushes a frame.
    /// Returns whether it pushed, so the caller knows whether to pop.
    ///
    /// `rel` is `dir` relative to the walk root; `dir` itself is a path
    /// the process can open. A file that can't be read is treated as
    /// absent -- an unreadable `.gitignore` should hide nothing, not stop
    /// the walk.
    pub fn pushDir(self: *Stack, io: std.Io, dir: []const u8, rel: []const u8) !bool {
        const path = try std.fs.path.join(self.alloc, &.{ dir, ".gitignore" });
        defer self.alloc.free(path);

        const text = std.Io.Dir.cwd().readFileAlloc(io, path, self.alloc, .limited(max_file_bytes)) catch return false;
        defer self.alloc.free(text);

        return self.pushText(rel, text);
    }

    /// Pushes a frame from already-read text. `pushDir` is the only caller
    /// in the program; tests use it to build a stack without a filesystem.
    pub fn pushText(self: *Stack, rel: []const u8, text: []const u8) !bool {
        var patterns: std.ArrayList(Pattern) = .empty;
        errdefer {
            for (patterns.items) |p| self.alloc.free(p.glob);
            patterns.deinit(self.alloc);
        }

        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |raw| {
            const p = (try parseLine(self.alloc, raw)) orelse continue;
            errdefer self.alloc.free(p.glob);
            try patterns.append(self.alloc, p);
        }
        if (patterns.items.len == 0) {
            patterns.deinit(self.alloc);
            return false;
        }

        const dir = try self.alloc.dupe(u8, rel);
        errdefer self.alloc.free(dir);
        try self.frames.append(self.alloc, .{
            .dir = dir,
            .patterns = try patterns.toOwnedSlice(self.alloc),
        });
        return true;
    }

    pub fn pop(self: *Stack) void {
        const f = self.frames.pop() orelse return;
        for (f.patterns) |p| self.alloc.free(p.glob);
        self.alloc.free(f.patterns);
        self.alloc.free(f.dir);
    }

    /// Whether `rel` -- a path relative to the walk root, `/` separated --
    /// is ignored by the frames currently in scope. `is_dir` decides
    /// whether a `dir_only` pattern applies.
    ///
    /// Every frame is consulted, outermost first, and the last pattern to
    /// match wins: git's rule, and the only way a nested `!` can rescue a
    /// file its parent excluded.
    pub fn match(self: *const Stack, rel: []const u8, is_dir: bool) Verdict {
        var verdict: Verdict = .none;
        for (self.frames.items) |frame| {
            // Paths are matched relative to the directory the ignore file
            // sat in; one outside that subtree isn't its business.
            const scoped = relativeTo(rel, frame.dir) orelse continue;
            for (frame.patterns) |p| {
                if (p.dir_only and !is_dir) continue;
                if (matchesPattern(p, scoped)) verdict = if (p.negated) .included else .ignored;
            }
        }
        return verdict;
    }

    /// `Stack.match` reduced to the question callers actually ask.
    pub fn isIgnored(self: *const Stack, rel: []const u8, is_dir: bool) bool {
        return self.match(rel, is_dir) == .ignored;
    }
};

/// `rel` with `dir`'s prefix removed, or null when `rel` isn't under
/// `dir`. An empty `dir` is the walk root, which everything is under.
fn relativeTo(rel: []const u8, dir: []const u8) ?[]const u8 {
    if (dir.len == 0) return rel;
    if (rel.len <= dir.len) return null;
    if (!std.mem.startsWith(u8, rel, dir)) return null;
    if (rel[dir.len] != '/') return null;
    return rel[dir.len + 1 ..];
}

/// Parses one line. Null for a blank line or a `#` comment -- neither is a
/// pattern -- and for a line that is nothing but slashes and whitespace.
fn parseLine(alloc: std.mem.Allocator, raw: []const u8) !?Pattern {
    // A CR from a file written on Windows is whitespace, not a character
    // to match on.
    var line = std.mem.trim(u8, raw, " \t\r");
    if (line.len == 0 or line[0] == '#') return null;

    var negated = false;
    if (line[0] == '!') {
        negated = true;
        line = line[1..];
    }
    // `\!` and `\#` are literal first characters, the two escapes git
    // spells out.
    if (line.len >= 2 and line[0] == '\\' and (line[1] == '!' or line[1] == '#')) line = line[1..];
    if (line.len == 0) return null;

    var dir_only = false;
    if (line[line.len - 1] == '/') {
        dir_only = true;
        line = line[0 .. line.len - 1];
    }

    // A `/` anywhere but the end anchors the pattern to the ignore file's
    // own directory -- including a leading one, which is the explicit way
    // to write it and is stripped once it has said so.
    const rooted = std.mem.indexOfScalar(u8, line, '/') != null;
    if (line[0] == '/') line = line[1..];
    if (line.len == 0) return null;

    return .{
        .glob = try alloc.dupe(u8, line),
        .negated = negated,
        .dir_only = dir_only,
        .rooted = rooted,
    };
}

/// Whether `path` -- relative to the ignore file's directory -- matches.
///
/// An unrooted pattern matches any component of the path, which is what
/// makes a bare `build` in the root ignore `a/b/build` too. A rooted one
/// is matched against the whole relative path. Either way a directory that
/// matches takes everything under it, so `zig-out` also hides
/// `zig-out/bin/x`.
fn matchesPattern(p: Pattern, path: []const u8) bool {
    if (p.rooted) {
        if (globMatch(p.glob, path)) return true;
        // A matched directory carries its subtree: test each prefix of the
        // path that ends at a component boundary.
        var i: usize = 0;
        while (std.mem.indexOfScalarPos(u8, path, i, '/')) |slash| {
            if (globMatch(p.glob, path[0..slash])) return true;
            i = slash + 1;
        }
        return false;
    }

    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |seg| {
        if (seg.len == 0) continue;
        if (globMatch(p.glob, seg)) return true;
    }
    return false;
}

/// Glob match over one string: `*` (any run, never across a `/`), `**`
/// (any run, `/` included), `?` (one character) and `[...]` classes with
/// ranges and a leading `!` or `^` for negation.
///
/// Recursive on `*`, which is the textbook shape and fine here: patterns
/// are a line long and paths are a path long.
pub fn globMatch(glob: []const u8, text: []const u8) bool {
    var g: usize = 0;
    var t: usize = 0;
    while (g < glob.len) {
        switch (glob[g]) {
            '*' => {
                // `**` crosses separators; a single `*` stops at one.
                const double = g + 1 < glob.len and glob[g + 1] == '*';
                const rest = glob[g + (if (double) @as(usize, 2) else 1) ..];
                if (rest.len == 0) {
                    if (double) return true;
                    return std.mem.indexOfScalarPos(u8, text, t, '/') == null;
                }
                var i = t;
                while (true) {
                    if (globMatch(rest, text[i..])) return true;
                    if (i >= text.len) return false;
                    if (!double and text[i] == '/') return false;
                    i += 1;
                }
            },
            '?' => {
                if (t >= text.len or text[t] == '/') return false;
                g += 1;
                t += 1;
            },
            '[' => {
                if (t >= text.len) return false;
                const close = classEnd(glob, g) orelse {
                    // An unterminated `[` is a literal bracket, which is
                    // what a shell does with it too.
                    if (text[t] != '[') return false;
                    g += 1;
                    t += 1;
                    continue;
                };
                if (!classMatches(glob[g + 1 .. close], text[t])) return false;
                g = close + 1;
                t += 1;
            },
            '\\' => {
                // An escape makes the next character literal. A trailing
                // backslash matches itself.
                const lit = if (g + 1 < glob.len) glob[g + 1] else '\\';
                if (t >= text.len or text[t] != lit) return false;
                g += if (g + 1 < glob.len) @as(usize, 2) else 1;
                t += 1;
            },
            else => {
                if (t >= text.len or text[t] != glob[g]) return false;
                g += 1;
                t += 1;
            },
        }
    }
    return t == text.len;
}

/// The index of the `]` closing the class opened at `open`, or null if the
/// class is never closed. A `]` immediately after the `[` (or after its
/// negation mark) is a literal, per the usual glob rule.
fn classEnd(glob: []const u8, open: usize) ?usize {
    var i = open + 1;
    if (i < glob.len and (glob[i] == '!' or glob[i] == '^')) i += 1;
    if (i < glob.len and glob[i] == ']') i += 1;
    while (i < glob.len) : (i += 1) {
        if (glob[i] == ']') return i;
    }
    return null;
}

/// Whether `c` is in the class body `body` -- the text between the
/// brackets, negation mark included.
fn classMatches(body: []const u8, c: u8) bool {
    var items = body;
    var negate = false;
    if (items.len > 0 and (items[0] == '!' or items[0] == '^')) {
        negate = true;
        items = items[1..];
    }

    var hit = false;
    var i: usize = 0;
    while (i < items.len) {
        // `a-z`, but a `-` at either end is a literal.
        if (i + 2 < items.len and items[i + 1] == '-') {
            if (c >= items[i] and c <= items[i + 2]) hit = true;
            i += 3;
            continue;
        }
        if (items[i] == c) hit = true;
        i += 1;
    }
    return hit != negate;
}
