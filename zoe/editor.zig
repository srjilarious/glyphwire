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
const buffer = @import("buffer.zig");
const motion = @import("motion.zig");

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
pub const Mode = enum { normal, insert, command, visual, visual_line };

/// The buffer-pane line-number gutter. `zoe/ui.zig` draws it; the core
/// only carries the setting so `:set lineno=…` can change it at runtime.
/// `off` hides the gutter, `absolute` numbers every line from 1,
/// `relative` shows each line's distance from the caret with the caret's
/// own line still absolute. Defaults to `absolute`; `zoe.conf`'s
/// `line_numbers` overrides it after `init`, the way `page_lines` does.
pub const LineNumbers = enum { off, absolute, relative };

/// Modifier state accompanying a `feedKey` call, matching what
/// glyphwire's `InputListener` reports.
pub const Mods = struct {
    ctrl: bool = false,
    alt: bool = false,
    shift: bool = false,
};

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

    /// Lines a PageDown / PageUp (or Ctrl-D / Ctrl-U) moves the cursor.
    /// vim scrolls close to a full screen, but the editor core has no
    /// viewport to measure, so this is a fixed count -- overridable from
    /// `zoe.conf`'s `page_lines`, which the host writes here after
    /// `init`.
    page_lines: usize = 10,

    /// The buffer-pane line-number gutter -- see `LineNumbers`. Set from
    /// `zoe.conf`'s `line_numbers` after `init`, changed live by
    /// `:set lineno=…`.
    line_numbers: LineNumbers = .absolute,

    /// The `:` line being typed, without the leading colon.
    cmdline: std.ArrayList(u8) = .empty,
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
        var rest = text;
        while (rest.len > 0) {
            switch (self.mode) {
                .insert => {
                    try self.insertText(rest);
                    return self.takeYankPending();
                },
                .command => {
                    try self.cmdline.appendSlice(self.alloc, rest);
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
                } else if (eq(u8, key, "backspace")) {
                    try self.backspace();
                } else if (eq(u8, key, "delete")) {
                    try self.deleteForward();
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
                if (eq(u8, key, "enter")) return self.runCommand();
                if (eq(u8, key, "backspace")) {
                    if (self.cmdline.items.len == 0) {
                        // Backspacing over the `:` itself leaves the mode,
                        // same as vim.
                        self.mode = .normal;
                        return .none;
                    }
                    const keep = prevCodepointIn(self.cmdline.items, self.cmdline.items.len);
                    self.cmdline.shrinkRetainingCapacity(keep);
                }
                return .none;
            },
        }
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
                self.cmdline.clearRetainingCapacity();
            },
            .visual, .visual_line => self.exitVisual(),
        }
    }

    fn resetPending(self: *Editor) void {
        self.count = 0;
        self.operator = null;
        self.operator_count = 0;
        self.prefix = null;
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
            // Paste. The editor can't read the clipboard itself, so the
            // host fetches it and calls `putText`.
            'p', 'P' => return Outcome{ .paste = .{ .after = c == 'p' } },

            ':' => {
                self.mode = .command;
                self.cmdline.clearRetainingCapacity();
            },
            else => {},
        }
        return .none;
    }

    fn prefixedCommand(self: *Editor, prefix: u8, c: u8) !Outcome {
        if (prefix != 'g') return .none;
        const n = self.takeCount();
        switch (c) {
            // `gg`: the first line, or the count'th if one was typed.
            'g' => {
                if (self.operator) |op| {
                    // `dgg` / `ygg` -- linewise from the target line to
                    // the cursor's.
                    self.operator = null;
                    self.operator_count = 0;
                    const first = n - 1;
                    const last = self.buf.lineAt(self.cursor);
                    if (op == 'd') try self.deleteLines(first, last) else if (op == 'y') try self.yankLines(first, last) else return .none;
                    self.yank_pending = true;
                    return .none;
                }
                self.moveTo(motion.gotoLine(&self.buf, n - 1), true);
            },
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
        switch (self.mode) {
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
                return Outcome{ .paste = .{ .after = false } };
            },
            // `:` from visual mode just enters the command line (no
            // `'<,'>` range support yet).
            ':' => {
                self.exitVisual();
                self.mode = .command;
                self.cmdline.clearRetainingCapacity();
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
        if (self.selectionSpan()) |span| try self.removeSpan(span);
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

    // ── Command line ────────────────────────────────────────────────────

    /// Runs whatever is on the `:` line and returns to normal mode.
    /// Everything that touches the filesystem leaves as an `Outcome` for
    /// the host to carry out.
    fn runCommand(self: *Editor) !Outcome {
        self.mode = .normal;
        const line = std.mem.trim(u8, self.cmdline.items, " \t");
        defer self.cmdline.clearRetainingCapacity();
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
        if (eq(u8, name, "cd") or eq(u8, name, "chdir")) return .{ .chdir = arg_opt };
        if (eq(u8, name, "pwd")) return .pwd;
        if (eq(u8, name, "set")) {
            self.applySet(arg_opt);
            return .none;
        }
        if (eq(u8, name, "w") or eq(u8, name, "write")) return .{ .write = arg_opt };
        if (eq(u8, name, "e") or eq(u8, name, "edit")) {
            if (self.buf.dirty) {
                self.setStatus("E37: No write since last change (add ! to override)", .{});
                return .none;
            }
            return .{ .edit = arg_opt };
        }
        if (eq(u8, name, "e!") or eq(u8, name, "edit!")) return .{ .edit = arg_opt };
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

    /// `:set lineno=off|absolute|relative` -- the one option `:set`
    /// understands, driving the buffer-pane line-number gutter. Spaces
    /// around the `=` are tolerated (`:set lineno = relative`). An unknown
    /// option name or value leaves the setting as it was and reports the
    /// matching vim error.
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
        if (!std.mem.eql(u8, opt, "lineno")) {
            self.setStatus("E518: Unknown option: {s}", .{opt});
            return;
        }
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

fn allDigits(s: []const u8) bool {
    for (s) |c| {
        if (!std.ascii.isDigit(c)) return false;
    }
    return s.len > 0;
}

/// Start of the codepoint ending at `end` in a plain byte slice -- the
/// `cmdline` equivalent of `motion.prevCodepoint`, which needs a
/// `Buffer`.
fn prevCodepointIn(s: []const u8, end: usize) usize {
    if (end == 0) return 0;
    var i = end - 1;
    while (i > 0 and s[i] & 0xC0 == 0x80) i -= 1;
    return i;
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
