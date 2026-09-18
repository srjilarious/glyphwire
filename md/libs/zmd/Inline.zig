//! Structured inline parsing for `Document` -- a glyphwire addition to the
//! vendored zmd fork (see README.md).
//!
//! zmd's own `Ast` turns inline markup into HTML through a flat token
//! stream, which is fine for a browser that will forgive it but loses
//! things a renderer that owns every cell cannot: an image inside a link
//! (`[![alt](a.png)](url)`) splits apart, a link inside bold drops the
//! bold, and `snake_case_name` comes out italic. This parser is a small
//! recursive-descent pass with CommonMark's flanking rules instead, and it
//! produces *runs* -- text with a style and an optional link -- rather
//! than markup, so a caller can lay them out and wrap them itself.
//!
//! Covered: backslash escapes, code spans (any backtick run length),
//! `*`/`_` emphasis and strong emphasis (nesting, intraword `_` left
//! alone), `~~strikethrough~~`, inline links and images with titles,
//! reference links (`[text][ref]`, `[text][]`, `[ref]`), `<autolinks>`,
//! bare `http(s)://` and `www.` URLs, and hard line breaks (two trailing
//! spaces or a trailing backslash). Raw inline HTML is passed through as
//! text.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Style = packed struct(u8) {
    bold: bool = false,
    italic: bool = false,
    code: bool = false,
    strike: bool = false,
    _pad: u4 = 0,
};

/// One piece of laid-out-able inline content.
pub const Run = struct {
    kind: Kind = .text,
    /// The text for `.text`; the alt text for `.image`.
    text: []const u8 = "",
    /// `.image` only: the source exactly as written (relative paths are
    /// the caller's to resolve).
    src: []const u8 = "",
    style: Style = .{},
    /// Index into the link list `parse` appended to. Every run inside one
    /// `[...](...)` shares the index, so a link whose text changes style
    /// partway through is still one link.
    link: ?usize = null,

    pub const Kind = enum { text, image, line_break };
};

pub const Link = struct {
    href: []const u8,
    title: []const u8 = "",
};

/// Reference definitions (`[label]: href "title"`), keyed by `normalizeLabel`.
pub const RefMap = std.StringHashMapUnmanaged(Link);

/// Parses `text` into runs. Every allocation (runs, unescaped text, link
/// entries) comes from `arena` and lives as long as it does. Links found
/// are appended to `links`, and each run inside one refers back by index.
pub fn parse(arena: Allocator, text: []const u8, refs: *const RefMap, links: *std.ArrayList(Link)) ![]Run {
    var p: Parser = .{ .arena = arena, .refs = refs, .links = links };
    try p.parseInto(text, .{}, null);
    try p.flush(.{}, null);
    return p.runs.toOwnedSlice(arena);
}

/// The runs' text concatenated, images contributing their alt text --
/// what a heading slug or a table cell's width is computed from.
pub fn plainText(arena: Allocator, runs: []const Run) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (runs) |r| switch (r.kind) {
        .text, .image => try out.appendSlice(arena, r.text),
        .line_break => try out.append(arena, ' '),
    };
    return out.toOwnedSlice(arena);
}

/// Case-folds and collapses whitespace so `[Foo  Bar]` and `[foo bar]`
/// name the same reference, as CommonMark requires.
pub fn normalizeLabel(arena: Allocator, label: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var in_space = false;
    for (std.mem.trim(u8, label, " \t\n")) |c| {
        if (c == ' ' or c == '\t' or c == '\n') {
            in_space = true;
            continue;
        }
        if (in_space) try out.append(arena, ' ');
        in_space = false;
        try out.append(arena, std.ascii.toLower(c));
    }
    return out.toOwnedSlice(arena);
}

