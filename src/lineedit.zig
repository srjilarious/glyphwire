// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: MPL-2.0

//! A one-line text field -- the readline-ish editing every glyphwire
//! client with somewhere to type ends up hand-rolling: gw-shell's prompt,
//! salacommander's Alt+D path row and its dialog fields, zoe's `:`
//! command line. Home/Ctrl+A, End/Ctrl+E, Ctrl+Left/Right word jumps,
//! Ctrl+Backspace/Ctrl+Delete word rubout, Ctrl+U, Ctrl+K.
//!
//! `LineEdit` owns a byte buffer and a `caret` *byte* offset into it,
//! always on a UTF-8 boundary. The grid a caller draws to is addressed in
//! *display columns* -- and an East Asian wide character is one codepoint,
//! two columns, and (commonly) three UTF-8 bytes -- so the free functions
//! at the bottom convert between the two: arrow movement steps whole
//! codepoints and `caretCol` lands the on-screen caret on the right column
//! even with CJK text on the line.
//!
//! Nothing here draws or does IO. A caller keeps its own rendering (the
//! shell repaints an input box, salacommander inverts a cell, zoe writes
//! its statusline) and calls either the named operations or `handleKey`,
//! which maps a glyphwire key name plus modifiers onto them. `handleKey`
//! deliberately does *not* claim Enter or Escape: it reports them as
//! `.submit` / `.cancel` and leaves the buffer alone, because what they
//! mean is the caller's (run the command, navigate to the path, leave the
//! field) and some callers -- the shell, whose Enter has a completion
//! picker and a scrollback browse mode in front of it -- handle them long
//! before the field sees a key at all.

const std = @import("std");
const core = @import("core.zig");

/// What a key meant, for a caller deciding whether to repaint and what
/// else to do. `.moved` and `.edited` are split because they differ for
/// more than redraw cost: gw-shell keeps its completion picker open
/// across an edit (re-filtering it) but closes it on a deliberate
/// reposition away from the word it was filtering.
pub const Outcome = enum {
    /// Not one of the field's keys -- the caller decides what it means.
    ignored,
    /// The caret moved; the buffer is unchanged.
    moved,
    /// The buffer changed.
    edited,
    /// Enter. The field is untouched; committing is the caller's.
    submit,
    /// Escape. The field is untouched; abandoning it is the caller's.
    cancel,
};

/// What `insert` does with control characters in the text handed to it.
/// Both policies drop the C0 controls and DEL outright -- there is no
/// offset in a single-line field where a `\t` or a `\x07` would mean
/// anything -- and differ only over newlines.
pub const ControlPolicy = enum {
    /// Drop newlines with the rest. For a field holding one value: a
    /// pasted newline in a path or a filename is a mistake, not a space.
    drop,
    /// Replace every maximal run of `\n` / `\r` with a single space. For
    /// a command line, where a multi-line paste -- a column of paths
    /// copied out of a listing, a block from another window -- should
    /// arrive as space-separated words the word-splitter turns into
    /// arguments.
    flatten_newlines,
};

