class_name MainController
extends Node2D

@onready var simulation_manager: SimulationManager = $SimulationManager
@onready var terrain_tiles = $TerrainTiles
@onready var ground_traces = $GroundTraces
@onready var agent_renderer = $AgentRenderer
@onready var world_view = $WorldView
@onready var overlay_renderer = $OverlayRenderer
@onready var place_labels = $PlaceLabels
@onready var world_camera = $GameCamera
@onready var debug_panel = $CanvasLayer/HUD/DebugPanel
@onready var charts_panel = $CanvasLayer/HUD/ChartsPanel
@onready var selection_tag = $CanvasLayer/HUD/SelectionTag
@onready var card_stack = $CanvasLayer/HUD/CardStack
@onready var player_bar = $CanvasLayer/HUD/PlayerBar
@onready var pinned_bar = $CanvasLayer/HUD/PinnedBar
@onready var herd_card = $CanvasLayer/HUD/CardStack/HerdCard
@onready var selection_card = $CanvasLayer/HUD/CardStack/SelectionCard
@onready var minimap = $CanvasLayer/MiniMap
@onready var climate_indicator = $CanvasLayer/ClimateIndicator
@onready var ecology_strip = $CanvasLayer/EcologyStrip
@onready var story_feed = $CanvasLayer/StoryFeed
@onready var epitaph_card = $CanvasLayer/EpitaphCard
@onready var season_card = $CanvasLayer/SeasonCard
@onready var chronicle_window = $CanvasLayer/ChronicleWindow
@onready var settings_panel = $CanvasLayer/SettingsPanel
@onready var photo_mode = $PhotoMode
@onready var power_targeting = $PowerTargeting
@onready var powers_bar = $CanvasLayer/HUD/PowersBar
@onready var goal_chips = $CanvasLayer/HUD/GoalChips
@onready var result_window = $CanvasLayer/ResultWindow
@onready var day_night_tint: CanvasModulate = $DayNightTint
@onready var pause_blur = $CanvasLayer/PauseBlur
@onready var pause_menu = $CanvasLayer/PauseMenu
@onready var start_menu = $CanvasLayer/StartMenu
@onready var help_screen = $CanvasLayer/HelpScreen
@onready var resume_button = $CanvasLayer/PauseMenu/PausePanel/MarginContainer/PauseVBox/ResumeButton
@onready var help_button = $CanvasLayer/PauseMenu/PausePanel/MarginContainer/PauseVBox/HelpButton
@onready var settings_button = $CanvasLayer/PauseMenu/PausePanel/MarginContainer/PauseVBox/SettingsButton
@onready var restart_button = $CanvasLayer/PauseMenu/PausePanel/MarginContainer/PauseVBox/RestartButton
@onready var exit_button = $CanvasLayer/PauseMenu/PausePanel/MarginContainer/PauseVBox/ExitButton
## A first game's hints (`challenge.hints`), built here rather than in the scene.
var tutorial_hints: TutorialHints = null
const ScenarioProgress := preload("res://scripts/core/scenario_progress.gd")

## Where the selection card sits with the HUD down, and how far it clears the
## debug panel when the HUD is up. The panel's width is measured rather than
## hard-coded: it is a Container sized to its content, so the font metrics of the
## widest overlay label decide it, and a duplicated constant here would drift.
const SELECTION_CARD_X := 12.0
const SELECTION_CARD_GAP := 12.0
const SELECTION_CARD_WIDTH := 332.0
## About a row of goal chips, for what stands beside them (`_layout_hud()`).
const CHIP_ROW_HEIGHT := 32.0
## How much of the map a scenario's start shows around the player's herd, in simulation units:
## close enough that the herd is awake, wide enough to see its water.
const SCENARIO_FRAME := Vector2(1800.0, 1100.0)
## Each power's input action and its key by place on the keyboard.
const POWER_KEYS := {"dig_pond": ["power_dig", KEY_Q], "lead_herd": ["power_lead", KEY_E], "cull": ["power_cull", KEY_R]}

var hud_visible: bool = false;
var _hud_visible_before_pause: bool = false
var _pause_menu_open: bool = false
var _paused_before_pause_menu: bool = false
var _bound: bool = false
var _selection: Dictionary = {}
## 0 disables autosaving. Read from debug.json at each start.
var _autosave_interval: int = 0
## Developer mode puts the developer panel and the charts behind Tab
## (`debug.developer_mode`; F12 switches it while playing). Off, a player gets the small
## Russian bar at the top left instead and Tab does nothing.
var developer_mode: bool = false
## Names, family tree and pins of the world on screen, saved with it (`StoryBook`).
var story_book = preload("res://scripts/story/story_book.gd").new()
## What the save being loaded kept of the story, until the world it belongs to is adopted.
var _pending_story: Dictionary = {}
## An animal asked for while asleep, selected as soon as it wakes.
var _pending_focus_id: int = -1
## Where `_close_help()` goes back to: "start", "pause", "game", or "" when the
## help screen is down.
var _help_return: String = ""
## The player's own settings (`SettingsStore`), and where `_close_settings()` goes back to.
var _settings: Dictionary = {}
var _settings_return: String = ""
## The season bar's and the strip's offsets as the scene has them, before `_layout_hud()` moves
## them aside, and the herd card's height when last shown.
var _climate_offsets := Vector2.ZERO
var _strip_offsets := Vector2.ZERO
var _herd_height: float = 0.0
var _overview_mode: bool = false
## The living reserve (`--reserve`), when this window is one: its viewers, the port their chat
## comes in on, the camera that directs itself and the panel the stream shows. Null otherwise.
var reserve_session: ReserveSession = null
var _viewer_link: ViewerLink = null
var _director: ReserveDirector = null
var _reserve_overlay: ReserveOverlay = null
var _ward_tags: WardTags = null
var _banner: ReserveBanner = null
## The year the reserve's summary was last told for.
var _reserve_year: int = -1


