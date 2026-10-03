class_name SeasonReport
extends RefCounted

## What is said of a season (`SeasonLedger.close()`), for the season card and the chronicle's
## «Сезоны»: a title - «Итоги лета · год 2 · засуха» - and a line each for the numbers, the
## young, the dead, the best hunter and the ponds:
##
##     Олени 278 (+38) · лисы 41 (−6) · тетерева 118 (+12)
##     Родились: 74 оленёнка, 12 лисят, 40 птенцов
##     Погибли: хищники — 31, голод — 9, жажда — 4, старость — 12
##     Лучший охотник: лис Рыжик — 5 добыч
##     Пересохли Тихая заводь, Кривой брод и ещё 3 водоёма
##
## A line with nothing to say is left out. Years are counted from 1, as the season bar counts
## them. A number keeps to its word and a pond's name to itself across a wrapped line (`NBSP`),
## so the card never ends a line on «старость» with «— 38» under it.

const HudTextScript := preload("res://scripts/ui/hud_text.gd")
## Species in this order, any other after them in the summary's own.
const SPECIES_ORDER := ["herbivore", "predator", "scavenger"]
const CAUSE_ORDER := ["predation", "starvation", "thirst", "old_age"]
## Ponds named before «и ещё …»; one more than this is named in full.
const PONDS_NAMED := 2
const NBSP := "\u00a0"


## The title. `form`: "card" - «Итоги лета · год 2 · засуха»; "row", for a season in the
## chronicle - «Лето · год 2 · засуха»; "running", for the one still going - «Лето · год 2 ·
## идёт». A season the ledger did not see from its start says so: «не с начала».
static func title(summary: Dictionary, form := "card") -> String:
	var season_id := str(summary.get("season_id", ""))
	var label := str(summary.get("label", season_id))
	var parts: Array = []
	if form == "card":
		parts.append("Итоги %s" % HudTextScript.season_genitive(season_id, label))
	else:
		parts.append(HudTextScript.capitalized(label.to_lower()))
	parts.append("год %d" % (int(summary.get("year", 0)) + 1))
	if bool(summary.get("drought", false)):
		parts.append("засуха")
	if form == "running":
		parts.append("идёт")
	if bool(summary.get("partial", false)):
		parts.append("не с начала")
	return " · ".join(parts)


## The lines under the title, the empty ones left out.
static func lines(summary: Dictionary) -> Array:
	var result: Array = []
	for line in [numbers_line(summary), births_line(summary), deaths_line(summary), hunter_line(summary),
			ponds_line(summary.get("dried", []), summary.get("genders", {}), true),
			ponds_line(summary.get("refilled", []), summary.get("genders", {}), false)]:
		if str(line) != "":
			result.append(line)
	return result


static func text(summary: Dictionary) -> String:
	return "\n".join(lines(summary))


## «Олени 278 (+38) · лисы 41 (−6) · тетерева 118 (+12)»: each species at the season's end and
## its change; a species the map never had is left out.
static func numbers_line(summary: Dictionary) -> String:
	var parts: Array = []
	var species: Dictionary = summary.get("species", {})
	for species_id in ordered(species.keys()):
		var numbers: Dictionary = species[species_id]
		var start := int(numbers.get("start", 0))
		var end := int(numbers.get("end", 0))
		if start == 0 and end == 0 and int(numbers.get("died", 0)) == 0:
			continue
		parts.append("%s%s%d%s(%s)" % [HudTextScript.animals_label(str(species_id)), NBSP, end, NBSP,
			HudTextScript.signed(end - start)])
	return HudTextScript.capitalized(" · ".join(parts))


## «Родились: 74 оленёнка, 12 лисят, 40 птенцов».
static func births_line(summary: Dictionary) -> String:
	var parts: Array = []
	var species: Dictionary = summary.get("species", {})
	for species_id in ordered(species.keys()):
		var births := int(species[species_id].get("births", 0))
		if births > 0:
			parts.append(HudTextScript.animal_count(str(species_id), births, true).replace(" ", NBSP))
	return "" if parts.is_empty() else "Родились: %s" % ", ".join(parts)


