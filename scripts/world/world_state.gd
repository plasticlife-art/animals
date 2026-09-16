class_name WorldState
extends RefCounted

# Agents are dispatched through `SpeciesRegistry`, from the `role.script` path in
# species.json, so no branch here names a species any more. This table is not
# dispatch - it is linkage, and every species script has to appear in it.
#
# A path read out of JSON is not a static dependency, so without an entry here the
# script is resolved by `load()` at run time. That is late enough to race: the
# interactive worker builds a second `WorldState` on its own thread, and a class
# still being compiled when the other side reaches it resolves to a half-built
# base. The symptom is not a missing file but `super.export_runtime_state()`
# reporting no such function, `Steering.wander` vanishing, and a `Scavenger` that
# answers to none of `AgentBase` - intermittently, a different set each run.
# It also gives an export build a reason to package the scripts at all.
const HerbivoreScript = preload("res://scripts/agents/herbivore.gd")
const PredatorScript = preload("res://scripts/agents/predator.gd")
const ScavengerScript = preload("res://scripts/agents/scavenger.gd")
const AgentBaseScript = preload("res://scripts/agents/agent_base.gd")
const AgentPerceptionSnapshotScript = preload("res://scripts/agents/agent_perception_snapshot.gd")
const ResourceSystemScript = preload("res://scripts/world/resource_system.gd")
const ClimateScript = preload("res://scripts/world/climate.gd")
const SpatialGridScript = preload("res://scripts/world/spatial_grid.gd")
const SpeciesRegistryScript = preload("res://scripts/core/species_registry.gd")
const TerrainSystemScript = preload("res://scripts/world/terrain_system.gd")

