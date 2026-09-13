// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: GPL-3.0-or-later

//! A Yomitan-format dictionary (e.g. Jitendex, https://jitendex.org) for
//! word lookup out of the mokuro OCR dialog -- "yomitan-style lookup",
//! the item `docs/roadmap.md` has carried since the OCR overlay landed.
//!
//! A Yomitan dictionary ships as a zip of JSON: `index.json` (title,
//! format, revision) and one or more `term_bank_N.json` files, each an
//! array of rows `[term, reading, definitionTags, rules, score, glossary,
//! sequence, termTags]`. `glossary` entries are either plain strings or
//! Yomitan's "structured content" objects (a tree of tagged nodes used
//! for formatting); this module flattens either shape to plain text
//! rather than rendering it, which loses styling but keeps every
//! dictionary readable in the box-drawing panels `ui.zig` already draws.
//!
//! Lookup does not tokenize the page's text up front. Japanese has no
//! spaces, so -- the same trick Yomitan itself uses -- a click just picks
//! a starting byte offset, and `lookup` tries decreasing-length candidate
//! substrings from there, deinflecting each one against a small rule
//! table before giving up on it. The longest substring with any match,
//! inflected or not, wins.
//!
//! Everything here except `loadFromZip` is pure -- JSON and text in,
//! structs out -- so `tests/read_tests.zig` can pin the parse and the
//! lookup without a dictionary file on disk. `loadFromZip` is the one
//! piece that touches the filesystem, mirroring how `archive.zig` is the
//! only place that reads a `.mokuro` sidecar's bytes.
//!
//! **What this deliberately does not do yet.** The deinflection table
//! below is a small slice of Yomitan's own (on the order of 30 rules
//! against its several hundred): plain-form negative/past/te-form for
//! godan and ichidan verbs, and negative/past/te-form for i-adjectives.
//! No -masu forms, no potential/passive/causative/volitional/imperative,
//! and no rule chaining (a passive-causative needs two steps; this
//! module only ever takes one). Widening this table is the natural
//! follow-up once single-step lookup is proven against a real volume --
//! see `docs/roadmap.md`.

const std = @import("std");

/// One term bank row. `rules` is Yomitan's space-separated deinflection
/// tags (`v1`, `v5`, `vk`, `vs`, `adj-i`, ...) -- empty for anything that
/// doesn't conjugate. `glossary` is one flattened string per sense.
pub const Entry = struct {
    term: []const u8 = "",
    reading: []const u8 = "",
    rules: []const u8 = "",
    glossary: []const []const u8 = &.{},
    sequence: i64 = 0,
};

/// A parsed dictionary. Arena-backed: every string and slice below
/// points into it, and `deinit` frees the lot in one go -- same shape as
/// `mokuro.Volume`.
pub const Dict = struct {
    arena: std.heap.ArenaAllocator,
    /// `index.json`'s title, when the zip had one. Empty otherwise.
    title: []const u8 = "",
    entries: []const Entry = &.{},
    /// Exact term -> indices into `entries`. Built once by `buildIndex`.
    by_term: std.StringHashMapUnmanaged([]const u32) = .empty,

    pub fn deinit(self: *Dict) void {
        self.arena.deinit();
    }
};

/// One deinflection step: strip `kana_in` off the end of the clicked
/// text and append `kana_out` to get a dictionary-form candidate.
/// `valid_rules` restricts which of the *candidate*'s own `rules` tags
/// make the guess acceptable -- without it, stripping "ない" off any
/// text ending that way would "deinflect" plenty of unrelated words that
/// merely happen to end in it.
pub const DeinflectRule = struct {
    kana_in: []const u8,
    kana_out: []const u8,
    valid_rules: []const []const u8,
    /// Shown next to a deinflected match so it doesn't read as a typo of
    /// the dictionary form.
    reason: []const u8,
};

