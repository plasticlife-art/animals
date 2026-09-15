class_name Predator
extends AgentBase

const WATER_INVESTIGATION_COOLDOWN_SECONDS := 12.0
const AgentAIState := preload("res://scripts/agents/ai/agent_ai_state.gd")
const AgentAction := preload("res://scripts/agents/ai/agent_action.gd")
const PredatorAIScript := preload("res://scripts/agents/ai/predator_ai.gd")

var hunt: Dictionary = {}
var last_seen_prey_position := Vector2.ZERO
var prey_last_seen_time: float = -1.0
var search_anchor := Vector2.ZERO
var search_started_time: float = -1.0
var search_waypoint_index: int = -1
var search_last_confirmed_position := Vector2.ZERO
var abandoned_prey_id: int = -1
var retry_after: float = -1.0
var preferred_mate_id: int = -1
var _ai_controller
var _cached_isolation_prey_id: int = -1
var _cached_prey_isolation: float = 0.0
var _last_water_memory_tick: int = -9999
var _patrol_goal: Variant = null
var _patrol_goal_tick: int = -9999


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
	update_needs(delta, world.climate.metabolism_multiplier)
	_maybe_drink(world)
	if apply_survival_checks(world, delta):
		set_ai_state(AgentAIState.DEAD)
		return
	_update_kin_state(world)

	if interaction_timer > 0.0:
		stop_motion(delta)
		return

	# An engaged animal follows its existing target without building every utility context.
	if state in ["seek_prey", "chase", "search_last_seen", "attack", "seek_carcass", "feed_carcass"]:
		set_ai_state(AgentAIState.ENGAGED)
		_ai_controller.sync_engaged_action(self, world.current_tick)
		if _continue_engaged_flow(world, delta):
			return
		clear_decision_cache()
		set_ai_state(AgentAIState.ALIVE)
	var should_decide: bool = world.should_run_decision_tick(self)
	var snapshot = cached_snapshot
	var context = cached_context
	if should_decide or snapshot == null or context == null:
		var context_started_at_usec := Time.get_ticks_usec()
		snapshot = world.build_predator_snapshot(self)
		context = _ai_controller.build_context(self, world, snapshot)
		world.record_ai_context_ms(float(Time.get_ticks_usec() - context_started_at_usec) / 1000.0)
		var next_ai_state: StringName = _ai_controller.resolve_state(self, context)
		set_ai_state(next_ai_state)
	else:
		set_ai_state(_ai_controller.resolve_state(self, context))

	if ai_state == AgentAIState.ENGAGED:
		_ai_controller.sync_engaged_action(self, world.current_tick)
		if _continue_engaged_flow(world, delta):
			return
		set_ai_state(AgentAIState.ALIVE)
		var rebuild_started_at_usec := Time.get_ticks_usec()
		snapshot = world.build_predator_snapshot(self)
		context = _ai_controller.build_context(self, world, snapshot)
		world.record_ai_context_ms(float(Time.get_ticks_usec() - rebuild_started_at_usec) / 1000.0)

	var scoped_context = context.with_state(ai_state)
	_ai_controller.update_action_target_tracking(self, scoped_context)
	cache_decision_state(snapshot, scoped_context, world.current_tick)
	if can_reproduce() and _attempt_reproduce(world, delta):
		set_ai_state(AgentAIState.ENGAGED)
		force_current_action(AgentAction.REPRODUCE, "reproduction override", world.current_tick)
		return

	if should_decide or current_action == AgentAction.NONE:
		var selection_started_at_usec := Time.get_ticks_usec()
		var decision = _ai_controller.select_action(self, scoped_context, world.current_tick)
		world.record_action_select_ms(float(Time.get_ticks_usec() - selection_started_at_usec) / 1000.0)
		apply_action_decision(decision, world.current_tick)

	_execute_selected_action(world, delta, current_action, snapshot)


func clear_targets(world = null) -> void:
	if world != null:
		release_carcass_target(world)
	else:
		target_carcass_id = -1
	_reset_search_state()
	super.clear_targets()


