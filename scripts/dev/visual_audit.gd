extends SceneTree

## Windowed performance benchmark.
## -- style map_size mix speed output_directory [measured_frames_per_view] [seed]
const WARMUP_FRAMES := 180
const MIN_MEASURED_FRAMES := 720
const REQUESTED_RESOLUTION := Vector2i(1600, 900)

var main = null
var manager = null
var frames := 0
var stage_frame := 0
var stage := "startup"
var settings := {}
var output := "/private/tmp"
var measured_frames := MIN_MEASURED_FRAMES
var speed := 1.0
var seed := 1337
var focus := Vector2.ZERO
var results: Array = []
var stage_started_usec: int = 0
var stage_start_simulation_time: float = 0.0


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	settings = {"style": args[0] if args.size() > 0 else "topdown_kenney",
		"map_size": args[1] if args.size() > 1 else "large",
		"mix": args[2] if args.size() > 2 else "balanced",
		"scenario": "normal", "rules": "normal", "difficulty": "normal"}
	speed = float(args[3]) if args.size() > 3 else 1.0
	output = args[4] if args.size() > 4 else "/private/tmp"
	measured_frames = maxi(MIN_MEASURED_FRAMES, int(args[5]) if args.size() > 5 else MIN_MEASURED_FRAMES)
	seed = int(args[6]) if args.size() > 6 else 1337
	DirAccess.make_dir_recursive_absolute(output)
	DisplayServer.window_set_size(REQUESTED_RESOLUTION)
	main = load("res://scenes/main/main.tscn").instantiate()
	root.add_child(main)


func _process(_delta: float) -> bool:
	frames += 1
	if frames == 2:
		main._selection = settings
		main._start_simulation(settings, seed)
		main._autosave_interval = 0
		manager = main.simulation_manager
		manager.set_speed_multiplier(speed)
		var animals: Array = manager.world_state.get_living_agents()
		focus = animals[0].position if not animals.is_empty() else manager.world_state.bounds.get_center()
		main.world_camera.global_position = WorldProjection.to_screen(focus,
			manager.world_state.terrain_system.get_height_at_position(focus))
		main.world_camera.zoom = Vector2.ONE * 0.8
		stage = "warmup"
		stage_frame = 0
	if manager == null:
		return false

	stage_frame += 1
	match stage:
		"warmup":
			if stage_frame >= WARMUP_FRAMES:
				_begin_stage("herd")
		"herd":
			if stage_frame >= measured_frames:
				_finish_stage("herd", true)
				_begin_stage("pan")
		"pan":
			main.world_camera.global_position += Vector2(1.5, 0.6)
			if stage_frame >= measured_frames:
				_finish_stage("pan", false)
				main.world_camera.global_position = WorldProjection.to_screen(manager.world_state.bounds.get_center())
				main.world_camera.zoom = Vector2.ONE * main.world_camera._zoom_min
				_begin_stage("overview")
		"overview":
			if stage_frame >= measured_frames:
				_finish_stage("overview", true)
				_write_report()
				manager.shutdown()
				return true
	return false


func _begin_stage(next_stage: String) -> void:
	manager.synchronize_worker()
	stage = next_stage
	stage_frame = 0
	manager.reset_performance_windows()
	stage_started_usec = Time.get_ticks_usec()
	stage_start_simulation_time = manager.simulation_time


func _finish_stage(name: String, screenshot: bool) -> void:
	manager.synchronize_worker()
	var elapsed_seconds := maxf(0.000001,
		float(Time.get_ticks_usec() - stage_started_usec) / 1000000.0)
	var simulated_seconds: float = manager.simulation_time - stage_start_simulation_time
	var result := {"view": name, "measured_frames": stage_frame,
		"camera_zoom": main.world_camera.zoom.x,
		"visible_world_fraction": _visible_fraction(),
		"elapsed_seconds": elapsed_seconds,
		"simulated_seconds": simulated_seconds,
		"measured_actual_speed": simulated_seconds / elapsed_seconds,
		"performance": manager.get_performance_summary()}
	if screenshot:
		var image := root.get_texture().get_image()
		result["screenshot_resolution"] = [image.get_width(), image.get_height()]
		image.save_png("%s/%s.png" % [output, name])
	results.append(result)


func _visible_fraction() -> float:
	var bounds: Rect2 = manager.world_state.bounds
	return WorldProjection.visible_world_fraction(
		main.world_camera.get_visible_screen_rect(), bounds)


func _write_report() -> void:
	var window_size := DisplayServer.window_get_size()
	var viewport_size := root.get_visible_rect().size
	var content_scale_size := root.content_scale_size
	var report := {"selection": settings, "seed": manager.seed,
		"requested_resolution": [REQUESTED_RESOLUTION.x, REQUESTED_RESOLUTION.y],
		"logical_viewport_resolution": [viewport_size.x, viewport_size.y],
		"window_resolution": [window_size.x, window_size.y],
		"content_scale_resolution": [content_scale_size.x, content_scale_size.y],
		"speed": speed,
		"lod_enabled": manager.lod_enabled, "warmup_frames": WARMUP_FRAMES,
		"measured_frames_per_view": measured_frames,
		"tick_rate": manager.tick_rate,
		"world_size": [manager.world_state.bounds.size.x, manager.world_state.bounds.size.y],
		"overview_lod": manager.config_bundle.get("visuals", {}).get("overview_lod", {}).duplicate(true),
		"results": results}
	var file := FileAccess.open(output + "/performance.json", FileAccess.WRITE)
	file.store_string(JSON.stringify(report, "\t"))
	file.close()
	print("VISUAL=" + JSON.stringify(report))
