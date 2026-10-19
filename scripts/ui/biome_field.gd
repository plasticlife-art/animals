extends RefCounted

## Curved biome borders (`visuals.borders.mode` "field"): the terrain grid's biomes as a smooth
## field, so where two meet the edge curves through the cells instead of stepping along them.
##
## `bake()` blurs each biome's one-hot mask over the walkable cells - a separable Gaussian,
## normalised by the blurred walkable mask so cliffs and ponds pull no biome away - a weight
## per biome of `BORDERS` and cell, packed with the cell's own data (`packed_image()`). The shader (`ground_traces.gdshader`
## `field_surface()`) reads it bilinearly at the art pixel, moved by a noise warp, and draws the
## biome that weighs most; within `dither_band` of a tie the two first are chosen between by a
## 4x4 Bayer test on art pixels, a ragged fringe a pixel or two wide. Two rules keep it honest:
## a pixel within `core` of its own cell's centre (shaped by half the warp) keeps its cell's
## biome, so a one-cell patch never vanishes and stays a blob, and a pixel may only take a biome some walkable cell of its 3x3 has, on the
## same level, so no colour appears where there is none.
##
## `sample()` is the same in script, for tests: the noise is an integer hash so the two agree
## but for float rounding at a tie. Keep the two in step.

const BORDERS := ["meadow", "forest", "drought", "swamp"]
const BAYER := [0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5]
## Weights for offsets -2..2 of a Gaussian of sigma 0.8 cell.
const KERNEL := [0.0175, 0.2059, 0.5532, 0.2059, 0.0175]


## The grid as `bake()` and `sample()` read it: `cols`, `rows`, and per cell the biome's index
## in `BORDERS` (-1 for another), the height and whether it is walkable.
static func grid_of(terrain) -> Dictionary:
	var count: int = terrain.cols * terrain.rows
	var biomes := PackedInt32Array()
	var heights := PackedInt32Array()
	var walkable := PackedByteArray()
	biomes.resize(count)
	heights.resize(count)
	walkable.resize(count)
	for index in range(count):
		biomes[index] = BORDERS.find(terrain.get_biome_at_index(index))
		heights[index] = terrain.get_height_at_index(index)
		walkable[index] = 1 if terrain.is_walkable_index(index) else 0
	return {"cols": terrain.cols, "rows": terrain.rows, "biomes": biomes, "heights": heights, "walkable": walkable}


## Per cell, each biome's share of the walkable ground around it, blurred: `[w0, w1, w2, w3]`
## flattened, four floats a cell.
static func bake(grid: Dictionary) -> PackedFloat32Array:
	var cols: int = grid["cols"]
	var rows: int = grid["rows"]
	var count := cols * rows
	var biomes: PackedInt32Array = grid["biomes"]
	var walkable: PackedByteArray = grid["walkable"]
	# Five channels: the four biomes and the walkable mask that normalises them.
	var source := PackedFloat32Array()
	source.resize(count * 5)
	for index in range(count):
		if walkable[index] == 0:
			continue
		source[index * 5 + 4] = 1.0
		if biomes[index] >= 0:
			source[index * 5 + biomes[index]] = 1.0
	var across := _blur(source, cols, rows, Vector2i(1, 0))
	var both := _blur(across, cols, rows, Vector2i(0, 1))
	var field := PackedFloat32Array()
	field.resize(count * 4)
	for index in range(count):
		var ground: float = both[index * 5 + 4]
		if ground <= 0.0001:
			continue
		for channel in range(4):
			field[index * 4 + channel] = both[index * 5 + channel] / ground
	return field


static func _blur(source: PackedFloat32Array, cols: int, rows: int, step: Vector2i) -> PackedFloat32Array:
	var result := PackedFloat32Array()
	result.resize(source.size())
	for y in range(rows):
		for x in range(cols):
			var out := (y * cols + x) * 5
			for tap in range(5):
				var sx := clampi(x + step.x * (tap - 2), 0, cols - 1)
				var sy := clampi(y + step.y * (tap - 2), 0, rows - 1)
				var at := (sy * cols + sx) * 5
				var weight: float = KERNEL[tap]
				for channel in range(5):
					result[out + channel] += source[at + channel] * weight
	return result


## The field packed as the shader reads it, in the one texture the borders have
## (`biome_tex`; the ground shader has no texture unit to spare): per cell the first three
## biomes' weights (r, g, b; the fourth is what they leave of 1), and in a the cell's biome
## (bits 0-1), whether it is walkable (2), whether its 3x3 at its level is all its biome (3)
## and its height (4-7).
static func packed_image(grid: Dictionary, field: PackedFloat32Array) -> Image:
	var cols: int = grid["cols"]
	var rows: int = grid["rows"]
	var biomes: PackedInt32Array = grid["biomes"]
	var heights: PackedInt32Array = grid["heights"]
	var walkable: PackedByteArray = grid["walkable"]
	var data := PackedByteArray()
	data.resize(cols * rows * 4)
	for index in range(cols * rows):
		for channel in range(3):
			data[index * 4 + channel] = clampi(int(round(field[index * 4 + channel] * 255.0)), 0, 255)
		var cell := Vector2i(index % cols, index / cols)
		var uniform := true
		for biome in range(4):
			if biome != biomes[index] and _nearby(grid, cell, biome):
				uniform = false
		data[index * 4 + 3] = (maxi(0, biomes[index]) & 3) | (walkable[index] << 2) | ((1 if uniform else 0) << 3) \
			| (clampi(heights[index], 0, 15) << 4)
	return Image.create_from_data(cols, rows, false, Image.FORMAT_RGBA8, data)


