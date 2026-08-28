//! Helpers for glyphwire-shell's prompt, gathered here as one module so
//! both `shell/main.zig` and the test runner (`tests/shell_tests.zig`)
//! can import them -- a Zig module can't reach across directories with a
//! relative `@import`.
//!
//! `wordsplit` / `complete` / `glob` / `handshake` / `history` are pure
//! (no libc, no IO). `config` is the exception: it embeds a Lua state
//! (via ziglua) to run `~/.config/glyphwire/shell.conf`, so this module
//! pulls in ziglua and the test runner links the Lua C library.

pub const wordsplit = @import("wordsplit.zig");
pub const complete = @import("complete.zig");
pub const glob = @import("glob.zig");
pub const handshake = @import("handshake.zig");
pub const history = @import("history.zig");
pub const config = @import("config.zig");
