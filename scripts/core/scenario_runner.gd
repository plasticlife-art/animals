class_name ScenarioRunner
extends RefCounted

## Keeps the score of a scenario (`scenarios.json`, the bundle's `challenge`): which herd is the
## player's, how many it has against how many it began with, what it lost and to what, and the
## goals' states, until one decides the result. It reads the world the view is shown - the
## worker's copy too - after each tick or frame (`update()`) and the events of the world
## (`hear()`), and changes nothing in it.
##
## The own herd is the herd of `own_herd.species` nearest `own_herd.near` (fractions of the map)
## when the scenario starts, with every half split off it since (`HerdSplit`): a herd that
## grows past its size divides, and the half that walks off is still the player's. Its count is
## its awake members and the sleeping ones of its sleeping sectors' aggregates, as the herd card
## counts them (`HerdReadout`).
##
## A goal names what must hold - the own herd's share of its starting count, its deaths of
## thirst, as a count or a share of that starting count - and when: on the first tick of a season (`at_season_start`), judged by the season
## ordinal of the world's time so the tick it begins is the one that decides, or `days` into it;
## or on every tick (`always`). Its `role` says what it decides: `win` won or lost at its moment, `lose` lost the
## moment it fails, `bonus` nothing. Once the result is in, the runner keeps still: the world
## may be watched on.

signal goal_changed(goal_id: String, state: String)
signal finished(won: bool, summary: Dictionary)

const ClimateScript := preload("res://scripts/world/climate.gd")
const PENDING := "pending"
const MET := "met"
const FAILED := "failed"
const SERIES_SECONDS := 5.0

var challenge: Dictionary = {}
var species: String = ""
## The own herd's group ids: the one picked at the start and each half split off it since.
var groups: Dictionary = {}
var baseline: int = 0
var count: int = 0
var lowest: int = 0
var started_at: float = 0.0
## Deaths in the own herd by cause.
var deaths: Dictionary = {}
## Goal id -> `PENDING`, `MET` or `FAILED`.
var states: Dictionary = {}
## The season ordinal an `at_season_start` goal is decided in, by goal id.
var decide_ordinals: Dictionary = {}
## The time, past the start of that season by the goal's `days`, it is decided at, by goal id.
var decide_times: Dictionary = {}
## "", "won" or "lost".
var result: String = ""
var decided_at: float = -1.0
## `[time, count]` every `SERIES_SECONDS`, for the result's curve.
var series: Array = []


func is_active() -> bool:
	return not challenge.is_empty()


func is_over() -> bool:
	return result != ""


func thirst_deaths() -> int:
	return int(deaths.get("thirst", 0))


## The own herd's count against its starting count, 0 to whatever it grew to.
func share() -> float:
	return float(count) / float(baseline) if baseline > 0 else 0.0


## Takes up the scenario of `manager`'s bundle at the world's start: picks the own herd and the
## count to measure against. Inactive (`is_active()`) for a bundle without a challenge.
func start(manager) -> void:
	challenge = {}
	groups.clear()
	deaths.clear()
	states.clear()
	decide_ordinals.clear()
	decide_times.clear()
	series.clear()
	result = ""
	decided_at = -1.0
	var bundle_challenge = manager.config_bundle.get("challenge", {})
	if not bundle_challenge is Dictionary or bundle_challenge.is_empty():
		return
	challenge = bundle_challenge
	var world = manager.world_state
	var own: Dictionary = challenge.get("own_herd", {})
	species = str(own.get("species", "herbivore"))
	var near: Array = own.get("near", [0.5, 0.5])
	var point: Vector2 = world.bounds.position + world.bounds.size * Vector2(float(near[0]), float(near[1]))
	var group_id := nearest_herd(world, species, point)
	if group_id >= 0:
		groups[group_id] = true
	started_at = float(manager.simulation_time)
	baseline = count_own(world)
	count = baseline
	lowest = baseline
	var climate_config: Dictionary = manager.config_bundle.get("world", {}).get("climate", {})
	for goal in challenge.get("goals", []):
		var goal_id := str(goal.get("id", ""))
		states[goal_id] = PENDING
		if str(goal.get("form", "")) == "at_season_start":
			var ordinal := next_season_ordinal(climate_config, started_at, str(goal.get("season", "")))
			decide_ordinals[goal_id] = ordinal
			decide_times[goal_id] = season_start_time(climate_config, ordinal) \
				+ float(goal.get("days", 0.0)) * float(climate_config.get("day_length_seconds", 120.0))
	series.append([snappedf(started_at, 0.01), count])


