class_name AgentBase
extends RefCounted

const SPECIES_HERBIVORE := "herbivore"
const SPECIES_PREDATOR := "predator"
const SEX_FEMALE := "female"
const SEX_MALE := "male"

var id: int = -1
var species_type: String = ""
var position: Vector2 = Vector2.ZERO
var velocity: Vector2 = Vector2.ZERO
var direction: Vector2 = Vector2.RIGHT
var energy: float = 100.0
var hunger: float = 0.0
var thirst: float = 0.0
var age: float = 0.0
var state: String = "idle"
var ai_state: StringName = &"alive"
var current_action: StringName = &"none"
var is_alive: bool = true
var sex: String = SEX_FEMALE
var reproduction_cooldown: float = 0.0
var target_agent_id: int = -1
var target_position = null
var group_id: int = -1
var last_state_change_tick: int = 0
var last_action_change_tick: int = 0
var interaction_timer: float = 0.0
var attack_cooldown: float = 0.0
var chase_timer: float = 0.0
var wander_angle: float = 0.0
var debug_color: Color = Color.WHITE
var recent_water_sources: Array = []
var kin_ids: Array = []
var last_known_kin_center = null
var last_action_reason: String = ""
var last_action_scores: Dictionary = {}
var last_action_raw_scores: Dictionary = {}
var decision_target_data: Dictionary = {}
var action_target_failure_ticks: int = 0
var lod_tier: int = 0
var path_cells: Array = []
var path_index: int = 0
var path_goal_cell: int = -1
var last_repath_tick: int = -9999
var stuck_timer: float = 0.0
var last_decision_tick: int = -9999
var cached_snapshot = null
var cached_context = null
## Grazing target, held across a few ticks. Searching for one is the single most
## expensive thing a herbivore does, and the answer rarely changes between
## consecutive ticks. `WorldState._find_grass_target_for_agent()` owns the
## refresh rule and drops the cache early once the cell is grazed down.
var grass_target_cache: Dictionary = {}
var grass_target_tick: int = -9999

var movement: Dictionary = {}
var perception: Dictionary = {}
var metabolism: Dictionary = {}
var feeding: Dictionary = {}
var reproduction: Dictionary = {}
var aging: Dictionary = {}
var balance: Dictionary = {}
var need_max: float = 100.0


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
	id = agent_id
	species_type = new_species_type
	position = spawn_position
	sex = new_sex
	group_id = new_group_id
	movement = species_config.get("movement", {})
	perception = species_config.get("perception", {})
	metabolism = species_config.get("metabolism", {})
	feeding = species_config.get("feeding", {})
	reproduction = species_config.get("reproduction", {})
	aging = species_config.get("aging", {})
	balance = balance_config
	need_max = float(balance_config.get("need_max", 100.0))
	energy = float(metabolism.get("max_energy", 100.0))
	wander_angle = rng.randf_range(0.0, TAU)
	ai_state = &"alive"
	current_action = &"none"
	last_action_change_tick = 0
	target_agent_id = -1
	target_position = null
	clear_water_memory()
	kin_ids.clear()
	last_known_kin_center = null
	last_action_reason = ""
	last_action_scores.clear()
	last_action_raw_scores.clear()
	decision_target_data.clear()
	action_target_failure_ticks = 0
	clear_navigation()
	lod_tier = 0
	last_decision_tick = -9999
	cached_snapshot = null
	cached_context = null
	grass_target_cache = {}
	grass_target_tick = -9999
	debug_color = Color(0.9, 0.9, 0.9)


func tick(_world, _delta: float) -> void:
	pass


func tick_maintenance(world, delta: float) -> void:
	update_needs(delta, world.climate.metabolism_multiplier)
	if apply_survival_checks(world, delta):
		return
	advance_inertia(world, delta)


func cache_decision_state(snapshot, context, current_tick: int) -> void:
	cached_snapshot = snapshot
	cached_context = context
	last_decision_tick = current_tick


func clear_decision_cache() -> void:
	cached_snapshot = null
	cached_context = null
	grass_target_cache = {}
	grass_target_tick = -9999
	last_decision_tick = -9999


