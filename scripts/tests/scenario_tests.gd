extends RefCounted

## Scenarios (`scenarios.json`, `ConfigLoader.load_scenario_bundle()`, `ScenarioRunner`): the
## bundle a scenario is played with - its own options and patch over the player's look, its
## challenge kept in it - the world it begins, the herd that is the player's, awake and asleep
## and split, the deaths and goals counted, the result decided on the very tick autumn begins,
## and the score saved.

const Helpers := preload("res://scripts/tests/test_helpers.gd")
const ConfigLoaderScript := preload("res://scripts/core/config_loader.gd")
const ScenarioRunnerScript := preload("res://scripts/core/scenario_runner.gd")

const OWN_AT := Vector2(1200.0, 1200.0)
const OTHER_AT := Vector2(2500.0, 2500.0)
const CHALLENGE := {
	"id": "test",
	"own_herd": {"species": "herbivore", "near": [0.5, 0.5]},
	"goals": [
		{"id": "keep_herd", "role": "win", "form": "at_season_start", "season": "autumn", "share_at_least": 0.6},
		{"id": "not_wiped", "role": "lose", "form": "always", "share_at_least": 0.3},
		{"id": "no_thirst", "role": "bonus", "form": "always", "thirst_deaths_at_most": 0},
	],
}


func run(a) -> void:
	_test_the_scenario_bundle(a)
	_test_the_world_it_begins(a)
	_test_the_own_herd(a)
	_test_deaths_and_goals(a)
	_test_decided_when_autumn_begins(a)
	_test_the_score_is_saved(a)


## A map wide enough for two herds apart, every animal awake unless a test puts a sector to
## sleep, the shipped clock begun in summer, and the test challenge.
static func _world(seed: int):
	var bundle: Dictionary = Helpers.build_large_sector_bundle(seed)
	var climate: Dictionary = ConfigLoaderScript.load_config_bundle()["world"]["climate"].duplicate(true)
	climate["enabled"] = true
	climate["start_season_index"] = 1
	bundle["world"]["climate"] = climate
	bundle["challenge"] = CHALLENGE.duplicate(true)
	var manager = Helpers.create_manager_with(bundle, seed)
	manager.set_lod_enabled(false)
	return manager


static func _runner(manager):
	var runner = ScenarioRunnerScript.new()
	runner.start(manager)
	manager.world_event.connect(runner.hear)
	return runner


func _test_the_scenario_bundle(a) -> void:
	var listed: Array = ConfigLoaderScript.list_scenarios()
	a.is_true(not listed.is_empty() and str(listed[0].id) == "long_drought" and str(listed[0].label) == "Долгая сушь",
		"«Долгая сушь» is on offer")
	var latin := RegEx.create_from_string("[A-Za-z]")
	for scenario in listed:
		a.is_true(latin.search(str(scenario.label) + str(scenario.brief)) == null, "%s is told in Russian" % scenario.id)
	var top: Dictionary = ConfigLoaderScript.load_scenario_bundle("long_drought", {"style": "topdown_kenney", "map_size": "small"})
	var iso: Dictionary = ConfigLoaderScript.load_scenario_bundle("long_drought", {"style": "isometric_craftpix"})
	var challenge: Dictionary = top.get("challenge", {})
	a.is_true(str(challenge.get("id", "")) == "long_drought" and int(challenge.get("seed", -1)) == 7
		and challenge.get("goals", []).size() == 3, "the challenge is in the bundle, with its id and seed")
	a.equal(float(top.world.world_size.x), 9600.0, "the scenario's map size, not the player's")
	a.equal(int(top.world.climate.start_season_index), 1, "it begins in summer")
	var droughts: Array = top.world.water_levels.drought_years
	a.is_true(droughts.size() == 1 and int(droughts[0]) == 0, "a drought the first year")
	a.near(float(top.world.water_levels.initial_level), 0.5, 0.0001, "ponds half full")
	a.is_true(bool(top.world.water_levels.enabled) and float(top.world.water_levels.drought_strength) > 1.0,
		"merged over the shipped water, not in place of it")
	a.is_true(int(top.world.terrain.height.levels) == 1 and int(iso.world.terrain.height.levels) == 1,
		"the same ground whatever the style")
	a.is_true(str(top.visuals.get("projection", "")) != str(iso.visuals.get("projection", "")), "the look stays the player's")
	var powers: Dictionary = top.powers.powers
	a.is_true(int(powers.dig_pond.charges) == 1 and int(powers.lead_herd.charges) == 2, "one waterhole, two walks")
	a.near(float(powers.dig_pond.radius_of_mean), 1.0, 0.0001, "the powers' own settings kept")
	a.is_true(float(top.balance.lifecycle.founder_age_share) < 0.9 and top.balance.lifecycle.size() > 1,
		"younger founders, the rest of the lifecycle as shipped")
	var plain: Dictionary = ConfigLoaderScript.load_config_bundle()
	a.is_true(not plain.has("challenge") and not plain.world.water_levels.has("drought_years")
		and not plain.world.water_levels.has("initial_level"), "a plain world has none of it")


