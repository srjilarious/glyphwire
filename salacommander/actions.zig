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
    /// Back and forward through the directories this pane has shown,
    /// the way a browser's buttons go; Back puts the cursor on the entry
    /// it was on (see `dirhistory.zig`).
    historyBack,
    historyForward,
    /// A list of the directories this pane has been in this session,
    /// most recent first, to filter by typing and pick one from.
    showHistory,
    /// Turn the active pane's title row into a text field holding its
    /// directory: Enter goes there, Escape puts the title back. Clicking
    /// a title row does the same without a key.
    editPath,
    switchPane,
    /// Point the other pane at this pane's directory.
    otherPaneToSameDir,
    /// The same, but only toward the side the arrow points: Ctrl+Right
    /// from the left pane, Ctrl+Left from the right one. From the pane
    /// on that side already there is nothing further, so it does nothing.
    rightPaneToSameDir,
    leftPaneToSameDir,
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
    /// Ctrl+Shift+P: every action `inPalette` lists, searchable by name
    /// and run from the list (`applib/palette.zig`, zoe's too).
    commandPalette,
    /// Open the file under the cursor in the configured `editor` (zoe by
    /// default). A binary file or a directory is refused in the bar.
    edit,
    copy,
    move,
    makeDir,
    /// Move the selection to the desktop trash (the freedesktop.org one
    /// the file manager's trash can shows), after a yes/no that defaults
    /// to yes. What can't go there is offered for `delete` instead.
    trash,
    /// Delete the selection outright, after a yes/no that defaults to no.
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
    .{ .chord = "alt+left", .action = .historyBack },
    .{ .chord = "alt+right", .action = .historyForward },
    .{ .chord = "alt+down", .action = .showHistory },
    .{ .chord = "alt+d", .action = .editPath },
    .{ .chord = "tab", .action = .switchPane },
    .{ .chord = "alt+o", .action = .otherPaneToSameDir },
    .{ .chord = "ctrl+right", .action = .rightPaneToSameDir },
    .{ .chord = "ctrl+left", .action = .leftPaneToSameDir },
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
    .{ .chord = "ctrl+shift+p", .action = .commandPalette },
    .{ .chord = "F4", .action = .edit },
    .{ .chord = "F5", .action = .copy },
    .{ .chord = "F6", .action = .move },
    .{ .chord = "F7", .action = .makeDir },
    // The trash by default, Shift for gone-for-good: the desktop's own
    // Delete / Shift+Delete.
    .{ .chord = "F8", .action = .trash },
    .{ .chord = "delete", .action = .trash },
    .{ .chord = "shift+F8", .action = .delete },
    .{ .chord = "shift+delete", .action = .delete },
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
        .commandPalette => "Cmds",
        .edit, .sudoEdit => "Edit",
        .newFile, .sudoNewFile => "New",
        .copy, .sudoCopy => "Copy",
        .move, .sudoMove => "RenMov",
        .makeDir, .sudoMakeDir => "Mkdir",
        .trash => "Trash",
        .delete, .sudoDelete => "Delete",
        .chmod, .sudoChmod => "Chmod",
        .chown, .sudoChown => "Chown",
        .sortByName => "Name",
        .sortByExt => "Ext",
        .sortBySize => "Size",
        .sortByTime => "Time",
        .upToParentDir => "Up",
        .historyBack => "Back",
        .historyForward => "Fwd",
        .showHistory => "Hist",
        .editPath => "Path",
        .switchPane => "Other",
        .otherPaneToSameDir => "Same",
        .rightPaneToSameDir => "Same>",
        .leftPaneToSameDir => "<Same",
        .swapPanes => "Swap",
        .markAll => "All",
        .unmarkAll => "None",
        .invertMarks => "Invert",
        .viewSmall => "Small",
        .viewLarge => "Large",
        .toggleShell => "Shell",
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

/// Whether the command palette lists `action`. Left out: the palette
/// itself, and the keys that only move the cursor or mark the row under
/// it -- by name they'd be slower than the key, and the palette hides the
/// cursor they act on.
pub fn inPalette(action: Action) bool {
    return switch (action) {
        .commandPalette => false,
        .cursorUp, .cursorDown, .pageUp, .pageDown, .cursorHome, .cursorEnd => false,
        .toggleMark, .toggleMarkAndDown => false,
        else => true,
    };
}

/// The palette's name for `action`, where its tag made into words
/// (`palette.labelFromName`) reads badly. Null for the rest. The root
/// variants say so in words, since the palette has no danger colour.
pub fn paletteLabel(action: Action) ?[]const u8 {
    return switch (action) {
        .activate => "Open / Enter Directory",
        .otherPaneToSameDir => "Other Pane to Same Directory",
        .rightPaneToSameDir => "Right Pane to Same Directory",
        .leftPaneToSameDir => "Left Pane to Same Directory",
        .upToParentDir => "Up to Parent Directory",
        .historyBack => "Back to Previous Directory",
        .historyForward => "Forward to Next Directory",
        .showHistory => "Directory History",
        .editPath => "Edit Path",
        .find => "Find Below This Directory",
        .copy => "Copy to Other Pane",
        .move => "Move to Other Pane",
        .makeDir => "Make Directory",
        .trash => "Move to Trash",
        .delete => "Delete Permanently",
        .fileOpsMenu => "File Operations Menu",
        .chmod => "Change Mode",
        .chown => "Change Owner/Group",
        .sudoRename => "Rename as Root",
        .sudoEdit => "Edit as Root",
        .sudoNewFile => "New File as Root",
        .sudoCopy => "Copy to Other Pane as Root",
        .sudoMove => "Move to Other Pane as Root",
        .sudoMakeDir => "Make Directory as Root",
        .sudoDelete => "Delete Permanently as Root",
        .sudoChmod => "Change Mode as Root",
        .sudoChown => "Change Owner/Group as Root",
        .toggleShell => "Toggle Shell Panel",
        .sortByExt => "Sort by Extension",
        .sortByName => "Sort by Name",
        .sortBySize => "Sort by Size",
        .sortByTime => "Sort by Time",
        .viewSmall => "Compact View (One Row per Entry)",
        .viewLarge => "Detailed View (Two Rows per Entry)",
        .toggleHidden => "Toggle Hidden Files",
        else => null,
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
pub const bar_actions = [_]Action{ .fileOpsMenu, .rename, .find, .edit, .copy, .move, .makeDir, .trash, .toggleView, .toggleHidden, .refresh, .quit };

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
