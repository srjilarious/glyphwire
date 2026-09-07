const std = @import("std");
const core = @import("core.zig");
const protocol = @import("protocol.zig");
const rpc = @import("rpc.zig");

/// Dispatches decoded JSON-RPC message bodies (the wire module's frame
/// payloads) against a headless `Context`. This is the message-catalog
/// subset needed to prove the vertical slice works end to end — just
/// enough of `write_text` and `get_property`/`set_property` for the
/// slice's "hello" round trip, not the fuller catalog from decisions.md
/// (still an open item there).
///
/// Per decisions.md's Protocol Shape: draw/state-change commands
/// (`write_text`, `set_property`) are notifications with no response;
/// `get_property` is a request since it needs to return a value.
/// JSON-RPC error *responses* aren't implemented yet — malformed or
/// unrecognized messages surface as Zig errors instead, since there's no
/// socket layer yet to decide how to report them to a peer.
pub const DispatchError = error{
    UnknownMethod,
    UnknownProperty,
    /// The property name is known but this layer refuses a write to it --
    /// `size` / `visibility` on the root layer, or any get-only property.
    /// See `core.PropertyError.ReadOnlyProperty`.
    ReadOnlyProperty,
    NotARequest,
    UnknownImage,
    UnknownIcon,
    UnknownLayer,
    /// A socket connection issued `destroy_layer` for a layer it doesn't
    /// own (never created and never `adopt_layer`'d) -- see
    /// `handleDestroyLayer`. `destroy_layer` is a notification with no
    /// response channel, so server.zig turns this into a logged warning
    /// and the layer is left intact; a real JSON-RPC error response would
    /// need the still-unbuilt error-response path (roadmap Milestone 0).
    LayerPermissionDenied,
    InvalidIconOption,
    /// `move_content`'s `direction` wasn't `"up"` or `"down"`.
    InvalidMoveDirection,
    UnknownMetadata,
    UnknownTable,
    InvalidTableOption,
    TableRowShapeMismatch,
    UnsupportedImageFormat,
    UnknownSplit,
    /// `create_split`'s `axis` wasn't `"row"` or `"column"`.
    InvalidSplitAxis,
    /// A `set_split_children` entry named both a layer and a split, or
    /// neither.
    InvalidSplitChild,
    /// `create_context` / `destroy_context` / `activate_context` /
    /// `adopt_context` named a context that doesn't exist.
    UnknownContext,
    /// `destroy_context` named the root context, which has no lifecycle
    /// (mirrors `UnknownLayer` for the root layer).
    RootContextImmutable,
    /// A socket connection issued `destroy_context` for a context it
    /// doesn't own (never created and never `adopt_context`'d). Like
    /// `LayerPermissionDenied`: `destroy_context` is a notification, so
    /// server.zig logs this and the context is left intact.
    ContextPermissionDenied,
    /// A context-management message reached a `Dispatcher` with no
    /// `Session` behind it (a bare `Dispatcher.init` -- tests, or a
    /// headless caller from before multi-context). Nothing in production
    /// hits this.
    NoContextSession,
};

const Envelope = struct {
    method: []const u8,
    id: ?std.json.Value = null,
    params: std.json.Value = .null,
};

/// No `row`/`col` fields: this slice's `Layer.writeText` only supports
/// cursor-implicit writes (see core.zig). Explicit positioning is decided
/// in decisions.md but not needed until a milestone past this slice.
/// `layer` (omitted, or `root_layer_handle`) means the root layer, same
/// convention as `row`/`col` defaulting to the cursor elsewhere.
const WriteTextParams = struct {
    layer: ?core.LayerHandle = null,
    text: []const u8,
    fg: ?protocol.Color = null,
    bg: ?protocol.Color = null,
    /// See `core.Cell.metadata_id`'s doc comment.
    metadata_id: ?core.MetadataHandle = null,
    /// `false` (default): `bg` omitted means "reset to
    /// `core.default_style.bg`" -- the original, still-default behavior.
    /// `true`: leaves each touched cell's existing background untouched
    /// instead (`bg` is ignored either way when this is set), for writing
    /// text over a background drawn some other way -- e.g. `draw_box`'s
    /// fill -- that needs to stay visible through it rather than being
    /// approximated with a matching flat color.
    transparent_bg: bool = false,
};

/// Params shared by `insert_cells`/`delete_cells` -- also cursor-implicit
/// like `write_text`, see `WriteTextParams`.
const CellCountParams = struct {
    layer: ?core.LayerHandle = null,
    count: usize,
};

