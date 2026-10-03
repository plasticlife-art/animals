class_name WorldView
extends Node2D

## World-space input and the few immediate-mode decorations that outlive the
## sprite renderer.
##
## Terrain moved to `terrain_tilemap.gd` and agents to `agent_renderer.gd`, so
## what is left here is the world border, the selection ring and the optional
## state labels - all cheap, all debug-adjacent - plus click-to-select, which
## has to live on a node that receives world input.

var simulation_manager: SimulationManager
var debug_flags: Dictionary = {}
var input_enabled: bool = true


func bind_manager(manager: SimulationManager) -> void:
	simulation_manager = manager
	if not simulation_manager.tick_completed.is_connected(_on_tick_completed):
		simulation_manager.tick_completed.connect(_on_tick_completed)
	if not simulation_manager.selection_changed.is_connected(_on_selection_changed):
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
		# The click arrives in screen space; selection happens in simulation
		# space, so it goes back through the projection seam.
		var world_position: Vector2 = WorldProjection.to_world(get_global_mouse_position())
		simulation_manager.select_agent_at_position(world_position, selection_radius)


func _draw() -> void:
	if simulation_manager == null or simulation_manager.world_state == null:
		return

	var world = simulation_manager.world_state
	# The terrain tiles cover every cell inside the bounds now, so only the
	# border outline is drawn here. Under a non-identity projection the world
	# rectangle is no longer a screen rectangle, so it is stroked as a polygon.
	_draw_world_border(world.bounds)


	if bool(debug_flags.get("show_state_labels", false)):
		_draw_state_labels(world)


func _draw_world_border(bounds: Rect2) -> void:
	var color := Color(0.25, 0.3, 0.28)
	if WorldProjection.is_identity():
		draw_rect(bounds, color, false, 2.0)
		return
	var outline := PackedVector2Array([
		WorldProjection.to_screen(bounds.position),
		WorldProjection.to_screen(Vector2(bounds.end.x, bounds.position.y)),
		WorldProjection.to_screen(bounds.end),
		WorldProjection.to_screen(Vector2(bounds.position.x, bounds.end.y)),
	])
	outline.append(outline[0])
	draw_polyline(outline, color, 2.0)


func _draw_state_labels(world) -> void:
	var font = ThemeDB.fallback_font
	if font == null:
		return
	var font_size := ThemeDB.fallback_font_size
	var visible_rect := _get_visible_world_rect(world.bounds).grow(24.0)
	for agent in world.get_living_agents():
		if not visible_rect.has_point(agent.position):
			continue
		draw_string(
			font,
			_screen_of(world, agent.position) + Vector2(10.0, -10.0),
			"%s №%d" % [HudText.state_label(agent.state), agent.id],
			HORIZONTAL_ALIGNMENT_LEFT,
			-1.0,
			font_size,
			Color(0.95, 0.95, 0.95, 0.9)
		)


## Both markers sit on the ground under the agent, so they need the same
## elevation the sprite got - otherwise the selection ring drifts off an animal
## standing on a rise.
func _screen_of(world, world_position: Vector2) -> Vector2:
	var level := 0
	if not WorldProjection.is_identity() and world.terrain_system != null:
		level = world.terrain_system.get_height_at_position(world_position)
	return WorldProjection.to_screen(world_position, level)


func _on_tick_completed(tick: int, _snapshot: Dictionary) -> void:
	if simulation_manager != null and not simulation_manager.should_refresh_ui_on_tick(tick):
		return
	request_refresh()


func _on_selection_changed(_agent_id: int) -> void:
	request_refresh()


func _get_visible_world_rect(world_bounds: Rect2) -> Rect2:
	var camera := _get_game_camera()
	if camera != null:
		return WorldProjection.world_rect_covering(camera.get_visible_screen_rect())
	return world_bounds


func _get_game_camera() -> GameCamera:
	var camera = get_viewport().get_camera_2d()
	return camera if camera is GameCamera else null
