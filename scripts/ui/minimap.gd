class_name MiniMap
extends Control

const PANEL_BACKGROUND_COLOR := Color(0.05, 0.07, 0.08, 0.88)
const PANEL_BORDER_COLOR := Color(0.82, 0.88, 0.9, 0.22)
const MAP_BACKGROUND_COLOR := Color(0.1, 0.13, 0.12, 1.0)
const MAP_BORDER_COLOR := Color(0.9, 0.95, 0.98, 0.2)
const WATER_FILL_COLOR := Color(0.24, 0.48, 0.78, 0.8)
## A shade darker than the fill: a bright rim made fifty small ponds the loudest thing
## on the map.
const WATER_OUTLINE_COLOR := Color(0.16, 0.34, 0.6, 0.9)
## Fallback only. Real per-species colours and dot sizes come from
## `visuals.json -> species.<id>.ui_color` / `.minimap_radius`; anything that is
## not "predator" used to be drawn as a herbivore, so a third species would have
## been invisible as itself on the overview map.
const UNKNOWN_SPECIES_COLOR := Color(0.82, 0.86, 0.9, 0.95)
const SELECTED_COLOR := Color(1.0, 1.0, 1.0, 0.96)
const CAMERA_FILL_COLOR := Color(1.0, 1.0, 1.0, 0.08)
const CAMERA_BORDER_COLOR := Color(1.0, 1.0, 1.0, 0.88)
const PANEL_PADDING := 10.0
const MAP_PADDING := 8.0
const MIN_CAMERA_RECT_SIZE := 4.0
const DOT_TEXTURE_SIZE := 12
const DOT_CAPACITY_CHUNK := 256

## Built once per bind from `visuals.json`, because this runs per agent per
## redraw and must not parse config in the loop.
var _species_dots: Dictionary = {}
@export var selected_radius: float = 5.0

var simulation_manager: SimulationManager
var world_camera: GameCamera
var input_enabled: bool = true
## The world's place names (`PlaceNames`), for the tooltip; none, no tooltip.
var places = null

var _static_texture: Texture2D
var _cached_world_bounds: Rect2 = Rect2()
var _cached_map_pixel_size: Vector2i = Vector2i.ZERO
var _dragging: bool = false
var _last_camera_rect: Rect2 = Rect2()
var _overview_mode: bool = false
var _overview_refresh_interval: float = 0.2
var _normal_refresh_interval: float = 0.25
var _refresh_elapsed: float = 0.0
var _refresh_pending: bool = false
var _dot_multimesh: MultiMesh
var _dot_texture: Texture2D
var _dots_dirty: bool = true


## On by default, as water is on the map itself. The large map has about fifty
## watering holes, a few pixels each here; the "lush" scenario has a few hundred, and
## there they read more as a lattice than as information, so the debug panel can still
## switch them off.
var _show_water: bool = true


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	mouse_filter = Control.MOUSE_FILTER_STOP
	focus_mode = Control.FOCUS_NONE
	_initialize_dot_batch()
	queue_redraw()


## Per-species dot colour and size, read straight out of the art config so the
## overview map cannot drift from what the sprites look like.
func _rebuild_species_dots() -> void:
	_species_dots.clear()
	if simulation_manager == null:
		return
	var species_visuals: Dictionary = simulation_manager.config_bundle.get("visuals", {}).get("species", {})
	for species_id in species_visuals.keys():
		var config: Dictionary = species_visuals[species_id]
		var rgb: Array = config.get("ui_color", [0.82, 0.86, 0.9])
		_species_dots[str(species_id)] = {
			"radius": float(config.get("minimap_radius", 1.5)),
			"color": Color(float(rgb[0]), float(rgb[1]), float(rgb[2]), 0.96),
		}


func bind_manager(manager: SimulationManager) -> void:
	if simulation_manager != manager:
		_disconnect_manager()
		simulation_manager = manager
		_connect_manager()
	_last_camera_rect = Rect2()
	_rebuild_species_dots()
	var hz := maxf(0.1, float(manager.config_bundle.get("visuals", {}) \
		.get("overview_lod", {}).get("minimap_refresh_hz", 5.0)))
	_overview_refresh_interval = 1.0 / hz
	# Camera motion used to redraw the complete animal map every frame. Keep it
	# on the same cadence as the rest of the HUD; overview has its explicit cap.
	_normal_refresh_interval = float(manager.ui_refresh_interval_ticks) / maxf(1.0, manager.tick_rate)
	_refresh_elapsed = 0.0
	_refresh_pending = false
	_rebuild_static_cache()
	queue_redraw()


