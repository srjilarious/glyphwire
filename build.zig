const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const glyphwire_mod = b.addModule("glyphwire", .{
        .root_source_file = b.path("src/glyphwire.zig"),
    });

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
}
