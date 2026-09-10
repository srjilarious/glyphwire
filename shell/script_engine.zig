//! The one Lua state glyphwire-shell keeps for a whole session.
//!
//! `shell/config.zig` runs `shell.conf` for its declarative `alias` /
//! `prompt` data; this module owns the *persistent* interpreter that runs
//! it, so a `function` the conf defines -- or a file dropped in
//! `~/.config/glyphwire/scripts/` -- stays callable as a builtin for the
//! rest of the session. It is the extension point other language runtimes
//! will hang off later; the Lua surface it exposes is deliberately small.
//!
//! What a script sees:
//!
//!  - `sh.setenv(name, value)` / `sh.unsetenv(name)` -- change this
//!    shell's environment *and* every child it launches afterwards.
//!    `sh.getenv(name)` reads the live view (anything a script set this
//!    session included); `sh.cwd()` and `sh.realpath(path)` are the two
//!    path helpers Lua's stdlib doesn't provide.
//!  - `defcmd(name, fn)` -- register `fn` as a builtin. Stored in a table
//!    kept only in the Lua registry, never as a global, so a builtin
//!    named `string` can't clobber the stdlib (see decisions.md).
//!  - a file `<scripts_dir>/<name>.lua` is also a builtin `name`, looked
//!    up by filename and re-read on every call (so editing it takes
//!    effect immediately). `require` finds shared helpers under
//!    `<scripts_dir>/lib/`.
//!  - `arg` (0 = command name, 1.. = positional) and the same values as
//!    `...`; a numeric return is the exit status.
//!  - `print` and `io.write` go to the grid. `os.exit` is disabled (it
//!    would kill the shell) -- calling it raises a catchable error.
//!
//! Dispatch precedence (see `shell/main.zig`): core builtins > aliases >
//! script builtins > `$PATH`. A runaway script is stopped by Ctrl-C
//! (polled through `HostHooks.poll_interrupt` from an instruction-count
//! hook) or, failing that, a hard wall-clock ceiling.

const std = @import("std");
const ziglua = @import("ziglua");
const Lua = ziglua.Lua;
const config = @import("config.zig");

const script_ext = ".lua";

/// Instructions between interrupt-hook checks. Small enough that a tight
/// `while true do end` is caught well under a second, large enough that
/// the check is noise on a normal script.
const hook_instruction_count: i32 = 100_000;

/// Hard ceiling on one builtin's wall-clock run time, in milliseconds. A
/// script still executing bytecode past this is force-aborted with a
/// (catchable) Lua error, so the shell always gets its prompt back.
/// Ctrl-C is the graceful stop; this is the backstop when no key is
/// coming.
const hook_deadline_ms: i64 = 30_000;

/// The services a running script needs from the shell. All of these are
/// implemented in `shell/main.zig` against the live `Prompt`; the engine
/// only ever reaches them through this struct.
pub const HostHooks = struct {
    ctx: *anyopaque,
    /// Set a variable for this shell and every child spawned afterwards.
    setenv: *const fn (ctx: *anyopaque, name: []const u8, value: []const u8) void,
    /// Remove a variable from this shell and future children.
    unsetenv: *const fn (ctx: *anyopaque, name: []const u8) void,
    /// The shell's live value for `name` (script-set values included).
    /// The returned slice only has to stay valid until the next env
    /// mutation -- callers copy it into Lua immediately.
    getenv: *const fn (ctx: *anyopaque, name: []const u8) ?[]const u8,
    /// Absolute working directory into `buf`; null on failure.
    cwd: *const fn (ctx: *anyopaque, buf: []u8) ?[]const u8,
    /// Canonical absolute form of `path` into `buf` (libc `realpath`);
    /// null if it doesn't resolve on disk. `buf` must be PATH_MAX.
    realpath: *const fn (ctx: *anyopaque, path: [:0]const u8, buf: []u8) ?[]const u8,
    /// Write script output onto the grid.
    write: *const fn (ctx: *anyopaque, bytes: []const u8) void,
    /// True once the user has pressed Ctrl-C since the builtin started --
    /// polled from the interrupt hook while a script runs.
    poll_interrupt: *const fn (ctx: *anyopaque) bool,
};

