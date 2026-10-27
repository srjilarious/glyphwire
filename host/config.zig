// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: MPL-2.0

const std = @import("std");
const glyphwire = @import("glyphwire");
const geometry = @import("geometry.zig");
const key_repeat = @import("key_repeat.zig");
const host_eng = @import("host_eng");
const keybind = @import("keybind");
const dividers = @import("dividers.zig");
const pane_focus = @import("pane_focus.zig");

// Font defaults. `host.conf.lua` (a global `config` table with
// `font_face` / `font_face_name` / `font_fallback` / `font_size` -- any
// subset) overrides these at startup; see `config_load.loadConfig`. The
// primary is Noto Sans Mono CJK: one monospaced face covering Latin, Greek,
// Cyrillic and CJK, so `ls` of files with Greek/Russian/Japanese names
// renders without tofu. It's a `.ttc` collection, so `font_face_name` picks
// the Japanese monospaced face out of it (a plain `.ttf` ignores the name
// and uses face 0). The fallback faces are tried in order for any
// codepoint the primary lacks before the atlas falls back to its
// `.notdef` (tofu) box. `font_fallback` is one font or a list of them:
// a CJK face and a symbol/emoji face rarely come in one file.
//
// `font_face` / `font_fallback` need not be bundled assets: `host/main.zig`
// (`resolveFontFile`) also accepts an absolute or cwd-relative path, and a
// bare family name it hands to `fc-match` to pick a system-installed font
// (see `host/system_font.zig`).
pub const font_path_default = "NotoSansCJK-Regular.ttc";
pub const font_face_name_default = "Mono CJK JP";
pub const font_fallback_default = "JetBrainsMono-Regular.ttf";
pub const font_size_default: f32 = 20.0;

// Basename of the host's startup config inside glyphwire's config
// directory (see `glyphwire.configDirPath`):
// `~/.config/glyphwire/host.conf.lua`. Same Lua `config`-table format the
// shell's `shell.conf.lua` uses; only the basename differs.
pub const host_conf_name = "host.conf.lua";

// Always-registered extra fallback: a tiny pyftsubset of a Nerd Font to
// the Powerline range (U+E0A0-E0D7), for a configured powerline shell
// prompt's separator / cap glyphs.
pub const powerline_symbols_font = "PowerlineSymbols-subset.ttf";

// Runtime font-size (Ctrl+- / Ctrl++ / Ctrl+0) policy. The engine applies
// whatever size it is handed; the clamp range and step are the host's.
pub const min_font_size: f32 = 8.0;
pub const max_font_size: f32 = 72.0;
pub const font_size_step: f32 = 2.0;

// Root layer scrollback depth in rows, passed to `Context.init`.
// `host.conf.lua`'s `scrollback_rows` overrides this at startup,
// clamped to `[0, scrollback_rows_max]`. `var`, not `const`, for that.
pub const scrollback_rows_default = 1000;
pub const scrollback_rows_max = 100_000;
pub var scrollback_rows: usize = scrollback_rows_default;

/// Font settings resolved at startup from `host.conf.lua` layered over the
/// `*_default` constants above. String fields point at `arena`-allocated
/// (process-lifetime) memory, or the default string literals.
pub const FontConfig = struct {
    face: [:0]const u8 = font_path_default,
    /// null unless `host.conf.lua` set `font_face_name`. When set it picks a
    /// named face out of a `.ttc` (see `host/main.zig`); when null the
    /// bundled default collection is scanned for `font_face_name_default`,
    /// and a system `.ttc` uses the face `fc-match` resolved.
    face_name: ?[]const u8 = null,
    /// Tried in order after the primary. Never empty: an empty
    /// `font_fallback = {}` keeps the default rather than leaving the
    /// primary on its own.
    fallbacks: []const [:0]const u8 = &.{font_fallback_default},
    /// `font_emoji`: colour emoji, from a colour bitmap font in
    /// `fallbacks` or else the system's (see `host/main.zig`'s
    /// `setUpColorEmoji`). False draws emoji from the text fonts only.
    emoji: bool = true,
    size: f32 = font_size_default,
};

/// Maps font config spellings that should be resolved under the bundled
/// asset directory to the relative asset path. The bare built-in default
/// form is the current spelling; `assets/...` is accepted for configs from
/// the older repo-cwd era and must still work after a prefix install.
pub fn bundledFontRelPath(value: []const u8, default_rel_path: []const u8) ?[]const u8 {
    const legacy_prefix = "assets/";
    if (std.mem.eql(u8, value, default_rel_path)) return default_rel_path;
    if (std.mem.startsWith(u8, value, legacy_prefix)) return value[legacy_prefix.len..];
    return null;
}

