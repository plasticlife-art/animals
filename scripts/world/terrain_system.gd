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
}

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
var _forage_init_multipliers: PackedFloat32Array = PackedFloat32Array()
var _forage_regrowth_multipliers: PackedFloat32Array = PackedFloat32Array()
var _blocked_cell_count: int = 0


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

	var cell_count := cols * rows
	_biomes.resize(cell_count)
	_obstacles.resize(cell_count)
	_move_costs.resize(cell_count)
	_walkable.resize(cell_count)
	_forage_init_multipliers.resize(cell_count)
	_forage_regrowth_multipliers.resize(cell_count)

	_generate_biomes(terrain_config.get("generation", {}), rng, water_sources)
	_apply_obstacles(terrain_config.get("obstacles", {}), rng)
	_connect_walkable_regions()
	_refresh_cached_values()
	_ensure_biome_presence(rng)


func get_cell_count() -> int:
	return cols * rows


func get_cell_coords(index: int) -> Vector2i:
	return Vector2i(index % cols, int(index / cols))


func get_cell_center(index: int) -> Vector2:
	var coords := get_cell_coords(index)
	return Vector2((coords.x + 0.5) * cell_size, (coords.y + 0.5) * cell_size)


func get_cell_rect(index: int) -> Rect2:
	var coords := get_cell_coords(index)
	return Rect2(coords.x * cell_size, coords.y * cell_size, cell_size, cell_size)


func get_index_from_position(position: Vector2) -> int:
	var coords := Vector2i(
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
	var cell_count := get_cell_count()
	if cell_count <= 0:
		return 0.0
	return float(_blocked_cell_count) / float(cell_count)


func get_biome_counts() -> Dictionary:
	var counts := {}
	for biome_id in biome_order:
		counts[biome_id] = 0
	for biome_id in _biomes:
		counts[biome_id] = int(counts.get(biome_id, 0)) + 1
	return counts


func get_walkable_neighbors(index: int) -> Array:
	if not is_walkable_index(index):
		return []
	var coords := get_cell_coords(index)
	var allow_diagonal := bool(navigation_config.get("allow_diagonal", true))
	var offsets := [
		Vector2i(1, 0),
		Vector2i(-1, 0),
		Vector2i(0, 1),
		Vector2i(0, -1),
	]
	if allow_diagonal:
		offsets.append_array([
			Vector2i(1, 1),
			Vector2i(1, -1),
			Vector2i(-1, 1),
			Vector2i(-1, -1),
		])

	var neighbors: Array = []
	for offset in offsets:
		var neighbor := coords + offset
		if neighbor.x < 0 or neighbor.y < 0 or neighbor.x >= cols or neighbor.y >= rows:
			continue
		var neighbor_index := neighbor.y * cols + neighbor.x
		if not is_walkable_index(neighbor_index):
			continue
		if allow_diagonal and abs(offset.x) == 1 and abs(offset.y) == 1:
			var horizontal := Vector2i(coords.x + offset.x, coords.y)
			var vertical := Vector2i(coords.x, coords.y + offset.y)
			if not is_walkable_index(horizontal.y * cols + horizontal.x) and not is_walkable_index(vertical.y * cols + vertical.x):
				continue
		neighbors.append(neighbor_index)
	return neighbors


func find_nearest_walkable_index(start_index: int) -> int:
	if is_walkable_index(start_index):
		return start_index
	if start_index < 0:
		return -1
	var origin := get_cell_coords(start_index)
	var radius_limit := maxi(cols, rows)
	for radius in range(1, radius_limit + 1):
		for x in range(origin.x - radius, origin.x + radius + 1):
			for y in range(origin.y - radius, origin.y + radius + 1):
				if x < 0 or y < 0 or x >= cols or y >= rows:
					continue
				if x != origin.x - radius and x != origin.x + radius and y != origin.y - radius and y != origin.y + radius:
					continue
				var index := y * cols + x
				if is_walkable_index(index):
					return index
	return -1


func find_path(from_position: Vector2, to_position: Vector2) -> Dictionary:
	var start_index := find_nearest_walkable_index(get_index_from_position(from_position))
	var goal_index := find_nearest_walkable_index(get_index_from_position(to_position))
	return find_path_between_indices(start_index, goal_index)


func find_path_between_indices(start_index: int, goal_index: int) -> Dictionary:
	if start_index == -1 or goal_index == -1:
		return {
			"cells": [],
			"cost": INF,
			"reachable": false,
			"start_index": start_index,
			"goal_index": goal_index,
		}
	if start_index == goal_index:
		return {
			"cells": [start_index],
			"cost": 0.0,
			"reachable": true,
			"start_index": start_index,
			"goal_index": goal_index,
		}

	var max_search_cells := maxi(64, int(navigation_config.get("max_search_cells", 2800)))
	var open: Array = [start_index]
	var open_lookup := {}
	open_lookup[start_index] = true
	var came_from := {}
	var g_score := {}
	g_score[start_index] = 0.0
	var f_score := {}
	f_score[start_index] = _heuristic_cost(start_index, goal_index)
	var best_index := start_index
	var best_heuristic := _heuristic_cost(start_index, goal_index)
	var visited := 0

	while not open.is_empty() and visited < max_search_cells:
		var current_index := _extract_lowest_cost_index(open, f_score)
		open_lookup.erase(current_index)
		visited += 1

		var current_heuristic := _heuristic_cost(current_index, goal_index)
		if current_heuristic < best_heuristic:
			best_heuristic = current_heuristic
			best_index = current_index

		if current_index == goal_index:
			return {
				"cells": _reconstruct_path(current_index, came_from),
				"cost": float(g_score.get(current_index, 0.0)),
				"reachable": true,
				"start_index": start_index,
				"goal_index": goal_index,
			}

		for neighbor_index in get_walkable_neighbors(current_index):
			var tentative_cost := float(g_score.get(current_index, INF)) + _step_cost(current_index, neighbor_index)
			if tentative_cost >= float(g_score.get(neighbor_index, INF)):
				continue
			came_from[neighbor_index] = current_index
			g_score[neighbor_index] = tentative_cost
			f_score[neighbor_index] = tentative_cost + _heuristic_cost(neighbor_index, goal_index)
			if not open_lookup.has(neighbor_index):
				open.append(neighbor_index)
				open_lookup[neighbor_index] = true
	}

	if best_index == start_index:
		return {
			"cells": [start_index],
			"cost": INF,
			"reachable": false,
			"start_index": start_index,
			"goal_index": goal_index,
		}
	return {
		"cells": _reconstruct_path(best_index, came_from),
		"cost": float(g_score.get(best_index, INF)),
		"reachable": false,
		"start_index": start_index,
		"goal_index": goal_index,
	}


