class_name WorldState
extends RefCounted

const HerbivoreScript = preload("res://scripts/agents/herbivore.gd")
const PredatorScript = preload("res://scripts/agents/predator.gd")
const AgentBaseScript = preload("res://scripts/agents/agent_base.gd")
const ResourceSystemScript = preload("res://scripts/world/resource_system.gd")
const SpatialGridScript = preload("res://scripts/world/spatial_grid.gd")

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
}

var bounds: Rect2 = Rect2(0.0, 0.0, 1600.0, 900.0)
var agents: Dictionary = {}
var pending_spawns: Array = []
var pending_removals: Array = []
var water_sources: Array = []
var next_agent_id: int = 1
var config_bundle: Dictionary = {}
var event_bus
var rng: RandomNumberGenerator
var resource_system: ResourceSystem
var spatial_grid: SpatialGrid
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
	pending_spawns.clear()
	pending_removals.clear()
	next_agent_id = 1

	var world_config: Dictionary = config_bundle.get("world", {})
	var world_size_config: Dictionary = world_config.get("world_size", {})
	bounds = Rect2(
		0.0,
		0.0,
		float(world_size_config.get("x", 1600.0)),
		float(world_size_config.get("y", 900.0))
	)

	resource_system = ResourceSystemScript.new()
	resource_system.initialize(world_config, rng)

	spatial_grid = SpatialGridScript.new()
	spatial_grid.configure(float(world_config.get("spatial_cell_size", 96.0)))

	water_sources.clear()
	for source in world_config.get("water_sources", []):
		water_sources.append({
			"position": Vector2(float(source.get("x", 0.0)), float(source.get("y", 0.0))),
			"radius": float(source.get("radius", 48.0)),
		})

	living_agents.clear()
	_spawn_initial_agents()
	_rebuild_living_agents_cache()
	spatial_grid.rebuild(living_agents)
	_update_lod_assignments({"enabled": false})


func step(delta: float, tick: int, time_seconds: float, lod_context: Dictionary = {}) -> void:
	current_tick = tick
	current_time = time_seconds
	resource_system.step(delta)
	var active_lod_context := _normalize_lod_context(lod_context)

	for agent in living_agents:
		if agent == null or not agent.is_alive:
			continue
		var lod_tier := _resolve_lod_tier(agent, active_lod_context)
		agent.lod_tier = lod_tier
		if _should_run_full_tick(agent, lod_tier, active_lod_context):
			agent.tick(self, delta)
		else:
			agent.tick_maintenance(self, delta)

	_flush_removals()
	_flush_spawns()
	_rebuild_living_agents_cache()
	spatial_grid.rebuild(living_agents)
	_update_lod_assignments(active_lod_context)


