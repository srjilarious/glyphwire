// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: GPL-3.0-or-later

//! The folders a zoe session works in: one for `zoe` / `zoe dir`, several
//! for `zoe dir1 dir2`, `zoe project.code-workspace` or
//! `zoe project.zoe-workspace`.
//!
//! Two file formats, told apart by extension:
//!
//! - VS Code's `.code-workspace`, read rather than imitated: a JSON object
//!   whose `folders` array lists `{"path": ..., "name": ...}` entries,
//!   paths relative to the file. That array is the only part zoe reads.
//!   `settings`, `extensions`, `launch` and the rest are VS Code's and
//!   ignored, and a folder given by `uri` (a remote one) is skipped --
//!   zoe has nowhere to open it from. zoe never writes one: rewriting a
//!   hand-edited JSONC file would throw away its comments and layout, and
//!   the file is as much VS Code's as zoe's.
//!
//! - zoe's own `.zoe-workspace`, which `:wssave` writes and `:wsopen` and
//!   the command line read: `{"version": 1, "folders": [...], "theme": ...}`
//!   with the same folder entries, plus an optional theme name that
//!   overrides zoe's usual choice (`zoe.conf.lua`'s `theme`, else the
//!   window's). zoe owns every key in it, so writing it back loses
//!   nothing but hand-added comments.
//!
//! VS Code writes and accepts JSONC -- `//` and `/* */` comments, and a
//! trailing comma before `]` or `}` -- which `std.json` rejects, so
//! `stripJsonc` blanks both out first, for either format. Comments become
//! spaces rather than disappearing so a parse error still points at the
//! right column.
//!
//! `:addfolder` / `:rmfolder` change the session only; a `:wssave`
//! afterwards is what puts them in a file.
//!
//! Pure apart from `load`'s one read and `save`'s one write, which is
//! what `tests/zoe_tests.zig` leans on.

const std = @import("std");

/// VS Code's workspace extension: read, never written.
pub const extension = ".code-workspace";
/// zoe's own workspace extension, what `:wssave` writes.
pub const zoe_extension = ".zoe-workspace";
/// The `version` `serialize` writes. A file with a higher one came from
/// a newer zoe and is refused rather than half-read.
pub const format_version: u32 = 1;

pub const Format = enum { vscode, zoe };

