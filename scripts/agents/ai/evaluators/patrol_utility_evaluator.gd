class_name PatrolUtilityEvaluator
extends "res://scripts/agents/ai/utility_evaluator.gd"

const AgentAction := preload("res://scripts/agents/ai/agent_action.gd")


func _init(new_config: Dictionary = {}) -> void:
	super._init(AgentAction.PATROL, new_config)


func evaluate(_agent, context) -> Dictionary:
	var low_urgency := float(context.get_value("low_urgency", 0.0))
	var no_targets := float(context.get_value("no_targets_score", 0.0))
	var score := get_weight("base_score", 0.15)
	score += low_urgency * get_weight("low_urgency_weight", 0.55)
	score += no_targets * get_weight("no_targets_weight", 0.30)
	return result(score, [
		reason_if("calm", low_urgency),
		reason_if("idle", no_targets),
	])
