class_name WorldState
extends RefCounted

const HerbivoreScript = preload("res://scripts/agents/herbivore.gd")
const PredatorScript = preload("res://scripts/agents/predator.gd")
const AgentBaseScript = preload("res://scripts/agents/agent_base.gd")
const AgentPerceptionSnapshotScript = preload("res://scripts/agents/agent_perception_snapshot.gd")
const ResourceSystemScript = preload("res://scripts/world/resource_system.gd")
const SpatialGridScript = preload("res://scripts/world/spatial_grid.gd")
const TerrainSystemScript = preload("res://scripts/world/terrain_system.gd")

const LOD_TIER_0 := 0
const LOD_TIER_1 := 1
const LOD_TIER_2 := 2
const LOD_PRIORITY_STATES := {
	"flee": true,
	"seek_prey": true,
	"chase": true,
	"attack": true,
	"reproduce": true,
	"eat": true,
	"drink": true,
	"seek_carcass": true,
	"feed_carcass": true,
}

var bounds: Rect2 = Rect2(0.0, 0.0, 1600.0, 900.0)
var agents: Dictionary = {}
var carcasses: Dictionary = {}
var pending_spawns: Array = []
var pending_removals: Array = []
var pending_carcass_removals: Array = []
var water_sources: Array = []
var next_agent_id: int = 1
var next_carcass_id: int = 1
var config_bundle: Dictionary = {}
var event_bus
var rng: RandomNumberGenerator
var terrain_system: TerrainSystem
var resource_system: ResourceSystem
var spatial_grid: SpatialGrid
var navigation_config: Dictionary = {}
var simulation_lod_config: Dictionary = {}
var current_tick: int = 0
var current_time: float = 0.0
var living_agents: Array = []
var performance_counters: Dictionary = {}
var lod_counts := {
	"lod0_agents": 0,
	"lod1_agents": 0,
	"lod2_agents": 0,
}
var _living_agent_index_by_id: Dictionary = {}
var _group_state_cache: Dictionary = {}
var _agent_sector_cells: Dictionary = {}
var _sector_states: Dictionary = {}
var _sector_size: float = 512.0
var _sector_grass_cache: Dictionary = {}
var _path_budget_remaining: int = 0
var _new_path_budget_remaining: int = 0
var _goal_bucket_size: int = 4
var _sector_grass_refresh_ticks: int = 18
var _scratch_agent_query: Array = []
var _mid_decision_interval_ticks: int = 3
var _far_decision_interval_ticks: int = 8
var _very_far_sector_step_seconds: float = 0.75


func initialize(new_config_bundle: Dictionary, new_event_bus, new_rng: RandomNumberGenerator) -> void:
	config_bundle = new_config_bundle
	event_bus = new_event_bus
	rng = new_rng
	agents.clear()
	carcasses.clear()
	pending_spawns.clear()
	pending_removals.clear()
	pending_carcass_removals.clear()
	next_agent_id = 1
	next_carcass_id = 1

	var world_config: Dictionary = config_bundle.get("world", {})
	var world_size_config: Dictionary = world_config.get("world_size", {})
	bounds = Rect2(
		0.0,
		0.0,
		float(world_size_config.get("x", 1600.0)),
		float(world_size_config.get("y", 900.0))
	)

	navigation_config = world_config.get("navigation", {}).duplicate(true)
	simulation_lod_config = world_config.get("simulation_lod", {}).duplicate(true)

	water_sources.clear()
	for source in world_config.get("water_sources", []):
		water_sources.append({
			"position": Vector2(float(source.get("x", 0.0)), float(source.get("y", 0.0))),
			"radius": float(source.get("radius", 48.0)),
		})

	terrain_system = TerrainSystemScript.new()
	terrain_system.initialize(world_config, rng, water_sources)

	resource_system = ResourceSystemScript.new()
	resource_system.initialize(world_config, rng, terrain_system)
	_sector_size = maxf(terrain_system.cell_size * 8.0, float(simulation_lod_config.get("sector_size", 512.0)))
	_goal_bucket_size = maxi(1, int(navigation_config.get("goal_bucket_size", 4)))
	_sector_grass_refresh_ticks = maxi(1, int(navigation_config.get("sector_grass_refresh_ticks", 18)))

	spatial_grid = SpatialGridScript.new()
	spatial_grid.configure(float(world_config.get("spatial_cell_size", 96.0)))

	living_agents.clear()
	_living_agent_index_by_id.clear()
	_group_state_cache.clear()
	_agent_sector_cells.clear()
	_sector_states.clear()
	_sector_grass_cache.clear()
	_reset_performance_counters()
	_spawn_initial_agents()
	_rebuild_group_state_cache()
	_update_lod_assignments({"enabled": false})


func step(delta: float, tick: int, time_seconds: float, lod_context: Dictionary = {}) -> void:
	current_tick = tick
	current_time = time_seconds
	_reset_performance_counters()
	_prepare_navigation_budget()
	resource_system.step(delta)
	var active_lod_context: Dictionary = _normalize_lod_context(lod_context)
	_mid_decision_interval_ticks = int(active_lod_context.get("mid_decision_interval_ticks", 3))
	_far_decision_interval_ticks = int(active_lod_context.get("far_decision_interval_ticks", 8))
	_very_far_sector_step_seconds = float(active_lod_context.get("very_far_sector_step_seconds", 0.75))
	_wake_relevant_dormant_sectors(active_lod_context)
	_rebuild_group_state_cache()

	for agent in living_agents:
		if agent == null or not agent.is_alive:
			continue
		var lod_tier: int = _resolve_lod_tier(agent, active_lod_context)
		agent.lod_tier = lod_tier
		var previous_position: Vector2 = agent.position
		if _should_run_full_tick(agent, lod_tier, active_lod_context):
			performance_counters["agents_full_tick"] += 1
			agent.tick(self, delta)
		else:
			performance_counters["agents_maintenance_tick"] += 1
			agent.tick_maintenance(self, delta)
		_track_agent_runtime_position(agent, previous_position)

	_flush_removals()
	_flush_spawns()
	_step_carcasses(delta)
	_step_dormant_sectors(delta, active_lod_context)
	_sleep_far_sectors(active_lod_context)
	_flush_carcass_removals()
	var path_stats: Dictionary = {} if terrain_system == null else terrain_system.consume_path_query_stats()
	performance_counters["pathfind_calls"] += int(path_stats.get("queries", 0))
	performance_counters["path_cache_hits"] += int(path_stats.get("cache_hits", 0))
	_update_lod_assignments(active_lod_context)


func spawn_agent(species_type: String, position: Vector2, group_id: int = -1, sex_override: String = "", metadata: Dictionary = {}) -> AgentBase:
	var agent = _create_agent(species_type)
	if agent == null:
		return null

	var species_config: Dictionary = config_bundle.get("species", {}).get(species_type, {})
	var sex: String = sex_override if sex_override != "" else _random_sex()
	var spawn_position: Vector2 = get_nearest_walkable_position(clamp_position(position))
	agent.configure(
		next_agent_id,
		species_type,
		spawn_position,
		sex,
		species_config,
		config_bundle.get("balance", {}),
		rng,
		group_id
	)
	agent.lod_tier = LOD_TIER_0
	agents[next_agent_id] = agent
	_register_living_agent(agent)
	next_agent_id += 1

	var reason: String = str(metadata.get("reason", "runtime"))
	emit_event("AgentBorn", agent, -1, {
		"reason": reason,
		"group_id": group_id,
	})
	return agent


func queue_spawn_agent(species_type: String, position: Vector2, group_id: int, parent_a = null, parent_b = null) -> void:
	pending_spawns.append({
		"species": species_type,
		"position": position,
		"group_id": group_id,
		"parent_a_id": -1 if parent_a == null else parent_a.id,
		"parent_b_id": -1 if parent_b == null else parent_b.id,
	})


func kill_agent(agent, cause: String, other_agent_id: int = -1) -> void:
	if agent == null or not agent.is_alive:
		return
	if agent.has_method("release_carcass_target"):
		agent.call("release_carcass_target", self)
	agent.is_alive = false
	pending_removals.append(agent.id)
	_maybe_spawn_carcass(agent, cause)

	if cause == "starvation":
		emit_event("AgentStarved", agent, other_agent_id, {"cause": cause})
	elif cause == "old_age":
		emit_event("AgentDiedOfAge", agent, other_agent_id, {"cause": cause})

	emit_event("AgentDied", agent, other_agent_id, {"cause": cause})


func get_agent(agent_id: int):
	return agents.get(agent_id)


func get_living_agents() -> Array:
	return living_agents


