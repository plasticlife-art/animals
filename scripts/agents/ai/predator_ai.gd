class_name PredatorAI
extends RefCounted

const AgentAIState := preload("res://scripts/agents/ai/agent_ai_state.gd")
const AgentAction := preload("res://scripts/agents/ai/agent_action.gd")
const ActionSelectorScript := preload("res://scripts/agents/ai/action_selector.gd")
const StatePolicyScript := preload("res://scripts/agents/ai/state_policy.gd")
const UtilityContextScript := preload("res://scripts/agents/ai/utility_context.gd")
const UtilityContextFactory := preload("res://scripts/agents/ai/utility_context_factory.gd")
const HuntPreyUtilityEvaluatorScript := preload("res://scripts/agents/ai/evaluators/hunt_prey_utility_evaluator.gd")
const ScavengeCarcassUtilityEvaluatorScript := preload("res://scripts/agents/ai/evaluators/scavenge_carcass_utility_evaluator.gd")
const DrinkUtilityEvaluatorScript := preload("res://scripts/agents/ai/evaluators/drink_utility_evaluator.gd")
const RestUtilityEvaluatorScript := preload("res://scripts/agents/ai/evaluators/rest_utility_evaluator.gd")
const InvestigateWaterUtilityEvaluatorScript := preload("res://scripts/agents/ai/evaluators/investigate_water_utility_evaluator.gd")
const PairCohesionUtilityEvaluatorScript := preload("res://scripts/agents/ai/evaluators/pair_cohesion_utility_evaluator.gd")
const PatrolUtilityEvaluatorScript := preload("res://scripts/agents/ai/evaluators/patrol_utility_evaluator.gd")

const ENGAGED_EXECUTION_STATES := {
	"seek_prey": AgentAction.HUNT_PREY,
	"chase": AgentAction.HUNT_PREY,
	"attack": AgentAction.HUNT_PREY,
	"seek_carcass": AgentAction.SCAVENGE_CARCASS,
	"feed_carcass": AgentAction.SCAVENGE_CARCASS,
	"investigate_water": AgentAction.INVESTIGATE_WATER,
	"reproduce": AgentAction.REPRODUCE,
}

var selector
var policies: Dictionary = {}
var evaluators: Dictionary = {}
var target_invalid_interrupt_ticks: int = 2


func _init(balance_config: Dictionary = {}) -> void:
	var ai_config: Dictionary = balance_config.get("ai", {})
	var selector_config: Dictionary = ai_config.get("selector", {})
	var predator_config: Dictionary = ai_config.get("predator", {})
	var evaluator_config: Dictionary = predator_config.get("evaluators", {})
	selector = ActionSelectorScript.new(selector_config)
	target_invalid_interrupt_ticks = maxi(1, int(selector_config.get("target_invalid_interrupt_ticks", 2)))
	policies = {
		AgentAIState.ALIVE: _build_policy(AgentAIState.ALIVE, [
			AgentAction.HUNT_PREY,
			AgentAction.SCAVENGE_CARCASS,
			AgentAction.DRINK,
			AgentAction.REST,
			AgentAction.INVESTIGATE_WATER,
			AgentAction.PAIR_COHESION,
			AgentAction.PATROL,
		]),
		AgentAIState.ENGAGED: _build_policy(AgentAIState.ENGAGED, [], true),
		AgentAIState.DEAD: _build_policy(AgentAIState.DEAD, []),
	}
	evaluators = {
		AgentAction.HUNT_PREY: HuntPreyUtilityEvaluatorScript.new(evaluator_config.get("hunt_prey", {})),
		AgentAction.SCAVENGE_CARCASS: ScavengeCarcassUtilityEvaluatorScript.new(evaluator_config.get("scavenge_carcass", {})),
		AgentAction.DRINK: DrinkUtilityEvaluatorScript.new(evaluator_config.get("drink", {})),
		AgentAction.REST: RestUtilityEvaluatorScript.new(evaluator_config.get("rest", {})),
		AgentAction.INVESTIGATE_WATER: InvestigateWaterUtilityEvaluatorScript.new(evaluator_config.get("investigate_water", {})),
		AgentAction.PAIR_COHESION: PairCohesionUtilityEvaluatorScript.new(evaluator_config.get("pair_cohesion", {})),
		AgentAction.PATROL: PatrolUtilityEvaluatorScript.new(evaluator_config.get("patrol", {})),
	}


