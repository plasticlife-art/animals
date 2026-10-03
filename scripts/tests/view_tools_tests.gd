extends RefCounted

## Tools around the view: the player's settings, photo mode and its pictures, the wind in the
## props, the borders between biomes.

const Helpers := preload("res://scripts/tests/test_helpers.gd")
const SettingsStoreScript := preload("res://scripts/ui/settings_store.gd")
const SettingsPanelScript := preload("res://scripts/ui/settings_panel.gd")
const GameCameraScript := preload("res://scripts/ui/game_camera.gd")
const SceneSpriteBatchScript := preload("res://scripts/ui/scene_sprite_batch.gd")


func run(a) -> void:
	_test_settings_round_trip(a)
	_test_settings_panel(a)
	_test_ui_scale_keeps_the_map(a)
	_test_wind_sways_plants_only(a)


## Settings are written and read back; a scale not on offer snaps to the nearest, and with no
## file the defaults stand.
func _test_settings_round_trip(a) -> void:
	var path := "user://test_settings.cfg"
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	a.equal(SettingsStoreScript.load_settings(path), SettingsStoreScript.DEFAULTS, "no file, the defaults")
	a.is_true(SettingsStoreScript.save_settings({"fullscreen": true, "ui_scale": 1.3}, path), "written")
	a.equal(SettingsStoreScript.load_settings(path), {"fullscreen": true, "ui_scale": 1.25},
		"read back, the scale one on offer")
	a.equal(SettingsStoreScript.nearest_scale(0.5), 0.75, "below the smallest, the smallest")
	a.equal(SettingsStoreScript.scale_label(1.25), "125 %", "a scale in words")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


## Showing settings is not changing them; a press or a pick is, at once.
func _test_settings_panel(a) -> void:
	var panel = SettingsPanelScript.new()
	var heard: Array = []
	panel.changed.connect(func(values: Dictionary) -> void: heard.append(values))
	panel.show_settings({"fullscreen": false, "ui_scale": 1.0})
	a.equal(heard.size(), 0, "showing is not changing")
	panel._fullscreen.button_pressed = true
	a.equal(heard.back() if not heard.is_empty() else {}, {"fullscreen": true, "ui_scale": 1.0}, "full screen on")
	a.is_true(panel._fullscreen.text.ends_with("вкл"), "and the button says so")
	panel._scale.select(4)
	panel._scale.item_selected.emit(4)
	a.equal(float(heard.back()["ui_scale"]), 1.25, "a larger interface")
	panel.free()


## A larger interface leaves the map the size it was on screen: the camera zooms out by the
## same factor, and what the player chose stays what it was.
func _test_ui_scale_keeps_the_map(a) -> void:
	var root: Window = Engine.get_main_loop().root
	var camera = GameCameraScript.new()
	root.add_child(camera)
	camera.reset_to_world(Rect2(0.0, 0.0, 14400.0, 8100.0))
	var chosen: float = camera.zoom.x
	camera.set_ui_scale(1.25)
	a.is_true(is_equal_approx(camera.zoom.x, chosen / 1.25), "the camera zooms out by the interface's growth")
	a.is_true(is_equal_approx(camera.user_zoom(), chosen), "the player's zoom stays")
	camera.set_ui_scale(1.0)
	a.is_true(is_equal_approx(camera.zoom.x, chosen), "and comes back")
	root.remove_child(camera)
	camera.free()


## Each prop slot sways by its group's weight - trees, bushes, flowers - and stones, animals and
## bodies not at all; the Kenney style keeps its mossy rocks still; the overview stills it all.
func _test_wind_sways_plants_only(a) -> void:
	var props := {"groups": {"tree_large": [0, 1], "bush": [5], "stone": [22, 23]}}
	var weights: PackedFloat32Array = SceneSpriteBatchScript.sway_weights(props, {"tree_large": 0.6, "bush": 0.5,
		"stone": 0.0})
	a.equal(weights.size(), 64, "a weight for every slot")
	a.is_true(is_equal_approx(weights[0], 0.6) and is_equal_approx(weights[5], 0.5), "trees and bushes sway")
	a.is_true(weights[22] == 0.0 and weights[30] == 0.0, "stones and slots in no group keep still")
	var shader_code: String = load("res://shaders/scene_atlas.gdshader").code
	a.is_true(shader_code.contains("sway_weights") and shader_code.contains("MODEL_MATRIX")
		and shader_code.contains("UV.y"), "the shader shears by slot weight, pinned at the ground")
	var kenney: Dictionary = Helpers.ConfigLoaderScript.load_config_bundle({"style": "topdown_kenney"}).visuals.wind.weights
	a.is_true(float(kenney["swamp"]) == 0.0 and float(kenney["drought"]) < 0.3 and float(kenney["tree_large"]) > 0.0,
		"Kenney's mossy rocks keep still, its cacti barely move, its trees sway: %s" % str(kenney))
	var visuals: Dictionary = Helpers.ConfigLoaderScript.load_config_bundle().visuals
	var batch = SceneSpriteBatchScript.new()
	batch.configure(null, visuals)
	var mat := batch.material as ShaderMaterial
	a.is_true(bool(mat.get_shader_parameter("wind_enabled")), "on in the normal view")
	batch.set_wind_paused(true)
	a.is_true(not bool(mat.get_shader_parameter("wind_enabled")), "still in the overview")
	var off := visuals.duplicate(true)
	off["wind"]["enabled"] = false
	batch.configure(null, off)
	a.is_true(not bool(mat.get_shader_parameter("wind_enabled")) or not bool((batch.material as ShaderMaterial)
		.get_shader_parameter("wind_enabled")), "and off when the config says so")
	batch.free()
