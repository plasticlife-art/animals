extends RefCounted

## Grass that can run out, and ground that prey learn to avoid.

const Helpers := preload("res://scripts/tests/test_helpers.gd")
const AgentAIState := preload("res://scripts/agents/ai/agent_ai_state.gd")
const WorldStateScript := preload("res://scripts/world/world_state.gd")

const GRASS_COLUMNS := 8


func run(a) -> void:
	_test_grass_grows_fastest_half_grown(a)
	_test_stubble_cannot_be_grazed_and_regrows(a)
	_test_growth_resumes_identically_after_a_reload(a)
	_test_a_bite_takes_no_more_than_hunger_can_use(a)
	_test_fed_grazer_walks_past_a_poor_sward(a)
	_test_no_grass_where_nothing_can_walk(a)
	_test_sleeping_grazer_walks_to_grass_beside_it(a)
	_test_starving_sleeper_heads_for_its_herds_grass(a)
	_test_sleeping_herd_looks_for_grass_from_where_it_stands(a)
	_test_risk_fades_by_half_each_half_life(a)
	_test_a_kill_marks_the_ground(a)
	_test_a_scare_marks_the_ground_once(a)
	_test_fed_grazer_keeps_off_risky_ground(a)
	_test_sleeping_herd_keeps_off_risky_ground(a)
	_test_fear_survives_a_save(a)
	_test_an_outgrown_herd_divides(a)
	_test_a_sleeping_herd_divides_too(a)
	_test_a_starved_animal_leaves_little_meat(a)


func _bundle(seed: int, growth_rate: float = 0.0, fear: bool = false) -> Dictionary:
	var bundle: Dictionary = Helpers.build_test_bundle(seed)
	bundle["world"]["grass"]["growth_rate"] = growth_rate
	bundle["world"]["grass"]["growth_stride_ticks"] = 4
	if fear:
		bundle["world"]["fear"] = {"enabled": true, "cell_size_in_grass_cells": 2, "half_life_seconds": 10.0,
			"kill_risk": 1.0, "scare_risk": 0.05, "hunt_pressure_risk": 0.1, "decay_stride_ticks": 4}
	return bundle


## Writes grazable biomass straight into the grid: everything bare except `cells`.
func _lay_grass(world, cells: Dictionary) -> void:
	var resources = world.resource_system
	for index in range(resources.get_cell_count()):
		resources._cells[index] = float(cells.get(index, 0.0))
	resources._rebuild_derived()
	world._sector_grass_cache.clear()


func _cell(column: int, row: int) -> int:
	return row * GRASS_COLUMNS + column


func _test_grass_grows_fastest_half_grown(a) -> void:
	var manager = Helpers.create_manager_with(_bundle(401, 0.05), 401)
	var world = manager.world_state
	_lay_grass(world, {0: 10.0, 1: 50.0, 2: 90.0, 3: 100.0})
	Helpers.run_ticks(manager, 24)
	var resources = world.resource_system
	var sparse: float = resources.get_biomass(0) - 10.0
	var half: float = resources.get_biomass(1) - 50.0
	var dense: float = resources.get_biomass(2) - 90.0
	a.is_true(sparse > 0.0 and dense > 0.0, "grass below its cap grows")
	a.is_true(half > sparse * 2.0 and half > dense * 2.0,
		"a half-grown sward grows fastest (sparse %.2f, half %.2f, dense %.2f)" % [sparse, half, dense])
	a.equal(resources.get_biomass(3), 100.0, "a full cell does not grow")
	a.near(resources.get_biomass(4), 0.0, 0.0001, "bare ground with no stubble stays bare")
	Helpers.destroy_manager(manager)


