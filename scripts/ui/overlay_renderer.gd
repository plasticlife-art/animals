class_name OverlayRenderer
extends Node2D

var simulation_manager: SimulationManager
var debug_flags: Dictionary = {}


func bind_manager(manager: SimulationManager) -> void:
	simulation_manager = manager
	simulation_manager.tick_completed.connect(_on_tick_completed)
	simulation_manager.selection_changed.connect(_on_selection_changed)
	queue_redraw()


func set_debug_flag(flag_name: String, enabled: bool) -> void:
	debug_flags[flag_name] = enabled
	queue_redraw()


func _draw() -> void:
	if simulation_manager == null or simulation_manager.world_state == null:
		return

	var world = simulation_manager.world_state
	var visible_rect := _get_visible_world_rect(world.bounds)
	if bool(debug_flags.get("show_biomes", false)):
		_draw_biomes(world, visible_rect)
	if bool(debug_flags.get("show_obstacles", false)):
		_draw_obstacles(world, visible_rect)
	if bool(debug_flags.get("show_grass_density", false)):
		_draw_grass_density(world, visible_rect)
	if bool(debug_flags.get("show_water_overlay", true)):
		_draw_water(world, visible_rect)
	if bool(debug_flags.get("show_carcasses", false)):
		_draw_carcasses(world, visible_rect)
	if bool(debug_flags.get("show_selected_path", false)):
		_draw_selected_path(world, visible_rect)
	if bool(debug_flags.get("show_population_density", false)):
		_draw_population_density(world, visible_rect)
	if bool(debug_flags.get("show_target_lines", false)):
		_draw_target_lines(world, visible_rect)
	if bool(debug_flags.get("show_chase_lines", false)):
		_draw_chase_lines(world, visible_rect)
	if bool(debug_flags.get("show_vision_radius", false)):
		_draw_selected_agent_radius()
	if bool(debug_flags.get("show_herd_relations", false)):
		_draw_selected_group_relation(world, visible_rect)


func _draw_grass_density(world, visible_rect: Rect2) -> void:
	var cell_size: float = world.resource_system.cell_size
	var min_cell_x := maxi(0, int(floor(visible_rect.position.x / cell_size)))
	var min_cell_y := maxi(0, int(floor(visible_rect.position.y / cell_size)))
	var max_cell_x := mini(world.resource_system.cols - 1, int(floor(visible_rect.end.x / cell_size)))
	var max_cell_y := mini(world.resource_system.rows - 1, int(floor(visible_rect.end.y / cell_size)))
	for x in range(min_cell_x, max_cell_x + 1):
		for y in range(min_cell_y, max_cell_y + 1):
			var index: int = y * world.resource_system.cols + x
			var biomass: float = world.resource_system.get_biomass(index)
			if biomass <= 0.5:
				continue
			var density: float = biomass / maxf(1.0, world.resource_system.max_biomass)
			if density <= 0.02:
				continue
			draw_rect(world.resource_system.get_cell_rect(index), Color(0.18, 0.44, 0.2, density * 0.42), true)


func _draw_biomes(world, visible_rect: Rect2) -> void:
	if world.terrain_system == null:
		return
	var terrain: TerrainSystem = world.terrain_system
	var cell_size: float = terrain.cell_size
	var min_cell_x: int = maxi(0, int(floor(visible_rect.position.x / cell_size)))
	var min_cell_y: int = maxi(0, int(floor(visible_rect.position.y / cell_size)))
	var max_cell_x: int = mini(terrain.cols - 1, int(floor(visible_rect.end.x / cell_size)))
	var max_cell_y: int = mini(terrain.rows - 1, int(floor(visible_rect.end.y / cell_size)))
	for x in range(min_cell_x, max_cell_x + 1):
		for y in range(min_cell_y, max_cell_y + 1):
			var index: int = y * terrain.cols + x
			var biome_color: Color = terrain.get_biome_color_at_index(index)
			biome_color.a = 0.32
			draw_rect(terrain.get_cell_rect(index), biome_color, true)


