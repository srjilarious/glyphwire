// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: MPL-2.0

//! Every notification op the Zig client sends, written once for both
//! `Client` (sent as its own frame) and `Client.Batch` (appended to the
//! batch). Each struct aliases the list (`pub const writeText =
//! ops.writeText;`), so `client.writeText(...)` and `b.writeText(...)` are
//! the same function and moving a sequence of draws into a batch is a
//! mechanical `client.` -> `b.` swap.
//!
//! Only notifications live here: a request answers differently on the two
//! (`Client` returns the result, `Batch` a `Slot` for `BatchResults`), so
//! requests stay hand-written on each. The `report_*` input messages and
//! `attach_*` stay `Client`-only too: a batch suppresses the broadcast a
//! report exists for, and an attach rebinds the connection mid-batch.

const std = @import("std");
const core = @import("core.zig");
const protocol = @import("protocol.zig");
const Client = @import("client.zig").Client;

const colorToJson = Client.colorToJson;
const TextOpts = Client.TextOpts;
const Span = Client.Span;
const ClearOpts = Client.ClearOpts;
const SetBgOpts = Client.SetBgOpts;
const SetFgOpts = Client.SetFgOpts;
const SetUnderlineOpts = Client.SetUnderlineOpts;
const DrawIconOpts = Client.DrawIconOpts;
const TableCellInput = Client.TableCellInput;
const TableSpanInput = Client.TableSpanInput;
const TableStyleInput = Client.TableStyleInput;
const SortKeyInput = Client.SortKeyInput;
const OutlineNodeInput = Client.OutlineNodeInput;
const OutlineStyleInput = Client.OutlineStyleInput;
const NinePatchUpdate = Client.NinePatchUpdate;
const SplitChildInput = @import("client.zig").SplitChildInput;
const PaneSplitChildInput = @import("client.zig").PaneSplitChildInput;

