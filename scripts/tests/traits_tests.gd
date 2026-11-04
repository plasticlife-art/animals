extends RefCounted

## Heritable traits: what a founder and a young one inherit, what each trait does to the animal
## and what it costs, sleeping births with both parents, selection asleep, the means the stats
## and the cards show, the chronicle's history and what it concludes, the marker that does
## nothing, and saves from before there were any.

const Helpers := preload("res://scripts/tests/test_helpers.gd")
const TraitsScript := preload("res://scripts/agents/traits.gd")
const SaveSystemScript := preload("res://scripts/core/save_system.gd")
const TraitHistoryScript := preload("res://scripts/story/trait_history.gd")
const StoryBookScript := preload("res://scripts/story/story_book.gd")
const FamilyTreeScript := preload("res://scripts/story/family_tree.gd")
const HerdReadoutScript := preload("res://scripts/ui/herd_readout.gd")
const SelectionCardScript := preload("res://scripts/ui/selection_card.gd")
const TraitInsightsScript := preload("res://scripts/story/trait_insights.gd")
const LineageScript := preload("res://scripts/story/lineage.gd")
const TraitsViewScript := preload("res://scripts/ui/traits_view.gd")
const InsightsViewScript := preload("res://scripts/ui/insights_view.gd")


## Level ground everywhere, so a run measures the animal and not the cells it crosses.
class FlatGround:
	extends RefCounted

	## A clock with no weather: pace as it is.
	var climate := preload("res://scripts/world/climate.gd").new()

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
	_test_marker_does_nothing(a)
	_test_history_tallies_who_left_a_trace(a)
	_test_history_spread_and_founders(a)
	_test_insights_tell_selection_from_chance(a)
	_test_insights_jump_bottleneck_race(a)
	_test_traits_screen_and_conclusions(a)
	_test_newer_traits_only_where_listed(a)
	_test_caution_drought_size_give_and_cost(a)
	_test_sleepers_pay_for_the_newer_traits(a)


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
	a.equal(book.heredity_species.size(), world.species_registry.ids().size(), "every shipped species inherits")
	var card: Dictionary = FamilyTreeScript.card(book, animal.id, 0.0)
	# Kept in single precision, as the family tree stores them.
	a.equal(str(card.get("traits", "")), HudText.traits_text(Array(PackedFloat32Array(animal.traits()))),
		"the family tree knows them too")
	Helpers.destroy_manager(manager)
	manager = Helpers.create_manager(9112)
	var plain = Helpers.spawn_herbivore(manager.world_state, Vector2(60.0, 60.0), 0)
	a.equal(SelectionCardScript.traits_line(plain), "", "without heredity the card says nothing of it")
	Helpers.destroy_manager(manager)


func _test_marker_does_nothing(a) -> void:
	var config := {"traits": {"enabled": true}}
	var founder := TraitsScript.founder(4242, config, 77)
	a.equal(founder.size(), TraitsScript.NAMES.size(), "a founder has every trait, the marker too")
	for index in range(TraitsScript.MARKER):
		# The first four are drawn as they were before the marker: a world plays as it did.
		var expected := clampf(1.0 + 0.08 * (TraitsScript.unit(4242, TraitsScript.SALTS[index], 77) * 2.0 - 1.0),
			0.9 if index == TraitsScript.LONGEVITY else 0.75, 1.1 if index == TraitsScript.LONGEVITY else 1.25)
		a.near(float(founder[index]), expected, 0.000001, "%s is the draw it always was" % TraitsScript.NAMES[index])
	a.is_true(absf(float(founder[TraitsScript.MARKER]) - 1.0) <= 0.08, "the marker spreads like the others")
	var marked: Array = TraitsScript.NEUTRAL.duplicate()
	marked[TraitsScript.MARKER] = 1.2
	var settings := TraitsScript.settings(config)
	a.near(TraitsScript.hunger_factor(marked, settings), 1.0, 0.000001, "the marker costs no hunger")
	a.near(TraitsScript.run_cost_factor(marked, settings), 1.0, 0.000001, "nor any run")
	a.equal(TraitsScript.padded([1.1, 0.9, 1.0, 1.05]), [1.1, 0.9, 1.0, 1.05, 1.0, 1.0, 1.0, 1.0],
		"an old animal's four take the newer traits as the species")
	a.equal(TraitsScript.of_record({"traits": [1.1, 0.9, 1.0, 1.05]})[TraitsScript.SPEED], 1.1,
		"an old record keeps its speed")
	var young := TraitsScript.inherit(9, [1.1, 1.1, 1.1, 1.05], [1.1, 1.1, 1.1, 1.05], config, 3)
	a.is_true(absf(float(young[TraitsScript.SPEED]) - 1.1) <= 0.04 + 0.000001,
		"a young one of old parents inherits their speed, not the species'")
	a.equal(HudText.traits_text([1.06, 0.97, 1.02, 1.04, 1.3]),
		"Скорость +6 % · Зрение −3 %\nАппетит +2 % · Долголетие +4 %", "the cards leave the marker out")
	var lineage = LineageScript.new()
	lineage.note_animal(1, "herbivore", "female")
	lineage.note_animal(2, "herbivore", "male")
	lineage.note_traits(1, [1.0, 1.0, 1.0, 1.0])
	lineage.note_traits(2, TraitsScript.NEUTRAL)
	a.is_true(lineage.entry(1).has("traits") and lineage.entry(2).has("traits"), "the family tree keeps four or five")


