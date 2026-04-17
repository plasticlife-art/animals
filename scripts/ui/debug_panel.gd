class_name DebugPanel
extends PanelContainer

signal pause_toggled(is_paused: bool)
signal single_step_requested
signal speed_selected(multiplier: float)
signal export_requested
signal focus_mode_selected(mode: String)
signal overlay_flag_changed(flag_name: String, enabled: bool)
signal lod_enabled_toggled(enabled: bool)

@onready var pause_button: Button = %PauseButton
@onready var step_button: Button = %StepButton
@onready var speed_option: OptionButton = %SpeedOption
@onready var export_button: Button = %ExportButton
@onready var focus_mode_option: OptionButton = %FocusModeOption
@onready var lod_enabled_check: CheckBox = %LodEnabledCheck
@onready var summary_label: RichTextLabel = %SummaryLabel
@onready var inspector_text: RichTextLabel = %InspectorText
@onready var event_log_text: RichTextLabel = %EventLogText
@onready var status_label: RichTextLabel = %StatusLabel

var simulation_manager: SimulationManager
var is_paused: bool = false
var overlay_checkboxes: Dictionary = {}
var speed_steps: Array = []
var ui_refresh_interval_ticks: int = 5
var event_log_visible_limit: int = 12


func _ready() -> void:
	pause_button.pressed.connect(_on_pause_button_pressed)
	step_button.pressed.connect(_on_step_button_pressed)
	export_button.pressed.connect(_on_export_button_pressed)
	speed_option.item_selected.connect(_on_speed_selected)
	focus_mode_option.item_selected.connect(_on_focus_mode_selected)
	lod_enabled_check.toggled.connect(_on_lod_enabled_check_toggled)
	focus_mode_option.add_item("Off", 0)
	focus_mode_option.add_item("Agent", 1)
	focus_mode_option.add_item("Flock", 2)

	overlay_checkboxes = {
		"show_state_labels": %StateLabelsCheck,
		"show_target_lines": %TargetLinesCheck,
		"show_vision_radius": %VisionRadiusCheck,
		"show_herd_relations": %HerdRelationsCheck,
		"show_chase_lines": %ChaseLinesCheck,
		"show_grass_density": %GrassDensityCheck,
		"show_population_density": %PopulationDensityCheck,
		"show_water_overlay": %WaterOverlayCheck,
		"show_lod_overlay": %LodOverlayCheck,
	}
	for flag_name in overlay_checkboxes.keys():
		var checkbox: CheckBox = overlay_checkboxes[flag_name]
		checkbox.toggled.connect(_on_overlay_toggled.bind(flag_name))


func bind_manager(manager: SimulationManager) -> void:
	simulation_manager = manager
	simulation_manager.tick_completed.connect(_on_tick_completed)
	simulation_manager.selection_changed.connect(_on_selection_changed)
	simulation_manager.focus_mode_changed.connect(_on_focus_mode_changed)
	simulation_manager.export_completed.connect(_on_export_completed)
	refresh_from_manager()


func apply_debug_settings(debug_config: Dictionary, flags: Dictionary, is_lod_enabled: bool) -> void:
	speed_steps = debug_config.get("speed_steps", [1.0])
	ui_refresh_interval_ticks = max(1, int(debug_config.get("ui_refresh_interval_ticks", 5)))
	event_log_visible_limit = max(1, int(debug_config.get("event_log_visible_limit", 12)))
	if speed_steps.is_empty():
		speed_steps = [1.0]
	speed_option.clear()
	for index in range(speed_steps.size()):
		speed_option.add_item("x%s" % str(speed_steps[index]).trim_suffix(".0"), index)
	var default_index := clampi(int(debug_config.get("default_speed_index", 0)), 0, max(0, speed_steps.size() - 1))
	speed_option.select(default_index)
	lod_enabled_check.set_pressed_no_signal(is_lod_enabled)

	for flag_name in overlay_checkboxes.keys():
		var checkbox: CheckBox = overlay_checkboxes[flag_name]
		checkbox.set_pressed_no_signal(bool(flags.get(flag_name, false)))


func set_status_text(text: String) -> void:
	status_label.text = text


func refresh_from_manager() -> void:
	if simulation_manager == null:
		return
	set_paused_state(simulation_manager.paused)
	set_focus_mode_state(simulation_manager.focus_mode)
	set_lod_enabled_state(simulation_manager.lod_enabled)
	_refresh_summary(simulation_manager.stats_system.get_snapshot())
	_refresh_inspector(simulation_manager.get_selected_agent_summary())
	_refresh_event_log()


func set_paused_state(value: bool) -> void:
	is_paused = value
	pause_button.text = "Resume" if is_paused else "Pause"


func set_focus_mode_state(mode: String) -> void:
	var option_index := 0
	match mode:
		"agent":
			option_index = 1
		"flock":
			option_index = 2
	focus_mode_option.select(option_index)


func set_lod_enabled_state(value: bool) -> void:
	lod_enabled_check.set_pressed_no_signal(value)


func _on_pause_button_pressed() -> void:
	set_paused_state(not is_paused)
	pause_toggled.emit(is_paused)


func _on_step_button_pressed() -> void:
	single_step_requested.emit()


func _on_export_button_pressed() -> void:
	export_requested.emit()


func _on_speed_selected(index: int) -> void:
	if index < 0 or index >= speed_steps.size():
		return
	speed_selected.emit(float(speed_steps[index]))


