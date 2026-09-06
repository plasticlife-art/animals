#!/usr/bin/env python3
"""Build the top-down Kenney preset atlases from the roguelike/RPG pack.

The pack is CC0, so unlike `assets/craftpix/` these source files carry no
redistribution restriction.

Source sheet geometry, measured rather than assumed: 968x526 px, 16x16 tiles
laid out on a 17 px pitch (one transparent separator pixel between tiles),
57 columns by 31 rows. Tiles are addressed here as (column, row).

Two atlases come out, and each has to match a contract the engine already has:

* terrain: six surfaces as columns of `tile_px` squares, in the order the
  orthogonal path in `terrain_tilemap.gd` reads from `visuals.terrain.*`
  `atlas_coords`. Kenney draws grass in exactly one shade, so forest and dense
  forest are the grass tile multiplied down - a tint applied once here rather
  than a modulate the renderer would have to carry.

  Each column carries `TERRAIN_VARIANTS` rows: the same tile rotated. The art is
  a flat field with a few darker specks, so a rotation reads as a different tile
  while still tiling seamlessly. Without variants a subdivided cell repeats one
  16x16 stamp in lockstep and the ground reads as graph paper.
* props: a uniform grid of `cell_px` cells, `columns` wide, indexed row-major.
  Every prop is bottom-aligned inside its cell because `_rebuild_props()`
  scales an instance about its base, so a shrunk prop stays planted.

  Trees are drawn on the sheet as 16x32 sprites split across two tile rows, so
  those slots are glued back together from two tiles - see `TWO_TILE_PROPS`.
"""

from PIL import Image
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SHEET = ROOT / "assets/kenney_roguelike-rpg-pack/Spritesheet/roguelikeSheet_transparent.png"
OUT = ROOT / "assets/tiles"

TILE = 16
PITCH = 17  # 16 px tile + 1 px separator

# Surface order is positional: it is what `atlas_coords` in visuals.json points at.
TERRAIN = [
    ("meadow", (5, 0), None),
    ("forest", (5, 0), (0.80, 0.90, 0.72)),
    ("drought", (6, 0), None),
    ("swamp", (11, 11), (0.86, 0.94, 0.88)),
    ("cliff", (7, 0), None),
    ("dense_forest", (5, 0), (0.55, 0.68, 0.46)),
]

PROP_CELL = (16, 32)
PROP_COLUMNS = 8
# Slot index is the position in this list; visuals.json groups reference it.
PROPS = [
    (13, 11), (14, 11), (15, 11), (23, 11),                       # 0-3   broadleaf, trunked
    (16, 11), (17, 11), (18, 11),                                 # 4-6   conifers, trunked
    (13, 9), (14, 9), (15, 9),                                    # 7-9   canopies, no trunk
    (19, 9), (20, 9), (21, 9),                                    # 10-12 bushes
    (41, 23), (42, 23), (43, 23), (44, 23),                       # 13-16 flowers
    (22, 9), (54, 19), (55, 19), (56, 19),                        # 17-20 cactus, dry mounds
    (54, 21), (55, 21), (56, 21),                                 # 21-23 bare rock
    (54, 22), (55, 22), (56, 22),                                 # 24-26 mossy rock
]
# Slots whose sprite spans two sheet tiles: the coordinate in `PROPS` names the
# bottom tile and the crown sits one row above it. Pasting only the bottom tile
# leaves the tree sheared off flat along its widest row.
TWO_TILE_PROPS = frozenset(range(0, 7))


def tile(sheet, coords):
    x, y = coords[0] * PITCH, coords[1] * PITCH
    return sheet.crop((x, y, x + TILE, y + TILE))


def tinted(image, factor):
    if factor is None:
        return image
    out = image.copy()
    px = out.load()
    for j in range(out.height):
        for i in range(out.width):
            r, g, b, a = px[i, j]
            px[i, j] = (int(r * factor[0]), int(g * factor[1]), int(b * factor[2]), a)
    return out


TERRAIN_VARIANTS = 4


def build_terrain(sheet):
    atlas = Image.new("RGBA", (TILE * len(TERRAIN), TILE * TERRAIN_VARIANTS), (0, 0, 0, 0))
    for i, (_name, coords, factor) in enumerate(TERRAIN):
        base = tinted(tile(sheet, coords), factor)
        for v in range(TERRAIN_VARIANTS):
            atlas.paste(base.rotate(90 * v), (i * TILE, v * TILE))
    path = OUT / "kenney_terrain_atlas.png"
    atlas.save(path)
    return path, atlas.size


def build_props(sheet):
    cw, ch = PROP_CELL
    rows = (len(PROPS) + PROP_COLUMNS - 1) // PROP_COLUMNS
    atlas = Image.new("RGBA", (cw * PROP_COLUMNS, ch * rows), (0, 0, 0, 0))
    for slot, coords in enumerate(PROPS):
        sprite = tile(sheet, coords)
        cx, cy = (slot % PROP_COLUMNS) * cw, (slot // PROP_COLUMNS) * ch
        # Bottom-aligned: the instance transform scales about the quad's base.
        atlas.paste(sprite, (cx + (cw - TILE) // 2, cy + ch - TILE))
        if slot in TWO_TILE_PROPS:
            crown = tile(sheet, (coords[0], coords[1] - 1))
            atlas.paste(crown, (cx + (cw - TILE) // 2, cy + ch - 2 * TILE))
    path = OUT / "kenney_props_atlas.png"
    atlas.save(path)
    return path, atlas.size, rows


def main():
    sheet = Image.open(SHEET).convert("RGBA")
    expected = (57 * PITCH - 1, 31 * PITCH - 1)
    if sheet.size != expected:
        raise SystemExit("sheet is %s, expected %s - pack layout changed" % (sheet.size, expected))
    tpath, tsize = build_terrain(sheet)
    ppath, psize, prows = build_props(sheet)
    print("terrain %s %s (%d surfaces, %d variants)"
          % (tpath.name, tsize, len(TERRAIN), TERRAIN_VARIANTS))
    print("props   %s %s (%d slots, %d columns, %d rows)"
          % (ppath.name, psize, len(PROPS), PROP_COLUMNS, prows))


if __name__ == "__main__":
    main()
