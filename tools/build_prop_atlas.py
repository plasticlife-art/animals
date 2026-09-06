#!/usr/bin/env python3
"""Cut scenery sprites out of the CraftPix plants pack into one packed atlas.

The plants sheet is free-form, not a grid: sprites sit at irregular positions
and sizes, and the right half duplicates the left. So the sprites are found as
connected islands of opaque pixels, a curated set is picked by index, and those
are repacked into a uniform grid the renderer can address as (column, row).

Indices refer to the left half of Plants.png ordered top-to-bottom then
left-to-right - the same order the contact sheet used when the set was chosen.

Run:  python3 tools/build_prop_atlas.py
"""

import json
import os
from collections import deque

from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SHEET = os.path.join(ROOT, "assets",
                     "craftpix-net-200380-free-pixel-art-plants-for-farm",
                     "PNG", "Plants.png")
OUT_PNG = os.path.join(ROOT, "assets", "tiles", "props_atlas.png")

# Curated scenery, grouped by where it belongs. Farm crops in the sheet
# (grapes, peppers, beans) are deliberately left out - this is wilderness.
GROUPS = {
    "tree_large": [2, 9, 20],
    "tree_small": [13, 22],
    "bush": [4, 5, 15, 25, 27],
    "meadow": [46, 50, 52, 38, 47],
    "drought": [48, 49, 40],
    "swamp": [17, 18, 19, 36],
    "stone": [54, 51],
}


def islands(image):
    w, h = image.size
    px = image.load()
    seen = [[False] * h for _ in range(w)]
    found = []
    for sx in range(w):
        for sy in range(h):
            if seen[sx][sy] or px[sx, sy][3] == 0:
                continue
            queue = deque([(sx, sy)])
            seen[sx][sy] = True
            x0 = x1 = sx
            y0 = y1 = sy
            count = 0
            while queue:
                x, y = queue.popleft()
                count += 1
                x0, x1 = min(x0, x), max(x1, x)
                y0, y1 = min(y0, y), max(y1, y)
                for dx in (-1, 0, 1):
                    for dy in (-1, 0, 1):
                        nx, ny = x + dx, y + dy
                        if 0 <= nx < w and 0 <= ny < h and not seen[nx][ny] and px[nx, ny][3] > 0:
                            seen[nx][ny] = True
                            queue.append((nx, ny))
            if count >= 30:
                found.append((x0, y0, x1 - x0 + 1, y1 - y0 + 1))
    return found


def main():
    sheet = Image.open(SHEET).convert("RGBA")
    # Left half only: the right half is a duplicate of it.
    left = [b for b in islands(sheet) if b[0] < 384 and b[2] >= 14 and b[3] >= 14]
    left.sort(key=lambda b: (b[1], b[0]))

    picked = []
    manifest = {}
    for group, indices in GROUPS.items():
        manifest[group] = []
        for index in indices:
            if index >= len(left):
                raise IndexError("plant index %d is past the %d islands found" % (index, len(left)))
            manifest[group].append(len(picked))
            picked.append(left[index])

    cell_w = max(b[2] for b in picked)
    cell_h = max(b[3] for b in picked)
    columns = 8
    rows = (len(picked) + columns - 1) // columns
    atlas = Image.new("RGBA", (columns * cell_w, rows * cell_h), (0, 0, 0, 0))
    for slot, (x, y, bw, bh) in enumerate(picked):
        cx = (slot % columns) * cell_w + (cell_w - bw) // 2
        # Bottom-aligned: a prop is planted on the ground, so its base must sit
        # at a predictable place in the cell for the renderer to anchor it.
        cy = (slot // columns) * cell_h + (cell_h - bh)
        atlas.paste(sheet.crop((x, y, x + bw, y + bh)), (cx, cy))
    atlas.save(OUT_PNG)

    print("props_atlas.png %s  cell %dx%d  %d columns x %d rows  %d sprites"
          % (atlas.size, cell_w, cell_h, columns, rows, len(picked)))
    for group, slots in manifest.items():
        print("  %-11s slots %s" % (group, slots))
    print(json.dumps({"cell": [cell_w, cell_h], "columns": columns,
                      "rows": rows, "groups": manifest}))


if __name__ == "__main__":
    main()
