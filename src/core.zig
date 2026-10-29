// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: MPL-2.0

const std = @import("std");

/// The VT escape machine `Layer.writeRuns` feeds (`vt.zig`): its state is
/// `Layer.vt`.
const vt = @import("vt.zig");
pub const Vt = vt.Vt;
pub const EscState = vt.EscState;
pub const SgrPen = vt.SgrPen;

pub const theme = @import("theme.zig");
pub const divider_style = @import("divider_style.zig");
const image = @import("image.zig");

/// Truecolor RGBA, or a reference to a theme palette slot or role (`ref`).
/// A reference's `r`/`g`/`b` mean nothing: the host resolves it against
/// the drawing context's theme (`theme.Theme.resolve`) when it renders,
/// which is how a theme switch recolours what is already on screen. Its
/// `a` still applies, multiplied into the theme colour's.
pub const Color = struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8 = 255,
    ref: ColorRef = .none,

    /// Palette slot `s` (0-23: dim, normal, bright ANSI hues).
    pub fn slot(s: theme.Slot) Color {
        return .{ .r = 0, .g = 0, .b = 0, .ref = .{ .slot = s } };
    }

    /// ANSI hue `hue` at `level`, as a slot reference.
    pub fn ansi(level: theme.Level, hue: theme.Hue) Color {
        return slot(theme.slot(level, hue));
    }

    /// Theme role `r` (`fg`, `keyword`, `table_header_bg`, ...).
    pub fn role(r: theme.Role) Color {
        return .{ .r = 0, .g = 0, .b = 0, .ref = .{ .role = r } };
    }

    pub fn withAlpha(self: Color, a: u8) Color {
        var c = self;
        c.a = a;
        return c;
    }

    pub fn eql(a: Color, b: Color) bool {
        return a.r == b.r and a.g == b.g and a.b == b.b and a.a == b.a and std.meta.eql(a.ref, b.ref);
    }
};

/// What a `Color` stands for besides its own RGB. See `Color`.
pub const ColorRef = union(enum) {
    none,
    slot: theme.Slot,
    role: theme.Role,
};

/// Server-generated reference to a loaded image, per the Object Model's
/// Image section.
pub const ImageHandle = u32;

/// Server-generated reference to an opaque, client-defined metadata blob
/// (`create_metadata`) -- a cell tags itself with one via
/// `Cell.metadata_id`, e.g. `write_text`/`draw_icon`'s optional
/// `metadata_id` param, rather than embedding the blob directly, so many
/// cells can share one without copying it (a whole filename written by one
/// `write_text` call, say, all pointing at the same id).
pub const MetadataHandle = u32;

pub const MetadataError = error{UnknownMetadata};

/// An opaque, server-stored-but-not-interpreted blob -- `json` because the
/// convention is a JSON string (so command-line tools and a future TUI can
/// each embed whatever shape of data they want, e.g. `{"kind":"file",
/// "path":"...","command":"cd ..."}`), but the server never parses it,
/// only stores and returns it verbatim (same treatment `ImageEntry.bytes`
/// gets for PNG bytes).
pub const Metadata = struct {
    json: []u8,
    /// What an Alt+drag starting on a cell tagged with this id hands the
    /// OS, or null when the span isn't draggable. Kept beside `json`
    /// rather than read out of it, so the blob stays opaque to the host.
    drag: ?DragPayload = null,
};

/// An outbound OS drag's contents, as a client describes them: on a
/// metadata tag (`create_metadata`'s `drag`) or for a drag it starts
/// itself (`start_drag`). Borrowed; `DragPayload` is the owned copy.
///
/// `uris` are full URIs (`file:///home/me/a%20b.mp3`), offered to the drop
/// target as `text/uri-list`. `label` and `icon` (an icon catalog name,
/// `file/audio`) are what the host draws under the pointer during the
/// drag.
pub const DragSpec = struct {
    uris: []const []const u8,
    label: ?[]const u8 = null,
    icon: ?[]const u8 = null,
};

pub const DragError = error{
    /// A drag with no URIs: there is nothing to hand the drop target.
    EmptyDrag,
};

/// The owned copy of a `DragSpec`.
pub const DragPayload = struct {
    uris: [][]u8,
    label: ?[]u8 = null,
    icon: ?[]u8 = null,

    pub fn init(alloc: std.mem.Allocator, spec: DragSpec) !DragPayload {
        if (spec.uris.len == 0) return DragError.EmptyDrag;
        const uris = try alloc.alloc([]u8, spec.uris.len);
        var filled: usize = 0;
        errdefer {
            for (uris[0..filled]) |u| alloc.free(u);
            alloc.free(uris);
        }
        for (spec.uris) |u| {
            uris[filled] = try alloc.dupe(u8, u);
            filled += 1;
        }
        const label = if (spec.label) |l| try alloc.dupe(u8, l) else null;
        errdefer if (label) |l| alloc.free(l);
        const icon = if (spec.icon) |i| try alloc.dupe(u8, i) else null;
        return .{ .uris = uris, .label = label, .icon = icon };
    }

    pub fn deinit(self: *DragPayload, alloc: std.mem.Allocator) void {
        for (self.uris) |u| alloc.free(u);
        alloc.free(self.uris);
        if (self.label) |l| alloc.free(l);
        if (self.icon) |i| alloc.free(i);
        self.* = undefined;
    }

    /// The borrowed view, for handing the same contents on.
    pub fn view(self: *const DragPayload) DragSpec {
        return .{ .uris = self.uris, .label = self.label, .icon = self.icon };
    }
};

/// A cell's image-backed background: which loaded image, the pixel offset
/// into that image this cell should display, and the uniform scale factor
/// the image is drawn at. `draw_image` computes all three per cell from
/// the draw call's anchor -- see `Layer.drawImage` -- rather than a
/// sub-image ever being extracted or cached as its own resource
/// (decisions.md's Image section).
///
/// `offset_x`/`offset_y` are always in *source* image pixels. `scale` is
/// `1.0` for a natural-size draw (the original behavior, and the default),
/// `< 1.0` when the client asked the image shrunk to fit a target width
/// (glyphwire-view's `--size fit-width`). At `scale != 1` each covered
/// cell samples `cell_px / scale` source pixels and the renderer draws
/// that slice scaled back down into the cell -- see `Layer.drawImage` and
/// host/render.zig's `emitImageCell`. Upscaling (`scale > 1`) is never
/// requested by a client but the math doesn't forbid it.
///
/// `src_right`/`src_bottom` are the exclusive source-pixel bound this
/// covered cell must not sample past, on top of the image's own real
/// edge -- how `draw_image`'s optional source rect (`ImageSrcRect`, a
/// sprite-sheet-style sub-region of the image) clips at *its own* edge
/// instead of the whole image's, so a sprite drawn from the middle of a
/// sheet doesn't bleed into its neighbours at its partial edge cell. Both
/// default to `maxInt`, i.e. "no bound beyond the image's own edge" --
/// byte-identical to the pre-source-rect behavior when no source rect was
/// requested.
pub const ImageBg = struct {
    handle: ImageHandle,
    offset_x: u32,
    offset_y: u32,
    scale: f32 = 1.0,
    src_right: u32 = std.math.maxInt(u32),
    src_bottom: u32 = std.math.maxInt(u32),
};

/// A sub-rectangle of an image's source pixels to sample from --
/// general-purpose sprite-sheet / sub-image support for `draw_image`, not
/// specific to any one client. `w`/`h` of `0` (the default) mean "to the
/// image's own right/bottom edge from `(x, y)`", so `.{}` reproduces the
/// old whole-image behavior exactly. A rect that starts at or past the
/// image's own edge, or is otherwise empty after clamping to it, simply
/// draws nothing -- same treatment `drawImage` already gives an image
/// smaller than the requested span.
pub const ImageSrcRect = struct {
    x: u32 = 0,
    y: u32 = 0,
    w: u32 = 0,
    h: u32 = 0,
};

