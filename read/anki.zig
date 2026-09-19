// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: GPL-3.0-or-later

//! Anki card mining for gw-read: what a card is made of, how each piece
//! is rendered into a note field, the AnkiConnect request that adds it,
//! and the background job that sends it.
//!
//! **The flow it serves** (ui.zig drives it): `c` with a dictionary
//! lookup or an AI answer showing captures a `Note` from what is on
//! screen, a crop of the page is picked (crop.zig), a read-only preview
//! lists the fields about to be filled, and Enter posts one `addNote` to
//! AnkiConnect. The shape follows jidoujisho's Android card creator,
//! down to its default note type, `jidoujisho Kinomoto`, whose field
//! names are `default_fields` below.
//!
//! **Why AnkiConnect and not AnkiWeb.** AnkiWeb has no API for adding
//! notes; desktop Anki with the AnkiConnect add-on (2055492159) is the
//! only supported way in, and Anki's own sync carries the note to AnkiWeb
//! (`anki_sync_after_add` asks it to straight away).
//!
//! **Media rides the same request.** The cropped JPEG goes in `picture`
//! as base64 and the audio in `audio` as a URL AnkiConnect downloads
//! itself, so one round trip adds the note and stores both files. The
//! audio entry carries `jpod_missing_md5` as its `skipHash`: JapanesePod101
//! answers a word it has no recording for with a fixed "no audio" clip,
//! and AnkiConnect drops a download whose MD5 matches.
//!
//! Split into `read_support` so `tests/read_tests.zig` can cover the
//! furigana alignment and both sides of the JSON without a network.

const std = @import("std");

/// One piece of card data a note field can be filled from. `anki_fields`
/// in `read.conf.lua` maps note field names to these by name.
pub const Source = enum {
    /// The dictionary form of the looked-up word; the whole bubble on a
    /// sentence card.
    term,
    reading,
    /// Anki's `漢字[かんじ]` syntax, aligned so okurigana stay outside
    /// the brackets (`見張[みは]る`).
    furigana,
    /// The whole OCR bubble the word came from.
    sentence,
    /// The bubble split around the looked-up span.
    cloze_before,
    cloze_inside,
    cloze_after,
    /// The dictionary senses; the AI translation on a sentence card.
    meaning,
    /// The AI explanation of the bubble, when one was open or cached.
    ai,
    /// The book's name (a file name, never a path).
    book,
    /// The 1-based page number.
    page,
    /// The cropped page image (`<img>`), when one was taken.
    image,
    /// The word's audio (`[sound:]`), when a source has one.
    audio,

    pub const all = [_]Source{ .term, .reading, .furigana, .sentence, .cloze_before, .cloze_inside, .cloze_after, .meaning, .ai, .book, .page, .image, .audio };

    /// A source by its name as written in `anki_fields` -- the tag name.
    pub fn parse(text: []const u8) ?Source {
        for (all) |s| {
            if (std.mem.eql(u8, text, @tagName(s))) return s;
        }
        return null;
    }
};

/// One `anki_fields` entry: a note field and what fills it.
pub const FieldMap = struct {
    field: []const u8,
    source: Source,
};

/// jidoujisho's `jidoujisho Kinomoto` note type, which is what cards
/// mined on the phone already use -- so a card from gw-read lands in the
/// same deck looking the same. Its `Expanded Meaning`, `Collapsed
/// Meaning`, `Frequency`, `Pitch Accent` and `Sentence Audio` fields have
/// no source here and are left empty, as jidoujisho mostly leaves them.
pub const default_fields = [_]FieldMap{
    .{ .field = "Term", .source = .term },
    .{ .field = "Reading", .source = .reading },
    .{ .field = "Furigana", .source = .furigana },
    .{ .field = "Sentence", .source = .sentence },
    .{ .field = "Cloze Before", .source = .cloze_before },
    .{ .field = "Cloze Inside", .source = .cloze_inside },
    .{ .field = "Cloze After", .source = .cloze_after },
    .{ .field = "Meaning", .source = .meaning },
    .{ .field = "Notes", .source = .ai },
    .{ .field = "Context", .source = .book },
    .{ .field = "Image", .source = .image },
    .{ .field = "Term Audio", .source = .audio },
};

