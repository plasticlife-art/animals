class_name HerbivoreAI
extends RefCounted

const AgentAIState := preload("res://scripts/agents/ai/agent_ai_state.gd")
const AgentAction := preload("res://scripts/agents/ai/agent_action.gd")
const ActionSelectorScript := preload("res://scripts/agents/ai/action_selector.gd")
const StatePolicyScript := preload("res://scripts/agents/ai/state_policy.gd")
const UtilityContextScript := preload("res://scripts/agents/ai/utility_context.gd")
const UtilityContextFactory := preload("res://scripts/agents/ai/utility_context_factory.gd")
const Perception := preload("res://scripts/agents/perception.gd")
const GrazeUtilityEvaluatorScript := preload("res://scripts/agents/ai/evaluators/graze_utility_evaluator.gd")
const DrinkUtilityEvaluatorScript := preload("res://scripts/agents/ai/evaluators/drink_utility_evaluator.gd")
const RestUtilityEvaluatorScript := preload("res://scripts/agents/ai/evaluators/rest_utility_evaluator.gd")
const ExploreUtilityEvaluatorScript := preload("res://scripts/agents/ai/evaluators/explore_utility_evaluator.gd")
const JoinHerdUtilityEvaluatorScript := preload("res://scripts/agents/ai/evaluators/join_herd_utility_evaluator.gd")
const FleeUtilityEvaluatorScript := preload("res://scripts/agents/ai/evaluators/flee_utility_evaluator.gd")

var selector
var policies: Dictionary = {}
var evaluators: Dictionary = {}
var panic_threat_threshold: float = 0.55
var target_invalid_interrupt_ticks: int = 2


func _init(balance_config: Dictionary = {}) -> void:
	var ai_config: Dictionary = balance_config.get("ai", {})
	var selector_config: Dictionary = ai_config.get("selector", {})
	var species_config: Dictionary = ai_config.get(_config_key(), {})
	var evaluator_config: Dictionary = species_config.get("evaluators", {})
	selector = ActionSelectorScript.new(selector_config)
	panic_threat_threshold = float(species_config.get("panic_threat_threshold", 0.55))
	target_invalid_interrupt_ticks = maxi(1, int(selector_config.get("target_invalid_interrupt_ticks", 2)))
	policies = {
		AgentAIState.ALIVE: _build_policy(AgentAIState.ALIVE, _alive_actions()),
		AgentAIState.PANIC: _build_policy(AgentAIState.PANIC, [
			AgentAction.FLEE_TO_SAFE_AREA,
			AgentAction.JOIN_HERD,
		]),
		AgentAIState.DEAD: _build_policy(AgentAIState.DEAD, []),
	}
	evaluators = _build_evaluators(evaluator_config)


## --- Seams for herd behaviours that are not grazers -------------------------
##
## Everything a herd animal does apart from finding food is shared: fleeing,
## drinking, resting, regrouping, exploring, and the whole panic state. A
## subclass swaps its food source through these rather than restating the rest.


## Which `balance.json -> ai.<key>` block tunes this behaviour.
func _config_key() -> String:
	return "herbivore"


func _alive_actions() -> Array:
	return [
		AgentAction.GRAZE,
		AgentAction.DRINK,
		AgentAction.REST,
		AgentAction.EXPLORE,
		AgentAction.JOIN_HERD,
	]


func _build_evaluators(evaluator_config: Dictionary) -> Dictionary:
	return {
		AgentAction.GRAZE: GrazeUtilityEvaluatorScript.new(evaluator_config.get("graze", {})),
		AgentAction.DRINK: DrinkUtilityEvaluatorScript.new(evaluator_config.get("drink", {})),
		AgentAction.REST: RestUtilityEvaluatorScript.new(evaluator_config.get("rest", {})),
		AgentAction.EXPLORE: ExploreUtilityEvaluatorScript.new(evaluator_config.get("explore", {})),
		AgentAction.JOIN_HERD: JoinHerdUtilityEvaluatorScript.new(evaluator_config.get("join_herd", {})),
		AgentAction.FLEE_TO_SAFE_AREA: FleeUtilityEvaluatorScript.new(evaluator_config.get("flee_to_safe_area", {})),
	}


## This behaviour's food, normalized. `proximity` and `quality` are 0..1 and feed
## the shared `resource_scarcity` term; `target` is what the feeding action aims at.
func _food_values(agent, world, snapshot) -> Dictionary:
	var grass: Dictionary = snapshot.grass_target
	if grass.is_empty():
		return {"proximity": 0.0, "quality": 0.0, "target": {}}
	# Normalized against the configured cap, not a literal 100. The cap scales
	# with cell area, so a hardcoded divisor silently saturates on a coarse
	# grid and reports every patch as equally rich.
	var biomass_cap := 100.0
	if world.resource_system != null:
		biomass_cap = maxf(1.0, world.resource_system.max_biomass)
	return {
		"proximity": UtilityContextFactory.proximity_ratio(
			agent.position.distance_to(grass.get("center", agent.position)),
			float(agent.perception.get("grass_search_radius", 180.0))),
		"quality": clampf(float(grass.get("biomass", 0.0)) / biomass_cap, 0.0, 1.0),
		"target": grass,
	}


