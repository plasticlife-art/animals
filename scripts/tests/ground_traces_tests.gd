extends RefCounted

## The marks animals leave on the ground, and the layer that shows them.

const Helpers := preload("res://scripts/tests/test_helpers.gd")
const TrailFieldScript := preload("res://scripts/world/trail_field.gd")
const SimulationWorkerScript := preload("res://scripts/core/simulation_worker.gd")
const GroundTracesScript := preload("res://scripts/ui/ground_traces.gd")

const HERD_CENTER := Vector2(768.0, 768.0)
const STEP_SECONDS := 0.75


func run(a) -> void:
	_test_wear_lands_in_the_cell_walked_through(a)
	_test_wear_fades_by_half_each_half_life(a)
	_test_a_walking_animal_wears_the_ground(a)
	_test_a_sleeping_herd_wears_the_ground(a)
	_test_trails_change_nothing_the_animals_do(a)
	_test_trails_survive_a_save(a)
	_test_caps_are_empty_where_nothing_can_walk(a)
	_test_worker_ships_the_ground_on_its_interval(a)
	_test_layer_covers_walkable_ground_only(a)
	_test_layer_is_off_when_switched_off(a)


func _field(half_life: float = 10.0) -> TrailField:
	var field: TrailField = TrailFieldScript.new()
	field.initialize({"trails": {"cell_size_in_grass_cells": 0.5, "half_life_seconds": half_life,
		"decay_stride_ticks": 4, "min_speed": 30.0}}, Vector2(256.0, 256.0), 32.0)
	return field


func _total(field: TrailField) -> float:
	var total := 0.0
	for value in field.export_cells():
		total += value
	return total


func _test_wear_lands_in_the_cell_walked_through(a) -> void:
	var field := _field()
	a.equal(field.cell_size, 16.0, "trail cells are sized in grass cells")
	field.deposit(Vector2(40.0, 20.0), 12.0, 0.2)
	field.deposit(Vector2(44.0, 28.0), 3.0, 0.05)
	field.deposit(Vector2(44.0, 28.0), 3.0, 0.5)
	a.near(field.wear_at(Vector2(33.0, 17.0)), 15.0, 0.0001, "steps in one cell add up, and milling about adds nothing")
	a.near(field.wear_at(Vector2(60.0, 20.0)), 0.0, 0.0001, "and stay out of the next one")
	field.deposit(Vector2(-5.0, 20.0), 9.0, 0.1)
	field.deposit(Vector2(20.0, 4000.0), 9.0, 0.1)
	a.near(_total(field), 15.0, 0.0001, "a step off the map marks nothing")
	var off := _field()
	off.enabled = false
	off.deposit(Vector2(40.0, 20.0), 12.0, 0.2)
	a.near(_total(off), 0.0, 0.0001, "a switched-off field stays blank")


func _test_wear_fades_by_half_each_half_life(a) -> void:
	var field := _field(10.0)
	field.deposit(Vector2(40.0, 20.0), 800.0, 1.0)
	var delta := 1.0 / 12.0
	for tick in range(120):
		field.step(delta, tick)
	a.near(field.wear_at(Vector2(40.0, 20.0)), 400.0, 1.0, "wear halves over one half-life")
	for tick in range(120, 120 * 12):
		field.step(delta, tick)
	a.near(field.wear_at(Vector2(40.0, 20.0)), 0.0, 0.0001, "and an unused path heals completely")


func _test_a_walking_animal_wears_the_ground(a) -> void:
	var manager = Helpers.create_manager_with(Helpers.build_large_sector_bundle(501), 501)
	var world = manager.world_state
	Helpers.spawn_herd(world, HERD_CENTER, 6, 0)
	Helpers.run_ticks(manager, 120)
	a.greater(_total(world.trail_field), 0.0, "animals that walk leave wear behind")
	var near_herd := 0.0
	var field: TrailField = world.trail_field
	var cells: PackedFloat32Array = field.export_cells()
	for index in range(cells.size()):
		@warning_ignore("integer_division")
		var center: Vector2 = (Vector2(index % field.cols, index / field.cols) + Vector2(0.5, 0.5)) * field.cell_size
		if center.distance_to(HERD_CENTER) < 600.0:
			near_herd += cells[index]
	a.near(near_herd, _total(world.trail_field), 0.001, "and only where they walked")
	Helpers.destroy_manager(manager)