## A family tree stand-in: the living with their traits.
func _family(living: Array, species := "herbivore"):
	var lineage = LineageScript.new()
	for index in range(living.size()):
		lineage.note_animal(index + 1, species, "female")
		lineage.note_traits(index + 1, living[index])
	return lineage


func _test_history_tallies_who_left_a_trace(a) -> void:
	var history = TraitHistoryScript.new()
	var metrics := {"herbivore_population": 10, "trait_speed_herbivore": 1.0, "trait_vision_herbivore": 1.0,
		"trait_appetite_herbivore": 1.0, "trait_longevity_herbivore": 1.0, "trait_marker_herbivore": 1.0}
	history.sample(0.0, metrics, ["herbivore"])
	history.hear_birth("herbivore", [[1.10, 1.0, 1.0, 1.0, 1.0], [1.06, 1.0, 1.0, 1.0, 1.0]])
	history.hear_death("herbivore", "predation", [0.90, 1.0, 1.0, 1.0, 1.0])
	history.hear_death("herbivore", "predation", [0.94, 1.0, 1.0, 1.0])
	history.hear_death("herbivore", "", [0.5, 1.0, 1.0, 1.0, 1.0])
	metrics["trait_speed_herbivore"] = 1.02
	history.sample(40.0, metrics, ["herbivore"])
	var parents: Dictionary = history.differential("herbivore", "parents", TraitsScript.SPEED)
	a.equal(int(parents["count"]), 2, "each parent counted once")
	a.near(float(parents["diff"]), 0.06, 0.0001, "parents 8 %% ahead of the living's 2 %%: %s" % str(parents))
	var hunted: Dictionary = history.differential("herbivore", "predation", TraitsScript.SPEED)
	a.equal(int(hunted["count"]), 2, "an old animal of four counts too; a death of no cause does not")
	a.near(float(hunted["diff"]), -0.10, 0.0001, "the hunted 8 %% behind the species, 10 behind the living")
	a.equal(int(history.differential("herbivore", "parents", TraitsScript.SPEED, 40.0)["count"]), 0,
		"nothing after the last point")
	# Folded, not lost, when the history thins out.
	var long = TraitHistoryScript.new()
	var time := 0.0
	var told := 0
	while long.points.size() < TraitHistoryScript.MAX_POINTS or long.interval <= TraitHistoryScript.START_INTERVAL:
		long.hear_death("herbivore", "old_age", [1.0, 1.0, 1.0, 1.0, 1.0])
		told += 1
		long.sample(time, metrics, ["herbivore"])
		time += long.interval
	long.sample(time, metrics, ["herbivore"])
	var counted: int = int(long.differential("herbivore", "old_age", 0)["count"]) + int(long._pending.get("herbivore", {}).get("old_age", [0, 0])[-1])
	a.equal(counted, told, "thinned out, the history keeps every death it heard (%d of %d)" % [counted, told])
	var copy = TraitHistoryScript.new()
	copy.import_state(long.export_state())
	a.equal(int(copy.differential("herbivore", "old_age", 0)["count"]), int(long.differential("herbivore", "old_age", 0)["count"]),
		"the tallies are saved with the story")


