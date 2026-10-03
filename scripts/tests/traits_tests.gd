extends RefCounted

## Heritable traits: what a founder and a young one inherit, what each trait does to the animal
## and what it costs, sleeping births with both parents, selection asleep, the means the stats
## and the cards show, the chronicle's history, and saves from before there were any.

const Helpers := preload("res://scripts/tests/test_helpers.gd")
const TraitsScript := preload("res://scripts/agents/traits.gd")
const SaveSystemScript := preload("res://scripts/core/save_system.gd")
const TraitHistoryScript := preload("res://scripts/story/trait_history.gd")
const StoryBookScript := preload("res://scripts/story/story_book.gd")
const FamilyTreeScript := preload("res://scripts/story/family_tree.gd")
const HerdReadoutScript := preload("res://scripts/ui/herd_readout.gd")
const SelectionCardScript := preload("res://scripts/ui/selection_card.gd")


## Level ground everywhere, so a run measures the animal and not the cells it crosses.
class FlatGround:
	extends RefCounted

	func get_move_cost_at_position(_position: Vector2) -> float:
		return 1.0

	func resolve_movement_position(_from: Vector2, to: Vector2, _radius: float) -> Vector2:
		return to


func run(a) -> void:
	_test_hash_is_stable_and_even(a)
	_test_founders_spread_within_reach(a)
	_test_young_take_the_parents_mean(a)
	_test_clamps_hold_at_the_edges(a)
	_test_traits_move_the_animal(a)
	_test_traits_cost_hunger_and_runs(a)
	_test_longevity_moves_every_age(a)
	_test_neutral_traits_change_nothing(a)
	_test_heredity_off_keeps_the_world(a)
	_test_awake_birth_inherits(a)
	_test_sleeping_birth_names_both_parents(a)
	_test_selection_asleep_leans_on_traits(a)
	_test_sleepers_pay_for_their_traits(a)
	_test_appetite_fills_up_faster(a)
	_test_means_reach_the_stats(a)
	_test_records_keep_traits_through_sleep_and_save(a)
	_test_v2_save_reads_as_v3(a)
	_test_trait_history_keeps_the_whole_life(a)
	_test_trait_words(a)
	_test_cards_and_tree_show_traits(a)


func _settings(overrides: Dictionary = {}) -> Dictionary:
	var block := {"enabled": true}
	block.merge(overrides, true)
	return {"traits": block}


## A test world whose species inherit, with `overrides` on every species' `traits` block.
func _heredity_bundle(seed: int, overrides: Dictionary = {}) -> Dictionary:
	var bundle: Dictionary = Helpers.build_test_bundle(seed)
	for species_id in bundle["species"].keys():
		var block := {"enabled": true}
		block.merge(overrides, true)
		bundle["species"][species_id]["traits"] = block
	return bundle


func _test_hash_is_stable_and_even(a) -> void:
	a.equal(TraitsScript.unit(12345, 7), TraitsScript.unit(12345, 7), "the same id and salt give the same draw")
	var total := 0.0
	var low := 1.0
	var high := 0.0
	var differ := 0
	for value in range(4000):
		var draw: float = TraitsScript.unit(value, 3)
		total += draw
		low = minf(low, draw)
		high = maxf(high, draw)
		if TraitsScript.unit(value, 3) != TraitsScript.unit(value, 4):
			differ += 1
	a.is_true(low >= 0.0 and high < 1.0, "draws stay in [0, 1): %.4f..%.4f" % [low, high])
	a.near(total / 4000.0, 0.5, 0.02, "draws are even on average")
	a.is_true(differ > 3990, "another salt draws differently (%d of 4000)" % differ)


func _test_founders_spread_within_reach(a) -> void:
	var config := _settings({"founder_spread": 0.08})
	var outside := 0
	var sums := [0.0, 0.0, 0.0, 0.0]
	for agent_id in range(1, 1001):
		var values: Array = TraitsScript.founder(agent_id, config)
		for index in range(4):
			sums[index] += float(values[index])
			if absf(float(values[index]) - 1.0) > 0.08 + 0.000001:
				outside += 1
	a.equal(outside, 0, "every founder is within the spread of the species")
	for index in range(4):
		a.near(float(sums[index]) / 1000.0, 1.0, 0.01, "founders centre on the species (%s)" % TraitsScript.NAMES[index])
	a.equal(TraitsScript.founder(77, config), TraitsScript.founder(77, config), "a founder's traits come from its id")
	a.is_true(TraitsScript.founder(77, config, 1) != TraitsScript.founder(77, config, 2),
		"and its world: two worlds' founders are not the same animals")


