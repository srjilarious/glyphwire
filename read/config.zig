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
const ziglua = @import("ziglua");
const Lua = ziglua.Lua;
const zoom = @import("zoom.zig");
const cache = @import("cache.zig");
const glyphwire = @import("glyphwire");
const ai = @import("ai.zig");

const conf_name = "read.conf.lua";

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

    /// Path to an already-*unzipped* Yomitan-format dictionary directory
    /// (e.g. a Jitendex download, https://jitendex.org, extracted once
    /// by hand) for word lookup out of the OCR dialog. Empty -- the
    /// default -- leaves the feature off entirely: no load at startup,
    /// no click handling in the dialog.
    dictionary: []const u8 = "",
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
    /// Ollama doesn't use one.
    ai_api_key_env: []const u8 = "OPENAI_API_KEY",
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

    /// Every string field above that `load` duped out of the Lua state,
    /// freed by `deinit`. Tracked as a list rather than by comparing each
    /// field against its default, so a default can stay a string literal.
    owned: std.ArrayList([]const u8) = .empty,

    pub fn deinit(self: *ReadConfig, alloc: std.mem.Allocator) void {
        for (self.owned.items) |s| alloc.free(s);
        self.owned.deinit(alloc);
        self.* = .{};
    }

    /// The model actually sent: `ai_model`, or the provider's default.
    pub fn aiModel(self: *const ReadConfig) []const u8 {
        return if (self.ai_model.len > 0) self.ai_model else self.ai_provider.defaultModel();
    }

    /// The URL actually posted to: `ai_endpoint`, or the provider's default.
    pub fn aiEndpoint(self: *const ReadConfig) []const u8 {
        return if (self.ai_endpoint.len > 0) self.ai_endpoint else self.ai_provider.defaultEndpoint();
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

pub const zoom_max_ceiling: f32 = 16.0;
/// Bounds on `ocr_dialog_cols`. The floor is "a wrap that isn't one
/// character per line"; the ceiling is the widest a floating panel can be
/// before it stops being a panel.
pub const ocr_dialog_cols_min: usize = 12;
pub const ocr_dialog_cols_max: usize = 200;
pub const pan_step_max: usize = 64;
pub const jump_pages_max: usize = 1000;
pub const prefetch_max: usize = 8;

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
        const conf = self.config;
        self.config = .{};
        return conf;
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

    const lua = Lua.init(alloc) catch {
        result.err = alloc.dupe(u8, conf_name ++ ": could not create Lua interpreter") catch null;
        return result;
    };
    defer lua.deinit();
    lua.openLibs();

    lua.doString(source) catch {
        const msg = lua.toString(-1) catch conf_name ++ ": unknown Lua error";
        result.err = alloc.dupe(u8, msg) catch null;
        return result;
    };

    _ = lua.getGlobal("config") catch return result;
    defer lua.pop(1);
    if (!lua.isTable(-1)) {
        if (!lua.isNil(-1))
            std.log.warn("gw-read: {s} `config` is not a table; using defaults", .{conf_name});
        return result;
    }

    if (stringField(lua, "mode")) |v| {
        if (parseMode(v)) |m| result.config.mode = m else std.log.warn(
            "gw-read: {s} `mode` = '{s}' is not a sizing mode; ignored",
            .{ conf_name, v },
        );
    }
    if (stringField(lua, "direction")) |v| {
        if (Direction.parse(v)) |d| result.config.direction = d else std.log.warn(
            "gw-read: {s} `direction` = '{s}' is not 'rtl' or 'ltr'; ignored",
            .{ conf_name, v },
        );
    }
    if (uintField(lua, "cache_pages")) |v|
        result.config.cache_pages = clampUint("cache_pages", v, 1, cache.max_capacity);
    if (uintField(lua, "prefetch")) |v|
        result.config.prefetch = clampUint("prefetch", v, 0, prefetch_max);
    if (uintField(lua, "jump_pages")) |v|
        result.config.jump_pages = clampUint("jump_pages", v, 1, jump_pages_max);
    if (uintField(lua, "pan_step")) |v|
        result.config.pan_step = clampUint("pan_step", v, 1, pan_step_max);
    if (numberField(lua, "max_zoom")) |v|
        result.config.max_zoom = clampZoom(v);
    if (boolField(lua, "upscale")) |v| result.config.upscale = v;
    if (boolField(lua, "remember_position")) |v| result.config.remember_position = v;
    if (boolField(lua, "ocr")) |v| result.config.ocr = v;
    if (boolField(lua, "ocr_hints")) |v| result.config.ocr_hints = v;
    if (numberField(lua, "ocr_peek")) |v| result.config.ocr_peek = clampPeek(v);
    if (uintField(lua, "ocr_dialog_cols")) |v|
        result.config.ocr_dialog_cols = clampUint("ocr_dialog_cols", v, ocr_dialog_cols_min, ocr_dialog_cols_max);
    // Duped immediately, unlike `mode`/`direction`: `stringField`'s
    // result points into Lua's own string and doesn't outlive `load`.
    if (stringField(lua, "dictionary")) |v|
        result.config.dictionary = ownString(alloc, &result.config, v, "");
    if (stringField(lua, "dictionary_title_scale")) |v| {
        if (parseTitleScale(v)) |s| result.config.dictionary_title_scale = s else std.log.warn(
            "gw-read: {s} `dictionary_title_scale` = '{s}' is not '1x'/'1.5x'/'2x'/'3x'; ignored",
            .{ conf_name, v },
        );
    }
    if (stringField(lua, "ocr_text_scale")) |v| {
        if (parseTitleScale(v)) |s| result.config.ocr_text_scale = s else std.log.warn(
            "gw-read: {s} `ocr_text_scale` = '{s}' is not '1x'/'1.5x'/'2x'/'3x'; ignored",
            .{ conf_name, v },
        );
    }

    if (boolField(lua, "ai_lookup")) |v| result.config.ai_lookup = v;
    if (stringField(lua, "ai_provider")) |v| {
        if (ai.Provider.parse(v)) |p| result.config.ai_provider = p else std.log.warn(
            "gw-read: {s} `ai_provider` = '{s}' is not 'openai' or 'ollama'; ignored",
            .{ conf_name, v },
        );
    }
    if (stringField(lua, "ai_model")) |v|
        result.config.ai_model = ownString(alloc, &result.config, v, "");
    if (stringField(lua, "ai_endpoint")) |v|
        result.config.ai_endpoint = ownString(alloc, &result.config, v, "");
    if (stringField(lua, "ai_api_key_env")) |v|
        result.config.ai_api_key_env = ownString(alloc, &result.config, v, result.config.ai_api_key_env);
    if (stringField(lua, "ai_prompt")) |v|
        result.config.ai_prompt = ownString(alloc, &result.config, v, result.config.ai_prompt);
    if (boolField(lua, "ai_include_neighbor_dialog")) |v| result.config.ai_include_neighbor_dialog = v;
    if (boolField(lua, "ai_include_book_info")) |v| result.config.ai_include_book_info = v;
    if (boolField(lua, "ai_confirm_before_send")) |v| result.config.ai_confirm_before_send = v;
    if (boolField(lua, "ai_cache")) |v| result.config.ai_cache = v;

    // A `cache_pages` smaller than what the prefetch wants resident means
    // every prefetched page evicts the one being read. Nudge rather than
    // reject: the intent ("keep a small cache") is still honoured.
    const needed = result.config.prefetch + 2;
    if (result.config.cache_pages < needed) {
        std.log.warn(
            "gw-read: {s} `cache_pages` {d} is below prefetch + 2; raised to {d}",
            .{ conf_name, result.config.cache_pages, needed },
        );
        result.config.cache_pages = needed;
    }

    return result;
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
    const path = std.fs.path.join(alloc, &.{ config_dir, conf_name }) catch return .{};
    defer alloc.free(path);

    const src = std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(64 * 1024)) catch |err| {
        if (err != error.FileNotFound)
            std.log.warn("gw-read: couldn't read {s} ({t}); using defaults", .{ path, err });
        return .{};
    };
    defer alloc.free(src);
    const src_z = std.mem.concatWithSentinel(alloc, u8, &.{src}, 0) catch return .{};
    defer alloc.free(src_z);

    var result = load(alloc, src_z);
    defer result.deinit(alloc);
    if (result.err) |e|
        std.log.warn("gw-read: {s}: {s}; using what parsed", .{ conf_name, e });
    return result.takeConfig();
}

