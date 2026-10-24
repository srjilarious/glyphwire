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
//! **The wire tree is edited minimally, not rebuilt.** A split's child
//! weights are the user's (a mouse drag or a resize key moved them), so a
//! structural edit sends the one fresh split's children and swaps exactly
//! one slot in its parent with `replace_pane_split_child`, which keeps that
//! slot's size. Splitting a pane halves that pane and leaves every other
//! ratio alone; closing one hands its whole slot to its sibling -- see
//! `splittree`'s module doc comment. Zoom is cheaper still: it never
//! touches the real tree at all, just swaps which split is the wire root.
//!
//! **The overlay is the one exception to drawing nothing.** The palette
//! and layout mode need a surface over every pane and the keyboard and
//! mouse while they are up, so gmux keeps one pane of its own outside the
//! tree and raises it over the window for as long as a mode lasts
//! (`set_overlay_pane`, see `raise`). Both connections are bound to it:
//! this one draws there, the listener hears its input. It is still the
//! session that routes that input, by focus, so gmux sees keystrokes only
//! while its own pane has them.

const std = @import("std");
const glyphwire = @import("glyphwire");

const splittree = @import("applib").splittree;
const layout = @import("layout.zig");
const actions = @import("actions.zig");
const keybind = @import("applib").keybind;
const palette = @import("applib").palette;
const config = @import("config.zig");
const arrange = @import("arrange.zig");

const Client = glyphwire.Client;
const InputListener = glyphwire.InputListener;
const PaneId = layout.PaneId;

/// Cells to move a divider per resize keystroke.
const resize_step: i64 = 2;

const Bounds = splittree.Rect;
const Direction = splittree.Direction;

/// What the raised overlay is for, if anything.
const Mode = enum { none, palette, layout };

