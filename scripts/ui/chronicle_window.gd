class_name ChronicleWindow
extends PanelContainer

## «Летопись»: the world's story in one window over the map - an animal's family three
## generations deep (`FamilyTree`), the records (`StoryRecords`), how each species' inherited
## traits have moved since the world began (`TraitHistory`), and every season's summary
## (`SeasonLedger`, in `SeasonReport`'s words), the one still going on top. The world keeps
## running behind it and the camera can still move. A click on a relative centres the tree on it and
## sends the camera there (`focus_requested`); «Назад» walks back through the relatives
## visited; a click on a record opens that animal's family. Esc or «Закрыть» closes it.

signal focus_requested(agent_id: int)
signal closed

const FamilyTreeScript := preload("res://scripts/story/family_tree.gd")
const StoryRecordsScript := preload("res://scripts/story/story_records.gd")
const SeasonReportScript := preload("res://scripts/story/season_report.gd")
const ClimateScript := preload("res://scripts/world/climate.gd")
const REFRESH_SECONDS := 1.5
const BODY_SIZE := Vector2(760.0, 500.0)
const TABS := {"family": "Родословная", "records": "Рекорды", "traits": "Черты", "seasons": "Сезоны"}
## Species lines are drawn in the species' interface colour, darkened to read on parchment.
const SPECIES_DARKEN := 0.45

var story = null
var simulation_manager = null
var _tab := "family"
var _focus_id := -1
var _history: Array = []
var _tabs: Dictionary = {}
var _tree: TreeView
var _records_scroll: ScrollContainer
var _records_box: VBoxContainer
var _traits_view: TraitsView
var _seasons_scroll: ScrollContainer
var _seasons_box: VBoxContainer
## The season still going, at the top of «Сезоны»: refreshed in place.
var _running_title: Label
var _running_text: Label
## What the closed seasons' rows were built from; they are built again only when it changes.
var _seasons_key := ""
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
	_traits_view = TraitsView.new()
	_traits_view.custom_minimum_size = BODY_SIZE
	root.add_child(_traits_view)
	_seasons_scroll = ScrollContainer.new()
	_seasons_scroll.custom_minimum_size = BODY_SIZE
	_seasons_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	root.add_child(_seasons_scroll)
	_seasons_box = VBoxContainer.new()
	_seasons_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_seasons_box.add_theme_constant_override("separation", 4)
	_seasons_scroll.add_child(_seasons_box)
	_empty = Label.new()
	_empty.text = "Выберите животное на карте или в списке закреплённых, чтобы увидеть его семью."
	_empty.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_empty.custom_minimum_size.x = BODY_SIZE.x
	root.add_child(_empty)


func bind(story_book, manager) -> void:
	story = story_book
	simulation_manager = manager
	_tree.story = story_book
	_seasons_key = ""


## Opens on an animal's family, or on `tab`; with no animal, the one already shown, if any.
func open(agent_id := -1, tab := "family") -> void:
	if agent_id >= 0 and agent_id != _focus_id:
		_history.clear()
		_focus_id = agent_id
	visible = true
	show_tab(tab)


## A new world: nobody's family shown yet, and its own seasons.
func reset() -> void:
	_history.clear()
	_focus_id = -1
	_seasons_key = ""
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
	_records_scroll.visible = _tab == "records"
	_traits_view.visible = _tab == "traits"
	_seasons_scroll.visible = _tab == "seasons"
	_back.visible = family and not _history.is_empty()
	if story == null:
		return
	if family and _focus_id >= 0:
		_tree.show_family(FamilyTreeScript.around(story, _focus_id), _now(), _calendar())
	elif _tab == "records":
		_fill_records()
	elif _tab == "traits":
		_traits_view.show_history(story.trait_history, _heredity_entries(), _now(), _calendar())
	elif _tab == "seasons":
		_fill_seasons()


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


