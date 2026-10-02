// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: GPL-3.0-or-later

//! The theme model (`src/theme.zig`): slots, roles, the built-ins, config
//! themes layered over them; `applib/themeconf.zig`'s Lua side; and the
//! host half -- SGR colours as slot references, per-context themes, and
//! `set_theme` / `get_theme` / `get_cells` on the wire.

const std = @import("std");
const testz = @import("testz");
const glyphwire = @import("glyphwire");
const themeconf = @import("themeconf");

const theme = glyphwire.theme;
const Color = glyphwire.Color;
const dispatch = glyphwire.dispatch;

fn expectColor(got: Color, hex: u24) !void {
    try testz.expectTrue(got.eql(theme.rgb(hex)));
}

// ─── Slots and roles ─────────────────────────────────────────────────────

pub fn slotIndicesFollowLevelThenHueTest(_: std.Io, _: std.mem.Allocator) !void {
    try testz.expectEqual(theme.slot(.dim, .black), 0);
    try testz.expectEqual(theme.slot(.normal, .red), 9);
    try testz.expectEqual(theme.slot(.bright, .white), 23);
    // ANSI 0-7 is the normal row, 8-15 the bright one.
    try testz.expectEqual(theme.ansiSlot(1), theme.slot(.normal, .red));
    try testz.expectEqual(theme.ansiSlot(9), theme.slot(.bright, .red));
    try testz.expectEqual(theme.atLevel(theme.slot(.bright, .cyan), .dim), theme.slot(.dim, .cyan));

    try testz.expectEqualStr(theme.slot_names[9], "red");
    try testz.expectEqualStr(theme.slot_names[1], "dim_red");
    try testz.expectEqualStr(theme.slot_names[17], "bright_red");
    try testz.expectEqual(theme.slotByName("bright_magenta").?, theme.slot(.bright, .magenta));
    try testz.expectTrue(theme.slotByName("orange") == null);
}

pub fn roleByNameTakesLegacyAndDottedNamesTest(_: std.Io, _: std.mem.Allocator) !void {
    try testz.expectEqual(theme.roleByName("keyword").?, .keyword);
    try testz.expectEqual(theme.roleByName("table_header_bg").?, .table_header_bg);
    // zoe's pre-role `ui` names.
    try testz.expectEqual(theme.roleByName("bg_buffer").?, .bg);
    try testz.expectEqual(theme.roleByName("fg_diag_error").?, .diag_error);
    // A dotted capture group.
    try testz.expectEqual(theme.roleByName("string.escape").?, .string_escape);
    try testz.expectTrue(theme.roleByName("nonsense") == null);

    try testz.expectTrue(std.meta.eql(theme.parseRoleValue("bright_red").?, theme.RoleValue{ .slot = 17 }));
    try testz.expectTrue(std.meta.eql(theme.parseRoleValue("keyword").?, theme.RoleValue{ .role = .keyword }));
    try testz.expectTrue(theme.parseRoleValue("#102030").?.rgb.eql(theme.rgb(0x102030)));
    try testz.expectTrue(theme.parseRoleValue("#12") == null);
}

pub fn roleColorFollowsAliasesAndSurvivesCyclesTest(_: std.Io, _: std.mem.Allocator) !void {
    var t = theme.initDefault();
    t.roles.set(.heading1, .{ .role = .keyword });
    try testz.expectTrue(t.roleColor(.heading1).eql(t.roleColor(.keyword)));
    // A role naming a slot follows that slot.
    t.roles.set(.heading2, .{ .slot = theme.slot(.normal, .green) });
    t.slots[theme.slot(.normal, .green)] = theme.rgb(0x010203);
    try expectColor(t.roleColor(.heading2), 0x010203);
    // A cycle answers white's slot rather than looping.
    t.roles.set(.heading3, .{ .role = .heading4 });
    t.roles.set(.heading4, .{ .role = .heading3 });
    try testz.expectTrue(t.roleColor(.heading3).eql(t.slots[theme.slot(.normal, .white)]));
}

