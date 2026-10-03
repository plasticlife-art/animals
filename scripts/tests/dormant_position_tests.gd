extends RefCounted

## A sleeping herd keeps every animal's own coordinates and state. The dormant path
## is allowed to advance them coarsely, never to replace them with a group average.

const Helpers := preload("res://scripts/tests/test_helpers.gd")
const AgentBase := preload("res://scripts/agents/agent_base.gd")

const HERD_CENTER := Vector2(768.0, 768.0)
const STEP_SECONDS := 0.75
const HERBIVORE_BODY_RADIUS := 18.0


func run(a) -> void:
	_test_sleep_wake_round_trip_is_exact(a)
	_test_dormant_preserves_herd_spread(a)
	_test_dormant_records_never_share_a_position(a)
	_test_dormant_formation_evolves(a)
	_test_dormant_newborn_does_not_move_the_herd(a)
	_test_dormant_newborn_is_clean(a)
	_test_dormant_motion_is_a_pure_function(a)
	_test_dormant_need_spread_survives_a_round_trip(a)
	_test_dormant_feeding_ledger_survives_sated_members(a)
	_test_dormant_age_spread_survives_a_round_trip(a)
	_test_dormant_starvation_takes_the_hungriest(a)
	_test_dormant_death_is_reported_where_the_victim_stood(a)
	_test_dormant_max_age_kills_once(a)
	_test_dormant_parents_stop_counting_as_ready(a)
	_test_split_herd_follows_one_goal(a)
	_test_sleeping_pair_keeps_its_bond(a)
	_test_herd_walks_around_what_blocks_its_centre(a)
	_test_sleeping_herd_finds_its_way_round_a_wall(a)
	_test_big_herd_grazes_the_ground_it_covers(a)


func _large_manager(seed: int):
	return Helpers.create_manager_with(Helpers.build_large_sector_bundle(seed), seed)


## A fresh herd of `count`, not yet asleep: [manager, world, sector_key, herd].
func _herd(seed: int, count: int) -> Array:
	var manager = _large_manager(seed)
	var world = manager.world_state
	var herd: Array = Helpers.spawn_herd(world, HERD_CENTER, count, 0)
	return [manager, world, world._get_sector_key(HERD_CENTER), herd]


## Coarse steps spaced the way `_step_dormant_sectors()` spaces them: the clock and the
## tick advance in between, so goal refreshes and the wander hash see time pass.
func _coarse_steps(world, sector_key: Vector2i, steps: int, after_step: Callable = Callable()) -> void:
	var ticks_per_step := int(round(STEP_SECONDS * 12.0))
	for step in range(steps):
		world.current_tick += ticks_per_step
		world.current_time += STEP_SECONDS
		# `step()` does this once a tick; it also runs the route searches left pending.
		world._prepare_navigation_budget()
		world._apply_dormant_sector_step(sector_key, world._sector_states[sector_key], STEP_SECONDS)
		if after_step.is_valid():
			after_step.call(step)


func _record_positions(world, sector_key: Vector2i) -> Array:
	return Helpers.positions_of(world._sector_states[sector_key].get("dormant_records", []))


func _positions_by_id(records: Array) -> Dictionary:
	var positions: Dictionary = {}
	for record in records:
		positions[int(record.get("id", -1))] = Vector2(record.get("position", Vector2.ZERO))
	return positions


