class_name TestHelpers
extends RefCounted

const AgentAIState := preload("res://scripts/agents/ai/agent_ai_state.gd")
const AgentAction := preload("res://scripts/agents/ai/agent_action.gd")
const AgentBaseScript := preload("res://scripts/agents/agent_base.gd")
const ConfigLoaderScript := preload("res://scripts/core/config_loader.gd")
const SimulationManagerScript := preload("res://scripts/core/simulation_manager.gd")
const StatePolicyScript := preload("res://scripts/agents/ai/state_policy.gd")
const UtilityContextScript := preload("res://scripts/agents/ai/utility_context.gd")


static func build_context(
	values: Dictionary,
	targets: Dictionary = {},
	species_type: String = "test",
	state_name: StringName = AgentAIState.ALIVE
):
	var context = UtilityContextScript.new()
	context.species_type = species_type
	context.state_name = state_name
	context.values = values.duplicate(true)
	context.targets = targets.duplicate(true)
	return context


static func build_policy(state_name: StringName, allowed_actions: Array, is_locked: bool = false):
	var policy = StatePolicyScript.new()
	policy.state_name = state_name
	policy.allowed_actions = allowed_actions.duplicate()
	policy.is_locked = is_locked
	return policy


static func build_test_bundle(seed: int = 17) -> Dictionary:
	var bundle: Dictionary = ConfigLoaderScript.load_config_bundle().duplicate(true)
	bundle["world"]["seed"] = seed
	bundle["world"]["scenery"] = {"enabled": false}
	bundle["balance"]["ai"]["decision_interval_ticks"] = 1
	bundle["world"]["tick_rate"] = 12.0
	bundle["world"]["world_size"] = {"x": 256.0, "y": 256.0}
	bundle["world"]["spatial_cell_size"] = 64.0
	bundle["world"]["grass"] = {
		"cell_size": 32.0,
		"max_biomass": 100.0,
		"regrowth_rate": 0.0,
		"initial_density_min": 1.0,
		"initial_density_max": 1.0,
	}
	# Pinned off on purpose, same reasoning as the flat terrain below: the
	# behavioural fixtures assert on chosen actions and need ratios, and a
	# season sweeping past mid-run must not reach them. `ClimateTests` builds
	# its own bundles when it wants the clock running.
	bundle["world"]["climate"] = {"enabled": false}
	bundle["world"]["terrain"]["cell_size"] = 32.0
	# Pinned flat on purpose: the fixtures assert on routes and reachability, so
	# turning relief on in world.json must not reach them.
	bundle["world"]["terrain"]["height"] = {"levels": 1}
	bundle["world"]["terrain"]["generation"] = {
		"biome_frequency": 0.0,
		"moisture_frequency": 0.0,
		"drought_frequency": 0.0,
		"forest_threshold": 1.0,
		"drought_threshold": 1.0,
		"swamp_threshold": 1.0,
		"swamp_water_radius": 0.0,
	}
	bundle["world"]["terrain"]["obstacles"] = {
		"dense_forest_cluster_count": 0,
		"dense_forest_radius_min_cells": 0.0,
		"dense_forest_radius_max_cells": 0.0,
		"cliff_count": 0,
		"cliff_thickness_min_cells": 0.0,
		"cliff_thickness_max_cells": 0.0,
		"cliff_gap_radius_cells": 0.0,
		"border_clearance_cells": 0,
	}
	bundle["world"]["water_sources"] = [
		{"x": 64.0, "y": 64.0, "radius": 18.0},
		{"x": 192.0, "y": 192.0, "radius": 18.0},
	]
	bundle["world"]["navigation"]["grass_candidate_limit"] = 8
	bundle["world"]["navigation"]["path_budget_per_tick"] = 32
	bundle["world"]["navigation"]["max_new_paths_per_tick"] = 16
	bundle["world"]["navigation"]["goal_bucket_size"] = 2
	bundle["world"]["navigation"]["sector_grass_refresh_ticks"] = 1
	# The margins are what `_build_lod_settings()` now derives the LOD window from. They
	# used to be dead here, overridden by fixed values in `debug.json`, so the fixture's
	# own 0/64 never applied and every test actually ran against 144/560. Stating those
	# explicitly keeps the behaviour these tests were written against; the tests that
	# want dormancy shrink `headless_active_radius` instead.
	bundle["world"]["simulation_lod"] = {
		"sector_size": 64.0,
		"near_sector_margin": 144.0,
		"mid_sector_margin": 560.0,
		"mid_decision_interval": 2,
		"far_decision_interval": 4,
		"very_far_sector_step_seconds": 0.5,
		"headless_active_radius": 96.0,
		"dormant_speed_scale": 0.45,
		"dormant_goal_refresh_seconds": 1.0,
		"dormant_stale_wake_seconds": 2.5,
		"dormant_reify_budget_per_tick": 1,
	}
	# Pinned so the fixtures stop depending on the shipped chart tuning. Raising
	# `sample_interval_ticks` for the seasonal charts moved the sample window
	# past the ten ticks the dormant-metrics fixtures run, and they silently read
	# a stale tick-0 snapshot instead of the window they meant to assert on.
	bundle["balance"]["stats"]["sample_interval_ticks"] = 5
	# Population caps are an ecology-scale rule. Tiny behavioural fixtures spawn
	# their own agents after initialization and would otherwise have a capacity of
	# zero because their preset intentionally starts empty.
	bundle["balance"]["population_regulation"]["enabled"] = false
	# Every species, not two named ones. `_spawn_initial_agents()` reads
	# `<species>_count` off the registry, so a new entry in species.json with a
	# non-zero count in world.json would otherwise seed itself into every
	# behavioural fixture and into the determinism trace.
	var spawns: Dictionary = {}
	for species_id in bundle.get("species", {}).keys():
		spawns["%s_count" % species_id] = 0
		spawns["%s_group_count" % species_id] = 1
	bundle["world"]["spawns"] = spawns
	return bundle


