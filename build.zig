const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const glyphwire_mod = b.addModule("glyphwire", .{
        .root_source_file = b.path("src/glyphwire.zig"),
    });

    // Pure prompt helpers shared by glyphwire-shell and its test runner
    // (a Zig module can't be reached across directories via relative
    // `@import`, so tests/ can't pull shell/ files in directly).
    const shell_support_mod = b.addModule("shell_support", .{
        .root_source_file = b.path("shell/support.zig"),
    });
    // `shell/lineedit.zig` imports `glyphwire` for `stringWidth` (East
    // Asian Width lookup); like `ls_support`, no IO / client / server is
    // pulled in for the pure width math itself.
    shell_support_mod.addImport("glyphwire", glyphwire_mod);

    // Column-packing math shared by glyphwire-ls and its test runner,
    // same cross-directory-module reason as `shell_support` above. Imports
    // `glyphwire` only for `codepointWidth` (East Asian Width lookup) --
    // still no IO / client / server pulled in for the math itself.
    const ls_support_mod = b.addModule("ls_support", .{
        .root_source_file = b.path("ls/support.zig"),
    });
    ls_support_mod.addImport("glyphwire", glyphwire_mod);

    // Pure, pixzig-free pieces of glyphwire-host (pixel/cell geometry,
    // scrollbar math, `host.conf` value clamps, the key-repeat timer) so
    // the test runner can exercise them without a GLFW/OpenGL link. Same
    // cross-directory-module reason as `shell_support` / `ls_support`;
    // imports `glyphwire` only for `CellPos` in `geometry.cellFromPixel`.
    const host_support_mod = b.addModule("host_support", .{
        .root_source_file = b.path("host/support.zig"),
    });
    host_support_mod.addImport("glyphwire", glyphwire_mod);

    const pixzig_dep = b.dependency("pixzig", .{ .target = target, .optimize = optimize, .build_examples = false });
    const pixzig_mod = pixzig_dep.module("pixzig");

    const zargunaught_mod = b.dependency("zargunaught", .{}).module("zargunaught");

    // Vendored Lua 5.3 (libs/ziglua) -- glyphwire-shell embeds a Lua state
    // to run ~/.config/glyphwire/shell.conf. `zlua` already links the Lua
    // C library into itself in ziglua's own build.zig; `lua_lib` is linked
    // onto each consuming executable explicitly, mirroring pixzig.
    const ziglua = b.dependency("ziglua", .{ .target = target, .optimize = optimize, .lang = .lua53 });
    const ziglua_mod = ziglua.module("zlua");
    const lua_lib = ziglua.artifact("lua");

    // shell/config.zig lives in this module and imports ziglua; both
    // glyphwire-shell and the test runner pull it in transitively.
    shell_support_mod.addImport("ziglua", ziglua_mod);
    // ls/config.zig (glyphwire-ls's ls.conf parser) does the same -- so
    // `ls_support` is no longer strictly dependency-free, but the width
    // math it also carries still pulls in nothing at its own call sites.
    ls_support_mod.addImport("ziglua", ziglua_mod);

    const tests_exe = b.addExecutable(.{
        .name = "tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    tests_exe.root_module.addImport("glyphwire", glyphwire_mod);
    tests_exe.root_module.addImport("shell_support", shell_support_mod);
    tests_exe.root_module.addImport("ls_support", ls_support_mod);
    tests_exe.root_module.addImport("host_support", host_support_mod);
    // shell_support -> shell/config.zig -> ziglua: the Lua C library and
    // libc have to be linked into the final test binary.
    tests_exe.root_module.linkLibrary(lua_lib);
    tests_exe.root_module.link_libc = true;

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
    shell_exe.root_module.addImport("shell_support", shell_support_mod);
    shell_exe.root_module.addImport("ziglua", ziglua_mod);
    shell_exe.root_module.linkLibrary(lua_lib);
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

    const table_demo_exe = b.addExecutable(.{
        .name = "glyphwire-table-demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("table-demo/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    table_demo_exe.root_module.addImport("glyphwire", glyphwire_mod);
    b.installArtifact(table_demo_exe);

    const run_table_demo = b.addRunArtifact(table_demo_exe);
    run_table_demo.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_table_demo.addArgs(args);

    const table_demo_step = b.step("table_demo", "Run the glyphwire table widget demo client");
    table_demo_step.dependOn(&run_table_demo.step);

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
    ls_exe.root_module.addImport("zargunaught", zargunaught_mod);
    ls_exe.root_module.addImport("ls_support", ls_support_mod);
    // ls_support -> ls/config.zig -> ziglua: the Lua C library has to be
    // linked onto the final binary, same as shell_exe does for shell.conf.
    ls_exe.root_module.linkLibrary(lua_lib);
    ls_exe.root_module.link_libc = true;
    b.installArtifact(ls_exe);

    const run_ls = b.addRunArtifact(ls_exe);
    run_ls.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_ls.addArgs(args);

    const ls_step = b.step("ls", "Run the glyphwire ls client (directory listing over the wire)");
    ls_step.dependOn(&run_ls.step);

    const view_exe = b.addExecutable(.{
        .name = "glyphwire-view",
        .root_module = b.createModule(.{
            .root_source_file = b.path("view/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    view_exe.root_module.addImport("glyphwire", glyphwire_mod);
    b.installArtifact(view_exe);

    const run_view = b.addRunArtifact(view_exe);
    run_view.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_view.addArgs(args);

    const view_step = b.step("view", "Run the glyphwire image-viewer client (glyphwire-view <image.png>)");
    view_step.dependOn(&run_view.step);

    const notify_exe = b.addExecutable(.{
        .name = "glyphwire-notify",
        .root_module = b.createModule(.{
            .root_source_file = b.path("notify/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    notify_exe.root_module.addImport("glyphwire", glyphwire_mod);
    b.installArtifact(notify_exe);

    const run_notify = b.addRunArtifact(notify_exe);
    run_notify.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_notify.addArgs(args);

    const notify_step = b.step("notify", "Run the glyphwire notification client (glyphwire-notify <message>)");
    notify_step.dependOn(&run_notify.step);

    // `zig build package` installs just the user-facing programs that ship
    // in the Linux release tarball -- host, shell, notify, demo, view, ls --
    // without also building the test runner or the internal server/client
    // tools that plain `zig build` pulls in. The CI packaging job
    // (.github/workflows/linux-package.yml) drives this step.
    const package_step = b.step("package", "Install the shipped programs (host, shell, notify, demo, view, ls) into zig-out/bin");
    for ([_]*std.Build.Step.Compile{ host_exe, shell_exe, notify_exe, demo_exe, view_exe, ls_exe }) |exe| {
        package_step.dependOn(&b.addInstallArtifact(exe, .{}).step);
    }
}
