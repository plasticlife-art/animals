extends RefCounted

## The world told as a story: names, the family tree, pins, and what the world's events
## carry for them.

const Helpers := preload("res://scripts/tests/test_helpers.gd")
const AnimalNamesScript := preload("res://scripts/story/animal_names.gd")
const StoryBookScript := preload("res://scripts/story/story_book.gd")
const SelectionCardScript := preload("res://scripts/ui/selection_card.gd")
const PinnedBarScript := preload("res://scripts/ui/pinned_bar.gd")
const SaveSystemScript := preload("res://scripts/core/save_system.gd")
const StoryLogScript := preload("res://scripts/story/story_log.gd")
const StoryFeedScript := preload("res://scripts/ui/story_feed.gd")


func run(a) -> void:
	_test_names_stay_and_number_while_alive(a)
	_test_lists_name_the_largest_start(a)
	_test_events_say_who_was_born_and_died(a)
	_test_family_from_the_worlds_events(a)
	_test_sleeping_births_join_the_family(a)
	_test_pins_follow_an_animal_anywhere(a)
	_test_story_survives_a_save(a)
	_test_card_and_list_words(a)
	_test_feed_tells_what_is_looked_at(a)
	_test_feed_folds_and_sums_up(a)
	_test_feed_shows_the_newest(a)


## An animal keeps its name. A newborn takes a name no living animal answers to while the
## list has one; a crowd larger than the list gets numbers, and no two living animals ever
## share a name. A death frees a name for the next.
func _test_names_stay_and_number_while_alive(a) -> void:
	var names = AnimalNamesScript.new()
	var does: Array = AnimalNamesScript.LISTS.herbivore.female
	var first: String = names.name_of(5, "herbivore", "female")
	a.equal(names.name_of(5, "herbivore", "female"), first, "the same name every time")
	a.is_true(does.has(first), "from the does' list")
	var crowd: Array = []
	for index in range(does.size() * 3):
		crowd.append(names.name_of(2000 + index, "herbivore", "female"))
	var distinct := {}
	var numbered := 0
	for name in crowd:
		distinct[name] = true
		if not does.has(name):
			numbered += 1
	a.equal(distinct.size(), crowd.size(), "no two living does share a name")
	a.is_true(numbered >= crowd.size() - does.size() and numbered <= crowd.size() - does.size() + does.size() / 4,
		"numbers only for the ones the list cannot name (%d numbered)" % numbered)
	var fresh = AnimalNamesScript.new()
	var named: String = fresh.name_of(3000, "herbivore", "female")
	a.equal(named, does[AnimalNamesScript.mix(3000) % does.size()], "an empty book gives the first pick")
	fresh.release(3000)
	var twin: int = _ids_with_one_base(does.size(), 3000)
	a.equal(fresh.name_of(twin, "herbivore", "female"), named, "a name a death freed is given again, plainly")
	a.equal(fresh.known(3000), named, "and the dead keep theirs")
	a.is_true(AnimalNamesScript.LISTS.predator.male.has(names.name_of(77, "predator", "male")), "a fox from the foxes' list")
	a.equal(names.name_of(9, "unicorn", "female"), "№9", "a species without names is numbered")
	var copy = AnimalNamesScript.new()
	copy.import_state(names.export_state())
	a.equal(copy.known(2005), names.known(2005), "names come back from a save")
	a.equal([AnimalNamesScript.roman(4), AnimalNamesScript.roman(14), AnimalNamesScript.roman(39)], ["IV", "XIV", "XXXIX"],
		"numbers in Roman")


