class_name Weather
extends RefCounted

## The weather (`world.weather`): spells of `spell_seconds`, each of a kind drawn from its season's
## `seasons` weights by a hash of the spell's number and the world's seed. Like `Climate`, a pure
## function of time: nothing to save, the same on the worker and in the view, no draw from the
## world's stream. A spell eases in from the one before over `ease_seconds`.
##
## What a kind does (`kinds`):
## - `water`: seasons of fill a season, added to the season's balance of the ponds;
## - `regrowth`: on the grass;
## - `metabolism`, `thirst`: on the needs;
## - `perception`: on the eyes;
## - `movement`: on the legs.
##
## `water`, `regrowth`, `metabolism` and `thirst` are evened out against the season's mean over its
## weights (the mean taken off `water`, divided out of the rest), so the weather varies a season's
## days without moving its average and the balance the ecology was tuned to holds. Sight and pace
## are left as they are: a fog is a fog. With `even` false - a scenario's own weather - nothing is
## evened: a hot summer is a drier one, a snowy winter a hungrier one.
##
## `forced` (`[{weather, since, until}]`, a vote's) overrides the drawn spell while it lasts, the
## latest first.

const TraitsScript := preload("res://scripts/agents/traits.gd")
const SALT := 0x3EA7E12
const EVENED := ["regrowth", "metabolism", "thirst"]
const NEUTRAL := {"kind": "", "intensity": 0.0, "water": 0.0, "regrowth": 1.0, "metabolism": 1.0, "thirst": 1.0,
	"perception": 1.0, "movement": 1.0}


static func enabled(config: Dictionary) -> bool:
	return bool(config.get("enabled", false)) and not config.get("kinds", {}).is_empty()


## The weather at `time_seconds` in `season_id`: its kind (the spell's, or the one it eases from
## while that is more than half), how strong it shows (0-1), and its multipliers.
static func evaluate(config: Dictionary, season_id: String, time_seconds: float, seed_value: int, forced: Array = []) -> Dictionary:
	if not enabled(config):
		return NEUTRAL.duplicate()
	var spell := _spell(config, season_id, time_seconds, seed_value, forced)
	var means := season_means(config, season_id)
	var before := effects(config, spell[0], means)
	var after := effects(config, spell[1], means)
	var blend: float = spell[2]
	var result := {"kind": spell[1] if blend >= 0.5 else spell[0]}
	for key in ["water", "regrowth", "metabolism", "thirst", "perception", "movement", "intensity"]:
		result[key] = lerpf(float(before[key]), float(after[key]), blend)
	return result


## What the view draws at `time_seconds`: how much rain, snow, fog and heat (0-1), eased from one
## spell to the next as the effects are, and the kind shown.
static func visual(config: Dictionary, season_id: String, time_seconds: float, seed_value: int, forced: Array = []) -> Dictionary:
	var shown := {"kind": "", "rain": 0.0, "snow": 0.0, "fog": 0.0, "heat": 0.0}
	if not enabled(config):
		return shown
	var spell := _spell(config, season_id, time_seconds, seed_value, forced)
	var blend: float = spell[2]
	shown["kind"] = spell[1] if blend >= 0.5 else spell[0]
	for part in [[spell[0], 1.0 - blend], [spell[1], blend]]:
		var raw: Dictionary = config.get("kinds", {}).get(part[0], {})
		var draws := str(raw.get("draws", part[0]))
		if shown.has(draws) and draws != "kind":
			shown[draws] += float(raw.get("intensity", 1.0)) * float(part[1])
	return shown


## The spell at `time_seconds`: `[kind before, kind now, how far eased in]`, a vote's weather
## (`forced`) in place of the drawn while it lasts.
static func _spell(config: Dictionary, season_id: String, time_seconds: float, seed_value: int, forced: Array) -> Array:
	var length := maxf(1.0, float(config.get("spell_seconds", 40.0)))
	var ease := clampf(float(config.get("ease_seconds", 6.0)), 0.0, length)
	var number := int(floor(time_seconds / length))
	var started := float(number) * length
	var now_kind := kind_of_spell(config, season_id, number, seed_value)
	var was_kind := kind_of_spell(config, season_id, number - 1, seed_value)
	for entry in forced:
		if time_seconds >= float(entry.get("since", 0.0)) and time_seconds < float(entry.get("until", 0.0)):
			if float(entry.get("since", 0.0)) > started:
				started = float(entry.get("since", 0.0))
				was_kind = now_kind
			now_kind = str(entry.get("weather", now_kind))
	var blend := 1.0 if ease <= 0.0 else smoothstep(0.0, 1.0, (time_seconds - started) / ease)
	return [was_kind, now_kind, blend]


## The kind of spell `number` in `season_id`: drawn by the hash from the season's weights.
static func kind_of_spell(config: Dictionary, season_id: String, number: int, seed_value: int) -> String:
	var weights: Dictionary = config.get("seasons", {}).get(season_id, {})
	var total := 0.0
	for kind in weights.keys():
		total += maxf(0.0, float(weights[kind]))
	if total <= 0.0:
		return "clear"
	var roll := TraitsScript.unit(number, SALT, seed_value) * total
	var kinds: Array = weights.keys()
	kinds.sort()
	for kind in kinds:
		roll -= maxf(0.0, float(weights[kind]))
		if roll < 0.0:
			return str(kind)
	return str(kinds[-1])


## What `kind` does, evened out against the season's `means` (unless the weather is not `even`).
static func effects(config: Dictionary, kind: String, means: Dictionary) -> Dictionary:
	var raw: Dictionary = config.get("kinds", {}).get(kind, {})
	if not bool(config.get("even", true)):
		means = {"water": 0.0, "regrowth": 1.0, "metabolism": 1.0, "thirst": 1.0}
	var values := {"intensity": float(raw.get("intensity", 0.0 if kind == "clear" else 1.0)),
		"water": float(raw.get("water", 0.0)) - float(means.get("water", 0.0)),
		"perception": float(raw.get("perception", 1.0)), "movement": float(raw.get("movement", 1.0))}
	for key in EVENED:
		values[key] = float(raw.get(key, 1.0)) / maxf(0.001, float(means.get(key, 1.0)))
	return values


## Each evened effect's mean over `season_id`'s weights.
static func season_means(config: Dictionary, season_id: String) -> Dictionary:
	var weights: Dictionary = config.get("seasons", {}).get(season_id, {})
	var kinds: Dictionary = config.get("kinds", {})
	var means := {"water": 0.0, "regrowth": 0.0, "metabolism": 0.0, "thirst": 0.0}
	var total := 0.0
	for kind in weights.keys():
		var weight := maxf(0.0, float(weights[kind]))
		total += weight
		var raw: Dictionary = kinds.get(kind, {})
		means["water"] += weight * float(raw.get("water", 0.0))
		for key in EVENED:
			means[key] += weight * float(raw.get(key, 1.0))
	if total <= 0.0:
		return {"water": 0.0, "regrowth": 1.0, "metabolism": 1.0, "thirst": 1.0}
	for key in means.keys():
		means[key] /= total
	return means


## «Дождь», «Туман»...: the kind's label, "" for none.
static func label(config: Dictionary, kind: String) -> String:
	return str(config.get("kinds", {}).get(kind, {}).get("label", ""))

