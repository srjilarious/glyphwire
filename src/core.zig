const std = @import("std");

/// Truecolor RGBA. The "use theme default" sentinel from decisions.md's
/// color model isn't needed until a real theme system exists; add it when
/// that lands.
pub const Color = struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8 = 255,
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
pub const ImageBg = struct {
    handle: ImageHandle,
    offset_x: u32,
    offset_y: u32,
    scale: f32 = 1.0,
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
///   preserved. Used by `Layer.drawBox`'s tiles rather than `fit`: a
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
    /// Normalized (0..1) sub-rectangle of the source image this cell
    /// samples, defaulting to the whole image. A plain `draw_icon` never
    /// sets these -- a single icon is always one complete picture (this
    /// struct's own doc comment). The one caller that does is
    /// `Layer.drawBox`'s `BoxMode.stretch`: it gives each cell along a
    /// multi-cell edge/fill run its own slice of one logical tile image,
    /// so the whole run (e.g. a vertical gradient) reads as that one image
    /// scaled continuously across the run rather than repeated per cell
    /// (`BoxMode.tile`'s behavior, which leaves these at the default).
    src_l: f32 = 0,
    src_t: f32 = 0,
    src_r: f32 = 1,
    src_b: f32 = 1,
};

/// A cell's background: a flat color, a reference to a loaded image tile
/// (`draw_image`/`draw_box`, clipped rather than stretched -- see
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
};

pub const ImageError = error{
    InvalidPng,
    InvalidJpeg,
    InvalidBmp,
    InvalidGif,
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

pub const Style = struct {
    fg: Color,
    bg: Background,
};

pub const default_style: Style = .{
    .fg = .{ .r = 255, .g = 255, .b = 255 },
    .bg = .{ .color = .{ .r = 0, .g = 0, .b = 0 } },
};

/// The "current pen" a `Layer` builds up from SGR (`ESC [ ... m`) sequences
/// seen in mirrored plain-command output -- glyphwire's small, deliberate
/// step toward honouring the escape codes a non-glyphwire-aware program
/// emits (compiler diagnostics in colour, `pip`/`npm` progress bars),
/// rather than the full VT model a real terminal library would bring (see
/// `docs/investigations/libghostty-vt-fallback.md`, Phase A).
///
/// **Colour only.** `bold` maps a basic (30-37) foreground to its bright
/// (90-97) variant; `dim` darkens the resolved foreground; `inverse` swaps
/// foreground and background. All three are folded into the concrete
/// `Cell.style` at write time -- no attribute bitflags on `Style`, no
/// renderer changes. Italic / underline / strikethrough are *parsed and
/// ignored* (they need a `Style` bitfield + font/renderer work -- the
/// separate "style attributes beyond fg/bg" roadmap item).
///
/// A `null` `fg` / `bg` override means "fall back to the `write_text`
/// call's own `fg`/`bg` argument (and then `default_style`)". `ESC [ 0 m`
/// (or `ESC [ m`) resets the whole pen. See `Layer.pen` for the
/// cross-call persistence rule.
pub const SgrPen = struct {
    /// Resolved foreground override, or null for "use the call's fg arg".
    fg: ?Color = null,
    /// Resolved background override, or null for "use the call's bg arg".
    bg: ?Color = null,
    /// Palette index 0-7 when `fg` was set by a basic `30`-`37` code, so a
    /// later `bold` can promote it to bright. Null once `fg` is bright,
    /// 256-indexed, truecolor, or default.
    fg_basic: ?u3 = null,
    bold: bool = false,
    dim: bool = false,
    inverse: bool = false,

    /// The 16 base ANSI colours (xterm's default palette). Index 0-7 are
    /// the normal set, 8-15 the bright set.
    pub const ansi16 = [16]Color{
        .{ .r = 0, .g = 0, .b = 0 },       .{ .r = 205, .g = 0, .b = 0 },
        .{ .r = 0, .g = 205, .b = 0 },     .{ .r = 205, .g = 205, .b = 0 },
        .{ .r = 0, .g = 0, .b = 238 },     .{ .r = 205, .g = 0, .b = 205 },
        .{ .r = 0, .g = 205, .b = 205 },   .{ .r = 229, .g = 229, .b = 229 },
        .{ .r = 127, .g = 127, .b = 127 }, .{ .r = 255, .g = 0, .b = 0 },
        .{ .r = 0, .g = 255, .b = 0 },     .{ .r = 255, .g = 255, .b = 0 },
        .{ .r = 92, .g = 92, .b = 255 },   .{ .r = 255, .g = 0, .b = 255 },
        .{ .r = 0, .g = 255, .b = 255 },   .{ .r = 255, .g = 255, .b = 255 },
    };

    /// Maps an xterm 256-colour index to RGB: 0-15 the base palette,
    /// 16-231 the 6x6x6 cube, 232-255 the 24-step grey ramp.
    pub fn xterm256(idx: u8) Color {
        if (idx < 16) return ansi16[idx];
        if (idx < 232) {
            const levels = [6]u8{ 0, 95, 135, 175, 215, 255 };
            const c = idx - 16;
            return .{
                .r = levels[(c / 36) % 6],
                .g = levels[(c / 6) % 6],
                .b = levels[c % 6],
            };
        }
        const v: u8 = @intCast(8 + 10 * @as(u16, idx - 232));
        return .{ .r = v, .g = v, .b = v };
    }

    /// Applies one SGR parameter list (the bytes between `ESC [` and the
    /// `m`, e.g. `"1;38;5;208"`) to the pen. Tolerant: unknown or
    /// malformed parameters are skipped, never an error -- matching the
    /// "recognize and don't choke" spirit of the old escape *stripper*
    /// this replaces. `:` sub-parameter separators (`38:2:...`) are
    /// accepted as equivalent to `;`.
    pub fn applySgr(self: *SgrPen, params: []const u8) void {
        // At most a handful of numeric params in any real SGR sequence;
        // a longer/garbled one is truncated rather than grown. `null` =
        // an empty field -- a standalone empty param means 0 (reset), and
        // an empty colour-space id in the colon form `38:2::r:g:b` is
        // skipped over (see below).
        var nums: [24]?u16 = undefined;
        var n: usize = 0;
        var it = std.mem.splitAny(u8, params, ";:");
        while (it.next()) |tok| {
            if (n == nums.len) break;
            nums[n] = if (tok.len == 0) null else (std.fmt.parseInt(u16, tok, 10) catch null);
            n += 1;
        }
        if (n == 0) {
            self.* = .{}; // bare `ESC [ m` is `ESC [ 0 m`
            return;
        }

        var i: usize = 0;
        while (i < n) : (i += 1) {
            const code = nums[i] orelse 0; // empty standalone param == 0
            switch (code) {
                0 => self.* = .{},
                1 => self.bold = true,
                2 => self.dim = true,
                22 => {
                    self.bold = false;
                    self.dim = false;
                },
                7 => self.inverse = true,
                27 => self.inverse = false,
                // Parsed and ignored: italic (3/23), underline (4/24),
                // blink (5/25), strikethrough (9/29). Colour-only for now.
                3, 4, 5, 9, 23, 24, 25, 29 => {},
                30...37 => {
                    self.fg_basic = @intCast(code - 30);
                    self.fg = ansi16[code - 30];
                },
                39 => {
                    self.fg = null;
                    self.fg_basic = null;
                },
                40...47 => self.bg = ansi16[code - 40],
                49 => self.bg = null,
                90...97 => {
                    self.fg_basic = null;
                    self.fg = ansi16[8 + (code - 90)];
                },
                100...107 => self.bg = ansi16[8 + (code - 100)],
                38, 48 => {
                    // `38;5;N` (256) / `38;2;R;G;B` (truecolor), with the
                    // colon variants `38:5:N` and `38:2[:cs]:R:G:B`. Skip
                    // the params consumed so the outer loop doesn't re-read
                    // them as standalone codes.
                    const target_fg = code == 38;
                    if (i + 1 >= n) break;
                    const mode = nums[i + 1] orelse 0;
                    if (mode == 5) {
                        if (i + 2 >= n) break;
                        const col = xterm256(@intCast((nums[i + 2] orelse 0) & 0xff));
                        if (target_fg) {
                            self.fg = col;
                            self.fg_basic = null;
                        } else self.bg = col;
                        i += 2;
                    } else if (mode == 2) {
                        // The colon form may carry an empty colour-space
                        // id right after the `2` -- step past it.
                        var base = i + 2;
                        if (base < n and nums[base] == null) base += 1;
                        if (base + 2 >= n) break;
                        const col = Color{
                            .r = @intCast((nums[base] orelse 0) & 0xff),
                            .g = @intCast((nums[base + 1] orelse 0) & 0xff),
                            .b = @intCast((nums[base + 2] orelse 0) & 0xff),
                        };
                        if (target_fg) {
                            self.fg = col;
                            self.fg_basic = null;
                        } else self.bg = col;
                        i = base + 2;
                    } else break;
                },
                else => {}, // unknown SGR code -- ignore
            }
        }
    }

    /// Resolves the concrete `(fg, bg)` a printed cell gets, given the
    /// pen and the `write_text` call's own `fg`/`bg` arguments (`bg` is a
    /// `?Background`: `null` = "leave the cell's existing background",
    /// per `write_text`'s `transparent_bg`). The pen overrides the
    /// arguments where it has an opinion; `bold`/`dim`/`inverse` are then
    /// folded into the result.
    pub fn resolve(self: SgrPen, arg_fg: Color, arg_bg: ?Background) struct { fg: Color, bg: ?Background } {
        var fg: Color = self.fg orelse arg_fg;
        if (self.bold) {
            if (self.fg_basic) |idx| fg = ansi16[8 + @as(usize, idx)];
        }
        if (self.dim) {
            fg = .{
                .r = @intCast(@as(u16, fg.r) * 55 / 100),
                .g = @intCast(@as(u16, fg.g) * 55 / 100),
                .b = @intCast(@as(u16, fg.b) * 55 / 100),
                .a = fg.a,
            };
        }

        var bg: ?Background = if (self.bg) |c| .{ .color = c } else arg_bg;

        if (self.inverse) {
            const bg_color: Color = switch (bg orelse Background{ .color = default_style.bg.color }) {
                .color => |c| c,
                // An image/icon background can't be swapped into the fg;
                // fall back to the default bg colour for the inverse.
                else => default_style.bg.color,
            };
            const new_bg = fg;
            fg = bg_color;
            bg = .{ .color = new_bg };
        }

        return .{ .fg = fg, .bg = bg };
    }
};

/// Inline byte capacity for a cell's grapheme cluster. This is a plain
/// fixed buffer for the slice, not the small-string-optimized
/// inline+overflow representation decisions.md settles on long term —
/// upgrade this alongside real UAX #29 segmentation.
pub const grapheme_inline_len = 8;

/// East Asian Width "Wide" (W) and "Fullwidth" (F) codepoint ranges,
/// sorted and non-overlapping, generated from Unicode 16.0.0 by walking
/// every codepoint's `unicodedata.east_asian_width` and coalescing the
/// W/F runs. Ambiguous (A) is deliberately excluded -- treated as narrow,
/// the wcwidth / non-CJK-locale default (see decisions.md, Cell content).
/// Regenerate the same way against a newer Unicode when bumping.
const wide_ranges = [_][2]u21{
    .{ 0x1100, 0x115F },   .{ 0x231A, 0x231B },   .{ 0x2329, 0x232A },
    .{ 0x23E9, 0x23EC },   .{ 0x23F0, 0x23F0 },   .{ 0x23F3, 0x23F3 },
    .{ 0x25FD, 0x25FE },   .{ 0x2614, 0x2615 },   .{ 0x2630, 0x2637 },
    .{ 0x2648, 0x2653 },   .{ 0x267F, 0x267F },   .{ 0x268A, 0x268F },
    .{ 0x2693, 0x2693 },   .{ 0x26A1, 0x26A1 },   .{ 0x26AA, 0x26AB },
    .{ 0x26BD, 0x26BE },   .{ 0x26C4, 0x26C5 },   .{ 0x26CE, 0x26CE },
    .{ 0x26D4, 0x26D4 },   .{ 0x26EA, 0x26EA },   .{ 0x26F2, 0x26F3 },
    .{ 0x26F5, 0x26F5 },   .{ 0x26FA, 0x26FA },   .{ 0x26FD, 0x26FD },
    .{ 0x2705, 0x2705 },   .{ 0x270A, 0x270B },   .{ 0x2728, 0x2728 },
    .{ 0x274C, 0x274C },   .{ 0x274E, 0x274E },   .{ 0x2753, 0x2755 },
    .{ 0x2757, 0x2757 },   .{ 0x2795, 0x2797 },   .{ 0x27B0, 0x27B0 },
    .{ 0x27BF, 0x27BF },   .{ 0x2B1B, 0x2B1C },   .{ 0x2B50, 0x2B50 },
    .{ 0x2B55, 0x2B55 },   .{ 0x2E80, 0x2E99 },   .{ 0x2E9B, 0x2EF3 },
    .{ 0x2F00, 0x2FD5 },   .{ 0x2FF0, 0x303E },   .{ 0x3041, 0x3096 },
    .{ 0x3099, 0x30FF },   .{ 0x3105, 0x312F },   .{ 0x3131, 0x318E },
    .{ 0x3190, 0x31E5 },   .{ 0x31EF, 0x321E },   .{ 0x3220, 0x3247 },
    .{ 0x3250, 0xA48C },   .{ 0xA490, 0xA4C6 },   .{ 0xA960, 0xA97C },
    .{ 0xAC00, 0xD7A3 },   .{ 0xF900, 0xFAFF },   .{ 0xFE10, 0xFE19 },
    .{ 0xFE30, 0xFE52 },   .{ 0xFE54, 0xFE66 },   .{ 0xFE68, 0xFE6B },
    .{ 0xFF01, 0xFF60 },   .{ 0xFFE0, 0xFFE6 },   .{ 0x16FE0, 0x16FE4 },
    .{ 0x16FF0, 0x16FF1 }, .{ 0x17000, 0x187F7 }, .{ 0x18800, 0x18CD5 },
    .{ 0x18CFF, 0x18D08 }, .{ 0x1AFF0, 0x1AFF3 }, .{ 0x1AFF5, 0x1AFFB },
    .{ 0x1AFFD, 0x1AFFE }, .{ 0x1B000, 0x1B122 }, .{ 0x1B132, 0x1B132 },
    .{ 0x1B150, 0x1B152 }, .{ 0x1B155, 0x1B155 }, .{ 0x1B164, 0x1B167 },
    .{ 0x1B170, 0x1B2FB }, .{ 0x1D300, 0x1D356 }, .{ 0x1D360, 0x1D376 },
    .{ 0x1F004, 0x1F004 }, .{ 0x1F0CF, 0x1F0CF }, .{ 0x1F18E, 0x1F18E },
    .{ 0x1F191, 0x1F19A }, .{ 0x1F200, 0x1F202 }, .{ 0x1F210, 0x1F23B },
    .{ 0x1F240, 0x1F248 }, .{ 0x1F250, 0x1F251 }, .{ 0x1F260, 0x1F265 },
    .{ 0x1F300, 0x1F320 }, .{ 0x1F32D, 0x1F335 }, .{ 0x1F337, 0x1F37C },
    .{ 0x1F37E, 0x1F393 }, .{ 0x1F3A0, 0x1F3CA }, .{ 0x1F3CF, 0x1F3D3 },
    .{ 0x1F3E0, 0x1F3F0 }, .{ 0x1F3F4, 0x1F3F4 }, .{ 0x1F3F8, 0x1F43E },
    .{ 0x1F440, 0x1F440 }, .{ 0x1F442, 0x1F4FC }, .{ 0x1F4FF, 0x1F53D },
    .{ 0x1F54B, 0x1F54E }, .{ 0x1F550, 0x1F567 }, .{ 0x1F57A, 0x1F57A },
    .{ 0x1F595, 0x1F596 }, .{ 0x1F5A4, 0x1F5A4 }, .{ 0x1F5FB, 0x1F64F },
    .{ 0x1F680, 0x1F6C5 }, .{ 0x1F6CC, 0x1F6CC }, .{ 0x1F6D0, 0x1F6D2 },
    .{ 0x1F6D5, 0x1F6D7 }, .{ 0x1F6DC, 0x1F6DF }, .{ 0x1F6EB, 0x1F6EC },
    .{ 0x1F6F4, 0x1F6FC }, .{ 0x1F7E0, 0x1F7EB }, .{ 0x1F7F0, 0x1F7F0 },
    .{ 0x1F90C, 0x1F93A }, .{ 0x1F93C, 0x1F945 }, .{ 0x1F947, 0x1F9FF },
    .{ 0x1FA70, 0x1FA7C }, .{ 0x1FA80, 0x1FA89 }, .{ 0x1FA8F, 0x1FAC6 },
    .{ 0x1FACE, 0x1FADC }, .{ 0x1FADF, 0x1FAE9 }, .{ 0x1FAF0, 0x1FAF8 },
    .{ 0x20000, 0x2FFFD }, .{ 0x30000, 0x3FFFD },
};

/// Maps a byte of the VT100 "special graphics and line drawing" set
/// (`Layer.g0_line_drawing` / `g1_line_drawing`, designated by `ESC ( 0` /
/// `ESC ) 0`) to its Unicode glyph. Only `` ` ``..`~` (0x60..0x7e) are part
/// of the set; callers must not pass anything outside that range. Table
/// per the DEC VT220 reference manual (table 2-4), reproduced verbatim by
/// the Linux console (`console_codes(4)`) and ncurses/terminfo's `acsc`
/// capability -- this is the same mapping every terminal that supports the
/// set uses.
fn acsGraphic(byte: u8) u21 {
    return switch (byte) {
        '`' => 0x25c6, // ◆ diamond
        'a' => 0x2592, // ▒ medium shade
        'b' => 0x2409, // ␉ HT symbol
        'c' => 0x240c, // ␌ FF symbol
        'd' => 0x240d, // ␍ CR symbol
        'e' => 0x240a, // ␊ LF symbol
        'f' => 0x00b0, // ° degree
        'g' => 0x00b1, // ± plus-minus
        'h' => 0x2424, // ␤ NL symbol
        'i' => 0x240b, // ␋ VT symbol
        'j' => 0x2518, // ┘ lower-right corner
        'k' => 0x2510, // ┐ upper-right corner
        'l' => 0x250c, // ┌ upper-left corner
        'm' => 0x2514, // └ lower-left corner
        'n' => 0x253c, // ┼ crossing lines
        'o' => 0x23ba, // ⎺ scan line 1
        'p' => 0x23bb, // ⎻ scan line 3
        'q' => 0x2500, // ─ horizontal line
        'r' => 0x23bc, // ⎼ scan line 7
        's' => 0x23bd, // ⎽ scan line 9
        't' => 0x251c, // ├ left T
        'u' => 0x2524, // ┤ right T
        'v' => 0x2534, // ┴ bottom T
        'w' => 0x252c, // ┬ top T
        'x' => 0x2502, // │ vertical line
        'y' => 0x2264, // ≤ less-or-equal
        'z' => 0x2265, // ≥ greater-or-equal
        '{' => 0x03c0, // π pi
        '|' => 0x2260, // ≠ not equal
        '}' => 0x00a3, // £ pound sterling
        '~' => 0x00b7, // · middle dot
        else => byte, // not part of the set -- callers never pass this
    };
}

/// Display width, in terminal cells, of a single codepoint: 2 for East
/// Asian Wide/Fullwidth, 1 otherwise. Not grapheme-aware -- a cluster's
/// width is taken from its base codepoint (combining marks and ZWJ emoji
/// sequences are still an open item, see decisions.md / UAX #29). Control
/// bytes never reach here; `writeText` strips them first.
pub fn codepointWidth(cp: u21) u2 {
    var lo: usize = 0;
    var hi: usize = wide_ranges.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (cp < wide_ranges[mid][0]) {
            hi = mid;
        } else if (cp > wide_ranges[mid][1]) {
            lo = mid + 1;
        } else {
            return 2;
        }
    }
    return 1;
}