## Nothing is simulated until the setup screen says so.
##
## The renderers cache atlases, tile sizes and projection at bind time, so they
## cannot be bound before the chosen options are known - which is exactly why
## binding lives in `_start_simulation` rather than here.
func _ready() -> void:
	_apply_ui_theme()
	_climate_offsets = Vector2(climate_indicator.offset_left, climate_indicator.offset_right)
	_strip_offsets = Vector2(ecology_strip.offset_left, ecology_strip.offset_right)
	# Before the first frame, so the window opens at the size and scale the player left it.
	_settings = SettingsStore.load_settings()
	SettingsStore.apply(_settings, get_window(), world_camera)
	start_menu.settings_requested.connect(_open_settings.bind("start"))
	settings_button.pressed.connect(_open_settings.bind("pause"))
	settings_panel.changed.connect(_on_settings_changed)
	settings_panel.closed.connect(_close_settings)
	set_hud_visible(false)
	_set_pause_menu_visible(false)
	start_menu.start_requested.connect(_on_start_requested)
	start_menu.scenario_requested.connect(_on_scenario_requested)
	start_menu.continue_requested.connect(_on_continue_requested)
	result_window.brief_closed.connect(_close_result_window)
	result_window.watch_on_requested.connect(_close_result_window)
	result_window.restart_requested.connect(_restart_scenario)
	result_window.menu_requested.connect(_result_to_menu)
	result_window.next_requested.connect(_on_next_scenario)
	tutorial_hints = TutorialHints.new()
	# Made after `_apply_ui_theme()`: the result window's parchment.
	tutorial_hints.theme = result_window.theme
	$CanvasLayer.add_child(tutorial_hints)
	# Help needs no simulation behind it, so unlike the rest of the pause menu it
	# is wired here rather than in `_bind_view()`, which only runs once a world
	# exists. That is what lets the setup screen offer it before the first start.
	start_menu.help_requested.connect(_open_help.bind("start"))
	start_menu.exit_requested.connect(_exit_game)
	help_button.pressed.connect(_open_help.bind("pause"))
	help_screen.closed.connect(_close_help)
	if OS.get_cmdline_user_args().has("--reserve"):
		_start_reserve(OS.get_cmdline_user_args().has("--fresh"))
		return
	_show_start_menu(SaveSystem.latest_slot() != "")


func _on_start_requested(selection: Dictionary) -> void:
	_selection = selection
	_start_simulation(selection, start_menu.selected_seed())


## A scenario from the start page («Сценарии»), in the style the setup page has: its own world
## and seed, then its brief over the player's herd.
func _on_scenario_requested(scenario_id: String, style: String) -> void:
	var bundle: Dictionary = ConfigLoader.load_scenario_bundle(scenario_id, {"style": style})
	if bundle.is_empty():
		return
	_selection = bundle["challenge"]["selection"]
	simulation_manager.initialize(bundle, int(bundle["challenge"]["seed"]))
	tutorial_hints.start(bundle["challenge"].get("hints", []))
	_adopt_running_simulation()
	_open_scenario_brief()


## «Следующий сценарий» on a won scenario's result: that one, in the same style.
func _on_next_scenario(scenario_id: String) -> void:
	result_window.close()
	_on_scenario_requested(scenario_id, str(_selection.get("style", start_menu.chosen_style())))


## «Заново» on the result: the same scenario from its start, in the same style.
func _restart_scenario() -> void:
	var challenge: Dictionary = simulation_manager.config_bundle.get("challenge", {})
	result_window.close()
	if not challenge.is_empty():
		_on_scenario_requested(str(challenge.get("id", "")), str(_selection.get("style", start_menu.chosen_style())))


func _result_to_menu() -> void:
	result_window.close()
	_sync_result_window()
	_show_start_menu(true)


## The brief, with the camera on the player's herd and one of it selected, the game paused until
## «Начать».
func _open_scenario_brief() -> void:
	var runner = simulation_manager.scenario
	if not runner.is_active():
		return
	var herd := PowerAim.herd_to_lead(simulation_manager)
	if not herd.is_empty():
		var center: Vector2 = herd["center"]
		# The herd right of the brief, where the screen is free; «Начать» brings it to the middle.
		world_camera.frame_world_rect(Rect2(center - SCENARIO_FRAME * 0.5, SCENARIO_FRAME))
		var aside := Vector2(world_camera.get_visible_screen_rect().size.x * 0.3, 0.0)
		world_camera.move_to_world_position(WorldProjection.to_world(world_camera.global_position - aside))
		var nearest = null
		for agent in simulation_manager.world_state.get_living_agents():
			if agent.is_alive and agent.species_type == runner.species and runner.groups.has(int(agent.group_id)) \
					and (nearest == null or agent.position.distance_squared_to(center) < nearest.position.distance_squared_to(center)):
				nearest = agent
		if nearest != null:
			simulation_manager.select_agent_by_id(nearest.id, false)
	result_window.show_brief(simulation_manager.config_bundle.get("challenge", {}))
	_sync_result_window()


func _on_scenario_finished(won: bool, summary: Dictionary) -> void:
	power_targeting.cancel()
	_refresh_powers()
	tutorial_hints.stop()
	if won:
		ScenarioProgress.record_win(str(summary.get("id", "")))
	result_window.show_result(won, summary, simulation_manager.scenario, simulation_manager.config_bundle.get("challenge", {}))
	_sync_result_window()