/// How an icon's source image is sized against its anchor cell:
/// - `fit` (the original, still-default behavior): shrunk/grown uniformly
///   (aspect preserved) to fit exactly within the cell.
/// - `natural`: drawn at its own native pixel size, optionally capped by
///   `IconBg.max_w`/`max_h` (uniform, aspect preserved, only ever shrinking
///   -- never upscaled past native size). Bigger than the cell overflows
///   into neighboring cells' *pixels* -- a pure rendering overlay, see
///   `IconBg`'s doc comment, so it never marks/claims those cells.
/// - `stretch`: fills the cell exactly on both axes, aspect *not*
///   preserved. Used by table border tiles rather than `fit`: a
///   non-square cell (this project's terminal cells usually are, since
///   glyph advance and line height rarely match) leaves `fit`-and-center
///   padding on whichever axis isn't the limiting one, breaking a
///   multi-tile border into visibly gapped segments along that axis --
///   `stretch` guarantees the tile always touches every edge of its cell,
///   so adjacent tiles' border lines stay continuous regardless of the
///   cell's aspect ratio.
pub const IconScale = enum { fit, natural, stretch };

/// Where a (possibly `natural`-sized, overflowing) icon sits relative to
/// its anchor cell along one axis. `center` (the default, matching the
/// pre-overflow behavior) grows the overflow symmetrically both ways;
/// `start`/`end` instead grow it entirely to one side, keeping the edge
/// on the anchor's `start`/`end` side flush with the cell.
pub const HAlign = enum { start, center, end };
pub const VAlign = enum { start, center, end };

/// A cell's icon-backed background: which loaded icon, how it's scaled,
/// and where it's aligned relative to its anchor cell. A `natural`-scaled
/// icon bigger than one cell overflows into neighboring cells' *pixels*
/// only -- deliberately not their data: this stays a single-cell anchor
/// in the grid (unlike `ImageBg`'s per-cell offset tracking), so
/// `get_cells`/clear/scroll on a neighboring cell know nothing about the
/// overflow, and the host's render pass is responsible for drawing it on
/// top of whatever those neighboring cells render. Kept deliberately
/// simple over `draw_image`'s span-marking approach because an icon is
/// meant to always read as one complete picture, not clipped/composed
/// per cell -- see decisions.md's Icon section.
pub const IconBg = struct {
    handle: ImageHandle,
    scale: IconScale = .fit,
    h_align: HAlign = .center,
    v_align: VAlign = .center,
    /// Only consulted when `scale == .natural` -- `fit`'s box is always
    /// exactly the cell, and `stretch` always fills it exactly, so neither
    /// has anything left to cap.
    max_w: ?u32 = null,
    max_h: ?u32 = null,
};

/// A cell's background: a flat color, a reference to a loaded image tile
/// (`draw_image`, clipped rather than stretched -- see
/// `ImageBg`), or a reference to a loaded icon (`draw_icon`, see
/// `IconBg`). Mutually exclusive per decisions.md.
pub const Background = union(enum) {
    color: Color,
    image: ImageBg,
    icon: IconBg,
};

// Image format sniffing and header measuring: `image.zig`.
pub const ImageInfo = image.ImageInfo;
pub const ImageFormat = image.ImageFormat;
pub const ImageError = image.ImageError;
pub const detectImageFormat = image.detectImageFormat;
pub const imageDimensions = image.imageDimensions;
pub const pngDimensions = image.pngDimensions;
pub const jpegDimensions = image.jpegDimensions;
pub const bmpDimensions = image.bmpDimensions;
pub const gifDimensions = image.gifDimensions;

/// A loaded image resource: the raw bytes as received, the container
/// format they were declared as, plus natural pixel dimensions. The
/// headless core never decodes pixels -- `width`/`height` come from a
/// fixed-offset header read per `format` (`imageDimensions`), not a real
/// decode -- so `get_image_info` doesn't need an image-codec dependency
/// here, and unlike an earlier idea in roadmap.md, the *client* doesn't
/// need to supply dimensions either. Full pixel decoding stays the
/// renderer's job (glyphwire-host, which already links zstbi), lazily on
/// first encountering a `.image` background it hasn't uploaded yet.
pub const ImageEntry = struct {
    bytes: []u8,
    format: ImageFormat,
    width: u32,
    height: u32,
    /// Bumped by every `update_image` on this handle. The bytes behind a
    /// handle are no longer immutable, so glyphwire-host can't treat "I
    /// already uploaded handle N" as "my texture for handle N is current"
    /// -- it caches this alongside the texture and re-decodes when it
    /// moves. See `Context.updateImage`.
    generation: u32 = 0,
    /// The connection that issued `load_image`, or null for an image
    /// loaded in-process (glyphwire-host's icon scan, `server/main.zig`,
    /// tests). While this is non-null the image is **pinned**: the
    /// scrollback sweep leaves it alone even with no cell referencing it,
    /// because its loader is still alive and may draw (or `update_image`)
    /// it at any moment. Cleared by `Context.releaseImages` when that
    /// connection closes, which is what makes the image a sweep
    /// candidate. See `sweepImages`.
    loader: ?ConnId = null,
    /// Whether this image may ever be swept (see `sweepImages`). True
    /// only for an image that arrived over a socket: an in-process load
    /// is host-owned infrastructure (the bundled icons) with no
    /// connection lifecycle behind it, so it stays for the session.
    sweepable: bool = false,
};

/// How many bytes of loaded images a session tolerates before a
/// `load_image` / `update_image` triggers the scrollback sweep
/// (`Session.sweepImages`). Not a hard cap: the sweep frees only what is
/// genuinely unreachable, so a session legitimately displaying more than
/// this simply stays above it and pays one wasted scan per load. Sized so
/// an ordinary session never sweeps at all, and a shell that has scrolled
/// a few hundred screenshots past sweeps every few dozen images.
pub const default_image_sweep_budget: usize = 64 * 1024 * 1024;

/// Failures of the image *lifecycle* messages (`destroy_image` /
/// `update_image`), as opposed to `ImageError`'s header-parsing failures.
/// `UnknownImage` deliberately shares its name with `DispatchError`'s --
/// Zig merges same-named errors across sets, so the dispatcher's existing
/// `UnknownImage` mapping covers both without a translation step.
pub const ImageResourceError = error{
    UnknownImage,
    /// The handle is registered in the icon catalog (`Context.icons`).
    /// Icons are session infrastructure shared by every context through
    /// `asset_fallback`, and their handles are observable to any client
    /// (`get_cells` reports `bg_icon.handle`), so destroying or replacing
    /// one on a client's say-so would break `draw_icon` for everyone.
    /// Refused rather than silently ignored, so a client that got a
    /// handle from the wrong place hears about it.
    ImageIsIcon,
};

/// Which underline a cell carries, if any. The five drawn styles are the
/// SGR `4:1`..`4:5` set every modern terminal has settled on, and they are
/// here because a language server's diagnostics need a mark that is *not*
/// a colour: a squiggle under a misspelled identifier has to coexist with
/// the syntax colour on that identifier and with a selection tint over it,
/// which a second fg or bg cannot do.
///
/// `curly` is the diagnostic squiggle; `single` is the ordinary underline
/// a link or a heading wants. `dotted` and `dashed` round out the SGR set
/// rather than adding cases nothing asks for -- the renderer draws all
/// five from the same run of rects, so the marginal cost of the last three
/// is a pattern table.
///
/// Note the deliberate gap: bold and italic stay *parsed and ignored* (see
/// `SgrPen`). Underline earns its `Style` field because it is drawn from
/// geometry the host already has (a rect at the cell's baseline), and
/// strikethrough (`Style.strike`) for the same reason; the others need a
/// second and third font face in the atlas, which is a different piece of
/// work.
pub const Underline = enum { none, single, double, curly, dotted, dashed };

/// A cell's underline: which style, and in what colour. `color` null means
/// "the cell's own `fg`", which is what an ordinary underline wants; a
/// diagnostic sets it explicitly so a red squiggle can sit under
/// syntax-coloured text without recolouring the text itself. This is SGR
/// `58`/`59`'s distinction too.
pub const UnderlineStyle = struct {
    style: Underline = .none,
    color: ?Color = null,

    pub fn eql(a: UnderlineStyle, b: UnderlineStyle) bool {
        if (a.style != b.style) return false;
        if (a.color == null and b.color == null) return true;
        const ac = a.color orelse return false;
        const bc = b.color orelse return false;
        return ac.eql(bc);
    }
};