pub const LineEdit = struct {
    /// The line. Owned; `deinit` frees it.
    buf: std.ArrayList(u8) = .empty,
    /// Offset into `buf`, `0..=buf.items.len`, where the next insert or
    /// delete acts and where the on-screen caret belongs. Always on a
    /// UTF-8 boundary -- every operation here produces one, and the only
    /// way to set it directly (`moveTo`) snaps to one.
    caret: usize = 0,
    /// How `insert` sanitizes what it is given. See `ControlPolicy`.
    controls: ControlPolicy = .drop,

    /// An empty field. `controls` defaults to `.drop`; a command line
    /// wanting the other policy sets the field on the literal
    /// (`.{ .controls = .flatten_newlines }`) rather than going through
    /// `init`, which is the convenience for the common case.
    pub const empty: LineEdit = .{};

    /// A field holding `initial`, caret at its end -- the state Alt+D or
    /// a prefilled dialog field starts in. `initial` is copied.
    pub fn init(alloc: std.mem.Allocator, initial: []const u8) !LineEdit {
        var self: LineEdit = .{};
        try self.buf.appendSlice(alloc, initial);
        self.caret = initial.len;
        return self;
    }

    pub fn deinit(self: *LineEdit, alloc: std.mem.Allocator) void {
        self.buf.deinit(alloc);
    }

    /// The line, borrowed -- invalidated by the next edit.
    pub fn text(self: *const LineEdit) []const u8 {
        return self.buf.items;
    }

    pub fn isEmpty(self: *const LineEdit) bool {
        return self.buf.items.len == 0;
    }

    /// Replaces the whole line, caret to the end -- a history recall, or
    /// a completion filling the field in. Unlike `insert` this takes
    /// `new_text` verbatim: it comes from the program, not from a paste.
    pub fn setText(self: *LineEdit, alloc: std.mem.Allocator, new_text: []const u8) !void {
        self.buf.clearRetainingCapacity();
        try self.buf.appendSlice(alloc, new_text);
        self.caret = self.buf.items.len;
    }

    /// Empties the field. Keeps the capacity: the same field is about to
    /// be typed into again.
    pub fn clear(self: *LineEdit) void {
        self.buf.clearRetainingCapacity();
        self.caret = 0;
    }

    // ── Movement ────────────────────────────────────────────────────────
    //
    // Each returns true when the caret actually moved, so a caller can
    // skip a repaint for a Left at column 0. The `*Offset` queries beside
    // them answer "where would this land" without moving, for a caller
    // (gw-shell) whose own reposition path does more than assign -- it
    // also closes a completion picker and snaps the scrollback view back.

    /// Puts the caret at `offset`, clamped to the line and snapped back
    /// to the codepoint boundary at or before it -- a click landing on
    /// the far half of a wide character belongs before it, since there is
    /// no offset inside one.
    pub fn moveTo(self: *LineEdit, offset: usize) bool {
        const clamped = @min(offset, self.buf.items.len);
        const snapped = if (clamped == self.buf.items.len)
            clamped
        else if (isContinuation(self.buf.items[clamped]))
            prevBoundary(self.buf.items, clamped)
        else
            clamped;
        if (snapped == self.caret) return false;
        self.caret = snapped;
        return true;
    }

    pub fn left(self: *LineEdit) bool {
        return self.moveTo(self.prevOffset());
    }

    pub fn right(self: *LineEdit) bool {
        return self.moveTo(self.nextOffset());
    }

    /// Home / Ctrl+A.
    pub fn home(self: *LineEdit) bool {
        return self.moveTo(0);
    }

    /// End / Ctrl+E.
    pub fn end(self: *LineEdit) bool {
        return self.moveTo(self.buf.items.len);
    }

    /// Ctrl+Left.
    pub fn wordLeft(self: *LineEdit) bool {
        return self.moveTo(self.wordLeftOffset());
    }

    /// Ctrl+Right.
    pub fn wordRight(self: *LineEdit) bool {
        return self.moveTo(self.wordRightOffset());
    }

    pub fn prevOffset(self: *const LineEdit) usize {
        return prevBoundary(self.buf.items, self.caret);
    }

    pub fn nextOffset(self: *const LineEdit) usize {
        return nextBoundary(self.buf.items, self.caret);
    }

    pub fn wordLeftOffset(self: *const LineEdit) usize {
        return wordLeftFrom(self.buf.items, self.caret);
    }

    pub fn wordRightOffset(self: *const LineEdit) usize {
        return wordRightFrom(self.buf.items, self.caret);
    }

    // ── Editing ─────────────────────────────────────────────────────────
    //
    // Each returns true when the buffer actually changed. Only `insert`
    // can grow the line, so it is the only one that needs an allocator --
    // the deletes shrink in place.

    /// Inserts `s` at the caret, which ends up past it. `s` is sanitized
    /// per `controls`; inserting text that is *entirely* control
    /// characters changes nothing and returns false.
    pub fn insert(self: *LineEdit, alloc: std.mem.Allocator, s: []const u8) !bool {
        if (s.len == 0) return false;
        const before = self.buf.items.len;

        var i: usize = 0;
        while (i < s.len) {
            // Take the longest run of acceptable bytes at once: a paste
            // is usually clean, and one `insertSlice` for the whole thing
            // beats a byte at a time.
            const run_start = i;
            while (i < s.len and !isControl(s[i])) : (i += 1) {}
            if (i > run_start) {
                try self.buf.insertSlice(alloc, self.caret, s[run_start..i]);
                self.caret += i - run_start;
            }
            if (i >= s.len) break;

            if (isNewline(s[i])) {
                // A whole run at once, so `\r\n\r\n` between two copied
                // paths is one separator rather than four.
                while (i < s.len and isNewline(s[i])) : (i += 1) {}
                if (self.controls == .flatten_newlines) {
                    try self.buf.insert(alloc, self.caret, ' ');
                    self.caret += 1;
                }
            } else {
                i += 1; // Any other control: dropped under both policies.
            }
        }
        return self.buf.items.len != before;
    }

    /// Backspace: deletes the codepoint before the caret.
    pub fn deleteBackward(self: *LineEdit) bool {
        if (self.caret == 0) return false;
        const start = self.prevOffset();
        self.deleteRange(start, self.caret);
        return true;
    }

    /// Delete: deletes the codepoint at the caret.
    pub fn deleteForward(self: *LineEdit) bool {
        if (self.caret >= self.buf.items.len) return false;
        self.deleteRange(self.caret, self.nextOffset());
        return true;
    }

    /// Ctrl+Backspace: deletes the span Ctrl+Left would have jumped over
    /// -- character-class based (see `wordLeftFrom`), so it stops at a
    /// `/` rather than swallowing a whole path the way bash's
    /// whitespace-only `unix-word-rubout` does.
    pub fn deleteWordBackward(self: *LineEdit) bool {
        if (self.caret == 0) return false;
        self.deleteRange(self.wordLeftOffset(), self.caret);
        return true;
    }

    /// Ctrl+Delete: the mirror, over `wordRight`'s span.
    pub fn deleteWordForward(self: *LineEdit) bool {
        if (self.caret >= self.buf.items.len) return false;
        self.deleteRange(self.caret, self.wordRightOffset());
        return true;
    }

    /// Ctrl+U: deletes from the start of the line through the caret.
    pub fn killToStart(self: *LineEdit) bool {
        if (self.caret == 0) return false;
        self.deleteRange(0, self.caret);
        return true;
    }

    /// Ctrl+K: deletes from the caret to the end of the line.
    pub fn killToEnd(self: *LineEdit) bool {
        if (self.caret >= self.buf.items.len) return false;
        self.deleteRange(self.caret, self.buf.items.len);
        return true;
    }

    /// Removes `buf[from..to]` and leaves the caret at `from`. Shrinking,
    /// so it never allocates.
    fn deleteRange(self: *LineEdit, from: usize, to: usize) void {
        self.buf.replaceRangeAssumeCapacity(from, to - from, &.{});
        self.caret = from;
    }

    // ── Key dispatch ────────────────────────────────────────────────────

    /// One key, by glyphwire key name (`"home"`, `"left"`, `"backspace"`)
    /// plus its modifiers. Printable characters are *not* handled here:
    /// they arrive on glyphwire's separate `text` stream -- already
    /// layout-, dead-key- and IME-resolved -- and go through `insert`.
    ///
    /// Any chord carrying alt or super is `.ignored`: those belong to the
    /// program around the field (salacommander's Alt+D, a pane switch),
    /// and swallowing them here would make a field that traps its
    /// application's own shortcuts.
    pub fn handleKey(self: *LineEdit, key: []const u8, mods: core.Mods) Outcome {
        if (mods.alt or mods.super) return .ignored;
        const eq = std.mem.eql;
        const ctrl = mods.ctrl;

        if (eq(u8, key, "enter") or eq(u8, key, "kp_enter")) return .submit;
        if (eq(u8, key, "escape")) return .cancel;

        // Editing first: Ctrl+Backspace and Ctrl+Delete are the word
        // forms of keys that also exist bare, so the modified spellings
        // have to be tested before the plain ones.
        const edited = blk: {
            if (eq(u8, key, "backspace")) break :blk if (ctrl) self.deleteWordBackward() else self.deleteBackward();
            if (eq(u8, key, "delete")) break :blk if (ctrl) self.deleteWordForward() else self.deleteForward();
            if (ctrl and eq(u8, key, "u")) break :blk self.killToStart();
            if (ctrl and eq(u8, key, "k")) break :blk self.killToEnd();
            break :blk null;
        };
        if (edited) |changed| return if (changed) .edited else .ignored;

        const moved = blk: {
            if (eq(u8, key, "left")) break :blk if (ctrl) self.wordLeft() else self.left();
            if (eq(u8, key, "right")) break :blk if (ctrl) self.wordRight() else self.right();
            if (eq(u8, key, "home") or (ctrl and eq(u8, key, "a"))) break :blk self.home();
            if (eq(u8, key, "end") or (ctrl and eq(u8, key, "e"))) break :blk self.end();
            break :blk null;
        };
        if (moved) |changed| return if (changed) .moved else .ignored;

        return .ignored;
    }

    // ── Display ─────────────────────────────────────────────────────────

    /// The caret's offset in grid columns from where the line's text
    /// starts -- what a caller adds to the field's own column to place
    /// the on-screen caret.
    pub fn caretCol(self: *const LineEdit) usize {
        return displayCol(self.buf.items, self.caret);
    }

    /// The whole line's width in grid columns.
    pub fn width(self: *const LineEdit) usize {
        return cellWidth(self.buf.items);
    }
};

