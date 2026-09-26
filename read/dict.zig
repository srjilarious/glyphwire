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
//! directory a Jitendex download was extracted to once, by hand.
//! Decompressing a several-hundred-MB dictionary on every book opened
//! would be real time to pay more than once.
//!
//! **Term data lives in a SQLite file next to the term banks, not in
//! memory.** The first time a dictionary directory is opened, every
//! `term_bank_*.json` is parsed once and its rows inserted into
//! `<dictionary>/index.sqlite3`, indexed by `term` and `reading`; every load after that
//! just opens the existing file and queries it. This replaced an
//! in-memory `StringHashMap` of every entry (see git history for that
//! version): the JSON parse itself was slow enough on a real Jitendex
//! download to be noticeable every single time gw-read opened a book,
//! since nothing about the parse was ever kept between runs -- an
//! on-disk index means that cost is paid once, not once per session.
//! SQLite is vendored as the public-domain amalgamation under
//! `read/libs/sqlite/` (see `build.zig`'s `read_support_mod` wiring) and
//! wrapped minimally in `sqlite.zig`; a heavier embedded database was
//! briefly considered and set aside as far more machinery than "look up
//! a term by exact string" needs -- see `docs/decisions.md`.
//!
//! Lookup does not tokenize the page's text up front. Japanese has no
//! spaces, so -- the same trick Yomitan itself uses -- a click just picks
//! a starting byte offset, and `lookup` tries every prefix from there (up
//! to `max_scan_codepoints`), in every spelling `kana.zig` normalizes it
//! to, deinflected through a small rule table. Every candidate is one
//! indexed `SELECT ... WHERE term = ? OR reading = ?`, cached per call.
//! Like Yomitan, it collects every hit at every length and ranks them
//! afterward (longest source first) rather than stopping at the longest
//! length that matched anything -- see `lookup` and `rankBefore`.
//!
//! **Parsing keeps the JSON tree off the entries it extracts.**
//! `std.json.Value` is a generic tree -- a hashmap per object, an
//! `ArrayList` per array, a tagged union per scalar -- and for a
//! multi-hundred-MB term bank that tree can outweigh the source JSON
//! several times over. `insertTermBank` parses each file into its own
//! short-lived scratch arena and frees it before the next file, so peak
//! memory while building the index is bounded by one term bank file's
//! tree, not by every file's tree held at once (an earlier version that
//! kept the whole tree alive in a long-lived arena reliably ran a real
//! machine out of memory before the book it was opened for ever got to
//! render a page).
//!
//! **Building the index is one file at a time, not one call.** A real
//! Jitendex download is tens of thousands of rows across dozens of term
//! banks -- long enough that `ui.zig` doesn't want to block the reader
//! on it. `Builder` (via `openOrBeginBuild`) exposes the same work
//! `loadFromDir` does as `step`-once-per-file plus `finish`, so the run
//! loop can call `step` once a tick and show a "file N of M" panel in
//! the meantime; `loadFromDir` itself just drives a `Builder` to
//! completion in a loop for callers that don't care about progress.
//!
//! Everything here except `loadFromDir`/`Builder` and the `sqlite` calls
//! they make is pure -- JSON and text in, plain Zig values out -- so
//! `tests/read_tests.zig` can pin the parse and the lookup against an
//! in-memory (`:memory:`) database without a dictionary directory on
//! disk.
//!
//! **Deinflection chains, up to `max_deinflect_depth` rule
//! applications.** `lookup` follows every chain from each candidate
//! substring (0 = a direct dictionary-form hit, 1 = one rule, 2 = two
//! rules chained, ...); when one entry is reachable several ways the
//! shortest chain is the one kept, and between entries fewer rules ranks
//! higher -- the "simplest explanation wins" preference. A rule's
//! `rules_out` can be empty (`&.{}`), meaning the form it produces is
//! never itself accepted as a final match -- only a dictionary row's
//! `rules` column can end a chain, so an empty `rules_out` forces at
//! least one more rule application (see `DeinflectRule`'s doc comment).
//! This is how a pre-collapse form like "-nakatta" is represented: it's
//! not a dictionary headword in its own right (it first collapses to the
//! plain "-nai" form, which the table's plain negative rules recognize),
//! so a chain that stops there is rejected the same way a wrong-tagged
//! direct hit was rejected before. Causative and passive/potential look
//! like they'd need the same treatment -- they're productive derivations
//! too -- but they aren't: stripping either always lands directly on the
//! plain dictionary form (食べさせる -> 食べる), so their `rules_out`
//! names the real headword's own class (`v1`/`v5`) like any other
//! terminal rule.
//!
//! The rule table covers plain negative/past/te-form/negative-past for
//! godan and ichidan verbs and i-adjectives; causative; passive/potential;
//! polite non-past/past/negative (-masu/-mashita/-masen); progressive
//! (-teiru/-teru/-deiru/-deru, chaining down onto the existing te-form
//! rules); volitional and polite volitional (-mashou); desiderative
//! (-tai); conditional (-tara) and provisional (-eba); imperative; and the
//! three irregular classes the index tags but no regular rule can reach --
//! **vs** (する and the kanji+する headwords), **vk** (来る, in both
//! spellings) and **vz** (ずる verbs) -- plus 行く, whose te-form and past
//! are irregular.
//!
//! Why the irregular classes matter out of proportion to their share of
//! the dictionary: every rule that produces only `v1`/`v5`/`adj-i` leaves
//! those rows unreachable *at any depth*, so before they were added a
//! click on した landed on 下 "below" and しない on 市内 "in the city" --
//! confident wrong answers rather than misses. する and 来る are also
//! about the most frequent verbs in the language.
//!
//! **Still not done:** the copula and na-adjectives (だった/じゃない/
//! でした), adjective derivations as rules rather than as lexicalized
//! entries (-さ/-く/-そう/-すぎる), te-form compounds (-ちゃう/-てしまう/
//! -ておく/-てくる), classical and colloquial negatives (-ぬ/-ず/-ん),
//! polite negative-past (-masendeshita), a dedicated godan す-row
//! causative row (causative "させる" is wired to its ichidan and する
//! targets, so 話す's causative 話させる doesn't resolve -- see the
//! causative rows below), godan potential -える where the dictionary
//! hasn't lexicalized it (読める and 話せる are their own `v1` entries,
//! 書ける is not), keigo, Kansai-ben, and anything needing more than
//! `max_deinflect_depth` chained rules. The phased plan for the rest,
//! including the structural fix the remaining forms want underneath them
//! (condition sets in place of `rules_out`), is in tech-notes:
//! `plans/glyphwire/2026-09-26-gw-read-yomitan-parity.md`.
//!
//! **Frequency data, when there is any, is what makes the ranking
//! usable.** Without it `rankBefore` puts fewer deinflection rules ahead of
//! more, so a depth-0 homograph noun outranks a depth-1 verb whenever both
//! exist: した showed 下 "below" first with する fourth, and しよう buried
//! する thirteenth under 私用/使用/仕様/至要. Reachable, and useless.
//!
//! So `term_meta_bank_*.json` -- Yomitan's frequency banks -- are indexed
//! into a `term_meta` table and `lookup` ranks on frequency *above*
//! deinflection depth. The data comes from a **separate dictionary
//! directory** (`config.frequency_dictionary`), because the two really are
//! separate downloads: a term dictionary like Jitendex ships no frequency
//! data at all, and the lists that do (JPDB, Innocent Corpus, BCCWJ) ship
//! no definitions. Mechanically a frequency list is just another dictionary
//! directory whose banks happen to be meta banks, so `Builder` indexes
//! either kind -- it dispatches per file name -- and `ui.zig` holds two
//! `Dict`s. With no frequency dictionary configured nothing has a
//! frequency, the axis is inert, and the order is what it always was.
//!
//! A frequency number carries no direction of its own: a ranked list counts
//! up from 1 and a corpus tally counts occurrences, and the file format does
//! not say which it is. `config.FrequencyOrder` is the reader's answer, the
//! same per-dictionary setting Yomitan makes it, because guessing wrong
//! silently inverts every result.
//!
//! Still on the list: Yomitan groups hits into one entry per headword and
//! shows them stacked, where this panel shows one at a time behind `]`/`[`.
//! Every ranking improvement is worth less than it should be until that
//! changes.

const std = @import("std");
const sqlite = @import("sqlite.zig");
const kana = @import("kana.zig");
const config = @import("config.zig");

/// One dictionary row, always fully owned by whatever allocator produced
/// it (`lookup`'s caller-supplied `alloc`, or a test's) -- unlike the
/// in-memory version this replaced, nothing here points into a
/// long-lived arena, since there is no long-lived in-memory copy of the
/// dictionary any more. `rules` is Yomitan's space-separated deinflection
/// tags (`v1`, `v5`, `vk`, `vs`, `adj-i`, ...) -- empty for anything that
/// doesn't conjugate. `glossary` is one flattened string per sense.
pub const Entry = struct {
    /// The row's id in `entries` -- identifies one entry across the
    /// several routes a lookup can reach it by.
    id: i64 = 0,
    term: []const u8 = "",
    reading: []const u8 = "",
    rules: []const u8 = "",
    glossary: []const []const u8 = &.{},
    sequence: i64 = 0,
    /// The dictionary's own ranking score for the row (field 4 of a term
    /// bank row); higher ranks first between otherwise equal hits.
    score: i64 = 0,

    pub fn deinit(self: Entry, alloc: std.mem.Allocator) void {
        alloc.free(self.term);
        alloc.free(self.reading);
        alloc.free(self.rules);
        for (self.glossary) |g| alloc.free(g);
        alloc.free(self.glossary);
    }
};

/// Frees every entry in `entries` and the slice itself -- the whole
/// result of one `queryTerm`, not a sub-slice of one (freeing part of a
/// slice that wasn't its own allocation is undefined behavior).
pub fn freeEntries(alloc: std.mem.Allocator, entries: []const Entry) void {
    for (entries) |e| e.deinit(alloc);
    alloc.free(entries);
}

/// An open dictionary: a SQLite connection onto `<dir>/index.sqlite3`
/// (built on first open -- see `loadFromDir`) plus the one prepared
/// statement `lookup` reuses for every candidate substring.
pub const Dict = struct {
    db: sqlite.Db,
    lookup_stmt: sqlite.Stmt,
    /// Queries `term_meta` -- the frequency table. Always prepared, since
    /// the table always exists as of schema 4; it simply finds nothing in a
    /// dictionary that shipped no `term_meta_bank_*.json`.
    freq_stmt: sqlite.Stmt,
    /// Backs `title` only -- everything else this module hands out is
    /// owned by whichever allocator the caller passed in.
    title_arena: std.heap.ArenaAllocator,
    /// `index.json`'s title, when the dictionary had one. Empty otherwise.
    title: []const u8 = "",

    pub fn deinit(self: *Dict) void {
        self.lookup_stmt.finalize();
        self.freq_stmt.finalize();
        self.db.close();
        self.title_arena.deinit();
    }
};

/// One headword's frequency, as a frequency dictionary gave it.
///
/// `value` is the raw number and carries no direction of its own: whether
/// smaller means "more common" is the frequency list's convention, not a
/// property of the number, which is why `lookup` takes a
/// `config.FrequencyOrder` rather than normalising here. `display` is the
/// list's own rendering of it when it supplied one (Yomitan's
/// `displayValue`) and empty otherwise.
pub const Frequency = struct {
    value: i64,
    display: []const u8 = "",
};

/// The frequency `freq` records for the headword `term`/`reading`, or null
/// when it has none.
///
/// Preference order among the rows that match, which is what makes a
/// frequency list usable against a dictionary that spells things
/// differently:
///
/// 1. A row filed under `term` beats one filed under `reading` -- Jitendex
///    files 面白い under the kanji, and a frequency list that has both
///    should be read as agreeing with the headword, not the reading.
/// 2. A row naming a *reading* beats one that names none, but only when it
///    names **this** reading; a row for another reading of the same kanji
///    (今日/きょう vs 今日/こんにち) is not about this headword at all and
///    is skipped.
/// 3. Between rows that are otherwise equal, the more common one wins under
///    `order`. Lists do sometimes carry several numbers for one word.
///
/// **Known cost of the reading fallback.** A rare kanji spelling that the
/// frequency list has never heard of picks up its *reading's* number, so
/// 為る -- the archaic spelling of する -- ranks as commonly as する and the
/// two appear back to back. Not a wrong answer (it is the same word twice),
/// and the fallback is what lets a kana-keyed list meet a kanji-keyed
/// dictionary at all, which matters more. Yomitan avoids it from the other
/// direction: it looks frequencies up by term only, and reaches the kana
/// spelling by *grouping* headwords that share a reading into one entry
/// first. Grouping would subsume this and is the remaining Yomitan gap; see
/// the module doc comment.
pub fn frequencyFor(
    freq: *Dict,
    order: config.FrequencyOrder,
    term: []const u8,
    reading: []const u8,
) ?Frequency {
    freq.freq_stmt.reset();
    freq.freq_stmt.bindText(1, term) catch return null;
    freq.freq_stmt.bindText(2, reading) catch return null;

    var best: ?Frequency = null;
    var best_rank: u8 = 0;
    while (freq.freq_stmt.step() catch false) {
        const row_term = freq.freq_stmt.columnText(0);
        const row_reading = freq.freq_stmt.columnText(1);

        // A row for some *other* reading of this term says nothing here.
        if (row_reading.len != 0 and !std.mem.eql(u8, row_reading, reading)) continue;

        const on_term = std.mem.eql(u8, row_term, term);
        const has_reading = row_reading.len != 0;
        // 3 = filed under the term and naming this reading, 0 = filed under
        // the reading with no reading of its own.
        const rank: u8 = (if (on_term) @as(u8, 2) else 0) + (if (has_reading) @as(u8, 1) else 0);

        const value = freq.freq_stmt.columnInt64(2);
        const display = freq.freq_stmt.columnText(3);
        const better = if (best) |b|
            rank > best_rank or (rank == best_rank and order.moreCommon(value, b.value))
        else
            true;
        if (!better) continue;
        best_rank = rank;
        // `columnText` points into SQLite's own row buffer, which the next
        // `step` invalidates -- so the winner's display text has to be
        // copied out. It is bounded by the column and never long (a
        // `displayValue` like "12㋕"), so a fixed buffer beats threading an
        // allocator through every caller of this.
        best = .{ .value = value, .display = displayCopy(display) };
    }
    return best;
}

