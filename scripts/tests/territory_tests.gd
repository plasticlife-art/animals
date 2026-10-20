extends RefCounted

## Fox territories (`species.predator.territory`, `TerritoryRegistry`). The registry and the
## dens: dens apart and alike for a seed, placed with nothing drawn from the world's stream;
## the founding pairs on them; a slot taken, let go at a death and taken again; the territory
## a young one is born on; and the registry back with a save. The foxes on them: a holder
## patrols and hunts its own ground until hunger drives it out, and gives up a chase past its
## edge; mates are the two holding one territory, and vagrants do not breed; a young one of
## age makes for an open territory not its birthplace and takes it. Asleep the same: a pair
## sleeps as its territory's group and keeps to it, drawing nothing from the stream; only
## holders breed; and a vagrant of age settles where a slot is open. One that has looked for
## `emigrate_after_seconds` leaves the map, awake or asleep, with no body. Holders hunting asleep
## count by `dormant_kill_scale`. The feed tells, in view: a
## pair taking a territory, a young one setting out, a kill by a pair, a herd going back to its
## season's pasture - and not one fox taking a slot alone.

const Helpers := preload("res://scripts/tests/test_helpers.gd")
const ConfigLoaderScript := preload("res://scripts/core/config_loader.gd")
const SimulationManagerScript := preload("res://scripts/core/simulation_manager.gd")
const AgentBaseScript := preload("res://scripts/agents/agent_base.gd")
const StoryLogScript := preload("res://scripts/story/story_log.gd")
const TERRITORY := {"radius_cells": 10.0, "spacing": 1.8, "step_cells": 2, "water_cells": 6.0, "capacity_multiplier": 4.0}


func run(a) -> void:
	_test_dens_on_the_map(a)
	_test_slots(a)
	_test_births_and_saves(a)
	_test_a_holder_keeps_to_its_ground(a)
	_test_mates_hold_together(a)
	_test_a_young_one_finds_its_own(a)
	_test_a_sleeping_pair_keeps_to_its_ground(a)
	_test_only_holders_breed_asleep(a)
	_test_a_sleeping_vagrant_settles(a)
	_test_the_feed_tells_it(a)
	_test_a_vagrant_with_nowhere_leaves(a)
	_test_sleeping_holders_kill_by_the_scale(a)
	_test_dens_in_cover(a)


static func _shipped(seed: int, territory: bool):
	var bundle: Dictionary = ConfigLoaderScript.load_config_bundle().duplicate(true)
	if territory:
		bundle["species"]["predator"]["territory"] = TERRITORY.duplicate(true)
	var manager = SimulationManagerScript.new()
	manager.initialize(bundle, seed)
	return manager


func _test_dens_on_the_map(a) -> void:
	var plain = _shipped(41, false)
	var held = _shipped(41, true)
	var again = _shipped(41, true)
	var registry: TerritoryRegistry = held.world_state.territory_registry("predator")
	a.is_true(registry != null and registry.size() >= 16 and registry.size() <= 40,
		"a territory for about every pair the land can hold (%d)" % (0 if registry == null else registry.size()))
	var cell: float = held.world_state.resource_system.cell_size
	var closest := INF
	for first in registry.territories:
		for second in registry.territories:
			if int(first["id"]) < int(second["id"]):
				closest = minf(closest, Vector2(first["den"]).distance_to(second["den"]))
	a.is_true(closest >= 1.8 * 10.0 * cell - cell, "no den within 1.8 radii of another (%.0f)" % closest)
	var dens_again: Array = []
	for territory in again.world_state.territory_registry("predator").territories:
		dens_again.append(territory["den"])
	var dens: Array = []
	for territory in registry.territories:
		dens.append(territory["den"])
	a.equal(dens, dens_again, "the same dens for the same seed")
	a.equal(held.rng.state, plain.rng.state, "and the world's stream where it is without them")
	a.is_true(plain.world_state.territory_registry("predator") == null, "without the block, no territories")
	# Every founding pair on a den of its own, and the registry the foxes' mirror.
	var holders := 0
	var at_den := true
	for agent in held.world_state.get_living_agents():
		if agent.species_type != "predator":
			continue
		var territory_id: int = registry.territory_of(agent.id)
		if territory_id == -1:
			continue
		holders += 1
		if agent.position.distance_to(registry.get_territory(territory_id)["den"]) > 120.0:
			at_den = false
		if registry.partner_of(agent.id) != agent.preferred_mate_id:
			at_den = false
	var founders: int = int(held.world_state.config_bundle["world"]["spawns"]["predator_count"])
	a.equal(holders, mini(founders, registry.size() * 2), "the founding pairs hold the best dens")
	a.is_true(at_den, "each pair starts at its den, and its mate is its co-holder")
	for manager in [plain, held, again]:
		Helpers.destroy_manager(manager)


