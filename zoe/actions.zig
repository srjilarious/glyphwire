// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: GPL-3.0-or-later

//! Every chord and named key zoe answers to, by name. A key press is
//! looked up in the `Keymaps` for the editor's mode and the result is
//! switched on -- by `Ui.perform` for the window-level actions (`isUi`),
//! by `Editor.perform` for the rest -- so `zoe.conf.lua` can rebind any
//! of them without code:
//!
//!     config = { keys = {
//!         global = { ["alt+h"] = false, ["ctrl+shift+h"] = "toggleHidden" },
//!         insert = { ["ctrl+d"] = "deleteWordForward" },
//!     } }
//!
//! Only chords and named keys live here. Unmodified printable keys in
//! normal and visual mode (`dd`, `gg`, `ciw`) are vim's grammar of counts,
//! operators and prefixes, and stay hard-coded in `editor.zig`; so do
//! Escape, the `:` / `/` line's editing keys, the file tree's own keys,
//! and the key after Ctrl+W.
//!
//! The tag names are the config names, so they're camelCase on purpose
//! and renaming one breaks users' configs.

const std = @import("std");
const keybind = @import("applib").keybind;

pub const Action = enum {
    /// Does nothing, and stops the lookup there: `false` in a config binds
    /// this, so a mode table can hide a global chord rather than fall
    /// through to it.
    none,

    // ── Window-level (`Ui.perform`) ──────────────────────────────────

    /// `:w` on the active buffer, leaving the mode alone.
    save,
    /// The Ctrl+P fuzzy file finder.
    findFile,
    /// The Ctrl+Shift+P command palette: every action here that
    /// `inPalette` lists, searchable by name (`applib/palette.zig`).
    commandPalette,
    /// Every extension zoe could load and whether it did, in a popup
    /// (`zoe/extlist.zig`); `:extensions` too.
    listExtensions,
    /// Every theme `:theme` can switch to, in the palette's popup, the
    /// highlighted one applied as the cursor moves (`zoe/themepicker.zig`);
    /// `:themes` too.
    selectTheme,
    toggleTree,
    /// Dotfiles and `.gitignore`d paths, in the tree and the finder.
    toggleHidden,
    /// The focused group's file found in the sidebar: the tree shown if
    /// it was hidden, its folders opened down to the file and the cursor
    /// put on it. The keyboard stays where it was.
    revealInTree,
    toggleShell,
    nextTab,
    prevTab,
    /// The focused group's shown tab, refused on a modified buffer the
    /// way `:bd` and the tab's `×` are. Ctrl+W x too.
    closeTab,
    /// The focused group's tabs left of the shown one, right of it, or
    /// all but it (`:tabcloseleft`, `:tabcloseright`, `:tabonly`).
    /// Modified tabs are left open and counted on the statusline; the
    /// `:` forms with `!` close those too. Unbound by default.
    closeTabsLeft,
    closeTabsRight,
    closeOtherTabs,
    /// A new `[No Name]` scratch tab next to the shown one (`:enew`).
    newBuffer,
    /// vim's Ctrl+W: the next key splits, closes or moves between groups.
    windowPrefix,
    focusLeft,
    focusRight,
    focusUp,
    focusDown,
    /// The shown tab to the group that way (a new one split off on that
    /// side when there is none). Unbound by default -- Ctrl+W Shift+hjkl
    /// is the built-in route -- so these are for `keys` to bind directly.
    moveTabLeft,
    moveTabRight,
    moveTabUp,
    moveTabDown,
    /// The focused group full-window, the other groups hidden (the
    /// sidebar stays); again to put them back. Ctrl+W z and `:zoom` too.
    /// Splitting, closing or moving to another group unzooms first.
    zoomGroup,
    jumpBack,
    jumpForward,
    /// Two-letter labels over every word start on the focused pane's
    /// visible rows; typing one moves the cursor there (`zoe/jump.zig`).
    /// A selection is extended to it, and the jumplist remembers where
    /// the cursor was.
    jump,
    /// The selection (or the line) to the system clipboard, removed.
    cut,
    /// The system clipboard, pasted after the cursor (vim's `p`), or over
    /// a selection.
    paste,
    /// Ask the language servers for completions here.
    complete,

    // ── Editor (`Editor.perform`) ────────────────────────────────────

    left,
    right,
    up,
    down,
    lineStart,
    lineEnd,
    /// Whole words, vim's `b` / `w`.
    wordLeft,
    wordRight,
    /// Word parts, VS Code's: `fooBar`, `foo_bar`, `HTTPServer` and
    /// `v2Thing` each stop inside the word as well as at its start.
    subwordLeft,
    subwordRight,
    fileStart,
    fileEnd,
    pageUp,
    pageDown,

    /// The same motions, extending a selection: visual mode from normal,
    /// a typed-over selection (select mode) from insert.
    selectLeft,
    selectRight,
    selectUp,
    selectDown,
    selectLineStart,
    selectLineEnd,
    selectWordLeft,
    selectWordRight,
    selectSubwordLeft,
    selectSubwordRight,
    selectFileStart,
    selectFileEnd,

    undo,
    redo,
    /// `>>` on the cursor line, `>` on a selection (which stays selected).
    indent,
    dedent,
    moveLinesUp,
    moveLinesDown,
    copyLinesUp,
    copyLinesDown,
    /// Line comments on or off for the cursor line or the selected lines.
    toggleComment,
    /// Close the innermost open fold around the cursor (`zc`).
    fold,
    /// Open the closed fold on the cursor's line (`zo`).
    unfold,
    /// `za`: open it if closed, else close the one the cursor is in.
    toggleFold,
    /// Every fold closed (`zM`) / open (`zR`).
    foldAll,
    unfoldAll,

    /// VS Code's find widget over the buffer (`Mode.find`): `find`
    /// opens it with the find field, `replace` with the replace row too.
    /// Pressed with the widget open they move to that field.
    find,
    replace,

    /// Insert mode's typing keys. Over a selection they replace it.
    newline,
    insertTab,
    backspace,
    deleteForward,
    deleteWordBack,
    deleteWordForward,
    deleteSubwordBack,
    deleteSubwordForward,

    /// Soft wrap on or off, in every buffer (`:set wrap` / `:set nowrap`).
    toggleWordWrap,

    /// Whether the command palette lists it. Left out: the palette
    /// itself, Ctrl+W's prefix (it waits for a key the palette has just
    /// taken), completion (insert mode's, and its chord's space is
    /// swallowed), and the keys that move the cursor or type -- running
    /// "Left" or "Backspace" by name is never quicker than the key.
    pub fn inPalette(self: Action) bool {
        return switch (self) {
            .none, .commandPalette, .windowPrefix, .complete => false,
            .left, .right, .up, .down, .lineStart, .lineEnd, .wordLeft, .wordRight, .subwordLeft, .subwordRight, .fileStart, .fileEnd, .pageUp, .pageDown => false,
            .selectLeft, .selectRight, .selectUp, .selectDown, .selectLineStart, .selectLineEnd, .selectWordLeft, .selectWordRight, .selectSubwordLeft, .selectSubwordRight, .selectFileStart, .selectFileEnd => false,
            .newline, .insertTab, .backspace, .deleteForward, .deleteWordBack, .deleteWordForward, .deleteSubwordBack, .deleteSubwordForward => false,
            else => true,
        };
    }

    /// The palette's name for it, where the tag made into words
    /// (`palette.labelFromName`) reads badly. Null for the rest.
    pub fn paletteLabel(self: Action) ?[]const u8 {
        return switch (self) {
            .prevTab => "Previous Tab",
            .newBuffer => "New Scratch Buffer",
            .closeTabsLeft => "Close Tabs to the Left",
            .closeTabsRight => "Close Tabs to the Right",
            .toggleHidden => "Toggle Hidden Files",
            .toggleShell => "Toggle Shell Panel",
            .toggleTree => "Toggle File Tree",
            .revealInTree => "Reveal Active File in Tree",
            .focusLeft => "Focus Group Left",
            .focusRight => "Focus Group Right",
            .focusUp => "Focus Group Above",
            .focusDown => "Focus Group Below",
            .moveTabUp => "Move Tab Up a Group",
            .moveTabDown => "Move Tab Down a Group",
            .moveTabLeft => "Move Tab Left a Group",
            .moveTabRight => "Move Tab Right a Group",
            .zoomGroup => "Toggle Zoom Group",
            .indent => "Indent Lines",
            .dedent => "Dedent Lines",
            .toggleComment => "Toggle Line Comment",
            .fold => "Fold",
            .unfold => "Unfold",
            .foldAll => "Fold All",
            .unfoldAll => "Unfold All",
            .replace => "Find and Replace",
            .paste => "Paste from Clipboard",
            .cut => "Cut to Clipboard",
            .jump => "Jump to Word",
            .selectTheme => "Select Color Theme",
            else => null,
        };
    }

    /// Whether `Ui.perform` handles this rather than the editor.
    pub fn isUi(self: Action) bool {
        return @intFromEnum(self) >= @intFromEnum(Action.save) and
            @intFromEnum(self) <= @intFromEnum(Action.complete);
    }
};

