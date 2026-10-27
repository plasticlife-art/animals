class_name SeasonCard
extends PanelContainer

## The season just over, on parchment at the right under the ecology strip, for a few seconds:
## «Итоги лета · год 2 · засуха», the numbers, the young, the dead, the best hunter and the ponds
## that dried (`SeasonReport`). «Летопись» opens every season in the chronicle («Сезоны»),
## «Закрыть» puts the card away. A new season's card replaces the old one; the countdown stops
## while the game is paused. Hidden by the start menu, by the developer panels (the charts stand
## where it does) and in photo mode.

signal chronicle_requested

const SeasonReportScript := preload("res://scripts/story/season_report.gd")
const SHOW_SECONDS := 8.0
const WIDTH := 460.0
const TITLE_INK := Color(0.20, 0.13, 0.08, 0.6)

var simulation_manager = null
var _summary: Dictionary = {}
var _left: float = 0.0
var _allowed: bool = true
## Held back, its countdown stopped, while a window stands over its place (`set_covered`).
var _covered: bool = false
var _title: Label
var _text: Label


func _init() -> void:
	visible = false
	mouse_filter = Control.MOUSE_FILTER_STOP
	custom_minimum_size.x = WIDTH
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	add_child(box)
	_title = Label.new()
	_title.add_theme_color_override("font_color", TITLE_INK)
	box.add_child(_title)
	_text = Label.new()
	_text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_text.custom_minimum_size.x = WIDTH - 40.0
	box.add_child(_text)
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_END
	row.add_theme_constant_override("separation", 8)
	box.add_child(row)
	var chronicle := Button.new()
	chronicle.text = "Летопись"
	chronicle.focus_mode = Control.FOCUS_NONE
	chronicle.pressed.connect(_on_chronicle)
	row.add_child(chronicle)
	var close := Button.new()
	close.text = "Закрыть"
	close.focus_mode = Control.FOCUS_NONE
	close.pressed.connect(clear)
	row.add_child(close)


## Shows a season's summary (`SeasonLedger.close()`) in place of whatever was on the card.
func show_season(summary: Dictionary) -> void:
	_summary = summary
	_title.text = SeasonReportScript.title(summary)
	_text.text = SeasonReportScript.text(summary)
	_left = SHOW_SECONDS
	visible = _allowed and not _covered


func set_allowed(value: bool) -> void:
	_allowed = value
	visible = _allowed and not _covered and not _summary.is_empty()


## While the chronicle is open over the right column the card waits, as an epitaph does there.
func set_covered(value: bool) -> void:
	if _covered == value:
		return
	_covered = value
	visible = _allowed and not _covered and not _summary.is_empty()


func clear() -> void:
	_summary = {}
	visible = false


## The season on the card now, or empty.
func current() -> Dictionary:
	return _summary


func text() -> String:
	return "" if _summary.is_empty() else "%s\n%s" % [_title.text, _text.text]


func _process(delta: float) -> void:
	if _summary.is_empty():
		return
	if _covered or (simulation_manager != null and bool(simulation_manager.paused)):
		return
	_left -= delta
	if _left <= 0.0:
		clear()


func _on_chronicle() -> void:
	clear()
	chronicle_requested.emit()
