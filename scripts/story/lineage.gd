class_name Lineage
extends RefCounted

## Who is whose: every animal the view has heard of, with its parents, when it was born and
## died and of what, and its generation - the founders are the first. Built from the world's
## events (`SimulationManager.world_event`): an awake birth names both parents
## (`AgentReproduced`), a birth in a sleeping sector its mother (`data.mother_id`), and every
## death the animal (`agent_id`, or `data.record_id` asleep), its age and its killer. Nothing
## here touches the simulation; it is kept with the save.
##
## Each entry: `species`, `sex`, `mother`, `father` (ids, -1 unknown), `born` and `died`
## (simulated seconds, -1 unknown or alive), `met` and `met_age` (when an animal not seen born
## was first met, or died, and how old it was then - founders were born before the clock
## started), `cause`, `killer` (id or -1), `generation`, `group` (the herd it was born into),
## `position` (where it died).
##
## The records keep running counts rather than walking the tree each time they are read: how
## many kills each hunter made, and how many descendants each animal has - alive and ever.
## A birth adds one to every distinct ancestor, a death takes one off the living count.

## An animal dropped to stay within `CAPACITY`, the longest dead first, so its name goes too.
signal forgotten(agent_id: int)

## Past this many animals the ones that died longest ago are forgotten first.
const CAPACITY := 30000
## Ancestors walked for one birth or death at most; a deep family is far below it.
const ANCESTOR_LIMIT := 4096

var _animals: Dictionary = {}
var _children: Dictionary = {}
var _kills: Dictionary = {}
var _alive_descendants: Dictionary = {}
var _all_descendants: Dictionary = {}


## Notes an animal the view met without hearing it born - a founder, or one from before a
## save that kept no family tree. It counts as the first generation. `age` at `now` dates it.
## Met again, it only fills what was missing: the sex of a killer heard of asleep, the age of
## one met grown.
func note_animal(agent_id: int, species: String, sex: String, group := -1, age := -1.0, now := -1.0) -> void:
	if agent_id < 0:
		return
	if _animals.has(agent_id):
		var known: Dictionary = _animals[agent_id]
		if str(known["sex"]) == "" and sex != "":
			known["sex"] = sex
		if str(known["species"]) == "" and species != "":
			known["species"] = species
		if float(known.get("met_age", -1.0)) < 0.0 and age >= 0.0 and now >= 0.0:
			known["met"] = now
			known["met_age"] = age
		return
	_animals[agent_id] = {"species": species, "sex": sex, "mother": -1, "father": -1, "born": -1.0,
		"died": -1.0, "cause": "", "killer": -1, "generation": 1, "group": group, "position": Vector2.ZERO,
		"met": now if age >= 0.0 and now >= 0.0 else -1.0, "met_age": age if age >= 0.0 and now >= 0.0 else -1.0}


## A birth: `parents` are ids, either order; which is the mother is read off their sexes. Heard
## twice for an awake birth - the birth, then the parents - so only ancestors it did not have
## yet count it.
func note_birth(agent_id: int, species: String, sex: String, time: float, group: int, parents: Array) -> void:
	if agent_id < 0:
		return
	note_animal(agent_id, species, sex, group)
	var before := ancestors(agent_id)
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
	entry["generation"] = maxi(generation + 1, int(entry["generation"])) if not parents.is_empty() else int(entry["generation"])
	var alive := not is_dead(agent_id)
	for ancestor in ancestors(agent_id).keys():
		if before.has(ancestor):
			continue
		_all_descendants[ancestor] = int(_all_descendants.get(ancestor, 0)) + 1
		if alive:
			_alive_descendants[ancestor] = int(_alive_descendants.get(ancestor, 0)) + 1
	_trim()


## A death, with the age it died at when the event told it (`-1` when not), which dates an
## animal not seen born more exactly than its meeting did.
func note_death(agent_id: int, time: float, cause: String, killer: int, position: Vector2, age := -1.0) -> void:
	var entry: Dictionary = _animals.get(agent_id, {})
	if entry.is_empty() or float(entry["died"]) >= 0.0:
		return
	entry["died"] = time
	entry["cause"] = cause
	entry["killer"] = killer
	entry["position"] = position
	if age >= 0.0 and float(entry["born"]) < 0.0:
		entry["met"] = time
		entry["met_age"] = age
	if cause == "predation" and killer >= 0:
		_kills[killer] = int(_kills.get(killer, 0)) + 1
	for ancestor in ancestors(agent_id).keys():
		if _alive_descendants.has(ancestor):
			_alive_descendants[ancestor] = maxi(0, int(_alive_descendants[ancestor]) - 1)


