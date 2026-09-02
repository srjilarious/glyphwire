//! Pure, dependency-free helpers for glyphwire-shell's prompt: word
//! splitting / alias parsing (`wordsplit`), filename completion
//! (`complete`), glob expansion (`glob`), and captured-child handshake
//! detection (`handshake`). Kept in their own files (no libc, no IO) and
//! gathered here as one module so both `shell/main.zig` and the test
//! runner (`tests/shell_tests.zig`) can import them -- a Zig module can't
//! reach across directories with a relative `@import`.

pub const wordsplit = @import("wordsplit.zig");
pub const complete = @import("complete.zig");
pub const glob = @import("glob.zig");
pub const handshake = @import("handshake.zig");
