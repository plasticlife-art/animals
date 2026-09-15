class_name SimulationManager
extends Node

signal tick_completed(tick: int, snapshot: Dictionary)
signal selection_changed(agent_id: int)
signal focus_mode_changed(mode: String)
signal export_completed(paths: Dictionary)

const ConfigLoaderScript = preload("res://scripts/core/config_loader.gd")
const EventBusScript = preload("res://scripts/core/event_bus.gd")
const WorldStateScript = preload("res://scripts/world/world_state.gd")
const StatsSystemScript = preload("res://scripts/stats/stats_system.gd")
const TelemetryLoggerScript = preload("res://scripts/stats/telemetry_logger.gd")

const MAX_SIMULATION_STEPS_PER_FRAME := 2
## Short worker spikes (birth/death batches, sector wakes, OS scheduling) may take
## longer than two tick intervals even when steady-state throughput is faster than
## real time. Keep enough debt to catch those spikes up; actual_speed still exposes
## sustained overload, and the per-frame step limit remains unchanged.
const MAX_SIMULATION_BACKLOG_STEPS := 8

var _worker = null
## One long-lived thread runs every interactive tick. It used to be a new `Thread`
## per tick - eighteen thread creations a second - and nothing joined it when the
## tree went away, so quitting could unload scripts under a tick still running.
## A job goes in through `_job_semaphore` and its result comes back through
## `_done_semaphore`; `_worker_mutex` guards the two hand-off slots.
var _worker_thread: Thread = null
var _worker_mutex: Mutex = Mutex.new()
var _job_semaphore: Semaphore = Semaphore.new()
var _done_semaphore: Semaphore = Semaphore.new()
var _worker_job: Dictionary = {}
var _worker_result: Dictionary = {}
var _worker_quit: bool = false
## Main thread only: a job has been posted and its result not yet applied.
var _job_in_flight: bool = false
## Set once the view has finished coming up. Until then no tick is threaded:
## the frames right after `enable_interactive_worker()` are where the main
## thread compiles `scene_sprite_batch.gd`, builds the themes and loads the
## atlases, and a worker stepping through that window reads instances whose
## script is mid-initialisation. The symptom is not a crash but a method that
## briefly does not exist - `is_alive` missing from a `Herbivore`, `is_threat`
## from the registry - a different set of them on every run.
var _worker_stepping: bool = false
var _presentation_alpha: float = 0.0
var config_bundle: Dictionary = {}
var event_bus
var world_state: WorldState
var stats_system: StatsSystem
var telemetry_logger: TelemetryLogger
var rng: RandomNumberGenerator = RandomNumberGenerator.new()
var current_tick: int = 0
var simulation_time: float = 0.0
var tick_rate: float = 20.0
var tick_duration: float = 0.05
var paused: bool = false
var speed_multiplier: float = 1.0
var accumulator: float = 0.0
var seed: int = 0
var selected_agent_id: int = -1
var focus_mode: String = "off"
var debug_flags: Dictionary = {}
var ui_refresh_interval_ticks: int = 5
var _single_step_requested: bool = false
var lod_enabled: bool = false
var lod_settings: Dictionary = {}
var lod_focus_rect: Rect2 = Rect2()
var overview_mode: bool = false
var lod_focus_center: Vector2 = Vector2.ZERO
var _lod_view_cache_key: PackedInt32Array = PackedInt32Array()
var frame_times = preload("res://scripts/stats/performance_window.gd").new()
var tick_times = preload("res://scripts/stats/performance_window.gd").new()
var render_times = preload("res://scripts/stats/performance_window.gd").new()
var worker_snapshot_times = preload("res://scripts/stats/performance_window.gd").new()
var worker_apply_times = preload("res://scripts/stats/performance_window.gd").new()
var worker_cycle_times = preload("res://scripts/stats/performance_window.gd").new()
var render_phase_times: Dictionary = {}
var simulation_phase_times: Dictionary = {}
var render_counts: Dictionary = {}
var _worker_started_usec: int = 0
var _worker_sequence: int = 0
var worker_snapshot_counts: Dictionary = {}
var actual_speed: float = 0.0
var dropped_simulation_seconds: float = 0.0
var _speed_wall: float = 0.0
var _speed_sim: float = 0.0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS


