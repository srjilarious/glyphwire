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
    /// Every pane moves one slot along the layout in reading order (left
    /// to right, top to bottom), the last wrapping to the first; the
    /// layout and its ratios stay put. Focus stays on the slot, so the
    /// pane that arrives there takes it (tmux's `rotate-window -D`).
    rotateForward,
    /// The same, the other way (`rotate-window -U`).
    rotateBackward,
    quit,
    /// Hands the prefix chord itself to the focused pane's program, once
    /// (tmux's `send-prefix`): the prefix pressed twice. What lets a
    /// program that wants the same chord -- zoe's Ctrl+B sidebar toggle --
    /// still have it.
    sendPrefix,

    /// Whether the command leaves a zoom in place: `zoom` toggles it
    /// itself, `quit` is about to tear everything down, `sendPrefix` is a
    /// keystroke for the pane on screen, and a rotate only changes which
    /// pane the zoom shows. Everything else acts on the real layout, so a
    /// zoom is undone first.
    pub fn keepsZoom(self: Action) bool {
        return switch (self) {
            .zoom, .quit, .sendPrefix, .rotateForward, .rotateBackward => true,
            else => false,
        };
    }
};

/// `sendPrefix`'s default chord: the prefix chord itself (Ctrl plus
/// `prefix_key`), so it follows a configured prefix rather than being a
/// fixed `ctrl+b` in `defaults`.
pub fn sendPrefixChord(prefix_key: u8) keybind.Chord {
    var buf: [6]u8 = "ctrl+?".*;
    buf[5] = prefix_key;
    // `config.readPrefixKey` only lets one lowercase letter through.
    return keybind.Chord.parse(&buf) catch unreachable;
}

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
    .{ .chord = "}", .action = .rotateForward },
    .{ .chord = "{", .action = .rotateBackward },
    .{ .chord = "q", .action = .quit },
};
