// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: GPL-3.0-or-later

//! zoe's text storage: a byte-oriented gap buffer plus the line index the
//! editor navigates by.
//!
//! A gap buffer is the right shape for a modal editor because the edit
//! pattern is "many small edits clustered at one point, then a jump":
//! insertion and deletion at the gap are O(1), and only a cursor jump
//! pays to move the gap. Nothing here knows about modes, keys or
//! rendering -- `editor.zig` sits on top and `motion.zig` reads through
//! it -- and nothing here does IO: a `Buffer` is built from bytes the
//! caller already has, so the whole core is testable without a
//! filesystem.
//!
//! Offsets are **byte** offsets into the logical text (the gap is not
//! part of it). Multi-byte UTF-8 is handled by the callers that need to
//! respect codepoint boundaries (`motion.zig`); the buffer itself is
//! byte-transparent, which is also what lets it hold a file it can't
//! decode without corrupting it on save.

const std = @import("std");
const syntax = @import("applib").syntax;

/// A line/column pair. `col` is a **byte** offset within the line, not a
/// display column -- `motion.zig` is what steps it by whole codepoints,
/// and display width (East Asian wide characters) is the renderer's
/// problem, not the model's.
pub const Pos = struct { line: usize = 0, col: usize = 0 };

/// The smallest gap `ensureGap` will leave behind, so a run of single-byte
/// insertions at one point doesn't reallocate on every keystroke.
const min_gap = 64;

