// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: GPL-3.0-or-later

//! Text normalization for dictionary lookup -- Yomitan's Japanese text
//! preprocessors (`ext/js/language/ja/japanese-text-preprocessors.js`),
//! in two kinds.
//!
//! **Normalizations** run once, unconditionally, in `normalize`. Each
//! maps a spelling no dictionary ever uses onto the one it does, so
//! there is nothing to gain by also searching the original:
//!
//! - **Half-width katakana** (ｶﾞｯｺｳ -> ガッコウ), including the
//!   separate half-width (han)dakuten. mokuro does emit these.
//! - **Combining marks**: か + U+3099 -> が, は + U+309A -> ぱ.
//! - **CJK Compatibility** squares: ㍿ -> 株式会社, ㌀ -> アパート.
//! - **Radicals and strokes**: ⼀ -> 一, ⺼ -> 肉. OCR mistakes a kanji
//!   for the radical that looks identical often enough to matter.
//!
//! The last two come from `cjk_normalize_table.zig`, generated from
//! Unicode data by `scripts/gen-cjk-normalize.py`; its header says
//! where this departs from Yomitan.
//!
//! **Variants** are alternatives, because a dictionary really does
//! file words under more than one of them. `variants` tries each
//! combination the way Yomitan's `_getTextVariants` does:
//!
//! - **Alphanumeric width**: as written, ASCII and full-width (JMdict
//!   spells Ｔシャツ full-width; OCR may read the T as ASCII).
//! - **Kana script**: as written, all-katakana and all-hiragana. Manga
//!   writes plenty of ordinary words in katakana for emphasis (スゴイ
//!   for すごい), and a headword or reading is only ever in one script.
//! - **Emphatic sequences**: runs of small っ/ッ and the long-vowel mark
//!   ー are collapsed to one (すっっごーーい -> すっごーい) and removed
//!   outright (-> すごい), since a stretched shout is never a headword.
//!
//! Every spelling is tagged with how many steps actually changed it
//! (normalizing counts as one), and `dict.lookup` ranks a match on the
//! text as written above one that needed changing to be found.
//!
//! Yomitan's other two are left out: `alphabeticToHiragana` is for
//! typed romaji, not OCR, and `standardizeKanji`'s itaiji table has no
//! license and comes from a commercial dictionary.
//!
//! Everything here is pure: text in, owned strings out.

const std = @import("std");

const cjk_table = @import("cjk_normalize_table.zig");

const hiragana_first: u21 = 0x3041;
const hiragana_last: u21 = 0x3096;
const katakana_first: u21 = 0x30A1;
const katakana_last: u21 = 0x30F6;
const katakana_small_ka: u21 = 0x30F5;
const katakana_small_ke: u21 = 0x30F6;
const prolonged_sound_mark: u21 = 0x30FC;
const hiragana_small_tsu: u21 = 0x3063;
const katakana_small_tsu: u21 = 0x30C3;

/// Kana grouped by vowel, straight from Yomitan's `VOWEL_TO_KANA_MAPPING`.
/// Used only to turn a katakana ー into the hiragana vowel it lengthens
/// (スーパー -> すうぱあ), which is how a hiragana reading spells it.
const vowel_rows = [_]struct { vowel: []const u8, kana: []const u8 }{
    .{ .vowel = "あ", .kana = "ぁあかがさざただなはばぱまゃやらゎわヵァアカガサザタダナハバパマャヤラヮワヵヷ" },
    .{ .vowel = "い", .kana = "ぃいきぎしじちぢにひびぴみりゐィイキギシジチヂニヒビピミリヰヸ" },
    .{ .vowel = "う", .kana = "ぅうくぐすずっつづぬふぶぷむゅゆるゥウクグスズッツヅヌフブプムュユルヴ" },
    .{ .vowel = "え", .kana = "ぇえけげせぜてでねへべぺめれゑヶェエケゲセゼテデネヘベペメレヱヶヹ" },
    // An "o" row lengthens with う, not お -- the way the language
    // actually spells a long o (こうこう, not こおこお).
    .{ .vowel = "う", .kana = "ぉおこごそぞとどのほぼぽもょよろをォオコゴソゾトドノホボポモョヨロヲヺ" },
};

