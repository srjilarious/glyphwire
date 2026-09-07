const std = @import("std");
const testz = @import("testz");

// The shell's session-long Lua interpreter (see shell/script_engine.zig).
// Like `config`, it embeds a real Lua 5.3 state, so these tests run
// actual scripts and assert on what the engine does with the shell
// (through a stub `HostHooks`).
const script_engine = @import("shell_support").script_engine;

// ─── stub host ───────────────────────────────────────────────────────

/// Stands in for the live `Prompt`: an in-memory environment, a captured
/// output buffer, and a settable interrupt flag.
const TestHost = struct {
    alloc: std.mem.Allocator,
    env: std.StringHashMapUnmanaged([]const u8) = .empty,
    out: std.ArrayListUnmanaged(u8) = .empty,
    interrupt: bool = false,
    /// Last path `sh.chdir` was asked to change to.
    chdir_to: ?[]const u8 = null,

    fn deinit(self: *TestHost) void {
        var it = self.env.iterator();
        while (it.next()) |e| {
            self.alloc.free(e.key_ptr.*);
            self.alloc.free(e.value_ptr.*);
        }
        self.env.deinit(self.alloc);
        self.out.deinit(self.alloc);
        if (self.chdir_to) |p| self.alloc.free(p);
    }

    fn hooks(self: *TestHost) script_engine.HostHooks {
        return .{
            .ctx = self,
            .setenv = tSetenv,
            .unsetenv = tUnsetenv,
            .getenv = tGetenv,
            .cwd = tCwd,
            .chdir = tChdir,
            .realpath = tRealpath,
            .write = tWrite,
            .poll_interrupt = tPollInterrupt,
            .run_line = tRunLine,
        };
    }

    fn output(self: *TestHost) []const u8 {
        return self.out.items;
    }
};

fn tSetenv(ctx: *anyopaque, name: []const u8, value: []const u8) void {
    const self: *TestHost = @ptrCast(@alignCast(ctx));
    if (self.env.fetchRemove(name)) |kv| {
        self.alloc.free(kv.key);
        self.alloc.free(kv.value);
    }
    const k = self.alloc.dupe(u8, name) catch return;
    const v = self.alloc.dupe(u8, value) catch {
        self.alloc.free(k);
        return;
    };
    self.env.put(self.alloc, k, v) catch {
        self.alloc.free(k);
        self.alloc.free(v);
    };
}

fn tUnsetenv(ctx: *anyopaque, name: []const u8) void {
    const self: *TestHost = @ptrCast(@alignCast(ctx));
    if (self.env.fetchRemove(name)) |kv| {
        self.alloc.free(kv.key);
        self.alloc.free(kv.value);
    }
}

fn tGetenv(ctx: *anyopaque, name: []const u8) ?[]const u8 {
    const self: *TestHost = @ptrCast(@alignCast(ctx));
    return self.env.get(name);
}

fn tCwd(ctx: *anyopaque, buf: []u8) ?[]const u8 {
    _ = ctx;
    const cwd = "/tmp";
    @memcpy(buf[0..cwd.len], cwd);
    return buf[0..cwd.len];
}

fn tChdir(ctx: *anyopaque, path: [:0]const u8) bool {
    const self: *TestHost = @ptrCast(@alignCast(ctx));
    if (self.chdir_to) |p| self.alloc.free(p);
    self.chdir_to = self.alloc.dupe(u8, path) catch null;
    return true;
}

fn tRealpath(ctx: *anyopaque, path: [:0]const u8, buf: []u8) ?[]const u8 {
    _ = ctx;
    if (path.len >= buf.len) return null;
    @memcpy(buf[0..path.len], path);
    return buf[0..path.len];
}

fn tWrite(ctx: *anyopaque, bytes: []const u8) void {
    const self: *TestHost = @ptrCast(@alignCast(ctx));
    self.out.appendSlice(self.alloc, bytes) catch {};
}

fn tPollInterrupt(ctx: *anyopaque) bool {
    const self: *TestHost = @ptrCast(@alignCast(ctx));
    return self.interrupt;
}