func _close_result_window() -> void:
	var was_brief: bool = result_window.mode() == "brief"
	result_window.close()
	_sync_result_window()
	if was_brief:
		var herd := PowerAim.herd_to_lead(simulation_manager)
		if not herd.is_empty():
			world_camera.move_to_world_position(herd["center"])


## The game stands still under the brief and the result, and the season card waits; closing
## either lets time go on.
func _sync_result_window() -> void:
	_on_pause_toggled(result_window.visible)
	season_card.set_allowed(not result_window.visible and not hud_visible and not start_menu.visible)


## A power's button or key: aimed, or put down if it was the one aimed.
func _on_power_pressed(power: String) -> void:
	if power_targeting.aim.power == power:
		power_targeting.cancel()
	elif simulation_manager.paused:
		power_targeting.cancel()
		power_targeting.aim.message = "Сначала снимите паузу"
	else:
		power_targeting.arm(power)
	_refresh_powers()


## What the first game's hints are judged by (`TutorialHints.advance()`).
func _tutorial_facts() -> Dictionary:
	var world = simulation_manager.world_state if simulation_manager != null else null
	return {"selected": int(simulation_manager.selected_agent_id), "following": simulation_manager.focus_mode != "off",
		"speed": float(simulation_manager.speed_multiplier), "feed_open": bool(story_feed.expanded),
		"leads": int(world.player.used.get("lead_herd", 0)) if world != null and world.player != null else 0}


## Hints show over a world in play, under nothing: not under the brief or the result, a menu,
## help, the chronicle or photo mode.
func _hints_allowed() -> bool:
	return _bound and player_bar.visible and not result_window.visible and not chronicle_window.visible \
		and not photo_mode.active and not start_menu.visible and not help_screen.visible and not pause_menu.visible \
		and not settings_panel.visible


## Whether a power may be aimed now: a world in play, nothing over it.
func _powers_available() -> bool:
	return _bound and powers_bar.visible and not result_window.visible and not chronicle_window.visible \
		and not photo_mode.active


func _refresh_powers() -> void:
	var world = simulation_manager.world_state
	if world == null or powers_bar == null:
		return
	powers_bar.refresh(world.player, simulation_manager.simulation_time, power_targeting.aim.power, power_targeting.aim.message)
	goal_chips.refresh(simulation_manager.scenario, simulation_manager.simulation_time, world)


func _enter_photo_mode() -> void:
	power_targeting.cancel()
	photo_mode.enter()


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
	_pending_story = data.get("story", {})
	# A first game resumed goes on without its hints: they were for its first minutes.
	tutorial_hints.stop()
	_adopt_running_simulation()


## The living reserve (`--reserve`, `reserve.json`): a world on a stream that its viewers act on
## through the chat, with no player's bar and a camera that directs itself. It goes on from its
## newest save (its own slots), unless started with `--fresh`.
func _start_reserve(fresh: bool) -> void:
	var config := ConfigLoader.load_reserve_config()
	var path := SaveSystem.latest_slot(SaveSystem.KIND_RESERVE)
	var data := SaveSystem.read(path) if path != "" and not fresh else {}
	if not data.is_empty() and SaveSystem.restore(simulation_manager, data):
		_selection = data.get("selection", {})
		_pending_story = data.get("story", {})
	else:
		data = {}
		var bundle := ConfigLoader.load_reserve_bundle(config)
		_selection = bundle["reserve"]["selection"]
		var seed_value := int(config.get("seed", 0))
		simulation_manager.initialize(bundle, seed_value if seed_value != 0 else 1 + int(Time.get_unix_time_from_system()) % 999983)
	tutorial_hints.stop()
	reserve_session = ReserveSession.new()
	reserve_session.import_state(data.get("reserve", {}))
	_adopt_running_simulation()
	# After the bring-up: the session and the director hear the world the view now shows.
	reserve_session.configure(simulation_manager, config)
	story_book.lineage.capacity = int(config.get("story_animals", story_book.lineage.capacity))
	_autosave_interval = maxi(1, int(float(config.get("autosave_seconds", 120.0)) * simulation_manager.tick_rate))
	_viewer_link = ViewerLink.new()
	if not _viewer_link.listen(config):
		push_warning("The reserve's chat port %s is taken: no viewers' lines will come in" % str(config.get("link", {})))
	_director = ReserveDirector.new()
	_director.configure(simulation_manager, world_camera, reserve_session, config)
	_reserve_overlay = ReserveOverlay.new()
	_reserve_overlay.theme = result_window.theme
	_reserve_overlay.set_anchors_preset(Control.PRESET_TOP_LEFT)
	_reserve_overlay.position = Vector2(12.0, 12.0)
	$CanvasLayer.add_child(_reserve_overlay)
	_reserve_overlay.bind(reserve_session, story_book)
	_banner = ReserveBanner.new()
	_banner.theme = result_window.theme
	$CanvasLayer.add_child(_banner)
	_banner.bind(reserve_session)
	_reserve_year = int(simulation_manager.world_state.climate.year)
	# Over the weather and under every panel: the wards' names belong to the map.
	_ward_tags = WardTags.new()
	_ward_tags.theme = result_window.theme
	$CanvasLayer.add_child(_ward_tags)
	$CanvasLayer.move_child(_ward_tags, 1)
	_ward_tags.bind(simulation_manager, agent_renderer, reserve_session)
	# The reserve is the one world of this window: no new one over its viewers from the pause menu.
	restart_button.visible = false
	_sync_player_bar()


