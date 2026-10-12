// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: MPL-2.0

//! A `Context`: one program's whole screen -- the root layer, the layers
//! created on top of it, their split tree, the images, metadata and icons
//! they reference, and its caret, pointer and clipboard state. The
//! `Session` (`session.zig`) owns every context and decides which one each
//! pane shows. The split tree that lays a context's layers out lives here
//! too, since only a `Context` walks it.

const std = @import("std");
const core = @import("core.zig");
const cell_paint = @import("cell_paint.zig");

const CellPos = core.CellPos;
const ConnId = core.ConnId;
const DragPayload = core.DragPayload;
const DragSpec = core.DragSpec;
const DropTarget = core.DropTarget;
const ImageEntry = core.ImageEntry;
const ImageFormat = core.ImageFormat;
const ImageHandle = core.ImageHandle;
const ImageInfo = core.ImageInfo;
const ImageResourceError = core.ImageResourceError;
const Layer = core.Layer;
const LayerError = core.LayerError;
const LayerHandle = core.LayerHandle;
const Metadata = core.Metadata;
const MetadataError = core.MetadataError;
const MetadataHandle = core.MetadataHandle;
const NinePatch = core.NinePatch;
const NinePatchError = core.NinePatchError;
const NinePatchHandle = core.NinePatchHandle;
const NinePatchStyle = core.NinePatchStyle;
const NinePatchUpdate = core.NinePatchUpdate;
const Outline = core.Outline;
const OutlineError = core.OutlineError;
const OutlineHandle = core.OutlineHandle;
const OutlineStyle = core.OutlineStyle;
const PaneHandle = core.PaneHandle;
const PointerState = core.PointerState;
const PropertyError = core.PropertyError;
const PropertyName = core.PropertyName;
const PropertyValue = core.PropertyValue;
const PxPos = core.PxPos;
const Rect = core.Rect;
const RectError = core.RectError;
const RectHandle = core.RectHandle;
const RectUpdate = core.RectUpdate;
const Table = core.Table;
const TableColumn = core.TableColumn;
const TableError = core.TableError;
const TableHandle = core.TableHandle;
const TableStyle = core.TableStyle;
const divider_style = core.divider_style;
const imageDimensions = core.imageDimensions;
const root_layer_handle = core.root_layer_handle;
const root_pane_handle = core.root_pane_handle;
const theme = core.theme;

// ─── Splits ─────────────────────────────────────────────────────────────
//
// A split tree is the host's answer to "where do the panes go". A client
// that wants a sidebar beside a buffer beside a statusline describes the
// arrangement once; the host computes every layer's bounds from it, keeps
// them correct across a window resize, and owns the divider drag. See
// decisions.md's Layer section for why this lives server-side rather than
// each TUI re-implementing pane math.
//
// The tree lays out over the whole context. The **root layer is never a
// split child** -- it is the shell's scrollback, drawn underneath at a
// fixed origin, and a full-screen program's panes simply cover it (the
// alt-screen story, without needing `create_context`).

pub const SplitHandle = u32;

pub const SplitError = error{
    UnknownSplit,
    /// A split named itself, directly or through a cycle, and the layout
    /// walk hit `max_split_depth`.
    SplitTooDeep,
    /// `replace_split_child` named a slot past the end of the split's
    /// child list.
    SplitChildOutOfRange,
};

/// Which way a split's children run.
pub const SplitAxis = enum {
    /// Left to right, separated by vertical dividers.
    row,
    /// Top to bottom, separated by horizontal dividers.
    column,
};

/// A rectangle in grid cells.
pub const CellRect = struct {
    row: usize = 0,
    col: usize = 0,
    cols: usize = 0,
    rows: usize = 0,

    pub fn contains(self: CellRect, row: usize, col: usize) bool {
        return row >= self.row and row < self.row + self.rows and
            col >= self.col and col < self.col + self.cols;
    }
};

/// One child of a split: what to place, and how big it is along the
/// parent's axis.
pub const SplitChild = struct {
    target: Target,
    size: Size = .{ .weight = 1 },

    pub const Target = union(enum) { layer: LayerHandle, split: SplitHandle };

    /// `fixed` children are measured first and `weight` children share
    /// what's left. That's what lets a one-row statusline sit beside a
    /// pane that takes "the rest" without the client recomputing a
    /// fraction every time the window changes height.
    pub const Size = union(enum) { weight: f32, fixed: usize };
};

pub const Split = struct {
    axis: SplitAxis,
    children: std.ArrayList(SplitChild) = .empty,
    /// Whether the user may drag the bands between this split's children.
    /// When false the split reserves no `divider_cells` gap between its
    /// children (the row/column returns to content), emits no
    /// `DividerRect` for glyphwire-host to draw or hit-test, and
    /// `moveDivider` is a no-op. What a TUI wants for a structural split
    /// like an editor's buffer-area-over-command-line: the command line
    /// is a fixed one-row child and a resize handle there is just a
    /// wasted row.
    resizable: bool = true,
    /// The cell rect this split occupied at the last `layoutSplits`.
    /// `moveDivider` needs it to turn a drag in cells back into sizes,
    /// and there is nowhere else to get it: a split has no size of its
    /// own until the tree is laid out.
    last_rect: CellRect = .{},
    laid_out: bool = false,

    pub fn deinit(self: *Split, alloc: std.mem.Allocator) void {
        self.children.deinit(alloc);
    }
};

/// One layer's laid-out bounds, as carried by a `layout` notification.
pub const LayerBounds = struct {
    layer: LayerHandle,
    row: usize,
    col: usize,
    cols: usize,
    rows: usize,
};

/// A draggable band between two children of a split.
pub const DividerRect = struct {
    split: SplitHandle,
    /// The divider *after* child `index`, so `index` and `index + 1` are
    /// the pair it separates and `index` is always a valid child.
    index: usize,
    axis: SplitAxis,
    rect: CellRect,
};

/// Recursion cap for the layout walk. A tree this deep is a bug or a
/// cycle; either way the walk stops rather than smashing the stack.
pub const max_split_depth: usize = 16;

/// Smallest extent a divider drag will leave a pane, in cells. Below
/// this a pane can't show anything and can't be grabbed back.
pub const min_pane_cells: usize = 1;

/// Typematic key-repeat timing a program asks the host for, in ms:
/// `delay_ms` is how long one of its keys must be held before it starts
/// repeating, `interval_ms` how often it repeats after that. Equal
/// values mean "no distinct initial hold" -- the first repeat lands one
/// interval after the press, which is what a modal editor wants and what
/// a shell (where an over-eager repeat re-runs a command) does not. The
/// host clamps both into its own range; see `host/key_repeat.zig`.
pub const KeyRepeat = struct {
    delay_ms: f64 = default_delay_ms,
    interval_ms: f64 = default_interval_ms,

    /// The timing a session runs at when nobody has asked for anything
    /// else -- typical OS keyboard-repeat values. `host.conf.lua` can move
    /// the host's own default off these, but a `set_key_repeat` that
    /// names only one of the two fields fills the other from here, not
    /// from the user's `host.conf.lua`: the protocol's default is the one
    /// both ends can agree on without asking.
    pub const default_delay_ms: f64 = 500;
    pub const default_interval_ms: f64 = 40;
};

/// The shape glyphwire-host draws a context's caret in, set with
/// `set_caret_shape`. The same four names `host.conf.lua`'s
/// `cursor_shape` takes; `line` is a thin bar at the cell's left edge
/// (nvim's insert cursor) and `block` fills the cell.
pub const CaretShape = enum { line, block, box, underline };

