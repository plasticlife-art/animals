extends RefCounted

const AgentAction := preload("res://scripts/agents/ai/agent_action.gd")
const TestHelpers := preload("res://scripts/tests/test_helpers.gd")


func run(asserts) -> void:
	_test_thirsty_herbivore(asserts)
	_test_panic_herbivore(asserts)
	_test_resting_herbivore(asserts)
	_test_sated_herbivore_does_not_graze(asserts)
	_test_hunting_predator(asserts)
	_test_scavenging_predator(asserts)
	_test_sated_predator_does_not_scavenge(asserts)
	_test_sated_predator_stops_forced_scavenge(asserts)
	_test_far_lod_panic_interrupt(asserts)
	_test_sector_dormancy_and_wake(asserts)
	_test_dormant_materializes_updated_position(asserts)
	_test_dormant_herbivore_feeding_reduces_hunger(asserts)
	_test_dormant_herbivore_drinking_reduces_thirst(asserts)
	_test_dormant_thirst_sector_moves_toward_water(asserts)
	_test_dormant_predator_goal_tracks_prey_pressure(asserts)
	_test_dormant_predator_hunts_from_feed_floor(asserts)
	_test_dormant_predator_drinking_reduces_thirst(asserts)
	_test_dormant_predation_grants_meat_for_every_kill(asserts)
	_test_dormant_predator_recovers_energy_when_idle(asserts)
	_test_dormant_aggregate_rebuild_keeps_accumulators(asserts)
	_test_hungry_predator_hunts_herd_member(asserts)
	_test_predator_energy_recovers_over_feeding_cycle(asserts)
	_test_attack_cooldown_keeps_pursuing(asserts)
	_test_predator_pair_closes_to_contact_and_breeds(asserts)
	_test_per_species_death_causes_are_counted(asserts)
	_test_dormant_stale_sector_forced_wake(asserts)
	_test_dormant_population_changes_are_counted(asserts)
	_test_snapshot_tracks_dormant_herbivore_metrics(asserts)
	_test_local_grass_fallback_without_path_budget(asserts)
	_test_grass_target_prefers_grass_underfoot(asserts)
	_test_grass_budget_miss_counted_when_local_grass_is_gone(asserts)
	_test_perf_snapshot_fields(asserts)
	_test_determinism(asserts)


func _test_thirsty_herbivore(asserts) -> void:
	var manager = TestHelpers.create_manager(31)
	var herbivore = TestHelpers.spawn_herbivore(manager.world_state, Vector2(72.0, 72.0), 0)
	herbivore.thirst = 92.0
	herbivore.hunger = 12.0
	herbivore.energy = 82.0
	TestHelpers.run_ticks(manager, 1)
	asserts.equal(herbivore.current_action, AgentAction.DRINK, "thirsty herbivore near safe water should choose drink")
	TestHelpers.destroy_manager(manager)


func _test_panic_herbivore(asserts) -> void:
	var manager = TestHelpers.create_manager(32)
	var herbivore = TestHelpers.spawn_herbivore(manager.world_state, Vector2(108.0, 96.0), 0)
	var predator = TestHelpers.spawn_predator(manager.world_state, Vector2(120.0, 96.0))
	herbivore.hunger = 90.0
	herbivore.thirst = 18.0
	herbivore.energy = 84.0
	predator.hunger = 20.0
	TestHelpers.run_ticks(manager, 1)
	asserts.equal(herbivore.current_action, AgentAction.FLEE_TO_SAFE_AREA, "herbivore near predator should not keep grazing")
	TestHelpers.destroy_manager(manager)


func _test_resting_herbivore(asserts) -> void:
	var manager = TestHelpers.create_manager(33)
	var herbivore = TestHelpers.spawn_herbivore(manager.world_state, Vector2(196.0, 196.0), 0)
	herbivore.hunger = 5.0
	herbivore.thirst = 5.0
	herbivore.energy = 6.0
	TestHelpers.run_ticks(manager, 1)
	asserts.equal(herbivore.current_action, AgentAction.REST, "tired herbivore in safe terrain should choose rest")
	TestHelpers.destroy_manager(manager)


func _test_sated_herbivore_does_not_graze(asserts) -> void:
	var manager = TestHelpers.create_manager(331)
	var herbivore = TestHelpers.spawn_herbivore(manager.world_state, Vector2(96.0, 96.0), 0)
	herbivore.hunger = 3.0
	herbivore.thirst = 3.0
	herbivore.energy = 84.0
	TestHelpers.run_ticks(manager, 1)
	asserts.is_true(herbivore.current_action != AgentAction.GRAZE, "sated herbivore should not choose graze just because grass is nearby")
	asserts.is_true(herbivore.state != "eat", "sated herbivore should not enter eat state")
	TestHelpers.destroy_manager(manager)


func _test_hunting_predator(asserts) -> void:
	var manager = TestHelpers.create_manager(34)
	var predator = TestHelpers.spawn_predator(manager.world_state, Vector2(100.0, 100.0))
	var herbivore = TestHelpers.spawn_herbivore(manager.world_state, Vector2(118.0, 100.0), 0)
	predator.hunger = 92.0
	predator.energy = 140.0
	herbivore.energy = 40.0
	TestHelpers.run_ticks(manager, 1)
	asserts.equal(predator.current_action, AgentAction.HUNT_PREY, "hungry predator with reachable prey should enter hunt flow")
	TestHelpers.destroy_manager(manager)


