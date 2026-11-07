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
## drawing reads - is the water's edge, `bank_radius * sqrt(level)`.
##
## A lake or a marsh (`WaterBodies`) is several round lobes, each a source of its own, sharing
## one body (`body` on each): one level, capacity and dry state for them all, measured by the
## body's area as a round pond of that area would be. Its water's edge stands in from every lobe's
## bank by the same `(R - R * sqrt(level))`, R its largest lobe's bank - what a round pond of R
## loses - so the narrow bays and arms go dry first and the deep basin last; a lobe left with no
## water counts as dry while the rest of its body holds water. A lake (`kind` "lake") never falls
## below `lake_floor`: springs feed it, and at the floor it gives what is asked. A pond on its own
## is a body of one lobe, as every pond was before. It counts as dry at
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
	# Years that are droughts whatever the hash says, the first among them if named - a
	# scenario's (`scenarios.json`); none by default.
	"drought_years": [],
	# How full the ponds start, 0 to 1; a scenario may start them low.
	"initial_level": 1.0,
	# The lowest a lake (`WaterBodies`, kind "lake") falls; 0 lets it dry like a pond.
	"lake_floor": 0.0,
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
## Each source's body, and each body's lobes, its largest first (its anchor).
var body_of := PackedInt32Array()
var _bodies: Array = []
## Per body: its largest lobe's bank, and the level it never falls below.
var _body_bank := PackedFloat32Array()
var _body_floor := PackedFloat32Array()
var _body_dry := PackedByteArray()


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
	# JSON gives the years as floats; held as ints so `has()` finds them.
	var drought_years: Array[int] = []
	if settings["drought_years"] is Array:
		for year in settings["drought_years"]:
			drought_years.append(int(year))
	settings["drought_years"] = drought_years
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
	for index in range(sources.size()):
		var source: Dictionary = sources[index]
		source["index"] = index
		source["bank_radius"] = float(source.get("radius", 0.0))
		_index_by_position[source["position"]] = index
	_build_bodies(sources)
	# Measured body by body, each as a round pond of its area; the mean is the ponds' (a body of a
	# kind other than "pond" - a lake, a marsh - is measured against them, not counted in it), so
	# a pond on a map of lakes lasts as a pond of its size always has.
	var equivalent := PackedFloat32Array()
	equivalent.resize(_bodies.size())
	var radius_sum := 0.0
	var ponds := 0
	var others_sum := 0.0
	var others := 0
	for body in range(_bodies.size()):
		var anchor: Dictionary = sources[_bodies[body][0]]
		equivalent[body] = _equivalent_radius(sources, _bodies[body])
		# A river's bank (`permanent`) is no pond: it is not measured, and it never fills or dries.
		if bool(anchor.get("permanent", false)):
			continue
		if str(anchor.get("kind", "pond")) == "pond":
			radius_sum += equivalent[body]
			ponds += 1
		else:
			others_sum += equivalent[body]
			others += 1
	mean_radius = radius_sum / float(ponds) if ponds > 0 else others_sum / float(maxi(1, others))
	var reference := maxf(1.0, mean_radius)
	var initial := clampf(float(settings["initial_level"]), 0.0, 1.0)
	levels.resize(sources.size())
	dry.resize(sources.size())
	capacity.resize(sources.size())
	size_factor.resize(sources.size())
	_body_dry.resize(_bodies.size())
	_body_floor.resize(_bodies.size())
	_wet_count = 0
	for body in range(_bodies.size()):
		var lobes: PackedInt32Array = _bodies[body]
		var anchor: Dictionary = sources[lobes[0]]
		var level := 1.0
		var body_capacity := INF
		var factor := 0.0
		var floor_level := 0.0
		if not bool(anchor.get("permanent", false)):
			var relative := maxf(0.01, equivalent[body] / reference)
			if str(anchor.get("kind", "")) == "lake":
				floor_level = clampf(float(settings["lake_floor"]), 0.0, 1.0)
			level = maxf(initial, floor_level)
			body_capacity = _capacity_for(relative)
			factor = pow(1.0 / relative, float(settings["size_exponent"]))
		_body_floor[body] = floor_level
		_body_dry[body] = 1 if body_capacity != INF and level <= float(settings["dry_level"]) else 0
		if _body_dry[body] == 0:
			_wet_count += 1
		for lobe in lobes:
			levels[lobe] = level
			capacity[lobe] = body_capacity
			size_factor[lobe] = factor
			dry[lobe] = _body_dry[body]
	if initial < 1.0:
		for body in range(_bodies.size()):
			_refresh_body(body)


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
	var body := _bodies.size()
	body_of.append(body)
	_bodies.append(PackedInt32Array([index]))
	_body_bank.append(float(source["bank_radius"]))
	_body_floor.append(0.0)
	levels.append(clampf(level, 0.0, 1.0))
	dry.append(1 if levels[index] <= float(settings["dry_level"]) else 0)
	_body_dry.append(dry[index])
	capacity.append(_capacity_for(relative))
	size_factor.append(pow(1.0 / relative, float(settings["size_exponent"])))
	if dry[index] == 0:
		_wet_count += 1
	_set_shore(index)


