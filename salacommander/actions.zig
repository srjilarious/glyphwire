// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: GPL-3.0-or-later

//! Everything salacommander can be told to do, by name. A key press is
//! looked up in a `glyphwire.keybind.Keymap(Action)` and the UI switches on
//! the result, so a new command is one enum tag, one default chord here
//! and one arm in `Ui.perform` -- and `salacommander.conf.lua` can rebind
//! it by the same name without any further code:
//!
//!     config = { keys = { ["alt+up"] = "upToParentDir", ["F3"] = false } }
//!
//! The tag names are the config names, so they're camelCase on purpose
//! and renaming one breaks users' configs.

const std = @import("std");
const glyphwire = @import("glyphwire");
const keybind = glyphwire.keybind;

pub const Action = enum {
    cursorUp,
    cursorDown,
    pageUp,
    pageDown,
    cursorHome,
    cursorEnd,
    /// Enter a directory, go up from `..`, or open a file with the
    /// desktop's opener.
    activate,
    upToParentDir,
    /// Type a directory for the active pane, starting from the one it
    /// shows.
    editPath,
    switchPane,
    /// Point the other pane at this pane's directory.
    otherPaneToSameDir,
    swapPanes,

    toggleMark,
    toggleMarkAndDown,
    markAll,
    unmarkAll,
    invertMarks,

    copy,
    move,
    makeDir,
    delete,

    viewSmall,
    viewLarge,
    toggleView,
    toggleHidden,
    refresh,
    quit,
};

pub const Keymap = keybind.Keymap(Action);

/// The built-in bindings: Midnight Commander's function keys, Total
/// Commander's marking keys.
pub const defaults = [_]keybind.Default(Action){
    .{ .chord = "up", .action = .cursorUp },
    .{ .chord = "down", .action = .cursorDown },
    .{ .chord = "page_up", .action = .pageUp },
    .{ .chord = "page_down", .action = .pageDown },
    .{ .chord = "home", .action = .cursorHome },
    .{ .chord = "end", .action = .cursorEnd },
    .{ .chord = "enter", .action = .activate },
    .{ .chord = "kp_enter", .action = .activate },
    .{ .chord = "alt+up", .action = .upToParentDir },
    .{ .chord = "backspace", .action = .upToParentDir },
    .{ .chord = "alt+d", .action = .editPath },
    .{ .chord = "tab", .action = .switchPane },
    .{ .chord = "alt+o", .action = .otherPaneToSameDir },
    .{ .chord = "ctrl+u", .action = .swapPanes },

    .{ .chord = "space", .action = .toggleMark },
    .{ .chord = "insert", .action = .toggleMarkAndDown },
    .{ .chord = "kp_add", .action = .markAll },
    .{ .chord = "ctrl+a", .action = .markAll },
    .{ .chord = "kp_subtract", .action = .unmarkAll },
    .{ .chord = "ctrl+d", .action = .unmarkAll },
    .{ .chord = "kp_multiply", .action = .invertMarks },

    .{ .chord = "F5", .action = .copy },
    .{ .chord = "F6", .action = .move },
    .{ .chord = "F7", .action = .makeDir },
    .{ .chord = "F8", .action = .delete },
    .{ .chord = "delete", .action = .delete },

    .{ .chord = "ctrl+1", .action = .viewSmall },
    .{ .chord = "ctrl+2", .action = .viewLarge },
    .{ .chord = "ctrl+v", .action = .toggleView },
    .{ .chord = "ctrl+h", .action = .toggleHidden },
    .{ .chord = "ctrl+r", .action = .refresh },
    .{ .chord = "F10", .action = .quit },
    .{ .chord = "ctrl+q", .action = .quit },
};

/// A short label for the function-key bar along the bottom.
pub fn barLabel(action: Action) []const u8 {
    return switch (action) {
        .copy => "Copy",
        .move => "RenMov",
        .makeDir => "Mkdir",
        .delete => "Delete",
        .toggleView => "View",
        .refresh => "Reread",
        .quit => "Quit",
        .toggleHidden => "Hidden",
        else => @tagName(action),
    };
}

/// The actions the function-key bar shows, in order.
pub const bar_actions = [_]Action{ .copy, .move, .makeDir, .delete, .toggleView, .toggleHidden, .refresh, .quit };
