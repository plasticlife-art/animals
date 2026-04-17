class_name WorldState
extends RefCounted

const HerbivoreScript = preload("res://scripts/agents/herbivore.gd")
const PredatorScript = preload("res://scripts/agents/predator.gd")
const AgentBaseScript = preload("res://scripts/agents/agent_base.gd")
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
var current_tick: int = 0
var current_time: float = 0.0
var living_agents: Array = []
var lod_counts := {
	"lod0_agents": 0,
	"lod1_agents": 0,
	"lod2_agents": 0,
}


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

	spatial_grid = SpatialGridScript.new()
	spatial_grid.configure(float(world_config.get("spatial_cell_size", 96.0)))

	living_agents.clear()
	_spawn_initial_agents()
	_rebuild_living_agents_cache()
	spatial_grid.rebuild(living_agents)
	_update_lod_assignments({"enabled": false})


func step(delta: float, tick: int, time_seconds: float, lod_context: Dictionary = {}) -> void:
	current_tick = tick
	current_time = time_seconds
	resource_system.step(delta)
	var active_lod_context: Dictionary = _normalize_lod_context(lod_context)

	for agent in living_agents:
		if agent == null or not agent.is_alive:
			continue
		var lod_tier: int = _resolve_lod_tier(agent, active_lod_context)
		agent.lod_tier = lod_tier
		if _should_run_full_tick(agent, lod_tier, active_lod_context):
			agent.tick(self, delta)
		else:
			agent.tick_maintenance(self, delta)

	_flush_removals()
	_flush_spawns()
	_step_carcasses(delta)
	_flush_carcass_removals()
	_rebuild_living_agents_cache()
	spatial_grid.rebuild(living_agents)
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
	living_agents.append(agent)
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


func get_lod_counts() -> Dictionary:
	return lod_counts.duplicate(true)


func get_active_carcass_count() -> int:
	return carcasses.size()


func get_total_carcass_meat_remaining() -> float:
	var total := 0.0
	for carcass in carcasses.values():
		total += float(carcass.get("meat_remaining", 0.0))
	return total


func refresh_lod_assignments(lod_context: Dictionary = {}) -> void:
	_update_lod_assignments(_normalize_lod_context(lod_context))


func query_agents(position: Vector2, radius: float, species_filter: String = "", exclude_id: int = -1) -> Array:
	return spatial_grid.query(position, radius, species_filter, exclude_id)


func query_grass_cells(position: Vector2, radius: float, min_biomass: float = 0.0) -> Dictionary:
	return find_reachable_grass(position, radius, min_biomass)


func query_water_sources(position: Vector2, radius: float) -> Array:
	var matches: Array = []
	for source in water_sources:
		var combined_radius: float = radius + float(source.get("radius", 0.0))
		if position.distance_squared_to(source["position"]) <= combined_radius * combined_radius:
			matches.append(source)
	return matches


func query_carcasses(position: Vector2, radius: float) -> Array:
	var matches: Array = []
	var radius_sq := radius * radius
	for carcass in carcasses.values():
		if not _is_carcass_available(carcass):
			continue
		if position.distance_squared_to(carcass["position"]) > radius_sq:
			continue
		matches.append(carcass.duplicate(true))
	return matches


func get_carcass(carcass_id: int) -> Dictionary:
	var carcass: Dictionary = carcasses.get(carcass_id, {})
	if carcass.is_empty() or not _is_carcass_available(carcass):
		return {}
	return carcass.duplicate(true)


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
			return carcass.duplicate(true)
	return {}


func get_group_center(group_id: int, species_type: String, exclude_id: int = -1):
	var center: Vector2 = Vector2.ZERO
	var count: int = 0
	for agent in living_agents:
		if agent == null or not agent.is_alive:
			continue
		if agent.id == exclude_id or agent.group_id != group_id or agent.species_type != species_type:
			continue
		center += agent.position
		count += 1
	if count <= 0:
		return null
	return center / count


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


