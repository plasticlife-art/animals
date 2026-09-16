extends SceneTree

## Follows one herd through a zoom-out and back, sampling every member's position
## whether it is awake or asleep.
##
## Godot --headless --path <project> --script res://scripts/dev/herd_trace.gd \
##   -- seed output.json [close_seconds] [away_seconds] [back_seconds]
##
## Close: the camera frames the herd farthest from the world centre. Away: an
## overview centred on the world, which puts that herd's sector to sleep. Back: the
## camera frames the herd again, which wakes it.
const SAMPLE_SECONDS := 0.5
const CLOSE_HALF_EXTENT := 800.0


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var run_seed := int(args[0]) if args.size() > 0 else 3
	var output_path := str(args[1]) if args.size() > 1 else "/private/tmp/herd-trace.json"
	var phases := [
		["close", float(args[2]) if args.size() > 2 else 20.0],
		["away", float(args[3]) if args.size() > 3 else 30.0],
		["back", float(args[4]) if args.size() > 4 else 15.0],
	]
	var manager = preload("res://scripts/core/simulation_manager.gd").new()
	manager.initialize(ConfigLoader.load_config_bundle(ConfigLoader.default_selection()), run_seed)
	manager.set_lod_enabled(true)
	var world = manager.world_state
	var world_center: Vector2 = world.bounds.get_center()
	var group_id := _farthest_herd(world, world_center)
	var samples: Array = []
	var sample_ticks := maxi(1, int(round(SAMPLE_SECONDS * manager.tick_rate)))
	for phase in phases:
		var phase_name: String = phase[0]
		var ticks := int(ceil(float(phase[1]) * manager.tick_rate))
		for tick in ticks:
			var members := _members(world, group_id)
			if phase_name == "away":
				manager.set_lod_view(Rect2(world_center - Vector2.ONE * 0.5, Vector2.ONE), world_center, true)
			else:
				var herd_center := _centroid(members)
				manager.set_lod_view(Rect2(herd_center - Vector2.ONE * CLOSE_HALF_EXTENT,
					Vector2.ONE * CLOSE_HALF_EXTENT * 2.0), herd_center, false)
			manager.step_once()
			if tick % sample_ticks == 0:
				samples.append({"time": snappedf(manager.simulation_time, 0.01), "phase": phase_name,
					"members": _members(world, group_id), "parts": _parts(world, group_id)})
	var report := {"seed": run_seed, "group_id": group_id, "phases": phases, "samples": samples,
		"body_radius": float(manager.config_bundle["species"]["herbivore"]["movement"]["body_radius"])}
	var file := FileAccess.open(output_path, FileAccess.WRITE)
	file.store_string(JSON.stringify(report) + "\n")
	manager.shutdown()
	manager.free()
	quit()


func _farthest_herd(world, from: Vector2) -> int:
	var sums: Dictionary = {}
	var counts: Dictionary = {}
	for agent in world.get_living_agents():
		if agent.species_type != "herbivore" or agent.group_id < 0:
			continue
		sums[agent.group_id] = Vector2(sums.get(agent.group_id, Vector2.ZERO)) + agent.position
		counts[agent.group_id] = int(counts.get(agent.group_id, 0)) + 1
	var best_group := 0
	var best_distance := -1.0
	for group in sums.keys():
		var distance: float = (Vector2(sums[group]) / float(counts[group])).distance_to(from)
		if distance > best_distance:
			best_distance = distance
			best_group = int(group)
	return best_group


## [id, x, y, asleep] for every herbivore of the group, live or dormant, by id.
func _members(world, group_id: int) -> Array:
	var members: Array = []
	for agent in world.get_living_agents():
		if agent.species_type == "herbivore" and agent.group_id == group_id:
			members.append([agent.id, snappedf(agent.position.x, 0.1), snappedf(agent.position.y, 0.1), false])
	for sector_state in world._sector_states.values():
		for record in sector_state.get("dormant_records", []):
			if str(record.get("species_type", "")) == "herbivore" and int(record.get("group_id", -1)) == group_id:
				var position: Vector2 = record.get("position", Vector2.ZERO)
				members.append([int(record["id"]), snappedf(position.x, 0.1), snappedf(position.y, 0.1), true])
	members.sort_custom(func(a, b): return int(a[0]) < int(b[0]))
	return members


## The group's dormant aggregates: where each thinks it is and where it is heading.
func _parts(world, group_id: int) -> Array:
	var parts: Array = []
	for sector_key in world._sector_states.keys():
		for aggregate in world._sector_states[sector_key].get("dormant_aggregates", []):
			if str(aggregate.get("species_type", "")) != "herbivore" or int(aggregate.get("group_id", -1)) != group_id:
				continue
			var center: Vector2 = aggregate.get("center", Vector2.ZERO)
			var goal: Vector2 = aggregate.get("goal_position", center)
			var velocity: Vector2 = aggregate.get("velocity", Vector2.ZERO)
			parts.append({"sector": [sector_key.x, sector_key.y], "count": int(aggregate.get("count", 0)),
				"goal_kind": str(aggregate.get("goal_kind", "")), "goal": [snappedf(goal.x, 1.0), snappedf(goal.y, 1.0)],
				"velocity": [snappedf(velocity.x, 0.1), snappedf(velocity.y, 0.1)]})
	return parts


func _centroid(members: Array) -> Vector2:
	if members.is_empty():
		return Vector2.ZERO
	var total := Vector2.ZERO
	for member in members:
		total += Vector2(float(member[1]), float(member[2]))
	return total / float(members.size())