/// Total display width of `text` in terminal cells (sum of
/// `codepointWidth` over its codepoints). Invalid UTF-8 falls back to the
/// byte length.
pub fn stringWidth(text: []const u8) usize {
    const view = std.unicode.Utf8View.init(text) catch return text.len;
    var it = view.iterator();
    var w: usize = 0;
    while (it.nextCodepointSlice()) |s| {
        w += codepointWidth(std.unicode.utf8Decode(s) catch 0xFFFD);
    }
    return w;
}

/// A cell's role in East Asian Width terms: an ordinary 1-cell character,
/// the left ("primary") cell of a 2-cell wide character that holds the
/// grapheme, or the right cell of such a pair which renders nothing of
/// its own (it carries the lead's background + `metadata_id` so a click
/// on either half resolves the same). See decisions.md, Cell content.
pub const CellWidth = enum(u2) { narrow, wide_lead, wide_spacer };

pub const Cell = struct {
    grapheme_bytes: [grapheme_inline_len]u8 = [_]u8{0} ** grapheme_inline_len,
    grapheme_len: u8 = 0,
    wide: CellWidth = .narrow,
    style: Style = default_style,
    /// Sibling of `style.bg`, not part of it -- a cell can be tagged
    /// regardless of whether its background is a color/image/icon. Set (or
    /// cleared) as a whole by `write_text`/`draw_icon`'s optional
    /// `metadata_id` param, the same way those calls already overwrite
    /// `grapheme`/`style` outright rather than merging with whatever was
    /// there before.
    metadata_id: ?MetadataHandle = null,
    /// An icon drawn *over* `style.bg` and `grapheme` rather than replacing
    /// either -- unlike the ordinary `draw_icon` (`style.bg`'s `.icon`
    /// variant), which is itself one of `Background`'s mutually exclusive
    /// cases and so necessarily replaces whatever background was there.
    /// Set by `Layer.drawIconOver` (`draw_icon`'s `foreground: true`),
    /// for content that needs to sit on top of an already-drawn background
    /// -- e.g. `glyphwire-notify`'s type icon over its `"dialog"` 9-patch
    /// panel, which `draw_icon`'s normal background-replacing behavior
    /// would otherwise punch a flat hole through.
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

/// One end of a linear text selection on a layer, in scroll-stable
/// coordinates. `above` is how many grid rows this point sits above the
/// live viewport's top row: positive counts up into retained scrollback
/// (`above == 1` is the row immediately above the viewport), zero or
/// negative is inside the live viewport (live buffer row `= -above`).
/// Deliberately not a `(view_offset, screen_row)` pair -- `above` is
/// anchored to the content, so a selection stays pinned to the same text
/// while the view is scrolled, and `Layer.scrollOne` shifts both ends by
/// one so it also stays pinned as fresh output pushes rows into history.
/// `col` is a 0-based cell column.
pub const SelectionPoint = struct { above: i64, col: usize };

/// A linear (stream, not rectangular) selection on a layer: from `anchor`
/// (where the drag / keyboard selection started) to `active` (the moving
/// end). Reading order runs from whichever end is further back in
/// scrollback (larger `above`, ties broken on smaller `col`) to the
/// other -- see `ordered`.
pub const Selection = struct {
    anchor: SelectionPoint,
    active: SelectionPoint,

    /// The two ends in reading order: `start` is the earlier point (higher
    /// on screen / further back in history), `end` the later one. `start`
    /// always has `above >= end.above`.
    pub fn ordered(self: Selection) struct { start: SelectionPoint, end: SelectionPoint } {
        const a = self.anchor;
        const b = self.active;
        const a_first = a.above > b.above or (a.above == b.above and a.col <= b.col);
        return if (a_first) .{ .start = a, .end = b } else .{ .start = b, .end = a };
    }

    /// Whether both ends coincide -- a zero-width selection, which
    /// `Layer.selectionText` renders as the empty string (the host treats
    /// that the same as "nothing selected").
    pub fn isEmpty(self: Selection) bool {
        return self.anchor.above == self.active.above and self.anchor.col == self.active.col;
    }
};

/// A layer's viewport size in cells -- what `get_property(layer, "size")`
/// reports. For the root layer this is the context's base size, i.e. the
/// answer to "how big is the window right now" (see `Context.resize`).
pub const LayerSize = struct { cols: usize, rows: usize };

/// A layer's scrollback view state (see `PropertyName.scroll` and the
/// `scroll_view` wire method): `offset` rows of retained history are
/// currently shown above the live viewport, out of `max` (`history_len`)
/// retained in total. `offset == 0` is the live tail.
pub const LayerScroll = struct { offset: usize, max: usize };

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
};

pub const PropertyValue = union(PropertyName) {
    cursor: Cursor,
    revision: u64,
    position: PxPos,
    cell_position: CellPos,
    size: LayerSize,
    scroll: LayerScroll,
    visibility: bool,
    viewport: Viewport,
    scroll_offset: CellPos,
    scrollbars: ScrollbarState,
    content_extent: Viewport,
};