const Parser = struct {
    arena: Allocator,
    refs: *const RefMap,
    links: *std.ArrayList(Link),
    runs: std.ArrayList(Run) = .empty,
    /// Literal text not yet emitted as a run -- flushed whenever the style
    /// or link changes, or a non-text run is emitted.
    pending: std.ArrayList(u8) = .empty,

    fn flush(self: *Parser, style: Style, link: ?usize) !void {
        if (self.pending.items.len == 0) return;
        const text = try self.pending.toOwnedSlice(self.arena);
        // Merge into the previous run when nothing about it differs, so a
        // line of plain text split up by escapes or failed markup is still
        // one run.
        if (self.runs.items.len > 0) {
            const last = &self.runs.items[self.runs.items.len - 1];
            if (last.kind == .text and @as(u8, @bitCast(last.style)) == @as(u8, @bitCast(style)) and last.link == link) {
                last.text = try std.mem.concat(self.arena, u8, &.{ last.text, text });
                return;
            }
        }
        try self.runs.append(self.arena, .{ .text = text, .style = style, .link = link });
    }

    fn parseInto(self: *Parser, text: []const u8, style: Style, link: ?usize) error{OutOfMemory}!void {
        var i: usize = 0;
        while (i < text.len) {
            const c = text[i];
            switch (c) {
                '\\' => {
                    if (i + 1 < text.len and text[i + 1] == '\n') {
                        try self.lineBreak(style, link);
                        i = skipLeadingSpaces(text, i + 2);
                        continue;
                    }
                    if (i + 1 < text.len and isAsciiPunct(text[i + 1])) {
                        try self.pending.append(self.arena, text[i + 1]);
                        i += 2;
                        continue;
                    }
                },
                '\n' => {
                    // Two or more trailing spaces make a hard break; anything
                    // else is a soft break, which reads as a space.
                    var spaces: usize = 0;
                    while (spaces < self.pending.items.len and self.pending.items[self.pending.items.len - 1 - spaces] == ' ') spaces += 1;
                    self.pending.shrinkRetainingCapacity(self.pending.items.len - spaces);
                    if (spaces >= 2) {
                        try self.lineBreak(style, link);
                    } else {
                        try self.pending.append(self.arena, ' ');
                    }
                    i = skipLeadingSpaces(text, i + 1);
                    continue;
                },
                '`' => {
                    if (codeSpan(text, i)) |cs| {
                        try self.flush(style, link);
                        var st = style;
                        st.code = true;
                        try self.runs.append(self.arena, .{ .text = try self.codeText(cs.content), .style = st, .link = link });
                        i = cs.end;
                        continue;
                    }
                    // An unmatched run is literal, all of it -- a lone
                    // backtick inside a longer run mustn't open a span.
                    const n = runLength(text, i, '`');
                    try self.pending.appendSlice(self.arena, text[i .. i + n]);
                    i += n;
                    continue;
                },
                '<' => if (link == null) {
                    if (autolink(text, i)) |al| {
                        try self.flush(style, link);
                        const href = if (al.email) try std.mem.concat(self.arena, u8, &.{ "mailto:", al.target }) else al.target;
                        const idx = try self.addLink(.{ .href = href });
                        try self.runs.append(self.arena, .{ .text = al.target, .style = style, .link = idx });
                        i = al.end;
                        continue;
                    }
                },
                '!' => if (i + 1 < text.len and text[i + 1] == '[') {
                    if (try self.linkish(text, i + 1)) |l| {
                        try self.flush(style, link);
                        const alt = try self.plainOf(text[l.label_start..l.label_end]);
                        try self.runs.append(self.arena, .{ .kind = .image, .text = alt, .src = l.dest.href, .style = style, .link = link });
                        i = l.end;
                        continue;
                    }
                },
                '[' => if (link == null) {
                    if (try self.linkish(text, i)) |l| {
                        try self.flush(style, link);
                        const idx = try self.addLink(l.dest);
                        try self.parseInto(text[l.label_start..l.label_end], style, idx);
                        try self.flush(style, idx);
                        i = l.end;
                        continue;
                    }
                },
                '*', '_' => {
                    if (try self.emphasis(text, i, style, link)) |next| {
                        i = next;
                        continue;
                    }
                    const n = runLength(text, i, c);
                    try self.pending.appendSlice(self.arena, text[i .. i + n]);
                    i += n;
                    continue;
                },
                '~' => if (i + 1 < text.len and text[i + 1] == '~') {
                    if (try self.strike(text, i, style, link)) |next| {
                        i = next;
                        continue;
                    }
                },
                'h', 'w' => if (link == null and atWordStart(text, i)) {
                    if (bareUrl(text, i)) |url_end| {
                        try self.flush(style, link);
                        const shown = text[i..url_end];
                        const href = if (std.mem.startsWith(u8, shown, "www."))
                            try std.mem.concat(self.arena, u8, &.{ "http://", shown })
                        else
                            shown;
                        const idx = try self.addLink(.{ .href = href });
                        try self.runs.append(self.arena, .{ .text = shown, .style = style, .link = idx });
                        i = url_end;
                        continue;
                    }
                },
                else => {},
            }
            try self.pending.append(self.arena, c);
            i += 1;
        }
        try self.flush(style, link);
    }

    fn lineBreak(self: *Parser, style: Style, link: ?usize) !void {
        try self.flush(style, link);
        try self.runs.append(self.arena, .{ .kind = .line_break, .style = style, .link = link });
    }

    fn addLink(self: *Parser, l: Link) !usize {
        try self.links.append(self.arena, l);
        return self.links.items.len - 1;
    }

    /// A code span's content with line endings turned into spaces, and
    /// one leading + trailing space stripped when both are present (so
    /// `` `` `a` `` `` can show a backtick).
    fn codeText(self: *Parser, content: []const u8) ![]const u8 {
        var s = content;
        if (s.len >= 2 and s[0] == ' ' and s[s.len - 1] == ' ' and std.mem.trim(u8, s, " ").len > 0) s = s[1 .. s.len - 1];
        const out = try self.arena.dupe(u8, s);
        for (out) |*b| {
            if (b.* == '\n') b.* = ' ';
        }
        return out;
    }

    /// A label's text with its markup dropped -- an image's alt text.
    fn plainOf(self: *Parser, label: []const u8) ![]const u8 {
        var sub: Parser = .{ .arena = self.arena, .refs = self.refs, .links = self.links };
        const before = self.links.items.len;
        try sub.parseInto(label, .{}, null);
        // Links inside alt text aren't clickable anywhere; don't leave
        // them behind in the document's link list.
        self.links.shrinkRetainingCapacity(before);
        return plainText(self.arena, sub.runs.items);
    }

    const Linkish = struct {
        label_start: usize,
        label_end: usize,
        dest: Link,
        end: usize,
    };

    /// Parses `[label](dest "title")`, `[label][ref]`, `[label][]` or
    /// `[ref]` starting at the `[` at `open`. Null when it isn't one, in
    /// which case the `[` is literal.
    fn linkish(self: *Parser, text: []const u8, open: usize) !?Linkish {
        const close = matchingBracket(text, open) orelse return null;
        const label_start = open + 1;
        const label_end = close;
        const after = close + 1;

        if (after < text.len and text[after] == '(') {
            if (inlineDest(text, after)) |d| {
                return .{
                    .label_start = label_start,
                    .label_end = label_end,
                    .dest = .{ .href = try unescape(self.arena, d.href), .title = try unescape(self.arena, d.title) },
                    .end = d.end,
                };
            }
        }
        if (after < text.len and text[after] == '[') {
            if (matchingBracket(text, after)) |ref_close| {
                const ref_label = text[after + 1 .. ref_close];
                const key = if (ref_label.len == 0) text[label_start..label_end] else ref_label;
                if (self.refs.get(try normalizeLabel(self.arena, key))) |def| {
                    return .{ .label_start = label_start, .label_end = label_end, .dest = def, .end = ref_close + 1 };
                }
                return null;
            }
        }
        // Shortcut reference: `[ref]` on its own.
        if (self.refs.get(try normalizeLabel(self.arena, text[label_start..label_end]))) |def| {
            return .{ .label_start = label_start, .label_end = label_end, .dest = def, .end = after };
        }
        return null;
    }

    /// `*`/`_` emphasis at `i`. Returns the index just past the closer when
    /// it matched (having emitted the content), or null when the run can't
    /// open or nothing closes it.
    fn emphasis(self: *Parser, text: []const u8, i: usize, style: Style, link: ?usize) !?usize {
        const c = text[i];
        const run = runLength(text, i, c);
        if (!canOpen(text, i, run, c)) return null;
        const open_len = @min(run, 3);

        // Look for a closer of the same character, skipping code spans
        // and escapes so a `*` inside `` `a*b` `` can't close anything.
        // `nested` counts inner openers of the same character still
        // waiting for their own closer, so `*a **b** c*` pairs the outer
        // stars with each other rather than with the inner `**`.
        var nested: usize = 0;
        var j = i + run;
        while (j < text.len) {
            switch (text[j]) {
                '\\' => {
                    j += 2;
                    continue;
                },
                '`' => {
                    if (codeSpan(text, j)) |cs| {
                        j = cs.end;
                        continue;
                    }
                    j += runLength(text, j, '`');
                    continue;
                },
                else => {},
            }
            if (text[j] == c) {
                const close_run = runLength(text, j, c);
                const closes = canClose(text, j, close_run, c) and j > i + run;
                if (closes and nested > 0) {
                    nested -= 1;
                    j += close_run;
                    continue;
                }
                if (!closes and canOpen(text, j, close_run, c)) {
                    nested += 1;
                    j += close_run;
                    continue;
                }
                if (closes) {
                    const k = @min(open_len, close_run);
                    // Leftover opener characters stay literal, outside.
                    try self.pending.appendSlice(self.arena, text[i .. i + (run - k)]);
                    try self.flush(style, link);
                    var st = style;
                    switch (k) {
                        1 => st.italic = true,
                        2 => st.bold = true,
                        else => {
                            st.bold = true;
                            st.italic = true;
                        },
                    }
                    try self.parseInto(text[i + run .. j], st, link);
                    try self.flush(st, link);
                    // Leftover closer characters are handled by the caller's
                    // loop as ordinary text (or another closer).
                    return j + k;
                }
                j += close_run;
                continue;
            }
            j += 1;
        }
        return null;
    }

    fn strike(self: *Parser, text: []const u8, i: usize, style: Style, link: ?usize) !?usize {
        const start = i + 2;
        if (start >= text.len or isSpace(text[start])) return null;
        const rel = std.mem.indexOf(u8, text[start..], "~~") orelse return null;
        if (rel == 0) return null;
        const end = start + rel;
        if (isSpace(text[end - 1])) return null;
        try self.flush(style, link);
        var st = style;
        st.strike = true;
        try self.parseInto(text[start..end], st, link);
        try self.flush(st, link);
        return end + 2;
    }
};