func bind_camera(camera: GameCamera) -> void:
	world_camera = camera
	_last_camera_rect = Rect2()
	queue_redraw()


func set_input_enabled(value: bool) -> void:
	input_enabled = value
	if not input_enabled:
		_dragging = false


func request_refresh() -> void:
	if is_visible_in_tree():
		_dots_dirty = true
		queue_redraw()


func set_overview_mode(value: bool) -> void:
	if _overview_mode == value:
		return
	_overview_mode = value
	_refresh_pending = true
	_refresh_elapsed = _current_refresh_interval()


func _process(delta: float) -> void:
	if _dragging and not Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		_dragging = false

	var current_camera_rect := Rect2()
	if world_camera != null:
		current_camera_rect = world_camera.get_visible_world_rect()

	if _rect_changed(_last_camera_rect, current_camera_rect):
		_last_camera_rect = current_camera_rect
		_refresh_pending = true
	if _refresh_pending:
		_refresh_elapsed += delta
		if _refresh_elapsed >= _current_refresh_interval():
			_refresh_elapsed = 0.0
			_refresh_pending = false
			request_refresh()


func _current_refresh_interval() -> float:
	return _overview_refresh_interval if _overview_mode else _normal_refresh_interval


func _gui_input(event: InputEvent) -> void:
	if not input_enabled or simulation_manager == null or world_camera == null:
		return

	var map_rect := _get_map_rect()
	if map_rect.size.x <= 0.0 or map_rect.size.y <= 0.0:
		return

	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			if map_rect.has_point(event.position):
				_dragging = true
				_move_camera_from_local_position(event.position)
				accept_event()
		elif _dragging:
			_dragging = false
			accept_event()
	elif event is InputEventMouseMotion and _dragging:
		if map_rect.has_point(event.position):
			_move_camera_from_local_position(event.position)
		accept_event()


func _draw() -> void:
	var started := Time.get_ticks_usec()
	var panel_rect := Rect2(Vector2.ZERO, size)
	draw_rect(panel_rect, PANEL_BACKGROUND_COLOR, true)
	draw_rect(panel_rect, PANEL_BORDER_COLOR, false, 2.0)

	var map_rect := _get_map_rect()
	if map_rect.size.x <= 0.0 or map_rect.size.y <= 0.0:
		_record_draw_time(started)
		return

	draw_rect(map_rect, MAP_BACKGROUND_COLOR, true)
	if _static_texture != null:
		draw_texture_rect(_static_texture, map_rect, false)
	draw_rect(map_rect, MAP_BORDER_COLOR, false, 1.0)

	if simulation_manager == null or simulation_manager.world_state == null:
		_record_draw_time(started)
		return

	if _dots_dirty:
		_rebuild_dot_batch(map_rect)
		_dots_dirty = false
	if _dot_multimesh != null and _dot_multimesh.visible_instance_count > 0:
		draw_multimesh(_dot_multimesh, _dot_texture)
	_draw_selected_agent(map_rect)
	_draw_camera_rect(map_rect)
	_record_draw_time(started)


func _record_draw_time(started_usec: int) -> void:
	if simulation_manager != null:
		simulation_manager.record_render_phase("minimap",
			float(Time.get_ticks_usec() - started_usec) / 1000.0)


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		_rebuild_static_cache()
		request_refresh()


func _connect_manager() -> void:
	if simulation_manager == null:
		return
	if not simulation_manager.tick_completed.is_connected(_on_tick_completed):
		simulation_manager.tick_completed.connect(_on_tick_completed)
	if not simulation_manager.selection_changed.is_connected(_on_selection_changed):
		simulation_manager.selection_changed.connect(_on_selection_changed)


func _disconnect_manager() -> void:
	if simulation_manager == null:
		return
	if simulation_manager.tick_completed.is_connected(_on_tick_completed):
		simulation_manager.tick_completed.disconnect(_on_tick_completed)
	if simulation_manager.selection_changed.is_connected(_on_selection_changed):
		simulation_manager.selection_changed.disconnect(_on_selection_changed)


func _initialize_dot_batch() -> void:
	var image := Image.create(DOT_TEXTURE_SIZE, DOT_TEXTURE_SIZE, false, Image.FORMAT_RGBA8)
	image.fill(Color.TRANSPARENT)
	var center := Vector2.ONE * (float(DOT_TEXTURE_SIZE) - 1.0) * 0.5
	var radius := float(DOT_TEXTURE_SIZE) * 0.42
	for x in DOT_TEXTURE_SIZE:
		for y in DOT_TEXTURE_SIZE:
			var sample := Vector2(float(x), float(y))
			if sample.distance_to(center) <= radius:
				image.set_pixel(x, y, Color.WHITE)
	_dot_texture = ImageTexture.create_from_image(image)
	var quad := QuadMesh.new()
	quad.size = Vector2.ONE
	_dot_multimesh = MultiMesh.new()
	_dot_multimesh.transform_format = MultiMesh.TRANSFORM_2D
	_dot_multimesh.use_colors = true
	_dot_multimesh.mesh = quad


