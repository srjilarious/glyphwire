#!/usr/bin/env python3
"""Lighten near-black icon glyphs so they stay visible on glyphwire-ls's
near-black row background (alt_row_bg = rgb(30,30,30)).

For every *.png in the directory given as argv[1], any icon whose opaque
pixels are, on average, very dark is repainted toward light grey -- each
pixel lifted in proportion to how dark it already was, alpha preserved so
antialiased edges survive. Multi-tone / already-light icons are left
alone. Same approach scripts/fetch-devicons.sh applies inline to a few
Devicon brand marks; factored out here so fetch-icon-themes.sh can reuse
it.

Needs Pillow. A missing directory or Pillow is a no-op, not an error.
"""
import os
import sys

try:
    from PIL import Image
except ImportError:
    sys.exit(0)

LIGHT = (213, 213, 213)
# Repaint an icon only if the mean brightness of its opaque pixels is at
# or below this (0..255) -- i.e. it really is a dark-on-transparent glyph.
DARK_MEAN = 60


def relight(path):
    im = Image.open(path).convert("RGBA")
    px = im.load()
    w, h = im.size

    total = 0.0
    count = 0
    for y in range(h):
        for x in range(w):
            r, g, b, a = px[x, y]
            if a < 16:
                continue
            total += max(r, g, b)
            count += 1
    if count == 0 or total / count > DARK_MEAN:
        return False

    for y in range(h):
        for x in range(w):
            r, g, b, a = px[x, y]
            if a == 0:
                continue
            k = max(r, g, b) / 255.0
            lift = 1.0 - k
            px[x, y] = (
                int(r + (LIGHT[0] - r) * lift),
                int(g + (LIGHT[1] - g) * lift),
                int(b + (LIGHT[2] - b) * lift),
                a,
            )
    im.save(path)
    return True


def main():
    if len(sys.argv) < 2 or not os.path.isdir(sys.argv[1]):
        return
    for name in sorted(os.listdir(sys.argv[1])):
        if not name.endswith(".png"):
            continue
        path = os.path.join(sys.argv[1], name)
        if relight(path):
            print(f"  relit {name}")


if __name__ == "__main__":
    main()
