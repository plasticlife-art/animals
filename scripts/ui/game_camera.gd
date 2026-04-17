class_name GameCamera
extends Camera2D

const ZOOM_IN_FACTOR := 0.9
const ZOOM_OUT_FACTOR := 1.1
const CAMERA_BOUNDS_PADDING := 16.0

@export var pan_speed: float = 900.0
@export var max_zoom_in_ratio: float = 0.35
@export var trackpad_pan_speed: float = 1.0
@export var trackpad_zoom_sensitivity: float = 0.08
@export var follow_smoothing_speed: float = 7.5

var world_bounds: Rect2 = Rect2()
var camera_bounds: Rect2 = Rect2()
var input_enabled: bool = true
var simulation_manager: SimulationManager
var _zoom_in_limit: float = 0.35
var _zoom_out_limit: float = 1.0
var _dragging: bool = false
var _last_mouse_position: Vector2 = Vector2.ZERO


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	set_process_input(true)
	make_current()


func set_input_enabled(value: bool) -> void:
	input_enabled = value
	if not input_enabled:
		_dragging = false


func bind_manager(manager: SimulationManager) -> void:
	simulation_manager = manager


func reset_to_world(bounds: Rect2) -> void:
	world_bounds = bounds
	camera_bounds = world_bounds.grow(CAMERA_BOUNDS_PADDING)
	_dragging = false
	make_current()
	_recalculate_zoom_limits()
	_set_zoom_factor(_zoom_out_limit)
	global_position = world_bounds.get_center()
	_clamp_to_bounds()


func get_visible_world_rect() -> Rect2:
	if world_bounds.size.is_zero_approx():
		return Rect2()
	return _get_camera_view_rect().intersection(world_bounds)


func _process(delta: float) -> void:
	if not input_enabled or world_bounds.size.is_zero_approx():
		return

	var direction := Input.get_vector("camera_left", "camera_right", "camera_up", "camera_down")
	if direction == Vector2.ZERO:
		direction = _get_fallback_direction()
	if direction != Vector2.ZERO:
		_clear_focus_if_active()
		global_position += direction.normalized() * pan_speed * zoom.x * delta
		_clamp_to_bounds()
		return
	if _is_follow_active():
		var focus_position = simulation_manager.get_focus_position()
		if focus_position != null:
			var weight := clampf(follow_smoothing_speed * delta, 0.0, 1.0)
			global_position = global_position.lerp(focus_position, weight)
			_clamp_to_bounds()
			return
		simulation_manager.clear_focus()
		return

	return


func _input(event: InputEvent) -> void:
	if not input_enabled or world_bounds.size.is_zero_approx():
		return

	if event is InputEventPanGesture:
		if _is_pointer_over_ui():
			return
		if event.shift_pressed:
			_handle_trackpad_pan(event.delta)
		else:
			_handle_trackpad_zoom(event.delta.y)
		get_viewport().set_input_as_handled()
	elif event is InputEventMagnifyGesture:
		if not _is_pointer_over_ui():
			var factor := clampf(event.factor, 0.5, 1.5)
			_set_zoom_factor(zoom.x / factor, _get_zoom_anchor_screen_position())
			get_viewport().set_input_as_handled()
	elif event is InputEventMouseButton:
		match event.button_index:
			MOUSE_BUTTON_WHEEL_UP:
				if event.pressed and not _is_pointer_over_ui():
					_set_zoom_factor(zoom.x * ZOOM_IN_FACTOR, _get_zoom_anchor_screen_position())
					get_viewport().set_input_as_handled()
			MOUSE_BUTTON_WHEEL_DOWN:
				if event.pressed and not _is_pointer_over_ui():
					_set_zoom_factor(zoom.x * ZOOM_OUT_FACTOR, _get_zoom_anchor_screen_position())
					get_viewport().set_input_as_handled()
			MOUSE_BUTTON_MIDDLE:
				if event.pressed:
					if _is_pointer_over_ui():
						_dragging = false
						return
					_dragging = true
					_last_mouse_position = event.position
					get_viewport().set_input_as_handled()
				else:
					_dragging = false
	elif event is InputEventMouseMotion and _dragging:
		var mouse_delta: Vector2 = event.position - _last_mouse_position
		_last_mouse_position = event.position
		_clear_focus_if_active()
		global_position -= mouse_delta * zoom.x
		_clamp_to_bounds()
		get_viewport().set_input_as_handled()


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_SIZE_CHANGED and not world_bounds.size.is_zero_approx():
		_recalculate_zoom_limits()
		_set_zoom_factor(zoom.x)


