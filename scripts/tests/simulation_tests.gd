extends RefCounted

const AgentAction := preload("res://scripts/agents/ai/agent_action.gd")
const TestHelpers := preload("res://scripts/tests/test_helpers.gd")
const TelemetryLoggerScript := preload("res://scripts/stats/telemetry_logger.gd")


func run(asserts) -> void:
	_test_thirsty_herbivore(asserts)
	_test_panic_herbivore(asserts)
	_test_resting_herbivore(asserts)
	_test_sated_herbivore_does_not_graze(asserts)
	_test_hunting_predator(asserts)
	_test_scavenging_predator(asserts)
	_test_sated_predator_does_not_scavenge(asserts)
	_test_sated_predator_stops_forced_scavenge(asserts)
	_test_starving_predator_walks_towards_distant_prey(asserts)
	_test_starving_predator_prefers_carcass_over_distant_hunt(asserts)
	_test_scavenger_feeds_on_carcass(asserts)
	_test_scavenger_is_not_a_threat_to_the_herd(asserts)
	_test_every_species_gets_counted(asserts)
	_test_stale_carrion_is_the_scavengers_alone(asserts)
	_test_scavenger_eats_what_the_predator_refused(asserts)
	_test_far_lod_panic_interrupt(asserts)
	_test_sector_dormancy_and_wake(asserts)
	_test_dormant_wake_restores_recorded_position(asserts)
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
	_test_determinism_with_lod_and_dormancy(asserts)
	_test_dormant_path_leaves_rng_untouched(asserts)
	_test_worker_ticks_match_inline_ticks(asserts)
	_test_snapshot_is_shared_read_only(asserts)
	_test_metrics_csv_keeps_columns(asserts)


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


## A starving predator used to lose its patrol goal exactly when it needed one.
## `Predator._resolve_patrol_goal()` scaled the search radius by the hunger clock,
## so past roughly hunger 65 no herd on a large map was still inside it, the goal
## came back empty, and patrol fell through to an undirected wander for the last
## half minute of the animal's life. Prey far beyond what the clock can pay for
## still has to produce a direction.
func _test_starving_predator_walks_towards_distant_prey(asserts) -> void:
	var bundle: Dictionary = TestHelpers.build_test_bundle(91)
	# Wide enough that the herd sits outside both vision (480) and the reach floor
	# (vision x 2), which is what the old code fell back to.
	bundle["world"]["world_size"] = {"x": 2048.0, "y": 512.0}
	bundle["world"]["simulation_lod"]["sector_size"] = 256.0
	# The census this reads is per sector, and dormancy would replace the herd with
	# an aggregate; the fixture is about the live path.
	bundle["debug"]["lod"]["enabled"] = false
	var manager = TestHelpers.create_manager_with(bundle, 91)
	for index in range(8):
		TestHelpers.spawn_herbivore(manager.world_state, Vector2(1800.0 + float(index) * 12.0, 256.0), 0)
	var predator = TestHelpers.spawn_predator(manager.world_state, Vector2(200.0, 256.0))
	predator.hunger = 92.0
	predator.thirst = 0.0
	predator.energy = 120.0
	var start_x: float = predator.position.x
	TestHelpers.run_ticks(manager, 60)
	asserts.is_true(predator.position.x > start_x + 100.0,
		"starving predator should walk towards the only herd on the map instead of wandering")
	TestHelpers.destroy_manager(manager)


## `hunt_prey` carried a critical-hunger knee and `scavenge_carcass` did not, so
## crossing the starvation line raised the score of the 0.38-chance chase and left
## the certain meal underfoot untouched - and `stickiness_bonus` then held the
## predator on it.
func _test_starving_predator_prefers_carcass_over_distant_hunt(asserts) -> void:
	var manager = TestHelpers.create_manager(77)
	var predator = TestHelpers.spawn_predator(manager.world_state, Vector2(112.0, 112.0))
	predator.hunger = 96.0
	predator.thirst = 0.0
	predator.energy = 120.0
	TestHelpers.spawn_carcass(manager.world_state, Vector2(124.0, 112.0))
	# In sight, but further off than the carcass.
	TestHelpers.spawn_herbivore(manager.world_state, Vector2(112.0, 208.0), 0)
	TestHelpers.run_ticks(manager, 1)
	asserts.equal(predator.current_action, AgentAction.SCAVENGE_CARCASS,
		"starving predator should take the carcass at its feet over a more distant chase")
	TestHelpers.destroy_manager(manager)


