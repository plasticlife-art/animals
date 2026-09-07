extends RefCounted
const Helpers = preload("res://scripts/tests/test_helpers.gd")
const Save = preload("res://scripts/core/save_system.gd")

func run(a) -> void:
	_test_geometry(a)
	_test_perception(a)
	_test_memory_and_contact(a)
	_test_save_and_budget(a)
	_test_deterministic_scenery(a)
	_test_interpolation_and_sort(a)

func solid(world, position: Vector2, radius: float = 12.0) -> void:
	world.scenery.add_object({"id": 1001, "position": position, "radius": radius, "cover_radius": 0.0})

func _test_geometry(a) -> void:
	var m = Helpers.create_manager()
	var world = m.world_state
	solid(world, Vector2(112, 128))
	a.is_true(not world.scenery.segment_clear(Vector2(64, 128), Vector2(160, 128), 6), "a complete sweep detects a trunk between free endpoints")
	var stopped: Vector2 = world.resolve_movement_position(Vector2(64, 128), Vector2(160, 128), 6)
	a.is_true(stopped.x <= 94.1, "sprinting cannot tunnel through a trunk")
	a.is_true(world.scenery.segment_clear(stopped, stopped, 6), "contact leaves the body outside the trunk")
	a.is_true(world.scenery.segment_clear(Vector2(64, 96), Vector2(160, 96), 6), "can walk beside the trunk beneath the canopy")
	a.is_true(not world.scenery.segment_clear(Vector2(2, 128), Vector2(4, 128), 6), "world boundary includes body radius")
	var path: PackedVector2Array = world.scenery.local_path(Vector2(64, 128), Vector2(160, 128), 6)
	a.is_true(path.size() > 2, "local path bends around the trunk")
	for i in range(1, path.size()):
		a.is_true(world.scenery.segment_clear(path[i - 1], path[i], 6), "each local path segment clears the whole body")
	var restored: Vector2 = world.scenery.nearest_free(Vector2(112, 128), 6)
	a.is_true(world.scenery.segment_clear(restored, restored, 6), "restore/spawn resolves an overlapping body")
	# A narrow gap admits the small body but not the large one.
	solid(world, Vector2(192, 106), 12)
	solid(world, Vector2(192, 150), 12)
	a.is_true(world.scenery.segment_clear(Vector2(170, 128), Vector2(214, 128), 6), "small body fits a gap")
	a.is_true(not world.scenery.segment_clear(Vector2(170, 128), Vector2(214, 128), 14), "large body cannot fit the same gap")
	Helpers.destroy_manager(m)

func _test_perception(a) -> void:
	var m = Helpers.create_manager()
	var s = m.world_state.scenery
	s.add_object({"id": 1, "position": Vector2(128, 128), "radius": 0.0, "cover_radius": 25.0, "opacity": 0.6, "move_cost": 1.4})
	a.is_true(s.segment_clear(Vector2(64, 128), Vector2(180, 128), 6), "bush remains physically passable")
	a.near(s.movement_cost(Vector2(128, 128)), 1.4, 0.001, "bush slows motion")
	a.is_true(not s.visible(Vector2(64, 128), Vector2(180, 128), 140), "bush hides distant prey")
	a.is_true(s.visible(Vector2(125, 128), Vector2(135, 128), 140), "bush does not grant immunity at contact")
	Helpers.destroy_manager(m)

func _test_memory_and_contact(a) -> void:
	var m = Helpers.create_manager()
	var world = m.world_state
	var prey = Helpers.spawn_herbivore(world, Vector2(140, 128))
	var hunter = Helpers.spawn_predator(world, Vector2(70, 128))
	hunter.hunger = 50.0
	a.is_true(hunter._hunt(world, 0.01, prey), "visible prey starts a hunt")
	var last_seen: Vector2 = hunter.last_seen_prey_position
	solid(world, Vector2(110, 128), 10)
	prey.position = Vector2(180, 128)
	world.current_time = 0.5
	hunter._continue_or_finish_chase(world, 0.01)
	a.equal(hunter.last_seen_prey_position, last_seen, "occluded prey does not update the remembered position")
	a.equal(hunter.target_position, last_seen, "hunter navigates toward its memory")
	world.current_time = 5.0
	a.is_true(not hunter._continue_or_finish_chase(world, 0.01), "lost sight eventually ends pursuit")
	a.equal(hunter.target_agent_id, -1, "lost pursuit releases the target")
	hunter.position = Vector2(100, 128)
	prey.position = Vector2(120, 128)
	a.is_true(not hunter._attack(world, prey, 0.01), "no attacks through a trunk even in attack range")
	a.is_true(prey.is_alive, "blocked contact cannot kill prey")
	# Remembered danger interrupts grazing even when the source has gone.
	prey.position = Vector2(160, 180)
	prey.threat_memory_until = 7.0
	prey.last_threat_position = Vector2(120, 180)
	prey.interaction_timer = 1.0
	prey.tick(world, 0.05)
	a.equal(prey.state, "flee", "recent danger continues to drive escape")
	a.near(prey.interaction_timer, 0.0, 0.001, "danger interrupts feeding")
	var energy: float = prey.energy
	prey._flee(world, 0.1, [], [])
	a.is_true(prey.energy <= energy, "escape spends energy")
	world.kill_agent(hunter, "test")
	world._flush_removals()
	world.current_time = 10.0
	prey.tick(world, 0.05)
	a.equal(prey.ai_state, &"alive", "panic ends after the safe memory interval")
	Helpers.destroy_manager(m)

