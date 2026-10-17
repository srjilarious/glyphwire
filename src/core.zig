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

pub const ImageInfo = struct {
    width: u32,
    height: u32,
};

/// The container formats `load_image` accepts. The headless core never
/// decodes pixels -- it only measures each one's natural width/height from
/// a fixed-offset header read (`imageDimensions`) -- but it still needs to
/// know which header shape to read, so the wire `format` field is now
/// parsed (`fromName`) rather than "accepted but unchecked". Full pixel
/// decoding stays the renderer's job (glyphwire-host's zstbi/stb_image,
/// which auto-detects all four from the same bytes).
pub const ImageFormat = enum {
    png,
    jpeg,
    bmp,
    gif,

    /// Maps a wire `format` string to a variant, or null for a format the
    /// core can't measure. Accepts `"jpg"` as an alias for `jpeg`;
    /// otherwise the canonical lowercase name clients send.
    pub fn fromName(name_str: []const u8) ?ImageFormat {
        if (std.mem.eql(u8, name_str, "png")) return .png;
        if (std.mem.eql(u8, name_str, "jpeg") or std.mem.eql(u8, name_str, "jpg")) return .jpeg;
        if (std.mem.eql(u8, name_str, "bmp")) return .bmp;
        if (std.mem.eql(u8, name_str, "gif")) return .gif;
        return null;
    }

    /// The canonical wire name (always `"jpeg"`, never `"jpg"`).
    pub fn name(self: ImageFormat) []const u8 {
        return switch (self) {
            .png => "png",
            .jpeg => "jpeg",
            .bmp => "bmp",
            .gif => "gif",
        };
    }

    /// Maps an image `mimetype` (the form `glyphwire-ls` tags entries
    /// with) to a variant, or null for an image type this can't
    /// measure/display -- `image/svg+xml`, `image/webp`. Lets a client
    /// (glyphwire-shell's click-to-view) decide "is this something
    /// glyphwire-view can open?" without keeping its own list. `image/jpg`
    /// is accepted alongside the correct `image/jpeg`.
    pub fn fromMimetype(mime: []const u8) ?ImageFormat {
        if (std.mem.eql(u8, mime, "image/png")) return .png;
        if (std.mem.eql(u8, mime, "image/jpeg") or std.mem.eql(u8, mime, "image/jpg")) return .jpeg;
        if (std.mem.eql(u8, mime, "image/bmp")) return .bmp;
        if (std.mem.eql(u8, mime, "image/gif")) return .gif;
        return null;
    }
};

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

