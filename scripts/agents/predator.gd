class_name Predator
extends AgentBase

const WATER_INVESTIGATION_COOLDOWN_SECONDS := 12.0
const AgentAIState := preload("res://scripts/agents/ai/agent_ai_state.gd")
const AgentAction := preload("res://scripts/agents/ai/agent_action.gd")
const PredatorAIScript := preload("res://scripts/agents/ai/predator_ai.gd")

var hunt: Dictionary = {}
var preferred_mate_id: int = -1
var target_carcass_id: int = -1
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
	hunt = species_config.get("hunt", {})
	preferred_mate_id = -1
	target_carcass_id = -1
	_ai_controller = PredatorAIScript.new(balance_config)
	debug_color = Color(0.93, 0.47, 0.32)


func tick(world, delta: float) -> void:
	update_needs(delta)
	_maybe_drink(world)
	if apply_survival_checks(world, delta):
		set_ai_state(AgentAIState.DEAD)
		return
	_update_kin_state(world)

	if interaction_timer > 0.0:
		stop_motion(delta)
		return

	var context = _ai_controller.build_context(self, world)
	var next_ai_state: StringName = _ai_controller.resolve_state(self, context)
	set_ai_state(next_ai_state)
	if next_ai_state == AgentAIState.ENGAGED:
		_ai_controller.sync_engaged_action(self, world.current_tick)
		if _continue_engaged_flow(world, delta):
			return
		set_ai_state(AgentAIState.ALIVE)
		context = _ai_controller.build_context(self, world)

	var scoped_context = context.with_state(ai_state)
	_ai_controller.update_action_target_tracking(self, scoped_context)
	if can_reproduce() and _attempt_reproduce(world, delta):
		set_ai_state(AgentAIState.ENGAGED)
		force_current_action(AgentAction.REPRODUCE, "reproduction override", world.current_tick)
		return

	var decision = _ai_controller.select_action(self, scoped_context, world.current_tick)
	apply_action_decision(decision, world.current_tick)
	_execute_selected_action(world, delta, decision.selected_action)


func clear_targets(world = null) -> void:
	if world != null:
		release_carcass_target(world)
	else:
		target_carcass_id = -1
	super.clear_targets()


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


func _get_debug_target_text() -> String:
	if target_carcass_id != -1:
		return "carcass:%d" % target_carcass_id
	return super._get_debug_target_text()


func _continue_or_finish_chase(world, delta: float) -> bool:
	if state not in ["seek_prey", "chase", "attack"]:
		return false
	if target_agent_id == -1:
		return false

	var prey: AgentBase = world.get_agent(target_agent_id)
	if prey == null or not prey.is_alive or prey.species_type != SPECIES_HERBIVORE:
		clear_targets(world)
		return false

	var break_radius: float = float(perception.get("chase_break_radius", 260.0))
	var max_chase_duration: float = float(balance.get("hunt_rules", {}).get("max_chase_duration", 9.0))
	var kin_break_radius: float = float(balance.get("hunt_rules", {}).get("kin_chase_break_radius", 220.0))
	var critical_hunger_multiplier: float = float(balance.get("hunt_rules", {}).get("critical_hunger_kin_break_multiplier", 1.75))
	var attack_radius: float = float(perception.get("attack_radius", 18.0))
	var min_chase_energy: float = float(hunt.get("min_chase_energy", 4.0))
	var critical_hunger: float = float(balance.get("state_thresholds", {}).get("critical_hunger", 65.0))
	var distance_sq: float = position.distance_squared_to(prey.position)
	var distance: float = sqrt(distance_sq)
	var fail_reason := ""
	if distance > break_radius:
		fail_reason = "out_of_range"
	elif chase_timer >= max_chase_duration:
		fail_reason = "timeout"
	elif energy <= min_chase_energy and distance > attack_radius * 1.5:
		fail_reason = "low_energy"
	elif last_known_kin_center != null:
		var allowed_kin_gap := kin_break_radius
		if hunger >= critical_hunger:
			allowed_kin_gap *= critical_hunger_multiplier
		if position.distance_to(last_known_kin_center) > allowed_kin_gap:
			fail_reason = "kin_gap"
	if fail_reason != "":
		var failure_data := {
			"reason": fail_reason,
			"distance": distance,
			"chase_time": chase_timer,
			"energy": energy,
		}
		if fail_reason == "kin_gap" and last_known_kin_center != null:
			failure_data["kin_distance"] = position.distance_to(last_known_kin_center)
		world.emit_event("PredationFailed", self, prey.id, failure_data)
		clear_targets(world)
		return false

	chase_timer += delta
	spend_energy(float(metabolism.get("chase_energy_cost", 5.0)) * delta)
	target_position = prey.position
	if distance <= attack_radius:
		return _attack(world, prey)

	set_state("chase", world.current_tick)
	var chase_waypoint: Vector2 = world.get_next_waypoint(position, prey.position, id)
	move_with_vector(world, Steering.seek(position, chase_waypoint), float(movement.get("sprint_speed", 128.0)), delta)
	return true