## Quitting frees the scripts the worker is executing. Joining here, while the
## tree is still whole, stops a tick from running into a half-unloaded agent.
func _exit_tree() -> void:
	_stop_worker_thread()


func initialize(config_override: Dictionary = {}, seed_override: int = -1) -> void:
	if _worker != null:
		shutdown()
	config_bundle = config_override if not config_override.is_empty() else ConfigLoaderScript.load_config_bundle()
	seed = seed_override if seed_override >= 0 else int(config_bundle.get("world", {}).get("seed", 1337))
	rng.seed = seed

	event_bus = EventBusScript.new()
	event_bus.initialize(config_bundle.get("debug", {}))
	stats_system = StatsSystemScript.new()
	stats_system.initialize(config_bundle, event_bus)

	telemetry_logger = TelemetryLoggerScript.new()
	telemetry_logger.initialize(config_bundle)

	world_state = WorldStateScript.new()
	world_state.initialize(config_bundle, event_bus, rng)

	tick_rate = float(config_bundle.get("world", {}).get("tick_rate", 20.0))
	tick_duration = 1.0 / maxf(1.0, tick_rate)
	current_tick = 0
	simulation_time = 0.0
	accumulator = 0.0
	paused = false
	selected_agent_id = -1
	focus_mode = "off"
	_single_step_requested = false
	_worker_sequence = 0
	_worker_started_usec = 0
	worker_snapshot_counts.clear()

	var debug_config: Dictionary = config_bundle.get("debug", {})
	debug_flags = debug_config.get("overlays", {}).duplicate(true)
	ui_refresh_interval_ticks = max(1, int(debug_config.get("ui_refresh_interval_ticks", 5)))
	lod_settings = _build_lod_settings(debug_config)
	lod_enabled = bool(lod_settings.get("enabled", false))
	lod_focus_rect = Rect2()
	overview_mode = false
	lod_focus_center = world_state.bounds.get_center()
	_lod_view_cache_key = _lod_view_key(lod_focus_rect, lod_focus_center, overview_mode)
	debug_flags["show_lod_overlay"] = bool(debug_flags.get("show_lod_overlay", lod_settings.get("show_lod_overlay", false)))
	var speeds: Array = debug_config.get("speed_steps", [1.0])
	if speeds.is_empty():
		speeds = [1.0]
	var default_index := int(debug_config.get("default_speed_index", 0))
	default_index = clampi(default_index, 0, speeds.size() - 1)
	speed_multiplier = float(speeds[default_index])

	stats_system.record_sample(world_state, current_tick, simulation_time)
	tick_completed.emit(current_tick, stats_system.get_snapshot_view())


func _process(delta: float) -> void:
	if world_state == null:
		return
	if _worker != null:
		_process_worker(delta)
		return
	if paused and not _single_step_requested:
		return

	frame_times.add(delta * 1000.0)
	_speed_wall += delta
	accumulator += delta * speed_multiplier
	var max_accumulator := tick_duration * float(MAX_SIMULATION_BACKLOG_STEPS)
	if accumulator > max_accumulator:
		dropped_simulation_seconds += accumulator - max_accumulator
		accumulator = max_accumulator

	var steps_this_frame := 0
	while accumulator >= tick_duration and steps_this_frame < MAX_SIMULATION_STEPS_PER_FRAME:
		accumulator -= tick_duration
		step_once()
		steps_this_frame += 1
		_speed_sim += tick_duration
		if _single_step_requested:
			_single_step_requested = false
			paused = true
			break

	if _speed_wall >= 1.0:
		actual_speed = _speed_sim / _speed_wall
		_speed_wall = 0.0
		_speed_sim = 0.0


