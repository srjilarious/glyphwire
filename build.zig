// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: MPL-2.0

const std = @import("std");
const testz = @import("testz");

/// The suite's version: what a release (tag, tarball) is called. Each
/// versioned program has its own on top of it, in its `apps` row.
const suite_version = @import("build.zig.zon").version;

/// An environment variable a run step sets, to a path under the build
/// root's `zig-out/` (the run step's cwd is the build root, and it runs
/// after the default install step, so the default prefix is where the
/// just-built files are).
const RunEnv = struct {
    name: []const u8,
    path: []const []const u8,
};

/// Points a program that spawns its siblings at the just-installed ones.
const bin_dir_env: RunEnv = .{ .name = "GLYPHWIRE_BIN_DIR", .path = &.{ "zig-out", "bin" } };
/// Points a program at the tree-sitter grammars this build just installed.
const grammar_dir_env: RunEnv = .{
    .name = "GLYPHWIRE_ZOE_GRAMMAR_DIR",
    .path = &.{ "zig-out", "share", "glyphwire", "grammars" },
};

/// One executable: what `build` compiles, installs, ships and gives a
/// `zig build <step>` run step.
const App = struct {
    /// The executable's name.
    name: []const u8,
    /// The program's own version, or null for the internal tools and
    /// demos that don't print one. A program with a version gets a
    /// `build_info` module (see `addBuildInfo`); bump it when that program
    /// changes in a release, the others stay put. scripts/sync-versions.py
    /// reads these, so keep `.name` and `.version` the first two fields.
    version: ?[]const u8 = null,
    /// The root source file.
    root: []const u8,
    /// The modules it imports, by the names `build` registers them under
    /// (and the name each is imported as). An unknown name stops the build.
    imports: []const []const u8,
    /// Links the Lua C library (and so libc): a config loader somewhere
    /// under the program's imports runs a `*.conf.lua` through ziglua.
    lua: bool = false,
    /// Links libc without Lua.
    libc: bool = false,
    /// Installed by plain `zig build`. False only for on-demand tools.
    install: bool = true,
    /// In the release tarball (`zig build package`) and in
    /// `zig build install-local`.
    shipped: bool = false,
    /// The `zig build <step>` that runs it, and that step's description.
    step: []const u8,
    description: []const u8,
    /// Environment the run step sets.
    env: []const RunEnv = &.{},
};