func set_state(new_state: String, current_tick: int) -> void:
	if state == new_state:
		return
	state = new_state
	last_state_change_tick = current_tick


func set_ai_state(new_state: StringName) -> void:
	ai_state = new_state


func get_ticks_in_current_action(current_tick: int) -> int:
	if current_action == &"none":
		return 0
	return maxi(0, current_tick - last_action_change_tick)


func apply_action_decision(decision, current_tick: int) -> void:
	if decision == null:
		return
	var selected_action: StringName = StringName(decision.selected_action)
	if current_action != selected_action:
		current_action = selected_action
		last_action_change_tick = current_tick
	last_action_reason = str(decision.reason)
	# ActionSelector already hands us freshly built dictionaries and drops the decision
	# immediately afterwards, so copying them again here was pure waste.
	last_action_scores = decision.final_scores
	last_action_raw_scores = decision.raw_scores
	decision_target_data = decision.target_data


func force_current_action(action_name: StringName, reason: String, current_tick: int) -> void:
	if current_action != action_name:
		current_action = action_name
		last_action_change_tick = current_tick
	last_action_reason = reason
	last_action_scores.clear()
	last_action_raw_scores.clear()


func clear_action_tracking(current_tick: int) -> void:
	current_action = &"none"
	last_action_change_tick = current_tick
	last_action_reason = ""
	last_action_scores.clear()
	last_action_raw_scores.clear()
	decision_target_data.clear()
	action_target_failure_ticks = 0


## Feeding uses hysteresis: an agent only starts eating once hunger reaches the
## start floor, but keeps eating down to the lower stop floor, so it neither
## grazes while full nor abandons a meal one point past the threshold.
func is_hunger_above_floor(start_floor: float, stop_floor_key: String, continuing: bool) -> bool:
	if not continuing:
		return hunger >= start_floor
	var thresholds: Dictionary = balance.get("state_thresholds", {})
	return hunger >= float(thresholds.get(stop_floor_key, minf(start_floor, 4.0)))


## `metabolism_scale` is the climate multiplier - winter costs more, night costs
## less. It is applied at the read sites and never written back: `metabolism` is
## a reference to the species.json sub-dictionary, shared by every agent of the
## species, so mutating it would scale the whole species permanently.
##
## Aging, recovery and the cooldowns stay unscaled. Recovery is not consumption,
## and scaling it would hand night rest a compounding bonus on top of the
## cheaper night metabolism.
func update_needs(delta: float, metabolism_scale: float = 1.0) -> void:
	age += delta
	hunger = minf(need_max, hunger + float(metabolism.get("hunger_rate", 2.0)) * metabolism_scale * delta)
	thirst = minf(need_max, thirst + float(metabolism.get("thirst_rate", 2.0)) * metabolism_scale * delta)
	reproduction_cooldown = maxf(0.0, reproduction_cooldown - delta)
	interaction_timer = maxf(0.0, interaction_timer - delta)
	attack_cooldown = maxf(0.0, attack_cooldown - delta)

	var max_energy := float(metabolism.get("max_energy", 100.0))
	var rest_recovery := float(metabolism.get("rest_recovery", 6.0))
	var energy_decay := float(metabolism.get("energy_decay", 2.0)) * metabolism_scale
	if state in ["rest", "eat", "drink", "reproduce", "feed_carcass"]:
		energy = minf(max_energy, energy + rest_recovery * delta)
	else:
		energy = maxf(0.0, energy - energy_decay * delta)

	var critical_thirst := float(balance.get("state_thresholds", {}).get("critical_thirst", 65.0))
	if thirst >= critical_thirst:
		energy = maxf(0.0, energy - float(metabolism.get("dehydration_energy_penalty", 4.0)) * metabolism_scale * delta)


