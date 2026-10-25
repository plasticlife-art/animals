class_name TerrainSystem
extends RefCounted

const DEFAULT_BIOMES := {
	"meadow": {
		"move_cost": 1.0,
		"forage_init_multiplier": 1.0,
		"forage_regrowth_multiplier": 1.0,
		"color": Color(0.31, 0.41, 0.22, 1.0),
	},
	"forest": {
		"move_cost": 1.3,
		"forage_init_multiplier": 0.65,
		"forage_regrowth_multiplier": 0.7,
		"color": Color(0.2, 0.3, 0.18, 1.0),
	},
	"drought": {
		"move_cost": 1.15,
		"forage_init_multiplier": 0.2,
		"forage_regrowth_multiplier": 0.28,
		"color": Color(0.48, 0.39, 0.2, 1.0),
	},
	"swamp": {
		"move_cost": 1.7,
		"forage_init_multiplier": 0.45,
		"forage_regrowth_multiplier": 0.52,
		"color": Color(0.18, 0.27, 0.23, 1.0),
	},
}

const DEFAULT_OBSTACLE_COLORS := {
	"cliff": Color(0.36, 0.37, 0.4, 1.0),
	"dense_forest": Color(0.08, 0.16, 0.11, 1.0),
	"water": Color(0.2, 0.42, 0.62, 1.0),
}
## What water a cell holds (`_water`): none, a river too deep to cross, or a ford.
const WATER_NONE := 0
const WATER_DEEP := 1
const WATER_FORD := 2
const RIVER_SALT := 0x51BE5

var world_size: Vector2 = Vector2.ZERO
var cell_size: float = 32.0
var cols: int = 0
var rows: int = 0
var navigation_config: Dictionary = {}
var biome_definitions: Dictionary = {}
var biome_order: Array = []

var _biomes: Array = []
var _obstacles: Array = []
var _move_costs: PackedFloat32Array = PackedFloat32Array()
var _walkable: PackedByteArray = PackedByteArray()
## Discrete elevation level per cell. Level 0 everywhere means a flat world and
## the height rules below become no-ops, which is the default and what the test
## fixtures build.
var _heights: PackedByteArray = PackedByteArray()
var _forage_init_multipliers: PackedFloat32Array = PackedFloat32Array()
var _forage_regrowth_multipliers: PackedFloat32Array = PackedFloat32Array()
var _blocked_cell_count: int = 0
var height_levels: int = 1
var _max_climb_step: int = 1
var _height_slope_cost: float = 0.35
var _cell_centers: PackedVector2Array = PackedVector2Array()
var _cached_walkable_neighbors: Array = []
var _cached_walkable_neighbor_costs: Array = []
var _path_cache: Dictionary = {}
var _path_cache_order: Array = []
var _path_cache_limit: int = 768
var _path_searches: Dictionary = {}
var _path_query_count: int = 0
var _path_cache_hit_count: int = 0
## The rivers (`terrain.rivers`): `{points, half_width, fords}` each, in world units, the smoothed
## bed from source to mouth, how far either side of it the water runs, and where it may be
## crossed. Empty, with `_water` empty too, in a world without rivers.
var rivers: Array = []
var _water: PackedByteArray = PackedByteArray()
## What crossing a ford costs, over the ground's own cost, in the route search and on the legs.
var _ford_cost: float = 1.0


func initialize(world_config: Dictionary, rng: RandomNumberGenerator, water_sources: Array) -> void:
	var world_size_config: Dictionary = world_config.get("world_size", {})
	world_size = Vector2(
		float(world_size_config.get("x", 1600.0)),
		float(world_size_config.get("y", 900.0))
	)

	var terrain_config: Dictionary = world_config.get("terrain", {})
	var grass_config: Dictionary = world_config.get("grass", {})
	cell_size = float(terrain_config.get("cell_size", grass_config.get("cell_size", 32.0)))
	cols = maxi(1, int(ceil(world_size.x / cell_size)))
	rows = maxi(1, int(ceil(world_size.y / cell_size)))

	navigation_config = world_config.get("navigation", {}).duplicate(true)
	biome_definitions = _build_biome_definitions(terrain_config.get("biomes", {}))
	biome_order = ["meadow", "forest", "drought", "swamp"]

	var height_config: Dictionary = terrain_config.get("height", {})
	height_levels = maxi(1, int(height_config.get("levels", 1)))
	_max_climb_step = maxi(1, int(height_config.get("max_climb_step", 1)))
	_height_slope_cost = maxf(0.0, float(height_config.get("slope_cost", 0.35)))

	var cell_count: int = cols * rows
	_biomes.resize(cell_count)
	_obstacles.resize(cell_count)
	_move_costs.resize(cell_count)
	_walkable.resize(cell_count)
	_heights.resize(cell_count)
	_forage_init_multipliers.resize(cell_count)
	_forage_regrowth_multipliers.resize(cell_count)
	_cell_centers = PackedVector2Array()
	_cached_walkable_neighbors.clear()
	_cached_walkable_neighbor_costs.clear()
	_path_cache.clear()
	_path_cache_order.clear()
	_path_searches.clear()
	_path_cache_limit = maxi(32, int(world_config.get("navigation", {}).get("path_cache_limit", 768)))
	_path_query_count = 0
	_path_cache_hit_count = 0
	rivers.clear()
	_water = PackedByteArray()
	_ford_cost = 1.0

	_generate_biomes(terrain_config.get("generation", {}), rng, water_sources)
	_generate_heights(height_config, rng)
	_apply_obstacles(terrain_config.get("obstacles", {}), rng)
	_generate_rivers(terrain_config.get("rivers", {}), rng, water_sources)
	_connect_walkable_regions()
	_refresh_cached_values()
	_ensure_biome_presence(rng)
	_finish_rivers()
	_refresh_navigation_cache()


func get_cell_count() -> int:
	return cols * rows


func get_cell_coords(index: int) -> Vector2i:
	return Vector2i(index % cols, int(index / cols))


func get_cell_center(index: int) -> Vector2:
	var coords: Vector2i = get_cell_coords(index)
	if index >= 0 and index < _cell_centers.size():
		var cached_center: Vector2 = _cell_centers[index]
		if not cached_center.is_zero_approx():
			return cached_center
	return Vector2((coords.x + 0.5) * cell_size, (coords.y + 0.5) * cell_size)