/// The notification ops for `Self` (`Client` or `Client.Batch`), each
/// calling `Self.notify` with the params `protocol.ParamsOf` types for its
/// method. `tests/client_tests.zig` analyses every alias on both, so a
/// params mismatch here fails the build rather than a call site.
pub fn Ops(comptime Self: type) type {
    return struct {
        /// Scratch allocator for the few ops that reshape their input
        /// before sending. Freed as soon as `notify` returns: both forms
        /// encode the message on the spot, `Batch` into its own arena.
        fn scratchAlloc(self: *Self) std.mem.Allocator {
            return switch (Self) {
                Client => self.alloc,
                Client.Batch => self.client.alloc,
                else => @compileError("client_ops.Ops: Self must be Client or Client.Batch"),
            };
        }

        // -- Text, clearing and the cursor --

        /// `write_text` -- a notification, no response. Every option is in
        /// `TextOpts`; a null `fg`/`bg` means the server's default style (see
        /// `core.default_style`).
        pub fn writeText(self: *Self, text: []const u8, opts: TextOpts) !void {
            try self.notify("write_text", textParams(text, null, opts));
        }

        /// `write_text` with `spans`: several differently styled runs written
        /// back to back in one message -- a syntax-coloured row, a status line
        /// whose mode word has its own colour. `opts` places the write, gives
        /// each span its defaults, and its `max_cols`/`pad` cover the whole
        /// write. A notification.
        pub fn writeSpans(self: *Self, spans: []const Span, opts: TextOpts) !void {
            const alloc = scratchAlloc(self);
            const wire_spans = try spansToWire(alloc, spans);
            defer alloc.free(wire_spans);
            try self.notify("write_text", textParams(null, wire_spans, opts));
        }

        /// `clear` with every option (see `ClearOpts`) -- a notification.
        pub fn clearArea(self: *Self, opts: ClearOpts) !void {
            try self.notify("clear", clearParams(opts));
        }

        /// `set_bg` -- repaints a region's background and nothing else, so a
        /// client that moves a highlight sends two of these instead of two
        /// rows of text. A notification; batched, the two rows a highlight
        /// moves between go out in one frame.
        pub fn setBg(self: *Self, opts: SetBgOpts) !void {
            try self.notify("set_bg", setBgParams(opts));
        }

        /// `set_fg` -- repaints a region's text colour and nothing else: the
        /// foreground half of moving a highlight whose text changes colour
        /// with it. A notification, meant to go out in the same batch as the
        /// `set_bg`s it recolours text under.
        pub fn setFg(self: *Self, opts: SetFgOpts) !void {
            try self.notify("set_fg", setFgParams(opts));
        }

        /// `set_underline` -- marks a region's underline and nothing else, for a
        /// mark that goes *over* text already drawn: a diagnostic squiggle under
        /// a row that has already been syntax-coloured, search-highlighted and
        /// selection-tinted. `.none` takes the mark off. A notification; an
        /// editor batches every diagnostic mark on the visible rows with the
        /// text it sits under.
        pub fn setUnderline(self: *Self, opts: SetUnderlineOpts) !void {
            try self.notify("set_underline", setUnderlineParams(opts));
        }

        /// `set_property(layer, "cursor", {row, col})` -- a notification.
        pub fn setCursor(self: *Self, row: usize, col: usize) !void {
            try self.notify("set_property", .{ .property = "cursor", .row = row, .col = col });
        }

        /// `set_property(layer, "cursor", {row, col})` on a non-root layer --
        /// see `setCursor` for the root-layer version. `write_text` is always
        /// cursor-implicit (no `row`/`col` params of its own), so placing text
        /// on a layer other than root goes through this first.
        pub fn setCursorOn(self: *Self, layer: core.LayerHandle, row: usize, col: usize) !void {
            try self.notify("set_property", .{ .layer = layer, .property = "cursor", .row = row, .col = col });
        }

        /// `insert_cells(count)` -- a notification. ECMA-48's ICH: shifts
        /// cells at and after the cursor rightward by `count` within its row,
        /// opening `count` blank cells at the cursor without moving it -- the
        /// primitive a line editor needs to insert into already-drawn text
        /// without retransmitting everything after the insertion point.
        pub fn insertCells(self: *Self, count: usize) !void {
            try self.notify("insert_cells", .{ .count = count });
        }

        /// `delete_cells(count)` -- a notification. ECMA-48's DCH: removes
        /// `count` cells at and after the cursor, shifting the row's
        /// remainder left and blanking `count` cells at the row's tail.
        pub fn deleteCells(self: *Self, count: usize) !void {
            try self.notify("delete_cells", .{ .count = count });
        }

        /// `move_content(layer?, top?, bot?, count, direction)` -- a
        /// notification. Shifts `count` rows of `layer`'s content grid (null
        /// = the root layer; the whole grid, or the inclusive `[top, bot]`
        /// band) vertically in place, the wire face of CSI SU/SD: a
        /// client-scrolled pane scrolls by moving the rows it still has and
        /// redrawing only the newly-exposed band rather than retransmitting
        /// every visible row. Usually sent from a `Batch`, right before that
        /// partial redraw.
        pub fn moveContent(
            self: *Self,
            layer: ?core.LayerHandle,
            top: ?usize,
            bot: ?usize,
            count: usize,
            direction: core.Layer.ScrollDir,
        ) !void {
            try self.notify("move_content", .{
                .layer = layer,
                .top = top,
                .bot = bot,
                .count = count,
                .direction = @tagName(direction),
            });
        }

        /// `tag_metadata(layer?, row, col, metadata_id)` -- a notification.
        /// Sets exactly one cell's metadata tag without touching its
        /// background/text -- unlike `writeText`/`drawIconStyled`,
        /// which tag as a side effect of drawing something. For a client that
        /// needs a cell tagged without changing what's drawn there, e.g.
        /// tagging the extra cells a `.natural`-scaled icon visually
        /// overflows into (see `core.IconScale`'s doc comment on why that
        /// overflow has no automatic data-model footprint on its own).
        ///
        /// `focus` marks the cell as its span's landing point for
        /// `findMetadata` (Ctrl+PgUp/PgDn in `glyphwire-shell`) -- see
        /// `core.Cell.meta_focus`. A server-painted table names its focus
        /// column with `TableColumnInput.focus` instead, since the client
        /// can't know where the column landed.
        pub fn tagMetadata(self: *Self, layer: ?core.LayerHandle, row: usize, col: usize, metadata_id: core.MetadataHandle, focus: bool) !void {
            try self.notify("tag_metadata", .{ .layer = layer, .row = row, .col = col, .metadata_id = metadata_id, .focus = focus });
        }

        /// `clear(layer?, row?, col?, rows?, cols?)` -- a notification.
        /// Resets cells in the given region of the root layer back to
        /// blank/default style. `rows`/`cols` null means
        /// "the rest of the layer from `row`/`col`", so `clear(0, 0, null,
        /// null)` wipes the whole layer.
        pub fn clear(self: *Self, row: usize, col: usize, rows: ?usize, cols: ?usize) !void {
            try self.clearOn(null, row, col, rows, cols);
        }

        /// `clear(layer?, ...)` -- the explicitly-targeted form of `clear`,
        /// matching `drawImageOn`, for a TUI wiping one of its own layers.
        /// Null = the root layer.
        pub fn clearOn(self: *Self, layer: ?core.LayerHandle, row: usize, col: usize, rows: ?usize, cols: ?usize) !void {
            try self.notify("clear", .{ .layer = layer, .row = row, .col = col, .rows = rows, .cols = cols });
        }

        // -- Images and icons --

        /// `destroy_image(handle)` -- a notification releasing a loaded
        /// image's bytes. Cells still backed by the handle are left as they
        /// are and simply render nothing from then on; clear them first if
        /// that matters -- see `core.Context.destroyImage`.
        ///
        /// Mostly unnecessary for a short-lived program (an image loaded over
        /// a connection is reclaimed automatically once that connection is
        /// gone and the image has scrolled out of the scrollback -- see
        /// `core.Session.sweepImages`); this is for a long-running client that
        /// wants its own memory back at a moment of its choosing.
        pub fn destroyImage(self: *Self, handle: core.ImageHandle) !void {
            try self.notify("destroy_image", .{ .handle = handle });
        }

        /// `draw_image(handle, row?, col?, row_span, col_span, scale, src)` --
        /// a notification. Places the image anchored at `(row, col)`
        /// (defaulting to the layer's cursor when either is omitted, same as
        /// `write_text`'s documented convention), clipped to the given span
        /// rather than stretched to fill it — see decisions.md's Image
        /// section. `scale` is the uniform factor the image is drawn at:
        /// `1.0` is its natural pixel size (the original behavior); `< 1.0`
        /// shrinks it (glyphwire-view passes `target_width_px / image_width_px`
        /// for `--size fit-width`). `src` optionally restricts sampling to a
        /// sub-rectangle of the image (sprite-sheet support) -- `.{}` draws
        /// from the whole image, the original behavior. Aspect-ratio-aware
        /// placement (choosing `row_span`/`col_span` to match the image's
        /// *scaled* shape) is the caller's job; `getImageInfo` plus
        /// `getCellMetrics` and `getSize` give it what it needs to compute
        /// that.
        pub fn drawImage(self: *Self, handle: core.ImageHandle, row: ?usize, col: ?usize, row_span: usize, col_span: usize, scale: f32, src: core.ImageSrcRect) !void {
            try self.drawImageOn(null, handle, row, col, row_span, col_span, scale, src);
        }

        /// `draw_image(layer, ...)` -- the explicitly-targeted form of
        /// `drawImage`, matching `drawIconOn`.
        /// The wire message has always carried `layer?`; only the Zig helper
        /// was missing it, so a TUI drawing a picture into one of its own
        /// layers (gw-read's page layer) had no way to say which.
        pub fn drawImageOn(
            self: *Self,
            layer: ?core.LayerHandle,
            handle: core.ImageHandle,
            row: ?usize,
            col: ?usize,
            row_span: usize,
            col_span: usize,
            scale: f32,
            src: core.ImageSrcRect,
        ) !void {
            try self.notify("draw_image", .{
                .layer = layer,
                .handle = handle,
                .row = row,
                .col = col,
                .row_span = row_span,
                .col_span = col_span,
                .scale = scale,
                .src_x = src.x,
                .src_y = src.y,
                .src_w = src.w,
                .src_h = src.h,
            });
        }

        /// `draw_icon(row?, col?, name)` -- a notification. Draws a bundled,
        /// named icon (decisions.md's Icon section; the default set is the
        /// `assets/icons/` tree, each icon named by its path there minus the
        /// `.png`) into exactly one cell, anchored at the
        /// layer's cursor when `row`/`col` is omitted -- unlike `drawImage`, no
        /// span: an icon is scoped to a single cell for now.
        pub fn drawIcon(self: *Self, row: ?usize, col: ?usize, name: []const u8) !void {
            try self.notify("draw_icon", .{ .row = row, .col = col, .name = name });
        }

        /// `draw_icon(row?, col?, name, scale?, h_align?, v_align?, max_w?,
        /// max_h?, metadata_id?)` -- like `drawIcon`, but lets the icon be
        /// drawn at its own native pixel size (`opts.scale = .natural`,
        /// optionally capped by `opts.max_w`/`opts.max_h`) or stretched to
        /// exactly fill the cell (`.stretch`) instead of shrunk to fit the
        /// anchor cell, aligned relative to the anchor cell per
        /// `opts.h_align`/`opts.v_align`, and optionally tagged with
        /// `opts.metadata_id`. A separate method rather than extra params on
        /// `drawIcon` itself since Zig has no default parameter values.
        pub fn drawIconStyled(self: *Self, row: ?usize, col: ?usize, name: []const u8, opts: DrawIconOpts) !void {
            try self.notify("draw_icon", iconParams(opts.layer, row, col, name, opts));
        }

        /// `draw_icon(layer, row?, col?, name)` on a non-root layer -- see
        /// `drawIcon` for the root-layer version.
        pub fn drawIconOn(self: *Self, layer: core.LayerHandle, row: ?usize, col: ?usize, name: []const u8) !void {
            try self.notify("draw_icon", .{ .layer = layer, .row = row, .col = col, .name = name });
        }

        /// `draw_icon(layer, row?, col?, name, scale?, h_align?, v_align?,
        /// max_w?, max_h?, metadata_id?)` on a non-root layer -- see
        /// `drawIconStyled` for the root-layer version.
        pub fn drawIconOnStyled(self: *Self, layer: core.LayerHandle, row: ?usize, col: ?usize, name: []const u8, opts: DrawIconOpts) !void {
            try self.notify("draw_icon", iconParams(layer, row, col, name, opts));
        }

        // -- Layers and contexts --

        /// `destroy_layer(layer)` -- a notification. Frees a layer created by
        /// `createLayer` and drops it from compositing; there's nothing more
        /// to do afterward, including no need to `clear` it first. The server
        /// honors this only from a connection that owns the layer (created it,
        /// or `adoptLayer`'d it); a non-owner's call is logged and ignored.
        /// You don't have to call this on a clean exit either -- the server
        /// culls a layer once every connection that owned it has disconnected.
        pub fn destroyLayer(self: *Self, layer: core.LayerHandle) !void {
            try self.notify("destroy_layer", .{ .layer = layer });
        }

        /// `adopt_layer(layer)` -- a notification. Adds this connection to
        /// `layer`'s set of owners, so the layer outlives its original
        /// creator disconnecting for as long as this connection stays up, and
        /// this connection may itself `destroyLayer` it. Use it when one
        /// process hands ongoing responsibility for a layer to another.
        pub fn adoptLayer(self: *Self, layer: core.LayerHandle) !void {
            try self.notify("adopt_layer", .{ .layer = layer });
        }

        /// `set_context_title(title)` -- a notification. Names this
        /// connection's active context for display: glyphwire-host's context
        /// switcher lists it and a shell's `jobs` prints it. Send it right
        /// after `createContext` (a program that inherited its context, like
        /// the shell, can name that one too).
        pub fn setContextTitle(self: *Self, title: []const u8) !void {
            try self.notify("set_context_title", .{ .title = title });
        }

        /// `set_theme` -- a notification. Gives this connection's active
        /// context its own theme: every slot and role of `t`, which the host
        /// resolves this context's colours against from now on, whatever the
        /// window's theme becomes. Null goes back to following the window's.
        pub fn setTheme(self: *Self, t: ?*const core.theme.Theme) !void {
            const th = t orelse return self.notify("set_theme", .{});
            var slots: [core.theme.slot_count]protocol.Color = undefined;
            for (th.slots, 0..) |c, i| slots[i] = protocol.colorToWire(c);
            const alloc = scratchAlloc(self);
            var roles: std.json.ArrayHashMap(protocol.Color) = .{};
            defer roles.deinit(alloc);
            for (std.enums.values(core.theme.Role)) |r| {
                try roles.map.put(alloc, @tagName(r), protocol.roleValueToWire(th.roles.get(r)));
            }
            try self.notify("set_theme", .{ .theme = protocol.ThemeWire{
                .name = th.name,
                .dark = th.dark,
                .panel_style = th.panel_style,
                .slots = &slots,
                .roles = roles,
            } });
        }

        /// `set_divider_style` -- a notification. How the host draws the
        /// bands of this connection's active context's own split tree: a
        /// preset and/or single glyphs, each falling back to the host's
        /// `pane_divider_style` when null. An empty override (`.{}`) goes
        /// back to the host's style entirely.
        pub fn setDividerStyle(self: *Self, style: *const core.divider_style.Override) !void {
            try self.notify("set_divider_style", protocol.DividerStyleWire.fromOverride(style));
        }

        /// `set_theme` by built-in name -- a notification.
        pub fn setThemeByName(self: *Self, name: []const u8) !void {
            try self.notify("set_theme", .{ .name = name });
        }

        /// `set_window_scrollbar(visible)` -- a notification. Toggles the
        /// always-on window scrollbar for this connection's active context
        /// after the fact (see `createContext`'s `window_scrollbar`).
        pub fn setWindowScrollbar(self: *Self, visible: bool) !void {
            try self.notify("set_window_scrollbar", .{ .visible = visible });
        }

        /// `set_caret_layer(layer)` -- a notification. Points glyphwire-host's
        /// caret at `layer` for this connection's active context instead of
        /// the root cursor; `null` restores the root cursor (see
        /// `core.Context.caret_layer`). A multi-pane client re-sends this on
        /// every focus change so the caret follows the active pane.
        pub fn setCaretLayer(self: *Self, layer: ?core.LayerHandle) !void {
            try self.notify("set_caret_layer", .{ .layer = layer });
        }

        /// `set_caret_visible(visible)` -- a notification. Shows or hides
        /// glyphwire-host's caret for this connection's active context (see
        /// `core.Context.caret_visible`). A program with no insertion point,
        /// like `gw-read`, sends `false` once after `createContext`.
        pub fn setCaretVisible(self: *Self, visible: bool) !void {
            try self.notify("set_caret_visible", .{ .visible = visible });
        }

        /// `set_caret_shape(shape)` -- a notification. Sets the shape
        /// glyphwire-host draws the caret in for this connection's active
        /// context (see `core.Context.caret_shape`); `null` goes back to the
        /// shape `host.conf.lua` chose. A modal editor sends `.line` in
        /// insert mode and `null` otherwise.
        pub fn setCaretShape(self: *Self, shape: ?core.CaretShape) !void {
            try self.notify("set_caret_shape", .{ .shape = shape });
        }

        /// `set_key_repeat(delay_ms, interval_ms)` -- a notification. Retimes
        /// the typematic key repeat glyphwire-host synthesizes while this
        /// connection's active context is focused: `delay_ms` is how long a
        /// key must be held before repeating, `interval_ms` how often it
        /// repeats after that (see `core.KeyRepeat`). Equal values mean no
        /// distinct initial hold, which is what an editor wants and a shell
        /// does not. Both `null` clears the override and goes back to the
        /// host's default.
        pub fn setKeyRepeat(self: *Self, delay_ms: ?f64, interval_ms: ?f64) !void {
            try self.notify("set_key_repeat", .{ .delay_ms = delay_ms, .interval_ms = interval_ms });
        }

        /// `destroy_context(context)` -- a notification. Frees a context
        /// created by `createContext` and everything in it, and (if it was
        /// visible) drops visibility back to whatever context was under it --
        /// the alt-screen auto-restore. Honored only from a connection that
        /// owns the context. Like `destroyLayer`, you don't have to call this
        /// on a clean exit: the server culls the context once every owning
        /// connection has disconnected.
        pub fn destroyContext(self: *Self, context: core.ContextHandle) !void {
            try self.notify("destroy_context", .{ .context = context });
        }

        /// `activate_context(context)` -- a notification. Makes `context` the
        /// one on screen *without* changing which context this `Client`
        /// draws on. A program backgrounds itself by activating
        /// `glyphwire.root_context_handle` and restores itself by activating
        /// its own handle again.
        pub fn activateContext(self: *Self, context: core.ContextHandle) !void {
            try self.notify("activate_context", .{ .context = context });
        }

        /// `adopt_context(context)` -- a notification. The context-level
        /// mirror of `adoptLayer`: adds this connection to `context`'s owner
        /// set so it outlives its creator disconnecting.
        pub fn adoptContext(self: *Self, context: core.ContextHandle) !void {
            try self.notify("adopt_context", .{ .context = context });
        }

        // -- Panes --

        /// `set_window_prefix`: the chord after which one keystroke is a window
        /// command rather than input for the focused pane. `null` clears it.
        ///
        /// The session enforces this, so a manager receives only its own
        /// commands and never a program's keystrokes -- see
        /// `core.WindowPrefix`.
        pub fn setWindowPrefix(self: *Self, key: ?[]const u8, ctrl: bool, alt: bool, shift: bool) !void {
            try self.notify("set_window_prefix", .{ .key = key, .ctrl = ctrl, .alt = alt, .shift = shift });
        }

        /// `destroy_pane`: stops whatever is running in the pane and frees it
        /// and every context in it.
        pub fn destroyPane(self: *Self, pane: core.PaneHandle) !void {
            try self.notify("destroy_pane", .{ .pane = pane });
        }

        /// `focus_pane`: which pane raw input goes to.
        pub fn focusPane(self: *Self, pane: core.PaneHandle) !void {
            try self.notify("focus_pane", .{ .pane = pane });
        }

        pub fn destroyPaneSplit(self: *Self, split: core.PaneSplitHandle) !void {
            try self.notify("destroy_pane_split", .{ .split = split });
        }

        pub fn setPaneSplitChildren(
            self: *Self,
            split: core.PaneSplitHandle,
            children: []const PaneSplitChildInput,
        ) !void {
            try self.notify("set_pane_split_children", .{ .split = split, .children = children });
        }

        /// `replace_pane_split_child`: puts `child` in slot `index` of
        /// `split`. Leave `child`'s `weight` and `fixed` unset (`.{ .pane = p }`
        /// / `.{ .split = s }`) to keep the slot's current size -- what a
        /// split or close of one pane wants, so the ratios the user dragged
        /// elsewhere survive.
        pub fn replacePaneSplitChild(self: *Self, split: core.PaneSplitHandle, index: usize, child: PaneSplitChildInput) !void {
            try self.notify("replace_pane_split_child", .{ .split = split, .index = index, .child = child });
        }

        /// `send_window_prefix`: delivers the registered prefix chord itself
        /// to the focused pane's program, once -- tmux's `send-prefix`.
        pub fn sendWindowPrefix(self: *Self) !void {
            try self.notify("send_window_prefix", .{});
        }

        pub fn setRootPaneSplit(self: *Self, split: ?core.PaneSplitHandle) !void {
            try self.notify("set_root_pane_split", .{ .split = split });
        }

        /// `move_pane_divider`: drags the band after child `index` by `delta`
        /// cells. Positive grows the child at `index` and shrinks its
        /// neighbour.
        pub fn movePaneDivider(self: *Self, split: core.PaneSplitHandle, index: usize, delta: i64) !void {
            try self.notify("move_pane_divider", .{ .split = split, .index = index, .delta = delta });
        }

        /// `stop_remote`: ends a session `startRemote` returned. Safe to send
        /// for one that has already ended -- the caller racing `remote_exit`
        /// is the normal case, not an error.
        pub fn stopRemote(self: *Self, session: u64) !void {
            try self.notify("stop_remote", .{ .session = session });
        }

        // -- Layer properties --

        /// `set_property(layer, "position", {x, y})` -- a notification. Moves
        /// `layer` to a pixel-precise position relative to the root (see
        /// `PropertyName.position`'s doc comment) -- e.g. sliding a
        /// notification layer across the screen one small step at a time.
        pub fn setLayerPosition(self: *Self, layer: core.LayerHandle, x: f32, y: f32) !void {
            try self.notify("set_property", .{ .layer = layer, .property = "position", .x = x, .y = y });
        }

        /// `set_property(layer, "cell_position", {row, col})` -- a
        /// notification. The same placement as `setLayerPosition` but in grid
        /// cells, and *sticky*: the server re-derives the pixel position when
        /// the cell metrics change, so a layer placed this way stays on its
        /// column across a font-size change. See
        /// `core.PropertyName.cell_position`. Batched, a popup moves in the
        /// same frame its contents are redrawn.
        pub fn setLayerCellPosition(self: *Self, layer: core.LayerHandle, row: usize, col: usize) !void {
            try self.notify("set_property", .{ .layer = layer, .property = "cell_position", .row = row, .col = col });
        }

        /// `set_property(layer, "size", {cols, rows})` -- a notification.
        /// Resizes a `createLayer` layer's cell grid, bottom-anchored like
        /// every other resize (see `core.Layer.resize`). This is how a
        /// multi-pane TUI reflows its panes on a `resize` notification
        /// without destroying and rebuilding them. Rejected for the root
        /// layer, whose size the host owns. Batched, the reflow and the rows
        /// redrawn for the new size land in one frame.
        pub fn setLayerSize(self: *Self, layer: core.LayerHandle, cols: usize, rows: usize) !void {
            try self.notify("set_property", .{ .layer = layer, .property = "size", .cols = cols, .rows = rows });
        }

        /// `set_property(layer, "visibility", {visible})` -- a notification.
        /// Hides or shows a layer without destroying it: its cells, tables
        /// and metadata ids all survive, glyphwire-host just stops
        /// compositing it. Rejected for the root layer. Showing a layer as
        /// the last message of the batch that drew it means it never
        /// appears half-drawn.
        pub fn setLayerVisible(self: *Self, layer: core.LayerHandle, visible: bool) !void {
            try self.notify("set_property", .{ .layer = layer, .property = "visibility", .visible = visible });
        }

        /// `set_property(layer, "opacity", {value})` -- a notification.
        /// `value` is 0.0..1.0 and multiplies the alpha of everything the
        /// layer composites, so what's behind it shows through. Unlike
        /// `setLayerVisible` the layer stays in the stack and keeps taking
        /// the mouse -- see `core.PropertyName.opacity`. Out-of-range values
        /// are clamped server-side.
        pub fn setLayerOpacity(self: *Self, layer: core.LayerHandle, value: f32) !void {
            try self.notify("set_property", .{ .layer = layer, .property = "opacity", .value = value });
        }

        /// `set_property(layer, "viewport", {cols, rows})` -- a notification.
        /// How much of the layer's content grid the host draws; zero on an
        /// axis means all of it. This is what makes a pane a *window onto*
        /// its content rather than the whole of it -- see
        /// `core.PropertyName.viewport`. A layer inside a split tree has this
        /// set for it by the layout.
        pub fn setLayerViewport(self: *Self, layer: core.LayerHandle, cols: usize, rows: usize) !void {
            try self.notify("set_property", .{ .layer = layer, .property = "viewport", .cols = cols, .rows = rows });
        }

        /// `set_property(layer, "scroll_offset", {row, col})` -- a
        /// notification. Where the viewport sits in the content grid, clamped
        /// server-side to what the content actually has. Batched, a frame's
        /// scroll position lands with the rows drawn for it.
        pub fn setLayerScrollOffset(self: *Self, layer: core.LayerHandle, row: usize, col: usize) !void {
            try self.notify("set_property", .{ .layer = layer, .property = "scroll_offset", .row = row, .col = col });
        }

        /// `set_property(layer, "content_extent", {cols, rows})` -- a
        /// notification. Declares the size of the whole content a
        /// self-scrolling pane redraws (a TUI editor's buffer), so the host
        /// can draw a proportional scrollbar and turn a wheel / drag over the
        /// pane into a `scroll_offset` the client obeys. `{0, 0}` clears it.
        /// See `core.PropertyName.content_extent`.
        ///
        /// Only accepted on a layer in `.client` scroll mode
        /// (`setLayerScrollMode`); on a host-scrolled layer the host reports
        /// `WrongScrollMode` and changes nothing.
        pub fn setLayerContentExtent(self: *Self, layer: core.LayerHandle, cols: usize, rows: usize) !void {
            try self.notify("set_property", .{ .layer = layer, .property = "content_extent", .cols = cols, .rows = rows });
        }

        /// `set_property(layer, "scroll_mode", {mode})` -- a notification.
        /// `.host` (the default): the host slides the viewport over a real
        /// content grid. `.client`: the program redraws its visible rows and
        /// reports a virtual `content_extent`. Switching resets the scroll
        /// position. See `core.PropertyName.scroll_mode`.
        pub fn setLayerScrollMode(self: *Self, layer: core.LayerHandle, mode: core.ScrollMode) !void {
            try self.notify("set_property", .{ .layer = layer, .property = "scroll_mode", .mode = @tagName(mode) });
        }

        /// `set_property(layer, "background", {color?})` -- a notification.
        /// The colour every transparent cell of the layer composites as;
        /// `null` restores see-through. See `core.PropertyName.background`.
        pub fn setLayerBackground(self: *Self, layer: core.LayerHandle, color: ?core.Color) !void {
            try self.notify("set_property", .{ .layer = layer, .property = "background", .color = colorToJson(color) });
        }

        /// `set_property(layer, "shadow", {shadow})` -- a notification. Gives
        /// the layer a soft drop shadow drawn by the host under its bounds, or
        /// removes it with `null`. See `core.Shadow`.
        pub fn setLayerShadow(self: *Self, layer: core.LayerHandle, shadow: ?core.Shadow) !void {
            try self.notify("set_property", .{ .layer = layer, .property = "shadow", .shadow = shadowToJson(shadow) });
        }

        /// `set_property(layer, "resize_edge", {edge})` -- a notification.
        /// Gives a floating layer an edge the host lets the user drag; the
        /// drag comes back as a `layer_resize` event (subscribe to
        /// `"layout"`), which the client applies itself. See
        /// `core.ResizeEdge`.
        pub fn setLayerResizeEdge(self: *Self, layer: core.LayerHandle, edge: core.ResizeEdge) !void {
            try self.notify("set_property", .{ .layer = layer, .property = "resize_edge", .edge = @tagName(edge) });
        }

        /// `set_property(layer, "pty_mode", {enabled})` -- a notification.
        /// Turns on cross-`write_text`-call persistence of the layer's
        /// escape-sequence / charset / SGR-pen state, so a sequence a PTY
        /// child split across two chunks still parses as one and a colour
        /// stays set until the program resets it (see `core.Layer.pty_mode`).
        /// Sending it -- with either value -- also clears that transient
        /// state, so a client re-sends `true` after a foreground program
        /// exits to drop anything it left half-open.
        pub fn setLayerPtyMode(self: *Self, layer: core.LayerHandle, enabled: bool) !void {
            try self.notify("set_property", .{ .layer = layer, .property = "pty_mode", .enabled = enabled });
        }

        /// `set_property(layer, "mouse_select", {enabled})` -- a
        /// notification. Lets glyphwire-host run its own drag-to-select on
        /// this layer even though this client owns the context, for a layer
        /// whose content is terminal output the user will want to copy (the
        /// embedded shell panel). Off by default, because on a layer the
        /// client draws itself the left button is the client's -- see
        /// `core.Layer.mouse_select`.
        pub fn setLayerMouseSelect(self: *Self, layer: core.LayerHandle, enabled: bool) !void {
            try self.notify("set_property", .{ .layer = layer, .property = "mouse_select", .enabled = enabled });
        }

        /// `set_property(layer, "selection_flow", {mode, cols, col})` -- a
        /// notification. Which way a selection on `layer` reads: the
        /// ordinary horizontal stream, or vertical columns right to left,
        /// each `flow.column_cols` cells wide starting at cell column
        /// `flow.origin_col`. See `core.SelectionFlow`. Batched, a panel's
        /// text and the way a selection reads it change in the same frame.
        pub fn setLayerSelectionFlow(self: *Self, layer: core.LayerHandle, flow: core.SelectionFlow) !void {
            try self.notify("set_property", selectionFlowParams(layer, flow));
        }

        /// `set_property(layer, "mouse_report", {enabled})` -- a notification.
        /// Says the program whose output `layer` shows has turned xterm mouse
        /// reporting on or off, so glyphwire-host hands it the raw button,
        /// drag and wheel events instead of selecting text. glyphwire-shell
        /// sends it as its pty child flips `?1000`/`?1002`/`?1003`. See
        /// `core.Layer.mouse_report`.
        pub fn setLayerMouseReport(self: *Self, layer: core.LayerHandle, enabled: bool) !void {
            try self.notify("set_property", .{ .layer = layer, .property = "mouse_report", .enabled = enabled });
        }

        /// `set_property(layer, "scrollbars", {vertical, horizontal})` -- a
        /// notification. Opt in per axis; the host draws the bars inside the
        /// layer's own bounds and drives `scroll_offset` from them.
        pub fn setLayerScrollbars(self: *Self, layer: core.LayerHandle, vertical: bool, horizontal: bool) !void {
            try self.notify("set_property", .{
                .layer = layer,
                .property = "scrollbars",
                .vertical = vertical,
                .horizontal = horizontal,
            });
        }

        // -- Splits and stacking --

        /// `destroy_split(split)` -- a notification. Frees the container; its
        /// children (layers and nested splits) survive.
        pub fn destroySplit(self: *Self, split: core.SplitHandle) !void {
            try self.notify("destroy_split", .{ .split = split });
        }

        /// `set_split_children(split, children)` -- a notification. Replaces
        /// the child list wholesale. Each entry names a layer *or* a nested
        /// split, and is sized either by `weight` (a share of what's left) or
        /// `fixed` (that many cells along the split's axis).
        pub fn setSplitChildren(self: *Self, split: core.SplitHandle, children: []const SplitChildInput) !void {
            try self.notify("set_split_children", .{ .split = split, .children = children });
        }

        /// `replace_split_child(split, index, child)` -- a notification.
        /// Puts `child` in slot `index`, keeping the slot's current size
        /// when `child` gives neither `weight` nor `fixed` (`.{ .layer = l }`
        /// / `.{ .split = s }`). Re-sending the whole list with
        /// `setSplitChildren` would reset what the user dragged it to.
        pub fn replaceSplitChild(self: *Self, split: core.SplitHandle, index: usize, child: SplitChildInput) !void {
            try self.notify("replace_split_child", .{ .split = split, .index = index, .child = child });
        }

        /// `set_root_split(split?)` -- a notification. Which split fills the
        /// window; null tears the layout down without destroying anything.
        pub fn setRootSplit(self: *Self, split: ?core.SplitHandle) !void {
            try self.notify("set_root_split", .{ .split = split });
        }

        /// `move_divider(split, index, delta)` -- a notification. Drags the
        /// band after child `index` by `delta` cells. glyphwire-host sends
        /// this for a mouse drag; a client sends it for a keyboard "grow this
        /// pane" binding.
        pub fn moveDivider(self: *Self, split: core.SplitHandle, index: usize, delta: i64) !void {
            try self.notify("move_divider", .{ .split = split, .index = index, .delta = delta });
        }

        /// `raise_layer(layer, above?)` -- a notification. Moves `layer` up
        /// the compositing order: directly above `above`, or to the very top
        /// when it's null. Creation order is only the *initial* stacking, so
        /// this is what puts a completion popup created early back over a
        /// sidebar created later.
        pub fn raiseLayer(self: *Self, layer: core.LayerHandle, above: ?core.LayerHandle) !void {
            try self.notify("raise_layer", .{ .layer = layer, .above = above });
        }

        /// `lower_layer(layer, below?)` -- the mirror of `raiseLayer`.
        pub fn lowerLayer(self: *Self, layer: core.LayerHandle, below: ?core.LayerHandle) !void {
            try self.notify("lower_layer", .{ .layer = layer, .below = below });
        }

        // -- Tables and outlines --

        /// `destroy_table(layer?, table)` -- a notification. Blanks whatever
        /// the table last painted and frees it server-side.
        pub fn destroyTable(self: *Self, layer: ?core.LayerHandle, table: core.TableHandle) !void {
            try self.notify("destroy_table", .{ .layer = layer, .table = table });
        }

        /// `table_set_rows(layer?, table, rows)` -- a notification. Replaces
        /// every row wholesale, re-sorts per the table's current sort state,
        /// and repaints -- see `core.Table.render`. `rows` is a plain matrix
        /// of borrowed values (`[row][col]`); this only needs a small
        /// temporary array to reshape it into wire JSON, freed before
        /// returning.
        pub fn tableSetRows(self: *Self, layer: ?core.LayerHandle, table: core.TableHandle, rows: []const []const TableCellInput) !void {
            const alloc = scratchAlloc(self);
            const wire_rows = try alloc.alloc([]protocol.TableCell, rows.len);
            @memset(wire_rows, &.{});
            defer {
                for (wire_rows) |r| {
                    for (r) |c| if (c.spans) |s| alloc.free(s);
                    alloc.free(r);
                }
                alloc.free(wire_rows);
            }
            for (rows, 0..) |row, ri| {
                const wire_row = try alloc.alloc(protocol.TableCell, row.len);
                for (wire_row) |*w| w.* = .{};
                wire_rows[ri] = wire_row;
                for (row, 0..) |c, ci| {
                    wire_row[ci] = .{
                        .display = if (c.spans == null) c.display else null,
                        .spans = if (c.spans) |s| try tableSpansToWire(alloc, s) else null,
                        .sort_key = sortKeyToJson(c.sort_key),
                        .icon = c.icon,
                        .fg = colorToJson(c.fg),
                        .metadata_id = c.metadata_id,
                    };
                }
            }
            try self.notify("table_set_rows", .{ .layer = layer, .table = table, .rows = wire_rows });
        }

        /// `table_set_sort(layer?, table, column?, direction?)` -- a
        /// notification. `column: null` or `direction: .none` both mean "back
        /// to insertion order". Repaints immediately -- this is the message a
        /// future sort-aware `glyphwire-shell` click handler would call.
        pub fn tableSetSort(self: *Self, layer: ?core.LayerHandle, table: core.TableHandle, column: ?usize, direction: core.SortDirection) !void {
            try self.notify("table_set_sort", .{
                .layer = layer,
                .table = table,
                .column = column,
                .direction = @tagName(direction),
            });
        }

        /// `table_set_style(layer?, table, style)` -- a notification. Replaces
        /// the table's whole style (e.g. toggling `alt_row_bg` on/off) and
        /// repaints.
        pub fn tableSetStyle(self: *Self, layer: ?core.LayerHandle, table: core.TableHandle, style: TableStyleInput) !void {
            try self.notify("table_set_style", .{ .layer = layer, .table = table, .style = tableStyleToJson(style) });
        }

        pub fn destroyOutline(self: *Self, layer: ?core.LayerHandle, outline: core.OutlineHandle) !void {
            try self.notify("destroy_outline", .{ .layer = layer, .outline = outline });
        }

        /// `outline_set_nodes(layer?, outline, nodes)` -- replaces the node
        /// list wholesale and repaints, like `table_set_rows`. Worth
        /// batching: `gw-grep` sends its whole result list in one frame
        /// alongside the metadata handles its nodes are tagged with.
        pub fn outlineSetNodes(
            self: *Self,
            layer: ?core.LayerHandle,
            outline: core.OutlineHandle,
            nodes: []const OutlineNodeInput,
        ) !void {
            const alloc = scratchAlloc(self);
            const wire_nodes = try outlineNodesToJson(alloc, nodes);
            defer freeOutlineNodesJson(alloc, wire_nodes);
            try self.notify("outline_set_nodes", .{ .layer = layer, .outline = outline, .nodes = wire_nodes });
        }

        /// `outline_set_collapsed(layer?, outline, node, collapsed?)`.
        /// A null `collapsed` toggles.
        pub fn outlineSetCollapsed(
            self: *Self,
            layer: ?core.LayerHandle,
            outline: core.OutlineHandle,
            node: usize,
            collapsed: ?bool,
        ) !void {
            try self.notify("outline_set_collapsed", .{
                .layer = layer,
                .outline = outline,
                .node = node,
                .collapsed = collapsed,
            });
        }

        /// `outline_set_all_collapsed(layer?, outline, collapsed, depth?)` --
        /// every collapsible node, or every one at `depth`, in one reflow.
        pub fn outlineSetAllCollapsed(
            self: *Self,
            layer: ?core.LayerHandle,
            outline: core.OutlineHandle,
            collapsed: bool,
            depth: ?u8,
        ) !void {
            try self.notify("outline_set_all_collapsed", .{
                .layer = layer,
                .outline = outline,
                .collapsed = collapsed,
                .depth = depth,
            });
        }

        pub fn outlineSetStyle(
            self: *Self,
            layer: ?core.LayerHandle,
            outline: core.OutlineHandle,
            style: OutlineStyleInput,
        ) !void {
            try self.notify("outline_set_style", .{
                .layer = layer,
                .outline = outline,
                .style = outlineStyleToJson(style),
            });
        }

        // -- Rects, nine-patches and metadata --

        /// `update_rect(layer?, rect, ...)` -- a notification. Merges `patch`'s
        /// non-null fields into the existing rect; a field left `null` keeps
        /// its current value -- see `core.RectUpdate`'s doc comment.
        pub fn updateRect(self: *Self, layer: ?core.LayerHandle, handle: core.RectHandle, patch: core.RectUpdate) !void {
            try self.notify("update_rect", rectUpdateParams(layer, handle, patch));
        }

        /// `destroy_rect(layer?, rect)` -- a notification. Removes the rect;
        /// it stops painting immediately.
        pub fn destroyRect(self: *Self, layer: ?core.LayerHandle, handle: core.RectHandle) !void {
            try self.notify("destroy_rect", .{ .layer = layer, .rect = handle });
        }

        /// `set_drop_target(layer?, mode, row?, col?, rows?, cols?)` -- a
        /// notification. Highlights where a drag would drop on `layer`, in
        /// the theme's `drop_target` colour, or clears it with null. Cheap
        /// to repeat: the host ignores a target it already shows.
        pub fn setDropTarget(self: *Self, layer: ?core.LayerHandle, target: ?core.DropTarget) !void {
            try self.notify("set_drop_target", dropTargetParams(layer, target));
        }

        /// `start_drag(uris, label?, icon?)` -- a notification. Asks the
        /// host to begin an OS drag carrying `drag.uris` out of the window,
        /// from the mouse press this client was just handed and the user is
        /// still holding. The host starts it once the pointer moves (the
        /// press may still turn out to be a click); a press already
        /// released, or a host with no OS drag support, drops it.
        pub fn startDrag(self: *Self, drag: core.DragSpec) !void {
            try self.notify("start_drag", drag);
        }

        /// `update_nine_patch(layer?, nine_patch, ...)` -- a notification.
        /// Moves, resizes, or restyles a nine-patch; see `NinePatchUpdate`.
        pub fn updateNinePatch(self: *Self, layer: ?core.LayerHandle, handle: core.NinePatchHandle, patch: NinePatchUpdate) !void {
            try self.notify("update_nine_patch", ninePatchUpdateParams(layer, handle, patch));
        }

        /// `destroy_nine_patch(layer?, nine_patch)` -- a notification. Removes
        /// the nine-patch; it stops painting immediately.
        pub fn destroyNinePatch(self: *Self, layer: ?core.LayerHandle, handle: core.NinePatchHandle) !void {
            try self.notify("destroy_nine_patch", .{ .layer = layer, .nine_patch = handle });
        }

        /// `destroy_metadata(id)` -- a notification. Frees `id`'s stored JSON;
        /// any cell still tagged with it afterward is left with a dangling
        /// reference -- `getMetadata` resolves that gracefully (reports the
        /// id, `json: null`) rather than erroring. There's no reference
        /// counting yet, so this is the caller's responsibility to get right.
        pub fn destroyMetadata(self: *Self, id: core.MetadataHandle) !void {
            try self.notify("destroy_metadata", .{ .id = id });
        }

        // -- Selection and clipboard --

        /// `set_selection(layer?, anchor, active)` -- a notification. Starts
        /// or replaces the layer's selection (root when `layer` is omitted).
        /// Points are `{above, col}` in the scroll-stable coordinate
        /// `core.SelectionPoint` documents.
        pub fn setSelection(self: *Self, layer: ?core.LayerHandle, anchor: core.SelectionPoint, active: core.SelectionPoint) !void {
            try self.notify("set_selection", .{
                .layer = layer,
                .anchor = .{ .above = anchor.above, .col = anchor.col },
                .active = .{ .above = active.above, .col = active.col },
            });
        }

        /// `update_selection(layer?, active)` -- a notification. Moves only
        /// the active (dragging) end; a no-op if nothing is selected.
        pub fn updateSelection(self: *Self, layer: ?core.LayerHandle, active: core.SelectionPoint) !void {
            try self.notify("update_selection", .{
                .layer = layer,
                .active = .{ .above = active.above, .col = active.col },
            });
        }

        /// `clear_selection(layer?)` -- a notification.
        pub fn clearSelection(self: *Self, layer: ?core.LayerHandle) !void {
            try self.notify("clear_selection", .{ .layer = layer });
        }

        /// `set_clipboard(text)` -- a notification. Replaces the session
        /// clipboard buffer; glyphwire-host mirrors it to the OS clipboard.
        pub fn setClipboard(self: *Self, text: []const u8) !void {
            try self.notify("set_clipboard", .{ .text = text });
        }
    };
}

