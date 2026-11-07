extends RefCounted

## The map's water in natural shapes (`WaterBodies`): the generator lays the lakes, marshes and
## ponds it is asked for, each a connected run of lobes on the map, spaced, every lobe with a shore,
## the map nowhere far from water, the same each time from one seed; `WaterSystem` keeps one level
## for a body's lobes, the narrow ones going dry first, a lake never below its floor; and the
## world drinks and approaches a lake by any of its lobes, knows it by one place, and walks
## through a marsh.

const Helpers := preload("res://scripts/tests/test_helpers.gd")
const ConfigLoaderScript := preload("res://scripts/core/config_loader.gd")
const WaterBodiesScript := preload("res://scripts/world/water_bodies.gd")
const WaterSystemScript := preload("res://scripts/world/water_system.gd")
const WaterMaskScript := preload("res://scripts/ui/water_mask.gd")
const ClimateScript := preload("res://scripts/world/climate.gd")
const AgentBaseScript := preload("res://scripts/agents/agent_base.gd")
const LARGE := Rect2(0.0, 0.0, 14400.0, 8100.0)


func run(a) -> void:
	_test_generator(a)
	_test_on_land(a)
	_test_body_levels(a)
	_test_lake_floor(a)
	_test_world(a)
	_test_streams(a)
	_test_mask(a)


func _shipped() -> Dictionary:
	return ConfigLoaderScript.load_config_bundle()["world"]["water_bodies"].duplicate(true)


## Bodies by tag: `{body: [lobes]}`.
static func _bodies(lobes: Array) -> Dictionary:
	var bodies := {}
	for lobe in lobes:
		if not bodies.has(lobe["body"]):
			bodies[lobe["body"]] = []
		bodies[lobe["body"]].append(lobe)
	return bodies


static func _connected(lobes: Array) -> bool:
	var reached := {0: true}
	var frontier := [0]
	while not frontier.is_empty():
		var at: int = frontier.pop_back()
		for other in range(lobes.size()):
			if not reached.has(other) and (lobes[at]["position"] as Vector2).distance_to(lobes[other]["position"]) \
					< float(lobes[at]["radius"]) + float(lobes[other]["radius"]):
				reached[other] = true
				frontier.append(other)
	return reached.size() == lobes.size()


static func _exposed(lobe: Dictionary, lobes: Array) -> bool:
	for probe in range(12):
		var rim: Vector2 = lobe["position"] + Vector2.from_angle(TAU * float(probe) / 12.0) * float(lobe["radius"])
		var covered := false
		for other in lobes:
			if other != lobe and rim.distance_to(other["position"]) < float(other["radius"]) - 1.0:
				covered = true
		if not covered:
			return true
	return false