func _draw_obstacles(world, visible_rect: Rect2) -> void:
	if world.terrain_system == null:
		return
	var terrain: TerrainSystem = world.terrain_system
	var cell_size: float = terrain.cell_size
	var min_cell_x: int = maxi(0, int(floor(visible_rect.position.x / cell_size)))
	var min_cell_y: int = maxi(0, int(floor(visible_rect.position.y / cell_size)))
	var max_cell_x: int = mini(terrain.cols - 1, int(floor(visible_rect.end.x / cell_size)))
	var max_cell_y: int = mini(terrain.rows - 1, int(floor(visible_rect.end.y / cell_size)))
	for x in range(min_cell_x, max_cell_x + 1):
		for y in range(min_cell_y, max_cell_y + 1):
			var index: int = y * terrain.cols + x
			var obstacle_id: String = terrain.get_obstacle_at_index(index)
			if obstacle_id == "":
				continue
			var rect: Rect2 = terrain.get_cell_rect(index)
			var obstacle_color: Color = terrain.get_obstacle_color(obstacle_id)
			obstacle_color.a = 0.72
			draw_rect(rect, obstacle_color, true)
			draw_rect(rect, Color(0.9, 0.9, 0.9, 0.12), false, 1.0)


func _draw_water(world, visible_rect: Rect2) -> void:
	for source in world.water_sources:
		var position: Vector2 = source["position"]
		var radius: float = float(source["radius"])
		var source_rect := Rect2(position - Vector2.ONE * radius, Vector2.ONE * radius * 2.0)
		if not visible_rect.intersects(source_rect):
			continue
		draw_circle(position, radius, Color(0.2, 0.42, 0.82, 0.22))
		draw_arc(position, radius, 0.0, TAU, 32, Color(0.52, 0.75, 1.0, 0.65), 2.0)


func _draw_carcasses(world, visible_rect: Rect2) -> void:
	var font = ThemeDB.fallback_font
	var font_size: int = max(10, ThemeDB.fallback_font_size - 1)
	var query_radius: float = visible_rect.size.length() * 0.5 + 48.0
	var carcasses: Array = world.query_carcasses(visible_rect.get_center(), query_radius)
	for carcass in carcasses:
		var position: Vector2 = carcass["position"]
		var meat_remaining: float = float(carcass.get("meat_remaining", 0.0))
		var meat_total: float = maxf(1.0, float(carcass.get("meat_total", 1.0)))
		var carcass_radius := lerpf(6.0, 11.0, clampf(meat_remaining / meat_total, 0.0, 1.0))
		var carcass_rect := Rect2(position - Vector2.ONE * (carcass_radius + 14.0), Vector2.ONE * (carcass_radius + 14.0) * 2.0)
		if not visible_rect.intersects(carcass_rect):
			continue

		draw_circle(position, carcass_radius + 3.0, Color(0.18, 0.08, 0.06, 0.5))
		draw_circle(position, carcass_radius, Color(0.42, 0.14, 0.1, 0.86))
		draw_arc(position, carcass_radius + 1.5, 0.0, TAU, 24, Color(0.93, 0.78, 0.66, 0.9), 1.4)
		draw_line(position + Vector2(-4.0, -4.0), position + Vector2(4.0, 4.0), Color(0.97, 0.88, 0.8, 0.72), 1.4)
		draw_line(position + Vector2(-4.0, 4.0), position + Vector2(4.0, -4.0), Color(0.97, 0.88, 0.8, 0.72), 1.4)

		if font != null:
			var label: String = "%.0f" % meat_remaining
			draw_string(
				font,
				position + Vector2(carcass_radius + 6.0, -carcass_radius - 2.0),
				label,
				HORIZONTAL_ALIGNMENT_LEFT,
				-1.0,
				font_size,
				Color(1.0, 0.92, 0.82, 0.96)
			)


func _draw_selected_path(world, visible_rect: Rect2) -> void:
	var agent = simulation_manager.get_selected_agent()
	if agent == null or world.terrain_system == null or agent.path_cells.is_empty():
		return
	var path_points: PackedVector2Array = PackedVector2Array()
	path_points.append(agent.position)
	for path_index in range(agent.path_index, agent.path_cells.size()):
		var cell_index := int(agent.path_cells[path_index])
		path_points.append(world.terrain_system.get_cell_center(cell_index))
	if agent.target_position != null:
		path_points.append(agent.target_position)
	if path_points.size() < 2:
		return
	for index in range(path_points.size() - 1):
		var from_point: Vector2 = path_points[index]
		var to_point: Vector2 = path_points[index + 1]
		if not _line_is_visible(from_point, to_point, visible_rect.grow(12.0)):
			continue
		draw_line(from_point, to_point, Color(0.98, 0.94, 0.62, 0.92), 2.6)
		draw_circle(to_point, 3.5, Color(0.98, 0.94, 0.62, 0.92))


