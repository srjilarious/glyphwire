//! Helpers shared by glyphwire-ls (`ls/main.zig`) and its test runner
//! (`tests/ls_tests.zig`), gathered as the `ls_support` build module -- a
//! Zig module can't reach across directories with a relative `@import`,
//! the same reason `shell_support` exists. `gridlayout` / `format` /
//! `icons` are pure; `config` pulls in `ziglua` to parse `ls.conf` (same
//! as `shell_support`'s `shell/config.zig`).

pub const gridlayout = @import("gridlayout.zig");
pub const format = @import("format.zig");
pub const icons = @import("icons.zig");
pub const config = @import("config.zig");
