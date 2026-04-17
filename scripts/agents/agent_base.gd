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
var remembered_water_position = null
var remembered_water_radius: float = 0.0
var remembered_water_time_seconds: float = -1.0
var lod_tier: int = 0

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
	if state in ["rest", "eat", "drink", "reproduce"]:
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
	if move_vector.length_squared() > 0.0001:
		desired_velocity = move_vector.normalized() * desired_speed
	var acceleration := float(movement.get("acceleration", 140.0))
	velocity = velocity.move_toward(desired_velocity, acceleration * delta)
	velocity = velocity.move_toward(Vector2.ZERO, float(movement.get("drag", 3.0)) * delta)
	if desired_speed > 0.0 and velocity.length() > desired_speed:
		velocity = velocity.normalized() * desired_speed
	position = world.clamp_position(position + velocity * delta)
	if velocity.length_squared() > 0.001:
		direction = velocity.normalized()


func advance_inertia(world, delta: float) -> void:
	velocity = velocity.move_toward(Vector2.ZERO, float(movement.get("drag", 3.0)) * delta)
	position = world.clamp_position(position + velocity * delta)
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


func remember_water(source: Dictionary, time_seconds: float) -> void:
	if source.is_empty():
		return
	remembered_water_position = source.get("position", null)
	remembered_water_radius = float(source.get("radius", 0.0))
	remembered_water_time_seconds = time_seconds


func clear_water_memory() -> void:
	remembered_water_position = null
	remembered_water_radius = 0.0
	remembered_water_time_seconds = -1.0


func get_remembered_water(time_seconds: float, max_age_seconds: float) -> Dictionary:
	if remembered_water_position == null or remembered_water_time_seconds < 0.0:
		return {}
	if max_age_seconds <= 0.0:
		clear_water_memory()
		return {}
	if time_seconds - remembered_water_time_seconds > max_age_seconds:
		clear_water_memory()
		return {}
	return {
		"position": remembered_water_position,
		"radius": remembered_water_radius,
	}


func get_debug_summary() -> Dictionary:
	var target_text := "-"
	if target_agent_id != -1:
		target_text = "agent:%d" % target_agent_id
	elif target_position != null:
		target_text = str(target_position)

	return {
		"id": id,
		"species": species_type,
		"state": state,
		"energy": snappedf(energy, 0.1),
		"hunger": snappedf(hunger, 0.1),
		"thirst": snappedf(thirst, 0.1),
		"age": snappedf(age, 0.1),
		"target": target_text,
		"speed": snappedf(velocity.length(), 0.1),
		"alive": is_alive,
		"sex": sex,
	}