static func create_manager(seed: int = 17):
	return create_manager_with(build_test_bundle(seed), seed)


## For fixtures that need to reshape the world first - a map wide enough that a
## predator cannot see across it, say. `build_test_bundle()` then edits, then this.
static func create_manager_with(bundle: Dictionary, seed: int = 17):
	var manager = SimulationManagerScript.new()
	manager.initialize(bundle, seed)
	return manager


static func create_benchmark_manager(seed: int = 17, herbivore_count: int = 220, predator_count: int = 18, herbivore_group_count: int = 12):
	var bundle: Dictionary = ConfigLoaderScript.load_config_bundle().duplicate(true)
	bundle["world"]["seed"] = seed
	bundle["world"]["scenery"] = {"enabled": false}
	bundle["balance"]["ai"]["decision_interval_ticks"] = 1
	var spawns: Dictionary = {}
	for species_id in bundle.get("species", {}).keys():
		spawns["%s_count" % species_id] = 0
		spawns["%s_group_count" % species_id] = 1
	spawns["herbivore_count"] = herbivore_count
	spawns["predator_count"] = predator_count
	spawns["herbivore_group_count"] = herbivore_group_count
	bundle["world"]["spawns"] = spawns
	var manager = SimulationManagerScript.new()
	manager.initialize(bundle, seed)
	return manager


static func run_ticks(manager, ticks: int) -> void:
	for _index in range(ticks):
		manager.step_once()


static func destroy_manager(manager) -> void:
	if manager == null:
		return
	manager.shutdown()
	manager.free()


## For species without a named helper. The two below stay because they also pin
## age and cooldown, which most fixtures want.
static func spawn_species(world, species_id: String, position: Vector2, group_id: int = -1, sex: String = AgentBaseScript.SEX_FEMALE):
	var agent = world.spawn_agent(species_id, position, group_id, sex, {"reason": "test"})
	if agent != null:
		agent.age = 30.0
		agent.reproduction_cooldown = 999.0
	_refresh_spatial_queries(world)
	return agent


static func spawn_herbivore(world, position: Vector2, group_id: int = 0):
	var herbivore = world.spawn_agent("herbivore", position, group_id, AgentBaseScript.SEX_FEMALE, {"reason": "test"})
	herbivore.age = 30.0
	herbivore.reproduction_cooldown = 999.0
	_refresh_spatial_queries(world)
	return herbivore


static func spawn_predator(world, position: Vector2):
	var predator = world.spawn_agent("predator", position, -1, AgentBaseScript.SEX_MALE, {"reason": "test"})
	predator.age = 30.0
	predator.reproduction_cooldown = 999.0
	_refresh_spatial_queries(world)
	return predator


static func spawn_carcass(world, position: Vector2, meat_remaining: float = 80.0) -> int:
	var carcass_id: int = world.next_carcass_id
	world.next_carcass_id += 1
	world.carcasses[carcass_id] = {
		"id": carcass_id,
		"position": position,
		"created_at": world.current_time,
		"ttl_seconds": 120.0,
		"source_species": AgentBaseScript.SPECIES_HERBIVORE,
		"death_cause": "test",
		"meat_total": meat_remaining,
		"meat_remaining": meat_remaining,
		"max_feeders": 3,
		"active_feeder_ids": [],
		"source_agent_id": -1,
	}
	world._register_carcass_sector(carcass_id, position)
	return carcass_id


static func capture_trace(manager, agent_ids: Array, ticks: int) -> Array:
	var trace: Array = []
	for _index in range(ticks):
		manager.step_once()
		var line_parts: Array = []
		for agent_id in agent_ids:
			var agent = manager.world_state.get_agent(int(agent_id))
			if agent == null:
				line_parts.append("%d:missing" % int(agent_id))
				continue
			line_parts.append("%d:%s:%s:%s" % [
				int(agent_id),
				String(agent.ai_state),
				String(agent.current_action),
				agent.state,
			])
		trace.append("|".join(line_parts))
	return trace


static func _refresh_spatial_queries(world) -> void:
	world.spatial_grid.rebuild(world.get_living_agents())
