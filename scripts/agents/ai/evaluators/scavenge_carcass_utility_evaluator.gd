class_name ScavengeCarcassUtilityEvaluator
extends "res://scripts/agents/ai/utility_evaluator.gd"

const AgentAction := preload("res://scripts/agents/ai/agent_action.gd")


func _init(new_config: Dictionary = {}) -> void:
	super._init(AgentAction.SCAVENGE_CARCASS, new_config)


func evaluate(_agent, context) -> Dictionary:
	var hunger := float(context.get_value("hunger", 0.0))
	var carcass_proximity := float(context.get_value("carcass_proximity", 0.0))
	var carcass_meat := float(context.get_value("carcass_meat", 0.0))
	var prey_scarcity := float(context.get_value("prey_scarcity", 0.0))
	var score := hunger * get_weight("hunger_weight", 0.35)
	score += carcass_proximity * get_weight("carcass_proximity_weight", 0.25)
	score += carcass_meat * get_weight("carcass_meat_weight", 0.25)
	score += prey_scarcity * get_weight("prey_scarcity_weight", 0.15)
	return result(score, [
		reason_if("hunger", hunger),
		reason_if("carcass", carcass_proximity),
		reason_if("meat", carcass_meat),
	])
