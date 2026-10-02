// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: GPL-3.0-or-later

//! zoe's optional startup config, `~/.config/glyphwire/zoe.conf.lua` --
//! a Lua script assigning a global `config` table, the same shape
//! `host.conf.lua` and `ls.conf.lua` use. It carries the settings zoe
//! reads at startup:
//! extra languages / extension remaps, extra grammar directories,
//! the colour theme (`theme`/`themes`, read by `applib/themeconf.zig`),
//! an `injections` on/off switch, and
//! the editor's display options (`page_lines`, `line_numbers`,
//! `tab_width`, `expand_tab`, `show_whitespace`, `tab_tooltip_delay_ms`).
//! With no file present
//! zoe runs on the built-in languages, the `default` theme, injection
//! enabled, and a 4-cell expanding Tab.
//!
//! Split out here (rather than in `ui.zig`) so `tests/zoe_tests.zig` can
//! exercise the parse without a Lua state wired into a running client,
//! matching how `ls/config.zig` sits in `ls_support`.

const std = @import("std");
const ziglua = @import("ziglua");
const glyphwire = @import("glyphwire");
const syntax = @import("applib").syntax;
const themes = @import("applib").theme;
const themeconf = @import("themeconf");
const editor = @import("editor.zig");
const lsp = @import("lsp.zig");

const Lua = ziglua.Lua;

const conf_name = "zoe.conf.lua";

/// One typematic repeat cadence, as asked of glyphwire-host with
/// `set_key_repeat`: the hold before a key starts repeating, then the
/// gap between repeats.
pub const KeyRepeat = struct {
    delay_ms: f64,
    interval_ms: f64,
};

// zoe asks for a cadence per mode and switches between them on the mode
// change (see `ui.Ui.syncKeyRepeat`), because the same key means
// different things in each and glyphwire-host repeats *typed* characters
// on this clock too.
//
// Both default to the same 300/30, which is what the two modes turned
// out to want in practice. The hold is well short of a terminal's, so a
// held `j` or arrow starts moving quickly, but still long enough that an
// ordinary keystroke -- held for ~100ms while typing -- can't cross it
// and repeat itself. Going much below that made insert mode double
// characters. They stay two settings because a config can pull them
// apart, and because sending on the mode change is also what stops a key
// held across it from repeating.
pub const key_repeat_delay_ms_default: f64 = 300;
pub const key_repeat_interval_ms_default: f64 = 30;
pub const key_repeat_insert_delay_ms_default: f64 = 300;
pub const key_repeat_insert_interval_ms_default: f64 = 30;

/// The tab tooltip's hover delay. Long enough that sweeping the pointer
/// across the strip on the way to somewhere else doesn't flash a popup
/// per tab, short enough that resting on one to ask feels answered.
pub const tab_tooltip_delay_ms_default: f64 = 400;

/// The language servers zoe knows about without being told. Each is started
/// only if its binary is on `PATH`, so having all three listed costs nothing
/// on a machine with none of them installed.
///
/// Two servers on Python is the point, not an oversight: the 2026 standard
/// setup is a type checker for hover and navigation (basedpyright -- the
/// open-source Pylance equivalent, pip-installable) *plus* `ruff server` for
/// lint and format diagnostics. The store keys diagnostics by
/// `(path, server)` precisely so the two can coexist.
pub const default_lsp_servers = [_]lsp.ServerConfig{
    .{ .name = "zls", .languages = &.{"zig"}, .cmd = &.{"zls"} },
    .{
        .name = "basedpyright",
        .languages = &.{"python"},
        .cmd = &.{ "basedpyright-langserver", "--stdio" },
    },
    .{ .name = "ruff", .languages = &.{"python"}, .cmd = &.{ "ruff", "server" } },
};

