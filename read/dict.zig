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
//! `loadFromDir` reads an already-*unzipped* dictionary directory, not
//! the zip itself -- `read.conf.lua`'s `dictionary` key names the
//! directory a Jitendex download was extracted to once, by hand. Two
//! things pushed that way rather than reading the zip in place: a real
//! dictionary is large enough (Jitendex's term banks run to a few
//! hundred MB of JSON total) that decompressing it is real time to pay
//! on every book opened, not just the first; and see the next paragraph.
//!
//! Lookup does not tokenize the page's text up front. Japanese has no
//! spaces, so -- the same trick Yomitan itself uses -- a click just picks
//! a starting byte offset, and `lookup` tries decreasing-length candidate
//! substrings from there, deinflecting each one against a small rule
//! table before giving up on it. The longest substring with any match,
//! inflected or not, wins.
//!
//! **Parsing keeps the JSON tree off the dictionary's own arena.**
//! `std.json.Value` is a generic tree -- a hashmap per object, an
//! `ArrayList` per array, a tagged union per scalar -- and for a
//! multi-hundred-MB term bank that tree can outweigh the source JSON
//! several times over. `parseTermBank` parses each file into its own
//! short-lived scratch arena, copies out only the handful of fields an
//! `Entry` keeps, and frees the tree before the next file -- so peak
//! memory is bounded by one term bank file's tree plus however many
//! `Entry`s have been extracted so far, not by every file's tree held
//! at once. The first version of this shared one arena for both and
//! reliably ran a real machine out of memory before the book it was
//! opened for ever got to render a page.
//!
//! Everything here except `loadFromDir` is pure -- JSON and text in,
//! structs out -- so `tests/read_tests.zig` can pin the parse and the
//! lookup without a dictionary file on disk. `loadFromDir` is the one
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

/// Parses one `term_bank_N.json`'s rows into `entries`, appended with
/// `dict_a` -- the dictionary's own long-lived arena, the only allocator
/// this function's *results* ever end up on. Same drop-don't-fail error
/// policy as `mokuro.parse`: a row that doesn't fit the shape is
/// dropped, never a reason to fail the whole file.
///
/// `scratch_backing` backs a fresh arena that holds the `std.json.Value`
/// parse tree and nothing else; it's destroyed before this returns, so
/// nothing in `entries` may point into it -- every field kept is
/// explicitly `dict_a.dupe`'d off the tree first. See the module doc
/// comment for why that split exists.
pub fn parseTermBank(
    dict_a: std.mem.Allocator,
    scratch_backing: std.mem.Allocator,
    entries: *std.ArrayList(Entry),
    json: []const u8,
) std.mem.Allocator.Error!void {
    var scratch: std.heap.ArenaAllocator = .init(scratch_backing);
    defer scratch.deinit();
    const sa = scratch.allocator();

    const parsed = std.json.parseFromSlice(std.json.Value, sa, json, .{}) catch return;
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
        const glossary = try parseGlossary(sa, row.items[5]);
        try entries.append(dict_a, .{
            .term = try dict_a.dupe(u8, term),
            .reading = try dict_a.dupe(u8, jsonString(row.items[1]) orelse ""),
            .rules = try dict_a.dupe(u8, jsonString(row.items[3]) orelse ""),
            .glossary = try dupeStrings(dict_a, glossary),
            .sequence = jsonInt(row.items[6]) orelse 0,
        });
    }
}

fn dupeStrings(a: std.mem.Allocator, strs: []const []const u8) std.mem.Allocator.Error![]const []const u8 {
    const out = try a.alloc([]const u8, strs.len);
    for (strs, 0..) |s, i| out[i] = try a.dupe(u8, s);
    return out;
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

/// True for a file name that is a term bank -- `term_bank_1.json` and
/// friends, but not `term_meta_bank_*` (frequency/pitch data) or
/// `kanji_bank_*`/`tag_bank_*`, neither of which this module reads yet.
fn isTermBankName(name: []const u8) bool {
    return std.mem.startsWith(u8, name, "term_bank_") and std.ascii.endsWithIgnoreCase(name, ".json");
}

/// Ceiling on one term bank file's raw JSON size. Jitendex's largest
/// files run to tens of MB; 256 MiB is the "obviously wrong" line for a
/// single file the same way `archive.max_page_bytes` draws one for a
/// page image, not a realistic size.
pub const max_term_bank_bytes: usize = 256 * 1024 * 1024;
/// `index.json` is a few hundred bytes in practice.
pub const max_index_bytes: usize = 1024 * 1024;

/// Reads and parses every `term_bank_*.json` (and, if present,
/// `index.json`) directly inside the directory at `path` -- an already
/// *unzipped* Yomitan dictionary, not the zip itself. See the module
/// doc comment for why: decompressing a several-hundred-MB dictionary on
/// every book opened is real time to spend more than once, and the
/// per-file scratch arena below is what keeps the parse itself from
/// blowing past available memory on a dictionary this size.
pub fn loadFromDir(alloc: std.mem.Allocator, io: std.Io, path: []const u8) !Dict {
    var dict: Dict = .{ .arena = .init(alloc) };
    errdefer dict.arena.deinit();
    const a = dict.arena.allocator();

    var dir = try std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
    defer dir.close(io);

    var entries: std.ArrayList(Entry) = .empty;
    var it = dir.iterate();
    while (it.next(io) catch null) |raw| {
        if (raw.kind != .file) continue;

        if (std.ascii.eqlIgnoreCase(raw.name, "index.json")) {
            if (dir.readFileAlloc(io, raw.name, alloc, .limited(max_index_bytes))) |bytes| {
                defer alloc.free(bytes);
                parseIndex(a, &dict, bytes);
            } else |_| {}
            continue;
        }
        if (!isTermBankName(raw.name)) continue;

        const bytes = dir.readFileAlloc(io, raw.name, alloc, .limited(max_term_bank_bytes)) catch continue;
        defer alloc.free(bytes);
        // `alloc`, not `a`: the scratch arena backing this file's parse
        // tree is unrelated to the dictionary's own long-lived one.
        try parseTermBank(a, alloc, &entries, bytes);
    }

    dict.entries = try entries.toOwnedSlice(a);
    try buildIndex(a, &dict);
    return dict;
}
