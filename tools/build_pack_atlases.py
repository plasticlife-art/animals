#!/usr/bin/env python3
"""Composite the CraftPix Hunt Animals pack into the atlases the renderer wants.

The pack ships one sheet per animation, each laid out as four direction rows by
N frame columns, 32x32 frames. The renderer draws one MultiMesh per species and
therefore needs a single texture per species, addressed as (column, row). This
builds that texture.

Row order in the output is `animation_index * 4 + direction_index`, with the
directions kept in the pack's own order:

    0 south (toward the viewer)   1 north (away)   2 west (left)   3 east (right)

That order is the pack's convention, not a guarantee: `Fox_Run` ships its two
side views the other way round, which drew every running fox facing backwards.
`SHEET_DIRECTION_ORDER` carries the per-sheet exceptions, and `check_direction_order()`
below re-derives the convention from the pixels after the remap so the next odd
sheet is caught here instead of in the game.

Note on `eat`: the pack has no eating animation, so grazing borrows Idle. That
is one substituted state out of five - worth knowing when watching a herd,
because a grazing animal will look like a standing one.

Run:  python3 tools/build_pack_atlases.py
"""

import os

from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PACK = os.path.join(ROOT, "assets", "craftpix", "PNG", "Without_shadow")
OUT = os.path.join(ROOT, "assets", "sprites")

FRAME = 32
DIRECTIONS = 4
# Logical animation -> the pack's sheet name. `eat` is a deliberate stand-in.
ANIMATIONS = [
    ("idle", "Idle"),
    ("walk", "Walk"),
    ("run", "Run"),
    ("eat", "Idle"),
    ("dead", "Death"),
]
SPECIES = {"herbivore": "Deer", "predator": "Fox", "scavenger": "Black_grouse"}

# Not every animal in the pack has every sheet. The grouse has no Run - it takes
# off instead - so its run rows come from Flight, which is what a startled bird
# does anyway.
ANIMATION_OVERRIDES = {"scavenger": {"run": "Flight"}}


def animations_for(species):
    overrides = ANIMATION_OVERRIDES.get(species, {})
    return [(key, overrides.get(key, name)) for key, name in ANIMATIONS]

# (animal, sheet) -> source row for each output direction. Absent means identity.
# Fox_Run has west and east swapped relative to every other Fox sheet, and
# Black_grouse_Flight disagrees with the rest of the grouse's the same way.
SHEET_DIRECTION_ORDER = {
    ("Black_grouse", "Flight"): [0, 1, 3, 2],
    ("Fox", "Run"): [0, 1, 3, 2],
}


def find_sheet(animal, name):
    """The pack is inconsistent about capitalisation (Fox_walk, Boar_shadow)."""
    folder = os.path.join(PACK, animal)
    wanted = ("%s_%s.png" % (animal, name)).lower()
    for entry in os.listdir(folder):
        if entry.lower() == wanted:
            return os.path.join(folder, entry)
    raise FileNotFoundError("%s / %s" % (animal, name))


def direction_order(animal, name):
    return SHEET_DIRECTION_ORDER.get((animal, name), list(range(DIRECTIONS)))


def _row_bias(sheet, row, frame):
    """Mean x of the opaque pixels in one frame - where the sprite's mass sits.

    A four-legged animal seen from the side is lopsided: head one end, tail the
    other. The sign of `bias(west) - bias(east)` is therefore constant across an
    animal's sheets, and a sheet that disagrees has its side rows swapped.
    """
    pixels = sheet.crop((frame * FRAME, row * FRAME,
                         (frame + 1) * FRAME, (row + 1) * FRAME)).load()
    total = 0
    weighted = 0
    for y in range(FRAME):
        for x in range(FRAME):
            if pixels[x, y][3] >= 128:
                total += 1
                weighted += x
    return None if total == 0 else float(weighted) / total


def check_direction_order(animal, sheets):
    """Warn when one sheet's side rows disagree with the rest of the animal's.

    Runs on the already-remapped rows, so a sheet listed in SHEET_DIRECTION_ORDER
    is expected to agree here - a warning means the table needs another entry.
    """
    votes = {}
    for name, sheet in sheets:
        order = direction_order(animal, name)
        frame = min(1, sheet.width // FRAME - 1)
        west = _row_bias(sheet, order[2], frame)
        east = _row_bias(sheet, order[3], frame)
        if west is None or east is None or abs(west - east) < 0.25:
            continue
        votes[name] = west < east

    if not votes:
        return []
    majority = sum(1 for agrees in votes.values() if agrees) * 2 >= len(votes)
    return ["%s_%s: side rows look swapped - add it to SHEET_DIRECTION_ORDER"
            % (animal, name)
            for name, agrees in votes.items() if agrees != majority]


def build_species(species, animal):
    animations = animations_for(species)
    sheets = [(key, name, Image.open(find_sheet(animal, name)).convert("RGBA"))
              for key, name in animations]
    columns = max(sheet.width // FRAME for _, _, sheet in sheets)
    rows = len(animations) * DIRECTIONS
    atlas = Image.new("RGBA", (columns * FRAME, rows * FRAME), (0, 0, 0, 0))

    meta = {}
    for anim_index, (key, name, sheet) in enumerate(sheets):
        frames = sheet.width // FRAME
        order = direction_order(animal, name)
        meta[key] = {"row": anim_index * DIRECTIONS, "frames": frames}
        for direction in range(DIRECTIONS):
            source_row = order[direction]
            for frame in range(frames):
                box = (frame * FRAME, source_row * FRAME,
                       (frame + 1) * FRAME, (source_row + 1) * FRAME)
                atlas.paste(sheet.crop(box),
                            (frame * FRAME, (anim_index * DIRECTIONS + direction) * FRAME))

    path = os.path.join(OUT, "%s_atlas.png" % species)
    atlas.save(path)
    warnings = check_direction_order(
        animal, [(name, sheet) for _, name, sheet in sheets])
    return atlas.size, columns, rows, meta, warnings


def build_carcass():
    """Three stages taken from the tail of the deer's death animation: the shared sheet,
    drawn only for a species without one of its own (tools/build_carcass_atlases.py)."""
    sheet = Image.open(find_sheet("Deer", "Death")).convert("RGBA")
    frames = sheet.width // FRAME
    picks = [frames - 3, frames - 2, frames - 1]
    atlas = Image.new("RGBA", (len(picks) * FRAME, FRAME), (0, 0, 0, 0))
    for i, frame in enumerate(picks):
        # Row 0 is the south-facing view, which reads best lying down.
        atlas.paste(sheet.crop((frame * FRAME, 0, (frame + 1) * FRAME, FRAME)), (i * FRAME, 0))
    path = os.path.join(OUT, "carcass_atlas.png")
    atlas.save(path)
    return atlas.size, len(picks)


def main():
    for species, animal in SPECIES.items():
        size, columns, rows, meta, warnings = build_species(species, animal)
        print("%s_atlas.png %s  %d columns x %d rows" % (species, size, columns, rows))
        for key, info in meta.items():
            print("    %-5s row %2d, %d frames" % (key, info["row"], info["frames"]))
        for name in sorted(n for a, n in SHEET_DIRECTION_ORDER if a == animal):
            print("    remapped directions: %s_%s %s"
                  % (animal, name, SHEET_DIRECTION_ORDER[(animal, name)]))
        for warning in warnings:
            print("    WARNING %s" % warning)
    print("carcass_atlas.png %s  %d stages" % build_carcass())


if __name__ == "__main__":
    main()
