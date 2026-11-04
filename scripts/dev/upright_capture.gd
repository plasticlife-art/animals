extends SceneTree

## The living reserve upright, as a phone sees it. Not part of the game.
##
##   OUT=/tmp/upright.png SAVES=/tmp/saves Godot --path . --script res://scripts/dev/upright_capture.gd
##
## HELP=1 shows the commands as after «!помощь»; without it they are not shown by themselves. The reserve starts fresh, with its saves and its
## stream settings under SAVES, never the player's own.

var _main
var _frames := 0
var _parked_msec := -1


func _initialize() -> void:
	var saves := OS.get_environment("SAVES")
	SaveSystem.save_dir = saves
	_main = load("res://scenes/main/main.tscn").instantiate()
	_main.stream_settings_path = saves.path_join("stream.json")
	root.add_child(_main)


func _process(_delta: float) -> bool:
	_frames += 1
	if _frames == 3:
		_main._hide_start_menu()
		_main._start_reserve(true)
		_main.set_reserve_portrait(true)
		root.mode = Window.MODE_WINDOWED
		root.size = Vector2i(540, 960)
	if _frames == 30:
		var manager = _main.simulation_manager
		var agents: Array = manager.world_state.get_living_agents()
		var target = agents[agents.size() / 2]
		for agent in agents:
			if agent.species_type == "herbivore" and int(agent.group_id) >= 0:
				target = agent
				break
		manager.select_agent_by_id(target.id, true)
		var session = _main.reserve_session
		if OS.get_environment("HELP") == "1":
			session.help_asked_at = session.now()
		else:
			var overlay: Dictionary = session.config.get("overlay", {})
			overlay["help_every_seconds"] = 0.0
			session.config["overlay"] = overlay
		DisplayServer.window_move_to_foreground()
		_parked_msec = Time.get_ticks_msec()
	if _parked_msec < 0 or _frames < 60 or Time.get_ticks_msec() - _parked_msec < 2500:
		return false
	RenderingServer.force_draw()
	var image: Image = root.get_texture().get_image()
	image.resize(540, roundi(540.0 * image.get_height() / image.get_width()))
	image.save_png(OS.get_environment("OUT"))
	print("saved %s" % OS.get_environment("OUT"))
	return true
