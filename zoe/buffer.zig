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
/// and its new end. `syntax.zig` replays these onto the retained parse
/// tree (`Tree.edit`) so a reparse can reuse it instead of starting from
/// scratch.
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
};

/// Cap on `pending_edits`. Past this the log is cleared and
/// `edits_overflowed` is set: a consumer that sees the flag must do a
/// full reparse rather than trust a partial replay. Sized so a normal
/// burst of typing between frames never trips it.
const max_pending_edits: usize = 512;

pub const Buffer = struct {
    alloc: std.mem.Allocator,
    gap: GapBuffer,
    line_starts: std.ArrayList(usize) = .empty,
    /// Set by every mutation, cleared by `markClean`. `:q` consults it.
    dirty: bool = false,
    /// Bumped by every mutation and never reset. A renderer diffs it
    /// against its last value to tell an edit (repaint everything) from a
    /// pure cursor move or scroll (shift the rows already drawn).
    edits: u64 = 0,

    /// When false, `pending_edits` is not maintained -- there is no
    /// consumer. `ui.zig` sets it once it has a live highlighter.
    track_edits: bool = false,
    /// Mutations applied since the last `clearEdits`, oldest first. Only
    /// populated while `track_edits`. Never allocates otherwise.
    pending_edits: std.ArrayList(Edit) = .empty,
    /// `pending_edits` filled past `max_pending_edits` (or an append
    /// failed) and was dropped; the log no longer accounts for every
    /// change since the last drain.
    edits_overflowed: bool = false,

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
        self.* = undefined;
    }

    pub fn len(self: *const Buffer) usize {
        return self.gap.len();
    }

    pub fn byteAt(self: *const Buffer, i: usize) u8 {
        return self.gap.byteAt(i);
    }

    pub fn markClean(self: *Buffer) void {
        self.dirty = false;
    }

    /// Rebuilds `line_starts` from scratch.
    ///
    /// A full rescan per edit is O(text) where an incremental fixup would
    /// be O(edited line) -- deliberate for now: it is the version that is
    /// obviously correct, and a whole-buffer scan is a few hundred
    /// microseconds on the file sizes zoe opens today. The incremental
    /// version is a contained change behind this one function when a
    /// profile asks for it.
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

    /// The whole buffer as a fresh allocation -- what `:w` hands the
    /// filesystem.
    pub fn text(self: *const Buffer, alloc: std.mem.Allocator) ![]u8 {
        return self.gap.read(alloc, 0, self.len());
    }

    pub fn insert(self: *Buffer, offset: usize, bytes: []const u8) !void {
        if (bytes.len == 0) return;
        const at = @min(offset, self.len());
        const start_point = if (self.track_edits) self.posOf(at) else Pos{};

        try self.gap.insert(at, bytes);
        try self.reindex();
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
    }

    pub fn delete(self: *Buffer, offset: usize, count: usize) !void {
        if (count == 0 or offset >= self.len()) return;
        const del = @min(count, self.len() - offset);
        const start_point = if (self.track_edits) self.posOf(offset) else Pos{};
        const old_end_point = if (self.track_edits) self.posOf(offset + del) else Pos{};

        self.gap.delete(offset, del);
        try self.reindex();
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
    }

    /// Append one edit to the pending log, or trip `edits_overflowed` and
    /// drop the log if it is full (or the append fails). Never returns an
    /// error: a lost edit degrades the highlighter to a full reparse, it
    /// does not fail the mutation.
    fn recordEdit(self: *Buffer, e: Edit) void {
        if (self.edits_overflowed) return;
        if (self.pending_edits.items.len >= max_pending_edits) {
            self.pending_edits.clearRetainingCapacity();
            self.edits_overflowed = true;
            return;
        }
        self.pending_edits.append(self.alloc, e) catch {
            self.pending_edits.clearRetainingCapacity();
            self.edits_overflowed = true;
        };
    }

    /// Drop the pending edit log and clear the overflow flag. The
    /// consumer calls this once it has replayed (or given up on) the
    /// edits for a frame.
    pub fn clearEdits(self: *Buffer) void {
        self.pending_edits.clearRetainingCapacity();
        self.edits_overflowed = false;
    }
};
