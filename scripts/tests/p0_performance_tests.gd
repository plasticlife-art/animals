extends RefCounted

const Helpers := preload("res://scripts/tests/test_helpers.gd")
const MainControllerScript := preload("res://scripts/ui/main_controller.gd")
const SceneSpriteBatchScript := preload("res://scripts/ui/scene_sprite_batch.gd")
const SaveSystemScript := preload("res://scripts/core/save_system.gd")
const ConfigLoaderScript := preload("res://scripts/core/config_loader.gd")


func run(a) -> void:
	_test_overview_hysteresis(a)
	_test_projected_visible_fraction(a)
	_test_deterministic_overview_scenery(a)
	_test_depth_order_cache_policy(a)
	_test_dormant_overview_positions(a)
	_test_worker_delta_protocol(a)
	_test_worker_pause_and_single_step(a)
	_test_worker_keeps_recoverable_backlog(a)
	_test_worker_load_and_shutdown_boundaries(a)
	_test_sector_with_carcass_can_sleep(a)
	_test_carcass_sector_query(a)
	_test_initial_carcass_index(a)
	_test_map_scaled_lod_rings(a)
	_test_dormant_step_stagger(a)
	_test_lod_assignment_cache(a)
	_test_incremental_group_cache(a)
	_test_static_waypoint_corridor_cache(a)
	_test_navigation_queue_fairness(a)
	_test_sliced_global_path_search(a)
	_test_overview_dormant_wake_policy(a)


func _test_overview_hysteresis(a) -> void:
	var bounds := Rect2(0.0, 0.0, 100.0, 100.0)
	var config := {"enabled": true, "enter_visible_fraction": 0.2, "exit_visible_fraction": 0.15}
	a.is_true(not MainControllerScript.resolve_overview_mode(false, Rect2(0, 0, 19, 100), bounds, config),
		"overview remains off below its enter threshold")
	a.is_true(MainControllerScript.resolve_overview_mode(false, Rect2(0, 0, 20, 100), bounds, config),
		"overview enters at twenty percent visible area")
	a.is_true(MainControllerScript.resolve_overview_mode(true, Rect2(0, 0, 16, 100), bounds, config),
		"overview hysteresis holds above the exit threshold")
	a.is_true(not MainControllerScript.resolve_overview_mode(true, Rect2(0, 0, 14, 100), bounds, config),
		"overview exits below fifteen percent visible area")


func _test_projected_visible_fraction(a) -> void:
	var bounds := Rect2(0, 0, 100, 100)
	WorldProjection.configure({"projection": "orthogonal"})
	a.near(WorldProjection.visible_world_fraction(Rect2(0, 0, 20, 100), bounds), 0.2, 0.0001,
		"orthogonal visible fraction matches rectangle area")
	WorldProjection.configure({"projection": "isometric"})
	var projected_bounds := Rect2(-100, 0, 200, 100)
	a.near(WorldProjection.visible_world_fraction(projected_bounds, bounds), 1.0, 0.0001,
		"the full projected isometric diamond reports complete visibility")
	var partial := WorldProjection.visible_world_fraction(Rect2(-25, 25, 50, 50), bounds)
	a.is_true(partial > 0.0 and partial < 1.0,
		"isometric visibility clips the diamond instead of using its inverse AABB")
	WorldProjection.configure({"projection": "orthogonal"})


func _test_deterministic_overview_scenery(a) -> void:
	var config := {"hide_groups": ["meadow"], "thin_groups": ["bush"], "bush_keep_fraction": 0.35}
	a.is_true(not SceneSpriteBatchScript.scenery_visible({"id": 1, "kind": "meadow"}, true, config),
		"small overview decoration is hidden")
	a.is_true(SceneSpriteBatchScript.scenery_visible({"id": 1, "kind": "tree_large"}, true, config),
		"large overview scenery remains visible")
	var first: Array[int] = []
	var second: Array[int] = []
	for id in range(1, 101):
		var entry := {"id": id, "kind": "bush"}
		if SceneSpriteBatchScript.scenery_visible(entry, true, config):
			first.append(id)
		if SceneSpriteBatchScript.scenery_visible(entry, true, config):
			second.append(id)
	a.equal(first, second, "overview thinning is stable for the same scenery IDs")
	a.equal(first.size(), 35, "overview keeps the configured thirty-five percent of bushes")


