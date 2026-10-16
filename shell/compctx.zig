// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: GPL-3.0-or-later

//! What Tab completion is completing: the word under the caret and the
//! command it belongs to, read with the same quoting rules the shell runs
//! the line with (`wordsplit.readWord`), plus the escaping that puts a
//! completed name back into that word. Pure; `shell/completion.zig` does
//! the directory scans, `$PATH`, Lua and fish lookups on top of it.

const std = @import("std");
const wordsplit = @import("applib").wordsplit;

/// The completion context for the text before the caret.
pub const Context = struct {
    /// Byte offset where the word under the caret starts (its raw,
    /// still-quoted form), or the caret itself after a blank.
    word_start: usize,
    /// That word's text up to the caret, unquoted and `$` / `~`
    /// expanded: what candidates are matched against. Owned.
    word: []u8,
    /// The quote still open at the caret (`'` or `"`), else 0. Completing
    /// inside one escapes for that quote and closes it after a final
    /// match, the way bash and fish do.
    open_quote: u8,
    /// Byte offset where the command holding the word starts: the line's
    /// start, or just past the last `|`, `;`, `&&` or `||`. What fish is
    /// handed as context.
    cmd_start: usize,
    /// The command's words before the one under the caret, unquoted and
    /// expanded, with leading `NAME=VALUE` assignments and redirect
    /// targets left out. `words[0]` is the command name. Owned.
    words: [][]u8,
    /// The word follows a redirect operator (`>`, `2>>`, `<`, `&>`): a
    /// file name, whatever the command.
    after_redirect: bool,

    /// Whether the word is the command name: nothing but assignments
    /// before it in its command, and not a redirect target.
    pub fn commandPosition(self: *const Context) bool {
        return self.words.len == 0 and !self.after_redirect;
    }

    pub fn deinit(self: *Context, alloc: std.mem.Allocator) void {
        alloc.free(self.word);
        for (self.words) |w| alloc.free(w);
        alloc.free(self.words);
    }
};

/// Reads `before` -- the line up to the caret -- into a `Context`.
pub fn scan(alloc: std.mem.Allocator, before: []const u8, exp: wordsplit.Expansion) std.mem.Allocator.Error!Context {
    var words: std.ArrayList([]u8) = .empty;
    errdefer {
        for (words.items) |w| alloc.free(w);
        words.deinit(alloc);
    }
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);

    var cmd_start: usize = 0;
    var after_redirect = false;

    var i = wordsplit.skipBlanks(before, 0);
    while (i < before.len) {
        const c = before[i];
        if (wordsplit.isOperatorByte(c)) {
            const op_len = operatorLen(before, i);
            if (c == '|' or c == ';' or (c == '&' and op_len == 2 and before[i + 1] == '&')) {
                // A new command starts after `|`, `||`, `;` or `&&`.
                for (words.items) |w| alloc.free(w);
                words.clearRetainingCapacity();
                after_redirect = false;
                cmd_start = i + op_len;
            } else if (c != '&' or op_len > 1) {
                after_redirect = true;
            }
            i = wordsplit.skipBlanks(before, i + op_len);
            continue;
        }

        const start = i;
        buf.clearRetainingCapacity();
        const w = try wordsplit.readWord(alloc, &buf, before, start, .blanks_and_operators, exp);
        if (w.end >= before.len) {
            // The word runs up to the caret: it's the one being completed.
            return .{
                .word_start = start,
                .word = try buf.toOwnedSlice(alloc),
                .open_quote = w.open_quote,
                .cmd_start = cmd_start,
                .words = try words.toOwnedSlice(alloc),
                .after_redirect = after_redirect,
            };
        }

        const fd_designator = w.end - start == 1 and std.ascii.isDigit(before[start]) and before[w.end] == '>';
        if (after_redirect) {
            after_redirect = false; // that was the target
        } else if (fd_designator) {
            // `2>` -- part of the redirect that follows, not a word.
        } else if (words.items.len == 0 and isAssignment(before[start..w.end])) {
            // `FOO=bar cmd`: the command is still to come.
        } else if (w.present) {
            try words.append(alloc, try alloc.dupe(u8, buf.items));
        }
        i = wordsplit.skipBlanks(before, w.end);
    }

    return .{
        .word_start = before.len,
        .word = try alloc.dupe(u8, ""),
        .open_quote = 0,
        .cmd_start = cmd_start,
        .words = try words.toOwnedSlice(alloc),
        .after_redirect = after_redirect,
    };
}

/// The length of the operator lexeme at `line[i]`: `||`, `&&`, `>>`,
/// `>&N`, `&>`, `&>>`, or a single byte.
fn operatorLen(line: []const u8, i: usize) usize {
    const c = line[i];
    const next: u8 = if (i + 1 < line.len) line[i + 1] else 0;
    switch (c) {
        '|' => return if (next == '|') 2 else 1,
        '&' => {
            if (next == '&') return 2;
            if (next == '>') return if (i + 2 < line.len and line[i + 2] == '>') 3 else 2;
            return 1;
        },
        '>' => {
            if (next == '>') return 2;
            if (next == '&') return if (i + 2 < line.len and std.ascii.isDigit(line[i + 2])) 3 else 2;
            return 1;
        },
        else => return 1,
    }
}

/// A plainly written `NAME=...` word.
fn isAssignment(raw: []const u8) bool {
    const ne = wordsplit.nameEnd(raw, 0);
    return ne > 0 and ne < raw.len and raw[ne] == '=';
}

