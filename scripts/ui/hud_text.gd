class_name HudText
extends RefCounted

## Every word the interface shows about the world, in Russian, in one table: species and
## the animals in them, herds, biomes, causes of death, what an animal is doing, and the
## grammar those need - a verb in the animal's gender, a noun after a number. The strip,
## the cards, the tag, the event feed and the developer panel all name things through
## here, so they name them the same way, and as the help screen does.

const SPECIES := {"herbivore": "Травоядные", "predator": "Хищники", "scavenger": "Падальщики"}
## What a group of each species is called; predators keep to pairs and have none.
const GROUPS := {"herbivore": "Стадо", "scavenger": "Стая"}
## The same nouns after «за», for the button that follows one.
const GROUPS_FOLLOWED := {"herbivore": "стадом", "scavenger": "стаей"}
## After «из» / «в»: «из Стада №3», «в Стае №2».
const GROUPS_GENITIVE := {"herbivore": "Стада", "scavenger": "Стаи"}
const GROUPS_PREPOSITIONAL := {"herbivore": "Стаде", "scavenger": "Стае"}
## After «стали»: «стали Стадом №8».
const GROUPS_INSTRUMENTAL := {"herbivore": "Стадом", "scavenger": "Стаей"}
const BIOMES := {"meadow": "Луг", "forest": "Лес", "drought": "Засуха", "swamp": "Болото"}
## The biomes the strip reports, in the order it reports them.
const BIOME_ORDER := ["meadow", "forest", "drought", "swamp"]
const CAUSES := {"starvation": "голод", "thirst": "жажда", "predation": "хищник", "old_age": "старость"}
## «умер от …»: the cause after «от».
const CAUSES_FROM := {"starvation": "голода", "thirst": "жажды", "predation": "хищника", "old_age": "старости"}

## The animal each species is drawn as, by sex and for a young one, and the forms a count
## takes: one, two to four, five and more (`plural()`).
const ANIMALS := {
	"herbivore": {"male": "олень", "female": "олениха", "young": "оленёнок",
		"count": ["олень", "оленя", "оленей"], "young_count": ["оленёнок", "оленёнка", "оленят"]},
	"predator": {"male": "лис", "female": "лиса", "young": "лисёнок",
		"count": ["лиса", "лисы", "лис"], "young_count": ["лисёнок", "лисёнка", "лисят"]},
	"scavenger": {"male": "тетерев", "female": "тетёрка", "young": "птенец",
		"count": ["тетерев", "тетерева", "тетеревов"], "young_count": ["птенец", "птенца", "птенцов"]},
}
const SEX_GLYPHS := {"female": "♀", "male": "♂"}
const AGE_STAGES := {
	"young": ["молодой", "молодая"], "adult": ["взрослый", "взрослая"], "old": ["старый", "старая"],
}

## What an animal is doing (`AgentBase.current_action`).
const ACTIONS := {
	"none": "Стоит",
	"graze": "Пасётся",
	"drink": "Пьёт",
	"rest": "Отдыхает",
	"explore": "Бродит",
	"join_herd": "Догоняет своих",
	"flee_to_safe_area": "Убегает",
	"hunt_prey": "Охотится",
	"scavenge_carcass": "Ест падаль",
	"investigate_water": "Ищет воду",
	"pair_cohesion": "Идёт за парой",
	"patrol": "Обходит угодья",
	"reproduce": "Ищет пару",
}
## The finer state under the action (`AgentBase.state`), for the developer panel and the
## state labels.
const STATES := {
	"idle": "стоит", "wander": "бродит", "seek_food": "ищет корм", "eat": "ест", "drink": "пьёт",
	"seek_water": "идёт к воде", "rest": "отдыхает", "flee": "убегает", "regroup": "собирается",
	"migrate": "кочует", "reproduce": "ищет пару", "seek_prey": "высматривает добычу",
	"chase": "гонится", "search_last_seen": "ищет след", "attack": "нападает",
	"seek_carcass": "идёт к туше", "feed_carcass": "ест тушу", "investigate_water": "ищет воду",
	"pair_cohesion": "держится пары", "patrol": "обходит угодья", "dead": "мёртв",
}


static func species_label(species_id: String) -> String:
	return str(SPECIES.get(species_id, species_id))


static func group_noun(species_id: String) -> String:
	return str(GROUPS.get(species_id, "Группа"))


static func biome_label(biome_id: String) -> String:
	return str(BIOMES.get(biome_id, biome_id))


static func cause_label(cause: String) -> String:
	return str(CAUSES.get(cause, cause))


static func action_label(action: String) -> String:
	return str(ACTIONS.get(action, action))


static func state_label(state: String) -> String:
	return str(STATES.get(state, state))


## Herds are numbered from one on screen; their ids start at zero.
static func herd_number(group_id: int) -> int:
	return group_id + 1


## «Стадо №5»; with `case` "genitive", "prepositional" or "instrumental" the noun
## declines: «Стада №5», «Стаде №5», «Стадом №5».
static func herd_name(species_id: String, group_id: int, case := "") -> String:
	var table: Dictionary = {"genitive": GROUPS_GENITIVE, "prepositional": GROUPS_PREPOSITIONAL,
		"instrumental": GROUPS_INSTRUMENTAL}.get(case, GROUPS)
	return "%s №%d" % [str(table.get(species_id, group_noun(species_id))), herd_number(group_id)]


## The animal an individual is: «олень», «олениха», «оленёнок» for a young one.
static func animal_noun(species_id: String, sex: String, young := false) -> String:
	var words: Dictionary = ANIMALS.get(species_id, {})
	if words.is_empty():
		return species_label(species_id).to_lower()
	if young:
		return str(words["young"])
	return str(words["female" if sex == "female" else "male"])


## «3 оленя», «5 оленят»: a count with its noun in the right form.
static func animal_count(species_id: String, count: int, young := false) -> String:
	var words: Dictionary = ANIMALS.get(species_id, {})
	if words.is_empty():
		return "%d %s" % [count, species_label(species_id).to_lower()]
	return "%d %s" % [count, plural(count, words["young_count" if young else "count"])]


## The form of a noun after `count`: `forms` is [one, two to four, five and more], as in
## [«голова», «головы», «голов»].
static func plural(count: int, forms: Array) -> String:
	var last_two := absi(count) % 100
	var last := last_two % 10
	if last_two >= 11 and last_two <= 14:
		return str(forms[2])
	if last == 1:
		return str(forms[0])
	if last >= 2 and last <= 4:
		return str(forms[1])
	return str(forms[2])


## A past-tense verb in the animal's gender: `masculine` or `feminine`.
static func verb(sex: String, masculine: String, feminine: String) -> String:
	return feminine if sex == "female" else masculine


## «погибла» to a hunter, «умерла» of hunger, thirst or age.
static func died(sex: String, cause: String) -> String:
	return verb(sex, "погиб", "погибла") if cause == "predation" else verb(sex, "умер", "умерла")


static func age_label(stage: String, sex: String) -> String:
	var forms: Array = AGE_STAGES.get(stage, [stage, stage])
	return str(forms[1] if sex == "female" else forms[0])


static func sex_glyph(sex: String) -> String:
	return str(SEX_GLYPHS.get(sex, ""))


## How long ago, in the simulation's seconds: «только что», «40 с назад», «3 мин назад».
static func ago_text(seconds: float) -> String:
	if seconds < 2.0:
		return "только что"
	if seconds < 60.0:
		return "%d с назад" % int(seconds)
	if seconds < 3600.0:
		return "%d мин назад" % int(seconds / 60.0)
	return "%d ч назад" % int(seconds / 3600.0)
