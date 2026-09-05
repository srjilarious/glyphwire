//! Loads glyphwire-shell's startup config, `~/.config/glyphwire/shell.conf`,
//! which is a Lua script. Running it produces a `ShellConfig` -- the Lua
//! bindings (right now just `alias(name, value)`) append into that struct
//! rather than touching the live prompt, so `shell/main.zig` can apply the
//! parsed result in one place and the parsing itself is unit-testable
//! without a running shell. Mirrors how pixzig parses a Lua config into a
//! Zig structure; new bindings add a field here and a collector in `load`.

const std = @import("std");
const ziglua = @import("ziglua");
const Lua = ziglua.Lua;

/// One `alias(name, value)` call collected from a shell.conf run. Both
/// fields are owned by the enclosing `ShellConfig`.
pub const AliasDef = struct {
    name: []const u8,
    value: []const u8,
};

/// The prompt templating a `prompt{ ... }` call declared. `left`/`right`
/// are the main templates (see `shell/prompt_template.zig` for the token
/// syntax); `exit`/`dur` are the sub-templates `{exit}` / `{dur}` expand
/// to. A `null` field was never set (across every `prompt` call) and the
/// prompt keeps its built-in default for that piece. Every non-null string
/// is owned by the enclosing `ShellConfig`.
pub const PromptConfig = struct {
    left: ?[]const u8 = null,
    right: ?[]const u8 = null,
    exit: ?[]const u8 = null,
    dur: ?[]const u8 = null,
    /// Minimum last-command run time, in milliseconds, before `{dur}`
    /// renders anything. `null` -> the prompt's default (2000).
    dur_min_ms: ?u64 = null,
};

/// Everything one shell.conf run declared, parsed into Zig data. Owns its
/// contents; call `deinit` once the caller has copied what it needs.
pub const ShellConfig = struct {
    alloc: std.mem.Allocator,
    /// `alias` bindings, in the order the conf declared them -- a later
    /// duplicate name is kept as its own entry, so whoever applies these
    /// (see `Prompt`) gets last-write-wins for free.
    aliases: std.ArrayList(AliasDef) = .empty,
    /// Prompt templating from `prompt{ ... }` calls. Multiple calls merge
    /// key by key, last write winning per key.
    prompt: PromptConfig = .{},

    pub fn deinit(self: *ShellConfig) void {
        for (self.aliases.items) |a| {
            self.alloc.free(a.name);
            self.alloc.free(a.value);
        }
        self.aliases.deinit(self.alloc);
        if (self.prompt.left) |s| self.alloc.free(s);
        if (self.prompt.right) |s| self.alloc.free(s);
        if (self.prompt.exit) |s| self.alloc.free(s);
        if (self.prompt.dur) |s| self.alloc.free(s);
    }
};

/// Outcome of `load`: the parsed config plus, on a Lua load/run failure,
/// an owned diagnostic string. `config` still holds whatever the conf
/// managed to declare before the error (Lua stops at the failing line),
/// so the caller can apply the partial result and surface `err`.
pub const LoadResult = struct {
    config: ShellConfig,
    err: ?[]const u8 = null,

    pub fn deinit(self: *LoadResult) void {
        if (self.err) |e| self.config.alloc.free(e);
        self.config.deinit();
    }
};

/// The config currently being populated, reachable from the C-ABI Lua
/// callbacks. Set only for the duration of a `load` call -- the shell
/// runs its startup config once, single-threaded, so a module-level
/// pointer is enough (same pattern as pixzig's
/// `sequencer.SeqScriptingContext`).
var g_active: ?*ShellConfig = null;

/// Runs `source` (the contents of shell.conf, null-terminated) as Lua
/// with glyphwire's config bindings installed, collecting what it
/// declares. The standard Lua libraries are opened, so a conf can use
/// `string`/`table`/loops/conditionals to build its alias list. Only a
/// genuine allocation failure is returned as an error; a Lua syntax or
/// runtime error lands in `LoadResult.err` with a partial config.
pub fn load(alloc: std.mem.Allocator, source: [:0]const u8) error{OutOfMemory}!LoadResult {
    var cfg: ShellConfig = .{ .alloc = alloc };
    errdefer cfg.deinit();

    const lua = Lua.init(alloc) catch {
        return .{ .config = cfg, .err = try alloc.dupe(u8, "shell.conf: could not create Lua interpreter") };
    };
    defer lua.deinit();
    lua.openLibs();

    lua.pushFunction(ziglua.wrap(luaAlias));
    lua.setGlobal("alias");

    lua.pushFunction(ziglua.wrap(luaPrompt));
    lua.setGlobal("prompt");

    const prev = g_active;
    g_active = &cfg;
    defer g_active = prev;

    lua.doString(source) catch {
        const msg = lua.toString(-1) catch "shell.conf: unknown Lua error";
        return .{ .config = cfg, .err = try alloc.dupe(u8, msg) };
    };

    return .{ .config = cfg };
}

/// `alias(name, value)` -- both arguments must be strings (a non-string
/// raises a Lua error, reported through `LoadResult.err`). Appends the
/// binding to the active `ShellConfig`.
fn luaAlias(lua: *Lua) !i32 {
    const cfg = g_active orelse return 0;
    const name = lua.checkString(1);
    const value = lua.checkString(2);

    const name_owned = try cfg.alloc.dupe(u8, name);
    errdefer cfg.alloc.free(name_owned);
    const value_owned = try cfg.alloc.dupe(u8, value);
    errdefer cfg.alloc.free(value_owned);

    try cfg.aliases.append(cfg.alloc, .{ .name = name_owned, .value = value_owned });
    return 0;
}

/// `prompt{ left = ..., right = ..., exit = ..., dur = ..., dur_min_ms = N }`
/// -- one table argument, every key optional. String keys must be strings
/// (a number coerces, like `alias`; other types raise). `dur_min_ms` must
/// be a non-negative number. Multiple `prompt` calls merge: a key set
/// again replaces (and frees) the earlier value, an omitted key is left
/// as whatever a prior call set.
fn luaPrompt(lua: *Lua) !i32 {
    const cfg = g_active orelse return 0;
    lua.checkType(1, .table);

    try promptStrField(lua, cfg, &cfg.prompt.left, "left");
    try promptStrField(lua, cfg, &cfg.prompt.right, "right");
    try promptStrField(lua, cfg, &cfg.prompt.exit, "exit");
    try promptStrField(lua, cfg, &cfg.prompt.dur, "dur");

    _ = lua.getField(1, "dur_min_ms");
    defer lua.pop(1);
    if (!lua.isNoneOrNil(-1)) {
        const n = lua.checkNumber(-1);
        if (n < 0) lua.raiseErrorStr("prompt: dur_min_ms must be >= 0", .{});
        cfg.prompt.dur_min_ms = @as(u64, @intFromFloat(n));
    }
    return 0;
}

/// Reads one string key off the table at stack index 1 into `slot`,
/// replacing (and freeing) any value a previous `prompt` call left there.
/// A missing/nil key leaves `slot` untouched.
fn promptStrField(lua: *Lua, cfg: *ShellConfig, slot: *?[]const u8, key: [:0]const u8) !void {
    _ = lua.getField(1, key);
    defer lua.pop(1);
    if (lua.isNoneOrNil(-1)) return;

    const s = lua.checkString(-1); // raises on a non-string/non-number
    const owned = try cfg.alloc.dupe(u8, s);
    if (slot.*) |old| cfg.alloc.free(old);
    slot.* = owned;
}
