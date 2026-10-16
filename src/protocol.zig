// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: MPL-2.0

const std = @import("std");
const core = @import("core.zig");

/// Pure wire data-transfer objects: the JSON shapes that cross the socket,
/// shared verbatim by the server side (`dispatch.zig` builds them,
/// `server.zig` fans some out) and the client side (`client.zig` builds
/// requests and parses responses/notifications). Keeping the one
/// definition here is what stops the two ends from drifting -- see
/// decisions.md's headless-first split; nothing in this module has
/// behavior, it's data and the odd string-name table only.
///
/// Adding a client-to-server method: its params (and result) struct under
/// "Request params and results", an entry in `Methods`, the handler and
/// its table entry in `dispatch.zig`, then the `Client` / `Batch` method.
///
/// Handle types (`core.LayerHandle`, `core.ImageHandle`, ...) and the
/// `{x,y}` / `{row,col}` position pairs already have a single definition
/// in `core.zig` and serialize as the wire wants, so they're re-exported
/// rather than redeclared.

pub const PxPos = core.PxPos;
pub const CellPos = core.CellPos;

/// A color on the wire: RGBA, or a reference to a theme palette slot
/// (`{"slot": 9}`, 0-23) or role (`{"role": "keyword"}`) that the host
/// resolves against the context's theme -- see `core.theme`. `a`
/// defaults to fully opaque so a client can omit it, and applies to a
/// reference too.
///
/// Serialized compactly by hand (`jsonStringify`): a reference goes out
/// as just `slot`/`role` (plus `a` when it isn't 255), unless `resolved`
/// is set -- which only `get_cells` does, to report the RGBA the
/// reference resolved to alongside the reference itself.
pub const Color = struct {
    r: u8 = 0,
    g: u8 = 0,
    b: u8 = 0,
    a: u8 = 255,
    slot: ?u8 = null,
    role: ?[]const u8 = null,
    /// `r`/`g`/`b`/`a` hold what a reference resolved to; send them too.
    /// Never read off the wire.
    resolved: bool = false,

    pub fn jsonStringify(self: Color, jw: anytype) !void {
        try jw.beginObject();
        const is_ref = self.slot != null or self.role != null;
        if (!is_ref or self.resolved) {
            try jw.objectField("r");
            try jw.write(self.r);
            try jw.objectField("g");
            try jw.write(self.g);
            try jw.objectField("b");
            try jw.write(self.b);
            try jw.objectField("a");
            try jw.write(self.a);
        } else if (self.a != 255) {
            try jw.objectField("a");
            try jw.write(self.a);
        }
        if (self.slot) |s| {
            try jw.objectField("slot");
            try jw.write(s);
        }
        if (self.role) |r| {
            try jw.objectField("role");
            try jw.write(r);
        }
        try jw.endObject();
    }
};

pub const ColorError = error{
    /// A colour's `slot` was outside 0-23, or a theme slot was given as a
    /// reference rather than a colour.
    InvalidColor,
    /// A colour's `role` isn't a `core.theme.Role` name.
    UnknownColorRole,
};

/// A wire colour as a `core.Color`: RGB, or a slot / role reference.
pub fn colorFromWire(c: Color) ColorError!core.Color {
    if (c.slot) |s| {
        if (s >= core.theme.slot_count) return ColorError.InvalidColor;
        return core.Color.slot(@intCast(s)).withAlpha(c.a);
    }
    if (c.role) |name| {
        const r = core.theme.roleByName(name) orelse return ColorError.UnknownColorRole;
        return core.Color.role(r).withAlpha(c.a);
    }
    return .{ .r = c.r, .g = c.g, .b = c.b, .a = c.a };
}

/// A `core.Color` for the wire, a reference kept a reference.
pub fn colorToWire(c: core.Color) Color {
    return switch (c.ref) {
        .none => .{ .r = c.r, .g = c.g, .b = c.b, .a = c.a },
        .slot => |s| .{ .a = c.a, .slot = s },
        .role => |r| .{ .a = c.a, .role = @tagName(r) },
    };
}

/// A theme role's value in `Color`'s shape: `{"slot": n}`, `{"role":
/// "name"}`, or RGB.
pub fn roleValueToWire(v: core.theme.RoleValue) Color {
    return switch (v) {
        .slot => |s| .{ .slot = s },
        .role => |r| .{ .role = @tagName(r) },
        .rgb => |c| .{ .r = c.r, .g = c.g, .b = c.b, .a = c.a },
    };
}

pub fn roleValueFromWire(c: Color) ColorError!core.theme.RoleValue {
    const col = try colorFromWire(c);
    return switch (col.ref) {
        .slot => |s| .{ .slot = s },
        .role => |r| .{ .role = r },
        .none => .{ .rgb = col },
    };
}

/// A theme on the wire: `set_theme`'s `theme`, and (with `own`)
/// `get_theme`'s result. `set_theme` starts from `default` and lays
/// `slots` and `roles` over it, so a partial one is fine; `get_theme`
/// always fills every slot and role. Roles are keyed by
/// `core.theme.Role` name, each value read by `roleValueFromWire`.
pub const ThemeWire = struct {
    name: []const u8 = "",
    dark: bool = true,
    panel_style: ?[]const u8 = null,
    slots: ?[]const Color = null,
    roles: ?std.json.ArrayHashMap(Color) = null,
    /// `get_theme` only: whether the context set this theme itself
    /// rather than following the window's.
    own: bool = false,

    /// Applies this over `t` (`set_theme`'s reading). `t` borrows the
    /// name strings.
    pub fn applyTo(self: ThemeWire, t: *core.theme.Theme) ColorError!void {
        t.name = self.name;
        t.dark = self.dark;
        t.panel_style = self.panel_style orelse
            (if (self.dark) core.theme.panel_dark else core.theme.panel_light);
        if (self.slots) |slots| {
            for (slots, 0..) |c, i| {
                if (i >= core.theme.slot_count) break;
                const col = try colorFromWire(c);
                // A slot is a colour, never a reference to one.
                if (col.ref != .none) return ColorError.InvalidColor;
                t.slots[i] = col;
            }
        }
        if (self.roles) |roles| {
            var it = roles.map.iterator();
            while (it.next()) |e| {
                const r = core.theme.roleByName(e.key_ptr.*) orelse return ColorError.UnknownColorRole;
                t.roles.set(r, try roleValueFromWire(e.value_ptr.*));
            }
        }
    }
};

/// `set_divider_style`'s params: a preset name and/or single-glyph
/// overrides for the bands in the issuing connection's context, both
/// optional. Neither (or both null) goes back to the host's style.
pub const DividerStyleWire = struct {
    /// A `core.divider_style.Preset` name.
    style: ?[]const u8 = null,
    chars: ?DividerCharsWire = null,

    pub const DividerCharsWire = struct {
        h: ?[]const u8 = null,
        v: ?[]const u8 = null,
        cross: ?[]const u8 = null,
        t_down: ?[]const u8 = null,
        t_up: ?[]const u8 = null,
        t_left: ?[]const u8 = null,
        t_right: ?[]const u8 = null,
        tl: ?[]const u8 = null,
        tr: ?[]const u8 = null,
        bl: ?[]const u8 = null,
        br: ?[]const u8 = null,
    };

    pub const Error = error{ UnknownDividerStyle, InvalidDividerChar };

    /// The override this describes. The result owns its glyphs (they are
    /// copied inline), so it outlives the parsed message.
    pub fn toOverride(self: DividerStyleWire) Error!core.divider_style.Override {
        var out: core.divider_style.Override = .{};
        if (self.style) |name| {
            out.preset = std.meta.stringToEnum(core.divider_style.Preset, name) orelse return error.UnknownDividerStyle;
        }
        if (self.chars) |chars| {
            inline for (@typeInfo(DividerCharsWire).@"struct".field_names) |name| {
                if (@field(chars, name)) |text| {
                    @field(out.chars, name) = core.divider_style.Glyph.init(text) orelse return error.InvalidDividerChar;
                }
            }
        }
        return out;
    }

    /// `o` on the wire. Borrows `o`'s glyphs.
    pub fn fromOverride(o: *const core.divider_style.Override) DividerStyleWire {
        var out: DividerStyleWire = .{ .style = if (o.preset) |p| @tagName(p) else null };
        if (o.chars.isEmpty()) return out;
        var chars: DividerCharsWire = .{};
        inline for (@typeInfo(DividerCharsWire).@"struct".field_names) |name| {
            if (@field(o.chars, name)) |*g| @field(chars, name) = g.slice();
        }
        out.chars = chars;
        return out;
    }
};

/// An image background reference in a `get_cells` cell -- the handle, the
/// sub-image pixel offset the cell samples from, and the uniform scale the
/// image is drawn at (`1.0` for a natural-size draw, `< 1.0` when it was
/// shrunk to fit a target width -- see `core.ImageBg`). `src_right`/
/// `src_bottom` report the source-rect clip bound (`core.ImageBg`'s
/// fields of the same name); both default to `maxInt`, i.e. no bound
/// beyond the image's own edge. Only these cross the wire, never the
/// pixels.
pub const ImageBg = struct {
    handle: core.ImageHandle,
    offset_x: u32,
    offset_y: u32,
    scale: f32 = 1.0,
    src_right: u32 = std.math.maxInt(u32),
    src_bottom: u32 = std.math.maxInt(u32),
};

