const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const glyphwire_mod = b.addModule("glyphwire", .{
        .root_source_file = b.path("src/glyphwire.zig"),
    });

    const installed_assets_step = b.addInstallDirectory(.{
        .source_dir = b.path("assets"),
        .install_dir = .{ .custom = "share/glyphwire" },
        .install_subdir = "assets",
    });
    b.getInstallStep().dependOn(&installed_assets_step.step);

    // Pure prompt helpers shared by gw-shell and its test runner
    // (a Zig module can't be reached across directories via relative
    // `@import`, so tests/ can't pull shell/ files in directly).
    const shell_support_mod = b.addModule("shell_support", .{
        .root_source_file = b.path("shell/support.zig"),
    });
    // `shell/lineedit.zig` imports `glyphwire` for `stringWidth` (East
    // Asian Width lookup); like `ls_support`, no IO / client / server is
    // pulled in for the pure width math itself.
    shell_support_mod.addImport("glyphwire", glyphwire_mod);

    // Column-packing math shared by gw-ls and its test runner,
    // same cross-directory-module reason as `shell_support` above. Imports
    // `glyphwire` only for `codepointWidth` (East Asian Width lookup) --
    // still no IO / client / server pulled in for the math itself.
    const ls_support_mod = b.addModule("ls_support", .{
        .root_source_file = b.path("ls/support.zig"),
    });
    ls_support_mod.addImport("glyphwire", glyphwire_mod);

    // Pure, engine-free pieces of glyphwire (pixel/cell geometry,
    // scrollbar math, `host.conf` value clamps, the key-repeat timer) so
    // the test runner can exercise them without an SDL/OpenGL link. Same
    // cross-directory-module reason as `shell_support` / `ls_support`;
    // imports `glyphwire` only for `CellPos` in `geometry.cellFromPixel`.
    const host_support_mod = b.addModule("host_support", .{
        .root_source_file = b.path("host/support.zig"),
    });
    host_support_mod.addImport("glyphwire", glyphwire_mod);

    // zoe's editor core (gap buffer, motions, the modal state machine)
    // shared by the `zoe` binary and its test runner -- same
    // cross-directory-module reason as `shell_support` / `ls_support`.
    // Pure: no glyphwire client, no engine, no IO.
    const zoe_support_mod = b.addModule("zoe_support", .{
        .root_source_file = b.path("zoe/support.zig"),
    });
    // `zoe/ui.zig` is the glyphwire client half of the editor, and
    // `zoe/tree.zig` uses `stringWidth` for its column maths; the editor
    // core itself still pulls in nothing.
    zoe_support_mod.addImport("glyphwire", glyphwire_mod);
    // The tree pane reuses glyphwire-ls's name -> icon mapping rather
    // than growing a second copy of it.
    zoe_support_mod.addImport("ls_support", ls_support_mod);

    const sdl_dep = b.dependency("sdl", .{ .target = target, .optimize = optimize });
    const zopengl = b.dependency("zopengl", .{ .target = target });
    const zmath = b.dependency("zmath", .{ .target = target });
    const zstbi = b.dependency("zstbi", .{ .target = target });
    // `host_eng` is glyphwire's own SDL3 + OpenGL engine backend (see
    // host_eng/root.zig) -- windowing, input, the renderer and the
    // resource manager, and nothing else. Its C-level pieces are vendored
    // under host_eng/libs/ and host_eng/engine/, so the whole backend is
    // pinned in-tree with no sibling checkout to keep in step.
    const stbtt_translate = b.addTranslateC(.{
        .root_source_file = b.path("host_eng/libs/stb_truetype/stb_truetype.h"),
        .target = target,
        .optimize = optimize,
    });
    stbtt_translate.addIncludePath(b.path("host_eng/libs/stb_truetype"));
    const stbtt_mod = b.addModule("host_eng_stb_truetype", .{
        .root_source_file = b.path("host_eng/libs/stb_truetype/stb_truetype.zig"),
    });
    stbtt_mod.addImport("c", stbtt_translate.createModule());
    stbtt_mod.addCSourceFile(.{
        .file = b.path("host_eng/libs/stb_truetype/stb_truetype.c"),
        .flags = &.{"-fno-sanitize=undefined"},
    });
    stbtt_mod.addIncludePath(b.path("host_eng/libs/stb_truetype"));
    const time_c_translate = b.addTranslateC(.{
        .root_source_file = b.path("host_eng/engine/time_c.h"),
        .target = target,
        .optimize = optimize,
    });

    const zargunaught_mod = b.dependency("zargunaught", .{}).module("zargunaught");

    // Vendored Lua 5.3 (libs/ziglua) -- gw-shell embeds a Lua state
    // to run ~/.config/glyphwire/shell.conf. `zlua` already links the Lua
    // C library into itself in ziglua's own build.zig; `lua_lib` is linked
    // onto each consuming executable explicitly.
    const ziglua = b.dependency("ziglua", .{ .target = target, .optimize = optimize, .lang = .lua53 });
    const ziglua_mod = ziglua.module("zlua");
    const lua_lib = ziglua.artifact("lua");

    const host_eng_mod = b.addModule("host_eng", .{
        .root_source_file = b.path("host_eng/root.zig"),
    });
    host_eng_mod.addImport("sdl3", sdl_dep.module("sdl3"));
    host_eng_mod.addImport("zopengl", zopengl.module("root"));
    host_eng_mod.addImport("zmath", zmath.module("root"));
    host_eng_mod.addImport("zstbi", zstbi.module("root"));
    host_eng_mod.addImport("ziglua", ziglua_mod);
    host_eng_mod.addImport("stb_truetype", stbtt_mod);
    host_eng_mod.addImport("c_time", time_c_translate.createModule());

    // shell/config.zig lives in this module and imports ziglua; both
    // gw-shell and the test runner pull it in transitively.
    shell_support_mod.addImport("ziglua", ziglua_mod);
    // ls/config.zig (glyphwire-ls's ls.conf parser) does the same -- so
    // `ls_support` is no longer strictly dependency-free, but the width
    // math it also carries still pulls in nothing at its own call sites.
    ls_support_mod.addImport("ziglua", ziglua_mod);
    // zoe/langconf.zig (zoe.conf parser) is the third ziglua consumer.
    zoe_support_mod.addImport("ziglua", ziglua_mod);

    // ── zoe syntax highlighting ──
    //
    // `tree_sitter` is the Zig binding *plus* the vendored libtree-sitter
    // C runtime (its module links the static lib in), so importing it
    // into `zoe_support` is enough to reach the `zoe` binary and the test
    // runner. The grammars themselves are NOT linked in: `installGrammars`
    // compiles each to a standalone `parser.so` that zoe `dlopen`s at
    // runtime from the grammar search path (see zoe/syntax.zig).
    const tree_sitter_dep = b.dependency("tree_sitter", .{ .target = target, .optimize = optimize });
    zoe_support_mod.addImport("tree_sitter", tree_sitter_dep.module("tree_sitter"));

    const grammars_install_dir = "share/glyphwire/grammars";
    installGrammars(b, target, optimize, grammars_install_dir);

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
    tests_exe.root_module.addImport("zoe_support", zoe_support_mod);
    // `host_eng_tests` exercises the SDL3 backend's Keyboard/Mouse state
    // machines and its two wire-visible enums. They need no window and no
    // GL context -- but the module does drag libSDL3.a into the test
    // binary, which is the price of catching a renamed key before it
    // reaches the protocol.
    tests_exe.root_module.addImport("host_eng", host_eng_mod);
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
        .name = "gw-shell",
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
    run_shell.setEnvironmentVariable("GLYPHWIRE_BIN_DIR", b.getInstallPath(.bin, ""));
    if (b.args) |args| run_shell.addArgs(args);

    const shell_step = b.step("gw-shell", "Run the glyphwire shell launcher");
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

    const probe_exe = b.addExecutable(.{
        .name = "glyphwire-probe",
        .root_module = b.createModule(.{
            .root_source_file = b.path("debug/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    probe_exe.root_module.addImport("glyphwire", glyphwire_mod);
    b.installArtifact(probe_exe);

    const run_probe = b.addRunArtifact(probe_exe);
    run_probe.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_probe.addArgs(args);

    const probe_step = b.step("probe", "Run glyphwire-probe against GLYPHWIRE_SOCK");
    probe_step.dependOn(&run_probe.step);

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
        .name = "glyphwire",
        .root_module = b.createModule(.{
            .root_source_file = b.path("host/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    host_exe.root_module.addImport("glyphwire", glyphwire_mod);
    host_exe.root_module.addImport("host_eng", host_eng_mod);
    b.installArtifact(host_exe);

    const run_host = b.addRunArtifact(host_exe);
    run_host.step.dependOn(b.getInstallStep());
    run_host.setEnvironmentVariable("GLYPHWIRE_ASSET_DIR", b.getInstallPath(.{ .custom = "share/glyphwire" }, "assets"));
    run_host.setEnvironmentVariable("GLYPHWIRE_BIN_DIR", b.getInstallPath(.bin, ""));
    if (b.args) |args| run_host.addArgs(args);

    const host_step = b.step("glyphwire", "Run the SDL3-windowed glyphwire host (spawns gw-shell)");
    host_step.dependOn(&run_host.step);

    const ls_exe = b.addExecutable(.{
        .name = "gw-ls",
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

    const ls_step = b.step("gw-ls", "Run the glyphwire ls client (directory listing over the wire)");
    ls_step.dependOn(&run_ls.step);

    const zoe_exe = b.addExecutable(.{
        .name = "zoe",
        .root_module = b.createModule(.{
            .root_source_file = b.path("zoe/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    zoe_exe.root_module.addImport("glyphwire", glyphwire_mod);
    zoe_exe.root_module.addImport("zoe_support", zoe_support_mod);
    // zoe_support -> langconf.zig -> ziglua, and -> syntax.zig ->
    // tree_sitter (which links the vendored libtree-sitter C runtime).
    // Both need libc and the Lua C lib on the final binary, same as
    // gw-shell / gw-ls do for their own configs.
    zoe_exe.root_module.linkLibrary(lua_lib);
    zoe_exe.root_module.link_libc = true;
    b.installArtifact(zoe_exe);

    const run_zoe = b.addRunArtifact(zoe_exe);
    run_zoe.step.dependOn(b.getInstallStep());
    // Point zoe at the grammars this build just installed, the way
    // `run_host` points the host at the installed asset dir.
    run_zoe.setEnvironmentVariable(
        "GLYPHWIRE_ZOE_GRAMMAR_DIR",
        b.getInstallPath(.{ .custom = "share/glyphwire" }, "grammars"),
    );
    if (b.args) |args| run_zoe.addArgs(args);

    const zoe_step = b.step("zoe", "Run the zoe editor (headless core driver for now -- see docs/investigations/zoe-editor.md)");
    zoe_step.dependOn(&run_zoe.step);

    const view_exe = b.addExecutable(.{
        .name = "gw-view",
        .root_module = b.createModule(.{
            .root_source_file = b.path("view/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    view_exe.root_module.addImport("glyphwire", glyphwire_mod);
    view_exe.root_module.addImport("zargunaught", zargunaught_mod);
    b.installArtifact(view_exe);

    const run_view = b.addRunArtifact(view_exe);
    run_view.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_view.addArgs(args);

    const view_step = b.step("gw-view", "Run the glyphwire image-viewer client (gw-view <image.png>)");
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

    // `zig build package` installs just the user-facing programs and
    // bundled assets that ship in the Linux release tarball -- glyphwire,
    // gw-shell, notify, demo, gw-view, gw-ls, and assets -- without also
    // building the test runner or the internal server/client tools that
    // plain `zig build` pulls in. The CI packaging job
    // (.github/workflows/linux-package.yml) drives this step.
    const package_step = b.step("package", "Install the shipped programs and assets into zig-out");
    for ([_]*std.Build.Step.Compile{ host_exe, shell_exe, notify_exe, demo_exe, view_exe, ls_exe }) |exe| {
        package_step.dependOn(&b.addInstallArtifact(exe, .{}).step);
    }
    package_step.dependOn(&installed_assets_step.step);

    const install_local_step = b.step("install-local", "Install glyphwire, gw-shell, gw-view, gw-ls, and assets under the selected prefix");
    for ([_]*std.Build.Step.Compile{ host_exe, shell_exe, view_exe, ls_exe }) |exe| {
        install_local_step.dependOn(&b.addInstallArtifact(exe, .{}).step);
    }
    install_local_step.dependOn(&installed_assets_step.step);
}

/// One bundled tree-sitter grammar: the lazy-dependency name holding its
/// generated parser, an optional in-repo subdirectory (the Markdown repo
/// nests two grammars), whether it ships an external `scanner.c`, and the
/// grammar-search-path directory name zoe loads it as.
const BundledGrammar = struct {
    name: []const u8,
    dep: []const u8,
    subdir: []const u8 = "",
    scanner: bool = false,
    /// The grammar dir also ships `queries/injections.scm`, to install
    /// alongside `highlights.scm` so zoe can highlight embedded languages.
    injections: bool = false,
};

const bundled_grammars = [_]BundledGrammar{
    .{ .name = "zig", .dep = "grammar_zig", .injections = true },
    .{ .name = "json", .dep = "grammar_json" },
    .{ .name = "c", .dep = "grammar_c" },
    .{ .name = "python", .dep = "grammar_python", .scanner = true },
    .{ .name = "toml", .dep = "grammar_toml", .scanner = true },
    // Markdown ships as two grammars: the block grammar parses the
    // document structure and injects `markdown_inline` for every
    // paragraph's inline span (and other languages for fenced code
    // blocks); the inline grammar highlights emphasis, links and code
    // spans. Both carry an `injections.scm`.
    .{
        .name = "markdown",
        .dep = "grammar_markdown",
        .subdir = "tree-sitter-markdown/",
        .scanner = true,
        .injections = true,
    },
    .{
        .name = "markdown_inline",
        .dep = "grammar_markdown",
        .subdir = "tree-sitter-markdown-inline/",
        .scanner = true,
        .injections = true,
    },
};

/// Compiles each bundled grammar to `<install_dir>/<name>/parser.so` and
/// copies its `highlights.scm` (and `injections.scm`, where the grammar
/// has one) alongside, wired onto the default install step. The grammar
/// deps are lazy, so a plain `zig build` only fetches them because this
/// runs; nothing links them into a Zig binary.
fn installGrammars(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    install_dir: []const u8,
) void {
    for (bundled_grammars) |g| {
        const dep = b.lazyDependency(g.dep, .{}) orelse continue;

        const lib = b.addLibrary(.{
            .name = b.fmt("tree-sitter-{s}", .{g.name}),
            .linkage = .dynamic,
            .root_module = b.createModule(.{
                .target = target,
                .optimize = optimize,
                .link_libc = true,
            }),
        });
        lib.root_module.addCSourceFile(.{
            .file = dep.path(b.fmt("{s}src/parser.c", .{g.subdir})),
            .flags = &.{"-std=c11"},
        });
        if (g.scanner) lib.root_module.addCSourceFile(.{
            .file = dep.path(b.fmt("{s}src/scanner.c", .{g.subdir})),
            .flags = &.{"-std=c11"},
        });
        lib.root_module.addIncludePath(dep.path(b.fmt("{s}src", .{g.subdir})));

        const dest: std.Build.InstallDir = .{ .custom = b.fmt("{s}/{s}", .{ install_dir, g.name }) };
        const inst_lib = b.addInstallArtifact(lib, .{ .dest_dir = .{ .override = dest } });
        const inst_scm = b.addInstallFileWithDir(
            dep.path(b.fmt("{s}queries/highlights.scm", .{g.subdir})),
            dest,
            "highlights.scm",
        );
        b.getInstallStep().dependOn(&inst_lib.step);
        b.getInstallStep().dependOn(&inst_scm.step);

        if (g.injections) {
            const inst_inj = b.addInstallFileWithDir(
                dep.path(b.fmt("{s}queries/injections.scm", .{g.subdir})),
                dest,
                "injections.scm",
            );
            b.getInstallStep().dependOn(&inst_inj.step);
        }
    }
}
