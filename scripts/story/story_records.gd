class_name StoryRecords
extends RefCounted

## The records the chronicle keeps, read off the family tree (`Lineage`) when asked: the oldest
## animals alive, the longest lives, the largest living families and the best hunters. One pass
## over the tree gives all four; ties go to the lower id, so a list never flickers between two
## equal animals. Nothing here reaches the simulation.

const KINDS := ["oldest", "longest", "family", "hunters"]
const TITLES := {"oldest": "Старейшие", "longest": "Долгожители", "family": "Большие семьи",
	"hunters": "Лучшие охотники"}


## `{kind: [row, …]}` for every kind, at most `count` rows each, best first. A row is `{id, name,
## species, sex, value, dead}`: age or lifespan in seconds, living descendants, or kills.
static func all(book, now: float, count := 3) -> Dictionary:
	var found := {"oldest": [], "longest": [], "family": [], "hunters": []}
	if book == null:
		return found
	var lineage = book.lineage
	var animals: Dictionary = lineage.animals()
	for agent_id in animals.keys():
		var entry: Dictionary = animals[agent_id]
		var id := int(agent_id)
		var dead := float(entry["died"]) >= 0.0
		var age: float = lineage.age_at(id, now)
		if age > 0.0:
			found["longest" if dead else "oldest"].append([age, id])
		var family: int = lineage.descendants_alive(id)
		if family > 0:
			found["family"].append([float(family), id])
	var kills: Dictionary = lineage.kill_counts()
	for hunter in kills.keys():
		if int(kills[hunter]) > 0:
			found["hunters"].append([float(kills[hunter]), int(hunter)])
	var rows := {}
	for kind in KINDS:
		var ranked: Array = found[kind]
		ranked.sort_custom(func(a, b): return a[0] > b[0] or (a[0] == b[0] and a[1] < b[1]))
		var listed: Array = []
		for pair in ranked.slice(0, count):
			listed.append(_row(book, int(pair[1]), float(pair[0])))
		rows[kind] = listed
	return rows


## The records an animal holds - the first place of each list - as kinds. Asked just before its
## death is noted, so the oldest living animal is still counted living.
static func held_by(book, agent_id: int, now: float) -> Array:
	var held: Array = []
	var rows := all(book, now, 1)
	for kind in KINDS:
		var listed: Array = rows[kind]
		if not listed.is_empty() and int(listed[0]["id"]) == agent_id:
			held.append(kind)
	return held


static func _row(book, agent_id: int, value: float) -> Dictionary:
	var entry: Dictionary = book.lineage.entry(agent_id)
	return {"id": agent_id, "name": book.name_of_id(agent_id), "species": str(entry.get("species", "")),
		"sex": str(entry.get("sex", "")), "value": value, "dead": book.lineage.is_dead(agent_id)}