## Sleeping and waking a sector before any coarse step has run must hand every animal
## back unchanged. Waking used to re-place the herd on a ring around its centre.
func _test_sleep_wake_round_trip_is_exact(a) -> void:
	var fixture := _herd(301, 12)
	var world = fixture[1]
	var sector_key: Vector2i = fixture[2]
	var herd: Array = fixture[3]
	var expected: Dictionary = {}
	for index in range(herd.size()):
		var agent = herd[index]
		agent.hunger = 5.0 + float(index) * 7.0
		agent.thirst = 60.0 - float(index) * 4.0
		agent.energy = 40.0 + float(index) * 3.0
		agent.age = 10.0 + float(index) * 11.0
		agent.velocity = Vector2(float(index) - 6.0, 3.0)
		agent.wander_angle = float(index) * 0.4
		expected[agent.id] = agent.export_runtime_state()
	var spread_before: Dictionary = Helpers.herd_spread(Helpers.positions_of(herd))
	world._sleep_sector(sector_key)
	a.is_true(bool(world._sector_states[sector_key].get("dormant", false)), "the herd's sector should be asleep")
	world._wake_sector(sector_key)
	var mismatches: Array = []
	var restored_herd: Array = []
	for agent_id in expected.keys():
		var restored = world.get_agent(int(agent_id))
		if restored == null:
			mismatches.append("%d missing" % int(agent_id))
			continue
		restored_herd.append(restored)
		var record: Dictionary = expected[agent_id]
		for field in ["position", "velocity", "age", "hunger", "thirst", "energy", "wander_angle"]:
			if restored.get(field) != record[field]:
				mismatches.append("%d %s %s != %s" % [int(agent_id), field, str(restored.get(field)), str(record[field])])
	a.equal(mismatches, [], "every animal wakes exactly as it slept")
	var spread_after: Dictionary = Helpers.herd_spread(Helpers.positions_of(restored_herd))
	a.near(float(spread_after["mean_radius"]), float(spread_before["mean_radius"]), 0.0001,
		"the herd's formation survives a sleep and wake")
	Helpers.destroy_manager(fixture[0])


## Forty coarse steps is half a minute asleep. The herd must neither collapse towards
## its centre, as the old ring did, nor smear across the sector, as drift without
## cohesion would.
func _test_dormant_preserves_herd_spread(a) -> void:
	var fixture := _herd(302, 20)
	var world = fixture[1]
	var sector_key: Vector2i = fixture[2]
	var before_radius := float(Helpers.herd_spread(Helpers.positions_of(fixture[3]))["mean_radius"])
	world._sleep_sector(sector_key)
	_coarse_steps(world, sector_key, 40)
	var asleep: Dictionary = Helpers.herd_spread(_record_positions(world, sector_key))
	var asleep_radius := float(asleep["mean_radius"])
	a.greater(asleep_radius, before_radius * 0.6, "a sleeping herd must not collapse towards its centre")
	a.is_true(asleep_radius < before_radius * 2.0,
		"a sleeping herd must not smear out (before %.1f, asleep %.1f)" % [before_radius, asleep_radius])
	a.greater(float(asleep["min_pair_distance"]), HERBIVORE_BODY_RADIUS, "sleeping animals keep about a body apart")
	world._wake_sector(sector_key)
	var awake_positions: Array = []
	for agent in world.get_living_agents():
		awake_positions.append(agent.position)
	a.equal(awake_positions.size(), 20, "the whole herd wakes")
	a.near(float(Helpers.herd_spread(awake_positions)["mean_radius"]), asleep_radius, 0.0001, "waking does not reshape the herd")
	Helpers.destroy_manager(fixture[0])


func _test_dormant_records_never_share_a_position(a) -> void:
	var fixture := _herd(303, 16)
	var world = fixture[1]
	var sector_key: Vector2i = fixture[2]
	world._sleep_sector(sector_key)
	var closest := [INF]
	_coarse_steps(world, sector_key, 40, func(_step):
		closest[0] = minf(closest[0], float(Helpers.herd_spread(_record_positions(world, sector_key))["min_pair_distance"])))
	a.greater(float(closest[0]), 0.5, "no two sleeping animals ever stand on the same point")
	Helpers.destroy_manager(fixture[0])