pub const PropertyError = error{
    UnknownProperty,
    /// The property exists but this layer won't accept a write to it --
    /// `size` and `visibility` on the root layer, whose geometry and
    /// visibility the host owns. See each one's doc comment above.
    ReadOnlyProperty,
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
/// `Layer.writeText` (see `Layer.consumeControl`). Fixed 8, the universal
/// terminal default; not yet a per-layer or per-session setting.
pub const tab_width: usize = 8;

/// State of `Layer`'s small escape-sequence machine (see
/// `Layer.consumeControl` / `Layer.stepEscape`). glyphwire has no full
/// VT100/ANSI model -- it replaces that, per decisions.md -- but a plain
/// program mirrored onto the grid emits colour codes and simple
/// cursor-move sequences, and drawing the raw bytes (`[31m` etc.) as
/// garbage graphemes reads worse than acting on the common ones. So
/// `writeText`:
///
///  - **interprets** `ESC [ ... m` (SGR): colours + bold/dim/inverse are
///    folded into `Layer.pen` and thence into each printed cell's
///    `Style` -- see `SgrPen`. Italic/underline/strikethrough are parsed
///    and ignored (colour-only for now).
///  - **interprets** a handful of `ESC [ ...` cursor/erase finals:
///    `A`/`B`/`C`/`D` (cursor up/down/right/left), `G` (column),
///    `H`/`f` (row;col), `J` (erase in display), `K` (erase in line).
///  - **interprets** VT100 charset designation/shift: `ESC ( <c>` / `ESC )
///    <c>` designate G0/G1 as the special graphics and line-drawing set
///    (`c == '0'`) or plain ASCII (anything else), and `SO`/`SI` (0x0E/
///    0x0F) shift which of G0/G1 is active. While the active set is line
///    drawing, printable bytes `` ` ``..`~` (0x60..0x7e) are mapped to
///    their Unicode box-drawing/symbol glyph (`acsGraphic`) instead of
///    printed literally -- see `g0_line_drawing`/`g1_line_drawing`. This is
///    what `smacs`/`rmacs` (xterm-style, redesignates G0 directly) and
///    `screen`/`tmux`-style (SO/SI over a G1 designated once) both compile
///    down to, and it's how ncurses draws panel borders when it isn't
///    using UTF-8 line-drawing glyphs directly.
///  - **discards** every other `ESC [ ...` (CSI) final and every
///    `ESC ] ... ` / `ESC P|X|^|_ ... ` (OSC and other string-terminated)
///    sequence, same as the old stripper -- recognized well enough to
///    find the end, then dropped.
///
/// Nothing carries across `writeText` calls. The machine is reset to
/// `.ground` (and the CSI parameter buffer cleared) at the end of every
/// call, and the SGR `pen` (colour state) is reset at the *start* of
/// every call -- a sequence, or a colour, is scoped entirely to the
/// chunk that carried it. This deliberately gives up on a sequence or an
/// SGR colour a pipe split across two `write_text` chunks (rare -- a
/// plain program emits each escape in one `write`, and its colour
/// usually with the text it colours) in exchange for never letting a
/// lone trailing `ESC`, a truncated `ESC [ ...`, an unterminated
/// `ESC ] ...` (OSC), or an un-reset `ESC [ 31 m` silently affect
/// anything written afterward -- glyphwire-shell's own prompt included.
pub const EscState = enum {
    /// Not inside a sequence -- the normal case.
    ground,
    /// Last byte was ESC (0x1b); the next byte selects the sequence kind.
    esc,
    /// Inside `ESC [ ...` -- consume parameter/intermediate bytes
    /// (0x20..0x3f) until a final byte (0x40..0x7e) ends it.
    csi,
    /// Inside a string-terminated sequence (`ESC ]`, `ESC P`, `ESC X`,
    /// `ESC ^`, `ESC _`) -- consume until BEL (0x07) or ST (`ESC \`).
    string,
    /// Saw `ESC (`; the next byte designates G0 (`g0_line_drawing`).
    charset_g0,
    /// Saw `ESC )`; the next byte designates G1 (`g1_line_drawing`).
    charset_g1,
};

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
    /// The layer's current text selection, or null when nothing is
    /// selected -- see `Selection`. Set/moved/cleared by the
    /// `set_selection` / `update_selection` / `clear_selection` wire
    /// messages (and glyphwire-host's in-process equivalents), read by the
    /// renderer (`selectionColRange`) and `get_selection_text`
    /// (`selectionText`). `scrollOne` keeps both ends pinned to their
    /// content as output scrolls; `resize` drops it (the ring buffer is
    /// rebuilt from scratch).
    selection: ?Selection = null,
    /// Metadata ids whose cells are drawn with the selection's translucent
    /// tint -- set/cleared by the `toggle_highlight` / `set_highlight` /
    /// `clear_highlight` messages. Stored as *ids*, not cell ranges: the
    /// renderer tints any cell whose `metadata_id` is in this set, so a
    /// highlight follows its content through scrollback and survives a
    /// `resize` for free, and an id whose cells have all scrolled out of
    /// retained history simply matches nothing (harmless -- ids are never
    /// reused). glyphwire-shell drives this for its `ls` multi-select
    /// marks. Owned -- freed in `deinit`.
    highlighted_ids: std.ArrayList(MetadataHandle) = .empty,
    /// Escape-sequence machine state (see `EscState`). `.ground` except
    /// partway through a single `writeText` call that is
    /// interpreting/discarding an `ESC ...` sequence -- reset back to
    /// `.ground` before that call returns, so an unterminated sequence
    /// never leaks into the next one.
    esc_state: EscState = .ground,
    /// Accumulates the parameter/intermediate bytes of the `ESC [ ...`
    /// sequence currently being parsed (`esc_state == .csi`), up to its
    /// final byte. Fixed-size: a sequence longer than this is abandoned
    /// (`csi_len` stops growing and the final byte finds a truncated
    /// buffer -- harmless, it just parses as far as it got). Cleared
    /// alongside `esc_state` at the end of every `writeText` call.
    csi_buf: [48]u8 = undefined,
    csi_len: usize = 0,
    /// True after `SO` (0x0E) shifted G1 into GL; false (the default, and
    /// after `SI` / 0x0F) means G0 is active. Which set is actually line
    /// drawing while active is `g0_line_drawing`/`g1_line_drawing`. Reset
    /// to `false` at the end of every `writeText` call, matching
    /// `esc_state`/`pen`'s call-scoped reset -- see `EscState`.
    shift_out: bool = false,
    /// True while G0 is designated as the VT100 special graphics/
    /// line-drawing set (`ESC ( 0`) rather than US-ASCII (`ESC ( B`, the
    /// default). xterm-style terminfo (`smacs`/`rmacs`) toggles this
    /// directly and never sends SO/SI. Reset to `false` at the end of
    /// every `writeText` call -- see `EscState`.
    g0_line_drawing: bool = false,
    /// Same as `g0_line_drawing` but for G1 (`ESC ) 0` / `ESC ) B`).
    /// screen/tmux-style terminfo designates this once and shifts into it
    /// with SO/SI (`shift_out`) instead of redesignating G0.
    g1_line_drawing: bool = false,
    /// Scratch SGR "pen" built up from `ESC [ ... m` sequences while a
    /// single `writeText` call runs -- see `SgrPen`. Reset to `.{}` at
    /// the *start* of every `writeTextTagged` call, so a colour is
    /// honoured only for the rest of the chunk that set it and never
    /// bleeds into a later call (the shell's prompt, the next command's
    /// output). Lives on the `Layer` only because the `ESC [` machine
    /// (`consumeControl` -> `stepEscape` -> `execCsi`) needs somewhere to
    /// accumulate it mid-call.
    pen: SgrPen = .{},
    /// --- B1 screen model (see `execCsi` / decisions.md's VT fallback) ---
    /// Alternate-screen buffer (xterm `?1049` / `?47` / `?1047`): a
    /// lazily-allocated `width * height` cell array, row-major, with **no
    /// scrollback ring** -- a full-screen program's transient screen.
    /// Null until first entered; kept allocated after exit for reuse,
    /// freed in `deinit`.
    alt_cells: ?[]Cell = null,
    /// True while the alt screen is the active target: `cell` / `liveRow`
    /// / `viewRow` read and write `alt_cells`, and scrolling shuffles
    /// within it with no history. `cursor` is then the alt cursor and the
    /// primary cursor is stashed in `stashed_cursor` (and vice versa).
    on_alt: bool = false,
    stashed_cursor: Cursor = .{},
    /// DECSC / DECRC (`ESC 7` / `ESC 8`, and the ANSI.SYS `CSI s` /
    /// `CSI u`) saved cursor, or null if nothing has been saved.
    saved_cursor: ?Cursor = null,
    /// DECSTBM scroll region, inclusive, in viewport rows. `[0, height-1]`
    /// (the default -- `regionActive()` false) keeps the classic
    /// ring-buffer scroll-into-scrollback on a line feed past the bottom;
    /// a narrower region confines line feeds, `SU`/`SD` and `IL`/`DL` to
    /// `[scroll_top, scroll_bot]` with no scrollback. Set to `height-1`
    /// by `init`; kept in range by `resize`.
    scroll_top: usize = 0,
    scroll_bot: usize = 0,
    /// DECTCEM (`CSI ? 25 h/l`): whether the host should paint a caret
    /// for this layer. Advisory data for the renderer only.
    cursor_visible: bool = true,
    /// DECCKM (`CSI ? 1 h/l`, application cursor keys). Tracked here only
    /// so glyphwire-host can tell a full-screen program (`less`, `vim`,
    /// `htop`, `fzf` -- they all set it; `ls`/`cat`/`grep` don't) is
    /// driving the primary screen and stop fighting it for the scrollback
    /// view -- see `host/main.zig`'s `screenOwnedByProgram`. The pty input
    /// path has its own copy in `pty.ModeTracker` (a synchronous local
    /// read; this one would need a wire round trip).
    app_cursor_keys: bool = false,
    /// Bytes this layer owes the program writing to it -- a terminal
    /// reply to a `CSI 6n` / `CSI c` / DECRQM query parsed out of
    /// `writeText`. The dispatcher drains it right after each `write_text`
    /// (`takeReply`) and forwards it as a `terminal_reply` notification;
    /// glyphwire-shell writes it to the pty master.
    reply_buf: [96]u8 = undefined,
    reply_len: usize = 0,
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
    /// See `PropertyName.viewport`. 0 on an axis means the whole content
    /// grid on that axis; read them through `viewportCols`/`viewportRows`,
    /// which resolve the default and clamp to the content.
    viewport_cols: usize = 0,
    viewport_rows: usize = 0,
    /// See `PropertyName.scroll_offset` -- the viewport's top-left within
    /// the content grid. Always within `maxScroll` (every writer goes
    /// through `setScrollOffset`, and `resize` re-clamps).
    scroll_off: CellPos = .{},
    /// See `PropertyName.content_extent`. Non-null on a pane that scrolls
    /// itself: the size of the whole content the client redraws, which
    /// the scrollbar/viewport maths use in place of the real grid.
    content_extent: ?CellPos = null,
    /// The virtual scroll position while `content_extent` is set --
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
            .owners = std.AutoHashMap(ConnId, void).init(alloc),
            .scrollback_rows = scrollback_rows,
            .buf = buf,
            .scroll_bot = height - 1,
        };
    }

    pub fn deinit(self: *Layer) void {
        self.alloc.free(self.buf);
        if (self.alt_cells) |a| self.alloc.free(a);
        var table_it = self.tables.valueIterator();
        while (table_it.next()) |t| t.deinit();
        self.tables.deinit();
        self.table_order.deinit(self.alloc);
        self.highlighted_ids.deinit(self.alloc);
        self.owners.deinit();
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
        return self.content_extent orelse .{ .row = self.height, .col = self.width };
    }

    /// The scroll offset a scrollbar reflects and `set_property` /
    /// wheel / drag move: the virtual `content_off` for a self-scrolling
    /// pane, else the real `scroll_off`.
    pub fn effectiveScrollOffset(self: *const Layer) CellPos {
        return if (self.content_extent != null) self.content_off else self.scroll_off;
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
            if (self.content_extent != null) {
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
    /// re-clamps the virtual offset into it. See
    /// `PropertyName.content_extent`.
    pub fn setContentExtent(self: *Layer, extent: ?CellPos) void {
        self.content_extent = extent;
        if (extent == null) self.content_off = .{};
        _ = self.setScrollOffset(self.effectiveScrollOffset());
        self.touchRender();
    }

    /// Everything the host needs to draw this layer's scrollbars, and the
    /// answer to `get_property(layer, "scrollbars")`.
    pub fn scrollbarState(self: *const Layer) ScrollbarState {
        const max = self.maxScroll();
        const off = self.effectiveScrollOffset();
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
    fn touchRender(self: *Layer) void {
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
    /// screen is active** -- the alt buffer while `on_alt`, otherwise the
    /// ring-buffer row. Every in-place mutator (`cell`, `clear`,
    /// `insertCells`/`deleteCells`, the region scrollers) goes through
    /// this so the alt screen needs no separate code path.
    fn liveRow(self: *const Layer, viewport_row: usize) []Cell {
        if (self.on_alt) {
            const start = viewport_row * self.width;
            return self.alt_cells.?[start .. start + self.width];
        }
        return self.rowSlice(self.physicalRow(viewport_row));
    }

    /// Whether a DECSTBM scroll region narrower than the full screen is
    /// in effect -- see `scroll_top`/`scroll_bot`.
    pub fn regionActive(self: *const Layer) bool {
        return self.scroll_top != 0 or self.scroll_bot != self.height - 1;
    }

    pub fn cell(self: *const Layer, row: usize, col: usize) *Cell {
        return &self.liveRow(row)[col];
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
        // every row comes straight from `alt_cells`.
        if (self.on_alt) {
            const start = row * self.width;
            return self.alt_cells.?[start .. start + self.width];
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
    fn scrollOne(self: *Layer) void {
        self.history_len = @min(self.history_len + 1, self.scrollback_rows);
        // Keep a selection pinned to its content: every row moves one step
        // further above the live viewport's top when the viewport advances
        // (see `SelectionPoint`). Drop it once an end scrolls off the top
        // of retained history -- the text it referred to is gone.
        if (self.selection) |*s| {
            s.anchor.above += 1;
            s.active.above += 1;
            const max_above = @max(s.anchor.above, s.active.above);
            if (max_above > @as(i64, @intCast(self.history_len))) self.selection = null;
        }
        // Highlights need no pinning here: they're keyed by metadata id and
        // the renderer matches them against live cell data, so they follow
        // their content automatically and an id with no matching cells left
        // just draws nothing.
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

    /// Resolves an absolute row a caller named (an explicit
    /// `set_property(cursor)`, or `drawImage`/`drawBox`/`drawIcon`'s
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
        if (self.on_alt) return @min(row, self.height - 1);
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
        self.selection = null;

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
        self.width = new_width;
        self.height = new_height;
        self.viewport_start = self.scrollback_rows;
        self.history_len = if (keep > new_height) keep - new_height else 0;
        if (self.view_scroll > self.history_len) self.view_scroll = self.history_len;

        if (self.cursor.row >= new_height) self.cursor.row = new_height - 1;
        if (self.cursor.col >= new_width) self.cursor.col = new_width - 1;

        // B1 screen model: the alt buffer is a flat width*height grid, so
        // a size change means a fresh (blank) one -- a full-screen program
        // redraws on the SIGWINCH anyway. The scroll region resets to the
        // full new height for the same reason (a program keeping margins
        // re-sends DECSTBM after a resize).
        if (self.alt_cells) |old| {
            self.alloc.free(old);
            const fresh = try self.alloc.alloc(Cell, new_width * new_height);
            for (fresh) |*c| c.* = .{};
            self.alt_cells = fresh;
        }
        self.scroll_top = 0;
        self.scroll_bot = new_height - 1;
        if (self.stashed_cursor.row >= new_height) self.stashed_cursor.row = new_height - 1;
        if (self.stashed_cursor.col >= new_width) self.stashed_cursor.col = new_width - 1;
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
    /// at column 0 of the next row rather than staircasing), `\r` returns
    /// to column 0, `\t` advances to the next `tab_width` stop, `\b` steps
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
        // The SGR pen is call-local: an `ESC [ ... m` colour is honoured
        // only for the rest of *this* `write_text`, never carried into
        // the next call. Cross-call persistence was tried and reverted --
        // every `glyphwire-shell` prompt/echo write passes the default
        // fg, so a colour a mirrored program left un-reset (a `cat`'d
        // file with raw escapes, an interrupted program) would poison the
        // prompt and everything after it. See `EscState` / `Layer.pen`.
        self.pen = .{};

        const view = try std.unicode.Utf8View.init(text);
        var it = view.iterator();
        while (it.nextCodepointSlice()) |cp_bytes| {
            if (cp_bytes.len == 1 and try self.consumeControl(cp_bytes[0])) continue;
            const eff = self.pen.resolve(fg, bg);
            // While the shifted-in charset is line drawing, a byte in
            // `` ` ``..`~` names a box-drawing/symbol glyph, not itself --
            // see `EscState`'s charset paragraph and `acsGraphic`.
            const line_drawing = if (self.shift_out) self.g1_line_drawing else self.g0_line_drawing;
            if (line_drawing and cp_bytes.len == 1 and cp_bytes[0] >= '`' and cp_bytes[0] <= '~') {
                var buf: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(acsGraphic(cp_bytes[0]), &buf) catch unreachable;
                self.putAtCursor(buf[0..n], 1, eff.fg, eff.bg, metadata_id);
                continue;
            }
            const cp = std.unicode.utf8Decode(cp_bytes) catch 0xFFFD;
            self.putAtCursor(cp_bytes, codepointWidth(cp), eff.fg, eff.bg, metadata_id);
        }
        // Don't carry a half-consumed `ESC ...` sequence into the next
        // call: a lone trailing `ESC`, a truncated `ESC [ ...`, or an
        // unterminated `ESC ] ...` (OSC) would otherwise leave the
        // machine armed and eat the start of whatever is written next
        // (glyphwire-shell's prompt, the following command's output).
        // See `EscState`.
        self.esc_state = .ground;
        self.csi_len = 0;
        self.shift_out = false;
        self.g0_line_drawing = false;
        self.g1_line_drawing = false;
        self.revision += 1;
        self.render_gen +%= 1;
    }

    /// Returns true when `byte` was consumed as a control byte (C0 control
    /// or part of an `ESC ...` sequence) and must not be placed as a
    /// grapheme; false for an ordinary printable byte the caller should
    /// draw. Only ever called with a single-byte codepoint slice, so
    /// `byte < 0x80` always holds. See `writeText`'s doc comment for the
    /// per-control semantics and `EscState` for the escape-strip rationale.
    fn consumeControl(self: *Layer, byte: u8) !bool {
        if (self.esc_state != .ground) {
            try self.stepEscape(byte);
            return true;
        }
        switch (byte) {
            0x1b => self.esc_state = .esc, // ESC: start of a sequence to strip
            '\n', 0x0b, 0x0c => { // LF, VT, FF -- all treated as newline (CR + LF)
                self.cursor.col = 0;
                self.lineFeed();
            },
            '\r' => self.cursor.col = 0, // CR
            '\t' => { // HT: to the next tab stop, clamped to the last column (no wrap)
                const stop = ((self.cursor.col / tab_width) + 1) * tab_width;
                self.cursor.col = @min(stop, self.width - 1);
            },
            0x08 => { // BS: back one column, non-destructive; a no-op at column 0
                if (self.cursor.col > 0) self.cursor.col -= 1;
            },
            0x0e => self.shift_out = true, // SO -- invoke G1 into GL
            0x0f => self.shift_out = false, // SI -- invoke G0 into GL
            // Every other C0 byte (NUL, BEL, DLE..SUB, FS..US) and DEL: dropped.
            0x00...0x07, 0x10...0x1a, 0x1c...0x1f, 0x7f => {},
            else => return false, // printable
        }
        return true;
    }

    /// Advances the escape-sequence machine by one byte while
    /// `esc_state != .ground`. For `ESC [ ...` (CSI) it buffers the
    /// parameter bytes and, on the final byte, either interprets the
    /// sequence (`execCsi`) or drops it; for `ESC ] ...` and friends it
    /// just finds the terminator and discards. See `EscState`.
    fn stepEscape(self: *Layer, byte: u8) !void {
        switch (self.esc_state) {
            .ground => unreachable,
            .esc => switch (byte) {
                '[' => {
                    self.esc_state = .csi;
                    self.csi_len = 0;
                },
                ']', 'P', 'X', '^', '_' => self.esc_state = .string,
                0x1b => {}, // ESC ESC -- stay armed for the real sequence
                '7' => { // DECSC -- save cursor
                    self.saved_cursor = self.cursor;
                    self.esc_state = .ground;
                },
                '8' => { // DECRC -- restore cursor
                    if (self.saved_cursor) |c| self.cursor = self.clampCursor(c);
                    self.esc_state = .ground;
                },
                'M' => { // RI -- reverse index (scroll down at the top margin)
                    if (self.cursor.row <= self.scroll_top) {
                        self.scrollRange(self.scroll_top, self.scroll_bot, 1, .down);
                    } else {
                        self.cursor.row -= 1;
                    }
                    self.esc_state = .ground;
                },
                'D' => { // IND -- index (line feed, no carriage return)
                    self.lineFeed();
                    self.esc_state = .ground;
                },
                'E' => { // NEL -- next line (carriage return + line feed)
                    self.cursor.col = 0;
                    self.lineFeed();
                    self.esc_state = .ground;
                },
                '(' => self.esc_state = .charset_g0, // designate G0, next byte
                ')' => self.esc_state = .charset_g1, // designate G1, next byte
                // Anything else is a short two-byte escape (or the ST
                // half of `ESC \`) -- it ends here.
                else => self.esc_state = .ground,
            },
            .csi => {
                if (byte >= 0x40 and byte <= 0x7e) {
                    // Final byte: act on it, then done.
                    try self.execCsi(byte);
                    self.esc_state = .ground;
                    self.csi_len = 0;
                } else if (self.csi_len < self.csi_buf.len) {
                    // Parameter (0x30-0x3f) / intermediate (0x20-0x2f)
                    // byte -- accumulate for `execCsi`.
                    self.csi_buf[self.csi_len] = byte;
                    self.csi_len += 1;
                }
            },
            .string => switch (byte) {
                0x07 => self.esc_state = .ground, // BEL terminator
                0x1b => self.esc_state = .esc, // ESC of an `ESC \` (ST) terminator
                else => {},
            },
            // `0` is the VT100 special graphics/line-drawing set; anything
            // else (`B` for US-ASCII, or any other 94-charset final) is
            // treated as plain ASCII. See `g0_line_drawing`/`g1_line_drawing`.
            .charset_g0 => {
                self.g0_line_drawing = byte == '0';
                self.esc_state = .ground;
            },
            .charset_g1 => {
                self.g1_line_drawing = byte == '0';
                self.esc_state = .ground;
            },
        }
    }

    /// Acts on a completed `ESC [ <params> <final>` sequence --
    /// `csi_buf[0..csi_len]` holds the parameter/intermediate bytes.
    /// Only the finals glyphwire interprets are handled; every other
    /// final returns without effect (the sequence's bytes were already
    /// kept off the grid by `stepEscape`). See `EscState` and, for the
    /// B1 screen-model finals, decisions.md's VT fallback section.
    fn execCsi(self: *Layer, final: u8) !void {
        const params = self.csi_buf[0..self.csi_len];

        // `ESC [ ! p` -- DECSTR soft terminal reset: scroll region back to
        // full, cursor shown, saved cursor and SGR pen cleared. Per spec
        // it does *not* move the cursor, clear the screen, or leave the
        // alt screen -- exactly what glyphwire-shell wants to undo after a
        // pty child that may have died mid-screen.
        if (final == 'p' and params.len == 1 and params[0] == '!') {
            self.scroll_top = 0;
            self.scroll_bot = self.height - 1;
            self.cursor_visible = true;
            self.saved_cursor = null;
            self.pen = .{};
            return;
        }

        // `ESC [ ? ...` -- DEC private modes and DECRQM.
        if (params.len > 0 and params[0] == '?') {
            self.execPrivateCsi(final, params[1..]);
            return;
        }
        // `ESC [ > ...` / `ESC [ = ...` -- device attributes. Answer a
        // secondary DA (`> c`); skip the rest.
        if (params.len > 0 and (params[0] == '>' or params[0] == '=')) {
            if (final == 'c') self.queueReply("\x1b[>0;10;1c");
            return;
        }

        const n1 = @max(csiParam(params, 0, 1), 1); // count / distance, default 1

        switch (final) {
            'm' => self.pen.applySgr(params),
            'A', 'B', 'C', 'D', 'G', 'H', 'f', 'd' => self.csiCursor(final, params),
            'J' => self.csiEraseDisplay(csiParam(params, 0, 0)),
            'K' => self.csiEraseLine(csiParam(params, 0, 0)),
            'r' => self.setScrollRegion(params), // DECSTBM
            'S' => self.scrollRange(self.scroll_top, self.scroll_bot, n1, .up), // SU
            'T' => self.scrollRange(self.scroll_top, self.scroll_bot, n1, .down), // SD
            'L' => if (self.rowInRegion(self.cursor.row)) // IL
                self.scrollRange(self.cursor.row, self.scroll_bot, n1, .down),
            'M' => if (self.rowInRegion(self.cursor.row)) // DL
                self.scrollRange(self.cursor.row, self.scroll_bot, n1, .up),
            '@' => self.insertCells(n1), // ICH
            'P' => self.deleteCells(n1), // DCH
            'X' => self.clear(self.cursor.row, self.cursor.col, 1, n1), // ECH
            's' => self.saved_cursor = self.cursor, // ANSI.SYS save cursor
            'u' => if (self.saved_cursor) |c| { // ANSI.SYS restore cursor
                self.cursor = self.clampCursor(c);
            },
            'n' => self.csiDsr(csiParam(params, 0, 0)), // DSR
            'c' => self.queueReply("\x1b[?1;2c"), // primary DA -- VT100 + AVO
            else => {}, // discarded, same as the old stripper
        }
    }

    /// `ESC [ ? <params> <final>` -- DEC private modes (`h`/`l`) and
    /// DECRQM (`$ p`). Only the modes the screen model actually acts on
    /// are handled here; the ones the pty input path cares about (`?1`,
    /// `?2004`, `?1000`..`?1006`) are left to glyphwire-shell's
    /// `pty.ModeTracker`, which sniffs the same byte stream.
    fn execPrivateCsi(self: *Layer, final: u8, params: []const u8) void {
        // DECRQM: `CSI ? Ps $ p` -- the `$` intermediate is the last
        // buffered byte before the `p` final.
        if (final == 'p' and params.len > 0 and params[params.len - 1] == '$') {
            self.replyDecrqm(params[0 .. params.len - 1]);
            return;
        }
        if (final != 'h' and final != 'l') return;
        const set = final == 'h';
        var it = std.mem.splitScalar(u8, params, ';');
        while (it.next()) |tok| {
            const n = std.fmt.parseInt(u32, tok, 10) catch continue;
            switch (n) {
                1 => self.app_cursor_keys = set, // DECCKM (see the field doc)
                25 => self.cursor_visible = set, // DECTCEM
                47, 1047, 1049 => if (set) {
                    self.enterAltScreen() catch {};
                } else self.exitAltScreen(),
                else => {},
            }
        }
    }

    fn rowInRegion(self: *const Layer, row: usize) bool {
        return row >= self.scroll_top and row <= self.scroll_bot;
    }

    fn clampCursor(self: *const Layer, c: Cursor) Cursor {
        return .{
            .row = @min(c.row, self.height - 1),
            .col = @min(c.col, self.width - 1),
        };
    }

    /// `ESC [ <top> ; <bot> r` -- DECSTBM. 1-based, inclusive; an omitted
    /// or degenerate pair (or `ESC [ r`) resets to the full screen. Homes
    /// the cursor, matching a real terminal.
    fn setScrollRegion(self: *Layer, params: []const u8) void {
        const top = @max(csiParam(params, 0, 1), 1) - 1;
        const bot = @max(csiParam(params, 1, self.height), 1) - 1;
        if (top >= bot or bot >= self.height) {
            self.scroll_top = 0;
            self.scroll_bot = self.height - 1;
        } else {
            self.scroll_top = top;
            self.scroll_bot = bot;
        }
        self.cursor = .{ .row = self.scroll_top, .col = 0 };
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
        if (bot < top or bot >= self.height) return;
        const span = bot - top + 1;
        const n = @min(n_in, span);
        if (n == 0) return;
        switch (dir) {
            .up => {
                var r = top;
                while (r + n <= bot) : (r += 1) @memcpy(self.liveRow(r), self.liveRow(r + n));
                r = bot + 1 - n;
                while (r <= bot) : (r += 1) blankRow(self.liveRow(r));
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
                    blankRow(self.liveRow(r));
                }
            },
        }
        self.revision += 1;
        self.render_gen +%= 1;
    }

    fn blankRow(row: []Cell) void {
        for (row) |*c| c.* = .{};
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
    /// advance that feeds the primary screen's scrollback.
    fn lineFeed(self: *Layer) void {
        if (self.on_alt or self.regionActive()) {
            if (self.cursor.row >= self.scroll_bot) {
                self.scrollRange(self.scroll_top, self.scroll_bot, 1, .up);
            } else if (self.cursor.row + 1 < self.height) {
                self.cursor.row += 1;
            }
        } else {
            self.cursor.row = self.resolveRow(self.cursor.row + 1);
        }
    }

    /// `CSI ? 1049 h` (or `?47` / `?1047`) -- switch to the alternate
    /// screen: stash the primary cursor, home, and show a cleared
    /// full-screen buffer with no scrollback. All three variants are
    /// treated alike (save cursor + clear on entry) -- the B1
    /// simplification; virtually every modern full-screen program uses
    /// `?1049`.
    fn enterAltScreen(self: *Layer) !void {
        if (self.on_alt) return;
        if (self.alt_cells == null)
            self.alt_cells = try self.alloc.alloc(Cell, self.width * self.height);
        for (self.alt_cells.?) |*c| c.* = .{};
        self.stashed_cursor = self.cursor;
        self.cursor = .{};
        self.scroll_top = 0;
        self.scroll_bot = self.height - 1;
        self.on_alt = true;
        self.revision += 1;
        self.render_gen +%= 1;
    }

    /// `CSI ? 1049 l` -- back to the primary screen (its scrollback and
    /// contents were never touched), restoring the stashed cursor.
    fn exitAltScreen(self: *Layer) void {
        if (!self.on_alt) return;
        self.on_alt = false;
        self.cursor = self.clampCursor(self.stashed_cursor);
        self.scroll_top = 0;
        self.scroll_bot = self.height - 1;
        self.revision += 1;
        self.render_gen +%= 1;
    }

    /// `CSI 5 n` / `CSI 6 n` -- device status / cursor position report.
    fn csiDsr(self: *Layer, ps: usize) void {
        switch (ps) {
            5 => self.queueReply("\x1b[0n"), // "terminal OK"
            6 => { // CPR -- 1-based row;col
                var b: [32]u8 = undefined;
                const s = std.fmt.bufPrint(&b, "\x1b[{d};{d}R", .{
                    self.cursor.row + 1, self.cursor.col + 1,
                }) catch return;
                self.queueReply(s);
            },
            else => {},
        }
    }

    /// DECRQM answer: `CSI ? Ps ; V $ y`, V = 1 set, 2 reset, 0 not
    /// recognized. Only the modes the screen model tracks report a real
    /// value.
    fn replyDecrqm(self: *Layer, ps_tok: []const u8) void {
        const n = std.fmt.parseInt(u32, std.mem.trim(u8, ps_tok, " ;"), 10) catch return;
        const v: u8 = switch (n) {
            1 => if (self.app_cursor_keys) 1 else 2,
            25 => if (self.cursor_visible) 1 else 2,
            47, 1047, 1049 => if (self.on_alt) 1 else 2,
            else => 0,
        };
        var b: [32]u8 = undefined;
        const s = std.fmt.bufPrint(&b, "\x1b[?{d};{d}$y", .{ n, v }) catch return;
        self.queueReply(s);
    }

    /// Appends `bytes` to the pending terminal reply (see `reply_buf`).
    /// Silently drops anything past the buffer -- replies are a handful of
    /// bytes each and never legitimately overflow 96.
    fn queueReply(self: *Layer, bytes: []const u8) void {
        const room = self.reply_buf.len - self.reply_len;
        const n = @min(bytes.len, room);
        @memcpy(self.reply_buf[self.reply_len..][0..n], bytes[0..n]);
        self.reply_len += n;
    }

    /// The bytes this layer owes the program writing to it (a `CSI 6n` /
    /// DA / DECRQM answer), or null if none are pending. The returned
    /// slice is valid until the next `writeText`. Drained by the
    /// dispatcher after each `write_text`.
    pub fn takeReply(self: *Layer) ?[]const u8 {
        if (self.reply_len == 0) return null;
        const s = self.reply_buf[0..self.reply_len];
        self.reply_len = 0;
        return s;
    }

    /// Reads the `index`-th `;`-separated numeric parameter from a CSI
    /// parameter string, returning `default_val` for a missing or empty
    /// field (VT convention: an omitted parameter takes its default).
    fn csiParam(params: []const u8, index: usize, default_val: usize) usize {
        var it = std.mem.splitScalar(u8, params, ';');
        var i: usize = 0;
        while (it.next()) |tok| : (i += 1) {
            if (i == index) {
                if (tok.len == 0) return default_val;
                return std.fmt.parseInt(usize, tok, 10) catch default_val;
            }
        }
        return default_val;
    }

    /// Cursor-movement CSI finals. **Every one clamps to the screen and
    /// never scrolls** -- a real terminal only scrolls on a line feed /
    /// `IND` / `RI` / an explicit scroll command, never on a cursor
    /// address. (This used to route downward/absolute-row moves through
    /// `resolveRow`, which scrolls; harmless for Phase A's colour+
    /// progress-bar output, but a full-screen program that positions to
    /// its last row -- `less`'s status line -- would scroll the whole
    /// primary layer one row per keypress.)
    fn csiCursor(self: *Layer, final: u8, params: []const u8) void {
        const last_row = self.height - 1;
        switch (final) {
            'A' => self.cursor.row -|= @max(csiParam(params, 0, 1), 1),
            'B' => self.cursor.row = @min(self.cursor.row + @max(csiParam(params, 0, 1), 1), last_row),
            'C' => self.cursor.col = @min(self.cursor.col + @max(csiParam(params, 0, 1), 1), self.width - 1),
            'D' => self.cursor.col -|= @max(csiParam(params, 0, 1), 1),
            'G' => self.cursor.col = @min(@max(csiParam(params, 0, 1), 1) - 1, self.width - 1),
            'd' => self.cursor.row = @min(@max(csiParam(params, 0, 1), 1) - 1, last_row),
            'H', 'f' => {
                self.cursor.row = @min(@max(csiParam(params, 0, 1), 1) - 1, last_row);
                self.cursor.col = @min(@max(csiParam(params, 1, 1), 1) - 1, self.width - 1);
            },
            else => unreachable,
        }
    }

    /// `ESC [ <n> K` -- erase in line: 0 = cursor to end of line
    /// (default), 1 = start of line to cursor, 2 = whole line. Blanks
    /// cells in the cursor's row only; doesn't move the cursor.
    fn csiEraseLine(self: *Layer, mode: usize) void {
        switch (mode) {
            0 => self.clear(self.cursor.row, self.cursor.col, 1, self.width),
            1 => self.clear(self.cursor.row, 0, 1, self.cursor.col + 1),
            2 => self.clear(self.cursor.row, 0, 1, self.width),
            else => {},
        }
    }

    /// `ESC [ <n> J` -- erase in display: 0 = cursor to end of screen
    /// (default), 1 = start of screen to cursor, 2/3 = whole screen.
    /// Blanks cells; doesn't move the cursor (a program that wants the
    /// cursor homed sends `ESC [ H` too, which `csiCursor` handles).
    fn csiEraseDisplay(self: *Layer, mode: usize) void {
        switch (mode) {
            0 => {
                self.clear(self.cursor.row, self.cursor.col, 1, self.width);
                if (self.cursor.row + 1 < self.height)
                    self.clear(self.cursor.row + 1, 0, self.height, self.width);
            },
            1 => {
                if (self.cursor.row > 0) self.clear(0, 0, self.cursor.row, self.width);
                self.clear(self.cursor.row, 0, 1, self.cursor.col + 1);
            },
            2, 3 => self.clear(0, 0, self.height, self.width),
            else => {},
        }
    }

    /// Places one grapheme cluster at the cursor. `w` is its East Asian
    /// display width in cells (1 or 2). A width-2 cluster occupies a
    /// `.wide_lead` cell holding the grapheme plus a blank `.wide_spacer`
    /// to its right; the spacer copies the lead's fg/bg and `metadata_id`
    /// so a background spans the pair and a hit-test on either half
    /// resolves the same. A width-2 cluster that would straddle the right
    /// edge wraps to the next row first. Overwriting either half of an
    /// existing wide pair blanks its orphaned partner.
    fn putAtCursor(self: *Layer, bytes: []const u8, w: u2, fg: Color, bg: ?Background, metadata_id: ?MetadataHandle) void {
        if (self.cursor.col + w > self.width) {
            self.cursor.col = 0;
            self.cursor.row += 1;
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
        if (bg) |b| c.style.bg = b;
        c.metadata_id = metadata_id;
        c.fg_icon = null;
        c.wide = if (w == 2) .wide_lead else .narrow;

        if (w == 2) {
            // The spacer renders nothing of its own; give it the lead's
            // fully resolved style so the background spans the pair, and
            // the lead's `metadata_id` so a hit-test on either half maps
            // to the same entry.
            const s = self.cell(row, col + 1);
            s.* = .{ .style = c.style, .metadata_id = metadata_id, .wide = .wide_spacer };
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
        if (count == 0 or self.cursor.col >= self.width) return;
        const row = self.liveRow(self.cursor.row);
        const col = self.cursor.col;
        const n = @min(count, self.width - col);
        const tail_len = self.width - col - n;
        std.mem.copyBackwards(Cell, row[col + n ..][0..tail_len], row[col..][0..tail_len]);
        for (row[col..][0..n]) |*c| c.* = .{};
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
        if (count == 0 or self.cursor.col >= self.width) return;
        const row = self.liveRow(self.cursor.row);
        const col = self.cursor.col;
        const n = @min(count, self.width - col);
        const tail_len = self.width - col - n;
        std.mem.copyForwards(Cell, row[col..][0..tail_len], row[col + n ..][0..tail_len]);
        for (row[col + tail_len ..][0..n]) |*c| c.* = .{};
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
    ) void {
        const s: f32 = if (scale > 0) scale else 1.0;
        // Source pixels each cell samples along each axis. At `s == 1` this
        // is exactly `cell_px`, so `src_step * k` lands on the same
        // integers `k * cell_px` did before scale existed and every
        // natural-size draw is unchanged.
        const src_step_x: f32 = @as(f32, @floatFromInt(cell_px_w)) / s;
        const src_step_y: f32 = @as(f32, @floatFromInt(cell_px_h)) / s;

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

            const offset_y: u32 = @intFromFloat(@round(@as(f32, @floatFromInt(img_row)) * src_step_y));
            if (offset_y >= img_h) break;

            var c = col;
            while (c < col_end) : (c += 1) {
                const offset_x: u32 = @intFromFloat(@round(@as(f32, @floatFromInt(c - col)) * src_step_x));
                if (offset_x >= img_w) continue;

                self.setCellImage(display_row, c, handle, offset_x, offset_y, s);
            }
        }
        self.revision += 1;
        self.render_gen +%= 1;
    }

    fn setCellImage(self: *Layer, row: usize, col: usize, handle: ImageHandle, offset_x: u32, offset_y: u32, scale: f32) void {
        self.cell(row, col).style.bg = .{ .image = .{ .handle = handle, .offset_x = offset_x, .offset_y = offset_y, .scale = scale } };
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
        self.revision += 1;
        self.render_gen +%= 1;
    }

    /// Same as `drawIcon`, but sets `Cell.fg_icon` instead of `style.bg`
    /// -- see that field's doc comment. Leaves `style.bg` (and whatever
    /// background is already there, e.g. a `drawBox` fill) untouched, so
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
    pub fn tagMetadata(self: *Layer, row: usize, col: usize, metadata_id: ?MetadataHandle) void {
        const resolved_row = self.resolveRow(row);
        if (col >= self.width) return;
        self.cell(resolved_row, col).metadata_id = metadata_id;
        self.revision += 1;
        self.render_gen +%= 1;
    }

    /// The 9 resolved tiles a `draw_box` call needs -- corners, edges, and
    /// a fill, per decisions.md's Icon section / roadmap.md's Phase 3.6.
    /// Just handles, same as `draw_icon`: each tile is drawn with the
    /// `.icon` Background variant (`scale: .stretch` -- see `IconScale`'s
    /// doc comment for why tiles stretch to fill their cell exactly rather
    /// than `drawIcon`'s default aspect-preserved `fit`), not `.image`'s
    /// clip-and-offset scheme, so there's no per-tile width/height to
    /// carry here either. Resolving these (by
    /// `"{style}-tl"` etc. against the icon catalog) is dispatch.zig's
    /// job; `Layer.drawBox` just consumes the result, so it's testable
    /// headlessly without going through name resolution.
    pub const BoxTiles = struct {
        tl: ImageHandle,
        t: ImageHandle,
        tr: ImageHandle,
        l: ImageHandle,
        fill: ImageHandle,
        r: ImageHandle,
        bl: ImageHandle,
        b: ImageHandle,
        br: ImageHandle,
    };

    /// How `drawBox` composes its 9 tiles across a rectangle bigger than
    /// 3x3 cells:
    /// - `tile` (the original, still-default behavior): every cell gets
    ///   one full copy of its role's tile, independently stretched to fill
    ///   just that cell -- fine for a border/fill that's meant to repeat,
    ///   but a repeated slice of a gradient image bands rather than fades.
    /// - `stretch`: corners are still one full tile each (they're always
    ///   exactly one cell), but each edge/fill role's *single* source
    ///   image is treated as one continuous picture spanning the whole
    ///   run it appears in -- `t`/`b` across every interior column,
    ///   `l`/`r` across every interior row, `fill` across the whole
    ///   interior rectangle -- so a cell partway along the run gets that
    ///   fraction of the image (`IconBg.src_l/src_t/src_r/src_b`)
    ///   stretched to fill it, reassembling into one smooth image (e.g. a
    ///   top-to-bottom gradient) across however many cells the box turns
    ///   out to span.
    pub const BoxMode = enum { tile, stretch };

    /// Draws a `rows x cols` box anchored at `(row, col)` (clamped to the
    /// layer's own bounds) using `tiles`: each cell gets exactly one tile,
    /// chosen by whether it's on the box's top/bottom row and/or
    /// left/right column, stretched to fill that cell exactly (`IconScale`'s
    /// `.stretch`). The bundled tile art is drawn with its border line
    /// hugging the tile's own outer edge rather than centered, so a
    /// caller can still put a character in a border cell (`write_text`
    /// only touches `Cell.grapheme`/`fg`, independent of `bg`) without it
    /// colliding with the line -- see decisions.md's Icon section on why
    /// `draw_box` gets this treatment now, same as icons. A 1x1 or
    /// 1xN/Nx1 box collapses reasonably: the top/left role is checked
    /// before bottom/right, so a single-row or single-column box shows
    /// corners/top/left tiles rather than picking arbitrarily.
    pub fn drawBox(
        self: *Layer,
        tiles: BoxTiles,
        mode: BoxMode,
        row: usize,
        col: usize,
        rows: usize,
        cols: usize,
    ) void {
        if (rows == 0 or cols == 0) return;

        const anchor_row = self.resolveRow(row);
        const row_end = @min(anchor_row + rows, self.height);
        const col_end = @min(col + cols, self.width);
        const last_row = anchor_row + rows - 1;
        const last_col = col + cols - 1;

        // Interior span sizes, for `.stretch`'s per-cell fractions below --
        // only ever consulted by a branch reached when there's at least
        // one interior row/col on that axis (see the branches' comments),
        // so this never divides by 0 despite looking unguarded.
        const interior_h: f32 = @floatFromInt(last_col -| col -| 1);
        const interior_v: f32 = @floatFromInt(last_row -| anchor_row -| 1);

        var r = anchor_row;
        while (r < row_end) : (r += 1) {
            const is_top = r == anchor_row;
            const is_bottom = r == last_row;
            const v_index: f32 = @floatFromInt(r - anchor_row -| 1);

            var c = col;
            while (c < col_end) : (c += 1) {
                const is_left = c == col;
                const is_right = c == last_col;
                const h_index: f32 = @floatFromInt(c - col -| 1);
                const is_corner = (is_top or is_bottom) and (is_left or is_right);

                const tile = if (is_top and is_left)
                    tiles.tl
                else if (is_top and is_right)
                    tiles.tr
                else if (is_bottom and is_left)
                    tiles.bl
                else if (is_bottom and is_right)
                    tiles.br
                else if (is_top)
                    tiles.t
                else if (is_bottom)
                    tiles.b
                else if (is_left)
                    tiles.l
                else if (is_right)
                    tiles.r
                else
                    tiles.fill;

                // A corner is always exactly one cell, so it never gets
                // sliced regardless of mode. `t`/`b` (reached only when
                // not a corner, i.e. `interior_h >= 1`) slice horizontally;
                // `l`/`r` (only reached when `interior_v >= 1`) slice
                // vertically; `fill` (only reached when both are `>= 1`)
                // slices both.
                const src: [4]f32 = if (mode == .tile or is_corner)
                    .{ 0, 0, 1, 1 }
                else if (is_top or is_bottom)
                    .{ h_index / interior_h, 0, (h_index + 1) / interior_h, 1 }
                else if (is_left or is_right)
                    .{ 0, v_index / interior_v, 1, (v_index + 1) / interior_v }
                else
                    .{ h_index / interior_h, v_index / interior_v, (h_index + 1) / interior_h, (v_index + 1) / interior_v };

                self.cell(r, c).style.bg = .{ .icon = .{
                    .handle = tile,
                    .scale = .stretch,
                    .src_l = src[0],
                    .src_t = src[1],
                    .src_r = src[2],
                    .src_b = src[3],
                } };
            }
        }
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
        if (row >= self.height or col >= self.width or rows == 0 or cols == 0) return;

        const row_end = @min(row + rows, self.height);
        const col_end = @min(col + cols, self.width);

        var r = row;
        while (r < row_end) : (r += 1) {
            for (self.liveRow(r)[col..col_end]) |*cell_ptr| cell_ptr.* = .{};
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
            .viewport => .{ .viewport = .{ .cols = self.viewportCols(), .rows = self.viewportRows() } },
            .scroll_offset => .{ .scroll_offset = self.effectiveScrollOffset() },
            .scrollbars => .{ .scrollbars = self.scrollbarState() },
            .content_extent => .{ .content_extent = blk: {
                const c = self.effectiveContent();
                break :blk .{ .cols = c.col, .rows = c.row };
            } },
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
            .viewport => |v| {
                self.viewport_cols = v.cols;
                self.viewport_rows = v.rows;
                // A smaller content window can strand the scroll offset
                // past its new maximum.
                _ = self.setScrollOffset(self.effectiveScrollOffset());
            },
            .scroll_offset => |off| _ = self.setScrollOffset(off),
            .scrollbars => |sb| self.scrollbars = .{ .vertical = sb.vertical, .horizontal = sb.horizontal },
            .content_extent => |v| self.setContentExtent(
                if (v.cols == 0 and v.rows == 0) null else .{ .row = v.rows, .col = v.cols },
            ),
        }
        // `.position` moves where the layer composites; `.cursor` can scroll
        // the ring buffer via `resolveRow` (bumped in `scrollOne`) and the
        // caret is an immediate draw either way -- bump unconditionally,
        // this path is never per-frame.
        self.touchRender();
    }

    // ── Selection ───────────────────────────────────────────────────────
    //
    // A linear selection over the layer's cell grid, including its
    // scrollback. State is just `self.selection` (see `Selection` /
    // `SelectionPoint`); these are the operations the wire messages and
    // glyphwire-host's in-process path drive it through, plus the two
    // read helpers the renderer and `get_selection_text` need.

    /// Starts (or replaces) the selection: `anchor` is the fixed end,
    /// `active` the moving one.
    pub fn setSelection(self: *Layer, anchor: SelectionPoint, active: SelectionPoint) void {
        self.selection = .{ .anchor = anchor, .active = active };
        self.touchRender();
    }

    /// Moves the selection's active (moving) end -- a no-op when nothing
    /// is selected, so a stray drag/extend after a `clear` does nothing.
    pub fn updateSelectionActive(self: *Layer, active: SelectionPoint) void {
        if (self.selection) |*s| {
            s.active = active;
            self.touchRender();
        }
    }

    pub fn clearSelection(self: *Layer) void {
        self.selection = null;
        self.touchRender();
    }

    /// Whether `id` is currently highlighted -- the per-cell test the
    /// renderer runs against `Cell.metadata_id`. `null` (an untagged cell)
    /// is never highlighted.
    pub fn isHighlighted(self: *const Layer, id: ?MetadataHandle) bool {
        const want = id orelse return false;
        for (self.highlighted_ids.items) |h| {
            if (h == want) return true;
        }
        return false;
    }

    /// Adds `id` to the highlight set if absent, removes it if present
    /// (`toggle_highlight`).
    pub fn toggleHighlightId(self: *Layer, id: MetadataHandle) !void {
        for (self.highlighted_ids.items, 0..) |h, i| {
            if (h == id) {
                _ = self.highlighted_ids.swapRemove(i);
                self.touchRender();
                return;
            }
        }
        try self.highlighted_ids.append(self.alloc, id);
        self.touchRender();
    }

    /// Replaces the whole highlight set with `ids` (`set_highlight`). An
    /// empty slice clears it, same as `clearHighlightIds`.
    pub fn setHighlightIds(self: *Layer, ids: []const MetadataHandle) !void {
        self.highlighted_ids.clearRetainingCapacity();
        try self.highlighted_ids.appendSlice(self.alloc, ids);
        self.touchRender();
    }

    /// Drops every highlighted id (`clear_highlight`).
    pub fn clearHighlightIds(self: *Layer) void {
        self.highlighted_ids.clearRetainingCapacity();
        self.touchRender();
    }

    /// The cell row `above` rows above the live viewport's top row (see
    /// `SelectionPoint`), or null if that row isn't currently retained.
    /// `above <= 0` is a live viewport row (`-above`); `above >= 1` walks
    /// up into scrollback.
    fn rowForAbove(self: *const Layer, above: i64) ?[]const Cell {
        if (above > 0) {
            if (above - 1 >= @as(i64, @intCast(self.history_len))) return null;
            return self.scrollbackRow(@intCast(above - 1));
        }
        const live_row: i64 = -above;
        if (live_row >= @as(i64, @intCast(self.height))) return null;
        return self.rowSlice(self.physicalRow(@intCast(live_row)));
    }

    /// For the renderer: the `[start, end)` column range selected on the
    /// row `above` rows above the live viewport's top (see
    /// `SelectionPoint`), or null if that row is outside the selection.
    /// Linear model -- interior rows select their whole width, the first
    /// and last row are clipped to the selection's start/end column.
    pub fn selectionColRange(self: *const Layer, above: i64) ?struct { start: usize, end: usize } {
        const sel = self.selection orelse return null;
        if (sel.isEmpty()) return null;
        const o = sel.ordered();
        if (above > o.start.above or above < o.end.above) return null;
        const lo: usize = if (above == o.start.above) @min(o.start.col, self.width) else 0;
        var hi: usize = if (above == o.end.above) o.end.col + 1 else self.width;
        if (hi > self.width) hi = self.width;
        if (lo >= hi) return null;
        return .{ .start = lo, .end = hi };
    }

    /// The selected text, or null when nothing is selected (a zero-width
    /// selection returns `""`). Rows are joined with `\n`, each row's
    /// trailing blanks trimmed; a blank cell inside the range becomes a
    /// space, a wide character's spacer half is skipped. A row no longer
    /// retained in scrollback contributes an empty line. Caller owns the
    /// result.
    pub fn selectionText(self: *const Layer, alloc: std.mem.Allocator) !?[]u8 {
        const sel = self.selection orelse return null;
        if (sel.isEmpty()) return try alloc.dupe(u8, "");
        const o = sel.ordered();

        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(alloc);

        var above = o.start.above;
        while (above >= o.end.above) : (above -= 1) {
            const lo: usize = if (above == o.start.above) @min(o.start.col, self.width) else 0;
            var hi: usize = if (above == o.end.above) o.end.col + 1 else self.width;
            if (hi > self.width) hi = self.width;

            const line_start = out.items.len;
            if (lo < hi) {
                if (self.rowForAbove(above)) |cells| {
                    var col = lo;
                    while (col < hi) : (col += 1) {
                        const c = cells[col];
                        if (c.wide == .wide_spacer) continue;
                        const g = c.grapheme();
                        if (g.len == 0) try out.append(alloc, ' ') else try out.appendSlice(alloc, g);
                    }
                }
            }
            while (out.items.len > line_start and out.items[out.items.len - 1] == ' ') {
                out.items.len -= 1;
            }
            if (above != o.end.above) try out.append(alloc, '\n');
        }

        return try out.toOwnedSlice(alloc);
    }
};

// ─── Table ───────────────────────────────────────────────────────────────
//
// A table is structured, server-owned data (columns, rows of typed cells,
// sort state, style) that *compiles* into ordinary cells on its owning
// layer whenever it changes -- not a live per-frame render path of its
// own. This is the whole reason adding tables needed no changes to
// glyphwire-host's render loop at all: that loop already draws whatever's
// sitting in a layer's cell buffer, regardless of what put it there
// (`write_text`, `draw_icon`, or now `Table.render`). It's also why a
// table survives the process that created it (e.g. `glyphwire-ls -l`)
// exiting, and why re-sorting later is just re-deriving row order from
// the same stored typed values and repainting -- no client needs to be
// running for either.
//
// A table is a component of the layer it's drawn on (`Layer.tables`),
// not a parallel object tree the way `Layer` itself is under `Context` --
// see decisions.md's Table section.

/// Server-generated handle for a table created via `create_table`.
/// Allocated from `Context.next_table_handle`, a single counter shared
/// across every layer -- same numbering convention `LayerHandle`/
/// `ImageHandle`/`MetadataHandle` already use -- even though the `Table`
/// value itself is stored on whichever `Layer` it was created on, not on
/// `Context` directly.
pub const TableHandle = u32;

pub const TableError = error{
    UnknownTable,
    /// `table_set_rows`: a row's cell count didn't match the table's
    /// column count.
    TableRowShapeMismatch,
};

/// How a column's cells compare when sorted -- `.text` compares
/// `SortKey.text` lexically, `.number` compares `SortKey.number`
/// numerically. Decided over sorting on display text alone specifically
/// so e.g. a Size column sorts `900 B` before `1.2 KB` correctly instead
/// of lexically ("1" before "9").
pub const ColumnKind = enum { text, number };

pub const SortDirection = enum { none, ascending, descending };

/// The glyph drawn after the active sort column's header name -- a filled
/// triangle pointing the way its rows are ordered. `.none` yields an
/// empty string: an unsorted table, and a column that is merely
/// `sortable` but not the current sort, show nothing extra (decided in
/// the sort feature's clarifying questions -- no persistent "click me"
/// affordance). One display cell wide; `Table.headerColWidth` reserves it
/// plus one leading space (`sort_arrow_cells`).
pub fn sortArrowGlyph(dir: SortDirection) []const u8 {
    return switch (dir) {
        .none => "",
        .ascending => "\u{25B2}", // ▲
        .descending => "\u{25BC}", // ▼
    };
}

/// Display cells the sort arrow plus its separating space occupy in a
/// header cell -- what `Table.headerColWidth` adds on top of the column
/// name's own width for the active sort column.
const sort_arrow_cells: usize = 2;

/// One column's shape -- display name (the header cell's text),
/// sortability, and sizing. `width` is the column's content width in
/// cells; `min_width` is a floor, same as the client-composited table
/// prototype's `ColumnDef` (`src/table.zig`, which this supersedes as
/// the source of table layout -- see decisions.md's Table section).
pub const TableColumn = struct {
    name: []u8,
    kind: ColumnKind = .text,
    sortable: bool = false,
    width: usize,
    min_width: usize = 1,
    h_align: HAlign = .start,

    pub fn deinit(self: TableColumn, alloc: std.mem.Allocator) void {
        alloc.free(self.name);
    }
};

/// A cell's value to compare against another cell in the same column
/// when sorting -- distinct from `TableCell.display` (what's actually
/// drawn): a Size column might display `"1.2 KB"` but needs to sort on
/// the raw byte count. Every cell has one (`handleTableSetRows` defaults
/// it to a copy of `display` when the wire omits an explicit `sort_key`),
/// so sorting never needs a "what do I compare when there's nothing to
/// compare" fallback.
pub const SortKey = union(enum) {
    text: []u8,
    number: f64,

    pub fn deinit(self: SortKey, alloc: std.mem.Allocator) void {
        switch (self) {
            .text => |t| alloc.free(t),
            .number => {},
        }
    }
};

/// One cell of one row. `icon` is a resolved image handle (looked up by
/// name against the icon catalog at `table_set_rows` time -- see
/// `handleTableSetRows` -- same "fail loud on an unknown name at the
/// point of use" treatment `draw_icon`'s `name` already gets), drawn
/// alongside `display` within the column's own width rather than
/// needing a dedicated icon-only column -- e.g. glyphwire-ls's Name
/// column carries both a per-entry icon and the filename in one cell.
/// `fg` is per-cell (`null` means `default_style.fg`) since a table has
/// no notion of "kind" of its own -- glyphwire-ls's directory/symlink/
/// file coloring is caller data, same as it always was.
pub const TableCell = struct {
    display: []u8,
    sort_key: SortKey,
    icon: ?ImageHandle = null,
    fg: ?Color = null,
    metadata_id: ?MetadataHandle = null,

    pub fn deinit(self: TableCell, alloc: std.mem.Allocator) void {
        alloc.free(self.display);
        self.sort_key.deinit(alloc);
    }
};

pub const TableRow = struct {
    cells: []TableCell,

    pub fn deinit(self: TableRow, alloc: std.mem.Allocator) void {
        for (self.cells) |c| c.deinit(alloc);
        alloc.free(self.cells);
    }
};

/// Rendering knobs for a table that aren't per-column -- same shape (and
/// same box-tile-catalog reuse for borders) `src/table.zig`'s
/// `TableStyle` had client-side. `row_height` (cells per body row, `1`
/// the default) is the "large format" option added mid-development of
/// the client-composited prototype, carried forward here -- a
/// server-painted table sidesteps the scrolling bug class that
/// prototype hit near a layer's bottom edge entirely, since `Table.render`
/// never advances a cursor or triggers `Layer.resolveRow`'s scrolling at
/// all (see that method's doc comment).
pub const TableStyle = struct {
    borders: bool = true,
    header_separator: bool = true,
    /// Always an owned copy (defaulted to a duped `"box"` by whoever
    /// constructs a `TableStyle`, e.g. `handleCreateTable`/
    /// `handleTableSetStyle`, if the wire omits it) so `deinit` can
    /// always safely free it.
    box_style: []u8,
    alt_row_bg: ?Color = null,
    header_fg: ?Color = null,
    header_bg: ?Color = null,
    row_height: usize = 1,
    /// Upper bound, in pixels, on a body-cell icon's rendered height --
    /// `writeBodyRow` caps `.natural` scaling to `min(row_height *
    /// cell_px_h, max_icon_px)`. `null` means "no extra cap", the row
    /// height alone bounds it (the historical behaviour). `glyphwire-ls`
    /// sets it so a tall `-l -L` row still renders its icon at the same
    /// size the icon grid uses, regardless of the source art's resolution.
    max_icon_px: ?u32 = null,

    pub fn deinit(self: TableStyle, alloc: std.mem.Allocator) void {
        alloc.free(self.box_style);
    }
};

/// Where a table last painted -- used to blank that whole region before
/// repainting a possibly-smaller one (fewer rows, a narrower style, ...)
/// so a shrinking table doesn't leave stale cells behind past its new
/// content's edge.
const TablePaintedExtent = struct {
    row: usize = 0,
    col: usize = 0,
    rows: usize = 0,
    cols: usize = 0,
};

pub const Table = struct {
    alloc: std.mem.Allocator,
    row: usize,
    col: usize,
    columns: []TableColumn,
    rows: []TableRow = &.{},
    style: TableStyle,
    sort_column: ?usize = null,
    sort_dir: SortDirection = .none,
    revision: u64 = 0,
    painted: TablePaintedExtent = .{},
    /// Where the table's logical row 0 currently sits in **live-viewport**
    /// coordinates (row 0 == the live viewport's top). `render` sets it
    /// (`anchor_row - scrolled`, so it goes negative for a table that
    /// scrolled its header up into scrollback), and `Layer.scrollOne`
    /// decrements it for every table on the layer as fresh output pushes
    /// the table up -- the same content-pinning `scrollOne` already does
    /// for `Layer.selection`. This is what lets a header click (which
    /// arrives as a *screen* row) be mapped back to the table however far
    /// output or the scrollback view has moved it since it was drawn --
    /// see `headerColumnAt` / `repaint`. `render`/`repaint`/`headerColumnAt`
    /// are the only readers; nothing persists it across a `resize` (the
    /// ring is rebuilt and the owning client re-renders).
    top_live: i64 = 0,

    /// Takes ownership of `columns` and `style` outright (the caller,
    /// `handleCreateTable`, built them specifically to hand off) -- same
    /// "caller hands over a fully-built value" shape `Context.loadImage`'s
    /// `bytes` param has.
    pub fn init(alloc: std.mem.Allocator, row: usize, col: usize, columns: []TableColumn, style: TableStyle) Table {
        return .{ .alloc = alloc, .row = row, .col = col, .columns = columns, .style = style };
    }

    pub fn deinit(self: *Table) void {
        for (self.columns) |c| c.deinit(self.alloc);
        self.alloc.free(self.columns);
        self.freeRows();
        self.style.deinit(self.alloc);
    }

    fn freeRows(self: *Table) void {
        for (self.rows) |r| r.deinit(self.alloc);
        self.alloc.free(self.rows);
        self.rows = &.{};
    }

    /// `table_set_rows`: replaces every row wholesale, taking ownership
    /// of `new_rows` the same way `init` takes `columns`/`style`. Errors
    /// (freeing `new_rows` itself first) if any row's cell count doesn't
    /// match the column count -- a shape mismatch, not something to
    /// silently pad/truncate around. Doesn't touch `sort_column`/
    /// `sort_dir` -- a caller replacing a table's data while a sort is
    /// active (e.g. glyphwire-ls re-listing a directory into an existing
    /// table) keeps that sort applied to the new rows, same as a real
    /// spreadsheet would.
    pub fn setRows(self: *Table, new_rows: []TableRow) error{TableRowShapeMismatch}!void {
        for (new_rows) |r| {
            if (r.cells.len != self.columns.len) {
                for (new_rows) |rr| rr.deinit(self.alloc);
                self.alloc.free(new_rows);
                return error.TableRowShapeMismatch;
            }
        }
        self.freeRows();
        self.rows = new_rows;
    }

    /// `table_set_sort`: `column: null` or `dir: .none` both mean
    /// "unsorted, original insertion order" -- see `sortedIndices`.
    pub fn setSort(self: *Table, column: ?usize, dir: SortDirection) void {
        self.sort_column = column;
        self.sort_dir = dir;
    }

    /// The 3-state cycle a header click steps `col` through, the mutation
    /// glyphwire-host's header hit-test runs (`headerColumnAt` resolves
    /// the column, this advances its sort): a fresh column -- or a return
    /// from `.none` -- sorts ascending, ascending goes to descending, and
    /// descending clears back to insertion order (`column: null`). A
    /// no-op on an out-of-range or non-`sortable` column. Like `setSort`
    /// it doesn't repaint; the caller calls `render` after.
    pub fn cycleSortOnColumn(self: *Table, col: usize) void {
        if (col >= self.columns.len or !self.columns[col].sortable) return;
        if (self.sort_column != col or self.sort_dir == .none) {
            self.setSort(col, .ascending);
        } else switch (self.sort_dir) {
            .ascending => self.setSort(col, .descending),
            .descending, .none => self.setSort(null, .none),
        }
    }

    /// The index of the column whose header cell covers **screen** cell
    /// `(screen_row, screen_col)` given the layer is scrolled back by
    /// `view_scroll` rows, or `null` when that cell isn't on this table's
    /// header row or lands on an inter-column separator.
    ///
    /// The header's live-viewport row is `top_live + border_pad` (see
    /// `top_live` -- kept accurate as output scrolls the table), and the
    /// content at live row `L` is shown at screen row `L + view_scroll`,
    /// so the header is on screen row `top_live + border_pad +
    /// view_scroll`. That means a header click resolves correctly however
    /// far the table has scrolled and whether or not the user has
    /// scrolled the view back to reach it -- the only requirement is that
    /// the header is actually on screen. Columns are laid out through
    /// `headerColWidth`, exactly as `render`/`writeHeaderRow` do, so the
    /// click lands on the column drawn under it, arrow width included.
    /// Pairs with `cycleSortOnColumn`.
    pub fn headerColumnAt(self: *const Table, screen_row: usize, screen_col: usize, view_scroll: usize) ?usize {
        const border_pad: usize = if (self.style.borders) 1 else 0;
        const header_screen = self.top_live + @as(i64, @intCast(border_pad)) + @as(i64, @intCast(view_scroll));
        if (header_screen < 0 or @as(i64, @intCast(screen_row)) != header_screen) return null;
        var c = self.col + border_pad;
        for (self.columns, 0..) |_, i| {
            if (i > 0) {
                if (screen_col == c) return null; // inter-column separator
                c += 1;
            }
            const w = self.headerColWidth(i);
            if (screen_col >= c and screen_col < c + w) return i;
            c += w;
        }
        return null;
    }

    /// A column's header/layout width in cells: its nominal
    /// `max(width, min_width)`, widened only on the *active* sort column
    /// so its name plus the direction arrow (`" ▲"`, `sort_arrow_cells`
    /// wide) fit without truncating the name -- the column expands to fit
    /// the arrow rather than the arrow eating into the name (decided in
    /// the sort feature's clarifying questions). Every other column, and
    /// all columns while the table is unsorted, get only their nominal
    /// width, so an inactive sortable header is laid out identically to a
    /// fixed one. `render`, `paintAt`, `writeHeaderRow`, `writeBodyRow`
    /// and `headerColumnAt` all place columns through this so the header
    /// and body stay aligned and a header hit-test lands on the right
    /// column.
    fn headerColWidth(self: *const Table, i: usize) usize {
        const base = @max(self.columns[i].width, self.columns[i].min_width);
        if (self.sort_dir == .none or self.sort_column != i) return base;
        return @max(base, stringWidth(self.columns[i].name) + sort_arrow_cells);
    }

    /// `table_set_style`: takes ownership of `new_style` the same way
    /// `init` takes its `style` param, freeing the previous one first.
    pub fn setStyle(self: *Table, new_style: TableStyle) void {
        self.style.deinit(self.alloc);
        self.style = new_style;
    }

    /// Row indices in current display order: identity order (`0, 1, 2,
    /// ...`) when unsorted or `sort_column` is out of range, otherwise
    /// sorted on that column's `SortKey` (`.text` lexically, `.number`
    /// numerically -- comparing a `.text` key against a `.number` one,
    /// which shouldn't happen since a column's cells are all built the
    /// same way by whatever sent `table_set_rows`, treats them as equal
    /// rather than erroring). Caller-owned, freed by the caller.
    pub fn sortedIndices(self: *const Table, alloc: std.mem.Allocator) ![]usize {
        const indices = try alloc.alloc(usize, self.rows.len);
        for (indices, 0..) |*idx, i| idx.* = i;

        const col = self.sort_column orelse return indices;
        if (self.sort_dir == .none or col >= self.columns.len) return indices;

        const SortCtx = struct {
            rows: []const TableRow,
            col: usize,
            ascending: bool,

            fn order(ctx: @This(), a: usize, b: usize) std.math.Order {
                const ka = ctx.rows[a].cells[ctx.col].sort_key;
                const kb = ctx.rows[b].cells[ctx.col].sort_key;
                return switch (ka) {
                    .text => |ta| switch (kb) {
                        .text => |tb| std.mem.order(u8, ta, tb),
                        .number => .eq,
                    },
                    .number => |na| switch (kb) {
                        .number => |nb| std.math.order(na, nb),
                        .text => .eq,
                    },
                };
            }

            fn lessThan(ctx: @This(), a: usize, b: usize) bool {
                const ord = ctx.order(a, b);
                return if (ctx.ascending) ord == .lt else ord == .gt;
            }
        };
        std.mem.sort(usize, indices, SortCtx{
            .rows = self.rows,
            .col = col,
            .ascending = self.sort_dir == .ascending,
        }, SortCtx.lessThan);
        return indices;
    }

    /// Repaints this table's current (sorted) view directly into `layer`'s
    /// cells at `(self.row, self.col)` -- the "compile structured data
    /// into ordinary cells" step. Runs once per mutation
    /// (`table_set_rows`/`table_set_sort`/`table_set_style`, each via
    /// their dispatch handler), not per frame -- there's no per-frame
    /// table-specific work at all, since glyphwire-host's existing render
    /// pass already draws whatever's in the cell buffer.
    ///
    /// Draws top-down from `self.row`, scrolling the layer a row at a time
    /// as it goes whenever the next piece would run past the bottom edge --
    /// exactly how ordinary terminal output behaves. A table drawn as a
    /// command's output (`glyphwire-ls -l`, printed wherever the shell's
    /// prompt happened to leave the cursor) that's taller than the window
    /// then scrolls its header and earliest rows up into scrollback, the
    /// live tail filling the viewport, with no blank filler anywhere --
    /// the table is a first-class model object for the sake of re-sorting
    /// later, not so it can freeze a header or clip its middle. The scroll
    /// is resolved once per *piece* (`tableMakeRoom`), never per cell: a
    /// per-cell resolution scrolls relative to whatever's currently on top
    /// every call, which is the compounding-scroll bug the
    /// client-composited prototype this replaced first hit. Total scrolling
    /// is capped at the layer's capacity, so a table with more rows than
    /// the viewport plus scrollback can hold degrades to dropping its
    /// newest rows rather than spinning.
    ///
    /// Writes every cell directly (`layer.cell(r, c)`) rather than through
    /// `Layer.writeText`/`drawIcon`'s cursor-implicit helpers -- the scroll
    /// bookkeeping lives here, in one place, so nothing downstream triggers
    /// another. Horizontal overflow just clips (`self.col` never moves) --
    /// there's no horizontal-scroll concept for a cell grid, same as
    /// `drawBox`/`drawImage` clamping their own rectangles to the layer's
    /// width.
    pub fn render(self: *Table, layer: *Layer, ctx: *const Context) !void {
        clearExtent(layer, self.painted);

        var content_width: usize = 0;
        for (self.columns, 0..) |_, i| {
            if (i > 0) content_width += 1;
            content_width += self.headerColWidth(i);
        }
        const border_pad: usize = if (self.style.borders) 1 else 0;
        const row_height = @max(self.style.row_height, 1);

        const content_start_col = self.col + border_pad;
        const anchor_row = self.row;
        var cur_row = self.row;
        var scrolled: usize = 0;

        if (self.style.borders) {
            tableMakeRoom(layer, &cur_row, &scrolled, 1);
            self.drawBorderEdge(layer, ctx, cur_row, content_width, .top);
            cur_row += 1;
        }

        tableMakeRoom(layer, &cur_row, &scrolled, 1);
        self.writeHeaderRow(layer, cur_row, content_start_col);
        if (self.style.borders) self.drawSideBorders(layer, ctx, cur_row, content_width);
        cur_row += 1;

        if (self.style.header_separator) {
            tableMakeRoom(layer, &cur_row, &scrolled, 1);
            self.drawSeparatorRow(layer, ctx, cur_row, content_start_col, content_width);
            cur_row += 1;
        }

        const indices = try self.sortedIndices(self.alloc);
        defer self.alloc.free(indices);

        for (indices, 0..) |row_idx, display_i| {
            tableMakeRoom(layer, &cur_row, &scrolled, row_height);
            const row_bg = if (self.style.alt_row_bg != null and display_i % 2 == 1) self.style.alt_row_bg else null;
            if (row_bg) |bg| fillRowBg(layer, cur_row, content_start_col, content_width, row_height, bg);
            if (self.style.borders) {
                var line: usize = 0;
                while (line < row_height) : (line += 1) self.drawSideBorders(layer, ctx, cur_row + line, content_width);
            }
            self.writeBodyRow(layer, ctx, self.rows[row_idx], cur_row, content_start_col, row_height, row_bg);
            cur_row += row_height;
        }

        if (self.style.borders) {
            tableMakeRoom(layer, &cur_row, &scrolled, 1);
            self.drawBorderEdge(layer, ctx, cur_row, content_width, .bottom);
            cur_row += 1;
        }

        // The painted extent is the table's *on-screen* footprint after any
        // scrolling: its top is `anchor_row` shifted up by however many
        // rows scrolled by (0 once it's scrolled off into history), its
        // bottom is wherever the loop left `cur_row`, clamped to the
        // viewport. `clearExtent` blanks exactly this region next render.
        const painted_top = anchor_row -| scrolled;
        const painted_bottom = @min(cur_row, layer.height);
        self.row = painted_top;
        // Unclamped: goes negative when the header scrolled up into
        // history. `scrollOne` decrements it as more output arrives, so
        // `headerColumnAt`/`repaint` can always find the table again.
        self.top_live = @as(i64, @intCast(anchor_row)) - @as(i64, @intCast(scrolled));
        self.painted = .{
            .row = painted_top,
            .col = self.col,
            .rows = painted_bottom - painted_top,
            .cols = content_width + 2 * border_pad,
        };
        self.revision += 1;
    }

    /// Repaint the table's current cells in place -- what a re-sort
    /// (`table_set_sort`, or a glyphwire-host header click) and a re-style
    /// need, as opposed to `render`'s "draw fresh at the cursor, scrolling
    /// the layer terminal-style" (right only when the table is first put
    /// on screen). The row *set* is unchanged, so this never scrolls the
    /// layer: it redraws the same footprint at the table's current
    /// position (`top_live`, kept accurate by `scrollOne` as output moved
    /// the table since `render`), clipping to the viewport instead. A
    /// table taller than the viewport therefore re-sorts the portion
    /// that's actually on screen; rows already in scrollback keep their
    /// old order (the ring's history isn't rewritable). Falls back to
    /// `render` only if the table was never rendered (`revision == 0`) --
    /// a table scrolled entirely off screen has `painted.rows == 0` but
    /// must still `repaint` (silently, painting nothing) rather than
    /// re-`render` and re-scroll.
    pub fn repaint(self: *Table, layer: *Layer, ctx: *const Context) !void {
        if (self.revision == 0) return self.render(layer, ctx);
        clearExtent(layer, self.painted);
        self.painted = try self.paintAt(layer, ctx, self.top_live);
        self.revision += 1;
    }

    /// Draws every piece of the table -- top border, header, separator,
    /// body rows, bottom border -- top-down starting at live-viewport row
    /// `top` (which may be negative: the table's header is up in
    /// scrollback), **clipping** any piece that falls outside `0
    /// ..layer.height` rather than scrolling to make room. Returns the
    /// on-screen footprint actually covered, for `repaint` to stash as
    /// `painted`. Shares the column layout (`headerColWidth`) and the
    /// per-piece writers with `render`; only the vertical placement rule
    /// differs (clip here, scroll there).
    fn paintAt(self: *Table, layer: *Layer, ctx: *const Context, top: i64) !TablePaintedExtent {
        var content_width: usize = 0;
        for (self.columns, 0..) |_, i| {
            if (i > 0) content_width += 1;
            content_width += self.headerColWidth(i);
        }
        const border_pad: usize = if (self.style.borders) 1 else 0;
        const row_height = @max(self.style.row_height, 1);
        const content_start_col = self.col + border_pad;
        const height_i: i64 = @intCast(layer.height);

        // True when a single-line piece at row `r` is on screen.
        const onScreen = struct {
            fn f(r: i64, h: i64) bool {
                return r >= 0 and r < h;
            }
        }.f;

        var cur: i64 = top;

        if (self.style.borders) {
            if (onScreen(cur, height_i)) self.drawBorderEdge(layer, ctx, @intCast(cur), content_width, .top);
            cur += 1;
        }

        if (onScreen(cur, height_i)) {
            self.writeHeaderRow(layer, @intCast(cur), content_start_col);
            if (self.style.borders) self.drawSideBorders(layer, ctx, @intCast(cur), content_width);
        }
        cur += 1;

        if (self.style.header_separator) {
            if (onScreen(cur, height_i)) self.drawSeparatorRow(layer, ctx, @intCast(cur), content_start_col, content_width);
            cur += 1;
        }

        const indices = try self.sortedIndices(self.alloc);
        defer self.alloc.free(indices);

        for (indices, 0..) |row_idx, display_i| {
            // A body block is placed only when its top line is on screen;
            // its lower lines then clip per-cell against `layer.height`.
            // A block whose top is above row 0 (the scroll boundary) is
            // skipped whole -- one row not repainted there is the price of
            // never rewriting history.
            if (cur >= 0 and cur < height_i) {
                const r: usize = @intCast(cur);
                const row_bg = if (self.style.alt_row_bg != null and display_i % 2 == 1) self.style.alt_row_bg else null;
                if (row_bg) |bg| fillRowBg(layer, r, content_start_col, content_width, row_height, bg);
                if (self.style.borders) {
                    var line: usize = 0;
                    while (line < row_height and r + line < layer.height) : (line += 1)
                        self.drawSideBorders(layer, ctx, r + line, content_width);
                }
                self.writeBodyRow(layer, ctx, self.rows[row_idx], r, content_start_col, row_height, row_bg);
            }
            cur += @intCast(row_height);
        }

        if (self.style.borders) {
            if (onScreen(cur, height_i)) self.drawBorderEdge(layer, ctx, @intCast(cur), content_width, .bottom);
            cur += 1;
        }

        const vis_top = std.math.clamp(top, 0, height_i);
        const vis_bot = std.math.clamp(cur, 0, height_i);
        return .{
            .row = @intCast(vis_top),
            .col = self.col,
            .rows = @intCast(vis_bot - vis_top),
            .cols = content_width + 2 * border_pad,
        };
    }

    fn writeHeaderRow(self: *const Table, layer: *Layer, row: usize, content_start_col: usize) void {
        const fg = self.style.header_fg orelse default_style.fg;
        var col = content_start_col;
        for (self.columns, 0..) |column, i| {
            if (i > 0) {
                writeCellRun(layer, row, col, "", 1, .start, fg, self.style.header_bg, null);
                col += 1;
            }
            const width = self.headerColWidth(i);
            if (self.sort_dir != .none and self.sort_column == i) {
                // The active sort column draws its name plus a direction
                // arrow ("Name ▲"); `headerColWidth` already widened this
                // column so the arrow fits without clipping the name. A
                // pathologically long name (>~250 bytes) that overflows
                // the format buffer just drops the arrow.
                var buf: [256]u8 = undefined;
                const label = std.fmt.bufPrint(
                    &buf,
                    "{s} {s}",
                    .{ column.name, sortArrowGlyph(self.sort_dir) },
                ) catch column.name;
                writeCellRun(layer, row, col, label, width, column.h_align, fg, self.style.header_bg, null);
            } else {
                writeCellRun(layer, row, col, column.name, width, column.h_align, fg, self.style.header_bg, null);
            }
            col += width;
        }
    }

    /// One column's icon (if any) plus display text, on the row block's
    /// middle line (`top_row + row_height / 2` -- `row_height == 1`
    /// lands on the block's only line). The icon is drawn `.natural`-scaled
    /// and capped to `row_height` cell-heights tall (so a `row_height == 1`
    /// row's icon fills that single line without spilling onto its
    /// neighbours, and a `row_height > 1` "large format" row's icon grows
    /// past its own line into the block's blank rows), then reserves enough
    /// leading columns that the text after it doesn't collide -- from the
    /// icon's own natural pixel width (`ctx.imageInfo`, read from the
    /// actually-loaded image rather than a hardcoded constant, unlike the
    /// client-composited prototype's fixed `icon_native_px`). Same "fill
    /// the line" rendering `writeGrid`'s icons in glyphwire-ls's non-table
    /// listing use. If the session's cell pixel metrics are unavailable
    /// (`ctx.cell_px_w`/`_h` zeroed) it falls back to a plain one-cell
    /// `.fit`.
    ///
    /// The icon goes into `Cell.fg_icon` (`setCellIconOver`), not
    /// `style.bg` -- it composites *over* the row's background rather than
    /// replacing it, so an `alt_row_bg` stripe stays unbroken behind the
    /// icon cell and a `.natural`-scaled icon that overflows into
    /// neighboring rows/columns paints over their backgrounds too. See
    /// `setCellIconOver`'s doc comment.
    fn writeBodyRow(self: *const Table, layer: *Layer, ctx: *const Context, row: TableRow, top_row: usize, content_start_col: usize, row_height: usize, row_bg: ?Color) void {
        const mid_row = top_row + row_height / 2;
        var col = content_start_col;
        for (self.columns, 0..) |column, i| {
            // `headerColWidth`, not the nominal width, so body cells stay
            // under their header: the active sort column is wider by the
            // arrow's `sort_arrow_cells`, which becomes trailing padding
            // here (or, for an `.end`-aligned column, keeps the value
            // flush under the arrow).
            const width = self.headerColWidth(i);
            const cell = row.cells[i];
            var icon_reserve: usize = 0;

            if (cell.icon) |icon_handle| {
                if (ctx.cell_px_w > 0 and ctx.cell_px_h > 0) {
                    const info = ctx.imageInfo(icon_handle) orelse ImageInfo{ .width = 0, .height = 0 };
                    // Row height bounds the icon; `style.max_icon_px` (if
                    // set) bounds it further, so a tall row still renders a
                    // modest icon.
                    const max_h: u32 = @min(
                        @as(u32, @intCast(row_height * ctx.cell_px_h)),
                        self.style.max_icon_px orelse std.math.maxInt(u32),
                    );
                    const render_px = @min(info.width, max_h);
                    icon_reserve = (render_px + ctx.cell_px_w - 1) / ctx.cell_px_w + 1;
                    setCellIconOver(layer, mid_row, col, icon_handle, .natural, .start, .center, max_h, cell.metadata_id);
                } else {
                    icon_reserve = 1;
                    setCellIconOver(layer, mid_row, col, icon_handle, .fit, .center, .center, null, cell.metadata_id);
                }
            }

            const text_col = col + icon_reserve;
            const text_width = width -| icon_reserve;
            const fg = cell.fg orelse default_style.fg;
            writeCellRun(layer, mid_row, text_col, cell.display, text_width, column.h_align, fg, row_bg, cell.metadata_id);

            col += width + 1;
        }
    }

    fn drawBorderEdge(self: *const Table, layer: *Layer, ctx: *const Context, row: usize, content_width: usize, edge: enum { top, bottom }) void {
        const corner_l = if (edge == .top) "tl" else "bl";
        const mid = if (edge == .top) "t" else "b";
        const corner_r = if (edge == .top) "tr" else "br";
        const total_width = content_width + 2;

        drawBorderTile(layer, ctx, row, self.col, self.style.box_style, corner_l);
        var c = self.col + 1;
        while (c < self.col + total_width - 1) : (c += 1) drawBorderTile(layer, ctx, row, c, self.style.box_style, mid);
        drawBorderTile(layer, ctx, row, self.col + total_width - 1, self.style.box_style, corner_r);
    }

    fn drawSideBorders(self: *const Table, layer: *Layer, ctx: *const Context, row: usize, content_width: usize) void {
        drawBorderTile(layer, ctx, row, self.col, self.style.box_style, "l");
        drawBorderTile(layer, ctx, row, self.col + content_width + 1, self.style.box_style, "r");
    }

    fn drawSeparatorRow(self: *const Table, layer: *Layer, ctx: *const Context, row: usize, content_start_col: usize, content_width: usize) void {
        if (self.style.borders) drawBorderTile(layer, ctx, row, self.col, self.style.box_style, "l");
        var c = content_start_col;
        while (c < content_start_col + content_width) : (c += 1) drawBorderTile(layer, ctx, row, c, self.style.box_style, "t");
        if (self.style.borders) drawBorderTile(layer, ctx, row, self.col + content_width + 1, self.style.box_style, "r");
    }
};

fn clearExtent(layer: *Layer, extent: TablePaintedExtent) void {
    if (extent.rows == 0 or extent.cols == 0) return;
    layer.clear(extent.row, extent.col, extent.rows, extent.cols);
}

/// Scrolls `layer` just far enough that a `piece_h`-row table piece about
/// to be drawn at `cur_row.*` sits fully above the viewport's bottom edge
/// -- the "make room for the next line" a terminal does as output flows
/// past the bottom. Each scrolled-off row keeps whatever the table already
/// wrote into it (`Table.render` draws top-down), so only real content
/// ever reaches scrollback. `scrolled.*` accumulates the total so
/// `render` can locate the table's top afterwards; scrolling stops once
/// that total reaches the layer's capacity, past which the excess rows
/// just clip (a table longer than viewport + scrollback).
fn tableMakeRoom(layer: *Layer, cur_row: *usize, scrolled: *usize, piece_h: usize) void {
    const past_bottom = cur_row.* + piece_h;
    if (past_bottom <= layer.height) return;
    const want = past_bottom - layer.height;
    const budget = layer.capacity() -| scrolled.*;
    const n = @min(want, budget);
    var i: usize = 0;
    while (i < n) : (i += 1) layer.scrollOne();
    scrolled.* += n;
    cur_row.* -|= n;
}

fn setCellText(layer: *Layer, row: usize, col: usize, grapheme: []const u8, fg: Color, bg: ?Color, metadata_id: ?MetadataHandle) void {
    if (row >= layer.height or col >= layer.width) return;
    const c = layer.cell(row, col);
    c.setGrapheme(grapheme);
    c.style.fg = fg;
    c.style.bg = if (bg) |b| .{ .color = b } else default_style.bg;
    c.metadata_id = metadata_id;
    c.wide = .narrow;
}

/// Writes a 2-cell wide grapheme: the lead cell at `(row, col)` holds it,
/// `(row, col + 1)` becomes a blank spacer carrying the lead's resolved
/// style + `metadata_id`. Caller guarantees `col + 1` is in range. Used
/// by `writeCellRun` so table cells advance the same way `writeText` does.
fn setCellWide(layer: *Layer, row: usize, col: usize, grapheme: []const u8, fg: Color, bg: ?Color, metadata_id: ?MetadataHandle) void {
    if (row >= layer.height or col + 1 >= layer.width) return;
    const lead = layer.cell(row, col);
    lead.setGrapheme(grapheme);
    lead.style.fg = fg;
    lead.style.bg = if (bg) |b| .{ .color = b } else default_style.bg;
    lead.metadata_id = metadata_id;
    lead.wide = .wide_lead;
    const sp = layer.cell(row, col + 1);
    sp.* = .{ .style = lead.style, .metadata_id = metadata_id, .wide = .wide_spacer };
}

fn setCellIcon(layer: *Layer, row: usize, col: usize, handle: ImageHandle, scale: IconScale, h_align: HAlign, v_align: VAlign, max_h: ?u32, metadata_id: ?MetadataHandle) void {
    if (row >= layer.height or col >= layer.width) return;
    const c = layer.cell(row, col);
    c.style.bg = .{ .icon = .{ .handle = handle, .scale = scale, .h_align = h_align, .v_align = v_align, .max_h = max_h } };
    c.metadata_id = metadata_id;
}

/// Like `setCellIcon`, but writes the icon into `Cell.fg_icon` instead of
/// `style.bg` -- see that field's doc comment. Leaves whatever background
/// the cell already carries (a `fillRowBg` `alt_row_bg` stripe, or the
/// default) in place, so `glyphwire-host`'s render pass composites the
/// icon *over* it rather than replacing it. Table body icons always take
/// this path: an icon should sit above its row's background, and a
/// `.natural`-scaled one that overflows past its anchor cell has to paint
/// over the neighboring rows'/columns' backgrounds too -- the host defers
/// `.natural` `fg_icon`s past the whole grid for exactly that, the same
/// way it already does for `style.bg`'s `.icon` overflow.
fn setCellIconOver(layer: *Layer, row: usize, col: usize, handle: ImageHandle, scale: IconScale, h_align: HAlign, v_align: VAlign, max_h: ?u32, metadata_id: ?MetadataHandle) void {
    if (row >= layer.height or col >= layer.width) return;
    const c = layer.cell(row, col);
    c.fg_icon = .{ .handle = handle, .scale = scale, .h_align = h_align, .v_align = v_align, .max_h = max_h };
    c.metadata_id = metadata_id;
}

fn fillRowBg(layer: *Layer, top_row: usize, content_start_col: usize, content_width: usize, row_height: usize, bg: Color) void {
    var line: usize = 0;
    while (line < row_height) : (line += 1) {
        const r = top_row + line;
        if (r >= layer.height) break;
        var c = content_start_col;
        const end = @min(content_start_col + content_width, layer.width);
        while (c < end) : (c += 1) setCellText(layer, r, c, "", default_style.fg, bg, null);
    }
}

fn borderTileHandle(ctx: *const Context, box_style: []const u8, piece: []const u8, name_buf: []u8) ?ImageHandle {
    // Tiles are catalog entries `"<style>/<piece>"` -- the `assets/icons/`
    // scan names an icon by its path under that directory (see
    // `iconName`), so the bundled `box`/`dialog` styles live in
    // `assets/icons/box/` and `assets/icons/dialog/` and resolve as
    // `box/tl`, `dialog/fill`, and so on.
    const name = std.fmt.bufPrint(name_buf, "{s}/{s}", .{ box_style, piece }) catch return null;
    return ctx.iconHandle(name);
}

fn drawBorderTile(layer: *Layer, ctx: *const Context, row: usize, col: usize, box_style: []const u8, piece: []const u8) void {
    var buf: [64]u8 = undefined;
    const handle = borderTileHandle(ctx, box_style, piece, &buf) orelse return;
    setCellIcon(layer, row, col, handle, .stretch, .center, .center, null, null);
}

/// Writes `text` into `layer` starting at `(row, col)`, measured in
/// **display cells** (East Asian wide codepoints take 2 -- see
/// `stringWidth`): truncated with a trailing "…" if wider than `width`,
/// or left/center/right-padded with spaces (per `h_align`) if narrower --
/// same shape the client-composited table prototype's `formatCell` had,
/// just writing straight into cells. A wide codepoint is never split
/// across the column edge; if one won't fit the remaining space the run
/// stops there (and the "…" / padding fills the gap). Clipped to the
/// layer's bounds and to `width` cells -- a column running off the right
/// edge loses its tail, matching `Table.render`'s "clip, don't scroll".
/// A no-op if `width` is 0.
fn writeCellRun(layer: *Layer, row: usize, col: usize, text: []const u8, width: usize, h_align: HAlign, fg: Color, bg: ?Color, metadata_id: ?MetadataHandle) void {
    if (row >= layer.height or width == 0 or col >= layer.width) return;
    const end_col = @min(col + width, layer.width);

    const text_width = stringWidth(text);
    const truncate = text_width > width;
    const keep: usize = if (truncate) width -| 1 else text_width;
    const pad: usize = if (truncate) 0 else width - text_width;
    const lead: usize = if (truncate) 0 else switch (h_align) {
        .start => 0,
        .end => pad,
        .center => pad / 2,
    };

    var c = col;
    var n: usize = 0;
    while (n < lead and c < end_col) : (n += 1) {
        setCellText(layer, row, c, " ", fg, bg, metadata_id);
        c += 1;
    }

    const view = std.unicode.Utf8View.init(text) catch (std.unicode.Utf8View.init("") catch unreachable);
    var it = view.iterator();
    var written: usize = 0; // display cells of the body written so far
    while (written < keep and c < end_col) {
        const cp_bytes = it.nextCodepointSlice() orelse break;
        const w = codepointWidth(std.unicode.utf8Decode(cp_bytes) catch 0xFFFD);
        if (written + w > keep) break;
        if (w == 2) {
            if (c + 1 >= end_col) break; // wide glyph won't fit the column tail
            setCellWide(layer, row, c, cp_bytes, fg, bg, metadata_id);
            c += 2;
        } else {
            setCellText(layer, row, c, cp_bytes, fg, bg, metadata_id);
            c += 1;
        }
        written += w;
    }

    if (truncate and c < end_col) {
        setCellText(layer, row, c, "\u{2026}", fg, bg, metadata_id);
        c += 1;
    }

    while (c < end_col) : (c += 1) setCellText(layer, row, c, " ", fg, bg, metadata_id);
}

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

/// Authoritative input state for a session: which keys/mouse buttons are
/// currently down, and the last known cursor position. Belongs on
/// `Context` rather than `Layer` since it's session-wide, not tied to any
/// one layer's cell content -- see decisions.md's Object Model.
///
/// Pure logic, no I/O, headless-testable like everything else in this
/// file: the actual GLFW capture happens in glyphwire-host, which reports
/// changes here as `report_key`/`report_mouse_button`/`report_mouse_move`
/// notifications (see dispatch.zig, or `Server`'s in-process equivalents
/// for a caller that owns the `Context` directly) rather than this type
/// knowing anything about how input was captured.
///
/// Key/button names are whatever string the reporter used (glyphwire-host
/// uses `@tagName` of its engine's key/button enums, e.g. "a",
/// "left_shift", "left") -- not a closed set enforced here.
pub const InputState = struct {
    alloc: std.mem.Allocator,
    keys_down: std.StringHashMap(void),
    mouse_buttons_down: std.StringHashMap(void),
    cursor_px: PxPos = .{},
    cursor_cell: CellPos = .{},

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
/// glyphs), and `box/` + `dialog/` (the two `draw_box` 9-patch styles --
/// `draw_box`'s `style` param is the subdirectory name, so its pieces
/// resolve as `box/tl`, `dialog/fill`, and so on).
pub fn iconName(rel_path: []const u8) ?[]const u8 {
    if (!std.ascii.endsWithIgnoreCase(rel_path, ".png")) return null;
    return rel_path[0 .. rel_path.len - ".png".len];
}


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
    /// Bumped whenever the split tree or the context size changes, i.e.
    /// whenever a previously computed layout (and its divider rects) went
    /// stale. glyphwire-host caches the divider geometry it hit-tests
    /// against and recomputes only when this moves.
    layout_gen: u64 = 0,
    input: InputState,
    images: std.AutoHashMap(ImageHandle, ImageEntry),
    next_image_handle: ImageHandle = 1,
    /// Name -> image handle, for `draw_icon` (decisions.md's Icon
    /// section). Populated by whoever loads the bundled icon files
    /// (`glyphwire-host`, scanning `assets/icons/` -- see `iconName`) --
    /// empty until then, same as `images` before any `load_image` call.
    icons: std.StringHashMap(ImageHandle),
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

    pub fn init(alloc: std.mem.Allocator, width: usize, height: usize, scrollback_rows: usize) !Context {
        return .{
            .alloc = alloc,
            .root = try Layer.init(alloc, width, height, scrollback_rows),
            .layers = std.AutoHashMap(LayerHandle, Layer).init(alloc),
            .splits = std.AutoHashMap(SplitHandle, Split).init(alloc),
            .input = InputState.init(alloc),
            .images = std.AutoHashMap(ImageHandle, ImageEntry).init(alloc),
            .icons = std.StringHashMap(ImageHandle).init(alloc),
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
        self.input.deinit();
        var it = self.images.valueIterator();
        while (it.next()) |entry| self.alloc.free(entry.bytes);
        self.images.deinit();
        var icon_it = self.icons.keyIterator();
        while (icon_it.next()) |k| self.alloc.free(k.*);
        self.icons.deinit();
        var metadata_it = self.metadata.valueIterator();
        while (metadata_it.next()) |m| self.alloc.free(m.json);
        self.metadata.deinit();
        self.clipboard.deinit(self.alloc);
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
        const owned = try self.alloc.dupe(u8, json);
        errdefer self.alloc.free(owned);

        const handle = self.next_metadata_handle;
        self.next_metadata_handle += 1;
        try self.metadata.put(handle, .{ .json = owned });
        return handle;
    }

    /// `destroy_metadata`: frees `id`'s stored JSON. Errors on an unknown
    /// id, same as `destroyLayer` -- there's no reference counting, so a
    /// cell can still be tagged with `id` afterward; `getMetadataAt`
    /// resolves that gracefully (reports the id, `metadata: null`) rather
    /// than erroring, since a dangling tag is an expected, not
    /// exceptional, state once destruction is explicit.
    pub fn destroyMetadata(self: *Context, id: MetadataHandle) MetadataError!void {
        const removed = self.metadata.fetchRemove(id) orelse return MetadataError.UnknownMetadata;
        self.alloc.free(removed.value.json);
    }

    /// `id`'s stored JSON, or null if it was never created or has since
    /// been destroyed (see `destroyMetadata`'s doc comment on why that's
    /// not an error here).
    pub fn metadataJson(self: *const Context, id: MetadataHandle) ?[]const u8 {
        return if (self.metadata.get(id)) |m| m.json else null;
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
    /// `visibility`), the cell-metric resolution `cell_position` needs,
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
            .cell_position => |cell| {
                layer.pos = self.pixelPosForCell(cell);
                layer.pos_cells = cell;
                layer.touchRender();
            },
            .revision, .scroll => return PropertyError.ReadOnlyProperty,
            .cursor, .position, .viewport, .scroll_offset, .scrollbars, .content_extent => layer.setProperty(value),
        }
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
        if (!moved and !resized) return;

        if (moved) {
            layer.pos_cells = .{ .row = rect.row, .col = rect.col };
            layer.pos = self.pixelPosForCell(layer.pos_cells.?);
            layer.touchRender();
        }
        if (resized) layer.setProperty(.{ .viewport = .{ .cols = rect.cols, .rows = rect.rows } });

        if (changed) |out| {
            try out.append(self.alloc, .{
                .layer = handle,
                .row = rect.row,
                .col = rect.col,
                .cols = rect.cols,
                .rows = rect.rows,
            });
        }
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
        const wa: ?f32 = switch (a.size) { .weight => |w| @max(w, 0), .fixed => null };
        const wb: ?f32 = switch (b.size) { .weight => |w| @max(w, 0), .fixed => null };

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
    /// `draw_icon`/`draw_box`), not optional here.
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
        clearExtent(layer, removed.value.painted);
        removed.value.deinit();
        for (layer.table_order.items, 0..) |h, i| {
            if (h == handle) {
                _ = layer.table_order.orderedRemove(i);
                break;
            }
        }
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

    /// `load_image`: stores `bytes` verbatim and reads their natural
    /// dimensions from `format`'s header (`imageDimensions`) -- see
    /// `ImageEntry`'s doc comment. Bytes that don't match the declared
    /// `format` fail with the matching `ImageError`. Returns a fresh
    /// server-generated handle.
    pub fn loadImage(self: *Context, format: ImageFormat, bytes: []const u8) !ImageHandle {
        const info = try imageDimensions(format, bytes);
        const owned = try self.alloc.dupe(u8, bytes);
        errdefer self.alloc.free(owned);

        const handle = self.next_image_handle;
        self.next_image_handle += 1;
        try self.images.put(handle, .{ .bytes = owned, .format = format, .width = info.width, .height = info.height });
        return handle;
    }

    /// `get_image_info`: natural pixel dimensions, or null for an unknown
    /// handle. Falls back to `asset_fallback` like `imageEntry`.
    pub fn imageInfo(self: *const Context, handle: ImageHandle) ?ImageInfo {
        const entry = self.imageEntry(handle) orelse return null;
        return .{ .width = entry.width, .height = entry.height };
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
    phases: [profile_max_phases]ProfilePhase = .{ProfilePhase{}} ** profile_max_phases,
    counters: [profile_max_counters]ProfileCount = .{ProfileCount{}} ** profile_max_counters,

    /// The populated phase / counter slices -- what a serializer or a
    /// formatter should walk (the arrays are fixed-size padding).
    pub fn phaseSlice(self: *const ProfileSnapshot) []const ProfilePhase {
        return self.phases[0..self.phase_count];
    }
    pub fn counterSlice(self: *const ProfileSnapshot) []const ProfileCount {
        return self.counters[0..self.counter_count];
    }
};

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
    /// Visibility history, bottom (index 0, always the root context) to
    /// top (the currently-visible context). `activate` moves a handle to
    /// the top; `create` pushes; destroying or culling the visible
    /// context pops back to whatever was under it.
    visible_stack: std.ArrayList(ContextHandle) = .empty,
    /// Denormalised copies of the top-of-stack handle and a
    /// change-counter, kept so lock-free readers (glyphwire-host's render
    /// loop polling for a switch, `Server.broadcast` deciding whether a
    /// backgrounded connection should see an input event) never touch
    /// `visible_stack` -- which is only ever mutated under the server's
    /// `ctx_mutex`. `visible_gen` is a counter, not a flag, so a switch
    /// that happens between two polls is never missed.
    visible_handle: std.atomic.Value(ContextHandle) = .init(root_context_handle),
    visible_gen: std.atomic.Value(u64) = .init(0),

    /// glyphwire-host's latest frame-timing profiler snapshot, refreshed
    /// under `ctx_mutex` each iteration while profiling is on and returned
    /// verbatim by `get_property "profile"`. `.active == false` (the
    /// default) whenever the host isn't profiling; the session never reads
    /// or acts on any field. See `src/profiler.zig`.
    profile: ProfileSnapshot = .{},

    /// Wraps an already-created root context. The caller keeps ownership
    /// of `root`'s memory and stays responsible for `root.deinit()`;
    /// this session frees only the contexts it creates itself.
    pub fn init(alloc: std.mem.Allocator, root: *Context) !Session {
        var contexts = std.AutoHashMap(ContextHandle, *Context).init(alloc);
        errdefer contexts.deinit();
        try contexts.put(root_context_handle, root);

        var stack: std.ArrayList(ContextHandle) = .empty;
        errdefer stack.deinit(alloc);
        try stack.append(alloc, root_context_handle);

        return .{ .alloc = alloc, .contexts = contexts, .visible_stack = stack };
    }

    pub fn deinit(self: *Session) void {
        var it = self.contexts.iterator();
        while (it.next()) |e| {
            if (e.key_ptr.* == root_context_handle) continue;
            e.value_ptr.*.deinit();
            self.alloc.destroy(e.value_ptr.*);
        }
        self.contexts.deinit();
        self.visible_stack.deinit(self.alloc);
    }

    /// The root context -- the asset source every other context falls
    /// back to, and the one that is always visible when nothing else is.
    pub fn rootContext(self: *Session) *Context {
        return self.contexts.get(root_context_handle).?;
    }

    /// The currently-visible context (top of the stack). Never null:
    /// the root context can't leave the stack.
    pub fn visibleContext(self: *Session) *Context {
        return self.contexts.get(self.visibleStackTop()).?;
    }

    /// The visible context's handle, read straight off the stack (call
    /// under `ctx_mutex`). Lock-free readers use `visible_handle` instead.
    pub fn visibleStackTop(self: *const Session) ContextHandle {
        return self.visible_stack.items[self.visible_stack.items.len - 1];
    }

    pub fn contextPtr(self: *Session, handle: ContextHandle) ?*Context {
        return self.contexts.get(handle);
    }

    /// Re-publishes `visible_handle` / `visible_gen` from the stack after
    /// any visibility change, and re-lays-out the now-visible context's
    /// split tree -- a context backgrounded across a window resize had
    /// its root layer caught up by `resizeAll` but its tree's cached
    /// rects left stale, and `layoutSplits` is idempotent and cheap.
    /// Every mutator below ends with this.
    fn republishVisible(self: *Session) void {
        self.visible_handle.store(self.visibleStackTop(), .monotonic);
        _ = self.visible_gen.fetchAdd(1, .monotonic);
        self.visibleContext().layoutSplits(null, null) catch {};
    }

    /// `create_context`: allocates a fresh context (defaulting to the
    /// root context's current size) and makes it visible immediately.
    /// The caller records the creating connection as first owner via
    /// `addContextOwner`.
    pub fn createContext(
        self: *Session,
        width: ?usize,
        height: ?usize,
        scrollback_rows: usize,
    ) !ContextHandle {
        const root = self.rootContext();

        const ctx = try self.alloc.create(Context);
        errdefer self.alloc.destroy(ctx);
        ctx.* = try Context.init(
            self.alloc,
            width orelse root.root.width,
            height orelse root.root.height,
            scrollback_rows,
        );
        errdefer ctx.deinit();
        ctx.cell_px_w = root.cell_px_w;
        ctx.cell_px_h = root.cell_px_h;
        ctx.asset_fallback = root;

        const handle = self.next_context_handle;
        try self.contexts.put(handle, ctx);
        errdefer _ = self.contexts.remove(handle);
        try self.visible_stack.append(self.alloc, handle);
        self.next_context_handle += 1;
        self.republishVisible();
        return handle;
    }

    /// Adds `conn` to `handle`'s owner set (see `Context.owners`). Errors
    /// `UnknownContext` for an unknown or the root handle -- the root
    /// context has no lifecycle to participate in.
    pub fn addContextOwner(self: *Session, handle: ContextHandle, conn: ConnId) !void {
        if (handle == root_context_handle) return ContextError.UnknownContext;
        const ctx = self.contexts.get(handle) orelse return ContextError.UnknownContext;
        try ctx.addOwner(conn);
    }

    /// Whether `conn` owns `handle` (false for the root or any unknown
    /// handle) -- the `destroy_context` ownership check.
    pub fn contextHasOwner(self: *Session, handle: ContextHandle, conn: ConnId) bool {
        if (handle == root_context_handle) return false;
        const ctx = self.contexts.get(handle) orelse return false;
        return ctx.hasOwner(conn);
    }

    /// `activate_context`: makes `handle` the visible context by moving
    /// it to the top of the visibility stack (it stays in the stack once,
    /// wherever it already was, rather than being pushed again). Errors
    /// `UnknownContext` for an unknown handle. A no-op (but not an error)
    /// if `handle` is already visible.
    pub fn activateContext(self: *Session, handle: ContextHandle) !void {
        if (!self.contexts.contains(handle)) return ContextError.UnknownContext;
        if (self.visibleStackTop() == handle) return;
        for (self.visible_stack.items, 0..) |h, i| {
            if (h == handle) {
                _ = self.visible_stack.orderedRemove(i);
                break;
            }
        }
        try self.visible_stack.append(self.alloc, handle);
        self.republishVisible();
    }

    /// `destroy_context`: frees `handle` and every layer, split, table
    /// and image it held (`Context.deinit`), and drops it from the
    /// visibility stack -- if it was visible, the context under it
    /// becomes visible. Errors `RootContextImmutable` for the root
    /// handle, `UnknownContext` for anything else unknown.
    pub fn destroyContext(self: *Session, handle: ContextHandle) ContextError!void {
        if (handle == root_context_handle) return ContextError.RootContextImmutable;
        const removed = self.contexts.fetchRemove(handle) orelse return ContextError.UnknownContext;
        removed.value.deinit();
        self.alloc.destroy(removed.value);
        self.dropFromStack(handle);
        self.republishVisible();
    }

    /// Drops `conn` from every connection-owned context's owner set; any
    /// context left with no owners is destroyed (the root context is
    /// never connection-owned, so it is never reached here) and its
    /// handle appended to `culled` (caller-owned, expected empty on
    /// entry). Called from `server.zig` when a connection closes, under
    /// `ctx_mutex` -- the one path that reaps a context a program left
    /// behind when it died without `destroy_context`, exactly as
    /// `Context.removeConnectionOwnership` does for layers one level
    /// down.
    pub fn reapConnection(self: *Session, conn: ConnId, culled: *std.ArrayList(ContextHandle)) !void {
        var it = self.contexts.iterator();
        while (it.next()) |e| {
            if (e.key_ptr.* == root_context_handle) continue;
            const ctx = e.value_ptr.*;
            if (!ctx.connection_owned) continue;
            _ = ctx.owners.remove(conn);
            if (ctx.owners.count() == 0) try culled.append(self.alloc, e.key_ptr.*);
        }
        // Destroy in a second pass: `destroyContext` mutates
        // `self.contexts`, which can't happen while the iterator is live.
        for (culled.items) |h| {
            if (self.contexts.fetchRemove(h)) |removed| {
                removed.value.deinit();
                self.alloc.destroy(removed.value);
                self.dropFromStack(h);
            }
        }
        if (culled.items.len > 0) self.republishVisible();
    }

    /// Resizes every context's root layer (and every base-size-tracking
    /// layer) to a new window size -- the window is a session-wide fact,
    /// so a context that was backgrounded during the resize is caught up
    /// too rather than showing a stale grid when it next becomes
    /// visible. Each `Context.resize` is a cheap no-op when its size is
    /// already current.
    pub fn resizeAll(self: *Session, width: usize, height: usize) !void {
        var it = self.contexts.valueIterator();
        while (it.next()) |ctx| try ctx.*.resize(width, height);
    }

    /// Applies new cell pixel metrics to every context (see
    /// `Context.setCellMetrics`) -- like `resizeAll`, a font-size step is
    /// session-wide.
    pub fn setCellMetricsAll(self: *Session, cell_px_w: u32, cell_px_h: u32) void {
        var it = self.contexts.valueIterator();
        while (it.next()) |ctx| ctx.*.setCellMetrics(cell_px_w, cell_px_h);
    }

    fn dropFromStack(self: *Session, handle: ContextHandle) void {
        var i: usize = self.visible_stack.items.len;
        while (i > 0) {
            i -= 1;
            if (self.visible_stack.items[i] == handle) _ = self.visible_stack.orderedRemove(i);
        }
    }
};
