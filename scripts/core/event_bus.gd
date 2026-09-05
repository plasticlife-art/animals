class_name EventBus
extends RefCounted

signal event_emitted(event: Dictionary)

## Events are retained for the debug log and the telemetry export, both of which only
## ever look at a bounded slice. Keeping the full history instead costs hundreds of
## megabytes of never-freed dictionaries over a long session, so the buffer is capped
## and old events are dropped from the front.
const DEFAULT_HISTORY_LIMIT := 4096

var history_limit: int = DEFAULT_HISTORY_LIMIT

var _events: Array = []
var _dropped_event_count: int = 0


func initialize(debug_config: Dictionary = {}) -> void:
	history_limit = maxi(1, int(debug_config.get("event_history_limit", DEFAULT_HISTORY_LIMIT)))
	clear()


func emit_event(event: Dictionary) -> void:
	# Callers build a fresh dictionary per event, so it is safe to store the one we
	# were handed rather than deep-copying it again.
	_events.append(event)
	# Trimming costs a full copy, so let the buffer overshoot by a quarter and trim in
	# batches; per-event this amortizes to O(1) instead of copying the whole history
	# on every emit once the cap is reached.
	if _events.size() >= history_limit + _trim_slack():
		var overflow: int = _events.size() - history_limit
		_events = _events.slice(overflow)
		_dropped_event_count += overflow
	event_emitted.emit(event)


func _trim_slack() -> int:
	return maxi(1, history_limit / 4)


func get_events() -> Array:
	return _events.duplicate(true)


func get_dropped_event_count() -> int:
	return _dropped_event_count


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
	_dropped_event_count = 0


func shutdown() -> void:
	clear()
