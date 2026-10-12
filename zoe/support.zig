// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: GPL-3.0-or-later

//! `zoe_support`: editor core, tree, tabs, UI. See CONTRIBUTING.md.

pub const buffer = @import("buffer.zig");
pub const motion = @import("motion.zig");
pub const search = @import("search.zig");
pub const editor = @import("editor.zig");
pub const keys = @import("keys.zig");
pub const actions = @import("actions.zig");
pub const display = @import("display.zig");
pub const wrap = @import("wrap.zig");
pub const tree = @import("tree.zig");
pub const finder = @import("applib").finder;
pub const gitignore = @import("applib").gitignore;
pub const filetype = @import("applib").filetype;
pub const ui = @import("ui.zig");
pub const tabs = @import("tabs.zig");
pub const spancache = @import("spancache.zig");
pub const selection_diff = @import("selection_diff.zig");
pub const groups = @import("groups.zig");
pub const langconf = @import("langconf.zig");
pub const lsp = @import("lsp.zig");
pub const diag = @import("diag.zig");
pub const hover = @import("hover.zig");
pub const complete = @import("complete.zig");
pub const diskwatch = @import("diskwatch.zig");
pub const inotify = @import("inotify.zig");
pub const cmdhistory = @import("cmdhistory.zig");
pub const pathmenu = @import("pathmenu.zig");
pub const workspace = @import("workspace.zig");
pub const hangup = @import("hangup.zig");
pub const ext = @import("ext.zig");
pub const extlist = @import("extlist.zig");
pub const fold = @import("fold.zig");

pub const Buffer = buffer.Buffer;
pub const GapBuffer = buffer.GapBuffer;
pub const Pos = buffer.Pos;
pub const Editor = editor.Editor;
pub const Mode = editor.Mode;
pub const Outcome = editor.Outcome;
pub const Tree = tree.Tree;
pub const Finder = finder.Finder;
pub const Ui = ui.Ui;
pub const Target = ui.Target;