func _test_stubble_cannot_be_grazed_and_regrows(a) -> void:
	var bundle := _bundle(402, 0.05)
	bundle["world"]["grass"]["stubble_fraction"] = 0.1
	var manager = Helpers.create_manager_with(bundle, 402)
	var resources = manager.world_state.resource_system
	var eaten: float = resources.consume_cell(0, INF)
	a.near(resources.get_biomass(0), 10.0, 0.0001, "grazing stops at the stubble")
	a.near(eaten, 90.0, 0.0001, "everything above the stubble can be eaten")
	a.equal(resources.get_available_biomass(0), 0.0, "stubble is not food")
	a.equal(resources.consume_cell(0, 5.0), 0.0, "a stripped cell gives nothing more")
	Helpers.run_ticks(manager, 24)
	a.greater(resources.get_biomass(0), 10.0, "a stripped cell regrows from its stubble")
	Helpers.destroy_manager(manager)


## Growth runs on a schedule taken from the tick, so a world restored mid-run keeps
## growing exactly as the one it was saved from.
func _test_growth_resumes_identically_after_a_reload(a) -> void:
	var original = Helpers.create_manager_with(_bundle(403, 0.05), 403)
	for index in range(12):
		original.world_state.resource_system.consume_cell(index * 5, 20.0 + float(index) * 5.0)
	Helpers.run_ticks(original, 7)
	var saved: Dictionary = original.world_state.export_state()
	var restored = Helpers.create_manager_with(_bundle(403, 0.05), 403)
	restored.world_state.import_state(saved)
	restored.current_tick = original.current_tick
	restored.simulation_time = original.simulation_time
	Helpers.run_ticks(original, 9)
	Helpers.run_ticks(restored, 9)
	a.equal(restored.world_state.resource_system.export_cells(), original.world_state.resource_system.export_cells(),
		"a reloaded world grows the same grass on the same ticks")
	Helpers.destroy_manager(original)
	Helpers.destroy_manager(restored)


func _test_a_bite_takes_no_more_than_hunger_can_use(a) -> void:
	var feeding := {"bite_amount": 33.0, "nutrition_gain": 0.3}
	a.near(WorldStateScript.grazing_bite(feeding, 60.0), 33.0, 0.0001, "a hungry animal takes a full bite")
	a.near(WorldStateScript.grazing_bite(feeding, 3.0), 10.0, 0.0001, "a nearly full one takes only what it can use")
	a.near(WorldStateScript.grazing_bite(feeding, 60.0, 1.5), 49.5, 0.0001, "a longer step scales the bite")


## Fed, a grazer heads for a sward worth the walk and leaves a grazed-down one to
## regrow. Hungry, it takes the nearest full bite.
func _test_fed_grazer_walks_past_a_poor_sward(a) -> void:
	var bundle := _bundle(404)
	bundle["world"]["grass"]["max_biomass"] = 200.0
	var manager = Helpers.create_manager_with(bundle, 404)
	var world = manager.world_state
	var poor := _cell(2, 3)
	var good := _cell(5, 3)
	_lay_grass(world, {poor: 40.0, good: 150.0})
	var grazer = Helpers.spawn_herbivore(world, Vector2(112.0, 112.0), 0)
	grazer.hunger = 20.0
	a.equal(int(world._find_grass_target_for_agent(grazer).get("index", -1)), good,
		"a fed grazer passes the poor sward for the good one")
	grazer.clear_decision_cache()
	grazer.hunger = 75.0
	a.equal(int(world._find_grass_target_for_agent(grazer).get("index", -1)), poor,
		"a hungry grazer takes the nearest full bite")
	Helpers.destroy_manager(manager)


func _test_risk_fades_by_half_each_half_life(a) -> void:
	var manager = Helpers.create_manager_with(_bundle(405, 0.0, true), 405)
	var field = manager.world_state.fear_field
	field.deposit(Vector2(40.0, 40.0), 1.0)
	a.near(field.risk_at(Vector2(40.0, 40.0)), 1.0, 0.0001, "a deposit lands in full on its own cell")
	a.near(field.risk_at(Vector2(100.0, 40.0)), 0.5, 0.0001, "and at half strength beside it")
	a.near(field.risk_at(Vector2(100.0, 100.0)), 0.25, 0.0001, "and a quarter diagonally")
	a.equal(field.risk_at(Vector2(200.0, 40.0)), 0.0, "and nowhere further")
	Helpers.run_ticks(manager, 120)
	a.near(field.risk_at(Vector2(40.0, 40.0)), 0.5, 0.02, "ten seconds at a ten-second half-life leaves half")
	Helpers.destroy_manager(manager)


