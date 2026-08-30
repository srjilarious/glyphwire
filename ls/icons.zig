//! Extension -> icon-registry-name lookup for `glyphwire-ls`, split out of
//! `ls/main.zig` into the pure `ls_support` module so `tests/ls_tests.zig`
//! can exercise it directly (same reason `ls/format.zig` lives here).
//!
//! The names on the right are icon-catalog names -- the bundled Oxygen
//! file-type art under `assets/icons/oxygen/`, which `glyphwire-host`
//! resolves server-side for `draw_icon` / `table_set_rows`. This is a
//! coarse, extension-based classification -- the same buckets a mime-type
//! lookup would land on for these common cases, without a mime database
//! dependency.

const std = @import("std");

/// Extension (including the leading `.`, matched case-insensitively) ->
/// default icon-registry name. First match wins; `iconForExtension`
/// falls back to `"file"` for anything not listed.
pub const extension_icons = [_]struct { ext: []const u8, icon: []const u8 }{
    .{ .ext = ".png", .icon = "oxygen/image" },
    .{ .ext = ".jpg", .icon = "oxygen/image" },
    .{ .ext = ".jpeg", .icon = "oxygen/image" },
    .{ .ext = ".gif", .icon = "oxygen/image" },
    .{ .ext = ".bmp", .icon = "oxygen/image" },
    .{ .ext = ".svg", .icon = "oxygen/image" },
    .{ .ext = ".webp", .icon = "oxygen/image" },

    .{ .ext = ".mp3", .icon = "oxygen/audio" },
    .{ .ext = ".wav", .icon = "oxygen/audio" },
    .{ .ext = ".flac", .icon = "oxygen/audio" },
    .{ .ext = ".ogg", .icon = "oxygen/audio" },
    .{ .ext = ".m4a", .icon = "oxygen/audio" },

    .{ .ext = ".mp4", .icon = "oxygen/video" },
    .{ .ext = ".mkv", .icon = "oxygen/video" },
    .{ .ext = ".mov", .icon = "oxygen/video" },
    .{ .ext = ".webm", .icon = "oxygen/video" },
    .{ .ext = ".avi", .icon = "oxygen/video" },

    .{ .ext = ".zip", .icon = "oxygen/archive" },
    .{ .ext = ".tar", .icon = "oxygen/archive" },
    .{ .ext = ".gz", .icon = "oxygen/archive" },
    .{ .ext = ".tgz", .icon = "oxygen/archive" },
    .{ .ext = ".xz", .icon = "oxygen/archive" },
    .{ .ext = ".bz2", .icon = "oxygen/archive" },
    .{ .ext = ".7z", .icon = "oxygen/archive" },
    .{ .ext = ".rar", .icon = "oxygen/archive" },
    .{ .ext = ".zst", .icon = "oxygen/archive" },

    .{ .ext = ".deb", .icon = "oxygen/package" },
    .{ .ext = ".rpm", .icon = "oxygen/package" },
    .{ .ext = ".pkg", .icon = "oxygen/package" },
    .{ .ext = ".apk", .icon = "oxygen/package" },

    .{ .ext = ".pdf", .icon = "oxygen/pdf" },

    .{ .ext = ".doc", .icon = "oxygen/document" },
    .{ .ext = ".docx", .icon = "oxygen/document" },
    .{ .ext = ".odt", .icon = "oxygen/document" },
    .{ .ext = ".rtf", .icon = "oxygen/document" },

    .{ .ext = ".xls", .icon = "oxygen/spreadsheet" },
    .{ .ext = ".xlsx", .icon = "oxygen/spreadsheet" },
    .{ .ext = ".ods", .icon = "oxygen/spreadsheet" },
    .{ .ext = ".csv", .icon = "oxygen/spreadsheet" },

    .{ .ext = ".ppt", .icon = "oxygen/presentation" },
    .{ .ext = ".pptx", .icon = "oxygen/presentation" },
    .{ .ext = ".odp", .icon = "oxygen/presentation" },

    .{ .ext = ".txt", .icon = "oxygen/text" },
    .{ .ext = ".md", .icon = "oxygen/text" },
    .{ .ext = ".markdown", .icon = "oxygen/text" },
    .{ .ext = ".rst", .icon = "oxygen/text" },
    .{ .ext = ".log", .icon = "oxygen/text" },
    .{ .ext = ".xml", .icon = "oxygen/text" },
    .{ .ext = ".json", .icon = "oxygen/text" },
    .{ .ext = ".yaml", .icon = "oxygen/text" },
    .{ .ext = ".yml", .icon = "oxygen/text" },
    .{ .ext = ".toml", .icon = "oxygen/text" },

    .{ .ext = ".html", .icon = "oxygen/web" },
    .{ .ext = ".htm", .icon = "oxygen/web" },
    .{ .ext = ".css", .icon = "oxygen/web" },

    .{ .ext = ".c", .icon = "oxygen/code" },
    .{ .ext = ".h", .icon = "oxygen/code" },
    .{ .ext = ".cpp", .icon = "oxygen/code" },
    .{ .ext = ".cc", .icon = "oxygen/code" },
    .{ .ext = ".cxx", .icon = "oxygen/code" },
    .{ .ext = ".hpp", .icon = "oxygen/code" },
    .{ .ext = ".py", .icon = "oxygen/code" },
    .{ .ext = ".zig", .icon = "oxygen/code" },
    .{ .ext = ".rs", .icon = "oxygen/code" },
    .{ .ext = ".go", .icon = "oxygen/code" },
    .{ .ext = ".js", .icon = "oxygen/code" },
    .{ .ext = ".ts", .icon = "oxygen/code" },
    .{ .ext = ".jsx", .icon = "oxygen/code" },
    .{ .ext = ".tsx", .icon = "oxygen/code" },
    .{ .ext = ".java", .icon = "oxygen/code" },
    .{ .ext = ".rb", .icon = "oxygen/code" },
    .{ .ext = ".lua", .icon = "oxygen/code" },
    .{ .ext = ".pl", .icon = "oxygen/code" },
    .{ .ext = ".php", .icon = "oxygen/code" },
    .{ .ext = ".sh", .icon = "oxygen/code" },
    .{ .ext = ".bash", .icon = "oxygen/code" },
    .{ .ext = ".zsh", .icon = "oxygen/code" },
    .{ .ext = ".fish", .icon = "oxygen/code" },

    .{ .ext = ".bin", .icon = "oxygen/executable" },
    .{ .ext = ".exe", .icon = "oxygen/executable" },
    .{ .ext = ".appimage", .icon = "oxygen/executable" },

    .{ .ext = ".iso", .icon = "oxygen/media-optical" },
};

/// The icon-registry name for a regular file, derived from its extension
/// (`extension_icons`), falling back to `"oxygen/file"` for an
/// unrecognized one.
pub fn iconForExtension(name: []const u8) []const u8 {
    const ext = std.fs.path.extension(name);
    for (extension_icons) |e| {
        if (std.ascii.eqlIgnoreCase(ext, e.ext)) return e.icon;
    }
    return "oxygen/file";
}