func _test_slots(a) -> void:
	var registry := TerritoryRegistry.new()
	registry.configure([Vector2(100.0, 100.0), Vector2(900.0, 100.0)], 300.0)
	a.is_true(registry.claim(0, 7, AgentBaseScript.SEX_MALE), "a free slot is taken")
	a.is_true(not registry.claim(0, 8, AgentBaseScript.SEX_MALE), "a taken one is not")
	a.is_true(registry.claim(0, 9, AgentBaseScript.SEX_FEMALE), "the other sex's is")
	a.equal(registry.partner_of(7), 9, "the two hold it together")
	a.equal(registry.census(), {"pairs": 1, "singles": 0, "vacant": 1}, "one held by a pair, one empty")
	a.equal(registry.open_slot_near(Vector2(120.0, 100.0), AgentBaseScript.SEX_MALE), 1,
		"a male looking for one is sent to the empty one, though the other is nearer")
	a.equal(registry.open_slot_near(Vector2(120.0, 100.0), AgentBaseScript.SEX_MALE, 1), -1,
		"and to none where it was born")
	a.equal(registry.held_at(Vector2(150.0, 150.0)), 0, "the ground near a held den is held")
	a.equal(registry.held_at(Vector2(900.0, 150.0)), -1, "an empty territory's is not")
	registry.release(7, 12.0)
	registry.release(9, 15.0)
	a.is_true(registry.is_vacant(0) and float(registry.get_territory(0)["vacant_since"]) == 15.0,
		"both gone, it is empty since the last left")
	a.is_true(registry.claim(0, 8, AgentBaseScript.SEX_MALE), "and taken again")
	var copy := TerritoryRegistry.new()
	copy.configure([Vector2.ZERO, Vector2.ZERO], 1.0)
	copy.import_state(registry.export_state())
	a.equal([copy.territories, copy.territory_of(8)], [registry.territories, 0], "a save brings it back")


func _test_births_and_saves(a) -> void:
	var bundle := Helpers.build_large_sector_bundle(9991)
	bundle["species"]["predator"]["territory"] = {"radius_cells": 4.0, "spacing": 1.8, "step_cells": 2,
		"water_cells": 30.0, "capacity_multiplier": 4.0}
	bundle["world"]["spawns"]["predator_count"] = 0
	var manager = Helpers.create_manager_with(bundle, 9991)
	manager.set_lod_enabled(false)
	var world = manager.world_state
	var registry: TerritoryRegistry = world.territory_registry("predator")
	a.is_true(registry.size() >= 2, "a small map has its few dens (%d)" % registry.size())
	var den: Vector2 = registry.get_territory(0)["den"]
	var male = Helpers.spawn_species(world, "predator", den, -1, AgentBaseScript.SEX_MALE)
	var female = Helpers.spawn_species(world, "predator", den + Vector2(20.0, 0.0), -1, AgentBaseScript.SEX_FEMALE)
	a.is_true(world.claim_territory(male, 0) and world.claim_territory(female, 0), "a pair takes a den")
	world.queue_spawn_agent("predator", den, -1, female, male)
	world._flush_spawns()
	var cub = world.get_agent(female.id + 1)
	a.equal(cub.natal_territory_id, 0, "a cub is born on its parents' territory")
	var saved: Dictionary = world.export_state()
	var other = Helpers.create_manager_with(bundle, 9991)
	other.world_state.import_state(saved)
	var back: TerritoryRegistry = other.world_state.territory_registry("predator")
	a.equal([back.territories, back.partner_of(male.id)], [registry.territories, female.id], "the registry comes back with a save")
	a.equal(other.world_state.get_agent(cub.id).natal_territory_id, 0, "and the cub's birthplace with it")
	world.kill_agent(female, "old_age")
	a.equal(registry.partner_of(male.id), -1, "a death lets its slot go")
	world.kill_agent(male, "old_age")
	a.is_true(registry.is_vacant(0), "and the last one's the territory")
	Helpers.destroy_manager(other)
	Helpers.destroy_manager(manager)