// ── Scanning helpers (pure) ──────────────────────────────────────────────

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n';
}

fn isAsciiPunct(c: u8) bool {
    return switch (c) {
        '!'...'/', ':'...'@', '['...'`', '{'...'~' => true,
        else => false,
    };
}

fn skipLeadingSpaces(text: []const u8, from: usize) usize {
    var i = from;
    while (i < text.len and (text[i] == ' ' or text[i] == '\t')) i += 1;
    return i;
}

fn runLength(text: []const u8, i: usize, c: u8) usize {
    var n: usize = 0;
    while (i + n < text.len and text[i + n] == c) n += 1;
    return n;
}

/// CommonMark's left-flanking test for the delimiter run `text[i..i+n]`,
/// with `_` additionally refusing to open inside a word.
fn canOpen(text: []const u8, i: usize, n: usize, c: u8) bool {
    const after: u8 = if (i + n < text.len) text[i + n] else ' ';
    const before: u8 = if (i > 0) text[i - 1] else ' ';
    if (isSpace(after)) return false;
    const left_flanking = !isAsciiPunct(after) or isSpace(before) or isAsciiPunct(before);
    if (!left_flanking) return false;
    if (c == '_' and std.ascii.isAlphanumeric(before)) return false;
    return true;
}

fn canClose(text: []const u8, i: usize, n: usize, c: u8) bool {
    const before: u8 = if (i > 0) text[i - 1] else ' ';
    const after: u8 = if (i + n < text.len) text[i + n] else ' ';
    if (isSpace(before)) return false;
    const right_flanking = !isAsciiPunct(before) or isSpace(after) or isAsciiPunct(after);
    if (!right_flanking) return false;
    if (c == '_' and std.ascii.isAlphanumeric(after)) return false;
    return true;
}