func _hunt(world, delta: float) -> bool:
	var prey: AgentBase = _choose_prey(world)
	if prey == null:
		return false
	release_carcass_target(world)
	target_agent_id = prey.id
	target_position = prey.position
	set_state("seek_prey", world.current_tick)
	var prey_waypoint: Vector2 = world.get_next_waypoint(position, prey.position, id)
	move_with_vector(world, Steering.seek(position, prey_waypoint), float(movement.get("max_speed", 84.0)), delta)
	chase_timer = maxf(chase_timer, delta)
	return true


func _attack(world, prey) -> bool:
	if attack_cooldown > 0.0:
		set_state("attack", world.current_tick)
		return true

	set_state("attack", world.current_tick)
	attack_cooldown = float(feeding.get("attack_cooldown", 1.0))

	var attack_config: Dictionary = balance.get("attack", {})
	var energy_ratio: float = energy / maxf(1.0, float(metabolism.get("max_energy", 100.0)))
	var isolation: float = _prey_isolation(world, prey)
	var prey_speed_ratio: float = prey.velocity.length() / maxf(1.0, float(prey.movement.get("sprint_speed", prey.movement.get("max_speed", 100.0))))

	var chance := float(attack_config.get("base_success_chance", 0.38))
	chance += energy_ratio * float(attack_config.get("predator_energy_bonus", 0.18))
	chance += isolation * float(attack_config.get("prey_isolation_bonus", 0.2))
	chance -= prey_speed_ratio * float(attack_config.get("prey_escape_penalty", 0.16))
	chance = clampf(chance, 0.08, 0.92)

	if world.rng.randf() <= chance:
		world.emit_event("PredationSuccess", self, prey.id, {
			"chance": chance,
			"isolation": isolation,
		})
		world.kill_agent(prey, "predation", id)
		var carcass: Dictionary = world.find_carcass_by_source_agent(prey.id)
		target_agent_id = -1
		if not carcass.is_empty():
			target_carcass_id = int(carcass.get("id", -1))
			target_position = carcass["position"]
		else:
			target_carcass_id = -1
			target_position = prey.position
		set_state("seek_carcass", world.current_tick)
		clear_navigation()
	else:
		world.emit_event("PredationFailed", self, prey.id, {
			"reason": "miss",
			"chance": chance,
			"isolation": isolation,
		})
	return true


func _rest(world, delta: float) -> void:
	set_state("rest", world.current_tick)
	clear_targets(world)
	move_with_vector(world, Vector2.ZERO, 0.0, delta)


func set_preferred_mate_id(agent_id: int) -> void:
	if preferred_mate_id != -1 and preferred_mate_id != agent_id:
		remove_kin_id(preferred_mate_id)
	preferred_mate_id = agent_id
	if agent_id != -1:
		add_kin_id(agent_id)


func clear_preferred_mate() -> void:
	if preferred_mate_id != -1:
		remove_kin_id(preferred_mate_id)
	preferred_mate_id = -1