func apply_survival_checks(world, delta: float) -> bool:
	var lifecycle: Dictionary = balance.get("lifecycle", {})
	if hunger >= float(lifecycle.get("starvation_death_threshold", need_max)):
		world.kill_agent(self, "starvation")
		return true
	if thirst >= float(lifecycle.get("thirst_death_threshold", need_max)):
		world.kill_agent(self, "thirst")
		return true

	var old_age_start := float(aging.get("old_age_start", aging.get("max_age", 9999.0)))
	var max_age := float(aging.get("max_age", 9999.0))
	if age >= max_age:
		world.kill_agent(self, "old_age")
		return true
	if age >= old_age_start:
		var chance := float(aging.get("old_age_death_chance_per_second", 0.0)) * delta
		if world.rng.randf() < chance:
			world.kill_agent(self, "old_age")
			return true
	return false


func move_with_vector(world, move_vector: Vector2, desired_speed: float, delta: float) -> void:
	var desired_velocity := Vector2.ZERO
	var effective_speed := desired_speed
	if move_vector.length_squared() > 0.0001:
		var local_move_cost := maxf(1.0, world.get_move_cost_at_position(position))
		effective_speed = desired_speed / local_move_cost
		desired_velocity = move_vector.normalized() * effective_speed
	var acceleration := float(movement.get("acceleration", 140.0))
	var previous_position := position
	velocity = velocity.move_toward(desired_velocity, acceleration * delta)
	velocity = velocity.move_toward(Vector2.ZERO, float(movement.get("drag", 3.0)) * delta)
	if effective_speed > 0.0 and velocity.length() > effective_speed:
		velocity = velocity.normalized() * effective_speed
	velocity = _damp_turn(velocity, delta)
	position = world.resolve_movement_position(position, position + velocity * delta)
	if position.distance_squared_to(previous_position) <= 0.04 and desired_velocity.length_squared() > 0.001:
		stuck_timer += delta
	else:
		stuck_timer = maxf(0.0, stuck_timer - delta * 0.5)
		if position.distance_squared_to(previous_position) <= 0.04:
			velocity = velocity.move_toward(Vector2.ZERO, acceleration * delta)
	if velocity.length_squared() > 0.001:
		direction = velocity.normalized()


## Caps how fast an animal can swing its heading.
##
## Without this the path itself is jagged, not just its rendering: `wander()`
## adds a random kick to the steering angle every tick, and the agent turns to
## the new heading instantly. No amount of smoothing in the renderer can hide a
## trajectory that genuinely zig-zags, which is why this lives in the simulation
## and is measured as a behaviour change rather than a visual one.
##
## A rate of zero disables it, which is what the test fixtures rely on.
func _damp_turn(new_velocity: Vector2, delta: float) -> Vector2:
	var max_rate := float(movement.get("max_turn_rate_degrees", 0.0))
	if max_rate <= 0.0 or delta <= 0.0:
		return new_velocity
	if new_velocity.length_squared() <= 0.0001 or direction.length_squared() <= 0.0001:
		return new_velocity
	var limit := deg_to_rad(max_rate) * delta
	var difference := wrapf(new_velocity.angle() - direction.angle(), -PI, PI)
	if absf(difference) <= limit:
		return new_velocity
	return Vector2.from_angle(direction.angle() + signf(difference) * limit) * new_velocity.length()


func advance_inertia(world, delta: float) -> void:
	var previous_position := position
	velocity = velocity.move_toward(Vector2.ZERO, float(movement.get("drag", 3.0)) * delta)
	position = world.resolve_movement_position(position, position + velocity * delta)
	if position.distance_squared_to(previous_position) <= 0.04:
		stuck_timer = maxf(0.0, stuck_timer - delta)
	if velocity.length_squared() > 0.001:
		direction = velocity.normalized()


func stop_motion(delta: float) -> void:
	var acceleration := float(movement.get("acceleration", 140.0))
	velocity = velocity.move_toward(Vector2.ZERO, acceleration * delta)
	if velocity.length_squared() > 0.001:
		direction = velocity.normalized()


func can_reproduce() -> bool:
	return is_alive \
		and age >= float(reproduction.get("maturity_age", 0.0)) \
		and reproduction_cooldown <= 0.0 \
		and energy >= float(reproduction.get("energy_threshold", 9999.0))


