class_name ChronicleWindow
extends PanelContainer

## «Летопись»: the world's story in one window over the map - an animal's family three
## generations deep (`FamilyTree`), and the records (`StoryRecords`). The world keeps running
## behind it and the camera can still move. A click on a relative centres the tree on it and
## sends the camera there (`focus_requested`); «Назад» walks back through the relatives
## visited; a click on a record opens that animal's family. Esc or «Закрыть» closes it.

signal focus_requested(agent_id: int)
signal closed

const FamilyTreeScript := preload("res://scripts/story/family_tree.gd")
const StoryRecordsScript := preload("res://scripts/story/story_records.gd")
const REFRESH_SECONDS := 1.5
const BODY_SIZE := Vector2(760.0, 440.0)
const TABS := {"family": "Родословная", "records": "Рекорды"}

var story = null
var simulation_manager = null
var _tab := "family"
var _focus_id := -1
var _history: Array = []
var _tabs: Dictionary = {}
var _tree: TreeView
var _records_scroll: ScrollContainer
var _records_box: VBoxContainer
var _back: Button
var _empty: Label
var _refresh_left := 0.0


func _init() -> void:
	visible = false
	mouse_filter = Control.MOUSE_FILTER_STOP
	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 8)
	add_child(root)
	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 8)
	root.add_child(header)
	var title := Label.new()
	title.text = "Летопись"
	title.add_theme_font_size_override("font_size", 20)
	header.add_child(title)
	var spacer := Control.new()
	spacer.custom_minimum_size.x = 16.0
	header.add_child(spacer)
	var group := ButtonGroup.new()
	for tab in TABS.keys():
		var button := Button.new()
		button.text = TABS[tab]
		button.toggle_mode = true
		button.button_group = group
		button.focus_mode = Control.FOCUS_NONE
		button.pressed.connect(show_tab.bind(tab))
		header.add_child(button)
		_tabs[tab] = button
	var fill := Control.new()
	fill.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(fill)
	_back = Button.new()
	_back.text = "Назад"
	_back.focus_mode = Control.FOCUS_NONE
	_back.pressed.connect(go_back)
	header.add_child(_back)
	var close := Button.new()
	close.text = "Закрыть"
	close.focus_mode = Control.FOCUS_NONE
	close.pressed.connect(close_window)
	header.add_child(close)
	_tree = TreeView.new()
	_tree.custom_minimum_size = BODY_SIZE
	_tree.picked.connect(_on_relative_picked)
	root.add_child(_tree)
	_records_scroll = ScrollContainer.new()
	_records_scroll.custom_minimum_size = BODY_SIZE
	_records_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	root.add_child(_records_scroll)
	_records_box = VBoxContainer.new()
	_records_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_records_box.add_theme_constant_override("separation", 4)
	_records_scroll.add_child(_records_box)
	_empty = Label.new()
	_empty.text = "Выберите животное на карте или в списке закреплённых, чтобы увидеть его семью."
	_empty.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_empty.custom_minimum_size.x = BODY_SIZE.x
	root.add_child(_empty)


func bind(story_book, manager) -> void:
	story = story_book
	simulation_manager = manager
	_tree.story = story_book


## Opens on an animal's family, or on `tab`; with no animal, the one already shown, if any.
func open(agent_id := -1, tab := "family") -> void:
	if agent_id >= 0 and agent_id != _focus_id:
		_history.clear()
		_focus_id = agent_id
	visible = true
	show_tab(tab)


## A new world: nobody's family shown yet.
func reset() -> void:
	_history.clear()
	_focus_id = -1
	close_window()


func close_window() -> void:
	if not visible:
		return
	visible = false
	closed.emit()


func show_tab(tab: String) -> void:
	_tab = tab if TABS.has(tab) else "family"
	for name in _tabs.keys():
		_tabs[name].set_pressed_no_signal(name == _tab)
	refresh()


## Back to the relative visited before this one.
func go_back() -> void:
	if _history.is_empty():
		return
	_focus_id = int(_history.pop_back())
	refresh()
	focus_requested.emit(_focus_id)


func focus_id() -> int:
	return _focus_id


func refresh() -> void:
	_refresh_left = REFRESH_SECONDS
	var family := _tab == "family"
	_tree.visible = family and _focus_id >= 0
	_empty.visible = family and _focus_id < 0
	_records_scroll.visible = not family
	_back.visible = family and not _history.is_empty()
	if story == null:
		return
	if family and _focus_id >= 0:
		_tree.show_family(FamilyTreeScript.around(story, _focus_id), _now(), _calendar())
	elif not family:
		_fill_records()


func _process(delta: float) -> void:
	if not visible:
		return
	_refresh_left -= delta
	if _refresh_left <= 0.0:
		refresh()


func _on_relative_picked(agent_id: int) -> void:
	if agent_id < 0 or agent_id == _focus_id:
		if agent_id >= 0:
			focus_requested.emit(agent_id)
		return
	if _focus_id >= 0:
		_history.append(_focus_id)
	_focus_id = agent_id
	refresh()
	focus_requested.emit(agent_id)