/// The wire params for a `TextOpts` write: either `text` or `spans`.
/// Every field left null here is absent on the
/// wire (see `notify`) -- which is why the server-side defaults (`pad`
/// false, `selectable` true, `transparent_bg` false, `scale` x1) are
/// written as null rather than spelled out: a syntax-coloured row is
/// mostly spans, and every byte per span counts.
fn textParams(text: ?[]const u8, spans: ?[]const protocol.SpanParams, opts: TextOpts) protocol.WriteTextParams {
    return .{
        .layer = opts.layer,
        .row = opts.row,
        .col = opts.col,
        .text = text,
        .spans = spans,
        .fg = colorToJson(opts.fg),
        .bg = colorToJson(opts.bg),
        .transparent_bg = if (opts.transparent_bg) true else null,
        .metadata_id = opts.metadata_id,
        .scale = if (opts.scale == .x1) null else @tagName(opts.scale),
        .max_cols = opts.max_cols,
        .pad = if (opts.pad) true else null,
        .selectable = if (opts.selectable) null else false,
        .masked = if (opts.masked) true else null,
        .copy_text = opts.copy_text,
        .line_join = if (opts.line_join == .newline) null else @tagName(opts.line_join),
        // Omitted entirely for the overwhelmingly common no-underline
        // write, so nothing grows on the wire for every existing
        // caller. Same reason `spans` is null for a plain write.
        .underline = if (opts.underline == .none) null else @tagName(opts.underline),
        .underline_color = colorToJson(opts.underline_color),
        .strikethrough = if (opts.strikethrough) true else null,
    };
}

