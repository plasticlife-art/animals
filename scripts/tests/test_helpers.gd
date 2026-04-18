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
	bundle["world"]["terrain"]["cell_size"] = 32.0
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
	bundle["world"]["spawns"] = {
		"herbivore_count": 0,
		"predator_count": 0,
		"herbivore_group_count": 1,
	}
	return bundle


static func create_manager(seed: int = 17):
	var manager = SimulationManagerScript.new()
	manager.initialize(build_test_bundle(seed), seed)
	return manager


static func run_ticks(manager, ticks: int) -> void:
	for _index in range(ticks):
		manager.step_once()


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
