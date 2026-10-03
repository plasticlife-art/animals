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


## Runs `water` from `from` to `to` seconds; returns `{dried: {index: time}, refilled: {...}, low: [...]}`.
func _run(water, from: float, to: float) -> Dictionary:
	var climate = ClimateScript.new()
	climate.configure({"climate": _shipped_climate()})
	var dried := {}
	var refilled := {}
	var low := [1.0, 1.0, 1.0]
	var time := from
	while time < to:
		climate.sample(time)
		water.step(TICK, climate)
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
	a.is_true(year["dried"].has(0), "the small pond dries in the first summer")
	a.is_true(float(year["dried"].get(0, 0.0)) > 180.0 and float(year["dried"].get(0, 999.0)) < 240.0,
		"three quarters into summer (%.0f s)" % float(year["dried"].get(0, -1.0)))
	a.is_true(not year["dried"].has(1), "a medium pond only shrinks")
	a.near(float(year["low"][1]), 0.178, 0.02, "to about a sixth by autumn")
	a.near(float(year["low"][2]), 0.446, 0.02, "a big one keeps nearly half")
	a.is_true(year["refilled"].has(0) and float(year["refilled"][0]) < 480.0, "the small one is back by the end of winter")
	var spring := _run(water, 480.0, 540.0)
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
	a.is_true(year["dried"].has(0) and year["dried"].has(1), "a drought dries the medium pond too")
	a.is_true(not year["dried"].has(2), "but not the big one")
	a.near(float(year["low"][2]), 0.113, 0.02, "which goes down to about a tenth")


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
	a.near(full, 5.0 * 840.0, 0.5, "a mean pond holds five seasons of one herd")
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
