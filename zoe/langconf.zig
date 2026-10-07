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
//! `tab_width`, `expand_tab`, `show_whitespace`, `wrap`,
//! `tab_tooltip_delay_ms`), and `workspace_autosave`.
//! With no file present
//! zoe runs on the built-in languages, the `default` theme, injection
//! enabled, and a 4-cell expanding Tab.
//!
//! Split out here (rather than in `ui.zig`) so `tests/zoe_tests.zig` can
//! exercise the parse without a Lua state wired into a running client,
//! matching how `ls/config.zig` sits in `ls_support`.

const std = @import("std");
const luaconf = @import("luaconf");
const glyphwire = @import("glyphwire");
const syntax = @import("applib").syntax;
const themes = @import("applib").theme;
const themeconf = @import("themeconf");
const dividerconf = @import("dividerconf");
const homepath = @import("applib").homepath;
const shellpanel = @import("applib").shellpanel;
const actions = @import("actions.zig");
const editor = @import("editor.zig");
const lsp = @import("lsp.zig");

const Lua = luaconf.Lua;

const conf_name = "zoe.conf.lua";
const conf: luaconf.Conf = .{ .prog = "zoe", .name = conf_name };

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
    /// `config.theme` / `config.themes`: zoe's own theme, overriding the
    /// window's (`ownTheme`), and the themes `:theme <name>` can reach.
    themes: themeconf.Parsed = .{ .source = conf_name },
    /// The shared `theme.lua`'s `themes`, which `config.theme` and
    /// `:theme` may name too.
    shared_themes: themeconf.Parsed = .{},
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
    /// `config.divider_style` / `config.divider_chars` -- how the host
    /// draws zoe's split bands (`applib/dividerconf.zig`). Empty, the
    /// default, inherits the host's `pane_divider_style`.
    divider_style: glyphwire.divider_style.Override = .{},
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
    /// `config.wrap` -- soft-wrap long lines in the buffer pane. Default
    /// false; `:set wrap=…` overrides.
    wrap: bool = false,
    /// `config.tab_tooltip_delay_ms` -- how long the pointer rests on a
    /// tab before its file's full path pops up under it. Zero shows it
    /// at once; a negative value or a non-number is ignored.
    tab_tooltip_delay_ms: f64 = tab_tooltip_delay_ms_default,
    /// `config.workspace_autosave` -- rewrite the session's
    /// `.zoe-workspace` on the way out (`:q`, `:wq`, the window closing;
    /// never `:q!`). Default true.
    workspace_autosave: bool = true,
    /// `config.shell_position` -- where the Ctrl+` shell panel sits:
    /// `"bottom"` (the default), `"top"`, `"left"`, `"right"`, or
    /// `"float"` for a framed box in the middle. `:shell <position>`
    /// moves it at runtime.
    shell_position: shellpanel.Position = .bottom,
    /// `config.shell_float_percent` -- how much of the window a floating
    /// panel takes, each way. Default 80; clamped to 10..100.
    shell_float_percent: u8 = shellpanel.default_float_percent,
    /// `config.lsp.enabled` -- the master switch. False stops every
    /// language server from starting, whatever `lsp_servers` says.
    lsp_enabled: bool = true,
    /// `config.lsp.servers`, merged **by name** over `default_lsp_servers`
    /// so overriding one server doesn't mean re-declaring the others. In
    /// the arena, like everything else here. Each entry's binary is
    /// probed on `PATH` at startup; one that isn't installed is simply not
    /// started (see `lsp.Pool.start`).
    lsp_servers: []const lsp.ServerConfig = &default_lsp_servers,
    /// `config.keys`, validated, in the arena: applied over the default
    /// bindings by `actions.Keymaps.apply` (`luaconf.scopedKeys`).
    keys: []const actions.Override = &.{},

    pub fn deinit(self: *Config) void {
        self.arena.deinit();
    }

    /// The theme `config.theme` names, resolved against zoe's `themes`
    /// and `theme.lua`'s, or null when zoe should follow the window's.
    /// Borrows from the arena.
    pub fn ownTheme(self: *Config) ?themes.Theme {
        return self.themes.resolve(self.arena.allocator(), self.shared_themes);
    }

    /// `:theme <name>`: a built-in, or one of either config's `themes`.
    pub fn findTheme(self: *Config, name: []const u8) ?themes.Theme {
        const all = std.mem.concat(self.arena.allocator(), themes.Custom, &.{ self.shared_themes.customs, self.themes.customs }) catch self.themes.customs;
        return themes.resolve(name, all);
    }
};