/// The lines a write draws on its text: an underline, and a strikethrough.
/// Bundled because they travel together from the SGR pen and a
/// `write_text`'s own arguments down to each cell's `Style`.
pub const Decoration = struct {
    underline: UnderlineStyle = .{},
    strike: bool = false,
};

pub const Style = struct {
    fg: Color,
    bg: Background,
    /// See `UnderlineStyle`. Defaults to no underline, so every existing
    /// `Style` initializer means what it did before this field existed.
    underline: UnderlineStyle = .{},
    /// A line through the text, in its `fg` -- `write_text`'s
    /// `strikethrough`, or SGR `9`. On a scaled glyph only the glyph's own
    /// cell carries it, and the host draws it across the whole footprint
    /// at the block's middle; the fill around the glyph never does, so the
    /// line isn't drawn twice at the wrong height.
    strike: bool = false,
};

/// The blank cell's style. `bg` is **fully transparent** (alpha 0), and
/// alpha is the only thing that makes a cell background transparent: the
/// renderer skips a `.color` background whose alpha is 0 and paints any
/// other one, black included. An explicit `{r: 0, g: 0, b: 0}` from a
/// client (whose wire `a` defaults to 255) is therefore an opaque black
/// fill, not "the default" -- which is what makes `clear`'s `bg` and the
/// layer `background` property usable with a black theme. `fg` is the
/// theme's `fg` role, so unstyled text follows the theme.
pub const default_style: Style = .{
    .fg = Color.role(.fg),
    .bg = .{ .color = .{ .r = 0, .g = 0, .b = 0, .a = 0 } },
};

/// Modifier keys held when an input event was generated, folded left and
/// right. Captured by the server at the moment it routes the event (from
/// `Session.mods`) and carried on `key_down`/`key_up`/`mouse_button`/
/// `mouse_move`, so a client that falls behind still sees the chord the
/// user actually pressed rather than whatever is held when it gets round
/// to the event.
pub const Mods = struct {
    ctrl: bool = false,
    alt: bool = false,
    shift: bool = false,
    super: bool = false,
};

/// Inline byte capacity for a cell's grapheme cluster. This is a plain
/// fixed buffer for the slice, not the small-string-optimized
/// inline+overflow representation decisions.md settles on long term —
/// upgrade this alongside real UAX #29 segmentation.
pub const grapheme_inline_len = 8;

const unicode_width = @import("unicode_width.zig");
pub const codepointWidth = unicode_width.codepointWidth;
pub const isZeroWidth = unicode_width.isZeroWidth;
pub const stringWidth = unicode_width.stringWidth;

/// Word-wraps `text` into lines at most `width` display cells wide,
/// yielding slices of `text` (no allocation). Breaks at spaces; a word
/// wider than `width` is hard-broken at a codepoint boundary, so a wide
/// character never splits. `\n` forces a break. Leading spaces of a
/// line and trailing spaces at a break are dropped. A single glyph wider
/// than `width` (a wide character in a 1-cell column) is still yielded on
/// its own line so the walk always makes progress. `width == 0` yields
/// nothing.
///
/// This is the one wrap rule for a `.wrap` table column: `Table` paints
/// with it and a client that lays out content below a table (gwmd) sizes
/// the table with it, so the two can't disagree on a row's height.
pub const WrapIterator = struct {
    text: []const u8,
    width: usize,
    pos: usize = 0,

    pub fn init(text: []const u8, width: usize) WrapIterator {
        return .{ .text = text, .width = width };
    }

    pub fn next(self: *WrapIterator) ?[]const u8 {
        const text = self.text;
        if (self.width == 0) return null;
        while (self.pos < text.len and text[self.pos] == ' ') self.pos += 1;
        if (self.pos >= text.len) return null;

        const start = self.pos;
        var i = start;
        var w: usize = 0;
        // Byte index of the last space whose prefix fits: the soft break.
        var soft_break: ?usize = null;
        while (i < text.len) {
            if (text[i] == '\n') {
                self.pos = i + 1;
                return trimTrailingSpaces(text[start..i]);
            }
            const cp_len = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
            const end = @min(i + cp_len, text.len);
            const cw: usize = codepointWidth(std.unicode.utf8Decode(text[i..end]) catch 0xFFFD);
            if (w + cw > self.width) {
                if (text[i] == ' ') {
                    self.pos = i;
                    return trimTrailingSpaces(text[start..i]);
                }
                if (soft_break) |b| {
                    self.pos = b;
                    return trimTrailingSpaces(text[start..b]);
                }
                // One word longer than the line: hard-break it. A glyph
                // wider than the whole line goes out alone.
                const cut = if (i == start) end else i;
                self.pos = cut;
                return text[start..cut];
            }
            if (text[i] == ' ') soft_break = i;
            w += cw;
            i = end;
        }
        self.pos = text.len;
        return trimTrailingSpaces(text[start..]);
    }

    fn trimTrailingSpaces(s: []const u8) []const u8 {
        return std.mem.trimEnd(u8, s, " ");
    }
};

/// How many lines `WrapIterator` breaks `text` into at `width`.
pub fn wrapLineCount(text: []const u8, width: usize) usize {
    var it = WrapIterator.init(text, width);
    var n: usize = 0;
    while (it.next()) |_| n += 1;
    return n;
}

/// A cell's role in East Asian Width terms: an ordinary 1-cell character,
/// the left ("primary") cell of a 2-cell wide character that holds the
/// grapheme, or the right cell of such a pair which renders nothing of
/// its own (it carries the lead's background + `metadata_id` so a click
/// on either half resolves the same). See decisions.md, Cell content.
pub const CellWidth = enum(u2) { narrow, wide_lead, wide_spacer };

/// A per-cell hint that the cell's glyph should be drawn larger than one
/// cell's normal pixel size -- `write_text`'s optional `scale` (`x1_5` is
/// "1.5x", `x2` is "2x", `x3` is "3x"; wire strings match the tag names exactly, see
/// `write_text` in docs/api.md). The enlarged glyph still renders from the
/// one cell that holds the grapheme and carries `text_scale`, but the
/// write **advances the cursor by the scaled width** (`scaledPitch` cells
/// per display column), filling the cells it steps over -- and the same
/// span on the `scaledPitch - 1` rows below, which the glyph draws down
/// over -- with blanks in the run's background and `metadata_id`. So
/// back-to-back scaled characters no longer draw on top of each other,
/// the whole block under the glyph takes the run's background, and a
/// click anywhere under it hit-tests as part of the run. The rows below
/// are clipped at the layer's bottom (never scrolled into), and the
/// cursor stays on the glyph's own row: reserving those rows, so later
/// text isn't written over the block, is still the caller's job. See
/// decisions.md's Text scale section.
pub const TextScale = enum { x1, x1_5, x2, x3 };

/// How a selection's copied text joins a row to the one below it --
/// `write_text`'s `line_join`, carried by the last glyph the write drew
/// (`Cell.line_join`). `newline` is a hard line end, every row's default.
/// A client that word-wraps prose itself marks each row it broke with
/// `space` (the space the wrap swallowed comes back) or, for a word it
/// had to split mid-way, `direct`, so a copied paragraph comes out as one
/// line again rather than as the window's line breaks. The row below's
/// leading blanks are then indentation, not text, and are dropped.
pub const LineJoin = enum(u2) { newline, space, direct };

/// Cells a `scale` glyph advances per display column: its size rounded up
/// to whole cells, so 1.5x and 2x both step two and 3x steps three.
pub fn scaledPitch(scale: TextScale) usize {
    return switch (scale) {
        .x1 => 1,
        .x1_5, .x2 => 2,
        .x3 => 3,
    };
}

