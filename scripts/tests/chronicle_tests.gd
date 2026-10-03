extends RefCounted

## The chronicle: names for the land, what the family tree counts, epitaphs, the chronicle
## window and the card's «Почему?».

const Helpers := preload("res://scripts/tests/test_helpers.gd")
const PlaceNamesScript := preload("res://scripts/story/place_names.gd")
const PlaceLabelsScript := preload("res://scripts/ui/place_labels.gd")
const StoryBookScript := preload("res://scripts/story/story_book.gd")
const MiniMapScript := preload("res://scripts/ui/minimap.gd")
const LineageScript := preload("res://scripts/story/lineage.gd")
const StoryRecordsScript := preload("res://scripts/story/story_records.gd")
const AnimalNamesScript := preload("res://scripts/story/animal_names.gd")


func run(a) -> void:
	_test_place_names_decline(a)
	_test_every_adjective_has_its_ending(a)
	_test_places_of_a_real_map(a)
	_test_feed_says_where(a)
	_test_places_survive_a_save(a)
	_test_labels_fade_with_zoom(a)
	_test_minimap_names_the_place_under_the_cursor(a)
	_test_kills_and_ages_from_events(a)
	_test_sleeping_kill_credits_a_hunter(a)
	_test_descendants_kept_running(a)
	_test_age_text(a)
	_test_records_rank(a)


## Names agree with their nouns in gender, and the phrases take the right case and preposition.
func _test_place_names_decline(a) -> void:
	var cases := [
		[PlaceNamesScript.compose("Тихий:v", ["заводь", "f", "заводи"]), "Тихая заводь", "у Тихой заводи"],
		[PlaceNamesScript.compose("Лисий:p", ["брод", "m", "брода"]), "Лисий брод", "у Лисьего брода"],
		[PlaceNamesScript.compose("Синий:s", ["озеро", "n", "озера"]), "Синее озеро", "у Синего озера"],
		[PlaceNamesScript.compose("Глухой:o", ["омут", "m", "омута"]), "Глухой омут", "у Глухого омута"],
		[PlaceNamesScript.compose("Медовый:h", ["луг", "m", "лугу", "на"], true), "Медовый луг", "на Медовом лугу"],
		[PlaceNamesScript.compose("Сухой:o", ["степь", "f", "степи", "в"], true), "Сухая степь", "в Сухой степи"],
		[PlaceNamesScript.compose("Рыжий:z", ["плато", "n", "плато", "на"], true), "Рыжее плато", "на Рыжем плато"],
		[PlaceNamesScript.compose("Медвежий:p", ["чаща", "f", "чаще", "в"], true), "Медвежья чаща", "в Медвежьей чаще"],
		[PlaceNamesScript.compose("Горький:v", ["солончак", "m", "солончаке", "на"], true), "Горький солончак",
			"на Горьком солончаке"],
		[PlaceNamesScript.compose("Дальний:s", ["топь", "f", "топи", "в"], true), "Дальняя топь", "в Дальней топи"],
	]
	for case in cases:
		a.equal(case[0]["name"], case[1], "name %s" % case[1])
		a.equal(case[0]["at"], case[2], "phrase %s" % case[2])


## A typo in a declension type would decline a word into nonsense; each word must end as its
## type says.
func _test_every_adjective_has_its_ending(a) -> void:
	var words: Array = PlaceNamesScript.POND_ADJECTIVES + PlaceNamesScript.SHARED_ADJECTIVES
	for biome in PlaceNamesScript.DISTRICT_ADJECTIVES.keys():
		words += PlaceNamesScript.DISTRICT_ADJECTIVES[biome]
	var endings := {"h": "ый", "o": "ой", "v": "ий", "z": "ий", "s": "ний", "p": "ий"}
	var wrong: Array = []
	for entry in words:
		var parts := str(entry).split(":")
		if parts.size() != 2 or not endings.has(parts[1]) or not parts[0].ends_with(endings[parts[1]]):
			wrong.append(entry)
		elif parts[1] == "v" and not parts[0].substr(parts[0].length() - 3, 1) in ["к", "г", "х"]:
			wrong.append(entry)
		elif parts[1] == "z" and not parts[0].substr(parts[0].length() - 3, 1) in ["ж", "ш", "ч", "щ"]:
			wrong.append(entry)
	a.is_true(wrong.is_empty(), "adjectives end as their type says: %s" % str(wrong))
	for biome in ["meadow", "forest", "drought", "swamp"]:
		a.is_true(PlaceNamesScript.DISTRICT_NOUNS.has(biome) and PlaceNamesScript.DISTRICT_ADJECTIVES.has(biome),
			"%s districts have words" % biome)


