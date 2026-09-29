extends RefCounted

## Herds moving on to fresh pasture before the ground they stand on is eaten out.

const Helpers := preload("res://scripts/tests/test_helpers.gd")

const STEP_SECONDS := 0.75
## Pasture patches are 3 grass cells of 64 units on the large fixture.
const PATCH := 192.0


func run(a) -> void:
	_test_a_herd_on_bare_ground_sets_out_for_the_nearest_rich_pasture(a)
	_test_a_herd_on_good_pasture_stays(a)
	_test_feared_ground_is_no_destination(a)
	_test_two_herds_do_not_head_for_the_same_patch(a)
	_test_a_starving_member_eats_the_nearest_grass(a)
	_test_an_awake_herd_walks_to_its_new_pasture(a)
	_test_a_sleeping_herd_walks_to_its_new_pasture(a)
	_test_migrations_survive_a_save(a)
	_test_a_herd_moves_on_only_when_its_pasture_is_half_gone(a)
	_test_sleeping_parts_can_be_left_out(a)


func _bundle(seed: int, fear: bool = false) -> Dictionary:
	var bundle: Dictionary = Helpers.build_large_sector_bundle(seed)
	bundle["world"]["grass"]["max_biomass"] = 450.0
	if fear:
		bundle["world"]["fear"] = {"enabled": true, "cell_size_in_grass_cells": 2, "half_life_seconds": 600.0,
			"kill_risk": 1.0, "scare_risk": 0.05, "hunt_pressure_risk": 0.1, "decay_stride_ticks": 4}
	return bundle


## Bare ground everywhere except the listed patches, each cell of which holds `per_cell`.
func _lay_pastures(world, patches: Array, per_cell: float = 400.0) -> void:
	var resources = world.resource_system
	for index in range(resources.get_cell_count()):
		resources._cells[index] = 0.0
	for patch in patches:
		for dy in range(3):
			for dx in range(3):
				var index: int = (int(patch.y) * 3 + dy) * resources.cols + int(patch.x) * 3 + dx
				resources._cells[index] = per_cell
	resources._rebuild_derived()
	world._sector_grass_cache.clear()


func _patch_rect(patch: Vector2i) -> Rect2:
	return Rect2(Vector2(patch) * PATCH, Vector2.ONE * PATCH)


## Whether a destination is the pasture laid at `patch`: close enough that the patch is
## what the herd would be weighing there.
func _heads_for(goal: Variant, patch: Vector2i) -> bool:
	return goal != null and Vector2(goal).distance_to(_patch_rect(patch).get_center()) <= PATCH


func _goal(world, group_id: int = 0) -> Variant:
	return world.herd_migration_goal("herbivore", group_id)


## Where the herd is, awake and asleep: sectors away from the fixture's focus sleep,
## and a sleeping animal lives on as a record rather than as the object spawned.
func _herd_centre(world, group_id: int = 0) -> Vector2:
	var positions: Array = []
	for agent in world.living_agents:
		if agent != null and agent.is_alive and agent.group_id == group_id:
			positions.append(agent.position)
	for key in world._sector_states.keys():
		for record in world._sector_states[key].get("dormant_records", []):
			if int(record.get("group_id", -1)) == group_id:
				positions.append(Vector2(record.get("position", Vector2.ZERO)))
	return Helpers.herd_spread(positions)["centroid"]


func _fed(herd: Array) -> Array:
	# Past the grazing floor, so members graze on arrival, and far from `exempt_hunger`.
	for animal in herd:
		animal.hunger = 15.0
		animal.thirst = 0.0
	return herd