pub const Cell = struct {
    grapheme_bytes: [grapheme_inline_len]u8 = @splat(0),
    grapheme_len: u8 = 0,
    wide: CellWidth = .narrow,
    text_scale: TextScale = .x1,
    /// Nonzero on a blank a scaled glyph draws down over (see
    /// `TextScale`): how many rows *below* the glyph's own row this cell
    /// sits, `1..scaledPitch - 1`. Selection reads it to treat the whole
    /// block as the glyph's row -- a drag onto the lower half of a scaled
    /// line lands on that line, not on a line of its own, and the tint
    /// covers every row the glyph draws into. Zero for every other cell.
    under_scaled: u2 = 0,
    /// Whether a selection takes this cell in -- `write_text`'s
    /// `selectable` (default true). A client's panel chrome (borders,
    /// padding) writes `false` so a selection's tint and copied text stop
    /// at the text inside it: an unselectable cell is never copied, and
    /// the tint on a row starts after any leading unselectable cells and
    /// ends at the last selectable non-blank one.
    selectable: bool = true,
    /// A secret's stand-in -- `write_text`'s `masked`: a password field
    /// draws one ● per typed character and marks those cells so the mask
    /// never reads back out. A masked cell is never selected or copied
    /// (the write also clears `selectable`), and `get_cells` reports it
    /// as an empty cell, so nothing reading the grid learns where a
    /// password field is or how long its contents are. The secret itself
    /// never reaches the server; this keeps its length off the wire too.
    masked: bool = false,
    /// What a selection copies for this cell instead of its grapheme:
    /// `write_text`'s `copy_text`, as a 1-based index into the owning
    /// layer's `Layer.copy_texts` (0 = copy the grapheme). For a glyph
    /// drawn as something other than the text it stands for -- gw-read's
    /// vertical OCR panel draws 。 as its vertical form ︒, and Ctrl+Shift+C
    /// should still copy 。. An index rather than the bytes so every cell
    /// doesn't pay for a second grapheme buffer.
    copy_alt: u16 = 0,
    /// How a selection joins this cell's row to the next one when this
    /// is the row's last glyph -- see `LineJoin`. Set only by a write
    /// that asks for it, on the last glyph it draws; any other write over
    /// the cell resets it to `.newline`.
    line_join: LineJoin = .newline,
    style: Style = default_style,
    /// Sibling of `style.bg`, not part of it -- a cell can be tagged
    /// regardless of whether its background is a color/image/icon. Set (or
    /// cleared) as a whole by `write_text`/`draw_icon`'s optional
    /// `metadata_id` param, the same way those calls already overwrite
    /// `grapheme`/`style` outright rather than merging with whatever was
    /// there before.
    metadata_id: ?MetadataHandle = null,
    /// This cell is its span's *focus* cell: where `adjacentMetadataSpan`
    /// lands instead of the span's first visible character. A `gw-ls -l`
    /// row is one span across every column, so without this Ctrl+PgUp
    /// would stop on the permissions column; the Name column sets it so
    /// the cursor arrives on the first character of the filename.
    ///
    /// Only meaningful alongside `metadata_id` -- it names a cell *within*
    /// a span, not a span of its own. Cleared by every write that sets
    /// `metadata_id`, for the same "overwrite outright, don't merge"
    /// reason `grapheme`/`style` are; the callers that want it set it
    /// explicitly (`tag_metadata`'s `focus`, a `focus` table column).
    meta_focus: bool = false,
    /// An icon drawn *over* `style.bg` and `grapheme` rather than replacing
    /// either -- unlike the ordinary `draw_icon` (`style.bg`'s `.icon`
    /// variant), which is itself one of `Background`'s mutually exclusive
    /// cases and so necessarily replaces whatever background was there.
    /// Set by `Layer.drawIconOver` (`draw_icon`'s `foreground: true`),
    /// for content that needs to sit on top of an already-drawn cell
    /// background, which `draw_icon`'s normal background-replacing
    /// behavior would otherwise punch a flat hole through. (A nine-patch
    /// panel isn't one: it's drawn under the cells, so a plain icon's
    /// transparent pixels already show it.)
    fg_icon: ?IconBg = null,

    pub fn setGrapheme(self: *Cell, bytes: []const u8) void {
        std.debug.assert(bytes.len <= grapheme_inline_len);
        @memcpy(self.grapheme_bytes[0..bytes.len], bytes);
        self.grapheme_len = @intCast(bytes.len);
    }

    pub fn grapheme(self: *const Cell) []const u8 {
        return self.grapheme_bytes[0..self.grapheme_len];
    }
};

pub const Cursor = struct {
    row: usize = 0,
    col: usize = 0,
};

/// What DECSC (`ESC 7` / `CSI s`) saves and DECRC (`ESC 8` / `CSI u`)
/// restores: the cursor, plus the SGR pen and the G0/G1 charset state,
/// as VT100 specifies. A program that saves, draws a coloured status
/// line, and restores expects its own colour back with the cursor.
pub const SavedCursor = struct {
    cursor: Cursor,
    pen: SgrPen,
    shift_out: bool,
    g0_line_drawing: bool,
    g1_line_drawing: bool,
};

/// Where a viewport row index lands after a bottom-anchored resize that
/// changed the height by `dh` (new minus old). `Layer.resize` keeps every
/// retained row's distance from the *last* viewport row, so a row index
/// simply moves by the delta; the result is clamped into the new
/// viewport, since a shrink can push a row that was near the top out into
/// scrollback and a grow can't invent rows above zero. Shared by the
/// cursor and by anything else pinned to a row through a resize.
pub fn shiftRowByHeightDelta(row: usize, dh: i64, new_height: usize) usize {
    std.debug.assert(new_height > 0);
    const shifted = @as(i64, @intCast(row)) + dh;
    if (shifted <= 0) return 0;
    return @min(@as(usize, @intCast(shifted)), new_height - 1);
}

/// A layer's text selection and highlight set (`layer_selection.zig`):
/// the state lives in `Layer.sel`, the types are re-exported here.
pub const LayerSelection = @import("layer_selection.zig").LayerSelection;
pub const SelectionPoint = @import("layer_selection.zig").SelectionPoint;
pub const Selection = @import("layer_selection.zig").Selection;
pub const SelectUnit = @import("layer_selection.zig").SelectUnit;
pub const UnitSpan = @import("layer_selection.zig").UnitSpan;
pub const SelectionFlow = @import("layer_selection.zig").SelectionFlow;

/// A layer's viewport size in cells -- what `get_property(layer, "size")`
/// reports. For the root layer this is the context's base size, i.e. the
/// answer to "how big is the window right now" (see `Context.resize`).
pub const LayerSize = struct { cols: usize, rows: usize };

/// A layer's scrollback view state (see `PropertyName.scroll` and the
/// `scroll_view` wire method): `offset` rows of retained history are
/// currently shown above the live viewport, out of `max` (`history_len`)
/// retained in total. `offset == 0` is the live tail.
pub const LayerScroll = struct { offset: usize, max: usize };

/// Which way `Layer.adjacentMetadataSpan` walks: `.next` forward in
/// reading order (down / toward the live tail), `.prev` backward (up
/// into scrollback).
pub const MetadataSpanDir = enum { next, prev };

/// Where `Layer.adjacentMetadataSpan` landed: the first visible character
/// of the neighbouring metadata-id span. `above` is in the scroll-stable
/// coordinate `SelectionPoint.above` documents (positive counts up into
/// retained scrollback, zero or negative is inside the live viewport).
pub const MetadataSpanHit = struct { above: i64, col: usize, id: MetadataHandle };

/// How much of a layer's content grid the host actually draws -- see
/// `PropertyName.viewport`. Zero on an axis means "all of it", which is
/// every layer that existed before viewports did.
pub const Viewport = struct { cols: usize, rows: usize };

/// Which scrollbars glyphwire-host draws for a layer, and how far each
/// one can travel. `max_row`/`max_col` are derived (content minus
/// viewport) rather than set, so a client can't put the thumb somewhere
/// the content doesn't go.
pub const ScrollbarState = struct {
    vertical: bool,
    horizontal: bool,
    row: usize,
    col: usize,
    max_row: usize,
    max_col: usize,
};