## A world event as the view hears it: a split of the own herd adds the half that left to it, a
## death in it is counted by cause - until the result is in.
func hear(event: Dictionary) -> void:
	if not is_active() or is_over() or str(event.get("species", "")) != species:
		return
	var data: Dictionary = event.get("data", {})
	match str(event.get("type", "")):
		"HerdSplit":
			if groups.has(int(data.get("group_id", -1))):
				groups[int(data.get("new_group_id", -1))] = true
		"AgentDied":
			if groups.has(int(data.get("group_id", -1))):
				var cause := str(data.get("cause", ""))
				deaths[cause] = int(deaths.get(cause, 0)) + 1


## The own herd counted again and the goals checked, after a tick or a frame.
func update(manager) -> void:
	if not is_active() or is_over():
		return
	var now := float(manager.simulation_time)
	count = count_own(manager.world_state)
	lowest = mini(lowest, count)
	if series.is_empty() or now - float(series[series.size() - 1][0]) >= SERIES_SECONDS:
		series.append([snappedf(now, 0.01), count])
	var ordinal := ClimateScript.season_ordinal(manager.config_bundle.get("world", {}).get("climate", {}), now)
	for goal in challenge.get("goals", []):
		var goal_id := str(goal.get("id", ""))
		if str(states.get(goal_id, PENDING)) != PENDING:
			continue
		var role := str(goal.get("role", ""))
		if str(goal.get("form", "")) == "at_season_start":
			if ordinal < int(decide_ordinals.get(goal_id, -1)) or ordinal < 0 \
					or now < float(decide_times.get(goal_id, 0.0)) - 0.0001:
				continue
			var held := holds(goal)
			_set_state(goal_id, MET if held else FAILED)
			if role == "win":
				_finish(held, now, manager)
				return
		elif not holds(goal):
			_set_state(goal_id, FAILED)
			if role == "lose":
				_finish(false, now, manager)
				return


## Whether what `goal` names holds now.
func holds(goal: Dictionary) -> bool:
	if goal.has("share_at_least") and share() < float(goal["share_at_least"]):
		return false
	if goal.has("thirst_deaths_at_most") and thirst_deaths() > int(goal["thirst_deaths_at_most"]):
		return false
	if goal.has("thirst_share_at_most") and float(thirst_deaths()) > float(goal["thirst_share_at_most"]) * float(baseline):
		return false
	return true


## The own herd's members now, awake and asleep.
func count_own(world) -> int:
	var total := 0
	for agent in world.get_living_agents():
		if agent != null and agent.is_alive and agent.species_type == species and groups.has(int(agent.group_id)):
			total += 1
	for sector in world._sector_states.values():
		if not bool(sector.get("dormant", false)):
			continue
		for aggregate in sector.get("dormant_aggregates", []):
			if str(aggregate.get("species_type", "")) == species and groups.has(int(aggregate.get("group_id", -1))):
				total += int(aggregate.get("count", 0))
	return total


## What the result window and the probe report: the counts, the deaths, the goals, the powers used.
func summary(manager = null) -> Dictionary:
	var used := {}
	if manager != null and manager.world_state != null and manager.world_state.player != null:
		for entry in manager.world_state.player.journal:
			if bool(entry.get("result", {}).get("ok", false)):
				used[str(entry.get("type", ""))] = int(used.get(str(entry.get("type", "")), 0)) + 1
	return {"id": str(challenge.get("id", "")), "result": result, "baseline": baseline, "count": count,
		"lowest": lowest, "share": snappedf(share(), 0.001), "deaths": deaths.duplicate(),
		"states": states.duplicate(), "decided_at": decided_at, "groups": groups.keys(), "powers_used": used}