func _test_history_spread_and_founders(a) -> void:
	var history = TraitHistoryScript.new()
	var metrics := {"herbivore_population": 4, "trait_speed_herbivore": 1.0, "trait_vision_herbivore": 1.0,
		"trait_appetite_herbivore": 1.0, "trait_longevity_herbivore": 1.0, "trait_marker_herbivore": 1.0}
	var family = _family([[0.9, 1.0, 1.0, 1.0, 1.0], [1.1, 1.0, 1.0, 1.0, 1.0], [0.9, 1.0, 1.0, 1.0, 1.0],
		[1.1, 1.0, 1.0, 1.0]])
	family.note_animal(9, "herbivore", "male")
	family.note_traits(9, [2.0, 2.0, 2.0, 2.0, 2.0])
	family.note_death(9, 1.0, "predation", -1, Vector2.ZERO)
	history.sample(0.0, metrics, ["herbivore"], family)
	var spread: Array = history.latest_spread("herbivore")
	a.near(float(spread[TraitsScript.SPEED]), 0.1, 0.0001, "speed spread among the living, the dead left out")
	a.near(float(spread[TraitsScript.VISION]), 0.0, 0.0001, "none where they are alike")
	a.near(float(spread[TraitsScript.MARKER]), 0.0, 0.0001, "the marker of three, the old one standing for none")
	var founders: Array = history.founders["herbivore"]
	a.equal(int(founders[TraitsScript.SPEED][TraitHistoryScript.bin_of(0.9)]), 2, "the founders' histogram")
	a.equal(TraitHistoryScript.bin_of(1.0), TraitHistoryScript.BINS / 2, "the species in the middle bucket")
	a.equal(TraitHistoryScript.bin_of(5.0), TraitHistoryScript.BINS - 1, "beyond the reach at the edge")
	history.sample(60.0, metrics, ["herbivore"], _family([[1.0, 1.0, 1.0, 1.0, 1.0]]))
	a.equal(int(history.founders["herbivore"][TraitsScript.SPEED][TraitHistoryScript.bin_of(0.9)]), 2,
		"the founders are kept from the first point")
	a.is_true(history.points[0].has("counts") and int(history.points[0]["counts"]["herbivore"]) == 4, "and the numbers")


## A made-up history: `years` of points, each species' means moving by `drift` (per trait over the
## whole time), with spreads, numbers and tallies as given per species.
func _made_history(points: int, species: Dictionary):
	var history = TraitHistoryScript.new()
	for step in range(points):
		var share := float(step) / float(points - 1)
		var values := {}
		var spread := {}
		var counts := {}
		var tallies := {}
		for id in species.keys():
			var plan: Dictionary = species[id]
			var means: Array = []
			for index in range(TraitsScript.NAMES.size()):
				var drift: Array = plan.get("drift", [])
				means.append(1.0 + (float(drift[index]) if index < drift.size() else 0.0) * share)
			if plan.has("jump") and step >= int(plan["jump"][0]):
				means[int(plan["jump"][1])] += float(plan["jump"][2])
			values[id] = means
			spread[id] = [0.05, 0.05, 0.05, 0.05, 0.05]
			var count_plan = plan.get("counts", 100)
			counts[id] = int(count_plan.call(step)) if count_plan is Callable else int(count_plan)
			if plan.has("spread"):
				spread[id] = plan["spread"].call(step)
			var groups := {}
			for group in plan.get("leans", {}).keys():
				var lean: Array = plan["leans"][group]
				var tally: Array = []
				for index in range(TraitsScript.NAMES.size()):
					tally.append((float(means[index]) + (float(lean[1]) if index == int(lean[0]) else 0.0)) * float(lean[2]))
				tally.append(int(lean[2]))
				groups[group] = tally
			if plan.has("jump_tally") and step == int(plan["jump"][0]):
				groups.merge(plan["jump_tally"].call(means), true)
			tallies[id] = groups
		history.points.append({"time": float(step) * 120.0, "values": values, "spread": spread, "counts": counts,
			"tallies": tallies})
	return history


