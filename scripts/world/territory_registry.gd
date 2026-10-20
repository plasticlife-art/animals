class_name TerritoryRegistry
extends RefCounted

## A species' territories (`species.<id>.territory`): a den and a radius each, and the pair that
## holds it - a male's slot and a female's, either empty. The registry is what is true; an
## animal's own `territory_id` only mirrors it. It lives in the world the simulation steps and
## is saved with it (`WorldState.export_state()`); the view's copy follows the worker's through
## `presentation_block()`, sent whenever `revision` moves.
##
## The dens are placed once, from the map, with no draw from the world's `rng`
## (`place_dens()`): a good den has grass around it and water near, and no den stands within
## `spacing` radii of another, so between the territories there is ground no one holds.

const NOBODY := -1

## Moves whenever what the view shows changes: a slot taken or let go.
var revision: int = 0
## `{id, den, radius, male, female, vacant_since, group}`, by id, which is the index. `group`
## is the pack living on it, for a species in packs (`role.social` "pack"); -1 otherwise.
var territories: Array = []
## Who holds which: agent id -> territory id.
var _held_by: Dictionary = {}


## The dens `place_dens()` chose, every one empty since `now`.
func configure(dens: Array, radius: float, now: float = 0.0) -> void:
	territories.clear()
	_held_by.clear()
	for index in range(dens.size()):
		territories.append({"id": index, "den": dens[index], "radius": radius,
			"male": NOBODY, "female": NOBODY, "vacant_since": now, "group": NOBODY})
	revision = 0


## Where the dens go: from a grid of candidate cells every `step_cells` (each moved within its
## step by a hash of the world's `seed`), the walkable ones at least half a radius from the
## edge with water within `water_cells`, taken best first - the most grass within half a
## radius, then the lower cell - while no taken den is within `spacing` radii. With `den_score`
## "cover" best is the most cover within half a radius (`cover`, 1 per cell of forest), grass
## breaking ties: a den in the wood, the pastures between.
## `caps` is the grass each cell can hold (`ResourceSystem.export_caps()`), `walkable` per cell.
static func place_dens(caps: PackedFloat32Array, walkable: PackedByteArray, cols: int, rows: int, cell: float,
		water_sources: Array, config: Dictionary, seed: int, cover := PackedFloat32Array()) -> Array:
	var radius_cells := float(config.get("radius_cells", 10.0))
	var step := maxi(1, int(config.get("step_cells", 2)))
	var water_cells := float(config.get("water_cells", 6.0))
	var spacing := float(config.get("spacing", 1.8)) * radius_cells
	var half := maxi(1, roundi(radius_cells * 0.5))
	var summed := _summed_area(caps, cols, rows)
	var by_cover := str(config.get("den_score", "grass")) == "cover" and cover.size() == caps.size()
	var cover_summed := _summed_area(cover, cols, rows) if by_cover else PackedFloat64Array()
	var grass_total := maxf(1.0, _box_sum(summed, cols, rows, cols / 2, rows / 2, maxi(cols, rows)))
	var watered := _watered(water_sources, cols, rows, cell, water_cells)
	var candidates: Array = []
	for gy in range(0, rows, step):
		for gx in range(0, cols, step):
			var x := mini(cols - 1, gx + int(_hash_unit(seed, gx * 7919 + gy) * float(step)))
			var y := mini(rows - 1, gy + int(_hash_unit(seed ^ 0x5BD1E995, gy * 7919 + gx) * float(step)))
			var index := y * cols + x
			if walkable[index] == 0 or watered[index] == 0:
				continue
			if float(x) < radius_cells * 0.5 or float(y) < radius_cells * 0.5 \
					or float(cols - 1 - x) < radius_cells * 0.5 or float(rows - 1 - y) < radius_cells * 0.5:
				continue
			var score := _box_sum(summed, cols, rows, x, y, half)
			if by_cover:
				score = _box_sum(cover_summed, cols, rows, x, y, half) + score / grass_total
			candidates.append([score, index])
	candidates.sort_custom(func(a, b): return a[0] > b[0] or (a[0] == b[0] and a[1] < b[1]))
	var chosen: Array = []
	var cells_taken: Array = []
	for candidate in candidates:
		var index: int = candidate[1]
		var at := Vector2(index % cols, index / cols)
		var free := true
		for other in cells_taken:
			if at.distance_squared_to(other) < spacing * spacing:
				free = false
				break
		if free:
			cells_taken.append(at)
			chosen.append((at + Vector2(0.5, 0.5)) * cell)
	return chosen


