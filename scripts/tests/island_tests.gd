extends RefCounted

## The island (`terrain.island`, `IslandMask`): off, the world is the world without it; on, one
## piece of land with sea all round it to the map's edge, the same for a seed and another for
## another, the world's stream untouched; the ponds on the land, the rivers down to the sea and
## no ford by it; the sea never drunk from; the animals placed on the land and not round its
## beaches, the dens half a radius from the sea, a flight from the beach kept ashore; and the
## districts named on the land only.

const Helpers := preload("res://scripts/tests/test_helpers.gd")
const TerrainSystemScript := preload("res://scripts/world/terrain_system.gd")
const PlaceNamesScript := preload("res://scripts/story/place_names.gd")


func run(a) -> void:
	_test_off(a)
	_test_the_mask(a)
	_test_an_island(a)
	_test_ponds_and_rivers(a)
	_test_the_sea_is_not_drunk(a)
	_test_placed_on_land(a)
	_test_dens_off_the_sea(a)
	_test_flight_stays_ashore(a)
	_test_districts_on_land(a)


static func _island(extra: Dictionary = {}) -> Dictionary:
	var config := {"enabled": true, "land_share": 0.55, "shape_power": 2.2, "noise_frequency": 0.05,
		"noise_amplitude": 0.4, "noise_octaves": 4, "warp": 6.0, "min_sea_cells": 3, "edge_band_cells": 5.0,
		"beach_cells": 1.5}
	config.merge(extra, true)
	return config


## A map 96 by 54 cells of 64 units, a sector as wide as the shipped one's.
static func _bundle(seed: int, island: Dictionary) -> Dictionary:
	var bundle: Dictionary = Helpers.build_large_sector_bundle(seed)
	bundle["world"]["world_size"] = {"x": 6144.0, "y": 3456.0}
	bundle["world"]["water_sources"] = []
	bundle["world"]["terrain"]["island"] = island
	return bundle


func _test_off(a) -> void:
	var plain: Dictionary = _bundle(9981, {})
	plain["world"]["terrain"].erase("island")
	var reference = Helpers.create_manager_with(plain, 9981)
	Helpers.spawn_herd(reference.world_state, Vector2(3000.0, 1700.0), 6, 0)
	for _tick in range(60):
		reference.step_once()
	var off = Helpers.create_manager_with(_bundle(9981, {"enabled": false, "land_share": 0.4}), 9981)
	Helpers.spawn_herd(off.world_state, Vector2(3000.0, 1700.0), 6, 0)
	for _tick in range(60):
		off.step_once()
	a.equal(Helpers.world_fingerprint(off), Helpers.world_fingerprint(reference), "switched off is as if absent")
	a.is_true(not off.world_state.terrain_system.has_island() and off.world_state.island_mask.is_empty()
		and off.world_state.terrain_system.coast_distance_at(Vector2(10.0, 10.0)) == INF, "no island, no sea, no coast")
	Helpers.destroy_manager(reference)
	Helpers.destroy_manager(off)


func _test_the_mask(a) -> void:
	var config: Dictionary = _bundle(9982, _island())["world"]
	var mask := IslandMask.build(config, 9982)
	var cols: int = mask["cols"]
	var rows: int = mask["rows"]
	var land: PackedByteArray = mask["land"]
	var coast: PackedFloat32Array = mask["coast"]
	a.is_true(cols == 96 and rows == 54, "a cell of the terrain's grid each (%dx%d)" % [cols, rows])
	var share := float(IslandMask.land_count(mask)) / float(cols * rows)
	a.is_true(absf(share - 0.55) < 0.06, "about `land_share` of the map is land (%.2f)" % share)
	var edge_sea := true
	for x in range(cols):
		for y in [0, 1, 2, rows - 3, rows - 2, rows - 1]:
			edge_sea = edge_sea and land[y * cols + x] == IslandMask.SEA
	for y in range(rows):
		for x in [0, 1, 2, cols - 3, cols - 2, cols - 1]:
			edge_sea = edge_sea and land[y * cols + x] == IslandMask.SEA
	a.is_true(edge_sea, "sea along the whole edge, `min_sea_cells` wide")
	var pieces: Array = IslandMask._pieces(land, cols, rows, IslandMask.LAND)
	var seas: Array = IslandMask._pieces(land, cols, rows, IslandMask.SEA)
	a.is_true(pieces[1] == 1 and seas[1] == 1, "one land and one sea, no lake inside (%d, %d)" % [pieces[1], seas[1]])
	var coast_right := true
	for index in range(land.size()):
		coast_right = coast_right and (coast[index] == 0.0) == (land[index] == IslandMask.SEA)
		if land[index] == IslandMask.LAND:
			coast_right = coast_right and coast[index] >= 1.0
	a.is_true(coast_right, "the coast's distance is 0 at sea and a cell or more on land")
	var again := IslandMask.build(config, 9982)
	var other := IslandMask.build(config, 9983)
	a.is_true(again["land"] == land and other["land"] != land, "the same for a seed, another for another")
	a.is_true(IslandMask.build(_bundle(9982, {"enabled": false})["world"], 9982).is_empty(), "nothing without an island")