func _test_a_sleeping_herd_wears_the_ground(a) -> void:
	var manager = Helpers.create_manager_with(Helpers.build_large_sector_bundle(502), 502)
	var world = manager.world_state
	Helpers.spawn_herd(world, HERD_CENTER, 12, 0)
	var sector_key: Vector2i = world._get_sector_key(HERD_CENTER)
	world._sleep_sector(sector_key)
	var blank := PackedFloat32Array()
	blank.resize(world.trail_field.get_cell_count())
	world.trail_field.import_cells(blank)
	var before: Array = Helpers.positions_of(world._sector_states[sector_key]["dormant_records"])
	for step in range(20):
		world.current_tick += int(round(STEP_SECONDS * 12.0))
		world.current_time += STEP_SECONDS
		world._prepare_navigation_budget()
		world._apply_dormant_sector_step(sector_key, world._sector_states[sector_key], STEP_SECONDS)
	var after: Array = Helpers.positions_of(world._sector_states[sector_key]["dormant_records"])
	var net := 0.0
	for index in range(mini(before.size(), after.size())):
		net += (after[index] as Vector2).distance_to(before[index])
	a.greater(net, 0.0, "the sleeping herd moved")
	a.is_true(_total(world.trail_field) >= net - 0.01,
		"sleeping animals wear the ground by at least as far as they got (%.1f of %.1f)" % [_total(world.trail_field), net])
	Helpers.destroy_manager(manager)


## The field is for the player. If a herd ever read it, this is the test that says so.
func _test_trails_change_nothing_the_animals_do(a) -> void:
	var with_trails = Helpers.create_manager_with(Helpers.build_large_sector_bundle(503), 503)
	var bundle: Dictionary = Helpers.build_large_sector_bundle(503)
	bundle["world"]["trails"] = {"enabled": false}
	var without = Helpers.create_manager_with(bundle, 503)
	Helpers.spawn_herd(with_trails.world_state, HERD_CENTER, 8, 0)
	Helpers.spawn_herd(without.world_state, HERD_CENTER, 8, 0)
	Helpers.run_ticks(with_trails, 90)
	Helpers.run_ticks(without, 90)
	a.greater(_total(with_trails.world_state.trail_field), 0.0, "one world has trails")
	a.near(_total(without.world_state.trail_field), 0.0, 0.0001, "the other has none")
	a.equal(Helpers.world_fingerprint(with_trails), Helpers.world_fingerprint(without),
		"and the animals did exactly the same in both")
	Helpers.destroy_manager(with_trails)
	Helpers.destroy_manager(without)


func _test_trails_survive_a_save(a) -> void:
	var original = Helpers.create_manager(504)
	original.world_state.trail_field.deposit(Vector2(100.0, 60.0), 250.0, 1.0)
	var saved: Dictionary = original.world_state.export_state()
	var restored = Helpers.create_manager(504)
	restored.world_state.import_state(saved)
	a.equal(restored.world_state.trail_field.export_cells(), original.world_state.trail_field.export_cells(),
		"a loaded world keeps its worn paths")
	Helpers.destroy_manager(original)
	Helpers.destroy_manager(restored)


func _obstacle_bundle(seed: int) -> Dictionary:
	var bundle: Dictionary = Helpers.build_large_sector_bundle(seed)
	bundle["world"]["terrain"]["obstacles"] = {"dense_forest_cluster_count": 3, "dense_forest_radius_min_cells": 1.0,
		"dense_forest_radius_max_cells": 2.0, "cliff_count": 2, "cliff_thickness_min_cells": 1.1,
		"cliff_thickness_max_cells": 2.0, "cliff_gap_radius_cells": 1.6, "border_clearance_cells": 1}
	return bundle


