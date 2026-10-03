// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: MPL-2.0

//! The OS window's title follows the program the user is in: "Glyphwire -
//! " plus the title of the context on screen in the focused pane (what a
//! program sets with `set_context_title` -- `zoe ~/code/x.zig`,
//! `gw-shell ~/code`). Just "Glyphwire" when that context has none.
//!
//! Pure apart from the caller's one `setTitle` call: `App.update` hands in
//! the context title each frame and only touches the window when the
//! formatted result changed.

const std = @import("std");
const glyphwire = @import("glyphwire");

pub const app_name = "Glyphwire";
const separator = " - ";

pub const max_len = app_name.len + separator.len + glyphwire.Context.max_title_len;

pub const WindowTitle = struct {
    /// The title last handed to the window, NUL-terminated for SDL.
    buf: [max_len + 1]u8 = undefined,
    len: usize = 0,
    /// False until the first `update`, so the first frame always sets it.
    set: bool = false,

    /// Formats the window title for `context_title` and returns it when it
    /// differs from the last one returned, or null when nothing changed.
    pub fn update(self: *WindowTitle, context_title: []const u8) ?[:0]const u8 {
        var next: [max_len + 1]u8 = undefined;
        const formatted = format(&next, context_title);
        if (self.set and std.mem.eql(u8, formatted, self.buf[0..self.len])) return null;
        @memcpy(self.buf[0..formatted.len], formatted);
        self.buf[formatted.len] = 0;
        self.len = formatted.len;
        self.set = true;
        return self.buf[0..self.len :0];
    }
};

/// `"Glyphwire - <context_title>"`, or `"Glyphwire"` for an empty one,
/// written into `buf` (which must hold `max_len` bytes).
pub fn format(buf: []u8, context_title: []const u8) []const u8 {
    if (context_title.len == 0) return std.fmt.bufPrint(buf, "{s}", .{app_name}) catch app_name;
    return std.fmt.bufPrint(buf, "{s}{s}{s}", .{ app_name, separator, context_title }) catch app_name;
}