func _test_generator(a) -> void:
	var cfg := _shipped()
	a.is_true(bool(cfg["enabled"]), "the large map's water comes in natural shapes")
	var settings := WaterBodiesScript.settings(cfg)
	var border := float(settings["border"])
	var spacing := float(settings["spacing"])
	for seed in [1, 2, 3]:
		var lobes: Array = WaterBodiesScript.generate(cfg, LARGE, seed)
		a.equal(lobes, WaterBodiesScript.generate(cfg, LARGE, seed), "seed %d: the same water from the same seed" % seed)
		var bodies := _bodies(lobes)
		var kinds := {}
		var positions := {}
		var inside := true
		var connected := true
		var shored := true
		var largest_first := true
		for body in bodies.keys():
			var own: Array = bodies[body]
			kinds[own[0]["kind"]] = int(kinds.get(own[0]["kind"], 0)) + 1
			connected = connected and _connected(own)
			for lobe in own:
				positions[lobe["position"]] = true
				inside = inside and LARGE.grow(-border - float(lobe["radius"]) + 0.01).has_point(lobe["position"])
				shored = shored and _exposed(lobe, own)
				largest_first = largest_first and float(own[0]["radius"]) >= float(lobe["radius"])
		a.is_true(largest_first, "seed %d: a body's largest lobe comes first" % seed)
		a.equal(int(kinds.get("lake", 0)), int(settings["lakes"]["count"]), "seed %d: the lakes asked for" % seed)
		a.equal(int(kinds.get("marsh", 0)), int(settings["marshes"]["count"]), "seed %d: the marshes asked for" % seed)
		var ponds := int(kinds.get("pond", 0))
		a.is_true(ponds >= int(settings["ponds"]["count_min"]) and ponds <= int(settings["ponds"]["count_max"]),
			"seed %d: ponds between the least and the most (%d)" % [seed, ponds])
		a.is_true(bodies.size() < 52, "seed %d: fewer waters than the 52 round ponds before (%d)" % [seed, bodies.size()])
		a.equal(positions.size(), lobes.size(), "seed %d: no two lobes at one point" % seed)
		a.is_true(inside, "seed %d: every lobe on the map, its border kept" % seed)
		a.is_true(connected, "seed %d: every body's lobes one water" % seed)
		a.is_true(shored, "seed %d: every lobe has a shore of its own" % seed)
		# Spacing: between bodies but a marsh and the lake it lies off.
		var spaced := true
		for first in bodies.keys():
			for second in bodies.keys():
				if int(second) <= int(first) or bodies[first][0]["kind"] == "marsh" or bodies[second][0]["kind"] == "marsh":
					continue
				for x in bodies[first]:
					for y in bodies[second]:
						var gap: float = (x["position"] as Vector2).distance_to(y["position"]) - float(x["radius"]) - float(y["radius"])
						spaced = spaced and gap >= spacing - 0.01
		a.is_true(spaced, "seed %d: bodies kept apart" % seed)
		# Nowhere far from water, unless every pond the map may have is laid.
		if ponds < int(settings["ponds"]["count_max"]):
			var furthest := 0.0
			var inner := LARGE.grow(-border)
			for gy in range(20):
				for gx in range(36):
					var point := inner.position + Vector2((gx + 0.5) / 36.0, (gy + 0.5) / 20.0) * inner.size
					var nearest := INF
					for lobe in lobes:
						nearest = minf(nearest, point.distance_to(lobe["position"]) - float(lobe["radius"]))
					furthest = maxf(furthest, nearest)
			a.is_true(furthest <= float(settings["ponds"]["max_gap"]) + 240.0,
				"seed %d: nowhere further from water than the gap allowed (%.0f)" % [seed, furthest])
	a.is_true(WaterBodiesScript.generate(cfg, LARGE, 1) != WaterBodiesScript.generate(cfg, LARGE, 2),
		"each world its own water")
	var scaled := cfg.duplicate(true)
	scaled["scale"] = 1.0 / 3.0
	var small: Array = WaterBodiesScript.generate(scaled, Rect2(0.0, 0.0, 4800.0, 2700.0), 1)
	a.equal(_bodies(small).size(), _bodies(WaterBodiesScript.generate(cfg, LARGE, 1)).size(),
		"a map a third the size, its water scaled, has as many waters")


func _test_on_land(a) -> void:
	var land := func(point: Vector2) -> bool: return point.x < 7200.0
	var lobes: Array = WaterBodiesScript.generate(_shipped(), LARGE, 5, land)
	var on_land := not lobes.is_empty()
	for lobe in lobes:
		on_land = on_land and float((lobe["position"] as Vector2).x) + float(lobe["radius"]) <= 7200.0 + 0.01
	a.is_true(on_land, "every lobe on land, its bank too")


## A body of three lobes (300, 200, 120), a tagged pond of one and a pond of old, measured as on the
## large map.
func _sources(kind := "marsh") -> Array:
	return [
		{"position": Vector2(350.0, 0.0), "radius": 200.0, "body": 0, "kind": kind},
		{"position": Vector2(0.0, 0.0), "radius": 300.0, "body": 0, "kind": kind},
		{"position": Vector2(-330.0, 60.0), "radius": 120.0, "body": 0, "kind": kind},
		{"position": Vector2(3000.0, 0.0), "radius": 180.0, "body": 1, "kind": "pond"},
		{"position": Vector2(6000.0, 0.0), "radius": 230.0},
	]