func _test_depth_order_cache_policy(a) -> void:
	var first := SceneSpriteBatchScript.quantize_view(Rect2(10, 10, 50, 50), 96.0)
	var nearby := SceneSpriteBatchScript.quantize_view(Rect2(15, 14, 50, 50), 96.0)
	a.equal(first, nearby, "camera motion inside the same sector range reuses the static set")
	a.is_true(not SceneSpriteBatchScript.needs_order_rebuild(7, 7, false),
		"depth order stays cached between simulation generations")
	a.is_true(SceneSpriteBatchScript.needs_order_rebuild(7, 8, false),
		"a simulation generation invalidates depth order")
	a.is_true(SceneSpriteBatchScript.needs_order_rebuild(7, 7, true),
		"a changed static sector set invalidates depth order")
	a.is_true(not SceneSpriteBatchScript.overview_order_rebuild_due(12, 17, 6, false),
		"stable overview order is reused inside its configured cadence")
	a.is_true(SceneSpriteBatchScript.overview_order_rebuild_due(12, 18, 6, false),
		"overview order is periodically refreshed after its cadence")
	a.is_true(SceneSpriteBatchScript.overview_order_rebuild_due(12, 13, 6, true),
		"overview membership changes rebuild order immediately")


func _test_dormant_overview_positions(a) -> void:
	var sector := Rect2(96, 192, 96, 96)
	var first := SceneSpriteBatchScript.dormant_proxy_position(sector.get_center(), sector, 123)
	var second := SceneSpriteBatchScript.dormant_proxy_position(sector.get_center(), sector, 123)
	a.equal(first, second, "a dormant animal keeps a stable overview position")
	a.is_true(sector.has_point(first), "a dormant overview proxy stays inside its sector")
	a.is_true(first != SceneSpriteBatchScript.dormant_proxy_position(sector.get_center(), sector, 124),
		"different dormant animals do not collapse onto the same overview point")


