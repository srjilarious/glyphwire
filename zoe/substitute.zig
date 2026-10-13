// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: GPL-3.0-or-later

//! `:s` and the line ranges in front of it -- the parsing half. Like
//! `search.zig` everything here is pure: text and a buffer in, values
//! out. `editor.zig` owns the state (the last substitution, the visual
//! marks) and makes the edits.
//!
//! **Ranges.** An address is a line number, `.` (the cursor's line), `$`
//! (the last), `'<` / `'>` (the first and last line of the last visual
//! selection), or nothing, each followed by any number of `+N` / `-N`
//! offsets (a bare `+` or `-` is 1). Two addresses join with `,`; `%` is
//! `1,$`. `;` (vim's "move to the first address, then read the second")
//! and pattern addresses (`/foo/`) are not here: they are rare, and each
//! is a parser of its own.
//!
//! **Patterns are literal**, the same as `/` (see `search.zig`): `:s`
//! matches what `/` would highlight. The only escapes are the delimiter
//! (`\/`), the backslash itself, and `\n` / `\t` for a newline and a tab
//! -- a `\n` lets one substitution join lines. Any other backslash is
//! just a backslash. Case is smartcase unless the `i` or `I` flag says
//! otherwise.
//!
//! **Replacements** keep vim's `&` for "the matched text", with `\&` for
//! a literal ampersand. `\r` and `\n` both insert a line break (vim
//! uses `\r` and inserts a NUL for `\n`, which is never what anyone
//! meant), `\t` a tab, `\\` a backslash, and `\` before the delimiter
//! the delimiter.

const std = @import("std");
const Buffer = @import("buffer.zig").Buffer;
const search = @import("search.zig");

/// A run of whole lines, 0-based and inclusive.
pub const LineRange = struct { first: usize, last: usize };

/// What an address can be resolved against.
pub const Context = struct {
    /// The cursor's line.
    current: usize,
    /// The buffer's last line (`lineCount() - 1`).
    last: usize,
    /// The last visual selection's lines, for `'<` and `'>`; null when
    /// there has been none.
    visual: ?LineRange = null,
};

pub const RangeError = enum {
    /// An address past either end of the buffer (vim's E16).
    invalid_range,
    /// `'<` / `'>` before any visual selection (vim's E20).
    mark_not_set,
};

/// A range at the front of a `:` line and what follows it.
pub const Parsed = struct {
    /// Null when the line starts with no address at all -- a command
    /// that then acts on the cursor's line.
    range: ?LineRange,
    /// Whether the range was spelled as more than one line address
    /// (`a,b` or `%`) or used a mark. A bare `:42` stays the existing
    /// line jump, so only these are new.
    explicit: bool,
    /// The command after the range.
    rest: []const u8,
    /// What was wrong with the range, if anything; `range` is then
    /// clamped into the buffer. Kept rather than returned so the caller
    /// can still read `rest`: `:99999` is a jump that clamps, and only a
    /// range in front of `:s` (or an explicit one) is an error.
    err: ?RangeError = null,
};

/// Reads the range off the front of `line`. A line with no address
/// comes back with a null range and `rest` as the whole line.
pub fn parseRange(line: []const u8, ctx: Context) Parsed {
    if (line.len > 0 and line[0] == '%') {
        return .{ .range = .{ .first = 0, .last = ctx.last }, .explicit = true, .rest = line[1..] };
    }
    var i: usize = 0;
    var used_mark = false;
    var err: ?RangeError = null;
    const a = parseAddress(line, &i, ctx, &used_mark, &err) orelse
        return .{ .range = null, .explicit = false, .rest = line };
    if (i < line.len and line[i] == ',') {
        i += 1;
        // `:5,` is `:5,.`: a missing second address is the cursor's line.
        const b = parseAddress(line, &i, ctx, &used_mark, &err) orelse ctx.current;
        // A backwards range is turned round rather than asked about.
        return .{
            .range = .{ .first = @min(a, b), .last = @max(a, b) },
            .explicit = true,
            .rest = line[i..],
            .err = err,
        };
    }
    return .{ .range = .{ .first = a, .last = a }, .explicit = used_mark, .rest = line[i..], .err = err };
}

