// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: GPL-3.0-or-later

//! Everything salacommander can be told to do, by name. A key press is
//! looked up in an `applib.keybind.Keymap(Action)` and the UI switches on
//! the result, so a new command is one enum tag, one default chord here
//! and one arm in `Ui.perform` -- and `salacommander.conf.lua` can rebind
//! it by the same name without any further code:
//!
//!     config = { keys = { ["alt+up"] = "upToParentDir", ["F7"] = false } }
//!
//! The tag names are the config names, so they're camelCase on purpose
//! and renaming one breaks users' configs.

const std = @import("std");
const glyphwire = @import("glyphwire");
const keybind = @import("applib").keybind;

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
    /// Turn the active pane's title row into a text field holding its
    /// directory: Enter goes there, Escape puts the title back. Clicking
    /// a title row does the same without a key.
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

    /// Turn the name of the entry under the cursor into a text field
    /// where it's listed: Enter renames it, Escape (or any key that does
    /// something else) leaves it alone. Same directory only -- F6 moves.
    rename,
    /// Search every path under the active pane's directory, the popup
    /// zoe's Ctrl+P is. Picking one points the pane at it rather than
    /// opening it: Enter (or F4) is one more key from there.
    find,
    /// Open the file under the cursor in the configured `editor` (zoe by
    /// default). A binary file or a directory is refused in the bar.
    edit,
    copy,
    move,
    makeDir,
    delete,
    /// Name a file that doesn't exist yet and open it in the `editor`
    /// (Midnight Commander's Shift+F4). Nothing is created until the
    /// editor saves it.
    newFile,
    /// F1: the file operations menu. Its entries are the `menu_defaults`
    /// keymap's unmodified chords (`menu_keys` in the config); a pick
    /// with modifiers held runs whatever that chord is bound to instead,
    /// so `super+m` is chmod as root.
    fileOpsMenu,
    /// Set the selection's permission bits: twelve toggles and the octal
    /// value they make, kept in step. Starts from the first entry's.
    chmod,
    /// Set the selection's owner and group by name or id.
    chown,

    /// The same operations as root, through sudo (see `sudo.zig`): a
    /// masked dialog asks for the password when sudo doesn't remember
    /// one. Edit and new file are `sudoedit`, so the editor still runs
    /// as you.
    sudoRename,
    sudoEdit,
    sudoNewFile,
    sudoCopy,
    sudoMove,
    sudoMakeDir,
    sudoDelete,
    sudoChmod,
    sudoChown,

    /// Open or close the shell panel across the bottom (see
    /// `applib/shellpanel.zig`). Closing it leaves the shell running.
    toggleShell,

    /// Re-order the active pane. Directories still lead; picking the
    /// order already in force flips it, the way a header click does.
    sortByName,
    sortByExt,
    sortBySize,
    sortByTime,

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

    .{ .chord = "F1", .action = .fileOpsMenu },
    .{ .chord = "F2", .action = .rename },
    .{ .chord = "F3", .action = .find },
    .{ .chord = "F4", .action = .edit },
    .{ .chord = "F5", .action = .copy },
    .{ .chord = "F6", .action = .move },
    .{ .chord = "F7", .action = .makeDir },
    .{ .chord = "F8", .action = .delete },
    .{ .chord = "delete", .action = .delete },
    .{ .chord = "shift+F4", .action = .newFile },

    // Super is "as root": the same function keys, through sudo.
    .{ .chord = "super+F2", .action = .sudoRename },
    .{ .chord = "super+F4", .action = .sudoEdit },
    .{ .chord = "super+shift+F4", .action = .sudoNewFile },
    .{ .chord = "super+F5", .action = .sudoCopy },
    .{ .chord = "super+F6", .action = .sudoMove },
    .{ .chord = "super+F7", .action = .sudoMakeDir },
    .{ .chord = "super+F8", .action = .sudoDelete },
    .{ .chord = "super+delete", .action = .sudoDelete },

    .{ .chord = "ctrl+`", .action = .toggleShell },

    // Total Commander's sort keys.
    .{ .chord = "ctrl+F3", .action = .sortByName },
    .{ .chord = "ctrl+F4", .action = .sortByExt },
    .{ .chord = "ctrl+F5", .action = .sortBySize },
    .{ .chord = "ctrl+F6", .action = .sortByTime },

    .{ .chord = "ctrl+1", .action = .viewSmall },
    .{ .chord = "ctrl+2", .action = .viewLarge },
    .{ .chord = "ctrl+v", .action = .toggleView },
    .{ .chord = "ctrl+h", .action = .toggleHidden },
    .{ .chord = "ctrl+r", .action = .refresh },
    .{ .chord = "F10", .action = .quit },
    .{ .chord = "ctrl+q", .action = .quit },
};