pub const GapBuffer = struct {
    alloc: std.mem.Allocator,
    /// Backing store. `buf[gap_start..gap_end]` is the gap and holds no
    /// meaningful bytes; everything else is text, in order.
    buf: []u8,
    gap_start: usize,
    /// Exclusive.
    gap_end: usize,

    pub fn init(alloc: std.mem.Allocator) !GapBuffer {
        return initFrom(alloc, "");
    }

    /// Seeds the buffer with `text` and puts the gap at the end, which is
    /// where a freshly opened file is usually first appended to.
    pub fn initFrom(alloc: std.mem.Allocator, text: []const u8) !GapBuffer {
        const buf = try alloc.alloc(u8, text.len + min_gap);
        @memcpy(buf[0..text.len], text);
        return .{
            .alloc = alloc,
            .buf = buf,
            .gap_start = text.len,
            .gap_end = buf.len,
        };
    }

    pub fn deinit(self: *GapBuffer) void {
        self.alloc.free(self.buf);
        self.* = undefined;
    }

    /// Length of the logical text -- the backing store minus the gap.
    pub fn len(self: *const GapBuffer) usize {
        return self.buf.len - (self.gap_end - self.gap_start);
    }

    pub fn gapLen(self: *const GapBuffer) usize {
        return self.gap_end - self.gap_start;
    }

    /// The text from logical offset `off` up to the gap, or to the end
    /// when `off` is past the gap -- the longest run that is contiguous
    /// in `buf`. Empty at or past the end.
    pub fn chunkAt(self: *const GapBuffer, off: usize) []const u8 {
        if (off >= self.len()) return &.{};
        if (off < self.gap_start) return self.buf[off..self.gap_start];
        return self.buf[off + self.gapLen() ..];
    }

    /// Backing-store index of logical offset `i`. Only meaningful for
    /// `i < len()`.
    fn physical(self: *const GapBuffer, i: usize) usize {
        return if (i < self.gap_start) i else i + self.gapLen();
    }

    pub fn byteAt(self: *const GapBuffer, i: usize) u8 {
        return self.buf[self.physical(i)];
    }

    /// Slides the gap so it begins at logical offset `pos`. The two
    /// branches copy in opposite directions because the source and
    /// destination ranges overlap whenever the move is longer than the
    /// gap itself.
    pub fn moveGapTo(self: *GapBuffer, pos: usize) void {
        const target = @min(pos, self.len());
        if (target == self.gap_start) return;

        if (target < self.gap_start) {
            // Gap moves left: the text it passes over shifts right, to
            // the far end of the gap.
            const n = self.gap_start - target;
            std.mem.copyBackwards(u8, self.buf[self.gap_end - n .. self.gap_end], self.buf[target..self.gap_start]);
            self.gap_start -= n;
            self.gap_end -= n;
        } else {
            // Gap moves right: the text after it shifts left into it.
            const n = target - self.gap_start;
            std.mem.copyForwards(u8, self.buf[self.gap_start..][0..n], self.buf[self.gap_end..][0..n]);
            self.gap_start += n;
            self.gap_end += n;
        }
    }

    /// Grows the backing store so the gap holds at least `n` bytes,
    /// keeping the gap where it currently sits. Doubles rather than
    /// fitting exactly so a long paste or a run of keystrokes amortizes.
    fn ensureGap(self: *GapBuffer, n: usize) !void {
        if (self.gapLen() >= n) return;

        const text_len = self.len();
        const wanted = @max(n, min_gap);
        const new_cap = @max(text_len + wanted, self.buf.len * 2);
        const new_buf = try self.alloc.alloc(u8, new_cap);

        const tail_len = text_len - self.gap_start;
        @memcpy(new_buf[0..self.gap_start], self.buf[0..self.gap_start]);
        @memcpy(new_buf[new_cap - tail_len ..], self.buf[self.gap_end..]);

        self.alloc.free(self.buf);
        self.buf = new_buf;
        self.gap_end = new_cap - tail_len;
    }

    /// Inserts `bytes` so they begin at logical offset `pos` (clamped to
    /// the end of the text).
    pub fn insert(self: *GapBuffer, pos: usize, bytes: []const u8) !void {
        self.moveGapTo(pos);
        try self.ensureGap(bytes.len);
        @memcpy(self.buf[self.gap_start..][0..bytes.len], bytes);
        self.gap_start += bytes.len;
    }

    /// Removes up to `count` bytes starting at `pos`, by swallowing them
    /// into the gap. A `count` past the end of the text deletes what's
    /// there rather than erroring -- every caller would otherwise clamp
    /// it the same way.
    pub fn delete(self: *GapBuffer, pos: usize, count: usize) void {
        const start = @min(pos, self.len());
        self.moveGapTo(start);
        self.gap_end += @min(count, self.len() - start);
    }

    /// Copies the logical range `[start, end)` into `out`, which must be
    /// at least `end - start` long. One or two `@memcpy`s depending on
    /// whether the range straddles the gap.
    pub fn copyRange(self: *const GapBuffer, start: usize, end: usize, out: []u8) void {
        const lo = @min(start, self.len());
        const hi = @min(end, self.len());
        if (hi <= lo) return;

        if (hi <= self.gap_start) {
            @memcpy(out[0 .. hi - lo], self.buf[lo..hi]);
        } else if (lo >= self.gap_start) {
            @memcpy(out[0 .. hi - lo], self.buf[self.physical(lo)..self.physical(hi)]);
        } else {
            const head = self.gap_start - lo;
            @memcpy(out[0..head], self.buf[lo..self.gap_start]);
            @memcpy(out[head .. hi - lo], self.buf[self.gap_end..][0 .. hi - self.gap_start]);
        }
    }

    /// The logical range `[start, end)` as a fresh allocation the caller
    /// owns.
    pub fn read(self: *const GapBuffer, alloc: std.mem.Allocator, start: usize, end: usize) ![]u8 {
        const lo = @min(start, self.len());
        const hi = @max(lo, @min(end, self.len()));
        const out = try alloc.alloc(u8, hi - lo);
        self.copyRange(lo, hi, out);
        return out;
    }
};

