extends RefCounted

const Helpers := preload("res://scripts/tests/test_helpers.gd")
const Save := preload("res://scripts/core/save_system.gd")


func run(a) -> void:
	_test_escape_from_multiple_threats(a)
	_test_escape_cover_and_commitment(a)
	_test_last_seen_search_and_reacquisition(a)
	_test_search_expiry_and_telemetry(a)
	_test_search_save_and_lod(a)
	_test_energy_speed_transition(a)


func _add_solid(world, object_id: int, position: Vector2, radius: float = 12.0) -> void:
	world.scenery.add_object({"id": object_id, "position": position, "kind": "tree_large",
		"radius": radius, "cover_radius": 0.0, "opacity": 0.0,
		"move_cost": 1.0, "slot": 0, "scale": 1.0, "level": 0})


func _clear_scenery(world) -> void:
	world.scenery.objects.clear()
	world.scenery.buckets.clear()
	world.scenery._point_cache.clear()
	world.scenery._near_cache.clear()
	world.scenery.max_extent = 0.0


func _test_escape_from_multiple_threats(a) -> void:
	var manager = Helpers.create_manager(1201)
	var world = manager.world_state
	var prey = Helpers.spawn_herbivore(world, Vector2(128, 128))
	var first = Helpers.spawn_predator(world, Vector2(64, 104))
	var second = Helpers.spawn_predator(world, Vector2(64, 152))
	var third = Helpers.spawn_predator(world, Vector2(92, 80))
	var predators := [first, second, third]
	var before := _minimum_distance(prey.position, predators)
	prey.last_threat_position = prey._nearest_threat_position(predators)
	prey._flee(world, 0.05, predators, [])
	var target: Vector2 = prey.target_position
	a.greater(target.x, 128.0, "multiple threats on the left produce an escape target to the right")
	a.is_true(_minimum_distance(target, predators) + 0.01 >= before,
		"escape does not reduce distance to the nearest visible threat")
	a.is_true(world.bounds.grow(-prey.get_body_radius()).has_point(target),
		"escape keeps the whole body inside the map")
	a.is_true(world.scenery.segment_clear(target, target, prey.get_body_radius()),
		"escape target is not inside a solid")
	a.equal(prey.last_threat_position, third.position,
		"threat memory records the nearest visible predator")
	Helpers.destroy_manager(manager)


func _test_escape_cover_and_commitment(a) -> void:
	var manager = Helpers.create_manager(1202)
	var world = manager.world_state
	var prey = Helpers.spawn_herbivore(world, Vector2(96, 128))
	var predator = Helpers.spawn_predator(world, Vector2(32, 128))
	_add_solid(world, 12021, Vector2(144, 128), 13.0)
	var target: Vector2 = prey.get_escape_destination(world, Vector2.RIGHT, 96.0, [predator])
	a.is_true(not world.scenery.visible(predator.position, target,
		predator.position.distance_to(target) + 0.01),
		"a reachable occluded escape candidate is preferred over open ground")
	var target_tick: int = prey._escape_target_tick
	var local_searches: int = world.scenery.local_searches
	var same: Vector2 = prey.get_escape_destination(world, Vector2.RIGHT, 96.0, [predator])
	a.equal(same, target, "escape target persists during the commitment window")
	a.equal(prey._escape_target_tick, target_tick, "reusing an escape target does not refresh its clock")
	a.equal(world.scenery.local_searches, local_searches,
		"reusing an escape target performs no new local search")
	world.current_tick += 1
	prey.stuck_timer = 0.8
	prey.get_escape_destination(world, Vector2.RIGHT, 96.0, [predator])
	a.equal(prey._escape_target_tick, world.current_tick, "getting stuck immediately refreshes the escape target")
	world.current_tick += 1
	prey.stuck_timer = 0.0
	prey.get_escape_destination(world, Vector2.LEFT, 96.0, [predator])
	a.equal(prey._escape_target_tick, world.current_tick,
		"a material threat-heading change immediately refreshes the route")
	Helpers.destroy_manager(manager)