/// Stub pipeline runner: the real one forks processes, out of scope for a
/// unit test. Echoes `line` into `out` when capturing so `sh.run`'s table
/// shape can still be asserted; always "succeeds".
fn tRunLine(
    ctx: *anyopaque,
    line: []const u8,
    capture: bool,
    stdin: []const u8,
    out: *std.ArrayList(u8),
    err: *std.ArrayList(u8),
) u8 {
    const self: *TestHost = @ptrCast(@alignCast(ctx));
    _ = err;
    if (capture) {
        out.appendSlice(self.alloc, line) catch {};
        out.appendSlice(self.alloc, stdin) catch {};
    } else {
        self.out.appendSlice(self.alloc, line) catch {};
    }
    return 0;
}

// ─── helpers ─────────────────────────────────────────────────────────

/// A fresh engine with no config directory (so only `defcmd` builtins
/// exist). Caller `defer`s `eng.deinit()` and `host.deinit()`.
fn newEngine(io: std.Io, host: *TestHost) !*script_engine.ScriptEngine {
    return script_engine.ScriptEngine.init(host.alloc, io, host.hooks(), null);
}

fn uniqueDir(alloc: std.mem.Allocator, tag: []const u8) ![]const u8 {
    return std.fmt.allocPrint(alloc, "/tmp/glyphwire-se-{s}-{d}", .{ tag, std.Thread.getCurrentId() });
}

// ─── shell.conf through the persistent state ─────────────────────────

pub fn runConfCollectsAliasesTest(io: std.Io, alloc: std.mem.Allocator) !void {
    var host = TestHost{ .alloc = alloc };
    defer host.deinit();
    const eng = try newEngine(io, &host);
    defer eng.deinit();

    try eng.runConf(
        \\alias("ll", "ls -l")
        \\alias("gs", "git status")
    );
    try testz.expectEqual(eng.conf_err, null);
    try testz.expectEqual(eng.cfg.aliases.items.len, 2);
    try testz.expectEqualStr("ll", eng.cfg.aliases.items[0].name);
    try testz.expectEqualStr("git status", eng.cfg.aliases.items[1].value);
}

pub fn runConfCapturesErrorButStaysUsableTest(io: std.Io, alloc: std.mem.Allocator) !void {
    var host = TestHost{ .alloc = alloc };
    defer host.deinit();
    const eng = try newEngine(io, &host);
    defer eng.deinit();

    // A runtime error partway through: Lua stops at the failing line, so
    // the `alias` before it is still collected.
    try eng.runConf("alias('ok', 'cd ~')\nerror('boom')");
    try testz.expectTrue(eng.conf_err != null);
    try testz.expectEqual(eng.cfg.aliases.items.len, 1);

    // A second run clears the stale diagnostic and works.
    try eng.runConf("alias('a', 'b')");
    try testz.expectEqual(eng.conf_err, null);
}

// ─── sh.* environment surface ────────────────────────────────────────

pub fn shSetenvReachesTheHostTest(io: std.Io, alloc: std.mem.Allocator) !void {
    var host = TestHost{ .alloc = alloc };
    defer host.deinit();
    const eng = try newEngine(io, &host);
    defer eng.deinit();

    try eng.runConf("sh.setenv('GW_TEST', 'yes')");
    try testz.expectEqual(eng.conf_err, null);
    try testz.expectEqualStr("yes", host.env.get("GW_TEST").?);
}

pub fn shGetenvSeesHostValuesTest(io: std.Io, alloc: std.mem.Allocator) !void {
    var host = TestHost{ .alloc = alloc };
    defer host.deinit();
    tSetenv(&host, "GW_PRESET", "here");
    const eng = try newEngine(io, &host);
    defer eng.deinit();

    // A builtin reads the preset back through `sh.getenv` and prints it.
    try eng.runConf("defcmd('readit', function() print(sh.getenv('GW_PRESET')) end)");
    try testz.expectEqual(eng.conf_err, null);
    _ = eng.runCommand("readit", &.{});
    try testz.expectEqualStr("here\n", host.output());
}

