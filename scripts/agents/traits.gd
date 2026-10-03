class_name Traits
extends RefCounted

## What an animal inherited: four multipliers on its species' values, 1.0 being the species as
## `species.json` writes it. `speed` scales how fast it walks and runs, `vision` how far it
## sees, `appetite` its metabolic rate, `longevity` its lifespan.
##
## Every advantage has a price, so a population has somewhere to settle instead of climbing to
## the cap: a fast runner burns its energy by the square of its speed when it runs and gets
## hungrier; a far-sighted one gets a little hungrier; a quick metabolism gets hungry faster but
## fills up faster too - each bite feeds it more - so it eats as much and more often; a long life
## is a slow one - it matures later and waits longer between young, by the same factor.
##
## Appetite once paid back in strength instead (rest recovered with it). Breeding needs both a
## fed animal and a rested one, and spread across those two thresholds it cost the grazers a
## sixth of their births on a seed and a third of their numbers: food for food keeps it off them.
##
## Founders spread around 1.0; a young one takes its parents' mean and a small mutation, inside
## the clamps. Every draw is a hash of the animal's id, a salt and the world's seed (`world`), never
## the world's rng, so the shared stream that decides everything else is not touched: with traits
## off - or all at 1.0 - a world plays exactly as it did before there were any. Per species in
## `species.<id>.traits`.

const NAMES := ["speed", "vision", "appetite", "longevity"]
const SPEED := 0
const VISION := 1
const APPETITE := 2
const LONGEVITY := 3
const NEUTRAL := [1.0, 1.0, 1.0, 1.0]
const SALTS := [0x5BEE, 0x515E, 0xA99E, 0x10AE]
const DEFAULTS := {
	"enabled": false,
	"founder_spread": 0.08,
	"mutation": 0.04,
	"clamp": 0.25,
	"longevity_clamp": 0.10,
	"run_cost_exponent": 2.0,
	"speed_hunger": 0.5,
	"vision_hunger": 0.3,
}


## The species' `traits` block with every key, defaults filling the gaps.
static func settings(species_config: Dictionary) -> Dictionary:
	var resolved := DEFAULTS.duplicate()
	resolved.merge(species_config.get("traits", {}), true)
	return resolved


static func enabled(species_config: Dictionary) -> bool:
	return bool(settings(species_config)["enabled"])


## A founder's traits: each within `founder_spread` of 1.0, hashed from its id and the world.
static func founder(agent_id: int, species_config: Dictionary, world := 0) -> Array:
	var config := settings(species_config)
	var spread := float(config["founder_spread"])
	var values: Array = []
	for index in range(NAMES.size()):
		values.append(1.0 + spread * (unit(agent_id, SALTS[index], world) * 2.0 - 1.0))
	return clamped(values, config)


## A young one's traits: its parents' mean, each moved by up to `mutation`, hashed from its id and
## the world. A missing parent counts as the other.
static func inherit(child_id: int, parent_a: Array, parent_b: Array, species_config: Dictionary, world := 0) -> Array:
	var config := settings(species_config)
	var a: Array = parent_a if parent_a.size() == NAMES.size() else (parent_b if parent_b.size() == NAMES.size() else NEUTRAL)
	var b: Array = parent_b if parent_b.size() == NAMES.size() else a
	var mutation := float(config["mutation"])
	var values: Array = []
	for index in range(NAMES.size()):
		var mean := (float(a[index]) + float(b[index])) * 0.5
		values.append(mean + mutation * (unit(child_id, SALTS[index] + 0x777, world) * 2.0 - 1.0))
	return clamped(values, config)


static func clamped(values: Array, config: Dictionary) -> Array:
	var reach := float(config.get("clamp", DEFAULTS["clamp"]))
	var long_reach := float(config.get("longevity_clamp", DEFAULTS["longevity_clamp"]))
	var out: Array = []
	for index in range(NAMES.size()):
		var limit := long_reach if index == LONGEVITY else reach
		out.append(clampf(float(values[index]), 1.0 - limit, 1.0 + limit))
	return out


## How much hungrier than the species these traits make an animal: its appetite, plus what
## running fast and seeing far cost.
static func hunger_factor(values: Array, config: Dictionary) -> float:
	return maxf(0.1, float(values[APPETITE]) * (1.0 + float(config["speed_hunger"]) * (float(values[SPEED]) - 1.0)
		+ float(config["vision_hunger"]) * (float(values[VISION]) - 1.0)))


## What a run costs against the species: the speed to `run_cost_exponent`.
static func run_cost_factor(values: Array, config: Dictionary) -> float:
	return pow(maxf(0.1, float(values[SPEED])), float(config["run_cost_exponent"]))


## A record's traits (`export_runtime_state()`), neutral when it has none.
static func of_record(record: Dictionary) -> Array:
	var values: Array = record.get("traits", NEUTRAL)
	return values if values.size() == NAMES.size() else NEUTRAL


## A value in [0, 1) from an id, a salt and a world seed, the same on every machine.
static func unit(value: int, salt: int, world := 0) -> float:
	var h: int = (_mul32(value & 0xFFFFFFFF, 0x2C1B3C6D) ^ _mul32(salt & 0xFFFFFFFF, 0x297A2D39)
		^ _mul32(world & 0xFFFFFFFF, 0x165667B1) ^ 0x9E3779B9) & 0xFFFFFFFF
	h ^= h >> 15
	h = _mul32(h, 0x85EBCA6B)
	h ^= h >> 13
	h = _mul32(h, 0xC2B2AE35)
	h ^= h >> 16
	return float(h & 0xFFFFFF) / 16777216.0


## `(value * factor) mod 2^32` for 32-bit inputs, split so no partial product leaves 64 bits
## (`WorldState._mul32()`): an overflow would be the platform's to decide.
static func _mul32(value: int, factor: int) -> int:
	return (value * (factor & 0xFFFF) + (((value * (factor >> 16)) & 0xFFFF) << 16)) & 0xFFFFFFFF
