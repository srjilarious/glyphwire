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
//!   `fuzzy`      the subsequence matcher (gw-hist, zoe, salacommander)
//!   `gitignore`  `.gitignore` matching + hidden-file rule (zoe,
//!                salacommander)
//!   `finder`     the fuzzy file finder model (zoe, salacommander)
//!   `filetype`   "is this text?" (zoe, salacommander)

pub const lineedit = @import("lineedit.zig");
pub const keybind = @import("keybind.zig");
pub const shellpanel = @import("shellpanel.zig");
pub const wordsplit = @import("wordsplit.zig");
pub const history = @import("history.zig");
pub const fuzzy = @import("fuzzy.zig");
pub const gitignore = @import("gitignore.zig");
pub const finder = @import("finder.zig");
pub const filetype = @import("filetype.zig");

pub const LineEdit = lineedit.LineEdit;
