//! Name -> icon-registry-name lookups for `glyphwire-ls`, split out of
//! `ls/main.zig` into the pure `ls_support` module so `tests/ls_tests.zig`
//! can exercise them directly (same reason `ls/format.zig` lives here).
//!
//! Two icon subtrees are referenced:
//!
//!   * `dev/*` -- the Devicon programming-language / developer-tool logos
//!     under `assets/icons/dev/` (plus the two LobeHub Claude marks). A
//!     recognised source file, or a well-known project directory / dotfile,
//!     gets its language's real logo here.
//!   * `oxygen/*` -- the coarser KDE-Oxygen file-type buckets under
//!     `assets/icons/oxygen/`, the fallback for everything without a `dev/`
//!     logo (images, audio, video, archives, office docs, ...).
//!
//! `glyphwire-host` resolves these names server-side for `draw_icon` /
//! `table_set_rows`. This is still a coarse, name-based classification --
//! no mime database, no content sniffing.

const std = @import("std");

/// Extension (including the leading `.`, matched case-insensitively) ->
/// default icon-registry name. First match wins; `iconForExtension`
/// falls back to `"oxygen/file"` for anything not listed.
pub const extension_icons = [_]struct { ext: []const u8, icon: []const u8 }{
    // ── Media / documents / archives: coarse Oxygen buckets ──────────
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
    .{ .ext = ".rst", .icon = "oxygen/text" },
    .{ .ext = ".log", .icon = "oxygen/text" },
    .{ .ext = ".xml", .icon = "oxygen/text" },
    .{ .ext = ".json", .icon = "oxygen/text" },
    .{ .ext = ".yaml", .icon = "oxygen/text" },
    .{ .ext = ".yml", .icon = "oxygen/text" },
    .{ .ext = ".toml", .icon = "oxygen/text" },
    .{ .ext = ".ini", .icon = "oxygen/text" },

    .{ .ext = ".bin", .icon = "oxygen/executable" },
    .{ .ext = ".exe", .icon = "oxygen/executable" },
    .{ .ext = ".appimage", .icon = "oxygen/executable" },

    .{ .ext = ".iso", .icon = "oxygen/media-optical" },

    // ── Source files: the language's real Devicon logo ──────────────
    .{ .ext = ".md", .icon = "dev/markdown" },
    .{ .ext = ".markdown", .icon = "dev/markdown" },
    .{ .ext = ".tex", .icon = "dev/latex" },

    .{ .ext = ".html", .icon = "dev/html5" },
    .{ .ext = ".htm", .icon = "dev/html5" },
    .{ .ext = ".css", .icon = "dev/css3" },
    .{ .ext = ".scss", .icon = "dev/sass" },
    .{ .ext = ".sass", .icon = "dev/sass" },
    .{ .ext = ".vue", .icon = "dev/vuejs" },
    .{ .ext = ".svelte", .icon = "dev/svelte" },

    .{ .ext = ".c", .icon = "dev/c" },
    .{ .ext = ".h", .icon = "dev/c" },
    .{ .ext = ".cpp", .icon = "dev/cpp" },
    .{ .ext = ".cc", .icon = "dev/cpp" },
    .{ .ext = ".cxx", .icon = "dev/cpp" },
    .{ .ext = ".hpp", .icon = "dev/cpp" },
    .{ .ext = ".hh", .icon = "dev/cpp" },
    .{ .ext = ".hxx", .icon = "dev/cpp" },
    .{ .ext = ".cs", .icon = "dev/csharp" },

    .{ .ext = ".go", .icon = "dev/go" },
    .{ .ext = ".rs", .icon = "dev/rust" },
    .{ .ext = ".zig", .icon = "dev/zig" },
    .{ .ext = ".zon", .icon = "dev/zig" },

    .{ .ext = ".py", .icon = "dev/python" },
    .{ .ext = ".pyw", .icon = "dev/python" },
    .{ .ext = ".pyi", .icon = "dev/python" },
    .{ .ext = ".rb", .icon = "dev/ruby" },
    .{ .ext = ".php", .icon = "dev/php" },
    .{ .ext = ".pl", .icon = "dev/perl" },
    .{ .ext = ".pm", .icon = "dev/perl" },
    .{ .ext = ".lua", .icon = "dev/lua" },
    .{ .ext = ".r", .icon = "dev/r" },
    .{ .ext = ".jl", .icon = "dev/julia" },

    .{ .ext = ".java", .icon = "dev/java" },
    .{ .ext = ".kt", .icon = "dev/kotlin" },
    .{ .ext = ".kts", .icon = "dev/kotlin" },
    .{ .ext = ".scala", .icon = "dev/scala" },
    .{ .ext = ".sc", .icon = "dev/scala" },
    .{ .ext = ".clj", .icon = "dev/clojure" },
    .{ .ext = ".cljs", .icon = "dev/clojure" },
    .{ .ext = ".cljc", .icon = "dev/clojure" },
    .{ .ext = ".edn", .icon = "dev/clojure" },
    .{ .ext = ".swift", .icon = "dev/swift" },

    .{ .ext = ".js", .icon = "dev/javascript" },
    .{ .ext = ".mjs", .icon = "dev/javascript" },
    .{ .ext = ".cjs", .icon = "dev/javascript" },
    .{ .ext = ".jsx", .icon = "dev/react" },
    .{ .ext = ".ts", .icon = "dev/typescript" },
    .{ .ext = ".tsx", .icon = "dev/react" },

    .{ .ext = ".ex", .icon = "dev/elixir" },
    .{ .ext = ".exs", .icon = "dev/elixir" },
    .{ .ext = ".erl", .icon = "dev/erlang" },
    .{ .ext = ".hrl", .icon = "dev/erlang" },
    .{ .ext = ".hs", .icon = "dev/haskell" },
    .{ .ext = ".ml", .icon = "dev/ocaml" },
    .{ .ext = ".mli", .icon = "dev/ocaml" },
    .{ .ext = ".nim", .icon = "dev/nim" },
    .{ .ext = ".nims", .icon = "dev/nim" },
    .{ .ext = ".cr", .icon = "dev/crystal" },
    .{ .ext = ".dart", .icon = "dev/dart" },

    .{ .ext = ".sh", .icon = "dev/bash" },
    .{ .ext = ".bash", .icon = "dev/bash" },
    .{ .ext = ".zsh", .icon = "dev/bash" },
    .{ .ext = ".ksh", .icon = "dev/bash" },
    .{ .ext = ".fish", .icon = "dev/bash" },
    .{ .ext = ".vim", .icon = "dev/vim" },
};