func export_runtime_state() -> Dictionary:
	var state_data: Dictionary = super.export_runtime_state()
	state_data["last_seen_prey_position"] = last_seen_prey_position
	state_data["prey_last_seen_time"] = prey_last_seen_time
	state_data["search_anchor"] = search_anchor
	state_data["search_started_time"] = search_started_time
	state_data["search_waypoint_index"] = search_waypoint_index
	state_data["search_last_confirmed_position"] = search_last_confirmed_position
	state_data["abandoned_prey_id"] = abandoned_prey_id
	state_data["retry_after"] = retry_after
	state_data["preferred_mate_id"] = preferred_mate_id
	return state_data


## The water-investigation cooldown is a real twelve-second timer, and it is the
## one predator field that sector sleep loses on purpose but a save must not.
func export_save_state() -> Dictionary:
	var state_data: Dictionary = super.export_save_state()
	state_data["last_water_memory_tick"] = _last_water_memory_tick
	return state_data


func apply_save_state(state_data: Dictionary) -> void:
	super.apply_save_state(state_data)
	_last_water_memory_tick = int(state_data.get("last_water_memory_tick", _last_water_memory_tick))


func apply_runtime_state(state_data: Dictionary) -> void:
	super.apply_runtime_state(state_data)
	last_seen_prey_position = state_data.get("last_seen_prey_position", position)
	prey_last_seen_time = float(state_data.get("prey_last_seen_time", -1.0))
	search_anchor = state_data.get("search_anchor", position)
	search_started_time = float(state_data.get("search_started_time", -1.0))
	search_waypoint_index = int(state_data.get("search_waypoint_index", -1))
	search_last_confirmed_position = state_data.get(
		"search_last_confirmed_position", last_seen_prey_position)
	abandoned_prey_id = int(state_data.get("abandoned_prey_id", -1))
	retry_after = float(state_data.get("retry_after", -1.0))
	preferred_mate_id = int(state_data.get("preferred_mate_id", preferred_mate_id))


func _get_debug_target_text() -> String:
	if target_carcass_id != -1:
		return "carcass:%d" % target_carcass_id
	return super._get_debug_target_text()


func _continue_or_finish_chase(world, delta: float) -> bool:
	if state not in ["seek_prey", "chase", "search_last_seen", "attack"]:
		return false
	if not is_hungry_enough_to_feed(can_continue_feeding()):
		clear_targets(world)
		return false
	if target_agent_id == -1:
		return false

	var prey: AgentBase = world.get_agent(target_agent_id)
	if prey == null or not prey.is_alive or not world.species_registry.prey_set(species_type).has(prey.species_type):
		clear_targets(world)
		return false

	var break_radius: float = float(perception.get("chase_break_radius", 260.0))
	var max_chase_duration: float = float(balance.get("hunt_rules", {}).get("max_chase_duration", 9.0))
	var kin_break_radius: float = float(balance.get("hunt_rules", {}).get("kin_chase_break_radius", 220.0))
	var critical_hunger_multiplier: float = float(balance.get("hunt_rules", {}).get("critical_hunger_kin_break_multiplier", 1.75))
	var attack_radius: float = float(perception.get("attack_radius", 18.0))
	var min_chase_energy: float = float(hunt.get("min_chase_energy", 4.0))
	var critical_hunger: float = float(balance.get("state_thresholds", {}).get("critical_hunger", 65.0))
	var visible: bool = world.can_see(self, prey, world.perception_radius(self, "vision_radius", 480.0))
	if visible:
		if search_started_time >= 0.0:
			world.emit_event("PreyReacquired", self, prey.id, {
				"search_time": maxf(0.0, world.current_time - search_started_time),
			})
		_reset_search_state()
		last_seen_prey_position = prey.position
		search_last_confirmed_position = prey.position
		prey_last_seen_time = world.current_time
	elif search_started_time < 0.0:
		_begin_last_seen_search(world, prey.id)
	var distance_sq: float = position.distance_squared_to(last_seen_prey_position)
	var distance: float = sqrt(distance_sq)
	var fail_reason := ""
	if not visible and world.current_time - prey_last_seen_time > float(hunt.get("lost_sight_search_seconds", 3.0)):
		fail_reason = "lost_sight"
	elif distance > break_radius:
		fail_reason = "out_of_range"
	elif chase_timer >= max_chase_duration:
		fail_reason = "timeout"
	elif energy <= min_chase_energy and distance > attack_radius * 1.5:
		fail_reason = "low_energy"
	elif last_known_kin_center != null and not is_hungry_enough_to_feed(true):
		# The leash only applies to a predator that does not need the meal. Every predator
		# carries a kin centre from the initial pairing, so applying it while hungry made the
		# mate's position abort chases outright - it was one of the largest single causes of
		# lost hunts. Feeding first, reuniting after, matches the evaluator veto.
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
		if fail_reason == "lost_sight":
			world.emit_event("PreySearchExpired", self, prey.id, {
				"search_time": maxf(0.0, world.current_time - search_started_time),
				"waypoints_visited": maxi(0, search_waypoint_index),
			})
		abandoned_prey_id = prey.id
		retry_after = world.current_time + float(hunt.get("retry_cooldown_seconds", 2.0))
		world.emit_event("PredationFailed", self, prey.id, failure_data)
		clear_targets(world)
		return false

	chase_timer += delta
	spend_energy(float(metabolism.get("chase_energy_cost", 5.0)) * delta)
	target_position = last_seen_prey_position if visible else _last_seen_search_target(world)
	if visible and distance <= minf(attack_radius, get_body_radius() + prey.get_body_radius() + float(hunt.get("contact_slack", 5.0))) and world.scenery.segment_clear(position, prey.position, 0.0):
		return _attack(world, prey, delta)

	set_state("chase" if visible else "search_last_seen", world.current_tick)
	var chase_waypoint: Vector2 = world.get_next_waypoint(position, target_position, id)
	move_with_vector(world, Steering.seek(position, chase_waypoint), float(movement.get("sprint_speed", 128.0)), delta)
	return true