func _attempt_reproduce(world, delta: float) -> bool:
	var chosen_mate: AgentBase = _find_viable_mate(world, true)
	if chosen_mate == null:
		return false

	release_carcass_target(world)
	_set_mutual_preferred_mate(chosen_mate)
	target_agent_id = chosen_mate.id
	target_position = chosen_mate.position
	if position.distance_squared_to(chosen_mate.position) > 18.0 * 18.0:
		set_state("reproduce", world.current_tick)
		var mate_waypoint: Vector2 = world.get_next_waypoint(position, chosen_mate.position, id)
		move_with_vector(world, Steering.seek(position, mate_waypoint), float(movement.get("max_speed", 84.0)), delta)
		return true

	if id > chosen_mate.id:
		stop_motion(delta)
		return true

	var center: Vector2 = position.lerp(chosen_mate.position, 0.5)
	var child_position: Vector2 = world.clamp_position(center + world.random_unit_vector() * float(reproduction.get("offspring_spawn_radius", 20.0)))
	world.queue_spawn_agent(SPECIES_PREDATOR, child_position, -1, self, chosen_mate)

	set_state("reproduce", world.current_tick)
	chosen_mate.set_state("reproduce", world.current_tick)
	interaction_timer = 1.0
	chosen_mate.interaction_timer = 1.0
	reproduction_cooldown = float(reproduction.get("cooldown", 52.0))
	chosen_mate.reproduction_cooldown = float(chosen_mate.reproduction.get("cooldown", 52.0))
	spend_energy(float(reproduction.get("birth_energy_cost", 22.0)))
	chosen_mate.spend_energy(float(chosen_mate.reproduction.get("birth_energy_cost", 22.0)))
	clear_targets(world)
	if chosen_mate.has_method("clear_targets"):
		chosen_mate.call("clear_targets", world)
	return true


func _continue_engaged_flow(world, delta: float) -> bool:
	if state == "reproduce" and _attempt_reproduce(world, delta):
		return true
	if _continue_or_finish_chase(world, delta):
		return true
	if (state in ["seek_carcass", "feed_carcass"] or target_carcass_id != -1) and _scavenge_or_feed(world, delta):
		return true
	if state == "investigate_water" and _investigate_recent_water(world, delta):
		return true
	return false


func _execute_selected_action(world, delta: float, action_name: StringName) -> void:
	match action_name:
		AgentAction.HUNT_PREY:
			if not _hunt(world, delta):
				_patrol(world, delta)
		AgentAction.SCAVENGE_CARCASS:
			if not _scavenge_or_feed(world, delta):
				_patrol(world, delta)
		AgentAction.DRINK:
			if not _seek_or_drink(world, delta):
				_patrol(world, delta)
		AgentAction.REST:
			_rest(world, delta)
		AgentAction.INVESTIGATE_WATER:
			if not _investigate_recent_water(world, delta):
				_patrol(world, delta)
		AgentAction.PAIR_COHESION:
			if not _regroup_with_kin(world, delta):
				_patrol(world, delta)
		AgentAction.PATROL:
			_patrol(world, delta)
		_:
			_patrol(world, delta)


func _patrol(world, delta: float) -> void:
	set_state("patrol", world.current_tick)
	clear_targets(world)
	_update_water_memory(world)
	move_with_vector(world, Steering.wander(self, world.rng), float(movement.get("max_speed", 84.0)) * 0.85, delta)


func _maybe_drink(world) -> void:
	var nearby_water: Dictionary = Perception.find_nearest_water(world, position, 32.0)
	if nearby_water.is_empty():
		return
	_remember_water_source(world, nearby_water)
	var drink_distance := float(feeding.get("drink_distance", 28.0)) + float(nearby_water.get("radius", 0.0))
	if position.distance_squared_to(nearby_water["position"]) > drink_distance * drink_distance:
		return
	if thirst <= 4.0:
		return
	var drink_restore: float = float(feeding.get("drink_restore", 14.0))
	reduce_thirst(drink_restore)
	clear_navigation()
	world.emit_event("WaterConsumed", self, -1, {
		"source_position": nearby_water["position"],
		"restored": drink_restore,
	})


