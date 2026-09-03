//! Helpers for glyphwire-shell's prompt, gathered here as one module so
//! both `shell/main.zig` and the test runner (`tests/shell_tests.zig`)
//! can import them -- a Zig module can't reach across directories with a
//! relative `@import`.
//!
//! `wordsplit` / `complete` / `glob` / `handshake` / `history` /
//! `lineedit` / `prompt_template` are pure (no libc, no IO). `config` and
//! `script_engine` are the exceptions: they embed a Lua state (via
//! ziglua) -- `config` for a one-shot `shell.conf` parse, `script_engine`
//! for the shell's session-long interpreter -- so this module pulls in
//! ziglua and the test runner links the Lua C library.

pub const wordsplit = @import("wordsplit.zig");
pub const complete = @import("complete.zig");
pub const glob = @import("glob.zig");
pub const handshake = @import("handshake.zig");
pub const history = @import("history.zig");
pub const lineedit = @import("lineedit.zig");
pub const config = @import("config.zig");
pub const script_engine = @import("script_engine.zig");
pub const keyencode = @import("glyphwire").key_encode;
pub const pty = @import("glyphwire").pty;
pub const prompt_template = @import("prompt_template.zig");
pub const browsescroll = @import("browsescroll.zig");
pub const openaction = @import("openaction.zig");