## Freezing every offset from the centre would also keep the spread, and would also be
## wrong: the formation is meant to keep living.
func _test_dormant_formation_evolves(a) -> void:
	var fixture := _herd(304, 12)
	var world = fixture[1]
	var sector_key: Vector2i = fixture[2]
	world._sleep_sector(sector_key)
	var offsets_before: Dictionary = {}
	var center: Vector2 = world._sector_states[sector_key]["dormant_aggregates"][0]["center"]
	for record in world._sector_states[sector_key]["dormant_records"]:
		offsets_before[int(record["id"])] = Vector2(record["position"]) - center
	_coarse_steps(world, sector_key, 40)
	center = world._sector_states[sector_key]["dormant_aggregates"][0]["center"]
	var largest_change := 0.0
	for record in world._sector_states[sector_key]["dormant_records"]:
		var offset := Vector2(record["position"]) - center
		largest_change = maxf(largest_change, offset.distance_to(offsets_before[int(record["id"])]))
	a.greater(largest_change, 4.0, "members shift within the herd while it sleeps")
	Helpers.destroy_manager(fixture[0])


## Placement used to follow age rank, so one newborn reshuffled the whole herd.
func _test_dormant_newborn_does_not_move_the_herd(a) -> void:
	var fixture := _herd(305, 8)
	var world = fixture[1]
	var sector_key: Vector2i = fixture[2]
	world._sleep_sector(sector_key)
	var state: Dictionary = world._sector_states[sector_key]
	var before := _positions_by_id(state["dormant_records"])
	state["dormant_aggregates"][0]["births_this_step"] = 1
	world._reconcile_dormant_records(sector_key, state, STEP_SECONDS)
	var after := _positions_by_id(state["dormant_records"])
	a.equal(after.size(), before.size() + 1, "the birth adds one record")
	var moved: Array = []
	for agent_id in before.keys():
		if after.get(agent_id, Vector2.INF) != before[agent_id]:
			moved.append(agent_id)
	a.equal(moved, [], "a birth moves none of the existing herd")
	Helpers.destroy_manager(fixture[0])


## A newborn is not a copy of whoever was youngest: no inherited route, target or kin.
func _test_dormant_newborn_is_clean(a) -> void:
	var fixture := _herd(306, 4)
	var world = fixture[1]
	var sector_key: Vector2i = fixture[2]
	for agent in fixture[3]:
		agent.path_cells = [1, 2, 3]
		agent.target_agent_id = 99
		agent.kin_ids = [7]
	world._sleep_sector(sector_key)
	var state: Dictionary = world._sector_states[sector_key]
	var parents := _positions_by_id(state["dormant_records"])
	state["dormant_aggregates"][0]["births_this_step"] = 1
	world._reconcile_dormant_records(sector_key, state, STEP_SECONDS)
	var newborn: Dictionary = {}
	for record in state["dormant_records"]:
		if not parents.has(int(record["id"])):
			newborn = record
	a.is_true(not newborn.is_empty(), "the birth should produce a record")
	if newborn.is_empty():
		Helpers.destroy_manager(fixture[0])
		return
	a.is_true(newborn.get("path_cells", [1]).is_empty(), "a newborn has no route of its own yet")
	a.equal(int(newborn.get("target_agent_id", 0)), -1, "a newborn has no target")
	a.is_true(newborn.get("kin_ids", [1]).is_empty(), "a newborn inherits no one else's kin list")
	a.equal(float(newborn.get("age", -1.0)), 0.0, "a newborn starts at age zero")
	var nearest_parent := INF
	for parent_position in parents.values():
		nearest_parent = minf(nearest_parent, Vector2(newborn["position"]).distance_to(parent_position))
	a.is_true(nearest_parent <= HERBIVORE_BODY_RADIUS * 2.0 + 0.01, "a newborn is put down beside a parent")
	Helpers.destroy_manager(fixture[0])


func _test_dormant_motion_is_a_pure_function(a) -> void:
	var fingerprints: Array = []
	var rng_moved: Array = []
	for _run in range(2):
		var fixture := _herd(307, 14)
		var world = fixture[1]
		var sector_key: Vector2i = fixture[2]
		world._sleep_sector(sector_key)
		var rng_before: int = world.rng.state
		_coarse_steps(world, sector_key, 30)
		rng_moved.append(world.rng.state != rng_before)
		var lines: Array = []
		for record in world._sector_states[sector_key]["dormant_records"]:
			lines.append("%d %s %s %.6f" % [int(record["id"]), str(record["position"]), str(record["velocity"]), float(record["wander_angle"])])
		fingerprints.append("\n".join(lines))
		Helpers.destroy_manager(fixture[0])
	a.equal(rng_moved, [false, false], "dormant motion never draws from the shared random stream")
	a.equal(fingerprints[0], fingerprints[1], "the same sleeping herd moves identically twice")