## A small map's world with territories `RADIUS_CELLS` cells across, no foxes but the test's.
const RADIUS_CELLS := 8.0


static func _small(seed: int, fed := false):
	var bundle := Helpers.build_large_sector_bundle(seed)
	if fed:
		# Never hungry nor thirsty: what is left is where it keeps to.
		bundle["species"]["predator"]["metabolism"]["hunger_rate"] = 0.0
		bundle["species"]["predator"]["metabolism"]["thirst_rate"] = 0.0
	bundle["species"]["predator"]["territory"] = {"radius_cells": RADIUS_CELLS, "spacing": 1.8, "step_cells": 2,
		"water_cells": 30.0, "capacity_multiplier": 4.0, "trespass_hunger": 70.0, "border_slack": 1.15,
		"dispersal_age_seconds": 240.0, "look_seconds": 2.0, "claim_radii": 0.5, "ring_radii": 0.7}
	bundle["world"]["spawns"]["predator_count"] = 0
	var manager = Helpers.create_manager_with(bundle, seed)
	manager.set_lod_enabled(false)
	return manager


static func _fox(world, at: Vector2, sex: String, age: float = 300.0):
	var fox = Helpers.spawn_species(world, "predator", at, -1, sex)
	fox.age = age
	return fox


func _test_a_holder_keeps_to_its_ground(a) -> void:
	var manager = _small(9992)
	var world = manager.world_state
	var registry: TerritoryRegistry = world.territory_registry("predator")
	var ground := registry.get_territory(0)
	var den: Vector2 = ground["den"]
	var radius: float = ground["radius"]
	var fox = _fox(world, den, AgentBaseScript.SEX_MALE)
	fox.hunger = 30.0
	world.claim_territory(fox, 0)
	var goal = fox._resolve_patrol_goal(world)
	a.is_true(goal != null and Vector2(goal).distance_to(den) <= radius * 1.15,
		"with no prey on its ground, it sweeps it round the den (%s)" % str(goal))
	# A deer past its edge, in sight: not for a fed holder, for a hungry one.
	var away := (Vector2(1536.0, 1536.0) - den).normalized()
	var deer = Helpers.spawn_herbivore(world, den + away * radius * 1.5, 0)
	fox.position = den + away * radius * 0.9
	Helpers._refresh_spatial_queries(world)
	a.equal(fox._choose_prey(world), null, "a fed holder lets prey past its edge be")
	fox.hunger = 80.0
	a.equal(fox._choose_prey(world), deer, "a hungry one does not")
	# Chasing it past the edge while fed: given up, for the border.
	fox.hunger = 40.0
	fox.target_agent_id = deer.id
	fox.state = "chase"
	fox._continue_or_finish_chase(world, manager.tick_duration)
	a.equal([fox.target_agent_id, int(manager.stats_system.counters.get("hunt_fail_border", 0))], [-1, 1],
		"and a chase past the edge is given up, for the border")
	Helpers.destroy_manager(manager)


