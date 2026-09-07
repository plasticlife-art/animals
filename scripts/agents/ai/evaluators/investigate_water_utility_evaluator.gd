class_name InvestigateWaterUtilityEvaluator
extends "res://scripts/agents/ai/utility_evaluator.gd"

const AgentAction := preload("res://scripts/agents/ai/agent_action.gd")


func _init(new_config: Dictionary = {}) -> void:
	super._init(AgentAction.INVESTIGATE_WATER, new_config)


func evaluate(_agent, context) -> Dictionary:
	# Investigating a water source is a guess about where prey might turn up. It has no
	# business outranking prey the predator can already see; thirst is `drink`'s job.
	if has_feeding_opportunity(context):
		return veto((["prey in reach"] if context.diagnostics else []))
	var hunger := float(context.get_value("hunger", 0.0))
	var thirst := float(context.get_value("thirst", 0.0))
	var signal_score := float(context.get_value("investigation_signal", 0.0))
	var water_proximity := float(context.get_value("water_proximity", 0.0))
	var score := hunger * get_weight("hunger_weight", 0.20)
	score += thirst * get_weight("thirst_weight", 0.15)
	score += signal_score * get_weight("signal_weight", 0.45)
	score += water_proximity * get_weight("water_weight", 0.20)
	return result(score, ([
		reason_if("signal", signal_score),
		reason_if("water", water_proximity),
		reason_if("hunger", hunger, 0.24),
	] if context.diagnostics else []))
