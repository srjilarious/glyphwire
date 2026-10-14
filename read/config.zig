// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: GPL-3.0-or-later

//! Loads gw-read's startup config, `~/.config/glyphwire/read.conf.lua` --
//! a Lua script that assigns a global `config` table, the same shape and
//! the same loader skeleton `ls.conf.lua` and `zoe.conf.lua` use.
//!
//! Split into the `read_support` module (like `read/pages.zig` and
//! `read/zoom.zig`) so `tests/read_tests.zig` can exercise the parse
//! without a running client.
//!
//! See `read/read.conf.template.lua` for the annotated reference copy.

const std = @import("std");
const luaconf = @import("luaconf");
const Lua = luaconf.Lua;
const zoom = @import("glyphwire").zoom;
const cache = @import("cache.zig");
const glyphwire = @import("glyphwire");
const ai = @import("ai.zig");
const anki = @import("anki.zig");
const mokuro = @import("mokuro.zig");

pub const conf_name = "read.conf.lua";
const conf: luaconf.Conf = .{ .prog = "gw-read", .name = conf_name };

/// Which way a page turn goes. Manga reads right-to-left, which is the
/// default because that's what this reader was built for; western comics
/// and scanned books want `ltr`. Toggled at runtime with `d`, and the
/// toggle is what gets remembered per book (see state.zig).
pub const Direction = enum {
    rtl,
    ltr,

    pub fn parse(text: []const u8) ?Direction {
        if (std.mem.eql(u8, text, "rtl")) return .rtl;
        if (std.mem.eql(u8, text, "ltr")) return .ltr;
        return null;
    }

    pub fn name(self: Direction) []const u8 {
        return @tagName(self);
    }

    /// The label the statusline shows -- an arrow reads faster than the
    /// three letters do when you're checking you're paging the right way.
    pub fn label(self: Direction) []const u8 {
        return switch (self) {
            .rtl => "←",
            .ltr => "→",
        };
    }
};

