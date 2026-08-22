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
}