/// An icon background/foreground reference in a `get_cells` cell (see
/// `core.IconBg`). `scale`/`h_align`/`v_align` are the `@tagName` strings
/// of the matching `core` enums; `max_w`/`max_h` are only meaningful when
/// `scale == "natural"`.
pub const IconBg = struct {
    handle: core.ImageHandle,
    scale: []const u8,
    h_align: []const u8,
    v_align: []const u8,
    max_w: ?u32 = null,
    max_h: ?u32 = null,
};

/// One flattened cell in a `get_cells` response, row-major starting at
/// (0,0). Exactly one of `bg`/`bg_image`/`bg_icon` is non-null, per
/// `core.Background`'s tagged union -- see decisions.md's Cell section.
/// `fg_icon` is a sibling of that union, not part of it: an icon drawn
/// *over* the background (`draw_icon`'s `foreground: true`, and every
/// table body icon -- see `core.Cell.fg_icon`), independent of which
/// `bg*` case is set.
pub const WireCell = struct {
    g: []const u8,
    fg: Color,
    bg: ?Color,
    bg_image: ?ImageBg = null,
    bg_icon: ?IconBg = null,
    fg_icon: ?IconBg = null,
    /// Just the id, not the resolved JSON -- same "handle, not content"
    /// treatment `bg_image`/`bg_icon` already give image/icon handles.
    /// `get_metadata` resolves an id to its actual content.
    metadata_id: ?core.MetadataHandle = null,
    /// This cell is the focus cell of its `metadata_id` span -- where
    /// `find_metadata` lands instead of the span's first visible
    /// character. See `core.Cell.meta_focus`.
    focus: bool = false,
    /// East Asian Width role of the cell: `"lead"` = left half of a
    /// 2-cell wide character (holds the grapheme), `"spacer"` = its right
    /// half (renders nothing, carries the lead's bg + metadata), absent =
    /// an ordinary 1-cell character. See decisions.md, Cell content.
    wide: ?[]const u8 = null,
    /// The cell's underline style name (`core.Underline`), absent for the
    /// common `none`. Exposed -- unlike `text_scale`, which isn't -- because
    /// a diagnostic mark is a thing a test or `glyphwire-probe` needs to
    /// read back to know it landed, and there is no other way to see it.
    underline: ?[]const u8 = null,
    /// The underline's colour, absent when it follows `fg`.
    underline_color: ?Color = null,
};

/// The `get_cells` response body: the layer's visible viewport as a
/// row-major `cells` array (`cols * rows` long) plus the layer revision
/// it was snapshotted at.
pub const CellsResult = struct {
    cols: usize,
    rows: usize,
    revision: u64,
    cells: []const WireCell,
};

/// The `get_input_state` response body: the authoritative down-sets plus
/// the last known cursor position.
pub const InputStateResult = struct {
    keys_down: []const []const u8,
    mouse_buttons_down: []const []const u8,
    cursor_px: PxPos,
    cursor_cell: CellPos,
};

/// One row of a `list_contexts` response.
pub const ContextEntry = struct {
    context: core.ContextHandle,
    /// Empty when the program never named its context.
    title: []const u8,
    /// Whether this is the one on screen in the pane (always the first).
    visible: bool,
};

/// The `list_contexts` response body: the issuing connection's pane
/// stack, top (on screen) first, plus which of them is the connection's
/// own active context -- the one thing a client can't otherwise learn
/// about itself when it inherited its context rather than creating it.
pub const ListContextsResult = struct {
    current: core.ContextHandle,
    contexts: []const ContextEntry,
};

// ─── Table ───────────────────────────────────────────────────────────────

/// A column as sent to `create_table`. `kind`/`h_align` are optional
/// wire strings (`null` means the `core` enum's default: `"text"` /
/// `"start"`); the client fills them in explicitly, a raw socket client
/// can omit them.
pub const TableColumn = struct {
    name: []const u8,
    /// "text" (default) or "number" -- see `core.ColumnKind`.
    kind: ?[]const u8 = null,
    sortable: bool = false,
    /// Fold ASCII case when sorting a `.text` column -- see
    /// `core.TableColumn.case_insensitive`.
    case_insensitive: bool = false,
    /// Land Ctrl+PgUp/PgDn on this column's body cell -- see
    /// `core.TableColumn.focus`.
    focus: bool = false,
    width: usize,
    min_width: usize = 1,
    /// "start" (default), "center", or "end".
    h_align: ?[]const u8 = null,
    /// "ellipsis" (default) or "wrap" -- see `core.TableOverflow`.
    overflow: ?[]const u8 = null,
};

/// A table's style, shared by `create_table`'s `style`, `table_set_style`'s,
/// and the read-back `table_get_state` reports -- the wire and read-back
/// shapes are identical. Every field defaults, so a client can send a
/// partial style.
pub const TableStyle = struct {
    borders: bool = true,
    header_separator: bool = true,
    box_style: ?[]const u8 = null,
    alt_row_bg: ?Color = null,
    header_fg: ?Color = null,
    header_bg: ?Color = null,
    row_height: usize = 1,
    /// Upper bound in pixels on a body icon's rendered height (see
    /// `core.TableStyle.max_icon_px`). Omitted → the row height alone
    /// bounds it.
    max_icon_px: ?u32 = null,
};

/// One row's cell, as sent to `table_set_rows`. `sort_key` (see
/// `core.SortKey`'s doc comment) is left as a raw `std.json.Value` rather
/// than a typed field, since it's naturally either a JSON number or a
/// JSON string depending on the column -- a number parses as `.number`,
/// a string as `.text`, anything else (or the field omitted) falls back
/// to a copy of `display`.
pub const TableCell = struct {
    display: []const u8,
    sort_key: ?std.json.Value = null,
    /// An icon-registry name, resolved the same way `draw_icon`'s `name`
    /// is (`Context.iconHandle`).
    icon: ?[]const u8 = null,
    fg: ?Color = null,
    metadata_id: ?core.MetadataHandle = null,
};

/// A column as reported back by `table_get_state` -- `kind`/`h_align`
/// are resolved to their concrete `@tagName` strings here, never null.
pub const ColumnState = struct {
    name: []const u8,
    kind: []const u8,
    sortable: bool,
    case_insensitive: bool,
    focus: bool,
    width: usize,
    min_width: usize,
    h_align: []const u8,
    overflow: []const u8,
};

/// Where a table last painted (`core.Table.painted`) -- a client that
/// wants to place something below the table (e.g. `glyphwire-ls -l`'s
/// next shell prompt) needs this rather than recomputing the layout math
/// `Table.render` already did, which would drift the moment that layout
/// changes.
pub const TablePainted = struct {
    row: usize,
    col: usize,
    rows: usize,
    cols: usize,
};

/// The `table_get_state` response body.
pub const TableStateResult = struct {
    columns: []const ColumnState,
    row_count: usize,
    sort_column: ?usize,
    sort_direction: []const u8,
    style: TableStyle,
    painted: TablePainted,
    revision: u64,
};

// ─── Outline ───────────────────────────────────────────────

/// One styled run of a node's row -- `write_text`'s `spans` shape, so a
/// grep hit's line number, its matched bytes and its tail can each carry
/// their own colour inside one row. `fg`/`bg` omitted take the layer's
/// default foreground and the row's own background (an `alt_row_bg`
/// stripe, or transparent).
pub const OutlineRun = struct {
    text: []const u8,
    fg: ?Color = null,
    bg: ?Color = null,
    /// Overrides the node's `metadata_id` for just this run's cells.
    metadata_id: ?core.MetadataHandle = null,
};

/// A node as sent to `outline_set_nodes`. The list is flat: `depth` is
/// what makes it a tree, and a collapsed node hides the contiguous run of
/// following nodes with a greater depth.
pub const OutlineNode = struct {
    depth: u8 = 0,
    runs: []const OutlineRun,
    /// An icon-registry name, resolved like `draw_icon`'s `name`.
    icon: ?[]const u8 = null,
    /// Tags every cell the row paints, so a click off the marker resolves
    /// through `get_metadata` like any other span.
    metadata_id: ?core.MetadataHandle = null,
    collapsible: bool = false,
    collapsed: bool = false,
};

/// An outline's style, shared by `create_outline`'s `style`,
/// `outline_set_style`'s, and what `outline_get_state` reports back.
pub const OutlineStyle = struct {
    /// Cells of indent per depth level, on top of the marker gutter.
    indent: usize = 2,
    /// The marker glyphs. Omitted, they default to the pointing triangles.
    marker_collapsed: ?[]const u8 = null,
    marker_expanded: ?[]const u8 = null,
    marker_fg: ?Color = null,
    alt_row_bg: ?Color = null,
};

