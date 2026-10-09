class_name GoalChips
extends HBoxContainer

## A scenario's goals above the powers, one chip each, with the numbers that decide them: «Ваше
## стадо: 17 из 20, нужно 10 · ещё 2:15», «Не меньше 5 голов», «Ни одной смерти от жажды». Ink
## while open, amber while it would fail if decided now, green once met, red once failed; the
## goal as the scenario words it in the tooltip. Read from the manager's score (`ScenarioRunner`).

const INK := {
	"pending": Color(0.2, 0.13, 0.08),
	"warning": Color(0.72, 0.42, 0.04),
	"met": Color(0.16, 0.48, 0.2),
	"failed": Color(0.66, 0.16, 0.1),
}

var _chips: Array = []


func _init() -> void:
	visible = false
	alignment = BoxContainer.ALIGNMENT_CENTER
	add_theme_constant_override("separation", 6)


## The chips for `runner`'s goals at `now`; none for a world without a scenario.
func refresh(runner, now: float) -> void:
	var goals: Array = runner.challenge.get("goals", []) if runner != null and runner.is_active() else []
	while _chips.size() < goals.size():
		var panel := PanelContainer.new()
		panel.mouse_filter = Control.MOUSE_FILTER_PASS
		var label := Label.new()
		panel.add_child(label)
		add_child(panel)
		_chips.append(panel)
	for index in range(_chips.size()):
		var panel: PanelContainer = _chips[index]
		panel.visible = index < goals.size()
		if not panel.visible:
			continue
		var shown := chip(goals[index], runner, now)
		var label: Label = panel.get_child(0)
		label.text = str(shown["text"])
		label.add_theme_color_override("font_color", INK.get(str(shown["state"]), INK["pending"]))
		panel.tooltip_text = str(shown["tooltip"])


## What one goal's chip says: `{text, state, tooltip}`, `state` one of `INK`'s keys.
static func chip(goal: Dictionary, runner, now: float) -> Dictionary:
	var goal_id := str(goal.get("id", ""))
	var state := str(runner.states.get(goal_id, "pending"))
	var role := str(goal.get("role", ""))
	var text := str(goal.get("label", goal_id))
	if goal.has("share_at_least"):
		var needed := ceili(float(goal["share_at_least"]) * float(runner.baseline) - 0.0001)
		if role == "win":
			text = "Ваше стадо: %d из %d, нужно %d" % [runner.count, runner.baseline, needed]
			if state == "pending" and runner.decide_times.has(goal_id):
				text += " · ещё %s" % clock(float(runner.decide_times[goal_id]) - now)
		else:
			text = "Не меньше %d %s" % [needed, heads_genitive(needed)]
	elif goal.has("thirst_deaths_at_most") or goal.has("thirst_share_at_most"):
		var deaths: int = runner.thirst_deaths()
		text = "Ни одной смерти от жажды" if deaths == 0 else "Смертей от жажды: %d" % deaths
		if goal.has("thirst_share_at_most"):
			text = "Смертей от жажды: %d" % deaths
	if state == "pending" and not runner.holds(goal):
		state = "warning"
	var tooltip := str(goal.get("label", ""))
	match role:
		"win":
			tooltip += "\nЦель: выполните её — и сценарий пройден"
		"lose":
			tooltip += "\nЕсли это нарушится — сценарий проигран"
		"bonus":
			tooltip += "\nДополнительно: на исход не влияет"
	return {"text": text, "state": state, "tooltip": tooltip}


## «голов» after «не меньше»: genitive, «головы» only after a one that is not eleven.
static func heads_genitive(count: int) -> String:
	return "головы" if count % 10 == 1 and count % 100 != 11 else "голов"


## «2:15»; «0:00» once past.
static func clock(seconds: float) -> String:
	var whole := maxi(0, ceili(seconds))
	@warning_ignore("integer_division")
	return "%d:%02d" % [whole / 60, whole % 60]