## The default map: every pond named once, every cell in a district, each district's label
## inside it, and the same seed naming the same way.
func _test_places_of_a_real_map(a) -> void:
	var manager = Helpers.create_manager_with(Helpers.ConfigLoaderScript.load_config_bundle(), 3)
	var world = manager.world_state
	var places = PlaceNamesScript.new()
	places.build(world, 3)
	a.equal(places.ponds.size(), world.water_sources.size(), "every pond named")
	var distinct := {}
	for pond in places.ponds:
		distinct[pond["name"]] = true
	a.equal(distinct.size(), places.ponds.size(), "no two ponds share a name")
	a.is_true(places.districts.size() >= 12 and places.districts.size() <= 40,
		"a large map has a couple of dozen districts (%d)" % places.districts.size())
	var unassigned := 0
	for district in places._cell_district:
		if district < 0:
			unassigned += 1
	a.equal(unassigned, 0, "every cell belongs to a district")
	var outside := 0
	for index in range(places.districts.size()):
		if places.district_at(places.districts[index]["center"]) != index:
			outside += 1
	a.equal(outside, 0, "each label lies in its own district")
	var biomes := {}
	for district in places.districts:
		biomes[district["biome"]] = true
	a.is_true(biomes.size() >= 2, "districts are not all meadows: %s" % str(biomes.keys()))
	var pond: Dictionary = places.ponds[0]
	var near: Dictionary = places.place_at(pond["position"] + Vector2(float(pond["radius"]) * 1.2, 0.0))
	a.equal(near.get("name", ""), pond["name"], "by a pond, the pond")
	a.is_true(str(near.get("at", "")).begins_with("у "), "«у …» a pond")
	var far := _far_from_ponds(places, world.bounds)
	var there: Dictionary = places.place_at(far)
	a.equal(there.get("kind", ""), "district", "away from water, the district")
	a.is_true(str(there.get("at", "")).begins_with("на ") or str(there.get("at", "")).begins_with("в "),
		"«на …» or «в …» a district: %s" % there.get("at", ""))
	a.equal(places.place_at(Vector2(-500.0, -500.0)), {}, "off the map, nowhere")
	var again = PlaceNamesScript.new()
	again.build(world, 3)
	a.equal(again.export_state(), places.export_state(), "the same seed names the same places")
	var other = PlaceNamesScript.new()
	other.build(world, 4)
	a.is_true(other.export_state() != places.export_state(), "another seed names them otherwise")
	Helpers.destroy_manager(manager)


## Deaths, births and splits say where; out of view, a named place stands in for «вдали».
func _test_feed_says_where(a) -> void:
	var manager = Helpers.create_manager(851)
	var world = manager.world_state
	var book = StoryBookScript.new()
	book.bind(manager)
	book.begin()
	var pond: Dictionary = book.places.ponds[0] if not book.places.ponds.is_empty() else {}
	a.is_true(not pond.is_empty(), "the fixture world has a pond")
	var mother = Helpers.spawn_herbivore(world, pond.get("position", Vector2(100.0, 100.0)), 0)
	book.feed.context_provider = func() -> Dictionary: return {"view": Rect2(-1000.0, -1000.0, 4000.0, 4000.0)}
	book.toggle_pin(mother)
	world.kill_agent(mother, "starvation")
	var line: Dictionary = book.feed.lines[0] if not book.feed.lines.is_empty() else {}
	a.is_true(str(line.get("text", "")).ends_with("от голода %s" % pond.get("at", "")),
		"a death says where: %s" % line.get("text", ""))
	a.equal(line.get("at", ""), pond.get("at", ""), "and keeps the place on the line")
	book.hear({"type": "AgentDied", "agent_id": -1, "species": "herbivore", "time_seconds": 10.0,
		"position": {"x": pond["position"].x, "y": pond["position"].y},
		"data": {"cause": "old_age", "record_id": 990001, "group_id": 0, "dormant": true}})
	book.feed.context_provider = func() -> Dictionary: return {"herd": ["herbivore", 0]}
	book.hear({"type": "AgentDied", "agent_id": -1, "species": "herbivore", "time_seconds": 30.0,
		"position": {"x": pond["position"].x, "y": pond["position"].y},
		"data": {"cause": "old_age", "record_id": 990002, "group_id": 0, "dormant": true}})
	var asleep: String = book.feed.lines[0]["text"]
	a.is_true(asleep.contains(pond["at"]) and not asleep.contains("вдали"),
		"asleep, the place instead of «вдали»: %s" % asleep)
	book.hear({"type": "AgentDied", "agent_id": -1, "species": "herbivore", "time_seconds": 60.0,
		"position": {"x": -900.0, "y": -900.0},
		"data": {"cause": "old_age", "record_id": 990003, "group_id": 0, "dormant": true}})
	a.is_true(str(book.feed.lines[0]["text"]).contains("вдали"), "nowhere named, still «вдали»")
	Helpers.destroy_manager(manager)