func _choose_prey(world) -> AgentBase:
	var prey_candidates: Array = Perception.get_nearby_agents(
		world,
		position,
		float(perception.get("vision_radius", 240.0)),
		SPECIES_HERBIVORE,
		id
	)
	if prey_candidates.is_empty():
		return null

	var weights: Dictionary = balance.get("hunt_weights", {})
	var vision_radius: float = float(perception.get("vision_radius", 240.0))
	var best_score: float = -INF
	var best_prey: AgentBase = null
	for prey in prey_candidates:
		var distance_sq: float = position.distance_squared_to(prey.position)
		var distance_score: float = 1.0 - clampf(sqrt(distance_sq) / maxf(vision_radius, 1.0), 0.0, 1.0)
		var isolation: float = _prey_isolation(world, prey)
		var prey_energy: float = 1.0 - clampf(prey.energy / maxf(1.0, float(prey.metabolism.get("max_energy", 100.0))), 0.0, 1.0)
		var age_score: float = 0.0
		match prey.get_age_stage():
			"young":
				age_score = 0.8
			"old":
				age_score = 1.0
			_:
				age_score = 0.4

		var score: float = distance_score * float(weights.get("distance", 1.0))
		score += isolation * float(weights.get("isolation", 1.35))
		score += prey_energy * float(weights.get("energy", 0.45))
		score += age_score * float(weights.get("age_stage", 0.65))
		if score > best_score:
			best_score = score
			best_prey = prey
	return best_prey


func _prey_isolation(world, prey) -> float:
	var neighbors: Array = world.query_agents(prey.position, 72.0, SPECIES_HERBIVORE, prey.id)
	return clampf(1.0 - (float(neighbors.size()) / 6.0), 0.0, 1.0)


func _regroup_with_kin(world, delta: float) -> bool:
	if last_known_kin_center == null:
		return false

	var follow_radius: float = float(reproduction.get("preferred_mate_follow_radius", 180.0))
	var distance_sq: float = position.distance_squared_to(last_known_kin_center)
	if distance_sq <= follow_radius * follow_radius:
		return false

	release_carcass_target(world)
	target_agent_id = -1
	target_position = last_known_kin_center
	set_state("pair_cohesion", world.current_tick)
	var mate_waypoint: Vector2 = world.get_next_waypoint(position, last_known_kin_center, id)
	var vectors := []
	vectors.append({"vector": Steering.seek(position, mate_waypoint), "weight": float(reproduction.get("preferred_mate_seek_weight", 0.75))})
	vectors.append({"vector": Steering.wander(self, world.rng), "weight": 0.45})
	move_with_vector(world, Steering.combine(vectors), float(movement.get("max_speed", 84.0)) * 0.8, delta)
	return true


func _find_viable_mate(world, require_reproduction_ready: bool) -> AgentBase:
	var preferred_mate: AgentBase = _get_preferred_mate(world)
	if _is_valid_mate_candidate(preferred_mate, require_reproduction_ready):
		return preferred_mate

	var mates: Array = Perception.get_nearby_agents(
		world,
		position,
		float(perception.get("mate_search_radius", 80.0)),
		SPECIES_PREDATOR,
		id
	)
	var chosen_mate: AgentBase = null
	var best_distance_sq: float = INF
	for mate in mates:
		if not _is_valid_mate_candidate(mate, require_reproduction_ready):
			continue
		var distance_sq: float = position.distance_squared_to(mate.position)
		if distance_sq < best_distance_sq:
			best_distance_sq = distance_sq
			chosen_mate = mate

	if chosen_mate != null:
		_set_mutual_preferred_mate(chosen_mate)
	return chosen_mate


func _get_preferred_mate(world) -> AgentBase:
	if preferred_mate_id == -1:
		return null
	var mate: AgentBase = world.get_agent(preferred_mate_id)
	if mate == null or not mate.is_alive or mate.species_type != SPECIES_PREDATOR or mate.sex == sex:
		clear_preferred_mate()
		return null
	var break_radius: float = float(reproduction.get("preferred_mate_break_radius", 640.0))
	if position.distance_squared_to(mate.position) > break_radius * break_radius:
		clear_preferred_mate()
		return null
	return mate


