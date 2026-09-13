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
//! `<dictionary>/index.sqlite3`, indexed by `term`; every load after that
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
//! a starting byte offset, and `lookup` tries decreasing-length candidate
//! substrings from there, deinflecting each one against a small rule
//! table before giving up on it. The longest substring with any match,
//! inflected or not, wins. Each candidate is one indexed `SELECT ... WHERE
//! term = ?`, so the scan costs at most `max_scan_codepoints` queries,
//! not a walk over every entry.
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
//! **Deinflection now chains, up to `max_deinflect_depth` rule
//! applications.** `lookup` tries each candidate substring at increasing
//! depth (0 = a direct dictionary-form hit, 1 = one rule, 2 = two rules
//! chained, ...) and takes the shallowest depth that resolves to a real
//! dictionary row -- the same "simplest explanation wins" preference the
//! old single-step version had, generalized to N steps. A rule's
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
//! rules); and volitional. **Still not done:** polite negative-past
//! (-masendeshita), imperative, conditional/provisional forms (-eba/-tara),
//! keigo, a dedicated godan す-row causative row (causative "させる" is
//! only wired to its ichidan target, so 話す's causative 話させる doesn't
//! resolve -- see the causative rows below), and anything needing more
//! than `max_deinflect_depth` chained rules. Widening further is the
//! natural follow-up once this is proven against a real volume -- see
//! `docs/roadmap.md`.

const std = @import("std");
const sqlite = @import("sqlite.zig");

/// One dictionary row, always fully owned by whatever allocator produced
/// it (`lookup`'s caller-supplied `alloc`, or a test's) -- unlike the
/// in-memory version this replaced, nothing here points into a
/// long-lived arena, since there is no long-lived in-memory copy of the
/// dictionary any more. `rules` is Yomitan's space-separated deinflection
/// tags (`v1`, `v5`, `vk`, `vs`, `adj-i`, ...) -- empty for anything that
/// doesn't conjugate. `glossary` is one flattened string per sense.
pub const Entry = struct {
    term: []const u8 = "",
    reading: []const u8 = "",
    rules: []const u8 = "",
    glossary: []const []const u8 = &.{},
    sequence: i64 = 0,

    pub fn deinit(self: Entry, alloc: std.mem.Allocator) void {
        alloc.free(self.term);
        alloc.free(self.reading);
        alloc.free(self.rules);
        for (self.glossary) |g| alloc.free(g);
        alloc.free(self.glossary);
    }
};

/// Frees every entry in `entries` and the slice itself -- the whole
/// result of one `lookup` call or `queryTerm`, not a sub-slice of one
/// (freeing part of a slice that wasn't its own allocation is undefined
/// behavior; see `ui.zig`'s `wordLookupAt` for the "keep one, drop the
/// rest" case, which frees each dropped `Entry` individually instead).
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
    /// Backs `title` only -- everything else this module hands out is
    /// owned by whichever allocator the caller passed in.
    title_arena: std.heap.ArenaAllocator,
    /// `index.json`'s title, when the dictionary had one. Empty otherwise.
    title: []const u8 = "",

    pub fn deinit(self: *Dict) void {
        self.lookup_stmt.finalize();
        self.db.close();
        self.title_arena.deinit();
    }
};

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
/// `tryDeinflectAtDepth`. Causative and passive/potential, despite also
/// being "productive derivations", do *not* use this -- they collapse
/// straight to the real headword, so they carry that headword's own
/// `v1`/`v5` tag instead (see the rule table below).
pub const DeinflectRule = struct {
    kana_in: []const u8,
    kana_out: []const u8,
    rules_out: []const []const u8,
    /// Shown next to a deinflected match so it doesn't read as a typo of
    /// the dictionary form. Joined with other reasons along the same
    /// chain into `Match.reason` -- see that field's doc comment for the
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
};

/// Ceiling on how many deinflection rules may be chained for one
/// candidate substring -- see `tryDeinflectAtDepth`. 4 covers every
/// example in this module's doc comment (a causative-passive-negative
/// chain is 3 rule applications) with one step of headroom.
pub const max_deinflect_depth: usize = 4;

/// A successful lookup: how many bytes of the source text it covers, the
/// deinflection reason chain, and every matching entry.
///
/// `reason` is `null` for a direct dictionary-form hit (no rules
/// applied) -- exactly as before chaining existed. Otherwise it is a
/// **heap-allocated** string owned by the same `alloc` passed to
/// `lookup`, joining every rule reason applied along the winning chain
/// with ", " -- the caller must free it (`alloc.free(match.reason.?)`)
/// alongside `entries`; unlike the single-step version this replaced,
/// `reason` no longer points into static rule-table data.
///
/// `entries` (and each entry within it) is owned by the caller's
/// allocator -- free it with `freeEntries`, or see `ui.zig`'s
/// `wordLookupAt` for keeping just one entry and dropping the rest.
pub const Match = struct {
    len: usize,
    reason: ?[]const u8 = null,
    entries: []const Entry,
};

