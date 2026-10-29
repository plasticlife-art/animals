extends SceneTree

# Screenshot harness for visual verification. Not part of the game.
#
#   Godot --path . --script res://scripts/dev/capture.gd -- <out.png> [zoom] [preset]
# Presets: `selected` / `selected_hud` select an animal (with the Tab panels for the
# second), `herd` selects a grazer in a herd so its herd card shows, `story` also pins it
# and two others, `chronicle` then opens the chronicle on it, `epitaph` tells the death of one
# pinned animal far away, `traits` opens the chronicle's «Черты» on a made-up history of
# eighty-nine years (`traits_species` on one species, `traits_drill` on one trait alone,
# `insights` on «Выводы» drawn from it), `ponds` / `ponds_iso` shows watering holes at made-up levels (a quarter dry, the
# rest a tenth, a third and three quarters full) top-down or isometric, `season` shows a made-up
# summer's card with an epitaph under it, `seasons` opens the chronicle's «Сезоны» on two
# made-up years,
# `scaled` is `story` under a 125 % interface (applied, not saved),
# `settings` shoots the settings panel, `water` turns on the minimap's water, `menu` shoots
# the setup screen.
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

const TraitsScript := preload("res://scripts/agents/traits.gd")
const TraitHistoryScript := preload("res://scripts/story/trait_history.gd")
const TraitsViewScript := preload("res://scripts/ui/traits_view.gd")
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
					"epitaph", "scaled", "settings", "traits", "traits_species", "traits_drill", "insights", "ponds",
					"ponds_iso", "season", "seasons"]:
				selection["style"] = _preset
			if _preset == "ponds_iso":
				selection["style"] = "isometric_craftpix"
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


## The harness only: levels by pond index, on the worker's world and the view's, so the frame
## shows them at once.
func _set_made_up_levels() -> void:
	var worlds: Array = [_manager.world_state]
	if _manager._worker != null:
		worlds.append(_manager._worker.world)
	for world in worlds:
		if world.water == null or not world.water.enabled:
			continue
		for index in range(world.water_sources.size()):
			world.water.levels[index] = [0.0, 0.12, 0.35, 0.75][index % 4]
			world.water._settle(index)
		world.water.take_transitions()


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
	if _preset.begins_with("ponds"):
		_set_made_up_levels()
		_aim(world.water_sources[2]["position"] if world.water_sources.size() > 2 else _focus)
		return
	var agents: Array = world.get_living_agents()
	if agents.is_empty():
		push_error("capture: no living agents even after settling")
		return
	var target = agents[agents.size() / 2]
	var story_like := _preset in ["story", "chronicle", "epitaph", "scaled", "traits", "traits_species", "traits_drill",
		"insights", "season", "seasons"]
	if _preset == "scaled":
		SettingsStore.apply({"fullscreen": false, "ui_scale": 1.25}, root, _camera)
	if _preset == "settings":
		_main._open_settings("pause")
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
	if _preset == "epitaph" or _preset == "season":
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
	if _preset in ["traits", "traits_species", "traits_drill", "insights"]:
		_made_up_traits()
		var heredity: Array = _main.story_book.heredity_species
		var shown := "hare" if heredity.has("hare") else "herbivore"
		if _preset == "traits_species":
			_main.chronicle_window.show_trait(shown)
			# The pointer over the first chart, three quarters along, for its reading.
			_main.chronicle_window._traits_view._hover = Vector2(TraitsViewScript.LIST_WIDTH + 16.0 + 40.0 + 120.0, 80.0)
		elif _preset == "traits_drill":
			_main.chronicle_window.show_trait("herbivore", 0)
		else:
			_main.chronicle_window.open(target.id, "insights" if _preset == "insights" else "traits")
		_main.chronicle_window.visible = true
	if _preset == "season":
		_main.story_book.season_closed.emit(_made_up_season(5, true))
	if _preset == "seasons":
		# Two years made up, since a fresh world has none closed. The harness only.
		_main.story_book.seasons.closed.clear()
		for ordinal in range(7):
			_main.story_book.seasons.closed.append(_made_up_season(ordinal, ordinal == 5))
		_main.open_seasons()
	var rect: Rect2 = _camera.get_visible_screen_rect()
	var in_frame := 0
	for agent in agents:
		if rect.has_point(WorldProjection.to_screen(agent.position, _height_at(agent.position))):
			in_frame += 1
	print("tick=%d camera=%s zoom=%s agents_in_frame=%d/%d" % [
		_manager.current_tick, _camera.global_position, _camera.zoom, in_frame, agents.size()])


