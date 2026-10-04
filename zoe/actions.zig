// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: GPL-3.0-or-later

//! Every chord and named key zoe answers to, by name. A key press is
//! looked up in the `Keymaps` for the editor's mode and the result is
//! switched on -- by `Ui.perform` for the window-level actions (`isUi`),
//! by `Editor.perform` for the rest -- so `zoe.conf.lua` can rebind any
//! of them without code:
//!
//!     config = { keys = {
//!         global = { ["ctrl+h"] = false, ["alt+h"] = "toggleHidden" },
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
    toggleTree,
    /// Dotfiles and `.gitignore`d paths, in the tree and the finder.
    toggleHidden,
    toggleShell,
    nextTab,
    prevTab,
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
    jumpBack,
    jumpForward,
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
    wordLeft,
    wordRight,
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

    /// Insert mode's typing keys. Over a selection they replace it.
    newline,
    insertTab,
    backspace,
    deleteForward,
    deleteWordBack,
    deleteWordForward,

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
    .{ .chord = "ctrl+n", .action = .toggleTree },
    .{ .chord = "ctrl+h", .action = .toggleHidden },
    .{ .chord = "ctrl+grave_accent", .action = .toggleShell },
    .{ .chord = "ctrl+tab", .action = .nextTab },
    .{ .chord = "ctrl+shift+tab", .action = .prevTab },
    .{ .chord = "ctrl+w", .action = .windowPrefix },
    // `h` is deliberately absent: Ctrl+H is hidden files, and focusing
    // left is already Ctrl+Left and Ctrl+W h.
    .{ .chord = "ctrl+left", .action = .focusLeft },
    .{ .chord = "ctrl+right", .action = .focusRight },
    .{ .chord = "ctrl+l", .action = .focusRight },
    .{ .chord = "ctrl+up", .action = .focusUp },
    .{ .chord = "ctrl+k", .action = .focusUp },
    .{ .chord = "ctrl+down", .action = .focusDown },
    .{ .chord = "ctrl+j", .action = .focusDown },
    .{ .chord = "ctrl+o", .action = .jumpBack },
    .{ .chord = "ctrl+i", .action = .jumpForward },
    .{ .chord = "ctrl+shift+x", .action = .cut },
    .{ .chord = "ctrl+shift+p", .action = .paste },

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
    .{ .chord = "ctrl+shift+left", .action = .selectWordLeft },
    .{ .chord = "ctrl+shift+right", .action = .selectWordRight },
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
    .{ .chord = "shift+enter", .action = .newline },
    .{ .chord = "tab", .action = .insertTab },
    .{ .chord = "shift+tab", .action = .dedent },
    .{ .chord = "backspace", .action = .backspace },
    .{ .chord = "shift+backspace", .action = .backspace },
    .{ .chord = "delete", .action = .deleteForward },
    .{ .chord = "ctrl+backspace", .action = .deleteWordBack },
    .{ .chord = "ctrl+delete", .action = .deleteWordForward },
    .{ .chord = "ctrl+left", .action = .wordLeft },
    .{ .chord = "ctrl+right", .action = .wordRight },
    .{ .chord = "ctrl+home", .action = .fileStart },
    .{ .chord = "ctrl+end", .action = .fileEnd },
    .{ .chord = "ctrl+space", .action = .complete },
};

/// One `zoe.conf.lua` `keys` entry, already validated. `action` is
/// `.none` for `false`.
pub const Override = struct {
    scope: Scope,
    chord: keybind.Chord,
    action: Action,
};

pub const Keymaps = struct {
    global: Keymap = .{},
    normal: Keymap = .{},
    visual: Keymap = .{},
    insert: Keymap = .{},

    pub fn initDefaults(alloc: std.mem.Allocator) !Keymaps {
        var self: Keymaps = .{};
        errdefer self.deinit(alloc);
        self.global = try Keymap.initDefaults(alloc, &global_defaults);
        self.normal = try Keymap.initDefaults(alloc, &normal_defaults);
        self.visual = try Keymap.initDefaults(alloc, &visual_defaults);
        self.insert = try Keymap.initDefaults(alloc, &insert_defaults);
        return self;
    }

    pub fn deinit(self: *Keymaps, alloc: std.mem.Allocator) void {
        self.global.deinit(alloc);
        self.normal.deinit(alloc);
        self.visual.deinit(alloc);
        self.insert.deinit(alloc);
    }

    pub fn table(self: *Keymaps, scope: Scope) *Keymap {
        return switch (scope) {
            .global => &self.global,
            .normal => &self.normal,
            .visual => &self.visual,
            .insert => &self.insert,
        };
    }

    /// The config's `keys`, over the defaults, in order.
    pub fn apply(self: *Keymaps, alloc: std.mem.Allocator, overrides: []const Override) !void {
        for (overrides) |o| try self.table(o.scope).bind(alloc, o.chord, o.action);
    }

    /// The action a key means in `scope`: that table's binding, else the
    /// global one. Null when neither binds it.
    pub fn lookup(self: *const Keymaps, scope: Scope, key: []const u8, mods: keybind.Mods) ?Action {
        const own: ?*const Keymap = switch (scope) {
            .global => null,
            .normal => &self.normal,
            .visual => &self.visual,
            .insert => &self.insert,
        };
        if (own) |t| {
            if (t.lookup(key, mods)) |a| return a;
        }
        return self.global.lookup(key, mods);
    }
};