func _test_young_take_the_parents_mean(a) -> void:
	var config := _settings({"mutation": 0.04})
	var mother := [1.10, 0.90, 1.00, 1.04]
	var father := [1.20, 1.00, 0.96, 1.00]
	var mean := [1.15, 0.95, 0.98, 1.02]
	var sums := [0.0, 0.0, 0.0, 0.0]
	var outside := 0
	for child_id in range(100, 1100):
		var values: Array = TraitsScript.inherit(child_id, mother, father, config)
		for index in range(4):
			sums[index] += float(values[index])
			if absf(float(values[index]) - float(mean[index])) > 0.04 + 0.000001:
				outside += 1
	a.equal(outside, 0, "a young one is within the mutation of its parents' mean")
	for index in range(4):
		a.near(float(sums[index]) / 1000.0, float(mean[index]), 0.006, "the young centre on the parents' mean")
	a.equal(TraitsScript.inherit(5, mother, [], config), TraitsScript.inherit(5, mother, mother, config),
		"a missing parent counts as the other")
	a.equal(TraitsScript.inherit(5, [], [], config), TraitsScript.inherit(5, TraitsScript.NEUTRAL, TraitsScript.NEUTRAL, config),
		"with neither, the species")
	var still: Array = TraitsScript.inherit(9, mother, father, _settings({"mutation": 0.0}))
	for index in range(4):
		a.equal(float(still[index]), float(mean[index]), "no mutation, the exact mean")


func _test_clamps_hold_at_the_edges(a) -> void:
	var config := _settings({"clamp": 0.25, "longevity_clamp": 0.10, "mutation": 0.04})
	var top := 0.0
	var bottom := 2.0
	var long_top := 0.0
	for child_id in range(200):
		var up: Array = TraitsScript.inherit(child_id, [1.3, 1.3, 1.3, 1.3], [1.3, 1.3, 1.3, 1.3], config)
		var down: Array = TraitsScript.inherit(child_id, [0.6, 0.6, 0.6, 0.85], [0.6, 0.6, 0.6, 0.85], config)
		top = maxf(top, maxf(float(up[0]), maxf(float(up[1]), float(up[2]))))
		bottom = minf(bottom, minf(float(down[0]), minf(float(down[1]), float(down[2]))))
		long_top = maxf(long_top, float(up[3]))
		a.is_true(float(down[3]) >= 0.9 - 0.000001, "longevity holds its lower clamp")
	a.near(top, 1.25, 0.000001, "speed, sight and appetite stop at +25 %")
	a.near(bottom, 0.75, 0.000001, "and at -25 %")
	a.near(long_top, 1.10, 0.000001, "longevity stops at +10 %")


func _test_traits_move_the_animal(a) -> void:
	var manager = Helpers.create_manager(9101)
	var world = manager.world_state
	var plain = Helpers.spawn_herbivore(world, Vector2(40.0, 70.0), 1)
	var quick = Helpers.spawn_herbivore(world, Vector2(40.0, 170.0), 2)
	quick.set_traits([1.2, 1.15, 1.0, 1.0])
	for agent in [plain, quick]:
		agent.energy = 100.0
		agent.velocity = Vector2.ZERO
		agent.direction = Vector2.RIGHT
	var ground := FlatGround.new()
	for _step in range(24):
		plain.move_with_vector(ground, Vector2.RIGHT, 50.0, manager.tick_duration)
		quick.move_with_vector(ground, Vector2.RIGHT, 50.0, manager.tick_duration)
	a.near(quick.velocity.length() / maxf(0.001, plain.velocity.length()), 1.2, 0.02,
		"a fast animal moves a fifth faster: %.2f against %.2f" % [quick.velocity.length(), plain.velocity.length()])
	var seen_plain: float = world.perception_radius(plain, "vision_radius", 100.0)
	var seen_quick: float = world.perception_radius(quick, "vision_radius", 100.0)
	a.near(seen_quick / seen_plain, 1.15, 0.0001, "a far-sighted one sees further by its trait")
	Helpers.destroy_manager(manager)