/// Opt-in per axis -- see `PropertyName.scrollbars`.
pub const Scrollbars = struct { vertical: bool = false, horizontal: bool = false };

pub const PropertyName = enum {
    cursor,
    /// Bumped once per `writeText` call; a cheap poll a renderer client can
    /// use to decide whether it's worth fetching the (much larger) full
    /// cell grid again this frame. Get-only: `Layer.setProperty` traps if
    /// asked to set it.
    revision,
    /// Pixel-precise position relative to the layer's parent (the root
    /// layer for every layer `create_layer` makes today -- see
    /// decisions.md's Layer section on why position stays pixel-precise
    /// rather than cell-snapped: smooth animation, e.g. sliding a
    /// notification layer on/off screen, needs sub-cell steps).
    position,
    /// The same placement as `position`, but expressed in whole grid
    /// cells (`{row, col}`) and resolved against the session's cell
    /// metrics (`Context.cell_px_w`/`cell_px_h`). A TUI lays itself out
    /// on the cell grid, and a layer placed this way stays laid out: the
    /// context re-derives its pixel `pos` whenever the cell metrics
    /// change (`Context.setCellMetrics`), so a sidebar stays snapped to
    /// column 0 across a font-size change instead of drifting. Setting
    /// `position` in pixels un-sticks it again -- pixel placement is the
    /// primitive, this is the sticky convenience on top. Goes through
    /// `Context.setLayerProperty`/`getLayerProperty`, not `Layer`'s own
    /// pair, since only the context knows the metrics.
    cell_position,
    /// Viewport size in cells (`{cols, rows}`). Settable on a
    /// `create_layer` layer -- a TUI that splits the window into a
    /// sidebar and a buffer pane has to reflow both on a `resize`
    /// notification, and destroying and recreating the layers would throw
    /// away their handles, tables and content. Get-only for the **root**
    /// layer, whose size the host owns (see `Context.resize`); an attempt
    /// reports `PropertyError.ReadOnlyProperty`. Setting it also clears
    /// `Layer.tracks_context_size` -- a client that picks its own size
    /// has taken over the layout. Goes through
    /// `Context.setLayerProperty`, which owns the root check and the
    /// reallocation.
    size,
    /// Scrollback view offset in rows (`{offset, max}`) -- how far the
    /// on-screen view is scrolled back into this layer's history (0 is
    /// the live tail), out of `history_len` retained. Get-only through
    /// `get_property`: a client changes it with the `scroll_view` request
    /// instead (which clamps and broadcasts a `scroll` notification),
    /// mirroring how `size` is read-only here and only moved by the
    /// host-driven resize path. See `Layer.view_scroll` / `Layer.scrollView`.
    scroll,
    /// Whether glyphwire-host composites this layer at all
    /// (`{visible: bool}`). A hidden layer keeps every cell, table and
    /// handle it had; the renderer just skips it. That's what a toggled
    /// sidebar wants -- `destroy_layer` plus a rebuild loses the tree's
    /// scroll position and its metadata ids for nothing. Settable on a
    /// `create_layer` layer only: hiding the **root** layer would blank
    /// the session with no wire path back, the same reason
    /// `destroy_layer` refuses it, so root reports
    /// `PropertyError.ReadOnlyProperty`.
    visibility,
    /// How opaque glyphwire-host composites this layer, 0.0..1.0
    /// (`{value: f32}`, default 1.0). The factor multiplies the alpha of
    /// every quad the layer contributes -- background fills, text, icons
    /// and image cells alike -- so the whole layer fades as one and
    /// whatever is behind it shows through.
    ///
    /// Distinct from `visibility`, which is the all-or-nothing form: a
    /// hidden layer contributes no quads at all, while a layer at 0.5
    /// still occupies its bounds and still takes the mouse. That's the
    /// difference `gw-read` wants between "get this dialog out of the
    /// way" and "let me see the artwork through it".
    ///
    /// Root reports `PropertyError.ReadOnlyProperty`, the same reason
    /// `visibility` does: fading the root layer to 0 would blank the
    /// session with no wire path back. Out-of-range values are clamped
    /// rather than rejected -- see `Layer.opacity`.
    opacity,
    /// The window of this layer's **content grid** that glyphwire-host
    /// draws, in cells (`{cols, rows}`). Zero on an axis means the whole
    /// content grid on that axis -- the default, and what every layer did
    /// before this existed, so the concept costs nothing until a client
    /// asks for it.
    ///
    /// This is what makes a pane distinct from its content: a file tree
    /// with 500 entries and a longest name of 90 columns is a 90x500
    /// layer (`size`) shown through a 30x40 viewport, and the host scrolls
    /// the window over it. The alternative -- the client redrawing 40 rows
    /// on every scroll tick -- puts a wire round trip in the middle of a
    /// mouse wheel.
    ///
    /// A viewport larger than the content is clamped to the content, so
    /// there is no way to scroll into blank space.
    viewport,
    /// Where the `viewport` sits within the content grid (`{row, col}`),
    /// clamped to `size - viewport` on each axis. This is the layer's
    /// scroll position, and the host moves it directly on a wheel tick or
    /// a scrollbar drag (broadcasting `scroll_offset`) rather than asking
    /// the client to.
    ///
    /// Distinct from `scroll`, which is the *scrollback ring* view --
    /// how far back into a terminal-style history the live viewport is
    /// looking. The two compose: `scroll` picks which rows are live,
    /// `scroll_offset` picks the window over them. A layer created with
    /// `scrollback_rows: 0` (every pane in a TUI) only ever uses this one.
    scroll_offset,
    /// Which scrollbars the host draws inside this layer's bounds
    /// (`{vertical, horizontal}`), opt-in per axis. Get returns the full
    /// `ScrollbarState` -- the two flags plus the current offset and its
    /// maximum on each axis, which is everything needed to draw or
    /// interpret a bar.
    ///
    /// Opt-in rather than automatic: a statusline or a popup can easily
    /// have content wider than its pane and should still not sprout a
    /// scrollbar.
    scrollbars,
    /// A "virtual" content size in cells (`{cols, rows}`) for a pane that
    /// scrolls *itself*: a TUI editor's buffer, whose real cell grid is
    /// only viewport-sized (a full grid for a large file would be
    /// hundreds of megabytes) so it redraws on every scroll rather than
    /// letting the host slide a viewport. Setting this tells the host how
    /// big the whole content really is, so it can draw a proportional
    /// scrollbar and turn a wheel / thumb drag over the pane into a
    /// `scroll_offset` the client then obeys and redraws against —
    /// `scroll_offset` on such a layer moves this virtual position, not
    /// the real (unmoving) grid. `{0, 0}` clears it back to an ordinary
    /// host-scrolled pane. Get reports the effective content size (the
    /// virtual one if set, else the real grid).
    content_extent,
    /// Which of the two viewport scroll models this layer uses
    /// (`{mode: "host" | "client"}`, default `"host"`):
    ///
    /// - `host`: the content grid is the whole content, and the host
    ///   slides the `viewport` over it (`scroll_offset` moves the real
    ///   grid window). `content_extent` is refused (`WrongScrollMode`).
    /// - `client`: the client redraws its visible rows itself and tells
    ///   the host the virtual size with `content_extent`; `scroll_offset`
    ///   is a virtual position the host only reports, the real grid never
    ///   moves.
    ///
    /// Both are separate from the root layer's terminal *scrollback*
    /// (`scroll` / `scroll_view` / `view_offset`), which is a ring buffer
    /// of rows that scrolled off the top, not a viewport. The model used
    /// to be implied by whether `content_extent` was set, which let a
    /// client flip a picture layer into the virtual model by accident; it
    /// is explicit now, and switching it resets the scroll position.
    scroll_mode,
    /// The colour an unwritten (transparent-background) cell composites
    /// as (`{color: {r, g, b, a}}`, or no `color` for none -- the
    /// default, where such cells show whatever is behind the layer).
    /// Painted under every cell of the layer's viewport, so rows past the
    /// end of a list stay opaque without the client writing padding.
    background,
    /// Whether this layer keeps its escape-sequence / charset / SGR-pen
    /// state across `write_text` calls instead of resetting it at each
    /// call boundary (`{enabled: bool}`, default off). See
    /// `Layer.pty_mode`: a pane fed one PTY child's byte stream wants it
    /// on so a sequence split across `read()` chunks still parses as one.
    /// Setting it -- to either value -- also clears that transient state,
    /// so it doubles as the "a foreground program just exited" re-arm.
    pty_mode,
    /// Whether glyphwire-host may start one of its own mouse text
    /// selections on this layer (`{enabled: bool}`, default off). See
    /// `Layer.mouse_select`.
    mouse_select,
    /// Whether the program drawing on this layer has asked for mouse
    /// events (`{enabled: bool}`, default off). See `Layer.mouse_report`.
    mouse_report,
    /// A soft drop shadow the host draws under the layer's bounds
    /// (`{shadow: {x, y, blur, radius, spread, color}}`, or no `shadow`
    /// for none -- the default). See `Shadow`.
    shadow,
    /// Which way a selection on this layer reads (`{mode, cols, col}`,
    /// default `horizontal`). See `SelectionFlow`.
    selection_flow,
    /// Which edge of a floating layer the host lets the user drag to
    /// resize it (`{edge: "top" | "bottom" | "left" | "right" | "none"}`,
    /// default `none`). See `ResizeEdge`.
    resize_edge,
};

