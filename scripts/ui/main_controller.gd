class_name MainController
extends Node2D

@onready var simulation_manager: SimulationManager = $SimulationManager
@onready var terrain_tiles = $TerrainTiles
@onready var agent_renderer = $AgentRenderer
@onready var world_view = $WorldView
@onready var overlay_renderer = $OverlayRenderer
@onready var world_camera = $GameCamera
@onready var debug_panel = $CanvasLayer/HUD/DebugPanel
@onready var charts_panel = $CanvasLayer/HUD/ChartsPanel
@onready var selection_tag = $CanvasLayer/HUD/SelectionTag
@onready var selection_card = $CanvasLayer/HUD/SelectionCard
@onready var minimap = $CanvasLayer/MiniMap
@onready var climate_indicator = $CanvasLayer/ClimateIndicator
@onready var day_night_tint: CanvasModulate = $DayNightTint
@onready var pause_blur = $CanvasLayer/PauseBlur
@onready var pause_menu = $CanvasLayer/PauseMenu
@onready var start_menu = $CanvasLayer/StartMenu
@onready var help_screen = $CanvasLayer/HelpScreen
@onready var resume_button = $CanvasLayer/PauseMenu/PausePanel/MarginContainer/PauseVBox/ResumeButton
@onready var help_button = $CanvasLayer/PauseMenu/PausePanel/MarginContainer/PauseVBox/HelpButton
@onready var restart_button = $CanvasLayer/PauseMenu/PausePanel/MarginContainer/PauseVBox/RestartButton
@onready var exit_button = $CanvasLayer/PauseMenu/PausePanel/MarginContainer/PauseVBox/ExitButton

## Where the selection card sits with the HUD down, and how far it clears the
## debug panel when the HUD is up. The panel's width is measured rather than
## hard-coded: it is a Container sized to its content, so the font metrics of the
## widest overlay label decide it, and a duplicated constant here would drift.
const SELECTION_CARD_X := 12.0
const SELECTION_CARD_GAP := 12.0
const SELECTION_CARD_WIDTH := 332.0

var hud_visible: bool = false;
var _hud_visible_before_pause: bool = false
var _pause_menu_open: bool = false
var _paused_before_pause_menu: bool = false
var _bound: bool = false
var _selection: Dictionary = {}
## 0 disables autosaving. Read from debug.json at each start.
var _autosave_interval: int = 0
## Where `_close_help()` goes back to: "start", "pause", "game", or "" when the
## help screen is down.
var _help_return: String = ""


## Nothing is simulated until the setup screen says so.
##
## The renderers cache atlases, tile sizes and projection at bind time, so they
## cannot be bound before the chosen options are known - which is exactly why
## binding lives in `_start_simulation` rather than here.
func _ready() -> void:
	_apply_ui_theme()
	set_hud_visible(false)
	_set_pause_menu_visible(false)
	start_menu.start_requested.connect(_on_start_requested)
	start_menu.continue_requested.connect(_on_continue_requested)
	# Help needs no simulation behind it, so unlike the rest of the pause menu it
	# is wired here rather than in `_bind_view()`, which only runs once a world
	# exists. That is what lets the setup screen offer it before the first start.
	start_menu.help_requested.connect(_open_help.bind("start"))
	start_menu.exit_requested.connect(_exit_game)
	help_button.pressed.connect(_open_help.bind("pause"))
	help_screen.closed.connect(_close_help)
	_show_start_menu(SaveSystem.latest_slot() != "")


func _on_start_requested(selection: Dictionary) -> void:
	_selection = selection
	_start_simulation(selection, start_menu.selected_seed())


## Continue means two different things depending on when it is pressed.
##
## Before anything is running it resumes the most recent autosave, which is the
## whole point of autosaving. With a simulation already going it just dismisses
## the screen, because the user opened it to look and changed their mind.
func _on_continue_requested() -> void:
	if _bound:
		_hide_start_menu()
		return
	var path := SaveSystem.latest_slot()
	if path == "":
		return
	var data := SaveSystem.read(path)
	if data.is_empty():
		push_warning("Autosave could not be read; starting a new simulation instead")
		_on_start_requested(ConfigLoader.default_selection())
		return
	_selection = data.get("selection", {})
	if not SaveSystem.restore(simulation_manager, data):
		return
	_adopt_running_simulation()


