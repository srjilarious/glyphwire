// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: GPL-3.0-or-later

//! gw-read's innards, gathered as the `read_support` build module so
//! `tests/read_tests.zig` can reach them -- a Zig module can't cross
//! directories with a relative `@import`, the same reason `ls_support`,
//! `zoe_support` and `host_support` exist.
//!
//! `pages` / `zoom` / `cache` are pure -- no client, no engine, no
//! filesystem -- which is what lets the page ordering, the fit maths and
//! the LRU be tested with nothing but an allocator. `state` and `archive`
//! read files and `ui` speaks the wire protocol; they live here too so
//! the test runner can reach their pure parts, the same arrangement
//! `ls_support` has with `ls/config.zig`.

pub const pages = @import("pages.zig");
pub const zoom = @import("zoom.zig");
pub const cache = @import("cache.zig");
pub const state = @import("state.zig");
pub const config = @import("config.zig");
pub const archive = @import("archive.zig");
pub const mokuro = @import("mokuro.zig");
pub const dict = @import("dict.zig");
pub const ui = @import("ui.zig");

pub const Archive = archive.Archive;
pub const Cache = cache.Cache;
pub const Direction = config.Direction;
pub const Mode = zoom.Mode;
pub const ReadConfig = config.ReadConfig;
pub const Ui = ui.Ui;
