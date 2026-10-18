// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: MPL-2.0

//! Ctrl+` -- a `gw-shell` running in a panel over a client's own
//! context, in a layer that client created for it. salacommander and zoe
//! both host one.
//!
//! **Where it sits.** Docked along one edge of the window (`bottom`,
//! the default, or `top`, `left`, `right`), floating over the panes
//! rather than squeezing them, or `float`ing in the middle: a framed box
//! `float_percent` of the window each way, centred, on the theme's
//! `panel` nine-patch and a dialog shadow. `setPosition` moves it live.
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
//! decides: while the panel has focus it consumes nothing but Ctrl+`, and
//! the shell is told `focus` / `blur` over the control pipe. Open and
//! focused are separate: a host may `blur` the panel and take the
//! keyboard back while leaving it on screen (zoe does, on a click outside
//! it -- `contains` is the hit test), and `focus` it again. The pipe is
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
//! **Its size is the user's.** A docked panel's inner edge (the top of
//! a bottom panel, the right of a left one) is a host `resize_edge`:
//! dragging it comes back as a `layer_resize` event, which the host
//! program hands to `handleLayerResize`. The height (top/bottom) or
//! width (left/right) asked for sticks for the rest of the run -- across
//! Ctrl+`, window resizes and moves between the two edges of the same
//! axis, clamped to whatever window it is laid out in -- but isn't saved:
//! the next run opens at the default share again. A floating panel has
//! no edge to drag; its size is the configured percentage.
//!
//! **Closing keeps the shell.** Ctrl+` hides the layer and blurs it; the
//! shell keeps running with its history, its environment and whatever it
//! was in the middle of. Only the host exiting ends it, and it ends
//! by itself: the control pipe's write end closes, the shell reads EOF
//! and leaves.

const std = @import("std");
const glyphwire = @import("glyphwire");

const Color = glyphwire.Color;

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

/// The same for a panel docked to a side, across: enough of the window
/// for a prompt and a useful line, never so much that the panes beside
/// it go.
const side_share_num = 2;
const side_share_den = 5;
const min_cols = 30;
const max_cols = 120;
/// Columns left beside a side panel, so the edge can always be grabbed
/// back from the content side.
const side_keep_cols = 10;
const min_dragged_cols = 10;

/// What a floating panel takes of the window, each way, when the caller
/// doesn't say, and the range a configured value is held to.
pub const default_float_percent: u8 = 80;
pub const min_float_percent: u8 = 10;
pub const max_float_percent: u8 = 100;

/// Where the panel sits. See the module doc.
pub const Position = enum {
    bottom,
    top,
    left,
    right,
    float,

    /// The edge the host lets the user drag: the one facing the panes.
    pub fn resizeEdge(self: Position) glyphwire.ResizeEdge {
        return switch (self) {
            .bottom => .top,
            .top => .bottom,
            .left => .right,
            .right => .left,
            .float => .none,
        };
    }
};

/// A block of cells, in the coordinates of the context the panel is in.
pub const Rect = struct {
    row: usize = 0,
    col: usize = 0,
    cols: usize = 0,
    rows: usize = 0,

    pub fn contains(self: Rect, cell: glyphwire.CellPos) bool {
        return cell.row >= self.row and cell.row < self.row + self.rows and
            cell.col >= self.col and cell.col < self.col + self.cols;
    }
};

/// Where `layoutFor` puts the panel: the shell layer's rect, and for a
/// floating panel the frame one cell bigger all round.
pub const Layout = struct {
    content: Rect,
    frame: ?Rect = null,
};