func _test_places_survive_a_save(a) -> void:
	var manager = Helpers.create_manager(852)
	var book = StoryBookScript.new()
	book.bind(manager)
	book.begin()
	var saved: Dictionary = book.export_state()
	a.is_true(saved.has("places"), "the story keeps its places")
	saved["places"]["ponds"][0] = ["Старая купель", "у Старой купели"]
	var other = StoryBookScript.new()
	other.bind(manager)
	other.begin(saved)
	a.equal(other.places.ponds[0]["name"], "Старая купель", "a saved name comes back over a new one")
	a.equal(other.places.at(other.places.ponds[0]["position"]), "у Старой купели", "with its phrase")
	var bare: Dictionary = book.export_state()
	bare.erase("places")
	var older = StoryBookScript.new()
	older.bind(manager)
	older.begin(bare)
	a.equal(older.places.ponds.size(), manager.world_state.water_sources.size(), "a save without places names them")
	Helpers.destroy_manager(manager)


func _test_labels_fade_with_zoom(a) -> void:
	var config: Dictionary = PlaceLabelsScript.DEFAULTS
	var pond_from := float(config["pond_zoom"])
	a.equal(PlaceLabelsScript.fade(config, pond_from * 0.5)[0], 0.0, "ponds hidden far out")
	a.equal(PlaceLabelsScript.fade(config, pond_from * 2.0)[0], 1.0, "ponds shown close in")
	var low := float(config["district_zoom_min"])
	var high := float(config["district_zoom_max"])
	a.equal(PlaceLabelsScript.fade(config, low * 0.5)[1], 0.0, "districts hidden at the widest view")
	a.equal(PlaceLabelsScript.fade(config, sqrt(low * high))[1], 1.0, "districts shown in between")
	a.equal(PlaceLabelsScript.fade(config, high * 1.5)[1], 0.0, "districts hidden close in")


func _test_minimap_names_the_place_under_the_cursor(a) -> void:
	var manager = Helpers.create_manager(853)
	var book = StoryBookScript.new()
	book.bind(manager)
	book.begin()
	var minimap = MiniMapScript.new()
	minimap.simulation_manager = manager
	minimap.size = Vector2(320.0, 200.0)
	a.equal(minimap._get_tooltip(Vector2(160.0, 100.0)), "", "no places, no tooltip")
	minimap.places = book.places
	var map_rect: Rect2 = minimap._get_map_rect()
	var tip: String = minimap._get_tooltip(map_rect.get_center())
	var expected: String = book.places.place_at(minimap._map_to_world_position(map_rect.get_center(), map_rect)) \
		.get("name", "")
	a.is_true(tip != "" and tip == expected, "the place under the cursor: %s" % tip)
	a.equal(minimap._get_tooltip(Vector2(1.0, 1.0)), "", "outside the map, none")
	minimap.free()
	Helpers.destroy_manager(manager)


