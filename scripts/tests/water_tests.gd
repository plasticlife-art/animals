extends RefCounted

## Watering holes that fill and dry (`WaterSystem`): a pond's year in a normal year and a
## drought year, how often droughts come, drinking a pond down, the brink a pond does not
## flicker across, the world that skips dry ponds awake and asleep, saves, the events told, and
## a world without levels playing exactly as before.

const Helpers := preload("res://scripts/tests/test_helpers.gd")
const WaterSystemScript := preload("res://scripts/world/water_system.gd")
const ClimateScript := preload("res://scripts/world/climate.gd")
const ConfigLoaderScript := preload("res://scripts/core/config_loader.gd")
const DrinkUtilityEvaluatorScript := preload("res://scripts/agents/ai/evaluators/drink_utility_evaluator.gd")
const WaterMaskScript := preload("res://scripts/ui/water_mask.gd")
const GroundTracesScript := preload("res://scripts/ui/ground_traces.gd")
const PlaceNamesScript := preload("res://scripts/story/place_names.gd")
const StoryBookScript := preload("res://scripts/story/story_book.gd")
const StoryLogScript := preload("res://scripts/story/story_log.gd")

const TICK := 1.0 / 18.0


func run(a) -> void:
	_test_a_normal_year(a)
	_test_a_drought_year(a)
	_test_drought_years_are_rare(a)
	_test_drinking_down_and_the_brink(a)
	_test_levels_off_change_nothing(a)
	_test_world_skips_dry_ponds(a)
	_test_thirsty_deer_finds_far_water(a)
	_test_no_water_anywhere(a)
	_test_sleeping_groups_and_dry_ponds(a)
	_test_memory_forgets_dry_ponds(a)
	_test_levels_survive_a_save(a)
	_test_each_change_told_once(a)
	_test_mask_knows_each_pond_and_shrinks_it(a)
	_test_ground_layer_shrinks_ponds(a)
	_test_levels_reach_the_view(a)
	_test_pond_names_take_their_case(a)
	_test_feed_tells_ponds(a)


func _shipped_climate() -> Dictionary:
	var climate: Dictionary = ConfigLoaderScript.load_config_bundle()["world"]["climate"].duplicate(true)
	climate["enabled"] = true
	return climate


## Three ponds of 180, 230 and 280 (mean 230) measured against a 840-point herd, as on the large map.
func _three_ponds(config := {}) -> Array:
	var sources := [
		{"position": Vector2(0.0, 0.0), "radius": 180.0},
		{"position": Vector2(1000.0, 0.0), "radius": 230.0},
		{"position": Vector2(2000.0, 0.0), "radius": 280.0},
	]
	var water = WaterSystemScript.new()
	var settings := {"enabled": true}
	settings.merge(config, true)
	water.initialize(settings, sources, 840.0, 120.0, true, 4242)
	return [water, sources]


## Runs `water` from `from` to `to` seconds, a herd drinking `herd_at` (a pond's index, -1 for
## none) down by one starting herd's thirst a season; returns `{dried: {index: time},
## refilled: {...}, low: [...]}`.
func _run(water, from: float, to: float, herd_at := -1) -> Dictionary:
	var climate = ClimateScript.new()
	climate.configure({"climate": _shipped_climate()})
	var dried := {}
	var refilled := {}
	var low := [1.0, 1.0, 1.0]
	var time := from
	while time < to:
		climate.sample(time)
		water.step(TICK, climate)
		if herd_at >= 0:
			water.drink(herd_at, 840.0 / 120.0 * TICK)
		for change in water.take_transitions():
			var into: Dictionary = dried if str(change[1]) == "dried" else refilled
			if not into.has(int(change[0])):
				into[int(change[0])] = time
		for index in range(3):
			low[index] = minf(low[index], water.levels[index])
		time += TICK
	return {"dried": dried, "refilled": refilled, "low": low}


