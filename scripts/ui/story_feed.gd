class_name StoryFeed
extends PanelContainer

## The event feed, above the minimap: the newest lines of the `StoryLog`, each with the
## time of day it happened. Lines about pinned animals stand out in gold, the minute's
## summary of the whole map is dimmer. A click takes the camera there (`line_clicked`): to
## the animal the line names while it lives - the hunter of a kill, the newborn of a birth -
## and otherwise to where it happened. Drawn dark like the season bar and the strip, so the
## readouts about the world read as one family; hidden by the start menu like the minimap.
## It grows upwards from its bottom edge, and keeps below a card standing over it in the right
## column (`fit_below()`): fewer rows, the newest kept. Folded by default to its title and the
## newest line - «События · ещё 6 ▾» - since seven lines took much of the right of the screen;
## a click on the title opens it or folds it.

signal line_clicked(line: Dictionary)

const MAX_ROWS := 7
## The rows shown while the feed is folded: the newest.
const FOLDED_ROWS := 1
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
## Every row (true), or the newest only (false).
var expanded: bool = false
var _rows: VBoxContainer
var _quiet: Label
var _header: HBoxContainer
var _title: Label
var _mark: FoldMark


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
	_header = HBoxContainer.new()
	_header.mouse_filter = Control.MOUSE_FILTER_STOP
	_header.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	_header.gui_input.connect(_on_header_input)
	box.add_child(_header)
	_title = _label("События", INK_DIM)
	_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_header.add_child(_title)
	_mark = FoldMark.new()
	_header.add_child(_mark)
	_update_header(0)
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


## Opens the feed to all its rows or folds it to the newest.
func set_expanded(value: bool) -> void:
	expanded = value
	refresh()


func refresh() -> void:
	for child in _rows.get_children():
		_rows.remove_child(child)
		child.queue_free()
	var lines: Array = [] if story_log == null else story_log.lines
	_quiet.visible = lines.is_empty()
	var shown := mini(MAX_ROWS if expanded else FOLDED_ROWS, lines.size())
	_update_header(mini(MAX_ROWS, lines.size()) - shown)
	for index in range(shown):
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


## Shows only as many of the newest rows as fit between `ceiling` - the lowest edge of a card in
## the right column, in the canvas's coordinates, or 0 with none - and the feed's bottom edge,
## so a season card or an epitaph never has the feed running on under it. The newest stay at
## the top, the oldest go first; the feed's bottom is anchored, so its top comes down.
func fit_below(ceiling: float) -> void:
	var rows: Array = _rows.get_children()
	if rows.is_empty():
		return
	var room := INF if ceiling <= 0.0 else get_global_rect().end.y - ceiling
	# What the panel holds besides its rows: margins, the title and the gaps.
	var used := get_combined_minimum_size().y - _rows.get_combined_minimum_size().y
	var separation := float(_rows.get_theme_constant("separation"))
	var full := false
	for row in rows:
		var height: float = row.get_combined_minimum_size().y
		var fits := not full and used + height <= room
		full = not fits
		if row.visible != fits:
			row.visible = fits
		if fits:
			used += height + separation


func shown_rows() -> int:
	var count := 0
	for row in _rows.get_children():
		if row.visible:
			count += 1
	return count


## «События», «События · ещё 6» while folded over more, and the mark that opens or folds it.
func _update_header(hidden: int) -> void:
	_title.text = "События · ещё %d" % hidden if hidden > 0 else "События"
	_mark.open = expanded
	_mark.queue_redraw()
	_header.tooltip_text = "Щёлкните, чтобы свернуть" if expanded else "Щёлкните, чтобы показать все события"


func _on_header_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		set_expanded(not expanded)
		accept_event()


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


## ▾ where the feed opens, ▴ where it folds.
class FoldMark:
	extends Control

	const SIDE := 8.0

	var open: bool = false

	func _init() -> void:
		custom_minimum_size = Vector2(SIDE + 4.0, SIDE)
		size_flags_vertical = Control.SIZE_SHRINK_CENTER
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _draw() -> void:
		var centre := size * 0.5
		var half := SIDE * 0.5
		var tip := -half * 0.6 if open else half * 0.6
		draw_colored_polygon(PackedVector2Array([centre + Vector2(-half, -tip), centre + Vector2(half, -tip),
			centre + Vector2(0.0, tip)]), StoryFeed.INK_DIM)