pub const ReadConfig = struct {
    /// Sizing mode a freshly opened book starts in.
    mode: zoom.Mode = .fit_screen,
    /// Page-turn direction for a book with no remembered one.
    direction: Direction = .rtl,
    /// How many pages of decoded image the session keeps resident (see
    /// cache.zig). 8 covers "flip back a few panels to re-read a line"
    /// without holding a whole volume.
    cache_pages: usize = 8,
    /// How many pages ahead, in reading order, to load before they're
    /// asked for. 1 hides the load behind the page turn; higher values
    /// help on a slow disk at the cost of cache slots.
    prefetch: usize = 1,
    /// What `]` / `[` jump by.
    jump_pages: usize = 5,
    /// Ceiling on the zoom factor. Raising it costs server-side memory
    /// quadratically -- see zoom.zig's module comment. Raised from the
    /// original 4.0 default (2026-09); `zoom_max_ceiling` below is the
    /// hard cap on what a `read.conf.lua` override can push it to.
    max_zoom: f32 = 8.0,
    /// Whether a fit mode may scale a page up past its natural size.
    upscale: bool = true,
    /// Cells panned per arrow key / `hjkl` press when the page overflows.
    pan_step: usize = 3,
    /// Resume where you left off. `false` opens every book at page 1 and
    /// stops writing the state file entirely.
    remember_position: bool = true,

    /// Read a book's mokuro OCR sidecar when one is found beside it (or
    /// packed inside it). `false` ignores it entirely -- no dialog, no
    /// region hints, no OCR marker on the statusline.
    ocr: bool = true,
    /// Whether the text regions start outlined on the page. Off by
    /// default: the outlines are a "where can I click" hint, and a page
    /// covered in boxes is not what a reader is for. `o` toggles it.
    ocr_hints: bool = false,
    /// The dialog's opacity while the peek key (`z`) is held, 0..1. The
    /// point is to read the artwork *through* the text -- mokuro drops
    /// furigana, so checking the page itself is a normal part of reading
    /// with this on. 0 is fully transparent, 1 disables the peek.
    ocr_peek: f32 = 0.5,
    /// Widest the text dialog gets, in cells. Japanese sets two cells per
    /// character, so 40 is about 20 characters a line -- close to a
    /// bubble's own column length, which is what makes the re-wrap read
    /// naturally rather than as one long ribbon.
    ocr_dialog_cols: usize = 40,
    /// Tallest a *vertical* dialog's column gets, in characters -- the
    /// vertical counterpart of `ocr_dialog_cols`. A bubble longer than
    /// this runs on into another column to the left. Clamped to the
    /// window on screen, so a scaled dialog wraps sooner rather than
    /// running off the bottom.
    ocr_dialog_rows: usize = 12,
    /// How the dialog sets a bubble's text when a book has no remembered
    /// choice: `"auto"` (the default) follows each bubble's own vertical
    /// flag from mokuro, `"vertical"` / `"horizontal"` force one way.
    /// `v` cycles it, and the choice is remembered per book.
    ocr_layout: mokuro.Layout = .auto,
    /// Where the dialog goes. `"margin"` (the default) puts it in the
    /// empty columns beside a fitted page when it fits there -- re-wrapped
    /// narrower, or into taller columns, if that's what it takes -- so it
    /// covers no artwork; `"bubble"` always puts it over the page next
    /// to its bubble. Either way a dialog that can't go in a margin sits
    /// by its bubble.
    ocr_dialog_placement: DialogPlacement = .margin,

    /// Path to an already-*unzipped* Yomitan-format dictionary directory
    /// (e.g. a Jitendex download, https://jitendex.org, extracted once
    /// by hand) for word lookup out of the OCR dialog. Empty -- the
    /// default -- leaves the feature off entirely: no load at startup,
    /// no click handling in the dialog.
    dictionary: []const u8 = "",
    /// Path to a second unzipped Yomitan dictionary directory holding
    /// *frequency* data -- `term_meta_bank_*.json` rows. Empty (the
    /// default) leaves ranking exactly as it was.
    ///
    /// It is a separate key rather than a second entry in `dictionary`
    /// because the two are separate downloads: a term dictionary like
    /// Jitendex ships no frequency data at all, and the frequency lists
    /// Yomitan users install (JPDB, Innocent Corpus, BCCWJ, …) ship no
    /// definitions. Each directory keeps its own `index.sqlite3`, so
    /// swapping the frequency list doesn't force the term index to be
    /// rebuilt.
    frequency_dictionary: []const u8 = "",
    /// Which direction `frequency_dictionary`'s numbers run, because the
    /// format does not say: `"rank"` (the default) means lower is more
    /// common, the way a ranked list like JPDB or Innocent Corpus is
    /// numbered; `"count"` means higher is more common, the way a raw
    /// corpus tally is. Yomitan makes the same thing a per-dictionary
    /// setting rather than guessing, and guessing wrong silently inverts
    /// every ranking.
    frequency_order: FrequencyOrder = .rank,
    /// Default size of the lookup panel's title (the looked-up term) --
    /// `"1x"` (normal), `"1.5x"`, or `"2x"`, drawn via `write_text`'s
    /// `scale` (see `core.TextScale`'s doc comment). `s` cycles it at
    /// runtime for the session; this is only the size a freshly opened
    /// book's lookup panel starts at.
    dictionary_title_scale: glyphwire.TextScale = .x1,
    /// Size of the OCR dialog's text -- same spellings and same
    /// `write_text` `scale` as `dictionary_title_scale`. `S` cycles it at
    /// runtime for the session. `ocr_dialog_cols` keeps meaning the wrap
    /// width at 1x, so a scaled dialog wraps to the same number of
    /// characters a line and grows wider rather than wrapping sooner.
    ocr_text_scale: glyphwire.TextScale = .x1,

    /// AI translation lookup of the whole OCR bubble (`a` in the open
    /// dialog). Off by default: turning it on is what makes OCR text
    /// leave the machine, so it has to be asked for. See ai.zig.
    ai_lookup: bool = false,
    ai_provider: ai.Provider = .openai,
    /// Empty means the provider's own default (`ai.Provider.defaultModel`).
    ai_model: []const u8 = "",
    /// Empty means the provider's own default URL
    /// (`ai.Provider.defaultEndpoint`) -- set it to reach an Ollama on
    /// another host, or an OpenAI-compatible proxy.
    ai_endpoint: []const u8 = "",
    /// The *name* of the environment variable holding the API key, never
    /// the key itself, so a config file can be shared or committed.
    /// Empty means the provider's own (`ai.Provider.defaultKeyEnv`:
    /// `OPENAI_API_KEY` / `ANTHROPIC_API_KEY`). Ollama and `claude_code`
    /// don't use one.
    ai_api_key_env: []const u8 = "",
    /// The user's reading-level/style instruction, appended to the fixed
    /// app rules in the request's instructions (`ai.buildPrompt`).
    ai_prompt: []const u8 = ai.default_style,
    /// Send the previous and next bubble in reading order as context.
    ai_include_neighbor_dialog: bool = true,
    /// Send the book's title (its file name, never the path) and the page
    /// number.
    ai_include_book_info: bool = false,
    /// Ask before the first send of a session, naming where the text is
    /// going. Cache hits never ask -- nothing leaves the machine.
    ai_confirm_before_send: bool = true,
    /// Keep answers in `read.ai-cache.sqlite3` next to the config, so
    /// reopening a bubble is instant and costs no tokens.
    ai_cache: bool = true,

    /// Anki card mining (`c` with a lookup or AI answer showing). On by
    /// default: nothing is sent anywhere until a card is confirmed, and
    /// then only to the AnkiConnect at `anki_url`. See anki.zig.
    anki_cards: bool = true,
    /// AnkiConnect's address -- desktop Anki with the add-on running.
    anki_url: []const u8 = anki.default_url,
    anki_deck: []const u8 = anki.default_deck,
    /// The note type. Its field names are what `anki_fields` maps.
    anki_model: []const u8 = anki.default_model,
    /// Which note field each piece of card data goes to. The default is
    /// jidoujisho's `jidoujisho Kinomoto` note type (`anki.default_fields`).
    /// Kept in `anki.Source` order, whatever order the Lua table had, so
    /// the preview lists fields the same way every time.
    anki_fields: []const anki.FieldMap = &anki.default_fields,
    /// Space-separated tags added to every card.
    anki_tags: []const u8 = "gw-read",
    /// Let a card whose first field matches an existing note in the deck
    /// through. Off: Anki's duplicate check stops it, and the preview
    /// reports why.
    anki_allow_duplicates: bool = false,
    /// Ask Anki to sync to AnkiWeb after every added card.
    anki_sync_after_add: bool = false,
    /// Where the word's audio comes from: `{term}` and `{reading}` are
    /// filled in. Empty turns audio off. JapanesePod101 by default, the
    /// source jidoujisho uses.
    anki_audio_url: []const u8 = anki.jpod_audio_url,
    /// The cropped image is scaled down (never up) to fit these, in
    /// pixels, and saved as a JPEG at `anki_image_quality` (1..100).
    anki_image_max_width: usize = 800,
    anki_image_max_height: usize = 800,
    anki_image_quality: usize = 85,

    /// `anki_fields` when it came from the Lua file; freed by `deinit`
    /// (the field names themselves are in `owned`).
    owned_fields: ?[]anki.FieldMap = null,

    /// Every string field above that `load` duped out of the Lua state,
    /// freed by `deinit`. Tracked as a list rather than by comparing each
    /// field against its default, so a default can stay a string literal.
    owned: std.ArrayList([]const u8) = .empty,

    pub fn deinit(self: *ReadConfig, alloc: std.mem.Allocator) void {
        for (self.owned.items) |s| alloc.free(s);
        self.owned.deinit(alloc);
        if (self.owned_fields) |f| alloc.free(f);
        self.* = .{};
    }

    /// The model actually sent: `ai_model`, or the provider's default.
    pub fn aiModel(self: *const ReadConfig) []const u8 {
        return if (self.ai_model.len > 0) self.ai_model else self.ai_provider.defaultModel();
    }

    /// The URL actually posted to (or, for `claude_code`, the executable
    /// run): `ai_endpoint`, or the provider's default.
    pub fn aiEndpoint(self: *const ReadConfig) []const u8 {
        return if (self.ai_endpoint.len > 0) self.ai_endpoint else self.ai_provider.defaultEndpoint();
    }

    /// The environment variable the API key is read from: `ai_api_key_env`,
    /// or the provider's default. Empty for a provider that takes none.
    pub fn aiApiKeyEnv(self: *const ReadConfig) []const u8 {
        return if (self.ai_api_key_env.len > 0) self.ai_api_key_env else self.ai_provider.defaultKeyEnv();
    }

    /// The zoom limits this config implies, handed to every `zoom.layout`
    /// call.
    pub fn limits(self: ReadConfig) zoom.Limits {
        var l: zoom.Limits = .{};
        l.max_scale = self.max_zoom;
        l.upscale = self.upscale;
        return l;
    }
};