pub fn resolveKeepsTheReferencesAlphaTest(_: std.Io, _: std.mem.Allocator) !void {
    const t = theme.initDefault();
    const literal = Color{ .r = 1, .g = 2, .b = 3, .a = 4 };
    try testz.expectTrue(t.resolve(literal).eql(literal));

    const half = t.resolve(Color.role(.selection_bg).withAlpha(128));
    try testz.expectEqual(half.a, 128);
    try testz.expectEqual(half.r, t.roleColor(.selection_bg).r);
    try testz.expectTrue(half.ref == .none);

    const red = t.resolve(Color.ansi(.normal, .red));
    try testz.expectTrue(red.eql(t.slots[9]));
}

// ─── Built-ins ───────────────────────────────────────────────────────────

pub fn defaultThemeKeepsZoesOriginalColoursTest(_: std.Io, _: std.mem.Allocator) !void {
    // `default` is derived from a palette rather than written out, so pin
    // it to the colours zoe hand-wrote before themes existed: choosing no
    // theme must not change a single capture colour.
    const t = theme.initDefault();
    const want = [_]struct { theme.Role, u24 }{
        .{ .comment, 0x5c6370 },             .{ .keyword, 0xc678dd },
        .{ .string, 0x98c379 },              .{ .string_escape, 0x56b6c2 },
        .{ .string_special, 0x56b6c2 },      .{ .escape, 0x56b6c2 },
        .{ .number, 0xd19a66 },              .{ .boolean, 0xd19a66 },
        .{ .character, 0x98c379 },           .{ .constant, 0xd19a66 },
        .{ .constant_builtin, 0xd19a66 },    .{ .function, 0x61afef },
        .{ .function_builtin, 0x61afef },    .{ .type, 0xe5c07b },
        .{ .type_builtin, 0xe5c07b },        .{ .constructor, 0xe5c07b },
        .{ .operator, 0x56b6c2 },            .{ .property, 0xe06c75 },
        .{ .variable_builtin, 0xe06c75 },    .{ .variable_parameter, 0xd19a66 },
        .{ .module, 0xe5c07b },              .{ .label, 0x61afef },
        .{ .attribute, 0xd19a66 },           .{ .tag, 0xe06c75 },
        .{ .punctuation_special, 0xc678dd }, .{ .text_title, 0x61afef },
        .{ .text_literal, 0x98c379 },        .{ .text_uri, 0x56b6c2 },
        .{ .text_reference, 0xe06c75 },
        // ...and a few of the UI colours that were constants in ui.zig.
             .{ .bg, 0x18181d },
        .{ .status_bg, 0x2e2e38 },           .{ .tab_bar_bg, 0x101014 },
        .{ .selection_bg, 0x303e54 },        .{ .cursor_fg, 0x18181d },
    };
    for (want) |w| try expectColor(t.roleColor(w[0]), w[1]);
    // Plain text stays plain.
    try testz.expectTrue(std.meta.eql(t.roles.get(.variable), theme.RoleValue{ .role = .fg }));
    try testz.expectEqualStr(t.panel_style, "panel");
}

pub fn everyBuiltinResolvesWithOpaqueSlotsTest(_: std.Io, _: std.mem.Allocator) !void {
    for (theme.builtins, 0..) |spec, i| {
        const t = theme.resolve(spec.name, &.{}) orelse return error.BuiltinDidNotResolve;
        try testz.expectEqualStr(t.name, spec.name);
        // Light themes get the light frame unless they name one.
        try testz.expectEqualStr(t.panel_style, if (spec.dark) "panel" else "panel_light");
        for (t.slots) |s| {
            try testz.expectEqual(s.a, 255);
            try testz.expectTrue(s.ref == .none);
        }
        // The accents are their hue's normal slot, unless the spec sets
        // its slots by hand (`xterm`).
        if (spec.slots.len == 0) {
            try expectColor(t.slots[theme.slot(.normal, .red)], spec.palette.red);
            try expectColor(t.slots[theme.slot(.normal, .magenta)], spec.palette.purple);
        }
        // Names are unique, or `:theme` could never reach the second.
        for (theme.builtins[i + 1 ..]) |other| {
            try testz.expectFalse(std.mem.eql(u8, spec.name, other.name));
        }
    }
    try testz.expectTrue(theme.resolve("no-such-theme", &.{}) == null);
}

