extends SceneTree

## Headless benchmark: runs a spawn profile and reports where a tick goes.
##
## `WorldState` already measures itself - `performance_counters` is rebuilt from
## scratch on every `step()`, so the counters have to be collected after each
## tick rather than read once at the end. That is why this runs `step_once()` in
## its own loop instead of calling `run_headless()`.
##
## LOD defaults to off here. With it on, and no camera to supply a focus rect,
## `_build_lod_context()` substitutes a fixed `headless_active_radius` box at the
## world centre, so most sectors go dormant and the numbers describe the LOD
## path rather than a full-fidelity tick. Pass `lod` as the third argument to
## measure the LOD path deliberately.
##
## Usage:
##   Godot --headless --path . --script res://scripts/core/headless_benchmark_runner.gd \
##       -- <profile> <ticks> [lod]
##   profile: current | 750 | 1500
##   lod: omit for no LOD, `lod` for the LOD path, `lod_all` to force near-total
##        dormancy so the coarse dormant ecology is what gets measured

const ConfigLoaderScript = preload("res://scripts/core/config_loader.gd")
const SimulationManagerScript = preload("res://scripts/core/simulation_manager.gd")

const TIMING_SUFFIX := "_ms"


func _initialize() -> void:
	var args: Array = OS.get_cmdline_user_args()
	var profile := "current"
	var total_ticks := 240
	var lod_enabled := false
	if args.size() >= 1 and str(args[0]) != "":
		profile = str(args[0])
	if args.size() >= 2:
		total_ticks = maxi(1, int(args[1]))
	var warmup := int(args[3]) if args.size() > 3 else 180
	var run_seed := int(args[4]) if args.size() > 4 else 3
	var force_dormant := false
	if args.size() >= 3:
		var lod_arg := str(args[2]).to_lower()
		force_dormant = lod_arg == "lod_all"
		lod_enabled = force_dormant or lod_arg in ["lod", "on", "true", "1"]

	var simulation_manager = SimulationManagerScript.new()
	root.add_child(simulation_manager)
	simulation_manager.initialize(_build_profile_bundle(profile, lod_enabled, force_dormant), run_seed)
	var warmup_start := Time.get_ticks_usec()
	for i in warmup:
		simulation_manager.step_once()
	print("warmup_ticks=%d warmup_ms=%.2f" % [warmup, (Time.get_ticks_usec() - warmup_start) / 1000.0])
	simulation_manager.tick_times.samples.clear()

	var timings: Dictionary = {}
	var counts: Dictionary = {}
	var started_at_usec: int = Time.get_ticks_usec()
	for _index in range(total_ticks):
		simulation_manager.step_once()
		_accumulate(simulation_manager.world_state.get_performance_counters(), timings, counts)
	var elapsed_ms: float = float(Time.get_ticks_usec() - started_at_usec) / 1000.0

	print("tick_percentiles=%s" % JSON.stringify(simulation_manager.tick_times.summary()))
	_report(profile, total_ticks, lod_enabled, elapsed_ms, timings, counts,
		simulation_manager.world_state, simulation_manager.stats_system.get_snapshot())

	root.remove_child(simulation_manager)
	simulation_manager.shutdown()
	simulation_manager.free()
	await process_frame
	quit()


func _accumulate(counters: Dictionary, timings: Dictionary, counts: Dictionary) -> void:
	for key in counters.keys():
		var value = counters[key]
		if typeof(value) not in [TYPE_INT, TYPE_FLOAT]:
			continue
		var bucket: Dictionary = timings if str(key).ends_with(TIMING_SUFFIX) else counts
		bucket[key] = float(bucket.get(key, 0.0)) + float(value)


func _report(
	profile: String,
	total_ticks: int,
	lod_enabled: bool,
	elapsed_ms: float,
	timings: Dictionary,
	counts: Dictionary,
	world_state,
	snapshot: Dictionary
) -> void:
	print("")
	print("Benchmark profile=%s ticks=%d lod=%s" % [profile, total_ticks, "on" if lod_enabled else "off"])
	print("Wall clock: %.2f s total, %.3f ms/tick" % [elapsed_ms / 1000.0, elapsed_ms / float(total_ticks)])
	print("Population at end: %d herbivores, %d predators, %d carcasses" % [
		int(snapshot.get("herbivore_population", 0)),
		int(snapshot.get("predator_population", 0)),
		world_state.get_active_carcass_count(),
	])

	print("")
	print("Tick phases (ms per tick, descending):")
	for entry in _sorted_entries(timings):
		print("  %-24s %8.3f" % [entry[0], entry[1] / float(total_ticks)])

	print("")
	print("Counters (per tick / total over run):")
	for entry in _sorted_entries(counts):
		print("  %-24s %10.2f  %12d" % [entry[0], entry[1] / float(total_ticks), int(entry[1])])

	# Machine-readable line for diffing runs. Determinism checks compare this
	# with the wall-clock keys stripped out - those end in `_ms` and never match
	# between runs.
	print("")
	print("snapshot=%s" % JSON.stringify(snapshot))
	print("")


## Descending by accumulated value, so the biggest cost is the first line read.
func _sorted_entries(bucket: Dictionary) -> Array:
	var entries: Array = []
	for key in bucket.keys():
		entries.append([str(key), float(bucket[key])])
	entries.sort_custom(func(a, b): return a[1] > b[1])
	return entries


func _build_profile_bundle(profile: String, lod_enabled: bool, force_dormant: bool = false) -> Dictionary:
	var selection := {}
	for part in profile.split(","):
		var pair := part.split("=")
		if pair.size() == 2:
			selection[pair[0]] = pair[1]
	var bundle: Dictionary = ConfigLoaderScript.load_config_bundle(selection).duplicate(true)
	match profile:
		"current":
			pass
		"750":
			bundle["world"]["spawns"] = {
				"herbivore_count": 690,
				"predator_count": 60,
				"herbivore_group_count": 24,
			}
		"1500":
			bundle["world"]["spawns"] = {
				"herbivore_count": 1380,
				"predator_count": 120,
				"herbivore_group_count": 40,
			}
		_:
			if selection.is_empty():
				push_error("Unknown benchmark profile: %s" % profile)
	var debug_config: Dictionary = bundle.get("debug", {})
	var lod_config: Dictionary = debug_config.get("lod", {})
	lod_config["enabled"] = lod_enabled
	debug_config["lod"] = lod_config
	bundle["debug"] = debug_config
	if force_dormant:
		# Plain `lod` leaves most of the map inside the `headless_active_radius` box, so
		# hardly any sector sleeps and the coarse dormant ecology is barely exercised.
		# Shrinking the box to a fraction of a sector forces near-total dormancy, which
		# is the only way to measure that path on its own.
		var simulation_lod: Dictionary = bundle["world"].get("simulation_lod", {})
		simulation_lod["headless_active_radius"] = 256.0
		simulation_lod["near_sector_margin"] = 0.0
		simulation_lod["mid_sector_margin"] = 0.0
		bundle["world"]["simulation_lod"] = simulation_lod
	return bundle