/// Every program the build makes: the one place the list lives.
const apps = [_]App{
    .{
        .name = "glyphwire",
        .version = "0.20.0",
        .root = "host/main.zig",
        // `theme.lua` (themeconf) is the window's theme; `listcursor` and
        // `keybind` come in on their own rather than through `applib`.
        .imports = &.{ "glyphwire", "host_eng", "themeconf", "luaconf", "listcursor", "keybind" },
        .shipped = true,
        .step = "glyphwire",
        .description = "Run the SDL3-windowed glyphwire host (spawns gw-shell)",
        .env = &.{
            .{ .name = "GLYPHWIRE_ASSET_DIR", .path = &.{ "zig-out", "share", "glyphwire", "assets" } },
            bin_dir_env,
        },
    },
    .{
        .name = "glyphwire-server",
        .version = "0.16.0",
        .root = "server/main.zig",
        .imports = &.{"glyphwire"},
        .step = "server",
        .description = "Run the glyphwire server",
    },
    .{
        .name = "gw-shell",
        .version = "0.14.0",
        .root = "shell/main.zig",
        .imports = &.{ "glyphwire", "shell_support", "applib", "ziglua", "themeconf" },
        .lua = true,
        .shipped = true,
        .step = "gw-shell",
        .description = "Run the glyphwire shell launcher",
        .env = &.{bin_dir_env},
    },
    // The remote endpoint of `glyphwire --ssh <dest>`. Runs on the far
    // host over ssh (`--stdio`), and doubles as the `SSH_ASKPASS` helper
    // (`--askpass`). Shipped alongside the shell tools; the remote box is
    // expected to have it on PATH.
    .{
        .name = "gw-agent",
        .version = "0.9.0",
        .root = "agent/main.zig",
        .imports = &.{"glyphwire"},
        .shipped = true,
        .step = "gw-agent",
        .description = "Run the glyphwire remote-session agent (gw-agent --stdio)",
    },
    .{
        .name = "gw-ls",
        .version = "0.9.1",
        .root = "ls/main.zig",
        .imports = &.{ "glyphwire", "zargunaught", "ls_support", "applib" },
        .lua = true,
        .shipped = true,
        .step = "gw-ls",
        .description = "Run the glyphwire ls client (directory listing over the wire)",
    },
    // `applib.history` and `applib.fuzzy`: the shell's history file and
    // matcher, without the shell's Lua-embedding support module behind
    // them.
    .{
        .name = "gw-hist",
        .version = "0.9.0",
        .root = "hist/main.zig",
        .imports = &.{ "glyphwire", "applib" },
        .libc = true,
        .shipped = true,
        .step = "gw-hist",
        .description = "Run the glyphwire Ctrl+R fuzzy history search standalone",
    },
    // applib/syntax.zig -> tree_sitter (the vendored C runtime) and the
    // `dlopen` of each grammar both need libc.
    .{
        .name = "gw-grep",
        .version = "0.9.0",
        .root = "grep/main.zig",
        .imports = &.{ "glyphwire", "zargunaught", "applib" },
        .libc = true,
        .shipped = true,
        .step = "gw-grep",
        .description = "Run the glyphwire ripgrep browser (gw-grep <pattern> [path...])",
        .env = &.{grammar_dir_env},
    },
    .{
        .name = "gw-read",
        .version = "0.10.0",
        .root = "read/main.zig",
        .imports = &.{ "glyphwire", "themeconf", "zargunaught", "read_support", "applib" },
        .lua = true,
        .shipped = true,
        .step = "gw-read",
        .description = "Run the glyphwire comic reader (cbz/cbr/cb7 or a directory of images)",
    },
    .{
        .name = "gw-view",
        .version = "0.9.0",
        .root = "view/main.zig",
        .imports = &.{ "glyphwire", "zargunaught", "applib" },
        .shipped = true,
        .step = "gw-view",
        .description = "Run the glyphwire image-viewer client (gw-view <image.png>)",
    },
    .{
        .name = "gwmd",
        .version = "0.12.0",
        .root = "md/main.zig",
        .imports = &.{ "glyphwire", "zargunaught", "md_support", "applib" },
        .shipped = true,
        .step = "gwmd",
        .description = "Run the glyphwire Markdown reader (gwmd <file.md>)",
    },
    .{
        .name = "glyphwire-notify",
        .version = "0.8.1",
        .root = "notify/main.zig",
        .imports = &.{"glyphwire"},
        .shipped = true,
        .step = "notify",
        .description = "Run the glyphwire notification client (glyphwire-notify <message>)",
    },
    // zoe_support -> applib/syntax.zig -> tree_sitter, which links the
    // vendored libtree-sitter C runtime; libc comes with `lua`.
    .{
        .name = "zoe",
        .version = "0.28.0",
        .root = "zoe/main.zig",
        .imports = &.{ "glyphwire", "applib", "zoe_support", "zargunaught" },
        .lua = true,
        .shipped = true,
        .step = "zoe",
        .description = "Run the zoe editor",
        .env = &.{grammar_dir_env},
    },
    .{
        .name = "gmux",
        .version = "0.13.0",
        .root = "gmux/main.zig",
        .imports = &.{ "glyphwire", "applib", "gmux_support" },
        .lua = true,
        .shipped = true,
        .step = "gmux",
        .description = "Run gmux, the glyphwire terminal multiplexer",
    },
    // The owner-name lookup it shares with gw-ls needs libc, which comes
    // with `lua` (salacommander.conf.lua).
    .{
        .name = "salacommander",
        .version = "0.13.0",
        .root = "salacommander/main.zig",
        .imports = &.{ "glyphwire", "themeconf", "dividerconf", "applib", "zargunaught", "salacommander_support" },
        .lua = true,
        .shipped = true,
        .step = "salacommander",
        .description = "Run salacommander, the two-pane file manager (salacommander [LEFT [RIGHT]])",
    },
    .{
        .name = "glyphwire-demo",
        .root = "demo/main.zig",
        .imports = &.{"glyphwire"},
        .shipped = true,
        .step = "demo",
        .description = "Run the glyphwire styled-text demo client",
    },
    .{
        .name = "glyphwire-table-demo",
        .root = "table-demo/main.zig",
        .imports = &.{"glyphwire"},
        .step = "table_demo",
        .description = "Run the glyphwire table widget demo client",
    },
    .{
        .name = "glyphwire-client",
        .root = "client/main.zig",
        .imports = &.{"glyphwire"},
        .step = "client",
        .description = "Run the glyphwire test client",
    },
    .{
        .name = "glyphwire-probe",
        .root = "debug/main.zig",
        .imports = &.{ "glyphwire", "applib" },
        .step = "probe",
        .description = "Run glyphwire-probe against GLYPHWIRE_SOCK",
    },
    // A measuring tool, run on demand and best optimized
    // (`zig build bench-wire -Doptimize=ReleaseFast`).
    .{
        .name = "gw-wire-bench",
        .root = "bench/wire.zig",
        .imports = &.{"glyphwire"},
        .install = false,
        .step = "bench-wire",
        .description = "Benchmark the JSON and MessagePack wire encodings",
    },
};