pub fn dividersKeepTheHostsOldGreysOnDefaultTest(_: std.Io, _: std.mem.Allocator) !void {
    // glyphwire-host drew both bands in fixed colours before they were
    // roles; `default` keeps them.
    const t = theme.initDefault();
    try expectColor(t.roleColor(.divider), 0x3a3a42);
    try expectColor(t.roleColor(.pane_divider), 0x545460);
}

pub fn everyBuiltinHasVisibleDividersAndAReadableCursorTest(_: std.Io, _: std.mem.Allocator) !void {
    for (theme.builtins) |spec| {
        const t = theme.resolve(spec.name, &.{}).?;
        const bg = t.roleColor(.bg);
        // Both bands stand off the background, the pane one further.
        const div = lumaDistance(t.roleColor(.divider), bg);
        const pane = lumaDistance(t.roleColor(.pane_divider), bg);
        try testz.expectTrue(div > 8);
        try testz.expectTrue(pane > div);
        // The cursor row's text is far from its fill: the case a light
        // theme's saturated cursor got wrong with the row's own colours.
        try testz.expectTrue(lumaDistance(t.roleColor(.list_cursor_fg), t.roleColor(.list_cursor_bg)) > 60);
    }
}

/// Rough perceived-brightness difference, 0-255.
fn lumaDistance(a: Color, b: Color) u32 {
    const la = (@as(u32, a.r) * 299 + @as(u32, a.g) * 587 + @as(u32, a.b) * 114) / 1000;
    const lb = (@as(u32, b.r) * 299 + @as(u32, b.g) * 587 + @as(u32, b.b) * 114) / 1000;
    return if (la > lb) la - lb else lb - la;
}

pub fn xtermThemeKeepsTheOldAnsiColoursTest(_: std.Io, _: std.mem.Allocator) !void {
    const t = theme.resolve("xterm", &.{}).?;
    try expectColor(t.resolve(Color.ansi(.normal, .red)), 0xcd0000);
    try expectColor(t.resolve(Color.ansi(.bright, .blue)), 0x5c5cff);
    // A role naming a slot follows it, so code takes xterm's hues too;
    // the chrome, set from the palette, is `default`'s.
    const d = theme.initDefault();
    try expectColor(t.roleColor(.keyword), 0xcd00cd);
    try testz.expectTrue(t.roleColor(.popup_bg).eql(d.roleColor(.popup_bg)));
    try testz.expectTrue(t.roleColor(.bg).eql(d.roleColor(.bg)));
}

pub fn lightThemeSlotsKeepAnsiBlackDarkTest(_: std.Io, _: std.mem.Allocator) !void {
    // `30` on a light theme is still text you can read: black is the
    // text end of the greys, white the background end.
    const t = theme.resolve("github-light", &.{}).?;
    const spec = theme.builtin("github-light").?;
    try expectColor(t.slots[theme.slot(.normal, .black)], spec.palette.fg);
    try expectColor(t.slots[theme.slot(.bright, .white)], spec.palette.bg);
}

