class_name HerdLossLog
extends RefCounted

## The last animal each herd lost, and to what: what the herd card says under
## «Последняя потеря». Fed from `SimulationManager.world_event`; death events carry the
## herd the animal belonged to (`data.group_id`), awake or asleep.
##
## Herd ids are reused: a split hands the new herd a free id, possibly one a herd that
## died out had. So a split forgets what was recorded under the id it hands out, or the
## new herd would open with the old one's loss.

## Herds remembered at most; past it the one that lost an animal longest ago is dropped.
const CAPACITY := 256

var _last: Dictionary = {}


func hear(event: Dictionary) -> void:
	var species := str(event.get("species", ""))
	var data: Dictionary = event.get("data", {})
	match str(event.get("type", "")):
		"AgentDied":
			var group_id := int(data.get("group_id", -1))
			if group_id < 0:
				return
			_last[_key(species, group_id)] = {"time": float(event.get("time_seconds", 0.0)),
				"cause": str(data.get("cause", ""))}
			if _last.size() > CAPACITY:
				_forget_oldest()
		"HerdSplit":
			_last.erase(_key(species, int(data.get("new_group_id", -1))))


## `{time, cause}` of the herd's last loss, or empty.
func last_loss(species: String, group_id: int) -> Dictionary:
	return _last.get(_key(species, group_id), {})


func size() -> int:
	return _last.size()


func clear() -> void:
	_last.clear()


func _forget_oldest() -> void:
	var oldest = null
	for key in _last:
		if oldest == null or float(_last[key]["time"]) < float(_last[oldest]["time"]):
			oldest = key
	_last.erase(oldest)


static func _key(species: String, group_id: int) -> String:
	return "%s:%d" % [species, group_id]