/// Deliberately partial -- see the module doc comment. One triple
/// (negative, past, te-form) per godan sound group, three for ichidan,
/// three for i-adjectives.
pub const deinflect_rules = [_]DeinflectRule{
    .{ .kana_in = "わない", .kana_out = "う", .valid_rules = &.{"v5"}, .reason = "negative" },
    .{ .kana_in = "った", .kana_out = "う", .valid_rules = &.{"v5"}, .reason = "past" },
    .{ .kana_in = "って", .kana_out = "う", .valid_rules = &.{"v5"}, .reason = "te-form" },

    .{ .kana_in = "かない", .kana_out = "く", .valid_rules = &.{"v5"}, .reason = "negative" },
    .{ .kana_in = "いた", .kana_out = "く", .valid_rules = &.{"v5"}, .reason = "past" },
    .{ .kana_in = "いて", .kana_out = "く", .valid_rules = &.{"v5"}, .reason = "te-form" },

    .{ .kana_in = "がない", .kana_out = "ぐ", .valid_rules = &.{"v5"}, .reason = "negative" },
    .{ .kana_in = "いだ", .kana_out = "ぐ", .valid_rules = &.{"v5"}, .reason = "past" },
    .{ .kana_in = "いで", .kana_out = "ぐ", .valid_rules = &.{"v5"}, .reason = "te-form" },

    .{ .kana_in = "さない", .kana_out = "す", .valid_rules = &.{"v5"}, .reason = "negative" },
    .{ .kana_in = "した", .kana_out = "す", .valid_rules = &.{"v5"}, .reason = "past" },
    .{ .kana_in = "して", .kana_out = "す", .valid_rules = &.{"v5"}, .reason = "te-form" },

    .{ .kana_in = "たない", .kana_out = "つ", .valid_rules = &.{"v5"}, .reason = "negative" },
    .{ .kana_in = "った", .kana_out = "つ", .valid_rules = &.{"v5"}, .reason = "past" },
    .{ .kana_in = "って", .kana_out = "つ", .valid_rules = &.{"v5"}, .reason = "te-form" },

    .{ .kana_in = "なない", .kana_out = "ぬ", .valid_rules = &.{"v5"}, .reason = "negative" },
    .{ .kana_in = "んだ", .kana_out = "ぬ", .valid_rules = &.{"v5"}, .reason = "past" },
    .{ .kana_in = "んで", .kana_out = "ぬ", .valid_rules = &.{"v5"}, .reason = "te-form" },

    .{ .kana_in = "ばない", .kana_out = "ぶ", .valid_rules = &.{"v5"}, .reason = "negative" },
    .{ .kana_in = "んだ", .kana_out = "ぶ", .valid_rules = &.{"v5"}, .reason = "past" },
    .{ .kana_in = "んで", .kana_out = "ぶ", .valid_rules = &.{"v5"}, .reason = "te-form" },

    .{ .kana_in = "まない", .kana_out = "む", .valid_rules = &.{"v5"}, .reason = "negative" },
    .{ .kana_in = "んだ", .kana_out = "む", .valid_rules = &.{"v5"}, .reason = "past" },
    .{ .kana_in = "んで", .kana_out = "む", .valid_rules = &.{"v5"}, .reason = "te-form" },

    // Godan verbs ending in -る (e.g. 分かる) -- distinct from ichidan
    // only by which dictionary entry it turns out to match, which is
    // exactly what `valid_rules` disambiguates at lookup time.
    .{ .kana_in = "らない", .kana_out = "る", .valid_rules = &.{"v5"}, .reason = "negative" },
    .{ .kana_in = "った", .kana_out = "る", .valid_rules = &.{"v5"}, .reason = "past" },
    .{ .kana_in = "って", .kana_out = "る", .valid_rules = &.{"v5"}, .reason = "te-form" },

    // Ichidan (v1): -る drops cleanly, so one variant covers every verb.
    .{ .kana_in = "ない", .kana_out = "る", .valid_rules = &.{"v1"}, .reason = "negative" },
    .{ .kana_in = "た", .kana_out = "る", .valid_rules = &.{"v1"}, .reason = "past" },
    .{ .kana_in = "て", .kana_out = "る", .valid_rules = &.{"v1"}, .reason = "te-form" },

    // i-adjectives.
    .{ .kana_in = "くない", .kana_out = "い", .valid_rules = &.{"adj-i"}, .reason = "negative" },
    .{ .kana_in = "かった", .kana_out = "い", .valid_rules = &.{"adj-i"}, .reason = "past" },
    .{ .kana_in = "くて", .kana_out = "い", .valid_rules = &.{"adj-i"}, .reason = "te-form" },
};

/// A successful lookup: how many bytes of the source text it covers, the
/// deinflection reason (null for a direct dictionary-form hit), and the
/// matching entries by index into `Dict.entries`. `entries` is owned by
/// the caller's allocator.
pub const Match = struct {
    len: usize,
    reason: ?[]const u8 = null,
    entries: []const u32,
};

/// How many codepoints of `text` a click may resolve to. 16 covers every
/// realistic single-word span (this table's longest suffix plus a
/// multi-kanji stem) without the scan costing more than a glance.
pub const max_scan_codepoints: usize = 16;