func _test_scavenging_predator(asserts) -> void:
	var manager = TestHelpers.create_manager(35)
	var predator = TestHelpers.spawn_predator(manager.world_state, Vector2(112.0, 112.0))
	predator.hunger = 92.0
	predator.energy = 130.0
	TestHelpers.spawn_carcass(manager.world_state, Vector2(120.0, 112.0), 90.0)
	TestHelpers.run_ticks(manager, 1)
	asserts.equal(predator.current_action, AgentAction.SCAVENGE_CARCASS, "hungry predator near carcass should choose scavenging")
	TestHelpers.destroy_manager(manager)


func _test_sated_predator_does_not_scavenge(asserts) -> void:
	var manager = TestHelpers.create_manager(351)
	var predator = TestHelpers.spawn_predator(manager.world_state, Vector2(112.0, 112.0))
	predator.hunger = 3.0
	predator.thirst = 2.0
	predator.energy = 130.0
	TestHelpers.spawn_carcass(manager.world_state, Vector2(120.0, 112.0), 90.0)
	TestHelpers.run_ticks(manager, 1)
	asserts.is_true(predator.current_action != AgentAction.SCAVENGE_CARCASS, "sated predator should not choose scavenging just because carcass is nearby")
	asserts.is_true(predator.state != "feed_carcass", "sated predator should not enter carcass feeding state")
	TestHelpers.destroy_manager(manager)


func _test_sated_predator_stops_forced_scavenge(asserts) -> void:
	var manager = TestHelpers.create_manager(352)
	var predator = TestHelpers.spawn_predator(manager.world_state, Vector2(112.0, 112.0))
	var carcass_id := TestHelpers.spawn_carcass(manager.world_state, Vector2(120.0, 112.0), 90.0)
	predator.hunger = 0.0
	predator.energy = 130.0
	predator.target_carcass_id = carcass_id
	predator.target_position = Vector2(120.0, 112.0)
	predator.current_action = AgentAction.SCAVENGE_CARCASS
	predator.state = "seek_carcass"
	predator.last_action_change_tick = manager.world_state.current_tick
	TestHelpers.run_ticks(manager, 1)
	asserts.is_true(predator.state != "feed_carcass", "forced scavenging should stop once predator is no longer hungry")
	asserts.equal(predator.target_carcass_id, -1, "sated predator should release carcass target instead of staying engaged")
	TestHelpers.destroy_manager(manager)


func _test_far_lod_panic_interrupt(asserts) -> void:
	var manager = TestHelpers.create_manager(37)
	manager.lod_enabled = true
	manager.lod_settings["headless_active_radius"] = 18.0
	var herbivore = TestHelpers.spawn_herbivore(manager.world_state, Vector2(220.0, 220.0), 0)
	var predator = TestHelpers.spawn_predator(manager.world_state, Vector2(232.0, 220.0))
	herbivore.hunger = 50.0
	herbivore.thirst = 12.0
	herbivore.energy = 88.0
	predator.hunger = 30.0
	TestHelpers.run_ticks(manager, 1)
	asserts.equal(herbivore.current_action, AgentAction.FLEE_TO_SAFE_AREA, "far-lod herbivore should still panic immediately on nearby predator")
	TestHelpers.destroy_manager(manager)


func _test_sector_dormancy_and_wake(asserts) -> void:
	var manager = TestHelpers.create_benchmark_manager(39, 80, 8, 8)
	manager.lod_enabled = true
	manager.lod_settings["headless_active_radius"] = 120.0
	manager.lod_settings["near_margin"] = 0.0
	manager.lod_settings["mid_margin"] = 280.0
	TestHelpers.run_ticks(manager, 10)
	asserts.is_true(manager.world_state.get_dormant_sector_count() > 0, "far sector should enter dormant coarse simulation")
	manager.lod_settings["headless_active_radius"] = 4000.0
	manager.lod_settings["mid_margin"] = 4000.0
	TestHelpers.run_ticks(manager, 1)
	asserts.equal(manager.world_state.get_dormant_sector_count(), 0, "dormant sector should wake when it enters the active window")
	asserts.is_true(manager.world_state.get_population_metrics().get("predator_count", 0) >= 1, "woken sector should restore predator population")
	TestHelpers.destroy_manager(manager)


func _test_dormant_materializes_updated_position(asserts) -> void:
	var manager = TestHelpers.create_manager(40)
	manager.lod_enabled = true
	manager.lod_settings["headless_active_radius"] = 18.0
	manager.lod_settings["near_margin"] = 0.0
	manager.lod_settings["mid_margin"] = 0.0
	var herbivore = TestHelpers.spawn_herbivore(manager.world_state, Vector2(20.0, 220.0), 0)
	herbivore.thirst = 95.0
	herbivore.hunger = 8.0
	herbivore.energy = 82.0
	var herbivore_id: int = herbivore.id
	var start_position: Vector2 = herbivore.position
	var sector_key: Vector2i = manager.world_state._get_sector_key(herbivore.position)
	manager.world_state._sleep_sector(sector_key)
	TestHelpers.run_ticks(manager, 7)
	var dormant_aggregate: Dictionary = _find_any_dormant_aggregate(manager.world_state, "herbivore")
	var moved_center: Vector2 = dormant_aggregate.get("center", start_position)
	asserts.is_true(moved_center.distance_to(start_position) > 8.0, "dormant aggregate should keep moving while sector sleeps")
	manager.lod_settings["headless_active_radius"] = 400.0
	manager.lod_settings["mid_margin"] = 400.0
	TestHelpers.run_ticks(manager, 1)
	var restored = manager.world_state.get_agent(herbivore_id)
	asserts.is_true(restored != null, "dormant agent should restore when sector wakes")
	asserts.is_true(restored.position.distance_to(start_position) > 8.0, "woken agent should materialize near updated coarse-sim position")
	TestHelpers.destroy_manager(manager)


