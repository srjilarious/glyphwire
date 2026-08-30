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

/// `-l`'s permission column: a type character (`d`/`l`/`-`/... , same
/// mapping lsz's `printLongEntry` uses) followed by the classic
/// 9-character `rwxrwxrwx` triad (user, group, all -- `-` for an unset
/// bit). Unlike lsz's version, this doesn't color each flag individually:
/// a table cell carries one foreground color for its whole text (see
/// `core.Table`), not per-character styling, and the type-character-plus-
/// string shape reads clearly enough in the table's default color.
pub fn formatPermBits(buf: *[10]u8, mode: u16) []const u8 {
    const fm: FileMode = @bitCast(mode);
    buf[0] = switch (fm.type) {
        4 => 'd',
        8 => '-',
        10 => 'l',
        1 => 'p',
        2 => 'c',
        6 => 'b',
        12 => 's',
        else => '?',
    };
    buf[1] = if (fm.user_r) 'r' else '-';
    buf[2] = if (fm.user_w) 'w' else '-';
    buf[3] = if (fm.user_x) 'x' else '-';
    buf[4] = if (fm.group_r) 'r' else '-';
    buf[5] = if (fm.group_w) 'w' else '-';
    buf[6] = if (fm.group_x) 'x' else '-';
    buf[7] = if (fm.all_r) 'r' else '-';
    buf[8] = if (fm.all_w) 'w' else '-';
    buf[9] = if (fm.all_x) 'x' else '-';
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
