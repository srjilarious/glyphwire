const std = @import("std");

const Build = std.Build;
const Step = std.Build.Step;

const applyPatchToFile = @import("utils.zig").applyPatchToFile;

pub const Language = enum {
    lua51,
    lua52,
    lua53,
    lua54,
    luajit,
    luau,
};

pub const Options = struct {
    lang: Language,
    shared: bool,
    library_name: []const u8,
    lua_user_h: ?Build.LazyPath,
};

pub fn configure(
    b: *Build,
    target: Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    upstream: *Build.Dependency,
    opts: Options,
) *Step.Compile {
    const lang = opts.lang;
    const library_name = opts.library_name;
    const lua_user_h = opts.lua_user_h;
    const shared = opts.shared;

    const version: std.SemanticVersion = switch (lang) {
        .lua51 => .{ .major = 5, .minor = 1, .patch = 5 },
        .lua52 => .{ .major = 5, .minor = 2, .patch = 4 },
        .lua53 => .{ .major = 5, .minor = 3, .patch = 6 },
        .lua54 => .{ .major = 5, .minor = 4, .patch = 8 },
        else => unreachable,
    };

    const lib = b.createModule(.{
        .target = target,
        .optimize = optimize,
    });
    const library = b.addLibrary(.{
        .name = library_name,
        .version = version,
        .linkage = if (shared) .dynamic else .static,
        .root_module = lib,
    });

    lib.addIncludePath(upstream.path("src"));

    const user_header = "user.h";

    const flags = [_][]const u8{
        // Standard version used in Lua Makefile
        "-std=gnu99",

        // Define target-specific macro
        switch (target.result.os.tag) {
            .linux => "-DLUA_USE_LINUX",
            .macos => "-DLUA_USE_MACOSX",
            .windows => "-DLUA_USE_WINDOWS",
            else => "-DLUA_USE_POSIX",
        },

        // Enable api check
        if (optimize == .Debug) "-DLUA_USE_APICHECK" else "",

        // Build as DLL for windows if shared
        if (target.result.os.tag == .windows and shared) "-DLUA_BUILD_AS_DLL" else "",

        if (lua_user_h) |_| b.fmt("-DLUA_USER_H=\"{s}\"", .{user_header}) else "",
    };

    const lua_source_files = switch (lang) {
        .lua51 => &lua_base_source_files,
        .lua52 => &lua_52_source_files,
        .lua53 => &lua_53_source_files,
        .lua54 => &lua_54_source_files,
        else => unreachable,
    };

    // PIXZIG: Emscripten requires compiling each C file separately
    if (target.result.os.tag != .emscripten) {
        lib.addCSourceFiles(.{
            .root = .{ .dependency = .{
                .dependency = upstream,
                .sub_path = "",
            } },
            .files = lua_source_files,
            .flags = &flags,
        });
    } else {
        for (lua_source_files) |file| {
            const compile_lua = emCompileStep(
                b,
                upstream.path(file),
                optimize,
                &flags,
            );
            lib.addObjectFile(compile_lua);
        }
    }

    // PIXZIG: Add patch back in.
    // Patch ldo.c for Lua 5.1
    // if (lang == .lua51) {
    //     const patched = applyPatchToFile(b, b.graph.host, upstream.path("src/ldo.c"), b.path("build/lua-5.1.patch"), "ldo.c");

    //     library.step.dependOn(&patched.run.step);

    //     lib.addCSourceFile(.{ .file = patched.output, .flags = &flags });
    // }

    library.root_module.link_libc = true;

    library.installHeader(upstream.path("src/lua.h"), "lua.h");
    library.installHeader(upstream.path("src/lualib.h"), "lualib.h");
    library.installHeader(upstream.path("src/lauxlib.h"), "lauxlib.h");
    library.installHeader(upstream.path("src/luaconf.h"), "luaconf.h");

    if (lua_user_h) |user_h| {
        library.root_module.addIncludePath(user_h.dirname());
        library.installHeader(user_h, user_header);
    }

    return library;
}

pub fn emCompileStep(b: *Build, filename: Build.LazyPath, optimize: std.builtin.OptimizeMode, extra_flags: []const []const u8) Build.LazyPath {
    // const emcc_path = emSdkLazyPath(b, emsdk, &.{ "upstream", "emscripten", "emcc" }).getPath(b);
    // const emcc = b.addSystemCommand(&.{emcc_path});
    const emcc_exe_path = "emcc";
    const emcc = b.addSystemCommand(&[_][]const u8{emcc_exe_path});
    emcc.setName("emcc"); // hide emcc path
    emcc.addArg("-c");
    if (optimize == .ReleaseSmall) {
        emcc.addArg("-Oz");
    } else if (optimize == .ReleaseFast or optimize == .ReleaseSafe) {
        emcc.addArg("-O3");
    }
    emcc.addFileArg(filename);
    for (extra_flags) |flag| {
        emcc.addArg(flag);
    }
    emcc.addArg("-o");

    const output_name = switch (filename) {
        .dependency => filename.dependency.sub_path,
        .src_path => filename.src_path.sub_path,
        .cwd_relative => filename.cwd_relative,
        .generated => filename.generated.sub_path,
    };

    const output = emcc.addOutputFileArg(b.fmt("{s}.o", .{output_name}));
    return output;
}

const lua_base_source_files = [_][]const u8{
    "src/lapi.c",
    "src/lcode.c",
    "src/ldebug.c",
    "src/ldump.c",
    "src/lfunc.c",
    "src/lgc.c",
    "src/llex.c",
    "src/lmem.c",
    "src/lobject.c",
    "src/lopcodes.c",
    "src/lparser.c",
    "src/lstate.c",
    "src/lstring.c",
    "src/ltable.c",
    "src/ltm.c",
    "src/lundump.c",
    "src/lvm.c",
    "src/lzio.c",
    "src/lauxlib.c",
    "src/lbaselib.c",
    "src/ldblib.c",
    "src/liolib.c",
    "src/lmathlib.c",
    "src/loslib.c",
    "src/ltablib.c",
    "src/lstrlib.c",
    "src/loadlib.c",
    "src/linit.c",
};

const lua_52_source_files = lua_base_source_files ++ [_][]const u8{
    "src/ldo.c",
    "src/lctype.c",
    "src/lbitlib.c",
    "src/lcorolib.c",
};

const lua_53_source_files = lua_base_source_files ++ [_][]const u8{
    "src/ldo.c",
    "src/lctype.c",
    "src/lbitlib.c",
    "src/lcorolib.c",
    "src/lutf8lib.c",
};

const lua_54_source_files = lua_base_source_files ++ [_][]const u8{
    "src/ldo.c",
    "src/lctype.c",
    "src/lcorolib.c",
    "src/lutf8lib.c",
};
