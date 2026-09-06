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
	# Called twice per decision - once by the agent, once again inside
	# `select_action()` on the context the agent already scoped - so the second
	# call is normally asking for the state it is already in. Nothing mutates a
	# context after `build_context()` fills it, so handing back the same object
	# is indistinguishable from a copy and saves an allocation plus two
	# dictionary copies on every decision of every agent.
	if new_state_name == state_name:
		return self
	# Runs on every predator tick, so it avoids a runtime load() and deep copies.
	# `values` holds only floats, and target dictionaries are read-only downstream,
	# so shallow copies are enough to keep the two contexts independent.
	var next_context = get_script().new()
	next_context.species_type = species_type
	next_context.state_name = new_state_name
	next_context.values = values.duplicate()
	next_context.targets = targets.duplicate()
	return next_context
