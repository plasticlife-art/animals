class_name ChronicleWindow
extends PanelContainer

## «Летопись»: the world's story in one window over the map - an animal's whole known family
## on a sheet that zooms, pans and saves as a picture (`FamilyTreeView`), the records
## (`StoryRecords`), how each species' inherited traits have moved since the world began
## (`TraitHistory`), and every season's summary (`SeasonLedger`, in `SeasonReport`'s words), the
## one still going on top. The world keeps running behind it and the camera can still move. A
## click on a relative centres the tree on it and sends the camera there (`focus_requested`);
## «Назад» walks back through the relatives visited; a click on a record opens that animal's
## family. Esc or «Закрыть» closes it.

signal focus_requested(agent_id: int)
signal closed

const FamilyTreeScript := preload("res://scripts/story/family_tree.gd")
const FamilyTreeViewScript := preload("res://scripts/ui/family_tree_view.gd")
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
var _tree: FamilyTreeView
var _records: RecordsView
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
	_tree = FamilyTreeViewScript.new()
	_tree.custom_minimum_size = BODY_SIZE
	_tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_tree.picked.connect(_on_relative_picked)
	root.add_child(_tree)
	_records = RecordsView.new()
	_records.custom_minimum_size = BODY_SIZE
	_records.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_records.picked.connect(_open_record)
	root.add_child(_records)
	_traits_view = TraitsView.new()
	_traits_view.custom_minimum_size = BODY_SIZE
	_traits_view.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(_traits_view)
	_seasons_scroll = ScrollContainer.new()
	_seasons_scroll.custom_minimum_size = BODY_SIZE
	_seasons_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
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
	_empty.size_flags_vertical = Control.SIZE_EXPAND_FILL
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
	_records.visible = _tab == "records"
	_traits_view.visible = _tab == "traits"
	_seasons_scroll.visible = _tab == "seasons"
	_back.visible = family and not _history.is_empty()
	if story == null:
		return
	if family and _focus_id >= 0:
		_tree.show_family(FamilyTreeScript.whole(story, _focus_id), _now(), _calendar())
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
	var colors := {}
	for species_id in HudText.ANIMALS.keys():
		colors[species_id] = _species_color(str(species_id))
	_records.show_records(StoryRecordsScript.all(story, _now()), _calendar(), colors)


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


## A record's row in its parts, as the card draws it: `{name, noun, value, caption}` -
## «Хват †», «лис», «14», «добыча».
static func record_parts(row: Dictionary, kind: String, calendar: Array = [120.0, 4]) -> Dictionary:
	var sex := str(row.get("sex", ""))
	var value := float(row.get("value", 0.0))
	var parts := {"name": "%s%s" % [row.get("name", ""), " †" if bool(row.get("dead", false)) else ""],
		"noun": HudText.animal_noun(str(row.get("species", "")), sex), "value": "", "caption": ""}
	match kind:
		"oldest":
			parts["value"] = HudText.age_text(value, calendar)
			parts["caption"] = "возраст"
		"longest":
			parts["value"] = HudText.age_text(value, calendar)
			parts["caption"] = "прожила" if sex == "female" else "прожил"
		"family":
			parts["value"] = str(int(value))
			parts["caption"] = HudText.plural(int(value), ["живой потомок", "живых потомка", "живых потомков"])
		"hunters":
			parts["value"] = str(int(value))
			parts["caption"] = "добыча"
	return parts


func _now() -> float:
	return 0.0 if simulation_manager == null else float(simulation_manager.simulation_time)


## `[{id, label, color}]` for the species that inherit traits.
func _heredity_entries() -> Array:
	var entries: Array = []
	for species_id in story.heredity_species:
		entries.append({"id": str(species_id), "label": HudText.species_label(str(species_id)),
			"color": _species_color(str(species_id))})
	return entries