## Each list holds more names than half the largest starting population any preset gives
## its species, so a number stays the exception until a population outgrows its start, and
## no list repeats a name.
func _test_lists_name_the_largest_start(a) -> void:
	var largest := {"herbivore": 0, "predator": 0, "scavenger": 0}
	for group in Helpers.ConfigLoaderScript.list_option_groups():
		for option in group["options"]:
			var spawns: Dictionary = Helpers.ConfigLoaderScript.load_config_bundle({group["id"]: option["id"]}) \
				.get("world", {}).get("spawns", {})
			for species in largest.keys():
				largest[species] = maxi(int(largest[species]), int(spawns.get("%s_count" % species, 0)))
	for species in largest.keys():
		a.is_true(int(largest[species]) > 0, "%s: a preset starts some" % species)
		for sex in ["female", "male"]:
			var listed: Array = AnimalNamesScript.LISTS[species][sex]
			var distinct := {}
			for name in listed:
				distinct[name] = true
			a.equal(distinct.size(), listed.size(), "%s %s: no name twice" % [species, sex])
			@warning_ignore("integer_division")
			var half: int = int(largest[species]) / 2
			a.is_true(listed.size() > half, "%s %s: %d names for up to %d at the start" % [species, sex,
				listed.size(), half])


## Another id whose first pick is the same name as `agent_id`'s.
static func _ids_with_one_base(list_size: int, agent_id: int) -> int:
	var wanted := AnimalNamesScript.mix(agent_id) % list_size
	for other in range(agent_id + 1, agent_id + 100000):
		if AnimalNamesScript.mix(other) % list_size == wanted:
			return other
	return -1


## Births and deaths carry who they were: the sex of a newborn, the id an animal had when it
## died asleep, both parents of an awake birth, and the herd a split came out of. The
## family tree reads them; nothing else in the world changes.
func _test_events_say_who_was_born_and_died(a) -> void:
	var manager = Helpers.create_manager(671)
	var world = manager.world_state
	var heard: Array = []
	manager.world_event.connect(func(event): heard.append(event))
	var mother = Helpers.spawn_herbivore(world, Vector2(100.0, 100.0), 0)
	a.equal(str(heard[0].get("data", {}).get("sex", "")), "female", "a birth says the newborn's sex")
	var father = Helpers.spawn_species(world, "herbivore", Vector2(110.0, 100.0), 0, Helpers.AgentBaseScript.SEX_MALE)
	heard.clear()
	world.queue_spawn_agent("herbivore", Vector2(105.0, 105.0), 0, father, mother)
	world._flush_spawns()
	var types: Array = []
	for event in heard:
		types.append(str(event.type))
	a.equal(types, ["AgentBorn", "AgentReproduced"], "an awake birth reaches the view with its parents")
	var parents: Dictionary = heard[1].get("data", {})
	a.equal([int(parents.get("parent_a_id", -1)), int(parents.get("parent_b_id", -1))], [father.id, mother.id], "both")
	heard.clear()
	world.emit_population_event("HerdSplit", "herbivore", Vector2.ZERO, {"size": 9, "new_group_id": 4, "group_id": 0, "moved": 5})
	a.equal(str(heard[0].type), "HerdSplit", "a split reaches the view")
	Helpers.destroy_manager(manager)


## The family tree from the world's own events: founders are the first generation, a calf
## knows its mother and father by their sexes, a death says when, of what and by whom.
func _test_family_from_the_worlds_events(a) -> void:
	var manager = Helpers.create_manager(672)
	var world = manager.world_state
	var book = StoryBookScript.new()
	book.bind(manager)
	book.begin()
	var mother = Helpers.spawn_herbivore(world, Vector2(100.0, 100.0), 0)
	var father = Helpers.spawn_species(world, "herbivore", Vector2(110.0, 100.0), 0, Helpers.AgentBaseScript.SEX_MALE)
	world.queue_spawn_agent("herbivore", Vector2(105.0, 105.0), 0, father, mother)
	world._flush_spawns()
	var calf = world.get_agent(world.next_agent_id - 1)
	var entry: Dictionary = book.lineage.entry(calf.id)
	a.equal([int(entry.mother), int(entry.father)], [mother.id, father.id], "the calf knows its mother and father")
	a.equal(int(entry.generation), 2, "and is the second generation")
	a.equal(int(book.lineage.entry(mother.id).generation), 1, "the founders the first")
	a.equal(book.lineage.children(mother.id), [calf.id], "the mother knows her calf")
	a.is_true(book.name_of(calf) != "", "the calf has a name")
	var fox = Helpers.spawn_predator(world, Vector2(60.0, 60.0))
	world.kill_agent(calf, "predation", fox.id)
	var death: Dictionary = book.lineage.entry(calf.id)
	a.is_true(book.lineage.is_dead(calf.id), "the calf's death is noted")
	a.equal([str(death.cause), int(death.killer)], ["predation", fox.id], "of what, and by whom")
	a.equal(book.lineage.descendants_alive(mother.id), 0, "the mother has no living young now")
	Helpers.destroy_manager(manager)