func get_performance_summary() -> Dictionary:
	var phases := {}
	for key in render_phase_times:
		phases[key] = render_phase_times[key].summary()
	var simulation_phases := {}
	for key in simulation_phase_times:
		simulation_phases[key] = simulation_phase_times[key].summary()
	return {"frame_ms": frame_times.summary(), "tick_ms": tick_times.summary(),
		"render_cpu_ms": render_times.summary(),
		"worker_snapshot_ms": worker_snapshot_times.summary(),
		"worker_apply_ms": worker_apply_times.summary(),
		"worker_cycle_ms": worker_cycle_times.summary(),
		"render_phases_ms": phases, "simulation_phases_ms": simulation_phases,
		"simulation_counts": world_state.performance_counters.duplicate() if world_state != null else {},
		"lod_counts": world_state.lod_counts.duplicate() if world_state != null else {},
		"render_counts": render_counts.duplicate(),
		"worker_snapshot_counts": worker_snapshot_counts.duplicate(),
		"actual_speed": actual_speed,
		"requested_speed": speed_multiplier, "dropped_simulation_seconds": dropped_simulation_seconds}


func record_render_phase(name: String, elapsed_ms: float) -> void:
	if not render_phase_times.has(name):
		render_phase_times[name] = preload("res://scripts/stats/performance_window.gd").new()
	render_phase_times[name].add(elapsed_ms)


func set_render_counts(counts: Dictionary) -> void:
	render_counts = counts.duplicate()


func reset_performance_windows() -> void:
	for window in [frame_times, tick_times, render_times, worker_snapshot_times,
			worker_apply_times, worker_cycle_times]:
		window.samples.clear()
		window.cursor = 0
	for window in render_phase_times.values():
		window.samples.clear()
		window.cursor = 0
	for window in simulation_phase_times.values():
		window.samples.clear()
		window.cursor = 0
	render_counts.clear()
	worker_snapshot_counts.clear()
	dropped_simulation_seconds = 0.0
	actual_speed = 0.0
	_speed_wall = 0.0
	_speed_sim = 0.0


func step_once() -> void:
	if world_state == null:
		return
	var started_at_usec := Time.get_ticks_usec()
	world_state.inspected_agent_id = selected_agent_id
	world_state.step(tick_duration, current_tick, simulation_time, _build_lod_context())
	var tick_ms := float(Time.get_ticks_usec() - started_at_usec) / 1000.0
	stats_system.record_step_duration(tick_ms)
	tick_times.add(tick_ms)
	current_tick += 1
	simulation_time += tick_duration
	if selected_agent_id != -1 and world_state.get_agent(selected_agent_id) == null:
		selected_agent_id = -1
		selection_changed.emit(selected_agent_id)
		clear_focus()
	stats_system.record_sample(world_state, current_tick, simulation_time)
	tick_completed.emit(current_tick, stats_system.get_snapshot_view())


func set_paused(value: bool) -> void:
	paused = value


func toggle_pause() -> void:
	paused = not paused


func request_single_step() -> void:
	_single_step_requested = true
	paused = false


func set_speed_multiplier(value: float) -> void:
	speed_multiplier = value


func set_debug_flag(flag_name: String, enabled: bool) -> void:
	debug_flags[flag_name] = enabled


## How far the clock has run past the last completed tick, as 0..1. Renderers
## use it to place things between two simulation states instead of snapping them
## to the last one. The speed multiplier is already folded into `accumulator`,
## so this stays correct at 4x and 10x without further work.
func get_tick_alpha() -> float:
	if _worker != null:
		return _presentation_alpha
	if tick_duration <= 0.0:
		return 0.0
	return clampf(accumulator / tick_duration, 0.0, 1.0)


func should_refresh_ui_on_tick(tick: int) -> bool:
	return tick <= 0 or tick % ui_refresh_interval_ticks == 0


func set_lod_enabled(value: bool) -> void:
	if lod_enabled == value:
		return
	lod_enabled = value
	_refresh_lod_assignments()


func set_lod_focus_rect(rect: Rect2) -> void:
	var next_key := _lod_view_key(rect, rect.get_center(), overview_mode)
	if _lod_view_cache_key == next_key:
		lod_focus_rect = rect
		lod_focus_center = rect.get_center()
		return
	lod_focus_rect = rect
	lod_focus_center = rect.get_center()
	_lod_view_cache_key = next_key
	_refresh_lod_assignments()


