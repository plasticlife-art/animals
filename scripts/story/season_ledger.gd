class_name SeasonLedger
extends RefCounted

## What each season did, for the season card and the chronicle's «Сезоны»: how many of each
## species there were when it began and ended, how many were born and how many died of what,
## who hunted best, which ponds dried and which filled again, and whether it was a drought year.
##
## The season open now counts every event the story hears (`hear()`); the story asks it on every
## tick (`observe()`), and when the clock has moved into another season it closes this one - with
## the numbers counted as the world stands at that tick, the best hunter and the ponds named as
## strings, since names are given back when animals die - and opens the next. A season the
## ledger did not see from its start (a world loaded without one) is `partial`. Main thread only,
## kept with the story; nothing here reaches the simulation.

const ClimateScript := preload("res://scripts/world/climate.gd")
## Closed seasons kept: fifty years.
const MAX_SEASONS := 200
const CAUSES := ["predation", "starvation", "thirst", "old_age"]

## The season being counted: `{ordinal, start, partial, populations, births, deaths, kills,
## dried, refilled}`; empty before the first `observe()` or with the clock off.
var open: Dictionary = {}
## Closed seasons, oldest first (`close()` describes one).
var closed: Array = []


func clear() -> void:
	open = {}
	closed.clear()


## Counts an event towards the open season.
func hear(event: Dictionary) -> void:
	if open.is_empty():
		return
	var data: Dictionary = event.get("data", {})
	var species := str(event.get("species", ""))
	match str(event.get("type", "")):
		"AgentBorn":
			if str(data.get("reason", "")) in ["reproduction", "dormant"]:
				var births: Dictionary = open["births"]
				births[species] = int(births.get(species, 0)) + 1
		"AgentDied":
			var deaths: Dictionary = open["deaths"]
			var by_cause: Dictionary = deaths.get(species, {})
			var cause := str(data.get("cause", ""))
			by_cause[cause] = int(by_cause.get(cause, 0)) + 1
			deaths[species] = by_cause
			# The hunter, awake (`other_agent_id`) or credited asleep (`killer_record_id`), as
			# `StoryBook.killer_of()` reads it.
			var killer := -1
			if cause == "predation":
				killer = int(event.get("other_agent_id", -1))
				if killer < 0:
					killer = int(data.get("killer_record_id", -1))
			if killer >= 0:
				var kills: Dictionary = open["kills"]
				kills[killer] = int(kills.get(killer, 0)) + 1
		"PondDried":
			open["dried"].append(int(data.get("index", -1)))
		"PondRefilled":
			open["refilled"].append(int(data.get("index", -1)))


## Closes the open season when `now` has moved into another and opens that one; returns the
## closed season, or {} - also before anything was open, when this only opens the season.
## `manager` gives the clock's config and the world's numbers, `book` the names.
func observe(now: float, manager, book) -> Dictionary:
	var climate_config: Dictionary = manager.config_bundle.get("world", {}).get("climate", {})
	var ordinal := ClimateScript.season_ordinal(climate_config, now)
	if ordinal < 0:
		return {}
	if open.is_empty():
		_open(ordinal, now, populations_of(manager), not _at_season_start(climate_config, ordinal, now, manager))
		return {}
	if ordinal == int(open["ordinal"]):
		return {}
	var summary := close(now, manager, book)
	_open(ordinal, now, summary["species_end"], false)
	return summary


## The open season as it stands at `now`, closed: `{ordinal, year, season_id, label, start, end,
## partial, drought, species: {id: {start, end, births, deaths: {cause: n}, died}}, species_end,
## hunter: {id, name, species, sex, kills} or {}, dried: [names], refilled: [names],
## genders: {pond name: "m" | "f" | "n"}}`. `drought` only for a season a drought year makes
## harsher: one whose water balance is a loss.
func close(now: float, manager, book) -> Dictionary:
	var summary := preview(now, manager, book)
	closed.append(summary)
	while closed.size() > MAX_SEASONS:
		closed.pop_front()
	return summary


