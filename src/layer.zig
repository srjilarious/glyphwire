// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: MPL-2.0

//! `Layer`: one cell grid with its scrollback, VT state, cursor,
//! selection, scroll and viewport state, and the components drawn on it
//! (rects, nine-patches, tables, outlines). Moved out of `core.zig`
//! (review B8), which re-exports it, so `core.Layer` still names it.

const std = @import("std");
const core = @import("core.zig");
/// The VT escape machine `Layer.writeRuns` feeds: its state is `Layer.vt`.
const vt = @import("vt.zig");

const Background = core.Background;
const Cell = core.Cell;
const CellPos = core.CellPos;
const CellRect = core.CellRect;
const Color = core.Color;
const ConnId = core.ConnId;
const Cursor = core.Cursor;
const Decoration = core.Decoration;
const DropTarget = core.DropTarget;
const HAlign = core.HAlign;
const IconScale = core.IconScale;
const ImageHandle = core.ImageHandle;
const ImageSrcRect = core.ImageSrcRect;
const LayerSelection = core.LayerSelection;
const LineJoin = core.LineJoin;
const MetadataHandle = core.MetadataHandle;
const MetadataSpanDir = core.MetadataSpanDir;
const MetadataSpanHit = core.MetadataSpanHit;
const NinePatch = core.NinePatch;
const NinePatchHandle = core.NinePatchHandle;
const Outline = core.Outline;
const OutlineHandle = core.OutlineHandle;
const PropertyName = core.PropertyName;
const PropertyValue = core.PropertyValue;
const PxPos = core.PxPos;
const Rect = core.Rect;
const RectHandle = core.RectHandle;
const ResizeEdge = core.ResizeEdge;
const ScrollMode = core.ScrollMode;
const ScrollbarState = core.ScrollbarState;
const Scrollbars = core.Scrollbars;
const Shadow = core.Shadow;
const Table = core.Table;
const TableHandle = core.TableHandle;
const TextScale = core.TextScale;
const UnderlineStyle = core.UnderlineStyle;
const VAlign = core.VAlign;
const Vt = core.Vt;
const codepointWidth = core.codepointWidth;
const default_style = core.default_style;
const isZeroWidth = core.isZeroWidth;
const scaledPitch = core.scaledPitch;
const shiftRowByHeightDelta = core.shiftRowByHeightDelta;
const tab_width = core.tab_width;

