#!/usr/bin/env bash
#
# Regenerates the screenshots embedded in README.md and the site (site/).
#
# For each scene it launches glyphwire-host with:
#   * GLYPHWIRE_SHELL_SCRIPT   -- a file of commands the spawned
#                                 glyphwire-shell replays through its
#                                 prompt as if typed (see shell/main.zig)
#   * --screenshot <path>      -- the host captures its grid region to that
#                                 PNG after --screenshot-delay-ms and quits
#                                 (see host/main.zig)
#
# No keystroke injection or external screenshot tool is involved: the host
# reads its own GL framebuffer back. A Wayland or X session does need to be
# available for the window to open.
#
# Usage:  scripts/regen-readme-assets.sh [scene ...]
#         (no args = all scenes)

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

out_dir="docs/images"
delay_ms="${GLYPHWIRE_SHOT_DELAY_MS:-3000}"
host_timeout="${GLYPHWIRE_SHOT_TIMEOUT:-40}"

if [[ -z "${WAYLAND_DISPLAY:-}" && -z "${DISPLAY:-}" ]]; then
    echo "error: no WAYLAND_DISPLAY or DISPLAY set -- glyphwire-host needs a display to open its window." >&2
    exit 1
fi

# scene name -> shell command(s) to replay, one per line.
# ls-table uses -S (compact one-line rows) on scripts/, small enough that
# the whole table fits the frame without scrolling the header off; it
# still exercises the table widget (columns, alt-row stripes,
# magnitude-coloured sizes).
# gw-read has no scene: a good shot needs a book with a mokuro sidecar and
# a word selected in the OCR dialog, so docs/images/gw-read.png is taken by
# hand.
# zoe-split opens a .zoe-workspace written below (two editor groups side
# by side, in its own theme); @WS@ is replaced by the workspace file's
# path. shell replays several lines (each scene's lines run as if typed,
# one per line), and view draws the logo inline below a listing. Scenes name gw-ls rather than ls, which is
# /usr/bin/ls without an alias.
declare -A scenes=(
    [ls-grid]='gw-ls'
    [ls-table]='gw-ls -l -S scripts'
    [demo]='glyphwire-demo'
    [zoe]='zoe src/client.zig'
    [salacommander]='salacommander . docs'
    [gwmd]='gwmd docs/protocol.md'
    [grep]='gw-grep --expand -C 2 -m 3 "fn connect" src'
    [zoe-split]='zoe @WS@'
    [gwmd-light]='gwmd docs/zoe-keys.md'
    [shell]=$'cd docs\ngw-ls -S\ngit log --oneline -4\nfalse'
    [view]=$'gw-ls -S assets\ngw-view assets/glyphwire_icon.png'
)

# scene name -> built-in theme name for a scene shot in a theme other than
# the pinned one below.
declare -A scene_themes=(
    [gwmd-light]='catppuccin-latte'
)

wanted=("$@")
if [[ ${#wanted[@]} -eq 0 ]]; then
    wanted=(ls-grid ls-table demo zoe salacommander gwmd grep zoe-split gwmd-light shell view)
fi

echo "==> building (zig build)"
zig build

mkdir -p "$out_dir"
tmp_script="$(mktemp)"
tmp_dir="$(mktemp -d)"
trap 'rm -f "$tmp_script"; rm -rf "$tmp_dir"' EXIT

# Outside the repo so zoe's rewrite of it on exit touches nothing tracked.
ws_file="$tmp_dir/shot.zoe-workspace"
cat > "$ws_file" <<WS
{
  "version": 1,
  "folders": [ { "path": "$repo_root", "name": "glyphwire" } ],
  "theme": "tokyo-night",
  "editors": {
    "split": "vertical", "ratio": 0.5,
    "first": { "files": ["$repo_root/src/protocol.zig"], "active": 0 },
    "second": { "files": ["$repo_root/zoe/workspace.zig", "$repo_root/README.md"], "active": 0, "focused": true }
  }
}
WS

for scene in "${wanted[@]}"; do
    cmds="${scenes[$scene]:-}"
    if [[ -z "$cmds" ]]; then
        echo "warning: unknown scene '$scene', skipping" >&2
        continue
    fi

    cmds="${cmds//@WS@/$ws_file}"
    printf '%s\n' "$cmds" > "$tmp_script"
    png="$out_dir/$scene.png"
    echo "==> $scene  ->  $png   (commands: $cmds)"

    # Every scene runs on a config dir of its own, never yours: the
    # window's look pinned (font, size, grid, theme), the example powerline
    # prompt, and nothing else, so no alias, saved session or
    # default_program of yours reaches the shot. State and history go to
    # the temp dir too, so a run leaves no trace in your own.
    cfg="$tmp_dir/config-$scene"
    mkdir -p "$cfg"
    cat > "$cfg/host.conf.lua" <<'HOST'
config = {
    font_face = "DejaVuSansM Nerd Font Mono",
    font_size = 22.0,
    cursor_shape = "underline",
    grid_cols = 150,
    grid_rows = 30,
}
HOST
    theme="${scene_themes[$scene]:-}"
    if [[ -n "$theme" ]]; then
        printf 'config = { theme = "%s" }\n' "$theme" > "$cfg/theme.lua"
    else
        printf 'config = { theme = { base = "gruvbox-dark", palette = { bg = "#121212" } } }\n' \
            > "$cfg/theme.lua"
    fi
    cp assets/shell.conf.example.lua "$cfg/shell.conf.lua"
    scene_env=(
        GLYPHWIRE_CONFIG_DIR="$cfg"
        XDG_STATE_HOME="$tmp_dir/state-$scene"
        GLYPHWIRE_NO_HISTORY=1
    )

    env "${scene_env[@]}" GLYPHWIRE_SHELL_SCRIPT="$tmp_script" \
        timeout "$host_timeout" ./zig-out/bin/glyphwire \
        --screenshot "$png" --screenshot-delay-ms "$delay_ms" \
        || echo "warning: host exited non-zero for '$scene'" >&2

    # The host exits itself once the shot is taken; the spawned shell and
    # any command it ran get orphaned, so clean them up before the next run.
    pkill -f 'zig-out/bin/gw-shell' 2>/dev/null || true
    pkill -f 'zig-out/bin/glyphwire-demo' 2>/dev/null || true
    pkill -f 'zig-out/bin/gw-ls' 2>/dev/null || true
    pkill -f 'zig-out/bin/zoe' 2>/dev/null || true
    pkill -f 'zig-out/bin/salacommander' 2>/dev/null || true
    pkill -f 'zig-out/bin/gwmd' 2>/dev/null || true
    pkill -f 'zig-out/bin/gw-grep' 2>/dev/null || true
    pkill -f 'zig-out/bin/gw-view' 2>/dev/null || true

    if [[ -f "$png" ]]; then
        echo "    wrote $(du -h "$png" | cut -f1)  $png"
    else
        echo "warning: $png was not produced" >&2
    fi
done

echo "==> done"