/// Scratch for the one `display` string `frequencyFor` returns. Overwritten
/// by the next call, which is safe because `lookup` consumes each result
/// before asking for the next one.
var display_buf: [64]u8 = undefined;

fn displayCopy(text: []const u8) []const u8 {
    const n = @min(text.len, display_buf.len);
    @memcpy(display_buf[0..n], text[0..n]);
    return display_buf[0..n];
}

/// True when `dict` actually carries frequency data -- `ui.zig` uses it to
/// warn that a configured `frequency_dictionary` indexed to nothing, the
/// same way `isEmpty` reports a term dictionary that did.
pub fn hasFrequency(dict: *Dict) bool {
    var stmt = dict.db.prepare("SELECT 1 FROM term_meta LIMIT 1") catch return false;
    defer stmt.finalize();
    return stmt.step() catch false;
}

/// One deinflection step: strip `kana_in` off the end of the clicked
/// text and append `kana_out` to get a candidate one layer less
/// conjugated. `rules_out` restricts which of the *candidate*'s own
/// `rules` tags make the guess acceptable when the candidate is queried
/// directly against the dictionary -- without it, stripping "ない" off
/// any text ending that way would "deinflect" plenty of unrelated words
/// that merely happen to end in it.
///
/// An empty `rules_out` (`&.{}`) means the form this rule produces is
/// never itself a valid final match -- it's an intermediate derivation
/// (a pre-collapse "-nakatta" negative-past, which first has to become
/// plain "-nai") that isn't a dictionary headword itself, so the search
/// must apply at least one more rule before it can succeed.
/// `hasAnyRule(rules, &.{})` always returns `false`, so this falls out
/// of the existing filter with no special casing -- see
/// `Search.collect`. Causative and passive/potential, despite also
/// being "productive derivations", do *not* use this -- they collapse
/// straight to the real headword, so they carry that headword's own
/// `v1`/`v5` tag instead (see the rule table below).
pub const DeinflectRule = struct {
    kana_in: []const u8,
    kana_out: []const u8,
    /// The classes a row must carry for this rule's output to be accepted
    /// as a final match. Three cases, and the third is the newest:
    ///
    /// - `&.{"v1"}`, `&.{ "v1", "v5" }`, ... -- the row's `rules` column
    ///   must name one of these. The ordinary case.
    /// - `&.{}` -- never accepted, so the rule is a pure intermediate
    ///   derivation and the search must apply at least one more rule.
    /// - `null` -- **accept any row, including one with no `rules` at
    ///   all.** The copula and na-adjective rows need this: 綺麗だった
    ///   reduces to 綺麗, and a na-adjective carries an *empty* `rules`
    ///   column in a Jitendex build, so there is no tag for a filter to
    ///   bite on. It is the most permissive setting in the table -- な and
    ///   に in particular will strip a kana off anything -- and it is used
    ///   only where the target genuinely has no verb class.
    rules_out: ?[]const []const u8,
    /// Shown next to a deinflected match so it doesn't read as a typo of
    /// the dictionary form. Joined with other reasons along the same
    /// chain into `Hit.reason` -- see that field's doc comment for the
    /// join order.
    reason: []const u8,
};

