// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: GPL-3.0-or-later

const std = @import("std");
const testz = @import("testz");
const build_options = @import("build_options");

const all_tests = blk: {
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
        testz.Group{ .name = "Read Tests", .tag = "read", .mod = @import("./read_tests.zig") },
        testz.Group{ .name = "Markdown Tests", .tag = "md", .mod = @import("./md_tests.zig") },
        testz.Group{ .name = "Keybind Tests", .tag = "keybind", .mod = @import("./keybind_tests.zig") },
        testz.Group{ .name = "Line Edit Tests", .tag = "lineedit", .mod = @import("./lineedit_tests.zig") },
        testz.Group{ .name = "Salacommander Tests", .tag = "salacommander", .mod = @import("./salacommander_tests.zig") },
    }, .{});
};

/// Everything discovered above, minus the groups this build was told to
/// leave out. Filtering here rather than at discovery means the skipped
/// group's file is still compiled into the binary, so a break in it still
/// fails the build -- see build.zig's `skip-e2e` option for why CI skips
/// the end-to-end group.
const tests_to_run = if (build_options.skip_e2e)
    withoutGroup(all_tests, "e2e")
else
    all_tests;

/// The tests in `tests` whose group tag is not `tag`.
fn withoutGroup(
    comptime tests: []const testz.TestFuncInfo,
    comptime tag: []const u8,
) []const testz.TestFuncInfo {
    comptime {
        // One pass over every discovered test, same reason as above.
        @setEvalBranchQuota(20000);
        var kept: [tests.len]testz.TestFuncInfo = undefined;
        var count: usize = 0;
        for (tests) |t| {
            if (std.mem.eql(u8, t.group.tag, tag)) continue;
            kept[count] = t;
            count += 1;
        }
        const final = kept[0..count].*;
        return &final;
    }
}

pub fn main(init: std.process.Init) !void {
    try testz.testzRunner(tests_to_run, init.minimal.args);
}