func _test_traits_cost_hunger_and_runs(a) -> void:
	var manager = Helpers.create_manager(9102)
	var world = manager.world_state
	var plain = Helpers.spawn_herbivore(world, Vector2(60.0, 60.0), 1)
	var costly = Helpers.spawn_herbivore(world, Vector2(160.0, 160.0), 2)
	costly.set_traits([1.2, 1.1, 1.05, 1.0])
	for agent in [plain, costly]:
		agent.hunger = 0.0
		agent.update_needs(1.0)
	# appetite x (1 + 0.5 x speed gain + 0.3 x sight gain), the shipped defaults
	a.near(costly.hunger / plain.hunger, 1.05 * (1.0 + 0.5 * 0.2 + 0.3 * 0.1), 0.0001,
		"speed, sight and appetite all make it hungrier")
	a.near(costly.trait_run_cost, 1.44, 0.0001, "a run costs the square of its speed")
	var slow = Helpers.spawn_herbivore(world, Vector2(100.0, 200.0), 3)
	slow.set_traits([1.0, 1.0, 0.8, 1.0])
	for agent in [plain, slow]:
		agent.energy = 10.0
		agent.state = "rest"
		agent.update_needs(1.0)
	a.near((slow.energy - 10.0) / (plain.energy - 10.0), 1.0, 0.0001,
		"rest is the species' whatever the appetite: breeding needs a rested animal too")
	Helpers.destroy_manager(manager)


func _test_longevity_moves_every_age(a) -> void:
	var manager = Helpers.create_manager(9103)
	var world = manager.world_state
	var elder = Helpers.spawn_herbivore(world, Vector2(60.0, 60.0), 1)
	elder.set_traits([1.0, 1.0, 1.0, 1.1])
	var maturity := float(elder.reproduction.get("maturity_age", 0.0))
	elder.age = maturity * 1.05
	a.equal(elder.get_age_stage(), "young", "a long life grows up later")
	elder.age = maturity * 1.11
	a.equal(elder.get_age_stage(), "adult", "but grows up")
	var max_age := float(elder.aging.get("max_age", 1000.0))
	elder.hunger = 0.0
	elder.thirst = 0.0
	elder.age = max_age * 1.05
	a.is_true(not elder.apply_survival_checks(world, 0.000001) and elder.is_alive, "a long life outlives the species' max age")
	var short = Helpers.spawn_herbivore(world, Vector2(160.0, 160.0), 2)
	short.set_traits([1.0, 1.0, 1.0, 0.9])
	short.hunger = 0.0
	short.thirst = 0.0
	short.age = max_age * 0.95
	a.is_true(short.apply_survival_checks(world, 0.000001), "a short one dies before it")
	Helpers.destroy_manager(manager)


## The hooks multiply by the traits; at 1.0 every one of them is exact, so a world whose animals
## all inherit 1.0 - heredity on, no spread, no mutation - plays as a world without heredity.
func _test_neutral_traits_change_nothing(a) -> void:
	var bundle := Helpers.build_test_bundle(9104)
	for species_id in bundle["species"].keys():
		bundle["species"][species_id].erase("traits")
	var plain := _run_small_world(bundle, 9104)
	var neutral := _run_small_world(_heredity_bundle(9104, {"founder_spread": 0.0, "mutation": 0.0}), 9104)
	var varied := _run_small_world(_heredity_bundle(9104), 9104)
	a.equal(neutral, plain, "heredity at 1.0 plays exactly as none")
	a.is_true(varied != plain, "spread founders play differently")


## Shipped heredity switched off by config is the world from before it existed - the
## identity runs check this at scale; here, that founders are then all the species.
func _test_heredity_off_keeps_the_world(a) -> void:
	var manager = Helpers.create_manager_with(Helpers.build_test_bundle(9105), 9105)
	var founder = manager.world_state.spawn_agent("herbivore", Vector2(80.0, 80.0), 0, "female", {"reason": "initial"})
	a.equal(founder.traits(), TraitsScript.NEUTRAL, "without heredity a founder is the species")
	Helpers.destroy_manager(manager)
	manager = Helpers.create_manager_with(_heredity_bundle(9105), 9105)
	founder = manager.world_state.spawn_agent("herbivore", Vector2(80.0, 80.0), 0, "female", {"reason": "initial"})
	a.is_true(founder.traits() != TraitsScript.NEUTRAL, "with it, a founder differs")
	var tested = manager.world_state.spawn_agent("herbivore", Vector2(90.0, 80.0), 0, "female", {"reason": "test"})
	a.equal(tested.traits(), TraitsScript.NEUTRAL, "an animal placed by hand is the species")
	Helpers.destroy_manager(manager)


