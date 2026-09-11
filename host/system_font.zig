//! Resolving a `host.conf` `font_face` / `font_fallback` value that names
//! a system-installed font family ("DejaVu Sans Mono", "monospace") rather
//! than a file. Done by shelling out to `fc-match` -- fontconfig's CLI,
//! present on any Linux desktop -- which turns a pattern into the file it
//! lives in plus, for a `.ttc`/`.otc` collection, the face index inside it.
//!
//! Engine-free (`std` only), so it lives in `host_support` and its pure
//! helpers are unit-tested in `tests/host_tests.zig` without spawning
//! anything. `host/main.zig` calls `resolve` as the last link of its font
//! lookup chain (see `resolveFontFile` there).

const std = @import("std");

/// A system font located by `fc-match`: the file it lives in (an `arena`
/// copy, process-lifetime) and, for a `.ttc`/`.otc` collection, the face
/// index fontconfig resolved. `index` is 0 for a plain single-face file.
pub const Match = struct {
    path: [:0]const u8,
    index: i32,
};

/// The four fields `fc-match` prints under `output_format` below, split
/// out for `nameSatisfiesRequest` to judge. All slices point into the
/// `fc-match` output buffer the caller still owns.
pub const RawMatch = struct {
    file: []const u8,
    family: []const u8,
    fullname: []const u8,
    index: i32,
};

/// `fc-match -f` template: file, family, full name, face index, one per
/// `|`, newline-terminated. `%{index}` is 0 for a plain `.ttf`/`.otf`.
pub const output_format = "%{file}|%{family}|%{fullname}|%{index}\n";

/// fontconfig's built-in generic aliases. A `host.conf` `font_face =
/// "monospace"` is a deliberate "whatever the system's default monospace
/// is", so `fc-match`'s answer is accepted even though the resolved family
/// name ("Noto Sans Mono", say) won't contain the word "monospace".
pub fn isGenericAlias(request: []const u8) bool {
    const aliases = [_][]const u8{
        "monospace", "mono",
        "sans-serif", "sans",
        "serif",
        "system-ui",
        "cursive",
        "fantasy",
        "emoji",
        "math",
    };
    for (aliases) |a| {
        if (std.ascii.eqlIgnoreCase(request, a)) return true;
    }
    return false;
}

/// Parses the first line of `fc-match -f output_format` output. Returns
/// null when the line doesn't carry the four `|`-separated fields (an old
/// fontconfig that doesn't know a token, an error printed to stdout, an
/// empty result).
pub fn parseFcMatchOutput(out: []const u8) ?RawMatch {
    const line_end = std.mem.indexOfScalar(u8, out, '\n') orelse out.len;
    const line = out[0..line_end];

    var it = std.mem.splitScalar(u8, line, '|');
    const file = it.next() orelse return null;
    const family = it.next() orelse return null;
    const fullname = it.next() orelse return null;
    const index_str = it.next() orelse return null;
    if (it.next() != null) return null; // more than four fields

    if (file.len == 0) return null;
    const index = std.fmt.parseInt(i32, std.mem.trim(u8, index_str, " \t\r"), 10) catch 0;
    return .{ .file = file, .family = family, .fullname = fullname, .index = index };
}

/// True when `fc-match` actually found the font that was asked for rather
/// than silently falling back to the system default -- fontconfig never
/// fails a match, so this is the only signal that the request landed. A
/// generic alias (`isGenericAlias`) always counts; otherwise the resolved
/// `family` or `fullname` must contain `request` once both sides are
/// lower-cased and stripped of spaces and hyphens, so "JetBrainsMono"
/// satisfies a "JetBrains Mono" family and vice versa.
pub fn nameSatisfiesRequest(request: []const u8, family: []const u8, fullname: []const u8) bool {
    if (isGenericAlias(request)) return true;

    var req_buf: [128]u8 = undefined;
    const req = normalizeName(&req_buf, request) orelse return false;
    if (req.len == 0) return false;

    var buf: [512]u8 = undefined;
    if (normalizeName(&buf, family)) |fam| {
        if (std.mem.indexOf(u8, fam, req) != null) return true;
    }
    if (normalizeName(&buf, fullname)) |full| {
        if (std.mem.indexOf(u8, full, req) != null) return true;
    }
    return false;
}

/// Lower-cases `name` into `buf` and drops ASCII spaces and hyphens.
/// Returns the written slice, or null when `name` doesn't fit `buf` (the
/// caller then treats it as "no match" rather than comparing a truncated
/// prefix).
fn normalizeName(buf: []u8, name: []const u8) ?[]const u8 {
    var n: usize = 0;
    for (name) |c| {
        if (c == ' ' or c == '-') continue;
        if (n == buf.len) return null;
        buf[n] = std.ascii.toLower(c);
        n += 1;
    }
    return buf[0..n];
}

/// Runs `fc-match` for `request` and returns the resolved file + face
/// index, or null when `fc-match` is missing, errors, or only offered an
/// unrelated fallback (see `nameSatisfiesRequest`). Never returns an
/// error: a system-font lookup that can't be made is just "not found", and
/// `host/main.zig` falls back to the bundled default face for the slot.
/// `arena` owns the returned path (process-lifetime); `gpa` is transient
/// (the `fc-match` output buffers).
pub fn resolve(arena: std.mem.Allocator, gpa: std.mem.Allocator, io: std.Io, request: []const u8) ?Match {
    const res = std.process.run(gpa, io, .{
        .argv = &.{ "fc-match", "-f", output_format, request },
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
    }) catch |err| {
        std.log.warn("glyphwire-host: fc-match for font '{s}' could not run ({t}); using the bundled default", .{ request, err });
        return null;
    };
    defer gpa.free(res.stdout);
    defer gpa.free(res.stderr);

    if (!res.term.success()) {
        std.log.warn("glyphwire-host: fc-match for font '{s}' {f}; using the bundled default", .{ request, res.term });
        return null;
    }

    const raw = parseFcMatchOutput(res.stdout) orelse {
        std.log.warn("glyphwire-host: couldn't parse fc-match output for font '{s}'; using the bundled default", .{request});
        return null;
    };

    if (!nameSatisfiesRequest(request, raw.family, raw.fullname)) {
        // fontconfig handed back its default, not the font asked for.
        return null;
    }

    const path = std.mem.concatWithSentinel(arena, u8, &.{raw.file}, 0) catch return null;
    return .{ .path = path, .index = raw.index };
}