/// A floating layer's draggable edge (`PropertyName.resize_edge`).
///
/// Split dividers already resize the layers *in* a split tree, but a
/// layer that floats over one -- the Ctrl+` shell panel docked along an
/// edge of zoe or salacommander -- has no divider: nothing sits on its
/// other side. This gives it one. The host draws a thin band along that edge,
/// hit-tests it ahead of the layer's own cells, and drags it with the
/// same ghost preview a split divider gets.
///
/// The host does **not** resize the layer itself. When the drag ends it
/// sends a `layer_resize` notification with the size the user asked for,
/// and the client applies (and clamps, and remembers) it: a floating
/// layer's placement is the client's arithmetic, redone on every window
/// resize, and only the client knows what has to stay visible around it.
///
/// The edge named is the one that moves: a panel docked to the bottom of
/// the window drags its `top`, one docked to the left its `right`. `top`
/// and `bottom` change the layer's height, `left` and `right` its width.
pub const ResizeEdge = enum {
    none,
    top,
    bottom,
    left,
    right,

    /// Whether dragging this edge changes the layer's width (as opposed
    /// to its height).
    pub fn horizontal(self: ResizeEdge) bool {
        return self == .left or self == .right;
    }
};

/// A layer's drop shadow (`PropertyName.shadow`): a rounded rect the size
/// of the layer's visible bounds, moved by `x`/`y`, grown on every side by
/// `spread` (negative shrinks it), with corner `radius`, blurred by
/// `blur` -- all in pixels -- and filled with `color` (its alpha is the
/// shadow's darkest point). Drawn by the host directly under the layer, so
/// it darkens whatever the layers beneath show and nothing of the layer's
/// own; it is not part of the layer's bounds, so it never takes a click.
///
/// The shape follows the layer's rectangle, not its pixels: set `radius`
/// to the corner radius of a nine-patch panel the layer draws, and a
/// negative `spread` if the panel doesn't reach the layer's edge. See
/// docs/api.md's Shadow section for why this isn't cast from the layer's
/// real alpha.
pub const Shadow = struct {
    x: i32 = 0,
    y: i32 = 0,
    blur: u32 = 0,
    radius: u32 = 0,
    spread: i32 = 0,
    color: Color = .{ .r = 0, .g = 0, .b = 0, .a = 128 },

    /// The largest `blur` / `radius` the host honours; anything bigger is
    /// clamped to it on the way in. They size a texture the host builds
    /// per distinct shadow (`2 * (radius + 2 * blur)` pixels across), so
    /// an unbounded value would be an unbounded allocation.
    pub const max_blur: u32 = 64;
    pub const max_radius: u32 = 64;

    /// The shadow glyphwire's own programs give a floating dialog, so
    /// zoe's popups, salacommander's questions, gw-read's panels and the
    /// notify toast all stand off the screen the same way. Dropped more
    /// than it's pushed sideways, as if lit from slightly above; `radius`
    /// matches the bundled `panel`/`dialog` nine-patches' corners.
    pub const dialog: Shadow = .{
        .x = 4,
        .y = 16,
        .blur = 18,
        .radius = 6,
        .color = .{ .r = 0, .g = 0, .b = 0, .a = 190 },
    };

    pub fn clamped(self: Shadow) Shadow {
        var out = self;
        out.blur = @min(self.blur, max_blur);
        out.radius = @min(self.radius, max_radius);
        return out;
    }
};

pub const PropertyValue = union(PropertyName) {
    cursor: Cursor,
    revision: u64,
    position: PxPos,
    cell_position: CellPos,
    size: LayerSize,
    scroll: LayerScroll,
    visibility: bool,
    opacity: f32,
    viewport: Viewport,
    scroll_offset: CellPos,
    scrollbars: ScrollbarState,
    content_extent: Viewport,
    scroll_mode: ScrollMode,
    background: ?Color,
    pty_mode: bool,
    mouse_select: bool,
    mouse_report: bool,
    shadow: ?Shadow,
    selection_flow: SelectionFlow,
    resize_edge: ResizeEdge,
};

/// See `PropertyName.scroll_mode`.
pub const ScrollMode = enum { host, client };

pub const PropertyError = error{
    UnknownProperty,
    /// The property exists but this layer won't accept a write to it --
    /// `size`, `visibility` and `opacity` on the root layer, whose
    /// geometry and compositing the host owns. See each one's doc
    /// comment above.
    ReadOnlyProperty,
    /// `content_extent` set on a layer whose `scroll_mode` is `host`. See
    /// `PropertyName.scroll_mode`.
    WrongScrollMode,
};

/// A server-generated handle for a layer created via `create_layer`.
/// `root_layer_handle` (0) always refers to the context's root layer,
/// which always exists and isn't itself stored in `Context.layers` --
/// every other handle (1, 2, ...) is a `Context.layers` entry.
pub const LayerHandle = u32;
pub const root_layer_handle: LayerHandle = 0;

/// Identity of one accepted socket connection, assigned by `server.zig` at
/// `accept` time (a plain incrementing counter -- see `Server.next_conn_id`).
/// Used only for layer ownership: `create_layer` records the creating
/// connection's id as the layer's first owner, `adopt_layer` adds more,
/// and when a connection closes every layer it solely owned is culled (see
/// `Context.removeConnectionOwnership`). A reconnecting client gets a fresh
/// id and owns nothing from its previous connection -- deliberately, per
/// decisions.md's "auto-restore-on-disconnect is a fresh identity"
/// precedent. In-process callers (glyphwire-host driving the `Context`
/// directly, the headless `server/main.zig`, tests) have no connection and
/// pass no id: layers they create are never connection-owned and never
/// auto-culled.
pub const ConnId = u64;

/// The secret that lets a connection act on a context it didn't create:
/// 16 random bytes as 32 lowercase hex characters, so it travels as a
/// plain string on either wire encoding and in an environment variable
/// (`GLYPHWIRE_TOKEN`). Every context gets one at `Context.init`. A
/// context handle is a small counter anyone can guess; the token is what
/// `attach_context` / `attach_pane` / `subscribe` check before a
/// connection may read, draw on or take input for a context (see
/// `Session.grantContext`).
pub const AccessToken = [32]u8;

/// A fresh `AccessToken` from the kernel's CSPRNG. `getrandom` without
/// flags blocks only until the pool is first seeded, which has long
/// happened by the time anything opens a window; a short read is retried.
pub fn newAccessToken() AccessToken {
    var raw: [16]u8 = undefined;
    var filled: usize = 0;
    while (filled < raw.len) {
        const rc = std.os.linux.getrandom(raw[filled..].ptr, raw.len - filled, 0);
        if (std.os.linux.errno(rc) != .SUCCESS) continue;
        filled += rc;
    }
    return std.fmt.bytesToHex(raw, .lower);
}

