// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: GPL-3.0-or-later

//! Text normalization for dictionary lookup -- the two Japanese text
//! preprocessors from Yomitan (`ext/js/language/ja/japanese-text-
//! preprocessors.js`) that matter most for OCR'd manga text:
//!
//! - **Kana script**: every scanned string is also tried as all-katakana
//!   and as all-hiragana. Manga writes plenty of ordinary words in
//!   katakana for emphasis (スゴイ for すごい), and a dictionary headword
//!   or reading is only ever in one script.
//! - **Emphatic sequences**: runs of small っ/ッ and the long-vowel mark
//!   ー are collapsed to one (すっっごーーい -> すっごーい) and removed
//!   outright (-> すごい), since a stretched shout is never a headword.
//!
//! `variants` combines them the way Yomitan's `_getTextVariants` does:
//! the kana step runs first and the emphatic step runs on each of its
//! outputs, so up to nine distinct strings come back, each tagged with
//! how many steps actually changed it. `dict.lookup` ranks a match on
//! the original text above one that needed normalizing to be found.
//!
//! Everything here is pure: text in, owned strings out.

const std = @import("std");

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

/// One spelling `variants` produced: the text, and how many
/// normalization steps changed it on the way (0 for the original).
pub const Variant = struct {
    text: []const u8,
    steps: u8,
};

/// Every distinct spelling of `text` Yomitan would try: {as written,
/// katakana, hiragana} each through {as is, collapsed, fully collapsed}.
/// The original is always first with `steps == 0`; a spelling reachable
/// more than one way keeps its fewest steps. Every string is allocated
/// from `alloc` -- meant for a scratch arena, since nothing here frees
/// individually.
pub fn variants(alloc: std.mem.Allocator, text: []const u8) ![]Variant {
    var out: std.ArrayList(Variant) = .empty;
    try out.append(alloc, .{ .text = text, .steps = 0 });

    const kata = try toKatakana(alloc, text);
    const hira = try toHiragana(alloc, text);
    const scripts = [_]Variant{
        .{ .text = text, .steps = 0 },
        .{ .text = kata, .steps = if (std.mem.eql(u8, kata, text)) 0 else 1 },
        .{ .text = hira, .steps = if (std.mem.eql(u8, hira, text)) 0 else 1 },
    };
    for (scripts) |s| {
        const emphatic = [_]Variant{
            .{ .text = s.text, .steps = s.steps },
            .{ .text = try collapseEmphatic(alloc, s.text, false), .steps = s.steps + 1 },
            .{ .text = try collapseEmphatic(alloc, s.text, true), .steps = s.steps + 1 },
        };
        for (emphatic) |e| {
            // A step that didn't change anything isn't a step.
            const steps = if (std.mem.eql(u8, e.text, s.text)) s.steps else e.steps;
            try addVariant(alloc, &out, .{ .text = e.text, .steps = steps });
        }
    }
    return out.toOwnedSlice(alloc);
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
