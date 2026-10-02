// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: GPL-3.0-or-later

//! zoe's modal editing state machine: the buffer, the cursor, the mode,
//! and the pending-command state that turns a stream of keystrokes into
//! edits.
//!
//! **Input arrives the way glyphwire delivers it**, as two streams rather
//! than one: `feedText` takes committed text (post-layout, post-dead-key,
//! post-IME -- glyphwire's `text` notification) and `feedKey` takes named
//! physical keys (`"escape"`, `"backspace"`, `"left"`, ... -- the
//! `key_down` notification). That split is not an accident of the
//! protocol; it is exactly what a modal editor wants. Normal-mode
//! commands *are* characters, so dispatching them off `text` makes `j`
//! mean "down" on Dvorak and AZERTY too, while Escape and the arrows have
//! no character to carry them and come through as keys. See decisions.md's
//! Input model.
//!
//! **This module does no IO.** `:w` doesn't write a file; it returns an
//! `Outcome.write` and the host does the writing, then calls `markSaved`.
//! That keeps the whole state machine testable with nothing but an
//! allocator, and keeps the eventual Lua command layer honest -- a script
//! that runs `:w` goes through the same outcome the keystroke does.

const std = @import("std");
const glyphwire = @import("glyphwire");
const buffer = @import("buffer.zig");
const motion = @import("motion.zig");
const display = @import("display.zig");
const search = @import("search.zig");

const Buffer = buffer.Buffer;
const Pos = buffer.Pos;

/// The modes this cut implements. vim's "command mode" is what everyone
/// calls normal mode; `command` here is the `:` command *line*, which is
/// its own mode in vim too (cmdline-mode). `visual` and `visual_line` are
/// vim's charwise and linewise visual selection modes.
///
/// Replace mode and operator-pending-as-a-mode are not modelled:
/// operator-pending is a field on `Editor` rather than a mode because
/// nothing outside the state machine needs to see it. Block/column visual
/// mode is deliberately left out -- it doubles every yank/cut/paste case
/// for a rare need, the same reason the wire's selection is linear-only
/// (see decisions.md's Selection & clipboard section).
/// `search` is the `/` and `?` prompt. It is a separate mode from
/// `command` rather than a flag on it because the two do opposite things
/// with what you type: a `:` line is inert until Enter, while a `/` line
/// moves the cursor on every keystroke (vim's `incsearch`) and Escape has
/// to put it back.
pub const Mode = enum { normal, insert, command, visual, visual_line, search };

/// Ceiling on `tab_width`, so an expanding Tab can build its run of
/// spaces on the stack and a nonsense `:set tabwidth=9999` can't make one
/// keystroke insert a screenful.
pub const max_tab_width: usize = 16;

/// The buffer-pane line-number gutter. `zoe/ui.zig` draws it; the core
/// only carries the setting so `:set lineno=…` can change it at runtime.
/// `off` hides the gutter, `absolute` numbers every line from 1,
/// `relative` shows each line's distance from the caret with the caret's
/// own line still absolute. Defaults to `absolute`; `zoe.conf.lua`'s
/// `line_numbers` overrides it after `init`, the way `page_lines` does.
pub const LineNumbers = enum { off, absolute, relative };

/// Which way a search runs. `/` and `*` are forward, `?` and `#` back;
/// `n` repeats the stored direction and `N` inverts it.
pub const SearchDir = enum {
    forward,
    backward,

    pub fn flipped(self: SearchDir) SearchDir {
        return if (self == .forward) .backward else .forward;
    }
};

/// Modifier state accompanying a `feedKey` call -- glyphwire's own, so
/// it can be handed straight to the shared `LineEdit` the `:` line is.
pub const Mods = glyphwire.Mods;

/// What the host must do on zoe's behalf, since the editor itself does no
/// IO. Returned by every `feed*` call; `.none` for the overwhelming
/// majority of keystrokes.
pub const Outcome = union(enum) {
    none,
    /// `:w [path]` -- write the buffer out. A null path means "the file
    /// it was opened from" (`Editor.path`). A non-null path borrows
    /// `Editor.cmd_arg` and stays valid until the next input is fed.
    write: ?[]const u8,
    /// The editor yanked or deleted text and it should go on the system
    /// clipboard -- an explicit `y` (visual mode, or the `y` operator), a
    /// visual-mode `d`/`x`/`c`, or any normal-mode delete (`x`, `dd`,
    /// `dw`, `D`, `C`, `s`), matching vim's unnamed register so `dd` then
    /// `p` works. Borrows `Editor.yank` and stays valid until the next
    /// input is fed. The editor does no IO; `zoe/ui.zig` makes the wire
    /// `set_clipboard` call.
    set_clipboard: []const u8,
    /// `p` / `P` (and the Ctrl+Shift+P chord) -- paste the system
    /// clipboard. The editor can't read the clipboard itself (that is a
    /// wire round-trip), so the host fetches it and hands the text back
    /// via `Editor.putText`. `after` is `p` (below the line / after the
    /// cursor) vs `P` (above / at the cursor).
    paste: struct { after: bool },
    /// `:q` / `:q!`. `force` is the `!` form, which abandons unsaved
    /// changes; a plain `:q` on a modified buffer never gets this far
    /// (the editor reports E37 and returns `.none` instead).
    quit: struct { force: bool },
    /// `:wq` / `:x` -- write, then quit if the write succeeded.
    write_quit: ?[]const u8,
    /// `:e <path>` -- replace the buffer with that file. Borrows
    /// `Editor.cmd_arg` like `write` does. A bare `:e` (reload the
    /// current file) carries null.
    edit: ?[]const u8,
    /// `:cd [dir]` -- change the working directory. `null` means
    /// `$HOME`, `"-"` the previous directory, anything else the target
    /// path (borrows `Editor.cmd_arg`, valid until the next input). The
    /// host does the `chdir` and re-roots the file tree; the editor
    /// core has no cwd of its own.
    chdir: ?[]const u8,
    /// `:pwd` -- show the working directory on the status line. The
    /// editor doesn't know it, so the host fills the message in.
    pwd,
    /// `:bn` / `:bp` -- move to the next / previous open buffer. An
    /// `Editor` *is* one buffer and knows nothing about the others, so
    /// the list lives in `zoe/ui.zig` and these just name the direction.
    buffer_step: struct { forward: bool },
    /// `:bd` / `:bd!` -- close this buffer. `force` is the `!` form; a
    /// plain `:bd` on a modified buffer never gets this far (E37, the
    /// same guard `:q` uses).
    buffer_close: struct { force: bool },
    /// `:vsplit [path]` / `:split [path]` -- a new editor group beside
    /// (`vertical`) or under this one. `path` borrows `Editor.cmd_arg`
    /// like `edit` does; null moves the current buffer into the new
    /// group. Groups are a `zoe/ui.zig` thing, the same way the buffer
    /// list is.
    split: struct { vertical: bool, path: ?[]const u8 },
    /// `:close` -- close this editor group, its tabs moving to the
    /// neighbour that takes its space.
    close_group,
    /// `K` -- ask a language server what is under the cursor. The editor
    /// has no idea; `zoe/ui.zig` owns the servers and puts the answer in a
    /// popup when it arrives. Named for what was asked, not for what will
    /// happen, because the request may well come back empty.
    lsp_hover,
    /// `gd` -- jump to the definition of whatever is under the cursor.
    /// Same division of labour as `lsp_hover`: the request and the jump
    /// (and pushing the jumplist entry to come back to) are the host's.
    lsp_definition,
    /// `]d` / `[d` -- move the cursor to the next / previous diagnostic in
    /// this buffer. The diagnostics live in `zoe/diag.zig`, which the
    /// editor core can't see, so it only names the direction -- exactly
    /// the arrangement `buffer_step` already has with the buffer list.
    diag_step: struct { forward: bool },
    /// `:lsp [restart]` -- report (or restart) the language servers.
    lsp_status: ?[]const u8,
    /// `:diag` -- list this buffer's diagnostics.
    diag_list,
    /// `:theme [name]` -- switch the colour theme, or (bare) report the
    /// current one. Themes are `zoe/ui.zig`'s, like the language servers:
    /// the editor core paints nothing. Borrows `Editor.cmd_arg`.
    theme: ?[]const u8,
};

