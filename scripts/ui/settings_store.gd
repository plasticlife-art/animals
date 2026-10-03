class_name SettingsStore
extends RefCounted

## The player's own settings, apart from the game's config: full screen and the size of the
## interface, in `user://settings.cfg`. Read and applied at startup, written whenever one
## changes. Volume waits until there is sound. Nothing here reaches the simulation.

const PATH := "user://settings.cfg"
## The interface sizes on offer; anything else read from the file snaps to the nearest. The HUD
## is laid out on a 1600x900 canvas, and at 150 % the selected animal's card alone fills the left
## column, so the largest is 125 %.
const UI_SCALES := [0.75, 0.9, 1.0, 1.1, 1.25]
const DEFAULTS := {"fullscreen": false, "ui_scale": 1.0}


static func load_settings(path: String = PATH) -> Dictionary:
	var settings := DEFAULTS.duplicate()
	var file := ConfigFile.new()
	if file.load(path) != OK:
		return settings
	settings["fullscreen"] = bool(file.get_value("display", "fullscreen", DEFAULTS["fullscreen"]))
	settings["ui_scale"] = nearest_scale(float(file.get_value("display", "ui_scale", DEFAULTS["ui_scale"])))
	return settings


static func save_settings(settings: Dictionary, path: String = PATH) -> bool:
	var file := ConfigFile.new()
	file.set_value("display", "fullscreen", bool(settings.get("fullscreen", DEFAULTS["fullscreen"])))
	file.set_value("display", "ui_scale", nearest_scale(float(settings.get("ui_scale", DEFAULTS["ui_scale"]))))
	return file.save(path) == OK


static func nearest_scale(value: float) -> float:
	var best: float = 1.0
	for scale in UI_SCALES:
		if absf(float(scale) - value) < absf(best - value):
			best = float(scale)
	return best


## «75 %», «100 %»…
static func scale_label(scale: float) -> String:
	return "%d %%" % int(round(scale * 100.0))


## Puts the settings on the window and the camera. The interface grows with the window's
## content scale, which scales the world as well, so the camera zooms out by the same factor
## and the map keeps its size on screen (`GameCamera.set_ui_scale()`).
static func apply(settings: Dictionary, window: Window, camera = null) -> void:
	if window == null:
		return
	var scale := nearest_scale(float(settings.get("ui_scale", 1.0)))
	var wanted := Window.MODE_FULLSCREEN if bool(settings.get("fullscreen", false)) else Window.MODE_WINDOWED
	if DisplayServer.get_name() != "headless" and window.mode != wanted \
			and not (wanted == Window.MODE_WINDOWED and window.mode == Window.MODE_MAXIMIZED):
		window.mode = wanted
	window.content_scale_factor = scale
	if camera != null and camera.has_method("set_ui_scale"):
		camera.set_ui_scale(scale)