pub fn shUnsetenvRemovesTest(io: std.Io, alloc: std.mem.Allocator) !void {
    var host = TestHost{ .alloc = alloc };
    defer host.deinit();
    tSetenv(&host, "GW_GONE", "1");
    const eng = try newEngine(io, &host);
    defer eng.deinit();

    try eng.runConf("sh.unsetenv('GW_GONE')");
    try testz.expectEqual(eng.conf_err, null);
    try testz.expectEqual(host.env.get("GW_GONE"), null);
}

// ─── defcmd builtins ─────────────────────────────────────────────────

pub fn defcmdRegistersABuiltinTest(io: std.Io, alloc: std.mem.Allocator) !void {
    var host = TestHost{ .alloc = alloc };
    defer host.deinit();
    const eng = try newEngine(io, &host);
    defer eng.deinit();

    try eng.runConf("defcmd('greet', function() print('hi there') end)");
    try testz.expectEqual(eng.conf_err, null);
    try testz.expectTrue(eng.hasCommand("greet"));
    try testz.expectTrue(!eng.hasCommand("nope"));

    const code = eng.runCommand("greet", &.{});
    try testz.expectEqual(code, @as(u8, 0));
    try testz.expectEqualStr("hi there\n", host.output());
}

pub fn builtinNumericReturnIsTheExitCodeTest(io: std.Io, alloc: std.mem.Allocator) !void {
    var host = TestHost{ .alloc = alloc };
    defer host.deinit();
    const eng = try newEngine(io, &host);
    defer eng.deinit();

    try eng.runConf("defcmd('boom', function() return 3 end)");
    try testz.expectEqual(eng.runCommand("boom", &.{}), @as(u8, 3));
}

pub fn builtinArgsArriveAsArgAndVarargsTest(io: std.Io, alloc: std.mem.Allocator) !void {
    var host = TestHost{ .alloc = alloc };
    defer host.deinit();
    const eng = try newEngine(io, &host);
    defer eng.deinit();

    try eng.runConf(
        \\defcmd('show', function(...)
        \\  local a = {...}
        \\  print(arg[0], arg[1], a[2])
        \\end)
    );
    _ = eng.runCommand("show", &.{ "one", "two" });
    try testz.expectEqualStr("show\tone\ttwo\n", host.output());
}

pub fn builtinLuaErrorIsReportedNotFatalTest(io: std.Io, alloc: std.mem.Allocator) !void {
    var host = TestHost{ .alloc = alloc };
    defer host.deinit();
    const eng = try newEngine(io, &host);
    defer eng.deinit();

    try eng.runConf("defcmd('bad', function() error('nope') end)");
    const code = eng.runCommand("bad", &.{});
    try testz.expectEqual(code, @as(u8, 1));
    try testz.expectTrue(std.mem.indexOf(u8, host.output(), "bad:") != null);
    try testz.expectTrue(std.mem.indexOf(u8, host.output(), "nope") != null);

    // Still usable afterwards.
    try eng.runConf("defcmd('ok', function() print('fine') end)");
    host.out.clearRetainingCapacity();
    _ = eng.runCommand("ok", &.{});
    try testz.expectEqualStr("fine\n", host.output());
}

pub fn osExitIsDisabledTest(io: std.Io, alloc: std.mem.Allocator) !void {
    var host = TestHost{ .alloc = alloc };
    defer host.deinit();
    const eng = try newEngine(io, &host);
    defer eng.deinit();

    try eng.runConf("defcmd('quit', function() os.exit(0) end)");
    const code = eng.runCommand("quit", &.{});
    try testz.expectEqual(code, @as(u8, 1));
    try testz.expectTrue(std.mem.indexOf(u8, host.output(), "disabled") != null);
}

pub fn ctrlCInterruptsALongRunningBuiltinTest(io: std.Io, alloc: std.mem.Allocator) !void {
    var host = TestHost{ .alloc = alloc };
    defer host.deinit();
    host.interrupt = true; // the "Ctrl-C is pending" signal the hook polls
    const eng = try newEngine(io, &host);
    defer eng.deinit();

    try eng.runConf("defcmd('spin', function() while true do end end)");
    const code = eng.runCommand("spin", &.{});
    try testz.expectEqual(code, @as(u8, 1));
    try testz.expectTrue(std.mem.indexOf(u8, host.output(), "interrupted") != null);
}