func _test_mates_hold_together(a) -> void:
	var manager = _small(9993)
	var world = manager.world_state
	var registry: TerritoryRegistry = world.territory_registry("predator")
	var den: Vector2 = registry.get_territory(0)["den"]
	var holder = _fox(world, den, AgentBaseScript.SEX_MALE)
	world.claim_territory(holder, 0)
	var stranger = _fox(world, den + Vector2(30.0, 0.0), AgentBaseScript.SEX_FEMALE)
	var sister = _fox(world, den + Vector2(0.0, 30.0), AgentBaseScript.SEX_FEMALE)
	sister.natal_territory_id = 0
	var far_den: Vector2 = registry.get_territory(1)["den"]
	var vagrant_male = _fox(world, far_den, AgentBaseScript.SEX_MALE)
	var vagrant_female = _fox(world, far_den + Vector2(30.0, 0.0), AgentBaseScript.SEX_FEMALE)
	a.is_true(not vagrant_male._is_valid_mate_candidate(world, vagrant_female, false), "two with no territory are no mates")
	a.is_true(not holder._is_valid_mate_candidate(world, sister, false), "nor one born on the territory with its holder")
	a.is_true(holder._is_valid_mate_candidate(world, stranger, false), "a stranger and a holder with her slot open are")
	a.equal(holder._find_viable_mate(world, false, [stranger]), stranger, "she is chosen")
	a.equal([registry.territory_of(stranger.id), registry.partner_of(holder.id)], [0, stranger.id],
		"and takes her slot: the two hold it together")
	# Holding it together, they stay mates however far apart they range over it.
	stranger.position = den + Vector2(700.0, 0.0)
	a.equal(holder._get_preferred_mate(world), stranger, "far apart on their ground, still mates")
	world.config_bundle["balance"]["population_regulation"]["enabled"] = true
	world.config_bundle["world"]["spawns"]["predator_count"] = 10
	a.equal(world.get_reproductive_capacity("predator"), 40, "the cap a backstop, four times the start")
	world.config_bundle["balance"]["population_regulation"]["enabled"] = false
	world.config_bundle["world"]["spawns"]["predator_count"] = 0
	Helpers.destroy_manager(manager)


func _test_a_young_one_finds_its_own(a) -> void:
	var manager = _small(9994)
	var world = manager.world_state
	var registry: TerritoryRegistry = world.territory_registry("predator")
	var home: Vector2 = registry.get_territory(0)["den"]
	var cub = _fox(world, home, AgentBaseScript.SEX_FEMALE, 100.0)
	cub.natal_territory_id = 0
	cub._seek_ground(world)
	a.equal(cub._making_for, -1, "too young, it stays")
	a.equal(int(cub._home_ground(world).get("id", -1)), 0, "keeping to its birthplace, as it does asleep")
	cub.age = 250.0
	cub._seek_ground(world)
	var bound: int = cub._making_for
	a.is_true(bound != -1 and bound != 0, "of age, it makes for an open territory not its birthplace (%d)" % bound)
	cub._patrol(world, manager.tick_duration)
	a.equal(cub.state, "disperse", "looking for its own")
	cub.position = registry.get_territory(bound)["den"]
	cub._seek_ground(world)
	a.equal([registry.territory_of(cub.id), cub._making_for], [bound, -1], "there, it takes it")
	Helpers.destroy_manager(manager)


const STEP_SECONDS := 0.75


## Coarse steps as `_step_dormant_sectors()` spaces them (`DormantPositionTests`).
static func _coarse_steps(world, sector_key: Vector2i, steps: int, after_step: Callable = Callable()) -> void:
	for step in range(steps):
		world.current_tick += 9
		world.current_time += STEP_SECONDS
		world._prepare_navigation_budget()
		world._apply_dormant_sector_step(sector_key, world._sector_states[sector_key], STEP_SECONDS)
		if after_step.is_valid():
			after_step.call(step)


static func _records(world, sector_key: Vector2i) -> Dictionary:
	var by_id := {}
	for record in world._sector_states[sector_key].get("dormant_records", []):
		by_id[int(record["id"])] = record
	return by_id