func _hunt(world, delta: float, prey = null) -> bool:
	if not is_hungry_enough_to_feed(can_continue_feeding()):
		clear_targets(world)
		return false
	if prey == null:
		prey = _choose_prey(world)
	if prey == null or not world.can_see(self, prey, world.perception_radius(self, "vision_radius", 480.0)):
		return false
	release_carcass_target(world)
	# A new target gets a fresh clock. Carrying the previous chase's elapsed time over
	# is what made a freshly acquired prey abort as a timeout on the first tick.
	var switched_target: bool = target_agent_id != prey.id
	if switched_target:
		world.emit_event("HuntStarted", self, prey.id)
		_reset_search_state()
	last_seen_prey_position = prey.position
	search_last_confirmed_position = prey.position
	prey_last_seen_time = world.current_time
	target_agent_id = prey.id
	target_position = prey.position
	set_state("seek_prey", world.current_tick)
	var prey_waypoint: Vector2 = world.get_next_waypoint(position, prey.position, id)
	move_with_vector(world, Steering.seek(position, prey_waypoint), float(movement.get("max_speed", 84.0)), delta)
	chase_timer = delta if switched_target else maxf(chase_timer, delta)
	return true


func _begin_last_seen_search(world, prey_id: int) -> void:
	search_anchor = last_seen_prey_position
	search_last_confirmed_position = last_seen_prey_position
	search_started_time = world.current_time
	search_waypoint_index = -1
	clear_navigation()
	world.emit_event("PreySearchStarted", self, prey_id, {
		"anchor": search_anchor,
	})


func _last_seen_search_target(world) -> Vector2:
	var arrival := get_body_radius() + 8.0
	var current_target := search_anchor if search_waypoint_index < 0 else _search_waypoint(world, search_waypoint_index)
	if position.distance_squared_to(current_target) > arrival * arrival:
		return current_target
	while search_waypoint_index < 3:
		search_waypoint_index += 1
		var candidate := _search_waypoint(world, search_waypoint_index)
		if _search_waypoint_reachable(world, candidate):
			clear_navigation()
			return candidate
	return current_target


func _search_waypoint(world, waypoint_index: int) -> Vector2:
	var radius: float = float(world.terrain_system.cell_size) * float(hunt.get("search_radius_cells", 0.75))
	var initial_angle: float = TAU * float(posmod(id * 1103515245 + 12345, 4096)) / 4096.0
	var raw: Vector2 = search_anchor + Vector2.from_angle(initial_angle + float(waypoint_index) * PI * 0.5) * radius
	return world.get_nearest_walkable_position(world.clamp_position(raw))


