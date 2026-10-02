// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: MPL-2.0

//! Colour themes for zoe and gw-grep: the built-in set, and resolving a
//! theme name (built-in or one a config defined) to concrete colours.
//!
//! A theme is three things:
//!
//!   `syntax`  the tree-sitter capture-group colours (`syntax.Theme`)
//!   `ui`      every colour the programs paint themselves: pane and bar
//!             backgrounds, cursor, selection, search matches,
//!             diagnostics, popups (`Ui`)
//!   `panel_style`  the nine-patch the popups are framed with, since a
//!             nine-patch is art and can't be recoloured
//!
//! Nobody writes all of that out by hand. A theme is *specified* as a
//! fifteen-colour `Palette` -- a few backgrounds, the text colours, and
//! seven accents -- and both halves are derived from it (`derive`), the
//! syntax half with the One Dark capture mapping and the UI half with
//! blends between the backgrounds and accents. Then a spec's own explicit
//! `syntax`/`ui` pairs are laid over the result: that is how a built-in
//! keeps the capture mapping of the editor theme it copies (GitHub's
//! keywords are red, not purple) and how `default` stays pixel-identical
//! to the hand-tuned palette zoe shipped before themes existed.
//!
//! A config's theme (`Custom`) is the same idea one level up: a `base`
//! theme, palette colours that replace the base's *before* derivation,
//! then syntax/ui overrides after it. Changing `palette.bg` therefore
//! moves every colour blended from it, but a slot the base set by hand
//! keeps its hand-set value until the custom theme names that slot too.
//!
//! Pure data and arithmetic -- no Lua, no wire. zoe's `langconf.zig`
//! parses the Lua tables into `Custom`s and gw-grep reuses that parse.

const std = @import("std");
const glyphwire = @import("glyphwire");
const syntax = @import("syntax.zig");

const Color = glyphwire.Color;
const Group = syntax.Theme.Group;

/// The colours a theme is specified in. `u24` (`0xrrggbb`) so the
/// built-in table below reads like the hex the upstream themes publish.
pub const Palette = struct {
    /// The editing pane.
    bg: u24,
    /// The darkest chrome: the tab bar, and half of the file tree's
    /// background. On a light theme, the faint grey chrome.
    bg_dark: u24,
    /// The raised chrome: the status bar, half of an inactive tab.
    bg_hi: u24,
    fg: u24,
    /// Line numbers, the finder's directory part, completion detail.
    fg_dim: u24,
    comment: u24,
    selection: u24,
    cursor: u24,
    red: u24,
    orange: u24,
    yellow: u24,
    green: u24,
    cyan: u24,
    blue: u24,
    purple: u24,

    /// Sets the field called `name` (`"bg"`, `"red"`, ...). False for a
    /// name that isn't one.
    pub fn setByName(self: *Palette, name: []const u8, c: Color) bool {
        inline for (comptime std.meta.fieldNames(Palette)) |f| {
            if (std.mem.eql(u8, name, f)) {
                @field(self, f) = pack(c);
                return true;
            }
        }
        return false;
    }

    pub fn has(name: []const u8) bool {
        inline for (comptime std.meta.fieldNames(Palette)) |f| {
            if (std.mem.eql(u8, name, f)) return true;
        }
        return false;
    }
};

/// Every colour zoe (and gw-grep) paints outside the syntax colours.
/// The field names are what a config's `ui = { ... }` table uses.
pub const Ui = struct {
    bg_buffer: Color,
    bg_tree: Color,
    bg_status: Color,
    /// The tab strip. The active tab takes `bg_buffer` so it reads as the
    /// front of the pane below it, the way a tabbed window does; the rest
    /// are `bg_tab` on a bar darker than either.
    bg_tab_bar: Color,
    bg_tab: Color,
    /// The Ctrl+` shell panel: darker than the buffer, so it reads as a
    /// terminal laid over the editor and not as more of it. Dark on every
    /// built-in, light themes included: what runs in it is a terminal
    /// program that assumes light text on a dark background, and
    /// gw-shell's prompt does too.
    bg_shell: Color,
    fg_text: Color,
    fg_dim: Color,
    fg_dir: Color,
    /// A tree row only on screen because Ctrl+H is on -- a dotfile or
    /// something `.gitignore` excludes. Dimmed rather than marked, so the
    /// listing still reads as one list, and kept distinct for files and
    /// directories so the shape of the tree survives the dimming: roughly
    /// halfway from the normal colour to the background.
    fg_hidden: Color,
    fg_hidden_dir: Color,
    fg_status: Color,
    fg_mode: Color,
    fg_error: Color,
    /// The dots and arrows `:set whitespace=on` paints. Bright enough to
    /// read the indentation off, dim enough to disappear when you stop
    /// looking for it.
    fg_whitespace: Color,
    bg_cursor: Color,
    fg_cursor: Color,
    bg_selected: Color,
    /// Search matches, in two weights: every match gets the dim one, the
    /// one the cursor is on the bright one, which is how you tell where
    /// `n` just landed in a screen full of hits.
    bg_match: Color,
    bg_match_current: Color,
    /// gw-grep's "this is the hit" line-number colour.
    fg_match: Color,
    fg_diag_error: Color,
    fg_diag_warning: Color,
    fg_diag_info: Color,
    fg_diag_hint: Color,
    /// The hover and completion popups' flat background, used where the
    /// host has no `panel_style` nine-patch.
    bg_popup: Color,
    fg_popup: Color,
    /// A fenced code block in the hover popup sits on its own band, so a
    /// signature reads as a unit apart from the prose under it.
    bg_popup_code: Color,
    fg_popup_rule: Color,
    /// A `---` rule across the hover popup, which joins the nine-patch's
    /// own border on both sides -- so keep it the border's colour.
    fg_popup_border: Color,
    bg_popup_selected: Color,
    fg_popup_label: Color,
    fg_popup_kind: Color,
    fg_popup_detail: Color,
    bg_finder_header: Color,
    fg_finder_header: Color,
    bg_finder_selected: Color,
    fg_finder_selected: Color,

    pub const Slot = std.meta.FieldEnum(Ui);

    pub fn setByName(self: *Ui, name: []const u8, c: Color) bool {
        inline for (comptime std.meta.fieldNames(Ui)) |f| {
            if (std.mem.eql(u8, name, f)) {
                @field(self, f) = c;
                return true;
            }
        }
        return false;
    }

    pub fn has(name: []const u8) bool {
        inline for (comptime std.meta.fieldNames(Ui)) |f| {
            if (std.mem.eql(u8, name, f)) return true;
        }
        return false;
    }

    fn setSlot(self: *Ui, slot: Slot, c: Color) void {
        inline for (comptime std.meta.fieldNames(Ui)) |f| {
            if (slot == @field(Slot, f)) @field(self, f) = c;
        }
    }
};

