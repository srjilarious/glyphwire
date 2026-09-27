// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: GPL-3.0-or-later

//! Helpers shared by glyphwire-ls (`ls/main.zig`) and its test runner
//! (`tests/ls_tests.zig`), gathered as the `ls_support` build module -- a
//! Zig module can't reach across directories with a relative `@import`,
//! the same reason `shell_support` exists. Only `config` is gw-ls's
//! alone; it pulls in `ziglua` to parse `ls.conf.lua`. The scanner, the
//! formatting, the grid packing and the icon lookup are shared with
//! salacommander and zoe, so they live in `applib`.

pub const config = @import("config.zig");