func _test_a_herd_on_bare_ground_sets_out_for_the_nearest_rich_pasture(a) -> void:
	var manager = Helpers.create_manager_with(_bundle(601), 601)
	var world = manager.world_state
	_fed(Helpers.spawn_herd(world, Vector2(1536, 1536), 10, 0))
	var near := Vector2i(11, 8)
	var far := Vector2i(3, 8)
	_lay_pastures(world, [near, far])
	world._update_herd_migrations()
	var goal: Variant = _goal(world)
	a.is_true(goal != null, "a herd on bare ground moves on")
	a.is_true(_heads_for(goal, near),
		"to the rich pasture it reaches soonest (goal %s)" % str(goal))
	a.equal(int(world.performance_counters.get("herd_migrations_started", 0)), 1, "and it is counted")
	a.equal(int(manager.stats_system.counters.get("herd_migrations", 0)), 1, "in the run's statistics too")
	# Starting hungry, the same herd would arrive starving: it looks no further than it
	# can walk before its average member starts to starve.
	world.herd_migrations.clear()
	for agent in world.living_agents:
		agent.hunger = 70.0
	world._update_herd_migrations()
	a.is_true(_goal(world) == null, "a hungry herd does not set out for pasture it cannot reach in time")
	Helpers.destroy_manager(manager)


func _test_a_herd_on_good_pasture_stays(a) -> void:
	var manager = Helpers.create_manager_with(_bundle(602), 602)
	var world = manager.world_state
	_fed(Helpers.spawn_herd(world, Vector2(1536, 1536), 10, 0))
	var everywhere: Array = []
	for y in range(16):
		for x in range(16):
			everywhere.append(Vector2i(x, y))
	_lay_pastures(world, everywhere)
	world._update_herd_migrations()
	a.is_true(_goal(world) == null, "a herd with grass enough around it stays put")
	Helpers.destroy_manager(manager)


func _test_feared_ground_is_no_destination(a) -> void:
	var manager = Helpers.create_manager_with(_bundle(603, true), 603)
	var world = manager.world_state
	_fed(Helpers.spawn_herd(world, Vector2(1536, 1536), 10, 0))
	var near := Vector2i(11, 8)
	var far := Vector2i(3, 8)
	_lay_pastures(world, [near, far])
	world.fear_field.deposit(_patch_rect(near).get_center(), 5.0)
	world._update_herd_migrations()
	var goal: Variant = _goal(world)
	a.is_true(_heads_for(goal, far),
		"a herd passes over pasture where it was hunted for one further off (goal %s)" % str(goal))
	Helpers.destroy_manager(manager)


## Each herd counts the grass the other is on its way to eat.
func _test_two_herds_do_not_head_for_the_same_patch(a) -> void:
	var manager = Helpers.create_manager_with(_bundle(604), 604)
	var world = manager.world_state
	_fed(Helpers.spawn_herd(world, Vector2(1536, 1500), 10, 0))
	_fed(Helpers.spawn_herd(world, Vector2(1536, 1800), 10, 1))
	var near := Vector2i(11, 8)
	var far := Vector2i(3, 8)
	_lay_pastures(world, [near, far])
	world._update_herd_migrations()
	var first: Variant = _goal(world, 0)
	var second: Variant = _goal(world, 1)
	a.is_true(first != null and second != null, "both herds move on")
	a.is_true(first != null and second != null and first.distance_to(second) > PATCH * 2.0,
		"to different pastures (%s and %s)" % [str(first), str(second)])
	Helpers.destroy_manager(manager)


## Hungry, the nearest bite beats any pasture ahead.
func _test_a_starving_member_eats_the_nearest_grass(a) -> void:
	var manager = Helpers.create_manager_with(_bundle(605), 605)
	var world = manager.world_state
	var herd: Array = _fed(Helpers.spawn_herd(world, Vector2(1536, 1536), 10, 0))
	var near := Vector2i(11, 8)
	_lay_pastures(world, [near])
	world._update_herd_migrations()
	# A little grass beside the herd, not worth staying for.
	var beside: int = world.resource_system.get_index_at_position(Vector2(1600, 1536))
	world.resource_system._cells[beside] = 60.0
	world.resource_system._rebuild_derived()
	var member = herd[0]
	member.hunger = 40.0
	var target: Dictionary = world._find_grass_target_for_agent(member)
	a.is_true(_heads_for(target.get("center", Vector2.ZERO), near),
		"a member on the move looks for grass at the destination")
	member.grass_target_cache = {}
	member.hunger = 90.0
	a.is_true(world.herd_migration_goal("herbivore", 0, member.hunger) == null, "a hungry one has no destination")
	target = world._find_grass_target_for_agent(member)
	a.equal(int(target.get("index", -1)), beside, "and takes the nearest grass instead")
	Helpers.destroy_manager(manager)