## A 32-bit integer hash of a lattice point, 0..1: the shader's `ihash()` bit for bit.
static func ihash(x: int, y: int) -> float:
	var h := ((x * 73856093) ^ (y * 19349663)) & 0xFFFFFFFF
	h ^= h >> 13
	h = (h * 1274126177) & 0xFFFFFFFF
	h ^= h >> 16
	return float(h & 0xFFFF) / 65535.0


static func value_noise(p: Vector2) -> float:
	var i := Vector2(floor(p.x), floor(p.y))
	var f := p - i
	f = f * f * (Vector2(3.0, 3.0) - 2.0 * f)
	var ix := int(i.x)
	var iy := int(i.y)
	return lerpf(lerpf(ihash(ix, iy), ihash(ix + 1, iy), f.x), lerpf(ihash(ix, iy + 1), ihash(ix + 1, iy + 1), f.x), f.y)


## The biome (its index in `BORDERS`) drawn at `world`, from the grid, its baked `field` and
## `params` - `cell`, `art_px`, `warp` and `warp_scale` (cells), `core` (cells), `dither_band`.
static func sample(grid: Dictionary, field: PackedFloat32Array, world: Vector2, params: Dictionary) -> int:
	var cols: int = grid["cols"]
	var rows: int = grid["rows"]
	var cell := float(params.get("cell", 96.0))
	var art_px := float(params.get("art_px", 3.0))
	var own_cell := Vector2i(clampi(int(floor(world.x / cell)), 0, cols - 1), clampi(int(floor(world.y / cell)), 0, rows - 1))
	var own_index := own_cell.y * cols + own_cell.x
	var biomes: PackedInt32Array = grid["biomes"]
	var own: int = biomes[own_index]
	var q := (Vector2(floor(world.x / art_px), floor(world.y / art_px)) + Vector2(0.5, 0.5)) * art_px
	var scale := cell * float(params.get("warp_scale", 1.5))
	var warp := Vector2(value_noise(q / scale), value_noise(q / scale + Vector2(17.0, 5.0))) - Vector2(0.5, 0.5)
	# The core, shaped by half the warp: a lone cell of a biome stays a blob, not a coin.
	var centre := (Vector2(own_cell) + Vector2(0.5, 0.5)) * cell
	if (q + warp * float(params.get("warp", 0.3)) * cell).distance_to(centre) < float(params.get("core", 0.32)) * cell:
		return own
	var p := q + warp * 2.0 * float(params.get("warp", 0.3)) * cell
	var weights := _bilinear(field, cols, rows, p / cell - Vector2(0.5, 0.5))
	var first := own
	var second := own
	var best := -1.0
	var next := -1.0
	for channel in range(4):
		var weight: float = weights[channel]
		if weight > best or (weight == best and channel == own):
			second = first
			next = best
			first = channel
			best = weight
		elif weight > next:
			second = channel
			next = weight
	var chosen := first
	var band := float(params.get("dither_band", 0.12))
	if band > 0.0 and best - next < band and second >= 0:
		var pixel := Vector2i(int(floor(world.x / art_px)), int(floor(world.y / art_px)))
		var threshold := (float(BAYER[posmod(pixel.y, 4) * 4 + posmod(pixel.x, 4)]) + 0.5) / 16.0
		if threshold < 0.5 * (1.0 - (best - next) / band):
			chosen = second
	if chosen == own or not _nearby(grid, own_cell, chosen):
		return own
	return chosen


## Whether biome `biome` is on some walkable cell of the 3x3 around `cell`, at its height.
static func _nearby(grid: Dictionary, cell: Vector2i, biome: int) -> bool:
	var cols: int = grid["cols"]
	var rows: int = grid["rows"]
	var heights: PackedInt32Array = grid["heights"]
	var walkable: PackedByteArray = grid["walkable"]
	var biomes: PackedInt32Array = grid["biomes"]
	var level: int = heights[cell.y * cols + cell.x]
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			var x := cell.x + dx
			var y := cell.y + dy
			if x < 0 or y < 0 or x >= cols or y >= rows:
				continue
			var index := y * cols + x
			if walkable[index] == 1 and biomes[index] == biome and heights[index] == level:
				return true
	return false


static func _bilinear(field: PackedFloat32Array, cols: int, rows: int, p: Vector2) -> Array:
	var i := Vector2i(int(floor(p.x)), int(floor(p.y)))
	var f := p - Vector2(i)
	var result := [0.0, 0.0, 0.0, 0.0]
	for corner in [[0, 0, (1.0 - f.x) * (1.0 - f.y)], [1, 0, f.x * (1.0 - f.y)], [0, 1, (1.0 - f.x) * f.y], [1, 1, f.x * f.y]]:
		var x := clampi(i.x + int(corner[0]), 0, cols - 1)
		var y := clampi(i.y + int(corner[1]), 0, rows - 1)
		var at := (y * cols + x) * 4
		# The shader reads three weights as bytes and the fourth as what they leave: so here.
		var left := 1.0
		for channel in range(3):
			var weight := roundf(field[at + channel] * 255.0) / 255.0
			result[channel] += weight * float(corner[2])
			left -= weight
		result[3] += maxf(0.0, left) * float(corner[2])
	return result
