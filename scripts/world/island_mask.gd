class_name IslandMask
extends RefCounted

## The world as an island (`terrain.island`): land in the middle of the map and sea all round it,
## so nothing walks off the map and nothing comes onto it. Per terrain cell, the same grid as
## `TerrainSystem` (`terrain.cell_size`, the grass cell without it), land or sea and how far each
## land cell lies from the sea.
##
## The shape is a rounded rectangle (a superellipse of power `shape_power` over the map, so it
## fills a 16:9 map as it fills a square one) broken by a noise of its own (`noise_frequency` per
## cell, `noise_amplitude`, `noise_octaves`, warped by `warp` cells); the land is the `land_share`
## of the map lowest in that field, never within `min_sea_cells` of the map's edge and rising to
## the sea over `edge_band_cells` inside that. Two rounds of
## smoothing take off single-cell spits and inlets; then only the largest land (four-way, as a
## walker crosses a corner only with one side open) is kept, the rest drowned, and every sea not
## joined to the open sea - a lake inside the land - is land: ponds are the island's lakes.
##
## A generator of its own, seeded from the world's seed (`seed` adds to it), as the rivers' is:
## the world's stream is not drawn from, so the island changes nothing else that is drawn.
## Missing or `enabled` false, there is no island and the map is the rectangle it always was.

const SALT := 0x15A4D
const SEA := 0
const LAND := 1


static func enabled(world_config: Dictionary) -> bool:
	return bool(world_config.get("terrain", {}).get("island", {}).get("enabled", false))


## `{cols, rows, cell_size, land, coast}` for `world_config`'s map and `world_seed`: `land` a byte
## per cell (`LAND` or `SEA`), `coast` how many cells each land cell's centre lies from the nearest
## sea cell's (0 at sea). Empty without an island.
static func build(world_config: Dictionary, world_seed: int) -> Dictionary:
	if not enabled(world_config):
		return {}
	var config: Dictionary = world_config.get("terrain", {}).get("island", {})
	var size_config: Dictionary = world_config.get("world_size", {})
	var world_size := Vector2(float(size_config.get("x", 1600.0)), float(size_config.get("y", 900.0)))
	var terrain_config: Dictionary = world_config.get("terrain", {})
	var cell_size := float(terrain_config.get("cell_size", world_config.get("grass", {}).get("cell_size", 32.0)))
	var cols := maxi(1, int(ceil(world_size.x / cell_size)))
	var rows := maxi(1, int(ceil(world_size.y / cell_size)))
	var count := cols * rows

	var noise := FastNoiseLite.new()
	noise.seed = (world_seed ^ SALT) + int(config.get("seed", 0))
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	noise.fractal_octaves = maxi(1, int(config.get("noise_octaves", 5)))
	noise.frequency = float(config.get("noise_frequency", 0.022))
	var warp := maxf(0.0, float(config.get("warp", 14.0)))
	if warp > 0.0:
		noise.domain_warp_enabled = true
		noise.domain_warp_type = FastNoiseLite.DOMAIN_WARP_SIMPLEX
		noise.domain_warp_amplitude = warp
		noise.domain_warp_frequency = noise.frequency * 0.5
	var power := maxf(1.0, float(config.get("shape_power", 2.2)))
	var amplitude := maxf(0.0, float(config.get("noise_amplitude", 0.45)))
	var margin := maxi(1, int(config.get("min_sea_cells", 4)))
	# Over the `edge_band_cells` inside that the field rises to the sea, so a coast that runs near
	# the map's edge still winds rather than following it in a straight line.
	var band := maxf(1.0, float(config.get("edge_band_cells", 10.0)))
	var share := clampf(float(config.get("land_share", 0.69)), 0.05, 0.95)

	var field := PackedFloat32Array()
	field.resize(count)
	var open := PackedFloat32Array()
	for y in range(rows):
		for x in range(cols):
			var index := y * cols + x
			var edge := mini(mini(x, y), mini(cols - 1 - x, rows - 1 - y))
			if edge < margin:
				field[index] = INF
				continue
			var u := absf((float(x) + 0.5) / float(cols) * 2.0 - 1.0)
			var v := absf((float(y) + 0.5) / float(rows) * 2.0 - 1.0)
			var value := pow(pow(u, power) + pow(v, power), 1.0 / power) + amplitude * noise.get_noise_2d(float(x), float(y))
			var rise := clampf(1.0 - float(edge - margin) / band, 0.0, 1.0)
			value += rise * rise * (1.0 + amplitude)
			field[index] = value
			open.append(value)
	open.sort()
	var threshold := -INF
	if not open.is_empty():
		threshold = open[clampi(int(float(count) * share), 0, open.size() - 1)]

	var land := PackedByteArray()
	land.resize(count)
	for index in range(count):
		land[index] = LAND if field[index] < threshold else SEA
	for _round in range(2):
		land = _smoothed(land, field, cols, rows)
	land = _largest_land(land, cols, rows)
	land = _without_lakes(land, cols, rows)
	return {"cols": cols, "rows": rows, "cell_size": cell_size, "land": land, "coast": coast_distances(land, cols, rows)}


