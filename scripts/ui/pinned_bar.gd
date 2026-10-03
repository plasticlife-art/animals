class_name PinnedBar
extends PanelContainer

## The animals the player pinned, under the bar at the top left, wherever they are: each by
## name and kind, with «вдали» while its sector sleeps and «погибла» (to a hunter) or
## «умерла» once it has died. A click sends the camera to it (`focus_requested`): selected
## and followed when it is awake, to where it sleeps or fell otherwise. Pinning is the
## animal's card's button (`StoryBook`, at most `StoryBook.MAX_PINS`); a right click here
## unpins.

signal focus_requested(agent_id: int)

const HudTextScript := preload("res://scripts/ui/hud_text.gd")

var story = null
var simulation_manager = null
var _allowed: bool = false
var _rows: VBoxContainer
var _buttons: Dictionary = {}
var _shown_pins: Array = []


func _init() -> void:
	var margin := MarginContainer.new()
	for side in ["left", "right"]:
		margin.add_theme_constant_override("margin_" + side, 6)
	for side in ["top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 4)
	add_child(margin)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 2)
	margin.add_child(box)
	var header := Label.new()
	header.text = "Закреплённые"
	header.modulate = Color(1.0, 1.0, 1.0, 0.7)
	box.add_child(header)
	_rows = VBoxContainer.new()
	_rows.add_theme_constant_override("separation", 2)
	box.add_child(_rows)


func bind(story_book, manager) -> void:
	story = story_book
	simulation_manager = manager
	if not story.pins_changed.is_connected(refresh):
		story.pins_changed.connect(refresh)
	if not manager.tick_completed.is_connected(_on_tick_completed):
		manager.tick_completed.connect(_on_tick_completed)
	refresh()


## False while the developer panel or a menu is up.
func set_allowed(value: bool) -> void:
	_allowed = value
	visible = _allowed and story != null and not story.pins.is_empty()


## Rows are rebuilt only when the pins change; between, their text is updated in place, so
## a row under the cursor is never swapped out from under a click.
func refresh() -> void:
	if story == null:
		visible = false
		return
	if _shown_pins != story.pins:
		for child in _rows.get_children():
			_rows.remove_child(child)
			child.queue_free()
		_buttons.clear()
		for agent_id in story.pins:
			var button := Button.new()
			button.flat = true
			button.alignment = HORIZONTAL_ALIGNMENT_LEFT
			button.tooltip_text = "Показать; правый клик - открепить"
			button.pressed.connect(func() -> void: focus_requested.emit(int(agent_id)))
			button.gui_input.connect(_on_row_input.bind(int(agent_id)))
			_rows.add_child(button)
			_buttons[int(agent_id)] = button
		_shown_pins = story.pins.duplicate()
	for agent_id in _buttons:
		_buttons[agent_id].text = row_text(story.pin_status(int(agent_id)))
	visible = _allowed and not story.pins.is_empty()


## «Ветка · олениха», «Ветка · олениха — вдали», «Ветка · олениха — погибла» / «— умерла».
static func row_text(status: Dictionary) -> String:
	var sex := str(status.get("sex", ""))
	var text := "%s · %s" % [status.get("name", ""), HudTextScript.animal_noun(str(status.get("species", "")), sex)]
	if bool(status.get("dead", false)):
		return "%s — %s" % [text, HudTextScript.died(sex, str(status.get("cause", "")))]
	if not bool(status.get("awake", false)):
		return "%s — вдали" % text
	return text


func _on_row_input(event: InputEvent, agent_id: int) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_RIGHT:
		story.unpin(agent_id)
		accept_event()


func _on_tick_completed(tick: int, _snapshot: Dictionary) -> void:
	if visible and simulation_manager != null and simulation_manager.should_refresh_ui_on_tick(tick):
		refresh()
