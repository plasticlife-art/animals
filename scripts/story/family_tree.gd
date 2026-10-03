class_name FamilyTree
extends RefCounted

## Three generations around one animal, for the chronicle's «Родословная»: its four
## grandparents, its two parents, the animal, and its children - the first few, with how many
## more there are. Read off the family tree (`Lineage`); -1 where a relative is not known. Each
## relative comes with what its box says: name and sex, kind, age or «†» and how it died.

## Children shown before «и ещё N».
const MAX_CHILDREN := 8


## `{focus, parents: [mother, father], grandparents: [mother's mother, mother's father, father's
## mother, father's father], children: [ids], more: int}`.
static func around(book, agent_id: int) -> Dictionary:
	var lineage = book.lineage
	var entry: Dictionary = lineage.entry(agent_id)
	var mother := int(entry.get("mother", -1))
	var father := int(entry.get("father", -1))
	var grandparents: Array = []
	for parent in [mother, father]:
		var parent_entry: Dictionary = lineage.entry(parent) if parent >= 0 else {}
		grandparents.append(int(parent_entry.get("mother", -1)))
		grandparents.append(int(parent_entry.get("father", -1)))
	var children: Array = lineage.children(agent_id).duplicate()
	# The living first, then by birth, so the box row leads with who can still be visited.
	children.sort_custom(func(a, b):
		var dead_a: bool = lineage.is_dead(int(a))
		var dead_b: bool = lineage.is_dead(int(b))
		if dead_a != dead_b:
			return not dead_a
		return int(a) < int(b))
	return {"focus": agent_id, "parents": [mother, father], "grandparents": grandparents,
		"children": children.slice(0, MAX_CHILDREN), "more": maxi(0, children.size() - MAX_CHILDREN)}


## What a relative's box says: `{id, known, name, glyph, kind, status, dead, pinned}` - the
## status an age, or «†» and the cause.
## `now` is the world's clock, `calendar` `Climate.calendar()`.
static func card(book, agent_id: int, now: float, calendar: Array = [120.0, 4]) -> Dictionary:
	if agent_id < 0 or not book.lineage.knows(agent_id):
		return {"id": agent_id, "known": false, "name": "неизвестно", "glyph": "", "kind": "", "status": "",
			"dead": false, "pinned": false}
	var entry: Dictionary = book.lineage.entry(agent_id)
	var sex := str(entry["sex"])
	var dead: bool = book.lineage.is_dead(agent_id)
	var age: float = book.lineage.age_at(agent_id, now)
	var status := HudText.age_text(age, calendar) if age >= 0.0 else ""
	if dead:
		# The cause alone: the age it died at is in its epitaph, and a box has one short line.
		var cause := str(entry["cause"])
		status = "† %s" % (HudText.cause_label(cause) if cause != "" else HudText.verb(sex, "умер", "умерла"))
	return {"id": agent_id, "known": true, "name": book.name_of_id(agent_id), "glyph": HudText.sex_glyph(sex),
		"kind": HudText.animal_noun(str(entry["species"]), sex), "status": status, "dead": dead,
		"pinned": book.is_pinned(agent_id)}
