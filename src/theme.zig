// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: MPL-2.0

//! Colour themes: the 24-slot palette, the well-known roles, the built-in
//! set, and resolving a theme name (built-in or one a config defined) to
//! concrete colours.
//!
//! A theme is two tables:
//!
//!   `slots`  24 colours: the eight ANSI hues (black red green yellow blue
//!            magenta cyan white) at three levels -- 0-7 dim, 8-15
//!            normal, 16-23 bright. ANSI escape output draws from these
//!            (`30`-`37` is 8-15, `90`-`97` and bold are 16-23, `2` dim
//!            is 0-7), so a program's `ls --color` and a glyphwire-native
//!            program agree on what "red" is.
//!   `roles`  what a colour is *for*: `fg`, `bg`, `keyword`, `heading1`,
//!            `table_header_bg`, `popup_border`, ... (`Role`). Each names
//!            a slot, a literal colour, or another role.
//!
//! A program sends a `Color` that *refers* to a slot or a role
//! (`Color.slot`, `Color.role`) instead of RGB, and the host resolves it
//! against the theme of the context that drew it -- at render time, so
//! switching theme recolours everything already on screen.
//!
//! Nobody writes all of that out by hand. A built-in is *specified* as a
//! fifteen-colour `Palette` -- a few backgrounds, the text colours, and
//! seven accents -- and both tables are derived from it (`derive`), the
//! syntax roles with the One Dark capture mapping and the chrome with
//! blends between the backgrounds and accents. Then a spec's own explicit
//! pairs are laid over the result: that is how a built-in keeps the
//! capture mapping of the editor theme it copies (GitHub's keywords are
//! red, not purple) and how `default` stays pixel-identical to the
//! hand-tuned palette zoe shipped before themes existed.
//!
//! A config's theme (`Custom`) is the same idea one level up: a `base`
//! theme, palette colours that replace the base's *before* derivation,
//! then slot and role overrides after it. Changing `palette.bg` therefore
//! moves every colour blended from it; changing a slot moves every role
//! that names that slot, but not a blend that was computed from it.
//!
//! Pure data and arithmetic -- no Lua, no wire. `applib/themeconf.zig`
//! parses the Lua tables into `Custom`s.

const std = @import("std");
const core = @import("core.zig");

const Color = core.Color;

// ── Slots ───────────────────────────────────────────────────────────────

pub const slot_count = 24;

/// A palette index, 0-23.
pub const Slot = u5;

/// The eight ANSI hues, in ANSI order.
pub const Hue = enum(u3) { black, red, green, yellow, blue, magenta, cyan, white };

pub const Level = enum(u2) { dim, normal, bright };

pub fn slot(level: Level, hue: Hue) Slot {
    return @as(Slot, @intFromEnum(level)) * 8 + @intFromEnum(hue);
}

pub fn slotHue(s: Slot) Hue {
    return @enumFromInt(s % 8);
}

pub fn slotLevel(s: Slot) Level {
    return @enumFromInt(s / 8);
}

/// ANSI colour `n` (0-7 normal, 8-15 bright) as a slot.
pub fn ansiSlot(n: u4) Slot {
    return @as(Slot, n) + 8;
}

/// The same hue at `level`.
pub fn atLevel(s: Slot, level: Level) Slot {
    return slot(level, slotHue(s));
}

/// The slot names a config and the wire use: the hue for the normal
/// level, `dim_`/`bright_` prefixed for the other two.
pub const slot_names = blk: {
    var names: [slot_count][]const u8 = undefined;
    for (0..slot_count) |i| {
        const hue = @tagName(@as(Hue, @enumFromInt(i % 8)));
        names[i] = switch (i / 8) {
            0 => "dim_" ++ hue,
            1 => hue,
            else => "bright_" ++ hue,
        };
    }
    break :blk names;
};

pub fn slotByName(name: []const u8) ?Slot {
    for (slot_names, 0..) |n, i| {
        if (std.mem.eql(u8, n, name)) return @intCast(i);
    }
    return null;
}

// ── Roles ───────────────────────────────────────────────────────────────