static func _summed_area(caps: PackedFloat32Array, cols: int, rows: int) -> PackedFloat64Array:
	var summed := PackedFloat64Array()
	summed.resize((cols + 1) * (rows + 1))
	for y in range(rows):
		var row := 0.0
		for x in range(cols):
			row += caps[y * cols + x]
			summed[(y + 1) * (cols + 1) + x + 1] = summed[y * (cols + 1) + x + 1] + row
	return summed


static func _box_sum(summed: PackedFloat64Array, cols: int, rows: int, x: int, y: int, half: int) -> float:
	var x0 := maxi(0, x - half)
	var y0 := maxi(0, y - half)
	var x1 := mini(cols, x + half + 1)
	var y1 := mini(rows, y + half + 1)
	var width := cols + 1
	return summed[y1 * width + x1] - summed[y0 * width + x1] - summed[y1 * width + x0] + summed[y0 * width + x0]


## Per cell, 1 within `water_cells` of a pond's edge.
static func _watered(water_sources: Array, cols: int, rows: int, cell: float, water_cells: float) -> PackedByteArray:
	var watered := PackedByteArray()
	watered.resize(cols * rows)
	for source in water_sources:
		var centre: Vector2 = source.get("position", Vector2.ZERO)
		var reach := float(source.get("radius", 0.0)) + water_cells * cell
		var x0 := maxi(0, int(floor((centre.x - reach) / cell)))
		var y0 := maxi(0, int(floor((centre.y - reach) / cell)))
		var x1 := mini(cols - 1, int(floor((centre.x + reach) / cell)))
		var y1 := mini(rows - 1, int(floor((centre.y + reach) / cell)))
		for y in range(y0, y1 + 1):
			for x in range(x0, x1 + 1):
				if (Vector2(x, y) + Vector2(0.5, 0.5)).distance_squared_to(centre / cell) <= (reach / cell) * (reach / cell):
					watered[y * cols + x] = 1
	return watered


## `WorldState._dormant_hash_unit()`: a hash of two ints, 0..1, with no product past 49 bits.
static func _hash_unit(a: int, b: int) -> float:
	var mixed: int = (a & 0xFFFFFFFF) ^ _mul32(b & 0xFFFFFFFF, 0x9E3779B9)
	mixed ^= mixed >> 16
	mixed = _mul32(mixed, 0x7FEB352D)
	mixed ^= mixed >> 15
	mixed = _mul32(mixed, 0x846CA68B)
	mixed ^= mixed >> 16
	return float(mixed & 0xFFFFFF) / 16777216.0


static func _mul32(value: int, factor: int) -> int:
	return (value * (factor & 0xFFFF) + (((value * (factor >> 16)) & 0xFFFF) << 16)) & 0xFFFFFFFF


func size() -> int:
	return territories.size()


func get_territory(territory_id: int) -> Dictionary:
	return territories[territory_id] if territory_id >= 0 and territory_id < territories.size() else {}


## The territory `agent_id` holds, or -1.
func territory_of(agent_id: int) -> int:
	return int(_held_by.get(agent_id, NOBODY))


## The territory the pack `group` lives on, or -1.
func territory_of_group(group: int) -> int:
	if group < 0:
		return NOBODY
	for territory in territories:
		if int(territory.get("group", NOBODY)) == group:
			return int(territory["id"])
	return NOBODY


## Who holds the other slot of `agent_id`'s territory, or -1.
func partner_of(agent_id: int) -> int:
	var territory := get_territory(territory_of(agent_id))
	if territory.is_empty():
		return NOBODY
	if int(territory["male"]) == agent_id:
		return int(territory["female"])
	return int(territory["male"])


static func _slot(sex: String) -> String:
	return "female" if sex == "female" else "male"


