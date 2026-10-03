class_name Lineage
extends RefCounted

## Who is whose: every animal the view has heard of, with its parents, when it was born and
## died and of what, and its generation - the founders are the first. Built from the world's
## events (`SimulationManager.world_event`): an awake birth names both parents
## (`AgentReproduced`), a birth in a sleeping sector its mother (`data.mother_id`), and every
## death the animal (`agent_id`, or `data.record_id` asleep). Nothing here touches the
## simulation; it is kept with the save.
##
## Each entry: `species`, `sex`, `mother`, `father` (ids, -1 unknown), `born` and `died`
## (simulated seconds, -1 unknown or alive), `cause`, `killer` (id or -1), `generation`,
## `group` (the herd it was born into), `position` (where it died).

## An animal dropped to stay within `CAPACITY`, the longest dead first, so its name goes too.
signal forgotten(agent_id: int)

## Past this many animals the ones that died longest ago are forgotten first.
const CAPACITY := 30000

var _animals: Dictionary = {}
var _children: Dictionary = {}


## Notes an animal the view met without hearing it born - a founder, or one from before a
## save that kept no family tree. It counts as the first generation.
func note_animal(agent_id: int, species: String, sex: String, group := -1) -> void:
	if agent_id < 0 or _animals.has(agent_id):
		return
	_animals[agent_id] = {"species": species, "sex": sex, "mother": -1, "father": -1, "born": -1.0,
		"died": -1.0, "cause": "", "killer": -1, "generation": 1, "group": group, "position": Vector2.ZERO}


## A birth: `parents` are ids, either order; which is the mother is read off their sexes.
func note_birth(agent_id: int, species: String, sex: String, time: float, group: int, parents: Array) -> void:
	if agent_id < 0:
		return
	note_animal(agent_id, species, sex, group)
	var entry: Dictionary = _animals[agent_id]
	if sex != "":
		entry["sex"] = sex
	entry["born"] = time
	entry["group"] = group
	var generation := 0
	for parent in parents:
		var parent_id := int(parent)
		if parent_id < 0 or parent_id == agent_id:
			continue
		var parent_entry: Dictionary = _animals.get(parent_id, {})
		var role := "father" if str(parent_entry.get("sex", "")) == "male" else "mother"
		if int(entry[role]) >= 0 and int(entry[role]) != parent_id:
			role = "father" if role == "mother" else "mother"
		entry[role] = parent_id
		var children: Array = _children.get(parent_id, [])
		if not children.has(agent_id):
			children.append(agent_id)
		_children[parent_id] = children
		generation = maxi(generation, int(parent_entry.get("generation", 1)))
	entry["generation"] = generation + 1
	_trim()


func note_death(agent_id: int, time: float, cause: String, killer: int, position: Vector2) -> void:
	var entry: Dictionary = _animals.get(agent_id, {})
	if entry.is_empty() or float(entry["died"]) >= 0.0:
		return
	entry["died"] = time
	entry["cause"] = cause
	entry["killer"] = killer
	entry["position"] = position


func entry(agent_id: int) -> Dictionary:
	return _animals.get(agent_id, {})


func knows(agent_id: int) -> bool:
	return _animals.has(agent_id)


func is_dead(agent_id: int) -> bool:
	return float(_animals.get(agent_id, {}).get("died", -1.0)) >= 0.0


func children(agent_id: int) -> Array:
	return _children.get(agent_id, [])


## How many of the animal's children, grandchildren and so on are alive, as far as known.
func descendants_alive(agent_id: int, limit := 2000) -> int:
	var alive := 0
	var seen := {agent_id: true}
	var queue: Array = children(agent_id).duplicate()
	while not queue.is_empty() and seen.size() < limit:
		var child := int(queue.pop_front())
		if seen.has(child):
			continue
		seen[child] = true
		if _animals.has(child) and not is_dead(child):
			alive += 1
		queue.append_array(children(child))
	return alive


func size() -> int:
	return _animals.size()


func export_state() -> Dictionary:
	return {"animals": _animals.duplicate(true), "children": _children.duplicate(true)}


func import_state(data: Dictionary) -> void:
	_animals = data.get("animals", {}).duplicate(true)
	_children = data.get("children", {}).duplicate(true)


func clear() -> void:
	_animals.clear()
	_children.clear()


func _trim() -> void:
	if _animals.size() <= CAPACITY:
		return
	var dead: Array = []
	for agent_id in _animals:
		if is_dead(agent_id):
			dead.append(agent_id)
	dead.sort_custom(func(a, b): return float(_animals[a]["died"]) < float(_animals[b]["died"]))
	for agent_id in dead.slice(0, _animals.size() - CAPACITY + int(CAPACITY * 0.1)):
		_animals.erase(agent_id)
		_children.erase(agent_id)
		forgotten.emit(agent_id)