/// The hiragana vowel `prev` is lengthened with, or null when `prev`
/// isn't a kana with a vowel (a kanji, punctuation, ...).
fn prolongedHiragana(prev: u21) ?[]const u8 {
    for (vowel_rows) |row| {
        var it = std.unicode.Utf8View.initUnchecked(row.kana).iterator();
        while (it.nextCodepoint()) |cp| {
            if (cp == prev) return row.vowel;
        }
    }
    return null;
}

fn appendCodepoint(alloc: std.mem.Allocator, out: *std.ArrayList(u8), cp: u21) !void {
    var buf: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(cp, &buf) catch return;
    try out.appendSlice(alloc, buf[0..n]);
}

/// Every hiragana in `text` turned katakana; anything else unchanged.
pub fn toKatakana(alloc: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var it = (std.unicode.Utf8View.init(text) catch return alloc.dupe(u8, text)).iterator();
    while (it.nextCodepoint()) |cp| {
        const mapped = if (cp >= hiragana_first and cp <= hiragana_last) cp + (katakana_first - hiragana_first) else cp;
        try appendCodepoint(alloc, &out, mapped);
    }
    return out.toOwnedSlice(alloc);
}

/// Every katakana in `text` turned hiragana, and a ー after a kana turned
/// into the vowel it lengthens. ヵ/ヶ stay as they are -- as counters
/// (一ヶ月) they aren't really kana at all, the same exception Yomitan
/// makes.
pub fn toHiragana(alloc: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var prev: ?u21 = null;
    var it = (std.unicode.Utf8View.init(text) catch return alloc.dupe(u8, text)).iterator();
    while (it.nextCodepoint()) |cp| {
        var mapped = cp;
        if (cp == prolonged_sound_mark) {
            if (prev) |p| if (prolongedHiragana(p)) |vowel| {
                try out.appendSlice(alloc, vowel);
                prev = std.unicode.utf8Decode(vowel) catch cp;
                continue;
            };
        } else if (cp != katakana_small_ka and cp != katakana_small_ke and
            cp >= katakana_first and cp <= katakana_last)
        {
            mapped = cp - (katakana_first - hiragana_first);
        }
        try appendCodepoint(alloc, &out, mapped);
        prev = mapped;
    }
    return out.toOwnedSlice(alloc);
}

fn isEmphatic(cp: u21) bool {
    return cp == hiragana_small_tsu or cp == katakana_small_tsu or cp == prolonged_sound_mark;
}

/// Yomitan's `collapseEmphaticSequences`: inside the string (leading and
/// trailing runs are kept as-is), a run of one repeated emphatic
/// character collapses to a single one, or with `full` disappears
/// entirely. A string that is nothing but emphatics comes back unchanged.
pub fn collapseEmphatic(alloc: std.mem.Allocator, text: []const u8, full: bool) ![]u8 {
    var cps: std.ArrayList(u21) = .empty;
    defer cps.deinit(alloc);
    var it = (std.unicode.Utf8View.init(text) catch return alloc.dupe(u8, text)).iterator();
    while (it.nextCodepoint()) |cp| try cps.append(alloc, cp);

    const all = cps.items;
    var left: usize = 0;
    while (left < all.len and isEmphatic(all[left])) left += 1;
    var right: usize = all.len;
    while (right > left and isEmphatic(all[right - 1])) right -= 1;
    if (left >= right) return alloc.dupe(u8, text);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    for (all[0..left]) |cp| try appendCodepoint(alloc, &out, cp);
    var current: ?u21 = null;
    for (all[left..right]) |cp| {
        if (isEmphatic(cp)) {
            if (current != cp) {
                current = cp;
                if (!full) try appendCodepoint(alloc, &out, cp);
            }
        } else {
            current = null;
            try appendCodepoint(alloc, &out, cp);
        }
    }
    for (all[right..]) |cp| try appendCodepoint(alloc, &out, cp);
    return out.toOwnedSlice(alloc);
}

const halfwidth_first: u21 = 0xFF65;
const halfwidth_dakuten: u21 = 0xFF9E;
const halfwidth_handakuten: u21 = 0xFF9F;
const combining_dakuten: u21 = 0x3099;
const combining_handakuten: u21 = 0x309A;

