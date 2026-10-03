class_name DebugPanel
extends PanelContainer

signal pause_toggled(is_paused: bool)
signal single_step_requested
signal speed_selected(multiplier: float)
signal export_requested
signal focus_mode_selected(mode: String)
signal overlay_flag_changed(flag_name: String, enabled: bool)
signal lod_enabled_toggled(enabled: bool)

@onready var pause_button: Button = get_node_or_null("%PauseButton")
@onready var step_button: Button = get_node_or_null("%StepButton")
@onready var speed_option: OptionButton = get_node_or_null("%SpeedOption")
@onready var export_button: Button = get_node_or_null("%ExportButton")
@onready var focus_mode_option: OptionButton = get_node_or_null("%FocusModeOption")
@onready var lod_enabled_check: CheckBox = get_node_or_null("%LodEnabledCheck")
@onready var summary_label: RichTextLabel = get_node_or_null("%SummaryLabel")
@onready var inspector_text: RichTextLabel = get_node_or_null("%InspectorText")
@onready var event_log_text: RichTextLabel = get_node_or_null("%EventLogText")
@onready var status_label: RichTextLabel = get_node_or_null("%StatusLabel")

## The developer's view of the world, in Russian like the rest of the interface. Shown only
## in developer mode (`debug.developer_mode`, F12 at runtime) and then on Tab.

## The event log's names for the bus's event types; a type missing here shows as it is.
const EVENT_NAMES := {
	"AgentDied": "смерть", "AgentStarved": "голод", "AgentDiedOfAge": "старость", "AgentBorn": "рождение",
	"AgentReproduced": "потомство", "HerdSplit": "деление стада", "HerdMigrates": "кочёвка стада",
	"GrassConsumed": "трава", "WaterConsumed": "водопой", "HuntStarted": "охота",
	"AttackAttempt": "бросок", "PredationSuccess": "добыча", "PredationFailed": "промах",
	"PreySearchStarted": "поиск следа", "PreySearchExpired": "след потерян", "PreyReacquired": "след найден",
	"CarcassSpawned": "туша", "CarcassConsumed": "кормёжка у туши", "CarcassExpired": "туша истлела",
}

var simulation_manager: SimulationManager
var is_paused: bool = false
var overlay_checkboxes: Dictionary = {}
var speed_steps: Array = []
var event_log_visible_limit: int = 12


func _ready() -> void:
	if pause_button != null:
		pause_button.pressed.connect(_on_pause_button_pressed)
	if step_button != null:
		step_button.pressed.connect(_on_step_button_pressed)
	if export_button != null:
		export_button.pressed.connect(_on_export_button_pressed)
	if speed_option != null:
		speed_option.item_selected.connect(_on_speed_selected)
	if focus_mode_option != null:
		focus_mode_option.item_selected.connect(_on_focus_mode_selected)
		focus_mode_option.clear()
		focus_mode_option.add_item("Выкл", 0)
		focus_mode_option.add_item("Животное", 1)
		focus_mode_option.add_item("Стадо", 2)
	if lod_enabled_check != null:
		lod_enabled_check.toggled.connect(_on_lod_enabled_check_toggled)

	overlay_checkboxes.clear()
	_try_register_overlay_checkbox("show_biomes", "%BiomesCheck")
	_try_register_overlay_checkbox("show_obstacles", "%ObstaclesCheck")
	_try_register_overlay_checkbox("show_state_labels", "%StateLabelsCheck")
	_try_register_overlay_checkbox("show_target_lines", "%TargetLinesCheck")
	_try_register_overlay_checkbox("show_vision_radius", "%VisionRadiusCheck")
	_try_register_overlay_checkbox("show_herd_relations", "%HerdRelationsCheck")
	_try_register_overlay_checkbox("show_chase_lines", "%ChaseLinesCheck")
	_try_register_overlay_checkbox("show_grass_density", "%GrassDensityCheck")
	_try_register_overlay_checkbox("show_fear", "%FearCheck")
	_try_register_overlay_checkbox("show_population_density", "%PopulationDensityCheck")
	_try_register_overlay_checkbox("show_water_overlay", "%WaterOverlayCheck")
	_try_register_overlay_checkbox("show_carcasses", "%CarcassesCheck")
	_try_register_overlay_checkbox("show_selected_path", "%SelectedPathCheck")
	_try_register_overlay_checkbox("show_lod_overlay", "%LodOverlayCheck")
	_try_register_overlay_checkbox("show_minimap_water", "%MinimapWaterCheck")
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
	event_log_visible_limit = max(1, int(debug_config.get("event_log_visible_limit", 12)))
	if speed_steps.is_empty():
		speed_steps = [1.0]
	if speed_option != null:
		speed_option.clear()
		for index in range(speed_steps.size()):
			speed_option.add_item("x%s" % str(speed_steps[index]).trim_suffix(".0"), index)
		var default_index := clampi(int(debug_config.get("default_speed_index", 0)), 0, max(0, speed_steps.size() - 1))
		speed_option.select(default_index)
	if lod_enabled_check != null:
		lod_enabled_check.set_pressed_no_signal(is_lod_enabled)

	for flag_name in overlay_checkboxes.keys():
		var checkbox: CheckBox = overlay_checkboxes[flag_name]
		checkbox.set_pressed_no_signal(bool(flags.get(flag_name, false)))


