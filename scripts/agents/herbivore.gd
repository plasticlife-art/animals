class_name Herbivore
extends AgentBase

const AgentAIState := preload("res://scripts/agents/ai/agent_ai_state.gd")
const AgentAction := preload("res://scripts/agents/ai/agent_action.gd")
const HerbivoreAIScript := preload("res://scripts/agents/ai/herbivore_ai.gd")

var _ai_controller
var _escape_target_tick: int = -1
var _escape_target_position: Vector2 = Vector2.ZERO
var threat_memory_until: float = -1.0
var last_threat_position: Vector2 = Vector2.ZERO
var _escape_heading: Vector2 = Vector2.ZERO

func export_runtime_state() -> Dictionary:
	var data := super.export_runtime_state()
	data["threat_memory_until"] = threat_memory_until
	data["last_threat_position"] = last_threat_position
	data["escape_target"] = _escape_target_position
	data["escape_target_tick"] = _escape_target_tick
	data["escape_heading"] = _escape_heading
	return data

func apply_runtime_state(data: Dictionary) -> void:
	super.apply_runtime_state(data)
	threat_memory_until = float(data.get("threat_memory_until", -1.0))
	last_threat_position = data.get("last_threat_position", position)
	_escape_target_position = data.get("escape_target", position)
	_escape_target_tick = int(data.get("escape_target_tick", -1))
	_escape_heading = data.get("escape_heading", Vector2.ZERO)


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
	update_needs(delta, world.climate.metabolism_multiplier)
	if apply_survival_checks(world, delta):
		set_ai_state(AgentAIState.DEAD)
		return

	var predators: Array = world.visible_agents_multi(
		self,
		world.perception_radius(self, "danger_radius", 120.0),
		world.species_registry.predator_set(species_type)
	)
	if not predators.is_empty():
		last_threat_position = predators[0].position
		threat_memory_until = world.current_time + float(perception.get("threat_memory_seconds", 2.0))
	if not predators.is_empty() or world.current_time < threat_memory_until:
		interaction_timer = 0.0
		set_ai_state(AgentAIState.PANIC)
		force_current_action(AgentAction.FLEE_TO_SAFE_AREA, "danger or recent threat", world.current_tick)
		var neighbors: Array = [] if cached_snapshot == null else cached_snapshot.group_neighbors
		_flee(world, delta, predators, neighbors)
		return
	if ai_state == AgentAIState.PANIC:
		clear_decision_cache()
		clear_navigation()
		set_ai_state(AgentAIState.ALIVE)
	if interaction_timer > 0.0:
		stop_motion(delta)
		return
	var should_decide: bool = world.should_run_decision_tick(self)
	var snapshot = cached_snapshot
	var context = cached_context
	if should_decide or snapshot == null or context == null:
		var context_started_at_usec := Time.get_ticks_usec()
		snapshot = _build_snapshot(world)
		context = _ai_controller.build_context(self, world, snapshot)
		world.record_ai_context_ms(float(Time.get_ticks_usec() - context_started_at_usec) / 1000.0)
		var next_ai_state: StringName = _ai_controller.resolve_state(self, context)
		var scoped_context = context.with_state(next_ai_state)
		_ai_controller.update_action_target_tracking(self, scoped_context)
		set_ai_state(next_ai_state)
		cache_decision_state(snapshot, scoped_context, world.current_tick)
		predators = snapshot.predators
		if can_reproduce() and next_ai_state == AgentAIState.ALIVE and _attempt_reproduce(world, delta, snapshot.group_neighbors, predators):
			force_current_action(AgentAction.REPRODUCE, "reproduction override", world.current_tick)
			return
		var selection_started_at_usec := Time.get_ticks_usec()
		var decision = _ai_controller.select_action(self, scoped_context, world.current_tick)
		world.record_action_select_ms(float(Time.get_ticks_usec() - selection_started_at_usec) / 1000.0)
		apply_action_decision(decision, world.current_tick)
	else:
		if predators.is_empty():
			predators = snapshot.predators
		if not predators.is_empty():
			set_ai_state(AgentAIState.PANIC)

	if can_reproduce() and ai_state == AgentAIState.ALIVE and current_action == AgentAction.REPRODUCE and _attempt_reproduce(world, delta, snapshot.group_neighbors, predators):
		force_current_action(AgentAction.REPRODUCE, "reproduction override", world.current_tick)
		return

	_execute_selected_action(world, delta, snapshot.group_neighbors, predators, current_action, snapshot)


## Which perception snapshot this behaviour runs on. The forage loop below is
## shared with any herd animal; only its food differs, and that is what a
## subclass overrides here.
func _build_snapshot(world):
	return world.build_herbivore_snapshot(self)


