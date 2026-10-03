extends SceneTree

# Screenshot harness for visual verification. Not part of the game.
#
#   Godot --path . --script res://scripts/dev/capture.gd -- <out.png> [zoom] [preset]
# Presets: `selected` / `selected_hud` select an animal (with the Tab panels for the
# second), `herd` selects a grazer in a herd so its herd card shows, `story` also pins it
# and two others, `chronicle` then opens the chronicle on it, `epitaph` tells the death of one
# pinned animal far away, `water` turns on the minimap's water, `menu` shoots the setup screen.
# Loads the real main scene, parks the camera, waits for
# LOD sectors around it to reify, then writes a PNG.
#
# The camera has to be parked before agents are read: agents outside the LOD
# focus rect are dormant and absent from `world.agents` entirely, so a fresh
# scene reports zero living agents until the camera tells it where to look.

var _frames := 0
var _main: Node = null
var _manager = null
var _camera = null
var _out := "user://capture.png"
var _zoom := 0.55
var _focus := Vector2.ZERO
var _preset := ""
var _hide_overlays := false
var _parked_msec := 0

const PARK_FRAME := 90
const SETTLE_FRAMES := 300


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		_out = args[0]
	if args.size() > 1:
		_zoom = float(args[1])
	if args.size() > 2:
		_preset = args[2]
	if args.size() > 3:
		_hide_overlays = args[3] == "noverlay"
	root.size = Vector2i(1600, 900)
	_main = load("res://scenes/main/main.tscn").instantiate()
	root.add_child(_main)


func _process(_delta: float) -> bool:
	_frames += 1
	if _frames == 10:
		# The app now opens on the setup screen and simulates nothing until it is
		# dismissed, so the harness makes the choice a person would.
		var menu = _main.get_node_or_null("CanvasLayer/StartMenu")
		if _preset == "menu":
			return false
		if menu != null and menu.visible:
			var selection: Dictionary = ConfigLoader.default_selection()
			# Anything that is not one of the shots below names an art style.
			if _preset != "" and _preset not in ["selected", "selected_hud", "hud", "water", "herd", "story", "chronicle",
					"epitaph"]:
				selection["style"] = _preset
			menu.start_requested.emit(selection)
	if _preset == "menu":
		if _frames < 40:
			return false
		root.get_texture().get_image().save_png(_out)
		print("saved menu %s" % _out)
		return true
	if _frames == PARK_FRAME:
		if _hide_overlays:
			_main.get_node("OverlayRenderer").visible = false
			_main.get_node("WorldView").visible = false
			_main.get_node("TerrainTiles").visible = false
		if _preset == "hud" or _preset == "selected_hud":
			_main.set_hud_visible(true)
		if _preset == "water":
			_main.set_hud_visible(true)
			_main._on_overlay_flag_changed("show_minimap_water", true)
		_manager = _main.get_node_or_null("SimulationManager")
		_camera = _main.get_node_or_null("GameCamera")
		var bounds: Rect2 = _manager.world_state.bounds
		_focus = bounds.position + bounds.size * 0.5
		_aim(_focus)
	if _frames == PARK_FRAME + SETTLE_FRAMES:
		_park_on_agent()
		# macOS stops presenting a window that sits behind others, and the picture saved
		# is then the last frame it drew, from before the camera moved.
		DisplayServer.window_move_to_foreground()
		_parked_msec = Time.get_ticks_msec()
	if _frames < PARK_FRAME + SETTLE_FRAMES + 8 or Time.get_ticks_msec() - _parked_msec < 2500:
		return false
	root.get_texture().get_image().save_png(_out)
	print("saved %s" % _out)
	return true


func _aim(world_position: Vector2) -> void:
	_camera.global_position = WorldProjection.to_screen(
		world_position, _height_at(world_position))
	_camera.zoom = Vector2(_zoom, _zoom)
	_camera.force_update_scroll()


func _height_at(world_position: Vector2) -> int:
	var terrain = _manager.world_state.terrain_system
	return 0 if terrain == null else terrain.get_height_at_position(world_position)


func _park_on_agent() -> void:
	var world = _manager.world_state
	var agents: Array = world.get_living_agents()
	if agents.is_empty():
		push_error("capture: no living agents even after settling")
		return
	var target = agents[agents.size() / 2]
	var story_like := _preset in ["story", "chronicle", "epitaph"]
	if _preset == "herd" or story_like:
		# A grazer in a herd, so the herd card is up above the animal's own.
		for agent in agents:
			if agent.species_type == "herbivore" and int(agent.group_id) >= 0:
				target = agent
				break
	_aim(target.position)
	if story_like:
		# Three animals pinned - the one in view and two others - for the list at the top left.
		var pinned := 0
		for agent in agents:
			if pinned < 3 and (agent == target or agent.species_type != target.species_type):
				_main.story_book.toggle_pin(agent)
				pinned += 1
	if _preset == "epitaph":
		# The last pinned one dies far away, told the way a sleeping sector tells it.
		var dying := int(_main.story_book.pins.back())
		var where: Vector2 = _manager.world_state.water_sources[0]["position"] if not _manager.world_state.water_sources.is_empty() \
			else target.position
		_main.story_book.hear({"type": "AgentDied", "agent_id": -1, "species": str(_main.story_book.lineage.entry(dying)
			.get("species", "")), "time_seconds": _manager.simulation_time, "position": {"x": where.x, "y": where.y},
			"data": {"cause": "old_age", "dormant": true, "record_id": dying, "group_id": -1, "age": 1010.0}})
	if _preset == "selected" or _preset == "selected_hud" or _preset == "herd" or story_like:
		# Centring is not selecting, and the tag and card only exist for a selection.
		var radius := float(_manager.config_bundle.get("debug", {}).get("selection_radius", 18.0))
		_manager.select_agent_at_position(target.position, radius)
	if _preset == "chronicle":
		# A family made up around the animal, since a fresh world has only founders: two
		# parents, three grandparents, five young, one of them dead. The harness only.
		var book = _main.story_book
		var lineage = book.lineage
		var t := float(_manager.simulation_time)
		for relative in [[900001, "female", -900.0], [900002, "male", -900.0], [900003, "female", -900.0],
				[900010, "female", -500.0], [900011, "male", -480.0]]:
			lineage.note_birth(relative[0], "herbivore", relative[1], 0.0, 0, [])
			lineage.entry(relative[0])["born"] = -1.0
			lineage.note_animal(relative[0], "herbivore", relative[1], 0, -float(relative[2]), t)
		lineage.note_birth(900010, "herbivore", "female", 0.0, 0, [900001, 900002])
		lineage.note_birth(900011, "herbivore", "male", 0.0, 0, [900003])
		lineage.note_death(900002, t, "predation", -1, target.position)
		var entry: Dictionary = lineage.entry(target.id)
		entry["mother"] = 900010
		entry["father"] = 900011
		for child in range(5):
			lineage.note_birth(900100 + child, "herbivore", "male" if child % 2 == 0 else "female", t, 0, [target.id, 900011])
		lineage.note_death(900103, t, "starvation", -1, target.position)
		_main.open_chronicle(target.id)
	var rect: Rect2 = _camera.get_visible_screen_rect()
	var in_frame := 0
	for agent in agents:
		if rect.has_point(WorldProjection.to_screen(agent.position, _height_at(agent.position))):
			in_frame += 1
	print("tick=%d camera=%s zoom=%s agents_in_frame=%d/%d" % [
		_manager.current_tick, _camera.global_position, _camera.zoom, in_frame, agents.size()])