func _test_worker_delta_protocol(a) -> void:
	var manager = Helpers.create_manager(81)
	var original = Helpers.spawn_herbivore(manager.world_state, Vector2(96, 96), 0)
	manager.enable_interactive_worker()
	var worker = manager._worker
	var lod: Dictionary = manager._build_lod_context()
	var first: Dictionary = worker.step(manager.tick_duration, 0, 0.0, lod, -1, false)
	a.equal(first.kind, "presentation_delta", "normal worker output is a presentation delta")
	a.equal(int(first.sequence), 1, "worker sequence starts at one")
	a.equal(int(first.snapshot_counts.grass_cells), 0, "grass is omitted while its overlay is disabled")
	a.is_true(not bool(first.agents[0].get("full_record", true)),
		"existing agents use compact presentation records")
	a.is_true(not first.agents[0].has("recent_water_sources") and not first.agents[0].has("path_cells"),
		"compact records omit worker-only navigation and memory")
	manager._apply_worker_frame(first)
	a.equal(manager.world_state.spatial_grid.get_agent_cell(original.id),
		manager.world_state.spatial_grid._to_cell(manager.world_state.get_agent(original.id).position),
		"applying a move updates the presentation spatial index incrementally")

	var born = worker.world.spawn_agent("herbivore", Vector2(160, 160), 0, "female", {"reason": "test"})
	var carcass_id := Helpers.spawn_carcass(worker.world, Vector2(144, 144), 30.0)
	var second: Dictionary = worker.step(manager.tick_duration, 1, manager.tick_duration, lod, -1, true)
	a.is_true(second.grass_delta.has("full"), "enabling the grass overlay sends one complete grass image")
	var birth_record: Dictionary = {}
	for record in second.agents:
		if int(record.id) == born.id:
			birth_record = record
			break
	a.is_true(bool(birth_record.get("full_record", false)), "a newly added agent carries a restorable full record")
	a.is_true(second.carcass_upserts.has(carcass_id), "a new carcass is included in the worker delta")
	manager._apply_worker_frame(second)
	a.is_true(manager.world_state.get_agent(born.id) != null, "an added agent is materialized by its delta")
	a.is_true(manager.world_state.carcasses.has(carcass_id), "a carcass upsert reaches the presentation world")
	a.equal(manager.world_state.query_carcasses(Vector2(144, 144), 12.0).size(), 1,
		"presentation sector deltas retain carcass membership for spatial overlays")

	worker.world.resource_system.track_dirty_cells = true
	worker.world.resource_system.consume_cell(0, 1.0)
	worker.world._queue_carcass_removal(carcass_id)
	worker.world._flush_carcass_removals()
	var third: Dictionary = worker.step(manager.tick_duration, 2, manager.tick_duration * 2.0, lod, -1, true)
	a.is_true(not third.grass_delta.has("full"), "later grass updates remain deltas")
	a.is_true(third.grass_delta.indices.size() >= 1, "a changed grass cell is included in the delta")
	a.is_true(third.carcass_removals.has(carcass_id), "a removed carcass is explicit in the worker delta")
	# Do not apply sequence three. Sequence four must force a complete resync.
	var fourth: Dictionary = worker.step(manager.tick_duration, 3, manager.tick_duration * 3.0, lod, -1, false)
	manager._apply_worker_frame(fourth)
	a.equal(manager._worker_sequence, 4, "a skipped sequence is recovered with the worker's current full snapshot")
	a.is_true(manager.world_state.query_carcasses(Vector2(144, 144), 12.0).is_empty(),
		"a full resync clears removed carcass membership from the presentation world")
	a.equal(str(manager.worker_snapshot_counts.get("mode", "full")), "full",
		"sequence recovery records a full snapshot")
	var unchanged: Dictionary = worker._dictionary_delta({Vector2i.ZERO: {"dormant": false}},
		{Vector2i.ZERO: {"dormant": false}}, false)
	a.is_true(unchanged.upserts.is_empty() and unchanged.removals.is_empty(),
		"unchanged sector state produces no worker delta")
	var removed: Dictionary = worker._dictionary_delta({}, {Vector2i.ZERO: {"dormant": false}}, false)
	a.equal(removed.removals, [Vector2i.ZERO], "removed sector state is explicit in the worker delta")
	var presented_sectors: Dictionary = worker._export_presentation_sectors()
	for sector_key in worker.world._sector_states:
		if worker.world._sector_states[sector_key].get("dormant", false):
			a.is_true(presented_sectors[sector_key].has("dormant_aggregates"),
				"worker sector records retain compact dormant overview aggregates")
			break

	worker.world.kill_agent(worker.world.get_agent(born.id), "cleanup")
	worker.world._flush_removals()
	var fifth: Dictionary = worker.step(manager.tick_duration, 4, manager.tick_duration * 4.0, lod, -1, false)
	a.is_true(fifth.agent_removals.has(born.id),
		"agent removals are explicit in a presentation delta")
	manager._apply_worker_frame(fifth)
	a.is_true(manager.world_state.get_agent(born.id) == null, "a removed agent disappears from the presentation index")
	a.equal(manager.world_state._living_agent_index_by_id.get(original.id, -1), 0,
		"incremental delta application keeps the presentation order index valid")
	Helpers.destroy_manager(manager)


