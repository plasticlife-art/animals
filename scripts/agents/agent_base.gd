class_name AgentBase
extends RefCounted

const TraitsScript := preload("res://scripts/agents/traits.gd")
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
## The carcass this agent has claimed, or -1. Lives here rather than on the
## meat eaters because `WorldState` releases it on death for every species.
var target_carcass_id: int = -1
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
## What this animal inherited (`Traits`): multipliers on its species' speed, sight, metabolic
## rate and lifespan, 1.0 being the species as written. Never written into the shared species
## dictionaries. `trait_hunger` and `trait_run_cost` are what they cost, cached.
var trait_speed: float = 1.0
var trait_vision: float = 1.0
var trait_appetite: float = 1.0
var trait_longevity: float = 1.0
var trait_hunger: float = 1.0
var trait_run_cost: float = 1.0
var trait_settings: Dictionary = {}
var last_action_scores: Dictionary = {}
var last_action_raw_scores: Dictionary = {}
var decision_target_data: Dictionary = {}
var action_target_failure_ticks: int = 0
var lod_tier: int = 0
var path_cells: Array = []
var path_index: int = 0
var path_goal_cell: int = -1
var last_repath_tick: int = -9999
var local_retry_tick: int = -9999
var local_path := PackedVector2Array()
var local_path_goal := Vector2.ZERO
## The scenery is static, so a normalized navigation goal and a recently checked
## direct corridor remain useful across movement ticks. Moving targets replace
## this cache as soon as their exact position changes.
var navigation_input_goal := Vector2(INF, INF)
var navigation_free_goal := Vector2.ZERO
var navigation_direct_clear: bool = false
var navigation_direct_check_tick: int = -9999
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
	trait_settings = TraitsScript.settings(species_config)
	set_traits(TraitsScript.NEUTRAL)
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
	# Decision target dictionaries may share immutable context storage. Rebind
	# instead of clearing the shared dictionary in place.
	decision_target_data = {}
	action_target_failure_ticks = 0


## Feeding uses hysteresis: an agent only starts eating once hunger reaches the
## start floor, but keeps eating down to the lower stop floor, so it neither
## grazes while full nor abandons a meal one point past the threshold.
func is_hunger_above_floor(start_floor: float, stop_floor_key: String, continuing: bool) -> bool:
	if not continuing:
		return hunger >= start_floor
	var thresholds: Dictionary = balance.get("state_thresholds", {})
	return hunger >= float(thresholds.get(stop_floor_key, minf(start_floor, 4.0)))


## The thirst twin of `is_hunger_above_floor()`, and the reason it now exists:
## eating had a start/stop band and drinking had none at all. An animal standing
## near water would go and drink at any thirst whatsoever, because the drink
## score paid for water being close rather than for the animal being thirsty, so
## a herd that wandered past a lake stayed there.
func is_thirst_above_floor(start_floor: float, stop_floor_key: String, continuing: bool) -> bool:
	if not continuing:
		return thirst >= start_floor
	var thresholds: Dictionary = balance.get("state_thresholds", {})
	return thirst >= float(thresholds.get(stop_floor_key, minf(start_floor, 4.0)))


## `state_thresholds.rest_energy` / `rest_energy_resume` existed and were read by
## the HUD and the dormant path, but never by the live rest evaluator - so rest
## had no energy floor and a calm animal in a meadow scored it on circumstance
## alone. The resume value is the hysteresis: start resting below the first,
## carry on until the second.
func is_energy_below_rest_floor() -> bool:
	var thresholds: Dictionary = balance.get("state_thresholds", {})
	if state == "rest" or current_action == &"rest":
		return energy <= float(metabolism.get("rest_energy_resume",
			thresholds.get("rest_energy_resume", 34.0)))
	return energy <= float(metabolism.get("rest_energy",
		thresholds.get("rest_energy", 26.0)))


func get_drink_thirst_floor() -> float:
	return float(balance.get("state_thresholds", {}).get("drink_thirst_floor", 40.0))


## Mid-drink, so that arriving at the water and taking the first mouthful does
## not immediately fall below the start floor and abandon the trip.
func can_continue_drinking() -> bool:
	return current_action == &"drink" or state in ["seek_water", "drink"]