func _is_valid_mate_candidate(candidate, require_reproduction_ready: bool) -> bool:
	if candidate == null or not candidate.is_alive:
		return false
	if candidate.id == id or candidate.species_type != SPECIES_PREDATOR or candidate.sex == sex:
		return false
	if require_reproduction_ready and not candidate.can_reproduce():
		return false
	return true


func _set_mutual_preferred_mate(mate: AgentBase) -> void:
	if mate == null:
		return
	set_preferred_mate_id(mate.id)
	if mate.has_method("set_preferred_mate_id"):
		mate.call("set_preferred_mate_id", id)


func _seek_or_drink(world, delta: float, water: Dictionary = {}) -> bool:
	if water.is_empty():
		water = _resolve_water_target(world)
	if water.is_empty():
		return false

	release_carcass_target(world)
	_remember_water_source(world, water)
	target_agent_id = -1
	target_position = water["position"]
	var drink_distance := float(feeding.get("drink_distance", 28.0)) + float(water.get("radius", 0.0))
	if position.distance_squared_to(water["position"]) <= drink_distance * drink_distance:
		clear_navigation()
		if thirst > 4.0:
			set_state("drink", world.current_tick)
			var drink_restore: float = float(feeding.get("drink_restore", 14.0))
			reduce_thirst(drink_restore)
			world.emit_event("WaterConsumed", self, -1, {
				"source_position": water["position"],
				"restored": drink_restore,
			})
			return true
		target_position = null
		return false

	set_state("seek_water", world.current_tick)
	var water_waypoint: Vector2 = world.get_next_waypoint(position, water["position"], id)
	move_with_vector(world, Steering.seek(position, water_waypoint), float(movement.get("max_speed", 84.0)), delta)
	return true


func _scavenge_or_feed(world, delta: float) -> bool:
	var carcass: Dictionary = _resolve_carcass_target(world)
	if carcass.is_empty():
		return false

	target_agent_id = -1
	target_position = carcass["position"]
	var feed_distance := float(feeding.get("feed_distance", feeding.get("eat_distance", 18.0)))
	if position.distance_squared_to(carcass["position"]) <= feed_distance * feed_distance:
		if not world.reserve_carcass_feeder(target_carcass_id, id):
			var alternate: Dictionary = _choose_carcass(world)
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
		reduce_hunger(consumed * float(feeding.get("carcass_nutrition_gain", 1.0)))
		restore_energy(consumed * float(feeding.get("carcass_energy_gain", 0.5)))
		var updated: Dictionary = world.get_carcass(target_carcass_id)
		if updated.is_empty() or float(updated.get("meat_remaining", 0.0)) <= 0.0:
			release_carcass_target(world)
		return true

	set_state("seek_carcass", world.current_tick)
	var carcass_waypoint: Vector2 = world.get_next_waypoint(position, carcass["position"], id)
	move_with_vector(world, Steering.seek(position, carcass_waypoint), float(movement.get("max_speed", 84.0)), delta)
	return true


func _resolve_carcass_target(world) -> Dictionary:
	if target_carcass_id != -1:
		var current_target: Dictionary = world.get_carcass(target_carcass_id)
		if not current_target.is_empty():
			return current_target
		release_carcass_target(world)
		target_position = null

	var carcass: Dictionary = _choose_carcass(world)
	if carcass.is_empty():
		return {}
	target_carcass_id = int(carcass.get("id", -1))
	return carcass


func _choose_carcass(world) -> Dictionary:
	var search_radius := float(balance.get("carcass", {}).get("search_radius", perception.get("vision_radius", 240.0)))
	var best_carcass := {}
	var best_distance_sq := INF
	var best_meat := -INF
	for carcass in world.query_carcasses(position, search_radius):
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


func _resolve_water_target(world, thresholds: Dictionary = {}) -> Dictionary:
	var critical_thirst := float(thresholds.get("critical_thirst", balance.get("state_thresholds", {}).get("critical_thirst", 60.0)))
	var search_radius := float(perception.get("water_search_radius", perception.get("vision_radius", 240.0)))
	if thirst >= critical_thirst:
		search_radius = maxf(search_radius * 3.0, 1200.0)

	var visible_water: Dictionary = Perception.find_nearest_water(
		world,
		position,
		search_radius
	)
	if not visible_water.is_empty():
		_remember_water_source(world, visible_water)
		return visible_water

	var remembered_sources := get_recent_water_sources(world.current_time, float(perception.get("water_memory_duration_seconds", 0.0)))
	if remembered_sources.is_empty():
		return {}
	return remembered_sources.front()