func _test_a_normal_year(a) -> void:
	var made := _three_ponds()
	var water = made[0]
	var sources: Array = made[1]
	a.equal(float(sources[1]["bank_radius"]), 230.0, "a pond keeps its bank")
	a.equal(int(sources[2]["index"]), 2, "and its place")
	var year := _run(water, 0.0, 480.0)
	a.is_true(year["dried"].is_empty(), "left alone, no pond dries in a normal summer")
	a.near(float(year["low"][0]), 0.156, 0.02, "the small one falls to about a sixth")
	a.near(float(year["low"][1]), 0.483, 0.02, "a medium one to about half")
	a.near(float(year["low"][2]), 0.651, 0.02, "a big one keeps two thirds")
	for index in range(3):
		a.is_true(water.levels[index] > 0.95, "autumn and winter rains fill it again (%.2f)" % water.levels[index])
	var drunk := _run(_three_ponds()[0], 0.0, 480.0, 0)
	a.is_true(float(drunk["dried"].get(0, 0.0)) > 180.0 and float(drunk["dried"].get(0, 999.0)) < 240.0,
		"a herd drinking the small one dries it late in summer (%.0f s)" % float(drunk["dried"].get(0, -1.0)))
	a.is_true(float(drunk["refilled"].get(0, 999.0)) < 300.0,
		"and it is back early in autumn (%.0f s)" % float(drunk["refilled"].get(0, -1.0)))
	_run(water, 480.0, 540.0)
	for index in range(3):
		a.is_true(water.levels[index] > 0.95, "every pond full again in early spring (%.2f)" % water.levels[index])
	a.near(float(sources[1]["radius"]), 230.0 * sqrt(water.levels[1]), 0.01, "its edge follows its level")


func _test_a_drought_year(a) -> void:
	var made := _three_ponds({"drought_chance": 1.0})
	var water = made[0]
	a.is_true(not water.is_drought_year(0), "never in the first year")
	a.is_true(water.is_drought_year(1), "a drought year when it comes")
	_run(water, 0.0, 480.0)
	var year := _run(water, 480.0, 960.0)
	a.is_true(year["dried"].has(0), "a drought dries the small pond on its own")
	a.near(float(year["low"][1]), 0.276, 0.02, "takes a medium one down to about a quarter")
	a.near(float(year["low"][2]), 0.512, 0.02, "and a big one to half")
	a.is_true(float(year["refilled"].get(0, 999.0)) < 780.0, "autumn rains bring the small one back (%.0f s)"
		% float(year["refilled"].get(0, -1.0)))


func _test_drought_years_are_rare(a) -> void:
	var water = _three_ponds()[0]
	var droughts := 0
	for year in range(1, 401):
		if water.is_drought_year(year):
			droughts += 1
	a.near(float(droughts) / 400.0, 0.25, 0.05, "about one year in four (%d of 400)" % droughts)
	var other = WaterSystemScript.new()
	other.initialize({"enabled": true}, [{"position": Vector2.ZERO, "radius": 200.0}], 840.0, 120.0, true, 99)
	var same := 0
	for year in range(1, 101):
		if other.is_drought_year(year) == water.is_drought_year(year):
			same += 1
	a.is_true(same < 100, "another world has other droughts (%d of 100 alike)" % same)


func _test_drinking_down_and_the_brink(a) -> void:
	var made := _three_ponds()
	var water = made[0]
	var full: float = water.capacity[1]
	a.near(full, 6.0 * 840.0, 0.5, "a mean pond holds six seasons of one herd")
	a.equal(water.drink(1, 50.0), 50.0, "a drink while there is water")
	a.near(water.levels[1], 1.0 - 50.0 / full, 0.00001, "takes it from the pond")
	water.levels[1] = 0.03
	var left: float = 0.03 * full
	a.near(water.drink(1, 500.0), left, 0.01, "the last of a pond is all it gives")
	a.is_true(water.is_dry(1), "and then it is dry")
	a.equal(water.drink(1, 10.0), 0.0, "a dry pond gives nothing")
	a.equal(water.take_transitions(), [[1, "dried"]], "told once")
	water.levels[1] = 0.08
	water._settle(1)
	a.is_true(water.is_dry(1), "a little rain is not yet water")
	water.levels[1] = 0.11
	water._settle(1)
	a.is_true(not water.is_dry(1), "a tenth of the basin is")
	a.equal(water.take_transitions(), [[1, "refilled"]], "told once")
	a.equal(water.dry_count(), 0, "none dry now")


