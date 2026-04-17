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

const MAX_SIMULATION_STEPS_PER_FRAME := 4

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
var _single_step_requested: bool = false
var lod_enabled: bool = false
var lod_settings: Dictionary = {}
var lod_focus_rect: Rect2 = Rect2()


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS


func initialize(config_override: Dictionary = {}, seed_override: int = -1) -> void:
	config_bundle = config_override if not config_override.is_empty() else ConfigLoaderScript.load_config_bundle()
	seed = seed_override if seed_override >= 0 else int(config_bundle.get("world", {}).get("seed", 1337))
	rng.seed = seed

	event_bus = EventBusScript.new()
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
	lod_settings = _build_lod_settings(debug_config)
	lod_enabled = false
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
	if paused and not _single_step_requested:
		return

	accumulator += delta * speed_multiplier
	var max_accumulator := tick_duration * float(MAX_SIMULATION_STEPS_PER_FRAME)
	if accumulator > max_accumulator:
		accumulator = max_accumulator

	var steps_this_frame := 0
	while accumulator >= tick_duration and steps_this_frame < MAX_SIMULATION_STEPS_PER_FRAME:
		accumulator -= tick_duration
		step_once()
		steps_this_frame += 1
		if _single_step_requested:
			_single_step_requested = false
			paused = true
			break


func step_once() -> void:
	if world_state == null:
		return
	var started_at_usec := Time.get_ticks_usec()
	world_state.step(tick_duration, current_tick, simulation_time, _build_lod_context())
	stats_system.record_step_duration(float(Time.get_ticks_usec() - started_at_usec) / 1000.0)
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
	var nearby := world_state.query_agents(position, radius, "", -1)
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
	return {} if agent == null else agent.get_debug_summary()


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


func _build_lod_settings(debug_config: Dictionary) -> Dictionary:
	var lod_config: Dictionary = debug_config.get("lod", {})
	var near_margin := maxf(0.0, float(lod_config.get("near_margin", 192.0)))
	return {
		"enabled": bool(lod_config.get("enabled", false)),
		"near_margin": near_margin,
		"mid_margin": maxf(near_margin, float(lod_config.get("mid_margin", 768.0))),
		"mid_update_interval_ticks": maxi(1, int(lod_config.get("mid_update_interval_ticks", 2))),
		"far_update_interval_ticks": maxi(1, int(lod_config.get("far_update_interval_ticks", 5))),
		"show_lod_overlay": bool(lod_config.get("show_lod_overlay", false)),
	}


func _build_lod_context() -> Dictionary:
	return {
		"enabled": lod_enabled and not lod_focus_rect.size.is_zero_approx(),
		"focus_rect": lod_focus_rect,
		"selected_agent_id": selected_agent_id,
		"near_margin": float(lod_settings.get("near_margin", 192.0)),
		"mid_margin": float(lod_settings.get("mid_margin", 768.0)),
		"mid_update_interval_ticks": int(lod_settings.get("mid_update_interval_ticks", 2)),
		"far_update_interval_ticks": int(lod_settings.get("far_update_interval_ticks", 5)),
	}


func _refresh_lod_assignments() -> void:
	if world_state == null:
		return
	world_state.refresh_lod_assignments(_build_lod_context())