pub const Editor = struct {
    alloc: std.mem.Allocator,
    buf: Buffer,
    /// Byte offset into the buffer. Normal mode keeps this on a
    /// character; insert mode may sit one past the line's last one.
    cursor: usize = 0,
    /// The byte column `j`/`k` try to return to, so walking down through
    /// a short line and out the other side lands back where it started.
    /// Updated by every horizontal motion, left alone by vertical ones.
    sticky_col: usize = 0,
    mode: Mode = .normal,

    /// Count typed so far in normal mode (`3` in `3dd`). 0 means none.
    count: usize = 0,
    /// A pending operator waiting for its motion -- only `d` today.
    operator: ?u8 = null,
    /// The count that was typed *before* the operator; multiplied with
    /// the motion's own count the way vim does (`2d3w` deletes 6 words).
    operator_count: usize = 0,
    /// A pending single-character prefix -- only `g` today (`gg`).
    prefix: ?u8 = null,

    /// The fixed end of a visual-mode selection, as a byte offset. Set
    /// when `v` / `V` (or a mouse drag) starts a selection, null the rest
    /// of the time. The moving end is always `cursor`, so the selection is
    /// `[min, max]` of the two -- see `selectionSpan`.
    select_anchor: ?usize = null,

    /// The selection the last visual mode ended with, so `gv` can put it
    /// back. Recorded by `exitVisual`, which every way out of visual mode
    /// goes through -- including the operators, so a `gv` right after a
    /// `d` reselects a range whose text has changed. vim's `gv` is no
    /// better behaved there; both ends are clamped on the way back in.
    last_visual: ?struct { anchor: usize, cursor: usize, mode: Mode } = null,

    /// Lines a PageDown / PageUp (or Ctrl-D / Ctrl-U) moves the cursor.
    /// vim scrolls close to a full screen, but the editor core has no
    /// viewport to measure, so this is a fixed count -- overridable from
    /// `zoe.conf.lua`'s `page_lines`, which the host writes here after
    /// `init`.
    page_lines: usize = 10,

    /// The buffer-pane line-number gutter -- see `LineNumbers`. Set from
    /// `zoe.conf.lua`'s `line_numbers` after `init`, changed live by
    /// `:set lineno=…`.
    line_numbers: LineNumbers = .absolute,

    /// Cells between tab stops: how wide a `\t` already in the file
    /// renders, and the grid an expanding Tab key indents onto. vim's
    /// `tabstop`, `zoe.conf`'s `tab_width`, `:set tabwidth=…`.
    tab_width: usize = 4,
    /// Whether the Tab key inserts spaces out to the next tab stop
    /// rather than a literal `\t`. vim's `expandtab`, and on by default
    /// here because every file in this tree is space-indented.
    /// `zoe.conf`'s `expand_tab`, `:set expandtab=…`.
    expand_tab: bool = true,
    /// Whether the buffer pane marks whitespace -- a faint dot on each
    /// space, a faint arrow on each tab. Off by default. `zoe.conf`'s
    /// `show_whitespace`, `:set whitespace=…`. Like `line_numbers` this
    /// is pure display -- the core only carries it so `:set` has
    /// somewhere to put it.
    show_whitespace: bool = false,

    /// The `:` line being typed, without the leading colon -- the same
    /// one-line field gw-shell's prompt and salacommander's path row use,
    /// so a long `:e some/deep/path` is editable rather than
    /// backspace-only. `.drop` (the default) because a `:` line is one
    /// command: a pasted newline is a mistake, not a separator.
    cmdline: @import("applib").LineEdit = .{},
    /// The argument of the command just run, kept alive so an `Outcome`
    /// can borrow it (see `Outcome.write`).
    cmd_arg: std.ArrayList(u8) = .empty,
    /// The message shown on the status line -- errors, `:w` confirmation.
    status: std.ArrayList(u8) = .empty,
    /// The text of the last yank or delete, kept alive so an
    /// `Outcome.set_clipboard` can borrow it (see that variant). vim's
    /// unnamed register, except the real register is the system clipboard
    /// and `zoe/ui.zig` puts it there.
    yank: std.ArrayList(u8) = .empty,
    /// A command in the current input filled `self.yank` and it should
    /// reach the clipboard. Consumed at the end of `feedText` / `feedKey`
    /// (as one `Outcome.set_clipboard`) rather than returned mid-command,
    /// so a change command like `s` / `c` doesn't abort the "type the
    /// rest of the chunk" loop.
    yank_pending: bool = false,
    /// The file this buffer came from, owned. Null for a scratch buffer.
    path: ?[]u8 = null,

    /// The pattern of the most recent search, owned. Kept after the
    /// prompt closes so `n` / `N` have something to repeat, and cleared
    /// by nothing -- vim's search register survives everything short of
    /// a new search.
    search_pat: std.ArrayList(u8) = .empty,
    /// Which way the last `/` / `?` (or `*` / `#`) went. `n` repeats it,
    /// `N` reverses it.
    search_dir: SearchDir = .forward,
    /// The last search asked for whole-word matches -- set by `*` / `#`,
    /// cleared by a typed `/` or `?`. See `search.zig`'s `whole_word`.
    search_word: bool = false,
    /// Whether matches are highlighted. On from the moment a search runs,
    /// off again at `:noh`. vim's `hlsearch`, except it is a state rather
    /// than an option because zoe has no `:set hlsearch` to turn off.
    search_hl: bool = false,
    /// Where the cursor was when the `/` prompt opened, so Escape can put
    /// it back after incremental search has been dragging it around.
    search_origin: usize = 0,
    /// The mode to return to when the prompt closes. `/` from visual mode
    /// keeps the selection and extends it to the match, which is why this
    /// is a mode rather than a bool.
    search_return: Mode = .normal,
    /// Where the current match starts, when there is one. `ui.zig` paints
    /// it in a stronger colour than the other matches, the way vim does.
    search_match: ?usize = null,
    /// The pattern on the open `/` line matches nothing, so the prompt
    /// draws in the error colour while you keep typing.
    search_failed: bool = false,

    /// `r` was typed and is waiting for the character to replace with.
    /// The count came with it (`3rx`), so it is stashed here too.
    pending_replace: ?usize = null,

    /// The command just run is only half of one edit and the host is
    /// about to finish it (a visual-mode `p`: the selection has gone, the
    /// clipboard text has not arrived yet). Keeps the undo group open
    /// across the round trip so `u` puts both halves back at once.
    undo_join_next: bool = false,

    pub fn init(alloc: std.mem.Allocator) !Editor {
        return .{ .alloc = alloc, .buf = try Buffer.init(alloc) };
    }

    /// `text` is copied into the buffer; `path` (if given) is duped.
    pub fn initFromText(alloc: std.mem.Allocator, text: []const u8, path: ?[]const u8) !Editor {
        var self: Editor = .{ .alloc = alloc, .buf = try Buffer.initFromText(alloc, text) };
        errdefer self.buf.deinit();
        if (path) |p| self.path = try alloc.dupe(u8, p);
        return self;
    }

    pub fn deinit(self: *Editor) void {
        self.buf.deinit();
        self.cmdline.deinit(self.alloc);
        self.cmd_arg.deinit(self.alloc);
        self.status.deinit(self.alloc);
        self.yank.deinit(self.alloc);
        self.search_pat.deinit(self.alloc);
        if (self.path) |p| self.alloc.free(p);
        self.* = undefined;
    }

    /// The cursor as a line/column pair -- what a status line shows and
    /// what the renderer will place the caret from.
    pub fn pos(self: *const Editor) Pos {
        return self.buf.posOf(self.cursor);
    }

    /// Called by the host after an `Outcome.write` actually landed on
    /// disk, so `:q` stops complaining.
    pub fn markSaved(self: *Editor) void {
        self.buf.markClean();
    }

    pub fn setStatus(self: *Editor, comptime fmt: []const u8, args: anytype) void {
        self.status.clearRetainingCapacity();
        // A status line that can't allocate is not worth failing an edit
        // over -- the message is dropped and the edit stands.
        const msg = std.fmt.allocPrint(self.alloc, fmt, args) catch return;
        defer self.alloc.free(msg);
        self.status.appendSlice(self.alloc, msg) catch {};
    }

    /// Replaces the buffer's contents and its path, resetting the cursor
    /// and the modified flag -- `:e`, and opening a file from the tree.
    /// The caller has already read the bytes; this does no IO, same as
    /// everything else here.
    pub fn loadText(self: *Editor, text: []const u8, path: ?[]const u8) !void {
        var fresh = try Buffer.initFromText(self.alloc, text);
        errdefer fresh.deinit();
        if (path) |p| try self.setPath(p);

        self.buf.deinit();
        self.buf = fresh;
        self.cursor = 0;
        self.sticky_col = 0;
        self.mode = .normal;
        self.resetPending();
        // The pattern survives -- it is session state, like vim's search
        // register -- but everything that points *into* the old text does
        // not, and neither does the undo history for a file that is gone.
        self.search_match = null;
        self.search_hl = false;
        self.search_origin = 0;
    }

    /// Replaces `path` with a copy of `new_path` -- what `:w <name>` does
    /// once the host has written it.
    pub fn setPath(self: *Editor, new_path: []const u8) !void {
        const owned = try self.alloc.dupe(u8, new_path);
        if (self.path) |p| self.alloc.free(p);
        self.path = owned;
    }

    // ── Input ───────────────────────────────────────────────────────────

    /// Committed text (glyphwire's `text` notification). In insert and
    /// command mode the whole chunk is taken at once, which is what makes
    /// a paste one edit; in normal mode it is dispatched one codepoint at
    /// a time, since each is its own command.
    pub fn feedText(self: *Editor, text: []const u8) !Outcome {
        self.yank_pending = false;
        defer self.settleUndo();
        var rest = text;
        while (rest.len > 0) {
            switch (self.mode) {
                .insert => {
                    try self.insertText(rest);
                    return self.takeYankPending();
                },
                .command => {
                    _ = try self.cmdline.insert(self.alloc, rest);
                    return self.takeYankPending();
                },
                // The `/` line moves the cursor on every keystroke, so
                // the whole chunk goes in and the search is re-run once.
                .search => {
                    _ = try self.cmdline.insert(self.alloc, rest);
                    self.incrementalSearch();
                    return self.takeYankPending();
                },
                .normal, .visual, .visual_line => {
                    // One codepoint at a time, re-checking the mode each
                    // round: a command in the middle of a chunk can switch
                    // modes (`ihello` is `i` plus five characters of text),
                    // and the remainder must then be typed, not obeyed.
                    // Visual mode dispatches the same way -- `vjjd` is four
                    // separate commands.
                    const view = std.unicode.Utf8View.init(rest) catch return self.takeYankPending();
                    var it = view.iterator();
                    const cp = it.nextCodepointSlice() orelse return self.takeYankPending();
                    const outcome = if (self.mode == .normal)
                        try self.normalChar(cp)
                    else
                        try self.visualChar(cp);
                    switch (outcome) {
                        .none => {},
                        // A real outcome (`.paste`) ends the chunk; a
                        // pending yank on the same chunk is dropped, which
                        // only a `y`/`d` immediately followed by `p` in one
                        // burst could hit.
                        else => |o| return o,
                    }
                    rest = rest[cp.len..];
                },
            }
        }
        return self.takeYankPending();
    }

    /// The clipboard outcome for a yank/delete deferred during this
    /// input, consumed once. `.none` when nothing was yanked.
    fn takeYankPending(self: *Editor) Outcome {
        if (!self.yank_pending) return .none;
        self.yank_pending = false;
        if (self.yank.items.len == 0) return .none;
        return .{ .set_clipboard = self.yank.items };
    }

    /// A named physical key (glyphwire's `key_down` notification). Only
    /// the keys with no character to carry them are handled here --
    /// everything printable arrives through `feedText`.
    pub fn feedKey(self: *Editor, key: []const u8, mods: Mods) !Outcome {
        self.yank_pending = false;
        defer self.settleUndo();
        const eq = std.mem.eql;
        if (eq(u8, key, "escape")) {
            self.escape();
            return .none;
        }

        switch (self.mode) {
            // Visual mode moves the same way normal mode does; only the
            // moving end (`cursor`) changes, the anchor stays put, and the
            // selection is recomputed from the two (`selectionSpan`).
            .normal, .visual, .visual_line => {
                // PageDown/PageUp, and vim's Ctrl-D / Ctrl-U half-page
                // keys, all move by `page_lines`. The Ctrl forms are
                // normal-mode only, leaving insert-mode Ctrl-U/D free
                // for their vim meanings if zoe grows them later.
                // Ctrl+R is redo -- the one vim chord with no printable
                // character to carry it, so it has to be caught here.
                if (mods.ctrl and eq(u8, key, "r")) return self.redo();
                if (eq(u8, key, "page_down") or (mods.ctrl and eq(u8, key, "d"))) {
                    self.pageMove(.down, false);
                    return .none;
                }
                if (eq(u8, key, "page_up") or (mods.ctrl and eq(u8, key, "u"))) {
                    self.pageMove(.up, false);
                    return .none;
                }
                if (eq(u8, key, "left")) {
                    self.moveTo(motion.left(&self.buf, self.cursor, 1), true);
                } else if (eq(u8, key, "right")) {
                    self.moveTo(motion.right(&self.buf, self.cursor, 1, false), true);
                } else if (eq(u8, key, "up")) {
                    self.moveTo(motion.up(&self.buf, self.cursor, 1, self.sticky_col, false), false);
                } else if (eq(u8, key, "down")) {
                    self.moveTo(motion.down(&self.buf, self.cursor, 1, self.sticky_col, false), false);
                } else if (eq(u8, key, "home")) {
                    self.moveTo(motion.lineStart(&self.buf, self.cursor), true);
                } else if (eq(u8, key, "end")) {
                    self.moveTo(motion.lineEnd(&self.buf, self.cursor, false), true);
                }
                return .none;
            },
            .insert => {
                if (eq(u8, key, "page_down")) {
                    self.pageMove(.down, true);
                } else if (eq(u8, key, "page_up")) {
                    self.pageMove(.up, true);
                } else if (eq(u8, key, "enter")) {
                    try self.insertText("\n");
                } else if (eq(u8, key, "tab")) {
                    try self.insertTab();
                } else if (eq(u8, key, "backspace")) {
                    try self.backspace();
                } else if (eq(u8, key, "delete")) {
                    try self.deleteForward();
                } else if (mods.ctrl and eq(u8, key, "left")) {
                    // vim's insert-mode <C-Left>/<C-Right>: the `b` / `w`
                    // motions, crossing lines like they do.
                    self.moveTo(motion.wordBackward(&self.buf, self.cursor, 1, false), true);
                } else if (mods.ctrl and eq(u8, key, "right")) {
                    self.moveTo(motion.wordForward(&self.buf, self.cursor, 1, false), true);
                } else if (mods.ctrl and eq(u8, key, "home")) {
                    self.moveTo(0, true);
                } else if (mods.ctrl and eq(u8, key, "end")) {
                    // Past the last character, so typing appends to the file.
                    self.moveTo(self.buf.len(), true);
                } else if (eq(u8, key, "left")) {
                    self.moveTo(motion.left(&self.buf, self.cursor, 1), true);
                } else if (eq(u8, key, "right")) {
                    self.moveTo(motion.right(&self.buf, self.cursor, 1, true), true);
                } else if (eq(u8, key, "up")) {
                    self.moveTo(motion.up(&self.buf, self.cursor, 1, self.sticky_col, true), false);
                } else if (eq(u8, key, "down")) {
                    self.moveTo(motion.down(&self.buf, self.cursor, 1, self.sticky_col, true), false);
                } else if (eq(u8, key, "home")) {
                    self.moveTo(motion.lineStart(&self.buf, self.cursor), true);
                } else if (eq(u8, key, "end")) {
                    self.moveTo(motion.lineEnd(&self.buf, self.cursor, true), true);
                }
                return .none;
            },
            .command => {
                // Backspacing over the `:` itself leaves the mode, same
                // as vim -- tested before the field sees the key, since
                // to the field an empty line is simply nothing to delete.
                if (eq(u8, key, "backspace") and self.cmdline.isEmpty()) {
                    self.mode = .normal;
                    return .none;
                }
                // Everything else the shared field knows is the field's:
                // Home/Ctrl+A, End/Ctrl+E, Ctrl+Left/Right over the path
                // segments of a `:e`, Ctrl+Backspace, Ctrl+U, Ctrl+K.
                switch (self.cmdline.handleKey(key, mods)) {
                    .submit => return self.runCommand(),
                    .moved, .edited, .ignored => return .none,
                    // Escape is `escape`'s below, which also clears the
                    // line; it never reaches here.
                    .cancel => return .none,
                }
            },
            .search => {
                // Backspacing the `/` away leaves the prompt, same rule
                // the `:` line has -- and the cursor goes back where it
                // started, since incremental search has been moving it.
                if (eq(u8, key, "backspace") and self.cmdline.isEmpty()) {
                    self.leaveSearch(.restore);
                    return .none;
                }
                switch (self.cmdline.handleKey(key, mods)) {
                    .submit => {
                        try self.commitSearch();
                        return .none;
                    },
                    // Any edit re-runs the search from the origin: the
                    // `incsearch` preview must not walk forward one match
                    // per keystroke.
                    .edited => {
                        self.incrementalSearch();
                        return .none;
                    },
                    .moved, .ignored, .cancel => return .none,
                }
            },
        }
    }

    /// Closes the open undo group unless the command in progress means to
    /// keep collecting into it: an insert-mode session is one `u`, and so
    /// is the delete-then-paste pair a visual-mode `p` turns into.
    fn settleUndo(self: *Editor) void {
        if (self.mode == .insert or self.undo_join_next) return;
        self.buf.closeUndoGroup();
    }

    /// Escape: leave insert or command mode. In insert mode the cursor
    /// steps back onto the character it was after, which is vim's
    /// behavior and the reason `A<esc>` leaves you on the last character
    /// rather than past it.
    fn escape(self: *Editor) void {
        switch (self.mode) {
            .normal => self.resetPending(),
            .insert => {
                self.mode = .normal;
                self.moveTo(motion.clampNormal(&self.buf, motion.left(&self.buf, self.cursor, 1)), true);
            },
            .command => {
                self.mode = .normal;
                self.cmdline.clear();
            },
            .search => self.leaveSearch(.restore),
            .visual, .visual_line => self.exitVisual(),
        }
    }

    fn resetPending(self: *Editor) void {
        self.count = 0;
        self.operator = null;
        self.operator_count = 0;
        self.prefix = null;
        self.pending_replace = null;
    }

    /// Puts the cursor at a byte offset, clamped into the buffer and onto a
    /// character boundary in normal mode -- for a jump decided outside the
    /// editor core: a language server's `gd` target, a diagnostic's position,
    /// a jumplist entry (see `zoe/ui.zig`).
    pub fn setCursor(self: *Editor, offset: usize) void {
        self.moveTo(motion.clampNormal(&self.buf, @min(offset, self.buf.len())), true);
    }

    /// `zoe --line N`: the cursor onto 1-based line `line`'s first
    /// non-blank, clamped to the last line -- where `:N` lands.
    pub fn gotoStartLine(self: *Editor, line: usize) void {
        self.setCursor(motion.gotoLine(&self.buf, line -| 1));
    }

    /// Accepting a completion: replaces `[start, cursor)` with `text` and
    /// leaves the cursor after it. Insert mode only, and part of the insert
    /// session's undo group -- the word typed and the completion that
    /// finished it are one `u`, the same as if it had all been typed.
    pub fn replaceBeforeCursor(self: *Editor, start: usize, text: []const u8) !void {
        if (self.mode != .insert) return;
        const lo = @min(start, self.cursor);
        if (self.cursor > lo) try self.buf.delete(lo, self.cursor - lo);
        self.cursor = lo;
        try self.insertText(text);
    }

    /// Moves the cursor, refreshing the sticky column for a horizontal
    /// move and preserving it for a vertical one.
    fn moveTo(self: *Editor, offset: usize, horizontal: bool) void {
        self.cursor = offset;
        if (horizontal) self.syncSticky();
    }

    fn syncSticky(self: *Editor) void {
        self.sticky_col = self.buf.posOf(self.cursor).col;
    }

    const VDir = enum { up, down };

    /// PageDown / PageUp: a vertical jump of `page_lines`, keeping the
    /// sticky column just like `j` / `k`. `allow_eol` follows the mode,
    /// the same as the arrow keys.
    fn pageMove(self: *Editor, dir: VDir, allow_eol: bool) void {
        const n = self.page_lines;
        const target = switch (dir) {
            .down => motion.down(&self.buf, self.cursor, n, self.sticky_col, allow_eol),
            .up => motion.up(&self.buf, self.cursor, n, self.sticky_col, allow_eol),
        };
        self.moveTo(target, false);
    }

    /// The count typed so far, defaulting to 1, consumed in the process.
    fn takeCount(self: *Editor) usize {
        const n = if (self.count == 0) 1 else self.count;
        self.count = 0;
        return n;
    }

    // ── Normal mode ─────────────────────────────────────────────────────

    fn normalChar(self: *Editor, s: []const u8) !Outcome {
        // Every normal-mode command is its own undo step, so each one
        // opens a group. An empty group (a motion, a count digit) is
        // thrown away when it closes, so this costs nothing but the call.
        self.buf.undoCheckpoint(self.cursor);
        self.undo_join_next = false;

        // `r` swallows the very next character, whatever it is -- a
        // digit, an operator, or something outside ASCII. Checked before
        // the single-byte guard below for exactly that last reason.
        if (self.pending_replace) |n| {
            self.pending_replace = null;
            try self.replaceChar(s, n);
            return .none;
        }

        // Nothing multi-byte is a command; it can only be a stray
        // keystroke, so drop it and reset rather than half-applying an
        // operator.
        if (s.len != 1) {
            self.resetPending();
            return .none;
        }
        const c = s[0];

        if (self.prefix) |p| {
            self.prefix = null;
            return self.prefixedCommand(p, c);
        }

        // A digit is a count, except `0` with no count already going --
        // that's the line-start motion.
        if (c >= '1' and c <= '9' or (c == '0' and self.count > 0)) {
            self.count = self.count * 10 + (c - '0');
            return .none;
        }

        if (self.operator != null) {
            return self.operatorMotion(c);
        }

        return self.command(c);
    }

    /// Runs `c` as a bare cursor motion with count `n` if it is one,
    /// returning true when it handled the key. Shared by normal and visual
    /// mode -- in visual mode only the moving end (`cursor`) shifts, and
    /// the selection is recomputed from anchor + cursor (`selectionSpan`).
    /// `had_count` distinguishes `G` (last line) from `{n}G` (line n).
    fn applyMotion(self: *Editor, c: u8, n: usize, had_count: bool) bool {
        switch (c) {
            'h' => self.moveTo(motion.left(&self.buf, self.cursor, n), true),
            'l' => self.moveTo(motion.right(&self.buf, self.cursor, n, false), true),
            'j' => self.moveTo(motion.down(&self.buf, self.cursor, n, self.sticky_col, false), false),
            'k' => self.moveTo(motion.up(&self.buf, self.cursor, n, self.sticky_col, false), false),
            'w' => self.moveTo(motion.wordForward(&self.buf, self.cursor, n, false), true),
            'W' => self.moveTo(motion.wordForward(&self.buf, self.cursor, n, true), true),
            'b' => self.moveTo(motion.wordBackward(&self.buf, self.cursor, n, false), true),
            'B' => self.moveTo(motion.wordBackward(&self.buf, self.cursor, n, true), true),
            'e' => self.moveTo(motion.wordEnd(&self.buf, self.cursor, n, false), true),
            'E' => self.moveTo(motion.wordEnd(&self.buf, self.cursor, n, true), true),
            '0' => self.moveTo(motion.lineStart(&self.buf, self.cursor), true),
            '^' => self.moveTo(motion.firstNonBlank(&self.buf, self.cursor), true),
            '$' => self.moveTo(motion.lineEnd(&self.buf, self.cursor, false), true),
            // `G` with a count is "go to that line", without one "go to
            // the last line" -- vim's one asymmetric motion.
            'G' => self.moveTo(motion.gotoLine(&self.buf, if (had_count) n - 1 else self.buf.lineCount() - 1), true),
            else => return false,
        }
        return true;
    }

    fn command(self: *Editor, c: u8) !Outcome {
        // `g` is a prefix, not a command: it leaves any count pending for
        // the character that completes it (`3gg` is "line 3").
        if (c == 'g') {
            self.prefix = 'g';
            return .none;
        }
        const had_count = self.count != 0;
        const n = self.takeCount();
        if (self.applyMotion(c, n, had_count)) return .none;
        switch (c) {
            // Entering insert mode.
            'i' => self.mode = .insert,
            'a' => {
                self.moveTo(motion.right(&self.buf, self.cursor, 1, true), true);
                self.mode = .insert;
            },
            'I' => {
                self.moveTo(motion.firstNonBlank(&self.buf, self.cursor), true);
                self.mode = .insert;
            },
            'A' => {
                self.moveTo(motion.lineEnd(&self.buf, self.cursor, true), true);
                self.mode = .insert;
            },
            'o' => try self.openLine(.below),
            'O' => try self.openLine(.above),

            // Entering visual mode.
            'v' => self.enterVisual(.visual),
            'V' => self.enterVisual(.visual_line),

            // Edits. Every delete also fills `self.yank` (see
            // `deleteRange` / `changeRange`) so it lands on the system
            // clipboard, matching vim's unnamed register.
            'x' => {
                try self.deleteRange(self.cursor, motion.right(&self.buf, self.cursor, n, true));
                self.yank_pending = true;
            },
            'X' => {
                try self.deleteRange(motion.left(&self.buf, self.cursor, n), self.cursor);
                self.yank_pending = true;
            },
            'D' => {
                try self.deleteRange(self.cursor, motion.lineEnd(&self.buf, self.cursor, true));
                self.yank_pending = true;
            },
            'C' => {
                try self.changeRange(self.cursor, motion.lineEnd(&self.buf, self.cursor, true));
                self.yank_pending = true;
            },
            's' => {
                try self.changeRange(self.cursor, motion.right(&self.buf, self.cursor, n, true));
                self.yank_pending = true;
            },
            'd' => {
                self.operator = 'd';
                self.operator_count = n;
            },
            'y' => {
                self.operator = 'y';
                self.operator_count = n;
            },
            // `r{char}` -- the character comes on the next input, so all
            // this does is arm it.
            'r' => self.pending_replace = n,
            'J' => try self.joinLines(n),
            '~' => try self.toggleCase(n),
            // `>`/`<` are operators like `d`/`y`; `>>` is the doubled
            // form, resolved in `operatorMotion`.
            '>', '<' => {
                self.operator = c;
                self.operator_count = n;
            },

            // Undo and redo. `u` is vim's; the redo chord Ctrl+R has no
            // character, so it is caught in `feedKey`.
            'u' => return self.undo(n),

            // Paste. The editor can't read the clipboard itself, so the
            // host fetches it and calls `putText`.
            'p', 'P' => return Outcome{ .paste = .{ .after = c == 'p' } },

            // Search.
            '/' => self.startSearch(.forward),
            '?' => self.startSearch(.backward),
            'n' => self.repeatSearch(self.search_dir, n),
            'N' => self.repeatSearch(self.search_dir.flipped(), n),
            '*' => try self.searchWord(.forward, n),
            '#' => try self.searchWord(.backward, n),

            ':' => {
                self.mode = .command;
                self.cmdline.clear();
            },

            // `K` -- what is this? Nothing the editor core can answer; see
            // `Outcome.lsp_hover`.
            'K' => return .lsp_hover,

            // `]` and `[` are prefixes, like `g`. Only `]d` / `[d` exist so
            // far; vim's other bracket pairs (`]]`, `]}`, `]c`) would land
            // here too.
            ']', '[' => self.prefix = c,

            else => {},
        }
        return .none;
    }

    fn prefixedCommand(self: *Editor, prefix: u8, c: u8) !Outcome {
        switch (prefix) {
            'g' => {},
            ']', '[' => {
                // `]d` / `[d` -- step through this buffer's diagnostics.
                _ = self.takeCount();
                if (c != 'd') return .none;
                return Outcome{ .diag_step = .{ .forward = prefix == ']' } };
            },
            else => return .none,
        }
        const n = self.takeCount();
        switch (c) {
            // `gg`: the first line, or the count'th if one was typed.
            'g' => {
                if (self.operator) |op| {
                    // `dgg` / `ygg` / `>gg` -- linewise from the target
                    // line to the cursor's.
                    self.operator = null;
                    self.operator_count = 0;
                    const first = n - 1;
                    const last = self.buf.lineAt(self.cursor);
                    switch (op) {
                        'd' => try self.deleteLines(first, last),
                        'y' => try self.yankLines(first, last),
                        // No yank and no `yank_pending` -- a shift moves
                        // text, it doesn't take a copy of it.
                        '>', '<' => {
                            try self.shiftLines(first, last, op == '>', 1);
                            return .none;
                        },
                        else => return .none,
                    }
                    self.yank_pending = true;
                    return .none;
                }
                self.moveTo(motion.gotoLine(&self.buf, n - 1), true);
            },
            // `gv`: the selection the last visual mode ended with. From
            // visual mode it swaps this selection for that one, which is
            // what vim does too.
            'v' => {
                const last = self.last_visual orelse return .none;
                self.mode = last.mode;
                self.select_anchor = motion.clampNormal(&self.buf, last.anchor);
                self.moveTo(motion.clampNormal(&self.buf, last.cursor), true);
            },
            // `gd` -- go to the definition. See `Outcome.lsp_definition`.
            'd' => return .lsp_definition,
            else => self.resetPending(),
        }
        return .none;
    }

    // ── Operator-pending ────────────────────────────────────────────────

    /// Resolves `d` / `y` + a motion. Linewise motions (`dd`/`yy`, `dj`,
    /// `dk`, `dG`, `dgg`) take whole lines; everything else takes the
    /// character range between where the cursor is and where the motion
    /// would have gone. Both operators fill `self.yank`; `d` also removes
    /// the range.
    fn operatorMotion(self: *Editor, c: u8) !Outcome {
        const motion_count = self.takeCount();
        const n = self.operator_count * motion_count;
        const op = self.operator.?;
        // `g` needs a second character, so hold the operator and wait.
        if (c == 'g') {
            self.prefix = 'g';
            self.count = n;
            return .none;
        }
        self.operator = null;
        self.operator_count = 0;

        // `>` / `<` are always linewise, so they take the vertical
        // motions and the doubled form and nothing else.
        if (op == '>' or op == '<') {
            const line = self.buf.lineAt(self.cursor);
            const right = op == '>';
            switch (c) {
                '>', '<' => if (c == op) try self.shiftLines(line, line + n - 1, right, 1),
                'j' => try self.shiftLines(line, line + n, right, 1),
                'k' => try self.shiftLines(line -| n, line, right, 1),
                'G' => try self.shiftLines(line, self.buf.lineCount() - 1, right, 1),
                else => {},
            }
            return .none;
        }

        if (op != 'd' and op != 'y') return .none;
        const del = op == 'd';

        const line = self.buf.lineAt(self.cursor);
        switch (c) {
            // Linewise. `dd` / `yy` need the doubled operator char; the
            // vertical motions don't.
            'd', 'y' => {
                if (c != op) return .none;
                if (del) try self.deleteLines(line, line + n - 1) else try self.yankLines(line, line + n - 1);
            },
            'j' => if (del) try self.deleteLines(line, line + n) else try self.yankLines(line, line + n),
            'k' => if (del) try self.deleteLines(line -| n, line) else try self.yankLines(line -| n, line),
            'G' => if (del) try self.deleteLines(line, self.buf.lineCount() - 1) else try self.yankLines(line, self.buf.lineCount() - 1),

            // Charwise, forward.
            'w' => try self.opCharwise(del, self.cursor, wordTargetForDelete(&self.buf, self.cursor, n)),
            'e' => try self.opCharwise(del, self.cursor, motion.nextCodepoint(&self.buf, motion.wordEnd(&self.buf, self.cursor, n, false))),
            'l' => try self.opCharwise(del, self.cursor, motion.right(&self.buf, self.cursor, n, true)),
            '$' => try self.opCharwise(del, self.cursor, motion.lineEnd(&self.buf, self.cursor, true)),

            // Charwise, backward.
            'b' => try self.opCharwise(del, motion.wordBackward(&self.buf, self.cursor, n, false), self.cursor),
            'h' => try self.opCharwise(del, motion.left(&self.buf, self.cursor, n), self.cursor),
            '0' => try self.opCharwise(del, motion.lineStart(&self.buf, self.cursor), self.cursor),
            '^' => {
                const target = motion.firstNonBlank(&self.buf, self.cursor);
                try self.opCharwise(del, @min(target, self.cursor), @max(target, self.cursor));
            },
            else => return .none,
        }
        self.yank_pending = true;
        return .none;
    }

    /// One charwise operator span: `d` deletes `[lo, hi)`, `y` copies it
    /// and drops the cursor at its start. Both fill `self.yank`.
    fn opCharwise(self: *Editor, del: bool, lo: usize, hi: usize) !void {
        if (del) try self.deleteRange(lo, hi) else try self.yankRange(lo, hi);
    }

    // ── Edits ───────────────────────────────────────────────────────────

    fn insertText(self: *Editor, text: []const u8) !void {
        try self.buf.insert(self.cursor, text);
        self.cursor += text.len;
        self.syncSticky();
    }

    /// The Tab key in insert mode. With `expand_tab` off it is a literal
    /// `\t`; with it on it is however many spaces reach the next
    /// `tab_width` stop -- so Tab in column 2 of a 4-wide grid inserts
    /// two spaces, not four, and the indentation lines up whatever
    /// column it was typed in.
    ///
    /// The stop is measured in *display* columns, which is why this asks
    /// `display.zig` rather than counting bytes: a line that already
    /// holds a tab, or anything double-width, puts the next stop
    /// somewhere the byte count would get wrong.
    fn insertTab(self: *Editor) !void {
        if (!self.expand_tab) return self.insertText("\t");

        const line_start = self.buf.lineStart(self.buf.posOf(self.cursor).line);
        const prefix = try self.buf.gap.read(self.alloc, line_start, self.cursor);
        defer self.alloc.free(prefix);
        const col = display.width(prefix, .{ .tab_width = self.tab_width });

        var spaces: [max_tab_width]u8 = @splat(' ');
        const n = @min(display.tabStop(col, self.tab_width), max_tab_width);
        try self.insertText(spaces[0..n]);
    }

    fn backspace(self: *Editor) !void {
        if (self.cursor == 0) return;
        const target = if (self.buf.byteAt(self.cursor - 1) == '\n')
            self.cursor - 1
        else
            motion.prevCodepoint(&self.buf, self.cursor);
        try self.buf.delete(target, self.cursor - target);
        self.cursor = target;
        self.syncSticky();
    }

    fn deleteForward(self: *Editor) !void {
        if (self.cursor >= self.buf.len()) return;
        const end = if (self.buf.byteAt(self.cursor) == '\n')
            self.cursor + 1
        else
            motion.nextCodepoint(&self.buf, self.cursor);
        try self.buf.delete(self.cursor, end - self.cursor);
        self.syncSticky();
    }

    /// Deletes `[lo, hi)` and leaves the cursor at a legal normal-mode
    /// position at `lo`. Stashes the removed text in `self.yank` so a
    /// caller can put it on the clipboard.
    fn deleteRange(self: *Editor, lo: usize, hi: usize) !void {
        if (hi <= lo) return;
        try self.stashYankRange(lo, hi, false);
        try self.buf.delete(lo, hi - lo);
        self.cursor = motion.clampNormal(&self.buf, lo);
        self.syncSticky();
    }

    /// Like `deleteRange`, but leaves the cursor exactly where the
    /// deletion started instead of pulling it back onto a character: the
    /// caller is entering insert mode, where sitting past the line's last
    /// character is legal. `C` at the end of a line would otherwise type
    /// one column left of where it deleted. Also stashes the removed text.
    fn changeRange(self: *Editor, lo: usize, hi: usize) !void {
        if (hi > lo) {
            try self.stashYankRange(lo, hi, false);
            try self.buf.delete(lo, hi - lo);
        }
        self.cursor = @min(lo, self.buf.len());
        self.syncSticky();
        self.mode = .insert;
    }

    /// Copies `[lo, hi)` into `self.yank` (charwise) and drops the cursor
    /// at `lo` -- the `y` operator's charwise path (`yw`, `y$`, ...).
    fn yankRange(self: *Editor, lo: usize, hi: usize) !void {
        try self.stashYankRange(lo, hi, false);
        self.moveTo(motion.clampNormal(&self.buf, lo), true);
    }

    /// Copies lines `[first, last]` into `self.yank` (linewise, so the
    /// text ends with a newline) and lands the cursor on the first --
    /// `yy`, `yj`, `yG`, `ygg`.
    fn yankLines(self: *Editor, first: usize, last: usize) !void {
        const lc = self.buf.lineCount();
        const f = @min(first, lc - 1);
        const l = @min(@max(first, last), lc - 1);
        try self.stashYankRange(self.buf.lineStart(f), self.buf.lineEnd(l), true);
        self.moveTo(motion.gotoLine(&self.buf, f), true);
    }

    /// Copies `[lo, hi)` into `self.yank`. `linewise` guarantees a
    /// trailing newline (adding one for a last-line yank that has none),
    /// so a later `putText` can tell a linewise paste from a charwise one
    /// from the clipboard text alone.
    fn stashYankRange(self: *Editor, lo: usize, hi: usize, linewise: bool) !void {
        self.yank.clearRetainingCapacity();
        if (hi > lo) {
            const s = try self.buf.read(self.alloc, lo, hi);
            defer self.alloc.free(s);
            try self.yank.appendSlice(self.alloc, s);
        }
        if (linewise and (self.yank.items.len == 0 or
            self.yank.items[self.yank.items.len - 1] != '\n'))
        {
            try self.yank.append(self.alloc, '\n');
        }
    }

    /// The outcome for a command that just filled `self.yank`: a
    /// `set_clipboard` borrowing it, or `.none` when nothing was actually
    /// yanked (an `x` at the end of the buffer, a `dw` on empty text).
    fn clipboardYankOutcome(self: *Editor) Outcome {
        if (self.yank.items.len == 0) return .none;
        return .{ .set_clipboard = self.yank.items };
    }

    /// Linewise delete of `[first, last]`, inclusive. The trailing
    /// newline goes with the lines, except when they run to the end of
    /// the buffer -- there the *leading* newline goes instead, or the
    /// previous line would be left with a phantom blank one after it.
    /// Stashes the removed lines in `self.yank` (linewise).
    fn deleteLines(self: *Editor, first: usize, last: usize) !void {
        const line_count = self.buf.lineCount();
        const f = @min(first, line_count - 1);
        const l = @min(last, line_count - 1);
        const start = self.buf.lineStart(f);
        const end = self.buf.lineEnd(l);
        try self.stashYankRange(start, end, true);

        if (end < self.buf.len()) {
            try self.buf.delete(start, end + 1 - start);
        } else if (f > 0) {
            const prev_end = self.buf.lineEnd(f - 1);
            try self.buf.delete(prev_end, end - prev_end);
        } else {
            try self.buf.delete(start, end - start);
        }

        // vim lands on the first non-blank of whatever line took their
        // place (or the last line, if they were the last).
        const landed = @min(f, self.buf.lineCount() - 1);
        self.moveTo(motion.gotoLine(&self.buf, landed), true);
    }

    /// `r{char}`: overwrite `count` characters with `count` copies of
    /// `s`. All or nothing, like vim -- `5rx` on a three-character line
    /// does nothing rather than replacing what fits.
    ///
    /// `r` followed by a *named* key other than Escape leaves the replace
    /// armed rather than cancelling it; only a character (or Escape,
    /// through `resetPending`) resolves it.
    fn replaceChar(self: *Editor, s: []const u8, count: usize) !void {
        const line = self.buf.lineAt(self.cursor);
        const limit = self.buf.lineEnd(line);
        var end = self.cursor;
        var i: usize = 0;
        while (i < count) : (i += 1) {
            if (end >= limit) return;
            end = motion.nextCodepoint(&self.buf, end);
        }

        var rep: std.ArrayList(u8) = .empty;
        defer rep.deinit(self.alloc);
        var k: usize = 0;
        while (k < count) : (k += 1) try rep.appendSlice(self.alloc, s);

        try self.buf.delete(self.cursor, end - self.cursor);
        try self.buf.insert(self.cursor, rep.items);
        // On the last replaced character, which is where vim leaves it.
        self.moveTo(motion.clampNormal(&self.buf, self.cursor + rep.items.len - s.len), true);
    }

    /// `J`: pull the next line onto this one, `count - 1` times (a bare
    /// `J` joins one line, `3J` joins three lines into one).
    ///
    /// The next line's indent goes with the newline and a single space
    /// takes their place -- unless this line is empty, already ends in
    /// whitespace, or the next line starts with `)`, which are vim's
    /// three exceptions. The cursor lands on the join.
    fn joinLines(self: *Editor, count: usize) !void {
        const joins = if (count > 1) count - 1 else 1;
        var i: usize = 0;
        while (i < joins) : (i += 1) {
            const line = self.buf.lineAt(self.cursor);
            if (line + 1 >= self.buf.lineCount()) break;

            const end = self.buf.lineEnd(line); // the newline itself
            const next_end = self.buf.lineEnd(line + 1);
            var cut = self.buf.lineStart(line + 1);
            while (cut < next_end and isBlank(self.buf.byteAt(cut))) cut += 1;

            const here_empty = end == self.buf.lineStart(line);
            const ends_blank = !here_empty and isBlank(self.buf.byteAt(end - 1));
            const next_empty = cut >= next_end;
            const next_closes = !next_empty and self.buf.byteAt(cut) == ')';

            try self.buf.delete(end, cut - end);
            if (!(here_empty or ends_blank or next_empty or next_closes)) {
                try self.buf.insert(end, " ");
            }
            self.moveTo(motion.clampNormal(&self.buf, end), true);
        }
    }

    /// `~`: flip the case of `count` characters and step past them.
    ///
    /// ASCII only. Flipping case beyond ASCII needs a Unicode case table,
    /// and a byte-wise flip of a UTF-8 sequence would corrupt it, so
    /// anything multi-byte is stepped over untouched.
    fn toggleCase(self: *Editor, count: usize) !void {
        const line = self.buf.lineAt(self.cursor);
        const limit = self.buf.lineEnd(line);
        var at = self.cursor;
        var i: usize = 0;
        while (i < count and at < limit) : (i += 1) {
            const b = self.buf.byteAt(at);
            const next = motion.nextCodepoint(&self.buf, at);
            if (next == at + 1 and std.ascii.isAlphabetic(b)) {
                const flipped: u8 = if (std.ascii.isLower(b))
                    std.ascii.toUpper(b)
                else
                    std.ascii.toLower(b);
                try self.buf.delete(at, 1);
                try self.buf.insert(at, &[_]u8{flipped});
            }
            at = next;
        }
        self.moveTo(motion.clampNormal(&self.buf, at), true);
    }

    /// `>>` / `<<` and their operator forms: shift lines `[first, last]`
    /// by `times` `tab_width`s. vim's `shiftwidth` is a separate option;
    /// zoe has one indent size, so the Tab key and `>>` agree by
    /// construction.
    ///
    /// A normal-mode count is a number of *lines* (`3>>` shifts three
    /// lines one level), so `times` is 1 there; it is the visual-mode
    /// `3>` that means three levels.
    fn shiftLines(self: *Editor, first: usize, last: usize, right: bool, times: usize) !void {
        const lc = self.buf.lineCount();
        const f = @min(first, lc - 1);
        const l = @min(@max(first, last), lc - 1);

        var pass: usize = 0;
        while (pass < times) : (pass += 1) {
            // Bottom-up: indenting a line moves every line after it, so a
            // top-down walk would be reading stale offsets by the second.
            var line = l + 1;
            while (line > f) {
                line -= 1;
                if (right) try self.indentLine(line) else try self.dedentLine(line);
            }
        }
        self.moveTo(motion.firstNonBlank(&self.buf, self.buf.lineStart(f)), true);
    }

    /// Visual `>` / `<`: shift every line the selection touches, `times`
    /// levels, and **keep the selection** so pressing `>` again shifts it
    /// further and Escape is what leaves.
    ///
    /// vim exits visual mode here and makes you `gv` to get the selection
    /// back, which is why `vnoremap > >gv` is in so many vimrcs; zoe just
    /// does the useful thing. `gv` exists too, for everything else it is
    /// good for.
    ///
    /// Both ends are carried across by line, with their column moved by
    /// however much that line's indent grew or shrank, so the selection
    /// stays on the same characters instead of sliding along the indent.
    fn visualShift(self: *Editor, right: bool, times: usize) !void {
        const span = self.selectionSpan() orelse {
            self.exitVisual();
            return;
        };
        const anchor = self.select_anchor orelse self.cursor;

        const a = SelEnd.of(&self.buf, anchor);
        const c = SelEnd.of(&self.buf, self.cursor);
        const first = self.buf.lineAt(span.lo);
        const last = self.buf.lineAt(if (span.hi > span.lo) span.hi - 1 else span.hi);

        try self.shiftLines(first, last, right, times);

        self.select_anchor = a.restore(&self.buf);
        self.moveTo(c.restore(&self.buf), true);
    }

    /// One end of a visual selection, remembered across an edit that
    /// changes its line's indent. See `visualShift`.
    const SelEnd = struct {
        line: usize,
        col: usize,
        /// The line's length before the shift, so the difference gives
        /// how far the text on it moved.
        was: usize,

        fn of(buf: *const Buffer, at: usize) SelEnd {
            const line = buf.lineAt(at);
            return .{ .line = line, .col = at - buf.lineStart(line), .was = buf.lineLen(line) };
        }

        fn restore(self: SelEnd, buf: *const Buffer) usize {
            const line = @min(self.line, buf.lineCount() - 1);
            const now = buf.lineLen(line);
            const col = if (now >= self.was)
                self.col + (now - self.was)
            else
                self.col -| (self.was - now);
            return buf.lineStart(line) + @min(col, now);
        }
    };

    fn indentLine(self: *Editor, line: usize) !void {
        // An empty line stays empty -- vim doesn't leave trailing
        // whitespace behind on one.
        if (self.buf.lineLen(line) == 0) return;
        const start = self.buf.lineStart(line);
        if (!self.expand_tab) return self.buf.insert(start, "\t");
        const spaces: [max_tab_width]u8 = @splat(' ');
        try self.buf.insert(start, spaces[0..self.tab_width]);
    }

    fn dedentLine(self: *Editor, line: usize) !void {
        const start = self.buf.lineStart(line);
        const end = self.buf.lineEnd(line);
        // Up to one shift width of leading whitespace, measured in
        // display columns so a single leading tab comes off in one go
        // however wide it renders.
        var at = start;
        var cols: usize = 0;
        while (at < end and cols < self.tab_width) : (at += 1) {
            const b = self.buf.byteAt(at);
            if (b == ' ') {
                cols += 1;
            } else if (b == '\t') {
                cols += display.tabStop(cols, self.tab_width);
            } else break;
        }
        if (at > start) try self.buf.delete(start, at - start);
    }

    // ── Undo ────────────────────────────────────────────────────────────

    /// `u`. The steps themselves are `buffer.zig`'s; this walks `count`
    /// of them and puts the cursor where each one says.
    fn undo(self: *Editor, count: usize) !Outcome {
        var did = false;
        var i: usize = 0;
        while (i < count) : (i += 1) {
            const at = (try self.buf.undo()) orelse break;
            self.moveTo(motion.clampNormal(&self.buf, at), true);
            did = true;
        }
        if (!did) self.setStatus("Already at oldest change", .{});
        return .none;
    }

    /// Ctrl+R, the counterpart to `u`. Takes the pending count the same
    /// way, since it arrives through `feedKey` with one possibly typed.
    fn redo(self: *Editor) !Outcome {
        const count = self.takeCount();
        var did = false;
        var i: usize = 0;
        while (i < count) : (i += 1) {
            const at = (try self.buf.redo()) orelse break;
            self.moveTo(motion.clampNormal(&self.buf, at), true);
            did = true;
        }
        if (!did) self.setStatus("Already at newest change", .{});
        return .none;
    }

    const OpenWhere = enum { above, below };

    /// `o` / `O`: a new line and insert mode on it.
    fn openLine(self: *Editor, where: OpenWhere) !void {
        const line = self.buf.lineAt(self.cursor);
        switch (where) {
            .below => {
                const at = self.buf.lineEnd(line);
                try self.buf.insert(at, "\n");
                self.cursor = at + 1;
            },
            .above => {
                const at = self.buf.lineStart(line);
                try self.buf.insert(at, "\n");
                self.cursor = at;
            },
        }
        self.syncSticky();
        self.mode = .insert;
    }

    // ── Visual mode & clipboard ────────────────────────────────────────

    /// The current visual selection as a byte range, or null when not in
    /// a visual mode. Charwise (`v`) is inclusive of the cursor cell, the
    /// way vim highlights it; linewise (`V`) covers whole lines including
    /// the trailing newline. `zoe/ui.zig` reads this to paint the
    /// highlight and to know what `y` / `d` act on.
    pub const SelSpan = struct { lo: usize, hi: usize, linewise: bool };

    pub fn selectionSpan(self: *const Editor) ?SelSpan {
        const a = self.select_anchor orelse return null;
        const lo = @min(a, self.cursor);
        const hi = @max(a, self.cursor);
        // A `/` started from visual mode keeps the selection and extends
        // it to the match as you type, so the prompt reports the mode it
        // will return to rather than `.search`.
        const m = if (self.mode == .search) self.search_return else self.mode;
        switch (m) {
            .visual => return .{
                .lo = @min(lo, self.buf.len()),
                .hi = motion.nextCodepoint(&self.buf, hi),
                .linewise = false,
            },
            .visual_line => {
                const first = self.buf.lineStart(self.buf.lineAt(lo));
                const text_end = self.buf.lineEnd(self.buf.lineAt(hi));
                return .{
                    .lo = first,
                    .hi = @min(text_end + 1, self.buf.len()),
                    .linewise = true,
                };
            },
            else => return null,
        }
    }

    /// `v` / `V` from normal mode: start a selection anchored at the
    /// cursor. `kind` is `.visual` or `.visual_line`.
    fn enterVisual(self: *Editor, kind: Mode) void {
        self.resetPending();
        self.mode = kind;
        self.select_anchor = self.cursor;
    }

    /// Back to normal mode, selection dropped. Also the target of
    /// `<esc>` in a visual mode.
    pub fn exitVisual(self: *Editor) void {
        if (self.select_anchor) |a| {
            if (self.mode == .visual or self.mode == .visual_line) {
                self.last_visual = .{ .anchor = a, .cursor = self.cursor, .mode = self.mode };
            }
        }
        self.resetPending();
        self.mode = .normal;
        self.select_anchor = null;
    }

    /// Puts the cursor at byte offset `byte`, clamped onto a legal
    /// normal-mode position -- a mouse press with no drag yet.
    pub fn moveCursorTo(self: *Editor, byte: usize) void {
        self.moveTo(motion.clampNormal(&self.buf, byte), true);
    }

    /// A charwise visual selection between two byte offsets -- a mouse
    /// drag. Both ends are clamped onto legal positions.
    pub fn setVisualSelection(self: *Editor, anchor: usize, cursor: usize) void {
        self.mode = .visual;
        self.select_anchor = motion.clampNormal(&self.buf, anchor);
        self.moveTo(motion.clampNormal(&self.buf, cursor), true);
    }

    /// One visual-mode command character (dispatched off `feedText` like
    /// normal mode). Motions move the cursor end; `y` / `d` / `x` / `c` /
    /// `p` act on the selection and leave visual mode.
    fn visualChar(self: *Editor, s: []const u8) !Outcome {
        self.buf.undoCheckpoint(self.cursor);
        self.undo_join_next = false;

        if (s.len != 1) {
            self.resetPending();
            return .none;
        }
        const c = s[0];

        if (self.prefix) |p| {
            self.prefix = null;
            return self.prefixedCommand(p, c);
        }
        if (c >= '1' and c <= '9' or (c == '0' and self.count > 0)) {
            self.count = self.count * 10 + (c - '0');
            return .none;
        }

        // `g` is a prefix -- leave any count pending for the char that
        // completes it (`3gg`), the same as `command` does.
        if (c == 'g') {
            self.prefix = 'g';
            return .none;
        }

        const had_count = self.count != 0;
        const n = self.takeCount();
        if (self.applyMotion(c, n, had_count)) return .none;

        switch (c) {
            // Leave the submode, or switch between charwise and linewise.
            'v' => if (self.mode == .visual) self.exitVisual() else {
                self.mode = .visual;
            },
            'V' => if (self.mode == .visual_line) self.exitVisual() else {
                self.mode = .visual_line;
            },
            // Move the cursor to the other end of the selection.
            'o' => if (self.select_anchor) |a| {
                self.select_anchor = self.cursor;
                self.moveTo(a, true);
            },
            // Yank / delete / change the selection, then leave visual mode.
            'y' => return self.visualOperate(.yank),
            'd', 'x' => return self.visualOperate(.delete),
            'c', 's' => return self.visualOperate(.change),
            // Shift every line the selection touches, `n` levels, and
            // stay in visual mode -- see `visualShift`.
            '>', '<' => try self.visualShift(c == '>', n),
            // Search from a selection extends it: the anchor stays put
            // and the match becomes the moving end.
            '/' => self.startSearch(.forward),
            '?' => self.startSearch(.backward),
            'n' => self.repeatSearch(self.search_dir, n),
            'N' => self.repeatSearch(self.search_dir.flipped(), n),
            '*' => try self.searchWord(.forward, n),
            '#' => try self.searchWord(.backward, n),
            // Replace the selection with the clipboard: drop the selected
            // text (without touching the clipboard) and let the host
            // splice its contents in at the gap.
            'p', 'P' => {
                const span = self.selectionSpan() orelse {
                    self.exitVisual();
                    return .none;
                };
                try self.removeSpan(span);
                self.exitVisual();
                // The host fetches the clipboard and calls `putText`;
                // hold the undo group open across that round trip so the
                // replacement is one step.
                self.undo_join_next = true;
                return Outcome{ .paste = .{ .after = false } };
            },
            // `:` from visual mode just enters the command line (no
            // `'<,'>` range support yet).
            ':' => {
                self.exitVisual();
                self.mode = .command;
                self.cmdline.clear();
            },
            else => {},
        }
        return .none;
    }

    const VisualOp = enum { yank, delete, change };

    /// Shared tail of visual `y` / `d` / `c`: stash the selection, act on
    /// it, and leave visual mode. Marks the yank pending so `feedText`
    /// emits one `set_clipboard` once the input is fully processed.
    fn visualOperate(self: *Editor, op: VisualOp) !Outcome {
        const span = self.selectionSpan() orelse {
            self.exitVisual();
            return .none;
        };
        try self.stashYankRange(span.lo, span.hi, span.linewise);
        switch (op) {
            .yank => {
                self.exitVisual();
                self.moveTo(motion.clampNormal(&self.buf, span.lo), true);
            },
            .delete => {
                try self.removeSpan(span);
                self.exitVisual();
            },
            .change => {
                try self.removeSpan(span);
                self.select_anchor = null;
                self.mode = .insert;
            },
        }
        self.yank_pending = true;
        return .none;
    }

    /// Deletes a selection span, landing the cursor at a legal position
    /// at its start. Does *not* fill `self.yank` -- the caller decides
    /// whether the removed text should reach the clipboard.
    fn removeSpan(self: *Editor, span: SelSpan) !void {
        if (span.hi <= span.lo) return;
        try self.buf.delete(span.lo, span.hi - span.lo);
        self.cursor = motion.clampNormal(&self.buf, span.lo);
        self.syncSticky();
    }

    /// Drops the visual selection's text without touching the clipboard
    /// and returns to normal mode -- the host calls this before splicing
    /// in a `paste` notification (Ctrl+Shift+V over a selection). A no-op
    /// outside visual mode.
    pub fn dropSelection(self: *Editor) !void {
        if (self.selectionSpan()) |span| {
            self.buf.undoCheckpoint(self.cursor);
            try self.removeSpan(span);
            // Its only caller pastes over the gap next, so the group
            // stays open and the pair is one `u`. `putText` closes it.
            self.undo_join_next = true;
        }
        self.exitVisual();
    }

    /// Inserts clipboard `text` at the cursor the way `p` / `P` do.
    /// `after` is `p` (below the line / after the cursor) vs `P` (above /
    /// at the cursor). Text ending in a newline is pasted linewise --
    /// whole lines above or below the current one, like vim's linewise
    /// register; anything else is spliced in charwise. Called by the host
    /// once it has fetched the clipboard for an `Outcome.paste`.
    pub fn putText(self: *Editor, text: []const u8, after: bool) !void {
        if (text.len == 0) return;
        // A visual-mode `p` already removed the selection and asked for
        // its group to be held open (`undo_join_next`), so the splice
        // joins it and one `u` puts the original text back. Every other
        // paste -- `p` from normal mode, the Ctrl+Shift+P chord, a
        // bracketed paste -- is a step of its own.
        if (self.undo_join_next) {
            self.undo_join_next = false;
        } else {
            self.buf.undoCheckpoint(self.cursor);
        }
        defer self.buf.closeUndoGroup();

        const linewise = text[text.len - 1] == '\n';
        if (linewise) {
            const line = self.buf.lineAt(self.cursor);
            const at = if (after) blk: {
                if (line + 1 < self.buf.lineCount()) break :blk self.buf.lineStart(line + 1);
                // Pasting below the last line: it has no trailing newline
                // to insert after, so add one first.
                try self.buf.insert(self.buf.len(), "\n");
                break :blk self.buf.len();
            } else self.buf.lineStart(line);
            try self.buf.insert(at, text);
            self.moveTo(motion.firstNonBlank(&self.buf, at), true);
        } else {
            const at = if (after) motion.right(&self.buf, self.cursor, 1, true) else self.cursor;
            try self.buf.insert(at, text);
            // vim leaves the cursor on the last pasted character.
            self.moveTo(motion.clampNormal(&self.buf, at + text.len - 1), true);
        }
    }

    /// Ctrl+Shift+C / the host's `copy_request`: put the visual selection
    /// on the clipboard, or -- with no selection -- the current line
    /// (linewise, like `yy`). Leaves visual mode; the cursor stays put.
    pub fn clipboardCopy(self: *Editor) !Outcome {
        if (self.selectionSpan()) |span| {
            try self.stashYankRange(span.lo, span.hi, span.linewise);
            self.exitVisual();
        } else {
            const line = self.buf.lineAt(self.cursor);
            try self.stashYankRange(self.buf.lineStart(line), self.buf.lineEnd(line), true);
        }
        return self.clipboardYankOutcome();
    }

    /// Ctrl+Shift+X: like `clipboardCopy`, but also remove what it
    /// copied -- the visual selection, or the current line.
    pub fn clipboardCut(self: *Editor) !Outcome {
        // Called straight from `ui.zig` (the Ctrl+Shift+X chord), so it
        // opens and closes its own undo step rather than riding one a
        // `feed*` call set up.
        self.buf.undoCheckpoint(self.cursor);
        defer self.buf.closeUndoGroup();
        if (self.selectionSpan()) |span| {
            try self.stashYankRange(span.lo, span.hi, span.linewise);
            try self.removeSpan(span);
            self.exitVisual();
        } else {
            const line = self.buf.lineAt(self.cursor);
            try self.deleteLines(line, line);
        }
        return self.clipboardYankOutcome();
    }

    // ── Search ──────────────────────────────────────────────────────────
    //
    // `/` and `?` open a prompt that is the same `LineEdit` the `:` line
    // is, but every keystroke re-runs the search **from where the cursor
    // was when the prompt opened** rather than from where the last
    // preview landed. That is what makes `incsearch` stable: deleting a
    // character has to walk the preview backwards, and it can only do
    // that if the origin never moved.
    //
    // Matching itself is `search.zig` -- literal text, smartcase. The
    // state here is vim's search register (`search_pat`), the direction
    // `n` repeats, and whether the highlight is showing.

    /// `/` and `?`. Remembers where the cursor was and which mode to
    /// return to, so Escape can undo the whole preview.
    fn startSearch(self: *Editor, dir: SearchDir) void {
        self.search_return = self.mode;
        self.search_origin = self.cursor;
        self.search_dir = dir;
        self.search_failed = false;
        self.search_match = null;
        self.mode = .search;
        self.cmdline.clear();
    }

    const SearchExit = enum {
        /// Escape: put the cursor back where the prompt found it.
        restore,
        /// Enter: the preview is the answer, leave the cursor on it.
        keep,
    };

    fn leaveSearch(self: *Editor, how: SearchExit) void {
        self.mode = self.search_return;
        self.cmdline.clear();
        self.search_failed = false;
        if (how == .restore) {
            self.moveTo(self.search_origin, true);
            self.search_match = null;
        }
    }

    /// Re-runs the search for whatever is on the prompt, moving the
    /// cursor onto the match. Called on every edit of the `/` line.
    fn incrementalSearch(self: *Editor) void {
        const pat = self.cmdline.text();
        if (pat.len == 0) {
            self.moveTo(self.search_origin, true);
            self.search_match = null;
            self.search_failed = false;
            return;
        }
        // A typed pattern is never whole-word -- that is `*`'s doing --
        // so the options come from the pattern alone.
        const opts = search.optsFor(pat, false);
        const hit = self.findFrom(pat, opts, self.search_origin, self.search_dir, 1);
        if (hit) |h| {
            self.search_failed = false;
            self.search_match = h.at;
            self.moveTo(h.at, true);
        } else {
            self.search_failed = true;
            self.search_match = null;
            self.moveTo(self.search_origin, true);
        }
    }

    /// Enter on the `/` line: adopt the pattern as the one `n` repeats,
    /// turn the highlight on, and stay on the match. An empty line
    /// repeats the previous pattern, the way a bare `/` does in vim.
    fn commitSearch(self: *Editor) !void {
        const typed = self.cmdline.text();
        if (typed.len > 0) {
            self.search_pat.clearRetainingCapacity();
            try self.search_pat.appendSlice(self.alloc, typed);
            self.search_word = false;
        }
        const dir = self.search_dir;
        const origin = self.search_origin;
        self.leaveSearch(.keep);

        if (self.search_pat.items.len == 0) {
            self.setStatus("E35: No previous regular expression", .{});
            return;
        }
        self.search_hl = true;
        // From the origin, not from the preview: the preview already sits
        // on the first match, and searching on from it would skip one.
        self.moveTo(origin, true);
        self.jump(dir, 1);
    }

    /// `n` / `N`: the stored pattern again, `count` matches on.
    fn repeatSearch(self: *Editor, dir: SearchDir, count: usize) void {
        if (self.search_pat.items.len == 0) {
            self.setStatus("E35: No previous regular expression", .{});
            return;
        }
        self.search_hl = true;
        self.jump(dir, count);
    }

    /// `*` / `#`: search for the word under the cursor, whole-word, from
    /// here. vim leaves the cursor on the *next* such word, which is what
    /// the jump below does since it never matches at the cursor itself.
    fn searchWord(self: *Editor, dir: SearchDir, count: usize) !void {
        const word = search.wordAt(&self.buf, self.cursor) orelse {
            self.setStatus("E348: No string under cursor", .{});
            return;
        };
        const text = try self.buf.read(self.alloc, word.lo, word.hi);
        defer self.alloc.free(text);

        self.search_pat.clearRetainingCapacity();
        try self.search_pat.appendSlice(self.alloc, text);
        self.search_word = true;
        self.search_hl = true;
        // From the start of the word, so `*` on the middle of one doesn't
        // find the same occurrence it is standing on.
        self.moveTo(word.lo, true);
        self.jump(dir, count);
    }

    /// Moves to the `count`th match of the stored pattern in `dir`,
    /// reporting a wrap or a miss the way vim does. Also records the
    /// direction, so a later `n` repeats *this*.
    fn jump(self: *Editor, dir: SearchDir, count: usize) void {
        self.search_dir = dir;
        const pat = self.search_pat.items;
        const opts = self.searchOpts();
        const hit = self.findFrom(pat, opts, self.cursor, dir, count) orelse {
            self.search_match = null;
            self.setStatus("E486: Pattern not found: {s}", .{pat});
            return;
        };
        self.search_match = hit.at;
        self.moveTo(hit.at, true);
        if (hit.wrapped) {
            // vim's own wording, and its own two messages -- `setStatus`
            // wants a comptime format, so they can't be one expression.
            if (dir == .forward)
                self.setStatus("search hit BOTTOM, continuing at TOP", .{})
            else
                self.setStatus("search hit TOP, continuing at BOTTOM", .{});
        }
    }

    /// `count` steps of `search.forward` / `search.backward` from `from`.
    /// Wrapping is on, so only a pattern that appears nowhere misses.
    fn findFrom(
        self: *const Editor,
        pat: []const u8,
        opts: search.Opts,
        from: usize,
        dir: SearchDir,
        count: usize,
    ) ?search.Hit {
        var at = from;
        var wrapped = false;
        var i: usize = 0;
        while (i < count) : (i += 1) {
            const step = switch (dir) {
                .forward => search.forward(&self.buf, pat, opts, at, true),
                .backward => search.backward(&self.buf, pat, opts, at, true),
            } orelse return null;
            at = step.at;
            wrapped = wrapped or step.wrapped;
        }
        return .{ .at = at, .wrapped = wrapped };
    }

    /// How the stored pattern is compared -- smartcase, plus whole-word
    /// when `*` / `#` set it. `ui.zig` needs this to paint the same
    /// matches the cursor jumps between.
    pub fn searchOpts(self: *const Editor) search.Opts {
        return search.optsFor(self.search_pat.items, self.search_word);
    }

    /// The pattern `ui.zig` should highlight, or null when there is
    /// nothing to show: no search yet, or `:noh` since the last one.
    /// While the prompt is open it is the half-typed line, so the
    /// highlight grows as you type.
    pub fn highlightPattern(self: *const Editor) ?[]const u8 {
        if (self.mode == .search) {
            const typed = self.cmdline.text();
            return if (typed.len == 0) null else typed;
        }
        if (!self.search_hl or self.search_pat.items.len == 0) return null;
        return self.search_pat.items;
    }

    /// `searchOpts` for whatever `highlightPattern` returned -- the
    /// half-typed line is never whole-word.
    pub fn highlightOpts(self: *const Editor) search.Opts {
        if (self.mode == .search) return search.optsFor(self.cmdline.text(), false);
        return self.searchOpts();
    }

    /// The character the `/` prompt is drawn with, for the status line.
    pub fn searchPrompt(self: *const Editor) u8 {
        return if (self.search_dir == .forward) '/' else '?';
    }

    // ── Command line ────────────────────────────────────────────────────

    /// Runs whatever is on the `:` line and returns to normal mode.
    /// Everything that touches the filesystem leaves as an `Outcome` for
    /// the host to carry out.
    fn runCommand(self: *Editor) !Outcome {
        self.mode = .normal;
        const line = std.mem.trim(u8, self.cmdline.text(), " \t");
        defer self.cmdline.clear();
        if (line.len == 0) return .none;

        // `:42` -- jump to a line.
        if (allDigits(line)) {
            const n = std.fmt.parseInt(usize, line, 10) catch return .none;
            self.moveTo(motion.gotoLine(&self.buf, if (n == 0) 0 else n - 1), true);
            return .none;
        }

        // `:$`, `:.`, `:+N`, `:-N`, and `:{count}{motion}` (`:23k`) --
        // a line address or a normal-mode motion typed on the `:` line.
        if (self.commandLineJump(line)) return .none;

        const name_end = std.mem.indexOfAny(u8, line, " \t") orelse line.len;
        const name = line[0..name_end];
        const arg = std.mem.trim(u8, line[name_end..], " \t");

        self.cmd_arg.clearRetainingCapacity();
        try self.cmd_arg.appendSlice(self.alloc, arg);
        const arg_opt: ?[]const u8 = if (self.cmd_arg.items.len == 0) null else self.cmd_arg.items;

        const eq = std.mem.eql;
        // `:noh` -- drop the search highlight, keeping the pattern so `n`
        // still works. vim spells it `:nohlsearch`; both are here because
        // nobody types the long one.
        if (eq(u8, name, "noh") or eq(u8, name, "nohl") or eq(u8, name, "nohlsearch")) {
            self.search_hl = false;
            self.search_match = null;
            return .none;
        }
        if (eq(u8, name, "cd") or eq(u8, name, "chdir")) return .{ .chdir = arg_opt };
        if (eq(u8, name, "pwd")) return .pwd;
        if (eq(u8, name, "set")) {
            self.applySet(arg_opt);
            return .none;
        }
        if (eq(u8, name, "w") or eq(u8, name, "write")) return .{ .write = arg_opt };
        if (eq(u8, name, "e") or eq(u8, name, "edit")) {
            // A *bare* `:e` re-reads this buffer from disk and throws
            // away unsaved changes, so it needs the same guard `:q` has.
            // `:e <path>` opens another buffer in another tab and
            // abandons nothing -- see decisions.md's "zoe multiple
            // buffers".
            if (arg_opt == null and self.buf.dirty) {
                self.setStatus("E37: No write since last change (add ! to override)", .{});
                return .none;
            }
            return .{ .edit = arg_opt };
        }
        if (eq(u8, name, "e!") or eq(u8, name, "edit!")) return .{ .edit = arg_opt };
        if (eq(u8, name, "bn") or eq(u8, name, "bnext")) return .{ .buffer_step = .{ .forward = true } };
        if (eq(u8, name, "bp") or eq(u8, name, "bprev") or eq(u8, name, "bprevious"))
            return .{ .buffer_step = .{ .forward = false } };
        if (eq(u8, name, "bd!") or eq(u8, name, "bdelete!")) return .{ .buffer_close = .{ .force = true } };
        if (eq(u8, name, "bd") or eq(u8, name, "bdelete")) {
            if (self.buf.dirty) {
                self.setStatus("E37: No write since last change (add ! to override)", .{});
                return .none;
            }
            return .{ .buffer_close = .{ .force = false } };
        }
        if (eq(u8, name, "vs") or eq(u8, name, "vsp") or eq(u8, name, "vsplit"))
            return .{ .split = .{ .vertical = true, .path = arg_opt } };
        if (eq(u8, name, "sp") or eq(u8, name, "split"))
            return .{ .split = .{ .vertical = false, .path = arg_opt } };
        if (eq(u8, name, "clo") or eq(u8, name, "close")) return .close_group;
        // `:lsp` reports which language servers are attached; `:lsp restart`
        // brings back one that crashed. The editor core knows about neither,
        // so both are just relayed (see `Outcome.lsp_status`).
        if (eq(u8, name, "lsp")) return .{ .lsp_status = arg_opt };
        if (eq(u8, name, "diag") or eq(u8, name, "diagnostics")) return .diag_list;
        if (eq(u8, name, "theme") or eq(u8, name, "colo") or eq(u8, name, "colorscheme")) return .{ .theme = arg_opt };
        if (eq(u8, name, "wq") or eq(u8, name, "x")) return .{ .write_quit = arg_opt };
        if (eq(u8, name, "q!") or eq(u8, name, "quit!")) return .{ .quit = .{ .force = true } };
        if (eq(u8, name, "wq!") or eq(u8, name, "x!")) return .{ .write_quit = arg_opt };
        if (eq(u8, name, "q") or eq(u8, name, "quit")) {
            if (self.buf.dirty) {
                self.setStatus("E37: No write since last change (add ! to override)", .{});
                return .none;
            }
            return .{ .quit = .{ .force = false } };
        }

        self.setStatus("E492: Not an editor command: {s}", .{name});
        return .none;
    }

    /// The options `:set` understands, all of them `name=value` with
    /// spaces around the `=` tolerated (`:set lineno = relative`):
    ///
    ///  - `lineno=off|absolute|relative` -- the line-number gutter
    ///  - `tabwidth=N`                   -- cells between tab stops
    ///  - `expandtab=on|off`             -- Tab inserts spaces
    ///  - `whitespace=on|off`            -- mark spaces and tabs
    ///
    /// An unknown option name or value leaves the setting as it was and
    /// reports the matching vim error. `zoe/ui.zig` pushes whatever
    /// changed to every open buffer, so `:set` reads as session-wide.
    fn applySet(self: *Editor, arg: ?[]const u8) void {
        const a = arg orelse {
            self.setStatus("E518: Unknown option: {s}", .{""});
            return;
        };
        const eq_at = std.mem.indexOfScalar(u8, a, '=') orelse {
            self.setStatus("E518: Unknown option: {s}", .{a});
            return;
        };
        const opt = std.mem.trim(u8, a[0..eq_at], " \t");
        const val = std.mem.trim(u8, a[eq_at + 1 ..], " \t");

        if (std.mem.eql(u8, opt, "lineno")) {
            self.line_numbers = if (std.mem.eql(u8, val, "off"))
                .off
            else if (std.mem.eql(u8, val, "absolute"))
                .absolute
            else if (std.mem.eql(u8, val, "relative"))
                .relative
            else {
                self.setStatus("E474: Invalid argument: lineno={s}", .{val});
                return;
            };
            return;
        }
        if (std.mem.eql(u8, opt, "tabwidth")) {
            const n = std.fmt.parseInt(usize, val, 10) catch 0;
            if (n < 1 or n > max_tab_width) {
                self.setStatus("E474: Invalid argument: tabwidth={s}", .{val});
                return;
            }
            self.tab_width = n;
            return;
        }
        if (std.mem.eql(u8, opt, "expandtab")) {
            self.expand_tab = parseFlag(val) orelse {
                self.setStatus("E474: Invalid argument: expandtab={s}", .{val});
                return;
            };
            return;
        }
        if (std.mem.eql(u8, opt, "whitespace")) {
            self.show_whitespace = parseFlag(val) orelse {
                self.setStatus("E474: Invalid argument: whitespace={s}", .{val});
                return;
            };
            return;
        }
        self.setStatus("E518: Unknown option: {s}", .{opt});
    }

    /// The `:` forms that move the cursor rather than run a command:
    ///
    ///  - `$` / `.`            -- the last / current line
    ///  - `+N` / `-N`          -- N lines down / up (N defaults to 1)
    ///  - `{count}{motion}`    -- a normal-mode motion with a count, so
    ///                            `:23k` moves up 23 lines and `:10l`
    ///                            right 10 characters
    ///
    /// A leading digit is what distinguishes the motion form from a
    /// command, so `:w` / `:q` / `:e` still dispatch normally. Returns
    /// true when `line` was one of these and the cursor has been moved.
    fn commandLineJump(self: *Editor, line: []const u8) bool {
        if (line.len == 0) return false;

        if (std.mem.eql(u8, line, "$")) {
            self.moveTo(motion.gotoLine(&self.buf, self.buf.lineCount() - 1), true);
            return true;
        }
        if (std.mem.eql(u8, line, ".")) {
            self.moveTo(motion.gotoLine(&self.buf, self.buf.lineAt(self.cursor)), true);
            return true;
        }
        if (line[0] == '+' or line[0] == '-') {
            const digits = line[1..];
            const n: usize = if (digits.len == 0)
                1
            else
                std.fmt.parseInt(usize, digits, 10) catch return false;
            const here = self.buf.lineAt(self.cursor);
            const target = if (line[0] == '+') here + n else here -| n;
            self.moveTo(motion.gotoLine(&self.buf, target), true);
            return true;
        }

        var i: usize = 0;
        while (i < line.len and std.ascii.isDigit(line[i])) i += 1;
        if (i == 0 or i == line.len) return false;
        const count = std.fmt.parseInt(usize, line[0..i], 10) catch return false;
        return self.commandLineMotion(line[i..], count);
    }

    /// Runs motion string `m` with `count`, the same motions `command`
    /// dispatches from a bare keystroke. Vertical motions keep the
    /// sticky column. Returns false for an unrecognized motion, so the
    /// caller can fall through to reporting an unknown command.
    fn commandLineMotion(self: *Editor, m: []const u8, count: usize) bool {
        const buf = &self.buf;
        const c = self.cursor;
        const sc = self.sticky_col;
        const eq = std.mem.eql;
        if (eq(u8, m, "j")) {
            self.moveTo(motion.down(buf, c, count, sc, false), false);
        } else if (eq(u8, m, "k")) {
            self.moveTo(motion.up(buf, c, count, sc, false), false);
        } else if (eq(u8, m, "h")) {
            self.moveTo(motion.left(buf, c, count), true);
        } else if (eq(u8, m, "l")) {
            self.moveTo(motion.right(buf, c, count, false), true);
        } else if (eq(u8, m, "w")) {
            self.moveTo(motion.wordForward(buf, c, count, false), true);
        } else if (eq(u8, m, "W")) {
            self.moveTo(motion.wordForward(buf, c, count, true), true);
        } else if (eq(u8, m, "b")) {
            self.moveTo(motion.wordBackward(buf, c, count, false), true);
        } else if (eq(u8, m, "B")) {
            self.moveTo(motion.wordBackward(buf, c, count, true), true);
        } else if (eq(u8, m, "e")) {
            self.moveTo(motion.wordEnd(buf, c, count, false), true);
        } else if (eq(u8, m, "E")) {
            self.moveTo(motion.wordEnd(buf, c, count, true), true);
        } else if (eq(u8, m, "G") or eq(u8, m, "gg")) {
            self.moveTo(motion.gotoLine(buf, count -| 1), true);
        } else {
            return false;
        }
        return true;
    }
};

