//! zoe's engine-free core, gathered as the `zoe_support` build module so
//! `tests/zoe_tests.zig` can reach it -- a Zig module can't cross
//! directories with a relative `@import`, the same reason `ls_support`
//! and `host_support` exist.
//!
//! Everything here is pure: no glyphwire client, no SDL, no filesystem.
//! `zoe/main.zig` is what wires it to the outside world.

pub const buffer = @import("buffer.zig");
pub const motion = @import("motion.zig");
pub const editor = @import("editor.zig");
pub const keys = @import("keys.zig");

pub const Buffer = buffer.Buffer;
pub const GapBuffer = buffer.GapBuffer;
pub const Pos = buffer.Pos;
pub const Editor = editor.Editor;
pub const Mode = editor.Mode;
pub const Outcome = editor.Outcome;
