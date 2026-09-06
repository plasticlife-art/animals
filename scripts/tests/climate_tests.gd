extends RefCounted

const ClimateScript := preload("res://scripts/world/climate.gd")
const ConfigLoaderScript := preload("res://scripts/core/config_loader.gd")
const TestHelpers := preload("res://scripts/tests/test_helpers.gd")

const DAY := 120.0
const SEASON := 120.0
const YEAR := 480.0


func _shipped_config() -> Dictionary:
	return ConfigLoaderScript.load_config_bundle().get("world", {}).get("climate", {})


func run(asserts) -> void:
	var config: Dictionary = _shipped_config()
	asserts.is_true(not config.is_empty(), "world.json should ship a climate block")
	if config.is_empty():
		return

	_test_neutral_at_zero(asserts, config)
	_test_season_cycle(asserts, config)
	_test_declared_values_are_reached(asserts, config)
	_test_continuity(asserts, config)
	_test_day_phase(asserts, config)
	_test_composition(asserts, config)
	_test_kill_switch(asserts, config)
	_test_purity(asserts, config)
	_test_per_species_perception(asserts, config)
	_test_seasonal_regrowth_keeps_working_set(asserts)
	_test_active_and_dormant_metabolism_agree(asserts)
	_test_species_metabolism_is_never_mutated(asserts)
	_test_clock_survives_a_save_round_trip(asserts)


## The invariant every other suite leans on. `start_day_phase: 0.5` puts t=0 at
## noon and `start_season_index: 0` puts it in spring, so nothing the climate
## does can perturb a fixture that starts at zero. If this fails, expect
## SimulationTests and EvaluatorTests to fail with it - fix this first.
func _test_neutral_at_zero(asserts, config: Dictionary) -> void:
	var at_zero: Dictionary = ClimateScript.evaluate(config, 0.0)
	asserts.equal(str(at_zero["season_id"]), "spring", "t=0 should be spring")
	asserts.equal(float(at_zero["regrowth_multiplier"]), 1.0, "t=0 regrowth multiplier should be exactly 1.0")
	asserts.equal(float(at_zero["metabolism_multiplier"]), 1.0, "t=0 metabolism multiplier should be exactly 1.0")
	asserts.equal(float(at_zero["perception_multiplier"]), 1.0, "t=0 perception multiplier should be exactly 1.0")
	asserts.equal(float(at_zero["night_ratio"]), 0.0, "t=0 night ratio should be exactly 0.0")
	asserts.is_true(not bool(at_zero["is_night"]), "t=0 should be daytime")


func _test_season_cycle(asserts, config: Dictionary) -> void:
	var expected := ["spring", "summer", "autumn", "winter"]
	for index in range(expected.size()):
		var values: Dictionary = ClimateScript.evaluate(config, SEASON * float(index) + 1.0)
		asserts.equal(str(values["season_id"]), expected[index],
			"season %d should be %s" % [index, expected[index]])
		asserts.equal(int(values["season_index"]), index, "season index %d" % index)
		asserts.equal(int(values["year"]), 0, "first four seasons should be year 0")

	var next_year: Dictionary = ClimateScript.evaluate(config, YEAR + 1.0)
	asserts.equal(str(next_year["season_id"]), "spring", "the year should wrap back to spring")
	asserts.equal(int(next_year["year"]), 1, "one year length in should be year 1")


## Guards against an interpolation scheme that never actually reaches the
## numbers written in the config. t = 372 is winter at 10% progress (inside the
## 65% hold band) and mid-afternoon (no night factor), so the season values must
## come through untouched.
func _test_declared_values_are_reached(asserts, config: Dictionary) -> void:
	var deep_winter: Dictionary = ClimateScript.evaluate(config, 372.0)
	asserts.equal(str(deep_winter["season_id"]), "winter", "t=372 should be winter")
	asserts.equal(float(deep_winter["night_ratio"]), 0.0, "t=372 should be full daylight")
	asserts.near(float(deep_winter["regrowth_multiplier"]), 0.40, 0.0001, "winter regrowth should reach 0.40")
	asserts.near(float(deep_winter["metabolism_multiplier"]), 1.15, 0.0001, "winter metabolism should reach 1.15")
	asserts.near(float(deep_winter["perception_multiplier"]), 0.90, 0.0001, "winter perception should reach 0.90")


