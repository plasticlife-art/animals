extends SceneTree

# Photo mode end to end in a window: starts the default world, enters photo mode, saves a PNG,
# films the ten-second GIF and reports how the frame rate held while recording.
#
#   Godot --path . --script res://scripts/dev/photo_check.gd -- <out_folder>

var _main: Node = null
var _frames := 0
var _phase := ""
var _deltas: Array = []
var _last_usec := 0
var _folder := ""
var _result := {}


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	_folder = args[0] if not args.is_empty() else ProjectSettings.globalize_path("user://photo_check")
	DirAccess.make_dir_recursive_absolute(_folder)
	root.size = Vector2i(1600, 900)
	_main = load("res://scenes/main/main.tscn").instantiate()
	root.add_child(_main)


func _process(_delta: float) -> bool:
	_frames += 1
	var now := Time.get_ticks_usec()
	if _frames == 10:
		var menu = _main.get_node("CanvasLayer/StartMenu")
		menu.start_requested.emit(ConfigLoader.default_selection())
	if _frames == 200:
		DisplayServer.window_move_to_foreground()
		_main.photo_mode.folder_override = _folder
		_main.photo_mode.enter()
		_main.photo_mode.take_photo()
	if _frames == 260:
		_main.photo_mode.start_gif()
		_phase = "recording"
		_last_usec = now
	if _phase == "recording":
		_deltas.append(float(now - _last_usec) / 1000.0)
		_last_usec = now
		var recorder = _main.photo_mode._recorder
		if recorder == null:
			_phase = "done"
		elif not recorder.is_recording() and _result.is_empty():
			_result["captured"] = recorder.captured
	if _phase == "done":
		var files := DirAccess.get_files_at(_folder)
		var mean := 0.0
		var worst := 0.0
		for d in _deltas:
			mean += d
			worst = maxf(worst, d)
		mean /= maxf(1.0, float(_deltas.size()))
		print("PHOTO_CHECK files=%s captured=%s frames=%d mean_ms=%.1f worst_ms=%.1f status=%s" % [str(files),
			str(_result.get("captured", "?")), _deltas.size(), mean, worst, _main.photo_mode._status.text])
		return true
	return false
