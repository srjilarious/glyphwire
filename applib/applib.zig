// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: MPL-2.0

//! `applib` -- application-level helpers shared by at least two of the
//! glyphwire programs, gathered as one build module so each program (and
//! the test runner) can import them. A Zig module can't reach across
//! directories with a relative `@import`, which is why these don't just
//! sit in whichever program wrote them first.
//!
//! The bar for living here is "two or more applications use it". Code
//! only one program needs stays in that program's own directory, and
//! the wire protocol, server and client stay in the `glyphwire` library
//! (`src/`) -- `applib` builds on that library's public API and never
//! reaches into its internals.
//!
//! Licensed MPL-2.0 like `src/`, so it may import `glyphwire` but must
//! never import one of the GPL program modules (`shell_support`,
//! `zoe_support`, ...); see CONTRIBUTING.md.
//!
//! What's here, and who shares it:
//!
//!   `lineedit`   the one-line text field (gw-shell, salacommander, zoe)
//!   `keybind`    named actions bound to key chords (salacommander, zoe)
//!   `shellpanel` an embedded `gw-shell` panel (salacommander, zoe)
//!   `wordsplit`  shell-style word splitting and quoting (gw-shell,
//!                salacommander)
//!   `history`    the shared command history file (gw-shell, gw-hist)
//!   `zjump`      the `zj` frecency directory database (gw-shell,
//!                gw-hist --dirs)
//!   `fuzzy`      the subsequence matcher (gw-hist, zoe, salacommander)
//!   `gitignore`  `.gitignore` matching + hidden-file rule (zoe,
//!                salacommander)
//!   `finder`     the fuzzy file finder model (zoe, salacommander)
//!   `finderpopup` the framed popup drawn around a `finder` (zoe's
//!                Ctrl+P, salacommander's F3)
//!   `filetype`   "is this text?" (zoe, salacommander)
//!   `entries`    directory scanning and per-entry classification
//!                (gw-ls, salacommander)
//!   `format`     ls-style size / permission / date formatting (gw-ls,
//!                salacommander)
//!   `gridlayout` column-major grid packing (gw-ls, salacommander)
//!   `icons`      file name -> icon name (gw-ls, salacommander, zoe)
//!   `interrupt`  keeping Ctrl+C from killing an interactive program
//!                (zoe, gw-hist, salacommander, gmux)
//!   `syntax`     tree-sitter highlighting: grammar registry, theme,
//!                per-line colour spans (zoe, gw-grep)
//!   `theme`      the built-in colour themes and resolving a config's
//!                own (zoe, gw-grep); the Lua half is the separate
//!                `themeconf` module, see applib/themeconf.zig

pub const lineedit = @import("lineedit.zig");
pub const interrupt = @import("interrupt.zig");
pub const keybind = @import("keybind.zig");
pub const shellpanel = @import("shellpanel.zig");
pub const wordsplit = @import("wordsplit.zig");
pub const history = @import("history.zig");
pub const zjump = @import("zjump.zig");
pub const fuzzy = @import("fuzzy.zig");
pub const gitignore = @import("gitignore.zig");
pub const finder = @import("finder.zig");
pub const finderpopup = @import("finderpopup.zig");
pub const filetype = @import("filetype.zig");
pub const entries = @import("entries.zig");
pub const format = @import("format.zig");
pub const gridlayout = @import("gridlayout.zig");
pub const icons = @import("icons.zig");
pub const homepath = @import("homepath.zig");
pub const syntax = @import("syntax.zig");
pub const theme = @import("glyphwire").theme;

pub const LineEdit = lineedit.LineEdit;
