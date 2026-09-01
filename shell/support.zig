//! Pure, dependency-free helpers for glyphwire-shell's prompt: word
//! splitting / alias parsing (`wordsplit`), and later filename completion
//! and glob expansion. Kept in their own files (no libc, no IO) and
//! gathered here as one module so both `shell/main.zig` and the test
//! runner (`tests/shell_tests.zig`) can import them -- a Zig module can't
//! reach across directories with a relative `@import`.

pub const wordsplit = @import("wordsplit.zig");
