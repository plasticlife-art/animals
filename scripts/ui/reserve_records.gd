class_name ReserveRecords
extends RefCounted

## The reserve's tables, from the world the view shows, its story and its viewers: the living wards
## that have lived longest, the ones with most living young and descendants, and the funds' perks
## this year. Read when shown; nothing kept.


## The `count` living wards that have lived longest: `[{name, guardian, age}]`, the eldest first
## (the lower id on a tie). Awake or asleep.
static func longest_lived(world, count: int) -> Array:
	var ages := _living_ages(world)
	var rows: Array = []
	for id in ages.keys():
		var ward: Dictionary = world.adoptions[id]
		rows.append({"id": int(id), "name": str(ward.get("name", "")), "guardian": str(ward.get("viewer_name", "")),
			"age": float(ages[id])})
	rows.sort_custom(func(a, b) -> bool: return a["age"] > b["age"] or (a["age"] == b["age"] and a["id"] < b["id"]))
	return rows.slice(0, count)


## The `count` living wards with most living descendants in the story (`Lineage`), at least one:
## `[{name, guardian, descendants}]`, the most first.
static func biggest_families(world, story, count: int) -> Array:
	var rows: Array = []
	if story == null:
		return rows
	for id in _living_ages(world).keys():
		var alive: int = story.lineage.descendants_alive(int(id))
		if alive <= 0:
			continue
		var ward: Dictionary = world.adoptions[id]
		rows.append({"id": int(id), "name": str(ward.get("name", "")), "guardian": str(ward.get("viewer_name", "")),
			"descendants": alive})
	rows.sort_custom(func(a, b) -> bool:
		return a["descendants"] > b["descendants"] or (a["descendants"] == b["descendants"] and a["id"] < b["id"]))
	return rows.slice(0, count)


## The panel's text for `page`: 0 the eldest, 1 the biggest families, 2 the funds this year.
static func page_text(page: int, world, story, session, calendar: Array) -> String:
	var lines: Array = []
	match page % 3:
		0:
			lines.append("Долгожители")
			for row in longest_lived(world, 3):
				lines.append("%s — %s" % [_who(row), HudText.age_text(float(row["age"]), calendar)])
		1:
			lines.append("Большие семьи")
			for row in biggest_families(world, story, 3):
				lines.append("%s — %s" % [_who(row), _count(int(row["descendants"]), ["потомок", "потомка", "потомков"])])
		2:
			lines.append("Фонды в этом году")
			var funds: Dictionary = session.config.get("teams", {}).get("funds", {})
			for team in funds.keys():
				var perks := int(session.year_perks.get(team, 0)) if int(session._perks_year) == int(world.climate.year) else 0
				lines.append("%s — %s" % [str(funds[team].get("label", team)), _count(perks, ["подарок", "подарка", "подарков"])])
	if lines.size() == 1:
		lines.append("пока никого")
	return "\n".join(lines)


## «Итоги года 3: дольше всех живёт Ветка (Вася), больше всех потомков у Бурана...», for the banner
## when a year ends; "" when there is nothing to tell.
static func year_summary(year: int, world, story, session) -> String:
	var parts: Array = []
	var eldest := longest_lived(world, 1)
	if not eldest.is_empty():
		parts.append("дольше всех живёт %s" % _who(eldest[0]))
	var family := biggest_families(world, story, 1)
	if not family.is_empty():
		parts.append("больше всех потомков — %s" % _who(family[0]))
	var best := ""
	for team in session.year_perks.keys():
		if best == "" or int(session.year_perks[team]) > int(session.year_perks[best]):
			best = str(team)
	if best != "":
		parts.append("фонд года — %s" % str(session.config.get("teams", {}).get("funds", {}).get(best, {}).get("label", best)).trim_prefix("Фонд "))
	if parts.is_empty():
		return ""
	return "Итоги года %d: %s" % [year, ", ".join(parts)]


static func _count(count: int, forms: Array) -> String:
	return "%d %s" % [count, HudText.plural(count, forms)]


static func _who(row: Dictionary) -> String:
	return str(row["name"]) if str(row["guardian"]) == "" else "%s (%s)" % [str(row["name"]), str(row["guardian"])]


## Each living ward's age, awake or asleep: `{id: seconds}`.
static func _living_ages(world) -> Dictionary:
	var ages := {}
	var asleep := {}
	for id in world.adoptions.keys():
		if float(world.adoptions[id].get("died_at", -1.0)) >= 0.0:
			continue
		var agent = world.get_agent(int(id))
		if agent != null and agent.is_alive:
			ages[int(id)] = float(agent.age)
		else:
			asleep[int(id)] = true
	if not asleep.is_empty():
		for sector in world._sector_states.values():
			for record in sector.get("dormant_records", []):
				var id := int(record.get("id", -1))
				if asleep.has(id):
					ages[id] = float(record.get("age", 0.0))
	return ages