/// Dupes `v` and records it in `conf.owned` so `ReadConfig.deinit` frees
/// it. Out of memory keeps `fallback` rather than failing the whole load.
fn ownString(alloc: std.mem.Allocator, conf: *ReadConfig, v: []const u8, fallback: []const u8) []const u8 {
    const copy = alloc.dupe(u8, v) catch return fallback;
    conf.owned.append(alloc, copy) catch {
        alloc.free(copy);
        return fallback;
    };
    return copy;
}

/// Reads `config.<key>` as a non-negative whole number. Assumes the
/// `config` table is on top of the stack, same as `ls/config.zig`.
fn uintField(lua: *Lua, key: [:0]const u8) ?usize {
    const n = numberField(lua, key) orelse return null;
    if (n < 0 or n != @floor(n) or n > @as(f64, std.math.maxInt(u32))) {
        std.log.warn("gw-read: {s} `{s}` = {d} is not a whole count; ignored", .{ conf_name, key, n });
        return null;
    }
    return @intFromFloat(n);
}

fn numberField(lua: *Lua, key: [:0]const u8) ?f64 {
    _ = lua.getField(-1, key);
    defer lua.pop(1);
    if (!lua.isNumber(-1)) {
        if (!lua.isNil(-1))
            std.log.warn("gw-read: {s} `{s}` is not a number; ignored", .{ conf_name, key });
        return null;
    }
    return lua.toNumber(-1) catch null;
}

