class_name FamilyTreeView
extends Control

## The chronicle's «Родословная»: the whole known family about one animal (`FamilyTree.whole`)
## on a sheet that zooms and pans - its ancestors above, a generation a band, its descendants
## below. It opens on five generations, grandparents to grandchildren, as close as they fit and
## never so far that the names cannot be read. The wheel, two fingers or a pinch zoom about the
## pointer as on the map; a drag pans, or two fingers with Shift. The buttons zoom, fit the five
## generations again («Вписать») or the whole tree («Всё дерево»), and «PNG» saves the whole
## tree as one picture in the Pictures folder (`PhotoMode.pictures_folder`). A click on a
## relative picks it (`picked`). The pointer over a relative lights its line down to the animal,
## and every other box of the same animal: a pedigree of kin draws an ancestor more than once.
##
## Boxes are laid out tidy (`layout`): parents centred over their child, a brood under its
## parent, subtrees pushed apart only as far as their rows need. Lines run first and the boxes
## over them. A box shows sex by its stripe and glyph, the dead dimmed, the pinned in gold; a box
## with relatives past the limits says «ещё N». The text is drawn at the size the zoom gives it,
## rounded down so it never outgrows its box, and so stays sharp; zoomed far out a box keeps only
## its name, and further out it is a plain block.

signal picked(agent_id: int)

const PhotoModeScript := preload("res://scripts/ui/photo_mode.gd")

const INK := Color(0.20, 0.13, 0.08)
const INK_DIM := Color(0.20, 0.13, 0.08, 0.58)
const INK_FAINT := Color(0.20, 0.13, 0.08, 0.35)
const LINE := Color(0.20, 0.13, 0.08, 0.42)
const PATH := Color(0.66, 0.33, 0.10)
const SHEET := Color(0.93, 0.89, 0.78)
const SHEET_EDGE := Color(0.20, 0.13, 0.08, 0.28)
const BAND := Color(0.20, 0.13, 0.08, 0.035)
const PAPER := Color(0.97, 0.94, 0.85)
const PAPER_HOVER := Color(1.0, 0.98, 0.91)
const PAPER_DEAD := Color(0.88, 0.85, 0.78)
const PAPER_FOCUS := Color(1.0, 0.95, 0.80)
const PAPER_UNKNOWN := Color(0.90, 0.87, 0.80, 0.7)
const SHADOW := Color(0.20, 0.13, 0.08, 0.16)
const PINNED := Color(0.80, 0.56, 0.10)
const KIN := Color(0.62, 0.30, 0.10)
const STRIPE := {"female": Color(0.76, 0.36, 0.43), "male": Color(0.27, 0.46, 0.66)}
const STRIPE_DEAD := Color(0.20, 0.13, 0.08, 0.22)
const BOX := Vector2(168.0, 64.0)
const FOCUS_BOX := Vector2(320.0, 96.0)
## From one generation's middle to the next.
const ROW_PITCH := 128.0
## Between two boxes of one brood or one pair, and between the boxes of two families.
const SIBLING_GAP := 12.0
const COUSIN_GAP := 32.0
const NAME_SIZE := 15
const LINE_SIZE := 13
const LABEL_SIZE := 12
## Text smaller than this on screen is left out; boxes narrower than this are plain blocks.
const MIN_TEXT := 6
## Zoomed out past the names' own size, a box keeps its name alone at this size.
const FAR_NAME_SIZE := 8
const MIN_DETAIL_WIDTH := 34.0
const MIN_ZOOM := 0.03
const MAX_ZOOM := 2.5
## The first view of a family: these generations each way, but never further than this.
const DEFAULT_GENERATIONS := 2
const DEFAULT_MIN_ZOOM := 0.5
## Fits never enlarge past this.
const FIT_MAX_ZOOM := 1.0
## Room the fits leave: around, and over the toolbar and under the hint.
const MARGIN := 18.0
const TOP_ROOM := 44.0
const BOTTOM_ROOM := 30.0
const BUTTON_STEP := 1.3
const WHEEL_STEP := 1.12
const PAN_GESTURE_SPEED := 18.0
const TRACKPAD_ZOOM := 0.08
const DRAG_SLOP := 5.0
const EASE_RATE := 12.0
## The picture: twice the sheet's size, smaller when the tree would be wider than this.
const EXPORT_SCALE := 2.0
const EXPORT_MAX_PIXELS := 12000.0
const EXPORT_HEADER := 70.0
const EXPORT_MARGIN := 40.0

var story = null
## Where pictures go instead of the Pictures folder, when set (the tests).
var folder_override := ""
## A copy drawn for the picture: no toolbar, no hover, a title over the tree.
var exporting := false
var font_override: Font = null
var title_text := ""
var subtitle_text := ""