func _test_dormant_herbivore_feeding_reduces_hunger(asserts) -> void:
	var manager = TestHelpers.create_manager(44)
	manager.lod_enabled = true
	manager.lod_settings["headless_active_radius"] = 18.0
	manager.lod_settings["near_margin"] = 0.0
	manager.lod_settings["mid_margin"] = 0.0
	var herbivore = TestHelpers.spawn_herbivore(manager.world_state, Vector2(20.0, 220.0), 0)
	herbivore.hunger = 78.0
	herbivore.thirst = 0.0
	herbivore.energy = 28.0
	var biomass_before: float = manager.world_state.resource_system.get_total_biomass()
	var sector_key: Vector2i = manager.world_state._get_sector_key(herbivore.position)
	manager.world_state._sleep_sector(sector_key)
	var dormant_state: Dictionary = manager.world_state._sector_states.get(sector_key, {})
	var dormant_aggregates: Array = dormant_state.get("dormant_aggregates", [])
	if not dormant_aggregates.is_empty():
		dormant_aggregates[0]["goal_kind"] = "grass"
		dormant_aggregates[0]["goal_sector"] = sector_key
		dormant_aggregates[0]["goal_position"] = herbivore.position
		dormant_aggregates[0]["last_goal_refresh_time"] = manager.world_state.current_time
		dormant_state["dormant_aggregates"] = dormant_aggregates
		manager.world_state._sector_states[sector_key] = dormant_state
	manager.world_state._apply_dormant_resource_interactions(sector_key, dormant_state, 0.75)
	manager.world_state._sector_states[sector_key] = dormant_state
	var dormant_aggregate: Dictionary = dormant_state.get("dormant_aggregates", [])[0]
	asserts.is_true(float(dormant_aggregate.get("avg_hunger", 999.0)) < 78.0, "dormant herbivore feeding should reduce average hunger")
	asserts.is_true(manager.world_state.resource_system.get_total_biomass() < biomass_before, "dormant herbivore feeding should reduce grass biomass")
	TestHelpers.destroy_manager(manager)


func _test_dormant_population_changes_are_counted(asserts) -> void:
	var manager = TestHelpers.create_manager(52)
	manager.lod_enabled = true
	manager.lod_settings["headless_active_radius"] = 18.0
	manager.lod_settings["near_margin"] = 0.0
	manager.lod_settings["mid_margin"] = 0.0
	var herd_position := Vector2(20.0, 220.0)
	for index in range(6):
		TestHelpers.spawn_herbivore(manager.world_state, herd_position + Vector2(float(index) * 3.0, 0.0), 0)
	var sector_key: Vector2i = manager.world_state._get_sector_key(herd_position)
	manager.world_state._sleep_sector(sector_key)
	var dormant_state: Dictionary = manager.world_state._sector_states.get(sector_key, {})
	var dormant_aggregates: Array = dormant_state.get("dormant_aggregates", [])
	asserts.is_true(not dormant_aggregates.is_empty(), "sleeping herd should produce a dormant aggregate")
	dormant_aggregates[0]["avg_hunger"] = 100.0
	dormant_state["dormant_aggregates"] = dormant_aggregates
	manager.world_state._sector_states[sector_key] = dormant_state

	var population_before: int = manager.world_state.get_dormant_agent_count()
	var deaths_before: int = int(manager.stats_system.counters["deaths_herbivore"])
	var starvation_before: int = int(manager.stats_system.counters["deaths_starvation"])
	manager.world_state._apply_dormant_sector_step(sector_key, dormant_state, 0.75)
	manager.world_state._sector_states[sector_key] = dormant_state
	var population_after: int = manager.world_state.get_dormant_agent_count()
	var deaths_after: int = int(manager.stats_system.counters["deaths_herbivore"])

	asserts.is_true(population_after < population_before, "starving dormant herd should lose members")
	asserts.equal(
		deaths_after - deaths_before,
		population_before - population_after,
		"dormant deaths must be counted so the population delta stays accountable"
	)
	asserts.greater(
		float(manager.stats_system.counters["deaths_starvation"]),
		float(starvation_before),
		"dormant deaths should carry their cause into the death-cause breakdown"
	)
	TestHelpers.destroy_manager(manager)


func _test_dormant_herbivore_drinking_reduces_thirst(asserts) -> void:
	var manager = TestHelpers.create_manager(45)
	manager.lod_enabled = true
	manager.lod_settings["headless_active_radius"] = 18.0
	manager.lod_settings["near_margin"] = 0.0
	manager.lod_settings["mid_margin"] = 0.0
	var herbivore = TestHelpers.spawn_herbivore(manager.world_state, Vector2(70.0, 70.0), 0)
	herbivore.hunger = 4.0
	herbivore.thirst = 96.0
	herbivore.energy = 82.0
	var sector_key: Vector2i = manager.world_state._get_sector_key(herbivore.position)
	manager.world_state._sleep_sector(sector_key)
	var dormant_state: Dictionary = manager.world_state._sector_states.get(sector_key, {})
	var dormant_aggregates: Array = dormant_state.get("dormant_aggregates", [])
	if not dormant_aggregates.is_empty():
		dormant_aggregates[0]["goal_kind"] = "water"
		dormant_aggregates[0]["goal_sector"] = sector_key
		dormant_aggregates[0]["goal_position"] = herbivore.position
		dormant_aggregates[0]["last_goal_refresh_time"] = manager.world_state.current_time
		dormant_state["dormant_aggregates"] = dormant_aggregates
		manager.world_state._sector_states[sector_key] = dormant_state
	manager.world_state._apply_dormant_resource_interactions(sector_key, dormant_state, 0.75)
	manager.world_state._sector_states[sector_key] = dormant_state
	var dormant_aggregate: Dictionary = dormant_state.get("dormant_aggregates", [])[0]
	asserts.is_true(float(dormant_aggregate.get("avg_thirst", 999.0)) < 96.0, "dormant herbivore drinking should reduce average thirst")
	TestHelpers.destroy_manager(manager)


