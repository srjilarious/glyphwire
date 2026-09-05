const std = @import("std");
const geometry = @import("geometry.zig");

// Font defaults. `host.conf` (a global `config` table with
// `font_face` / `font_face_name` / `font_fallback` / `font_size` -- any
// subset) overrides these at startup; see `config_load.loadConfig`. The
// primary is Noto Sans Mono CJK: one monospaced face covering Latin, Greek,
// Cyrillic and CJK, so `ls` of files with Greek/Russian/Japanese names
// renders without tofu. It's a `.ttc` collection, so `font_face_name` picks
// the Japanese monospaced face out of it (a plain `.ttf` ignores the name
// and uses face 0). The fallback face is tried for any codepoint the
// primary lacks before the atlas falls back to its `.notdef` (tofu) box.
pub const font_path_default = "assets/NotoSansCJK-Regular.ttc";
pub const font_face_name_default = "Mono CJK JP";
pub const font_fallback_default = "assets/JetBrainsMono-Regular.ttf";
pub const font_size_default: f32 = 20.0;

// Basename of the host's startup config inside glyphwire's config
// directory (see `glyphwire.configDirPath`): `~/.config/glyphwire/host.conf`.
// Same Lua `config`-table format the shell's `shell.conf` uses; only the
// basename differs.
pub const host_conf_name = "host.conf";

// Always-registered extra fallback: a tiny pyftsubset of a Nerd Font to
// the Powerline range (U+E0A0-E0D7), for a configured powerline shell
// prompt's separator / cap glyphs.
pub const powerline_symbols_font = "assets/PowerlineSymbols-subset.ttf";

// Runtime font-size (Ctrl+- / Ctrl++ / Ctrl+0) policy. The engine applies
// whatever size it is handed; the clamp range and step are the host's.
pub const min_font_size: f32 = 8.0;
pub const max_font_size: f32 = 72.0;
pub const font_size_step: f32 = 2.0;

// Root layer scrollback depth in rows, passed to `Context.init`.
// `host.conf`'s `scrollback_rows` overrides this at startup,
// clamped to `[0, scrollback_rows_max]`. `var`, not `const`, for that.
pub const scrollback_rows_default = 1000;
pub const scrollback_rows_max = 100_000;
pub var scrollback_rows: usize = scrollback_rows_default;

/// Font settings resolved at startup from `host.conf` layered over the
/// `*_default` constants above. String fields point at `arena`-allocated
/// (process-lifetime) memory, or the default string literals.
pub const FontConfig = struct {
    face: [:0]const u8 = font_path_default,
    face_name: []const u8 = font_face_name_default,
    fallback: [:0]const u8 = font_fallback_default,
    size: f32 = font_size_default,
};

/// The four caret shapes `host.conf`'s `cursor_shape` can select.
/// `line` (a vertical bar at the cell's left edge) is the default and the
/// original behavior; the rest fill, outline, or underline the cell.
pub const CursorShape = enum { line, block, box, underline };

pub const cursor_shape_default: CursorShape = .line;
pub const cursor_blink_default: bool = true;
// Half-period: the caret is shown for this long, then hidden for this
// long. ~530ms matches the historical xterm default. Clamped to a sane
// range when read from config.
pub const cursor_blink_ms_default: f64 = 530;
pub const cursor_blink_ms_min: f64 = 100;
pub const cursor_blink_ms_max: f64 = 5000;

/// Caret appearance, resolved at startup from `host.conf` (see
/// `config_load.loadConfig`). Host-local, like `FontConfig` -- the caret is
/// a property of the rendering front end, not the shared grid model.
pub const CursorConfig = struct {
    shape: CursorShape = cursor_shape_default,
    blink: bool = cursor_blink_default,
    blink_ms: f64 = cursor_blink_ms_default,
};

/// Initial grid size and scrollback depth, resolved at startup from
/// `host.conf`. A `null` field was not set by `host.conf`, so
/// the module-level default (or a `--grid-cols` / `--grid-rows` flag)
/// stands. `cols` / `rows` are already clamped up to `min_grid_*` and
/// `scrollback` down to `scrollback_rows_max` by `config_load.loadConfig`.
pub const GridConfig = struct {
    cols: ?usize = null,
    rows: ?usize = null,
    scrollback: ?usize = null,
};

pub const default_icon_theme = "oxygen";

/// Everything `config_load.loadConfig` resolves from `host.conf`.
pub const HostConfig = struct {
    font: FontConfig = .{},
    cursor: CursorConfig = .{},
    grid: GridConfig = .{},
    /// Which bundled file-type icon set (`assets/icons/filetype/<name>/`)
    /// backs the canonical `file/*` names glyphwire-ls draws with -- one
    /// of `oxygen` (default), `papirus`, `material`. An unknown value
    /// warns and falls back to `oxygen`. `arena`-owned when set from
    /// `host.conf`, otherwise this literal.
    icon_theme: []const u8 = default_icon_theme,
};

/// Maps `config.cursor_shape`'s string to a `CursorShape`, or null for an
/// unrecognized value (the caller warns and keeps the default).
pub fn cursorShapeFromStr(s: []const u8) ?CursorShape {
    return std.meta.stringToEnum(CursorShape, s);
}

// ── Pure clamp helpers ─────────────────────────────────────────────────
// `config_load.loadConfig` runs each `host.conf` value through the
// matching helper here; they are split out (rather than inlined) so the
// clamp ranges have unit-test coverage without needing a Lua state.

/// `font_size` clamped to `[min_font_size, max_font_size]`.
pub fn clampFontSize(size: f32) f32 {
    return std.math.clamp(size, min_font_size, max_font_size);
}

/// `cursor_blink_ms` clamped to `[cursor_blink_ms_min, cursor_blink_ms_max]`.
pub fn clampBlinkMs(ms: f64) f64 {
    return std.math.clamp(ms, cursor_blink_ms_min, cursor_blink_ms_max);
}

/// `grid_cols` clamped up to `geometry.min_grid_cols`.
pub fn clampGridCols(v: usize) usize {
    return @max(v, @as(usize, geometry.min_grid_cols));
}

/// `grid_rows` clamped up to `geometry.min_grid_rows`.
pub fn clampGridRows(v: usize) usize {
    return @max(v, @as(usize, geometry.min_grid_rows));
}

/// `scrollback_rows` clamped down to `scrollback_rows_max`.
pub fn clampScrollback(v: usize) usize {
    return @min(v, @as(usize, scrollback_rows_max));
}