func _test_an_island(a) -> void:
	var manager = Helpers.create_manager_with(_bundle(9982, _island()), 9982)
	var terrain = manager.world_state.terrain_system
	var land: PackedByteArray = manager.world_state.island_mask["land"]
	var sea_right := true
	for index in range(terrain.get_cell_count()):
		var sea: bool = land[index] == IslandMask.SEA
		sea_right = sea_right and terrain.is_sea_index(index) == sea
		if sea:
			sea_right = sea_right and not terrain.is_walkable_index(index) and terrain.is_water_index(index) \
				and not terrain.is_ford_index(index) and terrain.get_obstacle_at_index(index) == "water"
	a.is_true(sea_right, "the sea is deep water: no walking, no ford")
	a.equal(terrain._collect_walkable_components().size(), 1, "the land stays in one piece")
	var rect: Rect2 = terrain.land_rect
	a.is_true(rect.size.x > 0.0 and Rect2(Vector2.ZERO, terrain.world_size).grow(-terrain.cell_size * 2.0).encloses(rect),
		"the land's box lies inside the map")
	var config: Dictionary = _bundle(9984, _island())["world"]
	var with_rng := RandomNumberGenerator.new()
	with_rng.seed = 9984
	TerrainSystemScript.new().initialize(config, with_rng, [])
	var without := config.duplicate(true)
	without["terrain"]["island"] = {"enabled": false}
	var without_rng := RandomNumberGenerator.new()
	without_rng.seed = 9984
	TerrainSystemScript.new().initialize(without, without_rng, [])
	a.equal(with_rng.state, without_rng.state, "the world's stream is not drawn from")
	Helpers.destroy_manager(manager)


func _test_ponds_and_rivers(a) -> void:
	var bundle := _bundle(9985, _island())
	bundle["world"]["water_generation"] = {"sources_per_million_units": 1.6, "radius_min": 90.0, "radius_max": 130.0}
	bundle["world"]["terrain"]["rivers"] = {"enabled": true, "count": 2, "half_width_cells": 0.9,
		"min_length_fraction": 0.35, "wiggle": 3.0, "wiggle_frequency": 0.08, "climb_weight": 1.5,
		"pond_margin_cells": 2.0, "ford_every_cells": 10.0, "ford_width_cells": 2.5, "ford_cost": 2.5,
		"access_every_cells": 5.0, "seed": 0}
	var manager = Helpers.create_manager_with(bundle, 9985)
	var world = manager.world_state
	var terrain = world.terrain_system
	var ponds := 0
	var ponds_ashore := true
	for source in world.water_sources:
		if bool(source.get("permanent", false)):
			continue
		ponds += 1
		var coast: float = terrain.coast_distance_at(source["position"])
		ponds_ashore = ponds_ashore and coast >= float(source["radius"]) + terrain.cell_size
	a.is_true(ponds > 3 and ponds_ashore, "the ponds lie on the land, a cell clear of the sea (%d)" % ponds)
	a.is_true(terrain.rivers.size() >= 1, "a river (%d)" % terrain.rivers.size())
	var down_to_sea := true
	var fords_inland := true
	for river in terrain.rivers:
		var points: PackedVector2Array = river["points"]
		down_to_sea = down_to_sea and not terrain.is_sea_position(points[0]) and terrain.is_sea_position(points[points.size() - 1])
		for spot in river["fords"]:
			fords_inland = fords_inland and terrain.coast_distance_at(spot) >= 3.0 * terrain.cell_size
	a.is_true(down_to_sea, "every river runs from the land down to the sea")
	a.is_true(fords_inland, "no ford within three cells of the sea")
	var banks_ashore := true
	for source in world.water_sources:
		if bool(source.get("permanent", false)):
			banks_ashore = banks_ashore and not terrain.is_sea_position(source["position"])
	a.is_true(banks_ashore, "no drinking spot out at sea")
	a.equal(terrain._collect_walkable_components().size(), 1, "the land still in one piece across its rivers")
	Helpers.destroy_manager(manager)