// ── Pure UTF-8 / display-width helpers ──────────────────────────────────
//
// Free functions rather than methods: they also serve callers holding a
// plain slice (a completion word, a scrollback row) rather than a field.
// Every `offset` argument is assumed to already sit on a codepoint
// boundary. Invalid UTF-8 degrades to byte-at-a-time rather than looping.

/// True for a UTF-8 continuation byte (`10xxxxxx`) -- the trailing bytes
/// of a multi-byte codepoint, never a boundary.
fn isContinuation(b: u8) bool {
    return b & 0xC0 == 0x80;
}

/// C0 controls and DEL -- never literal content of a single-line field.
fn isControl(b: u8) bool {
    return b < 0x20 or b == 0x7f;
}

fn isNewline(b: u8) bool {
    return b == '\n' or b == '\r';
}

/// Byte offset of the start of the codepoint that ends at `offset` --
/// where a Left arrow or Backspace should move to. Walks back over
/// continuation bytes. Returns 0 when already at the start.
pub fn prevBoundary(buf: []const u8, offset: usize) usize {
    if (offset == 0) return 0;
    var i = @min(offset, buf.len) - 1;
    while (i > 0 and isContinuation(buf[i])) : (i -= 1) {}
    return i;
}

/// Byte offset just past the codepoint that starts at `offset` -- where a
/// Right arrow or forward-Delete boundary sits. Clamps to `buf.len`; a
/// malformed lead byte advances by one so a corrupt buffer can't wedge.
pub fn nextBoundary(buf: []const u8, offset: usize) usize {
    if (offset >= buf.len) return buf.len;
    const len = std.unicode.utf8ByteSequenceLength(buf[offset]) catch 1;
    return @min(offset + len, buf.len);
}

