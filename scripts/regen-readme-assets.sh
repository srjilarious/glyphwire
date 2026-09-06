#!/usr/bin/env bash
#
# Regenerates the screenshots embedded in README.md.
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
# ls-table uses -S (compact one-line rows) so the whole table fits the
# frame without scrolling the header off; it still exercises the table
# widget (columns, alt-row stripes, magnitude-coloured sizes).
declare -A scenes=(
    [ls-grid]='ls'
    [ls-table]='ls -l -S'
    [demo]='glyphwire-demo'
)

wanted=("$@")
if [[ ${#wanted[@]} -eq 0 ]]; then
    wanted=(ls-grid ls-table demo)
fi

echo "==> building (zig build)"
zig build

mkdir -p "$out_dir"
tmp_script="$(mktemp)"
trap 'rm -f "$tmp_script"' EXIT

for scene in "${wanted[@]}"; do
    cmds="${scenes[$scene]:-}"
    if [[ -z "$cmds" ]]; then
        echo "warning: unknown scene '$scene', skipping" >&2
        continue
    fi

    printf '%s\n' "$cmds" > "$tmp_script"
    png="$out_dir/$scene.png"
    echo "==> $scene  ->  $png   (commands: $cmds)"

    GLYPHWIRE_SHELL_SCRIPT="$tmp_script" \
        timeout "$host_timeout" ./zig-out/bin/glyphwire \
        --screenshot "$png" --screenshot-delay-ms "$delay_ms" \
        || echo "warning: host exited non-zero for '$scene'" >&2

    # The host exits itself once the shot is taken; the spawned shell and
    # any command it ran get orphaned, so clean them up before the next run.
    pkill -f 'zig-out/bin/gw-shell' 2>/dev/null || true
    pkill -f 'zig-out/bin/glyphwire-demo' 2>/dev/null || true
    pkill -f 'zig-out/bin/gw-ls' 2>/dev/null || true

    if [[ -f "$png" ]]; then
        echo "    wrote $(du -h "$png" | cut -f1)  $png"
    else
        echo "warning: $png was not produced" >&2
    fi
done

echo "==> done"