func _build_biome_definitions(config_biomes: Dictionary) -> Dictionary:
	var definitions := {}
	for biome_id in DEFAULT_BIOMES.keys():
		var merged := DEFAULT_BIOMES[biome_id].duplicate(true)
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
	var biome_noise := FastNoiseLite.new()
	biome_noise.seed = int(rng.randi())
	biome_noise.frequency = float(generation_config.get("biome_frequency", 0.018))
	biome_noise.fractal_octaves = int(generation_config.get("biome_octaves", 3))

	var moisture_noise := FastNoiseLite.new()
	moisture_noise.seed = int(rng.randi())
	moisture_noise.frequency = float(generation_config.get("moisture_frequency", 0.012))
	moisture_noise.fractal_octaves = int(generation_config.get("moisture_octaves", 3))

	var drought_noise := FastNoiseLite.new()
	drought_noise.seed = int(rng.randi())
	drought_noise.frequency = float(generation_config.get("drought_frequency", 0.016))
	drought_noise.fractal_octaves = int(generation_config.get("drought_octaves", 2))

	var swamp_water_radius := maxf(cell_size * 3.0, float(generation_config.get("swamp_water_radius", 240.0)))
	var forest_threshold := float(generation_config.get("forest_threshold", 0.2))
	var drought_threshold := float(generation_config.get("drought_threshold", 0.42))
	var swamp_threshold := float(generation_config.get("swamp_threshold", 0.48))

	for index in range(get_cell_count()):
		var center := get_cell_center(index)
		var biome_value := biome_noise.get_noise_2d(center.x, center.y)
		var moisture_value := moisture_noise.get_noise_2d(center.x, center.y)
		var drought_value := drought_noise.get_noise_2d(center.x, center.y)
		var water_influence := _get_water_influence(center, water_sources, swamp_water_radius)

		var biome_id := "meadow"
		if moisture_value + water_influence >= swamp_threshold:
			biome_id = "swamp"
		elif drought_value - water_influence * 0.45 >= drought_threshold:
			biome_id = "drought"
		elif biome_value + moisture_value * 0.35 >= forest_threshold:
			biome_id = "forest"
		_set_biome(index, biome_id)
		_obstacles[index] = ""
		_walkable[index] = 1