/// Deliberately partial -- see the module doc comment. One triple
/// (negative, past, te-form) per godan sound group, three for ichidan,
/// three for i-adjectives.
pub const deinflect_rules = [_]DeinflectRule{
    .{ .kana_in = "わない", .kana_out = "う", .rules_out = &.{"v5"}, .reason = "negative" },
    .{ .kana_in = "った", .kana_out = "う", .rules_out = &.{"v5"}, .reason = "past" },
    .{ .kana_in = "って", .kana_out = "う", .rules_out = &.{"v5"}, .reason = "te-form" },

    .{ .kana_in = "かない", .kana_out = "く", .rules_out = &.{"v5"}, .reason = "negative" },
    .{ .kana_in = "いた", .kana_out = "く", .rules_out = &.{"v5"}, .reason = "past" },
    .{ .kana_in = "いて", .kana_out = "く", .rules_out = &.{"v5"}, .reason = "te-form" },

    .{ .kana_in = "がない", .kana_out = "ぐ", .rules_out = &.{"v5"}, .reason = "negative" },
    .{ .kana_in = "いだ", .kana_out = "ぐ", .rules_out = &.{"v5"}, .reason = "past" },
    .{ .kana_in = "いで", .kana_out = "ぐ", .rules_out = &.{"v5"}, .reason = "te-form" },

    .{ .kana_in = "さない", .kana_out = "す", .rules_out = &.{"v5"}, .reason = "negative" },
    .{ .kana_in = "した", .kana_out = "す", .rules_out = &.{"v5"}, .reason = "past" },
    .{ .kana_in = "して", .kana_out = "す", .rules_out = &.{"v5"}, .reason = "te-form" },

    .{ .kana_in = "たない", .kana_out = "つ", .rules_out = &.{"v5"}, .reason = "negative" },
    .{ .kana_in = "った", .kana_out = "つ", .rules_out = &.{"v5"}, .reason = "past" },
    .{ .kana_in = "って", .kana_out = "つ", .rules_out = &.{"v5"}, .reason = "te-form" },

    .{ .kana_in = "なない", .kana_out = "ぬ", .rules_out = &.{"v5"}, .reason = "negative" },
    .{ .kana_in = "んだ", .kana_out = "ぬ", .rules_out = &.{"v5"}, .reason = "past" },
    .{ .kana_in = "んで", .kana_out = "ぬ", .rules_out = &.{"v5"}, .reason = "te-form" },

    .{ .kana_in = "ばない", .kana_out = "ぶ", .rules_out = &.{"v5"}, .reason = "negative" },
    .{ .kana_in = "んだ", .kana_out = "ぶ", .rules_out = &.{"v5"}, .reason = "past" },
    .{ .kana_in = "んで", .kana_out = "ぶ", .rules_out = &.{"v5"}, .reason = "te-form" },

    .{ .kana_in = "まない", .kana_out = "む", .rules_out = &.{"v5"}, .reason = "negative" },
    .{ .kana_in = "んだ", .kana_out = "む", .rules_out = &.{"v5"}, .reason = "past" },
    .{ .kana_in = "んで", .kana_out = "む", .rules_out = &.{"v5"}, .reason = "te-form" },

    // Godan verbs ending in -る (e.g. 分かる) -- distinct from ichidan
    // only by which dictionary entry it turns out to match, which is
    // exactly what `rules_out` disambiguates at lookup time.
    .{ .kana_in = "らない", .kana_out = "る", .rules_out = &.{"v5"}, .reason = "negative" },
    .{ .kana_in = "った", .kana_out = "る", .rules_out = &.{"v5"}, .reason = "past" },
    .{ .kana_in = "って", .kana_out = "る", .rules_out = &.{"v5"}, .reason = "te-form" },

    // Ichidan (v1): -る drops cleanly, so one variant covers every verb.
    .{ .kana_in = "ない", .kana_out = "る", .rules_out = &.{"v1"}, .reason = "negative" },
    .{ .kana_in = "た", .kana_out = "る", .rules_out = &.{"v1"}, .reason = "past" },
    .{ .kana_in = "て", .kana_out = "る", .rules_out = &.{"v1"}, .reason = "te-form" },

    // i-adjectives.
    .{ .kana_in = "くない", .kana_out = "い", .rules_out = &.{"adj-i"}, .reason = "negative" },
    .{ .kana_in = "かった", .kana_out = "い", .rules_out = &.{"adj-i"}, .reason = "past" },
    .{ .kana_in = "くて", .kana_out = "い", .rules_out = &.{"adj-i"}, .reason = "te-form" },

    // Negative-past: collapses to the plain negative ("ない") one layer
    // in, so it's non-terminal -- the chain finishes via whichever plain
    // negative rule above matches next (godan/ichidan/adjective all end
    // in exactly "ない" regardless of what precedes it, so one row here
    // covers every conjugation class).
    //
    // **This row never actually decides anything, and the reason is worth
    // understanding.** "ない" is itself an i-adjective, so "なかった" is
    // just its adjective past -- and the "かった" -> "い" row directly
    // above produces exactly the same string for every input this one
    // does (X なかった -> X な + い -> X ない). Being earlier in the table,
    // it always wins the tie in `Search.offer`, so a negative-past chain
    // reports "negative, past" rather than "negative, negative past".
    // That decomposition is the more honest one, which is why this is
    // documented rather than fixed by reordering. The row is kept because
    // it states the intent, but the live example of a non-terminal rule
    // is the progressive block further down, not this one.
    .{ .kana_in = "なかった", .kana_out = "ない", .rules_out = &.{}, .reason = "negative past" },

    // Causative. Terminal, not non-terminal: stripping it always lands
    // directly on the plain dictionary form (食べさせる -> 食べる), the
    // same "conjunctive form directly corresponds to a headword" status
    // the polite/volitional rows below have -- it only *looks* like it
    // should chain further because a causative verb is so often also
    // negated or past-tensed on the surface (食べさせなかった), but that
    // outer layer is peeled by the *plain* negative/past/te-form rules
    // above first, landing on the bare causative form ("食べさせる") as
    // their own intermediate step, which this rule then finishes in the
    // next round of the search. (An earlier version of this table marked
    // these `rules_out = &.{}` on the reasoning "causative is never a
    // headword" -- true, but irrelevant: `rules_out` validates the STEM
    // *after* stripping the causative suffix, which is always the real
    // headword. That version could never actually resolve a causative
    // chain; caught by hand-tracing `食べさせない`/`食べさせた` against it.)
    .{ .kana_in = "させる", .kana_out = "る", .rules_out = &.{"v1"}, .reason = "causative" },
    .{ .kana_in = "わせる", .kana_out = "う", .rules_out = &.{"v5"}, .reason = "causative" },
    .{ .kana_in = "かせる", .kana_out = "く", .rules_out = &.{"v5"}, .reason = "causative" },
    .{ .kana_in = "がせる", .kana_out = "ぐ", .rules_out = &.{"v5"}, .reason = "causative" },
    .{ .kana_in = "たせる", .kana_out = "つ", .rules_out = &.{"v5"}, .reason = "causative" },
    .{ .kana_in = "なせる", .kana_out = "ぬ", .rules_out = &.{"v5"}, .reason = "causative" },
    .{ .kana_in = "ばせる", .kana_out = "ぶ", .rules_out = &.{"v5"}, .reason = "causative" },
    .{ .kana_in = "ませる", .kana_out = "む", .rules_out = &.{"v5"}, .reason = "causative" },
    .{ .kana_in = "らせる", .kana_out = "る", .rules_out = &.{"v5"}, .reason = "causative" },

    // Passive/potential. Terminal, same reasoning as causative above.
    // "られる" is genuinely ambiguous between ichidan and godan-る (both
    // conjugate their passive/potential the same way), so that one row
    // accepts either tag rather than picking one.
    .{ .kana_in = "られる", .kana_out = "る", .rules_out = &.{ "v1", "v5" }, .reason = "passive/potential" },
    .{ .kana_in = "われる", .kana_out = "う", .rules_out = &.{"v5"}, .reason = "passive/potential" },
    .{ .kana_in = "かれる", .kana_out = "く", .rules_out = &.{"v5"}, .reason = "passive/potential" },
    .{ .kana_in = "がれる", .kana_out = "ぐ", .rules_out = &.{"v5"}, .reason = "passive/potential" },
    .{ .kana_in = "される", .kana_out = "す", .rules_out = &.{"v5"}, .reason = "passive/potential" },
    .{ .kana_in = "たれる", .kana_out = "つ", .rules_out = &.{"v5"}, .reason = "passive/potential" },
    .{ .kana_in = "なれる", .kana_out = "ぬ", .rules_out = &.{"v5"}, .reason = "passive/potential" },
    .{ .kana_in = "ばれる", .kana_out = "ぶ", .rules_out = &.{"v5"}, .reason = "passive/potential" },
    .{ .kana_in = "まれる", .kana_out = "む", .rules_out = &.{"v5"}, .reason = "passive/potential" },

    // Polite non-past ("-masu"). Terminal -- a plain conjunctive/i-stem
    // form directly corresponds to a real dictionary headword, the same
    // as the plain negative/past/te-form rows above.
    .{ .kana_in = "ます", .kana_out = "る", .rules_out = &.{"v1"}, .reason = "polite" },
    .{ .kana_in = "います", .kana_out = "う", .rules_out = &.{"v5"}, .reason = "polite" },
    .{ .kana_in = "きます", .kana_out = "く", .rules_out = &.{"v5"}, .reason = "polite" },
    .{ .kana_in = "ぎます", .kana_out = "ぐ", .rules_out = &.{"v5"}, .reason = "polite" },
    .{ .kana_in = "します", .kana_out = "す", .rules_out = &.{"v5"}, .reason = "polite" },
    .{ .kana_in = "ちます", .kana_out = "つ", .rules_out = &.{"v5"}, .reason = "polite" },
    .{ .kana_in = "にます", .kana_out = "ぬ", .rules_out = &.{"v5"}, .reason = "polite" },
    .{ .kana_in = "びます", .kana_out = "ぶ", .rules_out = &.{"v5"}, .reason = "polite" },
    .{ .kana_in = "みます", .kana_out = "む", .rules_out = &.{"v5"}, .reason = "polite" },
    .{ .kana_in = "ります", .kana_out = "る", .rules_out = &.{"v5"}, .reason = "polite" },

    // Polite past ("-mashita"). Same i-stem endings as -masu above, also
    // terminal.
    .{ .kana_in = "ました", .kana_out = "る", .rules_out = &.{"v1"}, .reason = "polite past" },
    .{ .kana_in = "いました", .kana_out = "う", .rules_out = &.{"v5"}, .reason = "polite past" },
    .{ .kana_in = "きました", .kana_out = "く", .rules_out = &.{"v5"}, .reason = "polite past" },
    .{ .kana_in = "ぎました", .kana_out = "ぐ", .rules_out = &.{"v5"}, .reason = "polite past" },
    .{ .kana_in = "しました", .kana_out = "す", .rules_out = &.{"v5"}, .reason = "polite past" },
    .{ .kana_in = "ちました", .kana_out = "つ", .rules_out = &.{"v5"}, .reason = "polite past" },
    .{ .kana_in = "にました", .kana_out = "ぬ", .rules_out = &.{"v5"}, .reason = "polite past" },
    .{ .kana_in = "びました", .kana_out = "ぶ", .rules_out = &.{"v5"}, .reason = "polite past" },
    .{ .kana_in = "みました", .kana_out = "む", .rules_out = &.{"v5"}, .reason = "polite past" },
    .{ .kana_in = "りました", .kana_out = "る", .rules_out = &.{"v5"}, .reason = "polite past" },

    // Polite negative ("-masen"). Same i-stem endings again, terminal.
    // "-masendeshita" (polite negative past) is not covered -- see the
    // module doc comment.
    .{ .kana_in = "ません", .kana_out = "る", .rules_out = &.{"v1"}, .reason = "polite negative" },
    .{ .kana_in = "いません", .kana_out = "う", .rules_out = &.{"v5"}, .reason = "polite negative" },
    .{ .kana_in = "きません", .kana_out = "く", .rules_out = &.{"v5"}, .reason = "polite negative" },
    .{ .kana_in = "ぎません", .kana_out = "ぐ", .rules_out = &.{"v5"}, .reason = "polite negative" },
    .{ .kana_in = "しません", .kana_out = "す", .rules_out = &.{"v5"}, .reason = "polite negative" },
    .{ .kana_in = "ちません", .kana_out = "つ", .rules_out = &.{"v5"}, .reason = "polite negative" },
    .{ .kana_in = "にません", .kana_out = "ぬ", .rules_out = &.{"v5"}, .reason = "polite negative" },
    .{ .kana_in = "びません", .kana_out = "ぶ", .rules_out = &.{"v5"}, .reason = "polite negative" },
    .{ .kana_in = "みません", .kana_out = "む", .rules_out = &.{"v5"}, .reason = "polite negative" },
    .{ .kana_in = "りません", .kana_out = "る", .rules_out = &.{"v5"}, .reason = "polite negative" },

    // Polite negative past ("-masendeshita"), non-terminal onto the polite
    // negative just above: 食べませんでした -> 食べません -> 食べる.
    //
    // **Must stay ahead of the copula rows.** "でした" -> "" reduces
    // 食べませんでした to 食べません too, at the same depth, and on a tie
    // `Search.offer` keeps whichever route was offered first -- which is
    // whichever rule comes first in this table. Below the copula block, the
    // chain reads "polite negative, polite copula past" instead of "polite
    // negative, polite negative past".
    .{ .kana_in = "ませんでした", .kana_out = "ません", .rules_out = &.{}, .reason = "polite negative past" },

    // Progressive ("-teiru"/"-teru" and the "-deiru"/"-deru" variant after
    // a te-form that ends in で, e.g. 死んでいる). These strip back down
    // to the plain te-form, not to a headword directly -- the existing
    // te-form rules above take it the rest of the way (e.g. 食べている ->
    // 食べて -> 食べる, two chained steps), so this is non-terminal.
    .{ .kana_in = "ている", .kana_out = "て", .rules_out = &.{}, .reason = "progressive" },
    .{ .kana_in = "てる", .kana_out = "て", .rules_out = &.{}, .reason = "progressive" },
    .{ .kana_in = "でいる", .kana_out = "で", .rules_out = &.{}, .reason = "progressive" },
    .{ .kana_in = "でる", .kana_out = "で", .rules_out = &.{}, .reason = "progressive" },

    // Volitional ("-you"/"let's"). Terminal, like the plain
    // negative/past rows -- a real conjugated form of the headword
    // itself, not a further derivation.
    .{ .kana_in = "よう", .kana_out = "る", .rules_out = &.{"v1"}, .reason = "volitional" },
    .{ .kana_in = "おう", .kana_out = "う", .rules_out = &.{"v5"}, .reason = "volitional" },
    .{ .kana_in = "こう", .kana_out = "く", .rules_out = &.{"v5"}, .reason = "volitional" },
    .{ .kana_in = "ごう", .kana_out = "ぐ", .rules_out = &.{"v5"}, .reason = "volitional" },
    .{ .kana_in = "そう", .kana_out = "す", .rules_out = &.{"v5"}, .reason = "volitional" },
    .{ .kana_in = "とう", .kana_out = "つ", .rules_out = &.{"v5"}, .reason = "volitional" },
    .{ .kana_in = "のう", .kana_out = "ぬ", .rules_out = &.{"v5"}, .reason = "volitional" },
    .{ .kana_in = "ぼう", .kana_out = "ぶ", .rules_out = &.{"v5"}, .reason = "volitional" },
    .{ .kana_in = "もう", .kana_out = "む", .rules_out = &.{"v5"}, .reason = "volitional" },
    .{ .kana_in = "ろう", .kana_out = "る", .rules_out = &.{"v5"}, .reason = "volitional" },

    // Desiderative ("-tai", "wants to"). Terminal, from the i-stem like
    // the polite rows above. "-tai" is itself an i-adjective, so its own
    // negative/past come for free through the i-adjective rows above:
    // 食べたくない -> 食べたい -> 食べる, two steps. The irregular verbs'
    // desiderative rows (したい, 来たい, ...) live in their own blocks at
    // the end of this table, not here.
    .{ .kana_in = "たい", .kana_out = "る", .rules_out = &.{"v1"}, .reason = "desiderative" },
    .{ .kana_in = "いたい", .kana_out = "う", .rules_out = &.{"v5"}, .reason = "desiderative" },
    .{ .kana_in = "きたい", .kana_out = "く", .rules_out = &.{"v5"}, .reason = "desiderative" },
    .{ .kana_in = "ぎたい", .kana_out = "ぐ", .rules_out = &.{"v5"}, .reason = "desiderative" },
    .{ .kana_in = "したい", .kana_out = "す", .rules_out = &.{"v5"}, .reason = "desiderative" },
    .{ .kana_in = "ちたい", .kana_out = "つ", .rules_out = &.{"v5"}, .reason = "desiderative" },
    .{ .kana_in = "にたい", .kana_out = "ぬ", .rules_out = &.{"v5"}, .reason = "desiderative" },
    .{ .kana_in = "びたい", .kana_out = "ぶ", .rules_out = &.{"v5"}, .reason = "desiderative" },
    .{ .kana_in = "みたい", .kana_out = "む", .rules_out = &.{"v5"}, .reason = "desiderative" },
    .{ .kana_in = "りたい", .kana_out = "る", .rules_out = &.{"v5"}, .reason = "desiderative" },

    // Conditional ("-tara"). Two rows, not ten: "-tara" *is* the past
    // form plus ら, so it collapses onto the past and the past rules
    // above finish the job -- non-terminal for the same reason the
    // progressive rows are. 食べたら -> 食べた -> 食べる, 読んだら ->
    // 読んだ -> 読む, 高かったら -> 高かった -> 高い, したら -> した ->
    // する. Modelling it this way isn't a shortcut, it's the morphology.
    .{ .kana_in = "たら", .kana_out = "た", .rules_out = &.{}, .reason = "conditional" },
    .{ .kana_in = "だら", .kana_out = "だ", .rules_out = &.{}, .reason = "conditional" },

    // Provisional ("-eba"). Terminal. "れば" is ambiguous between
    // ichidan (食べれば) and godan -る (分かれば) exactly as "られる" is,
    // so it accepts either tag.
    //
    // There is deliberately no "なければ" row: "ければ" already strips
    // 食べなければ to 食べない, which the negative rows then reduce to
    // 食べる, and the chain reads "negative, provisional" -- which is
    // what 食べなければ is.
    .{ .kana_in = "えば", .kana_out = "う", .rules_out = &.{"v5"}, .reason = "provisional" },
    .{ .kana_in = "けば", .kana_out = "く", .rules_out = &.{"v5"}, .reason = "provisional" },
    .{ .kana_in = "げば", .kana_out = "ぐ", .rules_out = &.{"v5"}, .reason = "provisional" },
    .{ .kana_in = "せば", .kana_out = "す", .rules_out = &.{"v5"}, .reason = "provisional" },
    .{ .kana_in = "てば", .kana_out = "つ", .rules_out = &.{"v5"}, .reason = "provisional" },
    .{ .kana_in = "ねば", .kana_out = "ぬ", .rules_out = &.{"v5"}, .reason = "provisional" },
    .{ .kana_in = "べば", .kana_out = "ぶ", .rules_out = &.{"v5"}, .reason = "provisional" },
    .{ .kana_in = "めば", .kana_out = "む", .rules_out = &.{"v5"}, .reason = "provisional" },
    .{ .kana_in = "れば", .kana_out = "る", .rules_out = &.{ "v1", "v5" }, .reason = "provisional" },
    .{ .kana_in = "ければ", .kana_out = "い", .rules_out = &.{"adj-i"}, .reason = "provisional" },

    // Imperative. The only single-kana `kana_in` rules in the table, and
    // so the most aggressive: every word ending in え/け/せ/て/... now
    // generates a godan candidate. いえ (家) produces 言う "imperative"
    // alongside the real 家 entry, which hits at depth 0 and outranks it;
    // Yomitan offers the same candidate for the same reason. Accepted
    // deliberately -- the alternative, multi-kana rows only, leaves
    // 話せ, 待て and 頑張れ unresolvable, and that is most of what shouted
    // dialogue is made of.
    //
    // "て" -> "つ" sits beside the existing te-form "て" -> "る": both
    // fire on the same text and each finds only its own class.
    .{ .kana_in = "ろ", .kana_out = "る", .rules_out = &.{"v1"}, .reason = "imperative" },
    .{ .kana_in = "よ", .kana_out = "る", .rules_out = &.{"v1"}, .reason = "imperative" },
    .{ .kana_in = "え", .kana_out = "う", .rules_out = &.{"v5"}, .reason = "imperative" },
    .{ .kana_in = "け", .kana_out = "く", .rules_out = &.{"v5"}, .reason = "imperative" },
    .{ .kana_in = "げ", .kana_out = "ぐ", .rules_out = &.{"v5"}, .reason = "imperative" },
    .{ .kana_in = "せ", .kana_out = "す", .rules_out = &.{"v5"}, .reason = "imperative" },
    .{ .kana_in = "て", .kana_out = "つ", .rules_out = &.{"v5"}, .reason = "imperative" },
    .{ .kana_in = "ね", .kana_out = "ぬ", .rules_out = &.{"v5"}, .reason = "imperative" },
    .{ .kana_in = "べ", .kana_out = "ぶ", .rules_out = &.{"v5"}, .reason = "imperative" },
    .{ .kana_in = "め", .kana_out = "む", .rules_out = &.{"v5"}, .reason = "imperative" },
    .{ .kana_in = "れ", .kana_out = "る", .rules_out = &.{"v5"}, .reason = "imperative" },

    // Polite volitional ("-mashou"). One non-terminal row onto the polite
    // non-past, which the -masu rules above then take to the headword:
    // 食べましょう -> 食べます -> 食べる.
    .{ .kana_in = "ましょう", .kana_out = "ます", .rules_out = &.{}, .reason = "polite volitional" },

    // -- Irregular verbs -------------------------------------------------
    //
    // Three classes the index tags but the rules above can never reach,
    // because every rule above produces only v1/v5/adj-i: vs (する, 987
    // rows in a Jitendex build, 932 of them kanji+する headwords), vk
    // (来る, 184 rows) and vz (ずる, 124 rows). Each class gets its own
    // block holding *all* of its forms -- including the ones whose
    // regular counterparts live in the form-family blocks above -- so
    // that "how is する handled" is one place in the file rather than a
    // dozen.

    // する (vs). The stem is irregular, so these strip whole surface
    // endings back to する rather than swapping a final kana. Suffix
    // matching means the kanji+する headwords come along for free:
    // 察した -> 察する, 愛して -> 愛する.
    //
    // Not listed, because they already chain through the rows above:
    // している / してる (progressive -> して), しなかった (negative past
    // -> しない), したら (conditional -> した).
    .{ .kana_in = "した", .kana_out = "する", .rules_out = &.{"vs"}, .reason = "past" },
    .{ .kana_in = "して", .kana_out = "する", .rules_out = &.{"vs"}, .reason = "te-form" },
    .{ .kana_in = "しない", .kana_out = "する", .rules_out = &.{"vs"}, .reason = "negative" },
    .{ .kana_in = "します", .kana_out = "する", .rules_out = &.{"vs"}, .reason = "polite" },
    .{ .kana_in = "しました", .kana_out = "する", .rules_out = &.{"vs"}, .reason = "polite past" },
    .{ .kana_in = "しません", .kana_out = "する", .rules_out = &.{"vs"}, .reason = "polite negative" },
    .{ .kana_in = "しよう", .kana_out = "する", .rules_out = &.{"vs"}, .reason = "volitional" },
    .{ .kana_in = "したい", .kana_out = "する", .rules_out = &.{"vs"}, .reason = "desiderative" },
    .{ .kana_in = "すれば", .kana_out = "する", .rules_out = &.{"vs"}, .reason = "provisional" },
    .{ .kana_in = "しろ", .kana_out = "する", .rules_out = &.{"vs"}, .reason = "imperative" },
    .{ .kana_in = "せよ", .kana_out = "する", .rules_out = &.{"vs"}, .reason = "imperative" },
    .{ .kana_in = "される", .kana_out = "する", .rules_out = &.{"vs"}, .reason = "passive/potential" },
    .{ .kana_in = "させる", .kana_out = "する", .rules_out = &.{"vs"}, .reason = "causative" },

    // 来る (vk), written with the kanji. The irregularity is in the stem
    // vowel, which the kanji spelling hides -- 来 stays put and only the
    // kana after it change -- so these look like ordinary suffix swaps.
    // Compounds come along by suffix match: 帰って来ない -> 帰って来る.
    .{ .kana_in = "来た", .kana_out = "来る", .rules_out = &.{"vk"}, .reason = "past" },
    .{ .kana_in = "来て", .kana_out = "来る", .rules_out = &.{"vk"}, .reason = "te-form" },
    .{ .kana_in = "来ない", .kana_out = "来る", .rules_out = &.{"vk"}, .reason = "negative" },
    .{ .kana_in = "来ます", .kana_out = "来る", .rules_out = &.{"vk"}, .reason = "polite" },
    .{ .kana_in = "来ました", .kana_out = "来る", .rules_out = &.{"vk"}, .reason = "polite past" },
    .{ .kana_in = "来ません", .kana_out = "来る", .rules_out = &.{"vk"}, .reason = "polite negative" },
    .{ .kana_in = "来よう", .kana_out = "来る", .rules_out = &.{"vk"}, .reason = "volitional" },
    .{ .kana_in = "来たい", .kana_out = "来る", .rules_out = &.{"vk"}, .reason = "desiderative" },
    .{ .kana_in = "来れば", .kana_out = "来る", .rules_out = &.{"vk"}, .reason = "provisional" },
    .{ .kana_in = "来い", .kana_out = "来る", .rules_out = &.{"vk"}, .reason = "imperative" },
    .{ .kana_in = "来られる", .kana_out = "来る", .rules_out = &.{"vk"}, .reason = "passive/potential" },
    .{ .kana_in = "来させる", .kana_out = "来る", .rules_out = &.{"vk"}, .reason = "causative" },

    // 来る (vk), written in kana, where the stem vowel really does change
    // (き-/こ-/く-) and each form needs its own row.
    .{ .kana_in = "きた", .kana_out = "くる", .rules_out = &.{"vk"}, .reason = "past" },
    .{ .kana_in = "きて", .kana_out = "くる", .rules_out = &.{"vk"}, .reason = "te-form" },
    .{ .kana_in = "こない", .kana_out = "くる", .rules_out = &.{"vk"}, .reason = "negative" },
    .{ .kana_in = "きます", .kana_out = "くる", .rules_out = &.{"vk"}, .reason = "polite" },
    .{ .kana_in = "きました", .kana_out = "くる", .rules_out = &.{"vk"}, .reason = "polite past" },
    .{ .kana_in = "きません", .kana_out = "くる", .rules_out = &.{"vk"}, .reason = "polite negative" },
    .{ .kana_in = "こよう", .kana_out = "くる", .rules_out = &.{"vk"}, .reason = "volitional" },
    .{ .kana_in = "きたい", .kana_out = "くる", .rules_out = &.{"vk"}, .reason = "desiderative" },
    .{ .kana_in = "くれば", .kana_out = "くる", .rules_out = &.{"vk"}, .reason = "provisional" },
    .{ .kana_in = "こい", .kana_out = "くる", .rules_out = &.{"vk"}, .reason = "imperative" },
    .{ .kana_in = "こられる", .kana_out = "くる", .rules_out = &.{"vk"}, .reason = "passive/potential" },
    .{ .kana_in = "こさせる", .kana_out = "くる", .rules_out = &.{"vk"}, .reason = "causative" },

    // ずる verbs (vz): 信ずる, 論ずる, 策を講ずる. Largely redundant --
    // most have a modern ichidan twin (信じる, tagged v1) that the rows
    // above already reach -- but 124 rows is 124 rows, and the ずる form
    // is what shows up in older or stiffer writing. No imperative row:
    // じろ belongs to the v1 twin, and the vz imperative (ぜよ) is rare
    // enough to leave to phase 3.
    .{ .kana_in = "じた", .kana_out = "ずる", .rules_out = &.{"vz"}, .reason = "past" },
    .{ .kana_in = "じて", .kana_out = "ずる", .rules_out = &.{"vz"}, .reason = "te-form" },
    .{ .kana_in = "じない", .kana_out = "ずる", .rules_out = &.{"vz"}, .reason = "negative" },
    .{ .kana_in = "じます", .kana_out = "ずる", .rules_out = &.{"vz"}, .reason = "polite" },
    .{ .kana_in = "じました", .kana_out = "ずる", .rules_out = &.{"vz"}, .reason = "polite past" },
    .{ .kana_in = "じません", .kana_out = "ずる", .rules_out = &.{"vz"}, .reason = "polite negative" },
    .{ .kana_in = "じよう", .kana_out = "ずる", .rules_out = &.{"vz"}, .reason = "volitional" },
    .{ .kana_in = "じたい", .kana_out = "ずる", .rules_out = &.{"vz"}, .reason = "desiderative" },
    .{ .kana_in = "じれば", .kana_out = "ずる", .rules_out = &.{"vz"}, .reason = "provisional" },
    .{ .kana_in = "じられる", .kana_out = "ずる", .rules_out = &.{"vz"}, .reason = "passive/potential" },
    .{ .kana_in = "じさせる", .kana_out = "ずる", .rules_out = &.{"vz"}, .reason = "causative" },

    // 行く (v5), whose te-form and past are irregular: 行って/行った, not
    // the 書いて/書いた its -く ending would predict.
    //
    // **This does not make 行く the top hit for 行った, and that is
    // accepted.** 行った still also reaches 行う(おこなう) through the
    // generic "った" -> "う", at the same depth, with the same score and
    // the same term length -- so `rankBefore` falls through to byte order
    // and 行う, whose う sorts before く, is shown first. The reader
    // presses `]` once. A rule-specificity tiebreaker (prefer the chain
    // that consumed more `kana_in` bytes) was considered and rejected: it
    // is a ranking axis Yomitan does not have, invented to cover for the
    // frequency data that is the real answer.
    //
    // That frequency data now exists (see the module doc comment), and it
    // settles this the honest way: 行く is a far commoner word than 行う, so
    // with a `frequency_dictionary` configured it leads. Without one, 行う
    // still does -- which is the argument for configuring one, not for a
    // tiebreaker.
    .{ .kana_in = "行った", .kana_out = "行く", .rules_out = &.{"v5"}, .reason = "past" },
    .{ .kana_in = "行って", .kana_out = "行く", .rules_out = &.{"v5"}, .reason = "te-form" },
    .{ .kana_in = "いった", .kana_out = "いく", .rules_out = &.{"v5"}, .reason = "past" },
    .{ .kana_in = "いって", .kana_out = "いく", .rules_out = &.{"v5"}, .reason = "te-form" },

    // -- The copula and na-adjectives ------------------------------------
    //
    // The first rows in the table with `rules_out = null`, because their
    // target has no class tag to check: a na-adjective or a noun carries an
    // *empty* `rules` column, so 綺麗だった -> 綺麗 can only be validated
    // by "some row exists". See `DeinflectRule.rules_out`.
    //
    // No bare "だ" or "では"/"じゃ" row. Those would strip a kana off a
    // large share of all text for a null filter to wave through, which is
    // a different risk from the imperative rows' -- those at least still
    // demand a v5 row at the other end.
    .{ .kana_in = "だった", .kana_out = "", .rules_out = null, .reason = "copula past" },
    .{ .kana_in = "です", .kana_out = "", .rules_out = null, .reason = "polite copula" },
    .{ .kana_in = "でした", .kana_out = "", .rules_out = null, .reason = "polite copula past" },
    .{ .kana_in = "じゃない", .kana_out = "", .rules_out = null, .reason = "negative copula" },
    .{ .kana_in = "ではない", .kana_out = "", .rules_out = null, .reason = "negative copula" },
    .{ .kana_in = "じゃありません", .kana_out = "", .rules_out = null, .reason = "polite negative copula" },
    .{ .kana_in = "ではありません", .kana_out = "", .rules_out = null, .reason = "polite negative copula" },
    // 綺麗な人 / 静かに -- the attributive and adverbial forms a
    // na-adjective takes. These two are the most permissive rules in the
    // table: any text ending in な or に gets its last kana stripped and
    // whatever is left accepted if it exists at all. Kept because 〜な and
    // 〜に are everywhere in dialogue, and because a hit still has to be a
    // real headword; ここに -> ここ is the shape that makes it worth it.
    .{ .kana_in = "な", .kana_out = "", .rules_out = null, .reason = "attributive" },
    .{ .kana_in = "に", .kana_out = "", .rules_out = null, .reason = "adverbial" },
    // じゃなかった / ではなかった need no rows: the negative-past row
    // already reduces them to じゃない / ではない.

    // -- i-adjective derivations -----------------------------------------
    //
    // 高さ, 早く, 高かろう, 高そう, 高すぎる. These resolved before only
    // when the dictionary happened to lexicalize the derived form (早く and
    // 高さ are their own Jitendex entries, 大きすぎる too) -- as rules they
    // work for any adjective. The `adj-i` filter is what keeps "く" -> "い"
    // honest: 行く also matches it, but 行い is a noun, so the guess is
    // rejected rather than shown as an adjective.
    .{ .kana_in = "さ", .kana_out = "い", .rules_out = &.{"adj-i"}, .reason = "nominalizer" },
    .{ .kana_in = "く", .kana_out = "い", .rules_out = &.{"adj-i"}, .reason = "adverbial" },
    .{ .kana_in = "かろう", .kana_out = "い", .rules_out = &.{"adj-i"}, .reason = "presumptive" },
    .{ .kana_in = "そう", .kana_out = "い", .rules_out = &.{"adj-i"}, .reason = "appearance" },
    .{ .kana_in = "すぎる", .kana_out = "い", .rules_out = &.{"adj-i"}, .reason = "excessive" },

    // Verbal "-sou" ("looks like it will"), from the i-stem. "そう" -> "す"
    // already exists above as the godan volitional (話そう); both fire and
    // each finds only its own class.
    .{ .kana_in = "そう", .kana_out = "る", .rules_out = &.{"v1"}, .reason = "appearance" },
    .{ .kana_in = "いそう", .kana_out = "う", .rules_out = &.{"v5"}, .reason = "appearance" },
    .{ .kana_in = "きそう", .kana_out = "く", .rules_out = &.{"v5"}, .reason = "appearance" },
    .{ .kana_in = "ぎそう", .kana_out = "ぐ", .rules_out = &.{"v5"}, .reason = "appearance" },
    .{ .kana_in = "しそう", .kana_out = "す", .rules_out = &.{"v5"}, .reason = "appearance" },
    .{ .kana_in = "ちそう", .kana_out = "つ", .rules_out = &.{"v5"}, .reason = "appearance" },
    .{ .kana_in = "にそう", .kana_out = "ぬ", .rules_out = &.{"v5"}, .reason = "appearance" },
    .{ .kana_in = "びそう", .kana_out = "ぶ", .rules_out = &.{"v5"}, .reason = "appearance" },
    .{ .kana_in = "みそう", .kana_out = "む", .rules_out = &.{"v5"}, .reason = "appearance" },
    .{ .kana_in = "りそう", .kana_out = "る", .rules_out = &.{"v5"}, .reason = "appearance" },
    .{ .kana_in = "しそう", .kana_out = "する", .rules_out = &.{"vs"}, .reason = "appearance" },

    // Verbal "-sugiru" ("does too much"), from the same i-stem.
    .{ .kana_in = "すぎる", .kana_out = "る", .rules_out = &.{"v1"}, .reason = "excessive" },
    .{ .kana_in = "いすぎる", .kana_out = "う", .rules_out = &.{"v5"}, .reason = "excessive" },
    .{ .kana_in = "きすぎる", .kana_out = "く", .rules_out = &.{"v5"}, .reason = "excessive" },
    .{ .kana_in = "ぎすぎる", .kana_out = "ぐ", .rules_out = &.{"v5"}, .reason = "excessive" },
    .{ .kana_in = "しすぎる", .kana_out = "す", .rules_out = &.{"v5"}, .reason = "excessive" },
    .{ .kana_in = "ちすぎる", .kana_out = "つ", .rules_out = &.{"v5"}, .reason = "excessive" },
    .{ .kana_in = "にすぎる", .kana_out = "ぬ", .rules_out = &.{"v5"}, .reason = "excessive" },
    .{ .kana_in = "びすぎる", .kana_out = "ぶ", .rules_out = &.{"v5"}, .reason = "excessive" },
    .{ .kana_in = "みすぎる", .kana_out = "む", .rules_out = &.{"v5"}, .reason = "excessive" },
    .{ .kana_in = "りすぎる", .kana_out = "る", .rules_out = &.{"v5"}, .reason = "excessive" },
    .{ .kana_in = "しすぎる", .kana_out = "する", .rules_out = &.{"vs"}, .reason = "excessive" },

    // -- te-form compounds ------------------------------------------------
    //
    // An auxiliary verb attached to a te-form. All non-terminal: they strip
    // back to て (or で, after a te-form that voiced it) and the existing
    // te-form rows finish the job, exactly like the progressive rows.
    // 食べちゃう -> 食べて -> 食べる; 飲んじゃう -> 飲んで -> 飲む.
    //
    // "である" is here as the voiced partner of 〜てある (読んである ->
    // 読んで), not as the formal copula. The copula sense collides with it
    // and simply dead-ends: 学生である -> 学生で, which no te-form rule
    // accepts and no row spells.
    .{ .kana_in = "ちゃう", .kana_out = "て", .rules_out = &.{}, .reason = "completive" },
    .{ .kana_in = "じゃう", .kana_out = "で", .rules_out = &.{}, .reason = "completive" },
    .{ .kana_in = "ちまう", .kana_out = "て", .rules_out = &.{}, .reason = "completive" },
    .{ .kana_in = "じまう", .kana_out = "で", .rules_out = &.{}, .reason = "completive" },
    .{ .kana_in = "てしまう", .kana_out = "て", .rules_out = &.{}, .reason = "completive" },
    .{ .kana_in = "でしまう", .kana_out = "で", .rules_out = &.{}, .reason = "completive" },
    .{ .kana_in = "ておく", .kana_out = "て", .rules_out = &.{}, .reason = "preparatory" },
    .{ .kana_in = "でおく", .kana_out = "で", .rules_out = &.{}, .reason = "preparatory" },
    .{ .kana_in = "とく", .kana_out = "て", .rules_out = &.{}, .reason = "preparatory" },
    .{ .kana_in = "どく", .kana_out = "で", .rules_out = &.{}, .reason = "preparatory" },
    .{ .kana_in = "ていく", .kana_out = "て", .rules_out = &.{}, .reason = "continuative" },
    .{ .kana_in = "でいく", .kana_out = "で", .rules_out = &.{}, .reason = "continuative" },
    .{ .kana_in = "てくる", .kana_out = "て", .rules_out = &.{}, .reason = "continuative" },
    .{ .kana_in = "でくる", .kana_out = "で", .rules_out = &.{}, .reason = "continuative" },
    .{ .kana_in = "てある", .kana_out = "て", .rules_out = &.{}, .reason = "resultative" },
    .{ .kana_in = "である", .kana_out = "で", .rules_out = &.{}, .reason = "resultative" },
    .{ .kana_in = "てみる", .kana_out = "て", .rules_out = &.{}, .reason = "attemptive" },
    .{ .kana_in = "でみる", .kana_out = "で", .rules_out = &.{}, .reason = "attemptive" },
    .{ .kana_in = "てくれる", .kana_out = "て", .rules_out = &.{}, .reason = "benefactive" },
    .{ .kana_in = "でくれる", .kana_out = "で", .rules_out = &.{}, .reason = "benefactive" },
    .{ .kana_in = "てもらう", .kana_out = "て", .rules_out = &.{}, .reason = "benefactive" },
    .{ .kana_in = "でもらう", .kana_out = "で", .rules_out = &.{}, .reason = "benefactive" },
    .{ .kana_in = "てあげる", .kana_out = "て", .rules_out = &.{}, .reason = "benefactive" },
    .{ .kana_in = "であげる", .kana_out = "で", .rules_out = &.{}, .reason = "benefactive" },

    // -- Classical, colloquial and dialect negatives ----------------------
    //
    // Four rows instead of the forty their conjugation tables would
    // suggest, because every one of these attaches to the same negative
    // stem "ない" does: strip the ending, put "ない" back, and the
    // negative rows above take it the rest of the way. 知らぬ ->
    // 知らない -> 知る; 行かず -> 行かない -> 行く; 分からん ->
    // 分からない -> 分かる. The chain then reads "negative, colloquial
    // negative", which is accurate -- these *are* negatives.
    //
    // 行かずに comes along too, via the "に" row above: three rules deep.
    .{ .kana_in = "ぬ", .kana_out = "ない", .rules_out = &.{}, .reason = "classical negative" },
    .{ .kana_in = "ず", .kana_out = "ない", .rules_out = &.{}, .reason = "classical negative" },
    .{ .kana_in = "ん", .kana_out = "ない", .rules_out = &.{}, .reason = "colloquial negative" },
    .{ .kana_in = "へん", .kana_out = "ない", .rules_out = &.{}, .reason = "Kansai negative" },
    .{ .kana_in = "せん", .kana_out = "する", .rules_out = &.{"vs"}, .reason = "colloquial negative" },

    // Kansai progressive (見とる, 何しとるんや). Strips to the te-form like
    // the standard 〜ている does. Only the kana spelling collides (取る is
    // 取 + る, so it does not end in とる).
    .{ .kana_in = "とる", .kana_out = "て", .rules_out = &.{}, .reason = "Kansai progressive" },
    .{ .kana_in = "どる", .kana_out = "で", .rules_out = &.{}, .reason = "Kansai progressive" },

    // -- The gaps the earlier phases left behind --------------------------

    // The godan す-row causative the table's own doc comment has been
    // admitting was missing since causative landed: 話させる -> 話す.
    .{ .kana_in = "させる", .kana_out = "す", .rules_out = &.{"v5"}, .reason = "causative" },

    // Godan potential ("can do"), which is a distinct form from the
    // passive/potential -areru above: 書ける, 飲める, 泳げる. Jitendex
    // lexicalizes some of these as their own v1 entries (読める, 話せる)
    // and not others (書ける), so before this a click on 書けない found
    // nothing at all.
    //
    // These overlap with real ichidan verbs by construction -- 入れる is
    // its own v1 headword *and* looks like the potential of 入る -- so
    // both are offered, the depth-0 headword first. Same trade as the
    // imperative rows.
    .{ .kana_in = "える", .kana_out = "う", .rules_out = &.{"v5"}, .reason = "potential" },
    .{ .kana_in = "ける", .kana_out = "く", .rules_out = &.{"v5"}, .reason = "potential" },
    .{ .kana_in = "げる", .kana_out = "ぐ", .rules_out = &.{"v5"}, .reason = "potential" },
    .{ .kana_in = "せる", .kana_out = "す", .rules_out = &.{"v5"}, .reason = "potential" },
    .{ .kana_in = "てる", .kana_out = "つ", .rules_out = &.{"v5"}, .reason = "potential" },
    .{ .kana_in = "ねる", .kana_out = "ぬ", .rules_out = &.{"v5"}, .reason = "potential" },
    .{ .kana_in = "べる", .kana_out = "ぶ", .rules_out = &.{"v5"}, .reason = "potential" },
    .{ .kana_in = "める", .kana_out = "む", .rules_out = &.{"v5"}, .reason = "potential" },
    .{ .kana_in = "れる", .kana_out = "る", .rules_out = &.{"v5"}, .reason = "potential" },
};