## «Погибли: хищники — 31, голод — 9, жажда — 4, старость — 12»: every species together, by cause.
static func deaths_line(summary: Dictionary) -> String:
	var totals := {}
	var species: Dictionary = summary.get("species", {})
	for species_id in species.keys():
		var deaths: Dictionary = species[species_id].get("deaths", {})
		for cause in deaths.keys():
			totals[str(cause)] = int(totals.get(str(cause), 0)) + int(deaths[cause])
	var parts: Array = []
	for cause in CAUSE_ORDER:
		var count := int(totals.get(cause, 0))
		if count > 0:
			parts.append("%s%s—%s%d" % ["хищники" if cause == "predation" else HudTextScript.cause_label(cause), NBSP,
				NBSP, count])
	return "" if parts.is_empty() else "Погибли: %s" % ", ".join(parts)


## «Лучший охотник: лис Рыжик — 5 добыч», «Лучшая охотница: лиса Огнёвка — 3 добычи».
static func hunter_line(summary: Dictionary) -> String:
	var hunter: Dictionary = summary.get("hunter", {})
	if hunter.is_empty():
		return ""
	var sex := str(hunter.get("sex", ""))
	var kills := int(hunter.get("kills", 0))
	var noun := HudTextScript.animal_noun(str(hunter.get("species", "")), sex) if str(hunter.get("species", "")) != "" else ""
	var who := str(hunter.get("name", ""))
	if noun != "":
		who = "%s %s" % [noun, who]
	return "%s: %s%s—%s%d%s%s" % [HudTextScript.verb(sex, "Лучший охотник", "Лучшая охотница"), who, NBSP, NBSP,
		kills, NBSP, HudTextScript.plural(kills, ["добыча", "добычи", "добыч"])]


## The ponds that dried - «Пересохла Тихая заводь», «Пересохли Тихая заводь и Кривой брод»,
## «Пересохли Тихая заводь, Кривой брод и ещё 3 водоёма» - or that filled again: «Снова с
## водой: Тихая заводь, Кривой брод и ещё 29 водоёмов». `genders` is the summary's.
static func ponds_line(names: Array, genders: Dictionary, dried: bool) -> String:
	if names.is_empty():
		return ""
	var listed := names_list(names)
	if not dried:
		return "Снова с водой: %s" % listed
	if names.size() == 1:
		var gender := str(genders.get(str(names[0]), "m"))
		return "%s %s" % [HudTextScript.verb3(gender, "Пересох", "Пересохла", "Пересохло"), listed]
	return "Пересохли %s" % listed


## «А», «А и Б», «А, Б и В», «А, Б и ещё 3 водоёма».
static func names_list(names: Array) -> String:
	var kept: Array = []
	for name in names:
		kept.append(str(name).replace(" ", NBSP))
	if kept.size() <= 1:
		return "" if kept.is_empty() else str(kept[0])
	if kept.size() <= PONDS_NAMED + 1:
		var head: Array = kept.slice(0, kept.size() - 1)
		return "%s и %s" % [", ".join(head), str(kept.back())]
	var rest := kept.size() - PONDS_NAMED
	return "%s и ещё %d%s%s" % [", ".join(kept.slice(0, PONDS_NAMED)), rest, NBSP,
		HudTextScript.plural(rest, ["водоём", "водоёма", "водоёмов"])]


## `species_ids` in `SPECIES_ORDER`, any other after them as given.
static func ordered(species_ids: Array) -> Array:
	var result: Array = []
	for species_id in SPECIES_ORDER:
		if species_ids.has(species_id):
			result.append(species_id)
	for species_id in species_ids:
		if not result.has(species_id):
			result.append(species_id)
	return result