func _test_body_levels(a) -> void:
	var sources := _sources()
	var water = WaterSystemScript.new()
	water.initialize({"enabled": true}, sources, 840.0, 120.0, true, 4242)
	a.equal(water.body_count(), 3, "three waters: a body of three lobes is one")
	a.equal(Array(water.lobes_of(2)), [1, 0, 2], "its lobes, the largest first")
	a.equal(sources[0]["anchor"], Vector2(0.0, 0.0), "known by its largest lobe's centre")
	a.is_true(not sources[3].has("anchor") and not sources[4].has("anchor"), "a pond of one lobe by its own")
	a.near(water.mean_radius, (180.0 + 230.0) / 2.0, 0.001, "measured against the ponds alone")
	a.equal(water.capacity[0], water.capacity[2], "one capacity for a body")
	a.is_true(water.capacity[0] > water.capacity[4], "a larger body holds more")
	var drunk: float = water.drink(2, 100.0)
	a.near(drunk, 100.0, 0.0001, "a drink from any lobe")
	a.equal(water.levels[0], water.levels[1], "lowers the body")
	a.equal(water.levels[2], water.levels[1], "every lobe of it")
	water.levels[0] = 0.25
	water._settle(0)
	a.near(float(sources[1]["radius"]), 150.0, 0.001, "at a quarter the largest lobe stands in half its bank")
	a.near(float(sources[0]["radius"]), 50.0, 0.001, "and every lobe in by as much")
	a.near(float(sources[2]["radius"]), 0.0, 0.001, "the smallest left with none")
	a.is_true(water.is_dry(2) and not water.is_dry(0) and not water.is_dry(1), "a lobe the water left is dry, the rest not")
	a.equal(water.dry_count(), 0, "while the body holds water, none dry")
	a.near(water.body_shrink(0, 10.0), 150.0, 0.001, "the body's shrink, what its lobes lost")
	water.levels[4] = 0.36
	water._settle(4)
	a.equal(float(sources[4]["radius"]), 230.0 * sqrt(water.levels[4]), "a pond of one lobe keeps its edge of old exactly")
	water.take_transitions()
	water.levels[1] = 0.01
	water._settle(1)
	a.equal(water.take_transitions(), [[1, "dried"]], "a body dries once, told by its anchor")
	a.is_true(water.is_dry(0) and water.is_dry(1) and water.is_dry(2), "every lobe dry with it")
	a.equal(water.dry_count(), 1, "one water dry")
	a.near(water.body_shrink(0, 10.0), 310.0, 0.001, "drawn gone past its largest bank")
	a.near(water.mean_level(), (0.01 + water.levels[3] + 0.36) / 3.0, 0.0001, "the mean level counts a body once")
	var saved: Dictionary = water.export_state()
	var back = WaterSystemScript.new()
	back.initialize({"enabled": true}, _sources(), 840.0, 120.0, true, 4242)
	back.import_state(saved)
	a.equal(back.dry_count(), 1, "a save keeps the body dry")
	a.is_true(back.is_dry(2) and back.levels[2] == water.levels[2], "and its lobes as they were")


func _test_lake_floor(a) -> void:
	var sources := _sources("lake")
	var water = WaterSystemScript.new()
	water.initialize({"enabled": true, "lake_floor": 0.3, "balance": {"spring": -3.0, "summer": -3.0, "autumn": -3.0,
		"winter": -3.0}}, sources, 840.0, 120.0, true, 4242)
	var climate = ClimateScript.new()
	var config: Dictionary = ConfigLoaderScript.load_config_bundle()["world"]["climate"].duplicate(true)
	config["enabled"] = true
	climate.configure({"climate": config})
	var time := 0.0
	while time < 2000.0:
		climate.sample(time)
		water.step(1.0, climate)
		time += 1.0
	a.near(water.levels[1], 0.3, 0.0001, "a lake falls no lower than its floor")
	a.is_true(water.levels[3] < 0.05, "a pond beside it goes down past it")
	a.near(water.drink(1, 500.0), 500.0, 0.0001, "at its floor a lake gives what is asked")
	a.near(water.levels[1], 0.3, 0.0001, "and stays there")
	a.is_true(not water.is_dry(1) and water.is_dry(2), "its narrow lobe dry, the lake not")