## Off - the block missing, switched off, or the climate stopped - ponds never change and a
## world plays as it always has.
func _test_levels_off_change_nothing(a) -> void:
	var sources := [{"position": Vector2.ZERO, "radius": 200.0}]
	var off = WaterSystemScript.new()
	off.initialize({"enabled": false}, sources, 840.0, 120.0, true, 1)
	var climate = ClimateScript.new()
	climate.configure({"climate": _shipped_climate()})
	climate.sample(200.0)
	off.step(10.0, climate)
	a.equal(float(sources[0]["radius"]), 200.0, "a pond without levels keeps its size")
	a.equal(off.drink(0, 52.0), 52.0, "and gives every drink")
	var no_clock = WaterSystemScript.new()
	no_clock.initialize({"enabled": true}, sources, 840.0, 120.0, false, 1)
	a.is_true(not no_clock.enabled, "no levels without a clock")
	var plain := Helpers.build_test_bundle(9301)
	plain["world"].erase("water_levels")
	var reference := _run_small_world(plain, 9301)
	a.equal(_run_small_world(Helpers.build_test_bundle(9301), 9301), reference, "switched off is as if absent")
	var stopped := Helpers.build_test_bundle(9301)
	stopped["world"]["water_levels"] = {"enabled": true}
	a.equal(_run_small_world(stopped, 9301), reference, "and so is on without a clock")


func _run_small_world(bundle: Dictionary, seed: int) -> String:
	var manager = Helpers.create_manager_with(bundle, seed)
	var world = manager.world_state
	for index in range(8):
		var animal = world.spawn_agent("herbivore", Vector2(40.0 + float(index) * 25.0, 120.0), 0,
			"female" if index % 2 == 0 else "male", {"reason": "initial"})
		animal.thirst = 70.0
	Helpers._refresh_spatial_queries(world)
	Helpers.run_ticks(manager, 240)
	var fingerprint: String = Helpers.world_fingerprint(manager)
	Helpers.destroy_manager(manager)
	return fingerprint


## A test world with levels on: the fixture's two small ponds, deep enough to drink from.
func _wet_world(seed: int):
	var bundle := Helpers.build_test_bundle(seed)
	bundle["world"]["climate"] = _shipped_climate()
	bundle["world"]["water_levels"] = {"enabled": true, "capacity_seasons": 4000.0}
	return Helpers.create_manager_with(bundle, seed)


func _dry_up(world, index: int) -> void:
	world.water.levels[index] = 0.0
	world.water._settle(index)


func _test_world_skips_dry_ponds(a) -> void:
	var manager = _wet_world(9302)
	var world = manager.world_state
	a.is_true(world.water.enabled, "levels on with the clock")
	var near_first: Vector2 = world.water_sources[0]["position"]
	a.equal(world.query_water_sources(near_first, 10.0).size(), 1, "a wet pond is found")
	_dry_up(world, 0)
	a.equal(world.query_water_sources(near_first, 10.0).size(), 0, "a dry one is not")
	a.is_true(world._resolve_water_source(near_first, 10.0).is_empty(), "nor chosen")
	a.is_true(world.live_water(world.water_sources[0]).is_empty(), "nor live")
	a.equal(world.live_water({"position": world.water_sources[1]["position"]}), world.water_sources[1],
		"a memory of a wet pond is the pond")
	a.near(float(world.water_sources[0]["radius"]), 0.0, 0.001, "a dry pond has no water's edge")
	Helpers.destroy_manager(manager)


func _test_thirsty_deer_finds_far_water(a) -> void:
	var manager = _wet_world(9303)
	var world = manager.world_state
	var near_pond: Vector2 = world.water_sources[0]["position"]
	var deer = Helpers.spawn_herbivore(world, near_pond + Vector2(30.0, 0.0), 0)
	deer.thirst = 80.0
	_dry_up(world, 0)
	var target: Dictionary = world._water_target_for(deer, 20.0)
	a.equal(target.get("position", Vector2.INF), world.water_sources[1]["position"],
		"a thirsty deer by a dry pond heads for the wet one, however far")
	deer.thirst = 0.0
	a.is_true(world._water_target_for(deer, 20.0).is_empty(), "a slaked one does not go looking")
	Helpers.destroy_manager(manager)