/// One node as reported by `outline_get_state`. `visible` is whether the
/// node is on screen right now, i.e. no collapsed node above it in the
/// list is shallower -- derived state a client would otherwise have to
/// re-walk the list for.
pub const OutlineNodeState = struct {
    depth: u8,
    collapsible: bool,
    collapsed: bool,
    visible: bool,
};

/// The `outline_get_state` response body. `painted` is the same shape and
/// purpose `table_get_state`'s has: where the outline actually drew, for a
/// caller placing its own content below it.
pub const OutlineStateResult = struct {
    nodes: []const OutlineNodeState,
    node_count: usize,
    visible_rows: usize,
    style: OutlineStyle,
    painted: TablePainted,
    revision: u64,
};

// ─── Request params and results ──────────────────────────────────────────
//
// What a client sends for each request and notification method, and what a
// request answers with. `dispatch.zig` parses these and `client.zig` builds
// them, so a field added or renamed on one end is a compile error on the
// other rather than a key the server silently ignores.
//
// A field a client may leave out is `?T = null`, with the handler applying
// the real default. The client encodes with nulls omitted (see
// `Client.notify`), and the null default is what makes "absent" and "null"
// mean the same thing to the server.

/// `layer` (omitted, or `root_layer_handle`) means the root layer.
/// `row`/`col` place the cursor before writing, each defaulting to the
/// cursor's current value -- the same rule `draw_icon`/`draw_image` use,
/// so a positioned write is one message rather than a `set_property`
/// cursor move followed by a write.
pub const WriteTextParams = struct {
    layer: ?core.LayerHandle = null,
    row: ?usize = null,
    col: ?usize = null,
    /// Exactly one of `text` and `spans`.
    text: ?[]const u8 = null,
    /// Styled runs written back to back as one write -- a syntax-coloured
    /// row, or a status line with a highlighted word, in one message.
    /// Each span's omitted fields fall back to this message's own.
    spans: ?[]const SpanParams = null,
    /// See `core.Layer.WriteOpts.max_cols`.
    max_cols: ?usize = null,
    /// See `core.Layer.WriteOpts.pad`. Omitted: false.
    pad: ?bool = null,
    /// `false` marks every cell this write touches as outside any
    /// selection -- see `core.Cell.selectable`. Whole-write, like `pad`.
    /// Omitted: true.
    selectable: ?bool = null,
    /// What a selection copies for each glyph this write draws, instead
    /// of the glyph -- see `core.Cell.copy_alt`. Whole-write, like `pad`.
    copy_text: ?[]const u8 = null,
    fg: ?Color = null,
    bg: ?Color = null,
    /// See `core.Cell.metadata_id`'s doc comment.
    metadata_id: ?core.MetadataHandle = null,
    /// `false` (or omitted): `bg` omitted means "reset to
    /// `core.default_style.bg`" -- the original, still-default behavior.
    /// `true`: leaves each touched cell's existing background untouched
    /// instead (`bg` is ignored either way when this is set), for writing
    /// text over a background drawn some other way -- e.g. a nine-patch's
    /// fill -- that needs to stay visible through it rather than being
    /// approximated with a matching flat color.
    transparent_bg: ?bool = null,
    /// `"x1"` (default), `"x1_5"`, `"x2"`, or `"x3"` -- see `core.TextScale`'s
    /// doc comment. Wire strings match the enum's tag names exactly, the
    /// same convention `draw_icon`'s `scale` already uses.
    scale: ?[]const u8 = null,
    /// `"none"` (default), `"single"`, `"double"`, `"curly"`, `"dotted"` or
    /// `"dashed"` -- see `core.Underline`. Tag names again, like `scale`.
    underline: ?[]const u8 = null,
    /// The underline's colour; omitted means the text's own `fg`, which is
    /// what an ordinary underline wants. A diagnostic squiggle sets it so
    /// the line can be red under syntax-coloured text.
    underline_color: ?Color = null,
};

/// One entry of `write_text`'s `spans`. Every field but `text` is optional
/// and inherits the enclosing message's value when omitted.
pub const SpanParams = struct {
    text: []const u8,
    fg: ?Color = null,
    bg: ?Color = null,
    metadata_id: ?core.MetadataHandle = null,
    transparent_bg: ?bool = null,
    scale: ?[]const u8 = null,
    underline: ?[]const u8 = null,
    underline_color: ?Color = null,
};

/// Params shared by `insert_cells`/`delete_cells` -- also cursor-implicit
/// like `write_text`, see `WriteTextParams`.
pub const CellCountParams = struct {
    layer: ?core.LayerHandle = null,
    count: usize,
};

pub const MoveContentParams = struct {
    layer: ?core.LayerHandle = null,
    /// Inclusive content-grid row range, defaulting to the whole grid.
    top: ?usize = null,
    bot: ?usize = null,
    /// Rows to shift, clamped to the span. Defaults to 1.
    count: usize = 1,
    /// `"up"` (default) or `"down"` -- the sense of CSI SU/SD.
    direction: ?[]const u8 = null,
};

/// Params shared by `set_property`/`get_property`. Not every field is
/// meaningful for every `property` value -- `row`/`col` for `"cursor"`
/// and `"cell_position"`, `x`/`y` for `"position"`, `cols`/`rows` for
/// `"size"`, `visible` for `"visibility"` -- the handler picks which
/// subset to read once it knows `property`, the same "flexible bag,
/// dispatched on a string" shape `ClearParams` already uses for its own
/// optional fields.
pub const PropertyParams = struct {
    layer: ?core.LayerHandle = null,
    property: []const u8,
    /// Omitted: 0. Every number and bool below is optional so a client
    /// sends only the fields its property reads; `handleSetProperty`
    /// applies the defaults.
    row: ?usize = null,
    col: ?usize = null,
    x: ?f32 = null,
    y: ?f32 = null,
    cols: ?usize = null,
    rows: ?usize = null,
    /// Omitted: true.
    visible: ?bool = null,
    /// Omitted: false.
    vertical: ?bool = null,
    horizontal: ?bool = null,
    /// `"pty_mode"`'s, `"mouse_select"`'s and `"mouse_report"`'s bool -- kept off `visible`
    /// so a client setting one property doesn't have to think about the
    /// other's default. Omitted: false.
    enabled: ?bool = null,
    /// `"opacity"`'s 0.0..1.0 factor. Omitted means fully opaque, so a
    /// client that names the property and forgets the field gets the
    /// layer back rather than losing it.
    value: ?f32 = null,
    /// `"scroll_mode"`'s `"host"` / `"client"`.
    mode: ?[]const u8 = null,
    /// `"background"`'s colour; omitted clears it back to transparent.
    color: ?Color = null,
    /// `"shadow"`'s shape; omitted removes the shadow.
    shadow: ?ShadowWire = null,
    /// `"resize_edge"`'s `"top"` / `"bottom"` / `"left"` / `"right"` /
    /// `"none"`; omitted is `"none"`.
    edge: ?[]const u8 = null,
};

/// `core.Shadow` on the wire. Every field is optional with the core's
/// default, so `{"shadow": {"y": 6, "blur": 10}}` is a whole shadow.
pub const ShadowWire = struct {
    x: i32 = 0,
    y: i32 = 0,
    blur: u32 = 0,
    radius: u32 = 0,
    spread: i32 = 0,
    color: Color = .{ .r = 0, .g = 0, .b = 0, .a = 128 },

    pub fn toCore(self: ShadowWire) ColorError!core.Shadow {
        return .{
            .x = self.x,
            .y = self.y,
            .blur = self.blur,
            .radius = self.radius,
            .spread = self.spread,
            .color = try colorFromWire(self.color),
        };
    }

    pub fn fromCore(sh: core.Shadow) ShadowWire {
        return .{
            .x = sh.x,
            .y = sh.y,
            .blur = sh.blur,
            .radius = sh.radius,
            .spread = sh.spread,
            .color = colorToWire(sh.color),
        };
    }
};

pub const CursorResult = struct { row: usize, col: usize };

pub const RevisionResult = struct { revision: u64 };

pub const PositionResult = struct { x: f32, y: f32 };

pub const CellPositionResult = struct { row: usize, col: usize };

pub const SizeResult = struct { cols: usize, rows: usize };

pub const ScrollResult = struct { offset: usize, max: usize };

pub const VisibilityResult = struct { visible: bool };

pub const OpacityResult = struct { value: f32 };

pub const PtyModeResult = struct { enabled: bool };

pub const ScrollModeResult = struct { mode: []const u8 };

pub const SelectionFlowResult = struct { mode: []const u8, cols: usize, col: usize };

pub const BackgroundResult = struct { color: ?Color };

pub const ShadowResult = struct { shadow: ?ShadowWire };

pub const ResizeEdgeResult = struct { edge: []const u8 };

pub const ScrollOffsetResult = struct { row: usize, col: usize, max_row: usize, max_col: usize };

pub const ScrollbarsResult = struct {
    vertical: bool,
    horizontal: bool,
    row: usize,
    col: usize,
    max_row: usize,
    max_col: usize,
};

