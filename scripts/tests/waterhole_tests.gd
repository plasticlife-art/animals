extends RefCounted

## «Водопой» (`WorldState._command_dig_pond()`): a dug pond joins the water with every array in
## step and no other pond's capacity moved; bad places are refused with their reason and cost
## nothing; animals awake and asleep drink from it and it dries like any other; it comes back
## with a save, with its level and no news; it reaches the view even across a lost frame; it is
## named without renaming the map's ponds; the ground draws it; and the feed tells of it.

const Helpers := preload("res://scripts/tests/test_helpers.gd")
const ConfigLoaderScript := preload("res://scripts/core/config_loader.gd")
const PlaceNamesScript := preload("res://scripts/story/place_names.gd")
const StoryBookScript := preload("res://scripts/story/story_book.gd")
const GroundTracesScript := preload("res://scripts/ui/ground_traces.gd")
const WaterMaskScript := preload("res://scripts/ui/water_mask.gd")

## Between the fixture's two ponds, (64, 64) and (192, 192), clear of both.
const DIG_AT := Vector2(64.0, 192.0)


func run(a) -> void:
	_test_a_dug_pond_joins_the_water(a)
	_test_bad_places_are_refused(a)
	_test_animals_drink_from_it_and_it_dries(a)
	_test_it_comes_back_with_a_save(a)
	_test_the_view_gets_it_across_a_lost_frame(a)
	_test_names_stay_put(a)
	_test_the_ground_draws_it(a)
	_test_the_feed_tells_of_it(a)


func _wet_world(seed: int):
	var bundle := Helpers.build_test_bundle(seed)
	var climate: Dictionary = ConfigLoaderScript.load_config_bundle()["world"]["climate"].duplicate(true)
	climate["enabled"] = true
	bundle["world"]["climate"] = climate
	bundle["world"]["water_levels"] = {"enabled": true, "capacity_seasons": 4000.0}
	return Helpers.create_manager_with(bundle, seed)


static func _dig(manager, at: Vector2) -> Dictionary:
	manager.enqueue_command("dig_pond", {"position": at})
	manager.step_once()
	return manager.world_state.player.journal.back()


func _test_a_dug_pond_joins_the_water(a) -> void:
	var manager = _wet_world(9801)
	var world = manager.world_state
	var capacities: PackedFloat32Array = world.water.capacity.duplicate()
	var factors: PackedFloat32Array = world.water.size_factor.duplicate()
	var entry := _dig(manager, DIG_AT)
	a.is_true(bool(entry.result.get("ok", false)), "a pond is dug between the two")
	a.equal(int(entry.result.get("index", -1)), 2, "as the third")
	var water = world.water
	a.equal([world.water_sources.size(), water.levels.size(), water.dry.size(), water.capacity.size(), water.size_factor.size()],
		[3, 3, 3, 3, 3], "every array grows with it")
	a.equal([water.capacity[0], water.capacity[1], water.size_factor[0], water.size_factor[1]],
		[capacities[0], capacities[1], factors[0], factors[1]], "and no other pond's capacity moves")
	a.equal(water.index_at(DIG_AT), 2, "it is found by its centre")
	a.near(float(world.water_sources[2]["bank_radius"]), water.mean_radius, 0.001, "the size of the map's mean pond")
	a.near(water.levels[2], 0.8, 0.01, "filled as configured")
	a.near(float(world.water_sources[2]["radius"]), water.mean_radius * sqrt(water.levels[2]), 0.01, "with its water's edge")
	a.equal(world.player.ponds.size(), 1, "the player's state keeps it")
	a.is_true(world.player.journal.size() == 1 and world.query_water_sources(DIG_AT, 5.0).size() == 1, "and the world finds it")
	Helpers.destroy_manager(manager)


func _test_bad_places_are_refused(a) -> void:
	var manager = _wet_world(9802)
	var world = manager.world_state
	a.equal(str(_dig(manager, Vector2(4.0, 128.0)).result.get("reason", "")), "off_map", "half off the map")
	a.equal(str(_dig(manager, Vector2(80.0, 70.0)).result.get("reason", "")), "too_close", "on another pond's bank")
	var terrain = world.terrain_system
	var cell: int = terrain.get_index_from_position(Vector2(160.0, 64.0))
	terrain._walkable[cell] = 0
	a.equal(str(_dig(manager, Vector2(160.0, 64.0)).result.get("reason", "")), "blocked", "on a cliff")
	terrain._walkable[cell] = 1
	world.scenery.add_object({"id": 9999, "position": Vector2(170.0, 112.0), "kind": "tree", "radius": 6.0,
		"cover_radius": 0.0, "opacity": 0.0, "move_cost": 1.0, "slot": 0, "scale": 1.0, "level": 0})
	a.equal(str(_dig(manager, Vector2(164.0, 112.0)).result.get("reason", "")), "overgrown", "where a tree stands")
	a.equal(world.water_sources.size(), 2, "none of them is dug")
	a.equal(float(world.player.budget["dig_pond"].cooldown_until), 0.0, "and none is paid for")
	Helpers.destroy_manager(manager)


