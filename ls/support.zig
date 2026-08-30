//! Pure, dependency-free helpers shared by glyphwire-ls (`ls/main.zig`)
//! and its test runner (`tests/ls_tests.zig`), gathered as the
//! `ls_support` build module -- a Zig module can't reach across
//! directories with a relative `@import`, the same reason `shell_support`
//! exists.

pub const gridlayout = @import("gridlayout.zig");
pub const format = @import("format.zig");
pub const icons = @import("icons.zig");
