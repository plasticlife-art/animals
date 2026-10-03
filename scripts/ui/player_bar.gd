class_name PlayerBar
extends PanelContainer

## The controls a player needs, at the top left during play, in Russian: pause, the game
## speeds, three of the map's layers - the grass, where predators have struck, who is
## chasing whom - and the help screen. Everything else - stepping, LOD, export, the other
## layers, the AI inspector - lives in the developer panel, which only developer mode
## shows (`debug.developer_mode`, F12 at runtime, then Tab); this bar steps aside while it
## is up, since the panel has the same controls.
##
## Built in code, like the herd card, so the scene holds one node. The bar only reports
## what was pressed; `MainController` applies it and keeps it in step with the panel.

signal pause_toggled(is_paused: bool)
signal speed_selected(multiplier: float)
signal overlay_toggled(flag_name: String, enabled: bool)
signal help_requested

## The layers a player gets, as [debug flag, label, tooltip].
const OVERLAYS := [
	["show_grass_density", "Трава", "Сколько травы в каждой клетке"],
	["show_fear", "Угроза", "Где хищники недавно охотились - травоядные обходят эти места"],
	["show_chase_lines", "Погони", "Кто за кем гонится прямо сейчас"],
]

var _pause: Button
var _speed_row: HBoxContainer
var _speeds: Array = []
var _speed_group := ButtonGroup.new()
var _overlays: Dictionary = {}


func _init() -> void:
	var margin := MarginContainer.new()
	for side in ["left", "right"]:
		margin.add_theme_constant_override("margin_" + side, 6)
	for side in ["top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 2)
	add_child(margin)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	margin.add_child(row)
	_pause = Button.new()
	_pause.toggle_mode = true
	_pause.text = "Пауза"
	_pause.tooltip_text = "Остановить и продолжить время"
	_pause.toggled.connect(func(pressed: bool) -> void: pause_toggled.emit(pressed))
	row.add_child(_pause)
	row.add_child(VSeparator.new())
	_speed_row = HBoxContainer.new()
	_speed_row.add_theme_constant_override("separation", 2)
	row.add_child(_speed_row)
	row.add_child(VSeparator.new())
	for overlay in OVERLAYS:
		var toggle := Button.new()
		toggle.toggle_mode = true
		toggle.text = str(overlay[1])
		toggle.tooltip_text = str(overlay[2])
		toggle.toggled.connect(_on_overlay_toggled.bind(str(overlay[0])))
		row.add_child(toggle)
		_overlays[str(overlay[0])] = toggle
	row.add_child(VSeparator.new())
	var help := Button.new()
	help.text = "?"
	help.tooltip_text = "Справка (F1)"
	help.pressed.connect(func() -> void: help_requested.emit())
	row.add_child(help)


## One button per speed in `debug.speed_steps`, `current` pressed; the layers as `flags` has
## them.
func configure(speed_steps: Array, current: float, flags: Dictionary) -> void:
	for entry in _speeds:
		entry["button"].queue_free()
	_speeds.clear()
	for step in speed_steps:
		var multiplier := float(step)
		var button := Button.new()
		button.toggle_mode = true
		button.button_group = _speed_group
		button.text = "x%s" % str(multiplier).trim_suffix(".0")
		button.tooltip_text = "Скорость времени"
		button.pressed.connect(func() -> void: speed_selected.emit(multiplier))
		_speed_row.add_child(button)
		_speeds.append({"button": button, "multiplier": multiplier})
	set_speed(current)
	for flag_name in _overlays:
		set_overlay_state(flag_name, bool(flags.get(flag_name, false)))


func set_paused_state(paused: bool) -> void:
	_pause.set_pressed_no_signal(paused)
	_pause.text = "Пуск" if paused else "Пауза"


func set_speed(multiplier: float) -> void:
	for entry in _speeds:
		entry["button"].set_pressed_no_signal(is_equal_approx(float(entry["multiplier"]), multiplier))


func set_overlay_state(flag_name: String, enabled: bool) -> void:
	if _overlays.has(flag_name):
		_overlays[flag_name].set_pressed_no_signal(enabled)


## The layers this bar switches, for the controller to keep in step.
func overlay_flags() -> Array:
	return _overlays.keys()


func _on_overlay_toggled(pressed: bool, flag_name: String) -> void:
	overlay_toggled.emit(flag_name, pressed)