func _test_insights_tell_selection_from_chance(a) -> void:
	var history = _made_history(40, {
		# Faster, the parents ahead and the hunted behind: selection.
		"hare": {"drift": [0.12, 0.0, 0.0, 0.0, 0.01], "leans": {"parents": [0, 0.02, 6], "predation": [0, -0.012, 4]}},
		# Slower, and the starved quick: what speed costs.
		"herbivore": {"drift": [0.0, -0.06, 0.0, 0.0, 0.005], "leans": {"starvation": [1, 0.02, 3], "parents": [1, 0.0, 5]}},
		# A few birds, wandering as far as the marker: chance.
		"scavenger": {"drift": [0.07, 0.0, 0.0, 0.0, 0.065], "counts": 14, "leans": {"parents": [0, 0.01, 2]}},
	})
	var found := TraitInsightsScript.conclude(history, ["hare", "herbivore", "scavenger"])
	var by_key := {}
	for finding in found:
		by_key["%s:%d" % [finding["species"], int(finding["trait"])]] = finding
	var hare: Dictionary = by_key.get("hare:0", {})
	a.equal(str(hare.get("kind", "")), "selection", "the hares' speed is selection: %s" % str(hare))
	a.equal(str(hare.get("title", "")), "Зайцы стали быстрее на 12\u00a0%", "said plainly")
	a.is_true(str(hare.get("detail", "")).contains("У родителей детёнышей скорость выше") and
		str(hare.get("detail", "")).contains("У съеденных хищниками скорость ниже"), "with both leans: %s" % str(hare.get("detail", "")))
	a.equal(int(hare.get("confidence", 0)), 3, "heard often and leaning hard: sure")
	var deer: Dictionary = by_key.get("herbivore:1", {})
	a.equal(str(deer.get("kind", "")), "cost", "the deer's sight fell for its cost: %s" % str(deer))
	a.equal(str(deer.get("title", "")), "Олени стали хуже видеть на 6\u00a0%", "titled as it fell")
	var birds: Dictionary = by_key.get("scavenger:0", {})
	a.equal(str(birds.get("kind", "")), "drift", "a few birds' speed is chance: %s" % str(birds))
	a.is_true(not by_key.has("hare:1"), "a trait that did not move says nothing")
	a.equal(str(found[0]["kind"]), "selection", "the surest first")
	a.equal(TraitInsightsScript.percent(0.045), "4,5\u00a0%", "a small lean with its tenth")
	a.equal(TraitInsightsScript.percent(-0.123), "12\u00a0%", "a large one whole")
	a.is_true(TraitInsightsScript.conclude(_made_history(2, {"hare": {"drift": [0.2]}}), ["hare"]).is_empty(),
		"two points are too few to conclude anything")


func _test_insights_jump_bottleneck_race(a) -> void:
	var history = _made_history(40, {
		"wolf": {"drift": [0.0], "jump": [30, 2, -0.05], "jump_tally": _old_wolves},
		"hare": {"drift": [0.1, 0.06], "counts": func(step: int) -> int: return 20 if step == 20 else 150,
			"spread": func(step: int) -> Array: return [0.05, 0.05, 0.05, 0.05, 0.05] if step < 20 else [0.02, 0.02, 0.02, 0.02, 0.02]},
		"predator": {"drift": [0.08, 0.0]},
	})
	var found := TraitInsightsScript.conclude(history, ["wolf", "hare", "predator"], {"predator": ["hare"], "wolf": []})
	var kinds := {}
	for finding in found:
		kinds["%s:%s" % [finding["kind"], finding["species"]]] = finding
	var jump: Dictionary = kinds.get("jump:wolf", {})
	a.equal(int(jump.get("trait", -1)), 2, "the wolves' appetite jumped: %s" % str(jump))
	a.is_true(str(jump.get("title", "")).begins_with("Волки: аппетит упал на 5\u00a0% за"), "titled: %s" % str(jump.get("title", "")))
	a.is_true(str(jump.get("detail", "")).contains("Умерли от старости 3 зверя"), "with who went: %s" % str(jump.get("detail", "")))
	var neck: Dictionary = kinds.get("bottleneck:hare", {})
	a.is_true(str(neck.get("title", "")).contains("20 из 150"), "the hares' bottleneck: %s" % str(neck))
	var race: Dictionary = kinds.get("race:hare", {})
	a.equal(str(race.get("partner", "")), "predator", "foxes and hares race: %s" % str(race))
	a.equal(TraitInsightsScript.about(found, "predator", TraitsScript.SPEED).size() >= 1, true,
		"the race is about the hunter too")