var _tree: Dictionary = {}
var _nodes: Array = []
var _pos: Array = []
var _cards: Dictionary = {}
var _kinds: Array = []
var _bounds := Rect2()
var _focus := -1
var _focus_line := ""
var _kinship := ""
var _zoom := 1.0
var _center := Vector2.ZERO
var _goal_zoom := 1.0
var _goal_center := Vector2.ZERO
var _easing := false
## Whether the view is still the one it opened on, refitted as the sheet changes size.
var _fitted := true
var _hover := -1
var _press_button := 0
var _press_at := Vector2.ZERO
var _dragging := false
## Where the relative just picked stood, so the new tree opens where the old one was looked at.
var _picked_at = null
var _box_style := StyleBoxFlat.new()
var _stripe_style := StyleBoxFlat.new()
var _zoom_label: Label
var _status: Label
var _open_folder: Button
var _export_button: Button
var _last_path := ""


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	clip_contents = true
	focus_mode = Control.FOCUS_NONE


func _ready() -> void:
	if exporting:
		return
	var bar := HBoxContainer.new()
	bar.add_theme_constant_override("separation", 4)
	bar.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT, Control.PRESET_MODE_MINSIZE, 8)
	bar.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	add_child(bar)
	_zoom_label = Label.new()
	_zoom_label.add_theme_color_override("font_color", INK_DIM)
	_zoom_label.add_theme_font_size_override("font_size", 13)
	_zoom_label.custom_minimum_size.x = 48.0
	_zoom_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	bar.add_child(_zoom_label)
	bar.add_child(_button("−", "Отдалить", func() -> void: zoom_by(1.0 / BUTTON_STEP)))
	bar.add_child(_button("+", "Приблизить", func() -> void: zoom_by(BUTTON_STEP)))
	bar.add_child(_button("Вписать", "Бабушки и деды, родители, дети и внуки", fit_default.bind(true)))
	bar.add_child(_button("Всё дерево", "Всё, что известно о семье", fit_whole.bind(true)))
	_export_button = _button("PNG", "Сохранить всё дерево картинкой в папку «Изображения»", _on_export_pressed)
	bar.add_child(_export_button)
	var foot := HBoxContainer.new()
	foot.add_theme_constant_override("separation", 8)
	foot.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT, Control.PRESET_MODE_MINSIZE, 6)
	foot.grow_vertical = Control.GROW_DIRECTION_BEGIN
	foot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(foot)
	_status = Label.new()
	_status.text = "Колесо — масштаб · перетащите — сдвиг · щелчок — к родственнику"
	_status.add_theme_color_override("font_color", INK_DIM)
	_status.add_theme_font_size_override("font_size", 12)
	foot.add_child(_status)
	_open_folder = _button("Открыть папку", "Показать картинку в Finder", _on_open_folder)
	_open_folder.visible = false
	foot.add_child(_open_folder)
	_update_zoom_label()


func _button(text: String, tip: String, action: Callable) -> Button:
	var button := Button.new()
	button.text = text
	button.tooltip_text = tip
	button.focus_mode = Control.FOCUS_NONE
	button.pressed.connect(action)
	return button


## The family to draw (`FamilyTree.whole`). The view stays where it is while the animal stays the
## same; a new animal opens on its five generations - from where the old tree was looked at, when
## it was picked in it.
func show_family(tree: Dictionary, now: float, calendar: Array) -> void:
	var focus := int(tree.get("focus", -1))
	var changed := focus != _focus
	_tree = tree
	_focus = focus
	_nodes = tree.get("nodes", [])
	_cards.clear()
	_kinds.clear()
	for node in _nodes:
		var agent_id := int(node["id"])
		if not _cards.has(agent_id):
			_cards[agent_id] = FamilyTree.card(story, agent_id, now, calendar)
	for node in _nodes:
		var card: Dictionary = _cards[int(node["id"])]
		var kind := str(card.get("kind", ""))
		if str(node["role"]) == "child" and bool(card.get("known", false)):
			var mate := FamilyTree.mate_line(story, int(node["id"]), int(_nodes[int(node["link"])]["id"]))
			if mate != "":
				kind = mate
		_kinds.append(kind)
	_focus_line = FamilyTree.focus_line(story, focus) if focus >= 0 and story != null else ""
	_kinship = FamilyTree.parents_kinship(FamilyTree.around(story, focus)) if focus >= 0 and story != null else ""
	_pos = layout(tree)
	_bounds = bounds_of(_nodes, _pos)
	if _hover >= _nodes.size():
		_hover = -1
	if changed:
		_hover = -1
		_fitted = true
		if _picked_at != null:
			# The old animal stands where the picked one stood, mirrored: start from there.
			_center -= _picked_at
			_picked_at = null
			fit_default(true)
		else:
			fit_default(false)
	elif _fitted:
		fit_default(false)
	queue_redraw()


func focus_id() -> int:
	return _focus


func zoom() -> float:
	return _zoom


func center() -> Vector2:
	return _center


func node_positions() -> Array:
	return _pos


