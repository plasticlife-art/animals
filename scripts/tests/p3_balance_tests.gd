extends RefCounted

const Helpers = preload("res://scripts/tests/test_helpers.gd")
const AgentBase = preload("res://scripts/agents/agent_base.gd")
const HuntEvaluator = preload("res://scripts/agents/ai/evaluators/hunt_prey_utility_evaluator.gd")


func run(a) -> void:
	_test_live_reproduction_requires_health_reserve(a)
	_test_dormant_juveniles_and_single_sex_groups_do_not_breed(a)
	_test_dormant_pair_breeds_only_when_ready(a)
	_test_dormant_age_cohorts_remain_distinct(a)
	_test_dormant_old_age_only_removes_old_cohort(a)
	_test_dormant_herd_grazes_while_travelling(a)
	_test_rest_reserve_scales_per_species(a)
	_test_carrying_capacity_only_suppresses_births(a)
	_test_critical_hunger_expands_carrion_search(a)
	_test_exhausted_predator_does_not_start_hunt(a)
	_test_critical_thirst_expands_water_search(a)


func _ready_record(agent, age: float, sex: String) -> Dictionary:
	agent.age = age
	agent.sex = sex
	agent.energy = float(agent.reproduction.get("energy_threshold", 0.0)) + 20.0
	agent.hunger = 0.0
	agent.thirst = 0.0
	agent.reproduction_cooldown = 0.0
	return agent.export_runtime_state()


func _test_live_reproduction_requires_health_reserve(a) -> void:
	var manager = Helpers.create_manager(81)
	var herbivore = Helpers.spawn_herbivore(manager.world_state, Vector2(100, 100))
	herbivore.reproduction_cooldown = 0.0
	herbivore.age = float(herbivore.reproduction.get("maturity_age", 0.0)) + 1.0
	herbivore.energy = float(herbivore.reproduction.get("energy_threshold", 0.0)) + 1.0
	herbivore.hunger = float(herbivore.reproduction.get("max_hunger", 100.0)) + 0.1
	a.is_true(not herbivore.can_reproduce(), "a hungry live animal keeps its reserve for survival")
	herbivore.hunger = 0.0
	herbivore.thirst = float(herbivore.reproduction.get("max_thirst", 100.0)) + 0.1
	a.is_true(not herbivore.can_reproduce(), "a thirsty live animal does not reproduce")
	herbivore.thirst = 0.0
	a.is_true(herbivore.can_reproduce(), "a mature fed and watered animal may reproduce")
	Helpers.destroy_manager(manager)


func _test_dormant_juveniles_and_single_sex_groups_do_not_breed(a) -> void:
	var manager = Helpers.create_manager(82)
	var world = manager.world_state
	var male = Helpers.spawn_species(world, "herbivore", Vector2(90, 90), 4, AgentBase.SEX_MALE)
	var female = Helpers.spawn_species(world, "herbivore", Vector2(100, 90), 4, AgentBase.SEX_FEMALE)
	var juvenile_records := [_ready_record(male, 1.0, AgentBase.SEX_MALE),
		_ready_record(female, 1.0, AgentBase.SEX_FEMALE)]
	var aggregates: Array = world._build_dormant_aggregates(juvenile_records, Vector2i.ZERO)
	aggregates[0]["birth_debt"] = 2.0
	a.equal(world._compute_dormant_births_for_aggregate(aggregates[0], 1.0), 0,
		"juveniles cannot breed while dormant")

	var female_records := [_ready_record(male, 30.0, AgentBase.SEX_FEMALE),
		_ready_record(female, 30.0, AgentBase.SEX_FEMALE)]
	aggregates = world._build_dormant_aggregates(female_records, Vector2i.ZERO)
	aggregates[0]["birth_debt"] = 2.0
	a.equal(world._compute_dormant_births_for_aggregate(aggregates[0], 1.0), 0,
		"a single-sex dormant group cannot create offspring")
	Helpers.destroy_manager(manager)