func _test_worker_pause_and_single_step(a) -> void:
	var manager = Helpers.create_manager(82)
	manager.enable_interactive_worker()
	manager.begin_interactive_stepping()
	manager.set_paused(true)
	manager._process_worker(0.1)
	a.is_true(manager._worker_thread == null, "a paused worker does not launch a tick")
	var before: int = manager.current_tick
	manager.request_single_step()
	manager._process_worker(0.0)
	a.is_true(manager._worker_thread != null, "single step launches exactly one worker result")
	manager.synchronize_worker()
	a.equal(manager.current_tick, before + 1, "single step advances exactly one tick")
	a.is_true(manager.paused and not manager._single_step_requested, "single step returns the worker to paused state")
	manager._process_worker(0.1)
	a.is_true(manager._worker_thread == null, "no second worker tick starts after a single step")
	Helpers.destroy_manager(manager)


func _test_worker_keeps_recoverable_backlog(a) -> void:
	var manager = Helpers.create_manager(821)
	manager.enable_interactive_worker()
	manager.set_paused(false)
	manager.accumulator = 0.0
	manager.dropped_simulation_seconds = 0.0
	manager._process_worker(manager.tick_duration * 4.0)
	a.near(manager.accumulator, manager.tick_duration * 4.0, 0.0001,
		"worker keeps a recoverable four-tick spike queued")
	a.near(manager.dropped_simulation_seconds, 0.0, 0.0001,
		"recoverable worker debt is not reported as dropped time")
	manager._process_worker(manager.tick_duration * 8.0)
	a.near(manager.accumulator, manager.tick_duration * 8.0, 0.0001,
		"worker backlog is bounded at the configured capacity")
	a.near(manager.dropped_simulation_seconds, manager.tick_duration * 4.0, 0.0001,
		"only debt beyond backlog capacity is reported as dropped")
	Helpers.destroy_manager(manager)


func _test_worker_load_and_shutdown_boundaries(a) -> void:
	var manager = Helpers.create_manager(86)
	manager.enable_interactive_worker()
	manager.begin_interactive_stepping()
	manager._process_worker(0.1)
	a.is_true(manager._worker_thread != null, "load fixture starts with a worker tick in flight")
	var world_data: Dictionary = manager.export_simulation_state()
	a.is_true(manager._worker_thread == null, "export synchronizes the in-flight worker before save")
	var saved_tick: int = manager.current_tick
	var data := {"version": 2, "selection": {}, "config_bundle": manager.config_bundle.duplicate(true),
		"seed": manager.seed, "tick": saved_tick, "simulation_time": manager.simulation_time,
		"accumulator": manager.accumulator, "rng_seed": manager.rng.seed,
		"rng_state": manager.rng.state, "world": world_data,
		"stats": manager.stats_system.counters.duplicate()}
	a.is_true(SaveSystemScript.restore(manager, data), "load rebuilds a manager after worker synchronization")
	a.equal(manager.current_tick, saved_tick, "load restores the synchronized tick")
	a.is_true(manager._worker == null and manager._worker_thread == null,
		"load leaves no stale worker owner attached")
	manager.enable_interactive_worker()
	manager.begin_interactive_stepping()
	manager._process_worker(0.1)
	a.is_true(manager._worker_thread != null, "shutdown fixture has an active worker")
	manager.shutdown()
	a.is_true(manager._worker_thread == null and manager._worker == null,
		"shutdown joins and releases the worker")
	manager.free()


