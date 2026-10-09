class_name PowersBar
extends PanelContainer

## The player's powers at the bottom centre during play: «Водопой» (Q) and «Повести стадо» (E),
## each with the charges left («×1») and, while it cools down, the seconds to wait; a power spent
## or cooling is greyed. Above them a line tells how to aim, or why the last try would not do
## (`PowerAim.message`). Its state is the world's (`PlayerState`, from the worker's frames).
##
## Built in code, like the player bar; it only reports what was pressed, and `MainController`
## aims the power. Up with the player bar - not under menus, help or the developer panels - and
## only in a world with powers.

signal power_pressed(power: String)

const DESCRIPTIONS := {
	"dig_pond": "Выкопать водопой там, где щёлкнете: пруд размером со средний на этой карте. "
		+ "Нельзя у края карты, на скалах, вплотную к другому пруду и среди деревьев или камней.",
	"lead_herd": "Повести стадо выбранного оленя туда, где щёлкнете, если путь туда есть и он не слишком далёк. "
		+ "Олени идут, пока не дойдут или не пройдёт пять минут; проголодавшиеся отходят поесть.",
}

var _buttons: Dictionary = {}
var _message: Label


func _init() -> void:
	visible = false
	var margin := MarginContainer.new()
	for side in ["left", "right"]:
		margin.add_theme_constant_override("margin_" + side, 6)
	for side in ["top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 2)
	add_child(margin)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 2)
	margin.add_child(column)
	_message = Label.new()
	_message.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_message.visible = false
	column.add_child(_message)
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 6)
	column.add_child(row)
	for power in PowerAim.POWERS:
		var button := Button.new()
		button.toggle_mode = true
		button.focus_mode = Control.FOCUS_NONE
		button.tooltip_text = "%s (%s)\n%s" % [PowerAim.LABELS[power], PowerAim.KEYS[power], DESCRIPTIONS[power]]
		button.pressed.connect(func() -> void: power_pressed.emit(power))
		row.add_child(button)
		_buttons[power] = button


## The buttons as `player` has the powers at `now`; `armed` pressed, `message` above them.
func refresh(player, now: float, armed: String, message: String) -> void:
	for power in _buttons:
		var entry: Dictionary = player.budget.get(power, {}) if player != null else {}
		var button: Button = _buttons[power]
		button.visible = not entry.is_empty()
		var charges := int(entry.get("charges", -1))
		var left := maxf(0.0, float(entry.get("cooldown_until", 0.0)) - now)
		button.text = button_text(str(power), charges, left)
		button.disabled = charges == 0 or left > 0.0
		button.set_pressed_no_signal(armed == power)
	_message.text = message
	_message.visible = message != ""


## «Водопой (Q) ×1», «Повести стадо (E) ×2 · 42 с»: the charges when they are counted, the wait
## while it cools down.
static func button_text(power: String, charges: int, cooldown_left: float) -> String:
	var text := "%s (%s)" % [PowerAim.LABELS.get(power, power), PowerAim.KEYS.get(power, "")]
	if charges >= 0:
		text += " ×%d" % charges
	if cooldown_left > 0.0 and charges != 0:
		text += " · %d с" % ceili(cooldown_left)
	return text


## Whether `player` has any power to show.
static func has_powers(player) -> bool:
	if player == null:
		return false
	for power in PowerAim.POWERS:
		if player.budget.has(power):
			return true
	return false


func button(power: String) -> Button:
	return _buttons.get(power)


func message_text() -> String:
	return _message.text if _message.visible else ""