## A discontinuous regrowth multiplier would show up as a step in the biomass
## chart at every season boundary. Sweeping the whole year catches it wherever
## it is, rather than only at the boundaries we thought to check.
func _test_continuity(asserts, config: Dictionary) -> void:
	var step := 0.1
	var tolerance := 0.02
	var previous: Dictionary = ClimateScript.evaluate(config, 0.0)
	var worst_regrowth := 0.0
	var worst_metabolism := 0.0
	var worst_perception := 0.0
	var worst_night := 0.0
	var time := step
	while time <= YEAR:
		var current: Dictionary = ClimateScript.evaluate(config, time)
		worst_regrowth = maxf(worst_regrowth,
			absf(float(current["regrowth_multiplier"]) - float(previous["regrowth_multiplier"])))
		worst_metabolism = maxf(worst_metabolism,
			absf(float(current["metabolism_multiplier"]) - float(previous["metabolism_multiplier"])))
		worst_perception = maxf(worst_perception,
			absf(float(current["perception_multiplier"]) - float(previous["perception_multiplier"])))
		worst_night = maxf(worst_night,
			absf(float(current["night_ratio"]) - float(previous["night_ratio"])))
		previous = current
		time += step
	asserts.check(worst_regrowth < tolerance,
		"regrowth multiplier should be continuous (worst step %.4f)" % worst_regrowth)
	asserts.check(worst_metabolism < tolerance,
		"metabolism multiplier should be continuous (worst step %.4f)" % worst_metabolism)
	asserts.check(worst_perception < tolerance,
		"perception multiplier should be continuous (worst step %.4f)" % worst_perception)
	asserts.check(worst_night < tolerance,
		"night ratio should be continuous (worst step %.4f)" % worst_night)


func _test_day_phase(asserts, config: Dictionary) -> void:
	var midnight: Dictionary = ClimateScript.evaluate(config, DAY * 0.5)
	asserts.near(float(midnight["day_phase"]), 0.0, 0.0001, "half a day past noon should be midnight")
	asserts.equal(float(midnight["night_ratio"]), 1.0, "midnight should be fully night")
	asserts.is_true(bool(midnight["is_night"]), "midnight should report is_night")

	var noon: Dictionary = ClimateScript.evaluate(config, DAY)
	asserts.near(float(noon["day_phase"]), 0.5, 0.0001, "a full day past noon should be noon again")
	asserts.equal(float(noon["night_ratio"]), 0.0, "noon should be fully day")


## Season and night must multiply, not add. t = 420 is winter at 50% progress
## (inside the hold) and exactly midnight.
func _test_composition(asserts, config: Dictionary) -> void:
	var winter_midnight: Dictionary = ClimateScript.evaluate(config, 420.0)
	asserts.equal(str(winter_midnight["season_id"]), "winter", "t=420 should be winter")
	asserts.equal(float(winter_midnight["night_ratio"]), 1.0, "t=420 should be midnight")
	asserts.near(float(winter_midnight["perception_multiplier"]), 0.90 * 0.55, 0.0001,
		"winter midnight perception should be the product of both factors")
	asserts.near(float(winter_midnight["metabolism_multiplier"]), 1.15 * 0.85, 0.0001,
		"winter midnight metabolism should be the product of both factors")
	asserts.near(float(winter_midnight["regrowth_multiplier"]), 0.40, 0.0001,
		"night does not change regrowth, so winter midnight stays at the season value")


func _test_kill_switch(asserts, config: Dictionary) -> void:
	var disabled: Dictionary = config.duplicate(true)
	disabled["enabled"] = false
	for time in [0.0, 37.5, 231.0, 419.0, 1234.5]:
		var values: Dictionary = ClimateScript.evaluate(disabled, float(time))
		asserts.equal(float(values["regrowth_multiplier"]), 1.0, "disabled climate regrowth at t=%s" % str(time))
		asserts.equal(float(values["metabolism_multiplier"]), 1.0, "disabled climate metabolism at t=%s" % str(time))
		asserts.equal(float(values["perception_multiplier"]), 1.0, "disabled climate perception at t=%s" % str(time))
		asserts.equal(float(values["night_ratio"]), 0.0, "disabled climate night ratio at t=%s" % str(time))
		asserts.is_true(values["light_color"] == Color.WHITE, "disabled climate light at t=%s" % str(time))


## The clock is a pure function of time and must stay one - a later refactor
## that starts accumulating would silently break save restore.
func _test_purity(asserts, config: Dictionary) -> void:
	for time in [0.0, 137.25, 401.75]:
		var first: Dictionary = ClimateScript.evaluate(config, float(time))
		var second: Dictionary = ClimateScript.evaluate(config, float(time))
		asserts.is_true(first == second, "evaluate should be pure at t=%s" % str(time))