/// The four caret shapes `host.conf.lua`'s `cursor_shape` can select.
/// `line` (a vertical bar at the cell's left edge) is the default and the
/// original behavior; the rest fill, outline, or underline the cell.
pub const CursorShape = enum { line, block, box, underline };

pub const cursor_shape_default: CursorShape = .line;

/// The shape the caret is actually drawn in, given what `host.conf.lua`
/// configured, what the visible context's client asked for with
/// `set_caret_shape` (null for "whatever you were going to use"), and
/// whether the host's window has the keyboard.
///
/// Focus wins over both. A hollow box in a window that isn't taking
/// input is the convention every terminal follows, and it is the one
/// thing on screen that says at a glance where the keyboard is going;
/// a client that would rather draw that itself gets the same news from
/// the `focus` notification.
pub fn effectiveCursorShape(
    configured: CursorShape,
    requested: ?glyphwire.CaretShape,
    window_focused: bool,
) CursorShape {
    if (!window_focused) return .box;
    return switch (requested orelse return configured) {
        .line => .line,
        .block => .block,
        .box => .box,
        .underline => .underline,
    };
}
pub const cursor_blink_default: bool = true;
// Half-period: the caret is shown for this long, then hidden for this
// long. ~530ms matches the historical xterm default. Clamped to a sane
// range when read from config.
pub const cursor_blink_ms_default: f64 = 530;
pub const cursor_blink_ms_min: f64 = 100;
pub const cursor_blink_ms_max: f64 = 5000;

/// Caret appearance, resolved at startup from `host.conf.lua` (see
/// `config_load.loadConfig`). Host-local, like `FontConfig` -- the caret is
/// a property of the rendering front end, not the shared grid model.
pub const CursorConfig = struct {
    shape: CursorShape = cursor_shape_default,
    blink: bool = cursor_blink_default,
    blink_ms: f64 = cursor_blink_ms_default,
};

/// Initial grid size and scrollback depth, resolved at startup from
/// `host.conf.lua`. A `null` field was not set by `host.conf.lua`, so
/// the module-level default (or a `--grid-cols` / `--grid-rows` flag)
/// stands. `cols` / `rows` are already clamped up to `min_grid_*` and
/// `scrollback` down to `scrollback_rows_max` by `config_load.loadConfig`.
pub const GridConfig = struct {
    cols: ?usize = null,
    rows: ?usize = null,
    scrollback: ?usize = null,
};

pub const default_icon_theme = "oxygen";

// Frame-timing profiler (see `host/profiler.zig`, `src/profiler.zig`).
// Off by default -- when disabled every profiler call is a cheap
// early-return, so the redraw-on-demand idle path pays nothing.
pub const profile_enabled_default: bool = false;
pub const profile_hud_default: bool = false;
// Start with forced every-frame redraw (bypasses redraw-on-demand, for
// measuring draw cost continuously). Ctrl+Alt+Shift+R toggles it at runtime.
pub const profile_force_redraw_default: bool = false;
pub const profile_log_ms_default: f64 = 0; // 0 = no periodic std.log summary
pub const profile_log_ms_min: f64 = 250;
pub const profile_log_ms_max: f64 = 60_000;
// Summary window: every stat (phase avg/p95/max, counter per-frame mean,
// fps) is accumulated over this many ms and then republished, so the
// numbers reflect the recent past rather than the whole session -- the
// same idea as an FPS counter's 1s bucket.
pub const profile_window_ms_default: f64 = 1000;
pub const profile_window_ms_min: f64 = 100;
pub const profile_window_ms_max: f64 = 10_000;

/// Resolved profiler settings. `enabled` gates the whole subsystem;
/// `hud` is the initial visibility of the on-screen overlay
/// (Ctrl+Alt+Shift+P toggles it at runtime while `enabled`); `window_ms` is the stat
/// averaging window; `log_interval_ms` is the cadence of the periodic
/// text summary to `std.log` (0 = never).
pub const ProfileConfig = struct {
    enabled: bool = profile_enabled_default,
    hud: bool = profile_hud_default,
    force_redraw: bool = profile_force_redraw_default,
    window_ms: f64 = profile_window_ms_default,
    log_interval_ms: f64 = profile_log_ms_default,
};

