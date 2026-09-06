class_name UtilityEvaluator
extends RefCounted

const VETO_SCORE := -1.0

const AgentActionRef := preload("res://scripts/agents/ai/agent_action.gd")

var action_name: StringName = StringName()
var config: Dictionary = {}


func _init(new_action_name: StringName = StringName(), new_config: Dictionary = {}) -> void:
	action_name = new_action_name
	config = new_config.duplicate(true)


func evaluate(_agent, _context) -> Dictionary:
	return result(0.0, [])


func get_weight(key: String, default_value: float) -> float:
	return float(config.get(key, default_value))


## Callers always pass a freshly built array literal, so the array is taken as-is.
## Copying it here allocated a second array per evaluator call - roughly eight
## per agent per decision tick, for nothing.
static func result(score: float, reasons: Array = []) -> Dictionary:
	return {
		"score": clampf(score, 0.0, 1.5),
		"reasons": reasons,
	}


## Marks the action as illegal for this decision tick. The selector drops vetoed
## actions from the candidate set instead of ranking them, so a veto cannot be
## outvoted by the stickiness bonus the way a zero score can.
static func veto(reasons: Array = []) -> Dictionary:
	return {
		"score": VETO_SCORE,
		"reasons": reasons,
		"vetoed": true,
	}


## True when the agent is hungry enough to feed and actually has something to eat in
## reach. The idle actions veto on this instead of competing on score, because their
## own inputs are derived as `1 - (the feeding drivers)`: on raw score `patrol` and
## `pair_cohesion` outrank `hunt_prey` until hunger is nearly lethal, and the
## stickiness bonus plus switch threshold then pin whichever of them is incumbent.
## A veto is the right tool because the selector drops vetoed actions from the
## candidate set rather than ranking them, so it bypasses both.
static func has_feeding_opportunity(context) -> bool:
	if float(context.get_value("feeding_allowed", 0.0)) < 0.5:
		return false
	return context.has_target(AgentActionRef.HUNT_PREY) or context.has_target(AgentActionRef.SCAVENGE_CARCASS)


static func reason_if(label: String, value: float, threshold: float = 0.18) -> String:
	if value < threshold:
		return ""
	return "%s %.2f" % [label, value]
