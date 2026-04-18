class_name StatePolicy
extends RefCounted

var state_name: StringName = StringName()
var allowed_actions: Array = []
var is_locked: bool = false


func get_allowed_actions() -> Array:
	return allowed_actions.duplicate()


func is_action_allowed(action_name: StringName) -> bool:
	return allowed_actions.has(action_name)


func get_state_modifier(_action_name: StringName, _context) -> float:
	return 0.0
