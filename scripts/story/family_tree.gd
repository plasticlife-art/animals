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


## The focus's own line of family: «3 детёныша (живы 2) · 7 живых потомков», «детей нет».
static func focus_line(book, agent_id: int) -> String:
	var children: Array = book.lineage.children(agent_id)
	if children.is_empty():
		return "детей нет"
	var living := 0
	for child in children:
		if not book.lineage.is_dead(int(child)):
			living += 1
	var text := "%d %s (живы %d)" % [children.size(),
		HudText.plural(children.size(), ["детёныш", "детёныша", "детёнышей"]), living]
	var descendants: int = book.lineage.descendants_alive(agent_id)
	if descendants > living:
		text += " · %d %s" % [descendants, HudText.plural(descendants, ["живой потомок", "живых потомка", "живых потомков"])]
	return text


## Whether the focus's parents are kin - «родители — брат и сестра», «у родителей одна мать», «у
## родителей один отец» - from the grandparents `around()` found; "" when not, or not known.
static func parents_kinship(family: Dictionary) -> String:
	var grand: Array = family.get("grandparents", [-1, -1, -1, -1])
	var same_mother: bool = int(grand[0]) >= 0 and int(grand[0]) == int(grand[2])
	var same_father: bool = int(grand[1]) >= 0 and int(grand[1]) == int(grand[3])
	if same_mother and same_father:
		return "родители — брат и сестра"
	if same_mother:
		return "у родителей одна мать"
	if same_father:
		return "у родителей один отец"
	return ""


## What a child's box says in place of its kind: the parent the tree does not draw, the focus's
## mate - «мать — Ветка», «отец — Буян», «отец неизвестен». Without it a buck's calves stood under
## him as if he had them alone. "" when the child is not the focus's.
static func mate_line(book, child_id: int, focus_id: int) -> String:
	var entry: Dictionary = book.lineage.entry(child_id)
	var mother := int(entry.get("mother", -1))
	var father := int(entry.get("father", -1))
	if focus_id == mother:
		return "отец — %s" % book.name_of_id(father) if father >= 0 and book.lineage.knows(father) else "отец неизвестен"
	if focus_id == father:
		return "мать — %s" % book.name_of_id(mother) if mother >= 0 and book.lineage.knows(mother) else "мать неизвестна"
	return ""


## What a relative's box says: `{id, known, name, glyph, kind, status, dead, pinned, traits}` - the
## status an age, or «†» and the cause; `traits` what it inherited, for the box's tooltip, empty
## when not known.
## `now` is the world's clock, `calendar` `Climate.calendar()`.
static func card(book, agent_id: int, now: float, calendar: Array = [120.0, 4]) -> Dictionary:
	if agent_id < 0 or not book.lineage.knows(agent_id):
		return {"id": agent_id, "known": false, "name": "неизвестно", "glyph": "", "kind": "", "status": "",
			"dead": false, "pinned": false, "traits": ""}
	var entry: Dictionary = book.lineage.entry(agent_id)
	var sex := str(entry["sex"])
	var dead: bool = book.lineage.is_dead(agent_id)
	var age: float = book.lineage.age_at(agent_id, now)
	var status := HudText.age_text(age, calendar) if age >= 0.0 else ""
	var cause := str(entry["cause"])
	if dead and cause == "emigrated":
		# Gone from the map, not dead: no cross.
		status = HudText.verb(sex, "ушёл с карты", "ушла с карты")
	elif dead:
		# The cause alone: the age it died at is in its epitaph, and a box has one short line.
		status = "† %s" % (HudText.cause_label(cause) if cause != "" else HudText.verb(sex, "умер", "умерла"))
	var traits = entry.get("traits", null)
	return {"id": agent_id, "known": true, "name": book.name_of_id(agent_id), "glyph": HudText.sex_glyph(sex), "sex": sex,
		"kind": HudText.animal_noun(str(entry["species"]), sex), "status": status, "dead": dead,
		"pinned": book.is_pinned(agent_id), "traits": "" if traits == null else HudText.traits_text(Array(traits))}