func _test_dormant_need_spread_survives_a_round_trip(a) -> void:
	var fixture := _herd(308, 10)
	var world = fixture[1]
	var sector_key: Vector2i = fixture[2]
	# No grass, so no grazing: this is about each animal keeping its own hunger, and a
	# real meal would rightly pull the whole herd down towards zero.
	for cell in range(world.resource_system.get_cell_count()):
		world.resource_system.consume_cell(cell, INF)
	var ids_by_hunger: Array = []
	for index in range(fixture[3].size()):
		var agent = fixture[3][index]
		agent.hunger = 10.0 + float(index) * 5.0
		agent.thirst = 5.0
		ids_by_hunger.append(agent.id)
	world._sleep_sector(sector_key)
	_coarse_steps(world, sector_key, 20)
	world._wake_sector(sector_key)
	var hunger_after: Array = []
	for agent_id in ids_by_hunger:
		var agent = world.get_agent(int(agent_id))
		if agent != null:
			hunger_after.append(agent.hunger)
	a.equal(hunger_after.size(), ids_by_hunger.size(), "no one should starve from this start")
	var ordered := true
	for index in range(1, hunger_after.size()):
		ordered = ordered and float(hunger_after[index]) >= float(hunger_after[index - 1])
	a.is_true(ordered, "the hungriest animal before sleep is still the hungriest after")
	var last := hunger_after.size() - 1
	a.near(float(hunger_after[last]) - float(hunger_after[0]), 45.0, 0.01,
		"animals wake with their own hunger, not the herd's mean")
	Helpers.destroy_manager(fixture[0])


## Two sated animals cannot eat, so the third takes the whole herd's share. The
## group's mean hunger must fall by exactly what the step's feeding ledger said.
func _test_dormant_feeding_ledger_survives_sated_members(a) -> void:
	var fixture := _herd(314, 3)
	var world = fixture[1]
	var sector_key: Vector2i = fixture[2]
	var hungers := [0.0, 0.0, 40.0]
	for index in range(3):
		fixture[3][index].hunger = hungers[index]
	world._sleep_sector(sector_key)
	var state: Dictionary = world._sector_states[sector_key]
	var aggregate: Dictionary = state["dormant_aggregates"][0]
	aggregate["avg_hunger"] = 40.0 / 3.0 - 10.0
	world._reconcile_dormant_records(sector_key, state, 0.0)
	var after: Array = []
	for record in state["dormant_records"]:
		after.append(snappedf(float(record["hunger"]), 0.001))
	a.equal(after, [0.0, 0.0, 10.0], "the hungry animal eats the share the sated ones could not")
	a.near(float(state["dormant_aggregates"][0]["avg_hunger"]), 40.0 / 3.0 - 10.0, 0.001,
		"the herd's mean hunger lands exactly where the feeding ledger put it")
	Helpers.destroy_manager(fixture[0])


func _test_dormant_age_spread_survives_a_round_trip(a) -> void:
	var fixture := _herd(309, 6)
	var world = fixture[1]
	var sector_key: Vector2i = fixture[2]
	var expected_ages: Dictionary = {}
	for index in range(fixture[3].size()):
		var agent = fixture[3][index]
		agent.age = 2.0 + float(index) * 60.0
		expected_ages[agent.id] = agent.age + 20.0 * STEP_SECONDS
	world._sleep_sector(sector_key)
	_coarse_steps(world, sector_key, 20)
	world._wake_sector(sector_key)
	var wrong: Array = []
	for agent_id in expected_ages.keys():
		var agent = world.get_agent(int(agent_id))
		if agent == null or absf(agent.age - float(expected_ages[agent_id])) > 0.001:
			wrong.append(agent_id)
	a.equal(wrong, [], "every animal ages by exactly the time it slept, from its own age")
	Helpers.destroy_manager(fixture[0])


