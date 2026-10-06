// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: GPL-3.0-or-later

//! Every prefix command gmux answers to, by name, rebindable from
//! `gmux.conf.lua`'s `keys` (`luaconf.keys`):
//!
//!     config = { keys = { ["-"] = "splitBelow", ["|"] = "splitRight", ['"'] = false } }
//!
//! Most commands are typed characters (`%`, `"`, `H`), matched against
//! what the keyboard layout produced. A lowercase letter or digit
//! (`"x"`, `"z"`) is a key in chord syntax, but gmux reads it off the
//! typed text too (`Ui.command`), so it still follows the layout.

const keybind = @import("applib").keybind;

pub const Action = enum {
    focusLeft,
    focusRight,
    focusUp,
    focusDown,
    /// A new pane below the focused one.
    splitBelow,
    /// A new pane right of the focused one.
    splitRight,
    killPane,
    zoom,
    resizeLeft,
    resizeRight,
    resizeUp,
    resizeDown,
    quit,

    /// Whether the command leaves a zoom in place: `zoom` toggles it
    /// itself and `quit` is about to tear everything down. Everything
    /// else acts on the real layout, so a zoom is undone first.
    pub fn keepsZoom(self: Action) bool {
        return self == .zoom or self == .quit;
    }
};

pub const Keymap = keybind.Keymap(Action);
pub const Override = keybind.Override(Action);

pub const defaults = [_]keybind.Default(Action){
    .{ .chord = "left", .action = .focusLeft },
    .{ .chord = "right", .action = .focusRight },
    .{ .chord = "up", .action = .focusUp },
    .{ .chord = "down", .action = .focusDown },
    .{ .chord = "\"", .action = .splitBelow },
    .{ .chord = "%", .action = .splitRight },
    .{ .chord = "x", .action = .killPane },
    .{ .chord = "z", .action = .zoom },
    .{ .chord = "H", .action = .resizeLeft },
    .{ .chord = "L", .action = .resizeRight },
    .{ .chord = "K", .action = .resizeUp },
    .{ .chord = "J", .action = .resizeDown },
    .{ .chord = "q", .action = .quit },
};