/// The parsed config. Everything it points at is owned by `arena`.
pub const Config = struct {
    arena: std.heap.ArenaAllocator,
    /// Extension -> grammar mapping, highest priority first. Config
    /// entries come before the built-in `default_langs`, so a config can
    /// remap an extension the defaults also claim.
    langs: []const syntax.LangDef,
    /// Extra grammar directories from `config.grammar_dirs`, `~` expanded.
    grammar_dirs: []const []const u8,
    /// The theme to start in: `config.theme` resolved against the
    /// built-ins and `config.themes` (see `applib/theme.zig`), or
    /// `default`. Its syntax half is what every highlighter colours with.
    theme: themes.Theme,
    /// `config.themes` (and the table form of `config.theme`, as
    /// `themeconf.table_theme_name`), kept so `:theme <name>` can switch
    /// to one later.
    custom_themes: []const themes.Custom = &.{},
    /// `config.injections` -- whether to run `injections.scm` and
    /// highlight embedded languages (code fences, Markdown inline).
    /// Default true; set `false` as an escape hatch.
    injections: bool = true,
    /// `config.page_lines` -- lines a PageDown / PageUp (or Ctrl-D /
    /// Ctrl-U) moves the cursor. Default 10; a non-positive or
    /// non-number value is ignored.
    page_lines: usize = 10,
    /// `config.tree_page_lines` -- rows a PageDown / PageUp moves the
    /// cursor in the file tree. Zero, the default, means "a viewport
    /// less one row of overlap", which is the rule a listing wants: a
    /// page through what is on screen, tracking a resized sidebar with
    /// nothing to keep in sync. A number >= 1 pins it to that many rows
    /// instead. Separate from `page_lines` because the buffer's page is a
    /// jump through *text*, where the window it is seen through is
    /// incidental -- see `Ui.treePageRows`.
    tree_page_lines: usize = 0,
    /// `config.key_repeat_delay_ms` / `config.key_repeat_interval_ms` --
    /// the typematic repeat cadence zoe asks glyphwire-host for in
    /// normal and visual mode (`Client.setKeyRepeat`), where a repeat is
    /// a motion: `j`, an arrow, PageDown. Shorter than a shell's, which
    /// waits half a second before repeating a key that might be a
    /// command. A negative delay, a non-positive interval, or a
    /// non-number is ignored; the host clamps whatever gets through.
    key_repeat_delay_ms: f64 = key_repeat_delay_ms_default,
    key_repeat_interval_ms: f64 = key_repeat_interval_ms_default,
    /// `config.key_repeat_insert_delay_ms` /
    /// `config.key_repeat_insert_interval_ms` -- the same, for insert and
    /// command mode, where a held letter types rather than moves. Kept
    /// separate so the two can be pulled apart: drop the motion delay far
    /// enough and ordinary typing starts repeating characters, which is
    /// only ever wrong. See the defaults above.
    key_repeat_insert_delay_ms: f64 = key_repeat_insert_delay_ms_default,
    key_repeat_insert_interval_ms: f64 = key_repeat_insert_interval_ms_default,
    /// `config.line_numbers` -- the buffer-pane line-number gutter.
    /// Absent or `true` means `.absolute` (the gutter is on); `false`
    /// turns it off; `"absolute"` / `"relative"` pick the style, where
    /// `"relative"` keeps the caret's own line absolute. `:set lineno=…`
    /// overrides it at runtime.
    line_numbers: editor.LineNumbers = .absolute,
    /// `config.tab_width` -- cells between tab stops, both for a `\t`
    /// already in the file and for the grid an expanding Tab indents
    /// onto. Default 4; anything outside 1..`editor.max_tab_width` is
    /// ignored. `:set tabwidth=…` overrides it at runtime.
    tab_width: usize = 4,
    /// `config.expand_tab` -- whether the Tab key inserts spaces rather
    /// than a literal `\t`. Default true; `:set expandtab=…` overrides.
    expand_tab: bool = true,
    /// `config.show_whitespace` -- mark whitespace in the buffer pane:
    /// a faint middle dot on each space, a faint arrow on each tab.
    /// Default false; `:set whitespace=…` overrides.
    show_whitespace: bool = false,
    /// `config.tab_tooltip_delay_ms` -- how long the pointer rests on a
    /// tab before its file's full path pops up under it. Zero shows it
    /// at once; a negative value or a non-number is ignored.
    tab_tooltip_delay_ms: f64 = tab_tooltip_delay_ms_default,
    /// `config.lsp.enabled` -- the master switch. False stops every
    /// language server from starting, whatever `lsp_servers` says.
    lsp_enabled: bool = true,
    /// `config.lsp.servers`, merged **by name** over `default_lsp_servers`
    /// so overriding one server doesn't mean re-declaring the others. In
    /// the arena, like everything else here. Each entry's binary is
    /// probed on `PATH` at startup; one that isn't installed is simply not
    /// started (see `lsp.Pool.start`).
    lsp_servers: []const lsp.ServerConfig = &default_lsp_servers,

    pub fn deinit(self: *Config) void {
        self.arena.deinit();
    }
};

