extends SceneTree

# What herbivores were doing when they starved. Not part of the game.
#
#   Godot --headless --path . --script res://scripts/dev/hunger_probe.gd -- <seed> <seconds> <out.json> [a.b.c=value ...]
# Runs at full fidelity and samples every herbivore every SAMPLE seconds: hunger,
# thirst, energy, action and state, grass under it and within 150 units, fear, and its
# grass target with what that target still holds. The last HISTORY samples of each
# animal are kept, and written out for every one that vanished while starving, so the
# lead-up to each starvation death can be read back. `bands` sums the same fields by
# hunger band over all samples. This is what found grazers nibbling stubble crumbs and
# animals frozen a hair inside a bush (see the Herbivore section of ARCHITECTURE.md).
const SAMPLE := 2.0
const HISTORY := 16

func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var run_seed := int(args[0])
	var seconds := float(args[1])
	var out := str(args[2])
	var bundle: Dictionary = ConfigLoader.load_config_bundle()
	for index in range(3, args.size()):
		var pair := str(args[index]).split("=", true, 1)
		var keys := pair[0].split(".")
		var node: Dictionary = bundle
		for k in range(keys.size() - 1):
			node = node[keys[k]]
		node[keys[keys.size() - 1]] = float(pair[1]) if pair[1].is_valid_float() else (pair[1] == "true" if pair[1] in ["true", "false"] else pair[1])
	var manager = preload("res://scripts/core/simulation_manager.gd").new()
	manager.initialize(bundle, run_seed)
	manager.set_lod_enabled(false)
	var world = manager.world_state
	var res = world.resource_system
	var bite := float(bundle.species.herbivore.feeding.bite_amount)
	var sample_ticks := int(round(SAMPLE * manager.tick_rate))
	var histories := {}
	var last_hunger := {}
	var bands := {}
	var deaths: Array = []
	var total_ticks := int(ceil(seconds * manager.tick_rate))
	var death_counter_before := 0
	for tick in range(total_ticks):
		manager.step_once()
		if tick % sample_ticks != 0:
			continue
		var alive := {}
		for agent in world.living_agents:
			if agent == null or not agent.is_alive or agent.species_type != "herbivore":
				continue
			alive[agent.id] = true
			var cell: int = res.get_index_at_position(agent.position)
			var under: float = res.get_available_biomass(cell) if cell >= 0 else 0.0
			var near := 0.0
			var near_cells: Array = res.query_cells(agent.position, 150.0)
			for c in near_cells:
				var ci: int = int(c) if typeof(c) == TYPE_INT else int(c.get("index", -1))
				if ci >= 0:
					near = maxf(near, res.get_available_biomass(ci))
			var row := {"t": snappedf(manager.simulation_time, 0.1), "h": snappedf(agent.hunger, 0.1), "th": snappedf(agent.thirst, 0.1),
				"e": snappedf(agent.energy, 0.1), "act": str(agent.current_action), "st": str(agent.state), "ai": str(agent.ai_state),
				"under": snappedf(under, 0.1), "near": snappedf(near, 0.1), "risk": snappedf(world.fear_field.risk_at(agent.position), 0.01),
				"pos": [snappedf(agent.position.x, 1), snappedf(agent.position.y, 1)], "group": agent.group_id,
				"target": agent.grass_target_cache.get("index", -1) if agent.grass_target_cache is Dictionary else -1,
				"interact": snappedf(agent.interaction_timer, 0.01),
				"tavail": snappedf(res.get_available_biomass(int(agent.grass_target_cache.get("index", -1))), 0.001) if agent.grass_target_cache is Dictionary and not agent.grass_target_cache.is_empty() else -1.0,
				"tdist": snappedf(agent.position.distance_to(agent.grass_target_cache.get("center", agent.position)), 1) if agent.grass_target_cache is Dictionary and not agent.grass_target_cache.is_empty() else -1.0,
				"tmin": agent.grass_target_cache.get("min_biomass", -1) if agent.grass_target_cache is Dictionary else -1,
				"mig": snappedf(agent.position.distance_to(world.herd_migration_goal(agent.species_type, agent.group_id)), 1)
					if world.herd_migration_goal(agent.species_type, agent.group_id) != null else -1.0}
			if not histories.has(agent.id):
				histories[agent.id] = []
			histories[agent.id].append(row)
			if histories[agent.id].size() > HISTORY:
				histories[agent.id].pop_front()
			last_hunger[agent.id] = agent.hunger
			var band := "%d" % mini(4, int(agent.hunger / 20.0))
			if not bands.has(band):
				bands[band] = {"n": 0, "act": {}, "st": {}, "under_bite": 0, "near_bite": 0, "risky": 0}
			var b: Dictionary = bands[band]
			b.n += 1
			b.act[row.act] = int(b.act.get(row.act, 0)) + 1
			b.st[row.st] = int(b.st.get(row.st, 0)) + 1
			if under >= bite:
				b.under_bite += 1
			if near >= bite:
				b.near_bite += 1
			if row.risk > 0.5:
				b.risky += 1
		# Anyone gone since the last sample while starving counts as a starvation death.
		for id in histories.keys():
			if not alive.has(id):
				if float(last_hunger.get(id, 0.0)) >= 90.0:
					deaths.append({"id": id, "history": histories[id]})
				histories.erase(id)
				last_hunger.erase(id)
		if tick % (sample_ticks * 30) == 0:
			print("t=%.0f herbivores=%d starving deaths so far=%d" % [manager.simulation_time, alive.size(), deaths.size()])
	var result := {"bands": bands, "deaths": deaths, "counters": manager.stats_system.counters}
	var file := FileAccess.open(out, FileAccess.WRITE)
	file.store_string(JSON.stringify(result))
	file.close()
	print("done ", out, " deaths ", deaths.size())
	manager.free()
	quit()
