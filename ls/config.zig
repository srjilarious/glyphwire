//! Loads glyphwire-ls's startup config, `~/.config/glyphwire/ls.conf`, a
//! Lua script that assigns a global `config` table -- the same shape
//! `host.conf` uses. Running it yields an `LsConfig`. Split into the
//! `ls_support` module (like `ls/icons.zig` / `ls/format.zig`) so
//! `tests/ls_tests.zig` can exercise the parse without a running client.
//!
//! Right now `ls.conf` only carries the on-screen icon sizes; colour
//! overrides are expected to land here later as a nested `colors = { ... }`
//! table, which is why it's a Lua script and not a flat key=value file.

const std = @import("std");
const ziglua = @import("ziglua");
const Lua = ziglua.Lua;

const conf_name = "ls.conf";

/// Rendered-icon height, in pixels, `glyphwire-ls` targets in each layout.
/// `.natural` scaling is aspect-preserving and shrink-only, so these are
/// upper bounds: a source icon smaller than the value renders at its own
/// size. Clamped to `icon_px_min..icon_px_max` on load.
pub const LsConfig = struct {
    /// `-L` grid bands and `-l -L` table rows. 48 matches the bundled
    /// art's own size (the Oxygen / Papirus / Material file-type themes,
    /// the Devicon language logos, and the distro logos are all 48x48), so
    /// every icon renders crisp and the same size; lower it for a denser
    /// listing.
    large_icon_px: u32 = 48,
    /// The default grid and `-l` (non-`-L`) table rows.
    small_icon_px: u32 = 16,
};

/// Sane bounds for the icon-size keys -- below `min` an icon is a few
/// unreadable pixels, above `max` one entry's band would swallow the
/// window. A value outside the range is clamped (with a warning), not
/// rejected.
pub const icon_px_min: u32 = 8;
pub const icon_px_max: u32 = 128;

/// Outcome of `load`: the parsed config plus, on a Lua load/run failure,
/// an owned diagnostic string. `config` still holds whatever ran before
/// the error (Lua stops at the failing line), so a caller can use the
/// partial result and surface `err`.
pub const LoadResult = struct {
    config: LsConfig = .{},
    err: ?[]const u8 = null,

    pub fn deinit(self: *LoadResult, alloc: std.mem.Allocator) void {
        if (self.err) |e| alloc.free(e);
    }
};

/// Parses `source` (the contents of `ls.conf`, null-terminated) and
/// returns the resulting `LsConfig`. Unknown keys are ignored; a key of
/// the wrong type, or one outside `icon_px_min..icon_px_max`, keeps /
/// clamps to a valid value and is noted on stderr. Only a genuine Lua-init
/// failure or a syntax/runtime error populates `LoadResult.err`; the
/// config is still usable in that case (defaults, plus any keys set before
/// the failing line).
pub fn load(alloc: std.mem.Allocator, source: [:0]const u8) LoadResult {
    var result: LoadResult = .{};

    const lua = Lua.init(alloc) catch {
        result.err = alloc.dupe(u8, conf_name ++ ": could not create Lua interpreter") catch null;
        return result;
    };
    defer lua.deinit();
    lua.openLibs();

    lua.doString(source) catch {
        const msg = lua.toString(-1) catch conf_name ++ ": unknown Lua error";
        result.err = alloc.dupe(u8, msg) catch null;
        return result;
    };

    _ = lua.getGlobal("config") catch return result;
    defer lua.pop(1);
    if (!lua.isTable(-1)) {
        if (!lua.isNil(-1))
            std.log.warn("glyphwire-ls: {s} `config` is not a table; using defaults", .{conf_name});
        return result;
    }

    if (uintField(lua, "large_icon_px")) |v| result.config.large_icon_px = clampPx("large_icon_px", v);
    if (uintField(lua, "small_icon_px")) |v| result.config.small_icon_px = clampPx("small_icon_px", v);

    return result;
}

/// `load`, but reading the file from glyphwire's config directory
/// (`glyphwire.configDirPath`). A missing file / missing config home is
/// the normal case: all defaults, no error, nothing logged. Returns the
/// `LsConfig` directly -- any parse diagnostic is logged here rather than
/// handed back, since `glyphwire-ls` has nowhere useful to surface it.
pub fn loadFromDir(
    alloc: std.mem.Allocator,
    io: std.Io,
    config_dir: []const u8,
) LsConfig {
    const path = std.fs.path.join(alloc, &.{ config_dir, conf_name }) catch return .{};
    defer alloc.free(path);

    const src = std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(64 * 1024)) catch |err| {
        if (err != error.FileNotFound)
            std.log.warn("glyphwire-ls: couldn't read {s} ({t}); using defaults", .{ path, err });
        return .{};
    };
    defer alloc.free(src);
    const src_z = alloc.dupeZ(u8, src) catch return .{};
    defer alloc.free(src_z);

    var result = load(alloc, src_z);
    defer result.deinit(alloc);
    if (result.err) |e|
        std.log.warn("glyphwire-ls: {s}: {s}; using what parsed", .{ conf_name, e });
    return result.config;
}

/// Reads `config.<key>` as a non-negative whole number. Absent, non-number,
/// negative, or non-integral -> null (caller keeps the default). Assumes
/// the `config` table is on top of the stack.
fn uintField(lua: *Lua, key: [:0]const u8) ?u32 {
    _ = lua.getField(-1, key);
    defer lua.pop(1);
    if (!lua.isNumber(-1)) {
        if (!lua.isNil(-1))
            std.log.warn("glyphwire-ls: {s} `{s}` is not a number; ignored", .{ conf_name, key });
        return null;
    }
    const n = lua.toNumber(-1) catch return null;
    if (n < 0 or n != @floor(n) or n > @as(f64, std.math.maxInt(u32))) {
        std.log.warn("glyphwire-ls: {s} `{s}` = {d} is not a valid size; ignored", .{ conf_name, key, n });
        return null;
    }
    return @intFromFloat(n);
}

fn clampPx(key: []const u8, v: u32) u32 {
    const c = std.math.clamp(v, icon_px_min, icon_px_max);
    if (c != v)
        std.log.warn("glyphwire-ls: {s} `{s}` {d} out of range {d}..{d}; clamped to {d}", .{ conf_name, key, v, icon_px_min, icon_px_max, c });
    return c;
}
