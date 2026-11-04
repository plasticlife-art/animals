class_name TraitHistory
extends RefCounted

## The inherited traits of each species over the whole life of the world, for the chronicle's
## «Черты» and «Выводы»: a point every `interval` simulated seconds with each species' means,
## read off the stats snapshot (`trait_<name>_<species>`), and beside them what the family tree
## (`Lineage`) knows of the living - how widely each trait is spread and how many there are - and
## a tally of who left young and who died of what since the point before, with the sums of their
## traits. The charts' own series keeps the last minutes, and a trait moves over generations, so
## this keeps everything: out of room, it drops every other point, folding the dropped point's
## tallies into the next, and samples half as often, and a world of any age fits in `MAX_POINTS`.
## Main thread only, kept with the story; nothing here reaches the simulation.

const TraitsScript := preload("res://scripts/agents/traits.gd")
const MAX_POINTS := 480
const START_INTERVAL := 30.0
## The least a chart's scale reaches either side of 1.0, so founders' noise is not drawn as a
## cliff.
const MIN_SPAN := 0.05
## A histogram's buckets across the widest clamp (`Traits.DEFAULTS.clamp`) either side of 1.0.
const BINS := 25
const BIN_REACH := 0.25
## The tally's groups: the parents of the young born (each parent once for each of its young),
## and the dead by cause (`SeasonLedger.CAUSES`).
const PARENTS := "parents"

var interval: float = START_INTERVAL
## `[{time, values: {species: [means]}, spread: {species: [deviations]}, counts: {species: n},
## tallies: {species: {group: [sums..., count]}}}]`, oldest first; the means one per
## `Traits.NAMES`, fewer in a point saved before a trait was added. `spread` and `tallies` are
## missing from points saved before they were kept.
var points: Array = []
## Each species' traits when the history began, as histograms (`{species: [[BINS counts] per
## trait]}`): the founders, against whom the living are drawn. Empty for a world saved without.
var founders: Dictionary = {}
var _next_at: float = 0.0
## Tallies heard since the last point (`{species: {group: [sums..., count]}}`).
var _pending: Dictionary = {}


## Takes a point from `metrics`, a stats snapshot, when the next is due, for `species_ids` - the
## species with heredity. One with nobody left is skipped: its mean would read 1.0. `lineage`,
## when given, adds how widely each trait is spread among the living it knows.
func sample(now: float, metrics: Dictionary, species_ids: Array, lineage = null) -> void:
	if now < _next_at or metrics.is_empty() or species_ids.is_empty():
		return
	var values := {}
	var counts := {}
	for species_id in species_ids:
		var population := int(metrics.get("%s_population" % species_id, 0))
		if population <= 0 or not metrics.has("trait_speed_%s" % species_id):
			continue
		var means: Array = []
		for trait_name in TraitsScript.NAMES:
			means.append(float(metrics.get("trait_%s_%s" % [trait_name, species_id], 1.0)))
		values[species_id] = means
		counts[species_id] = population
	var point := {"time": now, "values": values, "counts": counts, "tallies": _pending}
	_pending = {}
	if lineage != null:
		var living := living_traits(lineage, values.keys())
		var spread := {}
		for species_id in living.keys():
			spread[species_id] = deviations(living[species_id])
		point["spread"] = spread
		if points.is_empty() and founders.is_empty():
			for species_id in living.keys():
				founders[species_id] = histograms(living[species_id])
	points.append(point)
	_next_at = now + interval
	if points.size() > MAX_POINTS:
		var kept: Array = []
		for index in range(0, points.size(), 2):
			if index > 0:
				# What the dropped point heard happened before the one kept after it.
				points[index]["tallies"] = points[index].get("tallies", {})
				_fold(points[index - 1].get("tallies", {}), points[index]["tallies"])
			kept.append(points[index])
		if points.size() % 2 == 0:
			_fold(points[-1].get("tallies", {}), _pending)
		points = kept
		interval *= 2.0


## A young one of `species` born to parents with these traits (one array each, a missing parent
## left out): each parent counts once towards the next point's tally.
func hear_birth(species: String, parents_traits: Array) -> void:
	for traits in parents_traits:
		_add(species, PARENTS, traits)


## One of `species` dead of `cause`, with its traits.
func hear_death(species: String, cause: String, traits) -> void:
	if cause != "":
		_add(species, cause, traits)


## How far either side of 1.0 a chart of trait `index` has to reach to hold every point, for
## `species_id` or, empty, for every species.
func span(index: int, species_id := "") -> float:
	var reach := MIN_SPAN
	for point in points:
		var values: Dictionary = point["values"]
		for key in values.keys():
			if species_id != "" and key != species_id:
				continue
			var means: Array = values[key]
			if index < means.size():
				reach = maxf(reach, absf(float(means[index]) - 1.0) * 1.15)
	return reach


## The latest means of `species_id`, or none.
func latest(species_id: String) -> Array:
	for position in range(points.size() - 1, -1, -1):
		var values: Dictionary = points[position]["values"]
		if values.has(species_id):
			return values[species_id]
	return []


## The latest spread of `species_id` (`deviations()`), or none.
func latest_spread(species_id: String) -> Array:
	for position in range(points.size() - 1, -1, -1):
		var spread: Dictionary = points[position].get("spread", {})
		if spread.has(species_id):
			return spread[species_id]
	return []