## A species' interface colour, darkened to read on parchment.
func _species_color(species_id: String) -> Color:
	var visuals: Dictionary = {} if simulation_manager == null else \
		simulation_manager.config_bundle.get("visuals", {}).get("species", {})
	var rgb: Array = visuals.get(species_id, {}).get("ui_color", [0.5, 0.5, 0.5])
	return Color(float(rgb[0]), float(rgb[1]), float(rgb[2])).darkened(SPECIES_DARKEN)


func _calendar() -> Array:
	if simulation_manager == null:
		return [120.0, 4]
	return Climate.calendar(simulation_manager.config_bundle.get("world", {}).get("climate", {}))


## The records as four cards, two a row: a card a kind, its title and what it is ranked by, then
## up to three animals best first - a medal with the place, the name over the kind of animal in its
## species' colour, the value over what it counts on the right. The dead are dimmed; a click on a
## row opens that animal's family (`picked`).
class RecordsView:
	extends Control

	signal picked(agent_id: int)

	const INK := Color(0.20, 0.13, 0.08)
	const INK_DIM := Color(0.20, 0.13, 0.08, 0.55)
	const PAPER := Color(0.91, 0.86, 0.72)
	const PAPER_HOVER := Color(0.85, 0.79, 0.63)
	const FRAME := Color(0.20, 0.13, 0.08, 0.35)
	const RULE := Color(0.20, 0.13, 0.08, 0.15)
	const MEDALS := [Color(0.78, 0.55, 0.12), Color(0.55, 0.53, 0.50), Color(0.62, 0.38, 0.20)]
	const HINTS := {"oldest": "живые, по возрасту", "longest": "ушедшие, по прожитому",
		"family": "по живым потомкам", "hunters": "по числу добычи"}
	const GAP := 18.0
	const PAD := 14.0
	const HEADER := 58.0
	const ROW := 52.0
	const ROW_GAP := 4.0
	const MEDAL := 13.0
	const TITLE_SIZE := 17
	const NAME_SIZE := 15
	const LINE_SIZE := 13
	const HINT_SIZE := 12

	var _rows: Dictionary = {}
	var _calendar: Array = [120.0, 4]
	var _colors: Dictionary = {}
	var _hits: Array = []
	var _hover := -1

	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_STOP

	func show_records(rows: Dictionary, calendar: Array, colors: Dictionary) -> void:
		_rows = rows
		_calendar = calendar
		_colors = colors
		queue_redraw()

	## Every row's words, card by card - what a reader would find here.
	func texts() -> Array:
		var out: Array = []
		for kind in StoryRecords.KINDS:
			for row in _rows.get(kind, []):
				out.append(ChronicleWindow.record_text(row, kind, _calendar))
		return out

	func _gui_input(event: InputEvent) -> void:
		if event is InputEventMouseMotion:
			var over := _row_at(event.position)
			if over != _hover:
				_hover = over
				mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND if over >= 0 else Control.CURSOR_ARROW
				queue_redraw()
		elif event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
			var hit := _row_at(event.position)
			if hit >= 0:
				picked.emit(hit)
				accept_event()

	func _notification(what: int) -> void:
		if what == NOTIFICATION_MOUSE_EXIT and _hover >= 0:
			_hover = -1
			queue_redraw()

	func _get_tooltip(at_position: Vector2) -> String:
		return "" if _row_at(at_position) < 0 else "Открыть семью"

	func _row_at(point: Vector2) -> int:
		for hit in _hits:
			if (hit[0] as Rect2).has_point(point):
				return int(hit[1])
		return -1

	func _draw() -> void:
		_hits.clear()
		var font := get_theme_default_font()
		if font == null:
			return
		var cell := Vector2((size.x - GAP) * 0.5, (size.y - GAP) * 0.5)
		for index in range(StoryRecords.KINDS.size()):
			var origin := Vector2(float(index % 2) * (cell.x + GAP), float(floori(index / 2.0)) * (cell.y + GAP))
			_card(Rect2(origin, cell), str(StoryRecords.KINDS[index]), font)

	func _card(rect: Rect2, kind: String, font: Font) -> void:
		draw_rect(rect, PAPER, true)
		draw_rect(rect, FRAME, false, 1.0)
		var left := rect.position.x + PAD
		var room := rect.size.x - PAD * 2.0
		draw_string(font, Vector2(left, rect.position.y + 26.0), str(StoryRecords.TITLES[kind]),
			HORIZONTAL_ALIGNMENT_LEFT, room, TITLE_SIZE, INK)
		draw_string(font, Vector2(left, rect.position.y + 44.0), str(HINTS.get(kind, "")), HORIZONTAL_ALIGNMENT_LEFT,
			room, HINT_SIZE, INK_DIM)
		draw_line(Vector2(left, rect.position.y + HEADER - 4.0), Vector2(rect.end.x - PAD, rect.position.y + HEADER - 4.0),
			RULE, 1.0)
		var listed: Array = _rows.get(kind, [])
		if listed.is_empty():
			var none := "пока никого"
			var width := font.get_string_size(none, HORIZONTAL_ALIGNMENT_LEFT, -1, LINE_SIZE).x
			draw_string(font, Vector2(rect.get_center().x - width * 0.5, rect.position.y + HEADER + 48.0), none,
				HORIZONTAL_ALIGNMENT_LEFT, -1, LINE_SIZE, INK_DIM)
			return
		for place in range(listed.size()):
			var row_rect := Rect2(rect.position.x + 4.0, rect.position.y + HEADER + place * (ROW + ROW_GAP),
				rect.size.x - 8.0, ROW)
			_row(row_rect, place, listed[place], kind, font)

	func _row(rect: Rect2, place: int, row: Dictionary, kind: String, font: Font) -> void:
		var agent_id := int(row.get("id", -1))
		_hits.append([rect, agent_id])
		if agent_id == _hover:
			draw_rect(rect, PAPER_HOVER, true)
		var dead := bool(row.get("dead", false))
		var parts: Dictionary = ChronicleWindow.record_parts(row, kind, _calendar)
		var center := Vector2(rect.position.x + PAD + MEDAL - 4.0, rect.get_center().y)
		var medal: Color = MEDALS[mini(place, MEDALS.size() - 1)]
		draw_circle(center, MEDAL, medal)
		var number := str(place + 1)
		var number_width := font.get_string_size(number, HORIZONTAL_ALIGNMENT_LEFT, -1, LINE_SIZE).x
		draw_string(font, Vector2(center.x - number_width * 0.5, center.y + 5.0), number, HORIZONTAL_ALIGNMENT_LEFT, -1,
			LINE_SIZE, PAPER)
		var right := rect.end.x - PAD + 4.0
		var value := str(parts["value"])
		var caption := str(parts["caption"])
		var value_width := font.get_string_size(value, HORIZONTAL_ALIGNMENT_LEFT, -1, NAME_SIZE).x
		var caption_width := font.get_string_size(caption, HORIZONTAL_ALIGNMENT_LEFT, -1, HINT_SIZE).x
		var ink := INK_DIM if dead else INK
		draw_string(font, Vector2(right - value_width, rect.position.y + 22.0), value, HORIZONTAL_ALIGNMENT_LEFT, -1,
			NAME_SIZE, ink)
		draw_string(font, Vector2(right - caption_width, rect.position.y + 40.0), caption, HORIZONTAL_ALIGNMENT_LEFT, -1,
			HINT_SIZE, INK_DIM)
		var left := center.x + MEDAL + 10.0
		var room := maxf(40.0, right - maxf(value_width, caption_width) - 12.0 - left)
		draw_string(font, Vector2(left, rect.position.y + 22.0), str(parts["name"]), HORIZONTAL_ALIGNMENT_LEFT, room,
			NAME_SIZE, ink)
		var noun_color: Color = _colors.get(str(row.get("species", "")), INK_DIM)
		if dead:
			noun_color.a = 0.6
		draw_string(font, Vector2(left, rect.position.y + 40.0), str(parts["noun"]), HORIZONTAL_ALIGNMENT_LEFT, room,
			LINE_SIZE, noun_color)


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