const LOD_TIER_0 := 0
const LOD_TIER_1 := 1
const LOD_TIER_2 := 2
const LOD_PRIORITY_STATES := {
	"flee": true,
	"seek_prey": true,
	"chase": true,
	"search_last_seen": true,
	"attack": true,
	"reproduce": true,
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
var scenery = preload("res://scripts/world/scenery_system.gd").new()
var _local_path_budget: int = 6
var inspected_agent_id: int = -1
var config_bundle: Dictionary = {}
var event_bus
var rng: RandomNumberGenerator
var terrain_system: TerrainSystem
var resource_system: ResourceSystem
var climate: Climate
var spatial_grid: SpatialGrid
## Which species exist and what each one eats, is eaten by, and leaves behind.
## Immutable once built, so the worker thread's world and the presentation copy
## can each hold one. See scripts/core/species_registry.gd.
var species_registry
## Derived from the registry at initialize() so the tick never walks roles.
var _prey_species_ids: Array = []
var _threat_species_ids: Array = []
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
var _prey_pressure_sectors: Array = []
var _prey_pressure_refresh_tick: int = -9999
var _prey_pressure_refresh_ticks: int = 9
var _path_budget_remaining: int = 0
var _new_path_budget_remaining: int = 0
var _path_expansion_budget: int = 512
var _path_expansions_spent: int = 0
var _path_time_warning_ms: float = 4.0
var _path_expansions_per_slice: int = 384
var _pending_global_paths: Array = []
var _pending_global_path_keys: Dictionary = {}
var _path_served_requesters: Dictionary = {}
var _pending_local_agent_ids: Array[int] = []
var _pending_local_paths: Dictionary = {}
var _local_path_served_agents: Dictionary = {}
var _goal_bucket_size: int = 4
var _sector_grass_refresh_ticks: int = 18
var _grass_local_reach_cells: int = 3
var _walk_reachable_cache: Dictionary = {}
var _walk_reachable_order: Array = []
var _walk_reachable_cache_limit: int = 4096
var _grass_target_refresh_ticks: int = 6
var _mid_decision_interval_ticks: int = 3
var _far_decision_interval_ticks: int = 8
var _lod_agent_cache: Dictionary = {}
var _lod_context_cache_key: PackedInt32Array = PackedInt32Array()
var _very_far_sector_step_seconds: float = 0.75
## Every sleeping group's census and goal across sectors, rebuilt at the start of each
## `_step_dormant_sectors()` and cleared at its end. See `_index_dormant_groups()`.
var _dormant_group_index: Dictionary = {}
var _dormant_speed_scale: float = 0.45
var _dormant_goal_refresh_seconds: float = 2.0
var _dormant_stale_wake_seconds: float = 6.0
var _dormant_reify_budget_per_tick: int = 1
var _reproduction_population_counts: Dictionary = {}
var _reproduction_birth_reservations: Dictionary = {}


func initialize(new_config_bundle: Dictionary, new_event_bus, new_rng: RandomNumberGenerator) -> void:
	config_bundle = new_config_bundle
	event_bus = new_event_bus
	rng = new_rng
	species_registry = SpeciesRegistryScript.from_config(config_bundle.get("species", {}))
	_prey_species_ids = []
	_threat_species_ids = []
	for species_id in species_registry.ids():
		if not species_registry.predator_set(species_id).is_empty():
			_prey_species_ids.append(species_id)
		if species_registry.is_threat(species_id):
			_threat_species_ids.append(species_id)
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
	var water_generation: Dictionary = world_config.get("water_generation", {})
	if water_generation.is_empty():
		for source in world_config.get("water_sources", []):
			water_sources.append({
				"position": Vector2(float(source.get("x", 0.0)), float(source.get("y", 0.0))),
				"radius": float(source.get("radius", 48.0)),
			})
	else:
		_generate_water_sources(water_generation)

	terrain_system = TerrainSystemScript.new()
	terrain_system.initialize(world_config, rng, water_sources)
	scenery.initialize(world_config, config_bundle.get("visuals", {}), terrain_system, int(rng.seed))

	resource_system = ResourceSystemScript.new()
	resource_system.initialize(world_config, rng, terrain_system)
	# Sampled here and not only in `step()` because the manager writes a stats
	# snapshot on tick 0, before the first step ever runs.
	climate = ClimateScript.new()
	climate.configure(world_config)
	_sector_size = maxf(terrain_system.cell_size * 2.0, float(simulation_lod_config.get("sector_size", 512.0)))
	_goal_bucket_size = maxi(1, int(navigation_config.get("goal_bucket_size", 4)))
	_sector_grass_refresh_ticks = maxi(1, int(navigation_config.get("sector_grass_refresh_ticks", 18)))
	_grass_local_reach_cells = maxi(1, int(navigation_config.get("grass_local_reach_cells", 3)))
	_walk_reachable_cache_limit = maxi(64, int(navigation_config.get("grass_local_reach_cache_limit", 4096)))
	_walk_reachable_cache.clear()
	_walk_reachable_order.clear()
	_pending_global_paths.clear()
	_pending_global_path_keys.clear()
	_pending_local_agent_ids.clear()
	_pending_local_paths.clear()
	_lod_agent_cache.clear()
	_lod_context_cache_key = PackedInt32Array()
	_prey_pressure_refresh_ticks = maxi(1, int(navigation_config.get("prey_pressure_refresh_ticks", 9)))
	_grass_target_refresh_ticks = maxi(1, int(navigation_config.get("grass_target_refresh_ticks", 6)))
	_dormant_speed_scale = clampf(float(simulation_lod_config.get("dormant_speed_scale", 0.45)), 0.1, 1.0)
	_dormant_goal_refresh_seconds = maxf(0.5, float(simulation_lod_config.get("dormant_goal_refresh_seconds", 2.0)))
	_dormant_stale_wake_seconds = maxf(_dormant_goal_refresh_seconds, float(simulation_lod_config.get("dormant_stale_wake_seconds", 6.0)))
	_dormant_reify_budget_per_tick = maxi(0, int(simulation_lod_config.get("dormant_reify_budget_per_tick", 1)))
	_reproduction_population_counts.clear()
	_reproduction_birth_reservations.clear()

	spatial_grid = SpatialGridScript.new()
	spatial_grid.configure(float(world_config.get("spatial_cell_size", 96.0)))

	living_agents.clear()
	_living_agent_index_by_id.clear()
	_group_state_cache.clear()
	_agent_sector_cells.clear()
	_sector_states.clear()
	_sector_grass_cache.clear()
	_prey_pressure_sectors.clear()
	_prey_pressure_refresh_tick = -9999
	_reset_performance_counters()
	_spawn_initial_agents()
	_spawn_initial_carcasses()
	_rebuild_group_state_cache()
	_update_lod_assignments({"enabled": false})


func step(delta: float, tick: int, time_seconds: float, lod_context: Dictionary = {}) -> void:
	current_tick = tick
	current_time = time_seconds
	_reproduction_population_counts.clear()
	_reproduction_birth_reservations.clear()
	climate.sample(current_time)
	_reset_performance_counters()
	scenery.visibility_checks = 0
	scenery.local_searches = 0
	_prepare_navigation_budget()
	var phase_started_usec: int = Time.get_ticks_usec()
	resource_system.step(delta, climate.regrowth_multiplier)
	performance_counters["phase_resources_ms"] = float(Time.get_ticks_usec() - phase_started_usec) / 1000.0
	var active_lod_context: Dictionary = _normalize_lod_context(lod_context)
	var lod_context_key := _lod_assignment_context_key(active_lod_context)
	if lod_context_key != _lod_context_cache_key:
		_lod_context_cache_key = lod_context_key
		_lod_agent_cache.clear()
	_mid_decision_interval_ticks = int(active_lod_context.get("mid_decision_interval_ticks", 3))
	_far_decision_interval_ticks = int(active_lod_context.get("far_decision_interval_ticks", 8))
	_very_far_sector_step_seconds = float(active_lod_context.get("very_far_sector_step_seconds", 0.75))
	phase_started_usec = Time.get_ticks_usec()
	_wake_relevant_dormant_sectors(active_lod_context)
	_refresh_prey_pressure_sectors()
	performance_counters["phase_sectors_ms"] = float(Time.get_ticks_usec() - phase_started_usec) / 1000.0

	phase_started_usec = Time.get_ticks_usec()
	for offset in living_agents.size():
		var agent = living_agents[(offset + current_tick) % living_agents.size()]
		if agent == null or not agent.is_alive:
			continue
		var lod_tier: int = _resolve_lod_tier_cached(agent, active_lod_context)
		agent.lod_tier = lod_tier
		var previous_position: Vector2 = agent.position
		var agent_started_usec := Time.get_ticks_usec()
		if _should_run_full_tick(agent, lod_tier, active_lod_context):
			performance_counters["agents_full_tick"] += 1
			agent.tick(self, delta)
		else:
			performance_counters["agents_maintenance_tick"] += 1
			agent.tick_maintenance(self, delta)
		var species_timing_key := "agent_%s_ms" % agent.species_type
		performance_counters[species_timing_key] = float(performance_counters.get(species_timing_key, 0.0)) \
			+ float(Time.get_ticks_usec() - agent_started_usec) / 1000.0
		_track_agent_runtime_position(agent, previous_position)
		if agent.stuck_timer > 0.75:
			performance_counters["stuck_agents"] += 1

	var overlap_started_usec := Time.get_ticks_usec()
	_resolve_agent_overlap(delta)
	performance_counters["phase_overlap_ms"] = float(Time.get_ticks_usec() - overlap_started_usec) / 1000.0
	performance_counters["phase_agents_ms"] = float(Time.get_ticks_usec() - phase_started_usec) / 1000.0

	_flush_removals()
	_flush_spawns()
	_step_carcasses(delta)
	phase_started_usec = Time.get_ticks_usec()
	_step_dormant_sectors(delta, active_lod_context)
	_sleep_far_sectors(active_lod_context)
	performance_counters["phase_dormant_ms"] = float(Time.get_ticks_usec() - phase_started_usec) / 1000.0
	_flush_carcass_removals()
	var path_stats: Dictionary = {} if terrain_system == null else terrain_system.consume_path_query_stats()
	performance_counters["pathfind_calls"] += int(path_stats.get("queries", 0))
	performance_counters["path_cache_hits"] += int(path_stats.get("cache_hits", 0))
	performance_counters["grass_cells_scanned"] += resource_system.take_cells_scanned()
	performance_counters["visibility_checks"] = scenery.visibility_checks
	performance_counters["local_path_searches"] = scenery.local_searches
	_update_lod_assignments(active_lod_context, true)


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
	agent.position = scenery.nearest_free(agent.position, agent.get_body_radius())
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


## Per-species population and need totals, live and dormant.
##
## Keys are built from the species id - `herbivore_count`, `dormant_predator_hunger_sum`
## and so on - rather than enumerated, so a new species in species.json reaches the
## stats snapshot, the charts and the HUD without a line of code here. The names are
## exactly the ones the two hand-written species produced before, so every existing
## reader keeps working.
func get_population_metrics() -> Dictionary:
	var hunger_sum := 0.0
	var energy_sum := 0.0
	var living_count := 0
	var critical_hunger := float(config_bundle.get("balance", {}).get("state_thresholds", {}).get("critical_hunger", 60.0))

	var per_species: Dictionary = {}
	for species_id in species_registry.ids():
		per_species[species_id] = {
			"active": 0, "dormant": 0,
			"active_hunger": 0.0, "dormant_hunger": 0.0,
			"dormant_thirst": 0.0, "dormant_energy": 0.0,
			"starvation_risk": 0,
		}

	for agent in living_agents:
		if agent == null or not agent.is_alive:
			continue
		living_count += 1
		hunger_sum += agent.hunger
		energy_sum += agent.energy
		var totals = per_species.get(agent.species_type, null)
		if totals == null:
			continue
		totals["active"] += 1
		totals["active_hunger"] += agent.hunger
		if agent.hunger >= critical_hunger:
			totals["starvation_risk"] += 1

	for sector_state in _sector_states.values():
		if not bool(sector_state.get("dormant", false)):
			continue
		var dormant_species: Dictionary = sector_state.get("dormant_species", {})
		for species_key in dormant_species.keys():
			var species_state: Dictionary = dormant_species[species_key]
			var count: int = int(species_state.get("count", 0))
			if count <= 0:
				continue
			var avg_hunger := float(species_state.get("avg_hunger", 0.0))
			living_count += count
			hunger_sum += avg_hunger * count
			energy_sum += float(species_state.get("avg_energy", 0.0)) * count
			var totals = per_species.get(species_key, null)
			if totals == null:
				continue
			totals["dormant"] += count
			totals["dormant_hunger"] += avg_hunger * count
			totals["dormant_thirst"] += float(species_state.get("avg_thirst", 0.0)) * count
			totals["dormant_energy"] += float(species_state.get("avg_energy", 0.0)) * count
			if avg_hunger >= critical_hunger:
				totals["starvation_risk"] += count

	var metrics: Dictionary = {
		"hunger_sum": hunger_sum,
		"energy_sum": energy_sum,
		"living_count": living_count,
	}
	for species_id in species_registry.ids():
		var totals: Dictionary = per_species[species_id]
		metrics["%s_count" % species_id] = int(totals["active"]) + int(totals["dormant"])
		metrics["active_%s_count" % species_id] = totals["active"]
		metrics["dormant_%s_count" % species_id] = totals["dormant"]
		metrics["active_%s_hunger_sum" % species_id] = totals["active_hunger"]
		metrics["dormant_%s_hunger_sum" % species_id] = totals["dormant_hunger"]
		metrics["dormant_%s_thirst_sum" % species_id] = totals["dormant_thirst"]
		metrics["dormant_%s_energy_sum" % species_id] = totals["dormant_energy"]
		metrics["starvation_risk_%s_count" % species_id] = totals["starvation_risk"]
	return metrics


## Density-dependent breeding limit for a configured habitat.
##
## The reference is the preset's starting population, so map/mix presets keep
## their intended scale. This only suppresses new births near carrying capacity;
## it never inserts animals or kills them, and reproduction resumes after losses.
func get_reproductive_capacity(species_type: String) -> int:
	var regulation: Dictionary = config_bundle.get("balance", {}).get("population_regulation", {})
	if not bool(regulation.get("enabled", false)):
		return 2147483647
	var initial_count := int(config_bundle.get("world", {}).get("spawns", {}).get(
		"%s_count" % species_type, 0))
	if initial_count <= 0:
		return 0
	var multipliers: Dictionary = regulation.get("capacity_multipliers", {})
	return maxi(initial_count, int(round(float(initial_count) * float(
		multipliers.get(species_type, regulation.get("default_capacity_multiplier", 2.0))))))


func _reproduction_population_count(species_type: String) -> int:
	if _reproduction_population_counts.has(species_type):
		return int(_reproduction_population_counts[species_type])
	var count := int(get_population_metrics().get("%s_count" % species_type, 0))
	_reproduction_population_counts[species_type] = count
	return count


func has_reproductive_capacity(species_type: String) -> bool:
	return _reproduction_population_count(species_type) \
		+ int(_reproduction_birth_reservations.get(species_type, 0)) \
		< get_reproductive_capacity(species_type)


func reserve_reproductive_capacity(species_type: String, requested_births: int) -> int:
	if requested_births <= 0:
		return 0
	var used := int(_reproduction_birth_reservations.get(species_type, 0))
	var available := maxi(0, get_reproductive_capacity(species_type) \
		- _reproduction_population_count(species_type) - used)
	var granted := mini(requested_births, available)
	_reproduction_birth_reservations[species_type] = used + granted
	return granted


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
	for agent in living_agents:
		agent.clear_decision_cache()
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
	_walk_reachable_cache.clear()
	_walk_reachable_order.clear()
	_pending_global_paths.clear()
	_pending_global_path_keys.clear()
	_pending_local_agent_ids.clear()
	_pending_local_paths.clear()
	_lod_agent_cache.clear()
	_lod_context_cache_key = PackedInt32Array()
	_prey_pressure_sectors.clear()
	_prey_pressure_refresh_tick = -9999
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


## Agents of any of several species, in one grid walk. `species_set` comes from
## `SpeciesRegistry.prey_set()` / `predator_set()` and is already built - passing a
## freshly constructed Dictionary here would allocate once per agent per tick.
func query_agents_multi(position: Vector2, radius: float, species_set: Dictionary, exclude_id: int = -1) -> Array:
	performance_counters["agent_query_calls"] += 1
	if species_set.is_empty():
		return []
	var results: Array = []
	spatial_grid.query_into(results, position, radius, "", exclude_id, species_set)
	return results


## `visible_agents()` over a species set.
func visible_agents_multi(observer, radius: float, species_set: Dictionary) -> Array:
	var result: Array = query_agents_multi(observer.position, radius, species_set, observer.id)
	# Filter the spatial result in place. Creating a second result array doubled
	# temporary allocations for the near-threat check that every active herd
	# animal performs each movement tick.
	for index in range(result.size() - 1, -1, -1):
		if not can_see(observer, result[index], radius):
			result.remove_at(index)
	return result


## Neighbour count without materialising the agents. Same filter as
## `query_agents()`.
func count_agents(position: Vector2, radius: float, species_filter: String = "", exclude_id: int = -1) -> int:
	performance_counters["agent_query_calls"] += 1
	return spatial_grid.count(position, radius, species_filter, exclude_id)


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
	var clamped_radius := maxf(0.0, radius)
	var radius_sq := clamped_radius * clamped_radius
	var center_sector := _get_sector_key(position)
	var sector_radius := int(ceil(clamped_radius / _sector_size))
	var candidate_ids: Array[int] = []
	for x in range(center_sector.x - sector_radius, center_sector.x + sector_radius + 1):
		for y in range(center_sector.y - sector_radius, center_sector.y + sector_radius + 1):
			var sector_state: Dictionary = _sector_states.get(Vector2i(x, y), {})
			if sector_state.is_empty():
				continue
			for carcass_id in sector_state.get("carcass_ids", []):
				candidate_ids.append(int(carcass_id))
	# Sector order must not decide which equal-distance carcass wins. IDs are
	# monotonic, so sorting the small local candidate set preserves deterministic
	# tie-breaking without walking every carcass in the world.
	candidate_ids.sort()
	performance_counters["carcasses_scanned"] += candidate_ids.size()
	for carcass_id in candidate_ids:
		var carcass: Dictionary = carcasses.get(carcass_id, {})
		if carcass.is_empty():
			continue
		if not _is_carcass_available(carcass):
			continue
		if position.distance_squared_to(carcass["position"]) > radius_sq:
			continue
		matches.append(carcass)
	return matches


## Eyesight only, scaled by the climate. Search radii that stand in for memory
## rather than sight - water and grass, both an order of magnitude wider than the
## eye - deliberately do not pass through here: an animal does not forget where
## the river is when the sun goes down. It goes blind, not amnesiac.
##
## Every scaled site routes through this one function so a missed one is a grep
## rather than a guess. The pairing that matters: a search radius and the
## normalizer that divides by it must scale together, or every candidate found
## reads as maximally close and it looks like an AI bug instead of a sight one.
func perception_radius(agent, key: String, default_value: float) -> float:
	return float(agent.perception.get(key, default_value)) * climate.perception_multiplier_for(agent.species_type)


## Carrion smell expands as hunger becomes critical. Water and grass already
## have long-range memory searches; keeping carcasses at a fixed visual radius
## made active scavengers starve beside a map-wide surplus that dormant sectors
## could locate through their sector index.
func carcass_search_radius(agent) -> float:
	var base := float(agent.balance.get("carcass", {}).get("search_radius",
		agent.perception.get("vision_radius", 240.0)))
	var critical := float(config_bundle.get("balance", {}).get("state_thresholds", {}).get(
		"critical_hunger", 60.0))
	if agent.hunger <= critical:
		return base
	var urgency := clampf((agent.hunger - critical) / maxf(1.0, agent.need_max - critical), 0.0, 1.0)
	return lerpf(base, maxf(base * 4.0, _sector_size * 2.2), urgency)


func water_search_radius(agent) -> float:
	var base := float(agent.perception.get("water_search_radius", 260.0))
	var critical := float(config_bundle.get("balance", {}).get("state_thresholds", {}).get(
		"critical_thirst", 50.0))
	if agent.thirst <= critical:
		return base
	var urgency := clampf((agent.thirst - critical) / maxf(1.0, agent.need_max - critical), 0.0, 1.0)
	return lerpf(base, maxf(base * 3.0, _sector_size * 2.5), urgency)


func build_herbivore_snapshot(agent, known_predators = null) -> Variant:
	var snapshot = AgentPerceptionSnapshotScript.new()
	snapshot.built_at_tick = current_tick
	snapshot.built_at_time = current_time
	var started_usec: int = Time.get_ticks_usec()
	var neighbor_radius := float(agent.perception.get("neighbor_radius", 90.0))
	# The agent's own species, not the literal "herbivore" this used to pass. With one
	# prey species the two are the same; with two, every animal would have herded with
	# the other variant as readily as with its own.
	snapshot.species_neighbors = query_agents(agent.position, neighbor_radius, agent.species_type, agent.id)
	if agent.group_id == -1:
		snapshot.group_neighbors = snapshot.species_neighbors
	else:
		for neighbor in snapshot.species_neighbors:
			if neighbor.group_id == agent.group_id:
				snapshot.group_neighbors.append(neighbor)
		if snapshot.group_neighbors.is_empty():
			snapshot.group_neighbors = snapshot.species_neighbors
	var danger_radius := perception_radius(agent, "danger_radius", 120.0)
	snapshot.predators = visible_agents_multi(agent, danger_radius, species_registry.predator_set(agent.species_type)) \
		if known_predators == null else known_predators
	performance_counters["snapshot_agent_query_ms"] += float(Time.get_ticks_usec() - started_usec) / 1000.0

	started_usec = Time.get_ticks_usec()
	snapshot.group_center = get_group_center(agent.group_id, agent.species_type, agent.id)
	performance_counters["snapshot_group_ms"] += float(Time.get_ticks_usec() - started_usec) / 1000.0

	started_usec = Time.get_ticks_usec()
	snapshot.water_target = _resolve_water_source(agent.position, water_search_radius(agent))
	performance_counters["snapshot_water_ms"] += float(Time.get_ticks_usec() - started_usec) / 1000.0

	snapshot.grass_target = _find_grass_target_for_agent(agent)
	return snapshot


## Perception for a carrion feeder: the herd fields a flocking animal needs, plus
## the carcass fields the feeding action needs, and no grass search at all - which
## is the expensive half of the herbivore snapshot.
func build_scavenger_snapshot(agent, known_predators = null) -> Variant:
	var snapshot = AgentPerceptionSnapshotScript.new()
	snapshot.built_at_tick = current_tick
	snapshot.built_at_time = current_time
	var started_usec: int = Time.get_ticks_usec()
	var neighbor_radius := float(agent.perception.get("neighbor_radius", 90.0))
	snapshot.species_neighbors = query_agents(agent.position, neighbor_radius, agent.species_type, agent.id)
	if agent.group_id == -1:
		snapshot.group_neighbors = snapshot.species_neighbors
	else:
		for neighbor in snapshot.species_neighbors:
			if neighbor.group_id == agent.group_id:
				snapshot.group_neighbors.append(neighbor)
		if snapshot.group_neighbors.is_empty():
			snapshot.group_neighbors = snapshot.species_neighbors
	# Whichever species list this one in `role.eats_species`. For the scavenger that
	# is the predator, so the panic behaviour it inherits is live.
	var danger_radius := perception_radius(agent, "danger_radius", 120.0)
	snapshot.predators = visible_agents_multi(agent, danger_radius, species_registry.predator_set(agent.species_type)) \
		if known_predators == null else known_predators
	performance_counters["snapshot_agent_query_ms"] += float(Time.get_ticks_usec() - started_usec) / 1000.0

	started_usec = Time.get_ticks_usec()
	snapshot.group_center = get_group_center(agent.group_id, agent.species_type, agent.id)
	performance_counters["snapshot_group_ms"] += float(Time.get_ticks_usec() - started_usec) / 1000.0

	started_usec = Time.get_ticks_usec()
	snapshot.water_target = _resolve_water_source(agent.position, water_search_radius(agent))
	performance_counters["snapshot_water_ms"] += float(Time.get_ticks_usec() - started_usec) / 1000.0

	started_usec = Time.get_ticks_usec()
	snapshot.carcasses = query_carcasses(agent.position, carcass_search_radius(agent))
	snapshot.carcass_target = agent.choose_carcass(self, snapshot.carcasses)
	performance_counters["snapshot_carcass_ms"] += float(Time.get_ticks_usec() - started_usec) / 1000.0
	return snapshot


func build_predator_snapshot(agent) -> Variant:
	var snapshot = AgentPerceptionSnapshotScript.new()
	snapshot.built_at_tick = current_tick
	snapshot.built_at_time = current_time
	var started_usec: int = Time.get_ticks_usec()
	var vision_radius := perception_radius(agent, "vision_radius", 240.0)
	snapshot.prey_candidates = visible_agents_multi(agent, vision_radius, species_registry.prey_set(agent.species_type))
	var mate_radius := float(agent.perception.get("mate_search_radius", 80.0))
	var mates := query_agents(agent.position, mate_radius, agent.species_type, agent.id)
	performance_counters["snapshot_agent_query_ms"] += float(Time.get_ticks_usec() - started_usec) / 1000.0

	started_usec = Time.get_ticks_usec()
	snapshot.carcasses = query_carcasses(agent.position, carcass_search_radius(agent))
	performance_counters["snapshot_carcass_ms"] += float(Time.get_ticks_usec() - started_usec) / 1000.0

	started_usec = Time.get_ticks_usec()
	snapshot.water_target = _resolve_water_source(agent.position, _resolve_predator_water_search_radius(agent))
	snapshot.investigation_source = agent._get_recent_investigation_water_source(self)
	performance_counters["snapshot_water_ms"] += float(Time.get_ticks_usec() - started_usec) / 1000.0

	started_usec = Time.get_ticks_usec()
	snapshot.mate_target = agent._find_viable_mate(self, false, mates)
	snapshot.kin_center = agent.last_known_kin_center
	snapshot.prey_target = agent._choose_prey(self, snapshot.prey_candidates)
	snapshot.carcass_target = agent.choose_carcass(self, snapshot.carcasses)
	performance_counters["snapshot_predator_choice_ms"] += float(Time.get_ticks_usec() - started_usec) / 1000.0
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
	var cache_key := _group_cache_key(species_type, group_id)
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
	return terrain_system.get_move_cost_at_position(position) * scenery.movement_cost(position)


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


func resolve_movement_position(from_position: Vector2, to_position: Vector2, radius: float = 0.0) -> Vector2:
	return scenery.resolve_motion(from_position, clamp_position(to_position), radius)


func can_see(observer, target, radius: float) -> bool:
	return target != null and target.is_alive and scenery.visible(observer.position, target.position, radius)


func visible_agents(observer, radius: float, species: String) -> Array:
	var result: Array = []
	for candidate in query_agents(observer.position, radius, species, observer.id):
		if can_see(observer, candidate, radius):
			result.append(candidate)
	return result


func local_waypoint(agent, target: Vector2) -> Vector2:
	var radius: float = agent.get_body_radius()
	if scenery.segment_clear(agent.position, target, radius):
		agent.local_path = PackedVector2Array()
		return target
	if agent.local_path_goal.distance_squared_to(target) > terrain_system.cell_size * terrain_system.cell_size or agent.stuck_timer > 0.75:
		agent.local_path = PackedVector2Array()
	if agent.local_path.is_empty():
		if _local_path_budget <= 0 or _local_path_served_agents.has(agent.id) \
				or current_tick < agent.local_retry_tick:
			_enqueue_local_path(agent.id, target)
			return agent.position
		_local_path_budget -= 1
		_local_path_served_agents[agent.id] = true
		agent.local_retry_tick = current_tick + 12
		agent.local_path = scenery.local_path(agent.position, target, radius)
		agent.local_path_goal = target
	# Look ahead only across a swept, body-sized clear segment.
	while agent.local_path.size() > 1 and scenery.segment_clear(agent.position, agent.local_path[1], radius):
		agent.local_path.remove_at(0)
	if agent.local_path.is_empty():
		return agent.position
	if agent.position.distance_squared_to(agent.local_path[0]) < 4.0:
		agent.local_path.remove_at(0)
	return agent.position if agent.local_path.is_empty() else agent.local_path[0]


func random_point() -> Vector2:
	return get_nearest_walkable_position(Vector2(
		rng.randf_range(bounds.position.x, bounds.end.x),
		rng.randf_range(bounds.position.y, bounds.end.y)
	))


func random_unit_vector() -> Vector2:
	return Vector2.RIGHT.rotated(rng.randf_range(0.0, TAU))


## Nearest water source in range. Fused rather than going through
## `query_water_sources()`, which would build a match array and then measure the
## same distances a second time. Iteration order and first-wins tie-breaking are
## unchanged, so the chosen source is identical.
func _resolve_water_source(position: Vector2, radius: float) -> Dictionary:
	performance_counters["water_query_calls"] += 1
	var best := {}
	var best_distance_sq := INF
	for source in water_sources:
		var combined_radius: float = radius + float(source.get("radius", 0.0))
		var distance_sq: float = position.distance_squared_to(source["position"])
		if distance_sq > combined_radius * combined_radius:
			continue
		if distance_sq < best_distance_sq:
			best = source
			best_distance_sq = distance_sq
	return best


func _resolve_predator_water_search_radius(agent) -> float:
	return water_search_radius(agent)


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

	# Reuse a recent target instead of searching every decision tick. The cache
	# is dropped early if the cell has since been grazed below the threshold, so
	# a herd cannot keep walking to grass that is already gone.
	var cached: Dictionary = agent.grass_target_cache
	if not cached.is_empty() and current_tick - agent.grass_target_tick < _grass_target_refresh_ticks:
		var cached_index: int = int(cached.get("index", -1))
		if cached_index != -1 and resource_system.get_biomass(cached_index) >= min_biomass:
			return cached
		agent.grass_target_cache = {}

	# Tried and rejected: offsetting this search origin per agent to fan a herd
	# onto neighbouring cells. It measured flat (101 vs 107 vs 111 herbivores at
	# tick 1500 for offsets of 0, half a cell and a full cell), so the concept is
	# not carried. Herd contention is handled by the overlap pass instead.
	var local_grass := find_reachable_grass(agent.position, base_search_radius, min_biomass, agent.id)
	if not local_grass.is_empty():
		agent.grass_target_cache = local_grass
		agent.grass_target_tick = current_tick
		return local_grass
	var expanded_search_radius := lerpf(base_search_radius, maxf(base_search_radius * 4.0, 720.0), urgency_ratio)
	if expanded_search_radius <= base_search_radius:
		return {}
	var expanded_grass := find_reachable_grass(agent.position, expanded_search_radius, min_biomass, agent.id)
	if not expanded_grass.is_empty():
		agent.grass_target_cache = expanded_grass
		agent.grass_target_tick = current_tick
	return expanded_grass


## Places water on a jittered grid sized from the world's area.
##
## The alternative - a literal `water_sources` list - is what the map used
## before, and it is coordinates hardcoded for one particular world size with no
## clamping, so any change of `world_size` silently left sources outside the map
## or left the survivors nine times too sparse. Deriving the count from a density
## keeps water per unit area fixed however the map is resized.
##
## Uses its own generator rather than `rng`. Drawing from the simulation's stream
## here would shift every later draw - terrain, grass, spawns - so a change to
## water placement would reshuffle the whole world.
func _generate_water_sources(config: Dictionary) -> void:
	var area: float = bounds.size.x * bounds.size.y
	if area <= 0.0:
		return
	var density := float(config.get("sources_per_million_units", 1.39))
	var count: int = maxi(1, int(round(density * area / 1_000_000.0)))
	var radius_min := float(config.get("radius_min", 100.0))
	var radius_max := maxf(radius_min, float(config.get("radius_max", 144.0)))
	var jitter := clampf(float(config.get("jitter", 0.35)), 0.0, 0.5)

	# Grid proportioned to the world so cells stay near-square; a square grid on
	# a 16:9 map would band the water into columns.
	var columns: int = maxi(1, int(round(sqrt(float(count) * bounds.size.x / maxf(1.0, bounds.size.y)))))
	@warning_ignore("integer_division")
	var rows: int = maxi(1, int(ceil(float(count) / float(columns))))
	var step := Vector2(bounds.size.x / float(columns), bounds.size.y / float(rows))

	var water_rng := RandomNumberGenerator.new()
	water_rng.seed = int(config.get("seed", 0)) ^ hash(bounds.size)
	var placed: int = 0
	for row in range(rows):
		for column in range(columns):
			if placed >= count:
				break
			var centre := bounds.position + Vector2(
				(float(column) + 0.5) * step.x,
				(float(row) + 0.5) * step.y)
			var offset := Vector2(
				water_rng.randf_range(-jitter, jitter) * step.x,
				water_rng.randf_range(-jitter, jitter) * step.y)
			var radius := water_rng.randf_range(radius_min, radius_max)
			# Kept a full radius inside the map: a source clipped by the border
			# is a watering hole agents can path to but never reach.
			water_sources.append({
				"position": Vector2(
					clampf(centre.x + offset.x, bounds.position.x + radius, bounds.end.x - radius),
					clampf(centre.y + offset.y, bounds.position.y + radius, bounds.end.y - radius)),
				"radius": radius,
			})
			placed += 1


## Pushes overlapping animals apart after everyone has moved.
##
## Steering alone cannot promise this. Separation is one weighted vote among
## several, and during grazing it is outvoted roughly twenty to one, so a herd
## converging on one patch stacks up however the force law is tuned. Bodies are
## resolved here instead, as a position correction rather than a force - the same
## split physics engines make between steering and contacts.
##
## Two passes, and the split matters. Applying each pair's correction as it was
## found made the result depend on the order pairs happened to be visited, and -
## far worse - let one animal accumulate a correction from every neighbour at
## once: five contacts could displace it ninety units in a tick, against a
## walking speed near four. Animals were flung across the map faster than they
## could travel, never settling anywhere long enough to eat, and the population
## fell from 386 to 56 by tick 1500. Corrections are now summed first and then
## clamped to a fraction of a stride, so crowding relaxes over several ticks
## instead of snapping.
func _resolve_agent_overlap(delta: float) -> void:
	if spatial_grid == null:
		return
	var corrections: Dictionary = {}
	var neighbours: Array = []
	for agent in living_agents:
		if agent == null or not agent.is_alive:
			continue
		var radius: float = agent.get_body_radius()
		if radius <= 0.0:
			continue
		neighbours.clear()
		spatial_grid.query_into(neighbours, agent.position, radius * 2.0, "", agent.id)
		for other in neighbours:
			if other == null or not other.is_alive or int(other.id) <= int(agent.id):
				continue
			var minimum: float = radius + other.get_body_radius()
			var offset: Vector2 = other.position - agent.position
			var distance: float = offset.length()
			if distance >= minimum:
				continue
			var direction: Vector2
			if distance <= 0.001:
				# Coincident, so there is no offset to point along. Derive a
				# direction from the id pair: any consistent choice will do, as
				# long as a replay makes the same one.
				direction = Vector2.RIGHT.rotated(float((int(agent.id) + int(other.id)) % 6283) * 0.001)
				distance = 0.0
			else:
				direction = offset / distance
			var push: Vector2 = direction * ((minimum - distance) * 0.5)
			corrections[agent.id] = corrections.get(agent.id, Vector2.ZERO) - push
			corrections[other.id] = corrections.get(other.id, Vector2.ZERO) + push
	if corrections.is_empty():
		return
	for agent in living_agents:
		if agent == null or not agent.is_alive or not corrections.has(agent.id):
			continue
		var correction: Vector2 = corrections[agent.id]
		var limit: float = float(agent.movement.get("max_speed", 70.0)) * delta * _OVERLAP_RELAXATION
		if correction.length() > limit:
			correction = correction.normalized() * limit
		var previous: Vector2 = agent.position
		agent.position = resolve_movement_position(previous, previous + correction, agent.get_body_radius())
		_track_agent_runtime_position(agent, previous)


## Everything about this world that a fresh `initialize()` would not reproduce.
##
## Terrain is deliberately absent: it is regenerated bit-for-bit from the seed
## and config, and it is the largest structure here by far. Same for the spatial
## grid, the group cache and the biome totals - all derived, all rebuilt on load.
##
## `living_agents` order is saved explicitly. It is the order agents tick in, it
## is maintained by swap-removal, and it cannot be recovered from `agents`.
func export_state() -> Dictionary:
	var agent_records: Array = []
	for agent in living_agents:
		if agent == null:
			continue
		agent_records.append(agent.export_save_state())
	var carcass_records: Dictionary = {}
	for carcass_id in carcasses.keys():
		carcass_records[carcass_id] = carcasses[carcass_id].duplicate(true)
	return {
		"current_tick": current_tick,
		"current_time": current_time,
		"next_agent_id": next_agent_id,
		"next_carcass_id": next_carcass_id,
		"agents": agent_records,
		"carcasses": carcass_records,
		"grass": resource_system.export_cells(),
		"sectors": _export_sector_states(),
		# A memo, but a behaviourally visible one: it can hold a stale patch for
		# up to `sector_grass_refresh_ticks`, and a loaded world that recomputed
		# it fresh would find better grass than the run it is continuing.
		"sector_grass": _export_keyed(_sector_grass_cache),
	}


## Replaces the mutable layers of an already-initialized world.
##
## Call after `initialize()` with the same config and seed: this assumes terrain
## and the grids already exist, and only swaps out what changes over time.
func import_state(data: Dictionary) -> void:
	for agent in living_agents.duplicate():
		if agent != null:
			agent.clear_decision_cache()
	agents.clear()
	living_agents.clear()
	_living_agent_index_by_id.clear()
	_agent_sector_cells.clear()
	_sector_states.clear()
	carcasses.clear()
	pending_spawns.clear()
	pending_removals.clear()
	pending_carcass_removals.clear()

	current_tick = int(data.get("current_tick", 0))
	current_time = float(data.get("current_time", 0.0))
	# A restored save calls `refresh_snapshot()` immediately; without this the
	# loaded game would report spring noon for one tick.
	climate.sample(current_time)

	for record in data.get("agents", []):
		var agent = _restore_agent_record(record)
		if agent != null:
			agents[agent.id] = agent
			_register_living_agent(agent)
	# After the agents, so a stale counter cannot hand out an id already in use.
	next_agent_id = maxi(int(data.get("next_agent_id", 1)), _highest_agent_id() + 1)
	next_carcass_id = int(data.get("next_carcass_id", 1))

	for carcass_id in data.get("carcasses", {}).keys():
		carcasses[int(carcass_id)] = data["carcasses"][carcass_id].duplicate(true)

	resource_system.import_cells(data.get("grass", PackedFloat32Array()), terrain_system)
	_import_sector_states(data.get("sectors", {}))
	_rebuild_carcass_sector_index()
	_sector_grass_cache = _import_keyed(data.get("sector_grass", []))
	spatial_grid.rebuild(living_agents)
	_rebuild_group_state_cache()


func _restore_agent_record(record: Dictionary):
	var species_type := str(record.get("species_type", ""))
	var agent = _create_agent(species_type)
	if agent == null:
		return null
	agent.configure(
		int(record.get("id", 0)),
		species_type,
		record.get("position", Vector2.ZERO),
		str(record.get("sex", "")),
		config_bundle.get("species", {}).get(species_type, {}),
		config_bundle.get("balance", {}),
		rng,
		int(record.get("group_id", -1))
	)
	agent.apply_save_state(record)
	agent.position = scenery.nearest_free(agent.position, agent.get_body_radius())
	agent.clear_navigation()
	return agent


func _highest_agent_id() -> int:
	var highest: int = 0
	for agent_id in agents.keys():
		highest = maxi(highest, int(agent_id))
	for sector_state in _sector_states.values():
		for record in sector_state.get("dormant_records", []):
			highest = maxi(highest, int(record.get("id", 0)))
	return highest


## `Vector2i`-keyed dictionaries, flattened to a list of `[key, value]` pairs.
## Storing them as-is works with `store_var` but not with any text format, and
## keeping one shape for both makes the save file easier to inspect.
func _export_keyed(source: Dictionary) -> Array:
	var exported: Array = []
	for key in source.keys():
		exported.append([key, source[key].duplicate(true) if source[key] is Dictionary else source[key]])
	return exported


func _import_keyed(data) -> Dictionary:
	var restored: Dictionary = {}
	if not (data is Array):
		return restored
	for pair in data:
		if pair is Array and pair.size() == 2:
			restored[pair[0]] = pair[1]
	return restored


## Sector keys are `Vector2i`, which no text format can use as a key, so each
## sector is stored as a record carrying its own coordinates.
func _export_sector_states() -> Array:
	var exported: Array = []
	for sector_key in _sector_states.keys():
		var entry: Dictionary = _sector_states[sector_key].duplicate(true)
		entry["sector_key"] = sector_key
		exported.append(entry)
	return exported


func _import_sector_states(data) -> void:
	if not (data is Array):
		return
	for entry in data:
		if not (entry is Dictionary) or not entry.has("sector_key"):
			continue
		var restored: Dictionary = entry.duplicate(true)
		var sector_key = restored["sector_key"]
		restored.erase("sector_key")
		_sector_states[sector_key] = restored
	# Live agents were registered before this ran and rebuilt the occupancy of
	# the sectors they are in; a saved sector must not double-count them.
	for sector_key in _sector_states.keys():
		var state: Dictionary = _sector_states[sector_key]
		if bool(state.get("dormant", false)):
			continue
		state["agent_ids"] = []
		state["species_counts"] = {}
	for agent in living_agents:
		if agent != null:
			_register_sector_presence(agent)


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
		performance_counters["grass_consumed_total"] += consumed
		_mark_grass_sector_dirty_by_index(index)
	return consumed


func record_herbivore_hunger_reduction(amount: float, herbivore_count: int = 1) -> void:
	if amount <= 0.0 or herbivore_count <= 0:
		return
	performance_counters["herbivore_hunger_reduced_total"] += amount * herbivore_count


func find_reachable_grass(position: Vector2, radius: float, min_biomass: float = 0.0, requester_id: int = -1) -> Dictionary:
	var started_at_usec: int = Time.get_ticks_usec()
	var result: Dictionary = _find_reachable_grass_uncounted(position, radius, min_biomass, requester_id)
	performance_counters["grass_search_ms"] += float(Time.get_ticks_usec() - started_at_usec) / 1000.0
	performance_counters["grass_search_calls"] += 1
	return result


func _find_reachable_grass_uncounted(position: Vector2, radius: float, min_biomass: float, requester_id: int = -1) -> Dictionary:
	if terrain_system == null:
		return resource_system.find_best_cell(position, radius, min_biomass)

	var start_index: int = terrain_system.find_nearest_walkable_index(terrain_system.get_index_from_position(position))
	if start_index == -1:
		return {}

	# Grass and terrain share a cell index space: both grids are sized from the same world
	# bounds, so an index means the same cell in each only while `grass.cell_size` equals
	# `terrain.cell_size`. The walkability checks and path goals below rely on that, as
	# does `_find_sector_grass_candidate`, so the two must be configured together.

	# Grass within a few cells needs no route planning: the agent can walk straight to it.
	# Resolving it first is what keeps a herbivore eating the meadow it is standing in
	# instead of marching off to the sector cache's candidate, which is picked relative to
	# the sector centre and is therefore the same cell for every agent in that sector.
	var local_grass := _find_local_grass_target(position, start_index, radius, min_biomass)
	if not local_grass.is_empty():
		return local_grass

	var candidate := _find_sector_grass_candidate(position, radius, min_biomass)
	if candidate.is_empty():
		candidate = resource_system.find_best_cell(position, radius, min_biomass)
	if candidate.is_empty():
		return {}
	var candidate_index: int = int(candidate.get("index", -1))
	if candidate_index == -1:
		return {}
	var path_result := _find_path_with_budget(start_index, candidate_index, requester_id)
	var path_cells: Array = path_result.get("cells", [])
	if path_cells.is_empty():
		if not terrain_system.has_cached_path_between_indices(start_index, candidate_index):
			performance_counters["grass_target_budget_misses"] += 1
		return {}
	candidate["path_cost"] = float(path_result.get("cost", INF))
	candidate["reachable"] = bool(path_result.get("reachable", false))
	candidate["path_cells"] = path_cells.duplicate()
	candidate["score"] = float(candidate.get("biomass", 0.0)) - candidate["path_cost"] * 0.12
	return candidate


## Terrain walkability is fixed once the world is generated, so a cell's reachable set never
## changes. Herds revisit the same cells constantly, so memoising it turns the per-agent
## flood fill into a dictionary lookup.
func _get_walk_reachable_cells(start_index: int) -> Dictionary:
	var cached: Dictionary = _walk_reachable_cache.get(start_index, {})
	if not cached.is_empty():
		return cached
	var reachable_cells := _collect_walk_reachable_cells(start_index, _grass_local_reach_cells)
	if _walk_reachable_order.size() >= _walk_reachable_cache_limit:
		_walk_reachable_cache.erase(_walk_reachable_order.pop_front())
	_walk_reachable_cache[start_index] = reachable_cells
	_walk_reachable_order.append(start_index)
	return reachable_cells


## The cells an agent can walk to without a route: everything within `depth` steps of
## walkable neighbours. Bounded by construction, and every entry is connected to
## `start_index`, so a target drawn from it is reachable without spending path budget.
func _collect_walk_reachable_cells(start_index: int, depth: int) -> Dictionary:
	var reachable_cells: Dictionary = {start_index: true}
	var frontier: Array = [start_index]
	for _step in range(maxi(1, depth)):
		var next_frontier: Array = []
		for cell_index in frontier:
			for neighbor_index in terrain_system.get_walkable_neighbors(int(cell_index)):
				var neighbor := int(neighbor_index)
				if reachable_cells.has(neighbor):
					continue
				reachable_cells[neighbor] = true
				next_frontier.append(neighbor)
		if next_frontier.is_empty():
			break
		frontier = next_frontier
	return reachable_cells


func _find_local_grass_target(position: Vector2, start_index: int, radius: float, min_biomass: float = 0.0) -> Dictionary:
	if resource_system == null or terrain_system == null or start_index == -1:
		return {}
	var local_radius := minf(radius, terrain_system.cell_size * float(_grass_local_reach_cells) + resource_system.cell_size)
	var reachable_cells: Dictionary = _get_walk_reachable_cells(start_index)
	var best: Dictionary = resource_system.find_best_cell_in_set(position, local_radius, min_biomass, reachable_cells)
	if best.is_empty():
		return best
	var best_index: int = int(best.get("index", -1))
	best["path_cost"] = position.distance_to(best.get("center", position))
	best["reachable"] = true
	best["path_cells"] = [start_index] if best_index == start_index else [start_index, best_index]
	return best


func get_next_waypoint(from_position: Vector2, to_position: Vector2, agent_id: int, force_repath: bool = false) -> Vector2:
	var agent = get_agent(agent_id)
	if agent == null:
		return from_position
	var radius: float = agent.get_body_radius()
	var goal_changed: bool = agent.navigation_input_goal != to_position
	if goal_changed or force_repath:
		agent.navigation_input_goal = to_position
		agent.navigation_free_goal = scenery.nearest_free(to_position, radius)
		agent.navigation_direct_clear = false
		agent.navigation_direct_check_tick = -9999
	var target: Vector2 = agent.navigation_free_goal
	var direct_check_interval := maxi(1, int(navigation_config.get("repath_interval_ticks", 8)))
	var should_check_direct: bool = force_repath or goal_changed \
		or current_tick - agent.navigation_direct_check_tick >= direct_check_interval
	if should_check_direct:
		agent.navigation_direct_check_tick = current_tick
		agent.navigation_direct_clear = scenery.segment_clear(from_position, target, radius)
	if agent.navigation_direct_clear:
		agent.path_cells.clear()
		agent.path_index = 0
		agent.local_path = PackedVector2Array()
		return target
	return local_waypoint(agent, _coarse_waypoint(from_position, target, agent_id, force_repath))


func _coarse_waypoint(from_position: Vector2, to_position: Vector2, agent_id: int, force_repath: bool = false) -> Vector2:
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
		var path_result: Dictionary = _find_path_with_budget(start_index, goal_index, agent.id)
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


func choose_escape_destination(position: Vector2, flee_vector: Vector2, base_distance: float,
		requester_id: int = -1, threat_positions: Array[Vector2] = [], body_radius: float = 0.0) -> Vector2:
	if terrain_system == null or flee_vector.length_squared() <= 0.0001:
		return clamp_position(position + flee_vector * base_distance)

	var direction: Vector2 = flee_vector.normalized()
	var start_index: int = terrain_system.find_nearest_walkable_index(terrain_system.get_index_from_position(position))
	if start_index == -1:
		return clamp_position(position + direction * base_distance)

	var current_min_threat_distance := _minimum_threat_distance(position, threat_positions)
	var candidates: Array = []
	for angle_degrees in [0.0, 30.0, -30.0, 60.0, -60.0, 90.0, -90.0]:
		var raw: Vector2 = position + direction.rotated(deg_to_rad(float(angle_degrees))) * base_distance
		var candidate_position: Variant = _escape_candidate_position(raw, body_radius)
		if candidate_position == null:
			continue
		var candidate: Vector2 = candidate_position
		var candidate_index: int = terrain_system.find_nearest_walkable_index(
			terrain_system.get_index_from_position(candidate))
		if candidate_index == -1:
			continue
		var min_threat_distance := _minimum_threat_distance(candidate, threat_positions)
		var cover_breaks := _escape_cover_breaks(candidate, threat_positions)
		var edge_clearance := minf(minf(candidate.x - bounds.position.x, bounds.end.x - candidate.x),
			minf(candidate.y - bounds.position.y, bounds.end.y - candidate.y)) - body_radius
		var candidate_direction := (candidate - position).normalized()
		candidates.append({
			"position": candidate,
			"index": candidate_index,
			"safe": threat_positions.is_empty() or min_threat_distance + 0.01 >= current_min_threat_distance,
			"cover_breaks": cover_breaks,
			"threat_distance": 0.0 if threat_positions.is_empty() else min_threat_distance,
			"edge_clearance": edge_clearance,
			"alignment": direction.dot(candidate_direction),
		})
	if candidates.is_empty():
		return position
	candidates.sort_custom(_escape_candidate_precedes)

	# Global routes are served by the same persistent fair queue as every other
	# navigation request. Cached candidates are free; at most one new search for
	# this animal is admitted in a tick, and later commitment refreshes can use
	# the completed result without evicting other requesters.
	var fallback: Vector2 = candidates[0].position
	var routed_candidates: Array = []
	for candidate_offset in range(mini(3, candidates.size())):
		var candidate: Dictionary = candidates[candidate_offset]
		var path_result := _find_path_with_budget(start_index, int(candidate.index), requester_id)
		if bool(path_result.get("pending", false)):
			continue
		if bool(path_result.get("reachable", false)) and not path_result.get("cells", []).is_empty():
			candidate = candidate.duplicate()
			candidate["path_cost"] = float(path_result.get("cost", INF))
			routed_candidates.append(candidate)
	if not routed_candidates.is_empty():
		routed_candidates.sort_custom(_escape_routed_candidate_precedes)
		return routed_candidates[0].position
	return fallback


func _escape_candidate_position(raw: Vector2, body_radius: float) -> Variant:
	var margin := maxf(4.0, body_radius + 0.01)
	var safe_bounds := bounds.grow(-margin)
	if safe_bounds.size.x <= 0.0 or safe_bounds.size.y <= 0.0:
		return null
	var clamped := Vector2(clampf(raw.x, safe_bounds.position.x, safe_bounds.end.x),
		clampf(raw.y, safe_bounds.position.y, safe_bounds.end.y))
	var walkable := get_nearest_walkable_position(clamped)
	var free := scenery.nearest_free(walkable, body_radius)
	if not safe_bounds.has_point(free) or not scenery.segment_clear(free, free, body_radius):
		return null
	return free


func _minimum_threat_distance(point: Vector2, threat_positions: Array[Vector2]) -> float:
	if threat_positions.is_empty():
		return INF
	var minimum := INF
	for threat_position in threat_positions:
		minimum = minf(minimum, point.distance_to(threat_position))
	return minimum


func _escape_cover_breaks(candidate: Vector2, threat_positions: Array[Vector2]) -> int:
	var breaks := 0
	for threat_position in threat_positions:
		var distance := threat_position.distance_to(candidate)
		if not scenery.visible(threat_position, candidate, distance + 0.01):
			breaks += 1
	return breaks


func _escape_candidate_precedes(a: Dictionary, b: Dictionary) -> bool:
	if bool(a.safe) != bool(b.safe):
		return bool(a.safe)
	if int(a.cover_breaks) != int(b.cover_breaks):
		return int(a.cover_breaks) > int(b.cover_breaks)
	if not is_equal_approx(float(a.threat_distance), float(b.threat_distance)):
		return float(a.threat_distance) > float(b.threat_distance)
	if not is_equal_approx(float(a.edge_clearance), float(b.edge_clearance)):
		return float(a.edge_clearance) > float(b.edge_clearance)
	return float(a.alignment) > float(b.alignment)


func _escape_routed_candidate_precedes(a: Dictionary, b: Dictionary) -> bool:
	if bool(a.safe) != bool(b.safe):
		return bool(a.safe)
	if int(a.cover_breaks) != int(b.cover_breaks):
		return int(a.cover_breaks) > int(b.cover_breaks)
	if not is_equal_approx(float(a.threat_distance), float(b.threat_distance)):
		return float(a.threat_distance) > float(b.threat_distance)
	if not is_equal_approx(float(a.path_cost), float(b.path_cost)):
		return float(a.path_cost) < float(b.path_cost)
	if not is_equal_approx(float(a.edge_clearance), float(b.edge_clearance)):
		return float(a.edge_clearance) > float(b.edge_clearance)
	return float(a.alignment) > float(b.alignment)


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


## Population event for an individual that has no live agent object, i.e. one that
## only exists as part of a dormant sector aggregate. Without this the dormant
## population moves while the birth/death counters stay flat.
func emit_population_event(event_type: String, species_type: String, position: Vector2, data: Dictionary = {}) -> void:
	event_bus.emit_event({
		"tick": current_tick,
		"time_seconds": current_time,
		"type": event_type,
		"agent_id": -1,
		"other_agent_id": -1,
		"species": species_type,
		"position": {"x": position.x, "y": position.y},
		"data": _sanitize_variant(data),
	})


func _emit_dormant_death(species_type: String, position: Vector2, cause: String) -> void:
	if cause == "starvation":
		emit_population_event("AgentStarved", species_type, position, {"cause": cause, "dormant": true})
	elif cause == "old_age":
		emit_population_event("AgentDiedOfAge", species_type, position, {"cause": cause, "dormant": true})
	emit_population_event("AgentDied", species_type, position, {"cause": cause, "dormant": true})


func _maybe_spawn_carcass(agent, cause: String) -> void:
	# Which species leave a body is `role.leaves_carcass` in species.json, not a
	# name test. `role.carcass_meat_multiplier` then sizes it, so a small animal
	# does not feed a sector the way a large one does.
	if agent == null or not species_registry.leaves_carcass(agent.species_type):
		return
	if cause not in ["predation", "old_age", "starvation", "thirst"]:
		return
	var carcass_config: Dictionary = config_bundle.get("balance", {}).get("carcass", {})
	var meat_total := maxf(0.0, float(carcass_config.get("meat_total", 84.0))
		* species_registry.carcass_meat_multiplier(agent.species_type))
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
	_register_carcass_sector(carcass_id, agent.position)
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
			_unregister_carcass_sector(carcass_id, carcass["position"])
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


## The starting population, one species at a time in `role.slot` order.
##
## Counts stay flat keys - `<species>_count`, `<species>_group_count` - so the
## map-size presets, the benchmark profiles and the test fixtures that already
## write them keep working, and a new species only has to add its own. A species
## with no count spawns nothing, which is what keeps the test bundles empty.
##
## Order matters beyond tidiness: the seeded generator places herds, offsets, sexes
## and the initial stagger, so iterating species in any other order would move every
## animal in the world and break the determinism fixtures.
func _spawn_initial_agents() -> void:
	var spawn_config: Dictionary = config_bundle.get("world", {}).get("spawns", {})
	for species_id in species_registry.ids():
		var count: int = int(spawn_config.get("%s_count" % species_id, 0))
		if count <= 0:
			continue
		match species_registry.social(species_id):
			SpeciesRegistryScript.SOCIAL_PAIR:
				_spawn_initial_pairs(species_id, count)
			SpeciesRegistryScript.SOCIAL_SOLITARY:
				_spawn_initial_solitary(species_id, count)
			_:
				_spawn_initial_herd(species_id, count, maxi(1, int(spawn_config.get("%s_group_count" % species_id, 8))))


## `role.social == "herd"`: a few centres, members dealt round-robin so no group
## is left short.
func _spawn_initial_herd(species_id: String, count: int, group_count: int) -> void:
	var herd_centers: Array = []
	for _index in range(group_count):
		herd_centers.append(random_point())
	for index in range(count):
		var center: Vector2 = herd_centers[index % group_count]
		var spawn_position: Vector2 = get_nearest_walkable_position(clamp_position(
			center + Vector2(rng.randf_range(-60.0, 60.0), rng.randf_range(-60.0, 60.0))))
		_stagger_initial_agent(spawn_agent(species_id, spawn_position, index % group_count, "", {"reason": "initial"}))


## `role.social == "pair"`: a male and a female per centre, pointed at each other
## so the pair-cohesion flow has someone to hold from tick zero.
func _spawn_initial_pairs(species_id: String, count: int) -> void:
	var pair_count: int = maxi(1, int(ceil(float(count) / 2.0)))
	var pair_centers: Array = []
	for _index in range(pair_count):
		pair_centers.append(random_point())

	for pair_index in range(pair_count):
		var pair_center: Vector2 = pair_centers[pair_index]
		var male_offset: Vector2 = Vector2(rng.randf_range(-28.0, 28.0), rng.randf_range(-28.0, 28.0))
		var female_offset: Vector2 = Vector2(rng.randf_range(-28.0, 28.0), rng.randf_range(-28.0, 28.0))
		var male = null
		var female = null

		var male_index: int = pair_index * 2
		if male_index < count:
			male = spawn_agent(
				species_id,
				get_nearest_walkable_position(clamp_position(pair_center + male_offset)),
				-1,
				AgentBaseScript.SEX_MALE,
				{"reason": "initial"}
			)

		if male_index + 1 < count:
			female = spawn_agent(
				species_id,
				get_nearest_walkable_position(clamp_position(pair_center + female_offset)),
				-1,
				AgentBaseScript.SEX_FEMALE,
				{"reason": "initial"}
			)

		_stagger_initial_agent(male)
		_stagger_initial_agent(female)

		if male != null and female != null:
			if male.has_method("set_preferred_mate_id"):
				male.call("set_preferred_mate_id", female.id)
			if female.has_method("set_preferred_mate_id"):
				female.call("set_preferred_mate_id", male.id)


## Carrion the world starts with.
##
## Generation makes grass, water and living animals, and no dead ones at all, so
## a species that eats only carrion begins in a world with nothing in it: the
## first bodies appear when herbivores start dying, tens of seconds in, and the
## whole starting flock starved before then - 24 spawned, 24 dead of hunger, in
## every run regardless of how long bodies lasted. A world that has been running
## before the simulation opens has old kills lying in it.
func _spawn_initial_carcasses() -> void:
	var count: int = int(config_bundle.get("world", {}).get("spawns", {}).get("initial_carcass_count", 0))
	if count <= 0 or species_registry.carcass_source_ids().is_empty():
		return
	var carcass_config: Dictionary = config_bundle.get("balance", {}).get("carcass", {})
	var ttl := maxf(0.0, float(carcass_config.get("ttl_seconds", 90.0)))
	var meat_total := maxf(0.0, float(carcass_config.get("meat_total", 84.0)))
	if meat_total <= 0.0:
		return
	var source_species: String = str(species_registry.carcass_source_ids()[0])
	for _index in range(count):
		var carcass_id := next_carcass_id
		next_carcass_id += 1
		# Aged across the whole span, so some are fresh enough for a hunter and
		# some are already the scavenger's alone - the same spread a running
		# world would have.
		var age: float = rng.randf() * ttl
		var position: Vector2 = get_nearest_walkable_position(clamp_position(random_point()))
		carcasses[carcass_id] = {
			"id": carcass_id,
			"position": position,
			"created_at": current_time - age,
			"ttl_seconds": ttl,
			"source_species": source_species,
			"death_cause": "initial",
			"meat_total": meat_total,
			"meat_remaining": meat_total * (1.0 - age / maxf(1.0, ttl)),
			"max_feeders": maxi(1, int(carcass_config.get("max_feeders", 2))),
			"active_feeder_ids": [],
			"source_agent_id": -1,
		}
		_register_carcass_sector(carcass_id, position)


## `role.social == "solitary"`: scattered singles, no groups and no pairing.
func _spawn_initial_solitary(species_id: String, count: int) -> void:
	for _index in range(count):
		var spawn_position: Vector2 = get_nearest_walkable_position(clamp_position(random_point()))
		_stagger_initial_agent(spawn_agent(species_id, spawn_position, -1, "", {"reason": "initial"}))


## Spreads the starting cohort's needs and ages.
##
## Every initial animal used to begin at hunger 0 and thirst 0 with identical
## metabolism, so the whole population crossed every threshold on the same tick:
## a single synchronized famine around tick 600 that killed roughly half the map
## before the survivors desynchronized on their own. Staggering the start turns
## that cliff into ordinary churn.
##
## Age is deliberately NOT staggered. Tried, and it cost three quarters of the
## population by tick 900: age gates reproduction, so a cohort spread across the
## lifespan cannot breed its way back from the first famine.
##
## Draws from `rng`, deliberately - this is world generation, the same stream
## that already places herds and grass.
func _stagger_initial_agent(agent) -> void:
	if agent == null:
		return
	var thresholds: Dictionary = agent.balance.get("state_thresholds", {})
	var hunger_ceiling := float(thresholds.get("critical_hunger", 60.0))
	var thirst_ceiling := float(thresholds.get("critical_thirst", 50.0))
	agent.hunger = rng.randf_range(0.0, hunger_ceiling * 0.75)
	agent.thirst = rng.randf_range(0.0, thirst_ceiling * 0.75)


## Share of one tick's stride that the overlap pass may move an animal. Small
## on purpose: it corrects crowding over several ticks instead of teleporting.
const _OVERLAP_RELAXATION := 0.6

const PREY_PRESSURE_CACHE_LIMIT := 32

## A sleeping herd keeps drifting inside itself, so its formation goes on changing
## while the camera is elsewhere. Both shares are of the animal's own dormant
## walking speed; the turn rate bounds how far a wander heading swings per second.
const _DORMANT_WANDER_SHARE := 0.15
const _DORMANT_WANDER_TURN_PER_SECOND := 1.6
const _DORMANT_COHESION_SHARE := 0.5
## Spacing is checked pair by pair. A group larger than this skips that pass for
## the step rather than paying for it quadratically.
const _DORMANT_SPACING_MEMBER_LIMIT := 64
## Radius of a comfortably packed herd, in body radii per square root of its size.
const _DORMANT_PACKING_RADIUS := 1.1


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


func _resolve_lod_tier_cached(agent: AgentBase, lod_context: Dictionary) -> int:
	var sector_key: Vector2i = _agent_sector_cells.get(agent.id, _get_sector_key(agent.position))
	var priority := _is_priority_lod_agent(agent) \
		or agent.id == int(lod_context.get("selected_agent_id", -1))
	var cached: Dictionary = _lod_agent_cache.get(agent.id, {})
	if cached.get("sector", Vector2i(2147483647, 2147483647)) == sector_key \
			and bool(cached.get("priority", false)) == priority:
		return int(cached.get("tier", LOD_TIER_0))
	var tier := _resolve_lod_tier(agent, lod_context)
	_lod_agent_cache[agent.id] = {"sector": sector_key, "priority": priority, "tier": tier}
	return tier


func _lod_assignment_context_key(lod_context: Dictionary) -> PackedInt32Array:
	var focus_rect: Rect2 = lod_context.get("focus_rect", Rect2())
	if focus_rect.size.is_zero_approx():
		var radius := float(lod_context.get("headless_active_radius", 0.0))
		if radius > 0.0:
			focus_rect = Rect2(bounds.get_center() - Vector2.ONE * radius, Vector2.ONE * radius * 2.0)
	var near := focus_rect.grow(float(lod_context.get("near_margin", 0.0)))
	var mid := focus_rect.grow(float(lod_context.get("mid_margin", 0.0)))
	return PackedInt32Array([
		1 if bool(lod_context.get("enabled", false)) else 0,
		floori(near.position.x / _sector_size), floori(near.position.y / _sector_size),
		ceili(near.end.x / _sector_size), ceili(near.end.y / _sector_size),
		floori(mid.position.x / _sector_size), floori(mid.position.y / _sector_size),
		ceili(mid.end.x / _sector_size), ceili(mid.end.y / _sector_size),
		int(lod_context.get("selected_agent_id", -1)),
	])


func _is_priority_lod_agent(agent: AgentBase) -> bool:
	return agent.target_agent_id != -1 \
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
	if agent.target_agent_id != -1 and get_agent(agent.target_agent_id) == null:
		return true
	var interval: int = int(config_bundle.get("balance", {}).get("ai", {}).get("decision_interval_ticks", 3))
	if agent.lod_tier != LOD_TIER_0:
		interval = _mid_decision_interval_ticks if agent.lod_tier == LOD_TIER_1 else _far_decision_interval_ticks
	interval = maxi(1, interval)
	if agent.cached_snapshot == null:
		return true
	return current_tick % interval == agent.id % interval


## `reuse_agent_tiers` skips recomputing every agent's tier when the caller already did
## it this tick (the step loop does). Recomputing there was a second full pass over all
## agents whose result the next tick's loop immediately overwrites anyway.
func _update_lod_assignments(lod_context: Dictionary, reuse_agent_tiers: bool = false) -> void:
	lod_counts = {
		"lod0_agents": 0,
		"lod1_agents": 0,
		"lod2_agents": 0,
	}
	for agent in living_agents:
		if agent == null or not agent.is_alive:
			continue
		var lod_tier: int = agent.lod_tier if reuse_agent_tiers else _resolve_lod_tier(agent, lod_context)
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
		"stuck_agents": 0,
		"agents_maintenance_tick": 0,
		"ai_context_build_ms": 0.0,
		"action_select_ms": 0.0,
		"pathfind_calls": 0,
		"path_cache_hits": 0,
		"grass_query_calls": 0,
		"agent_query_calls": 0,
		"water_query_calls": 0,
		"carcass_query_calls": 0,
		"carcasses_scanned": 0,
		"spatial_update_ms": 0.0,
		"group_center_lookups": 0,
		"sector_wakeups": 0,
		"dormant_steps": 0,
		"dormant_predation_kills": 0,
		"dormant_hunting_predator_steps": 0,
		"dormant_hunt_colocated_steps": 0,
		"dormant_meat_granted": 0.0,
		"dormant_predator_hunger_reduced": 0.0,
		"dormant_migrations": 0,
		"dormant_forced_wakeups": 0,
		"dormant_goal_refreshes": 0,
		"dormant_stale_sectors": 0,
		"grass_consumed_total": 0.0,
		"herbivore_hunger_reduced_total": 0.0,
		"grass_target_budget_misses": 0,
		"grass_search_ms": 0.0,
		"grass_search_calls": 0,
		"grass_cells_scanned": 0,
		"pathfind_ms": 0.0,
		"path_expansions": 0,
		"path_time_warning_ticks": 0,
		"snapshot_agent_query_ms": 0.0,
		"snapshot_water_ms": 0.0,
		"snapshot_group_ms": 0.0,
		"snapshot_carcass_ms": 0.0,
		"snapshot_predator_choice_ms": 0.0,
		"phase_resources_ms": 0.0,
		"phase_agents_ms": 0.0,
		"phase_dormant_ms": 0.0,
		"phase_sectors_ms": 0.0,
	}


