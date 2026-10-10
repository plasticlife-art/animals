extends RefCounted

## «Отстрел» (`WorldState._command_cull()`): the foxes nearest the point taken, as many as the power
## allows and only foxes; asleep too, their sector's census following; no carcass left; refusals
## that cost nothing; the same world on the worker as inline; the powers a world is offered
## (`powers.offered`) - every one in the sandbox, two in «Долгая сушь», all of a bundle without the
## list; and the feed telling of it once.

const Helpers := preload("res://scripts/tests/test_helpers.gd")
const ConfigLoaderScript := preload("res://scripts/core/config_loader.gd")
const PlayerStateScript := preload("res://scripts/world/player_state.gd")
const StoryBookScript := preload("res://scripts/story/story_book.gd")
const SimulationTests := preload("res://scripts/tests/simulation_tests.gd")

const AT := Vector2(1200.0, 1200.0)


func run(a) -> void:
	_test_the_nearest_foxes_go(a)
	_test_sleeping_foxes_go_too(a)
	_test_refusals_cost_nothing(a)
	_test_the_worker_culls_alike(a)
	_test_the_powers_a_world_is_offered(a)
	_test_the_feed_tells_it_once(a)


## A map wide enough to put foxes about, every animal awake unless a test puts a sector to sleep.
static func _world(seed: int):
	var manager = Helpers.create_manager_with(Helpers.build_large_sector_bundle(seed), seed)
	manager.set_lod_enabled(false)
	return manager


static func _cull(manager, at: Vector2) -> Dictionary:
	manager.enqueue_command("cull", {"position": at})
	manager.step_once()
	return manager.world_state.player.journal.back()


## Five foxes in a line from the point and one far off, a deer beside the point.
static func _foxes(world) -> Array:
	var foxes: Array = []
	for index in range(5):
		foxes.append(Helpers.spawn_predator(world, AT + Vector2(20.0 + 15.0 * index, 0.0)))
	foxes.append(Helpers.spawn_predator(world, AT + Vector2(1500.0, 0.0)))
	return foxes


func _test_the_nearest_foxes_go(a) -> void:
	var manager = _world(9961)
	var world = manager.world_state
	var foxes := _foxes(world)
	var deer = Helpers.spawn_herbivore(world, AT + Vector2(-10.0, 0.0), 0)
	var died: Array = []
	manager.world_event.connect(func(event: Dictionary) -> void:
		if str(event.get("type", "")) == "AgentDied":
			died.append([int(event.agent_id), str(event.data.cause)]))
	var carcasses: int = world.carcasses.size()
	var entry := _cull(manager, AT)
	var max_kills := int(world.player.settings("cull").get("max_kills", 3))
	a.is_true(bool(entry.result.get("ok", false)) and int(entry.result.get("killed", 0)) == max_kills,
		"a cull takes as many as it may (%d)" % max_kills)
	a.equal(entry.result.get("ids", []), [foxes[0].id, foxes[1].id, foxes[2].id], "the nearest first")
	a.equal(died, [[foxes[0].id, "culled"], [foxes[1].id, "culled"], [foxes[2].id, "culled"]], "each told dead of a cull")
	a.is_true(deer.is_alive and foxes[3].is_alive and foxes[5].is_alive, "the deer beside it, the next fox and the far one live")
	a.equal(world.carcasses.size(), carcasses, "no body is left to feed the rest")
	a.equal(int(manager.stats_system.counters.get("deaths_culled", 0)), max_kills, "the stats count the cull")
	Helpers.destroy_manager(manager)


func _test_sleeping_foxes_go_too(a) -> void:
	var manager = _world(9962)
	var world = manager.world_state
	_foxes(world)
	var sector_key: Vector2i = world._get_sector_key(AT)
	world._sleep_sector(sector_key)
	var before := int(world.get_population_metrics().get("predator_count", 0))
	var asleep: Array = []
	manager.world_event.connect(func(event: Dictionary) -> void:
		if str(event.get("type", "")) == "AgentDied" and bool(event.data.get("dormant", false)) and str(event.data.cause) == "culled":
			asleep.append(int(event.data.get("record_id", -1))))
	var entry := _cull(manager, AT)
	a.is_true(bool(entry.result.get("ok", false)) and int(entry.result.get("killed", 0)) == 3, "asleep, they are taken too")
	a.equal(asleep, entry.result.get("ids", []), "each told dead where it slept")
	# The sector wakes later in the same tick (no LOD here): the other two are about, awake or asleep.
	var near := 0
	for agent in world.get_living_agents():
		if agent.species_type == "predator" and agent.position.distance_to(AT) < 300.0:
			near += 1
	for record in world._sector_states.get(sector_key, {}).get("dormant_records", []):
		if str(record.get("species_type", "")) == "predator" and Vector2(record.get("position", Vector2.INF)).distance_to(AT) < 300.0:
			near += 1
	a.equal(near, 2, "the other two are left")
	a.equal(int(world.get_population_metrics().get("predator_count", 0)), before - 3, "and the census follows")
	Helpers.destroy_manager(manager)