pub const default_url = "http://127.0.0.1:8765";
pub const default_deck = "Default";
pub const default_model = "jidoujisho Kinomoto";

/// `anki_audio_url`'s default. `{term}` and `{reading}` are replaced,
/// percent-encoded; a template without them is used as-is.
pub const jpod_audio_url = "https://assets.languagepod101.com/dictionary/japanese/audiomp3.php?kanji={term}&kana={reading}";

/// MD5 of JapanesePod101's "the audio for this clip is currently not
/// available" recording, which it serves (HTTP 200) for any word it has
/// no clip of. A real clip is a 301 to its CDN instead -- see `Job.probe`.
pub const jpod_missing_md5 = "7e2c2f954ef6051373ba916f000168dc";

/// The cropped page, JPEG-encoded (crop.zig).
pub const Image = struct {
    jpeg: []u8,
    width: u32,
    height: u32,
};

/// Whether the word's audio is worth attaching, as far as is known.
pub const AudioState = enum {
    /// No `anki_audio_url`, or a sentence card (no single word to say).
    off,
    /// The probe is still out, or the source can't be probed. Attached
    /// anyway, with the skip hash as the backstop.
    unknown,
    available,
    missing,
};

/// Everything a card is made from, captured when `c` is pressed so a
/// later lookup or page turn can't change it underneath the preview.
/// Every slice is owned.
pub const Note = struct {
    kind: Kind,
    term: []u8,
    reading: []u8,
    sentence: []u8,
    cloze_before: []u8,
    cloze_inside: []u8,
    cloze_after: []u8,
    /// One flattened string per sense. Empty on a sentence card.
    glossary: []const []u8,
    /// The AI answer, already plain text (`ai.plainText`), or empty.
    ai: []u8,
    book: []u8,
    page: usize,
    image: ?Image = null,
    /// The resolved audio URL, or empty when `audio` is `.off`.
    audio_url: []u8,
    audio: AudioState,

    /// A word card is built around one dictionary entry; a sentence card
    /// (from the AI panel with no word picked) around the whole bubble.
    pub const Kind = enum { word, sentence };

    pub const Init = struct {
        kind: Kind = .word,
        term: []const u8,
        reading: []const u8 = "",
        sentence: []const u8,
        /// Byte span of the looked-up word inside `sentence`; `start ==
        /// end` for a sentence card.
        span_start: usize = 0,
        span_end: usize = 0,
        glossary: []const []const u8 = &.{},
        ai: []const u8 = "",
        book: []const u8 = "",
        page: usize = 0,
        /// `anki_audio_url`; empty (or a sentence card) means no audio.
        audio_template: []const u8 = "",
    };

    /// Copies everything `in` points at.
    pub fn create(alloc: std.mem.Allocator, in: Init) !Note {
        var arena_list: std.ArrayList([]u8) = .empty;
        defer arena_list.deinit(alloc);
        errdefer for (arena_list.items) |s| alloc.free(s);

        const start = @min(in.span_start, in.sentence.len);
        const end = std.math.clamp(in.span_end, start, in.sentence.len);
        const dup = struct {
            fn f(a: std.mem.Allocator, list: *std.ArrayList([]u8), s: []const u8) ![]u8 {
                const copy = try a.dupe(u8, s);
                errdefer a.free(copy);
                try list.append(a, copy);
                return copy;
            }
        }.f;

        const term = try dup(alloc, &arena_list, in.term);
        const reading = try dup(alloc, &arena_list, in.reading);
        const sentence = try dup(alloc, &arena_list, in.sentence);
        const before = try dup(alloc, &arena_list, in.sentence[0..start]);
        const inside = try dup(alloc, &arena_list, in.sentence[start..end]);
        const after = try dup(alloc, &arena_list, in.sentence[end..]);
        const ai_text = try dup(alloc, &arena_list, in.ai);
        const book = try dup(alloc, &arena_list, in.book);
        const audio_url: []u8 = if (in.kind == .word and in.audio_template.len > 0 and in.term.len > 0)
            try audioUrl(alloc, in.audio_template, in.term, in.reading)
        else
            try alloc.alloc(u8, 0);
        errdefer alloc.free(audio_url);

        const glossary = try alloc.alloc([]u8, in.glossary.len);
        var filled: usize = 0;
        errdefer {
            for (glossary[0..filled]) |g| alloc.free(g);
            alloc.free(glossary);
        }
        for (in.glossary) |g| {
            glossary[filled] = try alloc.dupe(u8, g);
            filled += 1;
        }

        return .{
            .kind = in.kind,
            .term = term,
            .reading = reading,
            .sentence = sentence,
            .cloze_before = before,
            .cloze_inside = inside,
            .cloze_after = after,
            .glossary = glossary,
            .ai = ai_text,
            .book = book,
            .page = in.page,
            .audio_url = audio_url,
            .audio = if (audio_url.len > 0) .unknown else .off,
        };
    }

    pub fn setImage(self: *Note, alloc: std.mem.Allocator, image: ?Image) void {
        if (self.image) |old| alloc.free(old.jpeg);
        self.image = image;
    }

    pub fn deinit(self: *Note, alloc: std.mem.Allocator) void {
        for ([_][]u8{ self.term, self.reading, self.sentence, self.cloze_before, self.cloze_inside, self.cloze_after, self.ai, self.book, self.audio_url }) |s| alloc.free(s);
        for (self.glossary) |g| alloc.free(g);
        alloc.free(self.glossary);
        self.setImage(alloc, null);
        self.* = undefined;
    }

    /// Whether `audio` is going on the card.
    pub fn attachAudio(self: *const Note) bool {
        return self.audio == .unknown or self.audio == .available;
    }
};

