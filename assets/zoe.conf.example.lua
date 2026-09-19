-- Example zoe config.
--
-- Copy to ~/.config/glyphwire/zoe.conf.lua (or $GLYPHWIRE_CONFIG_DIR, or
-- $XDG_CONFIG_HOME/glyphwire) to use it. It's a Lua script, run once at
-- startup; assign a single global table named `config` and every key is
-- optional -- with no config at all zoe highlights the nine bundled
-- languages (zig, json, c, python, toml, lua, bash, markdown,
-- markdown_inline) with its built-in dark theme, embedded languages
-- included. See zoe/zoe.conf.template.lua for the full annotated
-- reference.

config = {
    -- Extra extension -> grammar mappings, merged ahead of the built-ins.
    -- Add `.ino` to the C grammar; claim `.conf` for whatever your own
    -- config files actually are.
    languages = {
        { name = "c", extensions = { ".c", ".h", ".ino" } },
        -- { name = "toml", extensions = { ".toml", ".conf" } },
    },

    -- Lines a PageDown / PageUp (or Ctrl-D / Ctrl-U) moves. Default 10.
    page_lines = 10,

    -- Typematic key repeat for the editor, in ms: a held `j` or arrow
    -- starts moving well before a terminal would repeat it. Insert and
    -- command mode are a separate pair, so typing can keep a longer hold
    -- than navigating if you want one.
    key_repeat_delay_ms = 300,
    key_repeat_interval_ms = 30,
    key_repeat_insert_delay_ms = 300,
    key_repeat_insert_interval_ms = 30,

    -- Line-number gutter: false / "absolute" / "relative".
    -- `:set lineno=off|absolute|relative` changes it live.
    line_numbers = "absolute",

    -- Cells between tab stops, and whether the Tab key inserts spaces out
    -- to the next one rather than a literal tab.
    -- `:set tabwidth=N` / `:set expandtab=on|off` change them live.
    tab_width = 4,
    expand_tab = true,

    -- Mark whitespace: a faint dot on each space, a faint arrow on each
    -- tab. `:set whitespace=on|off` changes it live.
    show_whitespace = false,

    -- A few capture-group colors; unset groups keep the built-in value.
    theme = {
        comment = "#6a7a86",
        keyword = "#c678dd",
        ["string"] = "#98c379",
        number = "#d19a66",
        type = "#e5c07b",
        ["function"] = "#61afef",
    },
}