func get_cell_rect(index: int) -> Rect2:
	var coords: Vector2i = get_cell_coords(index)
	return Rect2(coords.x * cell_size, coords.y * cell_size, cell_size, cell_size)


func get_index_from_position(position: Vector2) -> int:
	var coords: Vector2i = Vector2i(
		int(floor(position.x / cell_size)),
		int(floor(position.y / cell_size))
	)
	if coords.x < 0 or coords.y < 0 or coords.x >= cols or coords.y >= rows:
		return -1
	return coords.y * cols + coords.x


func get_cell_data(index: int) -> Dictionary:
	if index < 0 or index >= get_cell_count():
		return {}
	return {
		"index": index,
		"coords": get_cell_coords(index),
		"biome": str(_biomes[index]),
		"move_cost": float(_move_costs[index]),
		"walkable": bool(_walkable[index]),
		"obstacle": str(_obstacles[index]),
		"forage_init_multiplier": float(_forage_init_multipliers[index]),
		"forage_regrowth_multiplier": float(_forage_regrowth_multipliers[index]),
	}


func get_biome_at_index(index: int) -> String:
	if index < 0 or index >= get_cell_count():
		return "meadow"
	return str(_biomes[index])


func get_biome_at_position(position: Vector2) -> String:
	return get_biome_at_index(get_index_from_position(position))


func get_biome_color(biome_id: String) -> Color:
	var biome: Dictionary = biome_definitions.get(biome_id, DEFAULT_BIOMES["meadow"])
	return biome.get("color", DEFAULT_BIOMES["meadow"]["color"])


func get_biome_color_at_index(index: int) -> Color:
	return get_biome_color(get_biome_at_index(index))


func get_obstacle_at_index(index: int) -> String:
	if index < 0 or index >= get_cell_count():
		return ""
	return str(_obstacles[index])


func get_obstacle_color(obstacle_id: String) -> Color:
	return DEFAULT_OBSTACLE_COLORS.get(obstacle_id, Color(0.2, 0.2, 0.2, 1.0))


func get_move_cost_at_index(index: int) -> float:
	if index < 0 or index >= get_cell_count():
		return 1.0
	if not _water.is_empty() and _water[index] == WATER_FORD:
		return maxf(1.0, float(_move_costs[index])) * _ford_cost
	return maxf(1.0, float(_move_costs[index]))


func get_move_cost_at_position(position: Vector2) -> float:
	return get_move_cost_at_index(get_index_from_position(position))


func get_forage_init_multiplier(index: int) -> float:
	if index < 0 or index >= get_cell_count():
		return 1.0
	return float(_forage_init_multipliers[index])


func get_forage_regrowth_multiplier(index: int) -> float:
	if index < 0 or index >= get_cell_count():
		return 1.0
	return float(_forage_regrowth_multipliers[index])


func is_walkable_index(index: int) -> bool:
	if index < 0 or index >= get_cell_count():
		return false
	return bool(_walkable[index])


func is_walkable_position(position: Vector2) -> bool:
	return is_walkable_index(get_index_from_position(position))


func get_blocked_cell_ratio() -> float:
	var cell_count: int = get_cell_count()
	if cell_count <= 0:
		return 0.0
	return float(_blocked_cell_count) / float(cell_count)


func get_biome_counts() -> Dictionary:
	var counts: Dictionary = {}
	for biome_id in biome_order:
		counts[biome_id] = 0
	for biome_id in _biomes:
		counts[biome_id] = int(counts.get(biome_id, 0)) + 1
	return counts


func get_walkable_neighbors(index: int) -> Array:
	if index < 0 or index >= get_cell_count():
		return []
	if _cached_walkable_neighbors.size() == get_cell_count():
		return _cached_walkable_neighbors[index]
	return _compute_walkable_neighbors(index)


func find_nearest_walkable_index(start_index: int) -> int:
	if is_walkable_index(start_index):
		return start_index
	if start_index < 0:
		return -1
	var origin: Vector2i = get_cell_coords(start_index)
	var radius_limit: int = maxi(cols, rows)
	for radius in range(1, radius_limit + 1):
		for x in range(origin.x - radius, origin.x + radius + 1):
			for y in range(origin.y - radius, origin.y + radius + 1):
				if x < 0 or y < 0 or x >= cols or y >= rows:
					continue
				if x != origin.x - radius and x != origin.x + radius and y != origin.y - radius and y != origin.y + radius:
					continue
				var index: int = y * cols + x
				if is_walkable_index(index):
					return index
	return -1


func find_path(from_position: Vector2, to_position: Vector2) -> Dictionary:
	var start_index: int = find_nearest_walkable_index(get_index_from_position(from_position))
	var goal_index: int = find_nearest_walkable_index(get_index_from_position(to_position))
	return find_path_between_indices(start_index, goal_index)


## Returns a path result as `{cells, cost, reachable, start_index, goal_index}`.
##
## The returned dictionary is READ-ONLY for callers. On a cache hit it is the
## cached object itself, so mutating it in place would corrupt the cache for
## everyone. Callers that need to keep or edit the cells copy them first - see
## `WorldState.get_next_waypoint()` and `_find_reachable_grass_uncounted()`,
## which both `.duplicate()` before storing. This replaced a defensive copy on
## every single return, which cost an Array duplication per query even on the
## ~94% of queries that hit the cache.
func find_path_between_indices(start_index: int, goal_index: int) -> Dictionary:
	# Synchronous callers retain the original contract. Simulation requests use
	# step_path_between_indices() to spread this same deterministic search over
	# several ticks.
	while true:
		var step := step_path_between_indices(start_index, goal_index,
			maxi(64, int(navigation_config.get("max_search_cells", 2800))))
		if bool(step.get("complete", false)):
			return step.get("result", {})
	return {}