/// `scroll_view` params: `offset` (absolute target, rows) and/or `delta`
/// (added after), both optional -- omitting both is a pure query. See
/// `core.Layer.scrollView`.
pub const ScrollViewParams = struct {
    layer: ?core.LayerHandle = null,
    offset: ?usize = null,
    delta: ?i64 = null,
};

pub const GetCellsParams = struct {
    layer: ?core.LayerHandle = null,
    /// Rows of scrollback to read above the live viewport (see
    /// `core.Layer.viewRow`). 0 (default) is the live viewport -- the
    /// original behavior. Non-zero lets a client read what the user is
    /// actually looking at while glyphwire-host is scrolled back.
    view_offset: usize = 0,
};

pub const CreateLayerParams = struct {
    width: ?usize = null,
    height: ?usize = null,
    scrollback_rows: usize = 0,
};

pub const CreateLayerResult = struct { handle: core.LayerHandle };

/// `create_context`: an independent context (its own root layer, split
/// tree, layers, tables -- see `core.Session`), created in the issuing
/// connection's pane and shown there immediately. `width` / `height`
/// default to that pane's size.
pub const CreateContextParams = struct {
    width: ?usize = null,
    height: ?usize = null,
    scrollback_rows: usize = 0,
    /// Whether glyphwire-host draws its always-on right-edge scrollbar
    /// for this context (see `core.Context.window_scrollbar`). Default
    /// on -- a pure-TUI client passes false.
    window_scrollbar: bool = true,
    /// The context's display name (see `core.Context.title`). Optional:
    /// `set_context_title` can name it, or rename it, later.
    title: ?[]const u8 = null,
};

pub const CreateContextResult = struct { context: core.ContextHandle };

/// `set_context_title`: names the issuing connection's active context.
pub const SetContextTitleParams = struct { title: []const u8 };

/// `set_theme`: one of `name` (a built-in) or `theme` (a whole theme the
/// client resolved itself), or neither to go back to the window's theme.
pub const SetThemeParams = struct {
    name: ?[]const u8 = null,
    theme: ?ThemeWire = null,
};

/// `destroy_context` / `activate_context` / `adopt_context` -- all just
/// name one context handle.
pub const ContextHandleParams = struct { context: core.ContextHandle };

/// `set_window_scrollbar`: toggles the always-on window scrollbar on the
/// issuing connection's active context after the fact -- the runtime
/// counterpart of `create_context`'s `window_scrollbar`.
pub const SetWindowScrollbarParams = struct { visible: bool };

/// `set_caret_layer`: which layer glyphwire-host draws its caret for, or
/// `null` for the root cursor. See `core.Context.caret_layer`.
pub const SetCaretLayerParams = struct { layer: ?core.LayerHandle = null };

/// `set_caret_visible`: whether glyphwire-host draws a caret for the
/// issuing connection's active context. See `core.Context.caret_visible`.
pub const SetCaretVisibleParams = struct { visible: bool };

/// `set_caret_shape`: the shape glyphwire-host draws the caret in, or
/// `null` for the host's configured one. See `core.Context.caret_shape`.
pub const SetCaretShapeParams = struct { shape: ?core.CaretShape = null };

/// `set_key_repeat`: the typematic key-repeat timing this context's
/// program wants while it is focused. Both fields absent clears the
/// override and puts the context back on the host's default; one alone
/// keeps whatever the other was (the default's value when there was no
/// override yet). See `core.Context.key_repeat`.
pub const SetKeyRepeatParams = struct {
    delay_ms: ?f64 = null,
    interval_ms: ?f64 = null,
};

// ─── Pane params ───────────────────────────────────────────────────────
//
// The window-level mirror of the split params above. See session.zig's Panes
// section for what a pane is and why the two levels are separate types.

/// `request_role`: asks for a privileged role. The only one today is
/// `"window_manager"`, which gates every message below.
/// `request_role`: claims a privileged role, or joins one this program's
/// other connection already holds by presenting its `token`.
pub const RequestRoleParams = struct {
    role: []const u8,
    token: ?u64 = null,
};

/// The token is what a program's second connection passes to join the same
/// role -- see `core.Session.managers`. Null when the role was refused.
pub const RequestRoleResult = struct {
    granted: bool,
    token: ?u64 = null,
};

/// `attach_pane`: binds this connection to a pane. Sent as a connection's
/// first message by anything started with `GLYPHWIRE_PANE` set.
pub const AttachPaneParams = struct { pane: core.PaneHandle };

/// `create_pane`: a new pane plus the base context it shows.
/// `scrollback_rows` is that context's root layer's ring, so a terminal
/// pane asks for history and a TUI pane asks for none.
pub const CreatePaneParams = struct { scrollback_rows: usize = 0 };

pub const CreatePaneResult = struct {
    pane: core.PaneHandle,
    context: core.ContextHandle,
};

/// `destroy_pane` / `focus_pane` -- both just name one pane.
pub const PaneHandleParams = struct { pane: core.PaneHandle };

/// `create_pane_split`: an empty window-level container.
pub const CreatePaneSplitParams = struct {
    axis: []const u8,
    /// Whether the bands between this split's children can be dragged.
    /// See `core.PaneSplit.resizable`.
    resizable: bool = true,
};

pub const CreatePaneSplitResult = struct { split: core.PaneSplitHandle };

pub const PaneSplitHandleParams = struct { split: core.PaneSplitHandle };

/// One `set_pane_split_children` entry: exactly one of `pane` / `split`,
/// and exactly one of `weight` / `fixed` (both omitted means weight 1).
pub const PaneSplitChildParams = struct {
    pane: ?core.PaneHandle = null,
    split: ?core.PaneSplitHandle = null,
    weight: ?f32 = null,
    fixed: ?usize = null,

    /// A pane taking a share of whatever the fixed siblings leave.
    pub fn paneWeighted(handle: core.PaneHandle, weight: f32) PaneSplitChildParams {
        return .{ .pane = handle, .weight = weight };
    }

    /// A pane with an exact extent along the split's axis -- a fixed-width
    /// sidebar pane, a one-row status pane.
    pub fn paneFixed(handle: core.PaneHandle, cells: usize) PaneSplitChildParams {
        return .{ .pane = handle, .fixed = cells };
    }

    pub fn splitWeighted(handle: core.PaneSplitHandle, weight: f32) PaneSplitChildParams {
        return .{ .split = handle, .weight = weight };
    }

    pub fn splitFixed(handle: core.PaneSplitHandle, cells: usize) PaneSplitChildParams {
        return .{ .split = handle, .fixed = cells };
    }
};

pub const SetPaneSplitChildrenParams = struct {
    split: core.PaneSplitHandle,
    children: []const PaneSplitChildParams,
};

/// `set_root_pane_split`: null tears the window layout down, leaving the
/// root pane as the whole window again.
pub const SetRootPaneSplitParams = struct { split: ?core.PaneSplitHandle = null };

pub const MovePaneDividerParams = struct {
    split: core.PaneSplitHandle,
    index: usize,
    delta: i64,
};

/// `spawn_in_pane`: starts a program seated in a pane. `argv[0]` is
/// resolved through `PATH`. The child is handed `GLYPHWIRE_PANE` so it
/// binds itself to this pane on connect, which is the whole handshake --
/// see `core.Pane`.
pub const SpawnInPaneParams = struct {
    pane: core.PaneHandle,
    argv: []const []const u8,
    /// PTY size for the child. Defaults to the pane's own cells, which is
    /// what a program should almost always get.
    cols: ?usize = null,
    rows: ?usize = null,
};

pub const SpawnInPaneResult = struct { pid: i64 };

/// `start_remote`: brings up an `ssh` trunk to `dest` whose remote clients
/// draw into *this connection's* pane. Unlike `spawn_in_pane` there is no
/// pane parameter and no window-manager role: the caller is a program
/// already seated in the pane it wants to hand over, and naming someone
/// else's pane is exactly what it must not be able to do.
pub const StartRemoteParams = struct {
    dest: []const u8,
    /// Extra arguments inserted before `dest` on the `ssh` command line.
    ssh_args: []const []const u8 = &.{},
    /// The agent command run on the far side; null means `gw-agent`.
    remote_command: ?[]const u8 = null,
};

pub const StartRemoteResult = struct { session: u64 };

/// `stop_remote`: tears down a session `start_remote` returned. Idempotent
/// -- a session that already ended is not an error, because the caller
/// races the `remote_exit` notification by nature.
pub const StopRemoteParams = struct { session: u64 };

/// `set_window_prefix`: the chord after which one keystroke is delivered to
/// the window manager instead of to the focused pane. Null `key` clears it.
/// See `core.WindowPrefix`.
pub const SetWindowPrefixParams = struct {
    key: ?[]const u8 = null,
    ctrl: bool = true,
    alt: bool = false,
    shift: bool = false,
};

pub const DestroyLayerParams = struct {
    layer: core.LayerHandle,
};

/// `raise_layer` / `lower_layer`: `layer` moves in the compositing order,
/// `above` / `below` names the layer it lands next to. Both references are
/// optional -- omitted means "all the way to the top" / "all the way to
/// the bottom". Two field names rather than one shared `ref` so the JSON
/// reads the way the message does.
pub const RaiseLayerParams = struct {
    layer: core.LayerHandle,
    above: ?core.LayerHandle = null,
};