/// A resolved theme: what the programs read colours from.
pub const Theme = struct {
    /// Borrowed: a built-in's static name, or the config arena's copy.
    name: []const u8,
    dark: bool,
    syntax: syntax.Theme,
    ui: Ui,
    /// The nine-patch style the popups are framed with.
    panel_style: []const u8,
};

const SyntaxPair = struct { Group, u24 };
const UiPair = struct { Ui.Slot, u24 };

/// A built-in theme.
pub const Spec = struct {
    name: []const u8,
    dark: bool = true,
    /// Null picks by `dark`: `panel` or `panel_light`.
    panel_style: ?[]const u8 = null,
    palette: Palette,
    syntax: []const SyntaxPair = &.{},
    ui: []const UiPair = &.{},
};

/// One `name = "#rrggbb"` from a config table.
pub const NamedColor = struct {
    name: []const u8,
    color: Color,
};

/// A theme a config defined (`config.themes.<name>`, or the table form
/// of `config.theme`). Every string is borrowed from the config's arena.
pub const Custom = struct {
    name: []const u8,
    /// The theme this one starts from, built-in or custom. Null is
    /// `default`.
    base: ?[]const u8 = null,
    dark: ?bool = null,
    panel_style: ?[]const u8 = null,
    /// Replaces the base's palette colours before derivation.
    palette: []const NamedColor = &.{},
    /// Capture-group colours, by `syntax.Theme` name (`keyword`,
    /// `string.escape`), laid over the derived ones.
    syntax: []const NamedColor = &.{},
    /// `Ui` slots by field name, laid over the derived ones.
    ui: []const NamedColor = &.{},
};

/// The bundled light popup frame (`assets/ninepatch/panel_light.9.png`).
pub const panel_light = "panel_light";
pub const panel_dark = "panel";

/// The theme with no config: zoe's original palette.
pub const default_name = "default";

/// How deep `base` chains may go. Far past any real use; what it
/// actually guards is a cycle (`a` based on `b` based on `a`).
const max_base_depth = 16;

/// `name` resolved against the config's `customs` first (so a config can
/// shadow a built-in) and then the built-ins. Null for an unknown name or
/// a `base` chain that never reaches a built-in.
pub fn resolve(name: []const u8, customs: []const Custom) ?Theme {
    // The chain, leaf first: customs[chain[0]] is `name` itself.
    var chain: [max_base_depth]*const Custom = undefined;
    var depth: usize = 0;
    var cur = name;
    const root: *const Spec = while (true) {
        if (findCustom(customs, cur)) |c| {
            // A custom naming itself as its base is the obvious mistake
            // (`themes.nord = { base = "nord", ... }` to tweak nord):
            // let that base fall through to the built-in of that name.
            if (depth == max_base_depth) return null;
            chain[depth] = c;
            depth += 1;
            const next = c.base orelse default_name;
            if (std.mem.eql(u8, next, c.name)) break builtin(next) orelse return null;
            cur = next;
            continue;
        }
        break builtin(cur) orelse return null;
    };

    var pal = root.palette;
    var dark = root.dark;
    var panel = root.panel_style;
    // Root to leaf, so the theme the user named wins.
    var i = depth;
    while (i > 0) {
        i -= 1;
        const c = chain[i];
        for (c.palette) |p| _ = pal.setByName(p.name, p.color);
        if (c.dark) |d| {
            dark = d;
            // A custom that flips `dark` without naming a frame wants
            // the other bundled one, not its base's.
            if (c.panel_style == null) panel = null;
        }
        if (c.panel_style) |s| panel = s;
    }

    var t = derive(pal, dark);
    // The stored copy of the name, never `name` itself: a caller may
    // resolve a name it is only borrowing (`:theme`'s argument).
    t.name = if (depth > 0) chain[0].name else root.name;
    t.panel_style = panel orelse (if (dark) panel_dark else panel_light);
    for (root.syntax) |p| t.syntax.colors.set(p[0], rgb(p[1]));
    for (root.ui) |p| t.ui.setSlot(p[0], rgb(p[1]));
    i = depth;
    while (i > 0) {
        i -= 1;
        const c = chain[i];
        for (c.syntax) |p| _ = t.syntax.setByName(p.name, p.color);
        for (c.ui) |p| _ = t.ui.setByName(p.name, p.color);
    }
    return t;
}

/// The built-in theme called `name`.
pub fn builtin(name: []const u8) ?*const Spec {
    for (&builtins) |*s| {
        if (std.mem.eql(u8, s.name, name)) return s;
    }
    return null;
}

/// The default theme, which always resolves.
pub fn initDefault() Theme {
    return resolve(default_name, &.{}).?;
}

fn findCustom(customs: []const Custom, name: []const u8) ?*const Custom {
    // Last one wins, the way a Lua table assigned twice would.
    var i = customs.len;
    while (i > 0) {
        i -= 1;
        if (std.mem.eql(u8, customs[i].name, name)) return &customs[i];
    }
    return null;
}