func build_context(agent, world, snapshot = null):
	if snapshot == null:
		snapshot = world.build_predator_snapshot(agent)
	var thresholds: Dictionary = agent.balance.get("state_thresholds", {})
	var water_target: Dictionary = snapshot.water_target
	var prey = snapshot.prey_target
	var carcass: Dictionary = snapshot.carcass_target
	var investigation_source: Dictionary = snapshot.investigation_source
	var mate = snapshot.mate_target
	var max_energy := float(agent.metabolism.get("max_energy", 100.0))
	var hunger := UtilityContextFactory.need_ratio(agent.hunger, agent.need_max)
	var thirst := UtilityContextFactory.need_ratio(agent.thirst, agent.need_max)
	var energy_ratio := UtilityContextFactory.energy_ratio(agent.energy, max_energy)
	var fatigue := UtilityContextFactory.fatigue_ratio(agent.energy, max_energy)
	var hunt_vision := float(agent.perception.get("vision_radius", 240.0))

	var prey_quality := 0.0
	var prey_proximity := 0.0
	var prey_target := {}
	if prey != null:
		prey_target = {"agent_id": prey.id, "position": prey.position}
		prey_quality = clampf(agent._prey_isolation(world, prey) * 0.45 + (1.0 - UtilityContextFactory.energy_ratio(prey.energy, float(prey.metabolism.get("max_energy", 100.0)))) * 0.35 + 0.2, 0.0, 1.0)
		prey_proximity = UtilityContextFactory.proximity_ratio(agent.position.distance_to(prey.position), hunt_vision)

	var carcass_proximity := 0.0
	var carcass_meat := 0.0
	if not carcass.is_empty():
		carcass_proximity = UtilityContextFactory.proximity_ratio(
			agent.position.distance_to(carcass["position"]),
			float(agent.balance.get("carcass", {}).get("search_radius", hunt_vision))
		)
		carcass_meat = clampf(float(carcass.get("meat_remaining", 0.0)) / maxf(1.0, float(agent.balance.get("carcass", {}).get("meat_total", 100.0))), 0.0, 1.0)

	var water_proximity := 0.0
	if not water_target.is_empty():
		water_proximity = UtilityContextFactory.proximity_ratio(
			agent.position.distance_to(water_target["position"]),
			float(agent.perception.get("water_search_radius", hunt_vision))
		)

	var kin_separation := 0.0
	if snapshot.kin_center != null:
		kin_separation = clampf(
			agent.position.distance_to(snapshot.kin_center) / maxf(1.0, float(agent.reproduction.get("preferred_mate_follow_radius", 180.0)) * 1.4),
			0.0,
			1.0
		)

	var investigation_signal := 0.0
	if not investigation_source.is_empty():
		var last_seen := float(investigation_source.get("last_herbivore_seen_time", -1.0))
		var memory_window := maxf(1.0, float(agent.perception.get("water_memory_duration_seconds", 1.0)))
		if last_seen >= 0.0:
			investigation_signal = clampf(1.0 - ((world.current_time - last_seen) / memory_window), 0.0, 1.0)

	var low_urgency := clampf(1.0 - maxf(hunger, maxf(thirst, fatigue)), 0.0, 1.0)
	var no_targets_score := clampf(1.0 - maxf(prey_quality, maxf(carcass_proximity, investigation_signal)), 0.0, 1.0)
	var context = UtilityContextScript.new()
	context.species_type = agent.species_type
	context.state_name = AgentAIState.ALIVE
	context.values = {
		"hunger": hunger,
		"thirst": thirst,
		"fatigue": fatigue,
		"energy_ratio": energy_ratio,
		"health_ratio": 1.0,
		"threat": 0.0,
		"water_threat": 0.0,
		"prey_quality": prey_quality,
		"prey_proximity": prey_proximity,
		"carcass_proximity": carcass_proximity,
		"carcass_meat": carcass_meat,
		"prey_scarcity": clampf(1.0 - maxf(prey_quality, prey_proximity), 0.0, 1.0),
		"water_proximity": water_proximity,
		"investigation_signal": investigation_signal,
		"kin_separation": kin_separation,
		"mate_available": UtilityContextFactory.bool_ratio(mate != null),
		"low_urgency": low_urgency,
		"safe_biome_score": UtilityContextFactory.safe_biome_score(world.get_biome_at_position(agent.position)),
		"no_targets_score": no_targets_score,
	}
	context.targets = {
		AgentAction.HUNT_PREY: prey_target,
		AgentAction.SCAVENGE_CARCASS: carcass,
		AgentAction.DRINK: water_target,
		AgentAction.INVESTIGATE_WATER: investigation_source,
		AgentAction.PAIR_COHESION: {} if snapshot.kin_center == null else {"position": snapshot.kin_center},
	}
	return context