/// A `Config` holding nothing but the defaults, with a fresh arena. What
/// `load` starts from, and what a test hands to `parseSource`.
pub fn defaults(gpa: std.mem.Allocator) Config {
    return .{
        .arena = std.heap.ArenaAllocator.init(gpa),
        .langs = &syntax.default_langs,
        .grammar_dirs = &.{},
        .theme = themes.initDefault(),
        .injections = true,
        .line_numbers = .absolute,
    };
}

/// Reads `zoe.conf.lua` from glyphwire's config dir and returns the merged
/// config. A missing file / missing config home is the normal case:
/// defaults, no error, nothing logged. Any parse problem is logged and
/// whatever parsed before it is kept.
pub fn load(
    gpa: std.mem.Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
) Config {
    var cfg = defaults(gpa);
    const src = readConf(&cfg.arena, io, environ) orelse return cfg;
    return parseSource(gpa, src, environ, cfg);
}

/// The parse half of `load`, over config text already in hand. Split out so
/// `tests/zoe_tests.zig` can exercise it against a string -- which is the
/// whole reason this file isn't part of `ui.zig` (see the module comment),
/// and what `config.lsp`'s merge-by-name rules are checked against.
///
/// `cfg` comes in holding the defaults and its arena owns everything the
/// result points at.
pub fn parseSource(
    gpa: std.mem.Allocator,
    src: [:0]const u8,
    environ: *const std.process.Environ.Map,
    cfg_in: Config,
) Config {
    var cfg = cfg_in;
    const a = cfg.arena.allocator();

    const lua = Lua.init(gpa) catch {
        std.log.warn("zoe: could not create Lua interpreter for {s}; using defaults", .{conf_name});
        return cfg;
    };
    defer lua.deinit();
    lua.openLibs();

    lua.doString(src) catch {
        const msg = lua.toString(-1) catch conf_name ++ ": unknown Lua error";
        std.log.warn("zoe: {s}: {s}; using what parsed", .{ conf_name, msg });
        return cfg;
    };

    _ = lua.getGlobal("config") catch return cfg;
    defer lua.pop(1);
    if (lua.typeOf(-1) != .table) {
        if (lua.typeOf(-1) != .nil)
            std.log.warn("zoe: {s} `config` is not a table; using defaults", .{conf_name});
        return cfg;
    }

    const parsed = themeconf.read(lua, a);
    cfg.custom_themes = parsed.customs;
    cfg.theme = parsed.resolveOrDefault();
    cfg.grammar_dirs = readGrammarDirs(lua, a, environ);
    cfg.langs = readLangs(lua, a);
    cfg.injections = readInjections(lua);
    cfg.page_lines = readPageLines(lua, "page_lines", cfg.page_lines);
    cfg.tree_page_lines = readPageLines(lua, "tree_page_lines", cfg.tree_page_lines);
    cfg.key_repeat_delay_ms = readMs(lua, "key_repeat_delay_ms", 0, cfg.key_repeat_delay_ms);
    cfg.key_repeat_interval_ms = readMs(lua, "key_repeat_interval_ms", 1, cfg.key_repeat_interval_ms);
    cfg.key_repeat_insert_delay_ms = readMs(lua, "key_repeat_insert_delay_ms", 0, cfg.key_repeat_insert_delay_ms);
    cfg.key_repeat_insert_interval_ms = readMs(lua, "key_repeat_insert_interval_ms", 1, cfg.key_repeat_insert_interval_ms);
    cfg.line_numbers = readLineNumbers(lua, cfg.line_numbers);
    cfg.tab_width = readTabWidth(lua, cfg.tab_width);
    cfg.expand_tab = readFlag(lua, "expand_tab", cfg.expand_tab);
    cfg.show_whitespace = readFlag(lua, "show_whitespace", cfg.show_whitespace);
    cfg.tab_tooltip_delay_ms = readMs(lua, "tab_tooltip_delay_ms", 0, cfg.tab_tooltip_delay_ms);
    readLsp(lua, a, &cfg);
    return cfg;
}