// ── Field rendering ────────────────────────────────────────────────────

/// The HTML a note field gets for `source`. `image` and `audio` render
/// empty: AnkiConnect writes their `<img>` / `[sound:]` itself when it
/// stores the media (`buildAddNote`).
pub fn fieldValue(alloc: std.mem.Allocator, note: *const Note, source: Source) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    const w = &out.writer;
    switch (source) {
        .term => try writeHtml(w, note.term),
        .reading => try writeHtml(w, note.reading),
        .furigana => if (note.kind == .word) {
            const f = try furigana(alloc, note.term, note.reading);
            defer alloc.free(f);
            try writeHtml(w, f);
        },
        .sentence => try writeHtml(w, note.sentence),
        .cloze_before => try writeHtml(w, note.cloze_before),
        .cloze_inside => try writeHtml(w, note.cloze_inside),
        .cloze_after => try writeHtml(w, note.cloze_after),
        .meaning => if (note.glossary.len > 0) {
            // jidoujisho's own layout: one `◦ sense` per line.
            for (note.glossary, 0..) |g, i| {
                if (i > 0) try w.writeAll("<br>");
                try w.writeAll("\u{25e6}  ");
                try writeHtml(w, g);
            }
        } else if (note.kind == .sentence) {
            try writeHtml(w, note.ai);
        },
        // On a sentence card the AI answer *is* the meaning; repeating it
        // in Notes would only double the card.
        .ai => if (note.kind == .word) try writeHtml(w, note.ai),
        .book => try writeHtml(w, note.book),
        .page => if (note.page > 0) try w.print("{d}", .{note.page}),
        .image, .audio => {},
    }
    return out.toOwnedSlice();
}