## Asked by both the evaluator and the execution path, so the selector cannot
## send an animal to water the execution path will then refuse to drink from.
func is_drinking_allowed() -> bool:
	return is_thirst_above_floor(get_drink_thirst_floor(), "drink_stop_thirst_floor", can_continue_drinking())


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
	hunger = minf(need_max, hunger + float(metabolism.get("hunger_rate", 2.0)) * trait_hunger * metabolism_scale * delta)
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

	var old_age_start := float(aging.get("old_age_start", aging.get("max_age", 9999.0))) * trait_longevity
	var max_age := float(aging.get("max_age", 9999.0)) * trait_longevity
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
	var effective_speed := desired_speed * trait_speed
	if move_vector.length_squared() > 0.0001:
		var local_move_cost := maxf(1.0, world.get_move_cost_at_position(position))
		effective_speed = desired_speed * trait_speed / local_move_cost
		desired_velocity = move_vector.normalized() * effective_speed
	var fatigue_threshold := float(movement.get("fatigue_energy_ratio", 0.25)) * float(metabolism.get("max_energy", 100.0))
	var fatigue_scale := lerpf(float(movement.get("exhausted_speed_ratio", 0.55)), 1.0, clampf(energy / maxf(1.0, fatigue_threshold), 0.0, 1.0))
	desired_velocity *= fatigue_scale
	var acceleration := float(movement.get("acceleration", 140.0))
	var previous_position := position
	velocity = velocity.move_toward(desired_velocity, acceleration * delta)
	velocity = velocity.move_toward(Vector2.ZERO, float(movement.get("drag", 3.0)) * delta)
	if effective_speed > 0.0 and velocity.length() > effective_speed:
		velocity = velocity.normalized() * effective_speed
	velocity = _damp_turn(velocity, delta)
	position = world.resolve_movement_position(position, position + velocity * delta, get_body_radius())
	velocity = (position - previous_position) / maxf(delta, 0.00001)
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
	position = world.resolve_movement_position(position, position + velocity * delta, get_body_radius())
	# Collision resolution can stop the body or slide it along a surface. Keep
	# velocity tied to that actual displacement, just as `move_with_vector()`
	# does, so an LOD/inertial step cannot retain speed through a trunk and keep
	# trying to cross it on later ticks.
	velocity = (position - previous_position) / maxf(delta, 0.00001)
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
		and age >= float(reproduction.get("maturity_age", 0.0)) * trait_longevity \
		and reproduction_cooldown <= 0.0 \
		and energy >= float(reproduction.get("energy_threshold", 9999.0)) \
		and hunger <= float(reproduction.get("max_hunger", need_max)) \
		and thirst <= float(reproduction.get("max_thirst", need_max))


func spend_energy(amount: float) -> void:
	energy = maxf(0.0, energy - amount)


func restore_energy(amount: float) -> void:
	energy = minf(float(metabolism.get("max_energy", 100.0)), energy + amount)


func reduce_hunger(amount: float) -> void:
	hunger = maxf(0.0, hunger - amount)


func reduce_thirst(amount: float) -> void:
	thirst = maxf(0.0, thirst - amount)


func get_age_stage() -> String:
	if age < float(reproduction.get("maturity_age", 0.0)) * trait_longevity:
		return "young"
	if age >= float(aging.get("old_age_start", aging.get("max_age", 9999.0))) * trait_longevity:
		return "old"
	return "adult"


func clear_targets() -> void:
	target_agent_id = -1
	target_position = null
	chase_timer = 0.0
	clear_navigation()


func clear_navigation() -> void:
	local_path = PackedVector2Array()
	path_cells.clear()
	path_index = 0
	path_goal_cell = -1
	last_repath_tick = -9999
	navigation_input_goal = Vector2(INF, INF)
	navigation_free_goal = Vector2.ZERO
	navigation_direct_clear = false
	navigation_direct_check_tick = -9999
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
## --- Feeding on carrion ---------------------------------------------------
##
## This lived on `Predator` until a second carrion eater needed it. Nothing in it
## is predator-specific: the intake rates are `feeding.carcass_*` out of
## species.json, and `WorldState`'s reservation ledger never asked what species a
## feeder was - only its name said "predator".


## Whether feeding is worth starting, or worth continuing once started.
##
## Predators gorge. A carcass holds `balance.carcass.meat_total` but hunger alone
## caps intake at `hunger - feed_stop_hunger_floor`, so an animal arriving at
## hunger 60 could take only ~56 and leave the rest to rot inside the TTL. That
## capped energy income below the cost of the hunger cycle that earned the kill.
## While already at a meal, keep eating until the breeding reserve is covered.
##
## Deliberately gated on `continuing`: this finishes a carcass the animal is
## already at, it does not send a sated one hunting for energy alone.
func is_hungry_enough_to_feed(continuing: bool = false) -> bool:
	if is_hunger_above_floor(get_feed_hunger_floor(), "feed_stop_hunger_floor", continuing):
		return true
	if not continuing or not bool(feeding.get("gorge_below_energy_threshold", true)):
		return false
	return energy < float(reproduction.get("energy_threshold", 0.0))


