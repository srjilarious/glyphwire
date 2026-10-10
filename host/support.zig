// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: MPL-2.0

//! `host_support`: glyphwire-host's windowless pieces. See CONTRIBUTING.md.
//! From `host_eng`, only pure types like `Key`; nothing needing a live engine.

pub const geometry = @import("geometry.zig");
pub const config = @import("config.zig");
pub const config_load = @import("config_load.zig");
pub const dividers = @import("dividers.zig");
pub const window_title = @import("window_title.zig");
pub const system_font = @import("system_font.zig");
pub const emoji = @import("emoji.zig");
pub const key_repeat = @import("key_repeat.zig");
pub const redraw = @import("redraw.zig");
pub const profiler = @import("profiler.zig");
pub const shadow = @import("shadow.zig");
pub const modal_list = @import("modal_list.zig");