func _search_waypoint_reachable(world, candidate: Vector2) -> bool:
	var body_radius := get_body_radius()
	if not world.bounds.grow(-body_radius).has_point(candidate) \
			or not world.scenery.segment_clear(candidate, candidate, body_radius):
		return false
	if world.scenery.segment_clear(position, candidate, body_radius):
		return true
	var route: PackedVector2Array = world.scenery.local_path(position, candidate, body_radius)
	if route.is_empty() or route[-1].distance_to(candidate) > body_radius + 8.0:
		return false
	local_path = route
	local_path_goal = candidate
	return true


func _reset_search_state() -> void:
	search_anchor = Vector2.ZERO
	search_started_time = -1.0
	search_waypoint_index = -1
	search_last_confirmed_position = Vector2.ZERO


func _attack(world, prey, delta: float) -> bool:
	var contact := minf(float(perception.get("attack_radius", 60.0)), get_body_radius() + prey.get_body_radius() + float(hunt.get("contact_slack", 5.0)))
	if position.distance_to(prey.position) > contact or not world.scenery.segment_clear(position, prey.position, 0.0):
		return false
	if attack_cooldown > 0.0:
		# Standing still here handed the prey a free second: it sprints away at
		# `sprint_speed`, and closing that gap again at the ~16 units/s net closure
		# rate ate most of `max_chase_duration`, leaving one attack roll per chase.
		set_state("attack", world.current_tick)
		move_with_vector(world, Steering.seek(position, prey.position), float(movement.get("sprint_speed", 128.0)), delta)
		return true

	world.emit_event("AttackAttempt", self, prey.id)
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
			"chase_time": chase_timer,
		})
		world.kill_agent(prey, "predation", id)
		var carcass: Dictionary = world.find_carcass_by_source_agent(prey.id)
		target_agent_id = -1
		_reset_search_state()
		# `clear_targets()` is the only other thing that zeroes this, and the kill path
		# does not go through it. Leaving it set made `_hunt`'s `maxf` carry the spent
		# time into the next chase, which then aborted immediately as a timeout.
		chase_timer = 0.0
		if not carcass.is_empty():
			target_carcass_id = int(carcass.get("id", -1))
			target_position = carcass["position"]
			_consume_kill_bite(world)
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


## `feeding.food_restore` is the size of the first bite taken at the kill site. It is
## debited through `consume_carcass()`, the single meat ledger, so it cannot conjure
## nutrition that no carcass paid for - the key used to be read by nothing at all.
func _consume_kill_bite(world) -> void:
	var bite: float = float(feeding.get("food_restore", 0.0))
	if bite <= 0.0 or target_carcass_id == -1:
		return
	var consumed: float = world.consume_carcass(target_carcass_id, bite, id)
	if consumed <= 0.0:
		return
	reduce_hunger(consumed * float(feeding.get("carcass_nutrition_gain", 1.0)))
	restore_energy(consumed * float(feeding.get("carcass_energy_gain", 0.5)))


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
	if not world.has_reproductive_capacity(species_type):
		return false
	var chosen_mate: AgentBase = _find_viable_mate(world, true)
	if chosen_mate == null:
		return false

	release_carcass_target(world)
	_set_mutual_preferred_mate(chosen_mate)
	target_agent_id = chosen_mate.id
	target_position = chosen_mate.position
	var contact_distance: float = mate_contact_distance(chosen_mate)
	if position.distance_squared_to(chosen_mate.position) > contact_distance * contact_distance:
		set_state("reproduce", world.current_tick)
		var mate_waypoint: Vector2 = world.get_next_waypoint(position, chosen_mate.position, id)
		move_with_vector(world, Steering.seek(position, mate_waypoint), float(movement.get("max_speed", 84.0)), delta)
		return true

	if id > chosen_mate.id:
		stop_motion(delta)
		return true
	if world.reserve_reproductive_capacity(species_type, 1) <= 0:
		return false

	var center: Vector2 = position.lerp(chosen_mate.position, 0.5)
	var child_position: Vector2 = world.clamp_position(center + world.random_unit_vector() * float(reproduction.get("offspring_spawn_radius", 20.0)))
	world.queue_spawn_agent(species_type, child_position, -1, self, chosen_mate)

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
	if (state in ["seek_carcass", "feed_carcass"] or target_carcass_id != -1) and scavenge_or_feed(world, delta):
		return true
	if state == "investigate_water" and _investigate_recent_water(world, delta):
		return true
	return false