func tree_bounds() -> Rect2:
	return _bounds


## The first view: the generations `DEFAULT_GENERATIONS` each way, as close as they fit, not
## further than `DEFAULT_MIN_ZOOM` - then centred on the animal across.
func fit_default(animate := true) -> void:
	_fitted = true
	var rect := Rect2()
	var any := false
	for index in range(_nodes.size()):
		if absi(int(_nodes[index]["gen"])) <= DEFAULT_GENERATIONS:
			var box := node_rect(index)
			rect = box if not any else rect.merge(box)
			any = true
	if not any:
		return
	_fit(rect, DEFAULT_MIN_ZOOM, animate)


## The whole tree in the view, however small that makes it.
func fit_whole(animate := true) -> void:
	_fitted = false
	if not _nodes.is_empty():
		_fit(_bounds, MIN_ZOOM, animate)


func _fit(rect: Rect2, least: float, animate: bool) -> void:
	var room := _view_room().size
	if room.x <= 1.0 or room.y <= 1.0:
		return
	var goal := clampf(minf(room.x / rect.size.x, room.y / rect.size.y), least, FIT_MAX_ZOOM)
	var middle := rect.get_center()
	if rect.size.x * goal > room.x:
		# Too wide to fit at a readable size: the animal in the middle, the rest a pan away.
		middle.x = 0.0
	if rect.size.y * goal > room.y:
		middle.y = 0.0
	_set_view(goal, middle, animate)


## Zooms by `factor` about the middle of the view, eased.
func zoom_by(factor: float) -> void:
	_fitted = false
	var goal := clampf((_goal_zoom if _easing else _zoom) * factor, MIN_ZOOM, MAX_ZOOM)
	_set_view(goal, _goal_center if _easing else _center, true)


## Zooms to `goal` keeping the point under `screen` where it is, at once.
func zoom_at(screen: Vector2, goal: float) -> void:
	_fitted = false
	goal = clampf(goal, MIN_ZOOM, MAX_ZOOM)
	var anchor := to_world(screen)
	_set_view(goal, anchor - (screen - _view_middle()) / goal, false)


func _set_view(goal_zoom: float, goal_center: Vector2, animate: bool) -> void:
	_goal_zoom = goal_zoom
	_goal_center = _clamp_center(goal_center)
	if animate and is_inside_tree() and not exporting:
		_easing = true
		set_process(true)
	else:
		_easing = false
		_zoom = _goal_zoom
		_center = _goal_center
	_update_zoom_label()
	queue_redraw()


## The pan never loses the tree: the middle of the view stays over it.
func _clamp_center(point: Vector2) -> Vector2:
	if _bounds.size == Vector2.ZERO:
		return point
	return Vector2(clampf(point.x, _bounds.position.x, _bounds.end.x), clampf(point.y, _bounds.position.y, _bounds.end.y))


func _process(delta: float) -> void:
	if not _easing:
		set_process(false)
		return
	var t := 1.0 - exp(-delta * EASE_RATE)
	_zoom = exp(lerpf(log(_zoom), log(_goal_zoom), t))
	_center = _center.lerp(_goal_center, t)
	if absf(_zoom - _goal_zoom) < _goal_zoom * 0.002 and _center.distance_to(_goal_center) * _zoom < 0.5:
		_zoom = _goal_zoom
		_center = _goal_center
		_easing = false
	_update_zoom_label()
	queue_redraw()


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED and _fitted and not _nodes.is_empty():
		fit_default(false)


func _update_zoom_label() -> void:
	if _zoom_label != null:
		_zoom_label.text = "%d %%" % roundi(_goal_zoom * 100.0)


## Where the fits may put the tree: the sheet less the toolbar, the hint and a margin.
func _view_room() -> Rect2:
	var top := MARGIN if exporting else TOP_ROOM
	var bottom := MARGIN if exporting else BOTTOM_ROOM
	return Rect2(Vector2(MARGIN, top), size - Vector2(MARGIN * 2.0, top + bottom))


func _view_middle() -> Vector2:
	return _view_room().get_center()


func to_screen(point: Vector2) -> Vector2:
	return (point - _center) * _zoom + _view_middle()


func to_world(screen: Vector2) -> Vector2:
	return (screen - _view_middle()) / _zoom + _center


func box_size(index: int) -> Vector2:
	return FOCUS_BOX if index == 0 else BOX