func set_status_text(text: String) -> void:
	if status_label == null:
		return
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
	if pause_button != null:
		pause_button.text = "Дальше" if is_paused else "Пауза"


func set_focus_mode_state(mode: String) -> void:
	if focus_mode_option == null:
		return
	var option_index := 0
	match mode:
		"agent":
			option_index = 1
		"flock":
			option_index = 2
	focus_mode_option.select(option_index)


## Shows a layer switched from elsewhere - the player's bar - without emitting it back.
func set_overlay_state(flag_name: String, enabled: bool) -> void:
	if overlay_checkboxes.has(flag_name):
		overlay_checkboxes[flag_name].set_pressed_no_signal(enabled)


func set_speed_state(multiplier: float) -> void:
	if speed_option == null:
		return
	for index in range(speed_steps.size()):
		if is_equal_approx(float(speed_steps[index]), multiplier):
			speed_option.select(index)
			return


func set_lod_enabled_state(value: bool) -> void:
	if lod_enabled_check != null:
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
	if simulation_manager != null and not simulation_manager.should_refresh_ui_on_tick(tick):
		return
	_refresh_summary(snapshot)
	_refresh_inspector(simulation_manager.get_selected_agent_summary())
	_refresh_event_log()


func _on_selection_changed(_agent_id: int) -> void:
	_refresh_inspector(simulation_manager.get_selected_agent_summary())


func _on_focus_mode_changed(mode: String) -> void:
	set_focus_mode_state(mode)


func _on_export_completed(paths: Dictionary) -> void:
	set_status_text("Последний экспорт:\n%s\n%s\n%s" % [
		paths.get("metrics_csv", ""),
		paths.get("events_json", ""),
		paths.get("summary_json", ""),
	])


## The population and birth/death lines, one entry per species out of the
## snapshot rather than two spelled-out names. Labels come from
## `species.json -> role.label`, so a new species appears here by existing.
func _species_population_line(snapshot: Dictionary) -> String:
	var parts: Array[String] = []
	for entry in _species_entries():
		parts.append("[b]%s[/b] %d" % [entry["label"], int(snapshot.get("%s_population" % entry["id"], 0))])
	return "    ".join(parts)