func _test_sector_with_carcass_can_sleep(a) -> void:
	var manager = Helpers.create_manager(83)
	manager.lod_enabled = true
	var world = manager.world_state
	var animal = Helpers.spawn_herbivore(world, Vector2(20, 220), 0)
	var sector_key: Vector2i = world._get_sector_key(animal.position)
	var carcass_id := Helpers.spawn_carcass(world, animal.position, 40.0)
	var lod := {"enabled": true, "selected_agent_id": -1,
		"focus_rect": Rect2(Vector2.ZERO, Vector2.ONE), "near_margin": 0.0, "mid_margin": 0.0}
	world.refresh_lod_assignments(lod)
	a.is_true(world._can_sleep_sector(sector_key, lod), "a carcass no longer pins a far sector awake")
	world._sleep_sector(sector_key)
	a.is_true(bool(world._sector_states[sector_key].get("dormant", false)),
		"the far sector enters dormant simulation while retaining its carcass ledger")
	a.is_true(world.carcasses.has(carcass_id), "sleeping a sector preserves the real carcass")
	Helpers.destroy_manager(manager)


func _test_carcass_sector_query(a) -> void:
	var manager = Helpers.create_manager(88)
	var world = manager.world_state
	var near_id := Helpers.spawn_carcass(world, Vector2(20, 20), 40.0)
	var far_id := Helpers.spawn_carcass(world, Vector2(220, 220), 40.0)
	world._reset_performance_counters()
	var nearby: Array = world.query_carcasses(Vector2(20, 20), 40.0)
	a.equal(nearby.size(), 1, "carcass query returns the nearby indexed body only")
	a.equal(int(nearby[0].id), near_id, "carcass query returns the expected nearby body")
	a.equal(int(world.performance_counters.carcasses_scanned), 1,
		"carcass query does not scan bodies in distant sectors")
	# Simulate an older save without a carcass ledger. Import must repair it from
	# the authoritative carcass records before any AI or overlay query runs.
	var old_save: Dictionary = world.export_state()
	for sector in old_save.sectors:
		sector["carcass_ids"] = []
	world.import_state(old_save)
	a.is_true(world._sector_states[world._get_sector_key(Vector2(20, 20))].carcass_ids.has(near_id),
		"old-save import restores a nearby carcass membership")
	a.is_true(world._sector_states[world._get_sector_key(Vector2(220, 220))].carcass_ids.has(far_id),
		"old-save import restores a distant carcass membership")
	world._queue_carcass_removal(near_id)
	world._flush_carcass_removals()
	a.is_true(not world._sector_states[world._get_sector_key(Vector2(20, 20))].carcass_ids.has(near_id),
		"carcass removal clears its spatial membership")
	Helpers.destroy_manager(manager)


func _test_initial_carcass_index(a) -> void:
	var bundle := Helpers.build_test_bundle(89)
	bundle.world.spawns["initial_carcass_count"] = 3
	var manager = Helpers.create_manager_with(bundle, 89)
	var world = manager.world_state
	var indexed_count := 0
	for sector in world._sector_states.values():
		indexed_count += sector.get("carcass_ids", []).size()
	a.equal(world.carcasses.size(), 3, "fixture creates the configured initial carcasses")
	a.equal(indexed_count, 3, "every initial carcass is registered in exactly one sector")
	var world_radius: float = world.bounds.size.length()
	a.equal(world.query_carcasses(world.bounds.get_center(), world_radius).size(), 3,
		"spatial query can discover all indexed initial carcasses")
	Helpers.destroy_manager(manager)


func _test_map_scaled_lod_rings(a) -> void:
	var expected := {
		"small": [512.0, 192.0, 512.0],
		"medium": [1024.0, 384.0, 1024.0],
		"large": [1536.0, 576.0, 1536.0],
	}
	for map_size in expected:
		var bundle: Dictionary = ConfigLoaderScript.load_config_bundle({
			"style": "topdown_kenney", "map_size": map_size, "mix": "balanced",
			"scenario": "normal", "rules": "normal", "difficulty": "normal",
		})
		var lod: Dictionary = bundle.world.simulation_lod
		a.near(float(lod.mid_sector_margin), expected[map_size][0], 0.001,
			"%s normal LOD keeps one sector beyond the camera" % map_size)
		a.near(float(lod.overview_near_sector_margin), expected[map_size][1], 0.001,
			"%s overview keeps only its nearest detail ring" % map_size)
		a.near(float(lod.overview_mid_sector_margin), expected[map_size][2], 0.001,
			"%s overview keeps one compact maintenance ring" % map_size)