## The reserve's chat, votes and camera, once a frame.
func _tick_reserve() -> void:
	for message in _viewer_link.poll():
		reserve_session.hear(message)
	reserve_session.tick()
	_director.update()
	var year := int(simulation_manager.world_state.climate.year)
	if year > _reserve_year:
		var summary := ReserveRecords.year_summary(_reserve_year + 1, simulation_manager.world_state, story_book, reserve_session)
		if summary != "":
			_banner.hear({"text": summary, "kind": "year"})
	_reserve_year = year


func _start_simulation(selection: Dictionary, seed_value: int) -> void:
	simulation_manager.initialize(ConfigLoader.load_config_bundle(selection), seed_value)
	tutorial_hints.stop()
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
		ground_traces.rebuild()
		agent_renderer.rebuild_batches()
	else:
		_bind_view()
		_bound = true
	# Every time, not only on the first bind: the species the strip lists come from the
	# bundle, and the herd card's losses belong to the world they were heard in.
	ecology_strip.bind_manager(simulation_manager)
	herd_card.bind_manager(simulation_manager)
	# Before the worker starts stepping, so no birth or death of the new world is missed.
	story_book.bind(simulation_manager)
	story_book.begin(_pending_story)
	_pending_story = {}
	epitaph_card.clear()
	season_card.clear()
	chronicle_window.reset()
	place_labels.configure(simulation_manager.config_bundle.get("visuals", {}))
	_pending_focus_id = -1
	power_targeting.cancel()
	result_window.close()
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
	_refresh_powers()
	# Last, once the renderers, themes and atlases above have finished loading.
	# The worker steps on its own thread and reads the same scripts this bring-up
	# is still compiling.
	simulation_manager.begin_interactive_stepping()


func _show_start_menu(continue_available: bool) -> void:
	start_menu.set_continue_available(continue_available)
	# Always back to the front page: reopening this screen means "I want the
	# menu", not "put me back in the options I was half-way through changing".
	start_menu.show_root()
	start_menu.visible = true
	help_screen.visible = false
	_help_return = ""
	minimap.visible = false
	story_feed.visible = false
	player_bar.visible = false
	pinned_bar.set_allowed(false)
	epitaph_card.set_allowed(false)
	season_card.set_allowed(false)
	chronicle_window.close_window()
	photo_mode.leave()
	climate_indicator.visible = false
	ecology_strip.visible = false
	selection_tag.visible = false
	selection_card.visible = false
	herd_card.set_allowed(false)
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
	story_feed.visible = true
	climate_indicator.visible = true
	ecology_strip.visible = true
	selection_tag.visible = true
	# The card is left alone: it shows itself on the next tick, and only if there is
	# actually a live selection to show.
	selection_card.refresh()
	herd_card.set_allowed(true)
	epitaph_card.set_allowed(true)
	season_card.set_allowed(not hud_visible and not result_window.visible)
	_sync_player_bar()
	world_view.set_input_enabled(true)
	world_camera.set_input_enabled(true)
	minimap.set_input_enabled(true)
	_pause_menu_open = false
	_paused_before_pause_menu = false
	simulation_manager.set_paused(false)


func _bind_view() -> void:
	terrain_tiles.bind_manager(simulation_manager)
	ground_traces.bind_manager(simulation_manager, terrain_tiles)
	agent_renderer.bind_manager(simulation_manager)
	world_view.bind_manager(simulation_manager)
	overlay_renderer.bind_manager(simulation_manager)
	debug_panel.bind_manager(simulation_manager)
	charts_panel.bind_manager(simulation_manager)
	climate_indicator.bind_manager(simulation_manager)
	selection_tag.bind_manager(simulation_manager)
	selection_tag.bind_agent_renderer(agent_renderer)
	selection_card.bind_manager(simulation_manager)
	selection_card.story = story_book
	herd_card.places = story_book.places
	selection_tag.story = story_book
	pinned_bar.bind(story_book, simulation_manager)
	story_feed.bind(story_book.feed, simulation_manager)
	place_labels.bind(story_book, world_camera)
	minimap.places = story_book.places
	epitaph_card.simulation_manager = simulation_manager
	story_book.epitaph_written.connect(epitaph_card.show_epitaph)
	epitaph_card.place_requested.connect(_on_epitaph_place)
	epitaph_card.family_available = true
	epitaph_card.family_requested.connect(open_chronicle)
	season_card.simulation_manager = simulation_manager
	story_book.season_closed.connect(season_card.show_season)
	season_card.chronicle_requested.connect(open_seasons)
	chronicle_window.bind(story_book, simulation_manager)
	chronicle_window.focus_requested.connect(_focus_animal)
	player_bar.chronicle_requested.connect(toggle_chronicle)
	player_bar.photo_requested.connect(_enter_photo_mode)
	power_targeting.bind_manager(simulation_manager)
	power_targeting.aim_changed.connect(_refresh_powers)
	powers_bar.power_pressed.connect(_on_power_pressed)
	simulation_manager.player_state_changed.connect(_refresh_powers)
	simulation_manager.scenario_goal_changed.connect(func(_goal_id: String, _state: String) -> void: _refresh_powers())
	simulation_manager.scenario_finished.connect(_on_scenario_finished)
	photo_mode.bind(simulation_manager, [$CanvasLayer, overlay_renderer, world_view, place_labels, power_targeting], agent_renderer, world_view)
	photo_mode.set_theme_for_bar(PixelUiTheme.build(true))
	photo_mode.pause_toggled.connect(_on_pause_toggled)
	selection_card.tree_requested.connect(open_chronicle)
	story_book.feed.context_provider = _story_context
	selection_card.family_clicked.connect(_focus_animal)
	pinned_bar.focus_requested.connect(_focus_animal)
	story_feed.line_clicked.connect(_on_feed_line_clicked)
	simulation_manager.tick_completed.connect(_on_tick_for_story)
	world_camera.bind_manager(simulation_manager)
	world_camera.bind_agent_renderer(agent_renderer)

	simulation_manager.tick_completed.connect(_on_tick_for_autosave)
	# The weather over the map, under every panel.
	var weather := WeatherOverlay.new()
	$CanvasLayer.add_child(weather)
	$CanvasLayer.move_child(weather, 0)
	weather.bind(simulation_manager)
	simulation_manager.world_exported.connect(_on_world_exported)
	debug_panel.pause_toggled.connect(_on_pause_toggled)
	debug_panel.single_step_requested.connect(simulation_manager.request_single_step)
	debug_panel.speed_selected.connect(_on_speed_selected)
	player_bar.pause_toggled.connect(_on_pause_toggled)
	player_bar.speed_selected.connect(_on_speed_selected)
	player_bar.overlay_toggled.connect(_on_overlay_flag_changed)
	player_bar.help_requested.connect(_on_help_button)
	debug_panel.export_requested.connect(_on_export_requested)
	debug_panel.focus_mode_selected.connect(_on_focus_mode_selected)
	selection_card.follow_toggled.connect(_on_follow_toggled)
	herd_card.follow_toggled.connect(_on_herd_follow_toggled)
	debug_panel.overlay_flag_changed.connect(_on_overlay_flag_changed)
	debug_panel.lod_enabled_toggled.connect(_on_lod_enabled_toggled)
	resume_button.pressed.connect(resume_game)
	restart_button.pressed.connect(_on_new_simulation_pressed)
	exit_button.pressed.connect(_exit_game)
	_sync_lod_focus_rect()


