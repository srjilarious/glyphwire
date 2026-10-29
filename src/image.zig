// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: MPL-2.0

//! Image container formats as the headless core sees them: which of the
//! four formats a byte stream is (`detectImageFormat`), and its natural
//! size read from the header alone (`imageDimensions`), never a pixel
//! decode. Moved out of `core.zig` (review B8), which re-exports it.

const std = @import("std");

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