/// One line of plain text for the preview panel: what `source` will put
/// in its field, without the markup. The caller's panel clips it.
pub fn previewValue(alloc: std.mem.Allocator, note: *const Note, source: Source) ![]u8 {
    return switch (source) {
        .image => if (note.image) |img|
            std.fmt.allocPrint(alloc, "{d}x{d} jpeg, {d} KB", .{ img.width, img.height, (img.jpeg.len + 1023) / 1024 })
        else
            alloc.dupe(u8, ""),
        .audio => alloc.dupe(u8, switch (note.audio) {
            .off => "",
            .unknown => "checking / fetched by Anki",
            .available => "found",
            .missing => "no clip for this word",
        }),
        .meaning => if (note.glossary.len > 0) blk: {
            var out: std.ArrayList(u8) = .empty;
            errdefer out.deinit(alloc);
            for (note.glossary, 0..) |g, i| {
                if (i > 0) try out.appendSlice(alloc, "; ");
                try out.appendSlice(alloc, g);
            }
            break :blk oneLine(alloc, try out.toOwnedSlice(alloc));
        } else if (note.kind == .sentence) oneLine(alloc, try alloc.dupe(u8, note.ai)) else alloc.dupe(u8, ""),
        .ai => if (note.kind == .word) oneLine(alloc, try alloc.dupe(u8, note.ai)) else alloc.dupe(u8, ""),
        .furigana => if (note.kind == .word) furigana(alloc, note.term, note.reading) else alloc.dupe(u8, ""),
        .page => if (note.page > 0) std.fmt.allocPrint(alloc, "{d}", .{note.page}) else alloc.dupe(u8, ""),
        .term => oneLine(alloc, try alloc.dupe(u8, note.term)),
        .reading => alloc.dupe(u8, note.reading),
        .sentence => oneLine(alloc, try alloc.dupe(u8, note.sentence)),
        .cloze_before => alloc.dupe(u8, note.cloze_before),
        .cloze_inside => alloc.dupe(u8, note.cloze_inside),
        .cloze_after => alloc.dupe(u8, note.cloze_after),
        .book => alloc.dupe(u8, note.book),
    };
}

/// Folds every newline in an owned string to a space, in place.
fn oneLine(alloc: std.mem.Allocator, s: []u8) ![]u8 {
    _ = alloc;
    for (s) |*c| {
        if (c.* == '\n' or c.* == '\r') c.* = ' ';
    }
    return s;
}

/// Escapes `text` for an Anki field (which is HTML), turning newlines
/// into `<br>` so a multi-paragraph AI answer keeps its breaks.
pub fn writeHtml(w: *std.Io.Writer, text: []const u8) !void {
    for (text) |c| switch (c) {
        '&' => try w.writeAll("&amp;"),
        '<' => try w.writeAll("&lt;"),
        '>' => try w.writeAll("&gt;"),
        '"' => try w.writeAll("&quot;"),
        '\n' => try w.writeAll("<br>"),
        '\r' => {},
        else => try w.writeByte(c),
    };
}

// ── Furigana ───────────────────────────────────────────────────────────

/// Anki's furigana syntax for `term` read as `reading`: every run of
/// kanji gets its own bracket and the kana between runs stay outside, so
/// `見張る` / `みはる` is `見張[みは]る` and `お茶` / `おちゃ` is
/// `お 茶[ちゃ]` -- the space tells Anki where the bracketed run starts.
///
/// The alignment matches each kana run of the term against the reading
/// (katakana and hiragana compared as equal) and gives each kanji run
/// whatever lies between, trying the shortest share first and backing
/// off when a later kana run doesn't line up. A term that won't align --
/// irregular readings like 今日/きょう are fine, but a reading that
/// disagrees with the term's own kana isn't -- falls back to one bracket
/// over the whole term. A term with nothing to read -- kana only, or no
/// reading given -- has no furigana at all and comes back empty, so the
/// card's Furigana field doesn't just repeat the Term field.
pub fn furigana(alloc: std.mem.Allocator, term: []const u8, reading: []const u8) ![]u8 {
    const t = try codepoints(alloc, term);
    defer alloc.free(t);
    var any_kanji = false;
    for (t) |cp| {
        if (isKanji(cp)) any_kanji = true;
    }
    if (!any_kanji or reading.len == 0 or std.mem.eql(u8, term, reading)) return alloc.alloc(u8, 0);
    const r = try codepoints(alloc, reading);
    defer alloc.free(r);

    // Runs of the term: kana runs must appear verbatim in the reading.
    var runs: std.ArrayList(Run) = .empty;
    defer runs.deinit(alloc);
    var i: usize = 0;
    while (i < t.len) {
        const kana_run = isKana(t[i]);
        var j = i + 1;
        while (j < t.len and isKana(t[j]) == kana_run) j += 1;
        try runs.append(alloc, .{ .start = i, .end = j, .kana = kana_run });
        i = j;
    }
    if (runs.items.len == 1 and runs.items[0].kana) return alloc.dupe(u8, term);

    const shares = try alloc.alloc(Share, runs.items.len);
    defer alloc.free(shares);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    if (align_(t, r, runs.items, 0, 0, shares)) {
        for (runs.items, 0..) |run, k| {
            if (run.kana) {
                try appendCps(alloc, &out, t[run.start..run.end]);
                continue;
            }
            if (out.items.len > 0) try out.append(alloc, ' ');
            try appendCps(alloc, &out, t[run.start..run.end]);
            try out.append(alloc, '[');
            try appendCps(alloc, &out, r[shares[k].start..shares[k].end]);
            try out.append(alloc, ']');
        }
    } else {
        try out.appendSlice(alloc, term);
        try out.append(alloc, '[');
        try out.appendSlice(alloc, reading);
        try out.append(alloc, ']');
    }
    return out.toOwnedSlice(alloc);
}