/// The panel's rect in a `win`-sized window, for `position`, with the
/// size the user dragged it to if they have. Pure, for the tests.
///
/// Docked panels stay off the bottom `bar_rows` (the key bar or
/// statusline); a top or side panel starts at the window's top row. A
/// floating one is centred in the same area with room kept for its frame.
pub fn layoutFor(
    win: WinSize,
    position: Position,
    float_percent: u8,
    wanted_rows: ?usize,
    wanted_cols: ?usize,
) Layout {
    const area_rows = @max(win.rows -| bar_rows, 1);
    switch (position) {
        .bottom, .top => {
            const rows = Panel.rowsForWanted(win.rows, wanted_rows);
            const row = if (position == .top) 0 else win.rows -| (rows + bar_rows);
            return .{ .content = .{ .row = row, .col = 0, .cols = win.cols, .rows = rows } };
        },
        .left, .right => {
            const cols = Panel.colsForWanted(win.cols, wanted_cols);
            const col = if (position == .left) 0 else win.cols -| cols;
            return .{ .content = .{ .row = 0, .col = col, .cols = cols, .rows = area_rows } };
        },
        .float => {
            const pct: usize = std.math.clamp(float_percent, min_float_percent, max_float_percent);
            // The frame's border takes a cell each side, inside the area.
            const cols = std.math.clamp(win.cols * pct / 100, 1, @max(win.cols -| 2, 1));
            const rows = std.math.clamp(area_rows * pct / 100, 1, @max(area_rows -| 2, 1));
            const col = (win.cols -| cols) / 2;
            const row = (area_rows -| rows) / 2;
            return .{
                .content = .{ .row = row, .col = col, .cols = cols, .rows = rows },
                .frame = .{ .row = row -| 1, .col = col -| 1, .cols = cols + 2, .rows = rows + 2 },
            };
        },
    }
}

/// The panel's two layers. Made together by `createLayers` so they stack
/// frame-under-shell wherever the caller creates them.
pub const Layers = struct {
    /// The floating panel's nine-patch frame and shadow; hidden while
    /// the panel is docked.
    frame: glyphwire.LayerHandle,
    /// What the shell draws on.
    shell: glyphwire.LayerHandle,
};