/// A layer's cell grid is a fixed-capacity ring buffer of
/// `height + scrollback_rows` physical rows, one contiguous allocation.
/// The visible viewport is always the most recently written `height`
/// rows; writing past the bottom row scrolls (the old top row becomes
/// history, evicting the oldest history row once scrollback is full) —
/// the same "live tail" behavior a real terminal has. `scrollback_rows`
/// is a per-layer creation parameter (0 for a layer with no need for
/// history, e.g. a small popup notification) rather than a fixed default,
/// since layers range from a terminal-sized root layer down to something
/// like a 45x3 notification.
pub const Layer = struct {
    alloc: std.mem.Allocator,
    width: usize,
    height: usize,
    scrollback_rows: usize,
    /// Ring buffer storage: `capacity()` rows of `width` cells each.
    buf: []Cell,
    /// Physical row index (row units, not cell units) of the viewport's
    /// top row.
    viewport_start: usize = 0,
    /// How many rows above the viewport currently hold real history, vs.
    /// never-written blank space. Saturates at `scrollback_rows`.
    history_len: usize = 0,
    /// Display-only scrollback view offset in rows: how many rows of
    /// history (`history_len`) are currently shown above the live
    /// viewport. 0 is the live tail. Never affects where writes land --
    /// `viewRow` applies it at read time only, and `cell()` ignores it
    /// entirely. Driven by glyphwire-host's mouse wheel / scrollbar and
    /// by the `scroll_view` wire method (glyphwire-shell's browse cursor).
    /// `scrollOne` bumps it in step with incoming output so the rows a
    /// user is looking at stay put while new output accumulates below,
    /// until history eviction forces a drift. See `PropertyName.scroll`.
    view_scroll: usize = 0,
    cursor: Cursor = .{},
    /// The text selection, the highlighted metadata ids and which way a
    /// selection reads -- see `layer_selection.zig`, which also holds the
    /// operations on them (`layer.sel.text(alloc)`).
    sel: LayerSelection = .{},
    /// The VT machine's own state: the escape parser, charsets, SGR pen,
    /// DEC modes, tab stops, REP's last glyph and pending replies. See
    /// `vt.zig`, which holds the machine itself.
    vt: Vt = .{},
    /// `Cell.selectable` for every cell the `write_text` in progress
    /// touches -- `RunsOpts.selectable`, set by `writeRuns` for the length
    /// of the call and back to true after it, so every other write path
    /// (the pty stream, tables) leaves cells selectable. Lives on the
    /// `Layer` for the same reason `pen` does: `putAtCursor` is reached
    /// from deep inside the escape machine too.
    write_selectable: bool = true,
    /// `Cell.masked` for every cell the `write_text` in progress touches
    /// -- `RunsOpts.masked`, scoped to the call exactly like
    /// `write_selectable`.
    write_masked: bool = false,
    /// `Cell.copy_alt` for every glyph the `write_text` in progress
    /// draws -- `RunsOpts.copy_text` interned, set by `writeRuns` for the
    /// length of the call and back to 0 after it, exactly like
    /// `write_selectable`.
    write_copy_alt: u16 = 0,
    /// The distinct `write_text` `copy_text` strings this layer has been
    /// given, owned, indexed by `Cell.copy_alt - 1`. Interned rather than
    /// reference counted: the callers substitute a handful of fixed
    /// characters, so the table stays as small as that set, and a stale
    /// entry costs a few bytes until the layer goes. Never shrinks.
    copy_texts: std.ArrayList([]u8) = .empty,
    /// When set, the escape-sequence machine (`esc_state` / `csi_buf` /
    /// `csi_len`), the alternate-charset designation (`shift_out` /
    /// `g0_line_drawing` / `g1_line_drawing`) and the SGR `pen` are **kept
    /// across `writeText` calls** instead of being reset at the call
    /// boundary -- see `EscState`'s "nothing carries across calls" note
    /// for the default behaviour and why it exists.
    ///
    /// A layer fed one contiguous byte stream from a single PTY child --
    /// `gmux`'s panes, and `glyphwire-shell`'s root layer while a
    /// foreground program holds it -- wants real terminal semantics
    /// instead: a `CSI` sequence a `read()` split across two chunks must
    /// still parse as one, and an `ESC [ 31 m` stays in effect until the
    /// program itself resets it. The call-scoped reset turns both of
    /// those into "draw the tail as literal text" / "lose the colour",
    /// which is the escape-garbage seen scrolling fast through `bat` or
    /// `git log`.
    ///
    /// Off by default: the shell's prompt/echo path interleaves its own
    /// writes with a mirrored program's on the same layer, and there the
    /// call-scoped guard is what stops an interrupted colour or a
    /// half-open `ESC ] ...` from poisoning the prompt. Set (or re-set)
    /// via `set_property "pty_mode"`, which also clears the transient
    /// state above -- a clean re-arm point for when a foreground program
    /// exits.
    pty_mode: bool = false,
    /// Whether glyphwire-host may start one of *its own* mouse text
    /// selections (drag to select, copy to the clipboard) on this layer.
    ///
    /// Off by default, because a client that draws its own layers is
    /// usually also listening for `mouse_button` and would have the host
    /// fighting it for the left button: in `salacommander` a click in a
    /// file pane moves that pane's cursor, and a host selection drawn
    /// over it would mean nothing. The exception is a layer holding
    /// *terminal output* -- the embedded `gw-shell --embed` panel -- where
    /// the text on the layer is the thing the user wants to copy and the
    /// program underneath has no use for the click. Such a client opts
    /// that one layer in with `set_property "mouse_select"`.
    ///
    /// The root layer is the other way round: it is a terminal by
    /// definition, so the host selects on it unless a client has taken
    /// the whole context (`Context.connection_owned`). See
    /// `host/selection.zig`.
    mouse_select: bool = false,
    /// Whether the program whose output this layer shows has turned on
    /// xterm mouse reporting (`?1000` / `?1002` / `?1003`) -- set by
    /// glyphwire-shell as its pty child flips those modes. While it is,
    /// glyphwire-host stands down on this layer: no drag or multi-click
    /// selection, and the wheel goes to the program as wheel buttons
    /// rather than scrolling the scrollback, so vim or htop with
    /// `mouse=a` gets the raw presses, drags and releases it asked for.
    /// Shift held overrides it, the xterm convention for selecting text
    /// out of a mouse-mode program.
    ///
    /// Separate from `mouse_select`, which is a client-owned context's
    /// opt-*in* to host selection; this is a terminal layer's opt-*out*,
    /// and it follows the program, not the client.
    mouse_report: bool = false,
    /// The edge the host lets the user drag. See `ResizeEdge`.
    resize_edge: ResizeEdge = .none,
    /// See `PropertyName.revision`.
    revision: u64 = 0,
    /// Host-internal render-invalidation counter: bumped by `touchRender`
    /// on *any* change that alters what glyphwire-host would composite for
    /// this layer -- a superset of `revision`, which counts only cell
    /// content. On top of `revision`'s triggers it also moves on a
    /// scrollback-view change (`scrollView` / `scrollOne`), a `resize`, a
    /// `set_property` (position), and any selection or highlight edit.
    /// glyphwire-host caches a static quad batch per layer and only
    /// rebuilds it when this counter has moved since the batch was last
    /// built (see `host/render.zig`). Not on the wire -- `revision` is the
    /// client-facing "did the content change" poll; this one is purely the
    /// renderer's. Wraps (`+%`); the renderer only ever compares for
    /// inequality.
    render_gen: u64 = 0,
    /// See `PropertyName.position`. Zero for the root layer (there's no
    /// wire path that moves it) and for a freshly created layer until its
    /// creator calls `set_property(layer, "position", ...)`.
    pos: PxPos = .{},
    /// See `PropertyName.cell_position`. Non-null when `pos` above was
    /// last derived from a *cell* position rather than set in pixels, in
    /// which case `Context.setCellMetrics` re-derives `pos` from it on a
    /// font-size change. A pixel `set_property(position)` clears it.
    pos_cells: ?CellPos = null,
    /// Tables painted onto this layer (`create_table`), keyed by handle --
    /// decisions.md's Table section: a table is a component of a layer,
    /// not a parallel object tree like `Context.layers` is. A table's
    /// handle is still allocated from `Context.next_table_handle` (a
    /// single counter shared across every layer), but the `Table` value
    /// itself lives here, on whichever layer it was created on.
    tables: std.AutoHashMap(TableHandle, Table),
    /// Creation order of `tables`' entries, for repaint/compositing order
    /// -- same reasoning `Context.layer_order` already has for
    /// `Context.layers` (`AutoHashMap` iteration order is unspecified).
    /// Not consulted by rendering yet (a table paints its own cells once,
    /// at mutation time, not per frame -- see `Table.render`), but kept
    /// for a future "which table's border wins where two overlap" rule.
    table_order: std.ArrayList(TableHandle) = .empty,
    /// Overlay rects painted onto this layer (`create_rect`), keyed by
    /// handle -- a component of the layer exactly like `tables`, and
    /// allocated from the same kind of shared counter
    /// (`Context.next_rect_handle`). No ordering list: unlike tables,
    /// rects never repaint cells they might overlap (they're not part of
    /// the cell grid at all), so there's no "which one wins" question to
    /// answer.
    rects: std.AutoHashMap(RectHandle, Rect),
    /// Where a drag in progress would drop if released over this layer
    /// (`set_drop_target`), or null for none -- the default, and what a
    /// client sets again when the pointer leaves or the button comes up.
    /// One per layer: a drop lands in one place.
    drop_target: ?DropTarget = null,
    /// Nine-patch panels drawn on this layer (`create_nine_patch`), keyed
    /// by handle -- a component of the layer like `rects`, with the same
    /// shared-counter handles (`Context.next_nine_patch_handle`). No
    /// ordering list either: they're drawn under every cell background,
    /// and two overlapping panels on one layer isn't something any client
    /// does.
    nine_patches: std.AutoHashMap(NinePatchHandle, NinePatch),
    /// Collapsible outlines painted onto this layer (`create_outline`),
    /// keyed by handle -- a component of the layer exactly like `tables`,
    /// from the shared `Context.next_outline_handle` counter. Like a
    /// table, an outline is placed *by row*, so `scrollOne`/`unscrollOne`/
    /// `resize`/`reflowAt` all re-pin its `top_live` as content moves.
    outlines: std.AutoHashMap(OutlineHandle, Outline),
    /// Paint order of `outlines`' entries -- the order a marker hit-test
    /// walks, so where two overlap the last drawn takes the click, the
    /// same rule `table_order` sets up for tables.
    outline_order: std.ArrayList(OutlineHandle) = .empty,
    /// Whether this layer's size should follow the context's base size on
    /// a window resize -- true for the root layer and for any
    /// `create_layer` layer made without an explicit `width`/`height` (so
    /// it was already mirroring root's dimensions). A layer created at an
    /// explicit size (e.g. a 45x3 notification popup) keeps that size.
    /// See `Context.resize`.
    tracks_context_size: bool = false,
    /// See `PropertyName.visibility`. Always true for the root layer --
    /// nothing can set it there.
    visible: bool = true,
    /// See `PropertyName.opacity`. Always 1.0 for the root layer.
    /// Clamped to 0.0..1.0 on write, and a NaN is taken as 1.0: a
    /// client that computes a fade factor and divides by zero should
    /// get a visible layer back, not one that vanishes.
    opacity: f32 = 1.0,
    /// See `PropertyName.viewport`. 0 on an axis means the whole content
    /// grid on that axis; read them through `viewportCols`/`viewportRows`,
    /// which resolve the default and clamp to the content.
    viewport_cols: usize = 0,
    viewport_rows: usize = 0,
    /// The rect this layer's bounds were last *reported* at -- the last
    /// time `Context.applyBounds` ran with a `changed` list to collect
    /// into. Null until the first such pass.
    ///
    /// Deliberately separate from the applied geometry (`pos_cells` /
    /// `viewport_*`), because a layout pass that collects nothing still
    /// applies. `Session.republish` re-walks every on-screen context's
    /// split tree after any pane change, passing no list -- so on a window
    /// resize it applied every new rect silently, and the `reportLayout`
    /// that followed compared the new rects against the new geometry,
    /// found them equal and broadcast nothing. Clients got a `resize` and
    /// no `layout`, and every split-using pane sat at its old size.
    /// Comparing against what was last *reported* is what closes that.
    reported_bounds: ?CellRect = null,
    /// See `PropertyName.scroll_offset` -- the viewport's top-left within
    /// the content grid. Always within `maxScroll` (every writer goes
    /// through `setScrollOffset`, and `resize` re-clamps).
    scroll_off: CellPos = .{},
    /// See `PropertyName.content_extent`. Non-null on a pane that scrolls
    /// itself: the size of the whole content the client redraws, which
    /// the scrollbar/viewport maths use in place of the real grid.
    content_extent: ?CellPos = null,
    /// See `PropertyName.scroll_mode`. `content_extent`/`content_off` are
    /// only ever non-default in `.client`.
    scroll_mode: ScrollMode = .host,
    /// See `PropertyName.background`.
    background: ?Color = null,
    /// See `PropertyName.shadow`. Stored already `Shadow.clamped`.
    shadow: ?Shadow = null,
    /// The virtual scroll position of a `.client` scroll-mode layer --
    /// `scroll_off` stays put (the real grid never moves) and this is
    /// what `set_property(scroll_offset)`, the scrollbar and the wheel
    /// move instead.
    content_off: CellPos = .{},
    /// See `PropertyName.scrollbars`.
    scrollbars: Scrollbars = .{},
    /// The connections that own this layer, for lifecycle culling (see
    /// `ConnId` and `Context.removeConnectionOwnership`). Populated only
    /// for layers created over a socket connection: `Context.createLayer`
    /// leaves it empty and `connection_owned` false, and the dispatcher
    /// then calls `Context.addLayerOwner` with the creating connection's
    /// id. `adopt_layer` adds further ids. When the set drains to empty
    /// because every owning connection has disconnected, the layer is
    /// destroyed.
    owners: std.AutoHashMap(ConnId, void),
    /// True once this layer has had at least one connection owner (via
    /// `Context.addLayerOwner`). Distinguishes a layer whose owners have
    /// all disconnected (empty `owners`, cull it) from an in-process layer
    /// that never had a connection owner in the first place (also empty
    /// `owners`, but must be left alone).
    connection_owned: bool = false,

    pub fn init(alloc: std.mem.Allocator, width: usize, height: usize, scrollback_rows: usize) !Layer {
        const total_rows = height + scrollback_rows;
        const buf = try alloc.alloc(Cell, width * total_rows);
        for (buf) |*c| c.* = .{};

        return .{
            .alloc = alloc,
            .width = width,
            .height = height,
            .tables = std.AutoHashMap(TableHandle, Table).init(alloc),
            .rects = std.AutoHashMap(RectHandle, Rect).init(alloc),
            .nine_patches = std.AutoHashMap(NinePatchHandle, NinePatch).init(alloc),
            .outlines = std.AutoHashMap(OutlineHandle, Outline).init(alloc),
            .owners = std.AutoHashMap(ConnId, void).init(alloc),
            .scrollback_rows = scrollback_rows,
            .buf = buf,
            .vt = .{ .scroll_bot = height - 1 },
        };
    }

    pub fn deinit(self: *Layer) void {
        self.alloc.free(self.buf);
        if (self.vt.alt_cells) |a| self.alloc.free(a);
        if (self.vt.tab_stops) |t| self.alloc.free(t);
        self.vt.osc.deinit(self.alloc);
        if (self.vt.clipboard_write) |c| self.alloc.free(c);
        var table_it = self.tables.valueIterator();
        while (table_it.next()) |t| t.deinit();
        self.tables.deinit();
        self.table_order.deinit(self.alloc);
        self.rects.deinit();
        self.nine_patches.deinit();
        var outline_it = self.outlines.valueIterator();
        while (outline_it.next()) |o| o.deinit();
        self.outlines.deinit();
        self.outline_order.deinit(self.alloc);
        self.sel.highlighted_ids.deinit(self.alloc);
        self.owners.deinit();
        for (self.copy_texts.items) |t| self.alloc.free(t);
        self.copy_texts.deinit(self.alloc);
    }

    /// `text`'s 1-based index in `copy_texts`, added if it isn't there
    /// yet -- what `Cell.copy_alt` stores. 0 (copy the grapheme as usual)
    /// once the table is full, which no real caller gets near.
    fn internCopyText(self: *Layer, text: []const u8) !u16 {
        for (self.copy_texts.items, 0..) |t, i| {
            if (std.mem.eql(u8, t, text)) return @intCast(i + 1);
        }
        if (self.copy_texts.items.len >= std.math.maxInt(u16)) return 0;
        const owned = try self.alloc.dupe(u8, text);
        errdefer self.alloc.free(owned);
        try self.copy_texts.append(self.alloc, owned);
        return @intCast(self.copy_texts.items.len);
    }

    /// The text a selection copies for `c`: its `copy_text` when it has
    /// one, else its grapheme. Nothing for a masked cell, which is already
    /// unselectable; this is the backstop.
    pub fn copyTextOf(self: *const Layer, c: *const Cell) []const u8 {
        if (c.masked) return "";
        if (c.copy_alt != 0 and c.copy_alt <= self.copy_texts.items.len) return self.copy_texts.items[c.copy_alt - 1];
        return c.grapheme();
    }

    pub fn capacity(self: *const Layer) usize {
        return self.height + self.scrollback_rows;
    }

    /// Drawn width in cells: the viewport if one is set, else the whole
    /// content grid -- never more than the content, so there is no
    /// scrolling into blank space.
    pub fn viewportCols(self: *const Layer) usize {
        if (self.viewport_cols == 0) return self.width;
        return @min(self.viewport_cols, self.width);
    }

    /// Drawn height in cells -- see `viewportCols`.
    pub fn viewportRows(self: *const Layer) usize {
        if (self.viewport_rows == 0) return self.height;
        return @min(self.viewport_rows, self.height);
    }

    /// The content size the scrollbar/viewport maths run against: the
    /// virtual `content_extent` for a self-scrolling pane, else the real
    /// cell grid.
    fn effectiveContent(self: *const Layer) CellPos {
        if (self.scroll_mode == .host) return .{ .row = self.height, .col = self.width };
        return self.content_extent orelse .{ .row = self.height, .col = self.width };
    }

    /// The scroll offset a scrollbar reflects and `set_property` /
    /// wheel / drag move: the virtual `content_off` for a self-scrolling
    /// pane, else the real `scroll_off`.
    pub fn effectiveScrollOffset(self: *const Layer) CellPos {
        return if (self.scroll_mode == .client) self.content_off else self.scroll_off;
    }

    /// The largest legal scroll offset on each axis: how much content the
    /// viewport can't show at once. Both zero when the viewport covers
    /// the whole content, which is what makes `scrollsAnywhere` false and
    /// leaves the scrollbars inert. Saturating -- a virtual
    /// `content_extent` smaller than the viewport just yields zero.
    pub fn maxScroll(self: *const Layer) CellPos {
        const c = self.effectiveContent();
        return .{
            .row = c.row -| self.viewportRows(),
            .col = c.col -| self.viewportCols(),
        };
    }

    /// Whether either axis has content the viewport can't reach.
    pub fn scrollsAnywhere(self: *const Layer) bool {
        const max = self.maxScroll();
        return max.row > 0 or max.col > 0;
    }

    /// Whether this layer has retained cell-grid scrollback the view can
    /// be moved back into (`view_scroll` / `scrollView`) -- distinct from
    /// `scrollsAnywhere`, which is about a viewport smaller than the
    /// content grid. A `gmux` pane's content grid is exactly its
    /// viewport, so only this is ever true for it; the host routes a
    /// wheel over such a pane to `Server.reportLayerScroll` (the ring)
    /// rather than `reportScrollOffset` (the viewport).
    pub fn hasScrollback(self: *const Layer) bool {
        return self.history_len > 0;
    }

    /// Moves the viewport, clamped to `maxScroll`, and returns where it
    /// landed. The single writer for the scroll offset -- the wheel, a
    /// scrollbar drag and `set_property` all come through here, so the
    /// clamp can't be bypassed. On a self-scrolling pane
    /// (`content_extent` set) this moves the virtual `content_off`; the
    /// real grid never moves.
    pub fn setScrollOffset(self: *Layer, off: CellPos) CellPos {
        const max = self.maxScroll();
        const next: CellPos = .{ .row = @min(off.row, max.row), .col = @min(off.col, max.col) };
        const cur = self.effectiveScrollOffset();
        if (next.row != cur.row or next.col != cur.col) {
            if (self.scroll_mode == .client) {
                self.content_off = next;
            } else {
                self.scroll_off = next;
            }
            self.touchRender();
        }
        return next;
    }

    /// Relative move, saturating at both ends -- what a wheel tick and an
    /// arrow key both want.
    pub fn scrollOffsetBy(self: *Layer, d_row: i64, d_col: i64) CellPos {
        const cur = self.effectiveScrollOffset();
        const row: i64 = @as(i64, @intCast(cur.row)) + d_row;
        const col: i64 = @as(i64, @intCast(cur.col)) + d_col;
        return self.setScrollOffset(.{
            .row = @intCast(@max(row, 0)),
            .col = @intCast(@max(col, 0)),
        });
    }

    /// Sets (or, with `null`, clears) the virtual content extent and
    /// re-clamps the virtual offset into it. Only meaningful in `.client`
    /// scroll mode; `Context.setLayerProperty` refuses it otherwise. See
    /// `PropertyName.content_extent`.
    pub fn setContentExtent(self: *Layer, extent: ?CellPos) void {
        std.debug.assert(self.scroll_mode == .client);
        self.content_extent = extent;
        if (extent == null) self.content_off = .{};
        _ = self.setScrollOffset(self.effectiveScrollOffset());
        self.touchRender();
    }

    /// Switches scroll model. A no-op when unchanged; otherwise both scroll
    /// positions reset to the origin and any `content_extent` is dropped,
    /// so nothing from one model's coordinates leaks into the other. See
    /// `PropertyName.scroll_mode`.
    pub fn setScrollMode(self: *Layer, mode: ScrollMode) void {
        if (mode == self.scroll_mode) return;
        self.scroll_mode = mode;
        self.content_extent = null;
        self.content_off = .{};
        self.scroll_off = .{};
        self.touchRender();
    }

    /// Everything the host needs to draw this layer's scrollbars, and the
    /// answer to `get_property(layer, "scrollbars")`.
    pub fn scrollbarState(self: *const Layer) ScrollbarState {
        const max = self.maxScroll();
        const off = self.effectiveScrollOffset();
        // A terminal-style layer -- viewport exactly its grid, output
        // scrolling off the top into the ring -- has no viewport slack at
        // all, but it is scrollable: what its bar should show is the
        // scrollback, the way the window's own bar shows the root layer's
        // (`geometry.scrollbarGeom`). Reported in the same sense as a
        // viewport offset, so the thumb is at the top when the view is
        // furthest back and at the bottom when it's live -- which is also
        // what makes the bar's own drag and page arithmetic work
        // unchanged. A `gmux` pane and `gw-shell --embed`'s panel are
        // both this shape.
        if (max.row == 0 and self.history_len > 0) {
            return .{
                .vertical = self.scrollbars.vertical,
                .horizontal = self.scrollbars.horizontal,
                .row = self.history_len - @min(self.view_scroll, self.history_len),
                .col = off.col,
                .max_row = self.history_len,
                .max_col = max.col,
            };
        }
        return .{
            .vertical = self.scrollbars.vertical,
            .horizontal = self.scrollbars.horizontal,
            .row = off.row,
            .col = off.col,
            .max_row = max.row,
            .max_col = max.col,
        };
    }

    /// Marks this layer's composited output stale so glyphwire-host
    /// rebuilds its cached quad batch -- see `render_gen`. Called by every
    /// `Layer` mutator that changes what the renderer would draw.
    pub fn touchRender(self: *Layer) void {
        self.render_gen +%= 1;
    }

    /// The current value of `render_gen` -- glyphwire-host reads this each
    /// frame (under `ctx_mutex`) and rebuilds the layer's quad batch when
    /// it differs from the value the batch was last built at.
    pub fn renderGeneration(self: *const Layer) u64 {
        return self.render_gen;
    }

    fn physicalRow(self: *const Layer, viewport_row: usize) usize {
        return (self.viewport_start + viewport_row) % self.capacity();
    }

    fn rowSlice(self: *const Layer, physical_row: usize) []Cell {
        const start = physical_row * self.width;
        return self.buf[start .. start + self.width];
    }

    /// The `width` cells of viewport row `viewport_row` on **whichever
    /// screen is active** -- the alt buffer while `vt.on_alt`, otherwise the
    /// ring-buffer row. Every in-place mutator (`cell`, `clear`,
    /// `insertCells`/`deleteCells`, the region scrollers) goes through
    /// this so the alt screen needs no separate code path.
    fn liveRow(self: *const Layer, viewport_row: usize) []Cell {
        if (self.vt.on_alt) {
            const start = viewport_row * self.width;
            return self.vt.alt_cells.?[start .. start + self.width];
        }
        return self.rowSlice(self.physicalRow(viewport_row));
    }

    /// Whether a DECSTBM scroll region narrower than the full screen is
    /// in effect -- see `Vt.scroll_top`/`scroll_bot`.
    pub fn regionActive(self: *const Layer) bool {
        return self.vt.scroll_top != 0 or self.vt.scroll_bot != self.height - 1;
    }

    pub fn cell(self: *const Layer, row: usize, col: usize) *Cell {
        return &self.liveRow(row)[col];
    }

    /// Mutable cells of the row at **signed** live-viewport coordinate
    /// `row`: `0` is the live viewport's top (same as `cell`), a negative
    /// value reaches `-row` rows up into retained scrollback. Returns null
    /// when the row isn't in the retained buffer -- `>= height` (below the
    /// viewport, doesn't exist yet) or more than `history_len` rows above
    /// it (scrolled out of history). Unlike `viewRow` this is a *write*
    /// path: `Table.paintAt` uses it to re-lay a re-sorted table across
    /// whatever mix of viewport and scrollback rows it currently occupies,
    /// so a table stays consistently sorted after it scrolls back into
    /// view. The alt screen has no scrollback, so a negative `row` there
    /// is always null.
    pub fn rowAtSigned(self: *const Layer, row: i64) ?[]Cell {
        const height_i: i64 = @intCast(self.height);
        if (row >= height_i) return null;
        if (self.vt.on_alt) {
            if (row < 0) return null;
            const start: usize = @as(usize, @intCast(row)) * self.width;
            return self.vt.alt_cells.?[start .. start + self.width];
        }
        if (row >= 0) return self.rowSlice(self.physicalRow(@intCast(row)));
        const above: usize = @intCast(-row);
        if (above > self.history_len) return null;
        // `above == 1` is the row immediately above the viewport top.
        const cap = self.capacity();
        return self.rowSlice((self.viewport_start + cap - above) % cap);
    }

    /// The single mutable cell at signed live-viewport row `row` (see
    /// `rowAtSigned`) and column `col`, or null if the row isn't retained
    /// or `col` is out of range.
    pub fn cellSigned(self: *const Layer, row: i64, col: usize) ?*Cell {
        if (col >= self.width) return null;
        const cells = self.rowAtSigned(row) orelse return null;
        return &cells[col];
    }

    /// One cell position while walking retained content: `row` is the
    /// signed live-viewport coordinate `rowAtSigned` takes (0 = viewport
    /// top, negative reaches into scrollback).
    const WalkPos = struct { row: i64, col: usize };

    /// The next content cell after `p` in reading order (left to right,
    /// then down a row), or null past the bottom of the live viewport.
    fn walkNext(self: *const Layer, p: WalkPos) ?WalkPos {
        if (p.col + 1 < self.width) return .{ .row = p.row, .col = p.col + 1 };
        const nr = p.row + 1;
        if (nr >= @as(i64, @intCast(self.height))) return null;
        return .{ .row = nr, .col = 0 };
    }

    /// The previous content cell before `p` in reading order, or null past
    /// the oldest retained scrollback row.
    fn walkPrev(self: *const Layer, p: WalkPos) ?WalkPos {
        if (p.col > 0) return .{ .row = p.row, .col = p.col - 1 };
        const pr = p.row - 1;
        if (pr < -@as(i64, @intCast(self.history_len))) return null;
        return .{ .row = pr, .col = self.width -| 1 };
    }

    fn walkStep(self: *const Layer, p: WalkPos, dir: MetadataSpanDir) ?WalkPos {
        return switch (dir) {
            .next => self.walkNext(p),
            .prev => self.walkPrev(p),
        };
    }

    /// A cell counts as holding a visible character (vs. an icon-only or
    /// padding cell) when its grapheme is more than whitespace -- what
    /// `adjacentMetadataSpan` skips leading cells for.
    fn cellHasText(c: *const Cell) bool {
        return std.mem.trim(u8, c.grapheme(), " ").len != 0;
    }

    /// From content cell `(above, col)` -- `above` in `SelectionPoint`'s
    /// scroll-stable coordinate -- find the first visible character of the
    /// metadata-id span adjacent in `dir`. The span the start cell already
    /// belongs to is stepped over (its metadata id, including any untagged
    /// cells embedded in that id's run, e.g. the inter-column gaps of a
    /// `glyphwire-ls -l` row), as are untagged cells between spans.
    ///
    /// The result is the span's *focus* cell when it has one
    /// (`Cell.meta_focus` -- what a `focus` table column or a
    /// `tag_metadata` with `focus` sets), else its first cell carrying a
    /// non-blank grapheme, so a leading icon or padding cell tagged with
    /// the span's id is skipped; a span with neither falls back to its
    /// first cell. That ordering is what puts Ctrl+PgUp on the first
    /// character of the *filename* in a `glyphwire-ls -l` row, whose
    /// single span starts back at the permissions column.
    ///
    /// null when there's no further span in that direction within retained
    /// content.
    ///
    /// Server-side on purpose: a client never has to round-trip the grid
    /// with `get_cells` to scan for spans (see decisions.md, Metadata).
    pub fn adjacentMetadataSpan(self: *const Layer, above: i64, col: usize, dir: MetadataSpanDir) ?MetadataSpanHit {
        if (self.width == 0) return null;

        const start_row: i64 = -above;
        const start_id: ?MetadataHandle =
            if (self.cellSigned(start_row, col)) |c| c.metadata_id else null;

        // Phase 1: leave the current span. Skip cells tagged `start_id`
        // (or untagged -- that also carries us across the gaps inside a
        // gapped same-id run) until the first cell tagged with a different
        // id; that id names the neighbouring span.
        var pos = WalkPos{ .row = start_row, .col = col };
        const target_id: MetadataHandle = while (self.walkStep(pos, dir)) |next| {
            pos = next;
            const c = self.cellSigned(pos.row, pos.col) orelse return null;
            const mid = c.metadata_id orelse continue;
            if (start_id == null or mid != start_id.?) break mid;
        } else return null;

        // Phase 2: find the span's first cell in reading order. Walking
        // `.next` already stopped on it; walking `.prev` stopped on the
        // span's last cell, so step back over its `target_id` cells
        // (crossing untagged gaps) to the earliest one.
        var span_start = pos;
        if (dir == .prev) {
            var scan = pos;
            while (self.walkPrev(scan)) |p| : (scan = p) {
                const c = self.cellSigned(p.row, p.col) orelse break;
                if (c.metadata_id) |mid| {
                    if (mid != target_id) break;
                    span_start = p;
                }
            }
        }

        // Phase 3: the span's focus cell if it declared one (see
        // `Cell.meta_focus`), else its first cell holding a visible
        // character. Both are found in the same forward walk, so a span
        // with no focus cell costs nothing extra: remember the first
        // visible character as we pass it and keep going until either the
        // focus cell turns up or the span ends.
        var scan = span_start;
        var first_text: ?WalkPos = null;
        while (self.cellSigned(scan.row, scan.col)) |c| {
            if (c.metadata_id) |mid| {
                if (mid != target_id) break;
                if (c.meta_focus) return .{ .above = -scan.row, .col = scan.col, .id = target_id };
                if (first_text == null and cellHasText(c)) first_text = scan;
            }
            scan = self.walkNext(scan) orelse break;
        }
        if (first_text) |p| return .{ .above = -p.row, .col = p.col, .id = target_id };

        // All-icon / all-blank span: land on its first cell.
        return .{ .above = -span_start.row, .col = span_start.col, .id = target_id };
    }

    /// Returns the row `rows_above_viewport` above the current viewport
    /// (0 = the row immediately above viewport row 0), or null if that
    /// much history hasn't been retained (either scrolled past
    /// `scrollback_rows` already, or never scrolled that far yet).
    pub fn scrollbackRow(self: *const Layer, rows_above_viewport: usize) ?[]const Cell {
        if (rows_above_viewport >= self.history_len) return null;
        const cap = self.capacity();
        const physical = (self.viewport_start + cap - 1 - rows_above_viewport) % cap;
        return self.rowSlice(physical);
    }

    /// Row of cells to display at viewport row `row` (0..height) when the
    /// on-screen view has been scrolled back by `offset` rows of history --
    /// `offset` 0 is the live viewport (same content `cell()` reads),
    /// `offset` `history_len` shows the oldest retained history at the top.
    /// This is display-only: it never touches `viewport_start` or
    /// `history_len` the way `scrollOne` does, so scrolling the view back
    /// to look at output doesn't disturb where new writes land.
    ///
    /// `offset` is clamped to `history_len` internally so a caller-tracked
    /// scroll position doesn't have to be re-clamped on every call (and
    /// can't read past what's actually retained even if it's stale).
    pub fn viewRow(self: *const Layer, offset: usize, row: usize) []const Cell {
        // The alt screen has no scrollback -- `offset` is meaningless,
        // every row comes straight from `vt.alt_cells`.
        if (self.vt.on_alt) {
            const start = row * self.width;
            return self.vt.alt_cells.?[start .. start + self.width];
        }
        const clamped_offset = @min(offset, self.history_len);
        if (row < clamped_offset) {
            return self.scrollbackRow(clamped_offset - 1 - row).?;
        }
        return self.rowSlice(self.physicalRow(row - clamped_offset));
    }

    /// Moves the scrollback view offset (see `view_scroll`). `offset`, if
    /// given, is the absolute target in rows; `delta` is then added; the
    /// result is clamped to `0..history_len`. Returns the resulting
    /// offset. Both null is a pure query (returns the current offset
    /// unchanged). This is display-only -- it never touches
    /// `viewport_start`/`history_len` or where writes land.
    pub fn scrollView(self: *Layer, offset: ?usize, delta: ?i64) usize {
        var target: i64 = if (offset) |o| @intCast(o) else @intCast(self.view_scroll);
        if (delta) |d| target += d;
        self.view_scroll = @intCast(std.math.clamp(target, 0, @as(i64, @intCast(self.history_len))));
        self.touchRender();
        return self.view_scroll;
    }

    /// Scrolls the viewport down by one row: the current top row becomes
    /// history (evicting the oldest history row once `scrollback_rows`
    /// is full), and a fresh blank row appears at the bottom.
    /// Forgets the scrollback: `history_len` back to 0 and the view back
    /// on the live tail. The history rows themselves aren't wiped --
    /// nothing reads past `history_len`, and the next scroll overwrites
    /// them. A selection reaching into history is dropped with it. Backs
    /// `ED 3` (`csiEraseDisplay`).
    pub fn clearHistory(self: *Layer) void {
        if (self.history_len == 0) return;
        self.history_len = 0;
        self.view_scroll = 0;
        self.sel.dropHistory();
        _ = self.setScrollOffset(self.effectiveScrollOffset());
        self.revision += 1;
        self.touchRender();
    }

    pub fn scrollOne(self: *Layer) void {
        self.history_len = @min(self.history_len + 1, self.scrollback_rows);
        // Keep a selection pinned to its content (see `SelectionPoint`).
        self.sel.noteScrolled(self.history_len);
        // Tables, unlike highlights, are placed by row: pin each one's
        // `top_live` to its content so a later `repaint` / header
        // hit-test (`Table.headerColumnAt`) still finds it after output
        // has pushed it up. (Region scrolls and `resize` don't adjust
        // this -- a full-screen program owns the screen then, and a
        // resize rebuilds the ring and the client re-renders anyway.)
        if (self.tables.count() > 0) {
            var it = self.tables.valueIterator();
            while (it.next()) |t| t.top_live -= 1;
        }
        if (self.outlines.count() > 0) {
            var it = self.outlines.valueIterator();
            while (it.next()) |o| o.top_live -= 1;
        }
        // If the view is currently scrolled back, follow the incoming row
        // so the content the user is looking at stays at the same screen
        // position while new output piles up below it -- terminal-style.
        // Caps at `history_len`, so once scrollback is full the oldest
        // viewed row is evicted and the view drifts toward the tail.
        if (self.view_scroll > 0) self.view_scroll = @min(self.view_scroll + 1, self.history_len);
        self.viewport_start = (self.viewport_start + 1) % self.capacity();
        for (self.rowSlice(self.physicalRow(self.height - 1))) |*c| c.* = .{};
        // The scroll primitive under `resolveRow` (explicit rows from
        // `set_property`/`draw_*`) and every write path; a bump here covers
        // all of them even where the caller itself doesn't bump.
        self.touchRender();
    }

    /// The inverse of `scrollOne`: pulls the most recent history row back
    /// down into the viewport, so the content moves down one row and the
    /// bottom row leaves the viewport. Only `reflowAt` uses this -- output
    /// never un-scrolls -- and it is a no-op once history is exhausted.
    /// The row that ends up at the bottom is whatever the ring already
    /// held there; every caller overwrites or blanks it.
    fn unscrollOne(self: *Layer) void {
        if (self.history_len == 0) return;
        self.history_len -= 1;
        self.viewport_start = (self.viewport_start + self.capacity() - 1) % self.capacity();
        if (self.view_scroll > 0) self.view_scroll -= 1;
        if (self.tables.count() > 0) {
            var it = self.tables.valueIterator();
            while (it.next()) |t| t.top_live += 1;
        }
        if (self.outlines.count() > 0) {
            var it = self.outlines.valueIterator();
            while (it.next()) |o| o.top_live += 1;
        }
        self.touchRender();
    }

    /// Opens (`delta > 0`) or closes (`delta < 0`) `|delta|` rows directly
    /// below live-viewport row `at_row`, moving the content *above* the
    /// split and leaving the content *below* it where it is. This is what
    /// a layer component whose height changed needs -- an `Outline` node
    /// expanding or collapsing -- and the one place in `Layer` where
    /// content grows anywhere other than the bottom.
    ///
    /// **Growth goes upward, into scrollback.** The viewport's height is
    /// fixed by the window, so `delta` extra rows of content mean `delta`
    /// rows have to leave it, and the only exit that *preserves* them is
    /// the top. So rows at and above `at_row` shift up by `delta` (the
    /// topmost passing into history) and rows below it do not move at all.
    /// On screen the component's header rises while the shell prompt under
    /// it, a later command's output and the live prompt all stay put --
    /// which is the same thing that happens when ordinary output arrives,
    /// and is why this reads as natural rather than as the grid lurching.
    /// Growing *downward* would have to push the bottom rows off the
    /// viewport, where there is no ring to catch them, and they would
    /// simply be lost.
    ///
    /// A negative `delta` is the mirror image: the `|delta|` rows below
    /// `at_row` are dropped, the content above comes back down out of
    /// history, and the content below stays put. Expanding at `H` by `d`
    /// and then collapsing at `H - d` by `-d` restores the original grid,
    /// which is what makes a toggle round-trip.
    ///
    /// Three things bound what this can promise:
    ///
    /// - Rows pushed past `scrollback_rows` are evicted, exactly as they
    ///   are for ordinary output, and a later collapse cannot bring them
    ///   back. A layer created with no scrollback at all therefore loses
    ///   its top rows outright.
    /// - A collapse needs `|delta|` rows of history to pull down. With
    ///   less (the component sits near the oldest retained row) the
    ///   shortfall is taken off the bottom instead: the content below
    ///   moves *up* by the remainder and blank rows appear at the bottom.
    ///   The gap always closes by the full `delta` either way.
    /// - The alt screen (`vt.alt_cells`) is a flat buffer with no scrollback,
    ///   so there is nowhere for displaced rows to go and this is a no-op.
    ///
    /// The selection is dropped rather than re-pinned, the same call
    /// `resize` makes for the same reason: the rows it referred to have
    /// moved by two different amounts depending on which side of the split
    /// they sat on, and a selection spanning the split has no correct
    /// answer at all.
    pub fn reflowAt(self: *Layer, at_row: i64, delta: i64) error{OutOfMemory}!void {
        if (delta == 0) return;
        if (self.vt.on_alt) return;

        const height_i: i64 = @intCast(self.height);
        if (at_row >= height_i) return;

        // How far the ring itself moves, and so how far the content
        // *above* the split travels. Growing scrolls up by the full
        // `delta`; shrinking can only come back down as far as history
        // actually reaches (see the doc comment's third bullet).
        const pull: i64 = if (delta < 0) @min(-delta, @as(i64, @intCast(self.history_len))) else 0;
        const shift: i64 = if (delta > 0) -delta else pull;

        // The first row of content that survives *below* the split. A
        // collapse drops `-delta` rows, so its survivors start that much
        // further down; an expansion drops nothing.
        const removed: i64 = @max(0, -delta);
        // Clamped to retained history so a component sitting deep in
        // scrollback doesn't size the snapshot off the end of the ring.
        const first_below: i64 = @max(at_row + 1 + removed, -@as(i64, @intCast(self.history_len)));

        // Snapshot the rows below the split before the ring moves under
        // us, then lay them back down afterwards at `shift + delta` from
        // where they were. Going through a scratch buffer rather than
        // shuffling the ring in place keeps growing and shrinking as one
        // piece of code instead of two mirrored ones with their own
        // overlap rules, and the cost is one screen's worth of cells on a
        // click.
        const below_count: usize = if (first_below >= height_i) 0 else @intCast(height_i - first_below);
        const keep = try self.alloc.alloc(Cell, below_count * self.width);
        defer self.alloc.free(keep);
        for (0..below_count) |i| {
            const dst = keep[i * self.width ..][0..self.width];
            if (self.rowAtSigned(first_below + @as(i64, @intCast(i)))) |src| {
                @memcpy(dst, src);
            } else {
                for (dst) |*c| c.* = .{};
            }
        }

        // Move the ring. Both helpers pin every table's `top_live` to the
        // content as they go; the tables below the split are corrected
        // back below, once we know where the split landed.
        if (delta > 0) {
            var i: i64 = 0;
            while (i < delta) : (i += 1) self.scrollOne();
        } else {
            var i: i64 = 0;
            while (i < pull) : (i += 1) self.unscrollOne();
        }

        // Put the below-content back. Its new home is `shift + delta`
        // rows from its old one, which works out to "didn't move" in
        // every case but a history-starved collapse.
        const below_shift = shift + delta;
        for (0..below_count) |i| {
            const src = keep[i * self.width ..][0..self.width];
            const target = first_below + @as(i64, @intCast(i)) + below_shift;
            if (self.rowAtSigned(target)) |dst| @memcpy(dst, src);
        }

        // Blank whatever is left between the two sides: the freshly opened
        // gap on an expansion, and the rows the below-content vacated at
        // the bottom when a collapse had to take its shortfall from there.
        self.blankSignedRows(at_row + shift + 1, first_below + below_shift - 1);
        self.blankSignedRows(height_i - 1 + below_shift + 1, height_i - 1);

        // Tables below the split shouldn't have travelled with the ring.
        // `scrollOne`/`unscrollOne` moved every one of them by `shift`, so
        // undo that for the ones past the split by putting them on the
        // below-content's `shift + delta` instead.
        if (self.tables.count() > 0) {
            var it = self.tables.valueIterator();
            while (it.next()) |t| {
                if (t.top_live - shift > at_row) t.top_live += delta;
            }
        }
        if (self.outlines.count() > 0) {
            var it = self.outlines.valueIterator();
            while (it.next()) |o| {
                if (o.top_live - shift > at_row) o.top_live += delta;
            }
        }

        self.sel.range = null;
        self.touchRender();
    }

    /// Blanks every retained row from signed live-viewport row `from`
    /// through `to` inclusive, skipping rows that aren't in the ring.
    /// An empty or inverted range does nothing.
    fn blankSignedRows(self: *Layer, from: i64, to: i64) void {
        var r = from;
        while (r <= to) : (r += 1) {
            if (self.rowAtSigned(r)) |cells| {
                for (cells) |*c| c.* = .{};
            }
        }
    }

    /// Resolves an absolute row a caller named (an explicit
    /// `set_property(cursor)`, or `drawImage`/`drawIcon`'s
    /// anchor row) against the current viewport, scrolling first if it's
    /// at or past the bottom -- the same rule `putAtCursor` already
    /// applies when text advances past the edge. Without this, a client
    /// tracking "the next row" itself (rather than reading the cursor
    /// back) drifts out of sync the moment a scroll happens: text written
    /// through the cursor self-corrects (via `putAtCursor`), but an
    /// explicit row handed to `draw_image`/`draw_icon` didn't -- it just
    /// silently landed past `self.height` and got clamped to nothing,
    /// which is exactly what made glyphwire-ls's icons quietly stop
    /// appearing after enough rows had scrolled by.
    ///
    /// A single explicit row can only ever be at most one row past the
    /// bottom in the intended use (mirroring one write's worth of
    /// advance), but this loops rather than assuming that, so a
    /// caller-supplied row far past the edge still resolves sanely
    /// instead of under-scrolling. Capped at `capacity()` iterations so a
    /// wildly out-of-range value (a hostile or buggy client) can't spin
    /// the server scrolling an unbounded number of times.
    fn resolveRow(self: *Layer, row: usize) usize {
        // The alt screen never scrolls into a ring buffer -- an
        // out-of-range row just clamps to the last line.
        if (self.vt.on_alt) return @min(row, self.height - 1);
        if (row < self.height) return row;
        const overshoot = @min(row - self.height + 1, self.capacity());
        var i: usize = 0;
        while (i < overshoot) : (i += 1) self.scrollOne();
        return self.height - 1;
    }

    /// Resizes the viewport to `new_width` x `new_height`, keeping
    /// `scrollback_rows` unchanged and anchoring content to the bottom
    /// (newest) row -- the model the host wants when its window is
    /// resized (`Context.resize` / `Server.reportResize`):
    ///
    /// - **Grow height:** rows that had scrolled off the top come back
    ///   down out of history into the now-taller viewport; blank filler
    ///   rows appear at the top only once history is exhausted.
    /// - **Shrink height:** the top rows are pushed up into history
    ///   rather than discarded, so a later grow brings them back. Only
    ///   rows that overflow the new `height + scrollback_rows` capacity
    ///   are evicted, oldest first -- the same eviction `scrollOne` does.
    /// - **Width:** each row is clipped (shrink) or blank-padded on the
    ///   right (grow). No reflow, matching `insertCells`/`deleteCells`'s
    ///   row-scoped model.
    ///
    /// The cursor is clamped back into the new bounds. A no-op if the
    /// size is unchanged. Rebuilds the ring buffer from scratch; the only
    /// failure mode is the new allocation itself.
    pub fn resize(self: *Layer, new_width: usize, new_height: usize) !void {
        std.debug.assert(new_width > 0 and new_height > 0);
        if (new_width == self.width and new_height == self.height) return;
        // The ring buffer is rebuilt below, so any selection's row math is
        // about to be meaningless -- drop it rather than try to re-anchor.
        // Highlights are keyed by metadata id, not rows, so they carry
        // over untouched (their cells keep their tags through the reflow).
        self.sel.range = null;

        const old_cap = self.capacity();
        // Meaningful rows in oldest -> newest logical order: `history_len`
        // history rows followed by `height` viewport rows. `oldest_phys`
        // is the physical index of the first (oldest) one; logical row
        // `l` is physical `(oldest_phys + l) % old_cap`.
        const meaningful = self.history_len + self.height;
        const oldest_phys = (self.viewport_start + old_cap - self.history_len) % old_cap;

        const new_cap = new_height + self.scrollback_rows;
        const new_buf = try self.alloc.alloc(Cell, new_width * new_cap);
        for (new_buf) |*c| c.* = .{};

        // Keep the newest `keep` logical rows; anything older overflows
        // the new capacity and is dropped. The new buffer is laid out
        // un-wrapped -- history in physical rows [0, scrollback_rows),
        // viewport in [scrollback_rows, scrollback_rows + new_height) --
        // so the new `viewport_start` is just `scrollback_rows`.
        const keep = @min(meaningful, new_cap);
        const copy_w = @min(self.width, new_width);
        var kept: usize = 0;
        while (kept < keep) : (kept += 1) {
            const l = meaningful - keep + kept; // logical row, oldest kept first
            const src_phys = (oldest_phys + l) % old_cap;
            // Newest kept row (l == meaningful-1) lands on the last
            // viewport row; earlier rows fill upward from there.
            const dst_phys = self.scrollback_rows + new_height - keep + kept;
            const src_row = self.buf[src_phys * self.width ..][0..copy_w];
            const dst_row = new_buf[dst_phys * new_width ..][0..copy_w];
            @memcpy(dst_row, src_row);
        }

        self.alloc.free(self.buf);
        self.buf = new_buf;
        const old_height = self.height;
        self.width = new_width;
        self.height = new_height;
        self.viewport_start = self.scrollback_rows;
        self.history_len = if (keep > new_height) keep - new_height else 0;
        if (self.view_scroll > self.history_len) self.view_scroll = self.history_len;

        // The rebuild is bottom-anchored: the newest meaningful row stays
        // on the last viewport row, so every retained row's distance from
        // the bottom is unchanged and a table's or outline's pinned
        // `top_live` (see `scrollOne`) shifts by exactly the height delta.
        // Keeps a header or marker click resolving after a window resize,
        // when the client that drew it (`glyphwire-ls -l`, `gw-grep`) has
        // long since exited and nothing re-renders it.
        const dh = @as(i64, @intCast(new_height)) - @as(i64, @intCast(old_height));
        if (self.tables.count() > 0) {
            var it = self.tables.valueIterator();
            while (it.next()) |t| t.top_live += dh;
        }
        if (self.outlines.count() > 0) {
            var it = self.outlines.valueIterator();
            while (it.next()) |o| o.top_live += dh;
        }

        // The cursor rides the content for exactly the same reason, and
        // it's the one piece of this that a client can't recompute for
        // itself: glyphwire-shell asks `get_cursor` where its next prompt
        // goes after a foreground command, so a cursor left on its old row
        // index while the rows around it moved puts that prompt on top of
        // retained output. Only the *primary* cursor indexes the ring
        // buffer -- the alt buffer is rebuilt blank below, so its cursor
        // is merely clamped by the lines that follow.
        const primary: *Cursor = if (self.vt.on_alt) &self.vt.stashed_cursor else &self.cursor;
        primary.row = shiftRowByHeightDelta(primary.row, dh, new_height);

        if (self.cursor.row >= new_height) self.cursor.row = new_height - 1;
        if (self.cursor.col >= new_width) self.cursor.col = new_width - 1;

        // B1 screen model: the alt buffer is a flat width*height grid, so
        // a size change means a fresh (blank) one -- a full-screen program
        // redraws on the SIGWINCH anyway. The scroll region resets to the
        // full new height for the same reason (a program keeping margins
        // re-sends DECSTBM after a resize).
        if (self.vt.alt_cells) |old| {
            self.alloc.free(old);
            const fresh = try self.alloc.alloc(Cell, new_width * new_height);
            for (fresh) |*c| c.* = .{};
            self.vt.alt_cells = fresh;
        }
        self.vt.scroll_top = 0;
        self.vt.scroll_bot = new_height - 1;
        // Custom tab stops keep their columns; columns a wider grid adds
        // get the default stops.
        if (self.vt.tab_stops) |old| {
            const fresh = try self.alloc.alloc(bool, new_width);
            for (fresh, 0..) |*s, col| s.* = if (col < old.len) old[col] else col % tab_width == 0;
            self.alloc.free(old);
            self.vt.tab_stops = fresh;
        }
        if (self.vt.stashed_cursor.row >= new_height) self.vt.stashed_cursor.row = new_height - 1;
        if (self.vt.stashed_cursor.col >= new_width) self.vt.stashed_cursor.col = new_width - 1;
        // A smaller content grid can leave the viewport parked past the
        // end of it (see `maxScroll`).
        _ = self.setScrollOffset(self.effectiveScrollOffset());
        self.touchRender();
    }

    /// Appends `text` as grapheme clusters starting at the layer's cursor,
    /// advancing and wrapping it at the layer edge. Naive UTF-8 codepoint
    /// splitting for now, not real grapheme segmentation (UAX #29) — see
    /// decisions.md; swapping in the real thing later shouldn't change this
    /// shape. `bg` is `null` for "leave whatever background is already on
    /// each cell touched" (`write_text`'s `transparent_bg: true`) rather
    /// than resetting it to `default_style.bg` -- see that field's doc
    /// comment on `WriteTextParams` for why this needed splitting `fg`/`bg`
    /// out of a single `Style` value instead of just making `Style.bg`
    /// itself optional (`Cell.style` still always holds a concrete,
    /// resolved `Style` -- only the *write* can decline to touch it).
    ///
    /// C0 control bytes in `text` move the cursor instead of being drawn
    /// (see `consumeControl`): `\n` / `\v` / `\f` act as newline (carriage
    /// return + line feed, matching a cooked terminal so `"a\nb"` puts `b`
    /// at column 0 of the next row rather than staircasing; a `pty_mode`
    /// layer takes them as a plain line feed), `\r` returns
    /// to column 0, `\t` advances to the next tab stop, `\b` steps
    /// back one column; every other C0 byte and DEL is dropped. `ESC ...`
    /// sequences are recognized and discarded, not interpreted -- glyphwire
    /// has no VT100 layer (see `EscState`). This is baseline terminal
    /// behavior, not escape-code parsing.
    ///
    /// Escape stripping does not span calls: a sequence still open when
    /// this call's `text` runs out is abandoned (`esc_state` reset to
    /// `.ground`), so an unterminated `ESC ] ...` or a trailing `ESC [`
    /// can't swallow whatever the next `writeText` writes. See `EscState`.
    pub fn writeText(self: *Layer, text: []const u8, fg: Color, bg: ?Background) !void {
        return self.writeTextTagged(text, fg, bg, null);
    }

    /// Same as `writeText`, but every cell the text touches also gets
    /// tagged with `metadata_id` (see `Cell.metadata_id`'s doc comment) --
    /// a separate method rather than a new required param on `writeText`
    /// itself since Zig has no default parameter values, matching this
    /// codebase's existing convention for additive options (`drawIcon`'s
    /// `IconDrawOpts`).
    pub fn writeTextTagged(self: *Layer, text: []const u8, fg: Color, bg: ?Background, metadata_id: ?MetadataHandle) !void {
        return self.writeTextTaggedScaled(text, fg, bg, metadata_id, .x1);
    }

    /// Same as `writeTextTagged`, but every cell a grapheme lands in also
    /// carries `scale` (`Cell.text_scale`) -- see `TextScale`'s doc
    /// comment for what that does and doesn't reserve. A separate method
    /// rather than a new required param on `writeTextTagged` itself, same
    /// "Zig has no default parameter values" reason `writeTextTagged`
    /// itself got split out from `writeText`.
    pub fn writeTextTaggedScaled(self: *Layer, text: []const u8, fg: Color, bg: ?Background, metadata_id: ?MetadataHandle, scale: TextScale) !void {
        return self.writeTextOpts(text, fg, bg, .{ .metadata_id = metadata_id, .scale = scale });
    }

    /// The options `write_text` can carry beyond text and colour. Every
    /// field defaults to the original behaviour, so `writeTextOpts(t, fg,
    /// bg, .{})` is `writeText`.
    pub const WriteOpts = struct {
        metadata_id: ?MetadataHandle = null,
        scale: TextScale = .x1,
        /// Clip the run to this many display columns from where it starts
        /// (further clamped to the layer's right edge): a grapheme that
        /// would cross the limit is dropped along with everything after
        /// it, and the run never wraps. A wide character that only half
        /// fits leaves a blank cell in its place. The host's East Asian
        /// Width table decides, so a client never measures text itself.
        max_cols: ?usize = null,
        /// With `max_cols`: fill the rest of the clipped span with blank
        /// cells in `bg`, leaving the cursor at the span's end -- a whole
        /// row of a list or a status bar in one write, whatever the text
        /// length. Ignored without `max_cols`.
        pad: bool = false,
        /// `Cell.selectable` for every cell the write touches, padding
        /// and a scaled glyph's fill included.
        selectable: bool = true,
        /// `Cell.masked` for every cell the write touches, padding
        /// included. Implies `selectable = false`.
        masked: bool = false,
        /// What a selection copies for each glyph this write draws, in
        /// place of the glyph itself (`Cell.copy_alt`). Meant for a
        /// one-glyph write drawing a stand-in for some other text; a
        /// longer write repeats it for every glyph.
        copy_text: ?[]const u8 = null,
        /// How a selection joins the row this write ends on to the next
        /// (`LineJoin`), set on the last glyph it draws.
        line_join: LineJoin = .newline,
        /// The underline every cell the *text* touches carries (see
        /// `Underline`). Deliberately not applied to `pad`'s blanks: a
        /// padded status bar or list row would otherwise draw its
        /// underline out to the full width, and a diagnostic squiggle
        /// should stop at the end of the token it marks.
        underline: UnderlineStyle = .{},
        /// A line through every glyph the write draws (`Style.strike`).
        /// Like `underline`, never applied to `pad`'s blanks.
        strikethrough: bool = false,
    };

    /// `writeTextTaggedScaled` with `WriteOpts` -- a single styled run.
    pub fn writeTextOpts(self: *Layer, text: []const u8, fg: Color, bg: ?Background, opts: WriteOpts) !void {
        const runs = [_]TextRun{.{ .text = text, .fg = fg, .bg = bg, .metadata_id = opts.metadata_id, .scale = opts.scale, .underline = opts.underline, .strikethrough = opts.strikethrough }};
        return self.writeRuns(&runs, .{ .max_cols = opts.max_cols, .pad = opts.pad, .pad_fg = fg, .pad_bg = bg, .pad_metadata_id = opts.metadata_id, .selectable = opts.selectable, .masked = opts.masked, .copy_text = opts.copy_text, .line_join = opts.line_join });
    }

    /// One styled piece of a `write_text`: its text and everything that
    /// styles it, already resolved (the dispatcher fills a span's omitted
    /// fields from the message's top level). `bg` null leaves each touched
    /// cell's background alone (`transparent_bg`).
    pub const TextRun = struct {
        text: []const u8,
        fg: Color,
        bg: ?Background,
        metadata_id: ?MetadataHandle = null,
        scale: TextScale = .x1,
        /// See `WriteOpts.underline`. Per run, like `fg`, so one write can
        /// underline part of a row -- which is the whole point for a
        /// diagnostic span inside a syntax-coloured line.
        underline: UnderlineStyle = .{},
        /// See `WriteOpts.strikethrough`. Per run, like `underline`.
        strikethrough: bool = false,
    };

    /// The whole-write options for `writeRuns`: clipping and padding apply
    /// across every run together, and the padding takes `pad_*`.
    pub const RunsOpts = struct {
        /// See `WriteOpts.max_cols` -- counted from where the first run
        /// starts.
        max_cols: ?usize = null,
        /// See `WriteOpts.pad`.
        pad: bool = false,
        pad_fg: Color = default_style.fg,
        pad_bg: ?Background = default_style.bg,
        pad_metadata_id: ?MetadataHandle = null,
        /// See `WriteOpts.selectable` -- covers every run and the padding.
        selectable: bool = true,
        /// See `WriteOpts.masked` -- covers every run and the padding.
        masked: bool = false,
        /// See `WriteOpts.copy_text` -- every glyph of every run.
        copy_text: ?[]const u8 = null,
        /// See `WriteOpts.line_join` -- the last glyph of the last run
        /// that drew one.
        line_join: LineJoin = .newline,
    };

    /// Writes `runs` back to back as one `write_text` -- `write_text`'s
    /// `spans` form, and what the single-run form dispatches to. One SGR
    /// pen and one escape machine span the whole call, exactly as if the
    /// runs' text had been one string; only the styling changes at a run
    /// boundary. All text is validated as UTF-8 before anything is drawn,
    /// so a bad run can't leave the others half-written.
    pub fn writeRuns(self: *Layer, runs: []const TextRun, opts: RunsOpts) !void {
        for (runs) |r| _ = try std.unicode.Utf8View.init(r.text);
        self.write_copy_alt = if (opts.copy_text) |t| try self.internCopyText(t) else 0;
        defer self.write_copy_alt = 0;
        self.write_selectable = opts.selectable and !opts.masked;
        defer self.write_selectable = true;
        self.write_masked = opts.masked;
        defer self.write_masked = false;
        // The clip limit is an absolute column on the starting row.
        const clip_end: ?usize = if (opts.max_cols) |n| @min(self.cursor.col + n, self.width) else null;
        // Where the last glyph landed, for `line_join`.
        var last_glyph: ?GlyphPos = null;

        // The SGR pen is call-local: an `ESC [ ... m` colour is honoured
        // only for the rest of *this* `write_text`, never carried into
        // the next call. Cross-call persistence was tried and reverted --
        // every `glyphwire-shell` prompt/echo write passes the default
        // fg, so a colour a mirrored program left un-reset (a `cat`'d
        // file with raw escapes, an interrupted program) would poison the
        // prompt and everything after it. See `EscState` / `Vt.pen`.
        // A `pty_mode` layer opts out: it carries one program's byte
        // stream and wants the colour to persist until that program
        // resets it.
        if (!self.pty_mode) self.vt.pen = .{};

        runs: for (runs) |r| {
            var it = (std.unicode.Utf8View.init(r.text) catch unreachable).iterator();
            while (it.nextCodepointSlice()) |cp_bytes| {
                if (cp_bytes.len == 1 and try vt.consumeControl(self, cp_bytes[0])) continue;
                const eff = self.vt.pen.resolve(r.fg, r.bg, .{ .underline = r.underline, .strike = r.strikethrough });
                // While the shifted-in charset is line drawing, a byte in
                // `` ` ``..`~` names a box-drawing/symbol glyph, not itself
                // -- see `EscState`'s charset paragraph and `acsGraphic`.
                const line_drawing = if (self.vt.shift_out) self.vt.g1_line_drawing else self.vt.g0_line_drawing;
                if (line_drawing and cp_bytes.len == 1 and cp_bytes[0] >= '`' and cp_bytes[0] <= '~') {
                    var buf: [4]u8 = undefined;
                    const n = std.unicode.utf8Encode(vt.acsGraphic(cp_bytes[0]), &buf) catch unreachable;
                    if (self.vt.insert_mode) self.insertCellsFill(1, .{});
                    last_glyph = self.putRunGlyph(buf[0..n], 1, eff.fg, eff.bg, r.metadata_id, r.scale, eff.deco, clip_end) orelse break :runs;
                    vt.noteLastGlyph(self, buf[0..n], 1, eff.fg, eff.bg, eff.deco);
                    continue;
                }
                const cp = std.unicode.utf8Decode(cp_bytes) catch 0xFFFD;
                if (cp_bytes.len > 1 and vt.consumeInSequence(self, cp)) continue;
                // A program's own column math (wcwidth) gives combining
                // marks, ZWJ and variation selectors no width, so on a
                // pty stream they join the character before them rather
                // than taking a cell. Only there: a native client lays
                // out with `codepointWidth`, which still counts them as 1.
                if (self.pty_mode and isZeroWidth(cp)) {
                    vt.attachZeroWidth(self, cp_bytes);
                    continue;
                }
                const w = codepointWidth(cp);
                if (self.vt.insert_mode) self.insertCellsFill(w, .{});
                last_glyph = self.putRunGlyph(cp_bytes, w, eff.fg, eff.bg, r.metadata_id, r.scale, eff.deco, clip_end) orelse break :runs;
                vt.noteLastGlyph(self, cp_bytes, w, eff.fg, eff.bg, eff.deco);
            }
        }
        if (opts.line_join != .newline) {
            if (last_glyph) |g| {
                if (g.row < self.height and g.col < self.width) self.cell(g.row, g.col).line_join = opts.line_join;
            }
        }
        if (clip_end) |end| {
            if (opts.pad) {
                // Padding is not the glyph `copy_text` stands in for.
                self.write_copy_alt = 0;
                while (self.cursor.col < end) self.putAtCursor(" ", 1, opts.pad_fg, opts.pad_bg, opts.pad_metadata_id, .x1, .{});
            }
        }
        // Don't carry a half-consumed `ESC ...` sequence into the next
        // call: a lone trailing `ESC`, a truncated `ESC [ ...`, or an
        // unterminated `ESC ] ...` (OSC) would otherwise leave the
        // machine armed and eat the start of whatever is written next
        // (glyphwire-shell's prompt, the following command's output).
        // See `EscState`. A `pty_mode` layer keeps the machine armed: a
        // sequence its PTY child split across two chunks finishes parsing
        // on the next call rather than drawing its tail as literal text.
        if (!self.pty_mode) {
            self.vt.esc_state = .ground;
            vt.resetOsc(self);
            self.vt.csi_len = 0;
            self.vt.shift_out = false;
            self.vt.g0_line_drawing = false;
            self.vt.g1_line_drawing = false;
        }
        self.revision += 1;
        self.render_gen +%= 1;
    }

    // ── Grid operations shared with the VT machine ──────────────────────
    //
    // The erase background, band scrolling, line feeds, glyph placement
    // and cell insert/delete below serve plain writes and `vt.zig` alike.
    // That is why they are `pub`: the machine lives in its own file but
    // drives this same grid. What only escapes use (the pending-wrap
    // column, the scroll region, the alternate screen) is in `vt.zig`.

    /// The background an erase paints with: the SGR pen's current
    /// background, or null for the transparent default when it has none.
    /// This is BCE ("background colour erase"), which xterm-256color
    /// advertises -- nvim paints the rest of a coloured line with `EL`
    /// rather than spaces, and without it every colorscheme background
    /// shows holes.
    pub fn eraseBg(self: *const Layer) ?Color {
        const eff = self.vt.pen.resolve(default_style.fg, null, .{});
        return switch (eff.bg orelse return null) {
            .color => |c| c,
            else => null,
        };
    }

    /// A blank cell carrying the erase background (`eraseBg`), for the
    /// rows and cells an `IL`/`DL`/`SU`/`SD`/`ICH`/`DCH` or a scrolling
    /// line feed brings in.
    pub fn eraseBlank(self: *const Layer) Cell {
        var blank: Cell = .{};
        if (self.eraseBg()) |c| blank.style.bg = .{ .color = c };
        return blank;
    }

    pub fn clampCursor(self: *const Layer, c: Cursor) Cursor {
        return .{
            .row = @min(c.row, self.height - 1),
            .col = @min(c.col, self.width - 1),
        };
    }

    /// Which way `scrollRange` / `moveContent` shift a band: `.up` moves
    /// content toward the top of the band (blank rows appear at the
    /// bottom), `.down` the reverse -- the same sense as CSI SU / SD.
    pub const ScrollDir = enum { up, down };

    /// Scrolls rows `[top, bot]` of the active screen by `n` within that
    /// band -- `.up` moves content toward `top` (blank rows appear at
    /// `bot`), `.down` the reverse. No scrollback: rows pushed past a
    /// margin are gone. Backs a line feed at the bottom margin, `SU`/`SD`,
    /// `IL`/`DL` and `RI`.
    fn scrollRange(self: *Layer, top: usize, bot: usize, n_in: usize, dir: ScrollDir) void {
        self.scrollRangeFill(top, bot, n_in, dir, .{});
    }

    /// `scrollRange`, with the rows it brings in set to `blank` rather
    /// than the default cell -- the VT paths pass `eraseBlank` so new
    /// rows take the pen's background (BCE).
    pub fn scrollRangeFill(self: *Layer, top: usize, bot: usize, n_in: usize, dir: ScrollDir, blank: Cell) void {
        if (bot < top or bot >= self.height) return;
        const span = bot - top + 1;
        const n = @min(n_in, span);
        if (n == 0) return;
        self.sel.noteRangeScrolled(top, bot, n, dir, self.width);
        switch (dir) {
            .up => {
                var r = top;
                while (r + n <= bot) : (r += 1) @memcpy(self.liveRow(r), self.liveRow(r + n));
                r = bot + 1 - n;
                while (r <= bot) : (r += 1) @memset(self.liveRow(r), blank);
            },
            .down => {
                var r = bot + 1;
                while (r > top + n) {
                    r -= 1;
                    @memcpy(self.liveRow(r), self.liveRow(r - n));
                }
                r = top + n;
                while (r > top) {
                    r -= 1;
                    @memset(self.liveRow(r), blank);
                }
            },
        }
        self.revision += 1;
        self.render_gen +%= 1;
    }

    /// Shifts a band of the content grid vertically in place -- the wire
    /// face of `scrollRange` (which already backs CSI SU/SD and IL/DL),
    /// exposed so a client-scrolled pane doesn't have to retransmit every
    /// visible row on every scroll tick. A TUI editor whose buffer layer
    /// is `scrollback_rows: 0` with the content grid exactly viewport-
    /// sized scrolls by moving the rows it still has and redrawing only
    /// the newly-exposed band.
    ///
    /// `top`/`bot` are an inclusive row range in the content grid,
    /// defaulting to the whole grid (`0` .. `height - 1`); `count` rows
    /// are shifted, clamped to the span. Cells carry their styling, icons
    /// and metadata ids with them (a whole-`Cell` copy). An empty or
    /// out-of-range range, or a zero `count`, is a silent no-op.
    pub fn moveContent(self: *Layer, top: ?usize, bot: ?usize, count: usize, dir: ScrollDir) void {
        self.scrollRange(top orelse 0, bot orelse (self.height -| 1), count, dir);
    }

    /// A line feed (`\n` / VT / FF, and index past the bottom margin).
    /// With a scroll region set (or on the alt screen) it stays inside
    /// `[scroll_top, scroll_bot]`; otherwise it's the classic ring-buffer
    /// advance that feeds the primary screen's scrollback. Only a line
    /// feed *on* the bottom margin scrolls the region: below it (a status
    /// line under a scrolling pane) the cursor just moves down, stopping
    /// at the last row. Either way the row scrolled in takes the pen's
    /// background (`eraseBg`, BCE).
    pub fn lineFeed(self: *Layer) void {
        if (self.vt.on_alt or self.regionActive()) {
            if (self.cursor.row == self.vt.scroll_bot) {
                self.scrollRangeFill(self.vt.scroll_top, self.vt.scroll_bot, 1, .up, self.eraseBlank());
            } else if (self.cursor.row + 1 < self.height) {
                self.cursor.row += 1;
            }
        } else {
            const scrolls = self.cursor.row + 1 >= self.height;
            self.cursor.row = self.resolveRow(self.cursor.row + 1);
            if (scrolls) {
                if (self.eraseBg()) |bg| self.clearFill(self.cursor.row, 0, 1, self.width, bg);
            }
        }
    }

    /// The bytes this layer owes the program writing to it (a `CSI 6n` /
    /// DA / DECRQM answer), or null if none are pending. The returned
    /// slice is valid until the next `writeText`. Drained by the
    /// dispatcher after each `write_text`.
    pub fn takeReply(self: *Layer) ?[]const u8 {
        if (self.vt.reply_len == 0) return null;
        const s = self.vt.reply_buf[0..self.vt.reply_len];
        self.vt.reply_len = 0;
        return s;
    }

    /// Text an OSC 52 in the last `writeText` asked to put on the
    /// clipboard, or null. The caller owns it (freed with this layer's
    /// allocator). Drained by the dispatcher after each `write_text`,
    /// which writes it to the session clipboard. See `vt.execOsc52`.
    pub fn takeClipboard(self: *Layer) ?[]u8 {
        const text = self.vt.clipboard_write orelse return null;
        self.vt.clipboard_write = null;
        return text;
    }

    /// Places one glyph of a `write_text` run: its footprint is its display
    /// width times `scaledPitch(scale)` columns by `scaledPitch(scale)`
    /// rows, and every footprint cell past the glyph's own -- the gap to
    /// its right and the rows below it that the enlarged glyph draws over
    /// -- is filled with blanks in the run's style so they carry its
    /// background and `metadata_id` (see `TextScale`). The rows below are
    /// clipped at the layer's bottom edge rather than scrolling it, and
    /// the cursor stays on the glyph's own row. Returns where the glyph
    /// landed, or null when `clip_end` stops the write: the cells of the
    /// footprint that do fit are blanked instead, never half a glyph.
    fn putRunGlyph(
        self: *Layer,
        bytes: []const u8,
        w: u2,
        fg: Color,
        bg: ?Background,
        metadata_id: ?MetadataHandle,
        scale: TextScale,
        deco: Decoration,
        clip_end: ?usize,
    ) ?GlyphPos {
        const ul = deco.underline;
        const pitch = scaledPitch(scale);
        const footprint = @as(usize, w) * pitch;
        // A scaled glyph's underline belongs at the bottom of the *block*
        // it draws, not under its own cell row -- otherwise the line
        // crosses the middle of a 2x or 3x glyph. So the glyph's row only
        // carries it when the block is one row tall.
        const glyph_row_ul: UnderlineStyle = if (pitch == 1) ul else .{};
        if (clip_end) |end| {
            if (self.cursor.col + footprint > end) {
                while (self.cursor.col < end) self.putAtCursor(" ", 1, fg, bg, metadata_id, .x1, .{});
                return null;
            }
        } else if (footprint > w and self.cursor.col > 0 and self.cursor.col + footprint > self.width) {
            // A scaled glyph wraps whole, like a wide one does in
            // `putAtCursor`.
            self.cursor.col = 0;
            self.cursor.row += 1;
        }
        // The strikethrough goes on the glyph's own cell only: the host
        // draws it from there across the footprint (`Style.strike`).
        self.putAtCursor(bytes, w, fg, bg, metadata_id, scale, .{ .underline = glyph_row_ul, .strike = deco.strike });
        // Read back after the put, which may have wrapped the glyph.
        const row = self.cursor.row;
        const start_col = self.cursor.col - w;
        var extra = footprint - w;
        while (extra > 0 and self.cursor.col < self.width) : (extra -= 1) {
            self.putAtCursor(" ", 1, fg, bg, metadata_id, .x1, .{ .underline = glyph_row_ul });
        }
        const end_col = self.cursor.col;
        var r = row + 1;
        while (r < row + pitch and r < self.height) : (r += 1) {
            // Only the last row of the block gets the line (see above);
            // and if the block is clipped at the layer's bottom edge, the
            // line goes with the rows that were dropped rather than moving
            // up onto a row the glyph still occupies.
            const row_ul: UnderlineStyle = if (r == row + pitch - 1) ul else .{};
            var col = start_col;
            while (col < end_col) : (col += 1) self.blankScaledCell(r, col, @intCast(r - row), fg, bg, metadata_id, row_ul);
        }
        return .{ .row = row, .col = start_col };
    }

    /// A glyph's own cell, in live-screen coordinates: `putRunGlyph`'s
    /// answer.
    const GlyphPos = struct { row: usize, col: usize };

    /// One cell under a scaled glyph (see `putRunGlyph`): a narrow blank
    /// in the run's style, written in place without moving the cursor,
    /// marked as sitting `below` rows under the glyph's own row
    /// (`Cell.under_scaled`). `bg == null` (`transparent_bg`) leaves the
    /// cell's background alone, same as `putAtCursor`.
    fn blankScaledCell(self: *Layer, row: usize, col: usize, below: u2, fg: Color, bg: ?Background, metadata_id: ?MetadataHandle, ul: UnderlineStyle) void {
        self.clearWidePartner(row, col);
        const c = self.cell(row, col);
        c.setGrapheme(" ");
        c.style.fg = fg;
        c.style.underline = ul;
        c.style.strike = false;
        if (bg) |b| c.style.bg = b;
        c.metadata_id = metadata_id;
        c.meta_focus = false;
        c.fg_icon = null;
        c.wide = .narrow;
        c.text_scale = .x1;
        c.under_scaled = below;
        c.selectable = self.write_selectable;
        c.masked = self.write_masked;
        c.copy_alt = 0;
        c.line_join = .newline;
    }

    /// Places one grapheme cluster at the cursor. `w` is its East Asian
    /// display width in cells (1 or 2). A width-2 cluster occupies a
    /// `.wide_lead` cell holding the grapheme plus a blank `.wide_spacer`
    /// to its right; the spacer copies the lead's fg/bg and `metadata_id`
    /// so a background spans the pair and a hit-test on either half
    /// resolves the same. A width-2 cluster that would straddle the right
    /// edge wraps to the next row first. Overwriting either half of an
    /// existing wide pair blanks its orphaned partner.
    ///
    /// The wrap is a line feed (`lineFeed`), so on the alt screen or
    /// inside a scroll region it scrolls the region at its bottom margin
    /// like any other; just stepping the row would overwrite the alt
    /// screen's last row in place. With autowrap off
    /// (DECAWM, `?7l`) there is no wrap: the glyph lands on the last
    /// column(s) and the cursor stays there.
    pub fn putAtCursor(self: *Layer, bytes: []const u8, w: u2, fg: Color, bg: ?Background, metadata_id: ?MetadataHandle, scale: TextScale, deco: Decoration) void {
        if (self.cursor.col + w > self.width) {
            if (self.vt.autowrap) {
                self.cursor.col = 0;
                self.lineFeed();
            } else {
                self.cursor.col = self.width -| w;
            }
        }
        self.cursor.row = self.resolveRow(self.cursor.row);

        const row = self.cursor.row;
        const col = self.cursor.col;

        // Clear any wide pair we're about to land on top of, so no orphan
        // half-glyph is left behind.
        self.clearWidePartner(row, col);
        if (w == 2) self.clearWidePartner(row, col + 1);

        // Narrow write keeps the existing cell untouched except for what a
        // write sets, so `bg == null` (write_text's `transparent_bg`)
        // still leaves the prior background in place.
        var c = self.cell(row, col);
        c.setGrapheme(bytes);
        c.style.fg = fg;
        // Set, not merged, like `fg` -- a write with no underline clears
        // whatever the cell carried before, which is what makes a repaint
        // of a row enough to take a stale squiggle off it.
        c.style.underline = deco.underline;
        c.style.strike = deco.strike;
        if (bg) |b| c.style.bg = b;
        c.metadata_id = metadata_id;
        c.meta_focus = false;
        c.fg_icon = null;
        c.wide = if (w == 2) .wide_lead else .narrow;
        c.text_scale = scale;
        c.under_scaled = 0;
        c.selectable = self.write_selectable;
        c.masked = self.write_masked;
        c.copy_alt = self.write_copy_alt;
        c.line_join = .newline;

        if (w == 2) {
            // The spacer renders nothing of its own; give it the lead's
            // fully resolved style so the background spans the pair, and
            // the lead's `metadata_id` so a hit-test on either half maps
            // to the same entry.
            const s = self.cell(row, col + 1);
            s.* = .{ .style = c.style, .metadata_id = metadata_id, .wide = .wide_spacer, .selectable = c.selectable, .masked = c.masked };
        }

        self.cursor.col += w;
    }

    /// If `(row, col)` is one half of a 2-cell wide character, blank its
    /// other half. A no-op for a narrow cell.
    fn clearWidePartner(self: *Layer, row: usize, col: usize) void {
        if (col >= self.width) return;
        const c = self.cell(row, col);
        switch (c.wide) {
            .narrow => {},
            .wide_lead => if (col + 1 < self.width) {
                const p = self.cell(row, col + 1);
                if (p.wide == .wide_spacer) p.* = .{};
            },
            .wide_spacer => if (col > 0) {
                const p = self.cell(row, col - 1);
                if (p.wide == .wide_lead) p.* = .{};
            },
        }
    }

    /// Repairs any wide pair left inconsistent by an in-row cell shift
    /// (`insertCells` / `deleteCells`): a `.wide_lead` with no `.wide_spacer`
    /// to its right (or sitting on the last column), or a `.wide_spacer`
    /// with no `.wide_lead` to its left, is downgraded to a blank narrow
    /// cell. Keeps a line editor from painting half a wide glyph.
    fn sanitizeWidePairs(self: *Layer, row: usize) void {
        var col: usize = 0;
        while (col < self.width) : (col += 1) {
            const c = self.cell(row, col);
            switch (c.wide) {
                .narrow => {},
                .wide_lead => {
                    const ok = col + 1 < self.width and self.cell(row, col + 1).wide == .wide_spacer;
                    if (!ok) c.* = .{};
                },
                .wide_spacer => {
                    const ok = col > 0 and self.cell(row, col - 1).wide == .wide_lead;
                    if (!ok) c.* = .{};
                },
            }
        }
    }

    /// Shifts cells at and after the cursor's column rightward by `count`
    /// within the cursor's row, opening `count` blank cells at the cursor
    /// -- ECMA-48's ICH (Insert Character), the primitive a line editor
    /// needs to insert into already-drawn text without retransmitting
    /// everything after the insertion point. Cells shifted past the row's
    /// right edge are discarded, matching ICH. Doesn't move the cursor or
    /// touch other rows -- a caller editing a display-wrapped logical line
    /// would need to call this per physical row itself. `count` is
    /// clamped to the cells remaining in the row; a cursor already at or
    /// past the row's right edge is a no-op.
    pub fn insertCells(self: *Layer, count: usize) void {
        self.insertCellsFill(count, .{});
    }

    /// `insertCells`, with the inserted cells set to `blank` -- ICH
    /// passes `eraseBlank` (BCE).
    pub fn insertCellsFill(self: *Layer, count: usize, blank: Cell) void {
        if (count == 0 or self.cursor.col >= self.width) return;
        const row = self.liveRow(self.cursor.row);
        const col = self.cursor.col;
        const n = @min(count, self.width - col);
        const tail_len = self.width - col - n;
        std.mem.copyBackwards(Cell, row[col + n ..][0..tail_len], row[col..][0..tail_len]);
        @memset(row[col..][0..n], blank);
        self.sanitizeWidePairs(self.cursor.row);
        self.revision += 1;
        self.render_gen +%= 1;
    }

    /// Removes `count` cells at and after the cursor's column, shifting
    /// the row's remainder leftward and filling `count` blank cells at
    /// the row's tail -- ECMA-48's DCH (Delete Character), the mirror of
    /// `insertCells`. Doesn't move the cursor. `count` is clamped to the
    /// cells remaining in the row; a cursor already at or past the row's
    /// right edge is a no-op.
    pub fn deleteCells(self: *Layer, count: usize) void {
        self.deleteCellsFill(count, .{});
    }

    /// `deleteCells`, with the cells shifted in at the row's tail set to
    /// `blank` -- DCH passes `eraseBlank` (BCE).
    pub fn deleteCellsFill(self: *Layer, count: usize, blank: Cell) void {
        if (count == 0 or self.cursor.col >= self.width) return;
        const row = self.liveRow(self.cursor.row);
        const col = self.cursor.col;
        const n = @min(count, self.width - col);
        const tail_len = self.width - col - n;
        std.mem.copyForwards(Cell, row[col..][0..tail_len], row[col + n ..][0..tail_len]);
        @memset(row[col + tail_len ..][0..n], blank);
        self.sanitizeWidePairs(self.cursor.row);
        self.revision += 1;
        self.render_gen +%= 1;
    }

    /// Marks cells in `[row, row+row_span) x [col, col+col_span)` (clamped
    /// to the layer's own bounds) as backed by `handle`'s pixels, anchored
    /// at `(row, col)` with **no stretching** -- see decisions.md's Image
    /// section. Each covered cell gets the pixel offset into the source
    /// image it should display, computed from its position relative to the
    /// anchor; `img_w`/`img_h` are the image's natural pixel dimensions
    /// (from `pngDimensions`), `cell_px_w`/`cell_px_h` the session's fixed
    /// cell pixel metrics (`Context.cell_px_w`/`cell_px_h`).
    ///
    /// `scale` is the uniform factor the image is drawn at: `1.0` (the
    /// natural-size original behavior) means each cell samples exactly one
    /// cell's worth of source pixels; `< 1.0` (glyphwire-view's
    /// `--size fit-width`, which shrinks the image to the layer's width)
    /// means each cell samples `cell_px / scale` source pixels, so the
    /// same fixed cell grid still covers the whole, now-smaller rendered
    /// image. The per-cell `offset_x`/`offset_y` stored are always source
    /// pixels; the renderer (host/render.zig's `emitImageCell`) reads
    /// `scale` back to know how far into the source each cell reaches and
    /// how small to draw it. A non-positive `scale` is treated as `1.0`.
    ///
    /// A cell the image doesn't actually reach -- its computed offset
    /// falls at or past the image's own edge, i.e. the image is smaller
    /// than the requested span -- is left untouched rather than blanked,
    /// so drawing a small image over existing content only overwrites what
    /// the image actually covers. Cells the image *does* reach always get
    /// marked, even where the image only partially fills them at the
    /// image's bottom/right edge -- the renderer clips those, not this.
    ///
    /// Row span is resolved one row at a time, scrolling the viewport as
    /// needed exactly like `putAtCursor` does for text -- an image whose
    /// `row_span` reaches past the bottom shouldn't just lose its lower
    /// rows, as clamping `row_end` to `self.height` would (it reads as an
    /// image "clipping" to whatever viewport happened to be current when
    /// it was drawn, instead of interleaving into the flowing output
    /// the way multi-line text does). Only the column span still clips at
    /// `self.width` -- columns never scroll.
    ///
    /// `src` picks a sub-rectangle of the source image to sample from
    /// instead of the whole thing (`ImageSrcRect`, general-purpose
    /// sprite-sheet support) -- `.{}` reproduces the pre-source-rect
    /// behavior exactly. Clamped to the image's own bounds first, so a
    /// rect that starts past the image's edge (or is empty after
    /// clamping) draws nothing, same treatment an oversized `row_span`/
    /// `col_span` already gets.
    pub fn drawImage(
        self: *Layer,
        handle: ImageHandle,
        row: usize,
        col: usize,
        row_span: usize,
        col_span: usize,
        img_w: u32,
        img_h: u32,
        cell_px_w: u32,
        cell_px_h: u32,
        scale: f32,
        src: ImageSrcRect,
    ) void {
        const s: f32 = if (scale > 0) scale else 1.0;
        // Source pixels each cell samples along each axis. At `s == 1` this
        // is exactly `cell_px`, so `src_step * k` lands on the same
        // integers `k * cell_px` did before scale existed and every
        // natural-size draw is unchanged.
        const src_step_x: f32 = @as(f32, @floatFromInt(cell_px_w)) / s;
        const src_step_y: f32 = @as(f32, @floatFromInt(cell_px_h)) / s;

        // The sub-rect's own bounds, clamped to the image's real edge --
        // `avail_*` saturates at 0 rather than underflowing when `src.x`/
        // `src.y` is already past the image, which then makes `eff_*` 0
        // and every cell below fails its `>= src_right`/`src_bottom` test.
        const avail_w: u32 = if (src.x >= img_w) 0 else img_w - src.x;
        const avail_h: u32 = if (src.y >= img_h) 0 else img_h - src.y;
        const eff_w: u32 = if (src.w > 0) @min(src.w, avail_w) else avail_w;
        const eff_h: u32 = if (src.h > 0) @min(src.h, avail_h) else avail_h;
        const src_right = src.x + eff_w;
        const src_bottom = src.y + eff_h;

        const col_end = @min(col + col_span, self.width);
        var display_row = self.resolveRow(row);

        var img_row: usize = 0;
        while (img_row < row_span) : (img_row += 1) {
            if (img_row > 0) {
                if (display_row + 1 >= self.height) {
                    self.scrollOne();
                } else {
                    display_row += 1;
                }
            }

            const offset_y: u32 = src.y + @as(u32, @intFromFloat(@round(@as(f32, @floatFromInt(img_row)) * src_step_y)));
            if (offset_y >= src_bottom) break;

            var c = col;
            while (c < col_end) : (c += 1) {
                const offset_x: u32 = src.x + @as(u32, @intFromFloat(@round(@as(f32, @floatFromInt(c - col)) * src_step_x)));
                if (offset_x >= src_right) continue;

                self.setCellImage(display_row, c, handle, offset_x, offset_y, s, src_right, src_bottom);
            }
        }
        self.revision += 1;
        self.render_gen +%= 1;
    }

    fn setCellImage(self: *Layer, row: usize, col: usize, handle: ImageHandle, offset_x: u32, offset_y: u32, scale: f32, src_right: u32, src_bottom: u32) void {
        self.cell(row, col).style.bg = .{ .image = .{ .handle = handle, .offset_x = offset_x, .offset_y = offset_y, .scale = scale, .src_right = src_right, .src_bottom = src_bottom } };
    }

    /// `scale`/`h_align`/`v_align` default to the original fit-and-center
    /// behavior -- see `IconBg`'s doc comment.
    pub const IconDrawOpts = struct {
        scale: IconScale = .fit,
        h_align: HAlign = .center,
        v_align: VAlign = .center,
        max_w: ?u32 = null,
        max_h: ?u32 = null,
        /// See `Cell.metadata_id`'s doc comment.
        metadata_id: ?MetadataHandle = null,
    };

    /// Marks exactly one cell as backed by `handle`, resolved server-side
    /// by name against the icon catalog (`Context.iconHandle`) --
    /// dispatch.zig's job, not this method's. Still just one anchor cell
    /// even when `opts.scale == .natural` overflows beyond it -- see
    /// `IconBg`'s doc comment for why the overflow isn't tracked here.
    pub fn drawIcon(self: *Layer, handle: ImageHandle, row: usize, col: usize, opts: IconDrawOpts) void {
        const resolved_row = self.resolveRow(row);
        if (col >= self.width) return;
        const c = self.cell(resolved_row, col);
        c.style.bg = .{ .icon = .{
            .handle = handle,
            .scale = opts.scale,
            .h_align = opts.h_align,
            .v_align = opts.v_align,
            .max_w = opts.max_w,
            .max_h = opts.max_h,
        } };
        c.metadata_id = opts.metadata_id;
        c.meta_focus = false;
        self.revision += 1;
        self.render_gen +%= 1;
    }

    /// Same as `drawIcon`, but sets `Cell.fg_icon` instead of `style.bg`
    /// -- see that field's doc comment. Leaves `style.bg` (and whatever
    /// background is already there, e.g. a table border tile) untouched, so
    /// the host's render pass draws this icon over it rather than instead
    /// of it.
    pub fn drawIconOver(self: *Layer, handle: ImageHandle, row: usize, col: usize, opts: IconDrawOpts) void {
        const resolved_row = self.resolveRow(row);
        if (col >= self.width) return;
        const c = self.cell(resolved_row, col);
        c.fg_icon = .{
            .handle = handle,
            .scale = opts.scale,
            .h_align = opts.h_align,
            .v_align = opts.v_align,
            .max_w = opts.max_w,
            .max_h = opts.max_h,
        };
        c.metadata_id = opts.metadata_id;
        c.meta_focus = false;
        self.revision += 1;
        self.render_gen +%= 1;
    }

    /// `tag_metadata`: sets exactly one cell's `metadata_id`, touching
    /// nothing else -- unlike `writeTextTagged`/`drawIcon`, which tag as a
    /// side effect of also drawing something. For a client that needs to
    /// tag a cell without changing what's drawn there, e.g. `glyphwire-ls`
    /// tagging the extra cells a `.natural`-scaled icon visually overflows
    /// into (see `IconScale`'s doc comment on that overflow having no
    /// automatic data-model footprint -- this is how a client opts into
    /// giving it one anyway, deliberately, cell by cell).
    ///
    /// `focus` marks the cell as its span's landing point for
    /// `adjacentMetadataSpan` -- see `Cell.meta_focus`. It's the general
    /// way any client names a focus cell; a server-laid-out table instead
    /// sets `TableColumn.focus`, since the client can't know where the
    /// column ended up.
    pub fn tagMetadata(self: *Layer, row: usize, col: usize, metadata_id: ?MetadataHandle, focus: bool) void {
        const resolved_row = self.resolveRow(row);
        if (col >= self.width) return;
        const c = self.cell(resolved_row, col);
        c.metadata_id = metadata_id;
        c.meta_focus = focus;
        self.revision += 1;
        self.render_gen +%= 1;
    }

    /// Resets cells in `[row, row+rows) x [col, col+cols)` (clamped to the
    /// layer's own bounds) back to a blank cell -- empty grapheme, default
    /// style, no image background -- the same zero value `Layer.init`
    /// leaves every cell in. A no-op if the region is empty (`rows`/`cols`
    /// 0) or `row`/`col` is already past the layer's edge. Doesn't touch
    /// the cursor -- a caller wanting "clear and home the cursor" (a real
    /// terminal's `clear`/ctrl+l) does that itself via `set_property`.
    pub fn clear(self: *Layer, row: usize, col: usize, rows: usize, cols: usize) void {
        self.clearFill(row, col, rows, cols, null);
    }

    /// `clear`, but the blanked cells take `bg` as their background
    /// instead of the transparent default -- `clear`'s `bg` param, the
    /// "paint a solid panel" primitive. `null` is exactly `clear`.
    pub fn clearFill(self: *Layer, row: usize, col: usize, rows: usize, cols: usize, bg: ?Color) void {
        if (row >= self.height or col >= self.width or rows == 0 or cols == 0) return;

        const row_end = @min(row + rows, self.height);
        const col_end = @min(col + cols, self.width);
        var blank: Cell = .{};
        if (bg) |c| blank.style.bg = .{ .color = c };

        var r = row;
        while (r < row_end) : (r += 1) {
            for (self.liveRow(r)[col..col_end]) |*cell_ptr| cell_ptr.* = blank;
        }
        self.revision += 1;
        self.render_gen +%= 1;
    }

    /// Repaints only the *background* of the cells in
    /// `[row, row+rows) x [col, col+cols)` (clamped like `clearFill`),
    /// leaving each cell's grapheme, foreground colour, metadata id,
    /// `selectable` flag, text scale and foreground icon exactly as they
    /// were -- `set_bg`, the "move a highlight" primitive. A client that
    /// draws a list with one highlighted row repaints the row it left and
    /// the row it landed on with two of these instead of redrawing their
    /// text -- ~300 bytes a keystroke rather than kilobytes, which is what
    /// keeps a remote session responsive.
    ///
    /// The background is one slot (`Background` is a union), so a cell
    /// whose background was an image or an icon takes the colour like any
    /// other -- this overwrites rather than merging, the way `write_text`
    /// already does with `grapheme`/`style`. Foreground icons
    /// (`drawIconOver`) are a separate field and survive, which is what
    /// makes a listing row's icon stay put.
    pub fn fillBg(self: *Layer, row: usize, col: usize, rows: usize, cols: usize, bg: Color) void {
        if (row >= self.height or col >= self.width or rows == 0 or cols == 0) return;

        const row_end = @min(row + rows, self.height);
        const col_end = @min(col + cols, self.width);

        var r = row;
        while (r < row_end) : (r += 1) {
            for (self.liveRow(r)[col..col_end]) |*cell_ptr| cell_ptr.style.bg = .{ .color = bg };
        }
        self.revision += 1;
        self.render_gen +%= 1;
    }

    /// `fillBg` for the foreground: repaints only the text colour of the
    /// cells in `[row, row+rows) x [col, col+cols)` (clamped the same
    /// way), leaving grapheme, background, metadata, icons and the rest
    /// alone -- `set_fg`. The other half of moving a highlight whose row
    /// text changes colour with it (a light theme's `list_cursor_fg`):
    /// the row the cursor lands on takes one `set_fg` over its band, and
    /// the row it left one per run of its own colours, still a fraction
    /// of resending the text.
    pub fn fillFg(self: *Layer, row: usize, col: usize, rows: usize, cols: usize, fg: Color) void {
        if (row >= self.height or col >= self.width or rows == 0 or cols == 0) return;

        const row_end = @min(row + rows, self.height);
        const col_end = @min(col + cols, self.width);

        var r = row;
        while (r < row_end) : (r += 1) {
            for (self.liveRow(r)[col..col_end]) |*cell_ptr| cell_ptr.style.fg = fg;
        }
        self.revision += 1;
        self.render_gen +%= 1;
    }

    /// Repaints only the *underline* of the cells in
    /// `[row, row+rows) x [col, col+cols)` (clamped like `fillBg`), leaving
    /// everything else on them alone -- `set_underline`, and `fillBg`'s
    /// argument applies to it exactly: a mark applied over text that is
    /// already drawn, by a caller that does not know and should not have to
    /// recompute the colours underneath it.
    ///
    /// This is what makes a diagnostic squiggle work at all in a syntax-
    /// highlighted editor. A row is painted as coloured runs, then the search
    /// highlight and the selection are *overpainted* on top of it, and each
    /// of those is a full cell write that resets the underline. Threading a
    /// diagnostic through all three (and through every future overpaint)
    /// would mean every one of them knowing about diagnostics; one call
    /// after them means none of them do.
    ///
    /// A `.none` style is how a mark is taken off again.
    pub fn fillUnderline(
        self: *Layer,
        row: usize,
        col: usize,
        rows: usize,
        cols: usize,
        ul: UnderlineStyle,
    ) void {
        if (row >= self.height or col >= self.width or rows == 0 or cols == 0) return;

        const row_end = @min(row + rows, self.height);
        const col_end = @min(col + cols, self.width);

        var r = row;
        while (r < row_end) : (r += 1) {
            for (self.liveRow(r)[col..col_end]) |*cell_ptr| cell_ptr.style.underline = ul;
        }
        self.revision += 1;
        self.render_gen +%= 1;
    }

    pub fn getProperty(self: *const Layer, name: PropertyName) PropertyValue {
        return switch (name) {
            .cursor => .{ .cursor = self.cursor },
            .revision => .{ .revision = self.revision },
            .position => .{ .position = self.pos },
            .cell_position => unreachable, // needs the cell metrics; see Context.getLayerProperty
            .size => .{ .size = .{ .cols = self.width, .rows = self.height } },
            .scroll => .{ .scroll = .{ .offset = self.view_scroll, .max = self.history_len } },
            .visibility => .{ .visibility = self.visible },
            .opacity => .{ .opacity = self.opacity },
            .viewport => .{ .viewport = .{ .cols = self.viewportCols(), .rows = self.viewportRows() } },
            .scroll_offset => .{ .scroll_offset = self.effectiveScrollOffset() },
            .scrollbars => .{ .scrollbars = self.scrollbarState() },
            .content_extent => .{ .content_extent = blk: {
                const c = self.effectiveContent();
                break :blk .{ .cols = c.col, .rows = c.row };
            } },
            .scroll_mode => .{ .scroll_mode = self.scroll_mode },
            .background => .{ .background = self.background },
            .pty_mode => .{ .pty_mode = self.pty_mode },
            .mouse_select => .{ .mouse_select = self.mouse_select },
            .mouse_report => .{ .mouse_report = self.mouse_report },
            .shadow => .{ .shadow = self.shadow },
            .selection_flow => .{ .selection_flow = self.sel.flow },
            .resize_edge => .{ .resize_edge = self.resize_edge },
        };
    }

    pub fn setProperty(self: *Layer, value: PropertyValue) void {
        switch (value) {
            .cursor => |c| self.cursor = .{ .row = self.resolveRow(c.row), .col = c.col },
            .revision => unreachable, // get-only; see PropertyName.revision
            .position => |p| {
                self.pos = p;
                // An explicit pixel placement replaces a sticky cell one.
                self.pos_cells = null;
            },
            .cell_position => unreachable, // needs the cell metrics; see Context.setLayerProperty
            .size => unreachable, // reallocates and is root-guarded; see Context.setLayerProperty
            .scroll => unreachable, // get-only; move it with scrollView, see PropertyName.scroll
            .visibility => |v| self.visible = v,
            .opacity => |v| self.opacity = if (std.math.isNan(v)) 1.0 else std.math.clamp(v, 0.0, 1.0),
            .viewport => |v| {
                self.viewport_cols = v.cols;
                self.viewport_rows = v.rows;
                // A smaller content window can strand the scroll offset
                // past its new maximum.
                _ = self.setScrollOffset(self.effectiveScrollOffset());
            },
            .scroll_offset => |off| _ = self.setScrollOffset(off),
            .scrollbars => |sb| self.scrollbars = .{ .vertical = sb.vertical, .horizontal = sb.horizontal },
            // Ignored in host mode; `Context.setLayerProperty` is where
            // the wire path reports `WrongScrollMode` instead.
            .content_extent => |v| if (self.scroll_mode == .client) self.setContentExtent(
                if (v.cols == 0 and v.rows == 0) null else .{ .row = v.rows, .col = v.cols },
            ),
            .scroll_mode => |m| self.setScrollMode(m),
            .background => |c| self.background = c,
            .pty_mode => |v| {
                self.pty_mode = v;
                // Setting it either way is also the re-arm point: drop
                // any half-parsed sequence and any lingering colour so a
                // program that exited mid-escape can't bleed into what
                // the next one draws. See `Layer.pty_mode`.
                self.vt.esc_state = .ground;
                vt.resetOsc(self);
                self.vt.csi_len = 0;
                self.vt.shift_out = false;
                self.vt.g0_line_drawing = false;
                self.vt.g1_line_drawing = false;
                self.vt.pen = .{};
                vt.resetVtModes(self);
            },
            .mouse_select => |v| self.mouse_select = v,
            .mouse_report => |v| self.mouse_report = v,
            .shadow => |v| self.shadow = if (v) |sh| sh.clamped() else null,
            .selection_flow => |v| self.sel.flow = .{ .mode = v.mode, .column_cols = @max(v.column_cols, 1), .origin_col = v.origin_col },
            .resize_edge => |v| self.resize_edge = v,
        }
        // `.position` moves where the layer composites; `.cursor` can scroll
        // the ring buffer via `resolveRow` (bumped in `scrollOne`) and the
        // caret is an immediate draw either way -- bump unconditionally,
        // this path is never per-frame.
        self.touchRender();
    }

    pub const HeaderHit = struct { table: *Table, col: usize };

    /// The sortable table header column painted at **screen** cell
    /// `(row, col)` with the view scrolled back `view_scroll` rows, or
    /// null. Paint order (`table_order`) decides overlaps -- last drawn
    /// wins, as it does on screen. Shared by glyphwire-host's header click
    /// (`host/table_sort.zig`) and the `activate_at` wire op.
    pub fn sortableHeaderAt(self: *Layer, row: usize, col: usize, view_scroll: usize) ?HeaderHit {
        var found: ?HeaderHit = null;
        for (self.table_order.items) |handle| {
            const table = self.tables.getPtr(handle) orelse continue;
            const c = table.headerColumnAt(row, col, view_scroll) orelse continue;
            if (!table.columns[c].sortable) continue;
            found = .{ .table = table, .col = c };
        }
        return found;
    }

    pub const OutlineHit = struct { outline: *Outline, node: usize };

    /// How a cell picks an outline node to toggle: `.marker` is a mouse
    /// click (`Outline.toggleAt`), `.activate` is keyboard Enter
    /// (`Outline.activateAt`, which also takes an untagged row anywhere).
    pub const OutlinePick = enum { marker, activate };

    /// The outline node `(row, col)` would toggle under `pick`, or null.
    /// Same paint-order rule as `sortableHeaderAt`.
    pub fn outlineNodeAt(self: *Layer, row: usize, col: usize, view_scroll: usize, pick: OutlinePick) ?OutlineHit {
        var found: ?OutlineHit = null;
        for (self.outline_order.items) |handle| {
            const outline = self.outlines.getPtr(handle) orelse continue;
            const node = switch (pick) {
                .marker => outline.toggleAt(row, col, view_scroll),
                .activate => outline.activateAt(row, col, view_scroll),
            } orelse continue;
            found = .{ .outline = outline, .node = node };
        }
        return found;
    }

    /// The cell row `above` rows above the live viewport's top row (see
    /// `SelectionPoint`), or null if that row isn't currently retained.
    /// `above <= 0` is a live viewport row (`-above`); `above >= 1` walks
    /// up into scrollback.
    ///
    /// On the alternate screen the live rows are `vt.alt_cells`, which
    /// has no scrollback, exactly as `viewRow` draws it. Reading the
    /// primary buffer here instead had a selection over vim or nano trim
    /// its tint against, and copy, the shell output hidden underneath.
    pub fn rowForAbove(self: *const Layer, above: i64) ?[]const Cell {
        if (self.vt.on_alt) {
            if (above > 0) return null;
            const alt_row: usize = @intCast(-above);
            if (alt_row >= self.height) return null;
            const start = alt_row * self.width;
            return self.vt.alt_cells.?[start .. start + self.width];
        }
        if (above > 0) {
            if (above - 1 >= @as(i64, @intCast(self.history_len))) return null;
            return self.scrollbackRow(@intCast(above - 1));
        }
        const live_row: i64 = -above;
        if (live_row >= @as(i64, @intCast(self.height))) return null;
        return self.rowSlice(self.physicalRow(@intCast(live_row)));
    }
};
