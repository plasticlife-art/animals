extends SceneTree

## Windowed worker soak. Defaults enforce the P0 30-minute gate.
## -- style map_size mix output_json [duration_seconds] [seed]
const MIN_DURATION_SECONDS := 1800.0
const WARMUP_FRAMES := 180
const REQUESTED_RESOLUTION := Vector2i(1600, 900)

var main = null
var manager = null
var output_path := "/private/tmp/animals-worker-soak.json"
var settings := {}
var duration_seconds := MIN_DURATION_SECONDS
var seed := 1337
var frames := 0
var started_usec := 0
var next_sample_second := 60.0
var samples: Array = []
var last_sequence := 0
var sequence_regressions := 0
var start_simulation_time := 0.0
var start_resource_count := 0
var start_node_count := 0
var start_orphan_node_count := 0


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	settings = {"style": args[0] if args.size() > 0 else "topdown_kenney",
		"map_size": args[1] if args.size() > 1 else "large",
		"mix": args[2] if args.size() > 2 else "balanced",
		"scenario": "normal", "rules": "normal", "difficulty": "normal"}
	output_path = args[3] if args.size() > 3 else output_path
	duration_seconds = maxf(MIN_DURATION_SECONDS,
		float(args[4]) if args.size() > 4 else MIN_DURATION_SECONDS)
	seed = int(args[5]) if args.size() > 5 else 1337
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
		manager.set_speed_multiplier(1.0)
		main.world_camera.global_position = WorldProjection.to_screen(
			manager.world_state.bounds.get_center())
		main.world_camera.zoom = Vector2.ONE * main.world_camera._zoom_min
		manager.set_lod_view(manager.world_state.bounds,
			manager.world_state.bounds.get_center(), true)
	if manager == null or frames < WARMUP_FRAMES:
		return false
	if started_usec == 0:
		manager.reset_performance_windows()
		started_usec = Time.get_ticks_usec()
		start_simulation_time = manager.simulation_time
		last_sequence = manager._worker_sequence
		start_resource_count = int(Performance.get_monitor(Performance.OBJECT_RESOURCE_COUNT))
		start_node_count = int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT))
		start_orphan_node_count = int(Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT))
		return false
	var elapsed := float(Time.get_ticks_usec() - started_usec) / 1000000.0
	if manager._worker_sequence < last_sequence:
		sequence_regressions += 1
	last_sequence = manager._worker_sequence
	if elapsed >= next_sample_second:
		var counters: Dictionary = manager.world_state.performance_counters
		var lod_counts: Dictionary = manager.world_state.lod_counts
		samples.append({"elapsed_seconds": elapsed, "tick": manager.current_tick,
			"sequence": manager._worker_sequence,
			"worker_in_flight": manager.is_worker_tick_in_flight(),
			"living_count": manager.world_state.get_population_metrics().living_count,
			"lod0_agents": int(lod_counts.get("lod0_agents", 0)),
			"lod1_agents": int(lod_counts.get("lod1_agents", 0)),
			"lod2_agents": int(lod_counts.get("lod2_agents", 0)),
			"dormant_sector_count": manager.world_state.get_dormant_sector_count(),
			"pending_global_paths": int(counters.get("pending_global_paths", 0)),
			"pending_local_paths": int(counters.get("pending_local_paths", 0)),
			"resource_count": int(Performance.get_monitor(Performance.OBJECT_RESOURCE_COUNT)),
			"node_count": int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)),
			"orphan_node_count": int(Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT)),
			"dropped_simulation_seconds": manager.dropped_simulation_seconds,
			"actual_speed": manager.actual_speed})
		next_sample_second += 60.0
		_write_report({"status": "running", "selection": settings,
			"seed": manager.seed, "duration_seconds": duration_seconds,
			"elapsed_seconds": elapsed, "warmup_frames": WARMUP_FRAMES,
			"requested_resolution": [REQUESTED_RESOLUTION.x, REQUESTED_RESOLUTION.y],
			"logical_viewport_resolution": [root.get_visible_rect().size.x,
				root.get_visible_rect().size.y],
			"sequence_regressions": sequence_regressions,
			"latest_sequence": manager._worker_sequence,
			"performance": manager.get_performance_summary(), "samples": samples})
	if elapsed < duration_seconds:
		return false
	manager.synchronize_worker()
	var simulated_seconds: float = manager.simulation_time - start_simulation_time
	var measured_actual_speed := simulated_seconds / maxf(0.000001, elapsed)
	var tail_start_dropped := 0.0
	for sample in samples:
		if float(sample.elapsed_seconds) >= elapsed - 600.0:
			tail_start_dropped = float(sample.dropped_simulation_seconds)
			break
	var dropped_tail_growth: float = manager.dropped_simulation_seconds - tail_start_dropped
	var tail_start_global_paths := 0
	var tail_start_local_paths := 0
	var tail_start_resources := start_resource_count
	var tail_start_nodes := start_node_count
	var tail_start_orphans := start_orphan_node_count
	for sample in samples:
		if float(sample.elapsed_seconds) >= elapsed - 600.0:
			tail_start_global_paths = int(sample.pending_global_paths)
			tail_start_local_paths = int(sample.pending_local_paths)
			tail_start_resources = int(sample.resource_count)
			tail_start_nodes = int(sample.node_count)
			tail_start_orphans = int(sample.orphan_node_count)
			break
	var final_counters: Dictionary = manager.world_state.performance_counters
	var final_global_paths := int(final_counters.get("pending_global_paths", 0))
	var final_local_paths := int(final_counters.get("pending_local_paths", 0))
	var final_resources := int(Performance.get_monitor(Performance.OBJECT_RESOURCE_COUNT))
	var final_nodes := int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT))
	var final_orphans := int(Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT))
	var report := {"status": "complete", "selection": settings, "seed": manager.seed,
		"duration_seconds": elapsed, "warmup_frames": WARMUP_FRAMES,
		"requested_resolution": [REQUESTED_RESOLUTION.x, REQUESTED_RESOLUTION.y],
		"logical_viewport_resolution": [root.get_visible_rect().size.x,
			root.get_visible_rect().size.y],
		"window_resolution": [DisplayServer.window_get_size().x,
			DisplayServer.window_get_size().y],
		"simulated_seconds": simulated_seconds,
		"measured_actual_speed": measured_actual_speed,
		"dropped_tail_growth_seconds": dropped_tail_growth,
		"pending_global_path_tail_growth": final_global_paths - tail_start_global_paths,
		"pending_local_path_tail_growth": final_local_paths - tail_start_local_paths,
		"resource_count_tail_growth": final_resources - tail_start_resources,
		"node_count_tail_growth": final_nodes - tail_start_nodes,
		"orphan_node_count_tail_growth": final_orphans - tail_start_orphans,
		"sequence_regressions": sequence_regressions,
		"final_sequence": manager._worker_sequence,
		"worker_in_flight_after_sync": manager.is_worker_tick_in_flight(),
		"performance": manager.get_performance_summary(), "samples": samples,
		"accepted": measured_actual_speed >= 0.98 and sequence_regressions == 0
			and dropped_tail_growth <= manager.tick_duration
			and final_global_paths <= tail_start_global_paths
			and final_local_paths <= tail_start_local_paths
			and final_resources <= tail_start_resources
			and final_nodes <= tail_start_nodes
			and final_orphans <= tail_start_orphans}
	_write_report(report)
	print("WORKER_SOAK=" + JSON.stringify(report))
	manager.shutdown()
	return true


func _write_report(report: Dictionary) -> void:
	DirAccess.make_dir_recursive_absolute(output_path.get_base_dir())
	var temporary_path := output_path + ".tmp"
	var file := FileAccess.open(temporary_path, FileAccess.WRITE)
	if file == null:
		push_error("Could not write worker soak report: %s" % temporary_path)
		return
	file.store_string(JSON.stringify(report, "\t"))
	file.close()
	var rename_error := DirAccess.rename_absolute(temporary_path, output_path)
	if rename_error != OK:
		push_error("Could not publish worker soak report: %s" % error_string(rename_error))
