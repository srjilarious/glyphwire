// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: GPL-3.0-or-later

//! salacommander's pieces, gathered as the `salacommander_support` build
//! module so the `salacommander` binary and the test runner share them --
//! the same cross-directory reason `ls_support` and `read_support` exist.
//! `pane`, `fileops`, `dialog` and `actions` are windowless and tested
//! directly; `ui` is the glyphwire client half; `config` pulls in `ziglua`
//! for `salacommander.conf.lua`.

pub const pane = @import("pane.zig");
pub const fileops = @import("fileops.zig");
pub const dialog = @import("dialog.zig");
pub const actions = @import("actions.zig");
pub const openaction = @import("openaction.zig");
pub const config = @import("config.zig");
pub const ui = @import("ui.zig");

pub const Pane = pane.Pane;
pub const Ui = ui.Ui;
