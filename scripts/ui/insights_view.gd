extends Control

## The chronicle's «Выводы»: what it concludes from the traits' history (`TraitInsights`), one
## card each - what kind of conclusion, the sentence, the numbers behind it and how sure it is -
## the surest first. Chips above keep one kind. «Показать» opens the trait in «Черты». Grows to
## its cards' height inside the chronicle's scroll.

signal show_requested(species_id: String, index: int)

const TraitInsightsScript := preload("res://scripts/story/trait_insights.gd")

const INK := Color(0.20, 0.13, 0.08)
const INK_DIM := Color(0.20, 0.13, 0.08, 0.6)
const CARD := Color(1.0, 0.97, 0.86, 0.7)
const FRAME := Color(0.20, 0.13, 0.08, 0.2)
const BUTTON := Color(0.25, 0.54, 0.41)
const BUTTON_EDGE := Color(0.14, 0.31, 0.24)
const KIND_COLORS := {"selection": Color(0.25, 0.49, 0.31), "cost": Color(0.66, 0.39, 0.11),
	"race": Color(0.48, 0.36, 0.23), "jump": Color(0.42, 0.25, 0.63), "bottleneck": Color(0.29, 0.33, 0.41),
	"trend": Color(0.45, 0.40, 0.30), "drift": Color(0.54, 0.48, 0.36)}
const CHIPS_HEIGHT := 34.0
const CARD_GAP := 8.0

var found: Array = []
var species: Array = []
var heredity := true
var too_early := ""
## The kind kept, "" for all.
var kept := ""
var _hits: Array = []


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP


## `insights` from `TraitInsights.conclude()`, `entries` the species (`{id, label, color}`);
## `early` says why there is nothing yet when there is not.
func show_insights(insights: Array, entries: Array, early := "") -> void:
	found = insights
	species = entries
	heredity = not entries.is_empty()
	too_early = early
	custom_minimum_size.y = _height()
	queue_redraw()


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		var over := false
		for hit in _hits:
			if Rect2(hit[0]).has_point(event.position):
				over = true
		mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND if over else Control.CURSOR_ARROW
	elif event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		for hit in _hits:
			if Rect2(hit[0]).has_point(event.position):
				Callable(hit[1]).call()
				accept_event()
				return


func _draw() -> void:
	_hits.clear()
	var font := get_theme_default_font()
	if font == null:
		return
	if not heredity:
		draw_string(font, Vector2(8.0, 30.0), "В этом мире черты не наследуются.", HORIZONTAL_ALIGNMENT_LEFT, -1, 15, INK_DIM)
		return
	if found.is_empty():
		draw_multiline_string(font, Vector2(8.0, 30.0), too_early if too_early != "" else
			"Выводов пока нет: черты почти не сдвинулись с тех пор, как летопись их считает.",
			HORIZONTAL_ALIGNMENT_LEFT, size.x - 16.0, 15, -1, INK_DIM)
		return
	_chips(font)
	var y := CHIPS_HEIGHT + 6.0
	for finding in _shown():
		y += _card(font, finding, y) + CARD_GAP


func _chips(font: Font) -> void:
	var x := 0.0
	var kinds: Array = [""]
	for kind in TraitInsightsScript.KINDS:
		for finding in found:
			if str(finding["kind"]) == kind:
				kinds.append(kind)
				break
	for kind in kinds:
		var word := str(TraitInsightsScript.KIND_LABELS.get(kind, ""))
		var label := "Все: %d" % found.size() if kind == "" else word.substr(0, 1) + word.substr(1).to_lower()
		var width := font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, 13).x + 20.0
		var rect := Rect2(x, 4.0, width, 24.0)
		if kind == kept:
			draw_rect(rect, INK, true)
		else:
			draw_rect(rect, INK, false, 1.0)
		draw_string(font, rect.position + Vector2(10.0, 17.0), label, HORIZONTAL_ALIGNMENT_LEFT, -1, 13,
			Color(1.0, 0.97, 0.86) if kind == kept else INK)
		var chosen := str(kind)
		_hits.append([rect, func(): _keep(chosen)])
		x += width + 8.0


## One card at `y`; its height.
func _card(font: Font, finding: Dictionary, y: float) -> float:
	var width := size.x - 8.0
	var text_width := width - 170.0
	var detail := str(finding["detail"])
	var detail_height := font.get_multiline_string_size(detail, HORIZONTAL_ALIGNMENT_LEFT, text_width, 13).y
	var height := maxf(78.0, 44.0 + detail_height + 10.0)
	var rect := Rect2(0.0, y, width, height)
	draw_rect(rect, CARD, true)
	draw_rect(rect, FRAME, false, 1.0)
	var color: Color = _species_color(str(finding["species"]))
	draw_rect(Rect2(rect.position, Vector2(5.0, height)), color, true)
	var kind := str(finding["kind"])
	var badge := str(TraitInsightsScript.KIND_LABELS.get(kind, kind))
	var badge_width := font.get_string_size(badge, HORIZONTAL_ALIGNMENT_LEFT, -1, 12).x + 14.0
	draw_rect(Rect2(16.0, y + 11.0, badge_width, 20.0), KIND_COLORS.get(kind, INK_DIM), true)
	draw_string(font, Vector2(23.0, y + 26.0), badge, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color.WHITE)
	draw_string(font, Vector2(28.0 + badge_width, y + 27.0), str(finding["title"]), HORIZONTAL_ALIGNMENT_LEFT,
		width - badge_width - 200.0, 17, INK)
	draw_multiline_string(font, Vector2(16.0, y + 52.0), detail, HORIZONTAL_ALIGNMENT_LEFT, text_width, 13, -1, INK_DIM)
	for dot in range(3):
		var center := Vector2(width - 128.0 + float(dot) * 13.0, y + 21.0)
		if dot < int(finding["confidence"]):
			draw_circle(center, 4.5, INK)
		else:
			draw_arc(center, 4.5, 0.0, TAU, 16, INK, 1.0)
	draw_string(font, Vector2(width - 84.0, y + 26.0), "уверенность", HORIZONTAL_ALIGNMENT_LEFT, -1, 10, INK_DIM)
	var button := Rect2(width - 140.0, y + height - 34.0, 128.0, 26.0)
	draw_rect(button, BUTTON_EDGE, true)
	draw_rect(button.grow(-2.0), BUTTON, true)
	draw_string(font, button.position + Vector2(0.0, 18.0), "Показать ›", HORIZONTAL_ALIGNMENT_CENTER, button.size.x, 14, INK)
	var species_id := str(finding["species"])
	var index := int(finding["trait"])
	_hits.append([button, func(): show_requested.emit(species_id, index)])
	return height


func _shown() -> Array:
	if kept == "":
		return found
	return found.filter(func(finding): return str(finding["kind"]) == kept)


func _keep(kind: String) -> void:
	kept = kind
	custom_minimum_size.y = _height()
	queue_redraw()


func _height() -> float:
	var font := get_theme_default_font()
	if font == null or found.is_empty():
		return 60.0
	var height := CHIPS_HEIGHT + 6.0
	var text_width := maxf(200.0, size.x - 178.0) if size.x > 0.0 else 560.0
	for finding in _shown():
		var detail_height := font.get_multiline_string_size(str(finding["detail"]), HORIZONTAL_ALIGNMENT_LEFT, text_width, 13).y
		height += maxf(78.0, 44.0 + detail_height + 10.0) + CARD_GAP
	return height


func _species_color(id: String) -> Color:
	for entry in species:
		if str(entry["id"]) == id:
			return entry["color"]
	return INK_DIM
