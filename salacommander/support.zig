// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: GPL-3.0-or-later

//! `salacommander_support`: panes, fileops, UI. See CONTRIBUTING.md.

pub const pane = @import("pane.zig");
pub const dirhistory = @import("dirhistory.zig");
pub const fileops = @import("fileops.zig");
pub const dialog = @import("dialog.zig");
pub const actions = @import("actions.zig");
pub const openaction = @import("openaction.zig");
pub const config = @import("config.zig");
pub const drag = @import("drag.zig");
pub const tabs = @import("tabs.zig");
pub const sudo = @import("sudo.zig");
pub const attrs = @import("attrs.zig");
pub const form = @import("form.zig");
pub const attrdialog = @import("attrdialog.zig");
pub const ui = @import("ui.zig");

pub const Pane = pane.Pane;
pub const Ui = ui.Ui;