func find_reachable_grass(position: Vector2, radius: float, min_biomass: float = 0.0) -> Dictionary:
	if terrain_system == null:
		return resource_system.find_best_cell(position, radius, min_biomass)

	var start_index: int = terrain_system.find_nearest_walkable_index(terrain_system.get_index_from_position(position))
	if start_index == -1:
		return {}

	var candidate_limit: int = maxi(4, int(navigation_config.get("grass_candidate_limit", 12)))
	var candidates: Array = resource_system.query_cells(position, radius)
	var shortlisted: Array = []
	for candidate in candidates:
		if float(candidate.get("biomass", 0.0)) < min_biomass:
			continue
		var candidate_index: int = int(candidate.get("index", -1))
		if candidate_index == -1 or not terrain_system.is_walkable_index(candidate_index):
			continue
		var candidate_center: Vector2 = candidate.get("center", position)
		var heuristic_score: float = float(candidate.get("biomass", 0.0)) - position.distance_to(candidate_center) * 0.14
		var shortlisted_candidate: Dictionary = candidate.duplicate(true)
		shortlisted_candidate["heuristic_score"] = heuristic_score
		shortlisted.append(shortlisted_candidate)
	shortlisted.sort_custom(func(a, b): return a["heuristic_score"] > b["heuristic_score"])

	var best: Dictionary = {}
	var best_score: float = -INF
	var best_cost: float = INF
	var evaluated: int = 0
	for candidate in shortlisted:
		if evaluated >= candidate_limit:
			break
		var candidate_index: int = int(candidate.get("index", -1))
		evaluated += 1

		var path_result: Dictionary = terrain_system.find_path_between_indices(start_index, candidate_index)
		var path_cells: Array = path_result.get("cells", [])
		if path_cells.is_empty():
			continue

		var path_cost: float = float(path_result.get("cost", INF))
		var score: float = float(candidate.get("biomass", 0.0)) - path_cost * 0.12
		if not bool(path_result.get("reachable", false)):
			score -= 20.0

		if score > best_score or (is_equal_approx(score, best_score) and path_cost < best_cost):
			best = candidate.duplicate(true)
			best["path_cost"] = path_cost
			best["reachable"] = bool(path_result.get("reachable", false))
			best["path_cells"] = path_cells
			best["score"] = score
			best_score = score
			best_cost = path_cost
	return best


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
		var path_result: Dictionary = terrain_system.find_path_between_indices(start_index, goal_index)
		var path_cells: Array = path_result.get("cells", [])
		agent.path_cells = path_cells.duplicate()
		agent.path_goal_cell = goal_index
		agent.last_repath_tick = current_tick
		agent.path_index = 1 if agent.path_cells.size() > 1 else agent.path_cells.size()
		if agent.path_cells.is_empty():
			return from_position

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
			var path_result: Dictionary = terrain_system.find_path_between_indices(start_index, candidate_index)
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
	context["near_margin"] = maxf(0.0, float(context.get("near_margin", 0.0)))
	context["mid_margin"] = maxf(float(context.get("near_margin", 0.0)), float(context.get("mid_margin", 0.0)))
	context["mid_update_interval_ticks"] = maxi(1, int(context.get("mid_update_interval_ticks", 2)))
	context["far_update_interval_ticks"] = maxi(1, int(context.get("far_update_interval_ticks", 5)))
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
		return LOD_TIER_0

	if focus_rect.grow(float(lod_context.get("near_margin", 0.0))).has_point(agent.position):
		return LOD_TIER_0
	if focus_rect.grow(float(lod_context.get("mid_margin", 0.0))).has_point(agent.position):
		return LOD_TIER_1
	return LOD_TIER_2


func _is_priority_lod_agent(agent: AgentBase) -> bool:
	return agent.target_agent_id != -1 \
		or agent.interaction_timer > 0.0 \
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
	var next_living_agents: Array = []
	for agent in living_agents:
		if agent != null and agent.is_alive:
			next_living_agents.append(agent)
	living_agents = next_living_agents


func _cell_distance(from_index: int, to_index: int) -> float:
	if terrain_system == null:
		return 0.0
	var from_coords: Vector2i = terrain_system.get_cell_coords(from_index)
	var to_coords: Vector2i = terrain_system.get_cell_coords(to_index)
	return Vector2(float(from_coords.x), float(from_coords.y)).distance_to(
		Vector2(float(to_coords.x), float(to_coords.y))
	)