func _test_dormant_starvation_takes_the_hungriest(a) -> void:
	var fixture := _herd(310, 10)
	var world = fixture[1]
	var sector_key: Vector2i = fixture[2]
	var starving_ids: Array = []
	# Half a step's hunger short of the threshold, whatever the shipped hunger rate.
	var rise: float = float(fixture[0].config_bundle["species"]["herbivore"]["metabolism"]["hunger_rate"]) * STEP_SECONDS
	var threshold: float = float(fixture[0].config_bundle["balance"]["lifecycle"]["starvation_death_threshold"])
	for index in range(fixture[3].size()):
		var agent = fixture[3][index]
		agent.hunger = threshold - rise * 0.5 if index >= 7 else 10.0
		if index >= 7:
			starving_ids.append(agent.id)
	world._sleep_sector(sector_key)
	var state: Dictionary = world._sector_states[sector_key]
	var aggregate: Dictionary = state["dormant_aggregates"][0]
	world._apply_dormant_metabolism_to_aggregate(sector_key, aggregate, STEP_SECONDS, state["dormant_records"])
	a.equal(10 - int(aggregate["count"]), 3, "the three animals at the threshold starve, however fed the rest of the herd is")
	world._reconcile_dormant_records(sector_key, state, STEP_SECONDS)
	var remaining := _positions_by_id(state["dormant_records"])
	var starved_survivors: Array = []
	for agent_id in starving_ids:
		if remaining.has(agent_id):
			starved_survivors.append(agent_id)
	a.equal(starved_survivors, [], "starvation takes the hungriest animals")
	a.equal(remaining.size(), 7, "and only as many as the step decided")
	Helpers.destroy_manager(fixture[0])


func _test_dormant_death_is_reported_where_the_victim_stood(a) -> void:
	var fixture := _herd(311, 6)
	var world = fixture[1]
	var sector_key: Vector2i = fixture[2]
	world._sleep_sector(sector_key)
	var state: Dictionary = world._sector_states[sector_key]
	var before := _positions_by_id(state["dormant_records"])
	var aggregate: Dictionary = state["dormant_aggregates"][0]
	aggregate["count"] = 5
	world._queue_dormant_deaths(aggregate, "old_age", 1)
	world.event_bus.clear()
	world._reconcile_dormant_records(sector_key, state, 0.0)
	var after := _positions_by_id(state["dormant_records"])
	var victim_position := Vector2.INF
	for agent_id in before.keys():
		if not after.has(agent_id):
			victim_position = before[agent_id]
	var reported := Vector2.INF
	var death: Dictionary = {}
	for event in world.event_bus.get_events():
		if str(event.get("type", "")) == "AgentDied":
			reported = Vector2(float(event["position"]["x"]), float(event["position"]["y"]))
			death = event
	a.is_true(victim_position != Vector2.INF, "one animal should have died")
	a.equal(reported, victim_position, "the death is reported where that animal stood, not at the herd's centre")
	a.equal(int(death.get("data", {}).get("group_id", -2)), 0, "and names the herd it died out of")
	a.is_true(bool(death.get("data", {}).get("dormant", false)) and int(death.get("agent_id", 0)) == -1,
		"as a sleeping death, with no animal id")
	Helpers.destroy_manager(fixture[0])


## `max_age_count` used to be counted once, at sleep, and never again. One animal past
## its maximum age then forced an old-age death on every step until the herd crossed
## into another sector.
func _test_dormant_max_age_kills_once(a) -> void:
	var fixture := _herd(312, 6)
	var world = fixture[1]
	var sector_key: Vector2i = fixture[2]
	var elder = fixture[3][0]
	elder.age = float(elder.aging.get("max_age", 1200.0)) + 1.0
	for index in range(1, fixture[3].size()):
		fixture[3][index].age = 30.0
	world._sleep_sector(sector_key)
	world.event_bus.clear()
	_coarse_steps(world, sector_key, 4)
	var old_age_deaths := 0
	for event in world.event_bus.get_events():
		if str(event.get("type", "")) == "AgentDiedOfAge":
			old_age_deaths += 1
	a.equal(old_age_deaths, 1, "one animal past its maximum age dies once, and the herd lives on")
	a.equal(world._sector_states[sector_key]["dormant_records"].size(), 5, "the rest of the herd is untouched")
	Helpers.destroy_manager(fixture[0])