func _test_save_and_budget(a) -> void:
	var m = Helpers.create_manager()
	var world = m.world_state
	var prey = Helpers.spawn_herbivore(world, Vector2(64, 128))
	prey.threat_memory_until = 12.0
	prey.last_threat_position = Vector2(32, 128)
	var saved: Dictionary = prey.export_save_state()
	prey.threat_memory_until = -1.0
	prey.apply_save_state(saved)
	a.near(prey.threat_memory_until, 12.0, 0.001, "threat memory round-trips")
	prey.apply_runtime_state({})
	a.near(prey.threat_memory_until, -1.0, 0.001, "legacy records start without phantom threats")
	solid(world, Vector2(112, 128))
	world._local_path_budget = 0
	var point: Vector2 = world.local_waypoint(prey, Vector2(160, 128))
	a.equal(point, prey.position, "exhausted path budget waits instead of walking through an obstacle")
	world._prepare_navigation_budget()
	point = world.local_waypoint(prey, Vector2(160, 128))
	a.is_true(point != prey.position, "agent receives a route after budget replenishment")
	var early: Vector2 = prey.get_escape_destination(world, Vector2.RIGHT, 40)
	var count: int = world.scenery.local_searches
	var again: Vector2 = prey.get_escape_destination(world, Vector2.RIGHT, 40)
	a.equal(early, again, "escape destination is stable within the commitment window")
	a.equal(world.scenery.local_searches, count, "reusing escape goal performs no extra local search")
	var path := "/private/tmp/animals-v2-test.dat"
	a.is_true(Save.save(m, {}, path), "v2 save writes fixture config")
	var data: Dictionary = Save.read(path)
	data.version = 1
	data.erase("config_bundle")
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_var(data, true)
	file.close()
	# A v1 file has to be refused, not read. Its sector states predate
	# `species_counts`, so loading one leaves every sector reporting no animals to
	# the prey-pressure census and to `threat_score` - a world that looks fine and
	# in which predators never find a herd again.
	a.is_true(Save.read(path).is_empty(), "a pre-census save is refused rather than half-loaded")
	a.is_true(not Save.slot_paths().has(path) or Save.latest_slot() != path,
		"a refused save is not offered as something to continue")
	DirAccess.remove_absolute(path)
	Helpers.destroy_manager(m)

func _test_deterministic_scenery(a) -> void:
	var m = Helpers.create_manager()
	var config := {"scenery": {"enabled": true, "placement": {"meadow": {"chance": 1.0, "groups": ["tree_large"]}}, "types": {"tree_large": {"radius_cells": 0.1}}}}
	var before: int = m.rng.state
	var first = preload("res://scripts/world/scenery_system.gd").new()
	var second = preload("res://scripts/world/scenery_system.gd").new()
	first.initialize(config, {}, m.world_state.terrain_system, 42)
	second.initialize(config, {}, m.world_state.terrain_system, 42)
	a.equal(first.objects, second.objects, "scenery placement repeats for the same seed")
	a.equal(before, m.rng.state, "scenery does not consume ecology RNG")
	Helpers.destroy_manager(m)

func _test_interpolation_and_sort(a) -> void:
	var m = Helpers.create_manager()
	var animal = Helpers.spawn_herbivore(m.world_state, Vector2(80, 80))
	var renderer = preload("res://scripts/ui/agent_renderer.gd").new()
	renderer.simulation_manager = m
	renderer._history[animal.id] = PackedVector2Array([Vector2(64, 64), Vector2(80, 80), Vector2(80, 80), Vector2(96, 64)])
	for t in 11:
		renderer._render_positions.clear()
		var point: Vector2 = renderer._curve_position(animal, t / 10.0)
		a.is_true(m.world_state.scenery.segment_clear(Vector2(80, 80), point, animal.get_body_radius()), "render interpolation stays collision-safe")
	var batch = preload("res://scripts/ui/scene_sprite_batch.gd")
	a.is_true(batch.depth_less({"depth": 20.0, "id": 1}, {"depth": 30.0, "id": -1}), "animal behind tree sorts before its base")
	a.is_true(batch.depth_less({"depth": 30.0, "id": -1}, {"depth": 40.0, "id": 2}), "animal in front sorts after tree")
	renderer.free()
	Helpers.destroy_manager(m)
