class_name Herbivore
extends AgentBase

const AgentAIState := preload("res://scripts/agents/ai/agent_ai_state.gd")
const AgentAction := preload("res://scripts/agents/ai/agent_action.gd")
const HerbivoreAIScript := preload("res://scripts/agents/ai/herbivore_ai.gd")

var _ai_controller


func configure(
	agent_id: int,
	new_species_type: String,
	spawn_position: Vector2,
	new_sex: String,
	species_config: Dictionary,
	balance_config: Dictionary,
	rng: RandomNumberGenerator,
	new_group_id: int = -1
) -> void:
	super.configure(agent_id, new_species_type, spawn_position, new_sex, species_config, balance_config, rng, new_group_id)
	_ai_controller = HerbivoreAIScript.new(balance_config)
	debug_color = Color(0.71, 0.88, 0.54)


func tick(world, delta: float) -> void:
	update_needs(delta)
	if apply_survival_checks(world, delta):
		set_ai_state(AgentAIState.DEAD)
		return

	if interaction_timer > 0.0:
		stop_motion(delta)
		return

	var neighbors: Array = _get_group_neighbors(world)
	var context = _ai_controller.build_context(self, world)
	var next_ai_state: StringName = _ai_controller.resolve_state(self, context)
	var scoped_context = context.with_state(next_ai_state)
	_ai_controller.update_action_target_tracking(self, scoped_context)
	set_ai_state(next_ai_state)
	var predators: Array = Perception.get_nearby_agents(
		world,
		position,
		float(perception.get("danger_radius", 120.0)),
		SPECIES_PREDATOR,
		id
	)

	if can_reproduce() and next_ai_state == AgentAIState.ALIVE and _attempt_reproduce(world, delta, neighbors):
		force_current_action(AgentAction.REPRODUCE, "reproduction override", world.current_tick)
		return

	var decision = _ai_controller.select_action(self, scoped_context, world.current_tick)
	apply_action_decision(decision, world.current_tick)
	_execute_selected_action(world, delta, neighbors, predators, decision.selected_action)


func _seek_or_drink(world, delta: float, neighbors: Array) -> bool:
	var water: Dictionary = _resolve_water_target(world)
	if water.is_empty():
		return false

	target_position = water["position"]
	var drink_distance: float = float(feeding.get("drink_distance", 28.0)) + float(water.get("radius", 0.0))
	if position.distance_squared_to(water["position"]) <= drink_distance * drink_distance:
		set_state("drink", world.current_tick)
		clear_navigation()
		interaction_timer = float(feeding.get("drink_duration", 0.6))
		reduce_thirst(float(feeding.get("drink_restore", 35.0)))
		world.emit_event("WaterConsumed", self, -1, {
			"source_position": water["position"],
			"restored": float(feeding.get("drink_restore", 35.0)),
		})
		return true

	set_state("seek_water", world.current_tick)
	var herd_vector: Vector2 = _herd_vector(world, neighbors, false)
	var waypoint: Vector2 = world.get_next_waypoint(position, water["position"], id)
	var move_vector: Vector2 = Steering.combine([
		{"vector": Steering.seek(position, waypoint), "weight": 1.4},
		{"vector": herd_vector, "weight": 0.5},
	])
	move_with_vector(world, move_vector, float(movement.get("max_speed", 70.0)), delta)
	return true


func _resolve_water_target(world) -> Dictionary:
	var water: Dictionary = Perception.find_nearest_water(world, position, float(perception.get("water_search_radius", 260.0)))
	if water.is_empty():
		water = get_remembered_water(
			world.current_time,
			float(perception.get("water_memory_duration_seconds", 0.0))
		)
	if not water.is_empty():
		remember_water(water, world.current_time)
	return water


func _seek_or_eat(world, delta: float, neighbors: Array) -> bool:
	var grass: Dictionary = _find_grass_target(world)
	if grass.is_empty():
		return false
	return _move_to_grass_target(world, delta, neighbors, grass)