func _test_refusals_cost_nothing(a) -> void:
	var manager = _world(9963)
	var world = manager.world_state
	world.player.budget["cull"]["charges"] = 1
	var reasons: Array = []
	reasons.append(str(_cull(manager, Vector2(-50.0, 100.0)).result.get("reason", "")))
	reasons.append(str(_cull(manager, AT).result.get("reason", "")))
	Helpers.spawn_herbivore(world, AT, 0)
	reasons.append(str(_cull(manager, AT).result.get("reason", "")))
	a.equal(reasons, ["off_map", "no_target", "no_target"], "off the map, nobody there, only a deer there: refused")
	a.equal(int(world.player.budget["cull"]["charges"]), 1, "and none of it spent the charge")
	Helpers.destroy_manager(manager)


## The same cull on the same tick leaves a worker-stepped world where an inline one is.
func _test_the_worker_culls_alike(a) -> void:
	var inline = SimulationTests._build_worker_fixture(9964)
	var threaded = SimulationTests._build_worker_fixture(9964)
	threaded.enable_interactive_worker()
	threaded.begin_interactive_stepping()
	var hunter := Vector2(180.0, 150.0)
	for tick in range(16):
		if tick == 6:
			inline.enqueue_command("cull", {"position": hunter})
			threaded.enqueue_command("cull", {"position": hunter})
		inline.step_once()
		threaded._post_worker_job()
		threaded.synchronize_worker()
	a.is_true(int(inline.world_state.player.journal.back().result.get("killed", 0)) == 1, "the fox is culled")
	a.equal("\n".join(Helpers.agent_state_lines(threaded.world_state)), "\n".join(Helpers.agent_state_lines(inline.world_state)),
		"and the worker's world is where the inline one is")
	a.equal(threaded.rng.state, inline.rng.state, "with the shared stream untouched alike")
	a.equal(threaded.world_state.player.used, {"cull": 1}, "and the view's copy counts the cull, for the result")
	a.equal(threaded.scenario.summary(threaded).get("powers_used", {}), {"cull": 1},
		"which a scenario's summary reads there, journal or not")
	Helpers.destroy_manager(threaded)
	Helpers.destroy_manager(inline)


func _test_the_powers_a_world_is_offered(a) -> void:
	var shipped: Dictionary = ConfigLoaderScript.load_config_bundle()["powers"]
	var sandbox = PlayerStateScript.new()
	sandbox.configure(shipped)
	a.is_true(sandbox.budget.has("dig_pond") and sandbox.budget.has("lead_herd") and sandbox.budget.has("cull"),
		"the sandbox has every power")
	var drought = PlayerStateScript.new()
	drought.configure(ConfigLoaderScript.load_scenario_bundle("long_drought")["powers"])
	a.equal(drought.budget.keys(), ["dig_pond", "lead_herd"], "«Долгая сушь» keeps its two")
	a.equal(drought.refusal("cull", 0.0), "unknown_power", "and refuses a cull")
	var old: Dictionary = shipped.duplicate(true)
	old.erase("offered")
	old["powers"].erase("cull")
	var saved = PlayerStateScript.new()
	saved.configure(old)
	a.equal(saved.budget.keys(), ["dig_pond", "lead_herd"], "a bundle from before the list has the powers it holds")


func _test_the_feed_tells_it_once(a) -> void:
	var manager = _world(9965)
	var world = manager.world_state
	_foxes(world)
	var book = StoryBookScript.new()
	book.bind(manager)
	book.begin()
	_cull(manager, AT)
	book.tick(manager.simulation_time)
	var lines: Array = book.feed.lines.filter(func(line: Dictionary) -> bool: return str(line.get("kind", "")) == "player")
	a.equal(lines.size(), 1, "one line for the cull")
	a.is_true(not lines.is_empty() and str(lines[0]["text"]).begins_with("Отстрел") and str(lines[0]["text"]).ends_with("3 лисы"),
		"«Отстрел …: 3 лисы» (%s)" % (str(lines[0]["text"]) if not lines.is_empty() else ""))
	a.equal(book.feed.lines.filter(func(line: Dictionary) -> bool: return str(line.get("cause", "")) == "culled").size(), 0,
		"and no line a fox")
	a.is_true(book.epitaphs.is_empty(), "no epitaph either")
	Helpers.destroy_manager(manager)
