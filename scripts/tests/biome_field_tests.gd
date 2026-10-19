extends RefCounted

## Curved biome borders (`BiomeField`, the shader's `field_surface()` in script): a staircase of
## cells comes out as a curve with no step a cell high; every cell's centre keeps its biome; no
## pixel takes a biome its 3x3 does not have, or one on another level; a pixel is one colour
## within an art pixel; and near a tie the two biomes are dithered into a fringe.

const BiomeFieldScript := preload("res://scripts/ui/biome_field.gd")
const CELL := 96.0
const ART_PX := 6.0
const SIZE := 12
const PARAMS := {"cell": CELL, "art_px": ART_PX, "warp": 0.3, "warp_scale": 1.5, "core": 0.2, "dither_band": 0.0}


func run(a) -> void:
	_test_a_staircase_becomes_a_curve(a)
	_test_cells_keep_their_biome(a)
	_test_no_biome_from_nowhere(a)
	_test_one_colour_an_art_pixel(a)
	_test_a_dithered_fringe(a)


## A diagonal staircase: meadow above `x + y < SIZE`, drought below; `heights` per cell.
static func _staircase(heights_split := false) -> Dictionary:
	var biomes := PackedInt32Array()
	var heights := PackedInt32Array()
	var walkable := PackedByteArray()
	for y in range(SIZE):
		for x in range(SIZE):
			var dry := x + y >= SIZE
			biomes.append(2 if dry else 0)
			heights.append(1 if heights_split and dry else 0)
			walkable.append(1)
	return {"cols": SIZE, "rows": SIZE, "biomes": biomes, "heights": heights, "walkable": walkable}


## Per pixel row, where the drought begins along it, in cells.
static func _edges(grid: Dictionary, field: PackedFloat32Array, params: Dictionary) -> Array:
	var edges: Array = []
	var pixels := int(float(SIZE) * CELL / ART_PX)
	for row in range(int(pixels * 0.25), int(pixels * 0.75)):
		var y := (float(row) + 0.5) * ART_PX
		for column in range(pixels):
			var x := (float(column) + 0.5) * ART_PX
			if BiomeFieldScript.sample(grid, field, Vector2(x, y), params) == 2:
				edges.append(x / CELL)
				break
	return edges


func _test_a_staircase_becomes_a_curve(a) -> void:
	var grid := _staircase()
	var field := BiomeFieldScript.bake(grid)
	var curve := _edges(grid, field, PARAMS)
	var biggest := 0.0
	for index in range(1, curve.size()):
		biggest = maxf(biggest, absf(float(curve[index]) - float(curve[index - 1])))
	# Square cells step their edge a whole cell at each row of cells.
	a.is_true(curve.size() > 0 and biggest < 0.34,
		"the edge moves less than a third of a cell from one pixel row to the next, not a cell (%.2f)" % biggest)


func _test_cells_keep_their_biome(a) -> void:
	for split in [false, true]:
		var grid := _staircase(split)
		var field := BiomeFieldScript.bake(grid)
		var wrong := 0
		for y in range(SIZE):
			for x in range(SIZE):
				var centre := (Vector2(x, y) + Vector2(0.5, 0.5)) * CELL
				if BiomeFieldScript.sample(grid, field, centre, PARAMS) != grid["biomes"][y * SIZE + x]:
					wrong += 1
		a.equal(wrong, 0, "every cell's centre is its own biome%s" % (" (two levels)" if split else ""))


func _test_no_biome_from_nowhere(a) -> void:
	var grid := _staircase()
	var field := BiomeFieldScript.bake(grid)
	var foreign := 0
	var pixels := int(float(SIZE) * CELL / ART_PX)
	for row in range(0, pixels, 3):
		for column in range(0, pixels, 3):
			var world := (Vector2(column, row) + Vector2(0.5, 0.5)) * ART_PX
			var chosen := BiomeFieldScript.sample(grid, field, world, PARAMS)
			var cell := Vector2i(int(world.x / CELL), int(world.y / CELL))
			if chosen != grid["biomes"][cell.y * SIZE + cell.x] and not BiomeFieldScript._nearby(grid, cell, chosen):
				foreign += 1
	a.equal(foreign, 0, "no pixel takes a biome its 3x3 has not")
	var levels := _staircase(true)
	var level_field := BiomeFieldScript.bake(levels)
	var crossed := 0
	for row in range(0, pixels, 3):
		for column in range(0, pixels, 3):
			var world := (Vector2(column, row) + Vector2(0.5, 0.5)) * ART_PX
			var cell := Vector2i(int(world.x / CELL), int(world.y / CELL))
			if BiomeFieldScript.sample(levels, level_field, world, PARAMS) != levels["biomes"][cell.y * SIZE + cell.x]:
				crossed += 1
	a.equal(crossed, 0, "nor one across a change of level")


func _test_one_colour_an_art_pixel(a) -> void:
	var grid := _staircase()
	var field := BiomeFieldScript.bake(grid)
	var mixed := 0
	for index in range(200):
		var corner := Vector2(float(posmod(index * 37, 190)), float(posmod(index * 53, 190))) * ART_PX
		var first := BiomeFieldScript.sample(grid, field, corner + Vector2(0.4, 0.4), PARAMS)
		if BiomeFieldScript.sample(grid, field, corner + Vector2(ART_PX - 0.4, ART_PX - 0.4), PARAMS) != first:
			mixed += 1
	a.equal(mixed, 0, "a pixel of the art is one colour")


func _test_a_dithered_fringe(a) -> void:
	var grid := _staircase()
	var field := BiomeFieldScript.bake(grid)
	var plain := 0
	var dithered := 0
	var pixels := int(float(SIZE) * CELL / ART_PX)
	for row in range(pixels):
		for column in range(pixels):
			var world := (Vector2(column, row) + Vector2(0.5, 0.5)) * ART_PX
			if BiomeFieldScript.sample(grid, field, world, PARAMS) == 2:
				plain += 1
			if BiomeFieldScript.sample(grid, field, world, PARAMS.merged({"dither_band": 0.12}, true)) == 2:
				dithered += 1
	a.is_true(dithered != plain, "near a tie some pixels change hands: a fringe (%d against %d)" % [dithered, plain])
	a.is_true(absf(float(dithered - plain)) < float(plain) * 0.1, "a thin one")
