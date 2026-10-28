class_name WaterMask
extends RefCounted

## What `ids` holds over a ford: no pond's, as for the rest of a river, but marked, so the shader
## draws the bar of sand and stones the river is crossed by.
const FORD_ID := -2.0

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
## reads as dry land. A river's banks (`permanent` sources) are no ponds and are not stamped;
## the rivers themselves (`TerrainSystem.rivers`) are, by `stamp_river()`.
static func bake(sources: Array, world_size: Vector2, texel: float, reach: float, rivers: Array = [],
		ford_half: float = 0.0) -> Dictionary:
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
		if not bool(sources[pond].get("permanent", false)):
			stamp(mask, sources[pond], pond, reach)
	for river in rivers:
		stamp_river(mask, river, ford_half, reach)
	return mask


## Adds a river: the distance to its bed less its half width, segment by segment over the texels
## about each, owned by no pond (-1: a river never shrinks). Over a ford the field is held just
## below the water's edge, so the river shows there as shallows, light and narrow, and the texel is
## marked `FORD_ID`.
static func stamp_river(mask: Dictionary, river: Dictionary, ford_half: float, reach: float) -> void:
	var cells: PackedFloat32Array = mask["cells"]
	var ids: PackedFloat32Array = mask["ids"]
	var cols: int = mask["cols"]
	var rows: int = mask["rows"]
	var texel: float = mask["texel"]
	var points: PackedVector2Array = river.get("points", PackedVector2Array())
	var half_width := float(river.get("half_width", 0.0))
	var fords: Array = river.get("fords", [])
	var extent := half_width + reach
	for segment in range(points.size() - 1):
		var a := points[segment]
		var b := points[segment + 1]
		var box := Rect2(a, Vector2.ZERO).expand(b).grow(extent)
		var low_x := maxi(0, int(floor(box.position.x / texel)))
		var high_x := mini(cols - 1, int(ceil(box.end.x / texel)))
		var low_y := maxi(0, int(floor(box.position.y / texel)))
		var high_y := mini(rows - 1, int(ceil(box.end.y / texel)))
		for y in range(low_y, high_y + 1):
			for x in range(low_x, high_x + 1):
				var index := y * cols + x
				var point := Vector2((float(x) + 0.5) * texel, (float(y) + 0.5) * texel)
				var distance := point.distance_to(Geometry2D.get_closest_point_to_segment(point, a, b)) - half_width
				var ford := false
				for spot in fords:
					if point.distance_to(spot) <= ford_half + half_width * 0.5:
						distance = maxf(distance, -texel * 0.75)
						ford = true
						break
				if distance < cells[index]:
					cells[index] = distance
					ids[index] = FORD_ID if ford else -1.0
	mask["cells"] = cells
	mask["ids"] = ids


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
