// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: GPL-3.0-or-later

//! `read_support`: gw-read's testable pieces. See CONTRIBUTING.md.

pub const pages = @import("pages.zig");
pub const zoom = @import("glyphwire").zoom;
pub const cache = @import("cache.zig");
pub const state = @import("state.zig");
pub const config = @import("config.zig");
pub const actions = @import("actions.zig");
pub const archive = @import("archive.zig");
pub const mokuro = @import("mokuro.zig");
pub const place = @import("place.zig");
pub const dict = @import("dict.zig");
pub const kana = @import("kana.zig");
pub const ai = @import("ai.zig");
pub const ai_cache = @import("ai_cache.zig");
pub const anki = @import("anki.zig");
pub const crop = @import("crop.zig");
pub const ui = @import("ui.zig");

pub const Archive = archive.Archive;
pub const Cache = cache.Cache;
pub const Direction = config.Direction;
pub const Mode = zoom.Mode;
pub const ReadConfig = config.ReadConfig;
pub const Ui = ui.Ui;