func _ensure_dot_capacity(needed: int) -> void:
	if _dot_multimesh.instance_count >= needed:
		return
	_dot_multimesh.instance_count = maxi(needed,
		_dot_multimesh.instance_count + DOT_CAPACITY_CHUNK)


func _write_dot(index: int, point: Vector2, dot: Dictionary) -> void:
	var radius := float(dot.get("radius", 1.5))
	var diameter := radius * 2.0
	_dot_multimesh.set_instance_transform_2d(index, Transform2D(
		Vector2(diameter, 0.0), Vector2(0.0, diameter), point))
	_dot_multimesh.set_instance_color(index,
		dot.get("color", UNKNOWN_SPECIES_COLOR))


func _rebuild_dot_batch(map_rect: Rect2) -> void:
	if _dot_multimesh == null or simulation_manager == null \
			or simulation_manager.world_state == null:
		return
	var world = simulation_manager.world_state
	var count := world.get_living_agents().size()
	for sector in world._sector_states.values():
		if not bool(sector.get("dormant", false)):
			continue
		for aggregate in sector.get("dormant_aggregates", []):
			count += aggregate.get("record_ids", []).size()
	_ensure_dot_capacity(count)
	var index := 0
	for agent in world.get_living_agents():
		var point := _world_to_map_point(agent.position, map_rect)
		if not map_rect.has_point(point):
			continue
		_write_dot(index, point, _species_dots.get(agent.species_type, {}))
		index += 1
	# Sleeping animals are drawn where their records stand, so the minimap shows a
	# dormant herd's real formation rather than a stand-in around its centre.
	for sector in world._sector_states.values():
		if not bool(sector.get("dormant", false)):
			continue
		for aggregate in sector.get("dormant_aggregates", []):
			var dot: Dictionary = _species_dots.get(str(aggregate.get("species_type", "")), {})
			for member_index in range(aggregate.get("record_ids", []).size()):
				var point := SceneSpriteBatch.dormant_member_position(aggregate, member_index)
				_write_dot(index, _world_to_map_point(point, map_rect), dot)
				index += 1
	_dot_multimesh.visible_instance_count = index


func _draw_selected_agent(map_rect: Rect2) -> void:
	var agent = simulation_manager.get_selected_agent()
	if agent == null:
		return
	var point := _world_to_map_point(agent.position, map_rect)
	draw_arc(point, selected_radius, 0.0, TAU, 24, SELECTED_COLOR, 1.4)


func _draw_camera_rect(map_rect: Rect2) -> void:
	if world_camera == null:
		return
	var visible_rect := world_camera.get_visible_world_rect()
	if visible_rect.size.is_zero_approx():
		return
	var camera_rect := _world_to_map_rect(visible_rect, map_rect)
	draw_rect(camera_rect, CAMERA_FILL_COLOR, true)
	draw_rect(camera_rect, CAMERA_BORDER_COLOR, false, 2.0)


func _move_camera_from_local_position(local_position: Vector2) -> void:
	var world_position := _map_to_world_position(local_position, _get_map_rect())
	world_camera.move_to_world_position(world_position)
	_last_camera_rect = world_camera.get_visible_world_rect()
	request_refresh()


func _get_map_rect() -> Rect2:
	var outer_rect := Rect2(
		Vector2(PANEL_PADDING, PANEL_PADDING),
		size - Vector2.ONE * PANEL_PADDING * 2.0
	)
	if outer_rect.size.x <= 0.0 or outer_rect.size.y <= 0.0:
		return Rect2()

	var inner_rect := Rect2(
		outer_rect.position + Vector2.ONE * MAP_PADDING,
		outer_rect.size - Vector2.ONE * MAP_PADDING * 2.0
	)
	if inner_rect.size.x <= 0.0 or inner_rect.size.y <= 0.0:
		return Rect2()

	var aspect := 16.0 / 9.0
	var world_bounds := _get_world_bounds()
	if not world_bounds.size.is_zero_approx():
		aspect = world_bounds.size.x / maxf(1.0, world_bounds.size.y)

	var fitted_size := inner_rect.size
	if inner_rect.size.x / maxf(1.0, inner_rect.size.y) > aspect:
		fitted_size.x = inner_rect.size.y * aspect
	else:
		fitted_size.y = inner_rect.size.x / maxf(0.01, aspect)

	var fitted_position := inner_rect.position + (inner_rect.size - fitted_size) * 0.5
	return Rect2(fitted_position.floor(), fitted_size.floor())