## Runs at most `expansion_budget` node expansions of the saved search and reports
## how many it used in `expanded`. Trivial and cached requests expand nothing and
## leave the key out.
func step_path_between_indices(start_index: int, goal_index: int, expansion_budget: int) -> Dictionary:
	if start_index == -1 or goal_index == -1:
		return {"complete": true, "result": {
			"cells": [], "cost": INF, "reachable": false,
			"start_index": start_index, "goal_index": goal_index}}
	if start_index == goal_index:
		return {"complete": true, "result": {
			"cells": [start_index], "cost": 0.0, "reachable": true,
			"start_index": start_index, "goal_index": goal_index}}

	var cache_key := Vector2i(start_index, goal_index)
	if _path_cache.has(cache_key):
		_path_cache_hit_count += 1
		return {"complete": true, "result": _path_cache[cache_key]}

	var max_search_cells: int = maxi(64, int(navigation_config.get("max_search_cells", 2800)))
	var state: Dictionary = _path_searches.get(cache_key, {})
	if state.is_empty():
		_path_query_count += 1
		var first_heuristic := _heuristic_cost(start_index, goal_index)
		var initial_heap: Array[Vector2] = []
		_heap_push(initial_heap, Vector2(start_index, first_heuristic))
		state = {"open_heap": initial_heap, "came_from": {},
			"g_score": {start_index: 0.0}, "f_score": {start_index: first_heuristic},
			"best_index": start_index, "best_heuristic": first_heuristic, "visited": 0}
		_path_searches[cache_key] = state

	var open_heap: Array = state.open_heap
	var came_from: Dictionary = state.came_from
	var g_score: Dictionary = state.g_score
	var f_score: Dictionary = state.f_score
	var best_index: int = int(state.best_index)
	var best_heuristic: float = float(state.best_heuristic)
	var visited: int = int(state.visited)
	var expanded := 0
	var slice_limit := maxi(1, expansion_budget)
	while not open_heap.is_empty() and visited < max_search_cells and expanded < slice_limit:
		var current_node: Vector2 = _heap_pop(open_heap)
		var current_index: int = int(current_node.x)
		var queued_priority: float = current_node.y
		# Rounded as the heap holds it: a `Vector2` keeps 32-bit floats, `f_score` 64-bit ones.
		# Compared unrounded, an entry whose priority had rounded up looked stale and was
		# dropped, and a search short of the nodes it dropped called reachable goals unreachable.
		var current_priority: float = Vector2(0.0, float(f_score.get(current_index, INF))).y
		if current_index == -1 or queued_priority > current_priority:
			continue
		visited += 1
		expanded += 1

		var current_heuristic: float = _heuristic_cost(current_index, goal_index)
		if current_heuristic < best_heuristic:
			best_heuristic = current_heuristic
			best_index = current_index

		if current_index == goal_index:
			var result := {"cells": _reconstruct_path(current_index, came_from),
				"cost": float(g_score.get(current_index, 0.0)), "reachable": true,
				"start_index": start_index, "goal_index": goal_index}
			_path_searches.erase(cache_key)
			_store_path_cache_entry(cache_key, result)
			return {"complete": true, "result": result, "expanded": expanded}

		var neighbor_indices: Array = get_walkable_neighbors(current_index)
		var neighbor_costs: Array = _get_walkable_neighbor_costs(current_index)
		for neighbor_offset in range(neighbor_indices.size()):
			var neighbor_index: int = int(neighbor_indices[neighbor_offset])
			var tentative_cost: float = float(g_score.get(current_index, INF)) + float(neighbor_costs[neighbor_offset])
			if tentative_cost >= float(g_score.get(neighbor_index, INF)):
				continue
			came_from[neighbor_index] = current_index
			g_score[neighbor_index] = tentative_cost
			var total_cost: float = tentative_cost + _heuristic_cost(neighbor_index, goal_index)
			f_score[neighbor_index] = total_cost
			_heap_push(open_heap, Vector2(neighbor_index, total_cost))

	state.best_index = best_index
	state.best_heuristic = best_heuristic
	state.visited = visited
	if not open_heap.is_empty() and visited < max_search_cells:
		return {"complete": false, "result": {}, "expanded": expanded}

	_path_searches.erase(cache_key)
	if best_index == start_index:
		var failed_result := {"cells": [start_index], "cost": INF,
			"reachable": false, "start_index": start_index, "goal_index": goal_index}
		_store_path_cache_entry(cache_key, failed_result)
		return {"complete": true, "result": failed_result, "expanded": expanded}
	var partial_result := {"cells": _reconstruct_path(best_index, came_from),
		"cost": float(g_score.get(best_index, INF)), "reachable": false,
		"start_index": start_index, "goal_index": goal_index}
	_store_path_cache_entry(cache_key, partial_result)
	return {"complete": true, "result": partial_result, "expanded": expanded}


func cancel_path_search(start_index: int, goal_index: int) -> void:
	_path_searches.erase(Vector2i(start_index, goal_index))


func has_cached_path_between_indices(start_index: int, goal_index: int) -> bool:
	return _path_cache.has(Vector2i(start_index, goal_index))


func consume_path_query_stats() -> Dictionary:
	var stats := {
		"queries": _path_query_count,
		"cache_hits": _path_cache_hit_count,
	}
	_path_query_count = 0
	_path_cache_hit_count = 0
	return stats


func _build_biome_definitions(config_biomes: Dictionary) -> Dictionary:
	var definitions: Dictionary = {}
	for biome_id in DEFAULT_BIOMES.keys():
		var merged: Dictionary = DEFAULT_BIOMES[biome_id].duplicate(true)
		var overrides: Dictionary = config_biomes.get(biome_id, {})
		for key in overrides.keys():
			merged[key] = overrides[key]
		if merged.get("color", null) is Array:
			var color_components: Array = merged["color"]
			if color_components.size() >= 3:
				merged["color"] = Color(
					float(color_components[0]),
					float(color_components[1]),
					float(color_components[2]),
					1.0 if color_components.size() < 4 else float(color_components[3])
				)
		definitions[biome_id] = merged
	return definitions