## The sources grouped into bodies: the lobes sharing a `body` tag, every other source (a pond, a
## river's bank) a body of its own, in the order the sources first come; each body's lobes its
## largest first. A lobe of a body of several is told its body's number (`body`) and its anchor's
## centre (`anchor`): where the body is known by - a memory, a route given up - whichever lobe was
## seen.
func _build_bodies(sources: Array) -> void:
	_bodies = []
	body_of = PackedInt32Array()
	body_of.resize(sources.size())
	var by_tag := {}
	for index in range(sources.size()):
		var source: Dictionary = sources[index]
		var tag = source.get("body", null)
		if tag == null or bool(source.get("permanent", false)):
			body_of[index] = _bodies.size()
			_bodies.append(PackedInt32Array([index]))
		elif by_tag.has(tag):
			body_of[index] = int(by_tag[tag])
			_bodies[int(by_tag[tag])].append(index)
		else:
			by_tag[tag] = _bodies.size()
			body_of[index] = _bodies.size()
			_bodies.append(PackedInt32Array([index]))
	_body_bank = PackedFloat32Array()
	_body_bank.resize(_bodies.size())
	for body in range(_bodies.size()):
		var lobes: Array = Array(_bodies[body])
		lobes.sort_custom(func(a, b): return float(sources[a]["bank_radius"]) > float(sources[b]["bank_radius"]) \
			or (float(sources[a]["bank_radius"]) == float(sources[b]["bank_radius"]) and a < b))
		_bodies[body] = PackedInt32Array(lobes)
		_body_bank[body] = float(sources[lobes[0]]["bank_radius"])
		if sources[lobes[0]].has("body"):
			for lobe in lobes:
				sources[lobe]["body"] = body
				if lobes.size() > 1:
					sources[lobe]["anchor"] = sources[lobes[0]]["position"]


## The radius of a round pond of the body's area: its bank for one lobe, else measured on a grid a
## quarter of its smallest lobe across.
static func _equivalent_radius(sources: Array, lobes: PackedInt32Array) -> float:
	if lobes.size() == 1:
		return float(sources[lobes[0]]["bank_radius"])
	var box := Rect2()
	var smallest := INF
	for lobe in lobes:
		var centre: Vector2 = sources[lobe]["position"]
		var radius := float(sources[lobe]["bank_radius"])
		var disc := Rect2(centre - Vector2.ONE * radius, Vector2.ONE * radius * 2.0)
		box = disc if lobe == lobes[0] else box.merge(disc)
		smallest = minf(smallest, radius)
	var step := maxf(1.0, smallest * 0.25)
	var inside := 0
	var y := box.position.y + step * 0.5
	while y < box.end.y:
		var x := box.position.x + step * 0.5
		while x < box.end.x:
			for lobe in lobes:
				if Vector2(x, y).distance_squared_to(sources[lobe]["position"]) <= pow(float(sources[lobe]["bank_radius"]), 2.0):
					inside += 1
					break
			x += step
		y += step
	return sqrt(float(inside) * step * step / PI)


func _capacity_for(relative: float) -> float:
	return maxf(1.0, float(settings["capacity_seasons"]) * demand_unit * pow(relative, float(settings["capacity_exponent"])))


## Every pond `amount` fuller (or emptier, negative): rain, or a dry spell, a command brought.
func add_to_all(amount: float) -> void:
	if not enabled or amount == 0.0:
		return
	for body in range(_bodies.size()):
		var anchor: int = _bodies[body][0]
		if size_factor[anchor] == 0.0:
			continue
		var next := clampf(levels[anchor] + amount, _body_floor[body], 1.0)
		if next != levels[anchor]:
			_set_level(body, next)


## One tick: the season's balance on every pond. `climate` is the world's `Climate`, sampled.
func step(delta: float, climate) -> void:
	if not enabled:
		return
	var balance: float = climate.blend_by_season(settings["balance"])
	if balance < 0.0 and is_drought_year(climate.year):
		balance *= float(settings["drought_strength"])
	# The weather's rain or heat (`Climate.water_bias`, 0 without weather).
	balance += float(climate.water_bias)
	var rate := balance / season_length * delta
	if rate == 0.0:
		return
	for body in range(_bodies.size()):
		var anchor: int = _bodies[body][0]
		var next := clampf(levels[anchor] + rate * size_factor[anchor], _body_floor[body], 1.0)
		if next != levels[anchor]:
			_set_level(body, next)