func _apply_obstacles(obstacle_config: Dictionary, rng: RandomNumberGenerator) -> void:
	var forest_cluster_count := maxi(0, int(obstacle_config.get("dense_forest_cluster_count", 6)))
	var forest_radius_min := maxf(1.5, float(obstacle_config.get("dense_forest_radius_min_cells", 2.0)))
	var forest_radius_max := maxf(forest_radius_min, float(obstacle_config.get("dense_forest_radius_max_cells", 4.5)))
	for _index in range(forest_cluster_count):
		var center_index := _find_random_biome_cell("forest", rng)
		if center_index == -1:
			center_index = rng.randi_range(0, get_cell_count() - 1)
		_paint_obstacle_circle(center_index, rng.randf_range(forest_radius_min, forest_radius_max), "dense_forest")

	var cliff_count := maxi(0, int(obstacle_config.get("cliff_count", 5)))
	var cliff_thickness_min := maxf(0.9, float(obstacle_config.get("cliff_thickness_min_cells", 1.1)))
	var cliff_thickness_max := maxf(cliff_thickness_min, float(obstacle_config.get("cliff_thickness_max_cells", 2.2)))
	var cliff_gap_radius := maxf(1.0, float(obstacle_config.get("cliff_gap_radius_cells", 1.6)))
	for _index in range(cliff_count):
		var start := Vector2(rng.randf_range(0.0, world_size.x), rng.randf_range(0.0, world_size.y))
		var end := Vector2(rng.randf_range(0.0, world_size.x), rng.randf_range(0.0, world_size.y))
		var thickness := rng.randf_range(cliff_thickness_min, cliff_thickness_max) * cell_size
		var gap_count := rng.randi_range(1, 2)
		var gap_points: Array = []
		for _gap_index in range(gap_count):
			var t := rng.randf_range(0.12, 0.88)
			gap_points.append(start.lerp(end, t))
		_paint_segment_obstacle(start, end, thickness, cliff_gap_radius * cell_size, gap_points, "cliff")
	}

	var border_padding_cells := maxi(0, int(obstacle_config.get("border_clearance_cells", 1)))
	if border_padding_cells > 0:
		for x in range(cols):
			for y in range(rows):
				if x <= border_padding_cells or y <= border_padding_cells or x >= cols - border_padding_cells - 1 or y >= rows - border_padding_cells - 1:
					_clear_obstacle(y * cols + x)


func _connect_walkable_regions() -> void:
	var components := _collect_walkable_components()
	if components.is_empty():
		for index in range(get_cell_count()):
			_clear_obstacle(index)
		return

	components.sort_custom(func(a, b): return a["cells"].size() > b["cells"].size())
	var main_component: Array = components[0]["cells"]
	for component_index in range(1, components.size()):
		var component: Array = components[component_index]["cells"]
		var start_index := int(component[0])
		var end_index := _find_closest_cell_between_sets(component, main_component)
		if end_index == -1:
			continue
		_carve_corridor(start_index, end_index)
		main_component.append_array(component)

	components = _collect_walkable_components()
	if components.size() <= 1:
		return
	components.sort_custom(func(a, b): return a["cells"].size() > b["cells"].size())
	for component_index in range(1, components.size()):
		for index in components[component_index]["cells"]:
			_clear_obstacle(int(index))


func _collect_walkable_components() -> Array:
	var components: Array = []
	var visited := {}
	for index in range(get_cell_count()):
		if visited.has(index) or not is_walkable_index(index):
			continue
		var queue: Array = [index]
		var component: Array = []
		visited[index] = true
		while not queue.is_empty():
			var current := int(queue.pop_front())
			component.append(current)
			for neighbor in get_walkable_neighbors(current):
				if visited.has(neighbor):
					continue
				visited[neighbor] = true
				queue.append(neighbor)
		components.append({"cells": component})
	return components


func _find_closest_cell_between_sets(from_cells: Array, to_cells: Array) -> int:
	var best_target := -1
	var best_distance := INF
	for source in from_cells:
		var source_center := get_cell_center(int(source))
		for target in to_cells:
			var distance_sq := source_center.distance_squared_to(get_cell_center(int(target)))
			if distance_sq < best_distance:
				best_distance = distance_sq
				best_target = int(target)
	return best_target


