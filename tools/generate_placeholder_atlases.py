#!/usr/bin/env python3
"""Generate placeholder art atlases for Engine of Ecosystem.

These stand in until a real CC0 pack is dropped in. The geometry produced here
is the contract that data/config/visuals.json describes, so a replacement pack
only has to match the frame sizes and row order below.

  terrain_atlas.png   6 tiles in one row, 32px each
                      meadow, forest, drought, swamp, cliff, dense_forest
  <species>_atlas.png 4 frames per row, 5 rows, 32px frames
                      row order: idle, walk, run, eat, dead
  carcass_atlas.png   3 frames in one row, 32px each
                      fresh, picked, bones

Run:  python3 tools/generate_placeholder_atlases.py
"""

import os
import random

from PIL import Image, ImageDraw

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TILE_PX = 32
FRAME_PX = 32
FRAMES_PER_ROW = 4

# Matches data/config/world.json terrain colors and the debug_color values in
# scripts/agents/herbivore.gd and scripts/agents/predator.gd, so the placeholder
# build looks continuous with the old draw_rect / draw_circle rendering.
BIOMES = [
    ("meadow", (79, 105, 56)),
    ("forest", (51, 77, 46)),
    ("drought", (122, 99, 51)),
    ("swamp", (46, 69, 59)),
]
OBSTACLES = [
    ("cliff", (92, 94, 102)),
    # Was (20, 41, 28), which is dark enough that a thicket read as a hole in
    # the map rather than as ground you cannot walk through.
    ("dense_forest", (42, 72, 48)),
]

SPECIES = {
    "herbivore": {"body": (181, 224, 138), "dark": (120, 158, 88)},
    "predator": {"body": (237, 120, 82), "dark": (166, 74, 48)},
}

ANIMATION_ROWS = ["idle", "walk", "run", "eat", "dead"]


def shade(color, amount):
    return tuple(max(0, min(255, int(c + amount))) for c in color)


def face_shade(color, factor):
    """Darken proportionally, for the side faces of an isometric tile.

    Subtracting a fixed amount instead - which is what this used to do - clips
    dark surfaces to black: forest and dense forest walls came out at roughly
    (0, 19, 0) and read as holes punched in the map rather than as steps.
    """
    return tuple(max(0, min(255, int(c * factor))) for c in color)


def draw_terrain_tile(draw, ox, oy, base, rng, speckle):
    draw.rectangle([ox, oy, ox + TILE_PX - 1, oy + TILE_PX - 1], fill=base)
    for _ in range(speckle):
        x = ox + rng.randrange(TILE_PX)
        y = oy + rng.randrange(TILE_PX)
        draw.point((x, y), fill=shade(base, rng.choice((-22, -12, 12, 22))))


def build_terrain_atlas(path):
    tiles = BIOMES + OBSTACLES
    image = Image.new("RGBA", (TILE_PX * len(tiles), TILE_PX), (0, 0, 0, 0))
    draw = ImageDraw.Draw(image)
    for index, (name, base) in enumerate(tiles):
        rng = random.Random(hash(name) & 0xFFFF)
        speckle = 90 if name in ("cliff", "dense_forest") else 55
        draw_terrain_tile(draw, index * TILE_PX, 0, base, rng, speckle)
    image.save(path)
    return image.size