## The scavenger runs the herd behaviour with a different food source, so this is
## really asking whether `AgentBase.scavenge_or_feed()` reaches a species that is
## not the predator it was written for.
func _test_scavenger_feeds_on_carcass(asserts) -> void:
	var manager = TestHelpers.create_manager(412)
	var scavenger = TestHelpers.spawn_species(manager.world_state, "scavenger", Vector2(112.0, 112.0))
	scavenger.hunger = 80.0
	scavenger.thirst = 0.0
	var carcass_id := TestHelpers.spawn_carcass(manager.world_state, Vector2(120.0, 112.0), 90.0)
	var meat_before: float = float(manager.world_state.get_carcass(carcass_id).get("meat_remaining", 0.0))
	var hunger_before: float = scavenger.hunger
	TestHelpers.run_ticks(manager, 6)
	asserts.equal(scavenger.current_action, AgentAction.SCAVENGE_CARCASS,
		"a hungry scavenger beside a carcass should choose to scavenge")
	asserts.is_true(float(manager.world_state.get_carcass(carcass_id).get("meat_remaining", 0.0)) < meat_before,
		"scavenging should actually consume meat from the shared carcass ledger")
	asserts.is_true(scavenger.hunger < hunger_before, "eating should reduce the scavenger's hunger")
	TestHelpers.destroy_manager(manager)


## `_register_sector_presence()` filed anything that was not a herbivore as a
## predator, threat score included, so a scavenger would have stampeded the herds
## it feeds beside. The rule is now `role.is_threat`.
func _test_scavenger_is_not_a_threat_to_the_herd(asserts) -> void:
	var manager = TestHelpers.create_manager(413)
	var world = manager.world_state
	var herbivore = TestHelpers.spawn_herbivore(world, Vector2(112.0, 112.0), 0)
	herbivore.hunger = 40.0
	herbivore.thirst = 4.0
	herbivore.energy = 80.0
	TestHelpers.spawn_species(world, "scavenger", Vector2(120.0, 112.0))
	TestHelpers.run_ticks(manager, 1)
	var sector_state: Dictionary = world._sector_states.get(world._get_sector_key(herbivore.position), {})
	asserts.equal(float(sector_state.get("threat_score", -1.0)), 0.0,
		"a scavenger must not raise the sector threat score")
	asserts.is_true(herbivore.current_action != AgentAction.FLEE_TO_SAFE_AREA,
		"a herbivore should not panic at a scavenger standing next to it")
	TestHelpers.destroy_manager(manager)


## The births/deaths tallies used to be an if/elif over two names with no else, so
## a third species was counted nowhere and nothing reported it.
func _test_every_species_gets_counted(asserts) -> void:
	var manager = TestHelpers.create_manager(414)
	var world = manager.world_state
	for species_id in world.species_registry.ids():
		asserts.is_true(manager.stats_system.counters.has("deaths_%s" % species_id),
			"stats should carry a death counter for %s" % species_id)
		var agent = TestHelpers.spawn_species(world, species_id, Vector2(112.0, 112.0))
		var before: int = int(manager.stats_system.counters["deaths_%s" % species_id])
		world.kill_agent(agent, "starvation")
		TestHelpers.run_ticks(manager, 1)
		asserts.equal(int(manager.stats_system.counters["deaths_%s" % species_id]), before + 1,
			"a %s death should reach the counters" % species_id)
	TestHelpers.destroy_manager(manager)