fn spansToWire(alloc: std.mem.Allocator, spans: []const Span) ![]protocol.SpanParams {
    const out = try alloc.alloc(protocol.SpanParams, spans.len);
    for (spans, out) |s, *w| w.* = .{
        .text = s.text,
        .fg = colorToJson(s.fg),
        .bg = colorToJson(s.bg),
        .metadata_id = s.metadata_id,
        .transparent_bg = s.transparent_bg,
        .scale = if (s.scale) |sc| @tagName(sc) else null,
        .underline = if (s.underline) |u| @tagName(u) else null,
        .underline_color = colorToJson(s.underline_color),
        .strikethrough = s.strikethrough,
    };
    return out;
}

fn tableSpansToWire(alloc: std.mem.Allocator, spans: []const TableSpanInput) ![]protocol.TableSpan {
    const out = try alloc.alloc(protocol.TableSpan, spans.len);
    for (spans, out) |s, *w| w.* = .{
        .text = s.text,
        .fg = colorToJson(s.fg),
        .bg = colorToJson(s.bg),
        .metadata_id = s.metadata_id,
        .underline = if (s.underline) |u| @tagName(u) else null,
        .underline_color = colorToJson(s.underline_color),
        .strikethrough = s.strikethrough,
    };
    return out;
}

fn clearParams(opts: ClearOpts) protocol.ClearParams {
    return .{
        .layer = opts.layer,
        .row = opts.row,
        .col = opts.col,
        .rows = opts.rows,
        .cols = opts.cols,
        .bg = colorToJson(opts.bg),
    };
}

