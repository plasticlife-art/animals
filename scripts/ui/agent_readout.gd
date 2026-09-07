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

const ACTION_LABELS := {
	"none": "Idle",
	"graze": "Grazing",
	"drink": "Drinking",
	"rest": "Resting",
	"explore": "Exploring",
	"join_herd": "Joining the herd",
	"flee_to_safe_area": "Fleeing",
	"hunt_prey": "Hunting",
	"scavenge_carcass": "Scavenging",
	"investigate_water": "Looking for water",
	"pair_cohesion": "Following its mate",
	"patrol": "Patrolling",
	"reproduce": "Mating",
}

## Fallback only. The real label is `species.json -> role.label`, which the
## selection card passes in; this covers a species that omits one.
const SPECIES_LABELS := {}

const SEX_GLYPHS := {
	"female": "♀",
	"male": "♂",
}


static func title(agent) -> String:
	if agent == null:
		return ""
	var parts: Array[String] = [
		String(SPECIES_LABELS.get(agent.species_type, String(agent.species_type).capitalize()))
	]
	var glyph := String(SEX_GLYPHS.get(agent.sex, ""))
	if glyph != "":
		parts.append(glyph)
	parts.append("#%d" % agent.id)
	return " ".join(parts)


## What the animal is doing, in words. Falls back to the raw action name so a new
## `AgentAction` constant shows up as readable text instead of disappearing.
static func action_label(agent) -> String:
	if agent == null:
		return ""
	var key := String(agent.current_action)
	return String(ACTION_LABELS.get(key, key.capitalize()))


## The three needs, each as `{label, value, maximum, fill, color}`.
##
## Thresholds come off the agent's own `balance` dictionary rather than a copy of
## the numbers, so the warning colour flips at exactly the point the AI starts
## treating the need as urgent.
static func vitals(agent) -> Array:
	if agent == null:
		return []
	var thresholds: Dictionary = agent.balance.get("state_thresholds", {})
	var need_max: float = maxf(1.0, agent.need_max)
	var max_energy: float = maxf(1.0, float(agent.metabolism.get("max_energy", 100.0)))
	return [
		_entry("Energy", agent.energy, max_energy,
			agent.energy <= float(thresholds.get("rest_energy", 26.0))),
		_entry("Food", need_max - agent.hunger, need_max,
			agent.hunger >= float(thresholds.get("critical_hunger", 60.0))),
		_entry("Water", need_max - agent.thirst, need_max,
			agent.thirst >= float(thresholds.get("critical_thirst", 50.0))),
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


static func _entry(label: String, value: float, maximum: float, is_low: bool) -> Dictionary:
	return {
		"label": label,
		"value": clampf(value, 0.0, maximum),
		"maximum": maximum,
		"fill": clampf(value / maximum, 0.0, 1.0),
		"color": PixelUiTheme.BAR_LOW if is_low else PixelUiTheme.BAR_GOOD,
	}