/// A host-owned key chord: one key plus the modifiers that must be held
/// with it, exactly (an extra modifier held is a different chord). What
/// `host.conf.lua`'s `context_switcher_key` and `theme_switcher_key`
/// parse into.
pub const Chord = struct {
    key: host_eng.input.Key,
    ctrl: bool = false,
    alt: bool = false,
    shift: bool = false,
    super: bool = false,

    pub fn matches(self: Chord, ctrl: bool, alt: bool, shift: bool, super: bool) bool {
        return self.ctrl == ctrl and self.alt == alt and self.shift == shift and self.super == super;
    }
};

/// Super+F12: a chord no program binds (Ctrl+Z stays free for undo, and
/// the Super modifier is otherwise unused inside the window).
pub const context_switcher_default: Chord = .{ .key = .F12, .super = true };

/// Super+F10, the theme switcher's: next to the context switcher's, for
/// the same reason.
pub const theme_switcher_default: Chord = .{ .key = .F10, .super = true };

/// Parses a chord written `"super+f12"` / `"ctrl+alt+tab"` in the one
/// chord grammar every glyphwire config uses (`keybind.Chord.parse`:
/// modifiers then the key, `+`-separated, case-insensitive, key aliases
/// like `esc` and `1`), then names the key as `host_eng.input.Key` does.
/// Null for anything malformed: an unknown modifier or key, no key, or
/// two keys.
pub fn parseChord(text: []const u8) ?Chord {
    const parsed = keybind.Chord.parse(text) catch return null;
    return .{
        .key = keyFromName(parsed.key()) orelse return null,
        .ctrl = parsed.mods.ctrl,
        .alt = parsed.mods.alt,
        .shift = parsed.mods.shift,
        .super = parsed.mods.super,
    };
}

/// `host_eng.input.Key` by name, ignoring case (`f12` finds `F12`).
fn keyFromName(name: []const u8) ?host_eng.input.Key {
    inline for (@typeInfo(host_eng.input.Key).@"enum".field_names) |field| {
        if (std.ascii.eqlIgnoreCase(name, field)) {
            const key = @field(host_eng.input.Key, field);
            return if (key == .unknown) null else key;
        }
    }
    return null;
}

/// Everything `config_load.loadConfig` resolves from `host.conf.lua`.
pub const HostConfig = struct {
    font: FontConfig = .{},
    cursor: CursorConfig = .{},
    grid: GridConfig = .{},
    profile: ProfileConfig = .{},
    /// Session-wide typematic key-repeat timing (`key_repeat_delay_ms` /
    /// `key_repeat_interval_ms`), already clamped. This is the default a
    /// program runs at; one that wants its own cadence sends
    /// `set_key_repeat` (see `host/key_repeat.zig`).
    key_repeat: key_repeat.Timing = .{},
    /// Which bundled file-type icon set (`<asset-dir>/icons/filetype/<name>/`)
    /// backs the canonical `file/*` names glyphwire-ls draws with -- one
    /// of `oxygen` (default), `papirus`, `material`. An unknown value
    /// warns and falls back to `oxygen`. `arena`-owned when set from
    /// `host.conf.lua`, otherwise this literal.
    icon_theme: []const u8 = default_icon_theme,
    /// The chord that opens the context switcher (`host/switcher.zig`),
    /// or null when `host.conf.lua` turned it off with
    /// `context_switcher_key = false`.
    context_switcher: ?Chord = context_switcher_default,
    /// The chord that opens the theme switcher
    /// (`host/theme_switcher.zig`), or null for `theme_switcher_key =
    /// false`.
    theme_switcher: ?Chord = theme_switcher_default,
    /// How the bands between panes are drawn: `pane_divider_style`'s
    /// preset, with any `pane_divider_chars` glyphs laid over it. Glyph
    /// strings are `arena`-owned when set from `host.conf.lua`.
    pane_divider: dividers.Style = dividers.default_style,
    /// `drop_target_opacity`: how strongly a `set_drop_target` washes a
    /// pane or cell block in the theme's `drop_target` colour, already
    /// clamped to `[drop_target_opacity_min, 1]`.
    drop_target_opacity: f32 = drop_target_opacity_default,
    /// The focused pane's highlight on the dividers around it:
    /// `pane_focus_highlight`, `pane_focus_color`,
    /// `pane_focus_pulse_color` and `pane_focus_pulse_seconds`.
    pane_focus: pane_focus.Config = .{},
    /// `default_program`: the argv the root pane's gw-shell execs into
    /// (`gmux`, `{ "zoe", "notes.md" }`) when the command line forwards
    /// none. Empty -- the default -- is gw-shell's own interactive
    /// prompt. Like a forwarded command, the window closes when it exits.
    /// `arena`-owned when set from `host.conf.lua`.
    default_program: []const [:0]const u8 = &.{},
    /// How far one wheel tick scrolls: `wheel_lines` plain, and
    /// `alt_wheel_lines` with Alt held, for a long jump without reaching
    /// for the scrollbar.
    wheel: WheelConfig = .{},
};