/// Ceiling on how many deinflection rules may be chained for one
/// candidate substring -- see `Search.collect`. 5 is the deepest real
/// form the table can reach: 食べさせられたくなかった unwinds through
/// causative, passive/potential, desiderative, negative and past, one
/// rule each.
///
/// Raising it is close to free, which is not obvious from the rule count.
/// Replaying `collect` against a real 398k-row Jitendex index, a long
/// kana-only form reaches 40 distinct queried forms at depth 4, 42 at
/// depth 5 and **42 at depth 6** -- the search saturates rather than
/// branching, because the rules' `kana_in` suffixes are near-disjoint so
/// only two or three ever match a given form, and each chain dead-ends
/// within a step or two. The per-call cache in `Search.query` then makes
/// repeats free. So the cap is set by what the table can actually
/// express, not by what the search costs.
pub const max_deinflect_depth: usize = 5;

/// One entry a lookup found, with how it was found. `dict.lookup` ranks
/// hits on these fields the way Yomitan's `_sortTermDictionaryEntries`
/// does -- see `rankBefore`.
pub const Hit = struct {
    entry: Entry,
    /// How many bytes of the looked-up text this hit covers. Different
    /// hits in one `Match` can cover different lengths (食べ物, then 食べる
    /// off its first two characters, then 食 alone).
    source_len: usize,
    /// Every rule reason applied along the chain that reached `entry`,
    /// innermost (closest to the dictionary form) first, joined with
    /// ", " -- e.g. "causative, negative". Null for a direct hit. Owned by
    /// the allocator `lookup` was given.
    reason: ?[]const u8 = null,
    /// How many deinflection rules were applied (0 = direct hit).
    depth: u8 = 0,
    /// How many text normalization steps (`kana.variants`) the looked-up
    /// text needed before it matched (0 = matched as written).
    variant_steps: u8 = 0,
    /// True when the entry's own `term` (not just its `reading`) is the
    /// string that matched -- a kana-written headword ranks above a
    /// kanji one that merely reads the same.
    exact: bool = false,
    /// The frequency dictionary's raw number for this headword, or null
    /// when none was loaded or it had nothing for this word. Interpret it
    /// with the `frequency_order` the lookup was given -- the number alone
    /// does not say which direction is "common".
    frequency: ?i64 = null,
    /// The frequency list's own rendering of `frequency` when it supplied
    /// one, else empty. Owned by the allocator `lookup` was given.
    frequency_display: []const u8 = "",

    pub fn deinit(self: Hit, alloc: std.mem.Allocator) void {
        self.entry.deinit(alloc);
        if (self.reason) |r| alloc.free(r);
        alloc.free(self.frequency_display);
    }
};