/// Tries `text[0..L]` for decreasing `L`, longest first: a direct
/// dictionary-form match, then every deinflection rule whose `kana_in`
/// is `text[0..L]`'s suffix. Returns the first (longest) length with any
/// hit, or null if nothing in `text`'s first `max_scan_codepoints`
/// codepoints matches at all.
pub fn lookup(alloc: std.mem.Allocator, dict: *const Dict, text: []const u8) std.mem.Allocator.Error!?Match {
    var bounds: [max_scan_codepoints + 1]usize = undefined;
    var n_bounds: usize = 0;
    var i: usize = 0;
    while (n_bounds <= max_scan_codepoints and i <= text.len) {
        bounds[n_bounds] = i;
        n_bounds += 1;
        if (i >= text.len) break;
        const len = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
        i += @min(len, text.len - i);
    }

    var li = n_bounds;
    while (li > 1) {
        li -= 1;
        const L = bounds[li];
        const candidate = text[0..L];

        if (dict.by_term.get(candidate)) |idx| {
            return .{ .len = L, .entries = try alloc.dupe(u32, idx) };
        }

        for (deinflect_rules) |rule| {
            if (!std.mem.endsWith(u8, candidate, rule.kana_in)) continue;
            var buf: [128]u8 = undefined;
            const stem = candidate[0 .. candidate.len - rule.kana_in.len];
            const form = std.fmt.bufPrint(&buf, "{s}{s}", .{ stem, rule.kana_out }) catch continue;
            const idx = dict.by_term.get(form) orelse continue;

            var out: std.ArrayList(u32) = .empty;
            errdefer out.deinit(alloc);
            for (idx) |ei| {
                if (hasAnyRule(dict.entries[ei].rules, rule.valid_rules)) try out.append(alloc, ei);
            }
            if (out.items.len == 0) {
                out.deinit(alloc);
                continue;
            }
            return .{ .len = L, .reason = rule.reason, .entries = try out.toOwnedSlice(alloc) };
        }
    }
    return null;
}

fn hasAnyRule(rules: []const u8, valid: []const []const u8) bool {
    var it = std.mem.tokenizeScalar(u8, rules, ' ');
    while (it.next()) |tag| {
        for (valid) |v| {
            if (std.mem.eql(u8, tag, v)) return true;
        }
    }
    return false;
}

/// Parses one `term_bank_N.json`'s rows into `entries`. Same error
/// policy as `mokuro.parse`: a row that doesn't fit the shape is
/// dropped, never a reason to fail the whole file. `a` must be an arena
/// (or otherwise long-lived) allocator -- every `Entry` string returned
/// points into the parse tree, which is never freed separately.
pub fn parseTermBank(a: std.mem.Allocator, entries: *std.ArrayList(Entry), json: []const u8) std.mem.Allocator.Error!void {
    const parsed = std.json.parseFromSlice(std.json.Value, a, json, .{}) catch return;
    const rows = switch (parsed.value) {
        .array => |arr| arr,
        else => return,
    };
    for (rows.items) |row_val| {
        const row = switch (row_val) {
            .array => |r| r,
            else => continue,
        };
        // `[term, reading, definitionTags, rules, score, glossary, sequence, termTags]`.
        if (row.items.len < 8) continue;
        const term = jsonString(row.items[0]) orelse continue;
        try entries.append(a, .{
            .term = term,
            .reading = jsonString(row.items[1]) orelse "",
            .rules = jsonString(row.items[3]) orelse "",
            .glossary = try parseGlossary(a, row.items[5]),
            .sequence = jsonInt(row.items[6]) orelse 0,
        });
    }
}

/// `index.json`'s `title`, if the object parses and has one. Anything
/// else leaves `dict.title` as it was.
pub fn parseIndex(a: std.mem.Allocator, dict: *Dict, json: []const u8) void {
    const parsed = std.json.parseFromSlice(std.json.Value, a, json, .{}) catch return;
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return,
    };
    if (jsonString(obj.get("title") orelse return)) |t| dict.title = t;
}

