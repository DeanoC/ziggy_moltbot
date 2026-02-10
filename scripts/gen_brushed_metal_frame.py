#!/usr/bin/env python3
"""Generate a flat brushed-metal 9-slice frame (border-only).

This produces a 1024x1024 RGBA PNG with:
- brushed metal texture on the border ring
- transparent interior (so panel fill can provide the tiled center)
- rounded corners

It is intentionally "flat" (no lighting gradient); lighting should come from
`panel.overlay` (or future GPU shader).
"""

from __future__ import annotations

import os
from PIL import Image, ImageChops, ImageDraw

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)

DEFAULT_TILE = os.path.join(
    REPO,
    "docs/theme_engine/examples/zsc_brushed_metal/assets/images/brushed_metal_tile.png",
)
DEFAULT_OUT = os.path.join(
    REPO,
    "docs/theme_engine/examples/zsc_brushed_metal/assets/images/brushed_metal_9slice_bordered.png",
)


def make_masks(size: int, border_px: int, radius_px: int) -> tuple[Image.Image, Image.Image]:
    """Return (outer_mask, border_mask) as L images."""
    outer = Image.new("L", (size, size), 0)
    d = ImageDraw.Draw(outer)
    d.rounded_rectangle(
        [0, 0, size - 1, size - 1],
        radius=radius_px,
        fill=255,
    )

    inner = Image.new("L", (size, size), 0)
    d2 = ImageDraw.Draw(inner)
    d2.rounded_rectangle(
        [border_px, border_px, size - 1 - border_px, size - 1 - border_px],
        radius=max(0, radius_px - border_px),
        fill=255,
    )

    border = ImageChops.subtract(outer, inner)
    return outer, border


def main() -> None:
    size = 1024
    border_px = 32
    radius_px = 84

    tile = Image.open(DEFAULT_TILE).convert("RGBA")
    if tile.size != (size, size):
        # Preserve seamlessness by resizing only if needed. (Expect 1024x1024 in repo.)
        tile = tile.resize((size, size), resample=Image.BICUBIC)

    _, border_mask = make_masks(size=size, border_px=border_px, radius_px=radius_px)

    out = Image.new("RGBA", (size, size), (0, 0, 0, 0))

    # Textured border ring.
    border_layer = tile.copy()
    border_layer.putalpha(border_mask)
    out = Image.alpha_composite(out, border_layer)

    # Subtle outline lines to help it read as a frame (still flat, no lighting).
    # Outer stroke
    outline_outer = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    d = ImageDraw.Draw(outline_outer)
    d.rounded_rectangle(
        [0, 0, size - 1, size - 1],
        radius=radius_px,
        outline=(0, 0, 0, 70),
        width=2,
    )
    out = Image.alpha_composite(out, outline_outer)

    # Inner stroke
    outline_inner = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    d2 = ImageDraw.Draw(outline_inner)
    d2.rounded_rectangle(
        [border_px, border_px, size - 1 - border_px, size - 1 - border_px],
        radius=max(0, radius_px - border_px),
        outline=(0, 0, 0, 55),
        width=2,
    )
    out = Image.alpha_composite(out, outline_inner)

    os.makedirs(os.path.dirname(DEFAULT_OUT), exist_ok=True)
    out.save(DEFAULT_OUT)
    print(f"Wrote {DEFAULT_OUT}")


if __name__ == "__main__":
    main()
