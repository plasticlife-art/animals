class_name ScavengeCarcassUtilityEvaluator
extends "res://scripts/agents/ai/utility_evaluator.gd"

const AgentAction := preload("res://scripts/agents/ai/agent_action.gd")


func _init(new_config: Dictionary = {}) -> void:
	super._init(AgentAction.SCAVENGE_CARCASS, new_config)


func evaluate(_agent, context) -> Dictionary:
	var feeding_allowed := float(context.get_value("feeding_allowed", 1.0))
	if feeding_allowed < 0.5:
		return veto((["below hunger floor"] if context.diagnostics else []))
	var hunger := float(context.get_value("hunger", 0.0))
	var carcass_proximity := float(context.get_value("carcass_proximity", 0.0))
	var carcass_meat := float(context.get_value("carcass_meat", 0.0))
	var prey_scarcity := float(context.get_value("prey_scarcity", 0.0))
	var score := hunger * get_weight("hunger_weight", 0.35)
	score += carcass_proximity * get_weight("carcass_proximity_weight", 0.25)
	score += carcass_meat * get_weight("carcass_meat_weight", 0.25)
	score += prey_scarcity * get_weight("prey_scarcity_weight", 0.15)
	# The same knee `hunt_prey` uses. Without it, only hunting gained anything from
	# crossing the critical-hunger line, so a starving predator standing next to a
	# carcass still preferred to go and chase - and `stickiness_bonus` then held it
	# there. Weighted by whether a carcass is actually in reach, or a starving
	# predator with none in range would score scavenging high and stall on a target
	# it cannot find. The weight sits above the hunt one on purpose: a carcass is a
	# certain meal, an attack lands `attack.base_success_chance` of the time.
	var availability := maxf(carcass_proximity, carcass_meat)
	var knee := get_weight("critical_hunger_ratio", 0.6)
	var urgency := clampf((hunger - knee) / maxf(0.01, 1.0 - knee), 0.0, 1.0)
	score += urgency * availability * get_weight("critical_hunger_weight", 0.5)
	return result(score, ([
		reason_if("hunger", hunger),
		reason_if("carcass", carcass_proximity),
		reason_if("meat", carcass_meat),
	] if context.diagnostics else []))