/// The whole theme from a palette alone: One Dark's capture mapping for
/// the syntax half, blends for the UI half. A spec's explicit pairs go
/// on top of this.
pub fn derive(p: Palette, dark: bool) Theme {
    var s = syntax.Theme{ .colors = std.EnumArray(Group, ?Color).initFill(null) };
    const set = struct {
        fn f(st: *syntax.Theme, g: Group, hex: u24) void {
            st.colors.set(g, rgb(hex));
        }
    }.f;
    set(&s, .comment, p.comment);
    set(&s, .keyword, p.purple);
    set(&s, .string, p.green);
    set(&s, .string_escape, p.cyan);
    set(&s, .string_special, p.cyan);
    set(&s, .escape, p.cyan);
    set(&s, .number, p.orange);
    set(&s, .boolean, p.orange);
    set(&s, .character, p.green);
    set(&s, .constant, p.orange);
    set(&s, .constant_builtin, p.orange);
    set(&s, .function, p.blue);
    set(&s, .function_builtin, p.blue);
    set(&s, .type, p.yellow);
    set(&s, .type_builtin, p.yellow);
    set(&s, .constructor, p.yellow);
    set(&s, .operator, p.cyan);
    set(&s, .property, p.red);
    set(&s, .variable_builtin, p.red);
    set(&s, .variable_parameter, p.orange);
    set(&s, .module, p.yellow);
    set(&s, .label, p.blue);
    set(&s, .attribute, p.orange);
    set(&s, .tag, p.red);
    set(&s, .punctuation_special, p.purple);
    set(&s, .text_title, p.blue);
    set(&s, .text_literal, p.green);
    set(&s, .text_uri, p.cyan);
    set(&s, .text_reference, p.red);

    const bg = rgb(p.bg);
    const fg = rgb(p.fg);
    const blue = rgb(p.blue);
    const popup = if (dark) mix(bg, rgb(p.bg_hi), 0.5) else mix(bg, rgb(p.bg_dark), 0.6);
    const popup_selected = mix(popup, blue, if (dark) 0.45 else 0.25);
    const black = rgb(0x000000);

    const ui: Ui = .{
        .bg_buffer = bg,
        .bg_tree = mix(bg, rgb(p.bg_dark), 0.5),
        .bg_status = rgb(p.bg_hi),
        .bg_tab_bar = rgb(p.bg_dark),
        .bg_tab = mix(bg, rgb(p.bg_hi), 0.5),
        // See `Ui.bg_shell`: a light theme's terminal is its text colour
        // taken most of the way to black.
        .bg_shell = if (dark) mix(bg, black, 0.4) else mix(fg, black, 0.6),
        .fg_text = fg,
        .fg_dim = rgb(p.fg_dim),
        .fg_dir = blue,
        .fg_hidden = mix(fg, bg, 0.45),
        .fg_hidden_dir = mix(blue, bg, 0.45),
        .fg_status = fg,
        .fg_mode = rgb(p.green),
        .fg_error = rgb(p.red),
        .fg_whitespace = mix(rgb(p.fg_dim), bg, 0.5),
        .bg_cursor = rgb(p.cursor),
        .fg_cursor = bg,
        .bg_selected = rgb(p.selection),
        // Amber either way, so a search hit never reads as a selection.
        // A light theme's yellow is dark enough that the stronger
        // current-match tint goes to orange to keep text on it legible.
        .bg_match = mix(bg, rgb(p.yellow), if (dark) 0.28 else 0.22),
        .bg_match_current = if (dark) mix(bg, rgb(p.yellow), 0.55) else mix(bg, rgb(p.orange), 0.4),
        .fg_match = rgb(p.yellow),
        // Red/amber/blue/grey by severity: the convention every editor
        // and compiler shares, read at a glance and never looked up.
        .fg_diag_error = rgb(p.red),
        .fg_diag_warning = rgb(p.yellow),
        .fg_diag_info = blue,
        .fg_diag_hint = rgb(p.fg_dim),
        .bg_popup = popup,
        .fg_popup = fg,
        .bg_popup_code = if (dark) mix(popup, rgb(p.bg_dark), 0.5) else mix(popup, rgb(p.bg_hi), 0.5),
        .fg_popup_rule = mix(rgb(p.fg_dim), popup, 0.3),
        // The bundled frames' border colours (scripts/gen-ninepatches.py).
        .fg_popup_border = if (dark) rgb(0x68708c) else rgb(0xb8bcc8),
        .bg_popup_selected = popup_selected,
        .fg_popup_label = fg,
        .fg_popup_kind = blue,
        .fg_popup_detail = rgb(p.fg_dim),
        .bg_finder_header = if (dark) mix(bg, blue, 0.55) else blue,
        .fg_finder_header = if (dark) fg else bg,
        .bg_finder_selected = popup_selected,
        .fg_finder_selected = fg,
    };
    return .{ .name = "", .dark = dark, .syntax = s, .ui = ui, .panel_style = "" };
}

pub fn rgb(hex: u24) Color {
    return .{
        .r = @intCast((hex >> 16) & 0xff),
        .g = @intCast((hex >> 8) & 0xff),
        .b = @intCast(hex & 0xff),
    };
}

fn pack(c: Color) u24 {
    return (@as(u24, c.r) << 16) | (@as(u24, c.g) << 8) | c.b;
}

/// `a` taken `t` of the way to `b`.
pub fn mix(a: Color, b: Color, t: f32) Color {
    const ch = struct {
        fn f(x: u8, y: u8, k: f32) u8 {
            const fx: f32 = @floatFromInt(x);
            const fy: f32 = @floatFromInt(y);
            return @intFromFloat(@round(fx + (fy - fx) * k));
        }
    }.f;
    return .{ .r = ch(a.r, b.r, t), .g = ch(a.g, b.g, t), .b = ch(a.b, b.b, t) };
}

/// `#rrggbb` or `rrggbb`.
pub fn parseHex(s: []const u8) ?Color {
    const hex = if (s.len > 0 and s[0] == '#') s[1..] else s;
    if (hex.len != 6) return null;
    const v = std.fmt.parseInt(u24, hex, 16) catch return null;
    return rgb(v);
}

// ── The built-ins ───────────────────────────────────────────────────────
//
// Each copies the published palette of the editor theme it is named for,
// and the capture mapping where that differs from One Dark's. Groups a
// theme leaves to its plain text colour (Monokai's properties, Darcula's
// type names) are set to `fg` rather than dropped, so they don't fall
// back to the derived accent.