func spend_energy(amount: float) -> void:
	energy = maxf(0.0, energy - amount)


func restore_energy(amount: float) -> void:
	energy = minf(float(metabolism.get("max_energy", 100.0)), energy + amount)


func reduce_hunger(amount: float) -> void:
	hunger = maxf(0.0, hunger - amount)


func reduce_thirst(amount: float) -> void:
	thirst = maxf(0.0, thirst - amount)


func get_age_stage() -> String:
	if age < float(reproduction.get("maturity_age", 0.0)):
		return "young"
	if age >= float(aging.get("old_age_start", aging.get("max_age", 9999.0))):
		return "old"
	return "adult"


func clear_targets() -> void:
	target_agent_id = -1
	target_position = null
	chase_timer = 0.0
	clear_navigation()


func clear_navigation() -> void:
	path_cells.clear()
	path_index = 0
	path_goal_cell = -1
	last_repath_tick = -9999
	stuck_timer = 0.0


func move_to_target(world, target: Vector2, desired_speed: float, delta: float, force_repath: bool = false) -> void:
	target_position = target
	var waypoint: Vector2 = world.get_next_waypoint(position, target, id, force_repath)
	move_with_vector(world, waypoint - position, desired_speed, delta)


func remember_water(source: Dictionary, time_seconds: float) -> void:
	if source.is_empty():
		return
	var position_value = source.get("position", null)
	if position_value == null:
		return

	var previous_herbivore_seen_time := -1.0
	var previous_investigated_time := -1.0
	var existing_index := -1
	for index in range(recent_water_sources.size()):
		var existing: Dictionary = recent_water_sources[index]
		if existing.get("position", null) == position_value:
			existing_index = index
			previous_herbivore_seen_time = float(existing.get("last_herbivore_seen_time", -1.0))
			previous_investigated_time = float(existing.get("last_investigated_time", -1.0))
			break

	var updated_entry := {
		"position": position_value,
		"radius": float(source.get("radius", 0.0)),
		"last_seen_time": time_seconds,
		"last_herbivore_seen_time": previous_herbivore_seen_time,
		"last_investigated_time": previous_investigated_time,
	}
	if source.has("last_herbivore_seen_time"):
		updated_entry["last_herbivore_seen_time"] = float(source.get("last_herbivore_seen_time", previous_herbivore_seen_time))
	elif bool(source.get("herbivore_seen", false)):
		updated_entry["last_herbivore_seen_time"] = time_seconds
	if source.has("last_investigated_time"):
		updated_entry["last_investigated_time"] = float(source.get("last_investigated_time", previous_investigated_time))

	if existing_index != -1:
		recent_water_sources.remove_at(existing_index)
	recent_water_sources.push_front(updated_entry)
	while recent_water_sources.size() > 4:
		recent_water_sources.pop_back()


func clear_water_memory() -> void:
	recent_water_sources.clear()


func get_remembered_water(time_seconds: float, max_age_seconds: float) -> Dictionary:
	var remembered_sources := get_recent_water_sources(time_seconds, max_age_seconds)
	if remembered_sources.is_empty():
		return {}
	return remembered_sources.front().duplicate(true)


func get_recent_water_sources(time_seconds: float, max_age_seconds: float) -> Array:
	if max_age_seconds <= 0.0:
		clear_water_memory()
		return []

	var valid_sources: Array = []
	for entry in recent_water_sources:
		var last_seen_time := float(entry.get("last_seen_time", -1.0))
		if last_seen_time < 0.0:
			continue
		if time_seconds - last_seen_time > max_age_seconds:
			continue
		valid_sources.append(entry.duplicate(true))

	recent_water_sources = valid_sources.duplicate(true)
	recent_water_sources.sort_custom(Callable(self, "_sort_water_memory_entry"))
	return recent_water_sources.duplicate(true)


func mark_water_source_investigated(source_position: Vector2, time_seconds: float) -> void:
	remember_water({
		"position": source_position,
		"last_investigated_time": time_seconds,
	}, time_seconds)


func add_kin_id(agent_id: int) -> void:
	if agent_id == -1 or agent_id == id or kin_ids.has(agent_id):
		return
	kin_ids.append(agent_id)


