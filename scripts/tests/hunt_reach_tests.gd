extends RefCounted

## A hunter's reach on foot (`WorldState.hunt_reach()`, `hunt.reach_leash_share`): an animal sees
## across water, so a fox used to pick a deer over a river, run at the bank and stand there
## pushing at the water - its route waiting in the queue while the deer moved on - until the
## chase's clock ran out, its strength spent, and then take the next deer of the same herd. Now a
## prey with no way to it on foot within half as far again as the chase's leash is let be: none
## chosen over it, no hunt begun, a chase given up the moment its prey is out of reach
## (`no_way`); and one with a ford near is run down through the ford.

const Helpers := preload("res://scripts/tests/test_helpers.gd")
const TerrainSystemScript := preload("res://scripts/world/terrain_system.gd")

const DELTA := 1.0 / 12.0
## The fixture (`build_large_sector_bundle()`) is 48 x 48 cells of 64. The river runs down
## columns 22 and 23, x 1408 to 1536, from edge to edge.
const RIVER_COLUMNS := [22, 23]
const ROW_Y := 1504.0
const FOX_AT := Vector2(1250.0, ROW_Y)
## In sight of the fox (480) across the river, nearer than `OWN_BANK`.
const ACROSS := Vector2(1620.0, ROW_Y)
const OWN_BANK := Vector2(850.0, ROW_Y)
## A ford two rows below the fox's (rows 25-26): its way round is about 560, under its reach
## (520 x 1.5 = 780). One at rows 40-41 is some 2200 round.
const NEAR_FORD_ROW := 25
const FAR_FORD_ROW := 40


func run(a) -> void:
	_test_sight_crosses_the_river(a)
	_test_the_deer_on_its_own_bank(a)
	_test_no_hunt_over_the_river(a)
	_test_a_near_ford_is_run_through(a)
	_test_a_far_ford_is_too_far(a)
	_test_a_chase_given_up_when_the_prey_crosses(a)
	_test_a_mate_over_the_river_is_not_joined(a)
	_test_the_reach_follows_the_water(a)
	_test_switched_off(a)


func _world(seed: int, ford_row: int = -1, share: float = -1.0):
	var bundle: Dictionary = Helpers.build_large_sector_bundle(seed)
	if share >= 0.0:
		bundle["species"]["predator"]["hunt"]["reach_leash_share"] = share
	var manager = Helpers.create_manager_with(bundle, seed)
	_river(manager.world_state, ford_row)
	return manager


## Deep water down `RIVER_COLUMNS` from edge to edge, but for a ford two cells long at
## `ford_row` (-1: none); the caches that read the ground are emptied after.
func _river(world, ford_row: int) -> void:
	var terrain = world.terrain_system
	if terrain._water.is_empty():
		terrain._water.resize(terrain.get_cell_count())
	for row in range(terrain.rows):
		for column in RIVER_COLUMNS:
			var index: int = row * terrain.cols + column
			if ford_row >= 0 and row in [ford_row, ford_row + 1]:
				terrain._water[index] = TerrainSystemScript.WATER_FORD
				terrain._clear_obstacle(index)
			else:
				terrain._water[index] = TerrainSystemScript.WATER_DEEP
				terrain._set_obstacle(index, "water")
	terrain._refresh_navigation_cache()
	terrain._path_cache.clear()
	terrain._path_cache_order.clear()
	world._walk_reachable_cache.clear()
	world._walk_reachable_order.clear()
	world._hunt_reach_cache.clear()
	world._hunt_reach_order.clear()


func _hungry_fox(world, at: Vector2):
	var fox = Helpers.spawn_predator(world, at)
	fox.hunger = 70.0
	fox.thirst = 0.0
	fox.energy = 100.0
	return fox


func _deer(world, at: Vector2):
	var deer = Helpers.spawn_herbivore(world, at)
	deer.energy = 100.0
	return deer


func _step(world) -> void:
	world.current_tick += 1
	world.current_time += DELTA
	world._prepare_navigation_budget()


