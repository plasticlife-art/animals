extends SceneTree

## Actual window benchmark. No autosaves; all artifacts go to the supplied directory.
## -- style map_size mix speed output_directory [frames]
var main = null
var manager = null
var frames := 0
var settings := {}
var output := "/private/tmp"
var total_frames := 720
var speed := 1.0
var focus := Vector2.ZERO
var results: Array = []

func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	settings = {"style": args[0] if args.size() > 0 else "topdown_kenney",
		"map_size": args[1] if args.size() > 1 else "large",
		"mix": args[2] if args.size() > 2 else "balanced"}
	speed = float(args[3]) if args.size() > 3 else 1.0
	output = args[4] if args.size() > 4 else "/private/tmp"
	total_frames = int(args[5]) if args.size() > 5 else 720
	root.size = Vector2i(1600, 900)
	main = load("res://scenes/main/main.tscn").instantiate()
	root.add_child(main)

func _process(_delta: float) -> bool:
	frames += 1
	if frames == 2:
		main.start_menu.start_requested.emit(settings)
		main._autosave_interval = 0
		manager = main.simulation_manager
		manager.set_speed_multiplier(speed)
		var animals: Array = manager.world_state.get_living_agents()
		focus = animals[0].position if not animals.is_empty() else manager.world_state.bounds.get_center()
		main.world_camera.global_position = WorldProjection.to_screen(focus, manager.world_state.terrain_system.get_height_at_position(focus))
		main.world_camera.zoom = Vector2.ONE * 0.8
	if manager == null:
		return false
	if frames == 180:
		manager.frame_times.samples.clear()
		manager.tick_times.samples.clear()
		manager.render_times.samples.clear()
	if frames == 360:
		results.append({"view": "herd", "performance": manager.get_performance_summary()})
		root.get_texture().get_image().save_png(output + "/herd.png")
		manager.frame_times.samples.clear()
		manager.tick_times.samples.clear()
		manager.render_times.samples.clear()
	if frames > 360 and frames <= 540:
		main.world_camera.global_position += Vector2(1.5, 0.6)
	if frames == 540:
		results.append({"view": "pan", "performance": manager.get_performance_summary()})
		manager.frame_times.samples.clear()
		manager.tick_times.samples.clear()
		manager.render_times.samples.clear()
		main.world_camera.global_position = WorldProjection.to_screen(manager.world_state.bounds.get_center())
		main.world_camera.zoom = Vector2.ONE * main.world_camera._zoom_min
	if frames >= total_frames:
		results.append({"view": "overview", "performance": manager.get_performance_summary()})
		root.get_texture().get_image().save_png(output + "/overview.png")
		var report := {"selection": settings, "speed": speed, "results": results}
		var file := FileAccess.open(output + "/performance.json", FileAccess.WRITE)
		file.store_string(JSON.stringify(report, "\t"))
		file.close()
		print("VISUAL=" + JSON.stringify(report))
		manager.shutdown()
		return true
	return false
