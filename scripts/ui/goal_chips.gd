class_name GoalChips
extends HFlowContainer

## A scenario's goals above the powers, one chip each, with the numbers that decide them: «Ваше
## стадо: 17 из 20, нужно 10 · ещё 2:15», «Не меньше 5 голов», «Ни одной смерти от жажды». Ink
## while open, amber while it would fail if decided now, green once met, red once failed; the
## goal as the scenario words it in the tooltip. Read from the manager's score (`ScenarioRunner`).
## A species' floor reads «Лисы: 34, не меньше 20», a limit on culling «Отстреляно: 5 из 12». Last,
## in a scenario that asks for it (`challenge.chips` with "water"), how much water the own herd has
## on average, awake and asleep - «Вода стада: 64» - amber below `WATER_LOW`, red below
## `WATER_CRITICAL`: when to act is read off it. Centred in one row while there is room between the
## cards and the map (`fit()`), in two or more when there is not - a large interface, a small window.

const HerdReadoutScript := preload("res://scripts/ui/herd_readout.gd")
const HudTextScript := preload("res://scripts/ui/hud_text.gd")
## The herd's water, 0 to 100, below which its chip turns amber, then red: the drink floor and the
## thirst at which the herd is in danger (`balance.state_thresholds`).
const WATER_LOW := 60.0
const WATER_CRITICAL := 30.0
const SEPARATION := 6.0
const INK := {
	"pending": Color(0.2, 0.13, 0.08),
	"warning": Color(0.72, 0.42, 0.04),
	"met": Color(0.16, 0.48, 0.2),
	"failed": Color(0.66, 0.16, 0.1),
}

var _chips: Array = []


func _init() -> void:
	visible = false
	alignment = FlowContainer.ALIGNMENT_CENTER
	add_theme_constant_override("h_separation", int(SEPARATION))
	add_theme_constant_override("v_separation", 4)


## Centred where they stand, the chips take `room` pixels across at most: one row when it holds
## them, more when it does not.
func fit(room: float) -> void:
	var widths: Array = []
	for panel in _chips:
		if panel.visible:
			widths.append(panel.get_combined_minimum_size().x)
	var width := fit_width(widths, room)
	if not is_equal_approx(offset_right - offset_left, width):
		offset_left = -width * 0.5
		offset_right = width * 0.5


## The width of chips `widths` wide in `room`: their row when it fits, else the room - never
## narrower than the widest, which would stand out of any row.
static func fit_width(widths: Array, room: float) -> float:
	var row := 0.0
	var widest := 0.0
	for width in widths:
		row += float(width)
		widest = maxf(widest, float(width))
	row += SEPARATION * float(maxi(0, widths.size() - 1))
	return minf(row, maxf(room, widest))


## The chips for `runner`'s goals at `now`, and the own herd's water in `world`; none for a world
## without a scenario.
func refresh(runner, now: float, world = null) -> void:
	var goals: Array = runner.challenge.get("goals", []) if runner != null and runner.is_active() else []
	var shown: Array = []
	for goal in goals:
		shown.append(chip(goal, runner, now))
	if not goals.is_empty() and world != null and runner.challenge.get("chips", []).has("water"):
		shown.append(water_chip(herd_water(world, runner)))
	while _chips.size() < shown.size():
		var panel := PanelContainer.new()
		panel.mouse_filter = Control.MOUSE_FILTER_PASS
		var label := Label.new()
		panel.add_child(label)
		add_child(panel)
		_chips.append(panel)
	for index in range(_chips.size()):
		var panel: PanelContainer = _chips[index]
		panel.visible = index < shown.size()
		if not panel.visible:
			continue
		var label: Label = panel.get_child(0)
		label.text = str(shown[index]["text"])
		label.add_theme_color_override("font_color", INK.get(str(shown[index]["state"]), INK["pending"]))
		panel.tooltip_text = str(shown[index]["tooltip"])


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
		elif role == "bonus":
			text = "Дополнительно: не меньше %d %s" % [needed, heads_genitive(needed)]
		else:
			text = "Не меньше %d %s" % [needed, heads_genitive(needed)]
	elif goal.has("species_at_least") or goal.has("species_share_at_least"):
		var parts: Array = []
		var floors: Dictionary = goal.get("species_at_least", {})
		for species_id in floors.keys():
			parts.append(species_floor_text(str(species_id), int(runner.species_now.get(species_id, 0)), int(floors[species_id])))
		var shares: Dictionary = goal.get("species_share_at_least", {})
		for species_id in shares.keys():
			var needed := ceili(float(shares[species_id]) * float(runner.species_start.get(species_id, 0)) - 0.0001)
			parts.append(species_floor_text(str(species_id), int(runner.species_now.get(species_id, 0)), needed))
		text = " · ".join(parts)
	elif goal.has("culled_at_most"):
		text = "Отстреляно: %d из %d" % [runner.culled, int(goal["culled_at_most"])]
	elif goal.has("thirst_deaths_at_most") or goal.has("thirst_share_at_most"):
		var deaths: int = runner.thirst_deaths()
		text = "Ни одной смерти от жажды" if deaths == 0 else "Смертей от жажды: %d" % deaths
		if goal.has("thirst_share_at_most"):
			text = "Смертей от жажды: %d" % deaths
	elif goal.has("starvation_deaths_at_most"):
		var starved: int = runner.starvation_deaths()
		text = "Ни одного оленя от голода" if starved == 0 else "Смертей от голода: %d" % starved
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


## «Лисы: 34, не меньше 20».
static func species_floor_text(species_id: String, count: int, needed: int) -> String:
	return "%s: %d, не меньше %d" % [HudTextScript.capitalized(HudTextScript.animals_label(species_id)), count, needed]


## The own herd's water, 0 to 100, its members' mean awake and asleep; -1 with none of it left.
static func herd_water(world, runner) -> float:
	var thirst := 0.0
	var members := 0
	for group_id in runner.groups.keys():
		var summary: Dictionary = HerdReadoutScript.summarize(world, runner.species, int(group_id))
		thirst += float(summary["thirst"]) * float(summary["total"])
		members += int(summary["total"])
	return 100.0 - thirst / float(members) if members > 0 else -1.0


static func water_chip(water: float) -> Dictionary:
	var state := "pending"
	if water >= 0.0 and water < WATER_CRITICAL:
		state = "failed"
	elif water >= 0.0 and water < WATER_LOW:
		state = "warning"
	return {"text": "Вода стада: %s" % ("—" if water < 0.0 else str(roundi(water))), "state": state,
		"tooltip": "Сколько в среднем воды у вашего стада — и рядом, и вдали.
Когда вода падает, пора к пруду: олени гибнут от жажды, когда она кончается."}


## «2:15»; «0:00» once past.
static func clock(seconds: float) -> String:
	var whole := maxi(0, ceili(seconds))
	@warning_ignore("integer_division")
	return "%d:%02d" % [whole / 60, whole % 60]
