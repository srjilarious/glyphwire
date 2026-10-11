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
//!   `keybind`    named actions bound to key chords and typed characters
//!                (salacommander, zoe, gw-read, gwmd, gw-hist, gmux; the
//!                host's chords, as its own module)
//!   `shellpanel` an embedded `gw-shell` panel (salacommander, zoe)
//!   `wordsplit`  shell-style word splitting and quoting (gw-shell,
//!                salacommander)
//!   `history`    the command history file format (gw-shell, gw-hist,
//!                zoe's `:` and `/` lines)
//!   `pathcomplete` filename completion of a typed word (gw-shell's
//!                Tab, zoe's `:` line)
//!   `fsops`      make a directory / file, rename in place
//!                (salacommander, zoe's sidebar)
//!   `trash`      the freedesktop.org trash: move an entry to it
//!                (salacommander's F8; here so zoe's sidebar can offer
//!                the same when it grows a delete)
//!   `homepath`   `~` <-> `$HOME` (gw-shell, zoe), and a typed path
//!                made absolute (gw-ls, gw-grep, gw-read, gwmd,
//!                salacommander, zoe)
//!   `cli`        exit with a message, connect client + listener
//!                (gwmd, gw-read, gw-grep, gw-hist, gmux, salacommander,
//!                zoe, glyphwire-probe)
//!   `splittree`  the binary split tree mirroring a host split tree, and
//!                directional focus between its leaves (gmux, zoe)
//!   `zjump`      the `zj` frecency directory database (gw-shell,
//!                gw-hist --dirs)
//!   `fuzzy`      the subsequence matcher (gw-hist, zoe, salacommander)
//!   `gitignore`  `.gitignore` matching + hidden-file rule (zoe,
//!                salacommander)
//!   `listcursor` a list's pick + scroll (zoe's menus, gw-shell's Tab
//!                picker, gw-hist, `finder`, salacommander's panes; also
//!                glyphwire-host, as its own module)
//!   `walk`       the recursive `.gitignore`-aware directory walk
//!                (`finder`, zoe's `/` tree search)
//!   `finder`     the fuzzy file finder model (zoe, salacommander)
//!   `finderpopup` the framed popup drawn around a `finder` (zoe's
//!                Ctrl+P, salacommander's F3)
//!   `palette`    the Ctrl+Shift+P command palette over a program's
//!                named actions (zoe, salacommander)
//!   `popupframe` the framed, shadowed chrome both popups above are
//!                drawn in
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
//!
//! Three Lua-dependent pieces sit in this directory but are separate
//! build modules, so a program without Lua doesn't link it: `luaconf`
//! (reading and running a `*.conf.lua`, typed field readers; every
//! program with a config), `themeconf` and `dividerconf`.

pub const lineedit = @import("lineedit.zig");
pub const interrupt = @import("interrupt.zig");
pub const keybind = @import("keybind");
pub const shellpanel = @import("shellpanel.zig");
pub const wordsplit = @import("wordsplit.zig");
pub const history = @import("history.zig");
pub const zjump = @import("zjump.zig");
pub const fuzzy = @import("fuzzy.zig");
pub const gitignore = @import("gitignore.zig");
pub const finder = @import("finder.zig");
pub const popupframe = @import("popupframe.zig");
pub const finderpopup = @import("finderpopup.zig");
pub const palette = @import("palette.zig");
pub const filetype = @import("filetype.zig");
pub const entries = @import("entries.zig");
pub const format = @import("format.zig");
pub const gridlayout = @import("gridlayout.zig");
pub const icons = @import("icons.zig");
pub const homepath = @import("homepath.zig");
pub const cli = @import("cli.zig");
pub const splittree = @import("splittree.zig");
pub const walk = @import("walk.zig");
pub const listcursor = @import("listcursor");
pub const fsops = @import("fsops.zig");
pub const trash = @import("trash.zig");
pub const pathcomplete = @import("pathcomplete.zig");
pub const syntax = @import("syntax.zig");
pub const theme = @import("glyphwire").theme;

pub const LineEdit = lineedit.LineEdit;
