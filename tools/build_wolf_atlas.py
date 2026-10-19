#!/usr/bin/env python3
"""Build the wolf's stand-in atlas from the fox's: the same frames, the fur turned grey.

The wolf has no art of its own yet. Until it does it is drawn as the fox recoloured -
`assets/sprites/predator_atlas.png`, already composited from the pack, so this needs no
CraftPix files - and larger on the map (`visuals.json` `sprite_scale`). Only the fur is
recoloured: the colours the fox wears alive (rows 0-15), wherever they appear. The colours
seen only in its death rows are its blood, and stay red.

A warm colour (red through orange to cream) becomes a dun grey of about its brightness,
the darkest kept dark so the outline holds; the fox's white and its blue-grey shadows are
left as they are. Deterministic, so a rebuild without changes leaves the file as it is. The
carcass sheet is then made from this atlas as for every species:

Run:  python3 tools/build_wolf_atlas.py && python3 tools/build_carcass_atlases.py
"""

import colorsys
import os

from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SOURCE = os.path.join(ROOT, "assets", "sprites", "predator_atlas.png")
TARGET = os.path.join(ROOT, "assets", "sprites", "wolf_atlas.png")
FRAME = 32
LIVING_ROWS = 16
GREY_HUE = 30.0 / 360.0
GREY_SATURATION = 0.13


def is_warm(rgb):
    hue, saturation, _ = colorsys.rgb_to_hsv(*[c / 255.0 for c in rgb])
    degrees = hue * 360.0
    return saturation >= 0.18 and (degrees >= 330.0 or degrees <= 45.0)


def grey_of(rgb):
    _, _, value = colorsys.rgb_to_hsv(*[c / 255.0 for c in rgb])
    # Dark stays dark, for the outline; the rest a dun grey somewhat darker than the fox.
    shade = value if value < 0.35 else 0.32 + (value - 0.35) * 0.85
    r, g, b = colorsys.hsv_to_rgb(GREY_HUE, GREY_SATURATION, min(1.0, shade))
    return (round(r * 255), round(g * 255), round(b * 255))


def main():
    atlas = Image.open(SOURCE).convert("RGBA")
    width, height = atlas.size
    pixels = atlas.load()
    fur = set()
    for y in range(min(height, LIVING_ROWS * FRAME)):
        for x in range(width):
            r, g, b, a = pixels[x, y]
            if a > 0 and is_warm((r, g, b)):
                fur.add((r, g, b))
    wolf = atlas.copy()
    out = wolf.load()
    for y in range(height):
        for x in range(width):
            r, g, b, a = pixels[x, y]
            if a > 0 and (r, g, b) in fur:
                out[x, y] = grey_of((r, g, b)) + (a,)
    wolf.save(TARGET)
    print("%s %s, %d fur colours recoloured" % (os.path.relpath(TARGET, ROOT), wolf.size, len(fur)))


if __name__ == "__main__":
    main()