pub const LowerLayerParams = struct {
    layer: core.LayerHandle,
    below: ?core.LayerHandle = null,
};

pub const CreateSplitParams = struct {
    /// `"row"` (children left to right) or `"column"` (top to bottom).
    axis: []const u8,
    /// Whether the user may drag this split's dividers (see
    /// `core.Split.resizable`). Default true; a structural split like an
    /// editor's buffer-area-over-command-line passes false so the fixed
    /// child gets no grab band and no wasted row.
    resizable: bool = true,
};

pub const CreateSplitResult = struct { handle: core.SplitHandle };

pub const DestroySplitParams = struct { split: core.SplitHandle };

/// One entry of `set_split_children`. `layer` and `split` are the two
/// possible targets and exactly one must be given; `weight` and `fixed`
/// are the two possible sizes and at most one (defaulting to an equal
/// weight). Four optional fields rather than a tagged shape because
/// that's what JSON round-trips cleanly through `parseFromValue` without
/// a custom parser -- the validation is here instead.
pub const SplitChildParams = struct {
    layer: ?core.LayerHandle = null,
    split: ?core.SplitHandle = null,
    weight: ?f32 = null,
    fixed: ?usize = null,

    /// A layer taking a share of whatever the fixed siblings leave.
    pub fn layerWeighted(handle: core.LayerHandle, weight: f32) SplitChildParams {
        return .{ .layer = handle, .weight = weight };
    }

    /// A layer with an exact extent along the split's axis -- a one-row
    /// statusline, a fixed-width gutter.
    pub fn layerFixed(handle: core.LayerHandle, cells: usize) SplitChildParams {
        return .{ .layer = handle, .fixed = cells };
    }

    /// A nested split taking a share.
    pub fn splitWeighted(handle: core.SplitHandle, weight: f32) SplitChildParams {
        return .{ .split = handle, .weight = weight };
    }

    /// A nested split with an exact extent.
    pub fn splitFixed(handle: core.SplitHandle, cells: usize) SplitChildParams {
        return .{ .split = handle, .fixed = cells };
    }
};

pub const SetSplitChildrenParams = struct {
    split: core.SplitHandle,
    children: []const SplitChildParams,
};

pub const SetRootSplitParams = struct { split: ?core.SplitHandle = null };

pub const MoveDividerParams = struct {
    split: core.SplitHandle,
    index: usize,
    delta: i64,
};

/// `adopt_layer` params -- same single-handle shape as `destroy_layer`,
/// kept as its own type so the two messages stay independently
/// documented.
pub const AdoptLayerParams = struct {
    layer: core.LayerHandle,
};

pub const CreateMetadataParams = struct {
    json: []const u8,
    /// Makes the tagged span draggable out of the window (glyphwire-host:
    /// Alt+drag). See `core.DragSpec`.
    drag: ?core.DragSpec = null,
};

pub const CreateMetadataResult = struct { handle: core.MetadataHandle };

pub const DestroyMetadataParams = struct {
    id: core.MetadataHandle,
};

pub const GetMetadataParams = struct {
    layer: ?core.LayerHandle = null,
    row: usize,
    col: usize,
    /// Rows of scrollback to resolve `(row, col)` against, above the live
    /// viewport (see `core.Layer.viewRow`). 0 (default) is the live
    /// viewport. Non-zero is what lets a mouse click landing on a
    /// scrolled-back row resolve to the cell the user actually sees
    /// there, not the live-buffer cell at the same screen position.
    view_offset: usize = 0,
};

/// `id`/`json` are both null together (the cell isn't tagged) or `id` is
/// set with `json` still possibly null (tagged, but the id has since been
/// `destroy_metadata`'d -- see `Context.destroyMetadata`'s doc comment).
/// Reporting `id` even when `json` can't be resolved is what lets a
/// caller like a future mouse-click handler tell those two cases apart.
pub const GetMetadataResult = struct {
    id: ?core.MetadataHandle,
    json: ?[]const u8,
};

/// `find_metadata` params: the content cell to start from (`above` in
/// `core.SelectionPoint`'s scroll-stable coordinate -- positive counts up
/// into scrollback) and which way to look. `"next"` walks forward in
/// reading order, `"prev"` backward; anything else -> InvalidMetadataDirection.
pub const FindMetadataParams = struct {
    layer: ?core.LayerHandle = null,
    above: i64 = 0,
    col: usize = 0,
    direction: ?[]const u8 = null,
};

/// `find_metadata` result: `found` false means there's no further span in
/// that direction (the other fields are then unset). `above`/`col` are the
/// first visible character of the neighbouring span, `id` its metadata id.
pub const FindMetadataResult = struct {
    found: bool,
    above: i64 = 0,
    col: usize = 0,
    id: ?core.MetadataHandle = null,
};

pub const CellMetricsResult = struct { cell_px_w: u32, cell_px_h: u32 };

pub const ReportKeyParams = struct {
    key: []const u8,
    pressed: bool,
};

pub const ReportTextParams = struct {
    text: []const u8,
};

pub const ReportMouseButtonParams = struct {
    button: []const u8,
    pressed: bool,
    px: PxPos,
    cell: CellPos,
    /// The root layer's scrollback view offset (see `core.Layer.view_scroll`)
    /// at the moment of the click, so a subscriber resolving `cell` with
    /// `get_metadata` can pass the same `view_offset` and land on the row
    /// the user actually clicked while scrolled back. 0 (default) when the
    /// reporter is at the live tail or doesn't track scrollback.
    view_offset: usize = 0,
    /// The press's click count (see `MouseButtonParams.clicks`),
    /// passed through to the broadcast. 1 from a reporter that doesn't
    /// count.
    clicks: u8 = 1,
};

pub const ReportMouseMoveParams = struct {
    px: PxPos,
    cell: CellPos,
};

pub const SubscribeParams = struct {
    events: []const []const u8,
    /// Optional: binds this connection to a pane at the same time, exactly
    /// as `attach_pane` would. Folded into `subscribe` because `subscribe`
    /// is what arms the broadcast fan-out -- a connection that were
    /// subscribed but not yet bound would, until the binding landed, be
    /// gated against the wrong pane and could receive input meant for
    /// another program. See `InputListener.sendSubscribeAndWaitForAck`.
    pane: ?core.PaneHandle = null,
};

pub const SubscribeResult = struct {
    subscribed: []const []const u8,
};

pub const ImageInfoParams = struct { handle: core.ImageHandle };

pub const ImageInfoResult = struct { width: u32, height: u32 };

pub const LoadImageResult = struct { handle: core.ImageHandle };

/// `row`/`col` are optional, same as `write_text`'s documented (if not
/// yet wired in there) convention: omitted means "at the layer's
/// cursor" -- see `handleDrawImage`/`resolveAnchor`.
pub const DrawImageParams = struct {
    layer: ?core.LayerHandle = null,
    handle: core.ImageHandle,
    row: ?usize = null,
    col: ?usize = null,
    row_span: usize,
    col_span: usize,
    /// Uniform scale the image is drawn at -- `1.0` (the default) is the
    /// original natural-size placement; `< 1.0` shrinks it (glyphwire-view
    /// asks for `target_width_px / image_width_px` so the image fits the
    /// layer's width). The client still computes `row_span`/`col_span` to
    /// match the scaled size -- aspect-ratio-aware placement stays its job
    /// per decisions.md. A non-positive value is treated as `1.0`.
    scale: f32 = 1.0,
    /// Optional source sub-rectangle (`core.ImageSrcRect`) -- sprite-sheet
    /// support. All default to `0`, which is the whole image from `(0,0)`
    /// -- byte-identical to the pre-source-rect behavior.
    src_x: u32 = 0,
    src_y: u32 = 0,
    src_w: u32 = 0,
    src_h: u32 = 0,
};

pub const TagMetadataParams = struct {
    layer: ?core.LayerHandle = null,
    row: usize,
    col: usize,
    /// Unlike `write_text`/`draw_icon`'s optional `metadata_id`, required
    /// here -- there'd be no point to a `tag_metadata` call that tags
    /// with nothing; a client wanting to *clear* a cell's tag can send
    /// `write_text`/`draw_icon` with `metadata_id` omitted instead, same
    /// as it already would to change what's drawn there anyway.
    metadata_id: core.MetadataHandle,
    /// Mark this cell as its span's focus cell -- where `find_metadata`
    /// lands instead of the span's first visible character. See
    /// `core.Cell.meta_focus`. Defaults false, so an existing caller
    /// tagging overflow cells keeps tagging them as plain span members.
    focus: bool = false,
};