func _start_simulation(selection: Dictionary, seed_value: int) -> void:
	simulation_manager.initialize(ConfigLoader.load_config_bundle(selection), seed_value)
	_adopt_running_simulation()


## Brings the view up to a simulation the manager has already initialized,
## whether that came from the setup screen or from a save.
func _adopt_running_simulation() -> void:
	simulation_manager.enable_interactive_worker()
	_configure_projection()
	if _bound:
		# A new bundle may have changed the atlas, the tile size and whether the
		# grid is square or diamond. Repainting cells cannot express any of that,
		# so the tile set and the sprite batches are rebuilt outright.
		terrain_tiles.rebuild_layers()
		agent_renderer.rebuild_batches()
	else:
		_bind_view()
		_bound = true
	_apply_debug_configuration()
	debug_panel.set_paused_state(false)
	world_camera.reset_to_world(simulation_manager.world_state.bounds)
	minimap.bind_manager(simulation_manager)
	minimap.bind_camera(world_camera)
	debug_panel.refresh_from_manager()
	_sync_lod_focus_rect()
	_autosave_interval = maxi(0, int(simulation_manager.config_bundle
		.get("debug", {}).get("autosave_interval_ticks", 0)))
	_hide_start_menu()


func _show_start_menu(continue_available: bool) -> void:
	start_menu.set_continue_available(continue_available)
	# Always back to the front page: reopening this screen means "I want the
	# menu", not "put me back in the options I was half-way through changing".
	start_menu.show_root()
	start_menu.visible = true
	help_screen.visible = false
	_help_return = ""
	minimap.visible = false
	climate_indicator.visible = false
	selection_tag.visible = false
	selection_card.visible = false
	_set_pause_menu_visible(false)
	set_hud_visible(false)
	world_view.set_input_enabled(false)
	world_camera.set_input_enabled(false)
	minimap.set_input_enabled(false)
	simulation_manager.set_paused(true)


func _hide_start_menu() -> void:
	start_menu.visible = false
	help_screen.visible = false
	_help_return = ""
	_sync_overlay_blur()
	minimap.visible = true
	climate_indicator.visible = true
	selection_tag.visible = true
	# The card is left alone: it shows itself on the next tick, and only if there is
	# actually a live selection to show.
	selection_card.refresh()
	world_view.set_input_enabled(true)
	world_camera.set_input_enabled(true)
	minimap.set_input_enabled(true)
	_pause_menu_open = false
	_paused_before_pause_menu = false
	simulation_manager.set_paused(false)


func _bind_view() -> void:
	terrain_tiles.bind_manager(simulation_manager)
	agent_renderer.bind_manager(simulation_manager)
	world_view.bind_manager(simulation_manager)
	overlay_renderer.bind_manager(simulation_manager)
	debug_panel.bind_manager(simulation_manager)
	charts_panel.bind_manager(simulation_manager)
	climate_indicator.bind_manager(simulation_manager)
	selection_tag.bind_manager(simulation_manager)
	selection_tag.bind_agent_renderer(agent_renderer)
	selection_card.bind_manager(simulation_manager)
	world_camera.bind_manager(simulation_manager)
	world_camera.bind_agent_renderer(agent_renderer)

	simulation_manager.tick_completed.connect(_on_tick_for_autosave)
	debug_panel.pause_toggled.connect(_on_pause_toggled)
	debug_panel.single_step_requested.connect(simulation_manager.request_single_step)
	debug_panel.speed_selected.connect(simulation_manager.set_speed_multiplier)
	debug_panel.export_requested.connect(_on_export_requested)
	debug_panel.focus_mode_selected.connect(_on_focus_mode_selected)
	selection_card.follow_toggled.connect(_on_follow_toggled)
	debug_panel.overlay_flag_changed.connect(_on_overlay_flag_changed)
	debug_panel.lod_enabled_toggled.connect(_on_lod_enabled_toggled)
	resume_button.pressed.connect(resume_game)
	restart_button.pressed.connect(_on_new_simulation_pressed)
	exit_button.pressed.connect(_exit_game)
	_sync_lod_focus_rect()


