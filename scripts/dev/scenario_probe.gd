extends SceneTree

## Plays a scenario without a window, as a player who uses the powers by a fixed rule would,
## and reports how the own herd fared - what a scenario is tuned by before anyone plays it.
##
## Godot --headless --path <project> --script res://scripts/dev/scenario_probe.gd \
##   -- scenario policy camera seed after_seconds [output.json] [section.path.to.key=value ...]
##
## `policy`: `none` uses no power; `dig` digs a waterhole by the own herd once the water it
## drinks from runs low or far; `lead` leads it to the fullest pond in reach then; `both` digs
## first and leads after. `policy/low/far` sets how low (`LOW_LEVEL`) and how far (`FAR_WATER`)
## that is, e.g. `dig/0.03/1500` digs only when the water is all but gone. `camera`: `herd` keeps the view on the own herd, as a player watching
## it would - which keeps it awake; `overview` looks at the whole map, which puts it to sleep.
## `seed` -1 is the scenario's own. The run goes on `after_seconds` past the result, to see what
## the season after it does. Trailing `key=value` pairs override the scenario's bundle, as in
## `ecology_audit.gd`. The rules read the world and draw nothing from its rng.
const ScenarioRunnerScript := preload("res://scripts/core/scenario_runner.gd")
const SAMPLE_SECONDS := 10.0
const POLICY_SECONDS := 2.0
const CLOSE_HALF_EXTENT := 800.0
## The water the herd drinks from is low below this level, or far beyond this distance, by default.
const LOW_LEVEL := 0.15
const FAR_WATER := 1100.0

var low_level := LOW_LEVEL
var far_water := FAR_WATER


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var scenario_id := str(args[0]) if args.size() > 0 else "long_drought"
	var policy_spec := (str(args[1]) if args.size() > 1 else "none").split("/")
	var policy := policy_spec[0]
	if policy_spec.size() > 1:
		low_level = float(policy_spec[1])
	if policy_spec.size() > 2:
		far_water = float(policy_spec[2])
	var camera := str(args[2]) if args.size() > 2 else "herd"
	var seed_arg := int(args[3]) if args.size() > 3 else -1
	var after_seconds := float(args[4]) if args.size() > 4 else 120.0
	var output_path := str(args[5]) if args.size() > 5 else ""
	var bundle: Dictionary = ConfigLoader.load_scenario_bundle(scenario_id)
	var overrides := {}
	for index in range(6, args.size()):
		var pair := str(args[index]).split("=", true, 1)
		if pair.size() == 2:
			overrides[pair[0]] = _apply_override(bundle, pair[0], pair[1])
	var run_seed: int = seed_arg if seed_arg >= 0 else int(bundle["challenge"]["seed"])
	var manager = preload("res://scripts/core/simulation_manager.gd").new()
	manager.initialize(bundle, run_seed)
	manager.set_lod_enabled(true)
	var world = manager.world_state
	var runner = ScenarioRunnerScript.new()
	runner.start(manager)
	manager.world_event.connect(runner.hear)
	var all_deaths := {}
	manager.world_event.connect(func(event: Dictionary) -> void:
		if str(event.get("type", "")) == "AgentDied" and str(event.get("species", "")) == runner.species:
			var cause := str(event.get("data", {}).get("cause", ""))
			all_deaths[cause] = int(all_deaths.get(cause, 0)) + 1)
	var species_total_start := _species_count(world, runner.species)
	var samples: Array = []
	var commands: Array = []
	var sample_ticks := maxi(1, int(round(SAMPLE_SECONDS * manager.tick_rate)))
	var policy_ticks := maxi(1, int(round(POLICY_SECONDS * manager.tick_rate)))
	var started := Time.get_ticks_usec()
	var tick := 0
	var ends_at := INF
	var summary_at_result: Dictionary = {}
	var limit_ticks := int(ceil(3600.0 * manager.tick_rate))
	while tick < limit_ticks and manager.simulation_time < ends_at:
		var herd := _herd_state(world, runner)
		if camera == "herd" and Vector2(herd["center"]).is_finite():
			var center: Vector2 = herd["center"]
			manager.set_lod_view(Rect2(center - Vector2.ONE * CLOSE_HALF_EXTENT, Vector2.ONE * CLOSE_HALF_EXTENT * 2.0),
				center, false)
		elif camera != "herd":
			var middle: Vector2 = world.bounds.get_center()
			manager.set_lod_view(Rect2(middle - Vector2.ONE * 0.5, Vector2.ONE), middle, true)
		if not runner.is_over() and tick % policy_ticks == 0:
			var issued := _play(manager, runner, herd, policy)
			if not issued.is_empty():
				commands.append(issued)
		manager.step_once()
		runner.update(manager)
		tick += 1
		if tick % sample_ticks == 0:
			samples.append(_sample(manager, runner, _herd_state(world, runner)))
		if runner.is_over() and ends_at == INF:
			ends_at = manager.simulation_time + after_seconds
			summary_at_result = runner.summary(manager)
	var after := _herd_state(world, runner)
	var report := {
		"scenario": scenario_id, "policy": policy, "low_level": low_level, "far_water": far_water, "camera": camera, "seed": run_seed, "overrides": overrides,
		"result": runner.result, "decided_at": runner.decided_at, "summary": summary_at_result,
		"after": {"seconds": after_seconds, "count": int(after["count"]), "deaths": runner.deaths.duplicate(),
			"share": snappedf(float(after["count"]) / float(maxi(1, runner.baseline)), 0.001)},
		"species": {"start": species_total_start, "end": _species_count(world, runner.species), "deaths": all_deaths},
		"commands": commands,
		"journal": world.player.journal.duplicate(true),
		"samples": samples,
		"wall_seconds": snappedf((Time.get_ticks_usec() - started) / 1000000.0, 0.1),
	}
	var encoded := JSON.stringify(report)
	if output_path != "":
		var file := FileAccess.open(output_path, FileAccess.WRITE)
		if file != null:
			file.store_string(encoded + "\n")
			file.close()
	print("SCENARIO=" + encoded)
	manager.shutdown()
	manager.free()
	quit()