/// Catppuccin's four flavours share one mapping over different colours.
const Catppuccin = struct {
    name: []const u8,
    dark: bool = true,
    base: u24,
    mantle: u24,
    crust: u24,
    surface0: u24,
    surface1: u24,
    overlay0: u24,
    overlay2: u24,
    text: u24,
    rosewater: u24,
    pink: u24,
    mauve: u24,
    red: u24,
    maroon: u24,
    peach: u24,
    yellow: u24,
    green: u24,
    teal: u24,
    sky: u24,
    sapphire: u24,
    blue: u24,
    lavender: u24,
};

fn catppuccin(comptime f: Catppuccin) Spec {
    return .{
        .name = f.name,
        .dark = f.dark,
        .palette = .{
            .bg = f.base,
            .bg_dark = f.crust,
            .bg_hi = f.surface0,
            .fg = f.text,
            .fg_dim = f.overlay0,
            .comment = f.overlay2,
            .selection = f.surface1,
            .cursor = f.rosewater,
            .red = f.red,
            .orange = f.peach,
            .yellow = f.yellow,
            .green = f.green,
            .cyan = f.teal,
            .blue = f.blue,
            .purple = f.mauve,
        },
        .syntax = &.{
            .{ .string_escape, f.pink },
            .{ .string_special, f.pink },
            .{ .escape, f.pink },
            .{ .character, f.teal },
            .{ .constructor, f.sapphire },
            .{ .operator, f.sky },
            .{ .property, f.lavender },
            .{ .variable_parameter, f.maroon },
            .{ .module, f.lavender },
            .{ .label, f.sapphire },
            .{ .attribute, f.yellow },
            .{ .tag, f.blue },
            .{ .punctuation_special, f.sky },
            .{ .text_uri, f.rosewater },
            .{ .text_reference, f.lavender },
        },
        .ui = &.{
            .{ .bg_tree, f.mantle },
            .{ .bg_tab_bar, f.crust },
            .{ .bg_tab, f.mantle },
        },
    };
}

/// Solarized's two variants differ only in which end of the base tones
/// is the background.
fn solarized(comptime dark: bool) Spec {
    const base03 = 0x002b36;
    const base02 = 0x073642;
    const base01 = 0x586e75;
    const base00 = 0x657b83;
    const base0 = 0x839496;
    const base1 = 0x93a1a1;
    const base2 = 0xeee8d5;
    const base3 = 0xfdf6e3;
    return .{
        .name = if (dark) "solarized-dark" else "solarized-light",
        .dark = dark,
        .palette = .{
            .bg = if (dark) base03 else base3,
            .bg_dark = if (dark) 0x00212b else base2,
            .bg_hi = if (dark) base02 else 0xe4ddc8,
            .fg = if (dark) base0 else base00,
            .fg_dim = if (dark) base01 else base1,
            .comment = if (dark) base01 else base1,
            .selection = if (dark) 0x274642 else 0xe0dac6,
            .cursor = if (dark) base1 else base00,
            .red = 0xdc322f,
            .orange = 0xcb4b16,
            .yellow = 0xb58900,
            .green = 0x859900,
            .cyan = 0x2aa198,
            .blue = 0x268bd2,
            .purple = 0x6c71c4,
        },
        .syntax = &.{
            .{ .keyword, 0x859900 },
            .{ .string, 0x2aa198 },
            .{ .character, 0x2aa198 },
            .{ .string_escape, 0xdc322f },
            .{ .string_special, 0xdc322f },
            .{ .escape, 0xdc322f },
            .{ .number, 0xd33682 },
            .{ .boolean, 0xb58900 },
            .{ .constant, 0xcb4b16 },
            .{ .constant_builtin, 0xb58900 },
            .{ .function, 0x268bd2 },
            .{ .function_builtin, 0x268bd2 },
            .{ .type, 0xb58900 },
            .{ .type_builtin, 0x859900 },
            .{ .constructor, 0xcb4b16 },
            .{ .operator, 0x859900 },
            .{ .property, 0x268bd2 },
            .{ .variable_builtin, 0xcb4b16 },
            .{ .variable_parameter, if (dark) base1 else base01 },
            .{ .module, 0x6c71c4 },
            .{ .label, 0x6c71c4 },
            .{ .attribute, 0xb58900 },
            .{ .tag, 0x268bd2 },
            .{ .punctuation_special, 0xdc322f },
            .{ .text_title, 0xcb4b16 },
            .{ .text_literal, 0x2aa198 },
            .{ .text_uri, 0x6c71c4 },
            .{ .text_reference, 0x268bd2 },
        },
        // The light variant's terminal is the dark variant's background.
        .ui = if (dark) &.{} else &.{.{ .bg_shell, base03 }},
    };
}