## A birth in a sleeping sector names the mother and the newborn's id, so a herd's family
## goes on while nobody looks; a death there names the animal.
func _test_sleeping_births_join_the_family(a) -> void:
	var manager = Helpers.create_manager(673)
	var world = manager.world_state
	var book = StoryBookScript.new()
	book.bind(manager)
	book.begin()
	var at := Vector2(20.0, 220.0)
	var herd: Array = []
	for index in range(4):
		herd.append(Helpers.spawn_herbivore(world, at + Vector2(float(index) * 3.0, 0.0), 0))
		herd[index].age = 500.0
	var sector_key: Vector2i = world._get_sector_key(at)
	world._sleep_sector(sector_key)
	var state: Dictionary = world._sector_states[sector_key]
	var aggregate: Dictionary = state["dormant_aggregates"][0]
	aggregate["count"] = int(aggregate["count"]) + 1
	aggregate["births_this_step"] = 1
	var newest: int = world.next_agent_id
	world._reconcile_dormant_records(sector_key, state)
	var entry: Dictionary = book.lineage.entry(newest)
	a.is_true(not entry.is_empty(), "the newborn asleep joins the family tree by its id")
	var mothers: Array = []
	for member in herd:
		mothers.append(member.id)
	a.is_true(mothers.has(int(entry.get("mother", -1))), "with its mother, one of the herd")
	a.equal(int(entry.get("generation", 0)), 2, "a generation on")
	book.hear({"type": "AgentDied", "agent_id": -1, "species": "herbivore", "time_seconds": 30.0,
		"position": {"x": 1.0, "y": 2.0}, "data": {"cause": "starvation", "dormant": true, "record_id": newest}})
	a.is_true(book.lineage.is_dead(newest), "and its death asleep is noted under the same id")
	Helpers.destroy_manager(manager)


## A pin keeps an animal on the list wherever it is: awake, asleep in a sector, or dead. At
## most eight.
func _test_pins_follow_an_animal_anywhere(a) -> void:
	var manager = Helpers.create_manager(674)
	var world = manager.world_state
	var book = StoryBookScript.new()
	book.bind(manager)
	book.begin()
	var changes: Array = []
	book.pins_changed.connect(func() -> void: changes.append(true))
	var deer: Array = Helpers.spawn_herd(world, Vector2(120.0, 120.0), 9, 0)
	for index in range(StoryBookScript.MAX_PINS):
		a.is_true(book.toggle_pin(deer[index]), "pin %d" % index)
	a.is_true(not book.toggle_pin(deer[8]), "not past eight")
	a.equal(book.pins.size(), StoryBookScript.MAX_PINS, "eight on the list")
	var awake: Dictionary = book.pin_status(deer[0].id)
	a.is_true(bool(awake.awake) and awake.position == deer[0].position, "awake: where it is")
	world._sector_states[Vector2i(50, 50)] = {"dormant": true, "dormant_aggregates": [
		{"species_type": "herbivore", "group_id": 0, "record_ids": [deer[1].id], "record_positions": PackedVector2Array([Vector2(7.0, 8.0)])}]}
	world.living_agents.erase(deer[1])
	world.agents.erase(deer[1].id)
	var asleep: Dictionary = book.pin_status(deer[1].id)
	a.is_true(not bool(asleep.awake) and asleep.position == Vector2(7.0, 8.0), "asleep: where its sector keeps it")
	world.kill_agent(deer[2], "old_age")
	var dead: Dictionary = book.pin_status(deer[2].id)
	a.is_true(bool(dead.dead) and dead.position == deer[2].position, "dead: where it died")
	a.is_true(not book.toggle_pin(deer[0]) and not book.is_pinned(deer[0].id), "a second press unpins")
	a.is_true(changes.size() >= StoryBookScript.MAX_PINS + 2, "the list hears of every change")
	world._sector_states.erase(Vector2i(50, 50))
	Helpers.destroy_manager(manager)