/// One millisecond-valued config field: a number >= `min` replaces
/// `current`, anything else (absent, out of range, non-number) leaves it.
/// `min` is 0 for the repeat delay, where zero is a meaningful setting
/// ("no initial hold"), and 1 for the interval, where it isn't.
fn readMs(lua: *Lua, comptime name: [:0]const u8, min: f64, current: f64) f64 {
    const t = lua.getField(-1, name);
    defer lua.pop(1);
    if (t != .number) return current;
    const n = lua.toNumber(-1) catch return current;
    if (n < min) return current;
    return n;
}

/// `config.page_lines = 15` / `config.tree_page_lines = 15`. A number
/// >= 1 replaces the default; anything else (absent, zero, negative,
/// non-number) leaves it -- which for `tree_page_lines` is how the
/// viewport-sized default is spelled.
fn readPageLines(lua: *Lua, comptime name: [:0]const u8, current: usize) usize {
    const t = lua.getField(-1, name);
    defer lua.pop(1);
    if (t != .number) return current;
    const n = lua.toNumber(-1) catch return current;
    if (n < 1) return current;
    return @intFromFloat(n);
}

/// `config.tab_width = 8`. A number in 1..`editor.max_tab_width`
/// replaces the default; anything else (absent, zero, huge, non-number)
/// leaves it.
fn readTabWidth(lua: *Lua, current: usize) usize {
    const t = lua.getField(-1, "tab_width");
    defer lua.pop(1);
    if (t != .number) return current;
    const n = lua.toNumber(-1) catch return current;
    if (n < 1 or n > @as(f64, @floatFromInt(editor.max_tab_width))) return current;
    return @intFromFloat(n);
}

/// A plain `config.<name> = true|false`. A non-boolean (including
/// absent) leaves `current`.
fn readFlag(lua: *Lua, comptime name: [:0]const u8, current: bool) bool {
    const t = lua.getField(-1, name);
    defer lua.pop(1);
    if (t != .boolean) return current;
    return lua.toBoolean(-1);
}

/// `config.line_numbers`: `false` -> off, `true` -> absolute,
/// `"off"` / `"absolute"` / `"relative"` -> that style. Absent, or a
/// value that is neither a boolean nor one of those strings, leaves
/// `current` (the default, `.absolute`).
fn readLineNumbers(lua: *Lua, current: editor.LineNumbers) editor.LineNumbers {
    const t = lua.getField(-1, "line_numbers");
    defer lua.pop(1);
    switch (t) {
        .boolean => return if (lua.toBoolean(-1)) .absolute else .off,
        .string => {
            const s = lua.toString(-1) catch return current;
            if (std.mem.eql(u8, s, "off")) return .off;
            if (std.mem.eql(u8, s, "absolute")) return .absolute;
            if (std.mem.eql(u8, s, "relative")) return .relative;
            return current;
        },
        else => return current,
    }
}