/// What a colour is for. The names are the wire and config form; the
/// numeric order is append-only, so an index a program stored stays
/// meaningful. A role without a background suffix is a foreground.
pub const Role = enum(u8) {
    // Base text and surfaces.
    /// The default text colour: every cell nobody gave an `fg`.
    fg,
    /// Secondary text: line numbers, detail columns, hints.
    fg_dim,
    /// Emphasised text: bold-ish titles, the active pane's title.
    fg_strong,
    /// The main surface: an editor pane, a terminal's background.
    bg,
    /// The darkest chrome (a tab bar, a key bar).
    bg_dark,
    /// Raised chrome (a status bar, a button).
    bg_raised,
    border,
    accent,
    link,
    selection_bg,
    cursor_bg,
    cursor_fg,

    // Status.
    success,
    message,
    message_error,
    diag_error,
    diag_warning,
    diag_info,
    diag_hint,

    // Search.
    match,
    match_bg,
    match_current_bg,

    // Files: a tree, `gw-ls`, salacommander's panes.
    file,
    dir,
    symlink,
    exec,
    /// A device, socket or fifo.
    special,
    /// A dotfile or an ignored file shown anyway.
    hidden,
    hidden_dir,
    /// A multi-selected entry.
    marked,

    // Editor and app chrome.
    sidebar_bg,
    status_bg,
    status_fg,
    /// zoe's mode indicator.
    mode,
    tab_bar_bg,
    tab_bg,
    /// A terminal embedded in an app (zoe's and sala's Ctrl+` panel).
    shell_bg,
    whitespace,
    /// The focused pane's title bar, and the inactive ones'.
    title_bg,
    title_fg,
    title_inactive_bg,
    title_inactive_fg,
    /// The cursor row of a list that has focus, and of one that hasn't.
    list_cursor_bg,
    list_cursor_inactive_bg,
    /// A function-key bar: the key, and the label beside it.
    keybar_bg,
    keybar_key,
    keybar_label_bg,
    keybar_label,
    /// Grey completion text after the caret.
    suggestion,

    // Popups, dialogs, the finder.
    popup_bg,
    popup_fg,
    popup_code_bg,
    popup_rule,
    /// Keep this the colour of the popup nine-patch's border, which a
    /// `popup_rule` running into it has to meet.
    popup_border,
    popup_selected_bg,
    popup_label,
    popup_kind,
    popup_detail,
    finder_header_bg,
    finder_header_fg,
    finder_selected_bg,
    finder_selected_fg,
    dialog_bg,
    dialog_fg,
    dialog_title_bg,
    dialog_title_fg,
    /// A dialog asking about something destructive.
    danger_bg,
    input_bg,
    button_bg,
    button_focus_bg,

    // Documents (gwmd, hover text).
    heading1,
    heading2,
    heading3,
    heading4,
    heading5,
    heading6,
    strong,
    emphasis,
    strike,
    /// Inline code.
    code,
    code_bg,
    code_block,
    code_block_bg,
    quote,
    list_marker,
    rule,

    // Tables and outlines.
    table_header,
    table_header_bg,
    table_alt_row_bg,
    outline_marker,

    // Syntax: the tree-sitter capture groups (`applib/syntax.zig` maps a
    // dotted capture name down to one of these).
    comment,
    keyword,
    string,
    string_escape,
    string_special,
    escape,
    number,
    boolean,
    character,
    constant,
    constant_builtin,
    function,
    function_builtin,
    type,
    type_builtin,
    constructor,
    operator,
    property,
    variable,
    variable_builtin,
    variable_parameter,
    module,
    label,
    attribute,
    tag,
    punctuation,
    punctuation_special,
    text_title,
    text_literal,
    text_uri,
    text_reference,
};

pub const role_count = std.enums.values(Role).len;

