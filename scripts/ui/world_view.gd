class_name WorldView
extends Node2D

var simulation_manager: SimulationManager
var debug_flags: Dictionary = {}
var input_enabled: bool = true


func bind_manager(manager: SimulationManager) -> void:
	simulation_manager = manager
	simulation_manager.tick_completed.connect(_on_tick_completed)
	simulation_manager.selection_changed.connect(_on_selection_changed)
	queue_redraw()


func set_debug_flag(flag_name: String, enabled: bool) -> void:
	debug_flags[flag_name] = enabled
	queue_redraw()


func set_input_enabled(value: bool) -> void:
	input_enabled = value


func request_refresh() -> void:
	if is_visible_in_tree():
		queue_redraw()


func _unhandled_input(event: InputEvent) -> void:
	if simulation_manager == null or not input_enabled:
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		var selection_radius := float(simulation_manager.config_bundle.get("debug", {}).get("selection_radius", 18.0))
		simulation_manager.select_agent_at_position(get_global_mouse_position(), selection_radius)


func _draw() -> void:
	if simulation_manager == null or simulation_manager.world_state == null:
		return

	var world = simulation_manager.world_state
	draw_rect(world.bounds, Color(0.08, 0.1, 0.09), true)

	var font = ThemeDB.fallback_font
	var font_size := ThemeDB.fallback_font_size
	var selected_id := simulation_manager.selected_agent_id
	var visible_rect := _get_visible_world_rect(world.bounds).grow(24.0)
	if bool(debug_flags.get("show_biomes", false)) or bool(debug_flags.get("show_obstacles", false)):
		_draw_terrain_background(world, visible_rect)
	draw_rect(world.bounds, Color(0.25, 0.3, 0.28), false, 2.0)
	for agent in world.get_living_agents():
		if not visible_rect.has_point(agent.position):
			continue
		var agent_color := _get_agent_draw_color(agent)
		draw_circle(agent.position, 7.0 if agent.species_type == "herbivore" else 9.0, agent_color)
		draw_line(agent.position, agent.position + agent.direction * 14.0, agent_color.lightened(0.25), 2.0)
		if selected_id == agent.id:
			draw_arc(agent.position, 14.0, 0.0, TAU, 24, Color(1.0, 1.0, 1.0, 0.9), 2.0)
		if bool(debug_flags.get("show_state_labels", false)) and font != null:
			draw_string(
				font,
				agent.position + Vector2(10.0, -10.0),
				"%s #%d" % [agent.state, agent.id],
				HORIZONTAL_ALIGNMENT_LEFT,
				-1.0,
				font_size,
				Color(0.95, 0.95, 0.95, 0.9)
			)


func _draw_terrain_background(world, visible_rect: Rect2) -> void:
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
			var tint_strength: float = 0.4
			if bool(debug_flags.get("show_biomes", false)):
				tint_strength = 0.72
			var fill_color := biome_color.darkened(0.08)
			fill_color.a = tint_strength
			draw_rect(terrain.get_cell_rect(index), fill_color, true)
			if terrain.get_obstacle_at_index(index) != "":
				var obstacle_alpha: float = 0.78 if bool(debug_flags.get("show_obstacles", false)) else 0.52
				var obstacle_color: Color = terrain.get_obstacle_color(terrain.get_obstacle_at_index(index))
				obstacle_color.a = obstacle_alpha
				draw_rect(terrain.get_cell_rect(index), obstacle_color, true)


func _on_tick_completed(_tick: int, _snapshot: Dictionary) -> void:
	request_refresh()


func _on_selection_changed(_agent_id: int) -> void:
	request_refresh()


func _get_visible_world_rect(_world_bounds: Rect2) -> Rect2:
	var camera := _get_game_camera()
	if camera != null:
		return camera.get_visible_world_rect()
	return _world_bounds


func _get_agent_draw_color(agent) -> Color:
	var base_color: Color = agent.debug_color
	if not bool(debug_flags.get("show_lod_overlay", false)):
		return base_color

	var lod_color := Color(0.74, 0.93, 0.78)
	match int(agent.lod_tier):
		1:
			lod_color = Color(0.98, 0.8, 0.28)
		2:
			lod_color = Color(0.95, 0.45, 0.45)
	return base_color.lerp(lod_color, 0.68)


func _get_game_camera() -> GameCamera:
	var camera = get_viewport().get_camera_2d()
	return camera if camera is GameCamera else null