func _prepare_navigation_budget() -> void:
	_local_path_budget = maxi(1, int(navigation_config.get("local_path_budget_per_tick", 6)))
	_path_budget_remaining = maxi(1, int(navigation_config.get("path_budget_per_tick", 64)))
	_new_path_budget_remaining = maxi(1, int(navigation_config.get("max_new_paths_per_tick", 18)))
	_path_expansion_budget = maxi(1, int(navigation_config.get("path_expansion_budget_per_tick", 512)))
	_path_time_warning_ms = float(navigation_config.get("path_time_warning_ms_per_tick", 4.0))
	_path_expansions_per_slice = maxi(32, int(navigation_config.get("path_expansions_per_slice", 384)))
	_path_expansions_spent = 0
	_path_served_requesters.clear()
	_local_path_served_agents.clear()
	_service_pending_global_paths()
	_service_pending_local_paths()
	performance_counters["pending_global_paths"] = _pending_global_paths.size()
	performance_counters["pending_local_paths"] = _pending_local_agent_ids.size()


func _find_path_with_budget(start_index: int, goal_index: int, requester_id: int = -1) -> Dictionary:
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
		if _path_budget_remaining <= 0 or _new_path_budget_remaining <= 0 \
				or _path_expansions_spent >= _path_expansion_budget \
				or (requester_id >= 0 and (_path_served_requesters.has(requester_id) \
					or _has_pending_global_requester(requester_id))):
			_enqueue_global_path(start_index, goal_index, requester_id)
			return _pending_path_result(start_index, goal_index)
		_path_budget_remaining -= 1
		_new_path_budget_remaining -= 1
		if requester_id >= 0:
			_path_served_requesters[requester_id] = true
	var step := _step_path_slice(start_index, goal_index)
	if not bool(step.get("complete", false)):
		_enqueue_global_path(start_index, goal_index, requester_id)
		return _pending_path_result(start_index, goal_index)
	return step.get("result", _pending_path_result(start_index, goal_index))