func _execute_selected_action(world, delta: float, action_name: StringName, snapshot = null) -> void:
	match action_name:
		AgentAction.HUNT_PREY:
			if not is_hungry_enough_to_feed(can_continue_feeding()):
				_patrol(world, delta)
				return
			var prey = null if snapshot == null else snapshot.prey_target
			if not _hunt(world, delta, prey):
				_patrol(world, delta)
		AgentAction.SCAVENGE_CARCASS:
			if not is_hungry_enough_to_feed(can_continue_feeding()):
				_patrol(world, delta)
				return
			var carcass_target: Dictionary = {} if snapshot == null else snapshot.carcass_target
			if not scavenge_or_feed(world, delta, carcass_target):
				_patrol(world, delta)
		AgentAction.DRINK:
			var water_target: Dictionary = {} if snapshot == null else snapshot.water_target
			if not _seek_or_drink(world, delta, water_target):
				_patrol(world, delta)
		AgentAction.REST:
			_rest(world, delta)
		AgentAction.INVESTIGATE_WATER:
			var investigation_source: Dictionary = {} if snapshot == null else snapshot.investigation_source
			if not _investigate_recent_water(world, delta, investigation_source):
				_patrol(world, delta)
		AgentAction.PAIR_COHESION:
			if not _regroup_with_kin(world, delta):
				_patrol(world, delta)
		AgentAction.PATROL:
			_patrol(world, delta)
		_:
			_patrol(world, delta)


func _patrol(world, delta: float) -> void:
	var entering_patrol: bool = state != "patrol"
	set_state("patrol", world.current_tick)
	# Keep the static patrol route across ticks. Clearing it here forced the same
	# scenery and terrain checks to be rebuilt eighteen times per second.
	if entering_patrol or target_agent_id != -1 or target_carcass_id != -1:
		clear_targets(world)
	_update_water_memory(world)
	var patrol_goal: Variant = _resolve_patrol_goal(world)
	if patrol_goal != null:
		var patrol_waypoint: Vector2 = world.get_next_waypoint(position, patrol_goal, id)
		move_with_vector(world, Steering.seek(position, patrol_waypoint), float(movement.get("max_speed", 84.0)), delta)
		return
	# Nothing anywhere in range holds prey, so fall back to covering ground. The jitter
	# is far smaller than the herding one for the reason documented on `Steering.wander`.
	var jitter := float(movement.get("patrol_wander_jitter", 0.06))
	move_with_vector(world, Steering.wander(self, world.rng, jitter), float(movement.get("max_speed", 84.0)) * 0.85, delta)
	if stuck_timer > 0.0:
		# A low-jitter walker grinds along terrain it cannot enter. Turn it around
		# rather than letting it sit against the obstacle for its whole patrol.
		wander_angle += PI + world.rng.randf_range(-0.4, 0.4)


## Where to patrol towards: the nearest sector that actually holds herbivores.
##
## Patrol used to be an undirected random walk. With prey clumped into a dozen herds
## roughly 3100 units apart on the large map and vision reaching 480, a predator that
## lost sight of prey diffused rather than travelled and could not cross the gap inside
## its ~62 s hunger budget - which is why prey abundance never translated into meals.
## The sector census this reads already existed for the dormant path.
##
## The radius is what the hunger clock can still pay for, so a fed predator ranges wide
## to pre-position while a starving one stays with what it can still reach.
func _resolve_patrol_goal(world) -> Variant:
	var refresh_ticks: int = maxi(1, int(balance.get("hunt_rules", {}).get("patrol_goal_refresh_ticks", 27)))
	if world.current_tick - _patrol_goal_tick < refresh_ticks:
		return _patrol_goal
	_patrol_goal_tick = world.current_tick
	_patrol_goal = null
	var starvation_threshold := float(balance.get("lifecycle", {}).get("starvation_death_threshold", need_max))
	var hunger_headroom := maxf(1.0, starvation_threshold - hunger) / maxf(0.01, float(metabolism.get("hunger_rate", 1.6)))
	var reach := maxf(hunger_headroom * float(movement.get("max_speed", 84.0)) * 0.6, float(perception.get("vision_radius", 240.0)) * 2.0)
	var goal: Dictionary = world.find_prey_pressure_goal(position, reach)
	if goal.is_empty():
		# Nothing inside the hunger budget, so aim at the best prey concentration
		# on the map regardless of whether the clock can pay for it. Letting the
		# budget gate the search meant that past roughly hunger 65 no herd on the
		# large map was still "affordable", this returned nothing, and patrol
		# degraded to an undirected wander for the last half minute of the
		# animal's life - the one stretch where walking the wrong way is fatal.
		# A directed walk that may not arrive still beats a random one that
		# certainly will not.
		goal = world.find_prey_pressure_goal(position, INF)
	if goal.is_empty():
		return null
	# The goal is a sector centre, and a sector is far wider than vision. Standing on the
	# centre while seeing nothing means the herd is elsewhere in the sector, so sweep it
	# instead of milling on the spot - `_patrol`'s low-jitter wander covers ground.
	var goal_position: Vector2 = goal["goal_position"]
	if position.distance_to(goal_position) <= float(perception.get("vision_radius", 240.0)):
		return null
	_patrol_goal = goal_position
	return _patrol_goal