## How many cells of `mask` are land.
static func land_count(mask: Dictionary) -> int:
	var land: PackedByteArray = mask.get("land", PackedByteArray())
	var total := 0
	for value in land:
		total += int(value)
	return total


## One round of a cellular smoothing over the eight neighbours: land with five or more of them
## land, sea with three or fewer, as it was otherwise. The forced sea by the edge stays sea.
static func _smoothed(land: PackedByteArray, field: PackedFloat32Array, cols: int, rows: int) -> PackedByteArray:
	var next := land.duplicate()
	for y in range(rows):
		for x in range(cols):
			var index := y * cols + x
			if is_inf(field[index]):
				continue
			var around := 0
			for dy in [-1, 0, 1]:
				for dx in [-1, 0, 1]:
					if dx == 0 and dy == 0:
						continue
					var nx: int = x + dx
					var ny: int = y + dy
					if nx >= 0 and ny >= 0 and nx < cols and ny < rows and land[ny * cols + nx] == LAND:
						around += 1
			if around >= 5:
				next[index] = LAND
			elif around <= 3:
				next[index] = SEA
	return next


## `land` with only its largest four-way piece of land kept.
static func _largest_land(land: PackedByteArray, cols: int, rows: int) -> PackedByteArray:
	var pieces := _pieces(land, cols, rows, LAND)
	var largest := -1
	var largest_size := 0
	for piece in range(pieces[1]):
		if int(pieces[2][piece]) > largest_size:
			largest_size = int(pieces[2][piece])
			largest = piece
	var labels: PackedInt32Array = pieces[0]
	var kept := land.duplicate()
	for index in range(land.size()):
		if land[index] == LAND and labels[index] != largest:
			kept[index] = SEA
	return kept


## `land` with every sea not joined (four-way) to the map's edge turned to land.
static func _without_lakes(land: PackedByteArray, cols: int, rows: int) -> PackedByteArray:
	var pieces := _pieces(land, cols, rows, SEA)
	var labels: PackedInt32Array = pieces[0]
	var open := {}
	for x in range(cols):
		open[labels[x]] = true
		open[labels[(rows - 1) * cols + x]] = true
	for y in range(rows):
		open[labels[y * cols]] = true
		open[labels[y * cols + cols - 1]] = true
	var filled := land.duplicate()
	for index in range(land.size()):
		if land[index] == SEA and not open.has(labels[index]):
			filled[index] = LAND
	return filled


## Four-way pieces of the cells equal to `value`: `[labels, piece count, sizes]`, -1 elsewhere.
static func _pieces(land: PackedByteArray, cols: int, rows: int, value: int) -> Array:
	var labels := PackedInt32Array()
	labels.resize(land.size())
	labels.fill(-1)
	var sizes: Array = []
	var queue := PackedInt32Array()
	for start in range(land.size()):
		if land[start] != value or labels[start] != -1:
			continue
		var piece := sizes.size()
		labels[start] = piece
		queue.resize(0)
		queue.append(start)
		var head := 0
		while head < queue.size():
			var index := queue[head]
			head += 1
			var x := index % cols
			var y := int(index / cols)
			for offset in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
				var nx: int = x + offset.x
				var ny: int = y + offset.y
				if nx < 0 or ny < 0 or nx >= cols or ny >= rows:
					continue
				var next := ny * cols + nx
				if land[next] == value and labels[next] == -1:
					labels[next] = piece
					queue.append(next)
		sizes.append(queue.size())
	return [labels, sizes.size(), sizes]


## For each cell, how many cells its centre lies from the nearest sea cell's: 0 at sea, about the
## straight distance on land (a 3-4 chamfer over two passes). INF on a map with no sea at all.
static func coast_distances(land: PackedByteArray, cols: int, rows: int) -> PackedFloat32Array:
	var distance := PackedFloat32Array()
	distance.resize(land.size())
	for index in range(land.size()):
		distance[index] = 0.0 if land[index] == SEA else INF
	for y in range(rows):
		for x in range(cols):
			var index := y * cols + x
			var best := distance[index]
			if x > 0:
				best = minf(best, distance[index - 1] + 3.0)
			if y > 0:
				best = minf(best, distance[index - cols] + 3.0)
				if x > 0:
					best = minf(best, distance[index - cols - 1] + 4.0)
				if x < cols - 1:
					best = minf(best, distance[index - cols + 1] + 4.0)
			distance[index] = best
	for y in range(rows - 1, -1, -1):
		for x in range(cols - 1, -1, -1):
			var index := y * cols + x
			var best := distance[index]
			if x < cols - 1:
				best = minf(best, distance[index + 1] + 3.0)
			if y < rows - 1:
				best = minf(best, distance[index + cols] + 3.0)
				if x < cols - 1:
					best = minf(best, distance[index + cols + 1] + 4.0)
				if x > 0:
					best = minf(best, distance[index + cols - 1] + 4.0)
			distance[index] = best
	for index in range(distance.size()):
		distance[index] = distance[index] / 3.0
	return distance