func set_lod_view(rect: Rect2, center: Vector2, is_overview: bool) -> void:
	var next_key := _lod_view_key(rect, center, is_overview)
	if _lod_view_cache_key == next_key:
		lod_focus_rect = rect
		lod_focus_center = center
		overview_mode = is_overview
		return
	lod_focus_rect = rect
	lod_focus_center = center
	overview_mode = is_overview
	_lod_view_cache_key = next_key
	_refresh_lod_assignments()


func _lod_view_key(rect: Rect2, center: Vector2, is_overview: bool) -> PackedInt32Array:
	var sector_size := maxf(1.0, float(config_bundle.get("world", {})
		.get("simulation_lod", {}).get("sector_size", 512.0)))
	return PackedInt32Array([
		1 if is_overview else 0,
		floori(rect.position.x / sector_size), floori(rect.position.y / sector_size),
		ceili(rect.end.x / sector_size), ceili(rect.end.y / sector_size),
		floori(center.x / sector_size), floori(center.y / sector_size),
	])


func select_agent_at_position(position: Vector2, radius: float) -> void:
	if world_state == null:
		return
	var nearby: Array = world_state.query_agents(position, radius, "", -1)
	if nearby.is_empty():
		selected_agent_id = -1
		clear_focus()
	else:
		var nearest = nearby[0]
		var nearest_distance_sq: float = nearest.position.distance_squared_to(position)
		for candidate in nearby:
			var distance_sq: float = candidate.position.distance_squared_to(position)
			if distance_sq < nearest_distance_sq:
				nearest = candidate
				nearest_distance_sq = distance_sq
		selected_agent_id = nearest.id
		set_focus_mode("agent")
	_refresh_lod_assignments()
	selection_changed.emit(selected_agent_id)


func get_selected_agent():
	if selected_agent_id == -1:
		return null
	return world_state.get_agent(selected_agent_id)


func get_selected_agent_summary() -> Dictionary:
	var agent = get_selected_agent()
	if agent == null:
		return {}
	var summary: Dictionary = agent.get_debug_summary(current_tick)
	summary["biome"] = "meadow" if world_state == null else world_state.get_biome_at_position(agent.position)
	summary["path_nodes"] = agent.path_cells.size()
	return summary


func set_focus_mode(mode: String) -> void:
	var next_mode := mode
	if next_mode not in ["off", "agent", "flock"]:
		next_mode = "off"
	if next_mode != "off" and get_selected_agent() == null:
		next_mode = "off"
	if focus_mode == next_mode:
		return
	focus_mode = next_mode
	focus_mode_changed.emit(focus_mode)


func clear_focus() -> void:
	set_focus_mode("off")


func get_focus_position():
	if focus_mode == "off":
		return null
	var agent = get_selected_agent()
	if agent == null:
		return null
	if focus_mode == "flock":
		var group_center = world_state.get_group_center(agent.group_id, agent.species_type, agent.id)
		if group_center != null:
			return group_center
	return agent.position


func export_telemetry() -> Dictionary:
	var paths := telemetry_logger.export_all(seed, stats_system, event_bus, {
		"tick": current_tick,
		"time_seconds": simulation_time,
		"performance": get_performance_summary(),
	})
	export_completed.emit(paths)
	return paths


func run_headless(total_ticks: int, export_on_finish: bool = true) -> Dictionary:
	for _index in range(total_ticks):
		step_once()
	var export_paths := {}
	if export_on_finish:
		export_paths = export_telemetry()
	return {
		"tick": current_tick,
		"time_seconds": simulation_time,
		"snapshot": stats_system.get_snapshot(),
		"exports": export_paths,
	}


func shutdown() -> void:
	_stop_worker_thread()
	_worker_started_usec = 0
	if _worker != null:
		_worker.shutdown()
		_worker = null
	if is_instance_valid(self):
		set_process(false)
	if stats_system != null and stats_system.has_method("shutdown"):
		stats_system.shutdown()
	if telemetry_logger != null and telemetry_logger.has_method("shutdown"):
		telemetry_logger.shutdown()
	if world_state != null and world_state.has_method("shutdown"):
		world_state.shutdown()
	if event_bus != null and event_bus.has_method("shutdown"):
		event_bus.shutdown()
	world_state = null
	stats_system = null
	telemetry_logger = null
	event_bus = null
	config_bundle.clear()


