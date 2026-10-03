class_name EpitaphCard
extends PanelContainer

## A death worth remembering - a pinned animal's, the selected one's, a record holder's - on
## parchment at the top right, clear of the animal in the middle, for a few seconds: its epitaph (`Epitaph`), «Где это» to
## take the camera to where it died, «Родословная» to open its family in the chronicle. Several
## at once wait their turn; the countdown stops while the game is paused. Hidden by the start
## menu and in photo mode.

signal place_requested(position: Vector2)
signal family_requested(agent_id: int)

const SHOW_SECONDS := 10.0
const MAX_QUEUED := 6
const WIDTH := 460.0
const TITLE_INK := Color(0.20, 0.13, 0.08, 0.6)

var simulation_manager = null
## Whether «Родословная» has a chronicle to open.
var family_available: bool = false:
	set(value):
		family_available = value
		if _family_button != null:
			_family_button.visible = value
var _queue: Array = []
var _current: Dictionary = {}
var _left: float = 0.0
var _allowed: bool = true
var _title: Label
var _text: Label
var _family_button: Button


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
	var where := Button.new()
	where.text = "Где это"
	where.focus_mode = Control.FOCUS_NONE
	where.pressed.connect(func() -> void: place_requested.emit(_current.get("position", Vector2.INF)))
	row.add_child(where)
	_family_button = Button.new()
	_family_button.text = "Родословная"
	_family_button.focus_mode = Control.FOCUS_NONE
	_family_button.pressed.connect(func() -> void: family_requested.emit(int(_current.get("id", -1))))
	_family_button.visible = family_available
	row.add_child(_family_button)
	var close := Button.new()
	close.text = "Закрыть"
	close.focus_mode = Control.FOCUS_NONE
	close.pressed.connect(_next)
	row.add_child(close)


## Queues an epitaph; the oldest waiting one goes when too many wait.
func show_epitaph(agent_id: int, text: String, position: Vector2) -> void:
	_queue.append({"id": agent_id, "text": text, "position": position})
	while _queue.size() > MAX_QUEUED:
		_queue.pop_front()
	if _current.is_empty():
		_next()


func set_allowed(value: bool) -> void:
	_allowed = value
	visible = _allowed and not _current.is_empty()


func clear() -> void:
	_queue.clear()
	_current = {}
	visible = false


## What is on the card now: `{id, text, position}`, or empty.
func current() -> Dictionary:
	return _current


func waiting() -> int:
	return _queue.size()


func _process(delta: float) -> void:
	if _current.is_empty():
		return
	if simulation_manager != null and bool(simulation_manager.paused):
		return
	_left -= delta
	if _left <= 0.0:
		_next()


func _next() -> void:
	if _queue.is_empty():
		_current = {}
		visible = false
		return
	_current = _queue.pop_front()
	_title.text = "Памяти" + (" · ещё %d" % _queue.size() if not _queue.is_empty() else "")
	_text.text = str(_current["text"])
	_left = SHOW_SECONDS
	visible = _allowed