// ─── sh.run / sh.exec ────────────────────────────────────────────────

pub fn shRunReturnsAResultTableTest(io: std.Io, alloc: std.mem.Allocator) !void {
    var host = TestHost{ .alloc = alloc };
    defer host.deinit();
    const eng = try newEngine(io, &host);
    defer eng.deinit();

    // `tRunLine` echoes the command line into `out` and reports success,
    // so this exercises the binding's table shape without forking.
    try eng.runConf(
        \\defcmd('probe', function()
        \\  local r = sh.run('echo hello')
        \\  print(tostring(r.code) .. ':' .. tostring(r.ok) .. ':' .. r.out)
        \\end)
    );
    _ = eng.runCommand("probe", &.{});
    try testz.expectEqualStr("0:true:echo hello\n", host.output());
}

pub fn shRunFeedsItsStdinArgumentTest(io: std.Io, alloc: std.mem.Allocator) !void {
    var host = TestHost{ .alloc = alloc };
    defer host.deinit();
    const eng = try newEngine(io, &host);
    defer eng.deinit();

    try eng.runConf(
        \\defcmd('probe', function()
        \\  print(sh.run('cat', 'PIPED').out)
        \\end)
    );
    _ = eng.runCommand("probe", &.{});
    try testz.expectEqualStr("catPIPED\n", host.output());
}

pub fn shExecReturnsJustTheStatusTest(io: std.Io, alloc: std.mem.Allocator) !void {
    var host = TestHost{ .alloc = alloc };
    defer host.deinit();
    const eng = try newEngine(io, &host);
    defer eng.deinit();

    try eng.runConf("defcmd('runit', function() return sh.exec('anything') end)");
    try testz.expectEqual(eng.runCommand("runit", &.{}), @as(u8, 0));
}

pub fn pathSeparatorNamesAreNeverBuiltinsTest(io: std.Io, alloc: std.mem.Allocator) !void {
    var host = TestHost{ .alloc = alloc };
    defer host.deinit();
    const eng = try newEngine(io, &host);
    defer eng.deinit();

    try testz.expectTrue(!eng.hasCommand("a/b"));
    try testz.expectTrue(!eng.hasCommand("../etc/passwd"));
    try testz.expectTrue(!eng.hasCommand(""));
    try testz.expectTrue(!eng.hasCommand("."));
}

// ─── script files under <config_dir>/scripts ─────────────────────────

pub fn scriptFileIsABuiltinByBasenameTest(io: std.Io, alloc: std.mem.Allocator) !void {
    const cfg_dir = try uniqueDir(alloc, "file");
    defer alloc.free(cfg_dir);
    const scripts_dir = try std.fs.path.join(alloc, &.{ cfg_dir, "scripts" });
    defer alloc.free(scripts_dir);
    try std.Io.Dir.cwd().createDirPath(io, scripts_dir);
    defer std.Io.Dir.cwd().deleteTree(io, cfg_dir) catch {};

    const script_path = try std.fs.path.join(alloc, &.{ scripts_dir, "hello.lua" });
    defer alloc.free(script_path);
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = script_path,
        .data = "print('from file ' .. arg[1])\n",
    });

    var host = TestHost{ .alloc = alloc };
    defer host.deinit();
    const eng = try script_engine.ScriptEngine.init(alloc, io, host.hooks(), cfg_dir);
    defer eng.deinit();

    try testz.expectTrue(eng.hasCommand("hello"));
    try testz.expectTrue(!eng.hasCommand("missing"));

    const code = eng.runCommand("hello", &.{"x"});
    try testz.expectEqual(code, @as(u8, 0));
    try testz.expectEqualStr("from file x\n", host.output());
}