func _test_per_species_perception(asserts, config: Dictionary) -> void:
	var tuned: Dictionary = config.duplicate(true)
	tuned["species_night_perception_multiplier"] = {"herbivore": 0.55, "predator": 0.80}
	var winter_midnight: Dictionary = ClimateScript.evaluate(tuned, 420.0)
	var by_species: Dictionary = winter_midnight["perception_multiplier_by_species"]
	asserts.near(float(by_species["herbivore"]), 0.90 * 0.55, 0.0001, "herbivore night vision override")
	asserts.near(float(by_species["predator"]), 0.90 * 0.80, 0.0001, "predator night vision override")

	var noon: Dictionary = ClimateScript.evaluate(tuned, 372.0)
	var noon_by_species: Dictionary = noon["perception_multiplier_by_species"]
	asserts.near(float(noon_by_species["herbivore"]), 0.90, 0.0001, "daytime override collapses to the season value")
	asserts.near(float(noon_by_species["predator"]), 0.90, 0.0001, "daytime override collapses to the season value")

	# The cache layer must hand back the same numbers as the pure core, and fall
	# back to the shared multiplier for a species with no override.
	var climate = ClimateScript.new()
	climate.configure({"climate": tuned})
	climate.sample(420.0)
	asserts.near(climate.perception_multiplier_for("herbivore"), 0.90 * 0.55, 0.0001, "cached herbivore multiplier")
	asserts.near(climate.perception_multiplier_for("predator"), 0.90 * 0.80, 0.0001, "cached predator multiplier")
	asserts.near(climate.perception_multiplier_for("unknown"), climate.perception_multiplier, 0.0001,
		"an unlisted species should fall back to the shared multiplier")
	asserts.equal(climate.clock_text(), "00:00", "midnight should read as 00:00")


## Builds a manager whose grass really regrows and whose clock starts in the
## season named by `start_season_index`.
func _seasonal_manager(seed_value: int, start_season_index: int, winter_regrowth: float):
	var bundle: Dictionary = TestHelpers.build_test_bundle(seed_value)
	bundle["world"]["grass"]["regrowth_rate"] = 4.0
	bundle["world"]["grass"]["initial_density_min"] = 1.0
	bundle["world"]["grass"]["initial_density_max"] = 1.0
	var climate_config: Dictionary = _shipped_config().duplicate(true)
	climate_config["enabled"] = true
	climate_config["start_season_index"] = start_season_index
	climate_config["seasons"][3]["regrowth_multiplier"] = winter_regrowth
	bundle["world"]["climate"] = climate_config
	var manager = preload("res://scripts/core/simulation_manager.gd").new()
	manager.initialize(bundle, seed_value)
	return manager


## The regression this locks in is not visible at the shipped numbers - winter
## regrowth of 0.4 is still far above `is_zero_approx`. It bites at a multiplier
## of zero, where testing the season-scaled growth would evict the cell from the
## sparse working set permanently, so it would never resume in spring.
func _test_seasonal_regrowth_keeps_working_set(asserts) -> void:
	var manager = _seasonal_manager(71, 3, 0.4)
	var resources = manager.world_state.resource_system
	asserts.equal(str(manager.world_state.climate.season_id), "winter", "fixture should start in winter")
	resources.consume_cell(0, 60.0)
	var after_bite: float = resources.get_biomass(0)
	TestHelpers.run_ticks(manager, 30)
	asserts.greater(resources.get_biomass(0), after_bite, "grass should still regrow through a moderate winter")
	asserts.greater(float(resources.get_regrowing_cell_count()), 0.0, "the bitten cell should stay in the working set")
	TestHelpers.destroy_manager(manager)

	# A season that stops regrowth outright must pause the cell, never forget it.
	var frozen = _seasonal_manager(71, 3, 0.0)
	var frozen_resources = frozen.world_state.resource_system
	frozen_resources.consume_cell(0, 60.0)
	var frozen_biomass: float = frozen_resources.get_biomass(0)
	TestHelpers.run_ticks(frozen, 30)
	asserts.near(frozen_resources.get_biomass(0), frozen_biomass, 0.0001,
		"a zero-multiplier season should hold the cell where it is")
	asserts.is_true(frozen_resources.get_regrowing_cell_count() > 0,
		"a zero-multiplier season must not evict the cell from the working set")
	TestHelpers.destroy_manager(frozen)


