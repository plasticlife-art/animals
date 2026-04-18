class_name RestUtilityEvaluator
extends "res://scripts/agents/ai/utility_evaluator.gd"

const AgentAction := preload("res://scripts/agents/ai/agent_action.gd")


func _init(new_config: Dictionary = {}) -> void:
	super._init(AgentAction.REST, new_config)


func evaluate(_agent, context) -> Dictionary:
	var fatigue := float(context.get_value("fatigue", 0.0))
	var safe_biome := float(context.get_value("safe_biome_score", 0.0))
	var threat := float(context.get_value("threat", 0.0))
	var hunger := float(context.get_value("hunger", 0.0))
	var thirst := float(context.get_value("thirst", 0.0))
	var score := fatigue * get_weight("fatigue_weight", 0.45)
	score += safe_biome * get_weight("safe_biome_weight", 0.25)
	score += (1.0 - threat) * get_weight("low_threat_weight", 0.10)
	score -= hunger * get_weight("hunger_penalty", 0.18)
	score -= thirst * get_weight("thirst_penalty", 0.22)
	score -= threat * get_weight("threat_penalty", 0.35)
	return result(score, [
		reason_if("fatigue", fatigue),
		reason_if("safe", safe_biome),
		reason_if("threat", threat, 0.2),
	])