func _test_last_seen_search_and_reacquisition(a) -> void:
	var manager = Helpers.create_manager(1203)
	var world = manager.world_state
	var hunter = Helpers.spawn_predator(world, Vector2(48, 128))
	var prey = Helpers.spawn_herbivore(world, Vector2(128, 128))
	hunter.hunger = 50.0
	a.is_true(hunter._hunt(world, 0.01, prey), "visible prey starts the chase fixture")
	var remembered: Vector2 = hunter.last_seen_prey_position
	_add_solid(world, 12031, Vector2(104, 128), 11.0)
	prey.position = Vector2(184, 128)
	world.current_time = 0.5
	a.is_true(hunter._continue_or_finish_chase(world, 0.05),
		"occlusion enters last-seen search without ending the chase")
	a.equal(hunter.state, "search_last_seen", "search is an internal engaged execution phase")
	a.equal(hunter.search_anchor, remembered, "search anchors at the last confirmed position")
	a.equal(hunter.target_position, remembered, "hunter first travels to the last confirmed position")
	a.equal(hunter.last_seen_prey_position, remembered,
		"hidden prey movement cannot update the remembered position")

	hunter.position = remembered
	hunter.velocity = Vector2.ZERO
	_clear_scenery(world)
	_add_solid(world, 12032, Vector2(156, 128), 9.0)
	world.current_time = 0.7
	hunter._continue_or_finish_chase(world, 0.05)
	a.is_true(not hunter._search_waypoint_reachable(world, Vector2(156, 128)),
		"a search point inside a solid is rejected without extending the search")
	a.is_true(hunter.search_waypoint_index >= 0 and hunter.search_waypoint_index <= 3,
		"arrival advances to one of at most four reachable search points")
	var first_waypoint: Vector2 = hunter.target_position
	a.equal(first_waypoint, hunter._search_waypoint(world, hunter.search_waypoint_index),
		"the search point is deterministic for hunter ID and anchor")
	a.is_true(first_waypoint != prey.position, "search route does not use the hidden prey position")

	_clear_scenery(world)
	prey.position = hunter.position + Vector2(60, 0)
	world.current_time = 0.9
	hunter._continue_or_finish_chase(world, 0.05)
	a.equal(hunter.state, "chase", "seeing prey again immediately resumes the chase")
	a.near(hunter.search_started_time, -1.0, 0.001, "reacquisition clears the search phase")
	a.equal(hunter.last_seen_prey_position, prey.position,
		"reacquisition records the newly confirmed position")
	a.equal(int(manager.stats_system.counters.prey_reacquired), 1,
		"reacquisition is counted separately from attacks")
	Helpers.destroy_manager(manager)


func _test_search_expiry_and_telemetry(a) -> void:
	var manager = Helpers.create_manager(1204)
	var world = manager.world_state
	var hunter = Helpers.spawn_predator(world, Vector2(48, 128))
	var prey = Helpers.spawn_herbivore(world, Vector2(128, 128))
	hunter.hunger = 50.0
	hunter._hunt(world, 0.01, prey)
	_add_solid(world, 12041, Vector2(104, 128), 11.0)
	prey.position = Vector2(184, 128)
	world.current_time = 0.5
	hunter._continue_or_finish_chase(world, 0.1)
	a.equal(int(manager.stats_system.counters.search_started), 1,
		"loss of sight records one search start")
	world.current_time = 4.0
	a.is_true(not hunter._continue_or_finish_chase(world, 0.1),
		"search expires after the configured lost-sight window")
	a.equal(hunter.target_agent_id, -1, "expired search releases its prey target")
	a.equal(int(manager.stats_system.counters.search_expired), 1,
		"expired searches have a dedicated counter")
	a.equal(int(manager.stats_system.counters.hunt_fail_lost_sight), 1,
		"search expiry remains a lost-sight chase failure")
	a.equal(int(manager.stats_system.counters.completed_chase_count), 1,
		"a terminal chase contributes one duration sample")
	manager.stats_system.refresh_snapshot(world, world.current_tick, world.current_time)
	a.greater(float(manager.stats_system.latest_snapshot.average_completed_chase_seconds), 0.0,
		"completed chase duration is exposed in telemetry")
	Helpers.destroy_manager(manager)