## One slice of a saved A* search, cut down to what is left of this tick's
## expansion budget. The budget counts nodes rather than milliseconds: a wall-clock
## cut-off lands on a different request when the machine is busy, so two same-seed
## runs would hand paths to different animals and drift apart. Wall time is still
## measured, and a tick past `path_time_warning_ms_per_tick` is counted in
## `path_time_warning_ticks`, but nothing reads either to decide what to search.
func _step_path_slice(start_index: int, goal_index: int) -> Dictionary:
	var slice_budget := mini(_path_expansions_per_slice, maxi(1, _path_expansion_budget - _path_expansions_spent))
	var started_at_usec: int = Time.get_ticks_usec()
	var step: Dictionary = terrain_system.step_path_between_indices(start_index, goal_index, slice_budget)
	var elapsed_ms := float(Time.get_ticks_usec() - started_at_usec) / 1000.0
	var expanded := int(step.get("expanded", 0))
	_path_expansions_spent += expanded
	performance_counters["path_expansions"] += expanded
	performance_counters["pathfind_ms"] += elapsed_ms
	if float(performance_counters["pathfind_ms"]) > _path_time_warning_ms:
		performance_counters["path_time_warning_ticks"] = 1
	return step


func _pending_path_result(start_index: int, goal_index: int) -> Dictionary:
	return {"cells": [], "cost": INF, "reachable": false,
		"start_index": start_index, "goal_index": goal_index, "pending": true}


func _has_pending_global_requester(requester_id: int) -> bool:
	for request in _pending_global_paths:
		if int(request.get("requester_id", -1)) == requester_id:
			return true
	return false


func _enqueue_global_path(start_index: int, goal_index: int, requester_id: int) -> void:
	var key := Vector2i(start_index, goal_index)
	if _pending_global_path_keys.has(key):
		return
	if requester_id >= 0:
		for request in _pending_global_paths:
			if int(request.get("requester_id", -1)) == requester_id:
				return
	_pending_global_path_keys[key] = true
	_pending_global_paths.append({"key": key, "start": start_index, "goal": goal_index,
		"requester_id": requester_id})


func _service_pending_global_paths() -> void:
	var deferred: Array = []
	while not _pending_global_paths.is_empty() and _path_budget_remaining > 0 \
			and _new_path_budget_remaining > 0 and _path_expansions_spent < _path_expansion_budget:
		var request: Dictionary = _pending_global_paths.pop_front()
		var key: Vector2i = request.key
		_pending_global_path_keys.erase(key)
		var requester_id := int(request.get("requester_id", -1))
		if requester_id >= 0 and _path_served_requesters.has(requester_id):
			deferred.append(request)
			continue
		var start_index := int(request.start)
		var goal_index := int(request.goal)
		if terrain_system.has_cached_path_between_indices(start_index, goal_index):
			continue
		_path_budget_remaining -= 1
		_new_path_budget_remaining -= 1
		if requester_id >= 0:
			_path_served_requesters[requester_id] = true
		var step := _step_path_slice(start_index, goal_index)
		if not bool(step.get("complete", false)):
			deferred.append(request)
	for request in deferred:
		_pending_global_paths.append(request)
		_pending_global_path_keys[request.key] = true


func _enqueue_local_path(agent_id: int, target: Vector2) -> void:
	if agent_id < 0:
		return
	_pending_local_paths[agent_id] = target
	if not _pending_local_agent_ids.has(agent_id):
		_pending_local_agent_ids.append(agent_id)


func _service_pending_local_paths() -> void:
	while not _pending_local_agent_ids.is_empty() and _local_path_budget > 0:
		var agent_id: int = _pending_local_agent_ids.pop_front()
		var target: Vector2 = _pending_local_paths.get(agent_id, Vector2.INF)
		_pending_local_paths.erase(agent_id)
		var agent = get_agent(agent_id)
		if agent == null or not agent.is_alive or target == Vector2.INF:
			continue
		if scenery.segment_clear(agent.position, target, agent.get_body_radius()):
			agent.local_path = PackedVector2Array()
			continue
		_local_path_budget -= 1
		_local_path_served_agents[agent_id] = true
		agent.local_retry_tick = current_tick + 12
		agent.local_path = scenery.local_path(agent.position, target, agent.get_body_radius())
		agent.local_path_goal = target


func _register_living_agent(agent) -> void:
	if agent == null:
		return
	living_agents.append(agent)
	_living_agent_index_by_id[agent.id] = living_agents.size() - 1
	spatial_grid.insert(agent)
	_register_sector_presence(agent)
	_add_agent_to_group_cache(agent)


func _unregister_living_agent(agent) -> void:
	if agent == null:
		return
	_remove_agent_from_group_cache(agent)
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
	# The cached snapshot holds references to neighbouring agents, and two mutual
	# neighbours form a reference cycle. RefCounted has no cycle collector, so without
	# this every agent that ever took a decision tick leaks when it dies or its sector
	# sleeps.
	agent.clear_decision_cache()


func _track_agent_runtime_position(agent, previous_position: Vector2) -> void:
	if agent == null or not agent.is_alive:
		return
	var started_at_usec := Time.get_ticks_usec()
	spatial_grid.update_agent(agent, previous_position)
	_update_agent_sector(agent)
	_move_agent_in_group_cache(agent, previous_position)
	performance_counters["spatial_update_ms"] += float(Time.get_ticks_usec() - started_at_usec) / 1000.0


func _get_sector_key(position: Vector2) -> Vector2i:
	return Vector2i(floori(position.x / _sector_size), floori(position.y / _sector_size))


## Keeps carcass discovery, dormant feeding and rendering on the same spatial
## ledger. Carcasses do not move, so one sector membership lasts until removal.
func _register_carcass_sector(carcass_id: int, position: Vector2) -> void:
	var sector_key := _get_sector_key(position)
	var sector_state: Dictionary = _get_or_create_sector_state(sector_key)
	var carcass_ids: Array = sector_state.get("carcass_ids", [])
	if not carcass_ids.has(carcass_id):
		carcass_ids.append(carcass_id)
	sector_state["carcass_ids"] = carcass_ids
	_sector_states[sector_key] = sector_state


func _unregister_carcass_sector(carcass_id: int, position: Vector2) -> void:
	var sector_key := _get_sector_key(position)
	var sector_state: Dictionary = _sector_states.get(sector_key, {})
	if sector_state.is_empty():
		return
	var carcass_ids: Array = sector_state.get("carcass_ids", [])
	carcass_ids.erase(carcass_id)
	sector_state["carcass_ids"] = carcass_ids
	_sector_states[sector_key] = sector_state


## Saved version 1 worlds and early version 2 snapshots can lack carcass sector
## membership. Rebuilding from the authoritative carcass records also removes
## stale IDs left by an interrupted older save.
func _rebuild_carcass_sector_index() -> void:
	for sector_key in _sector_states.keys():
		var sector_state: Dictionary = _sector_states[sector_key]
		sector_state["carcass_ids"] = []
		_sector_states[sector_key] = sector_state
	var sorted_ids: Array[int] = []
	for carcass_id in carcasses.keys():
		sorted_ids.append(int(carcass_id))
	sorted_ids.sort()
	for carcass_id in sorted_ids:
		var carcass: Dictionary = carcasses.get(carcass_id, {})
		if carcass.is_empty():
			continue
		_register_carcass_sector(carcass_id, carcass.get("position", bounds.get_center()))


func _sector_key_to_rect(sector_key: Vector2i) -> Rect2:
	return Rect2(Vector2(sector_key.x, sector_key.y) * _sector_size, Vector2.ONE * _sector_size)


## Heads of the given species in a sector.
##
## `species_counts` holds live agents while the sector is awake and is overwritten
## from `dormant_species` the moment it sleeps, so one read covers both paths - and
## that is also why nothing here adds the dormant tally on top. The old readers did
## add it, which was right for a sector that had only just fallen asleep and wrong
## from its first dormant step onwards - `_apply_dormant_sector_step()` copies the
## same census into the flat counts, and from then on the sector reported twice the
## prey it held and outbid live ones for every hunting predator.
func _sector_species_count(sector_state: Dictionary, species_ids: Array) -> int:
	var counts: Dictionary = sector_state.get("species_counts", {})
	if counts.is_empty():
		return 0
	var total: int = 0
	for species_id in species_ids:
		total += int(counts.get(species_id, 0))
	return total


## Mirrors a sleeping sector's aggregate census back onto the flat per-species
## counts, which is what the census, the wake rules and `threat_score` all read.
func _project_dormant_counts_onto_sector(sector_state: Dictionary) -> void:
	var dormant_species: Dictionary = sector_state.get("dormant_species", {})
	var counts: Dictionary = {}
	for species_id in dormant_species.keys():
		counts[species_id] = int((dormant_species[species_id] as Dictionary).get("count", 0))
	sector_state["species_counts"] = counts
	sector_state["threat_score"] = float(_sector_species_count(sector_state, _threat_species_ids))


