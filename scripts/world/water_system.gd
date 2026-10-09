class_name WaterSystem
extends RefCounted

## Watering holes that fill and dry. Each pond holds a level, 0 to 1 of its basin: spring rains
## fill it, summer takes it down, and whoever drinks there drinks it down too. A small pond a
## herd drinks from dries by late summer, the others shrink; about one year in four is a
## drought year, its summer harsher, when small ponds dry on their own and many more with them.
## Autumn and winter rains fill them again, so the dry spell runs from late summer into early
## autumn: left dry through the winter, the ponds still wet drew every herd and were drunk dry
## in turn.
##
## The level moves by the season's balance (`balance`, per season id, eased between seasons
## as the climate's multipliers are; a drought year multiplies its losses by
## `drought_strength`) faster the smaller the pond (`(R̄ / R) ^ size_exponent`), and by what is
## drunk against the pond's capacity in thirst points: `capacity_seasons` times the thirst of
## one starting herd in a season (or the map's thirst per pond, if more), scaled with the
## pond's size (`(R / R̄) ^ capacity_exponent`) - so a pond lasts about as long on every map
## size and difficulty, whatever their radii and thirst rates.
##
## A pond keeps its `bank_radius` and `index`; its `radius` - what every drinker, query and
## drawing reads - is the water's edge, `bank_radius * sqrt(level)`. It counts as dry at
## `dry_level` and wet again only at `wet_level`, so a pond at the brink does not flicker; each
## change is kept in `transitions` for the world to tell. Nothing is drawn from the world's
## rng: the drought years are a hash of the year and the world's seed. Off (`world.water_levels`,
## or the climate off) the ponds never change.

const TraitsScript := preload("res://scripts/agents/traits.gd")
const DROUGHT_SALT := 0xD4A09000
const DEFAULTS := {
	"enabled": false,
	"balance": {"spring": 2.0, "summer": -0.6, "autumn": 0.2, "winter": 0.6},
	"capacity_seasons": 6.0,
	"size_exponent": 2.0,
	"capacity_exponent": 3.0,
	"dry_level": 0.02,
	"wet_level": 0.10,
	"drought_chance": 0.25,
	"drought_strength": 1.4,
}

var enabled: bool = false
var settings: Dictionary = {}
var levels := PackedFloat32Array()
var dry := PackedByteArray()
var capacity := PackedFloat32Array()
var size_factor := PackedFloat32Array()
var mean_radius: float = 0.0
## The thirst a pond of mean size is measured against, kept for the ponds added later
## (`add_source()`): measured against the same, the ponds the world began with keep theirs.
var demand_unit: float = 1.0
var season_length: float = 120.0
var world_seed: int = 0
## `[index, "dried" | "refilled"]` since the world last took them.
var transitions: Array = []
var _sources: Array = []
var _index_by_position: Dictionary = {}
var _wet_count: int = 0


## `sources` are the world's ponds (`WorldState.water_sources`), given their `index` and
## `bank_radius` here whether or not levels are on. `demand_unit_value` is the thirst, in points,
## a pond of mean size is measured against (`WorldState._water_demand_unit()`).
func initialize(water_config: Dictionary, sources: Array, demand_unit_value: float, season_seconds: float,
		clock_running: bool, seed_value: int) -> void:
	settings = DEFAULTS.duplicate(true)
	for key in water_config.keys():
		if key == "balance" and water_config[key] is Dictionary:
			var balance: Dictionary = settings["balance"].duplicate()
			balance.merge(water_config[key], true)
			settings["balance"] = balance
		else:
			settings[key] = water_config[key]
	enabled = bool(settings["enabled"]) and clock_running and not sources.is_empty()
	season_length = maxf(0.001, season_seconds)
	world_seed = seed_value
	demand_unit = maxf(1.0, demand_unit_value)
	_sources = sources
	_index_by_position.clear()
	levels = PackedFloat32Array()
	dry = PackedByteArray()
	capacity = PackedFloat32Array()
	size_factor = PackedFloat32Array()
	transitions.clear()
	var radius_sum := 0.0
	for index in range(sources.size()):
		var source: Dictionary = sources[index]
		source["index"] = index
		source["bank_radius"] = float(source.get("radius", 0.0))
		_index_by_position[source["position"]] = index
		radius_sum += float(source["bank_radius"])
	mean_radius = radius_sum / float(maxi(1, sources.size()))
	var reference := maxf(1.0, mean_radius)
	for source in sources:
		var relative := maxf(0.01, float(source["bank_radius"]) / reference)
		levels.append(1.0)
		dry.append(0)
		capacity.append(_capacity_for(relative))
		size_factor.append(pow(1.0 / relative, float(settings["size_exponent"])))
	_wet_count = sources.size()