## A small map of the shipped kinds, a quarter scale, with levels and water on the ground.
func _world_bundle(seed: int) -> Dictionary:
	var bundle := Helpers.build_test_bundle(seed)
	bundle["world"]["world_size"] = {"x": 3072.0, "y": 3072.0}
	bundle["world"]["spatial_cell_size"] = 128.0
	var cfg := _shipped()
	cfg["scale"] = 0.25
	bundle["world"]["water_bodies"] = cfg
	var climate: Dictionary = ConfigLoaderScript.load_config_bundle()["world"]["climate"].duplicate(true)
	climate["enabled"] = true
	bundle["world"]["climate"] = climate
	bundle["world"]["water_levels"] = {"enabled": true, "lake_floor": 0.4}
	bundle["world"]["terrain"]["ponds"] = {"enabled": true, "route_margin_cells": 0.0, "hysteresis_cells": 0.1, "wade": 0.5}
	return bundle


func _test_world(a) -> void:
	var manager = Helpers.create_manager_with(_world_bundle(7311), 7311)
	var world = manager.world_state
	var terrain = world.terrain_system
	var tags := {}
	var lake := -1
	var marsh := -1
	for index in range(world.water_sources.size()):
		var source: Dictionary = world.water_sources[index]
		if source.has("body"):
			tags[source["body"]] = source.get("kind", "")
			if lake < 0 and source.get("kind", "") == "lake" and world.water.lobes_of(index).size() >= 3:
				lake = index
			if marsh < 0 and source.get("kind", "") == "marsh":
				marsh = index
	a.equal(world.pond_count(), tags.size(), "a pond counted for each water, a lake once")
	a.is_true(lake >= 0 and marsh >= 0, "a lake and a marsh on the map")
	if lake < 0 or marsh < 0:
		Helpers.destroy_manager(manager)
		return
	# A marsh is walked through: swamp, open, never under water.
	var swamp := true
	for index in terrain._cells_within(world.water_sources[marsh]["position"], float(world.water_sources[marsh]["bank_radius"])):
		# Where it reaches into a lake's bank the lake's water lies over it.
		var in_lake := false
		for source in world.water_sources:
			if source.get("kind", "") != "marsh" and terrain.get_cell_center(index).distance_to(source["position"]) \
					<= float(source.get("bank_radius", 0.0)) + terrain.cell_size:
				in_lake = true
		if not in_lake:
			swamp = swamp and terrain.get_biome_at_index(index) == "swamp" and terrain.is_walkable_index(index) \
				and not terrain.is_flooded_index(index)
	a.is_true(swamp, "a marsh's ground is swamp, walked on")
	var lobes: PackedInt32Array = world.water.lobes_of(lake)
	var anchor: Dictionary = world.water_sources[lobes[0]]
	var far: Dictionary = world.water_sources[lobes[lobes.size() - 1]]
	a.is_true(terrain.is_flooded_index(terrain.get_index_from_position(anchor["position"])), "a lake's water is no ground")
	var place_ok := true
	for lobe in lobes:
		place_ok = place_ok and world.water_place(world.water_sources[lobe]) == anchor["position"]
	a.is_true(place_ok, "every lobe of a lake known by one place")
	# Drinking at one lobe's shore counts for the lake, whichever lobe was the target.
	var out: Vector2 = (far["position"] - anchor["position"]).normalized()
	if out == Vector2.ZERO:
		out = Vector2.RIGHT
	var shore: Vector2 = far["position"] + out * (float(far["radius"]) + 10.0)
	var direct: bool = shore.distance_to(anchor["position"]) <= 28.0 + float(anchor["radius"])
	a.is_true(world.within_drink_reach(anchor, shore, 28.0), "at any lobe's shore an animal drinks from the lake")
	a.is_true(direct or not world.within_drink_reach({"position": anchor["position"], "radius": anchor["radius"]}, shore, 28.0),
		"which the anchor's own edge would not allow")
	var spot: Vector2 = world.water_approach(anchor, shore, 6.0)
	a.is_true(spot.distance_to(shore) < shore.distance_to(anchor["position"]) - float(anchor["radius"]),
		"heading for the lake, it walks to the nearest shore of any lobe")
	# A sleeping group at a lobe's shore is at the water whichever sector the shore lies in: one
	# on the far side of a sector line from its goal lobe's centre died of thirst at the shore.
	a.is_true(terrain.ponds_solid, "the lake's water is solid here")
	var goal_sector: Vector2i = world._get_sector_key(far["position"])
	var group := {"goal_kind": "water", "goal_position": far["position"], "goal_sector": goal_sector, "center": shore}
	a.is_true(world._dormant_aggregate_reached_goal(goal_sector + Vector2i(1, 0), group),
		"a sleeping group at the shore drinks, across a sector line from its goal's centre")
	group["center"] = far["position"] + out * 5000.0
	a.is_true(not world._dormant_aggregate_reached_goal(goal_sector, group), "and far from every lobe it does not")
	# One memory for the lake, however many of its lobes were seen.
	var deer = Helpers.spawn_herbivore(world, shore, 0)
	deer.remember_water(anchor, world.current_time)
	deer.remember_water(far, world.current_time)
	a.equal(deer.recent_water_sources.size(), 1, "a lake seen by two lobes is remembered once")
	deer.forget_water(AgentBaseScript.water_place(far))
	a.equal(deer.recent_water_sources.size(), 0, "and forgotten at once")
	Helpers.destroy_manager(manager)