func _test_dormant_step_stagger(a) -> void:
	var manager = Helpers.create_manager(90)
	var world = manager.world_state
	var first = Helpers.spawn_herbivore(world, Vector2(20, 20), 0)
	var second = Helpers.spawn_herbivore(world, Vector2(148, 20), 1)
	var first_sector: Vector2i = world._get_sector_key(first.position)
	var second_sector: Vector2i = world._get_sector_key(second.position)
	world._sleep_sector(first_sector)
	world._sleep_sector(second_sector)
	var first_phase: float = float(world._sector_states[first_sector].dormant_elapsed)
	var second_phase: float = float(world._sector_states[second_sector].dormant_elapsed)
	a.is_true(not is_equal_approx(first_phase, second_phase),
		"newly sleeping sectors receive different deterministic update phases")
	a.near(first_phase, world._dormant_phase_offset(first_sector), 0.0001,
		"sleeping sector phase is stable for its coordinate")
	var lod := {"enabled": true, "overview": true, "selected_agent_id": -1,
		"focus_rect": Rect2(Vector2(230, 230), Vector2.ONE),
		"near_margin": 0.0, "mid_margin": 0.0}
	world._step_dormant_sectors(0.1, lod)
	a.near(float(world._sector_states[first_sector].dormant_elapsed), first_phase + 0.1, 0.0001,
		"dormant time advances once per simulation tick")
	Helpers.destroy_manager(manager)


func _test_lod_assignment_cache(a) -> void:
	var manager = Helpers.create_manager(84)
	manager.lod_settings["near_margin"] = 90.0
	manager.lod_settings["mid_margin"] = 180.0
	manager.lod_settings["overview_near_margin"] = 12.0
	manager.lod_settings["overview_mid_margin"] = 36.0
	manager.lod_settings["mid_update_interval_ticks"] = 3
	manager.lod_settings["far_update_interval_ticks"] = 8
	manager.lod_settings["overview_mid_update_interval_ticks"] = 8
	manager.lod_settings["overview_far_update_interval_ticks"] = 24
	manager.overview_mode = true
	var overview_context: Dictionary = manager._build_lod_context()
	a.equal(float(overview_context.near_margin), 12.0,
		"overview uses its compact nearest-sector margin")
	a.equal(float(overview_context.mid_margin), 36.0,
		"overview uses its compact next-ring margin")
	a.equal(int(overview_context.mid_update_interval_ticks), 8,
		"overview reduces mid-tier full simulation frequency")
	a.equal(int(overview_context.far_update_interval_ticks), 24,
		"overview reduces far-tier full simulation frequency")
	manager.overview_mode = false
	var normal_context: Dictionary = manager._build_lod_context()
	a.equal(float(normal_context.near_margin), 90.0,
		"normal camera LOD keeps its configured near margin")
	a.equal(float(normal_context.mid_margin), 180.0,
		"normal camera LOD keeps its configured mid margin")
	a.equal(int(normal_context.mid_update_interval_ticks), 3,
		"normal camera LOD keeps its configured mid-tier cadence")
	a.equal(int(normal_context.far_update_interval_ticks), 8,
		"normal camera LOD keeps its configured far-tier cadence")
	var world = manager.world_state
	var animal = Helpers.spawn_herbivore(world, Vector2(224, 224), 0)
	var lod := {"enabled": true, "selected_agent_id": -1,
		"focus_rect": Rect2(Vector2.ZERO, Vector2.ONE), "near_margin": 0.0, "mid_margin": 0.0}
	var first: int = world._resolve_lod_tier_cached(animal, lod)
	a.equal(first, world.LOD_TIER_2, "a far non-priority animal is cached at LOD2")
	a.equal(world._resolve_lod_tier_cached(animal, lod), first,
		"an unchanged animal reuses its LOD assignment")
	animal.ai_state = &"panic"
	a.equal(world._resolve_lod_tier_cached(animal, lod), world.LOD_TIER_0,
		"entering a priority state invalidates the cached tier immediately")
	animal.ai_state = &"alive"
	animal.state = "eat"
	animal.interaction_timer = 1.0
	a.equal(world._resolve_lod_tier_cached(animal, lod), world.LOD_TIER_2,
		"ordinary feeding does not pin an entire far sector awake")
	animal.state = "chase"
	a.equal(world._resolve_lod_tier_cached(animal, lod), world.LOD_TIER_0,
		"an active chase remains in detailed simulation")
	Helpers.destroy_manager(manager)