/// Layout mode's note across the top of the window.
const layout_hint = " Layout: drag a pane onto another's edge to move it there, onto its middle to swap  \u{00b7}  Esc to finish ";

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
    /// The directory gmux was started in: where the first pane's program
    /// starts, and where a split's does when the host can't read the
    /// split pane's shell's directory. Owned; null if it couldn't be read.
    start_cwd: ?[]const u8 = null,
    /// Every prefix command: `actions.defaults` with the config's `keys`
    /// over them.
    keymap: actions.Keymap = .{},
    /// The prefix chord itself (Ctrl plus `prefix_key`), which the
    /// palette shows in front of every command's key.
    prefix_chord: keybind.Chord,

    /// gmux's own pane, never in the tree: raised over the window while a
    /// mode is up, lowered otherwise (see the module doc comment).
    overlay: PaneId = 0,
    mode: Mode = .none,
    /// The overlay's size in cells, i.e. the window's, as of the last
    /// raise or `resize`.
    win: struct { cols: usize = 0, rows: usize = 0 } = .{},
    /// Ctrl+B P. Its layers are on the overlay.
    palette: palette.Popup = undefined,
    /// Layout mode's one-line note (`layout_hint`), on the overlay.
    hint_layer: glyphwire.LayerHandle = 0,
    /// The pane being dragged in layout mode, and where it would land.
    drag: ?struct { pane: PaneId, drop: ?arrange.Drop = null } = null,

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
            .start_cwd = currentDir(alloc, io),
            .prefix_chord = actions.sendPrefixChord(cfg.prefix_key),
        };
        errdefer if (self.start_cwd) |d| alloc.free(d);
        errdefer self.bounds.deinit();
        self.keymap = try actions.Keymap.initDefaults(alloc, &actions.defaults);
        errdefer self.keymap.deinit(alloc);
        // Before `apply`, so `keys` can still move or drop it.
        try self.keymap.bind(alloc, self.prefix_chord, .sendPrefix);
        try self.keymap.apply(alloc, cfg.keys);

        // The overlay, before anything is drawn on it: binding both
        // connections first is what puts the layers below on its context,
        // and what keeps the listener's raw input streams (subscribed in
        // `main.zig`) gated on its focus rather than the shell gmux was
        // started from.
        const overlay = try client.createPane(0);
        self.overlay = overlay.pane;
        try client.attachPane(overlay.pane);
        try listener.attachPane(overlay.pane);
        try client.setCaretVisible(false);
        self.hint_layer = try client.createLayer(1, 1, 0);
        try client.setLayerVisible(self.hint_layer, false);
        try client.setLayerBackground(self.hint_layer, glyphwire.Color.role(.popup_bg));
        // Last, so it composites over the hint.
        self.palette = try palette.Popup.init(alloc, client, try self.paletteStyle());
        errdefer self.palette.deinit();

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
        try self.spawnIn(first.pane, null);
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
        self.client.destroyPane(self.overlay) catch {};
        self.client.setRootPaneSplit(null) catch {};
        self.client.setWindowPrefix(null, true, false, false) catch {};

        self.palette.deinit();
        self.bounds.deinit();
        self.tree.deinit();
        self.keymap.deinit(self.alloc);
        if (self.start_cwd) |d| self.alloc.free(d);
        self.alloc.destroy(self);
    }

    /// Starts this pane's program. `spawn_in_pane` hands the host the argv
    /// and nothing else: the host knows the pane's size and what env lets
    /// the child find it, which is why spawning isn't gmux's job (see
    /// `dispatch.PaneSpawner`).
    ///
    /// It starts in the directory of `cwd_from`'s shell, read by the host
    /// (only it knows which process in a pane is the shell), or else where
    /// gmux was started -- the way a terminal's new tab follows the one
    /// you were in.
    fn spawnIn(self: *Ui, pane: PaneId, cwd_from: ?PaneId) !void {
        _ = try self.client.spawnInPane(pane, &.{self.shell_cmd}, .{ .cwd = self.start_cwd, .cwd_from = cwd_from });
    }

    fn currentDir(alloc: std.mem.Allocator, io: std.Io) ?[]const u8 {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const n = std.process.currentPath(io, &buf) catch return null;
        return alloc.dupe(u8, buf[0..n]) catch null;
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
                // The overlay's own input: only ever while it is raised and
                // focused, since the session gates it on focus.
                .key => |k| self.modeKey(k),
                .text, .paste => |t| self.modeText(t.text),
                .mouse_button => |m| self.modeMouseButton(m),
                .mouse_move => |m| self.modeMouseMove(m.cell),
                .scroll_offset => |so| if (self.mode == .palette and self.palette.scrolled(so)) self.redraw(),
                .resize => |r| {
                    self.win = .{ .cols = r.cols, .rows = r.rows };
                    self.redraw();
                },
                .theme => self.restyle(),
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
            // Raw input is the overlay's, taken in `run` before this.
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
        // A mode's own keys close it again. Any other command ends the mode
        // first: it acts on the panes, which the overlay is covering.
        if (self.mode != .none) {
            const own = (a == .commandPalette and self.mode == .palette) or (a == .layoutMode and self.mode == .layout);
            self.endMode();
            if (own) return;
        }
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
            .rotateForward => self.rotate(.after) catch |err| self.logError("rotate", err),
            .rotateBackward => self.rotate(.before) catch |err| self.logError("rotate", err),
            .quit => self.quit = true,
            .sendPrefix => self.client.sendWindowPrefix() catch |err| self.logError("send prefix", err),
            .commandPalette => self.openPalette() catch |err| {
                self.logError("command palette", err);
                self.endMode();
            },
            .layoutMode => self.openLayout() catch |err| {
                self.logError("layout mode", err);
                self.endMode();
            },
        }
    }

    fn logError(self: *Ui, what: []const u8, err: anyerror) void {
        _ = self;
        std.log.err("gmux: {s} failed: {t}", .{ what, err });
    }

    /// While a mode is up the overlay keeps the keyboard: the pane is only
    /// recorded, and `endMode` focuses it.
    fn setFocus(self: *Ui, id: PaneId) void {
        self.focused = id;
        if (self.mode != .none) return;
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
        return weightedInput(ref, 1);
    }

    fn weightedInput(ref: layout.ChildRef, weight: f32) glyphwire.PaneSplitChildInput {
        return switch (ref) {
            .pane => |id| glyphwire.PaneSplitChildInput.paneWeighted(id, weight),
            .split => |wire| glyphwire.PaneSplitChildInput.splitWeighted(wire, weight),
        };
    }

    /// Pushes split node `node`'s *current* two children at even weights --
    /// only for a split just created, whose list has never been sent.
    fn pushChildren(self: *Ui, node: *const layout.Node) !void {
        const refs = layout.childRefs(node);
        try self.client.setPaneSplitChildren(node.kind.split.handle, &.{ childInput(refs[0]), childInput(refs[1]) });
    }

    /// Re-points the slot `node` occupies in its parent split at whatever
    /// `node` now is, keeping the slot's size: the parent's ratio is
    /// whatever the user dragged it to (see the module doc comment).
    fn replaceInParent(self: *Ui, node: *const layout.Node) !void {
        const parent = node.parent.?;
        const child: glyphwire.PaneSplitChildInput = switch (layout.childRef(node)) {
            .pane => |id| .{ .pane = id },
            .split => |wire| .{ .split = wire },
        };
        try self.client.replacePaneSplitChild(parent.kind.split.handle, node.slot().?.index(), child);
    }

    fn splitFocused(self: *Ui, axis: layout.Axis) !void {
        const from = self.focused;
        const made = try self.client.createPane(self.scrollback_rows);
        errdefer self.client.destroyPane(made.pane) catch {};
        try self.bounds.put(made.pane, .{});

        const handle = try self.client.createPaneSplit(toWireAxis(axis), true);
        errdefer self.client.destroyPaneSplit(handle) catch {};
        const node = try self.tree.split(self.focused, made.pane, axis, handle, .after);
        try self.pushChildren(node);

        if (node.parent != null) {
            try self.replaceInParent(node);
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
        try self.spawnIn(made.pane, from);
        self.setFocus(made.pane);
    }

    fn killFocused(self: *Ui) !void {
        try self.removePane(self.focused);
    }

    /// Tears a pane down: promotes its sibling subtree in the tree (into
    /// the vacated split's slot, at that slot's size), destroys the
    /// vacated split, and destroys the pane (which stops the program in
    /// it). Closing the last pane is gmux's cue to quit, from
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

        if (removal.replacement.parent != null) {
            try self.replaceInParent(removal.replacement);
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

    /// Moves every pane one slot along the layout (`dir` as in
    /// `splittree.rotate`), leaving the splits and their ratios alone:
    /// each leaf's slot is re-pointed at its new pane with
    /// `replace_pane_split_child`, all in one batch so no frame shows a
    /// pane in two slots at once. Focus stays on the slot. While zoomed
    /// the zoom stays on and shows the pane that arrived in its slot.
    fn rotate(self: *Ui, dir: splittree.Side) !void {
        if (self.tree.count() < 2) return;

        // Each slot's rect before the move, so `bounds` can follow the
        // panes right away: an arrow in the next command measures from
        // where each pane now is, not where it was. The zoomed pane's
        // real slot is its pre-zoom rect, not the full window.
        var before: std.ArrayList(PaneId) = .empty;
        defer before.deinit(self.alloc);
        try self.tree.leavesInOrder(self.alloc, &before);
        const rects = try self.alloc.alloc(Bounds, before.items.len);
        defer self.alloc.free(rects);
        var focus_slot: usize = 0;
        for (before.items, rects, 0..) |id, *r, i| {
            r.* = self.bounds.get(id) orelse .{};
            if (self.zoomed) |z| if (z.pane == id) {
                r.* = z.restore_bounds;
            };
            if (id == self.focused) focus_slot = i;
        }

        var leaves: std.ArrayList(*layout.Node) = .empty;
        defer leaves.deinit(self.alloc);
        try self.tree.rotate(self.alloc, dir, &leaves);

        var batch = self.client.batch();
        defer batch.deinit();
        for (leaves.items) |node| {
            const parent = node.parent.?; // two or more leaves: none is the root
            try batch.replacePaneSplitChild(parent.kind.split.handle, node.slot().?.index(), .{ .pane = node.kind.leaf });
        }
        const arrived = leaves.items[focus_slot].kind.leaf;
        if (self.zoomed) |*z| {
            try batch.replacePaneSplitChild(z.wrapper, 0, .{ .pane = arrived });
            const full = self.bounds.get(z.pane) orelse Bounds{};
            for (leaves.items, rects) |node, r| try self.bounds.put(node.kind.leaf, r);
            try self.bounds.put(arrived, full);
            z.pane = arrived;
            z.restore_bounds = rects[focus_slot];
        } else {
            for (leaves.items, rects) |node, r| try self.bounds.put(node.kind.leaf, r);
        }
        var res = try batch.send();
        res.deinit();
        self.setFocus(arrived);
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

    // ── Modes: the palette and layout mode ──────────────────────────────

    /// Raises the overlay over the window and gives it the keyboard. The
    /// size is asked for after the raise, since only a raised overlay is
    /// laid out at the window's size.
    fn raise(self: *Ui, mode: Mode) !void {
        try self.client.setOverlayPane(self.overlay);
        try self.client.focusPane(self.overlay);
        self.mode = mode;
        const size = try self.client.getSize();
        self.win = .{ .cols = size.cols, .rows = size.rows };
    }

    /// Ends whatever mode is up: everything on the overlay hidden, focus
    /// handed back to the pane that had it (or took it meanwhile, see
    /// `setFocus`), then the overlay lowered -- in that order, so focus is
    /// never on a pane that has left the screen. A no-op with no mode up.
    fn endMode(self: *Ui) void {
        if (self.mode == .none) return;
        self.mode = .none;
        self.drag = null;
        if (self.palette.isOpen()) self.palette.close();
        self.client.setLayerVisible(self.hint_layer, false) catch {};
        self.client.setDropTarget(null, null) catch {};
        self.client.focusPane(self.focused) catch {};
        self.client.setOverlayPane(null) catch {};
    }

    /// Redraws what the mode up shows, after anything changed it.
    fn redraw(self: *Ui) void {
        switch (self.mode) {
            .none => {},
            .palette => self.renderPalette() catch |err| self.logError("draw palette", err),
            .layout => {
                self.renderHint() catch |err| self.logError("draw layout hint", err);
                if (self.drag) |d| self.showDrop(d.drop, d.pane);
            },
        }
    }

    /// Re-reads the theme for the palette's frame, which is a nine-patch
    /// picked by name and so doesn't recolour on its own.
    fn restyle(self: *Ui) void {
        const style = self.paletteStyle() catch return;
        self.palette.setStyle(style) catch |err| self.logError("restyle palette", err);
        self.redraw();
    }

    fn paletteStyle(self: *Ui) !palette.Style {
        const th = try self.client.getTheme();
        var style = palette.default_style;
        style.frame_style = th.panelStyle();
        return style;
    }

    /// A keystroke while the overlay has the keyboard.
    fn modeKey(self: *Ui, k: glyphwire.KeyEvent) void {
        if (!k.pressed) return;
        switch (self.mode) {
            .none => {},
            .palette => switch (self.palette.key(k) catch .handled) {
                .accept => self.acceptPalette(),
                .closed => self.endMode(),
                .handled => if (self.palette.dirty) self.redraw(),
            },
            .layout => if (std.mem.eql(u8, k.key, "escape") or std.mem.eql(u8, k.key, "enter")) self.endMode(),
        }
    }

    fn modeText(self: *Ui, text: []const u8) void {
        if (self.mode != .palette) return;
        self.palette.text(text) catch |err| self.logError("palette", err);
        if (self.palette.dirty) self.redraw();
    }

    fn modeMouseButton(self: *Ui, m: glyphwire.MouseButtonEvent) void {
        if (!std.mem.eql(u8, m.button, "left")) return;
        switch (self.mode) {
            .none => {},
            .palette => if (m.pressed) switch (self.palette.click(m.cell)) {
                .accept => self.acceptPalette(),
                .closed => self.endMode(),
                .handled => {},
            },
            .layout => if (m.pressed) self.startDrag(m.cell) else self.endDrag(),
        }
    }

    fn modeMouseMove(self: *Ui, cell: glyphwire.CellPos) void {
        if (self.mode != .layout) return;
        const d = if (self.drag) |*held| held else return;
        const rects = self.paneRects() catch return;
        defer self.alloc.free(rects);
        const drop = arrange.dropAt(rects, self.window(), d.pane, cell.row, cell.col);
        const same = if (drop) |a| (if (d.drop) |b| a.eql(b) else false) else d.drop == null;
        if (same) return;
        d.drop = drop;
        self.showDrop(drop, d.pane);
    }

    fn window(self: *const Ui) arrange.Rect {
        return .{ .cols = self.win.cols, .rows = self.win.rows };
    }

    /// Every pane in the tree with its rect. Caller frees.
    fn paneRects(self: *Ui) ![]arrange.PaneRect {
        const out = try self.alloc.alloc(arrange.PaneRect, self.bounds.count());
        var it = self.bounds.iterator();
        var i: usize = 0;
        while (it.next()) |e| : (i += 1) out[i] = .{ .pane = e.key_ptr.*, .rect = e.value_ptr.* };
        return out;
    }

    // ── The palette ─────────────────────────────────────────────────────

    /// Ctrl+B P: every command `inPalette` admits, with the keys that run
    /// it after the prefix.
    fn openPalette(self: *Ui) !void {
        try self.raise(.palette);
        var list = palette.List.init(self.alloc);
        {
            errdefer list.deinit();
            for (std.enums.values(actions.Action)) |a| {
                if (!actions.inPalette(a)) continue;
                try list.addAfterPrefix(@intFromEnum(a), @tagName(a), actions.paletteLabel(a), self.prefix_chord, self.keymap.chordFor(a));
            }
        }
        try self.palette.open(list);
        self.redraw();
    }

    /// Runs the pick as if its keys had been pressed, the overlay lowered
    /// first so the command acts on the panes with focus back where it was.
    fn acceptPalette(self: *Ui) void {
        const a = self.palette.selectedAs(actions.Action);
        self.endMode();
        self.command(a);
    }

    /// Across the top of the window, as wide and tall as the palette's
    /// style allows.
    fn renderPalette(self: *Ui) !void {
        var b = self.client.batch();
        defer b.deinit();
        try self.palette.render(&b, .{ .row = 0, .col = 0, .cols = self.win.cols, .rows = self.win.rows });
        var sent = try b.send();
        sent.deinit();
    }

    // ── Layout mode ─────────────────────────────────────────────────────

    /// Ctrl+B m. Nothing to arrange with one pane, so it doesn't start.
    fn openLayout(self: *Ui) !void {
        if (self.tree.count() < 2) return;
        try self.raise(.layout);
        self.redraw();
    }

    fn renderHint(self: *Ui) !void {
        const cols = @min(glyphwire.stringWidth(layout_hint), self.win.cols);
        if (cols == 0) return;
        var b = self.client.batch();
        defer b.deinit();
        try b.setLayerSize(self.hint_layer, cols, 1);
        try b.setLayerCellPosition(self.hint_layer, 0, (self.win.cols - cols) / 2);
        try b.writeSpans(&.{.{ .text = layout_hint }}, .{
            .layer = self.hint_layer,
            .row = 0,
            .col = 0,
            .fg = glyphwire.Color.role(.popup_fg),
            .max_cols = cols,
            .pad = true,
        });
        try b.setLayerVisible(self.hint_layer, true);
        var sent = try b.send();
        sent.deinit();
    }

    /// A press picks up the pane under the pointer; a press on a divider
    /// band picks up nothing.
    fn startDrag(self: *Ui, cell: glyphwire.CellPos) void {
        var it = self.bounds.iterator();
        while (it.next()) |e| {
            const r = e.value_ptr.*;
            if (cell.row >= r.row and cell.row < r.row + r.rows and cell.col >= r.col and cell.col < r.col + r.cols) {
                self.drag = .{ .pane = e.key_ptr.* };
                return;
            }
        }
    }

    /// The release drops the pane wherever the highlight says. Layout mode
    /// stays on for the next move.
    fn endDrag(self: *Ui) void {
        const d = self.drag orelse return;
        self.drag = null;
        self.client.setDropTarget(null, null) catch {};
        const drop = d.drop orelse return;
        self.applyDrop(d.pane, drop) catch |err| self.logError("move pane", err);
    }

    /// Washes the cells `drop` would give the dragged pane, on the
    /// overlay's root layer, under the hint; null clears it.
    fn showDrop(self: *Ui, drop: ?arrange.Drop, dragged: PaneId) void {
        const d = drop orelse {
            self.client.setDropTarget(null, null) catch {};
            return;
        };
        const rects = self.paneRects() catch return;
        defer self.alloc.free(rects);
        const root_run = switch (d) {
            .window => |e| arrange.windowRun(&self.tree, dragged, e.axis()),
            .pane => 0,
        };
        const r = arrange.highlight(d, rects, self.window(), root_run);
        self.client.setDropTarget(null, .{ .cells = .{ .row = r.row, .col = r.col, .rows = r.rows, .cols = r.cols } }) catch {};
    }

    /// Moves `dragged` to `drop`. The tree is edited first, then every
    /// split's children are re-sent in one batch with the weights
    /// `arrange.childWeights` gives them -- a move can reshape several
    /// splits at once, which the one-slot edits splitting and closing use
    /// can't express.
    fn applyDrop(self: *Ui, dragged: PaneId, drop: arrange.Drop) !void {
        const axis = switch (drop) {
            .pane => |p| switch (p.zone) {
                .center => return self.swapPanes(dragged, p.pane),
                .edge => |e| e.axis(),
            },
            .window => |e| e.axis(),
        };
        const handle = try self.client.createPaneSplit(toWireAxis(axis), true);
        const moved = arrange.move(&self.tree, dragged, drop, handle) catch |err| {
            self.client.destroyPaneSplit(handle) catch {};
            return err;
        };

        var splits: std.ArrayList(*layout.Node) = .empty;
        defer splits.deinit(self.alloc);
        try arrange.splitNodes(self.alloc, self.tree.root, &splits);

        var batch = self.client.batch();
        defer batch.deinit();
        for (splits.items) |n| {
            const w = arrange.childWeights(n, &moved.runs, &self.bounds, dragged);
            const refs = layout.childRefs(n);
            try batch.setPaneSplitChildren(n.kind.split.handle, &.{ weightedInput(refs[0], w[0]), weightedInput(refs[1], w[1]) });
        }
        // Layout mode unzoomed on the way in, so the wire root is the
        // tree's. Two or more panes, so the root is a split.
        const root = self.tree.root.kind.split.handle;
        if (root != self.current_root_wire) try batch.setRootPaneSplit(root);
        try batch.destroyPaneSplit(moved.removed_handle);
        var res = try batch.send();
        res.deinit();
        self.current_root_wire = root;
        self.setFocus(dragged);
    }

    /// A drop on another pane's middle: the two trade slots, every size
    /// kept, the way `rotate` moves panes.
    fn swapPanes(self: *Ui, a: PaneId, b: PaneId) !void {
        const nodes = try self.tree.swapLeaves(a, b);
        var batch = self.client.batch();
        defer batch.deinit();
        for (nodes) |node| {
            const parent = node.parent.?; // two or more leaves: none is the root
            try batch.replacePaneSplitChild(parent.kind.split.handle, node.slot().?.index(), .{ .pane = node.kind.leaf });
        }
        var res = try batch.send();
        res.deinit();
        const ra = self.bounds.get(a) orelse Bounds{};
        const rb = self.bounds.get(b) orelse Bounds{};
        try self.bounds.put(a, rb);
        try self.bounds.put(b, ra);
        self.setFocus(a);
    }
};
