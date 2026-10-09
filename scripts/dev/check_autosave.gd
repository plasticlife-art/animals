extends SceneTree

## End-to-end check of the setup screen, autosaving and resuming.
##
## `check_save.gd` exercises the save format directly; this one drives the real
## scene, so it covers the wiring that format check cannot see: that the setup
## screen starts a world, that autosaving actually fires from the tick signal,
## and that Continue reloads what was written.
##
## Two processes, because that is the scenario. Continue only loads a save when
## nothing is running yet - pressed during a game it just dismisses the screen -
## so resuming can only be tested by quitting and starting the app again.
##
##   Godot --script res://scripts/dev/check_autosave.gd -- write [scenario]
##   Godot --script res://scripts/dev/check_autosave.gd -- resume [scenario]
##
## With `scenario`, «Долгая сушь» is started from the start page instead, its brief closed, and
## the autosave must land in a scenario slot; resuming must bring the scenario back with its score
## and without its brief or a result. Write mode deletes every slot: keep a copy of the player's.

var _main: Node = null
var _frames := 0
var _phase := "boot"
var _saved_tick := -1


var _mode := "write"
var _scenario := false
var _saved_baseline := -1


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		_mode = str(args[0])
	_scenario = args.size() > 1 and str(args[1]) == "scenario"
	if _mode == "write":
		for path in SaveSystem.slot_paths():
			if FileAccess.file_exists(path):
				DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	else:
		_phase = "resume"
	root.size = Vector2i(1280, 720)
	_main = load("res://scenes/main/main.tscn").instantiate()
	root.add_child(_main)


func _process(_delta: float) -> bool:
	_frames += 1
	match _phase:
		"boot":
			if _frames < 10:
				return false
			var menu = _main.get_node_or_null("CanvasLayer/StartMenu")
			if menu == null or not menu.visible:
				print("FAIL setup screen did not appear on boot")
				quit(1)
				return true
			if _scenario:
				menu.scenario_requested.emit("long_drought", ConfigLoader.default_selection()["style"])
				if _main.result_window.mode() != "brief":
					print("FAIL the scenario opened without its brief")
					quit(1)
					return true
				_main.result_window.brief_closed.emit()
			else:
				menu.start_requested.emit(ConfigLoader.default_selection())
			_main.simulation_manager.set_speed_multiplier(10.0)
			_phase = "await_save"
		"await_save":
			var path := SaveSystem.latest_slot()
			if path != "":
				var header := SaveSystem.read(path)
				_saved_tick = int(header.get("tick", -1))
				if _scenario != path.get_file().begins_with("scenario_"):
					print("FAIL autosave went to %s" % path.get_file())
					quit(1)
					return true
				print("PASS autosave written at tick %d (%s)" % [_saved_tick, path.get_file()])
				quit(0)
				return true
			# The scenario's medium map steps slower than the sandbox's default world.
			if _frames > (7200 if _scenario else 1800):
				print("FAIL no autosave after %d frames (tick %d)"
					% [_frames, _main.simulation_manager.current_tick])
				quit(1)
				return true
		"resume":
			if _frames < 10:
				return false
			var path := SaveSystem.latest_slot()
			if path == "":
				print("FAIL no autosave to resume from")
				quit(1)
				return true
			var saved := SaveSystem.read(path)
			_saved_tick = int(saved.get("tick", -1))
			_saved_baseline = int(saved.get("scenario", {}).get("baseline", -1))
			var menu = _main.get_node_or_null("CanvasLayer/StartMenu")
			if menu == null or not menu.visible:
				print("FAIL setup screen did not appear on boot")
				quit(1)
				return true
			if not menu._continue_button.visible:
				print("FAIL Continue was not offered even though a save exists")
				quit(1)
				return true
			menu.continue_requested.emit()
			var tick: int = _main.simulation_manager.current_tick
			var living: int = _main.simulation_manager.world_state.get_living_agents().size()
			if tick != _saved_tick or living <= 0:
				print("FAIL resume: tick %d (save %d), %d live agents"
					% [tick, _saved_tick, living])
				quit(1)
				return true
			if _scenario:
				var score = _main.simulation_manager.scenario
				if not score.is_active() or score.baseline != _saved_baseline or _main.result_window.is_open():
					print("FAIL resume: scenario active %s, baseline %d (save %d), window %s"
						% [score.is_active(), score.baseline, _saved_baseline, _main.result_window.mode()])
					quit(1)
					return true
				print("PASS the scenario resumed with its score (baseline %d), no brief" % score.baseline)
			print("PASS resumed at tick %d with %d live agents" % [tick, living])
			quit(0)
			return true
	return false
