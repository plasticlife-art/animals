class_name Climate
extends RefCounted

## Seasons and the day/night cycle, as a pure function of `simulation_time`.
##
## Nothing here accumulates. `SaveSystem` already stores and restores
## `simulation_time`, so a derived clock costs no save-format change and no
## `SAVE_VERSION` bump; and because `speed_multiplier` scales only the
## accumulator and never `tick_duration`, independence from game speed comes
## for free. The instance half of this class is a cache, not state: `sample()`
## unpacks one `evaluate()` result into flat fields because the perception
## multiplier is read about ten times per agent per tick, and recomputing two
## `smoothstep`s for each of those would be pure waste.
##
## The single most important property, relied on by every other test suite:
## at `time_seconds == 0` with the shipped config, every multiplier is exactly
## 1.0 and `night_ratio` is exactly 0.0. `start_day_phase: 0.5` puts t=0 at
## noon and `start_season_index: 0` puts it in spring, inside the hold band.

const NEUTRAL := {
	"enabled": false,
	"year": 0,
	"season_index": 0,
	"season_id": "spring",
	"season_label": "Весна",
	"season_progress": 0.0,
	"day_phase": 0.5,
	"night_ratio": 0.0,
	"is_night": false,
	"regrowth_multiplier": 1.0,
	"metabolism_multiplier": 1.0,
	"perception_multiplier": 1.0,
	"light_color": Color.WHITE,
}

var enabled: bool = false
var year: int = 0
var season_index: int = 0
var season_id: String = "spring"
var season_label: String = "Spring"
var season_progress: float = 0.0
var day_phase: float = 0.5
var night_ratio: float = 0.0
var is_night: bool = false
var regrowth_multiplier: float = 1.0
var metabolism_multiplier: float = 1.0
var perception_multiplier: float = 1.0
var light_color: Color = Color.WHITE

var _config: Dictionary = {}
var _perception_by_species: Dictionary = {}


func configure(world_config: Dictionary) -> void:
	_config = world_config.get("climate", {})
	_perception_by_species.clear()
	sample(0.0)


## Reads the whole clock for `time_seconds` into the fields above. Called once
## per tick from `WorldState.step()`, and again on init and on save restore so
## the first stats snapshot is never a lie.
func sample(time_seconds: float) -> void:
	var values: Dictionary = evaluate(_config, time_seconds)
	enabled = bool(values["enabled"])
	year = int(values["year"])
	season_index = int(values["season_index"])
	season_id = str(values["season_id"])
	season_label = str(values["season_label"])
	season_progress = float(values["season_progress"])
	day_phase = float(values["day_phase"])
	night_ratio = float(values["night_ratio"])
	is_night = bool(values["is_night"])
	regrowth_multiplier = float(values["regrowth_multiplier"])
	metabolism_multiplier = float(values["metabolism_multiplier"])
	perception_multiplier = float(values["perception_multiplier"])
	light_color = values["light_color"]
	_perception_by_species = values.get("perception_multiplier_by_species", {})


## One hash lookup, not a recomputation - this is the hot path.
func perception_multiplier_for(species_type: String) -> float:
	return float(_perception_by_species.get(species_type, perception_multiplier))


func snapshot_values() -> Dictionary:
	return {
		"season": season_id,
		"season_index": season_index,
		"season_progress": season_progress,
		"day_phase": day_phase,
		"is_night": is_night,
		"climate_regrowth_multiplier": regrowth_multiplier,
	}


func clock_text() -> String:
	var total_minutes: int = int(round(day_phase * 1440.0)) % 1440
	return "%02d:%02d" % [total_minutes / 60, total_minutes % 60]


