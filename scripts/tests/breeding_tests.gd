extends RefCounted

## The breeding season and litters (`Breeding`): the curve over the year, who may breed on its
## ramps, how many young a pair has, the same answers awake and asleep, litters against the
## cap, and a world without a season playing exactly as before.

const Helpers := preload("res://scripts/tests/test_helpers.gd")
const BreedingScript := preload("res://scripts/agents/breeding.gd")
const ClimateScript := preload("res://scripts/world/climate.gd")
const ConfigLoaderScript := preload("res://scripts/core/config_loader.gd")

const CURVE := [[0.0, 1.0], [0.6, 1.0], [1.5, 0.0], [3.75, 0.0]]


func run(a) -> void:
	_test_curve_over_the_year(a)
	_test_spring_starts_open(a)
	_test_females_open_over_the_ramps(a)
	_test_litter_sizes(a)
	_test_no_season_plays_as_before(a)
	_test_autumn_is_barren_and_spring_has_twins(a)
	_test_out_of_season_predator_keeps_its_meal_and_mate(a)
	_test_fox_litter_and_its_kin(a)
	_test_litters_against_the_cap(a)
	_test_sleeping_litters(a)
	_test_sleeping_and_awake_agree(a)


## A world whose clock runs, starting in `season` (0 spring .. 3 winter), with every species
## breeding by season and the litters given.
func _seasonal_bundle(seed: int, season: int, litters := {"herbivore": [2.0, 2], "predator": [3.0, 4],
		"scavenger": [4.0, 6]}) -> Dictionary:
	var bundle: Dictionary = Helpers.build_test_bundle(seed)
	var climate: Dictionary = ConfigLoaderScript.load_config_bundle()["world"]["climate"].duplicate(true)
	climate["enabled"] = true
	climate["start_season_index"] = season
	bundle["world"]["climate"] = climate
	for species_id in litters.keys():
		bundle["species"][species_id]["breeding"] = {"enabled": true, "litter_mean": float(litters[species_id][0]),
			"litter_max": int(litters[species_id][1])}
	return bundle


func _test_curve_over_the_year(a) -> void:
	a.equal(BreedingScript.curve_value(CURVE, 0.0), 1.0, "open at the start of spring")
	a.equal(BreedingScript.curve_value(CURVE, 0.6), 1.0, "and through the first half of it")
	a.near(BreedingScript.curve_value(CURVE, 1.05), 0.5, 0.0001, "closing through early summer")
	a.equal(BreedingScript.curve_value(CURVE, 1.5), 0.0, "shut by midsummer")
	a.equal(BreedingScript.curve_value(CURVE, 2.5), 0.0, "autumn has no young")
	a.equal(BreedingScript.curve_value(CURVE, 3.5), 0.0, "nor early winter")
	a.near(BreedingScript.curve_value(CURVE, 3.875), 0.5, 0.0001, "opening at the end of winter")
	a.near(BreedingScript.curve_value(CURVE, 3.9999), 1.0, 0.001, "nearly open as spring comes")
	a.equal(BreedingScript.curve_value(CURVE, 4.3), BreedingScript.curve_value(CURVE, 0.3), "the year wraps")
	var jump := 0.0
	var previous := BreedingScript.curve_value(CURVE, 0.0)
	for step in range(1, 801):
		var value := BreedingScript.curve_value(CURVE, float(step) * 0.005)
		jump = maxf(jump, absf(value - previous))
		previous = value
	a.is_true(jump < 0.03, "no jump anywhere in the year (%.4f)" % jump)


func _test_spring_starts_open(a) -> void:
	var climate: Dictionary = ConfigLoaderScript.load_config_bundle()["world"]["climate"]
	var at_start: Dictionary = ClimateScript.evaluate(climate, 0.0)
	a.equal(float(at_start["season_position"]), 0.0, "t=0 is the first instant of spring")
	a.equal(BreedingScript.curve_value(climate["breeding_curve"], float(at_start["season_position"])), 1.0,
		"so a new world breeds as it always did")
	var later: Dictionary = ClimateScript.evaluate(climate, 300.0)
	a.near(float(later["season_position"]), 2.5, 0.0001, "300 s in is halfway through autumn")


