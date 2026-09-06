#!/usr/bin/env python3
"""Cut the panel frame and button states out of the CraftPix RPG UI pack.

Everything is exported at 2x, nearest-neighbour, and used at 1:1 by the theme.
Pre-scaling the source is what keeps the pixels crisp: a StyleBoxTexture draws
its 9-patch corners at the texture's own resolution, so scaling the Control tree
instead would leave the corners half the size of everything else - and scaling
the layer would fight the anchored HUD layout.

  panel.png        48x40 frame, uniform 4 px border -> 96x80 with 8 px margins
  button_*.png     56x12 in four states -> 112x24

Run:  python3 tools/build_ui_theme.py
"""

import os

from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PACK = os.path.join(ROOT, "assets", "craftpix-net-255216-free-basic-pixel-art-ui-for-rpg", "PNG")
OUT = os.path.join(ROOT, "assets", "ui")

SCALE = 3
PANEL_RECT = (208, 196, 48, 40)
PANEL_MARGIN = 4
# The four blank wide buttons, one per state. They sit in different columns and
# at slightly different heights - the pressed and disabled art is drawn a pixel
# or two lower on purpose - so each is located by its own measured origin and
# cropped to a common box, otherwise the button would jump when its state
# changes. Found by scanning the sheet for 56x12 islands with no glyph pixels.
BUTTON_SIZE = (56, 13)
# Assigned by measured brightness rather than by column order: the lightest of
# the four reads as a highlight, the darkest as pushed in.
BUTTON_ORIGINS = {
    "normal": (13, 417),
    "hover": (173, 431),
    "pressed": (93, 417),
    "disabled": (253, 434),
}


def export(image, name):
    scaled = image.resize((image.width * SCALE, image.height * SCALE), Image.NEAREST)
    path = os.path.join(OUT, name)
    scaled.save(path)
    return scaled.size


def main():
    os.makedirs(OUT, exist_ok=True)

    tiles = Image.open(os.path.join(PACK, "Main_tiles.png")).convert("RGBA")
    x, y, w, h = PANEL_RECT
    size = export(tiles.crop((x, y, x + w, y + h)), "panel.png")
    print("panel.png %s  9-patch margin %d px" % (size, PANEL_MARGIN * SCALE))

    buttons = Image.open(os.path.join(PACK, "Buttons.png")).convert("RGBA")
    bw, bh = BUTTON_SIZE
    for state, (bx, by) in BUTTON_ORIGINS.items():
        crop = buttons.crop((bx, by, bx + bw, by + bh))
        print("button_%s.png %s" % (state, export(crop, "button_%s.png" % state)))


if __name__ == "__main__":
    main()