/// A module `build` makes, under the name an `App` row imports it by.
const NamedModule = struct {
    name: []const u8,
    module: *std.Build.Module,
};

/// The module registered as `name`. A row naming a module `build` never
/// registered is a mistake in this file, so it stops the build.
fn moduleNamed(modules: []const NamedModule, name: []const u8) *std.Build.Module {
    for (modules) |m| {
        if (std.mem.eql(u8, m.name, name)) return m.module;
    }
    std.debug.panic("build.zig: no module named \"{s}\" for an apps row", .{name});
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const app_id = "dev.glyphwire.term";

    const glyphwire_mod = b.addModule("glyphwire", .{
        .root_source_file = b.path("src/glyphwire.zig"),
    });

    const installed_assets_step = b.addInstallDirectory(.{
        .source_dir = b.path("assets"),
        .install_dir = .{ .custom = "share/glyphwire" },
        .install_subdir = "assets",
    });
    b.getInstallStep().dependOn(&installed_assets_step.step);

    const installed_desktop_entry = b.addInstallFileWithDir(
        b.path(b.fmt("packaging/linux/{s}.desktop", .{app_id})),
        .{ .custom = "share/applications" },
        b.fmt("{s}.desktop", .{app_id}),
    );
    const installed_desktop_icon_svg = b.addInstallFileWithDir(
        b.path("assets/glyphwire_icon.svg"),
        .{ .custom = "share/icons/hicolor/scalable/apps" },
        "glyphwire.svg",
    );
    const installed_desktop_icon_png = b.addInstallFileWithDir(
        b.path("assets/glyphwire_icon.png"),
        .{ .custom = "share/icons/hicolor/256x256/apps" },
        "glyphwire.png",
    );

    // Application-level helpers shared by two or more of the programs
    // (the line editor, keymaps, the fuzzy finder, the shell panel, ...).
    // MPL-2.0 like `src/`, and built only on `glyphwire`'s public API --
    // see applib/applib.zig for what's in it and who uses what.
    const applib_mod = b.addModule("applib", .{
        .root_source_file = b.path("applib/applib.zig"),
    });
    applib_mod.addImport("glyphwire", glyphwire_mod);

    // applib/listcursor.zig: a list's pick + scroll arithmetic. Its own
    // module (re-exported as `applib.listcursor`) so glyphwire-host's
    // modal lists can use it without linking the rest of `applib`.
    const listcursor_mod = b.addModule("listcursor", .{
        .root_source_file = b.path("applib/listcursor.zig"),
    });
    applib_mod.addImport("listcursor", listcursor_mod);

    // applib/keybind.zig: chord text and named-action keymaps. Its own
    // module (re-exported as `applib.keybind`) for the same reason as
    // `listcursor`: glyphwire-host parses its chords with it.
    const keybind_mod = b.addModule("keybind", .{
        .root_source_file = b.path("applib/keybind.zig"),
    });
    keybind_mod.addImport("glyphwire", glyphwire_mod);
    applib_mod.addImport("keybind", keybind_mod);

    // Each program's `support.zig` is a named module so `tests/` can
    // reach it; see CONTRIBUTING.md, "The `support.zig` modules".
    const shell_support_mod = b.addModule("shell_support", .{
        .root_source_file = b.path("shell/support.zig"),
    });
    shell_support_mod.addImport("glyphwire", glyphwire_mod);
    // The line editor, word splitting and history the prompt is built on.
    shell_support_mod.addImport("applib", applib_mod);

    const ls_support_mod = b.addModule("ls_support", .{
        .root_source_file = b.path("ls/support.zig"),
    });

    const grep_support_mod = b.addModule("grep_support", .{
        .root_source_file = b.path("grep/support.zig"),
    });
    grep_support_mod.addImport("glyphwire", glyphwire_mod);
    grep_support_mod.addImport("applib", applib_mod);

    // Reading `config.theme` / `config.themes` from a Lua config: the
    // shared `theme.lua` (the host, and every program for its `themes`)
    // and a program's own override. Kept out of `applib` because it needs
    // ziglua, which would otherwise drag the Lua C library into every
    // program that uses `applib`. Its ziglua import is added below, next
    // to the other Lua consumers.
    const themeconf_mod = b.addModule("themeconf", .{
        .root_source_file = b.path("applib/themeconf.zig"),
    });
    themeconf_mod.addImport("glyphwire", glyphwire_mod);

    // applib/luaconf.zig: the shared skeleton of every `*.conf.lua`
    // loader (read the file, run it, typed `config` field readers). Its
    // own module for the same ziglua reason as `themeconf`.
    const luaconf_mod = b.addModule("luaconf", .{
        .root_source_file = b.path("applib/luaconf.zig"),
    });
    luaconf_mod.addImport("glyphwire", glyphwire_mod);
    luaconf_mod.addImport("keybind", keybind_mod);

    // applib/dividerconf.zig: a program's own `divider_style` /
    // `divider_chars` over the host's (`set_divider_style`). Its own
    // module for the same ziglua reason as `themeconf`.
    const dividerconf_mod = b.addModule("dividerconf", .{
        .root_source_file = b.path("applib/dividerconf.zig"),
    });
    dividerconf_mod.addImport("glyphwire", glyphwire_mod);

    // `host_eng` is added below, once the engine module exists.
    const host_support_mod = b.addModule("host_support", .{
        .root_source_file = b.path("host/support.zig"),
    });
    host_support_mod.addImport("glyphwire", glyphwire_mod);
    host_support_mod.addImport("listcursor", listcursor_mod);
    host_support_mod.addImport("keybind", keybind_mod);

    const zoe_support_mod = b.addModule("zoe_support", .{
        .root_source_file = b.path("zoe/support.zig"),
    });
    zoe_support_mod.addImport("glyphwire", glyphwire_mod);
    // The Ctrl+P finder, `.gitignore` rule, text sniff, `:` line field,
    // keymap and shell panel it shares with salacommander.
    zoe_support_mod.addImport("applib", applib_mod);
    zoe_support_mod.addImport("themeconf", themeconf_mod);
    zoe_support_mod.addImport("dividerconf", dividerconf_mod);

    const gmux_support_mod = b.addModule("gmux_support", .{
        .root_source_file = b.path("gmux/support.zig"),
    });
    gmux_support_mod.addImport("glyphwire", glyphwire_mod);
    gmux_support_mod.addImport("applib", applib_mod);

    const read_support_mod = b.addModule("read_support", .{
        .root_source_file = b.path("read/support.zig"),
    });
    read_support_mod.addImport("glyphwire", glyphwire_mod);
    read_support_mod.addImport("applib", applib_mod);

    // gw-yomi: the reading core (archives, mokuro, Yomitan dictionaries,
    // the Anki crop and note, the AI prompt and reply) gw-read shares with
    // the wns-reader Android app. SQLite and stb_image are compiled into
    // its module; `read/support.zig` re-exports its pieces under the names
    // gw-read has always used.
    const gw_yomi_dep = b.dependency("gw_yomi", .{ .target = target, .optimize = optimize });
    read_support_mod.addImport("gw_yomi", gw_yomi_dep.module("gw_yomi"));

    // The Markdown parser is the vendored zmd fork under `md/libs/zmd/`
    // (MIT, third-party; see its README for what glyphwire added to it).
    const zmd_mod = b.addModule("zmd", .{
        .root_source_file = b.path("md/libs/zmd/zmd.zig"),
    });
    const md_support_mod = b.addModule("md_support", .{
        .root_source_file = b.path("md/support.zig"),
    });
    md_support_mod.addImport("glyphwire", glyphwire_mod);
    md_support_mod.addImport("zmd", zmd_mod);
    md_support_mod.addImport("applib", applib_mod);

    const salacommander_support_mod = b.addModule("salacommander_support", .{
        .root_source_file = b.path("salacommander/support.zig"),
    });
    salacommander_support_mod.addImport("glyphwire", glyphwire_mod);
    // The finder, keymap, fields and shell panel it shares with zoe, and
    // `wordsplit.quoteArgIfNeeded`, so Ctrl+Shift+C answers with the same
    // shell-quoted path line gw-shell's own marked-paths copy produces.
    salacommander_support_mod.addImport("applib", applib_mod);

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
    // to run ~/.config/glyphwire/shell.conf.lua. `zlua` already links the Lua
    // C library into itself in ziglua's own build.zig; `lua_lib` is linked
    // onto each consuming executable explicitly.
    const ziglua = b.dependency("ziglua", .{ .target = target, .optimize = optimize, .lang = .lua53 });
    const ziglua_mod = ziglua.module("zlua");
    const lua_lib = ziglua.artifact("lua");

    const host_eng_mod = b.addModule("host_eng", .{
        .root_source_file = b.path("host_eng/root.zig"),
    });
    host_eng_mod.addImport("sdl3", sdl_dep.module("sdl3"));
    host_eng_mod.addImport("glyphwire", glyphwire_mod);
    host_eng_mod.addImport("zopengl", zopengl.module("root"));
    host_eng_mod.addImport("zmath", zmath.module("root"));
    host_eng_mod.addImport("zstbi", zstbi.module("root"));
    host_eng_mod.addImport("ziglua", ziglua_mod);
    host_eng_mod.addImport("stb_truetype", stbtt_mod);
    host_eng_mod.addImport("c_time", time_c_translate.createModule());
    // `host/key_repeat.zig` classifies the engine's `Key` enum and hands
    // back its `KeyRepeat` timing, so the windowless host module needs
    // the engine's types (not a window or a GL context).
    host_support_mod.addImport("host_eng", host_eng_mod);

    // shell/config.zig lives in this module and imports ziglua; both
    // gw-shell and the test runner pull it in transitively.
    shell_support_mod.addImport("ziglua", ziglua_mod);
    // ls/config.zig (glyphwire-ls's ls.conf.lua parser) does the same.
    ls_support_mod.addImport("ziglua", ziglua_mod);
    // zoe/langconf.zig (zoe.conf.lua parser) is the third ziglua consumer.
    zoe_support_mod.addImport("ziglua", ziglua_mod);
    // gmux/config.zig (gmux.conf.lua parser) is the fourth.
    gmux_support_mod.addImport("ziglua", ziglua_mod);
    // read/config.zig (read.conf.lua parser) is the fifth.
    read_support_mod.addImport("ziglua", ziglua_mod);
    // salacommander/config.zig (salacommander.conf.lua parser) is the sixth.
    salacommander_support_mod.addImport("ziglua", ziglua_mod);
    // applib/themeconf.zig (`theme.lua`, and the `theme` key of each
    // program's own config) is the seventh.
    themeconf_mod.addImport("ziglua", ziglua_mod);
    // applib/dividerconf.zig is the eighth.
    dividerconf_mod.addImport("ziglua", ziglua_mod);
    // applib/luaconf.zig, which every config loader above builds on.
    luaconf_mod.addImport("ziglua", ziglua_mod);
    shell_support_mod.addImport("luaconf", luaconf_mod);
    ls_support_mod.addImport("luaconf", luaconf_mod);
    zoe_support_mod.addImport("luaconf", luaconf_mod);
    gmux_support_mod.addImport("luaconf", luaconf_mod);
    read_support_mod.addImport("luaconf", luaconf_mod);
    salacommander_support_mod.addImport("luaconf", luaconf_mod);
    host_support_mod.addImport("luaconf", luaconf_mod);
    // The programs whose own config can override the window's theme.
    shell_support_mod.addImport("themeconf", themeconf_mod);
    read_support_mod.addImport("themeconf", themeconf_mod);
    salacommander_support_mod.addImport("themeconf", themeconf_mod);
    // The programs whose own config can override the host's divider style.
    salacommander_support_mod.addImport("dividerconf", dividerconf_mod);

    // ── syntax highlighting (zoe, gw-grep) ──
    //
    // `tree_sitter` is the Zig binding *plus* the vendored libtree-sitter
    // C runtime (its module links the static lib in), so importing it
    // into `applib` (for `applib/syntax.zig`) is enough to reach zoe,
    // gw-grep and the test runner. The grammars themselves are NOT linked
    // in: `installGrammars` compiles each to a standalone `parser.so`
    // that the highlighter `dlopen`s at runtime from the grammar search
    // path (see applib/syntax.zig).
    const tree_sitter_dep = b.dependency("tree_sitter", .{ .target = target, .optimize = optimize });
    applib_mod.addImport("tree_sitter", tree_sitter_dep.module("tree_sitter"));

    const grammars_install_dir = "share/glyphwire/grammars";
    const grammars_step = installGrammars(b, target, optimize, grammars_install_dir);

    const tests_mod = b.createModule(.{
        .root_source_file = b.path("tests/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    tests_mod.addImport("glyphwire", glyphwire_mod);
    tests_mod.addImport("applib", applib_mod);
    tests_mod.addImport("shell_support", shell_support_mod);
    tests_mod.addImport("ls_support", ls_support_mod);
    tests_mod.addImport("grep_support", grep_support_mod);
    tests_mod.addImport("themeconf", themeconf_mod);
    tests_mod.addImport("dividerconf", dividerconf_mod);
    tests_mod.addImport("luaconf", luaconf_mod);
    tests_mod.addImport("host_support", host_support_mod);
    tests_mod.addImport("zoe_support", zoe_support_mod);
    tests_mod.addImport("gmux_support", gmux_support_mod);
    tests_mod.addImport("read_support", read_support_mod);
    tests_mod.addImport("md_support", md_support_mod);
    tests_mod.addImport("salacommander_support", salacommander_support_mod);
    // `host_eng_tests` exercises the SDL3 backend's Keyboard/Mouse state
    // machines and its two wire-visible enums. They need no window and no
    // GL context -- but the module does drag libSDL3.a into the test
    // binary, which is the price of catching a renamed key before it
    // reaches the protocol.
    tests_mod.addImport("host_eng", host_eng_mod);
    // shell_support -> shell/config.zig -> ziglua: the Lua C library and
    // libc have to be linked into the final test binary.
    tests_mod.linkLibrary(lua_lib);
    tests_mod.link_libc = true;

    // testz pulls in its own `tree_sitter` dependency (for highlighting
    // failure output). Passing it the same target/optimize makes that
    // resolve to the very module `applib` already imports; with testz's
    // defaults (Debug) a release build would see `tree_sitter/root.zig`
    // in two modules and refuse to compile.
    // `addTestExe` also adds the `testz` import to `tests_mod`, and wraps it
    // in a generated root module that installs testz's panic handler, so a
    // panic inside a captured test still prints its message.
    const tests_exe = testz.addTestExe(b, .{
        .target = target,
        .optimize = optimize,
        .testz_dep = b.dependency("testz", .{ .target = target, .optimize = optimize }),
        .name = "tests",
        .root_module = tests_mod,
    });

    // The `e2e` group spawns the real `gw-shell` / `gw-ls` binaries and
    // drives them over real sockets and pty pairs, and it is flaky on the
    // CI runner: a run that passes locally failed three of them there.
    // CI therefore builds with `-Dskip-e2e=true` until that is fixed,
    // while a plain `zig build tests` still runs the group. tests/main.zig
    // discovers the group either way and only drops it from what it hands
    // the runner, so `tests/e2e_tests.zig` keeps getting compiled.
    const skip_e2e = b.option(
        bool,
        "skip-e2e",
        "Do not run the end-to-end test group (still compiled; used by CI while those tests are flaky)",
    ) orelse false;
    const tests_options = b.addOptions();
    tests_options.addOption(bool, "skip_e2e", skip_e2e);
    tests_mod.addImport("build_options", tests_options.createModule());

    b.installArtifact(tests_exe);

    const run_tests = b.addRunArtifact(tests_exe);
    run_tests.step.dependOn(b.getInstallStep());
    run_tests.addPassthruArgs();

    const test_step = b.step("tests", "Run unit tests");
    test_step.dependOn(&run_tests.step);

    const modules = [_]NamedModule{
        .{ .name = "glyphwire", .module = glyphwire_mod },
        .{ .name = "applib", .module = applib_mod },
        .{ .name = "listcursor", .module = listcursor_mod },
        .{ .name = "keybind", .module = keybind_mod },
        .{ .name = "themeconf", .module = themeconf_mod },
        .{ .name = "luaconf", .module = luaconf_mod },
        .{ .name = "dividerconf", .module = dividerconf_mod },
        .{ .name = "ziglua", .module = ziglua_mod },
        .{ .name = "zargunaught", .module = zargunaught_mod },
        .{ .name = "host_eng", .module = host_eng_mod },
        .{ .name = "shell_support", .module = shell_support_mod },
        .{ .name = "ls_support", .module = ls_support_mod },
        .{ .name = "grep_support", .module = grep_support_mod },
        .{ .name = "host_support", .module = host_support_mod },
        .{ .name = "zoe_support", .module = zoe_support_mod },
        .{ .name = "gmux_support", .module = gmux_support_mod },
        .{ .name = "read_support", .module = read_support_mod },
        .{ .name = "md_support", .module = md_support_mod },
        .{ .name = "salacommander_support", .module = salacommander_support_mod },
    };

    // `zig build package` installs just the shipped programs and bundled
    // assets that go in the Linux release tarball, without also building
    // the test runner or the internal tools plain `zig build` pulls in.
    // The CI packaging job (.github/workflows/linux-package.yml) drives
    // it. `install-local` installs the same set under any prefix (what
    // provision_remote and the remote-test image put on a box).
    const package_step = b.step("package", "Install the shipped programs and assets into zig-out");
    const install_local_step = b.step("install-local", "Install the shipped programs, grammars and assets under the selected prefix");

    const git = gitDescribe(b);
    for (apps) |app| {
        const exe = b.addExecutable(.{
            .name = app.name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(app.root),
                .target = target,
                .optimize = optimize,
            }),
        });
        for (app.imports) |name| exe.root_module.addImport(name, moduleNamed(&modules, name));
        if (app.lua) exe.root_module.linkLibrary(lua_lib);
        if (app.lua or app.libc) exe.root_module.link_libc = true;
        if (app.version) |version| addBuildInfo(b, exe, version, git);

        const run = b.addRunArtifact(exe);
        if (app.install) {
            b.installArtifact(exe);
            run.step.dependOn(b.getInstallStep());
        }
        for (app.env) |env| run.setEnvironmentVariable(env.name, b.pathJoin(env.path));
        run.addPassthruArgs();
        b.step(app.step, app.description).dependOn(&run.step);

        if (app.shipped) {
            package_step.dependOn(&b.addInstallArtifact(exe, .{}).step);
            install_local_step.dependOn(&b.addInstallArtifact(exe, .{}).step);
        }
    }

    // Neither step pulls in the default install step, so each needs the
    // assets, desktop entry and icons, and zoe's grammars (it dlopens them
    // from share/glyphwire/grammars at runtime) on its own.
    for ([_]*std.Build.Step{ package_step, install_local_step }) |step| {
        step.dependOn(&installed_assets_step.step);
        step.dependOn(&installed_desktop_entry.step);
        step.dependOn(&installed_desktop_icon_svg.step);
        step.dependOn(&installed_desktop_icon_png.step);
        step.dependOn(grammars_step);
    }
}

/// Gives `exe` a `build_info` module: `program` (its executable name),
/// `version` (from its `apps` row), `suite_version` and `git`.
/// `glyphwire.version` formats it.
fn addBuildInfo(b: *std.Build, exe: *std.Build.Step.Compile, version: []const u8, git: []const u8) void {
    const opts = b.addOptions();
    opts.addOption([]const u8, "program", exe.name);
    opts.addOption([]const u8, "version", version);
    opts.addOption([]const u8, "suite_version", suite_version);
    opts.addOption([]const u8, "git", git);
    exe.root_module.addImport("build_info", opts.createModule());
}

/// `git describe --always --dirty --tags` of the source tree: a tag once
/// there are any (`v0.8.0`, `v0.8.0-3-g1e34abf`), else the short commit
/// (`1e34abf`), with `-dirty` while there are uncommitted changes.
/// "unknown" outside a git checkout (a source tarball) or without git.
/// Run on every `zig build`; a program's build is only redone when the
/// answer changes (a commit, or the tree going dirty or clean).
fn gitDescribe(b: *std.Build) []const u8 {
    var code: u8 = 0;
    const root = b.root.joinString(b.allocator, ".") catch return "unknown";
    const out = b.runAllowFail(&.{ "git", "-C", root, "describe", "--always", "--dirty", "--tags" }, &code, .ignore) catch return "unknown";
    return std.mem.trim(u8, out, " \n\r\t");
}

/// One bundled tree-sitter grammar: the lazy-dependency name holding its
/// generated parser, an optional in-repo subdirectory (the Markdown repo
/// nests two grammars), whether it ships an external `scanner.c`, and the
/// grammar-search-path directory name zoe loads it as.
const BundledGrammar = struct {
    name: []const u8,
    dep: []const u8,
    /// When set, the grammar sources are vendored in-tree at this path
    /// (relative to the build root) instead of fetched as `dep`. Used for
    /// grammars whose upstream ships a `build.zig` that does not build on
    /// current Zig (tree-sitter-c), so listing it as a package dependency
    /// would fail at configure time even though we only read its sources.
    vendored: ?[]const u8 = null,
    subdir: []const u8 = "",
    scanner: bool = false,
    /// The grammar dir also ships `queries/injections.scm`, to install
    /// alongside `highlights.scm` so zoe can highlight embedded languages.
    injections: bool = false,
};

const bundled_grammars = [_]BundledGrammar{
    .{ .name = "zig", .dep = "grammar_zig", .injections = true },
    .{ .name = "json", .dep = "grammar_json" },
    .{ .name = "c", .dep = "grammar_c", .vendored = "vendor/grammars/c" },
    .{ .name = "python", .dep = "grammar_python", .scanner = true },
    .{ .name = "toml", .dep = "grammar_toml", .scanner = true },
    // Lua's `injections.scm` only reaches into `ffi.cdef` strings, but it
    // costs one file to ship and the C grammar it wants is already here.
    .{ .name = "lua", .dep = "grammar_lua", .scanner = true, .injections = true },
    .{ .name = "bash", .dep = "grammar_bash", .scanner = true },
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
/// has one) alongside, wired onto the default install step. Returns a
/// `grammars` step the `package` / `install-local` steps also depend on,
/// since those don't pull in the default install step but a packaged zoe
/// still needs its grammars. The grammar deps are lazy, so a plain
/// `zig build` only fetches them because this runs; nothing links them
/// into a Zig binary.
fn installGrammars(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    install_dir: []const u8,
) *std.Build.Step {
    const grammars_step = b.step("grammars", "Compile and install the bundled tree-sitter grammars");
    for (bundled_grammars) |g| {
        // `srcPath` yields a LazyPath to a file inside the grammar, from
        // either the vendored in-tree copy or the fetched dependency.
        const Ctx = struct {
            b: *std.Build,
            dep: ?*std.Build.Dependency,
            g: BundledGrammar,
            fn srcPath(ctx: @This(), rel: []const u8) std.Build.LazyPath {
                const sub = ctx.b.fmt("{s}{s}", .{ ctx.g.subdir, rel });
                if (ctx.g.vendored) |base| return ctx.b.path(ctx.b.fmt("{s}/{s}", .{ base, sub }));
                return ctx.dep.?.path(sub);
            }
        };
        const dep: ?*std.Build.Dependency = if (g.vendored != null) null else (b.lazyDependency(g.dep, .{}) orelse continue);
        const ctx = Ctx{ .b = b, .dep = dep, .g = g };

        const lib = b.addLibrary(.{
            .name = b.fmt("tree-sitter-{s}", .{g.name}),
            .linkage = .dynamic,
            .root_module = b.createModule(.{
                .target = target,
                .optimize = optimize,
                .link_libc = true,
            }),
        });
        // C23, not C11: most scanners declare `..._external_scanner_create()`,
        // which before C23 is an unprototyped function, while libtree-sitter
        // calls it through a `void *(*)(void)`. Zig builds C with
        // `-fsanitize=function` in safe modes, so under C11 a ReleaseSafe
        // zoe trapped (SIGILL) on the first parse of any grammar with a
        // scanner. In C23 `()` means `(void)` and the types agree.
        lib.root_module.addCSourceFile(.{
            .file = ctx.srcPath("src/parser.c"),
            .flags = &.{"-std=c23"},
        });
        if (g.scanner) lib.root_module.addCSourceFile(.{
            .file = ctx.srcPath("src/scanner.c"),
            .flags = &.{"-std=c23"},
        });
        lib.root_module.addIncludePath(ctx.srcPath("src"));

        const dest: std.Build.InstallDir = .{ .custom = b.fmt("{s}/{s}", .{ install_dir, g.name }) };
        const inst_lib = b.addInstallArtifact(lib, .{ .dest_dir = .{ .override = dest } });
        const inst_scm = b.addInstallFileWithDir(
            ctx.srcPath("queries/highlights.scm"),
            dest,
            "highlights.scm",
        );
        b.getInstallStep().dependOn(&inst_lib.step);
        b.getInstallStep().dependOn(&inst_scm.step);
        grammars_step.dependOn(&inst_lib.step);
        grammars_step.dependOn(&inst_scm.step);

        if (g.injections) {
            const inst_inj = b.addInstallFileWithDir(
                ctx.srcPath("queries/injections.scm"),
                dest,
                "injections.scm",
            );
            b.getInstallStep().dependOn(&inst_inj.step);
            grammars_step.dependOn(&inst_inj.step);
        }
    }
    return grammars_step;
}
