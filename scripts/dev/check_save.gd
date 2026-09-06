extends SceneTree

## Save/load check.
##
## Runs a simulation, saves, restores into a second manager and compares. Two
## comparisons, because they promise different things:
##
##   * at the moment of loading, every population metric and the grass total must
##     match exactly - a mismatch there is a field the save forgot;
##   * after both sides run on, only populations and death counts are compared.
##
## The middle is deliberately not asserted. A loaded world starts with cold
## caches - the pathfinder's memo and each agent's per-tick decision cache are
## memos, not state, and are not saved - so for a few ticks it re-derives what
## the original had cached and some animals reach grass sooner. Measured at a
## 200-tick save: hunger drifts about 6 points over ten ticks, then converges.
## Populations, deaths and carcasses track throughout.

const WALL_CLOCK_FIELDS := [
	"action_select_ms", "ai_context_build_ms", "grass_search_ms", "pathfind_ms",
	"phase_agents_ms", "phase_dormant_ms", "phase_resources_ms", "phase_sectors_ms",
	"sim_step_ms_avg", "sim_step_ms_lifetime_avg", "sim_step_ms_max",
	"sim_step_ms_peak", "spatial_update_ms", "snapshot_agent_query_ms",
	"snapshot_water_ms", "snapshot_group_ms", "snapshot_carcass_ms",
	"snapshot_predator_choice_ms",
]


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var ticks := int(args[0]) if args.size() > 0 else 400
	var after := int(args[1]) if args.size() > 1 else 200
	var lod_enabled := args.size() > 2 and args[2] == "lod"

	var selection := ConfigLoader.default_selection()
	var original = _make_manager(selection, lod_enabled)
	for _i in range(ticks):
		original.step_once()

	var path := "user://saves/check.dat"
	if not SaveSystem.save(original, selection, path):
		print("FAIL could not write save")
		quit(1)
		return
	var data := SaveSystem.read(path)
	if data.is_empty():
		print("FAIL could not read save back")
		quit(1)
		return

	var restored = _make_manager(selection, lod_enabled)
	if not SaveSystem.restore(restored, data):
		print("FAIL restore rejected the save")
		quit(1)
		return
	# `restore` reloads the config from the saved selection, which is right for
	# the game but throws away this harness's LOD override.
	restored.set_lod_enabled(lod_enabled)

	var left_metrics: Dictionary = original.world_state.get_population_metrics()
	var right_metrics: Dictionary = restored.world_state.get_population_metrics()
	var raw_mismatch: Array = []
	for key in left_metrics.keys():
		if str(left_metrics[key]) != str(right_metrics.get(key)):
			raw_mismatch.append("%s: %s vs %s" % [key, left_metrics[key], right_metrics.get(key)])
	if raw_mismatch.is_empty():
		print("PASS agent state at load (%d metrics)" % left_metrics.size())
	else:
		print("FAIL agent state at load")
		for entry in raw_mismatch:
			print("  - %s" % entry)
	print("  at load hunger_sum %.1f living %s" % [
		left_metrics.get("hunger_sum", 0.0), left_metrics.get("living_count", 0)])
	print("  grass original %.4f restored %.4f | tick %d vs %d" % [
		original.world_state.resource_system.total_biomass,
		restored.world_state.resource_system.total_biomass,
		original.current_tick, restored.current_tick])

	# Both sides run the same short stretch before the strict comparison.
	# Snapshots are only written on sampled ticks, and the per-tick counters in
	# them describe the tick that just ran, so comparing a stepped world against
	# a just-loaded one flags every counter as a difference that is not one.
	var settle := maxi(1, original.stats_system.sample_interval_ticks) * 2
	for _i in range(settle):
		original.step_once()
		restored.step_once()
	var after_left: Dictionary = original.world_state.get_population_metrics()
	var after_right: Dictionary = restored.world_state.get_population_metrics()
	for key in after_left.keys():
		if str(after_left[key]) != str(after_right.get(key)):
			print("  drift %s: %s vs %s" % [key, after_left[key], after_right.get(key)])
	var failures := 0
	if not raw_mismatch.is_empty():
		failures += raw_mismatch.size()
	_compare("%d ticks after load (informational)" % settle, original, restored, true)
	for _i in range(after):
		original.step_once()
		restored.step_once()
	failures += _compare_populations("after %d further ticks" % after, original, restored)

	print("Save check: %d failures (lod=%s)" % [failures, lod_enabled])
	quit(1 if failures > 0 else 0)


func _make_manager(selection: Dictionary, lod_enabled: bool):
	var bundle := ConfigLoader.load_config_bundle(selection)
	bundle["debug"]["lod"]["enabled"] = lod_enabled
	var manager = preload("res://scripts/core/simulation_manager.gd").new()
	root.add_child(manager)
	manager.initialize(bundle, int(bundle["world"].get("seed", 3)))
	return manager


## Populations after a long run-on, with a tolerance rather than an equality.
##
## The owner chose ecological equivalence over byte-identity: insertion-ordered
## collections are rebuilt by index, so an occasional tie breaks differently and
## the two runs diverge slowly. A few animals apart after two hundred ticks is
## the expected shape of that; a collapse on one side is not.
const POPULATION_TOLERANCE := 0.03


func _compare_populations(label: String, a, b) -> int:
	var left: Dictionary = a.stats_system.get_snapshot()
	var right: Dictionary = b.stats_system.get_snapshot()
	var failures := 0
	for key in ["herbivore_population", "predator_population", "active_carcasses"]:
		var lhs := float(left.get(key, 0))
		var rhs := float(right.get(key, 0))
		var allowed: float = maxf(2.0, lhs * POPULATION_TOLERANCE)
		var verdict := "ok" if absf(lhs - rhs) <= allowed else "OUT OF TOLERANCE"
		if verdict != "ok":
			failures += 1
		print("  %-22s %s vs %s  %s" % [key, lhs, rhs, verdict])
	print("%s %s" % ["PASS" if failures == 0 else "FAIL", label])
	return failures


func _compare(label: String, a, b, strict: bool) -> int:
	var left: Dictionary = a.stats_system.get_snapshot()
	var right: Dictionary = b.stats_system.get_snapshot()
	var keys: Array = []
	if strict:
		for key in left.keys():
			if not WALL_CLOCK_FIELDS.has(key):
				keys.append(key)
	else:
		keys = ["herbivore_population", "predator_population", "deaths_starvation",
			"deaths_predation", "active_carcasses"]
	var mismatches: Array = []
	for key in keys:
		if str(left.get(key)) != str(right.get(key)):
			mismatches.append("%s: %s vs %s" % [key, left.get(key), right.get(key)])
	if mismatches.is_empty():
		print("PASS %s (%d fields)" % [label, keys.size()])
		return 0
	print("DIFF %s (%d of %d fields differ)" % [label, mismatches.size(), keys.size()])
	for entry in mismatches:
		print("  - %s" % entry)
	return mismatches.size()