const CodeSpan = struct { content: []const u8, end: usize };

/// A code span opening at the backtick run at `i`: closed by the next run
/// of exactly the same length.
fn codeSpan(text: []const u8, i: usize) ?CodeSpan {
    const n = runLength(text, i, '`');
    var j = i + n;
    while (j < text.len) {
        if (text[j] == '`') {
            const m = runLength(text, j, '`');
            if (m == n) return .{ .content = text[i + n .. j], .end = j + m };
            j += m;
            continue;
        }
        j += 1;
    }
    return null;
}

/// The `]` matching the `[` at `open`, honouring nesting, escapes and code
/// spans. Null if the label never closes.
fn matchingBracket(text: []const u8, open: usize) ?usize {
    var depth: usize = 0;
    var j = open;
    while (j < text.len) {
        switch (text[j]) {
            '\\' => {
                j += 2;
                continue;
            },
            '`' => {
                if (codeSpan(text, j)) |cs| {
                    j = cs.end;
                    continue;
                }
            },
            '[' => depth += 1,
            ']' => {
                depth -= 1;
                if (depth == 0) return j;
            },
            else => {},
        }
        j += 1;
    }
    return null;
}

const InlineDest = struct { href: []const u8, title: []const u8, end: usize };

/// `(dest "title")` starting at the `(` at `open`. The destination may be
/// `<bracketed>` (and then contain spaces) or bare, where parentheses must
/// balance.
fn inlineDest(text: []const u8, open: usize) ?InlineDest {
    var j = skipLeadingSpaces(text, open + 1);
    if (j < text.len and text[j] == '\n') j = skipLeadingSpaces(text, j + 1);
    var href: []const u8 = "";
    if (j < text.len and text[j] == '<') {
        const close = std.mem.indexOfScalarPos(u8, text, j + 1, '>') orelse return null;
        href = text[j + 1 .. close];
        if (std.mem.indexOfScalar(u8, href, '\n') != null) return null;
        j = close + 1;
    } else {
        const start = j;
        var depth: usize = 0;
        while (j < text.len) : (j += 1) {
            const ch = text[j];
            if (ch == '\\' and j + 1 < text.len) {
                j += 1;
                continue;
            }
            if (isSpace(ch)) break;
            if (ch == '(') depth += 1;
            if (ch == ')') {
                if (depth == 0) break;
                depth -= 1;
            }
        }
        href = text[start..j];
    }
    j = skipLeadingSpaces(text, j);
    if (j < text.len and text[j] == '\n') j = skipLeadingSpaces(text, j + 1);
    var title: []const u8 = "";
    if (j < text.len and (text[j] == '"' or text[j] == '\'' or text[j] == '(')) {
        const closer: u8 = if (text[j] == '(') ')' else text[j];
        const close = std.mem.indexOfScalarPos(u8, text, j + 1, closer) orelse return null;
        title = text[j + 1 .. close];
        j = skipLeadingSpaces(text, close + 1);
    }
    if (j >= text.len or text[j] != ')') return null;
    return .{ .href = href, .title = title, .end = j + 1 };
}