## Whether the feeding action is allowed at all, before any scoring.
func _feeding_allowed(agent) -> bool:
	var floor_value: float = agent.get_graze_hunger_floor() if agent.has_method("get_graze_hunger_floor") else float(agent.balance.get("state_thresholds", {}).get("graze_hunger_floor", 20.0))
	return agent.hunger >= floor_value


## Last word on the context, for values and targets only this behaviour needs.
func _augment_context(_context, _agent, _world, _snapshot) -> void:
	pass


func build_context(agent, world, snapshot = null):
	if snapshot == null:
		snapshot = agent._build_snapshot(world)
	var neighbors: Array = snapshot.group_neighbors
	# Scaled in step with the snapshot query in `build_herbivore_snapshot`: if the
	# search shrinks at night and this normalizer does not, every predator found
	# divides down to "right on top of me".
	var danger_radius: float = world.perception_radius(agent, "danger_radius", 120.0)
	var predators: Array = snapshot.predators
	var water_target: Dictionary = snapshot.water_target
	var group_center = snapshot.group_center
	var biome_id: String = str(world.get_biome_at_position(agent.position))
	var max_energy := float(agent.metabolism.get("max_energy", 100.0))
	var hunger := UtilityContextFactory.need_ratio(agent.hunger, agent.need_max)
	var thirst := UtilityContextFactory.need_ratio(agent.thirst, agent.need_max)
	var energy_ratio := UtilityContextFactory.energy_ratio(agent.energy, max_energy)
	var fatigue := UtilityContextFactory.fatigue_ratio(agent.energy, max_energy)

	var threat := 0.0
	var flee_vector := Vector2.ZERO
	var predator_visible := not predators.is_empty()
	var water_threat := 0.0
	for predator in predators:
		var distance: float = agent.position.distance_to(predator.position)
		threat = maxf(threat, UtilityContextFactory.proximity_ratio(distance, danger_radius))
		flee_vector += agent.position - predator.position
		if not water_target.is_empty():
			water_threat = maxf(
				water_threat,
				UtilityContextFactory.proximity_ratio(predator.position.distance_to(water_target["position"]), danger_radius)
			)
	if predator_visible:
		threat = clampf(threat + clampf(float(predators.size()) / 3.0, 0.0, 1.0) * 0.2, 0.0, 1.0)
	if UtilityContextFactory.is_open_area_biome(biome_id):
		threat = clampf(threat + 0.08, 0.0, 1.0)

	var food: Dictionary = _food_values(agent, world, snapshot)
	var food_proximity := float(food["proximity"])
	var food_biomass := float(food["quality"])

	var water_proximity := 0.0
	if not water_target.is_empty():
		water_proximity = UtilityContextFactory.proximity_ratio(
			agent.position.distance_to(water_target["position"]),
			float(agent.perception.get("water_search_radius", 260.0))
		)

	var herd_available := 0.0
	var herd_proximity := 0.0
	if group_center != null:
		herd_available = 1.0
		var rejoin_distance := float(agent.balance.get("state_thresholds", {}).get("rejoin_distance", 135.0))
		herd_proximity = UtilityContextFactory.proximity_ratio(agent.position.distance_to(group_center), rejoin_distance * 1.5)

	var escape_target := {}
	var safe_zone_proximity := 0.0
	if flee_vector.length_squared() > 0.001:
		var escape_position: Vector2 = agent.get_escape_destination(world, flee_vector.normalized(), 168.0)
		escape_target = {"position": escape_position}
		safe_zone_proximity = UtilityContextFactory.proximity_ratio(agent.position.distance_to(escape_position), 220.0)

	var low_urgency := clampf(1.0 - maxf(hunger, maxf(thirst, fatigue)), 0.0, 1.0)
	var resource_scarcity := clampf(1.0 - maxf(food_proximity * maxf(food_biomass, 0.35), water_proximity), 0.0, 1.0)
	var context = UtilityContextScript.new()
	context.diagnostics = bool(world.config_bundle.get("debug", {}).get("ai_diagnostics", false)) or agent.id == world.inspected_agent_id
	context.species_type = agent.species_type
	context.state_name = AgentAIState.ALIVE
	context.values = {
		"hunger": hunger,
		"thirst": thirst,
		"fatigue": fatigue,
		"energy_ratio": energy_ratio,
		"health_ratio": 1.0,
		"predator_visible_ratio": UtilityContextFactory.bool_ratio(predator_visible),
		"threat": threat,
		"water_threat": clampf(maxf(water_threat, threat * 0.5), 0.0, 1.0),
		"food_proximity": food_proximity,
		"food_biomass": food_biomass,
		"water_proximity": water_proximity,
		"graze_allowed": UtilityContextFactory.bool_ratio(_feeding_allowed(agent)),
		"drinking_allowed": UtilityContextFactory.bool_ratio(agent.is_drinking_allowed()),
		"resting_allowed": UtilityContextFactory.bool_ratio(agent.is_energy_below_rest_floor()),
		"feeding_allowed": UtilityContextFactory.bool_ratio(_feeding_allowed(agent)),
		"herd_proximity": herd_proximity,
		"herd_available": herd_available,
		"isolation": clampf(1.0 - minf(float(neighbors.size()) / 5.0, 1.0), 0.0, 1.0),
		"open_area_ratio": UtilityContextFactory.bool_ratio(UtilityContextFactory.is_open_area_biome(biome_id)),
		"safe_biome_score": UtilityContextFactory.safe_biome_score(biome_id),
		"low_urgency": low_urgency,
		"night_ratio": world.climate.night_ratio,
		"resource_scarcity": resource_scarcity,
		"safe_zone_proximity": safe_zone_proximity,
	}
	context.targets = {
		AgentAction.GRAZE: food["target"],
		AgentAction.DRINK: water_target,
		AgentAction.JOIN_HERD: {} if group_center == null else {"position": group_center},
		AgentAction.FLEE_TO_SAFE_AREA: escape_target,
	}
	_augment_context(context, agent, world, snapshot)
	return context