## The open season so far, as `close()` would give it at `now`, left open; {} when none is.
func preview(now: float, manager, book) -> Dictionary:
	if open.is_empty():
		return {}
	var climate_config: Dictionary = manager.config_bundle.get("world", {}).get("climate", {})
	var calendar := ClimateScript.calendar(climate_config)
	var per_year := maxi(1, int(calendar[1]))
	var ordinal := int(open["ordinal"])
	var index := posmod(ordinal, per_year)
	var year := floori(float(ordinal) / float(per_year))
	var seasons: Array = climate_config.get("seasons", [])
	var season: Dictionary = seasons[index] if index < seasons.size() else {}
	var ends := populations_of(manager)
	var starts: Dictionary = open["populations"]
	var species := {}
	for species_id in _union(starts.keys(), ends.keys()):
		var deaths: Dictionary = open["deaths"].get(species_id, {})
		var died := 0
		for cause in deaths.keys():
			died += int(deaths[cause])
		species[species_id] = {"start": int(starts.get(species_id, 0)), "end": int(ends.get(species_id, 0)),
			"births": int(open["births"].get(species_id, 0)), "deaths": deaths.duplicate(), "died": died}
	var water = manager.world_state.water if manager.world_state != null else null
	var season_id := str(season.get("id", ""))
	var drought: bool = water != null and water.enabled and water.is_drought_year(year) \
		and float(water.settings["balance"].get(season_id, 0.0)) < 0.0
	var genders := {}
	return {
		"ordinal": ordinal, "year": year, "season_id": season_id,
		"label": str(season.get("label", season_id)), "start": float(open["start"]), "end": now,
		"partial": bool(open["partial"]), "drought": drought,
		"species": species, "species_end": ends, "hunter": _best_hunter(open["kills"], book),
		"dried": _pond_names(open["dried"], book, genders), "refilled": _pond_names(open["refilled"], book, genders),
		"genders": genders,
	}


## Each species' count as the world stands: `{id: n}`, asleep and awake.
static func populations_of(manager) -> Dictionary:
	var counts := {}
	if manager == null or manager.world_state == null:
		return counts
	var metrics: Dictionary = manager.world_state.get_population_metrics()
	for species_id in manager.world_state.species_registry.ids():
		counts[str(species_id)] = int(metrics.get("%s_count" % species_id, 0))
	return counts


func export_state() -> Dictionary:
	return {"open": open.duplicate(true), "closed": closed.duplicate(true)}


func import_state(data: Dictionary) -> void:
	clear()
	open = data.get("open", {}).duplicate(true)
	closed = data.get("closed", []).duplicate(true)


func _open(ordinal: int, now: float, populations: Dictionary, partial: bool) -> void:
	open = {"ordinal": ordinal, "start": now, "partial": partial, "populations": populations.duplicate(),
		"births": {}, "deaths": {}, "kills": {}, "dried": [], "refilled": []}


## Whether `now` is the first tick of season `ordinal`: a season opened later was not seen whole.
static func _at_season_start(climate_config: Dictionary, ordinal: int, now: float, manager) -> bool:
	var season_length := float(ClimateScript.calendar(climate_config)[0])
	var started := float(ordinal) * season_length - float(int(climate_config.get("start_season_index", 0))) * season_length
	return now - started <= float(manager.tick_duration) * 1.5


static func _best_hunter(kills: Dictionary, book) -> Dictionary:
	var best := -1
	var most := 0
	for hunter in kills.keys():
		var count := int(kills[hunter])
		if count > most or (count == most and int(hunter) < best):
			best = int(hunter)
			most = count
	if best < 0:
		return {}
	var entry: Dictionary = {} if book == null else book.lineage.entry(best)
	return {"id": best, "name": "" if book == null else book.name_of_id(best), "kills": most,
		"species": str(entry.get("species", "")), "sex": str(entry.get("sex", ""))}


## The ponds' names, once each, in the order they first changed; each name's gender goes into
## `genders` for the verb that agrees with it.
static func _pond_names(indices: Array, book, genders: Dictionary) -> Array:
	var names: Array = []
	for index in indices:
		var name := "водоём №%d" % int(index)
		var gender := "m"
		if book != null and book.places != null and int(index) >= 0 and int(index) < book.places.ponds.size():
			var pond: Dictionary = book.places.ponds[int(index)]
			name = str(pond["name"])
			gender = str(pond.get("gender", "m"))
		if not names.has(name):
			names.append(name)
			genders[name] = gender
	return names


static func _union(first: Array, second: Array) -> Array:
	var all: Array = first.duplicate()
	for key in second:
		if not all.has(key):
			all.append(key)
	return all