func _carve_corridor(start_index: int, end_index: int) -> void:
	var from_coords := get_cell_coords(start_index)
	var to_coords := get_cell_coords(end_index)
	var cursor := from_coords
	_clear_obstacle(start_index)
	_clear_obstacle(end_index)

	while cursor.x != to_coords.x:
		cursor.x += 1 if to_coords.x > cursor.x else -1
		_clear_obstacle(cursor.y * cols + cursor.x)
	while cursor.y != to_coords.y:
		cursor.y += 1 if to_coords.y > cursor.y else -1
		_clear_obstacle(cursor.y * cols + cursor.x)


func _paint_obstacle_circle(center_index: int, radius_cells: float, obstacle_id: String) -> void:
	var center_coords := get_cell_coords(center_index)
	var radius_sq := radius_cells * radius_cells
	var min_x := maxi(0, int(floor(center_coords.x - radius_cells)))
	var max_x := mini(cols - 1, int(ceil(center_coords.x + radius_cells)))
	var min_y := maxi(0, int(floor(center_coords.y - radius_cells)))
	var max_y := mini(rows - 1, int(ceil(center_coords.y + radius_cells)))
	for x in range(min_x, max_x + 1):
		for y in range(min_y, max_y + 1):
			var delta := Vector2(float(x - center_coords.x), float(y - center_coords.y))
			if delta.length_squared() > radius_sq:
				continue
			_set_obstacle(y * cols + x, obstacle_id)


func _paint_segment_obstacle(start: Vector2, end: Vector2, thickness: float, gap_radius: float, gap_points: Array, obstacle_id: String) -> void:
	for index in range(get_cell_count()):
		var center := get_cell_center(index)
		var closest := _closest_point_on_segment(center, start, end)
		if center.distance_to(closest) > thickness:
			continue
		var blocked := true
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
	var counts := get_biome_counts()
	for biome_id in biome_order:
		if int(counts.get(biome_id, 0)) > 0:
			continue
		var center_index := rng.randi_range(0, get_cell_count() - 1)
		_paint_biome_patch(center_index, biome_id, 2.5)
	_refresh_cached_values()


func _paint_biome_patch(center_index: int, biome_id: String, radius_cells: float) -> void:
	var center_coords := get_cell_coords(center_index)
	var radius_sq := radius_cells * radius_cells
	for x in range(maxi(0, int(floor(center_coords.x - radius_cells))), mini(cols - 1, int(ceil(center_coords.x + radius_cells))) + 1):
		for y in range(maxi(0, int(floor(center_coords.y - radius_cells))), mini(rows - 1, int(ceil(center_coords.y + radius_cells))) + 1):
			var delta := Vector2(float(x - center_coords.x), float(y - center_coords.y))
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


func _get_water_influence(position: Vector2, water_sources: Array, radius: float) -> float:
	if water_sources.is_empty() or radius <= 0.0:
		return 0.0
	var best := 0.0
	for source in water_sources:
		var source_position: Vector2 = source.get("position", Vector2.ZERO)
		var source_radius := float(source.get("radius", 0.0))
		var influence_radius := radius + source_radius
		var distance := position.distance_to(source_position)
		if distance > influence_radius:
			continue
		best = maxf(best, 1.0 - (distance / maxf(influence_radius, 1.0)))
	return best


func _extract_lowest_cost_index(open: Array, f_score: Dictionary) -> int:
	var best_index := 0
	var best_cost := float(f_score.get(open[0], INF))
	for index in range(1, open.size()):
		var node := open[index]
		var node_cost := float(f_score.get(node, INF))
		if node_cost < best_cost:
			best_cost = node_cost
			best_index = index
	return int(open.pop_at(best_index))


func _heuristic_cost(from_index: int, to_index: int) -> float:
	return get_cell_center(from_index).distance_to(get_cell_center(to_index))


func _step_cost(from_index: int, to_index: int) -> float:
	return get_cell_center(from_index).distance_to(get_cell_center(to_index)) * get_move_cost_at_index(to_index)


func _reconstruct_path(current_index: int, came_from: Dictionary) -> Array:
	var path: Array = [current_index]
	var cursor := current_index
	while came_from.has(cursor):
		cursor = int(came_from[cursor])
		path.push_front(cursor)
	return path


func _closest_point_on_segment(point: Vector2, segment_start: Vector2, segment_end: Vector2) -> Vector2:
	var segment := segment_end - segment_start
	var segment_length_sq := segment.length_squared()
	if segment_length_sq <= 0.0001:
		return segment_start
	var t := clampf((point - segment_start).dot(segment) / segment_length_sq, 0.0, 1.0)
	return segment_start + segment * t