func get_population_metrics() -> Dictionary:
	var herbivore_count := 0
	var predator_count := 0
	var hunger_sum := 0.0
	var energy_sum := 0.0
	var living_count := 0
	for agent in living_agents:
		if agent == null or not agent.is_alive:
			continue
		living_count += 1
		hunger_sum += agent.hunger
		energy_sum += agent.energy
		if agent.species_type == AgentBaseScript.SPECIES_HERBIVORE:
			herbivore_count += 1
		elif agent.species_type == AgentBaseScript.SPECIES_PREDATOR:
			predator_count += 1
	for sector_state in _sector_states.values():
		if not bool(sector_state.get("dormant", false)):
			continue
		var dormant_species: Dictionary = sector_state.get("dormant_species", {})
		for species_key in dormant_species.keys():
			var species_state: Dictionary = dormant_species[species_key]
			var count: int = int(species_state.get("count", 0))
			if count <= 0:
				continue
			living_count += count
			hunger_sum += float(species_state.get("avg_hunger", 0.0)) * count
			energy_sum += float(species_state.get("avg_energy", 0.0)) * count
			if species_key == AgentBaseScript.SPECIES_HERBIVORE:
				herbivore_count += count
			elif species_key == AgentBaseScript.SPECIES_PREDATOR:
				predator_count += count
	return {
		"herbivore_count": herbivore_count,
		"predator_count": predator_count,
		"hunger_sum": hunger_sum,
		"energy_sum": energy_sum,
		"living_count": living_count,
	}


func get_lod_counts() -> Dictionary:
	return lod_counts.duplicate(true)


func get_performance_counters() -> Dictionary:
	return performance_counters.duplicate(true)


func get_dormant_sector_count() -> int:
	var count := 0
	for sector_state in _sector_states.values():
		if bool(sector_state.get("dormant", false)):
			count += 1
	return count


func get_dormant_agent_count() -> int:
	var count := 0
	for sector_state in _sector_states.values():
		if not bool(sector_state.get("dormant", false)):
			continue
		count += int(sector_state.get("dormant_count", 0))
	return count


func get_active_carcass_count() -> int:
	return carcasses.size()


func get_total_carcass_meat_remaining() -> float:
	var total := 0.0
	for carcass in carcasses.values():
		total += float(carcass.get("meat_remaining", 0.0))
	return total


func shutdown() -> void:
	agents.clear()
	carcasses.clear()
	pending_spawns.clear()
	pending_removals.clear()
	pending_carcass_removals.clear()
	water_sources.clear()
	living_agents.clear()
	performance_counters.clear()
	_living_agent_index_by_id.clear()
	_group_state_cache.clear()
	_agent_sector_cells.clear()
	_sector_states.clear()
	_sector_grass_cache.clear()
	_scratch_agent_query.clear()
	spatial_grid = null
	resource_system = null
	terrain_system = null
	event_bus = null
	rng = null
	config_bundle.clear()


func refresh_lod_assignments(lod_context: Dictionary = {}) -> void:
	_update_lod_assignments(_normalize_lod_context(lod_context))


func query_agents(position: Vector2, radius: float, species_filter: String = "", exclude_id: int = -1) -> Array:
	performance_counters["agent_query_calls"] += 1
	return spatial_grid.query(position, radius, species_filter, exclude_id)


func query_agents_into(results: Array, position: Vector2, radius: float, species_filter: String = "", exclude_id: int = -1) -> void:
	performance_counters["agent_query_calls"] += 1
	spatial_grid.query_into(results, position, radius, species_filter, exclude_id)


func query_grass_cells(position: Vector2, radius: float, min_biomass: float = 0.0) -> Dictionary:
	performance_counters["grass_query_calls"] += 1
	return find_reachable_grass(position, radius, min_biomass)


func query_water_sources(position: Vector2, radius: float) -> Array:
	performance_counters["water_query_calls"] += 1
	var matches: Array = []
	for source in water_sources:
		var combined_radius: float = radius + float(source.get("radius", 0.0))
		if position.distance_squared_to(source["position"]) <= combined_radius * combined_radius:
			matches.append(source)
	return matches


func query_carcasses(position: Vector2, radius: float) -> Array:
	performance_counters["carcass_query_calls"] += 1
	var matches: Array = []
	var radius_sq := radius * radius
	for carcass in carcasses.values():
		if not _is_carcass_available(carcass):
			continue
		if position.distance_squared_to(carcass["position"]) > radius_sq:
			continue
		matches.append(carcass)
	return matches


func build_herbivore_snapshot(agent) -> Variant:
	var snapshot = AgentPerceptionSnapshotScript.new()
	snapshot.built_at_tick = current_tick
	snapshot.built_at_time = current_time
	var neighbor_radius := float(agent.perception.get("neighbor_radius", 90.0))
	snapshot.species_neighbors = query_agents(agent.position, neighbor_radius, AgentBaseScript.SPECIES_HERBIVORE, agent.id)
	if agent.group_id == -1:
		snapshot.group_neighbors = snapshot.species_neighbors
	else:
		for neighbor in snapshot.species_neighbors:
			if neighbor.group_id == agent.group_id:
				snapshot.group_neighbors.append(neighbor)
		if snapshot.group_neighbors.is_empty():
			snapshot.group_neighbors = snapshot.species_neighbors
	var danger_radius := float(agent.perception.get("danger_radius", 120.0))
	snapshot.predators = query_agents(agent.position, danger_radius, AgentBaseScript.SPECIES_PREDATOR, agent.id)
	snapshot.group_center = get_group_center(agent.group_id, agent.species_type, agent.id)
	snapshot.water_target = _resolve_water_source(agent.position, float(agent.perception.get("water_search_radius", 260.0)))
	snapshot.grass_target = _find_grass_target_for_agent(agent)
	return snapshot


func build_predator_snapshot(agent) -> Variant:
	var snapshot = AgentPerceptionSnapshotScript.new()
	snapshot.built_at_tick = current_tick
	snapshot.built_at_time = current_time
	var vision_radius := float(agent.perception.get("vision_radius", 240.0))
	snapshot.prey_candidates = query_agents(agent.position, vision_radius, AgentBaseScript.SPECIES_HERBIVORE, agent.id)
	snapshot.carcasses = query_carcasses(agent.position, float(agent.balance.get("carcass", {}).get("search_radius", vision_radius)))
	var mate_radius := float(agent.perception.get("mate_search_radius", 80.0))
	var mates := query_agents(agent.position, mate_radius, AgentBaseScript.SPECIES_PREDATOR, agent.id)
	snapshot.water_target = _resolve_water_source(agent.position, _resolve_predator_water_search_radius(agent))
	snapshot.investigation_source = agent._get_recent_investigation_water_source(self)
	snapshot.mate_target = agent._find_viable_mate(self, false, mates)
	snapshot.kin_center = agent.last_known_kin_center
	snapshot.prey_target = agent._choose_prey(self, snapshot.prey_candidates)
	snapshot.carcass_target = agent._choose_carcass(self, snapshot.carcasses)
	snapshot.values["water_has_herbivore"] = false
	return snapshot


func record_ai_context_ms(elapsed_ms: float) -> void:
	performance_counters["ai_context_build_ms"] += elapsed_ms


func record_action_select_ms(elapsed_ms: float) -> void:
	performance_counters["action_select_ms"] += elapsed_ms


func get_carcass(carcass_id: int) -> Dictionary:
	var carcass: Dictionary = carcasses.get(carcass_id, {})
	if carcass.is_empty() or not _is_carcass_available(carcass):
		return {}
	return carcass


func reserve_carcass_feeder(carcass_id: int, predator_id: int) -> bool:
	var carcass: Dictionary = carcasses.get(carcass_id, {})
	if carcass.is_empty() or not _is_carcass_available(carcass):
		return false
	var active_feeders: Array = carcass.get("active_feeder_ids", [])
	if active_feeders.has(predator_id):
		return true
	if active_feeders.size() >= int(carcass.get("max_feeders", 1)):
		return false
	active_feeders.append(predator_id)
	carcass["active_feeder_ids"] = active_feeders
	carcasses[carcass_id] = carcass
	return true


func release_carcass_feeder(carcass_id: int, predator_id: int) -> void:
	var carcass: Dictionary = carcasses.get(carcass_id, {})
	if carcass.is_empty():
		return
	var active_feeders: Array = carcass.get("active_feeder_ids", [])
	if not active_feeders.has(predator_id):
		return
	active_feeders.erase(predator_id)
	carcass["active_feeder_ids"] = active_feeders
	carcasses[carcass_id] = carcass


func consume_carcass(carcass_id: int, amount: float, predator_id: int = -1) -> float:
	var carcass: Dictionary = carcasses.get(carcass_id, {})
	if carcass.is_empty() or not _is_carcass_available(carcass):
		return 0.0
	var consumed := minf(maxf(amount, 0.0), float(carcass.get("meat_remaining", 0.0)))
	if consumed <= 0.0:
		return 0.0
	carcass["meat_remaining"] = maxf(0.0, float(carcass.get("meat_remaining", 0.0)) - consumed)
	carcasses[carcass_id] = carcass
	emit_event("CarcassConsumed", null, predator_id, {
		"carcass_id": carcass_id,
		"predator_id": predator_id,
		"consumed": consumed,
		"meat_remaining": float(carcass.get("meat_remaining", 0.0)),
		"position": {
			"x": float(carcass["position"].x),
			"y": float(carcass["position"].y),
		},
	})
	if float(carcass.get("meat_remaining", 0.0)) <= 0.0:
		_queue_carcass_removal(carcass_id)
	return consumed


func find_carcass_by_source_agent(source_agent_id: int) -> Dictionary:
	for carcass in carcasses.values():
		if int(carcass.get("source_agent_id", -1)) == source_agent_id and _is_carcass_available(carcass):
			return carcass
	return {}