const Autolink = struct { target: []const u8, email: bool, end: usize };

/// `<scheme:rest>` or `<user@host>`.
fn autolink(text: []const u8, open: usize) ?Autolink {
    const close = std.mem.indexOfScalarPos(u8, text, open + 1, '>') orelse return null;
    const inner = text[open + 1 .. close];
    if (inner.len == 0) return null;
    for (inner) |ch| if (isSpace(ch) or ch == '<') return null;
    if (std.mem.indexOfScalar(u8, inner, ':')) |colon| {
        if (colon >= 2 and std.ascii.isAlphabetic(inner[0])) {
            for (inner[0..colon]) |ch| if (!(std.ascii.isAlphanumeric(ch) or ch == '+' or ch == '.' or ch == '-')) return null;
            return .{ .target = inner, .email = false, .end = close + 1 };
        }
        return null;
    }
    if (std.mem.indexOfScalar(u8, inner, '@')) |at| {
        if (at > 0 and std.mem.indexOfScalarPos(u8, inner, at, '.') != null)
            return .{ .target = inner, .email = true, .end = close + 1 };
    }
    return null;
}

fn atWordStart(text: []const u8, i: usize) bool {
    if (i == 0) return true;
    const b = text[i - 1];
    return isSpace(b) or b == '(' or b == '*' or b == '_' or b == '~';
}

/// GFM's extended autolinks: `http://`, `https://` and `www.` run to the
/// next space, minus trailing punctuation and any unbalanced `)`. Returns
/// the end of the URL, or null when `text[i..]` isn't one.
fn bareUrl(text: []const u8, i: usize) ?usize {
    const rest = text[i..];
    const prefix_len: usize = if (std.mem.startsWith(u8, rest, "https://"))
        8
    else if (std.mem.startsWith(u8, rest, "http://"))
        7
    else if (std.mem.startsWith(u8, rest, "www."))
        4
    else
        return null;
    var end = i + prefix_len;
    while (end < text.len and !isSpace(text[end]) and text[end] != '<') end += 1;
    // Trailing punctuation belongs to the sentence, not the URL.
    while (end > i + prefix_len) {
        const last = text[end - 1];
        if (std.mem.indexOfScalar(u8, "?!.,:*_~'\"", last) != null) {
            end -= 1;
            continue;
        }
        if (last == ')') {
            const open_n = std.mem.count(u8, text[i..end], "(");
            const close_n = std.mem.count(u8, text[i..end], ")");
            if (close_n > open_n) {
                end -= 1;
                continue;
            }
        }
        break;
    }
    if (end <= i + prefix_len) return null;
    return end;
}

/// Drops the backslash from every backslash-escaped ASCII punctuation
/// character -- link destinations and titles.
fn unescape(arena: Allocator, s: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, s, '\\') == null) return s;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '\\' and i + 1 < s.len and isAsciiPunct(s[i + 1])) i += 1;
        try out.append(arena, s[i]);
    }
    return out.toOwnedSlice(arena);
}
