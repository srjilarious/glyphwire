// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: MPL-2.0

//! The `Session`: the one object the server holds. It owns every
//! `Context`, the pane tree that divides the window between them, and the
//! window-level state no single context owns: which pane and context have
//! focus, the keyboard input state, the window prefix and its managers,
//! and the profiler snapshot.

const std = @import("std");
const core = @import("core.zig");
/// Only for `Session.routeKey`'s printable-key test: whether a key name is
/// a key that also produces committed text. Pure, same module.
const key_encode = @import("key_encode.zig");
const version = @import("version.zig");

const CellRect = core.CellRect;
const ConnId = core.ConnId;
const Context = core.Context;
const ImageHandle = core.ImageHandle;
const InputState = core.InputState;
const Mods = core.Mods;
const SplitAxis = core.SplitAxis;
const theme = core.theme;

// ─── Sessions ───────────────────────────────────────────────────────────
//
// The server holds exactly one `Session`. It owns every `Context` and
// tracks which one is visible -- generalising the classic terminal
// alt-screen (`smcup`/`rmcup`) from a single alternate buffer to N
// independent, persistent contexts (decisions.md's Object Model). Only
// the top of the visibility stack is rendered; switching away never
// destroys a context, so a shell's prompt and scrollback are still
// there, untouched, when a full-screen editor's context is dismissed.

pub const ContextHandle = u32;

/// Handle of the session's root context -- the one the server starts
/// with (the shell's). Always exists, is never culled, and can't be
/// destroyed; it sits permanently at the bottom of the visibility stack
/// so there is always something to fall back to. Exactly
/// `root_layer_handle`'s role, one level up.
pub const root_context_handle: ContextHandle = 0;

pub const ContextError = error{
    UnknownContext,
    /// `destroy_context` named the root context, which has no lifecycle.
    RootContextImmutable,
};

/// `Session.grantContext`'s failures.
pub const AccessError = error{
    UnknownContext,
    /// The token presented isn't the context's (see `Session.grantContext`).
    ContextAccessDenied,
};

// ─── Profiler snapshot ─────────────────────────────────────────────────
//
// A plain-data view of glyphwire-host's frame-timing profiler (see
// `src/profiler.zig`, `host/profiler.zig`). The host refreshes
// `Session.profile` under `ctx_mutex` when profiling is enabled; the
// wire `get_property "profile"` handler in `dispatch.zig` reads it back.
// Core never interprets any of it -- it is a read-through only, kept here
// (rather than in `protocol.zig`) so `Session` can hold one by value.
// `name` fields always point at `@tagName` storage, so a snapshot stays
// valid for the process lifetime with nothing to free.

/// One timed phase's rolling stats, in milliseconds.
pub const ProfilePhase = struct {
    name: []const u8 = "",
    avg_ms: f32 = 0,
    p95_ms: f32 = 0,
    max_ms: f32 = 0,
};

/// One accumulating counter: the mean of its per-frame total over the
/// summary window (e.g. quads submitted per composited frame).
pub const ProfileCount = struct {
    name: []const u8 = "",
    per_frame: f32 = 0,
};

/// Upper bound on `ProfileSnapshot.phases` / `.counters` -- the profiler
/// `@compileError`s if a consumer declares more span / counter enum
/// members than this.
pub const profile_max_phases = 10;
pub const profile_max_counters = 8;

/// Everything `get_property "profile"` returns. `active` is false when
/// the host was built or configured without profiling, in which case
/// every other field is zero.
pub const ProfileSnapshot = struct {
    active: bool = false,
    /// Frames the renderer actually drew per second, averaged over the
    /// summary window; `skips_per_sec` counts iterations where
    /// `needsRedraw` said nothing moved and `render` was skipped.
    fps: f32 = 0,
    skips_per_sec: f32 = 0,
    phase_count: u8 = 0,
    counter_count: u8 = 0,
    phases: [profile_max_phases]ProfilePhase = @splat(.{}),
    counters: [profile_max_counters]ProfileCount = @splat(.{}),

    /// The populated phase / counter slices -- what a serializer or a
    /// formatter should walk (the arrays are fixed-size padding).
    pub fn phaseSlice(self: *const ProfileSnapshot) []const ProfilePhase {
        return self.phases[0..self.phase_count];
    }
    pub fn counterSlice(self: *const ProfileSnapshot) []const ProfileCount {
        return self.counters[0..self.counter_count];
    }
};

// ─── Panes ──────────────────────────────────────────────────────────────
//
// A pane is a rectangle of the window with its own stack of contexts. It
// is what makes a multiplexer possible: the split tree *inside* a context
// (see context.zig's Splits section) arranges layers, which is exactly
// right for one program's own sidebar and statusline, but a pane has to
// hold a whole other program -- including one that opens its own full-screen
// context.
//
// **From the program inside it, a pane is indistinguishable from the
// whole host.** `get_property "size"` returns the pane's cells. `resize`
// reports the pane's cells. `create_context` covers the pane and pops
// back to what was underneath when it is dismissed, which is alt-screen
// semantics at pane scope instead of window scope. Input arrives only
// while the pane is focused. Nothing a program can ask reveals where its
// pane sits, or that other panes exist -- see `Context.origin_row`. That
// sequestering is the whole point: a program needs no awareness of being
// multiplexed, so every existing client works inside a pane unchanged.
//
// The pane tree is deliberately the same shape as `Split`, one level up:
// same axis, same weight/fixed sizing, same divider bands, same
// minimally-edited contract. It is a separate set of types rather than a
// generic one because the two trees carry different child kinds and are
// walked by different owners (a `Context` lays out its layers; the
// `Session` lays out panes), and two short concrete walks read better
// than one parameterised one.

pub const PaneHandle = u32;

/// The pane that always exists: the whole window when no pane split tree
/// has been installed, and a leaf of that tree once one has. Holds the
/// session's root context, can't be destroyed, and is what focus falls
/// back to. Exactly `root_context_handle`'s role, one level up.
pub const root_pane_handle: PaneHandle = 0;

pub const PaneError = error{
    UnknownPane,
    /// `destroy_pane` named the root pane, which has no lifecycle.
    RootPaneImmutable,
    /// A pane-tree operation arrived from a connection that doesn't hold
    /// the window-manager role -- see `Session.manager`.
    NotWindowManager,
};

pub const PaneSplitHandle = u32;

pub const PaneSplitError = error{
    UnknownPaneSplit,
    /// A pane split named itself, directly or through a cycle, and the
    /// layout walk hit `max_pane_split_depth`.
    PaneSplitTooDeep,
    /// `replace_pane_split_child` named a slot past the end of the
    /// split's child list.
    PaneSplitChildOutOfRange,
};

/// One child of a pane split: what to place, and how big it is along the
/// parent's axis. Mirrors `SplitChild`.
pub const PaneSplitChild = struct {
    target: Target,
    size: Size = .{ .weight = 1 },

    pub const Target = union(enum) { pane: PaneHandle, split: PaneSplitHandle };
    pub const Size = union(enum) { weight: f32, fixed: usize };
};

pub const PaneSplit = struct {
    axis: SplitAxis,
    children: std.ArrayList(PaneSplitChild) = .empty,
    /// Whether the user may drag the bands between this split's children.
    /// False reserves no gap and emits no `PaneDividerRect`, same as
    /// `Split.resizable`.
    resizable: bool = true,
    /// The cell rect this split occupied at the last `layoutPanes` --
    /// `movePaneDivider` needs it to turn a drag in cells back into sizes.
    last_rect: CellRect = .{},
    laid_out: bool = false,

    pub fn deinit(self: *PaneSplit, alloc: std.mem.Allocator) void {
        self.children.deinit(alloc);
    }
};

/// A draggable band between two children of a pane split. The band
/// between two *panes* -- the one a multiplexer's user grabs to resize
/// them.
pub const PaneDividerRect = struct {
    split: PaneSplitHandle,
    /// The divider *after* child `index`, so `index` and `index + 1` are
    /// the pair it separates.
    index: usize,
    axis: SplitAxis,
    rect: CellRect,
};

