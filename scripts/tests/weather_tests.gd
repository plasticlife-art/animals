extends RefCounted

## The weather (`Weather`, `world.weather`): off without the block; spells drawn the same for a
## seed and differently for another; each season's evened effects keep its means; a spell eases
## in; a vote's weather overrides the drawn one while it lasts; in the world, what the weather does
## reaches the clock - pace, thirst, sight, the ponds; and the reserve's votes bring their weather.

const Helpers := preload("res://scripts/tests/test_helpers.gd")
const ConfigLoaderScript := preload("res://scripts/core/config_loader.gd")
const WeatherScript := preload("res://scripts/world/weather.gd")


func run(a) -> void:
	var config := _config()
	_test_off(a, config)
	_test_spells(a, config)
	_test_even_means(a, config)
	_test_easing_and_forcing(a, config)
	_test_in_the_world(a, config)
	_test_votes(a, config)


static func _config() -> Dictionary:
	var config: Dictionary = ConfigLoaderScript.load_config_bundle()["world"]["weather"].duplicate(true)
	config["enabled"] = true
	return config


func _test_off(a, config: Dictionary) -> void:
	var off := config.duplicate(true)
	off["enabled"] = false
	a.equal(WeatherScript.evaluate(off, "spring", 100.0, 7), WeatherScript.NEUTRAL, "no weather while it is off")
	var world = Helpers.create_manager(9951).world_state
	world.step(0.05, 1, 30.0)
	a.is_true(not world.weather_on and world.climate.weather_kind == "" and world.climate.movement_multiplier == 1.0,
		"a world without the block has none")


func _test_spells(a, config: Dictionary) -> void:
	var same := true
	var differs := false
	var kinds := {}
	for number in range(200):
		var kind: String = WeatherScript.kind_of_spell(config, "spring", number, 7)
		same = same and kind == WeatherScript.kind_of_spell(config, "spring", number, 7)
		differs = differs or kind != WeatherScript.kind_of_spell(config, "spring", number, 8)
		kinds[kind] = int(kinds.get(kind, 0)) + 1
	a.is_true(same and differs, "a seed draws the same spells, another seed others")
	a.is_true(kinds.keys().all(func(kind) -> bool: return config["seasons"]["spring"].has(kind)) and kinds.size() == 4,
		"only the season's kinds, all of them (%s)" % str(kinds))
	a.is_true(not kinds.has("snow") and WeatherScript.kind_of_spell(config, "winter", 3, 7) in ["clear", "snow", "fog"],
		"no snow in spring")


func _test_even_means(a, config: Dictionary) -> void:
	var even := true
	for season in config["seasons"].keys():
		var weights: Dictionary = config["seasons"][season]
		var means := WeatherScript.season_means(config, season)
		var totals := {"water": 0.0, "regrowth": 0.0, "thirst": 0.0, "metabolism": 0.0}
		var weight_sum := 0.0
		for kind in weights.keys():
			var effects := WeatherScript.effects(config, kind, means)
			weight_sum += float(weights[kind])
			for key in totals.keys():
				totals[key] += float(weights[kind]) * float(effects[key])
		even = even and absf(totals["water"] / weight_sum) < 1e-9 and absf(totals["regrowth"] / weight_sum - 1.0) < 1e-9 \
			and absf(totals["thirst"] / weight_sum - 1.0) < 1e-9 and absf(totals["metabolism"] / weight_sum - 1.0) < 1e-9
	a.is_true(even, "each season's weather keeps its means: the ponds, the grass, the needs")
	var fog := WeatherScript.effects(config, "fog", WeatherScript.season_means(config, "autumn"))
	a.equal(float(fog["perception"]), 0.55, "but a fog's sight is a fog's")


