// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: GPL-3.0-or-later

//! Every key gwmd answers to, by name: looked up in a `keybind.Keymap`
//! and switched on in `Ui.perform`. gwmd has no config file yet, so the
//! defaults are the whole table; one that grows a `keys` table reads it
//! with `luaconf.keys` and applies it over them.

const keybind = @import("applib").keybind;

pub const Action = enum {
    quit,
    /// Drops the Tab highlight, else quits.
    back,
    historyBack,
    historyForward,
    scrollUp,
    scrollDown,
    pageUp,
    pageDown,
    top,
    bottom,
    nextLink,
    prevLink,
    followLink,
    reload,
};

pub const Keymap = keybind.Keymap(Action);

pub const defaults = [_]keybind.Default(Action){
    .{ .chord = "q", .action = .quit },
    .{ .chord = "escape", .action = .back },
    .{ .chord = "alt+left", .action = .historyBack },
    .{ .chord = "backspace", .action = .historyBack },
    .{ .chord = "alt+right", .action = .historyForward },
    .{ .chord = "up", .action = .scrollUp },
    .{ .chord = "k", .action = .scrollUp },
    .{ .chord = "down", .action = .scrollDown },
    .{ .chord = "j", .action = .scrollDown },
    .{ .chord = "page_up", .action = .pageUp },
    .{ .chord = "b", .action = .pageUp },
    .{ .chord = "page_down", .action = .pageDown },
    .{ .chord = "space", .action = .pageDown },
    .{ .chord = "home", .action = .top },
    .{ .chord = "g", .action = .top },
    .{ .chord = "end", .action = .bottom },
    .{ .chord = "shift+g", .action = .bottom },
    .{ .chord = "tab", .action = .nextLink },
    .{ .chord = "shift+tab", .action = .prevLink },
    .{ .chord = "enter", .action = .followLink },
    .{ .chord = "kp_enter", .action = .followLink },
    .{ .chord = "r", .action = .reload },
};