const MoveContentParams = struct {
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
const PropertyParams = struct {
    layer: ?core.LayerHandle = null,
    property: []const u8,
    row: usize = 0,
    col: usize = 0,
    x: f32 = 0,
    y: f32 = 0,
    cols: usize = 0,
    rows: usize = 0,
    visible: bool = true,
    vertical: bool = false,
    horizontal: bool = false,
};

const CursorResult = struct { row: usize, col: usize };
const RevisionResult = struct { revision: u64 };
const PositionResult = struct { x: f32, y: f32 };
const CellPositionResult = struct { row: usize, col: usize };
const SizeResult = struct { cols: usize, rows: usize };
const ScrollResult = struct { offset: usize, max: usize };
const VisibilityResult = struct { visible: bool };
const ScrollOffsetResult = struct { row: usize, col: usize, max_row: usize, max_col: usize };
const ScrollbarsResult = struct {
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
const ScrollViewParams = struct {
    layer: ?core.LayerHandle = null,
    offset: ?usize = null,
    delta: ?i64 = null,
};

const GetCellsParams = struct {
    layer: ?core.LayerHandle = null,
    /// Rows of scrollback to read above the live viewport (see
    /// `core.Layer.viewRow`). 0 (default) is the live viewport -- the
    /// original behavior. Non-zero lets a client read what the user is
    /// actually looking at while glyphwire-host is scrolled back.
    view_offset: usize = 0,
};

const CreateLayerParams = struct {
    width: ?usize = null,
    height: ?usize = null,
    scrollback_rows: usize = 0,
};

const CreateLayerResult = struct { handle: core.LayerHandle };

/// `create_context`: an independent, full-window context (its own root
/// layer, split tree, layers, tables -- see `core.Session`). `width` /
/// `height` default to the current visible context's size. Shown
/// immediately.
const CreateContextParams = struct {
    width: ?usize = null,
    height: ?usize = null,
    scrollback_rows: usize = 0,
};

const CreateContextResult = struct { context: core.ContextHandle };

/// `destroy_context` / `activate_context` / `adopt_context` -- all just
/// name one context handle.
const ContextHandleParams = struct { context: core.ContextHandle };

const DestroyLayerParams = struct {
    layer: core.LayerHandle,
};

/// `raise_layer` / `lower_layer`: `layer` moves in the compositing order,
/// `above` / `below` names the layer it lands next to. Both references are
/// optional -- omitted means "all the way to the top" / "all the way to
/// the bottom". Two field names rather than one shared `ref` so the JSON
/// reads the way the message does.
const RaiseLayerParams = struct {
    layer: core.LayerHandle,
    above: ?core.LayerHandle = null,
};

const LowerLayerParams = struct {
    layer: core.LayerHandle,
    below: ?core.LayerHandle = null,
};

const CreateSplitParams = struct {
    /// `"row"` (children left to right) or `"column"` (top to bottom).
    axis: []const u8,
};

const CreateSplitResult = struct { handle: core.SplitHandle };

const DestroySplitParams = struct { split: core.SplitHandle };

/// One entry of `set_split_children`. `layer` and `split` are the two
/// possible targets and exactly one must be given; `weight` and `fixed`
/// are the two possible sizes and at most one (defaulting to an equal
/// weight). Four optional fields rather than a tagged shape because
/// that's what JSON round-trips cleanly through `parseFromValue` without
/// a custom parser -- the validation is here instead.
const SplitChildParams = struct {
    layer: ?core.LayerHandle = null,
    split: ?core.SplitHandle = null,
    weight: ?f32 = null,
    fixed: ?usize = null,
};

const SetSplitChildrenParams = struct {
    split: core.SplitHandle,
    children: []const SplitChildParams,
};

const SetRootSplitParams = struct { split: ?core.SplitHandle = null };

const MoveDividerParams = struct {
    split: core.SplitHandle,
    index: usize,
    delta: i64,
};

/// `adopt_layer` params -- same single-handle shape as `destroy_layer`,
/// kept as its own type so the two messages stay independently
/// documented.
const AdoptLayerParams = struct {
    layer: core.LayerHandle,
};

const CreateMetadataParams = struct {
    json: []const u8,
};

const CreateMetadataResult = struct { handle: core.MetadataHandle };

const DestroyMetadataParams = struct {
    id: core.MetadataHandle,
};

const GetMetadataParams = struct {
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
const GetMetadataResult = struct {
    id: ?core.MetadataHandle,
    json: ?[]const u8,
};

const CellMetricsResult = struct { cell_px_w: u32, cell_px_h: u32 };

const ReportKeyParams = struct {
    key: []const u8,
    pressed: bool,
};

const ReportTextParams = struct {
    text: []const u8,
};

const ReportMouseButtonParams = struct {
    button: []const u8,
    pressed: bool,
    px: protocol.PxPos,
    cell: protocol.CellPos,
    /// The root layer's scrollback view offset (see `core.Layer.view_scroll`)
    /// at the moment of the click, so a subscriber resolving `cell` with
    /// `get_metadata` can pass the same `view_offset` and land on the row
    /// the user actually clicked while scrolled back. 0 (default) when the
    /// reporter is at the live tail or doesn't track scrollback.
    view_offset: usize = 0,
};

const ReportMouseMoveParams = struct {
    px: protocol.PxPos,
    cell: protocol.CellPos,
};

const SubscribeParams = struct {
    events: []const []const u8,
};

const SubscribeResult = struct {
    subscribed: []const []const u8,
};

const ImageInfoParams = struct { handle: core.ImageHandle };
const ImageInfoResult = struct { width: u32, height: u32 };
const LoadImageResult = struct { handle: core.ImageHandle };

/// `row`/`col` are optional, same as `write_text`'s documented (if not
/// yet wired in there) convention: omitted means "at the layer's
/// cursor" -- see `handleDrawImage`/`resolveAnchor`.
const DrawImageParams = struct {
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
};

const TagMetadataParams = struct {
    layer: ?core.LayerHandle = null,
    row: usize,
    col: usize,
    /// Unlike `write_text`/`draw_icon`'s optional `metadata_id`, required
    /// here -- there'd be no point to a `tag_metadata` call that tags
    /// with nothing; a client wanting to *clear* a cell's tag can send
    /// `write_text`/`draw_icon` with `metadata_id` omitted instead, same
    /// as it already would to change what's drawn there anyway.
    metadata_id: core.MetadataHandle,
};

const DrawIconParams = struct {
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
    /// composites over an existing background (e.g. a `draw_box` fill)
    /// rather than replacing it.
    foreground: bool = false,
};

/// Parses `draw_icon`'s `scale`/`h_align`/`v_align` wire strings against
/// their `core` enums. `null` (the field omitted) means `default`.
fn parseIconOption(comptime E: type, value: ?[]const u8, default: E) !E {
    const s = value orelse return default;
    return std.meta.stringToEnum(E, s) orelse DispatchError.InvalidIconOption;
}

const DrawBoxParams = struct {
    layer: ?core.LayerHandle = null,
    row: ?usize = null,
    col: ?usize = null,
    rows: usize,
    cols: usize,
    style: []const u8,
    /// "tile" (default) or "stretch" -- see `core.Layer.BoxMode`.
    mode: ?[]const u8 = null,
};

// ─── Table ───────────────────────────────────────────────────────────────
//
// See core.zig's Table section for the object model. Every message here
// (`create_table`/`destroy_table`/`table_set_rows`/`table_set_sort`/
// `table_set_style`/`table_get_state`) takes a required `table` handle
// (except `create_table`, which returns one) alongside the usual optional
// `layer` -- a table's handle alone doesn't say which layer it's on
// (unlike a layer handle, which is globally meaningful), since it's
// stored in that layer's own `tables` map.

fn colorFromJson(c: protocol.Color) core.Color {
    return .{ .r = c.r, .g = c.g, .b = c.b, .a = c.a };
}

fn colorToJson(c: core.Color) protocol.Color {
    return .{ .r = c.r, .g = c.g, .b = c.b, .a = c.a };
}

/// Parses a table-related wire string against enum `E` -- same shape
/// `parseIconOption` already has for `draw_icon`'s `scale`/`h_align`/
/// `v_align`, split out under its own error (`InvalidTableOption` rather
/// than `InvalidIconOption`) since a bad `column.kind`/`h_align` or
/// `table_set_sort`'s `direction` isn't an icon problem.
fn parseTableOption(comptime E: type, value: ?[]const u8, default: E) !E {
    const s = value orelse return default;
    return std.meta.stringToEnum(E, s) orelse DispatchError.InvalidTableOption;
}

const CreateTableParams = struct {
    layer: ?core.LayerHandle = null,
    row: ?usize = null,
    col: ?usize = null,
    columns: []const protocol.TableColumn,
    style: protocol.TableStyle = .{},
};

const CreateTableResult = struct { handle: core.TableHandle };

const DestroyTableParams = struct {
    layer: ?core.LayerHandle = null,
    table: core.TableHandle,
};

const TableSetRowsParams = struct {
    layer: ?core.LayerHandle = null,
    table: core.TableHandle,
    rows: []const []const protocol.TableCell,
};

const TableSetSortParams = struct {
    layer: ?core.LayerHandle = null,
    table: core.TableHandle,
    column: ?usize = null,
    /// "none" (default), "ascending", or "descending".
    direction: ?[]const u8 = null,
};

const TableSetStyleParams = struct {
    layer: ?core.LayerHandle = null,
    table: core.TableHandle,
    style: protocol.TableStyle,
};

const TableGetStateParams = struct {
    layer: ?core.LayerHandle = null,
    table: core.TableHandle,
};

/// `rows`/`cols` are optional: omitted means "the rest of the layer from
/// `row`/`col`", so a bare `clear()` (every field defaulted) wipes the
/// whole layer -- see `handleClear`.
const ClearParams = struct {
    layer: ?core.LayerHandle = null,
    row: usize = 0,
    col: usize = 0,
    rows: ?usize = null,
    cols: ?usize = null,
};

/// `batch` params: an ordered list of sub-messages, each a normal
/// JSON-RPC object (`{method, params, id?}`) -- the same shape `handle`
/// parses from a standalone frame. See `handleBatch` for how they're
/// applied (in order, under the one `ctx_mutex` hold server.zig already
/// takes for the outer `batch` message) and how sub-message `id`s
/// correlate to the entries in the response's `responses` array.
const BatchParams = struct {
    messages: []const std.json.Value,
};

/// The `load_image` request's JSON header, peeked out of a frame body
/// before the binary side-channel payload it declares (`bytes` raw bytes,
/// following directly on the wire) can be read — see `peekLoadImage` and
/// wire.zig's `readRaw`. `id` is copied by value straight out of the
/// envelope's arena: safe only because `Client` always sends integer
/// request ids (never a string, which would need its own copy) — see
/// `Client.request`'s `next_id: i64`. `format` is the wire string already
/// resolved to a `core.ImageFormat` (`peekLoadImage` rejects an unknown
/// one with `DispatchError.UnsupportedImageFormat`).
pub const LoadImageHeader = struct {
    id: std.json.Value,
    format: core.ImageFormat,
    bytes: usize,
};

/// Which input event categories a connection has opted into (see
/// decisions.md's Input model: subscription is opt-in per event type,
/// X11 event-mask precedent). Set via the `subscribe` request; consulted
/// by server.zig when fanning out a `Broadcast` from `HandleResult` to
/// other connections.
pub const Subscriptions = struct {
    key: bool = false,
    /// `text` server->client notifications (`{text}`), committed text
    /// input -- see `Server.reportText` / `handleReportText`. A separate
    /// stream from `key`: a client wanting to edit a line subscribes to
    /// both (`key` for navigation/chords, `text` for the characters).
    text: bool = false,
    mouse_button: bool = false,
    /// `mouse_move` server->client notifications (`{px, cell}`), sent on a
    /// pointer cell change -- see `Server.reportMouseMove` /
    /// `handleReportMouseMove`. Opt-in on its own because a client that
    /// only cares about clicks doesn't want the motion firehose;
    /// glyphwire-shell subscribes while a pty child has motion reporting
    /// on.
    mouse_move: bool = false,
    /// `resize` server->client notifications (`{cols, rows}`), sent when
    /// the host window is resized -- see `Server.reportResize`.
    resize: bool = false,
    /// `shutdown` server->client notification (`{grace_ms}`), sent once
    /// when the host window is closing so a client can flush persistent
    /// state and exit cleanly -- see `Server.reportShutdown`.
    /// glyphwire-shell subscribes and treats it like a typed `exit`.
    shutdown: bool = false,
    /// `scroll` server->client notifications (`{offset, max}`), sent when
    /// the root layer's scrollback view offset moves -- see
    /// `Server.reportScroll` (mouse wheel / scrollbar) and
    /// `handleScrollView` (another client's browse cursor). Also covers
    /// `scroll_offset` (a *layer's* viewport moving over its content
    /// grid): one flag, because a client that wants to know when the view
    /// moved wants both kinds.
    scroll: bool = false,
    /// `layout` server->client notifications, sent when the split tree is
    /// re-laid-out and some pane's bounds changed -- a window resize or a
    /// divider drag. Its own flag rather than folding into `resize`: the
    /// payload is per-layer bounds, and a client with no panes shouldn't
    /// have to parse them.
    layout: bool = false,
    /// `selection` server->client notifications (`SelectionState`), sent
    /// when a layer's selection changes -- see `handleSetSelection` and
    /// `Server.setSelection`.
    selection: bool = false,
    /// `copy_request` and `paste` server->client notifications -- the
    /// clipboard interplay (see decisions.md's Selection & Clipboard
    /// section). One flag covers both: a client that wants to answer
    /// copy-with-nothing-selected also wants pasted text.
    clipboard: bool = false,
    /// `terminal_reply` server->client notifications -- the bytes a
    /// `write_text` produced in answer to a `CSI 6n` / DA / DECRQM query
    /// from the text it mirrored. glyphwire-shell subscribes while a pty
    /// child is foregrounded and writes them to the pty master.
    terminal: bool = false,
    /// `context` server->client notifications (`{context, cols, rows}`),
    /// sent when the visible context changes (`create_context` /
    /// `activate_context` / `destroy_context`, or the disconnect-cull
    /// auto-restore). A client managing its own context subscribes to
    /// learn it's been backgrounded or brought back.
    context: bool = false,
    /// Not a broadcast stream like the rest: subscribing to `"error"` just
    /// tells this connection's `Dispatcher` to start recording its own
    /// failed notifications into a ring (see `Dispatcher.error_ring`),
    /// which the client pulls with `get_errors`. Named `_events` because
    /// `error` is a keyword.
    error_events: bool = false,

    pub fn has(self: Subscriptions, event: []const u8) bool {
        if (std.mem.eql(u8, event, "key")) return self.key;
        if (std.mem.eql(u8, event, "text")) return self.text;
        if (std.mem.eql(u8, event, "mouse_button")) return self.mouse_button;
        if (std.mem.eql(u8, event, "mouse_move")) return self.mouse_move;
        if (std.mem.eql(u8, event, "resize")) return self.resize;
        if (std.mem.eql(u8, event, "shutdown")) return self.shutdown;
        if (std.mem.eql(u8, event, "scroll")) return self.scroll;
        if (std.mem.eql(u8, event, "scroll_offset")) return self.scroll;
        if (std.mem.eql(u8, event, "layout")) return self.layout;
        if (std.mem.eql(u8, event, "selection")) return self.selection;
        if (std.mem.eql(u8, event, "clipboard")) return self.clipboard;
        if (std.mem.eql(u8, event, "terminal")) return self.terminal;
        if (std.mem.eql(u8, event, "context")) return self.context;
        if (std.mem.eql(u8, event, "error")) return self.error_events;
        return false;
    }

    fn setFromEvents(events: []const []const u8) Subscriptions {
        var s: Subscriptions = .{};
        for (events) |e| {
            if (std.mem.eql(u8, e, "key")) s.key = true;
            if (std.mem.eql(u8, e, "text")) s.text = true;
            if (std.mem.eql(u8, e, "mouse_button")) s.mouse_button = true;
            if (std.mem.eql(u8, e, "mouse_move")) s.mouse_move = true;
            if (std.mem.eql(u8, e, "resize")) s.resize = true;
            if (std.mem.eql(u8, e, "shutdown")) s.shutdown = true;
            if (std.mem.eql(u8, e, "scroll")) s.scroll = true;
            if (std.mem.eql(u8, e, "scroll_offset")) s.scroll = true;
            if (std.mem.eql(u8, e, "layout")) s.layout = true;
            if (std.mem.eql(u8, e, "selection")) s.selection = true;
            if (std.mem.eql(u8, e, "clipboard")) s.clipboard = true;
            if (std.mem.eql(u8, e, "terminal")) s.terminal = true;
            if (std.mem.eql(u8, e, "context")) s.context = true;
            if (std.mem.eql(u8, e, "error")) s.error_events = true;
        }
        return s;
    }
};

/// An owned notification body (caller frees with the same allocator
/// passed to `handle`) to fan out to every *other* connection subscribed
/// to `event`. `handle`'s caller (server.zig) owns actually doing that
/// fan-out; `Dispatcher` itself has no knowledge of other connections, to
/// keep it headless-testable -- see decisions.md's headless-first
/// architecture note.
pub const Broadcast = struct {
    event: []const u8,
    body: []u8,
};

pub const HandleResult = struct {
    /// Owned response body for a request, freed by the caller. Null for a
    /// notification (no response) or when nothing changed worth
    /// broadcasting.
    response: ?[]u8 = null,
    broadcast: ?Broadcast = null,
};

/// Peeks at a decoded frame body to see whether it's a `load_image`
/// request — if so, the caller must read `bytes` raw bytes directly off
/// the wire next, before normal frame processing can continue (the binary
/// side-channel: a JSON header frame declares a byte count, then that many
/// raw bytes follow directly on the wire, not wrapped in `Content-Length`
/// framing — see decisions.md's Transport & Wire Format). Returns null for
/// every other message, which the caller should route to `handle` as
/// usual. Module-level (not a `Dispatcher` method) since it needs no
/// `Context` access — it's pure parsing, done before dispatch.
pub fn peekLoadImage(alloc: std.mem.Allocator, body: []const u8) !?LoadImageHeader {
    const parsed = try std.json.parseFromSlice(Envelope, alloc, body, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();
    if (!std.mem.eql(u8, parsed.value.method, "load_image")) return null;
    const id = parsed.value.id orelse return DispatchError.NotARequest;

    const Params = struct { format: []const u8, bytes: usize };
    const p = try std.json.parseFromValue(Params, alloc, parsed.value.params, .{
        .ignore_unknown_fields = true,
    });
    defer p.deinit();

    const format = core.ImageFormat.fromName(p.value.format) orelse return DispatchError.UnsupportedImageFormat;
    return .{ .id = id, .format = format, .bytes = p.value.bytes };
}

/// Peeks at a decoded frame body to determine whether it's a notification
/// (no `id`) rather than a request. Used by server.zig to decide whether a
/// `Dispatcher.handle` error should just be logged or propagated: a
/// notification has no response channel to report an error on anyway (per
/// JSON-RPC, that's a server-side log line, not a wire message -- see
/// decisions.md's latent-robustness-gap note), so severing the whole
/// connection over e.g. one `draw_icon` naming an unregistered icon would
/// be a disproportionate failure mode. A request needs *some* response;
/// until real JSON-RPC error responses land (roadmap.md's Milestone 0),
/// severing the connection is the least-bad fallback there rather than
/// leaving the client's request hanging forever with no reply.
pub fn isNotification(alloc: std.mem.Allocator, body: []const u8) !bool {
    const parsed = try std.json.parseFromSlice(Envelope, alloc, body, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();
    return parsed.value.id == null;
}

/// How many recent notification-dispatch errors a connection's ring
/// holds once it has subscribed to `"error"` (see `Dispatcher.recordError`
/// / `handleGetErrors`). Small on purpose: a client polls `get_errors`
/// between batches of work, and the `dropped` count in the reply tells it
/// if it fell behind -- keeping every error indefinitely would just be an
/// unbounded leak for a client that subscribed and never drained.
pub const error_ring_capacity = 5;

/// One entry in a `Dispatcher`'s error ring. Self-contained (no owned
/// slices): `method` is copied into a fixed inline buffer and `code` is a
/// `@errorName` string, which is static -- so the ring needs no allocator
/// and the `Dispatcher` needs no `deinit`.
const ErrorEntry = struct {
    method_buf: [24]u8 = undefined,
    method_len: u8 = 0,
    /// The `DispatchError` name, e.g. `"LayerPermissionDenied"`.
    code: []const u8 = "",
    /// Per-connection monotonic counter, assigned when the error is
    /// recorded. Lets a client order errors and notice gaps.
    seq: u64 = 0,

    fn method(self: *const ErrorEntry) []const u8 {
        return self.method_buf[0..self.method_len];
    }
};

pub const Dispatcher = struct {
    /// The context this connection is currently acting on -- every
    /// `layer?`-scoped message resolves against it. It starts as the
    /// context that was visible when the connection was accepted (a
    /// connection *inherits* the visible context) and is retargeted by
    /// `create_context` to the new context. `activate_context` does
    /// *not* move it -- that message only changes which context is on
    /// screen, so a client can background itself and keep drawing. A
    /// cached pointer, kept live against `session` by `syncActiveContext`
    /// (its context could be `destroy_context`'d by another owner).
    ctx: *core.Context,
    /// The multi-context registry, or null for a bare `Dispatcher.init`
    /// (tests / headless callers that predate multi-context). When null,
    /// every context-management message reports `NoContextSession`.
    session: ?*core.Session = null,
    /// Handle of `ctx` -- mirrored onto the `Connection` after each
    /// `handle` so `Server.broadcast` can withhold raw input from a
    /// backgrounded connection. Root context by default.
    active_ctx: core.ContextHandle = core.root_context_handle,
    /// This connection's current subscriptions; see `Subscriptions`. Not
    /// persisted anywhere else -- server.zig mirrors it onto its own
    /// per-connection record after each `handle` call so the fan-out
    /// logic can consult it without this type knowing about connections.
    subscriptions: Subscriptions = .{},
    /// Ring of recent failed-notification records, populated only while
    /// this connection is subscribed to `"error"` (see `recordError`).
    /// A notification (standalone or batched) that errors in its handler
    /// otherwise vanishes -- no response, no severed connection -- so this
    /// is how a client that opted in can find out after the fact. Drained
    /// by `get_errors`. `error` isn't a legal field name, hence the `_ev`.
    error_ring: [error_ring_capacity]ErrorEntry = [_]ErrorEntry{.{}} ** error_ring_capacity,
    error_ring_start: usize = 0,
    error_ring_len: usize = 0,
    /// Monotonic per-connection error counter (last value assigned to an
    /// `ErrorEntry.seq`). Never reset -- only the ring contents are.
    error_seq: u64 = 0,
    /// Count of errors evicted because the ring was full since the last
    /// drain. Returned by `get_errors` as `dropped`, then reset to 0 with
    /// the ring -- so it always means "lost since you last checked".
    error_dropped: u64 = 0,
    /// The identity of the socket connection this dispatcher serves, or
    /// null for an in-process caller with no connection (the headless
    /// `server/main.zig`, tests, glyphwire-host driving the `Context`
    /// directly). Threads through to layer ownership: a non-null id is
    /// recorded as the owner on `create_layer` / `adopt_layer` and
    /// checked on `destroy_layer`; a null id owns nothing and bypasses
    /// the `destroy_layer` ownership check entirely. See `core.ConnId`.
    conn_id: ?core.ConnId = null,

    pub fn init(ctx: *core.Context) Dispatcher {
        return .{ .ctx = ctx };
    }

    /// Like `init`, but for a dispatcher serving a real socket connection
    /// whose id participates in layer/context ownership (see `conn_id`).
    /// The connection inherits whatever context is visible now. Call
    /// under the server's `ctx_mutex` -- it reads the visibility stack.
    pub fn initForConnection(session: *core.Session, conn_id: core.ConnId) Dispatcher {
        return .{
            .ctx = session.visibleContext(),
            .session = session,
            .active_ctx = session.visibleStackTop(),
            .conn_id = conn_id,
        };
    }

    /// Keeps `ctx` live: if this connection's `active_ctx` was destroyed
    /// by another owner (`adopt_context` + `destroy_context` elsewhere),
    /// fall back to whatever is visible. Runs at the top of every
    /// dispatch, under `ctx_mutex`, so the stack reads are safe. A no-op
    /// for a sessionless `Dispatcher`.
    fn syncActiveContext(self: *Dispatcher) void {
        const session = self.session orelse return;
        if (session.contextPtr(self.active_ctx)) |c| {
            self.ctx = c;
        } else {
            self.active_ctx = session.visibleStackTop();
            self.ctx = session.visibleContext();
        }
    }

    /// Handles one decoded frame body. See `HandleResult`.
    pub fn handle(self: *Dispatcher, alloc: std.mem.Allocator, body: []const u8) !HandleResult {
        const parsed = try std.json.parseFromSlice(Envelope, alloc, body, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();
        return self.dispatchEnvelope(alloc, parsed.value);
    }

    /// Routes an already-parsed envelope through `dispatchCatalog` and, on
    /// error, records it in the connection's ring when the message was a
    /// notification (`id == null`) and the connection subscribed to
    /// `"error"`. A failed notification is otherwise silent -- no
    /// response, and (unlike a failed request) the connection isn't
    /// severed -- so this is the only place a client can learn about one.
    /// The error still propagates: server.zig / `handleBatch` keep logging
    /// and swallowing it exactly as before. `handleBatch` calls this per
    /// sub-message, so batched notification failures are recorded too.
    fn dispatchEnvelope(self: *Dispatcher, alloc: std.mem.Allocator, envelope: Envelope) !HandleResult {
        return self.dispatchCatalog(alloc, envelope) catch |err| {
            if (envelope.id == null and self.subscriptions.error_events) {
                self.recordError(envelope.method, err);
            }
            return err;
        };
    }

    /// Records one failed notification into the error ring (see
    /// `Dispatcher.error_ring`). When the ring is full the oldest entry is
    /// dropped and `error_dropped` is bumped. `code` is `@errorName(err)`,
    /// a static string, and `method` is copied into the entry's inline
    /// buffer (truncated at 24 bytes, which no real method name reaches),
    /// so nothing here allocates.
    fn recordError(self: *Dispatcher, method: []const u8, err: anyerror) void {
        self.error_seq += 1;

        const slot = (self.error_ring_start + self.error_ring_len) % error_ring_capacity;
        if (self.error_ring_len == error_ring_capacity) {
            self.error_ring_start = (self.error_ring_start + 1) % error_ring_capacity;
            self.error_dropped += 1;
        } else {
            self.error_ring_len += 1;
        }

        const e = &self.error_ring[slot];
        const n = @min(method.len, e.method_buf.len);
        @memcpy(e.method_buf[0..n], method[0..n]);
        e.method_len = @intCast(n);
        e.code = @errorName(err);
        e.seq = self.error_seq;
    }

    /// Uniform signature every catalog entry is adapted to. `anyerror`
    /// rather than a spelled-out set: the branches this replaced already
    /// raised a mix of `DispatchError`, JSON parse errors and
    /// `Allocator.Error`, and `dispatchEnvelope` catches all of them the
    /// same way. Routing through a function-pointer table also breaks the
    /// `batch` -> `handleBatch` -> `dispatchEnvelope` -> catalog
    /// error-set cycle for free (the reason `handleBatch` still spells out
    /// its own return set).
    const CatalogFn = *const fn (*Dispatcher, std.mem.Allocator, Envelope) anyerror!HandleResult;

    /// Adapts a `!HandleResult` handler taking `(alloc, params)`.
    fn catResult(comptime f: anytype) CatalogFn {
        return &struct {
            fn call(self: *Dispatcher, alloc: std.mem.Allocator, envelope: Envelope) anyerror!HandleResult {
                return try f(self, alloc, envelope.params);
            }
        }.call;
    }

    /// Adapts a `!void` handler taking `(alloc, params)` -- a
    /// fire-and-forget notification, so the reply is always the empty
    /// result.
    fn catVoid(comptime f: anytype) CatalogFn {
        return &struct {
            fn call(self: *Dispatcher, alloc: std.mem.Allocator, envelope: Envelope) anyerror!HandleResult {
                try f(self, alloc, envelope.params);
                return .{};
            }
        }.call;
    }

    /// Adapts a `!HandleResult` handler taking `(alloc, id, params)`: the
    /// message must be a request (carry an `id`).
    fn catResultId(comptime f: anytype) CatalogFn {
        return &struct {
            fn call(self: *Dispatcher, alloc: std.mem.Allocator, envelope: Envelope) anyerror!HandleResult {
                const id = envelope.id orelse return DispatchError.NotARequest;
                return try f(self, alloc, id, envelope.params);
            }
        }.call;
    }

    /// Adapts a `![]u8` (JSON response bytes) handler taking
    /// `(alloc, id, params)`: request-only, wrapped as `.response`.
    fn catBytesId(comptime f: anytype) CatalogFn {
        return &struct {
            fn call(self: *Dispatcher, alloc: std.mem.Allocator, envelope: Envelope) anyerror!HandleResult {
                const id = envelope.id orelse return DispatchError.NotARequest;
                return .{ .response = try f(self, alloc, id, envelope.params) };
            }
        }.call;
    }

    /// Adapts a `![]u8` handler taking `(alloc, id)`: request-only, reads
    /// no params.
    fn catBytesIdNoParams(comptime f: anytype) CatalogFn {
        return &struct {
            fn call(self: *Dispatcher, alloc: std.mem.Allocator, envelope: Envelope) anyerror!HandleResult {
                const id = envelope.id orelse return DispatchError.NotARequest;
                return .{ .response = try f(self, alloc, id) };
            }
        }.call;
    }

    /// `batch` alone: it needs the raw `id` (request *or* notification
    /// form) plus `params`, not the `(alloc, params)` shape the adapters
    /// above assume.
    fn catBatch(self: *Dispatcher, alloc: std.mem.Allocator, envelope: Envelope) anyerror!HandleResult {
        return try self.handleBatch(alloc, envelope.id, envelope.params);
    }

    /// Method name -> handler. A compile-time perfect-hash map built from
    /// the adapters above; replaces what was a ~60-branch `if/else` chain
    /// of `std.mem.eql` on `envelope.method`. Adding a message is one row
    /// here. `dispatchEnvelope` (error recording) and `handleBatch` both
    /// route through `dispatchCatalog`, so a batched sub-message and a
    /// standalone one still hit precisely the same handler.
    const catalog = std.StaticStringMap(CatalogFn).initComptime(.{
        .{ "write_text", catResult(handleWriteText) },
        .{ "insert_cells", catVoid(handleInsertCells) },
        .{ "delete_cells", catVoid(handleDeleteCells) },
        .{ "move_content", catVoid(handleMoveContent) },
        .{ "set_property", catVoid(handleSetProperty) },
        .{ "get_property", catBytesId(handleGetProperty) },
        .{ "get_cells", catBytesId(handleGetCells) },
        .{ "scroll_view", catResultId(handleScrollView) },
        .{ "create_layer", catBytesId(handleCreateLayer) },
        .{ "destroy_layer", catVoid(handleDestroyLayer) },
        .{ "adopt_layer", catVoid(handleAdoptLayer) },
        .{ "create_context", catResultId(handleCreateContext) },
        .{ "destroy_context", catResult(handleDestroyContext) },
        .{ "activate_context", catResult(handleActivateContext) },
        .{ "attach_context", catVoid(handleAttachContext) },
        .{ "adopt_context", catVoid(handleAdoptContext) },
        .{ "create_split", catBytesId(handleCreateSplit) },
        .{ "destroy_split", catResult(handleDestroySplit) },
        .{ "set_split_children", catResult(handleSetSplitChildren) },
        .{ "set_root_split", catResult(handleSetRootSplit) },
        .{ "move_divider", catResult(handleMoveDivider) },
        .{ "raise_layer", catVoid(handleRaiseLayer) },
        .{ "lower_layer", catVoid(handleLowerLayer) },
        .{ "report_key", catResult(handleReportKey) },
        .{ "report_text", catResult(handleReportText) },
        .{ "report_mouse_button", catResult(handleReportMouseButton) },
        .{ "report_mouse_move", catResult(handleReportMouseMove) },
        .{ "subscribe", catBytesId(handleSubscribe) },
        .{ "get_input_state", catBytesIdNoParams(handleGetInputState) },
        .{ "get_image_info", catBytesId(handleGetImageInfo) },
        .{ "draw_image", catVoid(handleDrawImage) },
        .{ "draw_icon", catVoid(handleDrawIcon) },
        .{ "tag_metadata", catVoid(handleTagMetadata) },
        .{ "draw_box", catVoid(handleDrawBox) },
        .{ "clear", catVoid(handleClear) },
        .{ "get_cell_metrics", catBytesIdNoParams(handleGetCellMetrics) },
        .{ "create_metadata", catBytesId(handleCreateMetadata) },
        .{ "destroy_metadata", catVoid(handleDestroyMetadata) },
        .{ "get_metadata", catBytesId(handleGetMetadata) },
        .{ "create_table", catBytesId(handleCreateTable) },
        .{ "destroy_table", catVoid(handleDestroyTable) },
        .{ "table_set_rows", catVoid(handleTableSetRows) },
        .{ "table_set_sort", catVoid(handleTableSetSort) },
        .{ "table_set_style", catVoid(handleTableSetStyle) },
        .{ "table_get_state", catBytesId(handleTableGetState) },
        .{ "set_selection", catResult(handleSetSelection) },
        .{ "update_selection", catResult(handleUpdateSelection) },
        .{ "clear_selection", catResult(handleClearSelection) },
        .{ "get_selection", catBytesId(handleGetSelection) },
        .{ "get_selection_text", catBytesId(handleGetSelectionText) },
        .{ "toggle_highlight", catBytesId(handleToggleHighlight) },
        .{ "set_highlight", catBytesId(handleSetHighlight) },
        .{ "clear_highlight", catBytesId(handleClearHighlight) },
        .{ "get_highlight", catBytesId(handleGetHighlight) },
        .{ "set_clipboard", catVoid(handleSetClipboard) },
        .{ "get_clipboard", catBytesIdNoParams(handleGetClipboard) },
        .{ "get_errors", catBytesIdNoParams(handleGetErrors) },
        .{ "batch", &catBatch },
    });

    /// Looks the method up in `catalog` and runs its handler. Split from
    /// `handle` so a batched sub-message and a standalone one hit
    /// precisely the same handler.
    fn dispatchCatalog(self: *Dispatcher, alloc: std.mem.Allocator, envelope: Envelope) !HandleResult {
        self.syncActiveContext();
        const handler = catalog.get(envelope.method) orelse return DispatchError.UnknownMethod;
        return handler(self, alloc, envelope);
    }

    /// A `batch` sub-message method that can't run inside a batch,
    /// regardless of params: another `batch` (nesting is disallowed) or
    /// `load_image` (handled by its own pre-dispatch path in server.zig
    /// because of the binary side-channel payload -- it has no branch in
    /// `dispatchEnvelope` at all). Everything else in the catalog is
    /// allowed; a sub-message that happens to produce a `broadcast`
    /// (`report_key`, `scroll_view`, ...) still applies its state change,
    /// but the broadcast is dropped -- see `handleBatch`.
    fn batchSubMethodInvalid(method: []const u8) bool {
        return std.mem.eql(u8, method, "batch") or std.mem.eql(u8, method, "load_image");
    }

    /// `batch`: applies an ordered list of sub-messages in one go. The
    /// whole batch runs under the single `ctx_mutex` hold server.zig
    /// already takes for this outer message, so nothing renders a
    /// half-updated grid partway through -- the motivating fix for
    /// glyphwire-ls's listing visibly painting itself one row at a time
    /// (see decisions.md's Batch section).
    ///
    /// Best-effort, matching how server.zig already treats a standalone
    /// notification's dispatch error: a sub-message that fails to parse,
    /// names a batch-invalid method, or errors in its handler is logged
    /// and skipped, and the rest of the batch still runs. The batch is
    /// atomic only in the "one render" sense, not all-or-nothing -- core
    /// has no transaction/rollback support.
    ///
    /// `outer_id` present (request form): the response is
    /// `{responses: [<response object>, ...]}`, one element per
    /// sub-message that carried an `id` and whose handler produced a
    /// response, in order. Each element is a complete JSON-RPC response
    /// object (`{jsonrpc, id, result}`) carrying that sub-message's own
    /// `id`, so a caller correlates by matching ids (a missing id means
    /// that sub-message was a notification, or it failed). `outer_id`
    /// absent (notification form): no response at all; any response a
    /// sub-request produced is dropped with a warning.
    ///
    /// The return set is spelled out (`ParseFromValueError`) rather than
    /// inferred, to break the inferred-error-set cycle with
    /// `dispatchEnvelope`: every error `dispatchEnvelope` can raise is
    /// caught per sub-message below, so this function only ever surfaces
    /// its own `BatchParams` parse / allocation failures.
    fn handleBatch(self: *Dispatcher, alloc: std.mem.Allocator, outer_id: ?std.json.Value, params_value: std.json.Value) std.json.ParseFromValueError!HandleResult {
        const parsed = try std.json.parseFromValue(BatchParams, alloc, params_value, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();

        var arena_state = std.heap.ArenaAllocator.init(alloc);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        var responses: std.ArrayList(std.json.Value) = .empty;

        for (parsed.value.messages) |msg_value| {
            const sub = std.json.parseFromValue(Envelope, alloc, msg_value, .{
                .ignore_unknown_fields = true,
            }) catch |err| {
                std.log.warn("glyphwire: batch sub-message parse failed: {t}", .{err});
                continue;
            };
            defer sub.deinit();

            if (batchSubMethodInvalid(sub.value.method)) {
                std.log.warn("glyphwire: batch sub-message '{s}' is not allowed in a batch, skipped", .{sub.value.method});
                continue;
            }

            const result = self.dispatchEnvelope(alloc, sub.value) catch |err| {
                std.log.warn("glyphwire: batch sub-message '{s}' failed: {t}", .{ sub.value.method, err });
                continue;
            };

            if (result.broadcast) |b| {
                alloc.free(b.body);
                std.log.warn("glyphwire: broadcast from batched '{s}' dropped", .{sub.value.method});
            }

            if (result.response) |resp| {
                defer alloc.free(resp);
                if (outer_id == null) {
                    std.log.warn("glyphwire: response from batched '{s}' dropped (notification-form batch)", .{sub.value.method});
                    continue;
                }
                const v = std.json.parseFromSliceLeaky(std.json.Value, arena, resp, .{}) catch |err| {
                    std.log.warn("glyphwire: re-parsing batched '{s}' response failed: {t}", .{ sub.value.method, err });
                    continue;
                };
                try responses.append(arena, v);
            }
        }

        const id = outer_id orelse return .{};
        const BatchResult = struct { responses: []const std.json.Value };
        return .{ .response = try rpc.response(alloc, id, BatchResult{ .responses = responses.items }) };
    }

    /// Handles the `load_image` request's JSON header once its binary
    /// payload has already been read off the wire by the caller (see
    /// server.zig's `serveConnection`, which special-cases this method
    /// instead of routing it through `handle` — the payload isn't a normal
    /// frame `handle` can see). Stores `raw_bytes` and returns the response
    /// frame for `hdr.id`.
    pub fn handleLoadImage(self: *Dispatcher, alloc: std.mem.Allocator, hdr: LoadImageHeader, raw_bytes: []const u8) ![]u8 {
        const image_handle = try self.ctx.loadImage(hdr.format, raw_bytes);
        return try rpc.response(alloc, hdr.id, LoadImageResult{ .handle = image_handle });
    }

    /// Resolves a wire-level `layer` field (omitted means the root layer,
    /// same convention `resolveAnchor` already uses for `row`/`col`) to
    /// its `Layer` -- shared by every layer-scoped handler below.
    fn resolveLayer(self: *Dispatcher, layer: ?core.LayerHandle) !*core.Layer {
        return self.ctx.layerPtr(layer) orelse DispatchError.UnknownLayer;
    }

    /// Validates an optional `metadata_id` param against `Context.metadata`
    /// before it's stored on a cell (`write_text`/`draw_icon`), the same
    /// "fail loud on a bad handle at the point of use" treatment
    /// `UnknownImage`/`UnknownIcon`/`UnknownLayer` already get -- catches a
    /// typo'd or already-`destroy_metadata`'d id immediately rather than
    /// silently tagging a cell with a dangling reference. `null` (the
    /// field omitted) passes through untouched.
    fn resolveMetadata(self: *Dispatcher, id: ?core.MetadataHandle) !?core.MetadataHandle {
        if (id) |m| {
            if (self.ctx.metadataJson(m) == null) return DispatchError.UnknownMetadata;
        }
        return id;
    }

    fn handleWriteText(self: *Dispatcher, alloc: std.mem.Allocator, params_value: std.json.Value) !HandleResult {
        const parsed = try std.json.parseFromValue(WriteTextParams, alloc, params_value, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();
        const p = parsed.value;
        const layer = try self.resolveLayer(p.layer);

        const fg: core.Color = if (p.fg) |c| .{ .r = c.r, .g = c.g, .b = c.b, .a = c.a } else core.default_style.fg;
        const bg: ?core.Background = if (p.transparent_bg)
            null
        else if (p.bg) |c|
            .{ .color = .{ .r = c.r, .g = c.g, .b = c.b, .a = c.a } }
        else
            core.default_style.bg;
        const metadata_id = try self.resolveMetadata(p.metadata_id);
        try layer.writeTextTagged(p.text, fg, bg, metadata_id);

        // A terminal query the text carried (`CSI 6n` / DA / DECRQM):
        // hand the reply bytes to `"terminal"` subscribers -- glyphwire-
        // shell writes them to the pty master. See `core.Layer.takeReply`.
        if (layer.takeReply()) |reply| {
            const body = try rpc.terminalReplyNotification(alloc, reply);
            return .{ .broadcast = .{ .event = "terminal_reply", .body = body } };
        }
        return .{};
    }

    fn handleInsertCells(self: *Dispatcher, alloc: std.mem.Allocator, params_value: std.json.Value) !void {
        const parsed = try std.json.parseFromValue(CellCountParams, alloc, params_value, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();
        const layer = try self.resolveLayer(parsed.value.layer);
        layer.insertCells(parsed.value.count);
    }

    fn handleDeleteCells(self: *Dispatcher, alloc: std.mem.Allocator, params_value: std.json.Value) !void {
        const parsed = try std.json.parseFromValue(CellCountParams, alloc, params_value, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();
        const layer = try self.resolveLayer(parsed.value.layer);
        layer.deleteCells(parsed.value.count);
    }

    /// `move_content`: shifts a band of a layer's content grid vertically
    /// in place (`Layer.moveContent` -> `scrollRange`) so a client-
    /// scrolled pane can scroll without retransmitting every visible row.
    /// A notification -- the shift is best-effort and batchable next to
    /// the follow-up redraw of the newly-exposed band.
    fn handleMoveContent(self: *Dispatcher, alloc: std.mem.Allocator, params_value: std.json.Value) !void {
        const parsed = try std.json.parseFromValue(MoveContentParams, alloc, params_value, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();
        const p = parsed.value;
        const layer = try self.resolveLayer(p.layer);
        const dir: core.Layer.ScrollDir = if (p.direction) |d|
            (std.meta.stringToEnum(core.Layer.ScrollDir, d) orelse return DispatchError.InvalidMoveDirection)
        else
            .up;
        layer.moveContent(p.top, p.bot, p.count, dir);
    }

    fn handleSetProperty(self: *Dispatcher, alloc: std.mem.Allocator, params_value: std.json.Value) !void {
        const parsed = try std.json.parseFromValue(PropertyParams, alloc, params_value, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();
        const p = parsed.value;

        const value: core.PropertyValue = if (std.mem.eql(u8, p.property, "cursor"))
            .{ .cursor = .{ .row = p.row, .col = p.col } }
        else if (std.mem.eql(u8, p.property, "position"))
            .{ .position = .{ .x = p.x, .y = p.y } }
        else if (std.mem.eql(u8, p.property, "cell_position"))
            .{ .cell_position = .{ .row = p.row, .col = p.col } }
        else if (std.mem.eql(u8, p.property, "size"))
            .{ .size = .{ .cols = p.cols, .rows = p.rows } }
        else if (std.mem.eql(u8, p.property, "visibility"))
            .{ .visibility = p.visible }
        else if (std.mem.eql(u8, p.property, "viewport"))
            .{ .viewport = .{ .cols = p.cols, .rows = p.rows } }
        else if (std.mem.eql(u8, p.property, "scroll_offset"))
            .{ .scroll_offset = .{ .row = p.row, .col = p.col } }
        else if (std.mem.eql(u8, p.property, "scrollbars"))
            // The other four `ScrollbarState` fields are derived, so
            // whatever a client sends for them is ignored -- see
            // `core.PropertyName.scrollbars`.
            .{ .scrollbars = .{
                .vertical = p.vertical,
                .horizontal = p.horizontal,
                .row = 0,
                .col = 0,
                .max_row = 0,
                .max_col = 0,
            } }
        else if (std.mem.eql(u8, p.property, "content_extent"))
            .{ .content_extent = .{ .cols = p.cols, .rows = p.rows } }
        else
            return DispatchError.UnknownProperty;

        // `Context.setLayerProperty` (not `Layer`'s own) owns the root
        // guards, the cell-metric resolution and `size`'s reallocation.
        self.ctx.setLayerProperty(p.layer, value) catch |err| return switch (err) {
            error.UnknownLayer => DispatchError.UnknownLayer,
            error.ReadOnlyProperty => DispatchError.ReadOnlyProperty,
            error.UnknownProperty => DispatchError.UnknownProperty,
            error.OutOfMemory => error.OutOfMemory,
        };
    }

    fn handleGetProperty(
        self: *Dispatcher,
        alloc: std.mem.Allocator,
        id: std.json.Value,
        params_value: std.json.Value,
    ) ![]u8 {
        const parsed = try std.json.parseFromValue(PropertyParams, alloc, params_value, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();
        const p = parsed.value;

        // `profile` is a host-wide diagnostic, not a per-layer property:
        // no `layer`, and it is answered straight from the session
        // snapshot glyphwire-host refreshes each frame under `ctx_mutex`
        // (see src/profiler.zig, host/profiler.zig). `active` is false
        // whenever the host isn't profiling.
        if (std.mem.eql(u8, p.property, "profile")) {
            const snap: core.ProfileSnapshot = if (self.session) |s| s.profile else .{};
            const View = struct {
                active: bool,
                fps: f32,
                skips_per_sec: f32,
                phases: []const core.ProfilePhase,
                counters: []const core.ProfileCount,
            };
            return try rpc.response(alloc, id, View{
                .active = snap.active,
                .fps = snap.fps,
                .skips_per_sec = snap.skips_per_sec,
                .phases = snap.phaseSlice(),
                .counters = snap.counterSlice(),
            });
        }

        const layer = try self.resolveLayer(p.layer);

        if (std.mem.eql(u8, p.property, "cursor")) {
            const cursor = layer.getProperty(.cursor).cursor;
            return try rpc.response(alloc, id, CursorResult{ .row = cursor.row, .col = cursor.col });
        } else if (std.mem.eql(u8, p.property, "revision")) {
            const revision = layer.getProperty(.revision).revision;
            return try rpc.response(alloc, id, RevisionResult{ .revision = revision });
        } else if (std.mem.eql(u8, p.property, "position")) {
            const pos = layer.getProperty(.position).position;
            return try rpc.response(alloc, id, PositionResult{ .x = pos.x, .y = pos.y });
        } else if (std.mem.eql(u8, p.property, "cell_position")) {
            // Needs the session's cell metrics, so it goes through the
            // context rather than the resolved layer -- see
            // `core.Context.getLayerProperty`.
            const value = self.ctx.getLayerProperty(p.layer, .cell_position) catch
                return DispatchError.UnknownLayer;
            const cell = value.cell_position;
            return try rpc.response(alloc, id, CellPositionResult{ .row = cell.row, .col = cell.col });
        } else if (std.mem.eql(u8, p.property, "visibility")) {
            const visible = layer.getProperty(.visibility).visibility;
            return try rpc.response(alloc, id, VisibilityResult{ .visible = visible });
        } else if (std.mem.eql(u8, p.property, "viewport")) {
            const vp = layer.getProperty(.viewport).viewport;
            return try rpc.response(alloc, id, SizeResult{ .cols = vp.cols, .rows = vp.rows });
        } else if (std.mem.eql(u8, p.property, "scroll_offset")) {
            const off = layer.getProperty(.scroll_offset).scroll_offset;
            const max = layer.maxScroll();
            return try rpc.response(alloc, id, ScrollOffsetResult{
                .row = off.row,
                .col = off.col,
                .max_row = max.row,
                .max_col = max.col,
            });
        } else if (std.mem.eql(u8, p.property, "scrollbars")) {
            const sb = layer.getProperty(.scrollbars).scrollbars;
            return try rpc.response(alloc, id, ScrollbarsResult{
                .vertical = sb.vertical,
                .horizontal = sb.horizontal,
                .row = sb.row,
                .col = sb.col,
                .max_row = sb.max_row,
                .max_col = sb.max_col,
            });
        } else if (std.mem.eql(u8, p.property, "size")) {
            const sz = layer.getProperty(.size).size;
            return try rpc.response(alloc, id, SizeResult{ .cols = sz.cols, .rows = sz.rows });
        } else if (std.mem.eql(u8, p.property, "content_extent")) {
            const ce = layer.getProperty(.content_extent).content_extent;
            return try rpc.response(alloc, id, SizeResult{ .cols = ce.cols, .rows = ce.rows });
        } else if (std.mem.eql(u8, p.property, "scroll")) {
            const sc = layer.getProperty(.scroll).scroll;
            return try rpc.response(alloc, id, ScrollResult{ .offset = sc.offset, .max = sc.max });
        }
        return DispatchError.UnknownProperty;
    }

    /// `create_layer`: allocates a fresh layer parented to the root (see
    /// `Context.createLayer`) and returns its handle. When this dispatcher
    /// serves a real connection (`conn_id` set), that connection is
    /// recorded as the layer's first owner, so the layer is culled if the
    /// connection later closes without destroying it (see
    /// `Context.removeConnectionOwnership`).
    fn handleCreateLayer(self: *Dispatcher, alloc: std.mem.Allocator, id: std.json.Value, params_value: std.json.Value) ![]u8 {
        const parsed = try std.json.parseFromValue(CreateLayerParams, alloc, params_value, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();
        const p = parsed.value;

        const layer_handle = try self.ctx.createLayer(p.width, p.height, p.scrollback_rows);
        if (self.conn_id) |cid| self.ctx.addLayerOwner(layer_handle, cid) catch {};
        return try rpc.response(alloc, id, CreateLayerResult{ .handle = layer_handle });
    }

    /// `destroy_layer`: frees a layer and drops it from compositing (see
    /// `Context.destroyLayer`). Errors (an unknown handle, or the root's)
    /// surface as `DispatchError.UnknownLayer` via `core.LayerError`'s own
    /// single member. When this dispatcher serves a real connection, that
    /// connection must own the layer (created it, or `adopt_layer`'d it) --
    /// otherwise `DispatchError.LayerPermissionDenied`, which server.zig
    /// logs and drops without touching the layer. An in-process caller
    /// (`conn_id` null) bypasses the check.
    fn handleDestroyLayer(self: *Dispatcher, alloc: std.mem.Allocator, params_value: std.json.Value) !void {
        const parsed = try std.json.parseFromValue(DestroyLayerParams, alloc, params_value, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();
        const layer_handle = parsed.value.layer;
        if (self.conn_id) |cid| {
            // An unknown handle falls through to the UnknownLayer path
            // below rather than being reported as a permission problem.
            if (self.ctx.layers.contains(layer_handle) and !self.ctx.layerHasOwner(layer_handle, cid))
                return DispatchError.LayerPermissionDenied;
        }
        self.ctx.destroyLayer(layer_handle) catch return DispatchError.UnknownLayer;
    }

    /// `adopt_layer`: adds this connection to `layer`'s owner set, so the
    /// layer survives its original creator disconnecting as long as this
    /// connection stays up, and this connection may itself `destroy_layer`
    /// it. Errors `UnknownLayer` for an unknown or root handle. A no-op
    /// for an in-process caller (`conn_id` null) -- it owns nothing and
    /// needs no ownership to act.
    fn handleAdoptLayer(self: *Dispatcher, alloc: std.mem.Allocator, params_value: std.json.Value) !void {
        const parsed = try std.json.parseFromValue(AdoptLayerParams, alloc, params_value, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();
        if (self.conn_id) |cid| {
            self.ctx.addLayerOwner(parsed.value.layer, cid) catch return DispatchError.UnknownLayer;
        }
    }

    // ── Contexts ────────────────────────────────────────────────────────

    /// The `context` broadcast (`{context, cols, rows}`) every
    /// context-management message ends with, naming whatever context is
    /// visible now and the size of its root layer -- so a subscriber can
    /// tell "I'm on screen" from "I've been backgrounded" without a
    /// follow-up request. Sessionless dispatchers never get here (the
    /// handlers reject those before building it).
    fn contextBroadcast(self: *Dispatcher, alloc: std.mem.Allocator) !HandleResult {
        const session = self.session.?;
        const visible = session.visibleContext();
        const body = try rpc.contextNotification(
            alloc,
            session.visibleStackTop(),
            visible.root.width,
            visible.root.height,
        );
        return .{ .broadcast = .{ .event = "context", .body = body } };
    }

    /// `create_context`: a fresh independent context (see `core.Session`),
    /// shown immediately. Retargets this connection onto it -- every
    /// later `layer?`-scoped message from this connection now resolves
    /// against the new context, not the shell's. The connection is
    /// recorded as first owner, so the context (and everything in it) is
    /// culled if the connection closes without `destroy_context`.
    fn handleCreateContext(self: *Dispatcher, alloc: std.mem.Allocator, id: std.json.Value, params_value: std.json.Value) !HandleResult {
        const session = self.session orelse return DispatchError.NoContextSession;
        const parsed = try std.json.parseFromValue(CreateContextParams, alloc, params_value, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();
        const p = parsed.value;

        const new_handle = try session.createContext(p.width, p.height, p.scrollback_rows);
        if (self.conn_id) |cid| session.addContextOwner(new_handle, cid) catch {};
        self.active_ctx = new_handle;
        self.ctx = session.contextPtr(new_handle).?;

        var result = try self.contextBroadcast(alloc);
        result.response = try rpc.response(alloc, id, CreateContextResult{ .context = new_handle });
        return result;
    }

    /// `destroy_context`: frees a context and everything in it, dropping
    /// it from the visibility stack (if it was visible, the context under
    /// it becomes visible -- the alt-screen auto-restore). Ownership-
    /// checked exactly like `destroy_layer`: honored only from a
    /// connection that owns the context (`ContextPermissionDenied`
    /// otherwise, logged and dropped by server.zig). The root context
    /// reports `RootContextImmutable`. An in-process caller bypasses the
    /// check.
    fn handleDestroyContext(self: *Dispatcher, alloc: std.mem.Allocator, params_value: std.json.Value) !HandleResult {
        const session = self.session orelse return DispatchError.NoContextSession;
        const parsed = try std.json.parseFromValue(ContextHandleParams, alloc, params_value, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();
        const target = parsed.value.context;

        if (self.conn_id) |cid| {
            // The root handle falls through to `RootContextImmutable`
            // below rather than being reported as a permission problem
            // (it's in `contexts` but never owned).
            if (target != core.root_context_handle and
                session.contexts.contains(target) and
                !session.contextHasOwner(target, cid))
                return DispatchError.ContextPermissionDenied;
        }
        session.destroyContext(target) catch |err| return switch (err) {
            error.RootContextImmutable => DispatchError.RootContextImmutable,
            error.UnknownContext => DispatchError.UnknownContext,
        };
        // If this connection just destroyed its own active context, fall
        // back to whatever is visible now.
        self.syncActiveContext();
        return try self.contextBroadcast(alloc);
    }

    /// `activate_context`: makes a context visible without changing which
    /// context this connection *draws* on. A client backgrounds itself by
    /// activating the root context, and un-backgrounds by activating its
    /// own handle again. `UnknownContext` for an unknown handle; a no-op
    /// if it's already visible.
    fn handleActivateContext(self: *Dispatcher, alloc: std.mem.Allocator, params_value: std.json.Value) !HandleResult {
        const session = self.session orelse return DispatchError.NoContextSession;
        const parsed = try std.json.parseFromValue(ContextHandleParams, alloc, params_value, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();
        session.activateContext(parsed.value.context) catch return DispatchError.UnknownContext;
        return try self.contextBroadcast(alloc);
    }

    /// `attach_context`: retargets this connection onto an *existing*
    /// context (`create_context` does this for a new one) -- every later
    /// `layer?`-scoped message resolves against it, and, for a subscribed
    /// connection, the raw input streams it receives now follow that
    /// context's visibility. The primitive a paired `InputListener` uses
    /// to join the context its `Client` created, and the same mechanism a
    /// future `GLYPHWIRE_CTX`-inheriting connection would use at startup.
    /// `UnknownContext` for an unknown handle; ownership is untouched
    /// (attaching isn't adopting). A no-op for a sessionless dispatcher's
    /// caller other than the error.
    fn handleAttachContext(self: *Dispatcher, alloc: std.mem.Allocator, params_value: std.json.Value) !void {
        const session = self.session orelse return DispatchError.NoContextSession;
        const parsed = try std.json.parseFromValue(ContextHandleParams, alloc, params_value, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();
        const target = parsed.value.context;
        self.ctx = session.contextPtr(target) orelse return DispatchError.UnknownContext;
        self.active_ctx = target;
    }

    /// `adopt_context`: adds this connection to a context's owner set, so
    /// it outlives its original creator disconnecting (and this
    /// connection may then `destroy_context` it). `UnknownContext` for an
    /// unknown or root handle; a no-op for an in-process caller. The
    /// context-level mirror of `adopt_layer`.
    fn handleAdoptContext(self: *Dispatcher, alloc: std.mem.Allocator, params_value: std.json.Value) !void {
        const session = self.session orelse return DispatchError.NoContextSession;
        const parsed = try std.json.parseFromValue(ContextHandleParams, alloc, params_value, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();
        if (self.conn_id) |cid| {
            session.addContextOwner(parsed.value.context, cid) catch return DispatchError.UnknownContext;
        }
    }

    /// Re-lays-out the split tree and, if any pane's bounds moved, builds
    /// the `layout` broadcast for it. Every split mutation ends here, so
    /// a client never has to ask what the change did to its panes.
    fn relayout(self: *Dispatcher, alloc: std.mem.Allocator) !HandleResult {
        var changed: std.ArrayList(core.LayerBounds) = .empty;
        defer changed.deinit(alloc);
        // `layoutSplits` appends through the context's allocator, which is
        // the same one the server hands dispatch.
        try self.ctx.layoutSplits(&changed, null);
        if (changed.items.len == 0) return .{};

        const bounds = try alloc.alloc(protocol.LayoutBounds, changed.items.len);
        defer alloc.free(bounds);
        for (changed.items, 0..) |b, i| {
            bounds[i] = .{ .layer = b.layer, .row = b.row, .col = b.col, .cols = b.cols, .rows = b.rows };
        }
        const body = try rpc.layoutNotification(alloc, bounds);
        return .{ .broadcast = .{ .event = "layout", .body = body } };
    }

    fn handleCreateSplit(self: *Dispatcher, alloc: std.mem.Allocator, id: std.json.Value, params_value: std.json.Value) ![]u8 {
        const parsed = try std.json.parseFromValue(CreateSplitParams, alloc, params_value, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();

        const axis = std.meta.stringToEnum(core.SplitAxis, parsed.value.axis) orelse
            return DispatchError.InvalidSplitAxis;
        const split_handle = try self.ctx.createSplit(axis);
        return try rpc.response(alloc, id, CreateSplitResult{ .handle = split_handle });
    }

    fn handleDestroySplit(self: *Dispatcher, alloc: std.mem.Allocator, params_value: std.json.Value) !HandleResult {
        const parsed = try std.json.parseFromValue(DestroySplitParams, alloc, params_value, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();
        self.ctx.destroySplit(parsed.value.split) catch return DispatchError.UnknownSplit;
        return try self.relayout(alloc);
    }

    fn handleSetSplitChildren(self: *Dispatcher, alloc: std.mem.Allocator, params_value: std.json.Value) !HandleResult {
        const parsed = try std.json.parseFromValue(SetSplitChildrenParams, alloc, params_value, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();
        const p = parsed.value;

        const children = try alloc.alloc(core.SplitChild, p.children.len);
        defer alloc.free(children);
        for (p.children, 0..) |c, i| {
            // Exactly one target; naming both (or neither) is a malformed
            // child rather than something to guess at.
            const target: core.SplitChild.Target = if (c.layer) |h| blk: {
                if (c.split != null) return DispatchError.InvalidSplitChild;
                break :blk .{ .layer = h };
            } else if (c.split) |h|
                .{ .split = h }
            else
                return DispatchError.InvalidSplitChild;

            const size: core.SplitChild.Size = if (c.fixed) |f|
                .{ .fixed = f }
            else if (c.weight) |w|
                .{ .weight = w }
            else
                .{ .weight = 1 };

            children[i] = .{ .target = target, .size = size };
        }

        self.ctx.setSplitChildren(p.split, children) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => DispatchError.UnknownSplit,
        };
        return try self.relayout(alloc);
    }

    fn handleSetRootSplit(self: *Dispatcher, alloc: std.mem.Allocator, params_value: std.json.Value) !HandleResult {
        const parsed = try std.json.parseFromValue(SetRootSplitParams, alloc, params_value, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();
        self.ctx.setRootSplit(parsed.value.split) catch return DispatchError.UnknownSplit;
        return try self.relayout(alloc);
    }

    fn handleMoveDivider(self: *Dispatcher, alloc: std.mem.Allocator, params_value: std.json.Value) !HandleResult {
        const parsed = try std.json.parseFromValue(MoveDividerParams, alloc, params_value, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();
        const p = parsed.value;
        self.ctx.moveDivider(p.split, p.index, p.delta) catch return DispatchError.UnknownSplit;
        return try self.relayout(alloc);
    }

    /// `raise_layer`: restacks a layer toward the top of the compositing
    /// order (see `Context.raiseLayer`). The root layer is always the
    /// bottom of the stack and isn't in the order at all, so naming it as
    /// `layer` or `above` reports `UnknownLayer`.
    fn handleRaiseLayer(self: *Dispatcher, alloc: std.mem.Allocator, params_value: std.json.Value) !void {
        const parsed = try std.json.parseFromValue(RaiseLayerParams, alloc, params_value, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();
        self.ctx.raiseLayer(parsed.value.layer, parsed.value.above) catch
            return DispatchError.UnknownLayer;
    }

    /// `lower_layer`: the mirror of `raise_layer` (see
    /// `Context.lowerLayer`).
    fn handleLowerLayer(self: *Dispatcher, alloc: std.mem.Allocator, params_value: std.json.Value) !void {
        const parsed = try std.json.parseFromValue(LowerLayerParams, alloc, params_value, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();
        self.ctx.lowerLayer(parsed.value.layer, parsed.value.below) catch
            return DispatchError.UnknownLayer;
    }

    /// `create_metadata`: stores `json` verbatim (see `Context.createMetadata`
    /// -- the server never parses it, just stores/returns it) and returns a
    /// fresh handle a later `write_text`/`draw_icon`/`destroy_metadata` can
    /// reference.
    fn handleCreateMetadata(self: *Dispatcher, alloc: std.mem.Allocator, id: std.json.Value, params_value: std.json.Value) ![]u8 {
        const parsed = try std.json.parseFromValue(CreateMetadataParams, alloc, params_value, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();

        const metadata_handle = try self.ctx.createMetadata(parsed.value.json);
        return try rpc.response(alloc, id, CreateMetadataResult{ .handle = metadata_handle });
    }

    /// `destroy_metadata`: frees `id`'s stored JSON (see
    /// `Context.destroyMetadata`'s doc comment on why a cell still tagged
    /// with `id` afterward isn't this call's problem -- there's no
    /// reference counting yet). Errors on an unknown id, same treatment
    /// `destroy_layer` gives an unknown layer handle.
    fn handleDestroyMetadata(self: *Dispatcher, alloc: std.mem.Allocator, params_value: std.json.Value) !void {
        const parsed = try std.json.parseFromValue(DestroyMetadataParams, alloc, params_value, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();
        self.ctx.destroyMetadata(parsed.value.id) catch return DispatchError.UnknownMetadata;
    }

    /// `get_metadata`: resolves `(row, col)` on `layer` (root when omitted)
    /// to a cell and reports its `metadata_id` plus that id's stored JSON
    /// -- see `GetMetadataResult`'s doc comment for how those two can
    /// diverge (a dangling id). Unlike `draw_icon`/`draw_image`, `row`/
    /// `col` are required rather than cursor-defaulted: this is a targeted
    /// lookup (e.g. resolving whatever cell a mouse click landed on), not
    /// a draw at "wherever the cursor currently is".
    fn handleGetMetadata(self: *Dispatcher, alloc: std.mem.Allocator, id: std.json.Value, params_value: std.json.Value) ![]u8 {
        const parsed = try std.json.parseFromValue(GetMetadataParams, alloc, params_value, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();
        const p = parsed.value;
        const layer = try self.resolveLayer(p.layer);

        const metadata_id = if (p.row < layer.height and p.col < layer.width)
            (if (p.view_offset > 0)
                layer.viewRow(p.view_offset, p.row)[p.col].metadata_id
            else
                layer.cell(p.row, p.col).metadata_id)
        else
            null;
        const json = if (metadata_id) |m| self.ctx.metadataJson(m) else null;

        return try rpc.response(alloc, id, GetMetadataResult{ .id = metadata_id, .json = json });
    }

    /// Returns a full row-major snapshot of the given layer's (default:
    /// root's) visible viewport, plus its current revision -- the
    /// read-back path decisions.md flagged as not yet exposed over the
    /// wire.
    fn handleGetCells(self: *Dispatcher, alloc: std.mem.Allocator, id: std.json.Value, params_value: std.json.Value) ![]u8 {
        const parsed = try std.json.parseFromValue(GetCellsParams, alloc, params_value, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();
        const layer = try self.resolveLayer(parsed.value.layer);
        const view_offset = parsed.value.view_offset;
        const cells = try alloc.alloc(protocol.WireCell, layer.width * layer.height);
        defer alloc.free(cells);

        var row: usize = 0;
        while (row < layer.height) : (row += 1) {
            const view_row: ?[]const core.Cell = if (view_offset > 0) layer.viewRow(view_offset, row) else null;
            var col: usize = 0;
            while (col < layer.width) : (col += 1) {
                const cell: *const core.Cell = if (view_row) |vr| &vr[col] else layer.cell(row, col);
                const bg: ?protocol.Color = switch (cell.style.bg) {
                    .color => |bgc| .{ .r = bgc.r, .g = bgc.g, .b = bgc.b, .a = bgc.a },
                    .image, .icon => null,
                };
                const bg_image: ?protocol.ImageBg = switch (cell.style.bg) {
                    .image => |img| .{ .handle = img.handle, .offset_x = img.offset_x, .offset_y = img.offset_y, .scale = img.scale },
                    .color, .icon => null,
                };
                const bg_icon: ?protocol.IconBg = switch (cell.style.bg) {
                    .icon => |icon| .{
                        .handle = icon.handle,
                        .scale = @tagName(icon.scale),
                        .h_align = @tagName(icon.h_align),
                        .v_align = @tagName(icon.v_align),
                        .max_w = icon.max_w,
                        .max_h = icon.max_h,
                    },
                    .color, .image => null,
                };
                const fg_icon: ?protocol.IconBg = if (cell.fg_icon) |icon| .{
                    .handle = icon.handle,
                    .scale = @tagName(icon.scale),
                    .h_align = @tagName(icon.h_align),
                    .v_align = @tagName(icon.v_align),
                    .max_w = icon.max_w,
                    .max_h = icon.max_h,
                } else null;
                cells[row * layer.width + col] = .{
                    .g = cell.grapheme(),
                    .fg = .{ .r = cell.style.fg.r, .g = cell.style.fg.g, .b = cell.style.fg.b, .a = cell.style.fg.a },
                    .bg = bg,
                    .bg_image = bg_image,
                    .bg_icon = bg_icon,
                    .fg_icon = fg_icon,
                    .metadata_id = cell.metadata_id,
                    .wide = switch (cell.wide) {
                        .narrow => null,
                        .wide_lead => "lead",
                        .wide_spacer => "spacer",
                    },
                };
            }
        }

        return try rpc.response(alloc, id, protocol.CellsResult{
            .cols = layer.width,
            .rows = layer.height,
            .revision = layer.revision,
            .cells = cells,
        });
    }

    /// `scroll_view`: moves the layer's scrollback view offset (see
    /// `core.Layer.scrollView` / `PropertyName.scroll`) and returns the
    /// resulting `{offset, max}`. Also broadcasts a `scroll` notification
    /// (same `{offset, max}`) to every *other* connection subscribed to
    /// `"scroll"` -- glyphwire-shell drives this from its browse cursor,
    /// and glyphwire-host, which owns the field directly, just reads it
    /// next frame. A request, unlike the host-internal `Server.reportScroll`
    /// path the mouse wheel/scrollbar use.
    fn handleScrollView(self: *Dispatcher, alloc: std.mem.Allocator, id: std.json.Value, params_value: std.json.Value) !HandleResult {
        const parsed = try std.json.parseFromValue(ScrollViewParams, alloc, params_value, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();
        const p = parsed.value;
        const layer = try self.resolveLayer(p.layer);
        const new_offset = layer.scrollView(p.offset, p.delta);

        const resp_body = try rpc.response(alloc, id, ScrollResult{ .offset = new_offset, .max = layer.history_len });
        errdefer alloc.free(resp_body);

        const notif_body = try rpc.scrollNotification(alloc, new_offset, layer.history_len);
        return .{ .response = resp_body, .broadcast = .{ .event = "scroll", .body = notif_body } };
    }

    /// A notification from an input-capturing client (glyphwire-host, in
    /// practice -- nothing here restricts it to a particular sender, see
    /// decisions.md's stance on there being no auth model yet). Updates
    /// the authoritative down-set and, if the key's state actually
    /// changed, returns a `key_down`/`key_up` broadcast for other
    /// connections subscribed to `"key"`.
    fn handleReportKey(self: *Dispatcher, alloc: std.mem.Allocator, params_value: std.json.Value) !HandleResult {
        const parsed = try std.json.parseFromValue(ReportKeyParams, alloc, params_value, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();
        const p = parsed.value;

        const changed = try self.ctx.input.setKey(p.key, p.pressed);
        if (!changed) return .{};

        const notif_body = try rpc.keyNotification(alloc, p.key, p.pressed);
        return .{ .broadcast = .{ .event = "key", .body = notif_body } };
    }

    /// A committed-text notification from an input-capturing client (see
    /// `handleReportKey`). Unlike a key event there's no authoritative
    /// down-set to update -- text is transient -- so this only fans a
    /// `text` broadcast out to `"text"` subscribers. An empty string is
    /// dropped.
    fn handleReportText(self: *Dispatcher, alloc: std.mem.Allocator, params_value: std.json.Value) !HandleResult {
        _ = self;
        const parsed = try std.json.parseFromValue(ReportTextParams, alloc, params_value, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();
        const p = parsed.value;

        if (p.text.len == 0) return .{};

        const notif_body = try rpc.textNotification(alloc, p.text);
        return .{ .broadcast = .{ .event = "text", .body = notif_body } };
    }

    fn handleReportMouseButton(self: *Dispatcher, alloc: std.mem.Allocator, params_value: std.json.Value) !HandleResult {
        const parsed = try std.json.parseFromValue(ReportMouseButtonParams, alloc, params_value, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();
        const p = parsed.value;

        self.ctx.input.cursor_px = .{ .x = p.px.x, .y = p.px.y };
        self.ctx.input.cursor_cell = .{ .row = p.cell.row, .col = p.cell.col };
        const changed = try self.ctx.input.setMouseButton(p.button, p.pressed);
        if (!changed) return .{};

        const notif_body = try rpc.mouseButtonNotification(alloc, p.button, p.pressed, p.px, p.cell, p.view_offset);
        return .{ .broadcast = .{ .event = "mouse_button", .body = notif_body } };
    }

    /// Keeps `get_input_state`'s cursor fields current, and -- only when
    /// the pointer crossed into a new cell -- broadcasts a `mouse_move`
    /// notification to `"mouse_move"` subscribers. Per-pixel motion
    /// within one cell is dropped (the host already coalesces most of it,
    /// and an xterm mouse report is cell-granular anyway).
    fn handleReportMouseMove(self: *Dispatcher, alloc: std.mem.Allocator, params_value: std.json.Value) !HandleResult {
        const parsed = try std.json.parseFromValue(ReportMouseMoveParams, alloc, params_value, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();
        const p = parsed.value;

        const cell_changed = self.ctx.input.cursor_cell.row != p.cell.row or
            self.ctx.input.cursor_cell.col != p.cell.col;
        self.ctx.input.cursor_px = .{ .x = p.px.x, .y = p.px.y };
        self.ctx.input.cursor_cell = .{ .row = p.cell.row, .col = p.cell.col };
        if (!cell_changed) return .{};

        const notif_body = try rpc.mouseMoveNotification(alloc, p.px, p.cell);
        return .{ .broadcast = .{ .event = "mouse_move", .body = notif_body } };
    }

    fn handleSubscribe(self: *Dispatcher, alloc: std.mem.Allocator, id: std.json.Value, params_value: std.json.Value) ![]u8 {
        const parsed = try std.json.parseFromValue(SubscribeParams, alloc, params_value, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();
        self.subscriptions = Subscriptions.setFromEvents(parsed.value.events);

        return try rpc.response(alloc, id, SubscribeResult{ .subscribed = parsed.value.events });
    }

    fn handleGetInputState(self: *Dispatcher, alloc: std.mem.Allocator, id: std.json.Value) ![]u8 {
        var keys = std.ArrayList([]const u8).empty;
        defer keys.deinit(alloc);
        var kit = self.ctx.input.keys_down.keyIterator();
        while (kit.next()) |k| try keys.append(alloc, k.*);

        var buttons = std.ArrayList([]const u8).empty;
        defer buttons.deinit(alloc);
        var bit = self.ctx.input.mouse_buttons_down.keyIterator();
        while (bit.next()) |k| try buttons.append(alloc, k.*);

        return try rpc.response(alloc, id, protocol.InputStateResult{
            .keys_down = keys.items,
            .mouse_buttons_down = buttons.items,
            .cursor_px = .{ .x = self.ctx.input.cursor_px.x, .y = self.ctx.input.cursor_px.y },
            .cursor_cell = .{ .row = self.ctx.input.cursor_cell.row, .col = self.ctx.input.cursor_cell.col },
        });
    }

    fn handleGetImageInfo(self: *Dispatcher, alloc: std.mem.Allocator, id: std.json.Value, params_value: std.json.Value) ![]u8 {
        const parsed = try std.json.parseFromValue(ImageInfoParams, alloc, params_value, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();

        const info = self.ctx.imageInfo(parsed.value.handle) orelse return DispatchError.UnknownImage;
        return try rpc.response(alloc, id, ImageInfoResult{ .width = info.width, .height = info.height });
    }

    /// Resolves an optional `row`/`col` pair against `layer`'s current
    /// cursor -- shared by `draw_image`/`draw_icon`/`draw_box`, matching
    /// `write_text`'s documented (if not yet wired in there) convention:
    /// omitted means "at the cursor," same as it would for text. Doesn't
    /// itself scroll or otherwise validate -- `Layer.resolveRow` (called
    /// downstream by `drawImage`/`drawIcon`/`drawBox` themselves) still
    /// handles a resulting row that's out of bounds.
    fn resolveAnchor(layer: *const core.Layer, row: ?usize, col: ?usize) struct { row: usize, col: usize } {
        return .{ .row = row orelse layer.cursor.row, .col = col orelse layer.cursor.col };
    }

    fn handleDrawImage(self: *Dispatcher, alloc: std.mem.Allocator, params_value: std.json.Value) !void {
        const parsed = try std.json.parseFromValue(DrawImageParams, alloc, params_value, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();
        const p = parsed.value;
        const layer = try self.resolveLayer(p.layer);

        const info = self.ctx.imageInfo(p.handle) orelse return DispatchError.UnknownImage;
        const anchor = resolveAnchor(layer, p.row, p.col);
        layer.drawImage(
            p.handle,
            anchor.row,
            anchor.col,
            p.row_span,
            p.col_span,
            info.width,
            info.height,
            self.ctx.cell_px_w,
            self.ctx.cell_px_h,
            p.scale,
        );
    }

    /// `draw_icon`: resolves `name` against the icon catalog
    /// (`Context.iconHandle`, populated by `glyphwire-host` scanning
    /// `assets/icons/`) and draws it into exactly one cell -- an icon is
    /// scoped to a single cell for now, per decisions.md's Icon section.
    /// `Layer.drawIcon` just needs the handle -- no dimensions/cell
    /// metrics to look up, unlike `handleDrawImage`, since an icon always
    /// scales the whole source image into the whole cell.
    fn handleDrawIcon(self: *Dispatcher, alloc: std.mem.Allocator, params_value: std.json.Value) !void {
        const parsed = try std.json.parseFromValue(DrawIconParams, alloc, params_value, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();
        const p = parsed.value;
        const layer = try self.resolveLayer(p.layer);

        const icon_handle = self.ctx.iconHandle(p.name) orelse return DispatchError.UnknownIcon;
        const anchor = resolveAnchor(layer, p.row, p.col);
        const metadata_id = try self.resolveMetadata(p.metadata_id);
        const opts: core.Layer.IconDrawOpts = .{
            .scale = try parseIconOption(core.IconScale, p.scale, .fit),
            .h_align = try parseIconOption(core.HAlign, p.h_align, .center),
            .v_align = try parseIconOption(core.VAlign, p.v_align, .center),
            .max_w = p.max_w,
            .max_h = p.max_h,
            .metadata_id = metadata_id,
        };
        if (p.foreground) {
            layer.drawIconOver(icon_handle, anchor.row, anchor.col, opts);
        } else {
            layer.drawIcon(icon_handle, anchor.row, anchor.col, opts);
        }
    }

    /// `tag_metadata`: sets exactly one cell's `metadata_id`, nothing else
    /// -- see `Layer.tagMetadata`'s doc comment. `metadata_id` is
    /// validated the same way `write_text`/`draw_icon`'s is
    /// (`resolveMetadata`), erroring `UnknownMetadata` on a bad handle.
    fn handleTagMetadata(self: *Dispatcher, alloc: std.mem.Allocator, params_value: std.json.Value) !void {
        const parsed = try std.json.parseFromValue(TagMetadataParams, alloc, params_value, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();
        const p = parsed.value;
        const layer = try self.resolveLayer(p.layer);
        const metadata_id = try self.resolveMetadata(p.metadata_id);
        layer.tagMetadata(p.row, p.col, metadata_id);
    }

    /// `draw_box`: resolves `style`'s 9 pieces against the icon catalog
    /// (`"{style}/tl"`, `"{style}/t"`, ... `"{style}/br"`/`"{style}/fill"`
    /// — the bundled `assets/icons/box/` and `assets/icons/dialog/`
    /// subtrees) and draws them via
    /// `Layer.drawBox`. Errors (missing name, or a registered name that
    /// somehow isn't in `ctx.images`) abort before drawing anything,
    /// rather than leaving a box half-drawn with some pieces missing.
    /// `mode` ("tile"/"stretch", default "tile") selects `core.Layer.BoxMode`
    /// -- reuses the same `InvalidIconOption` error `scale`/`h_align`/
    /// `v_align` already get for a bad value.
    fn handleDrawBox(self: *Dispatcher, alloc: std.mem.Allocator, params_value: std.json.Value) !void {
        const parsed = try std.json.parseFromValue(DrawBoxParams, alloc, params_value, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();
        const p = parsed.value;
        const layer = try self.resolveLayer(p.layer);

        const piece_names = [_][]const u8{ "tl", "t", "tr", "l", "fill", "r", "bl", "b", "br" };
        var pieces: [piece_names.len]core.ImageHandle = undefined;

        var name_buf: [64]u8 = undefined;
        for (piece_names, 0..) |piece, i| {
            const name = try std.fmt.bufPrint(&name_buf, "{s}/{s}", .{ p.style, piece });
            pieces[i] = self.ctx.iconHandle(name) orelse return DispatchError.UnknownIcon;
        }

        const tiles: core.Layer.BoxTiles = .{
            .tl = pieces[0],
            .t = pieces[1],
            .tr = pieces[2],
            .l = pieces[3],
            .fill = pieces[4],
            .r = pieces[5],
            .bl = pieces[6],
            .b = pieces[7],
            .br = pieces[8],
        };
        const mode = try parseIconOption(core.Layer.BoxMode, p.mode, .tile);
        const anchor = resolveAnchor(layer, p.row, p.col);
        layer.drawBox(tiles, mode, anchor.row, anchor.col, p.rows, p.cols);
    }

    /// `clear`: resets a region of the given layer's (default: root's)
    /// cells to blank. `rows`/`cols` default to "the rest of the layer
    /// from `row`/`col`" (clamped to 0 if `row`/`col` is already past the
    /// edge), so an all-defaulted `clear()` wipes everything.
    fn handleClear(self: *Dispatcher, alloc: std.mem.Allocator, params_value: std.json.Value) !void {
        const parsed = try std.json.parseFromValue(ClearParams, alloc, params_value, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();
        const p = parsed.value;

        const layer = try self.resolveLayer(p.layer);
        const rows = p.rows orelse (if (p.row < layer.height) layer.height - p.row else 0);
        const cols = p.cols orelse (if (p.col < layer.width) layer.width - p.col else 0);
        layer.clear(p.row, p.col, rows, cols);
    }

    /// A client-side convenience for aspect-ratio-aware placement
    /// (decisions.md: "the client's job, not the server's") — lets a
    /// client compute how many cells an image needs without hardcoding the
    /// session's cell pixel metrics, which otherwise live only in
    /// `Context.cell_px_w`/`cell_px_h` and glyphwire-host's matching
    /// constants.
    fn handleGetCellMetrics(self: *Dispatcher, alloc: std.mem.Allocator, id: std.json.Value) ![]u8 {
        return try rpc.response(alloc, id, CellMetricsResult{
            .cell_px_w = self.ctx.cell_px_w,
            .cell_px_h = self.ctx.cell_px_h,
        });
    }

    /// Builds an owned `core.TableStyle` from wire JSON -- `box_style`
    /// always ends up an owned copy (defaulted to a duped `"box"` when
    /// omitted) so `TableStyle.deinit` can always safely free it. Shared
    /// by `handleCreateTable` and `handleTableSetStyle`.
    fn resolveTableStyle(alloc: std.mem.Allocator, s: protocol.TableStyle) !core.TableStyle {
        const box_style = try alloc.dupe(u8, s.box_style orelse "box");
        return .{
            .borders = s.borders,
            .header_separator = s.header_separator,
            .box_style = box_style,
            .alt_row_bg = if (s.alt_row_bg) |c| colorFromJson(c) else null,
            .header_fg = if (s.header_fg) |c| colorFromJson(c) else null,
            .header_bg = if (s.header_bg) |c| colorFromJson(c) else null,
            .row_height = @max(s.row_height, 1),
            .max_icon_px = s.max_icon_px,
        };
    }

    /// `create_table`: builds the table's columns and style, then
    /// `Context.createTable` stores it on the resolved layer (root when
    /// omitted) at the resolved anchor (cursor-defaulted, same convention
    /// `draw_box`/`draw_icon` already use). No rows yet -- nothing to
    /// paint until `table_set_rows`.
    fn handleCreateTable(self: *Dispatcher, alloc: std.mem.Allocator, id: std.json.Value, params_value: std.json.Value) ![]u8 {
        const parsed = try std.json.parseFromValue(CreateTableParams, alloc, params_value, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();
        const p = parsed.value;
        const layer = try self.resolveLayer(p.layer);
        const anchor = resolveAnchor(layer, p.row, p.col);

        const talloc = self.ctx.alloc;
        const columns = try talloc.alloc(core.TableColumn, p.columns.len);
        var built: usize = 0;
        errdefer {
            for (columns[0..built]) |c| c.deinit(talloc);
            talloc.free(columns);
        }
        for (p.columns, 0..) |cj, i| {
            columns[i] = .{
                .name = try talloc.dupe(u8, cj.name),
                .kind = try parseTableOption(core.ColumnKind, cj.kind, .text),
                .sortable = cj.sortable,
                .width = cj.width,
                .min_width = cj.min_width,
                .h_align = try parseTableOption(core.HAlign, cj.h_align, .start),
            };
            built = i + 1;
        }

        const style = try resolveTableStyle(talloc, p.style);
        const table_handle = try self.ctx.createTable(p.layer, anchor.row, anchor.col, columns, style);

        return try rpc.response(alloc, id, CreateTableResult{ .handle = table_handle });
    }

    /// `destroy_table`: blanks the table's painted region and frees it
    /// (`Context.destroyTable`).
    fn handleDestroyTable(self: *Dispatcher, alloc: std.mem.Allocator, params_value: std.json.Value) !void {
        const parsed = try std.json.parseFromValue(DestroyTableParams, alloc, params_value, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();
        const p = parsed.value;
        self.ctx.destroyTable(p.layer, p.table) catch |err| switch (err) {
            error.UnknownLayer => return DispatchError.UnknownLayer,
            error.UnknownTable => return DispatchError.UnknownTable,
            else => return err,
        };
    }

    /// One `table_set_rows` cell: dupes `display`, resolves `sort_key`
    /// (a raw JSON number/string -- see `protocol.TableCell`'s doc comment,
    /// falling back to a copy of `display` for anything else or when
    /// omitted), resolves `icon`'s name against the icon catalog (erroring
    /// `UnknownIcon` immediately, same "fail loud at the point of use"
    /// treatment `draw_icon`'s `name` already gets), and validates
    /// `metadata_id` the same way `write_text`/`draw_icon`'s already is.
    fn buildTableCell(self: *Dispatcher, alloc: std.mem.Allocator, cj: protocol.TableCell) !core.TableCell {
        const display = try alloc.dupe(u8, cj.display);
        errdefer alloc.free(display);

        const sort_key: core.SortKey = if (cj.sort_key) |v| switch (v) {
            .integer => |n| .{ .number = @floatFromInt(n) },
            .float => |n| .{ .number = n },
            .string => |s| .{ .text = try alloc.dupe(u8, s) },
            else => .{ .text = try alloc.dupe(u8, cj.display) },
        } else .{ .text = try alloc.dupe(u8, cj.display) };
        errdefer sort_key.deinit(alloc);

        const icon_handle: ?core.ImageHandle = if (cj.icon) |name|
            self.ctx.iconHandle(name) orelse return DispatchError.UnknownIcon
        else
            null;

        const metadata_id = try self.resolveMetadata(cj.metadata_id);

        return .{
            .display = display,
            .sort_key = sort_key,
            .icon = icon_handle,
            .fg = if (cj.fg) |c| colorFromJson(c) else null,
            .metadata_id = metadata_id,
        };
    }

    fn buildTableRow(self: *Dispatcher, alloc: std.mem.Allocator, row_json: []const protocol.TableCell) !core.TableRow {
        const cells = try alloc.alloc(core.TableCell, row_json.len);
        var built: usize = 0;
        errdefer {
            for (cells[0..built]) |c| c.deinit(alloc);
            alloc.free(cells);
        }
        for (row_json, 0..) |cj, ci| {
            cells[ci] = try self.buildTableCell(alloc, cj);
            built = ci + 1;
        }
        return .{ .cells = cells };
    }

    /// Builds every row `table_set_rows` sent, fully independent of
    /// `core.Table.setRows` (which takes ownership of the result and
    /// handles a shape mismatch itself) -- kept as its own self-contained
    /// `errdefer` scope so a failure partway through building doesn't
    /// leave a dangling `errdefer` active around the later `setRows` call
    /// in `handleTableSetRows`, which already frees `rows` itself on its
    /// own error path.
    fn buildTableRows(self: *Dispatcher, alloc: std.mem.Allocator, rows_json: []const []const protocol.TableCell) ![]core.TableRow {
        const rows = try alloc.alloc(core.TableRow, rows_json.len);
        var built: usize = 0;
        errdefer {
            for (rows[0..built]) |r| r.deinit(alloc);
            alloc.free(rows);
        }
        for (rows_json, 0..) |row_json, ri| {
            rows[ri] = try self.buildTableRow(alloc, row_json);
            built = ri + 1;
        }
        return rows;
    }

    /// `table_set_rows`: replaces every row, re-sorts per the table's
    /// current sort state, and repaints (`Table.render`) -- see
    /// core.zig's Table section on why this needs no host/main.zig
    /// changes to actually show up.
    fn handleTableSetRows(self: *Dispatcher, alloc: std.mem.Allocator, params_value: std.json.Value) !void {
        const parsed = try std.json.parseFromValue(TableSetRowsParams, alloc, params_value, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();
        const p = parsed.value;
        const layer = try self.resolveLayer(p.layer);
        const table = layer.tables.getPtr(p.table) orelse return DispatchError.UnknownTable;

        const rows = try self.buildTableRows(self.ctx.alloc, p.rows);
        table.setRows(rows) catch |err| switch (err) {
            error.TableRowShapeMismatch => return DispatchError.TableRowShapeMismatch,
        };
        try table.render(layer, self.ctx);
    }

    /// `table_set_sort`: `column`/`direction` both defaulted (`null`/
    /// `"none"`) mean "back to insertion order" -- see
    /// `core.Table.sortedIndices`. Repaints immediately, same as
    /// `table_set_rows` -- this is the message a future sort-aware
    /// `glyphwire-shell` click handler would call.
    fn handleTableSetSort(self: *Dispatcher, alloc: std.mem.Allocator, params_value: std.json.Value) !void {
        const parsed = try std.json.parseFromValue(TableSetSortParams, alloc, params_value, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();
        const p = parsed.value;
        const layer = try self.resolveLayer(p.layer);
        const table = layer.tables.getPtr(p.table) orelse return DispatchError.UnknownTable;

        const dir = try parseTableOption(core.SortDirection, p.direction, .none);
        table.setSort(p.column, dir);
        try table.render(layer, self.ctx);
    }

    /// `table_set_style`: replaces the table's whole style (e.g. toggling
    /// `alt_row_bg` on/off) and repaints.
    fn handleTableSetStyle(self: *Dispatcher, alloc: std.mem.Allocator, params_value: std.json.Value) !void {
        const parsed = try std.json.parseFromValue(TableSetStyleParams, alloc, params_value, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();
        const p = parsed.value;
        const layer = try self.resolveLayer(p.layer);
        const table = layer.tables.getPtr(p.table) orelse return DispatchError.UnknownTable;

        const style = try resolveTableStyle(self.ctx.alloc, p.style);
        table.setStyle(style);
        try table.render(layer, self.ctx);
    }

    /// `table_get_state`: reads back a table's structured config (columns,
    /// sort, style, row count, revision) -- not its rendered cells, which
    /// are already readable through the owning layer's normal `get_cells`
    /// (a table paints into ordinary cells, see core.zig's Table
    /// section), so there's no separate "get rendered table" message.
    /// For a future client that needs to know e.g. which columns are
    /// sortable before deciding what a header click should do.
    fn handleTableGetState(self: *Dispatcher, alloc: std.mem.Allocator, id: std.json.Value, params_value: std.json.Value) ![]u8 {
        const parsed = try std.json.parseFromValue(TableGetStateParams, alloc, params_value, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();
        const p = parsed.value;
        const layer = try self.resolveLayer(p.layer);
        const table = layer.tables.getPtr(p.table) orelse return DispatchError.UnknownTable;

        const columns = try alloc.alloc(protocol.ColumnState, table.columns.len);
        defer alloc.free(columns);
        for (table.columns, 0..) |c, i| {
            columns[i] = .{
                .name = c.name,
                .kind = @tagName(c.kind),
                .sortable = c.sortable,
                .width = c.width,
                .min_width = c.min_width,
                .h_align = @tagName(c.h_align),
            };
        }

        return try rpc.response(alloc, id, protocol.TableStateResult{
            .columns = columns,
            .row_count = table.rows.len,
            .sort_column = table.sort_column,
            .sort_direction = @tagName(table.sort_dir),
            .style = .{
                .borders = table.style.borders,
                .header_separator = table.style.header_separator,
                .box_style = table.style.box_style,
                .alt_row_bg = if (table.style.alt_row_bg) |c| colorToJson(c) else null,
                .header_fg = if (table.style.header_fg) |c| colorToJson(c) else null,
                .header_bg = if (table.style.header_bg) |c| colorToJson(c) else null,
                .row_height = table.style.row_height,
                .max_icon_px = table.style.max_icon_px,
            },
            .painted = .{
                .row = table.painted.row,
                .col = table.painted.col,
                .rows = table.painted.rows,
                .cols = table.painted.cols,
            },
            .revision = table.revision,
        });
    }

    // ── Selection & clipboard ──────────────────────────────────────────

    fn pointFromWire(p: protocol.SelectionPointWire) core.SelectionPoint {
        return .{ .above = p.above, .col = p.col };
    }

    /// Broadcasts the resolved layer's current selection as a `selection`
    /// notification -- shared tail of `set_selection` / `update_selection`
    /// / `clear_selection`, so all three fan out the same shape.
    fn selectionBroadcast(alloc: std.mem.Allocator, layer: *const core.Layer) !HandleResult {
        const body = try rpc.selectionNotification(alloc, layer.selection);
        return .{ .broadcast = .{ .event = "selection", .body = body } };
    }

    fn handleSetSelection(self: *Dispatcher, alloc: std.mem.Allocator, params_value: std.json.Value) !HandleResult {
        const parsed = try std.json.parseFromValue(protocol.SetSelectionParams, alloc, params_value, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();
        const layer = try self.resolveLayer(parsed.value.layer);
        layer.setSelection(pointFromWire(parsed.value.anchor), pointFromWire(parsed.value.active));
        return selectionBroadcast(alloc, layer);
    }

    fn handleUpdateSelection(self: *Dispatcher, alloc: std.mem.Allocator, params_value: std.json.Value) !HandleResult {
        const parsed = try std.json.parseFromValue(protocol.UpdateSelectionParams, alloc, params_value, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();
        const layer = try self.resolveLayer(parsed.value.layer);
        layer.updateSelectionActive(pointFromWire(parsed.value.active));
        return selectionBroadcast(alloc, layer);
    }

    fn handleClearSelection(self: *Dispatcher, alloc: std.mem.Allocator, params_value: std.json.Value) !HandleResult {
        const parsed = try std.json.parseFromValue(protocol.LayerOnlyParams, alloc, params_value, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();
        const layer = try self.resolveLayer(parsed.value.layer);
        layer.clearSelection();
        return selectionBroadcast(alloc, layer);
    }

    fn handleGetSelection(self: *Dispatcher, alloc: std.mem.Allocator, id: std.json.Value, params_value: std.json.Value) ![]u8 {
        const parsed = try std.json.parseFromValue(protocol.LayerOnlyParams, alloc, params_value, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();
        const layer = try self.resolveLayer(parsed.value.layer);
        const state: protocol.SelectionState = if (layer.selection) |s| .{
            .active = true,
            .anchor = .{ .above = s.anchor.above, .col = s.anchor.col },
            .active_end = .{ .above = s.active.above, .col = s.active.col },
        } else .{ .active = false };
        return try rpc.response(alloc, id, state);
    }

    fn handleGetSelectionText(self: *Dispatcher, alloc: std.mem.Allocator, id: std.json.Value, params_value: std.json.Value) ![]u8 {
        const parsed = try std.json.parseFromValue(protocol.LayerOnlyParams, alloc, params_value, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();
        const layer = try self.resolveLayer(parsed.value.layer);
        const text = (try layer.selectionText(alloc)) orelse try alloc.dupe(u8, "");
        defer alloc.free(text);
        return try rpc.response(alloc, id, protocol.SelectionTextResult{ .text = text });
    }

    /// Builds the `HighlightState` response for `layer`: every currently
    /// highlighted id with its stored JSON blob (null for a dangling id).
    fn highlightStateResponse(self: *Dispatcher, alloc: std.mem.Allocator, id: std.json.Value, layer: *const core.Layer) ![]u8 {
        const ids = layer.highlighted_ids.items;
        const entries = try alloc.alloc(protocol.HighlightEntry, ids.len);
        defer alloc.free(entries);
        for (ids, entries) |mid, *e| e.* = .{ .id = mid, .json = self.ctx.metadataJson(mid) };
        return try rpc.response(alloc, id, protocol.HighlightState{ .entries = entries });
    }

    fn handleToggleHighlight(self: *Dispatcher, alloc: std.mem.Allocator, id: std.json.Value, params_value: std.json.Value) ![]u8 {
        const parsed = try std.json.parseFromValue(protocol.ToggleHighlightParams, alloc, params_value, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();
        const p = parsed.value;
        const layer = try self.resolveLayer(p.layer);

        // Resolve the cell to a metadata id the same way `get_metadata`
        // does, honouring `view_offset` for a click made while scrolled
        // back. A cell with no tag is a no-op (the set is unchanged).
        const metadata_id = if (p.row < layer.height and p.col < layer.width)
            (if (p.view_offset > 0)
                layer.viewRow(p.view_offset, p.row)[p.col].metadata_id
            else
                layer.cell(p.row, p.col).metadata_id)
        else
            null;
        if (metadata_id) |mid| try layer.toggleHighlightId(mid);

        return try self.highlightStateResponse(alloc, id, layer);
    }

    fn handleSetHighlight(self: *Dispatcher, alloc: std.mem.Allocator, id: std.json.Value, params_value: std.json.Value) ![]u8 {
        const parsed = try std.json.parseFromValue(protocol.SetHighlightParams, alloc, params_value, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();
        const layer = try self.resolveLayer(parsed.value.layer);
        try layer.setHighlightIds(parsed.value.ids);
        return try self.highlightStateResponse(alloc, id, layer);
    }

    fn handleClearHighlight(self: *Dispatcher, alloc: std.mem.Allocator, id: std.json.Value, params_value: std.json.Value) ![]u8 {
        const parsed = try std.json.parseFromValue(protocol.LayerOnlyParams, alloc, params_value, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();
        const layer = try self.resolveLayer(parsed.value.layer);
        layer.clearHighlightIds();
        return try self.highlightStateResponse(alloc, id, layer);
    }

    fn handleGetHighlight(self: *Dispatcher, alloc: std.mem.Allocator, id: std.json.Value, params_value: std.json.Value) ![]u8 {
        const parsed = try std.json.parseFromValue(protocol.LayerOnlyParams, alloc, params_value, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();
        const layer = try self.resolveLayer(parsed.value.layer);
        return try self.highlightStateResponse(alloc, id, layer);
    }

    fn handleSetClipboard(self: *Dispatcher, alloc: std.mem.Allocator, params_value: std.json.Value) !void {
        const parsed = try std.json.parseFromValue(protocol.ClipboardTextParams, alloc, params_value, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();
        try self.ctx.setClipboard(parsed.value.text);
    }

    fn handleGetClipboard(self: *Dispatcher, alloc: std.mem.Allocator, id: std.json.Value) ![]u8 {
        return try rpc.response(alloc, id, protocol.ClipboardResult{ .text = self.ctx.clipboardText() });
    }

    /// `get_errors`: returns this connection's buffered failed-notification
    /// records (oldest first) plus `dropped` -- how many were lost to a
    /// full ring since the last call -- then drains the ring. Empty and
    /// `dropped: 0` for a connection that never subscribed to `"error"`,
    /// since nothing gets recorded in that case. See
    /// `Dispatcher.recordError` and decisions.md's Error reporting section.
    fn handleGetErrors(self: *Dispatcher, alloc: std.mem.Allocator, id: std.json.Value) ![]u8 {
        var entries: std.ArrayList(protocol.DispatchErrorEntry) = .empty;
        defer entries.deinit(alloc);
        var i: usize = 0;
        while (i < self.error_ring_len) : (i += 1) {
            const e = &self.error_ring[(self.error_ring_start + i) % error_ring_capacity];
            try entries.append(alloc, .{ .method = e.method(), .code = e.code, .seq = e.seq });
        }

        const body = try rpc.response(alloc, id, protocol.ErrorsResult{ .errors = entries.items, .dropped = self.error_dropped });

        // Drain: the reply is built, so these are now delivered.
        self.error_ring_start = 0;
        self.error_ring_len = 0;
        self.error_dropped = 0;
        return body;
    }
};
