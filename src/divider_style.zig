// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: MPL-2.0

//! What a divider band is drawn with: the box-drawing glyph sets, the
//! presets `host.conf.lua`'s `pane_divider_style` names, and the
//! per-context `Override` a program sends with `set_divider_style`.
//!
//! The host's `pane_divider_style` / `pane_divider_chars` set the style
//! for every band it draws -- between panes, and inside each program's
//! own split tree. A program (zoe, salacommander) may override the second
//! for its own context only; one that never does inherits the host's.
//! `Override.resolve` is that rule, so the host and the tests agree on it.
//!
//! Pure data: the junction layout lives in glyphwire-host's
//! `host/dividers.zig`, which re-exports these types.

const std = @import("std");
const core = @import("core.zig");

/// One glyph per shape a divider cell can take. A junction is named for
/// the arm it adds to a straight line: `t_right` is `├` (a vertical line
/// with an arm to the right).
pub const Glyphs = struct {
    h: []const u8,
    v: []const u8,
    cross: []const u8,
    t_down: []const u8,
    t_up: []const u8,
    t_left: []const u8,
    t_right: []const u8,
    tl: []const u8,
    tr: []const u8,
    bl: []const u8,
    br: []const u8,
};

pub const single: Glyphs = .{ .h = "─", .v = "│", .cross = "┼", .t_down = "┬", .t_up = "┴", .t_left = "┤", .t_right = "├", .tl = "┌", .tr = "┐", .bl = "└", .br = "┘" };
pub const heavy: Glyphs = .{ .h = "━", .v = "┃", .cross = "╋", .t_down = "┳", .t_up = "┻", .t_left = "┫", .t_right = "┣", .tl = "┏", .tr = "┓", .bl = "┗", .br = "┛" };
pub const double: Glyphs = .{ .h = "═", .v = "║", .cross = "╬", .t_down = "╦", .t_up = "╩", .t_left = "╣", .t_right = "╠", .tl = "╔", .tr = "╗", .bl = "╚", .br = "╝" };

pub const Style = union(enum) {
    /// A solid band in the theme's divider colour.
    block,
    glyphs: Glyphs,
};

pub const default_style: Style = .{ .glyphs = single };

/// The preset names `pane_divider_style` and `set_divider_style`'s
/// `style` take.
pub const Preset = enum {
    single,
    heavy,
    double,
    block,

    pub fn style(self: Preset) Style {
        return switch (self) {
            .single => .{ .glyphs = single },
            .heavy => .{ .glyphs = heavy },
            .double => .{ .glyphs = double },
            .block => .block,
        };
    }
};

/// The preset called `name`, or null for an unknown one.
pub fn preset(name: []const u8) ?Style {
    const p = std.meta.stringToEnum(Preset, name) orelse return null;
    return p.style();
}

/// One overridden glyph, held inline so an `Override` owns no memory and
/// a `Context` can copy one in under its mutex without an allocator.
pub const Glyph = struct {
    buf: [max_bytes]u8 = undefined,
    len: u8 = 0,

    /// Room for one cell's worth of text: a codepoint plus a variation
    /// selector or a combining mark or two.
    pub const max_bytes = 16;

    /// `text` as a glyph, or null when it isn't exactly one cell wide or
    /// doesn't fit -- the same rule `pane_divider_chars` applies.
    pub fn init(text: []const u8) ?Glyph {
        if (text.len == 0 or text.len > max_bytes) return null;
        if (!std.unicode.utf8ValidateSlice(text)) return null;
        if (core.stringWidth(text) != 1) return null;
        var g: Glyph = .{ .len = @intCast(text.len) };
        @memcpy(g.buf[0..text.len], text);
        return g;
    }

    pub fn slice(self: *const Glyph) []const u8 {
        return self.buf[0..self.len];
    }
};

/// A program's divider style for its own context, as `set_divider_style`
/// carries it. Everything null (the default) means "the host's".
pub const Override = struct {
    /// The base style. Null keeps whatever the host is configured with.
    preset: ?Preset = null,
    /// Glyphs laid over the base, by `Glyphs` field name. Over a `block`
    /// base they start from `single`, as `pane_divider_chars` does.
    chars: Chars = .{},

    pub const Chars = struct {
        h: ?Glyph = null,
        v: ?Glyph = null,
        cross: ?Glyph = null,
        t_down: ?Glyph = null,
        t_up: ?Glyph = null,
        t_left: ?Glyph = null,
        t_right: ?Glyph = null,
        tl: ?Glyph = null,
        tr: ?Glyph = null,
        bl: ?Glyph = null,
        br: ?Glyph = null,

        pub fn isEmpty(self: *const Chars) bool {
            inline for (@typeInfo(Chars).@"struct".field_names) |name| {
                if (@field(self, name) != null) return false;
            }
            return true;
        }
    };

    /// True when this overrides nothing, so the host's style applies as is.
    pub fn inherits(self: *const Override) bool {
        return self.preset == null and self.chars.isEmpty();
    }

    /// The style to draw with when the host's own is `host`. The returned
    /// glyphs may point into `self.chars`, so `self` must outlive them.
    pub fn resolve(self: *const Override, host: Style) Style {
        const base = if (self.preset) |p| p.style() else host;
        if (self.chars.isEmpty()) return base;
        var glyphs: Glyphs = switch (base) {
            .glyphs => |g| g,
            .block => single,
        };
        inline for (@typeInfo(Chars).@"struct".field_names) |name| {
            if (@field(self.chars, name)) |*g| @field(glyphs, name) = g.slice();
        }
        return .{ .glyphs = glyphs };
    }
};

comptime {
    // `Chars` mirrors `Glyphs` field for field; `resolve` and the wire
    // both lean on the names matching.
    const glyph_fields = @typeInfo(Glyphs).@"struct".field_names;
    std.debug.assert(glyph_fields.len == @typeInfo(Override.Chars).@"struct".field_names.len);
    for (glyph_fields) |name| std.debug.assert(@hasField(Override.Chars, name));
}
