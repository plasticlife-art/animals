extends RefCounted

## Scenarios (`scenarios.json`, `ConfigLoader.load_scenario_bundle()`, `ScenarioRunner`): the
## bundle a scenario is played with - its own options and patch over the player's look, its
## challenge kept in it - the world it begins, the herd that is the player's, awake and asleep
## and split, the deaths and goals counted, the result decided on the very tick autumn begins,
## and the score saved; the manager keeping it inline and from worker frames, a save carrying it
## into its own slots and back without taking the start again or repeating the result, Continue
## opening the save written last, a version 3 save still loading, and the first season of a world
## begun in summer seen whole.

const Helpers := preload("res://scripts/tests/test_helpers.gd")
const ConfigLoaderScript := preload("res://scripts/core/config_loader.gd")
const ScenarioRunnerScript := preload("res://scripts/core/scenario_runner.gd")
const StoryBookScript := preload("res://scripts/story/story_book.gd")
const TEST_SAVE_DIR := "user://test_scenario_saves"

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
	_test_the_manager_keeps_score(a)
	_test_a_scenario_saved_and_loaded(a)
	_test_its_own_slots(a)
	_test_the_first_season_seen_whole(a)
	_test_years_species_and_culls(a)


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
	a.is_true(float(powers.dig_pond.start_level) < float(ConfigLoaderScript.load_config_bundle().powers.powers.dig_pond.start_level),
		"its waterhole filled less than the sandbox's")
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


## The manager's own score (`SimulationManager.scenario`), begun again here once the herds are in
## place: it hears an inline tick's deaths and counts after it, and a worker frame's alike.
func _test_the_manager_keeps_score(a) -> void:
	var manager = _world(9926)
	var world = manager.world_state
	var own: Array = Helpers.spawn_herd(world, OWN_AT, 10, 0)
	Helpers.spawn_herd(world, OTHER_AT, 6, 1)
	manager._start_scenario()
	var changed: Array = []
	manager.scenario_goal_changed.connect(func(goal_id: String, state: String) -> void: changed.append([goal_id, state]))
	a.is_true(manager.scenario.is_active() and manager.scenario.baseline == 10, "the manager keeps the score of a scenario world")
	world.kill_agent(own[0], "thirst")
	manager.step_once()
	a.is_true(manager.scenario.thirst_deaths() == 1 and manager.scenario.count == 9, "an inline tick: the death heard, the herd counted")
	a.equal(changed, [["no_thirst", "failed"]], "and the manager says what changed")
	manager.enable_interactive_worker()
	manager.begin_interactive_stepping()
	var worker_world = manager._worker.world
	# Dies of thirst on the worker's next tick, as it would in a game.
	for agent in worker_world.get_living_agents():
		if agent.is_alive and agent.group_id == 0:
			agent.thirst = agent.need_max
			break
	manager._post_worker_job()
	manager.synchronize_worker()
	a.is_true(manager.scenario.thirst_deaths() == 2 and manager.scenario.count == 8,
		"a worker frame: the same (%d of thirst, %d left)" % [manager.scenario.thirst_deaths(), manager.scenario.count])
	Helpers.destroy_manager(manager)
	var plain = Helpers.create_manager(9927)
	a.is_true(not plain.scenario.is_active(), "a world without a challenge keeps none")
	var player = plain.world_state.player
	a.is_true(int(player.budget.dig_pond.charges) == -1 and int(player.budget.lead_herd.charges) == -1
		and float(player.settings("dig_pond").cooldown_seconds) > 0.0, "the sandbox: powers without charges, only cooldowns")
	Helpers.destroy_manager(plain)


