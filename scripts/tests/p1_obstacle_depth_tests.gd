extends RefCounted

const Helpers := preload("res://scripts/tests/test_helpers.gd")
const ScenerySystemScript := preload("res://scripts/world/scenery_system.gd")
const SceneSpriteBatchScript := preload("res://scripts/ui/scene_sprite_batch.gd")


func run(a) -> void:
	_test_authoritative_scenery_records(a)
	_test_swept_inertia_and_sliding(a)
	_test_bush_motion_cost(a)
	_test_local_refinement_edges(a)
	_test_overlap_correction_respects_solids(a)
	_test_a_body_touching_a_solid_can_leave_it(a)
	_test_common_depth_ties(a)


func _add_solid(world, object_id: int, position: Vector2, radius: float = 12.0,
		kind: String = "tree_large") -> void:
	world.scenery.add_object({"id": object_id, "position": position, "kind": kind,
		"radius": radius, "cover_radius": 0.0, "opacity": 0.0,
		"move_cost": 1.0, "slot": 0, "scale": 1.0, "level": 0})


func _test_authoritative_scenery_records(a) -> void:
	var manager = Helpers.create_manager(901)
	var world = manager.world_state
	var config := {"scenery": {
		"enabled": true,
		"placement": {"meadow": {"chance": 1.0, "groups": ["tree_large"]}},
		"types": {"tree_large": {"radius_cells": 0.13}},
	}}
	var first = ScenerySystemScript.new()
	var second = ScenerySystemScript.new()
	first.initialize(config, manager.config_bundle.visuals, world.terrain_system, 901)
	second.initialize(config, manager.config_bundle.visuals, world.terrain_system, 901)
	a.equal(first.objects, second.objects,
		"world scenery IDs, positions and render metadata are stable for a seed")
	var ids := {}
	var schema_ok := true
	var indexed_at_same_position := true
	for entry in first.objects:
		ids[int(entry.id)] = true
		for key in ["id", "position", "kind", "radius", "cover_radius", "opacity",
				"move_cost", "slot", "scale", "level"]:
			schema_ok = schema_ok and entry.has(key)
		var found := first.query_rect(Rect2(entry.position, Vector2.ZERO).grow(0.01))
		indexed_at_same_position = indexed_at_same_position and found.has(entry)
	a.equal(ids.size(), first.objects.size(), "generated scenery IDs are unique")
	a.is_true(schema_ok, "one scenery record contains physics, cover and render fields")
	a.is_true(indexed_at_same_position,
		"the spatial index returns the authoritative render and physics records")
	if not first.objects.is_empty():
		var entry: Dictionary = first.objects[0]
		a.greater(float(entry.radius), 0.0, "tree collision uses the configured trunk radius")
	Helpers.destroy_manager(manager)


func _test_swept_inertia_and_sliding(a) -> void:
	var manager = Helpers.create_manager(902)
	var world = manager.world_state
	_add_solid(world, 2001, Vector2(112, 128))
	var animal = Helpers.spawn_herbivore(world, Vector2(64, 128))
	animal.movement = animal.movement.duplicate(true)
	animal.movement["body_radius"] = 6.0
	animal.velocity = Vector2(200, 0)
	var before: Vector2 = animal.position
	animal.advance_inertia(world, 0.5)
	a.is_true(world.scenery.segment_clear(before, animal.position, animal.get_body_radius()),
		"an inertial step sweeps the whole body instead of tunnelling")
	a.near(animal.velocity.x, (animal.position.x - before.x) / 0.5, 0.001,
		"inertial velocity is corrected to the actual collision-limited speed")
	a.is_true(animal.position.x <= 94.1, "inertia stops outside the trunk radius")

	var slide_start := Vector2(64, 96)
	var slide_target := Vector2(160, 144)
	var slid: Vector2 = world.scenery.resolve_motion(slide_start, slide_target, 6.0)
	a.is_true(world.scenery.segment_clear(slide_start, slid, 6.0),
		"the selected sliding segment remains body-clear")
	a.greater(slid.distance_to(slide_start), 30.0,
		"an angled collision preserves useful tangential movement")
	a.is_true(slid != slide_target, "the slide does not cross the obstacle corner")

	_add_solid(world, 2002, Vector2(112, 104))
	_add_solid(world, 2003, Vector2(112, 152))
	var blocked: Vector2 = world.scenery.resolve_motion(Vector2(64, 128), Vector2(176, 128), 8.0)
	a.is_true(blocked.x < 112.0, "a body cannot squeeze through a closed obstacle pair")
	a.is_true(world.scenery.segment_clear(Vector2(64, 128), blocked, 8.0),
		"corner resolution never returns an intersecting endpoint")
	Helpers.destroy_manager(manager)


func _test_bush_motion_cost(a) -> void:
	var manager = Helpers.create_manager(903)
	var world = manager.world_state
	world.scenery.add_object({"id": 3001, "position": Vector2(96, 96), "kind": "bush",
		"radius": 0.0, "cover_radius": 28.0, "opacity": 0.55,
		"move_cost": 1.4, "slot": 7, "scale": 0.6, "level": 0})
	var animal = Helpers.spawn_herbivore(world, Vector2(96, 96))
	animal.movement = animal.movement.duplicate(true)
	animal.movement["body_radius"] = 6.0
	animal.movement["acceleration"] = 10000.0
	animal.movement["drag"] = 0.0
	animal.movement["max_turn_rate_degrees"] = 0.0
	animal.move_with_vector(world, Vector2.RIGHT, 100.0, 0.1)
	a.near(animal.position.x - 96.0, 100.0 / 1.4 * 0.1, 0.05,
		"a passable bush reduces actual travel speed by its configured cost")
	a.is_true(world.scenery.visible(Vector2(86, 96), Vector2(106, 96), 100.0),
		"nearby animals remain visible inside a bush")
	a.is_true(not world.scenery.visible(Vector2(40, 96), Vector2(152, 96), 140.0),
		"the same bush attenuates distant line of sight")
	Helpers.destroy_manager(manager)