/// `config.injections = false` turns embedded-language highlighting off.
/// Anything other than an explicit `false` (absent, `nil`, `true`, a
/// non-boolean) leaves it on.
fn readInjections(lua: *Lua) bool {
    const t = lua.getField(-1, "injections");
    defer lua.pop(1);
    if (t != .boolean) return true;
    return lua.toBoolean(-1);
}

/// `config.grammar_dirs = { "~/x", ... }`, `~` expanded against $HOME.
fn readGrammarDirs(
    lua: *Lua,
    a: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
) []const []const u8 {
    if (lua.getField(-1, "grammar_dirs") != .table) {
        lua.pop(1);
        return &.{};
    }
    defer lua.pop(1);

    var dirs: std.ArrayList([]const u8) = .empty;
    const n = lua.rawLen(-1);
    var i: usize = 1;
    while (i <= n) : (i += 1) {
        defer lua.pop(1);
        if (lua.rawGetIndex(-1, @intCast(i)) != .string) continue;
        const raw = lua.toString(-1) catch continue;
        const expanded = expandTilde(a, raw, environ) catch continue;
        dirs.append(a, expanded) catch continue;
    }
    return dirs.toOwnedSlice(a) catch &.{};
}

/// `config.languages = { { name = "c", extensions = {".c", ".h"} }, ... }`
/// prepended to the built-in defaults.
fn readLangs(lua: *Lua, a: std.mem.Allocator) []const syntax.LangDef {
    if (lua.getField(-1, "languages") != .table) {
        lua.pop(1);
        return &syntax.default_langs;
    }
    defer lua.pop(1);

    var out: std.ArrayList(syntax.LangDef) = .empty;
    const n = lua.rawLen(-1);
    var i: usize = 1;
    while (i <= n) : (i += 1) {
        defer lua.pop(1); // the entry table pushed by rawGetIndex
        if (lua.rawGetIndex(-1, @intCast(i)) != .table) continue;

        // entry.name (required)
        if (lua.getField(-1, "name") != .string) {
            lua.pop(1);
            continue;
        }
        const name_raw = lua.toString(-1) catch {
            lua.pop(1);
            continue;
        };
        const name = a.dupe(u8, name_raw) catch {
            lua.pop(1);
            continue;
        };
        lua.pop(1); // entry.name value

        // entry.extensions (required, non-empty)
        var exts: std.ArrayList([]const u8) = .empty;
        if (lua.getField(-1, "extensions") == .table) {
            const en = lua.rawLen(-1);
            var j: usize = 1;
            while (j <= en) : (j += 1) {
                defer lua.pop(1);
                if (lua.rawGetIndex(-1, @intCast(j)) != .string) continue;
                const e = lua.toString(-1) catch continue;
                exts.append(a, a.dupe(u8, e) catch continue) catch continue;
            }
        }
        lua.pop(1); // entry.extensions value (table or whatever it was)

        if (exts.items.len == 0) continue;
        out.append(a, .{ .name = name, .extensions = exts.toOwnedSlice(a) catch continue }) catch continue;
    }

    if (out.items.len == 0) return &syntax.default_langs;
    out.appendSlice(a, &syntax.default_langs) catch {};
    return out.toOwnedSlice(a) catch &syntax.default_langs;
}