func _test_caps_are_empty_where_nothing_can_walk(a) -> void:
	var manager = Helpers.create_manager_with(_obstacle_bundle(505), 505)
	var world = manager.world_state
	var caps: PackedFloat32Array = world.resource_system.export_caps()
	a.equal(caps.size(), world.resource_system.get_cell_count(), "one cap per grass cell")
	var blocked := 0
	var wrong := 0
	for index in range(caps.size()):
		var walkable: bool = world.terrain_system.is_walkable_index(index)
		if not walkable:
			blocked += 1
		if (caps[index] > 0.0) != walkable:
			wrong += 1
	a.greater(blocked, 0, "the fixture has ground nothing can walk on")
	a.equal(wrong, 0, "caps are positive exactly where animals can graze")
	Helpers.destroy_manager(manager)


func _test_worker_ships_the_ground_on_its_interval(a) -> void:
	var manager = Helpers.create_manager(506)
	var worker = SimulationWorkerScript.new()
	worker.configure(manager.world_state, manager.stats_system, manager.event_bus, manager.rng)
	var delta := 1.0 / 12.0
	var shipped: Array = []
	for tick in range(12):
		var result: Dictionary = worker.step(delta, tick, float(tick) * delta, {}, -1, false, false, 6)
		if result.has("ground"):
			shipped.append(tick + 1)
			a.equal(result.ground.grass.size(), manager.world_state.resource_system.get_cell_count(), "the whole grass grid")
			a.equal(result.ground.trails.size(), manager.world_state.trail_field.get_cell_count(), "and the whole trail grid")
	a.equal(shipped, [6, 12], "the ground is shipped on the ticks the layer redraws")
	var silent: Dictionary = worker.step(delta, 12, 1.0, {}, -1, false, false, 0)
	a.is_true(not silent.has("ground"), "and never while the layer is off")
	Helpers.destroy_manager(manager)


func _test_layer_covers_walkable_ground_only(a) -> void:
	var manager = Helpers.create_manager_with(_obstacle_bundle(507), 507)
	var world = manager.world_state
	var walkable := 0
	for index in range(world.terrain_system.get_cell_count()):
		if world.terrain_system.is_walkable_index(index):
			walkable += 1
	WorldProjection.configure({"projection": "orthogonal"})
	var layer = GroundTracesScript.new()
	layer.bind_manager(manager)
	a.is_true(layer.visible and layer._mesh_instance != null, "the layer is on by default")
	var arrays: Array = layer._mesh_instance.mesh.surface_get_arrays(0)
	a.equal(arrays[Mesh.ARRAY_VERTEX].size(), walkable * 4, "one quad per walkable cell")
	a.equal(arrays[Mesh.ARRAY_VERTEX], arrays[Mesh.ARRAY_TEX_UV], "top-down, a quad sits where its ground is")
	a.equal(layer._grass_texture.get_size(), Vector2(world.resource_system.cols, world.resource_system.rows),
		"grass reaches the GPU one texel per cell")
	a.equal(layer._trail_texture.get_size(), Vector2(world.trail_field.cols, world.trail_field.rows),
		"and so do trails")
	WorldProjection.configure({"projection": "isometric", "level_height_px": 16}, world.terrain_system.get_max_height_level())
	layer.rebuild()
	var iso: Array = layer._mesh_instance.mesh.surface_get_arrays(0)
	var lifted := true
	for vertex_index in range(0, iso[Mesh.ARRAY_VERTEX].size(), 4):
		var corner: Vector2 = iso[Mesh.ARRAY_TEX_UV][vertex_index]
		var level: int = world.terrain_system.get_height_at_position(corner + Vector2.ONE)
		if not (iso[Mesh.ARRAY_VERTEX][vertex_index] as Vector2).is_equal_approx(WorldProjection.to_screen(corner, level)):
			lifted = false
			break
	a.is_true(lifted, "in the isometric view each quad rides at its ground's height")
	WorldProjection.configure({"projection": "orthogonal"})
	layer.free()
	Helpers.destroy_manager(manager)


func _test_layer_is_off_when_switched_off(a) -> void:
	var bundle: Dictionary = Helpers.build_test_bundle(508)
	bundle["visuals"]["ground"] = {"enabled": false}
	var manager = Helpers.create_manager_with(bundle, 508)
	a.equal(manager.ground_update_interval_ticks(), 0, "a switched-off layer asks the worker for nothing")
	var layer = GroundTracesScript.new()
	layer.bind_manager(manager)
	a.is_true(not layer.visible and layer._mesh_instance == null, "and draws nothing")
	layer.free()
	Helpers.destroy_manager(manager)