func get_feed_hunger_floor() -> float:
	var thresholds: Dictionary = balance.get("state_thresholds", {})
	return float(thresholds.get("feed_hunger_floor", thresholds.get("graze_hunger_floor", 12.0)))


## Whether the animal is mid-meal. Overridden per species, because which actions
## and execution states count as "already feeding" differs.
func can_continue_feeding() -> bool:
	return false


## The AI context has to ask the same question the execution path does, gorging
## included, or the selector drops the feeding action the moment hunger is sated
## and walks the animal away from a carcass it is still gaining energy from.
func is_feeding_allowed() -> bool:
	return is_hungry_enough_to_feed(can_continue_feeding())


func release_carcass_target(world) -> void:
	if world != null and target_carcass_id != -1:
		world.release_carcass_feeder(target_carcass_id, id)
	target_carcass_id = -1


func on_carcass_removed(carcass_id: int) -> void:
	if carcass_id != target_carcass_id:
		return
	target_carcass_id = -1
	if state == "feed_carcass" or state == "seek_carcass":
		target_position = null
		clear_navigation()


## Walk to the claimed carcass, then eat it. Returns false when there is nothing
## to feed on, which every caller treats as "fall back to your idle behaviour".
func scavenge_or_feed(world, delta: float, preferred_carcass: Dictionary = {}) -> bool:
	if not is_hungry_enough_to_feed(can_continue_feeding()):
		release_carcass_target(world)
		target_position = null
		return false
	var carcass: Dictionary = resolve_carcass_target(world, preferred_carcass)
	if carcass.is_empty():
		return false

	target_agent_id = -1
	target_position = carcass["position"]
	var feed_distance := float(feeding.get("feed_distance", feeding.get("eat_distance", 18.0)))
	if position.distance_squared_to(carcass["position"]) <= feed_distance * feed_distance:
		if not world.reserve_carcass_feeder(target_carcass_id, id):
			# Full. Divert to the next body rather than queueing, which is what turns
			# a kill into a scattered group instead of a stack of waiting animals.
			var alternate: Dictionary = choose_carcass(world)
			if alternate.is_empty() or int(alternate.get("id", -1)) == target_carcass_id:
				return false
			target_carcass_id = int(alternate.get("id", -1))
			target_position = alternate["position"]
			set_state("seek_carcass", world.current_tick)
			var alternate_waypoint: Vector2 = world.get_next_waypoint(position, alternate["position"], id)
			move_with_vector(world, Steering.seek(position, alternate_waypoint), float(movement.get("max_speed", 84.0)), delta)
			return true

		set_state("feed_carcass", world.current_tick)
		clear_navigation()
		stop_motion(delta)
		var consumed: float = world.consume_carcass(
			target_carcass_id,
			float(feeding.get("carcass_consume_rate", 24.0)) * delta,
			id
		)
		if consumed <= 0.0:
			release_carcass_target(world)
			target_position = null
			return false
		# A quick metabolism fills up faster (`Traits`); the strength meat gives is the species'.
		reduce_hunger(consumed * float(feeding.get("carcass_nutrition_gain", 1.0)) * trait_appetite)
		restore_energy(consumed * float(feeding.get("carcass_energy_gain", 0.5)))
		var updated: Dictionary = world.get_carcass(target_carcass_id)
		if updated.is_empty() or float(updated.get("meat_remaining", 0.0)) <= 0.0:
			release_carcass_target(world)
		return true

	set_state("seek_carcass", world.current_tick)
	var carcass_waypoint: Vector2 = world.get_next_waypoint(position, carcass["position"], id)
	move_with_vector(world, Steering.seek(position, carcass_waypoint), float(movement.get("max_speed", 84.0)), delta)
	return true


## Whether this species will still eat a body of that age. A hunter walks away
## from carrion past `role.carrion_max_age_seconds`; a carrion feeder never does.
func accepts_carcass(world, carcass: Dictionary) -> bool:
	if carcass.is_empty():
		return false
	var max_age: float = world.species_registry.carrion_max_age(species_type)
	if max_age == INF:
		return true
	return world.current_time - float(carcass.get("created_at", 0.0)) <= max_age


