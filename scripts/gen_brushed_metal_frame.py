#!/usr/bin/env python3
"""Generate a flat brushed-metal 9-slice panel frame (with center).

This produces a 1024x1024 RGBA PNG with:
- brushed metal texture everywhere (center included)
- a darker border ring + crisp strokes
- no lighting gradient (flat); lighting should come from `panel.overlay` (or a future shader)

This avoids visible seams between a separate tiled fill and a border-only frame.
"""

from __future__ import annotations

import os
from PIL import Image, ImageChops, ImageDraw, ImageEnhance

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


def make_masks(size: int, border_px: int, radius_px: int) -> tuple[Image.Image, Image.Image, Image.Image]:
    """Return (outer_mask, inner_mask, border_mask) as L images."""
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
    return outer, inner, border


def main() -> None:
    size = 1024
    border_px = 32
    radius_px = 84

    tile = Image.open(DEFAULT_TILE).convert("RGBA")
    if tile.size != (size, size):
        # Preserve seamlessness by resizing only if needed. (Expect 1024x1024 in repo.)
        tile = tile.resize((size, size), resample=Image.BICUBIC)

    outer_mask, inner_mask, border_mask = make_masks(size=size, border_px=border_px, radius_px=radius_px)

    # Start from full brushed metal texture (center included).
    out = tile.copy()

    # Darken the border ring so it reads as "chrome".
    darker = ImageEnhance.Brightness(tile).enhance(0.80)
    out = Image.composite(darker, out, border_mask)

    # Outside the rounded panel: paint black so we don't rely on alpha/rounded image fills.
    black_bg = Image.new("RGBA", (size, size), (0, 0, 0, 255))
    out = Image.composite(out, black_bg, outer_mask)

    # Crisp strokes (still flat, no lighting).
    d = ImageDraw.Draw(out)
    # Outer stroke
    d.rounded_rectangle(
        [0, 0, size - 1, size - 1],
        radius=radius_px,
        outline=(0, 0, 0, 255),
        width=6,
    )
    # Inner stroke
    d.rounded_rectangle(
        [border_px, border_px, size - 1 - border_px, size - 1 - border_px],
        radius=max(0, radius_px - border_px),
        outline=(0, 0, 0, 140),
        width=2,
    )

    os.makedirs(os.path.dirname(DEFAULT_OUT), exist_ok=True)
    out.save(DEFAULT_OUT)
    print(f"Wrote {DEFAULT_OUT}")


if __name__ == "__main__":
    main()