func _test_an_awake_herd_walks_to_its_new_pasture(a) -> void:
	var manager = Helpers.create_manager_with(_bundle(606), 606)
	# Awake throughout: the fixture otherwise puts sectors away from its focus to sleep.
	manager.set_lod_enabled(false)
	var world = manager.world_state
	var herd: Array = _fed(Helpers.spawn_herd(world, Vector2(1536, 1536), 8, 0))
	var near := Vector2i(11, 8)
	_lay_pastures(world, [near])
	world._update_herd_migrations()
	var goal: Vector2 = _goal(world)
	var start: Vector2 = _herd_centre(world)
	var grass_before: float = world._forage_within(goal, PATCH)
	var closest := INF
	var arrived_at := -1
	var settled_on_arrival := false
	# A minute: long enough for fed members to grow hungry and come to the only grass.
	for second in range(60):
		Helpers.run_ticks(manager, 12)
		closest = minf(closest, _herd_centre(world).distance_to(goal))
		if arrived_at < 0 and _goal(world) == null:
			arrived_at = second
			settled_on_arrival = world.herd_migrations.get("herbivore:0", {}).has("rest_until")
	a.is_true(closest <= PATCH,
		"the herd walked there (from %.0f units off to %.0f)" % [start.distance_to(goal), closest])
	a.is_true(arrived_at >= 0 and arrived_at < 20, "and the migration ended on arrival (after %d s)" % arrived_at)
	a.is_true(settled_on_arrival, "after which the herd stays a while")
	var awake := 0
	for animal in herd:
		if animal.is_alive and world.living_agents.has(animal):
			awake += 1
	a.equal(awake, herd.size(), "every member stayed awake, so this is the awake path")
	a.is_true(world._forage_within(goal, PATCH) < grass_before, "and grazes where it went")
	var worn := 0.0
	for index in range(world.trail_field.get_cell_count()):
		worn += world.trail_field.export_cells()[index]
	a.greater(worn, 0.0, "leaving a trail behind it")
	Helpers.destroy_manager(manager)


## With `follow_asleep` on (off by default: see the migration notes in ARCHITECTURE.md).
func _test_a_sleeping_herd_walks_to_its_new_pasture(a) -> void:
	var bundle := _bundle(607)
	bundle["species"]["herbivore"]["herd"]["migration"]["follow_asleep"] = true
	var manager = Helpers.create_manager_with(bundle, 607)
	var world = manager.world_state
	_fed(Helpers.spawn_herd(world, Vector2(700, 700), 8, 0))
	var ahead := Vector2i(7, 3)
	_lay_pastures(world, [ahead])
	var sector_key: Vector2i = world._get_sector_key(Vector2(700, 700))
	world._sleep_sector(sector_key)
	world._update_herd_migrations()
	var goal: Variant = _goal(world)
	a.is_true(_heads_for(goal, ahead),
		"a sleeping herd counts its sleeping members and moves on too (goal %s)" % str(goal))
	var start: Vector2 = Helpers.herd_spread(Helpers.positions_of(world._sector_states[sector_key]["dormant_records"]))["centroid"]
	var kinds: Dictionary = {}
	for step in range(24):
		world.current_tick += int(round(STEP_SECONDS * 12.0))
		world.current_time += STEP_SECONDS
		world._prepare_navigation_budget()
		for key in world._sector_states.keys():
			var state: Dictionary = world._sector_states[key]
			if bool(state.get("dormant", false)):
				world._apply_dormant_sector_step(key, state, STEP_SECONDS)
				for aggregate in state.get("dormant_aggregates", []):
					kinds[str(aggregate.get("goal_kind", ""))] = true
	var records: Array = []
	for key in world._sector_states.keys():
		records.append_array(world._sector_states[key].get("dormant_records", []))
	var now: Vector2 = Helpers.herd_spread(Helpers.positions_of(records))["centroid"]
	a.is_true(kinds.has("migrate"), "its goal is the destination (%s)" % str(kinds.keys()))
	a.is_true(goal != null and now.distance_to(goal) < start.distance_to(goal) * 0.6,
		"and it walks there (from %.0f to %.0f units off)" % [start.distance_to(goal) if goal != null else -1.0, now.distance_to(goal) if goal != null else -1.0])
	Helpers.destroy_manager(manager)