/// One pane's laid-out rect, as carried by a `pane_layout` notification.
pub const PaneBounds = struct {
    pane: PaneHandle,
    row: usize,
    col: usize,
    cols: usize,
    rows: usize,
};

/// Recursion cap for the pane layout walk, the `max_split_depth`
/// equivalent. Lower, because a window split this deep leaves panes of
/// one cell.
pub const max_pane_split_depth: usize = 8;

/// Smallest extent a pane divider drag will leave a pane, in cells.
pub const min_pane_extent: usize = 2;

/// One window pane: a rect, and its own context visibility history.
pub const Pane = struct {
    /// The pane's rect in window cells, recomputed by
    /// `Session.layoutPanes`. For the root pane with no tree installed
    /// this is the whole window.
    rect: CellRect = .{},
    /// Whether the last `layoutPanes` actually reached this pane through
    /// the tree. A pane the manager has created but not yet placed, or
    /// has temporarily lifted out of the tree (a zoom), is unmapped: it
    /// keeps its contexts and its programs alive but is not composited
    /// and takes no input. The root pane is always mapped when there is
    /// no tree at all.
    mapped: bool = false,
    /// This pane's own context visibility history, bottom (index 0,
    /// always `base`) to top (what is on screen here). The per-pane
    /// counterpart of what used to be one session-wide stack: a
    /// full-screen program in this pane pushes onto *this* stack, so its
    /// context covers this pane and nothing else.
    stack: std.ArrayList(ContextHandle) = .empty,
    /// The context created together with the pane. Never destroyed while
    /// the pane lives, so `stack` can never empty and `top` is always
    /// valid.
    base: ContextHandle = root_context_handle,
    /// The window-manager connection that created this pane, for culling
    /// on disconnect. Zero for the root pane, which has no lifecycle.
    owner: ConnId = 0,

    pub fn deinit(self: *Pane, alloc: std.mem.Allocator) void {
        self.stack.deinit(alloc);
    }

    /// The context on screen in this pane. Never null: `base` can't leave
    /// the stack.
    pub fn top(self: *const Pane) ContextHandle {
        return self.stack.items[self.stack.items.len - 1];
    }
};

/// The window manager's prefix chord, and the one-shot state behind it.
///
/// This is what makes a multiplexer's key bindings work *without* the
/// multiplexer seeing every keystroke. The session withholds the prefix
/// itself from the focused pane, and hands the key that follows it to the
/// manager as a `window_key` / `window_text` instead of to the program.
///
/// Keeping the decision here rather than in the manager is the fix for the
/// failure the layer-based design kept hitting: a manager that has to
/// observe every keystroke in order to recognise its own prefix has, by
/// construction, already let the program have that keystroke by the time it
/// decides to swallow it. No amount of care in the manager can close that,
/// because the manager is not in the delivery path. Here it is decided
/// before delivery, once, in the one place that knows what has focus.
pub const WindowPrefix = struct {
    /// Longest key name this holds inline (no allocation). Real key names
    /// are one character or a short word ("b", "space", "left").
    pub const max_key_name = 16;

    key_buf: [max_key_name]u8 = @splat(0),
    key_len: u8 = 0,
    ctrl: bool = true,
    alt: bool = false,
    shift: bool = false,

    /// Builds a chord, truncating an over-long key name (which can then
    /// never match, rather than silently matching a prefix of itself).
    pub fn init(key_name: []const u8, ctrl: bool, alt: bool, shift: bool) WindowPrefix {
        var self: WindowPrefix = .{ .ctrl = ctrl, .alt = alt, .shift = shift };
        const n = @min(key_name.len, max_key_name);
        @memcpy(self.key_buf[0..n], key_name[0..n]);
        self.key_len = @intCast(n);
        return self;
    }

    pub fn key(self: *const WindowPrefix) []const u8 {
        return self.key_buf[0..self.key_len];
    }

    /// Whether `key_name` with these modifiers held is this chord.
    pub fn matches(self: *const WindowPrefix, key_name: []const u8, ctrl: bool, alt: bool, shift: bool) bool {
        if (!std.mem.eql(u8, key_name, self.key())) return false;
        return ctrl == self.ctrl and alt == self.alt and shift == self.shift;
    }
};

/// How many connections may hold the window-manager role at once. Two in
/// practice -- a program's `Client` and its paired `InputListener` -- with
/// headroom rather than an exact fit.
pub const max_managers = 4;

