// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: MPL-2.0

//! `.gitignore` matching, for zoe's file tree and the two searches over
//! it, and salacommander's F3 finder.
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
//! A search walk (`walk.zig`) adds two things on top. Showing hidden
//! files there reveals dotfiles but not ignored paths (see
//! `Visibility.searchFinds`), and a `Rescue` lists some ignored paths
//! anyway: the repository's own linked worktrees, and the config's
//! `unignore` globs. A rescued directory starts afresh, the way a nested
//! repository does in git: the ignore files outside it stop applying
//! inside it (`Stack.base`), and its own take over.
//!
//! What it does not do: `.git/info/exclude` and the global
//! `core.excludesFile`. Both are per-checkout or per-user settings that
//! rarely change what a source tree looks like, and reading them would mean
//! parsing git config. Everything a repository commits is covered.
//!
//! Pure apart from `Stack.pushDir` and `linkedWorktrees`, the only parts
//! that read files, so `tests/zoe_tests.zig` exercises the matcher by
//! building patterns directly.

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
    /// Frames below this index are out of scope: the walk is inside a
    /// rescued directory, which the ignore files above it no longer
    /// govern. Set by the walk on the way in and restored on the way out.
    base: usize = 0,

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
        for (self.frames.items[self.base..]) |frame| {
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

/// What a listing or a walk is allowed to show. Off, both dotfiles and
/// anything `.gitignore` excludes are skipped; Ctrl+H turns it on.
///
/// One flag, deliberately: two toggles would mean remembering which of
/// them is hiding the file you are looking for. What "on" reveals depends
/// on the view, though. The tree pane lists every path, ignored ones
/// dimmed, since expanding one folder is cheap and asked for. A search
/// walks the whole tree, where ignored directories (`.zig-cache/`,
/// `.venv/`) would bury everything else, so there it reveals dotfiles
/// only (`searchFinds`). `.git/` stays out either way until you ask,
/// since it is a dotfile.
pub const Visibility = struct {
    show_hidden: bool = false,
    /// The config's `unignore` globs, borrowed: paths a search lists even
    /// though a `.gitignore` excludes them. See `Rescue`.
    unignore: []const []const u8 = &.{},

    /// Whether an entry is one the tree hides by default -- a dotfile, or
    /// a path the `.gitignore` files in scope exclude.
    ///
    /// Deliberately independent of `show_hidden`: with the flag on the
    /// entry is listed, but it is still *a hidden one*, and the pane draws
    /// it dim (`Entry.hidden`) so the toggle explains itself rather than
    /// silently doubling the size of the listing.
    pub fn isHidden(
        _: Visibility,
        ignores: *const Stack,
        name: []const u8,
        rel: []const u8,
        is_dir: bool,
    ) bool {
        if (name.len > 0 and name[0] == '.') return true;
        return ignores.isIgnored(rel, is_dir);
    }

    /// Whether to leave it out of the listing entirely.
    pub fn skips(self: Visibility, hidden: bool) bool {
        return hidden and !self.show_hidden;
    }

    /// What a search walk does with one entry. Unlike the tree listing,
    /// an ignored path stays out even with hidden files shown, unless
    /// `rescue` lists it or it is a directory the walk has to pass
    /// through to reach one that is.
    ///
    /// A rescued path is `.fresh` even when nothing ignores it: a
    /// worktree is its own repository wherever it sits, and the ignore
    /// files around it are never its business.
    pub fn searchFinds(
        self: Visibility,
        ignores: *const Stack,
        rescue: *const Rescue,
        name: []const u8,
        rel: []const u8,
        is_dir: bool,
    ) Found {
        if (name.len > 0 and name[0] == '.' and !self.show_hidden) return .skip;
        if (rescue.rescues(rel)) return .fresh;
        if (!ignores.isIgnored(rel, is_dir)) return .list;
        if (is_dir and rescue.leadsTo(rel)) return .list;
        return .skip;
    }
};

/// `Visibility.searchFinds`'s answer.
pub const Found = enum {
    skip,
    list,
    /// List it, and if it is a directory, walk it with the ignore files
    /// outside it out of scope (`Stack.base`).
    fresh,
};

/// The ignored paths a search lists anyway: the repository's linked git
/// worktrees under the walk root, and the config's `unignore` globs.
///
/// The case it exists for is a worktree kept inside the checkout it
/// belongs to (`.claude/worktrees/x`), under a directory the checkout
/// ignores. A search should find its files but not its `.zig-cache/`,
/// which its own `.gitignore` excludes.
pub const Rescue = struct {
    /// Root-relative paths of the linked worktrees inside the walk root,
    /// owned (`linkedWorktrees`).
    worktrees: [][]u8 = &.{},
    /// Root-relative globs, borrowed. Matched against the whole path, as
    /// a rooted `.gitignore` pattern is.
    globs: []const []const u8 = &.{},

    pub fn deinit(self: *Rescue, alloc: std.mem.Allocator) void {
        for (self.worktrees) |w| alloc.free(w);
        alloc.free(self.worktrees);
        self.* = undefined;
    }

    /// Whether `rel` is itself a rescued path.
    pub fn rescues(self: *const Rescue, rel: []const u8) bool {
        for (self.worktrees) |w| {
            if (std.mem.eql(u8, w, rel)) return true;
        }
        for (self.globs) |g| {
            if (globMatch(trimSlashes(g), rel)) return true;
        }
        return false;
    }

    /// Whether directory `rel` has a rescued path somewhere below it, so
    /// a walk must go through it even though it is ignored. Only the
    /// directories on the way are walked: their other contents stay
    /// ignored.
    pub fn leadsTo(self: *const Rescue, rel: []const u8) bool {
        for (self.worktrees) |w| {
            if (w.len > rel.len and w[rel.len] == '/' and std.mem.startsWith(u8, w, rel)) return true;
        }
        for (self.globs) |g| {
            if (globPrefixMatches(trimSlashes(g), rel)) return true;
        }
        return false;
    }
};

/// A glob as written in the config, without a leading `/` (root-anchored
/// is the only meaning it has here anyway) or a trailing one.
fn trimSlashes(glob: []const u8) []const u8 {
    return std.mem.trim(u8, glob, "/");
}

/// Whether directory `rel` could be an ancestor of something `glob`
/// matches: each of its components matches the glob's component at the
/// same depth, and the glob has more after them. A `**` component can
/// stand for any depth, so reaching one answers yes.
fn globPrefixMatches(glob: []const u8, rel: []const u8) bool {
    var gs = std.mem.splitScalar(u8, glob, '/');
    var rs = std.mem.splitScalar(u8, rel, '/');
    while (rs.next()) |r| {
        const g = gs.next() orelse return false;
        if (std.mem.indexOf(u8, g, "**") != null) return true;
        if (!globMatch(g, r)) return false;
    }
    return gs.next() != null;
}

/// The linked worktrees of the git repository `root` is in that sit
/// inside `root`, as paths relative to it. Read straight from the
/// repository's `worktrees/*/gitdir` files, which git keeps pointing at
/// each worktree's `.git`, so no `git` process. Empty when `root` isn't
/// in a repository or none of its worktrees are under it; anything that
/// can't be read counts as absent.
pub fn linkedWorktrees(alloc: std.mem.Allocator, io: std.Io, root: []const u8) ![][]u8 {
    var out: std.ArrayList([]u8) = .empty;
    errdefer {
        for (out.items) |p| alloc.free(p);
        out.deinit(alloc);
    }

    const root_abs = std.Io.Dir.cwd().realPathFileAlloc(io, root, alloc) catch return out.toOwnedSlice(alloc);
    defer alloc.free(root_abs);
    const git_dir = (try commonGitDir(alloc, io, root_abs)) orelse return out.toOwnedSlice(alloc);
    defer alloc.free(git_dir);

    const wt_path = try std.fs.path.join(alloc, &.{ git_dir, "worktrees" });
    defer alloc.free(wt_path);
    var wt_dir = std.Io.Dir.cwd().openDir(io, wt_path, .{ .iterate = true }) catch return out.toOwnedSlice(alloc);
    defer wt_dir.close(io);

    var it = wt_dir.iterate();
    while (it.next(io) catch null) |e| {
        if (e.kind != .directory) continue;
        const gitdir_file = try std.fs.path.join(alloc, &.{ wt_path, e.name, "gitdir" });
        defer alloc.free(gitdir_file);
        const text = std.Io.Dir.cwd().readFileAlloc(io, gitdir_file, alloc, .limited(std.fs.max_path_bytes)) catch continue;
        defer alloc.free(text);
        // `<worktree>/.git`, newline-terminated.
        const dot_git = std.mem.trim(u8, text, " \t\r\n");
        const wt = std.fs.path.dirname(dot_git) orelse continue;
        if (wt.len <= root_abs.len + 1) continue;
        if (!std.mem.startsWith(u8, wt, root_abs) or wt[root_abs.len] != '/') continue;
        try out.append(alloc, try alloc.dupe(u8, wt[root_abs.len + 1 ..]));
    }
    return out.toOwnedSlice(alloc);
}

/// The shared git directory of the repository `dir` (absolute) is in:
/// the first `.git` found walking up. A `.git` *file* means `dir` is in a
/// linked worktree, whose own git dir names the shared one in its
/// `commondir`. Null when there is no repository. Owned.
fn commonGitDir(alloc: std.mem.Allocator, io: std.Io, dir: []const u8) !?[]u8 {
    var cur: []const u8 = dir;
    while (true) {
        const dot_git = try std.fs.path.join(alloc, &.{ cur, ".git" });
        defer alloc.free(dot_git);
        if (std.Io.Dir.cwd().statFile(io, dot_git, .{})) |st| {
            if (st.kind == .directory) return try alloc.dupe(u8, dot_git);
            return linkedCommonDir(alloc, io, cur, dot_git);
        } else |_| {}
        cur = std.fs.path.dirname(cur) orelse return null;
    }
}

/// `commonGitDir` for a `.git` file: it reads `gitdir: <own git dir>`,
/// and that directory's `commondir` (relative to it) is the shared one.
fn linkedCommonDir(alloc: std.mem.Allocator, io: std.Io, holder: []const u8, dot_git: []const u8) !?[]u8 {
    const text = std.Io.Dir.cwd().readFileAlloc(io, dot_git, alloc, .limited(std.fs.max_path_bytes)) catch return null;
    defer alloc.free(text);
    const prefix = "gitdir:";
    const line = std.mem.trim(u8, text, " \t\r\n");
    if (!std.mem.startsWith(u8, line, prefix)) return null;
    const own = try std.fs.path.resolve(alloc, &.{ holder, std.mem.trim(u8, line[prefix.len..], " \t") });
    defer alloc.free(own);

    const common_file = try std.fs.path.join(alloc, &.{ own, "commondir" });
    defer alloc.free(common_file);
    const common = std.Io.Dir.cwd().readFileAlloc(io, common_file, alloc, .limited(std.fs.max_path_bytes)) catch return null;
    defer alloc.free(common);
    return try std.fs.path.resolve(alloc, &.{ own, std.mem.trim(u8, common, " \t\r\n") });
}