/// Set while any call into the persistent state is in flight, so the
/// C-ABI Lua callbacks (`sh.*`, `defcmd`, the interrupt hook) can reach
/// the engine. The shell is single-threaded and has exactly one engine,
/// so a module-level pointer is enough -- same pattern as
/// `config.g_active` and pixzig's `sequencer.SeqScriptingContext`.
var g_engine: ?*ScriptEngine = null;

pub const ScriptEngine = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    lua: *Lua,
    hooks: HostHooks,
    /// `<config_dir>/scripts`, owned. Empty when the shell has no config
    /// directory: then only `defcmd` builtins exist, no file lookup.
    scripts_dir: []const u8,
    /// Registry key for the `name -> function` table `defcmd` fills.
    cmds_ref: i32,
    /// `alias` / `prompt` declarations from the last `runConf`. Owned for
    /// the session; `shell/main.zig` reads it live on every prompt draw.
    cfg: config.ShellConfig,
    /// Owned diagnostic from the last `runConf` (a `shell.conf` syntax or
    /// runtime error), or null. The caller shows it once.
    conf_err: ?[]const u8 = null,

    /// Interrupt-hook state for the builtin currently running. Only one
    /// runs at a time -- dispatch is synchronous.
    call_started: ?std.Io.Clock.Timestamp = null,
    interrupted: bool = false,

    /// Builds the persistent state: opens the stdlib, installs the config
    /// bindings and the script surface (`sh`, `defcmd`, grid-routed
    /// `print`/`io.write`, disabled `os.exit`), and points `require` at
    /// `<config_dir>/scripts/lib/`. Heap-allocated so the module-level
    /// `g_engine` and the `hooks` closures have a stable address.
    pub fn init(
        alloc: std.mem.Allocator,
        io: std.Io,
        hooks: HostHooks,
        config_dir: ?[]const u8,
    ) !*ScriptEngine {
        const self = try alloc.create(ScriptEngine);
        errdefer alloc.destroy(self);

        const lua = try Lua.init(alloc);
        errdefer lua.deinit();
        lua.openLibs();

        self.* = .{
            .alloc = alloc,
            .io = io,
            .lua = lua,
            .hooks = hooks,
            .scripts_dir = "",
            .cmds_ref = 0,
            .cfg = .{ .alloc = alloc, .prompt_arena = std.heap.ArenaAllocator.init(alloc) },
        };
        errdefer self.cfg.deinit();

        if (config_dir) |dir| {
            self.scripts_dir = try std.fs.path.join(alloc, &.{ dir, "scripts" });
            setupPackagePath(lua, self.scripts_dir);
        }

        // The command registry: an anonymous table reachable only through
        // the Lua registry, so nothing a script does to `_G` can shadow
        // or leak it.
        lua.newTable();
        self.cmds_ref = try lua.ref(ziglua.registry_index);

        config.installBindings(lua);

        installShTable(lua);
        lua.pushFunction(ziglua.wrap(luaDefcmd));
        lua.setGlobal("defcmd");

        lua.pushFunction(ziglua.wrap(luaPrint));
        lua.setGlobal("print");
        overrideTableFn(lua, "os", "exit", ziglua.wrap(luaBlockedExit));
        overrideTableFn(lua, "io", "write", ziglua.wrap(luaIoWrite));

        g_engine = self;
        return self;
    }

    pub fn deinit(self: *ScriptEngine) void {
        if (g_engine == self) g_engine = null;
        self.lua.deinit(); // frees the registry table with everything else
        self.cfg.deinit();
        if (self.conf_err) |e| self.alloc.free(e);
        if (self.scripts_dir.len > 0) self.alloc.free(self.scripts_dir);
        self.alloc.destroy(self);
    }

    /// Runs `shell.conf` in the persistent state. `alias` / `prompt`
    /// calls land in `self.cfg`; any `function` it defines and any
    /// `defcmd` it calls stay live as builtins. A syntax or runtime error
    /// is captured in `self.conf_err` (whatever ran before the failing
    /// line still took effect), never returned -- only an allocation
    /// failure is.
    pub fn runConf(self: *ScriptEngine, source: [:0]const u8) std.mem.Allocator.Error!void {
        if (self.conf_err) |e| {
            self.alloc.free(e);
            self.conf_err = null;
        }

        const prev = config.beginCollecting(&self.cfg);
        defer config.endCollecting(prev);

        self.lua.doString(source) catch {
            const msg = self.lua.toString(-1) catch "shell.conf: unknown Lua error";
            self.conf_err = try self.alloc.dupe(u8, msg);
        };
        self.lua.setTop(0);
    }

    /// Whether `name` names a script builtin -- a `defcmd` registration
    /// or a readable `<scripts_dir>/<name>.lua`. Cheap: an in-memory
    /// table lookup, then at most one `access()` before dispatch falls
    /// through to `$PATH`. A name with a path separator is never a
    /// builtin.
    pub fn hasCommand(self: *ScriptEngine, name: []const u8) bool {
        if (!validName(name)) return false;

        const lua = self.lua;
        const base = lua.getTop();
        defer lua.setTop(base);

        var name_buf: [160]u8 = undefined;
        const name_z = toZ(&name_buf, name) orelse return false;

        _ = lua.rawGetIndex(ziglua.registry_index, self.cmds_ref);
        if (lua.getField(-1, name_z) == .function) return true;

        if (self.scripts_dir.len == 0) return false;
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const full = std.fmt.bufPrint(&path_buf, "{s}/{s}{s}", .{ self.scripts_dir, name, script_ext }) catch return false;
        std.Io.Dir.cwd().access(self.io, full, .{}) catch return false;
        return true;
    }

    /// Runs the builtin `name` with `args`, returning its exit status
    /// (a numeric Lua return, clamped to 0..255; 0 otherwise). A Lua
    /// error is written to the grid as `name: message` and reported as
    /// status 1; the shell itself is never taken down. `hasCommand` is
    /// assumed to have said yes.
    pub fn runCommand(self: *ScriptEngine, name: []const u8, args: []const []const u8) u8 {
        const lua = self.lua;
        const base = lua.getTop();
        defer lua.setTop(base);

        // `arg` global: [0] = command name, [1..] = positional. Cleared
        // again on the way out so it can't leak into the next builtin.
        lua.newTable();
        _ = lua.pushString(name);
        lua.rawSetIndex(-2, 0);
        for (args, 0..) |a, i| {
            _ = lua.pushString(a);
            lua.rawSetIndex(-2, @intCast(i + 1));
        }
        lua.setGlobal("arg");
        defer {
            lua.pushNil();
            lua.setGlobal("arg");
        }

        if (!self.pushCallable(name)) return 127;

        // The same values as `...`, so `function(a, b)` and `local a =
        // ...` work alongside `arg`.
        for (args) |a| _ = lua.pushString(a);

        self.call_started = std.Io.Clock.Timestamp.now(self.io, .awake);
        self.interrupted = false;
        lua.setHook(ziglua.wrap(interruptHook), .{ .count = true }, hook_instruction_count);
        defer lua.setHook(ziglua.wrap(interruptHook), .{}, 0);

        lua.protectedCall(.{ .args = @intCast(args.len), .results = 1 }) catch {
            self.writeErr(name, lua.toStringEx(-1));
            return 1;
        };

        if (lua.isNumber(-1)) {
            const n = lua.toNumber(-1) catch 0;
            return std.math.lossyCast(u8, @max(0, n));
        }
        return 0;
    }

    /// Pushes the function to run for `name`: a `defcmd` registration if
    /// there is one, otherwise the freshly compiled chunk of
    /// `<scripts_dir>/<name>.lua`. Returns false (nothing pushed, an
    /// error already written) when neither resolves.
    fn pushCallable(self: *ScriptEngine, name: []const u8) bool {
        const lua = self.lua;

        var name_buf: [160]u8 = undefined;
        const name_z = toZ(&name_buf, name) orelse return false;

        _ = lua.rawGetIndex(ziglua.registry_index, self.cmds_ref);
        if (lua.getField(-1, name_z) == .function) {
            lua.replace(-2); // drop the registry table, keep the function
            return true;
        }
        lua.pop(2); // the non-function field, then the registry table

        if (self.scripts_dir.len == 0) return false;

        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const full = std.fmt.bufPrintZ(&path_buf, "{s}/{s}{s}", .{ self.scripts_dir, name, script_ext }) catch return false;

        const src = std.Io.Dir.cwd().readFileAllocOptions(
            self.io,
            full,
            self.alloc,
            .limited(1 << 20),
            .of(u8),
            0,
        ) catch {
            self.writeErr(name, "could not read script");
            return false;
        };
        defer self.alloc.free(src);

        lua.loadString(src) catch {
            self.writeErr(name, lua.toStringEx(-1));
            lua.pop(1);
            return false;
        };
        return true; // the compiled chunk is on top
    }

    fn writeErr(self: *ScriptEngine, name: []const u8, msg: []const u8) void {
        var buf: [640]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "{s}: {s}\n", .{ name, msg }) catch "script error\n";
        self.hooks.write(self.hooks.ctx, line);
    }
};

