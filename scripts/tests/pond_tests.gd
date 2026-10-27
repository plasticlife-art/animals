extends RefCounted

## Ponds on the ground (`terrain.ponds`): off, the world is the world without the block; on, a
## pond's water is no ground to walk or graze but an animal sees across it, routes go round it and
## the map stays in one piece; the shore follows the level, the bed greening from stubble and an
## animal the water rises about stepping out; a thirsty deer drinks from the shore and never wades
## in; a route found before the water rose is not handed out after; a sleeping herd at the shore
## counts as at the water; and a save keeps the water where it was.

const Helpers := preload("res://scripts/tests/test_helpers.gd")
const CENTER := Vector2(512.0, 512.0)
const RADIUS := 120.0


func run(a) -> void:
	_test_off(a)
	_test_water_is_no_ground(a)
	_test_the_shore_follows_the_level(a)
	_test_drinks_from_the_shore(a)
	_test_stale_routes(a)
	_test_sleeping_herd_at_the_shore(a)
	_test_save(a)


static func _bundle(enabled: bool = true) -> Dictionary:
	var bundle: Dictionary = Helpers.build_test_bundle(9981)
	bundle["world"]["world_size"] = {"x": 1024.0, "y": 1024.0}
	bundle["world"]["spatial_cell_size"] = 64.0
	bundle["world"]["water_sources"] = [
		{"x": CENTER.x, "y": CENTER.y, "radius": RADIUS},
		{"x": 128.0, "y": 128.0, "radius": 18.0},
	]
	bundle["world"]["terrain"]["ponds"] = {"enabled": enabled, "route_margin_cells": 0.25,
		"hysteresis_cells": 0.1, "wade": 0.5}
	return bundle


func _test_off(a) -> void:
	var plain := _bundle()
	plain["world"]["terrain"].erase("ponds")
	var reference = Helpers.create_manager_with(plain, 9981)
	Helpers.spawn_herd(reference.world_state, CENTER + Vector2(-60.0, 0.0), 6, 0)
	for _tick in range(60):
		reference.step_once()
	var off = Helpers.create_manager_with(_bundle(false), 9981)
	Helpers.spawn_herd(off.world_state, CENTER + Vector2(-60.0, 0.0), 6, 0)
	for _tick in range(60):
		off.step_once()
	a.equal(Helpers.world_fingerprint(off), Helpers.world_fingerprint(reference), "switched off is as if absent")
	var terrain = off.world_state.terrain_system
	a.is_true(terrain.is_walkable_index(terrain.get_index_from_position(CENTER)) and not terrain.is_flooded_index(
		terrain.get_index_from_position(CENTER)), "and the pond lies on open ground")
	Helpers.destroy_manager(reference)
	Helpers.destroy_manager(off)