pub fn customThemeLayersOverItsBaseTest(_: std.Io, _: std.mem.Allocator) !void {
    const customs = [_]theme.Custom{
        .{
            .name = "mine",
            .base = "nord",
            .palette = &.{.{ .name = "bg", .color = theme.rgb(0x101010) }},
            .slots = &.{.{ .slot = theme.slot(.normal, .blue), .color = theme.rgb(0x0000aa) }},
            .roles = &.{
                .{ .role = .keyword, .value = .{ .rgb = theme.rgb(0x123456) } },
                .{ .role = .status_bg, .value = .{ .slot = theme.slot(.dim, .red) } },
            },
        },
        // Tweaking a built-in under its own name: the base is the
        // built-in, not this entry again.
        .{ .name = "dracula", .base = "dracula", .roles = &.{.{ .role = .string, .value = .{ .rgb = theme.rgb(0x010203) } }} },
        .{ .name = "a", .base = "b" },
        .{ .name = "b", .base = "a" },
    };

    const mine = theme.resolve("mine", &customs).?;
    try testz.expectEqualStr(mine.name, "mine");
    // The palette swap re-derives what is blended from it...
    try expectColor(mine.roleColor(.bg), 0x101010);
    try expectColor(mine.roleColor(.cursor_fg), 0x101010);
    // ...a slot override carries every role that names the slot (nord's
    // functions are its own colour, but directories are blue)...
    try expectColor(mine.roleColor(.dir), 0x0000aa);
    try expectColor(mine.roleColor(.function), 0x88c0d0);
    // ...and the custom's role overrides land last.
    try expectColor(mine.roleColor(.keyword), 0x123456);
    try testz.expectTrue(mine.roleColor(.status_bg).eql(mine.slots[theme.slot(.dim, .red)]));

    const dracula = theme.resolve("dracula", &customs).?;
    try expectColor(dracula.roleColor(.string), 0x010203);
    try expectColor(dracula.roleColor(.keyword), 0xff79c6);

    // A loop never resolves.
    try testz.expectTrue(theme.resolve("a", &customs) == null);
}

pub fn storedThemeCopiesItsNamesTest(_: std.Io, _: std.mem.Allocator) !void {
    var name_buf = "borrowed".*;
    var t = theme.initDefault();
    t.name = &name_buf;
    var st: theme.Stored = .init(t);
    name_buf[0] = 'X';
    try testz.expectEqualStr(st.name(), "borrowed");
    try testz.expectEqualStr(st.panelStyle(), "panel");
    // A copy is independent of the original.
    const copy = st;
    st.set(theme.resolve("nord", &.{}).?);
    try testz.expectEqualStr(copy.name(), "borrowed");
    try testz.expectEqualStr(st.name(), "nord");
}

// ─── themeconf ───────────────────────────────────────────────────────────

pub fn themeconfReadsSlotsRolesAndValueFormsTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    const parsed = themeconf.fromSource(arena.allocator(), alloc,
        \\config = {
        \\  theme = {
        \\    base = "nord",
        \\    slots = { red = "#aa0000", bright_red = "#ff0000", orange = "#ffaa00" },
        \\    roles = { heading1 = "bright_red", heading2 = "keyword", heading3 = 4 },
        \\    table_header_bg = "#202020",
        \\    keyword = "nonsense",
        \\  },
        \\}
    , "test.lua");
    const t = parsed.resolve(arena.allocator(), .{}).?;
    try testz.expectEqualStr(t.name, themeconf.table_theme_name);
    try expectColor(t.slots[theme.slot(.normal, .red)], 0xaa0000);
    try expectColor(t.roleColor(.heading1), 0xff0000);
    try testz.expectTrue(std.meta.eql(t.roles.get(.heading2), theme.RoleValue{ .role = .keyword }));
    try testz.expectTrue(std.meta.eql(t.roles.get(.heading3), theme.RoleValue{ .slot = 4 }));
    try expectColor(t.roleColor(.table_header_bg), 0x202020);
    // The bad value was skipped, so nord's keyword survives.
    try expectColor(t.roleColor(.keyword), theme.builtin("nord").?.palette.blue);
}

pub fn themeconfResolvesAgainstSharedThemesTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    const shared = themeconf.fromSource(a, alloc,
        \\config = { theme = "nord", themes = { house = { base = "dracula", keyword = "#010101" } } }
    , "theme.lua");
    try testz.expectEqualStr(shared.resolveOrDefault(a, .{}).name, "nord");

    // A program naming a theme `theme.lua` defined.
    const own = themeconf.fromSource(a, alloc, "config = { theme = \"house\" }", "prog.lua");
    const t = own.resolve(a, shared).?;
    try testz.expectEqualStr(t.name, "house");
    try expectColor(t.roleColor(.keyword), 0x010101);

    // No `theme`: follow the window.
    const none = themeconf.fromSource(a, alloc, "config = { page_lines = 3 }", "prog.lua");
    try testz.expectTrue(none.resolve(a, shared) == null);
    // A broken file is the same as no file.
    const broken = themeconf.fromSource(a, alloc, "config = {", "prog.lua");
    try testz.expectTrue(broken.name == null);
}