## Eighty-nine years of traits made up, since a fresh world has one point: means that wander and
## drift, spreads, numbers, who left young and who died of what, the founders, and the seasons with
## droughts and a cull. Deer grow faster as foxes take the slow, foxes lose their sight to hunger,
## a few grouse wander by chance, three old wolves take the pack's appetite with them, and the
## hares pass a bottleneck. The harness only.
func _made_up_traits() -> void:
	var book = _main.story_book
	var history = book.trait_history
	history.clear()
	var steps := 220
	var year := 480.0
	var length := 89.0 * year
	var plans := {
		"herbivore": {"drift": [0.12, 0.15, 0.10, -0.03, 0.02], "count": 250.0, "salt": 1},
		"predator": {"drift": [0.08, -0.10, -0.04, 0.04, -0.015], "count": 42.0, "salt": 2},
		"scavenger": {"drift": [0.06, -0.11, 0.06, 0.03, 0.05], "count": 22.0, "salt": 3, "vol": 0.012},
		"wolf": {"drift": [0.06, 0.0, 0.03, 0.03, 0.01], "count": 11.0, "salt": 4, "vol": 0.008},
		"hare": {"drift": [0.13, 0.15, -0.02, 0.0, 0.015], "count": 130.0, "salt": 5},
	}
	var walk := {}
	for species_id in plans.keys():
		walk[species_id] = [1.0, 1.0, 1.0, 1.0, 1.0]
		var founders: Array = []
		for animal in range(120):
			var traits: Array = []
			for index in range(5):
				traits.append(1.0 + 0.08 * (TraitsScript.unit(animal + 1000 * int(plans[species_id]["salt"]), index) * 2.0 - 1.0))
			founders.append(traits)
		history.founders[species_id] = TraitHistoryScript.histograms(founders)
	for step in range(steps):
		var time := float(step) / float(steps - 1) * length
		var values := {}
		var spreads := {}
		var counts := {}
		var tallies := {}
		for species_id in plans.keys():
			var plan: Dictionary = plans[species_id]
			var means: Array = walk[species_id]
			var vol := float(plan.get("vol", 0.004))
			for index in range(5):
				var noise := TraitsScript.unit(step * 7 + index, int(plan["salt"]) * 131) - 0.5
				means[index] = float(means[index]) + float(plan["drift"][index]) / float(steps) + noise * vol
			if species_id == "wolf" and step == 196:
				means[2] = float(means[2]) - 0.05
			var count := float(plan["count"]) * (1.0 + 0.15 * sin(float(step) * 0.21 + float(plan["salt"])))
			var narrow := 1.0
			if species_id == "hare":
				if step >= 100 and step < 116:
					count = 31.0 + absf(float(step) - 108.0) * 9.0
				if step >= 108:
					narrow = 0.55
			values[species_id] = means.duplicate()
			spreads[species_id] = [0.045 * narrow, 0.05 * narrow, 0.04 * narrow, 0.025 * narrow, 0.05 * narrow]
			counts[species_id] = int(count)
			var groups := {}
			var leans: Dictionary = {"herbivore": {"parents": [0, 0.012, 9], "predation": [0, -0.016, 4], "old_age": [1, 0.0, 3]},
				"predator": {"parents": [1, -0.006, 2], "starvation": [1, 0.02, 2]},
				"scavenger": {"parents": [0, 0.004, 1]},
				"wolf": {"old_age": [2, 0.0, 1]},
				"hare": {"parents": [0, 0.015, 6], "predation": [0, -0.02, 5]}}[species_id]
			for group in leans.keys():
				var lean: Array = leans[group]
				var tally: Array = []
				for index in range(5):
					tally.append((float(means[index]) + (float(lean[1]) if index == int(lean[0]) else 0.0)) * float(lean[2]))
				tally.append(int(lean[2]))
				groups[group] = tally
			if species_id == "wolf" and step == 196:
				var gone: Array = []
				for index in range(5):
					gone.append((float(means[index]) + (0.14 if index == 2 else 0.0)) * 3.0)
				gone.append(3)
				groups["old_age"] = gone
			tallies[species_id] = groups
		history.points.append({"time": time, "values": values, "spread": spreads, "counts": counts, "tallies": tallies})
	# No real point after the made-up ones.
	history._next_at = INF
	book.seasons.closed.clear()
	var season := year / 4.0
	var first := maxi(0, int(length / season) - 200)
	for ordinal in range(first, int(length / season)):
		var summary := _made_up_season(ordinal, (ordinal / 4) % 5 == 2)
		summary["start"] = float(ordinal) * season
		summary["end"] = float(ordinal + 1) * season
		if ordinal == int(length / season) - 30:
			summary["species"]["predator"]["deaths"]["culled"] = 6
		book.seasons.closed.append(summary)


## A season's summary made up for the shots, with the world's own pond names and a hunter's.
func _made_up_season(ordinal: int, drought: bool) -> Dictionary:
	var book = _main.story_book
	var season_id: String = ["spring", "summer", "autumn", "winter"][ordinal % 4]
	var label: String = ["Весна", "Лето", "Осень", "Зима"][ordinal % 4]
	var breeding := ordinal % 4 <= 1
	var ponds: Array = []
	var genders := {}
	for index in range(mini(5, book.places.ponds.size())):
		ponds.append(str(book.places.ponds[index]["name"]))
		genders[ponds.back()] = str(book.places.ponds[index].get("gender", "m"))
	var hunter := -1
	for agent in _manager.world_state.get_living_agents():
		if agent.species_type == "predator":
			hunter = agent.id
			break
	return {"ordinal": ordinal, "year": ordinal / 4, "season_id": season_id, "label": label, "partial": false,
		"drought": drought and ordinal % 4 in [1, 2],
		"species": {
			"herbivore": {"start": 240 + ordinal * 6, "end": 278 + ordinal * 6 if breeding else 228 + ordinal * 6,
				"births": 74 if breeding else 0, "deaths": {"predation": 11, "starvation": 5, "thirst": 4, "old_age": 16}, "died": 36},
			"predator": {"start": 47, "end": 41, "births": 12 if breeding else 0, "deaths": {"starvation": 4, "old_age": 14}, "died": 18},
			"scavenger": {"start": 106, "end": 118, "births": 40 if breeding else 0, "deaths": {"predation": 20, "old_age": 8}, "died": 28},
		},
		"hunter": {} if hunter < 0 else {"id": hunter, "name": book.name_of_id(hunter), "kills": 5,
			"species": "predator", "sex": str(book.lineage.entry(hunter).get("sex", "male"))},
		"dried": ponds if ordinal % 4 == 1 else [], "refilled": ponds if ordinal % 4 == 0 and ordinal > 0 else [],
		"genders": genders}