/// A gap buffer plus the index of where each line begins -- the shape the
/// editor actually navigates.
///
/// `line_starts` always holds at least one entry (`0`), so an empty
/// buffer is one empty line, matching how every editor counts. A trailing
/// newline therefore means a final empty line exists, which is what makes
/// `G` land where vim puts it.
/// One applied mutation, in the shape tree-sitter's `TSInputEdit` wants:
/// byte offsets and row/column points for the edit's start, its old end
/// and its new end. `toSyntax` hands one to `applib.syntax`, which
/// replays it onto the retained parse tree (`Tree.edit`) so a reparse can
/// reuse it instead of starting from scratch.
///
/// It lives on `Buffer`, not on the highlighter, because only `Buffer`
/// sees each individual mutation -- `editor.zig` routinely issues several
/// per keystroke (an autoindented newline is a delete plus an insert).
pub const Edit = struct {
    start_byte: usize,
    old_end_byte: usize,
    new_end_byte: usize,
    start_point: Pos,
    old_end_point: Pos,
    new_end_point: Pos,
    /// Who made it: `Buffer.author` when it was recorded. A view of a
    /// shared buffer skips its own edits when it catches up with the
    /// others' (`Editor.followEdit`).
    author: u64 = 0,

    /// Where `at` ends up after this edit: unchanged before it, shifted
    /// after it, and inside the replaced span kept as far in as the new
    /// text reaches. An insertion exactly at `at` leaves it in front.
    /// Works on any one coordinate the edit has a start and two ends in
    /// -- bytes, or lines through `mapLine`.
    pub fn mapIn(at: usize, start: usize, old_end: usize, new_end: usize) usize {
        if (at <= start) return at;
        if (at >= old_end) return at - old_end + new_end;
        return start + @min(at - start, new_end - start);
    }

    pub fn mapByte(e: Edit, at: usize) usize {
        return mapIn(at, e.start_byte, e.old_end_byte, e.new_end_byte);
    }

    pub fn mapLine(e: Edit, line: usize) usize {
        return mapIn(line, e.start_point.line, e.old_end_point.line, e.new_end_point.line);
    }

    /// The same edit in the highlighter's own types, which don't know
    /// about `Buffer`.
    pub fn toSyntax(e: Edit) syntax.Edit {
        return .{
            .start_byte = e.start_byte,
            .old_end_byte = e.old_end_byte,
            .new_end_byte = e.new_end_byte,
            .start_point = .{ .line = e.start_point.line, .col = e.start_point.col },
            .old_end_point = .{ .line = e.old_end_point.line, .col = e.old_end_point.col },
            .new_end_point = .{ .line = e.new_end_point.line, .col = e.new_end_point.col },
        };
    }
};

/// Cap on `pending_edits`. Past this the older entries are dropped, and
/// a reader whose mark they were behind finds `editsSince` null: it has
/// to start over (a full reparse, a recount) rather than trust a partial
/// replay. Sized so a normal burst of typing between frames never trips
/// it.
pub const max_pending_edits: usize = 512;

/// One primitive mutation, stored as what it takes to put the text back:
/// at `at`, drop `inserted` bytes and re-insert `removed`. A pure insert
/// has an empty `removed`; a pure delete has `inserted == 0`. `removed`
/// is owned by the record.
///
/// Records are the *primitive* level -- `editor.zig` routinely issues
/// several per command -- so they are gathered into `UndoGroup`s, and a
/// group is the granularity `u` steps by.
const UndoRec = struct {
    at: usize,
    removed: []const u8,
    inserted: usize,
};

/// One `u` step: every mutation between two `undoCheckpoint` calls, plus
/// where the cursor was when the group opened so undoing can put it back.
const UndoGroup = struct {
    recs: std.ArrayList(UndoRec) = .empty,
    cursor: usize = 0,

    fn deinit(self: *UndoGroup, alloc: std.mem.Allocator) void {
        // An insert record's `removed` is the empty literal, not an
        // allocation, so only non-empty ones are the allocator's.
        for (self.recs.items) |r| if (r.removed.len > 0) alloc.free(r.removed);
        self.recs.deinit(alloc);
    }
};

/// How far back `u` can go. Each group holds the text it removed, so this
/// bounds memory as much as history; past it the oldest group is dropped,
/// the way vim's `undolevels` works.
const max_undo_groups: usize = 512;

/// Which stack the open group lands on when it closes, and so whether
/// recording into it also discards the other one. Ordinary editing
/// invalidates any redo history; replaying an undo or a redo must not.
const UndoPhase = enum { normal, undoing, redoing };