## Takes `sex`'s slot of `territory_id` for `agent_id`, letting go of any other it holds.
## False when that slot is someone else's.
func claim(territory_id: int, agent_id: int, sex: String) -> bool:
	var territory := get_territory(territory_id)
	if territory.is_empty():
		return false
	var slot := _slot(sex)
	if int(territory[slot]) == agent_id:
		return true
	if int(territory[slot]) != NOBODY:
		return false
	release(agent_id, 0.0)
	territory[slot] = agent_id
	_held_by[agent_id] = territory_id
	revision += 1
	return true


## `agent_id` lets go of what it holds (it died, or left), at `now`; the territory it held, or -1.
func release(agent_id: int, now: float) -> int:
	var territory_id := territory_of(agent_id)
	if territory_id == NOBODY:
		return NOBODY
	_held_by.erase(agent_id)
	var territory: Dictionary = territories[territory_id]
	for slot in ["male", "female"]:
		if int(territory[slot]) == agent_id:
			territory[slot] = NOBODY
	if int(territory["male"]) == NOBODY and int(territory["female"]) == NOBODY:
		territory["vacant_since"] = now
	revision += 1
	return territory_id


func is_vacant(territory_id: int) -> bool:
	var territory := get_territory(territory_id)
	return not territory.is_empty() and int(territory["male"]) == NOBODY and int(territory["female"]) == NOBODY


## The territory with `sex`'s slot open nearest `position`, by distance to its den and then id,
## other than `excluded` (where the animal was born); -1 when there is none.
func open_slot_near(position: Vector2, sex: String, excluded: int = NOBODY) -> int:
	var slot := _slot(sex)
	var best := NOBODY
	var best_distance := INF
	for territory in territories:
		if int(territory["id"]) == excluded or int(territory[slot]) != NOBODY:
			continue
		var distance: float = position.distance_squared_to(territory["den"])
		if distance < best_distance:
			best_distance = distance
			best = int(territory["id"])
	return best


## The held territory whose ground `position` is on, by the nearest den within its radius
## times `slack`, or -1. `ignore` is a territory not counted (the asker's own).
func held_at(position: Vector2, slack: float = 1.0, ignore: int = NOBODY) -> int:
	var best := NOBODY
	var best_distance := INF
	for territory in territories:
		if int(territory["id"]) == ignore or is_vacant(int(territory["id"])):
			continue
		var reach: float = float(territory["radius"]) * slack
		var distance: float = position.distance_squared_to(territory["den"])
		if distance <= reach * reach and distance < best_distance:
			best_distance = distance
			best = int(territory["id"])
	return best


## Whether `position` is within `slack` radii of `territory_id`'s den.
func inside(territory_id: int, position: Vector2, slack: float = 1.0) -> bool:
	var territory := get_territory(territory_id)
	if territory.is_empty():
		return false
	var reach: float = float(territory["radius"]) * slack
	return position.distance_squared_to(territory["den"]) <= reach * reach


## Territories by how they are held: `{pairs, singles, vacant}`.
func census() -> Dictionary:
	var counts := {"pairs": 0, "singles": 0, "vacant": 0}
	for territory in territories:
		var holders := int(int(territory["male"]) != NOBODY) + int(int(territory["female"]) != NOBODY)
		counts[["vacant", "singles", "pairs"][holders]] += 1
	return counts


## What the view needs to draw the territories, whole each time: they are few.
func presentation_block() -> Dictionary:
	return {"revision": revision, "territories": territories.duplicate(true)}


func apply_presentation_block(block: Dictionary) -> void:
	revision = int(block.get("revision", revision))
	territories = block.get("territories", territories).duplicate(true)
	_rebuild_holders()


func export_state() -> Dictionary:
	return {"revision": revision, "territories": territories.duplicate(true)}


## A save from before territories carries none: the dens stay as placed and every one empty
## (the foxes' own ids say nothing a registry could be rebuilt from).
func import_state(data: Dictionary) -> void:
	if data.is_empty():
		return
	revision = int(data.get("revision", 0))
	territories = data.get("territories", territories).duplicate(true)
	_rebuild_holders()


func _rebuild_holders() -> void:
	_held_by.clear()
	for territory in territories:
		for slot in ["male", "female"]:
			if int(territory[slot]) != NOBODY:
				_held_by[int(territory[slot])] = int(territory["id"])
