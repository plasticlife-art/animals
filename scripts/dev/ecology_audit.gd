extends SceneTree

## Deterministic ecology run for the default preset.
##
## Godot --headless --path <project> --script res://scripts/dev/ecology_audit.gd \
##   -- seed lod|off seconds [output.json]
##
## LOD is configured on SimulationManager, not by mutating debug.json after the
## manager has initialized. Keeping that distinction here matters: the old audit
## labelled runs as LOD while actually simulating every animal at LOD0.
const SAMPLE_SECONDS := 60.0
const PRIMARY_SPECIES := ["herbivore", "predator"]


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var run_seed := int(args[0]) if args.size() > 0 else 3
	var use_lod := args.size() > 1 and str(args[1]).to_lower() == "lod"
	var requested_seconds := float(args[2]) if args.size() > 2 else 1440.0
	var output_path := str(args[3]) if args.size() > 3 else ""
	var selection := ConfigLoader.default_selection()
	var bundle := ConfigLoader.load_config_bundle(selection)
	var manager = preload("res://scripts/core/simulation_manager.gd").new()
	manager.initialize(bundle, run_seed)
	manager.set_lod_enabled(use_lod)
	if use_lod:
		var center: Vector2 = manager.world_state.bounds.get_center()
		manager.set_lod_view(Rect2(center - Vector2.ONE * 0.5, Vector2.ONE), center, true)

	var species_ids: Array = manager.world_state.species_registry.ids()
	var initial_population: Dictionary = manager.world_state.get_population_metrics()
	var history: Array = []
	var population_min: Dictionary = {}
	var population_max: Dictionary = {}
	var risk_animal_seconds: Dictionary = {}
	for species_id in species_ids:
		var count := int(initial_population.get("%s_count" % species_id, 0))
		population_min[species_id] = count
		population_max[species_id] = count
		risk_animal_seconds[species_id] = 0.0

	var total_ticks := int(ceil(requested_seconds * manager.tick_rate))
	var sample_ticks := maxi(1, int(round(SAMPLE_SECONDS * manager.tick_rate)))
	var tick_times: Array[float] = []
	var started := Time.get_ticks_usec()
	var stop_reason := "duration"
	for tick in total_ticks:
		var tick_started := Time.get_ticks_usec()
		manager.step_once()
		tick_times.append(float(Time.get_ticks_usec() - tick_started) / 1000.0)
		var population: Dictionary = manager.world_state.get_population_metrics()
		for species_id in species_ids:
			var count := int(population.get("%s_count" % species_id, 0))
			population_min[species_id] = mini(int(population_min[species_id]), count)
			population_max[species_id] = maxi(int(population_max[species_id]), count)
			risk_animal_seconds[species_id] = float(risk_animal_seconds[species_id]) \
				+ float(population.get("starvation_risk_%s_count" % species_id, 0)) * manager.tick_duration
		if tick == 0 or (tick + 1) % sample_ticks == 0 or tick + 1 == total_ticks:
			history.append(_history_row(manager, population, species_ids))
		if _food_chain_broken(population):
			stop_reason = "food_chain_broken"
			break

	var final_population: Dictionary = manager.world_state.get_population_metrics()
	var counters: Dictionary = manager.stats_system.counters.duplicate(true)
	var capacities := {}
	for species_id in species_ids:
		capacities[species_id] = manager.world_state.get_reproductive_capacity(species_id)
	var report := {
		"schema_version": 2,
		"selection": selection,
		"seed": run_seed,
		"lod": use_lod,
		"requested_seconds": requested_seconds,
		"simulated_seconds": manager.simulation_time,
		"stop_reason": stop_reason,
		"wall_seconds": (Time.get_ticks_usec() - started) / 1000000.0,
		"tick_ms": _timing_summary(tick_times),
		"initial_population": _population_counts(initial_population, species_ids),
		"population": _population_counts(final_population, species_ids),
		"population_min": population_min,
		"population_max": population_max,
		"reproductive_capacity": capacities,
		"starvation_risk_animal_seconds": risk_animal_seconds,
		"counters": counters,
		"outcome": _outcome(initial_population, final_population, counters, species_ids),
		"history": history,
		"formation": _formation_over_run(history),
		"lod_counts": manager.world_state.get_lod_counts(),
		"performance_counters": manager.world_state.get_performance_counters(),
	}
	var encoded := JSON.stringify(report, "  ")
	print("AUDIT=" + JSON.stringify(report))
	if output_path != "":
		var file := FileAccess.open(output_path, FileAccess.WRITE)
		if file == null:
			push_error("Could not write ecology report: %s" % output_path)
			manager.shutdown()
			manager.free()
			quit(2)
			return
		file.store_string(encoded + "\n")
	manager.shutdown()
	manager.free()
	quit()


func _food_chain_broken(population: Dictionary) -> bool:
	for species_id in PRIMARY_SPECIES:
		if int(population.get("%s_count" % species_id, 0)) <= 0:
			return true
	return false