const Run = struct { start: usize, end: usize, kana: bool };
const Share = struct { start: usize, end: usize };

/// Backtracking alignment of `runs[k..]` against `r[pos..]`, recording
/// each kanji run's slice of the reading in `shares`.
fn align_(t: []const u21, r: []const u21, runs: []const Run, k: usize, pos: usize, shares: []Share) bool {
    if (k == runs.len) return pos == r.len;
    const run = runs[k];
    if (run.kana) {
        const n = run.end - run.start;
        if (pos + n > r.len) return false;
        for (0..n) |d| {
            if (foldKana(t[run.start + d]) != foldKana(r[pos + d])) return false;
        }
        return align_(t, r, runs, k + 1, pos + n, shares);
    }
    // A kanji run reads as at least one kana; the last run takes the rest.
    var take: usize = 1;
    while (pos + take <= r.len) : (take += 1) {
        if (k + 1 == runs.len and pos + take != r.len) continue;
        shares[k] = .{ .start = pos, .end = pos + take };
        if (align_(t, r, runs, k + 1, pos + take, shares)) return true;
    }
    return false;
}

/// CJK ideographs (the main block, extension A, compatibility) and 々,
/// the repeat mark that stands in for one.
fn isKanji(cp: u21) bool {
    return (cp >= 0x4E00 and cp <= 0x9FFF) or (cp >= 0x3400 and cp <= 0x4DBF) or (cp >= 0xF900 and cp <= 0xFAFF) or cp == 0x3005;
}

fn isKana(cp: u21) bool {
    return (cp >= 0x3041 and cp <= 0x3096) or (cp >= 0x30A1 and cp <= 0x30FA) or cp == 0x30FC;
}

/// Katakana folded onto hiragana, one codepoint for one -- unlike
/// `kana.toHiragana`, which expands ー and would break the index-for-index
/// comparison `align_` does.
fn foldKana(cp: u21) u21 {
    if (cp >= 0x30A1 and cp <= 0x30F6) return cp - 0x60;
    return cp;
}

fn codepoints(alloc: std.mem.Allocator, text: []const u8) ![]u21 {
    var out: std.ArrayList(u21) = .empty;
    errdefer out.deinit(alloc);
    var it = (std.unicode.Utf8View.init(text) catch return error.InvalidUtf8).iterator();
    while (it.nextCodepoint()) |cp| try out.append(alloc, cp);
    return out.toOwnedSlice(alloc);
}

fn appendCps(alloc: std.mem.Allocator, out: *std.ArrayList(u8), cps: []const u21) !void {
    for (cps) |cp| {
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &buf) catch continue;
        try out.appendSlice(alloc, buf[0..n]);
    }
}

// ── Audio ──────────────────────────────────────────────────────────────