## «Сезоны»: the season going on top, refreshed in place, then every closed one, newest first -
## those rows built again only when a season closes, not on every refresh.
func _fill_seasons() -> void:
	var climate_config: Dictionary = {} if simulation_manager == null else \
		simulation_manager.config_bundle.get("world", {}).get("climate", {})
	var clock := ClimateScript.season_ordinal(climate_config, _now()) >= 0
	var closed: Array = story.seasons.closed
	var key := "off"
	if clock:
		key = "%d:%d" % [closed.size(), -1 if closed.is_empty() else int(closed.back()["ordinal"])]
	if key != _seasons_key:
		_seasons_key = key
		_build_seasons(clock, closed)
	if not clock:
		return
	var running: Dictionary = story.seasons.preview(_now(), simulation_manager, story)
	_running_title.text = "" if running.is_empty() else SeasonReportScript.title(running, "running")
	var running_text := "" if running.is_empty() else SeasonReportScript.text(running)
	_running_text.text = running_text if running_text != "" else "Пока ничего не случилось."


func _build_seasons(clock: bool, closed: Array) -> void:
	for child in _seasons_box.get_children():
		_seasons_box.remove_child(child)
		child.queue_free()
	_running_title = null
	_running_text = null
	if not clock:
		var none := Label.new()
		none.text = "В этом мире нет смены сезонов."
		_seasons_box.add_child(none)
		return
	_running_title = _season_title("")
	_running_text = _season_text("")
	if closed.is_empty():
		var quiet := Label.new()
		quiet.text = "Ни один сезон ещё не закончился."
		quiet.modulate = Color(1.0, 1.0, 1.0, 0.55)
		_seasons_box.add_child(quiet)
	for index in range(closed.size() - 1, -1, -1):
		var summary: Dictionary = closed[index]
		_season_title(SeasonReportScript.title(summary, "row"))
		_season_text(SeasonReportScript.text(summary))