## The two carrion eaters are separated by freshness, not by distance or speed.
## Sharing one pool meant the bigger, faster predator won every body, so raising
## `carcass.ttl_seconds` to feed the flock fed the predator boom instead - the
## measured result was 292 predators against 193 at the same moment.
func _test_stale_carrion_is_the_scavengers_alone(asserts) -> void:
	var manager = TestHelpers.create_manager(415)
	var world = manager.world_state
	var carcass_id := TestHelpers.spawn_carcass(world, Vector2(120.0, 112.0), 90.0)
	# Older than the predator's `role.carrion_max_age_seconds`, still inside the
	# fixture carcass's own long TTL, so it is present but stale.
	world.carcasses[carcass_id]["created_at"] = world.current_time - 60.0

	var predator = TestHelpers.spawn_predator(world, Vector2(112.0, 112.0))
	predator.hunger = 96.0
	predator.thirst = 0.0
	predator.energy = 120.0
	# Far enough not to panic: `predator.role.eats_species` now lists the flock, so
	# a bird beside a fox flees rather than eats, and this fixture is about the
	# freshness rule rather than about that.
	var scavenger = TestHelpers.spawn_species(world, "scavenger", Vector2(900.0, 900.0))
	scavenger.hunger = 96.0
	scavenger.thirst = 0.0

	asserts.is_true(not predator.accepts_carcass(world, world.get_carcass(carcass_id)),
		"a predator should refuse carrion past its freshness limit")
	asserts.is_true(scavenger.accepts_carcass(world, world.get_carcass(carcass_id)),
		"a scavenger should accept carrion of any age")

	TestHelpers.run_ticks(manager, 4)
	asserts.is_true(predator.state != "feed_carcass",
		"a predator should not feed on carrion it has refused")
	asserts.equal(predator.target_carcass_id, -1,
		"a predator should hold no target on a body it will not eat")
	TestHelpers.destroy_manager(manager)


## The other half of the same rule, in a world with no fox in it: the body the
## predator walked away from is still a meal for the bird.
func _test_scavenger_eats_what_the_predator_refused(asserts) -> void:
	var manager = TestHelpers.create_manager(416)
	var world = manager.world_state
	var carcass_id := TestHelpers.spawn_carcass(world, Vector2(120.0, 112.0), 90.0)
	world.carcasses[carcass_id]["created_at"] = world.current_time - 60.0
	var scavenger = TestHelpers.spawn_species(world, "scavenger", Vector2(112.0, 112.0))
	scavenger.hunger = 96.0
	scavenger.thirst = 0.0
	var meat_before: float = float(world.get_carcass(carcass_id).get("meat_remaining", 0.0))
	TestHelpers.run_ticks(manager, 6)
	asserts.equal(scavenger.current_action, AgentAction.SCAVENGE_CARCASS,
		"the scavenger should take a body too stale for any predator")
	asserts.is_true(float(world.get_carcass(carcass_id).get("meat_remaining", 0.0)) < meat_before,
		"stale carrion should actually feed the scavenger")
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