## A thirsty deer on the beach, no pond and no river anywhere: it never drinks.
func _test_the_sea_is_not_drunk(a) -> void:
	var manager = Helpers.create_manager_with(_bundle(9982, _island()), 9982)
	var world = manager.world_state
	var terrain = world.terrain_system
	var beach := Vector2.INF
	for index in range(terrain.get_cell_count()):
		if terrain.is_walkable_index(index) and terrain.coast_cells_at_index(index) <= 1.0:
			beach = terrain.get_cell_center(index)
			break
	var deer = Helpers.spawn_herbivore(world, beach, 0)
	deer.thirst = 70.0
	var lowest: float = deer.thirst
	for _tick in range(120):
		manager.step_once()
		if not is_instance_valid(deer) or not deer.is_alive:
			break
		lowest = minf(lowest, deer.thirst)
	a.is_true(lowest >= 70.0, "the sea is salt: a deer by it drinks nothing (thirst %.1f at least)" % lowest)
	Helpers.destroy_manager(manager)


func _test_placed_on_land(a) -> void:
	var manager = Helpers.create_manager_with(_bundle(9982, _island()), 9982)
	var world = manager.world_state
	var terrain = world.terrain_system
	var at_sea := 0
	var on_beach := 0
	for _draw in range(200):
		var point: Vector2 = world.random_point()
		if terrain.is_sea_position(point) or not terrain.is_walkable_position(point):
			at_sea += 1
		if terrain.coast_distance_at(point) <= terrain.cell_size * 2.0:
			on_beach += 1
	a.equal(at_sea, 0, "every point drawn is on walkable land")
	a.is_true(on_beach < 60, "and not most of them on the beach (%d of 200)" % on_beach)
	Helpers.destroy_manager(manager)


## Foxes' dens: a wolf's range is too wide for an island this small.
func _test_dens_off_the_sea(a) -> void:
	var bundle := _bundle(9982, _island())
	bundle["species"]["predator"]["territory"] = ConfigLoader.load_config_bundle()["species"]["predator"]["territory"].duplicate(true)
	# A den wants water near.
	bundle["world"]["water_generation"] = {"sources_per_million_units": 1.6, "radius_min": 90.0, "radius_max": 130.0}
	var manager = Helpers.create_manager_with(bundle, 9982)
	var world = manager.world_state
	var registry = world.territory_registry("predator")
	var config: Dictionary = world.territory_config("predator")
	var half: float = float(config.get("radius_cells", 10.0)) * 0.5 * world.terrain_system.cell_size
	var off_the_sea := true
	for territory in registry.territories:
		off_the_sea = off_the_sea and world.terrain_system.coast_distance_at(territory["den"]) >= half
	a.is_true(registry.size() > 0 and off_the_sea, "every den half a radius from the sea (%d dens)" % registry.size())
	Helpers.destroy_manager(manager)


## Fleeing out to sea, a deer on the beach makes for somewhere ashore.
func _test_flight_stays_ashore(a) -> void:
	var manager = Helpers.create_manager_with(_bundle(9982, _island()), 9982)
	var world = manager.world_state
	var terrain = world.terrain_system
	var beach := -1
	for index in range(terrain.get_cell_count()):
		if terrain.is_walkable_index(index) and terrain.coast_cells_at_index(index) <= 1.0:
			beach = index
			break
	var from: Vector2 = terrain.get_cell_center(beach)
	var seaward := Vector2.ZERO
	for offset in [Vector2.LEFT, Vector2.RIGHT, Vector2.UP, Vector2.DOWN]:
		if terrain.is_sea_position(from + offset * terrain.cell_size):
			seaward = offset
			break
	var threats: Array[Vector2] = [from - seaward * 200.0]
	var to: Vector2 = world.choose_escape_destination(from, seaward, 400.0, -1, threats, 8.0)
	a.is_true(seaward != Vector2.ZERO and not terrain.is_sea_position(to) and terrain.is_walkable_position(to),
		"its flight ends ashore (%s)" % str(to))
	Helpers.destroy_manager(manager)


func _test_districts_on_land(a) -> void:
	var manager = Helpers.create_manager_with(_bundle(9982, _island()), 9982)
	var world = manager.world_state
	var terrain = world.terrain_system
	var places = PlaceNamesScript.new()
	places.build(world, 9982)
	var ashore := true
	for district in places.districts:
		ashore = ashore and not terrain.is_sea_position(district["center"])
	var sea_unnamed := true
	var land_named := true
	for index in range(terrain.get_cell_count()):
		var point: Vector2 = terrain.get_cell_center(index)
		if terrain.is_sea_index(index):
			sea_unnamed = sea_unnamed and places.district_at(point) == -1
		else:
			land_named = land_named and places.district_at(point) >= 0
	a.is_true(places.districts.size() >= 2 and ashore, "the districts lie on the land (%d)" % places.districts.size())
	a.is_true(sea_unnamed and land_named, "the sea is no district, all the land is in one")
	Helpers.destroy_manager(manager)