fn setBgParams(opts: SetBgOpts) protocol.SetBgParams {
    return .{
        .layer = opts.layer,
        .row = opts.row,
        .col = opts.col,
        .rows = opts.rows,
        .cols = opts.cols,
        .bg = colorToJson(opts.bg).?,
    };
}

fn setFgParams(opts: SetFgOpts) protocol.SetFgParams {
    return .{
        .layer = opts.layer,
        .row = opts.row,
        .col = opts.col,
        .rows = opts.rows,
        .cols = opts.cols,
        .fg = colorToJson(opts.fg).?,
    };
}

fn setUnderlineParams(opts: SetUnderlineOpts) protocol.SetUnderlineParams {
    return .{
        .layer = opts.layer,
        .row = opts.row,
        .col = opts.col,
        .rows = opts.rows,
        .cols = opts.cols,
        .underline = @tagName(opts.underline),
        .underline_color = colorToJson(opts.underline_color),
    };
}

/// The wire params for a styled `draw_icon`. `layer` is passed
/// separately so the `*On*` forms can override `opts.layer`.
fn iconParams(layer: ?core.LayerHandle, row: ?usize, col: ?usize, name: []const u8, opts: DrawIconOpts) protocol.DrawIconParams {
    return .{
        .layer = layer,
        .row = row,
        .col = col,
        .name = name,
        .scale = @tagName(opts.scale),
        .h_align = @tagName(opts.h_align),
        .v_align = @tagName(opts.v_align),
        .max_w = opts.max_w,
        .max_h = opts.max_h,
        .metadata_id = opts.metadata_id,
        .foreground = opts.foreground,
    };
}