func get_group_center(group_id: int, species_type: String, exclude_id: int = -1):
	performance_counters["group_center_lookups"] += 1
	var cache_key := "%s:%d" % [species_type, group_id]
	var group_state: Dictionary = _group_state_cache.get(cache_key, {})
	if group_state.is_empty():
		return null
	var count: int = int(group_state.get("count", 0))
	if count <= 0:
		return null
	if exclude_id == -1:
		return group_state.get("center", null)
	if count <= 1:
		return null
	var agent = get_agent(exclude_id)
	if agent == null or not agent.is_alive or agent.group_id != group_id or agent.species_type != species_type:
		return group_state.get("center", null)
	var sum: Vector2 = group_state.get("sum", Vector2.ZERO)
	return (sum - agent.position) / float(count - 1)


func get_biome_at_position(position: Vector2) -> String:
	if terrain_system == null:
		return "meadow"
	return terrain_system.get_biome_at_position(position)


func get_move_cost_at_position(position: Vector2) -> float:
	if terrain_system == null:
		return 1.0
	return terrain_system.get_move_cost_at_position(position)


func is_walkable_position(position: Vector2) -> bool:
	if terrain_system == null:
		return bounds.has_point(position)
	return terrain_system.is_walkable_position(position)


func clamp_position(position: Vector2) -> Vector2:
	return Vector2(
		clampf(position.x, bounds.position.x + 4.0, bounds.end.x - 4.0),
		clampf(position.y, bounds.position.y + 4.0, bounds.end.y - 4.0)
	)


func get_nearest_walkable_position(position: Vector2) -> Vector2:
	var clamped: Vector2 = clamp_position(position)
	if terrain_system == null:
		return clamped
	if terrain_system.is_walkable_position(clamped):
		return clamped
	var nearest_index: int = terrain_system.find_nearest_walkable_index(terrain_system.get_index_from_position(clamped))
	if nearest_index == -1:
		return clamped
	return terrain_system.get_cell_center(nearest_index)


func resolve_movement_position(from_position: Vector2, to_position: Vector2) -> Vector2:
	var clamped_target: Vector2 = clamp_position(to_position)
	if terrain_system == null or terrain_system.is_walkable_position(clamped_target):
		return clamped_target

	var slide_x: Vector2 = clamp_position(Vector2(clamped_target.x, from_position.y))
	if terrain_system.is_walkable_position(slide_x):
		return slide_x

	var slide_y: Vector2 = clamp_position(Vector2(from_position.x, clamped_target.y))
	if terrain_system.is_walkable_position(slide_y):
		return slide_y

	return get_nearest_walkable_position(from_position)


func random_point() -> Vector2:
	return get_nearest_walkable_position(Vector2(
		rng.randf_range(bounds.position.x, bounds.end.x),
		rng.randf_range(bounds.position.y, bounds.end.y)
	))


func random_unit_vector() -> Vector2:
	return Vector2.RIGHT.rotated(rng.randf_range(0.0, TAU))


func _resolve_water_source(position: Vector2, radius: float) -> Dictionary:
	var best := {}
	var best_distance_sq := INF
	for source in query_water_sources(position, radius):
		var distance_sq := position.distance_squared_to(source["position"])
		if distance_sq < best_distance_sq:
			best = source
			best_distance_sq = distance_sq
	return best


func _resolve_predator_water_search_radius(agent) -> float:
	var critical_thirst := float(agent.balance.get("state_thresholds", {}).get("critical_thirst", 60.0))
	var search_radius := float(agent.perception.get("water_search_radius", agent.perception.get("vision_radius", 240.0)))
	if agent.thirst >= critical_thirst:
		search_radius = maxf(search_radius * 3.0, 1200.0)
	return search_radius


func _find_grass_target_for_agent(agent) -> Dictionary:
	var thresholds: Dictionary = agent.balance.get("state_thresholds", {})
	var graze_hunger_floor := float(thresholds.get("graze_hunger_floor", 20.0))
	var critical_hunger := float(thresholds.get("critical_hunger", 65.0))
	var base_search_radius := float(agent.perception.get("grass_search_radius", 180.0))
	var urgency_ratio := 0.0
	var urgency_start := minf(graze_hunger_floor, critical_hunger)
	if agent.hunger > urgency_start:
		urgency_ratio = clampf((agent.hunger - urgency_start) / maxf(1.0, agent.need_max - urgency_start), 0.0, 1.0)
	var min_biomass := 4.0 if urgency_ratio < 0.45 else 2.0
	var local_grass := find_reachable_grass(agent.position, base_search_radius, min_biomass)
	if not local_grass.is_empty():
		return local_grass
	var expanded_search_radius := lerpf(base_search_radius, maxf(base_search_radius * 4.0, 720.0), urgency_ratio)
	if expanded_search_radius <= base_search_radius:
		return {}
	return find_reachable_grass(agent.position, expanded_search_radius, min_biomass)


func find_path(from_position: Vector2, to_position: Vector2) -> Dictionary:
	if terrain_system == null:
		return {
			"cells": [],
			"cost": 0.0,
			"reachable": true,
			"start_index": -1,
			"goal_index": -1,
		}
	return terrain_system.find_path(from_position, to_position)


func consume_grass_cell(index: int, amount: float) -> float:
	var consumed := resource_system.consume_cell(index, amount)
	if consumed > 0.0:
		_mark_grass_sector_dirty_by_index(index)
	return consumed


func find_reachable_grass(position: Vector2, radius: float, min_biomass: float = 0.0) -> Dictionary:
	if terrain_system == null:
		return resource_system.find_best_cell(position, radius, min_biomass)

	var start_index: int = terrain_system.find_nearest_walkable_index(terrain_system.get_index_from_position(position))
	if start_index == -1:
		return {}

	var candidate := _find_sector_grass_candidate(position, radius, min_biomass)
	if candidate.is_empty():
		candidate = resource_system.find_best_cell(position, radius, min_biomass)
	if candidate.is_empty():
		return {}
	var candidate_index: int = int(candidate.get("index", -1))
	if candidate_index == -1:
		return {}
	var path_result := _find_path_with_budget(start_index, candidate_index)
	var path_cells: Array = path_result.get("cells", [])
	if path_cells.is_empty():
		return {}
	candidate["path_cost"] = float(path_result.get("cost", INF))
	candidate["reachable"] = bool(path_result.get("reachable", false))
	candidate["path_cells"] = path_cells.duplicate()
	candidate["score"] = float(candidate.get("biomass", 0.0)) - candidate["path_cost"] * 0.12
	return candidate


func get_next_waypoint(from_position: Vector2, to_position: Vector2, agent_id: int, force_repath: bool = false) -> Vector2:
	var agent: AgentBase = get_agent(agent_id)
	if agent == null:
		return clamp_position(to_position)
	if terrain_system == null:
		return clamp_position(to_position)

	var target: Vector2 = get_nearest_walkable_position(clamp_position(to_position))
	var start_index: int = terrain_system.find_nearest_walkable_index(terrain_system.get_index_from_position(from_position))
	var goal_index: int = terrain_system.find_nearest_walkable_index(terrain_system.get_index_from_position(target))
	if start_index == -1 or goal_index == -1:
		return from_position

	var goal_radius_cells: int = maxi(0, int(navigation_config.get("goal_reached_radius_cells", 1)))
	if _cell_distance(start_index, goal_index) <= float(goal_radius_cells):
		agent.path_cells = []
		agent.path_index = 0
		agent.path_goal_cell = goal_index
		return target

	var repath_interval: int = maxi(1, int(navigation_config.get("repath_interval_ticks", 8)))
	var needs_repath: bool = force_repath
	needs_repath = needs_repath or agent.path_cells.is_empty()
	needs_repath = needs_repath or agent.path_goal_cell != goal_index
	needs_repath = needs_repath or current_tick - agent.last_repath_tick >= repath_interval
	needs_repath = needs_repath or agent.stuck_timer >= float(repath_interval) * 0.08
	needs_repath = needs_repath or agent.path_index >= agent.path_cells.size()
	if not needs_repath and not agent.path_cells.is_empty():
		var previous_index: int = int(agent.path_cells[maxi(0, agent.path_index - 1)])
		var current_path_index: int = int(agent.path_cells[mini(agent.path_index, agent.path_cells.size() - 1)])
		if start_index != previous_index and start_index != current_path_index:
			needs_repath = true
		elif not terrain_system.is_walkable_index(current_path_index):
			needs_repath = true

	if needs_repath:
		var path_result: Dictionary = _find_path_with_budget(start_index, goal_index)
		var path_cells: Array = path_result.get("cells", [])
		agent.path_cells = path_cells.duplicate()
		agent.path_goal_cell = goal_index
		agent.last_repath_tick = current_tick
		agent.path_index = 1 if agent.path_cells.size() > 1 else agent.path_cells.size()
		if agent.path_cells.is_empty():
			return target

	var waypoint_radius_sq: float = pow(terrain_system.cell_size * 0.42, 2.0)
	while agent.path_index < agent.path_cells.size():
		var waypoint_index: int = int(agent.path_cells[agent.path_index])
		var waypoint_center: Vector2 = terrain_system.get_cell_center(waypoint_index)
		if from_position.distance_squared_to(waypoint_center) > waypoint_radius_sq:
			return waypoint_center
		agent.path_index += 1

	return target


