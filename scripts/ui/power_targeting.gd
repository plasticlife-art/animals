class_name PowerTargeting
extends Node2D

## The aim of a power on the map (`PowerAim`): under the pointer, the pond that would be dug -
## green where it can go, red where it cannot - or the flag the herd would be led to, with a line
## from the herd. While a power is aimed it takes the left click before the world's selection
## does (it stands after `WorldView` in the scene, and unhandled input reaches later nodes
## first); the right click or Esc stops aiming. `MainController` stops it under the pause menu,
## help, the chronicle, photo mode and a paused game.

signal aim_changed

const OK_COLOR := Color(0.35, 0.8, 0.45)
const BAD_COLOR := Color(0.9, 0.3, 0.25)
const CIRCLE_POINTS := 48
## Where a cull's count stands from the pointer: right of it and below the arrow.
const LABEL_OFFSET := Vector2(18.0, 30.0)

var simulation_manager = null
var aim := PowerAim.new()
var input_enabled: bool = true
## Where the aim is drawn instead of the pointer, in canvas space: for a capture that must not
## move the player's cursor. INF follows the pointer.
var pointer_override := Vector2.INF


func bind_manager(manager) -> void:
	simulation_manager = manager


func arm(power: String) -> bool:
	var armed := aim.arm(simulation_manager, power)
	queue_redraw()
	aim_changed.emit()
	return armed


func cancel() -> void:
	if not aim.is_armed() and aim.message == "":
		return
	aim.cancel()
	queue_redraw()
	aim_changed.emit()


func is_armed() -> bool:
	return aim.is_armed()


## The order for a click at `screen_position` (the canvas, as the mouse reports it).
func click(screen_position: Vector2) -> int:
	var seq := aim.issue(simulation_manager, WorldProjection.to_world(screen_position))
	queue_redraw()
	aim_changed.emit()
	return seq


func _unhandled_input(event: InputEvent) -> void:
	if not aim.is_armed() or not input_enabled or simulation_manager == null:
		return
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_LEFT:
			click(get_global_mouse_position())
			get_viewport().set_input_as_handled()
		elif event.button_index == MOUSE_BUTTON_RIGHT:
			cancel()
			get_viewport().set_input_as_handled()


func _process(_delta: float) -> void:
	if aim.is_armed():
		queue_redraw()


func _draw() -> void:
	if not aim.is_armed() or simulation_manager == null or simulation_manager.world_state == null:
		return
	var pointer := pointer_override if pointer_override.is_finite() else get_global_mouse_position()
	var shown := aim.preview(simulation_manager, WorldProjection.to_world(pointer))
	if shown.is_empty():
		return
	var color := OK_COLOR if str(shown["reason"]) == "" else BAD_COLOR
	var at: Vector2 = shown["position"]
	if str(shown["kind"]) in ["pond", "cull"]:
		var outline := PackedVector2Array()
		for index in range(CIRCLE_POINTS + 1):
			var angle := TAU * float(index) / float(CIRCLE_POINTS)
			outline.append(WorldProjection.to_screen(at + Vector2.from_angle(angle) * float(shown["radius"])))
		var fill := color
		fill.a = 0.22
		draw_colored_polygon(outline.slice(0, CIRCLE_POINTS), fill)
		draw_polyline(outline, color, 2.0)
		if str(shown["kind"]) == "cull":
			# How many are in reach, beside the pointer where the eye is: above the circle the
			# species table or a card would hide it whenever the circle reaches up under them.
			var label := "лис в круге: %d" % int(shown.get("count", 0))
			var font := ThemeDB.fallback_font
			var beside := WorldProjection.to_screen(at) + LABEL_OFFSET
			draw_string_outline(font, beside, label, HORIZONTAL_ALIGNMENT_LEFT, -1, 16, 4, Color(0, 0, 0, 0.8))
			draw_string(font, beside, label, HORIZONTAL_ALIGNMENT_LEFT, -1, 16, color.lightened(0.3))
		return
	var base := WorldProjection.to_screen(at)
	var from: Vector2 = shown.get("from", Vector2.INF)
	if from.is_finite():
		var faded := color
		faded.a = 0.5
		draw_dashed_line(WorldProjection.to_screen(from), base, faded, 2.0, 10.0)
	draw_line(base, base + Vector2(0.0, -34.0), color.darkened(0.4), 3.0)
	draw_colored_polygon(PackedVector2Array([base + Vector2(0.0, -34.0), base + Vector2(20.0, -27.0),
		base + Vector2(0.0, -20.0)]), color)
	draw_circle(base, 3.0, color.darkened(0.4))