pub fn scriptCanRequireFromLibTest(io: std.Io, alloc: std.mem.Allocator) !void {
    const cfg_dir = try uniqueDir(alloc, "lib");
    defer alloc.free(cfg_dir);
    const lib_dir = try std.fs.path.join(alloc, &.{ cfg_dir, "scripts", "lib" });
    defer alloc.free(lib_dir);
    try std.Io.Dir.cwd().createDirPath(io, lib_dir);
    defer std.Io.Dir.cwd().deleteTree(io, cfg_dir) catch {};

    const greeter = try std.fs.path.join(alloc, &.{ lib_dir, "greeter.lua" });
    defer alloc.free(greeter);
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = greeter,
        .data = "return { hi = function() return 'hey' end }\n",
    });

    const user = try std.fs.path.join(alloc, &.{ cfg_dir, "scripts", "usereq.lua" });
    defer alloc.free(user);
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = user,
        .data = "local g = require('greeter')\nprint(g.hi())\n",
    });

    var host = TestHost{ .alloc = alloc };
    defer host.deinit();
    const eng = try script_engine.ScriptEngine.init(alloc, io, host.hooks(), cfg_dir);
    defer eng.deinit();

    const code = eng.runCommand("usereq", &.{});
    try testz.expectEqual(code, @as(u8, 0));
    try testz.expectEqualStr("hey\n", host.output());
}

pub fn defcmdShadowsAScriptFileTest(io: std.Io, alloc: std.mem.Allocator) !void {
    const cfg_dir = try uniqueDir(alloc, "shadow");
    defer alloc.free(cfg_dir);
    const scripts_dir = try std.fs.path.join(alloc, &.{ cfg_dir, "scripts" });
    defer alloc.free(scripts_dir);
    try std.Io.Dir.cwd().createDirPath(io, scripts_dir);
    defer std.Io.Dir.cwd().deleteTree(io, cfg_dir) catch {};

    const script_path = try std.fs.path.join(alloc, &.{ scripts_dir, "dup.lua" });
    defer alloc.free(script_path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = script_path, .data = "print('from file')\n" });

    var host = TestHost{ .alloc = alloc };
    defer host.deinit();
    const eng = try script_engine.ScriptEngine.init(alloc, io, host.hooks(), cfg_dir);
    defer eng.deinit();

    try eng.runConf("defcmd('dup', function() print('from defcmd') end)");
    _ = eng.runCommand("dup", &.{});
    try testz.expectEqualStr("from defcmd\n", host.output());
}

// ─── collectCommandNames (Tab completion, command position) ───────────

/// Frees an owned `[]const []const u8` and the list itself.
fn freeNames(alloc: std.mem.Allocator, names: *std.ArrayList([]const u8)) void {
    for (names.items) |n| alloc.free(n);
    names.deinit(alloc);
}

/// Whether `list` contains `want` (order from `collectCommandNames` is
/// unspecified).
fn hasName(list: []const []const u8, want: []const u8) bool {
    for (list) |n| {
        if (std.mem.eql(u8, n, want)) return true;
    }
    return false;
}

pub fn collectCommandNamesReturnsDefcmdNamesTest(io: std.Io, alloc: std.mem.Allocator) !void {
    var host = TestHost{ .alloc = alloc };
    defer host.deinit();
    const eng = try newEngine(io, &host);
    defer eng.deinit();

    try eng.runConf(
        \\defcmd('deploy', function() end)
        \\defcmd('depcheck', function() end)
        \\defcmd('build', function() end)
    );
    try testz.expectEqual(eng.conf_err, null);

    var names: std.ArrayList([]const u8) = .empty;
    defer freeNames(alloc, &names);
    try eng.collectCommandNames(alloc, "dep", &names);

    try testz.expectEqual(names.items.len, 2);
    try testz.expectTrue(hasName(names.items, "deploy"));
    try testz.expectTrue(hasName(names.items, "depcheck"));
    try testz.expectTrue(!hasName(names.items, "build"));
}

