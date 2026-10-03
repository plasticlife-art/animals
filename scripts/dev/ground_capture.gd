extends SceneTree

# Screenshot harness for the ground layer. Not part of the game.
#
#   Godot --path . --script res://scripts/dev/ground_capture.gd -- <out_prefix> [sim_seconds] [style] [variants.json]
# Runs the real main scene at top speed until `sim_seconds` have passed, so herds have
# had time to graze pastures down and wear paths, then writes `<prefix>-map.png` with
# the whole map in frame, `<prefix>-mid.png` at play distance and `<prefix>-close.png`
# up close, both on the most worn ground, and `<prefix>-pond.png` up close on the
# watering hole nearest it.
#
# `variants.json` maps a name to a patch of `visuals.ground` keys. Each variant is put on
# the ground layer in turn and shot from the same three views, as `<prefix>-<name>-<view>.png`,
# so colours can be compared on one world instead of one twenty-minute run each.

var _frames := 0
var _main: Node = null
var _manager = null
var _camera = null
var _prefix := "user://ground"
var _seconds := 600.0
var _style := ""
var _variants_path := ""
var _stage := 0
var _stage_started_msec := 0
var _shots: Array = []
var _shot: Dictionary = {}


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		_prefix = args[0]
	if args.size() > 1:
		_seconds = float(args[1])
	if args.size() > 2:
		_style = args[2]
	if args.size() > 3:
		_variants_path = args[3]
	root.size = Vector2i(1600, 900)
	_main = load("res://scenes/main/main.tscn").instantiate()
	root.add_child(_main)


func _process(_delta: float) -> bool:
	_frames += 1
	if _frames == 10:
		var menu = _main.get_node_or_null("CanvasLayer/StartMenu")
		if menu != null and menu.visible:
			var selection: Dictionary = ConfigLoader.default_selection()
			if _style != "":
				selection["style"] = _style
			menu.start_requested.emit(selection)
	if _frames < 30:
		return false
	if _manager == null:
		_manager = _main.get_node("SimulationManager")
		_camera = _main.get_node("GameCamera")
		_manager.speed_multiplier = 64.0
		# Daylight, so the colours in the picture are the colours of the layer; and a
		# close camera while time runs, so the far sectors sleep and the run is quick.
		_main.get_node("DayNightTint").visible = false
		_aim(_manager.world_state.bounds.get_center(), 1.0)
	match _stage:
		0:
			if _frames % 600 == 0:
				print("t=%.0f" % _manager.simulation_time)
			if _manager.simulation_time >= _seconds:
				_manager.speed_multiplier = 0.0
				_queue_shots()
				_next_stage()
		1:
			if _shot.is_empty():
				if _shots.is_empty():
					return true
				_shot = _shots.pop_front()
				if _shot.has("variant"):
					# On top of the shipped settings, so one variant's keys never leak into the next.
					var ground: Dictionary = _manager.config_bundle.get("visuals", {}).get("ground", {}).duplicate()
					ground.merge(_shot["variant"], true)
					_main.get_node("GroundTraces")._apply_config(ground)
				_aim(_shot["position"], _shot["zoom"])
				_next_stage()
				_stage = 1
			elif _settled():
				_save(_shot["name"])
				_shot = {}
	return false


## Every view of every variant, taken on a paused world so they show the same ground.
func _queue_shots() -> void:
	var views := [
		["map", _manager.world_state.bounds.get_center(), _map_zoom()],
		["mid", _most_worn_position(), 0.2],
		["close", _most_worn_position(), 0.45],
		["pond", _pond_nearest(_most_worn_position()), 0.45],
	]
	var variants := {"": {}}
	if _variants_path != "":
		var parsed = JSON.parse_string(FileAccess.get_file_as_string(_variants_path))
		if parsed is Dictionary and not parsed.is_empty():
			variants = parsed
	for variant_name in variants.keys():
		for view in views:
			var shot := {"name": view[0] if variant_name == "" else "%s-%s" % [variant_name, view[0]],
				"position": view[1], "zoom": view[2]}
			if variant_name != "":
				shot["variant"] = variants[variant_name]
			_shots.append(shot)


func _next_stage() -> void:
	_stage += 1
	# macOS stops presenting a window that sits behind others, and the picture saved
	# is then the last frame it drew, minutes old.
	DisplayServer.window_move_to_foreground()
	_stage_started_msec = Time.get_ticks_msec()


## Wall-clock, not frames: without vsync a hundred frames pass before the window has
## drawn one, and the picture saved is the view from before the camera moved.
func _settled() -> bool:
	return Time.get_ticks_msec() - _stage_started_msec > 3000


func _save(name: String) -> void:
	var path := "%s-%s.png" % [_prefix, name]
	root.get_texture().get_image().save_png(path)
	print("saved %s at t=%.0f zoom=%s camera=%s" % [path, _manager.simulation_time, _camera.zoom, _camera.global_position])


func _map_zoom() -> float:
	var bounds: Rect2 = _manager.world_state.bounds
	var corners := [bounds.position, Vector2(bounds.end.x, bounds.position.y), bounds.end, Vector2(bounds.position.x, bounds.end.y)]
	var screen := Rect2(WorldProjection.to_screen(corners[0]), Vector2.ZERO)
	for corner in corners:
		screen = screen.expand(WorldProjection.to_screen(corner))
	var view: Vector2 = root.get_visible_rect().size
	return minf(view.x / screen.size.x, view.y / screen.size.y) * 0.97


func _aim(world_position: Vector2, zoom: float) -> void:
	var terrain = _manager.world_state.terrain_system
	var level: int = 0 if terrain == null else terrain.get_height_at_position(world_position)
	_camera.global_position = WorldProjection.to_screen(world_position, level)
	_camera.zoom = Vector2(zoom, zoom)
	_camera.force_update_scroll()


## The watering hole nearest `position`, where the animals that wore the ground drink.
func _pond_nearest(position: Vector2) -> Vector2:
	var best := position
	var best_distance := INF
	for source in _manager.world_state.water_sources:
		var distance: float = position.distance_to(source["position"])
		if distance < best_distance:
			best_distance = distance
			best = source["position"]
	return best


func _most_worn_position() -> Vector2:
	var field = _manager.world_state.trail_field
	var cells: PackedFloat32Array = field.export_cells()
	var best := 0
	for index in range(cells.size()):
		if cells[index] > cells[best]:
			best = index
	@warning_ignore("integer_division")
	return (Vector2(best % field.cols, best / field.cols) + Vector2(0.5, 0.5)) * field.cell_size
