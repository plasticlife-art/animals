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
		margin.add_theme_constant_override("margin_" + side, 12)
	for side in ["top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 4)
	add_child(margin)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	margin.add_child(row)
	_stripe = ColorRect.new()
	_stripe.custom_minimum_size = Vector2(6.0, 0.0)
	_stripe.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(_stripe)
	_label = Label.new()
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_label.add_theme_font_size_override("font_size", 26)
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
	size = get_combined_minimum_size()
	var view := get_viewport_rect().size
	position = Vector2(roundf((view.x - size.x) * 0.5), TOP)