func _process(delta: float) -> void:
	var started := Time.get_ticks_usec()
	_sync_lod_focus_rect()
	_sync_day_night_tint()
	_layout_hud()
	if tutorial_hints != null and not tutorial_hints.is_done():
		tutorial_hints.advance(_tutorial_facts(), delta, _hints_allowed())
	if reserve_session != null and _director != null and _bound:
		_tick_reserve()
	if simulation_manager != null and simulation_manager.world_state != null:
		simulation_manager.record_render_phase("ui",
			float(Time.get_ticks_usec() - started) / 1000.0)


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
	if is_paused:
		power_targeting.cancel()
	simulation_manager.set_paused(is_paused)
	debug_panel.set_paused_state(is_paused)
	player_bar.set_paused_state(is_paused)


## The bar and the developer panel each offer the speeds; whichever was used, both show it.
func _on_speed_selected(multiplier: float) -> void:
	simulation_manager.set_speed_multiplier(multiplier)
	debug_panel.set_speed_state(multiplier)
	player_bar.set_speed(multiplier)


func _on_help_button() -> void:
	if _bound and not _pause_menu_open:
		_open_help("game")


func _on_export_requested() -> void:
	var paths := simulation_manager.export_telemetry()
	debug_panel.set_status_text("Exported telemetry to:\n%s\n%s" % [paths.get("metrics_csv", ""), paths.get("events_json", "")])


func _on_focus_mode_selected(mode: String) -> void:
	_apply_focus_mode(mode)


## The card's button only knows on/off; the panel's dropdown also offers "flock".
## Toggling on from the card therefore means "agent", the mode a click already sets.
func _on_follow_toggled(enabled: bool) -> void:
	_apply_focus_mode("agent" if enabled else "off")


func _on_herd_follow_toggled(enabled: bool) -> void:
	_apply_focus_mode("flock" if enabled else "off")


## Both follow controls route through here so they cannot disagree, and both are
## re-read from the manager rather than from the request: `set_focus_mode()` refuses
## anything but "off" when nothing is selected, and a control left showing the mode
## it asked for would be lying.
func _apply_focus_mode(mode: String) -> void:
	simulation_manager.set_focus_mode(mode)
	debug_panel.set_focus_mode_state(simulation_manager.focus_mode)
	selection_card.set_follow_state(simulation_manager.focus_mode)
	herd_card.set_follow_state(simulation_manager.focus_mode)


