extends SceneTree

## Screenshots of the steward's interface in a scenario («Долгая сушь» unless named), from the
## real scene. Not part of the game. Windowed, and the window has to be in front for the captures to show the frame - an
## occluded window stops drawing while the world runs on - so it stays on top for the run and
## comes to the front before each capture:
##
##   Godot --path . --script res://scripts/dev/steward_capture.gd -- OUTDIR [style] [quick|brief|full] [scenario]
##
## `quick` brings the scenario's deciding moment - its time and its season - to fifteen seconds
## after the walk, so the result window comes without minutes of play (the score is the view's
## own; the world is untouched); `brief` stops after the brief.
##
## 01 the brief, 02 play with the powers and the goals, 03 aiming a waterhole, 04 it dug - or,
## where the scenario offers the cull and not the waterhole, 03 aiming a cull where most foxes
## near the herd stand, 04 them culled - 05 aiming a lead, 06 the herd walking (and
## 06_lead.gif), 07 the result, 08 at 125 %. The
## saves go to a scratch slot directory and the player's settings come back as they were; the
## aim is placed without moving the cursor (`PowerTargeting.pointer_override`).

const GIF_WIDTH := 640
const GIF_FRAMES := 36

var _main = null
var _out := ""


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	_out = str(args[0]) if args.size() > 0 else "/private/tmp/steward-capture"
	var style := str(args[1]) if args.size() > 1 else "topdown_kenney"
	var quick := args.size() > 2 and str(args[2]) == "quick"
	var scenario_id := str(args[3]) if args.size() > 3 else "long_drought"
	DirAccess.make_dir_recursive_absolute(_out)
	DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_ALWAYS_ON_TOP, true)
	SaveSystem.save_dir = "user://capture_saves"
	var settings_before: Dictionary = SettingsStore.load_settings()
	_main = load("res://scenes/main/main.tscn").instantiate()
	root.add_child(_main)
	await _frames(10)
	_main.start_menu.scenario_requested.emit(scenario_id, style)
	await _frames(30)
	await _snap("01_brief")
	if args.size() > 2 and str(args[2]) == "brief":
		quit()
		return
	_main.result_window._buttons.get_child(0).pressed.emit()
	await _frames(240)
	_main._refresh_powers()
	await _frames(2)
	await _snap("02_play")
	var sim = _main.simulation_manager
	var herd := PowerAim.herd_to_lead(sim)
	var center: Vector2 = herd.get("center", sim.world_state.bounds.get_center())
	if sim.world_state.player.budget.has("dig_pond"):
		var spot := _dig_spot(sim.world_state, center)
		_main._on_power_pressed("dig_pond")
		_main.power_targeting.pointer_override = WorldProjection.to_screen(spot)
		await _frames(6)
		await _snap("03_aim_pond")
		print("dig at ", spot, " order ", _main.power_targeting.click(WorldProjection.to_screen(spot)))
		_main.power_targeting.pointer_override = Vector2.INF
		await _frames(150)
		_main._refresh_powers()
		await _frames(2)
		await _snap("04_pond_dug")
	elif sim.world_state.player.budget.has("cull"):
		# Foxes come and go; wait, faster, for some in view.
		sim.set_speed_multiplier(10.0)
		var shot := _cull_spot(sim, center)
		var waiting := 0
		while not shot.is_finite() and waiting < 3600:
			await _frames(30)
			waiting += 30
			shot = _cull_spot(sim, center)
		sim.set_speed_multiplier(1.0)
		print("foxes in view after ", waiting, " frames")
		if not shot.is_finite():
			shot = center
		_main._on_power_pressed("cull")
		_main.power_targeting.pointer_override = WorldProjection.to_screen(shot)
		await _frames(6)
		await _snap("03_aim_cull")
		print("cull at ", shot, " order ", _main.power_targeting.click(WorldProjection.to_screen(shot)))
		_main.power_targeting.pointer_override = Vector2.INF
		await _frames(60)
		_main._refresh_powers()
		await _frames(2)
		await _snap("04_culled")
	var goal := _lead_goal(sim, center)
	_main._on_power_pressed("lead_herd")
	_main.power_targeting.pointer_override = WorldProjection.to_screen(goal)
	await _frames(6)
	await _snap("05_aim_flag")
	print("lead to ", goal, " order ", _main.power_targeting.click(WorldProjection.to_screen(goal)))
	_main.power_targeting.pointer_override = Vector2.INF
	await _frames(30)
	await _gif("06_lead")
	await _snap("06_lead")
	sim.set_speed_multiplier(10.0)
	if quick:
		var climate: Dictionary = sim.config_bundle.get("world", {}).get("climate", {})
		for goal_id in sim.scenario.decide_times.keys():
			sim.scenario.decide_times[goal_id] = sim.simulation_time + 15.0
			sim.scenario.decide_ordinals[goal_id] = Climate.season_ordinal(climate, sim.simulation_time + 15.0)
	var waited := 0
	while _main.result_window.mode() != "result" and waited < 120000 and sim.simulation_time < 900.0:
		await process_frame
		waited += 1
	print("result after ", waited, " frames at t=", snappedf(sim.simulation_time, 0.1), ": ", sim.scenario.result)
	await _frames(6)
	await _snap("07_result")
	_main.result_window.watch_on_requested.emit()
	sim.set_speed_multiplier(1.0)
	var scaled := settings_before.duplicate()
	scaled["ui_scale"] = 1.25
	_main._on_settings_changed(scaled)
	await _frames(30)
	_main._refresh_powers()
	await _frames(2)
	await _snap("08_scale125")
	_main._on_settings_changed(settings_before)
	for path in SaveSystem.slot_paths():
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	quit()


