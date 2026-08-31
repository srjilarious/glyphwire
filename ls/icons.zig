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
//!   * `file/*` -- the coarser file-type buckets (folder, image, audio,
//!     archive, pdf, ...), the fallback for everything without a `dev/`
//!     logo. `file/*` is a *canonical* name: `glyphwire-host` resolves it
//!     to whichever bundled icon theme `host.conf`'s `icon_theme` selects
//!     (`assets/icons/filetype/{oxygen,papirus,material}/`), Oxygen by
//!     default. `oxygen/*` still resolves too, as a back-compat alias.
//!
//! `glyphwire-host` resolves these names server-side for `draw_icon` /
//! `table_set_rows`. This is still a coarse, name-based classification --
//! no mime database, no content sniffing.

const std = @import("std");

/// Extension (including the leading `.`, matched case-insensitively) ->
/// default icon-registry name. First match wins; `iconForExtension`
/// falls back to `"file/file"` for anything not listed.
pub const extension_icons = [_]struct { ext: []const u8, icon: []const u8 }{
    // ── Media / documents / archives: coarse Oxygen buckets ──────────
    .{ .ext = ".png", .icon = "file/image" },
    .{ .ext = ".jpg", .icon = "file/image" },
    .{ .ext = ".jpeg", .icon = "file/image" },
    .{ .ext = ".gif", .icon = "file/image" },
    .{ .ext = ".bmp", .icon = "file/image" },
    .{ .ext = ".svg", .icon = "file/image" },
    .{ .ext = ".webp", .icon = "file/image" },

    .{ .ext = ".mp3", .icon = "file/audio" },
    .{ .ext = ".wav", .icon = "file/audio" },
    .{ .ext = ".flac", .icon = "file/audio" },
    .{ .ext = ".ogg", .icon = "file/audio" },
    .{ .ext = ".m4a", .icon = "file/audio" },

    .{ .ext = ".mp4", .icon = "file/video" },
    .{ .ext = ".mkv", .icon = "file/video" },
    .{ .ext = ".mov", .icon = "file/video" },
    .{ .ext = ".webm", .icon = "file/video" },
    .{ .ext = ".avi", .icon = "file/video" },

    .{ .ext = ".zip", .icon = "file/archive" },
    .{ .ext = ".tar", .icon = "file/archive" },
    .{ .ext = ".gz", .icon = "file/archive" },
    .{ .ext = ".tgz", .icon = "file/archive" },
    .{ .ext = ".xz", .icon = "file/archive" },
    .{ .ext = ".bz2", .icon = "file/archive" },
    .{ .ext = ".7z", .icon = "file/archive" },
    .{ .ext = ".rar", .icon = "file/archive" },
    .{ .ext = ".zst", .icon = "file/archive" },

    .{ .ext = ".deb", .icon = "file/package" },
    .{ .ext = ".rpm", .icon = "file/package" },
    .{ .ext = ".pkg", .icon = "file/package" },
    .{ .ext = ".apk", .icon = "file/package" },

    .{ .ext = ".pdf", .icon = "file/pdf" },

    .{ .ext = ".doc", .icon = "file/document" },
    .{ .ext = ".docx", .icon = "file/document" },
    .{ .ext = ".odt", .icon = "file/document" },
    .{ .ext = ".rtf", .icon = "file/document" },

    .{ .ext = ".xls", .icon = "file/spreadsheet" },
    .{ .ext = ".xlsx", .icon = "file/spreadsheet" },
    .{ .ext = ".ods", .icon = "file/spreadsheet" },
    .{ .ext = ".csv", .icon = "file/spreadsheet" },

    .{ .ext = ".ppt", .icon = "file/presentation" },
    .{ .ext = ".pptx", .icon = "file/presentation" },
    .{ .ext = ".odp", .icon = "file/presentation" },

    .{ .ext = ".txt", .icon = "file/text" },
    .{ .ext = ".rst", .icon = "file/text" },
    .{ .ext = ".log", .icon = "file/text" },
    .{ .ext = ".xml", .icon = "file/text" },
    .{ .ext = ".json", .icon = "file/text" },
    .{ .ext = ".yaml", .icon = "file/text" },
    .{ .ext = ".yml", .icon = "file/text" },
    .{ .ext = ".toml", .icon = "file/text" },
    .{ .ext = ".ini", .icon = "file/text" },

    .{ .ext = ".bin", .icon = "file/executable" },
    .{ .ext = ".exe", .icon = "file/executable" },
    .{ .ext = ".appimage", .icon = "file/executable" },

    .{ .ext = ".iso", .icon = "file/media-optical" },

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
/// listed, and the caller falls back to `"file/folder"`.
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
/// (`extension_icons`), falling back to `"file/file"` for an
/// unrecognized one. `iconForFileName` takes precedence over this at the
/// call site (`ls/main.zig`'s `iconForEntry`) for whole-name matches like
/// `Dockerfile`.
pub fn iconForExtension(name: []const u8) []const u8 {
    const ext = std.fs.path.extension(name);
    for (extension_icons) |e| {
        if (std.ascii.eqlIgnoreCase(ext, e.ext)) return e.icon;
    }
    return "file/file";
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
/// `"file/folder"`).
pub fn iconForDirName(name: []const u8) ?[]const u8 {
    for (dir_icons) |d| {
        if (std.mem.eql(u8, name, d.name)) return d.icon;
    }
    return null;
}