func resolve_state(agent, context) -> StringName:
	if not agent.is_alive:
		return AgentAIState.DEAD
	if bool(context.get_value("predator_visible_ratio", 0.0) > 0.0):
		return AgentAIState.PANIC
	if float(context.get_value("threat", 0.0)) >= panic_threat_threshold:
		return AgentAIState.PANIC
	return AgentAIState.ALIVE


func get_policy(state_name: StringName):
	return policies.get(state_name, policies[AgentAIState.ALIVE])


func select_action(agent, context, current_tick: int):
	var next_state: StringName = resolve_state(agent, context)
	var scoped_context = context.with_state(next_state)
	var policy = get_policy(next_state)
	var force_interrupt := should_force_interrupt(agent, next_state, scoped_context)
	return selector.select(agent, policy, scoped_context, evaluators, current_tick, force_interrupt)


func should_force_interrupt(agent, next_state: StringName, context) -> bool:
	var policy = get_policy(next_state)
	if next_state == AgentAIState.PANIC and agent.ai_state != AgentAIState.PANIC:
		return true
	if StringName(agent.current_action) == AgentAction.GRAZE and agent.has_method("can_continue_grazing") and not bool(agent.call("can_continue_grazing")):
		return true
	if agent.current_action != &"" and not policy.is_action_allowed(StringName(agent.current_action)):
		return true
	if _action_requires_target(StringName(agent.current_action)) and agent.action_target_failure_ticks >= target_invalid_interrupt_ticks:
		return true
	if _action_requires_target(StringName(agent.current_action)) and not context.has_target(StringName(agent.current_action)) and next_state == AgentAIState.PANIC:
		return true
	return false


func update_action_target_tracking(agent, context) -> void:
	var action_name: StringName = StringName(agent.current_action)
	if not _action_requires_target(action_name):
		agent.action_target_failure_ticks = 0
		return
	if context.has_target(action_name):
		agent.action_target_failure_ticks = 0
	else:
		agent.action_target_failure_ticks += 1


func _action_requires_target(action_name: StringName) -> bool:
	return action_name in [
		AgentAction.GRAZE,
		AgentAction.DRINK,
		AgentAction.JOIN_HERD,
		AgentAction.FLEE_TO_SAFE_AREA,
	]


func _resolve_water_target(agent, world) -> Dictionary:
	var water: Dictionary = Perception.find_nearest_water(
		world,
		agent.position,
		float(agent.perception.get("water_search_radius", 260.0))
	)
	if water.is_empty():
		water = agent.get_remembered_water(
			world.current_time,
			float(agent.perception.get("water_memory_duration_seconds", 0.0))
		)
	if not water.is_empty():
		agent.remember_water(water, world.current_time)
	return water


func _build_policy(state_name: StringName, allowed_actions: Array):
	var policy = StatePolicyScript.new()
	policy.state_name = state_name
	policy.allowed_actions = allowed_actions.duplicate()
	policy.is_locked = false
	return policy
