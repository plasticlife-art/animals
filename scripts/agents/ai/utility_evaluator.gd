class_name UtilityEvaluator
extends RefCounted

const VETO_SCORE := -1.0

var action_name: StringName = StringName()
var config: Dictionary = {}


func _init(new_action_name: StringName = StringName(), new_config: Dictionary = {}) -> void:
	action_name = new_action_name
	config = new_config.duplicate(true)


func evaluate(_agent, _context) -> Dictionary:
	return result(0.0, [])


func get_weight(key: String, default_value: float) -> float:
	return float(config.get(key, default_value))


static func result(score: float, reasons: Array = []) -> Dictionary:
	return {
		"score": clampf(score, 0.0, 1.5),
		"reasons": reasons.duplicate(),
	}


## Marks the action as illegal for this decision tick. The selector drops vetoed
## actions from the candidate set instead of ranking them, so a veto cannot be
## outvoted by the stickiness bonus the way a zero score can.
static func veto(reasons: Array = []) -> Dictionary:
	return {
		"score": VETO_SCORE,
		"reasons": reasons.duplicate(),
		"vetoed": true,
	}


static func reason_if(label: String, value: float, threshold: float = 0.18) -> String:
	if value < threshold:
		return ""
	return "%s %.2f" % [label, value]