/// `template` with `{term}` and `{reading}` filled in, percent-encoded.
/// A kana-only word has no separate reading in some dictionaries; the
/// term stands in for it, which is what JapanesePod101 expects.
pub fn audioUrl(alloc: std.mem.Allocator, template: []const u8, term: []const u8, reading: []const u8) ![]u8 {
    const kana_reading = if (reading.len > 0) reading else term;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var rest = template;
    while (rest.len > 0) {
        if (std.mem.startsWith(u8, rest, "{term}")) {
            try percentEncode(alloc, &out, term);
            rest = rest["{term}".len..];
        } else if (std.mem.startsWith(u8, rest, "{reading}")) {
            try percentEncode(alloc, &out, kana_reading);
            rest = rest["{reading}".len..];
        } else {
            try out.append(alloc, rest[0]);
            rest = rest[1..];
        }
    }
    return out.toOwnedSlice(alloc);
}

fn percentEncode(alloc: std.mem.Allocator, out: *std.ArrayList(u8), text: []const u8) !void {
    const hex = "0123456789ABCDEF";
    for (text) |c| {
        const unreserved = std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '~';
        if (unreserved) {
            try out.append(alloc, c);
        } else {
            try out.appendSlice(alloc, &.{ '%', hex[c >> 4], hex[c & 0xF] });
        }
    }
}

/// Whether `url` is JapanesePod101's, whose "have we got a clip" answer
/// `Job.probe` knows how to read.
pub fn isJpodUrl(url: []const u8) bool {
    return std.mem.indexOf(u8, url, "languagepod101.com/") != null;
}

// ── AnkiConnect ────────────────────────────────────────────────────────

pub const Target = struct {
    deck: []const u8,
    model: []const u8,
    fields: []const FieldMap,
    /// Space-separated, as Anki shows them.
    tags: []const u8 = "",
    allow_duplicates: bool = false,
    /// Unique per card: the media file names are built from it, and
    /// Anki's media folder is flat.
    stamp: []const u8,
};

/// The AnkiConnect `addNote` request for `note`. Every mapped field is
/// sent, empty ones included, so a note type with a required-looking
/// field doesn't silently miss it; `image`/`audio` fields are named in
/// the media entries instead, which is where AnkiConnect fills them.
pub fn buildAddNote(alloc: std.mem.Allocator, note: *const Note, target: Target) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    var s: std.json.Stringify = .{ .writer = &out.writer };

    try s.beginObject();
    try s.objectField("action");
    try s.write("addNote");
    try s.objectField("version");
    try s.write(6);
    try s.objectField("params");
    try s.beginObject();
    try s.objectField("note");
    try s.beginObject();

    try s.objectField("deckName");
    try s.write(target.deck);
    try s.objectField("modelName");
    try s.write(target.model);

    try s.objectField("fields");
    try s.beginObject();
    for (target.fields) |f| {
        if (f.source == .image or f.source == .audio) continue;
        const v = try fieldValue(alloc, note, f.source);
        defer alloc.free(v);
        try s.objectField(f.field);
        try s.write(v);
    }
    try s.endObject();

    try s.objectField("options");
    try s.beginObject();
    try s.objectField("allowDuplicate");
    try s.write(target.allow_duplicates);
    try s.objectField("duplicateScope");
    try s.write("deck");
    try s.endObject();

    try s.objectField("tags");
    try s.beginArray();
    var tags = std.mem.tokenizeAny(u8, target.tags, " \t");
    while (tags.next()) |tag| try s.write(tag);
    try s.endArray();

    if (note.image) |img| {
        if (hasSource(target.fields, .image)) {
            const b64 = try alloc.alloc(u8, std.base64.standard.Encoder.calcSize(img.jpeg.len));
            defer alloc.free(b64);
            _ = std.base64.standard.Encoder.encode(b64, img.jpeg);
            const name = try std.fmt.allocPrint(alloc, "gw-read-{s}.jpg", .{target.stamp});
            defer alloc.free(name);

            try s.objectField("picture");
            try s.beginArray();
            try s.beginObject();
            try s.objectField("data");
            try s.write(b64);
            try s.objectField("filename");
            try s.write(name);
            try s.objectField("fields");
            try writeFieldsFor(&s, target.fields, .image);
            try s.endObject();
            try s.endArray();
        }
    }

    if (note.attachAudio() and hasSource(target.fields, .audio)) {
        const name = try std.fmt.allocPrint(alloc, "gw-read-{s}.mp3", .{target.stamp});
        defer alloc.free(name);
        try s.objectField("audio");
        try s.beginArray();
        try s.beginObject();
        try s.objectField("url");
        try s.write(note.audio_url);
        try s.objectField("filename");
        try s.write(name);
        if (isJpodUrl(note.audio_url)) {
            try s.objectField("skipHash");
            try s.write(jpod_missing_md5);
        }
        try s.objectField("fields");
        try writeFieldsFor(&s, target.fields, .audio);
        try s.endObject();
        try s.endArray();
    }

    try s.endObject(); // note
    try s.endObject(); // params
    try s.endObject();
    return out.toOwnedSlice();
}