func _build_lod_settings(debug_config: Dictionary) -> Dictionary:
	var lod_config: Dictionary = debug_config.get("lod", {})
	var simulation_lod_config: Dictionary = config_bundle.get("world", {}).get("simulation_lod", {})
	# The margins default from `world.simulation_lod`, which `presets.json` scales per map
	# size. They used to default to fixed literals with `debug.json` always supplying a
	# value, so the per-size numbers were dead: the active window stayed the same width
	# while the map tripled, and nearly every sector went dormant in the GUI.
	var near_margin := maxf(0.0, float(lod_config.get("near_margin", simulation_lod_config.get("near_sector_margin", 192.0))))
	var mid_margin := maxf(near_margin, float(lod_config.get("mid_margin", simulation_lod_config.get("mid_sector_margin", 768.0))))
	return {
		"enabled": bool(lod_config.get("enabled", false)),
		"near_margin": near_margin,
		"mid_margin": mid_margin,
		"overview_near_margin": maxf(0.0, float(simulation_lod_config.get(
			"overview_near_sector_margin", near_margin))),
		"overview_mid_margin": maxf(0.0, float(simulation_lod_config.get(
			"overview_mid_sector_margin", mid_margin))),
		"mid_update_interval_ticks": maxi(1, int(lod_config.get("mid_update_interval_ticks", 2))),
		"far_update_interval_ticks": maxi(1, int(lod_config.get("far_update_interval_ticks", 5))),
		"overview_mid_update_interval_ticks": maxi(1, int(simulation_lod_config.get(
			"overview_mid_update_interval_ticks", lod_config.get("mid_update_interval_ticks", 2)))),
		"overview_far_update_interval_ticks": maxi(1, int(simulation_lod_config.get(
			"overview_far_update_interval_ticks", lod_config.get("far_update_interval_ticks", 5)))),
		"mid_decision_interval_ticks": maxi(1, int(simulation_lod_config.get("mid_decision_interval", 3))),
		"far_decision_interval_ticks": maxi(1, int(simulation_lod_config.get("far_decision_interval", 8))),
		"headless_active_radius": maxf(0.0, float(simulation_lod_config.get("headless_active_radius", 720.0))),
		"very_far_sector_step_seconds": maxf(0.25, float(simulation_lod_config.get("very_far_sector_step_seconds", 0.75))),
		"show_lod_overlay": bool(lod_config.get("show_lod_overlay", false)),
	}


func _build_lod_context() -> Dictionary:
	var focus_rect := lod_focus_rect
	# Seeing the whole map must not promote the whole simulation to LOD0. The
	# overview renderer still shows every animal, while detailed simulation stays
	# centred on the camera and active interactions remain priority agents.
	if overview_mode:
		focus_rect = Rect2(lod_focus_center - Vector2.ONE * 0.5, Vector2.ONE)
	if focus_rect.size.is_zero_approx() and world_state != null:
		var headless_active_radius := float(lod_settings.get("headless_active_radius", 0.0))
		if headless_active_radius > 0.0:
			var center: Vector2 = world_state.bounds.get_center()
			focus_rect = Rect2(center - Vector2.ONE * headless_active_radius, Vector2.ONE * headless_active_radius * 2.0)
	var near_margin := float(lod_settings.get("near_margin", 192.0))
	var mid_margin := float(lod_settings.get("mid_margin", 768.0))
	var mid_update_interval := int(lod_settings.get("mid_update_interval_ticks", 2))
	var far_update_interval := int(lod_settings.get("far_update_interval_ticks", 5))
	if overview_mode:
		near_margin = float(lod_settings.get("overview_near_margin", near_margin))
		mid_margin = maxf(near_margin, float(lod_settings.get("overview_mid_margin", mid_margin)))
		mid_update_interval = int(lod_settings.get(
			"overview_mid_update_interval_ticks", mid_update_interval))
		far_update_interval = int(lod_settings.get(
			"overview_far_update_interval_ticks", far_update_interval))
	return {
		"enabled": lod_enabled,
		"overview": overview_mode,
		"focus_rect": focus_rect,
		"selected_agent_id": selected_agent_id,
		"near_margin": near_margin,
		"mid_margin": mid_margin,
		"mid_update_interval_ticks": mid_update_interval,
		"far_update_interval_ticks": far_update_interval,
		"mid_decision_interval_ticks": int(lod_settings.get("mid_decision_interval_ticks", 3)),
		"far_decision_interval_ticks": int(lod_settings.get("far_decision_interval_ticks", 8)),
		"headless_active_radius": float(lod_settings.get("headless_active_radius", 720.0)),
		"very_far_sector_step_seconds": float(lod_settings.get("very_far_sector_step_seconds", 0.75)),
	}