## A node's box on the sheet, in the tree's own units.
func node_rect(index: int) -> Rect2:
	var box := box_size(index)
	return Rect2(Vector2(_pos[index]) - box * 0.5, box)


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var button: int = event.button_index
		if button == MOUSE_BUTTON_WHEEL_UP or button == MOUSE_BUTTON_WHEEL_DOWN:
			if event.pressed:
				var steps: float = event.factor if event.factor > 0.0 else 1.0
				var factor := pow(WHEEL_STEP, steps)
				zoom_at(event.position, _zoom * (factor if button == MOUSE_BUTTON_WHEEL_UP else 1.0 / factor))
			accept_event()
		elif button in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_MIDDLE, MOUSE_BUTTON_RIGHT]:
			if event.pressed:
				_press_button = button
				_press_at = event.position
				_dragging = false
			elif button == _press_button:
				if button == MOUSE_BUTTON_LEFT and not _dragging:
					_pick(event.position)
				_press_button = 0
				_dragging = false
				mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND if _hover >= 0 else Control.CURSOR_ARROW
			accept_event()
	elif event is InputEventMouseMotion:
		if _press_button != 0:
			if not _dragging and event.position.distance_to(_press_at) > DRAG_SLOP:
				_dragging = true
				mouse_default_cursor_shape = Control.CURSOR_DRAG
			if _dragging:
				_pan(-event.relative / _zoom)
				accept_event()
				return
		var over := _node_at(event.position)
		if over != _hover:
			_hover = over
			mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND if over >= 0 else Control.CURSOR_ARROW
			queue_redraw()
	elif event is InputEventPanGesture:
		# As on the map: two fingers zoom, with Shift they pan.
		if event.shift_pressed:
			_pan(event.delta * PAN_GESTURE_SPEED / _zoom)
		elif not is_zero_approx(event.delta.y):
			zoom_at(event.position, _zoom * exp(-event.delta.y * TRACKPAD_ZOOM))
		accept_event()
	elif event is InputEventMagnifyGesture:
		zoom_at(event.position, _zoom * clampf(event.factor, 0.5, 1.5))
		accept_event()


func _pan(by: Vector2) -> void:
	_fitted = false
	_easing = false
	_center = _clamp_center(_center + by)
	_goal_center = _center
	_goal_zoom = _zoom
	queue_redraw()


func _pick(screen: Vector2) -> void:
	var hit := _node_at(screen)
	if hit < 0:
		return
	if hit != 0:
		_picked_at = _pos[hit]
	picked.emit(int(_nodes[hit]["id"]))


## A known relative's node under a point of the view, or -1.
func _node_at(screen: Vector2) -> int:
	if _nodes.is_empty():
		return -1
	var point := to_world(screen)
	for index in range(_nodes.size()):
		if node_rect(index).has_point(point) and _known(int(_nodes[index]["id"])):
			return index
	return -1


## What the relative under the pointer inherited.
func _get_tooltip(at_position: Vector2) -> String:
	var hit := _node_at(at_position)
	if hit < 0:
		return ""
	return str(_cards.get(int(_nodes[hit]["id"]), {}).get("traits", ""))


func _known(agent_id: int) -> bool:
	return bool(_cards.get(agent_id, {}).get("known", false))


## «бабушки и деды», «внуки», «предки, 5-е колено».
static func generation_name(gen: int) -> String:
	match gen:
		-1:
			return "родители"
		-2:
			return "бабушки и деды"
		-3:
			return "прадеды"
		-4:
			return "прапрадеды"
		1:
			return "дети"
		2:
			return "внуки"
		3:
			return "правнуки"
		4:
			return "праправнуки"
	if gen == 0:
		return ""
	return "%s, %d-е колено" % ["предки" if gen < 0 else "потомки", absi(gen)]


## Each node's centre, node 0 at the origin, a generation `ROW_PITCH` from the next. Ancestors
## and descendants are laid out alike, each side its own tree grown from the animal: a node's
## branch (parents above, children below) side by side, each subtree pushed right of the ones
## before only as far as their rows need, and the node centred over its first and last.
static func layout(tree: Dictionary) -> Array:
	var nodes: Array = tree.get("nodes", [])
	var out: Array = []
	out.resize(nodes.size())
	if nodes.is_empty():
		return out
	var offsets := {}
	for key in ["up", "down"]:
		_contour(nodes, 0, key, offsets)
	out[0] = Vector2.ZERO
	var queue: Array = [0]
	while not queue.is_empty():
		var index := int(queue.pop_front())
		for key in ["up", "down"]:
			for branch in nodes[index][key]:
				out[branch] = Vector2(Vector2(out[index]).x + float(offsets[branch]), float(nodes[branch]["gen"]) * ROW_PITCH)
				queue.append(branch)
	return out


