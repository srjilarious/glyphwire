// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: MPL-2.0

//! Windowless pieces of glyphwire-host, re-exported as one module so the
//! test runner (`tests/host_tests.zig`) can exercise them without
//! standing up a window or a GL context. Same cross-directory-module
//! reason as `shell_support` / `ls_support` -- see build.zig. Only
//! modules that import nothing heavier than `std`, `glyphwire` and
//! `host_eng`'s pure types (`key_repeat` names the engine's `Key` enum)
//! belong here -- nothing that needs a live engine to run.

pub const geometry = @import("geometry.zig");
pub const config = @import("config.zig");
pub const system_font = @import("system_font.zig");
pub const key_repeat = @import("key_repeat.zig");
pub const redraw = @import("redraw.zig");
pub const profiler = @import("profiler.zig");
