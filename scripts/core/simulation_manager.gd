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

var _worker = null
var _worker_thread: Thread = null
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
var frame_times = preload("res://scripts/stats/performance_window.gd").new()
var tick_times = preload("res://scripts/stats/performance_window.gd").new()
var render_times = preload("res://scripts/stats/performance_window.gd").new()
var actual_speed: float = 0.0
var dropped_simulation_seconds: float = 0.0
var _speed_wall: float = 0.0
var _speed_sim: float = 0.0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS


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

	var debug_config: Dictionary = config_bundle.get("debug", {})
	debug_flags = debug_config.get("overlays", {}).duplicate(true)
	ui_refresh_interval_ticks = max(1, int(debug_config.get("ui_refresh_interval_ticks", 5)))
	lod_settings = _build_lod_settings(debug_config)
	lod_enabled = bool(lod_settings.get("enabled", false))
	lod_focus_rect = Rect2()
	debug_flags["show_lod_overlay"] = bool(debug_flags.get("show_lod_overlay", lod_settings.get("show_lod_overlay", false)))
	var speeds: Array = debug_config.get("speed_steps", [1.0])
	if speeds.is_empty():
		speeds = [1.0]
	var default_index := int(debug_config.get("default_speed_index", 0))
	default_index = clampi(default_index, 0, speeds.size() - 1)
	speed_multiplier = float(speeds[default_index])

	stats_system.record_sample(world_state, current_tick, simulation_time)
	tick_completed.emit(current_tick, stats_system.get_snapshot())


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
	var max_accumulator := tick_duration * float(MAX_SIMULATION_STEPS_PER_FRAME)
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
	return {"frame_ms": frame_times.summary(), "tick_ms": tick_times.summary(),
		"render_cpu_ms": render_times.summary(), "actual_speed": actual_speed,
		"requested_speed": speed_multiplier, "dropped_simulation_seconds": dropped_simulation_seconds}


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
	tick_completed.emit(current_tick, stats_system.get_snapshot())


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
	if lod_focus_rect == rect:
		return
	lod_focus_rect = rect
	_refresh_lod_assignments()


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
	if _worker_thread != null:
		_worker_thread.wait_to_finish()
		_worker_thread = null
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
		"mid_update_interval_ticks": maxi(1, int(lod_config.get("mid_update_interval_ticks", 2))),
		"far_update_interval_ticks": maxi(1, int(lod_config.get("far_update_interval_ticks", 5))),
		"mid_decision_interval_ticks": maxi(1, int(simulation_lod_config.get("mid_decision_interval", 3))),
		"far_decision_interval_ticks": maxi(1, int(simulation_lod_config.get("far_decision_interval", 8))),
		"headless_active_radius": maxf(0.0, float(simulation_lod_config.get("headless_active_radius", 720.0))),
		"very_far_sector_step_seconds": maxf(0.25, float(simulation_lod_config.get("very_far_sector_step_seconds", 0.75))),
		"show_lod_overlay": bool(lod_config.get("show_lod_overlay", false)),
	}


func _build_lod_context() -> Dictionary:
	var focus_rect := lod_focus_rect
	if focus_rect.size.is_zero_approx() and world_state != null:
		var headless_active_radius := float(lod_settings.get("headless_active_radius", 0.0))
		if headless_active_radius > 0.0:
			var center: Vector2 = world_state.bounds.get_center()
			focus_rect = Rect2(center - Vector2.ONE * headless_active_radius, Vector2.ONE * headless_active_radius * 2.0)
	return {
		"enabled": lod_enabled,
		"focus_rect": focus_rect,
		"selected_agent_id": selected_agent_id,
		"near_margin": float(lod_settings.get("near_margin", 192.0)),
		"mid_margin": float(lod_settings.get("mid_margin", 768.0)),
		"mid_update_interval_ticks": int(lod_settings.get("mid_update_interval_ticks", 2)),
		"far_update_interval_ticks": int(lod_settings.get("far_update_interval_ticks", 5)),
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
	stats_system.latest_snapshot = _worker.stats.get_snapshot()
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
	var cap := tick_duration * float(MAX_SIMULATION_STEPS_PER_FRAME)
	if accumulator > cap:
		dropped_simulation_seconds += accumulator - cap
		accumulator = cap
	if _worker_thread != null and not _worker_thread.is_alive():
		var result: Dictionary = _worker_thread.wait_to_finish()
		_worker_thread = null
		_apply_worker_frame(result)
		_speed_sim += tick_duration
		_presentation_alpha = 0.0
		if _single_step_requested:
			_single_step_requested = false
			paused = true
	if _speed_wall >= 1.0:
		actual_speed = _speed_sim / _speed_wall
		_speed_wall = 0.0
		_speed_sim = 0.0
	if _worker_stepping and _worker_thread == null and not paused and (accumulator >= tick_duration or _single_step_requested):
		accumulator = maxf(0.0, accumulator - tick_duration)
		_worker_thread = Thread.new()
		_worker_thread.start(_worker.step.bind(tick_duration, current_tick, simulation_time, _build_lod_context().duplicate(true), selected_agent_id))


func _apply_worker_frame(data: Dictionary) -> void:
	current_tick = int(data.tick)
	simulation_time = float(data.time)
	tick_times.add(float(data.tick_ms))
	var previous_agents: Dictionary = world_state.agents
	var next_agents := {}
	world_state.living_agents.clear()
	for record in data.agents:
		var agent = previous_agents.get(int(record.id))
		if agent == null:
			agent = world_state._restore_agent_record(record)
		else:
			agent.apply_runtime_state(record)
		agent.last_action_reason = record.get("last_action_reason", agent.last_action_reason)
		agent.last_action_scores = record.get("last_action_scores", agent.last_action_scores)
		agent.last_action_raw_scores = record.get("last_action_raw_scores", agent.last_action_raw_scores)
		next_agents[agent.id] = agent
		world_state.living_agents.append(agent)
	for id in previous_agents:
		if not next_agents.has(id):
			previous_agents[id].is_alive = false
	world_state.agents = next_agents
	world_state.carcasses = data.carcasses
	world_state.resource_system._cells = data.grass
	world_state.resource_system.total_biomass = float(data.biomass)
	world_state.resource_system._biomass_totals_by_biome = data.biomes
	world_state._sector_states = data.sectors
	world_state._group_state_cache = data.groups
	world_state.lod_counts = data.lod_counts
	world_state.performance_counters = data.performance
	world_state.current_tick = current_tick - 1
	world_state.current_time = simulation_time - tick_duration
	world_state.climate.sample(world_state.current_time)
	world_state.spatial_grid.rebuild(world_state.living_agents)
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
	if _worker_thread != null:
		var result: Dictionary = _worker_thread.wait_to_finish()
		_worker_thread = null
		_apply_worker_frame(result)

func export_simulation_state() -> Dictionary:
	synchronize_worker()
	return world_state.export_state() if _worker == null else _worker.world.export_state()