## A parent that has just bred is on cooldown and must stop counting as ready, or the
## coarse step goes on breeding the same pair at the ceiling rate.
func _test_dormant_parents_stop_counting_as_ready(a) -> void:
	var fixture := _herd(313, 2)
	var world = fixture[1]
	var sector_key: Vector2i = fixture[2]
	var sexes := [AgentBase.SEX_MALE, AgentBase.SEX_FEMALE]
	for index in range(2):
		var agent = fixture[3][index]
		agent.sex = sexes[index]
		agent.age = float(agent.reproduction.get("maturity_age", 0.0)) + 6.0
		agent.reproduction_cooldown = 0.0
		agent.energy = 95.0
		agent.hunger = 0.0
		agent.thirst = 0.0
	world._sleep_sector(sector_key)
	var state: Dictionary = world._sector_states[sector_key]
	var aggregate: Dictionary = state["dormant_aggregates"][0]
	a.equal([int(aggregate["ready_males"]), int(aggregate["ready_females"])], [1, 1], "the pair starts ready")
	aggregate["births_this_step"] = 1
	world._reconcile_dormant_records(sector_key, state, STEP_SECONDS)
	aggregate = state["dormant_aggregates"][0]
	a.equal([int(aggregate["ready_males"]), int(aggregate["ready_females"])], [0, 0], "parents that just bred are no longer ready")
	Helpers.destroy_manager(fixture[0])


## A herd straddling a sector boundary sleeps as two aggregates. Left to pick goals on
## their own the halves walk apart; the smaller half must follow the larger one.
func _test_split_herd_follows_one_goal(a) -> void:
	var manager = _large_manager(315)
	var world = manager.world_state
	var herd: Array = Helpers.spawn_herd(world, Vector2(1500.0, 768.0), 12, 0)
	var start_spread := float(Helpers.herd_spread(Helpers.positions_of(herd))["mean_pair_distance"])
	var left := Vector2i(0, 0)
	var right := Vector2i(1, 0)
	world._sleep_sector(left)
	world._sleep_sector(right)
	var left_part: Dictionary = world._sector_states[left]["dormant_aggregates"][0]
	var right_part: Dictionary = world._sector_states[right]["dormant_aggregates"][0]
	a.equal([int(left_part["count"]), int(right_part["count"])], [9, 3], "the herd sleeps split across the boundary")
	for part in [left_part, right_part]:
		part["last_goal_refresh_time"] = world.current_time
	left_part["goal_kind"] = "water"
	left_part["goal_position"] = Vector2(384.0, 384.0)
	left_part["goal_sector"] = left
	right_part["goal_kind"] = "wander"
	right_part["goal_position"] = Vector2(3000.0, 768.0)
	right_part["goal_sector"] = right
	# One step of the smaller half alone, so no migration merges it away first.
	world._index_dormant_groups()
	world.current_time += STEP_SECONDS
	world._apply_dormant_sector_step(right, world._sector_states[right], STEP_SECONDS)
	world._dormant_group_index.clear()
	a.equal(right_part.get("goal_position"), Vector2(384.0, 384.0), "the smaller half adopts the larger half's goal")
	var everywhere_far := {"enabled": true, "focus_rect": Rect2(-100000.0, -100000.0, 1.0, 1.0),
		"near_margin": 0.0, "mid_margin": 0.0}
	for _step in range(20):
		world.current_tick += 9
		world.current_time += STEP_SECONDS
		world._step_dormant_sectors(STEP_SECONDS, everywhere_far)
	var positions: Array = []
	for sector_state in world._sector_states.values():
		positions.append_array(Helpers.positions_of(sector_state.get("dormant_records", [])))
	a.equal(positions.size(), 12, "the whole herd is still asleep")
	var end_spread := float(Helpers.herd_spread(positions)["mean_pair_distance"])
	a.is_true(end_spread < start_spread * 2.0,
		"the halves travel together (pair distance %.0f at the start, %.0f after)" % [start_spread, end_spread])
	Helpers.destroy_manager(manager)