fn boolField(lua: *Lua, key: [:0]const u8) ?bool {
    _ = lua.getField(-1, key);
    defer lua.pop(1);
    if (!lua.isBoolean(-1)) {
        if (!lua.isNil(-1))
            std.log.warn("gw-read: {s} `{s}` is not a boolean; ignored", .{ conf_name, key });
        return null;
    }
    return lua.toBoolean(-1);
}

/// The returned slice points into the Lua string on the stack, which is
/// popped before this returns -- Lua 5.3 keeps the string alive as long
/// as it's reachable from the table it came from, which `config` is for
/// the rest of `load`. Only used inside `load`, never handed out.
fn stringField(lua: *Lua, key: [:0]const u8) ?[]const u8 {
    _ = lua.getField(-1, key);
    defer lua.pop(1);
    if (!lua.isString(-1)) {
        if (!lua.isNil(-1))
            std.log.warn("gw-read: {s} `{s}` is not a string; ignored", .{ conf_name, key });
        return null;
    }
    return lua.toString(-1) catch null;
}

fn clampUint(key: []const u8, v: usize, lo: usize, hi: usize) usize {
    const c = std.math.clamp(v, lo, hi);
    if (c != v)
        std.log.warn("gw-read: {s} `{s}` {d} out of range {d}..{d}; clamped to {d}", .{ conf_name, key, v, lo, hi, c });
    return c;
}

fn clampPeek(v: f64) f32 {
    const c = std.math.clamp(v, 0.0, 1.0);
    if (c != v)
        std.log.warn("gw-read: {s} `ocr_peek` {d} out of range 0..1; clamped to {d}", .{ conf_name, v, c });
    return @floatCast(c);
}

fn clampZoom(v: f64) f32 {
    const c = std.math.clamp(v, 1.0, zoom_max_ceiling);
    if (c != v)
        std.log.warn("gw-read: {s} `max_zoom` {d} out of range 1..{d}; clamped to {d}", .{ conf_name, v, zoom_max_ceiling, c });
    return @floatCast(c);
}
