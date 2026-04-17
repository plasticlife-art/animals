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
var is_alive: bool = true
var sex: String = SEX_FEMALE
var reproduction_cooldown: float = 0.0
var target_agent_id: int = -1
var target_position = null
var group_id: int = -1
var last_state_change_tick: int = 0
var interaction_timer: float = 0.0
var attack_cooldown: float = 0.0
var chase_timer: float = 0.0
var wander_angle: float = 0.0
var debug_color: Color = Color.WHITE
var recent_water_sources: Array = []
var kin_ids: Array = []
var last_known_kin_center = null
var lod_tier: int = 0
var path_cells: Array = []
var path_index: int = 0
var path_goal_cell: int = -1
var last_repath_tick: int = -9999
var stuck_timer: float = 0.0

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
	target_agent_id = -1
	target_position = null
	clear_water_memory()
	kin_ids.clear()
	last_known_kin_center = null
	clear_navigation()
	lod_tier = 0
	debug_color = Color(0.9, 0.9, 0.9)


func tick(_world, _delta: float) -> void:
	pass


func tick_maintenance(world, delta: float) -> void:
	update_needs(delta)
	if apply_survival_checks(world, delta):
		return
	advance_inertia(world, delta)


func set_state(new_state: String, current_tick: int) -> void:
	if state == new_state:
		return
	state = new_state
	last_state_change_tick = current_tick


func update_needs(delta: float) -> void:
	age += delta
	hunger = minf(need_max, hunger + float(metabolism.get("hunger_rate", 2.0)) * delta)
	thirst = minf(need_max, thirst + float(metabolism.get("thirst_rate", 2.0)) * delta)
	reproduction_cooldown = maxf(0.0, reproduction_cooldown - delta)
	interaction_timer = maxf(0.0, interaction_timer - delta)
	attack_cooldown = maxf(0.0, attack_cooldown - delta)

	var max_energy := float(metabolism.get("max_energy", 100.0))
	var rest_recovery := float(metabolism.get("rest_recovery", 6.0))
	var energy_decay := float(metabolism.get("energy_decay", 2.0))
	if state in ["rest", "eat", "drink", "reproduce", "feed_carcass"]:
		energy = minf(max_energy, energy + rest_recovery * delta)
	else:
		energy = maxf(0.0, energy - energy_decay * delta)

	var critical_thirst := float(balance.get("state_thresholds", {}).get("critical_thirst", 65.0))
	if thirst >= critical_thirst:
		energy = maxf(0.0, energy - float(metabolism.get("dehydration_energy_penalty", 4.0)) * delta)


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
	position = world.resolve_movement_position(position, position + velocity * delta)
	if position.distance_squared_to(previous_position) <= 0.04 and desired_velocity.length_squared() > 0.001:
		stuck_timer += delta
	else:
		stuck_timer = maxf(0.0, stuck_timer - delta * 0.5)
		if position.distance_squared_to(previous_position) <= 0.04:
			velocity = velocity.move_toward(Vector2.ZERO, acceleration * delta)
	if velocity.length_squared() > 0.001:
		direction = velocity.normalized()


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


func get_debug_summary() -> Dictionary:
	return {
		"id": id,
		"species": species_type,
		"state": state,
		"energy": snappedf(energy, 0.1),
		"hunger": snappedf(hunger, 0.1),
		"thirst": snappedf(thirst, 0.1),
		"age": snappedf(age, 0.1),
		"target": _get_debug_target_text(),
		"speed": snappedf(velocity.length(), 0.1),
		"biome": "-",
		"path_nodes": path_cells.size(),
		"alive": is_alive,
		"sex": sex,
	}


func _get_debug_target_text() -> String:
	if target_agent_id != -1:
		return "agent:%d" % target_agent_id
	if target_position != null:
		return str(target_position)
	return "-"
