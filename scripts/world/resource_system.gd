class_name ResourceSystem
extends RefCounted

var terrain_system: TerrainSystem
var world_size: Vector2 = Vector2.ZERO
var cell_size: float = 32.0
var cols: int = 0
var rows: int = 0
var max_biomass: float = 100.0
var regrowth_rate: float = 5.0
var total_biomass: float = 0.0
var _cells: PackedFloat32Array = PackedFloat32Array()
var _biomass_totals_by_biome: Dictionary = {}
# Indices of cells below their local maximum. A cell at max cannot regrow, so
# stepping the whole grid every tick costs the same whether or not anything was
# eaten; only depleted cells need work.
var _regrowing_cells: Dictionary = {}
# Counts cells visited by find_best_cell since the last drain, so the cost of grass
# searching is attributable instead of hiding inside the agent tick.
var _cells_scanned: int = 0
var _dirty_cells: Dictionary = {}
var track_dirty_cells: bool = false


func initialize(world_config: Dictionary, rng: RandomNumberGenerator, new_terrain_system: TerrainSystem = null) -> void:
	var grass_config: Dictionary = world_config.get("grass", {})
	var world_size_config: Dictionary = world_config.get("world_size", {})
	terrain_system = new_terrain_system

	world_size = Vector2(
		float(world_size_config.get("x", 1600.0)),
		float(world_size_config.get("y", 900.0))
	)
	cell_size = float(grass_config.get("cell_size", 32.0))
	# Biomass is stored per cell but means grass over an area, so both the cap
	# and the regrowth have to scale with the square of the cell. `max_biomass`
	# and `regrowth_rate` are the values tuned at `biomass_reference_cell_size`.
	#
	# Missing the key defaults the reference to the cell itself - factor 1, no
	# change - which is what keeps the test fixtures' own worlds untouched.
	#
	# This is not cosmetic. Carrying 100/6.0 from a 32-unit cell to a 96-unit one
	# left a cell holding three bites of `bite_amount` 33 while a herd has twenty
	# members, so a herd stripped a cell and moved on before most of it had eaten.
	var reference_cell_size := float(grass_config.get("biomass_reference_cell_size", cell_size))
	var area_scale: float = 1.0
	if reference_cell_size > 0.0:
		area_scale = pow(cell_size / reference_cell_size, 2.0)
	max_biomass = float(grass_config.get("max_biomass", 100.0)) * area_scale
	regrowth_rate = float(grass_config.get("regrowth_rate", 5.0)) * area_scale

	cols = maxi(1, int(ceil(world_size.x / cell_size)))
	rows = maxi(1, int(ceil(world_size.y / cell_size)))
	_cells.resize(cols * rows)
	total_biomass = 0.0
	_biomass_totals_by_biome.clear()
	_regrowing_cells.clear()
	_dirty_cells.clear()

	var density_min := float(grass_config.get("initial_density_min", 0.45))
	var density_max := float(grass_config.get("initial_density_max", 0.95))
	for index in range(_cells.size()):
		var forage_multiplier := 1.0 if terrain_system == null else terrain_system.get_forage_init_multiplier(index)
		var biomass := rng.randf_range(density_min, density_max) * max_biomass * forage_multiplier
		_cells[index] = biomass
		total_biomass += biomass
		_add_biomass_to_biome(index, biomass)
		if biomass < _get_cell_max_biomass(index):
			_regrowing_cells[index] = true


## Grass biomass is the one accumulated field here; everything else - the total,
## the per-biome totals and the regrowing set - is derived from it on import.
func export_cells() -> PackedFloat32Array:
	return _cells.duplicate()


func import_cells(cells, new_terrain_system: TerrainSystem = null) -> void:
	if new_terrain_system != null:
		terrain_system = new_terrain_system
	if not (cells is PackedFloat32Array) or cells.size() != _cells.size():
		push_error("Saved grass grid is %d cells, world has %d; keeping generated grass"
			% [cells.size() if cells is PackedFloat32Array else -1, _cells.size()])
		return
	_cells = cells.duplicate()
	total_biomass = 0.0
	_biomass_totals_by_biome.clear()
	_regrowing_cells.clear()
	_dirty_cells.clear()
	for index in range(_cells.size()):
		var biomass: float = _cells[index]
		total_biomass += biomass
		_add_biomass_to_biome(index, biomass)
		if biomass < _get_cell_max_biomass(index):
			_regrowing_cells[index] = true


