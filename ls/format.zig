//! Pure size / permission / timestamp formatting for glyphwire-ls's `-l`
//! listing (and the plain stdout fallback). No IO, no libc -- everything
//! here works off values already in a `FileEntry`.

const std = @import("std");

pub const KBytes: u64 = 1024;
pub const MBytes: u64 = 1024 * KBytes;
pub const GBytes: u64 = 1024 * MBytes;

/// Bitfield view of a `FileEntry`'s raw POSIX mode bits -- lifted from
/// lsz's identical `FileMode` (/home/jeffdw/code/lsz/src/main.zig), same
/// field layout (LSB first: all/other bits, then group, then user, then
/// setuid/setgid/sticky, then the file-type nibble in the top 4 bits,
/// matching `st_mode`'s standard POSIX layout).
pub const FileMode = packed struct(u16) {
    all_x: bool,
    all_w: bool,
    all_r: bool,
    group_x: bool,
    group_w: bool,
    group_r: bool,
    user_x: bool,
    user_w: bool,
    user_r: bool,
    sticky: bool,
    setgid: bool,
    setuid: bool,
    type: u4,
};

/// The leading type character of a `-l` permission string: `d`/`l`/`-`/...
/// (the same mapping lsz's `printLongEntry` uses). Split out from
/// `formatPermBits` so the glyphwire `-l` table -- which draws the type
/// char in its own cell, separately colored from the rwx triads -- and
/// the plain stdout string share one source of truth.
pub fn permTypeChar(mode: u16) u8 {
    const fm: FileMode = @bitCast(mode);
    return switch (fm.type) {
        4 => 'd',
        8 => '-',
        10 => 'l',
        1 => 'p',
        2 => 'c',
        6 => 'b',
        12 => 's',
        else => '?',
    };
}

/// Which of the three `rwx` bit groups a `formatPermTriad` call wants.
pub const PermGroup = enum { user, group, other };

/// One `rwx` triad of a permission string (`-` for an unset bit), for the
/// glyphwire `-l` table's split permission cells -- each triad is drawn
/// in its own 3-wide cell so it can carry its own color (a table cell has
/// one foreground for its whole text, so the individual r/w/x bits still
/// can't be colored apart; the whole triad is colored as a unit -- see
/// `permTriadColor` in `main.zig`).
pub fn formatPermTriad(buf: *[3]u8, mode: u16, group: PermGroup) []const u8 {
    const fm: FileMode = @bitCast(mode);
    const r, const w, const x = switch (group) {
        .user => .{ fm.user_r, fm.user_w, fm.user_x },
        .group => .{ fm.group_r, fm.group_w, fm.group_x },
        .other => .{ fm.all_r, fm.all_w, fm.all_x },
    };
    buf[0] = if (r) 'r' else '-';
    buf[1] = if (w) 'w' else '-';
    buf[2] = if (x) 'x' else '-';
    return buf;
}

/// `-l`'s permission column, as one string: the `permTypeChar` type
/// character followed by the classic 9-character `rwxrwxrwx` triad (user,
/// group, all -- `-` for an unset bit). Still used verbatim for the plain
/// stdout fallback; the glyphwire `-l` table draws the same bits as four
/// separately-colored cells (`permTypeChar` + three `formatPermTriad`s).
pub fn formatPermBits(buf: *[10]u8, mode: u16) []const u8 {
    buf[0] = permTypeChar(mode);
    _ = formatPermTriad(buf[1..4], mode, .user);
    _ = formatPermTriad(buf[4..7], mode, .group);
    _ = formatPermTriad(buf[7..10], mode, .other);
    return buf;
}

/// A file size for display. `raw` (`--bytes`) prints the exact byte
/// count; otherwise it's the human-readable form, right-padded to a fixed
/// width so the timestamp that follows lines up across rows -- e.g.
/// `  512 B`, ` 12.3 KB`. `buf` must hold at least 24 bytes (a u64 is up
/// to 20 digits).
pub fn formatSize(buf: []u8, size: u64, raw: bool) []const u8 {
    if (raw) return std.fmt.bufPrint(buf, "{d}", .{size}) catch buf[0..0];
    if (size < KBytes) return std.fmt.bufPrint(buf, "{d:>4} B ", .{size}) catch buf[0..0];
    if (size < MBytes) return std.fmt.bufPrint(buf, "{d:>5.1} KB", .{@as(f64, @floatFromInt(size)) / @as(f64, @floatFromInt(KBytes))}) catch buf[0..0];
    if (size < GBytes) return std.fmt.bufPrint(buf, "{d:>5.1} MB", .{@as(f64, @floatFromInt(size)) / @as(f64, @floatFromInt(MBytes))}) catch buf[0..0];
    return std.fmt.bufPrint(buf, "{d:>5.1} GB", .{@as(f64, @floatFromInt(size)) / @as(f64, @floatFromInt(GBytes))}) catch buf[0..0];
}

/// `-l`'s Owner column: the resolved owner and group names joined with a
/// colon (`owner:group`), matching exa's `user:group` cell. The names
/// themselves are looked up by the caller -- glyphwire-ls links libc for
/// `getpwuid`/`getgrgid`; this module stays pure -- and a caller with no
/// name for an id passes the decimal id as the string instead. `buf`
/// should hold at least `2 * longest_name + 1` bytes; on overflow this
/// returns an empty slice, same shape `formatSize`/`formatTimestamp` use.
pub fn formatOwnerGroup(buf: []u8, owner: []const u8, group: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "{s}:{s}", .{ owner, group }) catch buf[0..0];
}

/// `YYYY-MM-DD HH:MM`, purely from `std.time.epoch` -- no libc needed.
pub fn formatTimestamp(buf: []u8, sec: i64) []const u8 {
    if (sec < 0) return "";
    const epoch: std.time.epoch.EpochSeconds = .{ .secs = @intCast(sec) };
    const epoch_day = epoch.getEpochDay();
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_secs = epoch.getDaySeconds();
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        day_secs.getHoursIntoDay(),
        day_secs.getMinutesIntoHour(),
    }) catch buf[0..0];
}