/// `ReadConfig.ocr_dialog_placement`.
pub const DialogPlacement = enum { margin, bubble };

pub const zoom_max_ceiling: f32 = 16.0;
/// Bounds on `ocr_dialog_cols`. The floor is "a wrap that isn't one
/// character per line"; the ceiling is the widest a floating panel can be
/// before it stops being a panel.
pub const ocr_dialog_cols_min: usize = 12;
pub const ocr_dialog_cols_max: usize = 200;
/// Bounds on `ocr_dialog_rows`, in characters a column. The floor keeps a
/// column from being a few characters of a long bubble spread over a
/// dozen columns.
pub const ocr_dialog_rows_min: usize = 4;
pub const ocr_dialog_rows_max: usize = 100;
pub const pan_step_max: usize = 64;
pub const jump_pages_max: usize = 1000;
pub const prefetch_max: usize = 8;
pub const anki_image_side_max: usize = 4096;

/// Outcome of `load`: the parsed config plus, on a Lua load/run failure,
/// an owned diagnostic string. `config` still holds whatever ran before
/// the error (Lua stops at the failing line), so a caller can use the
/// partial result and surface `err`.
///
/// `deinit` frees both. A caller keeping the config past the result
/// takes it with `takeConfig`, which leaves nothing behind for `deinit`
/// to free a second time.
pub const LoadResult = struct {
    config: ReadConfig = .{},
    err: ?[]const u8 = null,

    pub fn takeConfig(self: *LoadResult) ReadConfig {
        const taken = self.config;
        self.config = .{};
        return taken;
    }

    pub fn deinit(self: *LoadResult, alloc: std.mem.Allocator) void {
        if (self.err) |e| alloc.free(e);
        self.config.deinit(alloc);
    }
};

