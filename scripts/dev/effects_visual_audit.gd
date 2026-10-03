extends SceneTree

# Screenshot harness for the event effects. Not part of the game.
#
#   Godot --path . --script res://scripts/dev/effects_visual_audit.gd -- <out_prefix> [style]
# Runs the real main scene to noon and then to midnight, and at each stages the effects on
# the animals nearest the middle of the map, through the same worker frames and events the
# game uses:
#   - a trail of dust as a running herbivore would leave it, laid down puff by puff at the
#     game's spacing (`...-dust-<offset>.png`): the look of the dust, whether or not a real
#     chase is on screen when the shot is due;
#   - a herbivore killed by a predator: its fall, the burst and the flash
#     (`<prefix>-<noon|midnight>-kill-<offset>.png`);
#   - a predator that starved: its fall without the red (`...-starved-<offset>.png`);
#   - the bodies both leave, whole, half eaten and picked to the bones
#     (`...-<kill|starved>-body-<meat share>.png`);
#   - a calf born beside a herbivore: the ring, the sparkles and the calf growing in
#     (`...-birth-<offset>.png`);
#   - a real chase, followed for a moment at normal speed and then paused, for the dust
#     (`...-chase.png`).
# Each staged series is frozen at several points after the event while the world stays
# paused, so its shots differ only in the effect.

const NOON := 120.0
const MIDNIGHT := 180.0
## The herbivore series come first: aiming at a predator moves the awake ground, and the
## herds near the middle may sleep after it.
const SERIES := [
	["dust", "herbivore", "dust", [0.05, 0.3]],
	["kill", "herbivore", "predation", [0.05, 0.12, 0.3, 0.55, 0.72, 0.9]],
	["birth", "herbivore", "birth", [0.04, 0.12, 0.25, 0.5]],
	["starved", "predator", "starvation", [0.05, 0.3, 0.55, 0.9]],
]

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
## The view-clock time the staged event started at, as the shots have moved it so far.
var _staged_start := 0.0
var _chase_started_msec := 0


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
			for series in SERIES:
				_steps.append(_aim_at_nearest.bind(series[1]))
				_steps.append(_stage.bind(series[2]))
				for offset in series[3]:
					_steps.append(_freeze.bind(offset))
					_steps.append(_save.bind("%s-%s-%.2f" % [moment[0], series[0], offset]))
				if series[0] in ["kill", "starved"]:
					# The body the fall left, whole, half eaten and picked to the bones.
					_steps.append(_freeze.bind(2.0))
					for share in [1.0, 0.5, 0.1]:
						_steps.append(_set_body_meat.bind(share))
						_steps.append(_save.bind("%s-%s-body-%.1f" % [moment[0], series[0], share]))
			_steps.append(_follow_chase)
			_steps.append(_stop_following)
			_steps.append(_save.bind("%s-chase" % moment[0]))
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


## The awake animal of `species` nearest the middle of the map, put in the middle of the view.
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


## Makes the event in the worker's world and runs one tick there, so it reaches the view in
## a frame, as an event in a tick does: a death of the aimed animal by `what`, or for
## "birth" a calf born beside it. Between ticks the worker drops events, so the ones this
## raises are put back in.
func _stage(what: String) -> int:
	var worker = _manager._worker
	var aimed = worker.world.get_agent(_aimed_id) if _aimed_id >= 0 else null
	if aimed == null:
		print("nothing to stage on")
		return 0
	# The last series is still frozen on the paused clock.
	_renderer._dying.clear()
	_renderer._effects.clear()
	_renderer._born.clear()
	if what == "dust":
		# Puff by puff, as a deer sprinting east would raise them: one per `dust_spacing`,
		# the newest at its hind feet.
		var now: float = _manager.get_display_time()
		var spacing: float = _renderer._effects.dust_spacing
		var sprint := 112.0
		for index in range(6):
			_renderer._effects.add_dust(aimed.position - Vector2(spacing * float(index) + 12.0, 0.0), Vector2.RIGHT,
				now - spacing * float(index) / sprint, aimed.id, index)
		_staged_start = now
		print("staged dust behind %d: %d marks" % [_aimed_id, _renderer._effects.queue.items().size()])
		return 0
	var heard: Array = []
	var listen := func(event: Dictionary) -> void: heard.append(event)
	worker.events.event_emitted.connect(listen)
	if what == "birth":
		worker.world.spawn_agent(aimed.species_type, aimed.position + Vector2(40.0, 18.0), aimed.group_id, "",
			{"reason": "reproduction"})
	else:
		worker.world.kill_agent(aimed, what)
	worker.events.event_emitted.disconnect(listen)
	var frame: Dictionary = worker.step(_manager.tick_duration, _manager.current_tick, _manager.simulation_time,
		_manager._build_lod_context(), _manager.selected_agent_id, false, false, _manager.ground_update_interval_ticks())
	frame["events"] = heard + frame["events"]
	_manager._apply_worker_frame(frame)
	_staged_start = float(heard[0].get("time_seconds", 0.0)) + _manager.tick_duration if not heard.is_empty() else 0.0
	print("staged %s on %d: %d dying sprites, %d marks" % [what, _aimed_id,
		_renderer.transient_sprites().size(), _renderer._effects.queue.items().size()])
	return 0


