class_name Herbivore
extends AgentBase


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
	debug_color = Color(0.71, 0.88, 0.54)


func tick(world, delta: float) -> void:
	update_needs(delta)
	if apply_survival_checks(world, delta):
		return

	if interaction_timer > 0.0:
		stop_motion(delta)
		return

	var thresholds: Dictionary = balance.get("state_thresholds", {})
	var neighbors: Array = _get_group_neighbors(world)
	var predators: Array = Perception.get_nearby_agents(
		world,
		position,
		float(perception.get("danger_radius", 120.0)),
		SPECIES_PREDATOR,
		id
	)
	if not predators.is_empty():
		_flee(world, delta, predators, neighbors)
		return

	if thirst >= float(thresholds.get("critical_thirst", 60.0)) and _seek_or_drink(world, delta, neighbors):
		return
	if hunger >= float(thresholds.get("critical_hunger", 65.0)) and _seek_or_eat(world, delta, neighbors):
		return
	if _should_regroup(world):
		_regroup(world, delta, neighbors)
		return
	if can_reproduce() and _attempt_reproduce(world, delta, neighbors):
		return

	_wander_or_graze(world, delta, neighbors)


func _seek_or_drink(world, delta: float, neighbors: Array) -> bool:
	var water: Dictionary = Perception.find_nearest_water(world, position, float(perception.get("water_search_radius", 260.0)))
	if water.is_empty():
		water = get_remembered_water(
			world.current_time,
			float(perception.get("water_memory_duration_seconds", 0.0))
		)
	if water.is_empty():
		return false
	remember_water(water, world.current_time)

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


func _seek_or_eat(world, delta: float, neighbors: Array) -> bool:
	var thresholds: Dictionary = balance.get("state_thresholds", {})
	var critical_hunger := float(thresholds.get("critical_hunger", 65.0))
	var base_search_radius := float(perception.get("grass_search_radius", 180.0))
	var urgency_ratio := 0.0
	if hunger > critical_hunger:
		urgency_ratio = clampf((hunger - critical_hunger) / maxf(1.0, need_max - critical_hunger), 0.0, 1.0)
	var search_radius := lerpf(base_search_radius, maxf(base_search_radius * 3.0, 540.0), urgency_ratio)
	var min_biomass := 4.0 if urgency_ratio < 0.45 else 2.0

	var grass: Dictionary = Perception.find_best_grass(world, position, search_radius, min_biomass)
	if grass.is_empty() and hunger >= critical_hunger:
		grass = Perception.find_best_grass(
			world,
			position,
			maxf(search_radius * 1.5, 720.0),
			1.0
		)
	if grass.is_empty():
		return false

	target_position = grass["center"]
	var eat_distance := float(feeding.get("eat_distance", 18.0))
	if position.distance_squared_to(grass["center"]) <= eat_distance * eat_distance:
		var consumed: float = world.resource_system.consume_at_position(position, float(feeding.get("bite_amount", 18.0)))
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

	set_state("seek_food", world.current_tick)
	var herd_vector: Vector2 = _herd_vector(world, neighbors, true)
	var waypoint: Vector2 = world.get_next_waypoint(position, grass["center"], id)
	var move_vector: Vector2 = Steering.combine([
		{"vector": Steering.seek(position, waypoint), "weight": 1.3},
		{"vector": herd_vector, "weight": 0.7},
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
	if hunger >= float(balance.get("state_thresholds", {}).get("critical_hunger", 65.0)):
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


func _wander_or_graze(world, delta: float, neighbors: Array) -> void:
	var grass_here: float = world.resource_system.get_density_at_position(position)
	var weights: Dictionary = balance.get("herd_weights", {})
	var wander_vector: Vector2 = Steering.wander(self, world.rng)
	var herd_vector: Vector2 = _herd_vector(world, neighbors, true)
	var base_speed: float = float(movement.get("max_speed", 70.0))

	if grass_here >= 0.28 and hunger >= float(balance.get("state_thresholds", {}).get("graze_hunger_floor", 20.0)):
		set_state("seek_food", world.current_tick)
		var local_grass: Dictionary = Perception.find_best_grass(world, position, 64.0, 4.0)
		if not local_grass.is_empty():
			var waypoint: Vector2 = world.get_next_waypoint(position, local_grass["center"], id)
			var move_vector: Vector2 = Steering.combine([
				{"vector": Steering.seek(position, waypoint), "weight": 1.1},
				{"vector": herd_vector, "weight": 0.8},
			])
			move_with_vector(world, move_vector, base_speed * 0.85, delta)
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