func _test_dormant_thirst_sector_moves_toward_water(asserts) -> void:
	var manager = TestHelpers.create_manager(41)
	manager.lod_enabled = true
	manager.lod_settings["headless_active_radius"] = 18.0
	manager.lod_settings["near_margin"] = 0.0
	manager.lod_settings["mid_margin"] = 0.0
	var herbivore = TestHelpers.spawn_herbivore(manager.world_state, Vector2(20.0, 220.0), 0)
	herbivore.thirst = 96.0
	herbivore.hunger = 5.0
	herbivore.energy = 88.0
	var water_target: Vector2 = Vector2(64.0, 64.0)
	var start_distance: float = herbivore.position.distance_to(water_target)
	var sector_key: Vector2i = manager.world_state._get_sector_key(herbivore.position)
	manager.world_state._sleep_sector(sector_key)
	TestHelpers.run_ticks(manager, 7)
	var dormant_aggregate: Dictionary = _find_any_dormant_aggregate(manager.world_state, "herbivore")
	asserts.equal(str(dormant_aggregate.get("goal_kind", "")), "water", "thirsty dormant herbivore should pick water as coarse goal")
	var moved_distance := Vector2(dormant_aggregate.get("center", herbivore.position)).distance_to(water_target)
	asserts.is_true(moved_distance < start_distance, "thirsty dormant herbivore should move closer to water while asleep")
	TestHelpers.destroy_manager(manager)


func _test_dormant_predator_goal_tracks_prey_pressure(asserts) -> void:
	var manager = TestHelpers.create_manager(42)
	manager.lod_enabled = true
	manager.lod_settings["headless_active_radius"] = 18.0
	manager.lod_settings["near_margin"] = 0.0
	manager.lod_settings["mid_margin"] = 0.0
	var predator = TestHelpers.spawn_predator(manager.world_state, Vector2(220.0, 220.0))
	var herbivore = TestHelpers.spawn_herbivore(manager.world_state, Vector2(148.0, 220.0), 0)
	predator.hunger = 96.0
	predator.energy = 140.0
	herbivore.hunger = 8.0
	herbivore.thirst = 8.0
	var predator_sector: Vector2i = manager.world_state._get_sector_key(predator.position)
	var herbivore_sector: Vector2i = manager.world_state._get_sector_key(herbivore.position)
	manager.world_state._sleep_sector(predator_sector)
	manager.world_state._sleep_sector(herbivore_sector)
	TestHelpers.run_ticks(manager, 7)
	var predator_aggregate := _find_any_dormant_aggregate(manager.world_state, "predator")
	asserts.is_true(not predator_aggregate.is_empty(), "predator aggregate should remain represented in dormant sectors")
	asserts.equal(str(predator_aggregate.get("goal_kind", "")), "hunt", "hungry dormant predator should target prey pressure")
	TestHelpers.destroy_manager(manager)


func _test_dormant_stale_sector_forced_wake(asserts) -> void:
	var manager = TestHelpers.create_manager(43)
	manager.lod_enabled = true
	manager.lod_settings["headless_active_radius"] = 18.0
	manager.lod_settings["near_margin"] = 0.0
	manager.lod_settings["mid_margin"] = 0.0
	var herbivore = TestHelpers.spawn_herbivore(manager.world_state, Vector2(220.0, 220.0), 0)
	var sector_key: Vector2i = manager.world_state._get_sector_key(herbivore.position)
	manager.world_state._sleep_sector(sector_key)
	var dormant_state: Dictionary = manager.world_state._sector_states.get(sector_key, {})
	var dormant_aggregates: Array = dormant_state.get("dormant_aggregates", [])
	if not dormant_aggregates.is_empty():
		dormant_aggregates[0]["stale_time"] = manager.world_state._dormant_stale_wake_seconds + 0.5
		dormant_state["dormant_aggregates"] = dormant_aggregates
		manager.world_state._sector_states[sector_key] = dormant_state
	TestHelpers.run_ticks(manager, 1)
	asserts.is_true(int(manager.world_state.get_performance_counters().get("dormant_forced_wakeups", 0)) >= 1, "forced wake counter should track stale-sector reification")
	asserts.is_true(int(manager.world_state.get_performance_counters().get("sector_wakeups", 0)) >= 1, "stale dormant sector should be reified at least once by wake budget")
	TestHelpers.destroy_manager(manager)