func _test_dormant_pair_breeds_only_when_ready(a) -> void:
	var manager = Helpers.create_manager(83)
	var world = manager.world_state
	var male = Helpers.spawn_species(world, "herbivore", Vector2(90, 90), 5, AgentBase.SEX_MALE)
	var female = Helpers.spawn_species(world, "herbivore", Vector2(100, 90), 5, AgentBase.SEX_FEMALE)
	var records := [_ready_record(male, 30.0, AgentBase.SEX_MALE),
		_ready_record(female, 30.0, AgentBase.SEX_FEMALE)]
	var aggregate: Dictionary = world._build_dormant_aggregates(records, Vector2i.ZERO)[0]
	aggregate["birth_debt"] = 1.0
	a.equal(world._compute_dormant_births_for_aggregate(aggregate, 1.0), 1,
		"one ready opposite-sex dormant pair produces at most one offspring")
	a.is_true(float(aggregate.get("avg_energy", 999.0)) < float(male.metabolism.get("max_energy", 100.0)),
		"dormant parents pay the configured birth energy cost")
	Helpers.destroy_manager(manager)


func _test_dormant_age_cohorts_remain_distinct(a) -> void:
	var manager = Helpers.create_manager(84)
	var world = manager.world_state
	var adult = Helpers.spawn_species(world, "herbivore", Vector2(90, 90), 6, AgentBase.SEX_MALE)
	var juvenile = Helpers.spawn_species(world, "herbivore", Vector2(100, 90), 6, AgentBase.SEX_FEMALE)
	var records := [_ready_record(adult, 30.0, AgentBase.SEX_MALE),
		_ready_record(juvenile, 2.0, AgentBase.SEX_FEMALE)]
	var aggregate: Dictionary = world._build_dormant_aggregates(records, Vector2i.ZERO)[0]
	var sector_state := {"dormant_records": records, "dormant_aggregates": [aggregate]}
	world._sync_dormant_records_with_aggregates(Vector2i.ZERO, sector_state, 0.75)
	var ages: Array = []
	for record in sector_state["dormant_records"]:
		ages.append(float(record.get("age", -1.0)))
	ages.sort()
	a.near(float(ages[0]), 2.75, 0.001, "the juvenile cohort advances by elapsed time")
	a.near(float(ages[1]), 30.75, 0.001, "the adult cohort is not averaged with newborns")
	Helpers.destroy_manager(manager)


func _test_dormant_old_age_only_removes_old_cohort(a) -> void:
	var manager = Helpers.create_manager(85)
	var world = manager.world_state
	var elder = Helpers.spawn_species(world, "herbivore", Vector2(90, 90), 7, AgentBase.SEX_MALE)
	var young = Helpers.spawn_species(world, "herbivore", Vector2(100, 90), 7, AgentBase.SEX_FEMALE)
	var max_age := float(elder.aging.get("max_age", 220.0))
	var records := [_ready_record(elder, max_age + 1.0, AgentBase.SEX_MALE),
		_ready_record(young, 2.0, AgentBase.SEX_FEMALE)]
	var aggregate: Dictionary = world._build_dormant_aggregates(records, Vector2i.ZERO)[0]
	world._apply_dormant_metabolism_to_aggregate(Vector2i.ZERO, aggregate, 0.75)
	a.equal(int(aggregate.get("count", 0)), 1,
		"a max-age dormant adult dies without taking the juvenile cohort with it")
	var sector_state := {"dormant_records": records, "dormant_aggregates": [aggregate]}
	world._sync_dormant_records_with_aggregates(Vector2i.ZERO, sector_state, 0.75)
	a.near(float(sector_state["dormant_records"][0].get("age", -1.0)), 2.75, 0.001,
		"coarse old-age removal retains the younger record")
	Helpers.destroy_manager(manager)


