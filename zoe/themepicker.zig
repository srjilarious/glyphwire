// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: GPL-3.0-or-later

//! The theme picker, `:themes` or "Select Color Theme" in the palette:
//! every theme `:theme <name>` could switch to, in the command palette's
//! popup (`applib/palette.zig`), so a query narrows it the same way.
//!
//! One row per theme: its name, and at the right end whether it is dark
//! or light and, for one a config defined, which config. That column is
//! matched like a palette command's `:` line, so `light` lists the light
//! ones. Built-ins come first in their own order, then `theme.lua`'s,
//! then `zoe.conf.lua`'s; a config theme with a built-in's name (or
//! `zoe.conf.lua`'s with `theme.lua`'s) takes that row over, since it is
//! what `:theme` would resolve the name to.
//!
//! What the popup does with them is `Ui`'s: the highlighted theme is
//! applied as the cursor moves, Enter keeps it, and Escape (or a click
//! outside) puts back what was there before. `choices` is pure, so
//! `tests/zoe_tests.zig` covers the merging without a client.

const std = @import("std");
const themes = @import("applib").theme;
const palette = @import("applib").palette;

/// Where a theme was defined.
pub const Origin = enum {
    built_in,
    /// `theme.lua`'s `themes`, shared by every program.
    shared,
    /// `zoe.conf.lua`'s `theme` / `themes`.
    own,

    pub fn label(self: Origin) []const u8 {
        return switch (self) {
            .built_in => "",
            .shared => "theme.lua",
            .own => "zoe.conf.lua",
        };
    }
};

pub const Choice = struct {
    /// Borrowed: a built-in's static name or the config's arena copy.
    name: []const u8,
    origin: Origin,
    /// Resolved once here, so moving the cursor only applies it.
    theme: themes.Theme,
};

/// Every theme reachable by name: the built-ins, then `shared`'s
/// customs, then `own`'s, each name once (the later definition's row,
/// at the earlier one's place). A custom whose `base` chain never
/// reaches a built-in can't be resolved and is left out. Owned slice;
/// the names borrow from the inputs.
pub fn choices(alloc: std.mem.Allocator, shared: []const themes.Custom, own: []const themes.Custom) ![]Choice {
    // Resolved against both, the way `langconf.Config.findTheme` does.
    const all = try std.mem.concat(alloc, themes.Custom, &.{ shared, own });
    defer alloc.free(all);

    var out: std.ArrayList(Choice) = .empty;
    errdefer out.deinit(alloc);
    for (&themes.builtins) |*s| try put(alloc, &out, s.name, .built_in, all);
    for (shared) |c| try put(alloc, &out, c.name, .shared, all);
    for (own) |c| try put(alloc, &out, c.name, .own, all);
    return out.toOwnedSlice(alloc);
}

fn put(alloc: std.mem.Allocator, out: *std.ArrayList(Choice), name: []const u8, origin: Origin, all: []const themes.Custom) !void {
    const t = themes.resolve(name, all) orelse return;
    for (out.items) |*c| {
        if (!std.mem.eql(u8, c.name, name)) continue;
        c.* = .{ .name = name, .origin = origin, .theme = t };
        return;
    }
    try out.append(alloc, .{ .name = name, .origin = origin, .theme = t });
}

/// The index of the choice called `name`, if there is one.
pub fn indexOf(list: []const Choice, name: []const u8) ?usize {
    for (list, 0..) |c, i| {
        if (std.mem.eql(u8, c.name, name)) return i;
    }
    return null;
}

/// What a row shows at its right end: `dark` or `light`, and the config
/// a custom came from (`light, zoe.conf.lua`). Borrows `buf`.
pub fn detail(buf: []u8, c: *const Choice) []const u8 {
    const shade = if (c.theme.dark) "dark" else "light";
    if (c.origin == .built_in) return shade;
    return std.fmt.bufPrint(buf, "{s}, {s}", .{ shade, c.origin.label() }) catch shade;
}

/// The palette list for `list`: each row's id is its index there.
pub fn paletteList(alloc: std.mem.Allocator, list: []const Choice) !palette.List {
    var l = palette.List.init(alloc);
    errdefer l.deinit();
    var buf: [64]u8 = undefined;
    for (list, 0..) |*c, i| {
        try l.addWithCommand(@intCast(i), c.name, c.name, null, detail(&buf, c));
    }
    return l;
}

/// The palette's shape for the picker: the command palette's, with its
/// own empty text.
pub fn style(base: palette.Style) palette.Style {
    var s = base;
    s.empty_text = "No matching themes";
    return s;
}