## The subtree from `index` along `key`: its rows' `[left, right]`, the nearest first, about the
## node's own centre; each branch node's place about it goes into `offsets`.
static func _contour(nodes: Array, index: int, key: String, offsets: Dictionary) -> Array:
	var half := (FOCUS_BOX.x if index == 0 else BOX.x) * 0.5
	var branch: Array = nodes[index][key]
	if branch.is_empty():
		return [[-half, half]]
	var merged: Array = []
	var places: Array = []
	for child in branch:
		var rows := _contour(nodes, int(child), key, offsets)
		var place := 0.0
		if not merged.is_empty():
			place = -INF
			for row in range(mini(merged.size(), rows.size())):
				var gap := SIBLING_GAP if row == 0 else COUSIN_GAP
				place = maxf(place, float(merged[row][1]) - float(rows[row][0]) + gap)
		places.append(place)
		for row in range(rows.size()):
			var left := float(rows[row][0]) + place
			var right := float(rows[row][1]) + place
			if row < merged.size():
				merged[row] = [minf(float(merged[row][0]), left), maxf(float(merged[row][1]), right)]
			else:
				merged.append([left, right])
	var middle := (float(places[0]) + float(places.back())) * 0.5
	for i in range(branch.size()):
		offsets[int(branch[i])] = float(places[i]) - middle
	var out: Array = [[-half, half]]
	for row in merged:
		out.append([float(row[0]) - middle, float(row[1]) - middle])
	return out


static func bounds_of(nodes: Array, positions: Array) -> Rect2:
	var rect := Rect2()
	for index in range(nodes.size()):
		var box := FOCUS_BOX if index == 0 else BOX
		var one := Rect2(Vector2(positions[index]) - box * 0.5, box)
		rect = one if index == 0 else rect.merge(one)
	return rect


func _font() -> Font:
	return font_override if font_override != null else get_theme_default_font()


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), SHEET, true)
	if not exporting:
		draw_rect(Rect2(Vector2.ZERO, size).grow(-0.5), SHEET_EDGE, false, 1.0)
	if _nodes.is_empty() or _pos.is_empty():
		return
	var font := _font()
	_draw_bands(font, false)
	var width := maxf(1.0, 1.6 * _zoom)
	for index in range(_nodes.size()):
		_draw_family_lines(index, width)
	if _hover >= 0:
		_draw_path(_hover)
	var view := Rect2(Vector2.ZERO, size)
	for index in range(_nodes.size()):
		var rect := Rect2(to_screen(node_rect(index).position), box_size(index) * _zoom)
		if not view.grow(24.0 * _zoom).intersects(rect):
			continue
		if index == 0:
			_draw_focus(rect, font)
		else:
			_draw_box(index, rect, font)
		if int(_nodes[index]["hidden"]) > 0:
			_draw_more(index, rect, font)
	_draw_bands(font, true)
	if exporting:
		_draw_title(font)


## A faint band behind every other generation; with `names`, each band's name at the left, kept
## in view as the band scrolls and drawn over the boxes.
func _draw_bands(font: Font, names: bool) -> void:
	var low := 0
	var high := 0
	for node in _nodes:
		low = mini(low, int(node["gen"]))
		high = maxi(high, int(node["gen"]))
	var label_size := roundi(LABEL_SIZE * (_zoom if exporting else 1.0))
	for gen in range(low, high + 1):
		var top := to_screen(Vector2(0.0, (gen - 0.5) * ROW_PITCH)).y
		var bottom := to_screen(Vector2(0.0, (gen + 0.5) * ROW_PITCH)).y
		if bottom < 0.0 or top > size.y:
			continue
		if gen % 2 != 0 and not names:
			draw_rect(Rect2(0.0, top, size.x, bottom - top), BAND, true)
		if not names:
			continue
		var name := generation_name(gen)
		if name == "" or bottom - top < label_size * 1.6:
			continue
		var text_size := font.get_string_size(name, HORIZONTAL_ALIGNMENT_LEFT, -1, label_size)
		var at := Vector2(8.0 * (_zoom if exporting else 1.0), maxf(top, 0.0) + label_size + 4.0)
		draw_rect(Rect2(at + Vector2(-4.0, -label_size - 1.0), text_size + Vector2(8.0, 4.0)), Color(SHEET, 0.85), true)
		draw_string(font, at, name, HORIZONTAL_ALIGNMENT_LEFT, -1, label_size, INK_FAINT)


## The lines from a node to its branch: down from the parents to a rule between the rows, along
## it, down into the child; or from the node down to a rule over its brood and into each.
func _draw_family_lines(index: int, width: float) -> void:
	for key in ["up", "down"]:
		var branch: Array = _nodes[index][key]
		if branch.is_empty():
			continue
		var xs: Array = []
		for other in branch:
			xs.append(to_screen(_pos[other]).x)
		var own := to_screen(_pos[index])
		var half := box_size(index).y * 0.5 * _zoom
		var near_edge := own.y - half if key == "up" else own.y + half
		var far_edge := to_screen(_pos[branch[0]]).y + (BOX.y * 0.5 * _zoom if key == "up" else -BOX.y * 0.5 * _zoom)
		var bus := (near_edge + far_edge) * 0.5
		draw_line(Vector2(own.x, near_edge), Vector2(own.x, bus), LINE, width)
		draw_line(Vector2(minf(own.x, xs.min()), bus), Vector2(maxf(own.x, xs.max()), bus), LINE, width)
		for x in xs:
			draw_line(Vector2(x, bus), Vector2(x, far_edge), LINE, width)


