extends RefCounted

## The chronicle: names for the land, what the family tree counts, epitaphs, the chronicle
## window and the card's «Почему?».

const Helpers := preload("res://scripts/tests/test_helpers.gd")
const PlaceNamesScript := preload("res://scripts/story/place_names.gd")
const PlaceLabelsScript := preload("res://scripts/ui/place_labels.gd")
const StoryBookScript := preload("res://scripts/story/story_book.gd")
const MiniMapScript := preload("res://scripts/ui/minimap.gd")


func run(a) -> void:
	_test_place_names_decline(a)
	_test_every_adjective_has_its_ending(a)
	_test_places_of_a_real_map(a)
	_test_feed_says_where(a)
	_test_places_survive_a_save(a)
	_test_labels_fade_with_zoom(a)
	_test_minimap_names_the_place_under_the_cursor(a)


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