## `season_regrowth_multiplier` is applied here rather than folded into
## `regrowth_rate`, which is resolved once at init with the area scale and must
## stay the tuned value - multiplying into it would compound every tick.
func step(delta: float, season_regrowth_multiplier: float = 1.0) -> void:
	if _regrowing_cells.is_empty():
		return
	var filled_cells: Array = []
	for index in _regrowing_cells.keys():
		var previous := _cells[index]
		var cell_max := _get_cell_max_biomass(index)
		var regrowth_multiplier := 1.0 if terrain_system == null else terrain_system.get_forage_regrowth_multiplier(index)
		var base_growth := regrowth_rate * regrowth_multiplier * delta
		var updated := minf(cell_max, previous + base_growth * season_regrowth_multiplier)
		var delta_biomass := updated - previous
		if updated >= cell_max:
			filled_cells.append(index)
		elif is_zero_approx(base_growth):
			# Only a cell whose terrain cannot regrow at all earns permanent
			# eviction; consumption puts it back when it next matters. Testing the
			# season-scaled growth instead would let a hard winter quietly empty
			# the working set, and those cells would never resume.
			filled_cells.append(index)
			continue
		if delta_biomass <= 0.0:
			continue
		_cells[index] = updated
		if track_dirty_cells:
			_dirty_cells[index] = updated
		total_biomass += delta_biomass
		_add_biomass_to_biome(index, delta_biomass)
	for index in filled_cells:
		_regrowing_cells.erase(index)


func get_regrowing_cell_count() -> int:
	return _regrowing_cells.size()


func get_total_biomass() -> float:
	return total_biomass


func get_cell_count() -> int:
	return _cells.size()


func get_biomass(index: int) -> float:
	if index < 0 or index >= _cells.size():
		return 0.0
	return _cells[index]


func get_cell_center(index: int) -> Vector2:
	var coords := get_cell_coords(index)
	return Vector2((coords.x + 0.5) * cell_size, (coords.y + 0.5) * cell_size)


func get_cell_rect(index: int) -> Rect2:
	var coords := get_cell_coords(index)
	return Rect2(coords.x * cell_size, coords.y * cell_size, cell_size, cell_size)


func get_cell_coords(index: int) -> Vector2i:
	return Vector2i(index % cols, int(index / cols))


func get_density_at_position(position: Vector2) -> float:
	var index := _position_to_index(position)
	if index == -1:
		return 0.0
	return _cells[index] / _get_cell_max_biomass(index)


func query_cells(position: Vector2, radius: float) -> Array:
	var result: Array = []
	var expanded_radius := radius + cell_size
	var radius_sq := expanded_radius * expanded_radius
	var min_cell := Vector2i(
		maxi(0, int(floor((position.x - radius) / cell_size))),
		maxi(0, int(floor((position.y - radius) / cell_size)))
	)
	var max_cell := Vector2i(
		mini(cols - 1, int(floor((position.x + radius) / cell_size))),
		mini(rows - 1, int(floor((position.y + radius) / cell_size)))
	)

	for x in range(min_cell.x, max_cell.x + 1):
		for y in range(min_cell.y, max_cell.y + 1):
			var index := y * cols + x
			var center := Vector2((x + 0.5) * cell_size, (y + 0.5) * cell_size)
			if center.distance_squared_to(position) > radius_sq:
				continue
			result.append({
				"index": index,
				"coords": Vector2i(x, y),
				"center": center,
				"biomass": _cells[index],
				"density": _cells[index] / _get_cell_max_biomass(index),
			})
	return result


func take_cells_scanned() -> int:
	var scanned := _cells_scanned
	_cells_scanned = 0
	return scanned


func find_best_cell(position: Vector2, radius: float, min_biomass: float = 0.0) -> Dictionary:
	var best := {}
	var best_distance := INF
	var best_biomass := -INF
	var expanded_radius := radius + cell_size
	var radius_sq := expanded_radius * expanded_radius
	var min_cell := Vector2i(
		maxi(0, int(floor((position.x - radius) / cell_size))),
		maxi(0, int(floor((position.y - radius) / cell_size)))
	)
	var max_cell := Vector2i(
		mini(cols - 1, int(floor((position.x + radius) / cell_size))),
		mini(rows - 1, int(floor((position.y + radius) / cell_size)))
	)

	_cells_scanned += (max_cell.x - min_cell.x + 1) * (max_cell.y - min_cell.y + 1)
	for x in range(min_cell.x, max_cell.x + 1):
		for y in range(min_cell.y, max_cell.y + 1):
			var index := y * cols + x
			var center := Vector2((x + 0.5) * cell_size, (y + 0.5) * cell_size)
			var distance_sq := position.distance_squared_to(center)
			if distance_sq > radius_sq:
				continue

			var biomass := _cells[index]
			if biomass < min_biomass:
				continue

			if distance_sq < best_distance or (is_equal_approx(distance_sq, best_distance) and biomass > best_biomass):
				best = {
					"index": index,
					"coords": Vector2i(x, y),
					"center": center,
					"biomass": biomass,
					"density": biomass / _get_cell_max_biomass(index),
				}
				best_distance = distance_sq
				best_biomass = biomass

	return best