func _fill_records() -> void:
	for child in _records_box.get_children():
		_records_box.remove_child(child)
		child.queue_free()
	var rows: Dictionary = StoryRecordsScript.all(story, _now())
	var any := false
	for kind in StoryRecordsScript.KINDS:
		var title := Label.new()
		title.text = str(StoryRecordsScript.TITLES[kind])
		title.add_theme_font_size_override("font_size", 17)
		_records_box.add_child(title)
		var listed: Array = rows.get(kind, [])
		if listed.is_empty():
			var none := Label.new()
			none.text = "    пока никого"
			none.modulate = Color(1.0, 1.0, 1.0, 0.55)
			_records_box.add_child(none)
		for row in listed:
			any = true
			var button := Button.new()
			button.text = record_text(row, kind, _calendar())
			button.alignment = HORIZONTAL_ALIGNMENT_LEFT
			button.flat = true
			button.focus_mode = Control.FOCUS_NONE
			button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
			button.pressed.connect(_open_record.bind(int(row["id"])))
			_records_box.add_child(button)
	if not any:
		var quiet := Label.new()
		quiet.text = "Рекордов пока нет: мир только начался."
		_records_box.add_child(quiet)


func _open_record(agent_id: int) -> void:
	_history.clear()
	_focus_id = agent_id
	show_tab("family")
	focus_requested.emit(agent_id)


## «Ветка · олениха — 2 года и 1 сезон», «Рыжик · лис † — добыча: 14».
static func record_text(row: Dictionary, kind: String, calendar: Array = [120.0, 4]) -> String:
	var sex := str(row.get("sex", ""))
	var who := "%s · %s%s" % [row.get("name", ""), HudText.animal_noun(str(row.get("species", "")), sex),
		" †" if bool(row.get("dead", false)) else ""]
	var value := float(row.get("value", 0.0))
	var what := ""
	match kind:
		"oldest", "longest":
			what = HudText.age_text(value, calendar)
		"family":
			what = "%d %s" % [int(value), HudText.plural(int(value), ["живой потомок", "живых потомка", "живых потомков"])]
		"hunters":
			what = "добыча: %d" % int(value)
	return "%s — %s" % [who, what]


func _now() -> float:
	return 0.0 if simulation_manager == null else float(simulation_manager.simulation_time)


func _calendar() -> Array:
	if simulation_manager == null:
		return [120.0, 4]
	return Climate.calendar(simulation_manager.config_bundle.get("world", {}).get("climate", {}))


