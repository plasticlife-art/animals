class_name PerformanceWindow
extends RefCounted

## Bounded samples; percentiles are calculated only when the HUD/export asks.
var samples: Array[float] = []
var capacity: int = 1800
var cursor: int = 0

func add(value: float) -> void:
	if samples.size() < capacity:
		samples.append(value)
	else:
		samples[cursor] = value
		cursor = (cursor + 1) % capacity

func summary() -> Dictionary:
	if samples.is_empty():
		return {"p50": 0.0, "p95": 0.0, "p99": 0.0, "count": 0}
	var ordered := samples.duplicate()
	ordered.sort()
	return {"p50": ordered[int(ceil(ordered.size() * 0.50)) - 1],
		"p95": ordered[int(ceil(ordered.size() * 0.95)) - 1],
		"p99": ordered[int(ceil(ordered.size() * 0.99)) - 1], "count": ordered.size()}
