#!/usr/bin/env bash
#
# Fetches the KDE Oxygen file-type icons at their native 48x48 size into
# assets/icons/filetype/oxygen/ -- the default set behind glyphwire's
# canonical file/* icon names (see host.conf's icon_theme). Straight PNG
# pull, no rasterization.
#
# Sources (both LGPL-3.0):
#   * pasnox/oxygen-icons-png        48x48/{places,mimetypes,devices,status}/ --
#                                    primary, because it dereferences the many
#                                    icons KDE stores as symlinks (raw.github
#                                    hands those back as a path string, not a
#                                    PNG).
#   * KDE/oxygen-icons               fallback for anything pasnox lacks.
#
# Needs: curl.  Safe to re-run (refetches everything).
#
# Usage:  scripts/fetch-oxygen.sh

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

out="assets/icons/filetype/oxygen"
mkdir -p "$out"

kde="https://raw.githubusercontent.com/KDE/oxygen-icons/master/48x48"
pasnox="https://raw.githubusercontent.com/pasnox/oxygen-icons-png/master/oxygen/48x48"

ok=0
miss=0

# True if $1 begins with the PNG magic bytes (so a symlink-target string
# handed back by raw.github doesn't get saved as an "icon").
is_png() { [ "$(head -c8 "$1" | od -An -tx1 | tr -d ' \n')" = "89504e470d0a1a0a" ]; }

# fetch <out-basename> <upstream-relative-path>  (e.g. mimetypes/text-plain.png)
# pasnox first (dereferenced), then KDE.
fetch() {
    local out_name="$1" rel="$2" dst="$out/$1.png"
    for src in "pasnox|$pasnox" "KDE|$kde"; do
        local label="${src%%|*}" base="${src#*|}"
        if curl -fsSL -m 20 "$base/$rel" -o "$dst" 2>/dev/null && is_png "$dst"; then
            printf '  %-24s <- %s %s\n' "$dst" "$label" "$rel"
            ok=$((ok + 1)); return 0
        fi
    done
    rm -f "$dst"
    printf '  MISS  %-16s (no 48x48 PNG for %s)\n' "$out_name" "$rel" >&2
    miss=$((miss + 1)); return 0
}

echo "Oxygen 48x48 -> $out/"
rm -f "$out"/*.png

fetch folder         places/folder.png
fetch folder-open    status/folder-open.png
fetch home           places/user-home.png
fetch file           mimetypes/text-x-generic.png
fetch text           mimetypes/text-plain.png
fetch code           mimetypes/application-x-shellscript.png
fetch web            mimetypes/text-html.png
fetch image          mimetypes/image-x-generic.png
fetch audio          mimetypes/audio-x-generic.png
fetch video          mimetypes/video-x-generic.png
fetch archive        mimetypes/application-x-archive.png
fetch package        mimetypes/application-x-rpm.png
fetch pdf            mimetypes/application-pdf.png
fetch document       mimetypes/x-office-document.png
fetch spreadsheet    mimetypes/x-office-spreadsheet.png
fetch presentation   mimetypes/x-office-presentation.png
fetch executable     mimetypes/application-x-executable.png
fetch unknown        mimetypes/unknown.png
fetch drive          devices/drive-harddisk.png
fetch media-optical  devices/media-optical.png

echo
echo "done: $ok fetched, $miss missing"