/// Which workspace format `path` is, by extension, or null when it isn't
/// a workspace file at all.
pub fn formatOf(path: []const u8) ?Format {
    if (std.mem.endsWith(u8, path, extension)) return .vscode;
    if (std.mem.endsWith(u8, path, zoe_extension)) return .zoe;
    return null;
}

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
    /// A `.zoe-workspace`'s `theme`, owned: the theme to open it in, by
    /// name. Null when the file gave none (and always for VS Code's
    /// format), which leaves zoe's usual choice alone.
    theme: ?[]u8 = null,
    /// A `.zoe-workspace`'s `editors`: the editor groups to bring back,
    /// with their tabs. Null when the file had none (and always for VS
    /// Code's format), which opens the usual single empty group.
    editors: ?Editors = null,

    pub fn deinit(self: *Workspace) void {
        for (self.folders.items) |f| freeFolder(self.alloc, f);
        self.folders.deinit(self.alloc);
        if (self.theme) |t| self.alloc.free(t);
        if (self.editors) |*e| e.arena.deinit();
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

// ── Editor groups ───────────────────────────────────────────────────────
//
// The `editors` key mirrors zoe's group layout (zoe/groups.zig): a binary
// tree whose leaves are editor groups and whose inner nodes are splits.
//
//     "editors": {
//       "split": "vertical", "ratio": 0.4,
//       "first":  { "files": ["src/main.zig"], "active": 0 },
//       "second": { "split": "horizontal", "ratio": 0.5,
//                   "first":  { "files": ["a.zig", "b.zig"], "active": 1,
//                               "focused": true },
//                   "second": { "files": [] } } }
//
// A node with `split` is a split, anything else a group. `ratio` is the
// first child's share of the split's width (vertical) or height
// (horizontal). File paths follow the folders' rule (see `serialize`).

/// Which way a saved split lays out its halves, in `zoe/groups.zig`'s
/// terms: `vertical` is `:vsplit`, side by side.
pub const Orientation = enum { vertical, horizontal };

pub const EditorNode = union(enum) {
    group: EditorGroup,
    split: EditorSplit,
};

pub const EditorGroup = struct {
    /// Absolute paths, in tab order. Empty for a group that only held
    /// scratch buffers, which comes back with one.
    files: []const []const u8 = &.{},
    /// Which of `files` is the shown tab.
    active: usize = 0,
    /// Whether this group had the keyboard. At most one should; when none
    /// does, focus stays where zoe's startup puts it.
    focused: bool = false,
};

pub const EditorSplit = struct {
    orientation: Orientation,
    /// The first child's share of the split, kept inside `min_ratio ..
    /// 1 - min_ratio` so neither half comes back too small to grab.
    ratio: f32 = 0.5,
    first: *const EditorNode,
    second: *const EditorNode,
};

pub const min_ratio: f32 = 0.05;

/// A parsed `editors` tree and the arena that owns every node and path
/// in it.
pub const Editors = struct {
    arena: std.heap.ArenaAllocator,
    root: *const EditorNode,
};

/// Deeper than any layout anyone builds by hand, and shallow enough that
/// a hostile or corrupt file can't recurse the parser off the stack.
const max_editor_depth = 32;

/// Reads an `editors` value into `arena`, resolving file paths against
/// `base_dir`. A malformed node is an error rather than skipped: there is
/// no sensible shape to fill a hole in a split with.
fn parseEditorNode(arena: std.mem.Allocator, v: std.json.Value, base_dir: []const u8, depth: usize) !*const EditorNode {
    if (depth > max_editor_depth) return error.EditorsTooDeep;
    const obj = switch (v) {
        .object => |o| o,
        else => return error.BadEditors,
    };
    const node = try arena.create(EditorNode);
    if (obj.get("split")) |split_v| {
        const name = switch (split_v) {
            .string => |s| s,
            else => return error.BadEditors,
        };
        const orientation = std.meta.stringToEnum(Orientation, name) orelse return error.BadEditors;
        const ratio: f32 = if (obj.get("ratio")) |r| switch (r) {
            .float => |f| @floatCast(f),
            .integer => |i| @floatFromInt(i),
            else => return error.BadEditors,
        } else 0.5;
        node.* = .{ .split = .{
            .orientation = orientation,
            .ratio = std.math.clamp(ratio, min_ratio, 1 - min_ratio),
            .first = try parseEditorNode(arena, obj.get("first") orelse return error.BadEditors, base_dir, depth + 1),
            .second = try parseEditorNode(arena, obj.get("second") orelse return error.BadEditors, base_dir, depth + 1),
        } };
        return node;
    }

    var files: std.ArrayList([]const u8) = .empty;
    if (obj.get("files")) |files_v| {
        const arr = switch (files_v) {
            .array => |a| a,
            else => return error.BadEditors,
        };
        for (arr.items) |f| switch (f) {
            .string => |s| try files.append(arena, try std.fs.path.resolve(arena, &.{ base_dir, s })),
            else => return error.BadEditors,
        };
    }
    const active: usize = if (obj.get("active")) |a| switch (a) {
        .integer => |i| if (i < 0) 0 else @intCast(i),
        else => return error.BadEditors,
    } else 0;
    const focused = if (obj.get("focused")) |f| switch (f) {
        .bool => |b| b,
        else => return error.BadEditors,
    } else false;
    node.* = .{ .group = .{
        .files = files.items,
        .active = @min(active, files.items.len -| 1),
        .focused = focused,
    } };
    return node;
}

/// What `serialize` writes for one node. Every field optional so a split
/// writes only split keys and a group only group keys.
const EditorShapeOut = struct {
    split: ?Orientation = null,
    ratio: ?f32 = null,
    first: ?*const EditorShapeOut = null,
    second: ?*const EditorShapeOut = null,
    files: ?[]const []const u8 = null,
    active: ?usize = null,
    focused: ?bool = null,
};

fn editorShape(arena: std.mem.Allocator, file_dir: []const u8, node: *const EditorNode) !*const EditorShapeOut {
    const out = try arena.create(EditorShapeOut);
    switch (node.*) {
        .split => |s| out.* = .{
            .split = s.orientation,
            .ratio = std.math.clamp(s.ratio, min_ratio, 1 - min_ratio),
            .first = try editorShape(arena, file_dir, s.first),
            .second = try editorShape(arena, file_dir, s.second),
        },
        .group => |g| {
            const files = try arena.alloc([]const u8, g.files.len);
            for (g.files, files) |f, *o| o.* = try storedPath(arena, file_dir, f);
            out.* = .{
                .files = files,
                .active = g.active,
                // Only the focused group says so; `false` everywhere else
                // would just be noise.
                .focused = if (g.focused) true else null,
            };
        },
    }
    return out;
}

fn freeFolder(alloc: std.mem.Allocator, f: Folder) void {
    alloc.free(f.path);
    alloc.free(f.name);
}

/// The last path component, or the path itself for `/`.
pub fn defaultName(abs: []const u8) []const u8 {
    const base = std.fs.path.basename(abs);
    return if (base.len == 0) abs else base;
}

/// Whether a command-line argument names a workspace file, in either
/// format.
pub fn isWorkspacePath(path: []const u8) bool {
    return formatOf(path) != null;
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
    // Anything not named `.zoe-workspace` reads as VS Code's: that was
    // the only format before zoe had one of its own.
    return parse(alloc, text, std.fs.path.dirname(abs) orelse "/", formatOf(path) orelse .vscode);
}

const FolderShape = struct {
    path: ?[]const u8 = null,
    name: ?[]const u8 = null,
};

/// What zoe reads out of a `.code-workspace`. Everything else in the file
/// is ignored by `ignore_unknown_fields`.
const VscodeShape = struct {
    folders: []const FolderShape = &.{},
};

/// A `.zoe-workspace` as read. Unknown keys are ignored too, so a file a
/// later zoe wrote at the same `version` (with something optional added)
/// still opens. `editors` is walked by hand (`parseEditorNode`): it is a
/// recursive shape, and a path in it needs resolving anyway.
const ZoeShapeIn = struct {
    version: u32 = format_version,
    folders: []const FolderShape = &.{},
    theme: ?[]const u8 = null,
    editors: ?std.json.Value = null,
};

/// A `.zoe-workspace` as written.
const ZoeShapeOut = struct {
    version: u32,
    folders: []const FolderShape,
    theme: ?[]const u8,
    editors: ?*const EditorShapeOut,
};

/// Parses workspace JSONC in `format`, resolving relative folder paths
/// against `base_dir`. A file that lists no usable folder is an error: a
/// workspace with nothing in it has no directory to put the sidebar on.
pub fn parse(alloc: std.mem.Allocator, text: []const u8, base_dir: []const u8, format: Format) !Workspace {
    const json = try alloc.dupe(u8, text);
    defer alloc.free(json);
    stripJsonc(json);

    var ws: Workspace = .{ .alloc = alloc };
    errdefer ws.deinit();
    switch (format) {
        .vscode => {
            const parsed = try std.json.parseFromSlice(VscodeShape, alloc, json, .{ .ignore_unknown_fields = true });
            defer parsed.deinit();
            try addFolders(&ws, base_dir, parsed.value.folders);
        },
        .zoe => {
            const parsed = try std.json.parseFromSlice(ZoeShapeIn, alloc, json, .{ .ignore_unknown_fields = true });
            defer parsed.deinit();
            if (parsed.value.version > format_version) return error.UnsupportedVersion;
            try addFolders(&ws, base_dir, parsed.value.folders);
            if (parsed.value.theme) |t| {
                if (t.len > 0) ws.theme = try alloc.dupe(u8, t);
            }
            if (parsed.value.editors) |v| {
                var arena = std.heap.ArenaAllocator.init(alloc);
                errdefer arena.deinit();
                const root = try parseEditorNode(arena.allocator(), v, base_dir, 0);
                ws.editors = .{ .arena = arena, .root = root };
            }
        },
    }
    if (ws.folders.items.len == 0) return error.NoFolders;
    return ws;
}

fn addFolders(ws: *Workspace, base_dir: []const u8, folders: []const FolderShape) !void {
    for (folders) |f| {
        // A `uri` folder (remote, or a virtual filesystem) has no `path`.
        const p = f.path orelse continue;
        _ = try ws.add(base_dir, p, f.name);
    }
}

/// A folder as `serialize` takes it: borrowed, `path` absolute.
pub const FolderSpec = struct {
    path: []const u8,
    name: []const u8,
};

/// Everything `:wssave` writes, borrowed.
pub const Snapshot = struct {
    folders: []const FolderSpec,
    /// The editor's own theme, or null when it follows the window's.
    theme: ?[]const u8 = null,
    editors: ?*const EditorNode = null,
};

/// The `.zoe-workspace` text for `snap`, for a file in `file_dir`
/// (absolute). Each path -- folder or open file -- is written relative to
/// `file_dir` when that takes at most one `..` (the folder the file sits
/// in, one under it, or a sibling of it), so a project's workspace file
/// still works after the project moves. Anything further away is written
/// absolute, since `../../../usr/src` says less than `/usr/src` and
/// breaks as soon as the file moves anyway. A `name` is written only
/// when it isn't the folder's last component, which is what reading it
/// back would default to. A null `theme` or `editors` leaves the key out.
pub fn serialize(alloc: std.mem.Allocator, file_dir: []const u8, snap: Snapshot) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const out_folders = try arena.alloc(FolderShape, snap.folders.len);
    for (snap.folders, out_folders) |f, *o| {
        o.* = .{
            .path = try storedPath(arena, file_dir, f.path),
            .name = if (std.mem.eql(u8, f.name, defaultName(f.path))) null else f.name,
        };
    }
    const shape: ZoeShapeOut = .{
        .version = format_version,
        .folders = out_folders,
        .theme = snap.theme,
        .editors = if (snap.editors) |e| try editorShape(arena, file_dir, e) else null,
    };
    const json = try std.json.Stringify.valueAlloc(arena, shape, .{
        .whitespace = .indent_2,
        .emit_null_optional_fields = false,
    });
    // A trailing newline, like every other text file zoe writes.
    return std.mem.concat(alloc, u8, &.{ json, "\n" });
}