func _test_females_open_over_the_ramps(a) -> void:
	var open := 0
	var males_open := 0
	for female_id in range(1, 2001):
		if BreedingScript.fertile(female_id, "female", 0.3, 2, 99):
			open += 1
		if BreedingScript.fertile(female_id, "male", 0.3, 2, 99):
			males_open += 1
	a.near(float(open) / 2000.0, 0.3, 0.03, "a third of the females on a third of the curve")
	a.equal(males_open, 2000, "every male while the curve is open at all")
	a.is_true(not BreedingScript.fertile(5, "male", 0.0, 2, 99), "nobody when it is shut")
	a.is_true(BreedingScript.fertile(5, "female", 1.0, 2, 99), "everybody when it is wide open")
	a.equal(BreedingScript.fertile(17, "female", 0.5, 3, 99), BreedingScript.fertile(17, "female", 0.5, 3, 99),
		"a female's draw is hers")
	var same := 0
	for female_id in range(1, 401):
		if BreedingScript.fertile(female_id, "female", 0.5, 3, 99) == BreedingScript.fertile(female_id, "female", 0.5, 4, 99):
			same += 1
	a.is_true(same < 300, "and new each year, so the same does are not always last (%d of 400 alike)" % same)


func _test_litter_sizes(a) -> void:
	a.equal(BreedingScript.litter(10, 11, 1, 2.0, 2, 7), 2, "twins")
	a.equal(BreedingScript.litter(10, 11, 1, 3.0, 4, 7), 3, "a litter of three")
	a.equal(BreedingScript.litter(10, 11, 1, 1.0, 1, 7), 1, "one young without a litter")
	a.equal(BreedingScript.litter(10, 11, 1, 5.0, 4, 7), 4, "never past the most")
	a.equal(BreedingScript.litter(31, 12, 2, 2.5, 4, 7), BreedingScript.litter(12, 31, 2, 2.5, 4, 7),
		"whichever parent asks")
	var total := 0
	for pair in range(400):
		total += BreedingScript.litter(pair * 2, pair * 2 + 1, 1, 2.5, 4, 7)
	a.near(float(total) / 400.0, 2.5, 0.08, "a fraction is a chance of one more")


## Off - the block missing, switched off, or the climate stopped - a world plays as it always
## has; on through the open plateau of spring with one young a time, it plays the same too.
func _test_no_season_plays_as_before(a) -> void:
	var plain := Helpers.build_test_bundle(9201)
	for species_id in plain["species"].keys():
		plain["species"][species_id].erase("breeding")
	var reference := _run_small_world(plain, 9201)
	var disabled := Helpers.build_test_bundle(9201)
	a.equal(_run_small_world(disabled, 9201), reference, "a season switched off is no season")
	var no_clock := _seasonal_bundle(9201, 0)
	no_clock["world"]["climate"] = {"enabled": false}
	a.equal(_run_small_world(no_clock, 9201), reference, "and so is one without a clock")
	var spring_plain := _seasonal_bundle(9201, 0, {})
	var spring_single := _seasonal_bundle(9201, 0, {"herbivore": [1.0, 1], "predator": [1.0, 1], "scavenger": [1.0, 1]})
	a.equal(_run_small_world(spring_single, 9201), _run_small_world(spring_plain, 9201),
		"open spring with single young is the world without a season")
	var spring_twins := _seasonal_bundle(9201, 0)
	a.is_true(_run_small_world(spring_twins, 9201) != _run_small_world(spring_plain, 9201), "twins change it")


func _run_small_world(bundle: Dictionary, seed: int) -> String:
	var manager = Helpers.create_manager_with(bundle, seed)
	var world = manager.world_state
	for index in range(10):
		var animal = world.spawn_agent("herbivore", Vector2(40.0 + float(index % 5) * 40.0, 60.0 + floorf(index / 5.0) * 40.0),
			0, "female" if index % 2 == 0 else "male", {"reason": "initial"})
		animal.age = 120.0
		animal.reproduction_cooldown = 0.0
		animal.energy = 90.0
		animal.hunger = 0.0
		animal.thirst = 0.0
	Helpers._refresh_spatial_queries(world)
	Helpers.run_ticks(manager, 240)
	var fingerprint: String = Helpers.world_fingerprint(manager)
	Helpers.destroy_manager(manager)
	return fingerprint


## Two deer ready to breed, side by side.
func _ready_pair(world, species: String, where: Vector2) -> Array:
	var female = Helpers.spawn_species(world, species, where, 3 if species != "predator" else -1, "female")
	var male = Helpers.spawn_species(world, species, where + Vector2(6.0, 0.0), 3 if species != "predator" else -1, "male")
	for animal in [female, male]:
		animal.age = float(animal.reproduction.get("maturity_age", 0.0)) + 30.0
		animal.reproduction_cooldown = 0.0
		animal.energy = float(animal.metabolism.get("max_energy", 100.0))
		animal.hunger = 0.0
		animal.thirst = 0.0
	Helpers._refresh_spatial_queries(world)
	return [female, male]


