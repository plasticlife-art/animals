class_name ExploreUtilityEvaluator
extends "res://scripts/agents/ai/utility_evaluator.gd"

const AgentAction := preload("res://scripts/agents/ai/agent_action.gd")


func _init(new_config: Dictionary = {}) -> void:
	super._init(AgentAction.EXPLORE, new_config)


func evaluate(_agent, context) -> Dictionary:
	var low_urgency := float(context.get_value("low_urgency", 0.0))
	var resource_scarcity := float(context.get_value("resource_scarcity", 0.0))
	var threat := float(context.get_value("threat", 0.0))
	var score := low_urgency * get_weight("low_urgency_weight", 0.45)
	score += resource_scarcity * get_weight("scarcity_weight", 0.35)
	score += (1.0 - threat) * get_weight("low_threat_weight", 0.20)
	return result(score, [
		reason_if("calm", low_urgency),
		reason_if("scarcity", resource_scarcity),
		reason_if("threat", threat, 0.24),
	])
