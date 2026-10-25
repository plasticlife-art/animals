class_name WardTags
extends Control

## The viewers' wards on the map, always: a ring at each one's feet in the colour of the fund its
## guardian backs (`ReserveSession`, white for none), and its name with the guardian's above it.
## Where names would cover each other, the nearer the bottom of the screen keeps its name and the
## others keep their rings; the selected animal has its own tag (`SelectionTag`) and keeps only the
## ring. Only wards awake on the map are drawn: one asleep far off is not in view anyway.
##
## Drawn in viewport space like `SelectionTag`, anchored on the sprite's gliding position
## (`AgentSpriteRenderer.get_render_position()`), so the text keeps one size at every zoom.

const LIFT_PX := 26.0
const PADDING := Vector2(5.0, 2.0)
## The ring's radius in canvas units, so it grows and shrinks with the sprite.
const RING_RADIUS := 13.0
const RING_WIDTH := 2.0
const NO_FUND := Color(0.97, 0.93, 0.82)
const OFFSCREEN_MARGIN := 40.0
## About the size of `SelectionTag`'s box, kept clear above the selected animal.
const SELECTED_TAG := Vector2(190.0, 70.0)

var simulation_manager = null
var session = null
var _agent_renderer: Node2D = null
var _fund_colors: Dictionary = {}
## What to draw this frame: `[screen point, ring radius, colour, label or ""]`.
var _marks: Array = []
## Where the selected animal's own tag stands this frame, kept clear of names; empty without.
var _selected_box := Rect2()


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)


func bind(manager, agent_renderer: Node2D, reserve_session) -> void:
	simulation_manager = manager
	_agent_renderer = agent_renderer
	session = reserve_session
	_fund_colors.clear()
	var visuals: Dictionary = manager.config_bundle.get("visuals", {}).get("species", {})
	for species in visuals.keys():
		var rgba: Array = visuals[species].get("ui_color", [])
		if rgba.size() >= 3:
			_fund_colors[str(species)] = Color(float(rgba[0]), float(rgba[1]), float(rgba[2]))


func _process(_delta: float) -> void:
	var had := not _marks.is_empty()
	_marks.clear()
	if simulation_manager == null or simulation_manager.world_state == null or _agent_renderer == null:
		if had:
			queue_redraw()
		return
	var world = simulation_manager.world_state
	var canvas: Transform2D = get_viewport().get_canvas_transform()
	var view := get_viewport_rect().grow(OFFSCREEN_MARGIN)
	var ring := RING_RADIUS * canvas.get_scale().x
	var selected: int = simulation_manager.selected_agent_id
	_selected_box = Rect2()
	var chosen = world.get_agent(selected) if selected >= 0 else null
	if chosen != null and chosen.is_alive:
		var head: Vector2 = canvas * WorldProjection.to_screen(_agent_renderer.get_render_position(chosen),
			_height_at(world, chosen.position))
		_selected_box = Rect2(head + Vector2(-SELECTED_TAG.x * 0.5, -SelectionTag.LIFT_PX * canvas.get_scale().y - SELECTED_TAG.y),
			SELECTED_TAG)
	for id in world.adoptions.keys():
		var ward: Dictionary = world.adoptions[id]
		if float(ward.get("died_at", -1.0)) >= 0.0:
			continue
		var agent = world.get_agent(int(id))
		if agent == null or not agent.is_alive:
			continue
		var at: Vector2 = _agent_renderer.get_render_position(agent)
		var feet: Vector2 = canvas * WorldProjection.to_screen(at, _height_at(world, at))
		if not view.has_point(feet):
			continue
		var label := "" if int(id) == selected else _label(ward)
		_marks.append([feet, ring, _fund_color(str(ward.get("viewer", ""))), label])
	if had or not _marks.is_empty():
		queue_redraw()


func _draw() -> void:
	if _marks.is_empty():
		return
	var font := get_theme_default_font()
	var font_size := get_theme_default_font_size()
	# Nearest the bottom of the screen first: the one in front keeps its name.
	_marks.sort_custom(func(a, b) -> bool: return a[0].y > b[0].y or (a[0].y == b[0].y and a[0].x < b[0].x))
	# The rings first, then the names over them.
	for mark in _marks:
		var radius: float = clampf(mark[1], 5.0, 26.0)
		draw_arc(mark[0], radius, 0.0, TAU, 24, Color(0.0, 0.0, 0.0, 0.55), RING_WIDTH + 2.0)
		draw_arc(mark[0], radius, 0.0, TAU, 24, mark[2], RING_WIDTH)
	var taken: Array = [_selected_box] if _selected_box.has_area() else []
	for mark in _marks:
		var feet: Vector2 = mark[0]
		var radius: float = clampf(mark[1], 5.0, 26.0)
		var text: String = mark[3]
		if text == "" or font == null:
			continue
		var size := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, font_size) + PADDING * 2.0
		var box := Rect2(Vector2(feet.x - size.x * 0.5, feet.y - LIFT_PX * maxf(1.0, radius / RING_RADIUS) - size.y), size)
		var clear := true
		for other in taken:
			if box.intersects(other):
				clear = false
				break
		if not clear:
			continue
		taken.append(box)
		draw_rect(box, PixelUiTheme.TAG_BACKDROP)
		draw_rect(Rect2(box.position, Vector2(3.0, box.size.y)), mark[2])
		draw_string(font, box.position + PADDING + Vector2(1.0, font.get_ascent(font_size)), text,
			HORIZONTAL_ALIGNMENT_LEFT, -1.0, font_size, PixelUiTheme.TAG_INK)


## «Ветка · Вася»: the ward's name and its guardian's.
static func _label(ward: Dictionary) -> String:
	var guardian := str(ward.get("viewer_name", ""))
	return str(ward.get("name", "")) if guardian == "" else "%s · %s" % [str(ward.get("name", "")), guardian]


## The colour of the fund `viewer` backs, from the species' own (`visuals.species.*.ui_color`).
func _fund_color(viewer: String) -> Color:
	if session == null:
		return NO_FUND
	var team := str(session.book.viewers.get(viewer, {}).get("team", ""))
	return _fund_colors.get(team, NO_FUND)


static func _height_at(world, at: Vector2) -> int:
	if WorldProjection.is_identity() or world.terrain_system == null:
		return 0
	return world.terrain_system.get_height_at_position(at)