func _get_or_create_sector_state(sector_key: Vector2i) -> Dictionary:
	if not _sector_states.has(sector_key):
		_sector_states[sector_key] = {
			"agent_ids": [],
			"species_counts": {},
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
			"dormant_aggregates": [],
			"dormant_meat_pool": 0.0,
			"dormant_kill_debt": 0.0,
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
	var species_counts: Dictionary = sector_state.get("species_counts", {})
	species_counts[agent.species_type] = int(species_counts.get(agent.species_type, 0)) + 1
	sector_state["species_counts"] = species_counts
	# Only species that actually hunt something frighten anyone. This used to be the
	# `else` of a herbivore test, so any third species would have been filed as a
	# predator here and driven the herds off a scavenger.
	if species_registry.is_threat(agent.species_type):
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
		var species_counts: Dictionary = sector_state.get("species_counts", {})
		species_counts[agent.species_type] = maxi(0, int(species_counts.get(agent.species_type, 0)) - 1)
		sector_state["species_counts"] = species_counts
		if species_registry.is_threat(agent.species_type):
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


## Group cache key. A Vector2i keeps this allocation-free: the old
## `"%s:%d"` format ran once per agent per tick in the rebuild and again on every
## lookup, which is several hundred throwaway Strings a tick.
func _group_cache_key(species_type: String, group_id: int) -> Vector2i:
	return Vector2i(species_registry.slot(species_type), group_id)


func _add_agent_to_group_cache(agent) -> void:
	if agent == null or not agent.is_alive or agent.group_id == -1:
		return
	var cache_key := _group_cache_key(agent.species_type, agent.group_id)
	var group_state: Dictionary = _group_state_cache.get(cache_key, {
		"count": 0, "sum": Vector2.ZERO, "center": null})
	var count := int(group_state.get("count", 0)) + 1
	var sum: Vector2 = Vector2(group_state.get("sum", Vector2.ZERO)) + agent.position
	group_state["count"] = count
	group_state["sum"] = sum
	group_state["center"] = sum / float(count)
	_group_state_cache[cache_key] = group_state


func _remove_agent_from_group_cache(agent) -> void:
	if agent == null or agent.group_id == -1:
		return
	var cache_key := _group_cache_key(agent.species_type, agent.group_id)
	var group_state: Dictionary = _group_state_cache.get(cache_key, {})
	if group_state.is_empty():
		return
	var count := int(group_state.get("count", 0)) - 1
	if count <= 0:
		_group_state_cache.erase(cache_key)
		return
	var sum: Vector2 = Vector2(group_state.get("sum", Vector2.ZERO)) - agent.position
	group_state["count"] = count
	group_state["sum"] = sum
	group_state["center"] = sum / float(count)
	_group_state_cache[cache_key] = group_state


func _move_agent_in_group_cache(agent, previous_position: Vector2) -> void:
	if agent == null or not agent.is_alive or agent.group_id == -1 \
			or previous_position == agent.position:
		return
	var cache_key := _group_cache_key(agent.species_type, agent.group_id)
	var group_state: Dictionary = _group_state_cache.get(cache_key, {})
	if group_state.is_empty():
		_add_agent_to_group_cache(agent)
		return
	var count := int(group_state.get("count", 0))
	if count <= 0:
		return
	var sum: Vector2 = Vector2(group_state.get("sum", Vector2.ZERO)) \
		+ agent.position - previous_position
	group_state["sum"] = sum
	group_state["center"] = sum / float(count)
	_group_state_cache[cache_key] = group_state


func _rebuild_group_state_cache() -> void:
	_group_state_cache.clear()
	for agent in living_agents:
		if agent == null or not agent.is_alive:
			continue
		if agent.group_id == -1:
			continue
		var cache_key := _group_cache_key(agent.species_type, agent.group_id)
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


## Cached per (sector, biomass threshold). Caching the *absence* of grass matters as
## much as caching its presence: an exhausted sector returns nothing, and treating that
## empty result as a cache miss made it rescan ~625 cells on every query, every tick,
## forever. That cost grows as the world is grazed down, which is what made long
## sessions degrade.
func _get_sector_best_grass(sector_key: Vector2i, min_biomass: float) -> Dictionary:
	var sector_state: Dictionary = _get_or_create_sector_state(sector_key)
	var sector_cache: Dictionary = _sector_grass_cache.get(sector_key, {})
	if bool(sector_state.get("dirty_grass", false)):
		sector_cache = {}
	var threshold_key := int(round(min_biomass * 10.0))
	var cache_entry: Dictionary = sector_cache.get(threshold_key, {})
	var is_stale := cache_entry.is_empty() \
		or current_tick - int(cache_entry.get("refresh_tick", -9999)) >= _sector_grass_refresh_ticks
	if is_stale:
		var sector_rect := _sector_key_to_rect(sector_key)
		var best: Dictionary = resource_system.find_best_cell(sector_rect.get_center(), maxf(sector_rect.size.x, sector_rect.size.y) * 0.75, min_biomass)
		sector_cache[threshold_key] = {
			"result": best,
			"refresh_tick": current_tick,
		}
		_sector_grass_cache[sector_key] = sector_cache
		sector_state["dirty_grass"] = false
		sector_state["last_grass_refresh_tick"] = current_tick
		_sector_states[sector_key] = sector_state
		return best
	return cache_entry.get("result", {})


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
			# Sectors are swept by whole sector, so a corner sector can hold a cell well
			# outside the caller's radius. Honouring the radius is what makes the hunger
			# driven expansion in `_find_grass_target_for_agent` mean anything.
			var candidate_distance := position.distance_to(candidate.get("center", position))
			if candidate_distance > radius:
				continue
			var score := float(candidate.get("biomass", 0.0)) - candidate_distance * 0.14
			if score > best_score:
				best = candidate
				best_score = score
	# Copied once, at the end. The loop used to deep-copy every intermediate
	# winner, and the caller mutates the result (it adds path_cells and score),
	# so the copy still has to happen - just not up to nine times per search.
	return best.duplicate(true) if not best.is_empty() else best


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
	var stale_candidates: Array = []
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
		if _dormant_sector_should_force_wake(sector_key, sector_state, lod_context):
			sectors_to_wake.append(sector_key)
			continue
		# Stale reification is a recovery mechanism for the camera vicinity. In a
		# whole-world overview it used to wake one far sector every tick until almost
		# the entire world was materialized again, defeating semantic LOD over time.
		var stale_score := _get_dormant_sector_stale_score(sector_state)
		if not bool(lod_context.get("overview", false)) \
				and stale_score >= _dormant_stale_wake_seconds:
			performance_counters["dormant_stale_sectors"] += 1
			stale_candidates.append({
				"sector_key": sector_key,
				"score": stale_score,
			})
	if stale_candidates.size() > 1:
		stale_candidates.sort_custom(func(a, b): return float(a.get("score", 0.0)) > float(b.get("score", 0.0)))
	var forced_wakes := mini(_dormant_reify_budget_per_tick, stale_candidates.size())
	for index in range(forced_wakes):
		var forced_sector_key: Vector2i = stale_candidates[index].get("sector_key", Vector2i.ZERO)
		if sectors_to_wake.has(forced_sector_key):
			continue
		sectors_to_wake.append(forced_sector_key)
		performance_counters["dormant_forced_wakeups"] += 1
	for sector_key in sectors_to_wake:
		if _sector_states.has(sector_key):
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
	_index_dormant_groups()
	var sectors_to_wake: Array = []
	var sector_keys: Array = _sector_states.keys().duplicate()
	for sector_key in sector_keys:
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
		performance_counters["dormant_steps"] += 1
		sectors_to_wake.append_array(_migrate_dormant_sector_records(sector_key, lod_context))
		var refreshed_state: Dictionary = _sector_states.get(sector_key, {})
		if refreshed_state.is_empty() or not bool(refreshed_state.get("dormant", false)):
			continue
		if _resolve_sector_lod_tier(sector_key, lod_context) != LOD_TIER_2 or _dormant_sector_should_force_wake(sector_key, refreshed_state, lod_context):
			sectors_to_wake.append(sector_key)
	var unique_wakes: Array = []
	for sector_key in sectors_to_wake:
		if unique_wakes.has(sector_key):
			continue
		unique_wakes.append(sector_key)
	for sector_key in unique_wakes:
		if _sector_states.has(sector_key):
			_wake_sector(sector_key)
	_dormant_group_index.clear()


## A herd whose members sit in two sectors is two aggregates, each stepping on its own.
## With real positions that happens whenever a herd crosses a sector boundary, and two
## halves picking their own goals would walk apart. This indexes each group once per
## tick: its total count and weighted centre, and the goal of its largest part, which
## the other parts follow. Groups without an id (-1) are independent animals and are
## not indexed.
func _index_dormant_groups() -> void:
	_dormant_group_index.clear()
	for sector_key in _sector_states.keys():
		var sector_state: Dictionary = _sector_states[sector_key]
		if not bool(sector_state.get("dormant", false)):
			continue
		for aggregate in sector_state.get("dormant_aggregates", []):
			var group_id := int(aggregate.get("group_id", -1))
			var count := int(aggregate.get("count", 0))
			if group_id < 0 or count <= 0:
				continue
			var group_key := _get_dormant_aggregate_key(str(aggregate.get("species_type", "")), group_id)
			var entry: Dictionary = _dormant_group_index.get(group_key, {
				"parts": 0, "count": 0, "center_sum": Vector2.ZERO, "owner_sector": sector_key, "owner_count": -1})
			entry["parts"] = int(entry["parts"]) + 1
			entry["count"] = int(entry["count"]) + count
			entry["center_sum"] = Vector2(entry["center_sum"]) + Vector2(aggregate.get("center", Vector2.ZERO)) * float(count)
			var owner_sector: Vector2i = entry["owner_sector"]
			if count > int(entry["owner_count"]) or (count == int(entry["owner_count"]) \
					and (sector_key.x < owner_sector.x or (sector_key.x == owner_sector.x and sector_key.y < owner_sector.y))):
				entry["owner_sector"] = sector_key
				entry["owner_count"] = count
				var goal := {}
				for goal_key in ["goal_kind", "goal_position", "goal_sector", "carcass_id", "last_goal_refresh_time"]:
					if aggregate.has(goal_key):
						goal[goal_key] = aggregate[goal_key]
				entry["goal"] = goal
			_dormant_group_index[group_key] = entry


## The goal a part of a split group should follow, or empty when this aggregate is the
## group's largest part (or the group is not split) and picks its own.
func _dormant_shared_goal(sector_key: Vector2i, aggregate: Dictionary) -> Dictionary:
	var group_id := int(aggregate.get("group_id", -1))
	if group_id < 0:
		return {}
	var entry: Dictionary = _dormant_group_index.get(_get_dormant_aggregate_key(str(aggregate.get("species_type", "")), group_id), {})
	if entry.is_empty() or int(entry.get("parts", 0)) < 2 or entry.get("owner_sector", sector_key) == sector_key:
		return {}
	return entry.get("goal", {})


func _can_sleep_sector(sector_key: Vector2i, lod_context: Dictionary) -> bool:
	var sector_state: Dictionary = _sector_states.get(sector_key, {})
	if sector_state.is_empty():
		return false
	for agent_id in sector_state.get("agent_ids", []):
		if int(agent_id) == int(lod_context.get("selected_agent_id", -1)):
			return false
		var agent = get_agent(int(agent_id))
		if agent == null or not agent.is_alive:
			continue
		if agent.lod_tier != LOD_TIER_2:
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
	# A zoom change can put dozens of sectors to sleep on one tick. A stable
	# phase keeps their aggregate ecology and migration work from recurring in
	# one large burst every `_very_far_sector_step_seconds`.
	sector_state["dormant_elapsed"] = _dormant_phase_offset(sector_key)
	sector_state["dormant_species"] = _build_dormant_species_state(records)
	sector_state["dormant_aggregates"] = _build_dormant_aggregates(records, sector_key)
	sector_state["dormant_count"] = records.size()
	sector_state["agent_ids"] = []
	_project_dormant_counts_onto_sector(sector_state)
	_sector_states[sector_key] = sector_state


func _dormant_phase_offset(sector_key: Vector2i) -> float:
	var hash_bucket := posmod(sector_key.x * 73856093 + sector_key.y * 19349663, 97)
	return _very_far_sector_step_seconds * float(hash_bucket) / 97.0


func _wake_sector(sector_key: Vector2i) -> void:
	var sector_state: Dictionary = _sector_states.get(sector_key, {})
	if sector_state.is_empty() or not bool(sector_state.get("dormant", false)):
		return
	# Records wake exactly as they slept or as the coarse step last advanced them.
	# Waking used to re-place every animal on a ring around its group's centre and
	# reset each one's needs and age to the group mean, which is what made a herd
	# collapse on zoom-out and spread back apart over the next seconds.
	var records: Array = sector_state.get("dormant_records", [])
	# Before the restores: `_register_living_agent()` adds each one back to
	# `species_counts`, which still holds the aggregate census standing in for them.
	sector_state["species_counts"] = {}
	sector_state["threat_score"] = 0.0
	_sector_states[sector_key] = sector_state
	for record in records:
		var agent = _restore_dormant_agent(record)
		if agent != null:
			_register_living_agent(agent)
	sector_state = _get_or_create_sector_state(sector_key)
	sector_state["dormant"] = false
	sector_state["dormant_records"] = []
	sector_state["dormant_species"] = {}
	sector_state["dormant_aggregates"] = []
	sector_state["dormant_count"] = 0
	sector_state["dormant_elapsed"] = 0.0
	# The coarse meat pool and kill debt only mean anything while the sector is asleep;
	# once awake its predators eat real carcasses through the normal ledger.
	sector_state["dormant_meat_pool"] = 0.0
	sector_state["dormant_kill_debt"] = 0.0
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


func _get_dormant_aggregate_key(species_key: String, group_id: int) -> String:
	return "%s:%d" % [species_key, group_id]


func _get_dormant_record_aggregate_key(record: Dictionary) -> String:
	return _get_dormant_aggregate_key(str(record.get("species_type", "")), int(record.get("group_id", -1)))


func _build_dormant_aggregate_previous_map(aggregates: Array) -> Dictionary:
	var previous_map: Dictionary = {}
	for aggregate in aggregates:
		previous_map[_get_dormant_aggregate_key(str(aggregate.get("species_type", "")), int(aggregate.get("group_id", -1)))] = aggregate
	return previous_map


func _build_dormant_aggregates(records: Array, sector_key: Vector2i, previous_map: Dictionary = {}) -> Array:
	var grouped: Dictionary = {}
	for record in records:
		var aggregate_key: String = _get_dormant_record_aggregate_key(record)
		var aggregate: Dictionary = grouped.get(aggregate_key, {
			"species_type": str(record.get("species_type", "")),
			"group_id": int(record.get("group_id", -1)),
			"count": 0,
			"center_sum": Vector2.ZERO,
			"velocity_sum": Vector2.ZERO,
			"avg_hunger_sum": 0.0,
			"avg_thirst_sum": 0.0,
			"avg_energy_sum": 0.0,
			"avg_age_sum": 0.0,
			"mature_males": 0,
			"mature_females": 0,
			"ready_males": 0,
			"ready_females": 0,
			"old_age_count": 0,
			"max_age_count": 0,
			"record_ids": [],
			"record_positions": PackedVector2Array(),
		})
		aggregate["count"] = int(aggregate.get("count", 0)) + 1
		aggregate["center_sum"] = Vector2(aggregate.get("center_sum", Vector2.ZERO)) + Vector2(record.get("position", bounds.get_center()))
		aggregate["velocity_sum"] = Vector2(aggregate.get("velocity_sum", Vector2.ZERO)) + Vector2(record.get("velocity", Vector2.ZERO))
		aggregate["avg_hunger_sum"] = float(aggregate.get("avg_hunger_sum", 0.0)) + float(record.get("hunger", 0.0))
		aggregate["avg_thirst_sum"] = float(aggregate.get("avg_thirst_sum", 0.0)) + float(record.get("thirst", 0.0))
		aggregate["avg_energy_sum"] = float(aggregate.get("avg_energy_sum", 0.0)) + float(record.get("energy", 0.0))
		aggregate["avg_age_sum"] = float(aggregate.get("avg_age_sum", 0.0)) + float(record.get("age", 0.0))
		_tally_dormant_member(aggregate, record)
		var record_ids: Array = aggregate.get("record_ids", [])
		record_ids.append(int(record.get("id", -1)))
		aggregate["record_ids"] = record_ids
		var record_positions: PackedVector2Array = aggregate["record_positions"]
		record_positions.append(Vector2(record.get("position", bounds.get_center())))
		aggregate["record_positions"] = record_positions
		grouped[aggregate_key] = aggregate
	var aggregates: Array = []
	for aggregate_key in grouped.keys():
		var aggregate: Dictionary = grouped[aggregate_key]
		var count: int = max(1, int(aggregate.get("count", 0)))
		var previous: Dictionary = previous_map.get(aggregate_key, {})
		var center: Vector2 = Vector2(aggregate.get("center_sum", Vector2.ZERO)) / float(count)
		var velocity: Vector2 = Vector2(aggregate.get("velocity_sum", Vector2.ZERO)) / float(count)
		aggregate.erase("center_sum")
		aggregate.erase("velocity_sum")
		aggregate["center"] = center
		# How spread out the herd was when it fell asleep. The dormant drift pulls
		# strays back past half again this, so the formation keeps its own scale
		# instead of freezing, collapsing, or diffusing across the sector.
		var radius_sum := 0.0
		for member_position in aggregate["record_positions"]:
			radius_sum += member_position.distance_to(center)
		aggregate["spread_radius"] = radius_sum / float(count)
		aggregate["velocity"] = velocity if previous.is_empty() else Vector2(previous.get("velocity", velocity))
		aggregate["avg_hunger"] = float(aggregate.get("avg_hunger_sum", 0.0)) / float(count)
		aggregate["avg_thirst"] = float(aggregate.get("avg_thirst_sum", 0.0)) / float(count)
		aggregate["avg_energy"] = float(aggregate.get("avg_energy_sum", 0.0)) / float(count)
		aggregate["avg_age"] = float(aggregate.get("avg_age_sum", 0.0)) / float(count)
		aggregate.erase("avg_hunger_sum")
		aggregate.erase("avg_thirst_sum")
		aggregate.erase("avg_energy_sum")
		aggregate.erase("avg_age_sum")
		aggregate["goal_position"] = previous.get("goal_position", center)
		aggregate["goal_sector"] = previous.get("goal_sector", sector_key)
		aggregate["goal_kind"] = str(previous.get("goal_kind", "wander"))
		aggregate["last_goal_refresh_time"] = float(previous.get("last_goal_refresh_time", current_time))
		aggregate["stale_time"] = float(previous.get("stale_time", 0.0))
		aggregate["home_position"] = previous.get("home_position", center)
		# Aggregates are rebuilt from records on every dormant step, so anything that has to
		# survive across steps must be carried over explicitly. The debts are fractional
		# accumulators: dropping them silently floored every sub-one-per-step rate to zero,
		# which suppressed births and need-deaths for any aggregate small enough that its
		# per-step share was below 1. `carcass_id` identifies the carcass a `seek_carcass`
		# goal refers to, so losing it broke dormant scavenging entirely.
		for carried_key in ["birth_debt", "starvation_debt", "thirst_debt", "old_age_debt", "carcass_id"]:
			if previous.has(carried_key):
				aggregate[carried_key] = previous[carried_key]
		aggregates.append(aggregate)
	return aggregates


## Adds one record to the maturity, readiness and age tallies the coarse step reads.
## Shared by the aggregate build and the per-step reconcile so the two cannot drift.
func _tally_dormant_member(aggregate: Dictionary, record: Dictionary) -> void:
	var species_config: Dictionary = config_bundle.get("species", {}).get(str(record.get("species_type", "")), {})
	var reproduction_config: Dictionary = species_config.get("reproduction", {})
	var aging_config: Dictionary = species_config.get("aging", {})
	var record_age := float(record.get("age", 0.0))
	var is_mature := record_age >= float(reproduction_config.get("maturity_age", 0.0))
	var is_ready := is_mature \
		and float(record.get("reproduction_cooldown", 0.0)) <= 0.0 \
		and float(record.get("energy", 0.0)) >= float(reproduction_config.get("energy_threshold", INF)) \
		and float(record.get("hunger", 0.0)) <= float(reproduction_config.get("max_hunger", 100.0)) \
		and float(record.get("thirst", 0.0)) <= float(reproduction_config.get("max_thirst", 100.0))
	var sex := str(record.get("sex", AgentBaseScript.SEX_FEMALE))
	if is_mature:
		var mature_key := "mature_males" if sex == AgentBaseScript.SEX_MALE else "mature_females"
		aggregate[mature_key] = int(aggregate.get(mature_key, 0)) + 1
	if is_ready:
		var ready_key := "ready_males" if sex == AgentBaseScript.SEX_MALE else "ready_females"
		aggregate[ready_key] = int(aggregate.get(ready_key, 0)) + 1
	if record_age >= float(aging_config.get("old_age_start", aging_config.get("max_age", INF))):
		aggregate["old_age_count"] = int(aggregate.get("old_age_count", 0)) + 1
	if record_age >= float(aging_config.get("max_age", INF)):
		aggregate["max_age_count"] = int(aggregate.get("max_age_count", 0)) + 1


func _get_dormant_sector_stale_score(sector_state: Dictionary) -> float:
	var stale_score: float = 0.0
	for aggregate in sector_state.get("dormant_aggregates", []):
		stale_score = maxf(stale_score, float(aggregate.get("stale_time", 0.0)))
	return stale_score


func _refresh_dormant_sector_state(sector_key: Vector2i, preserve_existing: bool = true) -> void:
	var sector_state: Dictionary = _sector_states.get(sector_key, {})
	if sector_state.is_empty():
		return
	var records: Array = sector_state.get("dormant_records", [])
	var previous_map: Dictionary = {}
	if preserve_existing:
		previous_map = _build_dormant_aggregate_previous_map(sector_state.get("dormant_aggregates", []))
	if records.is_empty():
		sector_state["dormant_records"] = []
		sector_state["dormant_species"] = {}
		sector_state["dormant_aggregates"] = []
		sector_state["dormant_count"] = 0
		sector_state["species_counts"] = {}
		sector_state["threat_score"] = 0.0
		sector_state["dormant"] = false
		if sector_state.get("agent_ids", []).is_empty() and sector_state.get("carcass_ids", []).is_empty() and not bool(sector_state.get("water", false)):
			_sector_states.erase(sector_key)
		else:
			_sector_states[sector_key] = sector_state
		return
	sector_state["dormant"] = true
	sector_state["dormant_species"] = _build_dormant_species_state(records)
	sector_state["dormant_aggregates"] = _build_dormant_aggregates(records, sector_key, previous_map)
	sector_state["dormant_count"] = records.size()
	_project_dormant_counts_onto_sector(sector_state)
	_sector_states[sector_key] = sector_state


func _find_nearest_water_goal(position: Vector2) -> Dictionary:
	var best: Dictionary = {}
	var best_distance_sq: float = INF
	for source in water_sources:
		var source_position: Vector2 = source.get("position", bounds.get_center())
		var distance_sq: float = position.distance_squared_to(source_position)
		if distance_sq < best_distance_sq:
			best_distance_sq = distance_sq
			best = {
				"goal_kind": "water",
				"goal_position": source_position,
				"goal_sector": _get_sector_key(source_position),
			}
	return best


func _find_dormant_grass_goal(position: Vector2, radius: float, min_biomass: float = 0.0) -> Dictionary:
	var center_sector: Vector2i = _get_sector_key(position)
	var sector_radius: int = maxi(1, int(ceil(radius / _sector_size)))
	var best: Dictionary = {}
	var best_score: float = -INF
	for x in range(center_sector.x - sector_radius, center_sector.x + sector_radius + 1):
		for y in range(center_sector.y - sector_radius, center_sector.y + sector_radius + 1):
			var candidate_sector: Vector2i = Vector2i(x, y)
			var candidate: Dictionary = _get_sector_best_grass(candidate_sector, min_biomass)
			if candidate.is_empty():
				continue
			var candidate_center: Vector2 = candidate.get("center", _sector_key_to_rect(candidate_sector).get_center())
			var score: float = float(candidate.get("biomass", 0.0)) - position.distance_to(candidate_center) * 0.08
			if score <= best_score:
				continue
			best_score = score
			best = {
				"goal_kind": "grass",
				"goal_position": candidate_center,
				"goal_sector": candidate_sector,
			}
	return best


## Sectors that currently hold herbivores, highest pressure first, rebuilt on a throttle.
##
## This is the simulation's only long-range prey signal, and both the dormant goal
## selector and the live predator patrol read it. A predator sees 480 units while herds
## sit roughly 3100 apart on the large map, so without a sector-level census it cannot
## find prey it has lost sight of. `herbivore_count` is maintained for live sectors too
## by `_register_sector_presence()`, so one cache covers both paths.
func _refresh_prey_pressure_sectors() -> void:
	if current_tick - _prey_pressure_refresh_tick < _prey_pressure_refresh_ticks:
		return
	_prey_pressure_refresh_tick = current_tick
	var entries: Array = []
	for sector_key in _sector_states.keys():
		var sector_state: Dictionary = _sector_states[sector_key]
		var pressure: int = _sector_species_count(sector_state, _prey_species_ids)
		if pressure <= 0:
			continue
		entries.append({
			"sector": sector_key,
			"center": _sector_key_to_rect(sector_key).get_center(),
			"pressure": pressure,
		})
	entries.sort_custom(func(a, b): return int(a["pressure"]) > int(b["pressure"]))
	if entries.size() > PREY_PRESSURE_CACHE_LIMIT:
		entries = entries.slice(0, PREY_PRESSURE_CACHE_LIMIT)
	_prey_pressure_sectors = entries


## Best prey-bearing sector within `radius`, scored as the dormant selector always scored
## it: pressure dominates and distance breaks ties.
func find_prey_pressure_goal(position: Vector2, radius: float) -> Dictionary:
	var best: Dictionary = {}
	var best_score: float = -INF
	for entry in _prey_pressure_sectors:
		var center: Vector2 = entry["center"]
		var distance: float = position.distance_to(center)
		if distance > radius:
			continue
		var score: float = float(entry["pressure"]) * 10.0 - distance * 0.1
		if score <= best_score:
			continue
		best_score = score
		best = {
			"goal_kind": "hunt",
			"goal_position": center,
			"goal_sector": entry["sector"],
		}
	return best


func _find_dormant_prey_goal(position: Vector2, radius: float) -> Dictionary:
	return find_prey_pressure_goal(position, radius)


## `max_age` mirrors `AgentBase.accepts_carcass()`, so a sleeping aggregate is
## not sent to a body its live counterpart would refuse as too old.
func _find_dormant_carcass_goal(sector_key: Vector2i, position: Vector2, radius: float, max_age: float = INF) -> Dictionary:
	var sector_radius: int = maxi(1, int(ceil(radius / _sector_size)))
	var best: Dictionary = {}
	var best_distance_sq: float = INF
	for x in range(sector_key.x - sector_radius, sector_key.x + sector_radius + 1):
		for y in range(sector_key.y - sector_radius, sector_key.y + sector_radius + 1):
			var candidate_sector: Vector2i = Vector2i(x, y)
			var sector_state: Dictionary = _sector_states.get(candidate_sector, {})
			if sector_state.is_empty():
				continue
			for carcass_id in sector_state.get("carcass_ids", []):
				var carcass: Dictionary = get_carcass(int(carcass_id))
				if carcass.is_empty():
					continue
				if max_age != INF and current_time - float(carcass.get("created_at", 0.0)) > max_age:
					continue
				var carcass_position: Vector2 = carcass.get("position", _sector_key_to_rect(candidate_sector).get_center())
				var distance_sq: float = position.distance_squared_to(carcass_position)
				if distance_sq >= best_distance_sq:
					continue
				best_distance_sq = distance_sq
				best = {
					"goal_kind": "seek_carcass",
					"goal_position": carcass_position,
					"goal_sector": candidate_sector,
					"carcass_id": int(carcass_id),
				}
	return best


func _get_dormant_group_center(species_type: String, group_id: int, fallback_sector_key: Vector2i) -> Variant:
	if group_id == -1:
		return null
	var total: Vector2 = Vector2.ZERO
	var count: int = 0
	# Inside a dormant step the group index already holds this sum, so goal refreshes
	# stop scanning every sector once per aggregate.
	var indexed: Dictionary = _dormant_group_index.get(_get_dormant_aggregate_key(species_type, group_id), {})
	if not indexed.is_empty():
		total = indexed["center_sum"]
		count = int(indexed["count"])
	else:
		for sector_key in _sector_states.keys():
			var sector_state: Dictionary = _sector_states[sector_key]
			if not bool(sector_state.get("dormant", false)):
				continue
			for aggregate in sector_state.get("dormant_aggregates", []):
				if str(aggregate.get("species_type", "")) != species_type or int(aggregate.get("group_id", -1)) != group_id:
					continue
				var aggregate_count := int(aggregate.get("count", 0))
				total += Vector2(aggregate.get("center", _sector_key_to_rect(sector_key).get_center())) * float(aggregate_count)
				count += aggregate_count
	var active_center = get_group_center(group_id, species_type, -1)
	if active_center != null:
		total += active_center
		count += 1
	if count <= 0:
		return _sector_key_to_rect(fallback_sector_key).get_center()
	return total / float(count)


func _resolve_dormant_wander_goal(sector_key: Vector2i, aggregate: Dictionary) -> Dictionary:
	# The last row and column of sectors run past the map edge, so the centre of the
	# part inside the map is used. The raw centre was clamped onto the edge itself and
	# pinned every herd wandering there against it.
	var sector_center: Vector2 = _sector_key_to_rect(sector_key).intersection(bounds).get_center()
	var home_position: Vector2 = aggregate.get("home_position", sector_center)
	var blend_target: Vector2 = sector_center.lerp(home_position, 0.65)
	var jitter_direction: Vector2 = Vector2.RIGHT.rotated(float(int(aggregate.get("group_id", -1)) * 13 + int(aggregate.get("count", 0))))
	var goal_position: Vector2 = get_nearest_walkable_position(clamp_position(blend_target + jitter_direction * minf(_sector_size * 0.2, 48.0)))
	return {
		"goal_kind": "wander",
		"goal_position": goal_position,
		"goal_sector": _get_sector_key(goal_position),
	}


## Goal-directed travel speed for a dormant aggregate.
##
## `dormant_speed_scale` is a fixed 0.45, but `sector_size` scales with the map and that
## did not: on the large map an aggregate has to cross three times the distance per unit
## of hunger it did on the small one, which is what turned cross-sector travel from slow
## into lethal. Scaling with sector size keeps the abstraction's reachability
## size-invariant; the `sprint_speed` clamp keeps it from outrunning a real animal.
func _get_dormant_travel_speed(species_config: Dictionary, is_directed: bool = true) -> float:
	var movement: Dictionary = species_config.get("movement", {})
	var reference := maxf(1.0, float(simulation_lod_config.get("dormant_travel_reference_sector_size", 512.0)))
	var travel_scale := maxf(1.0, _sector_size / reference)
	var speed := float(movement.get("max_speed", 70.0)) * _dormant_speed_scale * travel_scale
	if is_directed:
		speed *= float(simulation_lod_config.get("dormant_directed_speed_boost", 1.2))
	return minf(speed, float(movement.get("sprint_speed", movement.get("max_speed", 70.0))))


func _select_dormant_goal(sector_key: Vector2i, aggregate: Dictionary) -> Dictionary:
	var species_key := str(aggregate.get("species_type", ""))
	var species_config: Dictionary = config_bundle.get("species", {}).get(species_key, {})
	var perception: Dictionary = species_config.get("perception", {})
	var thresholds: Dictionary = config_bundle.get("balance", {}).get("state_thresholds", {})
	var center: Vector2 = aggregate.get("center", _sector_key_to_rect(sector_key).get_center())
	var dormant_config: Dictionary = config_bundle.get("balance", {}).get("dormant_ecology", {})
	var critical_thirst := float(thresholds.get("critical_thirst", 65.0))
	var graze_hunger_floor := float(thresholds.get("graze_hunger_floor", 20.0))
	var diet: String = species_registry.diet(species_key)
	if diet == SpeciesRegistryScript.DIET_GRASS:
		if float(aggregate.get("avg_thirst", 0.0)) >= critical_thirst:
			var water_goal: Dictionary = _find_nearest_water_goal(center)
			if not water_goal.is_empty():
				return water_goal
		if float(aggregate.get("avg_hunger", 0.0)) >= graze_hunger_floor:
			var grass_goal: Dictionary = _find_dormant_grass_goal(center, maxf(float(perception.get("grass_search_radius", 180.0)) * 2.5, _sector_size * 3.0), 2.0)
			if not grass_goal.is_empty():
				return grass_goal
		if int(aggregate.get("group_id", -1)) != -1:
			var group_center: Variant = _get_dormant_group_center(species_key, int(aggregate.get("group_id", -1)), sector_key)
			if group_center != null and center.distance_to(group_center) > _sector_size * 0.35:
				return {
					"goal_kind": "regroup",
					"goal_position": group_center,
					"goal_sector": _get_sector_key(group_center),
				}
		return _resolve_dormant_wander_goal(sector_key, aggregate)
	# Thirst first: it is the tighter clock. A predator has 36.7 s of headroom between
	# `critical_thirst` and death, against 53.75 s for hunger, so checking prey first
	# could send a thirsty predator across the map and kill it on the way.
	var predator_thirst := float(aggregate.get("avg_thirst", 0.0))
	if predator_thirst >= critical_thirst * float(dormant_config.get("predator_thirst_trigger_ratio", 0.6)):
		var predator_water_goal: Dictionary = _find_nearest_water_goal(center)
		if not predator_water_goal.is_empty():
			return predator_water_goal
	var travel_speed := _get_dormant_travel_speed(species_config)
	# Only look as far as the hunger clock can actually carry the aggregate. The old
	# `max(vision * 1.5, sector_size * 3)` was 4608 units on the large map, which needs
	# 143 hunger points of travel - more than the scale has - so predators committed to
	# goals they could never reach and starved en route.
	var carcass_ttl := float(config_bundle.get("balance", {}).get("carcass", {}).get("ttl_seconds", 30.0))
	var carcass_goal: Dictionary = _find_dormant_carcass_goal(
		sector_key, center, maxf(carcass_ttl * travel_speed * 0.8, _sector_size),
		species_registry.carrion_max_age(species_key))
	if not carcass_goal.is_empty():
		return carcass_goal
	var predator_hunger := float(aggregate.get("avg_hunger", 0.0))
	# Hunt from the same floor the live path uses via `_is_hungry_enough_to_feed`, not
	# from `critical_hunger * 0.9`: at 54 hunger only 27.5 s of travel remained, less
	# than the width of one sector.
	# A carrion eater takes the same water-then-carcass route above and stops there:
	# it has no hunt to fall through to, so it wanders on to the next body instead.
	if diet != SpeciesRegistryScript.DIET_PREY:
		return _resolve_dormant_wander_goal(sector_key, aggregate)
	if predator_hunger >= graze_hunger_floor:
		# Already standing among prey: hunt here. Without this the goal refresh that fires
		# on arrival could send the aggregate off to another sector, so it spent most of its
		# time travelling between herds rather than beside one - and a dormant kill can only
		# resolve while predator and prey share a sector.
		if _get_sector_prey_pressure(sector_key) > 0:
			return {
				"goal_kind": "hunt",
				"goal_position": center,
				"goal_sector": sector_key,
			}
		# Keep an existing hunt goal that is still valid. The refresh in
		# `_apply_dormant_sector_step` fires whenever the aggregate is within
		# `sector_size * 0.18` of its goal, so re-picking on approach let a hunting
		# aggregate dither its whole travel budget away.
		if str(aggregate.get("goal_kind", "")) == "hunt" \
				and not _dormant_aggregate_reached_goal(sector_key, aggregate) \
				and _get_sector_prey_pressure(Vector2i(aggregate.get("goal_sector", sector_key))) > 0:
			return {
				"goal_kind": "hunt",
				"goal_position": aggregate.get("goal_position", center),
				"goal_sector": aggregate.get("goal_sector", sector_key),
			}
		var hunger_headroom := maxf(1.0, 98.0 - predator_hunger) / maxf(0.01, float(species_config.get("metabolism", {}).get("hunger_rate", 1.6)))
		# The 0.6 covers terrain move cost, water detours and prey that keeps moving. The
		# floor matters as much as the cap: heading for prey it may not reach still beats
		# wandering, so a nearly starved aggregate must not fall back to a random walk.
		var prey_reach := maxf(hunger_headroom * travel_speed * 0.6, _sector_size * 1.5)
		var prey_goal: Dictionary = _find_dormant_prey_goal(center, prey_reach)
		if not prey_goal.is_empty():
			return prey_goal
	return _resolve_dormant_wander_goal(sector_key, aggregate)


## Energy ceiling recovery may reach in the aggregate's current mode, or a negative value
## when it should be decaying instead. Mirrors `AgentBase.update_needs()`, which recovers in
## the rest / eat / drink / feed states and decays otherwise.
##
## Idle rest is capped at `rest_energy_resume`, the point a live agent stops resting. Only
## actually feeding or drinking carries an aggregate past that, which matters because the
## breeding gate is an energy threshold: uncapped idle recovery would hand every fed
## aggregate its breeding reserve for free and turn the coarse path into a population pump.
func _dormant_energy_recovery_ceiling(
	sector_key: Vector2i,
	aggregate: Dictionary,
	avg_hunger: float,
	avg_thirst: float,
	thresholds: Dictionary,
	max_energy: float
) -> float:
	var goal_kind := str(aggregate.get("goal_kind", "wander"))
	# Tie the idle ceiling to what it is actually protecting - the breeding reserve - rather
	# than to `rest_energy_resume`, which is scaled for the herbivore's smaller maximum. At
	# 34 a predator woken from dormancy had roughly six seconds of chase energy, which
	# surfaced as a wall of `low_energy` hunt failures. Staying below the reserve still means
	# only real food can buy a litter.
	var reproduction_config: Dictionary = config_bundle.get("species", {}).get(str(aggregate.get("species_type", "")), {}).get("reproduction", {})
	var metabolism_config: Dictionary = config_bundle.get("species", {}).get(str(aggregate.get("species_type", "")), {}).get("metabolism", {})
	var idle_ratio := float(config_bundle.get("balance", {}).get("dormant_ecology", {}).get("idle_recovery_energy_ratio", 0.75))
	var rest_ceiling := maxf(
		float(metabolism_config.get("rest_energy_resume", thresholds.get("rest_energy_resume", 34.0))),
		float(reproduction_config.get("energy_threshold", 0.0)) * idle_ratio
	)
	# At a food or water goal the aggregate is eating or drinking, and those live states
	# recover energy too - this is the only path to the breeding reserve.
	if goal_kind in ["grass", "water", "seek_carcass"]:
		return max_energy if _dormant_aggregate_reached_goal(sector_key, aggregate) else -1.0
	# A predator stalking a herd it has not caught yet is resting between attempts, so it
	# recovers only to the point a live agent stops resting. Withholding this entirely
	# looks tidier but bottoms its energy out, and `hunt.min_chase_energy` then aborts every
	# chase the moment it wakes - which shows up as a wall of `low_energy` hunt failures.
	# Reaching the breeding reserve still requires actually eating.
	if goal_kind == "hunt":
		return rest_ceiling if _dormant_aggregate_reached_goal(sector_key, aggregate) else -1.0
	if goal_kind != "wander":
		return -1.0
	if avg_thirst >= float(thresholds.get("critical_thirst", 65.0)):
		return -1.0
	if avg_hunger >= float(thresholds.get("feed_hunger_floor", thresholds.get("graze_hunger_floor", 12.0))):
		return -1.0
	return rest_ceiling


## Deaths from a saturated need, accumulated as a float debt on the aggregate.
##
## This used to be `maxi(1, ceil(count * clampf(fraction, 0.05, 0.35)))`, where `ceil`
## already forced at least one death per step. At a 0.75 s step that is 1.33 deaths a
## second regardless of how small the group is, so a pair could not survive dormancy at
## all while a herd of twenty died at the intended rate. Carrying the fractional
## remainder makes small aggregates die at the correct *rate* instead.
func _dormant_need_deaths(aggregate: Dictionary, debt_key: String, count: int, need_value: float, elapsed: float) -> int:
	var debt: float = float(aggregate.get(debt_key, 0.0))
	if need_value >= 98.0:
		debt += float(count) * clampf((need_value - 98.0) / 2.0, 0.05, 0.35) * (elapsed / 0.75)
	else:
		debt = 0.0
	var deaths: int = mini(count, int(floor(debt)))
	aggregate[debt_key] = debt - float(deaths)
	return deaths


## The single place a dormant kill can happen. Every removed herbivore produces exactly
## `carcass.meat_total` of meat in the sector's pool, and no meat exists without a
## matching death - the invariant the accounting test asserts.
##
## Uses a float debt rather than rounding per step, because the old per-step
## `int(round(count * pressure * elapsed * 0.18))` needed four co-located predators to
## reach 0.5 and predators spawn in pairs: dormant predation was silently always zero,
## so dormant herbivores were safe while dormant predators had no food source at all.
##
## Deliberately free of `rng` calls: the dormant path must not perturb the shared RNG
## stream, or every agent's rolls shift and the determinism test breaks.
func _resolve_dormant_predation(sector_key: Vector2i, sector_state: Dictionary, aggregates: Array, elapsed: float) -> void:
	var dormant_config: Dictionary = config_bundle.get("balance", {}).get("dormant_ecology", {})
	var carcass_config: Dictionary = config_bundle.get("balance", {}).get("carcass", {})
	var meat_total: float = maxf(1.0, float(carcass_config.get("meat_total", 150.0)))
	var pool: float = float(sector_state.get("dormant_meat_pool", 0.0))

	# Meat rots on the same clock a real carcass does, so a sector cannot bank kills.
	var ttl: float = maxf(1.0, float(carcass_config.get("ttl_seconds", 30.0)))
	if pool > 0.0:
		pool = maxf(0.0, pool - pool * minf(1.0, elapsed / ttl))

	# Who counts as prey here depends on who is hunting, so the hunters are gathered
	# first and their `role.eats_species` decides the rest. Two passes over a handful
	# of per-sector aggregates.
	var prey_aggregates: Array = []
	var local_prey: int = 0
	var hunting_predators: int = 0
	var hunter_species: String = ""
	var hunter_center := Vector2.ZERO
	var hunted_species: Dictionary = {}
	for aggregate in aggregates:
		if int(aggregate.get("count", 0)) <= 0:
			continue
		var species_key := str(aggregate.get("species_type", ""))
		if species_registry.diet(species_key) != SpeciesRegistryScript.DIET_PREY:
			continue
		if str(aggregate.get("goal_kind", "")) != "hunt":
			continue
		hunting_predators += int(aggregate.get("count", 0))
		if hunter_species == "":
			hunter_species = species_key
			hunter_center = aggregate.get("center", _sector_key_to_rect(sector_key).get_center())
		for prey_id in species_registry.prey_set(species_key).keys():
			hunted_species[prey_id] = true
	if hunting_predators > 0:
		for aggregate in aggregates:
			var count: int = int(aggregate.get("count", 0))
			if count <= 0:
				continue
			if hunted_species.has(str(aggregate.get("species_type", ""))):
				prey_aggregates.append(aggregate)
				local_prey += count

	if hunting_predators > 0:
		performance_counters["dormant_hunting_predator_steps"] += hunting_predators
		if local_prey > 0:
			performance_counters["dormant_hunt_colocated_steps"] += hunting_predators
	var kills: int = 0
	var debt: float = float(sector_state.get("dormant_kill_debt", 0.0))
	if hunting_predators > 0 and local_prey > 0:
		var kill_rate: float = float(dormant_config.get("kill_rate_per_prey_per_second", 0.001667))
		debt += float(hunting_predators) * float(local_prey) * kill_rate * elapsed
		kills = mini(local_prey, int(floor(debt)))
		debt -= float(kills)
	else:
		# Progress towards a kill resets when predator and prey are no longer together,
		# rather than being banked for a burst of kills whenever a predator wanders back.
		debt = 0.0
	sector_state["dormant_kill_debt"] = debt

	if kills > 0:
		var remaining: int = kills
		# Largest herd first: a predator in a sector hunts where the prey actually is.
		# The group key breaks ties, since `sort_custom` is not stable.
		prey_aggregates.sort_custom(func(a, b):
			var count_a := int(a.get("count", 0))
			var count_b := int(b.get("count", 0))
			if count_a != count_b:
				return count_a > count_b
			return _get_dormant_aggregate_key(str(a.get("species_type", "")), int(a.get("group_id", -1))) \
				< _get_dormant_aggregate_key(str(b.get("species_type", "")), int(b.get("group_id", -1))))
		for aggregate in prey_aggregates:
			if remaining <= 0:
				break
			var taken: int = mini(remaining, int(aggregate.get("count", 0)))
			aggregate["count"] = int(aggregate.get("count", 0)) - taken
			remaining -= taken
			# Which animals died is settled in `_reconcile_dormant_records()`: the ones
			# nearest the hunters, reported where they stood.
			_queue_dormant_deaths(aggregate, "predation", taken, {"near": hunter_center, "hunter": hunter_species})
		kills -= remaining
		pool += float(kills) * meat_total
		performance_counters["dormant_predation_kills"] += kills
		performance_counters["dormant_meat_granted"] += float(kills) * meat_total

	sector_state["dormant_meat_pool"] = pool


## Predation is deliberately absent here: it lives in `_resolve_dormant_predation()`,
## which is the one place a dormant kill can happen, so a herbivore can never be
## removed without the matching meat being granted.
func _apply_dormant_metabolism_to_aggregate(sector_key: Vector2i, aggregate: Dictionary, elapsed: float) -> void:
	var species_key := str(aggregate.get("species_type", ""))
	var species_config: Dictionary = config_bundle.get("species", {}).get(species_key, {})
	var metabolism: Dictionary = species_config.get("metabolism", {})
	var aging: Dictionary = species_config.get("aging", {})
	var count: int = int(aggregate.get("count", 0))
	if count <= 0:
		return
	var thresholds: Dictionary = config_bundle.get("balance", {}).get("state_thresholds", {})
	# The same climate scale the live agents get, on the same four keys, and with
	# `rest_recovery` left alone for the same reason. If the two ever drift apart,
	# dormant herds survive winters that kill active ones - and since dormancy
	# follows the camera, the divergence hides exactly where you are looking.
	var metabolism_scale: float = climate.metabolism_multiplier
	var avg_hunger: float = minf(100.0, float(aggregate.get("avg_hunger", 0.0)) + float(metabolism.get("hunger_rate", 2.0)) * metabolism_scale * elapsed)
	var avg_thirst: float = minf(100.0, float(aggregate.get("avg_thirst", 0.0)) + float(metabolism.get("thirst_rate", 2.0)) * metabolism_scale * elapsed)
	# Live agents recover energy while resting; the dormant path only ever drained it,
	# so dormant energy fell monotonically to zero. That alone made dormant breeding
	# impossible, because `_compute_dormant_births_for_aggregate` gates on
	# `avg_energy >= reproduction.energy_threshold`. An idle, fed, watered aggregate is
	# resting, and gets the same `rest_recovery` its live counterpart would.
	var max_energy := float(metabolism.get("max_energy", 100.0))
	var avg_energy: float = float(aggregate.get("avg_energy", 0.0))
	var critical_thirst := float(thresholds.get("critical_thirst", 65.0))
	var recovery_ceiling := _dormant_energy_recovery_ceiling(sector_key, aggregate, avg_hunger, avg_thirst, thresholds, max_energy)
	if recovery_ceiling >= 0.0 and avg_energy < recovery_ceiling:
		avg_energy = minf(recovery_ceiling, avg_energy + float(metabolism.get("rest_recovery", 6.0)) * elapsed)
	else:
		# Above its ceiling, or with nothing to recover from, an aggregate burns baseline
		# energy like a live agent outside the recovering states.
		avg_energy = maxf(0.0, avg_energy - float(metabolism.get("energy_decay", 2.0)) * metabolism_scale * elapsed)
		if avg_thirst >= critical_thirst:
			avg_energy = maxf(0.0, avg_energy - float(metabolism.get("dehydration_energy_penalty", 4.0)) * metabolism_scale * elapsed)
	# Aging is not metabolic, matching the unscaled `age += delta` on the agent.
	var avg_age: float = float(aggregate.get("avg_age", 0.0)) + elapsed
	var starvation_deaths: int = _dormant_need_deaths(aggregate, "starvation_debt", count, avg_hunger, elapsed)
	var thirst_deaths: int = _dormant_need_deaths(aggregate, "thirst_debt", count, avg_thirst, elapsed)
	# Age remains cohort based in dormancy. Applying mortality to an aggregate's
	# mean age made one old cohort pull every newborn over the threshold together.
	var forced_old_age_deaths := mini(count, int(aggregate.get("max_age_count", 0)))
	var aging_population := maxi(0, int(aggregate.get("old_age_count", 0)) - forced_old_age_deaths)
	var old_age_debt: float = float(aggregate.get("old_age_debt", 0.0)) \
		+ float(aging_population) * float(aging.get("old_age_death_chance_per_second", 0.0)) * elapsed
	var old_age_deaths := mini(count, forced_old_age_deaths + int(floor(old_age_debt)))
	aggregate["old_age_debt"] = old_age_debt - float(maxi(0, old_age_deaths - forced_old_age_deaths))
	var applied_deaths: int = mini(count, starvation_deaths + thirst_deaths + old_age_deaths)
	count = maxi(0, count - applied_deaths)
	aggregate["count"] = count
	aggregate["avg_hunger"] = avg_hunger
	aggregate["avg_thirst"] = avg_thirst
	aggregate["avg_energy"] = avg_energy
	aggregate["avg_age"] = avg_age
	if applied_deaths <= 0:
		return
	# The requested totals can exceed the aggregate size, so causes are drained in
	# order until the applied budget runs out.
	var deaths_by_cause: Array = [
		["starvation", starvation_deaths],
		["thirst", thirst_deaths],
		["old_age", old_age_deaths],
	]
	for entry in deaths_by_cause:
		var cause_deaths: int = mini(applied_deaths, int(entry[1]))
		_queue_dormant_deaths(aggregate, str(entry[0]), cause_deaths)
		applied_deaths -= cause_deaths
		if applied_deaths <= 0:
			break


## Records how many of a group died of `cause` this step. The step decides numbers;
## `_reconcile_dormant_records()` decides who, the way `births_this_step` works.
func _queue_dormant_deaths(aggregate: Dictionary, cause: String, count: int, details: Dictionary = {}) -> void:
	if count <= 0:
		return
	var entry := details.duplicate()
	entry["cause"] = cause
	entry["count"] = count
	var queued: Array = aggregate.get("deaths_this_step", [])
	queued.append(entry)
	aggregate["deaths_this_step"] = queued


## Births in the coarse path, rate-limited by `reproduction.cooldown`.
##
## An aggregate has no per-animal cooldown timers, so the ceiling is derived: with `count`
## animals each needing `cooldown` seconds between births, the sustainable rate cannot
## exceed `count / cooldown` births per second. The unbounded version stayed hidden only
## because dormant energy could never rise to the threshold; the moment it could, a fed
## aggregate bred on nearly every step.
##
## Fractional births accumulate as a debt for the same reason deaths do - `round()` per step
## either discards the rate entirely for small aggregates or doubles it for large ones.
func _compute_dormant_births_for_aggregate(aggregate: Dictionary, elapsed: float) -> int:
	var count: int = int(aggregate.get("count", 0))
	if count <= 1:
		aggregate["birth_debt"] = 0.0
		return 0
	var reproduction_config: Dictionary = config_bundle.get("species", {}).get(str(aggregate.get("species_type", "")), {}).get("reproduction", {})
	var energy_threshold := float(reproduction_config.get("energy_threshold", 9999.0))
	var avg_energy: float = float(aggregate.get("avg_energy", 0.0))
	var avg_hunger: float = float(aggregate.get("avg_hunger", 0.0))
	var avg_thirst: float = float(aggregate.get("avg_thirst", 0.0))
	var ready_pairs := mini(int(aggregate.get("ready_males", 0)), int(aggregate.get("ready_females", 0)))
	if ready_pairs <= 0 or avg_energy < energy_threshold \
			or avg_hunger > float(reproduction_config.get("max_hunger", 100.0)) \
			or avg_thirst > float(reproduction_config.get("max_thirst", 100.0)):
		return 0
	var reserve_ratio: float = clampf((avg_energy - energy_threshold) / maxf(1.0, energy_threshold), 0.0, 0.35)
	var birth_rate: float = reserve_ratio * 0.15 * float(ready_pairs * 2)
	# Only ready opposite-sex pairs breed. This mirrors the live path's mate gate
	# and prevents an all-female or juvenile aggregate from creating offspring.
	var cooldown_ceiling: float = float(ready_pairs) / maxf(1.0, float(reproduction_config.get("cooldown", 46.0)))
	var debt: float = float(aggregate.get("birth_debt", 0.0)) + minf(birth_rate, cooldown_ceiling) * elapsed
	var births: int = mini(ready_pairs, int(floor(debt)))
	aggregate["birth_debt"] = debt - float(births)
	births = reserve_reproductive_capacity(str(aggregate.get("species_type", "")), births)
	if births > 0:
		# The live path charges `birth_energy_cost` to both parents. Skipping it here left
		# the coarse path breeding for free, with nothing to pay back between litters.
		var total_cost: float = float(births) * 2.0 * float(reproduction_config.get("birth_energy_cost", 0.0))
		aggregate["avg_energy"] = maxf(0.0, avg_energy - total_cost / float(count))
		aggregate["births_this_step"] = births
	return maxi(0, births)


## Moves a sleeping herd without inventing anyone's position.
##
## The herd's goal-seeking is swept once from its centre, so a whole herd costs one
## collision query and slides along what it grazes. Every member then takes that step
## from where it actually stands, plus a drift of its own: a wander heading carried in
## `wander_angle`, spacing from neighbours closer than two bodies, and a pull back
## towards its kin or the herd once it strays past a comfortable distance.
##
## A member whose step would land where it cannot stand stays put and turns its wander
## heading around. A herd walking into a cliff piles up against it, rather than every
## member being snapped onto the same nearest walkable cell.
##
## Nothing here reads `rng`. The wander turn is a hash of the animal's id and the tick.
func _advance_dormant_herd(sector_key: Vector2i, aggregate: Dictionary, members: Array, elapsed: float) -> void:
	var current_center: Vector2 = aggregate.get("center", _sector_key_to_rect(sector_key).get_center())
	var goal_position: Vector2 = aggregate.get("goal_position", current_center)
	var species_config: Dictionary = config_bundle.get("species", {}).get(str(aggregate.get("species_type", "")), {})
	var movement: Dictionary = species_config.get("movement", {})
	var body_radius := float(movement.get("body_radius", 0.0))
	var is_directed: bool = str(aggregate.get("goal_kind", "wander")) in ["water", "hunt", "seek_carcass"]
	var base_speed: float = _get_dormant_travel_speed(species_config, is_directed)
	var desired_velocity: Vector2 = Vector2.ZERO
	var to_goal: Vector2 = goal_position - current_center
	if to_goal.length_squared() > 4.0:
		desired_velocity = to_goal.normalized() * base_speed
	var acceleration: float = float(movement.get("acceleration", 140.0)) * _dormant_speed_scale
	var next_velocity: Vector2 = Vector2(aggregate.get("velocity", Vector2.ZERO)).move_toward(desired_velocity, acceleration * elapsed)
	next_velocity = next_velocity.move_toward(Vector2.ZERO, float(movement.get("drag", 3.0)) * elapsed)
	var herd_step: Vector2 = next_velocity * elapsed
	# The centre is a point no animal stands on. The sweep uses a point body, as the
	# coarse step always has, and when an obstacle cuts it short the herd does not stop
	# there: every member takes the full step and only its own landing point is
	# checked. Sweeping with a body radius and keeping the cut-short step stalled whole
	# herds behind a single tree or cliff cell between their members, until they died
	# of thirst with open ground on both sides.
	if is_walkable_position(current_center):
		var resolved := resolve_movement_position(current_center, current_center + herd_step)
		var swept := get_nearest_walkable_position(resolved) - current_center
		if swept.length_squared() >= herd_step.length_squared() * 0.25:
			herd_step = swept
	if herd_step.length_squared() + 0.01 < (next_velocity * elapsed).length_squared():
		next_velocity = herd_step / maxf(elapsed, 0.00001)
	aggregate["velocity"] = next_velocity
	var count := members.size()
	var next_center := current_center + herd_step
	if count > 0:
		next_center = _drift_dormant_members(aggregate, members, current_center, herd_step, goal_position,
			float(movement.get("max_speed", 70.0)) * _dormant_speed_scale, body_radius, elapsed)
	var moved_distance: float = next_center.distance_to(current_center)
	aggregate["center"] = next_center
	if moved_distance <= 2.0:
		aggregate["stale_time"] = float(aggregate.get("stale_time", 0.0)) + elapsed
	else:
		aggregate["stale_time"] = maxf(0.0, float(aggregate.get("stale_time", 0.0)) - elapsed * 0.5)


## Applies the herd's step and each member's own drift. Returns the new centroid.
func _drift_dormant_members(aggregate: Dictionary, members: Array, center: Vector2, herd_step: Vector2,
		goal_position: Vector2, drift_speed: float, body_radius: float, elapsed: float) -> Vector2:
	var count := members.size()
	var starts := PackedVector2Array()
	starts.resize(count)
	for i in range(count):
		starts[i] = members[i].get("position", center)
	var spacing := body_radius * 2.0
	var nudges := PackedVector2Array()
	nudges.resize(count)
	if count <= _DORMANT_SPACING_MEMBER_LIMIT and spacing > 0.0:
		for i in range(count):
			var position_i: Vector2 = starts[i]
			for j in range(i + 1, count):
				var gap: Vector2 = starts[j] - position_i
				var distance_sq := gap.length_squared()
				if distance_sq >= spacing * spacing:
					continue
				var distance := sqrt(distance_sq)
				var push_direction := gap / distance if distance > 0.001 \
					else Vector2.from_angle(_dormant_hash_unit(int(members[i].get("id", 0)), int(members[j].get("id", 0))) * TAU)
				var push := push_direction * (spacing - distance) * 0.5
				nudges[i] -= push
				nudges[j] += push
	var comfort_radius := maxf(float(aggregate.get("spread_radius", 0.0)) * 1.5,
		body_radius * _DORMANT_PACKING_RADIUS * sqrt(float(count)))
	# An animal with a partner or young in the group (`kin_ids`) holds to them, not to
	# the group's centre. Unbonded animals of a sector share one aggregate - every
	# predator pair sleeps in the same `predator:-1` group - so that centre means
	# nothing to a pair, and a pair left to wander apart passes
	# `preferred_mate_break_radius` and wakes without its bond.
	var index_by_id: Dictionary = {}
	for member in members:
		if not member.get("kin_ids", []).is_empty():
			for i in range(count):
				index_by_id[int(members[i].get("id", -1))] = i
			break
	var reproduction: Dictionary = config_bundle.get("species", {}).get(str(aggregate.get("species_type", "")), {}).get("reproduction", {})
	var kin_comfort_radius := float(reproduction.get("preferred_mate_follow_radius", 180.0)) * 0.5
	var turn_limit := _DORMANT_WANDER_TURN_PER_SECOND * elapsed
	var position_sum := Vector2.ZERO
	for index in range(count):
		var record: Dictionary = members[index]
		var position: Vector2 = starts[index]
		var heading := wrapf(float(record.get("wander_angle", 0.0))
			+ (_dormant_hash_unit(int(record.get("id", 0)), current_tick) * 2.0 - 1.0) * turn_limit, -PI, PI)
		var drift := Vector2.from_angle(heading) * drift_speed * _DORMANT_WANDER_SHARE * elapsed
		var anchor := center
		var comfort := comfort_radius
		if not index_by_id.is_empty():
			var kin_sum := Vector2.ZERO
			var kin_count := 0
			for kin_id in record.get("kin_ids", []):
				var kin_index: int = index_by_id.get(int(kin_id), -1)
				if kin_index >= 0 and kin_index != index:
					kin_sum += starts[kin_index]
					kin_count += 1
			if kin_count > 0:
				anchor = kin_sum / float(kin_count)
				comfort = kin_comfort_radius
		var offset := position - anchor
		var offset_length := offset.length()
		if offset_length > comfort:
			drift -= offset / offset_length * minf(offset_length - comfort, drift_speed * _DORMANT_COHESION_SHARE * elapsed)
		var move := herd_step + drift + nudges[index]
		var next_position := _dormant_step_target(position, move)
		if next_position != position + move:
			heading = wrapf(heading + PI, -PI, PI)
		record["wander_angle"] = heading
		var moved := next_position - position
		record["position"] = next_position
		record["velocity"] = moved / maxf(elapsed, 0.00001)
		if moved.length_squared() > 0.001:
			record["direction"] = moved.normalized()
		record["target_position"] = goal_position
		position_sum += next_position
	return position_sum / float(count)


## Where a sleeping animal ends up after trying to move by `move`. It slides along the
## map edge and along whichever axis is still open, and stays put only when neither is.
## The spacing push rides along in every case, so animals pressed against a wall line
## up along it instead of stacking onto one spot.
func _dormant_step_target(from: Vector2, move: Vector2) -> Vector2:
	for candidate in [from + move, from + Vector2(move.x, 0.0), from + Vector2(0.0, move.y)]:
		var clamped := clamp_position(candidate)
		if is_walkable_position(clamped):
			return clamped
	return from if _is_dormant_foothold(from) else get_nearest_walkable_position(from)


func _is_dormant_foothold(position: Vector2) -> bool:
	return clamp_position(position) == position and is_walkable_position(position)


## A uniform value in [0, 1) from two integers, for dormant choices that must not
## touch `rng`. Every product is cut back to 32 bits through `_mul32()`, so no
## intermediate overflows a 64-bit int and the result is the same on any platform.
static func _dormant_hash_unit(a: int, b: int) -> float:
	var mixed: int = (a & 0xFFFFFFFF) ^ _mul32(b & 0xFFFFFFFF, 0x9E3779B9)
	mixed ^= mixed >> 16
	mixed = _mul32(mixed, 0x7FEB352D)
	mixed ^= mixed >> 15
	mixed = _mul32(mixed, 0x846CA68B)
	mixed ^= mixed >> 16
	return float(mixed & 0xFFFFFF) / 16777216.0


## `(value * factor) mod 2^32` for 32-bit inputs, split so no partial product
## exceeds 49 bits.
static func _mul32(value: int, factor: int) -> int:
	return (value * (factor & 0xFFFF) + (((value * (factor >> 16)) & 0xFFFF) << 16)) & 0xFFFFFFFF


func _group_dormant_records(records: Array) -> Dictionary:
	var buckets: Dictionary = {}
	for record in records:
		var aggregate_key := _get_dormant_record_aggregate_key(record)
		if not buckets.has(aggregate_key):
			buckets[aggregate_key] = []
		buckets[aggregate_key].append(record)
	return buckets


## Applies what a coarse step decided for each group to the animals in it.
##
## The step works in group totals: how many died of what, how many were born, how far
## average hunger moved. This turns those into changes to real records. Deaths take
## particular animals - nearest the hunters for predation, the hungriest or thirstiest,
## the oldest - and are reported where that animal stands. Every survivor's hunger,
## thirst and energy move by the group's change instead of being set to its mean, so a
## herd's spread of needs survives dormancy. Newborns are built the way a woken animal
## is and put down beside their mother. The group's averages, tallies, centre and
## member list are then read back off the records.
func _reconcile_dormant_records(sector_key: Vector2i, sector_state: Dictionary, elapsed: float = 0.0, buckets: Dictionary = {}) -> void:
	var records: Array = sector_state.get("dormant_records", [])
	if buckets.is_empty():
		buckets = _group_dormant_records(records)
	var need_max := float(config_bundle.get("balance", {}).get("need_max", 100.0))
	var next_records: Array = []
	var next_aggregates: Array = []
	var claimed: Dictionary = {}
	for aggregate in sector_state.get("dormant_aggregates", []):
		var species_key := str(aggregate.get("species_type", ""))
		var group_id := int(aggregate.get("group_id", -1))
		var aggregate_key := _get_dormant_aggregate_key(species_key, group_id)
		claimed[aggregate_key] = true
		var bucket: Array = buckets.get(aggregate_key, [])
		var species_config: Dictionary = config_bundle.get("species", {}).get(species_key, {})
		var reproduction_config: Dictionary = species_config.get("reproduction", {})
		var max_energy := float(species_config.get("metabolism", {}).get("max_energy", 100.0))
		var shift := _dormant_need_shift(aggregate, bucket)
		var survivors := _take_dormant_victims(aggregate, bucket)
		var births := int(aggregate.get("births_this_step", 0))
		aggregate.erase("births_this_step")
		var parent_cooldown := float(reproduction_config.get("cooldown", 46.0))
		var maturity_age := float(reproduction_config.get("maturity_age", 0.0))
		var male_parents_left := births
		var mothers: Array = []
		_share_dormant_need_shift(survivors, "hunger", shift.x, 0.0, need_max)
		_share_dormant_need_shift(survivors, "thirst", shift.y, 0.0, need_max)
		_share_dormant_need_shift(survivors, "energy", shift.z, 0.0, max_energy)
		for record in survivors:
			record["age"] = float(record.get("age", 0.0)) + elapsed
			record["reproduction_cooldown"] = maxf(0.0, float(record.get("reproduction_cooldown", 0.0)) - elapsed)
			var parent_ready := float(record.get("age", 0.0)) >= maturity_age \
				and float(record.get("reproduction_cooldown", 0.0)) <= 0.0
			var sex := str(record.get("sex", AgentBaseScript.SEX_FEMALE))
			if parent_ready and sex == AgentBaseScript.SEX_MALE and male_parents_left > 0:
				record["reproduction_cooldown"] = parent_cooldown
				male_parents_left -= 1
			elif parent_ready and sex == AgentBaseScript.SEX_FEMALE and mothers.size() < births:
				record["reproduction_cooldown"] = parent_cooldown
				mothers.append(record)
		var members: Array = survivors.duplicate()
		var body_radius := float(species_config.get("movement", {}).get("body_radius", 0.0))
		for birth_index in range(births):
			var mother: Dictionary = {}
			if birth_index < mothers.size():
				mother = mothers[birth_index]
			elif not survivors.is_empty():
				mother = survivors[birth_index % survivors.size()]
			var anchor: Vector2 = mother.get("position", aggregate.get("center", _sector_key_to_rect(sector_key).get_center()))
			var newborn := _make_dormant_newborn(species_key, group_id, anchor, body_radius)
			if newborn.is_empty():
				continue
			members.append(newborn)
			emit_population_event("AgentBorn", species_key, Vector2(newborn["position"]), {
				"reason": "dormant",
				"group_id": group_id,
			})
		_read_dormant_group_back(aggregate, members)
		if members.is_empty():
			continue
		next_records.append_array(members)
		next_aggregates.append(aggregate)
	# Records of a group the step no longer lists would otherwise vanish uncounted.
	var orphaned := false
	for aggregate_key in buckets.keys():
		if not claimed.has(aggregate_key):
			next_records.append_array(buckets[aggregate_key])
			orphaned = true
	sector_state["dormant_records"] = next_records
	if orphaned:
		next_aggregates = _build_dormant_aggregates(next_records, sector_key,
			_build_dormant_aggregate_previous_map(next_aggregates))
	sector_state["dormant_aggregates"] = next_aggregates


## How far the step moved a group's average hunger, thirst and energy, as x, y and z.
## The averages were read off these same records when the step began, so the
## difference is exactly what this step's metabolism, feeding and births did.
func _dormant_need_shift(aggregate: Dictionary, bucket: Array) -> Vector3:
	if bucket.is_empty():
		return Vector3.ZERO
	var sums := Vector3.ZERO
	for record in bucket:
		sums += Vector3(float(record.get("hunger", 0.0)), float(record.get("thirst", 0.0)), float(record.get("energy", 0.0)))
	var means := sums / float(bucket.size())
	return Vector3(
		float(aggregate.get("avg_hunger", means.x)) - means.x,
		float(aggregate.get("avg_thirst", means.y)) - means.y,
		float(aggregate.get("avg_energy", means.z)) - means.z)


## Moves every record's `field` by `shift` on average, within [low, high]. A record
## already at a bound cannot take its share, so the rest take it instead: an animal
## that is already sated eats nothing and leaves the grass to the hungry ones. The
## group's mean then moves by exactly what the step's ledger says it did.
static func _share_dormant_need_shift(records: Array, field: String, shift: float, low: float, high: float) -> void:
	var remaining := shift * float(records.size())
	var open: Array = records
	while not open.is_empty() and absf(remaining) > 0.0001:
		var share := remaining / float(open.size())
		var still_open: Array = []
		for record in open:
			var before := float(record.get(field, 0.0))
			var after := clampf(before + share, low, high)
			record[field] = after
			remaining -= after - before
			if (share > 0.0 and after < high) or (share < 0.0 and after > low):
				still_open.append(record)
		if still_open.size() == open.size():
			break
		open = still_open


## Removes the animals this step's queued deaths name and reports each where it stood.
## Returns the survivors, in their original order.
func _take_dormant_victims(aggregate: Dictionary, bucket: Array) -> Array:
	var survivors: Array = bucket.duplicate()
	var species_key := str(aggregate.get("species_type", ""))
	for entry in aggregate.get("deaths_this_step", []):
		var cause := str(entry.get("cause", ""))
		for _index in range(int(entry.get("count", 0))):
			var victim_index := _pick_dormant_victim(survivors, cause, entry)
			# A group whose count ran ahead of its records has no one left to lose.
			if victim_index < 0:
				break
			var position: Vector2 = survivors[victim_index].get("position", aggregate.get("center", bounds.get_center()))
			survivors.remove_at(victim_index)
			_emit_dormant_death(species_key, position, cause)
			if cause == "predation":
				emit_population_event("PredationSuccess", str(entry.get("hunter", "")), position, {"dormant": true})
	aggregate.erase("deaths_this_step")
	return survivors


## The record a death of `cause` takes: nearest the hunters for predation, the
## hungriest for starvation, the thirstiest for thirst, the oldest for old age. Ties
## go to the lower id, so the choice never depends on array order or float noise.
func _pick_dormant_victim(candidates: Array, cause: String, entry: Dictionary) -> int:
	var best_index := -1
	var best_score := -INF
	var best_id := 0
	var near: Vector2 = entry.get("near", Vector2.ZERO)
	for index in range(candidates.size()):
		var record: Dictionary = candidates[index]
		var score: float
		match cause:
			"predation":
				score = -Vector2(record.get("position", near)).distance_squared_to(near)
			"starvation":
				score = float(record.get("hunger", 0.0))
			"thirst":
				score = float(record.get("thirst", 0.0))
			_:
				score = float(record.get("age", 0.0))
		var record_id := int(record.get("id", 0))
		if best_index < 0 or score > best_score or (score == best_score and record_id < best_id):
			best_index = index
			best_score = score
			best_id = record_id
	return best_index


## Recomputes everything an aggregate says about its members from the members.
func _read_dormant_group_back(aggregate: Dictionary, members: Array) -> void:
	var count := members.size()
	var record_ids: Array = []
	var record_positions := PackedVector2Array()
	var position_sum := Vector2.ZERO
	var needs_sum := Vector3.ZERO
	var age_sum := 0.0
	for key in ["mature_males", "mature_females", "ready_males", "ready_females", "old_age_count", "max_age_count"]:
		aggregate[key] = 0
	for record in members:
		var position: Vector2 = record.get("position", bounds.get_center())
		record_ids.append(int(record.get("id", -1)))
		record_positions.append(position)
		position_sum += position
		needs_sum += Vector3(float(record.get("hunger", 0.0)), float(record.get("thirst", 0.0)), float(record.get("energy", 0.0)))
		age_sum += float(record.get("age", 0.0))
		_tally_dormant_member(aggregate, record)
	aggregate["count"] = count
	aggregate["record_ids"] = record_ids
	aggregate["record_positions"] = record_positions
	if count <= 0:
		return
	aggregate["center"] = position_sum / float(count)
	aggregate["avg_hunger"] = needs_sum.x / float(count)
	aggregate["avg_thirst"] = needs_sum.y / float(count)
	aggregate["avg_energy"] = needs_sum.z / float(count)
	aggregate["avg_age"] = age_sum / float(count)


## A dormant birth, built the way a woken animal is so it carries every field a live
## newborn has and inherits nothing from its herd's travel or hunting state. The
## throwaway generator, seeded with the newborn's id, takes the wander roll
## `configure()` makes, so the shared `rng` is never drawn.
func _make_dormant_newborn(species_type: String, group_id: int, mother_position: Vector2, body_radius: float) -> Dictionary:
	var agent = _create_agent(species_type)
	if agent == null:
		return {}
	var newborn_id := next_agent_id
	next_agent_id += 1
	var birth_rng := RandomNumberGenerator.new()
	birth_rng.seed = newborn_id
	var position := mother_position + Vector2.from_angle(_dormant_hash_unit(newborn_id, 0x5EED) * TAU) * body_radius * 2.0
	if not _is_dormant_foothold(position):
		position = mother_position
	agent.configure(
		newborn_id,
		species_type,
		position,
		_deterministic_sex(newborn_id),
		config_bundle.get("species", {}).get(species_type, {}),
		config_bundle.get("balance", {}),
		birth_rng,
		group_id
	)
	agent.lod_tier = LOD_TIER_2
	return agent.export_runtime_state()


func _migrate_dormant_sector_records(sector_key: Vector2i, lod_context: Dictionary) -> Array:
	var sectors_to_wake: Array = []
	var sector_state: Dictionary = _sector_states.get(sector_key, {})
	if sector_state.is_empty() or not bool(sector_state.get("dormant", false)):
		return sectors_to_wake
	var retained_records: Array = []
	var moved_by_sector: Dictionary = {}
	for record in sector_state.get("dormant_records", []):
		var destination_sector := _get_sector_key(Vector2(record.get("position", _sector_key_to_rect(sector_key).get_center())))
		if destination_sector == sector_key:
			retained_records.append(record)
			continue
		var destination_state: Dictionary = _get_or_create_sector_state(destination_sector)
		if _resolve_sector_lod_tier(destination_sector, lod_context) != LOD_TIER_2 or not destination_state.get("agent_ids", []).is_empty():
			retained_records.append(record)
			sectors_to_wake.append(sector_key)
			sectors_to_wake.append(destination_sector)
			continue
		if not moved_by_sector.has(destination_sector):
			moved_by_sector[destination_sector] = []
		moved_by_sector[destination_sector].append(record)
		performance_counters["dormant_migrations"] += 1
	sector_state["dormant_records"] = retained_records
	_sector_states[sector_key] = sector_state
	_refresh_dormant_sector_state(sector_key, true)
	for destination_sector in moved_by_sector.keys():
		var destination_state: Dictionary = _get_or_create_sector_state(destination_sector)
		var destination_records: Array = destination_state.get("dormant_records", [])
		destination_records.append_array(moved_by_sector[destination_sector])
		destination_state["dormant"] = true
		destination_state["dormant_records"] = destination_records
		destination_state["dormant_elapsed"] = float(destination_state.get("dormant_elapsed", 0.0))
		_sector_states[destination_sector] = destination_state
		_refresh_dormant_sector_state(destination_sector, true)
	return sectors_to_wake


func _sector_adjacent_to_active_ring(sector_key: Vector2i, lod_context: Dictionary) -> bool:
	for x in range(sector_key.x - 1, sector_key.x + 2):
		for y in range(sector_key.y - 1, sector_key.y + 2):
			var neighbor_key := Vector2i(x, y)
			if neighbor_key == sector_key:
				continue
			if _resolve_sector_lod_tier(neighbor_key, lod_context) != LOD_TIER_2:
				return true
	return false


func _dormant_sector_should_force_wake(sector_key: Vector2i, sector_state: Dictionary, lod_context: Dictionary) -> bool:
	if _dormant_sector_should_wake_for_neighboring_threat(sector_key, lod_context):
		return true
	var threat_count := _sector_species_count(sector_state, _threat_species_ids)
	var prey_count := _sector_species_count(sector_state, _prey_species_ids)
	if threat_count > 0 and prey_count > 0 and _sector_adjacent_to_active_ring(sector_key, lod_context):
		return true
	# Co-located predators and prey are resolved by the dormant predation ledger.
	# Water is sector state as well, so it does not require materializing a far
	# sector. The active-ring check above still wakes a chase approaching LOD0/1.
	return false


func _dormant_aggregate_reached_goal(sector_key: Vector2i, aggregate: Dictionary) -> bool:
	var goal_sector: Vector2i = aggregate.get("goal_sector", sector_key)
	if goal_sector != sector_key:
		return false
	var center: Vector2 = aggregate.get("center", _sector_key_to_rect(sector_key).get_center())
	var goal_position: Vector2 = aggregate.get("goal_position", center)
	var proximity := maxf(_sector_size * 0.35, 24.0 if resource_system == null else resource_system.cell_size * 1.25)
	return center.distance_to(goal_position) <= proximity


func _get_sector_prey_pressure(sector_key: Vector2i) -> int:
	var sector_state: Dictionary = _sector_states.get(sector_key, {})
	if sector_state.is_empty():
		return 0
	return _sector_species_count(sector_state, _prey_species_ids)


## Meat to hunger and energy, per head, using exactly the knobs the live
## `Predator._scavenge_or_feed()` path uses so the two paths cannot drift apart.
func _apply_dormant_meat_to_predator(aggregate: Dictionary, feeding: Dictionary, meat_per_head: float, max_energy: float) -> void:
	if meat_per_head <= 0.0:
		return
	var hunger_reduction: float = meat_per_head * float(feeding.get("carcass_nutrition_gain", 1.0))
	aggregate["avg_hunger"] = maxf(0.0, float(aggregate.get("avg_hunger", 0.0)) - hunger_reduction)
	aggregate["avg_energy"] = minf(max_energy, float(aggregate.get("avg_energy", 0.0)) + meat_per_head * float(feeding.get("carcass_energy_gain", 0.5)))
	performance_counters["dormant_predator_hunger_reduced"] += hunger_reduction * float(maxi(1, int(aggregate.get("count", 0))))


func _apply_dormant_resource_interactions(sector_key: Vector2i, sector_state: Dictionary, elapsed: float) -> void:
	var aggregates: Array = sector_state.get("dormant_aggregates", [])
	if aggregates.is_empty():
		return
	for aggregate in aggregates:
		if int(aggregate.get("count", 0)) <= 0:
			continue
		var species_key := str(aggregate.get("species_type", ""))
		var species_config: Dictionary = config_bundle.get("species", {}).get(species_key, {})
		var feeding: Dictionary = species_config.get("feeding", {})
		var diet: String = species_registry.diet(species_key)
		if diet == SpeciesRegistryScript.DIET_GRASS:
			if str(aggregate.get("goal_kind", "")) == "water" and _dormant_aggregate_reached_goal(sector_key, aggregate):
				var drink_duration := maxf(0.1, float(feeding.get("drink_duration", 0.6)))
				var thirst_restore := float(feeding.get("drink_restore", 35.0)) * minf(1.0, elapsed / drink_duration)
				aggregate["avg_thirst"] = maxf(0.0, float(aggregate.get("avg_thirst", 0.0)) - thirst_restore)
			# A sleeping herd represents animals spread through this whole sector,
			# rather than one body pinned to the aggregate centre. Let it graze local
			# biomass whenever hungry, including during a water trip. Requiring the
			# averaged centre to touch one exact grass cell caused dormant herbivores
			# to starve while the same sector still held millions of biomass and the
			# fully simulated population had zero starvation deaths.
			var graze_floor := float(config_bundle.get("balance", {}).get(
				"state_thresholds", {}).get("graze_hunger_floor", 12.0))
			if float(aggregate.get("avg_hunger", 0.0)) >= graze_floor:
				var grass_target := _get_sector_best_grass(sector_key, 1.0)
				if grass_target.is_empty():
					aggregate["last_goal_refresh_time"] = -INF
				else:
					var bite_amount := float(feeding.get("bite_amount", 18.0))
					var eat_duration := maxf(0.1, float(feeding.get("eat_duration", 0.55)))
					var desired_consumption := float(aggregate.get("count", 0)) * bite_amount * maxf(1.0, elapsed / eat_duration)
					var consumed := consume_grass_cell(int(grass_target.get("index", -1)), desired_consumption)
					if consumed <= 0.0:
						aggregate["last_goal_refresh_time"] = -INF
					else:
						var consumed_per_agent := consumed / maxf(1.0, float(aggregate.get("count", 0)))
						var hunger_reduction := consumed_per_agent * float(feeding.get("nutrition_gain", 0.8))
						if hunger_reduction > 0.0:
							aggregate["avg_hunger"] = maxf(0.0, float(aggregate.get("avg_hunger", 0.0)) - hunger_reduction)
							record_herbivore_hunger_reduction(hunger_reduction, int(aggregate.get("count", 0)))
						var max_energy := float(species_config.get("metabolism", {}).get("max_energy", 100.0))
						aggregate["avg_energy"] = minf(max_energy, float(aggregate.get("avg_energy", 0.0)) + consumed_per_agent * 0.18)
			continue
		# Meat eaters, hunters and carrion feeders alike: the `water` and `seek_carcass`
		# arms below serve both, and only a hunter is ever handed a `hunt` goal.
		if diet != SpeciesRegistryScript.DIET_PREY and diet != SpeciesRegistryScript.DIET_CARRION:
			continue
		# The predator side of the coarse ecology. Without these branches a dormant
		# predator could reach prey, water or a carcass and still take nothing from any
		# of them: hunger and thirst only ever rose, so every predator that went
		# dormant starved on a fixed ~61 s timer no matter how much prey surrounded it.
		var predator_max_energy := float(species_config.get("metabolism", {}).get("max_energy", 100.0))
		var head_count: int = maxi(1, int(aggregate.get("count", 0)))
		match str(aggregate.get("goal_kind", "")):
			"water":
				if _dormant_aggregate_reached_goal(sector_key, aggregate):
					aggregate["avg_thirst"] = maxf(0.0, float(aggregate.get("avg_thirst", 0.0)) - float(feeding.get("drink_restore", 35.0)))
			"seek_carcass":
				if not _dormant_aggregate_reached_goal(sector_key, aggregate):
					continue
				# Routed through `consume_carcass()` so a dormant aggregate and a live
				# predator can never eat the same meat twice.
				var carcass_id: int = int(aggregate.get("carcass_id", -1))
				var carcass_meat: float = 0.0
				if carcass_id != -1:
					carcass_meat = consume_carcass(carcass_id, float(feeding.get("carcass_consume_rate", 24.0)) * float(head_count) * elapsed, -1)
				if carcass_meat <= 0.0:
					aggregate["last_goal_refresh_time"] = -INF
					continue
				_apply_dormant_meat_to_predator(aggregate, feeding, carcass_meat / float(head_count), predator_max_energy)
			"hunt":
				var prey_pressure := _get_sector_prey_pressure(Vector2i(aggregate.get("goal_sector", sector_key)))
				if prey_pressure <= 0:
					aggregate["last_goal_refresh_time"] = -INF
				# Draw from the meat this sector's kills produced in
				# `_resolve_dormant_predation()`; the pool is the only source, so intake
				# can never exceed what actually died here.
				var pool: float = float(sector_state.get("dormant_meat_pool", 0.0))
				if pool <= 0.0:
					continue
				var wanted: float = float(feeding.get("carcass_consume_rate", 24.0)) * float(head_count) * elapsed
				var taken: float = minf(wanted, pool)
				sector_state["dormant_meat_pool"] = pool - taken
				_apply_dormant_meat_to_predator(aggregate, feeding, taken / float(head_count), predator_max_energy)


## One coarse step for a sleeping sector.
##
## An aggregate effect reaches a record as a change, never as an assignment. The step
## decides group-level quantities - kills, deaths by cause, births, the herd's move, how
## far average needs shift - and `_reconcile_dormant_records()` applies them to the
## animals. No record's position, needs or age is ever replaced by its group's value.
func _apply_dormant_sector_step(sector_key: Vector2i, sector_state: Dictionary, elapsed: float) -> void:
	var records: Array = sector_state.get("dormant_records", [])
	if records.is_empty():
		return
	var aggregates: Array = sector_state.get("dormant_aggregates", [])
	if aggregates.is_empty():
		aggregates = _build_dormant_aggregates(records, sector_key)
		sector_state["dormant_aggregates"] = aggregates
	var buckets := _group_dormant_records(records)
	# Kills resolve before metabolism, so a predator that just ate is not then starved
	# in the same step by the hunger it had a moment earlier.
	_resolve_dormant_predation(sector_key, sector_state, aggregates, elapsed)
	for aggregate in aggregates:
		_apply_dormant_metabolism_to_aggregate(sector_key, aggregate, elapsed)
		# An emptied group stays listed until the reconcile, which reports its deaths.
		if int(aggregate.get("count", 0)) <= 0:
			continue
		var shared_goal := _dormant_shared_goal(sector_key, aggregate)
		if not shared_goal.is_empty():
			aggregate.erase("carcass_id")
			for goal_key in shared_goal.keys():
				aggregate[goal_key] = shared_goal[goal_key]
		var should_refresh_goal := Vector2(aggregate.get("goal_position", Vector2.ZERO)).distance_to(Vector2(aggregate.get("center", Vector2.ZERO))) <= _sector_size * 0.18
		should_refresh_goal = should_refresh_goal or current_time - float(aggregate.get("last_goal_refresh_time", -INF)) >= _dormant_goal_refresh_seconds
		if should_refresh_goal and shared_goal.is_empty():
			var previous_goal_kind := str(aggregate.get("goal_kind", "wander"))
			var previous_goal_sector: Vector2i = aggregate.get("goal_sector", sector_key)
			var next_goal := _select_dormant_goal(sector_key, aggregate)
			if not next_goal.is_empty():
				aggregate["goal_kind"] = str(next_goal.get("goal_kind", previous_goal_kind))
				aggregate["goal_position"] = next_goal.get("goal_position", aggregate.get("goal_position", aggregate.get("center", bounds.get_center())))
				aggregate["goal_sector"] = next_goal.get("goal_sector", previous_goal_sector)
				# A `seek_carcass` goal names the carcass it refers to, so dormant feeding can
				# debit that specific carcass through `consume_carcass()` rather than inventing
				# meat. Any other goal kind must clear it.
				if next_goal.has("carcass_id"):
					aggregate["carcass_id"] = int(next_goal["carcass_id"])
				else:
					aggregate.erase("carcass_id")
				aggregate["last_goal_refresh_time"] = current_time
				performance_counters["dormant_goal_refreshes"] += 1
				if str(aggregate.get("goal_kind", "wander")) != previous_goal_kind or aggregate.get("goal_sector", sector_key) != previous_goal_sector:
					aggregate["stale_time"] = 0.0
		var aggregate_key := _get_dormant_aggregate_key(str(aggregate.get("species_type", "")), int(aggregate.get("group_id", -1)))
		_advance_dormant_herd(sector_key, aggregate, buckets.get(aggregate_key, []), elapsed)
		var dormant_births := _compute_dormant_births_for_aggregate(aggregate, elapsed)
		if dormant_births > 0:
			aggregate["count"] = int(aggregate.get("count", 0)) + dormant_births
	_apply_dormant_resource_interactions(sector_key, sector_state, elapsed)
	_reconcile_dormant_records(sector_key, sector_state, elapsed, buckets)
	sector_state["dormant_species"] = _build_dormant_species_state(sector_state.get("dormant_records", []))
	sector_state["dormant_count"] = sector_state.get("dormant_records", []).size()
	_project_dormant_counts_onto_sector(sector_state)


func _restore_dormant_agent(record: Dictionary):
	var species_type := str(record.get("species_type", ""))
	var agent = _create_agent(species_type)
	if agent == null:
		return null
	var species_config: Dictionary = config_bundle.get("species", {}).get(species_type, {})
	var record_id := int(record.get("id", next_agent_id))
	var sex := str(record.get("sex", ""))
	if sex == "":
		sex = _deterministic_sex(record_id)
	# Waking follows the camera, so nothing here may draw from `rng`. The default
	# argument used to call `_random_sex()` on every wake whether or not the record
	# had a sex, and `configure()` rolls a wander angle. The throwaway generator
	# takes that roll, and `apply_runtime_state()` restores the real angle below.
	var restore_rng := RandomNumberGenerator.new()
	restore_rng.seed = record_id
	agent.configure(
		record_id,
		species_type,
		Vector2(record.get("position", bounds.get_center())),
		sex,
		species_config,
		config_bundle.get("balance", {}),
		restore_rng,
		int(record.get("group_id", -1))
	)
	agent.apply_runtime_state(record)
	agent.position = scenery.nearest_free(agent.position, agent.get_body_radius())
	agent.clear_navigation()
	agents[record_id] = agent
	next_agent_id = maxi(next_agent_id, record_id + 1)
	return agent


func _dormant_sector_has_agent(sector_state: Dictionary, agent_id: int) -> bool:
	for record in sector_state.get("dormant_records", []):
		if int(record.get("id", -1)) == agent_id:
			return true
	return false


func _dormant_sector_should_wake_for_neighboring_threat(sector_key: Vector2i, lod_context: Dictionary) -> bool:
	var sector_state: Dictionary = _sector_states.get(sector_key, {})
	if _sector_species_count(sector_state, _threat_species_ids) > 0 and _sector_species_count(sector_state, _prey_species_ids) > 0 and _sector_adjacent_to_active_ring(sector_key, lod_context):
		return true
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
			if float(neighbor_state.get("threat_score", 0.0)) > 0.0 or float(sector_state.get("threat_score", 0.0)) > 0.0:
				return true
	return false


func _create_agent(species_type: String):
	return species_registry.make_agent(species_type)


func _random_sex() -> String:
	return AgentBaseScript.SEX_MALE if rng.randf() > 0.5 else AgentBaseScript.SEX_FEMALE


## Sex for an animal the dormant path creates, from its id alone. The coarse
## ecology runs wherever the camera is not, so a roll from `rng` here would make
## every later draw in the world depend on where the player had been looking.
static func _deterministic_sex(agent_id: int) -> String:
	var mixed: int = agent_id * 0x9E3779B1
	mixed = (mixed ^ (mixed >> 15)) * 0x85EBCA77
	mixed = mixed ^ (mixed >> 13)
	return AgentBaseScript.SEX_MALE if (mixed & 1) == 1 else AgentBaseScript.SEX_FEMALE


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
		# Kin links are what the pair-cohesion flow and the chase leash read, so they
		# belong to any species that lives in pairs rather than to predators by name.
		if species_registry.social(child.species_type) == SpeciesRegistryScript.SOCIAL_PAIR:
			for parent_key in ["parent_a_id", "parent_b_id"]:
				var parent_id := int(request[parent_key])
				var parent = get_agent(parent_id)
				if parent == null or not parent.is_alive or parent.species_type != child.species_type:
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


func _cell_distance(from_index: int, to_index: int) -> float:
	if terrain_system == null:
		return 0.0
	var from_coords: Vector2i = terrain_system.get_cell_coords(from_index)
	var to_coords: Vector2i = terrain_system.get_cell_coords(to_index)
	return Vector2(float(from_coords.x), float(from_coords.y)).distance_to(
		Vector2(float(to_coords.x), float(to_coords.y))
	)
