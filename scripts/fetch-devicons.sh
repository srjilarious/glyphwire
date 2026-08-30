#!/usr/bin/env bash
#
# Fetches the bundled distro + dev logo icons and rasterizes them to the
# 48x48 RGBA PNGs glyphwire-host scans at boot (see host/main.zig's
# loadIconsFromDir -- a file at assets/icons/<sub>/<name>.png registers as
# the catalog name "<sub>/<name>").
#
# Sources:
#   * devicons/devicon  (MIT)  -- distro logos + per-language dev logos.
#     Prefers <name>-original.svg, falls back to <name>-plain.svg.
#   * lobehub/lobe-icons (MIT) -- the Claude / Claude Code marks, which
#     devicon does not carry. Uses the -color variants.
#
# Needs: curl, and one of rsvg-convert / resvg for SVG -> PNG.
#
# Usage:  scripts/fetch-devicons.sh
#         (always refetches every icon; safe to re-run)

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

px=48
distro_dir="assets/icons/distro"
dev_dir="assets/icons/dev"
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

dv_base="https://raw.githubusercontent.com/devicons/devicon/master/icons"
lobe_base="https://raw.githubusercontent.com/lobehub/lobe-icons/master/packages/static-svg/icons"

ok=0
miss=0

# fetch_devicon <devicon-icon-name> <dest-dir> <out-basename>
fetch_devicon() {
    local name="$1" dir="$2" out="$3" svg="$tmp/$1.svg"
    for variant in original plain line; do
        if curl -fsSL -m 20 "$dv_base/$name/$name-$variant.svg" -o "$svg" 2>/dev/null; then
            mkdir -p "$dir"
            rasterize "$svg" "$dir/$out.png"
            printf '  %-22s <- devicon %s-%s\n' "$dir/$out.png" "$name" "$variant"
            ok=$((ok + 1))
            return 0
        fi
    done
    printf '  MISS  %-16s (no devicon icon "%s")\n' "$out" "$name" >&2
    miss=$((miss + 1))
    return 0
}

# fetch_lobe <lobe-icon-file> <dest-dir> <out-basename>
fetch_lobe() {
    local file="$1" dir="$2" out="$3" svg="$tmp/lobe-$3.svg"
    if curl -fsSL -m 20 "$lobe_base/$file" -o "$svg" 2>/dev/null; then
        mkdir -p "$dir"
        rasterize "$svg" "$dir/$out.png"
        printf '  %-22s <- lobehub %s\n' "$dir/$out.png" "$file"
        ok=$((ok + 1))
    else
        printf '  MISS  %-16s (no lobehub icon "%s")\n' "$out" "$file" >&2
        miss=$((miss + 1))
    fi
}

