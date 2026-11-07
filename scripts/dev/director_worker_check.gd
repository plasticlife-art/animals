extends SceneTree

# The reserve's camera (`ReserveDirector`) as the game runs it: the world on the worker thread,
# the director reading the view's copy and hearing the frames' events. Not part of the game.
#
#   Godot --headless --path . --script res://scripts/dev/director_worker_check.gd -- <seed> <seconds> <out.json>
# No window, chats or saves: the manager with its worker, a stand-in camera as in
# `director_replay.gd`, real time at x1. Writes each caption with the scene's kind and when, and
# how many hunts, kills, pair hunts and alarms reached the director (`scene_event`).
const ReplayScript := preload("res://scripts/dev/director_replay.gd")

var _manager = null
var _director = null
var _camera = null
var _seconds := 0.0
var _out := ""
var _started := 0
var _captions: Array = []
var _heard := {}
var _promoted := 0
var _last_kind := ""


func _initialize() -> void:
	Engine.max_fps = 60
	var args := OS.get_cmdline_user_args()
	var run_seed := int(args[0])
	_seconds = float(args[1])
	_out = str(args[2])
	var reserve: Dictionary = ConfigLoader._load_json("res://data/config/reserve.json")
	var bundle: Dictionary = ConfigLoader.load_reserve_bundle(reserve)
	WorldProjection.configure(bundle.get("visuals", {}))
	_manager = preload("res://scripts/core/simulation_manager.gd").new()
	root.add_child(_manager)
	_manager.initialize(bundle, run_seed)
	_manager.set_lod_enabled(true)
	_manager.enable_interactive_worker()
	_camera = ReplayScript.ReplayCamera.new()
	_camera.bounds = _manager.world_state.bounds
	_camera.widest = _camera.zoom_to_fit(_manager.world_state.bounds)
	_camera.center = _manager.world_state.bounds.get_center()
	var session = preload("res://scripts/reserve/reserve_session.gd").new()
	session.configure(_manager, reserve)
	_director = preload("res://scripts/ui/reserve_director.gd").new()
	_director.configure(_manager, _camera, session, reserve)
	_director.caption_changed.connect(_on_caption)
	_manager.begin_interactive_stepping()
	_manager.scene_event.connect(func(event: Dictionary) -> void:
		var kind := str(event.get("type", ""))
		_heard[kind] = int(_heard.get(kind, 0)) + 1)
	_started = Time.get_ticks_msec()


func _process(delta: float) -> bool:
	if _manager == null:
		return false
	if not _director.is_moving():
		_manager.set_lod_view(WorldProjection.world_rect_covering(_camera.screen_rect()), _camera.center, false)
	_director.update()
	var kind := str(_director.scene.get("kind", ""))
	if _last_kind == "prowl" and kind == "hunt" and int(_director.scene.get("id", -1)) == int(_director.current_id):
		_promoted += 1
	_last_kind = kind
	if not _director.is_moving() and _manager.focus_mode != "off":
		var focus = _manager.get_focus_position()
		if focus != null:
			_camera.center = _camera.center.lerp(focus, clampf(7.5 * delta, 0.0, 1.0))
	if Time.get_ticks_msec() - _started < int(_seconds * 1000.0):
		return false
	var report := {"seconds": _seconds, "simulated": snappedf(float(_manager.simulation_time), 0.1), "heard": _heard,
		"prowls_become_hunts": _promoted, "captions": _captions}
	var file := FileAccess.open(_out, FileAccess.WRITE)
	file.store_string(JSON.stringify(report, "  "))
	file.close()
	print(JSON.stringify(report, "  "))
	_manager.shutdown()
	return true


func _on_caption(text: String, _seconds_shown: float) -> void:
	_captions.append([snappedf(float(_manager.simulation_time), 0.1), str(_director.scene.get("kind", "")), text])