fn jsonString(v: std.json.Value) ?[]const u8 {
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

fn jsonInt(v: std.json.Value) ?i64 {
    return switch (v) {
        .integer => |n| n,
        .float => |f| @intFromFloat(@round(f)),
        else => null,
    };
}

/// Flattens one glossary entry to plain text. A v3 term bank's glossary
/// items are plain strings; Jitendex and other structured-content
/// dictionaries nest tagged objects instead -- `{"tag": "...", "content":
/// [...]}`  and similar -- so every string leaf under `v` is collected in
/// document order, space-separated, rather than any of it being rendered
/// (headings, emphasis, the term-tag badges) as anything but text.
fn parseGlossary(a: std.mem.Allocator, v: std.json.Value) std.mem.Allocator.Error![]const []const u8 {
    const arr = switch (v) {
        .array => |arr| arr,
        else => return &.{},
    };
    var out: std.ArrayList([]const u8) = .empty;
    for (arr.items) |item| {
        var buf: std.ArrayList(u8) = .empty;
        try flattenText(a, item, &buf);
        if (buf.items.len == 0) {
            buf.deinit(a);
            continue;
        }
        try out.append(a, try buf.toOwnedSlice(a));
    }
    return out.toOwnedSlice(a);
}

fn flattenText(a: std.mem.Allocator, v: std.json.Value, out: *std.ArrayList(u8)) std.mem.Allocator.Error!void {
    switch (v) {
        .string => |s| {
            if (s.len == 0) return;
            if (out.items.len > 0) try out.append(a, ' ');
            try out.appendSlice(a, s);
        },
        .array => |arr| for (arr.items) |item| try flattenText(a, item, out),
        .object => |obj| if (obj.get("content")) |c| try flattenText(a, c, out),
        else => {},
    }
}

/// Fills `dict.by_term` from `dict.entries`. Must run once, after every
/// term bank has been parsed into `entries`.
pub fn buildIndex(a: std.mem.Allocator, dict: *Dict) std.mem.Allocator.Error!void {
    var builder: std.StringHashMapUnmanaged(std.ArrayListUnmanaged(u32)) = .empty;
    for (dict.entries, 0..) |e, i| {
        const gop = try builder.getOrPut(a, e.term);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(a, @intCast(i));
    }
    var final: std.StringHashMapUnmanaged([]const u32) = .empty;
    var it = builder.iterator();
    while (it.next()) |kv| {
        try final.put(a, kv.key_ptr.*, try kv.value_ptr.toOwnedSlice(a));
    }
    dict.by_term = final;
}

/// True for a zip entry name that is a term bank -- `term_bank_1.json`
/// and friends, but not `term_meta_bank_*` (frequency/pitch data) or
/// `kanji_bank_*`/`tag_bank_*`, neither of which this module reads yet.
fn isTermBankName(name: []const u8) bool {
    const base = basename(name);
    return std.mem.startsWith(u8, base, "term_bank_") and std.ascii.endsWithIgnoreCase(base, ".json");
}

fn basename(path: []const u8) []const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return path;
    return path[slash + 1 ..];
}

/// Reads and parses every `term_bank_*.json` (and, if present,
/// `index.json`) out of the Yomitan dictionary zip at `path`. One pass
/// over the central directory, the same shape `archive.zig`'s `indexZip`
/// walks a `.cbz` with.
pub fn loadFromZip(alloc: std.mem.Allocator, io: std.Io, path: []const u8) !Dict {
    var dict: Dict = .{ .arena = .init(alloc) };
    errdefer dict.arena.deinit();
    const a = dict.arena.allocator();

    const file = try std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_only });
    defer file.close(io);
    const read_buf = try alloc.alloc(u8, 64 * 1024);
    defer alloc.free(read_buf);
    var reader = file.reader(io, read_buf);

    var it = std.zip.Iterator.init(&reader) catch return error.UnknownArchiveFormat;
    var name_buf: [std.fs.max_path_bytes]u8 = undefined;

    var entries: std.ArrayList(Entry) = .empty;
    while (it.next() catch return error.UnknownArchiveFormat) |entry| {
        const name = entry.getFilename(&reader, &name_buf, .{}) catch continue;

        if (std.ascii.eqlIgnoreCase(basename(name), "index.json")) {
            if (extractEntry(alloc, &reader, entry)) |bytes| {
                defer alloc.free(bytes);
                parseIndex(a, &dict, bytes);
            } else |_| {}
            continue;
        }
        if (!isTermBankName(name)) continue;

        const bytes = extractEntry(alloc, &reader, entry) catch continue;
        defer alloc.free(bytes);
        try parseTermBank(a, &entries, bytes);
    }

    dict.entries = try entries.toOwnedSlice(a);
    try buildIndex(a, &dict);
    return dict;
}

fn extractEntry(alloc: std.mem.Allocator, reader: *std.Io.File.Reader, entry: std.zip.Iterator.Entry) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try entry.extractTo(reader, &out.writer);
    return out.toOwnedSlice();
}
