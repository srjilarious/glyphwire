//! zoe's engine-free core, gathered as the `zoe_support` build module so
//! `tests/zoe_tests.zig` can reach it -- a Zig module can't cross
//! directories with a relative `@import`, the same reason `ls_support`
//! and `host_support` exist.
//!
//! `buffer` / `motion` / `editor` / `keys` are pure -- no client, no
//! engine, no filesystem -- which is what lets the whole editing state
//! machine be tested with nothing but an allocator. `tree` reads
//! directories and `ui` speaks the wire protocol; they live here too so
//! the test runner can reach their pure parts, the same arrangement
//! `ls_support` has with `ls/config.zig`.

pub const buffer = @import("buffer.zig");
pub const motion = @import("motion.zig");
pub const editor = @import("editor.zig");
pub const keys = @import("keys.zig");
pub const tree = @import("tree.zig");
pub const ui = @import("ui.zig");
pub const syntax = @import("syntax.zig");
pub const langconf = @import("langconf.zig");

pub const Buffer = buffer.Buffer;
pub const GapBuffer = buffer.GapBuffer;
pub const Pos = buffer.Pos;
pub const Editor = editor.Editor;
pub const Mode = editor.Mode;
pub const Outcome = editor.Outcome;
pub const Tree = tree.Tree;
pub const Ui = ui.Ui;