/// Half-width katakana U+FF65..FF9D in order, straight from Yomitan's
/// `HALFWIDTH_KATAKANA_MAPPING`: each row is the full-width kana plain,
/// with a following ﾞ and with a following ﾟ, `-` where that mark
/// can't attach (the mark is then left in place).
const halfwidth_rows = [_][]const u8{
    "・--", "ヲヺ-", "ァ--", "ィ--", "ゥ--", "ェ--", "ォ--", "ャ--",
    "ュ--", "ョ--", "ッ--", "ー--", "ア--", "イ--", "ウヴ-", "エ--",
    "オ--", "カガ-", "キギ-", "クグ-", "ケゲ-", "コゴ-", "サザ-", "シジ-",
    "スズ-", "セゼ-", "ソゾ-", "タダ-", "チヂ-", "ツヅ-", "テデ-", "トド-",
    "ナ--", "ニ--", "ヌ--", "ネ--", "ノ--", "ハバパ", "ヒビピ", "フブプ",
    "ヘベペ", "ホボポ", "マ--", "ミ--", "ム--", "メ--", "モ--", "ヤ--",
    "ユ--", "ヨ--", "ラ--", "リ--", "ル--", "レ--", "ロ--", "ワ--",
    "ン--",
};

/// The full-width kana for half-width `cp` with mark `which` (0 plain,
/// 1 dakuten, 2 handakuten), or null when `cp` isn't half-width kana or
/// that mark can't attach to it.
fn halfwidthKana(cp: u21, which: usize) ?u21 {
    if (cp < halfwidth_first or cp >= halfwidth_first + halfwidth_rows.len) return null;
    var it = std.unicode.Utf8View.initUnchecked(halfwidth_rows[cp - halfwidth_first]).iterator();
    var i: usize = 0;
    while (it.nextCodepoint()) |got| : (i += 1) {
        if (i == which) return if (got == '-') null else got;
    }
    return null;
}

// Yomitan's `dakutenAllowed`/`handakutenAllowed`. Like Yomitan's, the
// ranges let through a few kana that take no mark (っ, ぱ, ...); a
// combining mark never follows one of those in real text.
fn dakutenAllowed(cp: u21) bool {
    return (cp >= 0x304B and cp <= 0x3068) or (cp >= 0x306F and cp <= 0x307B) or
        (cp >= 0x30AB and cp <= 0x30C8) or (cp >= 0x30CF and cp <= 0x30DB);
}

fn handakutenAllowed(cp: u21) bool {
    return (cp >= 0x306F and cp <= 0x307B) or (cp >= 0x30CF and cp <= 0x30DB);
}

fn cjkReplacement(cp: u21) ?[]const u8 {
    const entries = &cjk_table.entries;
    var lo: usize = 0;
    var hi: usize = entries.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (entries[mid].from == cp) return entries[mid].to;
        if (entries[mid].from < cp) lo = mid + 1 else hi = mid;
    }
    return null;
}

/// All four normalizations in one pass: half-width katakana (with its
/// separate ﾞ/ﾟ) to full-width, a combining (han)dakuten folded into
/// the kana before it, and CJK Compatibility squares, radicals and
/// strokes replaced from `cjk_normalize_table.zig`. A half-width kana
/// followed by a *combining* mark (ｶ + U+3099) is converted first and
/// then folded (-> ガ), the same as Yomitan's chain of separate passes.
pub fn normalize(alloc: std.mem.Allocator, text: []const u8) ![]u8 {
    var cps: std.ArrayList(u21) = .empty;
    defer cps.deinit(alloc);
    var it = (std.unicode.Utf8View.init(text) catch return alloc.dupe(u8, text)).iterator();
    while (it.nextCodepoint()) |cp| try cps.append(alloc, cp);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    const all = cps.items;
    var i: usize = 0;
    while (i < all.len) {
        const original = all[i];
        var cp = original;
        i += 1;
        if (halfwidthKana(original, 0)) |plain| {
            cp = plain;
            const mark: usize = if (i < all.len and all[i] == halfwidth_dakuten)
                1
            else if (i < all.len and all[i] == halfwidth_handakuten)
                2
            else
                0;
            if (mark != 0) {
                if (halfwidthKana(original, mark)) |marked| {
                    cp = marked;
                    i += 1;
                }
            }
        }
        if (i < all.len and all[i] == combining_dakuten and dakutenAllowed(cp)) {
            cp += 1;
            i += 1;
        } else if (i < all.len and all[i] == combining_handakuten and handakutenAllowed(cp)) {
            cp += 2;
            i += 1;
        }
        if (cjkReplacement(cp)) |to| {
            try out.appendSlice(alloc, to);
        } else {
            try appendCodepoint(alloc, &out, cp);
        }
    }
    return out.toOwnedSlice(alloc);
}