/// A successful lookup: every hit, best first. Never empty -- `lookup`
/// returns null instead. Owned by the allocator `lookup` was given; free
/// with `deinit`.
pub const Match = struct {
    hits: []Hit,

    /// Bytes covered by the best hit -- the longest match, since that is
    /// the first thing hits are ranked on.
    pub fn len(self: Match) usize {
        return self.hits[0].source_len;
    }

    pub fn deinit(self: Match, alloc: std.mem.Allocator) void {
        for (self.hits) |h| h.deinit(alloc);
        alloc.free(self.hits);
    }
};

/// How many codepoints of `text` a lookup considers -- Yomitan's default
/// scan length. Covers every realistic single-word span (this table's
/// longest suffix plus a multi-kanji stem).
pub const max_scan_codepoints: usize = 16;

/// Ceiling on how many hits one `Match` keeps -- Yomitan's default
/// `maxResults`. A short kana prefix like お can match a dozen entries
/// by reading, and they all rank below anything longer anyway.
pub const max_results: usize = 32;

/// Looks up everything `text` could start with, the way Yomitan does:
/// every prefix of up to `max_scan_codepoints` codepoints, each tried in
/// every `kana.variants` spelling, each of those deinflected through
/// every chain of up to `max_deinflect_depth` rules -- and every
/// resulting form queried against both the `term` and the `reading`
/// column. All of it is collected, not just the longest length that hit
/// something, then ranked (`rankBefore`) and capped at `max_results`.
///
/// Querying `reading` is what makes kana-written words work at all: a
/// dictionary like Jitendex files おもしろい under its kanji headword
/// 面白い, so a term-only search misses it at every length and falls all
/// the way back to the interjection お.
///
/// An entry reachable more than one way (at several lengths, or through
/// several spellings or chains) is kept once, from its best route --
/// longest source, then fewest normalization steps, then fewest rules.
///
/// A dragged selection goes through here too: its full text is simply
/// the longest prefix, so an exact match on the selection ranks first
/// and shorter prefixes follow only as fallbacks.
pub fn lookup(
    alloc: std.mem.Allocator,
    dict: *Dict,
    freq: ?*Dict,
    order: config.FrequencyOrder,
    text: []const u8,
) !?Match {
    // Every query result, variant string and chain lives here until the
    // winners are copied out into `alloc` at the end.
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    var search: Search = .{ .scratch = arena.allocator(), .dict = dict };

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
        search.source_len = bounds[li];
        for (try kana.variants(search.scratch, text[0..bounds[li]])) |v| {
            search.variant_steps = v.steps;
            try search.collect(v.text, null, &.{});
        }
    }

    const found = search.best.values();
    if (found.len == 0) return null;

    // Frequency is read here, once per surviving candidate, rather than
    // during `collect`: the search reaches the same row by several routes
    // and only the winning route is kept, so annotating at the end is one
    // query per *entry* (a few dozen) instead of one per route.
    if (freq) |f| {
        for (found) |*c| {
            if (frequencyFor(f, order, c.entry.term, c.entry.reading)) |got| {
                c.frequency = got.value;
                c.frequency_display = try search.scratch.dupe(u8, got.display);
            }
        }
    }

    std.mem.sort(Candidate, found, order, rankBefore);

    const n = @min(found.len, max_results);
    var hits: std.ArrayList(Hit) = .empty;
    errdefer {
        for (hits.items) |h| h.deinit(alloc);
        hits.deinit(alloc);
    }
    for (found[0..n]) |c| {
        const entry = try dupeEntry(alloc, c.entry);
        errdefer entry.deinit(alloc);
        const reason = if (c.chain.len == 0) null else try joinChainReasons(alloc, c.chain);
        try hits.append(alloc, .{
            .entry = entry,
            .source_len = c.source_len,
            .reason = reason,
            .depth = @intCast(c.chain.len),
            .variant_steps = c.variant_steps,
            .exact = c.exact,
            .frequency = c.frequency,
            .frequency_display = try alloc.dupe(u8, c.frequency_display),
        });
    }
    return .{ .hits = try hits.toOwnedSlice(alloc) };
}

