// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: GPL-3.0-or-later

//! One open file's text and everything that follows the text rather
//! than a way of looking at it: the buffer with its undo history and
//! edit journal, the parse tree and its colour cache, what the language
//! servers have been told, the disk stamp, the unsaved-change backup.
//!
//! A tab (`Ui.Slot`) is a view of one document: its own `Editor`
//! (cursor, mode, selection, search) over the document's buffer, its
//! own scroll position and render cache. Several tabs, in several
//! groups, can show one document, each scrolled and placed on its own;
//! an edit in one reaches the others through the buffer's journal
//! (`Ui.syncViews`). The document is freed with the last tab showing it
//! (`refs`), and that is also when the language servers hear `didClose`
//! and a `zoe --wait` waiter is let go.
//!
//! The same split is what more than one person editing in one zoe would
//! need: a view per person over the one document.

const std = @import("std");
const syntax = @import("applib").syntax;
const Buffer = @import("buffer.zig").Buffer;
const SpanCache = @import("spancache.zig").SpanCache;
const diskwatch = @import("diskwatch.zig");
const remote = @import("remote.zig");

pub const Document = struct {
    buf: Buffer,
    /// How many tabs show this document. The last one to close frees it.
    refs: usize = 1,
    /// Scratch for `Ui.trimJournals`: the oldest journal entry some
    /// reader of this document still needs. Meaningless between calls.
    journal_floor: u64 = 0,

    /// This document's own tree-sitter state -- null when highlighting is
    /// off entirely, or when no grammar matched its extension. Kept for
    /// as long as the document is open, so a tab switch doesn't throw a
    /// parse tree away.
    hl: ?syntax.Highlighter = null,
    /// The `Buffer.edits` value `hl`'s tree reflects; a mismatch in
    /// `renderBuffer` triggers a reparse.
    hl_edits: u64 = 0,
    /// How far into the edit journal `hl` has read (`Buffer.editsSince`).
    hl_mark: u64 = 0,
    /// `hl`'s spans for the lines painted so far, kept in step with the
    /// buffer by `syncHighlight` and filled per frame by `fillSpanCache`.
    /// Shared by every view: the colours are the text's, not the pane's.
    spans: SpanCache = .{},

    /// The `Buffer.edits` value the language servers have been told about.
    /// A mismatch arms the `didChange` debounce -- deliberately a separate
    /// watermark from `hl_edits` rather than a reader of the journal.
    lsp_sent_edits: u64 = 0,
    /// The LSP document version to send next. Monotonic per document, as
    /// the protocol requires; a server uses it to discard a stale reply.
    lsp_version: i64 = 1,
    /// Whether `didOpen` has been sent for this document. A scratch
    /// buffer with no path never is, and neither is one whose extension
    /// no configured server claims.
    lsp_opened: bool = false,
    /// The path resolved to an absolute one, owned, filled on first use
    /// (`Ui.slotAbs`). The diagnostic store is keyed by absolute path, and
    /// the sign column asks it a question per visible row per frame --
    /// resolving the cwd that many times a frame is the kind of cost that
    /// only shows up as the editor feeling slightly heavy. Invalidated by
    /// whatever changes the path.
    abs_path: ?[]u8 = null,

    /// The file's size and mtime as of zoe's last read or write of it --
    /// what `Ui.checkDisk` compares against to notice a change made
    /// outside zoe. Null for a scratch buffer, or a `[New]` one until its
    /// first `:w`. `disk_warned` is the changed stamp already reported
    /// for a modified buffer, so it is reported once, not every poll.
    disk: ?diskwatch.Stamp = null,
    disk_warned: ?diskwatch.Stamp = null,
    /// The file was on disk and the last check found it gone
    /// (`diskwatch.gone`): its tabs carry `tabs.gone_mark`. Cleared when
    /// it comes back or a `:w` writes it again.
    gone: bool = false,

    /// The name, in the backup directory, of this document's backup
    /// (`zoe/backup.zig`), owned. Null when it has none on disk. A
    /// document freed with one keeps the file: that is what brings unsaved
    /// edits back after `:q`.
    backup_name: ?[]u8 = null,
    /// `buf.edits` when the backup was last written. A mismatch on a
    /// modified buffer is a backup that has fallen behind.
    backup_edits: u64 = 0,
    /// An untitled buffer's id in its backup's name, random, so the
    /// backup keeps one name across writes and sessions.
    backup_id: ?u64 = null,
    /// A backup that doesn't match the file on disk any more, waiting on
    /// recover / discard / split (`Ui.recoverKey`), owned. While set the
    /// backup is left untouched.
    pending_backup: ?[]u8 = null,
    /// Another running zoe has this file open with unsaved edits: its
    /// backup is that zoe's, and this one never writes or deletes it.
    backup_foreign: bool = false,
    /// `zoe --wait` clients that opened this file from the shell panel
    /// (`zoe/remote.zig`): each connection is closed when the last tab
    /// showing it is, which is what lets them exit. Owned.
    waiters: std.ArrayList(i32) = .empty,

    pub fn create(alloc: std.mem.Allocator, text: []const u8) !*Document {
        const doc = try alloc.create(Document);
        errdefer alloc.destroy(doc);
        doc.* = .{ .buf = try Buffer.initFromText(alloc, text) };
        return doc;
    }

    pub fn destroy(self: *Document, alloc: std.mem.Allocator) void {
        for (self.waiters.items) |fd| remote.close(fd);
        self.waiters.deinit(alloc);
        if (self.hl) |*h| h.deinit();
        self.spans.deinit(alloc);
        if (self.abs_path) |p| alloc.free(p);
        if (self.backup_name) |n| alloc.free(n);
        if (self.pending_backup) |t| alloc.free(t);
        self.buf.deinit();
        alloc.destroy(self);
    }
};