func resolve_carcass_target(world, preferred_carcass: Dictionary = {}) -> Dictionary:
	if target_carcass_id != -1:
		var current_target: Dictionary = world.get_carcass(target_carcass_id)
		# Also drops a body that went stale during the walk over to it, so a
		# predator does not stand at a carcass it has decided is too old to eat.
		if not current_target.is_empty() and accepts_carcass(world, current_target):
			return current_target
		release_carcass_target(world)
		target_position = null

	var carcass: Dictionary = preferred_carcass if not preferred_carcass.is_empty() else choose_carcass(world)
	if carcass.is_empty():
		return {}
	target_carcass_id = int(carcass.get("id", -1))
	return carcass


## Nearest carcass that still has room, breaking ties on remaining meat.
func choose_carcass(world, carcasses: Array = []) -> Dictionary:
	var search_radius: float = float(world.carcass_search_radius(self))
	var best_carcass := {}
	var best_distance_sq := INF
	var best_meat := -INF
	if carcasses.is_empty():
		carcasses = world.query_carcasses(position, search_radius)
	for carcass in carcasses:
		if not accepts_carcass(world, carcass):
			continue
		var active_feeders: Array = carcass.get("active_feeder_ids", [])
		if not active_feeders.has(id) and active_feeders.size() >= int(carcass.get("max_feeders", 1)):
			continue
		var distance_sq := position.distance_squared_to(carcass["position"])
		var meat_remaining := float(carcass.get("meat_remaining", 0.0))
		if distance_sq < best_distance_sq or (is_equal_approx(distance_sq, best_distance_sq) and meat_remaining > best_meat):
			best_distance_sq = distance_sq
			best_meat = meat_remaining
			best_carcass = carcass
	return best_carcass


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


## Its inherited multipliers (`Traits.NAMES` order), and their cost on its needs and runs.
func set_traits(values: Array) -> void:
	var known: Array = values if values.size() == TraitsScript.NAMES.size() else TraitsScript.NEUTRAL
	trait_speed = float(known[TraitsScript.SPEED])
	trait_vision = float(known[TraitsScript.VISION])
	trait_appetite = float(known[TraitsScript.APPETITE])
	trait_longevity = float(known[TraitsScript.LONGEVITY])
	var settings := trait_settings if not trait_settings.is_empty() else TraitsScript.DEFAULTS
	trait_hunger = TraitsScript.hunger_factor(known, settings)
	trait_run_cost = TraitsScript.run_cost_factor(known, settings)


func traits() -> Array:
	return [trait_speed, trait_vision, trait_appetite, trait_longevity]


func export_runtime_state() -> Dictionary:
	return {
		"id": id,
		"traits": traits(),
		"species_type": species_type,
		"target_carcass_id": target_carcass_id,
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


## Compact state copied from the simulation worker every tick. Static species and
## balance dictionaries already live on the presentation agent, while navigation,
## memory and decision caches are worker-only until an explicit save/resync.
func export_presentation_state() -> Dictionary:
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
		"target_carcass_id": target_carcass_id,
		"target_position": target_position,
		"group_id": group_id,
		"last_state_change_tick": last_state_change_tick,
		"last_action_change_tick": last_action_change_tick,
		"interaction_timer": interaction_timer,
		"attack_cooldown": attack_cooldown,
		"chase_timer": chase_timer,
		"lod_tier": lod_tier,
	}


func apply_presentation_state(state_data: Dictionary) -> void:
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
	target_carcass_id = int(state_data.get("target_carcass_id", target_carcass_id))
	target_position = state_data.get("target_position", target_position)
	group_id = int(state_data.get("group_id", group_id))
	last_state_change_tick = int(state_data.get("last_state_change_tick", last_state_change_tick))
	last_action_change_tick = int(state_data.get("last_action_change_tick", last_action_change_tick))
	interaction_timer = float(state_data.get("interaction_timer", interaction_timer))
	attack_cooldown = float(state_data.get("attack_cooldown", attack_cooldown))
	chase_timer = float(state_data.get("chase_timer", chase_timer))
	lod_tier = int(state_data.get("lod_tier", lod_tier))


func apply_runtime_state(state_data: Dictionary) -> void:
	if state_data.has("traits"):
		set_traits(state_data["traits"])
	position = state_data.get("position", position)
	target_carcass_id = int(state_data.get("target_carcass_id", target_carcass_id))
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