func _test_incremental_group_cache(a) -> void:
	var manager = Helpers.create_manager(841)
	var world = manager.world_state
	var first = Helpers.spawn_herbivore(world, Vector2(40, 40), 73)
	var second = Helpers.spawn_herbivore(world, Vector2(80, 40), 73)
	a.equal(world.get_group_center(73, first.species_type), Vector2(60, 40),
		"runtime spawns update the group center incrementally")
	var previous: Vector2 = second.position
	second.position = Vector2(120, 40)
	world._move_agent_in_group_cache(second, previous)
	a.equal(world.get_group_center(73, first.species_type), Vector2(80, 40),
		"agent movement updates the cached group sum")
	world.kill_agent(second, "test")
	world._flush_removals()
	a.equal(world.get_group_center(73, first.species_type), first.position,
		"agent removal updates the cached group center")
	Helpers.destroy_manager(manager)


func _test_static_waypoint_corridor_cache(a) -> void:
	var manager = Helpers.create_manager(842)
	var world = manager.world_state
	var animal = Helpers.spawn_herbivore(world, Vector2(40, 40), 0)
	var goal := Vector2(180, 40)
	world.current_tick = 10
	var first: Vector2 = world.get_next_waypoint(animal.position, goal, animal.id)
	a.equal(first, goal, "a clear static navigation goal remains directly reachable")
	a.equal(animal.navigation_direct_check_tick, 10,
		"the first static waypoint request validates its movement corridor")
	world.current_tick = 11
	a.equal(world.get_next_waypoint(animal.position, goal, animal.id), goal,
		"a repeated static waypoint keeps the validated direct corridor")
	a.equal(animal.navigation_direct_check_tick, 10,
		"a direct corridor is not rechecked on every movement tick")
	world.current_tick = 22
	world.get_next_waypoint(animal.position, goal, animal.id)
	a.equal(animal.navigation_direct_check_tick, 22,
		"the direct corridor is periodically validated at the repath cadence")
	world.current_tick = 23
	world.get_next_waypoint(animal.position, Vector2(180, 48), animal.id)
	a.equal(animal.navigation_direct_check_tick, 23,
		"a moving goal invalidates the cached corridor immediately")
	Helpers.destroy_manager(manager)


func _test_navigation_queue_fairness(a) -> void:
	var manager = Helpers.create_manager(85)
	var world = manager.world_state
	world.navigation_config["path_budget_per_tick"] = 1
	world.navigation_config["max_new_paths_per_tick"] = 1
	world._enqueue_global_path(0, 1, 101)
	world._enqueue_global_path(1, 2, 101)
	world._enqueue_global_path(8, 9, 202)
	a.equal(world._pending_global_paths.size(), 2,
		"one requester cannot occupy repeated pending global slots")
	world._prepare_navigation_budget()
	a.equal(world._pending_global_paths.size(), 1,
		"the first budget window services one requester and preserves the rest")
	a.equal(int(world._pending_global_paths[0].requester_id), 202,
		"the next requester keeps its round-robin position")
	world._prepare_navigation_budget()
	a.is_true(world._pending_global_paths.is_empty(),
		"a later budget window services the waiting requester")
	world._enqueue_local_path(101, Vector2(64, 64))
	world._enqueue_local_path(101, Vector2(96, 96))
	world._enqueue_local_path(202, Vector2(128, 128))
	a.equal(world._pending_local_agent_ids, [101, 202],
		"the local path queue stores one stable slot per animal")
	a.equal(world._pending_local_paths[101], Vector2(96, 96),
		"a repeated local request updates its target without jumping the queue")
	Helpers.destroy_manager(manager)


