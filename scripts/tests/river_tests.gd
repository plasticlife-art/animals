extends RefCounted

## Rivers (`terrain.rivers`): off, the world is the world without them; on, a river runs from
## inland off the map's edge, deep water blocking the way but for fords, the map still in one
## piece; the same for a seed and another for another; the world's stream untouched; animals drink
## at its banks, which never run dry and are no ponds; and an animal sees across it.

const Helpers := preload("res://scripts/tests/test_helpers.gd")
const TerrainSystemScript := preload("res://scripts/world/terrain_system.gd")
const WaterMaskScript := preload("res://scripts/ui/water_mask.gd")


func run(a) -> void:
	_test_off(a)
	_test_a_river(a)
	_test_banks(a)
	_test_fords_drawn(a)


static func _rivers(count: int = 1) -> Dictionary:
	return {"enabled": true, "count": count, "half_width_cells": 0.9, "min_length_fraction": 0.45, "wiggle": 3.0,
		"wiggle_frequency": 0.08, "climb_weight": 1.5, "pond_margin_cells": 2.0, "ford_every_cells": 12.0,
		"ford_width_cells": 2.5, "ford_cost": 2.5, "access_every_cells": 5.0, "seed": 0}


static func _bundle(seed: int, rivers: Dictionary) -> Dictionary:
	var bundle: Dictionary = Helpers.build_large_sector_bundle(seed)
	bundle["world"]["terrain"]["rivers"] = rivers
	return bundle


func _test_off(a) -> void:
	var plain: Dictionary = Helpers.build_large_sector_bundle(9971)
	plain["world"]["terrain"].erase("rivers")
	var reference = Helpers.create_manager_with(plain, 9971)
	Helpers.spawn_herd(reference.world_state, Vector2(800.0, 800.0), 6, 0)
	for _tick in range(60):
		reference.step_once()
	var off = Helpers.create_manager_with(_bundle(9971, {"enabled": false, "count": 2}), 9971)
	Helpers.spawn_herd(off.world_state, Vector2(800.0, 800.0), 6, 0)
	for _tick in range(60):
		off.step_once()
	a.equal(Helpers.world_fingerprint(off), Helpers.world_fingerprint(reference), "switched off is as if absent")
	a.is_true(off.world_state.terrain_system.rivers.is_empty() and off.world_state.pond_count() == off.world_state.water_sources.size(),
		"no river, no banks")
	Helpers.destroy_manager(reference)
	Helpers.destroy_manager(off)


func _test_a_river(a) -> void:
	var world = Helpers.create_manager_with(_bundle(9972, _rivers()), 9972).world_state
	var terrain = world.terrain_system
	a.equal(terrain.rivers.size(), 1, "a river")
	if terrain.rivers.is_empty():
		return
	var points: PackedVector2Array = terrain.rivers[0]["points"]
	var mouth: Vector2 = points[points.size() - 1]
	a.is_true(Rect2(Vector2.ZERO, terrain.world_size).grow(-terrain.cell_size * 4.0).has_point(points[0])
		and not Rect2(Vector2.ZERO, terrain.world_size).has_point(mouth), "from inland off the edge")
	var deep := 0
	var fords := 0
	var deep_walkable := false
	for index in range(terrain.get_cell_count()):
		match terrain.get_water_at_index(index):
			TerrainSystemScript.WATER_DEEP:
				deep += 1
				deep_walkable = deep_walkable or terrain.is_walkable_index(index)
			TerrainSystemScript.WATER_FORD:
				fords += 1
	a.is_true(deep > 20 and not deep_walkable and fords > 0, "deep water blocks the way, fords do not (%d deep, %d ford)" % [deep, fords])
	a.equal(terrain._collect_walkable_components().size(), 1, "the map stays in one piece")
	var ford_index := -1
	for index in range(terrain.get_cell_count()):
		if terrain.is_ford_index(index):
			ford_index = index
			break
	a.is_true(terrain.get_move_cost_at_index(ford_index) >= 2.5 and terrain.get_forage_init_multiplier(ford_index) == 0.0,
		"a ford is slow going, and bare")
	var again = Helpers.create_manager_with(_bundle(9972, _rivers()), 9972)
	var other = Helpers.create_manager_with(_bundle(9973, _rivers()), 9973)
	a.is_true(again.world_state.terrain_system.rivers[0]["points"] == points
		and other.world_state.terrain_system.rivers.size() > 0 and other.world_state.terrain_system.rivers[0]["points"] != points,
		"the same for a seed, another for another")
	var config: Dictionary = _bundle(9974, _rivers())["world"]
	var with_rng := RandomNumberGenerator.new()
	with_rng.seed = 9974
	TerrainSystemScript.new().initialize(config, with_rng, [])
	var without := config.duplicate(true)
	without["terrain"]["rivers"] = {"enabled": false}
	var without_rng := RandomNumberGenerator.new()
	without_rng.seed = 9974
	TerrainSystemScript.new().initialize(without, without_rng, [])
	a.equal(with_rng.state, without_rng.state, "the world's stream is not drawn from")
	# Across the deep water: no way through, but in sight.
	var deep_index := -1
	for index in range(terrain.get_cell_count()):
		if terrain.get_water_at_index(index) == TerrainSystemScript.WATER_DEEP:
			var coords: Vector2i = terrain.get_cell_coords(index)
			if coords.x > 3 and coords.y > 3 and coords.x < terrain.cols - 4 and coords.y < terrain.rows - 4:
				deep_index = index
				break
	var center: Vector2 = terrain.get_cell_center(deep_index)
	var across := _across(terrain, center)
	a.is_true(across.size() == 2 and not world.scenery.terrain_clear(across[0], across[1], 0.0)
		and world.scenery.terrain_clear(across[0], across[1], 0.0, true), "no way across the deep water, but sight across it")
	Helpers.destroy_manager(again)
	Helpers.destroy_manager(other)