/// One way of reaching a dictionary row, before ranking. Everything in it
/// lives in `Search.scratch`.
const Candidate = struct {
    entry: Entry,
    source_len: usize,
    variant_steps: u8,
    exact: bool,
    /// The frequency dictionary's number for this headword, or null when
    /// there is no frequency dictionary or it has nothing for this word.
    /// Filled in by `lookup` after the search, not by `collect`.
    frequency: ?i64 = null,
    frequency_display: []const u8 = "",
    /// Rule reasons in application order, outermost first -- see
    /// `joinChainReasons`.
    chain: []const []const u8,

    /// Whether `self` is a better route to the *same* entry than
    /// `other`: the dedup rule in `Search.offer`.
    fn betterRouteThan(self: Candidate, other: Candidate) bool {
        if (self.source_len != other.source_len) return self.source_len > other.source_len;
        if (self.variant_steps != other.variant_steps) return self.variant_steps < other.variant_steps;
        return self.chain.len < other.chain.len;
    }
};

/// Yomitan's result order, minus the one part that still needs data this
/// reader doesn't have (several dictionaries at once): longest source text,
/// **most frequent**, fewest normalization steps, fewest deinflection rules,
/// an exact term match over a reading-only one, higher dictionary score,
/// longer headword, headword text, more senses -- and the row id last, so
/// the order is total and repeatable.
///
/// **Frequency outranks deinflection depth deliberately**, and that is the
/// whole point of loading it. Without it, "fewest rules wins" means any
/// depth-0 homograph noun beats the verb a reader is actually looking at:
/// した showed 下 "below" first with する fourth, and しよう buried する
/// thirteenth under 私用/使用/仕様/至要. Frequency is the thing that knows
/// する is one of the most common words in the language and 至要 is not.
/// The cost, accepted: a common but heavily conjugated reading can now
/// outrank a rarer word that matched as written.
///
/// A candidate with no frequency at all sorts *after* every candidate that
/// has one -- silence from a frequency list is weak evidence of rarity, and
/// treating it as "unknown, so neutral" would let it jump ahead of a word
/// the list explicitly ranked. With no frequency dictionary loaded nothing
/// has a frequency, the whole axis is inert, and the order is exactly what
/// it was before.
fn rankBefore(order: config.FrequencyOrder, a: Candidate, b: Candidate) bool {
    if (a.source_len != b.source_len) return a.source_len > b.source_len;
    if (a.frequency) |af| {
        if (b.frequency) |bf| {
            if (af != bf) return order.moreCommon(af, bf);
        } else return true;
    } else if (b.frequency != null) return false;
    if (a.variant_steps != b.variant_steps) return a.variant_steps < b.variant_steps;
    if (a.chain.len != b.chain.len) return a.chain.len < b.chain.len;
    if (a.exact != b.exact) return a.exact;
    if (a.entry.score != b.entry.score) return a.entry.score > b.entry.score;
    if (a.entry.term.len != b.entry.term.len) return a.entry.term.len > b.entry.term.len;
    switch (std.mem.order(u8, a.entry.term, b.entry.term)) {
        .lt => return true,
        .gt => return false,
        .eq => {},
    }
    if (a.entry.glossary.len != b.entry.glossary.len) return a.entry.glossary.len > b.entry.glossary.len;
    return a.entry.id < b.entry.id;
}

/// The state of one `lookup` call: the scratch arena, a per-call query
/// cache (the same form comes up again and again across lengths,
/// variants and chains), and the best route found so far to each entry.
const Search = struct {
    scratch: std.mem.Allocator,
    dict: *Dict,
    /// The prefix length and variant currently being searched.
    source_len: usize = 0,
    variant_steps: u8 = 0,
    queried: std.StringHashMapUnmanaged([]const Entry) = .empty,
    /// Keyed by the row's `id`. Insertion-ordered, which doesn't matter
    /// -- `lookup` sorts the values afterward.
    best: std.AutoArrayHashMapUnmanaged(i64, Candidate) = .empty,

    fn query(self: *Search, form: []const u8) ![]const Entry {
        if (self.queried.get(form)) |rows| return rows;
        const rows: []const Entry = (try queryTerm(self.scratch, self.dict, form)) orelse &.{};
        try self.queried.put(self.scratch, try self.scratch.dupe(u8, form), rows);
        return rows;
    }

    /// Queries `form`, offers every row that passes `filter` (null for
    /// the undeinflected text, which accepts every row), then tries
    /// every rule that strips a suffix off `form`, recursing up to
    /// `max_deinflect_depth` rules deep.
    ///
    /// `filter` is the *last* applied rule's `rules_out`: only that rule
    /// constrains which rows count. An empty `rules_out` (`&.{}`) can
    /// never pass (`hasAnyRule` against an empty list is always false),
    /// which is how a non-terminal rule forces at least one more step --
    /// see `DeinflectRule`.
    fn collect(self: *Search, form: []const u8, filter: ?[]const []const u8, chain: []const []const u8) !void {
        for (try self.query(form)) |row| {
            if (filter) |f| if (!hasAnyRule(row.rules, f)) continue;
            try self.offer(.{
                .entry = row,
                .source_len = self.source_len,
                .variant_steps = self.variant_steps,
                .exact = std.mem.eql(u8, row.term, form),
                .chain = chain,
            });
        }
        if (chain.len == max_deinflect_depth) return;

        for (deinflect_rules) |rule| {
            if (!std.mem.endsWith(u8, form, rule.kana_in)) continue;
            const stem = form[0 .. form.len - rule.kana_in.len];
            const next = try std.mem.concat(self.scratch, u8, &.{ stem, rule.kana_out });
            // The copula rows have an empty `kana_out`, so a form that is
            // nothing but the ending ("だった" on its own) deinflects to
            // nothing. Querying "" finds no rows and no rule can match it,
            // so this only skips work -- but it makes that explicit
            // rather than leaving it to fall out.
            if (next.len == 0) continue;
            const next_chain = try self.scratch.alloc([]const u8, chain.len + 1);
            @memcpy(next_chain[0..chain.len], chain);
            next_chain[chain.len] = rule.reason;
            try self.collect(next, rule.rules_out, next_chain);
        }
    }

    fn offer(self: *Search, c: Candidate) !void {
        const gop = try self.best.getOrPut(self.scratch, c.entry.id);
        if (!gop.found_existing or c.betterRouteThan(gop.value_ptr.*)) gop.value_ptr.* = c;
    }
};

/// Joins `chain`'s reasons into one display string, innermost reason
/// first (the reverse of `chain`'s own outermost-first accumulation
/// order): "食べさせない" strips the outer negative first, landing on the
/// causative form "食べさせる", which the causative rule then reduces to
/// "食べる" -- `chain = .{"negative", "causative"}`, shown as
/// "causative, negative". Never called with an empty `chain`.
fn joinChainReasons(alloc: std.mem.Allocator, chain: []const []const u8) ![]const u8 {
    var reversed: [max_deinflect_depth][]const u8 = undefined;
    for (chain, 0..) |r, idx| reversed[chain.len - 1 - idx] = r;
    return std.mem.join(alloc, ", ", reversed[0..chain.len]);
}

fn dupeEntry(alloc: std.mem.Allocator, e: Entry) !Entry {
    const term = try alloc.dupe(u8, e.term);
    errdefer alloc.free(term);
    const reading = try alloc.dupe(u8, e.reading);
    errdefer alloc.free(reading);
    const rules = try alloc.dupe(u8, e.rules);
    errdefer alloc.free(rules);
    var glossary: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (glossary.items) |g| alloc.free(g);
        glossary.deinit(alloc);
    }
    for (e.glossary) |g| try glossary.append(alloc, try alloc.dupe(u8, g));
    return .{
        .id = e.id,
        .term = term,
        .reading = reading,
        .rules = rules,
        .glossary = try glossary.toOwnedSlice(alloc),
        .sequence = e.sequence,
        .score = e.score,
    };
}

/// Every entry whose `term` or `reading` is exactly `term`, or null when
/// there are none. Reuses (and always resets) `dict.lookup_stmt`.
fn queryTerm(alloc: std.mem.Allocator, dict: *Dict, term: []const u8) !?[]Entry {
    dict.lookup_stmt.reset();
    try dict.lookup_stmt.bindText(1, term);

    var out: std.ArrayList(Entry) = .empty;
    errdefer freeEntries(alloc, out.items);
    while (try dict.lookup_stmt.step()) {
        try out.append(alloc, .{
            .id = dict.lookup_stmt.columnInt64(0),
            .term = try alloc.dupe(u8, dict.lookup_stmt.columnText(1)),
            .reading = try alloc.dupe(u8, dict.lookup_stmt.columnText(2)),
            .rules = try alloc.dupe(u8, dict.lookup_stmt.columnText(3)),
            .glossary = try splitGlossary(alloc, dict.lookup_stmt.columnText(4)),
            .sequence = dict.lookup_stmt.columnInt64(5),
            .score = dict.lookup_stmt.columnInt64(6),
        });
    }
    if (out.items.len == 0) {
        out.deinit(alloc);
        return null;
    }
    return try out.toOwnedSlice(alloc);
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

/// The delimiter joining a row's flattened glossary strings into the
/// `entries.glossary` column -- ASCII unit separator, which no flattened
/// English/Japanese definition text will ever contain.
const glossary_sep: u8 = 0x1F;

fn joinGlossary(a: std.mem.Allocator, items: []const []const u8) std.mem.Allocator.Error![]const u8 {
    var buf: [1]u8 = .{glossary_sep};
    return std.mem.join(a, buf[0..], items);
}

fn splitGlossary(a: std.mem.Allocator, blob: []const u8) std.mem.Allocator.Error![]const []const u8 {
    if (blob.len == 0) return &.{};
    var out: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, blob, glossary_sep);
    while (it.next()) |part| try out.append(a, try a.dupe(u8, part));
    return out.toOwnedSlice(a);
}

/// Parses one `term_bank_N.json`'s rows and inserts each into `entries`
/// via `insert_stmt` (`insert_sql`, already prepared by the caller). Returns how many rows were actually inserted -- `Builder`
/// uses it to run a "N terms indexed" counter while building. Same
/// drop-don't-fail error policy as the parse this replaced: a row that
/// doesn't fit the shape, or that SQLite itself rejects, is dropped,
/// never a reason to fail the whole file.
///
/// `scratch_backing` backs a fresh arena that holds the `std.json.Value`
/// parse tree and nothing else; it's destroyed before this returns. See
/// the module doc comment for why that split exists.
fn insertTermBank(
    insert_stmt: sqlite.Stmt,
    scratch_backing: std.mem.Allocator,
    json: []const u8,
) std.mem.Allocator.Error!usize {
    var scratch: std.heap.ArenaAllocator = .init(scratch_backing);
    defer scratch.deinit();
    const sa = scratch.allocator();

    const parsed = std.json.parseFromSlice(std.json.Value, sa, json, .{}) catch return 0;
    const rows = switch (parsed.value) {
        .array => |arr| arr,
        else => return 0,
    };
    var inserted: usize = 0;
    for (rows.items) |row_val| {
        const row = switch (row_val) {
            .array => |r| r,
            else => continue,
        };
        // `[term, reading, definitionTags, rules, score, glossary, sequence, termTags]`.
        if (row.items.len < 8) continue;
        const term = jsonString(row.items[0]) orelse continue;
        const glossary = try parseGlossary(sa, row.items[5]);
        const joined = try joinGlossary(sa, glossary);
        // An empty reading means "reads as written" -- stored as the term
        // itself, the same as Yomitan's importer, so the `reading` index
        // covers kana-only headwords too.
        const reading = jsonString(row.items[1]) orelse "";

        insertRow(
            insert_stmt,
            term,
            if (reading.len == 0) term else reading,
            jsonString(row.items[3]) orelse "",
            joined,
            jsonInt(row.items[6]) orelse 0,
            jsonInt(row.items[4]) orelse 0,
        ) catch {
            insert_stmt.reset();
            continue;
        };
        insert_stmt.reset();
        inserted += 1;
    }
    return inserted;
}