func _refresh_lod_assignments() -> void:
	if world_state == null:
		return
	world_state.refresh_lod_assignments(_build_lod_context())


func enable_interactive_worker() -> void:
	if _worker != null or world_state == null:
		return
	_worker = preload("res://scripts/core/simulation_worker.gd").new()
	_worker.configure(world_state, stats_system, event_bus, rng)
	var initial: Dictionary = world_state.export_state()
	event_bus = EventBusScript.new()
	event_bus.initialize(config_bundle.debug)
	stats_system = StatsSystemScript.new()
	stats_system.initialize(config_bundle, event_bus)
	stats_system.counters = _worker.stats.counters.duplicate()
	stats_system.latest_snapshot = _worker.stats.get_snapshot_view()
	world_state = WorldStateScript.new()
	var view_rng := RandomNumberGenerator.new()
	view_rng.seed = seed
	world_state.initialize(config_bundle, event_bus, view_rng)
	world_state.import_state(initial)
	# Initialisation events belong to construction, not to the running ecology.
	event_bus.clear()
	stats_system.counters = _worker.stats.counters.duplicate()
	_presentation_alpha = 0.0
	_worker_stepping = false


## Begin threading ticks. Separate from `enable_interactive_worker()` on purpose:
## that has to run early, because it replaces `world_state` and everything that
## binds to the manager must bind to the final object. Stepping has to start late,
## once nothing is still being loaded on the main thread. The caller owns the gap.
func begin_interactive_stepping() -> void:
	_worker_stepping = true


func _process_worker(delta: float) -> void:
	frame_times.add(delta * 1000.0)
	if not paused:
		_speed_wall += delta
		accumulator += delta * speed_multiplier
		_presentation_alpha = minf(1.0, _presentation_alpha + delta * speed_multiplier / tick_duration)
	var cap := tick_duration * float(MAX_SIMULATION_BACKLOG_STEPS)
	if accumulator > cap:
		dropped_simulation_seconds += accumulator - cap
		accumulator = cap
	if _job_in_flight and _done_semaphore.try_wait():
		var result: Dictionary = _take_worker_result()
		if _worker_started_usec > 0:
			worker_cycle_times.add(float(Time.get_ticks_usec() - _worker_started_usec) / 1000.0)
		_worker_started_usec = 0
		worker_snapshot_times.add(float(result.get("snapshot_ms", 0.0)))
		var apply_started := Time.get_ticks_usec()
		_apply_worker_frame(result)
		worker_apply_times.add(float(Time.get_ticks_usec() - apply_started) / 1000.0)
		_speed_sim += tick_duration
		_presentation_alpha = 0.0
		if _single_step_requested:
			_single_step_requested = false
			paused = true
	if _speed_wall >= 1.0:
		actual_speed = _speed_sim / _speed_wall
		_speed_wall = 0.0
		_speed_sim = 0.0
	if _worker_stepping and not _job_in_flight and not paused and (accumulator >= tick_duration or _single_step_requested):
		accumulator = maxf(0.0, accumulator - tick_duration)
		_post_worker_job()


## True while a posted tick has not been applied yet. The thread stays up between
## ticks, so `_worker_thread` no longer says whether a tick is in flight.
func is_worker_tick_in_flight() -> bool:
	return _job_in_flight


