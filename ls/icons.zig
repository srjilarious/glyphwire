//! Extension -> icon-registry-name lookup for `glyphwire-ls`, split out of
//! `ls/main.zig` into the pure `ls_support` module so `tests/ls_tests.zig`
//! can exercise it directly (same reason `ls/format.zig` lives here).
//!
//! The names on the right are `core.default_icon_manifest` entries
//! (`glyphwire-host` resolves them server-side for `draw_icon` /
//! `table_set_rows`). This is a coarse, extension-based classification --
//! the same buckets a mime-type lookup would land on for these common
//! cases, without a mime database dependency.

const std = @import("std");

/// Extension (including the leading `.`, matched case-insensitively) ->
/// default icon-registry name. First match wins; `iconForExtension`
/// falls back to `"file"` for anything not listed.
pub const extension_icons = [_]struct { ext: []const u8, icon: []const u8 }{
    .{ .ext = ".png", .icon = "image" },
    .{ .ext = ".jpg", .icon = "image" },
    .{ .ext = ".jpeg", .icon = "image" },
    .{ .ext = ".gif", .icon = "image" },
    .{ .ext = ".bmp", .icon = "image" },
    .{ .ext = ".svg", .icon = "image" },
    .{ .ext = ".webp", .icon = "image" },

    .{ .ext = ".mp3", .icon = "audio" },
    .{ .ext = ".wav", .icon = "audio" },
    .{ .ext = ".flac", .icon = "audio" },
    .{ .ext = ".ogg", .icon = "audio" },
    .{ .ext = ".m4a", .icon = "audio" },

    .{ .ext = ".mp4", .icon = "video" },
    .{ .ext = ".mkv", .icon = "video" },
    .{ .ext = ".mov", .icon = "video" },
    .{ .ext = ".webm", .icon = "video" },
    .{ .ext = ".avi", .icon = "video" },

    .{ .ext = ".zip", .icon = "archive" },
    .{ .ext = ".tar", .icon = "archive" },
    .{ .ext = ".gz", .icon = "archive" },
    .{ .ext = ".tgz", .icon = "archive" },
    .{ .ext = ".xz", .icon = "archive" },
    .{ .ext = ".bz2", .icon = "archive" },
    .{ .ext = ".7z", .icon = "archive" },
    .{ .ext = ".rar", .icon = "archive" },
    .{ .ext = ".zst", .icon = "archive" },

    .{ .ext = ".deb", .icon = "package" },
    .{ .ext = ".rpm", .icon = "package" },
    .{ .ext = ".pkg", .icon = "package" },
    .{ .ext = ".apk", .icon = "package" },

    .{ .ext = ".pdf", .icon = "pdf" },

    .{ .ext = ".doc", .icon = "document" },
    .{ .ext = ".docx", .icon = "document" },
    .{ .ext = ".odt", .icon = "document" },
    .{ .ext = ".rtf", .icon = "document" },

    .{ .ext = ".xls", .icon = "spreadsheet" },
    .{ .ext = ".xlsx", .icon = "spreadsheet" },
    .{ .ext = ".ods", .icon = "spreadsheet" },
    .{ .ext = ".csv", .icon = "spreadsheet" },

    .{ .ext = ".ppt", .icon = "presentation" },
    .{ .ext = ".pptx", .icon = "presentation" },
    .{ .ext = ".odp", .icon = "presentation" },

    .{ .ext = ".txt", .icon = "text" },
    .{ .ext = ".md", .icon = "text" },
    .{ .ext = ".markdown", .icon = "text" },
    .{ .ext = ".rst", .icon = "text" },
    .{ .ext = ".log", .icon = "text" },
    .{ .ext = ".xml", .icon = "text" },
    .{ .ext = ".json", .icon = "text" },
    .{ .ext = ".yaml", .icon = "text" },
    .{ .ext = ".yml", .icon = "text" },
    .{ .ext = ".toml", .icon = "text" },

    .{ .ext = ".html", .icon = "web" },
    .{ .ext = ".htm", .icon = "web" },
    .{ .ext = ".css", .icon = "web" },

    .{ .ext = ".c", .icon = "code" },
    .{ .ext = ".h", .icon = "code" },
    .{ .ext = ".cpp", .icon = "code" },
    .{ .ext = ".cc", .icon = "code" },
    .{ .ext = ".cxx", .icon = "code" },
    .{ .ext = ".hpp", .icon = "code" },
    .{ .ext = ".py", .icon = "code" },
    .{ .ext = ".zig", .icon = "code" },
    .{ .ext = ".rs", .icon = "code" },
    .{ .ext = ".go", .icon = "code" },
    .{ .ext = ".js", .icon = "code" },
    .{ .ext = ".ts", .icon = "code" },
    .{ .ext = ".jsx", .icon = "code" },
    .{ .ext = ".tsx", .icon = "code" },
    .{ .ext = ".java", .icon = "code" },
    .{ .ext = ".rb", .icon = "code" },
    .{ .ext = ".lua", .icon = "code" },
    .{ .ext = ".pl", .icon = "code" },
    .{ .ext = ".php", .icon = "code" },
    .{ .ext = ".sh", .icon = "code" },
    .{ .ext = ".bash", .icon = "code" },
    .{ .ext = ".zsh", .icon = "code" },
    .{ .ext = ".fish", .icon = "code" },

    .{ .ext = ".bin", .icon = "executable" },
    .{ .ext = ".exe", .icon = "executable" },
    .{ .ext = ".appimage", .icon = "executable" },

    .{ .ext = ".iso", .icon = "media-optical" },
};

/// The icon-registry name for a regular file, derived from its extension
/// (`extension_icons`), falling back to `"file"` for an unrecognized one.
pub fn iconForExtension(name: []const u8) []const u8 {
    const ext = std.fs.path.extension(name);
    for (extension_icons) |e| {
        if (std.ascii.eqlIgnoreCase(ext, e.ext)) return e.icon;
    }
    return "file";
}