// ─── name vetting / small helpers ─────────────────────────────────────

fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > 128) return false;
    if (std.mem.indexOfAny(u8, name, "/\\") != null) return false;
    if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return false;
    return true;
}

/// Copies `s` into `buf` with a trailing NUL and returns it as a
/// sentinel slice, or null if it doesn't fit.
fn toZ(buf: []u8, s: []const u8) ?[:0]const u8 {
    if (s.len >= buf.len) return null;
    @memcpy(buf[0..s.len], s);
    buf[s.len] = 0;
    return buf[0..s.len :0];
}

// ─── Lua state setup ─────────────────────────────────────────────────

/// Prepends `<scripts_dir>/lib/?.lua` (and `/?/init.lua`) to
/// `package.path` so a script can `require` shared helpers. A best-effort
/// step: on any hiccup the stock path is left as-is.
fn setupPackagePath(lua: *Lua, scripts_dir: []const u8) void {
    _ = lua.getGlobal("package") catch return;
    if (lua.isNil(-1)) {
        lua.pop(1);
        return;
    }
    _ = lua.getField(-1, "path");
    const old = lua.toString(-1) catch "";

    var buf: [std.fs.max_path_bytes * 2 + 64]u8 = undefined;
    const combined = std.fmt.bufPrintZ(&buf, "{s}/lib/?.lua;{s}/lib/?/init.lua;{s}", .{
        scripts_dir, scripts_dir, old,
    }) catch {
        lua.pop(2);
        return;
    };
    lua.pop(1); // the old path string

    _ = lua.pushStringZ(combined);
    lua.setField(-2, "path");
    lua.pop(1); // the package table
}