func _maybe_drink(world) -> void:
	var nearby_water: Dictionary = Perception.find_nearest_water(world, position, 32.0)
	if nearby_water.is_empty():
		return
	_remember_water_source(world, nearby_water)
	var drink_distance := float(feeding.get("drink_distance", 28.0)) + float(nearby_water.get("radius", 0.0))
	if position.distance_squared_to(nearby_water["position"]) > drink_distance * drink_distance:
		return
	if not is_drinking_allowed():
		return
	var drink_restore: float = float(feeding.get("drink_restore", 14.0))
	reduce_thirst(drink_restore)
	clear_navigation()
	world.emit_event("WaterConsumed", self, -1, {
		"source_position": nearby_water["position"],
		"restored": drink_restore,
	})


func _choose_prey(world, prey_candidates: Array = []) -> AgentBase:
	# One radius for both the query and the `distance_score` normalizer below.
	# Scaling only one of them would make edge-of-range prey score zero.
	var vision_radius: float = world.perception_radius(self, "vision_radius", 240.0)
	if prey_candidates.is_empty():
		prey_candidates = world.query_agents_multi(position, vision_radius, world.species_registry.prey_set(species_type), id)
	if prey_candidates.is_empty():
		return null

	var weights: Dictionary = balance.get("hunt_weights", {})
	# Scoring a candidate costs a neighbourhood count for its isolation term, so
	# the work here is predators x visible prey - the fastest-growing cost in the
	# tick once herds get dense. Only the nearest few are worth ranking: distance
	# is a scored term itself, so far-off prey rarely won anyway.
	var evaluation_limit: int = maxi(1, int(perception.get("prey_evaluation_limit", 10)))
	if prey_candidates.size() > evaluation_limit:
		var by_distance: Array = prey_candidates.duplicate()
		var origin: Vector2 = position
		by_distance.sort_custom(func(a, b):
			return origin.distance_squared_to(a.position) < origin.distance_squared_to(b.position))
		prey_candidates = by_distance.slice(0, evaluation_limit)
	var best_score: float = -INF
	var best_prey: AgentBase = null
	for prey in prey_candidates:
		if (prey.id == abandoned_prey_id and world.current_time < retry_after) or not world.can_see(self, prey, vision_radius):
			continue
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
			_cached_isolation_prey_id = prey.id
			_cached_prey_isolation = isolation
	return best_prey


## Scored once per prey candidate per predator per tick, and a predator sees far
## with a 480 vision radius, so this is the most-called query in the sim. Only
## the count matters, so it goes through `count_agents()` and never builds the
## neighbour array.
## How exposed a prey animal is, as 1.0 for a lone straggler down to 0.0 deep inside a
## herd. The radius used to be a hardcoded 72 against a divisor of 6, but herds hold
## `separation_radius` 84 with ~20 members, so six neighbours were always inside 72 and
## this returned a flat 0 for every animal in the world - which silently killed both
## `attack.prey_isolation_bonus` and `hunt_weights.isolation`. Measuring just outside
## the herd's own spacing, against a divisor near a real herd size, makes it discriminate
## between the edge of a herd and its centre again.
func _prey_isolation(world, prey) -> float:
	var isolation_config: Dictionary = balance.get("prey_isolation", {})
	var radius: float = float(isolation_config.get("neighbor_radius", 126.0))
	var reference_count: float = maxf(1.0, float(isolation_config.get("reference_neighbor_count", 10.0)))
	# Its own species, not "herbivore": how hidden an animal is depends on the herd it
	# is standing in, and a second prey species does not hide the first.
	var neighbor_count: int = world.count_agents(prey.position, radius, prey.species_type, prey.id)
	return clampf(1.0 - (float(neighbor_count) / reference_count), 0.0, 1.0)