## The name of the place under the cursor: a pond, or the district it lies in.
func _get_tooltip(at_position: Vector2) -> String:
	if places == null:
		return ""
	var map_rect := _get_map_rect()
	if not map_rect.has_point(at_position):
		return ""
	return str(places.place_at(_map_to_world_position(at_position, map_rect)).get("name", ""))


func _get_world_bounds() -> Rect2:
	if simulation_manager != null and simulation_manager.world_state != null:
		return simulation_manager.world_state.bounds
	return _cached_world_bounds


func _map_to_world_position(local_position: Vector2, map_rect: Rect2) -> Vector2:
	var world_bounds := _get_world_bounds()
	if world_bounds.size.is_zero_approx() or map_rect.size.x <= 0.0 or map_rect.size.y <= 0.0:
		return world_bounds.get_center()

	var normalized := (local_position - map_rect.position) / map_rect.size
	normalized.x = clampf(normalized.x, 0.0, 1.0)
	normalized.y = clampf(normalized.y, 0.0, 1.0)
	return world_bounds.position + Vector2(
		normalized.x * world_bounds.size.x,
		normalized.y * world_bounds.size.y
	)


func _world_to_map_point(world_position: Vector2, map_rect: Rect2) -> Vector2:
	var world_bounds := _get_world_bounds()
	if world_bounds.size.is_zero_approx():
		return map_rect.get_center()
	var normalized := (world_position - world_bounds.position) / world_bounds.size
	normalized.x = clampf(normalized.x, 0.0, 1.0)
	normalized.y = clampf(normalized.y, 0.0, 1.0)
	return map_rect.position + Vector2(
		normalized.x * map_rect.size.x,
		normalized.y * map_rect.size.y
	)


func _world_to_map_rect(world_rect: Rect2, map_rect: Rect2) -> Rect2:
	var top_left := _world_to_map_point(world_rect.position, map_rect)
	var bottom_right := _world_to_map_point(world_rect.end, map_rect)
	var result := Rect2(top_left, bottom_right - top_left)
	if result.size.x < MIN_CAMERA_RECT_SIZE:
		result.position.x -= (MIN_CAMERA_RECT_SIZE - result.size.x) * 0.5
		result.size.x = MIN_CAMERA_RECT_SIZE
	if result.size.y < MIN_CAMERA_RECT_SIZE:
		result.position.y -= (MIN_CAMERA_RECT_SIZE - result.size.y) * 0.5
		result.size.y = MIN_CAMERA_RECT_SIZE
	return result.intersection(map_rect)


## Water is baked into the cached terrain image rather than drawn each frame, so
## toggling it has to invalidate that cache. The flag is the only debug flag the
## minimap reads; the rest are overlays on the main view.
func set_debug_flag(flag_name: String, enabled: bool) -> void:
	if flag_name != "show_minimap_water" or _show_water == enabled:
		return
	_show_water = enabled
	_rebuild_static_cache()
	queue_redraw()


func _rebuild_static_cache() -> void:
	_static_texture = null
	_cached_world_bounds = Rect2()
	_cached_map_pixel_size = Vector2i.ZERO

	if simulation_manager == null or simulation_manager.world_state == null:
		return

	var map_rect := _get_map_rect()
	if map_rect.size.x < 2.0 or map_rect.size.y < 2.0:
		return

	var world = simulation_manager.world_state
	_cached_world_bounds = world.bounds
	_cached_map_pixel_size = Vector2i(
		maxi(1, int(round(map_rect.size.x))),
		maxi(1, int(round(map_rect.size.y)))
	)

	var image := Image.create(
		_cached_map_pixel_size.x,
		_cached_map_pixel_size.y,
		false,
		Image.FORMAT_RGBA8
	)
	image.fill(MAP_BACKGROUND_COLOR)

	_rasterize_terrain(image, world)
	if _show_water:
		_rasterize_water(image, world)
	_static_texture = ImageTexture.create_from_image(image)