func _season_title(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", 17)
	_seasons_box.add_child(label)
	return label


func _season_text(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.custom_minimum_size.x = BODY_SIZE.x - 24.0
	_seasons_box.add_child(label)
	return label


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


## `[{id, label, color}]` for the species that inherit traits.
func _heredity_entries() -> Array:
	var entries: Array = []
	var visuals: Dictionary = {} if simulation_manager == null else \
		simulation_manager.config_bundle.get("visuals", {}).get("species", {})
	for species_id in story.heredity_species:
		var rgb: Array = visuals.get(species_id, {}).get("ui_color", [0.5, 0.5, 0.5])
		entries.append({"id": str(species_id), "label": HudText.species_label(str(species_id)),
			"color": Color(float(rgb[0]), float(rgb[1]), float(rgb[2])).darkened(SPECIES_DARKEN)})
	return entries


func _calendar() -> Array:
	if simulation_manager == null:
		return [120.0, 4]
	return Climate.calendar(simulation_manager.config_bundle.get("world", {}).get("climate", {}))


## The family drawn as boxes and lines: grandparents, parents, the animal, its children.
class TreeView:
	extends Control

	## Three generations about an animal, laid out to the height there is: the grandparents in
	## pairs over each parent, the parents over the animal, its children under it, four a row.
	## Generations nobody knows take no room. The lines run first and the boxes over them, a
	## lower row of children reached down the gap between two boxes of the row above. A box
	## shows sex by its stripe, the dead dimmed; the animal's own box says its family and whether
	## its parents are kin.

	signal picked(agent_id: int)

	const INK := Color(0.20, 0.13, 0.08)
	const INK_DIM := Color(0.20, 0.13, 0.08, 0.55)
	const LINE := Color(0.20, 0.13, 0.08, 0.45)
	const PAPER := Color(0.91, 0.86, 0.72)
	const PAPER_HOVER := Color(0.85, 0.79, 0.63)
	const PAPER_DEAD := Color(0.87, 0.84, 0.76)
	const PINNED := Color(0.78, 0.55, 0.12)
	const KIN := Color(0.62, 0.30, 0.10)
	const STRIPE := {"female": Color(0.74, 0.36, 0.42), "male": Color(0.27, 0.45, 0.64)}
	const STRIPE_DEAD := Color(0.20, 0.13, 0.08, 0.25)
	const BOX := Vector2(176.0, 56.0)
	const FOCUS_BOX := Vector2(250.0, 84.0)
	const CHILD_BOX := Vector2(168.0, 56.0)
	const PER_ROW := 4
	const GENERATION_GAP := 40.0
	const CHILD_ROW_GAP := 20.0
	const CAPTION := 16.0
	const NAME_SIZE := 15
	const LINE_SIZE := 13

	var story = null
	var _family: Dictionary = {}
	var _cards: Dictionary = {}
	var _boxes: Array = []
	var _hover := -2
	var _focus_line := ""
	var _kinship := ""

	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_STOP

	func show_family(family: Dictionary, now: float, calendar: Array) -> void:
		_family = family
		_cards.clear()
		var focus := int(family.get("focus", -1))
		var ids: Array = [focus] + family.get("parents", []) + family.get("grandparents", []) + family.get("children", [])
		for agent_id in ids:
			_cards[int(agent_id)] = FamilyTree.card(story, int(agent_id), now, calendar)
		for child in family.get("children", []):
			var mate := FamilyTree.mate_line(story, int(child), focus)
			if mate != "" and bool(_cards[int(child)].get("known", false)):
				_cards[int(child)]["kind"] = mate
		_focus_line = FamilyTree.focus_line(story, focus) if focus >= 0 else ""
		_kinship = FamilyTree.parents_kinship(family)
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

	## What the relative under the cursor inherited.
	func _get_tooltip(at_position: Vector2) -> String:
		var hit := _box_at(at_position)
		return "" if hit < 0 else str(_cards.get(hit, {}).get("traits", ""))

	func _box_at(point: Vector2) -> int:
		for box in _boxes:
			if (box[0] as Rect2).has_point(point) and bool(_cards.get(int(box[1]), {}).get("known", false)):
				return int(box[1])
		return -1

	## The rows there are and where they stand: `{grand, parents, focus, children: [y…], more}`,
	## each a row's top, -1 for a row not drawn; the whole centred in `height`.
	func layout(height: float) -> Dictionary:
		var grand: Array = _family.get("grandparents", [-1, -1, -1, -1])
		var parents: Array = _family.get("parents", [-1, -1])
		var children: Array = _family.get("children", [])
		var has_grand := false
		for index in range(4):
			has_grand = has_grand or _known(int(grand[index]))
		var has_parents := _known(int(parents[0])) or _known(int(parents[1]))
		has_grand = has_grand and has_parents
		var child_rows := ceili(float(children.size()) / PER_ROW)
		var more := int(_family.get("more", 0))
		var total := FOCUS_BOX.y
		if has_grand:
			total += CAPTION + BOX.y + GENERATION_GAP
		if has_parents:
			total += BOX.y + GENERATION_GAP
		if child_rows > 0:
			total += GENERATION_GAP + child_rows * CHILD_BOX.y + (child_rows - 1) * CHILD_ROW_GAP
		if more > 0:
			total += 24.0
		var y := maxf(6.0, (height - total) * 0.5)
		var out := {"grand": -1.0, "parents": -1.0, "focus": -1.0, "children": [], "more": -1.0}
		if has_grand:
			out["grand"] = y + CAPTION
			y += CAPTION + BOX.y + GENERATION_GAP
		if has_parents:
			out["parents"] = y
			y += BOX.y + GENERATION_GAP
		out["focus"] = y
		y += FOCUS_BOX.y
		if child_rows > 0:
			y += GENERATION_GAP
			for row in range(child_rows):
				out["children"].append(y)
				y += CHILD_BOX.y + CHILD_ROW_GAP
			y -= CHILD_ROW_GAP
		if more > 0:
			out["more"] = y + 18.0
		return out

	func _draw() -> void:
		_boxes.clear()
		if _family.is_empty():
			return
		var w := size.x
		var rows := layout(size.y)
		var grand: Array = _family.get("grandparents", [-1, -1, -1, -1])
		var parents: Array = _family.get("parents", [-1, -1])
		var focus := int(_family.get("focus", -1))
		var children: Array = _family.get("children", [])
		var parent_x := [w * 0.27, w * 0.73]
		var grand_x := [w * 0.13, w * 0.39, w * 0.61, w * 0.87]
		var font := get_theme_default_font()
		var focus_top: float = rows["focus"]
		var focus_bottom: float = focus_top + FOCUS_BOX.y
		# Lines first, boxes over them.
		var grand_pairs: Array = []
		if float(rows["grand"]) >= 0.0:
			for side in range(2):
				if _known(int(grand[side * 2])) or _known(int(grand[side * 2 + 1])):
					grand_pairs.append(side)
					_join([grand_x[side * 2], grand_x[side * 2 + 1]], float(rows["grand"]) + BOX.y, parent_x[side],
						float(rows["parents"]))
		if float(rows["parents"]) >= 0.0:
			_join(parent_x, float(rows["parents"]) + BOX.y, w * 0.5, focus_top)
		var child_rows: Array = rows["children"]
		var trunk_from := focus_bottom
		var trunk_x := w * 0.5
		for row in range(child_rows.size()):
			var row_top: float = child_rows[row]
			var bus := row_top - (GENERATION_GAP if row == 0 else CHILD_ROW_GAP) * 0.5
			var xs: Array = []
			for index in range(row * PER_ROW, mini(children.size(), (row + 1) * PER_ROW)):
				xs.append(_child_x(index, children.size(), w))
			draw_line(Vector2(trunk_x, trunk_from), Vector2(trunk_x, bus), LINE, 1.5)
			draw_line(Vector2(minf(trunk_x, xs.min()), bus), Vector2(maxf(trunk_x, xs.max()), bus), LINE, 1.5)
			for x in xs:
				draw_line(Vector2(x, bus), Vector2(x, row_top), LINE, 1.5)
			# The next row is reached down the gap nearest the middle of this one.
			trunk_from = bus
			trunk_x = _gap_x(xs, w)
		# Boxes.
		var captions := ["родители матери", "родители отца"]
		for side in grand_pairs:
			var caption: String = captions[side]
			var width := font.get_string_size(caption, HORIZONTAL_ALIGNMENT_LEFT, -1, 12).x
			draw_string(font, Vector2(parent_x[side] - width * 0.5, float(rows["grand"]) - 5.0), caption,
				HORIZONTAL_ALIGNMENT_LEFT, -1, 12, INK_DIM)
			for index in [side * 2, side * 2 + 1]:
				_box(Vector2(grand_x[index], float(rows["grand"]) + BOX.y * 0.5), BOX, int(grand[index]), "неизвестно")
		if float(rows["parents"]) >= 0.0:
			var unknown := ["мать неизвестна", "отец неизвестен"]
			for side in range(2):
				_box(Vector2(parent_x[side], float(rows["parents"]) + BOX.y * 0.5), BOX, int(parents[side]), unknown[side])
		_focus_box(Vector2(w * 0.5, focus_top + FOCUS_BOX.y * 0.5), focus, float(rows["parents"]) < 0.0)
		for index in range(children.size()):
			var row := floori(float(index) / PER_ROW)
			_box(Vector2(_child_x(index, children.size(), w), float(child_rows[row]) + CHILD_BOX.y * 0.5), CHILD_BOX,
				int(children[index]), "неизвестно")
		if float(rows["more"]) >= 0.0:
			var text := "и ещё %d" % int(_family.get("more", 0))
			var width := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, LINE_SIZE).x
			draw_string(font, Vector2(w * 0.5 - width * 0.5, float(rows["more"])), text, HORIZONTAL_ALIGNMENT_LEFT, -1,
				LINE_SIZE, INK_DIM)

	func _known(agent_id: int) -> bool:
		return bool(_cards.get(agent_id, {}).get("known", false))

	## A child's centre: `PER_ROW` a row, a short last row centred.
	func _child_x(index: int, count: int, w: float) -> float:
		var row := floori(float(index) / PER_ROW)
		var in_row := mini(PER_ROW, count - row * PER_ROW)
		var spacing := w / float(PER_ROW)
		return w * 0.5 - spacing * (in_row - 1) * 0.5 + spacing * (index - row * PER_ROW)

	## Where a line can pass down through a row of boxes centred at `xs`: the middle when the row
	## is even (a gap there), else beside the middle box.
	func _gap_x(xs: Array, w: float) -> float:
		if xs.size() % 2 == 0:
			return w * 0.5
		var spacing := w / float(PER_ROW)
		return w * 0.5 + spacing * 0.5

	## Parents into a child: down from each parent to a rule between the rows, along it, down
	## into the child.
	func _join(from_xs: Array, from_bottom: float, to_x: float, to_top: float) -> void:
		var bus := to_top - GENERATION_GAP * 0.5
		var left: float = minf(from_xs.min(), to_x)
		var right: float = maxf(from_xs.max(), to_x)
		for x in from_xs:
			draw_line(Vector2(x, from_bottom), Vector2(x, bus), LINE, 1.5)
		draw_line(Vector2(left, bus), Vector2(right, bus), LINE, 1.5)
		draw_line(Vector2(to_x, bus), Vector2(to_x, to_top), LINE, 1.5)

	func _frame(rect: Rect2, agent_id: int, focus: bool) -> Dictionary:
		var card: Dictionary = _cards.get(agent_id, {})
		var known := bool(card.get("known", false))
		var dead := bool(card.get("dead", false))
		_boxes.append([rect, agent_id])
		draw_rect(rect, PAPER_HOVER if agent_id == _hover and known else (PAPER_DEAD if dead or not known else PAPER), true)
		var pinned := bool(card.get("pinned", false))
		var border := PINNED if pinned else (INK if focus else INK_DIM)
		draw_rect(rect, border, false, 2.0 if focus or pinned else 1.0)
		if known:
			var stripe: Color = STRIPE_DEAD if dead else STRIPE.get(str(card.get("sex", "")), INK_DIM)
			draw_rect(Rect2(rect.position + Vector2(1.0, 1.0), Vector2(5.0, rect.size.y - 2.0)), stripe, true)
		return card

	func _box(center: Vector2, box_size: Vector2, agent_id: int, unknown_text: String) -> void:
		var rect := Rect2(center - box_size * 0.5, box_size)
		var card := _frame(rect, agent_id, false)
		var font := get_theme_default_font()
		var known := bool(card.get("known", false))
		var ink := INK_DIM if not known or bool(card.get("dead", false)) else INK
		var left := rect.position.x + 14.0
		var room := box_size.x - 22.0
		if not known:
			draw_string(font, Vector2(left, rect.position.y + 33.0), unknown_text, HORIZONTAL_ALIGNMENT_LEFT, room, LINE_SIZE, INK_DIM)
			return
		var title := ("%s %s" % [card.get("name", ""), card.get("glyph", "")]).strip_edges()
		draw_string(font, Vector2(left, rect.position.y + 19.0), title, HORIZONTAL_ALIGNMENT_LEFT, room, NAME_SIZE, ink)
		draw_string(font, Vector2(left, rect.position.y + 35.0), str(card.get("kind", "")), HORIZONTAL_ALIGNMENT_LEFT, room, LINE_SIZE, INK_DIM)
		draw_string(font, Vector2(left, rect.position.y + 50.0), str(card.get("status", "")), HORIZONTAL_ALIGNMENT_LEFT, room, LINE_SIZE, INK_DIM)

	## The animal itself: its name larger, its kind and age, its family, and a note when its
	## parents are kin - or that its parents are not known.
	func _focus_box(center: Vector2, agent_id: int, founder: bool) -> void:
		var rect := Rect2(center - FOCUS_BOX * 0.5, FOCUS_BOX)
		var card := _frame(rect, agent_id, true)
		var font := get_theme_default_font()
		var left := rect.position.x + 14.0
		var room := FOCUS_BOX.x - 22.0
		var ink := INK_DIM if bool(card.get("dead", false)) else INK
		var title := ("%s %s" % [card.get("name", ""), card.get("glyph", "")]).strip_edges()
		draw_string(font, Vector2(left, rect.position.y + 22.0), title, HORIZONTAL_ALIGNMENT_LEFT, room, NAME_SIZE + 2, ink)
		var about := " · ".join([str(card.get("kind", "")), str(card.get("status", ""))].filter(func(part): return part != ""))
		draw_string(font, Vector2(left, rect.position.y + 40.0), about, HORIZONTAL_ALIGNMENT_LEFT, room, LINE_SIZE, INK_DIM)
		draw_string(font, Vector2(left, rect.position.y + 57.0), _focus_line, HORIZONTAL_ALIGNMENT_LEFT, room, LINE_SIZE, INK)
		var note := "родители неизвестны" if founder else _kinship
		if note != "":
			draw_string(font, Vector2(left, rect.position.y + 74.0), note, HORIZONTAL_ALIGNMENT_LEFT, room, LINE_SIZE,
				INK_DIM if founder else KIN)


## Each species' inherited traits over the world's life (`TraitHistory`): four small charts, one
## a trait, a line a species, the species as written (1.0) dashed across the middle. The scale
## reaches as far as the furthest point, at least `TraitHistory.MIN_SPAN`; the latest value is
## written at the end of each line.
class TraitsView:
	extends Control

	const INK := Color(0.20, 0.13, 0.08)
	const INK_DIM := Color(0.20, 0.13, 0.08, 0.5)
	const FRAME := Color(0.20, 0.13, 0.08, 0.2)
	const GAP := 22.0
	const LEFT := 46.0
	const RIGHT := 50.0

	var history = null
	var species: Array = []
	var now := 0.0
	var calendar: Array = [120.0, 4]

	func show_history(trait_history, entries: Array, time: float, world_calendar: Array) -> void:
		history = trait_history
		species = entries
		now = time
		calendar = world_calendar
		queue_redraw()

	func _draw() -> void:
		var font := get_theme_default_font()
		if history == null or font == null:
			return
		if species.is_empty():
			draw_string(font, Vector2(8.0, 30.0), "В этом мире черты не наследуются.", HORIZONTAL_ALIGNMENT_LEFT,
				-1, 15, INK_DIM)
			return
		var x := 0.0
		for entry in species:
			draw_string(font, Vector2(x, 15.0), str(entry["label"]), HORIZONTAL_ALIGNMENT_LEFT, -1, 15, entry["color"])
			x += font.get_string_size(str(entry["label"]), HORIZONTAL_ALIGNMENT_LEFT, -1, 15).x + 18.0
		draw_string(font, Vector2(x + 6.0, 15.0), "— средние по виду, от начала мира", HORIZONTAL_ALIGNMENT_LEFT,
			-1, 13, INK_DIM)
		if history.points.size() < 2:
			draw_string(font, Vector2(0.0, 48.0), "Собираем данные: точка раз в %d с." % int(history.interval),
				HORIZONTAL_ALIGNMENT_LEFT, -1, 14, INK_DIM)
			return
		var top := 30.0
		var cell := Vector2((size.x - GAP) * 0.5, (size.y - top - GAP) * 0.5)
		for index in range(HudText.TRAIT_LABELS.size()):
			var origin := Vector2(float(index % 2) * (cell.x + GAP), top + float(floori(index / 2.0)) * (cell.y + GAP))
			_chart(Rect2(origin, cell), index, font)

	func _chart(rect: Rect2, index: int, font: Font) -> void:
		draw_string(font, rect.position + Vector2(0.0, 14.0), str(HudText.TRAIT_LABELS[index]),
			HORIZONTAL_ALIGNMENT_LEFT, -1, 14, INK)
		var plot := Rect2(rect.position + Vector2(LEFT, 22.0), rect.size - Vector2(LEFT + RIGHT, 22.0 + 16.0))
		draw_rect(plot, FRAME, false, 1.0)
		var reach: float = history.span(index)
		var middle := plot.get_center().y
		draw_dashed_line(Vector2(plot.position.x, middle), Vector2(plot.end.x, middle), INK_DIM, 1.0, 4.0)
		draw_string(font, Vector2(rect.position.x, plot.position.y + 10.0), HudText.percent_change(1.0 + reach),
			HORIZONTAL_ALIGNMENT_LEFT, LEFT - 4.0, 11, INK_DIM)
		draw_string(font, Vector2(rect.position.x, middle + 4.0), "вид", HORIZONTAL_ALIGNMENT_LEFT, LEFT - 4.0, 11, INK_DIM)
		draw_string(font, Vector2(rect.position.x, plot.end.y), HudText.percent_change(1.0 - reach),
			HORIZONTAL_ALIGNMENT_LEFT, LEFT - 4.0, 11, INK_DIM)
		var first := float(history.points[0]["time"])
		var last := maxf(now, float(history.points[-1]["time"]))
		var duration := maxf(1.0, last - first)
		var ends: Array = []
		for entry in species:
			var line := PackedVector2Array()
			for point in history.points:
				var means = point["values"].get(entry["id"])
				if means == null:
					# Gone for a while: the line breaks rather than bridging the gap.
					if line.size() >= 2:
						draw_polyline(line, entry["color"], 2.0, true)
					line = PackedVector2Array()
					continue
				var at_x := plot.position.x + (float(point["time"]) - first) / duration * plot.size.x
				line.append(Vector2(at_x, _y(plot, middle, reach, float(means[index]))))
			if line.size() >= 2:
				draw_polyline(line, entry["color"], 2.0, true)
			var latest: Array = history.latest(str(entry["id"]))
			if not latest.is_empty():
				ends.append([_y(plot, middle, reach, float(latest[index])), HudText.percent_change(float(latest[index])),
					entry["color"]])
		# The latest values beside the lines' ends, nudged apart where they would overlap.
		ends.sort_custom(func(a, b): return float(a[0]) < float(b[0]))
		var floor_y := -INF
		for end in ends:
			var y := maxf(float(end[0]) + 4.0, floor_y + 12.0)
			draw_string(font, Vector2(plot.end.x + 4.0, y), str(end[1]), HORIZONTAL_ALIGNMENT_LEFT, RIGHT - 4.0, 11, end[2])
			floor_y = y
		draw_string(font, Vector2(plot.position.x, plot.end.y + 13.0), "начало", HORIZONTAL_ALIGNMENT_LEFT, -1, 11, INK_DIM)
		var age := HudText.age_text(last, calendar)
		var width := font.get_string_size(age, HORIZONTAL_ALIGNMENT_LEFT, -1, 11).x
		draw_string(font, Vector2(plot.end.x - width, plot.end.y + 13.0), age, HORIZONTAL_ALIGNMENT_LEFT, -1, 11, INK_DIM)

	static func _y(plot: Rect2, middle: float, reach: float, value: float) -> float:
		return clampf(middle - (value - 1.0) / reach * plot.size.y * 0.5, plot.position.y, plot.end.y)
