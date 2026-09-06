//! Pure, engine-free pieces of glyphwire-host, re-exported as one module
//! so the test runner (`tests/host_tests.zig`) can exercise them without
//! pulling in SDL / OpenGL. Same cross-directory-module reason as
//! `shell_support` / `ls_support` -- see build.zig. Only modules that
//! import nothing heavier than `std` and `glyphwire` belong here.

pub const geometry = @import("geometry.zig");
pub const config = @import("config.zig");
pub const key_repeat = @import("key_repeat.zig");
pub const redraw = @import("redraw.zig");