func _test_the_world_it_begins(a) -> void:
	var bundle: Dictionary = ConfigLoaderScript.load_scenario_bundle("long_drought")
	var manager = Helpers.create_manager_with(bundle, int(bundle.challenge.seed))
	var world = manager.world_state
	a.equal(world.climate.season_id, "summer", "the world begins in summer")
	a.is_true(world.water.is_drought_year(0), "a drought year")
	a.near(world.water.mean_level(), 0.5, 0.0001, "its ponds half full")
	a.is_true(int(world.player.budget.dig_pond.charges) == 1 and int(world.player.budget.lead_herd.charges) == 2,
		"the player has the scenario's powers")
	var runner = _runner(manager)
	a.is_true(runner.is_active() and runner.groups.size() == 1 and runner.baseline > 0,
		"a herd is the player's (%d head)" % runner.baseline)
	Helpers.destroy_manager(manager)


func _test_the_own_herd(a) -> void:
	var manager = _world(9921)
	var world = manager.world_state
	var split_size := int(manager.config_bundle["species"]["herbivore"]["herd"]["split_size"])
	Helpers.spawn_herd(world, OWN_AT, split_size + 4, 0)
	Helpers.spawn_herd(world, OTHER_AT, 6, 1)
	var runner = _runner(manager)
	a.equal(runner.groups.keys(), [0], "the herd nearest the middle of the map is the player's")
	a.equal(runner.baseline, split_size + 4, "counted at the start")
	world._split_oversized_herds()
	runner.update(manager)
	a.equal(runner.groups.size(), 2, "the half split off it is the player's too")
	a.equal(runner.count, split_size + 4, "and still counted")
	world._sleep_sector(world._get_sector_key(OWN_AT))
	runner.update(manager)
	a.equal(runner.count, split_size + 4, "asleep, it is counted from its sector")
	a.equal(ScenarioRunnerScript.nearest_herd(world, "herbivore", OTHER_AT), 1, "the other herd is found awake")
	a.is_true(ScenarioRunnerScript.nearest_herd(world, "herbivore", OWN_AT) in runner.groups, "and the own one asleep")
	Helpers.destroy_manager(manager)