func _species_vital_line(snapshot: Dictionary) -> String:
	var births: Array[String] = []
	var deaths: Array[String] = []
	for entry in _species_entries():
		var initial: String = String(entry["label"]).substr(0, 1)
		births.append("%s:%d" % [initial, int(snapshot.get("births_%s" % entry["id"], 0))])
		deaths.append("%s:%d" % [initial, int(snapshot.get("deaths_%s" % entry["id"], 0))])
	return "[b]Рождения[/b] %s    [b]Смерти[/b] %s" % [" ".join(births), " ".join(deaths)]


func _species_entries() -> Array:
	var entries: Array = []
	if simulation_manager == null:
		return entries
	var species_config: Dictionary = simulation_manager.config_bundle.get("species", {})
	var ids: Array = species_config.keys()
	ids.sort_custom(func(a, b):
		return int(species_config[a].get("role", {}).get("slot", 0)) < int(species_config[b].get("role", {}).get("slot", 0)))
	for species_id in ids:
		entries.append({
			"id": str(species_id),
			"label": HudText.species_label(str(species_id)),
		})
	return entries


func _refresh_summary(snapshot: Dictionary) -> void:
	if summary_label == null:
		return
	if snapshot.is_empty():
		summary_label.text = "Данных пока нет."
		return
	var perf: Dictionary = simulation_manager.get_performance_summary()
	summary_label.text = "\n".join([
		"[b]Кадр p95/p99[/b] %.1f / %.1f мс    [b]Отрисовка p95[/b] %.1f мс" % [perf.frame_ms.p95, perf.frame_ms.p99, perf.render_cpu_ms.p95],
		"[b]Скорость[/b] %.2fx из %.1fx    [b]Тик p95[/b] %.1f мс" % [perf.actual_speed, perf.requested_speed, perf.tick_ms.p95],
		"[b]Тик[/b] %d    [b]Время[/b] %.1f с    [b]Зерно[/b] %d" % [
			int(snapshot.get("tick", 0)),
			float(snapshot.get("time_seconds", 0.0)),
			simulation_manager.seed,
		],
		# Climate goes in the summary as well as the always-on indicator, because
		# this line is what reaches telemetry exports and screenshots.
		"[b]Сезон[/b] %s    [b]Часы[/b] %s    [b]Рост травы[/b] x%.2f" % [
			_season_label(str(snapshot.get("season", "-"))),
			"%02d:%02d" % [
				int(float(snapshot.get("day_phase", 0.0)) * 24.0) % 24,
				int(float(snapshot.get("day_phase", 0.0)) * 1440.0) % 60,
			],
			float(snapshot.get("climate_regrowth_multiplier", 1.0)),
		],
		_species_population_line(snapshot),
		_species_vital_line(snapshot),
		"[b]Голод[/b] %d    [b]Жажда[/b] %d    [b]Хищники[/b] %d    [b]Старость[/b] %d" % [
			int(snapshot.get("deaths_starvation", 0)),
			int(snapshot.get("deaths_thirst", 0)),
			int(snapshot.get("deaths_predation", 0)),
			int(snapshot.get("deaths_old_age", 0)),
		],
		"[b]Средний голод[/b] %.1f    [b]Средние силы[/b] %.1f    [b]Удачных охот[/b] %.2f" % [
			float(snapshot.get("average_hunger", 0.0)),
			float(snapshot.get("average_energy", 0.0)),
			float(snapshot.get("hunt_success_rate", 0.0)),
		],
		"[b]LOD[/b] %s    [b]LOD0[/b] %d    [b]LOD1[/b] %d    [b]LOD2[/b] %d" % [
			"вкл" if simulation_manager.lod_enabled else "выкл",
			int(snapshot.get("lod0_agents", 0)),
			int(snapshot.get("lod1_agents", 0)),
			int(snapshot.get("lod2_agents", 0)),
		],
		"[b]Непроходимо[/b] %.1f%%    [b]Шаг в среднем[/b] %.2f мс    [b]Шаг максимум[/b] %.2f мс" % [
			float(snapshot.get("blocked_cell_ratio", 0.0)) * 100.0,
			float(snapshot.get("sim_step_ms_avg", 0.0)),
			float(snapshot.get("sim_step_ms_max", 0.0)),
		],
	])