fn hasSource(fields: []const FieldMap, source: Source) bool {
    for (fields) |f| {
        if (f.source == source) return true;
    }
    return false;
}

fn writeFieldsFor(s: *std.json.Stringify, fields: []const FieldMap, source: Source) !void {
    try s.beginArray();
    for (fields) |f| {
        if (f.source == source) try s.write(f.field);
    }
    try s.endArray();
}

/// A request with no parameters -- `sync`, `version`.
pub fn buildAction(alloc: std.mem.Allocator, action: []const u8) ![]u8 {
    return std.json.Stringify.valueAlloc(alloc, .{ .action = action, .version = 6 }, .{});
}

/// What an AnkiConnect reply said. `failure` is owned.
pub const Reply = union(enum) {
    /// `result`, when it is an integer (a note id); 0 otherwise.
    ok: i64,
    failure: []u8,
};

/// Reads AnkiConnect's `{"result": ..., "error": ...}` envelope.
pub fn parseReply(alloc: std.mem.Allocator, status: u16, body: []const u8) !Reply {
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, body, .{}) catch {
        return .{ .failure = try std.fmt.allocPrint(alloc, "HTTP {d}: AnkiConnect's reply was not JSON", .{status}) };
    };
    defer parsed.deinit();
    const root = parsed.value;
    if (root != .object) return .{ .failure = try std.fmt.allocPrint(alloc, "HTTP {d}: unexpected reply", .{status}) };
    if (root.object.get("error")) |e| {
        if (e == .string) return .{ .failure = try alloc.dupe(u8, e.string) };
    }
    if (status < 200 or status >= 300) return .{ .failure = try std.fmt.allocPrint(alloc, "HTTP {d}", .{status}) };
    const result = root.object.get("result") orelse return .{ .ok = 0 };
    return .{ .ok = if (result == .integer) result.integer else 0 };
}

// ── Background job ─────────────────────────────────────────────────────

