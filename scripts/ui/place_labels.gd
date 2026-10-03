class_name PlaceLabels
extends Node2D

## The names of the land on the map (`PlaceNames`): each watering hole's when the camera is
## close enough to read it, each district's from further out, both faded in and out over a
## band of zoom rather than popping. The text keeps its size on screen whatever the zoom, has
## a dark outline so it reads on grass and on water, and is drawn unshaded so the night tint
## leaves it legible. Placed through `WorldProjection`, so in the isometric view a name stands
## at its ground's height. Hidden in photo mode.

## Zoom is the camera's magnification: larger is closer. Ponds fade in from `pond_zoom` and
## are full at 1.25 times it; districts are full between their two bounds and fade over a
## quarter of each.
const DEFAULTS := {
	"enabled": true,
	"pond_zoom": 0.42,
	"district_zoom_min": 0.09,
	"district_zoom_max": 0.5,
	"pond_font_size": 13,
	"district_font_size": 17,
	"pond_color": [0.86, 0.94, 1.0, 1.0],
	"district_color": [0.98, 0.93, 0.8, 1.0],
	"outline_color": [0.05, 0.06, 0.07, 0.86],
	"outline_size": 4,
}

var story = null
var camera: Camera2D = null
var _config: Dictionary = DEFAULTS.duplicate(true)
var _last_view := Transform2D()
var _font: Font


func _ready() -> void:
	var unshaded := CanvasItemMaterial.new()
	unshaded.light_mode = CanvasItemMaterial.LIGHT_MODE_UNSHADED
	material = unshaded
	_font = ThemeDB.fallback_font


func bind(story_book, world_camera: Camera2D) -> void:
	story = story_book
	camera = world_camera
	queue_redraw()


## Reads `visuals.places`, keys it lacks from `DEFAULTS`.
func configure(visuals: Dictionary) -> void:
	_config = DEFAULTS.duplicate(true)
	var given: Dictionary = visuals.get("places", {})
	for key in given.keys():
		_config[key] = given[key]
	queue_redraw()


## How strongly each kind shows at a zoom: `[ponds, districts]`, 0 to 1.
static func fade(config: Dictionary, zoom: float) -> Array:
	var pond_from := float(config.get("pond_zoom", DEFAULTS["pond_zoom"]))
	var low := float(config.get("district_zoom_min", DEFAULTS["district_zoom_min"]))
	var high := float(config.get("district_zoom_max", DEFAULTS["district_zoom_max"]))
	var ponds := smoothstep(pond_from, pond_from * 1.25, zoom)
	var districts := smoothstep(low, low * 1.25, zoom) * (1.0 - smoothstep(high * 0.75, high, zoom))
	return [ponds, districts]


func _process(_delta: float) -> void:
	if camera == null:
		return
	var view := Transform2D(0.0, camera.zoom, 0.0, camera.global_position)
	if view != _last_view:
		_last_view = view
		queue_redraw()


func _draw() -> void:
	if story == null or camera == null or _font == null or not bool(_config.get("enabled", true)):
		return
	var places = story.places
	if places == null:
		return
	var zoom: float = maxf(camera.zoom.x, 0.0001)
	var strength: Array = fade(_config, zoom)
	var view: Rect2 = camera.get_visible_world_rect() if camera.has_method("get_visible_world_rect") else Rect2()
	var margin := 600.0 / zoom
	view = view.grow(margin)
	if float(strength[0]) > 0.01:
		var colour := _colour("pond_color")
		colour.a *= float(strength[0])
		for pond in places.ponds:
			if view.has_point(pond["position"]):
				_label(pond["position"], int(pond["level"]), str(pond["name"]), int(_config["pond_font_size"]), colour,
					float(strength[0]), zoom)
	if float(strength[1]) > 0.01:
		var colour := _colour("district_color")
		colour.a *= float(strength[1])
		for district in places.districts:
			if view.has_point(district["center"]):
				_label(district["center"], int(district["level"]), str(district["name"]),
					int(_config["district_font_size"]), colour, float(strength[1]), zoom)


func _label(position: Vector2, level: int, text: String, font_size: int, colour: Color, strength: float,
		zoom: float) -> void:
	var outline := _colour("outline_color")
	outline.a *= strength
	var width := _font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
	draw_set_transform(WorldProjection.to_screen(position, level), 0.0, Vector2.ONE / zoom)
	var at := Vector2(-width * 0.5, font_size * 0.35)
	draw_string_outline(_font, at, text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size,
		int(_config.get("outline_size", 4)), outline)
	draw_string(_font, at, text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, colour)
	draw_set_transform(Vector2.ZERO)


func _colour(key: String) -> Color:
	var value = _config.get(key, DEFAULTS[key])
	if value is Color:
		return value
	if value is Array and value.size() >= 3:
		return Color(float(value[0]), float(value[1]), float(value[2]), float(value[3]) if value.size() > 3 else 1.0)
	return Color.WHITE