/// Display width, in grid columns, of `buf[0..offset]` -- the caret's
/// column offset from where the line's text starts.
pub fn displayCol(buf: []const u8, offset: usize) usize {
    return core.stringWidth(buf[0..@min(offset, buf.len)]);
}

/// Display width, in grid columns, of the whole slice -- how many cells a
/// run of text occupies once drawn, which is what `insert_cells` /
/// `delete_cells` count in (not bytes).
pub fn cellWidth(text: []const u8) usize {
    return core.stringWidth(text);
}

/// The byte offset `cells` display columns past `start` in `text`, on a
/// UTF-8 boundary and clamped to the end. A click that lands on the far
/// half of a wide character puts the caret before it rather than inside
/// it -- there is no offset inside one.
pub fn offsetAtCol(text: []const u8, start: usize, cells: usize) usize {
    var i = @min(start, text.len);
    var w: usize = 0;
    while (i < text.len) {
        const next = nextBoundary(text, i);
        const cw = core.stringWidth(text[i..next]);
        if (w + cw > cells) break;
        w += cw;
        i = next;
    }
    return i;
}

/// Character classes a Ctrl+Left/Right hop stops at: letters, digits, and
/// underscore are one "word" class (an identifier/filename segment);
/// every other non-whitespace byte is its own "punct" class. So a path
/// separator or a run of operator characters (`/`, `--`, `&&`) is its own
/// stop rather than being swallowed into the surrounding text the way
/// bash's word-jump skips over it silently.
const WordClass = enum { space, word, punct };