def draw_creature(draw, ox, oy, palette, row, frame):
    """One 32x32 top-down creature frame, facing right."""
    body = palette["body"]
    dark = palette["dark"]
    cx, cy = ox + 14, oy + 16

    if row == "dead":
        # Belly up: flattened body, legs pointing out, washed out palette.
        pale = shade(body, -35)
        draw.ellipse([cx - 9, cy - 4, cx + 9, cy + 4], fill=pale, outline=shade(dark, -20))
        for lx, ly in ((-5, -7), (-5, 7), (3, -7), (3, 7)):
            draw.rectangle([cx + lx, cy + ly - 1, cx + lx + 1, cy + ly + 1], fill=shade(dark, -20))
        draw.ellipse([cx + 8, cy - 3, cx + 14, cy + 3], fill=pale, outline=shade(dark, -20))
        return

    bob = (0, 1, 0, 1)[frame] if row == "idle" else (0, 1, 2, 1)[frame]
    if row == "run":
        bob *= 2
    cy -= bob

    stride = {"idle": 0, "walk": 2, "run": 3, "eat": 0}[row]
    swing = (-1, 0, 1, 0)[frame] * stride

    # Legs first so the body sits on top of them.
    for lx, base_ly in ((-5, -7), (-5, 7), (4, -7), (4, 7)):
        ly = base_ly + (swing if lx < 0 else -swing)
        draw.rectangle([cx + lx, cy + ly - 1, cx + lx + 1, cy + ly + 1], fill=dark)

    length = 10 if row == "run" else 9
    draw.ellipse([cx - length, cy - 6, cx + length - 2, cy + 6], fill=body, outline=dark)
    draw.line([cx - length - 3, cy, cx - length + 1, cy], fill=dark)  # tail

    head_x, head_y = cx + 9, cy
    if row == "eat":
        head_x += 1
        head_y += (0, 2, 3, 2)[frame]
    draw.ellipse([head_x - 4, head_y - 4, head_x + 4, head_y + 4], fill=body, outline=dark)
    draw.point((head_x + 2, head_y - 2), fill=dark)
    draw.point((head_x + 2, head_y + 2), fill=dark)


def build_species_atlas(path, palette):
    width = FRAME_PX * FRAMES_PER_ROW
    height = FRAME_PX * len(ANIMATION_ROWS)
    image = Image.new("RGBA", (width, height), (0, 0, 0, 0))
    draw = ImageDraw.Draw(image)
    for row_index, row in enumerate(ANIMATION_ROWS):
        for frame in range(FRAMES_PER_ROW):
            draw_creature(draw, frame * FRAME_PX, row_index * FRAME_PX, palette, row, frame)
    image.save(path)
    return image.size


def build_carcass_atlas(path):
    stages = 3
    image = Image.new("RGBA", (FRAME_PX * stages, FRAME_PX), (0, 0, 0, 0))
    draw = ImageDraw.Draw(image)
    meat = (150, 92, 84)
    bone = (214, 208, 190)
    for stage in range(stages):
        ox = stage * FRAME_PX
        cx, cy = ox + 16, 16
        if stage < 2:
            width = 10 - stage * 3
            draw.ellipse([cx - width, cy - 5, cx + width, cy + 5],
                         fill=shade(meat, -stage * 20), outline=shade(meat, -60))
        for i in range(4):
            bx = cx - 6 + i * 4
            draw.line([bx, cy - 4, bx, cy + 4], fill=bone)
        draw.ellipse([cx + 7, cy - 3, cx + 13, cy + 3], fill=bone, outline=shade(meat, -60))
    image.save(path)
    return image.size


ISO_TILE_W = 64
ISO_TILE_H = 32
ISO_SKIRT_STEP = 16
ISO_SKIRT_LEVELS = 4