## `_choose_prey` already scored isolation for every candidate, including the winner.
## Context building asks for the winner's score again, so reuse it rather than paying
## for a second spatial query over the same neighbourhood in the same tick.
func get_prey_isolation(world, prey) -> float:
	if prey != null and prey.id == _cached_isolation_prey_id:
		return _cached_prey_isolation
	return _prey_isolation(world, prey)


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
	var move_vector := Steering.combine_two(
		Steering.seek(position, mate_waypoint), float(reproduction.get("preferred_mate_seek_weight", 0.75)),
		Steering.wander(self, world.rng), 0.45)
	move_with_vector(world, move_vector, float(movement.get("max_speed", 84.0)) * 0.8, delta)
	return true


func _find_viable_mate(world, require_reproduction_ready: bool, mates: Array = []) -> AgentBase:
	var preferred_mate: AgentBase = _get_preferred_mate(world)
	if _is_valid_mate_candidate(preferred_mate, require_reproduction_ready):
		return preferred_mate

	if mates.is_empty():
		mates = Perception.get_nearby_agents(
			world,
			position,
			float(perception.get("mate_search_radius", 80.0)),
			species_type,
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
	if mate == null or not mate.is_alive or mate.species_type != species_type or mate.sex == sex:
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
	if candidate.id == id or candidate.species_type != species_type or candidate.sex == sex:
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


## Throttled: this runs on every patrol tick and each call ends in a vision-radius
## spatial query over the water source. Water sources do not move and herbivores do not
## arrive within a single tick, so refreshing a few times per second is enough.
const WATER_MEMORY_REFRESH_TICKS := 9


func _update_water_memory(world) -> void:
	# Phase by id so predators refresh on different ticks instead of spiking together.
	if (world.current_tick + id) % WATER_MEMORY_REFRESH_TICKS != 0:
		return
	_last_water_memory_tick = world.current_tick
	var visible_water: Dictionary = Perception.find_nearest_water(
		world,
		position,
		float(perception.get("water_search_radius", perception.get("vision_radius", 240.0)))
	)
	if not visible_water.is_empty():
		_remember_water_source(world, visible_water)


## Which flows count as "already at a meal", for the gorging rule in
## `AgentBase.is_hungry_enough_to_feed()`. A hunt counts: a predator committed to a
## chase should not be talked out of it by the hunger it is about to satisfy.
func can_continue_feeding() -> bool:
	return current_action in [AgentAction.HUNT_PREY, AgentAction.SCAVENGE_CARCASS] or state in ["seek_prey", "chase", "attack", "seek_carcass", "feed_carcass"]


func _investigate_recent_water(world, delta: float, source: Dictionary = {}) -> bool:
	if source.is_empty():
		source = _get_recent_investigation_water_source(world)
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
	if scavenge_or_feed(world, delta):
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
	var herbivores: Array = world.query_agents_multi(
		source_position,
		world.perception_radius(self, "vision_radius", 240.0),
		world.species_registry.prey_set(species_type),
		-1
	)
	return not herbivores.is_empty()


func _update_kin_state(world) -> void:
	var live_kin: Array = []
	var kin_center := Vector2.ZERO
	for kin_id in kin_ids:
		var kin_agent: AgentBase = world.get_agent(int(kin_id))
		if kin_agent == null or not kin_agent.is_alive or kin_agent.species_type != species_type:
			continue
		live_kin.append(kin_agent.id)
		kin_center += kin_agent.position
	kin_ids = live_kin
	if kin_ids.is_empty():
		last_known_kin_center = null
		return
	last_known_kin_center = kin_center / float(kin_ids.size())