## Three old wolves gone, their appetite 14 % over the pack's after the fall.
func _old_wolves(means: Array) -> Dictionary:
	var tally: Array = []
	for index in range(means.size()):
		tally.append((float(means[index]) + (0.14 if index == 2 else 0.0)) * 3.0)
	tally.append(3)
	return {"old_age": tally}


func _test_traits_screen_and_conclusions(a) -> void:
	var history = _made_history(30, {"hare": {"drift": [0.12], "leans": {"parents": [0, 0.01, 6], "predation": [0, -0.012, 4]}},
		"predator": {"drift": [0.05]}})
	history.founders["hare"] = TraitHistoryScript.histograms([[1.0, 1.0, 1.0, 1.0, 1.0]])
	var entries := [{"id": "hare", "label": "Зайцы", "color": Color(0.5, 0.35, 0.2)},
		{"id": "predator", "label": "Хищники", "color": Color(0.5, 0.2, 0.1)}]
	var found := TraitInsightsScript.conclude(history, ["hare", "predator"])
	var view = TraitsViewScript.new()
	view.size = Vector2(760.0, 500.0)
	view.show_history(history, entries, 3600.0, [120.0, 4], [], _family([[1.1, 1.0, 1.0, 1.0, 1.0]], "hare"), found)
	a.equal(view.shown_species, "", "it opens on every species")
	view.focus("hare", TraitsScript.SPEED)
	view.show_history(history, entries, 3600.0, [120.0, 4], [], _family([[1.1, 1.0, 1.0, 1.0, 1.0]], "hare"), found)
	a.is_true(view.drilled == TraitsScript.SPEED and not view._living_histograms.is_empty(), "a trait opened alone, with the living's histogram")
	view.focus("")
	a.is_true(view.shown_species == "" and view.drilled == -1, "and back to all")
	view.focus("hare")
	view._drill_at(TraitsScript.VISION, Rect2(0, 0, 100, 100), 0.1, Vector2(50, 50))
	a.equal(view.drilled, TraitsScript.VISION, "a click on a chart opens that trait")
	view.focus("")
	var last: Dictionary = history.points[-1]
	var plot := Rect2(0, 0, 100, 100)
	view._drill_at(TraitsScript.SPEED, plot, 0.2, Vector2(99.0, TraitsViewScript._y(plot, 50.0, 0.2,
		float(last["values"]["hare"][TraitsScript.SPEED]))))
	a.is_true(view.shown_species == "hare" and view.drilled == TraitsScript.SPEED, "with all, the click picks the nearest line")
	view.free()
	var list = InsightsViewScript.new()
	list.size = Vector2(740.0, 500.0)
	var asked: Array = []
	list.show_requested.connect(func(species_id: String, index: int) -> void: asked.append([species_id, index]))
	list.show_insights(found, entries)
	a.is_true(list.custom_minimum_size.y > 100.0, "the list grows to its cards")
	list._keep("selection")
	a.is_true(list._shown().all(func(finding) -> bool: return finding["kind"] == "selection"), "a chip keeps one kind")
	list.show_requested.emit("hare", 0)
	a.equal(asked, [["hare", 0]], "«Показать» asks for the trait")
	list.free()


