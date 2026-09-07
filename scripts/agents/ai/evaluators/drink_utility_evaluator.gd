class_name DrinkUtilityEvaluator
extends "res://scripts/agents/ai/utility_evaluator.gd"

const AgentAction := preload("res://scripts/agents/ai/agent_action.gd")


func _init(new_config: Dictionary = {}) -> void:
	super._init(AgentAction.DRINK, new_config)


func evaluate(_agent, context) -> Dictionary:
	var thirst := float(context.get_value("thirst", 0.0))
	var water_proximity := float(context.get_value("water_proximity", 0.0))
	var water_threat := float(context.get_value("water_threat", 0.0))
	var hunger := float(context.get_value("hunger", 0.0))
	var food_proximity := float(context.get_value("food_proximity", 0.0))
	var threat := float(context.get_value("threat", 0.0))
	if float(context.get_value("drinking_allowed", 1.0)) < 0.5:
		return veto((["below thirst floor"] if context.diagnostics else []))
	# Proximity multiplies the need instead of adding to it. As a free addend it
	# rewarded standing near water rather than being thirsty, which is what kept
	# half a herd parked at the lake: `water_proximity` is near 1.0 for anything
	# beside the water, so the term paid out no matter how slaked the animal was.
	var score := thirst * (get_weight("thirst_weight", 0.50)
		+ water_proximity * get_weight("water_weight", 0.30))
	score += (1.0 - water_threat) * get_weight("safety_weight", 0.08)
	score -= water_threat * get_weight("water_threat_penalty", 0.35)
	score -= threat * get_weight("ambient_threat_penalty", 0.12)
	score -= hunger * food_proximity * get_weight("hunger_penalty", 0.08)
	return result(score, ([
		reason_if("thirst", thirst),
		reason_if("water", water_proximity),
		reason_if("risk", water_threat, 0.2),
	] if context.diagnostics else []))