/// How many codepoints of `text` a click may resolve to. 16 covers every
/// realistic single-word span (this table's longest suffix plus a
/// multi-kanji stem) without the scan costing more than a glance.
pub const max_scan_codepoints: usize = 16;

/// Tries `text[0..L]` for decreasing `L`, longest first: for each length,
/// searches increasing deinflection depths via `tryDeinflectAtDepth` (0 =
/// direct dictionary-form hit, 1 = one rule applied, 2 = two rules
/// chained, ... up to `max_deinflect_depth`) and takes the shallowest
/// depth that resolves to a real dictionary row. Returns the first
/// (longest) length with any hit at any depth, or null if nothing in
/// `text`'s first `max_scan_codepoints` codepoints matches at all. Each
/// candidate tried costs one indexed SQLite query against
/// `dict.lookup_stmt`.
pub fn lookup(alloc: std.mem.Allocator, dict: *Dict, text: []const u8) !?Match {
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

        var depth: usize = 0;
        while (depth <= max_deinflect_depth) : (depth += 1) {
            if (try tryDeinflectAtDepth(alloc, dict, candidate, depth, null, &.{})) |m| {
                var found = m;
                found.len = L;
                return found;
            }
        }
    }
    return null;
}

/// One level of the iterative-deepening search `lookup` runs per
/// candidate substring.
///
/// `depth == 0` is the base case: query `candidate` directly.
/// `filter == null` means `candidate` is the original, undeinflected
/// text (`chain.len == 0`, the very first call for this length) -- every
/// row returned is accepted, exactly like a direct dictionary-form hit
/// always has been. `filter != null` means at least one rule has already
/// been applied to get here -- only rows whose `rules` column contains
/// one of `filter`'s tags are kept (`hasAnyRule`); if none survive, this
/// call reports no match. A rule with `rules_out = &.{}` can never pass
/// this filter (`hasAnyRule` against an empty list is always false), so
/// a chain that bottoms out on a non-terminal rule is correctly rejected
/// and the caller's next-`depth` (or next-`L`) attempt takes over.
///
/// `depth > 0` tries every rule (in table order) whose `kana_in` suffixes
/// `candidate`, strips it, appends `kana_out`, and recurses at
/// `depth - 1` with `filter = rule.rules_out` and `rule.reason` appended
/// to `chain`. The first rule whose recursive call succeeds wins;
/// `next_chain` is a fresh array per rule attempted so trying one rule
/// can never leak into a sibling rule's chain in the same loop.
///
/// `chain` accumulates in application order: `chain[0]` is the outermost
/// suffix stripped (the grammatical layer closest to the surface text),
/// `chain[1]` the next layer in, and so on. `Match.reason` joins them in
/// the *reverse* of that order -- innermost (closest to the dictionary
/// form) first -- with ", " between, so it reads as "what happened to
/// the text" starting from the headword outward (e.g. "食べさせない"
/// strips the outer negative first, landing on the causative form
/// "食べさせる", which the causative rule then reduces to "食べる" --
/// `chain = .{"negative", "causative"}`, joined as `"causative,
/// negative"`).
fn tryDeinflectAtDepth(
    alloc: std.mem.Allocator,
    dict: *Dict,
    candidate: []const u8,
    depth: usize,
    filter: ?[]const []const u8,
    chain: []const []const u8,
) !?Match {
    if (depth == 0) {
        const all = (try queryTerm(alloc, dict, candidate)) orelse return null;
        var entries: []const Entry = all;
        if (filter) |f| {
            var kept: std.ArrayList(Entry) = .empty;
            errdefer freeEntries(alloc, kept.items);
            for (all) |e| {
                if (hasAnyRule(e.rules, f)) {
                    try kept.append(alloc, e);
                } else {
                    e.deinit(alloc);
                }
            }
            alloc.free(all);
            if (kept.items.len == 0) {
                kept.deinit(alloc);
                return null;
            }
            entries = try kept.toOwnedSlice(alloc);
        }
        const reason = if (chain.len == 0) null else try joinChainReasons(alloc, chain);
        return .{ .len = 0, .reason = reason, .entries = entries };
    }

    for (deinflect_rules) |rule| {
        if (!std.mem.endsWith(u8, candidate, rule.kana_in)) continue;
        var buf: [128]u8 = undefined;
        const stem = candidate[0 .. candidate.len - rule.kana_in.len];
        const form = std.fmt.bufPrint(&buf, "{s}{s}", .{ stem, rule.kana_out }) catch continue;

        var next_chain: [max_deinflect_depth][]const u8 = undefined;
        std.mem.copyForwards([]const u8, next_chain[0..chain.len], chain);
        next_chain[chain.len] = rule.reason;

        if (try tryDeinflectAtDepth(
            alloc,
            dict,
            form,
            depth - 1,
            rule.rules_out,
            next_chain[0 .. chain.len + 1],
        )) |m| return m;
    }
    return null;
}

