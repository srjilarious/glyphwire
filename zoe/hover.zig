// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: GPL-3.0-or-later

//! A hover reply's markdown, cut into the lines the popup draws.
//!
//! Language servers answer `textDocument/hover` with a small, predictable
//! subset of markdown: a fenced code block holding the signature, a `---`
//! rule, then a paragraph or two of documentation with some inline code and
//! emphasis in it. Running that through the `md/` renderer would be the
//! complete answer and is a much bigger one (it draws into a layer of its
//! own). This is the useful half: fenced blocks are kept as code, tagged
//! with their language so `zoe/ui.zig` can colour them with the same
//! tree-sitter grammars the buffer uses, and prose has its markdown
//! punctuation taken off so it reads as text rather than as source.
//!
//! Pure -- no client, no grammar -- so the splitting is tested on its own.

const std = @import("std");

pub const Kind = enum {
    /// Documentation text, markdown punctuation already removed.
    prose,
    /// One line of a fenced code block, verbatim.
    code,
    /// A `---` (or `***`, `___`) thematic break. Drawn as a line across the
    /// popup rather than as three dashes.
    rule,
};

pub const Line = struct {
    kind: Kind,
    /// The line's text, no terminator. Points into `Doc`'s arena.
    text: []const u8,
    /// For `.code`: the index into `Doc.blocks` of the block it belongs to.
    block: usize = 0,
};

/// One fenced code block: its language tag and the lines it spans.
pub const Block = struct {
    /// The fence's info string up to the first space, lowercased -- `zig`,
    /// `python`, `py`. Empty for a bare fence; the caller picks a default
    /// (the buffer's own language, which is what a bare fence from a
    /// language server nearly always means).
    lang: []const u8,
    /// `Doc.lines[first .. first + count]` are this block's lines.
    first: usize,
    count: usize,
};

pub const Doc = struct {
    arena: std.heap.ArenaAllocator,
    lines: []Line,
    blocks: []Block,

    pub fn deinit(self: *Doc) void {
        self.arena.deinit();
    }

    /// The block's lines joined with `\n`, the source a highlighter parses.
    /// Allocated from `alloc`, owned by the caller.
    pub fn blockSource(self: *const Doc, alloc: std.mem.Allocator, b: Block) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(alloc);
        for (self.lines[b.first .. b.first + b.count], 0..) |l, i| {
            if (i > 0) try out.append(alloc, '\n');
            try out.appendSlice(alloc, l.text);
        }
        return out.toOwnedSlice(alloc);
    }
};

/// Splits `markdown` into popup lines. Runs of blank lines collapse to one
/// and leading/trailing blanks go, so a server's generous spacing doesn't
/// spend the popup's few rows on nothing. An unterminated fence runs to the
/// end, which is how every markdown renderer reads one.
pub fn parse(alloc: std.mem.Allocator, markdown: []const u8) !Doc {
    var arena = std.heap.ArenaAllocator.init(alloc);
    errdefer arena.deinit();
    const a = arena.allocator();

    var lines: std.ArrayList(Line) = .empty;
    var blocks: std.ArrayList(Block) = .empty;

    var fence: ?Fence = null;
    var it = std.mem.splitScalar(u8, markdown, '\n');
    while (it.next()) |raw_line| {
        const line = std.mem.trimEnd(u8, raw_line, "\r");

        if (fence) |f| {
            if (f.closes(line)) {
                blocks.items[blocks.items.len - 1].count = lines.items.len - blocks.items[blocks.items.len - 1].first;
                fence = null;
                continue;
            }
            try lines.append(a, .{ .kind = .code, .text = try a.dupe(u8, line), .block = blocks.items.len - 1 });
            continue;
        }

        if (Fence.opens(line)) |f| {
            fence = f;
            try blocks.append(a, .{ .lang = try lowerDupe(a, f.lang), .first = lines.items.len, .count = 0 });
            continue;
        }

        const trimmed = std.mem.trim(u8, line, " \t");
        if (trimmed.len == 0) {
            // Collapse runs, and never lead with a blank.
            if (lines.items.len == 0) continue;
            const prev = lines.items[lines.items.len - 1];
            if (prev.kind == .prose and prev.text.len == 0) continue;
            try lines.append(a, .{ .kind = .prose, .text = "" });
            continue;
        }
        if (isRule(trimmed)) {
            try lines.append(a, .{ .kind = .rule, .text = "" });
            continue;
        }
        try lines.append(a, .{ .kind = .prose, .text = try cleanProse(a, line) });
    }
    // An unterminated fence: its block runs to the end.
    if (fence != null) {
        const last = &blocks.items[blocks.items.len - 1];
        last.count = lines.items.len - last.first;
    }

    // Trailing blanks and rules say nothing at the bottom of a popup. Only
    // prose and rules are ever popped, never code, so every block's line
    // range stays valid.
    while (lines.items.len > 0) {
        const last = lines.items[lines.items.len - 1];
        const empty_prose = last.kind == .prose and last.text.len == 0;
        if (!empty_prose and last.kind != .rule) break;
        _ = lines.pop();
    }
    return .{
        .arena = arena,
        .lines = try lines.toOwnedSlice(a),
        .blocks = try blocks.toOwnedSlice(a),
    };
}

