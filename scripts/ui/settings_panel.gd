class_name SettingsPanel
extends PanelContainer

## «Настройки», from the pause menu or the setup screen: full screen, and the size of the
## interface. Built from the themed buttons - the pixel theme styles buttons and option buttons,
## not check boxes or sliders. Every change applies at once and is written straight away
## (`changed`); «Готово» goes back to where it was opened from (`closed`).

signal changed(settings: Dictionary)
signal closed

const SettingsStoreScript := preload("res://scripts/ui/settings_store.gd")

var settings: Dictionary = SettingsStoreScript.DEFAULTS.duplicate()
var _fullscreen: Button
var _scale: OptionButton


func _init() -> void:
	visible = false
	mouse_filter = Control.MOUSE_FILTER_STOP
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 14)
	add_child(box)
	var title := Label.new()
	title.text = "Настройки"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(title)
	_fullscreen = Button.new()
	_fullscreen.toggle_mode = true
	_fullscreen.focus_mode = Control.FOCUS_NONE
	_fullscreen.toggled.connect(_on_fullscreen_toggled)
	box.add_child(_fullscreen)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	box.add_child(row)
	var label := Label.new()
	label.text = "Масштаб интерфейса"
	row.add_child(label)
	_scale = OptionButton.new()
	_scale.focus_mode = Control.FOCUS_NONE
	for scale in SettingsStoreScript.UI_SCALES:
		_scale.add_item(SettingsStoreScript.scale_label(float(scale)))
	_scale.item_selected.connect(_on_scale_selected)
	row.add_child(_scale)
	var hint := Label.new()
	hint.text = "F11 — полный экран в любой момент"
	hint.modulate = Color(1.0, 1.0, 1.0, 0.6)
	box.add_child(hint)
	var done := Button.new()
	done.text = "Готово"
	done.focus_mode = Control.FOCUS_NONE
	done.pressed.connect(func() -> void: closed.emit())
	box.add_child(done)
	show_settings(settings)


## Shows `values` without announcing them as a change.
func show_settings(values: Dictionary) -> void:
	settings = values.duplicate()
	_fullscreen.set_pressed_no_signal(bool(settings.get("fullscreen", false)))
	_fullscreen.text = "Полный экран: %s" % ("вкл" if bool(settings.get("fullscreen", false)) else "выкл")
	_scale.select(SettingsStoreScript.UI_SCALES.find(SettingsStoreScript.nearest_scale(float(settings.get("ui_scale", 1.0)))))


func _on_fullscreen_toggled(pressed: bool) -> void:
	settings["fullscreen"] = pressed
	_fullscreen.text = "Полный экран: %s" % ("вкл" if pressed else "выкл")
	changed.emit(settings.duplicate())


func _on_scale_selected(index: int) -> void:
	settings["ui_scale"] = float(SettingsStoreScript.UI_SCALES[clampi(index, 0, SettingsStoreScript.UI_SCALES.size() - 1)])
	changed.emit(settings.duplicate())