func choose_escape_destination(position: Vector2, flee_vector: Vector2, base_distance: float) -> Vector2:
	if terrain_system == null or flee_vector.length_squared() <= 0.0001:
		return clamp_position(position + flee_vector * base_distance)

	var direction: Vector2 = flee_vector.normalized()
	var start_index: int = terrain_system.find_nearest_walkable_index(terrain_system.get_index_from_position(position))
	if start_index == -1:
		return clamp_position(position + direction * base_distance)

	var angles: Array = [0.0, 0.45, -0.45, 0.9, -0.9]
	var distance_scales: Array = [1.0, 1.35]
	var best_target: Vector2 = clamp_position(position + direction * base_distance)
	var best_score: float = -INF
	for scale in distance_scales:
		for angle in angles:
			var candidate_position: Vector2 = get_nearest_walkable_position(clamp_position(position + direction.rotated(float(angle)) * base_distance * float(scale)))
			var candidate_index: int = terrain_system.find_nearest_walkable_index(terrain_system.get_index_from_position(candidate_position))
			if candidate_index == -1:
				continue
			var path_result: Dictionary = _find_path_with_budget(start_index, candidate_index)
			var path_cells: Array = path_result.get("cells", [])
			if path_cells.is_empty():
				continue
			var candidate_direction: Vector2 = candidate_position - position
			if candidate_direction.length_squared() <= 0.001:
				continue
			var alignment: float = direction.dot(candidate_direction.normalized())
			var score: float = alignment * 220.0 - float(path_result.get("cost", INF))
			if not bool(path_result.get("reachable", false)):
				score -= 24.0
			if score > best_score:
				best_score = score
				best_target = candidate_position
	return best_target


func emit_event(event_type: String, agent, other_agent_id: int = -1, data: Dictionary = {}) -> void:
	var payload: Dictionary = {
		"tick": current_tick,
		"time_seconds": current_time,
		"type": event_type,
		"agent_id": -1 if agent == null else agent.id,
		"other_agent_id": other_agent_id,
		"species": "" if agent == null else agent.species_type,
		"position": {"x": 0.0, "y": 0.0} if agent == null else {
			"x": agent.position.x,
			"y": agent.position.y,
		},
		"data": _sanitize_variant(data),
	}
	event_bus.emit_event(payload)


func _maybe_spawn_carcass(agent, cause: String) -> void:
	if agent == null or agent.species_type != AgentBaseScript.SPECIES_HERBIVORE:
		return
	if cause not in ["predation", "old_age", "starvation", "thirst"]:
		return
	var carcass_config: Dictionary = config_bundle.get("balance", {}).get("carcass", {})
	var meat_total := maxf(0.0, float(carcass_config.get("meat_total", 84.0)))
	if meat_total <= 0.0:
		return
	var carcass_id := next_carcass_id
	next_carcass_id += 1
	var carcass := {
		"id": carcass_id,
		"position": agent.position,
		"created_at": current_time,
		"ttl_seconds": maxf(0.0, float(carcass_config.get("ttl_seconds", 90.0))),
		"source_species": agent.species_type,
		"death_cause": cause,
		"meat_total": meat_total,
		"meat_remaining": meat_total,
		"max_feeders": maxi(1, int(carcass_config.get("max_feeders", 2))),
		"active_feeder_ids": [],
		"source_agent_id": int(agent.id),
	}
	carcasses[carcass_id] = carcass
	var sector_key := _get_sector_key(agent.position)
	var sector_state: Dictionary = _get_or_create_sector_state(sector_key)
	var carcass_ids: Array = sector_state.get("carcass_ids", [])
	if not carcass_ids.has(carcass_id):
		carcass_ids.append(carcass_id)
	sector_state["carcass_ids"] = carcass_ids
	_sector_states[sector_key] = sector_state
	emit_event("CarcassSpawned", agent, -1, {
		"carcass_id": carcass_id,
		"cause": cause,
		"meat_total": meat_total,
		"source_agent_id": int(agent.id),
		"position": {
			"x": agent.position.x,
			"y": agent.position.y,
		},
	})


func _step_carcasses(_delta: float) -> void:
	for carcass_id in carcasses.keys():
		var carcass: Dictionary = carcasses.get(carcass_id, {})
		if carcass.is_empty():
			continue
		var ttl_seconds := float(carcass.get("ttl_seconds", 0.0))
		if ttl_seconds > 0.0 and current_time - float(carcass.get("created_at", current_time)) >= ttl_seconds:
			emit_event("CarcassExpired", null, -1, {
				"carcass_id": int(carcass_id),
				"meat_remaining": float(carcass.get("meat_remaining", 0.0)),
				"lifetime_seconds": current_time - float(carcass.get("created_at", current_time)),
				"position": {
					"x": float(carcass["position"].x),
					"y": float(carcass["position"].y),
				},
			})
			_queue_carcass_removal(int(carcass_id))


func _flush_carcass_removals() -> void:
	if pending_carcass_removals.is_empty():
		return
	for carcass_id in pending_carcass_removals:
		var carcass: Dictionary = carcasses.get(carcass_id, {})
		if not carcass.is_empty():
			var sector_key := _get_sector_key(carcass["position"])
			var sector_state: Dictionary = _sector_states.get(sector_key, {})
			if not sector_state.is_empty():
				var carcass_ids: Array = sector_state.get("carcass_ids", [])
				carcass_ids.erase(carcass_id)
				sector_state["carcass_ids"] = carcass_ids
				_sector_states[sector_key] = sector_state
		carcasses.erase(carcass_id)
	pending_carcass_removals.clear()


func _queue_carcass_removal(carcass_id: int) -> void:
	if pending_carcass_removals.has(carcass_id):
		return
	var carcass: Dictionary = carcasses.get(carcass_id, {})
	if carcass.is_empty():
		return
	for feeder_id in carcass.get("active_feeder_ids", []):
		var feeder = get_agent(int(feeder_id))
		if feeder != null and feeder.has_method("on_carcass_removed"):
			feeder.call("on_carcass_removed", carcass_id)
	carcass["active_feeder_ids"] = []
	carcasses[carcass_id] = carcass
	pending_carcass_removals.append(carcass_id)


func _is_carcass_available(carcass: Dictionary) -> bool:
	if carcass.is_empty():
		return false
	if float(carcass.get("meat_remaining", 0.0)) <= 0.0:
		return false
	var ttl_seconds := float(carcass.get("ttl_seconds", 0.0))
	if ttl_seconds <= 0.0:
		return false
	return current_time - float(carcass.get("created_at", current_time)) < ttl_seconds


func _spawn_initial_agents() -> void:
	var world_config: Dictionary = config_bundle.get("world", {})
	var spawn_config: Dictionary = world_config.get("spawns", {})
	var herbivore_count: int = int(spawn_config.get("herbivore_count", 120))
	var predator_count: int = int(spawn_config.get("predator_count", 12))
	var group_count: int = maxi(1, int(spawn_config.get("herbivore_group_count", 8)))

	var herd_centers: Array = []
	for index in range(group_count):
		herd_centers.append(random_point())

	for index in range(herbivore_count):
		var center: Vector2 = herd_centers[index % group_count]
		var spawn_position: Vector2 = get_nearest_walkable_position(clamp_position(center + Vector2(rng.randf_range(-60.0, 60.0), rng.randf_range(-60.0, 60.0))))
		spawn_agent(AgentBaseScript.SPECIES_HERBIVORE, spawn_position, index % group_count, "", {"reason": "initial"})

	var predator_pair_count: int = maxi(1, int(ceil(float(predator_count) / 2.0)))
	var predator_centers: Array = []
	for _index in range(predator_pair_count):
		predator_centers.append(random_point())

	for pair_index in range(predator_pair_count):
		var pair_center: Vector2 = predator_centers[pair_index]
		var male_offset: Vector2 = Vector2(rng.randf_range(-28.0, 28.0), rng.randf_range(-28.0, 28.0))
		var female_offset: Vector2 = Vector2(rng.randf_range(-28.0, 28.0), rng.randf_range(-28.0, 28.0))
		var male_predator = null
		var female_predator = null

		var male_index: int = pair_index * 2
		if male_index < predator_count:
			male_predator = spawn_agent(
				AgentBaseScript.SPECIES_PREDATOR,
				get_nearest_walkable_position(clamp_position(pair_center + male_offset)),
				-1,
				AgentBaseScript.SEX_MALE,
				{"reason": "initial"}
			)

		var female_index: int = male_index + 1
		if female_index < predator_count:
			female_predator = spawn_agent(
				AgentBaseScript.SPECIES_PREDATOR,
				get_nearest_walkable_position(clamp_position(pair_center + female_offset)),
				-1,
				AgentBaseScript.SEX_FEMALE,
				{"reason": "initial"}
			)

		if male_predator != null and female_predator != null:
			if male_predator.has_method("set_preferred_mate_id"):
				male_predator.call("set_preferred_mate_id", female_predator.id)
			if female_predator.has_method("set_preferred_mate_id"):
				female_predator.call("set_preferred_mate_id", male_predator.id)


