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

/// The three modes this cut implements. vim's "command mode" is what
/// everyone calls normal mode; `command` here is the `:` command *line*,
/// which is its own mode in vim too (cmdline-mode).
///
/// Visual mode, replace mode and operator-pending-as-a-mode are not
/// modelled: operator-pending is a field on `Editor` rather than a mode
/// because nothing outside the state machine needs to see it.
pub const Mode = enum { normal, insert, command };

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
    /// `:q` / `:q!`. `force` is the `!` form, which abandons unsaved
    /// changes; a plain `:q` on a modified buffer never gets this far
    /// (the editor reports E37 and returns `.none` instead).
    quit: struct { force: bool },
    /// `:wq` / `:x` -- write, then quit if the write succeeded.
    write_quit: ?[]const u8,
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

    /// The `:` line being typed, without the leading colon.
    cmdline: std.ArrayList(u8) = .empty,
    /// The argument of the command just run, kept alive so an `Outcome`
    /// can borrow it (see `Outcome.write`).
    cmd_arg: std.ArrayList(u8) = .empty,
    /// The message shown on the status line -- errors, `:w` confirmation.
    status: std.ArrayList(u8) = .empty,
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
        var rest = text;
        while (rest.len > 0) {
            switch (self.mode) {
                .insert => {
                    try self.insertText(rest);
                    return .none;
                },
                .command => {
                    try self.cmdline.appendSlice(self.alloc, rest);
                    return .none;
                },
                .normal => {
                    // One codepoint at a time, re-checking the mode each
                    // round: a command in the middle of a chunk can switch
                    // modes (`ihello` is `i` plus five characters of text),
                    // and the remainder must then be typed, not obeyed.
                    const view = std.unicode.Utf8View.init(rest) catch return .none;
                    var it = view.iterator();
                    const cp = it.nextCodepointSlice() orelse return .none;
                    switch (try self.normalChar(cp)) {
                        .none => {},
                        else => |outcome| return outcome,
                    }
                    rest = rest[cp.len..];
                },
            }
        }
        return .none;
    }

    /// A named physical key (glyphwire's `key_down` notification). Only
    /// the keys with no character to carry them are handled here --
    /// everything printable arrives through `feedText`.
    pub fn feedKey(self: *Editor, key: []const u8, mods: Mods) !Outcome {
        _ = mods;
        const eq = std.mem.eql;
        if (eq(u8, key, "escape")) {
            self.escape();
            return .none;
        }

        switch (self.mode) {
            .normal => {
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
                if (eq(u8, key, "enter")) {
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
            try self.operatorMotion(c);
            return .none;
        }

        return self.command(c);
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
        switch (c) {
            // Motions.
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

            // Edits.
            'x' => try self.deleteRange(self.cursor, motion.right(&self.buf, self.cursor, n, true)),
            'X' => try self.deleteRange(motion.left(&self.buf, self.cursor, n), self.cursor),
            'D' => try self.deleteRange(self.cursor, motion.lineEnd(&self.buf, self.cursor, true)),
            'C' => try self.changeRange(self.cursor, motion.lineEnd(&self.buf, self.cursor, true)),
            's' => try self.changeRange(self.cursor, motion.right(&self.buf, self.cursor, n, true)),
            'd' => {
                self.operator = 'd';
                self.operator_count = n;
            },

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
                if (self.operator) |_| {
                    // `dgg` -- linewise from the target line to the cursor's.
                    self.operator = null;
                    self.operator_count = 0;
                    try self.deleteLines(n - 1, self.buf.lineAt(self.cursor));
                } else {
                    self.moveTo(motion.gotoLine(&self.buf, n - 1), true);
                }
            },
            else => self.resetPending(),
        }
        return .none;
    }

    // ── Operator-pending ────────────────────────────────────────────────

    /// Resolves `d` + a motion. Linewise motions (`dd`, `dj`, `dk`, `dG`,
    /// `dgg`) take whole lines; everything else takes the character range
    /// between where the cursor is and where the motion would have gone.
    fn operatorMotion(self: *Editor, c: u8) !void {
        const motion_count = self.takeCount();
        const n = self.operator_count * motion_count;
        const op = self.operator.?;
        // `g` needs a second character, so hold the operator and wait.
        if (c == 'g') {
            self.prefix = 'g';
            self.count = n;
            return;
        }
        self.operator = null;
        self.operator_count = 0;
        if (op != 'd') return;

        const line = self.buf.lineAt(self.cursor);
        switch (c) {
            // Linewise.
            'd' => try self.deleteLines(line, line + n - 1),
            'j' => try self.deleteLines(line, line + n),
            'k' => try self.deleteLines(line -| n, line),
            'G' => try self.deleteLines(line, self.buf.lineCount() - 1),

            // Charwise, forward.
            'w' => try self.deleteRange(self.cursor, wordTargetForDelete(&self.buf, self.cursor, n)),
            'e' => try self.deleteRange(self.cursor, motion.nextCodepoint(&self.buf, motion.wordEnd(&self.buf, self.cursor, n, false))),
            'l' => try self.deleteRange(self.cursor, motion.right(&self.buf, self.cursor, n, true)),
            '$' => try self.deleteRange(self.cursor, motion.lineEnd(&self.buf, self.cursor, true)),

            // Charwise, backward.
            'b' => try self.deleteRange(motion.wordBackward(&self.buf, self.cursor, n, false), self.cursor),
            'h' => try self.deleteRange(motion.left(&self.buf, self.cursor, n), self.cursor),
            '0' => try self.deleteRange(motion.lineStart(&self.buf, self.cursor), self.cursor),
            '^' => {
                const target = motion.firstNonBlank(&self.buf, self.cursor);
                try self.deleteRange(@min(target, self.cursor), @max(target, self.cursor));
            },
            else => {},
        }
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
    /// position at `lo`.
    fn deleteRange(self: *Editor, lo: usize, hi: usize) !void {
        if (hi <= lo) return;
        try self.buf.delete(lo, hi - lo);
        self.cursor = motion.clampNormal(&self.buf, lo);
        self.syncSticky();
    }

    /// Like `deleteRange`, but leaves the cursor exactly where the
    /// deletion started instead of pulling it back onto a character: the
    /// caller is entering insert mode, where sitting past the line's last
    /// character is legal. `C` at the end of a line would otherwise type
    /// one column left of where it deleted.
    fn changeRange(self: *Editor, lo: usize, hi: usize) !void {
        if (hi > lo) try self.buf.delete(lo, hi - lo);
        self.cursor = @min(lo, self.buf.len());
        self.syncSticky();
        self.mode = .insert;
    }

    /// Linewise delete of `[first, last]`, inclusive. The trailing
    /// newline goes with the lines, except when they run to the end of
    /// the buffer -- there the *leading* newline goes instead, or the
    /// previous line would be left with a phantom blank one after it.
    fn deleteLines(self: *Editor, first: usize, last: usize) !void {
        const line_count = self.buf.lineCount();
        const f = @min(first, line_count - 1);
        const l = @min(last, line_count - 1);
        const start = self.buf.lineStart(f);
        const end = self.buf.lineEnd(l);

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

        const name_end = std.mem.indexOfAny(u8, line, " \t") orelse line.len;
        const name = line[0..name_end];
        const arg = std.mem.trim(u8, line[name_end..], " \t");

        self.cmd_arg.clearRetainingCapacity();
        try self.cmd_arg.appendSlice(self.alloc, arg);
        const arg_opt: ?[]const u8 = if (self.cmd_arg.items.len == 0) null else self.cmd_arg.items;

        const eq = std.mem.eql;
        if (eq(u8, name, "w") or eq(u8, name, "write")) return .{ .write = arg_opt };
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
