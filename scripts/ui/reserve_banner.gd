class_name ReserveBanner
extends PanelContainer

## The reserve's big news, across the top of the screen for a few seconds each: a ward's death or
## young, a vote's outcome, newcomers, a fund's perk, the year's summary. One at a time, in large
## type; waiting news is shown weightiest first, and a full queue drops the lightest.

## How heavily each kind of `ReserveSession.told` line weighs; kinds not here are not shown.
const WEIGHTS := {"ward_death": 6, "year": 5, "ward_born": 4, "vote": 3, "rescue": 3, "team": 2}
const COLORS := {"ward_death": Color(0.86, 0.32, 0.26), "ward_born": Color(0.52, 0.78, 0.38),
	"vote": Color(0.36, 0.6, 0.9), "rescue": Color(0.95, 0.74, 0.3), "team": Color(0.95, 0.74, 0.3),
	"year": Color(0.95, 0.88, 0.6)}
const SHOW_SECONDS := 4.0
const FADE_SECONDS := 0.35
const MAX_WAITING := 6
const TOP := 150.0
## The least room between the banner and the screen's sides; its margins, colour stripe and the
## gap after the stripe.
const SIDE := 12.0
const MARGIN := 12
const STRIPE := 6.0
const GAP := 10
const FONT_SIZE := 26
const COMPACT_FONT_SIZE := 20

## How far down it stands: `TOP`, unless `bottom` is set - upright, its foot just above the news
## cards at the foot of the screen.
var top := TOP
var bottom := INF
## Upright, on a phone: smaller type, so a long line takes two rows rather than four.
var compact := false:
	set(value):
		compact = value
		if _label != null:
			_label.add_theme_font_size_override("font_size", COMPACT_FONT_SIZE if value else FONT_SIZE)
var _label: Label
var _stripe: ColorRect
var _waiting: Array = []
var _left := 0.0


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	visible = false
	var margin := MarginContainer.new()
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for side in ["left", "right"]:
		margin.add_theme_constant_override("margin_" + side, MARGIN)
	for side in ["top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 4)
	add_child(margin)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", GAP)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	margin.add_child(row)
	_stripe = ColorRect.new()
	_stripe.custom_minimum_size = Vector2(STRIPE, 0.0)
	_stripe.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(_stripe)
	_label = Label.new()
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_label.add_theme_font_size_override("font_size", FONT_SIZE)
	row.add_child(_label)


func bind(session) -> void:
	if not session.told.is_connected(hear):
		session.told.connect(hear)


## A told line, shown if its kind is news.
func hear(line: Dictionary) -> void:
	var kind := str(line.get("kind", ""))
	if not WEIGHTS.has(kind):
		return
	_waiting.append({"text": str(line.get("text", "")), "kind": kind, "weight": int(WEIGHTS[kind]), "order": Time.get_ticks_usec()})
	if _waiting.size() > MAX_WAITING:
		_waiting.sort_custom(_heavier)
		_waiting.resize(MAX_WAITING)


## What waits, weightiest first (the earlier on a tie).
func waiting() -> Array:
	var sorted := _waiting.duplicate()
	sorted.sort_custom(_heavier)
	return sorted


static func _heavier(a: Dictionary, b: Dictionary) -> bool:
	return int(a["weight"]) > int(b["weight"]) or (int(a["weight"]) == int(b["weight"]) and int(a["order"]) < int(b["order"]))


func _process(delta: float) -> void:
	if _left > 0.0:
		_left -= delta
		modulate.a = clampf(minf(_left, SHOW_SECONDS - _left) / FADE_SECONDS, 0.0, 1.0)
		# Kept where it belongs while shown: the panel it stands under may grow meanwhile, and a
		# wrapped line takes its height a frame after its width.
		_place()
		if _left <= 0.0:
			visible = false
		return
	if _waiting.is_empty():
		return
	_waiting.sort_custom(_heavier)
	var next: Dictionary = _waiting.pop_front()
	_label.text = str(next["text"])
	_stripe.color = COLORS.get(str(next["kind"]), Color.WHITE)
	_left = SHOW_SECONDS
	modulate.a = 0.0
	visible = true
	_wrap()
	_place()


## Long news wraps to the screen's width rather than running off both sides: upright, a ward's
## name alone can take half of it.
func _wrap() -> void:
	var font := _label.get_theme_font("font")
	var font_size := _label.get_theme_font_size("font_size")
	var width := font.get_string_size(_label.text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
	var frame := 2.0 * MARGIN + STRIPE + GAP
	var style := get_theme_stylebox("panel")
	if style != null:
		frame += style.get_minimum_size().x
	var room := get_viewport_rect().size.x - 2.0 * SIDE - frame
	var wraps := width > room
	_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART if wraps else TextServer.AUTOWRAP_OFF
	_label.custom_minimum_size.x = room if wraps else 0.0


func _place() -> void:
	size = get_combined_minimum_size()
	position = Vector2(roundf((get_viewport_rect().size.x - size.x) * 0.5), top if bottom == INF else bottom - size.y)