func _generate_biomes(generation_config: Dictionary, rng: RandomNumberGenerator, water_sources: Array) -> void:
	var biome_noise: FastNoiseLite = FastNoiseLite.new()
	biome_noise.seed = int(rng.randi())
	biome_noise.frequency = float(generation_config.get("biome_frequency", 0.018))
	biome_noise.fractal_octaves = int(generation_config.get("biome_octaves", 3))

	var moisture_noise: FastNoiseLite = FastNoiseLite.new()
	moisture_noise.seed = int(rng.randi())
	moisture_noise.frequency = float(generation_config.get("moisture_frequency", 0.012))
	moisture_noise.fractal_octaves = int(generation_config.get("moisture_octaves", 3))

	var drought_noise: FastNoiseLite = FastNoiseLite.new()
	drought_noise.seed = int(rng.randi())
	drought_noise.frequency = float(generation_config.get("drought_frequency", 0.016))
	drought_noise.fractal_octaves = int(generation_config.get("drought_octaves", 2))

	var swamp_water_radius: float = maxf(cell_size * 3.0, float(generation_config.get("swamp_water_radius", 240.0)))
	var forest_threshold: float = float(generation_config.get("forest_threshold", 0.2))
	var drought_threshold: float = float(generation_config.get("drought_threshold", 0.42))
	var swamp_threshold: float = float(generation_config.get("swamp_threshold", 0.48))

	for index in range(get_cell_count()):
		var center: Vector2 = get_cell_center(index)
		var biome_value: float = biome_noise.get_noise_2d(center.x, center.y)
		var moisture_value: float = moisture_noise.get_noise_2d(center.x, center.y)
		var drought_value: float = drought_noise.get_noise_2d(center.x, center.y)
		var water_influence: float = _get_water_influence(center, water_sources, swamp_water_radius)

		var biome_id: String = "meadow"
		if moisture_value + water_influence >= swamp_threshold:
			biome_id = "swamp"
		elif drought_value - water_influence * 0.45 >= drought_threshold:
			biome_id = "drought"
		elif biome_value + moisture_value * 0.35 >= forest_threshold:
			biome_id = "forest"
		_set_biome(index, biome_id)
		_obstacles[index] = ""
		_walkable[index] = 1


## Elevation is a separate noise layer from the biomes, so relief and vegetation
## do not have to agree. With `levels` at 1 every cell stays at 0 and every
## height rule downstream collapses to a no-op.
func _generate_heights(height_config: Dictionary, rng: RandomNumberGenerator) -> void:
	var cell_count := get_cell_count()
	if height_levels <= 1:
		for index in range(cell_count):
			_heights[index] = 0
		return

	var height_noise: FastNoiseLite = FastNoiseLite.new()
	height_noise.seed = int(rng.randi())
	height_noise.frequency = float(height_config.get("frequency", 0.012))
	height_noise.fractal_octaves = int(height_config.get("octaves", 3))

	var top_level: int = height_levels - 1
	for index in range(cell_count):
		var center: Vector2 = get_cell_center(index)
		var value: float = (height_noise.get_noise_2d(center.x, center.y) + 1.0) * 0.5
		_heights[index] = clampi(int(floor(value * float(height_levels))), 0, top_level)


func get_height_at_index(index: int) -> int:
	if index < 0 or index >= _heights.size():
		return 0
	return int(_heights[index])


func get_height_at_position(position: Vector2) -> int:
	return get_height_at_index(get_index_from_position(position))


func get_max_height_level() -> int:
	return maxi(0, height_levels - 1)


## A transition is climbable when the step between the two cells is small
## enough. Elevation is a property of the move, not of the cell, so
## `is_walkable_index()` keeps meaning "not blocked by an obstacle" and every
## caller that asks that question is unaffected.
func _is_climbable(from_index: int, to_index: int) -> bool:
	if height_levels <= 1:
		return true
	return absi(int(_heights[from_index]) - int(_heights[to_index])) <= _max_climb_step


func _apply_obstacles(obstacle_config: Dictionary, rng: RandomNumberGenerator) -> void:
	var forest_cluster_count: int = maxi(0, int(obstacle_config.get("dense_forest_cluster_count", 6)))
	var forest_radius_min: float = maxf(1.5, float(obstacle_config.get("dense_forest_radius_min_cells", 2.0)))
	var forest_radius_max: float = maxf(forest_radius_min, float(obstacle_config.get("dense_forest_radius_max_cells", 4.5)))
	for _index in range(forest_cluster_count):
		var center_index: int = _find_random_biome_cell("forest", rng)
		if center_index == -1:
			center_index = rng.randi_range(0, get_cell_count() - 1)
		_paint_obstacle_circle(center_index, rng.randf_range(forest_radius_min, forest_radius_max), "dense_forest")

	var cliff_count: int = maxi(0, int(obstacle_config.get("cliff_count", 5)))
	var cliff_thickness_min: float = maxf(0.9, float(obstacle_config.get("cliff_thickness_min_cells", 1.1)))
	var cliff_thickness_max: float = maxf(cliff_thickness_min, float(obstacle_config.get("cliff_thickness_max_cells", 2.2)))
	var cliff_gap_radius: float = maxf(1.0, float(obstacle_config.get("cliff_gap_radius_cells", 1.6)))
	for _index in range(cliff_count):
		var start: Vector2 = Vector2(rng.randf_range(0.0, world_size.x), rng.randf_range(0.0, world_size.y))
		var end: Vector2 = Vector2(rng.randf_range(0.0, world_size.x), rng.randf_range(0.0, world_size.y))
		var thickness: float = rng.randf_range(cliff_thickness_min, cliff_thickness_max) * cell_size
		var gap_count: int = rng.randi_range(1, 2)
		var gap_points: Array = []
		for _gap_index in range(gap_count):
			var t: float = rng.randf_range(0.12, 0.88)
			gap_points.append(start.lerp(end, t))
		_paint_segment_obstacle(start, end, thickness, cliff_gap_radius * cell_size, gap_points, "cliff")

	var border_padding_cells: int = maxi(0, int(obstacle_config.get("border_clearance_cells", 1)))
	if border_padding_cells > 0:
		for x in range(cols):
			for y in range(rows):
				if x <= border_padding_cells or y <= border_padding_cells or x >= cols - border_padding_cells - 1 or y >= rows - border_padding_cells - 1:
					_clear_obstacle(y * cols + x)


func _connect_walkable_regions() -> void:
	var components: Array = _collect_walkable_components()
	if components.is_empty():
		for index in range(get_cell_count()):
			_clear_obstacle(index)
		return

	components.sort_custom(func(a, b): return a["cells"].size() > b["cells"].size())
	var main_component: Array = components[0]["cells"]
	var main_anchor_index: int = int(main_component[int(main_component.size() / 2)])
	for component_index in range(1, components.size()):
		var component: Array = components[component_index]["cells"]
		var start_index: int = int(component[0])
		_carve_corridor(start_index, main_anchor_index)
		main_component.append_array(component)

	components = _collect_walkable_components()
	if components.size() <= 1:
		return
	components.sort_custom(func(a, b): return a["cells"].size() > b["cells"].size())
	for component_index in range(1, components.size()):
		for index in components[component_index]["cells"]:
			_clear_obstacle(int(index))

	# Terminal fallback. Clearing obstacles cannot rescue a region that is walled
	# off by elevation rather than by an obstacle, so if the map is still split
	# the height field is abandoned entirely. A connected world matters more than
	# relief, and this firing at all means the height settings are too extreme
	# for the map - hence the warning rather than a silent flatten.
	if _collect_walkable_components().size() > 1:
		push_warning("Terrain still disconnected after carving; flattening height field. Check terrain.height settings.")
		for index in range(get_cell_count()):
			_heights[index] = 0