## A season's name as the climate config gives it («Весна»), from the id the snapshot keeps.
func _season_label(season_id: String) -> String:
	for season in simulation_manager.config_bundle.get("world", {}).get("climate", {}).get("seasons", []):
		if str(season.get("id", "")) == season_id:
			return str(season.get("label", season_id))
	return season_id


func _refresh_inspector(agent_summary: Dictionary) -> void:
	if inspector_text == null:
		return
	if agent_summary.is_empty():
		inspector_text.text = "Никто не выбран."
		return
	inspector_text.text = "\n".join([
		"[b]Номер[/b] %s" % str(agent_summary.get("id", "-")),
		"[b]Вид[/b] %s    [b]Пол[/b] %s" % [HudText.species_label(str(agent_summary.get("species", "-"))),
			HudText.sex_glyph(str(agent_summary.get("sex", "")))],
		"[b]Состояние[/b] %s    [b]Жив[/b] %s" % [HudText.state_label(str(agent_summary.get("state", "-"))),
			"да" if bool(agent_summary.get("alive", false)) else "нет"],
		"[b]Режим ИИ[/b] %s    [b]Действие[/b] %s" % [agent_summary.get("ai_state", "-"),
			HudText.action_label(str(agent_summary.get("current_action", "-")))],
		"[b]Силы[/b] %.1f    [b]Голод[/b] %.1f    [b]Жажда[/b] %.1f" % [
			float(agent_summary.get("energy", 0.0)),
			float(agent_summary.get("hunger", 0.0)),
			float(agent_summary.get("thirst", 0.0)),
		],
		"[b]Возраст[/b] %.1f с    [b]Скорость[/b] %.1f" % [
			float(agent_summary.get("age", 0.0)),
			float(agent_summary.get("speed", 0.0)),
		],
		"[b]Биом[/b] %s    [b]Узлов пути[/b] %d" % [
			HudText.biome_label(str(agent_summary.get("biome", "-"))),
			int(agent_summary.get("path_nodes", 0)),
		],
		"[b]Цель[/b] %s" % str(agent_summary.get("target", "-")),
		"[b]Тиков в действии[/b] %d" % int(agent_summary.get("ticks_in_current_action", 0)),
		"[b]Решение[/b] %s" % str(agent_summary.get("last_action_reason", "-")),
		_format_utility_scores(agent_summary.get("utility_scores", {})),
	])


func _format_utility_scores(scores: Dictionary) -> String:
	if scores.is_empty():
		return "[b]Оценки[/b] -"
	var lines := ["[b]Оценки[/b]"]
	var keys: Array = scores.keys()
	keys.sort()
	for key in keys:
		lines.append("- %s: %.3f" % [HudText.action_label(str(key)), float(scores.get(key, 0.0))])
	return "\n".join(lines)


func _refresh_event_log() -> void:
	if event_log_text == null:
		return
	if simulation_manager == null or simulation_manager.event_bus == null:
		event_log_text.text = "Событий пока нет."
		return
	var events: Array = simulation_manager.event_bus.get_recent_events(event_log_visible_limit)
	if events.is_empty():
		event_log_text.text = "Событий пока нет."
		return
	var lines := PackedStringArray()
	for event in events:
		lines.append(
			"%04d  %s  #%d -> %s" % [
				int(event.get("tick", 0)),
				str(EVENT_NAMES.get(str(event.get("type", "")), event.get("type", ""))),
				int(event.get("agent_id", -1)),
				JSON.stringify(event.get("data", {})),
			]
		)
	event_log_text.text = "\n".join(lines)


func _try_register_overlay_checkbox(flag_name: String, node_path: String) -> void:
	var checkbox: CheckBox = get_node_or_null(node_path)
	if checkbox != null:
		overlay_checkboxes[flag_name] = checkbox