func _test_a_kill_marks_the_ground(a) -> void:
	var manager = Helpers.create_manager_with(_bundle(406, 0.0, true), 406)
	var world = manager.world_state
	var prey = Helpers.spawn_herbivore(world, Vector2(176.0, 112.0), 0)
	var old = Helpers.spawn_herbivore(world, Vector2(40.0, 200.0), 0)
	world.kill_agent(prey, "predation")
	world.kill_agent(old, "old_age")
	a.near(world.fear_field.risk_at(Vector2(176.0, 112.0)), 1.0, 0.0001, "a kill marks the place it happened")
	a.equal(world.fear_field.risk_at(Vector2(40.0, 200.0)), 0.0, "a death from old age frightens no one")
	Helpers.destroy_manager(manager)


func _test_a_scare_marks_the_ground_once(a) -> void:
	var manager = Helpers.create_manager_with(_bundle(407, 0.0, true), 407)
	var world = manager.world_state
	var grazer = Helpers.spawn_herbivore(world, Vector2(176.0, 112.0), 0)
	var predator = Helpers.spawn_predator(world, Vector2(176.0, 200.0))
	predator.hunger = 0.0
	Helpers.run_ticks(manager, 1)
	a.equal(grazer.ai_state, AgentAIState.PANIC, "the fixture should scare the grazer")
	var total := 0.0
	for index in range(world.fear_field.get_cell_count()):
		total += world.fear_field.get_risk(index)
	Helpers.run_ticks(manager, 3)
	var later := 0.0
	for index in range(world.fear_field.get_cell_count()):
		later += world.fear_field.get_risk(index)
	a.greater(total, 0.0, "being scared marks the ground")
	a.is_true(later <= total, "one scare is logged once, not on every tick of the panic (%.3f then %.3f)" % [total, later])
	Helpers.destroy_manager(manager)


## The trophic cascade in one decision: risky ground with good grass is left alone
## until hunger outweighs fear.
func _test_fed_grazer_keeps_off_risky_ground(a) -> void:
	var manager = Helpers.create_manager_with(_bundle(408, 0.0, true), 408)
	var world = manager.world_state
	var risky := _cell(2, 3)
	var safe := _cell(5, 3)
	_lay_grass(world, {risky: 100.0, safe: 100.0})
	world.fear_field.deposit(Vector2(80.0, 112.0), 0.8)
	var grazer = Helpers.spawn_herbivore(world, Vector2(112.0, 112.0), 0)
	grazer.hunger = 20.0
	a.equal(int(world._find_grass_target_for_agent(grazer).get("index", -1)), safe,
		"a fed grazer walks further to graze on safe ground")
	grazer.clear_decision_cache()
	grazer.hunger = 75.0
	a.equal(int(world._find_grass_target_for_agent(grazer).get("index", -1)), risky,
		"a hungry one grazes the nearest grass, risk or not")
	a.is_true(not world.grazing_ground_is_acceptable(Vector2(80.0, 112.0), 20.0, grazer.perception),
		"a fed grazer does not eat underfoot on risky ground")
	a.is_true(world.grazing_ground_is_acceptable(Vector2(80.0, 112.0), 75.0, grazer.perception),
		"a hungry one does")
	Helpers.destroy_manager(manager)