func resolve_state(agent, _context) -> StringName:
	if not agent.is_alive:
		return AgentAIState.DEAD
	if ENGAGED_EXECUTION_STATES.has(agent.state):
		return AgentAIState.ENGAGED
	if agent.target_agent_id != -1 or agent.target_carcass_id != -1:
		return AgentAIState.ENGAGED
	return AgentAIState.ALIVE


func get_policy(state_name: StringName):
	return policies.get(state_name, policies[AgentAIState.ALIVE])


func select_action(agent, context, current_tick: int):
	var next_state: StringName = resolve_state(agent, context)
	var scoped_context = context.with_state(next_state)
	var policy = get_policy(next_state)
	var force_interrupt := should_force_interrupt(agent, next_state)
	return selector.select(agent, policy, scoped_context, evaluators, current_tick, force_interrupt)


func should_force_interrupt(agent, next_state: StringName) -> bool:
	var policy = get_policy(next_state)
	if next_state == AgentAIState.ENGAGED and agent.ai_state != AgentAIState.ENGAGED:
		return true
	if agent.current_action != &"" and not policy.is_action_allowed(StringName(agent.current_action)):
		return true
	if _action_requires_target(StringName(agent.current_action)) and agent.action_target_failure_ticks >= target_invalid_interrupt_ticks:
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


func sync_engaged_action(agent, current_tick: int) -> void:
	var mapped_action: StringName = StringName(ENGAGED_EXECUTION_STATES.get(agent.state, AgentAction.NONE))
	if mapped_action == AgentAction.NONE:
		if agent.target_agent_id != -1:
			mapped_action = AgentAction.HUNT_PREY
		elif agent.target_carcass_id != -1:
			mapped_action = AgentAction.SCAVENGE_CARCASS
	if mapped_action == AgentAction.NONE:
		agent.force_current_action(AgentAction.NONE, "engaged flow idle", current_tick)
		return
	agent.force_current_action(mapped_action, "engaged flow: %s" % agent.state, current_tick)


func _action_requires_target(action_name: StringName) -> bool:
	return action_name in [
		AgentAction.HUNT_PREY,
		AgentAction.SCAVENGE_CARCASS,
		AgentAction.DRINK,
		AgentAction.INVESTIGATE_WATER,
		AgentAction.PAIR_COHESION,
	]


func _build_policy(state_name: StringName, allowed_actions: Array, is_locked: bool = false):
	var policy = StatePolicyScript.new()
	policy.state_name = state_name
	policy.allowed_actions = allowed_actions.duplicate()
	policy.is_locked = is_locked
	return policy