/// The names zoe's `ui = { ... }` table used before roles existed, so an
/// old config keeps working.
const legacy_role_names = std.StaticStringMap(Role).initComptime(.{
    .{ "bg_buffer", .bg },
    .{ "bg_tree", .sidebar_bg },
    .{ "bg_status", .status_bg },
    .{ "bg_tab_bar", .tab_bar_bg },
    .{ "bg_tab", .tab_bg },
    .{ "bg_shell", .shell_bg },
    .{ "fg_text", .fg },
    .{ "fg_dir", .dir },
    .{ "fg_hidden", .hidden },
    .{ "fg_hidden_dir", .hidden_dir },
    .{ "fg_status", .status_fg },
    .{ "fg_mode", .mode },
    .{ "fg_error", .message_error },
    .{ "fg_whitespace", .whitespace },
    .{ "bg_cursor", .cursor_bg },
    .{ "fg_cursor", .cursor_fg },
    .{ "bg_selected", .selection_bg },
    .{ "bg_match", .match_bg },
    .{ "bg_match_current", .match_current_bg },
    .{ "fg_match", .match },
    .{ "fg_diag_error", .diag_error },
    .{ "fg_diag_warning", .diag_warning },
    .{ "fg_diag_info", .diag_info },
    .{ "fg_diag_hint", .diag_hint },
    .{ "bg_popup", .popup_bg },
    .{ "fg_popup", .popup_fg },
    .{ "bg_popup_code", .popup_code_bg },
    .{ "fg_popup_rule", .popup_rule },
    .{ "fg_popup_border", .popup_border },
    .{ "bg_popup_selected", .popup_selected_bg },
    .{ "fg_popup_label", .popup_label },
    .{ "fg_popup_kind", .popup_kind },
    .{ "fg_popup_detail", .popup_detail },
    .{ "bg_finder_header", .finder_header_bg },
    .{ "fg_finder_header", .finder_header_fg },
    .{ "bg_finder_selected", .finder_selected_bg },
    .{ "fg_finder_selected", .finder_selected_fg },
});

/// A role by its name, a legacy `ui` name, or a dotted capture group
/// (`string.escape`).
pub fn roleByName(name: []const u8) ?Role {
    if (std.meta.stringToEnum(Role, name)) |r| return r;
    if (legacy_role_names.get(name)) |r| return r;
    if (std.mem.indexOfScalar(u8, name, '.') != null) {
        var buf: [64]u8 = undefined;
        if (name.len > buf.len) return null;
        for (name, 0..) |ch, i| buf[i] = if (ch == '.') '_' else ch;
        return std.meta.stringToEnum(Role, buf[0..name.len]);
    }
    return null;
}

/// What a role resolves through.
pub const RoleValue = union(enum) {
    slot: Slot,
    rgb: Color,
    /// Another role's colour (`variable` is `fg` unless a theme says
    /// otherwise).
    role: Role,
};

/// How many `role` hops `Theme.roleColor` follows before it gives up on
/// a cycle and answers `fg`'s slot.
const max_role_hops = 8;

/// A resolved theme: what the host resolves `Color` references against.
pub const Theme = struct {
    /// Borrowed: a built-in's static name, or the owner's copy.
    name: []const u8,
    dark: bool,
    slots: [slot_count]Color,
    roles: std.EnumArray(Role, RoleValue),
    /// The nine-patch style popups are framed with -- a nine-patch is
    /// art and can't be recoloured, so a theme picks one.
    panel_style: []const u8,

    pub fn slotColor(self: *const Theme, s: Slot) Color {
        return self.slots[s];
    }

    /// The concrete colour of role `r`.
    pub fn roleColor(self: *const Theme, r: Role) Color {
        var cur = r;
        var hops: usize = 0;
        while (hops < max_role_hops) : (hops += 1) {
            switch (self.roles.get(cur)) {
                .slot => |s| return self.slots[s],
                .rgb => |c| return c,
                .role => |next| cur = next,
            }
        }
        return self.slots[slot(.normal, .white)];
    }

    /// `c` with any reference followed: its RGB from the slot or role,
    /// its alpha the reference's alpha times the theme colour's. A
    /// literal colour is returned as it is.
    pub fn resolve(self: *const Theme, c: Color) Color {
        const base = switch (c.ref) {
            .none => return c,
            .slot => |s| self.slots[s],
            .role => |r| self.roleColor(r),
        };
        return .{
            .r = base.r,
            .g = base.g,
            .b = base.b,
            .a = @intCast(@as(u16, base.a) * c.a / 255),
        };
    }

    /// The value a pair from a spec or config gets: the slot whose
    /// colour it is exactly, if there is one, so a later slot override
    /// carries it along; otherwise the literal.
    fn snap(self: *const Theme, c: Color) RoleValue {
        for (self.slots, 0..) |s, i| {
            if (s.r == c.r and s.g == c.g and s.b == c.b and s.a == c.a) return .{ .slot = @intCast(i) };
        }
        return .{ .rgb = c };
    }
};