pub const Session = struct {
    alloc: std.mem.Allocator,
    /// Every context, keyed by handle. Key 0 is the root context, whose
    /// backing memory the *caller* of `init` owns; keys >= 1 are
    /// `create_context` contexts this session allocated and frees in
    /// `deinit`. Values are pointers so a handler (or a `Dispatcher`) can
    /// hold a `*Context` across a later `createContext` that rehashes
    /// this map.
    contexts: std.AutoHashMap(ContextHandle, *Context),
    next_context_handle: ContextHandle = 1,

    /// Every pane, keyed by handle. Key 0 (`root_pane_handle`) always
    /// exists and holds the root context.
    panes: std.AutoHashMap(PaneHandle, Pane),
    next_pane_handle: PaneHandle = 1,
    /// Pane split containers, keyed by handle. Empty, and
    /// `root_pane_split` null, for every session that never installs a
    /// window layout -- which is all of them until a multiplexer runs.
    pane_splits: std.AutoHashMap(PaneSplitHandle, PaneSplit),
    next_pane_split_handle: PaneSplitHandle = 1,
    /// The pane split that fills the window, if any. Null means the root
    /// pane simply *is* the window, which is the single-program case and
    /// the default.
    root_pane_split: ?PaneSplitHandle = null,
    /// Cells of gap between two children of a pane split.
    pane_divider_cells: usize = 1,

    /// The program serving this session -- glyphwire-host, or the
    /// headless glyphwire-server -- as `get_version` reports it. Set once
    /// by that program right after `Server.bind`; empty fields until then
    /// (a test's bare session). Borrowed: the strings are the program's
    /// `build_info` constants.
    host_info: version.Info = .{},

    /// The window size in cells -- the rect the pane tree is laid out
    /// over. Kept here rather than read off the root context, because
    /// once panes exist the root context is a *pane's* size, not the
    /// window's.
    window_cols: usize,
    window_rows: usize,

    /// The pane raw input goes to. A window with one pane always focuses
    /// it; a multiplexer moves this on every focus change.
    focused_pane: std.atomic.Value(PaneHandle) = .init(root_pane_handle),
    /// The connection currently holding the window-manager role, or null.
    /// At most one at a time; every pane-tree mutation requires it. See
    /// `claimManager`.
    /// The connections holding the window-manager role.
    ///
    /// A set rather than one connection because a program is two
    /// connections: a `Client` that issues the pane calls and an
    /// `InputListener` that receives the window commands. Both need the
    /// role, for different halves of it.
    ///
    /// The second one joins by presenting the token the first was given
    /// (see `claimManager`) -- the same shape `attach_context` uses to let
    /// a paired listener join the context its client created, and for the
    /// same reason: the two connections share knowledge in-process, so a
    /// token passed between them is proof of association that the server
    /// can check without inventing a notion of process identity.
    managers: [max_managers]ConnId = @splat(0),
    /// The token that joins the role, or 0 before anyone holds it.
    manager_token: u64 = 0,
    /// Lock-free mirror of `managers`, so the addressed `window_key` /
    /// `window_text` delivery can find its recipients while the connection
    /// registry is already locked. Same denormalisation, and the same
    /// reason, as `focused_context`.
    manager_conns: [max_managers]std.atomic.Value(ConnId) = @splat(.init(0)),
    /// The manager's registered prefix chord, or null when none is (which
    /// is every session without a multiplexer). See `WindowPrefix`.
    window_prefix: ?WindowPrefix = null,
    /// True between the prefix chord and the key that follows it -- a
    /// one-shot, exactly as tmux's prefix is.
    prefix_armed: bool = false,
    /// The key name whose *press* was withheld from the focused pane, so
    /// its matching release is withheld too. Without this a program sees a
    /// release with no press, which a VT-aware one can act on.
    swallowed_key: [WindowPrefix.max_key_name]u8 = @splat(0),
    swallowed_key_len: u8 = 0,
    /// The window-global modifier state `routeKey` matches the prefix
    /// against, folded left/right and maintained from the modifier key
    /// events `routeKey` itself sees.
    ///
    /// Tracked *here* rather than read off the focused context's input
    /// down-set, which is what this used to do and which broke the moment
    /// focus moved. `Context.input` is per *context*, `Server.ctx` follows
    /// the focused pane, and glyphwire-host edge-detects each modifier
    /// (`input.KeyInput.reportModifier`) -- so a modifier still held across
    /// a focus change is never re-reported, and the pane just focused has
    /// no idea it is down. `Ctrl-B <arrow>` therefore worked exactly once:
    /// the next `Ctrl-B` read `ctrl = false` from the pane it had just
    /// moved to, failed to match, and went to that pane's program.
    ///
    /// A keyboard is one keyboard. Its state belongs to the window.
    ///
    /// Also what every `key_*`/`mouse_*` notification's `mods` is stamped
    /// from, for the same reason (see `Mods`).
    mods: Mods = .{},
    /// Which keys/mouse buttons are down, window-wide -- what
    /// `report_key` / `report_mouse_button` dedupe against and what
    /// `get_input_state` reports. Session-owned for the same reason as
    /// `mods`; see `InputState`.
    input: InputState,

    /// Denormalised copies of "which context is on screen in the focused
    /// pane" and a change-counter, kept so lock-free readers
    /// (`Server.broadcast` deciding whether a connection should see an
    /// input event, glyphwire-host's render loop polling for a switch)
    /// never touch `panes` -- which is only ever mutated under the
    /// server's `ctx_mutex`. `visible_gen` is a counter, not a flag, so a
    /// switch between two polls is never missed.
    focused_context: std.atomic.Value(ContextHandle) = .init(root_context_handle),
    visible_gen: std.atomic.Value(u64) = .init(0),
    /// Bumped whenever the *pane* tree, a pane's rect, or the window size
    /// changed, i.e. whenever a previously computed pane layout (and its
    /// divider rects) went stale. glyphwire-host caches pane divider
    /// geometry against this exactly as it does `Context.layout_gen` for
    /// layer dividers.
    pane_layout_gen: std.atomic.Value(u64) = .init(0),

    /// glyphwire-host's latest frame-timing profiler snapshot, refreshed
    /// under `ctx_mutex` each iteration while profiling is on and returned
    /// verbatim by `get_property "profile"`. `.active == false` (the
    /// default) whenever the host isn't profiling; the session never reads
    /// or acts on any field. See `src/profiler.zig`.
    profile: ProfileSnapshot = .{},

    /// The window's theme: what every context that hasn't set its own
    /// (`Context.theme_own`) resolves colours against. glyphwire-host
    /// sets it from `theme.lua` (`setTheme`); a context created later
    /// starts with a copy.
    theme: theme.Stored,

    /// Wraps an already-created root context as the root pane's base. The
    /// caller keeps ownership of `root`'s memory and stays responsible for
    /// `root.deinit()`; this session frees only the contexts it creates
    /// itself.
    pub fn init(alloc: std.mem.Allocator, root: *Context) !Session {
        var contexts = std.AutoHashMap(ContextHandle, *Context).init(alloc);
        errdefer contexts.deinit();
        try contexts.put(root_context_handle, root);

        var panes = std.AutoHashMap(PaneHandle, Pane).init(alloc);
        errdefer panes.deinit();

        var root_pane: Pane = .{
            .base = root_context_handle,
            .mapped = true,
            .rect = .{ .cols = root.root.width, .rows = root.root.height },
        };
        errdefer root_pane.deinit(alloc);
        try root_pane.stack.append(alloc, root_context_handle);
        try panes.put(root_pane_handle, root_pane);

        return .{
            .alloc = alloc,
            .contexts = contexts,
            .panes = panes,
            .pane_splits = std.AutoHashMap(PaneSplitHandle, PaneSplit).init(alloc),
            .input = InputState.init(alloc),
            .theme = root.theme,
            .window_cols = root.root.width,
            .window_rows = root.root.height,
        };
    }

    pub fn deinit(self: *Session) void {
        var it = self.contexts.iterator();
        while (it.next()) |e| {
            if (e.key_ptr.* == root_context_handle) continue;
            e.value_ptr.*.deinit();
            self.alloc.destroy(e.value_ptr.*);
        }
        self.contexts.deinit();
        var pit = self.panes.valueIterator();
        while (pit.next()) |p| p.deinit(self.alloc);
        self.panes.deinit();
        var sit = self.pane_splits.valueIterator();
        while (sit.next()) |sp| sp.deinit(self.alloc);
        self.pane_splits.deinit();
        self.input.deinit();
    }

    /// Replaces the window's theme, and with it the theme of every
    /// context that hasn't set its own.
    pub fn setTheme(self: *Session, t: theme.Theme) void {
        self.theme.set(t);
        var it = self.contexts.valueIterator();
        while (it.next()) |ctx| {
            if (!ctx.*.theme_own) ctx.*.followTheme(&self.theme);
        }
    }

    /// The root context -- the asset source every other context falls
    /// back to, and the base of the root pane.
    pub fn rootContext(self: *Session) *Context {
        return self.contexts.get(root_context_handle).?;
    }

    pub fn contextPtr(self: *Session, handle: ContextHandle) ?*Context {
        return self.contexts.get(handle);
    }

    /// Total loaded-image bytes across every context -- what the sweep
    /// trigger compares against `default_image_sweep_budget`.
    pub fn imageBytes(self: *Session) usize {
        var total: usize = 0;
        var it = self.contexts.valueIterator();
        while (it.next()) |ctx| total += ctx.*.image_bytes;
        return total;
    }

    /// The scrollback image sweep: marks every image handle still
    /// reachable from a cell anywhere in the session, then frees the
    /// unreferenced, unpinned, socket-loaded ones in every context.
    /// Returns the bytes reclaimed.
    ///
    /// Mark-and-sweep rather than a per-cell refcount because a cell's
    /// image background is dropped by a dozen unrelated paths -- a
    /// scrollback eviction, `clear`, `delete_cells`, any `write_text`
    /// over the same cell, a `resize` that rebuilds the ring, a table
    /// repaint -- and a refcount would have to be threaded correctly
    /// through every one of them forever, where missing a single
    /// decrement leaks and a single double-decrement frees a picture
    /// still on screen. Scanning is O(cells), but it runs only when the
    /// stored bytes cross the budget, not per frame or per scroll.
    ///
    /// The marking pass has to span every context before *any* context is
    /// swept -- see `Context.sweepImages` on `asset_fallback`.
    pub fn sweepImages(self: *Session) !usize {
        var referenced = std.AutoHashMap(ImageHandle, void).init(self.alloc);
        defer referenced.deinit();

        var mark_it = self.contexts.valueIterator();
        while (mark_it.next()) |ctx| try ctx.*.markImageRefs(&referenced);

        var freed: usize = 0;
        var sweep_it = self.contexts.valueIterator();
        while (sweep_it.next()) |ctx| freed += try ctx.*.sweepImages(&referenced);

        // One counter for glyphwire-host to watch, wherever the bytes
        // actually came from -- see `Context.image_gen`.
        if (freed > 0) self.rootContext().image_gen +%= 1;
        return freed;
    }

    /// Sweeps only if the session is holding more image bytes than
    /// `budget`. The trigger the dispatcher calls after a successful
    /// `load_image` / `update_image`, so an interactive client that keeps
    /// pushing pictures into the scrollback pays for the cleanup rather
    /// than a background timer nobody owns.
    pub fn sweepImagesIfOverBudget(self: *Session, budget: usize) !usize {
        if (self.imageBytes() <= budget) return 0;
        return self.sweepImages();
    }

    /// Drops `conn`'s image pins across every context -- see
    /// `Context.releaseImages`. Called on disconnect.
    pub fn releaseImages(self: *Session, conn: ConnId) void {
        var it = self.contexts.valueIterator();
        while (it.next()) |ctx| ctx.*.releaseImages(conn);
    }

    pub fn panePtr(self: *Session, handle: PaneHandle) ?*Pane {
        return self.panes.getPtr(handle);
    }

    pub fn rootPane(self: *Session) *Pane {
        return self.panes.getPtr(root_pane_handle).?;
    }

    /// The context on screen in `pane`, or null for an unknown pane.
    pub fn paneContext(self: *Session, handle: PaneHandle) ?*Context {
        const pane = self.panes.getPtr(handle) orelse return null;
        return self.contexts.get(pane.top());
    }

    /// The focused pane's handle, read off the atomic (safe without
    /// `ctx_mutex`). Falls back to the root pane if the focused one was
    /// destroyed without focus moving, which `destroyPane` prevents but
    /// which this stays robust to anyway.
    pub fn focusedPaneHandle(self: *Session) PaneHandle {
        const h = self.focused_pane.load(.monotonic);
        return if (self.panes.contains(h)) h else root_pane_handle;
    }

    /// The context raw input belongs to: what's on screen in the focused
    /// pane. Never null. This is what used to be `visibleContext` when
    /// "visible" and "focused" were the same thing because there was only
    /// ever one pane.
    pub fn focusedContext(self: *Session) *Context {
        return self.contexts.get(self.focusedContextHandle()).?;
    }

    /// `focusedContext`'s handle, read through `panes` (call under
    /// `ctx_mutex`). Lock-free readers use `focused_context` instead.
    pub fn focusedContextHandle(self: *Session) ContextHandle {
        const pane = self.panes.getPtr(self.focusedPaneHandle()) orelse return root_context_handle;
        return pane.top();
    }

    /// Re-publishes `focused_context` / `visible_gen` after any
    /// visibility, focus or pane change, and re-lays-out every on-screen
    /// context's layer tree -- a context whose pane was resized while it
    /// was backgrounded had its root layer caught up by `layoutPanes` but
    /// its tree's cached rects left stale, and `layoutSplits` is
    /// idempotent and cheap. Every mutator below ends with this.
    fn republish(self: *Session) void {
        self.focused_context.store(self.focusedContextHandle(), .monotonic);
        _ = self.visible_gen.fetchAdd(1, .monotonic);
        var it = self.panes.valueIterator();
        while (it.next()) |p| {
            if (self.contexts.get(p.top())) |c| c.layoutSplits(null, null) catch {};
        }
    }

    // ── The window-manager role ─────────────────────────────────────────

    /// Grants `conn` the window-manager role and returns the token its
    /// sibling connection joins with, or null when another program already
    /// holds it -- two multiplexers in one window would fight over the same
    /// tree, so the second is told no rather than silently interleaving
    /// edits.
    ///
    /// `token` non-zero is a join: granted when it matches the one this
    /// session issued. A connection that already holds the role is answered
    /// again with the same token, so the call is idempotent.
    pub fn claimManager(self: *Session, conn: ConnId, token: u64) ?u64 {
        if (self.isManager(conn)) return self.manager_token;

        if (self.manager_token != 0) {
            // Someone holds it. A matching token means this is the holder's
            // other connection; anything else is a different program.
            if (token == 0 or token != self.manager_token) return null;
            if (!self.addManager(conn)) return null;
            return self.manager_token;
        }

        // First claim. The token only has to be unguessable by accident,
        // not by an attacker: every connection here is already inside the
        // user's own session.
        self.manager_token = std.hash.Wyhash.hash(0x9177, std.mem.asBytes(&conn)) | 1;
        if (!self.addManager(conn)) {
            self.manager_token = 0;
            return null;
        }
        return self.manager_token;
    }

    fn addManager(self: *Session, conn: ConnId) bool {
        for (&self.managers, 0..) |*slot, i| {
            if (slot.* != 0) continue;
            slot.* = conn;
            self.manager_conns[i].store(conn, .monotonic);
            return true;
        }
        return false;
    }

    pub fn isManager(self: *const Session, conn: ConnId) bool {
        if (conn == 0) return false;
        for (self.managers) |held| {
            if (held == conn) return true;
        }
        return false;
    }

    /// Drops `conn` from the role. When the last holder goes, the prefix
    /// chord goes with it -- a prefix with nobody to deliver to would
    /// swallow keystrokes into nothing -- and the token is cleared so the
    /// next multiplexer can claim cleanly.
    pub fn releaseManager(self: *Session, conn: ConnId) void {
        var any_left = false;
        for (&self.managers, 0..) |*slot, i| {
            if (slot.* == conn) {
                slot.* = 0;
                self.manager_conns[i].store(0, .monotonic);
                continue;
            }
            if (slot.* != 0) any_left = true;
        }
        if (any_left) return;
        self.manager_token = 0;
        self.window_prefix = null;
        self.prefix_armed = false;
        self.swallowed_key_len = 0;
    }

    /// What should happen to one key event, given the prefix state.
    pub const KeyRoute = enum {
        /// Normal: on to the focused pane's program.
        pass,
        /// Withheld from everyone (the prefix itself, or a release whose
        /// press was withheld).
        swallow,
        /// A window command: to the manager, not the program.
        manager,
    };

    /// Routes one key press or release. Call under the server's
    /// `ctx_mutex`; mutates the one-shot prefix state and the modifier
    /// state it matches against.
    ///
    /// Takes no modifier arguments: it derives them from the key events it
    /// is already being handed, which is the only view of the keyboard that
    /// stays correct across a focus change -- see `Session.mods`.
    pub fn routeKey(self: *Session, key_name: []const u8, pressed: bool) KeyRoute {
        // Folded in before the early return below: a manager can register
        // a prefix while a modifier is already held, and the next
        // keystroke has to match against the real keyboard.
        const is_mod = self.noteModifier(key_name, pressed);

        const prefix = self.window_prefix orelse return .pass;

        if (!pressed) {
            // Pair the release with the press that was withheld, so a
            // program never sees half a keystroke.
            if (self.swallowed_key_len > 0 and
                std.mem.eql(u8, key_name, self.swallowed_key[0..self.swallowed_key_len]))
            {
                self.swallowed_key_len = 0;
                return .swallow;
            }
            return .pass;
        }

        if (self.prefix_armed) {
            // A modifier's own press is not the command. It arrives as a
            // key event of its own, ahead of the key it modifies, so
            // treating it as the command swallowed the prefix and left the
            // real keystroke to fall through to the program. Passed on
            // rather than withheld, so the program's modifier state stays
            // accurate either way.
            if (is_mod) return .pass;

            // A printable key is about to arrive a *second* time as
            // committed text: an input-capturing host reports both streams
            // for one keystroke (glyphwire-host's `reportKeyEvents` then
            // `reportTextInput`). The text is the form a window command is
            // actually written in -- `"` and `%`, not `shift` plus
            // `apostrophe`/`five` -- and it is layout- and IME-correct
            // besides. So withhold the key event, stay armed, and let
            // `routeText` deliver the command.
            //
            // With Ctrl or Alt held there is no text event coming (a real
            // terminal sends a control byte, and SDL commits no text), so
            // the key event is the only chance to deliver the command.
            if (!self.mods.ctrl and !self.mods.alt and
                key_encode.charFromKeyName(key_name, self.mods.shift) != null)
            {
                self.noteSwallowed(key_name);
                return .swallow;
            }

            self.prefix_armed = false;
            self.noteSwallowed(key_name);
            return .manager;
        }
        if (prefix.matches(key_name, self.mods.ctrl, self.mods.alt, self.mods.shift)) {
            self.prefix_armed = true;
            self.noteSwallowed(key_name);
            return .swallow;
        }
        return .pass;
    }

    /// Routes committed text. Only ever a window command or normal input:
    /// text has no press/release to pair up. Every printable prefix
    /// command arrives here rather than through `routeKey`, which
    /// deliberately keeps the prefix armed across a printable key's press
    /// and waits for this -- see the armed branch there.
    pub fn routeText(self: *Session) KeyRoute {
        if (self.window_prefix == null) return .pass;
        if (!self.prefix_armed) return .pass;
        self.prefix_armed = false;
        return .manager;
    }

    /// Whether `key_name` is the key whose press was withheld and whose
    /// release is still owed -- i.e. a key the user is holding down as part
    /// of a prefix sequence. A typematic repeat for it must be dropped, the
    /// same as its press was, or holding a command key (`Ctrl-B` then a
    /// held arrow) starts leaking repeats into the program.
    pub fn isSwallowedKey(self: *const Session, key_name: []const u8) bool {
        if (self.swallowed_key_len == 0) return false;
        return std.mem.eql(u8, key_name, self.swallowed_key[0..self.swallowed_key_len]);
    }

    /// Folds one modifier key event into `mods`, and reports whether
    /// `key_name` was a modifier at all -- which is also how `routeKey`
    /// knows not to let one consume the armed prefix.
    ///
    /// Left and right fold together, because nothing in glyphwire
    /// distinguishes them: glyphwire-host forwards each modifier's
    /// *logical* state under its `left_*` name (see
    /// `input.KeyInput.reportKeyEvents`), which is also what picks up an
    /// OS-level remap like CapsLock acting as Control. A wire client that
    /// reports both physical sides and releases one will read as released
    /// here; the host never produces that.
    fn noteModifier(self: *Session, key_name: []const u8, pressed: bool) bool {
        const eql = std.mem.eql;
        if (eql(u8, key_name, "left_control") or eql(u8, key_name, "right_control")) {
            self.mods.ctrl = pressed;
            return true;
        }
        if (eql(u8, key_name, "left_alt") or eql(u8, key_name, "right_alt")) {
            self.mods.alt = pressed;
            return true;
        }
        if (eql(u8, key_name, "left_shift") or eql(u8, key_name, "right_shift")) {
            self.mods.shift = pressed;
            return true;
        }
        // `WindowPrefix` has no Super, so the prefix never matches on it;
        // it is stored for the `mods` stamped on input notifications.
        if (eql(u8, key_name, "left_super") or eql(u8, key_name, "right_super")) {
            self.mods.super = pressed;
            return true;
        }
        return false;
    }

    fn noteSwallowed(self: *Session, key_name: []const u8) void {
        const n = @min(key_name.len, WindowPrefix.max_key_name);
        @memcpy(self.swallowed_key[0..n], key_name[0..n]);
        self.swallowed_key_len = @intCast(n);
    }

    // ── Panes ───────────────────────────────────────────────────────────

    /// `create_pane`: a new pane plus the base context it displays,
    /// sized to the window until `layoutPanes` gives it a real rect. The
    /// pane starts unmapped: the manager places it by editing the tree.
    /// Returns both handles.
    pub fn createPane(self: *Session, owner: ConnId, scrollback_rows: usize) !struct {
        pane: PaneHandle,
        context: ContextHandle,
    } {
        const handle = self.next_pane_handle;

        var pane: Pane = .{ .owner = owner, .rect = .{ .cols = self.window_cols, .rows = self.window_rows } };
        errdefer pane.deinit(self.alloc);

        // The base context is created directly rather than through
        // `createContext`, which would need a pane that already exists.
        const ctx = try self.alloc.create(Context);
        errdefer self.alloc.destroy(ctx);
        const root = self.rootContext();
        ctx.* = try Context.init(self.alloc, self.window_cols, self.window_rows, scrollback_rows);
        errdefer ctx.deinit();
        ctx.theme = self.theme;
        ctx.cell_px_w = root.cell_px_w;
        ctx.cell_px_h = root.cell_px_h;
        ctx.asset_fallback = root;
        ctx.pane = handle;
        // A pane holds one program's whole surface, so its own root has
        // no window-wide scrollbar of its own to draw.
        ctx.window_scrollbar = false;

        const ctx_handle = self.next_context_handle;
        try self.contexts.put(ctx_handle, ctx);
        errdefer _ = self.contexts.remove(ctx_handle);

        pane.base = ctx_handle;
        try pane.stack.append(self.alloc, ctx_handle);
        try self.panes.put(handle, pane);

        self.next_context_handle += 1;
        self.next_pane_handle += 1;
        _ = self.pane_layout_gen.fetchAdd(1, .monotonic);
        self.republish();
        return .{ .pane = handle, .context = ctx_handle };
    }

    /// `destroy_pane`: frees the pane and every context in it. Focus
    /// falls back to the root pane if this pane had it. The caller is
    /// responsible for having removed the pane from the tree first; a
    /// stale child reference is skipped by the layout walk either way.
    pub fn destroyPane(self: *Session, handle: PaneHandle) PaneError!void {
        if (handle == root_pane_handle) return PaneError.RootPaneImmutable;
        var removed = self.panes.fetchRemove(handle) orelse return PaneError.UnknownPane;
        removed.value.deinit(self.alloc);

        // Every context that lived in this pane goes with it. Collected
        // first: destroying mutates `contexts`, which can't happen while
        // its iterator is live.
        var doomed: [16]ContextHandle = undefined;
        var n: usize = 0;
        var it = self.contexts.iterator();
        while (it.next()) |e| {
            if (e.key_ptr.* == root_context_handle) continue;
            if (e.value_ptr.*.pane != handle) continue;
            if (n >= doomed.len) break;
            doomed[n] = e.key_ptr.*;
            n += 1;
        }
        for (doomed[0..n]) |h| {
            if (self.contexts.fetchRemove(h)) |kv| {
                kv.value.deinit();
                self.alloc.destroy(kv.value);
            }
        }

        if (self.focused_pane.load(.monotonic) == handle) {
            self.focused_pane.store(root_pane_handle, .monotonic);
        }
        _ = self.pane_layout_gen.fetchAdd(1, .monotonic);
        self.republish();
    }

    /// `focus_pane`: which pane raw input goes to. Errors on an unknown
    /// or unmapped pane -- focusing something that isn't on screen would
    /// send every keystroke somewhere invisible.
    pub fn focusPane(self: *Session, handle: PaneHandle) PaneError!void {
        const pane = self.panes.getPtr(handle) orelse return PaneError.UnknownPane;
        if (!pane.mapped) return PaneError.UnknownPane;
        self.focused_pane.store(handle, .monotonic);
        self.republish();
    }

    /// The pane whose rect contains `(row, col)` in window cells, or null
    /// for a gap between panes (a divider band) or outside every pane.
    /// What a mouse click resolves through.
    pub fn paneAt(self: *Session, row: usize, col: usize) ?PaneHandle {
        var it = self.panes.iterator();
        while (it.next()) |e| {
            if (!e.value_ptr.mapped) continue;
            if (e.value_ptr.rect.contains(row, col)) return e.key_ptr.*;
        }
        return null;
    }

    // ── Pane split tree ─────────────────────────────────────────────────

    /// `create_pane_split`: an empty container. Draws and lays out
    /// nothing until it has children and is reached from
    /// `root_pane_split`.
    pub fn createPaneSplit(self: *Session, axis: SplitAxis, resizable: bool) !PaneSplitHandle {
        const handle = self.next_pane_split_handle;
        try self.pane_splits.put(handle, .{ .axis = axis, .resizable = resizable });
        self.next_pane_split_handle += 1;
        return handle;
    }

    /// `destroy_pane_split`: frees the container. Its children are *not*
    /// touched -- a child pane is a separate object with programs running
    /// in it, and a nested split is a handle its creator may still want.
    pub fn destroyPaneSplit(self: *Session, handle: PaneSplitHandle) PaneSplitError!void {
        var removed = self.pane_splits.fetchRemove(handle) orelse return PaneSplitError.UnknownPaneSplit;
        removed.value.deinit(self.alloc);
        if (self.root_pane_split == handle) self.root_pane_split = null;
        _ = self.pane_layout_gen.fetchAdd(1, .monotonic);
    }

    /// `set_pane_split_children`: replaces the child list wholesale.
    pub fn setPaneSplitChildren(self: *Session, handle: PaneSplitHandle, children: []const PaneSplitChild) !void {
        const split = self.pane_splits.getPtr(handle) orelse return PaneSplitError.UnknownPaneSplit;
        split.children.clearRetainingCapacity();
        try split.children.appendSlice(self.alloc, children);
        _ = self.pane_layout_gen.fetchAdd(1, .monotonic);
    }

    /// `replace_pane_split_child`: puts `target` in slot `index`,
    /// keeping that slot's size unless `size` says otherwise. The pane
    /// counterpart of `Context.replaceSplitChild` -- what a multiplexer
    /// splitting or closing one pane sends so the ratios the user dragged
    /// everywhere else survive.
    pub fn replacePaneSplitChild(
        self: *Session,
        handle: PaneSplitHandle,
        index: usize,
        target: PaneSplitChild.Target,
        size: ?PaneSplitChild.Size,
    ) PaneSplitError!void {
        const split = self.pane_splits.getPtr(handle) orelse return PaneSplitError.UnknownPaneSplit;
        if (index >= split.children.items.len) return PaneSplitError.PaneSplitChildOutOfRange;
        const slot = &split.children.items[index];
        slot.target = target;
        if (size) |sz| slot.size = sz;
        _ = self.pane_layout_gen.fetchAdd(1, .monotonic);
    }

    /// Each child's extent along the split's axis as of the last
    /// `layoutPanes`, all zero for a split never laid out. The pane
    /// counterpart of `Context.splitExtents`, behind `get_pane_split`.
    ///
    /// `out.len` must equal the child count.
    pub fn paneSplitExtents(self: *const Session, split: *const PaneSplit, out: []usize) void {
        if (!split.laid_out) {
            @memset(out, 0);
            return;
        }
        self.paneChildExtents(split, split.last_rect, out);
    }

    /// `set_root_pane_split`: which split fills the window. Null tears
    /// the layout down, leaving the root pane as the whole window again.
    pub fn setRootPaneSplit(self: *Session, handle: ?PaneSplitHandle) PaneSplitError!void {
        if (handle) |h| {
            if (!self.pane_splits.contains(h)) return PaneSplitError.UnknownPaneSplit;
        }
        self.root_pane_split = handle;
        _ = self.pane_layout_gen.fetchAdd(1, .monotonic);
    }

    /// Recomputes every pane's rect from the tree, mirrors it onto every
    /// context in that pane (size *and* origin), and re-lays-out each
    /// on-screen context's own layer tree. Both outputs are optional:
    /// `changed` collects the panes whose rect moved (what a
    /// `pane_layout` notification carries) and `dividers` the draggable
    /// bands (what the host hit-tests and draws).
    ///
    /// Idempotent. With no tree installed, the root pane takes the whole
    /// window, which is the single-program case and costs one rect
    /// comparison.
    pub fn layoutPanes(
        self: *Session,
        changed: ?*std.ArrayList(PaneBounds),
        dividers: ?*std.ArrayList(PaneDividerRect),
    ) !void {
        var it = self.panes.valueIterator();
        while (it.next()) |p| p.mapped = false;

        const full: CellRect = .{ .cols = self.window_cols, .rows = self.window_rows };
        if (self.root_pane_split) |root| {
            try self.layoutPaneSplit(root, full, changed, dividers, 0);
        } else {
            try self.applyPaneRect(root_pane_handle, full, changed);
        }

        // Every context follows its pane. A context whose pane went
        // unmapped keeps its last size: it is still live, just not shown,
        // and resizing it to nothing would destroy its contents.
        var cit = self.contexts.iterator();
        while (cit.next()) |e| {
            const ctx = e.value_ptr.*;
            const pane = self.panes.getPtr(ctx.pane) orelse continue;
            if (!pane.mapped) continue;
            ctx.origin_row = pane.rect.row;
            ctx.origin_col = pane.rect.col;
            try ctx.resize(@max(pane.rect.cols, 1), @max(pane.rect.rows, 1));
        }

        self.rescueFocus();
        self.republish();
    }

    /// Moves focus off a pane the layout just left unmapped, so input never
    /// goes somewhere invisible.
    ///
    /// This happens routinely, not exceptionally: a multiplexer taking over
    /// the window unmaps the pane it was launched from, and zooming unmaps
    /// every pane but one. Fixing it here rather than requiring the manager
    /// to call `focus_pane` at exactly the right moment removes a whole
    /// class of "keystrokes went nowhere" bug from every future manager.
    fn rescueFocus(self: *Session) void {
        const current = self.focused_pane.load(.monotonic);
        if (self.panes.getPtr(current)) |pane| {
            if (pane.mapped) return;
        }
        var it = self.panes.iterator();
        while (it.next()) |e| {
            if (!e.value_ptr.mapped) continue;
            self.focused_pane.store(e.key_ptr.*, .monotonic);
            return;
        }
        // Nothing is mapped at all (no tree, or a tree naming only dead
        // panes). The root pane always exists, so fall back to it rather
        // than leaving focus dangling.
        self.focused_pane.store(root_pane_handle, .monotonic);
    }

    fn layoutPaneSplit(
        self: *Session,
        handle: PaneSplitHandle,
        rect: CellRect,
        changed: ?*std.ArrayList(PaneBounds),
        dividers: ?*std.ArrayList(PaneDividerRect),
        depth: usize,
    ) !void {
        if (depth >= max_pane_split_depth) return;
        const split = self.pane_splits.getPtr(handle) orelse return;
        split.last_rect = rect;
        split.laid_out = true;

        const n = split.children.items.len;
        if (n == 0) return;

        const extents = try self.alloc.alloc(usize, n);
        defer self.alloc.free(extents);
        self.paneChildExtents(split, rect, extents);

        const gap: usize = if (split.resizable) self.pane_divider_cells else 0;

        var pos: usize = if (split.axis == .row) rect.col else rect.row;
        for (split.children.items, 0..) |child, i| {
            const extent = extents[i];
            const child_rect: CellRect = if (split.axis == .row)
                .{ .row = rect.row, .col = pos, .cols = extent, .rows = rect.rows }
            else
                .{ .row = pos, .col = rect.col, .cols = rect.cols, .rows = extent };

            switch (child.target) {
                .pane => |h| try self.applyPaneRect(h, child_rect, changed),
                .split => |h| try self.layoutPaneSplit(h, child_rect, changed, dividers, depth + 1),
            }

            pos += extent;
            if (i + 1 < n and gap > 0) {
                if (dividers) |out| {
                    const band: CellRect = if (split.axis == .row)
                        .{ .row = rect.row, .col = pos, .cols = gap, .rows = rect.rows }
                    else
                        .{ .row = pos, .col = rect.col, .cols = rect.cols, .rows = gap };
                    try out.append(self.alloc, .{
                        .split = handle,
                        .index = i,
                        .axis = split.axis,
                        .rect = band,
                    });
                }
                pos += gap;
            }
        }
    }

    /// `childExtents` for panes. Same rules: `fixed` children take their
    /// cells first, `weight` children share what's left, the last
    /// weighted one absorbs the rounding remainder.
    fn paneChildExtents(self: *const Session, split: *const PaneSplit, rect: CellRect, out: []usize) void {
        const n = split.children.items.len;
        const axis_total: usize = if (split.axis == .row) rect.cols else rect.rows;
        const gap: usize = if (split.resizable) self.pane_divider_cells else 0;
        var remaining = axis_total -| (n - 1) * gap;

        var fixed_total: usize = 0;
        var weight_total: f32 = 0;
        var last_weighted: ?usize = null;
        for (split.children.items, 0..) |c, i| switch (c.size) {
            .fixed => |f| fixed_total += f,
            .weight => |w| {
                weight_total += @max(w, 0);
                last_weighted = i;
            },
        };
        const flexible = remaining -| fixed_total;

        var flexible_used: usize = 0;
        for (split.children.items, 0..) |child, i| {
            const want: usize = switch (child.size) {
                .fixed => |f| f,
                .weight => |w| blk: {
                    if (weight_total <= 0) break :blk 0;
                    if (i == last_weighted.?) break :blk flexible -| flexible_used;
                    const share_f = @as(f32, @floatFromInt(flexible)) * (@max(w, 0) / weight_total);
                    const share: usize = @intFromFloat(@floor(share_f));
                    flexible_used += share;
                    break :blk share;
                },
            };
            out[i] = @min(want, remaining);
            remaining -= out[i];
        }
    }

    /// Places one pane at `rect` and marks it mapped. An unknown handle
    /// (a stale child the manager hasn't cleaned up) is skipped rather
    /// than failing the whole walk.
    fn applyPaneRect(self: *Session, handle: PaneHandle, rect: CellRect, changed: ?*std.ArrayList(PaneBounds)) !void {
        const pane = self.panes.getPtr(handle) orelse return;
        const moved = pane.rect.row != rect.row or pane.rect.col != rect.col or
            pane.rect.cols != rect.cols or pane.rect.rows != rect.rows;
        pane.rect = rect;
        pane.mapped = true;
        if (!moved) return;
        if (changed) |out| {
            try out.append(self.alloc, .{
                .pane = handle,
                .row = rect.row,
                .col = rect.col,
                .cols = rect.cols,
                .rows = rect.rows,
            });
        }
    }

    /// `move_pane_divider`: drags the band after child `index` by `delta`
    /// cells, growing one neighbour and shrinking the other. The pane
    /// counterpart of `Context.moveDivider`, with the same rule that a
    /// drag never silently converts a child's sizing mode. The caller
    /// re-runs `layoutPanes` afterwards.
    pub fn movePaneDivider(self: *Session, handle: PaneSplitHandle, index: usize, delta: i64) PaneSplitError!void {
        const split = self.pane_splits.getPtr(handle) orelse return PaneSplitError.UnknownPaneSplit;
        if (!split.laid_out or !split.resizable) return;
        const n = split.children.items.len;
        if (index + 1 >= n) return;
        if (delta == 0) return;

        const extents = self.alloc.alloc(usize, n) catch return;
        defer self.alloc.free(extents);
        self.paneChildExtents(split, split.last_rect, extents);

        const before = extents[index];
        const after = extents[index + 1];
        const pair = before + after;
        if (pair < 2 * min_pane_extent) return;

        const lo: i64 = @intCast(min_pane_extent);
        const hi: i64 = @intCast(pair - min_pane_extent);
        const want: i64 = @as(i64, @intCast(before)) + delta;
        const new_before: usize = @intCast(std.math.clamp(want, lo, hi));
        const new_after = pair - new_before;
        if (new_before == before) return;

        const a = &split.children.items[index];
        const b = &split.children.items[index + 1];
        const wa: ?f32 = switch (a.size) {
            .weight => |w| @max(w, 0),
            .fixed => null,
        };
        const wb: ?f32 = switch (b.size) {
            .weight => |w| @max(w, 0),
            .fixed => null,
        };

        if (wa == null) a.size = .{ .fixed = new_before };
        if (wb == null) b.size = .{ .fixed = new_after };
        if (wa != null and wb != null) {
            const total_w = wa.? + wb.?;
            if (total_w <= 0) return;
            const frac = @as(f32, @floatFromInt(new_before)) / @as(f32, @floatFromInt(pair));
            a.size = .{ .weight = total_w * frac };
            b.size = .{ .weight = total_w * (1 - frac) };
        }

        _ = self.pane_layout_gen.fetchAdd(1, .monotonic);
    }

    // ── Contexts ────────────────────────────────────────────────────────

    /// `create_context`: allocates a fresh context *in `pane`* (defaulting
    /// to that pane's current size) and makes it the one on screen there.
    /// The caller records the creating connection as first owner via
    /// `addContextOwner`.
    pub fn createContext(
        self: *Session,
        pane_handle: PaneHandle,
        width: ?usize,
        height: ?usize,
        scrollback_rows: usize,
    ) !ContextHandle {
        const pane = self.panes.getPtr(pane_handle) orelse return PaneError.UnknownPane;
        const root = self.rootContext();

        const ctx = try self.alloc.create(Context);
        errdefer self.alloc.destroy(ctx);
        ctx.* = try Context.init(
            self.alloc,
            width orelse @max(pane.rect.cols, 1),
            height orelse @max(pane.rect.rows, 1),
            scrollback_rows,
        );
        errdefer ctx.deinit();
        ctx.theme = self.theme;
        ctx.cell_px_w = root.cell_px_w;
        ctx.cell_px_h = root.cell_px_h;
        ctx.asset_fallback = root;
        ctx.pane = pane_handle;
        ctx.origin_row = pane.rect.row;
        ctx.origin_col = pane.rect.col;

        const handle = self.next_context_handle;
        try self.contexts.put(handle, ctx);
        errdefer _ = self.contexts.remove(handle);
        // `panes` isn't rehashed here, so `pane` is still valid.
        try pane.stack.append(self.alloc, handle);
        self.next_context_handle += 1;
        self.republish();
        return handle;
    }

    /// Adds `conn` to `handle`'s owner set (see `Context.owners`). Errors
    /// `UnknownContext` for an unknown handle or any pane's base context
    /// -- a base context has no lifecycle of its own, it lives and dies
    /// with its pane.
    pub fn addContextOwner(self: *Session, handle: ContextHandle, conn: ConnId) !void {
        if (self.isBaseContext(handle)) return ContextError.UnknownContext;
        const ctx = self.contexts.get(handle) orelse return ContextError.UnknownContext;
        try ctx.addOwner(conn);
    }

    /// Whether `conn` owns `handle` (false for a base context or any
    /// unknown handle) -- the `destroy_context` ownership check.
    pub fn contextHasOwner(self: *Session, handle: ContextHandle, conn: ConnId) bool {
        if (self.isBaseContext(handle)) return false;
        const ctx = self.contexts.get(handle) orelse return false;
        return ctx.hasOwner(conn);
    }

    /// Whether `conn` may act on `handle` at all -- read it, draw on it,
    /// take its input: it owns the context (`create_context` /
    /// `adopt_context`) or presented its token (`grantContext`). False for
    /// an unknown handle. The window manager's bypass is the dispatcher's
    /// to apply, not this.
    pub fn mayAccess(self: *Session, handle: ContextHandle, conn: ConnId) bool {
        const ctx = self.contexts.get(handle) orelse return false;
        return ctx.hasOwner(conn) or ctx.members.contains(conn);
    }

    /// Records that `conn` presented `token` for `handle`, and may act on
    /// it from now on (see `Context.members`). `UnknownContext` for an
    /// unknown handle, `ContextAccessDenied` for a wrong token -- the two
    /// are kept apart because a guessable handle is no secret, only the
    /// token is.
    pub fn grantContext(self: *Session, handle: ContextHandle, conn: ConnId, token: []const u8) (AccessError || std.mem.Allocator.Error)!void {
        const ctx = self.contexts.get(handle) orelse return AccessError.UnknownContext;
        if (!core.accessTokenMatches(&ctx.token, token)) return AccessError.ContextAccessDenied;
        try ctx.members.put(conn, {});
    }

    /// `grantContext` without a token, for a caller that is itself the
    /// authority: glyphwire-host opening a connection on a pane's behalf
    /// (`host/remote.zig`'s auth prompt), and tests.
    pub fn addContextMember(self: *Session, handle: ContextHandle, conn: ConnId) !void {
        const ctx = self.contexts.get(handle) orelse return ContextError.UnknownContext;
        try ctx.members.put(conn, {});
    }

    /// `handle`'s token, or null for an unknown handle. What glyphwire-host
    /// puts in `GLYPHWIRE_TOKEN` for a program it starts in a context.
    pub fn contextToken(self: *Session, handle: ContextHandle) ?core.AccessToken {
        const ctx = self.contexts.get(handle) orelse return null;
        return ctx.token;
    }

    /// The context in `pane_handle` whose token is `token`, or null for an
    /// unknown pane or a token matching none of them. What `attach_pane`
    /// lands a connection on: the context it was given the token for,
    /// rather than whatever happens to be on top of the pane.
    pub fn paneContextForToken(self: *Session, pane_handle: PaneHandle, token: []const u8) ?ContextHandle {
        const pane = self.panes.getPtr(pane_handle) orelse return null;
        for (pane.stack.items) |h| {
            const ctx = self.contexts.get(h) orelse continue;
            if (core.accessTokenMatches(&ctx.token, token)) return h;
        }
        return null;
    }

    /// Whether `handle` is some pane's base context, i.e. the one that
    /// can't be destroyed while that pane lives. True for the root
    /// context.
    pub fn isBaseContext(self: *Session, handle: ContextHandle) bool {
        var it = self.panes.valueIterator();
        while (it.next()) |p| {
            if (p.base == handle) return true;
        }
        return false;
    }

    /// Whether `handle` belongs to a shell rather than to a program run
    /// from one: any pane's base context, or one the host made for a
    /// switcher-spawned shell (`Context.spawned_shell`). `list_contexts`'
    /// `shell`.
    pub fn isShellContext(self: *Session, handle: ContextHandle) bool {
        if (self.isBaseContext(handle)) return true;
        const ctx = self.contexts.get(handle) orelse return false;
        return ctx.spawned_shell;
    }

    /// `pane`'s context stack, bottom (its base) to top (on screen), or
    /// null for an unknown pane. Borrowed: valid until the next pane or
    /// context mutation. What the context switcher and `list_contexts`
    /// show -- the programs a pane is holding, in the order they came up.
    pub fn paneStack(self: *Session, pane_handle: PaneHandle) ?[]const ContextHandle {
        const pane = self.panes.getPtr(pane_handle) orelse return null;
        return pane.stack.items;
    }

    /// `activate_context`: brings `handle` to the top of *its own pane's*
    /// stack. It stays in the stack once, wherever it already was, rather
    /// than being pushed again. Errors `UnknownContext` for an unknown
    /// handle; a no-op (but not an error) if it is already on top.
    pub fn activateContext(self: *Session, handle: ContextHandle) !void {
        const ctx = self.contexts.get(handle) orelse return ContextError.UnknownContext;
        const pane = self.panes.getPtr(ctx.pane) orelse return ContextError.UnknownContext;
        if (pane.top() == handle) return;
        for (pane.stack.items, 0..) |h, i| {
            if (h == handle) {
                _ = pane.stack.orderedRemove(i);
                break;
            }
        }
        try pane.stack.append(self.alloc, handle);
        self.republish();
    }

    /// `destroy_context`: frees `handle` and every layer, split, table
    /// and image it held (`Context.deinit`), and drops it from its pane's
    /// stack -- if it was on screen there, the context under it takes
    /// over. Errors `RootContextImmutable` for any pane's base context,
    /// `UnknownContext` for anything else unknown.
    pub fn destroyContext(self: *Session, handle: ContextHandle) ContextError!void {
        if (self.isBaseContext(handle)) return ContextError.RootContextImmutable;
        const removed = self.contexts.fetchRemove(handle) orelse return ContextError.UnknownContext;
        const pane_handle = removed.value.pane;
        removed.value.deinit();
        self.alloc.destroy(removed.value);
        self.dropFromStack(pane_handle, handle);
        self.republish();
    }

    /// Drops `conn` from every connection-owned context's owner set; any
    /// context left with no owners is destroyed and its handle appended to
    /// `culled_contexts`. Panes the connection created (it was the window
    /// manager) are destroyed too, and appended to `culled_panes`. Both
    /// lists are caller-owned and expected empty on entry. Called from
    /// `server.zig` when a connection closes, under `ctx_mutex`.
    pub fn reapConnection(
        self: *Session,
        conn: ConnId,
        culled_contexts: *std.ArrayList(ContextHandle),
        culled_panes: *std.ArrayList(PaneHandle),
    ) !void {
        self.releaseManager(conn);

        var it = self.contexts.iterator();
        while (it.next()) |e| {
            const ctx = e.value_ptr.*;
            // Access granted by token goes with the connection, on every
            // context including the bases.
            _ = ctx.members.remove(conn);
            if (self.isBaseContext(e.key_ptr.*)) continue;
            if (!ctx.connection_owned) continue;
            _ = ctx.owners.remove(conn);
            if (ctx.owners.count() == 0) try culled_contexts.append(self.alloc, e.key_ptr.*);
        }
        // Destroy in a second pass: `destroyContext` mutates
        // `self.contexts`, which can't happen while the iterator is live.
        for (culled_contexts.items) |h| {
            if (self.contexts.fetchRemove(h)) |removed| {
                const pane_handle = removed.value.pane;
                removed.value.deinit();
                self.alloc.destroy(removed.value);
                self.dropFromStack(pane_handle, h);
            }
        }

        // A pane outlives nothing: when the manager that made it goes, so
        // does the pane and every program's surface inside it.
        var pit = self.panes.iterator();
        while (pit.next()) |e| {
            if (e.key_ptr.* == root_pane_handle) continue;
            if (e.value_ptr.owner != conn) continue;
            try culled_panes.append(self.alloc, e.key_ptr.*);
        }
        for (culled_panes.items) |h| self.destroyPane(h) catch {};

        if (culled_panes.items.len > 0) {
            // The tree still names panes that no longer exist; without a
            // manager to fix it, drop it so the root pane fills the
            // window again rather than leaving holes on screen.
            self.root_pane_split = null;
            _ = self.pane_layout_gen.fetchAdd(1, .monotonic);
            self.layoutPanes(null, null) catch {};
        }
        if (culled_contexts.items.len > 0 or culled_panes.items.len > 0) self.republish();
    }

    /// The window changed size: re-lay-out the pane tree, which resizes
    /// every pane's contexts to their new rects. A context backgrounded
    /// during the resize is caught up too, rather than showing a stale
    /// grid when it next comes forward.
    pub fn resizeWindow(self: *Session, cols: usize, rows: usize) !void {
        if (cols == self.window_cols and rows == self.window_rows) return;
        self.window_cols = cols;
        self.window_rows = rows;
        _ = self.pane_layout_gen.fetchAdd(1, .monotonic);
        try self.layoutPanes(null, null);
    }

    /// Applies new cell pixel metrics to every context (see
    /// `Context.setCellMetrics`) -- like a resize, a font-size step is
    /// session-wide.
    pub fn setCellMetricsAll(self: *Session, cell_px_w: u32, cell_px_h: u32) void {
        var it = self.contexts.valueIterator();
        while (it.next()) |ctx| ctx.*.setCellMetrics(cell_px_w, cell_px_h);
    }

    fn dropFromStack(self: *Session, pane_handle: PaneHandle, handle: ContextHandle) void {
        const pane = self.panes.getPtr(pane_handle) orelse return;
        var i: usize = pane.stack.items.len;
        while (i > 0) {
            i -= 1;
            if (pane.stack.items[i] == handle) _ = pane.stack.orderedRemove(i);
        }
    }
};