func _find_grass_target(world) -> Dictionary:
	var thresholds: Dictionary = balance.get("state_thresholds", {})
	var graze_hunger_floor := float(thresholds.get("graze_hunger_floor", 20.0))
	var critical_hunger := float(thresholds.get("critical_hunger", 65.0))
	var base_search_radius := float(perception.get("grass_search_radius", 180.0))
	var urgency_ratio := 0.0
	var urgency_start := minf(graze_hunger_floor, critical_hunger)
	if hunger > urgency_start:
		urgency_ratio = clampf((hunger - urgency_start) / maxf(1.0, need_max - urgency_start), 0.0, 1.0)
	var min_biomass := 4.0 if urgency_ratio < 0.45 else 2.0

	var local_grass: Dictionary = Perception.find_best_grass(world, position, base_search_radius, min_biomass)
	if not local_grass.is_empty():
		return local_grass

	var expanded_search_radius := _get_expanded_grass_search_radius(urgency_start)
	if expanded_search_radius <= base_search_radius:
		return {}
	return Perception.find_best_grass(world, position, expanded_search_radius, min_biomass)


func _get_expanded_grass_search_radius(urgency_start: float) -> float:
	var base_search_radius := float(perception.get("grass_search_radius", 180.0))
	var urgency_ratio := 0.0
	if hunger > urgency_start:
		urgency_ratio = clampf((hunger - urgency_start) / maxf(1.0, need_max - urgency_start), 0.0, 1.0)
	return lerpf(base_search_radius, maxf(base_search_radius * 4.0, 720.0), urgency_ratio)


func _move_to_grass_target(world, delta: float, neighbors: Array, grass: Dictionary) -> bool:
	target_position = grass["center"]
	var eat_distance := float(feeding.get("eat_distance", 18.0))
	var current_cell_index: int = -1 if world.terrain_system == null else world.terrain_system.get_index_from_position(position)
	var cell_reach_distance: float = minf(eat_distance, world.resource_system.cell_size * 0.45)
	var reached_target_cell: bool = int(grass.get("index", -1)) == current_cell_index
	var reached_target_radius: bool = position.distance_squared_to(grass["center"]) <= cell_reach_distance * cell_reach_distance
	if reached_target_cell or reached_target_radius:
		var consumed: float = world.resource_system.consume_cell(int(grass.get("index", -1)), float(feeding.get("bite_amount", 18.0)))
		if consumed > 0.0:
			set_state("eat", world.current_tick)
			clear_navigation()
			interaction_timer = float(feeding.get("eat_duration", 0.55))
			reduce_hunger(consumed * float(feeding.get("nutrition_gain", 0.8)))
			restore_energy(consumed * 0.18)
			world.emit_event("GrassConsumed", self, -1, {
				"consumed": consumed,
				"cell_index": int(grass["index"]),
			})
			return true
		clear_targets()
		var fallback_grass: Dictionary = _find_grass_target(world)
		if fallback_grass.is_empty():
			return false
		if int(fallback_grass.get("index", -1)) == int(grass.get("index", -1)):
			return false
		return _move_to_grass_target(world, delta, neighbors, fallback_grass)

	set_state("seek_food", world.current_tick)
	var herd_vector: Vector2 = _herd_vector(world, neighbors, false)
	var waypoint: Vector2 = world.get_next_waypoint(position, grass["center"], id)
	var move_vector: Vector2 = Steering.combine([
		{"vector": Steering.seek(position, waypoint), "weight": 1.3},
		{"vector": herd_vector, "weight": 0.15},
	])
	move_with_vector(world, move_vector, float(movement.get("max_speed", 70.0)), delta)
	return true


func _flee(world, delta: float, predators: Array, neighbors: Array) -> void:
	set_state("flee", world.current_tick)
	clear_targets()

	var flee_vector := Vector2.ZERO
	for predator in predators:
		flee_vector += Steering.flee(position, predator.position)
	flee_vector = flee_vector.normalized()

	var herd_weights: Dictionary = balance.get("herd_weights", {})
	var escape_target: Vector2 = world.choose_escape_destination(position, flee_vector, 168.0)
	target_position = escape_target
	var waypoint: Vector2 = world.get_next_waypoint(position, escape_target, id, true)
	var move_vector: Vector2 = Steering.combine([
		{"vector": Steering.seek(position, waypoint), "weight": float(herd_weights.get("flee", 2.4))},
		{"vector": _herd_vector(world, neighbors, false), "weight": 0.35},
	])
	move_with_vector(world, move_vector, float(movement.get("sprint_speed", 115.0)), delta)