func _test_dormant_wake_restores_recorded_position(asserts) -> void:
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
	var record_sector := Vector2i.ZERO
	var record: Dictionary = {}
	for key in manager.world_state._sector_states.keys():
		for candidate in manager.world_state._sector_states[key].get("dormant_records", []):
			if int(candidate.get("id", -1)) == herbivore_id:
				record_sector = key
				record = candidate
	asserts.is_true(not record.is_empty(), "the sleeping herbivore should still have a dormant record")
	var recorded_position: Vector2 = record.get("position", Vector2.ZERO)
	var recorded_age := float(record.get("age", -1.0))
	manager.world_state._wake_sector(record_sector)
	var restored = manager.world_state.get_agent(herbivore_id)
	asserts.is_true(restored != null, "dormant agent should restore when sector wakes")
	if restored != null:
		asserts.equal(restored.position, recorded_position, "a woken animal stands exactly where its record was")
		asserts.equal(restored.age, recorded_age, "waking keeps the animal's own age, not its group's mean")
		asserts.is_true(restored.position.distance_to(start_position) > 8.0, "the animal travelled with its herd while asleep")
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
	# Dormant sectors now have deterministic phase offsets, so a five-tick stats
	# window can legitimately fall between two 0.5-second aggregate steps. Three
	# windows cover every phase at this fixture's 12 Hz tick rate.
	TestHelpers.run_ticks(manager, 15)
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
	TestHelpers.disable_wall_clock_budgets(manager_a)
	var herbivore_a = TestHelpers.spawn_herbivore(manager_a.world_state, Vector2(104.0, 104.0), 0)
	var predator_a = TestHelpers.spawn_predator(manager_a.world_state, Vector2(132.0, 104.0))
	herbivore_a.hunger = 62.0
	herbivore_a.thirst = 24.0
	herbivore_a.energy = 78.0
	predator_a.hunger = 74.0
	predator_a.energy = 135.0
	var trace_a := TestHelpers.capture_trace(manager_a, [herbivore_a.id, predator_a.id], 18)

	var manager_b = TestHelpers.create_manager(36)
	TestHelpers.disable_wall_clock_budgets(manager_b)
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
	# Above `state_thresholds.feed_hunger_floor`. The floor was 12, which had predators
	# opening a chase at a tenth of their hunger budget; the sibling assertion below is
	# the other half of that rule.
	predator.hunger = 40.0
	predator.energy = 140.0
	TestHelpers.run_ticks(manager, 1)
	asserts.equal(predator.current_action, AgentAction.HUNT_PREY, "a hungry predator should hunt a healthy herd animal")

	var idle_predator = TestHelpers.spawn_predator(manager.world_state, Vector2(104.0, 108.0))
	idle_predator.hunger = 20.0
	idle_predator.energy = 140.0
	TestHelpers.run_ticks(manager, 1)
	asserts.is_true(idle_predator.current_action != AgentAction.HUNT_PREY,
		"a predator below the feed floor should not open a chase it does not need")
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


## The small determinism trace above never sleeps a sector. This one runs a real
## map through dormancy, then widens the active window so everything wakes, and
## demands the same world twice.
func _test_determinism_with_lod_and_dormancy(asserts) -> void:
	var fingerprints: Array = []
	var most_dormant: Array = []
	for _run in range(2):
		var manager = TestHelpers.create_benchmark_manager(61, 80, 8, 8)
		TestHelpers.disable_wall_clock_budgets(manager)
		manager.lod_enabled = true
		manager.lod_settings["headless_active_radius"] = 120.0
		manager.lod_settings["near_margin"] = 0.0
		manager.lod_settings["mid_margin"] = 280.0
		var dormant_peak := 0
		for tick in range(180):
			if tick == 120:
				manager.lod_settings["headless_active_radius"] = 4000.0
				manager.lod_settings["mid_margin"] = 4000.0
			manager.step_once()
			dormant_peak = maxi(dormant_peak, manager.world_state.get_dormant_sector_count())
		fingerprints.append(TestHelpers.world_fingerprint(manager))
		most_dormant.append(dormant_peak)
		TestHelpers.destroy_manager(manager)
	asserts.is_true(int(most_dormant[0]) > 0, "the replay must actually put sectors to sleep, or it proves nothing")
	asserts.equal(fingerprints[0], fingerprints[1], "same seed and LOD context must replay identically through sleep and wake")


func _test_dormant_path_leaves_rng_untouched(asserts) -> void:
	var manager = TestHelpers.create_manager(62)
	var world = manager.world_state
	var herd_position := Vector2(20.0, 220.0)
	for index in range(4):
		TestHelpers.spawn_herbivore(world, herd_position + Vector2(float(index) * 3.0, 0.0), 0)
	var sector_key: Vector2i = world._get_sector_key(herd_position)
	world._sleep_sector(sector_key)
	var dormant_state: Dictionary = world._sector_states.get(sector_key, {})
	var aggregates: Array = dormant_state.get("dormant_aggregates", [])
	asserts.is_true(not aggregates.is_empty(), "a sleeping herd should produce an aggregate to grow")
	if aggregates.is_empty():
		TestHelpers.destroy_manager(manager)
		return
	aggregates[0]["count"] = int(aggregates[0].get("count", 0)) + 6
	aggregates[0]["births_this_step"] = 6
	var state_before: int = world.rng.state
	world._reconcile_dormant_records(sector_key, dormant_state)
	asserts.equal(world.rng.state, state_before, "dormant births must not draw from the shared random stream")
	var records: Array = dormant_state.get("dormant_records", [])
	asserts.equal(records.size(), 10, "every member of the grown aggregate should have a record")
	var male_newborns := 0
	for record in records:
		if str(record.get("sex", "")) == TestHelpers.AgentBaseScript.SEX_MALE:
			male_newborns += 1
	asserts.is_true(male_newborns > 0, "sexes derived from ids should not all come out female")
	world._sector_states[sector_key] = dormant_state
	state_before = world.rng.state
	for _step in range(20):
		world._apply_dormant_sector_step(sector_key, dormant_state, 0.75)
	asserts.equal(world.rng.state, state_before, "twenty coarse steps of herd motion must not draw from the shared random stream")
	world._wake_sector(sector_key)
	asserts.equal(world.rng.state, state_before, "waking a sector must not draw from the shared random stream")
	asserts.equal(world.get_dormant_sector_count(), 0, "the sector should be awake again")
	TestHelpers.destroy_manager(manager)


