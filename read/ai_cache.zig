// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: GPL-3.0-or-later

//! The AI lookup's answer cache: `read.ai-cache.sqlite3` in glyphwire's
//! config directory, next to `read.state.json`.
//!
//! **Keyed by content, not by position.** The key is a SHA-256 over the
//! provider, the model and the exact two messages sent (`ai.Prompt`).
//! That already covers book/page/bubble/highlight/style -- they are all
//! *in* the prompt -- and gets invalidation right for free: change the
//! `ai_prompt` style, toggle neighbour context, pick another model, and
//! the key changes with it. The book/page/block/highlight columns are
//! stored alongside only so the file can be inspected by hand.

const std = @import("std");
const sqlite = @import("sqlite.zig");
const ai = @import("ai.zig");

pub const file_name = "read.ai-cache.sqlite3";

/// A hex SHA-256, the `answers.key` column.
pub const Key = [64]u8;

pub fn key(provider: ai.Provider, model: []const u8, prompt: ai.Prompt) Key {
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    // NUL separators so ("ab", "c") and ("a", "bc") can't collide.
    h.update(@tagName(provider));
    h.update("\x00");
    h.update(model);
    h.update("\x00");
    h.update(prompt.instructions);
    h.update("\x00");
    h.update(prompt.user);
    var digest: [32]u8 = undefined;
    h.final(&digest);
    return std.fmt.bytesToHex(digest, .lower);
}

/// What `put` records beside the answer -- for a human reading the file,
/// not for lookup.
pub const Meta = struct {
    title: []const u8 = "",
    page: usize = 0,
    block: usize = 0,
    highlight: []const u8 = "",
    provider: ai.Provider,
    model: []const u8,
};

pub const Cache = struct {
    db: sqlite.Db,
    get_stmt: sqlite.Stmt,
    put_stmt: sqlite.Stmt,

    /// `path` is a real OS path or `:memory:`. Creates the file and its
    /// table the first time.
    pub fn open(path: [:0]const u8) !Cache {
        var db = try sqlite.Db.open(path, sqlite.OPEN_READWRITE | sqlite.OPEN_CREATE);
        errdefer db.close();
        try db.exec(
            \\CREATE TABLE IF NOT EXISTS answers (
            \\  key TEXT PRIMARY KEY,
            \\  answer TEXT NOT NULL,
            \\  title TEXT, page INTEGER, block INTEGER, highlight TEXT,
            \\  provider TEXT, model TEXT, created INTEGER
            \\);
        );
        const get_stmt = try db.prepare("SELECT answer FROM answers WHERE key = ?1");
        errdefer get_stmt.finalize();
        const put_stmt = try db.prepare(
            "INSERT OR REPLACE INTO answers (key, answer, title, page, block, highlight, provider, model, created) " ++
                "VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, strftime('%s','now'))",
        );
        return .{ .db = db, .get_stmt = get_stmt, .put_stmt = put_stmt };
    }

    pub fn close(self: *Cache) void {
        self.get_stmt.finalize();
        self.put_stmt.finalize();
        self.db.close();
    }

    /// The cached answer for `k`, owned by the caller, or null.
    pub fn get(self: *Cache, alloc: std.mem.Allocator, k: Key) !?[]u8 {
        defer self.get_stmt.reset();
        try self.get_stmt.bindText(1, &k);
        if (!try self.get_stmt.step()) return null;
        return try alloc.dupe(u8, self.get_stmt.columnText(0));
    }

    pub fn put(self: *Cache, k: Key, answer: []const u8, meta: Meta) !void {
        defer self.put_stmt.reset();
        const s = self.put_stmt;
        try s.bindText(1, &k);
        try s.bindText(2, answer);
        try s.bindText(3, meta.title);
        try s.bindInt64(4, @intCast(meta.page));
        try s.bindInt64(5, @intCast(meta.block));
        try s.bindText(6, meta.highlight);
        try s.bindText(7, @tagName(meta.provider));
        try s.bindText(8, meta.model);
        _ = try s.step();
    }
};
