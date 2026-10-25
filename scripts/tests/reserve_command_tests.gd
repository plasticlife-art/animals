extends RefCounted

## The reserve's orders to the world (`adopt`, `rain`, `drought`, `cold_snap`, `bloom`, `release`):
## a viewer takes the nearest animal no one cares for, awake or asleep, and only one living at a
## time; the weather fills or empties the ponds and, for a while, quickens hunger or the grass;
## newcomers walk in from the edge, grown, the pair taking a free territory; the wards and the
## weather come back with a save; the worker carries the orders out as an inline tick does; and
## a world that does not offer them refuses them.

const Helpers := preload("res://scripts/tests/test_helpers.gd")
const ConfigLoaderScript := preload("res://scripts/core/config_loader.gd")
const RESERVE_POWERS := ["dig_pond", "lead_herd", "cull", "adopt", "rain", "drought", "cold_snap", "bloom", "release"]
const AT := Vector2(1500.0, 1500.0)


func run(a) -> void:
	_test_adoption(a)
	_test_adopting_a_sleeper(a)
	_test_the_weather(a)
	_test_newcomers(a)
	_test_kept_and_alike(a)
	_test_not_offered(a)


static func _bundle(seed: int) -> Dictionary:
	var bundle := Helpers.build_large_sector_bundle(seed)
	bundle["powers"]["offered"] = RESERVE_POWERS.duplicate()
	# Ponds with levels need the seasons; no cooldowns, so one test may order the same twice.
	var shipped: Dictionary = ConfigLoaderScript.load_config_bundle()
	bundle["world"]["climate"] = shipped["world"]["climate"].duplicate(true)
	bundle["world"]["water_levels"] = shipped["world"]["water_levels"].duplicate(true)
	bundle["world"]["water_levels"]["enabled"] = true
	for power in RESERVE_POWERS:
		bundle["powers"]["powers"][power]["cooldown_seconds"] = 0.0
	return bundle


static func _world(seed: int):
	var manager = Helpers.create_manager_with(_bundle(seed), seed)
	manager.set_lod_enabled(false)
	return manager


## What came of the order numbered `seq`, from the journal.
static func _result(world, seq: int) -> Dictionary:
	for entry in world.player.journal:
		if int(entry.get("seq", -1)) == seq:
			return entry.get("result", {})
	return {}


func _test_adoption(a) -> void:
	var manager = _world(9941)
	var world = manager.world_state
	var herd: Array = Helpers.spawn_herd(world, AT, 4, 0)
	var first: int = manager.enqueue_command("adopt", {"viewer": "twitch:1", "name": "  Ветка  ", "position": AT})
	manager.step_once()
	var result := _result(world, first)
	var ward := int(result.get("agent_id", -1))
	a.is_true(bool(result.get("ok", false)) and world.adoptions.has(ward), "a viewer takes an animal under care (%s)" % str(result))
	a.equal(str(world.adoptions.get(ward, {}).get("name", "")), "Ветка", "named as asked, trimmed")
	var second: int = manager.enqueue_command("adopt", {"viewer": "twitch:1", "name": "Ещё", "position": AT})
	var other: int = manager.enqueue_command("adopt", {"viewer": "youtube:2", "name": "Дымка", "position": AT})
	manager.step_once()
	a.equal(str(_result(world, second).get("reason", "")), PlayerCommands.REFUSED_HAS_WARD, "one living ward a viewer")
	a.is_true(int(_result(world, other).get("agent_id", -1)) not in [-1, ward], "another viewer takes another animal")
	for deer in herd:
		if deer.id == ward:
			world.kill_agent(deer, "old_age")
	a.is_true(float(world.adoptions[ward]["died_at"]) >= 0.0, "a ward's death is remembered")
	var again: int = manager.enqueue_command("adopt", {"viewer": "twitch:1", "name": "Снова", "position": AT})
	manager.step_once()
	a.is_true(bool(_result(world, again).get("ok", false)), "and its viewer may take another")
	Helpers.destroy_manager(manager)


func _test_adopting_a_sleeper(a) -> void:
	var manager = _world(9942)
	var world = manager.world_state
	Helpers.spawn_herd(world, AT, 4, 0)
	world._sleep_sector(world._get_sector_key(AT))
	# Carried out on the sleeping world as it is: a tick with LOD off would wake the sector.
	world._apply_player_commands([PlayerCommands.make(1, "adopt", {"viewer": "twitch:3", "name": "Соня", "position": AT})])
	var ward := int(_result(world, 1).get("agent_id", -1))
	var asleep := false
	for record in world._sector_states[world._get_sector_key(AT)].get("dormant_records", []):
		if int(record.get("id", -1)) == ward:
			asleep = true
	a.is_true(asleep, "an animal asleep far off can be taken under care too")
	Helpers.destroy_manager(manager)


