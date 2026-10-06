// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: GPL-3.0-or-later

//! gmux's optional startup config, `~/.config/glyphwire/gmux.conf.lua` -- a
//! Lua script assigning a global `config` table, same shape `zoe.conf.lua` /
//! `ls.conf.lua` / `shell.conf.lua` use. Deliberately tiny: the prefix
//! key, the shell to run in a fresh pane, how much scrollback each pane's
//! ring keeps, and `keys` to rebind the commands after the prefix (see
//! `actions.zig`). With no file present gmux runs on Ctrl-B, `gw-shell`,
//! 2000 rows and the default commands.

const std = @import("std");
const luaconf = @import("luaconf");
const actions = @import("actions.zig");

const Lua = luaconf.Lua;

const conf: luaconf.Conf = .{ .prog = "gmux", .name = "gmux.conf.lua" };

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
    /// `config.keys`: prefix commands rebound by name (`actions.zig`),
    /// validated, in the arena.
    keys: []const actions.Override = &.{},

    pub fn deinit(self: *Config) void {
        self.arena.deinit();
    }
};

/// Reads `gmux.conf.lua` from glyphwire's config dir and returns the merged
/// config. A missing file / missing config home is the normal case:
/// defaults, no error, nothing logged. Any parse problem is logged and
/// the defaults stand.
pub fn load(gpa: std.mem.Allocator, io: std.Io, environ: *const std.process.Environ.Map) Config {
    // Allocate through `cfg.arena`, never through a separate local: an
    // `ArenaAllocator` holds its block list by value, so allocating via one
    // copy and calling `deinit` on another frees nothing.
    var cfg = Config{ .arena = std.heap.ArenaAllocator.init(gpa) };
    const src = conf.read(cfg.arena.allocator(), io, environ) orelse return cfg;
    conf.runLogged(gpa, src, &cfg, apply);
    return cfg;
}

fn apply(cfg: *Config, lua: *Lua) void {
    cfg.prefix_key = readPrefixKey(lua, cfg.prefix_key);
    if (conf.string(lua, "shell")) |s| cfg.shell = cfg.arena.allocator().dupe(u8, s) catch null;
    if (conf.uint(lua, usize, "scrollback_rows", .{})) |v| cfg.scrollback_rows = v;
    cfg.keys = conf.keys(lua, cfg.arena.allocator(), actions.Action);
}

/// `config.prefix_key = "a"` -- a single lowercase ASCII letter. Anything
/// else (longer, uppercase, punctuation) leaves the default and warns,
/// since a silently-ignored typo here is otherwise invisible.
fn readPrefixKey(lua: *Lua, current: u8) u8 {
    const s = conf.string(lua, "prefix_key") orelse return current;
    if (s.len == 1 and s[0] >= 'a' and s[0] <= 'z') return s[0];
    conf.warn("prefix_key must be one lowercase letter; using default", .{});
    return current;
}

/// The command to run in a fresh pane: `config.shell`, else `gw-shell`.
/// Deliberately doesn't fall back to `$SHELL`: `gw-shell` in a pane is a
/// strictly better experience than a plain shell under VT emulation, so it
/// is the default a user opts out of explicitly, not something `$SHELL`
/// can silently override.
pub fn shellCommand(cfg: *const Config) []const u8 {
    return cfg.shell orelse "gw-shell";
}