func _population_counts(population: Dictionary, species_ids: Array) -> Dictionary:
	var result := {}
	for species_id in species_ids:
		result[species_id] = int(population.get("%s_count" % species_id, 0))
	return result


func _history_row(manager, population: Dictionary, species_ids: Array) -> Dictionary:
	var row := {"time": snappedf(manager.simulation_time, 0.1)}
	for species_id in species_ids:
		row[species_id] = int(population.get("%s_count" % species_id, 0))
		row["%s_starvation_risk" % species_id] = int(population.get(
			"starvation_risk_%s_count" % species_id, 0))
	row["grass_biomass"] = manager.world_state.resource_system.get_total_biomass()
	row["carcass_meat"] = manager.world_state.get_total_carcass_meat_remaining()
	row["formation"] = _formation(manager)
	return row


## The shape of herbivore herds, sleeping and awake, measured apart. `nn` is the mean
## distance from each animal to its nearest herd-mate and `radius` the mean distance to
## its group's centre, each the median over groups of three or more. A sleeping herd
## packed onto a ring shows as a small `nn`; one smeared out by drift as a large
## `radius`. The live figures are the reference the sleeping ones should resemble.
func _formation(manager) -> Dictionary:
	var world = manager.world_state
	var dormant_groups: Array = []
	for sector_state in world._sector_states.values():
		if not bool(sector_state.get("dormant", false)):
			continue
		var buckets: Dictionary = {}
		for record in sector_state.get("dormant_records", []):
			var group_id := int(record.get("group_id", -1))
			if str(record.get("species_type", "")) != "herbivore" or group_id < 0:
				continue
			if not buckets.has(group_id):
				buckets[group_id] = []
			buckets[group_id].append(Vector2(record.get("position", Vector2.ZERO)))
		dormant_groups.append_array(buckets.values())
	var live_buckets: Dictionary = {}
	for agent in world.get_living_agents():
		if agent.species_type != "herbivore" or agent.group_id < 0:
			continue
		if not live_buckets.has(agent.group_id):
			live_buckets[agent.group_id] = []
		live_buckets[agent.group_id].append(agent.position)
	return {"dormant": _shape_of(dormant_groups), "live": _shape_of(live_buckets.values())}


func _shape_of(groups: Array) -> Dictionary:
	var radii: Array = []
	var nearest: Array = []
	for positions in groups:
		if positions.size() < 3:
			continue
		var center := Vector2.ZERO
		for position in positions:
			center += position
		center /= float(positions.size())
		var radius_sum := 0.0
		var nearest_sum := 0.0
		for i in range(positions.size()):
			radius_sum += positions[i].distance_to(center)
			var closest := INF
			for j in range(positions.size()):
				if i != j:
					closest = minf(closest, positions[i].distance_to(positions[j]))
			nearest_sum += closest
		radii.append(radius_sum / float(positions.size()))
		nearest.append(nearest_sum / float(positions.size()))
	return {"groups": radii.size(), "radius": _median(radii), "nn": _median(nearest)}


func _formation_over_run(history: Array) -> Dictionary:
	var summary := {}
	for state in ["dormant", "live"]:
		for measure in ["radius", "nn"]:
			var values: Array = []
			for row in history:
				var shape: Dictionary = row.get("formation", {}).get(state, {})
				if int(shape.get("groups", 0)) > 0:
					values.append(float(shape.get(measure, 0.0)))
			summary["%s_%s_median" % [state, measure]] = _median(values)
	return summary


func _median(values: Array) -> float:
	if values.is_empty():
		return 0.0
	var sorted := values.duplicate()
	sorted.sort()
	return float(sorted[sorted.size() / 2])


func _outcome(initial_population: Dictionary, final_population: Dictionary,
		counters: Dictionary, species_ids: Array) -> Dictionary:
	var result := {}
	for species_id in species_ids:
		var initial := int(initial_population.get("%s_count" % species_id, 0))
		var final := int(final_population.get("%s_count" % species_id, 0))
		result[species_id] = {
			"survived": final > 0,
			"reproduced": int(counters.get("births_%s" % species_id, 0)) > 0,
			"growth_ratio": float(final) / maxf(1.0, float(initial)),
		}
	return result


func _timing_summary(samples: Array[float]) -> Dictionary:
	if samples.is_empty():
		return {"count": 0, "p50": 0.0, "p95": 0.0, "p99": 0.0, "max": 0.0}
	var sorted := samples.duplicate()
	sorted.sort()
	return {
		"count": sorted.size(),
		"p50": _percentile(sorted, 0.50),
		"p95": _percentile(sorted, 0.95),
		"p99": _percentile(sorted, 0.99),
		"max": float(sorted[-1]),
	}


func _percentile(sorted: Array, percentile: float) -> float:
	var index := clampi(int(ceil(percentile * float(sorted.size()))) - 1, 0, sorted.size() - 1)
	return float(sorted[index])