## The hovered relative's line down (or up) to the animal, lit.
func _draw_path(index: int) -> void:
	var width := maxf(2.0, 2.6 * _zoom)
	while index > 0:
		var link := int(_nodes[index]["link"])
		var own := to_screen(_pos[index])
		var other := to_screen(_pos[link])
		var up := int(_nodes[index]["gen"]) < 0
		var own_edge := own.y + (BOX.y * 0.5 * _zoom if up else -BOX.y * 0.5 * _zoom)
		var other_edge := other.y + (-1.0 if up else 1.0) * box_size(link).y * 0.5 * _zoom
		var bus := (own_edge + other_edge) * 0.5
		draw_polyline(PackedVector2Array([Vector2(own.x, own_edge), Vector2(own.x, bus), Vector2(other.x, bus),
			Vector2(other.x, other_edge)]), PATH, width)
		index = link


func _panel(rect: Rect2, fill: Color, border: Color, border_width: float, stripe: Color) -> void:
	var radius := maxi(1, roundi(4.0 * _zoom))
	draw_rect(Rect2(rect.position + Vector2(2.0, 3.0) * _zoom, rect.size), SHADOW, true)
	_box_style.bg_color = fill
	_box_style.border_color = border
	_box_style.set_border_width_all(maxi(1, roundi(border_width * maxf(_zoom, 0.6))))
	_box_style.set_corner_radius_all(radius)
	_box_style.anti_aliasing = true
	draw_style_box(_box_style, rect)
	if stripe.a > 0.0:
		_stripe_style.bg_color = stripe
		_stripe_style.corner_radius_top_left = radius
		_stripe_style.corner_radius_bottom_left = radius
		_stripe_style.corner_radius_top_right = 0
		_stripe_style.corner_radius_bottom_right = 0
		draw_style_box(_stripe_style, Rect2(rect.position, Vector2(maxf(2.0, 6.0 * _zoom), rect.size.y)))


func _draw_box(index: int, rect: Rect2, font: Font) -> void:
	var agent_id := int(_nodes[index]["id"])
	var card: Dictionary = _cards.get(agent_id, {})
	var known := bool(card.get("known", false))
	var dead := bool(card.get("dead", false))
	var lit := _hover >= 0 and agent_id >= 0 and int(_nodes[_hover]["id"]) == agent_id
	var sex_colour: Color = STRIPE.get(str(card.get("sex", "")), INK_FAINT)
	if rect.size.x < MIN_DETAIL_WIDTH:
		draw_rect(rect, (PAPER_DEAD if dead else sex_colour) if known else PAPER_UNKNOWN, true)
		return
	var fill := PAPER_UNKNOWN if not known else (PAPER_HOVER if lit else (PAPER_DEAD if dead else PAPER))
	var pinned := bool(card.get("pinned", false))
	var border := PINNED if pinned else (PATH if lit else (INK_DIM if known else INK_FAINT))
	_panel(rect, fill, border, 2.0 if pinned or lit else 1.0, (STRIPE_DEAD if dead else sex_colour) if known else Color(0, 0, 0, 0))
	if pinned:
		_draw_pin(rect)
	var name_size := floori(NAME_SIZE * _zoom)
	var line_size := floori(LINE_SIZE * _zoom)
	if line_size < MIN_TEXT:
		_far_name(rect, font, str(card.get("name", "")) if known else "?", maxi(FAR_NAME_SIZE, name_size),
			INK_DIM if dead or not known else INK)
		return
	var left := rect.position.x + 14.0 * _zoom
	var room := rect.size.x - 22.0 * _zoom
	if not known:
		var unknown := "неизвестно"
		if index > 0 and int(_nodes[index]["link"]) == 0:
			unknown = "мать неизвестна" if str(_nodes[index]["role"]) == "mother" else "отец неизвестен"
		_text(font, Vector2(left, rect.position.y + 37.0 * _zoom), unknown, room, line_size, INK_DIM)
		return
	var ink := INK_DIM if dead else INK
	var name_end := _text(font, Vector2(left, rect.position.y + 21.0 * _zoom), str(card.get("name", "")), room - name_size, name_size, ink)
	_text(font, Vector2(name_end + 4.0 * _zoom, rect.position.y + 21.0 * _zoom), str(card.get("glyph", "")), name_size,
		name_size, Color(sex_colour, 0.55) if dead else sex_colour)
	_text(font, Vector2(left, rect.position.y + 39.0 * _zoom), str(_kinds[index]), room, line_size, INK_DIM)
	_text(font, Vector2(left, rect.position.y + 56.0 * _zoom), str(card.get("status", "")), room, line_size,
		KIN if dead and str(card.get("status", "")).begins_with("†") else INK_DIM)