pub const DrawIconParams = struct {
    layer: ?core.LayerHandle = null,
    row: ?usize = null,
    col: ?usize = null,
    name: []const u8,
    /// "fit" (default), "natural", or "stretch" -- see `core.IconScale`.
    scale: ?[]const u8 = null,
    /// "start"/"center" (default)/"end" -- see `core.HAlign`/`core.VAlign`.
    h_align: ?[]const u8 = null,
    v_align: ?[]const u8 = null,
    /// Only consulted when `scale == "natural"` -- see `core.IconBg`.
    max_w: ?u32 = null,
    max_h: ?u32 = null,
    /// See `core.Cell.metadata_id`'s doc comment.
    metadata_id: ?core.MetadataHandle = null,
    /// `false` (default): draws into `Cell.style.bg`, replacing whatever
    /// background was there, same as always. `true`: draws into
    /// `Cell.fg_icon` instead -- see that field's doc comment -- so it
    /// composites over an existing background (e.g. a table border tile)
    /// rather than replacing it.
    foreground: bool = false,
};

// ─── Table messages ──────────────────────────────────────────────────────
//
// See table.zig's header for the object model. Every message here
// (`create_table`/`destroy_table`/`table_set_rows`/`table_set_sort`/
// `table_set_style`/`table_get_state`) takes a required `table` handle
// (except `create_table`, which returns one) alongside the usual optional
// `layer` -- a table's handle alone doesn't say which layer it's on
// (unlike a layer handle, which is globally meaningful), since it's
// stored in that layer's own `tables` map.

pub const CreateTableParams = struct {
    layer: ?core.LayerHandle = null,
    row: ?usize = null,
    col: ?usize = null,
    columns: []const TableColumn,
    style: TableStyle = .{},
};

pub const CreateTableResult = struct { handle: core.TableHandle };

pub const DestroyTableParams = struct {
    layer: ?core.LayerHandle = null,
    table: core.TableHandle,
};

pub const TableSetRowsParams = struct {
    layer: ?core.LayerHandle = null,
    table: core.TableHandle,
    rows: []const []const TableCell,
};

pub const TableSetSortParams = struct {
    layer: ?core.LayerHandle = null,
    table: core.TableHandle,
    column: ?usize = null,
    /// "none" (default), "ascending", or "descending".
    direction: ?[]const u8 = null,
};

pub const TableSetStyleParams = struct {
    layer: ?core.LayerHandle = null,
    table: core.TableHandle,
    style: TableStyle,
};

pub const TableGetStateParams = struct {
    layer: ?core.LayerHandle = null,
    table: core.TableHandle,
};

// ─── Outline messages ────────────────────────────────────────────────────
//
// See outline.zig's header for the object model. Same handle
// convention tables use: every message carries the optional `layer`
// alongside a required `outline`, because an outline lives in that
// layer's own `outlines` map rather than being globally addressable.

pub const CreateOutlineParams = struct {
    layer: ?core.LayerHandle = null,
    row: ?usize = null,
    col: ?usize = null,
    /// Cells across. Omitted, the outline takes the rest of the layer's
    /// width from `col` -- the overwhelmingly common case, and it keeps a
    /// caller from having to read the layer size just to fill a line.
    width: ?usize = null,
    style: OutlineStyle = .{},
};

pub const CreateOutlineResult = struct { handle: core.OutlineHandle };

pub const DestroyOutlineParams = struct {
    layer: ?core.LayerHandle = null,
    outline: core.OutlineHandle,
};

pub const OutlineSetNodesParams = struct {
    layer: ?core.LayerHandle = null,
    outline: core.OutlineHandle,
    nodes: []const OutlineNode,
};

pub const OutlineSetCollapsedParams = struct {
    layer: ?core.LayerHandle = null,
    outline: core.OutlineHandle,
    node: usize,
    /// Omitted means toggle -- the host's own marker click and a client
    /// binding both want "flip it" far more often than a set.
    collapsed: ?bool = null,
};

pub const OutlineSetAllCollapsedParams = struct {
    layer: ?core.LayerHandle = null,
    outline: core.OutlineHandle,
    collapsed: bool,
    /// Only nodes at this depth; omitted means every depth.
    depth: ?u8 = null,
};

pub const OutlineSetStyleParams = struct {
    layer: ?core.LayerHandle = null,
    outline: core.OutlineHandle,
    style: OutlineStyle,
};

pub const OutlineGetStateParams = struct {
    layer: ?core.LayerHandle = null,
    outline: core.OutlineHandle,
};

// ─── Rect ────────────────────────────────────────────────────────────────
//
// See rect.zig's header for the object model. `create_rect` returns
// a handle; `update_rect`/`destroy_rect` take a required `rect` handle
// alongside the usual optional `layer`, same shape the Table messages use.

pub const CreateRectParams = struct {
    layer: ?core.LayerHandle = null,
    x: u32,
    y: u32,
    w: u32,
    h: u32,
    color: Color,
    line_width: u32 = 1,
    filled: bool = false,
};

pub const CreateRectResult = struct { handle: core.RectHandle };

/// Every field but `rect` is optional and `null` (not a default value)
/// means "leave unchanged" -- see `core.RectUpdate`'s doc comment.
pub const UpdateRectParams = struct {
    layer: ?core.LayerHandle = null,
    rect: core.RectHandle,
    x: ?u32 = null,
    y: ?u32 = null,
    w: ?u32 = null,
    h: ?u32 = null,
    color: ?Color = null,
    line_width: ?u32 = null,
    filled: ?bool = null,
};

pub const DestroyRectParams = struct {
    layer: ?core.LayerHandle = null,
    rect: core.RectHandle,
};

/// `set_drop_target`: `mode` picks the shape (see `core.DropTarget`), and
/// the cell fields it needs come alongside. `rows` / `cols` absent (or
/// null) mean one, so a single-row strip or a one-cell target needn't
/// spell them.
pub const SetDropTargetParams = struct {
    layer: ?core.LayerHandle = null,
    mode: []const u8,
    row: ?usize = null,
    col: ?usize = null,
    rows: ?usize = null,
    cols: ?usize = null,
};

/// `start_drag`: a live client handing the host an OS drag to begin from
/// the press it is still holding. Same shape as `create_metadata`'s
/// `drag`.
pub const StartDragParams = core.DragSpec;

// ─── Nine-patch ──────────────────────────────────────────────────────────
//
// See nine_patch.zig's header. Same create/update/destroy shape as
// the Rect messages, placed by cell rect instead of pixels.

pub const CreateNinePatchParams = struct {
    layer: ?core.LayerHandle = null,
    row: usize,
    col: usize,
    rows: usize,
    cols: usize,
    style: []const u8,
};

pub const CreateNinePatchResult = struct { handle: core.NinePatchHandle };

/// `null` means "leave unchanged" -- see `core.NinePatchUpdate`.
pub const UpdateNinePatchParams = struct {
    layer: ?core.LayerHandle = null,
    nine_patch: core.NinePatchHandle,
    row: ?usize = null,
    col: ?usize = null,
    rows: ?usize = null,
    cols: ?usize = null,
    style: ?[]const u8 = null,
};

pub const DestroyNinePatchParams = struct {
    layer: ?core.LayerHandle = null,
    nine_patch: core.NinePatchHandle,
};

/// `rows`/`cols` are optional: omitted means "the rest of the layer from
/// `row`/`col`", so a bare `clear()` (every field defaulted) wipes the
/// whole layer -- see `handleClear`. `bg` fills the cleared cells with an
/// opaque background instead of leaving them transparent.
pub const ClearParams = struct {
    layer: ?core.LayerHandle = null,
    row: usize = 0,
    col: usize = 0,
    rows: ?usize = null,
    cols: ?usize = null,
    bg: ?Color = null,
};

/// `set_bg` params: `ClearParams`' region, but `bg` is required -- the
/// call means "paint this background", so there's no sense in omitting
/// it. Defaults match `clear`'s, so a bare `set_bg` with just a colour
/// repaints the whole layer's background without touching its text.
pub const SetBgParams = struct {
    layer: ?core.LayerHandle = null,
    row: usize = 0,
    col: usize = 0,
    rows: ?usize = null,
    cols: ?usize = null,
    bg: Color,
};

/// `set_fg` params: `set_bg`'s, with the foreground required instead.
pub const SetFgParams = struct {
    layer: ?core.LayerHandle = null,
    row: usize = 0,
    col: usize = 0,
    rows: ?usize = null,
    cols: ?usize = null,
    fg: Color,
};

/// `set_underline` params: the same region as `set_bg`, and `underline` is
/// required for the same reason `bg` is. `"none"` is how a mark comes off.
pub const SetUnderlineParams = struct {
    layer: ?core.LayerHandle = null,
    row: usize = 0,
    col: usize = 0,
    rows: ?usize = null,
    cols: ?usize = null,
    underline: []const u8,
    underline_color: ?Color = null,
};

/// The params of a method that takes none. A named empty struct rather
/// than `.{}`, which encodes as an empty JSON array.
pub const NoParams = struct {};

