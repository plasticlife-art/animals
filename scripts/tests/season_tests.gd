extends RefCounted

## The season ledger (`SeasonLedger`): which season a moment falls in, a season closing on the
## tick it ends with its numbers - a change in each species exactly its births less its deaths -
## the best hunter awake and asleep, the ponds that dried, a season seen only in part, the
## ledger kept with the story, and nothing at all without a clock.

const Helpers := preload("res://scripts/tests/test_helpers.gd")
const ClimateScript := preload("res://scripts/world/climate.gd")
const ConfigLoaderScript := preload("res://scripts/core/config_loader.gd")
const StoryBookScript := preload("res://scripts/story/story_book.gd")
const SeasonLedgerScript := preload("res://scripts/story/season_ledger.gd")

## Seconds a season lasts in these fixtures.
const SEASON := 6.0


func run(a) -> void:
	_test_ordinals(a)
	_test_seasons_close_with_their_numbers(a)
	_test_best_hunter(a)
	_test_dried_ponds_by_name(a)
	_test_partial_season(a)
	_test_kept_with_the_story(a)
	_test_no_clock_no_seasons(a)


func _climate(start_season := 0) -> Dictionary:
	var climate: Dictionary = ConfigLoaderScript.load_config_bundle()["world"]["climate"].duplicate(true)
	climate["enabled"] = true
	climate["day_length_seconds"] = SEASON
	climate["start_season_index"] = start_season
	return climate


func _world(seed: int):
	var bundle := Helpers.build_test_bundle(seed)
	bundle["world"]["climate"] = _climate()
	return Helpers.create_manager_with(bundle, seed)


func _book(manager):
	var book = StoryBookScript.new()
	book.bind(manager)
	book.begin()
	return book


func _test_ordinals(a) -> void:
	var climate: Dictionary = ConfigLoaderScript.load_config_bundle()["world"]["climate"].duplicate(true)
	climate["enabled"] = true
	a.equal(ClimateScript.season_ordinal(climate, 0.0), 0, "the world begins in its first season")
	a.equal(ClimateScript.season_ordinal(climate, 119.9), 0, "which lasts 120 s")
	a.equal(ClimateScript.season_ordinal(climate, 120.0), 1, "then the next")
	a.equal(ClimateScript.season_ordinal(climate, 480.0), 4, "and a year is four")
	climate["start_season_index"] = 2
	a.equal(ClimateScript.season_ordinal(climate, 0.0), 2, "a world started in autumn counts from autumn")
	climate["enabled"] = false
	a.equal(ClimateScript.season_ordinal(climate, 50.0), -1, "no clock, no seasons")


func _test_seasons_close_with_their_numbers(a) -> void:
	var manager = _world(9401)
	var world = manager.world_state
	for index in range(12):
		var deer = world.spawn_agent("herbivore", Vector2(40.0 + float(index % 6) * 30.0, 80.0 + floorf(index / 6.0) * 40.0),
			0, "female" if index % 2 == 0 else "male", {"reason": "initial"})
		deer.age = 120.0
		deer.reproduction_cooldown = 0.0
		deer.energy = 90.0
		# Three already starving, who die on the first tick.
		deer.hunger = deer.need_max if index < 3 else 0.0
		deer.thirst = 0.0
	Helpers._refresh_spatial_queries(world)
	var book = _book(manager)
	var closed: Array = []
	book.season_closed.connect(func(summary: Dictionary) -> void: closed.append(summary))
	Helpers.run_ticks(manager, int(SEASON * 2.0 / manager.tick_duration) + 2)
	a.equal(closed.size(), 2, "two seasons closed in two seasons' time")
	if closed.is_empty():
		return
	var first: Dictionary = closed[0]
	a.equal(str(first["label"]), "Весна", "the first was spring")
	a.equal(int(first["year"]), 0, "of the first year")
	a.is_true(not bool(first["partial"]), "seen whole")
	var deer: Dictionary = first["species"]["herbivore"]
	a.equal(int(deer["start"]), 12, "it began with the founders")
	a.equal(int(deer["end"]) - int(deer["start"]), int(deer["births"]) - int(deer["died"]),
		"and changed by exactly its births less its deaths (%d born, %d died)" % [int(deer["births"]), int(deer["died"])])
	a.is_true(int(deer["deaths"].get("starvation", 0)) >= 3, "the starving three died of hunger")
	var second: Dictionary = closed[1]
	a.equal(int(second["species"]["herbivore"]["start"]), int(deer["end"]), "the next season began where it ended")
	a.equal(str(second["label"]), "Лето", "and was summer")
	a.equal(book.seasons.closed.size(), 2, "the ledger keeps them")
	Helpers.destroy_manager(manager)


func _died(time: float, species: String, cause: String, killer := -1, asleep_killer := -1) -> Dictionary:
	var data := {"cause": cause}
	if asleep_killer >= 0:
		data["killer_record_id"] = asleep_killer
	return {"type": "AgentDied", "time_seconds": time, "species": species, "agent_id": 900 + int(time * 10.0),
		"other_agent_id": killer, "position": {"x": 0.0, "y": 0.0}, "data": data}