func _test_sleeping_herd_keeps_off_risky_ground(a) -> void:
	var bundle: Dictionary = Helpers.build_large_sector_bundle(409)
	bundle["world"]["fear"] = {"enabled": true, "cell_size_in_grass_cells": 4, "half_life_seconds": 480.0}
	var manager = Helpers.create_manager_with(bundle, 409)
	var world = manager.world_state
	var herd: Array = Helpers.spawn_herd(world, Vector2(768.0, 768.0), 6, 0)
	for grazer in herd:
		grazer.hunger = 20.0
		grazer.thirst = 0.0
	var sector_key: Vector2i = world._get_sector_key(Vector2(768.0, 768.0))
	world._sleep_sector(sector_key)
	# The herd straddles four fear cells; 4.0 leaves even the diagonal one above tolerance.
	world.fear_field.deposit(Vector2(768.0, 768.0), 4.0)
	var aggregate: Dictionary = world._sector_states[sector_key]["dormant_aggregates"][0]
	var tolerance := float(herd[0].perception.get("risk_tolerance", INF))
	var goal: Dictionary = world._select_dormant_goal(sector_key, aggregate)
	a.equal(str(goal.get("goal_kind", "")), "grass", "a peckish sleeping herd looks for grass")
	a.is_true(world.fear_field.risk_at(Vector2(goal.get("goal_position", Vector2.ZERO))) <= tolerance,
		"and picks it on ground it does not fear")
	var state: Dictionary = world._sector_states[sector_key]
	var biomass_before: float = world.resource_system.get_total_biomass()
	world._apply_dormant_resource_interactions(sector_key, state, 0.75)
	a.equal(world.resource_system.get_total_biomass(), biomass_before, "fed sleepers do not graze the risky ground they stand on")
	for record in state["dormant_records"]:
		record["hunger"] = 80.0
	aggregate["avg_hunger"] = 80.0
	world._apply_dormant_resource_interactions(sector_key, state, 0.75)
	a.is_true(world.resource_system.get_total_biomass() < biomass_before, "hungry ones do")
	Helpers.destroy_manager(manager)


func _test_fear_survives_a_save(a) -> void:
	var original = Helpers.create_manager_with(_bundle(410, 0.0, true), 410)
	original.world_state.fear_field.deposit(Vector2(176.0, 112.0), 0.7)
	var saved: Dictionary = original.world_state.export_state()
	var restored = Helpers.create_manager_with(_bundle(410, 0.0, true), 410)
	restored.world_state.import_state(saved)
	a.equal(restored.world_state.fear_field.export_cells(), original.world_state.fear_field.export_cells(),
		"a loaded world remembers where its prey were hunted")
	Helpers.destroy_manager(original)
	Helpers.destroy_manager(restored)


## Grass on a cliff or in a pond can never be eaten. Left in, it stayed the richest cell
## around for ever and drew sleeping herds to stand beside it and starve.
func _test_no_grass_where_nothing_can_walk(a) -> void:
	var bundle: Dictionary = Helpers.build_large_sector_bundle(411)
	bundle["world"]["terrain"]["obstacles"] = {"dense_forest_cluster_count": 3, "dense_forest_radius_min_cells": 1.0,
		"dense_forest_radius_max_cells": 2.0, "cliff_count": 2, "cliff_thickness_min_cells": 1.1,
		"cliff_thickness_max_cells": 2.0, "cliff_gap_radius_cells": 1.6, "border_clearance_cells": 1}
	var manager = Helpers.create_manager_with(bundle, 411)
	var world = manager.world_state
	var blocked := 0
	var grassy_blocked := 0
	for index in range(world.resource_system.get_cell_count()):
		if world.terrain_system.is_walkable_index(index):
			continue
		blocked += 1
		if world.resource_system.get_biomass(index) > 0.0:
			grassy_blocked += 1
	a.greater(float(blocked), 0.0, "the fixture should have cells nothing can walk on")
	a.equal(grassy_blocked, 0, "no grass grows where nothing can walk")
	Helpers.destroy_manager(manager)


const WIDE_COLUMNS := 48