## The herd of `species_key` whose centre, awake and asleep, is nearest `point`; -1 if none.
static func nearest_herd(world, species_key: String, point: Vector2) -> int:
	var sums := {}
	var counts := {}
	for agent in world.get_living_agents():
		if agent == null or not agent.is_alive or agent.species_type != species_key or int(agent.group_id) < 0:
			continue
		sums[agent.group_id] = Vector2(sums.get(agent.group_id, Vector2.ZERO)) + agent.position
		counts[agent.group_id] = int(counts.get(agent.group_id, 0)) + 1
	for sector in world._sector_states.values():
		if not bool(sector.get("dormant", false)):
			continue
		for aggregate in sector.get("dormant_aggregates", []):
			var group_id := int(aggregate.get("group_id", -1))
			var members := int(aggregate.get("count", 0))
			if str(aggregate.get("species_type", "")) != species_key or group_id < 0 or members <= 0:
				continue
			sums[group_id] = Vector2(sums.get(group_id, Vector2.ZERO)) + Vector2(aggregate.get("center", Vector2.ZERO)) * float(members)
			counts[group_id] = int(counts.get(group_id, 0)) + members
	var best := -1
	var best_distance := INF
	var ids := sums.keys()
	ids.sort()
	for group_id in ids:
		var distance: float = (Vector2(sums[group_id]) / float(counts[group_id])).distance_squared_to(point)
		if distance < best_distance:
			best_distance = distance
			best = int(group_id)
	return best


## The ordinal of the first season named `season_id` that begins after `time_seconds`; -1 with the
## clock off or no such season.
static func next_season_ordinal(climate_config: Dictionary, time_seconds: float, season_id: String) -> int:
	var ordinal := ClimateScript.season_ordinal(climate_config, time_seconds)
	var seasons: Array = climate_config.get("seasons", [])
	if ordinal < 0 or seasons.is_empty():
		return -1
	for step in range(1, seasons.size() + 1):
		if str(seasons[(ordinal + step) % seasons.size()].get("id", "")) == season_id:
			return ordinal + step
	return -1


## When season `ordinal` began, in the world's seconds (it may be before 0: the season the
## world began in).
static func season_start_time(climate_config: Dictionary, ordinal: int) -> float:
	var season_length := float(ClimateScript.calendar(climate_config)[0])
	return float(ordinal - int(climate_config.get("start_season_index", 0))) * season_length


func export_state() -> Dictionary:
	return {"species": species, "groups": groups.keys(), "baseline": baseline, "count": count, "lowest": lowest,
		"started_at": started_at, "deaths": deaths.duplicate(), "states": states.duplicate(),
		"decide_ordinals": decide_ordinals.duplicate(), "decide_times": decide_times.duplicate(),
		"result": result, "decided_at": decided_at,
		"series": series.duplicate(true)}


## A saved score over `manager`'s bundle: the starting count and the decided goals are the
## saved ones, not taken again.
func import_state(manager, data: Dictionary) -> void:
	start(manager)
	if not is_active() or data.is_empty():
		return
	species = str(data.get("species", species))
	groups.clear()
	for group_id in data.get("groups", []):
		groups[int(group_id)] = true
	baseline = int(data.get("baseline", baseline))
	count = int(data.get("count", count))
	lowest = int(data.get("lowest", lowest))
	started_at = float(data.get("started_at", started_at))
	deaths.clear()
	for cause in data.get("deaths", {}).keys():
		deaths[str(cause)] = int(data["deaths"][cause])
	for goal_id in data.get("states", {}).keys():
		states[str(goal_id)] = str(data["states"][goal_id])
	for goal_id in data.get("decide_ordinals", {}).keys():
		decide_ordinals[str(goal_id)] = int(data["decide_ordinals"][goal_id])
	for goal_id in data.get("decide_times", {}).keys():
		decide_times[str(goal_id)] = float(data["decide_times"][goal_id])
	result = str(data.get("result", ""))
	decided_at = float(data.get("decided_at", -1.0))
	series = data.get("series", []).duplicate(true)


func _set_state(goal_id: String, state: String) -> void:
	states[goal_id] = state
	goal_changed.emit(goal_id, state)


## The result in: the goals still open are settled - a `lose` or `bonus` goal that never failed
## was kept - and `finished` says so.
func _finish(won: bool, now: float, manager) -> void:
	result = "won" if won else "lost"
	decided_at = now
	for goal in challenge.get("goals", []):
		var goal_id := str(goal.get("id", ""))
		if str(states.get(goal_id, PENDING)) == PENDING:
			_set_state(goal_id, MET if holds(goal) else FAILED)
	series.append([snappedf(now, 0.01), count])
	finished.emit(won, summary(manager))