func _normalize_lod_context(lod_context: Dictionary) -> Dictionary:
	var context: Dictionary = lod_context.duplicate(true)
	context["enabled"] = bool(context.get("enabled", false))
	context["selected_agent_id"] = int(context.get("selected_agent_id", -1))
	context["near_margin"] = maxf(0.0, float(context.get("near_margin", simulation_lod_config.get("near_sector_margin", 320.0))))
	context["mid_margin"] = maxf(float(context.get("near_margin", 0.0)), float(context.get("mid_margin", simulation_lod_config.get("mid_sector_margin", 1280.0))))
	context["mid_update_interval_ticks"] = maxi(1, int(context.get("mid_update_interval_ticks", 2)))
	context["far_update_interval_ticks"] = maxi(1, int(context.get("far_update_interval_ticks", 5)))
	context["mid_decision_interval_ticks"] = maxi(1, int(context.get("mid_decision_interval_ticks", simulation_lod_config.get("mid_decision_interval", 3))))
	context["far_decision_interval_ticks"] = maxi(1, int(context.get("far_decision_interval_ticks", simulation_lod_config.get("far_decision_interval", 8))))
	context["headless_active_radius"] = maxf(0.0, float(context.get("headless_active_radius", simulation_lod_config.get("headless_active_radius", 720.0))))
	context["very_far_sector_step_seconds"] = maxf(0.25, float(context.get("very_far_sector_step_seconds", simulation_lod_config.get("very_far_sector_step_seconds", 0.75))))
	return context


func _resolve_lod_tier(agent: AgentBase, lod_context: Dictionary) -> int:
	if not bool(lod_context.get("enabled", false)):
		return LOD_TIER_0
	if agent.id == int(lod_context.get("selected_agent_id", -1)):
		return LOD_TIER_0
	if _is_priority_lod_agent(agent):
		return LOD_TIER_0

	var focus_rect: Rect2 = lod_context.get("focus_rect", Rect2())
	if focus_rect.size.is_zero_approx():
		var headless_radius := float(lod_context.get("headless_active_radius", 0.0))
		if headless_radius <= 0.0:
			return LOD_TIER_0
		var world_center := bounds.get_center()
		focus_rect = Rect2(world_center - Vector2.ONE * headless_radius, Vector2.ONE * headless_radius * 2.0)

	var sector_origin := _sector_key_to_rect(_get_sector_key(agent.position)).get_center()
	if focus_rect.grow(float(lod_context.get("near_margin", 0.0))).has_point(sector_origin):
		return LOD_TIER_0
	if focus_rect.grow(float(lod_context.get("mid_margin", 0.0))).has_point(sector_origin):
		return LOD_TIER_1
	return LOD_TIER_2


func _is_priority_lod_agent(agent: AgentBase) -> bool:
	return agent.target_agent_id != -1 \
		or agent.interaction_timer > 0.0 \
		or agent.ai_state == &"panic" \
		or LOD_PRIORITY_STATES.has(agent.state)


func _should_run_full_tick(agent: AgentBase, lod_tier: int, lod_context: Dictionary) -> bool:
	if lod_tier == LOD_TIER_0:
		return true

	var interval_key: String = "mid_update_interval_ticks" if lod_tier == LOD_TIER_1 else "far_update_interval_ticks"
	var default_interval: int = 2 if lod_tier == LOD_TIER_1 else 5
	var interval: int = int(lod_context.get(interval_key, default_interval))
	if interval <= 1:
		return true
	return current_tick % interval == agent.id % interval


func should_run_decision_tick(agent: AgentBase) -> bool:
	if agent == null or not agent.is_alive:
		return false
	if agent.lod_tier == LOD_TIER_0:
		return true
	if _is_priority_lod_agent(agent):
		return true
	var interval: int = _mid_decision_interval_ticks if agent.lod_tier == LOD_TIER_1 else _far_decision_interval_ticks
	if agent.cached_snapshot == null:
		return true
	return current_tick % interval == agent.id % interval


func _update_lod_assignments(lod_context: Dictionary) -> void:
	lod_counts = {
		"lod0_agents": 0,
		"lod1_agents": 0,
		"lod2_agents": 0,
	}
	for agent in living_agents:
		if agent == null or not agent.is_alive:
			continue
		var lod_tier: int = _resolve_lod_tier(agent, lod_context)
		agent.lod_tier = lod_tier
		match lod_tier:
			LOD_TIER_1:
				lod_counts["lod1_agents"] += 1
			LOD_TIER_2:
				lod_counts["lod2_agents"] += 1
			_:
				lod_counts["lod0_agents"] += 1
	for sector_key in _sector_states.keys():
		var sector_state: Dictionary = _sector_states[sector_key]
		if not bool(sector_state.get("dormant", false)):
			continue
		var dormant_count := int(sector_state.get("dormant_count", 0))
		if dormant_count <= 0:
			continue
		match _resolve_sector_lod_tier(sector_key, lod_context):
			LOD_TIER_1:
				lod_counts["lod1_agents"] += dormant_count
			LOD_TIER_2:
				lod_counts["lod2_agents"] += dormant_count
			_:
				lod_counts["lod0_agents"] += dormant_count


func _reset_performance_counters() -> void:
	performance_counters = {
		"agents_full_tick": 0,
		"agents_maintenance_tick": 0,
		"ai_context_build_ms": 0.0,
		"action_select_ms": 0.0,
		"pathfind_calls": 0,
		"path_cache_hits": 0,
		"grass_query_calls": 0,
		"agent_query_calls": 0,
		"water_query_calls": 0,
		"carcass_query_calls": 0,
		"spatial_update_ms": 0.0,
		"group_center_lookups": 0,
		"sector_wakeups": 0,
	}


func _prepare_navigation_budget() -> void:
	_path_budget_remaining = maxi(1, int(navigation_config.get("path_budget_per_tick", 64)))
	_new_path_budget_remaining = maxi(1, int(navigation_config.get("max_new_paths_per_tick", 18)))


func _find_path_with_budget(start_index: int, goal_index: int) -> Dictionary:
	if terrain_system == null:
		return {
			"cells": [],
			"cost": 0.0,
			"reachable": false,
			"start_index": start_index,
			"goal_index": goal_index,
		}
	if start_index == -1 or goal_index == -1:
		return terrain_system.find_path_between_indices(start_index, goal_index)
	var has_cached := terrain_system.has_cached_path_between_indices(start_index, goal_index)
	if not has_cached:
		if _path_budget_remaining <= 0 or _new_path_budget_remaining <= 0:
			return {
				"cells": [],
				"cost": INF,
				"reachable": false,
				"start_index": start_index,
				"goal_index": goal_index,
			}
		_path_budget_remaining -= 1
		_new_path_budget_remaining -= 1
	return terrain_system.find_path_between_indices(start_index, goal_index)


func _register_living_agent(agent) -> void:
	if agent == null:
		return
	living_agents.append(agent)
	_living_agent_index_by_id[agent.id] = living_agents.size() - 1
	spatial_grid.insert(agent)
	_register_sector_presence(agent)


func _unregister_living_agent(agent) -> void:
	if agent == null:
		return
	var index := int(_living_agent_index_by_id.get(agent.id, -1))
	if index != -1:
		var last_index := living_agents.size() - 1
		var last_agent = living_agents[last_index]
		living_agents[index] = last_agent
		living_agents.remove_at(last_index)
		_living_agent_index_by_id.erase(agent.id)
		if last_agent != null and last_agent != agent:
			_living_agent_index_by_id[last_agent.id] = index
	spatial_grid.remove(agent)
	_unregister_sector_presence(agent)


func _track_agent_runtime_position(agent, previous_position: Vector2) -> void:
	if agent == null or not agent.is_alive:
		return
	var started_at_usec := Time.get_ticks_usec()
	spatial_grid.update_agent(agent, previous_position)
	_update_agent_sector(agent)
	performance_counters["spatial_update_ms"] += float(Time.get_ticks_usec() - started_at_usec) / 1000.0


func _get_sector_key(position: Vector2) -> Vector2i:
	return Vector2i(floori(position.x / _sector_size), floori(position.y / _sector_size))


func _sector_key_to_rect(sector_key: Vector2i) -> Rect2:
	return Rect2(Vector2(sector_key.x, sector_key.y) * _sector_size, Vector2.ONE * _sector_size)


func _get_or_create_sector_state(sector_key: Vector2i) -> Dictionary:
	if not _sector_states.has(sector_key):
		_sector_states[sector_key] = {
			"agent_ids": [],
			"herbivore_count": 0,
			"predator_count": 0,
			"dormant_count": 0,
			"carcass_ids": [],
			"water": false,
			"threat_score": 0.0,
			"dirty_grass": true,
			"last_grass_refresh_tick": -9999,
			"last_active_tick": current_tick,
			"dormant": false,
			"dormant_elapsed": 0.0,
			"dormant_records": [],
			"dormant_species": {},
		}
	return _sector_states[sector_key]


