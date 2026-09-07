class_name HuntPreyUtilityEvaluator
extends "res://scripts/agents/ai/utility_evaluator.gd"

const AgentAction := preload("res://scripts/agents/ai/agent_action.gd")


func _init(new_config: Dictionary = {}) -> void:
	super._init(AgentAction.HUNT_PREY, new_config)


func evaluate(_agent, context) -> Dictionary:
	var feeding_allowed := float(context.get_value("feeding_allowed", 1.0))
	if feeding_allowed < 0.5:
		return veto((["below hunger floor"] if context.diagnostics else []))
	var hunger := float(context.get_value("hunger", 0.0))
	var prey_quality := float(context.get_value("prey_quality", 0.0))
	var prey_proximity := float(context.get_value("prey_proximity", 0.0))
	var energy_ratio := float(context.get_value("energy_ratio", 1.0))
	var score := hunger * get_weight("hunger_weight", 0.35)
	score += prey_quality * get_weight("prey_quality_weight", 0.35)
	score += prey_proximity * get_weight("prey_proximity_weight", 0.15)
	score += energy_ratio * get_weight("energy_weight", 0.15)
	score -= (1.0 - energy_ratio) * get_weight("low_energy_penalty", 0.12)
	# Hunger alone enters linearly, so crossing the critical threshold used to change
	# nothing. The knee makes starving decisively outrank drinking and resting, which
	# both scale with their own need and would otherwise tie at high hunger.
	var knee := get_weight("critical_hunger_ratio", 0.6)
	var urgency := clampf((hunger - knee) / maxf(0.01, 1.0 - knee), 0.0, 1.0)
	score += urgency * get_weight("critical_hunger_weight", 0.45)
	return result(score, ([
		reason_if("hunger", hunger),
		reason_if("prey", prey_quality),
		reason_if("range", prey_proximity),
		reason_if("urgent", urgency),
	] if context.diagnostics else []))
