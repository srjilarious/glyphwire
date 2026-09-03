-- glyphwire-host configuration.
--
-- Read once at startup (see host/main.zig `loadFontConfig`). Every field is
-- optional; anything left out keeps the built-in default shown below. Delete
-- this file entirely to use all defaults.

config = {
    -- Primary font file, relative to the repo root. TTF/OTF, or a TTC
    -- collection (then set `font_face_name` to pick a face out of it).
    font_face = "assets/NotoSansCJK-Regular.ttc",

    -- For a TTC: substring of the desired face's name (case-sensitive).
    -- Ignored for a plain TTF/OTF. Falls back to face 0 if not found.
    font_face_name = "Mono CJK JP",

    -- Face tried for any codepoint the primary lacks, before the tofu box.
    font_fallback = "assets/JetBrainsMono-Regular.ttf",

    -- Starting cell size in pixels. Clamped to 8..72. At runtime,
    -- Ctrl+- / Ctrl++ step it by 2 and Ctrl+0 returns to this value.
    font_size = 20.0,
}
