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


func initialize(world_config: Dictionary, rng: RandomNumberGenerator, new_terrain_system: TerrainSystem = null) -> void:
	var grass_config: Dictionary = world_config.get("grass", {})
	var world_size_config: Dictionary = world_config.get("world_size", {})
	terrain_system = new_terrain_system

	world_size = Vector2(
		float(world_size_config.get("x", 1600.0)),
		float(world_size_config.get("y", 900.0))
	)
	cell_size = float(grass_config.get("cell_size", 32.0))
	max_biomass = float(grass_config.get("max_biomass", 100.0))
	regrowth_rate = float(grass_config.get("regrowth_rate", 5.0))

	cols = maxi(1, int(ceil(world_size.x / cell_size)))
	rows = maxi(1, int(ceil(world_size.y / cell_size)))
	_cells.resize(cols * rows)
	total_biomass = 0.0
	_biomass_totals_by_biome.clear()

	var density_min := float(grass_config.get("initial_density_min", 0.45))
	var density_max := float(grass_config.get("initial_density_max", 0.95))
	for index in range(_cells.size()):
		var forage_multiplier := 1.0 if terrain_system == null else terrain_system.get_forage_init_multiplier(index)
		var biomass := rng.randf_range(density_min, density_max) * max_biomass * forage_multiplier
		_cells[index] = biomass
		total_biomass += biomass
		_add_biomass_to_biome(index, biomass)


func step(delta: float) -> void:
	for index in range(_cells.size()):
		var previous := _cells[index]
		var regrowth_multiplier := 1.0 if terrain_system == null else terrain_system.get_forage_regrowth_multiplier(index)
		var updated := minf(_get_cell_max_biomass(index), previous + regrowth_rate * regrowth_multiplier * delta)
		_cells[index] = updated
		var delta_biomass := updated - previous
		if is_zero_approx(delta_biomass):
			continue
		total_biomass += delta_biomass
		_add_biomass_to_biome(index, delta_biomass)


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


func consume_at_position(position: Vector2, amount: float) -> float:
	var index := _position_to_index(position)
	return consume_cell(index, amount)


func consume_cell(index: int, amount: float) -> float:
	if index == -1:
		return 0.0
	var consumed := minf(_cells[index], amount)
	_cells[index] -= consumed
	total_biomass -= consumed
	_add_biomass_to_biome(index, -consumed)
	return consumed


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