## Two dry points either side of the deep water at `center`, on a line across it; [] if none.
static func _across(terrain, center: Vector2) -> Array:
	for direction in [Vector2.RIGHT, Vector2.DOWN, Vector2(1.0, 1.0).normalized(), Vector2(1.0, -1.0).normalized()]:
		var found: Array = []
		for side in [-1.0, 1.0]:
			for step in range(1, 6):
				var point: Vector2 = center + direction * side * terrain.cell_size * float(step)
				var index: int = terrain.get_index_from_position(point)
				if index >= 0 and terrain.is_walkable_index(index) and not terrain.is_water_index(index):
					found.append(point)
					break
		if found.size() == 2:
			return found
	return []


func _test_banks(a) -> void:
	var manager = Helpers.create_manager_with(_bundle(9972, _rivers()), 9972)
	var world = manager.world_state
	var banks: Array = world.water_sources.filter(func(source) -> bool: return bool(source.get("permanent", false)))
	var dry_ground := true
	for bank in banks:
		var index: int = world.terrain_system.get_index_from_position(bank["position"])
		dry_ground = dry_ground and world.terrain_system.is_walkable_index(index) and not world.terrain_system.is_water_index(index)
	a.is_true(banks.size() >= 4 and dry_ground, "animals drink at points on both banks, on dry ground (%d)" % banks.size())
	var plain = Helpers.create_manager_with(_bundle(9972, {"enabled": false}), 9972)
	a.is_true(is_equal_approx(world.water.mean_radius, plain.world_state.water.mean_radius) and world.pond_count() == plain.world_state.pond_count(),
		"the banks are no ponds: not measured")
	var bank_index := int(banks[0]["index"])
	if world.water.enabled:
		var level: float = world.water.levels[bank_index]
		world.water.step(10.0, world.climate)
		world.water.add_to_all(-0.5)
		a.is_true(world.water.drink(bank_index, 40.0) == 40.0 and world.water.levels[bank_index] == level, "and they never run dry")
	else:
		a.equal(world.water.drink(bank_index, 40.0), 40.0, "and they give every drink")
	Helpers.destroy_manager(manager)
	Helpers.destroy_manager(plain)


## The water field marks a ford's texels, so the shader can draw the bar across the stream; the
## rest of the river is owned by no pond, as before.
func _test_fords_drawn(a) -> void:
	var manager = Helpers.create_manager_with(_bundle(9972, _rivers()), 9972)
	var world = manager.world_state
	var river: Dictionary = world.terrain_system.rivers[0]
	var texel: float = world.terrain_system.cell_size * 0.5
	var mask: Dictionary = WaterMaskScript.bake([], world.bounds.end, texel, texel * 3.0, [river],
		2.5 * world.terrain_system.cell_size * 0.5)
	var at_ford: Vector2 = river["fords"][0]
	var ford_texel := int(floor(at_ford.y / texel)) * int(mask["cols"]) + int(floor(at_ford.x / texel))
	a.equal(mask["ids"][ford_texel], WaterMaskScript.FORD_ID, "a ford's texel is marked")
	var points: PackedVector2Array = river["points"]
	var plain_marked := 0
	var plain := 0
	for point in points:
		var near_ford := false
		for spot in river["fords"]:
			near_ford = near_ford or point.distance_to(spot) < world.terrain_system.cell_size * 3.0
		if near_ford or not Rect2(Vector2.ZERO, world.bounds.end).has_point(point):
			continue
		var index := int(floor(point.y / texel)) * int(mask["cols"]) + int(floor(point.x / texel))
		plain += 1
		if mask["ids"][index] == WaterMaskScript.FORD_ID:
			plain_marked += 1
	a.is_true(plain > 10 and plain_marked == 0, "and the rest of the river is not (%d of %d)" % [plain_marked, plain])
	Helpers.destroy_manager(manager)