func _test_sight_crosses_the_river(a) -> void:
	var manager = _world(9601)
	var world = manager.world_state
	var fox = _hungry_fox(world, FOX_AT)
	var deer = _deer(world, ACROSS)
	a.is_true(world.can_see(fox, deer, world.perception_radius(fox, "vision_radius", 480.0)), "the fox sees the deer over the water")
	a.is_true(not world.scenery.terrain_clear(fox.position, deer.position, fox.get_body_radius()), "but has no straight way to it")
	a.is_true(not fox.can_hunt_reach(world, deer.position), "nor any within its reach")
	Helpers.destroy_manager(manager)


func _test_the_deer_on_its_own_bank(a) -> void:
	var manager = _world(9602)
	var world = manager.world_state
	var fox = _hungry_fox(world, FOX_AT)
	var across = _deer(world, ACROSS)
	var own = _deer(world, OWN_BANK)
	a.is_true(fox.position.distance_to(across.position) < fox.position.distance_to(own.position), "the deer over the river is the nearer")
	var chosen = fox._choose_prey(world)
	a.equal(-1 if chosen == null else chosen.id, own.id, "the fox picks the one on its own bank")
	a.equal(fox.get_prey_isolation(world, own), fox._prey_isolation(world, own), "and what it scored for it is what it keeps")
	Helpers.destroy_manager(manager)


func _test_no_hunt_over_the_river(a) -> void:
	var manager = _world(9603)
	var world = manager.world_state
	var fox = _hungry_fox(world, FOX_AT)
	var deer = _deer(world, ACROSS)
	a.is_true(fox._choose_prey(world) == null, "a deer over the river only: none to hunt")
	a.is_true(world.build_predator_snapshot(fox).prey_target == null, "which is what its decision is shown")
	_step(world)
	a.is_true(not fox._hunt(world, DELTA, deer), "told to hunt it anyway, it begins no hunt")
	a.equal([fox.target_agent_id, fox.state != "seek_prey"], [-1, true], "and takes up no target")
	var started: Vector2 = fox.position
	var chasing := 0
	for tick in range(120):
		_step(world)
		fox.tick(world, DELTA)
		if fox.state in fox.CHASE_STATES:
			chasing += 1
	a.equal([int(manager.stats_system.counters.get("hunts_started", 0)), chasing], [0, 0],
		"ten seconds by the river: no hunt, not a tick of chasing")
	a.is_true(fox.position.x < 1408.0 - fox.get_body_radius() + 0.5, "and it is still on its bank (moved %.0f)" % fox.position.distance_to(started))
	Helpers.destroy_manager(manager)


func _test_a_near_ford_is_run_through(a) -> void:
	var manager = _world(9604, NEAR_FORD_ROW)
	var world = manager.world_state
	var terrain = world.terrain_system
	var fox = _hungry_fox(world, FOX_AT)
	var deer = _deer(world, ACROSS)
	a.is_true(fox.can_hunt_reach(world, deer.position), "with a ford near, the deer is within its reach")
	var chosen = fox._choose_prey(world)
	a.equal(-1 if chosen == null else chosen.id, deer.id, "and its prey")
	var through_ford := false
	var reached := false
	for tick in range(240):
		_step(world)
		fox.tick(world, DELTA)
		through_ford = through_ford or terrain.is_ford_index(terrain.get_index_from_position(fox.position))
		if not deer.is_alive or fox.position.distance_to(deer.position) <= fox.get_body_radius() + deer.get_body_radius() + 6.0:
			reached = true
			break
	a.is_true(through_ford, "the fox runs round by the ford")
	a.is_true(reached, "and gets to the deer (%.0f from it)" % fox.position.distance_to(deer.position))
	a.equal(int(manager.stats_system.counters.get("hunt_fail_timeout", 0)), 0, "with no chase run out at the bank")
	Helpers.destroy_manager(manager)


func _test_a_far_ford_is_too_far(a) -> void:
	var manager = _world(9605, FAR_FORD_ROW)
	var world = manager.world_state
	var fox = _hungry_fox(world, FOX_AT)
	var deer = _deer(world, ACROSS)
	var route: Dictionary = world.terrain_system.find_path(fox.position, deer.position)
	a.is_true(bool(route.get("reachable", false)), "there is a way, by the far ford")
	a.is_true(not fox.can_hunt_reach(world, deer.position) and fox._choose_prey(world) == null,
		"but further round than the fox would go: no prey")
	Helpers.destroy_manager(manager)