func _test_newer_traits_only_where_listed(a) -> void:
	var old_list := {"traits": {"enabled": true}}
	var founder := TraitsScript.founder(31, old_list, 5)
	for index in [TraitsScript.CAUTION, TraitsScript.DROUGHT, TraitsScript.SIZE]:
		a.equal(float(founder[index]), 1.0, "a species without %s in its list stays the species" % TraitsScript.NAMES[index])
	var listed := {"traits": {"enabled": true, "list": TraitsScript.NAMES}}
	var spread := TraitsScript.founder(31, listed, 5)
	a.is_true(float(spread[TraitsScript.SIZE]) != 1.0 and absf(float(spread[TraitsScript.SIZE]) - 1.0) <= 0.08,
		"listed, size spreads like the rest: %s" % str(spread))
	for index in range(TraitsScript.MARKER):
		a.equal(float(spread[index]), float(founder[index]), "and the first ones are the same draws (%s)" % TraitsScript.NAMES[index])
	var young := TraitsScript.inherit(9, spread, spread, old_list, 5)
	a.equal(float(young[TraitsScript.SIZE]), 1.0, "a young one of a species without size has none, whatever its parents")
	a.equal(TraitsScript.indices(listed), range(TraitsScript.NAMES.size()), "every index listed")
	a.equal(TraitsScript.indices(old_list), [0, 1, 2, 3, 4], "the first five by default")
	var shipped: Dictionary = ConfigLoader.load_config_bundle(ConfigLoader.default_selection())["species"]
	a.is_true(TraitsScript.has_trait(TraitsScript.settings(shipped["herbivore"]), TraitsScript.CAUTION),
		"deer are cautious by heredity")
	a.is_true(not TraitsScript.has_trait(TraitsScript.settings(shipped["predator"]), TraitsScript.CAUTION),
		"foxes have no caution to inherit")
	a.is_true(TraitsScript.has_trait(TraitsScript.settings(shipped["wolf"]), TraitsScript.SIZE), "wolves have size")
	a.equal(HudText.traits_text([1.06, 0.97, 1.02, 1.04, 1.3, 1.0, 1.1, 0.9]),
		"Скорость +6 % · Зрение −3 %\nАппетит +2 % · Долголетие +4 %\nЗасухоустойчивость +10 % · Размер −10 %",
		"the card names the newer traits the animal has, not those its species lacks")
	a.equal(HudText.traits_brief([1.0, 1.0, 1.0, 1.0, 1.4, 1.2, 1.0, 1.0]), "Черты: осторожность +20 %",
		"a cautious one's brief")


func _test_caution_drought_size_give_and_cost(a) -> void:
	var settings := TraitsScript.settings({"traits": {"enabled": true}})
	var dry: Array = TraitsScript.NEUTRAL.duplicate()
	dry[TraitsScript.DROUGHT] = 1.25
	a.near(TraitsScript.thirst_factor(dry), 0.8, 0.0001, "a quarter more drought-hardy thirsts a fifth slower")
	a.near(TraitsScript.hunger_factor(dry, settings), 1.1, 0.0001, "and is a tenth hungrier")
	var big: Array = TraitsScript.NEUTRAL.duplicate()
	big[TraitsScript.SIZE] = 1.25
	a.near(TraitsScript.hunger_factor(big, settings), pow(1.25, -0.25), 0.0001, "a big body's hunger rises slowly")
	a.near(TraitsScript.fill_factor(big), 0.8, 0.0001, "but a bite fills it less")
	a.near(TraitsScript.hunger_factor(big, settings) / TraitsScript.fill_factor(big), pow(1.25, 0.75), 0.0001,
		"so it needs food as its size to the three quarters")
	a.near(TraitsScript.turn_factor(big, settings), 1.0 / sqrt(1.25), 0.0001, "and turns slower")
	var wary: Array = TraitsScript.NEUTRAL.duplicate()
	wary[TraitsScript.CAUTION] = 1.2
	a.near(TraitsScript.hunger_factor(wary, settings), 1.0, 0.0001, "awake, caution costs no hunger: it costs grazing")
	a.near(TraitsScript.sleeping_hunger_factor(wary, settings), 1.06, 0.0001, "asleep it is paid in hunger")
	var manager = Helpers.create_manager(9120)
	var world = manager.world_state
	var plain = Helpers.spawn_herbivore(world, Vector2(60.0, 60.0), 1)
	var hardy = Helpers.spawn_herbivore(world, Vector2(160.0, 160.0), 2)
	hardy.set_traits(dry)
	for agent in [plain, hardy]:
		agent.thirst = 0.0
		agent.update_needs(1.0)
	a.near(hardy.thirst / plain.thirst, 0.8, 0.0001, "awake, the drought-hardy thirsts slower")
	var heavy = Helpers.spawn_herbivore(world, Vector2(200.0, 60.0), 3)
	heavy.set_traits(big)
	a.near(heavy.trait_fill, 0.8, 0.0001, "a heavy grazer's bites fill it less")
	heavy.direction = Vector2.RIGHT
	plain.direction = Vector2.RIGHT
	heavy.movement = heavy.movement.duplicate()
	heavy.movement["max_turn_rate_degrees"] = 90.0
	plain.movement = plain.movement.duplicate()
	plain.movement["max_turn_rate_degrees"] = 90.0
	var turned_heavy: Vector2 = heavy._damp_turn(Vector2.UP * 10.0, 0.5)
	var turned_plain: Vector2 = plain._damp_turn(Vector2.UP * 10.0, 0.5)
	a.is_true(absf(turned_heavy.angle()) < absf(turned_plain.angle()), "and it swings round slower")
	var cautious = Helpers.spawn_herbivore(world, Vector2(300.0, 300.0), 4)
	cautious.set_traits(wary)
	a.is_true(world.grazing_ground_is_acceptable(Vector2.ZERO, 0.0, {"risk_tolerance": 0.5}, 1.0) and
		world.grazing_ground_is_acceptable(Vector2.ZERO, 0.0, {"risk_tolerance": 0.5}, cautious.trait_caution),
		"unfeared ground suits the cautious too")
	# The test world is fearless; this check needs ground a hunter has marked.
	world.fear_field.enabled = true
	world.fear_field.deposit(Vector2.ZERO, 0.45)
	var risk: float = world.fear_field.risk_at(Vector2.ZERO)
	var tolerance := risk * 1.1
	a.is_true(world.grazing_ground_is_acceptable(Vector2.ZERO, 0.0, {"risk_tolerance": tolerance}, 1.0)
		and not world.grazing_ground_is_acceptable(Vector2.ZERO, 0.0, {"risk_tolerance": tolerance}, 1.2),
		"ground a bold one grazes, a cautious one leaves (risk %.2f)" % risk)
	Helpers.destroy_manager(manager)


