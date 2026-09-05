const std = @import("std");
const testz = @import("testz");

const Tests = blk: {
    // testz's per-module discovery walks every `pub` decl with an
    // `inline for`; enough test functions across the groups below tips it
    // past the default 1000-branch comptime limit.
    @setEvalBranchQuota(20000);
    break :blk testz.discoverTests(.{
        testz.Group{ .name = "Core Tests", .tag = "core", .mod = @import("./core_tests.zig") },
        testz.Group{ .name = "Wire Tests", .tag = "wire", .mod = @import("./wire_tests.zig") },
        testz.Group{ .name = "RPC Tests", .tag = "rpc", .mod = @import("./rpc_tests.zig") },
        testz.Group{ .name = "Dispatch Tests", .tag = "dispatch", .mod = @import("./dispatch_tests.zig") },
        testz.Group{ .name = "Server Tests", .tag = "server", .mod = @import("./server_tests.zig") },
        testz.Group{ .name = "Client Tests", .tag = "client", .mod = @import("./client_tests.zig") },
        testz.Group{ .name = "Table Tests", .tag = "table", .mod = @import("./table_tests.zig") },
        testz.Group{ .name = "End-to-end Tests", .tag = "e2e", .mod = @import("./e2e_tests.zig") },
        testz.Group{ .name = "Shell Tests", .tag = "shell", .mod = @import("./shell_tests.zig") },
        testz.Group{ .name = "Shell Config Tests", .tag = "shell-config", .mod = @import("./shell_config_tests.zig") },
        testz.Group{ .name = "Prompt Template Tests", .tag = "prompt", .mod = @import("./prompt_template_tests.zig") },
        testz.Group{ .name = "Ls Tests", .tag = "ls", .mod = @import("./ls_tests.zig") },
    }, .{});
};

pub fn main(init: std.process.Init) !void {
    try testz.testzRunner(Tests, init.minimal.args);
}