func _test_a_chase_given_up_when_the_prey_crosses(a) -> void:
	var manager = _world(9606)
	var world = manager.world_state
	var fox = _hungry_fox(world, FOX_AT)
	var deer = _deer(world, FOX_AT + Vector2(-200.0, 0.0))
	_step(world)
	a.is_true(fox._hunt(world, DELTA, deer), "a deer on its own bank: the hunt begins")
	_step(world)
	a.is_true(fox._continue_or_finish_chase(world, DELTA), "and the chase runs on")
	# The deer gets over (as by a ford out of the fox's reach).
	deer.position = ACROSS
	Helpers._refresh_spatial_queries(world)
	_step(world)
	var going: bool = fox._continue_or_finish_chase(world, DELTA)
	a.is_true(not going and fox.target_agent_id == -1, "once it is over the river the fox gives it up at once")
	a.equal(int(manager.stats_system.counters.get("hunt_fail_no_way", 0)), 1, "told as a chase with no way")
	a.equal(int(manager.stats_system.counters.get("hunt_fail_timeout", 0)), 0, "not one whose clock ran out")
	Helpers.destroy_manager(manager)


func _test_a_mate_over_the_river_is_not_joined(a) -> void:
	var manager = _world(9607)
	var world = manager.world_state
	var fox = _hungry_fox(world, FOX_AT)
	var mate = _hungry_fox(world, ACROSS + Vector2(120.0, 60.0))
	mate.sex = "female"
	var deer = _deer(world, ACROSS)
	fox.preferred_mate_id = mate.id
	mate.preferred_mate_id = fox.id
	mate.target_agent_id = deer.id
	mate.set_state("chase", world.current_tick)
	var vision: float = world.perception_radius(fox, "vision_radius", 480.0)
	a.is_true(fox._mates_prey(world, vision) == null, "the mate's deer over the river is not joined")
	_river(world, NEAR_FORD_ROW)
	a.equal(-1 if fox._mates_prey(world, vision) == null else fox._mates_prey(world, vision).id, deer.id,
		"with a ford near, it is")
	Helpers.destroy_manager(manager)


func _test_the_reach_follows_the_water(a) -> void:
	var manager = _world(9608)
	var world = manager.world_state
	var terrain = world.terrain_system
	var start: int = terrain.get_index_from_position(FOX_AT)
	var reach: Dictionary = world.hunt_reach(start, 780.0)
	a.is_true(world.hunt_reach(start, 780.0) == reach and world._hunt_reach_cache.size() == 1, "kept for the next hunter there")
	var builds := int(world.performance_counters.get("hunt_reach_builds", 0))
	world.hunt_reach(start, 780.0)
	a.equal(int(world.performance_counters.get("hunt_reach_builds", 0)), builds, "and not searched again")
	var far := PackedInt32Array([terrain.get_index_from_position(Vector2(2900.0, 2900.0))])
	world._forget_hunt_reach_about(far)
	a.equal(world._hunt_reach_cache.size(), 1, "water far off leaves it be")
	var near := PackedInt32Array([terrain.get_index_from_position(FOX_AT + Vector2(256.0, 128.0))])
	world._forget_hunt_reach_about(near)
	a.equal(world._hunt_reach_cache.size(), 0, "water within it has it measured again")
	var fresh: Dictionary = terrain.walk_field_within(start, 780.0)
	a.equal(fresh["cost"], reach["cost"], "to the same answer while the ground is the same")
	var across: int = terrain.get_index_from_position(ACROSS)
	a.is_true(not (fresh["cost"] as Dictionary).has(across), "no cell over the river within it")
	Helpers.destroy_manager(manager)


func _test_switched_off(a) -> void:
	var manager = _world(9609, -1, 0.0)
	var world = manager.world_state
	var fox = _hungry_fox(world, FOX_AT)
	var across = _deer(world, ACROSS)
	_deer(world, OWN_BANK)
	var chosen = fox._choose_prey(world)
	a.equal(-1 if chosen == null else chosen.id, across.id, "reach_leash_share 0: the nearest in sight, as before")
	Helpers.destroy_manager(manager)