/// `text` escaped to go into a word whose open quote at the insertion
/// point is `open_quote`: backslash escapes outside quotes
/// (`wordsplit.escapeSpecial`), `'\''` for an embedded `'` inside single
/// quotes, and `\` before `"`, `\`, `$` and `` ` `` inside double quotes.
/// Caller owns the result.
pub fn escapeInsert(alloc: std.mem.Allocator, text: []const u8, open_quote: u8) std.mem.Allocator.Error![]u8 {
    switch (open_quote) {
        0 => return wordsplit.escapeSpecial(alloc, text),
        '\'' => {
            var out: std.ArrayList(u8) = .empty;
            errdefer out.deinit(alloc);
            for (text) |c| {
                if (c == '\'') try out.appendSlice(alloc, "'\\''") else try out.append(alloc, c);
            }
            return out.toOwnedSlice(alloc);
        },
        else => {
            var out: std.ArrayList(u8) = .empty;
            errdefer out.deinit(alloc);
            for (text) |c| {
                if (c == '"' or c == '\\' or c == '$' or c == '`') try out.append(alloc, '\\');
                try out.append(alloc, c);
            }
            return out.toOwnedSlice(alloc);
        },
    }
}

/// One line of `fish -c 'complete -C ...'` output: the completed token
/// (raw, unescaped -- fish unescapes it for `-C`) and its description.
pub const FishItem = struct {
    text: []const u8,
    desc: []const u8,
};

/// Splits fish's `complete -C` output into items, in fish's order. Each
/// line is `token` or `token<TAB>description`; blank lines are skipped.
/// The slices point into `bytes`; free the outer slice with `alloc`.
pub fn parseFishOutput(alloc: std.mem.Allocator, bytes: []const u8) std.mem.Allocator.Error![]FishItem {
    var out: std.ArrayList(FishItem) = .empty;
    errdefer out.deinit(alloc);
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len == 0) continue;
        if (std.mem.indexOfScalar(u8, line, '\t')) |tab| {
            if (tab == 0) continue;
            try out.append(alloc, .{ .text = line[0..tab], .desc = line[tab + 1 ..] });
        } else {
            try out.append(alloc, .{ .text = line, .desc = "" });
        }
    }
    return out.toOwnedSlice(alloc);
}

/// A word a history autosuggestion would complete or add that has to
/// name something that still exists for the suggestion to be offered
/// (see `suggestedPaths`).
pub const SuggestedPath = struct {
    /// Unquoted and `$` / `~` expanded. Owned.
    path: []u8,
    kind: Kind,

    pub const Kind = enum {
        /// A `cd` / `pushd` target: must be a directory.
        dir,
        /// Plainly a path (`/`, `./`, `../`, `~`, or `.` / `..` itself):
        /// must exist.
        definite,
        /// Any other word with a `/` in it: a path only if its parent
        /// directory exists (`.claude/worktrees/old`), otherwise
        /// something else that happens to have a slash (`origin/main`,
        /// `feature/x`), and left alone.
        maybe,
    };
};

/// The words of history `entry` that end past `typed_len` -- the one a
/// suggestion would finish and every one it would add, never a word the
/// user already typed in full -- and that could be paths. Flags, URLs,
/// unquoted globs and leading assignments are left out, as are words
/// with no `/` (except a `cd` target). Free with `freeSuggestedPaths`.
pub fn suggestedPaths(
    alloc: std.mem.Allocator,
    entry: []const u8,
    typed_len: usize,
    exp: wordsplit.Expansion,
) std.mem.Allocator.Error![]SuggestedPath {
    var out: std.ArrayList(SuggestedPath) = .empty;
    errdefer {
        for (out.items) |p| alloc.free(p.path);
        out.deinit(alloc);
    }
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);

    // Which word of its command the next one is (0 = the name), and
    // whether that command is `cd` / `pushd`.
    var arg_index: usize = 0;
    var cmd_is_cd = false;

    var i = wordsplit.skipBlanks(entry, 0);
    while (i < entry.len) {
        const c = entry[i];
        if (wordsplit.isOperatorByte(c)) {
            if (c == '|' or c == ';' or c == '&') {
                arg_index = 0;
                cmd_is_cd = false;
            }
            i = wordsplit.skipBlanks(entry, i + operatorLen(entry, i));
            continue;
        }

        const start = i;
        buf.clearRetainingCapacity();
        const w = try wordsplit.readWord(alloc, &buf, entry, start, .blanks_and_operators, exp);
        i = wordsplit.skipBlanks(entry, w.end);
        if (!w.present) continue;
        const raw = entry[start..w.end];
        if (arg_index == 0 and isAssignment(raw)) continue;

        const index = arg_index;
        arg_index += 1;
        const text = buf.items;
        if (index == 0) cmd_is_cd = std.mem.eql(u8, text, "cd") or std.mem.eql(u8, text, "pushd");

        if (w.end <= typed_len) continue;
        if (text.len == 0 or text[0] == '-') continue;
        if (std.mem.indexOf(u8, text, "://") != null) continue;
        if (!w.quoted and std.mem.indexOfAny(u8, raw, "*?[") != null) continue;

        const kind: SuggestedPath.Kind = if (cmd_is_cd and index == 1)
            .dir
        else if (text[0] == '/' or std.mem.startsWith(u8, text, "./") or
            std.mem.startsWith(u8, text, "../") or
            std.mem.eql(u8, text, ".") or std.mem.eql(u8, text, ".."))
            .definite
        else if (std.mem.indexOfScalar(u8, text, '/') != null)
            .maybe
        else
            continue;
        try out.ensureUnusedCapacity(alloc, 1);
        out.appendAssumeCapacity(.{ .path = try alloc.dupe(u8, text), .kind = kind });
    }
    return out.toOwnedSlice(alloc);
}

pub fn freeSuggestedPaths(alloc: std.mem.Allocator, paths: []SuggestedPath) void {
    for (paths) |p| alloc.free(p.path);
    alloc.free(paths);
}
