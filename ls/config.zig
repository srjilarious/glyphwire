// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: GPL-3.0-or-later

//! Loads glyphwire-ls's startup config, `~/.config/glyphwire/ls.conf.lua`, a
//! Lua script that assigns a global `config` table -- the same shape
//! `host.conf.lua` uses. Running it yields an `LsConfig`. Split into the
//! `ls_support` module so
//! `tests/ls_tests.zig` can exercise the parse without a running client.
//!
//! Right now `ls.conf.lua` only carries the on-screen icon sizes; colour
//! overrides are expected to land here later as a nested `colors = { ... }`
//! table, which is why it's a Lua script and not a flat key=value file.

const std = @import("std");
const luaconf = @import("luaconf");
const Lua = luaconf.Lua;

const conf: luaconf.Conf = .{ .prog = "glyphwire-ls", .name = "ls.conf.lua" };

/// Rendered-icon height, in pixels, `glyphwire-ls` targets in each layout.
/// `.natural` scaling is aspect-preserving and shrink-only, so these are
/// upper bounds: a source icon smaller than the value renders at its own
/// size. Clamped to `icon_px_min..icon_px_max` on load.
pub const LsConfig = struct {
    /// `-L` grid bands and `-l -L` table rows. 32 keeps every icon the
    /// size of a folder/file bucket icon even when the source art is
    /// larger (the 48px `dev/*` logos); raise it for chunkier icons.
    large_icon_px: u32 = 32,
    /// The default grid and `-l` (non-`-L`) table rows.
    small_icon_px: u32 = 16,
};

/// Sane bounds for the icon-size keys -- below `min` an icon is a few
/// unreadable pixels, above `max` one entry's band would swallow the
/// window. A value outside the range is clamped (with a warning), not
/// rejected.
pub const icon_px_min: u32 = 8;
pub const icon_px_max: u32 = 128;
const icon_px: luaconf.Range(u32) = .{ .min = icon_px_min, .max = icon_px_max };

/// Outcome of `load`: the parsed config plus, on a Lua load/run failure,
/// an owned diagnostic string. `config` holds the defaults in that case.
pub const LoadResult = struct {
    config: LsConfig = .{},
    err: ?[]const u8 = null,

    pub fn deinit(self: *LoadResult, alloc: std.mem.Allocator) void {
        if (self.err) |e| alloc.free(e);
    }
};

/// Parses `source` (the contents of `ls.conf.lua`, null-terminated) and
/// returns the resulting `LsConfig`. Unknown keys are ignored; a key of
/// the wrong type, or one outside `icon_px_min..icon_px_max`, keeps /
/// clamps to a valid value and is noted on stderr. Only a genuine Lua-init
/// failure or a syntax/runtime error populates `LoadResult.err`.
pub fn load(alloc: std.mem.Allocator, source: [:0]const u8) LoadResult {
    var result: LoadResult = .{};
    result.err = conf.run(alloc, source, &result.config, apply);
    return result;
}

fn apply(cfg: *LsConfig, lua: *Lua) void {
    if (conf.uint(lua, u32, "large_icon_px", icon_px)) |v| cfg.large_icon_px = v;
    if (conf.uint(lua, u32, "small_icon_px", icon_px)) |v| cfg.small_icon_px = v;
}

/// `load`, but reading the file from `config_dir`. A missing file is the
/// normal case: all defaults, no error, nothing logged. Returns the
/// `LsConfig` directly -- any parse diagnostic is logged here rather than
/// handed back, since `glyphwire-ls` has nowhere useful to surface it.
pub fn loadFromDir(
    alloc: std.mem.Allocator,
    io: std.Io,
    config_dir: []const u8,
) LsConfig {
    const src = conf.readIn(alloc, io, config_dir) catch return .{};
    defer alloc.free(src);
    var result = load(alloc, src);
    defer result.deinit(alloc);
    if (result.err) |e| conf.logRunError(e);
    return result.config;
}
