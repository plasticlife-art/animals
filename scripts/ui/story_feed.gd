class_name StoryFeed
extends PanelContainer

## The event feed, above the minimap: the newest lines of the `StoryLog`, each with the
## time of day it happened. Lines about pinned animals stand out in gold, the minute's
## summary of the whole map is dimmer. A click takes the camera there (`line_clicked`): to
## the animal the line names while it lives - the hunter of a kill, the newborn of a birth -
## and otherwise to where it happened. Drawn dark like the season bar and the strip, so the
## readouts about the world read as one family; hidden by the start menu like the minimap.

signal line_clicked(line: Dictionary)

const MAX_ROWS := 7
const ROW_WIDTH := 336.0
const FONT_SIZE := 14
const BACKDROP := Color(0.06, 0.07, 0.08, 0.82)
const BORDER := Color(0.22, 0.24, 0.26)
const INK := Color(0.88, 0.9, 0.92)
const INK_DIM := Color(0.88, 0.9, 0.92, 0.6)
const PINNED_INK := Color(0.98, 0.84, 0.46)
const HOVER := Color(1.15, 1.15, 1.15, 1.0)

var story_log = null
var simulation_manager = null
var _rows: VBoxContainer
var _quiet: Label


func _init() -> void:
	var style := StyleBoxFlat.new()
	style.bg_color = BACKDROP
	style.border_color = BORDER
	style.set_border_width_all(1)
	style.set_content_margin_all(8.0)
	add_theme_stylebox_override("panel", style)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 4)
	add_child(box)
	box.add_child(_label("События", INK_DIM))
	_rows = VBoxContainer.new()
	_rows.add_theme_constant_override("separation", 3)
	box.add_child(_rows)
	_quiet = _label("Пока тихо", INK_DIM)
	box.add_child(_quiet)


func bind(feed_log, manager) -> void:
	story_log = feed_log
	simulation_manager = manager
	if not story_log.changed.is_connected(refresh):
		story_log.changed.connect(refresh)
	refresh()


func refresh() -> void:
	for child in _rows.get_children():
		_rows.remove_child(child)
		child.queue_free()
	var lines: Array = [] if story_log == null else story_log.lines
	_quiet.visible = lines.is_empty()
	for index in range(mini(MAX_ROWS, lines.size())):
		var line: Dictionary = lines[index]
		var colour := INK
		if bool(line.get("pinned", false)):
			colour = PINNED_INK
		elif str(line.get("kind", "")) == "summary":
			colour = INK_DIM
		var row := _label("%s  %s" % [clock_text(float(line.get("time", 0.0))), str(line.get("text", ""))], colour)
		row.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		row.custom_minimum_size.x = ROW_WIDTH
		row.mouse_filter = Control.MOUSE_FILTER_STOP
		row.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		row.tooltip_text = "Показать"
		row.gui_input.connect(_on_row_input.bind(line))
		row.mouse_entered.connect(func() -> void: row.modulate = HOVER)
		row.mouse_exited.connect(func() -> void: row.modulate = Color.WHITE)
		_rows.add_child(row)


## The time of day an event happened, «06:40», by the world's clock.
func clock_text(time: float) -> String:
	var climate: Dictionary = {} if simulation_manager == null \
		else simulation_manager.config_bundle.get("world", {}).get("climate", {})
	var phase := float(Climate.evaluate(climate, time).get("day_phase", 0.5))
	var minutes := int(round(phase * 1440.0)) % 1440
	@warning_ignore("integer_division")
	return "%02d:%02d" % [minutes / 60, minutes % 60]


func _on_row_input(event: InputEvent, line: Dictionary) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		line_clicked.emit(line)
		accept_event()


static func _label(text: String, colour: Color) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_color_override("font_color", colour)
	label.add_theme_font_size_override("font_size", FONT_SIZE)
	return label