func _test_autumn_is_barren_and_spring_has_twins(a) -> void:
	var manager = Helpers.create_manager_with(_seasonal_bundle(9202, 2), 9202)
	var world = manager.world_state
	var pair := _ready_pair(world, "herbivore", Vector2(120.0, 120.0))
	a.equal(world.breeding_value("herbivore"), 0.0, "autumn has no breeding season")
	a.is_true(pair[0].can_reproduce() and not world.can_breed(pair[0]), "a ready doe does not breed in autumn")
	a.is_true(not world.can_breed(pair[1]), "nor a ready stag")
	Helpers.destroy_manager(manager)
	manager = Helpers.create_manager_with(_seasonal_bundle(9202, 0), 9202)
	world = manager.world_state
	pair = _ready_pair(world, "herbivore", Vector2(120.0, 120.0))
	var first = pair[0] if pair[0].id < pair[1].id else pair[1]
	var heard: Array = []
	manager.world_event.connect(func(event: Dictionary) -> void:
		if str(event.get("type", "")) == "AgentReproduced":
			heard.append(event))
	a.is_true(first._attempt_reproduce(world, manager.tick_duration, [], []), "in spring the pair mates")
	a.equal(world.pending_spawns.size(), 2, "and has twins")
	world._flush_spawns()
	a.equal(heard.size(), 2, "both born, both to the pair")
	var pair_ids := [pair[0].id, pair[1].id]
	pair_ids.sort()
	for event in heard:
		var data: Dictionary = event.get("data", {})
		var parents := [int(data.get("parent_a_id", -1)), int(data.get("parent_b_id", -1))]
		parents.sort()
		a.equal(parents, pair_ids, "each young names both parents")
	a.near(first.reproduction_cooldown, float(first.reproduction.get("cooldown", 0.0)) * first.trait_longevity, 0.0001,
		"one mating, one wait")
	Helpers.destroy_manager(manager)


func _test_out_of_season_predator_keeps_its_meal_and_mate(a) -> void:
	var manager = Helpers.create_manager_with(_seasonal_bundle(9203, 2), 9203)
	var world = manager.world_state
	var pair := _ready_pair(world, "predator", Vector2(120.0, 120.0))
	var vixen = pair[0]
	var carcass_id: int = Helpers.spawn_carcass(world, Vector2(140.0, 120.0))
	vixen.target_carcass_id = carcass_id
	vixen.preferred_mate_id = -1
	a.is_true(not vixen._attempt_reproduce(world, manager.tick_duration), "no mating in autumn")
	a.equal(vixen.target_carcass_id, carcass_id, "so it does not leave its carcass for a mate")
	a.equal(vixen.preferred_mate_id, -1, "nor bond on the way")
	Helpers.destroy_manager(manager)


func _test_fox_litter_and_its_kin(a) -> void:
	var manager = Helpers.create_manager_with(_seasonal_bundle(9204, 0), 9204)
	var world = manager.world_state
	var pair := _ready_pair(world, "predator", Vector2(120.0, 120.0))
	var first = pair[0] if pair[0].id < pair[1].id else pair[1]
	a.is_true(first._attempt_reproduce(world, manager.tick_duration), "a spring pair mates")
	a.equal(world.pending_spawns.size(), 3, "and has three cubs")
	var before: Array = first.kin_ids.duplicate()
	world._flush_spawns()
	var cubs: Array = []
	for agent in world.get_living_agents():
		if agent.id != pair[0].id and agent.id != pair[1].id:
			cubs.append(agent)
	a.equal(cubs.size(), 3, "three in the world")
	for cub in cubs:
		a.is_true(cub.kin_ids.has(pair[0].id) and cub.kin_ids.has(pair[1].id), "each cub knows both parents")
	a.equal(first.kin_ids.size() - before.size(), 1, "a parent keeps the first cub as kin, not the whole litter")
	Helpers.destroy_manager(manager)


## Room for three deer: the cap counts from three founders.
func _capped_bundle() -> Dictionary:
	var bundle := _seasonal_bundle(9205, 0)
	bundle["balance"]["population_regulation"] = {"enabled": true, "capacity_multipliers": {"herbivore": 1.0}}
	bundle["world"]["spawns"]["herbivore_count"] = 3
	return bundle


