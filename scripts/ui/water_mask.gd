class_name WaterMask
extends RefCounted

## The watering holes as a signed distance field: for each texel of a grid laid over the
## world, how far its centre is from the nearest pond's bank, negative inside it, and which
## pond that is. Baked once per world, since ponds never move, and read by the ground shader
## to draw water, its depth and its shore. Overlapping ponds join into one.
##
## A pond whose level has fallen (`WaterSystem`) is the same field moved in: for a round pond
## the distance to an edge `s` inside the bank is the distance to the bank plus `s`. So the
## shader shrinks each pond by adding its own shrink (`bank_radius - radius`) to the texels it
## owns, and the field is never baked again.


## Bakes the field over `[0, world_size]`. Only each pond's box grown by `reach` is
## visited; a texel further than `reach` from every pond keeps `reach`, which the shader
## reads as dry land.
static func bake(sources: Array, world_size: Vector2, texel: float, reach: float) -> Dictionary:
	var cols := maxi(1, int(ceil(world_size.x / texel)))
	var rows := maxi(1, int(ceil(world_size.y / texel)))
	var cells := PackedFloat32Array()
	cells.resize(cols * rows)
	cells.fill(reach)
	var ids := PackedFloat32Array()
	ids.resize(cols * rows)
	ids.fill(-1.0)
	var mask := {"cells": cells, "ids": ids, "cols": cols, "rows": rows, "texel": texel}
	for pond in range(sources.size()):
		stamp(mask, sources[pond], pond, reach)
	return mask


## Adds one pond to a baked field - a pond the player dug, after the map's own were baked: only
## its box grown by `reach` is visited, and a texel takes it where it is nearer than what the
## texel had.
static func stamp(mask: Dictionary, source: Dictionary, pond: int, reach: float) -> void:
	var cells: PackedFloat32Array = mask["cells"]
	var ids: PackedFloat32Array = mask["ids"]
	var cols: int = mask["cols"]
	var rows: int = mask["rows"]
	var texel: float = mask["texel"]
	var center: Vector2 = source.get("position", Vector2.ZERO)
	var radius := float(source.get("bank_radius", source.get("radius", 0.0)))
	var extent := radius + reach
	var low_x := maxi(0, int(floor((center.x - extent) / texel)))
	var high_x := mini(cols - 1, int(ceil((center.x + extent) / texel)))
	var low_y := maxi(0, int(floor((center.y - extent) / texel)))
	var high_y := mini(rows - 1, int(ceil((center.y + extent) / texel)))
	for y in range(low_y, high_y + 1):
		var texel_y := (float(y) + 0.5) * texel
		for x in range(low_x, high_x + 1):
			var index := y * cols + x
			var distance := Vector2((float(x) + 0.5) * texel, texel_y).distance_to(center) - radius
			if distance < cells[index]:
				cells[index] = distance
				ids[index] = float(pond)
	# Packed arrays are values: hand the changed ones back.
	mask["cells"] = cells
	mask["ids"] = ids


## The field at `world_position`, read the way the shader reads it: blended between the
## four nearest texel centres, clamped at the edges of the grid.
static func sample(mask: Dictionary, world_position: Vector2) -> float:
	var cols: int = mask["cols"]
	var rows: int = mask["rows"]
	var cells: PackedFloat32Array = mask["cells"]
	var p: Vector2 = world_position / float(mask["texel"]) - Vector2(0.5, 0.5)
	var x := floori(p.x)
	var y := floori(p.y)
	var f := p - Vector2(x, y)
	var top := lerpf(_at(cells, cols, rows, x, y), _at(cells, cols, rows, x + 1, y), f.x)
	var bottom := lerpf(_at(cells, cols, rows, x, y + 1), _at(cells, cols, rows, x + 1, y + 1), f.x)
	return lerpf(top, bottom, f.y)


## The field with each pond shrunk by `shrinks[pond]`, read as the shader reads it: each of the
## four nearest texels moved by its own pond's shrink, then blended.
static func sample_shrunk(mask: Dictionary, shrinks: PackedFloat32Array, world_position: Vector2) -> float:
	var cols: int = mask["cols"]
	var rows: int = mask["rows"]
	var p: Vector2 = world_position / float(mask["texel"]) - Vector2(0.5, 0.5)
	var x := floori(p.x)
	var y := floori(p.y)
	var f := p - Vector2(x, y)
	var top := lerpf(_shrunk_at(mask, shrinks, x, y), _shrunk_at(mask, shrinks, x + 1, y), f.x)
	var bottom := lerpf(_shrunk_at(mask, shrinks, x, y + 1), _shrunk_at(mask, shrinks, x + 1, y + 1), f.x)
	return lerpf(top, bottom, f.y)


static func _shrunk_at(mask: Dictionary, shrinks: PackedFloat32Array, x: int, y: int) -> float:
	var cols: int = mask["cols"]
	var rows: int = mask["rows"]
	var index := clampi(y, 0, rows - 1) * cols + clampi(x, 0, cols - 1)
	var pond := int(mask["ids"][index])
	var distance: float = mask["cells"][index]
	return distance if pond < 0 or pond >= shrinks.size() else distance + shrinks[pond]


static func _at(cells: PackedFloat32Array, cols: int, rows: int, x: int, y: int) -> float:
	return cells[clampi(y, 0, rows - 1) * cols + clampi(x, 0, cols - 1)]