func _get_fallback_direction() -> Vector2:
	var direction := Vector2.ZERO
	if Input.is_key_pressed(KEY_A):
		direction.x -= 1.0
	if Input.is_key_pressed(KEY_D):
		direction.x += 1.0
	if Input.is_key_pressed(KEY_W):
		direction.y -= 1.0
	if Input.is_key_pressed(KEY_S):
		direction.y += 1.0
	return direction


func _is_pointer_over_ui() -> bool:
	var hovered = get_viewport().gui_get_hovered_control()
	return hovered != null


func _handle_trackpad_pan(delta: Vector2) -> void:
	_clear_focus_if_active()
	global_position -= delta * zoom.x * trackpad_pan_speed
	_clamp_to_bounds()


func _handle_trackpad_zoom(vertical_delta: float) -> void:
	if is_zero_approx(vertical_delta):
		return
	var zoom_multiplier := exp(-vertical_delta * trackpad_zoom_sensitivity)
	_set_zoom_factor(zoom.x * zoom_multiplier, _get_zoom_anchor_screen_position())


func _recalculate_zoom_limits() -> void:
	var viewport_size := get_viewport_rect().size
	if viewport_size.x <= 0.0 or viewport_size.y <= 0.0:
		_zoom_out_limit = 1.0
		_zoom_in_limit = max_zoom_in_ratio
		return

	_zoom_out_limit = maxf(camera_bounds.size.x / viewport_size.x, camera_bounds.size.y / viewport_size.y)
	_zoom_out_limit = maxf(_zoom_out_limit, 0.1)
	_zoom_in_limit = minf(_zoom_out_limit, maxf(0.1, _zoom_out_limit * max_zoom_in_ratio))


func _set_zoom_factor(value: float, anchor_screen_position: Variant = null) -> void:
	var clamped := clampf(value, _zoom_in_limit, _zoom_out_limit)
	var anchor_world_before = null
	if anchor_screen_position is Vector2:
		anchor_world_before = _screen_to_world(anchor_screen_position)
	zoom = Vector2.ONE * clamped
	if anchor_world_before != null:
		var anchor_world_after: Vector2 = _screen_to_world(anchor_screen_position)
		global_position += anchor_world_before - anchor_world_after
	_clamp_to_bounds()


func _clamp_to_bounds() -> void:
	if camera_bounds.size.is_zero_approx():
		return

	var view_rect := _get_camera_view_rect()
	var half_extents := view_rect.size * 0.5
	var center := camera_bounds.get_center()

	if half_extents.x * 2.0 >= camera_bounds.size.x:
		global_position.x = center.x
	else:
		global_position.x = clampf(
			global_position.x,
			camera_bounds.position.x + half_extents.x,
			camera_bounds.end.x - half_extents.x
		)

	if half_extents.y * 2.0 >= camera_bounds.size.y:
		global_position.y = center.y
	else:
		global_position.y = clampf(
			global_position.y,
			camera_bounds.position.y + half_extents.y,
			camera_bounds.end.y - half_extents.y
		)


func _is_follow_active() -> bool:
	return simulation_manager != null and simulation_manager.focus_mode != "off"


func _clear_focus_if_active() -> void:
	if _is_follow_active():
		simulation_manager.clear_focus()


func _get_camera_view_rect() -> Rect2:
	var viewport_rect := get_viewport_rect()
	var inverse_canvas := get_canvas_transform().affine_inverse()
	var top_left: Vector2 = inverse_canvas * viewport_rect.position
	var bottom_right: Vector2 = inverse_canvas * viewport_rect.end
	return Rect2(top_left, bottom_right - top_left)


func _get_zoom_anchor_screen_position():
	var viewport_rect := get_viewport_rect()
	var mouse_position := get_viewport().get_mouse_position()
	if not viewport_rect.has_point(mouse_position):
		return null
	return mouse_position


func _screen_to_world(screen_position: Vector2) -> Vector2:
	return get_canvas_transform().affine_inverse() * screen_position