func _test_search_save_and_lod(a) -> void:
	var manager = Helpers.create_manager(1205)
	var world = manager.world_state
	var hunter = Helpers.spawn_predator(world, Vector2(64, 64))
	hunter.state = "search_last_seen"
	hunter.target_agent_id = 77
	hunter.search_anchor = Vector2(120, 96)
	hunter.search_started_time = 4.25
	hunter.search_waypoint_index = 2
	hunter.search_last_confirmed_position = Vector2(116, 94)
	var saved: Dictionary = hunter.export_save_state()
	hunter._reset_search_state()
	hunter.apply_save_state(saved)
	a.equal(hunter.search_anchor, Vector2(120, 96), "search anchor round-trips in a v2 record")
	a.near(hunter.search_started_time, 4.25, 0.001, "search start time round-trips")
	a.equal(hunter.search_waypoint_index, 2, "search waypoint progress round-trips")
	a.equal(hunter.search_last_confirmed_position, Vector2(116, 94),
		"last confirmed prey position round-trips")
	a.is_true(world._is_priority_lod_agent(hunter), "last-seen search remains in LOD0")
	var save_path := "/private/tmp/animals-p2-search-save.dat"
	a.is_true(Save.save(manager, {}, save_path), "an active search writes through the v2 save system")
	var restored_manager = Helpers.create_manager(1205)
	a.is_true(Save.restore(restored_manager, Save.read(save_path)), "an active search restores through the v2 save system")
	var restored = restored_manager.world_state.get_agent(hunter.id)
	a.is_true(restored != null, "the searching predator exists after full restore")
	if restored != null:
		a.equal(restored.state, "search_last_seen", "full restore keeps the internal search phase")
		a.equal(restored.search_anchor, Vector2(120, 96), "full restore keeps the search anchor")
		a.equal(restored.search_waypoint_index, 2, "full restore keeps search progress")
	DirAccess.remove_absolute(save_path)
	Helpers.destroy_manager(restored_manager)
	hunter.apply_runtime_state({"position": Vector2(64, 64)})
	a.near(hunter.search_started_time, -1.0, 0.001,
		"older v2 records without search fields load outside search")
	a.equal(hunter.search_waypoint_index, -1, "older v2 records receive safe search defaults")
	Helpers.destroy_manager(manager)


func _test_energy_speed_transition(a) -> void:
	var manager = Helpers.create_manager(1206)
	var world = manager.world_state
	var animal = Helpers.spawn_herbivore(world, Vector2(64, 64))
	animal.movement = animal.movement.duplicate(true)
	animal.movement["acceleration"] = 20.0
	animal.movement["drag"] = 0.0
	animal.movement["max_turn_rate_degrees"] = 0.0
	animal.movement["body_radius"] = 4.0
	animal.energy = float(animal.metabolism.max_energy)
	for _step in 60:
		animal.move_with_vector(world, Vector2.RIGHT, 100.0, 0.05)
	var full_speed: float = animal.velocity.length()
	animal.energy = 0.0
	animal.move_with_vector(world, Vector2.RIGHT, 100.0, 0.05)
	a.is_true(full_speed - animal.velocity.length() <= 1.01,
		"energy loss decelerates by acceleration instead of snapping to exhausted speed")
	for _step in 60:
		animal.move_with_vector(world, Vector2.LEFT, 100.0, 0.05)
	var exhausted_speed: float = animal.velocity.length()
	a.is_true(exhausted_speed <= 55.1,
		"sustained exhaustion reaches the configured reduced target speed")
	animal.energy = float(animal.metabolism.max_energy)
	var before_recovery: float = animal.velocity.length()
	animal.move_with_vector(world, Vector2.LEFT, 100.0, 0.05)
	a.is_true(animal.velocity.length() - before_recovery <= 1.01,
		"energy recovery accelerates smoothly without a speed jump")
	Helpers.destroy_manager(manager)


func _minimum_distance(point: Vector2, agents: Array) -> float:
	var result := INF
	for agent in agents:
		result = minf(result, point.distance_to(agent.position))
	return result