func _test_a_sleeping_pair_keeps_to_its_ground(a) -> void:
	var manager = _small(9995, true)
	var world = manager.world_state
	var registry: TerritoryRegistry = world.territory_registry("predator")
	var ground := registry.get_territory(0)
	var den: Vector2 = ground["den"]
	var male = _fox(world, den, AgentBaseScript.SEX_MALE)
	var female = _fox(world, den + Vector2(30.0, 0.0), AgentBaseScript.SEX_FEMALE)
	for fox in [male, female]:
		world.claim_territory(fox, 0)
		fox.hunger = 0.0
		fox.thirst = 0.0
		fox.reproduction_cooldown = 9999.0
	male.set_preferred_mate_id(female.id)
	female.set_preferred_mate_id(male.id)
	var sector_key: Vector2i = world._get_sector_key(den)
	world._sleep_sector(sector_key)
	var keys: Array = []
	for aggregate in world._sector_states[sector_key].get("dormant_aggregates", []):
		keys.append(world._aggregate_key(aggregate))
	a.equal(keys, ["predator:-1:t0"], "the pair sleeps as its territory's group")
	var state_before: int = world.rng.state
	var farthest := [0.0]
	var pair_ids := [male.id, female.id]
	_coarse_steps(world, sector_key, 800, func(_step):
		for record in world._sector_states[sector_key].get("dormant_records", []):
			if pair_ids.has(int(record["id"])):
				farthest[0] = maxf(farthest[0], Vector2(record["position"]).distance_to(den)))
	var radius: float = ground["radius"]
	a.is_true(farthest[0] > 0.0 and farthest[0] <= radius * 1.2,
		"over 600 s asleep the pair keeps to its ground (farthest %.0f, radius %.0f)" % [farthest[0], radius])
	a.equal(world.rng.state, state_before, "drawing nothing from the shared stream")
	world._wake_sector(sector_key)
	a.equal([registry.territory_of(male.id), registry.partner_of(male.id)], [0, female.id],
		"awake again, the registry is as it was")
	Helpers.destroy_manager(manager)


func _test_only_holders_breed_asleep(a) -> void:
	var manager = _small(9996)
	var world = manager.world_state
	var registry: TerritoryRegistry = world.territory_registry("predator")
	var den: Vector2 = registry.get_territory(0)["den"]
	var holders := [_fox(world, den, AgentBaseScript.SEX_MALE), _fox(world, den + Vector2(30.0, 0.0), AgentBaseScript.SEX_FEMALE)]
	for fox in holders:
		world.claim_territory(fox, 0)
	var vagrants := [_fox(world, den + Vector2(0.0, 40.0), AgentBaseScript.SEX_MALE),
		_fox(world, den + Vector2(30.0, 40.0), AgentBaseScript.SEX_FEMALE)]
	for fox in holders + vagrants:
		fox.hunger = 0.0
		fox.thirst = 0.0
		fox.energy = 100.0
		fox.reproduction_cooldown = 0.0
	var sector_key: Vector2i = world._get_sector_key(den)
	world._sleep_sector(sector_key)
	var buckets: Dictionary = world._group_dormant_records(world._sector_states[sector_key]["dormant_records"])
	var births := {}
	for aggregate in world._sector_states[sector_key].get("dormant_aggregates", []):
		var key: String = world._aggregate_key(aggregate)
		births[key] = world._compute_dormant_births_for_aggregate(aggregate, STEP_SECONDS, buckets.get(key, []))
	a.is_true(int(births.get("predator:-1:t0", 0)) > 0, "the holders breed asleep (%s)" % str(births))
	a.equal(int(births.get("predator:-1", -1)), 0, "two vagrants do not")
	Helpers.destroy_manager(manager)