/// `core.Shadow` in its wire shape.
fn shadowToJson(shadow: ?core.Shadow) ?protocol.ShadowWire {
    const sh = shadow orelse return null;
    return protocol.ShadowWire.fromCore(sh);
}

fn selectionFlowParams(layer: core.LayerHandle, flow: core.SelectionFlow) protocol.PropertyParams {
    return .{
        .layer = layer,
        .property = "selection_flow",
        .mode = @tagName(flow.mode),
        .cols = flow.column_cols,
        .col = flow.origin_col,
    };
}

/// `OutlineStyleInput` in its wire shape. Public for `createOutline`,
/// which is a request and so lives on `Client` and `Batch` separately.
pub fn outlineStyleToJson(st: OutlineStyleInput) protocol.OutlineStyle {
    return .{
        .indent = st.indent,
        .marker_collapsed = st.marker_collapsed,
        .marker_expanded = st.marker_expanded,
        .marker_fg = colorToJson(st.marker_fg),
        .alt_row_bg = colorToJson(st.alt_row_bg),
    };
}

/// Flattens the node list to its wire shape. The caller frees the
/// returned slice and the per-node run slices with
/// `freeOutlineNodesJson`.
fn outlineNodesToJson(alloc: std.mem.Allocator, nodes: []const OutlineNodeInput) ![]protocol.OutlineNode {
    const out = try alloc.alloc(protocol.OutlineNode, nodes.len);
    var built: usize = 0;
    errdefer {
        for (out[0..built]) |n| alloc.free(@constCast(n.runs));
        alloc.free(out);
    }
    for (nodes, 0..) |n, i| {
        const runs = try alloc.alloc(protocol.OutlineRun, n.runs.len);
        for (n.runs, 0..) |r, ri| {
            runs[ri] = .{
                .text = r.text,
                .fg = colorToJson(r.fg),
                .bg = colorToJson(r.bg),
                .metadata_id = r.metadata_id,
            };
        }
        out[i] = .{
            .depth = n.depth,
            .runs = runs,
            .icon = n.icon,
            .metadata_id = n.metadata_id,
            .collapsible = n.collapsible,
            .collapsed = n.collapsed,
        };
        built = i + 1;
    }
    return out;
}