fn insertRow(
    stmt: sqlite.Stmt,
    term: []const u8,
    reading: []const u8,
    rules: []const u8,
    glossary: []const u8,
    sequence: i64,
    score: i64,
) sqlite.Error!void {
    try stmt.bindText(1, term);
    try stmt.bindText(2, reading);
    try stmt.bindText(3, rules);
    try stmt.bindText(4, glossary);
    try stmt.bindInt64(5, sequence);
    try stmt.bindInt64(6, score);
    _ = try stmt.step();
}

/// Parses one `term_meta_bank_N.json` and inserts its **frequency** rows,
/// returning how many landed. Same drop-don't-fail policy and same
/// per-file scratch arena as `insertTermBank`.
///
/// A meta row is `[term, type, data]` where `type` is "freq", "pitch" or
/// "ipa"; only "freq" is kept, since pitch accent is display-only and this
/// module has nowhere to show it yet.
///
/// `data` has five shapes in the wild, all of which appear in the
/// frequency lists Yomitan users install, and `parseFrequency` folds them
/// into one `(reading, value, display)` triple:
///
/// ```
/// 12                                              -- a bare number
/// "12"                                            -- the same, as text
/// { "value": 12, "displayValue": "12㋕" }          -- a display override
/// { "reading": "にほん", "frequency": 12 }         -- reading-specific
/// { "reading": "にほん",
///   "frequency": { "value": 12, "displayValue": "12" } }
/// ```
///
/// A reading-specific row only applies to that reading; a row without one
/// applies to any reading of the term, and is stored with an empty
/// `reading` to say so. That is the distinction `frequencyFor` then uses.
fn insertTermMetaBank(
    insert_stmt: sqlite.Stmt,
    scratch_backing: std.mem.Allocator,
    json: []const u8,
) std.mem.Allocator.Error!usize {
    var scratch: std.heap.ArenaAllocator = .init(scratch_backing);
    defer scratch.deinit();
    const sa = scratch.allocator();

    const parsed = std.json.parseFromSlice(std.json.Value, sa, json, .{}) catch return 0;
    const rows = switch (parsed.value) {
        .array => |arr| arr,
        else => return 0,
    };
    var inserted: usize = 0;
    for (rows.items) |row_val| {
        const row = switch (row_val) {
            .array => |r| r,
            else => continue,
        };
        if (row.items.len < 3) continue;
        const term = jsonString(row.items[0]) orelse continue;
        const kind = jsonString(row.items[1]) orelse continue;
        if (!std.mem.eql(u8, kind, "freq")) continue;
        const freq = parseFrequency(row.items[2]) orelse continue;

        insertMetaRow(insert_stmt, term, freq.reading, freq.value, freq.display) catch {
            insert_stmt.reset();
            continue;
        };
        insert_stmt.reset();
        inserted += 1;
    }
    return inserted;
}

/// One frequency row as it came out of a `term_meta_bank` file, before it
/// is bound to the insert. `reading` is empty when the row applies to any
/// reading; `display` is empty when the number speaks for itself.
const ParsedFrequency = struct {
    reading: []const u8 = "",
    value: i64,
    display: []const u8 = "",
};

/// Folds every `data` shape listed on `insertTermMetaBank` into one
/// triple, or null when there is no usable number in there at all.
///
/// The string form is parsed rather than stored as text: a frequency has
/// to be ordered against other frequencies, and a list that writes its
/// numbers as strings is otherwise indistinguishable from one that writes
/// them as numbers. Text that isn't a number keeps its display value and
/// is dropped from ranking, which is the honest outcome -- "㋕" is a
/// label, not a rank.
fn parseFrequency(v: std.json.Value) ?ParsedFrequency {
    switch (v) {
        .integer => |n| return .{ .value = n },
        .float => |f| return .{ .value = @intFromFloat(f) },
        .string => |t| return .{
            .value = std.fmt.parseInt(i64, t, 10) catch return null,
            .display = t,
        },
        .object => |obj| {
            // Reading-specific: recurse on the inner `frequency`, which is
            // itself any of the non-object shapes or the value/displayValue
            // object.
            if (obj.get("frequency")) |inner| {
                var got = parseFrequency(inner) orelse return null;
                got.reading = jsonString(obj.get("reading") orelse .null) orelse "";
                return got;
            }
            const value = obj.get("value") orelse return null;
            var got = parseFrequency(value) orelse return null;
            if (jsonString(obj.get("displayValue") orelse .null)) |d| got.display = d;
            got.reading = jsonString(obj.get("reading") orelse .null) orelse got.reading;
            return got;
        },
        else => return null,
    }
}

fn insertMetaRow(
    stmt: sqlite.Stmt,
    term: []const u8,
    reading: []const u8,
    frequency: i64,
    display: []const u8,
) sqlite.Error!void {
    try stmt.bindText(1, term);
    try stmt.bindText(2, reading);
    try stmt.bindInt64(3, frequency);
    try stmt.bindText(4, display);
    _ = try stmt.step();
}

/// Reads `index.json`'s `title` into `out`, replacing whatever was there.
/// Leaves `out` untouched if the JSON doesn't parse or has no title.
fn readTitleInto(
    scratch_backing: std.mem.Allocator,
    out: *std.ArrayList(u8),
    out_alloc: std.mem.Allocator,
    json: []const u8,
) std.mem.Allocator.Error!void {
    var scratch: std.heap.ArenaAllocator = .init(scratch_backing);
    defer scratch.deinit();
    const parsed = std.json.parseFromSlice(std.json.Value, scratch.allocator(), json, .{}) catch return;
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return,
    };
    const t = jsonString(obj.get("title") orelse return) orelse return;
    out.clearRetainingCapacity();
    try out.appendSlice(out_alloc, t);
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