## The animal itself: larger, warmer, its name bigger; its kind and age, its family, and a note
## when its parents are kin - or that they are not known.
func _draw_focus(rect: Rect2, font: Font) -> void:
	var card: Dictionary = _cards.get(_focus, {})
	var dead := bool(card.get("dead", false))
	var pinned := bool(card.get("pinned", false))
	var lit := _hover == 0
	var sex_colour: Color = STRIPE.get(str(card.get("sex", "")), INK_FAINT)
	if rect.size.x < MIN_DETAIL_WIDTH:
		draw_rect(rect, PATH, true)
		return
	draw_rect(rect.grow(4.0 * _zoom), Color(PATH, 0.16), true)
	_panel(rect, PAPER_HOVER if lit else (PAPER_DEAD if dead else PAPER_FOCUS), PINNED if pinned else INK, 2.0,
		STRIPE_DEAD if dead else sex_colour)
	if pinned:
		_draw_pin(rect)
	var name_size := floori((NAME_SIZE + 4) * _zoom)
	var line_size := floori(LINE_SIZE * _zoom)
	if line_size < MIN_TEXT:
		_far_name(rect, font, str(card.get("name", "")), maxi(FAR_NAME_SIZE + 2, name_size), INK)
		return
	var left := rect.position.x + 16.0 * _zoom
	var room := rect.size.x - 26.0 * _zoom
	var ink := INK_DIM if dead else INK
	var name_end := _text(font, Vector2(left, rect.position.y + 25.0 * _zoom), str(card.get("name", "")), room - name_size, name_size, ink)
	_text(font, Vector2(name_end + 5.0 * _zoom, rect.position.y + 25.0 * _zoom), str(card.get("glyph", "")), name_size, name_size, sex_colour)
	var about := " · ".join([str(card.get("kind", "")), str(card.get("status", ""))].filter(func(part): return part != ""))
	_text(font, Vector2(left, rect.position.y + 45.0 * _zoom), about, room, line_size, INK_DIM)
	_text(font, Vector2(left, rect.position.y + 64.0 * _zoom), _focus_line, room, line_size, INK)
	var founder: bool = _nodes[0]["up"].is_empty()
	var note := "родители неизвестны" if founder else _kinship
	if note != "":
		_text(font, Vector2(left, rect.position.y + 83.0 * _zoom), note, room, line_size, INK_DIM if founder else KIN)


## A far box's name alone, small but readable, in the middle of the box.
func _far_name(rect: Rect2, font: Font, text: String, font_size: int, colour: Color) -> void:
	if rect.size.y < font_size + 2:
		return
	var left := rect.position.x + maxf(3.0, 10.0 * _zoom)
	_text(font, Vector2(left, rect.get_center().y + font_size * 0.35), text, rect.end.x - left - 2.0, font_size, colour)


func _draw_pin(rect: Rect2) -> void:
	var at := Vector2(rect.end.x - 9.0 * _zoom, rect.position.y + 9.0 * _zoom)
	draw_circle(at, maxf(2.0, 4.0 * _zoom), PINNED)


## «ещё 5»: the relatives past the limits, in a tag beyond the box.
func _draw_more(index: int, rect: Rect2, font: Font) -> void:
	var text_size := floori(11 * _zoom)
	if text_size < MIN_TEXT:
		return
	var text := "ещё %d" % int(_nodes[index]["hidden"])
	var width := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, text_size).x + 12.0 * _zoom
	var tag_height := text_size + 6.0 * _zoom
	var down := int(_nodes[index]["gen"]) >= 0
	var stem := 10.0 * _zoom
	var x := rect.get_center().x
	var edge := rect.end.y if down else rect.position.y
	var tag_top := edge + stem if down else edge - stem - tag_height
	draw_line(Vector2(x, edge), Vector2(x, edge + (stem if down else -stem)), LINE, maxf(1.0, _zoom))
	var tag := Rect2(x - width * 0.5, tag_top, width, tag_height)
	_box_style.bg_color = PAPER_DEAD
	_box_style.border_color = INK_FAINT
	_box_style.set_border_width_all(1)
	_box_style.set_corner_radius_all(roundi(tag_height * 0.5))
	draw_style_box(_box_style, tag)
	draw_string(font, Vector2(tag.position.x + 6.0 * _zoom, tag.end.y - 4.0 * _zoom), text, HORIZONTAL_ALIGNMENT_LEFT,
		-1, text_size, INK_DIM)