func _collect_walkable_components() -> Array:
	var components: Array = []
	var visited: Dictionary = {}
	for index in range(get_cell_count()):
		if visited.has(index) or not is_walkable_index(index):
			continue
		var queue: Array = [index]
		var read_index: int = 0
		var component: Array = []
		visited[index] = true
		while read_index < queue.size():
			var current: int = int(queue[read_index])
			read_index += 1
			component.append(current)
			for neighbor in get_walkable_neighbors(current):
				if visited.has(neighbor):
					continue
				visited[neighbor] = true
				queue.append(neighbor)
		components.append({"cells": component})
	return components


## Cuts an L-shaped passage between two disconnected regions. Clearing the
## obstacles is only half the job once terrain has elevation: a corridor that
## runs into a cliff face is still a wall, so the height field is graded along
## it as well.
func _carve_corridor(start_index: int, end_index: int) -> void:
	var cells: Array = _corridor_cells(start_index, end_index)
	for index in cells:
		_clear_obstacle(int(index))
		# Through a river, the passage is a ford.
		if not _water.is_empty() and _water[int(index)] == WATER_DEEP:
			_water[int(index)] = WATER_FORD
	_grade_corridor(cells)


func _corridor_cells(start_index: int, end_index: int) -> Array:
	var from_coords: Vector2i = get_cell_coords(start_index)
	var to_coords: Vector2i = get_cell_coords(end_index)
	var cursor: Vector2i = from_coords
	var cells: Array = [start_index]
	while cursor.x != to_coords.x:
		cursor.x += 1 if to_coords.x > cursor.x else -1
		cells.append(cursor.y * cols + cursor.x)
	while cursor.y != to_coords.y:
		cursor.y += 1 if to_coords.y > cursor.y else -1
		cells.append(cursor.y * cols + cursor.x)
	return cells


## Grades the interior of a corridor into a ramp between the two ends, whose own
## heights belong to the regions being joined and are left alone. A long enough
## corridor absorbs any difference; a corridor too short to ramp legally is
## flattened to the destination level instead, which is still connected.
func _grade_corridor(cells: Array) -> void:
	if height_levels <= 1 or cells.size() < 2:
		return
	var first: int = int(cells[0])
	var last: int = int(cells[cells.size() - 1])
	var from_height: int = int(_heights[first])
	var to_height: int = int(_heights[last])
	var span: int = cells.size() - 1
	if absi(to_height - from_height) > span * _max_climb_step:
		for cell_index in cells:
			_heights[int(cell_index)] = to_height
		return
	for step in range(1, span):
		var t: float = float(step) / float(span)
		_heights[int(cells[step])] = int(round(lerpf(float(from_height), float(to_height), t)))


func _paint_obstacle_circle(center_index: int, radius_cells: float, obstacle_id: String) -> void:
	var center_coords: Vector2i = get_cell_coords(center_index)
	var radius_sq: float = radius_cells * radius_cells
	var min_x: int = maxi(0, int(floor(center_coords.x - radius_cells)))
	var max_x: int = mini(cols - 1, int(ceil(center_coords.x + radius_cells)))
	var min_y: int = maxi(0, int(floor(center_coords.y - radius_cells)))
	var max_y: int = mini(rows - 1, int(ceil(center_coords.y + radius_cells)))
	for x in range(min_x, max_x + 1):
		for y in range(min_y, max_y + 1):
			var delta: Vector2 = Vector2(float(x - center_coords.x), float(y - center_coords.y))
			if delta.length_squared() > radius_sq:
				continue
			_set_obstacle(y * cols + x, obstacle_id)


func _paint_segment_obstacle(start: Vector2, end: Vector2, thickness: float, gap_radius: float, gap_points: Array, obstacle_id: String) -> void:
	for index in range(get_cell_count()):
		var center: Vector2 = get_cell_center(index)
		var closest: Vector2 = _closest_point_on_segment(center, start, end)
		if center.distance_to(closest) > thickness:
			continue
		var blocked: bool = true
		for gap_point in gap_points:
			if center.distance_to(gap_point) <= gap_radius:
				blocked = false
				break
		if blocked:
			_set_obstacle(index, obstacle_id)


func _find_random_biome_cell(biome_id: String, rng: RandomNumberGenerator) -> int:
	var candidates: Array = []
	for index in range(get_cell_count()):
		if str(_biomes[index]) == biome_id:
			candidates.append(index)
	if candidates.is_empty():
		return -1
	return int(candidates[rng.randi_range(0, candidates.size() - 1)])


func _ensure_biome_presence(rng: RandomNumberGenerator) -> void:
	var counts: Dictionary = get_biome_counts()
	for biome_id in biome_order:
		if int(counts.get(biome_id, 0)) > 0:
			continue
		var center_index: int = rng.randi_range(0, get_cell_count() - 1)
		_paint_biome_patch(center_index, biome_id, 2.5)
	_refresh_cached_values()


func _paint_biome_patch(center_index: int, biome_id: String, radius_cells: float) -> void:
	var center_coords: Vector2i = get_cell_coords(center_index)
	var radius_sq: float = radius_cells * radius_cells
	for x in range(maxi(0, int(floor(center_coords.x - radius_cells))), mini(cols - 1, int(ceil(center_coords.x + radius_cells))) + 1):
		for y in range(maxi(0, int(floor(center_coords.y - radius_cells))), mini(rows - 1, int(ceil(center_coords.y + radius_cells))) + 1):
			var delta: Vector2 = Vector2(float(x - center_coords.x), float(y - center_coords.y))
			if delta.length_squared() > radius_sq:
				continue
			_set_biome(y * cols + x, biome_id)


func _set_biome(index: int, biome_id: String) -> void:
	_biomes[index] = biome_id
	var definition: Dictionary = biome_definitions.get(biome_id, DEFAULT_BIOMES["meadow"])
	_move_costs[index] = float(definition.get("move_cost", 1.0))
	_forage_init_multipliers[index] = float(definition.get("forage_init_multiplier", 1.0))
	_forage_regrowth_multipliers[index] = float(definition.get("forage_regrowth_multiplier", 1.0))


func _set_obstacle(index: int, obstacle_id: String) -> void:
	_obstacles[index] = obstacle_id
	_walkable[index] = 0