/// One request in flight, the same ownership rules as `ai.Job`: created
/// with everything copied in, run by `io.concurrent`, polled through
/// `done`, destroyed by the UI only after awaiting or cancelling it.
pub const Job = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    kind: Kind,
    url: []u8,
    /// The `addNote` body; empty for a probe.
    body: []u8,
    done: std.atomic.Value(bool) = .init(false),
    result: ?Result = null,

    pub const Kind = union(enum) {
        /// HEAD the audio URL to learn whether the word has a clip.
        probe,
        /// POST `body` to AnkiConnect, then a `sync` when asked.
        add: struct { sync: bool },
    };

    pub const Result = union(enum) {
        audio: AudioState,
        added: struct { note_id: i64, sync_failure: ?[]u8 = null },
        /// Owned: why the note wasn't added.
        failure: []u8,

        pub fn deinit(self: Result, alloc: std.mem.Allocator) void {
            switch (self) {
                .audio => {},
                .added => |a| if (a.sync_failure) |f| alloc.free(f),
                .failure => |f| alloc.free(f),
            }
        }
    };

    pub fn create(alloc: std.mem.Allocator, io: std.Io, kind: Kind, url: []const u8, body: []const u8) !*Job {
        const job = try alloc.create(Job);
        errdefer alloc.destroy(job);
        const url_copy = try alloc.dupe(u8, url);
        errdefer alloc.free(url_copy);
        job.* = .{ .alloc = alloc, .io = io, .kind = kind, .url = url_copy, .body = try alloc.dupe(u8, body) };
        return job;
    }

    pub fn destroy(self: *Job) void {
        const alloc = self.alloc;
        if (self.result) |r| r.deinit(alloc);
        alloc.free(self.url);
        alloc.free(self.body);
        alloc.destroy(self);
    }

    pub fn takeResult(self: *Job) ?Result {
        const r = self.result;
        self.result = null;
        return r;
    }

    pub fn run(self: *Job) void {
        self.result = switch (self.kind) {
            .probe => .{ .audio = self.probe() },
            .add => |a| self.add(a.sync) catch |err| failure: {
                const msg = switch (err) {
                    error.ConnectionRefused => std.fmt.allocPrint(self.alloc, "couldn't reach AnkiConnect at {s} -- is Anki running with the AnkiConnect add-on?", .{self.url}),
                    else => std.fmt.allocPrint(self.alloc, "request to AnkiConnect failed ({t})", .{err}),
                } catch break :failure null;
                break :failure .{ .failure = msg };
            },
        };
        self.done.store(true, .release);
    }

    /// JapanesePod101 redirects a word it has a clip for to the clip, and
    /// answers 200 with its placeholder otherwise -- so a HEAD without
    /// following redirects is the whole question. Anything else (another
    /// source, a network error) stays `unknown` and the clip is attached
    /// anyway.
    ///
    /// Asked over plain HTTP: `assets.languagepod101.com` is an old
    /// Apache whose TLS 1.2 handshake Zig's std TLS client can't complete
    /// (`TlsInitializationFailed`), while its HTTP side gives the same
    /// 301-or-200 answer. Only the status is read, and the clip itself is
    /// still downloaded by Anki from the `https` URL.
    fn probe(self: *Job) AudioState {
        if (!isJpodUrl(self.url)) return .unknown;
        const https = "https://";
        const probe_url = if (std.mem.startsWith(u8, self.url, https))
            std.fmt.allocPrint(self.alloc, "http://{s}", .{self.url[https.len..]}) catch return .unknown
        else
            self.alloc.dupe(u8, self.url) catch return .unknown;
        defer self.alloc.free(probe_url);

        var client: std.http.Client = .{ .allocator = self.alloc, .io = self.io };
        defer client.deinit();
        const res = client.fetch(.{
            .location = .{ .url = probe_url },
            .method = .HEAD,
            .redirect_behavior = .unhandled,
        }) catch return .unknown;
        return switch (res.status.class()) {
            .redirect => .available,
            .success => .missing,
            else => .unknown,
        };
    }

    fn add(self: *Job, sync: bool) !Result {
        var client: std.http.Client = .{ .allocator = self.alloc, .io = self.io };
        defer client.deinit();

        const reply = try self.post(&client, self.body);
        const note_id = switch (reply) {
            .failure => |f| return .{ .failure = f },
            .ok => |id| id,
        };
        if (!sync) return .{ .added = .{ .note_id = note_id } };

        const sync_body = try buildAction(self.alloc, "sync");
        defer self.alloc.free(sync_body);
        const sync_reply = self.post(&client, sync_body) catch |err|
            return .{ .added = .{ .note_id = note_id, .sync_failure = try std.fmt.allocPrint(self.alloc, "{t}", .{err}) } };
        return .{ .added = .{ .note_id = note_id, .sync_failure = switch (sync_reply) {
            .failure => |f| f,
            .ok => null,
        } } };
    }

    fn post(self: *Job, client: *std.http.Client, body: []const u8) !Reply {
        var response: std.Io.Writer.Allocating = .init(self.alloc);
        defer response.deinit();
        const res = try client.fetch(.{
            .location = .{ .url = self.url },
            .method = .POST,
            .payload = body,
            .headers = .{ .content_type = .{ .override = "application/json" } },
            .response_writer = &response.writer,
        });
        return parseReply(self.alloc, @intFromEnum(res.status), response.written());
    }
};