func _test_streams(a) -> void:
	var manager = Helpers.create_manager_with(_world_bundle(7311), 7311)
	var world = manager.world_state
	var terrain = world.terrain_system
	a.is_true(terrain.streams.size() >= 3, "streams run down to the water (%d)" % terrain.streams.size())
	var walked := true
	for stream in terrain.streams:
		var points: PackedVector2Array = stream["points"]
		for index in range(0, points.size() - 4, 3):
			var cell: int = terrain.get_index_from_position(points[index])
			walked = walked and (terrain.is_walkable_index(cell) or terrain.is_flooded_index(cell))
	a.is_true(walked, "a stream is walked across, no ford needed")
	var springs := 0
	var never_dry := true
	for index in range(world.water_sources.size()):
		var source: Dictionary = world.water_sources[index]
		if source.has("stream"):
			springs += 1
			never_dry = never_dry and bool(source.get("permanent", false)) and is_inf(world.water.capacity[index])
	a.is_true(springs >= terrain.streams.size(), "animals drink from points along every stream (%d)" % springs)
	a.is_true(never_dry, "and a stream never runs dry")
	var off := _world_bundle(7311)
	off["world"]["water_bodies"]["streams"] = {"count": 0}
	var plain = Helpers.create_manager_with(off, 7311)
	a.equal(plain.world_state.terrain_system.streams.size(), 0, "none when none are asked for")
	Helpers.destroy_manager(plain)
	Helpers.destroy_manager(manager)


func _test_mask(a) -> void:
	# The field's origin is the map's: the lobes, about x -450..550, shifted in.
	var shifted: Array = []
	for source in _sources():
		var moved: Dictionary = source.duplicate()
		moved["position"] = source["position"] + Vector2(500.0, 400.0)
		shifted.append(moved)
	var water = WaterSystemScript.new()
	water.initialize({"enabled": true}, shifted, 840.0, 120.0, true, 4242)
	var mask: Dictionary = WaterMaskScript.bake(shifted, Vector2(7000.0, 800.0), 20.0, 60.0, [], 0.0, water.body_of)
	var ids: PackedFloat32Array = mask["ids"]
	var cols: int = mask["cols"]
	var at := func(point: Vector2) -> float:
		return ids[int(point.y / 20.0) * cols + int(point.x / 20.0)]
	a.equal(at.call(Vector2(850.0, 400.0)), 0.0, "a lobe's water is owned by its body")
	a.equal(at.call(Vector2(180.0, 460.0)), 0.0, "every lobe's")
	a.equal(at.call(Vector2(3500.0, 400.0)), 1.0, "a pond its own")
	a.near(WaterMaskScript.smooth_min(-12.0 + 30.0, -20.0 + 30.0, 40.0), WaterMaskScript.smooth_min(-12.0, -20.0, 40.0) + 30.0,
		0.0001, "a shrink moves the smooth minimum by as much")
	a.is_true(WaterMaskScript.sample(mask, Vector2(675.0, 400.0)) < -100.0,
		"where two lobes meet the water runs on, no notch")