func _seek_or_drink(world, delta: float, neighbors: Array, water: Dictionary = {}) -> bool:
	if water.is_empty():
		water = _resolve_water_target(world)
	if water.is_empty():
		return false

	target_position = water["position"]
	var drink_distance: float = float(feeding.get("drink_distance", 28.0)) + float(water.get("radius", 0.0))
	if position.distance_squared_to(water["position"]) <= drink_distance * drink_distance:
		# Arriving is not a reason to drink. Without this an animal that merely
		# grazed its way to the shore took a mouthful, and the herd standing by
		# the water never had a reason to leave it.
		if not is_drinking_allowed():
			return false
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
	if not _is_hungry_enough_to_graze(can_continue_grazing()):
		clear_targets()
		return false
	var grass: Dictionary = _find_grass_target(world)
	if grass.is_empty():
		return false
	return _move_to_grass_target(world, delta, neighbors, grass)


func _find_grass_target(world) -> Dictionary:
	return world._find_grass_target_for_agent(self)


func _move_to_grass_target(world, delta: float, neighbors: Array, grass: Dictionary) -> bool:
	if not _is_hungry_enough_to_graze(can_continue_grazing()):
		clear_targets()
		return false
	target_position = grass["center"]
	var eat_distance := float(feeding.get("eat_distance", 18.0))
	var current_cell_index: int = -1 if world.terrain_system == null else world.terrain_system.get_index_from_position(position)
	# `eat_distance` is the configured grazing reach, and the window must also never be
	# narrower than half a cell or a target cell centre is unreachable by the radius test.
	# The old `min` of the two took whichever was smaller, so on a fine grid the window
	# shrank below the distance an agent covers between two LOD-throttled ticks and it
	# could run past its target without the arrival check ever sampling it inside.
	var cell_reach_distance: float = maxf(eat_distance, world.resource_system.cell_size * 0.5)
	var reached_target_cell: bool = int(grass.get("index", -1)) == current_cell_index
	var reached_target_radius: bool = position.distance_squared_to(grass["center"]) <= cell_reach_distance * cell_reach_distance
	# Graze where you stand, not only on the exact cell that was chosen.
	#
	# A herd cannot physically fit inside one cell once bodies push each other
	# apart - twenty animals at arm's length need more than a 96-unit square - so
	# insisting on the chosen cell left most of the herd shuffling at its edge,
	# never eating. Any cell underfoot with grass on it is food.
	var bite_amount := float(feeding.get("bite_amount", 18.0))
	var eat_index: int = int(grass.get("index", -1))
	if not (reached_target_cell or reached_target_radius) and current_cell_index != -1:
		# A full bite, not a scrap. A lower bar had animals stopping for `eat_duration`
		# on nearly bare ground instead of walking to the patch they had chosen,
		# which fed them less than never grazing underfoot at all.
		if world.resource_system.get_biomass(current_cell_index) >= bite_amount:
			eat_index = current_cell_index
			reached_target_cell = true
	if reached_target_cell or reached_target_radius:
		var consumed: float = world.consume_grass_cell(eat_index, bite_amount)
		if consumed > 0.0:
			set_state("eat", world.current_tick)
			clear_navigation()
			interaction_timer = float(feeding.get("eat_duration", 0.55))
			var hunger_reduction := consumed * float(feeding.get("nutrition_gain", 0.8))
			reduce_hunger(hunger_reduction)
			if world.has_method("record_herbivore_hunger_reduction"):
				world.record_herbivore_hunger_reduction(hunger_reduction)
			restore_energy(consumed * 0.18)
			world.emit_event("GrassConsumed", self, -1, {
				"consumed": consumed,
				"cell_index": eat_index,
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


## Both the context builder and the flee action want the escape destination in the same
## tick, and each computation costs several pathfinds. Memoize it per tick so a panicking
## herd asks the navigation budget once per agent instead of twice.
func get_escape_destination(world, flee_vector: Vector2, base_distance: float) -> Vector2:
	var refresh_ticks := maxi(1, int(perception.get("escape_refresh_ticks", 12)))
	var changed := _escape_heading.dot(flee_vector) < 0.5
	var arrived := position.distance_to(_escape_target_position) < get_body_radius() + 8.0
	if _escape_target_tick >= 0 and world.current_tick - _escape_target_tick < refresh_ticks and not changed and not arrived and stuck_timer < 0.75:
		return _escape_target_position
	_escape_target_tick = world.current_tick
	_escape_heading = flee_vector
	_escape_target_position = world.choose_escape_destination(position, flee_vector, base_distance)
	return _escape_target_position


func _flee(world, delta: float, predators: Array, _neighbors: Array) -> void:
	set_state("flee", world.current_tick)
	target_agent_id = -1
	var flee_vector := Vector2.ZERO
	for predator in predators:
		var offset: Vector2 = position - predator.position
		flee_vector += offset / maxf(1.0, offset.length_squared())
	if flee_vector.is_zero_approx():
		flee_vector = position - last_threat_position
	if flee_vector.is_zero_approx():
		flee_vector = direction
	flee_vector = flee_vector.normalized()
	var escape_target := get_escape_destination(world, flee_vector, world.terrain_system.cell_size * float(perception.get("escape_distance_cells", 2.5)))
	target_position = escape_target
	var waypoint: Vector2 = world.get_next_waypoint(position, escape_target, id)
	move_with_vector(world, Steering.seek(position, waypoint), float(movement.get("sprint_speed", 115.0)), delta)
	if velocity.length_squared() > 1.0:
		spend_energy(float(metabolism.get("sprint_energy_cost", 2.0)) * delta)


func _should_regroup(world, group_center = null) -> bool:
	if group_id == -1:
		return false
	if hunger >= get_graze_hunger_floor():
		return false
	var center: Variant = group_center if group_center != null else world.get_group_center(group_id, species_type, id)
	if center == null:
		return false
	var rejoin_distance := float(balance.get("state_thresholds", {}).get("rejoin_distance", 135.0))
	return position.distance_squared_to(center) >= rejoin_distance * rejoin_distance


func _regroup(world, delta: float, neighbors: Array, group_center = null) -> void:
	var center: Variant = group_center if group_center != null else world.get_group_center(group_id, species_type, id)
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


func _attempt_reproduce(world, delta: float, neighbors: Array, predators: Array = []) -> bool:
	var safe_radius := float(reproduction.get("safe_radius", 100.0))
	if predators.is_empty():
		predators = world.query_agents_multi(position, safe_radius, world.species_registry.predator_set(species_type), id)
	if not predators.is_empty():
		return false

	var mates: Array = Perception.get_nearby_agents(
		world,
		position,
		float(perception.get("mate_search_radius", 70.0)),
		species_type,
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
	var contact_distance: float = mate_contact_distance(chosen_mate)
	if position.distance_squared_to(chosen_mate.position) > contact_distance * contact_distance:
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
	world.queue_spawn_agent(species_type, child_position, group_id, self, chosen_mate)

	set_state("reproduce", world.current_tick)
	chosen_mate.set_state("reproduce", world.current_tick)
	interaction_timer = 0.8
	chosen_mate.interaction_timer = 0.8
	reproduction_cooldown = float(reproduction.get("cooldown", 30.0))
	chosen_mate.reproduction_cooldown = float(chosen_mate.reproduction.get("cooldown", 30.0))
	spend_energy(float(reproduction.get("birth_energy_cost", 18.0)))
	chosen_mate.spend_energy(float(chosen_mate.reproduction.get("birth_energy_cost", 18.0)))
	return true


func _execute_selected_action(world, delta: float, neighbors: Array, predators: Array, action_name: StringName, snapshot = null) -> void:
	match action_name:
		AgentAction.FLEE_TO_SAFE_AREA:
			if predators.is_empty():
				_explore(world, delta, neighbors)
				return
			_flee(world, delta, predators, neighbors)
		AgentAction.DRINK:
			var water_target: Dictionary = {} if snapshot == null else snapshot.water_target
			if not _seek_or_drink(world, delta, neighbors, water_target):
				_explore(world, delta, neighbors)
		AgentAction.GRAZE:
			if not _is_hungry_enough_to_graze(can_continue_grazing()):
				_explore(world, delta, neighbors)
				return
			var grass_target: Dictionary = {} if snapshot == null else snapshot.grass_target
			if grass_target.is_empty():
				if not _seek_or_eat(world, delta, neighbors):
					_explore(world, delta, neighbors)
			elif not _move_to_grass_target(world, delta, neighbors, grass_target):
				_explore(world, delta, neighbors)
		AgentAction.REST:
			_rest(world, delta)
		AgentAction.JOIN_HERD:
			var group_center = null if snapshot == null else snapshot.group_center
			if _should_regroup(world, group_center):
				_regroup(world, delta, neighbors, group_center)
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
	if hunger >= get_graze_hunger_floor():
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
		species_type,
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


func can_continue_grazing() -> bool:
	return current_action == AgentAction.GRAZE or state in ["seek_food", "eat"]


func get_graze_hunger_floor() -> float:
	return float(balance.get("state_thresholds", {}).get("graze_hunger_floor", 20.0))


func _is_hungry_enough_to_graze(continuing: bool = false) -> bool:
	return is_hunger_above_floor(get_graze_hunger_floor(), "graze_stop_hunger_floor", continuing)