func _on_overlay_flag_changed(flag_name: String, enabled: bool) -> void:
	debug_panel.set_overlay_state(flag_name, enabled)
	player_bar.set_overlay_state(flag_name, enabled)
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

	# Photo mode keeps its own keys: Esc or P leaves it, H hides its bar; nothing else acts.
	if photo_mode.active:
		if cancel_pressed or _is_key(event, "toggle_photo_mode", KEY_P):
			photo_mode.leave()
			get_viewport().set_input_as_handled()
		elif _is_key(event, "photo_hide_bar", KEY_H):
			photo_mode.toggle_bar()
			get_viewport().set_input_as_handled()
		return
	if _is_key(event, "toggle_photo_mode", KEY_P):
		if _bound and not start_menu.visible and not _pause_menu_open and not help_screen.visible \
				and not settings_panel.visible:
			_enter_photo_mode()
		get_viewport().set_input_as_handled()
		return
	# F11 switches full screen whatever is up.
	if _is_key(event, "toggle_fullscreen", KEY_F11):
		_settings["fullscreen"] = not bool(_settings.get("fullscreen", false))
		_on_settings_changed(_settings)
		settings_panel.show_settings(_settings)
		get_viewport().set_input_as_handled()
		return
	# Settings, like help, answer Esc themselves and leave nothing behind them to act on.
	if settings_panel.visible:
		if cancel_pressed:
			_close_settings()
		get_viewport().set_input_as_handled()
		return

	# Help is answered before anything else: while it is up both Esc and F1 mean
	# "go back", and Tab and F have nothing behind it to act on.
	if help_screen.visible:
		if cancel_pressed or toggle_help_pressed:
			_close_help()
			get_viewport().set_input_as_handled()
		return

	# A power being aimed is put down before anything else answers Esc; Q and E aim one.
	if power_targeting.is_armed() and cancel_pressed:
		power_targeting.cancel()
		get_viewport().set_input_as_handled()
		return
	for power in POWER_KEYS:
		if _is_key(event, str(POWER_KEYS[power][0]), POWER_KEYS[power][1]):
			if _powers_available() and not _pause_menu_open and not start_menu.visible \
					and simulation_manager.world_state.player.budget.has(power):
				_on_power_pressed(str(power))
			get_viewport().set_input_as_handled()
			return

	# The chronicle closes before the pause menu opens; L opens and closes it in play.
	if chronicle_window.visible and cancel_pressed:
		chronicle_window.close_window()
		get_viewport().set_input_as_handled()
		return
	if _is_key(event, "toggle_chronicle", KEY_L):
		if _bound and not start_menu.visible and not _pause_menu_open:
			toggle_chronicle()
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
		if not _pause_menu_open and developer_mode:
			set_hud_visible(not hud_visible)
		get_viewport().set_input_as_handled()
	elif event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_F12:
		if _bound and not _pause_menu_open:
			set_developer_mode(not developer_mode)
		get_viewport().set_input_as_handled()
	elif toggle_follow_pressed:
		if not _pause_menu_open:
			_apply_focus_mode("off" if simulation_manager.focus_mode != "off" else "agent")
		get_viewport().set_input_as_handled()
	elif cancel_pressed:
		# The setup screen has no pause menu behind it: before the first world its buttons are
		# not even wired, and closing it would hand the mouse back to a world under the menu.
		if not start_menu.visible:
			toggle_pause_menu()
		get_viewport().set_input_as_handled()


## Keeps the HUD from overlapping on a small canvas - a large interface, a small window, many
## pins: the season bar and the strip step right of the player bar, and the herd card gives way
## when the selected animal's card and the pinned list leave it no room. A few rects a frame.
func _layout_hud() -> void:
	var shift := 0.0
	if player_bar.visible:
		var view_width: float = get_viewport().get_visible_rect().size.x
		shift = maxf(0.0, player_bar.get_global_rect().end.x + 12.0 - (view_width * 0.5 + _climate_offsets.x))
	if not is_equal_approx(climate_indicator.offset_left, _climate_offsets.x + shift):
		climate_indicator.offset_left = _climate_offsets.x + shift
		climate_indicator.offset_right = _climate_offsets.y + shift
		ecology_strip.offset_left = _strip_offsets.x + shift
		ecology_strip.offset_right = _strip_offsets.y + shift
	# The first game's hints stand under the species line.
	if tutorial_hints != null and tutorial_hints.visible:
		var hints_top: float = (ecology_strip.get_global_rect().end.y if ecology_strip.visible else 100.0) + 10.0
		if not is_equal_approx(tutorial_hints.offset_top, hints_top):
			tutorial_hints.offset_top = hints_top
	# The goals stand just above the powers, between the cards on the left and the map and the
	# feed on the right: in two rows rather than under them. What stands beside them is judged
	# over two rows' height, so taking the second does not change the room it was taken for.
	var chips_bottom: float = powers_bar.offset_bottom - (powers_bar.size.y + 6.0 if powers_bar.visible else 0.0)
	if not is_equal_approx(goal_chips.offset_bottom, chips_bottom):
		goal_chips.offset_top = chips_bottom
		goal_chips.offset_bottom = chips_bottom
	if goal_chips.visible:
		var view_size: Vector2 = get_viewport().get_visible_rect().size
		var band := Rect2(0.0, goal_chips.get_global_rect().end.y - 2.0 * CHIP_ROW_HEIGHT, view_size.x, 2.0 * CHIP_ROW_HEIGHT)
		var left := 0.0
		var right := view_size.x
		for card in [herd_card, selection_card]:
			if card.is_visible_in_tree() and card.get_global_rect().intersects(band):
				left = maxf(left, card.get_global_rect().end.x + 8.0)
		for column in [minimap, story_feed]:
			if column.is_visible_in_tree() and column.get_global_rect().intersects(band):
				right = minf(right, column.get_global_rect().position.x - 8.0)
		var center := view_size.x * 0.5
		goal_chips.fit(2.0 * minf(center - left, right - center))
	# One card at a time in the right column: an epitaph waits, its countdown stopped, while the
	# season card stands there. Stacked, the two reach down over the event feed.
	var epitaph_allowed: bool = not start_menu.visible and not season_card.visible and not result_window.visible
	if epitaph_card.is_allowed() != epitaph_allowed:
		epitaph_card.set_allowed(epitaph_allowed)
	# The feed keeps below the card standing in that column: fewer rows, the newest kept.
	var card_bottom := 0.0
	for card in [season_card, epitaph_card]:
		if card.visible:
			card_bottom = maxf(card_bottom, card.get_global_rect().end.y + 8.0)
	story_feed.fit_below(card_bottom)
	if herd_card.visible:
		_herd_height = herd_card.size.y
	# The reserve's panel stands where the herd card would.
	if reserve_session != null:
		herd_card.set_room(false)
		return
	if not selection_card.visible or _herd_height <= 0.0:
		herd_card.set_room(true)
		return
	var ceiling := 0.0
	if pinned_bar.visible:
		ceiling = pinned_bar.get_global_rect().end.y
	elif player_bar.visible:
		ceiling = player_bar.get_global_rect().end.y
	var top: float = card_stack.get_global_rect().end.y - selection_card.size.y - 8.0 - _herd_height
	# A little slack before it comes back, so it does not blink at the edge.
	herd_card.set_room(top >= ceiling + (8.0 if herd_card.has_room else 24.0))