func _clear_obstacle(index: int) -> void:
	_obstacles[index] = ""
	_walkable[index] = 1


func _refresh_cached_values() -> void:
	_blocked_cell_count = 0
	for index in range(get_cell_count()):
		if not bool(_walkable[index]):
			_blocked_cell_count += 1


func _refresh_navigation_cache() -> void:
	var cell_count := get_cell_count()
	_cell_centers.resize(cell_count)
	_cached_walkable_neighbors.resize(cell_count)
	_cached_walkable_neighbor_costs.resize(cell_count)
	for index in range(cell_count):
		var coords: Vector2i = get_cell_coords(index)
		_cell_centers[index] = Vector2((coords.x + 0.5) * cell_size, (coords.y + 0.5) * cell_size)
	for index in range(cell_count):
		if not is_walkable_index(index):
			_cached_walkable_neighbors[index] = []
			_cached_walkable_neighbor_costs[index] = []
			continue
		var neighbors: Array = _compute_walkable_neighbors(index)
		var costs: Array = []
		costs.resize(neighbors.size())
		for neighbor_offset in range(neighbors.size()):
			var neighbor_index: int = int(neighbors[neighbor_offset])
			costs[neighbor_offset] = _step_cost(index, neighbor_index)
		_cached_walkable_neighbors[index] = neighbors
		_cached_walkable_neighbor_costs[index] = costs


func _compute_walkable_neighbors(index: int) -> Array:
	if not is_walkable_index(index):
		return []
	var coords: Vector2i = get_cell_coords(index)
	var allow_diagonal: bool = bool(navigation_config.get("allow_diagonal", true))
	var neighbors: Array = []
	var orthogonal_offsets := [
		Vector2i(1, 0),
		Vector2i(-1, 0),
		Vector2i(0, 1),
		Vector2i(0, -1),
	]
	for offset in orthogonal_offsets:
		var neighbor_index := _offset_to_walkable_index(coords, offset)
		if neighbor_index != -1 and _is_climbable(index, neighbor_index):
			neighbors.append(neighbor_index)
	if not allow_diagonal:
		return neighbors
	var diagonal_offsets := [
		Vector2i(1, 1),
		Vector2i(1, -1),
		Vector2i(-1, 1),
		Vector2i(-1, -1),
	]
	for offset in diagonal_offsets:
		var neighbor: Vector2i = coords + offset
		if neighbor.x < 0 or neighbor.y < 0 or neighbor.x >= cols or neighbor.y >= rows:
			continue
		var neighbor_index: int = neighbor.y * cols + neighbor.x
		if not is_walkable_index(neighbor_index):
			continue
		if not _is_climbable(index, neighbor_index):
			continue
		# A diagonal needs one of its two orthogonal supports to be usable,
		# climb included - otherwise an agent could cut the corner of a cliff.
		var horizontal_index: int = coords.y * cols + (coords.x + offset.x)
		var vertical_index: int = (coords.y + offset.y) * cols + coords.x
		var horizontal_ok := is_walkable_index(horizontal_index) and _is_climbable(index, horizontal_index)
		var vertical_ok := is_walkable_index(vertical_index) and _is_climbable(index, vertical_index)
		if not horizontal_ok and not vertical_ok:
			continue
		neighbors.append(neighbor_index)
	return neighbors


func _offset_to_walkable_index(coords: Vector2i, offset: Vector2i) -> int:
	var neighbor: Vector2i = coords + offset
	if neighbor.x < 0 or neighbor.y < 0 or neighbor.x >= cols or neighbor.y >= rows:
		return -1
	var neighbor_index: int = neighbor.y * cols + neighbor.x
	if not is_walkable_index(neighbor_index):
		return -1
	return neighbor_index


func _get_walkable_neighbor_costs(index: int) -> Array:
	if index < 0 or index >= get_cell_count():
		return []
	if _cached_walkable_neighbor_costs.size() == get_cell_count():
		return _cached_walkable_neighbor_costs[index]
	var neighbors := _compute_walkable_neighbors(index)
	var costs: Array = []
	costs.resize(neighbors.size())
	for neighbor_offset in range(neighbors.size()):
		costs[neighbor_offset] = _step_cost(index, int(neighbors[neighbor_offset]))
	return costs


func _get_water_influence(position: Vector2, water_sources: Array, radius: float) -> float:
	if water_sources.is_empty() or radius <= 0.0:
		return 0.0
	var best: float = 0.0
	for source in water_sources:
		var source_position: Vector2 = source.get("position", Vector2.ZERO)
		var source_radius: float = float(source.get("radius", 0.0))
		var influence_radius: float = radius + source_radius
		var distance: float = position.distance_to(source_position)
		if distance > influence_radius:
			continue
		best = maxf(best, 1.0 - (distance / maxf(influence_radius, 1.0)))
	return best


func _heap_push(heap: Array[Vector2], value: Vector2) -> void:
	heap.append(value)
	var index := heap.size() - 1
	while index > 0:
		var parent := int((index - 1) / 2)
		if heap[parent].y <= value.y:
			break
		heap[index] = heap[parent]
		index = parent
	heap[index] = value


func _heap_pop(heap: Array[Vector2]) -> Vector2:
	if heap.is_empty():
		return Vector2(-1.0, INF)
	var result: Vector2 = heap[0]
	var tail: Vector2 = heap.pop_back()
	if heap.is_empty():
		return result
	var index := 0
	var heap_size := heap.size()
	while true:
		var left := index * 2 + 1
		if left >= heap_size:
			break
		var right := left + 1
		var best_child := left
		if right < heap_size and heap[right].y < heap[left].y:
			best_child = right
		if heap[best_child].y >= tail.y:
			break
		heap[index] = heap[best_child]
		index = best_child
	heap[index] = tail
	return result


func _heuristic_cost(from_index: int, to_index: int) -> float:
	# Avoid constructing and looking up two world-space vectors for every A*
	# neighbor. Cell coordinates are sufficient because all cells share one size.
	var from_x := from_index % cols
	var from_y := int(from_index / cols)
	var to_x := to_index % cols
	var to_y := int(to_index / cols)
	var delta_x := float(from_x - to_x)
	var delta_y := float(from_y - to_y)
	return sqrt(delta_x * delta_x + delta_y * delta_y) * cell_size