/// Parses `source` (the contents of `read.conf.lua`, null-terminated).
/// Unknown keys are ignored; a key of the wrong type or out of range is
/// clamped or dropped with a warning on stderr. Only a genuine Lua-init
/// failure or a syntax/runtime error populates `LoadResult.err`.
pub fn load(alloc: std.mem.Allocator, source: [:0]const u8) LoadResult {
    var result: LoadResult = .{};
    var ctx: Apply = .{ .alloc = alloc, .cfg = &result.config };
    result.err = conf.run(alloc, source, &ctx, Apply.apply);
    return result;
}

const Apply = struct {
    alloc: std.mem.Allocator,
    cfg: *ReadConfig,

    fn apply(self: *Apply, lua: *Lua) void {
        const cfg = self.cfg;
        if (conf.string(lua, "mode")) |v| {
            if (parseMode(v)) |m| cfg.mode = m else conf.warn("`mode` = '{s}' is not a sizing mode; ignored", .{v});
        }
        if (conf.string(lua, "direction")) |v| {
            if (Direction.parse(v)) |d| cfg.direction = d else conf.warn("`direction` = '{s}' is not 'rtl' or 'ltr'; ignored", .{v});
        }
        if (conf.uint(lua, usize, "cache_pages", .{ .min = 1, .max = cache.max_capacity })) |v| cfg.cache_pages = v;
        if (conf.uint(lua, usize, "prefetch", .{ .max = prefetch_max })) |v| cfg.prefetch = v;
        if (conf.uint(lua, usize, "jump_pages", .{ .min = 1, .max = jump_pages_max })) |v| cfg.jump_pages = v;
        if (conf.uint(lua, usize, "pan_step", .{ .min = 1, .max = pan_step_max })) |v| cfg.pan_step = v;
        if (conf.number(lua, f32, "max_zoom", .{ .min = 1.0, .max = zoom_max_ceiling })) |v| cfg.max_zoom = v;
        if (conf.boolean(lua, "upscale")) |v| cfg.upscale = v;
        if (conf.boolean(lua, "remember_position")) |v| cfg.remember_position = v;
        if (conf.boolean(lua, "ocr")) |v| cfg.ocr = v;
        if (conf.boolean(lua, "ocr_hints")) |v| cfg.ocr_hints = v;
        if (conf.number(lua, f32, "ocr_peek", .{ .min = 0.0, .max = 1.0 })) |v| cfg.ocr_peek = v;
        if (conf.uint(lua, usize, "ocr_dialog_cols", .{ .min = ocr_dialog_cols_min, .max = ocr_dialog_cols_max })) |v| cfg.ocr_dialog_cols = v;
        if (conf.uint(lua, usize, "ocr_dialog_rows", .{ .min = ocr_dialog_rows_min, .max = ocr_dialog_rows_max })) |v| cfg.ocr_dialog_rows = v;
        if (conf.enumValue(lua, DialogPlacement, "ocr_dialog_placement")) |v| cfg.ocr_dialog_placement = v;
        if (conf.string(lua, "ocr_layout")) |v| {
            if (mokuro.Layout.parse(v)) |l| cfg.ocr_layout = l else conf.warn("`ocr_layout` = '{s}' is not 'auto'/'vertical'/'horizontal'; ignored", .{v});
        }
        // Duped immediately, unlike `mode`/`direction`: `conf.string`'s
        // result points into Lua's own string and doesn't outlive `load`.
        if (conf.string(lua, "dictionary")) |v| cfg.dictionary = self.own(v, "");
        if (conf.string(lua, "frequency_dictionary")) |v| cfg.frequency_dictionary = self.own(v, "");
        if (conf.string(lua, "frequency_order")) |v| {
            if (parseFrequencyOrder(v)) |o| cfg.frequency_order = o else conf.warn("`frequency_order` = '{s}' is not 'rank'/'count'; ignored", .{v});
        }
        if (conf.string(lua, "dictionary_title_scale")) |v| {
            if (parseTitleScale(v)) |s| cfg.dictionary_title_scale = s else conf.warn("`dictionary_title_scale` = '{s}' is not '1x'/'1.5x'/'2x'/'3x'; ignored", .{v});
        }
        if (conf.string(lua, "ocr_text_scale")) |v| {
            if (parseTitleScale(v)) |s| cfg.ocr_text_scale = s else conf.warn("`ocr_text_scale` = '{s}' is not '1x'/'1.5x'/'2x'/'3x'; ignored", .{v});
        }

        if (conf.boolean(lua, "ai_lookup")) |v| cfg.ai_lookup = v;
        if (conf.string(lua, "ai_provider")) |v| {
            if (ai.Provider.parse(v)) |p| cfg.ai_provider = p else conf.warn("`ai_provider` = '{s}' is not 'openai', 'anthropic', 'claude_code' or 'ollama'; ignored", .{v});
        }
        if (conf.string(lua, "ai_model")) |v| cfg.ai_model = self.own(v, "");
        if (conf.string(lua, "ai_endpoint")) |v| cfg.ai_endpoint = self.own(v, "");
        if (conf.string(lua, "ai_api_key_env")) |v| cfg.ai_api_key_env = self.own(v, cfg.ai_api_key_env);
        if (conf.string(lua, "ai_prompt")) |v| cfg.ai_prompt = self.own(v, cfg.ai_prompt);
        if (conf.boolean(lua, "ai_include_neighbor_dialog")) |v| cfg.ai_include_neighbor_dialog = v;
        if (conf.boolean(lua, "ai_include_book_info")) |v| cfg.ai_include_book_info = v;
        if (conf.boolean(lua, "ai_confirm_before_send")) |v| cfg.ai_confirm_before_send = v;
        if (conf.boolean(lua, "ai_cache")) |v| cfg.ai_cache = v;

        if (conf.boolean(lua, "anki_cards")) |v| cfg.anki_cards = v;
        if (conf.string(lua, "anki_url")) |v| cfg.anki_url = self.own(v, cfg.anki_url);
        if (conf.string(lua, "anki_deck")) |v| cfg.anki_deck = self.own(v, cfg.anki_deck);
        if (conf.string(lua, "anki_model")) |v| cfg.anki_model = self.own(v, cfg.anki_model);
        if (conf.string(lua, "anki_tags")) |v| cfg.anki_tags = self.own(v, cfg.anki_tags);
        if (conf.boolean(lua, "anki_allow_duplicates")) |v| cfg.anki_allow_duplicates = v;
        if (conf.boolean(lua, "anki_sync_after_add")) |v| cfg.anki_sync_after_add = v;
        if (conf.string(lua, "anki_audio_url")) |v| cfg.anki_audio_url = self.own(v, cfg.anki_audio_url);
        const image_side: luaconf.Range(usize) = .{ .min = 64, .max = anki_image_side_max };
        if (conf.uint(lua, usize, "anki_image_max_width", image_side)) |v| cfg.anki_image_max_width = v;
        if (conf.uint(lua, usize, "anki_image_max_height", image_side)) |v| cfg.anki_image_max_height = v;
        if (conf.uint(lua, usize, "anki_image_quality", .{ .min = 1, .max = 100 })) |v| cfg.anki_image_quality = v;
        loadAnkiFields(self.alloc, lua, cfg);

        // A `cache_pages` smaller than what the prefetch wants resident means
        // every prefetched page evicts the one being read. Nudge rather than
        // reject: the intent ("keep a small cache") is still honoured.
        const needed = cfg.prefetch + 2;
        if (cfg.cache_pages < needed) {
            conf.warn("`cache_pages` {d} is below prefetch + 2; raised to {d}", .{ cfg.cache_pages, needed });
            cfg.cache_pages = needed;
        }
    }

    fn own(self: *Apply, v: []const u8, fallback: []const u8) []const u8 {
        return ownString(self.alloc, self.cfg, v, fallback);
    }
};