fn freeOutlineNodesJson(alloc: std.mem.Allocator, nodes: []protocol.OutlineNode) void {
    for (nodes) |n| alloc.free(@constCast(n.runs));
    alloc.free(nodes);
}

fn sortKeyToJson(key: ?SortKeyInput) ?std.json.Value {
    const k = key orelse return null;
    return switch (k) {
        .text => |t| .{ .string = t },
        .number => |n| .{ .float = n },
    };
}

/// `update_rect`'s wire params.
fn rectUpdateParams(layer: ?core.LayerHandle, handle: core.RectHandle, patch: core.RectUpdate) protocol.UpdateRectParams {
    return .{
        .layer = layer,
        .rect = handle,
        .x = patch.x,
        .y = patch.y,
        .w = patch.w,
        .h = patch.h,
        .color = colorToJson(patch.color),
        .line_width = patch.line_width,
        .filled = patch.filled,
    };
}

/// `set_drop_target`'s wire params.
fn dropTargetParams(layer: ?core.LayerHandle, target: ?core.DropTarget) protocol.SetDropTargetParams {
    const t = target orelse return .{ .layer = layer, .mode = "none" };
    return switch (t) {
        .layer => .{ .layer = layer, .mode = "layer" },
        .cells => |c| .{ .layer = layer, .mode = "cells", .row = c.row, .col = c.col, .rows = c.rows, .cols = c.cols },
        .insert => |i| .{ .layer = layer, .mode = "insert", .row = i.row, .col = i.col, .rows = i.rows },
    };
}

/// `update_nine_patch`'s wire params.
fn ninePatchUpdateParams(layer: ?core.LayerHandle, handle: core.NinePatchHandle, patch: NinePatchUpdate) protocol.UpdateNinePatchParams {
    return .{
        .layer = layer,
        .nine_patch = handle,
        .row = patch.row,
        .col = patch.col,
        .rows = patch.rows,
        .cols = patch.cols,
        .style = patch.style,
    };
}

/// Flattens the ergonomic `Client.TableStyleInput` (real `core.Color`
/// fields) down to the wire `protocol.TableStyle`. Public for
/// `Client.createTable`.
pub fn tableStyleToJson(s: TableStyleInput) protocol.TableStyle {
    return .{
        .borders = s.borders,
        .header_separator = s.header_separator,
        .box_style = s.box_style,
        .alt_row_bg = colorToJson(s.alt_row_bg),
        .header_fg = colorToJson(s.header_fg),
        .header_bg = colorToJson(s.header_bg),
        .row_height = s.row_height,
        .max_icon_px = s.max_icon_px,
    };
}
