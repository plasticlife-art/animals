class_name GrazeUtilityEvaluator
extends "res://scripts/agents/ai/utility_evaluator.gd"

const AgentAction := preload("res://scripts/agents/ai/agent_action.gd")


func _init(new_config: Dictionary = {}) -> void:
	super._init(AgentAction.GRAZE, new_config)


func evaluate(_agent, context) -> Dictionary:
	var hunger := float(context.get_value("hunger", 0.0))
	var food_proximity := float(context.get_value("food_proximity", 0.0))
	var food_biomass := float(context.get_value("food_biomass", 0.0))
	var threat := float(context.get_value("threat", 0.0))
	var thirst := float(context.get_value("thirst", 0.0))
	var water_proximity := float(context.get_value("water_proximity", 0.0))
	var fatigue := float(context.get_value("fatigue", 0.0))
	var score := hunger * get_weight("hunger_weight", 0.42)
	score += food_proximity * get_weight("food_weight", 0.28)
	score += food_biomass * get_weight("biomass_weight", 0.18)
	score += (1.0 - threat) * get_weight("safety_weight", 0.14)
	score -= threat * get_weight("threat_penalty", 0.32)
	score -= fatigue * get_weight("fatigue_penalty", 0.08)
	score -= thirst * water_proximity * get_weight("thirst_penalty", 0.12)
	return result(score, [
		reason_if("hunger", hunger),
		reason_if("food", food_proximity),
		reason_if("threat", threat, 0.28),
	])