func _register_sector_presence(agent) -> void:
	if agent == null:
		return
	var sector_key := _get_sector_key(agent.position)
	_agent_sector_cells[agent.id] = sector_key
	var sector_state: Dictionary = _get_or_create_sector_state(sector_key)
	var agent_ids: Array = sector_state.get("agent_ids", [])
	if not agent_ids.has(agent.id):
		agent_ids.append(agent.id)
	sector_state["agent_ids"] = agent_ids
	if agent.species_type == AgentBaseScript.SPECIES_HERBIVORE:
		sector_state["herbivore_count"] = int(sector_state.get("herbivore_count", 0)) + 1
	else:
		sector_state["predator_count"] = int(sector_state.get("predator_count", 0)) + 1
		sector_state["threat_score"] = float(sector_state.get("threat_score", 0.0)) + 1.0
	sector_state["water"] = sector_state.get("water", false) or _sector_has_water(sector_key)
	sector_state["dirty_grass"] = true
	sector_state["last_active_tick"] = current_tick
	_sector_states[sector_key] = sector_state


func _unregister_sector_presence(agent) -> void:
	if agent == null:
		return
	var sector_key: Variant = _agent_sector_cells.get(agent.id, null)
	if sector_key == null:
		return
	var sector_state: Dictionary = _sector_states.get(sector_key, {})
	if not sector_state.is_empty():
		var agent_ids: Array = sector_state.get("agent_ids", [])
		agent_ids.erase(agent.id)
		sector_state["agent_ids"] = agent_ids
		if agent.species_type == AgentBaseScript.SPECIES_HERBIVORE:
			sector_state["herbivore_count"] = maxi(0, int(sector_state.get("herbivore_count", 0)) - 1)
		else:
			sector_state["predator_count"] = maxi(0, int(sector_state.get("predator_count", 0)) - 1)
			sector_state["threat_score"] = maxf(0.0, float(sector_state.get("threat_score", 0.0)) - 1.0)
		sector_state["dirty_grass"] = true
		if agent_ids.is_empty() and not bool(sector_state.get("water", false)) and not bool(sector_state.get("dormant", false)):
			_sector_states.erase(sector_key)
		else:
			_sector_states[sector_key] = sector_state
	_agent_sector_cells.erase(agent.id)


func _update_agent_sector(agent) -> void:
	if agent == null:
		return
	var previous_key: Variant = _agent_sector_cells.get(agent.id, null)
	var next_key := _get_sector_key(agent.position)
	if previous_key == null:
		_register_sector_presence(agent)
		return
	if previous_key == next_key:
		return
	_unregister_sector_presence(agent)
	_register_sector_presence(agent)
	performance_counters["sector_wakeups"] += 1


func _sector_has_water(sector_key: Vector2i) -> bool:
	var sector_rect := _sector_key_to_rect(sector_key)
	for source in water_sources:
		if sector_rect.grow(float(source.get("radius", 0.0))).has_point(source["position"]):
			return true
	return false


func _rebuild_group_state_cache() -> void:
	_group_state_cache.clear()
	for agent in living_agents:
		if agent == null or not agent.is_alive:
			continue
		if agent.group_id == -1:
			continue
		var cache_key := "%s:%d" % [agent.species_type, agent.group_id]
		var group_state: Dictionary = _group_state_cache.get(cache_key, {
			"count": 0,
			"sum": Vector2.ZERO,
			"center": null,
		})
		group_state["count"] = int(group_state.get("count", 0)) + 1
		var running_sum: Vector2 = group_state.get("sum", Vector2.ZERO)
		group_state["sum"] = running_sum + agent.position
		_group_state_cache[cache_key] = group_state
	for cache_key in _group_state_cache.keys():
		var group_state: Dictionary = _group_state_cache[cache_key]
		var count: int = int(group_state.get("count", 0))
		if count > 0:
			var total_sum: Vector2 = group_state.get("sum", Vector2.ZERO)
			group_state["center"] = total_sum / float(count)
		_group_state_cache[cache_key] = group_state


func _mark_grass_sector_dirty_by_index(index: int) -> void:
	if index < 0 or resource_system == null:
		return
	var sector_key := _get_sector_key(resource_system.get_cell_center(index))
	var sector_state: Dictionary = _get_or_create_sector_state(sector_key)
	sector_state["dirty_grass"] = true
	_sector_states[sector_key] = sector_state
	_sector_grass_cache.erase(sector_key)


func _get_sector_best_grass(sector_key: Vector2i, min_biomass: float) -> Dictionary:
	var sector_state: Dictionary = _get_or_create_sector_state(sector_key)
	var cache_entry: Dictionary = _sector_grass_cache.get(sector_key, {})
	var is_stale := cache_entry.is_empty() \
		or bool(sector_state.get("dirty_grass", false)) \
		or current_tick - int(sector_state.get("last_grass_refresh_tick", -9999)) >= _sector_grass_refresh_ticks \
		or float(cache_entry.get("biomass", 0.0)) < min_biomass
	if is_stale:
		var sector_rect := _sector_key_to_rect(sector_key)
		var best: Dictionary = resource_system.find_best_cell(sector_rect.get_center(), maxf(sector_rect.size.x, sector_rect.size.y) * 0.75, min_biomass)
		_sector_grass_cache[sector_key] = best
		sector_state["dirty_grass"] = false
		sector_state["last_grass_refresh_tick"] = current_tick
		_sector_states[sector_key] = sector_state
		return best
	return cache_entry


func _find_sector_grass_candidate(position: Vector2, radius: float, min_biomass: float) -> Dictionary:
	var center_sector := _get_sector_key(position)
	var sector_radius := maxi(1, int(ceil(radius / _sector_size)))
	var best := {}
	var best_score := -INF
	for x in range(center_sector.x - sector_radius, center_sector.x + sector_radius + 1):
		for y in range(center_sector.y - sector_radius, center_sector.y + sector_radius + 1):
			var sector_key := Vector2i(x, y)
			var candidate := _get_sector_best_grass(sector_key, min_biomass)
			if candidate.is_empty():
				continue
			var candidate_index := int(candidate.get("index", -1))
			if candidate_index == -1 or not terrain_system.is_walkable_index(candidate_index):
				continue
			var score := float(candidate.get("biomass", 0.0)) - position.distance_to(candidate.get("center", position)) * 0.14
			if score > best_score:
				best = candidate.duplicate(true)
				best_score = score
	return best


func _resolve_sector_lod_tier(sector_key: Vector2i, lod_context: Dictionary) -> int:
	if not bool(lod_context.get("enabled", false)):
		return LOD_TIER_0
	var focus_rect: Rect2 = lod_context.get("focus_rect", Rect2())
	if focus_rect.size.is_zero_approx():
		var headless_radius := float(lod_context.get("headless_active_radius", 0.0))
		if headless_radius <= 0.0:
			return LOD_TIER_0
		var world_center := bounds.get_center()
		focus_rect = Rect2(world_center - Vector2.ONE * headless_radius, Vector2.ONE * headless_radius * 2.0)
	var sector_origin := _sector_key_to_rect(sector_key).get_center()
	if focus_rect.grow(float(lod_context.get("near_margin", 0.0))).has_point(sector_origin):
		return LOD_TIER_0
	if focus_rect.grow(float(lod_context.get("mid_margin", 0.0))).has_point(sector_origin):
		return LOD_TIER_1
	return LOD_TIER_2


func _wake_relevant_dormant_sectors(lod_context: Dictionary) -> void:
	var sectors_to_wake: Array = []
	for sector_key in _sector_states.keys():
		var sector_state: Dictionary = _sector_states[sector_key]
		if not bool(sector_state.get("dormant", false)):
			continue
		if _resolve_sector_lod_tier(sector_key, lod_context) != LOD_TIER_2:
			sectors_to_wake.append(sector_key)
			continue
		var selected_agent_id := int(lod_context.get("selected_agent_id", -1))
		if selected_agent_id != -1 and _dormant_sector_has_agent(sector_state, selected_agent_id):
			sectors_to_wake.append(sector_key)
			continue
		if _dormant_sector_should_wake_for_neighboring_threat(sector_key, lod_context):
			sectors_to_wake.append(sector_key)
	for sector_key in sectors_to_wake:
		_wake_sector(sector_key)


func _sleep_far_sectors(lod_context: Dictionary) -> void:
	var sectors_to_sleep: Array = []
	for sector_key in _sector_states.keys():
		var sector_state: Dictionary = _sector_states[sector_key]
		if bool(sector_state.get("dormant", false)):
			continue
		if _resolve_sector_lod_tier(sector_key, lod_context) != LOD_TIER_2:
			sector_state["last_active_tick"] = current_tick
			_sector_states[sector_key] = sector_state
			continue
		if _can_sleep_sector(sector_key, lod_context):
			sectors_to_sleep.append(sector_key)
	for sector_key in sectors_to_sleep:
		_sleep_sector(sector_key)