## The rule the policy plays by, once every `POLICY_SECONDS`: the command it gives, or {}.
func _play(manager, runner, herd: Dictionary, policy: String) -> Dictionary:
	if policy == "none" or int(herd["count"]) == 0:
		return {}
	var world = manager.world_state
	var center: Vector2 = herd["center"]
	var drinking := _water_near(world, center)
	if not drinking.is_empty() and float(drinking["level"]) >= low_level and float(drinking["distance"]) <= far_water:
		return {}
	var now: float = manager.simulation_time
	if policy in ["dig", "both"] and world.player.refusal("dig_pond", now) == "":
		var spot := _dig_spot(world, center)
		if spot.is_finite():
			manager.enqueue_command("dig_pond", {"position": spot})
			return {"time": snappedf(now, 0.1), "type": "dig_pond", "at": [snappedf(spot.x, 1.0), snappedf(spot.y, 1.0)],
				"water": drinking}
	if policy in ["lead", "both"] and world.player.refusal("lead_herd", now) == "" \
			and not world.is_led_by_player(runner.species, int(herd["group"])):
		var goal := _lead_goal(world, center)
		if goal.is_finite():
			manager.enqueue_command("lead_herd", {"species": runner.species, "group_id": int(herd["group"]), "position": goal})
			return {"time": snappedf(now, 0.1), "type": "lead_herd", "group": int(herd["group"]),
				"to": [snappedf(goal.x, 1.0), snappedf(goal.y, 1.0)], "water": drinking}
	return {}


## The own herd: its count, centre and mean thirst, awake and asleep, and its biggest group.
func _herd_state(world, runner) -> Dictionary:
	var count := 0
	var sum := Vector2.ZERO
	var thirst := 0.0
	var hunger := 0.0
	var by_group := {}
	for agent in world.get_living_agents():
		if agent != null and agent.is_alive and agent.species_type == runner.species and runner.groups.has(int(agent.group_id)):
			count += 1
			sum += agent.position
			thirst += agent.thirst
			hunger += agent.hunger
			by_group[agent.group_id] = int(by_group.get(agent.group_id, 0)) + 1
	for sector in world._sector_states.values():
		if not bool(sector.get("dormant", false)):
			continue
		for aggregate in sector.get("dormant_aggregates", []):
			var group_id := int(aggregate.get("group_id", -1))
			if str(aggregate.get("species_type", "")) != runner.species or not runner.groups.has(group_id):
				continue
			var members := int(aggregate.get("count", 0))
			count += members
			sum += Vector2(aggregate.get("center", Vector2.ZERO)) * float(members)
			thirst += float(aggregate.get("avg_thirst", 0.0)) * float(members)
			hunger += float(aggregate.get("avg_hunger", 0.0)) * float(members)
			by_group[group_id] = int(by_group.get(group_id, 0)) + members
	var group := -1
	var biggest := 0
	var ids: Array = by_group.keys()
	ids.sort()
	for group_id in ids:
		if int(by_group[group_id]) > biggest:
			biggest = int(by_group[group_id])
			group = int(group_id)
	return {"count": count, "center": sum / float(count) if count > 0 else Vector2.INF,
		"thirst": thirst / float(maxi(1, count)), "hunger": hunger / float(maxi(1, count)), "group": group}


