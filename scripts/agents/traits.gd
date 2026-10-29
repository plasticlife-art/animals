class_name Traits
extends RefCounted

## What an animal inherited: multipliers on its species' values, 1.0 being the species as
## `species.json` writes it. `speed` scales how fast it walks and runs, `vision` how far it
## sees, `appetite` its metabolic rate, `longevity` its lifespan. `marker` scales nothing: it is
## inherited and mutates like the others, so how far it wanders is how far chance alone moves a
## trait - the chronicle's yardstick for telling selection from drift (`TraitInsights`).
## `caution` is how long a grazer stays scared once it has seen a hunter, how far it runs and how
## wary it is of ground where hunters have been; `drought` how slowly it gets thirsty; `size` its
## build - a big body is hard to bring down and a big hunter strikes surer, and hunger rises
## slowly in it, but every bite fills it less and it turns slowly.
##
## Every advantage has a price, so a population has somewhere to settle instead of climbing to
## the cap: a fast runner burns its energy by the square of its speed when it runs and gets
## hungrier; a far-sighted one gets a little hungrier; a quick metabolism gets hungry faster but
## fills up faster too - each bite feeds it more - so it eats as much and more often; a long life
## is a slow one - it matures later and waits longer between young, by the same factor. A cautious
## one pays in grazing time - it runs from what a bolder one ignores and leaves good grass where
## hunters were - and asleep, where nobody runs, in hunger (`sleeping_hunger_factor()`); one that
## thirsts slowly gets its water from its food and is hungrier; a big one needs food as its size to
## the three quarters, a small one less, as bodies do.
##
## Which of these a species has is `traits.list`; one it lacks stays at 1.0 and costs nothing, so
## a species without the newer ones plays as it did.
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

const NAMES := ["speed", "vision", "appetite", "longevity", "marker", "caution", "drought", "size"]
const SPEED := 0
const VISION := 1
const APPETITE := 2
const LONGEVITY := 3
const MARKER := 4
const CAUTION := 5
const DROUGHT := 6
const SIZE := 7
const NEUTRAL := [1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0]
## One per trait: a trait's draws never move another's, so a trait added later leaves the first
## ones as they were.
const SALTS := [0x5BEE, 0x515E, 0xA99E, 0x10AE, 0x3A4C, 0xCA07, 0xD207, 0x512E]
## The traits a species has when its `traits.list` does not say: those from before the newer ones.
const FIRST_LIST := ["speed", "vision", "appetite", "longevity", "marker"]
const DEFAULTS := {
	"enabled": false,
	"list": FIRST_LIST,
	"founder_spread": 0.08,
	"mutation": 0.04,
	"clamp": 0.25,
	"longevity_clamp": 0.10,
	"run_cost_exponent": 2.0,
	"speed_hunger": 0.5,
	"vision_hunger": 0.3,
	# Asleep nobody runs from anything, so caution's grazing time is paid in hunger there.
	"caution_sleep_hunger": 0.3,
	"drought_hunger": 0.4,
	# Hunger rises as size to this, each bite fills as one over size: food as size to the 3/4.
	"size_hunger_exponent": -0.25,
	# A strike's chance moves by this for each whole of the hunter's size over its prey's.
	"size_attack": 0.4,
	"size_turn_exponent": -0.5,
}


## The species' `traits` block with every key, defaults filling the gaps.
static func settings(species_config: Dictionary) -> Dictionary:
	var resolved := DEFAULTS.duplicate()
	resolved.merge(species_config.get("traits", {}), true)
	return resolved


static func enabled(species_config: Dictionary) -> bool:
	return bool(settings(species_config)["enabled"])


## Whether trait `index` is one the species has (`traits.list`).
static func has_trait(config: Dictionary, index: int) -> bool:
	return Array(config.get("list", FIRST_LIST)).has(NAMES[index])


## The indices of the traits a species has, in `NAMES` order.
static func indices(species_config: Dictionary) -> Array:
	var config := settings(species_config)
	var out: Array = []
	for index in range(NAMES.size()):
		if has_trait(config, index):
			out.append(index)
	return out


## A founder's traits: each within `founder_spread` of 1.0, hashed from its id and the world.
static func founder(agent_id: int, species_config: Dictionary, world := 0) -> Array:
	var config := settings(species_config)
	var spread := float(config["founder_spread"])
	var values: Array = []
	for index in range(NAMES.size()):
		values.append(1.0 + spread * (unit(agent_id, SALTS[index], world) * 2.0 - 1.0) if has_trait(config, index) else 1.0)
	return clamped(values, config)


## A young one's traits: its parents' mean, each moved by up to `mutation`, hashed from its id and
## the world. A missing parent counts as the other.
static func inherit(child_id: int, parent_a: Array, parent_b: Array, species_config: Dictionary, world := 0) -> Array:
	var config := settings(species_config)
	var a: Array = padded(parent_a if not parent_a.is_empty() else parent_b)
	var b: Array = padded(parent_b) if not parent_b.is_empty() else a
	var mutation := float(config["mutation"])
	var values: Array = []
	for index in range(NAMES.size()):
		if not has_trait(config, index):
			values.append(1.0)
			continue
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
## running fast, seeing far and thirsting slowly cost, as its size has hunger rise.
static func hunger_factor(values: Array, config: Dictionary) -> float:
	return maxf(0.1, float(values[APPETITE]) * (1.0 + float(config["speed_hunger"]) * (float(values[SPEED]) - 1.0)
		+ float(config["vision_hunger"]) * (float(values[VISION]) - 1.0)
		+ float(config["drought_hunger"]) * (float(values[DROUGHT]) - 1.0))
		* pow(maxf(0.1, float(values[SIZE])), float(config["size_hunger_exponent"])))


## `hunger_factor()` for an animal asleep, where its caution's grazing time is paid in hunger.
static func sleeping_hunger_factor(values: Array, config: Dictionary) -> float:
	return maxf(0.1, hunger_factor(values, config) * (1.0 + float(config["caution_sleep_hunger"]) * (float(values[CAUTION]) - 1.0)))


## How much a bite or a meal fills against the species: a quick metabolism more, a big body less.
static func fill_factor(values: Array) -> float:
	return float(values[APPETITE]) / maxf(0.1, float(values[SIZE]))


## How much more slowly than the species it gets thirsty.
static func thirst_factor(values: Array) -> float:
	return 1.0 / maxf(0.1, float(values[DROUGHT]))


## How quickly it can turn against the species: a big body slower.
static func turn_factor(values: Array, config: Dictionary) -> float:
	return pow(maxf(0.1, float(values[SIZE])), float(config["size_turn_exponent"]))


## What a run costs against the species: the speed to `run_cost_exponent`.
static func run_cost_factor(values: Array, config: Dictionary) -> float:
	return pow(maxf(0.1, float(values[SPEED])), float(config["run_cost_exponent"]))


## A record's traits (`export_runtime_state()`), neutral when it has none.
static func of_record(record: Dictionary) -> Array:
	return padded(record.get("traits", NEUTRAL))


## `values` with one for every trait: a save from before a trait was added has fewer, and the
## missing ones are the species (1.0); none at all is the species throughout.
static func padded(values) -> Array:
	if values == null or values.size() == 0:
		return NEUTRAL.duplicate()
	if values.size() == NAMES.size():
		return Array(values)
	var out: Array = []
	for index in range(NAMES.size()):
		out.append(float(values[index]) if index < values.size() else 1.0)
	return out


## Zeros, one per trait: the start of a sum over animals.
static func zeros() -> Array:
	var out: Array = []
	out.resize(NAMES.size())
	out.fill(0.0)
	return out


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
