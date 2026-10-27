class_name ReserveCaption
extends PanelContainer

## What the reserve's camera shows and where, as each scene opens (`ReserveDirector.caption_changed`):
## «Охота: лиса Рыжик гонит оленя · у Тихой заводи». Light type on the dark backdrop the tags over
## animals have, faded in and out; the controller places it (`_layout_reserve`) - over the foot of
## the map lying down, above the animal's card standing upright.

const FADE_SECONDS := 0.4
const BACKDROP := Color(0.10, 0.09, 0.07, 0.84)
const INK := Color(0.94, 0.91, 0.84)

var _label: Label
var _left := 0.0
var _shown := 0.0


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	visible = false
	var style := StyleBoxFlat.new()
	style.bg_color = BACKDROP
	style.set_corner_radius_all(3)
	style.content_margin_left = 14.0
	style.content_margin_right = 14.0
	style.content_margin_top = 6.0
	style.content_margin_bottom = 8.0
	add_theme_stylebox_override("panel", style)
	_label = Label.new()
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_label.add_theme_color_override("font_color", INK)
	_label.add_theme_font_size_override("font_size", 20)
	_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(_label)


## Shows `text` for `seconds`, in place of whatever it said.
func show_caption(text: String, seconds: float) -> void:
	if text == "":
		return
	_label.text = text
	_shown = maxf(seconds, FADE_SECONDS * 2.0)
	_left = _shown
	modulate.a = 0.0
	visible = true
	reset_size()


func text() -> String:
	return _label.text if visible else ""


## No wider than `width`, its words wrapped beyond.
func set_room(width: float) -> void:
	var natural: float = _label.get_theme_font("font").get_string_size(_label.text, HORIZONTAL_ALIGNMENT_LEFT, -1,
		_label.get_theme_font_size("font_size")).x + 30.0
	custom_minimum_size.x = minf(natural, width)
	_label.custom_minimum_size.x = custom_minimum_size.x - 28.0


func _process(delta: float) -> void:
	if not visible:
		return
	_left -= delta
	modulate.a = clampf(minf(_left, _shown - _left) / FADE_SECONDS, 0.0, 1.0)
	if _left <= 0.0:
		visible = false