## Hands the next tick to the worker thread, starting the thread on first use.
## The LOD context is built fresh for the job, so the worker owns it outright.
func _post_worker_job() -> void:
	if _worker == null or _job_in_flight:
		return
	if _worker_thread == null:
		_worker_quit = false
		_worker_thread = Thread.new()
		_worker_thread.start(_worker_loop)
	_worker_mutex.lock()
	_worker_job = {"delta": tick_duration, "tick": current_tick, "time": simulation_time,
		"lod": _build_lod_context(), "inspected": selected_agent_id,
		"include_grass": bool(debug_flags.get("show_grass_density", false))}
	_worker_mutex.unlock()
	_worker_started_usec = Time.get_ticks_usec()
	_job_in_flight = true
	_job_semaphore.post()


func _worker_loop() -> void:
	while true:
		_job_semaphore.wait()
		_worker_mutex.lock()
		var stopping := _worker_quit
		var job: Dictionary = _worker_job
		_worker_job = {}
		_worker_mutex.unlock()
		if stopping:
			return
		if job.is_empty():
			continue
		var result: Dictionary = _worker.step(float(job.delta), int(job.tick), float(job.time),
			job.lod, int(job.inspected), bool(job.include_grass))
		_worker_mutex.lock()
		_worker_result = result
		_worker_mutex.unlock()
		_done_semaphore.post()


func _take_worker_result() -> Dictionary:
	_worker_mutex.lock()
	var result: Dictionary = _worker_result
	_worker_result = {}
	_worker_mutex.unlock()
	_job_in_flight = false
	return result


## Joins the worker. A tick already running finishes and its result is dropped:
## whoever stops the thread is discarding this simulation anyway, and
## `synchronize_worker()` is the path that keeps a result.
func _stop_worker_thread() -> void:
	if _worker_thread == null:
		return
	_worker_mutex.lock()
	_worker_quit = true
	_worker_mutex.unlock()
	_job_semaphore.post()
	_worker_thread.wait_to_finish()
	_worker_thread = null
	_worker_quit = false
	_job_in_flight = false
	_worker_job = {}
	_worker_result = {}
	while _done_semaphore.try_wait():
		pass


