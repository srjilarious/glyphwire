// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: MPL-2.0

const std = @import("std");
const glyphwire = @import("glyphwire");

const app_mod = @import("app.zig");
const config = @import("config.zig");
const modal_list = @import("modal_list.zig");

const App = app_mod.App;
const Engine = app_mod.Engine;
const theme = glyphwire.theme;

/// The theme switcher: a modal list of every theme the window could use
/// (`theme.lua`'s `themes`, then the built-ins), opened by a host-owned
/// chord (`host.conf.lua`'s `theme_switcher_key`, Super+F10 by default).
///
/// It changes the **window** theme (`Server.setWindowTheme`), so every
/// program that follows it recolours and one whose own config named a
/// `theme` keeps that. Moving the selection previews the highlighted
/// theme straight away; Enter keeps it and Escape puts back the one in
/// place when the dialog opened. Nothing is written back: `theme.lua`
/// still decides the theme the next session starts with.
///
/// Host-side for the same reasons as the context switcher (`switcher.zig`),
/// whose keys and look it shares (`modal_list`). The two are never open
/// together: while one is, it has every key press, the other's chord
/// included.
pub const ThemeSwitcher = struct {
    app: *App,
    /// Null disables the switcher entirely.
    chord: ?config.Chord = config.theme_switcher_default,
    /// `theme.lua`'s themes, which `names` can name. Borrowed from the
    /// host's startup arena, like `names`.
    customs: []const theme.Custom = &.{},
    names: []const []const u8 = &.{},

    open: bool = false,
    /// The pane the dialog is centred on. The theme is the window's
    /// whichever pane this is.
    pane: glyphwire.PaneHandle = glyphwire.root_pane_handle,
    selected: usize = 0,
    /// The window theme when the dialog opened, which Escape restores,
    /// and its row (null for a theme not in `names`, which can only be
    /// one `theme.lua` failed to resolve).
    original: theme.Stored = undefined,
    original_index: ?usize = null,
    /// Bumped on every visible change, for the redraw fingerprint.
    gen: u64 = 0,
    /// As `Switcher.consumed`: this frame's presses are the dialog's.
    consumed: bool = false,
    row_buf: [max_rows]modal_list.Row = undefined,

    /// More than every built-in plus any sensible `themes` table; the
    /// rest are dropped from the list.
    pub const max_rows = 128;

    /// Takes `theme.lua`'s themes (and the list built from them) for the
    /// session. `arena` must outlive the switcher.
    pub fn setThemes(self: *ThemeSwitcher, arena: std.mem.Allocator, customs: []const theme.Custom) !void {
        self.customs = customs;
        const all = try modal_list.themeNames(arena, customs);
        self.names = all[0..@min(all.len, max_rows)];
    }

    /// Runs once per frame, before any key reaches the wire. Returns
    /// `consumed`.
    pub fn handleKeys(self: *ThemeSwitcher, eng: *Engine) bool {
        self.consumed = self.step(eng);
        return self.consumed;
    }

    fn step(self: *ThemeSwitcher, eng: *Engine) bool {
        const kb = &eng.inputs.keyboard;
        const chord_hit = if (self.chord) |c|
            kb.pressed(c.key) and c.matches(kb.ctrl(), kb.alt(), kb.shift(), kb.super())
        else
            false;

        if (!self.open) {
            if (!chord_hit) return false;
            self.openOn();
            return true;
        }

        switch (modal_list.readAction(kb, chord_hit)) {
            .none => {},
            .close => self.cancel(),
            .commit => self.close(),
            .move => |d| self.select(modal_list.wrapMove(self.selected, self.names.len, d)),
            .pick => |i| if (i < self.names.len) {
                self.select(i);
                self.close();
            },
        }
        return true;
    }

    fn openOn(self: *ThemeSwitcher) void {
        if (self.names.len == 0) return;
        const server = self.app.server;
        {
            server.ctx_mutex.lockUncancelable(server.io);
            defer server.ctx_mutex.unlock(server.io);
            self.pane = server.session.focusedPaneHandle();
            self.original = server.session.theme;
        }
        self.original_index = null;
        for (self.names, 0..) |n, i| {
            if (std.mem.eql(u8, n, self.original.name())) {
                self.original_index = i;
                break;
            }
        }
        self.selected = self.original_index orelse 0;
        self.open = true;
        self.gen +%= 1;
    }

    /// Moves to row `index` and previews its theme on the window.
    fn select(self: *ThemeSwitcher, index: usize) void {
        if (index == self.selected) return;
        self.selected = index;
        self.gen +%= 1;
        const t = theme.resolve(self.names[index], self.customs) orelse return;
        self.apply(t);
    }

    /// Escape: back to the theme the window had when the dialog opened.
    fn cancel(self: *ThemeSwitcher) void {
        if (self.selected != self.original_index) {
            // `Stored` keeps its strings beside the theme; put them back
            // on a copy for `setWindowTheme`, which stores its own.
            var t = self.original.theme;
            t.name = self.original.name();
            t.panel_style = self.original.panelStyle();
            self.apply(t);
        }
        self.close();
    }

    fn close(self: *ThemeSwitcher) void {
        self.open = false;
        self.gen +%= 1;
    }

    fn apply(self: *ThemeSwitcher, t: theme.Theme) void {
        self.app.server.setWindowTheme(self.app.alloc, t) catch |err| {
            std.log.err("glyphwire-host: theme switch failed: {t}", .{err});
        };
    }

    /// What to draw while open. Borrowed; valid until the next
    /// `handleKeys`.
    pub fn view(self: *ThemeSwitcher) ?modal_list.View {
        if (!self.open) return null;
        for (self.names, 0..) |n, i| {
            self.row_buf[i] = .{ .text = n, .tag = if (self.original_index == i) "  (current)" else "" };
        }
        return .{
            .pane = self.pane,
            .title = "Theme",
            .foot = "Enter keep  Esc revert",
            .rows = self.row_buf[0..self.names.len],
            .selected = self.selected,
        };
    }
};