func _test_dormant_herd_grazes_while_travelling(a) -> void:
	var manager = Helpers.create_manager(86)
	var world = manager.world_state
	var herbivore = Helpers.spawn_species(world, "herbivore", Vector2(90, 90), 8, AgentBase.SEX_FEMALE)
	var record := _ready_record(herbivore, 30.0, AgentBase.SEX_FEMALE)
	var sector_key: Vector2i = world._get_sector_key(Vector2(record["position"]))
	var aggregate: Dictionary = world._build_dormant_aggregates([record], sector_key)[0]
	aggregate["avg_hunger"] = 50.0
	aggregate["goal_kind"] = "water"
	aggregate["goal_sector"] = sector_key + Vector2i.ONE
	var sector_state := {"dormant_aggregates": [aggregate]}
	world._apply_dormant_resource_interactions(sector_key, sector_state, 0.75)
	a.is_true(float(aggregate.get("avg_hunger", 50.0)) < 50.0,
		"a dormant herd consumes local grass while its centre travels toward water")
	Helpers.destroy_manager(manager)


func _test_rest_reserve_scales_per_species(a) -> void:
	var manager = Helpers.create_manager(87)
	var predator = Helpers.spawn_predator(manager.world_state, Vector2(100, 100))
	predator.state = "rest"
	predator.energy = 50.0
	a.is_true(predator.is_energy_below_rest_floor(),
		"a predator keeps resting until its species-sized chase reserve is restored")
	predator.energy = 61.0
	a.is_true(not predator.is_energy_below_rest_floor(),
		"a predator leaves rest after reaching its configured reserve")
	Helpers.destroy_manager(manager)


func _test_carrying_capacity_only_suppresses_births(a) -> void:
	var bundle := Helpers.build_test_bundle(88)
	bundle["balance"]["population_regulation"] = {
		"enabled": true,
		"capacity_multipliers": {"herbivore": 1.5},
	}
	bundle["world"]["spawns"]["herbivore_count"] = 2
	bundle["world"]["spawns"]["herbivore_group_count"] = 1
	var manager = Helpers.create_manager_with(bundle, 88)
	a.equal(manager.world_state.get_reproductive_capacity("herbivore"), 3,
		"habitat carrying capacity scales from the selected preset population")
	a.equal(manager.world_state.reserve_reproductive_capacity("herbivore", 2), 1,
		"birth reservations cannot overshoot the habitat capacity within one tick")
	a.is_true(not manager.world_state.has_reproductive_capacity("herbivore"),
		"breeding pauses at capacity without adding or removing an animal")
	Helpers.destroy_manager(manager)


func _test_critical_hunger_expands_carrion_search(a) -> void:
	var manager = Helpers.create_manager(89)
	var scavenger = Helpers.spawn_species(manager.world_state, "scavenger", Vector2(100, 100))
	scavenger.hunger = 20.0
	var normal_radius: float = float(manager.world_state.carcass_search_radius(scavenger))
	scavenger.hunger = 99.0
	a.is_true(manager.world_state.carcass_search_radius(scavenger) > normal_radius * 3.0,
		"a starving carrion eater follows scent beyond its normal search radius")
	Helpers.destroy_manager(manager)


func _test_exhausted_predator_does_not_start_hunt(a) -> void:
	var manager = Helpers.create_manager(90)
	var predator = Helpers.spawn_predator(manager.world_state, Vector2(100, 100))
	predator.energy = float(predator.hunt.get("min_chase_energy", 0.0))
	var context = Helpers.build_context({
		"feeding_allowed": 1.0,
		"hunger": 0.9,
		"prey_quality": 1.0,
		"prey_proximity": 1.0,
		"energy_ratio": predator.energy / float(predator.metabolism.get("max_energy", 150.0)),
	})
	a.is_true(bool(HuntEvaluator.new().evaluate(predator, context).get("vetoed", false)),
		"an exhausted predator rests instead of opening a chase it must abort")
	Helpers.destroy_manager(manager)


func _test_critical_thirst_expands_water_search(a) -> void:
	var manager = Helpers.create_manager(91)
	var scavenger = Helpers.spawn_species(manager.world_state, "scavenger", Vector2(100, 100))
	scavenger.thirst = 20.0
	var normal_radius: float = float(manager.world_state.water_search_radius(scavenger))
	scavenger.thirst = 99.0
	a.is_true(manager.world_state.water_search_radius(scavenger) > normal_radius * 2.5,
		"a critically thirsty animal searches beyond its normal water memory radius")
	Helpers.destroy_manager(manager)