func _rasterize_terrain(image: Image, world) -> void:
	if world.terrain_system == null:
		return
	var terrain: TerrainSystem = world.terrain_system
	for y in range(terrain.rows):
		for x in range(terrain.cols):
			var index := y * terrain.cols + x
			var color: Color = terrain.get_biome_color_at_index(index).darkened(0.08)
			var obstacle_id := terrain.get_obstacle_at_index(index)
			if obstacle_id != "":
				var obstacle_color := terrain.get_obstacle_color(obstacle_id)
				obstacle_color.a = 0.58
				color = _blend_colors(color, obstacle_color)
			var cell_rect := terrain.get_cell_rect(index)
			var texture_rect := _world_rect_to_texture_rect(cell_rect, image.get_size())
			_fill_image_rect(image, texture_rect, color)


func _rasterize_water(image: Image, world) -> void:
	for source in world.water_sources:
		var center := _world_to_texture_point(source["position"], image.get_size())
		var radius := float(source["radius"]) * _get_texture_scale(image.get_size())
		_draw_circle_on_image(image, center, radius, WATER_FILL_COLOR, WATER_OUTLINE_COLOR)


func _world_rect_to_texture_rect(world_rect: Rect2, texture_size: Vector2i) -> Rect2i:
	var start := _world_to_texture_point(world_rect.position, texture_size)
	var finish := _world_to_texture_point(world_rect.end, texture_size)
	var min_x := maxi(0, mini(texture_size.x - 1, int(floor(start.x))))
	var min_y := maxi(0, mini(texture_size.y - 1, int(floor(start.y))))
	var max_x := maxi(min_x + 1, mini(texture_size.x, int(ceil(finish.x))))
	var max_y := maxi(min_y + 1, mini(texture_size.y, int(ceil(finish.y))))
	return Rect2i(min_x, min_y, max_x - min_x, max_y - min_y)


func _world_to_texture_point(world_position: Vector2, texture_size: Vector2i) -> Vector2:
	var world_bounds := _cached_world_bounds
	if world_bounds.size.is_zero_approx():
		return Vector2.ZERO
	var normalized := (world_position - world_bounds.position) / world_bounds.size
	normalized.x = clampf(normalized.x, 0.0, 1.0)
	normalized.y = clampf(normalized.y, 0.0, 1.0)
	return Vector2(
		normalized.x * float(texture_size.x),
		normalized.y * float(texture_size.y)
	)


func _get_texture_scale(texture_size: Vector2i) -> float:
	if _cached_world_bounds.size.x <= 0.0:
		return 1.0
	return float(texture_size.x) / _cached_world_bounds.size.x


func _fill_image_rect(image: Image, rect: Rect2i, color: Color) -> void:
	var x_end := rect.position.x + rect.size.x
	var y_end := rect.position.y + rect.size.y
	for x in range(rect.position.x, x_end):
		for y in range(rect.position.y, y_end):
			image.set_pixel(x, y, color)


func _draw_circle_on_image(image: Image, center: Vector2, radius: float, fill_color: Color, outline_color: Color) -> void:
	if radius <= 0.0:
		return
	var min_x := maxi(0, int(floor(center.x - radius - 1.0)))
	var min_y := maxi(0, int(floor(center.y - radius - 1.0)))
	var max_x := mini(image.get_width() - 1, int(ceil(center.x + radius + 1.0)))
	var max_y := mini(image.get_height() - 1, int(ceil(center.y + radius + 1.0)))
	for x in range(min_x, max_x + 1):
		for y in range(min_y, max_y + 1):
			var sample := Vector2(float(x) + 0.5, float(y) + 0.5)
			var distance := sample.distance_to(center)
			if distance <= radius:
				image.set_pixel(x, y, _blend_colors(image.get_pixel(x, y), fill_color))
			elif absf(distance - radius) <= 1.1:
				image.set_pixel(x, y, _blend_colors(image.get_pixel(x, y), outline_color))


func _blend_colors(base: Color, overlay: Color) -> Color:
	var alpha := clampf(overlay.a, 0.0, 1.0)
	return Color(
		lerpf(base.r, overlay.r, alpha),
		lerpf(base.g, overlay.g, alpha),
		lerpf(base.b, overlay.b, alpha),
		1.0
	)


func _rect_changed(previous: Rect2, current: Rect2, epsilon: float = 0.1) -> bool:
	return (
		absf(previous.position.x - current.position.x) > epsilon
		or absf(previous.position.y - current.position.y) > epsilon
		or absf(previous.size.x - current.size.x) > epsilon
		or absf(previous.size.y - current.size.y) > epsilon
	)


func _on_tick_completed(_tick: int, _snapshot: Dictionary) -> void:
	if simulation_manager != null and not simulation_manager.should_refresh_ui_on_tick(_tick):
		return
	if _overview_mode:
		_refresh_pending = true
		return
	request_refresh()


func _on_selection_changed(_agent_id: int) -> void:
	request_refresh()