func _test_sleepers_pay_for_the_newer_traits(a) -> void:
	var manager = Helpers.create_manager_with(_heredity_bundle(9121), 9121)
	var world = manager.world_state
	var hardy := {"id": 1, "thirst": 10.0, "traits": [1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.25, 1.0]}
	var plain := {"id": 2, "thirst": 10.0, "traits": TraitsScript.NEUTRAL}
	var weigh: Callable = world._dormant_trait_weigh("herbivore", "thirst", 2.0)
	a.is_true(weigh.is_valid(), "asleep, thirst rising is shared by how quickly each thirsts")
	world._share_dormant_need_shift([hardy, plain], "thirst", 2.0, 0.0, 100.0, weigh)
	a.is_true(float(hardy["thirst"]) < float(plain["thirst"]), "the drought-hardy one thirsts less asleep too")
	a.near(float(hardy["thirst"]) + float(plain["thirst"]), 24.0, 0.0001, "and the group's mean moves by the step")
	var near := Vector2(100.0, 100.0)
	var bold := {"id": 3, "position": Vector2(124.0, 100.0), "traits": [1.0, 1.0, 1.0, 1.0, 1.0, 0.85, 1.0, 1.0]}
	var wary := {"id": 4, "position": Vector2(120.0, 100.0), "traits": [1.0, 1.0, 1.0, 1.0, 1.0, 1.2, 1.0, 1.0]}
	a.equal(world._pick_dormant_victim([wary, bold], "predation", {"near": near}), 1,
		"asleep, hunters take the bold one though the wary stood nearer")
	var small := {"id": 5, "position": Vector2(124.0, 100.0), "traits": [1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 0.8]}
	var large := {"id": 6, "position": Vector2(120.0, 100.0), "traits": [1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.25]}
	a.equal(world._pick_dormant_victim([large, small], "predation", {"near": near}), 1, "and the small before the big")
	var hunger: Callable = world._dormant_trait_weigh("herbivore", "hunger", 2.0)
	a.near(float(hunger.call(wary)), 1.06, 0.0001, "and the wary pays in hunger")
	Helpers.destroy_manager(manager)