/// A theme held by something that outlives what it was resolved from (a
/// `Context`, the `Session`): the two strings copied into inline buffers.
/// Plain data, so the holder can be moved; `theme.name` and
/// `theme.panel_style` are left empty and read through `name()` /
/// `panelStyle()` instead.
pub const Stored = struct {
    theme: Theme,
    name_buf: [max_name_len]u8 = undefined,
    name_len: u8 = 0,
    panel_buf: [max_name_len]u8 = undefined,
    panel_len: u8 = 0,

    pub const max_name_len = 64;

    pub fn init(t: Theme) Stored {
        var s: Stored = .{ .theme = t };
        s.set(t);
        return s;
    }

    /// Replaces the stored theme. Strings longer than `max_name_len`
    /// are cut.
    pub fn set(self: *Stored, t: Theme) void {
        self.theme = t;
        self.theme.name = "";
        self.theme.panel_style = "";
        self.name_len = @intCast(@min(t.name.len, max_name_len));
        @memcpy(self.name_buf[0..self.name_len], t.name[0..self.name_len]);
        self.panel_len = @intCast(@min(t.panel_style.len, max_name_len));
        @memcpy(self.panel_buf[0..self.panel_len], t.panel_style[0..self.panel_len]);
    }

    pub fn name(self: *const Stored) []const u8 {
        return self.name_buf[0..self.name_len];
    }

    pub fn panelStyle(self: *const Stored) []const u8 {
        return self.panel_buf[0..self.panel_len];
    }

    pub fn resolve(self: *const Stored, c: Color) Color {
        return self.theme.resolve(c);
    }
};

// ── Specs ───────────────────────────────────────────────────────────────

/// The colours a built-in is specified in. `u24` (`0xrrggbb`) so the
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

const RolePair = struct { Role, u24 };
const SlotPair = struct { Slot, u24 };

/// A built-in theme.
pub const Spec = struct {
    name: []const u8,
    dark: bool = true,
    /// Null picks by `dark`: `panel` or `panel_light`.
    panel_style: ?[]const u8 = null,
    palette: Palette,
    /// Slots set by hand over the derived ones.
    slots: []const SlotPair = &.{},
    /// Capture-group roles, then chrome roles, set by hand. Two lists
    /// only so a spec reads in the two halves people think of.
    syntax: []const RolePair = &.{},
    ui: []const RolePair = &.{},
};

/// One `name = "#rrggbb"` from a config table.
pub const NamedColor = struct {
    name: []const u8,
    color: Color,
};

pub const NamedSlot = struct {
    slot: Slot,
    color: Color,
};

