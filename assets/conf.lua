-- glyphwire-host configuration.
--
-- Read once at startup (see host/main.zig `loadConfig`). Every field is
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

    -- Caret shape: "line" (a vertical bar at the cell's left edge, the
    -- default), "block" (fills the cell), "box" (a hollow outline), or
    -- "underline" (a bar along the cell's bottom). block/box/underline
    -- cover both cells of a wide (CJK) character.
    cursor_shape = "line",

    -- Whether the caret blinks. It always shows solid the moment the
    -- caret moves or the window scrolls, and resumes blinking once things
    -- settle.
    cursor_blink = true,

    -- Blink half-period in milliseconds: the caret is shown for this long,
    -- then hidden for this long. Clamped to 100..5000.
    cursor_blink_ms = 530.0,

    -- Initial grid size in cells. The window opens this many cells wide/tall
    -- (times the measured cell pixel size); after that it's user-resizable
    -- and the grid tracks the window. Clamped up to 16 cols / 4 rows. A
    -- `--grid-cols` / `--grid-rows` command-line flag overrides these.
    -- grid_cols = 120,
    -- grid_rows = 50,

    -- Root layer scrollback depth, in rows: how many scrolled-off rows the
    -- history ring keeps for the mouse wheel / scrollbar to reach. Clamped
    -- to 0..100000.
    -- scrollback_rows = 1000,
}
