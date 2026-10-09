// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: GPL-3.0-or-later

//! `gmux_support`: layout tree, config, actions, UI. See CONTRIBUTING.md.

pub const layout = @import("layout.zig");
pub const config = @import("config.zig");
pub const actions = @import("actions.zig");
pub const ui = @import("ui.zig");

pub const Tree = layout.Tree;
pub const Axis = layout.Axis;
pub const PaneId = layout.PaneId;
pub const Ui = ui.Ui;
