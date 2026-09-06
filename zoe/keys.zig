//! A vim-notation key script: `"ihello<esc>3jdd"` fed to an `Editor` as
//! the same two streams glyphwire would deliver.
//!
//! This exists so the editor can be driven without a window. It is what
//! `tests/zoe_tests.zig` writes its cases in and what `zoe --keys` runs,
//! which means the tests exercise the real `feedText`/`feedKey` split
//! rather than reaching past it into the edit functions.
//!
//! Everything outside `<...>` is committed text; a `<name>` is a named
//! key. `<lt>` is a literal `<`, matching vim's own escape for it. An
//! unrecognized `<name>` is passed to `feedKey` verbatim, so a key
//! glyphwire grows later needs no change here.

const std = @import("std");
const editor = @import("editor.zig");

const Editor = editor.Editor;
const Outcome = editor.Outcome;

/// Runs `script` against `ed`. Stops at the first command that produces
/// an `Outcome` other than `.none` and returns it -- a script containing
/// `:q<cr>` ends there, the way the real input loop would.
pub fn feed(ed: *Editor, script: []const u8) !Outcome {
    var i: usize = 0;
    while (i < script.len) {
        if (script[i] == '<') {
            if (std.mem.indexOfScalarPos(u8, script, i, '>')) |close| {
                const name = script[i + 1 .. close];
                i = close + 1;
                // `<lt>` and `<space>` stand for characters, so they go
                // down the text path; everything else is a named key.
                if (literalFor(name)) |literal| {
                    switch (try ed.feedText(literal)) {
                        .none => {},
                        else => |o| return o,
                    }
                } else {
                    switch (try ed.feedKey(keyName(name), .{})) {
                        .none => {},
                        else => |o| return o,
                    }
                }
                continue;
            }
            // An unclosed `<` is just text.
        }

        // Take the whole run up to the next `<` as one committed-text
        // chunk, which is how a real keystroke burst or a paste arrives.
        const end = std.mem.indexOfScalarPos(u8, script, i + 1, '<') orelse script.len;
        switch (try ed.feedText(script[i..end])) {
            .none => {},
            else => |o| return o,
        }
        i = end;
    }
    return .none;
}

fn literalFor(name: []const u8) ?[]const u8 {
    if (std.ascii.eqlIgnoreCase(name, "lt")) return "<";
    if (std.ascii.eqlIgnoreCase(name, "space")) return " ";
    return null;
}

/// vim's short names mapped onto glyphwire's key names, which come from
/// the engine backend's SDL3 keycode enum (`@tagName`) and so are the
/// protocol -- see decisions.md's Input model. An unlisted name passes
/// through, which is how `<f1>` or `<page_up>` work with no entry here.
fn keyName(name: []const u8) []const u8 {
    const aliases = [_]struct { short: []const u8, full: []const u8 }{
        .{ .short = "esc", .full = "escape" },
        .{ .short = "cr", .full = "enter" },
        .{ .short = "nl", .full = "enter" },
        .{ .short = "bs", .full = "backspace" },
        .{ .short = "del", .full = "delete" },
    };
    for (aliases) |a| {
        if (std.ascii.eqlIgnoreCase(name, a.short)) return a.full;
    }
    return name;
}
