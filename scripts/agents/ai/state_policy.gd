class_name StatePolicy
extends RefCounted

var state_name: StringName = StringName()
var allowed_actions: Array = []
var is_locked: bool = false


func get_allowed_actions() -> Array:
	# Policies are immutable after controller construction. Selection only
	# iterates this array, so copying it for every decision adds no isolation.
	return allowed_actions


func is_action_allowed(action_name: StringName) -> bool:
	return allowed_actions.has(action_name)


func get_state_modifier(_action_name: StringName, _context) -> float:
	return 0.0