## An action, or its key by where it sits on the keyboard, so a Russian layout presses it too.
static func _is_key(event: InputEvent, action: String, key: Key) -> bool:
	if event.is_action_pressed(action):
		return true
	return event is InputEventKey and event.pressed and not event.echo and event.physical_keycode == key


## «Летопись» on the player bar, or L: open on the selected animal, or on whoever it showed last.
func toggle_chronicle() -> void:
	power_targeting.cancel()
	if chronicle_window.visible:
		chronicle_window.close_window()
		return
	var selected := int(simulation_manager.selected_agent_id)
	chronicle_window.open(selected if selected >= 0 else chronicle_window.focus_id())


## The chronicle on one animal's family: from the card's link, an epitaph, a record.
func open_chronicle(agent_id: int) -> void:
	if agent_id >= 0:
		chronicle_window.open(agent_id, "family")


## The chronicle on every season's summary, from the season card.
func open_seasons() -> void:
	chronicle_window.open(-1, "seasons")


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
	_sync_player_bar()
	world_view.set_input_enabled(false)
	world_camera.set_input_enabled(false)
	minimap.set_input_enabled(false)


func _exit_menu_overlay() -> void:
	_pause_menu_open = false
	simulation_manager.set_paused(_paused_before_pause_menu)
	debug_panel.set_paused_state(_paused_before_pause_menu)
	player_bar.set_paused_state(_paused_before_pause_menu)
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


func _open_settings(from: String) -> void:
	if settings_panel.visible:
		return
	_settings_return = from
	start_menu.visible = false
	pause_menu.visible = false
	settings_panel.show_settings(_settings)
	settings_panel.visible = true
	_sync_overlay_blur()


func _close_settings() -> void:
	if not settings_panel.visible:
		return
	settings_panel.visible = false
	var came_from := _settings_return
	_settings_return = ""
	if came_from == "start":
		_show_start_menu(SaveSystem.latest_slot() != "")
	else:
		_set_pause_menu_visible(true)
		resume_button.grab_focus()


## A setting changed: on the window and the camera at once, and in the file.
func _on_settings_changed(values: Dictionary) -> void:
	_settings = values.duplicate()
	SettingsStore.save_settings(_settings)
	SettingsStore.apply(_settings, get_window(), world_camera)


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
	# The world is taken after the next tick, on the worker's thread, and written on a pool thread:
	# the screen does not stop for a save (`_on_world_exported()`).
	simulation_manager.request_world_export()


func _on_world_exported(world: Dictionary) -> void:
	SaveSystem.save_exported(simulation_manager, world, _selection, story_book.export_state(),
		reserve_session.export_state() if reserve_session != null else {})


## The selection tag and card are deliberately absent from this: they are the one
## readout that should be up whenever an animal is selected, which is the whole
## point of not making the user press Tab for it.
func set_hud_visible(value: bool) -> void:
	hud_visible = value
	debug_panel.visible = value
	charts_panel.visible = value
	# The charts stand where the season card does.
	season_card.set_allowed(not value and not start_menu.visible and not (result_window != null and result_window.visible))
	_sync_player_bar()
	# The two cards stand in one stack, which steps aside as a whole.
	card_stack.offset_left = _selection_card_left(value)
	card_stack.offset_right = card_stack.offset_left + SELECTION_CARD_WIDTH
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
	for path in ["CanvasLayer/HUD", "CanvasLayer/MiniMap", "CanvasLayer/ClimateIndicator", "CanvasLayer/EcologyStrip",
			"CanvasLayer/StoryFeed", "CanvasLayer/EpitaphCard", "CanvasLayer/SeasonCard", "CanvasLayer/ChronicleWindow",
			"CanvasLayer/ResultWindow"]:
		var hud_node := get_node_or_null(path)
		if hud_node is Control:
			hud_node.theme = compact
	for path in ["CanvasLayer/PauseMenu", "CanvasLayer/StartMenu", "CanvasLayer/HelpScreen", "CanvasLayer/SettingsPanel"]:
		var menu_node := get_node_or_null(path)
		if menu_node is Control:
			menu_node.theme = roomy


func _configure_projection() -> void:
	var visuals: Dictionary = simulation_manager.config_bundle.get("visuals", {})
	var max_level := 0
	var art_scale := 1.0
	if simulation_manager.world_state != null and simulation_manager.world_state.terrain_system != null:
		var terrain: TerrainSystem = simulation_manager.world_state.terrain_system
		max_level = terrain.get_max_height_level()
		art_scale = TerrainTileRenderer.iso_art_scale(visuals, terrain.cell_size)
	WorldProjection.configure(visuals, max_level, art_scale)


## Puts the camera on an animal from the story - a pinned one, a parent on the card: selected
## and followed when it is awake; asleep, the camera goes where its sector keeps it and it is
## selected as soon as it wakes; dead, the camera goes to where it died.
func _focus_animal(agent_id: int) -> void:
	_pending_focus_id = -1
	if simulation_manager.select_agent_by_id(agent_id):
		_apply_focus_mode("agent")
		return
	var status: Dictionary = story_book.pin_status(agent_id)
	var at: Vector2 = status.get("position", Vector2.INF)
	if at != Vector2.INF:
		world_camera.move_to_world_position(at)
	if not bool(status.get("dead", false)):
		_pending_focus_id = agent_id