func _step_cost(from_index: int, to_index: int) -> float:
	var base: float = get_cell_center(from_index).distance_to(get_cell_center(to_index)) * get_move_cost_at_index(to_index)
	if height_levels <= 1 or _height_slope_cost <= 0.0:
		return base
	# Only climbing is penalised. Going downhill is free, which keeps agents
	# from treating a descent as a detour worth avoiding.
	var climb: int = int(_heights[to_index]) - int(_heights[from_index])
	if climb <= 0:
		return base
	return base * (1.0 + float(climb) * _height_slope_cost)


func _reconstruct_path(current_index: int, came_from: Dictionary) -> Array:
	var path: Array = [current_index]
	var cursor: int = current_index
	while came_from.has(cursor):
		cursor = int(came_from[cursor])
		path.push_front(cursor)
	return path


func _closest_point_on_segment(point: Vector2, segment_start: Vector2, segment_end: Vector2) -> Vector2:
	var segment: Vector2 = segment_end - segment_start
	var segment_length_sq: float = segment.length_squared()
	if segment_length_sq <= 0.0001:
		return segment_start
	var t: float = clampf((point - segment_start).dot(segment) / segment_length_sq, 0.0, 1.0)
	return segment_start + segment * t


func _store_path_cache_entry(cache_key: Vector2i, result: Dictionary) -> void:
	if _path_cache.has(cache_key):
		return
	# Stored by reference, and `find_path_between_indices()` hands the same
	# object back, so there is one rule for callers rather than two: never
	# mutate a path result in place.
	_path_cache[cache_key] = result
	_path_cache_order.append(cache_key)
	if _path_cache_order.size() > _path_cache_limit:
		var oldest_key: Vector2i = _path_cache_order.pop_front()
		_path_cache.erase(oldest_key)


## Whether the cell holds river water, deep or a ford.
func is_water_index(index: int) -> bool:
	return not _water.is_empty() and index >= 0 and index < _water.size() and _water[index] != WATER_NONE


func is_ford_index(index: int) -> bool:
	return not _water.is_empty() and index >= 0 and index < _water.size() and _water[index] == WATER_FORD


func get_water_at_index(index: int) -> int:
	return WATER_NONE if not is_water_index(index) else int(_water[index])


## Rivers (`terrain.rivers`): `count` of them, each from a source inland, away from the ponds, to
## the map's edge at least `min_length_fraction` of the map away. The bed follows the cheapest way
## (`AStarGrid2D`, eight-way) over a noise that makes it wind (`wiggle`), round the ponds by
## `pond_margin_cells`, along low ground where the map has relief, and clear of the rivers before
## it; smoothed (Chaikin), it is deep water within `half_width_cells` - an obstacle like a cliff -
## but for a ford every `ford_every_cells` along it, `ford_width_cells` wide, walkable at
## `ford_cost` times the ground's cost. A generator of its own, seeded from the world's seed: the
## world's stream is not drawn from, so a world without rivers is the world it was.
func _generate_rivers(config: Dictionary, rng: RandomNumberGenerator, water_sources: Array) -> void:
	if not bool(config.get("enabled", false)) or int(config.get("count", 0)) <= 0:
		return
	var random := RandomNumberGenerator.new()
	random.seed = (int(rng.seed) ^ RIVER_SALT) + int(config.get("seed", 0))
	_water.resize(get_cell_count())
	_water.fill(WATER_NONE)
	_ford_cost = maxf(1.0, float(config.get("ford_cost", 2.5)))
	var noise := FastNoiseLite.new()
	noise.seed = random.randi()
	noise.frequency = float(config.get("wiggle_frequency", 0.08))
	var grid := AStarGrid2D.new()
	grid.region = Rect2i(0, 0, cols, rows)
	grid.cell_size = Vector2.ONE
	grid.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_ALWAYS
	grid.default_compute_heuristic = AStarGrid2D.HEURISTIC_OCTILE
	grid.default_estimate_heuristic = AStarGrid2D.HEURISTIC_OCTILE
	grid.update()
	var wiggle := float(config.get("wiggle", 3.0))
	var climb_weight := float(config.get("climb_weight", 1.5))
	var pond_margin := float(config.get("pond_margin_cells", 3.0)) * cell_size
	for index in range(get_cell_count()):
		var coords := get_cell_coords(index)
		var weight := 1.0 + wiggle * (noise.get_noise_2d(float(coords.x), float(coords.y)) + 1.0) * 0.5
		if height_levels > 1:
			weight += float(_heights[index]) * climb_weight
		if _near_pond(get_cell_center(index), water_sources, pond_margin):
			weight += 60.0
		grid.set_point_weight_scale(coords, weight)
	var half_width := maxf(0.75, float(config.get("half_width_cells", 0.9))) * cell_size
	var min_length := float(config.get("min_length_fraction", 0.45)) * maxf(world_size.x, world_size.y)
	var ford_half := maxf(0.5, float(config.get("ford_width_cells", 2.5))) * cell_size * 0.5
	for _river in range(int(config.get("count", 2))):
		var route := _river_route(grid, random, water_sources, min_length, pond_margin)
		if route.size() < 2:
			continue
		var points := _chaikin(route, 3)
		var fords := _place_fords(points, float(config.get("ford_every_cells", 16.0)) * cell_size, half_width)
		rivers.append({"points": points, "half_width": half_width, "fords": fords})
		_paint_river(points, half_width, fords, ford_half)
		# The next river keeps out of this one's bed rather than running into it.
		for index in range(get_cell_count()):
			if _water[index] != WATER_NONE:
				grid.set_point_weight_scale(get_cell_coords(index), 200.0)


static func _near_pond(point: Vector2, water_sources: Array, margin: float) -> bool:
	for source in water_sources:
		if point.distance_to(source["position"]) <= float(source.get("radius", 0.0)) + margin:
			return true
	return false