func spawn_agent(species_type: String, position: Vector2, group_id: int = -1, sex_override: String = "", metadata: Dictionary = {}) -> AgentBase:
	var agent = _create_agent(species_type)
	if agent == null:
		return null

	var species_config: Dictionary = config_bundle.get("species", {}).get(species_type, {})
	var sex := sex_override if sex_override != "" else _random_sex()
	agent.configure(
		next_agent_id,
		species_type,
		clamp_position(position),
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

	var reason := str(metadata.get("reason", "runtime"))
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
	agent.is_alive = false
	pending_removals.append(agent.id)

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


func refresh_lod_assignments(lod_context: Dictionary = {}) -> void:
	_update_lod_assignments(_normalize_lod_context(lod_context))


func query_agents(position: Vector2, radius: float, species_filter: String = "", exclude_id: int = -1) -> Array:
	return spatial_grid.query(position, radius, species_filter, exclude_id)


func query_grass_cells(position: Vector2, radius: float, min_biomass: float = 0.0) -> Dictionary:
	return resource_system.find_best_cell(position, radius, min_biomass)


func query_water_sources(position: Vector2, radius: float) -> Array:
	var matches: Array = []
	for source in water_sources:
		var combined_radius := radius + float(source.get("radius", 0.0))
		if position.distance_squared_to(source["position"]) <= combined_radius * combined_radius:
			matches.append(source)
	return matches


func get_group_center(group_id: int, species_type: String, exclude_id: int = -1):
	var center := Vector2.ZERO
	var count := 0
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


func clamp_position(position: Vector2) -> Vector2:
	return Vector2(
		clampf(position.x, bounds.position.x + 4.0, bounds.end.x - 4.0),
		clampf(position.y, bounds.position.y + 4.0, bounds.end.y - 4.0)
	)


func random_point() -> Vector2:
	return Vector2(
		rng.randf_range(bounds.position.x, bounds.end.x),
		rng.randf_range(bounds.position.y, bounds.end.y)
	)


func random_unit_vector() -> Vector2:
	return Vector2.RIGHT.rotated(rng.randf_range(0.0, TAU))


func emit_event(event_type: String, agent, other_agent_id: int = -1, data: Dictionary = {}) -> void:
	var payload := {
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


func _spawn_initial_agents() -> void:
	var world_config: Dictionary = config_bundle.get("world", {})
	var spawn_config: Dictionary = world_config.get("spawns", {})
	var herbivore_count := int(spawn_config.get("herbivore_count", 120))
	var predator_count := int(spawn_config.get("predator_count", 12))
	var group_count := maxi(1, int(spawn_config.get("herbivore_group_count", 8)))

	var herd_centers: Array = []
	for index in range(group_count):
		herd_centers.append(random_point())

	for index in range(herbivore_count):
		var center: Vector2 = herd_centers[index % group_count]
		var spawn_position := clamp_position(center + Vector2(rng.randf_range(-60.0, 60.0), rng.randf_range(-60.0, 60.0)))
		spawn_agent(AgentBaseScript.SPECIES_HERBIVORE, spawn_position, index % group_count, "", {"reason": "initial"})

	var predator_pair_count := maxi(1, int(ceil(float(predator_count) / 2.0)))
	var predator_centers: Array = []
	for _index in range(predator_pair_count):
		predator_centers.append(random_point())

	for pair_index in range(predator_pair_count):
		var pair_center: Vector2 = predator_centers[pair_index]
		var male_offset := Vector2(rng.randf_range(-28.0, 28.0), rng.randf_range(-28.0, 28.0))
		var female_offset := Vector2(rng.randf_range(-28.0, 28.0), rng.randf_range(-28.0, 28.0))
		var male_predator = null
		var female_predator = null

		var male_index := pair_index * 2
		if male_index < predator_count:
			male_predator = spawn_agent(
				AgentBaseScript.SPECIES_PREDATOR,
				clamp_position(pair_center + male_offset),
				-1,
				AgentBaseScript.SEX_MALE,
				{"reason": "initial"}
			)

		var female_index := male_index + 1
		if female_index < predator_count:
			female_predator = spawn_agent(
				AgentBaseScript.SPECIES_PREDATOR,
				clamp_position(pair_center + female_offset),
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
	var context := lod_context.duplicate(true)
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

	var interval_key := "mid_update_interval_ticks" if lod_tier == LOD_TIER_1 else "far_update_interval_ticks"
	var default_interval := 2 if lod_tier == LOD_TIER_1 else 5
	var interval := int(lod_context.get(interval_key, default_interval))
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
		var lod_tier := _resolve_lod_tier(agent, lod_context)
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
		emit_event("AgentReproduced", child, int(request["parent_a_id"]), {
			"parent_a_id": int(request["parent_a_id"]),
			"parent_b_id": int(request["parent_b_id"]),
		})
	pending_spawns.clear()


func _sanitize_variant(value):
	match typeof(value):
		TYPE_VECTOR2:
			return {"x": value.x, "y": value.y}
		TYPE_DICTIONARY:
			var sanitized := {}
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
