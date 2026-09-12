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
        testz.Group{ .name = "Mux Tests", .tag = "mux", .mod = @import("./mux_tests.zig") },
        testz.Group{ .name = "RPC Tests", .tag = "rpc", .mod = @import("./rpc_tests.zig") },
        testz.Group{ .name = "Profiler Tests", .tag = "profiler", .mod = @import("./profiler_tests.zig") },
        testz.Group{ .name = "Dispatch Tests", .tag = "dispatch", .mod = @import("./dispatch_tests.zig") },
        testz.Group{ .name = "Server Tests", .tag = "server", .mod = @import("./server_tests.zig") },
        testz.Group{ .name = "Client Tests", .tag = "client", .mod = @import("./client_tests.zig") },
        testz.Group{ .name = "Table Tests", .tag = "table", .mod = @import("./table_tests.zig") },
        testz.Group{ .name = "End-to-end Tests", .tag = "e2e", .mod = @import("./e2e_tests.zig") },
        testz.Group{ .name = "Shell Tests", .tag = "shell", .mod = @import("./shell_tests.zig") },
        testz.Group{ .name = "Shell Parse Tests", .tag = "shell-parse", .mod = @import("./shell_parse_tests.zig") },
        testz.Group{ .name = "Shell Env Assign Tests", .tag = "shell-envassign", .mod = @import("./shell_envassign_tests.zig") },
        testz.Group{ .name = "Shell Config Tests", .tag = "shell-config", .mod = @import("./shell_config_tests.zig") },
        testz.Group{ .name = "Shell Script Engine Tests", .tag = "shell-script", .mod = @import("./shell_script_engine_tests.zig") },
        testz.Group{ .name = "Shell Zjump Tests", .tag = "shell-zjump", .mod = @import("./shell_zjump_tests.zig") },
        testz.Group{ .name = "Shell Flush Gate Tests", .tag = "shell-flushgate", .mod = @import("./shell_flushgate_tests.zig") },
        testz.Group{ .name = "Shell Remote Tests", .tag = "shell-remote", .mod = @import("./shell_remote_tests.zig") },
        testz.Group{ .name = "Prompt Template Tests", .tag = "prompt", .mod = @import("./prompt_template_tests.zig") },
        testz.Group{ .name = "Ls Tests", .tag = "ls", .mod = @import("./ls_tests.zig") },
        testz.Group{ .name = "Open Action Tests", .tag = "openaction", .mod = @import("./openaction_tests.zig") },
        testz.Group{ .name = "Host Tests", .tag = "host", .mod = @import("./host_tests.zig") },
        testz.Group{ .name = "Host Engine Tests", .tag = "host-eng", .mod = @import("./host_eng_tests.zig") },
        testz.Group{ .name = "Zoe Tests", .tag = "zoe", .mod = @import("./zoe_tests.zig") },
        testz.Group{ .name = "Gmux Tests", .tag = "gmux", .mod = @import("./gmux_tests.zig") },
    }, .{});
};

pub fn main(init: std.process.Init) !void {
    try testz.testzRunner(Tests, init.minimal.args);
}