func remove_kin_id(agent_id: int) -> void:
	if not kin_ids.has(agent_id):
		return
	kin_ids.erase(agent_id)


func _sort_water_memory_entry(a: Dictionary, b: Dictionary) -> bool:
	var a_herbivore_time := float(a.get("last_herbivore_seen_time", -1.0))
	var b_herbivore_time := float(b.get("last_herbivore_seen_time", -1.0))
	var a_has_herbivore := a_herbivore_time >= 0.0
	var b_has_herbivore := b_herbivore_time >= 0.0
	if a_has_herbivore != b_has_herbivore:
		return a_has_herbivore
	if a_has_herbivore and not is_equal_approx(a_herbivore_time, b_herbivore_time):
		return a_herbivore_time > b_herbivore_time
	return float(a.get("last_seen_time", -1.0)) > float(b.get("last_seen_time", -1.0))


func get_debug_summary(current_tick: int = 0) -> Dictionary:
	return {
		"id": id,
		"species": species_type,
		"state": state,
		"ai_state": String(ai_state),
		"current_action": String(current_action),
		"energy": snappedf(energy, 0.1),
		"hunger": snappedf(hunger, 0.1),
		"thirst": snappedf(thirst, 0.1),
		"age": snappedf(age, 0.1),
		"target": _get_debug_target_text(),
		"speed": snappedf(velocity.length(), 0.1),
		"biome": "-",
		"path_nodes": path_cells.size(),
		"ticks_in_current_action": get_ticks_in_current_action(current_tick),
		"last_action_reason": last_action_reason,
		"utility_scores": _snapshot_scores(last_action_scores),
		"utility_raw_scores": _snapshot_scores(last_action_raw_scores),
		"alive": is_alive,
		"sex": sex,
	}


## Half the space this animal's body occupies, used by the overlap pass in
## WorldState. Derived from the sprite so the simulation's idea of a body and
## the drawn animal agree; zero disables the pass for this agent.
func get_body_radius() -> float:
	return float(movement.get("body_radius", 0.0))


## How close a pair has to be for the rendezvous to count as contact.
##
## Derived from the bodies rather than hardcoded, because it has to clear them:
## `WorldState._resolve_agent_overlap()` holds two animals apart at the sum of
## their radii, so any threshold below that sum is unreachable and the pair
## shoves each other in place forever instead of breeding. `mate_contact_slack`
## is the margin on top, and it exists so the check is not decided by a float
## comparison against the exact distance the solver is aiming for.
func mate_contact_distance(mate: AgentBase) -> float:
	var slack := maxf(0.0, float(reproduction.get("mate_contact_slack", 4.0)))
	return get_body_radius() + mate.get_body_radius() + slack


## Everything `export_runtime_state` carries, plus the per-decision caches.
##
## Kept separate because the two callers want different things. Sector sleep
## drops the caches deliberately - a herd that wakes somewhere else should look
## around again - whereas a save is meant to resume exactly where it left off,
## and an agent that loses its grass target immediately re-searches. Measured:
## restoring without these had the loaded world eating twenty-seven times as
## much grass in its first ten ticks as the run it was supposed to continue.
func export_save_state() -> Dictionary:
	var state_data: Dictionary = export_runtime_state()
	state_data["last_decision_tick"] = last_decision_tick
	state_data["decision_target_data"] = decision_target_data.duplicate(true)
	state_data["grass_target_cache"] = grass_target_cache.duplicate(true)
	state_data["grass_target_tick"] = grass_target_tick
	return state_data


func apply_save_state(state_data: Dictionary) -> void:
	apply_runtime_state(state_data)
	last_decision_tick = int(state_data.get("last_decision_tick", last_decision_tick))
	decision_target_data = state_data.get("decision_target_data", {}).duplicate(true)
	grass_target_cache = state_data.get("grass_target_cache", {}).duplicate(true)
	grass_target_tick = int(state_data.get("grass_target_tick", grass_target_tick))