/// Whether `given` is `want`, in time independent of where they differ,
/// so a client probing tokens learns nothing from how fast it is refused.
/// Anything that isn't exactly `AccessToken`'s length is simply wrong.
pub fn accessTokenMatches(want: *const AccessToken, given: []const u8) bool {
    if (given.len != want.len) return false;
    return std.crypto.timing_safe.eql(AccessToken, want.*, given[0..want.len].*);
}

/// A context and the token that lets a connection act on it: what
/// `create_context` hands back, and what glyphwire-host passes along to a
/// program it starts there (`GLYPHWIRE_CTX` / `GLYPHWIRE_TOKEN`).
pub const ContextGrant = struct {
    context: ContextHandle,
    token: AccessToken,
};

pub const LayerError = error{UnknownLayer};

/// Columns between horizontal tab stops for `\t` handling in
/// `Layer.writeText` (see `vt.consumeControl`). Fixed 8, the universal
/// terminal default; not yet a per-layer or per-session setting.
pub const tab_width: usize = 8;

/// A layer's cell grid: `layer.zig`.
pub const Layer = @import("layer.zig").Layer;

// ─── Rect ────────────────────────────────────────────────────────────────
//
// A pixel-space overlay box on a layer (`Layer.rects`). See `rect.zig`.
pub const RectHandle = @import("rect.zig").RectHandle;
pub const RectError = @import("rect.zig").RectError;
pub const Rect = @import("rect.zig").Rect;
pub const RectUpdate = @import("rect.zig").RectUpdate;

// ─── Drop target ────────────────────────────────────────────────────────
//
// The highlight a drag-and-drop shows over where it would land: a whole
// pane, a block of cells in it, or the slot between two tabs. The host
// never sees the drag itself -- a client tracks the button and pointer,
// works out the target and says so with `set_drop_target` -- so this is
// presentation only, like `Rect`. What it adds over a client drawing its
// own rect is consistency: every program's drop target is the theme's
// `drop_target` colour at `host.conf.lua`'s `drop_target_opacity`, in
// cell coordinates with no pixel arithmetic on the client's side.

pub const DropTarget = union(enum) {
    /// The layer's whole visible area: "drop here" with no finer place.
    layer,
    /// `rows` x `cols` content cells from `(row, col)`.
    cells: struct { row: usize, col: usize, rows: usize, cols: usize },
    /// An insertion marker: a bar a couple of pixels wide on the left
    /// edge of content column `col`, spanning `rows` rows from `row`.
    /// Where a tab dropped on a tab strip would go. `col` may be one past
    /// the last column for "at the end".
    insert: struct { row: usize, col: usize, rows: usize },
};

// ─── Nine-patch ─────────────────────────────────────────────────────────
//
// A `.9.png` panel background on a layer (`Layer.nine_patches`). See
// `nine_patch.zig`.
pub const NinePatchHandle = @import("nine_patch.zig").NinePatchHandle;
pub const NinePatchError = @import("nine_patch.zig").NinePatchError;
pub const NinePatchParseError = @import("nine_patch.zig").NinePatchParseError;
pub const NinePatchInsets = @import("nine_patch.zig").NinePatchInsets;
pub const NinePatchStyle = @import("nine_patch.zig").NinePatchStyle;
pub const parseNinePatch = @import("nine_patch.zig").parseNinePatch;
pub const NinePatch = @import("nine_patch.zig").NinePatch;
pub const NinePatchUpdate = @import("nine_patch.zig").NinePatchUpdate;
pub const NinePatchQuad = @import("nine_patch.zig").NinePatchQuad;
pub const ninePatchQuads = @import("nine_patch.zig").ninePatchQuads;

// ─── Table ───────────────────────────────────────────────────────────────
//
// Server-owned tabular data compiled into a layer's cells (`Layer.tables`).
// See `table.zig`.
pub const TableHandle = @import("table.zig").TableHandle;
pub const TableError = @import("table.zig").TableError;
pub const ColumnKind = @import("table.zig").ColumnKind;
pub const TableOverflow = @import("table.zig").TableOverflow;
pub const SortDirection = @import("table.zig").SortDirection;
pub const sortArrowGlyph = @import("table.zig").sortArrowGlyph;
pub const TableColumn = @import("table.zig").TableColumn;
pub const SortKey = @import("table.zig").SortKey;
pub const TableCell = @import("table.zig").TableCell;
pub const CellRun = @import("table.zig").CellRun;
pub const TableRow = @import("table.zig").TableRow;
pub const TableStyle = @import("table.zig").TableStyle;
pub const Table = @import("table.zig").Table;

// ─── Outline ───────────────────────────────────────────────────────────
//
// A collapsible tree of text rows on a layer (`Layer.outlines`). See
// `outline.zig`.
pub const OutlineHandle = @import("outline.zig").OutlineHandle;
pub const OutlineError = @import("outline.zig").OutlineError;
pub const outline_marker_cols = @import("outline.zig").outline_marker_cols;
pub const OutlineNode = @import("outline.zig").OutlineNode;
pub const OutlineNodes = @import("outline.zig").OutlineNodes;
pub const OutlineStyle = @import("outline.zig").OutlineStyle;
pub const Outline = @import("outline.zig").Outline;

/// Pixel-space cursor position (framebuffer pixels, as glyphwire-host
/// reports it).
pub const PxPos = struct { x: f32 = 0, y: f32 = 0 };

/// Cell-grid cursor position, derived from `PxPos` and the cell pixel
/// size -- see decisions.md's Cell/Layer sections. Whoever reports it
/// (glyphwire-host, which owns the font/cell metrics) computes this, not
/// the headless server -- see `InputState`'s doc comment.
pub const CellPos = struct {
    row: usize = 0,
    col: usize = 0,

    /// A signed cell offset -- what a wheel tick or an arrow key applies
    /// to a scroll position. Separate from `CellPos` because a position
    /// can't be negative but a movement can.
    pub const Delta = struct { row: i64 = 0, col: i64 = 0 };
};

/// Turns a stream of button presses into `mouse_button`'s `clicks` count:
/// 1 for a single click, 2 for a double, 3 for a triple. A press counts
/// on from the previous one when it is the same button, within `slop_px`
/// of it on both axes, and within `interval_ms` of it; anything else
/// starts over at 1. Past a triple the count wraps back to 1, so a fourth
/// quick click is a fresh single click rather than an ever-growing number
/// no client acts on.
///
/// Distance in pixels rather than "the same cell": a hand that wobbles a
/// pixel across a cell border is still double-clicking, the way every
/// desktop toolkit measures it.
///
/// The host owns the one counter, so every client sees the same count
/// for the same gesture instead of each timing clicks its own way. Pure
/// logic: the caller passes the clock in.
pub const ClickCounter = struct {
    /// Longest gap between two presses that still chain. 400ms is within
    /// the common desktop defaults (GTK 400, Windows 500).
    interval_ms: i64 = 400,
    /// How far apart two chained presses may land, per axis.
    slop_px: f32 = 4,
    count: u8 = 0,
    last_ms: i64 = 0,
    last_button: u8 = 0,
    last_px: PxPos = .{},

    /// Records a press of `button` (any stable small id) at `px` at
    /// `now_ms` and returns its click count.
    pub fn press(self: *ClickCounter, button: u8, px: PxPos, now_ms: i64) u8 {
        const chains = self.count != 0 and
            button == self.last_button and
            @abs(px.x - self.last_px.x) <= self.slop_px and
            @abs(px.y - self.last_px.y) <= self.slop_px and
            now_ms - self.last_ms <= self.interval_ms;
        self.count = if (chains and self.count < 3) self.count + 1 else 1;
        self.last_ms = now_ms;
        self.last_button = button;
        self.last_px = px;
        return self.count;
    }
};