/// `config.lsp`: the master switch and the server list, merged by name over
/// `default_lsp_servers`.
///
/// Merging by name rather than replacing the list wholesale is what makes
/// the common edits one line each: pointing `zls` at a different binary, or
/// turning `ruff` off, without having to restate the servers you were happy
/// with. A name the defaults don't have is a new server.
fn readLsp(lua: *Lua, a: std.mem.Allocator, cfg: *Config) void {
    if (lua.getField(-1, "lsp") != .table) {
        lua.pop(1);
        return;
    }
    defer lua.pop(1);

    cfg.lsp_enabled = readFlag(lua, "enabled", cfg.lsp_enabled);

    if (lua.getField(-1, "servers") != .table) {
        lua.pop(1);
        return;
    }
    defer lua.pop(1);

    // Start from the built-ins and edit in place, so an entry naming one of
    // them overrides just the fields it mentions.
    var out: std.ArrayList(lsp.ServerConfig) = .empty;
    out.appendSlice(a, &default_lsp_servers) catch return;

    const n = lua.rawLen(-1);
    var i: usize = 1;
    while (i <= n) : (i += 1) {
        defer lua.pop(1); // the entry table
        if (lua.rawGetIndex(-1, @intCast(i)) != .table) continue;

        // `name` is what an entry is identified by, so an entry without one
        // can't be merged and can't stand alone either.
        if (lua.getField(-1, "name") != .string) {
            lua.pop(1);
            continue;
        }
        const name_raw = lua.toString(-1) catch {
            lua.pop(1);
            continue;
        };
        const name = a.dupe(u8, name_raw) catch {
            lua.pop(1);
            continue;
        };
        lua.pop(1);

        const existing: ?*lsp.ServerConfig = blk: {
            for (out.items) |*s| if (std.mem.eql(u8, s.name, name)) break :blk s;
            break :blk null;
        };
        var entry: lsp.ServerConfig = if (existing) |e| e.* else .{
            .name = name,
            .languages = &.{},
            .cmd = &.{},
        };

        if (readStringList(lua, a, "languages")) |langs| entry.languages = langs;
        if (readStringList(lua, a, "cmd")) |cmd| entry.cmd = cmd;
        entry.enabled = readFlag(lua, "enabled", entry.enabled);
        {
            // Bracketed by the stack height rather than a counted `pop`:
            // `luaValueToJson` walks a table with `next`, which leaves a key
            // and a value on the stack, and an early return out of it would
            // otherwise make the pop below take the wrong thing and corrupt
            // the walk over the remaining entries.
            const top = lua.getTop();
            defer lua.setTop(top);
            if (lua.getField(-1, "settings") == .table) {
                var json: std.ArrayList(u8) = .empty;
                if (luaValueToJson(lua, a, &json, 0)) {
                    entry.settings_json = json.toOwnedSlice(a) catch null;
                }
            }
        }

        if (existing) |e| {
            e.* = entry;
        } else {
            // A brand-new server with nothing to run, or nothing to run it
            // for, would be started and immediately do nothing.
            if (entry.cmd.len == 0 or entry.languages.len == 0) continue;
            out.append(a, entry) catch continue;
        }
    }

    cfg.lsp_servers = out.toOwnedSlice(a) catch &default_lsp_servers;
}

/// A table of strings at `config.<...>.<name>`, duped into `a`. Null when
/// the field is absent or isn't a table, so a caller can tell "not
/// mentioned" (keep the default) from "mentioned as empty" (an entry that
/// won't start). A non-string element is skipped.
fn readStringList(lua: *Lua, a: std.mem.Allocator, comptime name: [:0]const u8) ?[]const []const u8 {
    if (lua.getField(-1, name) != .table) {
        lua.pop(1);
        return null;
    }
    defer lua.pop(1);
    var out: std.ArrayList([]const u8) = .empty;
    const n = lua.rawLen(-1);
    var i: usize = 1;
    while (i <= n) : (i += 1) {
        defer lua.pop(1);
        if (lua.rawGetIndex(-1, @intCast(i)) != .string) continue;
        const s = lua.toString(-1) catch continue;
        out.append(a, a.dupe(u8, s) catch continue) catch continue;
    }
    return out.toOwnedSlice(a) catch null;
}