func _test_snapshot_tracks_dormant_herbivore_metrics(asserts) -> void:
	var manager = TestHelpers.create_manager(46)
	manager.lod_enabled = true
	manager.lod_settings["headless_active_radius"] = 18.0
	manager.lod_settings["near_margin"] = 0.0
	manager.lod_settings["mid_margin"] = 0.0
	for position in [Vector2(20.0, 220.0), Vector2(220.0, 220.0)]:
		var herbivore = TestHelpers.spawn_herbivore(manager.world_state, position, 0)
		herbivore.hunger = 76.0
		herbivore.thirst = 0.0
		herbivore.energy = 34.0
		manager.world_state._sleep_sector(manager.world_state._get_sector_key(position))
	TestHelpers.run_ticks(manager, 10)
	var snapshot: Dictionary = manager.stats_system.get_snapshot()
	asserts.is_true(float(snapshot.get("herbivore_hunger_reduced_total", 0.0)) > 0.0, "snapshot should accumulate herbivore hunger reduction across dormant ticks")
	asserts.is_true(int(snapshot.get("dormant_steps_total", 0)) > 0, "snapshot should accumulate dormant steps across sample window")
	asserts.is_true(int(snapshot.get("dormant_herbivore_count", 0)) > 0, "snapshot should expose dormant herbivore split")
	asserts.is_true(snapshot.has("starvation_risk_herbivore_count"), "snapshot should expose herbivore starvation risk count")
	TestHelpers.destroy_manager(manager)


func _test_local_grass_fallback_without_path_budget(asserts) -> void:
	var manager = TestHelpers.create_manager(451)
	var herbivore = TestHelpers.spawn_herbivore(manager.world_state, Vector2(96.0, 96.0), 0)
	herbivore.hunger = 24.0
	manager.world_state._path_budget_remaining = 0
	manager.world_state._new_path_budget_remaining = 0
	var grass_target: Dictionary = manager.world_state._find_grass_target_for_agent(herbivore)
	asserts.is_true(not grass_target.is_empty(), "herbivore should still get a nearby grass target when path budget is exhausted")
	var reach: float = manager.world_state.terrain_system.cell_size * float(manager.world_state._grass_local_reach_cells) + manager.world_state.resource_system.cell_size
	asserts.is_true(
		herbivore.position.distance_to(grass_target.get("center", Vector2.ZERO)) <= reach,
		"grass target resolved without path budget should be within walking reach"
	)
	TestHelpers.destroy_manager(manager)


## A herbivore standing in grass must graze it rather than being routed to whichever cell
## the sector cache happens to hold, which is chosen relative to the sector centre and is
## therefore the same distant cell for every agent in that sector.
func _test_grass_target_prefers_grass_underfoot(asserts) -> void:
	var manager = TestHelpers.create_manager(452)
	var herbivore = TestHelpers.spawn_herbivore(manager.world_state, Vector2(96.0, 96.0), 0)
	herbivore.hunger = 24.0
	manager.world_state._prepare_navigation_budget()
	var grass_target: Dictionary = manager.world_state._find_grass_target_for_agent(herbivore)
	asserts.is_true(not grass_target.is_empty(), "herbivore standing in grass should resolve a grass target")
	var reach: float = manager.world_state.terrain_system.cell_size * float(manager.world_state._grass_local_reach_cells) + manager.world_state.resource_system.cell_size
	asserts.is_true(
		herbivore.position.distance_to(grass_target.get("center", Vector2.ZERO)) <= reach,
		"grass target should be the grass underfoot, not a distant sector candidate"
	)
	TestHelpers.destroy_manager(manager)


## Once the nearby cells are grazed out the agent has to travel, and that is when the
## path budget becomes the limit worth counting.
func _test_grass_budget_miss_counted_when_local_grass_is_gone(asserts) -> void:
	var manager = TestHelpers.create_manager(453)
	var world = manager.world_state
	var herbivore = TestHelpers.spawn_herbivore(world, Vector2(96.0, 96.0), 0)
	herbivore.hunger = 24.0
	var start_index: int = world.terrain_system.find_nearest_walkable_index(world.terrain_system.get_index_from_position(herbivore.position))
	for cell_index in world._collect_walk_reachable_cells(start_index, world._grass_local_reach_cells).keys():
		world.resource_system.consume_cell(int(cell_index), world.resource_system.max_biomass)
	world._path_budget_remaining = 0
	world._new_path_budget_remaining = 0
	var grass_target: Dictionary = world._find_grass_target_for_agent(herbivore)
	asserts.is_true(grass_target.is_empty(), "no target should be resolved when local grass is gone and no path budget remains")
	asserts.is_true(
		float(world.performance_counters.get("grass_target_budget_misses", 0)) >= 1.0,
		"grass budget miss counter should increase when a distant candidate cannot be pathed"
	)
	TestHelpers.destroy_manager(manager)


func _test_perf_snapshot_fields(asserts) -> void:
	var manager = TestHelpers.create_manager(38)
	TestHelpers.spawn_herbivore(manager.world_state, Vector2(96.0, 96.0), 0)
	TestHelpers.run_ticks(manager, 1)
	var snapshot: Dictionary = manager.stats_system.get_snapshot()
	asserts.is_true(snapshot.has("agents_full_tick"), "snapshot should expose agents_full_tick")
	asserts.is_true(snapshot.has("ai_context_build_ms"), "snapshot should expose ai_context_build_ms")
	asserts.is_true(snapshot.has("pathfind_calls"), "snapshot should expose pathfind_calls")
	asserts.is_true(snapshot.has("spatial_update_ms"), "snapshot should expose spatial_update_ms")
	asserts.is_true(snapshot.has("dormant_migrations"), "snapshot should expose dormant_migrations")
	asserts.is_true(snapshot.has("dormant_forced_wakeups"), "snapshot should expose dormant_forced_wakeups")
	asserts.is_true(snapshot.has("grass_consumed_total"), "snapshot should expose accumulated grass consumption")
	asserts.is_true(snapshot.has("herbivore_hunger_reduced_total"), "snapshot should expose accumulated herbivore hunger reduction")
	TestHelpers.destroy_manager(manager)


