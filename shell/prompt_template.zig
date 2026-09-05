//! Pure template engine for glyphwire-shell's configurable prompt.
//!
//! `shell.conf` (see `shell/config.zig`) can set `prompt.left` / `prompt.right`
//! strings; this module turns one of those strings, plus the shell's live
//! state (`Data`), into an ordered list of draw ops (`Op`): literal text
//! runs and icon placements. `shell/main.zig`'s `Prompt.writePromptPrefix`
//! walks that list, emitting `write_text` for text and `draw_icon` for icons.
//!
//! No libc, no IO, no glyphwire import -- it's string math, unit-tested in
//! `tests/prompt_template_tests.zig`. Column widths are counted in UTF-8
//! codepoints (every codepoint one column); a CJK-wide glyph in a prompt is
//! rare enough that the right-aligned section's placement being off by a
//! column in that case is acceptable.
//!
//! ## Token syntax
//!
//! `{name}` interpolates a field. `{{` is a literal `{`. `\n` `\t` `\\` in
//! the template are unescaped. An unrecognized `{name}` is left verbatim so
//! a typo is visible rather than silently dropped.
//!
//! Fields:
//!   - `{cwd}`       working directory, `$HOME` collapsed to `~`
//!   - `{cwd_full}`  working directory, absolute
//!   - `{user}`      `$USER`
//!   - `{host}`      hostname
//!   - `{icon:NAME}` a bundled icon by registry name (e.g. `distro-arch`)
//!   - `{exit}`      expands to the `exit` sub-template, but only when the
//!                   last external command exited non-zero; empty otherwise
//!   - `{dur}`       expands to the `dur` sub-template, but only when the
//!                   last external command ran for at least `dur_min_ms`
//!   - `{exit_code}` the numeric last exit status -- meant for use inside
//!                   the `exit` sub-template
//!   - `{duration}`  the humanized last-command wall time -- meant for use
//!                   inside the `dur` sub-template

const std = @import("std");

/// One thing to draw, in order. `text` runs are already unescaped and have
/// their fields interpolated; `icon` carries an icon-registry name. Both
/// slices are owned by the enclosing `Rendered.arena`.
pub const Op = union(enum) {
    text: []const u8,
    icon: []const u8,
};

/// The shell state a template renders against. All string fields default to
/// empty so a caller can fill in only what it has.
pub const Data = struct {
    cwd: []const u8 = "",
    cwd_full: []const u8 = "",
    user: []const u8 = "",
    host: []const u8 = "",

    /// The last external command's exit status, and whether one has run at
    /// all this session. `{exit}` stays empty until `have_status` is true.
    last_status: u8 = 0,
    have_status: bool = false,

    /// The last external command's wall-clock run time. `{dur}` renders its
    /// sub-template only when this is `>= dur_min_ms`.
    last_dur_ms: u64 = 0,
    dur_min_ms: u64 = 2000,

    /// Sub-template `{exit}` expands to, rendered only on a non-zero status.
    /// `null` (nothing set in shell.conf) means `{exit}` is always empty.
    exit_section: ?[]const u8 = null,
    /// Sub-template `{dur}` expands to, rendered only past the threshold.
    /// `null` means `{dur}` is always empty.
    dur_section: ?[]const u8 = null,
};

/// The result of `render`: an owned op list plus the arena backing every
/// slice in it. Call `deinit` when done.
pub const Rendered = struct {
    arena: std.heap.ArenaAllocator,
    ops: []const Op,

    pub fn deinit(self: *Rendered) void {
        self.arena.deinit();
    }
};

/// Guards `{exit}`/`{dur}` sub-template recursion -- a section that
/// references its own trigger token (`exit` containing `{exit}`) would
/// otherwise loop forever, since the data that made it fire is unchanged.
const max_depth = 4;

/// Renders `template` against `data` into an ordered op list. Only fails on
/// allocation failure; an unrecognized token is emitted as literal text,
/// not an error.
pub fn render(gpa: std.mem.Allocator, template: []const u8, data: Data) error{OutOfMemory}!Rendered {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    var ops: std.ArrayList(Op) = .empty;
    var pending: std.ArrayList(u8) = .empty;

    try renderInto(a, &ops, &pending, template, data, 0);
    try flushPending(a, &ops, &pending);

    return .{ .arena = arena, .ops = try ops.toOwnedSlice(a) };
}

/// Appends the accumulated literal text (if any) as one `text` op, then
/// clears the buffer. Adjacent text stays merged this way -- only an icon
/// breaks a run.
fn flushPending(a: std.mem.Allocator, ops: *std.ArrayList(Op), pending: *std.ArrayList(u8)) !void {
    if (pending.items.len == 0) return;
    try ops.append(a, .{ .text = try a.dupe(u8, pending.items) });
    pending.clearRetainingCapacity();
}

