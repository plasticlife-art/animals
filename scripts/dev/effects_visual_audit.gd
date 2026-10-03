extends SceneTree

# Screenshot harness for the event effects. Not part of the game.
#
#   Godot --path . --script res://scripts/dev/effects_visual_audit.gd -- <out_prefix> [style]
# Runs the real main scene to noon and then to midnight, and at each stages the effects on
# the animals nearest the middle of the map, through the same worker frames and events the
# game uses: a herbivore killed by a predator and a predator that starved, each frozen at
# several points of its fall and shot up close, as
# `<prefix>-<noon|midnight>-<herbivore|predator>-<offset>.png`. The world stays paused
# while a series is shot, so the shots differ only in the effect.

const NOON := 120.0
const MIDNIGHT := 180.0
## Seconds into the fall: first frame, falling, the blow (a kill only), lying, fading.
const OFFSETS := [0.05, 0.3, 0.55, 0.72, 0.9]
const VICTIMS := [["herbivore", "predation"], ["predator", "starvation"]]

var _frames := 0
var _main: Node = null
var _manager = null
var _camera = null
var _renderer = null
var _prefix := "user://effects"
var _style := ""
var _steps: Array = []
var _wait_until_msec := 0
var _aimed_id := -1


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		_prefix = args[0]
	if args.size() > 1:
		_style = args[1]
	root.size = Vector2i(1600, 900)
	_main = load("res://scenes/main/main.tscn").instantiate()
	root.add_child(_main)


func _process(_delta: float) -> bool:
	_frames += 1
	if _frames == 10:
		var menu = _main.get_node_or_null("CanvasLayer/StartMenu")
		if menu != null and menu.visible:
			var selection: Dictionary = ConfigLoader.default_selection()
			if _style != "":
				selection["style"] = _style
			menu.start_requested.emit(selection)
	if _frames < 30:
		return false
	if _manager == null:
		_manager = _main.get_node("SimulationManager")
		_camera = _main.get_node("GameCamera")
		_renderer = _main.get_node("AgentRenderer")
		# A close camera while time runs, so the far sectors sleep and the run is quick.
		_aim(_manager.world_state.bounds.get_center(), 1.0)
		for moment in [["noon", NOON], ["midnight", MIDNIGHT]]:
			_steps.append(_run_to.bind(moment[1]))
			for victim in VICTIMS:
				_steps.append(_aim_at_nearest.bind(victim[0]))
				_steps.append(_kill_aimed.bind(victim[1]))
				for offset in OFFSETS:
					_steps.append(_freeze_dying.bind(offset))
					_steps.append(_save.bind("%s-%s-%.2f" % [moment[0], victim[0], offset]))
	if Time.get_ticks_msec() < _wait_until_msec:
		return false
	while not _steps.is_empty():
		var step: Callable = _steps.front()
		# A step returns how long to let the window draw before the next one, or -1 to be
		# called again next frame.
		var wait_msec: int = step.call()
		if wait_msec < 0:
			return false
		_steps.pop_front()
		if wait_msec > 0:
			# macOS stops presenting a window that sits behind others, and the picture
			# saved is then the last frame it drew.
			DisplayServer.window_move_to_foreground()
			_wait_until_msec = Time.get_ticks_msec() + wait_msec
			return false
	return true


func _run_to(seconds: float) -> int:
	if _manager.simulation_time < seconds:
		_manager.paused = false
		_manager.speed_multiplier = 64.0
		if _frames % 300 == 0:
			print("t=%.0f" % _manager.simulation_time)
		return -1
	_manager.paused = true
	_manager.synchronize_worker()
	return 0



## The awake animal of `species` nearest the middle of the view, put in the middle of it.
func _aim_at_nearest(species: String) -> int:
	var centre: Vector2 = _manager.world_state.bounds.get_center()
	var best = null
	for agent in _manager.world_state.get_living_agents():
		if agent.species_type != species:
			continue
		if best == null or agent.position.distance_squared_to(centre) < best.position.distance_squared_to(centre):
			best = agent
	_aimed_id = -1 if best == null else int(best.id)
	if best != null:
		_aim(best.position, 1.2)
		print("aimed at %s %d at %s" % [species, _aimed_id, best.position])
	return 1500


## Kills the aimed animal in the worker's world and runs one tick there, so its death,
## its body and its removal reach the view in one frame, as a death in a tick does. The
## death happens between ticks, where the worker drops events, so it is put back in.
func _kill_aimed(cause: String) -> int:
	var worker = _manager._worker
	var victim = worker.world.get_agent(_aimed_id) if _aimed_id >= 0 else null
	if victim == null:
		print("nothing to kill")
		return 0
	# The last series is still frozen mid-fade on the paused clock.
	_renderer._dying.clear()
	var heard: Array = []
	var listen := func(event: Dictionary) -> void: heard.append(event)
	worker.events.event_emitted.connect(listen)
	worker.world.kill_agent(victim, cause)
	worker.events.event_emitted.disconnect(listen)
	var frame: Dictionary = worker.step(_manager.tick_duration, _manager.current_tick, _manager.simulation_time,
		_manager._build_lod_context(), _manager.selected_agent_id, false, false, _manager.ground_update_interval_ticks())
	frame["events"] = heard + frame["events"]
	_manager._apply_worker_frame(frame)
	print("killed %d (%s): %d dying sprites" % [_aimed_id, cause, _renderer.transient_sprites().size()])
	return 0


## Holds every dying sprite `offset` seconds into its fall: the clock stands still while
## paused, so a start moved back by `offset` keeps it there.
func _freeze_dying(offset: float) -> int:
	var now: float = _manager.get_display_time()
	for state in _renderer.transient_sprites():
		state["start"] = now - offset
	_renderer._needs_refresh = true
	return 2500


func _save(name: String) -> int:
	var path := "%s-%s.png" % [_prefix, name]
	root.get_texture().get_image().save_png(path)
	var states: Array = _renderer.transient_sprites()
	var described := "none" if states.is_empty() else "frame %d alpha %.2f" % [int(states[0].frame), float(states[0].alpha)]
	print("saved %s at t=%.1f: %s, carcasses drawn %s" % [path, _manager.simulation_time, described,
		_renderer.scene_batch.last_counts.get("visible_carcasses", -1)])
	return 0


func _aim(world_position: Vector2, zoom: float) -> void:
	var terrain = _manager.world_state.terrain_system
	var level: int = 0 if terrain == null else terrain.get_height_at_position(world_position)
	_camera.global_position = WorldProjection.to_screen(world_position, level)
	_camera.zoom = Vector2(zoom, zoom)
	_camera.force_update_scroll()
