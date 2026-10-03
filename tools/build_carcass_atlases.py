#!/usr/bin/env python3
"""Build each species' carcass atlas from the frames its death animation ends on.

A body lies where an animal died until it is eaten. It used to be drawn from one sheet
cut from the deer's death row, so a fox or a grouse turned into a deer as its fall ended,
and a fresh body was the deer's red flash frame whatever the animal died of. Each species
now gets a sheet of its own, made from its own atlas (`assets/sprites/<species>_atlas.png`,
already composited from the pack, so this needs no CraftPix files), so the body takes over
from the fall without changing shape or colour:

    columns  0 whole, 1 opened (about half eaten), 2 bones
    rows     0-3 a death without a blow, facing south, north, west, east
             4-7 a kill, the same four directions

Column 0 is the frame the fall ends on, read from `data/config/visuals.json`: the last of
`animations.dead.fall_frames` for rows 0-3 and of `kill_frames` for rows 4-7. The other two
are drawn over it: the belly opened with the ribs across it, then a skeleton lying on the
stain the body left. Deterministic, so a rebuild without changes leaves the files as they are.

Run:  python3 tools/build_carcass_atlases.py
"""

import json
import os

from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
VISUALS = os.path.join(ROOT, "data", "config", "visuals.json")

SOUTH, NORTH, WEST, EAST = 0, 1, 2, 3
BONE = (234, 224, 200, 255)
BONE_SHADE = (168, 152, 126, 255)
SOCKET = (70, 58, 48, 255)
STAIN = (70, 34, 28, 130)
WOUND = (104, 22, 22, 255)
WOUND_RIM = (168, 44, 38, 255)


def res_path(path):
    return os.path.join(ROOT, path.replace("res://", ""))


def crop(image, column, row, size):
    return image.crop((column * size, row * size, (column + 1) * size, (row + 1) * size))


def opaque(frame):
    width, height = frame.size
    return {(x, y) for y in range(height) for x in range(width) if frame.getpixel((x, y))[3] > 0}


def outline(points):
    return {(x, y) for (x, y) in points
            if any((x + dx, y + dy) not in points for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)))}