func _test_the_weather(a) -> void:
	var manager = _world(9943)
	var world = manager.world_state
	world.water.add_to_all(-0.6)
	var before: float = world.water.mean_level()
	var state_before: int = world.rng.state
	manager.enqueue_command("rain", {})
	manager.step_once()
	var after_rain: float = world.water.mean_level()
	a.is_true(after_rain > before + 0.2, "rain fills the ponds (%.2f -> %.2f)" % [before, after_rain])
	manager.enqueue_command("drought", {})
	manager.step_once()
	a.is_true(world.water.mean_level() < after_rain - 0.2, "a dry spell empties them")
	var plain: float = world.climate.metabolism_multiplier
	manager.enqueue_command("cold_snap", {"seconds": 1.0, "factor": 1.5})
	manager.enqueue_command("bloom", {"seconds": 1.0, "factor": 2.0})
	manager.step_once()
	a.is_true(absf(world.climate.metabolism_multiplier - plain * 1.5) < 0.01, "a cold snap quickens hunger (%.3f)" % world.climate.metabolism_multiplier)
	a.equal(world.world_events.size(), 2, "both last a while")
	for _tick in range(int(manager.tick_rate * 1.5)):
		manager.step_once()
	a.is_true(world.world_events.is_empty(), "and then pass")
	a.equal(world.rng.state, state_before, "the weather draws nothing from the shared stream")
	Helpers.destroy_manager(manager)


func _test_newcomers(a) -> void:
	var manager = _world(9944)
	var world = manager.world_state
	for species in ["predator", "wolf", "herbivore"]:
		var seq: int = manager.enqueue_command("release", {"species": species})
		manager.step_once()
		var result := _result(world, seq)
		var arrived: Array = []
		for agent in world.get_living_agents():
			if agent.species_type == species:
				arrived.append(agent)
		var edge: Vector2 = result.get("position", Vector2.ZERO)
		var near_edge: bool = minf(minf(edge.x, world.bounds.end.x - edge.x), minf(edge.y, world.bounds.end.y - edge.y)) < 400.0
		a.is_true(bool(result.get("ok", false)) and arrived.size() == int(world.player.settings("release")["counts"][species]) and near_edge,
			"%s walk in from the edge (%d, at %s)" % [species, arrived.size(), str(edge)])
		if species == "predator":
			var registry = world.territory_registry("predator")
			a.is_true(arrived[0].preferred_mate_id == arrived[1].id and (registry == null or registry.territory_of(arrived[0].id) != -1),
				"the pair are mates, holding a free territory")
		if species != "predator":
			a.is_true(arrived[0].group_id >= 0 and arrived[0].group_id == arrived[arrived.size() - 1].group_id, "%s as one group" % species)
	Helpers.destroy_manager(manager)


func _test_kept_and_alike(a) -> void:
	var manager = _world(9945)
	var world = manager.world_state
	Helpers.spawn_herd(world, AT, 4, 0)
	manager.enqueue_command("adopt", {"viewer": "twitch:5", "name": "Звёздочка", "position": AT})
	manager.enqueue_command("bloom", {"seconds": 30.0})
	manager.step_once()
	var saved: Dictionary = world.export_state()
	var other = Helpers.create_manager_with(_bundle(9945), 9945)
	other.world_state.import_state(saved)
	a.equal([other.world_state.adoptions, other.world_state.world_events], [world.adoptions, world.world_events],
		"the wards and the weather come back with a save")
	Helpers.destroy_manager(other)
	Helpers.destroy_manager(manager)
	var inline = _world(9946)
	var threaded = _world(9946)
	threaded.enable_interactive_worker()
	threaded.begin_interactive_stepping()
	for manager_pair in [inline, threaded]:
		manager_pair.enqueue_command("release", {"species": "wolf"})
		manager_pair.enqueue_command("cold_snap", {})
	for _tick in range(30):
		inline.step_once()
		threaded._post_worker_job()
		threaded.synchronize_worker()
	a.equal("\n".join(Helpers.agent_state_lines(threaded.world_state)), "\n".join(Helpers.agent_state_lines(inline.world_state)),
		"the worker carries the orders out as an inline tick does")
	a.equal(threaded.rng.state, inline.rng.state, "drawing the stream alike")
	Helpers.destroy_manager(threaded)
	Helpers.destroy_manager(inline)


func _test_not_offered(a) -> void:
	var manager = Helpers.create_manager_with(Helpers.build_large_sector_bundle(9947), 9947)
	var seq: int = manager.enqueue_command("rain", {})
	manager.step_once()
	a.equal(str(_result(manager.world_state, seq).get("reason", "")), PlayerCommands.REFUSED_UNKNOWN,
		"a world that does not offer the reserve's powers refuses them")
	Helpers.destroy_manager(manager)