func _test_easing_and_forcing(a, config: Dictionary) -> void:
	var spell := float(config["spell_seconds"])
	var number := 0
	while WeatherScript.kind_of_spell(config, "spring", number, 7) == WeatherScript.kind_of_spell(config, "spring", number - 1, 7):
		number += 1
	var start := float(number) * spell
	var means := WeatherScript.season_means(config, "spring")
	var before := WeatherScript.effects(config, WeatherScript.kind_of_spell(config, "spring", number - 1, 7), means)
	var after := WeatherScript.effects(config, WeatherScript.kind_of_spell(config, "spring", number, 7), means)
	var at_start := WeatherScript.evaluate(config, "spring", start, 7)
	var eased := WeatherScript.evaluate(config, "spring", start + float(config["ease_seconds"]), 7)
	a.is_true(is_equal_approx(float(at_start["perception"]), float(before["perception"]))
		and is_equal_approx(float(eased["perception"]), float(after["perception"])), "a spell eases in from the one before")
	var forced := [{"kind": "weather", "weather": "downpour", "since": start + 1.0, "until": start + 30.0}]
	var during := WeatherScript.evaluate(config, "spring", start + 20.0, 7, forced)
	var after_it := WeatherScript.evaluate(config, "spring", start + 31.0, 7, forced)
	a.is_true(str(during["kind"]) == "downpour" and float(during["water"]) > float(config["kinds"]["rain"]["water"])
		and str(after_it["kind"]) == WeatherScript.kind_of_spell(config, "spring", number, 7), "a vote's weather while it lasts")


func _test_in_the_world(a, config: Dictionary) -> void:
	var bundle: Dictionary = Helpers.build_test_bundle(9952)
	var shipped: Dictionary = ConfigLoaderScript.load_config_bundle()
	bundle["world"]["climate"] = shipped["world"]["climate"].duplicate(true)
	bundle["world"]["water_levels"] = shipped["world"]["water_levels"].duplicate(true)
	bundle["world"]["water_levels"]["enabled"] = true
	bundle["world"]["weather"] = config.duplicate(true)
	var manager = Helpers.create_manager_with(bundle, 9952)
	var world = manager.world_state
	a.is_true(world.weather_on, "a world with the block has weather")
	world.world_events.append({"kind": "weather", "weather": "snow", "since": 0.0, "until": 100.0})
	world.step(0.05, 200, 10.0)
	var snow_pace: float = world.climate.movement_multiplier
	var snow_sight: float = world.climate.perception_multiplier
	world.world_events = [{"kind": "weather", "weather": "heat", "since": 0.0, "until": 100.0}]
	world.step(0.05, 201, 10.05)
	a.is_true(world.climate.weather_kind == "heat" and is_equal_approx(world.climate.thirst_multiplier, float(config["kinds"]["heat"]["thirst"]))
		and is_equal_approx(world.climate.water_bias, float(config["kinds"]["heat"]["water"]) - float(WeatherScript.season_means(config, "spring")["water"])),
		"heat: thirst and drying ponds, against spring's mean")
	a.is_true(is_equal_approx(snow_pace, 0.85) and snow_sight < 0.85, "snow: slower and shorter-sighted")
	world.world_events = [{"kind": "weather", "weather": "downpour", "since": 0.0, "until": 100.0}]
	world.step(0.05, 202, 10.1)
	_lower_ponds(world)
	var before: float = world.water.mean_level()
	world.water.step(1.0, world.climate)
	var rained: float = world.water.mean_level() - before
	world.world_events = [{"kind": "weather", "weather": "clear", "since": 0.0, "until": 100.0}]
	world.step(0.05, 203, 10.15)
	_lower_ponds(world)
	before = world.water.mean_level()
	world.water.step(1.0, world.climate)
	a.is_true(rained > world.water.mean_level() - before, "a downpour fills the ponds faster than a clear spell")
	Helpers.destroy_manager(manager)


static func _lower_ponds(world) -> void:
	for index in range(world.water.levels.size()):
		world.water.levels[index] = 0.3


func _test_votes(a, config: Dictionary) -> void:
	var bundle: Dictionary = preload("res://scripts/tests/reserve_command_tests.gd")._bundle(9953)
	bundle["world"]["weather"] = config.duplicate(true)
	var manager = Helpers.create_manager_with(bundle, 9953)
	var world = manager.world_state
	var revision: int = world.world_events_revision
	world._apply_player_commands([PlayerCommands.make(1, "rain", {}), PlayerCommands.make(2, "drought", {}),
		PlayerCommands.make(3, "cold_snap", {})])
	var brought: Array = world.weather_forced().map(func(event) -> String: return str(event["weather"]))
	a.equal(brought, ["downpour", "heat", "snow"], "a rain brings a downpour, a dry spell heat, a cold snap snow")
	a.is_true(world.world_events_revision > revision, "and the view is told")
	Helpers.destroy_manager(manager)