## The pure core. Everything above is a cache over this.
static func evaluate(climate_config: Dictionary, time_seconds: float) -> Dictionary:
	var seasons: Array = climate_config.get("seasons", [])
	if not bool(climate_config.get("enabled", false)) or seasons.is_empty():
		return NEUTRAL.duplicate()

	var day_length: float = maxf(0.001, float(climate_config.get("day_length_seconds", 120.0)))
	var season_length: float = day_length * maxf(0.001, float(climate_config.get("season_length_days", 1.0)))
	var season_count: int = seasons.size()
	var year_length: float = season_length * float(season_count)

	# The season timeline is offset rather than the world time, so `t=0` can be
	# placed in any season without moving the day phase with it.
	var season_time: float = time_seconds + float(int(climate_config.get("start_season_index", 0))) * season_length
	var into_year: float = fposmod(season_time, year_length)
	var current_year: int = int(floor(season_time / year_length))
	var index: int = clampi(int(floor(into_year / season_length)), 0, season_count - 1)
	var progress: float = clampf(fposmod(into_year, season_length) / season_length, 0.0, 1.0)

	var current: Dictionary = seasons[index]
	var upcoming: Dictionary = seasons[(index + 1) % season_count]

	# Hold, then ease. A linear ramp across the whole season would make the
	# declared "winter regrowth 0.4" true only at the instant winter begins, and
	# peaking at the midpoint would put t=0 halfway between winter and spring -
	# which is exactly the neutrality the test suites depend on. Holding for the
	# first 65% and easing over the last 35% gives both: the declared numbers are
	# really reached, and there is no discontinuity at any boundary.
	var transition: float = clampf(float(climate_config.get("season_transition_fraction", 0.35)), 0.0, 1.0)
	var blend: float = 0.0 if transition <= 0.0 else smoothstep(1.0 - transition, 1.0, progress)

	var season_regrowth: float = lerpf(
		float(current.get("regrowth_multiplier", 1.0)),
		float(upcoming.get("regrowth_multiplier", 1.0)), blend)
	var season_metabolism: float = lerpf(
		float(current.get("metabolism_multiplier", 1.0)),
		float(upcoming.get("metabolism_multiplier", 1.0)), blend)
	var season_perception: float = lerpf(
		float(current.get("perception_multiplier", 1.0)),
		float(upcoming.get("perception_multiplier", 1.0)), blend)
	var season_tint: Color = _blend_color(
		_read_color(current.get("tint", null), Color.WHITE),
		_read_color(upcoming.get("tint", null), Color.WHITE), blend)

	var day_config: Dictionary = climate_config.get("day", {})
	var phase: float = fposmod(
		time_seconds / day_length + float(climate_config.get("start_day_phase", 0.5)), 1.0)
	var night: float = _night_ratio(
		phase,
		float(day_config.get("night_start_phase", 0.8)),
		float(day_config.get("night_end_phase", 0.22)),
		float(day_config.get("twilight_fraction", 0.07)))

	var night_perception: float = float(day_config.get("night_perception_multiplier", 1.0))
	var per_species: Dictionary = {}
	for species_key in climate_config.get("species_night_perception_multiplier", {}):
		per_species[species_key] = season_perception * lerpf(
			1.0, float(climate_config["species_night_perception_multiplier"][species_key]), night)

	return {
		"enabled": true,
		"year": current_year,
		"season_index": index,
		"season_id": str(current.get("id", "spring")),
		"season_label": str(current.get("label", current.get("id", "spring"))),
		"season_progress": progress,
		"day_phase": phase,
		"night_ratio": night,
		"is_night": night >= 0.5,
		"regrowth_multiplier": season_regrowth * lerpf(
			1.0, float(day_config.get("night_regrowth_multiplier", 1.0)), night),
		"metabolism_multiplier": season_metabolism * lerpf(
			1.0, float(day_config.get("night_metabolism_multiplier", 1.0)), night),
		"perception_multiplier": season_perception * lerpf(1.0, night_perception, night),
		"perception_multiplier_by_species": per_species,
		"light_color": _apply_tint(
			_sample_light_keyframes(day_config.get("light_keyframes", []), phase), season_tint),
	}


## Night as a smooth 0..1 ramp rather than a flag, so the multipliers and the AI
## bias are driven by one continuous signal and cannot disagree with each other.
##
## Works in a rotated frame where nightfall sits at 0, which makes the wrap past
## midnight ordinary arithmetic instead of a special case.
static func _night_ratio(phase: float, night_start: float, night_end: float, twilight: float) -> float:
	var night_length: float = fposmod(night_end - night_start, 1.0)
	if night_length <= 0.0:
		return 0.0
	var day_length_fraction: float = 1.0 - night_length
	var band: float = clampf(twilight, 0.0, minf(night_length, day_length_fraction) * 0.5)
	var t: float = fposmod(phase - night_start, 1.0)
	if t <= night_length:
		return 1.0
	if band <= 0.0:
		return 0.0
	if t < night_length + band:
		return 1.0 - smoothstep(night_length, night_length + band, t)
	if t > 1.0 - band:
		return smoothstep(1.0 - band, 1.0, t)
	return 0.0


## Piecewise-linear ramp through the keyframes, wrapping from the last back to
## the first across midnight so the colour is continuous everywhere.
static func _sample_light_keyframes(keyframes: Array, phase: float) -> Color:
	if keyframes.is_empty():
		return Color.WHITE
	if keyframes.size() == 1:
		return _read_color(keyframes[0].get("color", null), Color.WHITE)

	var last_index: int = keyframes.size() - 1
	var first_phase: float = float(keyframes[0].get("phase", 0.0))
	var last_phase: float = float(keyframes[last_index].get("phase", 1.0))
	if phase < first_phase or phase >= last_phase:
		var span: float = fposmod(first_phase - last_phase, 1.0)
		var travelled: float = fposmod(phase - last_phase, 1.0)
		var wrap_blend: float = 0.0 if span <= 0.0 else clampf(travelled / span, 0.0, 1.0)
		return _blend_color(
			_read_color(keyframes[last_index].get("color", null), Color.WHITE),
			_read_color(keyframes[0].get("color", null), Color.WHITE), wrap_blend)

	for index in range(last_index):
		var from_phase: float = float(keyframes[index].get("phase", 0.0))
		var to_phase: float = float(keyframes[index + 1].get("phase", 1.0))
		if phase < from_phase or phase > to_phase:
			continue
		var width: float = to_phase - from_phase
		var blend: float = 0.0 if width <= 0.0 else clampf((phase - from_phase) / width, 0.0, 1.0)
		return _blend_color(
			_read_color(keyframes[index].get("color", null), Color.WHITE),
			_read_color(keyframes[index + 1].get("color", null), Color.WHITE), blend)
	return Color.WHITE


static func _read_color(raw, fallback: Color) -> Color:
	if raw is Color:
		return raw
	if raw is Array and raw.size() >= 3:
		return Color(float(raw[0]), float(raw[1]), float(raw[2]))
	return fallback


static func _blend_color(from_color: Color, to_color: Color, blend: float) -> Color:
	return Color(
		lerpf(from_color.r, to_color.r, blend),
		lerpf(from_color.g, to_color.g, blend),
		lerpf(from_color.b, to_color.b, blend))


## Per channel, clamped: the season tint pushes hue (winter cool, autumn warm)
## rather than brightness, so seasons read even at noon while nights stay night.
static func _apply_tint(base: Color, tint: Color) -> Color:
	return Color(
		clampf(base.r * tint.r, 0.0, 1.0),
		clampf(base.g * tint.g, 0.0, 1.0),
		clampf(base.b * tint.b, 0.0, 1.0))