## A save carries the score and a load takes it back: the starting count, the deaths, the goals
## and the curve as saved, not taken again from the world loaded; a result already in is not
## announced again, and one still to come is decided at its time.
func _test_a_scenario_saved_and_loaded(a) -> void:
	var manager = _world(9928)
	var world = manager.world_state
	var own: Array = Helpers.spawn_herd(world, OWN_AT, 10, 0)
	Helpers.spawn_herd(world, OTHER_AT, 6, 1)
	manager._start_scenario()
	world.kill_agent(own[0], "thirst")
	world.kill_agent(own[1], "predation")
	manager.step_once()
	var path := TEST_SAVE_DIR + "/roundtrip.dat"
	a.is_true(SaveSystem.save(manager, {}, path), "a scenario world saves")
	var data: Dictionary = SaveSystem.read(path)
	a.is_true(int(data.get("scenario", {}).get("baseline", -1)) == 10 and float(data.get("saved_at", 0.0)) > 0.0,
		"with its score and when it was written")
	var loaded = Helpers.create_manager(9929)
	var results: Array = []
	loaded.scenario_finished.connect(func(won: bool, _summary: Dictionary) -> void: results.append(won))
	a.is_true(SaveSystem.restore(loaded, data), "and loads")
	var score = loaded.scenario
	a.is_true(score.is_active() and score.baseline == 10 and score.groups.keys() == [0], "the starting count and the herd as saved")
	a.is_true(score.thirst_deaths() == 1 and int(score.deaths.get("predation", 0)) == 1 and score.count == 8,
		"the deaths and the count")
	a.equal(score.series.size(), manager.scenario.series.size(), "the curve")
	var decide_at := float(score.decide_times.keep_herd)
	loaded.simulation_time = decide_at - loaded.tick_duration * 0.5
	loaded.step_once()
	a.is_true(score.result == "won" and results == [true], "decided at its time after the load")
	SaveSystem.save(loaded, {}, path)
	var again = Helpers.create_manager(9930)
	var repeated: Array = []
	again.scenario_finished.connect(func(won: bool, _summary: Dictionary) -> void: repeated.append(won))
	SaveSystem.restore(again, SaveSystem.read(path))
	again.step_once()
	a.is_true(again.scenario.result == "won" and repeated.is_empty(), "a result already in is not announced again")
	for manager_done in [manager, loaded, again]:
		Helpers.destroy_manager(manager_done)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


## A scenario saves into its own slots and the sandbox into its own; Continue opens whichever was
## written last; a version 3 sandbox save, without a time, counts as the oldest and still loads.
func _test_its_own_slots(a) -> void:
	var shipped_dir: String = SaveSystem.save_dir
	SaveSystem.save_dir = TEST_SAVE_DIR
	for path in SaveSystem.slot_paths():
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	var sandbox = Helpers.create_manager(9931)
	Helpers.spawn_herbivore(sandbox.world_state, Vector2(100.0, 100.0), 0)
	var scenario_world = _world(9932)
	Helpers.spawn_herd(scenario_world.world_state, OWN_AT, 6, 0)
	scenario_world._start_scenario()
	a.is_true(SaveSystem.kind_of(sandbox) == "sandbox" and SaveSystem.kind_of(scenario_world) == "scenario", "each world knows its kind")
	SaveSystem.save(sandbox, {})
	SaveSystem.save(scenario_world, {})
	a.equal(SaveSystem.latest_slot().get_file(), "scenario_a.dat", "the scenario in its own slot, and Continue opens it")
	SaveSystem.save(sandbox, {})
	a.equal(SaveSystem.latest_slot().get_file(), "autosave_b.dat", "the sandbox written after it is opened instead")
	SaveSystem.save(sandbox, {})
	a.is_true(FileAccess.file_exists(TEST_SAVE_DIR + "/scenario_a.dat") and SaveSystem.next_slot("scenario").get_file() == "scenario_b.dat",
		"the sandbox writing on leaves the scenario's slot alone")
	a.equal(SaveSystem.next_slot().get_file(), "autosave_b.dat", "and alternates its own")
	# A save as version 3 wrote it: no player, no score, no time.
	var old: Dictionary = SaveSystem.read(TEST_SAVE_DIR + "/autosave_a.dat")
	old["version"] = 3
	old.erase("saved_at")
	old.erase("scenario")
	old["world"].erase("player")
	var file := FileAccess.open(TEST_SAVE_DIR + "/autosave_a.dat", FileAccess.WRITE)
	file.store_var(old, true)
	file.close()
	SaveSystem.save(sandbox, {}, TEST_SAVE_DIR + "/autosave_b.dat")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_SAVE_DIR + "/scenario_a.dat"))
	a.equal(SaveSystem.latest_slot().get_file(), "autosave_b.dat", "a save without a time is the oldest")
	var loaded = Helpers.create_manager(9933)
	a.is_true(SaveSystem.restore(loaded, SaveSystem.read(TEST_SAVE_DIR + "/autosave_a.dat"))
		and not loaded.scenario.is_active() and loaded.world_state.get_living_agents().size() == 1,
		"a version 3 save still loads, as a sandbox")
	for path in SaveSystem.slot_paths():
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	SaveSystem.save_dir = shipped_dir
	for manager_done in [sandbox, scenario_world, loaded]:
		Helpers.destroy_manager(manager_done)


