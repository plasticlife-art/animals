class_name ResultWindow
extends PanelContainer

## A scenario's two windows, on parchment in the middle of the screen. Before play, the brief:
## the scenario's name, what it asks in a few sentences, its goals, and «Начать». At the end, the
## result: «Стадо пережило сушь» or «Стадо не пережило сушь» (the scenario's own words), the herd's
## curve against its whole species' (`ScenarioRunner.series`), how many are left and the least
## there were, the dead by cause, the powers used and the bonus; then, after a win with a scenario
## after it, «Следующий сценарий», and «Смотреть дальше» (the world goes on), «Заново» and «В меню». `MainController` pauses the game under either and keeps
## the season card back while one is open.

signal brief_closed
signal watch_on_requested
signal restart_requested
signal menu_requested
## «Следующий сценарий», after a scenario won that has one after it (`ConfigLoader.next_scenario()`).
signal next_requested(scenario_id: String)

const HudTextScript := preload("res://scripts/ui/hud_text.gd")
const WIDTH := 540.0
const TITLE_INK := Color(0.20, 0.13, 0.08)
const DEFAULT_TITLES := {"won": "Сценарий пройден", "lost": "Сценарий проигран"}

var _title: Label
var _text: Label
var _curve: ResultCurve
var _buttons: HBoxContainer
var _mode: String = ""


func _init() -> void:
	visible = false
	mouse_filter = Control.MOUSE_FILTER_STOP
	custom_minimum_size.x = WIDTH
	var margin := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 14)
	add_child(margin)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 10)
	margin.add_child(box)
	_title = Label.new()
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_title.add_theme_color_override("font_color", TITLE_INK)
	box.add_child(_title)
	_curve = ResultCurve.new()
	_curve.custom_minimum_size = Vector2(WIDTH - 40.0, 130.0)
	box.add_child(_curve)
	_text = Label.new()
	_text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_text.custom_minimum_size.x = WIDTH - 40.0
	box.add_child(_text)
	_buttons = HBoxContainer.new()
	_buttons.alignment = BoxContainer.ALIGNMENT_CENTER
	_buttons.add_theme_constant_override("separation", 8)
	box.add_child(_buttons)


## The brief of `challenge` (the bundle's), before the scenario starts.
func show_brief(challenge: Dictionary) -> void:
	_mode = "brief"
	_title.text = str(challenge.get("label", ""))
	var lines: Array = [str(challenge.get("brief", ""))]
	var goals: Array = []
	for goal in challenge.get("goals", []):
		goals.append("• " + str(goal.get("label", "")))
	if not goals.is_empty():
		lines.append("Цели:\n" + "\n".join(goals))
	_text.text = "\n\n".join(lines)
	_curve.visible = false
	_set_buttons([["Начать", brief_closed]])
	visible = true


## The result: `won`, the runner's `summary`, its curve (`runner.series`) and the scenario's words.
func show_result(won: bool, summary: Dictionary, runner, challenge: Dictionary) -> void:
	_mode = "result"
	_title.text = result_title(won, challenge)
	_text.text = "\n".join(result_lines(summary, runner, challenge))
	_curve.series = runner.series.duplicate(true)
	_curve.species_label = HudTextScript.capitalized(HudTextScript.animals_label(str(runner.species)))
	_curve.watched_labels = []
	for watched in challenge.get("watch", []):
		_curve.watched_labels.append(HudTextScript.capitalized(HudTextScript.animals_label(str(watched))))
	_curve.visible = _curve.series.size() >= 2
	_curve.queue_redraw()
	var buttons: Array = [["Смотреть дальше", watch_on_requested], ["Заново", restart_requested], ["В меню", menu_requested]]
	var next_id := ConfigLoader.next_scenario(str(challenge.get("id", ""))) if won else ""
	if next_id != "":
		buttons.push_front(["Следующий сценарий", next_requested, next_id])
	_set_buttons(buttons)
	visible = true


func close() -> void:
	_mode = ""
	visible = false


func is_open() -> bool:
	return visible


## "brief", "result", or "" when closed.
func mode() -> String:
	return _mode if visible else ""


func text() -> String:
	return "%s\n%s" % [_title.text, _text.text]


func button_labels() -> Array:
	var labels: Array = []
	for button in _buttons.get_children():
		labels.append(button.text)
	return labels


static func result_title(won: bool, challenge: Dictionary) -> String:
	var titles: Dictionary = challenge.get("result", {})
	var key := "won" if won else "lost"
	return str(titles.get(key, DEFAULT_TITLES[key]))