/// How `serialize` writes `abs` for a file in `file_dir`: see there.
fn storedPath(arena: std.mem.Allocator, file_dir: []const u8, abs: []const u8) ![]const u8 {
    const rel = try std.fs.path.relativeAlloc(arena, file_dir, null, file_dir, abs);
    if (rel.len == 0) return ".";
    var ups: usize = 0;
    var it = std.mem.splitScalar(u8, rel, std.fs.path.sep);
    while (it.next()) |part| {
        if (std.mem.eql(u8, part, "..")) ups += 1;
    }
    return if (ups <= 1) rel else abs;
}

/// Writes `serialize`'s text for `snap` to `path` (resolved against `cwd`), adding
/// `.zoe-workspace` when the name has no workspace extension. Returns the
/// absolute path written, owned by the caller: where a bare `:wssave`
/// writes next time. A `.code-workspace` target is refused, since that
/// file is VS Code's (see the note at the top).
pub fn save(
    alloc: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    path: []const u8,
    snap: Snapshot,
) ![]u8 {
    const format = formatOf(path);
    if (format == .vscode) return error.VscodeWorkspace;
    const named = if (format == null)
        try std.mem.concat(alloc, u8, &.{ path, zoe_extension })
    else
        try alloc.dupe(u8, path);
    defer alloc.free(named);
    const abs = try std.fs.path.resolve(alloc, &.{ cwd, named });
    errdefer alloc.free(abs);

    const text = try serialize(alloc, std.fs.path.dirname(abs) orelse "/", snap);
    defer alloc.free(text);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = abs, .data = text });
    return abs;
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
