class_name AgentReadout
extends RefCounted

## Shared formatting for the two selection surfaces: the tag that rides above the
## selected animal and the card in the corner.
##
## It exists so the normalisation happens once. Energy is the trap - a herbivore's
## bar fills at 100 and a predator's at 150 (`data/config/species.json`), so
## anything that divides by a literal draws every predator as half-starved.
## `metabolism.max_energy` is the only correct denominator.
##
## Every bar reads "more is better", which is why hunger and thirst are inverted
## into food and water. Three bars that all drain as the animal needs something can
## be read at a glance; a mix of directions cannot.

const HudTextScript := preload("res://scripts/ui/hud_text.gd")
## The three needs, in the order the bars stand.
const NEED_LABELS := ["Силы", "Сытость", "Вода"]


## «Ветка ♀ · олениха» with a name, «Олениха ♀ №284» without one.
static func title(agent, name := "") -> String:
	if agent == null:
		return ""
	var noun := HudTextScript.animal_noun(agent.species_type, agent.sex,
		agent.has_method("get_age_stage") and agent.get_age_stage() == "young")
	var glyph := HudTextScript.sex_glyph(agent.sex)
	if name != "":
		return "%s %s · %s" % [name, glyph, noun]
	return "%s %s №%d" % [noun.capitalize(), glyph, agent.id]


## What the animal is doing, in words. Falls back to the raw action name so a new
## `AgentAction` constant shows up as text instead of disappearing.
static func action_label(agent) -> String:
	if agent == null:
		return ""
	return HudTextScript.action_label(String(agent.current_action))


## The three needs, each as `{label, value, maximum, fill, color}`.
##
## Thresholds come off the agent's own `balance` dictionary rather than a copy of
## the numbers, so the warning colour flips at exactly the point the AI starts
## treating the need as urgent.
static func vitals(agent) -> Array:
	if agent == null:
		return []
	return need_bars(agent.energy, agent.hunger, agent.thirst, maxf(1.0, agent.need_max),
		maxf(1.0, float(agent.metabolism.get("max_energy", 100.0))), agent.balance.get("state_thresholds", {}))


## The same three bars from raw values, for whatever has them: one animal above, a herd's
## means on the herd card. `labels` names energy, food and water, in that order.
static func need_bars(energy: float, hunger: float, thirst: float, need_max: float, max_energy: float,
		thresholds: Dictionary, labels: Array = NEED_LABELS) -> Array:
	return [
		bar_entry(str(labels[0]), energy, max_energy, energy <= float(thresholds.get("rest_energy", 26.0))),
		bar_entry(str(labels[1]), need_max - hunger, need_max, hunger >= float(thresholds.get("critical_hunger", 60.0))),
		bar_entry(str(labels[2]), need_max - thirst, need_max, thirst >= float(thresholds.get("critical_thirst", 50.0))),
	]


static func value_text(entry: Dictionary) -> String:
	return "%d / %d" % [roundi(float(entry.get("value", 0.0))), roundi(float(entry.get("maximum", 0.0)))]


## Stacks `entries` as bars from `origin` down and reports the height used, so
## callers can lay themselves out around a strip whose size they do not hardcode.
static func draw_bars(canvas: CanvasItem, origin: Vector2, width: float,
		bar_height: float, spacing: float, entries: Array) -> float:
	if entries.is_empty():
		return 0.0
	var y := origin.y
	for entry in entries:
		var track := Rect2(origin.x, y, width, bar_height)
		canvas.draw_rect(track, PixelUiTheme.BAR_TRACK)
		var fill: float = clampf(float(entry.get("fill", 0.0)), 0.0, 1.0)
		if fill > 0.0:
			canvas.draw_rect(Rect2(origin.x, y, width * fill, bar_height),
				entry.get("color", PixelUiTheme.BAR_GOOD))
		canvas.draw_rect(track, PixelUiTheme.INK_DIM, false, 1.0)
		y += bar_height + spacing
	return y - origin.y - spacing


static func bar_entry(label: String, value: float, maximum: float, is_low: bool) -> Dictionary:
	return {
		"label": label,
		"value": clampf(value, 0.0, maximum),
		"maximum": maximum,
		"fill": clampf(value / maximum, 0.0, 1.0),
		"color": PixelUiTheme.BAR_LOW if is_low else PixelUiTheme.BAR_GOOD,
	}