func _test_best_hunter(a) -> void:
	var manager = _world(9402)
	var book = _book(manager)
	for event in [_died(1.0, "herbivore", "predation", 7), _died(1.5, "herbivore", "predation", 7),
			_died(2.0, "herbivore", "predation", -1, 9), _died(2.5, "scavenger", "predation", -1, 9),
			_died(3.0, "herbivore", "starvation")]:
		book.seasons.hear(event)
	var tie: Dictionary = book.seasons.close(3.5, manager, book)
	a.equal(int(tie["hunter"].get("id", -1)), 7, "a tie goes to the lower id")
	a.equal(int(tie["hunter"].get("kills", 0)), 2, "with its kills")
	a.equal(int(tie["species"]["herbivore"]["deaths"].get("predation", 0)), 3, "kills awake and asleep are counted")
	book.seasons._open(1, 6.0, {}, false)
	for event in [_died(7.0, "herbivore", "predation", 7), _died(7.5, "herbivore", "predation", -1, 9),
			_died(8.0, "herbivore", "predation", -1, 9)]:
		book.seasons.hear(event)
	var asleep: Dictionary = book.seasons.close(9.0, manager, book)
	a.equal(int(asleep["hunter"].get("id", -1)), 9, "a hunter credited asleep can be the season's best")
	Helpers.destroy_manager(manager)


func _test_dried_ponds_by_name(a) -> void:
	var manager = _world(9403)
	var book = _book(manager)
	for index in [0, 1, 0]:
		book.seasons.hear({"type": "PondDried", "time_seconds": 2.0, "species": "", "agent_id": -1,
			"position": {"x": 0.0, "y": 0.0}, "data": {"index": index}})
	book.seasons.hear({"type": "PondRefilled", "time_seconds": 3.0, "species": "", "agent_id": -1,
		"position": {"x": 0.0, "y": 0.0}, "data": {"index": 1}})
	var summary: Dictionary = book.seasons.close(4.0, manager, book)
	a.equal(summary["dried"], [book.places.ponds[0]["name"], book.places.ponds[1]["name"]],
		"the ponds that dried, by name, once each")
	a.equal(summary["refilled"], [book.places.ponds[1]["name"]], "and the one that filled again")
	Helpers.destroy_manager(manager)


func _test_partial_season(a) -> void:
	var manager = _world(9404)
	Helpers.run_ticks(manager, int(SEASON * 0.5 / manager.tick_duration))
	var book = _book(manager)
	a.is_true(bool(book.seasons.open.get("partial", false)), "a season met half-way is not seen whole")
	var closed: Array = []
	book.season_closed.connect(func(summary: Dictionary) -> void: closed.append(summary))
	Helpers.run_ticks(manager, int(SEASON / manager.tick_duration) + 2)
	a.is_true(not closed.is_empty() and bool(closed[0]["partial"]), "and says so when it closes")
	a.is_true(closed.size() < 2 or not bool(closed[1]["partial"]), "the next one is whole")
	Helpers.destroy_manager(manager)


func _test_kept_with_the_story(a) -> void:
	var manager = _world(9405)
	var book = _book(manager)
	book.seasons.hear(_died(1.0, "herbivore", "thirst"))
	# Into the second season, which the book closes the first for on the way.
	Helpers.run_ticks(manager, int(SEASON / manager.tick_duration) + 2)
	book.seasons.hear(_died(7.0, "herbivore", "old_age"))
	var saved: Dictionary = book.export_state()
	a.equal(int(saved["version"]), StoryBookScript.STATE_VERSION, "the story's version stays as it was")
	var loaded = StoryBookScript.new()
	loaded.bind(manager)
	loaded.begin(saved)
	a.equal(loaded.seasons.closed.size(), 1, "closed seasons come back")
	a.equal(int(loaded.seasons.open.get("ordinal", -1)), 1, "and the open one")
	a.equal(int(loaded.seasons.open["deaths"]["herbivore"].get("old_age", 0)), 1, "with what it counted so far")
	saved.erase("seasons")
	var older = StoryBookScript.new()
	older.bind(manager)
	older.begin(saved)
	a.is_true(older.seasons.closed.is_empty(), "a story saved before seasons starts with none")
	Helpers.destroy_manager(manager)


func _test_no_clock_no_seasons(a) -> void:
	var manager = Helpers.create_manager(9406)
	var book = _book(manager)
	a.is_true(book.seasons.open.is_empty(), "no clock, no season open")
	var closed: Array = []
	book.season_closed.connect(func(summary: Dictionary) -> void: closed.append(summary))
	Helpers.run_ticks(manager, 200)
	a.is_true(closed.is_empty(), "and none closed")
	Helpers.destroy_manager(manager)