const Fence = struct {
    /// ``` or ~~~, and how many -- a closing fence must use the same
    /// character and at least as many.
    char: u8,
    len: usize,
    lang: []const u8,

    fn opens(line: []const u8) ?Fence {
        const t = std.mem.trimStart(u8, line, " ");
        // More than three spaces of indent is an indented code block's
        // territory, not a fence.
        if (line.len - t.len > 3) return null;
        if (t.len < 3) return null;
        const c = t[0];
        if (c != '`' and c != '~') return null;
        var n: usize = 0;
        while (n < t.len and t[n] == c) n += 1;
        if (n < 3) return null;
        const info = std.mem.trim(u8, t[n..], " \t");
        // A backtick fence's info string may not contain a backtick -- that
        // line is inline code, not a fence.
        if (c == '`' and std.mem.indexOfScalar(u8, info, '`') != null) return null;
        const end = std.mem.indexOfAny(u8, info, " \t{") orelse info.len;
        return .{ .char = c, .len = n, .lang = info[0..end] };
    }

    fn closes(self: Fence, line: []const u8) bool {
        const t = std.mem.trim(u8, line, " \t");
        if (t.len < self.len) return false;
        for (t) |ch| if (ch != self.char) return false;
        return true;
    }
};

fn isRule(t: []const u8) bool {
    if (t.len < 3) return false;
    const c = t[0];
    if (c != '-' and c != '*' and c != '_') return false;
    var n: usize = 0;
    for (t) |ch| {
        if (ch == c) {
            n += 1;
        } else if (ch != ' ') return false;
    }
    return n >= 3;
}

fn lowerDupe(a: std.mem.Allocator, s: []const u8) ![]u8 {
    const out = try a.dupe(u8, s);
    for (out) |*c| c.* = std.ascii.toLower(c.*);
    return out;
}

/// One prose line with its markdown punctuation removed: heading `#`s,
/// `**` / `__` emphasis markers, inline-code backticks, and backslash
/// escapes (pyright escapes every `_` in an identifier). Single `*` / `_`
/// are left alone -- they are as likely to be a glob or `snake_case` as
/// emphasis, and a stray asterisk reads better than a lost one.
///
/// Link syntax `[text](url)` keeps the text and drops the target: the
/// popup can't follow a link, and a long URL would eat the whole row.
pub fn cleanProse(a: std.mem.Allocator, line: []const u8) ![]u8 {
    var s = line;
    // `# Heading` -> `Heading`.
    const lead = std.mem.trimStart(u8, s, " ");
    if (lead.len > 0 and lead[0] == '#') {
        var n: usize = 0;
        while (n < lead.len and lead[n] == '#') n += 1;
        if (n <= 6 and (n == lead.len or lead[n] == ' ')) s = std.mem.trimStart(u8, lead[n..], " ");
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var i: usize = 0;
    while (i < s.len) {
        const c = s[i];
        if (c == '\\' and i + 1 < s.len and std.ascii.isPrint(s[i + 1]) and !std.ascii.isAlphanumeric(s[i + 1]) and s[i + 1] != ' ') {
            try out.append(a, s[i + 1]);
            i += 2;
            continue;
        }
        if ((c == '*' or c == '_') and i + 1 < s.len and s[i + 1] == c) {
            // `a__b` is a name, not emphasis: a `__` with a word character
            // on both sides stays.
            const inside_word = c == '_' and i > 0 and isWord(s[i - 1]) and
                i + 2 < s.len and isWord(s[i + 2]);
            if (!inside_word) {
                i += 2;
                continue;
            }
        }
        if (c == '`') {
            i += 1;
            continue;
        }
        if (c == '[') {
            if (linkEnd(s, i)) |l| {
                try out.appendSlice(a, s[i + 1 .. l.text_end]);
                i = l.end;
                continue;
            }
        }
        try out.append(a, c);
        i += 1;
    }
    return out.toOwnedSlice(a);
}

fn isWord(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c >= 0x80;
}

/// `[text](target)` starting at `open`: where the text ends and where the
/// whole construct ends. Null for a bracket that isn't a link.
fn linkEnd(s: []const u8, open: usize) ?struct { text_end: usize, end: usize } {
    const close = std.mem.indexOfScalarPos(u8, s, open + 1, ']') orelse return null;
    if (close + 1 >= s.len or s[close + 1] != '(') return null;
    const paren = std.mem.indexOfScalarPos(u8, s, close + 2, ')') orelse return null;
    return .{ .text_end = close, .end = paren + 1 };
}