func _run_small_world(bundle: Dictionary, seed: int) -> String:
	var manager = Helpers.create_manager_with(bundle, seed)
	var world = manager.world_state
	for index in range(10):
		var animal = world.spawn_agent("herbivore", Vector2(40.0 + float(index % 5) * 40.0, 60.0 + floorf(index / 5.0) * 40.0),
			0, "female" if index % 2 == 0 else "male", {"reason": "initial"})
		animal.age = 120.0
		animal.reproduction_cooldown = 0.0
	for index in range(2):
		var hunter = world.spawn_agent("predator", Vector2(60.0 + float(index) * 120.0, 210.0), -1,
			"male" if index == 0 else "female", {"reason": "initial"})
		hunter.age = 60.0
		hunter.hunger = 60.0
	Helpers._refresh_spatial_queries(world)
	Helpers.run_ticks(manager, 360)
	var fingerprint: String = Helpers.world_fingerprint(manager)
	Helpers.destroy_manager(manager)
	return fingerprint


func _test_awake_birth_inherits(a) -> void:
	var manager = Helpers.create_manager_with(_heredity_bundle(9106, {"mutation": 0.04}), 9106)
	var world = manager.world_state
	var mother = Helpers.spawn_herbivore(world, Vector2(100.0, 100.0), 0)
	var father = Helpers.spawn_herbivore(world, Vector2(110.0, 100.0), 0)
	mother.set_traits([1.2, 1.0, 1.0, 1.0])
	father.set_traits([1.0, 1.2, 1.0, 1.0])
	var heard: Array = []
	manager.world_event.connect(func(event: Dictionary) -> void:
		if str(event.get("type", "")) == "AgentBorn":
			heard.append(event))
	world.queue_spawn_agent("herbivore", Vector2(105.0, 100.0), 0, mother, father)
	# A parent may die before the spawn is made: the traits were copied when it was queued.
	mother.set_traits(TraitsScript.NEUTRAL)
	world._flush_spawns()
	a.equal(heard.size(), 1, "the birth is heard")
	var child_id := int(heard[0].get("agent_id", -1)) if not heard.is_empty() else -1
	var child = world.get_agent(child_id)
	a.is_true(child != null, "the young one is in the world")
	if child != null:
		a.near(child.trait_speed, 1.1, 0.0401, "its speed is its parents' mean, give or take a mutation")
		a.near(child.trait_vision, 1.1, 0.0401, "and so is its sight")
		a.equal(heard[0].get("data", {}).get("traits", []), child.traits(), "the birth says what it inherited")
	Helpers.destroy_manager(manager)


func _test_sleeping_birth_names_both_parents(a) -> void:
	var bundle := _heredity_bundle(9107, {"mutation": 0.04})
	var manager = Helpers.create_manager_with(bundle, 9107)
	var world = manager.world_state
	var female = Helpers.spawn_species(world, "predator", Vector2(100, 100), -1, AgentBase.SEX_FEMALE)
	var mate = Helpers.spawn_species(world, "predator", Vector2(120, 100), -1, AgentBase.SEX_MALE)
	female.set_preferred_mate_id(mate.id)
	mate.set_preferred_mate_id(female.id)
	female.set_traits([1.2, 1.0, 1.0, 1.05])
	mate.set_traits([1.0, 1.2, 1.0, 0.95])
	var records := [_ready_record(female, AgentBase.SEX_FEMALE), _ready_record(mate, AgentBase.SEX_MALE)]
	var aggregate: Dictionary = world._build_dormant_aggregates(records, Vector2i.ZERO)[0]
	a.near(float(aggregate["avg_traits"][0]), 1.1, 0.0001, "a sleeping group knows its mean speed")
	a.equal(world._compute_dormant_births_for_aggregate(aggregate, 1.0, records), 1, "the pair breeds asleep")
	var cooldown := float(female.reproduction.get("cooldown", 0.0))
	a.near(float(records[0]["reproduction_cooldown"]), cooldown * 1.05, 0.0001, "a long life waits longer for the next young")
	a.near(float(records[1]["reproduction_cooldown"]), cooldown * 0.95, 0.0001, "a short one less")
	var heard: Array = []
	manager.world_event.connect(func(event: Dictionary) -> void:
		if str(event.get("type", "")) == "AgentBorn":
			heard.append(event))
	var sector_state := {"dormant_records": records, "dormant_aggregates": [aggregate]}
	world._reconcile_dormant_records(Vector2i.ZERO, sector_state, 0.75)
	a.equal(heard.size(), 1, "the sleeping birth is heard")
	var data: Dictionary = heard[0].get("data", {}) if not heard.is_empty() else {}
	a.equal(int(data.get("mother_id", -1)), female.id, "it names the mother")
	a.equal(int(data.get("father_id", -1)), mate.id, "and the father")
	var newborn: Dictionary = {}
	for record in sector_state["dormant_records"]:
		if int(record.get("id", -1)) == int(data.get("record_id", -2)):
			newborn = record
	a.is_true(not newborn.is_empty(), "the young one sleeps with them")
	var traits: Array = TraitsScript.of_record(newborn)
	a.near(float(traits[0]), 1.1, 0.0401, "its speed is between its parents'")
	a.near(float(traits[1]), 1.1, 0.0401, "and its sight")
	a.equal(data.get("traits", []), traits, "the birth says what it inherited")
	Helpers.destroy_manager(manager)