func _test_deaths_and_goals(a) -> void:
	var manager = _world(9922)
	var world = manager.world_state
	var own: Array = Helpers.spawn_herd(world, OWN_AT, 10, 0)
	var other: Array = Helpers.spawn_herd(world, OTHER_AT, 6, 1)
	var runner = _runner(manager)
	var changes: Array = []
	var results: Array = []
	runner.goal_changed.connect(func(goal_id: String, state: String) -> void: changes.append([goal_id, state]))
	runner.finished.connect(func(won: bool, summary: Dictionary) -> void: results.append([won, summary]))
	world.kill_agent(other[0], "thirst")
	runner.update(manager)
	a.equal(runner.thirst_deaths(), 0, "another herd's thirst is not the player's")
	world.kill_agent(own[0], "thirst")
	world.kill_agent(own[1], "predation")
	runner.update(manager)
	a.is_true(runner.thirst_deaths() == 1 and int(runner.deaths.get("predation", 0)) == 1, "the own herd's deaths, by cause")
	a.equal(runner.count, 8, "and its count")
	a.equal(changes, [["no_thirst", "failed"]], "one death of thirst loses the bonus")
	a.equal(runner.result, "", "and nothing else")
	for index in range(2, 8):
		world.kill_agent(own[index], "starvation")
	runner.update(manager)
	a.is_true(runner.result == "lost" and str(runner.states.not_wiped) == "failed", "under a third left, the scenario is lost")
	a.equal(str(runner.states.keep_herd), "failed", "and the goal still open settled")
	a.is_true(results.size() == 1 and not bool(results[0][0]) and int(results[0][1].lowest) == 2,
		"`finished` says so once, with the summary")
	world.kill_agent(own[8], "thirst")
	runner.update(manager)
	a.is_true(runner.count == 2 and results.size() == 1, "after the result the score keeps still")
	a.is_true(runner.holds({"thirst_share_at_most": 0.1}) and not runner.holds({"thirst_share_at_most": 0.05}),
		"one death of thirst in ten is a tenth")
	Helpers.destroy_manager(manager)


func _test_decided_when_autumn_begins(a) -> void:
	var manager = _world(9923)
	var world = manager.world_state
	Helpers.spawn_herd(world, OWN_AT, 10, 0)
	var runner = _runner(manager)
	var results: Array = []
	runner.finished.connect(func(won: bool, _summary: Dictionary) -> void: results.append(won))
	a.equal(int(runner.decide_ordinals.keep_herd), 2, "begun in summer, decided as autumn begins")
	var season_length := float(manager.config_bundle.world.climate.day_length_seconds) \
		* float(manager.config_bundle.world.climate.season_length_days)
	manager.simulation_time = season_length - 0.01
	runner.update(manager)
	a.equal(runner.result, "", "not on summer's last tick")
	manager.simulation_time = season_length
	runner.update(manager)
	a.is_true(runner.result == "won" and runner.decided_at == season_length, "on autumn's first")
	a.is_true(str(runner.states.not_wiped) == "met" and str(runner.states.no_thirst) == "met",
		"the goals never failed are kept")
	runner.update(manager)
	a.equal(results, [true], "won once")
	Helpers.destroy_manager(manager)
	manager = _world(9925)
	Helpers.spawn_herd(manager.world_state, OWN_AT, 10, 0)
	manager.config_bundle["challenge"]["goals"][0]["days"] = 0.5
	runner = _runner(manager)
	var day_length := float(manager.config_bundle.world.climate.day_length_seconds)
	manager.simulation_time = season_length + day_length * 0.5 - 0.01
	runner.update(manager)
	a.equal(runner.result, "", "a goal `days` into autumn waits past its first tick")
	manager.simulation_time = season_length + day_length * 0.5
	runner.update(manager)
	a.equal(runner.result, "won", "and is decided then")
	Helpers.destroy_manager(manager)


func _test_the_score_is_saved(a) -> void:
	var manager = _world(9924)
	var world = manager.world_state
	var own: Array = Helpers.spawn_herd(world, OWN_AT, 10, 0)
	Helpers.spawn_herd(world, OTHER_AT, 6, 1)
	var runner = _runner(manager)
	world.kill_agent(own[0], "thirst")
	runner.update(manager)
	var saved: Dictionary = JSON.parse_string(JSON.stringify(runner.export_state()))
	for index in range(1, 5):
		world.kill_agent(own[index], "predation")
	var loaded = ScenarioRunnerScript.new()
	loaded.import_state(manager, saved)
	a.equal(loaded.baseline, 10, "the starting count is the saved one, not taken again")
	a.is_true(loaded.groups.keys() == [0] and loaded.thirst_deaths() == 1 and str(loaded.states.no_thirst) == "failed",
		"the herd, the deaths and the goals as saved")
	a.equal(int(loaded.decide_ordinals.keep_herd), 2, "decided when it was to be")
	loaded.update(manager)
	a.is_true(loaded.count == 5 and loaded.result == "", "it counts on from there")
	Helpers.destroy_manager(manager)