/// `anki_fields = { ["Note field"] = "source", ... }`. A source name
/// that isn't an `anki.Source` is warned about and skipped; `false`
/// leaves a field out, which is how a default mapping is trimmed without
/// retyping it. An empty result keeps the default.
fn loadAnkiFields(alloc: std.mem.Allocator, lua: *Lua, cfg: *ReadConfig) void {
    _ = lua.getField(-1, "anki_fields");
    defer lua.pop(1);
    if (!lua.isTable(-1)) {
        if (!lua.isNil(-1))
            conf.warn("`anki_fields` is not a table; ignored", .{});
        return;
    }

    var out: std.ArrayList(anki.FieldMap) = .empty;
    defer out.deinit(alloc);
    lua.pushNil();
    while (lua.next(-2)) {
        // Key at -2, value at -1. `toString` only on a real string key:
        // it would convert a number key in place and break `next`.
        defer lua.pop(1);
        if (lua.typeOf(-2) != .string) {
            conf.warn("`anki_fields` entry with a non-string key; ignored", .{});
            continue;
        }
        const field = lua.toString(-2) catch continue;
        if (lua.typeOf(-1) == .boolean and !lua.toBoolean(-1)) continue;
        if (lua.typeOf(-1) != .string) {
            conf.warn("anki_fields[\"{s}\"] must be a source name; ignored", .{ field });
            continue;
        }
        const name = lua.toString(-1) catch continue;
        const source = anki.Source.parse(name) orelse {
            conf.warn("anki_fields[\"{s}\"] = '{s}' is not a card source; ignored", .{ field, name });
            continue;
        };
        const owned = ownString(alloc, cfg, field, "");
        if (owned.len == 0) continue;
        out.append(alloc, .{ .field = owned, .source = source }) catch return;
    }
    if (out.items.len == 0) {
        conf.warn("`anki_fields` maps nothing; keeping the default", .{});
        return;
    }
    std.mem.sort(anki.FieldMap, out.items, {}, struct {
        fn lessThan(_: void, a: anki.FieldMap, b: anki.FieldMap) bool {
            if (a.source != b.source) return @intFromEnum(a.source) < @intFromEnum(b.source);
            return std.mem.lessThan(u8, a.field, b.field);
        }
    }.lessThan);
    const fields = out.toOwnedSlice(alloc) catch return;
    cfg.owned_fields = fields;
    cfg.anki_fields = fields;
}