func _ready_record(agent, sex: String) -> Dictionary:
	agent.age = float(agent.reproduction.get("maturity_age", 0.0)) * 1.2 + 6.0
	agent.sex = sex
	agent.energy = float(agent.reproduction.get("energy_threshold", 0.0)) + 20.0
	agent.hunger = 0.0
	agent.thirst = 0.0
	agent.reproduction_cooldown = 0.0
	return agent.export_runtime_state()


func _test_selection_asleep_leans_on_traits(a) -> void:
	var manager = Helpers.create_manager(9108)
	var world = manager.world_state
	var near := Vector2(100.0, 100.0)
	var quick := {"id": 1, "position": Vector2(120.0, 100.0), "traits": [1.15, 1.1, 1.0, 1.0], "hunger": 80.0, "age": 500.0}
	var slow := {"id": 2, "position": Vector2(124.0, 100.0), "traits": [0.85, 0.9, 1.0, 1.0], "hunger": 80.0, "age": 500.0}
	a.equal(world._pick_dormant_victim([quick, slow], "predation", {"near": near}), 1,
		"hunters catch the slow, short-sighted one though it stood a little further")
	var plain := {"id": 3, "position": Vector2(120.0, 100.0), "hunger": 80.0, "age": 500.0}
	var plain_far := {"id": 4, "position": Vector2(124.0, 100.0), "hunger": 80.0, "age": 500.0}
	a.equal(world._pick_dormant_victim([plain, plain_far], "predation", {"near": near}), 0,
		"without traits the nearest, as before")
	var hungry := {"id": 5, "hunger": 80.0, "traits": [1.0, 1.0, 1.2, 1.0]}
	var thrifty := {"id": 6, "hunger": 85.0, "traits": [1.0, 1.0, 0.9, 1.0]}
	a.equal(world._pick_dormant_victim([thrifty, hungry], "starvation", {}), 0,
		"hunger starves the hungriest: what traits cost is already in the hunger")
	var short := {"id": 7, "age": 950.0, "traits": [1.0, 1.0, 1.0, 0.9]}
	var long := {"id": 8, "age": 1000.0, "traits": [1.0, 1.0, 1.0, 1.1]}
	a.equal(world._pick_dormant_victim([long, short], "old_age", {}), 1, "a short life ends first")
	Helpers.destroy_manager(manager)


