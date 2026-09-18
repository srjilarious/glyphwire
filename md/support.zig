// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: GPL-3.0-or-later

//! gwmd's innards, gathered as the `md_support` build module so
//! `tests/md_tests.zig` can reach them -- a Zig module can't cross
//! directories with a relative `@import`, the same reason `read_support`
//! and `ls_support` exist.
//!
//! `layout` and `nav` are pure; `ui` speaks the wire protocol. The
//! Markdown parser itself is the vendored zmd fork under `libs/zmd/`,
//! re-exported here as `zmd`.

pub const zmd = @import("zmd");
pub const layout = @import("layout.zig");
pub const nav = @import("nav.zig");
pub const ui = @import("ui.zig");

pub const Document = zmd.Document;
pub const Layout = layout.Layout;
pub const Ui = ui.Ui;
