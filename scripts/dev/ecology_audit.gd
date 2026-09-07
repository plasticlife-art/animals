extends SceneTree

## Godot --headless --script res://scripts/dev/ecology_audit.gd -- seed lod|off seconds
func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var run_seed := int(args[0]) if args.size() > 0 else 3
	var use_lod := args.size() > 1 and args[1] == "lod"
	var seconds := float(args[2]) if args.size() > 2 else 1440.0
	var manager = preload("res://scripts/core/simulation_manager.gd").new()
	var bundle := ConfigLoader.load_config_bundle()
	bundle.debug.lod.enabled = use_lod
	manager.initialize(bundle, run_seed)
	var started := Time.get_ticks_usec()
	var history: Array = []
	for tick in int(seconds * manager.tick_rate):
		manager.step_once()
		if tick % int(manager.tick_rate * 60) == 0:
			var population: Dictionary = manager.world_state.get_population_metrics()
			var row := {"time": snappedf(manager.simulation_time, 0.1)}
			for species_id in manager.world_state.species_registry.ids():
				row[species_id] = population.get("%s_count" % species_id, 0)
			history.append(row)
			print(JSON.stringify(row))
			# Stop when the food chain has actually broken, not when any one species
			# is gone: a scavenger dying out is a result worth watching the rest of.
			if int(population.get("herbivore_count", 0)) == 0 or int(population.get("predator_count", 0)) == 0:
				break
	var snapshot: Dictionary = manager.world_state.get_population_metrics()
	print("AUDIT=" + JSON.stringify({"seed": run_seed, "lod": use_lod, "seconds": manager.simulation_time,
		"population": snapshot, "counters": manager.stats_system.counters, "history": history,
		"wall_seconds": (Time.get_ticks_usec() - started) / 1000000.0}))
	manager.shutdown()
	manager.free()
	quit()