func _test_water_is_no_ground(a) -> void:
	var manager = Helpers.create_manager_with(_bundle(), 9981)
	var world = manager.world_state
	var terrain = world.terrain_system
	var middle: int = terrain.get_index_from_position(CENTER)
	a.is_true(not terrain.is_walkable_index(middle) and terrain.is_flooded_index(middle)
		and world.resource_system.get_biomass(middle) == 0.0, "no route and no grass in the water")
	var far: int = terrain.get_index_from_position(CENTER + Vector2(RADIUS + 96.0, 0.0))
	a.is_true(terrain.is_walkable_index(far) and world.resource_system.get_biomass(far) > 0.0, "the shore is ground")
	var west := CENTER + Vector2(-RADIUS - 60.0, 0.0)
	var east := CENTER + Vector2(RADIUS + 60.0, 0.0)
	a.is_true(not world.scenery.segment_clear(west, east, 9.0) and world.scenery.terrain_clear(west, east, 0.0, true),
		"no way across the water, but sight across it")
	# The water's own edge, not the cells': a body may wade half its radius in, no more.
	var body := 18.0
	var at_edge := CENTER + Vector2(RADIUS + body * 0.5 + 1.0, 0.0)
	var in_water := CENTER + Vector2(RADIUS + body * 0.5 - 2.0, 0.0)
	a.is_true(world.scenery.segment_clear(at_edge, at_edge, body) and not world.scenery.segment_clear(in_water, in_water, body),
		"a body stands with half its radius over the water, and no further in")
	var route: Dictionary = terrain.find_path(west, east)
	var dry: bool = not route.get("cells", []).is_empty()
	for cell in route.get("cells", []):
		dry = dry and terrain.is_walkable_index(int(cell))
	a.is_true(bool(route.get("reachable", false)) and dry, "a route goes round")
	a.equal(terrain._collect_walkable_components().size(), 1, "the map stays in one piece")
	var shore: Vector2 = world.water_approach(world.water_sources[0], CENTER + Vector2(0.0, -400.0), body)
	var drink_reach: float = RADIUS + float(world.config_bundle["species"]["herbivore"]["feeding"].get("drink_distance", 28.0))
	a.is_true(shore.y < CENTER.y - RADIUS and shore.distance_to(CENTER) <= drink_reach
		and world.scenery.segment_clear(shore, shore, body), "one drinks from the near shore, standing clear (%s)" % shore)
	# A cliff on the near shore: the spot is round it, still at the water.
	for x in range(-2, 3):
		var cell: int = terrain.get_index_from_position(CENTER + Vector2(float(x) * terrain.cell_size, -RADIUS - 20.0))
		terrain._set_obstacle(cell, "cliff")
	world._shore_spots.clear()
	var round_it: Vector2 = world.water_approach(world.water_sources[0], CENTER + Vector2(0.0, -400.0), body)
	a.is_true(round_it.distance_to(CENTER) <= drink_reach and world.scenery.segment_clear(round_it, round_it, body)
		and absf(round_it.x - CENTER.x) > terrain.cell_size, "a cliff on the near shore sends one round it (%s)" % round_it)
	Helpers.destroy_manager(manager)


func _test_the_shore_follows_the_level(a) -> void:
	var manager = Helpers.create_manager_with(_bundle(), 9981)
	var world = manager.world_state
	var terrain = world.terrain_system
	var source: Dictionary = world.water_sources[0]
	var ring: int = terrain.get_index_from_position(CENTER + Vector2(RADIUS - 40.0, 0.0))
	a.is_true(not terrain.is_walkable_index(ring), "under water while the pond is full")
	source["radius"] = RADIUS * 0.4
	world.lay_pond_water()
	var stubble: float = world.resource_system._get_cell_max_biomass(ring) * world.resource_system.stubble_fraction
	a.is_true(terrain.is_walkable_index(ring) and is_equal_approx(world.resource_system.get_biomass(ring), stubble),
		"the bed comes out as the water falls, greening from stubble")
	var deer = Helpers.spawn_herbivore(world, CENTER + Vector2(RADIUS - 40.0, 0.0))
	var spot: Vector2 = deer.position
	source["radius"] = RADIUS
	world.lay_pond_water()
	a.is_true(not terrain.is_walkable_index(ring) and world.resource_system.get_biomass(ring) == 0.0,
		"and goes under again as it rises")
	a.is_true(deer.position.distance_to(CENTER) >= RADIUS + deer.get_body_radius() * 0.5 - 0.5
		and world.scenery.segment_clear(deer.position, deer.position, deer.get_body_radius()),
		"a deer the water rose about steps out onto the shore (%.0f from %s)" % [deer.position.distance_to(CENTER), spot])
	# Barely moving water flips nothing: a pond drunk down while it rains does not flicker.
	var flooded: int = terrain._ponds[0]["flooded"]
	source["radius"] = RADIUS - 1.0
	world.lay_pond_water()
	source["radius"] = RADIUS
	world.lay_pond_water()
	a.equal(terrain._ponds[0]["flooded"], flooded, "a shore does not flicker")
	Helpers.destroy_manager(manager)