## One river's way, cell centres from a source to a point just past the edge; empty when no try
## gave one long enough.
func _river_route(grid: AStarGrid2D, random: RandomNumberGenerator, water_sources: Array, min_length: float,
		pond_margin: float) -> PackedVector2Array:
	var margin := mini(12, int(mini(cols, rows) / 4.0))
	for _attempt in range(24):
		var source := Vector2i(random.randi_range(margin, cols - 1 - margin), random.randi_range(margin, rows - 1 - margin))
		var side := random.randi_range(0, 3)
		var along := random.randf()
		var start_index := source.y * cols + source.x
		var start_center := get_cell_center(start_index)
		if is_water_index(start_index) or _near_pond(start_center, water_sources, pond_margin * 2.0):
			continue
		var target := Vector2i(int(along * float(cols - 1)), 0 if side == 0 else rows - 1) if side < 2 \
			else Vector2i(0 if side == 2 else cols - 1, int(along * float(rows - 1)))
		var mouth_index := target.y * cols + target.x
		if get_cell_center(mouth_index).distance_to(start_center) < min_length:
			continue
		var ids: Array[Vector2i] = grid.get_id_path(source, target)
		if ids.size() < 2:
			continue
		var route := PackedVector2Array()
		for id in ids:
			route.append(get_cell_center(id.y * cols + id.x))
		var outward := [Vector2(0.0, -1.0), Vector2(0.0, 1.0), Vector2(-1.0, 0.0), Vector2(1.0, 0.0)][side] as Vector2
		route.append(route[route.size() - 1] + outward * cell_size)
		return route
	return PackedVector2Array()


## Corner cutting, `rounds` times: each segment's quarter and three-quarter points, the ends kept.
static func _chaikin(points: PackedVector2Array, rounds: int) -> PackedVector2Array:
	var current := points
	for _round in range(rounds):
		var next := PackedVector2Array([current[0]])
		for index in range(current.size() - 1):
			next.append(current[index].lerp(current[index + 1], 0.25))
			next.append(current[index].lerp(current[index + 1], 0.75))
		next.append(current[current.size() - 1])
		current = next
	return current


## Points along the bed every `every` units, the first half a step from the source, at least one
## in the middle of a short river; none within three cells of the edge. Where the map has relief,
## each moves up to six cells along to banks a step apart at most, so the ford can be climbed.
func _place_fords(points: PackedVector2Array, every: float, half_width: float) -> Array:
	var length := 0.0
	for index in range(points.size() - 1):
		length += points[index].distance_to(points[index + 1])
	var marks: Array = []
	var at := minf(every * 0.5, length * 0.5)
	while at < length:
		marks.append(at)
		at += every
	var fords: Array = []
	var inner := Rect2(Vector2.ZERO, world_size).grow(-3.0 * cell_size)
	for mark in marks:
		var best := Vector2.INF
		for shift in [0, 1, -1, 2, -2, 3, -3, 4, -4, 5, -5, 6, -6]:
			var spot := _point_along(points, float(mark) + float(shift) * cell_size)
			if not inner.has_point(spot[0]):
				continue
			if best == Vector2.INF:
				best = spot[0]
			if _banks_climbable(spot[0], spot[1], half_width):
				best = spot[0]
				break
		if best != Vector2.INF:
			fords.append(best)
	return fords


## The point `distance` along the polyline and its direction: `[point, unit tangent]`.
static func _point_along(points: PackedVector2Array, distance: float) -> Array:
	var left := maxf(0.0, distance)
	for index in range(points.size() - 1):
		var step := points[index].distance_to(points[index + 1])
		if left <= step or index == points.size() - 2:
			var tangent := (points[index + 1] - points[index]).normalized()
			return [points[index].lerp(points[index + 1], clampf(left / maxf(step, 0.001), 0.0, 1.0)), tangent]
		left -= step
	return [points[points.size() - 1], Vector2.RIGHT]


func _banks_climbable(point: Vector2, tangent: Vector2, half_width: float) -> bool:
	if height_levels <= 1:
		return true
	var normal := Vector2(-tangent.y, tangent.x)
	var a := get_index_from_position(point + normal * (half_width + cell_size))
	var b := get_index_from_position(point - normal * (half_width + cell_size))
	if a < 0 or b < 0:
		return false
	return absi(int(_heights[a]) - int(_heights[b])) <= _max_climb_step


## Marks the bed's cells: deep water within `half_width` of the polyline, an obstacle; a ford within
## `ford_half` (plus half the width) of a ford point, walkable, at the lower bank's level.
func _paint_river(points: PackedVector2Array, half_width: float, fords: Array, ford_half: float) -> void:
	var nearest := polyline_distances(points, half_width)
	for index in nearest.keys():
		if float(nearest[index]) > half_width:
			continue
		var center := get_cell_center(int(index))
		var ford := false
		for spot in fords:
			if center.distance_to(spot) <= ford_half + half_width * 0.5:
				ford = true
				break
		if ford:
			_water[int(index)] = WATER_FORD
			_clear_obstacle(int(index))
		elif _water[int(index)] != WATER_FORD:
			_water[int(index)] = WATER_DEEP
			_set_obstacle(int(index), "water")
	if height_levels > 1:
		for index in range(get_cell_count()):
			if _water[index] == WATER_FORD:
				_heights[index] = _lowest_dry_neighbour_height(index)


## Each cell whose centre lies within `reach` of the polyline, and how far: `{index: distance}`.
## Segment by segment over the cells about each, so a long river costs what its banks cover.
func polyline_distances(points: PackedVector2Array, reach: float) -> Dictionary:
	var nearest := {}
	for segment in range(points.size() - 1):
		var a := points[segment]
		var b := points[segment + 1]
		var box := Rect2(a, Vector2.ZERO).expand(b).grow(reach)
		var low := Vector2i((box.position / cell_size).floor())
		var high := Vector2i((box.end / cell_size).floor())
		for y in range(maxi(0, low.y), mini(rows - 1, high.y) + 1):
			for x in range(maxi(0, low.x), mini(cols - 1, high.x) + 1):
				var index := y * cols + x
				var center := get_cell_center(index)
				var distance := center.distance_to(Geometry2D.get_closest_point_to_segment(center, a, b))
				if distance <= reach and distance < float(nearest.get(index, INF)):
					nearest[index] = distance
	return nearest


func _lowest_dry_neighbour_height(index: int) -> int:
	var coords := get_cell_coords(index)
	var lowest := int(_heights[index])
	for offset in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
		var next: Vector2i = coords + offset
		if next.x < 0 or next.y < 0 or next.x >= cols or next.y >= rows:
			continue
		var neighbour := next.y * cols + next.x
		if _water[neighbour] == WATER_NONE:
			lowest = mini(lowest, int(_heights[neighbour]))
	return lowest


## Once the rest is laid: no grass in a river, deep or ford.
func _finish_rivers() -> void:
	if _water.is_empty():
		return
	for index in range(get_cell_count()):
		if _water[index] != WATER_NONE:
			_forage_init_multipliers[index] = 0.0
			_forage_regrowth_multipliers[index] = 0.0