/// The `mode` key's accepted spellings. Hyphenated because that's how the
/// keys read in a config file; `zoom.Mode`'s own tag names use
/// underscores.
pub fn parseMode(name: []const u8) ?zoom.Mode {
    if (std.mem.eql(u8, name, "fit") or std.mem.eql(u8, name, "fit-screen") or std.mem.eql(u8, name, "fit_screen"))
        return .fit_screen;
    if (std.mem.eql(u8, name, "fit-width") or std.mem.eql(u8, name, "fit_width")) return .fit_width;
    if (std.mem.eql(u8, name, "fit-height") or std.mem.eql(u8, name, "fit_height")) return .fit_height;
    if (std.mem.eql(u8, name, "natural") or std.mem.eql(u8, name, "1:1")) return .natural;
    if (std.mem.eql(u8, name, "free") or std.mem.eql(u8, name, "zoom")) return .free;
    return null;
}

/// Which way a frequency dictionary's numbers run -- see
/// `ReadConfig.frequency_order`.
pub const FrequencyOrder = enum {
    /// Lower is more common (JPDB, Innocent Corpus, BCCWJ rank files).
    rank,
    /// Higher is more common (a raw corpus occurrence count).
    count,

    /// Whether `a` names a more common word than `b` under this order.
    pub fn moreCommon(self: FrequencyOrder, a: i64, b: i64) bool {
        return switch (self) {
            .rank => a < b,
            .count => a > b,
        };
    }
};