## What a drinker that wants `wanted` thirst points takes from pond `index`: all of it while
## the pond holds that much, what is left otherwise, nothing from a dry one.
func drink(index: int, wanted: float) -> float:
	if not enabled or index < 0 or index >= levels.size() or wanted <= 0.0:
		return maxf(0.0, wanted) if not enabled else 0.0
	if dry[index] != 0:
		return 0.0
	# A river's bank: as much as wanted, and it stays full.
	if is_inf(capacity[index]):
		return wanted
	var body := body_of[index]
	var anchor: int = _bodies[body][0]
	# A lake gives what is asked: at its floor the springs make it up.
	if _body_floor[body] > 0.0:
		_set_level(body, maxf(_body_floor[body], levels[anchor] - wanted / capacity[anchor]))
		return wanted
	var granted := minf(wanted, levels[anchor] * capacity[anchor])
	_set_level(body, maxf(0.0, levels[anchor] - granted / capacity[anchor]))
	return granted


func is_dry(index: int) -> bool:
	return enabled and index >= 0 and index < dry.size() and dry[index] != 0


## The lobes of the body pond `index` belongs to, its anchor first: just `index` for a pond on its own.
func lobes_of(index: int) -> PackedInt32Array:
	if index < 0 or index >= body_of.size():
		return PackedInt32Array()
	return _bodies[body_of[index]]


func body_count() -> int:
	return _bodies.size()


## Body `body`'s anchor: its largest lobe's index.
func body_anchor(body: int) -> int:
	return _bodies[body][0]


## Pond `index`'s body, or -1.
func body_index(index: int) -> int:
	return body_of[index] if index >= 0 and index < body_of.size() else -1


## How far body `body`'s water stands in from its banks: `dry_margin` past its largest bank while
## it is dry, else what its lobes have lost - for the ground's shader, which moves each body's
## field in by it.
func body_shrink(body: int, dry_margin: float) -> float:
	var anchor: int = _bodies[body][0]
	var bank := float(_sources[anchor]["bank_radius"])
	if enabled and _body_dry[body] != 0:
		return bank + dry_margin
	return maxf(0.0, bank - float(_sources[anchor].get("radius", bank)))


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


## The bodies holding water - a lake of many lobes is one - the rivers' banks among them.
func wet_count() -> int:
	return _wet_count if enabled else _bodies.size()


func dry_count() -> int:
	return _bodies.size() - wet_count()


## The ponds' mean level, a body counted once; the rivers' banks, always full, are not counted.
func mean_level() -> float:
	var total := 0.0
	var ponds := 0
	for body in range(_bodies.size()):
		var anchor: int = _bodies[body][0]
		if size_factor[anchor] == 0.0 and is_inf(capacity[anchor]):
			continue
		total += levels[anchor]
		ponds += 1
	return 1.0 if ponds == 0 else total / float(ponds)


## Whether `year` is a drought year: one `drought_years` names, or by a hash of the year and the
## world's seed, never the first.
func is_drought_year(year: int) -> bool:
	if settings["drought_years"].has(year):
		return true
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
	# A body's anchor goes dry only with the body: its lobe is the last the water leaves.
	for body in range(_bodies.size()):
		_body_dry[body] = dry[_bodies[body][0]]
		if _body_dry[body] == 0:
			_wet_count += 1
		_refresh_body(body)


## Body `body`'s level, on every lobe, and what follows from it.
func _set_level(body: int, level: float) -> void:
	for lobe in _bodies[body]:
		levels[lobe] = level
	_settle_body(body)


## The water's edge and the dry/wet state after pond `index`'s level moved (its body's, all of it).
func _settle(index: int) -> void:
	var body := body_of[index]
	var level := levels[index]
	for lobe in _bodies[body]:
		levels[lobe] = level
	_settle_body(body)


func _settle_body(body: int) -> void:
	var anchor: int = _bodies[body][0]
	if _body_dry[body] == 0 and levels[anchor] <= float(settings["dry_level"]):
		_body_dry[body] = 1
		_wet_count -= 1
		transitions.append([anchor, "dried"])
	elif _body_dry[body] != 0 and levels[anchor] >= float(settings["wet_level"]):
		_body_dry[body] = 0
		_wet_count += 1
		transitions.append([anchor, "refilled"])
	_refresh_body(body)


## Every lobe's edge, and each dry with its body or once the water has left it.
func _refresh_body(body: int) -> void:
	for lobe in _bodies[body]:
		_set_shore(lobe)
		dry[lobe] = 1 if _body_dry[body] != 0 or (_bodies[body].size() > 1 and float(_sources[lobe]["radius"]) <= 0.0) else 0


func _set_shore(index: int) -> void:
	var source: Dictionary = _sources[index]
	var lobes: PackedInt32Array = _bodies[body_of[index]] if index < body_of.size() else PackedInt32Array([index])
	if lobes.size() <= 1:
		source["radius"] = float(source["bank_radius"]) * sqrt(maxf(0.0, levels[index]))
		return
	var body_bank := _body_bank[body_of[index]]
	var lost := body_bank - body_bank * sqrt(maxf(0.0, levels[index]))
	source["radius"] = maxf(0.0, float(source["bank_radius"]) - lost)