echo "distro logos -> $distro_dir/"
rm -f "$distro_dir"/*.png
# out-name         devicon-name    (out-name keeps existing {icon:distro/*} refs working)
fetch_devicon archlinux    "$distro_dir" arch
fetch_devicon linux        "$distro_dir" tux
fetch_devicon debian       "$distro_dir" debian
fetch_devicon fedora       "$distro_dir" fedora
fetch_devicon ubuntu       "$distro_dir" ubuntu
fetch_devicon centos       "$distro_dir" centos
fetch_devicon redhat       "$distro_dir" redhat
fetch_devicon gentoo       "$distro_dir" gentoo
fetch_devicon nixos        "$distro_dir" nixos
fetch_devicon raspberrypi  "$distro_dir" raspberrypi

echo
echo "dev logos -> $dev_dir/"
rm -f "$dev_dir"/*.png
# Languages
fetch_devicon c            "$dev_dir" c
fetch_devicon cplusplus    "$dev_dir" cpp
fetch_devicon csharp       "$dev_dir" csharp
fetch_devicon dotnetcore   "$dev_dir" dotnet
fetch_devicon go           "$dev_dir" go
fetch_devicon rust         "$dev_dir" rust
fetch_devicon zig          "$dev_dir" zig
fetch_devicon python       "$dev_dir" python
fetch_devicon ruby         "$dev_dir" ruby
fetch_devicon php          "$dev_dir" php
fetch_devicon java         "$dev_dir" java
fetch_devicon kotlin       "$dev_dir" kotlin
fetch_devicon swift        "$dev_dir" swift
fetch_devicon javascript   "$dev_dir" javascript
fetch_devicon typescript   "$dev_dir" typescript
fetch_devicon elixir       "$dev_dir" elixir
fetch_devicon erlang       "$dev_dir" erlang
fetch_devicon haskell      "$dev_dir" haskell
fetch_devicon clojure      "$dev_dir" clojure
fetch_devicon scala        "$dev_dir" scala
fetch_devicon lua          "$dev_dir" lua
fetch_devicon perl         "$dev_dir" perl
fetch_devicon dart         "$dev_dir" dart
fetch_devicon r            "$dev_dir" r
fetch_devicon ocaml        "$dev_dir" ocaml
fetch_devicon nim          "$dev_dir" nim
fetch_devicon crystal      "$dev_dir" crystal
fetch_devicon julia        "$dev_dir" julia
# Web / markup
fetch_devicon html5        "$dev_dir" html5
fetch_devicon css3         "$dev_dir" css3
fetch_devicon sass         "$dev_dir" sass
fetch_devicon react        "$dev_dir" react
fetch_devicon vuejs        "$dev_dir" vuejs
fetch_devicon svelte       "$dev_dir" svelte
# Ecosystem / tooling
fetch_devicon nodejs       "$dev_dir" nodejs
fetch_devicon denojs       "$dev_dir" deno
fetch_devicon bun          "$dev_dir" bun
fetch_devicon docker       "$dev_dir" docker
fetch_devicon git          "$dev_dir" git
fetch_devicon github       "$dev_dir" github
fetch_devicon bash         "$dev_dir" bash
fetch_devicon vim          "$dev_dir" vim
fetch_devicon neovim       "$dev_dir" neovim
fetch_devicon cmake        "$dev_dir" cmake
fetch_devicon npm          "$dev_dir" npm
fetch_devicon markdown     "$dev_dir" markdown
fetch_devicon latex        "$dev_dir" latex
fetch_devicon vscode       "$dev_dir" vscode
# Claude marks (not in devicon)
fetch_lobe    claude-color.svg     "$dev_dir" claude
fetch_lobe    claudecode-color.svg "$dev_dir" claudecode

# A few devicon "-original" logos are a solid near-black glyph (the
# brand's mark really is monochrome black): rust's gear, deno's dino,
# the GitHub cat, the Markdown / LaTeX wordmarks, the Crystal facet.
# glyphwire-ls draws icons on a near-black row background (alt_row_bg =
# rgb(30,30,30)), so those would be invisible. Repaint their opaque
# pixels to a light grey, keeping each pixel's alpha (so the antialiased
# edges survive).
echo
echo "relighting dark-on-dark glyphs"
python3 - "$dev_dir" <<'PY'
import sys, os
from PIL import Image

dev_dir = sys.argv[1]
targets = ["rust", "deno", "github", "markdown", "latex", "crystal"]
light = (213, 213, 213)
for name in targets:
    path = os.path.join(dev_dir, name + ".png")
    if not os.path.exists(path):
        continue
    im = Image.open(path).convert("RGBA")
    px = im.load()
    w, h = im.size
    for y in range(h):
        for x in range(w):
            r, g, b, a = px[x, y]
            if a == 0:
                continue
            # scale the light colour by how bright this pixel already was
            # (near-black -> full light, lighter -> proportionally lighter)
            k = max(r, g, b) / 255.0
            lift = 1.0 - k
            nr = int(r + (light[0] - r) * lift)
            ng = int(g + (light[1] - g) * lift)
            nb = int(b + (light[2] - b) * lift)
            px[x, y] = (nr, ng, nb, a)
    im.save(path)
    print(f"  relit {name}.png")
PY

echo
echo "done: $ok fetched, $miss missing"