fn installShTable(lua: *Lua) void {
    lua.newTable();
    lua.pushFunction(ziglua.wrap(shSetenv));
    lua.setField(-2, "setenv");
    lua.pushFunction(ziglua.wrap(shUnsetenv));
    lua.setField(-2, "unsetenv");
    lua.pushFunction(ziglua.wrap(shGetenv));
    lua.setField(-2, "getenv");
    lua.pushFunction(ziglua.wrap(shCwd));
    lua.setField(-2, "cwd");
    lua.pushFunction(ziglua.wrap(shRealpath));
    lua.setField(-2, "realpath");
    lua.setGlobal("sh");
}

/// Replaces `table.field` with `f`, if `table` exists. Used to disable
/// `os.exit` and re-point `io.write` at the grid.
fn overrideTableFn(lua: *Lua, table: [:0]const u8, field: [:0]const u8, f: ziglua.CFn) void {
    _ = lua.getGlobal(table) catch return;
    if (lua.isNil(-1)) {
        lua.pop(1);
        return;
    }
    lua.pushFunction(f);
    lua.setField(-2, field);
    lua.pop(1);
}

// ─── C-ABI Lua callbacks ─────────────────────────────────────────────

fn shSetenv(lua: *Lua) i32 {
    const e = g_engine orelse return 0;
    const name = lua.checkString(1);
    const value = lua.checkString(2);
    if (name.len == 0 or std.mem.indexOfAny(u8, name, "=\x00") != null)
        lua.raiseErrorStr("sh.setenv: invalid variable name", .{});
    if (std.mem.indexOfScalar(u8, value, 0) != null)
        lua.raiseErrorStr("sh.setenv: value must not contain a NUL byte", .{});
    e.hooks.setenv(e.hooks.ctx, name, value);
    return 0;
}

