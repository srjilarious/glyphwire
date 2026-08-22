const std = @import("std");
const testz = @import("testz");

const Tests = testz.discoverTests(.{
    testz.Group{ .name = "Core Tests", .tag = "core", .mod = @import("./core_tests.zig") },
    testz.Group{ .name = "Wire Tests", .tag = "wire", .mod = @import("./wire_tests.zig") },
    testz.Group{ .name = "Dispatch Tests", .tag = "dispatch", .mod = @import("./dispatch_tests.zig") },
    testz.Group{ .name = "Server Tests", .tag = "server", .mod = @import("./server_tests.zig") },
    testz.Group{ .name = "End-to-end Tests", .tag = "e2e", .mod = @import("./e2e_tests.zig") },
}, .{});

pub fn main(init: std.process.Init) !void {
    try testz.testzRunner(Tests, init.minimal.args);
}