func _update_water_memory(world) -> void:
	var visible_water: Dictionary = Perception.find_nearest_water(
		world,
		position,
		float(perception.get("water_search_radius", perception.get("vision_radius", 240.0)))
	)
	if not visible_water.is_empty():
		_remember_water_source(world, visible_water)


func _should_seek_water(thresholds: Dictionary, water_target: Dictionary) -> bool:
	if water_target.is_empty():
		return false
	return thirst >= float(thresholds.get("critical_thirst", 60.0))


func _should_rest(thresholds: Dictionary) -> bool:
	var rest_energy := float(thresholds.get("rest_energy", 26.0))
	var rest_energy_resume := float(thresholds.get("rest_energy_resume", rest_energy + 8.0))
	if state == "rest":
		return energy <= rest_energy_resume
	return energy <= rest_energy


func _investigate_recent_water(world, delta: float) -> bool:
	var source: Dictionary = _get_recent_investigation_water_source(world)
	if source.is_empty():
		return false
	release_carcass_target(world)
	target_agent_id = -1
	target_position = source["position"]

	var investigate_distance := float(feeding.get("drink_distance", 28.0)) + float(source.get("radius", 0.0))
	if position.distance_squared_to(source["position"]) > investigate_distance * investigate_distance:
		set_state("investigate_water", world.current_tick)
		var waypoint: Vector2 = world.get_next_waypoint(position, source["position"], id)
		move_with_vector(world, Steering.seek(position, waypoint), float(movement.get("max_speed", 84.0)), delta)
		return true

	clear_navigation()
	if thirst > 4.0 and _seek_or_drink(world, delta, source):
		return true
	if _scavenge_or_feed(world, delta):
		return true
	if _hunt(world, delta):
		return true
	mark_water_source_investigated(source["position"], world.current_time)
	target_position = null
	return false


func _remember_water_source(world, source: Dictionary) -> void:
	if source.is_empty():
		return
	var updated_source: Dictionary = source.duplicate(true)
	if _water_source_has_herbivore(world, updated_source):
		updated_source["last_herbivore_seen_time"] = world.current_time
	remember_water(updated_source, world.current_time)


func _get_recent_investigation_water_source(world) -> Dictionary:
	var remembered_sources := get_recent_water_sources(
		world.current_time,
		float(perception.get("water_memory_duration_seconds", 0.0))
	)
	for source in remembered_sources:
		if float(source.get("last_herbivore_seen_time", -1.0)) < 0.0:
			continue
		var last_investigated_time := float(source.get("last_investigated_time", -1.0))
		if last_investigated_time >= 0.0 and world.current_time - last_investigated_time < WATER_INVESTIGATION_COOLDOWN_SECONDS:
			continue
		return source
	return {}


func _water_source_has_herbivore(world, source: Dictionary) -> bool:
	var source_position: Variant = source.get("position", null)
	if source_position == null:
		return false
	var herbivores: Array = Perception.get_nearby_agents(
		world,
		source_position,
		float(perception.get("vision_radius", 240.0)),
		SPECIES_HERBIVORE,
		-1
	)
	return not herbivores.is_empty()


func _update_kin_state(world) -> void:
	var live_kin: Array = []
	var kin_center := Vector2.ZERO
	for kin_id in kin_ids:
		var kin_agent: AgentBase = world.get_agent(int(kin_id))
		if kin_agent == null or not kin_agent.is_alive or kin_agent.species_type != SPECIES_PREDATOR:
			continue
		live_kin.append(kin_agent.id)
		kin_center += kin_agent.position
	kin_ids = live_kin
	if kin_ids.is_empty():
		last_known_kin_center = null
		return
	last_known_kin_center = kin_center / float(kin_ids.size())