## The family drawn as boxes and lines: grandparents, parents, the animal, its children.
class TreeView:
	extends Control

	signal picked(agent_id: int)

	const INK := Color(0.20, 0.13, 0.08)
	const INK_DIM := Color(0.20, 0.13, 0.08, 0.5)
	const BOX_FILL := Color(0.20, 0.13, 0.08, 0.07)
	const BOX_HOVER := Color(0.20, 0.13, 0.08, 0.16)
	const PINNED := Color(0.78, 0.55, 0.12)
	const BOX := Vector2(168.0, 54.0)
	const CHILD_BOX := Vector2(160.0, 50.0)

	var story = null
	var _family: Dictionary = {}
	var _cards: Dictionary = {}
	var _boxes: Array = []
	var _hover := -2

	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_STOP

	func show_family(family: Dictionary, now: float, calendar: Array) -> void:
		_family = family
		_cards.clear()
		var ids: Array = [int(family.get("focus", -1))] + family.get("parents", []) + family.get("grandparents", []) \
			+ family.get("children", [])
		for agent_id in ids:
			_cards[int(agent_id)] = FamilyTree.card(story, int(agent_id), now, calendar)
		queue_redraw()

	func _gui_input(event: InputEvent) -> void:
		if event is InputEventMouseMotion:
			var over := _box_at(event.position)
			if over != _hover:
				_hover = over
				mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND if over >= 0 else Control.CURSOR_ARROW
				queue_redraw()
		elif event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
			var hit := _box_at(event.position)
			if hit >= 0:
				picked.emit(hit)
				accept_event()

	func _box_at(point: Vector2) -> int:
		for box in _boxes:
			if (box[0] as Rect2).has_point(point) and bool(_cards.get(int(box[1]), {}).get("known", false)):
				return int(box[1])
		return -1

	func _draw() -> void:
		_boxes.clear()
		if _family.is_empty():
			return
		var w := size.x
		var h := size.y
		var rows := [h * 0.1, h * 0.33, h * 0.56, h * 0.79]
		var grand: Array = _family.get("grandparents", [-1, -1, -1, -1])
		var parents: Array = _family.get("parents", [-1, -1])
		var focus := int(_family.get("focus", -1))
		var children: Array = _family.get("children", [])
		var parent_x := [w * 0.27, w * 0.73]
		var grand_x := [w * 0.13, w * 0.39, w * 0.61, w * 0.87]
		var font := get_theme_default_font()
		var any_parent := _known(int(parents[0])) or _known(int(parents[1]))
		# Nobody known above - a founder - says so once instead of six empty boxes.
		if not any_parent:
			var note := "основатель: родители неизвестны"
			var width := font.get_string_size(note, HORIZONTAL_ALIGNMENT_LEFT, -1, 13).x
			draw_string(font, Vector2(w * 0.5 - width * 0.5, rows[1]), note, HORIZONTAL_ALIGNMENT_LEFT, -1, 13, INK_DIM)
		else:
			var labels := ["родители матери", "родители отца"]
			for side in range(2):
				_line(Vector2(parent_x[side], rows[1] + BOX.y * 0.5), Vector2(w * 0.5, rows[2] - BOX.y * 0.5))
				# A pair of grandparents is drawn when either of them is known.
				if _known(int(grand[side * 2])) or _known(int(grand[side * 2 + 1])):
					for index in [side * 2, side * 2 + 1]:
						_line(Vector2(grand_x[index], rows[0] + BOX.y * 0.5), Vector2(parent_x[side], rows[1] - BOX.y * 0.5))
						_box(Vector2(grand_x[index], rows[0]), BOX, int(grand[index]))
					draw_string(font, Vector2(parent_x[side] - 52.0, rows[0] - BOX.y * 0.5 - 6.0), labels[side],
						HORIZONTAL_ALIGNMENT_LEFT, -1, 12, INK_DIM)
				_box(Vector2(parent_x[side], rows[1]), BOX, int(parents[side]))
		var per_row := 4
		var child_rows := ceili(float(children.size()) / per_row)
		for index in range(children.size()):
			var at := _child_point(index, children.size(), per_row, w, rows[3], child_rows)
			_line(Vector2(w * 0.5, rows[2] + BOX.y * 0.5), at - Vector2(0.0, CHILD_BOX.y * 0.5))
		_box(Vector2(w * 0.5, rows[2]), BOX + Vector2(24.0, 0.0), focus, true)
		for index in range(children.size()):
			_box(_child_point(index, children.size(), per_row, w, rows[3], child_rows), CHILD_BOX, int(children[index]))
		var more := int(_family.get("more", 0))
		if more > 0:
			var text := "и ещё %d" % more
			draw_string(font, Vector2(w * 0.5 - 30.0, h - 4.0), text, HORIZONTAL_ALIGNMENT_LEFT, -1, 13, INK_DIM)
		if children.is_empty():
			draw_string(font, Vector2(w * 0.5 - 30.0, rows[3]), "детей нет", HORIZONTAL_ALIGNMENT_LEFT, -1, 13, INK_DIM)

	func _known(agent_id: int) -> bool:
		return bool(_cards.get(agent_id, {}).get("known", false))

	func _child_point(index: int, count: int, per_row: int, w: float, top: float, child_rows: int) -> Vector2:
		var row := floori(float(index) / per_row)
		var in_row := mini(per_row, count - row * per_row)
		var column := index - row * per_row
		var spacing := w / float(per_row)
		var start := w * 0.5 - spacing * (in_row - 1) * 0.5
		var y := top + float(row) * (CHILD_BOX.y + 10.0) - (float(child_rows - 1) * (CHILD_BOX.y + 10.0) * 0.25)
		return Vector2(start + spacing * column, y)

	func _line(from: Vector2, to: Vector2) -> void:
		var mid := (from.y + to.y) * 0.5
		draw_polyline(PackedVector2Array([from, Vector2(from.x, mid), Vector2(to.x, mid), to]), INK_DIM, 1.5)

	func _box(center: Vector2, box_size: Vector2, agent_id: int, focus := false) -> void:
		var rect := Rect2(center - box_size * 0.5, box_size)
		var card: Dictionary = _cards.get(agent_id, {})
		var known := bool(card.get("known", false))
		_boxes.append([rect, agent_id])
		draw_rect(rect, BOX_HOVER if agent_id == _hover and known else BOX_FILL, true)
		var border := PINNED if bool(card.get("pinned", false)) else (INK if focus else INK_DIM)
		draw_rect(rect, border, false, 2.0 if focus or bool(card.get("pinned", false)) else 1.0)
		var font := get_theme_default_font()
		var ink := INK_DIM if not known or bool(card.get("dead", false)) else INK
		var title := "%s %s" % [card.get("name", ""), card.get("glyph", "")] if known else "неизвестно"
		draw_string(font, rect.position + Vector2(8.0, 18.0), title.strip_edges(), HORIZONTAL_ALIGNMENT_LEFT,
			box_size.x - 16.0, 14, ink)
		if known:
			draw_string(font, rect.position + Vector2(8.0, 33.0), str(card.get("kind", "")), HORIZONTAL_ALIGNMENT_LEFT,
				box_size.x - 16.0, 12, INK_DIM)
			draw_string(font, rect.position + Vector2(8.0, 47.0), str(card.get("status", "")), HORIZONTAL_ALIGNMENT_LEFT,
				box_size.x - 16.0, 12, INK_DIM)
