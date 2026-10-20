// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: GPL-3.0-or-later

//! The `:` commands the command palette lists (`Ui.openPalette`), so
//! everything typed on the statusline can be found by name too:
//! "Add Folder to Workspace" is `:addfolder`. `Editor.runCommand` is
//! still what parses and runs them; this table only names them.
//!
//! A command that does what an `Action` does (`:bd` and `closeTab`) is
//! one palette row, the action's, with its `:` form shown beside the
//! chord. The rest are rows of their own: picked, one that needs an
//! argument puts the `:` line up holding `name ` for it (the Tab path
//! popup and Up's history then work as usual); one that doesn't runs
//! straight away.

const std = @import("std");
const Action = @import("actions.zig").Action;

pub const ExCommand = struct {
    /// What the palette shows after the `:`, and what it matches a query
    /// against. The spelling people type, not always vim's long one.
    name: []const u8,
    /// The palette's row label. Unused when `action` is set: the row is
    /// the action's, under the action's label.
    label: []const u8,
    /// The action this is the `:` form of, or null for a row of its own.
    action: ?Action = null,
    /// Picked from the palette, the `:` line is put up holding this and
    /// waits for the rest, rather than running `name`. Null runs it.
    prefill: ?[]const u8 = null,
};

pub const commands = [_]ExCommand{
    .{ .name = "w", .label = "Save", .action = .save },
    .{ .name = "w", .label = "Save As", .prefill = "w " },
    .{ .name = "wq", .label = "Save and Quit" },
    .{ .name = "q", .label = "Quit" },
    .{ .name = "q!", .label = "Quit Without Saving" },
    .{ .name = "e", .label = "Open File", .prefill = "e " },
    .{ .name = "e!", .label = "Revert to Saved" },
    .{ .name = "enew", .label = "", .action = .newBuffer },
    .{ .name = "bn", .label = "", .action = .nextTab },
    .{ .name = "bp", .label = "", .action = .prevTab },
    .{ .name = "bd", .label = "", .action = .closeTab },
    .{ .name = "bd!", .label = "Close Tab Discarding Changes" },
    .{ .name = "vsplit", .label = "Split Group Right" },
    .{ .name = "split", .label = "Split Group Down" },
    .{ .name = "close", .label = "Close Group" },
    .{ .name = "zoom", .label = "", .action = .zoomGroup },
    .{ .name = "N", .label = "Go to Line", .prefill = "" },
    .{ .name = "%s", .label = "Substitute in File", .prefill = "%s/" },
    .{ .name = "noh", .label = "Clear Search Highlight" },
    .{ .name = "set", .label = "Set Option", .prefill = "set " },
    .{ .name = "cd", .label = "Change Directory", .prefill = "cd " },
    .{ .name = "pwd", .label = "Show Working Directory" },
    .{ .name = "addfolder", .label = "Add Folder to Workspace", .prefill = "addfolder " },
    .{ .name = "rmfolder", .label = "Remove Folder from Workspace", .prefill = "rmfolder " },
    .{ .name = "wssave", .label = "Save Workspace" },
    .{ .name = "wssave", .label = "Save Workspace As", .prefill = "wssave " },
    .{ .name = "wsopen", .label = "Open Workspace", .prefill = "wsopen " },
    .{ .name = "wsopen!", .label = "Open Workspace Discarding Changes", .prefill = "wsopen! " },
    .{ .name = "themes", .label = "", .action = .selectTheme },
    .{ .name = "theme", .label = "Change Theme by Name", .prefill = "theme " },
    .{ .name = "shell", .label = "Move Shell Panel", .prefill = "shell " },
    .{ .name = "lsp", .label = "Language Server Status" },
    .{ .name = "lsp restart", .label = "Restart Language Servers" },
    .{ .name = "diag", .label = "List Diagnostics" },
    .{ .name = "extensions", .label = "", .action = .listExtensions },
    .{ .name = "recover", .label = "Recover Backup" },
};

/// The `:` form of `action`, if it has one.
pub fn forAction(action: Action) ?[]const u8 {
    for (commands) |c| {
        if (c.action == action) return c.name;
    }
    return null;
}
