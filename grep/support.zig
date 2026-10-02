// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: GPL-3.0-or-later

//! gw-grep is an executable, so `tests/` can't `@import` its modules
//! across directories. Its pure halves are re-exported here as the
//! `grep_support` build module, exactly as `ls_support` / `md_support`
//! do -- `main.zig` (the subprocess and the wire calls) stays out.

pub const rg = @import("rg.zig");
pub const nodes = @import("nodes.zig");