## Predator pairs sleep in one `predator:-1` aggregate with every other unbonded
## predator in the sector. Holding to that aggregate's centre let each partner wander
## off alone; five minutes asleep put a pair past `preferred_mate_break_radius`, and
## the pair woke without its bond and stopped breeding.
func _test_sleeping_pair_keeps_its_bond(a) -> void:
	var manager = _large_manager(316)
	var world = manager.world_state
	var male = world.spawn_agent("predator", Vector2(700.0, 760.0), -1, AgentBase.SEX_MALE, {"reason": "test"})
	var female = world.spawn_agent("predator", Vector2(740.0, 760.0), -1, AgentBase.SEX_FEMALE, {"reason": "test"})
	male.set_preferred_mate_id(female.id)
	female.set_preferred_mate_id(male.id)
	for corner in [Vector2(160.0, 160.0), Vector2(1380.0, 160.0), Vector2(160.0, 1380.0), Vector2(1380.0, 1380.0)]:
		world.spawn_agent("predator", corner, -1, AgentBase.SEX_MALE, {"reason": "test"})
	for agent in world.get_living_agents():
		agent.age = 30.0
		agent.hunger = 0.0
		agent.thirst = 0.0
		agent.reproduction_cooldown = 999.0
	var sector_key: Vector2i = world._get_sector_key(Vector2(700.0, 760.0))
	world._sleep_sector(sector_key)
	var widest := [0.0]
	var pair_ids := [male.id, female.id]
	_coarse_steps(world, sector_key, 400, func(_step):
		var pair: Array = []
		for record in world._sector_states[sector_key].get("dormant_records", []):
			if pair_ids.has(int(record["id"])):
				pair.append(Vector2(record["position"]))
		if pair.size() == 2:
			widest[0] = maxf(widest[0], pair[0].distance_to(pair[1])))
	var follow_radius := float(male.reproduction.get("preferred_mate_follow_radius", 180.0))
	a.is_true(float(widest[0]) > 0.0, "the pair should stay asleep and alive through the run")
	a.is_true(float(widest[0]) <= follow_radius,
		"a sleeping pair stays within follow range (widest %.0f, follow radius %.0f)" % [float(widest[0]), follow_radius])
	Helpers.destroy_manager(manager)


## A herd's centre is a point no animal stands on. With an obstacle on the line from
## that centre to the goal, one blocked sweep used to cancel the whole herd's step
## although every animal had open ground ahead, and herds stood still until they died
## of thirst in sight of water.
func _test_herd_walks_around_what_blocks_its_centre(a) -> void:
	var manager = _large_manager(317)
	var world = manager.world_state
	for position in [Vector2(600.0, 690.0), Vector2(600.0, 910.0)]:
		Helpers.spawn_herbivore(world, position, 0)
	var terrain = world.terrain_system
	for row in range(11, 14):
		for column in range(11, 13):
			terrain._walkable[row * terrain.cols + column] = 0
	a.is_true(not world.is_walkable_position(Vector2(768.0, 800.0)), "the fixture should block the line from the herd's centre")
	var sector_key: Vector2i = world._get_sector_key(Vector2(600.0, 800.0))
	world._sleep_sector(sector_key)
	world._dormant_goal_refresh_seconds = 1.0e9
	var aggregate: Dictionary = world._sector_states[sector_key]["dormant_aggregates"][0]
	aggregate["goal_kind"] = "water"
	aggregate["goal_position"] = Vector2(1400.0, 800.0)
	aggregate["goal_sector"] = sector_key
	aggregate["last_goal_refresh_time"] = world.current_time
	var start_x := float(Vector2(aggregate["center"]).x)
	_coarse_steps(world, sector_key, 8)
	aggregate = world._sector_states[sector_key]["dormant_aggregates"][0]
	a.greater(float(Vector2(aggregate["center"]).x) - start_x, 300.0,
		"the herd passes on both sides of an obstacle in front of its centre")
	Helpers.destroy_manager(manager)