pub const Buffer = struct {
    alloc: std.mem.Allocator,
    gap: GapBuffer,
    line_starts: std.ArrayList(usize) = .empty,
    /// Set by every mutation, cleared by `markClean`. `:q` consults it.
    /// Undo and redo recompute it instead: landing back on the save
    /// point (`clean_depth`) clears it.
    dirty: bool = false,
    /// Bumped by every mutation and never reset. A renderer diffs it
    /// against its last value to tell an edit (repaint everything) from a
    /// pure cursor move or scroll (shift the rows already drawn).
    edits: u64 = 0,

    /// When false, `pending_edits` is not maintained -- there is no
    /// reader. `ui.zig` turns it on for every buffer it opens.
    track_edits: bool = false,
    /// The edit journal: the newest mutations, oldest first, numbered by
    /// how many came before them. Several readers follow it at their own
    /// pace -- the highlighter, each view's row counts and cursor -- each
    /// keeping the number it has read up to (a mark) and asking
    /// `editsSince` for the rest; `trimEdits` drops what every reader has
    /// seen. Only populated while `track_edits`.
    pending_edits: std.ArrayList(Edit) = .empty,
    /// How many edits have ever been recorded: the next one's number, and
    /// the mark of a reader that is up to date. `pending_edits[0]` is
    /// number `edit_seq - pending_edits.items.len`.
    edit_seq: u64 = 0,
    /// Stamped on each recorded edit (`Edit.author`). An `Editor` sets it
    /// to its own `Editor.author` before every mutation it makes.
    author: u64 = 0,

    /// Closed undo groups, oldest first; `u` pops from the end.
    undo_stack: std.ArrayList(UndoGroup) = .empty,
    /// Groups undone and not yet redone; Ctrl+R pops from the end.
    /// Discarded by the first mutation of any ordinary edit.
    redo_stack: std.ArrayList(UndoGroup) = .empty,
    /// The group mutations are being recorded into, opened by
    /// `undoCheckpoint` and closed by `closeUndoGroup`. Null between
    /// commands; an insert-mode session deliberately leaves one open so
    /// the whole session is one `u`.
    undo_open: ?UndoGroup = null,
    undo_phase: UndoPhase = .normal,
    /// How many groups `undo_stack` held when the text last matched the
    /// file -- at load (0) or at the last `markClean`. Undoing or redoing
    /// back to exactly that depth makes the buffer clean again. Null once
    /// that state can no longer be reached: an edit made after undoing
    /// past it discards the redo history that led back, and trimming the
    /// stack's oldest group can drop it off the far end.
    clean_depth: ?usize = 0,

    /// The lines closed folds start on, ascending (`zoe/fold.zig`). The
    /// buffer knows nothing about folding; it keeps these here only
    /// because `insert` and `delete` are where lines move, so this is the
    /// one place that can carry each one along with its line -- undo and
    /// redo included, since they replay through the same two calls. A
    /// line deleted outright takes its entry with it.
    closed_folds: std.ArrayList(usize) = .empty,
    /// Bumped whenever `closed_folds` changes, by an edit or by the
    /// editor opening and closing folds, so a renderer can tell that the
    /// rows on screen moved without anything being typed.
    folds_gen: u64 = 0,

    pub fn init(alloc: std.mem.Allocator) !Buffer {
        return initFromText(alloc, "");
    }

    pub fn initFromText(alloc: std.mem.Allocator, contents: []const u8) !Buffer {
        var self: Buffer = .{ .alloc = alloc, .gap = try GapBuffer.initFrom(alloc, contents) };
        errdefer self.gap.deinit();
        try self.reindex();
        return self;
    }

    pub fn deinit(self: *Buffer) void {
        self.gap.deinit();
        self.line_starts.deinit(self.alloc);
        self.pending_edits.deinit(self.alloc);
        self.clearUndo();
        self.undo_stack.deinit(self.alloc);
        self.redo_stack.deinit(self.alloc);
        self.closed_folds.deinit(self.alloc);
        self.* = undefined;
    }

    pub fn len(self: *const Buffer) usize {
        return self.gap.len();
    }

    pub fn byteAt(self: *const Buffer, i: usize) u8 {
        return self.gap.byteAt(i);
    }

    /// The text is what is on disk now. The open undo group is closed
    /// first so the save point falls between two `u` steps -- a save in
    /// the middle of an insert session splits it, and one `u` lands back
    /// on exactly the saved text.
    pub fn markClean(self: *Buffer) void {
        self.closeUndoGroup();
        self.dirty = false;
        self.clean_depth = self.undo_stack.items.len;
    }

    /// Rebuilds `line_starts` from scratch -- once, when the text is
    /// loaded. Edits keep it up to date incrementally (`reindexInsert`,
    /// `reindexDelete`): a rescan per edit was O(text), a byte at a time
    /// through the gap, and showed up as most of a keystroke's input
    /// handling in a 6k-line file.
    fn reindex(self: *Buffer) !void {
        self.line_starts.clearRetainingCapacity();
        try self.line_starts.append(self.alloc, 0);
        var i: usize = 0;
        while (i < self.gap.len()) : (i += 1) {
            if (self.gap.byteAt(i) == '\n') try self.line_starts.append(self.alloc, i + 1);
        }
    }

    pub fn lineCount(self: *const Buffer) usize {
        return self.line_starts.items.len;
    }

    pub fn lineStart(self: *const Buffer, line: usize) usize {
        const idx = @min(line, self.lineCount() - 1);
        return self.line_starts.items[idx];
    }

    /// Offset of the line's terminating newline, or the end of the buffer
    /// for the last line -- i.e. one past the line's last text byte.
    pub fn lineEnd(self: *const Buffer, line: usize) usize {
        const idx = @min(line, self.lineCount() - 1);
        if (idx + 1 < self.lineCount()) return self.line_starts.items[idx + 1] - 1;
        return self.len();
    }

    pub fn lineLen(self: *const Buffer, line: usize) usize {
        return self.lineEnd(line) - self.lineStart(line);
    }

    /// The line containing `offset`, by binary search over `line_starts`
    /// for the last start that is still `<= offset`.
    pub fn lineAt(self: *const Buffer, offset: usize) usize {
        const target = @min(offset, self.len());
        const starts = self.line_starts.items;
        var lo: usize = 0;
        var hi: usize = starts.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (starts[mid] <= target) lo = mid + 1 else hi = mid;
        }
        return lo - 1;
    }

    pub fn posOf(self: *const Buffer, offset: usize) Pos {
        const line = self.lineAt(offset);
        return .{ .line = line, .col = @min(offset, self.len()) - self.lineStart(line) };
    }

    /// The offset of `pos`, with the line clamped to the last line and
    /// the column to that line's length.
    pub fn offsetOf(self: *const Buffer, pos: Pos) usize {
        const line = @min(pos.line, self.lineCount() - 1);
        return self.lineStart(line) + @min(pos.col, self.lineLen(line));
    }

    /// The text of one line, without its newline, as a fresh allocation.
    pub fn lineText(self: *const Buffer, alloc: std.mem.Allocator, line: usize) ![]u8 {
        return self.gap.read(alloc, self.lineStart(line), self.lineEnd(line));
    }

    /// The text as the highlighter reads it: the gap buffer's two runs,
    /// borrowed, with no copy. Valid until the next mutation, and
    /// pointing at this `Buffer` -- which must not move while it is held.
    pub fn textSource(self: *const Buffer) syntax.TextSource {
        return .{ .reader = .{ .ctx = self, .len = self.len(), .chunk_fn = readChunk } };
    }

    fn readChunk(ctx: *const anyopaque, off: usize) []const u8 {
        const self: *const Buffer = @ptrCast(@alignCast(ctx));
        return self.gap.chunkAt(off);
    }

    /// The whole buffer as a fresh allocation -- what `:w` hands the
    /// filesystem.
    pub fn text(self: *const Buffer, alloc: std.mem.Allocator) ![]u8 {
        return self.gap.read(alloc, 0, self.len());
    }

    /// The byte range `[start, end)` as a fresh allocation the caller
    /// owns -- what a yank / cut hands the clipboard.
    pub fn read(self: *const Buffer, alloc: std.mem.Allocator, start: usize, end: usize) ![]u8 {
        return self.gap.read(alloc, start, end);
    }

    pub fn insert(self: *Buffer, offset: usize, bytes: []const u8) !void {
        if (bytes.len == 0) return;
        const at = @min(offset, self.len());
        const start_point = if (self.track_edits) self.posOf(at) else Pos{};
        // Before the text changes: `lineAt` clamps to the current length.
        const line = self.lineAt(at);

        // Grow the index first, so a failed allocation leaves both it and
        // the text as they were.
        try self.reindexInsert(line, at, bytes);
        errdefer self.reindex() catch {};
        try self.gap.insert(at, bytes);
        self.shiftFoldsInsert(line, at == self.line_starts.items[line], std.mem.count(u8, bytes, "\n"));
        self.dirty = true;
        self.edits += 1;

        if (self.track_edits) self.recordEdit(.{
            .start_byte = at,
            .old_end_byte = at,
            .new_end_byte = at + bytes.len,
            .start_point = start_point,
            .old_end_point = start_point,
            .new_end_point = self.posOf(at + bytes.len),
        });
        self.recordUndo(at, "", bytes.len);
    }

    pub fn delete(self: *Buffer, offset: usize, count: usize) !void {
        if (count == 0 or offset >= self.len()) return;
        const del = @min(count, self.len() - offset);
        const start_point = if (self.track_edits) self.posOf(offset) else Pos{};
        const old_end_point = if (self.track_edits) self.posOf(offset + del) else Pos{};

        // Read before the cut, not after: the undo record *is* the text
        // about to disappear, and this is the only place it still exists.
        const removed = try self.gap.read(self.alloc, offset, offset + del);
        errdefer self.alloc.free(removed);

        // Before the text changes: `lineAt` clamps to the current length.
        const first_line = self.lineAt(offset);
        const last_line = self.lineAt(offset + del);
        self.shiftFoldsDelete(
            first_line,
            last_line,
            offset == self.lineStart(first_line) and offset + del == self.lineStart(last_line),
            offset == self.lineStart(first_line),
        );
        self.reindexDelete(first_line, last_line, del);
        self.gap.delete(offset, del);
        self.dirty = true;
        self.edits += 1;

        if (self.track_edits) self.recordEdit(.{
            .start_byte = offset,
            .old_end_byte = offset + del,
            .new_end_byte = offset,
            .start_point = start_point,
            .old_end_point = old_end_point,
            .new_end_point = start_point,
        });
        self.recordUndo(offset, removed, 0);
    }

    /// `line_starts` after inserting `bytes` at `at`, which lies on `line`:
    /// every later line moves down by the insert's length, and each
    /// newline in `bytes` starts a new line right after it. O(lines after
    /// the insert) for the shift -- a pass of additions -- with no scan of
    /// the text.
    fn reindexInsert(self: *Buffer, line: usize, at: usize, bytes: []const u8) !void {
        const newlines = std.mem.count(u8, bytes, "\n");
        try self.line_starts.ensureUnusedCapacity(self.alloc, newlines);
        for (self.line_starts.items[line + 1 ..]) |*start| start.* += bytes.len;
        if (newlines == 0) return;

        var new_starts = try self.alloc.alloc(usize, newlines);
        defer self.alloc.free(new_starts);
        var n: usize = 0;
        for (bytes, 0..) |c, i| {
            if (c != '\n') continue;
            new_starts[n] = at + i + 1;
            n += 1;
        }
        self.line_starts.insertSliceAssumeCapacity(line + 1, new_starts);
    }

    /// `line_starts` after deleting `del` bytes starting on line
    /// `first_line`, the deleted range ending on `last_line`: the lines
    /// whose newline was cut (starts in `first_line + 1 ..= last_line`)
    /// are gone, and every later line moves up by `del`. Can't fail --
    /// the list only shrinks.
    fn reindexDelete(self: *Buffer, first_line: usize, last_line: usize, del: usize) void {
        const removed = last_line - first_line;
        self.line_starts.replaceRangeAssumeCapacity(first_line + 1, removed, &.{});
        for (self.line_starts.items[first_line + 1 ..]) |*start| start.* -= del;
    }

    /// `closed_folds` after `newlines` line breaks were inserted on
    /// `line`: every fold below it moves down by that many, and so does
    /// one on `line` itself when the insert went in at its very start
    /// (`at_start`), since that pushes the whole line down.
    fn shiftFoldsInsert(self: *Buffer, line: usize, at_start: bool, newlines: usize) void {
        if (newlines == 0 or self.closed_folds.items.len == 0) return;
        for (self.closed_folds.items) |*f| {
            if (f.* > line or (f.* == line and at_start)) f.* += newlines;
        }
        self.folds_gen += 1;
    }

    /// `closed_folds` after a delete from `first` through `last` (the
    /// lines its two ends are on). A fold on a line whose start was cut
    /// goes with it -- the line was deleted or joined onto the one above.
    /// The exceptions are where the cut ran from the start of `first`
    /// to the start of `last` (`whole_lines`, which is `dd`): then
    /// `first` itself went, and `last` survives intact as the new
    /// `first`. `from_start` says the cut began at `first`'s start, so a
    /// fold there loses its line even when the cut ends mid-line.
    fn shiftFoldsDelete(self: *Buffer, first: usize, last: usize, whole_lines: bool, from_start: bool) void {
        if (last == first or self.closed_folds.items.len == 0) return;
        const removed = last - first;
        var i: usize = 0;
        while (i < self.closed_folds.items.len) {
            const f = &self.closed_folds.items[i];
            if (f.* > last) {
                f.* -= removed;
            } else if (f.* == last and whole_lines) {
                f.* = first;
            } else if (f.* > first or (f.* == first and from_start)) {
                _ = self.closed_folds.orderedRemove(i);
                continue;
            }
            i += 1;
        }
        self.folds_gen += 1;
    }

    /// Appends one edit to the journal, dropping the older entries first
    /// when it is full. Never returns an error: an edit the journal loses
    /// costs its readers a fresh start (`editsSince` goes null for them),
    /// it does not fail the mutation.
    fn recordEdit(self: *Buffer, edit: Edit) void {
        var e = edit;
        e.author = self.author;
        self.edit_seq += 1;
        if (self.pending_edits.items.len >= max_pending_edits) self.pending_edits.clearRetainingCapacity();
        self.pending_edits.append(self.alloc, e) catch self.pending_edits.clearRetainingCapacity();
    }

    /// The journal number of the oldest edit still held.
    pub fn journalStart(self: *const Buffer) u64 {
        return self.edit_seq - self.pending_edits.items.len;
    }

    /// The edits after `mark` (a number `edit_seq` once was), oldest
    /// first, or null when some of them were dropped: the reader has to
    /// start over from the text as it is.
    pub fn editsSince(self: *const Buffer, mark: u64) ?[]const Edit {
        if (mark < self.journalStart() or mark > self.edit_seq) return null;
        return self.pending_edits.items[@intCast(mark - self.journalStart())..];
    }

    /// Drops the edits before number `upto`: every reader has read them.
    pub fn trimEdits(self: *Buffer, upto: u64) void {
        const start = self.journalStart();
        if (upto <= start) return;
        const n: usize = @intCast(@min(upto - start, self.pending_edits.items.len));
        const items = self.pending_edits.items;
        std.mem.copyForwards(Edit, items[0 .. items.len - n], items[n..]);
        self.pending_edits.shrinkRetainingCapacity(items.len - n);
    }

    /// Drops the whole journal: whoever reads it next starts over.
    pub fn clearEdits(self: *Buffer) void {
        self.pending_edits.clearRetainingCapacity();
    }

    // ── Undo ────────────────────────────────────────────────────────────
    //
    // The buffer records, `editor.zig` decides where the steps fall. Every
    // mutation lands in the currently open group; `undoCheckpoint` is what
    // starts a new one, and the editor calls it once per command. Insert
    // mode is the interesting case: it checkpoints when insert mode is
    // *entered* and not again until it is left, so a whole typing session
    // is one `u`, which is what vim does.
    //
    // Allocation failure anywhere in here drops history rather than
    // corrupting it: a `u` that does nothing is recoverable, a `u` that
    // replays half a group is not.

    /// Opens a fresh undo group, closing whatever was open. `cursor` is
    /// where undoing this group should put the cursor back.
    pub fn undoCheckpoint(self: *Buffer, cursor: usize) void {
        self.closeUndoGroup();
        self.undo_open = .{ .cursor = cursor };
    }

    /// Ends the open group, pushing it onto whichever stack the current
    /// phase names. An empty group is thrown away rather than becoming a
    /// `u` that does nothing.
    pub fn closeUndoGroup(self: *Buffer) void {
        var g = self.undo_open orelse return;
        self.undo_open = null;
        if (g.recs.items.len == 0) {
            g.deinit(self.alloc);
            return;
        }
        const stack = if (self.undo_phase == .undoing) &self.redo_stack else &self.undo_stack;
        if (stack.items.len >= max_undo_groups) {
            var oldest = stack.orderedRemove(0);
            oldest.deinit(self.alloc);
            // The undo stack's oldest group leads out of depth 0, so every
            // depth above it slides down one and depth 0 is gone. The redo
            // stack's oldest is its far end; the check below covers that.
            if (stack == &self.undo_stack) {
                if (self.clean_depth) |d| self.clean_depth = if (d == 0) null else d - 1;
            }
        }
        stack.append(self.alloc, g) catch {
            g.deinit(self.alloc);
            // A group that never landed leaves the depths miscounted.
            self.clean_depth = null;
        };
        if (self.clean_depth) |d| {
            if (d > self.undo_stack.items.len + self.redo_stack.items.len) self.clean_depth = null;
        }
    }

    /// True while a group is open, so the editor can tell "this mutation
    /// continues the command in progress" from "this one starts a new
    /// step" -- see `Editor.putText`.
    pub fn hasOpenUndoGroup(self: *const Buffer) bool {
        return self.undo_open != null;
    }

    pub fn canUndo(self: *const Buffer) bool {
        if (self.undo_stack.items.len > 0) return true;
        const g = self.undo_open orelse return false;
        return g.recs.items.len > 0;
    }

    pub fn canRedo(self: *const Buffer) bool {
        return self.redo_stack.items.len > 0;
    }

    /// Reverses the newest undo group and returns where the cursor
    /// belongs, or null when there is nothing left to undo.
    pub fn undo(self: *Buffer) !?usize {
        self.closeUndoGroup();
        if (self.undo_stack.pop()) |popped| {
            var group = popped;
            defer group.deinit(self.alloc);
            try self.replay(&group, .undoing);
            self.settleDirty();
            return group.cursor;
        }
        return null;
    }

    /// Re-applies the newest undone group. Null when the redo stack is
    /// empty -- including after any ordinary edit, which discards it.
    pub fn redo(self: *Buffer) !?usize {
        self.closeUndoGroup();
        if (self.redo_stack.pop()) |popped| {
            var group = popped;
            defer group.deinit(self.alloc);
            try self.replay(&group, .redoing);
            self.settleDirty();
            return group.cursor;
        }
        return null;
    }

    /// Throws away all undo history -- `:e`, or an allocation failure
    /// that would otherwise leave the log unable to account for the text.
    pub fn clearUndo(self: *Buffer) void {
        if (self.undo_open) |*g| g.deinit(self.alloc);
        self.undo_open = null;
        self.dropUndoStack(&self.undo_stack);
        self.dropUndoStack(&self.redo_stack);
        self.clean_depth = null;
    }

    /// After an undo or redo: clean exactly when it landed on the save
    /// point. The replayed group was closed, so `undo_stack`'s length is
    /// the whole of where the history stands.
    fn settleDirty(self: *Buffer) void {
        self.dirty = self.clean_depth != self.undo_stack.items.len;
    }

    /// Applies `group`'s records backwards, each one inverted, with a
    /// fresh group open to catch the inverse. That recorded inverse is
    /// what lands on the opposite stack, which is why undo and redo need
    /// no separate machinery: redoing is undoing the undo.
    fn replay(self: *Buffer, group: *UndoGroup, phase: UndoPhase) !void {
        // Where the *inverse* group should land the cursor: at the start
        // of the first change it makes, which is vim's rule for both.
        const back_to = if (group.recs.items.len > 0) group.recs.items[0].at else group.cursor;
        self.undo_phase = phase;
        self.undo_open = .{ .cursor = back_to };
        defer {
            self.closeUndoGroup();
            self.undo_phase = .normal;
        }

        var i = group.recs.items.len;
        while (i > 0) {
            i -= 1;
            const r = group.recs.items[i];
            if (r.inserted > 0) try self.delete(r.at, r.inserted);
            if (r.removed.len > 0) try self.insert(r.at, r.removed);
        }
    }

    /// Adds one primitive mutation to the open group, taking ownership of
    /// `removed`. Opens a group first if none is (a mutation the editor
    /// didn't checkpoint for still belongs somewhere).
    fn recordUndo(self: *Buffer, at: usize, removed: []const u8, inserted: usize) void {
        if (self.undo_open == null) self.undo_open = .{ .cursor = at };
        // An ordinary edit invalidates the redo history. A replay is what
        // *rebuilds* the opposite stack, so it must leave both alone. A
        // save point out in the redo history goes with it.
        if (self.undo_phase == .normal and self.redo_stack.items.len > 0) {
            if (self.clean_depth) |d| {
                if (d > self.undo_stack.items.len) self.clean_depth = null;
            }
            self.dropUndoStack(&self.redo_stack);
        }

        self.undo_open.?.recs.append(self.alloc, .{
            .at = at,
            .removed = removed,
            .inserted = inserted,
        }) catch {
            if (removed.len > 0) self.alloc.free(removed);
            self.clearUndo();
        };
    }

    fn dropUndoStack(self: *Buffer, stack: *std.ArrayList(UndoGroup)) void {
        for (stack.items) |*g| g.deinit(self.alloc);
        stack.clearRetainingCapacity();
    }
};