func _test_determinism(asserts) -> void:
	var manager_a = TestHelpers.create_manager(36)
	var herbivore_a = TestHelpers.spawn_herbivore(manager_a.world_state, Vector2(104.0, 104.0), 0)
	var predator_a = TestHelpers.spawn_predator(manager_a.world_state, Vector2(132.0, 104.0))
	herbivore_a.hunger = 62.0
	herbivore_a.thirst = 24.0
	herbivore_a.energy = 78.0
	predator_a.hunger = 74.0
	predator_a.energy = 135.0
	var trace_a := TestHelpers.capture_trace(manager_a, [herbivore_a.id, predator_a.id], 18)

	var manager_b = TestHelpers.create_manager(36)
	var herbivore_b = TestHelpers.spawn_herbivore(manager_b.world_state, Vector2(104.0, 104.0), 0)
	var predator_b = TestHelpers.spawn_predator(manager_b.world_state, Vector2(132.0, 104.0))
	herbivore_b.hunger = 62.0
	herbivore_b.thirst = 24.0
	herbivore_b.energy = 78.0
	predator_b.hunger = 74.0
	predator_b.energy = 135.0
	var trace_b := TestHelpers.capture_trace(manager_b, [herbivore_b.id, predator_b.id], 18)

	asserts.equal(JSON.stringify(trace_a), JSON.stringify(trace_b), "same seed and setup should produce identical action/state traces")
	TestHelpers.destroy_manager(manager_a)
	TestHelpers.destroy_manager(manager_b)


func _find_any_dormant_aggregate(world, species_type: String) -> Dictionary:
	for sector_state in world._sector_states.values():
		if not bool(sector_state.get("dormant", false)):
			continue
		for aggregate in sector_state.get("dormant_aggregates", []):
			if str(aggregate.get("species_type", "")) == species_type:
				return aggregate
	return {}


## Sleeps the sector holding `position` and returns its state plus the aggregate for
## `species_type`, with `goal_kind` forced so the resource-interaction branch under test
## is the one that runs.
static func _sleep_with_goal(world, position: Vector2, species_type: String, goal_kind: String, extra: Dictionary = {}) -> Array:
	var sector_key: Vector2i = world._get_sector_key(position)
	world._sleep_sector(sector_key)
	var dormant_state: Dictionary = world._sector_states.get(sector_key, {})
	for aggregate in dormant_state.get("dormant_aggregates", []):
		if str(aggregate.get("species_type", "")) != species_type:
			continue
		aggregate["goal_kind"] = goal_kind
		aggregate["goal_sector"] = sector_key
		aggregate["goal_position"] = position
		aggregate["last_goal_refresh_time"] = world.current_time
		for key in extra.keys():
			aggregate[key] = extra[key]
		world._sector_states[sector_key] = dormant_state
		return [sector_key, dormant_state, aggregate]
	return [sector_key, dormant_state, {}]


func _test_dormant_predator_hunts_from_feed_floor(asserts) -> void:
	var manager = TestHelpers.create_manager(61)
	manager.lod_enabled = true
	var herd_position := Vector2(220.0, 20.0)
	for index in range(6):
		TestHelpers.spawn_herbivore(manager.world_state, herd_position + Vector2(float(index) * 3.0, 0.0), 0)
	var predator = TestHelpers.spawn_predator(manager.world_state, Vector2(20.0, 220.0))
	# Above `feed_hunger_floor` (12) but far below the old `critical_hunger * 0.9` gate of
	# 54, which left too little of the hunger clock to reach prey a sector away.
	predator.hunger = 20.0
	predator.thirst = 0.0
	var sector_key: Vector2i = manager.world_state._get_sector_key(predator.position)
	manager.world_state._refresh_prey_pressure_sectors()
	manager.world_state._sleep_sector(sector_key)
	var dormant_state: Dictionary = manager.world_state._sector_states.get(sector_key, {})
	var aggregates: Array = dormant_state.get("dormant_aggregates", [])
	asserts.is_true(not aggregates.is_empty(), "predator sector should produce a dormant aggregate")
	if aggregates.is_empty():
		TestHelpers.destroy_manager(manager)
		return
	var goal: Dictionary = manager.world_state._select_dormant_goal(sector_key, aggregates[0])
	asserts.equal(str(goal.get("goal_kind", "")), "hunt", "mildly hungry dormant predator should already head for prey")
	TestHelpers.destroy_manager(manager)


func _test_dormant_predator_drinking_reduces_thirst(asserts) -> void:
	var manager = TestHelpers.create_manager(62)
	manager.lod_enabled = true
	var predator = TestHelpers.spawn_predator(manager.world_state, Vector2(20.0, 220.0))
	predator.thirst = 95.0
	predator.hunger = 0.0
	var slept: Array = _sleep_with_goal(manager.world_state, predator.position, "predator", "water")
	manager.world_state._apply_dormant_resource_interactions(slept[0], slept[1], 0.75)
	asserts.is_true(float(slept[2].get("avg_thirst", 999.0)) < 95.0, "dormant predator reaching water should drink")
	TestHelpers.destroy_manager(manager)