## One sleeping grazer on bare ground at cell (12, 12) of the large-sector fixture.
func _sleeping_grazer(seed: int, cells: Dictionary) -> Array:
	var manager = Helpers.create_manager_with(Helpers.build_large_sector_bundle(seed), seed)
	var world = manager.world_state
	_lay_grass(world, cells)
	var grazer = Helpers.spawn_herbivore(world, Vector2(800.0, 800.0), 0)
	grazer.hunger = 70.0
	grazer.thirst = 0.0
	var sector_key: Vector2i = world._get_sector_key(grazer.position)
	world._sleep_sector(sector_key)
	return [manager, world, sector_key, world._sector_states[sector_key]]


func _test_sleeping_grazer_walks_to_grass_beside_it(a) -> void:
	var beside := 12 * WIDE_COLUMNS + 13
	var fixture := _sleeping_grazer(412, {beside: 100.0})
	var world = fixture[1]
	var state: Dictionary = fixture[3]
	var record: Dictionary = state["dormant_records"][0]
	for _step in range(2):
		world._apply_dormant_resource_interactions(fixture[2], state, 0.75)
	a.equal(world.resource_system.get_index_at_position(Vector2(record["position"])), beside,
		"with nothing underfoot a sleeping grazer walks to the grass beside it")
	a.is_true(float(record["hunger"]) < 70.0, "and eats once it is there")
	Helpers.destroy_manager(fixture[0])


func _test_starving_sleeper_heads_for_its_herds_grass(a) -> void:
	var fixture := _sleeping_grazer(413, {})
	var world = fixture[1]
	var state: Dictionary = fixture[3]
	var aggregate: Dictionary = state["dormant_aggregates"][0]
	aggregate["goal_kind"] = "grass"
	aggregate["goal_position"] = Vector2(1400.0, 800.0)
	var record: Dictionary = state["dormant_records"][0]
	var before := Vector2(record["position"]).distance_to(Vector2(1400.0, 800.0))
	world._apply_dormant_resource_interactions(fixture[2], state, 0.75)
	var after := Vector2(record["position"]).distance_to(Vector2(1400.0, 800.0))
	a.greater(before - after, 20.0, "with no grass in reach a sleeping grazer heads for the grass its herd is making for")
	Helpers.destroy_manager(fixture[0])


## The per-sector grass candidate sits by its sector's centre. Choosing from those alone
## walked a herd back to the patch it had just eaten.
func _test_sleeping_herd_looks_for_grass_from_where_it_stands(a) -> void:
	# The grazer stands at (800, 800); the sector's centre is (768, 768). `near_cell` is
	# the closer of the two to the grazer, `central_cell` the closer to the centre.
	var near_cell := 12 * WIDE_COLUMNS + 14
	var central_cell := 11 * WIDE_COLUMNS + 10
	var fixture := _sleeping_grazer(414, {near_cell: 100.0, central_cell: 100.0})
	var world = fixture[1]
	var aggregate: Dictionary = fixture[3]["dormant_aggregates"][0]
	var goal: Dictionary = world._select_dormant_goal(fixture[2], aggregate)
	a.equal(str(goal.get("goal_kind", "")), "grass", "a hungry sleeping herd looks for grass")
	a.equal(world.resource_system.get_index_at_position(Vector2(goal.get("goal_position", Vector2.ZERO))), near_cell,
		"and takes the nearest, not the one by the sector's centre")
	Helpers.destroy_manager(fixture[0])


