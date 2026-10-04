// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: GPL-3.0-or-later

//! The folders a zoe session works in: one for `zoe` / `zoe dir`, several
//! for `zoe dir1 dir2` or `zoe project.code-workspace`.
//!
//! The file format is VS Code's, read rather than imitated: a
//! `.code-workspace` is a JSON object whose `folders` array lists
//! `{"path": ..., "name": ...}` entries, paths relative to the file. That
//! array is the only part zoe reads. `settings`, `extensions`, `launch`
//! and the rest are VS Code's and ignored, and a folder given by `uri`
//! (a remote one) is skipped -- zoe has nowhere to open it from.
//!
//! VS Code writes and accepts JSONC -- `//` and `/* */` comments, and a
//! trailing comma before `]` or `}` -- which `std.json` rejects, so
//! `stripJsonc` blanks both out first. Comments become spaces rather than
//! disappearing so a parse error still points at the right column.
//!
//! zoe never writes the file back. `:addfolder` / `:rmfolder` change the
//! session only: rewriting a hand-edited JSONC file would throw away its
//! comments and layout, and the file is as much VS Code's as zoe's.
//!
//! Pure apart from `load`'s one read, which is what `tests/zoe_tests.zig`
//! leans on.

const std = @import("std");

/// The extension that makes a command-line argument a workspace file
/// rather than a file to edit.
pub const extension = ".code-workspace";

pub const Folder = struct {
    /// Absolute, normalized, owned.
    path: []u8,
    /// The label the sidebar shows on the folder's header row, owned: the
    /// workspace's `name` when it gave one, else the last path component.
    name: []u8,
};

pub const Workspace = struct {
    alloc: std.mem.Allocator,
    /// In the order they were listed, which is the order the sidebar
    /// shows them. Never empty once `parse` / `fromDirs` has returned.
    folders: std.ArrayList(Folder) = .empty,

    pub fn deinit(self: *Workspace) void {
        for (self.folders.items) |f| freeFolder(self.alloc, f);
        self.folders.deinit(self.alloc);
        self.* = undefined;
    }

    /// Adds `path` (resolved against `base`) under `name`, or its last
    /// component when `name` is null. False, and nothing added, when that
    /// folder is already in the list: VS Code drops a duplicate folder
    /// too, and two header rows over the same directory would be two
    /// copies of every row under it.
    pub fn add(self: *Workspace, base: []const u8, path: []const u8, name: ?[]const u8) !bool {
        const abs = try std.fs.path.resolve(self.alloc, &.{ base, path });
        errdefer self.alloc.free(abs);
        if (self.indexOf(abs) != null) {
            self.alloc.free(abs);
            return false;
        }
        const label = try self.alloc.dupe(u8, name orelse defaultName(abs));
        errdefer self.alloc.free(label);
        try self.folders.append(self.alloc, .{ .path = abs, .name = label });
        return true;
    }

    pub fn indexOf(self: *const Workspace, abs: []const u8) ?usize {
        for (self.folders.items, 0..) |f, i| {
            if (std.mem.eql(u8, f.path, abs)) return i;
        }
        return null;
    }
};

fn freeFolder(alloc: std.mem.Allocator, f: Folder) void {
    alloc.free(f.path);
    alloc.free(f.name);
}

/// The last path component, or the path itself for `/`.
pub fn defaultName(abs: []const u8) []const u8 {
    const base = std.fs.path.basename(abs);
    return if (base.len == 0) abs else base;
}

/// Whether a command-line argument names a workspace file.
pub fn isWorkspacePath(path: []const u8) bool {
    return std.mem.endsWith(u8, path, extension);
}

/// A workspace of plain directories, `zoe dir1 dir2`, each resolved
/// against `cwd`. Duplicates collapse.
pub fn fromDirs(alloc: std.mem.Allocator, cwd: []const u8, dirs: []const []const u8) !Workspace {
    var ws: Workspace = .{ .alloc = alloc };
    errdefer ws.deinit();
    for (dirs) |d| _ = try ws.add(cwd, d, null);
    return ws;
}