func _test_a_sleeping_vagrant_settles(a) -> void:
	var manager = _small(9997)
	var world = manager.world_state
	var registry: TerritoryRegistry = world.territory_registry("predator")
	var den: Vector2 = registry.get_territory(0)["den"]
	var vagrant = _fox(world, den + Vector2(20.0, 0.0), AgentBaseScript.SEX_FEMALE)
	vagrant.hunger = 0.0
	var young = _fox(world, den + Vector2(0.0, 20.0), AgentBaseScript.SEX_MALE, 50.0)
	var sector_key: Vector2i = world._get_sector_key(den)
	world._sleep_sector(sector_key)
	_coarse_steps(world, sector_key, 2)
	a.equal(registry.territory_of(vagrant.id), 0, "a vagrant of age asleep by an open den takes it")
	a.equal(registry.territory_of(young.id), -1, "one too young does not")
	var saved: Dictionary = world.export_state()
	var other = Helpers.create_manager_with(world.config_bundle, 9997)
	other.world_state.import_state(saved)
	a.equal(other.world_state.territory_registry("predator").territory_of(vagrant.id), 0, "and keeps it through a save")
	Helpers.destroy_manager(other)
	Helpers.destroy_manager(manager)


static func _event(type: String, agent_id: int, species: String, data: Dictionary) -> Dictionary:
	return {"type": type, "agent_id": agent_id, "species": species, "time_seconds": 10.0,
		"position": {"x": 100.0, "y": 100.0}, "data": data}


func _test_the_feed_tells_it(a) -> void:
	var log = StoryLogScript.new()
	log.context_provider = func() -> Dictionary: return {"view": Rect2(0.0, 0.0, 500.0, 500.0), "herd": ["herbivore", 2]}
	log.hear(_event("TerritoryClaimed", 5, "predator", {"territory_id": 0, "partner_id": -1}))
	a.equal(log.lines.size(), 0, "one fox taking a slot alone is not told")
	log.hear(_event("TerritoryClaimed", 5, "predator", {"territory_id": 0, "partner_id": 6}))
	a.is_true(log.lines.size() == 1 and str(log.lines[0]["text"]).ends_with("заняли участок"),
		"a pair taking it is (%s)" % str(log.lines[0]["text"] if not log.lines.is_empty() else ""))
	log.hear(_event("DispersalStarted", 7, "predator", {"territory_id": 3}))
	a.is_true(str(log.lines[0]["text"]).contains("искать свой участок"), "a young one setting out (%s)" % str(log.lines[0]["text"]))
	log.hear(_event("AgentDied", 8, "herbivore", {"cause": "predation", "group_id": 1, "age": 30.0, "pair": true}))
	a.is_true(str(log.lines[0]["text"]).begins_with("Пара лис загнала оленя"), "a kill by a pair (%s)" % str(log.lines[0]["text"]))
	log.hear(_event("HerdMigrates", -1, "herbivore", {"to_x": 900.0, "to_y": 900.0, "size": 9, "remembered": true,
		"season": "summer", "group_id": 2}))
	a.is_true(str(log.lines[0]["text"]).contains("идёт на летние угодья"), "a herd going back to its pasture (%s)" % str(log.lines[0]["text"]))


func _test_a_vagrant_with_nowhere_leaves(a) -> void:
	for asleep in [false, true]:
		var manager = _small(9998 + int(asleep), true)
		var world = manager.world_state
		world.config_bundle["species"]["predator"]["territory"]["emigrate_after_seconds"] = 10.0
		var registry: TerritoryRegistry = world.territory_registry("predator")
		# Every slot but the farthest den's taken: one to make for, and a crowd would make for it.
		var den: Vector2 = registry.get_territory(0)["den"]
		var farthest := 0
		for territory in registry.territories:
			if Vector2(territory["den"]).distance_to(den) > Vector2(registry.get_territory(farthest)["den"]).distance_to(den):
				farthest = int(territory["id"])
		for territory in registry.territories:
			if int(territory["id"]) != farthest:
				registry.claim(int(territory["id"]), 50000 + int(territory["id"]), AgentBaseScript.SEX_FEMALE)
		var vagrant = _fox(world, den, AgentBaseScript.SEX_FEMALE)
		vagrant.territory["emigrate_after_seconds"] = 10.0
		var carcasses: int = world.carcasses.size()
		if asleep:
			var sector_key: Vector2i = world._get_sector_key(den)
			world._sleep_sector(sector_key)
			_coarse_steps(world, sector_key, 20)
			a.is_true(not _records(world, sector_key).has(vagrant.id), "asleep, looking too long it leaves")
		else:
			for step in range(20):
				world.current_time += 1.0
				vagrant._seek_ground(world)
			a.is_true(not vagrant.is_alive, "looking too long, though one slot was open far off, it leaves the map")
		a.equal([int(manager.stats_system.counters.get("deaths_emigrated", 0)), world.carcasses.size()], [1, carcasses],
			"counted as gone, with no body%s" % (" (asleep)" if asleep else ""))
		Helpers.destroy_manager(manager)