func _test_worker_ticks_match_inline_ticks(asserts) -> void:
	var inline = _build_worker_fixture(63)
	var threaded = _build_worker_fixture(63)
	threaded.enable_interactive_worker()
	threaded.begin_interactive_stepping()
	for _tick in range(36):
		inline.step_once()
		threaded._post_worker_job()
		threaded.synchronize_worker()
	asserts.equal(threaded.current_tick, inline.current_tick, "the worker should have run every posted tick")
	asserts.is_true(threaded._worker_thread != null, "one worker thread should stay up between ticks")
	asserts.equal(threaded.rng.state, inline.rng.state, "the worker should consume the random stream exactly as an inline tick does")
	asserts.equal(
		"\n".join(TestHelpers.agent_state_lines(threaded.world_state)),
		"\n".join(TestHelpers.agent_state_lines(inline.world_state)),
		"the view of a worker tick must match the same tick run inline"
	)
	TestHelpers.destroy_manager(threaded)
	TestHelpers.destroy_manager(inline)


static func _build_worker_fixture(seed: int):
	var manager = TestHelpers.create_manager(seed)
	var world = manager.world_state
	var grazer = TestHelpers.spawn_herbivore(world, Vector2(90.0, 90.0), 0)
	grazer.hunger = 40.0
	var drinker = TestHelpers.spawn_herbivore(world, Vector2(110.0, 96.0), 0)
	drinker.thirst = 55.0
	var hunter = TestHelpers.spawn_predator(world, Vector2(180.0, 150.0))
	hunter.hunger = 70.0
	return manager


func _test_snapshot_is_shared_read_only(asserts) -> void:
	var manager = TestHelpers.create_manager(64)
	TestHelpers.spawn_herbivore(manager.world_state, Vector2(96.0, 96.0), 0)
	TestHelpers.run_ticks(manager, 5)
	asserts.is_true(manager.stats_system.get_snapshot_view().is_read_only(), "the shared snapshot should be frozen against edits")
	asserts.is_true(not manager.stats_system.get_snapshot().is_read_only(), "get_snapshot() should still hand out an editable copy")
	TestHelpers.destroy_manager(manager)


func _test_metrics_csv_keeps_columns(asserts) -> void:
	asserts.equal(TelemetryLoggerScript.csv_field(12.5), "12.5", "plain numbers stay unquoted")
	# `JSON.stringify()` sorts keys, so the cell reads alphabetically.
	asserts.equal(TelemetryLoggerScript.csv_field({"meadow": 1, "forest": 2}),
		"\"{\"\"forest\"\":2,\"\"meadow\"\":1}\"", "nested values are written as quoted JSON")
	var path := "user://csv_columns_test.csv"
	var logger = TelemetryLoggerScript.new()
	logger._write_metrics_csv(path, [{"tick": 5, "grass_biomass_by_biome": {"meadow": 1.5, "swamp": 2.0}, "time_seconds": 0.5}])
	var file := FileAccess.open(path, FileAccess.READ)
	var header := file.get_csv_line()
	var row := file.get_csv_line()
	file.close()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	asserts.equal(row.size(), header.size(), "a nested value must not add columns to its row")
	asserts.equal(row[header.find("tick")], "5", "cells after a nested value must stay in their own column")
