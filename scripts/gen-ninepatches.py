#!/usr/bin/env python3
# Copyright (c) 2026 Jeff DeWall
# SPDX-License-Identifier: MPL-2.0
"""Regenerates the bundled nine-patch art in assets/ninepatch/.

Each style is drawn at 4x and box-filtered down, so the rounded corners
come out antialiased (the partial-alpha pixels a nine-patch keeps at
native size), then wrapped in the 1px `.9.png` guide border: black on
the top row and left column over the stretchable span. See
`core.parseNinePatch` for how the host reads it.

Usage: scripts/gen-ninepatches.py   (needs Pillow)
"""

from pathlib import Path

from PIL import Image, ImageDraw

SS = 4  # supersampling factor
OUT = Path(__file__).resolve().parent.parent / "assets" / "ninepatch"


def rounded_mask(w, h, radius, inset=0):
    mask = Image.new("L", (w * SS, h * SS), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        (inset * SS, inset * SS, (w - inset) * SS - 1, (h - inset) * SS - 1),
        radius=radius * SS,
        fill=255,
    )
    return mask


def rounded_outline(w, h, radius, width, inset, colour):
    layer = Image.new("RGBA", (w * SS, h * SS), (0, 0, 0, 0))
    ImageDraw.Draw(layer).rounded_rectangle(
        (inset * SS, inset * SS, (w - inset) * SS - 1, (h - inset) * SS - 1),
        radius=radius * SS,
        outline=colour,
        width=width * SS,
    )
    return layer


def with_guides(art, h_span, v_span):
    """Wraps `art` in the guide border. Spans are (first, last) inclusive,
    in the art's own pixel coordinates."""
    w, h = art.size
    out = Image.new("RGBA", (w + 2, h + 2), (0, 0, 0, 0))
    out.paste(art, (1, 1))
    for x in range(h_span[0], h_span[1] + 1):
        out.putpixel((x + 1, 0), (0, 0, 0, 255))
    for y in range(v_span[0], v_span[1] + 1):
        out.putpixel((0, y + 1), (0, 0, 0, 255))
    return out


def vertical_panel(w, h, corner, radius, top, bottom, border):
    """A rounded panel whose fill runs `top` to `bottom` down the vertical
    stretch span (flat under each corner), under a 1px `border`. The ramp
    stretches with the panel's height at pixel precision, so it reads as
    one smooth gradient however many rows the panel covers."""
    fill = Image.new("RGBA", (w * SS, h * SS))
    px = fill.load()
    for y in range(h * SS):
        t = min(max((y / SS - corner) / (h - 2 * corner), 0.0), 1.0)
        c = tuple(round(a + (b - a) * t) for a, b in zip(top, bottom)) + (255,)
        for x in range(w * SS):
            px[x, y] = c
    art = Image.new("RGBA", (w * SS, h * SS), (0, 0, 0, 0))
    art.paste(fill, (0, 0), rounded_mask(w, h, radius))
    art.alpha_composite(rounded_outline(w, h, radius, 1, 0, border))
    art = art.resize((w, h), Image.BOX)
    return with_guides(art, (corner, w - corner - 1), (corner, h - corner - 1))


def dialog():
    # Light blue at the top to dark navy at the bottom, under a white
    # rounded border -- glyphwire-notify's toast.
    return vertical_panel(24, 40, 8, 6, (134, 168, 196), (20, 36, 90), (255, 255, 255, 255))


def panel():
    # A dark popup background with a muted rounded border: zoe's finder
    # frame. The fill falls off slightly towards the bottom so a tall
    # panel doesn't read as a flat slab.
    return vertical_panel(24, 40, 8, 6, (44, 44, 54), (30, 30, 38), (104, 112, 140, 255))


def box():
    # A thin rounded outline over a transparent middle, for framing
    # content on a layer that already has its own background.
    w, h, corner, radius = 24, 24, 8, 4
    art = rounded_outline(w, h, radius, 1, 1, (230, 230, 234, 255))
    art = art.resize((w, h), Image.BOX)
    return with_guides(art, (corner, w - corner - 1), (corner, h - corner - 1))


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    for name, make in (("dialog", dialog), ("panel", panel), ("box", box)):
        path = OUT / f"{name}.9.png"
        make().save(path)
        print(f"wrote {path}")


if __name__ == "__main__":
    main()