fn shUnsetenv(lua: *Lua) i32 {
    const e = g_engine orelse return 0;
    const name = lua.checkString(1);
    if (!envNameOk(name)) return 0;
    e.hooks.unsetenv(e.hooks.ctx, name);
    return 0;
}

fn shGetenv(lua: *Lua) i32 {
    const e = g_engine orelse return 0;
    const name = lua.checkString(1);
    if (envNameOk(name)) {
        if (e.hooks.getenv(e.hooks.ctx, name)) |v| {
            _ = lua.pushString(v);
            return 1;
        }
    }
    lua.pushNil();
    return 1;
}

/// A name safe to hand `std.process.Environ.Map` (it asserts these):
/// non-empty, no NUL.
fn envNameOk(name: []const u8) bool {
    return name.len > 0 and std.mem.indexOfScalar(u8, name, 0) == null;
}

fn shCwd(lua: *Lua) i32 {
    const e = g_engine orelse return 0;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    if (e.hooks.cwd(e.hooks.ctx, &buf)) |p| {
        _ = lua.pushString(p);
    } else {
        lua.pushNil();
    }
    return 1;
}

fn shRealpath(lua: *Lua) i32 {
    const e = g_engine orelse return 0;
    const path = lua.checkString(1); // already NUL-terminated
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    if (e.hooks.realpath(e.hooks.ctx, path, &buf)) |p| {
        _ = lua.pushString(p);
    } else {
        lua.pushNil();
    }
    return 1;
}

fn luaDefcmd(lua: *Lua) i32 {
    const e = g_engine orelse return 0;
    const name = lua.checkString(1);
    lua.checkType(2, .function);
    if (!validName(name) or std.mem.indexOfAny(u8, name, " \t") != null)
        lua.raiseErrorStr("defcmd: invalid command name", .{});

    _ = lua.rawGetIndex(ziglua.registry_index, e.cmds_ref);
    lua.pushValue(2);
    lua.setField(-2, name);
    lua.pop(1);
    return 0;
}

fn luaPrint(lua: *Lua) i32 {
    const e = g_engine orelse return 0;
    const n = lua.getTop();
    var i: i32 = 1;
    while (i <= n) : (i += 1) {
        if (i > 1) e.hooks.write(e.hooks.ctx, "\t");
        e.hooks.write(e.hooks.ctx, lua.toStringEx(i));
        lua.pop(1); // luaL_tolstring pushed a copy
    }
    e.hooks.write(e.hooks.ctx, "\n");
    return 0;
}

fn luaIoWrite(lua: *Lua) i32 {
    const e = g_engine orelse return 0;
    const n = lua.getTop();
    var i: i32 = 1;
    while (i <= n) : (i += 1) {
        e.hooks.write(e.hooks.ctx, lua.toStringEx(i));
        lua.pop(1);
    }
    return 0;
}

fn luaBlockedExit(lua: *Lua) i32 {
    lua.raiseErrorStr("os.exit() is disabled inside glyphwire-shell scripts", .{});
    return 0;
}

/// Instruction-count hook: aborts the running builtin on Ctrl-C or once
/// it blows past the wall-clock ceiling. `raiseErrorStr` longjmps to the
/// `protectedCall` in `runCommand`, exactly how Lua's own CLI handles
/// SIGINT.
fn interruptHook(lua: *Lua, event: ziglua.Event, info: *ziglua.DebugInfo) void {
    _ = event;
    _ = info;
    const e = g_engine orelse return;

    if (e.interrupted or e.hooks.poll_interrupt(e.hooks.ctx)) {
        e.interrupted = true;
        lua.raiseErrorStr("interrupted", .{});
    }
    if (e.call_started) |started| {
        if (started.untilNow(e.io).raw.toMilliseconds() > hook_deadline_ms)
            lua.raiseErrorStr("script exceeded its 30s time limit", .{});
    }
}
