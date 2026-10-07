extends RefCounted

## Hunters turning from rare prey (`WorldState.prey_preference()`, `balance.prey_switching`):
## the preference by a species' share of all the prey, a fox that notices a rare deer only
## near it, sleeping hunters catching less of a rare species, and nothing changed with the
## block off or while every species is common.

const Helpers := preload("res://scripts/tests/test_helpers.gd")
const SimulationTests := preload("res://scripts/tests/simulation_tests.gd")

const SWITCHING := {"enabled": true, "reference_share": {"herbivore": 0.5, "scavenger": 0.2}, "min_preference": 0.1}


func run(a) -> void:
	_test_preference_follows_the_share(a)
	_test_a_fox_notices_a_rare_deer_only_near(a)
	_test_sleeping_hunters_catch_less_of_a_rare_prey(a)


func _bundle(seed: int, switching: Dictionary = SWITCHING) -> Dictionary:
	var bundle: Dictionary = Helpers.build_test_bundle(seed)
	bundle["balance"]["prey_switching"] = switching.duplicate(true)
	return bundle


## The counts a tick would find, without spawning hundreds: the per-tick cache the
## preference reads (`_reproduction_population_count()`), on a tick of their own.
func _set_counts(world, deer: int, grouse: int) -> void:
	world.current_tick += 1
	world._reproduction_population_counts = {"herbivore": deer, "scavenger": grouse, "predator": 0}


func _test_preference_follows_the_share(a) -> void:
	var manager = Helpers.create_manager_with(_bundle(9601), 9601)
	var world = manager.world_state
	_set_counts(world, 240, 72)
	a.equal(world.prey_preference("herbivore"), 1.0, "deer as the map starts are hunted as ever")
	a.equal(world.prey_preference("scavenger"), 1.0, "and so are grouse at 23 % of the prey")
	_set_counts(world, 63, 126)
	a.near(world.prey_preference("herbivore"), (63.0 / 189.0) / 0.5, 0.0001, "a third of the prey: two thirds as readily")
	_set_counts(world, 10, 126)
	a.near(world.prey_preference("herbivore"), (10.0 / 136.0) / 0.5, 0.0001, "the last ten deer, a seventh")
	_set_counts(world, 1, 126)
	a.equal(world.prey_preference("herbivore"), 0.1, "never below the floor")
	_set_counts(world, 300, 12)
	a.near(world.prey_preference("scavenger"), (12.0 / 312.0) / 0.2, 0.0001, "grouse the same when they are the rare ones")
	a.equal(world.prey_preference("herbivore"), 1.0, "while the deer are hunted as ever")
	a.equal(world.prey_preference("predator"), 1.0, "a species with no share named is not judged")
	Helpers.destroy_manager(manager)
	manager = Helpers.create_manager_with(_bundle(9601, {"enabled": false}), 9601)
	world = manager.world_state
	_set_counts(world, 1, 126)
	a.equal(world.prey_preference("herbivore"), 1.0, "with the block off every prey is hunted as ever")
	Helpers.destroy_manager(manager)


## Among a flock of grouse the last deer is noticed only within the square root of its
## preference of the fox's sight; with the block off, anywhere in sight.
func _test_a_fox_notices_a_rare_deer_only_near(a) -> void:
	for switching in [true, false]:
		var manager = Helpers.create_manager_with(_bundle(9602, SWITCHING if switching else {"enabled": false}), 9602)
		var world = manager.world_state
		var fox = Helpers.spawn_predator(world, Vector2(20.0, 128.0))
		fox.hunger = 60.0
		var vision: float = world.perception_radius(fox, "vision_radius", 240.0)
		var notice := vision * sqrt(0.1)
		var far_deer = Helpers.spawn_herbivore(world, Vector2(20.0 + notice + 30.0, 128.0))
		_set_counts(world, 1, 126)
		if switching:
			a.is_true(notice + 30.0 < vision, "the deer is in sight, past what its rarity leaves of it")
			a.equal(fox._choose_prey(world), null, "a fox among grouse does not go for the last deer far off")
			var near_deer = Helpers.spawn_herbivore(world, Vector2(20.0 + notice - 40.0, 128.0))
			_set_counts(world, 2, 126)
			a.equal(fox._choose_prey(world), near_deer, "but takes one close by")
		else:
			a.equal(fox._choose_prey(world), far_deer, "with the block off it goes for it as ever")
		Helpers.destroy_manager(manager)


## A sleeping hunter among a few deer, when grouse are most of the prey, gains on a kill as
## much slower as the deer's preference, and its sector counts that much less catchable prey.
func _test_sleeping_hunters_catch_less_of_a_rare_prey(a) -> void:
	var debts := {}
	for switching in [true, false]:
		var manager = Helpers.create_manager_with(_bundle(9603, SWITCHING if switching else {"enabled": false}), 9603)
		manager.lod_enabled = true
		var world = manager.world_state
		var herd_position := Vector2(20.0, 220.0)
		for index in range(8):
			Helpers.spawn_herbivore(world, herd_position + Vector2(float(index) * 2.0, 0.0), 0)
		var fox = Helpers.spawn_predator(world, herd_position + Vector2(4.0, 4.0))
		fox.hunger = 60.0
		world.config_bundle["balance"]["dormant_ecology"]["kill_rate_per_prey_per_second"] = 0.05
		var slept: Array = SimulationTests._sleep_with_goal(world, herd_position, "predator", "hunt")
		var sector_state: Dictionary = slept[1]
		_set_counts(world, 8, 126)
		world._resolve_dormant_predation(slept[0], sector_state, sector_state.get("dormant_aggregates", []), 0.75)
		debts[switching] = float(sector_state.get("dormant_kill_debt", 0.0))
		var catchable: float = world._sector_catchable_prey({"species_counts": {"herbivore": 8, "scavenger": 126}})
		var grouse_catchability := float(world.config_bundle["balance"]["dormant_ecology"]["prey_catchability"]["scavenger"])
		var deer_weight: float = world.prey_preference("herbivore") if switching else 1.0
		a.near(catchable, 8.0 * deer_weight + 126.0 * grouse_catchability, 0.0001,
			"the sector's catchable prey counts the deer by their preference" if switching else "and by heads with the block off")
		Helpers.destroy_manager(manager)
	a.greater(debts[false], 0.0, "a hungry sleeping fox gains on a kill among deer")
	a.near(debts[true] / debts[false], (8.0 / 134.0) / 0.5, 0.0001, "as much slower as the deer's preference when they are rare")
