//! zoe's optional startup config, `~/.config/glyphwire/zoe.conf` -- a Lua
//! script assigning a global `config` table, the same shape `host.conf`
//! and `ls.conf` use. It carries syntax-highlighting settings only:
//! extra languages / extension remaps, extra grammar directories,
//! capture-group colour overrides, and an `injections` on/off switch.
//! With no file present zoe runs on the built-in six languages, the dark
//! theme, and injection enabled.
//!
//! Split out here (rather than in `ui.zig`) so `tests/zoe_tests.zig` can
//! exercise the parse without a Lua state wired into a running client,
//! matching how `ls/config.zig` sits in `ls_support`.

const std = @import("std");
const ziglua = @import("ziglua");
const glyphwire = @import("glyphwire");
const syntax = @import("syntax.zig");
const editor = @import("editor.zig");

const Lua = ziglua.Lua;
const Color = glyphwire.Color;

const conf_name = "zoe.conf";

/// The parsed config. Everything it points at is owned by `arena`.
pub const Config = struct {
    arena: std.heap.ArenaAllocator,
    /// Extension -> grammar mapping, highest priority first. Config
    /// entries come before the built-in `default_langs`, so a config can
    /// remap an extension the defaults also claim.
    langs: []const syntax.LangDef,
    /// Extra grammar directories from `config.grammar_dirs`, `~` expanded.
    grammar_dirs: []const []const u8,
    /// The built-in theme with any `config.theme` overrides applied.
    theme: syntax.Theme,
    /// `config.injections` -- whether to run `injections.scm` and
    /// highlight embedded languages (code fences, Markdown inline).
    /// Default true; set `false` as an escape hatch.
    injections: bool = true,
    /// `config.page_lines` -- lines a PageDown / PageUp (or Ctrl-D /
    /// Ctrl-U) moves the cursor. Default 10; a non-positive or
    /// non-number value is ignored.
    page_lines: usize = 10,
    /// `config.line_numbers` -- the buffer-pane line-number gutter.
    /// Absent or `true` means `.absolute` (the gutter is on); `false`
    /// turns it off; `"absolute"` / `"relative"` pick the style, where
    /// `"relative"` keeps the caret's own line absolute. `:set lineno=…`
    /// overrides it at runtime.
    line_numbers: editor.LineNumbers = .absolute,

    pub fn deinit(self: *Config) void {
        self.arena.deinit();
    }
};

/// Reads `zoe.conf` from glyphwire's config dir and returns the merged
/// config. A missing file / missing config home is the normal case:
/// defaults, no error, nothing logged. Any parse problem is logged and
/// whatever parsed before it is kept.
pub fn load(
    gpa: std.mem.Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
) Config {
    var arena = std.heap.ArenaAllocator.init(gpa);
    const a = arena.allocator();

    var cfg = Config{
        .arena = arena,
        .langs = &syntax.default_langs,
        .grammar_dirs = &.{},
        .theme = syntax.Theme.initDefault(),
        .injections = true,
        .line_numbers = .absolute,
    };

    const src = readConf(&cfg.arena, io, environ) orelse return cfg;

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

    applyTheme(lua, &cfg.theme);
    cfg.grammar_dirs = readGrammarDirs(lua, a, environ);
    cfg.langs = readLangs(lua, a);
    cfg.injections = readInjections(lua);
    cfg.page_lines = readPageLines(lua, cfg.page_lines);
    cfg.line_numbers = readLineNumbers(lua, cfg.line_numbers);
    return cfg;
}

/// `config.page_lines = 15`. A number >= 1 replaces the default;
/// anything else (absent, zero, negative, non-number) leaves it.
fn readPageLines(lua: *Lua, current: usize) usize {
    const t = lua.getField(-1, "page_lines");
    defer lua.pop(1);
    if (t != .number) return current;
    const n = lua.toNumber(-1) catch return current;
    if (n < 1) return current;
    return @intFromFloat(n);
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

/// `config.theme = { keyword = "#c678dd", ... }` -> overrides on the
/// built-in theme. Unknown group names and unparseable colours are
/// skipped with a warning.
fn applyTheme(lua: *Lua, theme: *syntax.Theme) void {
    if (lua.getField(-1, "theme") != .table) {
        lua.pop(1);
        return;
    }
    defer lua.pop(1);

    lua.pushNil();
    while (lua.next(-2)) {
        // key at -2, value at -1
        defer lua.pop(1);
        if (!lua.isString(-2) or !lua.isString(-1)) continue;
        const key = lua.toString(-2) catch continue;
        const val = lua.toString(-1) catch continue;
        const color = parseHexColor(val) orelse {
            std.log.warn("zoe: {s} theme.{s} = \"{s}\" is not a #rrggbb colour; ignored", .{ conf_name, key, val });
            continue;
        };
        if (!theme.setByName(key, color))
            std.log.warn("zoe: {s} theme.{s} is not a known highlight group; ignored", .{ conf_name, key });
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

/// `#rrggbb` or `rrggbb`.
fn parseHexColor(s: []const u8) ?Color {
    const hex = if (s.len > 0 and s[0] == '#') s[1..] else s;
    if (hex.len != 6) return null;
    const v = std.fmt.parseInt(u24, hex, 16) catch return null;
    return .{
        .r = @intCast((v >> 16) & 0xff),
        .g = @intCast((v >> 8) & 0xff),
        .b = @intCast(v & 0xff),
    };
}

test {
    _ = parseHexColor;
}