pub const builtins = [_]Spec{
    // zoe's original hand-tuned palette, every UI slot pinned to the
    // value it had as a constant in `zoe/ui.zig`, so choosing no theme
    // changes nothing on screen. One Dark's syntax colours.
    .{
        .name = default_name,
        .palette = .{
            .bg = 0x18181d,
            .bg_dark = 0x101014,
            .bg_hi = 0x2e2e38,
            .fg = 0xd2d2da,
            .fg_dim = 0x5c5c68,
            .comment = 0x5c6370,
            .selection = 0x303e54,
            .cursor = 0xdcdce6,
            .red = 0xe06c75,
            .orange = 0xd19a66,
            .yellow = 0xe5c07b,
            .green = 0x98c379,
            .cyan = 0x56b6c2,
            .blue = 0x61afef,
            .purple = 0xc678dd,
        },
        .ui = &.{
            .{ .bg_tree, 0x141419 },
            .{ .bg_tab, 0x222229 },
            .{ .bg_shell, 0x0e0f12 },
            .{ .fg_dir, 0x84b0e8 },
            .{ .fg_hidden, 0x707078 },
            .{ .fg_hidden_dir, 0x546c8e },
            .{ .fg_status, 0xe2e2ec },
            .{ .fg_mode, 0x96dca0 },
            .{ .fg_error, 0xf08c8c },
            .{ .fg_whitespace, 0x3e3e48 },
            .{ .bg_match, 0x544422 },
            .{ .bg_match_current, 0x96742a },
            .{ .fg_match, 0xffbe3c },
            .{ .fg_diag_error, 0xe85c5c },
            .{ .fg_diag_warning, 0xe2b04a },
            .{ .fg_diag_info, 0x6ca4e8 },
            .{ .fg_diag_hint, 0x848494 },
            .{ .bg_popup, 0x22222a },
            .{ .fg_popup, 0xd6d6de },
            .{ .bg_popup_code, 0x1a1a20 },
            .{ .fg_popup_rule, 0x505060 },
            .{ .fg_popup_border, 0x68708c },
            .{ .bg_popup_selected, 0x3c5a96 },
            .{ .fg_popup_label, 0xe2e2ea },
            .{ .fg_popup_kind, 0x8caadc },
            .{ .fg_popup_detail, 0x828292 },
            .{ .bg_finder_header, 0x285aaa },
            .{ .fg_finder_header, 0xebf0fa },
            .{ .bg_finder_selected, 0x4678c8 },
            .{ .fg_finder_selected, 0xf5faff },
        },
    },
    .{
        .name = "one-dark",
        .palette = .{
            .bg = 0x282c34,
            .bg_dark = 0x21252b,
            .bg_hi = 0x333842,
            .fg = 0xabb2bf,
            .fg_dim = 0x4b5263,
            .comment = 0x5c6370,
            .selection = 0x3e4451,
            .cursor = 0x528bff,
            .red = 0xe06c75,
            .orange = 0xd19a66,
            .yellow = 0xe5c07b,
            .green = 0x98c379,
            .cyan = 0x56b6c2,
            .blue = 0x61afef,
            .purple = 0xc678dd,
        },
    },
    .{
        .name = "vscode-light",
        .dark = false,
        .palette = .{
            .bg = 0xffffff,
            .bg_dark = 0xf3f3f3,
            .bg_hi = 0xe5e5e5,
            .fg = 0x1f1f1f,
            .fg_dim = 0x6e7681,
            .comment = 0x008000,
            .selection = 0xadd6ff,
            .cursor = 0x000000,
            .red = 0xe51400,
            .orange = 0xc27c0e,
            .yellow = 0xbf8803,
            .green = 0x388a34,
            .cyan = 0x267f99,
            .blue = 0x0070c1,
            .purple = 0xaf00db,
        },
        .syntax = &.{
            .{ .keyword, 0x0000ff },
            .{ .string, 0xa31515 },
            .{ .character, 0xa31515 },
            .{ .string_escape, 0xee0000 },
            .{ .string_special, 0xee0000 },
            .{ .escape, 0xee0000 },
            .{ .number, 0x098658 },
            .{ .boolean, 0x0000ff },
            .{ .constant, 0x0070c1 },
            .{ .constant_builtin, 0x0000ff },
            .{ .function, 0x795e26 },
            .{ .function_builtin, 0x795e26 },
            .{ .type, 0x267f99 },
            .{ .type_builtin, 0x0000ff },
            .{ .constructor, 0x267f99 },
            .{ .operator, 0x1f1f1f },
            .{ .property, 0x001080 },
            .{ .variable_builtin, 0x0000ff },
            .{ .variable_parameter, 0x001080 },
            .{ .module, 0x267f99 },
            .{ .label, 0x795e26 },
            .{ .attribute, 0xe50000 },
            .{ .tag, 0x800000 },
            .{ .punctuation_special, 0x0000ff },
            .{ .text_title, 0x800000 },
            .{ .text_literal, 0x800000 },
            .{ .text_uri, 0x0451a5 },
            .{ .text_reference, 0x0451a5 },
        },
        // VS Code's blue status bar, white on it.
        .ui = &.{
            .{ .bg_status, 0x007acc },
            .{ .fg_status, 0xffffff },
            .{ .fg_mode, 0xffffff },
            .{ .fg_error, 0xffd6d6 },
            .{ .bg_tab, 0xececec },
        },
    },
    .{
        .name = "github-dark",
        .palette = .{
            .bg = 0x0d1117,
            .bg_dark = 0x010409,
            .bg_hi = 0x21262d,
            .fg = 0xe6edf3,
            .fg_dim = 0x6e7681,
            .comment = 0x8b949e,
            .selection = 0x1f3b5a,
            .cursor = 0x2f81f7,
            .red = 0xf85149,
            .orange = 0xffa657,
            .yellow = 0xd29922,
            .green = 0x3fb950,
            .cyan = 0x39c5cf,
            .blue = 0x58a6ff,
            .purple = 0xbc8cff,
        },
        .syntax = &github_dark_syntax,
    },
    .{
        .name = "github-light",
        .dark = false,
        .palette = .{
            .bg = 0xffffff,
            .bg_dark = 0xf6f8fa,
            .bg_hi = 0xeaeef2,
            .fg = 0x1f2328,
            .fg_dim = 0x8c959f,
            .comment = 0x6e7781,
            .selection = 0xc3dcf7,
            .cursor = 0x0969da,
            .red = 0xcf222e,
            .orange = 0xbc4c00,
            .yellow = 0x9a6700,
            .green = 0x1a7f37,
            .cyan = 0x1b7c83,
            .blue = 0x0969da,
            .purple = 0x8250df,
        },
        .syntax = &.{
            .{ .keyword, 0xcf222e },
            .{ .string, 0x0a3069 },
            .{ .character, 0x0a3069 },
            .{ .string_escape, 0x0550ae },
            .{ .string_special, 0x0550ae },
            .{ .escape, 0x0550ae },
            .{ .number, 0x0550ae },
            .{ .boolean, 0x0550ae },
            .{ .constant, 0x0550ae },
            .{ .constant_builtin, 0x0550ae },
            .{ .function, 0x8250df },
            .{ .function_builtin, 0x8250df },
            .{ .type, 0x953800 },
            .{ .type_builtin, 0x953800 },
            .{ .constructor, 0x953800 },
            .{ .operator, 0xcf222e },
            .{ .property, 0x0550ae },
            .{ .variable_builtin, 0x0550ae },
            .{ .variable_parameter, 0x953800 },
            .{ .module, 0x953800 },
            .{ .label, 0x8250df },
            .{ .attribute, 0x0550ae },
            .{ .tag, 0x116329 },
            .{ .punctuation_special, 0xcf222e },
            .{ .text_title, 0x0550ae },
            .{ .text_literal, 0x0a3069 },
            .{ .text_uri, 0x0a3069 },
            .{ .text_reference, 0x0550ae },
        },
    },
    catppuccin(.{
        .name = "catppuccin-mocha",
        .base = 0x1e1e2e,
        .mantle = 0x181825,
        .crust = 0x11111b,
        .surface0 = 0x313244,
        .surface1 = 0x45475a,
        .overlay0 = 0x6c7086,
        .overlay2 = 0x9399b2,
        .text = 0xcdd6f4,
        .rosewater = 0xf5e0dc,
        .pink = 0xf5c2e7,
        .mauve = 0xcba6f7,
        .red = 0xf38ba8,
        .maroon = 0xeba0ac,
        .peach = 0xfab387,
        .yellow = 0xf9e2af,
        .green = 0xa6e3a1,
        .teal = 0x94e2d5,
        .sky = 0x89dceb,
        .sapphire = 0x74c7ec,
        .blue = 0x89b4fa,
        .lavender = 0xb4befe,
    }),
    catppuccin(.{
        .name = "catppuccin-macchiato",
        .base = 0x24273a,
        .mantle = 0x1e2030,
        .crust = 0x181926,
        .surface0 = 0x363a4f,
        .surface1 = 0x494d64,
        .overlay0 = 0x6e738d,
        .overlay2 = 0x939ab7,
        .text = 0xcad3f5,
        .rosewater = 0xf4dbd6,
        .pink = 0xf5bde6,
        .mauve = 0xc6a0f6,
        .red = 0xed8796,
        .maroon = 0xee99a0,
        .peach = 0xf5a97f,
        .yellow = 0xeed49f,
        .green = 0xa6da95,
        .teal = 0x8bd5ca,
        .sky = 0x91d7e3,
        .sapphire = 0x7dc4e4,
        .blue = 0x8aadf4,
        .lavender = 0xb7bdf8,
    }),
    catppuccin(.{
        .name = "catppuccin-frappe",
        .base = 0x303446,
        .mantle = 0x292c3c,
        .crust = 0x232634,
        .surface0 = 0x414559,
        .surface1 = 0x51576d,
        .overlay0 = 0x737994,
        .overlay2 = 0x949cbb,
        .text = 0xc6d0f5,
        .rosewater = 0xf2d5cf,
        .pink = 0xf4b8e4,
        .mauve = 0xca9ee6,
        .red = 0xe78284,
        .maroon = 0xea999c,
        .peach = 0xef9f76,
        .yellow = 0xe5c890,
        .green = 0xa6d189,
        .teal = 0x81c8be,
        .sky = 0x99d1db,
        .sapphire = 0x85c1dc,
        .blue = 0x8caaee,
        .lavender = 0xbabbf1,
    }),
    catppuccin(.{
        .name = "catppuccin-latte",
        .dark = false,
        .base = 0xeff1f5,
        .mantle = 0xe6e9ef,
        .crust = 0xdce0e8,
        .surface0 = 0xccd0da,
        .surface1 = 0xbcc0cc,
        .overlay0 = 0x9ca0b0,
        .overlay2 = 0x7c7f93,
        .text = 0x4c4f69,
        .rosewater = 0xdc8a78,
        .pink = 0xea76cb,
        .mauve = 0x8839ef,
        .red = 0xd20f39,
        .maroon = 0xe64553,
        .peach = 0xfe640b,
        .yellow = 0xdf8e1d,
        .green = 0x40a02b,
        .teal = 0x179299,
        .sky = 0x04a5e5,
        .sapphire = 0x209fb5,
        .blue = 0x1e66f5,
        .lavender = 0x7287fd,
    }),
    .{
        .name = "tokyo-night",
        .palette = .{
            .bg = 0x1a1b26,
            .bg_dark = 0x16161e,
            .bg_hi = 0x292e42,
            .fg = 0xc0caf5,
            .fg_dim = 0x545c7e,
            .comment = 0x565f89,
            .selection = 0x283457,
            .cursor = 0xc0caf5,
            .red = 0xf7768e,
            .orange = 0xff9e64,
            .yellow = 0xe0af68,
            .green = 0x9ece6a,
            .cyan = 0x7dcfff,
            .blue = 0x7aa2f7,
            .purple = 0xbb9af7,
        },
        .syntax = &.{
            .{ .string_escape, 0x89ddff },
            .{ .string_special, 0x89ddff },
            .{ .escape, 0x89ddff },
            .{ .type, 0x2ac3de },
            .{ .type_builtin, 0x27a1b9 },
            .{ .constructor, 0x2ac3de },
            .{ .operator, 0x89ddff },
            .{ .property, 0x73daca },
            .{ .variable_builtin, 0xf7768e },
            .{ .variable_parameter, 0xe0af68 },
            .{ .module, 0x7dcfff },
            .{ .attribute, 0x2ac3de },
            .{ .tag, 0xf7768e },
            .{ .punctuation_special, 0x89ddff },
            .{ .text_uri, 0x73daca },
            .{ .text_reference, 0x73daca },
        },
    },
    solarized(true),
    solarized(false),
    .{
        .name = "darcula",
        .palette = .{
            .bg = 0x2b2b2b,
            .bg_dark = 0x232525,
            .bg_hi = 0x3c3f41,
            .fg = 0xa9b7c6,
            .fg_dim = 0x606366,
            .comment = 0x808080,
            .selection = 0x214283,
            .cursor = 0xbbbbbb,
            .red = 0xbc3f3c,
            .orange = 0xcc7832,
            .yellow = 0xffc66d,
            .green = 0x6a8759,
            .cyan = 0x629755,
            .blue = 0x6897bb,
            .purple = 0x9876aa,
        },
        .syntax = &.{
            .{ .keyword, 0xcc7832 },
            .{ .string, 0x6a8759 },
            .{ .character, 0x6a8759 },
            .{ .string_escape, 0xcc7832 },
            .{ .string_special, 0xcc7832 },
            .{ .escape, 0xcc7832 },
            .{ .number, 0x6897bb },
            .{ .boolean, 0xcc7832 },
            .{ .constant, 0x9876aa },
            .{ .constant_builtin, 0xcc7832 },
            .{ .function, 0xffc66d },
            .{ .function_builtin, 0xffc66d },
            .{ .type, 0xa9b7c6 },
            .{ .type_builtin, 0xcc7832 },
            .{ .constructor, 0xffc66d },
            .{ .operator, 0xa9b7c6 },
            .{ .property, 0x9876aa },
            .{ .variable_builtin, 0x94558d },
            .{ .variable_parameter, 0xa9b7c6 },
            .{ .module, 0xa9b7c6 },
            .{ .label, 0x9876aa },
            .{ .attribute, 0xbbb529 },
            .{ .tag, 0xe8bf6a },
            .{ .punctuation_special, 0xcc7832 },
            .{ .text_title, 0xcc7832 },
            .{ .text_literal, 0x6a8759 },
            .{ .text_uri, 0x287bde },
            .{ .text_reference, 0x287bde },
        },
    },
    .{
        .name = "cobalt2",
        .palette = .{
            .bg = 0x193549,
            .bg_dark = 0x15232d,
            .bg_hi = 0x234e6d,
            .fg = 0xffffff,
            .fg_dim = 0x4f6b7f,
            .comment = 0x0088ff,
            .selection = 0x0050a4,
            .cursor = 0xffc600,
            .red = 0xff628c,
            .orange = 0xff9d00,
            .yellow = 0xffc600,
            .green = 0x3ad900,
            .cyan = 0x80fcff,
            .blue = 0x0088ff,
            .purple = 0xfb94ff,
        },
        .syntax = &.{
            .{ .keyword, 0xff9d00 },
            .{ .string, 0xa5ff90 },
            .{ .character, 0xa5ff90 },
            .{ .string_escape, 0x80ffbb },
            .{ .string_special, 0x80ffbb },
            .{ .escape, 0x80ffbb },
            .{ .number, 0xff628c },
            .{ .boolean, 0xff628c },
            .{ .constant, 0xff628c },
            .{ .constant_builtin, 0xff628c },
            .{ .function, 0xffc600 },
            .{ .function_builtin, 0xffc600 },
            .{ .type, 0x80ffbb },
            .{ .type_builtin, 0x80ffbb },
            .{ .constructor, 0x80ffbb },
            .{ .operator, 0xff9d00 },
            .{ .property, 0x9effff },
            .{ .variable_builtin, 0xfb94ff },
            .{ .variable_parameter, 0xffffff },
            .{ .module, 0x80ffbb },
            .{ .label, 0xffc600 },
            .{ .attribute, 0xffc600 },
            .{ .tag, 0x9effff },
            .{ .punctuation_special, 0xff9d00 },
            .{ .text_title, 0xffc600 },
            .{ .text_literal, 0xa5ff90 },
            .{ .text_uri, 0x9effff },
            .{ .text_reference, 0x9effff },
        },
        // The comment blue is the theme's brightest accent; the tree's
        // directories take the property cyan instead.
        .ui = &.{.{ .fg_dir, 0x9effff }},
    },
    .{
        .name = "dracula",
        .palette = .{
            .bg = 0x282a36,
            .bg_dark = 0x21222c,
            .bg_hi = 0x44475a,
            .fg = 0xf8f8f2,
            .fg_dim = 0x6272a4,
            .comment = 0x6272a4,
            .selection = 0x44475a,
            .cursor = 0xf8f8f2,
            .red = 0xff5555,
            .orange = 0xffb86c,
            .yellow = 0xf1fa8c,
            .green = 0x50fa7b,
            .cyan = 0x8be9fd,
            // Dracula has no blue; cyan stands in.
            .blue = 0x8be9fd,
            .purple = 0xbd93f9,
        },
        .syntax = &.{
            .{ .keyword, 0xff79c6 },
            .{ .string, 0xf1fa8c },
            .{ .character, 0xf1fa8c },
            .{ .string_escape, 0xff79c6 },
            .{ .string_special, 0xff79c6 },
            .{ .escape, 0xff79c6 },
            .{ .number, 0xbd93f9 },
            .{ .boolean, 0xbd93f9 },
            .{ .constant, 0xbd93f9 },
            .{ .constant_builtin, 0xbd93f9 },
            .{ .function, 0x50fa7b },
            .{ .function_builtin, 0x50fa7b },
            .{ .type, 0x8be9fd },
            .{ .type_builtin, 0x8be9fd },
            .{ .constructor, 0x8be9fd },
            .{ .operator, 0xff79c6 },
            .{ .property, 0xf8f8f2 },
            .{ .variable_builtin, 0xbd93f9 },
            .{ .variable_parameter, 0xffb86c },
            .{ .module, 0x8be9fd },
            .{ .label, 0x8be9fd },
            .{ .attribute, 0x50fa7b },
            .{ .tag, 0xff79c6 },
            .{ .punctuation_special, 0xff79c6 },
            .{ .text_title, 0xbd93f9 },
            .{ .text_literal, 0x50fa7b },
            .{ .text_uri, 0x8be9fd },
            .{ .text_reference, 0x8be9fd },
        },
    },
    .{
        .name = "nord",
        .palette = .{
            .bg = 0x2e3440,
            .bg_dark = 0x242933,
            .bg_hi = 0x3b4252,
            .fg = 0xd8dee9,
            .fg_dim = 0x4c566a,
            .comment = 0x616e88,
            .selection = 0x434c5e,
            .cursor = 0xd8dee9,
            .red = 0xbf616a,
            .orange = 0xd08770,
            .yellow = 0xebcb8b,
            .green = 0xa3be8c,
            .cyan = 0x88c0d0,
            .blue = 0x81a1c1,
            .purple = 0xb48ead,
        },
        .syntax = &.{
            .{ .keyword, 0x81a1c1 },
            .{ .string_escape, 0xebcb8b },
            .{ .string_special, 0xebcb8b },
            .{ .escape, 0xebcb8b },
            .{ .character, 0xebcb8b },
            .{ .number, 0xb48ead },
            .{ .boolean, 0x81a1c1 },
            .{ .constant, 0xb48ead },
            .{ .constant_builtin, 0x81a1c1 },
            .{ .function, 0x88c0d0 },
            .{ .function_builtin, 0x88c0d0 },
            .{ .type, 0x8fbcbb },
            .{ .type_builtin, 0x81a1c1 },
            .{ .constructor, 0x8fbcbb },
            .{ .operator, 0x81a1c1 },
            .{ .property, 0xd8dee9 },
            .{ .variable_builtin, 0x81a1c1 },
            .{ .variable_parameter, 0xd8dee9 },
            .{ .module, 0x8fbcbb },
            .{ .label, 0x8fbcbb },
            .{ .attribute, 0xd08770 },
            .{ .tag, 0x81a1c1 },
            .{ .punctuation_special, 0x81a1c1 },
            .{ .text_title, 0x88c0d0 },
            .{ .text_uri, 0x88c0d0 },
            .{ .text_reference, 0x88c0d0 },
        },
    },
    .{
        .name = "gruvbox-dark",
        .palette = .{
            .bg = 0x282828,
            .bg_dark = 0x1d2021,
            .bg_hi = 0x3c3836,
            .fg = 0xebdbb2,
            .fg_dim = 0x7c6f64,
            .comment = 0x928374,
            .selection = 0x504945,
            .cursor = 0xebdbb2,
            .red = 0xfb4934,
            .orange = 0xfe8019,
            .yellow = 0xfabd2f,
            .green = 0xb8bb26,
            .cyan = 0x8ec07c,
            .blue = 0x83a598,
            .purple = 0xd3869b,
        },
        .syntax = &.{
            .{ .keyword, 0xfb4934 },
            .{ .string_escape, 0xfe8019 },
            .{ .string_special, 0xfe8019 },
            .{ .escape, 0xfe8019 },
            .{ .character, 0xd3869b },
            .{ .number, 0xd3869b },
            .{ .boolean, 0xd3869b },
            .{ .constant, 0xd3869b },
            .{ .constant_builtin, 0xd3869b },
            .{ .function, 0xfabd2f },
            .{ .function_builtin, 0xfe8019 },
            .{ .operator, 0xfe8019 },
            .{ .property, 0x83a598 },
            .{ .variable_builtin, 0xfe8019 },
            .{ .variable_parameter, 0x83a598 },
            .{ .module, 0x8ec07c },
            .{ .label, 0xfb4934 },
            .{ .attribute, 0x8ec07c },
            .{ .tag, 0x8ec07c },
            .{ .punctuation_special, 0xfe8019 },
            .{ .text_title, 0xb8bb26 },
            .{ .text_uri, 0xd3869b },
            .{ .text_reference, 0x83a598 },
        },
    },
    .{
        .name = "monokai",
        .palette = .{
            .bg = 0x272822,
            .bg_dark = 0x1e1f1c,
            .bg_hi = 0x3e3d32,
            .fg = 0xf8f8f2,
            .fg_dim = 0x90908a,
            .comment = 0x88846f,
            .selection = 0x49483e,
            .cursor = 0xf8f8f0,
            .red = 0xf92672,
            .orange = 0xfd971f,
            .yellow = 0xe6db74,
            .green = 0xa6e22e,
            .cyan = 0x66d9ef,
            .blue = 0x66d9ef,
            .purple = 0xae81ff,
        },
        .syntax = &.{
            .{ .keyword, 0xf92672 },
            .{ .string, 0xe6db74 },
            .{ .character, 0xe6db74 },
            .{ .string_escape, 0xae81ff },
            .{ .string_special, 0xae81ff },
            .{ .escape, 0xae81ff },
            .{ .number, 0xae81ff },
            .{ .boolean, 0xae81ff },
            .{ .constant, 0xae81ff },
            .{ .constant_builtin, 0xae81ff },
            .{ .function, 0xa6e22e },
            .{ .function_builtin, 0x66d9ef },
            .{ .type, 0x66d9ef },
            .{ .type_builtin, 0x66d9ef },
            .{ .constructor, 0xa6e22e },
            .{ .operator, 0xf92672 },
            .{ .property, 0xf8f8f2 },
            .{ .variable_builtin, 0xfd971f },
            .{ .variable_parameter, 0xfd971f },
            .{ .module, 0xa6e22e },
            .{ .label, 0xe6db74 },
            .{ .attribute, 0xa6e22e },
            .{ .tag, 0xf92672 },
            .{ .punctuation_special, 0xf92672 },
            .{ .text_title, 0xa6e22e },
            .{ .text_literal, 0xe6db74 },
            .{ .text_uri, 0x66d9ef },
            .{ .text_reference, 0x66d9ef },
        },
    },
};