fn wordClass(ch: u8) WordClass {
    if (ch == ' ' or ch == '\t') return .space;
    if ((ch >= 'A' and ch <= 'Z') or (ch >= 'a' and ch <= 'z') or (ch >= '0' and ch <= '9') or ch == '_') return .word;
    return .punct;
}

/// The offset a Ctrl+Right hop lands on: past any whitespace right of
/// `cursor`, then past the following run of one `WordClass` -- e.g.
/// `/home/jeff` takes two hops per path segment, one over the `/`, one
/// over the name.
pub fn wordRightFrom(buf: []const u8, cursor: usize) usize {
    var i = @min(cursor, buf.len);
    while (i < buf.len and wordClass(buf[i]) == .space) : (i += 1) {}
    if (i >= buf.len) return i;
    const class = wordClass(buf[i]);
    while (i < buf.len and wordClass(buf[i]) == class) : (i += 1) {}
    return i;
}

/// The offset a Ctrl+Left hop lands on: back past any whitespace left of
/// `cursor`, then back past the preceding run of one `WordClass`.
pub fn wordLeftFrom(buf: []const u8, cursor: usize) usize {
    var i = @min(cursor, buf.len);
    while (i > 0 and wordClass(buf[i - 1]) == .space) : (i -= 1) {}
    if (i == 0) return 0;
    const class = wordClass(buf[i - 1]);
    while (i > 0 and wordClass(buf[i - 1]) == class) : (i -= 1) {}
    return i;
}

/// Every maximal run of `\n` / `\r` in `text` replaced by a single space,
/// as an owned copy (free with `alloc`), for a caller that needs the
/// flattened text itself rather than a field holding it. Narrower than
/// `ControlPolicy.flatten_newlines`, which also drops the other control
/// characters `insert` must not put in a line; this touches newlines
/// only. Text with no newline still comes back as a fresh allocation, so
/// the caller frees unconditionally.
pub fn flattenNewlines(alloc: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.ensureTotalCapacity(alloc, text.len);

    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == '\n' or text[i] == '\r') {
            while (i < text.len and (text[i] == '\n' or text[i] == '\r')) : (i += 1) {}
            try out.append(alloc, ' ');
        } else {
            try out.append(alloc, text[i]);
            i += 1;
        }
    }
    return out.toOwnedSlice(alloc);
}