## A kill counts for its hunter, awake or asleep; a death's age gives back the birth of an
## animal met grown.
func _test_kills_and_ages_from_events(a) -> void:
	var manager = Helpers.create_manager(861)
	var world = manager.world_state
	# Spawned before the book listens, so it is met grown rather than heard born.
	var grown = Helpers.spawn_herbivore(world, Vector2(140.0, 100.0), 0)
	grown.age = 80.0
	manager.simulation_time = 200.0
	var book = StoryBookScript.new()
	book.bind(manager)
	book.begin()
	a.equal(book.lineage.age_at(grown.id, 260.0), 140.0, "one met grown is aged from its age")
	var fox = Helpers.spawn_species(world, "predator", Vector2(110.0, 100.0), -1, Helpers.AgentBaseScript.SEX_MALE)
	book.meet_living()
	book.hear({"type": "AgentDied", "agent_id": 990777, "other_agent_id": fox.id, "species": "herbivore",
		"time_seconds": 210.0, "position": {"x": 100.0, "y": 100.0},
		"data": {"cause": "predation", "group_id": 0, "age": 300.0}})
	a.equal(book.lineage.kills(fox.id), 1, "the hunter's kill counted")
	a.equal(book.lineage.age_at(990777, 999.0), 300.0, "the age it died at, from the event")
	world.kill_agent(grown, "predation", fox.id)
	a.equal(book.lineage.kills(fox.id), 2, "a kill in the world counts the same")
	a.equal(book.lineage.age_at(grown.id, 999.0), 80.0, "dated at its death by the age it died at")
	book.hear({"type": "AgentDied", "agent_id": -1, "species": "herbivore", "time_seconds": 60.0,
		"position": {"x": 120.0, "y": 120.0}, "data": {"cause": "predation", "dormant": true, "record_id": 880001,
			"group_id": 0, "age": 120.0, "killer_record_id": 880900, "killer_sex": "female", "killer_species": "predator"}})
	a.equal(book.lineage.kills(880900), 1, "a sleeping kill counts for the hunter credited")
	var hunter: Dictionary = book.lineage.entry(880900)
	a.is_true(str(hunter.get("species", "")) == "predator" and str(hunter.get("sex", "")) == "female",
		"and the hunter is known by what the event says")
	a.equal(book.lineage.age_at(880001, 999.0), 120.0, "a sleeping death's age too")
	Helpers.destroy_manager(manager)


## A kill in a sleeping sector is credited to one of the hungry hunters there, by a hash of the
## victim - the same one every time - and the death reports its age.
func _test_sleeping_kill_credits_a_hunter(a) -> void:
	var manager = Helpers.create_manager(862)
	var world = manager.world_state
	var heard: Array = []
	manager.world_event.connect(func(event: Dictionary) -> void:
		if str(event.get("type", "")) == "AgentDied":
			heard.append(event))
	var hunters := [[501, "male"], [502, "female"], [503, "female"]]
	var bucket := [{"id": 701, "position": Vector2(60.0, 60.0), "age": 222.0, "group_id": 0},
		{"id": 702, "position": Vector2(200.0, 200.0), "age": 90.0, "group_id": 0}]
	for attempt in range(2):
		var aggregate := {"species_type": "herbivore", "group_id": 0, "center": Vector2(80.0, 80.0),
			"deaths_this_step": [{"cause": "predation", "count": 1, "near": Vector2(50.0, 50.0), "hunter": "predator",
				"hunters": hunters}]}
		world._take_dormant_victims(aggregate, bucket.duplicate(true))
	a.equal(heard.size(), 2, "two sleeping deaths heard")
	var data: Dictionary = heard[0].get("data", {}) if not heard.is_empty() else {}
	a.equal(int(data.get("record_id", -1)), 701, "the victim nearest the hunters")
	a.is_true([501, 502, 503].has(int(data.get("killer_record_id", -1))), "credited to one of the hungry hunters")
	a.equal(float(data.get("age", -1.0)), 222.0, "with its age")
	a.equal(str(data.get("killer_species", "")), "predator", "and the hunter's species")
	var second: Dictionary = heard[1].get("data", {}) if heard.size() > 1 else {}
	a.equal(int(second.get("killer_record_id", -2)), int(data.get("killer_record_id", -1)), "the same hunter each time")
	Helpers.destroy_manager(manager)