func _test_migrations_survive_a_save(a) -> void:
	var original = Helpers.create_manager_with(_bundle(608), 608)
	_fed(Helpers.spawn_herd(original.world_state, Vector2(1536, 1536), 10, 0))
	_lay_pastures(original.world_state, [Vector2i(11, 8)])
	original.world_state._update_herd_migrations()
	var saved: Dictionary = original.world_state.export_state()
	var restored = Helpers.create_manager_with(_bundle(608), 608)
	restored.world_state.import_state(saved)
	a.equal(restored.world_state.herd_migrations, original.world_state.herd_migrations,
		"a loaded world knows where its herds were heading")
	Helpers.destroy_manager(original)
	Helpers.destroy_manager(restored)


## Arrive where the whole need is, leave at half of it, and stay a while on arrival.
## Without the gap herds re-weighed their new ground at once from a centre a little off
## the destination, moved on after five seconds, and did so all day.
func _test_a_herd_moves_on_only_when_its_pasture_is_half_gone(a) -> void:
	var manager = Helpers.create_manager_with(_bundle(609), 609)
	var world = manager.world_state
	_fed(Helpers.spawn_herd(world, Vector2(1536, 1536), 10, 0))
	var here := Vector2i(8, 8)
	var near := Vector2i(11, 8)
	_lay_pastures(world, [here, near])
	var need: float = 10.0 * world._herd_member_intake("herbivore") * 30.0
	var at_home: float = world._forage_within(_herd_centre(world), PATCH)
	# Thin the home pasture to three quarters of the need: short, but not half gone.
	var scale := need * 0.75 / at_home
	for index in range(world.resource_system.get_cell_count()):
		if world.resource_system.get_cell_center(index).distance_to(_patch_rect(here).get_center()) < PATCH:
			world.resource_system._cells[index] *= scale
	world.resource_system._rebuild_derived()
	world._update_herd_migrations()
	a.is_true(_goal(world) == null, "a herd with three quarters of what it needs stays and eats")
	for index in range(world.resource_system.get_cell_count()):
		if world.resource_system.get_cell_center(index).distance_to(_patch_rect(here).get_center()) < PATCH:
			world.resource_system._cells[index] *= 0.5
	world.resource_system._rebuild_derived()
	world._update_herd_migrations()
	a.is_true(_heads_for(_goal(world), near), "below half, it moves on")
	world.herd_migrations["herbivore:0"] = {"rest_until": world.current_time + 30.0}
	world._update_herd_migrations()
	a.is_true(_goal(world) == null, "but not while it is settling after arriving")
	world.current_time += 31.0
	world._update_herd_migrations()
	a.is_true(_goal(world) != null, "and once settled it may move on again")
	Helpers.destroy_manager(manager)


## `follow_asleep` off: the herd still decides, but its sleeping parts keep to their own
## grass search.
func _test_sleeping_parts_can_be_left_out(a) -> void:
	var bundle := _bundle(610)
	bundle["species"]["herbivore"]["herd"]["migration"]["follow_asleep"] = false
	var manager = Helpers.create_manager_with(bundle, 610)
	var world = manager.world_state
	_fed(Helpers.spawn_herd(world, Vector2(700, 700), 8, 0))
	_lay_pastures(world, [Vector2i(7, 3)])
	var sector_key: Vector2i = world._get_sector_key(Vector2(700, 700))
	world._sleep_sector(sector_key)
	world._update_herd_migrations()
	a.is_true(_goal(world) != null, "the herd still decides to move on")
	var kinds: Dictionary = {}
	for step in range(8):
		world.current_tick += int(round(STEP_SECONDS * 12.0))
		world.current_time += STEP_SECONDS
		world._prepare_navigation_budget()
		var state: Dictionary = world._sector_states[sector_key]
		world._apply_dormant_sector_step(sector_key, state, STEP_SECONDS)
		for aggregate in state.get("dormant_aggregates", []):
			kinds[str(aggregate.get("goal_kind", ""))] = true
	a.is_true(not kinds.has("migrate"), "but its sleeping part never takes the migrate goal (%s)" % str(kinds.keys()))
	Helpers.destroy_manager(manager)