/// Reads and parses the workspace file at `path`. Relative folder paths
/// in it resolve against the file's own directory, which is how VS Code
/// reads them -- so `"."` is the folder the file sits in.
pub fn load(alloc: std.mem.Allocator, io: std.Io, cwd: []const u8, path: []const u8) !Workspace {
    const text = try std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(1024 * 1024));
    defer alloc.free(text);
    const abs = try std.fs.path.resolve(alloc, &.{ cwd, path });
    defer alloc.free(abs);
    return parse(alloc, text, std.fs.path.dirname(abs) orelse "/");
}

/// What zoe reads out of a `.code-workspace`. Everything else in the file
/// is ignored by `ignore_unknown_fields`.
const FileShape = struct {
    folders: []const struct {
        path: ?[]const u8 = null,
        name: ?[]const u8 = null,
    } = &.{},
};

/// Parses workspace JSONC, resolving relative folder paths against
/// `base_dir`. A file that lists no usable folder is an error: a
/// workspace with nothing in it has no directory to put the sidebar on.
pub fn parse(alloc: std.mem.Allocator, text: []const u8, base_dir: []const u8) !Workspace {
    const json = try alloc.dupe(u8, text);
    defer alloc.free(json);
    stripJsonc(json);

    const parsed = try std.json.parseFromSlice(FileShape, alloc, json, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    var ws: Workspace = .{ .alloc = alloc };
    errdefer ws.deinit();
    for (parsed.value.folders) |f| {
        // A `uri` folder (remote, or a virtual filesystem) has no `path`.
        const p = f.path orelse continue;
        _ = try ws.add(base_dir, p, f.name);
    }
    if (ws.folders.items.len == 0) return error.NoFolders;
    return ws;
}

/// Blanks JSONC's extras out of `text` in place, leaving plain JSON of
/// the same length: comments become spaces (their newlines kept, so line
/// numbers in an error still match), and a comma whose next non-space
/// character is `]` or `}` becomes a space. Nothing inside a string is
/// touched, escapes included.
pub fn stripJsonc(text: []u8) void {
    var i: usize = 0;
    while (i < text.len) {
        const c = text[i];
        if (c == '"') {
            i = skipString(text, i);
        } else if (c == '/' and i + 1 < text.len and text[i + 1] == '/') {
            while (i < text.len and text[i] != '\n') : (i += 1) text[i] = ' ';
        } else if (c == '/' and i + 1 < text.len and text[i + 1] == '*') {
            text[i] = ' ';
            text[i + 1] = ' ';
            i += 2;
            while (i < text.len) : (i += 1) {
                if (text[i] == '*' and i + 1 < text.len and text[i + 1] == '/') {
                    text[i] = ' ';
                    text[i + 1] = ' ';
                    i += 2;
                    break;
                }
                if (text[i] != '\n') text[i] = ' ';
            }
        } else {
            i += 1;
        }
    }

    // A second pass for trailing commas, now that no comment can sit
    // between a comma and its closing bracket.
    i = 0;
    while (i < text.len) {
        const c = text[i];
        if (c == '"') {
            i = skipString(text, i);
            continue;
        }
        if (c == ',') {
            var j = i + 1;
            while (j < text.len and std.ascii.isWhitespace(text[j])) j += 1;
            if (j < text.len and (text[j] == ']' or text[j] == '}')) text[i] = ' ';
        }
        i += 1;
    }
}

/// The index one past the closing quote of the string opening at
/// `start`, or the end of the text for an unterminated one.
fn skipString(text: []const u8, start: usize) usize {
    var i = start + 1;
    while (i < text.len) : (i += 1) {
        switch (text[i]) {
            '\\' => i += 1,
            '"' => return i + 1,
            else => {},
        }
    }
    return text.len;
}
