extends RefCounted

## Targets an awake animal cannot reach (`AgentBase.unreachable_targets`): navigation says when
## its route search found none, and a deer leaves a pond, a predator a carcass it cannot get
## to, for one it can, instead of standing at the wall until its strength is gone. The memory
## lapses, keeps to a dozen and travels with the animal's state.

const Helpers := preload("res://scripts/tests/test_helpers.gd")
const AgentBaseScript := preload("res://scripts/agents/agent_base.gd")

const DELTA := 1.0 / 12.0
## The fixture is 8 x 8 cells of 32. The wall rings the 2 x 2 cells around (192, 192), where
## the second pond lies.
const SHUT_IN := Vector2(192.0, 192.0)


func run(a) -> void:
	_test_navigation_says_when_there_is_no_route(a)
	_test_deer_leaves_a_pond_it_cannot_reach(a)
	_test_predator_leaves_a_carcass_it_cannot_reach(a)
	_test_memory_lapses_and_keeps_to_a_dozen(a)
	_test_memory_travels_with_the_animal(a)


## Walls in the cells around `SHUT_IN`: rows and columns 4 to 7, the inner four left open.
func _wall_in(world) -> void:
	var terrain = world.terrain_system
	for row in range(4, 8):
		for column in range(4, 8):
			if row in [5, 6] and column in [5, 6]:
				continue
			terrain._walkable[row * terrain.cols + column] = 0
	# The route search reads neighbour lists and routes cached when the terrain was built.
	terrain._cached_walkable_neighbors.clear()
	terrain._path_cache.clear()
	terrain._path_cache_order.clear()


## Asks for a route to `goal` until the search has an answer (it may run over a few ticks).
func _route(world, animal, goal: Vector2) -> void:
	for tick in range(12):
		world.current_tick += 1
		world._prepare_navigation_budget()
		world.get_next_waypoint(animal.position, goal, animal.id)
		if not animal.path_cells.is_empty() or animal.navigation_direct_clear:
			return


func _test_navigation_says_when_there_is_no_route(a) -> void:
	var manager = Helpers.create_manager(9501)
	var world = manager.world_state
	_wall_in(world)
	var deer = Helpers.spawn_herbivore(world, Vector2(48.0, 208.0))
	_route(world, deer, SHUT_IN + Vector2(8.0, 8.0))
	a.is_true(not deer.path_reachable, "no route into the walled cells")
	_route(world, deer, Vector2(48.0, 48.0))
	a.is_true(deer.path_reachable, "a clear way is a route")
	deer.clear_navigation()
	a.is_true(deer.path_reachable, "and a fresh start assumes one")
	Helpers.destroy_manager(manager)


func _test_deer_leaves_a_pond_it_cannot_reach(a) -> void:
	var manager = Helpers.create_manager(9502)
	var world = manager.world_state
	_wall_in(world)
	# Nearer the walled pond (about 80 away) than the open one at (64, 64) (about 150).
	var deer = Helpers.spawn_herbivore(world, Vector2(112.0, 208.0))
	deer.thirst = 80.0
	var walled: Dictionary = world.water_sources[1]
	a.equal(Vector2(walled["position"]), SHUT_IN, "the fixture's second pond is the walled one")
	var going := true
	for tick in range(12):
		world.current_tick += 1
		world._prepare_navigation_budget()
		going = deer._seek_or_drink(world, DELTA, [], walled)
		if not going:
			break
	a.is_true(not going, "it gives the walled pond up")
	a.is_true(deer.is_unreachable(AgentBaseScript.place_key(SHUT_IN), world.current_time), "and remembers it has no way there")
	var next: Dictionary = deer._resolve_water_target(world)
	a.equal(Vector2(next.get("position", Vector2.INF)), Vector2(64.0, 64.0), "the pond it can reach instead")
	a.equal(Vector2(world._water_target_for(deer, 400.0).get("position", Vector2.INF)), Vector2(64.0, 64.0),
		"which is also what its next decision is shown")
	world.current_tick += 1
	world._prepare_navigation_budget()
	a.is_true(deer._seek_or_drink(world, DELTA, [], next), "and it sets off for it")
	Helpers.destroy_manager(manager)


func _test_predator_leaves_a_carcass_it_cannot_reach(a) -> void:
	var manager = Helpers.create_manager(9503)
	var world = manager.world_state
	_wall_in(world)
	var fox = Helpers.spawn_predator(world, Vector2(112.0, 208.0))
	fox.hunger = 60.0
	var walled := Helpers.spawn_carcass(world, SHUT_IN + Vector2(8.0, 8.0))
	var open := Helpers.spawn_carcass(world, Vector2(48.0, 48.0))
	a.equal(int(fox.choose_carcass(world).get("id", -1)), walled, "the walled body is the nearest")
	var feeding := true
	for tick in range(12):
		world.current_tick += 1
		world._prepare_navigation_budget()
		feeding = fox.scavenge_or_feed(world, DELTA)
		if not feeding:
			break
	a.is_true(not feeding and fox.target_carcass_id == -1, "it lets the walled body go")
	a.is_true(fox.is_unreachable(AgentBaseScript.carcass_key(walled), world.current_time), "and passes it by for a while")
	a.equal(int(fox.choose_carcass(world).get("id", -1)), open, "choosing the one it can reach")
	world.current_tick += 1
	world._prepare_navigation_budget()
	a.is_true(fox.scavenge_or_feed(world, DELTA) and fox.target_carcass_id == open, "and going for it")
	Helpers.destroy_manager(manager)


func _test_memory_lapses_and_keeps_to_a_dozen(a) -> void:
	var manager = Helpers.create_manager(9504)
	var world = manager.world_state
	var deer = Helpers.spawn_herbivore(world, Vector2(48.0, 48.0))
	deer.mark_unreachable("p1,1", 10.0, 30.0)
	a.is_true(deer.is_unreachable("p1,1", 39.9), "left alone for its while")
	a.is_true(not deer.is_unreachable("p1,1", 40.1), "and tried again after it")
	for index in range(14):
		deer.mark_unreachable("c%d" % index, 50.0 + float(index), 30.0)
	a.equal(deer.unreachable_targets.size(), AgentBaseScript.MAX_UNREACHABLE, "a dozen kept")
	a.is_true(not deer.unreachable_targets.has("p1,1") and not deer.unreachable_targets.has("c0")
		and deer.unreachable_targets.has("c13"), "the lapsed and the soonest to lapse go first")
	Helpers.destroy_manager(manager)


func _test_memory_travels_with_the_animal(a) -> void:
	var manager = Helpers.create_manager(9505)
	var world = manager.world_state
	var deer = Helpers.spawn_herbivore(world, Vector2(48.0, 48.0))
	deer.mark_unreachable(AgentBaseScript.place_key(SHUT_IN), 5.0, 30.0)
	deer.path_reachable = false
	var state: Dictionary = deer.export_runtime_state()
	var other = Helpers.spawn_herbivore(world, Vector2(80.0, 48.0))
	other.apply_runtime_state(state)
	a.equal(other.unreachable_targets, deer.unreachable_targets, "through sleep, waking and saves")
	a.is_true(not other.path_reachable, "with what its route last said")
	Helpers.destroy_manager(manager)