/// Creates the panel's layers, hidden. Call it where the panel should
/// stack: layers composite in creation order. The shell layer carries
/// `scrollback_rows` of history; how it looks (background, scrollbars,
/// mouse selection) is the caller's to set.
pub fn createLayers(client: *glyphwire.Client, cols: usize) !Layers {
    const frame = try client.createLayer(cols, 3, 0);
    try client.setLayerVisible(frame, false);
    const shell = try client.createLayer(cols, 1, scrollback_rows);
    try client.setLayerVisible(shell, false);
    return .{ .frame = frame, .shell = shell };
}

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
    /// The floating panel's frame, under `layer`. See `Layers`.
    frame_layer: glyphwire.LayerHandle,
    /// The frame's nine-patch, once `setFrameStyle` has made one. Null
    /// before that and when the host has no such style; a floating panel
    /// then gets a flat one-cell border in the shell's own colour.
    frame_patch: ?glyphwire.NinePatchHandle = null,
    context: glyphwire.ContextHandle,

    /// Where the panel sits, and how much of the window it takes when
    /// floating. See `setPosition`.
    position: Position = .bottom,
    float_percent: u8 = default_float_percent,

    /// The running shell, once Ctrl+` has started one.
    child: ?std.process.Child = null,
    /// The environment the shell starts with, when the host program has
    /// something to add to its own (zoe's `ZOE_SOCK`). Null inherits this
    /// process's. Borrowed.
    environ_map: ?*const std.process.Environ.Map = null,
    /// Write end of the control pipe. Closed when the panel is torn down,
    /// which is what tells the shell to leave.
    control_fd: ?i32 = null,
    /// Whether the panel is on screen.
    visible: bool = false,
    /// Whether it has the keyboard. Only ever true while `visible`;
    /// `open` sets it, `blur` and `close` clear it.
    focused: bool = false,
    /// Where `place` last put the panel, frame included, for `contains`.
    bounds: Rect = .{},
    /// The edge last sent as the layer's `resize_edge`, so `place`
    /// re-sends it only when the position changes.
    sent_edge: ?glyphwire.ResizeEdge = null,
    /// The directory last sent, so following the panes doesn't re-send
    /// the same `cd` on every cursor move. Owned.
    sent_cwd: ?[]u8 = null,
    /// The height the user dragged a top or bottom panel to, if they
    /// have; `place` uses it instead of the default share. Kept as asked,
    /// not as clamped, so shrinking the window and growing it back
    /// returns the panel to the height the user picked.
    wanted_rows: ?usize = null,
    /// The same for a left or right panel's width.
    wanted_cols: ?usize = null,

    /// Touches no client: `setFrameStyle` makes the frame's nine-patch.
    pub fn init(
        alloc: std.mem.Allocator,
        io: std.Io,
        client: *glyphwire.Client,
        context: glyphwire.ContextHandle,
        layers: Layers,
    ) Panel {
        return .{
            .alloc = alloc,
            .io = io,
            .client = client,
            .context = context,
            .layer = layers.shell,
            .frame_layer = layers.frame,
        };
    }

    /// (Re)makes the floating frame's nine-patch from the theme's panel
    /// style -- once after `init`, and again on a theme change. Destroyed
    /// and re-created rather than updated, the same as the finder popup:
    /// an unknown style is only reported to a request, and the frame
    /// then falls back to flat.
    pub fn setFrameStyle(self: *Panel, style: []const u8) void {
        if (self.frame_patch) |p| self.client.destroyNinePatch(self.frame_layer, p) catch {};
        self.frame_patch = self.client.createNinePatch(self.frame_layer, 0, 0, 3, 3, style) catch |err| blk: {
            std.log.warn("shell panel: no '{s}' nine-patch ({t}); drawing its frame flat", .{ style, err });
            break :blk null;
        };
        const has_patch = self.frame_patch != null;
        self.client.setLayerShadow(self.frame_layer, if (has_patch) glyphwire.Shadow.dialog else null) catch {};
        self.client.setLayerBackground(self.frame_layer, if (has_patch) null else Color.role(.shell_bg)) catch {};
        if (self.visible and self.position == .float) {
            // The new patch is made at a placeholder size.
            self.placeFrame(self.bounds) catch {};
        }
    }

    /// Moves the panel (`:shell left` and friends, or the config). An open
    /// panel is re-placed at once; a closed one opens there next time.
    /// `float_percent` is held to `min_float_percent`..`max_float_percent`.
    pub fn setPosition(self: *Panel, position: Position, float_percent: u8, win: WinSize) void {
        self.position = position;
        self.float_percent = std.math.clamp(float_percent, min_float_percent, max_float_percent);
        if (self.visible) self.place(win) catch {};
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

    pub fn isFocused(self: *const Panel) bool {
        return self.focused;
    }

    /// Whether `cell` is on the open panel, a floating panel's frame
    /// included: a click on the border is a click on the panel.
    pub fn contains(self: *const Panel, cell: glyphwire.CellPos) bool {
        return self.visible and self.bounds.contains(cell);
    }

    /// Gives the keyboard (and the caret, which the shell takes itself)
    /// back to the open panel.
    pub fn focus(self: *Panel) void {
        if (!self.visible or self.focused) return;
        self.focused = true;
        self.send("focus");
    }

    /// Takes the keyboard back but leaves the panel on screen, its output
    /// still live. The caret is the host's again, the same as on `close`.
    pub fn blur(self: *Panel) void {
        if (!self.focused) return;
        self.focused = false;
        self.send("blur");
        self.client.setCaretVisible(false) catch {};
        self.client.setCaretLayer(null) catch {};
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
        self.focused = false;
        self.client.clearOn(self.layer, 0, 0, null, null) catch {};
        self.client.setLayerVisible(self.layer, false) catch {};
        self.client.setLayerVisible(self.frame_layer, false) catch {};
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

    /// Columns a left or right panel takes of a window `win_cols` wide:
    /// `rowsFor`'s rule turned on its side.
    pub fn colsFor(win_cols: usize) usize {
        const share = win_cols * side_share_num / side_share_den;
        const room = @max(@min(max_cols, win_cols -| side_keep_cols), 1);
        return @min(@max(share, min_cols), room);
    }

    /// `colsFor`, or the width the user dragged the panel to, held only
    /// to the room the window has (`rowsForWanted`'s rule).
    pub fn colsForWanted(win_cols: usize, wanted: ?usize) usize {
        const w = wanted orelse return colsFor(win_cols);
        const room = @max(win_cols -| side_keep_cols, 1);
        return std.math.clamp(w, @min(min_dragged_cols, room), room);
    }

    /// A `layer_resize` from the host: the user dragged the panel's inner
    /// edge. Returns false for anyone else's layer, so the caller can
    /// pass every one through here.
    pub fn handleLayerResize(self: *Panel, ev: glyphwire.LayerResizeEvent, win: WinSize) bool {
        if (ev.context != self.context or ev.layer != self.layer) return false;
        switch (self.position) {
            .bottom, .top => self.wanted_rows = ev.rows,
            // 0 from a host that only knows top edges, which can't have
            // sent this for a side panel's anyway.
            .left, .right => if (ev.cols != 0) {
                self.wanted_cols = ev.cols;
            },
            .float => {},
        }
        if (self.visible) self.place(win) catch {};
        return true;
    }

    /// Opens the panel, starting the shell the first time. `cwd` is the
    /// directory it should be in.
    pub fn open(self: *Panel, cwd: []const u8, win: WinSize) !void {
        if (self.child == null) try self.start(cwd, win);
        // Visible first: `place` shows the frame only on an open panel.
        self.visible = true;
        errdefer self.visible = false;
        try self.place(win);
        try self.client.setLayerVisible(self.layer, true);
        self.focused = true;
        self.send("focus");
        self.setCwd(cwd);
    }

    /// Hides the panel and gives the keyboard back. The shell stays
    /// running behind it.
    pub fn close(self: *Panel) void {
        if (!self.visible) return;
        self.visible = false;
        if (self.focused) self.send("blur");
        self.focused = false;
        self.client.setLayerVisible(self.layer, false) catch {};
        self.client.setLayerVisible(self.frame_layer, false) catch {};
        // The panel had pointed the host's caret at its own layer.
        self.client.setCaretVisible(false) catch {};
        self.client.setCaretLayer(null) catch {};
    }

    /// Puts the layer where `position` says in a `win`-sized window
    /// (`layoutFor`), with its frame when floating, and tells the shell to
    /// re-read its size.
    pub fn place(self: *Panel, win: WinSize) !void {
        const l = layoutFor(win, self.position, self.float_percent, self.wanted_rows, self.wanted_cols);
        const r = l.content;
        try self.client.setLayerSize(self.layer, r.cols, r.rows);
        try self.client.setLayerCellPosition(self.layer, r.row, r.col);
        const edge = self.position.resizeEdge();
        if (self.sent_edge != edge) {
            try self.client.setLayerResizeEdge(self.layer, edge);
            self.sent_edge = edge;
        }
        if (l.frame) |fr| {
            self.bounds = fr;
            if (self.visible) try self.placeFrame(fr);
        } else {
            self.bounds = r;
            try self.client.setLayerVisible(self.frame_layer, false);
        }
        if (self.child != null) self.send("size");
    }

    /// Sizes the floating frame (and its nine-patch) to `fr` and shows it.
    fn placeFrame(self: *Panel, fr: Rect) !void {
        try self.client.setLayerSize(self.frame_layer, fr.cols, fr.rows);
        try self.client.setLayerCellPosition(self.frame_layer, fr.row, fr.col);
        if (self.frame_patch) |p| try self.client.updateNinePatch(self.frame_layer, p, .{ .rows = fr.rows, .cols = fr.cols });
        try self.client.setLayerVisible(self.frame_layer, true);
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
            .environ_map = self.environ_map,
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