## Asleep, a group's step is one number for each need; its members share it by what they
## inherited, and the group's mean still moves by the step.
func _test_sleepers_pay_for_their_traits(a) -> void:
	var manager = Helpers.create_manager_with(_heredity_bundle(9113), 9113)
	var world = manager.world_state
	var records := [{"id": 1, "hunger": 10.0, "traits": [1.0, 1.0, 1.0, 1.0]},
		{"id": 2, "hunger": 10.0, "traits": [1.2, 1.0, 1.0, 1.0]},
		{"id": 3, "hunger": 10.0, "traits": [1.0, 1.0, 0.8, 1.0]}]
	var weigh: Callable = world._dormant_trait_weigh("herbivore", "hunger", 3.0)
	a.is_true(weigh.is_valid(), "hunger rising is shared by cost")
	world._share_dormant_need_shift(records, "hunger", 3.0, 0.0, 100.0, weigh)
	var total := 0.0
	for record in records:
		total += float(record["hunger"])
	a.near(total, 39.0, 0.0001, "the group's mean moves by the step")
	a.is_true(float(records[1]["hunger"]) > float(records[0]["hunger"]) and float(records[0]["hunger"]) > float(records[2]["hunger"]),
		"the fast one hungers most, the slow metabolism least: %s" % str(records.map(func(r): return snappedf(r["hunger"], 0.01))))
	a.near(float(records[1]["hunger"]) - 10.0, 3.0 * 1.1 / ((1.0 + 1.1 + 0.8) / 3.0), 0.0001, "each by its own factor")
	var capped := [{"id": 1, "hunger": 99.0, "traits": [1.2, 1.0, 1.0, 1.0]}, {"id": 2, "hunger": 10.0}]
	world._share_dormant_need_shift(capped, "hunger", 2.0, 0.0, 100.0, world._dormant_trait_weigh("herbivore", "hunger", 2.0))
	a.near(float(capped[0]["hunger"]) + float(capped[1]["hunger"]), 113.0, 0.0001, "what a full one cannot take, the rest do")
	a.is_true(not world._dormant_trait_weigh("herbivore", "hunger", -2.0).is_valid(), "a grazer eats by its own bites, not a share")
	var meal: Callable = world._dormant_trait_weigh("predator", "hunger", -4.0)
	a.near(float(meal.call({"traits": [1.1, 1.2, 1.0, 1.0]})), 1.32, 0.0001, "a hunter's meal goes by speed and sight")
	a.near(float(meal.call({"traits": [1.0, 1.0, 1.2, 1.0]})), 1.2, 0.0001, "and feeds a quick metabolism more")
	a.is_true(not world._dormant_trait_weigh("scavenger", "energy", 5.0).is_valid(), "strength is shared evenly")
	var plain := [{"id": 1, "hunger": 10.0}, {"id": 2, "hunger": 20.0}]
	world._share_dormant_need_shift(plain, "hunger", 3.0, 0.0, 100.0)
	a.equal([plain[0]["hunger"], plain[1]["hunger"]], [13.0, 23.0], "without weights, even shares as before")
	Helpers.destroy_manager(manager)
	var off = Helpers.create_manager(9113)
	a.is_true(not off.world_state._dormant_trait_weigh("herbivore", "hunger", 3.0).is_valid(), "no heredity, even shares")
	Helpers.destroy_manager(off)


## Appetite pays back in food, not strength: the same grass feeds a quick metabolism more, and
## gives both the same strength.
func _test_appetite_fills_up_faster(a) -> void:
	var manager = Helpers.create_manager_with(_heredity_bundle(9114), 9114)
	var world = manager.world_state
	var species_config: Dictionary = world.config_bundle["species"]["herbivore"]
	var quick := {"id": 1, "position": Vector2(120.0, 40.0), "hunger": 60.0, "energy": 50.0, "traits": [1.0, 1.0, 1.2, 1.0]}
	var slow := {"id": 2, "position": Vector2(40.0, 120.0), "hunger": 60.0, "energy": 50.0, "traits": [1.0, 1.0, 0.8, 1.0]}
	world._graze_dormant_members({"species_type": "herbivore", "center": Vector2(80.0, 80.0)}, [quick, slow],
		species_config["feeding"], species_config, 1.0)
	var fed_quick := 60.0 - float(quick["hunger"])
	var fed_slow := 60.0 - float(slow["hunger"])
	a.is_true(fed_slow > 0.0, "both graze asleep (%.2f, %.2f)" % [fed_quick, fed_slow])
	a.near(fed_quick / maxf(0.0001, fed_slow), 1.5, 0.0001, "the same bite feeds a quick metabolism more")
	a.near(float(quick["energy"]), float(slow["energy"]), 0.0001, "and gives both the same strength")
	a.near(WorldState.grazing_bite(species_config["feeding"], 3.0, 1.0, 1.5),
		WorldState.grazing_bite(species_config["feeding"], 3.0) / 1.5, 0.0001, "a nearly full one takes no more than it can use")
	Helpers.destroy_manager(manager)