func _test_sliced_global_path_search(a) -> void:
	var manager = Helpers.create_manager(86)
	var terrain = manager.world_state.terrain_system
	var start_index: int = terrain.find_nearest_walkable_index(9)
	var goal_index: int = terrain.find_nearest_walkable_index(54)
	terrain._path_cache.clear()
	terrain._path_cache_order.clear()
	terrain.cancel_path_search(start_index, goal_index)
	var step: Dictionary = terrain.step_path_between_indices(start_index, goal_index, 1)
	a.is_true(not bool(step.get("complete", true)),
		"a long global path yields after its deterministic expansion slice")
	var guard := 0
	while not bool(step.get("complete", false)) and guard < 100:
		step = terrain.step_path_between_indices(start_index, goal_index, 64)
		guard += 1
	a.is_true(bool(step.get("complete", false)),
		"subsequent slices finish the same saved path search")
	a.is_true(terrain.has_cached_path_between_indices(start_index, goal_index),
		"a completed sliced path is published through the normal cache")
	Helpers.destroy_manager(manager)


func _test_overview_dormant_wake_policy(a) -> void:
	var manager = Helpers.create_manager(87)
	manager.lod_enabled = true
	var world = manager.world_state
	var animal = Helpers.spawn_herbivore(world, Vector2(220, 220), 0)
	var sector_key: Vector2i = world._get_sector_key(animal.position)
	var lod := {"enabled": true, "overview": true, "selected_agent_id": -1,
		"focus_rect": Rect2(Vector2.ZERO, Vector2.ONE), "near_margin": 0.0, "mid_margin": 0.0}
	world.refresh_lod_assignments(lod)
	world._sleep_sector(sector_key)
	var sector: Dictionary = world._sector_states[sector_key]
	for aggregate in sector.get("dormant_aggregates", []):
		aggregate["stale_time"] = world._dormant_stale_wake_seconds + 1.0
	world._sector_states[sector_key] = sector
	world._wake_relevant_dormant_sectors(lod)
	a.is_true(bool(world._sector_states[sector_key].get("dormant", false)),
		"overview does not gradually reify stale far sectors")
	lod["overview"] = false
	world._wake_relevant_dormant_sectors(lod)
	a.is_true(not bool(world._sector_states[sector_key].get("dormant", true)),
		"the normal camera mode retains stale-sector recovery")
	Helpers.destroy_manager(manager)

	manager = Helpers.create_manager(88)
	manager.lod_enabled = true
	world = manager.world_state
	animal = Helpers.spawn_herbivore(world, Vector2(220, 220), 0)
	Helpers.spawn_predator(world, Vector2(224, 224))
	sector_key = world._get_sector_key(animal.position)
	lod = {"enabled": true, "overview": true, "selected_agent_id": -1,
		"focus_rect": Rect2(Vector2.ZERO, Vector2.ONE), "near_margin": 0.0, "mid_margin": 0.0}
	world.refresh_lod_assignments(lod)
	sector = world._sector_states[sector_key]
	sector["water"] = true
	world._sector_states[sector_key] = sector
	world._sleep_sector(sector_key)
	sector = world._sector_states[sector_key]
	a.is_true(not world._dormant_sector_should_force_wake(sector_key, sector, lod),
		"far water with predators and prey stays in the aggregate predation path")
	Helpers.destroy_manager(manager)