## The result in lines: the herd left, the dead by cause, the powers used, the bonus goals.
static func result_lines(summary: Dictionary, runner, challenge: Dictionary) -> Array:
	var baseline := int(summary.get("baseline", 0))
	var count := int(summary.get("count", 0))
	var lines: Array = ["Осталось %d из %d (%d %%), меньше всего было %d" % [count, baseline,
		roundi(100.0 * float(summary.get("share", 0.0))), int(summary.get("lowest", count))]]
	var dead: Array = []
	var deaths: Dictionary = summary.get("deaths", {})
	for cause in ["thirst", "starvation", "predation", "old_age", "culled", "emigrated"]:
		if int(deaths.get(cause, 0)) > 0:
			dead.append("%s %d" % [HudTextScript.cause_label(cause), int(deaths[cause])])
	lines.append("Погибли: " + ", ".join(dead) if not dead.is_empty() else "Потерь не было")
	var used: Array = []
	var powers: Dictionary = summary.get("powers_used", {})
	for power in PowerAim.POWERS:
		if int(powers.get(power, 0)) > 0:
			used.append("%s %d" % [PowerAim.LABELS[power], int(powers[power])])
	lines.append("Силы: " + ", ".join(used) if not used.is_empty() else "Силы не понадобились")
	if int(summary.get("culled", 0)) > 0:
		lines.append("Отстреляно: %d" % int(summary["culled"]))
	var at_start: Dictionary = summary.get("species_start", {})
	var at_end: Dictionary = summary.get("species", {})
	for watched in challenge.get("watch", []):
		var watched_id := str(watched)
		if at_end.has(watched_id):
			lines.append("%s: %d (было %d)" % [HudTextScript.capitalized(HudTextScript.animals_label(watched_id)),
				int(at_end[watched_id]), int(at_start.get(watched_id, 0))])
	var states: Dictionary = summary.get("states", {})
	for goal in challenge.get("goals", []):
		if str(goal.get("role", "")) == "bonus":
			var kept := str(states.get(str(goal.get("id", "")), "")) == "met"
			lines.append("Дополнительно: %s — %s" % [str(goal.get("label", "")), "выполнено" if kept else "не выполнено"])
	return lines


## The herd's curve and its species', each to its own height: what the drought did to the herd
## against what it did to all of them.
class ResultCurve:
	extends Control

	const OWN_COLOR := Color(0.16, 0.48, 0.2)
	const SPECIES_COLOR := Color(0.45, 0.36, 0.26, 0.8)
	const WATCHED_COLORS := [Color(0.72, 0.3, 0.12), Color(0.38, 0.3, 0.62)]

	var series: Array = []
	var species_label: String = ""
	var watched_labels: Array = []

	func _draw() -> void:
		if series.size() < 2:
			return
		var font := get_theme_default_font()
		var font_size := get_theme_default_font_size()
		var top := float(font_size) + 6.0
		var rect := Rect2(Vector2(0.0, top), size - Vector2(0.0, top))
		draw_rect(rect, Color(0.2, 0.13, 0.08, 0.06), true)
		var start := float(series[0][0])
		var span := maxf(1.0, float(series[series.size() - 1][0]) - start)
		var columns: Array = [[1, OWN_COLOR], [2, SPECIES_COLOR]]
		for index in range(watched_labels.size()):
			columns.append([3 + index, WATCHED_COLORS[index % WATCHED_COLORS.size()]])
		for column in columns:
			var index: int = column[0]
			var highest := 1.0
			for row in series:
				if row.size() > index:
					highest = maxf(highest, float(row[index]))
			var points := PackedVector2Array()
			for row in series:
				if row.size() <= index:
					continue
				points.append(rect.position + Vector2((float(row[0]) - start) / span * rect.size.x,
					rect.size.y * (1.0 - float(row[index]) / highest)))
			if points.size() >= 2:
				draw_polyline(points, column[1], 2.0, true)
		draw_string(font, Vector2(0.0, float(font_size)), "Ваше стадо", HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, OWN_COLOR)
		var slot := size.x / float(2 + watched_labels.size())
		draw_string(font, Vector2(slot, float(font_size)), species_label, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, SPECIES_COLOR)
		for index in range(watched_labels.size()):
			draw_string(font, Vector2(slot * float(2 + index), float(font_size)), str(watched_labels[index]),
				HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, WATCHED_COLORS[index % WATCHED_COLORS.size()])


func _set_buttons(entries: Array) -> void:
	for child in _buttons.get_children():
		_buttons.remove_child(child)
		child.queue_free()
	for entry in entries:
		var button := Button.new()
		button.text = str(entry[0])
		button.focus_mode = Control.FOCUS_NONE
		var announce: Signal = entry[1]
		# A third element is what the signal carries: the next scenario's id.
		if entry.size() > 2:
			var carried = entry[2]
			button.pressed.connect(func() -> void: announce.emit(carried))
		else:
			button.pressed.connect(func() -> void: announce.emit())
		_buttons.add_child(button)