func _apply_worker_frame(data: Dictionary) -> void:
	var next_sequence := int(data.get("sequence", 0))
	if not bool(data.get("full", false)) and next_sequence != _worker_sequence + 1:
		data = _worker.full_presentation_snapshot(selected_agent_id)
		next_sequence = int(data.get("sequence", _worker_sequence))
	_worker_sequence = next_sequence
	worker_snapshot_counts = data.get("snapshot_counts", {}).duplicate()
	current_tick = int(data.tick)
	simulation_time = float(data.time)
	tick_times.add(float(data.tick_ms))
	var full_snapshot := bool(data.get("full", false))
	var previous_agents: Dictionary = world_state.agents
	var next_agents := {} if full_snapshot else previous_agents
	if full_snapshot:
		world_state.living_agents.clear()
		world_state._living_agent_index_by_id.clear()
	else:
		for removed_id_value in data.get("agent_removals", PackedInt32Array()):
			var removed_id := int(removed_id_value)
			var removed_agent = previous_agents.get(removed_id)
			if removed_agent != null:
				world_state.spatial_grid.remove(removed_agent)
				removed_agent.is_alive = false
			previous_agents.erase(removed_id)
			world_state._living_agent_index_by_id.erase(removed_id)
		world_state.living_agents.resize(data.agents.size())
	for record_index in data.agents.size():
		var record: Dictionary = data.agents[record_index]
		var agent = previous_agents.get(int(record.id))
		var previous_position := Vector2.ZERO
		if agent == null:
			if not bool(record.get("full_record", false)):
				data = _worker.full_presentation_snapshot(selected_agent_id)
				_apply_worker_frame(data)
				return
			agent = world_state._restore_agent_record(record)
			world_state.spatial_grid.insert(agent)
		else:
			previous_position = agent.position
			if bool(record.get("full_record", false)):
				agent.apply_runtime_state(record)
			else:
				agent.apply_presentation_state(record)
			world_state.spatial_grid.update_agent(agent, previous_position)
		agent.last_action_reason = record.get("last_action_reason", agent.last_action_reason)
		agent.last_action_scores = record.get("last_action_scores", agent.last_action_scores)
		agent.last_action_raw_scores = record.get("last_action_raw_scores", agent.last_action_raw_scores)
		next_agents[agent.id] = agent
		if full_snapshot:
			world_state.living_agents.append(agent)
		else:
			world_state.living_agents[record_index] = agent
		world_state._living_agent_index_by_id[agent.id] = record_index
	if full_snapshot:
		for id in previous_agents:
			if not next_agents.has(id):
				world_state.spatial_grid.remove(previous_agents[id])
				previous_agents[id].is_alive = false
		world_state.agents = next_agents
	for carcass_id in data.get("carcass_removals", PackedInt32Array()):
		world_state.carcasses.erase(int(carcass_id))
	for carcass_id in data.get("carcass_upserts", {}):
		world_state.carcasses[int(carcass_id)] = data.carcass_upserts[carcass_id]
	var grass_delta: Dictionary = data.get("grass_delta", {})
	if grass_delta.has("full"):
		world_state.resource_system._cells = grass_delta.full.duplicate()
	else:
		var indices: PackedInt32Array = grass_delta.get("indices", PackedInt32Array())
		var values: PackedFloat32Array = grass_delta.get("values", PackedFloat32Array())
		for index in mini(indices.size(), values.size()):
			world_state.resource_system._cells[indices[index]] = values[index]
	world_state.resource_system.total_biomass = float(data.biomass)
	world_state.resource_system._biomass_totals_by_biome = data.biomes
	if bool(data.get("full", false)):
		world_state._sector_states.clear()
		world_state._group_state_cache.clear()
	for key in data.get("sector_removals", []):
		world_state._sector_states.erase(key)
	for key in data.get("sector_upserts", {}):
		world_state._sector_states[key] = data.sector_upserts[key]
	for key in data.get("group_removals", []):
		world_state._group_state_cache.erase(key)
	for key in data.get("group_upserts", {}):
		world_state._group_state_cache[key] = data.group_upserts[key]
	world_state.lod_counts = data.lod_counts
	world_state.performance_counters = data.performance
	for key in data.performance:
		if not str(key).ends_with("_ms"):
			continue
		if not simulation_phase_times.has(key):
			simulation_phase_times[key] = preload("res://scripts/stats/performance_window.gd").new()
		simulation_phase_times[key].add(float(data.performance[key]))
	world_state.current_tick = current_tick - 1
	world_state.current_time = simulation_time - tick_duration
	world_state.climate.sample(world_state.current_time)
	for event in data.events:
		event_bus.emit_event(event)
	stats_system.counters = data.counters
	if stats_system.latest_snapshot.get("tick", -1) != data.metrics.get("tick", -1):
		stats_system.time_series.append(data.metrics)
		if stats_system.time_series.size() > stats_system.history_limit:
			stats_system.time_series.pop_front()
	stats_system.latest_snapshot = data.metrics
	if selected_agent_id != -1 and world_state.get_agent(selected_agent_id) == null:
		selected_agent_id = -1
		selection_changed.emit(-1)
		clear_focus()
	tick_completed.emit(current_tick, data.metrics)


## Called only for an explicit save/load boundary, never by the frame renderer.
func synchronize_worker() -> void:
	if _job_in_flight:
		_done_semaphore.wait()
		var result: Dictionary = _take_worker_result()
		if _worker_started_usec > 0:
			worker_cycle_times.add(float(Time.get_ticks_usec() - _worker_started_usec) / 1000.0)
		_worker_started_usec = 0
		worker_snapshot_times.add(float(result.get("snapshot_ms", 0.0)))
		var apply_started := Time.get_ticks_usec()
		_apply_worker_frame(result)
		worker_apply_times.add(float(Time.get_ticks_usec() - apply_started) / 1000.0)
		_speed_sim += tick_duration
		_presentation_alpha = 0.0
		if _single_step_requested:
			_single_step_requested = false
			paused = true

func export_simulation_state() -> Dictionary:
	synchronize_worker()
	return world_state.export_state() if _worker == null else _worker.world.export_state()