pub const Keymap = keybind.Keymap(Action);
pub const Default = keybind.Default(Action);

/// Which table a binding lives in. A key is looked up in its mode's table
/// first and `global` after, so the mode tables only hold what differs.
/// Select mode (a selection made with Shift+arrows in insert mode) reads
/// `insert`; the `:` and `/` lines read only `global`.
pub const Scope = enum { global, normal, visual, insert };

/// Bindings every mode shares: the window chords, the arrows and their
/// Shift forms, and the VSCode-style edits.
pub const global_defaults = [_]Default{
    .{ .chord = "ctrl+s", .action = .save },
    .{ .chord = "ctrl+p", .action = .findFile },
    .{ .chord = "ctrl+b", .action = .toggleTree },
    // A second chord for the same thing: gmux's prefix is Ctrl+B, and
    // the session hands it to gmux before zoe ever sees it.
    .{ .chord = "ctrl+n", .action = .toggleTree },
    // Ctrl+H is VS Code's replace; hidden files moved off it to Alt+H.
    .{ .chord = "alt+h", .action = .toggleHidden },
    .{ .chord = "ctrl+shift+e", .action = .revealInTree },
    .{ .chord = "ctrl+f", .action = .find },
    .{ .chord = "ctrl+h", .action = .replace },
    .{ .chord = "ctrl+grave_accent", .action = .toggleShell },
    .{ .chord = "ctrl+tab", .action = .nextTab },
    .{ .chord = "ctrl+shift+tab", .action = .prevTab },
    // Ctrl+W is the window prefix, so closing a tab takes the Windows /
    // VS Code alternate (Ctrl+W x is the prefix's own route).
    .{ .chord = "ctrl+F4", .action = .closeTab },
    .{ .chord = "ctrl+shift+n", .action = .newBuffer },
    .{ .chord = "ctrl+w", .action = .windowPrefix },
    // `h` is deliberately absent: Ctrl+H is replace, and focusing left
    // is already Ctrl+Left and Ctrl+W h.
    .{ .chord = "ctrl+left", .action = .focusLeft },
    .{ .chord = "ctrl+right", .action = .focusRight },
    .{ .chord = "ctrl+l", .action = .focusRight },
    .{ .chord = "ctrl+up", .action = .focusUp },
    .{ .chord = "ctrl+k", .action = .focusUp },
    .{ .chord = "ctrl+down", .action = .focusDown },
    .{ .chord = "ctrl+j", .action = .focusDown },
    .{ .chord = "ctrl+o", .action = .jumpBack },
    .{ .chord = "ctrl+i", .action = .jumpForward },
    // Every mode, insert included: Shift+Enter there was only a second
    // Enter.
    .{ .chord = "shift+enter", .action = .jump },
    // VS Code's.
    .{ .chord = "alt+z", .action = .toggleWordWrap },
    .{ .chord = "ctrl+shift+p", .action = .commandPalette },
    // `paste` has no chord of its own: Ctrl+Shift+V is the host's, which
    // reads the system clipboard and sends it as a `paste` event zoe
    // already splices in. The action stays for the palette and `keys`.
    .{ .chord = "ctrl+shift+x", .action = .cut },

    .{ .chord = "left", .action = .left },
    .{ .chord = "right", .action = .right },
    .{ .chord = "up", .action = .up },
    .{ .chord = "down", .action = .down },
    .{ .chord = "home", .action = .lineStart },
    .{ .chord = "end", .action = .lineEnd },
    .{ .chord = "page_up", .action = .pageUp },
    .{ .chord = "page_down", .action = .pageDown },

    .{ .chord = "shift+left", .action = .selectLeft },
    .{ .chord = "shift+right", .action = .selectRight },
    .{ .chord = "shift+up", .action = .selectUp },
    .{ .chord = "shift+down", .action = .selectDown },
    .{ .chord = "shift+home", .action = .selectLineStart },
    .{ .chord = "shift+end", .action = .selectLineEnd },
    // Ctrl+arrows move by word part (insert mode's, below), so their
    // Shift forms select by one; whole words are Alt's.
    .{ .chord = "ctrl+shift+left", .action = .selectSubwordLeft },
    .{ .chord = "ctrl+shift+right", .action = .selectSubwordRight },
    .{ .chord = "alt+left", .action = .wordLeft },
    .{ .chord = "alt+right", .action = .wordRight },
    .{ .chord = "shift+alt+left", .action = .selectWordLeft },
    .{ .chord = "shift+alt+right", .action = .selectWordRight },
    .{ .chord = "ctrl+shift+home", .action = .selectFileStart },
    .{ .chord = "ctrl+shift+end", .action = .selectFileEnd },

    .{ .chord = "ctrl+z", .action = .undo },
    .{ .chord = "ctrl+shift+z", .action = .redo },
    .{ .chord = "ctrl+y", .action = .redo },
    .{ .chord = "alt+up", .action = .moveLinesUp },
    .{ .chord = "alt+down", .action = .moveLinesDown },
    .{ .chord = "shift+alt+up", .action = .copyLinesUp },
    .{ .chord = "shift+alt+down", .action = .copyLinesDown },
    .{ .chord = "ctrl+slash", .action = .toggleComment },
    // VS Code's fold chords. Its fold-all / unfold-all are Ctrl+K
    // chords, and Ctrl+K is focus-up here, so those two are the
    // palette's (and `keys`') alone.
    .{ .chord = "ctrl+shift+left_bracket", .action = .fold },
    .{ .chord = "ctrl+shift+right_bracket", .action = .unfold },
};