/// Full-width digits and Latin letters (０-９, Ａ-Ｚ, ａ-ｚ) turned ASCII;
/// anything else unchanged.
pub fn toAsciiAlphanumeric(alloc: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var it = (std.unicode.Utf8View.init(text) catch return alloc.dupe(u8, text)).iterator();
    while (it.nextCodepoint()) |cp| {
        const mapped: u21 = switch (cp) {
            0xFF10...0xFF19, 0xFF21...0xFF3A, 0xFF41...0xFF5A => cp - (0xFF10 - '0'),
            else => cp,
        };
        try appendCodepoint(alloc, &out, mapped);
    }
    return out.toOwnedSlice(alloc);
}

/// ASCII digits and Latin letters turned full-width; anything else
/// unchanged.
pub fn toFullWidthAlphanumeric(alloc: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var it = (std.unicode.Utf8View.init(text) catch return alloc.dupe(u8, text)).iterator();
    while (it.nextCodepoint()) |cp| {
        const mapped: u21 = switch (cp) {
            '0'...'9', 'A'...'Z', 'a'...'z' => cp + (0xFF10 - '0'),
            else => cp,
        };
        try appendCodepoint(alloc, &out, mapped);
    }
    return out.toOwnedSlice(alloc);
}

/// One spelling `variants` produced: the text, and how many
/// normalization steps changed it on the way (0 for the original).
pub const Variant = struct {
    text: []const u8,
    steps: u8,
};

/// The independent choices `variants` multiplies out, in Yomitan's
/// order. Each offers two alternatives to the spelling it is given.
const Axis = enum { alphanumeric_width, script, emphatic };

/// Every distinct spelling of `text` Yomitan would try: `text` through
/// `normalize`, then {as written, ASCII, full-width} each through {as
/// written, katakana, hiragana} each through {as is, collapsed, fully
/// collapsed}. The normalized text is always first, with `steps` 0
/// unless normalizing changed it; a spelling reachable more than one
/// way keeps its fewest steps. Every string is allocated from `alloc`
/// -- meant for a scratch arena, since nothing here frees individually.
pub fn variants(alloc: std.mem.Allocator, text: []const u8) ![]Variant {
    var out: std.ArrayList(Variant) = .empty;
    const normalized = try normalize(alloc, text);
    const steps: u8 = if (std.mem.eql(u8, normalized, text)) 0 else 1;
    try out.append(alloc, .{ .text = normalized, .steps = steps });
    for ([_]Axis{ .alphanumeric_width, .script, .emphatic }) |axis| {
        try expandAxis(alloc, &out, axis);
    }
    return out.toOwnedSlice(alloc);
}

/// Adds `axis`'s alternatives to every spelling already in `out`; the
/// spellings themselves stay, as the axis's "as written" choice.
fn expandAxis(alloc: std.mem.Allocator, out: *std.ArrayList(Variant), axis: Axis) !void {
    const n = out.items.len;
    for (0..n) |i| {
        const v = out.items[i];
        const alternatives: [2][]const u8 = switch (axis) {
            .alphanumeric_width => .{
                try toAsciiAlphanumeric(alloc, v.text),
                try toFullWidthAlphanumeric(alloc, v.text),
            },
            .script => .{
                try toKatakana(alloc, v.text),
                try toHiragana(alloc, v.text),
            },
            .emphatic => .{
                try collapseEmphatic(alloc, v.text, false),
                try collapseEmphatic(alloc, v.text, true),
            },
        };
        for (alternatives) |alt| {
            // A step that didn't change anything isn't a step.
            const steps = if (std.mem.eql(u8, alt, v.text)) v.steps else v.steps + 1;
            try addVariant(alloc, out, .{ .text = alt, .steps = steps });
        }
    }
}

fn addVariant(alloc: std.mem.Allocator, out: *std.ArrayList(Variant), v: Variant) !void {
    for (out.items) |*existing| {
        if (std.mem.eql(u8, existing.text, v.text)) {
            existing.steps = @min(existing.steps, v.steps);
            return;
        }
    }
    try out.append(alloc, v);
}