func _process(_delta: float) -> void:
	_sync_lod_focus_rect()
	_sync_day_night_tint()


## Sampled from sub-tick time rather than the last completed tick: the tint is
## a continuous function of the clock, and reading the cached per-tick value
## would step a 120-second day eighteen times a second, which is visible as
## banding through dawn. This is the same interpolation the renderers already
## use for agent positions.
func _sync_day_night_tint() -> void:
	if day_night_tint == null:
		return
	# The world behind the start menu is a presentation, not the simulation, and
	# a night tint under the pause blur makes it unreadable. This guard also
	# covers the pre-bind case, where there is no world yet.
	if not _bound or start_menu.visible or help_screen.visible \
			or simulation_manager.world_state == null:
		day_night_tint.color = Color.WHITE
		return
	var display_time: float = simulation_manager.simulation_time \
		+ simulation_manager.get_tick_alpha() * simulation_manager.tick_duration
	day_night_tint.color = Climate.evaluate(
		simulation_manager.config_bundle.get("world", {}).get("climate", {}),
		display_time).get("light_color", Color.WHITE)


func _on_pause_toggled(is_paused: bool) -> void:
	simulation_manager.set_paused(is_paused)
	debug_panel.set_paused_state(is_paused)


func _on_export_requested() -> void:
	var paths := simulation_manager.export_telemetry()
	debug_panel.set_status_text("Exported telemetry to:\n%s\n%s" % [paths.get("metrics_csv", ""), paths.get("events_json", "")])


func _on_focus_mode_selected(mode: String) -> void:
	_apply_focus_mode(mode)


## The card's button only knows on/off; the panel's dropdown also offers "flock".
## Toggling on from the card therefore means "agent", the mode a click already sets.
func _on_follow_toggled(enabled: bool) -> void:
	_apply_focus_mode("agent" if enabled else "off")


## Both follow controls route through here so they cannot disagree, and both are
## re-read from the manager rather than from the request: `set_focus_mode()` refuses
## anything but "off" when nothing is selected, and a control left showing the mode
## it asked for would be lying.
func _apply_focus_mode(mode: String) -> void:
	simulation_manager.set_focus_mode(mode)
	debug_panel.set_focus_mode_state(simulation_manager.focus_mode)
	selection_card.set_follow_state(simulation_manager.focus_mode)


func _on_overlay_flag_changed(flag_name: String, enabled: bool) -> void:
	minimap.set_debug_flag(flag_name, enabled)
	simulation_manager.set_debug_flag(flag_name, enabled)
	world_view.set_debug_flag(flag_name, enabled)
	overlay_renderer.set_debug_flag(flag_name, enabled)
	agent_renderer.request_refresh()


func _on_lod_enabled_toggled(enabled: bool) -> void:
	simulation_manager.set_lod_enabled(enabled)
	debug_panel.set_lod_enabled_state(enabled)
	world_view.request_refresh()