func _on_focus_mode_selected(index: int) -> void:
	var mode := "off"
	if index == 1:
		mode = "agent"
	elif index == 2:
		mode = "flock"
	focus_mode_selected.emit(mode)


func _on_lod_enabled_check_toggled(enabled: bool) -> void:
	lod_enabled_toggled.emit(enabled)


func _on_overlay_toggled(enabled: bool, flag_name: String) -> void:
	overlay_flag_changed.emit(flag_name, enabled)


func _on_tick_completed(tick: int, snapshot: Dictionary) -> void:
	if tick != 0 and tick % ui_refresh_interval_ticks != 0:
		return
	_refresh_summary(snapshot)
	_refresh_inspector(simulation_manager.get_selected_agent_summary())
	_refresh_event_log()


func _on_selection_changed(_agent_id: int) -> void:
	_refresh_inspector(simulation_manager.get_selected_agent_summary())


func _on_focus_mode_changed(mode: String) -> void:
	set_focus_mode_state(mode)


func _on_export_completed(paths: Dictionary) -> void:
	set_status_text("Last export:\n%s\n%s\n%s" % [
		paths.get("metrics_csv", ""),
		paths.get("events_json", ""),
		paths.get("summary_json", ""),
	])


func _refresh_summary(snapshot: Dictionary) -> void:
	if snapshot.is_empty():
		summary_label.text = "No simulation data yet."
		return
	summary_label.text = "\n".join([
		"[b]Tick[/b] %d    [b]Time[/b] %.1fs    [b]Seed[/b] %d" % [
			int(snapshot.get("tick", 0)),
			float(snapshot.get("time_seconds", 0.0)),
			simulation_manager.seed,
		],
		"[b]Herbivores[/b] %d    [b]Predators[/b] %d" % [
			int(snapshot.get("herbivore_population", 0)),
			int(snapshot.get("predator_population", 0)),
		],
		"[b]Births[/b] H:%d P:%d    [b]Deaths[/b] H:%d P:%d" % [
			int(snapshot.get("births_herbivore", 0)),
			int(snapshot.get("births_predator", 0)),
			int(snapshot.get("deaths_herbivore", 0)),
			int(snapshot.get("deaths_predator", 0)),
		],
		"[b]Starvation[/b] %d    [b]Thirst[/b] %d    [b]Predation[/b] %d    [b]Old age[/b] %d" % [
			int(snapshot.get("deaths_starvation", 0)),
			int(snapshot.get("deaths_thirst", 0)),
			int(snapshot.get("deaths_predation", 0)),
			int(snapshot.get("deaths_old_age", 0)),
		],
		"[b]Avg hunger[/b] %.1f    [b]Avg energy[/b] %.1f    [b]Hunt success[/b] %.2f" % [
			float(snapshot.get("average_hunger", 0.0)),
			float(snapshot.get("average_energy", 0.0)),
			float(snapshot.get("hunt_success_rate", 0.0)),
		],
		"[b]LOD[/b] %s    [b]LOD0[/b] %d    [b]LOD1[/b] %d    [b]LOD2[/b] %d" % [
			"On" if simulation_manager.lod_enabled else "Off",
			int(snapshot.get("lod0_agents", 0)),
			int(snapshot.get("lod1_agents", 0)),
			int(snapshot.get("lod2_agents", 0)),
		],
		"[b]Step avg[/b] %.2f ms    [b]Step max[/b] %.2f ms" % [
			float(snapshot.get("sim_step_ms_avg", 0.0)),
			float(snapshot.get("sim_step_ms_max", 0.0)),
		],
	])


func _refresh_inspector(agent_summary: Dictionary) -> void:
	if agent_summary.is_empty():
		inspector_text.text = "No agent selected."
		return
	inspector_text.text = "\n".join([
		"[b]ID[/b] %s" % str(agent_summary.get("id", "-")),
		"[b]Species[/b] %s    [b]Sex[/b] %s" % [agent_summary.get("species", "-"), agent_summary.get("sex", "-")],
		"[b]State[/b] %s    [b]Alive[/b] %s" % [agent_summary.get("state", "-"), str(agent_summary.get("alive", false))],
		"[b]Energy[/b] %.1f    [b]Hunger[/b] %.1f    [b]Thirst[/b] %.1f" % [
			float(agent_summary.get("energy", 0.0)),
			float(agent_summary.get("hunger", 0.0)),
			float(agent_summary.get("thirst", 0.0)),
		],
		"[b]Age[/b] %.1f    [b]Speed[/b] %.1f" % [
			float(agent_summary.get("age", 0.0)),
			float(agent_summary.get("speed", 0.0)),
		],
		"[b]Target[/b] %s" % str(agent_summary.get("target", "-")),
	])


func _refresh_event_log() -> void:
	if simulation_manager == null or simulation_manager.event_bus == null:
		event_log_text.text = "No events yet."
		return
	var events: Array = simulation_manager.event_bus.get_recent_events(event_log_visible_limit)
	if events.is_empty():
		event_log_text.text = "No events yet."
		return
	var lines := PackedStringArray()
	for event in events:
		lines.append(
			"%04d  %s  #%d -> %s" % [
				int(event.get("tick", 0)),
				str(event.get("type", "")),
				int(event.get("agent_id", -1)),
				JSON.stringify(event.get("data", {})),
			]
		)
	event_log_text.text = "\n".join(lines)
