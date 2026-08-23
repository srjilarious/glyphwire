const std = @import("std");
const glyphwire = @import("glyphwire");

/// glyphwire-ls: a directory listing built on `lsz`'s core scanning logic
/// (see /home/jeffdw/code/lsz/src/main.zig) but re-targeted to draw over a
/// glyphwire connection instead of ANSI escapes -- the first real-world
/// client meant to be launched from glyphwire-shell's prompt (see
/// shell/main.zig's `runCommand`), to exercise the shell/client path
/// against something more than the styled-text demo. Falls back to a
/// plain newline-per-entry stdout listing (the same content a
/// non-glyphwire `ls` would produce) when no session is available, per
/// decisions.md's Discovery & Connection.
///
/// Deliberately narrower than lsz: no terminal-width grid packing (doesn't
/// mean anything over a fixed-size cell grid), no long-listing
/// permissions/owner/group columns, no per-extension icons (the bundled
/// JetBrainsMono-Regular.ttf isn't Nerd-Font-patched, so those glyphs
/// would just render as tofu) -- directory/symlink/file coloring plus a
/// trailing `/` or ` -> target` covers the same information lsz's
/// coloring conveys. lsz itself stays the terminal tool; this is a
/// demonstration client, not a replacement.
pub fn main(init: std.process.Init) !void {
    const alloc = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    var show_hidden = false;
    var dir_path: []const u8 = ".";
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "-a") or std.mem.eql(u8, arg, "--hidden")) {
            show_hidden = true;
        } else {
            dir_path = arg;
        }
    }

    const entries = try listDir(io, alloc, dir_path, show_hidden);
    defer freeEntries(alloc, entries);

    if (glyphwire.Client.connectFromEnv(io, alloc, init.environ_map)) |connected| {
        var client = connected;
        defer client.deinit();
        try writeGrid(&client, entries);
    } else |_| {
        try writePlain(io, entries);
    }
}

const EntryKind = enum { file, directory, sym_link, other };

const FileEntry = struct {
    name: []const u8,
    kind: EntryKind,
    link_target: ?[]const u8, // non-null for symlinks; caller owns memory
};

fn listDir(io: std.Io, alloc: std.mem.Allocator, dir_path: []const u8, show_hidden: bool) ![]FileEntry {
    var entries: std.ArrayList(FileEntry) = .empty;
    errdefer freeEntries(alloc, entries.items);

    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch |err| {
        std.log.err("glyphwire-ls: cannot open {s}: {t}", .{ dir_path, err });
        return entries.toOwnedSlice(alloc);
    };
    defer dir.close(io);

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (!show_hidden and std.mem.startsWith(u8, entry.name, ".")) continue;

        const kind: EntryKind = switch (entry.kind) {
            .directory => .directory,
            .file => .file,
            .sym_link => .sym_link,
            else => .other,
        };

        var link_target: ?[]const u8 = null;
        if (kind == .sym_link) {
            var target_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            if (dir.readLink(io, entry.name, &target_buf)) |len| {
                link_target = try alloc.dupe(u8, target_buf[0..len]);
            } else |_| {}
        }
        errdefer if (link_target) |t| alloc.free(t);

        const name_copy = try alloc.dupe(u8, entry.name);
        try entries.append(alloc, .{ .name = name_copy, .kind = kind, .link_target = link_target });
    }

    std.mem.sort(FileEntry, entries.items, {}, struct {
        fn lessThan(_: void, a: FileEntry, b: FileEntry) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.lessThan);

    return entries.toOwnedSlice(alloc);
}

fn freeEntries(alloc: std.mem.Allocator, entries: []const FileEntry) void {
    for (entries) |e| {
        alloc.free(e.name);
        if (e.link_target) |t| alloc.free(t);
    }
    alloc.free(entries);
}

// ── Styling ────────────────────────────────────────────────────────────────

fn rgb(r: u8, g: u8, b: u8) glyphwire.Color {
    return .{ .r = r, .g = g, .b = b, .a = 255 };
}

const dir_color = rgb(98, 114, 164);
const symlink_color = rgb(139, 233, 253);
const file_color = rgb(220, 220, 220);

// ── glyphwire output ──────────────────────────────────────────────────────

/// Writes one entry per row starting at the layer's current cursor row,
/// leaving the cursor at the start of the row after the last entry --
/// glyphwire-shell resyncs from `get_property(cursor)` after this process
/// exits (see `Prompt.submitLine`), so there's no fixed row count it needs
/// to guess.
fn writeGrid(client: *glyphwire.Client, entries: []const FileEntry) !void {
    const start = try client.getCursor();
    var row = start.row;

    var buf: [std.Io.Dir.max_path_bytes + 8]u8 = undefined;
    for (entries) |entry| {
        try client.setCursor(row, 0);
        switch (entry.kind) {
            .directory => {
                const text = std.fmt.bufPrint(&buf, "{s}/", .{entry.name}) catch entry.name;
                try client.writeText(text, dir_color, null);
            },
            .sym_link => {
                const text = if (entry.link_target) |tgt|
                    std.fmt.bufPrint(&buf, "{s} -> {s}", .{ entry.name, tgt }) catch entry.name
                else
                    entry.name;
                try client.writeText(text, symlink_color, null);
            },
            else => try client.writeText(entry.name, file_color, null),
        }
        row += 1;
    }

    try client.setCursor(row, 0);
}

fn writePlain(io: std.Io, entries: []const FileEntry) !void {
    var buf: [4096]u8 = undefined;
    var w = std.Io.File.stdout().writer(io, &buf);
    for (entries) |entry| {
        switch (entry.kind) {
            .directory => try w.interface.print("{s}/\n", .{entry.name}),
            .sym_link => if (entry.link_target) |tgt|
                try w.interface.print("{s} -> {s}\n", .{ entry.name, tgt })
            else
                try w.interface.print("{s}\n", .{entry.name}),
            else => try w.interface.print("{s}\n", .{entry.name}),
        }
    }
    try w.interface.flush();
}
