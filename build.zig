const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const glyphwire_mod = b.addModule("glyphwire", .{
        .root_source_file = b.path("src/glyphwire.zig"),
    });

    const pixzig_dep = b.dependency("pixzig", .{ .target = target, .optimize = optimize, .build_examples = false });
    const pixzig_mod = pixzig_dep.module("pixzig");

    const tests_exe = b.addExecutable(.{
        .name = "tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    tests_exe.root_module.addImport("glyphwire", glyphwire_mod);

    const testz_dep = b.dependency("testz", .{});
    tests_exe.root_module.addImport("testz", testz_dep.module("testz"));

    b.installArtifact(tests_exe);

    const run_tests = b.addRunArtifact(tests_exe);
    run_tests.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_tests.addArgs(args);

    const test_step = b.step("tests", "Run unit tests");
    test_step.dependOn(&run_tests.step);

    const server_exe = b.addExecutable(.{
        .name = "glyphwire-server",
        .root_module = b.createModule(.{
            .root_source_file = b.path("server/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    server_exe.root_module.addImport("glyphwire", glyphwire_mod);
    b.installArtifact(server_exe);

    const run_server = b.addRunArtifact(server_exe);
    run_server.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_server.addArgs(args);

    const server_step = b.step("server", "Run the glyphwire server");
    server_step.dependOn(&run_server.step);

    const shell_exe = b.addExecutable(.{
        .name = "glyphwire-shell",
        .root_module = b.createModule(.{
            .root_source_file = b.path("shell/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    shell_exe.root_module.addImport("glyphwire", glyphwire_mod);
    shell_exe.root_module.link_libc = true;
    b.installArtifact(shell_exe);

    const run_shell = b.addRunArtifact(shell_exe);
    run_shell.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_shell.addArgs(args);

    const shell_step = b.step("shell", "Run the glyphwire shell launcher");
    shell_step.dependOn(&run_shell.step);

    const client_exe = b.addExecutable(.{
        .name = "glyphwire-client",
        .root_module = b.createModule(.{
            .root_source_file = b.path("client/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    client_exe.root_module.addImport("glyphwire", glyphwire_mod);
    b.installArtifact(client_exe);

    const run_client = b.addRunArtifact(client_exe);
    run_client.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_client.addArgs(args);

    const client_step = b.step("client", "Run the glyphwire test client");
    client_step.dependOn(&run_client.step);

    const demo_exe = b.addExecutable(.{
        .name = "glyphwire-demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("demo/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    demo_exe.root_module.addImport("glyphwire", glyphwire_mod);
    b.installArtifact(demo_exe);

    const run_demo = b.addRunArtifact(demo_exe);
    run_demo.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_demo.addArgs(args);

    const demo_step = b.step("demo", "Run the glyphwire styled-text demo client");
    demo_step.dependOn(&run_demo.step);

    const host_exe = b.addExecutable(.{
        .name = "glyphwire-host",
        .root_module = b.createModule(.{
            .root_source_file = b.path("host/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    host_exe.root_module.addImport("glyphwire", glyphwire_mod);
    host_exe.root_module.addImport("pixzig", pixzig_mod);
    b.installArtifact(host_exe);

    const run_host = b.addRunArtifact(host_exe);
    run_host.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_host.addArgs(args);

    const host_step = b.step("host", "Run the glyphwire pixzig-windowed host (spawns glyphwire-shell)");
    host_step.dependOn(&run_host.step);

    const ls_exe = b.addExecutable(.{
        .name = "ls",
        .root_module = b.createModule(.{
            .root_source_file = b.path("ls/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    ls_exe.root_module.addImport("glyphwire", glyphwire_mod);
    b.installArtifact(ls_exe);

    const run_ls = b.addRunArtifact(ls_exe);
    run_ls.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_ls.addArgs(args);

    const ls_step = b.step("ls", "Run the glyphwire ls client (directory listing over the wire)");
    ls_step.dependOn(&run_ls.step);
}
