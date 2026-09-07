class_name PairCohesionUtilityEvaluator
extends "res://scripts/agents/ai/utility_evaluator.gd"

const AgentAction := preload("res://scripts/agents/ai/agent_action.gd")


func _init(new_config: Dictionary = {}) -> void:
	super._init(AgentAction.PAIR_COHESION, new_config)


func evaluate(_agent, context) -> Dictionary:
	# Regrouping with a mate peaks around 0.70 with a distant partner, which also
	# outranks hunting. Feeding comes first; the pair can reunite once fed.
	if has_feeding_opportunity(context):
		return veto((["prey in reach"] if context.diagnostics else []))
	var separation := float(context.get_value("kin_separation", 0.0))
	var mate_available := float(context.get_value("mate_available", 0.0))
	var low_urgency := float(context.get_value("low_urgency", 0.0))
	var score := separation * get_weight("separation_weight", 0.45)
	score += mate_available * get_weight("mate_available_weight", 0.25)
	score += low_urgency * get_weight("low_urgency_weight", 0.30)
	# `low_urgency` alone did not tip the balance: with a distant mate this still outscored
	# patrol at moderate hunger, so a hungry predator was pulled back to its partner
	# instead of setting off towards prey. The pair can reunite once it has eaten.
	score -= float(context.get_value("hunger", 0.0)) * get_weight("hunger_penalty", 0.35)
	return result(score, ([
		reason_if("separation", separation),
		reason_if("mate", mate_available),
	] if context.diagnostics else []))