/// One address at `line[i.*]`, advancing `i`. Null when there is none
/// there. Line numbers are 1-based on the line and 0-based out, and `0`
/// is taken as line 1, which is what every vim command but `:0put`
/// does with it. A problem goes in `err` (the first one wins) and the
/// line is clamped into the buffer.
fn parseAddress(line: []const u8, i: *usize, ctx: Context, used_mark: *bool, err: *?RangeError) ?usize {
    var at: i64 = undefined;
    var have = false;
    if (i.* < line.len) {
        const c = line[i.*];
        if (std.ascii.isDigit(c)) {
            at = @max(readNumber(line, i) - 1, 0);
            have = true;
        } else if (c == '.') {
            i.* += 1;
            at = @intCast(ctx.current);
            have = true;
        } else if (c == '$') {
            i.* += 1;
            at = @intCast(ctx.last);
            have = true;
        } else if (c == '\'' and i.* + 1 < line.len and (line[i.* + 1] == '<' or line[i.* + 1] == '>')) {
            if (ctx.visual) |v| {
                at = @intCast(if (line[i.* + 1] == '<') v.first else v.last);
            } else {
                if (err.* == null) err.* = .mark_not_set;
                at = @intCast(ctx.current);
            }
            i.* += 2;
            used_mark.* = true;
            have = true;
        }
    }
    // Offsets, with or without a base: `+3` alone is three below `.`.
    while (i.* < line.len and (line[i.*] == '+' or line[i.*] == '-')) {
        if (!have) {
            at = @intCast(ctx.current);
            have = true;
        }
        const sign: i64 = if (line[i.*] == '+') 1 else -1;
        i.* += 1;
        const n: i64 = if (i.* < line.len and std.ascii.isDigit(line[i.*])) readNumber(line, i) else 1;
        at += sign * n;
    }
    if (!have) return null;
    const last: i64 = @intCast(ctx.last);
    if (at < 0 or at > last) {
        if (err.* == null) err.* = .invalid_range;
        at = std.math.clamp(at, 0, last);
    }
    return @intCast(at);
}

/// The digits at `line[i.*]` as a number, capped rather than
/// overflowing on a silly one (which then fails the range check).
fn readNumber(line: []const u8, i: *usize) i64 {
    const cap: i64 = std.math.maxInt(i32);
    var n: i64 = 0;
    while (i.* < line.len and std.ascii.isDigit(line[i.*])) : (i.* += 1) {
        n = @min(n * 10 + (line[i.*] - '0'), cap);
    }
    return n;
}

/// Whether `rest` (what followed the range) names `:s`, and if so where
/// its argument starts. `:s/a/b/`, `:s#a#b#`, `:substitute/a/b/` and a
/// bare `:s` all count; `:set`, `:sp` and `:split` don't, because a
/// letter can't be a delimiter. Blanks between the range and the name
/// (`:% s/a/b/`) are allowed, as in vim.
pub fn commandArg(rest: []const u8) ?[]const u8 {
    const cmd = std.mem.trimStart(u8, rest, " \t");
    const names = [_][]const u8{ "substitute", "s" };
    for (names) |name| {
        if (!std.mem.startsWith(u8, cmd, name)) continue;
        const arg = cmd[name.len..];
        if (arg.len == 0) return arg;
        if (std.ascii.isAlphanumeric(arg[0])) continue;
        return arg;
    }
    return null;
}

/// How a substitution compares its pattern.
pub const CaseMode = enum { smart, ignore, exact };

/// A parsed `:s/pat/rep/flags`.
pub const Command = struct {
    /// The pattern, escapes resolved. Empty means "the last search
    /// pattern", which the editor fills in. Owned.
    pat: []u8,
    /// The replacement as typed: `expand` resolves it per match, since
    /// `&` is different every time. Owned.
    rep: []u8,
    /// The delimiter it was written with, which `\` escapes in `rep`.
    delim: u8,
    /// `g`: every match on a line rather than the first.
    global: bool = false,
    case: CaseMode = .smart,

    pub fn deinit(self: *Command, alloc: std.mem.Allocator) void {
        alloc.free(self.pat);
        alloc.free(self.rep);
        self.* = undefined;
    }

    /// The search options for `pat` under these flags.
    pub fn opts(self: *const Command, pat: []const u8, whole_word: bool) search.Opts {
        return .{
            .ignore_case = switch (self.case) {
                .smart => search.smartIgnoreCase(pat),
                .ignore => true,
                .exact => false,
            },
            .whole_word = whole_word,
        };
    }
};

pub const ParseError = error{
    /// A flag that isn't `g`, `i` or `I`; carries no detail, since the
    /// editor reports the text itself (vim's E488).
    TrailingCharacters,
    /// A delimiter that can't be one: alphanumeric, `\`, `"` or `|`.
    BadDelimiter,
} || std.mem.Allocator.Error;