## The wet pond nearest `point`: `{index, distance, level}`, or {} with none.
func _water_near(world, point: Vector2) -> Dictionary:
	if not point.is_finite():
		return {}
	var pond: Dictionary = world.water.nearest_wet(point)
	if pond.is_empty():
		return {}
	var index := int(pond.get("index", -1))
	return {"index": index, "distance": snappedf(point.distance_to(pond["position"]), 1.0),
		"level": snappedf(float(world.water.levels[index]) if world.water.enabled else 1.0, 0.001)}


## The first place, in rings out from `center`, a waterhole may be dug; INF with none.
func _dig_spot(world, center: Vector2) -> Vector2:
	var step: float = world.player_pond_radius() * 1.5
	for ring in range(0, 10):
		var around := maxi(1, ring * 6)
		for index in range(around):
			var angle := TAU * float(index) / float(around)
			var spot := center + Vector2.from_angle(angle) * step * float(ring)
			if world.dig_pond_refusal(spot) == "":
				return spot
	return Vector2.INF


## The shore, on the herd's side, of the fullest wet pond within reach of a lead; INF with none.
func _lead_goal(world, center: Vector2) -> Vector2:
	var reach := float(world.player.settings("lead_herd").get("max_distance", 2400.0))
	var best: Dictionary = {}
	var best_level := -1.0
	for pond in world.water_sources:
		var index := int(pond.get("index", -1))
		if world.water.is_dry(index):
			continue
		var position: Vector2 = pond["position"]
		if center.distance_to(position) > reach * 0.9:
			continue
		var level := float(world.water.levels[index]) * pow(float(pond.get("bank_radius", 1.0)), 2.0)
		if level > best_level:
			best_level = level
			best = pond
	if best.is_empty():
		return Vector2.INF
	var shore: Vector2 = best["position"] + (center - Vector2(best["position"])).normalized() * float(best.get("bank_radius", 0.0)) * 1.2
	for step in range(6):
		var goal := shore.lerp(center, float(step) * 0.08)
		if world.terrain_system.is_walkable_position(goal) and world.bounds.has_point(goal):
			return goal
	return Vector2.INF


func _sample(manager, runner, herd: Dictionary) -> Dictionary:
	var world = manager.world_state
	return {"t": snappedf(manager.simulation_time, 0.1), "own": int(herd["count"]),
		"thirst": snappedf(float(herd["thirst"]), 0.1), "hunger": snappedf(float(herd["hunger"]), 0.1),
		"at": [snappedf(Vector2(herd["center"]).x, 1.0), snappedf(Vector2(herd["center"]).y, 1.0)] if Vector2(herd["center"]).is_finite() else [],
		"grass": snappedf(world._forage_within(herd["center"], world._pasture_radius(runner.species)), 1.0) if Vector2(herd["center"]).is_finite() else 0.0,
		"led": world.is_led_by_player(runner.species, int(herd["group"])), "water": _water_near(world, herd["center"]),
		"wet": world.water.wet_count(), "mean_level": snappedf(world.water.mean_level(), 0.001),
		"species": _species_count(world, runner.species), "thirst_deaths": runner.thirst_deaths()}


func _species_count(world, species: String) -> int:
	return int(world.get_population_metrics().get("%s_count" % species, 0))


## Sets `bundle[a][b][c]` from "a.b.c" and a JSON-ish value; returns the parsed value.
func _apply_override(bundle: Dictionary, path: String, raw: String) -> Variant:
	var value: Variant = JSON.parse_string(raw)
	if value == null and raw != "null":
		value = raw
	var keys := path.split(".")
	var node: Dictionary = bundle
	for index in range(keys.size() - 1):
		if not (node.get(keys[index]) is Dictionary):
			node[keys[index]] = {}
		node = node[keys[index]]
	node[keys[keys.size() - 1]] = value
	return value