/// How far one wheel tick scrolls whatever is under the pointer: a layer,
/// a pane's scrollback, or the arrow keys a full-screen program gets.
pub const WheelConfig = struct {
    plain: WheelStep = .{ .lines = 3 },
    alt: WheelStep = .{ .pages = 1 },
};

/// One wheel tick's distance: a number of lines, or a fraction or
/// multiple of the pane under the pointer, so `"page"` is one screenful
/// whatever the pane's height. Sideways (Shift+wheel) the same step is
/// taken in columns, and a page is the pane's width.
pub const WheelStep = union(enum) {
    lines: f32,
    pages: f32,

    /// The step in rows (or columns) for a pane `extent` cells across on
    /// the scrolling axis. A page is never less than one line, so a
    /// one-row pane still moves.
    pub fn cells(self: WheelStep, extent: usize) f32 {
        return switch (self) {
            .lines => |n| n,
            .pages => |n| @max(1, n * @as(f32, @floatFromInt(extent))),
        };
    }
};

pub const wheel_lines_max: f32 = 1000;
pub const wheel_pages_max: f32 = 100;

/// A `wheel_lines` / `alt_wheel_lines` string: `"page"`, `"pages"`, or a
/// count before either (`"2 pages"`, `"0.5 page"`, `"1.5pages"`). A
/// number in a string (`"8"`) is lines. Null for anything else, or a
/// count that isn't positive.
pub fn parseWheelStep(s: []const u8) ?WheelStep {
    const t = std.mem.trim(u8, s, " \t");
    const unit_at = std.mem.indexOfAny(u8, t, "pP") orelse t.len;
    const count_str = std.mem.trimEnd(u8, t[0..unit_at], " \t");
    const unit = t[unit_at..];
    const count: f32 = if (count_str.len == 0)
        1
    else
        std.fmt.parseFloat(f32, count_str) catch return null;
    if (!(count > 0)) return null;
    if (unit.len == 0) {
        if (count_str.len == 0) return null;
        return .{ .lines = @min(count, wheel_lines_max) };
    }
    if (!std.ascii.eqlIgnoreCase(unit, "page") and !std.ascii.eqlIgnoreCase(unit, "pages")) return null;
    return .{ .pages = @min(count, wheel_pages_max) };
}

pub const drop_target_opacity_default: f32 = 0.25;
/// Below this a wash stops reading as a highlight at all.
pub const drop_target_opacity_min: f32 = 0.05;

/// `drop_target_opacity` clamped to `[drop_target_opacity_min, 1]`.
pub fn clampDropTargetOpacity(v: f32) f32 {
    return std.math.clamp(v, drop_target_opacity_min, 1.0);
}

/// Maps `config.cursor_shape`'s string to a `CursorShape`, or null for an
/// unrecognized value (the caller warns and keeps the default).
pub fn cursorShapeFromStr(s: []const u8) ?CursorShape {
    return std.meta.stringToEnum(CursorShape, s);
}

// ── Pure clamp helpers ─────────────────────────────────────────────────
// `config_load.loadConfig` runs each `host.conf.lua` value through the
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

/// `profile_log_ms`: 0 (or negative) means "no periodic summary"; any
/// other value is clamped to `[profile_log_ms_min, profile_log_ms_max]`.
pub fn clampProfileLogMs(ms: f64) f64 {
    if (ms <= 0) return 0;
    return std.math.clamp(ms, profile_log_ms_min, profile_log_ms_max);
}

/// `profile_window_ms` clamped to `[profile_window_ms_min, profile_window_ms_max]`.
pub fn clampProfileWindowMs(ms: f64) f64 {
    return std.math.clamp(ms, profile_window_ms_min, profile_window_ms_max);
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
