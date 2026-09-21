class_name ResourceSystem
extends RefCounted

var terrain_system: TerrainSystem
## Optional `FearField`. The cell searches skip cells whose risk exceeds the caller's
## `max_risk`; with no field, or `max_risk` left at INF, risk plays no part.
var risk_field = null
var world_size: Vector2 = Vector2.ZERO
var cell_size: float = 32.0
var cols: int = 0
var rows: int = 0
var max_biomass: float = 100.0
## Logistic growth rate per second: a sparse sward grows by this share of itself.
var growth_rate: float = 0.0
## Share of a cell's cap that cannot be grazed - roots and stubble. Growth starts from
## it, so a stripped cell recovers instead of staying bare for ever.
var stubble_fraction: float = 0.0
## Each cell grows once every this many ticks, with the elapsed time made up in the
## step, so a slow-growing map does not cost a full grid sweep every tick.
var growth_stride_ticks: int = 18
var total_biomass: float = 0.0
var _cells: PackedFloat32Array = PackedFloat32Array()
var _biomass_totals_by_biome: Dictionary = {}
# 1 for cells below their local maximum. A cell at its cap cannot grow, so the
# sweep skips it.
var _below_cap: PackedByteArray = PackedByteArray()
var _below_cap_count: int = 0
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
	# Biomass is stored per cell but means grass over an area, so the cap has to
	# scale with the square of the cell. `max_biomass` is the value tuned at
	# `biomass_reference_cell_size`. `growth_rate` is a share per second and needs
	# no scaling.
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
	growth_rate = maxf(0.0, float(grass_config.get("growth_rate", 0.0)))
	stubble_fraction = clampf(float(grass_config.get("stubble_fraction", 0.0)), 0.0, 0.9)
	growth_stride_ticks = maxi(1, int(grass_config.get("growth_stride_ticks", 18)))

	cols = maxi(1, int(ceil(world_size.x / cell_size)))
	rows = maxi(1, int(ceil(world_size.y / cell_size)))
	_cells.resize(cols * rows)
	_dirty_cells.clear()

	var density_min := float(grass_config.get("initial_density_min", 0.45))
	var density_max := float(grass_config.get("initial_density_max", 0.95))
	for index in range(_cells.size()):
		var forage_multiplier := 1.0 if terrain_system == null else terrain_system.get_forage_init_multiplier(index)
		var biomass := rng.randf_range(density_min, density_max) * max_biomass * forage_multiplier
		# Nothing grows where nothing can walk. Grass on a cliff or in a pond could never
		# be eaten, so it stayed the richest cell around for ever and drew sleeping herds
		# to stand beside it and starve. The draw above still happens, so the rest of
		# the world comes out of `rng` unchanged.
		if terrain_system != null and not terrain_system.is_walkable_index(index):
			_cells[index] = 0.0
			continue
		_cells[index] = maxf(biomass, _get_cell_max_biomass(index) * stubble_fraction)
	_rebuild_derived()


## Grass biomass is the one accumulated field here; everything else - the total,
## the per-biome totals and the regrowing set - is derived from it on import.
func export_cells() -> PackedFloat32Array:
	return _cells.duplicate()


## What each cell can hold, and nothing where nothing can graze. The ground layer
## reads grass against this to tell a grazed-down pasture from poor soil.
func export_caps() -> PackedFloat32Array:
	var caps := PackedFloat32Array()
	caps.resize(_cells.size())
	for index in range(_cells.size()):
		if terrain_system == null or terrain_system.is_walkable_index(index):
			caps[index] = _get_cell_max_biomass(index)
	return caps


func import_cells(cells, new_terrain_system: TerrainSystem = null) -> void:
	if new_terrain_system != null:
		terrain_system = new_terrain_system
	if not (cells is PackedFloat32Array) or cells.size() != _cells.size():
		push_error("Saved grass grid is %d cells, world has %d; keeping generated grass"
			% [cells.size() if cells is PackedFloat32Array else -1, _cells.size()])
		return
	_cells = cells.duplicate()
	# A save from before grass could run out holds several times today's cap, and
	# grass on cells nothing can reach. Both are brought within the current rules.
	for index in range(_cells.size()):
		if terrain_system != null and not terrain_system.is_walkable_index(index):
			_cells[index] = 0.0
		else:
			_cells[index] = minf(_cells[index], _get_cell_max_biomass(index))
	_dirty_cells.clear()
	_rebuild_derived()


