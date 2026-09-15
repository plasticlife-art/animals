extends SceneTree

## Deterministic P2 behaviour gate.
## -- output_json [seed]
const Helpers := preload("res://scripts/tests/test_helpers.gd")


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var args := OS.get_cmdline_user_args()
	var output_path := args[0] if args.size() > 0 else "/private/tmp/animals-p2-behavior.json"
	var seed := int(args[1]) if args.size() > 1 else 2201
	var escape_report := _audit_escape(seed)
	var search_report := _audit_search(seed + 1)
	var passed := bool(escape_report.passed) and bool(search_report.passed)
	var report := {"seed": seed, "passed": passed,
		"escape": escape_report, "last_seen_search": search_report}
	DirAccess.make_dir_recursive_absolute(output_path.get_base_dir())
	var file := FileAccess.open(output_path, FileAccess.WRITE)
	file.store_string(JSON.stringify(report, "\t"))
	file.close()
	print("P2_BEHAVIOR_AUDIT=" + JSON.stringify(report))
	quit(0 if passed else 1)


func _audit_escape(seed: int) -> Dictionary:
	var manager = Helpers.create_manager(seed)
	var world = manager.world_state
	var prey = Helpers.spawn_herbivore(world, Vector2(112, 128))
	var predators := [
		Helpers.spawn_predator(world, Vector2(48, 96)),
		Helpers.spawn_predator(world, Vector2(48, 160)),
	]
	world.scenery.add_object({"id": 22011, "position": Vector2(160, 128),
		"kind": "tree_large", "radius": 12.0, "cover_radius": 0.0,
		"opacity": 0.0, "move_cost": 1.0, "slot": 0, "scale": 1.0, "level": 0})
	var before := _minimum_distance(prey.position, predators)
	prey._flee(world, 0.05, predators, [])
	var target: Vector2 = prey.target_position
	var after := _minimum_distance(target, predators)
	var blocked_sight := true
	for predator in predators:
		blocked_sight = blocked_sight and not world.scenery.visible(
			predator.position, target, predator.position.distance_to(target) + 0.01)
	var report := {"start": prey.position, "target": target,
		"minimum_distance_before": before, "minimum_distance_at_target": after,
		"breaks_all_sight": blocked_sight,
		"body_clear": world.scenery.segment_clear(target, target, prey.get_body_radius()),
		"inside_bounds": world.bounds.grow(-prey.get_body_radius()).has_point(target)}
	report["passed"] = after + 0.01 >= before and bool(report.body_clear) \
		and bool(report.inside_bounds) and blocked_sight
	Helpers.destroy_manager(manager)
	return report


func _audit_search(seed: int) -> Dictionary:
	var manager = Helpers.create_manager(seed)
	var world = manager.world_state
	var hunter = Helpers.spawn_predator(world, Vector2(48, 128))
	var prey = Helpers.spawn_herbivore(world, Vector2(128, 128))
	hunter.hunger = 50.0
	var started: bool = hunter._hunt(world, 0.01, prey)
	var remembered: Vector2 = hunter.last_seen_prey_position
	world.scenery.add_object({"id": 22021, "position": Vector2(104, 128),
		"kind": "tree_large", "radius": 11.0, "cover_radius": 0.0,
		"opacity": 0.0, "move_cost": 1.0, "slot": 0, "scale": 1.0, "level": 0})
	prey.position = Vector2(184, 128)
	world.current_time = 0.5
	var searching: bool = hunter._continue_or_finish_chase(world, 0.05)
	var hidden_position_ignored: bool = hunter.last_seen_prey_position == remembered \
		and hunter.target_position == remembered
	world.current_time = 4.0
	var continued_after_expiry: bool = hunter._continue_or_finish_chase(world, 0.05)
	var report := {"hunt_started": started, "search_continued": searching,
		"hidden_position_ignored": hidden_position_ignored,
		"expired": not continued_after_expiry and hunter.target_agent_id == -1,
		"search_started_count": int(manager.stats_system.counters.search_started),
		"search_expired_count": int(manager.stats_system.counters.search_expired),
		"lost_sight_failures": int(manager.stats_system.counters.hunt_fail_lost_sight)}
	report["passed"] = bool(report.hunt_started) and bool(report.search_continued) \
		and bool(report.hidden_position_ignored) and bool(report.expired) \
		and int(report.search_started_count) == 1 and int(report.search_expired_count) == 1 \
		and int(report.lost_sight_failures) == 1
	Helpers.destroy_manager(manager)
	return report


func _minimum_distance(point: Vector2, agents: Array) -> float:
	var result := INF
	for agent in agents:
		result = minf(result, point.distance_to(agent.position))
	return result