// ─── The host: SGR, contexts, the wire ───────────────────────────────────

pub fn sgrColoursAreSlotReferencesTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var ctx = try glyphwire.Context.init(alloc, 20, 2, 0);
    defer ctx.deinit();
    try ctx.root.writeText("\x1b[31ma\x1b[1mb\x1b[22;2mc\x1b[0;2md\x1b[0;7me\x1b[0;38;5;12mf", glyphwire.default_style.fg, null);

    const fg = struct {
        fn at(c: *glyphwire.Context, col: usize) Color {
            return c.root.cell(0, col).style.fg;
        }
    }.at;
    try testz.expectTrue(fg(&ctx, 0).eql(Color.ansi(.normal, .red)));
    // Bold promotes a basic colour to its bright slot...
    try testz.expectTrue(fg(&ctx, 1).eql(Color.ansi(.bright, .red)));
    // ...and dim drops it to its dim one.
    try testz.expectTrue(fg(&ctx, 2).eql(Color.ansi(.dim, .red)));
    // Dim default text is `fg_dim`.
    try testz.expectTrue(fg(&ctx, 3).eql(Color.role(.fg_dim)));
    // Inverse over the (transparent) default background inks with `bg`.
    try testz.expectTrue(fg(&ctx, 4).eql(Color.role(.bg)));
    try testz.expectTrue(ctx.root.cell(0, 4).style.bg.color.eql(Color.role(.fg)));
    // 256-colour 0-15 are the same slots.
    try testz.expectTrue(fg(&ctx, 5).eql(Color.ansi(.bright, .blue)));
}

pub fn sessionThemePassesContextsThatSetTheirOwnTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var ctx = try glyphwire.Context.init(alloc, 10, 2, 0);
    defer ctx.deinit();
    var session = try glyphwire.Session.init(alloc, &ctx);
    defer session.deinit();
    const other = session.contextPtr(try session.createContext(glyphwire.root_pane_handle, null, null, 0)).?;
    other.setOwnTheme(theme.resolve("dracula", &.{}).?);

    const gen = ctx.theme_gen;
    session.setTheme(theme.resolve("nord", &.{}).?);
    try testz.expectEqualStr(ctx.theme.name(), "nord");
    try testz.expectFalse(ctx.theme_gen == gen);
    try testz.expectEqualStr(other.theme.name(), "dracula");

    // A context created later starts from the session's.
    const later = session.contextPtr(try session.createContext(glyphwire.root_pane_handle, null, null, 0)).?;
    try testz.expectEqualStr(later.theme.name(), "nord");

    other.followTheme(&session.theme);
    try testz.expectEqualStr(other.theme.name(), "nord");
    try testz.expectFalse(other.theme_own);
}