func _test_no_water_anywhere(a) -> void:
	var manager = _wet_world(9304)
	var world = manager.world_state
	a.is_true(world.any_wet_water(), "water while any pond holds some")
	_dry_up(world, 0)
	_dry_up(world, 1)
	a.is_true(not world.any_wet_water(), "none once every pond is dry")
	var evaluator = DrinkUtilityEvaluatorScript.new()
	var context = Helpers.build_context({"thirst": 0.9, "drinking_allowed": 1.0, "water_reachable": 0.0})
	context.diagnostics = true
	var verdict: Dictionary = evaluator.evaluate(null, context)
	a.is_true(bool(verdict.get("vetoed", false)), "so a thirsty animal does not choose to drink")
	a.is_true(str(verdict.get("reasons", [])).contains("no water anywhere"), "and says why")
	Helpers.destroy_manager(manager)


func _test_sleeping_groups_and_dry_ponds(a) -> void:
	var manager = _wet_world(9305)
	var world = manager.world_state
	var first: Vector2 = world.water_sources[0]["position"]
	var second: Vector2 = world.water_sources[1]["position"]
	a.equal(world._find_nearest_water_goal(first + Vector2(5.0, 0.0)).get("goal_position"), first, "the nearest pond")
	_dry_up(world, 0)
	a.equal(world._find_nearest_water_goal(first + Vector2(5.0, 0.0)).get("goal_position"), second,
		"a sleeping group passes a dry one by")
	var group := {"count": 10, "avg_thirst": 60.0, "goal_kind": "water", "goal_position": second,
		"last_goal_refresh_time": 5.0}
	var before: float = world.water.levels[1]
	world._dormant_drink(group, 30.0)
	a.near(float(group["avg_thirst"]), 30.0, 0.0001, "the group drinks")
	a.near((before - world.water.levels[1]) * world.water.capacity[1], 300.0, 0.05, "and every head drinks the pond down")
	var stranded := {"count": 10, "avg_thirst": 60.0, "goal_kind": "water", "goal_position": first,
		"last_goal_refresh_time": 5.0}
	world._dormant_drink(stranded, 30.0)
	a.equal(float(stranded["avg_thirst"]), 60.0, "at a dry pond nobody drinks")
	a.equal(float(stranded["last_goal_refresh_time"]), -INF, "and the group chooses again at once")
	a.is_true(not world._dormant_water_goal_wet(stranded), "a dry goal is no rest stop")
	Helpers.destroy_manager(manager)


func _test_memory_forgets_dry_ponds(a) -> void:
	var manager = _wet_world(9306)
	var world = manager.world_state
	var deer = Helpers.spawn_herbivore(world, Vector2(128.0, 128.0), 0)
	deer.remember_water(world.water_sources[0], world.current_time)
	# Both dry, so the deer falls back on what it remembers.
	_dry_up(world, 0)
	_dry_up(world, 1)
	var water: Dictionary = deer._resolve_water_target(world)
	a.is_true(water.is_empty(), "a deer does not head for the pond it remembers dry")
	var remembered := false
	for entry in deer.recent_water_sources:
		if entry.get("position") == world.water_sources[0]["position"]:
			remembered = true
	a.is_true(not remembered, "and forgets it")
	Helpers.destroy_manager(manager)


func _test_levels_survive_a_save(a) -> void:
	var manager = _wet_world(9307)
	var world = manager.world_state
	world.water.levels[0] = 0.37
	world.water._settle(0)
	_dry_up(world, 1)
	var saved: Dictionary = world.export_state()
	var restored = _wet_world(9307)
	restored.world_state.import_state(saved)
	a.near(restored.world_state.water.levels[0], 0.37, 0.0001, "a level comes back")
	a.is_true(restored.world_state.water.is_dry(1), "and a dry pond stays dry")
	a.near(float(restored.world_state.water_sources[0]["radius"]), 18.0 * sqrt(0.37), 0.01, "with its edge")
	Helpers.destroy_manager(restored)
	var old: Dictionary = saved.duplicate()
	old.erase("water")
	var fresh = _wet_world(9307)
	fresh.world_state.import_state(old)
	a.equal(fresh.world_state.water.dry_count(), 0, "a save from before levels keeps its ponds full")
	Helpers.destroy_manager(fresh)
	Helpers.destroy_manager(manager)