func entry(agent_id: int) -> Dictionary:
	return _animals.get(agent_id, {})


func knows(agent_id: int) -> bool:
	return _animals.has(agent_id)


func is_dead(agent_id: int) -> bool:
	return float(_animals.get(agent_id, {}).get("died", -1.0)) >= 0.0


func children(agent_id: int) -> Array:
	return _children.get(agent_id, [])


## How many of the animal's children, grandchildren and so on are alive, as far as known.
func descendants_alive(agent_id: int) -> int:
	return int(_alive_descendants.get(agent_id, 0))


## How many descendants the animal has had, alive or not.
func descendants_ever(agent_id: int) -> int:
	return int(_all_descendants.get(agent_id, 0))


## How many animals this hunter killed, asleep or awake.
func kills(agent_id: int) -> int:
	return int(_kills.get(agent_id, 0))


func kill_counts() -> Dictionary:
	return _kills


## Its age at `time`, or at its death; -1 when nothing dates it.
func age_at(agent_id: int, time: float) -> float:
	var known: Dictionary = _animals.get(agent_id, {})
	if known.is_empty():
		return -1.0
	var until: float = float(known["died"]) if float(known["died"]) >= 0.0 else time
	if float(known["born"]) >= 0.0:
		return maxf(0.0, until - float(known["born"]))
	if float(known.get("met_age", -1.0)) >= 0.0:
		return maxf(0.0, until - float(known["met"]) + float(known["met_age"]))
	return -1.0


## Every known ancestor's id, as a set: parents, their parents, and on.
func ancestors(agent_id: int) -> Dictionary:
	var found := {}
	var queue: Array = []
	var start: Dictionary = _animals.get(agent_id, {})
	for role in ["mother", "father"]:
		if int(start.get(role, -1)) >= 0:
			queue.append(int(start[role]))
	while not queue.is_empty() and found.size() < ANCESTOR_LIMIT:
		var ancestor := int(queue.pop_back())
		if ancestor == agent_id or found.has(ancestor):
			continue
		found[ancestor] = true
		var known: Dictionary = _animals.get(ancestor, {})
		for role in ["mother", "father"]:
			var parent := int(known.get(role, -1))
			if parent >= 0 and not found.has(parent):
				queue.append(parent)
	return found


## The living descendants counted the slow way, down the tree: what the running counts must
## always agree with.
func count_descendants_alive(agent_id: int, limit := 20000) -> int:
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


## Every animal the family tree knows, by id - for the records.
func animals() -> Dictionary:
	return _animals


func size() -> int:
	return _animals.size()


func export_state() -> Dictionary:
	return {"animals": _animals.duplicate(true), "children": _children.duplicate(true), "kills": _kills.duplicate(),
		"alive_descendants": _alive_descendants.duplicate(), "all_descendants": _all_descendants.duplicate()}


## A save from before the running counts gets them rebuilt from the tree.
func import_state(data: Dictionary) -> void:
	_animals = data.get("animals", {}).duplicate(true)
	_children = data.get("children", {}).duplicate(true)
	_kills = data.get("kills", {}).duplicate()
	_alive_descendants = data.get("alive_descendants", {}).duplicate()
	_all_descendants = data.get("all_descendants", {}).duplicate()
	if not data.has("alive_descendants"):
		_rebuild_counts()


func clear() -> void:
	_animals.clear()
	_children.clear()
	_kills.clear()
	_alive_descendants.clear()
	_all_descendants.clear()


func _rebuild_counts() -> void:
	_kills.clear()
	_alive_descendants.clear()
	_all_descendants.clear()
	for agent_id in _animals:
		var known: Dictionary = _animals[agent_id]
		if str(known["cause"]) == "predation" and int(known["killer"]) >= 0:
			_kills[int(known["killer"])] = int(_kills.get(int(known["killer"]), 0)) + 1
		var alive := float(known["died"]) < 0.0
		for ancestor in ancestors(agent_id).keys():
			_all_descendants[ancestor] = int(_all_descendants.get(ancestor, 0)) + 1
			if alive:
				_alive_descendants[ancestor] = int(_alive_descendants.get(ancestor, 0)) + 1


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
		_kills.erase(agent_id)
		_alive_descendants.erase(agent_id)
		_all_descendants.erase(agent_id)
		forgotten.emit(agent_id)