/// Authoritative input state for a session: which keys/mouse buttons are
/// currently down. Lives on `Session`, not on any one `Context`: there is
/// one keyboard and one mouse, and a release has to clear the same set
/// its press went into even when focus moved in between. It used to be
/// per-context, and a press that launched a full-screen program (Enter on
/// `gwmd README.md`) had its release land in the *new* context's set --
/// the shell's set still had the key down when focus came back, so the
/// next press there was dropped as a redundant press-while-down. Same
/// reasoning as `Session.mods`. The pointer position, which *is*
/// per-context (it's in that context's cell frame), is `PointerState`.
///
/// Pure logic, no I/O, headless-testable like everything else in this
/// file: the actual capture happens in glyphwire-host, which reports
/// changes here as `report_key`/`report_mouse_button` notifications (see
/// dispatch.zig, or `Server`'s in-process equivalents for a caller that
/// owns the session directly) rather than this type knowing anything
/// about how input was captured.
///
/// Key/button names are whatever string the reporter used (glyphwire-host
/// uses `@tagName` of its engine's key/button enums, e.g. "a",
/// "left_shift", "left") -- not a closed set enforced here.
pub const InputState = struct {
    alloc: std.mem.Allocator,
    keys_down: std.StringHashMap(void),
    mouse_buttons_down: std.StringHashMap(void),

    pub fn init(alloc: std.mem.Allocator) InputState {
        return .{
            .alloc = alloc,
            .keys_down = std.StringHashMap(void).init(alloc),
            .mouse_buttons_down = std.StringHashMap(void).init(alloc),
        };
    }

    pub fn deinit(self: *InputState) void {
        freeStringSet(self.alloc, &self.keys_down);
        freeStringSet(self.alloc, &self.mouse_buttons_down);
    }

    fn freeStringSet(alloc: std.mem.Allocator, set: *std.StringHashMap(void)) void {
        var it = set.keyIterator();
        while (it.next()) |k| alloc.free(k.*);
        set.deinit();
    }

    /// Records a key press/release. Returns true if this actually changed
    /// the down-set (false for a redundant press-while-down or
    /// release-while-up report), so callers can skip broadcasting a
    /// no-op change.
    pub fn setKey(self: *InputState, key: []const u8, down: bool) !bool {
        return setInSet(self.alloc, &self.keys_down, key, down);
    }

    pub fn setMouseButton(self: *InputState, button: []const u8, down: bool) !bool {
        return setInSet(self.alloc, &self.mouse_buttons_down, button, down);
    }

    fn setInSet(alloc: std.mem.Allocator, set: *std.StringHashMap(void), name: []const u8, down: bool) !bool {
        if (down) {
            if (set.contains(name)) return false;
            const owned = try alloc.dupe(u8, name);
            errdefer alloc.free(owned);
            try set.put(owned, {});
            return true;
        } else {
            if (set.fetchRemove(name)) |kv| {
                alloc.free(kv.key);
                return true;
            }
            return false;
        }
    }

    pub fn isKeyDown(self: *const InputState, key: []const u8) bool {
        return self.keys_down.contains(key);
    }

    pub fn isMouseButtonDown(self: *const InputState, button: []const u8) bool {
        return self.mouse_buttons_down.contains(button);
    }
};

/// The last pointer position reported against a context, in that
/// context's own coordinate frame -- what `get_input_state`'s
/// `cursor_px` / `cursor_cell` return. Kept per-context, unlike the
/// down-sets in `InputState`, because a cell position only means
/// something relative to the context it was reported against.
pub const PointerState = struct {
    cursor_px: PxPos = .{},
    cursor_cell: CellPos = .{},
};

/// String id the host/shell put in `GLYPHWIRE_CTX` for a connecting
/// client to inherit -- the wire-level discovery half of the multi-context
/// model is still deferred (a connection just inherits whichever context
/// is visible at connect time; see `Session`), so this stays an
/// out-of-band sentinel. It names the root context (`root_context_handle`).
pub const default_context_id = "0";

/// Derives an icon's catalog name from its path under the bundled
/// `assets/icons/` directory: just the path with a trailing `.png`
/// extension removed (case-insensitive on the extension). So
/// `oxygen/folder.png` -> `oxygen/folder`, `box/tl.png` -> `box/tl`,
/// `status/error.png` -> `status/error`. Returns null for anything that
/// isn't a `.png` (the tree also carries `README.txt` / license files),
/// so the caller can skip it.
///
/// This is the whole naming convention: `glyphwire-host` recursively
/// walks `assets/icons/` at startup and registers every `.png` under the
/// name this returns (see `host/main.zig`'s `loadIconsFromDir`). There's
/// no hand-maintained manifest -- dropping a file into a subdirectory is
/// all it takes to add an icon. The bundled subtrees are `oxygen/`
/// (KDE Oxygen file-type art), `dev/` (Devicon language / tool logos, plus
/// the LobeHub Claude marks -- used by `glyphwire-ls`), `distro/` (Devicon
/// distro logos, for prompts), `notify/` (`glyphwire-notify` type icons),
/// `status/` (prompt status
/// glyphs), and `box/` (the table border tiles -- `TableStyle.box_style`
/// is the subdirectory name, so its pieces resolve as `box/tl` and so
/// on). Panel backgrounds are nine-patches instead, loaded from
/// `assets/ninepatch/` -- see `parseNinePatch`.
pub fn iconName(rel_path: []const u8) ?[]const u8 {
    if (!std.ascii.endsWithIgnoreCase(rel_path, ".png")) return null;
    return rel_path[0 .. rel_path.len - ".png".len];
}

// ─── Contexts ───────────────────────────────────────────────────────────
//
// A program's screen: its layers, their split tree, images and input
// state. See `context.zig`.
pub const SplitHandle = @import("context.zig").SplitHandle;
pub const SplitError = @import("context.zig").SplitError;
pub const SplitAxis = @import("context.zig").SplitAxis;
pub const CellRect = @import("context.zig").CellRect;
pub const SplitChild = @import("context.zig").SplitChild;
pub const Split = @import("context.zig").Split;
pub const LayerBounds = @import("context.zig").LayerBounds;
pub const DividerRect = @import("context.zig").DividerRect;
pub const max_split_depth = @import("context.zig").max_split_depth;
pub const min_pane_cells = @import("context.zig").min_pane_cells;
pub const KeyRepeat = @import("context.zig").KeyRepeat;
pub const CaretShape = @import("context.zig").CaretShape;
pub const Context = @import("context.zig").Context;

// ─── Sessions and panes ─────────────────────────────────────────────────
//
// The session that owns every context, and the panes that divide the
// window between them. See `session.zig`.
pub const ContextHandle = @import("session.zig").ContextHandle;
pub const root_context_handle = @import("session.zig").root_context_handle;
pub const ContextError = @import("session.zig").ContextError;
pub const ProfilePhase = @import("session.zig").ProfilePhase;
pub const ProfileCount = @import("session.zig").ProfileCount;
pub const profile_max_phases = @import("session.zig").profile_max_phases;
pub const profile_max_counters = @import("session.zig").profile_max_counters;
pub const ProfileSnapshot = @import("session.zig").ProfileSnapshot;
pub const PaneHandle = @import("session.zig").PaneHandle;
pub const root_pane_handle = @import("session.zig").root_pane_handle;
pub const PaneError = @import("session.zig").PaneError;
pub const PaneSplitHandle = @import("session.zig").PaneSplitHandle;
pub const PaneSplitError = @import("session.zig").PaneSplitError;
pub const PaneSplitChild = @import("session.zig").PaneSplitChild;
pub const PaneSplit = @import("session.zig").PaneSplit;
pub const PaneDividerRect = @import("session.zig").PaneDividerRect;
pub const PaneBounds = @import("session.zig").PaneBounds;
pub const max_pane_split_depth = @import("session.zig").max_pane_split_depth;
pub const min_pane_extent = @import("session.zig").min_pane_extent;
pub const Pane = @import("session.zig").Pane;
pub const WindowPrefix = @import("session.zig").WindowPrefix;
pub const max_managers = @import("session.zig").max_managers;
pub const Session = @import("session.zig").Session;