func _test_dormant_predation_grants_meat_for_every_kill(asserts) -> void:
	var manager = TestHelpers.create_manager(63)
	manager.lod_enabled = true
	var herd_position := Vector2(20.0, 220.0)
	for index in range(8):
		TestHelpers.spawn_herbivore(manager.world_state, herd_position + Vector2(float(index) * 2.0, 0.0), 0)
	var predator = TestHelpers.spawn_predator(manager.world_state, herd_position + Vector2(4.0, 4.0))
	predator.hunger = 60.0
	# The shipped rate is deliberately slow, so drive it hard enough to resolve a kill in
	# one step. Setting it here also proves the knob is actually read.
	manager.world_state.config_bundle["balance"]["dormant_ecology"]["kill_rate_per_prey_per_second"] = 0.5
	var slept: Array = _sleep_with_goal(manager.world_state, herd_position, "predator", "hunt")
	var sector_state: Dictionary = slept[1]
	var herbivores_before := 0
	for aggregate in sector_state.get("dormant_aggregates", []):
		if str(aggregate.get("species_type", "")) == "herbivore":
			herbivores_before += int(aggregate.get("count", 0))
	var meat_total := float(manager.world_state.config_bundle["balance"]["carcass"]["meat_total"])
	manager.world_state._resolve_dormant_predation(slept[0], sector_state, sector_state.get("dormant_aggregates", []), 0.75)
	var herbivores_after := 0
	for aggregate in sector_state.get("dormant_aggregates", []):
		if str(aggregate.get("species_type", "")) == "herbivore":
			herbivores_after += int(aggregate.get("count", 0))
	var kills: int = herbivores_before - herbivores_after
	asserts.greater(kills, 0, "a hunting dormant predator among prey should make a kill")
	var counters: Dictionary = manager.world_state.get_performance_counters()
	asserts.equal(int(counters.get("dormant_predation_kills", -1)), kills, "counted kills should match the herbivores removed")
	# The invariant: meat exists only because something died, in exact proportion.
	asserts.equal(float(counters.get("dormant_meat_granted", -1.0)), float(kills) * meat_total, "every kill should grant exactly one carcass worth of meat")
	asserts.equal(float(sector_state.get("dormant_meat_pool", -1.0)), float(kills) * meat_total, "the granted meat should be in this sector's pool")
	TestHelpers.destroy_manager(manager)


func _test_dormant_predator_recovers_energy_when_idle(asserts) -> void:
	var manager = TestHelpers.create_manager(64)
	manager.lod_enabled = true
	var predator = TestHelpers.spawn_predator(manager.world_state, Vector2(20.0, 220.0))
	predator.hunger = 0.0
	predator.thirst = 0.0
	predator.energy = 40.0
	var slept: Array = _sleep_with_goal(manager.world_state, predator.position, "predator", "wander")
	var sector_key: Vector2i = slept[0]
	var aggregate: Dictionary = slept[2]
	aggregate["avg_hunger"] = 0.0
	aggregate["avg_thirst"] = 0.0
	aggregate["avg_energy"] = 20.0
	manager.world_state._apply_dormant_metabolism_to_aggregate(sector_key, aggregate, 0.75)
	# The dormant path only ever drained energy, so a dormant predator could never reach
	# `reproduction.energy_threshold` and dormant breeding was impossible.
	asserts.greater(float(aggregate.get("avg_energy", 0.0)), 20.0, "an idle, fed dormant predator should recover energy")

	# Idle rest stops below the breeding reserve: only actually feeding may carry an
	# aggregate up to `reproduction.energy_threshold`, so a dormant litter still has to be
	# paid for with food.
	var breeding_reserve := float(predator.reproduction.get("energy_threshold", 92.0))
	aggregate["avg_energy"] = 20.0
	for _step in range(60):
		aggregate["avg_hunger"] = 0.0
		aggregate["avg_thirst"] = 0.0
		manager.world_state._apply_dormant_metabolism_to_aggregate(sector_key, aggregate, 0.75)
	asserts.is_true(float(aggregate.get("avg_energy", 0.0)) < breeding_reserve, "idle rest alone should never reach the breeding reserve")
	TestHelpers.destroy_manager(manager)


func _test_hungry_predator_hunts_herd_member(asserts) -> void:
	var manager = TestHelpers.create_manager(65)
	var predator = TestHelpers.spawn_predator(manager.world_state, Vector2(100.0, 100.0))
	# A packed herd: `_prey_isolation` reports 0 here, which is the case where `patrol`
	# used to outscore `hunt_prey` until hunger was within a point or two of lethal.
	for index in range(6):
		TestHelpers.spawn_herbivore(manager.world_state, Vector2(118.0 + float(index) * 4.0, 100.0), 0)
	predator.hunger = 20.0
	predator.energy = 140.0
	TestHelpers.run_ticks(manager, 1)
	asserts.equal(predator.current_action, AgentAction.HUNT_PREY, "a mildly hungry predator should hunt a healthy herd animal")
	TestHelpers.destroy_manager(manager)


func _test_predator_energy_recovers_over_feeding_cycle(asserts) -> void:
	var manager = TestHelpers.create_manager(66)
	var predator = TestHelpers.spawn_predator(manager.world_state, Vector2(112.0, 112.0))
	predator.hunger = 60.0
	predator.energy = 20.0
	TestHelpers.spawn_carcass(manager.world_state, Vector2(118.0, 112.0), 150.0)
	TestHelpers.run_ticks(manager, 60)
	# Feeding used to stop at `feed_stop_hunger_floor`, capping intake at the hunger the
	# predator arrived with. That made every cycle net-negative on energy and put the
	# breeding threshold permanently out of reach.
	asserts.greater(predator.energy, float(predator.reproduction.get("energy_threshold", 92.0)), "gorging on a full carcass should carry a predator past its breeding reserve")
	TestHelpers.destroy_manager(manager)