fn renderInto(
    a: std.mem.Allocator,
    ops: *std.ArrayList(Op),
    pending: *std.ArrayList(u8),
    template: []const u8,
    data: Data,
    depth: usize,
) error{OutOfMemory}!void {
    if (depth >= max_depth) return;

    var i: usize = 0;
    while (i < template.len) {
        const ch = template[i];

        if (ch == '\\' and i + 1 < template.len) {
            switch (template[i + 1]) {
                'n' => try pending.append(a, '\n'),
                't' => try pending.append(a, '\t'),
                '\\' => try pending.append(a, '\\'),
                else => {
                    // Not a recognized escape -- keep both bytes as typed.
                    try pending.append(a, '\\');
                    try pending.append(a, template[i + 1]);
                },
            }
            i += 2;
            continue;
        }

        if (ch == '{') {
            if (i + 1 < template.len and template[i + 1] == '{') {
                try pending.append(a, '{');
                i += 2;
                continue;
            }
            const close = std.mem.indexOfScalarPos(u8, template, i + 1, '}') orelse {
                // No closing brace -- treat the `{` as an ordinary byte.
                try pending.append(a, '{');
                i += 1;
                continue;
            };
            const token = template[i + 1 .. close];
            try expandToken(a, ops, pending, token, data, depth);
            i = close + 1;
            continue;
        }

        if (ch == '}' and i + 1 < template.len and template[i + 1] == '}') {
            try pending.append(a, '}');
            i += 2;
            continue;
        }

        try pending.append(a, ch);
        i += 1;
    }
}

fn expandToken(
    a: std.mem.Allocator,
    ops: *std.ArrayList(Op),
    pending: *std.ArrayList(u8),
    token: []const u8,
    data: Data,
    depth: usize,
) error{OutOfMemory}!void {
    if (std.mem.startsWith(u8, token, "icon:")) {
        const name = token["icon:".len..];
        if (name.len == 0) {
            try appendLiteralToken(a, pending, token);
            return;
        }
        try flushPending(a, ops, pending);
        try ops.append(a, .{ .icon = try a.dupe(u8, name) });
        return;
    }

    if (std.mem.eql(u8, token, "cwd")) {
        try pending.appendSlice(a, data.cwd);
    } else if (std.mem.eql(u8, token, "cwd_full")) {
        try pending.appendSlice(a, data.cwd_full);
    } else if (std.mem.eql(u8, token, "user")) {
        try pending.appendSlice(a, data.user);
    } else if (std.mem.eql(u8, token, "host")) {
        try pending.appendSlice(a, data.host);
    } else if (std.mem.eql(u8, token, "exit_code")) {
        var buf: [8]u8 = undefined;
        try pending.appendSlice(a, std.fmt.bufPrint(&buf, "{d}", .{data.last_status}) catch "");
    } else if (std.mem.eql(u8, token, "duration")) {
        var buf: [24]u8 = undefined;
        try pending.appendSlice(a, formatDuration(&buf, data.last_dur_ms));
    } else if (std.mem.eql(u8, token, "exit")) {
        if (data.have_status and data.last_status != 0) {
            if (data.exit_section) |section| {
                try renderInto(a, ops, pending, section, data, depth + 1);
            }
        }
    } else if (std.mem.eql(u8, token, "dur")) {
        if (data.dur_min_ms > 0 and data.last_dur_ms >= data.dur_min_ms) {
            if (data.dur_section) |section| {
                try renderInto(a, ops, pending, section, data, depth + 1);
            }
        }
    } else {
        // Unknown token -- pass it through verbatim so a typo is visible.
        try appendLiteralToken(a, pending, token);
    }
}

fn appendLiteralToken(a: std.mem.Allocator, pending: *std.ArrayList(u8), token: []const u8) !void {
    try pending.append(a, '{');
    try pending.appendSlice(a, token);
    try pending.append(a, '}');
}

/// Humanizes a millisecond duration: `450ms`, `1.5s`, `2m3s`, `1h4m`.
pub fn formatDuration(buf: []u8, ms: u64) []const u8 {
    if (ms < 1000) return std.fmt.bufPrint(buf, "{d}ms", .{ms}) catch "";
    const total_s = ms / 1000;
    if (total_s < 60) {
        const tenths = (ms % 1000) / 100;
        return std.fmt.bufPrint(buf, "{d}.{d}s", .{ total_s, tenths }) catch "";
    }
    const total_m = total_s / 60;
    if (total_m < 60) {
        return std.fmt.bufPrint(buf, "{d}m{d}s", .{ total_m, total_s % 60 }) catch "";
    }
    return std.fmt.bufPrint(buf, "{d}h{d}m", .{ total_m / 60, total_m % 60 }) catch "";
}

/// Display width of `text` in columns, counting one column per UTF-8
/// codepoint (a continuation byte is `0b10xxxxxx`). `\n` resets the count:
/// the result is the width of the final line only, which is what the
/// right-aligned prompt section needs.
pub fn displayWidth(text: []const u8) usize {
    var width: usize = 0;
    for (text) |b| {
        if (b == '\n') {
            width = 0;
        } else if (b & 0xC0 != 0x80) {
            width += 1;
        }
    }
    return width;
}

/// Total column width an op list occupies on its final line -- text widths
/// (via `displayWidth`, so a `\n` in any run resets the running count) plus
/// one column per icon. Used to right-align `prompt.right`.
pub fn opsWidth(ops: []const Op) usize {
    var width: usize = 0;
    for (ops) |op| switch (op) {
        .text => |t| {
            if (std.mem.lastIndexOfScalar(u8, t, '\n')) |nl| {
                width = displayWidth(t[nl + 1 ..]);
            } else {
                width += displayWidth(t);
            }
        },
        .icon => width += 1,
    };
    return width;
}