func _test_means_reach_the_stats(a) -> void:
	var manager = Helpers.create_manager_with(_heredity_bundle(9109), 9109)
	var world = manager.world_state
	var first = Helpers.spawn_herbivore(world, Vector2(60.0, 60.0), 0)
	var second = Helpers.spawn_herbivore(world, Vector2(80.0, 60.0), 0)
	first.set_traits([1.2, 1.0, 0.9, 1.0])
	second.set_traits([1.0, 1.1, 0.9, 1.04])
	var metrics: Dictionary = world.get_population_metrics()
	a.near(float(metrics.get("herbivore_trait_speed_sum", 0.0)), 2.2, 0.0001, "the awake are summed")
	manager.stats_system.refresh_snapshot(world, manager.current_tick, manager.simulation_time)
	var snapshot: Dictionary = manager.stats_system.get_snapshot_view()
	a.near(float(snapshot.get("trait_speed_herbivore", 0.0)), 1.1, 0.0001, "the snapshot holds the mean")
	a.near(float(snapshot.get("trait_longevity_herbivore", 0.0)), 1.02, 0.0001, "for every trait")
	a.equal(float(snapshot.get("trait_speed_predator", 0.0)), 1.0, "a species with nobody reads the species")
	var summary: Dictionary = HerdReadoutScript.summarize(world, "herbivore", 0)
	a.near(float(summary["traits"][1]), 1.05, 0.0001, "the herd card's means")
	a.equal(HerdReadoutScript.traits_tooltip(summary), "Черты в среднем\nСкорость +10 % · Зрение +5 %\nАппетит −10 % · Долголетие +2 %",
		"on the head count's tooltip")
	Helpers.destroy_manager(manager)


func _test_records_keep_traits_through_sleep_and_save(a) -> void:
	var manager = Helpers.create_manager_with(_heredity_bundle(9110), 9110)
	var world = manager.world_state
	var animal = Helpers.spawn_herbivore(world, Vector2(60.0, 60.0), 0)
	animal.set_traits([1.13, 0.94, 1.02, 1.05])
	var record: Dictionary = animal.export_runtime_state()
	var woken = world._create_agent("herbivore")
	woken.configure(animal.id, "herbivore", animal.position, animal.sex, world.config_bundle["species"]["herbivore"],
		world.config_bundle["balance"], RandomNumberGenerator.new(), 0)
	woken.apply_runtime_state(record)
	a.equal(woken.traits(), animal.traits(), "a record wakes with its traits")
	a.near(woken.trait_hunger, animal.trait_hunger, 0.000001, "and their cost")
	var old: Dictionary = record.duplicate()
	old.erase("traits")
	var older = world._create_agent("herbivore")
	older.configure(animal.id, "herbivore", animal.position, animal.sex, world.config_bundle["species"]["herbivore"],
		world.config_bundle["balance"], RandomNumberGenerator.new(), 0)
	older.apply_runtime_state(old)
	a.equal(older.traits(), TraitsScript.NEUTRAL, "a record from before traits is the species")
	var path := "user://traits_round_trip.dat"
	a.is_true(SaveSystemScript.save(manager, {}, path), "a world with traits saves")
	var restored = Helpers.create_manager_with(_heredity_bundle(9110), 9110)
	a.is_true(SaveSystemScript.restore(restored, SaveSystemScript.read(path)), "and loads")
	var back = restored.world_state.get_agent(animal.id)
	a.is_true(back != null and back.traits() == animal.traits(), "with each animal's traits")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	Helpers.destroy_manager(restored)
	Helpers.destroy_manager(manager)


func _test_v2_save_reads_as_v3(a) -> void:
	var manager = Helpers.create_manager(9111)
	Helpers.spawn_herbivore(manager.world_state, Vector2(60.0, 60.0), 0)
	var path := "user://traits_v2.dat"
	a.is_true(SaveSystemScript.save(manager, {}, path), "fixture save writes")
	var data: Dictionary = SaveSystemScript.read(path)
	data["version"] = 2
	for species_id in data["config_bundle"]["species"].keys():
		data["config_bundle"]["species"][species_id].erase("traits")
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_var(data, true)
	file.close()
	var migrated: Dictionary = SaveSystemScript.read(path)
	a.equal(int(migrated.get("version", 0)), SaveSystemScript.SAVE_VERSION, "a v2 save reads as the current version")
	var restored = Helpers.create_manager(9111)
	a.is_true(SaveSystemScript.restore(restored, migrated), "and loads")
	a.is_true(not TraitsScript.enabled(restored.config_bundle["species"]["herbivore"]),
		"with its own bundle, which has no heredity")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	Helpers.destroy_manager(restored)
	Helpers.destroy_manager(manager)


