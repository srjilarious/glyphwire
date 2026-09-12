//! gmux's glyphwire client: a binary split tree of panes, each running a
//! program of its own, plus the command loop behind the prefix key.
//!
//! **gmux draws nothing.** It owns no context, no layer, no PTY and no VT
//! state; it never sees a keystroke meant for a program, and never relays
//! one. Every pane is a sequestered host (see core.zig's Panes section):
//! the program inside it draws its own surface, the host runs its PTY, and
//! the session decides where input goes. What is left for a multiplexer to
//! do is exactly what a multiplexer is for -- deciding what panes exist,
//! where they sit, and which one has focus.
//!
//! That is the whole difference from the abandoned first version, which
//! made panes out of *layers* in one context that gmux owned, and therefore
//! had to be in the path of every byte of output and every keystroke. See
//! `docs/investigations/context-panes.md`.
//!
//! **The wire tree is edited minimally, not rebuilt.** glyphwire has no way
//! to read a split's current (possibly mouse-dragged) child weights back,
//! so a structural edit only ever touches the nodes on the path between the
//! edit and its nearest surviving ancestor -- see `layout.zig`'s module doc
//! comment. Zoom is cheaper still: it never touches the real tree at all,
//! just swaps which split is the wire root.

const std = @import("std");
const glyphwire = @import("glyphwire");

const layout = @import("layout.zig");
const config = @import("config.zig");

const Client = glyphwire.Client;
const InputListener = glyphwire.InputListener;
const PaneId = layout.PaneId;

/// Cells to move a divider per resize keystroke.
const resize_step: i64 = 2;

const Bounds = struct { row: usize = 0, col: usize = 0, cols: usize = 0, rows: usize = 0 };

const Direction = enum { left, right, up, down };

pub const Error = error{
    /// Another connection already holds the window-manager role -- there is
    /// a multiplexer running in this window already.
    WindowManagerTaken,
};