func _unhandled_input(event: InputEvent) -> void:
	var toggle_hud_pressed := event.is_action_pressed("toggle_hud")
	var cancel_pressed := event.is_action_pressed("ui_cancel")
	var toggle_follow_pressed := event.is_action_pressed("toggle_follow")
	var toggle_help_pressed := event.is_action_pressed("toggle_help")
	if event is InputEventKey and event.pressed and not event.echo:
		toggle_hud_pressed = toggle_hud_pressed or event.keycode == KEY_TAB
		cancel_pressed = cancel_pressed or event.keycode == KEY_ESCAPE
		toggle_follow_pressed = toggle_follow_pressed or event.keycode == KEY_F
		toggle_help_pressed = toggle_help_pressed or event.keycode == KEY_F1

	# Help is answered before anything else: while it is up both Esc and F1 mean
	# "go back", and Tab and F have nothing behind it to act on.
	if help_screen.visible:
		if cancel_pressed or toggle_help_pressed:
			_close_help()
			get_viewport().set_input_as_handled()
		return

	if toggle_help_pressed:
		if start_menu.visible:
			_open_help("start")
		elif _pause_menu_open:
			_open_help("pause")
		elif _bound:
			_open_help("game")
		get_viewport().set_input_as_handled()
	elif toggle_hud_pressed:
		if not _pause_menu_open:
			set_hud_visible(not hud_visible)
		get_viewport().set_input_as_handled()
	elif toggle_follow_pressed:
		if not _pause_menu_open:
			_apply_focus_mode("off" if simulation_manager.focus_mode != "off" else "agent")
		get_viewport().set_input_as_handled()
	elif cancel_pressed:
		toggle_pause_menu()
		get_viewport().set_input_as_handled()


func toggle_pause_menu() -> void:
	if _pause_menu_open:
		resume_game()
		return

	_enter_menu_overlay()
	_set_pause_menu_visible(true)
	resume_button.grab_focus()


func resume_game() -> void:
	if not _pause_menu_open:
		return
	_exit_menu_overlay()


## Shared by the pause menu and by F1 over a running world. Both stop time, put
## the HUD away and take input off the world; both have to hand all of it back
## exactly as it was, including a pause the user had set themselves.
func _enter_menu_overlay() -> void:
	_hud_visible_before_pause = hud_visible
	_paused_before_pause_menu = simulation_manager.paused
	_pause_menu_open = true
	simulation_manager.set_paused(true)
	debug_panel.set_paused_state(true)
	set_hud_visible(false)
	world_view.set_input_enabled(false)
	world_camera.set_input_enabled(false)
	minimap.set_input_enabled(false)


func _exit_menu_overlay() -> void:
	_pause_menu_open = false
	simulation_manager.set_paused(_paused_before_pause_menu)
	debug_panel.set_paused_state(_paused_before_pause_menu)
	set_hud_visible(_hud_visible_before_pause)
	world_view.set_input_enabled(true)
	world_camera.set_input_enabled(true)
	minimap.set_input_enabled(true)
	_set_pause_menu_visible(false)


## Help opens from three places and has to return to the one it came from: the
## setup screen, the pause menu, or straight back into a running world. Only the
## last one has to stop time on the way in - the other two are already stopped.
func _open_help(from: String) -> void:
	if help_screen.visible:
		return
	_help_return = from
	if from == "game":
		_enter_menu_overlay()
	start_menu.visible = false
	pause_menu.visible = false
	help_screen.visible = true
	help_screen.reset()
	_sync_overlay_blur()


func _close_help() -> void:
	if not help_screen.visible:
		return
	help_screen.visible = false
	var came_from := _help_return
	_help_return = ""
	match came_from:
		"start":
			_show_start_menu(SaveSystem.latest_slot() != "")
		"pause":
			_set_pause_menu_visible(true)
			resume_button.grab_focus()
		_:
			_exit_menu_overlay()


## The pause menu's second button reopens the setup screen rather than silently
## restarting: choosing options is the point, and Continue goes back.
func _on_new_simulation_pressed() -> void:
	_show_start_menu(true)


## Autosaving lives here rather than in SimulationManager: the controller is
## what knows which setup options produced this world, and a save without them
## cannot regenerate the same terrain.
func _on_tick_for_autosave(tick: int, _snapshot: Dictionary) -> void:
	if _autosave_interval <= 0 or tick <= 0 or tick % _autosave_interval != 0:
		return
	SaveSystem.save(simulation_manager, _selection)


## The selection tag and card are deliberately absent from this: they are the one
## readout that should be up whenever an animal is selected, which is the whole
## point of not making the user press Tab for it.
func set_hud_visible(value: bool) -> void:
	hud_visible = value
	debug_panel.visible = value
	charts_panel.visible = value
	selection_card.offset_left = _selection_card_left(value)
	selection_card.offset_right = selection_card.offset_left + SELECTION_CARD_WIDTH
	if value:
		charts_panel.request_refresh()


