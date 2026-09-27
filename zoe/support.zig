// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: GPL-3.0-or-later

//! zoe's engine-free core, gathered as the `zoe_support` build module so
//! `tests/zoe_tests.zig` can reach it -- a Zig module can't cross
//! directories with a relative `@import`, the same reason `ls_support`
//! and `host_support` exist.
//!
//! `buffer` / `motion` / `editor` / `keys` / `display` / `filetype` are
//! pure -- no client, no engine, no filesystem -- which is what lets the
//! whole editing state machine be tested with nothing but an allocator.
//! `tree` and `finder` read directories and `ui` speaks the wire
//! protocol; they live here too so the test runner can reach their pure
//! parts, the same arrangement `ls_support` has with `ls/config.zig`.

pub const buffer = @import("buffer.zig");
pub const motion = @import("motion.zig");
pub const search = @import("search.zig");
pub const editor = @import("editor.zig");
pub const keys = @import("keys.zig");
pub const display = @import("display.zig");
pub const tree = @import("tree.zig");
pub const finder = @import("shell_support").finder;
pub const gitignore = @import("shell_support").gitignore;
pub const filetype = @import("shell_support").filetype;
pub const ui = @import("ui.zig");
pub const tabs = @import("tabs.zig");
pub const syntax = @import("syntax.zig");
pub const langconf = @import("langconf.zig");
pub const lsp = @import("lsp.zig");
pub const diag = @import("diag.zig");
pub const hover = @import("hover.zig");
pub const complete = @import("complete.zig");

pub const Buffer = buffer.Buffer;
pub const GapBuffer = buffer.GapBuffer;
pub const Pos = buffer.Pos;
pub const Editor = editor.Editor;
pub const Mode = editor.Mode;
pub const Outcome = editor.Outcome;
pub const Tree = tree.Tree;
pub const Finder = finder.Finder;
pub const Ui = ui.Ui;
pub const Target = ui.Target;
