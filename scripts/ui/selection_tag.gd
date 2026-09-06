class_name SelectionTag
extends Control

## The label that rides above the selected animal - name, what it is doing, and the
## three vital bars - so none of that needs the HUD to be open.
##
## Drawn in viewport space rather than in the world: the text then keeps one size at
## every zoom level, which is the whole point of a readout. Only the anchor comes
## from the world, converted once per frame through the canvas transform.
##
## The anchor is `AgentSpriteRenderer.get_render_position()` and never
## `agent.position`. The simulation steps at the tick rate while the sprite glides
## between ticks, so the raw position reads as a tag vibrating beside an otherwise
## smooth animal.

## How far above the animal's feet the tag sits, in canvas units. Canvas rather than
## screen units on purpose: it scales with the sprite, so the tag stays on the head
## instead of sliding down into the body as the camera pulls back.
const LIFT_PX := 30.0
const PADDING := Vector2(8.0, 5.0)
const BAR_WIDTH := 92.0
const BAR_HEIGHT := 4.0
const BAR_SPACING := 2.0
const LINE_GAP := 3.0
## Keeps the tag from being drawn far outside the viewport while the camera is
## somewhere else entirely.
const OFFSCREEN_MARGIN := 240.0

var simulation_manager: SimulationManager
var _agent_renderer: Node2D
var _screen_point: Vector2 = Vector2.ZERO
var _visible_now: bool = false
var _title: String = ""
var _action: String = ""
var _vitals: Array = []


func _ready() -> void:
	# Anything but IGNORE here would put a full-screen control under the cursor, and
	# GameCamera._is_pointer_over_ui() would stop the wheel from zooming the world.
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_process(false)


func bind_manager(manager: SimulationManager) -> void:
	simulation_manager = manager
	if not simulation_manager.selection_changed.is_connected(_on_selection_changed):
		simulation_manager.selection_changed.connect(_on_selection_changed)
	if not simulation_manager.tick_completed.is_connected(_on_tick_completed):
		simulation_manager.tick_completed.connect(_on_tick_completed)
	set_process(true)
	_refresh_values()


func bind_agent_renderer(renderer: Node2D) -> void:
	_agent_renderer = renderer


## The position has to be recomputed every frame because the animal moves every
## frame; the numbers do not, and are refreshed on the tick signal instead.
func _process(_delta: float) -> void:
	var agent = _selected_agent()
	if agent == null:
		if _visible_now:
			_visible_now = false
			queue_redraw()
		return

	var world_position: Vector2 = _agent_renderer.get_render_position(agent)
	var canvas_point: Vector2 = WorldProjection.to_screen(world_position, _height_at(world_position))
	canvas_point.y -= LIFT_PX
	_screen_point = get_viewport().get_canvas_transform() * canvas_point

	var on_screen := get_viewport_rect().grow(OFFSCREEN_MARGIN).has_point(_screen_point)
	if not on_screen:
		if _visible_now:
			_visible_now = false
			queue_redraw()
		return

	_visible_now = true
	queue_redraw()


func _draw() -> void:
	if not _visible_now:
		return

	var font := get_theme_default_font()
	var font_size := get_theme_default_font_size()
	if font == null:
		return

	var title_size := font.get_string_size(_title, HORIZONTAL_ALIGNMENT_LEFT, -1.0, font_size)
	var action_size := font.get_string_size(_action, HORIZONTAL_ALIGNMENT_LEFT, -1.0, font_size)
	var bars_height := float(_vitals.size()) * (BAR_HEIGHT + BAR_SPACING) - BAR_SPACING
	var content_width := maxf(BAR_WIDTH, maxf(title_size.x, action_size.x))
	var content_height := title_size.y + LINE_GAP + action_size.y + LINE_GAP + bars_height
	var box_size := Vector2(content_width, content_height) + PADDING * 2.0

	# The anchor is the animal's head, so the box hangs above it and centred on it.
	var box_origin := Vector2(_screen_point.x - box_size.x * 0.5, _screen_point.y - box_size.y)
	draw_rect(Rect2(box_origin, box_size), PixelUiTheme.TAG_BACKDROP)

	var cursor := box_origin + PADDING
	draw_string(font, cursor + Vector2(0.0, font.get_ascent(font_size)), _title,
		HORIZONTAL_ALIGNMENT_LEFT, -1.0, font_size, PixelUiTheme.TAG_INK)
	cursor.y += title_size.y + LINE_GAP
	draw_string(font, cursor + Vector2(0.0, font.get_ascent(font_size)), _action,
		HORIZONTAL_ALIGNMENT_LEFT, -1.0, font_size, PixelUiTheme.TAG_INK_DIM)
	cursor.y += action_size.y + LINE_GAP
	AgentReadout.draw_bars(self, cursor, content_width, BAR_HEIGHT, BAR_SPACING, _vitals)


func _on_selection_changed(_agent_id: int) -> void:
	_refresh_values()


## Text and bars follow the HUD's refresh cadence rather than the frame rate: the
## values only change on a tick, and redrawing them at 60 Hz makes them flicker.
func _on_tick_completed(tick: int, _snapshot: Dictionary) -> void:
	if simulation_manager != null and not simulation_manager.should_refresh_ui_on_tick(tick):
		return
	_refresh_values()


func _refresh_values() -> void:
	var agent = _selected_agent()
	if agent == null:
		_title = ""
		_action = ""
		_vitals = []
		return
	_title = AgentReadout.title(agent)
	_action = AgentReadout.action_label(agent)
	_vitals = AgentReadout.vitals(agent)


## Null whenever there is nothing to draw. The selected agent can die between
## frames, in which case the manager clears the selection and this goes quiet; and
## `world_state` is null while the setup screen is up, before anything exists.
func _selected_agent():
	if simulation_manager == null or _agent_renderer == null:
		return null
	if simulation_manager.world_state == null:
		return null
	var agent = simulation_manager.get_selected_agent()
	if agent == null or not agent.is_alive:
		return null
	return agent


## Read off the world each time rather than cached at bind time: restarting builds a
## new `world_state`, and the renderers are refreshed rather than rebound, so a
## cached terrain would keep answering for the previous world's heightmap.
func _height_at(world_position: Vector2) -> int:
	if WorldProjection.is_identity():
		return 0
	var terrain = simulation_manager.world_state.terrain_system
	if terrain == null:
		return 0
	return terrain.get_height_at_position(world_position)
