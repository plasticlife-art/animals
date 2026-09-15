class_name ScavengerAI
extends "res://scripts/agents/ai/herbivore_ai.gd"

## A herd animal whose food is carrion.
##
## Everything that is not "where is my next meal" is inherited: flocking,
## drinking, resting, exploring, and the panic state - live, because the predator
## lists this species in its `role.eats_species`. Only the food source, the
## action that pursues it and the values that score it live here.
##
## The evaluators are the existing ones. `scavenge_carcass` was written for the
## predator and reads nothing predator-specific - `hunger`, `carcass_proximity`,
## `carcass_meat`, `prey_scarcity` - so it is reused rather than copied, and both
## species tune it from their own `balance.json -> ai.<species>.evaluators` block.

const ScavengeCarcassUtilityEvaluatorScript := preload("res://scripts/agents/ai/evaluators/scavenge_carcass_utility_evaluator.gd")


func _config_key() -> String:
	return "scavenger"


func _alive_actions() -> Array:
	return [
		AgentAction.SCAVENGE_CARCASS,
		AgentAction.DRINK,
		AgentAction.REST,
		AgentAction.EXPLORE,
		AgentAction.JOIN_HERD,
	]


func _build_evaluators(evaluator_config: Dictionary) -> Dictionary:
	var built: Dictionary = super._build_evaluators(evaluator_config)
	built.erase(AgentAction.GRAZE)
	built[AgentAction.SCAVENGE_CARCASS] = ScavengeCarcassUtilityEvaluatorScript.new(
		evaluator_config.get("scavenge_carcass", {}))
	return built


## A carcass rather than a grass patch. `quality` is the share of the body still
## on it, which is what keeps a flock from all converging on a picked-over one.
func _food_values(agent, _world, snapshot) -> Dictionary:
	var carcass: Dictionary = snapshot.carcass_target
	if carcass.is_empty():
		return {"proximity": 0.0, "quality": 0.0, "target": {}}
	var search_radius := float(agent.balance.get("carcass", {}).get("search_radius", 420.0))
	var meat_total := maxf(1.0, float(agent.balance.get("carcass", {}).get("meat_total", 100.0)))
	return {
		"proximity": UtilityContextFactory.proximity_ratio(
			agent.position.distance_to(carcass["position"]), search_radius),
		"quality": clampf(float(carcass.get("meat_remaining", 0.0)) / meat_total, 0.0, 1.0),
		"target": carcass,
	}


## The gorging rule from `AgentBase`, the same one the execution path applies, so
## the selector cannot walk a scavenger off a body it is still gaining energy from.
func _feeding_allowed(agent) -> bool:
	return agent.is_feeding_allowed()


func _augment_context(context, _agent, _world, snapshot) -> void:
	var carcass: Dictionary = snapshot.carcass_target
	var proximity := float(context.get_value("food_proximity", 0.0))
	var meat := float(context.get_value("food_biomass", 0.0))
	context.values["carcass_proximity"] = proximity
	context.values["carcass_meat"] = meat
	# The evaluator's `prey_scarcity` term means "nothing better on offer". For a
	# species that never hunts, the only alternative to this carcass is another one,
	# so scarcity is simply how poorly the current find scores.
	context.values["prey_scarcity"] = clampf(1.0 - maxf(proximity, meat), 0.0, 1.0)
	context.targets[AgentAction.SCAVENGE_CARCASS] = carcass


func _action_requires_target(action_name: StringName) -> bool:
	if action_name == AgentAction.SCAVENGE_CARCASS:
		return true
	return super._action_requires_target(action_name)