## Names, the family tree and the pins are saved with the world and come back with it.
func _test_story_survives_a_save(a) -> void:
	var manager = Helpers.create_manager(675)
	var world = manager.world_state
	var book = StoryBookScript.new()
	book.bind(manager)
	book.begin()
	var mother = Helpers.spawn_herbivore(world, Vector2(100.0, 100.0), 0)
	var father = Helpers.spawn_species(world, "herbivore", Vector2(110.0, 100.0), 0, Helpers.AgentBaseScript.SEX_MALE)
	world.queue_spawn_agent("herbivore", Vector2(105.0, 105.0), 0, mother, father)
	world._flush_spawns()
	var calf = world.get_agent(world.next_agent_id - 1)
	book.toggle_pin(calf)
	var calf_name: String = book.name_of(calf)
	var path := "user://story_round_trip.dat"
	a.is_true(SaveSystemScript.save(manager, {}, path, book.export_state()), "saved")
	var data: Dictionary = SaveSystemScript.read(path)
	var loaded = StoryBookScript.new()
	loaded.bind(manager)
	loaded.begin(data.get("story", {}))
	a.equal(loaded.name_of_id(calf.id), calf_name, "the calf keeps its name")
	a.equal(int(loaded.lineage.entry(calf.id).get("mother", -1)), mother.id, "and its mother")
	a.equal(loaded.pins, [calf.id], "and stays pinned")
	var old = StoryBookScript.new()
	old.bind(manager)
	old.begin({})
	a.is_true(old.pins.is_empty() and old.name_of(calf) != "", "a save without a story starts one")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	Helpers.destroy_manager(manager)


## The card's family line links the parents and marks a dead one; the pinned list says
## where an animal is in words.
func _test_card_and_list_words(a) -> void:
	var manager = Helpers.create_manager(676)
	var world = manager.world_state
	var book = StoryBookScript.new()
	book.bind(manager)
	book.begin()
	var mother = Helpers.spawn_herbivore(world, Vector2(100.0, 100.0), 0)
	var father = Helpers.spawn_species(world, "herbivore", Vector2(110.0, 100.0), 0, Helpers.AgentBaseScript.SEX_MALE)
	world.queue_spawn_agent("herbivore", Vector2(105.0, 105.0), 0, mother, father)
	world._flush_spawns()
	var calf = world.get_agent(world.next_agent_id - 1)
	world.kill_agent(mother, "starvation")
	var line: String = SelectionCardScript.family_line(book, calf)
	a.is_true(line.contains("Мать: [url=%d]%s (умерла)[/url]" % [mother.id, book.name_of_id(mother.id)]),
		"the mother who starved, linked: %s" % line)
	a.is_true(line.contains("Отец: [url=%d]%s[/url]" % [father.id, book.name_of_id(father.id)]), "the father, linked")
	a.is_true(line.contains("Поколение 2 · детей нет") and not line.contains("потомков"),
		"the generation, no children: %s" % line)
	var founder_line: String = SelectionCardScript.family_line(book, father)
	a.equal(founder_line.get_slice("\n", 1), "Поколение 1 · детей: 1, живы 1", "a founder: %s" % founder_line)
	a.is_true(founder_line.begins_with("Родители неизвестны") and not founder_line.contains("потомков"),
		"no line for descendants who are all children")
	var mate = Helpers.spawn_herbivore(world, Vector2(108.0, 104.0), 0)
	world.queue_spawn_agent("herbivore", Vector2(106.0, 105.0), 0, calf, mate)
	world._flush_spawns()
	a.equal(SelectionCardScript.family_line(book, father).get_slice("\n", 2), "Живых потомков: 2",
		"a grandchild counts among the descendants")
	world.kill_agent(father, "predation")
	a.is_true(SelectionCardScript.family_line(book, calf).contains("(погиб)[/url]"), "a father a hunter took")
	a.equal(PinnedBarScript.row_text({"name": "Ветка", "species": "herbivore", "sex": "female", "dead": false, "awake": true}),
		"Ветка · олениха", "awake")
	a.equal(PinnedBarScript.row_text({"name": "Рыжик", "species": "predator", "sex": "male", "dead": false, "awake": false}),
		"Рыжик · лис — вдали", "asleep")
	a.equal(PinnedBarScript.row_text({"name": "Ветка", "species": "herbivore", "sex": "female", "dead": true,
		"cause": "predation"}), "Ветка · олениха — погибла", "taken by a hunter")
	a.equal(PinnedBarScript.row_text({"name": "Ветка", "species": "herbivore", "sex": "female", "dead": true,
		"cause": "old_age"}), "Ветка · олениха — умерла", "died of age")
	Helpers.destroy_manager(manager)