func _draw_population_density(world, visible_rect: Rect2) -> void:
	for cell_data in world.spatial_grid.get_population_density_in_rect(visible_rect):
		var count := int(cell_data["count"])
		if count <= 0:
			continue
		var rect := Rect2(
			cell_data["position"] - Vector2.ONE * float(cell_data["size"]) * 0.5,
			Vector2.ONE * float(cell_data["size"])
		)
		var alpha := clampf(float(count) / 10.0, 0.05, 0.4)
		draw_rect(rect, Color(0.96, 0.72, 0.18, alpha), true)


func _draw_target_lines(world, visible_rect: Rect2) -> void:
	for agent in world.get_living_agents():
		if agent.target_agent_id != -1:
			var target_agent = world.get_agent(agent.target_agent_id)
			if target_agent != null and target_agent.is_alive:
				if not _line_is_visible(agent.position, target_agent.position, visible_rect):
					continue
				draw_line(agent.position, target_agent.position, Color(1.0, 1.0, 1.0, 0.42), 1.5)
		elif agent.target_position != null:
			if not _line_is_visible(agent.position, agent.target_position, visible_rect):
				continue
			draw_line(agent.position, agent.target_position, Color(0.8, 0.8, 0.8, 0.22), 1.0)


func _draw_chase_lines(world, visible_rect: Rect2) -> void:
	for agent in world.get_living_agents():
		if agent.species_type != "predator":
			continue
		if agent.state not in ["seek_prey", "chase", "attack"]:
			continue
		if agent.target_agent_id == -1:
			continue
		var prey = world.get_agent(agent.target_agent_id)
		if prey == null or not prey.is_alive:
			continue
		if not _line_is_visible(agent.position, prey.position, visible_rect):
			continue
		draw_line(agent.position, prey.position, Color(1.0, 0.42, 0.18, 0.78), 2.0)


func _draw_selected_agent_radius() -> void:
	var agent = simulation_manager.get_selected_agent()
	if agent == null:
		return
	var radius: float = float(agent.perception.get("vision_radius", agent.perception.get("danger_radius", 0.0)))
	draw_arc(agent.position, radius, 0.0, TAU, 48, Color(0.85, 0.9, 1.0, 0.7), 1.5)


func _draw_selected_group_relation(world, visible_rect: Rect2) -> void:
	var agent = simulation_manager.get_selected_agent()
	if agent == null or agent.group_id == -1:
		return
	var group_center = world.get_group_center(agent.group_id, agent.species_type, agent.id)
	if group_center == null:
		return
	if not _line_is_visible(agent.position, group_center, visible_rect.grow(12.0)):
		return
	draw_line(agent.position, group_center, Color(0.78, 1.0, 0.8, 0.85), 2.0)
	draw_circle(group_center, 6.0, Color(0.78, 1.0, 0.8, 0.85))


func _on_tick_completed(_tick: int, _snapshot: Dictionary) -> void:
	queue_redraw()


func _on_selection_changed(_agent_id: int) -> void:
	queue_redraw()


func _get_visible_world_rect(_world_bounds: Rect2) -> Rect2:
	var camera := _get_game_camera()
	if camera != null:
		return camera.get_visible_world_rect()
	return _world_bounds


func _line_is_visible(from_point: Vector2, to_point: Vector2, visible_rect: Rect2) -> bool:
	if visible_rect.has_point(from_point) or visible_rect.has_point(to_point):
		return true
	var bounds := Rect2(from_point, Vector2.ZERO).expand(to_point).grow(6.0)
	return visible_rect.intersects(bounds)


func _get_game_camera() -> GameCamera:
	var camera = get_viewport().get_camera_2d()
	return camera if camera is GameCamera else null