pub const NamedRole = struct {
    role: Role,
    value: RoleValue,
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
    /// Slot colours, laid over the derived ones.
    slots: []const NamedSlot = &.{},
    /// Role values, laid over everything else.
    roles: []const NamedRole = &.{},
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
    for (root.slots) |p| t.slots[p[0]] = rgb(p[1]);
    for (root.syntax) |p| t.roles.set(p[0], t.snap(rgb(p[1])));
    for (root.ui) |p| t.roles.set(p[0], t.snap(rgb(p[1])));
    i = depth;
    while (i > 0) {
        i -= 1;
        const c = chain[i];
        for (c.slots) |p| t.slots[p.slot] = p.color;
        for (c.roles) |p| t.roles.set(p.role, p.value);
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

/// The slots from a palette alone. Each accent is its hue's normal
/// level; dim is that accent taken most of the way to the background,
/// bright a step further from it. Black and white are the theme's own
/// greys: on a dark theme black is the chrome and white the text, on a
/// light one the other way round, which is what a light terminal theme
/// does too (`30` stays the text-on-light colour).
pub fn deriveSlots(p: Palette, dark: bool) [slot_count]Color {
    var s: [slot_count]Color = undefined;
    const bg = rgb(p.bg);
    const white = rgb(0xffffff);
    const black = rgb(0x000000);
    const accents = [_]struct { Hue, u24 }{
        .{ .red, p.red },
        .{ .green, p.green },
        .{ .yellow, p.yellow },
        .{ .blue, p.blue },
        .{ .magenta, p.purple },
        .{ .cyan, p.cyan },
    };
    for (accents) |a| {
        const c = rgb(a[1]);
        s[slot(.dim, a[0])] = mix(c, bg, 0.45);
        s[slot(.normal, a[0])] = c;
        s[slot(.bright, a[0])] = if (dark) mix(c, white, 0.3) else mix(c, black, 0.25);
    }
    if (dark) {
        s[slot(.dim, .black)] = rgb(p.bg_dark);
        s[slot(.normal, .black)] = rgb(p.bg_hi);
        s[slot(.bright, .black)] = rgb(p.comment);
        s[slot(.dim, .white)] = rgb(p.fg_dim);
        s[slot(.normal, .white)] = rgb(p.fg);
        s[slot(.bright, .white)] = mix(rgb(p.fg), white, 0.5);
    } else {
        s[slot(.dim, .black)] = rgb(p.fg_dim);
        s[slot(.normal, .black)] = rgb(p.fg);
        s[slot(.bright, .black)] = rgb(p.comment);
        s[slot(.dim, .white)] = rgb(p.bg_hi);
        s[slot(.normal, .white)] = rgb(p.bg_dark);
        s[slot(.bright, .white)] = rgb(p.bg);
    }
    return s;
}

/// The whole theme from a palette alone: the derived slots, One Dark's
/// capture mapping for the syntax roles, blends for the chrome. A spec's
/// explicit pairs go on top of this.
pub fn derive(p: Palette, dark: bool) Theme {
    var t: Theme = .{
        .name = "",
        .dark = dark,
        .slots = deriveSlots(p, dark),
        .roles = .initFill(.{ .role = .fg }),
        .panel_style = "",
    };
    const R = struct {
        fn s(level: Level, hue: Hue) RoleValue {
            return .{ .slot = slot(level, hue) };
        }
        fn n(hue: Hue) RoleValue {
            return .{ .slot = slot(.normal, hue) };
        }
        fn c(col: Color) RoleValue {
            return .{ .rgb = col };
        }
        fn h(hex: u24) RoleValue {
            return .{ .rgb = rgb(hex) };
        }
        fn r(role: Role) RoleValue {
            return .{ .role = role };
        }
    };
    const set = struct {
        fn f(th: *Theme, role: Role, v: RoleValue) void {
            th.roles.set(role, v);
        }
    }.f;

    const bg = rgb(p.bg);
    const fg = rgb(p.fg);
    const blue = rgb(p.blue);
    const white = rgb(0xffffff);
    const black = rgb(0x000000);
    const popup = if (dark) mix(bg, rgb(p.bg_hi), 0.5) else mix(bg, rgb(p.bg_dark), 0.6);
    const popup_selected = mix(popup, blue, if (dark) 0.45 else 0.25);
    const header = if (dark) mix(bg, blue, 0.55) else blue;

    // Base.
    set(&t, .fg, R.c(fg));
    set(&t, .fg_dim, R.h(p.fg_dim));
    set(&t, .fg_strong, R.c(mix(fg, if (dark) white else black, 0.5)));
    set(&t, .bg, R.c(bg));
    set(&t, .bg_dark, R.h(p.bg_dark));
    set(&t, .bg_raised, R.h(p.bg_hi));
    set(&t, .border, R.c(mix(rgb(p.fg_dim), bg, 0.3)));
    set(&t, .accent, R.n(.blue));
    set(&t, .link, R.n(.blue));
    set(&t, .selection_bg, R.h(p.selection));
    set(&t, .cursor_bg, R.h(p.cursor));
    set(&t, .cursor_fg, R.r(.bg));

    // Red/amber/blue/grey by severity: the convention every editor and
    // compiler shares, read at a glance and never looked up.
    set(&t, .success, R.n(.green));
    set(&t, .message, R.n(.yellow));
    set(&t, .message_error, R.n(.red));
    set(&t, .diag_error, R.n(.red));
    set(&t, .diag_warning, R.n(.yellow));
    set(&t, .diag_info, R.n(.blue));
    set(&t, .diag_hint, R.r(.fg_dim));

    // Amber either way, so a search hit never reads as a selection. A
    // light theme's yellow is dark enough that the stronger current-match
    // tint goes to orange to keep text on it legible.
    set(&t, .match, R.n(.yellow));
    set(&t, .match_bg, R.c(mix(bg, rgb(p.yellow), if (dark) 0.28 else 0.22)));
    set(&t, .match_current_bg, R.c(if (dark) mix(bg, rgb(p.yellow), 0.55) else mix(bg, rgb(p.orange), 0.4)));

    set(&t, .file, R.r(.fg));
    set(&t, .dir, R.n(.blue));
    set(&t, .symlink, R.n(.cyan));
    set(&t, .exec, R.n(.green));
    set(&t, .special, R.n(.magenta));
    // Dimmed rather than marked, so the listing still reads as one list:
    // roughly halfway from the normal colour to the background.
    set(&t, .hidden, R.c(mix(fg, bg, 0.45)));
    set(&t, .hidden_dir, R.c(mix(blue, bg, 0.45)));
    set(&t, .marked, R.s(.bright, .yellow));

    set(&t, .sidebar_bg, R.c(mix(bg, rgb(p.bg_dark), 0.5)));
    set(&t, .status_bg, R.r(.bg_raised));
    set(&t, .status_fg, R.r(.fg));
    set(&t, .mode, R.n(.green));
    set(&t, .tab_bar_bg, R.r(.bg_dark));
    set(&t, .tab_bg, R.c(mix(bg, rgb(p.bg_hi), 0.5)));
    // An embedded terminal sits a shade off the pane so it reads as laid
    // over it -- darker on a dark theme, the faint grey chrome on a light
    // one. Light, not dark: what runs in it draws in this theme's `fg`
    // and slots, which are chosen for this theme's background.
    set(&t, .shell_bg, R.c(if (dark) mix(bg, black, 0.4) else rgb(p.bg_dark)));
    // Bright enough to read the indentation off, dim enough to disappear
    // when you stop looking for it.
    set(&t, .whitespace, R.c(mix(rgb(p.fg_dim), bg, 0.5)));
    set(&t, .title_bg, R.c(header));
    set(&t, .title_fg, R.r(.fg_strong));
    set(&t, .title_inactive_bg, R.r(.bg_raised));
    set(&t, .title_inactive_fg, R.r(.fg_dim));
    set(&t, .list_cursor_bg, R.c(header));
    set(&t, .list_cursor_inactive_bg, R.c(mix(bg, rgb(p.bg_hi), 0.7)));
    set(&t, .keybar_bg, R.r(.bg_dark));
    set(&t, .keybar_key, R.r(.fg));
    set(&t, .keybar_label_bg, R.c(mix(rgb(p.cyan), bg, 0.3)));
    set(&t, .keybar_label, R.r(.bg_dark));
    set(&t, .suggestion, R.r(.fg_dim));

    set(&t, .popup_bg, R.c(popup));
    set(&t, .popup_fg, R.r(.fg));
    set(&t, .popup_code_bg, R.c(if (dark) mix(popup, rgb(p.bg_dark), 0.5) else mix(popup, rgb(p.bg_hi), 0.5)));
    set(&t, .popup_rule, R.c(mix(rgb(p.fg_dim), popup, 0.3)));
    // The bundled frames' border colours (scripts/gen-ninepatches.py).
    set(&t, .popup_border, R.h(if (dark) 0x68708c else 0xb8bcc8));
    set(&t, .popup_selected_bg, R.c(popup_selected));
    set(&t, .popup_label, R.r(.fg));
    set(&t, .popup_kind, R.n(.blue));
    set(&t, .popup_detail, R.r(.fg_dim));
    set(&t, .finder_header_bg, R.c(header));
    set(&t, .finder_header_fg, if (dark) R.r(.fg) else R.r(.bg));
    set(&t, .finder_selected_bg, R.c(popup_selected));
    set(&t, .finder_selected_fg, R.r(.fg));
    set(&t, .dialog_bg, R.r(.popup_bg));
    set(&t, .dialog_fg, R.r(.popup_fg));
    set(&t, .dialog_title_bg, R.r(.title_bg));
    set(&t, .dialog_title_fg, R.r(.title_fg));
    set(&t, .danger_bg, R.c(mix(rgb(p.red), bg, 0.4)));
    set(&t, .input_bg, R.r(.bg));
    set(&t, .button_bg, R.r(.bg_raised));
    set(&t, .button_focus_bg, R.r(.title_bg));

    set(&t, .heading1, R.n(.blue));
    set(&t, .heading2, R.n(.magenta));
    set(&t, .heading3, R.n(.cyan));
    set(&t, .heading4, R.n(.yellow));
    set(&t, .heading5, R.n(.green));
    set(&t, .heading6, R.r(.fg_dim));
    set(&t, .strong, R.r(.fg_strong));
    set(&t, .emphasis, R.c(mix(fg, blue, 0.25)));
    set(&t, .strike, R.r(.comment));
    set(&t, .code, R.n(.yellow));
    set(&t, .code_bg, R.c(mix(bg, rgb(p.bg_hi), 0.8)));
    set(&t, .code_block, R.r(.fg));
    set(&t, .code_block_bg, R.c(mix(bg, rgb(p.bg_hi), 0.5)));
    set(&t, .quote, R.r(.comment));
    set(&t, .list_marker, R.n(.yellow));
    set(&t, .rule, R.r(.border));

    set(&t, .table_header, R.n(.yellow));
    set(&t, .table_header_bg, R.r(.bg_raised));
    set(&t, .table_alt_row_bg, R.c(mix(bg, rgb(p.bg_hi), 0.3)));
    set(&t, .outline_marker, R.r(.fg_dim));

    set(&t, .comment, R.h(p.comment));
    set(&t, .keyword, R.n(.magenta));
    set(&t, .string, R.n(.green));
    set(&t, .string_escape, R.n(.cyan));
    set(&t, .string_special, R.n(.cyan));
    set(&t, .escape, R.n(.cyan));
    set(&t, .number, R.h(p.orange));
    set(&t, .boolean, R.h(p.orange));
    set(&t, .character, R.n(.green));
    set(&t, .constant, R.h(p.orange));
    set(&t, .constant_builtin, R.h(p.orange));
    set(&t, .function, R.n(.blue));
    set(&t, .function_builtin, R.n(.blue));
    set(&t, .type, R.n(.yellow));
    set(&t, .type_builtin, R.n(.yellow));
    set(&t, .constructor, R.n(.yellow));
    set(&t, .operator, R.n(.cyan));
    set(&t, .property, R.n(.red));
    set(&t, .variable, R.r(.fg));
    set(&t, .variable_builtin, R.n(.red));
    set(&t, .variable_parameter, R.h(p.orange));
    set(&t, .module, R.n(.yellow));
    set(&t, .label, R.n(.blue));
    set(&t, .attribute, R.h(p.orange));
    set(&t, .tag, R.n(.red));
    set(&t, .punctuation, R.r(.fg));
    set(&t, .punctuation_special, R.n(.magenta));
    set(&t, .text_title, R.n(.blue));
    set(&t, .text_literal, R.n(.green));
    set(&t, .text_uri, R.n(.cyan));
    set(&t, .text_reference, R.n(.red));
    return t;
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

/// A role value as a config or the wire spells it: a slot name
/// (`"bright_red"`), another role's name (`"keyword"`), or `#rrggbb`.
pub fn parseRoleValue(s: []const u8) ?RoleValue {
    if (slotByName(s)) |sl| return .{ .slot = sl };
    if (roleByName(s)) |r| return .{ .role = r };
    if (parseHex(s)) |c| return .{ .rgb = c };
    return null;
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
            .{ .sidebar_bg, f.mantle },
            .{ .tab_bar_bg, f.crust },
            .{ .tab_bg, f.mantle },
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
    };
}

/// zoe's original hand-tuned palette.
const default_palette: Palette = .{
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
};

/// xterm's 16 ANSI colours, which every SGR colour was before slots
/// existed: the normal row then the bright one.
const xterm_slots = [_]SlotPair{
    .{ 8, 0x000000 },  .{ 9, 0xcd0000 },  .{ 10, 0x00cd00 }, .{ 11, 0xcdcd00 },
    .{ 12, 0x0000ee }, .{ 13, 0xcd00cd }, .{ 14, 0x00cdcd }, .{ 15, 0xe5e5e5 },
    .{ 16, 0x7f7f7f }, .{ 17, 0xff0000 }, .{ 18, 0x00ff00 }, .{ 19, 0xffff00 },
    .{ 20, 0x5c5cff }, .{ 21, 0xff00ff }, .{ 22, 0x00ffff }, .{ 23, 0xffffff },
};

/// `default`'s chrome, pinned to the constants `zoe/ui.zig` had.
const default_ui: []const RolePair = &.{
    .{ .sidebar_bg, 0x141419 },
    .{ .tab_bg, 0x222229 },
    .{ .shell_bg, 0x0e0f12 },
    .{ .dir, 0x84b0e8 },
    .{ .hidden, 0x707078 },
    .{ .hidden_dir, 0x546c8e },
    .{ .status_fg, 0xe2e2ec },
    .{ .mode, 0x96dca0 },
    .{ .message_error, 0xf08c8c },
    .{ .whitespace, 0x3e3e48 },
    .{ .match_bg, 0x544422 },
    .{ .match_current_bg, 0x96742a },
    .{ .match, 0xffbe3c },
    .{ .diag_error, 0xe85c5c },
    .{ .diag_warning, 0xe2b04a },
    .{ .diag_info, 0x6ca4e8 },
    .{ .diag_hint, 0x848494 },
    .{ .popup_bg, 0x22222a },
    .{ .popup_fg, 0xd6d6de },
    .{ .popup_code_bg, 0x1a1a20 },
    .{ .popup_rule, 0x505060 },
    .{ .popup_border, 0x68708c },
    .{ .popup_selected_bg, 0x3c5a96 },
    .{ .popup_label, 0xe2e2ea },
    .{ .popup_kind, 0x8caadc },
    .{ .popup_detail, 0x828292 },
    .{ .finder_header_bg, 0x285aaa },
    .{ .finder_header_fg, 0xebf0fa },
    .{ .finder_selected_bg, 0x4678c8 },
    .{ .finder_selected_fg, 0xf5faff },
};

pub const builtins = [_]Spec{
    // zoe's original hand-tuned palette, every UI slot pinned to the
    // value it had as a constant in `zoe/ui.zig`, so choosing no theme
    // changes nothing on screen. One Dark's syntax colours.
    .{
        .name = default_name,
        .palette = default_palette,
        .ui = default_ui,
    },
    // `default` with xterm's own ANSI colours in the slots, as terminal
    // output had before the palette existed: for whoever wants `ls
    // --color` unchanged. The syntax roles name slots, so code takes
    // xterm's hues too; the chrome is `default`'s.
    .{
        .name = "xterm",
        .palette = default_palette,
        .slots = &xterm_slots,
        .ui = default_ui,
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
            .{ .status_bg, 0x007acc },
            .{ .status_fg, 0xffffff },
            .{ .mode, 0xffffff },
            .{ .message_error, 0xffd6d6 },
            .{ .tab_bg, 0xececec },
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
        .ui = &.{.{ .dir, 0x9effff }},
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

const github_dark_syntax = [_]RolePair{
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