## A book on a world whose view covers the ground around (100, 100) and whose selected
## herd is herbivore herd 0.
static func _watched_world(seed_value: int) -> Array:
	var manager = Helpers.create_manager(seed_value)
	var book = StoryBookScript.new()
	book.bind(manager)
	book.begin()
	book.feed.context_provider = func() -> Dictionary:
		return {"view": Rect2(50.0, 50.0, 120.0, 120.0), "herd": ["herbivore", 0]}
	return [manager, manager.world_state, book]


static func _texts(book) -> Array:
	var texts: Array = []
	for line in book.feed.lines:
		texts.append(str(line.text))
	return texts


## Lines of their own for what the player looks at: a kill in view, a birth in the selected
## herd, the death of a pinned animal far away, the selected herd splitting. Anything else
## is only counted.
func _test_feed_tells_what_is_looked_at(a) -> void:
	var setup := _watched_world(681)
	var manager = setup[0]
	var world = setup[1]
	var book = setup[2]
	var doe = Helpers.spawn_herbivore(world, Vector2(100.0, 100.0), 0)
	var fox = Helpers.spawn_species(world, "predator", Vector2(110.0, 100.0), -1, Helpers.AgentBaseScript.SEX_MALE)
	book.meet_living()
	world.kill_agent(doe, "predation", fox.id)
	var kill: Dictionary = book.feed.lines[0]
	a.equal(str(kill.text), "%s, олениха из Стада №1, погибла: задрал лис %s" % [book.name_of_id(doe.id), book.name_of_id(fox.id)],
		"a kill in view, told with both names")
	a.equal(int(kill.focus_id), fox.id, "a click goes to the hunter")
	var mother = Helpers.spawn_herbivore(world, Vector2(400.0, 400.0), 0)
	var father = Helpers.spawn_species(world, "herbivore", Vector2(410.0, 400.0), 0, Helpers.AgentBaseScript.SEX_MALE)
	world.queue_spawn_agent("herbivore", Vector2(405.0, 405.0), 0, father, mother)
	world._flush_spawns()
	var calf = world.get_agent(world.next_agent_id - 1)
	a.equal(str(book.feed.lines[0].text), "Пополнение в Стаде №1: %s %s, мать — %s" % [
		HudText.animal_noun("herbivore", calf.sex, true), book.name_of_id(calf.id), book.name_of_id(mother.id)],
		"a birth in the selected herd, out of view")
	var stranger = Helpers.spawn_herbivore(world, Vector2(400.0, 60.0), 3)
	var before: int = book.feed.lines.size()
	world.kill_agent(stranger, "thirst")
	a.equal(book.feed.lines.size(), before, "a death out of view in another herd gets no line")
	var far_fox = Helpers.spawn_predator(world, Vector2(600.0, 600.0))
	book.toggle_pin(far_fox)
	book.hear({"type": "AgentDied", "agent_id": -1, "species": "predator", "time_seconds": 5.0,
		"position": {"x": 600.0, "y": 600.0}, "data": {"cause": "starvation", "dormant": true, "record_id": far_fox.id}})
	var pinned: Dictionary = book.feed.lines[0]
	a.is_true(bool(pinned.pinned) and str(pinned.text).ends_with("умер вдали от голода"), "a pinned fox far away: %s" % pinned.text)
	world.emit_population_event("HerdSplit", "herbivore", Vector2(900.0, 900.0), {"size": 10, "new_group_id": 4, "group_id": 0, "moved": 5})
	a.equal(str(book.feed.lines[0].text), "Стадо №1 разделилось: 5 голов ушли в новое Стадо №5", "the selected herd splits")
	Helpers.destroy_manager(manager)


