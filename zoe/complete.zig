// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: GPL-3.0-or-later

//! The completion popup's model: the items a server sent, filtered and
//! ranked against what has been typed since, and which one is selected.
//!
//! Filtering happens here, in the editor, not on the server. A request goes
//! out once when a word starts (or a trigger character is typed); every
//! keystroke after that narrows the list it brought back without another
//! round trip -- unless the server marked its list incomplete, in which case
//! `zoe/ui.zig` asks again. That is what makes typing through an open popup
//! feel instant.
//!
//! Pure -- no client, no server -- so the ranking is tested on its own.

const std = @import("std");
const lsp = @import("lsp.zig");

/// How well an item matched what was typed, best first. The popup sorts by
/// this before the server's own `sortText`, so an exact-case prefix match
/// is never buried under a server's idea of relevance.
pub const Tier = enum(u8) {
    /// The typed text is a prefix, case and all.
    prefix,
    /// A prefix ignoring case (`str` for `String`).
    prefix_nocase,
    /// The typed characters appear in order (`gcl` for `getCellLength`).
    subsequence,
};

/// How `typed` matches `candidate`, or null when it doesn't.
pub fn match(candidate: []const u8, typed: []const u8) ?Tier {
    if (std.mem.startsWith(u8, candidate, typed)) return .prefix;
    if (candidate.len >= typed.len and std.ascii.eqlIgnoreCase(candidate[0..typed.len], typed)) return .prefix_nocase;
    var i: usize = 0;
    for (candidate) |c| {
        if (i == typed.len) break;
        if (std.ascii.toLower(c) == std.ascii.toLower(typed[i])) i += 1;
    }
    return if (i == typed.len) .subsequence else null;
}

/// A short name for an LSP `CompletionItemKind`, for the popup's first
/// column. Blank for 0 (the server didn't say).
pub fn kindLabel(kind: u8) []const u8 {
    const names = [_][]const u8{
        "", "text", "meth", "fn", "ctor", "fld", "var", "class", "iface", "mod",
        "prop", "unit", "val", "enum", "kw", "snip", "color", "file", "ref", "dir",
        "enum", "const", "struct", "event", "op", "type",
    };
    return if (kind < names.len) names[kind] else "";
}

pub const Menu = struct {
    alloc: std.mem.Allocator,
    /// Everything the server sent, owned.
    items: []lsp.CompletionItem,
    /// The server's `isIncomplete`: filtering locally may miss things, so
    /// typing more should ask again.
    incomplete: bool = false,
    /// The buffer byte where the word being completed starts, and the line
    /// it is on. Typed text is `[word_start, cursor)`; leaving the line or
    /// backspacing past the start closes the popup.
    word_start: usize,
    line: usize,
    /// Indices into `items` that match what is typed, best first. Owned.
    matches: std.ArrayList(usize) = .empty,
    /// Index into `matches`.
    selected: usize = 0,
    /// The first `matches` entry shown, for a list longer than the popup.
    top: usize = 0,

    /// Takes ownership of `items`.
    pub fn init(
        alloc: std.mem.Allocator,
        items: []lsp.CompletionItem,
        word_start: usize,
        line: usize,
        incomplete: bool,
    ) Menu {
        return .{
            .alloc = alloc,
            .items = items,
            .word_start = word_start,
            .line = line,
            .incomplete = incomplete,
        };
    }

    pub fn deinit(self: *Menu) void {
        lsp.freeCompletionItems(self.alloc, self.items);
        self.matches.deinit(self.alloc);
    }

    /// Re-ranks against `typed`, putting the selection back on the best
    /// match. An empty `typed` (Ctrl+Space, or right after a `.`) keeps
    /// everything in the server's order.
    pub fn refilter(self: *Menu, typed: []const u8) !void {
        self.matches.clearRetainingCapacity();
        const tiers = try self.alloc.alloc(Tier, self.items.len);
        defer self.alloc.free(tiers);
        for (self.items, 0..) |it, i| {
            const t = match(it.filter, typed) orelse continue;
            tiers[i] = t;
            try self.matches.append(self.alloc, i);
        }
        const Ctx = struct {
            items: []const lsp.CompletionItem,
            tiers: []const Tier,
            fn lessThan(ctx: @This(), a: usize, b: usize) bool {
                const ta = @intFromEnum(ctx.tiers[a]);
                const tb = @intFromEnum(ctx.tiers[b]);
                if (ta != tb) return ta < tb;
                switch (std.mem.order(u8, ctx.items[a].sort, ctx.items[b].sort)) {
                    .lt => return true,
                    .gt => return false,
                    .eq => {},
                }
                // Stable on the server's own order for everything else.
                return a < b;
            }
        };
        std.mem.sort(usize, self.matches.items, Ctx{ .items = self.items, .tiers = tiers }, Ctx.lessThan);
        self.selected = 0;
        self.top = 0;
    }

    pub fn count(self: *const Menu) usize {
        return self.matches.items.len;
    }

    /// The selected item, or null with nothing matching.
    pub fn current(self: *const Menu) ?*const lsp.CompletionItem {
        if (self.selected >= self.matches.items.len) return null;
        return &self.items[self.matches.items[self.selected]];
    }

    /// The item `row` places down from the top of what `rows` shows.
    pub fn visible(self: *const Menu, row: usize) ?*const lsp.CompletionItem {
        const idx = self.top + row;
        if (idx >= self.matches.items.len) return null;
        return &self.items[self.matches.items[idx]];
    }

    /// Moves the selection, wrapping at both ends the way every completion
    /// menu does, and scrolls so it stays within `rows`.
    pub fn move(self: *Menu, delta: i64, rows: usize) void {
        const n = self.matches.items.len;
        if (n == 0) return;
        const cur: i64 = @intCast(self.selected);
        const len: i64 = @intCast(n);
        self.selected = @intCast(@mod(cur + delta, len));
        self.follow(rows);
    }

    /// Scrolls just enough that the selection is on screen.
    pub fn follow(self: *Menu, rows: usize) void {
        if (rows == 0) return;
        if (self.selected < self.top) self.top = self.selected;
        if (self.selected >= self.top + rows) self.top = self.selected + 1 - rows;
    }
};

/// Whether `c` continues an identifier for the purpose of finding where the
/// word under completion starts. Any non-ASCII byte counts, so a Unicode
/// identifier is one word rather than a word boundary per character.
pub fn isWordByte(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c >= 0x80;
}

/// Where the word ending at byte `cursor` of `line` (the line's text up to
/// at least the cursor) begins -- `cursor` itself when the byte before it is
/// not part of a word.
pub fn wordStart(line: []const u8, cursor: usize) usize {
    var i = @min(cursor, line.len);
    while (i > 0 and isWordByte(line[i - 1])) i -= 1;
    return i;
}