/// The `frequency_order` key's accepted spellings.
pub fn parseFrequencyOrder(text: []const u8) ?FrequencyOrder {
    if (std.mem.eql(u8, text, "rank")) return .rank;
    if (std.mem.eql(u8, text, "count")) return .count;
    return null;
}

/// The `dictionary_title_scale` key's accepted spellings -- config-file
/// friendly ("1x"/"1.5x"/"2x"/"3x"), not necessarily `core.TextScale`'s wire
/// tag names (`x1`/`x1_5`/`x2`/`x3`).
pub fn parseTitleScale(text: []const u8) ?glyphwire.TextScale {
    if (std.mem.eql(u8, text, "1x")) return .x1;
    if (std.mem.eql(u8, text, "1.5x")) return .x1_5;
    if (std.mem.eql(u8, text, "2x")) return .x2;
    if (std.mem.eql(u8, text, "3x")) return .x3;
    return null;
}

/// `load`, but reading the file from glyphwire's config directory
/// (`glyphwire.configDirPath`). A missing file / missing config home is
/// the normal case: all defaults, no error, nothing logged.
pub fn loadFromDir(alloc: std.mem.Allocator, io: std.Io, config_dir: []const u8) ReadConfig {
    const src = conf.readIn(alloc, io, config_dir) catch return .{};
    defer alloc.free(src);

    var result = load(alloc, src);
    defer result.deinit(alloc);
    if (result.err) |e| conf.logRunError(e);
    return result.takeConfig();
}

/// Dupes `v` and records it in `cfg.owned` so `ReadConfig.deinit` frees
/// it. Out of memory keeps `fallback` rather than failing the whole load.
fn ownString(alloc: std.mem.Allocator, cfg: *ReadConfig, v: []const u8, fallback: []const u8) []const u8 {
    const copy = alloc.dupe(u8, v) catch return fallback;
    cfg.owned.append(alloc, copy) catch {
        alloc.free(copy);
        return fallback;
    };
    return copy;
}

