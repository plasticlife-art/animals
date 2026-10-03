class_name EcologyReadout
extends RefCounted

## What the ecology strip says, worked out from the stats snapshots and kept apart from
## the drawing so it can be tested: per species how many there are and which way the
## number is going, how many are close to starving or to dying of thirst, how many were
## killed lately; per biome how much of its grass is left. Each figure also gets a level -
## fine, worth a look, bad - that the strip colours it by.
##
## Everything is read from what the snapshots already carry
## (`<species>_population`, `starvation_risk_<species>_count`,
## `thirst_risk_<species>_count`, the cumulative `deaths_predation_<species>`,
## `grass_biomass_by_biome`); nothing here asks the world anything but the grass caps,
## once per world.

enum Level { GOOD, WARN, BAD }

## How far back "lately" reaches, in simulated seconds: the trend and the kills compare
## the newest snapshot with the one this long before it.
const WINDOW_SECONDS := 60.0
## A population that moved by less than this share (and less than two animals) holds steady.
const TREND_DEAD_BAND := 0.03
## Share of a species close to starving or to dying of thirst: worth a look, then bad.
const RISK_WARN := 0.10
const RISK_BAD := 0.25
## Share of a species killed per minute.
const KILLS_WARN := 0.02
const KILLS_BAD := 0.05
## Share of a biome's grass left: below these it is worth a look, then bad. A world starts
## at about 0.47; over 96-minute runs on four seeds the whole map's share stayed between
## 0.21 and 0.71 and mostly between 0.3 and 0.5, dipping in winter.
const GRASS_WARN := 0.3
const GRASS_BAD := 0.18


## The newest snapshot taken at least `window` seconds before `latest`, or the oldest
## there is while the series is still shorter than that; empty with nothing to compare.
static func reference_sample(series: Array, latest: Dictionary, window := WINDOW_SECONDS) -> Dictionary:
	if series.is_empty() or latest.is_empty():
		return {}
	var cutoff: float = float(latest.get("time_seconds", 0.0)) - window
	# From the newest back: a minute is about sixty samples, the whole series over a thousand.
	var found: Dictionary = series[0]
	for index in range(series.size() - 1, -1, -1):
		if float(series[index].get("time_seconds", 0.0)) <= cutoff:
			found = series[index]
			break
	return {} if int(found.get("tick", -1)) == int(latest.get("tick", -2)) else found


## +1 rising, -1 falling, 0 holding, from `before` to `now`.
static func trend(now: float, before: float) -> int:
	var band := maxf(2.0, absf(before) * TREND_DEAD_BAND)
	if now - before >= band:
		return 1
	if before - now >= band:
		return -1
	return 0


static func level_of(value: float, warn: float, bad: float) -> int:
	if value >= bad:
		return Level.BAD
	if value >= warn:
		return Level.WARN
	return Level.GOOD


## How much of what it can hold a biome is short of, as a level: the lower, the worse.
static func grass_level(share: float) -> int:
	if share < GRASS_BAD:
		return Level.BAD
	if share < GRASS_WARN:
		return Level.WARN
	return Level.GOOD


## One row per species in `species_ids`: `population`, `trend`, `hungry`, `thirsty`,
## `kills` since `reference` and over `minutes`, and a level for each of the last three.
static func species_rows(snapshot: Dictionary, reference: Dictionary, species_ids: Array) -> Array:
	var minutes := 0.0
	if not reference.is_empty():
		minutes = maxf(0.0, float(snapshot.get("time_seconds", 0.0)) - float(reference.get("time_seconds", 0.0))) / 60.0
	var rows: Array = []
	for species_id in species_ids:
		var population := int(snapshot.get("%s_population" % species_id, 0))
		var hungry := int(snapshot.get("starvation_risk_%s_count" % species_id, 0))
		var thirsty := int(snapshot.get("thirst_risk_%s_count" % species_id, 0))
		var kills := 0
		var direction := 0
		if not reference.is_empty():
			kills = maxi(0, int(snapshot.get("deaths_predation_%s" % species_id, 0))
				- int(reference.get("deaths_predation_%s" % species_id, 0)))
			direction = trend(float(population), float(reference.get("%s_population" % species_id, population)))
		var whole := float(maxi(1, population))
		var kills_per_minute: float = 0.0 if minutes <= 0.0 else float(kills) / minutes
		rows.append({
			"id": str(species_id), "population": population, "trend": direction,
			"hungry": hungry, "thirsty": thirsty, "kills": kills, "minutes": minutes,
			"hungry_level": level_of(float(hungry) / whole, RISK_WARN, RISK_BAD),
			"thirsty_level": level_of(float(thirsty) / whole, RISK_WARN, RISK_BAD),
			"kills_level": level_of(kills_per_minute / whole, KILLS_WARN, KILLS_BAD),
		})
	return rows


## How much grass each biome can hold at most: the caps of its walkable cells, summed.
## Caps do not change during a run, so this is worked out once per world.
static func capacity_by_biome(resource_system, terrain_system) -> Dictionary:
	var capacity: Dictionary = {}
	if resource_system == null or terrain_system == null:
		return capacity
	var caps: PackedFloat32Array = resource_system.export_caps()
	for index in range(caps.size()):
		if caps[index] <= 0.0:
			continue
		var biome: String = terrain_system.get_biome_at_index(index)
		capacity[biome] = float(capacity.get(biome, 0.0)) + caps[index]
	return capacity


## One entry per biome in `order` that has grass at all: `id`, `share` of its capacity
## left and its level.
static func grass_rows(snapshot: Dictionary, capacity: Dictionary, order: Array) -> Array:
	var biomass: Dictionary = snapshot.get("grass_biomass_by_biome", {})
	var rows: Array = []
	for biome in order:
		var most := float(capacity.get(biome, 0.0))
		if most <= 0.0:
			continue
		var share := clampf(float(biomass.get(biome, 0.0)) / most, 0.0, 1.0)
		rows.append({"id": str(biome), "share": share, "level": grass_level(share)})
	return rows