## A sleeping herd used to eat from the single best cell in its sector. That fed twenty
## animals and starved a herd of a hundred and sixty on a sector still full of grass.
func _test_big_herd_grazes_the_ground_it_covers(a) -> void:
	var fixture := _herd(318, 81)
	var world = fixture[1]
	var sector_key: Vector2i = fixture[2]
	for agent in fixture[3]:
		agent.hunger = 60.0
	world._sleep_sector(sector_key)
	var state: Dictionary = world._sector_states[sector_key]
	var biomass_before: float = world.resource_system.get_total_biomass()
	world._apply_dormant_resource_interactions(sector_key, state, STEP_SECONDS)
	var total_hunger := 0.0
	for record in state["dormant_records"]:
		total_hunger += float(record["hunger"])
	var mean_hunger := total_hunger / float(state["dormant_records"].size())
	# At least half of what one step's bite takes off, derived from the shipped feeding.
	var feeding: Dictionary = fixture[0].config_bundle["species"]["herbivore"]["feeding"]
	var bite: float = world.grazing_bite(feeding, 60.0, STEP_SECONDS / float(feeding["eat_duration"]))
	var ceiling: float = 60.0 - 0.5 * bite * float(feeding["nutrition_gain"])
	a.is_true(mean_hunger < ceiling,
		"a big sleeping herd feeds from the ground under all of it (mean hunger %.1f, below %.1f)" % [mean_hunger, ceiling])
	a.near(float(state["dormant_aggregates"][0]["avg_hunger"]), mean_hunger, 0.01,
		"the group's mean follows what its members ate")
	a.greater(biomass_before - world.resource_system.get_total_biomass(), 0.0, "the grass they ate is gone")
	Helpers.destroy_manager(fixture[0])


## A sleeping herd headed for its goal in a straight line, so a cliff across the way
## held it until it starved. It now takes a route, as a live animal would.
func _test_sleeping_herd_finds_its_way_round_a_wall(a) -> void:
	var fixture := _herd(319, 6)
	var world = fixture[1]
	var sector_key: Vector2i = fixture[2]
	var terrain = world.terrain_system
	# A wall three cells thick, east of the herd, seventeen cells long with open ends.
	for row in range(4, 21):
		for column in range(16, 19):
			terrain._walkable[row * terrain.cols + column] = 0
	# The route search reads neighbour lists and routes cached when the terrain was built.
	terrain._cached_walkable_neighbors.clear()
	terrain._path_cache.clear()
	a.is_true(not world.scenery.terrain_clear(HERD_CENTER, Vector2(1500.0, 768.0), 0.0), "the fixture should wall off the goal")
	world._sleep_sector(sector_key)
	world._dormant_goal_refresh_seconds = 1.0e9
	for agent_record in world._sector_states[sector_key]["dormant_records"]:
		agent_record["hunger"] = 0.0
		agent_record["thirst"] = 0.0
	var aggregate: Dictionary = world._sector_states[sector_key]["dormant_aggregates"][0]
	aggregate["avg_hunger"] = 0.0
	aggregate["avg_thirst"] = 0.0
	aggregate["goal_kind"] = "wander"
	aggregate["goal_position"] = Vector2(1500.0, 768.0)
	aggregate["goal_sector"] = sector_key
	aggregate["last_goal_refresh_time"] = world.current_time
	var furthest_east := [0.0]
	_coarse_steps(world, sector_key, 60, func(_step):
		var parts: Array = world._sector_states[sector_key].get("dormant_aggregates", [])
		if not parts.is_empty():
			furthest_east[0] = maxf(furthest_east[0], float(Vector2(parts[0]["center"]).x)))
	a.greater(float(furthest_east[0]), 1250.0, "the herd gets past the wall instead of standing at it")
	Helpers.destroy_manager(fixture[0])
