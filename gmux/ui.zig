// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: GPL-3.0-or-later

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
//! had to be in the path of every byte of output and every keystroke.
//!
//! **The wire tree is edited minimally, not rebuilt.** glyphwire has no way
//! to read a split's current (possibly mouse-dragged) child weights back,
//! so a structural edit only ever touches the nodes on the path between the
//! edit and its nearest surviving ancestor -- see `layout.zig`'s module doc
//! comment. Zoom is cheaper still: it never touches the real tree at all,
//! just swaps which split is the wire root.

const std = @import("std");
const glyphwire = @import("glyphwire");

const splittree = @import("applib").splittree;
const layout = @import("layout.zig");
const actions = @import("actions.zig");
const keybind = @import("applib").keybind;
const config = @import("config.zig");

const Client = glyphwire.Client;
const InputListener = glyphwire.InputListener;
const PaneId = layout.PaneId;

/// Cells to move a divider per resize keystroke.
const resize_step: i64 = 2;

const Bounds = splittree.Rect;
const Direction = splittree.Direction;

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
        /// A tree edit made while zoomed (a hidden pane's program exiting)
        /// updates this instead of the wire root -- see `installRoot`.
        restore_root: glyphwire.PaneSplitHandle,
        /// The pane's rect before it filled the window. Put back into
        /// `bounds` on unzoom, so a focus move in the same command (an
        /// arrow) doesn't measure from the full-window rect before the
        /// host's `pane_layout` for the restored layout has arrived.
        restore_bounds: Bounds,
    } = null,

    scrollback_rows: usize,
    /// The program a fresh pane runs. Borrowed from the config's arena.
    shell_cmd: []const u8,
    /// Every prefix command: `actions.defaults` with the config's `keys`
    /// over them.
    keymap: actions.Keymap = .{},

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
        self.keymap = try actions.Keymap.initDefaults(alloc, &actions.defaults);
        errdefer self.keymap.deinit(alloc);
        try self.keymap.apply(alloc, cfg.keys);

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
        self.keymap.deinit(self.alloc);
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

    /// Blocks on the listener's one ordered queue: every window command,
    /// pane layout and pane exit wakes it, so there is nothing to poll.
    pub fn run(self: *Ui) !void {
        while (!self.quit) {
            const ev = try self.listener.next(.none) orelse continue;
            defer ev.deinit(self.alloc);
            switch (ev) {
                .pane_layout => |l| for (l.panes) |b| {
                    if (!self.bounds.contains(b.pane)) continue;
                    try self.bounds.put(b.pane, .{ .row = b.row, .col = b.col, .cols = b.cols, .rows = b.rows });
                },
                // A pane's program exited. Nothing happens to the pane on
                // its own: it belongs to gmux, not to the program, so
                // closing it is gmux's decision -- and closing the last one
                // is gmux's cue to quit.
                .pane_exit => |e| try self.removePane(e.pane),
                // Focus moved -- often by a click, which no command of
                // ours caused. Followed so `z`, `x` and the arrows act on
                // the pane the user is actually in. Only the record is
                // updated: the host has already moved focus.
                .pane_focus => |f| if (self.bounds.contains(f.pane)) {
                    self.focused = f.pane;
                },
                else => if (ev.asInput()) |input| try self.handleInput(input),
            }
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
            .window_key => |k| if (k.pressed) self.command(self.keyAction(k)),
            .window_text => |t| self.command(self.textAction(t.text)),
            .shutdown => self.quit = true,
            // gmux is never in the focused pane, so raw input never arrives.
            // Ignored rather than asserted: a future host that does deliver
            // something here shouldn't crash the multiplexer.
            .key, .text, .paste, .copy_request => {},
        }
    }

    /// The command a named key means. A letter or digit with no command
    /// modifier is skipped here: that keystroke also arrives as typed
    /// text, and `textAction` takes it from there so it follows the
    /// keyboard layout and doesn't run twice.
    fn keyAction(self: *const Ui, k: glyphwire.KeyEvent) ?actions.Action {
        const typing = !k.mods.ctrl and !k.mods.alt and !k.mods.super;
        if (typing and (k.key.len == 1 or isDigitName(k.key))) return null;
        return self.keymap.lookup(k.key, k.mods);
    }

    /// The command typed text means: a typed-character binding (`%`,
    /// `H`), else a lone letter or digit as the key of that name (`x`).
    fn textAction(self: *const Ui, text: []const u8) ?actions.Action {
        if (self.keymap.lookupText(text)) |a| return a;
        if (text.len != 1 or !std.ascii.isAlphanumeric(text[0])) return null;
        var lower: [1]u8 = .{std.ascii.toLower(text[0])};
        return self.keymap.lookup(keybind.normalizeKey(&lower), .{});
    }

    fn isDigitName(key: []const u8) bool {
        const names = [_][]const u8{ "zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine" };
        for (names) |n| if (std.mem.eql(u8, key, n)) return true;
        return false;
    }

    /// One prefix command. A failed command is logged, not propagated:
    /// crashing the multiplexer over one failed split would take every
    /// other pane's program down with it. An unbound prefix sequence is
    /// swallowed, same as tmux.
    fn command(self: *Ui, action: ?actions.Action) void {
        const a = action orelse return;
        // Everything but zoom itself and quit acts on the real layout, so
        // a zoom is undone first -- tmux's rule. Silently ignoring a split
        // while zoomed looked like gmux had stopped listening.
        if (!a.keepsZoom()) self.unzoom() catch |err| self.logError("unzoom", err);

        switch (a) {
            .focusLeft => self.moveFocus(.left),
            .focusRight => self.moveFocus(.right),
            .focusUp => self.moveFocus(.up),
            .focusDown => self.moveFocus(.down),
            .splitBelow => self.splitFocused(.column) catch |err| self.logError("split", err),
            .splitRight => self.splitFocused(.row) catch |err| self.logError("split", err),
            .killPane => self.killFocused() catch |err| self.logError("kill pane", err),
            .zoom => self.zoomToggle() catch |err| self.logError("zoom", err),
            .resizeLeft => self.resizeFocused(.row, false) catch |err| self.logError("resize", err),
            .resizeRight => self.resizeFocused(.row, true) catch |err| self.logError("resize", err),
            .resizeUp => self.resizeFocused(.column, false) catch |err| self.logError("resize", err),
            .resizeDown => self.resizeFocused(.column, true) catch |err| self.logError("resize", err),
            .quit => self.quit = true,
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

    /// The pane facing the focused one in `dir`: wholly on that side,
    /// overlapping it across the other axis, nearest first (see
    /// `splittree.neighbor`, which zoe's Ctrl+hjkl uses too).
    fn moveFocus(self: *Ui, dir: Direction) void {
        const n = self.bounds.count();
        const ids = self.alloc.alloc(PaneId, n) catch return;
        defer self.alloc.free(ids);
        const rects = self.alloc.alloc(Bounds, n) catch return;
        defer self.alloc.free(rects);

        var from: ?usize = null;
        var it = self.bounds.iterator();
        var i: usize = 0;
        while (it.next()) |entry| : (i += 1) {
            ids[i] = entry.key_ptr.*;
            rects[i] = entry.value_ptr.*;
            if (ids[i] == self.focused) from = i;
        }
        const hit = splittree.neighbor(rects, from orelse return, dir) orelse return;
        self.setFocus(ids[hit]);
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

    /// Pushes split node `node`'s *current* two children -- called only
    /// for a split whose child set just changed, never for an untouched
    /// sibling elsewhere in the tree (see the module doc comment).
    fn pushChildren(self: *Ui, node: *const layout.Node) !void {
        const refs = layout.childRefs(node);
        try self.client.setPaneSplitChildren(node.kind.split.handle, &.{ childInput(refs[0]), childInput(refs[1]) });
    }

    fn splitFocused(self: *Ui, axis: layout.Axis) !void {
        const made = try self.client.createPane(self.scrollback_rows);
        errdefer self.client.destroyPane(made.pane) catch {};
        try self.bounds.put(made.pane, .{});

        const handle = try self.client.createPaneSplit(toWireAxis(axis), true);
        errdefer self.client.destroyPaneSplit(handle) catch {};
        const node = try self.tree.split(self.focused, made.pane, axis, handle, .after);
        try self.pushChildren(node);

        if (node.parent) |p| {
            try self.pushChildren(p);
        } else {
            // The fresh split is now the whole tree -- install it as the
            // real wire root, replacing the single-pane wrapper.
            try self.installRoot(handle);
            if (self.single_wrapper) |w| {
                self.client.destroyPaneSplit(w) catch {};
                self.single_wrapper = null;
            }
        }

        // After the tree edit, so the pane is already placed and sized when
        // the program starts and reads its own dimensions.
        try self.spawnIn(made.pane);
        self.setFocus(made.pane);
    }

    fn killFocused(self: *Ui) !void {
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
        // The zoomed pane itself going away (its program exited) ends the
        // zoom: there is nothing left to show full-window. Any other pane
        // goes quietly, underneath it.
        if (self.zoomed) |z| if (z.pane == id) try self.unzoom();

        const removal = self.tree.remove(id) catch |err| switch (err) {
            error.LastLeaf => {
                self.quit = true;
                _ = self.bounds.remove(id);
                self.client.destroyPane(id) catch {};
                return;
            },
            else => return err,
        };

        if (removal.replacement.parent) |gp| {
            try self.pushChildren(gp);
        } else {
            switch (removal.replacement.kind) {
                .leaf => |only_id| {
                    const wrapper = try self.client.createPaneSplit(.row, true);
                    try self.client.setPaneSplitChildren(wrapper, &.{
                        glyphwire.PaneSplitChildInput.paneWeighted(only_id, 1),
                    });
                    try self.installRoot(wrapper);
                    self.single_wrapper = wrapper;
                },
                .split => |s| try self.installRoot(s.handle),
            }
        }
        self.client.destroyPaneSplit(removal.handle) catch {};

        if (self.focused == id) self.setFocus(removal.focus);

        _ = self.bounds.remove(id);
        self.client.destroyPane(id) catch {};
    }

    /// Zoom swaps the wire root for a 1-child wrapper holding the focused
    /// pane. Every other pane simply stops being reached by the layout walk
    /// and goes unmapped -- it keeps its program and its contents, it just
    /// isn't composited or focusable. The real tree, and whatever ratios a
    /// mouse drag left on it, sit untouched underneath.
    fn zoomToggle(self: *Ui) !void {
        if (self.zoomed != null) return self.unzoom();

        const wrapper = try self.client.createPaneSplit(.row, true);
        try self.client.setPaneSplitChildren(wrapper, &.{glyphwire.PaneSplitChildInput.paneWeighted(self.focused, 1)});
        try self.client.setRootPaneSplit(wrapper);
        self.zoomed = .{
            .pane = self.focused,
            .wrapper = wrapper,
            .restore_root = self.current_root_wire,
            .restore_bounds = self.bounds.get(self.focused) orelse .{},
        };
        self.current_root_wire = wrapper;
        self.setFocus(self.focused);
    }

    /// Puts the real tree back as the wire root. A no-op when not zoomed.
    fn unzoom(self: *Ui) !void {
        const z = self.zoomed orelse return;
        try self.client.setRootPaneSplit(z.restore_root);
        self.current_root_wire = z.restore_root;
        self.client.destroyPaneSplit(z.wrapper) catch {};
        self.zoomed = null;
        if (self.bounds.getPtr(z.pane)) |b| b.* = z.restore_bounds;
        // Focus has to be re-asserted: it fell back to the root pane
        // while this pane's neighbours were unmapped.
        self.setFocus(z.pane);
    }

    /// Makes `handle` the root of the real tree. While zoomed the wire
    /// root is the zoom wrapper and must stay that way, so the new root is
    /// only recorded for `unzoom` to install.
    fn installRoot(self: *Ui, handle: glyphwire.PaneSplitHandle) !void {
        if (self.zoomed) |*z| {
            z.restore_root = handle;
            return;
        }
        try self.client.setRootPaneSplit(handle);
        self.current_root_wire = handle;
    }

    /// `axis`: which split axis this resize applies to (the focused pane's
    /// immediate parent has to have it, or there's nothing to move);
    /// `grow`: whether the focused pane should get bigger.
    /// `move_pane_divider`'s `delta` is signed relative to the child at
    /// `index` (always 0 here -- a binary split has exactly one divider):
    /// positive grows the first child and shrinks the second.
    fn resizeFocused(self: *Ui, axis: layout.Axis, grow: bool) !void {
        const leaf = self.tree.find(self.focused) orelse return;
        const parent = (leaf.parent orelse return).kind.split;
        if (parent.axis != axis) return; // this key doesn't apply here
        const grows_first = grow == (leaf.slot() == .first);
        const delta: i64 = if (grows_first) resize_step else -resize_step;
        try self.client.movePaneDivider(parent.handle, 0, delta);
    }
};