func _step_dormant_sectors(delta: float, lod_context: Dictionary) -> void:
	for sector_key in _sector_states.keys():
		var sector_state: Dictionary = _sector_states[sector_key]
		if not bool(sector_state.get("dormant", false)):
			continue
		sector_state["dormant_elapsed"] = float(sector_state.get("dormant_elapsed", 0.0)) + delta
		if float(sector_state.get("dormant_elapsed", 0.0)) < _very_far_sector_step_seconds:
			_sector_states[sector_key] = sector_state
			continue
		var step_seconds := float(sector_state.get("dormant_elapsed", 0.0))
		sector_state["dormant_elapsed"] = 0.0
		_apply_dormant_sector_step(sector_key, sector_state, step_seconds)
		_sector_states[sector_key] = sector_state
		if _resolve_sector_lod_tier(sector_key, lod_context) != LOD_TIER_2:
			_wake_sector(sector_key)


func _can_sleep_sector(sector_key: Vector2i, lod_context: Dictionary) -> bool:
	var sector_state: Dictionary = _sector_states.get(sector_key, {})
	if sector_state.is_empty():
		return false
	if not sector_state.get("carcass_ids", []).is_empty():
		return false
	for agent_id in sector_state.get("agent_ids", []):
		if int(agent_id) == int(lod_context.get("selected_agent_id", -1)):
			return false
		var agent = get_agent(int(agent_id))
		if agent == null or not agent.is_alive:
			continue
		if _resolve_lod_tier(agent, lod_context) != LOD_TIER_2:
			return false
		if _is_priority_lod_agent(agent):
			return false
	return not sector_state.get("agent_ids", []).is_empty()


func _sleep_sector(sector_key: Vector2i) -> void:
	var sector_state: Dictionary = _sector_states.get(sector_key, {})
	if sector_state.is_empty() or bool(sector_state.get("dormant", false)):
		return
	var records: Array = []
	var active_ids: Array = sector_state.get("agent_ids", []).duplicate()
	for agent_id in active_ids:
		var agent = get_agent(int(agent_id))
		if agent == null or not agent.is_alive:
			continue
		records.append(agent.export_runtime_state())
		_unregister_living_agent(agent)
		agents.erase(agent.id)
	sector_state = _get_or_create_sector_state(sector_key)
	sector_state["dormant"] = true
	sector_state["dormant_records"] = records
	sector_state["dormant_elapsed"] = 0.0
	sector_state["dormant_species"] = _build_dormant_species_state(records)
	sector_state["dormant_count"] = records.size()
	sector_state["agent_ids"] = []
	_sector_states[sector_key] = sector_state


func _wake_sector(sector_key: Vector2i) -> void:
	var sector_state: Dictionary = _sector_states.get(sector_key, {})
	if sector_state.is_empty() or not bool(sector_state.get("dormant", false)):
		return
	var records: Array = _materialize_dormant_records(sector_state)
	for record in records:
		var agent = _restore_dormant_agent(record)
		if agent != null:
			_register_living_agent(agent)
	sector_state["dormant"] = false
	sector_state["dormant_records"] = []
	sector_state["dormant_species"] = {}
	sector_state["dormant_count"] = 0
	sector_state["dormant_elapsed"] = 0.0
	sector_state["last_active_tick"] = current_tick
	_sector_states[sector_key] = sector_state
	performance_counters["sector_wakeups"] += 1


func _build_dormant_species_state(records: Array) -> Dictionary:
	var species_state: Dictionary = {}
	for record in records:
		var species_key := str(record.get("species_type", ""))
		var entry: Dictionary = species_state.get(species_key, {
			"count": 0,
			"avg_hunger": 0.0,
			"avg_thirst": 0.0,
			"avg_energy": 0.0,
			"avg_age": 0.0,
		})
		entry["count"] = int(entry.get("count", 0)) + 1
		entry["avg_hunger"] = float(entry.get("avg_hunger", 0.0)) + float(record.get("hunger", 0.0))
		entry["avg_thirst"] = float(entry.get("avg_thirst", 0.0)) + float(record.get("thirst", 0.0))
		entry["avg_energy"] = float(entry.get("avg_energy", 0.0)) + float(record.get("energy", 0.0))
		entry["avg_age"] = float(entry.get("avg_age", 0.0)) + float(record.get("age", 0.0))
		species_state[species_key] = entry
	for species_key in species_state.keys():
		var entry: Dictionary = species_state[species_key]
		var count: int = int(entry.get("count", 0))
		if count > 0:
			entry["avg_hunger"] = float(entry.get("avg_hunger", 0.0)) / count
			entry["avg_thirst"] = float(entry.get("avg_thirst", 0.0)) / count
			entry["avg_energy"] = float(entry.get("avg_energy", 0.0)) / count
			entry["avg_age"] = float(entry.get("avg_age", 0.0)) / count
		species_state[species_key] = entry
	return species_state


func _apply_dormant_sector_step(sector_key: Vector2i, sector_state: Dictionary, elapsed: float) -> void:
	var dormant_species: Dictionary = sector_state.get("dormant_species", {})
	if dormant_species.is_empty():
		return
	var predator_count := int(dormant_species.get(AgentBaseScript.SPECIES_PREDATOR, {}).get("count", 0))
	var herbivore_count := int(dormant_species.get(AgentBaseScript.SPECIES_HERBIVORE, {}).get("count", 0))
	for species_key in dormant_species.keys():
		var species_config: Dictionary = config_bundle.get("species", {}).get(species_key, {})
		var metabolism: Dictionary = species_config.get("metabolism", {})
		var aging: Dictionary = species_config.get("aging", {})
		var entry: Dictionary = dormant_species[species_key]
		var count: int = int(entry.get("count", 0))
		if count <= 0:
			continue
		var avg_hunger := minf(100.0, float(entry.get("avg_hunger", 0.0)) + float(metabolism.get("hunger_rate", 2.0)) * elapsed)
		var avg_thirst := minf(100.0, float(entry.get("avg_thirst", 0.0)) + float(metabolism.get("thirst_rate", 2.0)) * elapsed)
		var avg_energy := maxf(0.0, float(entry.get("avg_energy", 0.0)) - float(metabolism.get("energy_decay", 2.0)) * elapsed)
		var critical_thirst := float(config_bundle.get("balance", {}).get("state_thresholds", {}).get("critical_thirst", 65.0))
		if avg_thirst >= critical_thirst:
			avg_energy = maxf(0.0, avg_energy - float(metabolism.get("dehydration_energy_penalty", 4.0)) * elapsed)
		var avg_age := float(entry.get("avg_age", 0.0)) + elapsed
		var starvation_deaths := 0
		var thirst_deaths := 0
		var old_age_deaths := 0
		var predation_deaths := 0
		if avg_hunger >= 98.0:
			starvation_deaths = maxi(1, int(ceil(float(count) * clampf((avg_hunger - 98.0) / 2.0, 0.05, 0.35))))
		if avg_thirst >= 98.0:
			thirst_deaths = maxi(1, int(ceil(float(count) * clampf((avg_thirst - 98.0) / 2.0, 0.05, 0.35))))
		var old_age_start := float(aging.get("old_age_start", aging.get("max_age", 9999.0)))
		var max_age := float(aging.get("max_age", 9999.0))
		if avg_age >= max_age:
			old_age_deaths = maxi(1, int(ceil(float(count) * 0.2)))
		elif avg_age >= old_age_start:
			old_age_deaths = int(round(float(count) * float(aging.get("old_age_death_chance_per_second", 0.0)) * elapsed))
		if species_key == AgentBaseScript.SPECIES_HERBIVORE and predator_count > 0 and herbivore_count > 0:
			var predation_pressure := clampf(float(predator_count) / maxf(1.0, float(herbivore_count)), 0.0, 0.45)
			predation_deaths = int(round(float(count) * predation_pressure * elapsed * 0.18))
		var total_deaths := mini(count, starvation_deaths + thirst_deaths + old_age_deaths + predation_deaths)
		count = maxi(0, count - total_deaths)
		entry["count"] = count
		entry["avg_hunger"] = avg_hunger
		entry["avg_thirst"] = avg_thirst
		entry["avg_energy"] = avg_energy
		entry["avg_age"] = avg_age
		dormant_species[species_key] = entry
	var births := _compute_dormant_sector_births(sector_state, dormant_species, elapsed)
	_apply_dormant_births(sector_state, births)
	_apply_dormant_deaths_to_records(sector_state)
	_apply_dormant_grass_pressure(sector_key, sector_state, elapsed)
	sector_state["dormant_species"] = _build_dormant_species_state(sector_state.get("dormant_records", []))
	sector_state["dormant_count"] = sector_state.get("dormant_records", []).size()
	sector_state["herbivore_count"] = int(sector_state.get("dormant_species", {}).get(AgentBaseScript.SPECIES_HERBIVORE, {}).get("count", 0))
	sector_state["predator_count"] = int(sector_state.get("dormant_species", {}).get(AgentBaseScript.SPECIES_PREDATOR, {}).get("count", 0))
	sector_state["threat_score"] = float(sector_state["predator_count"])