/// Joins `chain`'s reasons into one display string, innermost reason
/// first (the reverse of `chain`'s own outermost-first accumulation
/// order) -- see `tryDeinflectAtDepth`'s doc comment. Never called with
/// an empty `chain` (that case returns `reason = null` directly).
fn joinChainReasons(alloc: std.mem.Allocator, chain: []const []const u8) ![]const u8 {
    var reversed: [max_deinflect_depth][]const u8 = undefined;
    for (chain, 0..) |r, idx| reversed[chain.len - 1 - idx] = r;
    return std.mem.join(alloc, ", ", reversed[0..chain.len]);
}

/// Every entry whose `term` is exactly `term`, or null when there are
/// none. Reuses (and always resets) `dict.lookup_stmt`.
fn queryTerm(alloc: std.mem.Allocator, dict: *Dict, term: []const u8) !?[]Entry {
    dict.lookup_stmt.reset();
    try dict.lookup_stmt.bindText(1, term);

    var out: std.ArrayList(Entry) = .empty;
    errdefer freeEntries(alloc, out.items);
    while (try dict.lookup_stmt.step()) {
        try out.append(alloc, .{
            .term = try alloc.dupe(u8, dict.lookup_stmt.columnText(0)),
            .reading = try alloc.dupe(u8, dict.lookup_stmt.columnText(1)),
            .rules = try alloc.dupe(u8, dict.lookup_stmt.columnText(2)),
            .glossary = try splitGlossary(alloc, dict.lookup_stmt.columnText(3)),
            .sequence = dict.lookup_stmt.columnInt64(4),
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
/// via `insert_stmt` (`INSERT INTO entries (term, reading, rules,
/// glossary, sequence) VALUES (?, ?, ?, ?, ?)`, already prepared by the
/// caller). Returns how many rows were actually inserted -- `Builder`
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

        insertRow(
            insert_stmt,
            term,
            jsonString(row.items[1]) orelse "",
            jsonString(row.items[3]) orelse "",
            joined,
            jsonInt(row.items[6]) orelse 0,
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
) sqlite.Error!void {
    try stmt.bindText(1, term);
    try stmt.bindText(2, reading);
    try stmt.bindText(3, rules);
    try stmt.bindText(4, glossary);
    try stmt.bindInt64(5, sequence);
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

/// The SQLite file `loadFromDir` builds and queries, sitting alongside
/// the term banks it was built from.
pub const db_file_name = "index.sqlite3";

const schema_sql =
    \\DROP TABLE IF EXISTS entries;
    \\DROP TABLE IF EXISTS meta;
    \\CREATE TABLE entries (
    \\  id INTEGER PRIMARY KEY,
    \\  term TEXT NOT NULL,
    \\  reading TEXT NOT NULL,
    \\  rules TEXT NOT NULL,
    \\  glossary TEXT NOT NULL,
    \\  sequence INTEGER NOT NULL
    \\);
    \\CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
;

/// True once `build` has committed a full index -- the `meta` row it
/// writes last, after the data and the index both exist, so a build
/// interrupted partway through (crash, killed process) is never mistaken
/// for a finished one. `prepare` itself fails on a brand new database
/// (no `meta` table yet), which this treats the same as "not built".
fn isBuilt(db: *sqlite.Db) bool {
    var stmt = db.prepare("SELECT value FROM meta WHERE key = 'complete'") catch return false;
    defer stmt.finalize();
    return stmt.step() catch false;
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
    /// Every `term_bank_*.json` name found in the directory, resolved up
    /// front (during `beginBuild`) so `total_files` is known from the
    /// very first `step`.
    files: std.ArrayList([]u8) = .empty,
    file_idx: usize = 0,
    terms_indexed: usize = 0,
    title_buf: std.ArrayList(u8) = .empty,

    pub fn totalFiles(self: *const Builder) usize {
        return self.files.items.len;
    }

    /// True once every file has been `step`'d -- the caller should call
    /// `finish` next rather than `step` again.
    pub fn isDone(self: *const Builder) bool {
        return self.file_idx >= self.files.items.len;
    }

    /// Parses and inserts exactly one term bank file -- one unit of
    /// visible progress. Undefined to call once `isDone`.
    pub fn step(self: *Builder) !void {
        const name = self.files.items[self.file_idx];
        self.file_idx += 1;
        const bytes = self.dir.readFileAlloc(self.io, name, self.alloc, .limited(max_term_bank_bytes)) catch return;
        defer self.alloc.free(bytes);
        // `self.alloc`, not a per-dictionary arena: the scratch arena
        // backing this file's parse tree has nothing to do with anything
        // kept afterward -- every row is inserted straight into `db`.
        self.terms_indexed += try insertTermBank(self.insert_stmt, self.alloc, bytes);
    }

    /// Commits, builds the index, writes `meta`, and returns the now-open
    /// `Dict` -- call once `isDone`. Consumes `self`; do not call
    /// `deinit` afterward.
    pub fn finish(self: *Builder) !Dict {
        self.insert_stmt.finalize();
        try self.db.exec("COMMIT");
        try self.db.exec("CREATE INDEX IF NOT EXISTS idx_entries_term ON entries(term)");

        var meta_stmt = try self.db.prepare("INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?)");
        defer meta_stmt.finalize();
        try meta_stmt.bindText(1, "title");
        try meta_stmt.bindText(2, self.title_buf.items);
        _ = try meta_stmt.step();
        meta_stmt.reset();
        // Written last, on purpose -- see `isBuilt`.
        try meta_stmt.bindText(1, "complete");
        try meta_stmt.bindText(2, "1");
        _ = try meta_stmt.step();

        self.dir.close(self.io);
        for (self.files.items) |f| self.alloc.free(f);
        self.files.deinit(self.alloc);
        self.title_buf.deinit(self.alloc);

        const lookup_stmt = try self.db.prepare(
            "SELECT term, reading, rules, glossary, sequence FROM entries WHERE term = ?",
        );
        var title_arena: std.heap.ArenaAllocator = .init(self.alloc);
        const title = readTitle(title_arena.allocator(), &self.db) catch "";
        return .{ .db = self.db, .lookup_stmt = lookup_stmt, .title_arena = title_arena, .title = title };
    }

    /// Releases everything without finishing -- e.g. the reader quit, or
    /// a `step` failed, partway through a build. Do not call after
    /// `finish`.
    pub fn deinit(self: *Builder) void {
        self.insert_stmt.finalize();
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
    const insert_stmt = try db.prepare(
        "INSERT INTO entries (term, reading, rules, glossary, sequence) VALUES (?, ?, ?, ?, ?)",
    );
    errdefer insert_stmt.finalize();

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
        if (!isTermBankName(raw.name)) continue;
        try files.append(alloc, try alloc.dupe(u8, raw.name));
    }

    return .{
        .alloc = alloc,
        .io = io,
        .dir = dir,
        .db = db,
        .insert_stmt = insert_stmt,
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
    const lookup_stmt = try d.prepare("SELECT term, reading, rules, glossary, sequence FROM entries WHERE term = ?");
    errdefer lookup_stmt.finalize();

    var title_arena: std.heap.ArenaAllocator = .init(alloc);
    errdefer title_arena.deinit();
    const title = readTitle(title_arena.allocator(), &d) catch "";

    return .{ .db = d, .lookup_stmt = lookup_stmt, .title_arena = title_arena, .title = title };
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
pub fn openMemory(alloc: std.mem.Allocator, term_bank_jsons: []const []const u8, index_json: ?[]const u8) !Dict {
    var db = try sqlite.Db.open(":memory:", sqlite.OPEN_READWRITE | sqlite.OPEN_CREATE);
    errdefer db.close();

    try db.exec(schema_sql);
    try db.exec("BEGIN");
    const insert_stmt = try db.prepare(
        "INSERT INTO entries (term, reading, rules, glossary, sequence) VALUES (?, ?, ?, ?, ?)",
    );
    for (term_bank_jsons) |j| _ = try insertTermBank(insert_stmt, alloc, j);
    insert_stmt.finalize();
    try db.exec("COMMIT");
    try db.exec("CREATE INDEX IF NOT EXISTS idx_entries_term ON entries(term)");

    var title_buf: std.ArrayList(u8) = .empty;
    defer title_buf.deinit(alloc);
    if (index_json) |j| try readTitleInto(alloc, &title_buf, alloc, j);

    var meta_stmt = try db.prepare("INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?)");
    try meta_stmt.bindText(1, "title");
    try meta_stmt.bindText(2, title_buf.items);
    _ = try meta_stmt.step();
    meta_stmt.reset();
    try meta_stmt.bindText(1, "complete");
    try meta_stmt.bindText(2, "1");
    _ = try meta_stmt.step();
    meta_stmt.finalize();

    const lookup_stmt = try db.prepare("SELECT term, reading, rules, glossary, sequence FROM entries WHERE term = ?");
    var title_arena: std.heap.ArenaAllocator = .init(alloc);
    const title = readTitle(title_arena.allocator(), &db) catch "";

    return .{ .db = db, .lookup_stmt = lookup_stmt, .title_arena = title_arena, .title = title };
}