/// A `Config` holding nothing but the defaults, with a fresh arena. What
/// `load` starts from, and what a test hands to `parseSource`.
pub fn defaults(gpa: std.mem.Allocator) Config {
    return .{
        .arena = std.heap.ArenaAllocator.init(gpa),
        .langs = &syntax.default_langs,
        .grammar_dirs = &.{},
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
    cfg.shared_themes = themeconf.loadShared(cfg.arena.allocator(), gpa, io, environ);
    const src = conf.read(cfg.arena.allocator(), io, environ) orelse return cfg;
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
    var ctx: Apply = .{ .cfg = &cfg, .environ = environ };
    conf.runLogged(gpa, src, &ctx, Apply.apply);
    return cfg;
}

const float_percent: luaconf.Range(u8) = .{
    .min = shellpanel.min_float_percent,
    .max = shellpanel.max_float_percent,
};

const Apply = struct {
    cfg: *Config,
    environ: *const std.process.Environ.Map,

    fn apply(self: *Apply, lua: *Lua) void {
        const cfg = self.cfg;
        const a = cfg.arena.allocator();
        cfg.themes = themeconf.read(lua, a, conf_name);
        cfg.divider_style = dividerconf.read(lua, conf_name);
        cfg.grammar_dirs = readGrammarDirs(lua, a, self.environ);
        cfg.langs = readLangs(lua, a);
        if (conf.boolean(lua, "injections")) |v| cfg.injections = v;
        // `page_lines` must move at least a line; `tree_page_lines` may be
        // 0, which is how its viewport-sized default is spelled.
        if (conf.uint(lua, usize, "page_lines", .{ .min = 1 })) |v| cfg.page_lines = v;
        if (conf.uint(lua, usize, "tree_page_lines", .{})) |v| cfg.tree_page_lines = v;
        // A repeat delay of 0 is meaningful ("no initial hold"); an
        // interval of 0 isn't.
        const delay: luaconf.Range(f64) = .{ .min = 0 };
        const interval: luaconf.Range(f64) = .{ .min = 1 };
        if (conf.number(lua, f64, "key_repeat_delay_ms", delay)) |v| cfg.key_repeat_delay_ms = v;
        if (conf.number(lua, f64, "key_repeat_interval_ms", interval)) |v| cfg.key_repeat_interval_ms = v;
        if (conf.number(lua, f64, "key_repeat_insert_delay_ms", delay)) |v| cfg.key_repeat_insert_delay_ms = v;
        if (conf.number(lua, f64, "key_repeat_insert_interval_ms", interval)) |v| cfg.key_repeat_insert_interval_ms = v;
        cfg.line_numbers = readLineNumbers(lua, cfg.line_numbers);
        if (conf.uint(lua, usize, "tab_width", .{ .min = 1, .max = editor.max_tab_width })) |v| cfg.tab_width = v;
        if (conf.boolean(lua, "expand_tab")) |v| cfg.expand_tab = v;
        if (conf.boolean(lua, "show_whitespace")) |v| cfg.show_whitespace = v;
        if (conf.boolean(lua, "wrap")) |v| cfg.wrap = v;
        if (conf.number(lua, f64, "tab_tooltip_delay_ms", delay)) |v| cfg.tab_tooltip_delay_ms = v;
        if (conf.boolean(lua, "workspace_autosave")) |v| cfg.workspace_autosave = v;
        if (conf.enumValue(lua, shellpanel.Position, "shell_position")) |v| cfg.shell_position = v;
        if (conf.uint(lua, u8, "shell_float_percent", float_percent)) |v| cfg.shell_float_percent = v;
        readLsp(lua, a, cfg);
        // Per-mode tables (`global`, `normal`, `visual`, `insert`; see
        // `actions.zig`). `false` binds `.none`, which also hides the
        // global binding when it is in a mode table.
        cfg.keys = conf.scopedKeys(lua, a, actions.Scope, actions.Action);
    }
};

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
        const expanded = homepath.expandHomeAlloc(a, raw, environ.get("HOME")) catch continue;
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

        // entry.comment (optional): the line-comment marker for Ctrl+/.
        var comment: ?[]const u8 = null;
        if (lua.getField(-1, "comment") == .string) {
            if (lua.toString(-1)) |c| {
                if (c.len > 0) comment = a.dupe(u8, c) catch null;
            } else |_| {}
        }
        lua.pop(1);

        if (exts.items.len == 0) continue;
        out.append(a, .{
            .name = name,
            .extensions = exts.toOwnedSlice(a) catch continue,
            .line_comment = comment,
        }) catch continue;
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

    if (conf.boolean(lua, "enabled")) |v| cfg.lsp_enabled = v;

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

        if (conf.stringList(lua, a, "languages")) |langs| entry.languages = langs;
        if (conf.stringList(lua, a, "cmd")) |cmd| entry.cmd = cmd;
        if (conf.boolean(lua, "enabled")) |v| entry.enabled = v;
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