/// A boolean `:set` value. vim writes these as `:set expandtab` /
/// `:set noexpandtab`, but every option here takes `name=value`, so the
/// spellings are the ones a config file would use. Null is "not a
/// boolean", which the caller turns into E474.
fn parseFlag(val: []const u8) ?bool {
    const yes = [_][]const u8{ "on", "true", "yes", "1" };
    const no = [_][]const u8{ "off", "false", "no", "0" };
    for (yes) |v| if (std.ascii.eqlIgnoreCase(val, v)) return true;
    for (no) |v| if (std.ascii.eqlIgnoreCase(val, v)) return false;
    return null;
}

/// A space or a tab -- the whitespace `J` eats and `<<` gives back.
fn isBlank(b: u8) bool {
    return b == ' ' or b == '\t';
}

fn allDigits(s: []const u8) bool {
    for (s) |c| {
        if (!std.ascii.isDigit(c)) return false;
    }
    return s.len > 0;
}

/// `dw`'s one special case: where a bare `w` would jump to the next line,
/// `dw` stops at the end of the current one, so deleting the last word of
/// a line doesn't pull the next line up onto it.
fn wordTargetForDelete(buf: *const Buffer, cursor: usize, count: usize) usize {
    const target = motion.wordForward(buf, cursor, count, false);
    const line = buf.lineAt(cursor);
    const end = buf.lineEnd(line);
    if (target > end and cursor < end) return end;
    return target;
}