func _test_drinks_from_the_shore(a) -> void:
	var manager = Helpers.create_manager_with(_bundle(), 9981)
	var world = manager.world_state
	var deer = Helpers.spawn_herbivore(world, CENTER + Vector2(-RADIUS - 220.0, 30.0))
	deer.thirst = 90.0
	deer.hunger = 0.0
	var closest := INF
	var drank := false
	for _tick in range(360):
		manager.step_once()
		if not deer.is_alive:
			break
		closest = minf(closest, deer.position.distance_to(CENTER))
		drank = drank or deer.thirst < 60.0
	a.is_true(drank, "a thirsty deer drinks (thirst %.0f)" % deer.thirst)
	a.is_true(closest >= RADIUS + deer.get_body_radius() * 0.5 - 0.5, "from the shore, never in the water (%.0f)" % closest)
	Helpers.destroy_manager(manager)


func _test_stale_routes(a) -> void:
	var manager = Helpers.create_manager_with(_bundle(), 9981)
	var world = manager.world_state
	var terrain = world.terrain_system
	var source: Dictionary = world.water_sources[0]
	source["radius"] = 1.0
	world.lay_pond_water()
	var west := CENTER + Vector2(-RADIUS - 60.0, 0.0)
	var east := CENTER + Vector2(RADIUS + 60.0, 0.0)
	var straight: Dictionary = terrain.find_path(west, east)
	var through := false
	for cell in straight.get("cells", []):
		through = through or terrain.get_cell_center(int(cell)).distance_to(CENTER) < RADIUS * 0.5
	a.is_true(through, "a dry bed is walked straight across")
	source["radius"] = RADIUS
	world.lay_pond_water()
	var after: Dictionary = terrain.find_path(west, east)
	var dry := true
	for cell in after.get("cells", []):
		dry = dry and terrain.is_walkable_index(int(cell))
	a.is_true(bool(after.get("reachable", false)) and dry, "and once it fills, the remembered route is not handed out")
	Helpers.destroy_manager(manager)


func _test_sleeping_herd_at_the_shore(a) -> void:
	for enabled in [true, false]:
		var manager = Helpers.create_manager_with(_bundle(enabled), 9981)
		var world = manager.world_state
		var sector: Vector2i = world._get_sector_key(CENTER)
		var aggregate := {"goal_kind": "water", "goal_position": CENTER, "goal_sector": sector,
			"center": CENTER + Vector2(RADIUS + 20.0, 0.0)}
		a.equal(world._dormant_aggregate_reached_goal(sector, aggregate), enabled,
			"a sleeping herd at the shore is at the water while it is no ground (%s)" % enabled)
		Helpers.destroy_manager(manager)


func _test_save(a) -> void:
	var manager = Helpers.create_manager_with(_bundle(), 9981)
	var world = manager.world_state
	# Down past the hysteresis and a little back up: more cells under than the level alone says.
	_set_level(world, 0.25)
	_set_level(world, pow((RADIUS * 0.5 + 2.0) / RADIUS, 2.0))
	var floods: Dictionary = world.terrain_system.export_floods()
	var state: Dictionary = world.export_state()
	var loaded = Helpers.create_manager_with(_bundle(), 9981)
	loaded.world_state.import_state(state)
	a.equal(loaded.world_state.terrain_system.export_floods(), floods, "a save keeps the water where it was")
	a.equal(loaded.world_state.resource_system.export_cells(), world.resource_system.export_cells(), "and the grass")
	Helpers.destroy_manager(manager)
	Helpers.destroy_manager(loaded)


## Pond 0 at `level` (`WaterSystem`, whose levels a save carries), its water laid.
static func _set_level(world, level: float) -> void:
	world.water.levels[0] = level
	world.water._set_shore(0)
	world.lay_pond_water()
