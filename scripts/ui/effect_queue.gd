class_name EffectQueue
extends RefCounted

## Short-lived marks the view puts on the world for what just happened there: dust under a
## chase, the burst and flash of a kill, a ring and sparkles at a birth (`EventEffects`
## draws them). Each is a kind, a world position, a start on the view's clock
## (`SimulationManager.get_display_time()`), how long it lasts, a size and a drift.
##
## Nothing here touches the simulation, and nothing draws from a random stream: the
## scatter comes from `jitter()`, a hash of numbers the caller already has, so the same
## events always make the same picture and no generator anywhere is advanced by looking.
## Finished marks go back to a free list instead of being thrown away, since a stampede
## in view makes and drops dozens a second.

enum Kind { DUST, BURST, FLASH, RING, SPARKLE }

## At most this many at once; past it a new mark is refused, never an old one cut short.
var capacity: int = 160
## Marks accepted since the queue was made, for the render counters and the tests.
var added: int = 0
var _items: Array = []
var _free: Array = []


## Adds a mark. `drift` is how far it travels over its life and `lift` how far above the
## ground point it sits, both in screen units; `tint` is its colour. Refused when full or
## when it would last no time.
func add(kind: int, position: Vector2, start: float, seconds: float, size: float, drift := Vector2.ZERO,
		lift := 0.0, tint := Color.WHITE) -> bool:
	if _items.size() >= capacity or seconds <= 0.0:
		return false
	var item: Dictionary = _free.pop_back() if not _free.is_empty() else {}
	item["kind"] = kind
	item["position"] = position
	item["start"] = start
	item["seconds"] = seconds
	item["size"] = size
	item["drift"] = drift
	item["lift"] = lift
	item["tint"] = tint
	_items.append(item)
	added += 1
	return true


## Drops the marks that have run their course by `now`, keeping the rest in the order
## they came, so the newest still draws on top. True while any are left to draw.
func advance(now: float) -> bool:
	var kept := 0
	for item in _items:
		if now - float(item["start"]) >= float(item["seconds"]):
			_free.append(item)
			continue
		_items[kept] = item
		kept += 1
	_items.resize(kept)
	return kept > 0


func items() -> Array:
	return _items


func is_empty() -> bool:
	return _items.is_empty()


func clear() -> void:
	_free.append_array(_items)
	_items.clear()


## How far through its life `item` is at `now`, 0..1; negative before it starts.
static func progress(item: Dictionary, now: float) -> float:
	var elapsed: float = now - float(item["start"])
	if elapsed < 0.0:
		return -1.0
	return clampf(elapsed / maxf(float(item["seconds"]), 0.0001), 0.0, 1.0)


## A number in [0, 1) that depends only on `a` and `b`: the scatter of a puff from the id
## of the animal that raised it and how many it has raised.
static func jitter(a: int, b: int) -> float:
	var h: int = (a * 73856093) ^ (b * 19349663) ^ 0x5bd1e995
	h = (h ^ (h >> 15)) * 0x2c1b3c6d
	h = (h ^ (h >> 12)) * 0x297a2d39
	h = h ^ (h >> 15)
	return float(h & 0xFFFFFF) / float(0x1000000)