func _should_regroup(world) -> bool:
	if group_id == -1:
		return false
	if hunger >= float(balance.get("state_thresholds", {}).get("graze_hunger_floor", 20.0)):
		return false
	var center: Variant = world.get_group_center(group_id, species_type, id)
	if center == null:
		return false
	var rejoin_distance := float(balance.get("state_thresholds", {}).get("rejoin_distance", 135.0))
	return position.distance_squared_to(center) >= rejoin_distance * rejoin_distance


func _regroup(world, delta: float, neighbors: Array) -> void:
	var center: Variant = world.get_group_center(group_id, species_type, id)
	if center == null:
		_wander_or_graze(world, delta, neighbors)
		return

	set_state("regroup", world.current_tick)
	target_position = center
	var weights: Dictionary = balance.get("herd_weights", {})
	var waypoint: Vector2 = world.get_next_waypoint(position, center, id)
	var move_vector: Vector2 = Steering.combine([
		{"vector": Steering.seek(position, waypoint), "weight": float(weights.get("regroup", 1.1))},
		{"vector": _herd_vector(world, neighbors, true), "weight": 0.85},
	])
	move_with_vector(world, move_vector, float(movement.get("max_speed", 70.0)), delta)


func _attempt_reproduce(world, delta: float, neighbors: Array) -> bool:
	var safe_radius := float(reproduction.get("safe_radius", 100.0))
	if not Perception.get_nearby_agents(world, position, safe_radius, SPECIES_PREDATOR, id).is_empty():
		return false

	var mates: Array = Perception.get_nearby_agents(
		world,
		position,
		float(perception.get("mate_search_radius", 70.0)),
		SPECIES_HERBIVORE,
		id
	)
	var chosen_mate = null
	for mate in mates:
		if mate.sex == sex or not mate.can_reproduce():
			continue
		if mate.group_id != -1 and group_id != -1 and mate.group_id != group_id:
			continue
		chosen_mate = mate
		break

	if chosen_mate == null:
		return false

	target_agent_id = chosen_mate.id
	target_position = chosen_mate.position
	if position.distance_squared_to(chosen_mate.position) > 16.0 * 16.0:
		set_state("reproduce", world.current_tick)
		var waypoint: Vector2 = world.get_next_waypoint(position, chosen_mate.position, id)
		var move_vector: Vector2 = Steering.combine([
			{"vector": Steering.seek(position, waypoint), "weight": 1.2},
			{"vector": _herd_vector(world, neighbors, true), "weight": 0.5},
		])
		move_with_vector(world, move_vector, float(movement.get("max_speed", 70.0)), delta)
		return true

	if id > chosen_mate.id:
		stop_motion(delta)
		return true

	var spawn_center: Vector2 = position.lerp(chosen_mate.position, 0.5)
	var spawn_offset: Vector2 = world.random_unit_vector() * float(reproduction.get("offspring_spawn_radius", 18.0))
	var child_position: Vector2 = world.clamp_position(spawn_center + spawn_offset)
	world.queue_spawn_agent(SPECIES_HERBIVORE, child_position, group_id, self, chosen_mate)

	set_state("reproduce", world.current_tick)
	chosen_mate.set_state("reproduce", world.current_tick)
	interaction_timer = 0.8
	chosen_mate.interaction_timer = 0.8
	reproduction_cooldown = float(reproduction.get("cooldown", 30.0))
	chosen_mate.reproduction_cooldown = float(chosen_mate.reproduction.get("cooldown", 30.0))
	spend_energy(float(reproduction.get("birth_energy_cost", 18.0)))
	chosen_mate.spend_energy(float(chosen_mate.reproduction.get("birth_energy_cost", 18.0)))
	return true