## The total, the per-biome totals and the below-cap flags, read off the cells.
func _rebuild_derived() -> void:
	total_biomass = 0.0
	_biomass_totals_by_biome.clear()
	_below_cap.resize(_cells.size())
	_below_cap_count = 0
	for index in range(_cells.size()):
		var biomass: float = _cells[index]
		total_biomass += biomass
		_add_biomass_to_biome(index, biomass)
		var below := biomass < _get_cell_max_biomass(index)
		_below_cap[index] = 1 if below else 0
		if below:
			_below_cap_count += 1


## Logistic growth: `growth_rate x biomass x (1 - biomass / cap)`, scaled by the biome
## and the season. A grazed-down sward grows slowly, a half-grown one fastest, a full
## one not at all, which is what lets grazing pressure decide how much a range yields.
## Grass used to refill at a flat rate that outran every herd on the map hundreds of
## times over, so food never limited anything.
##
## One slice of the grid per tick: the cells whose index falls on this tick's phase,
## each stepped by the time since its last turn. The phase comes from `tick`, not from
## a counter, so a loaded save resumes the same schedule.
func step(delta: float, season_regrowth_multiplier: float = 1.0, tick: int = 0) -> void:
	if growth_rate <= 0.0 or season_regrowth_multiplier <= 0.0 or _below_cap_count <= 0:
		return
	var stride := growth_stride_ticks
	var seasonal_rate := growth_rate * season_regrowth_multiplier * delta * float(stride)
	for index in range(posmod(tick, stride), _cells.size(), stride):
		if _below_cap[index] == 0:
			continue
		var biome_multiplier := 1.0 if terrain_system == null else terrain_system.get_forage_regrowth_multiplier(index)
		if biome_multiplier <= 0.0:
			continue
		var previous := _cells[index]
		var cell_max := _get_cell_max_biomass(index)
		var updated := minf(cell_max, previous + seasonal_rate * biome_multiplier * previous * (1.0 - previous / cell_max))
		if updated >= cell_max:
			_below_cap[index] = 0
			_below_cap_count -= 1
		var delta_biomass := updated - previous
		if delta_biomass <= 0.0:
			continue
		_cells[index] = updated
		if track_dirty_cells:
			_dirty_cells[index] = updated
		total_biomass += delta_biomass
		_add_biomass_to_biome(index, delta_biomass)


func get_regrowing_cell_count() -> int:
	return _below_cap_count


func get_total_biomass() -> float:
	return total_biomass


func get_cell_count() -> int:
	return _cells.size()


func get_biomass(index: int) -> float:
	if index < 0 or index >= _cells.size():
		return 0.0
	return _cells[index]


## What a grazer can take from a cell: everything above the stubble.
func get_available_biomass(index: int) -> float:
	if index < 0 or index >= _cells.size():
		return 0.0
	return maxf(0.0, _cells[index] - _get_cell_max_biomass(index) * stubble_fraction)


## Standing biomass as a share of what the map could hold.
func get_mean_density() -> float:
	var capacity := 0.0
	for index in range(_cells.size()):
		if terrain_system == null or terrain_system.is_walkable_index(index):
			capacity += _get_cell_max_biomass(index)
	return total_biomass / maxf(1.0, capacity)


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
			var available := get_available_biomass(index)
			result.append({
				"index": index,
				"coords": Vector2i(x, y),
				"center": center,
				"biomass": available,
				"density": available / _get_cell_max_biomass(index),
			})
	return result


func take_cells_scanned() -> int:
	var scanned := _cells_scanned
	_cells_scanned = 0
	return scanned


func find_best_cell(position: Vector2, radius: float, min_biomass: float = 0.0, max_risk: float = INF) -> Dictionary:
	var check_risk := max_risk < INF and risk_field != null
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

			var biomass := get_available_biomass(index)
			if biomass < min_biomass:
				continue
			if check_risk and risk_field.risk_at(center) > max_risk:
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
func find_best_cell_in_set(position: Vector2, radius: float, min_biomass: float, allowed_indices: Dictionary, max_risk: float = INF) -> Dictionary:
	var check_risk := max_risk < INF and risk_field != null
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
			var biomass := get_available_biomass(index)
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
			if check_risk and risk_field.risk_at(center) > max_risk:
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


func get_index_at_position(position: Vector2) -> int:
	return _position_to_index(position)


func consume_at_position(position: Vector2, amount: float) -> float:
	var index := _position_to_index(position)
	return consume_cell(index, amount)


func consume_cell(index: int, amount: float) -> float:
	if index == -1:
		return 0.0
	var consumed := minf(get_available_biomass(index), amount)
	if consumed <= 0.0:
		return 0.0
	_cells[index] -= consumed
	if track_dirty_cells:
		_dirty_cells[index] = _cells[index]
	total_biomass -= consumed
	_add_biomass_to_biome(index, -consumed)
	if _below_cap[index] == 0:
		_below_cap[index] = 1
		_below_cap_count += 1
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
