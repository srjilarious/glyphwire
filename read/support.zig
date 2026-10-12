// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: GPL-3.0-or-later

//! `read_support`: gw-read's testable pieces. See CONTRIBUTING.md.
//!
//! The reading core (archives, pages, mokuro, kana, dictionaries, the
//! Anki crop and note, the AI prompt and reply) is gw-yomi's, shared with
//! the wns-reader Android app; it is re-exported here under the names
//! gw-read has always used. `mokuro`, `ai` and `anki` are gw-read's own
//! thin modules over gw-yomi's, adding the cell-width helpers and the
//! network jobs.

const gw_yomi = @import("gw_yomi");

pub const pages = gw_yomi.pages;
pub const zoom = @import("glyphwire").zoom;
pub const cache = @import("cache.zig");
pub const state = @import("state.zig");
pub const config = @import("config.zig");
pub const actions = @import("actions.zig");
pub const archive = gw_yomi.archive;
pub const mokuro = @import("mokuro.zig");
pub const place = @import("place.zig");
pub const dict = gw_yomi.dict;
pub const kana = gw_yomi.kana;
pub const ai = @import("ai.zig");
pub const ai_cache = gw_yomi.ai_cache;
pub const anki = @import("anki.zig");
pub const crop = gw_yomi.crop;
pub const ui = @import("ui.zig");

pub const Archive = archive.Archive;
pub const Cache = cache.Cache;
pub const Direction = config.Direction;
pub const Mode = zoom.Mode;
pub const ReadConfig = config.ReadConfig;
pub const Ui = ui.Ui;