## The rendezvous threshold has to clear the bodies. `_resolve_agent_overlap()` holds two
## predators apart at the sum of their radii - about 30 px - so the 18 px this used to ask
## for could never be reached: the pair pressed into each other forever, one of them being
## shoved backwards on every tick, and no predator was ever born inside an awake sector.
func _test_predator_pair_closes_to_contact_and_breeds(asserts) -> void:
	var manager = TestHelpers.create_manager(68)
	var world = manager.world_state
	var male = TestHelpers.spawn_predator(world, Vector2(100.0, 100.0))
	var female = TestHelpers.spawn_predator(world, Vector2(140.0, 100.0))
	female.sex = AgentBase.SEX_FEMALE
	for parent in [male, female]:
		parent.reproduction_cooldown = 0.0
		parent.hunger = 0.0
		parent.thirst = 0.0
		parent.energy = 140.0

	var separation: float = male.position.distance_to(female.position)
	asserts.greater(separation, male.mate_contact_distance(female), "the pair should start further apart than contact, so they have to close the gap")

	TestHelpers.run_ticks(manager, 60)
	var predators: int = 0
	for agent in world.get_living_agents():
		if agent.species_type == "predator":
			predators += 1
	asserts.equal(predators, 3, "a fed, mature predator pair should meet and produce one cub")
	TestHelpers.destroy_manager(manager)


func _test_attack_cooldown_keeps_pursuing(asserts) -> void:
	var manager = TestHelpers.create_manager(67)
	var predator = TestHelpers.spawn_predator(manager.world_state, Vector2(100.0, 100.0))
	var herbivore = TestHelpers.spawn_herbivore(manager.world_state, Vector2(104.0, 100.0), 0)
	predator.hunger = 80.0
	predator.energy = 140.0
	predator.target_agent_id = herbivore.id
	predator.set_state("attack", manager.world_state.current_tick)
	predator.attack_cooldown = 0.5
	var position_before: Vector2 = predator.position
	TestHelpers.run_ticks(manager, 1)
	# Standing still through the cooldown handed the prey a free second of sprinting.
	asserts.is_true(predator.position.distance_to(position_before) > 0.0, "a predator on attack cooldown should keep closing on its prey")
	TestHelpers.destroy_manager(manager)


func _test_per_species_death_causes_are_counted(asserts) -> void:
	var manager = TestHelpers.create_manager(68)
	var predator = TestHelpers.spawn_predator(manager.world_state, Vector2(100.0, 100.0))
	var herbivore = TestHelpers.spawn_herbivore(manager.world_state, Vector2(180.0, 180.0), 0)
	manager.world_state.kill_agent(predator, "starvation")
	manager.world_state.kill_agent(herbivore, "thirst")
	TestHelpers.run_ticks(manager, 1)
	var counters: Dictionary = manager.stats_system.counters
	asserts.equal(int(counters.get("deaths_starvation_predator", -1)), 1, "a starved predator should be counted against its own species")
	asserts.equal(int(counters.get("deaths_thirst_herbivore", -1)), 1, "a herbivore lost to thirst should be counted against its own species")
	asserts.equal(int(counters.get("deaths_starvation_herbivore", -1)), 0, "the split should not leak across species")
	TestHelpers.destroy_manager(manager)


func _test_dormant_aggregate_rebuild_keeps_accumulators(asserts) -> void:
	var manager = TestHelpers.create_manager(69)
	manager.lod_enabled = true
	var herd_position := Vector2(20.0, 220.0)
	for index in range(4):
		TestHelpers.spawn_herbivore(manager.world_state, herd_position + Vector2(float(index) * 3.0, 0.0), 0)
	var slept: Array = _sleep_with_goal(manager.world_state, herd_position, "herbivore", "grass", {
		"birth_debt": 0.4,
		"starvation_debt": 0.3,
		"carcass_id": 11,
	})
	var sector_key: Vector2i = slept[0]
	var sector_state: Dictionary = slept[1]
	# Aggregates are rebuilt from records on every dormant step. Fractional accumulators that
	# do not survive the rebuild are silently floored to zero every step, which suppresses any
	# rate below one event per step - births and need-deaths for every small group.
	var previous_map: Dictionary = manager.world_state._build_dormant_aggregate_previous_map(sector_state.get("dormant_aggregates", []))
	var rebuilt: Array = manager.world_state._build_dormant_aggregates(sector_state.get("dormant_records", []), sector_key, previous_map)
	asserts.is_true(not rebuilt.is_empty(), "rebuilding should produce an aggregate")
	if rebuilt.is_empty():
		TestHelpers.destroy_manager(manager)
		return
	asserts.equal(float(rebuilt[0].get("birth_debt", -1.0)), 0.4, "birth debt should survive an aggregate rebuild")
	asserts.equal(float(rebuilt[0].get("starvation_debt", -1.0)), 0.3, "starvation debt should survive an aggregate rebuild")
	asserts.equal(int(rebuilt[0].get("carcass_id", -1)), 11, "the carcass a goal refers to should survive an aggregate rebuild")
	TestHelpers.destroy_manager(manager)
