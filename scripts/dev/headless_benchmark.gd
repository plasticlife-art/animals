extends SceneTree

## Headless benchmark using the same preset bundle as the setup screen.
## -- style map_size mix lod_on output_json [warmup_ticks] [measured_ticks] [seed]
const ConfigLoaderScript := preload("res://scripts/core/config_loader.gd")
const SimulationManagerScript := preload("res://scripts/core/simulation_manager.gd")
const PerformanceWindowScript := preload("res://scripts/stats/performance_window.gd")

const MIN_WARMUP_TICKS := 90
const MIN_MEASURED_TICKS := 600


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var args := OS.get_cmdline_user_args()
	var selection := {"style": args[0] if args.size() > 0 else "topdown_kenney",
		"map_size": args[1] if args.size() > 1 else "large",
		"mix": args[2] if args.size() > 2 else "balanced",
		"scenario": "normal", "rules": "normal", "difficulty": "normal"}
	var lod_on := str(args[3] if args.size() > 3 else "true").to_lower() in ["1", "true", "on", "yes"]
	var output_path := args[4] if args.size() > 4 else "/private/tmp/animals-headless-performance.json"
	var warmup := maxi(MIN_WARMUP_TICKS, int(args[5]) if args.size() > 5 else MIN_WARMUP_TICKS)
	var measured := maxi(MIN_MEASURED_TICKS, int(args[6]) if args.size() > 6 else MIN_MEASURED_TICKS)
	var seed := int(args[7]) if args.size() > 7 else 1337
	var manager = SimulationManagerScript.new()
	manager.initialize(ConfigLoaderScript.load_config_bundle(selection), seed)
	manager.lod_enabled = lod_on
	# With no camera, the LOD run represents the same whole-map overview used by
	# the interactive acceptance case: a point-sized detailed focus at the world
	# centre, followed by the configured near/mid sector rings. LOD-off remains
	# the full-fidelity control for the exact same world and seed.
	manager.overview_mode = lod_on
	manager.lod_focus_center = manager.world_state.bounds.get_center()
	for _tick in warmup:
		manager.step_once()
	manager.reset_performance_windows()
	var timings = PerformanceWindowScript.new()
	timings.capacity = measured
	var phase_timings: Dictionary = {}
	var worst_ticks: Array = []
	var first_global_queue := -1
	var first_local_queue := -1
	var last_global_queue := 0
	var last_local_queue := 0
	var max_global_queue := 0
	var max_local_queue := 0
	var started := Time.get_ticks_usec()
	for _tick in measured:
		var tick_started := Time.get_ticks_usec()
		manager.step_once()
		var tick_ms := float(Time.get_ticks_usec() - tick_started) / 1000.0
		timings.add(tick_ms)
		var phases: Dictionary = manager.world_state.get_performance_counters()
		last_global_queue = int(phases.get("pending_global_paths", 0))
		last_local_queue = int(phases.get("pending_local_paths", 0))
		if first_global_queue < 0:
			first_global_queue = last_global_queue
			first_local_queue = last_local_queue
		max_global_queue = maxi(max_global_queue, last_global_queue)
		max_local_queue = maxi(max_local_queue, last_local_queue)
		for key in phases:
			if not str(key).ends_with("_ms"):
				continue
			if not phase_timings.has(key):
				phase_timings[key] = PerformanceWindowScript.new()
			phase_timings[key].add(float(phases[key]))
		worst_ticks.append({"tick": manager.current_tick, "tick_ms": tick_ms,
			"phases": phases.duplicate()})
		worst_ticks.sort_custom(func(a, b): return float(a.tick_ms) > float(b.tick_ms))
		if worst_ticks.size() > 10:
			worst_ticks.resize(10)
	var elapsed_seconds := float(Time.get_ticks_usec() - started) / 1000000.0
	var simulated_seconds: float = float(measured) * manager.tick_duration
	var phase_summary := {}
	for key in phase_timings:
		phase_summary[key] = phase_timings[key].summary()
	var report := {"selection": selection, "seed": seed, "lod_enabled": lod_on,
		"view_mode": "overview" if lod_on else "full_fidelity",
		"warmup_ticks": warmup, "measured_ticks": measured,
		"tick_rate": manager.tick_rate,
		"world_size": [manager.world_state.bounds.size.x, manager.world_state.bounds.size.y],
		"population": manager.world_state.get_population_metrics(),
		"lod_counts": manager.world_state.lod_counts.duplicate(),
		"tick_ms": timings.summary(),
		"tick_phases_ms": phase_summary, "worst_ticks": worst_ticks,
		"navigation_queues": {"global_first": first_global_queue,
			"global_last": last_global_queue, "global_max": max_global_queue,
			"local_first": first_local_queue, "local_last": last_local_queue,
			"local_max": max_local_queue},
		"actual_speed_capacity": simulated_seconds / maxf(0.000001, elapsed_seconds),
		"elapsed_seconds": elapsed_seconds,
		"last_tick_phases": manager.world_state.get_performance_counters()}
	DirAccess.make_dir_recursive_absolute(output_path.get_base_dir())
	var file := FileAccess.open(output_path, FileAccess.WRITE)
	file.store_string(JSON.stringify(report, "\t"))
	file.close()
	print("HEADLESS_BENCHMARK=" + JSON.stringify(report))
	manager.shutdown()
	manager.free()
	quit()
