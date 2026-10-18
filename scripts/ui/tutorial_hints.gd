class_name TutorialHints
extends PanelContainer

## A scenario's hints for a first game (`challenge.hints`, «Первая зима»), one at a time on
## parchment at the top of the screen under the species line: what to try next - choose a deer,
## follow it, speed time up, lead the herd to grass, open the feed. A hint goes once the player
## has done what it asks (`until`), or on «Понятно»; one that only tells (`until` "time") waits
## its `seconds`. One asking for what is already so - time already sped up - is skipped. The next
## comes after a short pause. What it is judged by comes from `MainController` every frame
## (`advance()`): the selected animal, whether the camera follows, the speed, the leads given and
## whether the feed is open - it reads no world of its own.

const WIDTH := 460.0
## The pause before the first hint and between two.
const GAP_SECONDS := 1.2
## What a hint can wait for besides «Понятно».
const UNTIL := ["select", "follow", "speed", "lead", "feed", "time"]

var hints: Array = []
## The hint shown or next to show; `hints.size()` once all are done.
var index: int = 0
var _showing: bool = false
var _gap: float = 0.0
var _shown_for: float = 0.0
var _start_facts: Dictionary = {}
var _counter: Label
var _text: Label


func _init() -> void:
	visible = false
	mouse_filter = Control.MOUSE_FILTER_STOP
	set_anchors_preset(Control.PRESET_CENTER_TOP)
	grow_horizontal = Control.GROW_DIRECTION_BOTH
	custom_minimum_size.x = WIDTH
	# Under the species line; `MainController._layout_hud()` keeps it there.
	offset_top = 150.0
	var margin := MarginContainer.new()
	for side in ["left", "right"]:
		margin.add_theme_constant_override("margin_" + side, 14)
	for side in ["top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 10)
	add_child(margin)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 6)
	margin.add_child(column)
	_counter = Label.new()
	_counter.add_theme_color_override("font_color", PixelUiTheme.INK_DIM)
	column.add_child(_counter)
	_text = Label.new()
	_text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_text.custom_minimum_size.x = WIDTH - 28.0
	column.add_child(_text)
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_END
	column.add_child(row)
	var understood := Button.new()
	understood.text = "Понятно"
	understood.focus_mode = Control.FOCUS_NONE
	understood.pressed.connect(next)
	row.add_child(understood)


## The hints of a scenario just started, the first after a pause; none clears them.
func start(hint_list: Array) -> void:
	hints = hint_list.duplicate(true)
	index = 0
	_showing = false
	_gap = GAP_SECONDS
	visible = false


func stop() -> void:
	start([])


func is_done() -> bool:
	return index >= hints.size()


## Moves the hints on by `delta` seconds with `facts` - `{selected, following, speed, leads,
## feed_open}` - and shows the current one while `allowed` (nothing over the game). Time under a
## menu or the result does not count.
func advance(facts: Dictionary, delta: float, allowed: bool) -> void:
	if is_done() or not allowed:
		visible = false
		return
	if not _showing:
		_gap -= delta
		if _gap > 0.0:
			visible = false
			return
		var hint: Dictionary = hints[index]
		# A hint asking for what is already so is passed over unseen.
		if str(hint.get("until", "")) != "time" and hint_done(hint, facts, facts, 0.0):
			index += 1
			return
		_showing = true
		_shown_for = 0.0
		_start_facts = facts.duplicate()
		_counter.text = "Подсказка %d из %d" % [index + 1, hints.size()]
		_text.text = str(hint.get("text", ""))
	visible = true
	_shown_for += delta
	if hint_done(hints[index], _start_facts, facts, _shown_for):
		next()


## The hint shown is done (or «Понятно»): the next after a pause.
func next() -> void:
	if is_done():
		return
	index += 1
	_showing = false
	_gap = GAP_SECONDS
	visible = false


func text() -> String:
	return _text.text if visible else ""


## Whether `hint` is done: what it asks for has happened since `start` (the facts when it came
## up) by `now`, or, for one that only tells, it has been up `seconds`.
static func hint_done(hint: Dictionary, start: Dictionary, now: Dictionary, shown_for: float) -> bool:
	match str(hint.get("until", "")):
		"select":
			return int(now.get("selected", -1)) >= 0 and int(now.get("selected", -1)) != int(start.get("selected", -1))
		"follow":
			return bool(now.get("following", false))
		"speed":
			return float(now.get("speed", 1.0)) > 1.0
		"lead":
			return int(now.get("leads", 0)) > int(start.get("leads", 0))
		"feed":
			return bool(now.get("feed_open", false))
		"time":
			return shown_for >= float(hint.get("seconds", 10.0))
	return false
