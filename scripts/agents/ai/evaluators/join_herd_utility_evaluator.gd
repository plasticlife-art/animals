class_name JoinHerdUtilityEvaluator
extends "res://scripts/agents/ai/utility_evaluator.gd"

const AgentAction := preload("res://scripts/agents/ai/agent_action.gd")


func _init(new_config: Dictionary = {}) -> void:
	super._init(AgentAction.JOIN_HERD, new_config)


func evaluate(_agent, context) -> Dictionary:
	var isolation := float(context.get_value("isolation", 0.0))
	var herd_proximity := float(context.get_value("herd_proximity", 0.0))
	var herd_available := float(context.get_value("herd_available", 0.0))
	var threat := float(context.get_value("threat", 0.0))
	var score := isolation * get_weight("isolation_weight", 0.35)
	score += herd_proximity * get_weight("herd_weight", 0.25)
	score += herd_available * get_weight("availability_weight", 0.20)
	score += threat * get_weight("threat_weight", 0.20)
	return result(score, [
		reason_if("alone", isolation),
		reason_if("herd", herd_proximity),
		reason_if("threat", threat, 0.22),
	])