pub const Context = struct {
    alloc: std.mem.Allocator,
    root: Layer,
    /// Layers created via `create_layer`, keyed by handle -- the root
    /// layer isn't in here (it's always addressed as `root_layer_handle`
    /// and always exists; see that constant's doc comment). Every layer
    /// here is parented to the root: decisions.md's Layer tree allows
    /// deeper nesting, but nothing creates or needs a non-root parent yet,
    /// so that generality isn't built.
    layers: std.AutoHashMap(LayerHandle, Layer),
    /// Creation order of `layers`' entries, for compositing -- a later-
    /// created layer draws on top of an earlier one, and the root layer is
    /// always underneath all of them. Kept separate from `layers` itself
    /// since `AutoHashMap` iteration order is unspecified, not something
    /// a renderer should draw in.
    layer_order: std.ArrayList(LayerHandle) = .empty,
    next_layer_handle: LayerHandle = 1,
    /// Split containers, keyed by handle -- the pane tree (see the Splits
    /// section above). Empty, and `root_split` null, for every client
    /// that positions its layers by hand, which is all of them until one
    /// asks for a tree.
    splits: std.AutoHashMap(SplitHandle, Split),
    next_split_handle: SplitHandle = 1,
    /// The split that fills the context, if any. Null means no split
    /// layout at all: layers stay wherever `position` / `cell_position`
    /// put them.
    root_split: ?SplitHandle = null,
    /// Cells of gap between two children of a split -- the band a mouse
    /// grabs to resize them. One cell is wide enough to hit and cheap to
    /// draw.
    divider_cells: usize = 1,
    /// Whether glyphwire-host draws its always-on right-edge scrollbar
    /// (the root layer's scrollback view) for this context. On for the
    /// shell and every terminal-style client; a pure-TUI context like
    /// zoe -- whose root has no scrollback and whose panes carry their
    /// own `scrollbars` -- turns it off (`create_context`'s
    /// `window_scrollbar`, or the `set_window_scrollbar` notification) so
    /// the window doesn't show a permanently full, inert bar.
    window_scrollbar: bool = true,
    /// Which `create_layer` layer glyphwire-host draws its blinking caret
    /// for, instead of the root layer's live cursor. Null (the default)
    /// means the root cursor, which is what every terminal-style client
    /// and zoe want. A multi-pane client like `gmux`, whose focused pane
    /// is a non-root layer fed by that pane's PTY, points this at the
    /// focused pane and moves it on a focus switch -- the host then
    /// positions the caret through that layer's pane bounds, viewport and
    /// scroll offset. Set with the `set_caret_layer` notification; an
    /// unknown or destroyed handle falls back to the root cursor rather
    /// than showing nothing.
    caret_layer: ?LayerHandle = null,
    /// Whether glyphwire-host draws a caret for this context at all, set
    /// with `set_caret_visible`. A program with no text insertion point
    /// (`gw-read`, a viewer) turns it off once rather than parking the
    /// cursor somewhere out of sight. Distinct from a layer's DECTCEM
    /// `cursor_visible`, which a PTY program drives and `ESC [ ! p`
    /// resets; this one only changes on the wire message, and hides the
    /// caret whichever layer `caret_layer` points it at.
    caret_visible: bool = true,
    /// The shape the host draws the caret in, set with `set_caret_shape`,
    /// or null for the shape `host.conf.lua` chose. A modal editor
    /// switches it as the mode changes (a bar for insert), and puts it
    /// back to null when it hands the caret to something else.
    caret_shape: ?CaretShape = null,
    /// The typematic key-repeat timing this context's program asked for
    /// with `set_key_repeat`, or null to run at the host's own default
    /// (`host.conf.lua`'s `key_repeat_delay_ms` / `key_repeat_interval_ms`).
    /// Only the *focused* context's value is in effect -- the host reads
    /// it each tick and retimes the engine's repeat clock, so switching
    /// panes between the shell and zoe switches cadence with it.
    key_repeat: ?KeyRepeat = null,
    /// Bumped by every `set_key_repeat`, including one that sets the
    /// same numbers again. A program retimes when the meaning of its
    /// keys has changed, so the host treats each arrival as a boundary
    /// and stops whatever is held from repeating across it (see
    /// `host/input.zig`'s `syncRepeatTiming`) -- which is a thing that
    /// has to happen even when the cadence itself is unchanged.
    key_repeat_gen: u64 = 0,
    /// Bumped whenever the split tree or the context size changes, i.e.
    /// whenever a previously computed layout (and its divider rects) went
    /// stale. glyphwire-host caches the divider geometry it hit-tests
    /// against and recomputes only when this moves.
    layout_gen: u64 = 0,
    /// Last pointer position reported against this context -- see
    /// `PointerState`. The key/button down-sets are the session's
    /// (`Session.input`).
    pointer: PointerState = .{},
    images: std.AutoHashMap(ImageHandle, ImageEntry),
    next_image_handle: ImageHandle = 1,
    /// Sum of every stored `ImageEntry.bytes.len` in this context. What
    /// the scrollback sweep's budget check reads, so deciding whether to
    /// sweep never walks the `images` map.
    image_bytes: usize = 0,
    /// Bumped by `destroyImage` / `updateImage` / `sweepImages` -- i.e.
    /// whenever an image handle's bytes changed identity or stopped
    /// resolving. glyphwire-host caches decoded GPU textures by handle
    /// and holds pointers to them inside already-built quad batches;
    /// neither is invalidated by a cell change, so `render_gen` can't
    /// tell it. It watches **the root context's** counter: `Session`
    /// sweeps every context at once and bumps the root's whenever
    /// anything anywhere was freed, so one number covers the session.
    image_gen: u64 = 0,
    /// Name -> image handle, for `draw_icon` (decisions.md's Icon
    /// section). Populated by whoever loads the bundled icon files
    /// (`glyphwire-host`, scanning `assets/icons/` -- see `iconName`) --
    /// empty until then, same as `images` before any `load_image` call.
    icons: std.StringHashMap(ImageHandle),
    /// Name -> nine-patch, for `create_nine_patch`. Seeded by
    /// glyphwire-host from `assets/ninepatch/` (and the user's
    /// `~/.config/glyphwire/ninepatch/`), exactly the way `icons` is from
    /// `assets/icons/`; a `create_context` context resolves it through
    /// `asset_fallback`.
    nine_patch_styles: std.StringHashMap(NinePatchStyle),
    metadata: std.AutoHashMap(MetadataHandle, Metadata),
    next_metadata_handle: MetadataHandle = 1,
    /// The session's fixed cell pixel metrics -- decisions.md's "one
    /// monospace font + size per session" -- needed to translate a
    /// `draw_image` span into per-cell pixel offsets (see
    /// `Layer.drawImage`). Defaults match glyphwire-host's current
    /// JetBrainsMono tuning (`host/main.zig`'s `cell_w`/`cell_h`); a host
    /// with different metrics should overwrite these right after `init`.
    cell_px_w: u32 = 12,
    cell_px_h: u32 = 12,
    /// Shared across every layer's `tables` map -- see `TableHandle`'s
    /// doc comment.
    next_table_handle: TableHandle = 1,
    /// Shared across every layer's `rects` map, same reasoning as
    /// `next_table_handle`.
    next_rect_handle: RectHandle = 1,
    /// Shared across every layer's `nine_patches` map, same reasoning as
    /// `next_table_handle`.
    next_nine_patch_handle: NinePatchHandle = 1,
    /// Shared across every layer's `outlines` map, same reasoning as
    /// `next_table_handle`.
    next_outline_handle: OutlineHandle = 1,
    /// Session clipboard buffer. The wire's `set_clipboard` /
    /// `get_clipboard` read and write this directly; the headless case
    /// (`server/main.zig`, tests) has nothing else behind it. glyphwire-
    /// host treats it as the source of truth and mirrors it to the OS
    /// clipboard whenever `clipboard_serial` changes (a `set_clipboard`
    /// from a client, or its own selection copy) and refreshes it from
    /// the OS on paste. See decisions.md's Selection & Clipboard section.
    clipboard: std.ArrayList(u8) = .empty,
    /// Bumped by every `setClipboard`; glyphwire-host compares it against
    /// the serial it last pushed to the OS to know when to push again,
    /// without diffing the bytes every frame.
    clipboard_serial: u64 = 0,
    /// The drag a client asked to start with `start_drag`, waiting for
    /// glyphwire-host to pick it up (`takeDragRequest`) on its main
    /// thread, where the OS drag has to begin. A newer request replaces
    /// an untaken one. Headless, nothing ever takes it.
    drag_request: ?DragPayload = null,
    /// The connections that own this context, for lifecycle culling --
    /// the exact mirror of `Layer.owners` / `connection_owned`, one level
    /// up. Populated only for a context created over a socket via
    /// `create_context`: `Session.createContext` leaves it empty and
    /// `connection_owned` false, and the dispatcher then calls
    /// `Session.addContextOwner` with the creating connection's id.
    /// `adopt_context` adds more. When the set drains to empty because
    /// every owning connection disconnected, the context is destroyed
    /// and, if it was visible, the session falls back to the
    /// previously-visible one -- the alt-screen auto-restore,
    /// generalised (see `Session`). Never populated for the root
    /// context, which has no lifecycle.
    owners: std.AutoHashMap(ConnId, void),
    connection_owned: bool = false,
    /// A read-only asset source consulted when this context's own
    /// `icons` / `images` don't have a name/handle -- set by
    /// `Session.createContext` to the session's root context, so a
    /// full-screen program's own context resolves the same `draw_icon`
    /// names the host populated on the shell's context without every
    /// context re-loading (or copying) the bundled icon bytes. Null for
    /// the root context itself and for any standalone `Context` (tests,
    /// `server/main.zig` before a `Session` wraps it).
    asset_fallback: ?*Context = null,
    /// Which window pane displays this context. Fixed for the context's
    /// whole life: a context is created *into* a pane and never moves
    /// between them (a program that wants to appear elsewhere creates a
    /// new context there). `root_pane_handle` for the root context and for
    /// any standalone `Context` with no `Session` over it.
    pane: PaneHandle = root_pane_handle,
    /// This context's top-left cell within the window, mirrored from its
    /// pane's rect by `Session.layoutPanes`.
    ///
    /// Everything *inside* a context -- layer positions, the split tree,
    /// `get_cells` coordinates, the cell a mouse event reports to a client
    /// -- stays relative to the context, so a program never has to know
    /// where its pane sits. Only glyphwire-host adds this, once, when it
    /// composites, and `Server` subtracts it once when it translates a
    /// mouse event inbound. Both zero for a single-pane session, which is
    /// why every existing client is unaffected by panes existing at all.
    origin_row: usize = 0,
    origin_col: usize = 0,
    /// A short human name for what this context is showing ("zoe
    /// main.zig", "salacommander"), set by `create_context`'s `title` or
    /// `set_context_title`. Empty until a program names itself. Only
    /// read for display: glyphwire-host's context switcher lists it, and
    /// `list_contexts` hands it to a shell's `jobs`. Capped at
    /// `max_title_len` bytes, cut on a UTF-8 boundary.
    title: std.ArrayList(u8) = .empty,
    /// The theme every `Color` reference this context's cells hold is
    /// resolved against (see `theme`). A copy of the session's theme until
    /// the program sets its own with `set_theme` (`theme_own`); a session
    /// theme change then passes this context by.
    theme: theme.Stored,
    theme_own: bool = false,
    /// Bumped on every change to `theme`, so glyphwire-host rebuilds the
    /// layer batches it resolved against the old one.
    theme_gen: u64 = 0,
    /// How glyphwire-host draws this context's own split bands (see
    /// `divider_style`). Inherits the host's `pane_divider_style` until
    /// the program sends `set_divider_style`. Never touches the bands
    /// *between* panes: those belong to no program.
    divider_style: divider_style.Override = .{},
    /// Bumped on every `set_divider_style`, so glyphwire-host repaints.
    divider_style_gen: u64 = 0,

    pub const max_title_len = 128;

    pub fn init(alloc: std.mem.Allocator, width: usize, height: usize, scrollback_rows: usize) !Context {
        return .{
            .alloc = alloc,
            .theme = .init(theme.initDefault()),
            .root = try Layer.init(alloc, width, height, scrollback_rows),
            .layers = std.AutoHashMap(LayerHandle, Layer).init(alloc),
            .splits = std.AutoHashMap(SplitHandle, Split).init(alloc),
            .images = std.AutoHashMap(ImageHandle, ImageEntry).init(alloc),
            .icons = std.StringHashMap(ImageHandle).init(alloc),
            .nine_patch_styles = std.StringHashMap(NinePatchStyle).init(alloc),
            .metadata = std.AutoHashMap(MetadataHandle, Metadata).init(alloc),
            .owners = std.AutoHashMap(ConnId, void).init(alloc),
        };
    }

    pub fn deinit(self: *Context) void {
        self.owners.deinit();
        self.root.deinit();
        var layer_it = self.layers.valueIterator();
        while (layer_it.next()) |l| l.deinit();
        self.layers.deinit();
        self.layer_order.deinit(self.alloc);
        var split_it = self.splits.valueIterator();
        while (split_it.next()) |sp| sp.deinit(self.alloc);
        self.splits.deinit();
        var it = self.images.valueIterator();
        while (it.next()) |entry| self.alloc.free(entry.bytes);
        self.images.deinit();
        var icon_it = self.icons.keyIterator();
        while (icon_it.next()) |k| self.alloc.free(k.*);
        self.icons.deinit();
        var np_it = self.nine_patch_styles.keyIterator();
        while (np_it.next()) |k| self.alloc.free(k.*);
        self.nine_patch_styles.deinit();
        var metadata_it = self.metadata.valueIterator();
        while (metadata_it.next()) |m| {
            self.alloc.free(m.json);
            if (m.drag) |*d| d.deinit(self.alloc);
        }
        self.metadata.deinit();
        if (self.drag_request) |*d| d.deinit(self.alloc);
        self.clipboard.deinit(self.alloc);
        self.title.deinit(self.alloc);
    }

    /// `set_theme`: this context's own theme from now on, whatever the
    /// session's becomes.
    pub fn setOwnTheme(self: *Context, t: theme.Theme) void {
        self.theme.set(t);
        self.theme_own = true;
        self.theme_gen +%= 1;
    }

    /// `set_theme` with no theme: back to following the session's.
    pub fn followTheme(self: *Context, session_theme: *const theme.Stored) void {
        self.theme = session_theme.*;
        self.theme_own = false;
        self.theme_gen +%= 1;
    }

    /// `set_divider_style`: replaces this context's override wholesale.
    /// An empty one (`.{}`) goes back to the host's style.
    pub fn setDividerStyle(self: *Context, style: divider_style.Override) void {
        self.divider_style = style;
        self.divider_style_gen +%= 1;
    }

    /// `set_context_title`: replaces the title (see `title`), truncated to
    /// `max_title_len` bytes without splitting a UTF-8 sequence.
    pub fn setTitle(self: *Context, text: []const u8) !void {
        var len = @min(text.len, max_title_len);
        // Back off any continuation bytes so the cut lands on a codepoint
        // start; a title is only ever drawn, and half a character draws as
        // a replacement glyph.
        if (len < text.len) {
            while (len > 0 and (text[len] & 0xC0) == 0x80) len -= 1;
        }
        self.title.clearRetainingCapacity();
        try self.title.appendSlice(self.alloc, text[0..len]);
    }

    /// `set_clipboard`: replaces the clipboard buffer with `text` (copied
    /// in) and bumps `clipboard_serial`.
    pub fn setClipboard(self: *Context, text: []const u8) !void {
        self.clipboard.clearRetainingCapacity();
        try self.clipboard.appendSlice(self.alloc, text);
        self.clipboard_serial +%= 1;
    }

    /// `get_clipboard`: the current clipboard buffer, borrowed (valid
    /// until the next `setClipboard`). On glyphwire-host this is only as
    /// fresh as the last host->OS / OS->host sync -- see `clipboard`.
    pub fn clipboardText(self: *const Context) []const u8 {
        return self.clipboard.items;
    }

    /// `create_metadata`: stores `json` verbatim (duped -- the caller's
    /// copy, e.g. a just-parsed request buffer, isn't guaranteed to
    /// outlive this) and returns a fresh handle. No cleanup happens here
    /// or anywhere else yet -- `destroy_metadata` is explicit-only for
    /// now, and a real garbage collector (scrollback eviction and
    /// possibly other scenarios freeing ids no cell references any more)
    /// is future work, not needed for this to be useful today.
    pub fn createMetadata(self: *Context, json: []const u8) !MetadataHandle {
        return self.createMetadataDrag(json, null);
    }

    /// `create_metadata` with its optional `drag`: a span tagged with the
    /// returned id is draggable out of the window (glyphwire-host's
    /// Alt+drag) carrying `drag`'s URIs. `drag` is copied; an empty URI
    /// list is `DragError.EmptyDrag`.
    pub fn createMetadataDrag(self: *Context, json: []const u8, drag: ?DragSpec) !MetadataHandle {
        const owned = try self.alloc.dupe(u8, json);
        errdefer self.alloc.free(owned);
        var payload: ?DragPayload = if (drag) |d| try DragPayload.init(self.alloc, d) else null;
        errdefer if (payload) |*p| p.deinit(self.alloc);

        const handle = self.next_metadata_handle;
        self.next_metadata_handle += 1;
        try self.metadata.put(handle, .{ .json = owned, .drag = payload });
        return handle;
    }

    /// `destroy_metadata`: frees `id`'s stored JSON. Errors on an unknown
    /// id, same as `destroyLayer` -- there's no reference counting, so a
    /// cell can still be tagged with `id` afterward; `getMetadataAt`
    /// resolves that gracefully (reports the id, `metadata: null`) rather
    /// than erroring, since a dangling tag is an expected, not
    /// exceptional, state once destruction is explicit.
    pub fn destroyMetadata(self: *Context, id: MetadataHandle) MetadataError!void {
        var removed = self.metadata.fetchRemove(id) orelse return MetadataError.UnknownMetadata;
        self.alloc.free(removed.value.json);
        if (removed.value.drag) |*d| d.deinit(self.alloc);
    }

    /// `id`'s stored JSON, or null if it was never created or has since
    /// been destroyed (see `destroyMetadata`'s doc comment on why that's
    /// not an error here).
    pub fn metadataJson(self: *const Context, id: MetadataHandle) ?[]const u8 {
        return if (self.metadata.get(id)) |m| m.json else null;
    }

    /// `id`'s drag payload, borrowed, or null when the id is gone or its
    /// span isn't draggable.
    pub fn metadataDrag(self: *const Context, id: MetadataHandle) ?DragSpec {
        const m = self.metadata.getPtr(id) orelse return null;
        if (m.drag) |*d| return d.view();
        return null;
    }

    /// What an Alt+drag starting on a span tagged `id` on `layer` carries,
    /// owned by `alloc`: when `id` is highlighted, every highlighted
    /// span's URIs in listing order (gw-shell's marked set, the same one
    /// Ctrl+Shift+C copies as paths), else `id`'s own payload. Null when
    /// `id` carries no drag; a highlighted id without one adds nothing.
    pub fn dragForPress(self: *const Context, alloc: std.mem.Allocator, layer: *const Layer, id: MetadataHandle) !?DragPayload {
        const own = self.metadataDrag(id) orelse return null;
        if (!layer.sel.isHighlighted(id)) return try DragPayload.init(alloc, own);

        // Ids are handed out in creation order, which for a listing is the
        // order it was drawn in.
        const ids = try alloc.dupe(MetadataHandle, layer.sel.highlighted_ids.items);
        defer alloc.free(ids);
        std.mem.sort(MetadataHandle, ids, {}, std.sort.asc(MetadataHandle));

        var uris: std.ArrayList([]const u8) = .empty;
        defer uris.deinit(alloc);
        for (ids) |h| {
            if (self.metadataDrag(h)) |d| try uris.appendSlice(alloc, d.uris);
        }
        if (uris.items.len <= own.uris.len) return try DragPayload.init(alloc, own);

        var label_buf: [32]u8 = undefined;
        const label = try std.fmt.bufPrint(&label_buf, "{d} files", .{uris.items.len});
        return try DragPayload.init(alloc, .{ .uris = uris.items, .label = label, .icon = own.icon });
    }

    /// `start_drag`: queues `drag` (copied) for glyphwire-host, replacing
    /// any request it hasn't taken yet.
    pub fn requestDrag(self: *Context, drag: DragSpec) !void {
        const payload = try DragPayload.init(self.alloc, drag);
        if (self.drag_request) |*old| old.deinit(self.alloc);
        self.drag_request = payload;
    }

    /// Hands the pending `start_drag` over; the caller owns it now (free
    /// with `DragPayload.deinit` and this context's allocator).
    pub fn takeDragRequest(self: *Context) ?DragPayload {
        const d = self.drag_request orelse return null;
        self.drag_request = null;
        return d;
    }

    /// `create_layer`: allocates a fresh layer parented to the root,
    /// defaulting to the context's base size (the root layer's own
    /// width/height) when `width`/`height` is omitted -- decisions.md's
    /// Layer section. Returns its handle. A layer created with *both*
    /// dimensions omitted tracks the context's base size on a later
    /// window resize (`Layer.tracks_context_size` / `Context.resize`);
    /// one created with an explicit size keeps that size.
    pub fn createLayer(self: *Context, width: ?usize, height: ?usize, scrollback_rows: usize) !LayerHandle {
        var layer = try Layer.init(self.alloc, width orelse self.root.width, height orelse self.root.height, scrollback_rows);
        layer.tracks_context_size = (width == null and height == null);
        errdefer layer.deinit();

        const handle = self.next_layer_handle;
        try self.layer_order.append(self.alloc, handle);
        errdefer _ = self.layer_order.pop();

        try self.layers.put(handle, layer);
        self.next_layer_handle += 1;
        return handle;
    }

    /// `destroy_layer`: frees a previously created layer and drops it from
    /// the compositing order. The root layer isn't in `layers` at all
    /// (see `root_layer_handle`'s doc comment), so a handle of 0 reports
    /// `UnknownLayer` here the same as any other bogus handle -- there's
    /// no wire path that destroys the root.
    pub fn destroyLayer(self: *Context, handle: LayerHandle) LayerError!void {
        var removed = self.layers.fetchRemove(handle) orelse return LayerError.UnknownLayer;
        removed.value.deinit();
        for (self.layer_order.items, 0..) |h, i| {
            if (h == handle) {
                _ = self.layer_order.orderedRemove(i);
                break;
            }
        }
        // The host would fall back to the root cursor on its own, but drop
        // the dangling handle so a reused number can't later resolve to an
        // unrelated layer.
        if (self.caret_layer == handle) self.caret_layer = null;
    }

    /// Records `conn` as an owner of `handle` (see `ConnId`). Called by
    /// the dispatcher for the connection that issued `create_layer`, and
    /// again for each connection that later issues `adopt_layer`. Marks
    /// the layer `connection_owned` so a later drain to zero owners culls
    /// it rather than leaving it (see `removeConnectionOwnership`). Adding
    /// an id already present is a no-op. Errors `UnknownLayer` for an
    /// unknown or root handle -- the root layer has no lifecycle.
    pub fn addLayerOwner(self: *Context, handle: LayerHandle, conn: ConnId) !void {
        if (handle == root_layer_handle) return LayerError.UnknownLayer;
        const layer = self.layers.getPtr(handle) orelse return LayerError.UnknownLayer;
        try layer.owners.put(conn, {});
        layer.connection_owned = true;
    }

    /// Whether `conn` owns `handle` -- the check `destroy_layer` makes
    /// before honoring a request from a socket connection. False for the
    /// root handle and for any unknown handle (neither is connection-owned).
    pub fn layerHasOwner(self: *Context, handle: LayerHandle, conn: ConnId) bool {
        if (handle == root_layer_handle) return false;
        const layer = self.layers.getPtr(handle) orelse return false;
        return layer.owners.contains(conn);
    }

    /// Drops `conn` from every connection-owned layer's owner set; any
    /// layer left with no owners is destroyed and its handle appended to
    /// `culled` (caller-owned, expected empty on entry -- server.zig logs
    /// the entries). Called from `server.zig` when a connection closes,
    /// under `ctx_mutex`. Layers that were never connection-owned (created
    /// in-process) are skipped entirely. On an allocation failure while
    /// recording a culled handle this returns the error with the layer
    /// already destroyed but not reported -- an OOM path the host treats
    /// as fatal anyway.
    pub fn removeConnectionOwnership(self: *Context, conn: ConnId, culled: *std.ArrayList(LayerHandle)) !void {
        var it = self.layers.iterator();
        while (it.next()) |entry| {
            const layer = entry.value_ptr;
            if (!layer.connection_owned) continue;
            _ = layer.owners.remove(conn);
            if (layer.owners.count() == 0) try culled.append(self.alloc, entry.key_ptr.*);
        }
        // Destroy in a second pass: `destroyLayer` mutates `self.layers`,
        // which can't happen while the iterator above is live.
        for (culled.items) |h| self.destroyLayer(h) catch {};
    }

    /// Changes the context's base size -- the width/height a
    /// `create_layer` with no explicit dimensions inherits, and what
    /// `get_property(root, "size")` reports. Resizes the root layer plus
    /// every `create_layer` layer that was tracking the base size
    /// (`Layer.tracks_context_size`); layers created at an explicit size
    /// (notification popups, etc.) are left alone. Content in each
    /// resized layer is anchored to its bottom row -- see `Layer.resize`.
    ///
    /// Driven by the host when its window is resized
    /// (`Server.reportResize`); there is no wire message a client can use
    /// to set this. A no-op if the base size is unchanged. On an
    /// allocation failure partway through, the root may have resized
    /// while some tracking layers have not -- acceptable for an OOM path,
    /// which the host treats as fatal anyway.
    pub fn resize(self: *Context, width: usize, height: usize) !void {
        if (width == self.root.width and height == self.root.height) return;
        // Any previously computed split layout (and its divider rects) is
        // now stale -- see `layout_gen`.
        self.layout_gen +%= 1;
        try self.root.resize(width, height);
        var it = self.layers.valueIterator();
        while (it.next()) |layer| {
            if (layer.tracks_context_size) try layer.resize(width, height);
        }
    }

    /// Changes the session's cell pixel metrics -- what `get_cell_metrics`
    /// reports -- and re-derives the pixel `pos` of every layer that was
    /// placed in cells (`PropertyName.cell_position`). glyphwire-host
    /// calls this rather than assigning `cell_px_w`/`cell_px_h` directly
    /// so a font-size step (Ctrl+`+` / Ctrl+`-`) doesn't leave a
    /// cell-placed sidebar sitting half a cell off its column.
    pub fn setCellMetrics(self: *Context, cell_px_w: u32, cell_px_h: u32) void {
        if (cell_px_w == self.cell_px_w and cell_px_h == self.cell_px_h) return;
        self.cell_px_w = cell_px_w;
        self.cell_px_h = cell_px_h;
        var it = self.layers.valueIterator();
        while (it.next()) |layer| {
            const cell = layer.pos_cells orelse continue;
            layer.pos = self.pixelPosForCell(cell);
            layer.touchRender();
        }
    }

    /// The top-left pixel of grid cell `cell`, under the current metrics.
    fn pixelPosForCell(self: *const Context, cell: CellPos) PxPos {
        const w: usize = self.cell_px_w;
        const h: usize = self.cell_px_h;
        return .{
            .x = @floatFromInt(cell.col * w),
            .y = @floatFromInt(cell.row * h),
        };
    }

    /// `get_property` with the context in scope: everything `Layer`'s own
    /// `getProperty` answers, plus `cell_position`, which needs the
    /// session's cell metrics. `UnknownLayer` for a destroyed or
    /// never-created handle; `null`/`root_layer_handle` are the root, as
    /// everywhere else.
    pub fn getLayerProperty(self: *Context, handle: ?LayerHandle, name: PropertyName) LayerError!PropertyValue {
        const layer = self.layerPtr(handle) orelse return LayerError.UnknownLayer;
        if (name != .cell_position) return layer.getProperty(name);
        // A layer placed in cells reports back exactly what was set; one
        // placed in pixels reports the cell its top-left corner lands in,
        // so the getter always has an answer.
        if (layer.pos_cells) |cell| return .{ .cell_position = cell };
        const w: f32 = @floatFromInt(@max(self.cell_px_w, 1));
        const h: f32 = @floatFromInt(@max(self.cell_px_h, 1));
        return .{ .cell_position = .{
            .row = @intFromFloat(@max(layer.pos.y, 0) / h),
            .col = @intFromFloat(@max(layer.pos.x, 0) / w),
        } };
    }

    pub const SetPropertyError = LayerError || PropertyError || std.mem.Allocator.Error;

    /// `set_property` with the context in scope -- the single entry point
    /// the dispatcher uses. Owns the three things a `Layer` can't decide
    /// alone: which properties the root layer refuses (`size`,
    /// `visibility`, `opacity`), the cell-metric resolution `cell_position` needs,
    /// and the reallocation `size` performs. Everything else is forwarded
    /// to `Layer.setProperty`.
    pub fn setLayerProperty(self: *Context, handle: ?LayerHandle, value: PropertyValue) SetPropertyError!void {
        const is_root = (handle orelse root_layer_handle) == root_layer_handle;
        const layer = self.layerPtr(handle) orelse return LayerError.UnknownLayer;
        switch (value) {
            .size => |sz| {
                if (is_root) return PropertyError.ReadOnlyProperty;
                // A zero-width or zero-height grid has no representation
                // here (`Layer.init` needs at least one row to seat the
                // scroll region), so a degenerate request is clamped
                // rather than rejected -- same spirit as `scroll_view`
                // clamping an out-of-range offset.
                const cols = @max(sz.cols, 1);
                const rows = @max(sz.rows, 1);
                if (cols == layer.width and rows == layer.height) return;
                try layer.resize(cols, rows);
                // The client owns this layer's geometry from here on, so
                // a later window resize must not drag it around too.
                layer.tracks_context_size = false;
            },
            .visibility => |v| {
                if (is_root) return PropertyError.ReadOnlyProperty;
                layer.setProperty(.{ .visibility = v });
            },
            .opacity => |v| {
                if (is_root) return PropertyError.ReadOnlyProperty;
                layer.setProperty(.{ .opacity = v });
            },
            .cell_position => |cell| {
                layer.pos = self.pixelPosForCell(cell);
                layer.pos_cells = cell;
                layer.touchRender();
            },
            .revision, .scroll => return PropertyError.ReadOnlyProperty,
            .content_extent => {
                if (layer.scroll_mode != .client) return PropertyError.WrongScrollMode;
                layer.setProperty(value);
            },
            .cursor, .position, .viewport, .scroll_offset, .scrollbars, .scroll_mode, .background, .pty_mode, .mouse_select, .mouse_report, .shadow, .selection_flow, .resize_edge => layer.setProperty(value),
        }
    }

    /// `set_caret_layer`: points glyphwire-host's caret at a
    /// `create_layer` layer (see `Context.caret_layer`) instead of the
    /// root cursor. `null` restores the root cursor. A handle that
    /// doesn't resolve to a live non-root layer reports `UnknownLayer`
    /// and leaves the current setting untouched -- a client clears it
    /// with `null`, not with a stale handle.
    pub fn setCaretLayer(self: *Context, handle: ?LayerHandle) LayerError!void {
        if (handle) |h| {
            if (h == root_layer_handle or self.layers.getPtr(h) == null) return LayerError.UnknownLayer;
        }
        self.caret_layer = handle;
    }

    /// `raise_layer`: moves `handle` up the compositing order
    /// (`layer_order` -- later entries draw on top). With `above` given it
    /// lands directly above that layer; omitted, it goes to the very top.
    /// The root layer is never in `layer_order` (it is always the bottom
    /// of the stack), so naming it as either handle reports
    /// `UnknownLayer`, same as `destroy_layer`.
    pub fn raiseLayer(self: *Context, handle: LayerHandle, above: ?LayerHandle) LayerError!void {
        return self.reorderLayer(handle, above, .above);
    }

    /// `lower_layer`: the mirror of `raiseLayer` -- directly below
    /// `below`, or all the way to the bottom of the stack when omitted.
    pub fn lowerLayer(self: *Context, handle: LayerHandle, below: ?LayerHandle) LayerError!void {
        return self.reorderLayer(handle, below, .below);
    }

    /// Compositing order only: nothing about a layer's cached quad batch
    /// depends on where it sits in the stack (glyphwire-host walks
    /// `layer_order` live each frame), so no `touchRender` here.
    fn reorderLayer(
        self: *Context,
        handle: LayerHandle,
        ref: ?LayerHandle,
        dir: enum { above, below },
    ) LayerError!void {
        // "Above itself" is a no-op, not an error -- and taking it early
        // keeps the removal below from hiding the reference handle.
        if (ref) |r| if (r == handle) return;

        const from = self.layerOrderIndex(handle) orelse return LayerError.UnknownLayer;
        _ = self.layer_order.orderedRemove(from);

        const target: usize = if (ref) |r| blk: {
            const ri = self.layerOrderIndex(r) orelse {
                // Put it back before reporting: a bad reference handle
                // shouldn't silently restack the layer it named.
                self.layer_order.insertAssumeCapacity(from, handle);
                return LayerError.UnknownLayer;
            };
            break :blk if (dir == .above) ri + 1 else ri;
        } else switch (dir) {
            .above => self.layer_order.items.len,
            .below => 0,
        };
        // The list just lost an element, so it has room for this one.
        self.layer_order.insertAssumeCapacity(target, handle);
    }

    fn layerOrderIndex(self: *const Context, handle: LayerHandle) ?usize {
        for (self.layer_order.items, 0..) |h, i| {
            if (h == handle) return i;
        }
        return null;
    }

    // ── Splits ──────────────────────────────────────────────────────────

    /// `create_split`: an empty container. It draws nothing and lays out
    /// nothing until it is given children and reached from `root_split`.
    pub fn createSplit(self: *Context, axis: SplitAxis) !SplitHandle {
        const handle = self.next_split_handle;
        try self.splits.put(handle, .{ .axis = axis });
        self.next_split_handle += 1;
        self.layout_gen +%= 1;
        return handle;
    }

    /// `destroy_split`: frees the container. Its children are *not*
    /// destroyed -- a layer outlives the pane it was sitting in, and a
    /// nested split is a separate handle its creator may still want. A
    /// destroyed `root_split` clears the root, dropping the whole layout
    /// back to hand-positioned layers.
    pub fn destroySplit(self: *Context, handle: SplitHandle) SplitError!void {
        var removed = self.splits.fetchRemove(handle) orelse return SplitError.UnknownSplit;
        removed.value.deinit(self.alloc);
        if (self.root_split == handle) self.root_split = null;
        self.layout_gen +%= 1;
    }

    /// `set_split_children`: replaces the child list wholesale. One
    /// message rather than insert/remove/reorder, because a client
    /// rebuilding a pane arrangement always knows the whole new list and
    /// the incremental forms would each need their own index semantics.
    pub fn setSplitChildren(self: *Context, handle: SplitHandle, children: []const SplitChild) !void {
        const split = self.splits.getPtr(handle) orelse return SplitError.UnknownSplit;
        split.children.clearRetainingCapacity();
        try split.children.appendSlice(self.alloc, children);
        self.layout_gen +%= 1;
    }

    /// `replace_split_child`: puts `target` in slot `index` of the
    /// split's child list, keeping that slot's size unless `size` says
    /// otherwise. What a client splitting or closing one pane sends
    /// instead of re-sending the parent's whole list, which would reset
    /// every proportion the user dragged it to: the slot's weight (or
    /// fixed cells) is the user's, not the client's.
    pub fn replaceSplitChild(
        self: *Context,
        handle: SplitHandle,
        index: usize,
        target: SplitChild.Target,
        size: ?SplitChild.Size,
    ) SplitError!void {
        const split = self.splits.getPtr(handle) orelse return SplitError.UnknownSplit;
        if (index >= split.children.items.len) return SplitError.SplitChildOutOfRange;
        const slot = &split.children.items[index];
        slot.target = target;
        if (size) |sz| slot.size = sz;
        self.layout_gen +%= 1;
    }

    /// Each child's extent along the split's axis, in cells, as of the
    /// last `layoutSplits` -- what `get_split` reports next to the sizes
    /// it was declared with. All zero for a split that has never been
    /// laid out (not yet reached from the root), since it has no size of
    /// its own until then.
    ///
    /// `out.len` must equal the child count.
    pub fn splitExtents(self: *const Context, split: *const Split, out: []usize) void {
        if (!split.laid_out) {
            @memset(out, 0);
            return;
        }
        self.childExtents(split, split.last_rect, out);
    }

    /// `set_root_split`: which split fills the context. Null tears the
    /// layout down without destroying anything.
    pub fn setRootSplit(self: *Context, handle: ?SplitHandle) SplitError!void {
        if (handle) |h| {
            if (!self.splits.contains(h)) return SplitError.UnknownSplit;
        }
        self.root_split = handle;
        self.layout_gen +%= 1;
    }

    /// Recomputes every layer's position and viewport from the split
    /// tree. Both outputs are optional: pass `changed` to collect the
    /// layers whose bounds actually moved (what a `layout` notification
    /// carries), and `dividers` to collect the draggable bands (what the
    /// host hit-tests and draws).
    ///
    /// Idempotent, and cheap enough to re-run for the divider geometry
    /// alone -- a re-run with unchanged inputs appends nothing to
    /// `changed`. A no-op when there is no root split.
    ///
    /// "Unchanged" means *since the last pass that collected*, not since
    /// the last pass at all: a run with `changed == null` applies the new
    /// rects but leaves them owed, so the next collecting run still
    /// reports them. That is what lets `Session.republish` re-walk every
    /// on-screen tree after a pane change without swallowing the `layout`
    /// notification a window resize is about to need. See
    /// `Layer.reported_bounds`.
    pub fn layoutSplits(
        self: *Context,
        changed: ?*std.ArrayList(LayerBounds),
        dividers: ?*std.ArrayList(DividerRect),
    ) !void {
        const root = self.root_split orelse return;
        try self.layoutSplit(root, .{
            .row = 0,
            .col = 0,
            .cols = self.root.width,
            .rows = self.root.height,
        }, changed, dividers, 0);
    }

    fn layoutSplit(
        self: *Context,
        handle: SplitHandle,
        rect: CellRect,
        changed: ?*std.ArrayList(LayerBounds),
        dividers: ?*std.ArrayList(DividerRect),
        depth: usize,
    ) !void {
        // A cycle or a pathologically deep tree stops here rather than
        // running off the stack -- see `max_split_depth`.
        if (depth >= max_split_depth) return;
        const split = self.splits.getPtr(handle) orelse return;
        split.last_rect = rect;
        split.laid_out = true;

        const n = split.children.items.len;
        if (n == 0) return;

        const extents = try self.alloc.alloc(usize, n);
        defer self.alloc.free(extents);
        self.childExtents(split, rect, extents);

        // A non-resizable split leaves no gap between its children and
        // draws no grab band -- see `Split.resizable`.
        const gap: usize = if (split.resizable) self.divider_cells else 0;

        var pos: usize = if (split.axis == .row) rect.col else rect.row;
        for (split.children.items, 0..) |child, i| {
            const extent = extents[i];
            const child_rect: CellRect = if (split.axis == .row)
                .{ .row = rect.row, .col = pos, .cols = extent, .rows = rect.rows }
            else
                .{ .row = pos, .col = rect.col, .cols = rect.cols, .rows = extent };

            switch (child.target) {
                .layer => |h| try self.applyBounds(h, child_rect, changed),
                .split => |h| try self.layoutSplit(h, child_rect, changed, dividers, depth + 1),
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

    /// Splits `rect`'s extent along the split's axis across its children:
    /// `fixed` children take their cells first, `weight` children share
    /// what's left. The last weighted child absorbs the rounding
    /// remainder, so the children plus dividers always fill the split
    /// exactly rather than leaving a stray blank column.
    ///
    /// `out.len` must equal the child count.
    fn childExtents(self: *const Context, split: *const Split, rect: CellRect, out: []usize) void {
        const n = split.children.items.len;
        const axis_total: usize = if (split.axis == .row) rect.cols else rect.rows;
        const gap: usize = if (split.resizable) self.divider_cells else 0;
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
            // Clamped against what's actually left: a client whose fixed
            // children over-subscribe the window gets truncation at the
            // end rather than panes drawn outside it.
            out[i] = @min(want, remaining);
            remaining -= out[i];
        }
    }

    /// Places one layer at `rect` -- position in cells, viewport to the
    /// pane's size. The layer's *content* size is left alone: a file tree
    /// taller than its pane is the whole point of the viewport, and the
    /// client owns how much content there is.
    fn applyBounds(self: *Context, handle: LayerHandle, rect: CellRect, changed: ?*std.ArrayList(LayerBounds)) !void {
        // The root layer is drawn at a fixed origin and is never a pane --
        // see the Splits section's note.
        if (handle == root_layer_handle) return;
        const layer = self.layers.getPtr(handle) orelse return;

        const moved = layer.pos_cells == null or
            layer.pos_cells.?.row != rect.row or
            layer.pos_cells.?.col != rect.col;
        const resized = layer.viewport_cols != rect.cols or layer.viewport_rows != rect.rows;

        if (moved) {
            layer.pos_cells = .{ .row = rect.row, .col = rect.col };
            layer.pos = self.pixelPosForCell(layer.pos_cells.?);
            layer.touchRender();
        }
        if (resized) layer.setProperty(.{ .viewport = .{ .cols = rect.cols, .rows = rect.rows } });

        // Reporting is measured against the last rect that was *reported*,
        // not the one currently applied -- see `Layer.reported_bounds`.
        // The two differ exactly when a silent pass (`changed == null`)
        // applied a rect nobody has been told about yet, which is what a
        // window resize does on its way through `Session.republish`.
        const out = changed orelse return;
        if (layer.reported_bounds) |prev| {
            if (prev.row == rect.row and prev.col == rect.col and
                prev.cols == rect.cols and prev.rows == rect.rows) return;
        }
        layer.reported_bounds = rect;
        try out.append(self.alloc, .{
            .layer = handle,
            .row = rect.row,
            .col = rect.col,
            .cols = rect.cols,
            .rows = rect.rows,
        });
    }

    /// `move_divider`: drags the band after child `index` by `delta`
    /// cells along the split's axis, growing one neighbour and shrinking
    /// the other. This is what a mouse drag on a divider does; a client
    /// can send it too (a keyboard "grow this pane" binding).
    ///
    /// How the sizes change depends on how the pair was declared, so that
    /// a drag doesn't silently convert a pane's sizing mode: a `fixed`
    /// neighbour keeps its cells and just gets more or fewer of them, and
    /// a `weight` pair keeps its combined weight and re-splits it by the
    /// new ratio (so the rest of the tree is undisturbed).
    pub fn moveDivider(self: *Context, handle: SplitHandle, index: usize, delta: i64) SplitError!void {
        const split = self.splits.getPtr(handle) orelse return SplitError.UnknownSplit;
        if (!split.laid_out) return;
        // A non-resizable split has no draggable bands -- a client asking
        // to move one is asking for nothing (see `Split.resizable`).
        if (!split.resizable) return;
        const n = split.children.items.len;
        if (index + 1 >= n) return;
        if (delta == 0) return;

        const extents = self.alloc.alloc(usize, n) catch return;
        defer self.alloc.free(extents);
        self.childExtents(split, split.last_rect, extents);

        const before = extents[index];
        const after = extents[index + 1];
        const pair = before + after;
        if (pair < 2 * min_pane_cells) return;

        // Clamp the drag so neither neighbour is squeezed out of
        // existence -- a pane at zero cells can't be grabbed back.
        const lo: i64 = @intCast(min_pane_cells);
        const hi: i64 = @intCast(pair - min_pane_cells);
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

        // A fixed neighbour just gets a new cell count. A weighted one
        // next to a fixed one needs no change at all -- it already
        // absorbs whatever the fixed one leaves.
        if (wa == null) a.size = .{ .fixed = new_before };
        if (wb == null) b.size = .{ .fixed = new_after };
        if (wa != null and wb != null) {
            const total_w = wa.? + wb.?;
            if (total_w <= 0) return;
            const frac = @as(f32, @floatFromInt(new_before)) / @as(f32, @floatFromInt(pair));
            a.size = .{ .weight = total_w * frac };
            b.size = .{ .weight = total_w * (1 - frac) };
        }

        self.layout_gen +%= 1;
    }

    /// Resolves a wire-level layer handle to its `Layer` -- `null` (an
    /// omitted `layer` param) and `root_layer_handle` both mean the root
    /// layer, matching how omitted `row`/`col` already means "at the
    /// cursor" elsewhere in the wire API. Null for an unknown non-root
    /// handle (a destroyed or never-created layer).
    pub fn layerPtr(self: *Context, handle: ?LayerHandle) ?*Layer {
        const h = handle orelse root_layer_handle;
        if (h == root_layer_handle) return &self.root;
        return self.layers.getPtr(h);
    }

    /// `create_table`: builds a `Table` (taking ownership of `columns`/
    /// `style`, see `Table.init`) and stores it on the resolved layer's
    /// `tables` map, allocating a fresh handle from `next_table_handle`.
    /// Doesn't paint anything yet -- a freshly created table has no rows,
    /// so there's nothing to render until `table_set_rows`. `row`/`col`
    /// are the resolved anchor (cursor-defaulted by the caller,
    /// `handleCreateTable`, same convention `resolveAnchor` already gives
    /// `draw_icon`), not optional here.
    pub fn createTable(self: *Context, layer_handle: ?LayerHandle, row: usize, col: usize, columns: []TableColumn, style: TableStyle) !TableHandle {
        const layer = self.layerPtr(layer_handle) orelse return LayerError.UnknownLayer;

        const handle = self.next_table_handle;
        try layer.tables.put(handle, Table.init(self.alloc, row, col, columns, style));
        errdefer _ = layer.tables.remove(handle);
        try layer.table_order.append(self.alloc, handle);
        self.next_table_handle += 1;
        return handle;
    }

    /// `destroy_table`: blanks whatever the table last painted (see
    /// `Table.painted`), frees it, and drops it from its layer's
    /// compositing order. Errors on an unknown layer or table handle,
    /// same treatment `destroyLayer` gives an unknown layer handle.
    pub fn destroyTable(self: *Context, layer_handle: ?LayerHandle, handle: TableHandle) !void {
        const layer = self.layerPtr(layer_handle) orelse return LayerError.UnknownLayer;
        var removed = layer.tables.fetchRemove(handle) orelse return TableError.UnknownTable;
        cell_paint.clearExtent(layer, removed.value.painted);
        removed.value.deinit();
        for (layer.table_order.items, 0..) |h, i| {
            if (h == handle) {
                _ = layer.table_order.orderedRemove(i);
                break;
            }
        }
    }

    /// `create_outline`: builds an `Outline` (taking ownership of `style`,
    /// see `Outline.init`) on the resolved layer, allocating a fresh
    /// handle from `next_outline_handle`. Paints nothing yet -- a fresh
    /// outline has no nodes, so there is nothing to draw until
    /// `outline_set_nodes`, exactly as for a table and its rows.
    pub fn createOutline(self: *Context, layer_handle: ?LayerHandle, row: usize, col: usize, width: usize, style: OutlineStyle) !OutlineHandle {
        const layer = self.layerPtr(layer_handle) orelse return LayerError.UnknownLayer;

        const handle = self.next_outline_handle;
        try layer.outlines.put(handle, Outline.init(self.alloc, row, col, width, style));
        errdefer _ = layer.outlines.remove(handle);
        try layer.outline_order.append(self.alloc, handle);
        self.next_outline_handle += 1;
        return handle;
    }

    /// `destroy_outline`: blanks whatever the outline last painted, frees
    /// it, and drops it from its layer's paint order. The rows it occupied
    /// are left blank rather than closed up -- collapsing them would move
    /// content the caller didn't ask to move, and a client that wants the
    /// space back collapses the outline first.
    pub fn destroyOutline(self: *Context, layer_handle: ?LayerHandle, handle: OutlineHandle) !void {
        const layer = self.layerPtr(layer_handle) orelse return LayerError.UnknownLayer;
        var removed = layer.outlines.fetchRemove(handle) orelse return OutlineError.UnknownOutline;
        cell_paint.clearExtent(layer, removed.value.painted);
        removed.value.deinit();
        for (layer.outline_order.items, 0..) |h, i| {
            if (h == handle) {
                _ = layer.outline_order.orderedRemove(i);
                break;
            }
        }
        layer.touchRender();
    }

    /// Registers `style` under `name` for `create_nine_patch` to resolve.
    /// `name` is duped; an existing registration is replaced, same as
    /// `registerIcon`, so a user `.9.png` overrides a bundled one.
    pub fn registerNinePatchStyle(self: *Context, name: []const u8, style: NinePatchStyle) !void {
        if (self.nine_patch_styles.fetchRemove(name)) |kv| self.alloc.free(kv.key);
        const owned = try self.alloc.dupe(u8, name);
        errdefer self.alloc.free(owned);
        try self.nine_patch_styles.put(owned, style);
    }

    /// `create_nine_patch`'s name lookup, falling back to `asset_fallback`
    /// like `iconHandle`.
    pub fn ninePatchStyle(self: *const Context, name: []const u8) ?NinePatchStyle {
        if (self.nine_patch_styles.get(name)) |st| return st;
        if (self.asset_fallback) |f| return f.nine_patch_styles.get(name);
        return null;
    }

    /// `create_nine_patch`: adds a nine-patch panel to the resolved layer
    /// under a fresh handle. Renders immediately, like `createRect`.
    pub fn createNinePatch(self: *Context, layer_handle: ?LayerHandle, patch: NinePatch) !NinePatchHandle {
        const layer = self.layerPtr(layer_handle) orelse return LayerError.UnknownLayer;

        const handle = self.next_nine_patch_handle;
        try layer.nine_patches.put(handle, patch);
        self.next_nine_patch_handle += 1;
        layer.touchRender();
        return handle;
    }

    /// `update_nine_patch`: merges `patch`'s non-null fields into the
    /// existing nine-patch -- moving or resizing a panel doesn't re-send
    /// its style.
    pub fn updateNinePatch(self: *Context, layer_handle: ?LayerHandle, handle: NinePatchHandle, patch: NinePatchUpdate) !void {
        const layer = self.layerPtr(layer_handle) orelse return LayerError.UnknownLayer;
        const np = layer.nine_patches.getPtr(handle) orelse return NinePatchError.UnknownNinePatch;
        if (patch.style) |v| np.style = v;
        if (patch.row) |v| np.row = v;
        if (patch.col) |v| np.col = v;
        if (patch.rows) |v| np.rows = v;
        if (patch.cols) |v| np.cols = v;
        layer.touchRender();
    }

    /// `destroy_nine_patch`: removes the panel and stops it painting.
    pub fn destroyNinePatch(self: *Context, layer_handle: ?LayerHandle, handle: NinePatchHandle) !void {
        const layer = self.layerPtr(layer_handle) orelse return LayerError.UnknownLayer;
        _ = layer.nine_patches.fetchRemove(handle) orelse return NinePatchError.UnknownNinePatch;
        layer.touchRender();
    }

    /// `create_rect`: adds a new pixel-space overlay rect to the resolved
    /// layer, allocating a fresh handle from `next_rect_handle` (a single
    /// counter shared across every layer, exactly like
    /// `next_table_handle`). Renders immediately -- unlike a freshly
    /// created table (which has no rows yet), a rect is fully specified
    /// up front and has nothing further to configure before it paints.
    pub fn createRect(self: *Context, layer_handle: ?LayerHandle, rect: Rect) !RectHandle {
        const layer = self.layerPtr(layer_handle) orelse return LayerError.UnknownLayer;

        const handle = self.next_rect_handle;
        try layer.rects.put(handle, rect);
        self.next_rect_handle += 1;
        layer.touchRender();
        return handle;
    }

    /// `update_rect`: merges `patch`'s non-null fields into the existing
    /// rect -- see `RectUpdate`'s doc comment for why this is a merge
    /// rather than a replace.
    pub fn updateRect(self: *Context, layer_handle: ?LayerHandle, handle: RectHandle, patch: RectUpdate) !void {
        const layer = self.layerPtr(layer_handle) orelse return LayerError.UnknownLayer;
        const r = layer.rects.getPtr(handle) orelse return RectError.UnknownRect;
        if (patch.x) |v| r.x = v;
        if (patch.y) |v| r.y = v;
        if (patch.w) |v| r.w = v;
        if (patch.h) |v| r.h = v;
        if (patch.color) |v| r.color = v;
        if (patch.line_width) |v| r.line_width = v;
        if (patch.filled) |v| r.filled = v;
        layer.touchRender();
    }

    /// `destroy_rect`: removes the rect and stops it from painting. Errors
    /// on an unknown layer or rect handle, same treatment `destroyTable`
    /// gives an unknown table handle.
    pub fn destroyRect(self: *Context, layer_handle: ?LayerHandle, handle: RectHandle) !void {
        const layer = self.layerPtr(layer_handle) orelse return LayerError.UnknownLayer;
        _ = layer.rects.fetchRemove(handle) orelse return RectError.UnknownRect;
        layer.touchRender();
    }

    /// `set_drop_target`: replaces the layer's drop-target highlight, or
    /// clears it with null. Setting what is already there leaves the
    /// layer's render cache alone, since a drag sends this on every
    /// pointer move and most of those don't change the target.
    pub fn setDropTarget(self: *Context, layer_handle: ?LayerHandle, target: ?DropTarget) !void {
        const layer = self.layerPtr(layer_handle) orelse return LayerError.UnknownLayer;
        if (std.meta.eql(layer.drop_target, target)) return;
        layer.drop_target = target;
        layer.touchRender();
    }

    /// Registers `handle` under `name` in the icon catalog, for `draw_icon`
    /// to resolve later. `name` is duped -- the caller (`glyphwire-host`'s
    /// `loadIconsFromDir`) doesn't need to keep its own copy alive.
    /// Overwrites any existing
    /// registration under the same name (its old key is freed) rather than
    /// erroring, so re-running icon loading is idempotent.
    pub fn registerIcon(self: *Context, name: []const u8, handle: ImageHandle) !void {
        if (self.icons.fetchRemove(name)) |kv| self.alloc.free(kv.key);
        const owned = try self.alloc.dupe(u8, name);
        errdefer self.alloc.free(owned);
        try self.icons.put(owned, handle);
    }

    /// `draw_icon`'s name -> handle lookup. Falls back to
    /// `asset_fallback`'s catalog (the session's root context -- see that
    /// field) for a name this context never registered itself, so a
    /// `create_context` context resolves the host's bundled icons.
    /// Null for a name unknown to both.
    pub fn iconHandle(self: *const Context, name: []const u8) ?ImageHandle {
        if (self.icons.get(name)) |h| return h;
        if (self.asset_fallback) |f| return f.icons.get(name);
        return null;
    }

    /// A loaded image's stored entry (raw bytes + measured dimensions),
    /// consulting `asset_fallback` for a handle this context never loaded
    /// itself -- the icon catalog `iconHandle` falls back to resolves its
    /// handles against the root context's `images`, so the renderer and
    /// the draw handlers have to look there too. Null for a handle
    /// unknown to both.
    pub fn imageEntry(self: *const Context, handle: ImageHandle) ?ImageEntry {
        if (self.images.get(handle)) |e| return e;
        if (self.asset_fallback) |f| return f.images.get(handle);
        return null;
    }

    /// `load_image` from an in-process caller: no owning connection, so
    /// the result is never a sweep candidate. See `loadImageFrom`.
    pub fn loadImage(self: *Context, format: ImageFormat, bytes: []const u8) !ImageHandle {
        return self.loadImageFrom(format, bytes, null);
    }

    /// `load_image`: stores `bytes` verbatim and reads their natural
    /// dimensions from `format`'s header (`imageDimensions`) -- see
    /// `ImageEntry`'s doc comment. Bytes that don't match the declared
    /// `format` fail with the matching `ImageError`. Returns a fresh
    /// server-generated handle.
    ///
    /// `loader` is the connection the request came in on (null for an
    /// in-process caller), recorded so the image stays pinned against the
    /// scrollback sweep for as long as that client is alive -- see
    /// `ImageEntry.loader`.
    pub fn loadImageFrom(self: *Context, format: ImageFormat, bytes: []const u8, loader: ?ConnId) !ImageHandle {
        const info = try imageDimensions(format, bytes);
        const owned = try self.alloc.dupe(u8, bytes);
        errdefer self.alloc.free(owned);

        const handle = self.next_image_handle;
        self.next_image_handle += 1;
        try self.images.put(handle, .{
            .bytes = owned,
            .format = format,
            .width = info.width,
            .height = info.height,
            .loader = loader,
            .sweepable = loader != null,
        });
        self.image_bytes += owned.len;
        return handle;
    }

    /// `get_image_info`: natural pixel dimensions, or null for an unknown
    /// handle. Falls back to `asset_fallback` like `imageEntry`.
    pub fn imageInfo(self: *const Context, handle: ImageHandle) ?ImageInfo {
        const entry = self.imageEntry(handle) orelse return null;
        return .{ .width = entry.width, .height = entry.height };
    }

    /// Whether `handle` is registered in this context's icon catalog --
    /// the guard `destroyImage`/`updateImage`/`sweepImages` share. Walks
    /// `icons` rather than keeping a reverse map: the catalog is a few
    /// hundred entries scanned once at startup, and this runs only on the
    /// lifecycle messages, never per frame.
    pub fn isIconHandle(self: *const Context, handle: ImageHandle) bool {
        var it = self.icons.valueIterator();
        while (it.next()) |h| if (h.* == handle) return true;
        // A nine-patch's `.9.png` is catalog art the same way.
        var np_it = self.nine_patch_styles.valueIterator();
        while (np_it.next()) |st| if (st.image == handle) return true;
        return false;
    }

    /// `destroy_image`: frees a loaded image's bytes and drops its handle.
    ///
    /// Cells still backed by the handle are deliberately **left alone**.
    /// The alternative -- scanning every layer's ring buffer to blank them
    /// -- would make an O(1) release O(cells) and would silently wipe
    /// content the caller didn't ask to touch. A dangling image handle
    /// renders as nothing (glyphwire-host's `textureForImage` already
    /// returns null for a handle it can't resolve), the same way
    /// `get_metadata` reports a dangling `metadata_id` rather than
    /// treating it as an error.
    ///
    /// Resolves only against **this** context's own `images`: an
    /// `asset_fallback` entry belongs to the root context and is not this
    /// context's to free.
    pub fn destroyImage(self: *Context, handle: ImageHandle) ImageResourceError!void {
        if (self.isIconHandle(handle)) return ImageResourceError.ImageIsIcon;
        const removed = self.images.fetchRemove(handle) orelse return ImageResourceError.UnknownImage;
        self.image_bytes -= removed.value.bytes.len;
        self.alloc.free(removed.value.bytes);
        self.image_gen +%= 1;
    }

    /// `update_image`: replaces a loaded image's bytes in place, keeping
    /// its handle. For a client that redraws the same slot over and over
    /// -- a comic/page reader stepping through a `.cbz`, a plot that
    /// refreshes -- where `load_image`-per-frame would pile up one dead
    /// entry per step.
    ///
    /// The new bytes may have different natural dimensions than the old.
    /// Cells already drawn from this handle keep the per-cell sampling
    /// offsets `drawImage` baked in from the *old* size, which stay exact
    /// only while the size is unchanged; a caller that changes it is
    /// expected to `draw_image` again with a span sized for the new
    /// dimensions (which a page reader does anyway). Re-deriving those
    /// offsets here would mean tracking every span a handle was ever
    /// drawn into, and would silently repaint cells the caller may since
    /// have cleared -- see decisions.md's Image lifecycle section.
    pub fn updateImage(self: *Context, handle: ImageHandle, format: ImageFormat, bytes: []const u8) !void {
        if (self.isIconHandle(handle)) return ImageResourceError.ImageIsIcon;
        const entry = self.images.getPtr(handle) orelse return ImageResourceError.UnknownImage;

        // Measure and copy before touching the existing entry, so a bad
        // payload leaves the old image intact rather than blanking it.
        const info = try imageDimensions(format, bytes);
        const owned = try self.alloc.dupe(u8, bytes);

        self.image_bytes -= entry.bytes.len;
        self.alloc.free(entry.bytes);
        entry.bytes = owned;
        entry.format = format;
        entry.width = info.width;
        entry.height = info.height;
        entry.generation +%= 1;
        self.image_bytes += owned.len;
        self.image_gen +%= 1;
    }

    /// Drops `conn`'s pin from every image it loaded (see
    /// `ImageEntry.loader`), making those images sweep candidates the
    /// moment nothing on screen references them. Called from server.zig
    /// on disconnect alongside `removeConnectionOwnership`.
    ///
    /// Deliberately does *not* free anything itself: an image drawn by a
    /// program that has since exited is exactly the case that has to keep
    /// rendering -- `glyphwire-view` loads, draws and exits, and the
    /// picture stays in the shell's scrollback afterwards. Reclaiming it
    /// is the sweep's job, once it has actually scrolled away.
    pub fn releaseImages(self: *Context, conn: ConnId) void {
        var it = self.images.valueIterator();
        while (it.next()) |entry| {
            if (entry.loader) |c| {
                if (c == conn) entry.loader = null;
            }
        }
    }

    /// Marks every image handle any cell in this context still references,
    /// for the sweep below. Walks each layer's whole ring buffer (live
    /// viewport *and* retained scrollback) plus its alt screen, since an
    /// image that has merely scrolled out of view is still displayed the
    /// moment the user scrolls back to it.
    ///
    /// Only `.image` backgrounds are marked. The `.icon` background and
    /// `Cell.fg_icon` can only ever hold a catalog handle (`draw_icon`
    /// resolves a *name*, never a raw handle), and catalog images are
    /// loaded in-process and so never `sweepable` in the first place --
    /// marking them would be work per cell to protect what is already
    /// unreachable from the sweep.
    pub fn markImageRefs(self: *const Context, seen: *std.AutoHashMap(ImageHandle, void)) !void {
        try markLayerImageRefs(&self.root, seen);
        var it = self.layers.valueIterator();
        while (it.next()) |layer| try markLayerImageRefs(layer, seen);
    }

    fn markLayerImageRefs(layer: *const Layer, seen: *std.AutoHashMap(ImageHandle, void)) !void {
        for (layer.buf) |c| {
            if (c.style.bg == .image) try seen.put(c.style.bg.image.handle, {});
        }
        if (layer.vt.alt_cells) |alt| {
            for (alt) |c| {
                if (c.style.bg == .image) try seen.put(c.style.bg.image.handle, {});
            }
        }
    }

    /// Frees every image in this context that is `sweepable`, unpinned
    /// (its loading connection is gone) and absent from `referenced` --
    /// i.e. loaded over a socket by a client that has since exited, and
    /// no longer on any cell because the rows holding it fell off the end
    /// of the scrollback ring. Returns the bytes reclaimed.
    ///
    /// `referenced` must have been marked across **every** context in the
    /// session, not just this one: `asset_fallback` lets a
    /// `create_context` program's cells resolve handles that live in the
    /// root context's map, so a root-context image can be kept alive by a
    /// cell somewhere else entirely. `Session.sweepImages` is what
    /// guarantees that; call it rather than this directly.
    ///
    /// No icon check is needed here even though icons share the `images`
    /// map: a catalog image is loaded in-process (`host/icons.zig`), so
    /// it is never `sweepable`.
    pub fn sweepImages(self: *Context, referenced: *const std.AutoHashMap(ImageHandle, void)) !usize {
        // Collected first: removing from a hash map while iterating it
        // would invalidate the iterator.
        var doomed: std.ArrayList(ImageHandle) = .empty;
        defer doomed.deinit(self.alloc);

        var it = self.images.iterator();
        while (it.next()) |entry| {
            const e = entry.value_ptr;
            if (!e.sweepable or e.loader != null) continue;
            if (referenced.contains(entry.key_ptr.*)) continue;
            try doomed.append(self.alloc, entry.key_ptr.*);
        }

        var freed: usize = 0;
        for (doomed.items) |h| {
            const removed = self.images.fetchRemove(h) orelse continue;
            freed += removed.value.bytes.len;
            self.alloc.free(removed.value.bytes);
        }
        self.image_bytes -= freed;
        if (freed > 0) self.image_gen +%= 1;
        return freed;
    }

    /// Records `conn` as an owner of this context (see `owners`). Adding
    /// an id already present is a no-op. Marks the context
    /// `connection_owned` so a later drain to zero owners culls it.
    pub fn addOwner(self: *Context, conn: ConnId) !void {
        try self.owners.put(conn, {});
        self.connection_owned = true;
    }

    /// Whether `conn` owns this context -- the check `destroy_context`
    /// makes before honouring a request from a socket connection.
    pub fn hasOwner(self: *const Context, conn: ConnId) bool {
        return self.owners.contains(conn);
    }
};