func _compute_dormant_sector_births(sector_state: Dictionary, dormant_species: Dictionary, elapsed: float) -> Dictionary:
	var births := {}
	for species_key in dormant_species.keys():
		var entry: Dictionary = dormant_species[species_key]
		var count: int = int(entry.get("count", 0))
		if count <= 1:
			continue
		var avg_energy := float(entry.get("avg_energy", 0.0))
		var avg_hunger := float(entry.get("avg_hunger", 0.0))
		var reproduction_config: Dictionary = config_bundle.get("species", {}).get(species_key, {}).get("reproduction", {})
		var energy_threshold := float(reproduction_config.get("energy_threshold", 9999.0))
		if avg_energy < energy_threshold or avg_hunger > 35.0:
			continue
		var birth_chance := clampf((avg_energy - energy_threshold) / maxf(1.0, energy_threshold), 0.0, 0.35) * elapsed * 0.15
		var birth_count := int(round(float(count) * birth_chance))
		if birth_count > 0:
			births[species_key] = birth_count
	return births


func _apply_dormant_births(sector_state: Dictionary, births: Dictionary) -> void:
	if births.is_empty():
		return
	var records: Array = sector_state.get("dormant_records", [])
	for species_key in births.keys():
		var template = _find_dormant_record_template(records, species_key)
		if template.is_empty():
			continue
		for _index in range(int(births[species_key])):
			var record: Dictionary = template.duplicate(true)
			record["id"] = next_agent_id
			next_agent_id += 1
			record["age"] = 0.0
			record["hunger"] = 4.0
			record["thirst"] = 4.0
			record["energy"] = float(config_bundle.get("species", {}).get(species_key, {}).get("metabolism", {}).get("max_energy", 100.0)) * 0.7
			record["position"] = _sector_key_to_rect(_get_sector_key(record.get("position", bounds.get_center()))).get_center() + random_unit_vector() * 8.0
			record["velocity"] = Vector2.ZERO
			record["target_agent_id"] = -1
			record["target_position"] = null
			record["current_action"] = "none"
			record["state"] = "idle"
			record["ai_state"] = "alive"
			record["sex"] = _random_sex()
			records.append(record)
	sector_state["dormant_records"] = records


func _apply_dormant_deaths_to_records(sector_state: Dictionary) -> void:
	var records: Array = sector_state.get("dormant_records", [])
	var species_targets: Dictionary = {}
	for species_key in sector_state.get("dormant_species", {}).keys():
		species_targets[species_key] = int(sector_state.get("dormant_species", {})[species_key].get("count", 0))
	var by_species: Dictionary = {}
	for record in records:
		var species_key := str(record.get("species_type", ""))
		if not by_species.has(species_key):
			by_species[species_key] = []
		by_species[species_key].append(record)
	var next_records: Array = []
	for species_key in by_species.keys():
		var target_count := int(species_targets.get(species_key, 0))
		var bucket: Array = by_species[species_key]
		if bucket.size() <= target_count:
			next_records.append_array(bucket)
			continue
		bucket.sort_custom(func(a, b): return int(a.get("id", -1)) < int(b.get("id", -1)))
		for index in range(target_count):
			next_records.append(bucket[index])
	sector_state["dormant_records"] = next_records


func _apply_dormant_grass_pressure(sector_key: Vector2i, sector_state: Dictionary, elapsed: float) -> void:
	var herbivore_count := int(sector_state.get("dormant_species", {}).get(AgentBaseScript.SPECIES_HERBIVORE, {}).get("count", 0))
	if herbivore_count <= 0:
		return
	var grass_target := _get_sector_best_grass(sector_key, 0.0)
	if grass_target.is_empty():
		return
	var consumption := float(herbivore_count) * elapsed * 0.9
	consume_grass_cell(int(grass_target.get("index", -1)), consumption)


func _find_dormant_record_template(records: Array, species_key: String) -> Dictionary:
	for record in records:
		if str(record.get("species_type", "")) == species_key:
			return record
	return {}


func _materialize_dormant_records(sector_state: Dictionary) -> Array:
	var records: Array = sector_state.get("dormant_records", []).duplicate(true)
	var dormant_species: Dictionary = sector_state.get("dormant_species", {})
	for species_key in dormant_species.keys():
		var species_records: Array = []
		for record in records:
			if str(record.get("species_type", "")) == species_key:
				species_records.append(record)
		var entry: Dictionary = dormant_species[species_key]
		for record in species_records:
			record["hunger"] = float(entry.get("avg_hunger", record.get("hunger", 0.0)))
			record["thirst"] = float(entry.get("avg_thirst", record.get("thirst", 0.0)))
			record["energy"] = float(entry.get("avg_energy", record.get("energy", 0.0)))
			record["age"] = float(entry.get("avg_age", record.get("age", 0.0)))
	return records


func _restore_dormant_agent(record: Dictionary):
	var species_type := str(record.get("species_type", ""))
	var agent = _create_agent(species_type)
	if agent == null:
		return null
	var species_config: Dictionary = config_bundle.get("species", {}).get(species_type, {})
	var record_id := int(record.get("id", next_agent_id))
	agent.configure(
		record_id,
		species_type,
		Vector2(record.get("position", bounds.get_center())),
		str(record.get("sex", _random_sex())),
		species_config,
		config_bundle.get("balance", {}),
		rng,
		int(record.get("group_id", -1))
	)
	agent.apply_runtime_state(record)
	agents[record_id] = agent
	next_agent_id = maxi(next_agent_id, record_id + 1)
	return agent


func _dormant_sector_has_agent(sector_state: Dictionary, agent_id: int) -> bool:
	for record in sector_state.get("dormant_records", []):
		if int(record.get("id", -1)) == agent_id:
			return true
	return false


func _dormant_sector_should_wake_for_neighboring_threat(sector_key: Vector2i, lod_context: Dictionary) -> bool:
	for x in range(sector_key.x - 1, sector_key.x + 2):
		for y in range(sector_key.y - 1, sector_key.y + 2):
			var neighbor_key := Vector2i(x, y)
			if neighbor_key == sector_key:
				continue
			var neighbor_state: Dictionary = _sector_states.get(neighbor_key, {})
			if neighbor_state.is_empty():
				continue
			if _resolve_sector_lod_tier(neighbor_key, lod_context) == LOD_TIER_2:
				continue
			if float(neighbor_state.get("threat_score", 0.0)) > 0.0 or float(_sector_states.get(sector_key, {}).get("threat_score", 0.0)) > 0.0:
				return true
	return false


func _create_agent(species_type: String):
	match species_type:
		AgentBaseScript.SPECIES_HERBIVORE:
			return HerbivoreScript.new()
		AgentBaseScript.SPECIES_PREDATOR:
			return PredatorScript.new()
		_:
			push_error("Unknown species type: %s" % species_type)
			return null


func _random_sex() -> String:
	return AgentBaseScript.SEX_MALE if rng.randf() > 0.5 else AgentBaseScript.SEX_FEMALE


func _flush_removals() -> void:
	if pending_removals.is_empty():
		return
	pending_removals.sort()
	for agent_id in pending_removals:
		var agent = agents.get(agent_id, null)
		if agent != null:
			_unregister_living_agent(agent)
		agents.erase(agent_id)
	pending_removals.clear()


func _flush_spawns() -> void:
	if pending_spawns.is_empty():
		return
	for request in pending_spawns:
		var child = spawn_agent(
			request["species"],
			request["position"],
			int(request["group_id"]),
			"",
			{"reason": "reproduction"}
		)
		if child == null:
			continue
		if child.species_type == AgentBaseScript.SPECIES_PREDATOR:
			for parent_key in ["parent_a_id", "parent_b_id"]:
				var parent_id := int(request[parent_key])
				var parent = get_agent(parent_id)
				if parent == null or not parent.is_alive or parent.species_type != AgentBaseScript.SPECIES_PREDATOR:
					continue
				if child.has_method("add_kin_id"):
					child.call("add_kin_id", parent_id)
				if parent.has_method("add_kin_id"):
					parent.call("add_kin_id", child.id)
		emit_event("AgentReproduced", child, int(request["parent_a_id"]), {
			"parent_a_id": int(request["parent_a_id"]),
			"parent_b_id": int(request["parent_b_id"]),
		})
	pending_spawns.clear()


func _sanitize_variant(value):
	match typeof(value):
		TYPE_VECTOR2:
			return {"x": value.x, "y": value.y}
		TYPE_VECTOR2I:
			return {"x": value.x, "y": value.y}
		TYPE_DICTIONARY:
			var sanitized: Dictionary = {}
			for key in value.keys():
				sanitized[key] = _sanitize_variant(value[key])
			return sanitized
		TYPE_ARRAY:
			var sanitized_array: Array = []
			for item in value:
				sanitized_array.append(_sanitize_variant(item))
			return sanitized_array
		_:
			return value


func _rebuild_living_agents_cache() -> void:
	_living_agent_index_by_id.clear()
	for index in range(living_agents.size()):
		var agent = living_agents[index]
		if agent == null or not agent.is_alive:
			continue
		_living_agent_index_by_id[agent.id] = index


func _cell_distance(from_index: int, to_index: int) -> float:
	if terrain_system == null:
		return 0.0
	var from_coords: Vector2i = terrain_system.get_cell_coords(from_index)
	var to_coords: Vector2i = terrain_system.get_cell_coords(to_index)
	return Vector2(float(from_coords.x), float(from_coords.y)).distance_to(
		Vector2(float(to_coords.x), float(to_coords.y))
	)