/// Serializes the Lua value on top of the stack as JSON into `out`, for a
/// server's `initializationOptions` -- `settings` in the config.
///
/// Passed through rather than modelled: every server has its own settings
/// schema (basedpyright's `python.analysis.*`, zls's own keys), all of them
/// change faster than zoe would track, and none of them mean anything here.
/// So the config's table is transcribed and forwarded verbatim.
///
/// A table with a positive `rawLen` is an array and everything else is an
/// object, which is the usual Lua ambiguity and the usual resolution.
/// Returns false if the value isn't representable, leaving `out` unusable.
fn luaValueToJson(lua: *Lua, a: std.mem.Allocator, out: *std.ArrayList(u8), depth: u8) bool {
    // Bounded rather than trusting the config not to contain a cycle: a
    // self-referencing table would otherwise recurse until the stack went.
    if (depth > 16) return false;
    switch (lua.typeOf(-1)) {
        .nil => out.appendSlice(a, "null") catch return false,
        .boolean => out.appendSlice(a, if (lua.toBoolean(-1)) "true" else "false") catch return false,
        .number => {
            const v = lua.toNumber(-1) catch return false;
            // Lua has one number type; integral values are written without
            // a decimal point so a count or a port doesn't arrive as "8.0e0".
            if (v == @trunc(v) and @abs(v) < 1e15) {
                out.print(a, "{d}", .{@as(i64, @intFromFloat(v))}) catch return false;
            } else {
                out.print(a, "{d}", .{v}) catch return false;
            }
        },
        .string => {
            const s = lua.toString(-1) catch return false;
            appendJsonString(a, out, s) catch return false;
        },
        .table => {
            const len = lua.rawLen(-1);
            if (len > 0) {
                out.append(a, '[') catch return false;
                var i: usize = 1;
                while (i <= len) : (i += 1) {
                    if (i > 1) out.append(a, ',') catch return false;
                    _ = lua.rawGetIndex(-1, @intCast(i));
                    const ok = luaValueToJson(lua, a, out, depth + 1);
                    lua.pop(1);
                    if (!ok) return false;
                }
                out.append(a, ']') catch return false;
                return true;
            }
            out.append(a, '{') catch return false;
            var first = true;
            lua.pushNil();
            while (lua.next(-2)) {
                // key at -2, value at -1. Only string keys make sense in
                // JSON; a numeric key in a table with no array part is a
                // config mistake, not a thing to invent a name for.
                if (lua.typeOf(-2) != .string) {
                    lua.pop(1);
                    continue;
                }
                if (!first) out.append(a, ',') catch return false;
                first = false;
                // `toString` on the key would coerce it in place and break
                // `next`; it is already a string, so this is just a read.
                const key = lua.toString(-2) catch {
                    lua.pop(1);
                    continue;
                };
                appendJsonString(a, out, key) catch return false;
                out.append(a, ':') catch return false;
                const ok = luaValueToJson(lua, a, out, depth + 1);
                if (!ok) return false;
                lua.pop(1); // the value; the key stays for `next`
            }
            out.append(a, '}') catch return false;
        },
        else => return false,
    }
    return true;
}

/// One JSON string literal, quotes and escapes included, appended to `out`.
/// Through `Stringify` rather than hand-rolled so the escaping is the same
/// as everywhere else in the codebase.
fn appendJsonString(a: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8) !void {
    const quoted = try std.json.Stringify.valueAlloc(a, s, .{});
    defer a.free(quoted);
    try out.appendSlice(a, quoted);
}

fn readConf(
    arena: *std.heap.ArenaAllocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
) ?[:0]const u8 {
    const a = arena.allocator();
    const dir = glyphwire.configDirPath(a, environ) catch return null;
    const path = std.fs.path.join(a, &.{ dir, conf_name }) catch return null;
    return std.Io.Dir.cwd().readFileAllocOptions(io, path, a, .limited(256 * 1024), .of(u8), 0) catch |err| {
        if (err != error.FileNotFound)
            std.log.warn("zoe: couldn't read {s} ({t}); using defaults", .{ path, err });
        return null;
    };
}

fn expandTilde(
    a: std.mem.Allocator,
    path: []const u8,
    environ: *const std.process.Environ.Map,
) ![]const u8 {
    if (!std.mem.startsWith(u8, path, "~/")) return a.dupe(u8, path);
    const home = environ.get("HOME") orelse return a.dupe(u8, path);
    return std.fs.path.join(a, &.{ home, path[2..] });
}