## A run of one thing in one herd becomes one line with a number; once a minute everything
## that had no line of its own is summed up for the whole map.
func _test_feed_folds_and_sums_up(a) -> void:
	var setup := _watched_world(682)
	var manager = setup[0]
	var world = setup[1]
	var book = setup[2]
	var mother = Helpers.spawn_herbivore(world, Vector2(100.0, 100.0), 0)
	var father = Helpers.spawn_species(world, "herbivore", Vector2(110.0, 100.0), 0, Helpers.AgentBaseScript.SEX_MALE)
	for index in range(3):
		world.queue_spawn_agent("herbivore", Vector2(105.0, 105.0), 0, father, mother)
	world._flush_spawns()
	a.equal(_texts(book).slice(0, 1), ["Пополнение в Стаде №1: 3 оленёнка"], "three births in one line")
	for index in range(4):
		var far = Helpers.spawn_herbivore(world, Vector2(500.0, 500.0), 7)
		world.kill_agent(far, "starvation")
	var fox = Helpers.spawn_predator(world, Vector2(500.0, 520.0))
	world.kill_agent(fox, "old_age")
	book.feed.tick(0.0)
	book.feed.tick(StoryLogScript.SUMMARY_SECONDS + 1.0)
	a.equal(str(book.feed.lines[0].text), "За минуту по всей карте: голод — 4 оленя · старость — 1 лиса",
		"the minute summed up")
	a.equal(StoryLogScript.summary_text({"deaths:predation:herbivore": 2, "deaths:predation:scavenger": 1,
		"births:herbivore": 5, "births:predator": 2}),
		"За минуту по всей карте: хищники — 2 оленя, 1 тетерев · родились — 5 оленят, 2 лисёнка", "every part")
	for index in range(StoryLogScript.CAPACITY + 5):
		world.emit_population_event("HerdSplit", "herbivore", Vector2(100.0, 100.0),
			{"size": 10, "new_group_id": 9, "group_id": 0, "moved": 5})
	a.equal(book.feed.lines.size(), StoryLogScript.CAPACITY, "kept within its capacity")
	Helpers.destroy_manager(manager)


## The feed shows the newest lines with the time of day, quiet while there are none.
func _test_feed_shows_the_newest(a) -> void:
	var setup := _watched_world(683)
	var manager = setup[0]
	var book = setup[2]
	var feed = StoryFeedScript.new()
	feed.bind(book.feed, manager)
	a.is_true(feed._quiet.visible and feed._rows.get_child_count() == 0, "quiet at first")
	for index in range(10):
		manager.world_state.emit_population_event("HerdSplit", "herbivore", Vector2(100.0, 100.0),
			{"size": 10, "new_group_id": 20 + index, "group_id": 0, "moved": 5})
	a.equal(feed._rows.get_child_count(), StoryFeedScript.MAX_ROWS, "the newest few")
	a.is_true(not feed._quiet.visible, "no longer quiet")
	var shown: String = feed._rows.get_child(0).text
	a.is_true(RegEx.create_from_string("^\\d\\d:\\d\\d  Стадо №1 разделилось").search(shown) != null,
		"with the time of day first: %s" % shown)
	feed.free()
	Helpers.destroy_manager(manager)