func _test_litters_against_the_cap(a) -> void:
	var manager = Helpers.create_manager_with(_capped_bundle(), 9205)
	var world = manager.world_state
	# The cap counts from three founders; take them away, so the pair leaves room for one young.
	for founder in world.get_living_agents().duplicate():
		world.kill_agent(founder, "test")
	world._flush_removals()
	world._reproduction_population_counts.clear()
	var pair := _ready_pair(world, "herbivore", Vector2(120.0, 120.0))
	var first = pair[0] if pair[0].id < pair[1].id else pair[1]
	a.equal(world.get_reproductive_capacity("herbivore"), 3, "room for three deer")
	a.is_true(first._attempt_reproduce(world, manager.tick_duration, [], []), "the pair still mates")
	a.equal(world.pending_spawns.size(), 1, "but has one of its twins: the cap has room for one")
	Helpers.destroy_manager(manager)
	manager = Helpers.create_manager_with(_capped_bundle(), 9205)
	world = manager.world_state
	a.equal(world.get_reproductive_capacity("herbivore"), 3, "the same room asleep")
	var records: Array = []
	for index in range(4):
		var animal = Helpers.spawn_species(world, "herbivore", Vector2(100.0 + float(index) * 5.0, 100.0), 4,
			"female" if index % 2 == 0 else "male")
		records.append(_ready_record(animal))
	for animal in world.get_living_agents().duplicate():
		world.kill_agent(animal, "test")
	world._flush_removals()
	world._reproduction_population_counts.clear()
	world._reproduction_population_counts["herbivore"] = 2
	var aggregate: Dictionary = world._build_dormant_aggregates(records, Vector2i.ZERO)[0]
	a.equal(world._compute_dormant_births_for_aggregate(aggregate, 1.0, records), 1,
		"asleep, the cap's one place goes to the first pair's litter")
	var waited := 0
	for record in records:
		if float(record.get("reproduction_cooldown", 0.0)) > 0.0:
			waited += 1
	a.equal(waited, 2, "and the pair the cap left nothing for does not breed at all")
	Helpers.destroy_manager(manager)


func _ready_record(agent) -> Dictionary:
	agent.age = float(agent.reproduction.get("maturity_age", 0.0)) * 1.2 + 6.0
	agent.energy = float(agent.metabolism.get("max_energy", 100.0))
	agent.hunger = 0.0
	agent.thirst = 0.0
	agent.reproduction_cooldown = 0.0
	return agent.export_runtime_state()


func _test_sleeping_litters(a) -> void:
	var manager = Helpers.create_manager_with(_seasonal_bundle(9206, 0), 9206)
	var world = manager.world_state
	var pair := _ready_pair(world, "predator", Vector2(100.0, 100.0))
	pair[0].set_preferred_mate_id(pair[1].id)
	pair[1].set_preferred_mate_id(pair[0].id)
	var records := [_ready_record(pair[0]), _ready_record(pair[1])]
	var aggregate: Dictionary = world._build_dormant_aggregates(records, Vector2i.ZERO)[0]
	var rng_before: int = world.rng.state
	a.equal(world._compute_dormant_births_for_aggregate(aggregate, 1.0, records), 3, "a sleeping vixen has three cubs")
	var heard: Array = []
	manager.world_event.connect(func(event: Dictionary) -> void:
		if str(event.get("type", "")) == "AgentBorn":
			heard.append(event))
	var sector_state := {"dormant_records": records, "dormant_aggregates": [aggregate]}
	world._reconcile_dormant_records(Vector2i.ZERO, sector_state, 0.75)
	a.equal(sector_state["dormant_records"].size(), 5, "three records join the pair")
	a.equal(heard.size(), 3, "three births heard")
	for event in heard:
		var data: Dictionary = event.get("data", {})
		a.is_true(int(data.get("mother_id", -1)) == pair[0].id and int(data.get("father_id", -1)) == pair[1].id,
			"each with both parents")
	a.equal(world.rng.state, rng_before, "and nothing drawn from the shared stream")
	Helpers.destroy_manager(manager)


## The tally and the births asleep and the checks awake give the same answer for the same
## animals, in and out of season.
func _test_sleeping_and_awake_agree(a) -> void:
	for season in [0, 1, 2, 3]:
		var manager = Helpers.create_manager_with(_seasonal_bundle(9207, season), 9207)
		var world = manager.world_state
		var config: Dictionary = world.config_bundle["species"]["scavenger"]["reproduction"]
		var disagreements := 0
		var fertile := 0
		for index in range(24):
			var animal = Helpers.spawn_species(world, "scavenger", Vector2(40.0 + float(index) * 8.0, 200.0), 5,
				"female" if index % 3 != 0 else "male")
			var record := _ready_record(animal)
			var awake: bool = world.can_breed(animal)
			if awake != world._dormant_record_can_breed(record, config, "scavenger"):
				disagreements += 1
			if awake:
				fertile += 1
		a.equal(disagreements, 0, "awake and asleep agree in season %d" % season)
		if season == 2:
			a.equal(fertile, 0, "nobody breeds in autumn")
			var records: Array = []
			for animal in world.get_living_agents():
				records.append(animal.export_runtime_state())
			var tally: Dictionary = world._build_dormant_aggregates(records, Vector2i.ZERO)[0]
			a.equal(int(tally.get("ready_females", 0)) + int(tally.get("ready_males", 0)), 0,
				"and a sleeping group counts nobody ready")
		if season == 0:
			a.equal(fertile, 24, "everybody in spring")
		Helpers.destroy_manager(manager)