/// The F1 menu's own keymap (`menu_keys` in the config), over the same
/// actions. Each unmodified chord is a line of the menu, in this order;
/// the modified ones are what a pick turns into while their modifiers
/// are held. Kept apart from `defaults` so a bare letter here doesn't
/// take that letter from type-to-find in the panes.
pub const menu_defaults = [_]keybind.Default(Action){
    .{ .chord = "m", .action = .chmod },
    .{ .chord = "super+m", .action = .sudoChmod },
    .{ .chord = "o", .action = .chown },
    .{ .chord = "super+o", .action = .sudoChown },
};

/// A short label for the function-key bar along the bottom.
pub fn barLabel(action: Action) []const u8 {
    return switch (action) {
        .fileOpsMenu => "FileOp",
        .rename, .sudoRename => "Rename",
        .find => "Find",
        .edit, .sudoEdit => "Edit",
        .newFile, .sudoNewFile => "New",
        .copy, .sudoCopy => "Copy",
        .move, .sudoMove => "RenMov",
        .makeDir, .sudoMakeDir => "Mkdir",
        .delete, .sudoDelete => "Delete",
        .chmod, .sudoChmod => "Chmod",
        .chown, .sudoChown => "Chown",
        .sortByName => "Name",
        .sortByExt => "Ext",
        .sortBySize => "Size",
        .sortByTime => "Time",
        .toggleView => "View",
        .refresh => "Reread",
        .quit => "Quit",
        .toggleHidden => "Hidden",
        else => @tagName(action),
    };
}

/// A line of the F1 menu.
pub fn menuLabel(action: Action) []const u8 {
    return switch (action) {
        .chmod => "Change mode...",
        .sudoChmod => "Change mode as root...",
        .chown => "Change owner/group...",
        .sudoChown => "Change owner/group as root...",
        else => barLabel(action),
    };
}

/// Whether `action` runs through sudo, so the bar and the F1 menu can
/// say so.
pub fn isRoot(action: Action) bool {
    return switch (action) {
        .sudoRename, .sudoEdit, .sudoNewFile, .sudoCopy, .sudoMove, .sudoMakeDir, .sudoDelete, .sudoChmod, .sudoChown => true,
        else => false,
    };
}

/// The actions the function-key bar shows, in order, when no modifier
/// is held. With one held it shows whatever each F-key is bound to
/// under it instead (`Ui.renderBar`).
pub const bar_actions = [_]Action{ .fileOpsMenu, .rename, .find, .edit, .copy, .move, .makeDir, .delete, .toggleView, .toggleHidden, .refresh, .quit };

/// What a pick in the F1 menu means: an entry's unmodified chord key
/// pressed again with `held`, looked up in the menu keymap, else the
/// entry itself. So holding the modifiers `sudoChmod` is bound with
/// while pressing Enter on "Change mode" is chmod as root.
pub fn menuPick(menu: *const Keymap, entry: Action, held: keybind.Mods) Action {
    const chord = menu.chordFor(entry) orelse return entry;
    return menu.lookup(chord.key(), held) orelse entry;
}

/// The F1 menu's entries: the actions the menu keymap binds to a chord
/// without modifiers, in binding order, each once. Fills `buf` and
/// returns the used part.
pub fn menuEntries(menu: *const Keymap, buf: []Action) []Action {
    var n: usize = 0;
    outer: for (menu.bindings.items) |b| {
        if (n == buf.len) break;
        if (!std.meta.eql(b.chord.mods, keybind.Mods{}) or b.chord.text) continue;
        for (buf[0..n]) |a| {
            if (a == b.action) continue :outer;
        }
        buf[n] = b.action;
        n += 1;
    }
    return buf[0..n];
}