pub fn wireRoleColoursResolvePerContextThemeTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var ctx = try glyphwire.Context.init(alloc, 10, 2, 0);
    defer ctx.deinit();
    var session = try glyphwire.Session.init(alloc, &ctx);
    defer session.deinit();
    var d = dispatch.Dispatcher.initForConnection(&session, 7, null, null);

    _ = try d.handle(alloc,
        \\{"method":"write_text","params":{"text":"k","fg":{"role":"keyword"},"bg":{"slot":9,"a":128}}}
    );
    const cell = ctx.root.cell(0, 0);
    try testz.expectTrue(cell.style.fg.eql(Color.role(.keyword)));
    try testz.expectTrue(cell.style.bg.color.eql(Color.slot(9).withAlpha(128)));

    // `get_cells` reports the reference and what it resolves to.
    {
        const body = (try d.handle(alloc,
            \\{"id":1,"method":"get_cells","params":{}}
        )).response.?;
        defer alloc.free(body);
        try testz.expectTrue(std.mem.indexOf(u8, body, "\"role\":\"keyword\"") != null);
        try testz.expectTrue(std.mem.indexOf(u8, body, "\"r\":198,\"g\":120,\"b\":221") != null);
    }

    // A theme of the context's own: same cell, new colour.
    const gen = ctx.theme_gen;
    _ = try d.handle(alloc,
        \\{"method":"set_theme","params":{"name":"dracula"}}
    );
    try testz.expectTrue(ctx.theme_own);
    try testz.expectFalse(ctx.theme_gen == gen);
    {
        const body = (try d.handle(alloc,
            \\{"id":2,"method":"get_cells","params":{}}
        )).response.?;
        defer alloc.free(body);
        // Dracula's keyword is #ff79c6.
        try testz.expectTrue(std.mem.indexOf(u8, body, "\"r\":255,\"g\":121,\"b\":198") != null);
    }

    // Bad references are errors, not silently white.
    try testz.expectError(d.handle(alloc,
        \\{"method":"write_text","params":{"text":"x","fg":{"role":"nope"}}}
    ), dispatch.DispatchError.UnknownColorRole);
    try testz.expectError(d.handle(alloc,
        \\{"method":"write_text","params":{"text":"x","fg":{"slot":24}}}
    ), dispatch.DispatchError.InvalidColor);
    try testz.expectError(d.handle(alloc,
        \\{"method":"set_theme","params":{"name":"nope"}}
    ), dispatch.DispatchError.UnknownTheme);

    // Neither `name` nor `theme`: back to the window's.
    _ = try d.handle(alloc,
        \\{"method":"set_theme","params":{}}
    );
    try testz.expectFalse(ctx.theme_own);
    try testz.expectEqualStr(ctx.theme.name(), "default");
}

pub fn wireThemeRoundTripsThroughGetThemeTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var ctx = try glyphwire.Context.init(alloc, 10, 2, 0);
    defer ctx.deinit();
    var session = try glyphwire.Session.init(alloc, &ctx);
    defer session.deinit();
    var d = dispatch.Dispatcher.initForConnection(&session, 7, null, null);

    // A partial theme lays over `default`.
    _ = try d.handle(alloc,
        \\{"method":"set_theme","params":{"theme":{"name":"mine","dark":false,
        \\  "slots":[{"r":1,"g":2,"b":3}],
        \\  "roles":{"keyword":{"slot":17},"heading1":{"role":"keyword"},"bg":{"r":250,"g":250,"b":250}}}}}
    );
    try testz.expectEqualStr(ctx.theme.name(), "mine");
    try testz.expectEqualStr(ctx.theme.panelStyle(), "panel_light");
    try expectColor(ctx.theme.theme.slots[0], 0x010203);
    try expectColor(ctx.theme.theme.roleColor(.bg), 0xfafafa);

    const body = (try d.handle(alloc,
        \\{"jsonrpc":"2.0","id":3,"method":"get_theme"}
    )).response.?;
    defer alloc.free(body);
    const Resp = struct { result: glyphwire.protocol.ThemeWire };
    const parsed = try std.json.parseFromSlice(Resp, alloc, body, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    const got = parsed.value.result;
    try testz.expectTrue(got.own);
    try testz.expectEqual(got.slots.?.len, theme.slot_count);
    try testz.expectEqual(got.roles.?.map.count(), theme.role_count);

    var back = theme.initDefault();
    try got.applyTo(&back);
    try testz.expectFalse(back.dark);
    try testz.expectTrue(std.meta.eql(back.roles.get(.keyword), theme.RoleValue{ .slot = 17 }));
    try testz.expectTrue(std.meta.eql(back.roles.get(.heading1), theme.RoleValue{ .role = .keyword }));
    try expectColor(back.slots[0], 0x010203);
}