func export_runtime_state() -> Dictionary:
	return {
		"id": id,
		"species_type": species_type,
		"position": position,
		"velocity": velocity,
		"direction": direction,
		"energy": energy,
		"hunger": hunger,
		"thirst": thirst,
		"age": age,
		"state": state,
		"ai_state": String(ai_state),
		"current_action": String(current_action),
		"is_alive": is_alive,
		"sex": sex,
		"reproduction_cooldown": reproduction_cooldown,
		"target_agent_id": target_agent_id,
		"target_position": target_position,
		"group_id": group_id,
		"last_state_change_tick": last_state_change_tick,
		"last_action_change_tick": last_action_change_tick,
		"interaction_timer": interaction_timer,
		"attack_cooldown": attack_cooldown,
		"chase_timer": chase_timer,
		"wander_angle": wander_angle,
		"recent_water_sources": recent_water_sources.duplicate(true),
		"kin_ids": kin_ids.duplicate(),
		"last_known_kin_center": last_known_kin_center,
		"action_target_failure_ticks": action_target_failure_ticks,
		"lod_tier": lod_tier,
		"path_cells": path_cells.duplicate(),
		"path_index": path_index,
		"path_goal_cell": path_goal_cell,
		"last_repath_tick": last_repath_tick,
		"stuck_timer": stuck_timer,
	}


func apply_runtime_state(state_data: Dictionary) -> void:
	position = state_data.get("position", position)
	velocity = state_data.get("velocity", velocity)
	direction = state_data.get("direction", direction)
	energy = float(state_data.get("energy", energy))
	hunger = float(state_data.get("hunger", hunger))
	thirst = float(state_data.get("thirst", thirst))
	age = float(state_data.get("age", age))
	state = str(state_data.get("state", state))
	ai_state = StringName(state_data.get("ai_state", String(ai_state)))
	current_action = StringName(state_data.get("current_action", String(current_action)))
	is_alive = bool(state_data.get("is_alive", is_alive))
	sex = str(state_data.get("sex", sex))
	reproduction_cooldown = float(state_data.get("reproduction_cooldown", reproduction_cooldown))
	target_agent_id = int(state_data.get("target_agent_id", target_agent_id))
	target_position = state_data.get("target_position", target_position)
	group_id = int(state_data.get("group_id", group_id))
	last_state_change_tick = int(state_data.get("last_state_change_tick", last_state_change_tick))
	last_action_change_tick = int(state_data.get("last_action_change_tick", last_action_change_tick))
	interaction_timer = float(state_data.get("interaction_timer", interaction_timer))
	attack_cooldown = float(state_data.get("attack_cooldown", attack_cooldown))
	chase_timer = float(state_data.get("chase_timer", chase_timer))
	wander_angle = float(state_data.get("wander_angle", wander_angle))
	recent_water_sources = state_data.get("recent_water_sources", []).duplicate(true)
	kin_ids = state_data.get("kin_ids", []).duplicate()
	last_known_kin_center = state_data.get("last_known_kin_center", last_known_kin_center)
	action_target_failure_ticks = int(state_data.get("action_target_failure_ticks", action_target_failure_ticks))
	lod_tier = int(state_data.get("lod_tier", lod_tier))
	path_cells = state_data.get("path_cells", []).duplicate()
	path_index = int(state_data.get("path_index", path_index))
	path_goal_cell = int(state_data.get("path_goal_cell", path_goal_cell))
	last_repath_tick = int(state_data.get("last_repath_tick", last_repath_tick))
	stuck_timer = float(state_data.get("stuck_timer", stuck_timer))
	clear_decision_cache()


func _get_debug_target_text() -> String:
	if target_agent_id != -1:
		return "agent:%d" % target_agent_id
	if target_position != null:
		return str(target_position)
	return "-"


func _snapshot_scores(scores: Dictionary) -> Dictionary:
	var snapshot := {}
	var keys: Array = scores.keys()
	keys.sort_custom(func(a, b): return str(a) < str(b))
	for key in keys:
		snapshot[String(key)] = snappedf(float(scores.get(key, 0.0)), 0.001)
	return snapshot