/// vim's chords with no printable key to carry them, and Tab as `>>`.
pub const normal_defaults = [_]Default{
    .{ .chord = "ctrl+r", .action = .redo },
    .{ .chord = "ctrl+d", .action = .pageDown },
    .{ .chord = "ctrl+u", .action = .pageUp },
    .{ .chord = "tab", .action = .indent },
    .{ .chord = "shift+tab", .action = .dedent },
};

pub const visual_defaults = normal_defaults;

/// Typing keys, plus the word and file jumps insert mode takes back from
/// the global focus chords.
pub const insert_defaults = [_]Default{
    .{ .chord = "enter", .action = .newline },
    .{ .chord = "tab", .action = .insertTab },
    .{ .chord = "shift+tab", .action = .dedent },
    .{ .chord = "backspace", .action = .backspace },
    .{ .chord = "shift+backspace", .action = .backspace },
    .{ .chord = "delete", .action = .deleteForward },
    // By word part, like the arrows beside them. `deleteWordBack` and
    // `deleteWordForward` are left for `keys` to bind.
    .{ .chord = "ctrl+backspace", .action = .deleteSubwordBack },
    .{ .chord = "ctrl+delete", .action = .deleteSubwordForward },
    .{ .chord = "ctrl+left", .action = .subwordLeft },
    .{ .chord = "ctrl+right", .action = .subwordRight },
    .{ .chord = "ctrl+home", .action = .fileStart },
    .{ .chord = "ctrl+end", .action = .fileEnd },
    .{ .chord = "ctrl+space", .action = .complete },
};


/// One `zoe.conf.lua` `keys` entry, already validated (`luaconf.scopedKeys`).
/// A null `action` (`false`) binds `.none` in its table.
pub const Override = keybind.ScopedOverride(Scope, Action);

/// A `keys` entry naming no `Action`: perhaps a Lua extension's command
/// (`zoe/ext.zig`), which is only known once the extensions load.
pub const NamedOverride = keybind.ScopedNamed(Scope);

/// Every mode table but `global` falls back to `global`.
fn parentScope(scope: Scope) ?Scope {
    return if (scope == .global) null else .global;
}

pub const Keymaps = keybind.Scoped(Scope, Action, parentScope, .none);

pub const defaults: Keymaps.Defaults = .init(.{
    .global = &global_defaults,
    .normal = &normal_defaults,
    .visual = &visual_defaults,
    .insert = &insert_defaults,
});
