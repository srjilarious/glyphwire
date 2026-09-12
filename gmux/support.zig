//! gmux's engine-free pieces, gathered as the `gmux_support` build module
//! so `tests/gmux_tests.zig` can reach them -- a Zig module can't cross
//! directories with a relative `@import`, same reason `zoe_support` /
//! `shell_support` / `ls_support` exist.
//!
//! `layout` is pure: no client, no pty, no filesystem -- just the split
//! tree's structure, which is what lets it be tested with nothing but an
//! allocator. `config` speaks Lua but no wire protocol.

pub const layout = @import("layout.zig");
pub const config = @import("config.zig");
pub const ui = @import("ui.zig");

pub const Tree = layout.Tree;
pub const Axis = layout.Axis;
pub const PaneId = layout.PaneId;
pub const Ui = ui.Ui;
