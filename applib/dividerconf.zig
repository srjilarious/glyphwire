// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: MPL-2.0

//! Reading `config.divider_style` and `config.divider_chars` out of a
//! program's own Lua config (`zoe.conf.lua`, `salacommander.conf.lua`):
//! how glyphwire-host should draw the bands of that program's split tree.
//! Absent, the program sends nothing and inherits the host's
//! `pane_divider_style` / `pane_divider_chars`.
//!
//!   divider_style = "heavy"                  -- single, heavy, double, block
//!   divider_chars = { v = "┃", h = "━" }     -- any subset of the glyphs
//!
//! The keys mirror `host.conf.lua`'s, without the `pane_` prefix. Either
//! may be given alone: `divider_chars` with no `divider_style` lays its
//! glyphs over whatever the host draws. Bad names and glyphs are logged
//! and skipped, never fatal.
//!
//! Its own build module, like `themeconf`, because it needs `ziglua`.

const std = @import("std");
const ziglua = @import("ziglua");
const glyphwire = @import("glyphwire");

const divider_style = glyphwire.divider_style;
const Lua = ziglua.Lua;

/// Reads `divider_style` / `divider_chars` from the `config` table on top
/// of `lua`'s stack. Leaves the stack as it found it. `source` names the
/// file in log lines.
pub fn read(lua: *Lua, source: []const u8) divider_style.Override {
    var out: divider_style.Override = .{};

    if (lua.getField(-1, "divider_style") == .string) {
        const name = lua.toString(-1) catch "";
        if (std.meta.stringToEnum(divider_style.Preset, name)) |p| {
            out.preset = p;
        } else {
            std.log.warn("{s}: divider_style \"{s}\" unknown (single, heavy, double, block); keeping the host's", .{ source, name });
        }
    } else if (!lua.isNil(-1)) {
        std.log.warn("{s}: divider_style is not a string; ignored", .{source});
    }
    lua.pop(1);

    if (lua.getField(-1, "divider_chars") == .table) {
        inline for (@typeInfo(divider_style.Override.Chars).@"struct".field_names) |name| {
            if (lua.getField(-1, name) == .string) {
                const text = lua.toString(-1) catch "";
                if (divider_style.Glyph.init(text)) |g| {
                    @field(out.chars, name) = g;
                } else {
                    std.log.warn("{s}: divider_chars." ++ name ++ " \"{s}\" isn't one cell wide; ignored", .{ source, text });
                }
            }
            lua.pop(1);
        }
    } else if (!lua.isNil(-1)) {
        std.log.warn("{s}: divider_chars is not a table; ignored", .{source});
    }
    lua.pop(1);

    return out;
}

/// `read` over a config given as Lua source -- for tests, which have no
/// file. A source that fails to run, or has no `config` table, inherits.
pub fn fromSource(gpa: std.mem.Allocator, src: [:0]const u8, source: []const u8) divider_style.Override {
    const lua = Lua.init(gpa) catch return .{};
    defer lua.deinit();
    lua.openLibs();
    lua.doString(src) catch |err| {
        std.log.warn("{s}: {t}; divider settings ignored", .{ source, err });
        return .{};
    };
    _ = lua.getGlobal("config") catch return .{};
    defer lua.pop(1);
    if (lua.typeOf(-1) != .table) return .{};
    return read(lua, source);
}