pub const ImageError = error{
    InvalidPng,
    InvalidJpeg,
    InvalidBmp,
    InvalidGif,
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

/// Sniffs a container format from an image's leading magic bytes -- enough
/// for a client to fill `load_image`'s `format` field from the file
/// contents rather than trusting its extension. Null for bytes matching
/// none of the four formats the core can measure.
pub fn detectImageFormat(bytes: []const u8) ?ImageFormat {
    if (bytes.len >= 8 and std.mem.eql(u8, bytes[0..8], &[_]u8{ 0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n' }))
        return .png;
    if (bytes.len >= 3 and bytes[0] == 0xFF and bytes[1] == 0xD8 and bytes[2] == 0xFF)
        return .jpeg;
    if (bytes.len >= 2 and bytes[0] == 'B' and bytes[1] == 'M')
        return .bmp;
    if (bytes.len >= 6 and (std.mem.eql(u8, bytes[0..6], "GIF87a") or std.mem.eql(u8, bytes[0..6], "GIF89a")))
        return .gif;
    return null;
}

/// Natural pixel dimensions of an image, read from `format`'s header
/// without decoding pixels. A byte stream that doesn't actually match the
/// declared `format` fails here -- that's how a wrong `load_image` hint
/// surfaces (see `Context.loadImage`).
pub fn imageDimensions(format: ImageFormat, bytes: []const u8) ImageError!ImageInfo {
    return switch (format) {
        .png => pngDimensions(bytes),
        .jpeg => jpegDimensions(bytes),
        .bmp => bmpDimensions(bytes),
        .gif => gifDimensions(bytes),
    };
}

/// Parses just the IHDR chunk's width/height from a PNG byte stream -- not
/// a decoder. Per the PNG spec, the 8-byte signature is always followed
/// immediately by the IHDR chunk (4-byte length, 4-byte "IHDR" tag, then
/// big-endian u32 width and height), so this is a fixed-offset read, not a
/// real parse.
pub fn pngDimensions(bytes: []const u8) ImageError!ImageInfo {
    const sig = [_]u8{ 0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n' };
    if (bytes.len < 24 or !std.mem.eql(u8, bytes[0..8], &sig)) return ImageError.InvalidPng;
    if (!std.mem.eql(u8, bytes[12..16], "IHDR")) return ImageError.InvalidPng;
    return .{
        .width = std.mem.readInt(u32, bytes[16..20], .big),
        .height = std.mem.readInt(u32, bytes[20..24], .big),
    };
}

/// Walks a JPEG's marker segments looking for the frame header (SOFn) and
/// reads its 16-bit height/width -- not a decoder. After the `FF D8` start
/// marker, JPEG is a sequence of `FF <marker>` segments, each (bar a
/// handful of standalone markers) carrying a big-endian 2-byte length that
/// covers itself. The first SOFn segment (`FF C0`-`FF CF`, excluding the
/// non-frame `C4`/`C8`/`CC`) holds `precision(1) height(2) width(2)`.
pub fn jpegDimensions(bytes: []const u8) ImageError!ImageInfo {
    if (bytes.len < 4 or bytes[0] != 0xFF or bytes[1] != 0xD8) return ImageError.InvalidJpeg;
    var i: usize = 2;
    while (i + 4 <= bytes.len) {
        if (bytes[i] != 0xFF) {
            i += 1;
            continue;
        }
        // A run of 0xFF bytes before the marker id is legal fill.
        var marker = bytes[i + 1];
        while (marker == 0xFF) {
            i += 1;
            if (i + 1 >= bytes.len) return ImageError.InvalidJpeg;
            marker = bytes[i + 1];
        }
        i += 2;
        // Standalone markers (no length, no payload): padding (00), TEM
        // (01), and RST0-RST7 / SOI / EOI (D0-D9).
        if (marker == 0x00 or marker == 0x01 or (marker >= 0xD0 and marker <= 0xD9)) continue;
        if (i + 2 > bytes.len) return ImageError.InvalidJpeg;
        const seg_len = std.mem.readInt(u16, bytes[i..][0..2], .big);
        if (seg_len < 2 or i + seg_len > bytes.len) return ImageError.InvalidJpeg;
        const is_sof = marker >= 0xC0 and marker <= 0xCF and
            marker != 0xC4 and marker != 0xC8 and marker != 0xCC;
        if (is_sof) {
            if (seg_len < 7) return ImageError.InvalidJpeg;
            const p = i + 2; // past the length bytes, at `precision`
            return .{
                .height = std.mem.readInt(u16, bytes[p + 1 ..][0..2], .big),
                .width = std.mem.readInt(u16, bytes[p + 3 ..][0..2], .big),
            };
        }
        i += seg_len;
        // SOS: entropy-coded scan data follows with no further SOFn.
        if (marker == 0xDA) break;
    }
    return ImageError.InvalidJpeg;
}

/// Reads width/height from a BMP's DIB header -- not a decoder. The 14-byte
/// file header ("BM" + sizes) is followed by a DIB header whose leading
/// u32 is its own byte length: 12 for the old BITMAPCOREHEADER (u16 w/h),
/// 40 or more for BITMAPINFOHEADER and its successors (i32 w/h, where a
/// negative height just means a top-down row order). All little-endian.
pub fn bmpDimensions(bytes: []const u8) ImageError!ImageInfo {
    if (bytes.len < 26 or bytes[0] != 'B' or bytes[1] != 'M') return ImageError.InvalidBmp;
    const dib_size = std.mem.readInt(u32, bytes[14..18], .little);
    if (dib_size == 12) {
        return .{
            .width = std.mem.readInt(u16, bytes[18..20], .little),
            .height = std.mem.readInt(u16, bytes[20..22], .little),
        };
    }
    if (dib_size >= 40) {
        const w = std.mem.readInt(i32, bytes[18..22], .little);
        const h = std.mem.readInt(i32, bytes[22..26], .little);
        if (w <= 0 or h == 0) return ImageError.InvalidBmp;
        const abs_h: i64 = if (h < 0) -@as(i64, h) else h;
        return .{ .width = @intCast(w), .height = @intCast(abs_h) };
    }
    return ImageError.InvalidBmp;
}

/// Reads the logical screen width/height from a GIF header -- not a
/// decoder. The 6-byte signature ("GIF87a" / "GIF89a") is followed
/// immediately by the Logical Screen Descriptor, whose first two fields
/// are little-endian u16 width and height.
pub fn gifDimensions(bytes: []const u8) ImageError!ImageInfo {
    if (bytes.len < 10) return ImageError.InvalidGif;
    if (!std.mem.eql(u8, bytes[0..6], "GIF87a") and !std.mem.eql(u8, bytes[0..6], "GIF89a"))
        return ImageError.InvalidGif;
    return .{
        .width = std.mem.readInt(u16, bytes[6..8], .little),
        .height = std.mem.readInt(u16, bytes[8..10], .little),
    };
}

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
/// Note the deliberate gap: bold, italic and strikethrough stay *parsed
/// and ignored* (see `SgrPen`). Underline earns its `Style` field because
/// it is drawn from geometry the host already has (a rect at the cell's
/// baseline); the others need a second and third font face in the atlas,
/// which is a different piece of work.
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

pub const Style = struct {
    fg: Color,
    bg: Background,
    /// See `UnderlineStyle`. Defaults to no underline, so every existing
    /// `Style` initializer means what it did before this field existed.
    underline: UnderlineStyle = .{},
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

pub const LayerError = error{UnknownLayer};

/// Columns between horizontal tab stops for `\t` handling in
/// `Layer.writeText` (see `vt.consumeControl`). Fixed 8, the universal
/// terminal default; not yet a per-layer or per-session setting.
pub const tab_width: usize = 8;

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
        /// The underline every cell the *text* touches carries (see
        /// `Underline`). Deliberately not applied to `pad`'s blanks: a
        /// padded status bar or list row would otherwise draw its
        /// underline out to the full width, and a diagnostic squiggle
        /// should stop at the end of the token it marks.
        underline: UnderlineStyle = .{},
    };

    /// `writeTextTaggedScaled` with `WriteOpts` -- a single styled run.
    pub fn writeTextOpts(self: *Layer, text: []const u8, fg: Color, bg: ?Background, opts: WriteOpts) !void {
        const runs = [_]TextRun{.{ .text = text, .fg = fg, .bg = bg, .metadata_id = opts.metadata_id, .scale = opts.scale, .underline = opts.underline }};
        return self.writeRuns(&runs, .{ .max_cols = opts.max_cols, .pad = opts.pad, .pad_fg = fg, .pad_bg = bg, .pad_metadata_id = opts.metadata_id, .selectable = opts.selectable, .masked = opts.masked, .copy_text = opts.copy_text });
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
                const eff = self.vt.pen.resolve(r.fg, r.bg, r.underline);
                // While the shifted-in charset is line drawing, a byte in
                // `` ` ``..`~` names a box-drawing/symbol glyph, not itself
                // -- see `EscState`'s charset paragraph and `acsGraphic`.
                const line_drawing = if (self.vt.shift_out) self.vt.g1_line_drawing else self.vt.g0_line_drawing;
                if (line_drawing and cp_bytes.len == 1 and cp_bytes[0] >= '`' and cp_bytes[0] <= '~') {
                    var buf: [4]u8 = undefined;
                    const n = std.unicode.utf8Encode(vt.acsGraphic(cp_bytes[0]), &buf) catch unreachable;
                    if (self.vt.insert_mode) self.insertCellsFill(1, .{});
                    if (!self.putRunGlyph(buf[0..n], 1, eff.fg, eff.bg, r.metadata_id, r.scale, eff.underline, clip_end)) break :runs;
                    vt.noteLastGlyph(self, buf[0..n], 1, eff.fg, eff.bg, eff.underline);
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
                if (!self.putRunGlyph(cp_bytes, w, eff.fg, eff.bg, r.metadata_id, r.scale, eff.underline, clip_end)) break :runs;
                vt.noteLastGlyph(self, cp_bytes, w, eff.fg, eff.bg, eff.underline);
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

    /// Places one glyph of a `write_text` run: its footprint is its display
    /// width times `scaledPitch(scale)` columns by `scaledPitch(scale)`
    /// rows, and every footprint cell past the glyph's own -- the gap to
    /// its right and the rows below it that the enlarged glyph draws over
    /// -- is filled with blanks in the run's style so they carry its
    /// background and `metadata_id` (see `TextScale`). The rows below are
    /// clipped at the layer's bottom edge rather than scrolling it, and
    /// the cursor stays on the glyph's own row. Returns false when
    /// `clip_end` stops the write: the cells of the footprint that do fit
    /// are blanked instead, never half a glyph.
    fn putRunGlyph(
        self: *Layer,
        bytes: []const u8,
        w: u2,
        fg: Color,
        bg: ?Background,
        metadata_id: ?MetadataHandle,
        scale: TextScale,
        ul: UnderlineStyle,
        clip_end: ?usize,
    ) bool {
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
                return false;
            }
        } else if (footprint > w and self.cursor.col > 0 and self.cursor.col + footprint > self.width) {
            // A scaled glyph wraps whole, like a wide one does in
            // `putAtCursor`.
            self.cursor.col = 0;
            self.cursor.row += 1;
        }
        self.putAtCursor(bytes, w, fg, bg, metadata_id, scale, glyph_row_ul);
        // Read back after the put, which may have wrapped the glyph.
        const row = self.cursor.row;
        const start_col = self.cursor.col - w;
        var extra = footprint - w;
        while (extra > 0 and self.cursor.col < self.width) : (extra -= 1) {
            self.putAtCursor(" ", 1, fg, bg, metadata_id, .x1, glyph_row_ul);
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
        return true;
    }

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
    /// like any other; it used to just step the row, which on the alt
    /// screen's last row overwrote that row in place. With autowrap off
    /// (DECAWM, `?7l`) there is no wrap: the glyph lands on the last
    /// column(s) and the cursor stays there.
    pub fn putAtCursor(self: *Layer, bytes: []const u8, w: u2, fg: Color, bg: ?Background, metadata_id: ?MetadataHandle, scale: TextScale, ul: UnderlineStyle) void {
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
        c.style.underline = ul;
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
    /// rows the way clamping `row_end` to `self.height` used to (it read
    /// as an image "clipping" to whatever viewport happened to be current
    /// when it was drawn, instead of interleaving into the flowing output
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
    pub fn rowForAbove(self: *const Layer, above: i64) ?[]const Cell {
        if (above > 0) {
            if (above - 1 >= @as(i64, @intCast(self.history_len))) return null;
            return self.scrollbackRow(@intCast(above - 1));
        }
        const live_row: i64 = -above;
        if (live_row >= @as(i64, @intCast(self.height))) return null;
        return self.rowSlice(self.physicalRow(@intCast(live_row)));
    }
};

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
