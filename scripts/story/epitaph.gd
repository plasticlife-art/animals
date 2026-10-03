class_name Epitaph
extends RefCounted

## What is said of an animal when it dies: «Ветка, олениха — старейшая на карте. Прожила 2 года
## и 1 сезон. 7 детёнышей (живы 3), 12 живых потомков. Погибла у Тихой заводи: задрал лис
## Рыжик.»
## Composed from the family tree (`Lineage`) once the death is noted there, and from the
## book's places (`PlaceNames`). A hunter's says how many it took; an animal that held one of
## the chronicle's records says which (`StoryRecords`).

const HudTextScript := preload("res://scripts/ui/hud_text.gd")


## The epitaph of an animal the book knows died, or "" if it knows nothing of it. `held` is the
## records it held when it died (`StoryRecords.held_by()`); `calendar` is `Climate.calendar()`.
static func compose(book, agent_id: int, held: Array = [], calendar: Array = [120.0, 4]) -> String:
	var entry: Dictionary = book.lineage.entry(agent_id)
	if entry.is_empty():
		return ""
	var species := str(entry["species"])
	var sex := str(entry["sex"])
	var head := "%s, %s" % [book.name_of_id(agent_id), HudTextScript.animal_noun(species, sex)]
	var titles: Array = []
	for kind in held:
		var title := record_title(str(kind), sex)
		if title != "":
			titles.append(title)
	if not titles.is_empty():
		head += " — " + ", ".join(titles)
	var text := head + "."
	var age: float = book.lineage.age_at(agent_id, float(entry["died"]))
	if age >= 0.0:
		text += " %s %s." % [HudTextScript.verb(sex, "Прожил", "Прожила"), HudTextScript.age_text(age, calendar)]
	var life: Array = []
	var children: Array = book.lineage.children(agent_id)
	var living := 0
	for child in children:
		if not book.lineage.is_dead(int(child)):
			living += 1
	if not children.is_empty():
		life.append("%d %s (живы %d)" % [children.size(),
			HudTextScript.plural(children.size(), ["детёныш", "детёныша", "детёнышей"]), living])
	var descendants: int = book.lineage.descendants_alive(agent_id)
	if descendants > living:
		life.append("%d %s" % [descendants,
			HudTextScript.plural(descendants, ["живой потомок", "живых потомка", "живых потомков"])])
	var kills: int = book.lineage.kills(agent_id)
	if kills > 0:
		life.append("добыча: %d" % kills)
	if not life.is_empty():
		var told := ", ".join(life)
		text += " " + told.substr(0, 1).to_upper() + told.substr(1) + "."
	return text + " " + death_text(book, entry)


## «Погибла у Тихой заводи: задрал лис Рыжик.», «Умерла от старости на Медовом лугу.»
static func death_text(book, entry: Dictionary) -> String:
	var sex := str(entry["sex"])
	var cause := str(entry["cause"])
	var at: String = book.places.at(entry["position"]) if book.places != null else ""
	var place := " " + at if at != "" else ""
	var killer := int(entry["killer"])
	if cause == "predation" and killer >= 0:
		var hunter: Dictionary = book.lineage.entry(killer)
		var hunter_sex := str(hunter.get("sex", ""))
		return "%s%s: %s %s %s." % [HudTextScript.verb(sex, "Погиб", "Погибла"), place,
			HudTextScript.verb(hunter_sex, "задрал", "задрала"),
			HudTextScript.animal_noun(str(hunter.get("species", "predator")), hunter_sex), book.name_of_id(killer)]
	if cause == "predation":
		return "%s от хищника%s." % [HudTextScript.verb(sex, "Погиб", "Погибла"), place]
	return "%s от %s%s." % [HudTextScript.verb(sex, "Умер", "Умерла"),
		str(HudTextScript.CAUSES_FROM.get(cause, cause)), place]


## How an epitaph names a record: «старейшая на карте», «долгожительница карты», «лучший охотник
## карты».
static func record_title(kind: String, sex: String) -> String:
	match kind:
		"oldest":
			return HudTextScript.verb(sex, "старейший на карте", "старейшая на карте")
		"longest":
			return HudTextScript.verb(sex, "долгожитель карты", "долгожительница карты")
		"family":
			return "глава самой большой семьи"
		"hunters":
			return HudTextScript.verb(sex, "лучший охотник карты", "лучшая охотница карты")
	return ""
