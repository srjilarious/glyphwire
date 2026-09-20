// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: GPL-3.0-or-later

//! `gw-shell --embed`: the prompt running as a panel inside another
//! client's context, rather than owning a context of its own.
//!
//! The host client (salacommander's Ctrl+` popup) creates the context
//! and a layer inside it, spawns the shell with
//!
//!     gw-shell --embed <context>,<layer>[,<control-fd>]
//!
//! and the shell `attach_context`es onto it and draws everything on that
//! layer (`Prompt.layer`, and the `draw*` helpers around it). Nothing
//! about the prompt changes: same line editor, same pty loop, same
//! scrollback -- the layer is created with its own `scrollback_rows`, so
//! even Ctrl+Up browsing works inside the panel.
//!
//! **Both programs see every keystroke.** Input is delivered per context
//! and there is one context here, so the host and the shell each receive
//! the whole stream and each decides whether it's theirs. That decision
//! is the host's to make, and it says so over the control pipe: `focus`
//! when it has handed the keyboard to the panel, `blur` when it has
//! taken it back. The shell ignores input while blurred; the host
//! ignores everything but its own toggle key while the panel has focus.
//!
//! **The control pipe** is the read end of a pipe the host created
//! non-blocking and left open across the spawn -- the same trick the
//! shell's own `$GLYPHWIRE_RESULT_FD` plays on its children, in the
//! other direction. The shell drains it between keystrokes
//! (`Control.drain`, from the prompt's idle pass, so a directive lands
//! within one idle tick) and treats end-of-file as "the host is gone".
//! One directive per line:
//!
//!     cd <path>   change the panel's directory -- what makes the popup
//!                 follow the file pane. Applied before the next prompt
//!                 is drawn, so it never disturbs a half-typed line the
//!                 way typing `cd` into the panel would.
//!     focus       keystrokes are the shell's
//!     blur        keystrokes are the host's
//!     size        the layer was resized; re-read it
//!     quit        leave, as if `exit` had been typed
//!
//! Unknown directives are ignored rather than fatal: the host and the
//! shell are separately installed programs and a newer host talking to an
//! older shell should degrade, not die.

const std = @import("std");
const glyphwire = @import("glyphwire");

/// What `--embed` was given.
pub const Options = struct {
    context: glyphwire.ContextHandle,
    layer: glyphwire.LayerHandle,
    /// The inherited read end of the host's control pipe. Null when the
    /// host wants no say after spawn.
    control_fd: ?i32 = null,
};

pub const ParseError = error{Malformed};

/// Parses `--embed`'s value: `<context>,<layer>` and an optional
/// `,<control-fd>`, all decimal, as the host printed them.
pub fn parseOptions(value: []const u8) ParseError!Options {
    var it = std.mem.splitScalar(u8, value, ',');
    const ctx_text = it.next() orelse return error.Malformed;
    const layer_text = it.next() orelse return error.Malformed;
    const context = std.fmt.parseInt(u64, std.mem.trim(u8, ctx_text, " "), 10) catch return error.Malformed;
    const layer = std.fmt.parseInt(u64, std.mem.trim(u8, layer_text, " "), 10) catch return error.Malformed;
    const fd_text = std.mem.trim(u8, it.next() orelse "", " ");
    const control_fd: ?i32 = if (fd_text.len == 0)
        null
    else
        std.fmt.parseInt(i32, fd_text, 10) catch return error.Malformed;
    if (it.next() != null) return error.Malformed;
    return .{
        .context = @intCast(context),
        .layer = @intCast(layer),
        .control_fd = control_fd,
    };
}

/// One line of the control pipe.
pub const Directive = union(enum) {
    /// The panel's new directory. Borrowed from the buffer the line was
    /// read into, so it's used (or copied) before the next drain.
    cd: []const u8,
    focus,
    blur,
    /// The layer's size changed; re-read it rather than trust the last
    /// `resize`, which reports the *context*.
    size,
    quit,
};

/// Parses one line. Null for a blank line or a directive this build
/// doesn't know -- see the module comment on why that isn't an error.
pub fn parseDirective(line: []const u8) ?Directive {
    const t = std.mem.trim(u8, line, " \t\r");
    if (t.len == 0) return null;
    if (std.mem.eql(u8, t, "focus")) return .focus;
    if (std.mem.eql(u8, t, "blur")) return .blur;
    if (std.mem.eql(u8, t, "size")) return .size;
    if (std.mem.eql(u8, t, "quit")) return .quit;
    if (std.mem.startsWith(u8, t, "cd ")) {
        const path = std.mem.trim(u8, t[3..], " \t");
        if (path.len == 0) return null;
        return .{ .cd = path };
    }
    return null;
}

const c = struct {
    extern "c" fn read(fd: i32, buf: [*]u8, n: usize) isize;
    extern "c" fn close(fd: i32) i32;
};

/// The read end of the host's control pipe, drained a line at a time.
/// The fd is non-blocking (the host made it so with `pipe2`), which is
/// what lets the prompt loop check it between keystrokes rather than
/// wait on a pipe that may stay quiet for minutes.
pub const Control = struct {
    fd: i32,
    alloc: std.mem.Allocator,
    /// Partial line left from the last read -- a directive can straddle
    /// two reads.
    buf: std.ArrayList(u8) = .empty,
    /// Set once the write end is closed: the host has exited, and an
    /// embedded shell with no host has nothing left to draw on.
    host_gone: bool = false,

    pub fn init(alloc: std.mem.Allocator, fd: i32) Control {
        return .{ .fd = fd, .alloc = alloc };
    }

    pub fn deinit(self: *Control) void {
        self.buf.deinit(self.alloc);
        _ = c.close(self.fd);
    }

    /// Reads whatever is waiting and calls `apply` for each complete
    /// line. Never blocks: a negative read is "nothing right now"
    /// (`EAGAIN` on an empty non-blocking pipe, and any other error is no
    /// more actionable here), while a zero-length read is end of file --
    /// every writer closed, so the host is gone.
    pub fn drain(self: *Control, ctx: anytype, apply: *const fn (@TypeOf(ctx), Directive) void) !void {
        var chunk: [1024]u8 = undefined;
        while (true) {
            const n = c.read(self.fd, &chunk, chunk.len);
            if (n < 0) return;
            if (n == 0) {
                self.host_gone = true;
                return;
            }
            const got: usize = @intCast(n);
            try self.buf.appendSlice(self.alloc, chunk[0..got]);
            while (std.mem.indexOfScalar(u8, self.buf.items, '\n')) |nl| {
                if (parseDirective(self.buf.items[0..nl])) |d| apply(ctx, d);
                // The directive borrows the buffer, so it's consumed
                // before the tail shifts down over it.
                const rest = self.buf.items.len - (nl + 1);
                std.mem.copyForwards(u8, self.buf.items[0..rest], self.buf.items[nl + 1 ..]);
                self.buf.shrinkRetainingCapacity(rest);
            }
            if (got < chunk.len) return;
        }
    }
};