## Draws `text` from `at`, cut with «…» to `room`; returns where it ended.
func _text(font: Font, at: Vector2, text: String, room: float, font_size: int, colour: Color) -> float:
	if text == "" or font_size < MIN_TEXT:
		return at.x
	var width := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
	if width > room:
		while text.length() > 1 and font.get_string_size(text + "…", HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x > room:
			text = text.substr(0, text.length() - 1)
		text = text.strip_edges() + "…"
		width = font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
	draw_string(font, at, text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, colour)
	return at.x + width


func _draw_title(font: Font) -> void:
	var scale := _zoom
	draw_string(font, Vector2(EXPORT_MARGIN, 38.0) * scale, title_text, HORIZONTAL_ALIGNMENT_LEFT, -1, roundi(24 * scale), INK)
	draw_string(font, Vector2(EXPORT_MARGIN, 60.0) * scale, subtitle_text, HORIZONTAL_ALIGNMENT_LEFT, -1, roundi(13 * scale), INK_DIM)


## The picture's scale: `EXPORT_SCALE`, less when the tree would come out wider or taller than
## `EXPORT_MAX_PIXELS`.
static func export_scale(tree_size: Vector2) -> float:
	var sheet := tree_size + Vector2(EXPORT_MARGIN * 2.0, EXPORT_MARGIN * 2.0 + EXPORT_HEADER)
	return minf(EXPORT_SCALE, EXPORT_MAX_PIXELS / maxf(sheet.x, sheet.y))


## «Родословная — Ветка, олениха»; under it how big the tree is.
func _export_titles() -> Array:
	var card: Dictionary = _cards.get(_focus, {})
	var title := "Родословная — %s" % card.get("name", "")
	if str(card.get("kind", "")) != "":
		title += ", %s" % card.get("kind", "")
	var gens_up := 0
	var gens_down := 0
	for node in _nodes:
		gens_up = maxi(gens_up, -int(node["gen"]))
		gens_down = maxi(gens_down, int(node["gen"]))
	var ancestors := int(_tree.get("ancestors", 0))
	var descendants := int(_tree.get("descendants", 0))
	var subtitle := "%d %s в %d %s вверх · %d %s в %d %s вниз" % [
		ancestors, HudText.plural(ancestors, ["предок", "предка", "предков"]),
		gens_up, HudText.plural(gens_up, ["поколении", "поколениях", "поколениях"]),
		descendants, HudText.plural(descendants, ["потомок", "потомка", "потомков"]),
		gens_down, HudText.plural(gens_down, ["поколении", "поколениях", "поколениях"])]
	return [title, subtitle]


## The whole tree drawn once more off screen, at `export_scale`, under a title, and saved as a
## PNG at `path`. Needs a renderer: false headless.
func export_png(path: String) -> bool:
	if _nodes.is_empty() or DisplayServer.get_name() == "headless":
		return false
	var scale := export_scale(_bounds.size)
	var sheet := (_bounds.size + Vector2(EXPORT_MARGIN * 2.0, EXPORT_MARGIN * 2.0 + EXPORT_HEADER)) * scale
	var viewport := SubViewport.new()
	viewport.size = Vector2i(ceili(sheet.x), ceili(sheet.y))
	viewport.transparent_bg = false
	viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	var painter: FamilyTreeView = (get_script() as Script).new()
	painter.exporting = true
	painter.font_override = _font()
	var titles := _export_titles()
	painter.title_text = titles[0]
	painter.subtitle_text = titles[1]
	painter._tree = _tree
	painter._nodes = _nodes
	painter._pos = _pos
	painter._cards = _cards
	painter._kinds = _kinds
	painter._bounds = _bounds
	painter._focus = _focus
	painter._focus_line = _focus_line
	painter._kinship = _kinship
	painter._zoom = scale
	painter._fitted = false
	# The tree's top-left at the margin under the header; the view's middle is the sheet's.
	painter._center = _bounds.position + (sheet * 0.5 - Vector2(EXPORT_MARGIN, EXPORT_MARGIN + EXPORT_HEADER) * scale) / scale
	viewport.add_child(painter)
	painter.size = sheet
	add_child(viewport)
	await RenderingServer.frame_post_draw
	var image := viewport.get_texture().get_image()
	viewport.queue_free()
	return image != null and not image.is_empty() and image.save_png(path) == OK


## A new file for the picture: «Родословная Ветка 2026-10-28-14-55-12.png».
func export_path() -> String:
	var folder := folder_override if folder_override != "" else PhotoModeScript.pictures_folder()
	var name := str(_cards.get(_focus, {}).get("name", "")).replace("/", "-").strip_edges()
	var stamp := Time.get_datetime_string_from_system(false, true).replace(":", "-").replace(" ", "-")
	var path := "%s/Родословная %s %s.png" % [folder, name, stamp]
	var index := 2
	while FileAccess.file_exists(path):
		path = "%s/Родословная %s %s-%d.png" % [folder, name, stamp, index]
		index += 1
	return path


func _on_export_pressed() -> void:
	if _nodes.is_empty():
		return
	_export_button.disabled = true
	_status.text = "Сохраняю…"
	var path := export_path()
	var ok: bool = await export_png(path)
	_export_button.disabled = false
	_last_path = path if ok else ""
	_status.text = "Сохранено: %s" % path.get_file() if ok else "Не удалось сохранить картинку"
	_open_folder.visible = ok


func _on_open_folder() -> void:
	if _last_path != "":
		OS.shell_show_in_file_manager(ProjectSettings.globalize_path(_last_path))