func _frames(count: int) -> void:
	for _index in range(count):
		await process_frame


func _snap(name: String) -> void:
	DisplayServer.window_move_to_foreground()
	for _index in range(3):
		await process_frame
	var path := "%s/%s.png" % [_out, name]
	root.get_texture().get_image().save_png(path)
	print("saved ", path)


func _gif(name: String) -> void:
	var size: Vector2i = root.get_texture().get_size()
	var height := int(round(float(GIF_WIDTH) * float(size.y) / float(size.x)))
	var encoder := GifEncoder.new(GIF_WIDTH, height)
	for _index in range(GIF_FRAMES):
		var image: Image = root.get_texture().get_image()
		image.resize(GIF_WIDTH, height, Image.INTERPOLATE_BILINEAR)
		image.convert(Image.FORMAT_RGB8)
		encoder.add_frame(image.get_data(), 12)
		await _frames(7)
	var file := FileAccess.open("%s/%s.gif" % [_out, name], FileAccess.WRITE)
	file.store_buffer(encoder.finish())
	file.close()
	print("saved ", name, ".gif")


## The first place, in rings out from beside the herd, a waterhole may be dug.
func _dig_spot(world, center: Vector2) -> Vector2:
	var step: float = world.player_pond_radius() * 1.5
	for ring in range(1, 12):
		for index in range(ring * 6):
			var spot := center + Vector2.from_angle(TAU * float(index) / float(ring * 6)) * step * float(ring)
			if world.dig_pond_refusal(spot) == "":
				return spot
	return center


## Where, among the foxes on the screen, a cull would take the most - `Vector2.INF` if none are in
## view.
func _cull_spot(sim, _center: Vector2) -> Vector2:
	var world = sim.world_state
	var radius: float = world.cull_radius()
	var view: Rect2 = root.get_visible_rect().grow(-120.0)
	# `WorldProjection.to_screen` is the world's canvas; the camera puts that on the window.
	var canvas: Transform2D = _main.get_viewport().get_canvas_transform()
	var best := Vector2.INF
	var most := 0
	for agent in world.get_living_agents():
		if agent.species_type != "predator" or not view.has_point(canvas * WorldProjection.to_screen(agent.position)):
			continue
		var count := PowerAim.cull_count(world, agent.position, radius, ["predator"])
		if count > most:
			most = count
			best = agent.position
	return best


## A goal the herd can be led to, some way off.
func _lead_goal(sim, center: Vector2) -> Vector2:
	var aim := PowerAim.new()
	aim.power = "lead_herd"
	for distance in [900.0, 700.0, 1200.0, 500.0]:
		for index in range(12):
			var goal: Vector2 = center + Vector2.from_angle(TAU * float(index) / 12.0) * distance
			if str(aim.preview(sim, goal).get("reason", "x")) == "":
				return goal
	return center + Vector2(400.0, 0.0)
