// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: MPL-2.0

//! Ctrl+` -- a `gw-shell` running across the bottom of a client's own
//! context, in a layer that client created for it. salacommander and zoe
//! both host one.
//!
//! The shell is a glyphwire client, not a terminal program, so this is
//! not a pty being mirrored into a panel: the shell attaches to *this*
//! context (`attach_context`) and draws its prompt straight onto the
//! layer handle it is given (`gw-shell --embed <context>,<layer>,<fd>`,
//! and `shell/embed.zig` for the whole contract). Everything the panel
//! costs on this side is the layer, a pipe, and a child process.
//!
//! **Who has the keyboard.** Input is delivered per context and there is
//! one context, so both programs see every keystroke and the host
//! decides: while the panel is open it consumes nothing but Ctrl+`, and
//! the shell is told `focus` / `blur` over the control pipe. The pipe is
//! also how the panel follows the host's directory -- a `cd` line
//! whenever it changes, applied by the shell before its next prompt
//! rather than typed into whatever is on its line.
//!
//! **Who has the caret.** The shell takes the host caret when it is
//! focused (`set_caret_layer`, `set_caret_visible`, and the default
//! `set_caret_shape`), but it does not give it back on `blur`: the host
//! is the one taking the keyboard back, so it puts the caret where it
//! wants it (`close` hides it; an editor then re-sends its own). Both
//! sides doing it raced.
//!
//! **Its height is the user's.** The layer's top edge is a host
//! `resize_edge`: dragging it comes back as a `layer_resize` event, which
//! the host program hands to `handleLayerResize`. The height asked for
//! sticks for the rest of the run -- across Ctrl+` and window resizes,
//! clamped to whatever window it is laid out in -- but isn't saved:
//! the next run opens at the default share again.
//!
//! **Closing keeps the shell.** Ctrl+` hides the layer and blurs it; the
//! shell keeps running with its history, its environment and whatever it
//! was in the middle of. Only the host exiting ends it, and it ends
//! by itself: the control pipe's write end closes, the shell reads EOF
//! and leaves.

const std = @import("std");
const glyphwire = @import("glyphwire");

const c = struct {
    extern "c" fn pipe2(fds: *[2]i32, flags: i32) i32;
    extern "c" fn close(fd: i32) i32;
    extern "c" fn write(fd: i32, buf: [*]const u8, n: usize) isize;
    extern "c" fn waitpid(pid: i32, status: ?*i32, options: i32) i32;
};

/// `WNOHANG`: ask whether the shell has exited without waiting for it to.
const wnohang: i32 = 1;

/// `O_NONBLOCK` on Linux. The read end is what matters -- the shell
/// polls it between keystrokes and must never block on it -- and `pipe2`
/// sets the flag on both ends, which is fine for directives this small.
const o_nonblock: i32 = 0o4000;

/// How much of the window the panel takes when it opens, and the bounds
/// on that: enough rows to read a command's output, never so many that
/// the file panes stop being usable.
const share_num = 1;
const share_den = 3;
const min_rows = 6;
const max_rows = 24;
/// The least a drag may shrink the panel to: a prompt and a line of
/// output.
const min_dragged_rows = 2;

/// Rows left below the panel: salacommander's function-key bar and zoe's
/// statusline (the mode word lives there), which stay readable
/// with the shell up -- Ctrl+` is not a mode you should have to remember
/// your way out of.
const bar_rows = 1;

/// Rows of history the panel's layer keeps, so Ctrl+Up in the shell has
/// something to browse.
pub const scrollback_rows = 2000;

/// The window the panel is laid out against, in cells.
pub const WinSize = struct { cols: usize, rows: usize };