pub const Ui = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    client: *Client,
    listener: *InputListener,

    tree: layout.Tree,
    /// Every live pane's last-known window rect, mirrored from
    /// `pane_layout` events. Used for directional focus; the host owns the
    /// geometry itself, and resizing each program's terminal to match.
    bounds: std.AutoHashMap(PaneId, Bounds),
    focused: PaneId,

    /// Whichever split is *currently* the wire root -- the tree's own root
    /// split, the single-pane synthetic wrapper, or a zoom wrapper. Always
    /// valid once `init` returns.
    current_root_wire: glyphwire.PaneSplitHandle = 0,
    /// The synthetic 1-child split installed while the tree has exactly one
    /// pane (`set_root_pane_split` needs a real split even for one pane).
    /// Null once a second pane exists.
    single_wrapper: ?glyphwire.PaneSplitHandle = null,
    zoomed: ?struct {
        pane: PaneId,
        wrapper: glyphwire.PaneSplitHandle,
        /// What `current_root_wire` was before zooming, restored on unzoom.
        restore_root: glyphwire.PaneSplitHandle,
    } = null,

    scrollback_rows: usize,
    /// The program a fresh pane runs. Borrowed from the config's arena.
    shell_cmd: []const u8,

    quit: bool = false,

    pub fn init(
        alloc: std.mem.Allocator,
        io: std.Io,
        client: *Client,
        listener: *InputListener,
        cfg: *const config.Config,
    ) !*Ui {
        // Before anything else: only one multiplexer per window. Answered
        // rather than thrown by the server, so this is a clean message to
        // the user instead of a wire error.
        const token = try client.requestWindowManager() orelse return Error.WindowManagerTaken;
        // The role has two halves and gmux is two connections: this one
        // issues the pane calls, and the listener receives the window
        // commands. The token is how the listener joins the same role.
        try listener.joinWindowManager(token);

        const self = try alloc.create(Ui);
        errdefer alloc.destroy(self);

        self.* = .{
            .alloc = alloc,
            .io = io,
            .client = client,
            .listener = listener,
            .tree = undefined,
            .bounds = std.AutoHashMap(PaneId, Bounds).init(alloc),
            .focused = 0,
            .scrollback_rows = cfg.scrollback_rows,
            .shell_cmd = config.shellCommand(cfg),
        };
        errdefer self.bounds.deinit();

        // The prefix chord the session will enforce for us. From here on
        // every `window_key` / `window_text` we receive is a command, and
        // nothing else reaches us at all -- see `core.WindowPrefix`.
        try client.setWindowPrefix(&.{cfg.prefix_key}, true, false, false);

        const first = try client.createPane(cfg.scrollback_rows);
        self.tree = try layout.Tree.init(alloc, first.pane);
        errdefer self.tree.deinit();
        try self.bounds.put(first.pane, .{});
        self.focused = first.pane;

        const wrapper = try client.createPaneSplit(.row, true);
        try client.setPaneSplitChildren(wrapper, &.{glyphwire.PaneSplitChildInput.paneWeighted(first.pane, 1)});
        try client.setRootPaneSplit(wrapper);
        self.single_wrapper = wrapper;
        self.current_root_wire = wrapper;

        // Placed before spawning, so the program's first `get_property
        // "size"` already reports the pane's real dimensions rather than
        // the window's.
        try self.spawnIn(first.pane);
        try client.focusPane(first.pane);
        return self;
    }

    pub fn deinit(self: *Ui) void {
        // Destroying each pane stops the program in it. The server would
        // cull them anyway when this connection closes (a pane belongs to
        // the manager that made it), but doing it explicitly keeps the
        // teardown order obvious.
        var it = self.bounds.keyIterator();
        while (it.next()) |id| self.client.destroyPane(id.*) catch {};
        self.client.setRootPaneSplit(null) catch {};
        self.client.setWindowPrefix(null, true, false, false) catch {};

        self.bounds.deinit();
        self.tree.deinit();
        self.alloc.destroy(self);
    }

    /// Starts this pane's program. `spawn_in_pane` hands the host the argv
    /// and nothing else: the host knows the pane's size and what env lets
    /// the child find it, which is why spawning isn't gmux's job (see
    /// `dispatch.PaneSpawner`).
    fn spawnIn(self: *Ui, pane: PaneId) !void {
        _ = try self.client.spawnInPane(pane, &.{self.shell_cmd}, null, null);
    }

    // ── Loop ────────────────────────────────────────────────────────────

    pub fn run(self: *Ui) !void {
        while (!self.quit) {
            try self.drainEvents();
            if (self.quit) break;

            if (self.listener.waitInputEvent(.{
                .duration = .{ .raw = .fromMilliseconds(50), .clock = .awake },
            }) catch null) |ev| {
                defer ev.deinit(self.alloc);
                try self.handleInput(ev);
            }
        }
    }

    fn drainEvents(self: *Ui) !void {
        while (self.listener.pollPaneLayoutEvent()) |ev| {
            defer ev.deinit(self.alloc);
            for (ev.panes) |b| {
                if (!self.bounds.contains(b.pane)) continue;
                try self.bounds.put(b.pane, .{ .row = b.row, .col = b.col, .cols = b.cols, .rows = b.rows });
            }
        }
        // A pane's program exited. Nothing happens to the pane on its own:
        // it belongs to gmux, not to the program, so closing it is gmux's
        // decision -- and closing the last one is gmux's cue to quit.
        while (self.listener.pollPaneExitEvent()) |ev| {
            try self.removePane(ev.pane);
        }
    }

    // ── Input ───────────────────────────────────────────────────────────

    /// Every event that reaches gmux is a window command. The session
    /// withholds the prefix itself and delivers only what follows it, so
    /// there is no prefix state to track here and no possibility of a
    /// command leaking through to a program -- the failure mode that
    /// defined the previous design.
    fn handleInput(self: *Ui, ev: glyphwire.InputEvent) !void {
        switch (ev) {
            .window_key => |k| if (k.pressed) self.command(k.key, null),
            .window_text => |t| self.command(null, t.text),
            .shutdown => self.quit = true,
            // gmux is never in the focused pane, so raw input never arrives.
            // Ignored rather than asserted: a future host that does deliver
            // something here shouldn't crash the multiplexer.
            .key, .text, .paste, .copy_request => {},
        }
    }

    /// One prefix command, named either by a key (arrows) or by committed
    /// text (everything printable). A failed command is logged, not
    /// propagated: crashing the multiplexer over one failed split would
    /// take every other pane's program down with it.
    fn command(self: *Ui, key: ?[]const u8, text: ?[]const u8) void {
        if (key) |k| {
            if (std.mem.eql(u8, k, "left")) return self.moveFocus(.left);
            if (std.mem.eql(u8, k, "right")) return self.moveFocus(.right);
            if (std.mem.eql(u8, k, "up")) return self.moveFocus(.up);
            if (std.mem.eql(u8, k, "down")) return self.moveFocus(.down);
            return; // an unbound prefix sequence is swallowed, same as tmux
        }
        const t = text orelse return;
        var it = (std.unicode.Utf8View.init(t) catch return).iterator();
        const cp = it.nextCodepointSlice() orelse return;
        if (cp.len != 1) return;
        switch (cp[0]) {
            '"' => self.splitFocused(.column) catch |err| self.logError("split", err), // stacked: new pane below
            '%' => self.splitFocused(.row) catch |err| self.logError("split", err), // side by side: new pane right
            'x' => self.killFocused() catch |err| self.logError("kill pane", err),
            'z' => self.zoomToggle() catch |err| self.logError("zoom", err),
            'H' => self.resizeFocused(.row, false) catch |err| self.logError("resize", err),
            'L' => self.resizeFocused(.row, true) catch |err| self.logError("resize", err),
            'K' => self.resizeFocused(.column, false) catch |err| self.logError("resize", err),
            'J' => self.resizeFocused(.column, true) catch |err| self.logError("resize", err),
            'q' => self.quit = true,
            else => {},
        }
    }

    fn logError(self: *Ui, what: []const u8, err: anyerror) void {
        _ = self;
        std.log.err("gmux: {s} failed: {t}", .{ what, err });
    }

    fn setFocus(self: *Ui, id: PaneId) void {
        self.focused = id;
        self.client.focusPane(id) catch {};
    }

    /// Nearest pane whose rect is strictly beyond the focused pane's edge
    /// in `dir`, by the gap between the two edges. Doesn't require
    /// perpendicular overlap -- a reasonable heuristic, not a full
    /// tmux-style geometric layout search.
    fn moveFocus(self: *Ui, dir: Direction) void {
        const cur = self.bounds.get(self.focused) orelse return;

        var best: ?PaneId = null;
        var best_dist: i64 = std.math.maxInt(i64);
        var it = self.bounds.iterator();
        while (it.next()) |entry| {
            const id = entry.key_ptr.*;
            if (id == self.focused) continue;
            const b = entry.value_ptr.*;
            const dist: i64 = switch (dir) {
                .left => blk: {
                    if (b.col + b.cols > cur.col) break :blk null;
                    break :blk @as(i64, @intCast(cur.col)) - @as(i64, @intCast(b.col + b.cols));
                },
                .right => blk: {
                    if (b.col < cur.col + cur.cols) break :blk null;
                    break :blk @as(i64, @intCast(b.col)) - @as(i64, @intCast(cur.col + cur.cols));
                },
                .up => blk: {
                    if (b.row + b.rows > cur.row) break :blk null;
                    break :blk @as(i64, @intCast(cur.row)) - @as(i64, @intCast(b.row + b.rows));
                },
                .down => blk: {
                    if (b.row < cur.row + cur.rows) break :blk null;
                    break :blk @as(i64, @intCast(b.row)) - @as(i64, @intCast(cur.row + cur.rows));
                },
            } orelse continue;
            if (dist < best_dist) {
                best_dist = dist;
                best = id;
            }
        }
        if (best) |id| self.setFocus(id);
    }

    // ── Commands ────────────────────────────────────────────────────────

    fn toWireAxis(axis: layout.Axis) glyphwire.SplitAxis {
        return switch (axis) {
            .row => .row,
            .column => .column,
        };
    }

    fn childInput(ref: layout.ChildRef) glyphwire.PaneSplitChildInput {
        return switch (ref) {
            .pane => |id| glyphwire.PaneSplitChildInput.paneWeighted(id, 1),
            .split => |wire| glyphwire.PaneSplitChildInput.splitWeighted(wire, 1),
        };
    }

    /// Pushes `s`'s *current* two children -- called only for a split node
    /// whose child set just changed, never for an untouched sibling
    /// elsewhere in the tree (see the module doc comment).
    fn pushChildren(self: *Ui, s: *layout.SplitNode) !void {
        const refs = layout.childRefs(s);
        try self.client.setPaneSplitChildren(s.wire_id, &.{ childInput(refs[0]), childInput(refs[1]) });
    }

    fn splitFocused(self: *Ui, axis: layout.Axis) !void {
        if (self.zoomed != null) return; // unzoom first -- see the module doc comment

        const made = try self.client.createPane(self.scrollback_rows);
        errdefer self.client.destroyPane(made.pane) catch {};
        try self.bounds.put(made.pane, .{});

        const result = try self.tree.splitLeaf(self.focused, made.pane, axis);
        result.node.split.wire_id = try self.client.createPaneSplit(toWireAxis(axis), true);
        try self.pushChildren(&result.node.split);

        if (result.parent) |p| {
            try self.pushChildren(p);
        } else {
            // The fresh split is now the whole tree -- install it as the
            // real wire root, replacing the single-pane wrapper.
            try self.client.setRootPaneSplit(result.node.split.wire_id);
            if (self.single_wrapper) |w| {
                self.client.destroyPaneSplit(w) catch {};
                self.single_wrapper = null;
            }
            self.current_root_wire = result.node.split.wire_id;
        }

        // After the tree edit, so the pane is already placed and sized when
        // the program starts and reads its own dimensions.
        try self.spawnIn(made.pane);
        self.setFocus(made.pane);
    }

    fn killFocused(self: *Ui) !void {
        if (self.zoomed != null) return;
        try self.removePane(self.focused);
    }

    /// Tears a pane down: promotes its sibling subtree in the tree,
    /// destroys the vacated split, and destroys the pane (which stops the
    /// program in it). Closing the last pane is gmux's cue to quit, from
    /// either `x` or a program exiting on its own.
    ///
    /// A no-op for a pane that is already gone, so a `pane_exit` arriving
    /// just after an `x` for the same pane is harmless.
    fn removePane(self: *Ui, id: PaneId) !void {
        if (!self.bounds.contains(id)) return;

        if (self.tree.leafCount() == 1) {
            self.quit = true;
            _ = self.bounds.remove(id);
            self.client.destroyPane(id) catch {};
            return;
        }

        const removal = self.tree.removeLeaf(id) catch |err| switch (err) {
            error.LastPane => {
                self.quit = true;
                _ = self.bounds.remove(id);
                self.client.destroyPane(id) catch {};
                return;
            },
            else => return err,
        };

        if (removal.parent) |gp| {
            try self.pushChildren(gp);
        } else {
            switch (removal.sibling.*) {
                .leaf => |only_id| {
                    const wrapper = try self.client.createPaneSplit(.row, true);
                    try self.client.setPaneSplitChildren(wrapper, &.{
                        glyphwire.PaneSplitChildInput.paneWeighted(only_id, 1),
                    });
                    try self.client.setRootPaneSplit(wrapper);
                    self.single_wrapper = wrapper;
                    self.current_root_wire = wrapper;
                },
                .split => |*s| {
                    try self.client.setRootPaneSplit(s.wire_id);
                    self.current_root_wire = s.wire_id;
                },
            }
        }
        self.client.destroyPaneSplit(removal.removed_wire_id) catch {};

        if (self.focused == id) self.setFocus(layout.Tree.firstLeaf(removal.sibling));

        _ = self.bounds.remove(id);
        self.client.destroyPane(id) catch {};
    }

    /// Zoom swaps the wire root for a 1-child wrapper holding the focused
    /// pane. Every other pane simply stops being reached by the layout walk
    /// and goes unmapped -- it keeps its program and its contents, it just
    /// isn't composited or focusable. The real tree, and whatever ratios a
    /// mouse drag left on it, sit untouched underneath.
    fn zoomToggle(self: *Ui) !void {
        if (self.zoomed) |z| {
            try self.client.setRootPaneSplit(z.restore_root);
            self.current_root_wire = z.restore_root;
            self.client.destroyPaneSplit(z.wrapper) catch {};
            self.zoomed = null;
            // Focus has to be re-asserted: it fell back to the root pane
            // while this pane's neighbours were unmapped.
            self.setFocus(z.pane);
            return;
        }

        const wrapper = try self.client.createPaneSplit(.row, true);
        try self.client.setPaneSplitChildren(wrapper, &.{glyphwire.PaneSplitChildInput.paneWeighted(self.focused, 1)});
        try self.client.setRootPaneSplit(wrapper);
        self.zoomed = .{ .pane = self.focused, .wrapper = wrapper, .restore_root = self.current_root_wire };
        self.current_root_wire = wrapper;
        self.setFocus(self.focused);
    }

    /// `axis`: which split axis this resize applies to (the focused pane's
    /// immediate parent has to have it, or there's nothing to move);
    /// `grow`: whether the focused pane should get bigger.
    /// `move_pane_divider`'s `delta` is signed relative to the child at
    /// `index` (always 0 here -- a binary split has exactly one divider):
    /// positive grows slot `a` and shrinks slot `b`.
    fn resizeFocused(self: *Ui, axis: layout.Axis, grow: bool) !void {
        const info = self.tree.parentOf(self.focused) orelse return;
        if (info.parent.axis != axis) return; // this key doesn't apply here
        const grows_a = grow == (info.slot == .a);
        const delta: i64 = if (grows_a) resize_step else -resize_step;
        try self.client.movePaneDivider(info.parent.wire_id, 0, delta);
    }
};
