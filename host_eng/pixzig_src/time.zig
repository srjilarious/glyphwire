const std = @import("std");
const builtin = @import("builtin");
const c = @import("c_time");

pub const LocalTime = struct {
    year: u32,
    month: u32,
    day: u32,
    hour: u32,
    minute: u32,
    second: u32,
    ms_part: u32,
};

/// Returns the current wall-clock time in the process's local timezone.
/// Uses localtime_r (POSIX) on Linux/macOS/emscripten and localtime on Windows.
pub fn getLocalTime(io: std.Io) LocalTime {
    const ms = std.Io.Timestamp.now(io, .real).toMilliseconds();
    const ms_part: u32 = @intCast(@mod(ms, 1000));
    const total_secs: c.time_t = @intCast(@divFloor(ms, 1000));

    var tm_val: c.struct_tm = undefined;
    if (builtin.os.tag == .windows) {
        if (c.localtime(&total_secs)) |p| tm_val = p.*;
    } else {
        _ = c.localtime_r(&total_secs, &tm_val);
    }

    return .{
        .year = @as(u32, @intCast(tm_val.tm_year)) + 1900,
        .month = @as(u32, @intCast(tm_val.tm_mon)) + 1,
        .day = @intCast(tm_val.tm_mday),
        .hour = @intCast(tm_val.tm_hour),
        .minute = @intCast(tm_val.tm_min),
        .second = @intCast(tm_val.tm_sec),
        .ms_part = ms_part,
    };
}
