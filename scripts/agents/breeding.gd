class_name Breeding
extends RefCounted

## When animals breed and how many young they have. Young come from late winter to midsummer,
## most in spring, none in autumn or winter, so the year has a season of young and a winter
## to get through. The season is a curve over the year (`world.climate.breeding_curve`, a
## species may have its own in `species.<id>.breeding.curve`): keyframes `[position, value]`
## along `Climate.season_position`, 0 at the start of spring, wrapping at 4.
##
## A male breeds whenever the curve is above 0. A female breeds where it is 1; on its ramps she
## does when her own draw for the year, hashed from her id, the year and the world's seed, lies
## below it - so the season opens and closes over the ramps rather than at one instant, the
## sleeping and the awake answer alike, and nothing is stored or drawn from the world's rng.
##
## A spring is shorter than a deer's wait between young, so one mating a season brings a
## litter: `litter_mean` young on average (its fraction as a hashed chance of one more), at
## most `litter_max`. Per species in `species.<id>.breeding`; off, or with the climate off, a
## species breeds all year one young at a time, as it always has.

const TraitsScript := preload("res://scripts/agents/traits.gd")
const FERTILITY_SALT := 0xF3A71000
const LITTER_SALT := 0x1177E000
const YEAR_LENGTH_SEASONS := 4.0
const DEFAULTS := {
	"enabled": false,
	"litter_mean": 1.0,
	"litter_max": 1,
}


## The species' `breeding` block with every key, defaults filling the gaps.
static func settings(species_config: Dictionary) -> Dictionary:
	var resolved := DEFAULTS.duplicate()
	resolved.merge(species_config.get("breeding", {}), true)
	return resolved


## The curve's value at `position` (seasons since the start of spring): linear between
## keyframes, and from the last one back round to the first across the new year.
static func curve_value(curve: Array, position: float) -> float:
	if curve.is_empty():
		return 1.0
	if curve.size() == 1:
		return float(curve[0][1])
	var at := fposmod(position, YEAR_LENGTH_SEASONS)
	var last := curve.size() - 1
	var first_at := float(curve[0][0])
	var last_at := float(curve[last][0])
	if at < first_at or at >= last_at:
		var span := fposmod(first_at - last_at, YEAR_LENGTH_SEASONS)
		var travelled := fposmod(at - last_at, YEAR_LENGTH_SEASONS)
		var wrap := 0.0 if span <= 0.0 else clampf(travelled / span, 0.0, 1.0)
		return lerpf(float(curve[last][1]), float(curve[0][1]), wrap)
	for index in range(last):
		var from_at := float(curve[index][0])
		var to_at := float(curve[index + 1][0])
		if at < from_at or at > to_at:
			continue
		var blend := 0.0 if to_at <= from_at else clampf((at - from_at) / (to_at - from_at), 0.0, 1.0)
		return lerpf(float(curve[index][1]), float(curve[index + 1][1]), blend)
	return 1.0


## Whether an animal may breed while the curve stands at `value`: a male whenever it is open
## at all, a female by her own draw for `year`.
static func fertile(agent_id: int, sex: String, value: float, year: int, world: int) -> bool:
	if value >= 1.0:
		return true
	if value <= 0.0:
		return false
	if sex == "male":
		return true
	return TraitsScript.unit(agent_id, FERTILITY_SALT + year, world) < value


## How many young a pair has this `year`: the mean's whole part, and one more by a hashed chance
## of its fraction, between 1 and `maximum`. The same for the pair whichever of them asks.
static func litter(parent_a: int, parent_b: int, year: int, mean: float, maximum: int, world: int) -> int:
	var whole := int(floor(maxf(1.0, mean)))
	var fraction := maxf(1.0, mean) - float(whole)
	var low := mini(parent_a, parent_b)
	var high := maxi(parent_a, parent_b)
	var draw := TraitsScript.unit(low, LITTER_SALT + year + high * 7919, world)
	return clampi(whole + (1 if draw < fraction else 0), 1, maxi(1, maximum))
