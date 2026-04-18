class_name FleeUtilityEvaluator
extends "res://scripts/agents/ai/utility_evaluator.gd"

const AgentAction := preload("res://scripts/agents/ai/agent_action.gd")


func _init(new_config: Dictionary = {}) -> void:
	super._init(AgentAction.FLEE_TO_SAFE_AREA, new_config)


func evaluate(_agent, context) -> Dictionary:
	var threat := float(context.get_value("threat", 0.0))
	var predator_visible := float(context.get_value("predator_visible_ratio", 0.0))
	var open_area := float(context.get_value("open_area_ratio", 0.0))
	var low_energy := 1.0 - float(context.get_value("energy_ratio", 1.0))
	var safe_zone := float(context.get_value("safe_zone_proximity", 0.0))
	var score := threat * get_weight("threat_weight", 0.50)
	score += predator_visible * get_weight("predator_visible_weight", 0.20)
	score += open_area * get_weight("open_area_weight", 0.10)
	score += low_energy * get_weight("low_energy_weight", 0.10)
	score += safe_zone * get_weight("safe_zone_weight", 0.10)
	return result(score, [
		reason_if("threat", threat),
		reason_if("predator", predator_visible),
		reason_if("open", open_area, 0.2),
	])