## The kill debt a sleeping pair of holders runs up among deer, at `scale`, and the fear it leaves
## where the herd stands: `[debt, fear]`.
static func _sleeping_debt(scale: float) -> Array:
	var manager = _small(9990, true)
	var world = manager.world_state
	world.config_bundle["world"]["fear"] = {"enabled": true}
	world.fear_field.initialize(world.config_bundle["world"], world.resource_system.world_size, world.resource_system.cell_size)
	world.config_bundle["species"]["predator"]["territory"]["dormant_kill_scale"] = scale
	var registry: TerritoryRegistry = world.territory_registry("predator")
	var den: Vector2 = registry.get_territory(0)["den"]
	for sex in [AgentBaseScript.SEX_MALE, AgentBaseScript.SEX_FEMALE]:
		var fox = _fox(world, den, sex)
		world.claim_territory(fox, 0)
		fox.hunger = 60.0
	Helpers.spawn_herd(world, den + Vector2(60.0, 0.0), 6, 0)
	var sector_key: Vector2i = world._get_sector_key(den)
	world._sleep_sector(sector_key)
	var state: Dictionary = world._sector_states[sector_key]
	for aggregate in state["dormant_aggregates"]:
		if str(aggregate["species_type"]) == "predator":
			aggregate["goal_kind"] = "hunt"
	var herd_at := den + Vector2(60.0, 0.0)
	var before: float = world.fear_field.risk_at(herd_at)
	world._resolve_dormant_predation(sector_key, state, state["dormant_aggregates"], 0.5,
		world._group_dormant_records(state["dormant_records"]))
	var result := [float(state.get("dormant_kill_debt", 0.0)), world.fear_field.risk_at(herd_at) - before]
	Helpers.destroy_manager(manager)
	return result


func _test_sleeping_holders_kill_by_the_scale(a) -> void:
	var full := _sleeping_debt(1.0)
	var half := _sleeping_debt(0.5)
	a.is_true(full[0] > 0.0 and absf(half[0] - full[0] * 0.5) < full[0] * 0.01,
		"holders asleep run up half the kill debt at half the scale (%.5f against %.5f)" % [half[0], full[0]])
	a.is_true(full[1] > 0.0 and half[1] < full[1] * 0.75,
		"and leave less fear on the herd's ground (%.4f against %.4f)" % [half[1], full[1]])


func _test_dens_in_cover(a) -> void:
	# A 40 x 20 map, grass everywhere, a wood on its right half; water all over.
	var cols := 40
	var rows := 20
	var caps := PackedFloat32Array()
	var walkable := PackedByteArray()
	var cover := PackedFloat32Array()
	for index in range(cols * rows):
		caps.append(100.0 if index % cols < 20 else 60.0)
		walkable.append(1)
		cover.append(1.0 if index % cols >= 20 else 0.0)
	var water := [{"position": Vector2(640.0, 320.0), "radius": 2000.0}]
	var config := {"radius_cells": 4.0, "spacing": 1.8, "step_cells": 2, "water_cells": 30.0}
	var by_grass: Array = TerritoryRegistry.place_dens(caps, walkable, cols, rows, 32.0, water, config, 7, cover)
	config["den_score"] = "cover"
	var by_cover: Array = TerritoryRegistry.place_dens(caps, walkable, cols, rows, 32.0, water, config, 7, cover)
	a.is_true(Vector2(by_grass[0]).x < 20.0 * 32.0, "by grass the best den is on the meadow")
	a.is_true(Vector2(by_cover[0]).x >= 20.0 * 32.0, "by cover it is in the wood")