## «Где это» on the epitaph card: the camera to where the animal died.
func _on_epitaph_place(position: Vector2) -> void:
	if position != Vector2.INF:
		world_camera.move_to_world_position(position)


func _on_tick_for_story(tick: int, _snapshot: Dictionary) -> void:
	if _pending_focus_id >= 0 and simulation_manager.select_agent_by_id(_pending_focus_id):
		_apply_focus_mode("agent")
		_pending_focus_id = -1
	if simulation_manager.should_refresh_ui_on_tick(tick):
		story_book.tick(simulation_manager.simulation_time)
		_refresh_powers()


## What the player is looking at, for the feed to tell apart from the rest of the map: the
## ground in view and the selected animal's herd.
func _story_context() -> Dictionary:
	var context := {"view": agent_renderer._visible_rect}
	var agent = simulation_manager.get_selected_agent()
	if agent != null and agent.group_id >= 0:
		context["herd"] = [agent.species_type, int(agent.group_id)]
	return context


## A line of the feed: the animal it names while it lives, otherwise where it happened.
func _on_feed_line_clicked(line: Dictionary) -> void:
	var agent_id := int(line.get("focus_id", -1))
	if agent_id >= 0 and not story_book.lineage.is_dead(agent_id):
		_focus_animal(agent_id)
		return
	var at: Vector2 = line.get("position", Vector2.INF)
	if at != Vector2.INF:
		world_camera.move_to_world_position(at)


## Switches developer mode; leaving it puts the developer panel away.
func set_developer_mode(value: bool) -> void:
	developer_mode = value
	if not value and hud_visible:
		set_hud_visible(false)


## The player's bar is up while a world runs with nothing over it: not under the setup
## screen, a menu or help, and not beside the developer panel, which has the same controls.
func _sync_player_bar() -> void:
	if player_bar == null:
		return
	player_bar.visible = _bound and not hud_visible and not _pause_menu_open \
		and not start_menu.visible and not help_screen.visible and reserve_session == null
	pinned_bar.set_allowed(player_bar.visible)
	var world = simulation_manager.world_state if simulation_manager != null else null
	powers_bar.visible = player_bar.visible and world != null and PowersBar.has_powers(world.player)
	player_bar.set_overlay_offered("show_territories", world != null and _has_territories(world))
	goal_chips.visible = player_bar.visible and simulation_manager.scenario.is_active()
	power_targeting.input_enabled = player_bar.visible
	if not player_bar.visible:
		power_targeting.cancel()


## Whether some species of the world keeps territories and lives in it.
func _has_territories(world) -> bool:
	for species_key in world.territories.keys():
		var count := int(world.config_bundle.get("world", {}).get("spawns", {}).get("%s_count" % species_key, 0))
		if count > 0 or world.territories[species_key].census()["vacant"] < world.territories[species_key].size():
			return true
	return false


func _apply_debug_configuration() -> void:
	var debug_config: Dictionary = simulation_manager.config_bundle.get("debug", {})
	set_developer_mode(bool(debug_config.get("developer_mode", false)))
	player_bar.configure(debug_config.get("speed_steps", [1.0]), simulation_manager.speed_multiplier,
		simulation_manager.debug_flags)
	player_bar.set_paused_state(simulation_manager.paused)
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
	pause_blur.visible = start_menu.visible or pause_menu.visible or help_screen.visible or settings_panel.visible


func _sync_lod_focus_rect() -> void:
	if simulation_manager == null or simulation_manager.world_state == null or world_camera == null:
		return
	# The camera reports a screen-space rect; sector dormancy is decided in
	# simulation space, so it goes through the projection seam.
	var focus_rect: Rect2 = WorldProjection.world_rect_covering(world_camera.get_visible_screen_rect())
	var bounds: Rect2 = simulation_manager.world_state.bounds
	var overview_config: Dictionary = simulation_manager.config_bundle.get("visuals", {}).get("overview_lod", {})
	var visible_fraction := WorldProjection.visible_world_fraction(
		world_camera.get_visible_screen_rect(), bounds)
	_overview_mode = resolve_overview_fraction(_overview_mode, visible_fraction, overview_config)
	var focus_center := WorldProjection.to_world(world_camera.global_position)
	simulation_manager.set_lod_view(focus_rect, focus_center, _overview_mode)
	agent_renderer.set_overview_mode(_overview_mode)
	minimap.set_overview_mode(_overview_mode)
	if bool(simulation_manager.debug_flags.get("show_lod_overlay", false)):
		world_view.request_refresh()


static func resolve_overview_mode(current: bool, visible_rect: Rect2, bounds: Rect2, config: Dictionary) -> bool:
	if not bool(config.get("enabled", true)) or bounds.get_area() <= 0.0:
		return false
	var fraction := visible_rect.intersection(bounds).get_area() / bounds.get_area()
	return resolve_overview_fraction(current, fraction, config)


static func resolve_overview_fraction(current: bool, fraction: float, config: Dictionary) -> bool:
	if not bool(config.get("enabled", true)):
		return false
	var threshold := float(config.get("exit_visible_fraction", 0.15)) if current \
		else float(config.get("enter_visible_fraction", 0.2))
	return fraction >= threshold


func _exit_game() -> void:
	SaveSystem.finish_writing()
	get_tree().quit()


## The window closed: a save being written is finished first.
func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		SaveSystem.finish_writing()