/// Parses the argument of `:s` (from the delimiter on). An empty
/// argument isn't a `Command` -- it repeats the last one -- and is the
/// caller's to spot.
pub fn parse(alloc: std.mem.Allocator, arg: []const u8) ParseError!Command {
    std.debug.assert(arg.len > 0);
    const delim = arg[0];
    if (std.ascii.isAlphanumeric(delim) or delim == '\\' or delim == '"' or delim == '|' or delim == ' ')
        return error.BadDelimiter;

    var i: usize = 1;
    var pat: std.ArrayList(u8) = .empty;
    errdefer pat.deinit(alloc);
    while (i < arg.len and arg[i] != delim) : (i += 1) {
        if (arg[i] == '\\' and i + 1 < arg.len) {
            const n = arg[i + 1];
            if (n == delim or n == '\\') {
                try pat.append(alloc, n);
                i += 1;
                continue;
            }
            if (n == 'n' or n == 't') {
                try pat.append(alloc, if (n == 'n') '\n' else '\t');
                i += 1;
                continue;
            }
        }
        try pat.append(alloc, arg[i]);
    }

    // The replacement runs to the next unescaped delimiter. Escapes stay
    // in it -- `expand` reads them -- but are skipped over here so `\/`
    // doesn't end it.
    var rep_start = arg.len;
    var rep_end = arg.len;
    if (i < arg.len) {
        i += 1;
        rep_start = i;
        while (i < arg.len and arg[i] != delim) : (i += 1) {
            if (arg[i] == '\\' and i + 1 < arg.len) i += 1;
        }
        rep_end = i;
        if (i < arg.len) i += 1;
    }

    var cmd: Command = .{
        .pat = try pat.toOwnedSlice(alloc),
        .rep = &.{},
        .delim = delim,
    };
    errdefer alloc.free(cmd.pat);
    for (std.mem.trim(u8, arg[i..], " \t")) |f| switch (f) {
        'g' => cmd.global = true,
        'i' => cmd.case = .ignore,
        'I' => cmd.case = .exact,
        else => return error.TrailingCharacters,
    };
    cmd.rep = try alloc.dupe(u8, arg[rep_start..rep_end]);
    return cmd;
}

/// Appends replacement template `rep` to `out` for one match whose text
/// is `matched`. See the module comment for the escapes.
pub fn expand(
    alloc: std.mem.Allocator,
    out: *std.ArrayList(u8),
    rep: []const u8,
    delim: u8,
    matched: []const u8,
) !void {
    var i: usize = 0;
    while (i < rep.len) : (i += 1) {
        const c = rep[i];
        if (c == '&') {
            try out.appendSlice(alloc, matched);
            continue;
        }
        if (c == '\\' and i + 1 < rep.len) {
            i += 1;
            const n = rep[i];
            switch (n) {
                'r', 'n' => try out.append(alloc, '\n'),
                't' => try out.append(alloc, '\t'),
                '&', '\\' => try out.append(alloc, n),
                else => {
                    // `\` before the delimiter is the delimiter; before
                    // anything else it is kept as typed.
                    if (n != delim) try out.append(alloc, '\\');
                    try out.append(alloc, n);
                },
            }
            continue;
        }
        try out.append(alloc, c);
    }
}

/// One place a pattern matched: `len` bytes from `at`.
pub const Match = struct { at: usize, len: usize };

/// Every match of `pat` that starts on a line of `range`, in order and
/// non-overlapping: the first on each line, or with `global` all of
/// them. A match carrying a newline may end past the range; the next
/// one is looked for after it, so a line joined onto the one above is
/// not matched again.
pub fn collect(
    alloc: std.mem.Allocator,
    buf: *const Buffer,
    pat: []const u8,
    opts: search.Opts,
    range: LineRange,
    global: bool,
) ![]Match {
    var out: std.ArrayList(Match) = .empty;
    errdefer out.deinit(alloc);
    if (pat.len == 0) return out.toOwnedSlice(alloc);

    // A match may start on the newline that ends the range's last line,
    // so the limit is one past it.
    const limit = @min(buf.lineEnd(range.last) + 1, buf.len());
    var from = buf.lineStart(range.first);
    while (search.firstIn(buf, pat, opts, from, limit)) |at| {
        try out.append(alloc, .{ .at = at, .len = pat.len });
        const after = at + pat.len;
        if (global) {
            from = after;
        } else {
            const next_line = buf.lineAt(at) + 1;
            if (next_line >= buf.lineCount()) break;
            from = @max(after, buf.lineStart(next_line));
        }
    }
    return out.toOwnedSlice(alloc);
}

/// Every match of `pat` in `[lo, hi)` -- the find widget's replace-all
/// over a selection or the whole buffer.
pub fn collectSpan(
    alloc: std.mem.Allocator,
    buf: *const Buffer,
    pat: []const u8,
    opts: search.Opts,
    lo: usize,
    hi: usize,
) ![]Match {
    var out: std.ArrayList(Match) = .empty;
    errdefer out.deinit(alloc);
    if (pat.len == 0) return out.toOwnedSlice(alloc);
    var from = lo;
    while (search.firstIn(buf, pat, opts, from, hi)) |at| {
        // A match must fit inside the span, not just start in it.
        if (at + pat.len > hi) break;
        try out.append(alloc, .{ .at = at, .len = pat.len });
        from = at + pat.len;
    }
    return out.toOwnedSlice(alloc);
}