class Body:
    """A lying body's layout: which way it runs, where its head and its spine are."""

    def __init__(self, points, direction):
        self.points = points
        self.horizontal = direction in (WEST, EAST)
        self.head_high = direction in (EAST, SOUTH)
        alongs = [self.along(p) for p in points]
        self.lo, self.hi = min(alongs), max(alongs)
        self.span = max(1, self.hi - self.lo)
        head_reach = self.span * 0.25
        head = [p for p in points
                if (self.along(p) >= self.hi - head_reach if self.head_high else self.along(p) <= self.lo + head_reach)]
        self.head_along = round(sum(self.along(p) for p in head) / len(head))
        self.head_across = round(sum(self.across(p) for p in head) / len(head))
        middle = sorted(self.across(p) for p in points
                        if self.lo + self.span * 0.25 <= self.along(p) <= self.hi - self.span * 0.25)
        self.spine = middle[len(middle) // 2] if middle else self.head_across
        self.tail = round(self.lo + self.span * 0.12) if self.head_high else round(self.hi - self.span * 0.12)
        self.step = 1 if self.head_high else -1

    def along(self, point):
        return point[0] if self.horizontal else point[1]

    def across(self, point):
        return point[1] if self.horizontal else point[0]

    def at(self, along, across):
        return (along, across) if self.horizontal else (across, along)

    def thickness(self, along):
        column = [self.across(p) for p in self.points if self.along(p) == along]
        return (max(column) - min(column)) if column else 0


def opened(frame, direction):
    """About half eaten: the belly opened, the ribs across it, the rest darker for lying out."""
    out = frame.copy()
    points = opaque(frame)
    if not points:
        return out
    edge = outline(points)
    body = Body(points, direction)
    cx = sum(p[0] for p in points) / len(points)
    cy = sum(p[1] for p in points) / len(points)
    xs = [p[0] for p in points]
    ys = [p[1] for p in points]
    length_share, depth_share = 0.2, 0.24
    rx = max(2.0, (max(xs) - min(xs)) * (length_share if body.horizontal else depth_share))
    ry = max(2.0, (max(ys) - min(ys)) * (depth_share if body.horizontal else length_share))
    for point in points:
        r, g, b, a = frame.getpixel(point)
        reach = ((point[0] - cx) / rx) ** 2 + ((point[1] - cy) / ry) ** 2
        if reach <= 1.0 and point not in edge:
            colour = WOUND if reach < 0.55 else WOUND_RIM
            if reach < 0.55 and body.along(point) % 2 == 0:
                colour = BONE
            out.putpixel(point, colour)
        else:
            out.putpixel(point, (int(r * 0.86), int(g * 0.84), int(b * 0.84), a))
    return out


def bones(frame, direction):
    """Picked clean: a skeleton on the stain the body left - spine, ribs, skull, pelvis."""
    width, height = frame.size
    out = Image.new("RGBA", frame.size, (0, 0, 0, 0))
    points = opaque(frame)
    if not points:
        return out
    for point in points:
        out.putpixel(point, STAIN)
    body = Body(points, direction)

    def put(along, across, colour):
        x, y = body.at(along, across)
        if 0 <= x < width and 0 <= y < height:
            out.putpixel((x, y), colour)

    neck = body.head_along - 2 * body.step
    for along in range(min(body.tail, neck), max(body.tail, neck) + 1):
        put(along, body.spine, BONE)
        put(along, body.spine + 1, BONE_SHADE)
    # The neck bends from the spine up to where the head lay.
    rise = body.head_across - body.spine
    for k in range(1, abs(rise) + 1):
        put(neck + body.step * min(k, 2), body.spine + (k if rise > 0 else -k), BONE)
    # Ribs over the middle half of the body, every other step, as deep as the body is there.
    first = round(body.lo + body.span * 0.3)
    last = round(body.hi - body.span * 0.3)
    for along in range(first, last + 1):
        if (along - body.lo) % 2:
            continue
        reach = max(1, int(body.thickness(along) * 0.32))
        for k in range(1, reach + 1):
            put(along, body.spine - k, BONE)
            put(along, body.spine + 1 + k, BONE_SHADE if k == reach else BONE)
    # The skull where the head lay, an eye socket in it; the pelvis at the other end.
    for da in range(4):
        for db in (-1, 0, 1):
            put(body.head_along - body.step + body.step * da, body.head_across + db, BONE)
    put(body.head_along + body.step, body.head_across, SOCKET)
    for db in (-1, 0, 1, 2):
        put(body.tail, body.spine + db, BONE)
    return out


def build(species, config):
    dead = config["animations"]["dead"]
    size = int(config.get("frame_px", 32))
    directions = int(config.get("directions", 1))
    atlas = Image.open(res_path(config["atlas"])).convert("RGBA")
    ends = [dead["fall_frames"][-1], dead["kill_frames"][-1]]
    sheet = Image.new("RGBA", (3 * size, len(ends) * directions * size), (0, 0, 0, 0))
    for variant, column in enumerate(ends):
        for direction in range(directions):
            whole = crop(atlas, column, dead["row"] + direction, size)
            row = variant * directions + direction
            for stage, image in enumerate([whole, opened(whole, direction), bones(whole, direction)]):
                sheet.paste(image, (stage * size, row * size))
    path = res_path(config["carcass_atlas"])
    sheet.save(path)
    return path, sheet.size


def main():
    visuals = json.load(open(VISUALS))
    for species, config in visuals["species"].items():
        if "carcass_atlas" not in config:
            print("%s: no carcass_atlas, skipped" % species)
            continue
        path, size = build(species, config)
        print("%s %s" % (os.path.relpath(path, ROOT), size))


if __name__ == "__main__":
    main()