func _test_animals_drink_from_it_and_it_dries(a) -> void:
	var manager = _wet_world(9803)
	var world = manager.world_state
	_dig(manager, DIG_AT)
	var deer = Helpers.spawn_herbivore(world, DIG_AT + Vector2(40.0, 0.0), 0)
	deer.thirst = 80.0
	a.equal(Vector2(world._water_target_for(deer, 400.0).get("position", Vector2.INF)), DIG_AT, "a thirsty deer goes to it")
	a.equal(Vector2(world._find_nearest_water_goal(DIG_AT + Vector2(20.0, 0.0)).get("goal_position", Vector2.INF)), DIG_AT,
		"and a sleeping herd beside it")
	var before: float = world.water.levels[2]
	var drunk: float = world.water.drink(2, 100.0)
	a.near(drunk, 100.0, 0.001, "it gives water")
	a.is_true(world.water.levels[2] < before, "and goes down for it")
	world.water.levels[2] = 0.0
	world.water._settle(2)
	a.is_true(world.water.is_dry(2), "it dries like any other")
	a.is_true(Vector2(world.water.nearest_wet(DIG_AT).get("position", Vector2.INF)) != DIG_AT, "and is passed by dry")
	Helpers.destroy_manager(manager)


func _test_it_comes_back_with_a_save(a) -> void:
	var manager = _wet_world(9804)
	var world = manager.world_state
	_dig(manager, DIG_AT)
	world.water.levels[2] = 0.42
	world.water._settle(2)
	var deer = Helpers.spawn_herbivore(world, DIG_AT + Vector2(30.0, 0.0), 0)
	deer.remember_water(world.water_sources[2], world.current_time)
	var saved: Dictionary = world.export_state()
	var restored = _wet_world(9804)
	var heard: Array = []
	restored.world_state.event_bus.event_emitted.connect(func(event: Dictionary) -> void: heard.append(str(event.get("type", ""))))
	restored.world_state.import_state(saved)
	var back = restored.world_state
	a.equal(back.water_sources.size(), 3, "the dug pond comes back")
	a.equal(back.water.levels.size(), 3, "with a level for it")
	a.near(back.water.levels[2], 0.42, 0.0001, "the level it had")
	a.near(back.water.levels[0], world.water.levels[0], 0.0001, "and every other pond's too")
	a.equal(back.water.index_at(DIG_AT), 2, "found where it was")
	var remembered = back.get_agent(deer.id)
	var memory: Dictionary = remembered.recent_water_sources.back() if not remembered.recent_water_sources.is_empty() else {}
	a.equal(back.live_water(memory), back.water_sources[2], "a deer's memory of it still leads to it")
	a.is_true(not heard.has("PlayerCommand"), "and nothing is told: it was dug long ago")
	Helpers.destroy_manager(restored)
	Helpers.destroy_manager(manager)


## The worker digs; the frame that brought the pond is lost; the next one is a full snapshot,
## which carries the player's state, so the view's world gets the pond and the levels fit it.
func _test_the_view_gets_it_across_a_lost_frame(a) -> void:
	var manager = _wet_world(9805)
	Helpers.spawn_herbivore(manager.world_state, Vector2(120.0, 120.0), 0)
	manager.enable_interactive_worker()
	var worker = manager._worker
	var lod: Dictionary = manager._build_lod_context()
	manager._apply_worker_frame(worker.step(manager.tick_duration, 0, 0.0, lod, -1))
	worker.step(manager.tick_duration, 1, manager.tick_duration, lod, -1, false, false, 0,
		[PlayerCommands.make(1, "dig_pond", {"position": DIG_AT})])
	a.equal(worker.world.water_sources.size(), 3, "the worker digs")
	var later: Dictionary = worker.step(manager.tick_duration, 2, manager.tick_duration * 2.0, lod, -1)
	manager._apply_worker_frame(later)
	var view = manager.world_state
	a.equal(view.water_sources.size(), 3, "the view's world gets the pond after the lost frame")
	a.equal(view.water.levels.size(), 3, "with levels that fit")
	a.near(view.water.levels[2], worker.world.water.levels[2], 0.0001, "the worker's")
	manager._apply_worker_frame(later)
	a.equal(view.water_sources.size(), 3, "a frame applied twice digs nothing twice")
	Helpers.destroy_manager(manager)