## How a `group`'s traits (`PARENTS` or a cause) differed from the living's over the points after
## `from_time`: `{diff, count}`, `diff` the mean of trait `index` among them less the living's mean
## at each point, weighted by how many each point heard. `count` 0 when none were heard.
func differential(species_id: String, group: String, index: int, from_time := -INF) -> Dictionary:
	var total := 0.0
	var living := 0.0
	var count := 0
	for point in points:
		if float(point["time"]) <= from_time:
			continue
		var means: Array = point["values"].get(species_id, [])
		var tally: Array = point.get("tallies", {}).get(species_id, {}).get(group, [])
		if index >= means.size() or tally.size() != TraitsScript.NAMES.size() + 1:
			continue
		var heard := int(tally[-1])
		if heard <= 0:
			continue
		total += float(tally[index])
		living += float(means[index]) * heard
		count += heard
	return {"diff": 0.0 if count == 0 else (total - living) / float(count), "count": count}


## The mean spread of trait `index` in `species_id` over the points after `from_time`, 0 when no
## point knew it.
func mean_spread(species_id: String, index: int, from_time := -INF) -> float:
	var total := 0.0
	var known := 0
	for point in points:
		if float(point["time"]) <= from_time:
			continue
		var spread: Array = point.get("spread", {}).get(species_id, [])
		if index < spread.size():
			total += float(spread[index])
			known += 1
	return 0.0 if known == 0 else total / float(known)


func clear() -> void:
	interval = START_INTERVAL
	points.clear()
	founders.clear()
	_pending = {}
	_next_at = 0.0


func export_state() -> Dictionary:
	return {"interval": interval, "points": points.duplicate(true), "next_at": _next_at,
		"founders": founders.duplicate(true), "pending": _pending.duplicate(true)}


func import_state(data: Dictionary) -> void:
	clear()
	interval = maxf(START_INTERVAL, float(data.get("interval", START_INTERVAL)))
	points = data.get("points", []).duplicate(true)
	_next_at = float(data.get("next_at", 0.0))
	founders = data.get("founders", {}).duplicate(true)
	_pending = data.get("pending", {}).duplicate(true)


## The traits of every living animal of `species_ids` the family tree knows them for:
## `{species: [traits arrays]}`. One told before the marker has four, and stands for none there.
static func living_traits(lineage, species_ids: Array) -> Dictionary:
	var living := {}
	for species_id in species_ids:
		living[str(species_id)] = []
	var animals: Dictionary = lineage.animals()
	for agent_id in animals:
		var entry: Dictionary = animals[agent_id]
		if float(entry["died"]) >= 0.0 or not entry.has("traits"):
			continue
		var species := str(entry["species"])
		if living.has(species):
			living[species].append(entry["traits"])
	return living


## The standard deviation of each trait among `traits_list`, one per `Traits.NAMES`; 0 for a
## trait fewer than two animals know.
static func deviations(traits_list: Array) -> Array:
	var out: Array = []
	for index in range(TraitsScript.NAMES.size()):
		var sum := 0.0
		var squares := 0.0
		var known := 0
		for traits in traits_list:
			if index >= traits.size():
				continue
			var value := float(traits[index])
			sum += value
			squares += value * value
			known += 1
		if known < 2:
			out.append(0.0)
			continue
		var mean := sum / float(known)
		out.append(sqrt(maxf(0.0, squares / float(known) - mean * mean)))
	return out


## One histogram per trait of `traits_list`: `BINS` counts across 1.0 ± `BIN_REACH`, the edges
## holding what lies beyond.
static func histograms(traits_list: Array) -> Array:
	var out: Array = []
	for index in range(TraitsScript.NAMES.size()):
		var bins: Array = []
		bins.resize(BINS)
		bins.fill(0)
		for traits in traits_list:
			if index < traits.size():
				bins[bin_of(float(traits[index]))] += 1
		out.append(bins)
	return out


static func bin_of(value: float) -> int:
	return clampi(floori((value - 1.0 + BIN_REACH) / (2.0 * BIN_REACH) * float(BINS)), 0, BINS - 1)


func _add(species: String, group: String, traits) -> void:
	if traits == null or traits.size() < 4:
		return
	var known: Array = TraitsScript.padded(traits)
	var by_group: Dictionary = _pending.get(species, {})
	var tally: Array = by_group.get(group, [])
	if tally.size() != known.size() + 1:
		tally = TraitsScript.zeros()
		tally.append(0)
	for index in range(known.size()):
		tally[index] = float(tally[index]) + float(known[index])
	tally[-1] = int(tally[-1]) + 1
	by_group[group] = tally
	_pending[species] = by_group


## Adds the tallies of `from` into `into`, both `{species: {group: [sums..., count]}}`.
static func _fold(from: Dictionary, into: Dictionary) -> void:
	for species in from.keys():
		var target: Dictionary = into.get(species, {})
		for group in from[species].keys():
			var source: Array = from[species][group]
			var tally: Array = target.get(group, [])
			if tally.size() != source.size():
				target[group] = source.duplicate()
				continue
			for index in range(source.size()):
				tally[index] = tally[index] + source[index]
		into[species] = target
