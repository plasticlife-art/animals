class_name MainController
extends Node2D

@onready var simulation_manager: SimulationManager = $SimulationManager
@onready var world_view = $WorldView
@onready var overlay_renderer = $OverlayRenderer
@onready var world_camera = $GameCamera
@onready var debug_panel = $CanvasLayer/HUD/DebugPanel
@onready var charts_panel = $CanvasLayer/HUD/ChartsPanel
@onready var pause_blur = $CanvasLayer/PauseBlur
@onready var pause_menu = $CanvasLayer/PauseMenu
@onready var resume_button = $CanvasLayer/PauseMenu/PausePanel/MarginContainer/PauseVBox/ResumeButton
@onready var restart_button = $CanvasLayer/PauseMenu/PausePanel/MarginContainer/PauseVBox/RestartButton
@onready var exit_button = $CanvasLayer/PauseMenu/PausePanel/MarginContainer/PauseVBox/ExitButton

var hud_visible: bool = false;
var _hud_visible_before_pause: bool = false
var _pause_menu_open: bool = false
var _paused_before_pause_menu: bool = false


func _ready() -> void:
	simulation_manager.initialize()

	world_view.bind_manager(simulation_manager)
	overlay_renderer.bind_manager(simulation_manager)
	debug_panel.bind_manager(simulation_manager)
	charts_panel.bind_manager(simulation_manager)
	world_camera.reset_to_world(simulation_manager.world_state.bounds)

	_apply_debug_configuration()
	set_hud_visible(false)
	_set_pause_menu_visible(false)
	world_view.set_input_enabled(true)
	world_camera.set_input_enabled(true)

	debug_panel.pause_toggled.connect(_on_pause_toggled)
	debug_panel.single_step_requested.connect(simulation_manager.request_single_step)
	debug_panel.speed_selected.connect(simulation_manager.set_speed_multiplier)
	debug_panel.export_requested.connect(_on_export_requested)
	debug_panel.overlay_flag_changed.connect(_on_overlay_flag_changed)
	resume_button.pressed.connect(resume_game)
	restart_button.pressed.connect(restart_game)
	exit_button.pressed.connect(_exit_game)


func _on_pause_toggled(is_paused: bool) -> void:
	simulation_manager.set_paused(is_paused)
	debug_panel.set_paused_state(is_paused)


func _on_export_requested() -> void:
	var paths := simulation_manager.export_telemetry()
	debug_panel.set_status_text("Exported telemetry to:\n%s\n%s" % [paths.get("metrics_csv", ""), paths.get("events_json", "")])


func _on_overlay_flag_changed(flag_name: String, enabled: bool) -> void:
	simulation_manager.set_debug_flag(flag_name, enabled)
	world_view.set_debug_flag(flag_name, enabled)
	overlay_renderer.set_debug_flag(flag_name, enabled)


func _unhandled_input(event: InputEvent) -> void:
	var toggle_hud_pressed := event.is_action_pressed("toggle_hud")
	var cancel_pressed := event.is_action_pressed("ui_cancel")
	if event is InputEventKey and event.pressed and not event.echo:
		toggle_hud_pressed = toggle_hud_pressed or event.keycode == KEY_TAB
		cancel_pressed = cancel_pressed or event.keycode == KEY_ESCAPE

	if toggle_hud_pressed:
		if not _pause_menu_open:
			set_hud_visible(not hud_visible)
		get_viewport().set_input_as_handled()
	elif cancel_pressed:
		toggle_pause_menu()
		get_viewport().set_input_as_handled()


func toggle_pause_menu() -> void:
	if _pause_menu_open:
		resume_game()
		return

	_hud_visible_before_pause = hud_visible
	_paused_before_pause_menu = simulation_manager.paused
	_pause_menu_open = true
	simulation_manager.set_paused(true)
	debug_panel.set_paused_state(true)
	set_hud_visible(false)
	world_view.set_input_enabled(false)
	world_camera.set_input_enabled(false)
	_set_pause_menu_visible(true)
	resume_button.grab_focus()


func resume_game() -> void:
	if not _pause_menu_open:
		return

	_pause_menu_open = false
	simulation_manager.set_paused(_paused_before_pause_menu)
	debug_panel.set_paused_state(_paused_before_pause_menu)
	set_hud_visible(_hud_visible_before_pause)
	world_view.set_input_enabled(true)
	world_camera.set_input_enabled(true)
	_set_pause_menu_visible(false)


func restart_game() -> void:
	var restore_hud := _hud_visible_before_pause if _pause_menu_open else hud_visible

	simulation_manager.initialize(simulation_manager.config_bundle, simulation_manager.seed)
	_apply_debug_configuration()
	debug_panel.set_paused_state(false)
	set_hud_visible(restore_hud)
	_pause_menu_open = false
	_paused_before_pause_menu = false
	world_view.set_input_enabled(true)
	world_camera.set_input_enabled(true)
	world_camera.reset_to_world(simulation_manager.world_state.bounds)
	_set_pause_menu_visible(false)


func set_hud_visible(value: bool) -> void:
	hud_visible = value
	debug_panel.visible = value
	charts_panel.visible = value


func _apply_debug_configuration() -> void:
	var debug_config: Dictionary = simulation_manager.config_bundle.get("debug", {})
	debug_panel.apply_debug_settings(debug_config, simulation_manager.debug_flags)
	for flag_name in simulation_manager.debug_flags.keys():
		var enabled := bool(simulation_manager.debug_flags[flag_name])
		world_view.set_debug_flag(flag_name, enabled)
		overlay_renderer.set_debug_flag(flag_name, enabled)


func _set_pause_menu_visible(value: bool) -> void:
	pause_blur.visible = value
	pause_menu.visible = value


func _exit_game() -> void:
	get_tree().quit()