## A world with 52 ponds of its own names them as it always did; a dug 53rd takes a name none of
## them has and renames none; a save brings every name back.
func _test_names_stay_put(a) -> void:
	var manager = _wet_world(9806)
	var world = manager.world_state
	var own := FakeWorld.new(world.terrain_system, world.bounds, _ponds(52))
	var before := PlaceNamesScript.new()
	before.build(own, 77)
	var dug := FakeWorld.new(world.terrain_system, world.bounds, _ponds(53))
	dug.player.ponds = [{"position": dug.water_sources[52]["position"], "bank_radius": 30.0, "index": 52}]
	var after := PlaceNamesScript.new()
	after.build(dug, 77)
	var same := 0
	var names := {}
	for index in range(52):
		if str(after.ponds[index]["name"]) == str(before.ponds[index]["name"]):
			same += 1
		names[str(before.ponds[index]["name"])] = true
	a.equal(same, 52, "the map's own ponds keep their names")
	a.is_true(not names.has(str(after.ponds[52]["name"])), "the dug one takes a name none of them has")
	var reloaded := PlaceNamesScript.new()
	reloaded.build(dug, 77)
	reloaded.import_state(after.export_state())
	a.equal(str(reloaded.ponds[52]["name"]), str(after.ponds[52]["name"]), "and keeps it through a save")
	Helpers.destroy_manager(manager)


static func _ponds(count: int) -> Array:
	var sources: Array = []
	for index in range(count):
		sources.append({"position": Vector2(20.0 + float(index % 8) * 30.0, 20.0 + floorf(float(index) / 8.0) * 30.0),
			"radius": 10.0, "bank_radius": 10.0})
	return sources


func _test_the_ground_draws_it(a) -> void:
	var manager = _wet_world(9807)
	var layer = GroundTracesScript.new()
	layer.bind_manager(manager)
	a.equal(layer.water_shrinks.size(), 2, "a shrink for each of the map's ponds")
	_dig(manager, DIG_AT)
	a.equal(layer.water_shrinks.size(), 3, "and one more for the dug pond, as soon as it is dug")
	a.is_true(WaterMaskScript.sample(layer._water_mask, DIG_AT) < 0.0, "the water field holds it")
	a.equal(int(layer._water_mask["ids"][_texel_of(layer._water_mask, DIG_AT)]), 2, "as its own pond")
	layer.free()
	Helpers.destroy_manager(manager)


static func _texel_of(mask: Dictionary, at: Vector2) -> int:
	var texel: float = mask["texel"]
	return int(floor(at.y / texel)) * int(mask["cols"]) + int(floor(at.x / texel))


func _test_the_feed_tells_of_it(a) -> void:
	var manager = _wet_world(9808)
	var book = StoryBookScript.new()
	book.bind(manager)
	book.begin()
	book.feed.context_provider = func(): return {"view": Rect2(-10, -10, 1, 1)}
	_dig(manager, DIG_AT)
	a.equal(book.places.ponds.size(), 3, "the dug pond is named")
	var district: int = book.places.district_at(DIG_AT)
	var where := "" if district < 0 else " " + str(book.places.districts[district]["at"])
	a.equal(str(book.feed.lines[0]["text"]) if not book.feed.lines.is_empty() else "",
		"Выкопан водопой: %s%s" % [book.places.ponds[2]["name"], where], "and the feed tells of it, out of view too")
	_dig(manager, Vector2(70.0, 70.0))
	a.equal(book.feed.lines.size(), 1, "a refused dig has no line")
	Helpers.destroy_manager(manager)


## What `PlaceNames.build()` reads of a world.
class FakeWorld:
	var terrain_system
	var bounds: Rect2
	var water_sources: Array
	var player := FakePlayer.new()

	func _init(terrain, map_bounds: Rect2, sources: Array) -> void:
		terrain_system = terrain
		bounds = map_bounds
		water_sources = sources


class FakePlayer:
	var ponds: Array = []
