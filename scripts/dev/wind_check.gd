extends SceneTree

# The wind in a window: the default world paused, the camera on trees, two frames half a second
# apart. Animals stand still while paused; whatever moved between the frames is the wind.
#
#   Godot --path . --script res://scripts/dev/wind_check.gd -- <out_prefix> [zoom]

var _main: Node = null
var _frames := 0
var _prefix := ""
var _zoom := 1.4
var _shot_at := 0


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	_prefix = args[0] if not args.is_empty() else "user://wind"
	if args.size() > 1:
		_zoom = float(args[1])
	root.size = Vector2i(1600, 900)
	_main = load("res://scenes/main/main.tscn").instantiate()
	root.add_child(_main)


func _process(_delta: float) -> bool:
	_frames += 1
	if _frames == 10:
		_main.get_node("CanvasLayer/StartMenu").start_requested.emit(ConfigLoader.default_selection())
	if _frames == 120:
		var manager = _main.simulation_manager
		manager.set_paused(true)
		var camera = _main.world_camera
		var target: Vector2 = manager.world_state.bounds.get_center()
		# The tallest props nearby, so there is something to sway.
		for entry in manager.world_state.scenery.query_rect(Rect2(target - Vector2(1500, 1500), Vector2(3000, 3000))):
			if str(entry.kind) == "tree_large":
				target = entry.position
				break
		camera.global_position = WorldProjection.to_screen(target)
		camera.zoom = Vector2(_zoom, _zoom)
		_main.get_node("CanvasLayer").visible = false
		DisplayServer.window_move_to_foreground()
	if _frames == 300:
		root.get_texture().get_image().save_png(_prefix + "-a.png")
		_shot_at = Time.get_ticks_msec()
	if _shot_at > 0 and Time.get_ticks_msec() - _shot_at >= 600:
		root.get_texture().get_image().save_png(_prefix + "-b.png")
		print("WIND_CHECK saved")
		return true
	return false