## `find_best_cell` restricted to a caller-supplied set of cell indices, allocating a
## dictionary only for the winner rather than one per scanned cell the way `query_cells`
## does. The local grazing lookup runs for every hungry herbivore on every decision tick,
## so that allocation dominated the search.
##
## Nearest-first, like `find_best_cell`: one bite is a small fraction of a full cell, so a
## richer cell further away buys the agent nothing it cannot get underfoot, and walking to
## it is time spent not eating.
func find_best_cell_in_set(position: Vector2, radius: float, min_biomass: float, allowed_indices: Dictionary) -> Dictionary:
	var best_index := -1
	var best_distance_sq := INF
	var best_biomass := -INF
	var best_center := Vector2.ZERO
	var expanded_radius := radius + cell_size
	var radius_sq := expanded_radius * expanded_radius
	var min_cell := Vector2i(
		maxi(0, int(floor((position.x - radius) / cell_size))),
		maxi(0, int(floor((position.y - radius) / cell_size)))
	)
	var max_cell := Vector2i(
		mini(cols - 1, int(floor((position.x + radius) / cell_size))),
		mini(rows - 1, int(floor((position.y + radius) / cell_size)))
	)

	_cells_scanned += (max_cell.x - min_cell.x + 1) * (max_cell.y - min_cell.y + 1)
	for x in range(min_cell.x, max_cell.x + 1):
		for y in range(min_cell.y, max_cell.y + 1):
			var index := y * cols + x
			if not allowed_indices.has(index):
				continue
			var biomass := _cells[index]
			if biomass < min_biomass:
				continue
			var center := Vector2((x + 0.5) * cell_size, (y + 0.5) * cell_size)
			var distance_sq := position.distance_squared_to(center)
			if distance_sq > radius_sq:
				continue
			if distance_sq > best_distance_sq:
				continue
			if is_equal_approx(distance_sq, best_distance_sq) and biomass <= best_biomass:
				continue
			best_index = index
			best_distance_sq = distance_sq
			best_biomass = biomass
			best_center = center

	if best_index == -1:
		return {}
	return {
		"index": best_index,
		"coords": Vector2i(best_index % cols, int(best_index / cols)),
		"center": best_center,
		"biomass": best_biomass,
		"density": best_biomass / _get_cell_max_biomass(best_index),
		"score": best_biomass,
	}


func consume_at_position(position: Vector2, amount: float) -> float:
	var index := _position_to_index(position)
	return consume_cell(index, amount)


func consume_cell(index: int, amount: float) -> float:
	if index == -1:
		return 0.0
	var consumed := minf(_cells[index], amount)
	if consumed <= 0.0:
		return 0.0
	_cells[index] -= consumed
	if track_dirty_cells:
		_dirty_cells[index] = _cells[index]
	total_biomass -= consumed
	_add_biomass_to_biome(index, -consumed)
	_regrowing_cells[index] = true
	return consumed


func take_dirty_cells() -> Dictionary:
	var indices := PackedInt32Array()
	var values := PackedFloat32Array()
	indices.resize(_dirty_cells.size())
	values.resize(_dirty_cells.size())
	var offset := 0
	for index in _dirty_cells.keys():
		indices[offset] = int(index)
		values[offset] = float(_dirty_cells[index])
		offset += 1
	_dirty_cells.clear()
	return {"indices": indices, "values": values}


func clear_dirty_cells() -> void:
	_dirty_cells.clear()


func get_biomass_totals_by_biome() -> Dictionary:
	return _biomass_totals_by_biome.duplicate(true)


func _position_to_index(position: Vector2) -> int:
	var cell := Vector2i(
		int(floor(position.x / cell_size)),
		int(floor(position.y / cell_size))
	)
	if cell.x < 0 or cell.y < 0 or cell.x >= cols or cell.y >= rows:
		return -1
	return cell.y * cols + cell.x


func _get_cell_max_biomass(index: int) -> float:
	var local_multiplier := 1.0 if terrain_system == null else terrain_system.get_forage_init_multiplier(index)
	return maxf(1.0, max_biomass * maxf(0.1, local_multiplier))


func _add_biomass_to_biome(index: int, delta_biomass: float) -> void:
	if is_zero_approx(delta_biomass):
		return
	var biome_id := "meadow" if terrain_system == null else terrain_system.get_biome_at_index(index)
	_biomass_totals_by_biome[biome_id] = float(_biomass_totals_by_biome.get(biome_id, 0.0)) + delta_biomass
