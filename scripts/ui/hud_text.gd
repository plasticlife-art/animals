class_name HudText
extends RefCounted

## The Russian words the always-on readouts use: species, herds, biomes, causes of death
## and how long ago something happened. One table, so the strip at the top and the herd
## card at the bottom name things the same way, and as the help screen does.

const SPECIES := {"herbivore": "Травоядные", "predator": "Хищники", "scavenger": "Падальщики"}
## What a group of each species is called; predators keep to pairs and have none.
const GROUPS := {"herbivore": "Стадо", "scavenger": "Стая"}
## The same nouns after «за», for the button that follows one.
const GROUPS_FOLLOWED := {"herbivore": "стадом", "scavenger": "стаей"}
const BIOMES := {"meadow": "Луг", "forest": "Лес", "drought": "Засуха", "swamp": "Болото"}
## The biomes the strip reports, in the order it reports them.
const BIOME_ORDER := ["meadow", "forest", "drought", "swamp"]
const CAUSES := {"starvation": "голод", "thirst": "жажда", "predation": "хищник", "old_age": "старость"}


static func species_label(species_id: String) -> String:
	return str(SPECIES.get(species_id, species_id))


static func group_noun(species_id: String) -> String:
	return str(GROUPS.get(species_id, "Группа"))


static func biome_label(biome_id: String) -> String:
	return str(BIOMES.get(biome_id, biome_id))


static func cause_label(cause: String) -> String:
	return str(CAUSES.get(cause, cause))


## Herds are numbered from one on screen; their ids start at zero.
static func herd_number(group_id: int) -> int:
	return group_id + 1


## How long ago, in the simulation's seconds: «только что», «40 с назад», «3 мин назад».
static func ago_text(seconds: float) -> String:
	if seconds < 2.0:
		return "только что"
	if seconds < 60.0:
		return "%d с назад" % int(seconds)
	if seconds < 3600.0:
		return "%d мин назад" % int(seconds / 60.0)
	return "%d ч назад" % int(seconds / 3600.0)