pub const Panel = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    client: *glyphwire.Client,
    /// The panel's layer. Created with the rest of the UI's layers and
    /// kept hidden until the panel is first opened -- a layer costs
    /// nothing while it's invisible, and creating it up front keeps the
    /// compositing order fixed.
    layer: glyphwire.LayerHandle,
    context: glyphwire.ContextHandle,

    /// The running shell, once Ctrl+` has started one.
    child: ?std.process.Child = null,
    /// Write end of the control pipe. Closed when the panel is torn down,
    /// which is what tells the shell to leave.
    control_fd: ?i32 = null,
    /// Whether the panel is on screen (and has the keyboard).
    visible: bool = false,
    /// The directory last sent, so following the panes doesn't re-send
    /// the same `cd` on every cursor move. Owned.
    sent_cwd: ?[]u8 = null,
    /// The height the user dragged the panel to, if they have; `place`
    /// uses it instead of the default share. Kept as asked, not as
    /// clamped, so shrinking the window and growing it back returns the
    /// panel to the height the user picked.
    wanted_rows: ?usize = null,

    pub fn init(
        alloc: std.mem.Allocator,
        io: std.Io,
        client: *glyphwire.Client,
        context: glyphwire.ContextHandle,
        layer: glyphwire.LayerHandle,
    ) Panel {
        return .{ .alloc = alloc, .io = io, .client = client, .context = context, .layer = layer };
    }

    /// Ends the shell: closing the control pipe is the signal, and the
    /// child is reaped rather than left behind.
    pub fn deinit(self: *Panel) void {
        if (self.control_fd) |fd| {
            _ = c.write(fd, "quit\n", 5);
            _ = c.close(fd);
            self.control_fd = null;
        }
        // Reaped if it's already gone, but never waited *for*: a shell
        // with a `sleep 60` in the foreground would hold the file manager
        // open until it finished. Its control pipe is closed, so it ends
        // on its own; an unreaped child of a process that is itself
        // exiting is init's problem, not a leak.
        if (self.child) |ch| {
            if (ch.id) |pid| _ = c.waitpid(pid, null, wnohang);
            self.child = null;
        }
        if (self.sent_cwd) |p| self.alloc.free(p);
        self.sent_cwd = null;
    }

    pub fn isOpen(self: *const Panel) bool {
        return self.visible;
    }

    /// Whether the shell has exited since the last check -- `exit` typed
    /// into the panel, or a crash. True once, when it's noticed: the
    /// panel closes, its layer is wiped, and the next Ctrl+` starts a
    /// fresh shell. Reaped here so nothing is left as a zombie.
    pub fn reapIfExited(self: *Panel) bool {
        const ch = self.child orelse return false;
        const pid = ch.id orelse return false;
        if (c.waitpid(pid, null, wnohang) != pid) return false;

        self.child = null;
        if (self.control_fd) |fd| {
            _ = c.close(fd);
            self.control_fd = null;
        }
        if (self.sent_cwd) |p| self.alloc.free(p);
        self.sent_cwd = null;
        self.visible = false;
        self.client.clearOn(self.layer, 0, 0, null, null) catch {};
        self.client.setLayerVisible(self.layer, false) catch {};
        self.client.setCaretVisible(false) catch {};
        self.client.setCaretLayer(null) catch {};
        return true;
    }

    /// Rows the panel occupies in a window `win_rows` tall. Always
    /// leaves the key bar and a couple of rows of file pane above it.
    pub fn rowsFor(win_rows: usize) usize {
        const share = win_rows * share_num / share_den;
        const room = @max(@min(max_rows, win_rows -| (bar_rows + 2)), 1);
        return @min(@max(share, min_rows), room);
    }

    /// `rowsFor`, or the height the user dragged the panel to. A dragged
    /// height isn't held to the default's `min_rows`/`max_rows` -- the
    /// user chose it -- only to the room the window has: the key bar and
    /// a couple of rows above the panel stay, so the edge can always be
    /// grabbed again from the content side.
    pub fn rowsForWanted(win_rows: usize, wanted: ?usize) usize {
        const w = wanted orelse return rowsFor(win_rows);
        const room = @max(win_rows -| (bar_rows + 2), 1);
        return std.math.clamp(w, @min(min_dragged_rows, room), room);
    }

    /// A `layer_resize` from the host: the user dragged the panel's top
    /// edge. Returns false for anyone else's layer, so the caller can
    /// pass every one through here.
    pub fn handleLayerResize(self: *Panel, ev: glyphwire.LayerResizeEvent, win: WinSize) bool {
        if (ev.context != self.context or ev.layer != self.layer) return false;
        self.wanted_rows = ev.rows;
        if (self.visible) self.place(win) catch {};
        return true;
    }

    /// Opens the panel, starting the shell the first time. `cwd` is the
    /// directory it should be in.
    pub fn open(self: *Panel, cwd: []const u8, win: WinSize) !void {
        if (self.child == null) try self.start(cwd, win);
        try self.place(win);
        try self.client.setLayerVisible(self.layer, true);
        self.visible = true;
        self.send("focus");
        self.setCwd(cwd);
    }

    /// Hides the panel and gives the keyboard back. The shell stays
    /// running behind it.
    pub fn close(self: *Panel) void {
        if (!self.visible) return;
        self.visible = false;
        self.send("blur");
        self.client.setLayerVisible(self.layer, false) catch {};
        // The panel had pointed the host's caret at its own layer.
        self.client.setCaretVisible(false) catch {};
        self.client.setCaretLayer(null) catch {};
    }

    /// Puts the layer across the bottom of a `win`-sized window and tells
    /// the shell to re-read its size. A no-op before the shell exists.
    pub fn place(self: *Panel, win: WinSize) !void {
        const rows = rowsForWanted(win.rows, self.wanted_rows);
        try self.client.setLayerSize(self.layer, win.cols, rows);
        // Above the key bar, not over it.
        try self.client.setLayerCellPosition(self.layer, win.rows -| (rows + bar_rows), 0);
        if (self.child != null) self.send("size");
    }

    /// Follows the file pane: the shell changes directory before its next
    /// prompt. Cheap to call on every navigation -- an unchanged path
    /// sends nothing.
    pub fn setCwd(self: *Panel, cwd: []const u8) void {
        if (self.child == null) return;
        if (self.sent_cwd) |prev| {
            if (std.mem.eql(u8, prev, cwd)) return;
        }
        const copy = self.alloc.dupe(u8, cwd) catch return;
        if (self.sent_cwd) |prev| self.alloc.free(prev);
        self.sent_cwd = copy;

        var buf: [std.Io.Dir.max_path_bytes + 8]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "cd {s}\n", .{cwd}) catch return;
        self.writeLine(line);
    }

    fn send(self: *Panel, directive: []const u8) void {
        var buf: [32]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "{s}\n", .{directive}) catch return;
        self.writeLine(line);
    }

    /// Best-effort: a full pipe or a shell that already died is not worth
    /// tearing the file manager down over.
    fn writeLine(self: *Panel, line: []const u8) void {
        const fd = self.control_fd orelse return;
        _ = c.write(fd, line.ptr, line.len);
    }

    /// Starts `gw-shell --embed`, with the read end of a fresh control
    /// pipe inherited. No `O_CLOEXEC` on either end, the same reason the
    /// shell's own result pipe leaves it off: the read end has to survive
    /// the exec into the child.
    fn start(self: *Panel, cwd: []const u8, win: WinSize) !void {
        try self.place(win);
        try self.client.setLayerVisible(self.layer, false);
        try self.client.setLayerResizeEdge(self.layer, .top);

        var fds: [2]i32 = undefined;
        if (c.pipe2(&fds, o_nonblock) != 0) return error.PipeFailed;
        errdefer {
            _ = c.close(fds[0]);
            _ = c.close(fds[1]);
        }

        var arg_buf: [96]u8 = undefined;
        const embed_arg = try std.fmt.bufPrint(&arg_buf, "{d},{d},{d}", .{ self.context, self.layer, fds[0] });

        const child = std.process.spawn(self.io, .{
            .argv = &.{ "gw-shell", "--embed", embed_arg },
            .cwd = .{ .path = cwd },
            // The panel's output goes on the wire, not down a pipe; what
            // the shell itself logs would land on the screen underneath
            // us, so it goes nowhere.
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
            // A group of its own: the shell that started this program
            // SIGINTs our whole group on Ctrl+C, and the panel's shell is
            // not ours to have killed that way (see `applib.interrupt`).
            .pgid = 0,
        }) catch |err| {
            return err;
        };
        // Ours is the write end; the child owns its copy of the read end.
        _ = c.close(fds[0]);
        self.control_fd = fds[1];
        self.child = child;
        // A freshly started shell is in `cwd` already; record it so the
        // first navigation doesn't send a redundant `cd`.
        self.sent_cwd = self.alloc.dupe(u8, cwd) catch null;
    }
};