## A pond added while the world runs (`WorldState._add_pond_source()`), already appended to the
## world's list - which is this system's own: given its `index`, measured against the mean and
## the demand the map began with, so no other pond's capacity moves, and filled to `level`.
func add_source(source: Dictionary, level: float) -> void:
	var index := levels.size()
	assert(_sources.size() == index + 1 and _sources[index] == source, "append the pond to the world's list first")
	source["index"] = index
	source["bank_radius"] = float(source.get("bank_radius", source.get("radius", 0.0)))
	_index_by_position[source["position"]] = index
	var relative := maxf(0.01, float(source["bank_radius"]) / maxf(1.0, mean_radius))
	levels.append(clampf(level, 0.0, 1.0))
	dry.append(1 if levels[index] <= float(settings["dry_level"]) else 0)
	capacity.append(_capacity_for(relative))
	size_factor.append(pow(1.0 / relative, float(settings["size_exponent"])))
	if dry[index] == 0:
		_wet_count += 1
	_set_shore(index)


func _capacity_for(relative: float) -> float:
	return maxf(1.0, float(settings["capacity_seasons"]) * demand_unit * pow(relative, float(settings["capacity_exponent"])))


## One tick: the season's balance on every pond. `climate` is the world's `Climate`, sampled.
func step(delta: float, climate) -> void:
	if not enabled:
		return
	var balance: float = climate.blend_by_season(settings["balance"])
	if balance < 0.0 and is_drought_year(climate.year):
		balance *= float(settings["drought_strength"])
	var rate := balance / season_length * delta
	if rate == 0.0:
		return
	for index in range(levels.size()):
		var next := clampf(levels[index] + rate * size_factor[index], 0.0, 1.0)
		if next != levels[index]:
			levels[index] = next
			_settle(index)


## What a drinker that wants `wanted` thirst points takes from pond `index`: all of it while
## the pond holds that much, what is left otherwise, nothing from a dry one.
func drink(index: int, wanted: float) -> float:
	if not enabled or index < 0 or index >= levels.size() or wanted <= 0.0:
		return maxf(0.0, wanted) if not enabled else 0.0
	if dry[index] != 0:
		return 0.0
	var granted := minf(wanted, levels[index] * capacity[index])
	levels[index] = maxf(0.0, levels[index] - granted / capacity[index])
	_settle(index)
	return granted


func is_dry(index: int) -> bool:
	return enabled and index >= 0 and index < dry.size() and dry[index] != 0


## The pond at exactly `position` (a pond's centre, as goals and memories hold it), or -1.
func index_at(position: Vector2) -> int:
	return int(_index_by_position.get(position, -1))


## The nearest pond that is not dry, or {} when every one is.
func nearest_wet(position: Vector2) -> Dictionary:
	var best: Dictionary = {}
	var best_distance_sq := INF
	for index in range(_sources.size()):
		if dry[index] != 0:
			continue
		var distance_sq: float = position.distance_squared_to(_sources[index]["position"])
		if distance_sq < best_distance_sq:
			best_distance_sq = distance_sq
			best = _sources[index]
	return best


func wet_count() -> int:
	return _wet_count if enabled else _sources.size()


func dry_count() -> int:
	return _sources.size() - wet_count()


func mean_level() -> float:
	if levels.is_empty():
		return 1.0
	var total := 0.0
	for value in levels:
		total += value
	return total / float(levels.size())


## Whether `year` is a drought year: a hash of the year and the world's seed, never the first.
func is_drought_year(year: int) -> bool:
	return year > 0 and TraitsScript.unit(year, DROUGHT_SALT, world_seed) < float(settings["drought_chance"])


## The changes since the last call, handed over once.
func take_transitions() -> Array:
	var taken := transitions
	transitions = []
	return taken


func export_state() -> Dictionary:
	return {"levels": levels.duplicate(), "dry": dry.duplicate()}


## A save's levels, or a worker frame's; a save from before there were any keeps every pond
## full. Levels for another number of ponds than this world has are not applied, and said so:
## the ponds the player dug must be in place first (`WorldState._add_pond_source()`).
func import_state(data: Dictionary) -> void:
	var saved_levels = data.get("levels", null)
	var saved_dry = data.get("dry", null)
	if saved_levels == null or saved_dry == null:
		return
	if saved_levels.size() != levels.size() or saved_dry.size() != dry.size():
		push_warning("Water levels for %d ponds, this world has %d; not applied." % [saved_levels.size(), levels.size()])
		return
	levels = PackedFloat32Array(saved_levels)
	dry = PackedByteArray(saved_dry)
	_wet_count = 0
	for index in range(levels.size()):
		if dry[index] == 0:
			_wet_count += 1
		_set_shore(index)


## The water's edge and the dry/wet state after the level moved.
func _settle(index: int) -> void:
	_set_shore(index)
	if dry[index] == 0 and levels[index] <= float(settings["dry_level"]):
		dry[index] = 1
		_wet_count -= 1
		transitions.append([index, "dried"])
	elif dry[index] != 0 and levels[index] >= float(settings["wet_level"]):
		dry[index] = 0
		_wet_count += 1
		transitions.append([index, "refilled"])


func _set_shore(index: int) -> void:
	var source: Dictionary = _sources[index]
	source["radius"] = float(source["bank_radius"]) * sqrt(maxf(0.0, levels[index]))