/// Every client-to-server method by its wire name, typed by its params.
/// `Client` and `Batch` take `params: ParamsOf(method)`, so an anonymous
/// literal at a call site is checked against the struct the handler
/// parses. `load_image` / `update_image` are absent: their bytes ride
/// beside the message (see `Client.sendImagePayload`).
pub const Methods = struct {
    // Text, cells and properties.
    write_text: WriteTextParams,
    insert_cells: CellCountParams,
    delete_cells: CellCountParams,
    move_content: MoveContentParams,
    set_property: PropertyParams,
    get_property: PropertyParams,
    get_cells: GetCellsParams,
    scroll_view: ScrollViewParams,
    clear: ClearParams,
    set_bg: SetBgParams,
    set_fg: SetFgParams,
    set_underline: SetUnderlineParams,
    get_cell_metrics: NoParams,
    // Layers and splits.
    create_layer: CreateLayerParams,
    destroy_layer: DestroyLayerParams,
    adopt_layer: AdoptLayerParams,
    attach_layer: SetCaretLayerParams,
    raise_layer: RaiseLayerParams,
    lower_layer: LowerLayerParams,
    create_split: CreateSplitParams,
    destroy_split: DestroySplitParams,
    set_split_children: SetSplitChildrenParams,
    set_root_split: SetRootSplitParams,
    move_divider: MoveDividerParams,
    // Contexts and window state.
    create_context: CreateContextParams,
    destroy_context: ContextHandleParams,
    activate_context: ContextHandleParams,
    attach_context: ContextHandleParams,
    adopt_context: ContextHandleParams,
    set_context_title: SetContextTitleParams,
    set_theme: SetThemeParams,
    set_divider_style: DividerStyleWire,
    get_theme: NoParams,
    list_contexts: NoParams,
    set_window_scrollbar: SetWindowScrollbarParams,
    set_caret_layer: SetCaretLayerParams,
    set_caret_visible: SetCaretVisibleParams,
    set_caret_shape: SetCaretShapeParams,
    set_key_repeat: SetKeyRepeatParams,
    // Panes and the window manager.
    request_role: RequestRoleParams,
    join_role: RequestRoleParams,
    attach_pane: AttachPaneParams,
    create_pane: CreatePaneParams,
    destroy_pane: PaneHandleParams,
    focus_pane: PaneHandleParams,
    create_pane_split: CreatePaneSplitParams,
    destroy_pane_split: PaneSplitHandleParams,
    set_pane_split_children: SetPaneSplitChildrenParams,
    set_root_pane_split: SetRootPaneSplitParams,
    move_pane_divider: MovePaneDividerParams,
    spawn_in_pane: SpawnInPaneParams,
    start_remote: StartRemoteParams,
    stop_remote: StopRemoteParams,
    set_window_prefix: SetWindowPrefixParams,
    // Input.
    report_key: ReportKeyParams,
    report_text: ReportTextParams,
    report_mouse_button: ReportMouseButtonParams,
    report_mouse_move: ReportMouseMoveParams,
    subscribe: SubscribeParams,
    get_input_state: NoParams,
    // Images and icons.
    get_image_info: ImageInfoParams,
    destroy_image: ImageInfoParams,
    draw_image: DrawImageParams,
    draw_icon: DrawIconParams,
    // Metadata.
    tag_metadata: TagMetadataParams,
    create_metadata: CreateMetadataParams,
    destroy_metadata: DestroyMetadataParams,
    get_metadata: GetMetadataParams,
    find_metadata: FindMetadataParams,
    // Tables and outlines.
    create_table: CreateTableParams,
    destroy_table: DestroyTableParams,
    table_set_rows: TableSetRowsParams,
    table_set_sort: TableSetSortParams,
    table_set_style: TableSetStyleParams,
    table_get_state: TableGetStateParams,
    create_outline: CreateOutlineParams,
    destroy_outline: DestroyOutlineParams,
    outline_set_nodes: OutlineSetNodesParams,
    outline_set_collapsed: OutlineSetCollapsedParams,
    outline_set_all_collapsed: OutlineSetAllCollapsedParams,
    outline_set_style: OutlineSetStyleParams,
    outline_get_state: OutlineGetStateParams,
    // Rects, nine-patches and drop targets.
    create_rect: CreateRectParams,
    update_rect: UpdateRectParams,
    destroy_rect: DestroyRectParams,
    set_drop_target: SetDropTargetParams,
    start_drag: StartDragParams,
    create_nine_patch: CreateNinePatchParams,
    update_nine_patch: UpdateNinePatchParams,
    destroy_nine_patch: DestroyNinePatchParams,
    // Selection, highlights and the clipboard.
    set_selection: SetSelectionParams,
    update_selection: UpdateSelectionParams,
    clear_selection: LayerOnlyParams,
    get_selection: LayerOnlyParams,
    get_selection_text: LayerOnlyParams,
    toggle_highlight: ToggleHighlightParams,
    activate_at: ActivateAtParams,
    set_highlight: SetHighlightParams,
    clear_highlight: LayerOnlyParams,
    get_highlight: LayerOnlyParams,
    set_clipboard: ClipboardTextParams,
    get_clipboard: NoParams,
    // Diagnostics and ordering.
    get_errors: NoParams,
    sync: NoParams,
};

/// The params struct `method` takes. A compile error for a name that
/// isn't in `Methods`.
pub fn ParamsOf(comptime method: []const u8) type {
    return @FieldType(Methods, method);
}

// ─── Notification params ─────────────────────────────────────────────────
//
// The `params` object of each server->client input notification. The
// method name (`key_down`/`key_up`, `mouse_button`, `scroll`, `resize`)
// carries the rest; see `rpc.zig` for the builders that wrap these in an
// envelope, and `client.zig`'s `InputListener` for the parse side.

/// `key_down` / `key_up` params. The pressed/released bit is the method
/// name, not a field. `mods` is the modifier state when the host routed
/// the event (see `core.Mods`); a modifier's own press already counts
/// itself (`left_control` down carries `ctrl: true`).
pub const KeyParams = struct { key: []const u8, mods: core.Mods = .{} };

/// `text` params: a run of committed text input, already resolved through
/// the OS keyboard layout, dead keys and IME composition -- one or more
/// Unicode codepoints as a UTF-8 string. Deliberately distinct from
/// `key_down` (see decisions.md's Input model): a key event carries a
/// physical key name for chords and navigation; this carries what the
/// user actually typed, which for a non-US layout, an AltGr combo or a
/// CJK IME is not derivable from the key name.
pub const TextParams = struct { text: []const u8 };

/// `mouse_button` params. `view_offset` is the root layer's scrollback
/// view offset at click time (see `core.Layer.view_scroll`) so a
/// subscriber resolving `cell` with `get_metadata` can pass the same
/// offset and land on the row the user actually clicked.
pub const MouseButtonParams = struct {
    button: []const u8,
    pressed: bool,
    px: PxPos,
    cell: CellPos,
    view_offset: usize = 0,
    /// See `KeyParams.mods`.
    mods: core.Mods = .{},
    /// 1 for a single click, 2 for a double, 3 for a triple -- counted by
    /// the host (`core.ClickCounter`) so every client agrees on what a
    /// double-click is. A release carries the count of the press it ends.
    /// Defaults to 1 for a reporter that doesn't count.
    clicks: u8 = 1,
};

/// `mouse_move` params: the pointer's new pixel and cell position. Sent
/// only when the cell changed (the host coalesces per-pixel motion),
/// which is the granularity an xterm mouse report needs anyway. Consumed
/// by `InputListener`; glyphwire-shell re-encodes it as a mouse report
/// for a pty child that asked for motion reporting (`?1002` / `?1003`).
pub const MouseMoveParams = struct {
    px: PxPos,
    cell: CellPos,
    /// See `KeyParams.mods`.
    mods: core.Mods = .{},
};

/// `scroll` params: a layer's scrollback-ring view offset and the
/// retained-history maximum it's clamped to. `layer` is `null` for the
/// **root** layer's scrollback (the window's wheel / right-edge bar, and
/// `glyphwire-shell`'s browse cursor) — the common case — and carries a
/// handle when a client-`scroll_view`'d or `gmux`-pane-wheeled non-root
/// layer's ring moved. A root-only subscriber ignores the ones with a
/// handle.
pub const ScrollParams = struct { layer: ?core.LayerHandle = null, offset: usize, max: usize };

/// `scroll_offset` params: a layer's viewport moved over its content
/// grid -- the host's wheel or scrollbar drag, or another client's
/// `set_property`. Carries the handle (unlike `scroll`, which is always
/// the root layer's scrollback) plus the axis maxima, so a subscriber can
/// redraw or size its own indicator without a follow-up request.
pub const ScrollOffsetParams = struct {
    layer: core.LayerHandle,
    row: usize,
    col: usize,
    max_row: usize,
    max_col: usize,
};

/// `layer_resize` params: the user finished dragging a layer's
/// `resize_edge` and wants it `cols` x `rows`. Only the dragged axis
/// differs from the layer's current size. A request, not a fact -- the
/// host has not resized anything, and the client that owns the layer
/// applies (and clamps) it. `context` because layer handles are
/// per-context and this is fanned out to every `"layout"` subscriber.
pub const LayerResizeParams = struct {
    context: core.ContextHandle,
    layer: core.LayerHandle,
    rows: usize,
    /// Absent from hosts older than side edges, which only ever dragged
    /// a height; 0 then means "unchanged".
    cols: usize = 0,
};