## The debug panel occupies the full left edge, so the card has to step out of its
## way rather than sit underneath it. `size` is what the panel actually got laid
## out at; the minimum covers the first call, which happens before any layout.
func _selection_card_left(hud_up: bool) -> float:
	if not hud_up:
		return SELECTION_CARD_X
	return debug_panel.position.x \
		+ maxf(debug_panel.size.x, debug_panel.get_combined_minimum_size().x) \
		+ SELECTION_CARD_GAP


## The projection has to know the tallest terrain level before anything culls
## or draws through it, so this runs before the renderers bind.
## One theme covers every HUD control, including the pause menu and the charts.
## The pack's panel is light, so this also carries the text colours - without
## them Godot's default light-grey labels vanish against the parchment.
func _apply_ui_theme() -> void:
	# CanvasLayer is not a Control and carries no theme, so it goes on each of
	# the HUD roots instead. Setting it at the top of each subtree is enough:
	# themes inherit downwards.
	# The HUD gets the compact variant: it is a dense readout plus a grid of
	# toggles, and at menu type size the panel runs off the bottom of the screen.
	var compact := PixelUiTheme.build(true)
	var roomy := PixelUiTheme.build(false)
	for path in ["CanvasLayer/HUD", "CanvasLayer/MiniMap", "CanvasLayer/ClimateIndicator"]:
		var hud_node := get_node_or_null(path)
		if hud_node is Control:
			hud_node.theme = compact
	for path in ["CanvasLayer/PauseMenu", "CanvasLayer/StartMenu", "CanvasLayer/HelpScreen"]:
		var menu_node := get_node_or_null(path)
		if menu_node is Control:
			menu_node.theme = roomy


func _configure_projection() -> void:
	var max_level := 0
	if simulation_manager.world_state != null and simulation_manager.world_state.terrain_system != null:
		max_level = simulation_manager.world_state.terrain_system.get_max_height_level()
	WorldProjection.configure(simulation_manager.config_bundle.get("visuals", {}), max_level)


func _apply_debug_configuration() -> void:
	var debug_config: Dictionary = simulation_manager.config_bundle.get("debug", {})
	var lod_config: Dictionary = debug_config.get("lod", {})
	var lod_enabled := bool(lod_config.get("enabled", false))
	simulation_manager.set_lod_enabled(lod_enabled)
	debug_panel.apply_debug_settings(debug_config, simulation_manager.debug_flags, lod_enabled)
	for flag_name in simulation_manager.debug_flags.keys():
		var enabled := bool(simulation_manager.debug_flags[flag_name])
		world_view.set_debug_flag(flag_name, enabled)
		overlay_renderer.set_debug_flag(flag_name, enabled)
		minimap.set_debug_flag(flag_name, enabled)
	agent_renderer.request_refresh()
	_sync_lod_focus_rect()


func _set_pause_menu_visible(value: bool) -> void:
	pause_menu.visible = value
	_sync_overlay_blur()


## The blur backs every full-screen overlay - setup screen, pause menu, help -
## so it is derived from all three rather than owned by any one of them. Setting
## it per screen used to mean whichever ran last won, and the setup screen lost.
func _sync_overlay_blur() -> void:
	pause_blur.visible = start_menu.visible or pause_menu.visible or help_screen.visible


func _sync_lod_focus_rect() -> void:
	if simulation_manager == null or world_camera == null:
		return
	# The camera reports a screen-space rect; sector dormancy is decided in
	# simulation space, so it goes through the projection seam.
	var focus_rect: Rect2 = WorldProjection.world_rect_covering(world_camera.get_visible_screen_rect())
	if simulation_manager.lod_focus_rect == focus_rect:
		return
	simulation_manager.set_lod_focus_rect(focus_rect)
	if bool(simulation_manager.debug_flags.get("show_lod_overlay", false)):
		world_view.request_refresh()


func _exit_game() -> void:
	get_tree().quit()