func _test_each_change_told_once(a) -> void:
	var manager = _wet_world(9308)
	var world = manager.world_state
	var heard: Array = []
	manager.world_event.connect(func(event: Dictionary) -> void:
		if str(event.get("type", "")).begins_with("Pond"):
			heard.append(event))
	_dry_up(world, 0)
	world._emit_pond_transitions()
	world._emit_pond_transitions()
	a.equal(heard.size(), 1, "a pond drying is told once")
	a.equal(str(heard[0].get("type", "")) if not heard.is_empty() else "", "PondDried", "as dried")
	a.equal(int(heard[0].get("data", {}).get("index", -1)) if not heard.is_empty() else -1, 0, "naming the pond")
	Helpers.destroy_manager(manager)


func _test_mask_knows_each_pond_and_shrinks_it(a) -> void:
	var ponds := [{"position": Vector2(300, 400), "radius": 40.0, "bank_radius": 100.0},
		{"position": Vector2(700, 400), "radius": 60.0, "bank_radius": 60.0}]
	var mask: Dictionary = WaterMaskScript.bake(ponds, Vector2(1000, 800), 10.0, 40.0)
	a.equal(int(mask["ids"][40 * 100 + 30]), 0, "a texel in the first pond knows it")
	a.equal(int(mask["ids"][40 * 100 + 70]), 1, "and one in the second")
	a.equal(int(mask["ids"][5 * 100 + 5]), -1, "dry land belongs to no pond")
	a.is_true(WaterMaskScript.sample(mask, Vector2(300, 400)) < -90.0, "baked to the bank, not the water's edge")
	var shrinks := PackedFloat32Array([60.0, 0.0])
	a.near(WaterMaskScript.sample_shrunk(mask, shrinks, Vector2(300, 400)),
		WaterMaskScript.sample(mask, Vector2(300, 400)) + 60.0, 0.001, "shrunk by exactly its own amount")
	a.near(WaterMaskScript.sample_shrunk(mask, shrinks, Vector2(340, 400)), 0.0, 1.5, "and the edge is at 40")
	a.near(WaterMaskScript.sample_shrunk(mask, shrinks, Vector2(700, 400)), WaterMaskScript.sample(mask, Vector2(700, 400)),
		0.0001, "the other pond stays as it was")
	a.is_true(WaterMaskScript.sample_shrunk(mask, PackedFloat32Array([130.0, 0.0]), Vector2(300, 400)) > 0.0,
		"shrunk past its bank, no water is left")


func _test_ground_layer_shrinks_ponds(a) -> void:
	var manager = _wet_world(9309)
	var world = manager.world_state
	var layer = GroundTracesScript.new()
	layer.bind_manager(manager)
	a.equal(layer.water_shrinks.size(), 2, "a shrink for each pond")
	a.near(layer.water_shrinks[0], 0.0, 0.0001, "none while full")
	world.water.levels[0] = 0.25
	world.water._settle(0)
	_dry_up(world, 1)
	layer.refresh_water()
	a.near(layer.water_shrinks[0], 18.0 - 18.0 * 0.5, 0.01, "a pond at a quarter stands in half its radius")
	a.is_true(layer.water_shrinks[1] > 18.0, "a dry one is shrunk past its bank")
	layer.free()
	Helpers.destroy_manager(manager)


func _test_levels_reach_the_view(a) -> void:
	var manager = _wet_world(9310)
	manager.enable_interactive_worker()
	var worker = manager._worker
	worker.world.water.levels[0] = 0.4
	worker.world.water._settle(0)
	var frame: Dictionary = worker.step(manager.tick_duration, 0, 0.0, manager._build_lod_context(), -1, false)
	a.is_true(frame.has("water"), "a frame carries the ponds' levels")
	manager._apply_worker_frame(frame)
	a.near(manager.world_state.water.levels[0], worker.world.water.levels[0], 0.0001, "and the view's world takes them")
	a.near(float(manager.world_state.water_sources[0]["radius"]), float(worker.world.water_sources[0]["radius"]), 0.001,
		"with the water's edge")
	Helpers.destroy_manager(manager)


