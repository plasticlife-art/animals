class_name PairCohesionUtilityEvaluator
extends "res://scripts/agents/ai/utility_evaluator.gd"

const AgentAction := preload("res://scripts/agents/ai/agent_action.gd")


func _init(new_config: Dictionary = {}) -> void:
	super._init(AgentAction.PAIR_COHESION, new_config)


func evaluate(_agent, context) -> Dictionary:
	var separation := float(context.get_value("kin_separation", 0.0))
	var mate_available := float(context.get_value("mate_available", 0.0))
	var low_urgency := float(context.get_value("low_urgency", 0.0))
	var score := separation * get_weight("separation_weight", 0.45)
	score += mate_available * get_weight("mate_available_weight", 0.25)
	score += low_urgency * get_weight("low_urgency_weight", 0.30)
	return result(score, [
		reason_if("separation", separation),
		reason_if("mate", mate_available),
	])