pub fn collectCommandNamesEmptyPrefixReturnsAllTest(io: std.Io, alloc: std.mem.Allocator) !void {
    var host = TestHost{ .alloc = alloc };
    defer host.deinit();
    const eng = try newEngine(io, &host);
    defer eng.deinit();

    try eng.runConf("defcmd('a', function() end)\ndefcmd('b', function() end)");
    try testz.expectEqual(eng.conf_err, null);

    var names: std.ArrayList([]const u8) = .empty;
    defer freeNames(alloc, &names);
    try eng.collectCommandNames(alloc, "", &names);

    try testz.expectEqual(names.items.len, 2);
    try testz.expectTrue(hasName(names.items, "a"));
    try testz.expectTrue(hasName(names.items, "b"));
}

pub fn collectCommandNamesIncludesScriptFilesTest(io: std.Io, alloc: std.mem.Allocator) !void {
    const cfg_dir = try uniqueDir(alloc, "collect");
    defer alloc.free(cfg_dir);
    const lib_dir = try std.fs.path.join(alloc, &.{ cfg_dir, "scripts", "lib" });
    defer alloc.free(lib_dir);
    try std.Io.Dir.cwd().createDirPath(io, lib_dir);
    defer std.Io.Dir.cwd().deleteTree(io, cfg_dir) catch {};

    const scripts_dir = try std.fs.path.join(alloc, &.{ cfg_dir, "scripts" });
    defer alloc.free(scripts_dir);

    inline for (.{
        .{ "greet.lua", "print('hi')\n" },
        .{ "grep-notes.lua", "print('notes')\n" },
        .{ "notes.txt", "not a script\n" },
    }) |entry| {
        const p = try std.fs.path.join(alloc, &.{ scripts_dir, entry[0] });
        defer alloc.free(p);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = p, .data = entry[1] });
    }
    // A lib module: present but never a command.
    const libmod = try std.fs.path.join(alloc, &.{ lib_dir, "helper.lua" });
    defer alloc.free(libmod);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = libmod, .data = "return {}\n" });

    var host = TestHost{ .alloc = alloc };
    defer host.deinit();
    const eng = try script_engine.ScriptEngine.init(alloc, io, host.hooks(), cfg_dir);
    defer eng.deinit();

    var names: std.ArrayList([]const u8) = .empty;
    defer freeNames(alloc, &names);
    try eng.collectCommandNames(alloc, "gr", &names);

    try testz.expectEqual(names.items.len, 2);
    try testz.expectTrue(hasName(names.items, "greet"));
    try testz.expectTrue(hasName(names.items, "grep-notes"));
    try testz.expectTrue(!hasName(names.items, "notes")); // .txt skipped
    try testz.expectTrue(!hasName(names.items, "helper")); // lib/ skipped
}

pub fn collectCommandNamesMergesDefcmdAndFilesTest(io: std.Io, alloc: std.mem.Allocator) !void {
    const cfg_dir = try uniqueDir(alloc, "collectmerge");
    defer alloc.free(cfg_dir);
    const scripts_dir = try std.fs.path.join(alloc, &.{ cfg_dir, "scripts" });
    defer alloc.free(scripts_dir);
    try std.Io.Dir.cwd().createDirPath(io, scripts_dir);
    defer std.Io.Dir.cwd().deleteTree(io, cfg_dir) catch {};

    const filecmd = try std.fs.path.join(alloc, &.{ scripts_dir, "sync.lua" });
    defer alloc.free(filecmd);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = filecmd, .data = "print('sync')\n" });

    var host = TestHost{ .alloc = alloc };
    defer host.deinit();
    const eng = try script_engine.ScriptEngine.init(alloc, io, host.hooks(), cfg_dir);
    defer eng.deinit();

    // `status` from defcmd, `sync` from a file: both come back. `sync`
    // also has a defcmd, so it appears twice -- the caller dedups.
    try eng.runConf("defcmd('status', function() end)\ndefcmd('sync', function() end)");
    try testz.expectEqual(eng.conf_err, null);

    var names: std.ArrayList([]const u8) = .empty;
    defer freeNames(alloc, &names);
    try eng.collectCommandNames(alloc, "s", &names);

    try testz.expectTrue(hasName(names.items, "status"));
    try testz.expectTrue(hasName(names.items, "sync"));
    try testz.expectEqual(names.items.len, 3);
}