func _execute_selected_action(world, delta: float, neighbors: Array, predators: Array, action_name: StringName) -> void:
	match action_name:
		AgentAction.FLEE_TO_SAFE_AREA:
			if predators.is_empty():
				_explore(world, delta, neighbors)
				return
			_flee(world, delta, predators, neighbors)
		AgentAction.DRINK:
			if not _seek_or_drink(world, delta, neighbors):
				_explore(world, delta, neighbors)
		AgentAction.GRAZE:
			if not _seek_or_eat(world, delta, neighbors):
				_explore(world, delta, neighbors)
		AgentAction.REST:
			_rest(world, delta)
		AgentAction.JOIN_HERD:
			if _should_regroup(world):
				_regroup(world, delta, neighbors)
			else:
				_explore(world, delta, neighbors)
		AgentAction.EXPLORE:
			_explore(world, delta, neighbors)
		_:
			_explore(world, delta, neighbors)


func _rest(world, delta: float) -> void:
	set_state("rest", world.current_tick)
	clear_targets()
	move_with_vector(world, Vector2.ZERO, 0.0, delta)


func _explore(world, delta: float, neighbors: Array) -> void:
	var weights: Dictionary = balance.get("herd_weights", {})
	var wander_vector: Vector2 = Steering.wander(self, world.rng)
	var herd_vector: Vector2 = _herd_vector(world, neighbors, true)
	set_state("wander", world.current_tick)
	clear_targets()
	var combined: Vector2 = Steering.combine([
		{"vector": wander_vector, "weight": float(weights.get("wander", 0.45))},
		{"vector": herd_vector, "weight": 1.0},
	])
	move_with_vector(world, combined, float(movement.get("max_speed", 70.0)) * 0.9, delta)


func _wander_or_graze(world, delta: float, neighbors: Array) -> void:
	var weights: Dictionary = balance.get("herd_weights", {})
	var wander_vector: Vector2 = Steering.wander(self, world.rng)
	var herd_vector: Vector2 = _herd_vector(world, neighbors, true)
	var base_speed: float = float(movement.get("max_speed", 70.0))
	var graze_hunger_floor := float(balance.get("state_thresholds", {}).get("graze_hunger_floor", 20.0))

	if hunger >= graze_hunger_floor:
		var grass: Dictionary = _find_grass_target(world)
		if not grass.is_empty():
			_move_to_grass_target(world, delta, neighbors, grass)
			return

	set_state("wander", world.current_tick)
	clear_targets()
	var combined: Vector2 = Steering.combine([
		{"vector": wander_vector, "weight": float(weights.get("wander", 0.45))},
		{"vector": herd_vector, "weight": 1.0},
	])
	move_with_vector(world, combined, base_speed * 0.9, delta)


func _get_group_neighbors(world) -> Array:
	var species_neighbors: Array = Perception.get_nearby_agents(
		world,
		position,
		float(perception.get("neighbor_radius", 90.0)),
		SPECIES_HERBIVORE,
		id
	)
	if group_id == -1:
		return species_neighbors

	var grouped: Array = []
	for neighbor in species_neighbors:
		if neighbor.group_id == group_id:
			grouped.append(neighbor)
	return grouped if not grouped.is_empty() else species_neighbors


func _herd_vector(world, neighbors: Array, include_wander: bool) -> Vector2:
	var weights: Dictionary = balance.get("herd_weights", {})
	var separation_radius := float(perception.get("separation_radius", 28.0))
	var vectors := [
		{"vector": Steering.cohesion(position, neighbors), "weight": float(weights.get("cohesion", 0.75))},
		{"vector": Steering.alignment(neighbors), "weight": float(weights.get("alignment", 0.55))},
		{"vector": Steering.separation(position, neighbors, separation_radius), "weight": float(weights.get("separation", 1.2))},
	]
	if include_wander:
		vectors.append({"vector": Steering.wander(self, world.rng), "weight": float(weights.get("wander", 0.45))})
	return Steering.combine(vectors)