const github_dark_syntax = [_]SyntaxPair{
    .{ .keyword, 0xff7b72 },
    .{ .string, 0xa5d6ff },
    .{ .character, 0xa5d6ff },
    .{ .string_escape, 0x79c0ff },
    .{ .string_special, 0x79c0ff },
    .{ .escape, 0x79c0ff },
    .{ .number, 0x79c0ff },
    .{ .boolean, 0x79c0ff },
    .{ .constant, 0x79c0ff },
    .{ .constant_builtin, 0x79c0ff },
    .{ .function, 0xd2a8ff },
    .{ .function_builtin, 0xd2a8ff },
    .{ .type, 0xffa657 },
    .{ .type_builtin, 0xffa657 },
    .{ .constructor, 0xffa657 },
    .{ .operator, 0xff7b72 },
    .{ .property, 0x79c0ff },
    .{ .variable_builtin, 0x79c0ff },
    .{ .variable_parameter, 0xffa657 },
    .{ .module, 0xffa657 },
    .{ .label, 0xd2a8ff },
    .{ .attribute, 0x79c0ff },
    .{ .tag, 0x7ee787 },
    .{ .punctuation_special, 0xff7b72 },
    .{ .text_title, 0x79c0ff },
    .{ .text_literal, 0xa5d6ff },
    .{ .text_uri, 0xa5d6ff },
    .{ .text_reference, 0x79c0ff },
};
