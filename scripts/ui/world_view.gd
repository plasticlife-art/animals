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
	draw_rect(world.bounds, Color(0.09, 0.11, 0.1), true)
	draw_rect(world.bounds, Color(0.25, 0.3, 0.28), false, 2.0)

	var font = ThemeDB.fallback_font
	var font_size := ThemeDB.fallback_font_size
	var selected_id := simulation_manager.selected_agent_id
	var visible_rect := _get_visible_world_rect(world.bounds).grow(24.0)
	for agent in world.get_living_agents():
		if not visible_rect.has_point(agent.position):
			continue
		draw_circle(agent.position, 7.0 if agent.species_type == "herbivore" else 9.0, agent.debug_color)
		draw_line(agent.position, agent.position + agent.direction * 14.0, agent.debug_color.lightened(0.25), 2.0)
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


func _on_tick_completed(_tick: int, _snapshot: Dictionary) -> void:
	queue_redraw()


func _on_selection_changed(_agent_id: int) -> void:
	queue_redraw()


func _get_visible_world_rect(world_bounds: Rect2) -> Rect2:
	var viewport_rect := get_viewport_rect()
	var inverse_canvas := get_canvas_transform().affine_inverse()
	var top_left: Vector2 = inverse_canvas * viewport_rect.position
	var bottom_right: Vector2 = inverse_canvas * viewport_rect.end
	return Rect2(top_left, bottom_right - top_left).intersection(world_bounds)