/// Exact file basename (matched case-sensitively) -> icon-registry name,
/// for files whose type lives in the whole name rather than an extension
/// (`Dockerfile`, `Makefile`, ...). Checked before `extension_icons`.
pub const filename_icons = [_]struct { name: []const u8, icon: []const u8 }{
    .{ .name = "Dockerfile", .icon = "dev/docker" },
    .{ .name = "Containerfile", .icon = "dev/docker" },
    .{ .name = ".dockerignore", .icon = "dev/docker" },
    .{ .name = "docker-compose.yml", .icon = "dev/docker" },
    .{ .name = "docker-compose.yaml", .icon = "dev/docker" },
    .{ .name = "compose.yml", .icon = "dev/docker" },
    .{ .name = "compose.yaml", .icon = "dev/docker" },

    .{ .name = "CMakeLists.txt", .icon = "dev/cmake" },

    .{ .name = ".gitignore", .icon = "dev/git" },
    .{ .name = ".gitattributes", .icon = "dev/git" },
    .{ .name = ".gitmodules", .icon = "dev/git" },

    .{ .name = "package.json", .icon = "dev/npm" },
    .{ .name = "package-lock.json", .icon = "dev/npm" },
    .{ .name = ".npmrc", .icon = "dev/npm" },

    .{ .name = "go.mod", .icon = "dev/go" },
    .{ .name = "go.sum", .icon = "dev/go" },

    .{ .name = "Gemfile", .icon = "dev/ruby" },
    .{ .name = "Rakefile", .icon = "dev/ruby" },

    .{ .name = ".vimrc", .icon = "dev/vim" },
    .{ .name = ".bashrc", .icon = "dev/bash" },
    .{ .name = ".bash_profile", .icon = "dev/bash" },
    .{ .name = ".zshrc", .icon = "dev/bash" },
};

/// Exact directory basename (matched case-sensitively) -> icon-registry
/// name, so a project's tooling directory shows that tool's logo instead
/// of the generic folder. `iconForDirName` returns null for anything not
/// listed, and the caller falls back to `"oxygen/folder"`.
pub const dir_icons = [_]struct { name: []const u8, icon: []const u8 }{
    .{ .name = ".vscode", .icon = "dev/vscode" },
    .{ .name = ".claude", .icon = "dev/claude" },
    .{ .name = ".git", .icon = "dev/git" },
    .{ .name = ".github", .icon = "dev/github" },
    .{ .name = "node_modules", .icon = "dev/nodejs" },
    .{ .name = ".cargo", .icon = "dev/rust" },
    .{ .name = ".docker", .icon = "dev/docker" },
    .{ .name = ".vim", .icon = "dev/vim" },
    .{ .name = "nvim", .icon = "dev/neovim" },
};

/// The icon-registry name for a regular file, derived from its extension
/// (`extension_icons`), falling back to `"oxygen/file"` for an
/// unrecognized one. `iconForFileName` takes precedence over this at the
/// call site (`ls/main.zig`'s `iconForEntry`) for whole-name matches like
/// `Dockerfile`.
pub fn iconForExtension(name: []const u8) []const u8 {
    const ext = std.fs.path.extension(name);
    for (extension_icons) |e| {
        if (std.ascii.eqlIgnoreCase(ext, e.ext)) return e.icon;
    }
    return "oxygen/file";
}

/// The `dev/*` logo for an exact file basename (`filename_icons`), or null
/// if the name isn't one of the special-cased ones.
pub fn iconForFileName(name: []const u8) ?[]const u8 {
    for (filename_icons) |f| {
        if (std.mem.eql(u8, name, f.name)) return f.icon;
    }
    return null;
}

/// The `dev/*` logo for an exact directory basename (`dir_icons`), or null
/// if the name isn't one of the special-cased ones (the caller then uses
/// `"oxygen/folder"`).
pub fn iconForDirName(name: []const u8) ?[]const u8 {
    for (dir_icons) |d| {
        if (std.mem.eql(u8, name, d.name)) return d.icon;
    }
    return null;
}