## Herds only ever grew, and a herd too big for its range starves and is never
## replaced. Past `herd.split_size` a herd divides into two neighbouring halves.
func _test_an_outgrown_herd_divides(a) -> void:
	var manager = Helpers.create_manager_with(Helpers.build_large_sector_bundle(415), 415)
	var world = manager.world_state
	var split_size := int(manager.config_bundle["species"]["herbivore"]["herd"]["split_size"])
	var small: Array = Helpers.spawn_herd(world, Vector2(2300.0, 2300.0), split_size, 1)
	var big: Array = Helpers.spawn_herd(world, Vector2(800.0, 800.0), split_size + 10, 0)
	world._split_oversized_herds()
	var stayed: Array = []
	var left: Array = []
	for grazer in big:
		if grazer.group_id == 0:
			stayed.append(grazer.position)
		else:
			left.append(grazer.position)
	a.equal([stayed.size(), left.size()], [(split_size + 10) / 2, (split_size + 10) - (split_size + 10) / 2], "an outgrown herd divides in half")
	var new_ids: Dictionary = {}
	for grazer in big:
		if grazer.group_id != 0:
			new_ids[grazer.group_id] = true
	a.equal(new_ids.keys(), [2], "the half that leaves takes the next free group id")
	# The fixture lattice is wider than tall or as wide, so the cut runs along one axis:
	# every animal that left stands beyond every animal that stayed on it.
	var stayed_max := Vector2(-INF, -INF)
	var left_min := Vector2(INF, INF)
	for position in stayed:
		stayed_max = Vector2(maxf(stayed_max.x, position.x), maxf(stayed_max.y, position.y))
	for position in left:
		left_min = Vector2(minf(left_min.x, position.x), minf(left_min.y, position.y))
	a.is_true(left_min.x >= stayed_max.x or left_min.y >= stayed_max.y, "the two halves are neighbours, not a shuffle")
	var whole := 0
	for grazer in small:
		if grazer.group_id == 1:
			whole += 1
	a.equal(whole, split_size, "a herd at its split size stays whole")
	a.is_true(world.get_group_center(2, "herbivore") != null, "the new herd is known to the group cache")
	Helpers.destroy_manager(manager)


func _test_a_sleeping_herd_divides_too(a) -> void:
	var manager = Helpers.create_manager_with(Helpers.build_large_sector_bundle(416), 416)
	var world = manager.world_state
	var split_size := int(manager.config_bundle["species"]["herbivore"]["herd"]["split_size"])
	Helpers.spawn_herd(world, Vector2(768.0, 768.0), split_size + 8, 0)
	var sector_key: Vector2i = world._get_sector_key(Vector2(768.0, 768.0))
	world._sleep_sector(sector_key)
	world._split_oversized_herds()
	var state: Dictionary = world._sector_states[sector_key]
	var counts: Array = []
	for aggregate in state["dormant_aggregates"]:
		counts.append(int(aggregate["count"]))
	counts.sort()
	a.equal(counts, [(split_size + 8) / 2, (split_size + 8) / 2], "a sleeping herd divides into two aggregates")
	a.equal(state["dormant_records"].size(), split_size + 8, "and loses no one doing it")
	Helpers.destroy_manager(manager)


## A famine among grazers must not be a feast for everything that eats meat.
func _test_a_starved_animal_leaves_little_meat(a) -> void:
	var bundle := _bundle(417)
	bundle["balance"]["carcass"]["meat_total"] = 200.0
	bundle["balance"]["carcass"]["meat_by_cause"] = {"starvation": 0.25, "thirst": 0.0}
	var manager = Helpers.create_manager_with(bundle, 417)
	var world = manager.world_state
	var size: float = world.species_registry.carcass_meat_multiplier("herbivore")
	var killed: int = world._spawn_carcass("herbivore", Vector2(100.0, 100.0), "predation", -1)
	var starved: int = world._spawn_carcass("herbivore", Vector2(120.0, 100.0), "starvation", -1)
	var parched: int = world._spawn_carcass("herbivore", Vector2(140.0, 100.0), "thirst", -1)
	a.near(float(world.carcasses[killed]["meat_total"]), 200.0 * size, 0.001, "a kill is a whole body")
	a.near(float(world.carcasses[starved]["meat_total"]), 50.0 * size, 0.001, "a starved animal is a quarter of one")
	a.equal(parched, -1, "and a cause worth nothing leaves no carcass at all")
	Helpers.destroy_manager(manager)