## The divergence trap. Shipping the fine-grained metabolism scale without the
## dormant mirror lets sleeping herds coast through a winter that starves the
## active ones, and because dormancy tracks the camera the bug hides wherever
## you happen to be looking. This drives both paths over the same elapsed time
## under the same clock and requires them to land in the same place.
func _test_active_and_dormant_metabolism_agree(asserts) -> void:
	var manager = _seasonal_manager(83, 3, 0.4)
	var world = manager.world_state
	asserts.equal(str(world.climate.season_id), "winter", "fixture should start in winter")
	var scale: float = world.climate.metabolism_multiplier
	asserts.greater(scale, 1.0, "winter should cost more than a neutral season")

	var species_config: Dictionary = manager.config_bundle.get("species", {}).get("herbivore", {})
	var hunger_rate: float = float(species_config.get("metabolism", {}).get("hunger_rate", 2.0))
	var elapsed: float = 4.0

	var active = TestHelpers.spawn_herbivore(world, Vector2(120.0, 120.0), 0)
	active.hunger = 10.0
	active.state = "idle"
	active.update_needs(elapsed, world.climate.metabolism_multiplier)
	var active_delta: float = active.hunger - 10.0

	var aggregate: Dictionary = {
		"species_type": "herbivore", "group_id": 0, "count": 3,
		"avg_hunger": 10.0, "avg_thirst": 0.0, "avg_energy": 80.0, "avg_age": 30.0,
		"center": Vector2(200.0, 200.0),
	}
	world._apply_dormant_metabolism_to_aggregate(world._get_sector_key(Vector2(200.0, 200.0)), aggregate, elapsed)
	var dormant_delta: float = float(aggregate["avg_hunger"]) - 10.0

	asserts.near(active_delta, hunger_rate * scale * elapsed, 0.0001,
		"the active path should scale hunger by the climate multiplier")
	asserts.near(dormant_delta, active_delta, 0.0001,
		"dormant and active hunger must advance identically under one climate")
	TestHelpers.destroy_manager(manager)


## `metabolism` is a reference into the shared species.json sub-dictionary, held
## by every agent of the species at once. Scaling has to happen at the read site.
func _test_species_metabolism_is_never_mutated(asserts) -> void:
	var manager = _seasonal_manager(91, 3, 0.4)
	var world = manager.world_state
	var raw: float = float(ConfigLoaderScript.load_config_bundle()
		.get("species", {}).get("herbivore", {}).get("metabolism", {}).get("hunger_rate", -1.0))
	var agent = TestHelpers.spawn_herbivore(world, Vector2(120.0, 120.0), 0)
	TestHelpers.run_ticks(manager, 20)
	asserts.near(float(agent.metabolism.get("hunger_rate", -1.0)), raw, 0.0001,
		"the shared species metabolism must survive a winter unmutated")
	asserts.near(float(manager.config_bundle.get("species", {}).get("herbivore", {})
		.get("metabolism", {}).get("hunger_rate", -1.0)), raw, 0.0001,
		"the config bundle metabolism must survive a winter unmutated")
	TestHelpers.destroy_manager(manager)


## The whole point of deriving the clock from `simulation_time` rather than
## accumulating it: the save format does not have to know the climate exists.
## If this ever needs a new stored field, `SAVE_VERSION` has to move with it and
## every existing autosave is discarded on load - so the version check is part
## of the assertion, not decoration.
func _test_clock_survives_a_save_round_trip(asserts) -> void:
	asserts.equal(SaveSystem.SAVE_VERSION, 1,
		"a derived clock needs no save-format change; bumping this means something started accumulating")

	var manager = _seasonal_manager(97, 0, 0.4)
	# Far enough to cross into another season and out of the neutral start.
	TestHelpers.run_ticks(manager, int(200.0 * manager.tick_rate))
	var before = manager.world_state.climate
	var expected_season: int = before.season_index
	var expected_phase: float = before.day_phase
	var expected_year: int = before.year
	asserts.is_true(expected_season != 0, "the fixture should have left the starting season")

	var path := "user://climate_round_trip_test.dat"
	asserts.is_true(SaveSystem.save(manager, {}, path), "save should succeed")
	TestHelpers.destroy_manager(manager)

	var restored = _seasonal_manager(97, 0, 0.4)
	var data: Dictionary = SaveSystem.read(path)
	asserts.is_true(not data.is_empty(), "the save should read back")
	asserts.is_true(SaveSystem.restore(restored, data), "restore should succeed")
	var after = restored.world_state.climate
	asserts.equal(after.season_index, expected_season, "the restored world should resume in the same season")
	asserts.equal(after.year, expected_year, "the restored world should resume in the same year")
	asserts.near(after.day_phase, expected_phase, 0.0001, "the restored world should resume at the same time of day")
	TestHelpers.destroy_manager(restored)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