func _test_pond_names_take_their_case(a) -> void:
	for noun in PlaceNamesScript.POND_NOUNS:
		a.equal(noun.size(), 5, "%s has its locative and preposition" % noun[0])
	var still: Dictionary = PlaceNamesScript.compose("Тихий:v", ["заводь", "f", "заводи", "заводи", "в"])
	a.equal(str(still.get("in", "")), "в Тихой заводи", "в Тихой заводи")
	a.equal(str(still.get("gender", "")), "f", "a feminine pond")
	var ford: Dictionary = PlaceNamesScript.compose("Тихий:v", ["брод", "m", "брода", "броду", "в"])
	a.equal(str(ford.get("in", "")), "в Тихом броду", "в Тихом броду")
	var drink: Dictionary = PlaceNamesScript.compose("Лисий:p", ["водопой", "m", "водопоя", "водопое", "на"])
	a.equal(str(drink.get("in", "")), "на Лисьем водопое", "на Лисьем водопое")
	var lake: Dictionary = PlaceNamesScript.compose("Синий:s", ["озеро", "n", "озера", "озере", "в"])
	a.equal(str(lake.get("in", "")), "в Синем озере", "в Синем озере")
	var short: Dictionary = PlaceNamesScript.compose("Тихий:v", ["брод", "m", "брода"])
	a.equal(str(short.get("in", "")), str(short.get("at", "")), "a noun without its locative still names a place")


func _test_feed_tells_ponds(a) -> void:
	var manager = _wet_world(9311)
	var book = StoryBookScript.new()
	book.bind(manager)
	book.begin()
	var pond: Dictionary = book.places.ponds[0]
	var at: Vector2 = pond["position"]
	book.feed.context_provider = func(): return {"view": Rect2(at - Vector2(50, 50), Vector2(100, 100))}
	book.hear({"type": "PondDried", "time_seconds": 200.0, "species": "", "agent_id": -1,
		"position": {"x": at.x, "y": at.y}, "data": {"index": 0}})
	var verbs := {"m": "пересох", "f": "пересохла", "n": "пересохло"}
	var dried: String = str(pond["name"]) + " " + str(verbs[str(pond["gender"])])
	a.equal(str(book.feed.lines[0]["text"]) if not book.feed.lines.is_empty() else "", dried, "a pond in view: %s" % dried)
	book.hear({"type": "PondRefilled", "time_seconds": 450.0, "species": "", "agent_id": -1,
		"position": {"x": at.x, "y": at.y}, "data": {"index": 0}})
	a.equal(str(book.feed.lines[0]["text"]), HudText.capitalized(str(pond["in"])) + " снова вода", "and its water back")
	var far: Dictionary = book.places.ponds[1]
	book.feed.context_provider = func(): return {"view": Rect2(-10, -10, 1, 1)}
	book.hear({"type": "PondDried", "time_seconds": 460.0, "species": "", "agent_id": -1,
		"position": {"x": far["position"].x, "y": far["position"].y}, "data": {"index": 1}})
	a.equal(book.feed.lines.size(), 2, "a pond out of view gets no line of its own")
	book.feed.tick(470.0)
	book.feed.tick(600.0)
	a.is_true(str(book.feed.lines[0]["text"]).contains("пересохли — 1 водоём"), "it is in the minute's summary")
	var log = StoryLogScript.new()
	log.book = book
	log.context_provider = func(): return {"view": Rect2(-1000, -1000, 100000, 100000)}
	for index in range(2):
		log.hear({"type": "PondDried", "time_seconds": 300.0 + float(index), "species": "", "agent_id": -1,
			"position": {"x": book.places.ponds[index]["position"].x, "y": book.places.ponds[index]["position"].y},
			"data": {"index": index}})
	a.equal(log.lines.size(), 1, "two drying within seconds fold into one line")
	a.equal(str(log.lines[0]["text"]), "Пересохли %s и ещё 1 водоём" % book.places.ponds[0]["name"], "naming the first")
	Helpers.destroy_manager(manager)
