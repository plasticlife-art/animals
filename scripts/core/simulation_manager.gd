class_name SimulationManager
extends Node

signal tick_completed(tick: int, snapshot: Dictionary)
signal selection_changed(agent_id: int)
signal export_completed(paths: Dictionary)

const ConfigLoaderScript = preload("res://scripts/core/config_loader.gd")
const EventBusScript = preload("res://scripts/core/event_bus.gd")
const WorldStateScript = preload("res://scripts/world/world_state.gd")
const StatsSystemScript = preload("res://scripts/stats/stats_system.gd")
const TelemetryLoggerScript = preload("res://scripts/stats/telemetry_logger.gd")

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
var debug_flags: Dictionary = {}
var _single_step_requested: bool = false


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
	_single_step_requested = false

	var debug_config: Dictionary = config_bundle.get("debug", {})
	debug_flags = debug_config.get("overlays", {}).duplicate(true)
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
	while accumulator >= tick_duration:
		accumulator -= tick_duration
		step_once()
		if _single_step_requested:
			_single_step_requested = false
			paused = true
			break


func step_once() -> void:
	if world_state == null:
		return
	var started_at_usec := Time.get_ticks_usec()
	world_state.step(tick_duration, current_tick, simulation_time)
	stats_system.record_step_duration(float(Time.get_ticks_usec() - started_at_usec) / 1000.0)
	current_tick += 1
	simulation_time += tick_duration
	if selected_agent_id != -1 and world_state.get_agent(selected_agent_id) == null:
		selected_agent_id = -1
		selection_changed.emit(selected_agent_id)
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


func select_agent_at_position(position: Vector2, radius: float) -> void:
	if world_state == null:
		return
	var nearby := world_state.query_agents(position, radius, "", -1)
	if nearby.is_empty():
		selected_agent_id = -1
	else:
		var nearest = nearby[0]
		var nearest_distance_sq: float = nearest.position.distance_squared_to(position)
		for candidate in nearby:
			var distance_sq: float = candidate.position.distance_squared_to(position)
			if distance_sq < nearest_distance_sq:
				nearest = candidate
				nearest_distance_sq = distance_sq
		selected_agent_id = nearest.id
	selection_changed.emit(selected_agent_id)


func get_selected_agent():
	if selected_agent_id == -1:
		return null
	return world_state.get_agent(selected_agent_id)


func get_selected_agent_summary() -> Dictionary:
	var agent = get_selected_agent()
	return {} if agent == null else agent.get_debug_summary()


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
