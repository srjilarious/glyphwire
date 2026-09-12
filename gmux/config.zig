//! gmux's optional startup config, `~/.config/glyphwire/gmux.conf` -- a
//! Lua script assigning a global `config` table, same shape `zoe.conf` /
//! `ls.conf` / `shell.conf` use. Deliberately tiny for the first version:
//! the prefix key, the shell to run in a fresh pane, and how much
//! scrollback each pane's ring keeps. With no file present gmux runs on
//! Ctrl-B, `gw-shell`, and 2000 rows.

const std = @import("std");
const ziglua = @import("ziglua");
const glyphwire = @import("glyphwire");

const Lua = ziglua.Lua;

const conf_name = "gmux.conf";

pub const Config = struct {
    arena: std.heap.ArenaAllocator,
    /// The letter after Ctrl that starts a command (`config.prefix_key =
    /// "a"` for screen-style Ctrl-A). Lowercase ASCII letter only for
    /// v1 -- a symbol or a non-Ctrl modifier is a later refinement.
    /// Default `'b'` (tmux).
    prefix_key: u8 = 'b',
    /// `config.shell` overrides the default `gw-shell` for every pane
    /// spawned from here on -- `/bin/bash`, `$SHELL`, whatever a user
    /// wants instead. Any program works -- a pane is a sequestered host,
    /// so a plain `bash` gets a real PTY and a terminal of exactly the
    /// pane's size (see `host/pane_proc.zig`). `gw-shell` is merely the
    /// better default, since a glyphwire-aware program draws on the
    /// pane's own context rather than through VT emulation.
    shell: ?[]const u8 = null,
    /// `config.scrollback_rows` -- the ring every new pane's base context
    /// root layer is created with.
    scrollback_rows: usize = 2000,

    pub fn deinit(self: *Config) void {
        self.arena.deinit();
    }
};

/// Reads `gmux.conf` from glyphwire's config dir and returns the merged
/// config. A missing file / missing config home is the normal case:
/// defaults, no error, nothing logged. Any parse problem is logged and
/// whatever parsed before it is kept.
pub fn load(gpa: std.mem.Allocator, io: std.Io, environ: *const std.process.Environ.Map) Config {
    var arena = std.heap.ArenaAllocator.init(gpa);
    var cfg = Config{ .arena = arena };

    const src = readConf(&arena, io, environ) orelse return cfg;

    const lua = Lua.init(gpa) catch {
        std.log.warn("gmux: could not create Lua interpreter for {s}; using defaults", .{conf_name});
        return cfg;
    };
    defer lua.deinit();
    lua.openLibs();

    lua.doString(src) catch {
        const msg = lua.toString(-1) catch conf_name ++ ": unknown Lua error";
        std.log.warn("gmux: {s}: {s}; using what parsed", .{ conf_name, msg });
        return cfg;
    };

    _ = lua.getGlobal("config") catch return cfg;
    defer lua.pop(1);
    if (lua.typeOf(-1) != .table) {
        if (lua.typeOf(-1) != .nil)
            std.log.warn("gmux: {s} `config` is not a table; using defaults", .{conf_name});
        return cfg;
    }

    cfg.prefix_key = readPrefixKey(lua, cfg.prefix_key);
    cfg.shell = readShell(lua, arena.allocator());
    cfg.scrollback_rows = readScrollbackRows(lua, cfg.scrollback_rows);
    return cfg;
}

/// `config.prefix_key = "a"` -- a single lowercase ASCII letter. Anything
/// else (absent, longer, uppercase, punctuation) leaves the default and
/// warns, since a silently-ignored typo here is otherwise invisible.
fn readPrefixKey(lua: *Lua, current: u8) u8 {
    const t = lua.getField(-1, "prefix_key");
    defer lua.pop(1);
    if (t != .string) return current;
    const s = lua.toString(-1) catch return current;
    if (s.len == 1 and s[0] >= 'a' and s[0] <= 'z') return s[0];
    std.log.warn("gmux: {s} prefix_key must be one lowercase letter; using default", .{conf_name});
    return current;
}

/// `config.shell = "/usr/bin/fish"` -- overrides `$SHELL` for every pane.
fn readShell(lua: *Lua, a: std.mem.Allocator) ?[]const u8 {
    const t = lua.getField(-1, "shell");
    defer lua.pop(1);
    if (t != .string) return null;
    const s = lua.toString(-1) catch return null;
    return a.dupe(u8, s) catch null;
}

/// `config.scrollback_rows = 5000`. A number >= 0 replaces the default;
/// anything else (absent, negative, non-number) leaves it.
fn readScrollbackRows(lua: *Lua, current: usize) usize {
    const t = lua.getField(-1, "scrollback_rows");
    defer lua.pop(1);
    if (t != .number) return current;
    const n = lua.toNumber(-1) catch return current;
    if (n < 0) return current;
    return @intFromFloat(n);
}

fn readConf(arena: *std.heap.ArenaAllocator, io: std.Io, environ: *const std.process.Environ.Map) ?[:0]const u8 {
    const a = arena.allocator();
    const dir = glyphwire.configDirPath(a, environ) catch return null;
    const path = std.fs.path.join(a, &.{ dir, conf_name }) catch return null;
    return std.Io.Dir.cwd().readFileAllocOptions(io, path, a, .limited(256 * 1024), .of(u8), 0) catch |err| {
        if (err != error.FileNotFound)
            std.log.warn("gmux: couldn't read {s} ({t}); using defaults", .{ path, err });
        return null;
    };
}

/// The command to run in a fresh pane: `config.shell`, else `gw-shell`.
/// Deliberately doesn't fall back to `$SHELL`: `gw-shell` in a pane is a
/// strictly better experience than a plain shell under VT emulation, so it
/// is the default a user opts out of explicitly, not something `$SHELL`
/// can silently override.
pub fn shellCommand(cfg: *const Config) []const u8 {
    return cfg.shell orelse "gw-shell";
}
