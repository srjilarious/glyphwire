#!/usr/bin/env bash
#
# Fetches the alternate file-type icon themes -- Papirus and Material --
# into assets/icons/filetype/<theme>/, the sets host.conf's `icon_theme`
# can select instead of the default Oxygen (scripts/fetch-oxygen.sh).
# Each is rasterized from SVG to a 48x48 RGBA PNG under the canonical
# name glyphwire uses (folder, file, image, pdf, ...).
#
# Sources:
#   * Papirus   PapirusDevelopmentTeam/papirus-icon-theme  (GPL-3.0)
#               Papirus/48x48/{places,mimetypes,devices}/<name>.svg
#   * Material  material-extensions/vscode-material-icon-theme  (MIT)
#               icons/<name>.svg
#
# $PAPIRUS_REF / $MATERIAL_REF override the git ref fetched from (default
# `master` / `main`).
#
# Needs: curl, one of rsvg-convert / resvg, and python3+Pillow for the
# dark-glyph relight pass.  Safe to re-run.  A source that can't be
# reached (some environments allowlist only certain hosts) just leaves
# that theme's misses reported and moves on -- glyphwire-host falls back
# to Oxygen for a theme directory with no icons.
#
# Usage:  scripts/fetch-icon-themes.sh [papirus|material ...]   (default: both)

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

px=48
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

if command -v rsvg-convert >/dev/null 2>&1; then
    rasterize() { rsvg-convert -w "$px" -h "$px" -o "$2" "$1"; }
elif command -v resvg >/dev/null 2>&1; then
    rasterize() { resvg -w "$px" -h "$px" "$1" "$2"; }
else
    echo "error: need rsvg-convert or resvg on PATH" >&2
    exit 1
fi

pap_ref="${PAPIRUS_REF:-master}"
mat_ref="${MATERIAL_REF:-main}"
pap_root="https://raw.githubusercontent.com/PapirusDevelopmentTeam/papirus-icon-theme/$pap_ref"
pap_base="$pap_root/Papirus/48x48"
pap_license="$pap_root/LICENSE"
mat_root="https://raw.githubusercontent.com/material-extensions/vscode-material-icon-theme/$mat_ref"
mat_base="$mat_root/icons"
mat_license="$mat_root/LICENSE"

ok=0 miss=0

# fetch_svg <base-url> <rel-path> <dest.png>  -- download, following the
# relative symlinks Papirus uses (raw.github hands a symlink back as its
# target path string, not the file), then rasterize.
fetch_svg() {
    local base="$1" rel="$2" dst="$3" svg="$tmp/x.svg"
    local hop
    for hop in 1 2 3 4 5; do
        curl -fsSL -m 20 "$base/$rel" -o "$svg" 2>/dev/null || return 1
        if head -c 400 "$svg" | grep -qi "<svg"; then
            rasterize "$svg" "$dst"
            return 0
        fi
        # Not SVG: maybe a one-line relative symlink target. Resolve it
        # lexically against $rel's directory and try again. Bail if it
        # doesn't look like a plain `.svg` path (no spaces / markup).
        local target
        target="$(tr -d '\r\n' < "$svg")"
        case "$target" in
            *.svg) ;;
            *) return 1 ;;
        esac
        case "$target" in
            *[[:space:]]* | *"<"*) return 1 ;;
        esac
        rel="$(realpath -m -s "/$(dirname "$rel")/$target")"; rel="${rel#/}"
    done
    return 1
}

# do_theme <theme> <base-url> <path-fn>  where path-fn maps a canonical
# name to the source path under base-url, via the `map` assoc array.
do_theme() {
    local theme="$1" base="$2" license_url="$3"; shift 3
    local -n m="$1"
    local out="assets/icons/filetype/$theme"
    mkdir -p "$out"
    rm -f "$out"/*.png
    echo "$theme -> $out/"
    curl -fsSL -m 20 "$license_url" -o "$out/LICENSE.txt" 2>/dev/null \
        && echo "  LICENSE.txt <- $license_url" \
        || echo "  (could not fetch LICENSE from $license_url)" >&2
    local name src
    for name in "${!m[@]}"; do
        src="${m[$name]}"
        if fetch_svg "$base" "$src" "$out/$name.png"; then
            printf '  %-30s <- %s\n' "$out/$name.png" "$src"
            ok=$((ok + 1))
        else
            printf '  MISS  %-16s (%s)\n' "$name" "$src" >&2
            miss=$((miss + 1))
        fi
    done
    # Relight any glyph that would vanish on the near-black row background
    # (same treatment scripts/fetch-devicons.sh gives Devicon's mono logos).
    if command -v python3 >/dev/null 2>&1; then
        python3 scripts/relight-dark-icons.py "$out" || true
    fi
    echo
}

# ---- Papirus: places/ + mimetypes/ + devices/ (all verified present) ----
declare -A papirus=(
    [folder]=places/folder.svg
    [folder-open]=places/folder-open.svg
    [home]=places/user-home.svg
    [file]=mimetypes/text-x-generic.svg
    [text]=mimetypes/text-plain.svg
    [code]=mimetypes/application-x-shellscript.svg
    [web]=mimetypes/text-html.svg
    [image]=mimetypes/image-x-generic.svg
    [audio]=mimetypes/audio-x-generic.svg
    [video]=mimetypes/video-x-generic.svg
    [archive]=mimetypes/application-x-archive.svg
    [package]=mimetypes/package-x-generic.svg
    [pdf]=mimetypes/application-pdf.svg
    [document]=mimetypes/x-office-document.svg
    [spreadsheet]=mimetypes/x-office-spreadsheet.svg
    [presentation]=mimetypes/x-office-presentation.svg
    [executable]=mimetypes/application-x-executable.svg
    [unknown]=mimetypes/unknown.svg
    [drive]=devices/drive-harddisk.svg
    [media-optical]=devices/media-optical.svg
)

# ---- Material: one flat icons/ dir --------------------------------------
declare -A material=(
    [folder]=folder-base.svg
    [folder-open]=folder-base.svg
    [home]=folder-home.svg
    [file]=document.svg
    [text]=document.svg
    [code]=console.svg
    [web]=html.svg
    [image]=image.svg
    [audio]=audio.svg
    [video]=video.svg
    [archive]=zip.svg
    [package]=zip.svg
    [pdf]=pdf.svg
    [document]=word.svg
    [spreadsheet]=table.svg
    [presentation]=powerpoint.svg
    [executable]=exe.svg
    [unknown]=document.svg
    [drive]=disc.svg
    [media-optical]=disc.svg
)

targets=("$@")
[ ${#targets[@]} -eq 0 ] && targets=(papirus material)
for t in "${targets[@]}"; do
    case "$t" in
        papirus)  do_theme papirus  "$pap_base" "$pap_license" papirus ;;
        material) do_theme material "$mat_base" "$mat_license" material ;;
        *) echo "unknown theme: $t" >&2 ;;
    esac
done

echo "done: $ok fetched, $miss missing"