## The running counts of living descendants agree with walking the tree, through births, deaths
## and a save that kept no counts.
func _test_descendants_kept_running(a) -> void:
	var lineage = LineageScript.new()
	var living: Array = []
	for founder in range(1, 9):
		lineage.note_animal(founder, "herbivore", "female" if founder % 2 == 0 else "male")
		living.append(founder)
	var next_id := 100
	for step in range(240):
		var h: int = AnimalNamesScript.mix(step * 7919 + 13)
		if h % 5 == 0 and living.size() > 4:
			var victim: int = living[h % living.size()]
			living.erase(victim)
			lineage.note_death(victim, float(step), "old_age", -1, Vector2.ZERO)
			continue
		var mother: int = living[h % living.size()]
		var father: int = living[AnimalNamesScript.mix(h) % living.size()]
		var sex := "female" if h % 3 == 0 else "male"
		lineage.note_birth(next_id, "herbivore", sex, float(step), 0, [])
		lineage.note_birth(next_id, "herbivore", sex, float(step), 0, [mother, father])
		living.append(next_id)
		next_id += 1
	var wrong: Array = []
	for agent_id in lineage.animals().keys():
		if lineage.descendants_alive(agent_id) != lineage.count_descendants_alive(agent_id):
			wrong.append(agent_id)
	a.is_true(wrong.is_empty(), "running counts match the tree: %s" % str(wrong.slice(0, 5)))
	var saved: Dictionary = lineage.export_state()
	saved.erase("alive_descendants")
	saved.erase("all_descendants")
	var loaded = LineageScript.new()
	loaded.import_state(saved)
	var drift := 0
	for agent_id in lineage.animals().keys():
		if loaded.descendants_alive(agent_id) != lineage.descendants_alive(agent_id) \
				or loaded.descendants_ever(agent_id) != lineage.descendants_ever(agent_id):
			drift += 1
	a.equal(drift, 0, "a save without counts rebuilds them")


func _test_age_text(a) -> void:
	a.equal(HudText.age_text(30.0), "меньше сезона", "under a season")
	a.equal(HudText.age_text(130.0), "1 сезон", "a season")
	a.equal(HudText.age_text(360.0), "3 сезона", "three seasons")
	a.equal(HudText.age_text(480.0), "1 год", "a year")
	a.equal(HudText.age_text(720.0), "1 год и 2 сезона", "a year and two seasons")
	a.equal(HudText.age_text(1200.0), "2 года и 2 сезона", "two years and a half")
	a.equal(HudText.age_text(2400.0), "5 лет", "five years")
	a.equal(HudText.age_text(250.0, [100.0, 2]), "1 год", "another calendar")


func _test_records_rank(a) -> void:
	var manager = Helpers.create_manager(863)
	var book = StoryBookScript.new()
	book.bind(manager)
	book.begin()
	var lineage = book.lineage
	lineage.note_birth(1, "herbivore", "female", 0.0, 0, [])
	lineage.note_birth(2, "herbivore", "male", 100.0, 0, [])
	lineage.note_animal(3, "predator", "male", -1, 50.0, 100.0)
	lineage.note_birth(4, "predator", "female", 10.0, -1, [])
	lineage.note_birth(10, "herbivore", "female", 200.0, 0, [1, 2])
	lineage.note_birth(11, "herbivore", "male", 210.0, 0, [1, 2])
	lineage.note_birth(12, "herbivore", "male", 300.0, 0, [10, 2])
	lineage.note_death(4, 400.0, "starvation", -1, Vector2.ZERO)
	lineage.note_death(11, 410.0, "predation", 3, Vector2.ZERO)
	lineage.note_death(12, 420.0, "predation", 3, Vector2.ZERO)
	var rows: Dictionary = StoryRecordsScript.all(book, 500.0)
	a.equal(_ids(rows["oldest"]), [1, 3, 2], "the oldest alive, oldest first")
	a.equal(_ids(rows["longest"]), [4, 11, 12], "the longest lives among the dead")
	a.equal(_ids(rows["family"]), [1, 2], "the largest living families, ties to the lower id")
	a.equal(_ids(rows["hunters"]), [3], "the hunters")
	a.equal(int(rows["hunters"][0]["value"]), 2, "with their kills")
	a.equal(StoryRecordsScript.held_by(book, 1, 500.0), ["oldest", "family"], "the records an animal holds")
	Helpers.destroy_manager(manager)


static func _ids(rows: Array) -> Array:
	var ids: Array = []
	for row in rows:
		ids.append(int(row["id"]))
	return ids


## A point on the map as far as can be found from every pond's reach.
static func _far_from_ponds(places, bounds: Rect2) -> Vector2:
	var best := bounds.get_center()
	var best_gap := -INF
	for gx in range(1, 12):
		for gy in range(1, 8):
			var point := bounds.position + bounds.size * Vector2(gx / 12.0, gy / 8.0)
			var gap := INF
			for pond in places.ponds:
				gap = minf(gap, point.distance_to(pond["position"]) - float(pond["radius"]) * PlaceNamesScript.POND_REACH)
			if gap > best_gap:
				best_gap = gap
				best = point
	return best
