const std = @import("std");
const builtin = @import("builtin");
const web = @import("./web.zig");
const ptime = @import("./time.zig");

/// Either the default panic handler or an emscripten capable one.
pub const panic = if (builtin.os.tag == .emscripten) web.panic else std.debug.FullPanic(std.debug.defaultPanic);

/// Standard options for setting up logging to either use an emscripten log handler, or the default one.
pub const std_options = blk: {
    if (builtin.os.tag == .emscripten) {
        break :blk std.Options{ .logFn = web.log };
    } else {
        break :blk std.Options{ .logFn = nativeLog };
    }
};

fn nativeLog(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    const level_color = comptime switch (level) {
        .err => "\x1b[31;1m",
        .warn => "\x1b[33;1m",
        .info => "\x1b[32;1m",
        .debug => "\x1b[36;1m",
    };
    const level_char = comptime switch (level) {
        .err => "E",
        .warn => "W",
        .info => "I",
        .debug => "D",
    };
    const scope_prefix = comptime if (scope == .default) "" else "(" ++ @tagName(scope) ++ ") ";

    const io = std.Io.Threaded.global_single_threaded.io();
    const lt = ptime.getLocalTime(io);

    var buffer: [256]u8 = undefined;
    const stderr = std.debug.lockStderr(&buffer);
    defer std.debug.unlockStderr();
    nosuspend {
        stderr.file_writer.interface.print(
            "\x1b[2m{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}\x1b[0m " ++
                level_color ++ level_char ++ "\x1b[0m " ++
                scope_prefix,
            .{ lt.hour, lt.minute, lt.second, lt.ms_part },
        ) catch return;
        stderr.file_writer.interface.print(format ++ "\x1b[0m\n", args) catch return;
    }
}