func _test_trait_history_keeps_the_whole_life(a) -> void:
	var history = TraitHistoryScript.new()
	var metrics := {"herbivore_population": 10, "trait_speed_herbivore": 1.0, "trait_vision_herbivore": 1.0,
		"trait_appetite_herbivore": 1.0, "trait_longevity_herbivore": 1.0, "predator_population": 0}
	var time := 0.0
	while time < 60000.0:
		metrics["trait_speed_herbivore"] = 1.0 + time / 600000.0
		history.sample(time, metrics, ["herbivore", "predator"])
		time += 7.0
	a.is_true(history.points.size() <= TraitHistoryScript.MAX_POINTS, "it fits (%d points)" % history.points.size())
	a.is_true(history.points.size() > TraitHistoryScript.MAX_POINTS / 3, "and keeps enough to draw")
	a.near(float(history.points[0]["time"]), 0.0, 0.001, "from the beginning")
	a.is_true(float(history.points[-1]["time"]) > 60000.0 - history.interval * 2.0, "to now")
	a.is_true(not history.points[-1]["values"].has("predator"), "a species with nobody is left out")
	a.near(float(history.latest("herbivore")[0]), 1.1, 0.002, "the latest mean")
	a.near(history.span(0), 0.1 * 1.15, 0.003, "the chart reaches the furthest point")
	a.near(history.span(1), TraitHistoryScript.MIN_SPAN, 0.000001, "and never less than its least")
	var copy = TraitHistoryScript.new()
	copy.import_state(history.export_state())
	a.equal(copy.points.size(), history.points.size(), "it is saved with the story")
	a.equal(copy.interval, history.interval, "with its pace")


func _test_trait_words(a) -> void:
	a.equal(HudText.percent_change(1.06), "+6 %", "a gain")
	a.equal(HudText.percent_change(0.97), "−3 %", "a loss, with a real minus")
	a.equal(HudText.percent_change(1.004), "0 %", "nothing to speak of")
	a.equal(HudText.traits_text([1.06, 0.97, 1.02, 1.04]),
		"Скорость +6 % · Зрение −3 %\nАппетит +2 % · Долголетие +4 %", "the card's two lines")
	a.equal(HudText.traits_brief([1.03, 1.0, 0.99, 0.95]), "Черты: долголетие −5 %, скорость +3 %",
		"a group's two that stand out most")
	a.equal(HudText.traits_brief([1.001, 0.998, 1.0, 1.0]), "Черты: как у вида", "or none")


func _test_cards_and_tree_show_traits(a) -> void:
	var manager = Helpers.create_manager_with(_heredity_bundle(9112), 9112)
	var world = manager.world_state
	var animal = world.spawn_agent("herbivore", Vector2(60.0, 60.0), 0, "female", {"reason": "initial"})
	a.equal(SelectionCardScript.traits_line(animal), HudText.traits_brief(animal.traits()), "the card shows its traits")
	a.is_true(SelectionCardScript.traits_tooltip(animal).begins_with(HudText.traits_text(animal.traits())),
		"all four in the tooltip")
	var book = StoryBookScript.new()
	book.bind(manager)
	book.begin()
	a.equal(book.heredity_species.size(), 3, "every shipped species inherits")
	var card: Dictionary = FamilyTreeScript.card(book, animal.id, 0.0)
	# Kept in single precision, as the family tree stores them.
	a.equal(str(card.get("traits", "")), HudText.traits_text(Array(PackedFloat32Array(animal.traits()))),
		"the family tree knows them too")
	Helpers.destroy_manager(manager)
	manager = Helpers.create_manager(9112)
	var plain = Helpers.spawn_herbivore(manager.world_state, Vector2(60.0, 60.0), 0)
	a.equal(SelectionCardScript.traits_line(plain), "", "without heredity the card says nothing of it")
	Helpers.destroy_manager(manager)
