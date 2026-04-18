class_name UtilityContext
extends RefCounted

var species_type: String = ""
var state_name: StringName = StringName()
var values: Dictionary = {}
var targets: Dictionary = {}


func get_value(key: String, default_value = 0.0):
	return values.get(key, default_value)


func get_target(action_name: StringName) -> Dictionary:
	if not targets.has(action_name):
		return {}
	var target: Variant = targets[action_name]
	return {} if typeof(target) != TYPE_DICTIONARY else target


func has_target(action_name: StringName) -> bool:
	return not get_target(action_name).is_empty()


func with_state(new_state_name: StringName) -> Variant:
	var next_context = load("res://scripts/agents/ai/utility_context.gd").new()
	next_context.species_type = species_type
	next_context.state_name = new_state_name
	next_context.values = values.duplicate(true)
	next_context.targets = targets.duplicate(true)
	return next_context