/// One layer's bounds inside a `layout` notification.
pub const LayoutBounds = struct {
    layer: core.LayerHandle,
    row: usize,
    col: usize,
    cols: usize,
    rows: usize,
};

/// `layout` params: every pane whose bounds changed, after the split tree
/// was re-laid-out (a window resize or a divider drag). One notification
/// for the whole tree rather than one per pane, so a client redraws once
/// against a consistent set of bounds instead of N times against
/// partially-updated ones.
pub const LayoutParams = struct { layers: []const LayoutBounds };

/// `terminal_reply` params: the bytes a `write_text` produced in answer
/// to a terminal query (`CSI 6n` cursor-position, `CSI c` device
/// attributes, DECRQM) in the text it mirrored. All printable ASCII in
/// practice (`ESC [ ... R` etc.). glyphwire-shell writes them to the pty
/// master so the foregrounded child sees its reply.
pub const TerminalReplyParams = struct { bytes: []const u8 };

/// `resize` params: the receiving connection's own context's new size, in
/// cells. The window's size for a client that has the window to itself;
/// its pane's size for one running inside a pane -- deliberately
/// indistinguishable, so a program needs no awareness of being
/// multiplexed (see session.zig's Panes section).
pub const ResizeParams = struct { cols: usize, rows: usize };

/// One pane's window rect inside a `pane_layout` notification.
pub const PaneBounds = struct {
    pane: core.PaneHandle,
    row: usize,
    col: usize,
    cols: usize,
    rows: usize,
};

/// `pane_layout` params: every pane whose window rect changed. The
/// window-level counterpart of `LayoutParams`, and the only message that
/// reveals pane geometry -- a window manager subscribes to it, and nothing
/// else has a reason to.
pub const PaneLayoutParams = struct { panes: []const PaneBounds };

/// `pane_exit` params: the program in `pane` finished with wait status
/// `status`.
pub const PaneExitParams = struct { pane: core.PaneHandle, status: i64 };

/// `pane_focus` params: `pane` now has input focus.
pub const PaneFocusParams = struct { pane: core.PaneHandle };

/// `remote_exit` params: the remote session `session` (started by
/// `start_remote`) has ended. `status` is the `ssh` process's wait status,
/// so a non-zero value distinguishes "the remote shell exited" from "the
/// connection failed".
pub const RemoteExitParams = struct {
    session: u64,
    status: i64,
    /// Whether the session ever came up -- the agent's `hello` arrived and
    /// remote clients could connect. False means the connection failed
    /// (no such host, auth refused, no `gw-agent` on the far side), which
    /// `status` alone cannot say: `ssh` passes the remote command's exit
    /// code through, so a failure and a remote shell exiting with the same
    /// number are indistinguishable from the status.
    started: bool = true,
};

/// `shutdown` params: the host window is closing and this connection
/// should flush any persistent state and exit. `grace_ms` is roughly how
/// long the host will wait for that before it exits anyway -- advisory,
/// and a client that has nothing to flush can just ignore it. A real
/// field (rather than an empty object) on purpose: a zero-field struct
/// serializes as `[]`, which would fail an object parse (see
/// decisions.md's "Zig JSON gotcha").
pub const ShutdownParams = struct { grace_ms: u32 = 0 };

/// `focus` params: whether the host's own window now has the keyboard.
/// Nothing to do with which *context* is on screen (that is `context`) or
/// which pane is focused within the window -- this is the whole window
/// against the rest of the desktop. A client that paints its own cursor
/// dims or hollows it out on `false`, the way the host does its caret.
pub const FocusParams = struct { focused: bool };

/// `context` params: the now-visible context's handle and the size of
/// its root layer (in cells). A client that manages its own context
/// (zoe) uses the handle to tell "I'm the one on screen now" from "I've
/// been backgrounded"; `cols`/`rows` save it a follow-up `get_property`.
pub const ContextParams = struct { context: u32, cols: usize, rows: usize };

/// `theme` params: the window theme changed (glyphwire-host's theme
/// switcher). Sent only to connections whose context follows the window
/// theme -- one that set its own with `set_theme` is unaffected. Every
/// colour reference already on screen recolours by itself; this is for
/// what a client resolved on its own: `panel_style` (a nine-patch can't
/// be recoloured) and blends it computed. `get_theme` has the rest.
pub const ThemeChangedParams = struct { name: []const u8, dark: bool, panel_style: []const u8 };

// ─── Selection & clipboard ───────────────────────────────────────────────

/// One end of a selection on the wire -- mirrors `core.SelectionPoint`.
/// `above` is rows above the live viewport's top (positive = scrollback);
/// `col` is a 0-based cell column. See `core.SelectionPoint`'s doc
/// comment for why it's content-anchored rather than a screen position.
pub const SelectionPointWire = struct { above: i64, col: usize };

/// `set_selection` params: both ends explicitly.
pub const SetSelectionParams = struct {
    layer: ?core.LayerHandle = null,
    anchor: SelectionPointWire,
    active: SelectionPointWire,
};

/// `update_selection` params: move only the active (dragging) end.
pub const UpdateSelectionParams = struct {
    layer: ?core.LayerHandle = null,
    active: SelectionPointWire,
};

/// `clear_selection` params / `get_selection` / `get_selection_text`
/// params -- just the target layer.
pub const LayerOnlyParams = struct { layer: ?core.LayerHandle = null };

/// `get_selection` result and the `selection` server->client
/// notification: `active` is false when nothing is selected, in which
/// case `anchor`/`active_end` are absent.
pub const SelectionState = struct {
    active: bool,
    anchor: ?SelectionPointWire = null,
    active_end: ?SelectionPointWire = null,
};

/// `get_selection_text` result.
pub const SelectionTextResult = struct { text: []const u8 };

// ─── Highlights ──────────────────────────────────────────────────────────

/// `toggle_highlight` params: the cell to resolve to a metadata id and
/// flip in the layer's highlight set. `row`/`col` are a viewport
/// position; `view_offset` (default 0) resolves against that many rows of
/// scrollback, same as `get_metadata`.
pub const ToggleHighlightParams = struct {
    layer: ?core.LayerHandle = null,
    row: usize,
    col: usize,
    view_offset: usize = 0,
};

/// `activate_at` params: the cell a keyboard "activate" (glyphwire-shell's
/// Enter while browsing scrollback) landed on. Same coordinates as
/// `toggle_highlight`.
pub const ActivateAtParams = struct {
    layer: ?core.LayerHandle = null,
    row: usize,
    col: usize,
    view_offset: usize = 0,
};

/// What `activate_at` did: `"sorted"` (cycled a table header's sort),
/// `"toggled"` (expanded/collapsed an outline node) or `"none"` (nothing
/// there to act on -- the caller falls back to its own action, e.g. the
/// cell's metadata open action).
///
/// `offset` is the layer's view offset afterwards. For `"toggled"`, `row`
/// is the toggled node's screen row at that offset (null if it ended up
/// off screen): the reflow moves the node, so a caller with a cursor on it
/// needs to know where it went.
pub const ActivateAtResult = struct {
    action: []const u8,
    offset: usize = 0,
    row: ?usize = null,
};

/// `set_highlight` params: the full highlighted-id set for the layer,
/// replacing whatever was there. An empty `ids` is the same as
/// `clear_highlight`.
pub const SetHighlightParams = struct {
    layer: ?core.LayerHandle = null,
    ids: []const core.MetadataHandle = &.{},
};

/// One entry in a `HighlightState`: a highlighted metadata id and that
/// id's stored JSON blob (`json` null ⇒ the id was destroyed but is still
/// in the set — same dangling case `get_metadata` reports).
pub const HighlightEntry = struct { id: core.MetadataHandle, json: ?[]const u8 = null };

/// `toggle_highlight` / `set_highlight` / `clear_highlight` / `get_highlight`
/// result: every currently highlighted id on the layer, each with its
/// metadata blob so a client needn't round-trip per id.
pub const HighlightState = struct { entries: []const HighlightEntry };

/// `set_clipboard` params and the `paste` server->client notification --
/// both just carry the text.
pub const ClipboardTextParams = struct { text: []const u8 };

/// `get_clipboard` result.
pub const ClipboardResult = struct { text: []const u8 };

/// One entry in a `get_errors` result: a notification this connection
/// sent that failed in its handler. `method` is the notification's
/// method, `code` the `DispatchError` name (e.g. `"LayerPermissionDenied"`,
/// `"UnknownLayer"`), `seq` a per-connection monotonic counter.
pub const DispatchErrorEntry = struct {
    method: []const u8,
    code: []const u8,
    seq: u64,
};

/// `get_errors` result: the connection's buffered failed-notification
/// records (oldest first, at most `dispatch.error_ring_capacity`) and
/// `dropped` -- how many were lost to a full ring since the last
/// `get_errors`. Reading drains the ring. See decisions.md's Error
/// reporting section.
pub const ErrorsResult = struct {
    errors: []const DispatchErrorEntry,
    dropped: u64,
};