func _test_local_refinement_edges(a) -> void:
	var manager = Helpers.create_manager(904)
	var world = manager.world_state
	_add_solid(world, 4001, Vector2(160, 128), 12.0)
	var adjusted: PackedVector2Array = world.scenery.local_path(
		Vector2(64, 128), Vector2(160, 128), 6.0)
	a.greater(float(adjusted.size()), 1.0,
		"a solid coarse waypoint is refined to a nearby reachable point")
	if not adjusted.is_empty():
		a.is_true(adjusted[-1] != Vector2(160, 128),
			"local refinement does not end inside the blocking object")
		for index in range(1, adjusted.size()):
			a.is_true(world.scenery.segment_clear(adjusted[index - 1], adjusted[index], 6.0),
				"refined route segments remain clear around a blocked endpoint")

	var edge_path: PackedVector2Array = world.scenery.local_path(
		Vector2(8, 24), Vector2(8, 220), 6.0)
	a.greater(float(edge_path.size()), 1.0, "local routing works beside the map boundary")
	for point in edge_path:
		a.is_true(point.x >= 6.0 and point.y >= 6.0 and point.x <= 250.0 and point.y <= 250.0,
			"a boundary route keeps the complete body inside the world")

	for index in 8:
		_add_solid(world, 4100 + index,
			Vector2(192, 192) + Vector2.from_angle(TAU * float(index) / 8.0) * 23.0, 10.0)
	var unreachable: PackedVector2Array = world.scenery.local_path(
		Vector2(120, 192), Vector2(192, 192), 6.0)
	a.is_true(unreachable.is_empty() or unreachable[-1] != Vector2(192, 192),
		"an enclosed target is never reported as directly reachable")
	Helpers.destroy_manager(manager)


func _test_overlap_correction_respects_solids(a) -> void:
	var manager = Helpers.create_manager(905)
	var world = manager.world_state
	_add_solid(world, 5001, Vector2(112, 128), 12.0)
	var first = Helpers.spawn_herbivore(world, Vector2(88, 128), 0)
	var second = Helpers.spawn_herbivore(world, Vector2(92, 128), 0)
	for animal in [first, second]:
		animal.movement = animal.movement.duplicate(true)
		animal.movement["body_radius"] = 6.0
	world.spatial_grid.rebuild(world.get_living_agents())
	world._resolve_agent_overlap(0.5)
	a.is_true(world.scenery.segment_clear(first.position, first.position, 6.0),
		"overlap separation keeps the first animal outside the trunk")
	a.is_true(world.scenery.segment_clear(second.position, second.position, 6.0),
		"overlap separation keeps the second animal outside the trunk")
	Helpers.destroy_manager(manager)


## A body can end up a hair inside a solid's reach: nudged there by a neighbour through
## rounding, or born there. Every move from such a spot used to count as blocked, even
## one straight away from the trunk, so the animal never moved again. A seventh of the
## herbivores that starved at full fidelity stood like that beside a bush, grass in
## sight. Leaving, or sliding along, must be allowed; going deeper must not.
func _test_a_body_touching_a_solid_can_leave_it(a) -> void:
	var manager = Helpers.create_manager(906)
	var world = manager.world_state
	_add_solid(world, 6001, Vector2(112, 128), 12.0)
	var inside := Vector2(94.5, 128)
	a.is_true(not world.scenery.segment_clear(inside, inside, 6.0),
		"the spot itself still counts as touching the trunk")
	a.is_true(world.scenery.segment_clear(inside, Vector2(60, 128), 6.0), "moving straight away is clear")
	a.is_true(world.scenery.segment_clear(inside, Vector2(94.5, 100), 6.0), "sliding along the trunk is clear")
	a.is_true(not world.scenery.segment_clear(inside, Vector2(100, 128), 6.0), "moving deeper is still blocked")
	var animal = Helpers.spawn_herbivore(world, inside)
	animal.movement = animal.movement.duplicate(true)
	animal.movement["body_radius"] = 6.0
	# Placed, not spawned: spawning finds a free spot first.
	animal.position = inside
	for step in range(6):
		animal.move_with_vector(world, Vector2.LEFT, 70.0, 0.1)
	a.is_true(animal.position.x < inside.x - 5.0,
		"an animal touching a trunk walks away from it (x %.1f)" % animal.position.x)
	var path: PackedVector2Array = world.scenery.local_path(inside, Vector2(160, 128), 6.0)
	a.is_true(not path.is_empty(), "and can plan a way round it")
	Helpers.destroy_manager(manager)


func _test_common_depth_ties(a) -> void:
	var carcass := {"depth": 100.0, "depth_tie": 0, "id": 100000001}
	var herbivore := {"depth": 100.0, "depth_tie": 1, "id": 10}
	var predator := {"depth": 100.0, "depth_tie": 1, "id": 20}
	var bush := {"depth": 100.0, "depth_tie": 2, "id": -7}
	a.is_true(SceneSpriteBatchScript.depth_less(carcass, herbivore),
		"a carcass at the same base is stable below living animals")
	a.is_true(SceneSpriteBatchScript.depth_less(herbivore, predator),
		"different species at the same depth use stable agent IDs")
	a.is_true(SceneSpriteBatchScript.depth_less(predator, bush),
		"a bush at the same base paints over an animal standing in cover")
	a.is_true(SceneSpriteBatchScript.depth_less(
		{"depth": 90.0, "depth_tie": 2, "id": -1}, herbivore),
		"ground depth still outranks the equal-depth tie policy")