## Holds everything the staged event started `offset` seconds after it: the clock stands
## still while paused, so moving the starts back keeps them there.
func _freeze(offset: float) -> int:
	var shift: float = (_manager.get_display_time() - offset) - _staged_start
	_staged_start += shift
	for state in _renderer.transient_sprites():
		state["start"] = float(state["start"]) + shift
	for item in _renderer._effects.queue.items():
		item["start"] = float(item["start"]) + shift
	for id in _renderer._born.keys():
		_renderer._born[id] = float(_renderer._born[id]) + shift
	_renderer._effects._dirty = true
	_renderer._needs_refresh = true
	return 2500


## Leaves `share` of the staged body's meat on it, in the view's copy of the world only, for
## a shot of its stages while the world stands paused.
func _set_body_meat(share: float) -> int:
	for carcass in _manager.world_state.carcasses.values():
		if int(carcass.get("source_agent_id", -1)) == _aimed_id:
			carcass["meat_remaining"] = float(carcass.get("meat_total", 1.0)) * share
	_renderer._needs_refresh = true
	return 2500


## Runs the world, watching the hungriest awake predator, until an animal is running in a
## chase - the hunter or its prey - then follows it at normal speed for a moment so the dust
## is in the picture. Gives up after a minute of wall time and shoots whatever is there.
func _follow_chase() -> int:
	var elapsed := Time.get_ticks_msec() - _chase_started_msec
	if _chase_started_msec == 0:
		_chase_started_msec = Time.get_ticks_msec()
		elapsed = 0
		_manager.paused = false
		_manager.speed_multiplier = 2.0
		_aim_at_hungriest_predator()
	if _manager.selected_agent_id == -1:
		var runner = _running_in_chase()
		if runner != null:
			_manager.selected_agent_id = runner.id
			_manager.set_focus_mode("agent")
			_manager.speed_multiplier = 1.0
			_camera.zoom = Vector2(0.9, 0.9)
			_chase_started_msec = Time.get_ticks_msec()
			print("following %s %d (%s) at t=%.1f" % [runner.species_type, runner.id, runner.current_action,
				_manager.simulation_time])
			return -1
		if elapsed < 60000:
			# Another look every fifteen seconds: the one watched may have eaten.
			if elapsed > 0 and elapsed % 15000 < 20:
				_aim_at_hungriest_predator()
			return -1
	elif elapsed < 1200:
		return -1
	_manager.paused = true
	_manager.synchronize_worker()
	_chase_started_msec = 0
	return 0


func _aim_at_hungriest_predator() -> void:
	var hungriest = null
	for agent in _manager.world_state.get_living_agents():
		if agent.species_type == "predator" and (hungriest == null or agent.hunger > hungriest.hunger):
			hungriest = agent
	if hungriest != null:
		_aim(hungriest.position, 0.9)


func _running_in_chase():
	var dusty: Dictionary = _renderer._effects.dust_species
	var best = null
	for agent in _manager.world_state.get_living_agents():
		if not dusty.has(agent.species_type) or not _renderer._in_chase(agent):
			continue
		if float(_renderer._drawn_speed.get(agent.id, 0.0)) < 60.0:
			continue
		if best == null or agent.species_type == "predator":
			best = agent
	return best


## Pauses where the camera is and lets go of the animal, so neither the selection ring nor
## the card covers the dust.
func _stop_following() -> int:
	_manager.selected_agent_id = -1
	_manager.clear_focus()
	_manager.selection_changed.emit(-1)
	_renderer.queue_redraw()
	print("dust marks: %d" % _renderer._effects.queue.items().size())
	return 2500


func _save(name: String) -> int:
	var path := "%s-%s.png" % [_prefix, name]
	root.get_texture().get_image().save_png(path)
	var states: Array = _renderer.transient_sprites()
	var described := "no fall" if states.is_empty() else "frame %d alpha %.2f" % [int(states[0].frame), float(states[0].alpha)]
	print("saved %s at t=%.1f: %s, %d marks, carcasses drawn %s" % [path.get_file(), _manager.simulation_time, described,
		_renderer._effects.queue.items().size(), _renderer.scene_batch.last_counts.get("visible_carcasses", -1)])
	return 0


func _aim(world_position: Vector2, zoom: float) -> void:
	var terrain = _manager.world_state.terrain_system
	var level: int = 0 if terrain == null else terrain.get_height_at_position(world_position)
	_camera.global_position = WorldProjection.to_screen(world_position, level)
	_camera.zoom = Vector2(zoom, zoom)
	_camera.force_update_scroll()
