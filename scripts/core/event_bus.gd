class_name EventBus
extends RefCounted

signal event_emitted(event: Dictionary)

var _events: Array = []


func emit_event(event: Dictionary) -> void:
	var payload := event.duplicate(true)
	_events.append(payload)
	event_emitted.emit(payload)


func get_events() -> Array:
	return _events.duplicate(true)


func get_recent_events(limit: int) -> Array:
	if limit <= 0 or _events.is_empty():
		return []
	var start := maxi(0, _events.size() - limit)
	var recent: Array = []
	for index in range(start, _events.size()):
		recent.append(_events[index].duplicate(true))
	return recent


func clear() -> void:
	_events.clear()


func shutdown() -> void:
	clear()