def _diamond_points(ox, oy):
    """Corners of one isometric top face, clockwise from the top."""
    return [
        (ox + ISO_TILE_W // 2, oy),
        (ox + ISO_TILE_W - 1, oy + ISO_TILE_H // 2),
        (ox + ISO_TILE_W // 2, oy + ISO_TILE_H - 1),
        (ox, oy + ISO_TILE_H // 2),
    ]


def _fill_diamond(draw, ox, oy, colour):
    """Top face drawn as an explicit 2:1 staircase rather than a polygon.

    A polygon fill approximates the edge and leaves single-pixel gaps where two
    diamonds meet, which reads as a dotted seam across the whole map. Stepping
    the rows by hand - widths 4, 8, ... 64, 64, ... 8, 4 - is the shape that
    actually tiles.
    """
    half = ISO_TILE_H // 2
    for row in range(ISO_TILE_H):
        span = row + 1 if row < half else ISO_TILE_H - row
        width = span * 4
        x0 = ox + ISO_TILE_W // 2 - width // 2
        draw.rectangle([x0, oy + row, x0 + width - 1, oy + row], fill=colour)


def build_isometric_terrain_atlas(path):
    """Isometric terrain tiles: one row per surface, one column per face pair.

    Each tile is a 64x32 top face with vertical faces hanging below it. The two
    faces an isometric camera can see drop independently - a cell can be a step
    above its right neighbour while flush with its left one - so the depth of
    each is a separate axis of the atlas. Collapsing them onto a single depth
    draws a wall where the ground is flat, which is visible on roughly a
    quarter of a noisy map.

    Column index is `left * ISO_SKIRT_LEVELS + right`, where left is the drop
    toward +y and right the drop toward +x.
    """
    tiles = BIOMES + OBSTACLES
    tile_h = ISO_TILE_H + ISO_SKIRT_STEP * (ISO_SKIRT_LEVELS - 1)
    columns = ISO_SKIRT_LEVELS * ISO_SKIRT_LEVELS
    image = Image.new("RGBA", (ISO_TILE_W * columns, tile_h * len(tiles)), (0, 0, 0, 0))
    draw = ImageDraw.Draw(image)
    mid = ISO_TILE_W // 2

    for row, (name, base) in enumerate(tiles):
        rng = random.Random(hash(name) & 0xFFFF)
        for left in range(ISO_SKIRT_LEVELS):
            for right in range(ISO_SKIRT_LEVELS):
                ox = (left * ISO_SKIRT_LEVELS + right) * ISO_TILE_W
                oy = row * tile_h
                left_depth = ISO_SKIRT_STEP * left
                right_depth = ISO_SKIRT_STEP * right
                if left_depth:
                    draw.polygon(
                        [(ox, oy + ISO_TILE_H // 2), (ox + mid, oy + ISO_TILE_H - 1),
                         (ox + mid, oy + ISO_TILE_H - 1 + left_depth),
                         (ox, oy + ISO_TILE_H // 2 + left_depth)],
                        fill=face_shade(base, 0.52))
                if right_depth:
                    draw.polygon(
                        [(ox + mid, oy + ISO_TILE_H - 1), (ox + ISO_TILE_W - 1, oy + ISO_TILE_H // 2),
                         (ox + ISO_TILE_W - 1, oy + ISO_TILE_H // 2 + right_depth),
                         (ox + mid, oy + ISO_TILE_H - 1 + right_depth)],
                        fill=face_shade(base, 0.72))
                _fill_diamond(draw, ox, oy, base)
                for _ in range(26):
                    x = ox + rng.randrange(ISO_TILE_W)
                    y = oy + rng.randrange(ISO_TILE_H)
                    if image.getpixel((x, y))[3]:
                        draw.point((x, y), fill=shade(base, rng.choice((-18, -10, 10, 18))))
    image.save(path)
    return image.size, tile_h


def build_shadow_texture(path):
    """Soft elliptical blob drawn under every animal.

    Cheapest readability win there is: without it sprites look pasted onto the
    tiles rather than standing on them. Alpha falls off toward the rim so the
    edge does not read as a hard ring.
    """
    w, h = 48, 24
    image = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    px = image.load()
    cx, cy = (w - 1) / 2.0, (h - 1) / 2.0
    for y in range(h):
        for x in range(w):
            nx = (x - cx) / cx
            ny = (y - cy) / cy
            d = (nx * nx + ny * ny) ** 0.5
            if d >= 1.0:
                continue
            px[x, y] = (12, 18, 10, int(215 * (1.0 - d) ** 1.5))
    image.save(path)
    return image.size


def main():
    tiles_dir = os.path.join(ROOT, "assets", "tiles")
    sprites_dir = os.path.join(ROOT, "assets", "sprites")
    os.makedirs(tiles_dir, exist_ok=True)
    os.makedirs(sprites_dir, exist_ok=True)

    print("terrain_atlas.png", build_terrain_atlas(os.path.join(tiles_dir, "terrain_atlas.png")))
    iso_size, iso_tile_h = build_isometric_terrain_atlas(
        os.path.join(tiles_dir, "terrain_iso_atlas.png"))
    print("terrain_iso_atlas.png", iso_size, "tile", (ISO_TILE_W, iso_tile_h))
    for name, palette in SPECIES.items():
        size = build_species_atlas(os.path.join(sprites_dir, "%s_atlas.png" % name), palette)
        print("%s_atlas.png" % name, size)
    print("carcass_atlas.png", build_carcass_atlas(os.path.join(sprites_dir, "carcass_atlas.png")))
    print("shadow.png", build_shadow_texture(os.path.join(sprites_dir, "shadow.png")))


if __name__ == "__main__":
    main()