/// Flattens one entry's glossary to plain text, one string per sense. A
/// v3 term bank's glossary items are plain strings, one sense each.
/// Jitendex and other structured-content dictionaries nest tagged
/// objects instead -- `{"tag": "...", "content": [...]}` -- and mark each
/// sense's glosses as a list with `data.content = "glossary"`; each such
/// list becomes one string, its items joined with "; ". Everything
/// around the lists (part-of-speech badges, notes, example sentences,
/// the forms table, the JMdict credit) is left out: the lookup panel and
/// an Anki card's Meaning both want what the word means, and the rest
/// flattened into one line read as noise ("exp kana everybody ... 正 しょう
/// 直 じき ... JMdict | Tatoeba").
///
/// A structured entry with no glossary lists falls back to every text
/// leaf in document order, minus the same badges, ruby readings and
/// credit (`flattenText`).
fn parseGlossary(a: std.mem.Allocator, v: std.json.Value) std.mem.Allocator.Error![]const []const u8 {
    const arr = switch (v) {
        .array => |arr| arr,
        else => return &.{},
    };
    var out: std.ArrayList([]const u8) = .empty;
    for (arr.items) |item| {
        const before = out.items.len;
        try collectGlossaryLists(a, item, &out);
        if (out.items.len > before) continue;

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

/// `data.content` of a structured-content node, or "".
fn dataContent(obj: std.json.ObjectMap) []const u8 {
    const data = obj.get("data") orelse return "";
    if (data != .object) return "";
    const c = data.object.get("content") orelse return "";
    return if (c == .string) c.string else "";
}

/// Appends one string per `data.content = "glossary"` list under `v`,
/// each item flattened and joined with "; ".
fn collectGlossaryLists(a: std.mem.Allocator, v: std.json.Value, out: *std.ArrayList([]const u8)) std.mem.Allocator.Error!void {
    switch (v) {
        .array => |arr| for (arr.items) |item| try collectGlossaryLists(a, item, out),
        .object => |obj| {
            const content = obj.get("content") orelse return;
            if (!std.mem.eql(u8, dataContent(obj), "glossary")) return collectGlossaryLists(a, content, out);

            var buf: std.ArrayList(u8) = .empty;
            const items: []const std.json.Value = switch (content) {
                .array => |arr| arr.items,
                else => &.{content},
            };
            for (items) |item| {
                var gloss: std.ArrayList(u8) = .empty;
                defer gloss.deinit(a);
                try flattenText(a, item, &gloss);
                if (gloss.items.len == 0) continue;
                if (buf.items.len > 0) try buf.appendSlice(a, "; ");
                try buf.appendSlice(a, gloss.items);
            }
            if (buf.items.len == 0) {
                buf.deinit(a);
                return;
            }
            try out.append(a, try buf.toOwnedSlice(a));
        },
        else => {},
    }
}

/// Every text leaf under `v`, space-separated, in document order --
/// except ruby readings (`rt`, which would put 正 しょう side by side),
/// tag badges (`data.class = "tag"`), and the forms table and credit
/// line, none of which are part of what the entry says.
fn flattenText(a: std.mem.Allocator, v: std.json.Value, out: *std.ArrayList(u8)) std.mem.Allocator.Error!void {
    switch (v) {
        .string => |s| {
            if (s.len == 0) return;
            if (out.items.len > 0) try out.append(a, ' ');
            try out.appendSlice(a, s);
        },
        .array => |arr| for (arr.items) |item| try flattenText(a, item, out),
        .object => |obj| {
            if (obj.get("tag")) |t| if (t == .string and std.mem.eql(u8, t.string, "rt")) return;
            if (obj.get("data")) |data| if (data == .object) {
                if (data.object.get("class")) |cls| if (cls == .string and std.mem.eql(u8, cls.string, "tag")) return;
            };
            const role = dataContent(obj);
            if (std.mem.eql(u8, role, "forms") or std.mem.eql(u8, role, "attribution")) return;
            if (obj.get("content")) |c| try flattenText(a, c, out);
        },
        else => {},
    }
}

/// True for a file name that is a term bank -- `term_bank_1.json` and
/// friends, but not `term_meta_bank_*` (frequency/pitch data) or
/// `kanji_bank_*`/`tag_bank_*`, neither of which this module reads yet.
fn isTermBankName(name: []const u8) bool {
    return std.mem.startsWith(u8, name, "term_bank_") and std.ascii.endsWithIgnoreCase(name, ".json");
}

/// `term_meta_bank_*.json` -- frequency (and pitch accent, which this
/// module skips) rather than definitions. Checked *before*
/// `isTermBankName` would matter, since the two prefixes don't overlap.
fn isTermMetaBankName(name: []const u8) bool {
    return std.mem.startsWith(u8, name, "term_meta_bank_") and std.ascii.endsWithIgnoreCase(name, ".json");
}

/// Ceiling on one term bank file's raw JSON size. Jitendex's largest
/// files run to tens of MB; 256 MiB is the "obviously wrong" line for a
/// single file the same way `archive.max_page_bytes` draws one for a
/// page image, not a realistic size.
pub const max_term_bank_bytes: usize = 256 * 1024 * 1024;
/// `index.json` is a few hundred bytes in practice.
pub const max_index_bytes: usize = 1024 * 1024;

/// The SQLite file `loadFromDir` builds and queries, sitting alongside
/// the term banks it was built from.
pub const db_file_name = "index.sqlite3";

const schema_sql =
    \\DROP TABLE IF EXISTS entries;
    \\DROP TABLE IF EXISTS term_meta;
    \\DROP TABLE IF EXISTS meta;
    \\CREATE TABLE entries (
    \\  id INTEGER PRIMARY KEY,
    \\  term TEXT NOT NULL,
    \\  reading TEXT NOT NULL,
    \\  rules TEXT NOT NULL,
    \\  glossary TEXT NOT NULL,
    \\  sequence INTEGER NOT NULL,
    \\  score INTEGER NOT NULL
    \\);
    \\CREATE TABLE term_meta (
    \\  id INTEGER PRIMARY KEY,
    \\  term TEXT NOT NULL,
    \\  reading TEXT NOT NULL,
    \\  frequency INTEGER NOT NULL,
    \\  display TEXT NOT NULL
    \\);
    \\CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
;

/// Bumped whenever `schema_sql` or what gets stored in it changes, so an
/// index built by an older gw-read is rebuilt rather than queried with
/// columns it doesn't have. 2 added `score`, the `reading` index, and
/// empty readings stored as the term. 3 stores structured glossaries as
/// one string per sense list, without badges, examples or credits. 4 adds
/// `term_meta`, the frequency table built from `term_meta_bank_*.json`.
pub const schema_version = "4";

const insert_sql = "INSERT INTO entries (term, reading, rules, glossary, sequence, score) VALUES (?, ?, ?, ?, ?, ?)";

const insert_meta_sql = "INSERT INTO term_meta (term, reading, frequency, display) VALUES (?, ?, ?, ?)";

/// Every frequency row for a headword, matched on either its `term` or its
/// `reading` -- a frequency list files a kana-written word under the kana,
/// while Jitendex files it under the kanji. `frequencyFor` picks between
/// the rows this returns; see it for the preference order.
const freq_sql = "SELECT term, reading, frequency, display FROM term_meta WHERE term = ?1 OR term = ?2";

/// Matches on the headword *or* its reading -- see `lookup` for why the
/// reading half is essential.
const lookup_sql = "SELECT id, term, reading, rules, glossary, sequence, score FROM entries WHERE term = ?1 OR reading = ?1";

const index_sql =
    \\CREATE INDEX IF NOT EXISTS idx_entries_term ON entries(term);
    \\CREATE INDEX IF NOT EXISTS idx_entries_reading ON entries(reading);
    \\CREATE INDEX IF NOT EXISTS idx_term_meta_term ON term_meta(term);
;

/// Writes the `meta` rows, `complete` last -- see `isBuilt`.
fn writeMeta(db: *sqlite.Db, title: []const u8) !void {
    var meta_stmt = try db.prepare("INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?)");
    defer meta_stmt.finalize();
    const rows = [_][2][]const u8{
        .{ "title", title },
        .{ "schema", schema_version },
        .{ "complete", "1" },
    };
    for (rows) |row| {
        try meta_stmt.bindText(1, row[0]);
        try meta_stmt.bindText(2, row[1]);
        _ = try meta_stmt.step();
        meta_stmt.reset();
    }
}

/// True once `build` has committed a full index -- the `meta` row it
/// writes last, after the data and the index both exist, so a build
/// interrupted partway through (crash, killed process) is never mistaken
/// for a finished one. `prepare` itself fails on a brand new database
/// (no `meta` table yet), which this treats the same as "not built".
///
/// An index from an older `schema_version` counts as not built, which
/// sends it through the same drop-and-rebuild an interrupted build gets.
fn isBuilt(db: *sqlite.Db) bool {
    var complete = db.prepare("SELECT value FROM meta WHERE key = 'complete'") catch return false;
    defer complete.finalize();
    if (!(complete.step() catch false)) return false;

    var schema = db.prepare("SELECT value FROM meta WHERE key = 'schema'") catch return false;
    defer schema.finalize();
    if (!(schema.step() catch false)) return false;
    return std.mem.eql(u8, schema.columnText(0), schema_version);
}

/// An in-progress build, one `term_bank_*.json` file at a time --
/// `ui.zig` drives this one `step` per run-loop tick instead of calling
/// `loadFromDir` and blocking the reader for however long a real
/// Jitendex-sized dictionary takes to index, so it can show a "building
/// dictionary, file N of M" panel the reader stays responsive behind.
/// `loadFromDir` itself just drives one to completion in a loop, for
/// callers (tests, anything not interactive) that don't need that.
pub const Builder = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    db: sqlite.Db,
    insert_stmt: sqlite.Stmt,
    insert_meta_stmt: sqlite.Stmt,
    /// Every `term_bank_*.json` **and** `term_meta_bank_*.json` name found
    /// in the directory, resolved up front (during `beginBuild`) so
    /// `total_files` is known from the very first `step`. `step` dispatches
    /// on the name, which is what lets one `Builder` index a term
    /// dictionary, a frequency list, or a directory holding both -- see
    /// `Dict`'s doc comment for why a frequency list is just another
    /// dictionary directory here.
    files: std.ArrayList([]u8) = .empty,
    file_idx: usize = 0,
    terms_indexed: usize = 0,
    freqs_indexed: usize = 0,
    title_buf: std.ArrayList(u8) = .empty,

    pub fn totalFiles(self: *const Builder) usize {
        return self.files.items.len;
    }

    /// True once every file has been `step`'d -- the caller should call
    /// `finish` next rather than `step` again.
    pub fn isDone(self: *const Builder) bool {
        return self.file_idx >= self.files.items.len;
    }

    /// Parses and inserts exactly one bank file -- one unit of visible
    /// progress -- choosing the parser by file name. Undefined to call once
    /// `isDone`.
    pub fn step(self: *Builder) !void {
        const name = self.files.items[self.file_idx];
        self.file_idx += 1;
        const bytes = self.dir.readFileAlloc(self.io, name, self.alloc, .limited(max_term_bank_bytes)) catch return;
        defer self.alloc.free(bytes);
        // `self.alloc`, not a per-dictionary arena: the scratch arena
        // backing this file's parse tree has nothing to do with anything
        // kept afterward -- every row is inserted straight into `db`.
        if (isTermMetaBankName(name)) {
            self.freqs_indexed += try insertTermMetaBank(self.insert_meta_stmt, self.alloc, bytes);
        } else {
            self.terms_indexed += try insertTermBank(self.insert_stmt, self.alloc, bytes);
        }
    }

    /// Commits, builds the index, writes `meta`, and returns the now-open
    /// `Dict` -- call once `isDone`. Consumes `self`; do not call
    /// `deinit` afterward.
    pub fn finish(self: *Builder) !Dict {
        self.insert_stmt.finalize();
        self.insert_meta_stmt.finalize();
        try self.db.exec("COMMIT");
        try self.db.exec(index_sql);
        try writeMeta(&self.db, self.title_buf.items);

        self.dir.close(self.io);
        for (self.files.items) |f| self.alloc.free(f);
        self.files.deinit(self.alloc);
        self.title_buf.deinit(self.alloc);

        const lookup_stmt = try self.db.prepare(lookup_sql);
        const freq_stmt = try self.db.prepare(freq_sql);
        var title_arena: std.heap.ArenaAllocator = .init(self.alloc);
        const title = readTitle(title_arena.allocator(), &self.db) catch "";
        return .{
            .db = self.db,
            .lookup_stmt = lookup_stmt,
            .freq_stmt = freq_stmt,
            .title_arena = title_arena,
            .title = title,
        };
    }

    /// Releases everything without finishing -- e.g. the reader quit, or
    /// a `step` failed, partway through a build. Do not call after
    /// `finish`.
    pub fn deinit(self: *Builder) void {
        self.insert_stmt.finalize();
        self.insert_meta_stmt.finalize();
        self.db.exec("ROLLBACK") catch {};
        self.db.close();
        self.dir.close(self.io);
        for (self.files.items) |f| self.alloc.free(f);
        self.files.deinit(self.alloc);
        self.title_buf.deinit(self.alloc);
    }
};

/// Opens `<path>/index.sqlite3` (creating it if missing), drops and
/// recreates `entries`/`meta`, and resolves the directory's
/// `term_bank_*.json` names up front -- everything a `Builder` needs
/// before its first `step`. See `isBuilt` for why a fresh rebuild always
/// starts by dropping the tables: it's what makes retrying an
/// interrupted build safe.
fn beginBuild(alloc: std.mem.Allocator, io: std.Io, path: []const u8) !Builder {
    var dir = try std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
    errdefer dir.close(io);

    const db_path = try std.mem.concatWithSentinel(alloc, u8, &.{ path, "/", db_file_name }, 0);
    defer alloc.free(db_path);
    var db = try sqlite.Db.open(db_path, sqlite.OPEN_READWRITE | sqlite.OPEN_CREATE);
    errdefer db.close();

    try db.exec(schema_sql);
    try db.exec("BEGIN");
    const insert_stmt = try db.prepare(insert_sql);
    errdefer insert_stmt.finalize();
    const insert_meta_stmt = try db.prepare(insert_meta_sql);
    errdefer insert_meta_stmt.finalize();

    var files: std.ArrayList([]u8) = .empty;
    errdefer {
        for (files.items) |f| alloc.free(f);
        files.deinit(alloc);
    }
    var title_buf: std.ArrayList(u8) = .empty;
    errdefer title_buf.deinit(alloc);

    var it = dir.iterate();
    while (it.next(io) catch null) |raw| {
        if (raw.kind != .file) continue;

        if (std.ascii.eqlIgnoreCase(raw.name, "index.json")) {
            if (dir.readFileAlloc(io, raw.name, alloc, .limited(max_index_bytes))) |bytes| {
                defer alloc.free(bytes);
                try readTitleInto(alloc, &title_buf, alloc, bytes);
            } else |_| {}
            continue;
        }
        if (!isTermBankName(raw.name) and !isTermMetaBankName(raw.name)) continue;
        try files.append(alloc, try alloc.dupe(u8, raw.name));
    }

    return .{
        .alloc = alloc,
        .io = io,
        .dir = dir,
        .db = db,
        .insert_stmt = insert_stmt,
        .insert_meta_stmt = insert_meta_stmt,
        .files = files,
        .title_buf = title_buf,
    };
}

fn readTitle(alloc: std.mem.Allocator, db: *sqlite.Db) ![]const u8 {
    var stmt = db.prepare("SELECT value FROM meta WHERE key = 'title'") catch return "";
    defer stmt.finalize();
    if (!(stmt.step() catch return "")) return "";
    return alloc.dupe(u8, stmt.columnText(0));
}

/// True if the dictionary has no entries at all -- an empty or
/// unparseable set of term banks. `ui.zig`'s `loadDict` treats that the
/// same as a missing dictionary.
pub fn isEmpty(dict: *Dict) bool {
    var stmt = dict.db.prepare("SELECT 1 FROM entries LIMIT 1") catch return true;
    defer stmt.finalize();
    const has_row = stmt.step() catch return true;
    return !has_row;
}

fn openExisting(alloc: std.mem.Allocator, db: sqlite.Db) !Dict {
    var d = db;
    errdefer d.close();
    const lookup_stmt = try d.prepare(lookup_sql);
    errdefer lookup_stmt.finalize();
    const freq_stmt = try d.prepare(freq_sql);
    errdefer freq_stmt.finalize();

    var title_arena: std.heap.ArenaAllocator = .init(alloc);
    errdefer title_arena.deinit();
    const title = readTitle(title_arena.allocator(), &d) catch "";

    return .{
        .db = d,
        .lookup_stmt = lookup_stmt,
        .freq_stmt = freq_stmt,
        .title_arena = title_arena,
        .title = title,
    };
}

/// Either the dictionary directory at `path` was already built and is
/// now open, or it wasn't and a `Builder` is ready to start on it --
/// `ui.zig`'s `loadDict` uses this to decide whether to show a
/// build-progress panel at all.
pub const Load = union(enum) {
    ready: Dict,
    building: Builder,
};

/// Opens `<path>/index.sqlite3` (an already *unzipped* Yomitan
/// dictionary directory, not the zip itself -- see the module doc
/// comment) and checks whether it already holds a finished build.
pub fn openOrBeginBuild(alloc: std.mem.Allocator, io: std.Io, path: []const u8) !Load {
    const db_path = try std.mem.concatWithSentinel(alloc, u8, &.{ path, "/", db_file_name }, 0);
    defer alloc.free(db_path);
    var db = try sqlite.Db.open(db_path, sqlite.OPEN_READWRITE | sqlite.OPEN_CREATE);

    if (isBuilt(&db)) return .{ .ready = try openExisting(alloc, db) };

    // Not built (or built by a version whose `complete` marker never
    // landed): this connection isn't needed any more -- `beginBuild`
    // reopens its own, alongside the directory handle a `Builder` also
    // needs and this check never touched.
    db.close();
    return .{ .building = try beginBuild(alloc, io, path) };
}

/// Opens the dictionary directory at `path`, building `index.sqlite3`
/// first if it isn't there yet -- blocking until that finishes. Callers
/// that want to show progress while a build runs (`ui.zig`) use
/// `openOrBeginBuild` and `Builder.step` directly instead; this is the
/// synchronous all-at-once version for everything else (tests, in
/// particular).
pub fn loadFromDir(alloc: std.mem.Allocator, io: std.Io, path: []const u8) !Dict {
    switch (try openOrBeginBuild(alloc, io, path)) {
        .ready => |d| return d,
        .building => |built| {
            var b = built;
            errdefer b.deinit();
            while (!b.isDone()) try b.step();
            return b.finish();
        },
    }
}

/// Opens an in-memory dictionary built from `term_bank_jsons` (and
/// `index_json`, for the title) -- `tests/read_tests.zig`'s way of
/// exercising `insertTermBank` / `lookup` / the whole build-then-query
/// path without touching disk. Not used by `gw-read` itself.
pub fn openMemory(
    alloc: std.mem.Allocator,
    term_bank_jsons: []const []const u8,
    term_meta_bank_jsons: []const []const u8,
    index_json: ?[]const u8,
) !Dict {
    var db = try sqlite.Db.open(":memory:", sqlite.OPEN_READWRITE | sqlite.OPEN_CREATE);
    errdefer db.close();

    try db.exec(schema_sql);
    try db.exec("BEGIN");
    const insert_stmt = try db.prepare(insert_sql);
    for (term_bank_jsons) |j| _ = try insertTermBank(insert_stmt, alloc, j);
    insert_stmt.finalize();
    const insert_meta_stmt = try db.prepare(insert_meta_sql);
    for (term_meta_bank_jsons) |j| _ = try insertTermMetaBank(insert_meta_stmt, alloc, j);
    insert_meta_stmt.finalize();
    try db.exec("COMMIT");
    try db.exec(index_sql);

    var title_buf: std.ArrayList(u8) = .empty;
    defer title_buf.deinit(alloc);
    if (index_json) |j| try readTitleInto(alloc, &title_buf, alloc, j);

    try writeMeta(&db, title_buf.items);

    const lookup_stmt = try db.prepare(lookup_sql);
    const freq_stmt = try db.prepare(freq_sql);
    var title_arena: std.heap.ArenaAllocator = .init(alloc);
    const title = readTitle(title_arena.allocator(), &db) catch "";

    return .{
        .db = db,
        .lookup_stmt = lookup_stmt,
        .freq_stmt = freq_stmt,
        .title_arena = title_arena,
        .title = title,
    };
}