## A world begun in summer opens its first season on its first tick: the season book sees it
## whole, not met half-way.
func _test_the_first_season_seen_whole(a) -> void:
	var manager = _world(9934)
	var book = StoryBookScript.new()
	book.bind(manager)
	book.begin()
	a.is_true(int(book.seasons.open.get("ordinal", -1)) == 1 and not bool(book.seasons.open.get("partial", true)),
		"summer, seen whole")
	Helpers.destroy_manager(manager)


## A goal the `years`-th season from the start; a species counted from its start and held to a floor;
## the foxes culled counted from the orders carried out; the watched species in the curve; and all
## of it saved.
func _test_years_species_and_culls(a) -> void:
	var manager = _world(9935)
	var world = manager.world_state
	Helpers.spawn_herd(world, OWN_AT, 6, 0)
	for at in [Vector2(2000.0, 2000.0), Vector2(2020.0, 2000.0), Vector2(2600.0, 600.0)]:
		Helpers.spawn_predator(world, at)
	manager.config_bundle["challenge"] = {
		"id": "foxes", "own_herd": {"species": "herbivore", "near": [0.5, 0.5]}, "watch": ["predator"],
		"goals": [
			{"id": "keep_herd", "role": "win", "form": "at_season_start", "season": "summer", "years": 2, "share_at_least": 0.5},
			{"id": "foxes_live", "role": "lose", "form": "always", "species_at_least": {"predator": 2}},
			{"id": "few_shots", "role": "bonus", "form": "always", "culled_at_most": 1},
		],
	}
	manager._start_scenario()
	var runner = manager.scenario
	a.equal(int(runner.decide_ordinals.keep_herd), 9, "begun in summer, decided two summers on")
	a.near(float(runner.decide_times.keep_herd), 960.0, 0.001, "at second 960")
	a.equal(int(runner.species_start.get("predator", 0)), 3, "the foxes counted at the start")
	a.equal(runner.series[0].size(), 4, "and watched in the curve")
	var saved: Dictionary = {}
	manager.enqueue_command("cull", {"position": Vector2(2010.0, 2000.0)})
	manager.step_once()
	a.equal(runner.culled, 2, "the two culled counted")
	a.equal(str(runner.states.few_shots), "failed", "past the limit, the bonus is lost")
	a.is_true(runner.result == "lost" and str(runner.states.foxes_live) == "failed", "one fox left of a floor of two: lost")
	saved = runner.export_state()
	var loaded = ScenarioRunnerScript.new()
	loaded.import_state(manager, JSON.parse_string(JSON.stringify(saved)))
	a.is_true(loaded.culled == 2 and int(loaded.species_start.get("predator", 0)) == 3 and int(loaded.species_now.get("predator", 0)) == 1,
		"the culls and the species saved")
	Helpers.destroy_manager(manager)
