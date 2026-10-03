extends RefCounted

## The season ledger (`SeasonLedger`): which season a moment falls in, a season closing on the
## tick it ends with its numbers - a change in each species exactly its births less its deaths -
## the best hunter awake and asleep, the ponds that dried, a season seen only in part, the
## ledger kept with the story, and nothing at all without a clock. Then what is said of a
## season (`SeasonReport`), the card that says it (`SeasonCard`) and the chronicle's «Сезоны».

const Helpers := preload("res://scripts/tests/test_helpers.gd")
const ClimateScript := preload("res://scripts/world/climate.gd")
const ConfigLoaderScript := preload("res://scripts/core/config_loader.gd")
const StoryBookScript := preload("res://scripts/story/story_book.gd")
const SeasonLedgerScript := preload("res://scripts/story/season_ledger.gd")
const SeasonReportScript := preload("res://scripts/story/season_report.gd")
const SeasonCardScript := preload("res://scripts/ui/season_card.gd")
const EpitaphCardScript := preload("res://scripts/ui/epitaph_card.gd")
const StoryFeedScript := preload("res://scripts/ui/story_feed.gd")
const StoryLogScript := preload("res://scripts/story/story_log.gd")
const ChronicleWindowScript := preload("res://scripts/ui/chronicle_window.gd")
const HudTextScript := preload("res://scripts/ui/hud_text.gd")

## Seconds a season lasts in these fixtures.
const SEASON := 6.0


func run(a) -> void:
	_test_ordinals(a)
	_test_seasons_close_with_their_numbers(a)
	_test_best_hunter(a)
	_test_dried_ponds_by_name(a)
	_test_partial_season(a)
	_test_kept_with_the_story(a)
	_test_no_clock_no_seasons(a)
	_test_drought_only_where_it_bites(a)
	_test_preview_leaves_it_open(a)
	_test_report_words(a)
	_test_ponds_named(a)
	_test_card(a)
	_test_feed_keeps_below_a_card(a)
	_test_seasons_tab(a)


## The game is paused while this says so: the card's countdown reads `paused`.
class ManagerStub:
	extends RefCounted

	var paused := false


func _climate(start_season := 0) -> Dictionary:
	var climate: Dictionary = ConfigLoaderScript.load_config_bundle()["world"]["climate"].duplicate(true)
	climate["enabled"] = true
	climate["day_length_seconds"] = SEASON
	climate["start_season_index"] = start_season
	return climate


func _world(seed: int):
	var bundle := Helpers.build_test_bundle(seed)
	bundle["world"]["climate"] = _climate()
	return Helpers.create_manager_with(bundle, seed)


func _book(manager):
	var book = StoryBookScript.new()
	book.bind(manager)
	book.begin()
	return book


func _test_ordinals(a) -> void:
	var climate: Dictionary = ConfigLoaderScript.load_config_bundle()["world"]["climate"].duplicate(true)
	climate["enabled"] = true
	a.equal(ClimateScript.season_ordinal(climate, 0.0), 0, "the world begins in its first season")
	a.equal(ClimateScript.season_ordinal(climate, 119.9), 0, "which lasts 120 s")
	a.equal(ClimateScript.season_ordinal(climate, 120.0), 1, "then the next")
	a.equal(ClimateScript.season_ordinal(climate, 480.0), 4, "and a year is four")
	climate["start_season_index"] = 2
	a.equal(ClimateScript.season_ordinal(climate, 0.0), 2, "a world started in autumn counts from autumn")
	climate["enabled"] = false
	a.equal(ClimateScript.season_ordinal(climate, 50.0), -1, "no clock, no seasons")


func _test_seasons_close_with_their_numbers(a) -> void:
	var manager = _world(9401)
	var world = manager.world_state
	for index in range(12):
		var deer = world.spawn_agent("herbivore", Vector2(40.0 + float(index % 6) * 30.0, 80.0 + floorf(index / 6.0) * 40.0),
			0, "female" if index % 2 == 0 else "male", {"reason": "initial"})
		deer.age = 120.0
		deer.reproduction_cooldown = 0.0
		deer.energy = 90.0
		# Three already starving, who die on the first tick.
		deer.hunger = deer.need_max if index < 3 else 0.0
		deer.thirst = 0.0
	Helpers._refresh_spatial_queries(world)
	var book = _book(manager)
	var closed: Array = []
	book.season_closed.connect(func(summary: Dictionary) -> void: closed.append(summary))
	Helpers.run_ticks(manager, int(SEASON * 2.0 / manager.tick_duration) + 2)
	a.equal(closed.size(), 2, "two seasons closed in two seasons' time")
	if closed.is_empty():
		return
	var first: Dictionary = closed[0]
	a.equal(str(first["label"]), "Весна", "the first was spring")
	a.equal(int(first["year"]), 0, "of the first year")
	a.is_true(not bool(first["partial"]), "seen whole")
	var deer: Dictionary = first["species"]["herbivore"]
	a.equal(int(deer["start"]), 12, "it began with the founders")
	a.equal(int(deer["end"]) - int(deer["start"]), int(deer["births"]) - int(deer["died"]),
		"and changed by exactly its births less its deaths (%d born, %d died)" % [int(deer["births"]), int(deer["died"])])
	a.is_true(int(deer["deaths"].get("starvation", 0)) >= 3, "the starving three died of hunger")
	var second: Dictionary = closed[1]
	a.equal(int(second["species"]["herbivore"]["start"]), int(deer["end"]), "the next season began where it ended")
	a.equal(str(second["label"]), "Лето", "and was summer")
	a.equal(book.seasons.closed.size(), 2, "the ledger keeps them")
	Helpers.destroy_manager(manager)


func _died(time: float, species: String, cause: String, killer := -1, asleep_killer := -1) -> Dictionary:
	var data := {"cause": cause}
	if asleep_killer >= 0:
		data["killer_record_id"] = asleep_killer
	return {"type": "AgentDied", "time_seconds": time, "species": species, "agent_id": 900 + int(time * 10.0),
		"other_agent_id": killer, "position": {"x": 0.0, "y": 0.0}, "data": data}


func _test_best_hunter(a) -> void:
	var manager = _world(9402)
	var book = _book(manager)
	for event in [_died(1.0, "herbivore", "predation", 7), _died(1.5, "herbivore", "predation", 7),
			_died(2.0, "herbivore", "predation", -1, 9), _died(2.5, "scavenger", "predation", -1, 9),
			_died(3.0, "herbivore", "starvation")]:
		book.seasons.hear(event)
	var tie: Dictionary = book.seasons.close(3.5, manager, book)
	a.equal(int(tie["hunter"].get("id", -1)), 7, "a tie goes to the lower id")
	a.equal(int(tie["hunter"].get("kills", 0)), 2, "with its kills")
	a.equal(int(tie["species"]["herbivore"]["deaths"].get("predation", 0)), 3, "kills awake and asleep are counted")
	book.seasons._open(1, 6.0, {}, false)
	for event in [_died(7.0, "herbivore", "predation", 7), _died(7.5, "herbivore", "predation", -1, 9),
			_died(8.0, "herbivore", "predation", -1, 9)]:
		book.seasons.hear(event)
	var asleep: Dictionary = book.seasons.close(9.0, manager, book)
	a.equal(int(asleep["hunter"].get("id", -1)), 9, "a hunter credited asleep can be the season's best")
	Helpers.destroy_manager(manager)


func _test_dried_ponds_by_name(a) -> void:
	var manager = _world(9403)
	var book = _book(manager)
	for index in [0, 1, 0]:
		book.seasons.hear({"type": "PondDried", "time_seconds": 2.0, "species": "", "agent_id": -1,
			"position": {"x": 0.0, "y": 0.0}, "data": {"index": index}})
	book.seasons.hear({"type": "PondRefilled", "time_seconds": 3.0, "species": "", "agent_id": -1,
		"position": {"x": 0.0, "y": 0.0}, "data": {"index": 1}})
	var summary: Dictionary = book.seasons.close(4.0, manager, book)
	a.equal(summary["dried"], [book.places.ponds[0]["name"], book.places.ponds[1]["name"]],
		"the ponds that dried, by name, once each")
	a.equal(summary["refilled"], [book.places.ponds[1]["name"]], "and the one that filled again")
	Helpers.destroy_manager(manager)


func _test_partial_season(a) -> void:
	var manager = _world(9404)
	Helpers.run_ticks(manager, int(SEASON * 0.5 / manager.tick_duration))
	var book = _book(manager)
	a.is_true(bool(book.seasons.open.get("partial", false)), "a season met half-way is not seen whole")
	var closed: Array = []
	book.season_closed.connect(func(summary: Dictionary) -> void: closed.append(summary))
	Helpers.run_ticks(manager, int(SEASON / manager.tick_duration) + 2)
	a.is_true(not closed.is_empty() and bool(closed[0]["partial"]), "and says so when it closes")
	a.is_true(closed.size() < 2 or not bool(closed[1]["partial"]), "the next one is whole")
	Helpers.destroy_manager(manager)


func _test_kept_with_the_story(a) -> void:
	var manager = _world(9405)
	var book = _book(manager)
	book.seasons.hear(_died(1.0, "herbivore", "thirst"))
	# Into the second season, which the book closes the first for on the way.
	Helpers.run_ticks(manager, int(SEASON / manager.tick_duration) + 2)
	book.seasons.hear(_died(7.0, "herbivore", "old_age"))
	var saved: Dictionary = book.export_state()
	a.equal(int(saved["version"]), StoryBookScript.STATE_VERSION, "the story's version stays as it was")
	var loaded = StoryBookScript.new()
	loaded.bind(manager)
	loaded.begin(saved)
	a.equal(loaded.seasons.closed.size(), 1, "closed seasons come back")
	a.equal(int(loaded.seasons.open.get("ordinal", -1)), 1, "and the open one")
	a.equal(int(loaded.seasons.open["deaths"]["herbivore"].get("old_age", 0)), 1, "with what it counted so far")
	saved.erase("seasons")
	var older = StoryBookScript.new()
	older.bind(manager)
	older.begin(saved)
	a.is_true(older.seasons.closed.is_empty(), "a story saved before seasons starts with none")
	Helpers.destroy_manager(manager)


func _test_no_clock_no_seasons(a) -> void:
	var manager = Helpers.create_manager(9406)
	var book = _book(manager)
	a.is_true(book.seasons.open.is_empty(), "no clock, no season open")
	var closed: Array = []
	book.season_closed.connect(func(summary: Dictionary) -> void: closed.append(summary))
	Helpers.run_ticks(manager, 200)
	a.is_true(closed.is_empty(), "and none closed")
	Helpers.destroy_manager(manager)


## A drought year's flag on the seasons it makes harsher - summer and autumn lose water - and not
## on its spring or winter.
func _test_drought_only_where_it_bites(a) -> void:
	var manager = _world(9407)
	var book = _book(manager)
	var water = manager.world_state.water
	water.enabled = true
	var year := -1
	for candidate in range(1, 60):
		if water.is_drought_year(candidate):
			year = candidate
			break
	a.is_true(year > 0, "a drought year in sixty")
	var flags := []
	for index in range(4):
		book.seasons._open(year * 4 + index, 0.0, {}, false)
		flags.append(bool(book.seasons.close(1.0, manager, book)["drought"]))
	a.equal(flags, [false, true, true, false], "summer and autumn of a drought year, not spring or winter")
	water.enabled = false
	book.seasons._open(year * 4 + 1, 0.0, {}, false)
	a.is_true(not bool(book.seasons.close(1.0, manager, book)["drought"]), "and none with the levels off")
	Helpers.destroy_manager(manager)


func _test_preview_leaves_it_open(a) -> void:
	var manager = _world(9408)
	var book = _book(manager)
	book.seasons.hear(_died(1.0, "herbivore", "thirst"))
	var so_far: Dictionary = book.seasons.preview(1.5, manager, book)
	a.equal(int(so_far["species"]["herbivore"]["deaths"].get("thirst", 0)), 1, "the season so far")
	a.is_true(book.seasons.closed.is_empty() and not book.seasons.open.is_empty(), "left open, nothing closed")
	Helpers.destroy_manager(manager)


func _summer() -> Dictionary:
	return {"ordinal": 5, "year": 1, "season_id": "summer", "label": "Лето", "partial": false, "drought": true,
		"species": {
			"scavenger": {"start": 106, "end": 118, "births": 40, "deaths": {"predation": 20, "old_age": 8}, "died": 28},
			"herbivore": {"start": 240, "end": 278, "births": 74,
				"deaths": {"predation": 11, "starvation": 5, "thirst": 4, "old_age": 16}, "died": 36},
			"predator": {"start": 47, "end": 41, "births": 12, "deaths": {"starvation": 4, "old_age": 14}, "died": 18},
		},
		"hunter": {"id": 7, "name": "Рыжик", "species": "predator", "sex": "male", "kills": 5},
		"dried": ["Тихая заводь", "Кривой брод", "Лисий водопой", "Ольховый плёс", "Сухой омут"],
		"refilled": [], "genders": {"Тихая заводь": "f", "Кривой брод": "m"}}


## `text` with the report's no-break spaces as plain ones, for comparing; arrays line by line.
func _plain(text):
	if text is Array:
		var lines: Array = []
		for line in text:
			lines.append(_plain(line))
		return lines
	return str(text).replace(SeasonReportScript.NBSP, " ")


func _test_report_words(a) -> void:
	var summer := _summer()
	a.equal(SeasonReportScript.title(summer), "Итоги лета · год 2 · засуха", "the card's title")
	a.equal(SeasonReportScript.title(summer, "row"), "Лето · год 2 · засуха", "a row's")
	a.equal(SeasonReportScript.title(summer, "running"), "Лето · год 2 · засуха · идёт", "the season going")
	a.equal(_plain(SeasonReportScript.lines(summer)), [
		"Олени 278 (+38) · лисы 41 (−6) · тетерева 118 (+12)",
		"Родились: 74 оленёнка, 12 лисят, 40 птенцов",
		"Погибли: хищники — 31, голод — 9, жажда — 4, старость — 38",
		"Лучший охотник: лис Рыжик — 5 добыч",
		"Пересохли Тихая заводь, Кривой брод и ещё 3 водоёма",
	], "its lines")
	var latin := RegEx.create_from_string("[A-Za-z]")
	a.is_true(latin.search(SeasonReportScript.title(summer) + SeasonReportScript.text(summer)) == null, "all in Russian")
	var winter := {"year": 0, "season_id": "winter", "label": "Зима", "partial": true, "drought": false,
		"species": {"herbivore": {"start": 40, "end": 40, "births": 0, "deaths": {}, "died": 0},
			"predator": {"start": 0, "end": 0, "births": 0, "deaths": {}, "died": 0}},
		"hunter": {"id": 3, "name": "Огнёвка", "species": "predator", "sex": "female", "kills": 3},
		"dried": [], "refilled": []}
	a.equal(SeasonReportScript.title(winter), "Итоги зимы · год 1 · не с начала", "a season met half-way")
	a.equal(_plain(SeasonReportScript.lines(winter)), ["Олени 40 (±0)", "Лучшая охотница: лиса Огнёвка — 3 добычи"],
		"quiet lines left out, a species the map lacks too, and a huntress")
	a.equal([HudTextScript.signed(38), HudTextScript.signed(-6), HudTextScript.signed(0)], ["+38", "−6", "±0"],
		"signs, the minus a real one")
	a.equal([HudTextScript.season_genitive("spring"), HudTextScript.season_genitive("autumn"),
		HudTextScript.season_genitive("monsoon", "Муссон")], ["весны", "осени", "муссон"], "seasons after «итоги»")


func _test_ponds_named(a) -> void:
	var genders := {"Тихая заводь": "f", "Кривой брод": "m", "Лесное озерцо": "n"}
	a.equal(_plain(SeasonReportScript.ponds_line(["Тихая заводь"], genders, true)), "Пересохла Тихая заводь", "one, in its gender")
	a.equal(_plain(SeasonReportScript.ponds_line(["Кривой брод"], genders, true)), "Пересох Кривой брод", "masculine")
	a.equal(_plain(SeasonReportScript.ponds_line(["Лесное озерцо"], genders, true)), "Пересохло Лесное озерцо", "neuter")
	a.equal(_plain(SeasonReportScript.ponds_line(["Тихая заводь", "Кривой брод"], genders, true)),
		"Пересохли Тихая заводь и Кривой брод", "two")
	a.equal(_plain(SeasonReportScript.ponds_line(["А", "Б", "В"], {}, true)), "Пересохли А, Б и В", "three named in full")
	var many: Array = []
	for index in range(31):
		many.append("Пруд %d" % index)
	a.equal(_plain(SeasonReportScript.ponds_line(many, {}, false)), "Снова с водой: Пруд 0, Пруд 1 и ещё 29 водоёмов",
		"a spring's worth, cut short")
	a.equal(_plain(SeasonReportScript.ponds_line([], {}, true)), "", "none, no line")


func _test_card(a) -> void:
	var card = SeasonCardScript.new()
	var manager := ManagerStub.new()
	card.simulation_manager = manager
	card.show_season(_summer())
	a.is_true(card.visible and card.text().begins_with("Итоги лета · год 2"), "on screen with its title")
	var autumn := _summer()
	autumn["season_id"] = "autumn"
	autumn["label"] = "Осень"
	card.show_season(autumn)
	a.is_true(card.text().begins_with("Итоги осени"), "a new season replaces the old")
	card.set_allowed(false)
	a.is_true(not card.visible, "hidden by the start menu or the developer panels")
	card.set_allowed(true)
	a.is_true(card.visible, "and back")
	manager.paused = true
	card._process(SeasonCardScript.SHOW_SECONDS + 1.0)
	a.is_true(card.visible and not card.current().is_empty(), "the countdown waits while the game is paused")
	manager.paused = false
	card._process(SeasonCardScript.SHOW_SECONDS - 1.0)
	a.is_true(card.visible, "still there before its time")
	card._process(1.1)
	a.is_true(not card.visible and card.current().is_empty(), "gone after %d s" % int(SeasonCardScript.SHOW_SECONDS))
	card.set_allowed(true)
	a.is_true(not card.visible, "and not brought back with nothing to show")
	var asked := []
	card.chronicle_requested.connect(func() -> void: asked.append(true))
	card.show_season(_summer())
	card._on_chronicle()
	a.is_true(asked.size() == 1 and not card.visible, "«Летопись» asks for the chronicle and puts the card away")
	card.free()
	var epitaph = EpitaphCardScript.new()
	epitaph.show_epitaph(1, "Первая.", Vector2.ZERO)
	epitaph.set_allowed(false)
	epitaph._process(EpitaphCardScript.SHOW_SECONDS + 1.0)
	a.is_true(epitaph.current().get("id", -1) == 1 and not epitaph.visible,
		"an epitaph held back behind the season card keeps its time")
	epitaph.set_allowed(true)
	a.is_true(epitaph.visible, "and shows when the card is gone")
	epitaph.free()


## The feed under a card in the right column shows fewer rows, the newest kept, and all of them
## once the card has gone.
func _test_feed_keeps_below_a_card(a) -> void:
	var feed_log = StoryLogScript.new()
	for index in range(StoryFeedScript.MAX_ROWS):
		feed_log.lines.append({"time": float(index), "text": "Строка %d о том, что случилось у водопоя на краю карты" % index,
			"position": Vector2.INF, "focus_id": -1, "pinned": false, "kind": "summary", "key": "", "count": 1})
	var feed = StoryFeedScript.new()
	# In the tree: outside it a control's minimum size is never recomputed.
	Engine.get_main_loop().root.add_child(feed)
	feed.bind(feed_log, null)
	var full: float = feed.get_combined_minimum_size().y
	feed.size = Vector2(360.0, full)
	feed.fit_below(0.0)
	a.equal(feed.shown_rows(), StoryFeedScript.MAX_ROWS, "every row with nothing over it")
	var room := full * 0.5
	feed.fit_below(full - room)
	var shown: int = feed.shown_rows()
	a.is_true(shown > 0 and shown < StoryFeedScript.MAX_ROWS, "fewer under a card (%d)" % shown)
	a.is_true(feed._rows.get_child(0).visible, "the newest kept")
	a.is_true(feed.get_combined_minimum_size().y <= room + 0.5, "and the feed clear of the card (%.1f of %.1f)"
		% [feed.get_combined_minimum_size().y, room])
	feed.fit_below(0.0)
	a.equal(feed.shown_rows(), StoryFeedScript.MAX_ROWS, "all back once it has gone")
	feed.get_parent().remove_child(feed)
	feed.free()


func _tab_texts(window) -> Array:
	var texts: Array = []
	for child in window._seasons_box.get_children():
		if child is Label:
			texts.append(child.text)
	return texts


func _test_seasons_tab(a) -> void:
	var manager = _world(9409)
	var book = _book(manager)
	var window = ChronicleWindowScript.new()
	window.bind(book, manager)
	window.open(-1, "seasons")
	a.is_true(window._seasons_scroll.visible and not window._tree.visible, "the seasons tab")
	var texts := _tab_texts(window)
	a.equal(str(texts[0]), "Весна · год 1 · идёт", "the season going on top")
	a.equal(str(texts[2]), "Ни один сезон ещё не закончился.", "none closed yet")
	var rows: Array = window._seasons_box.get_children()
	Helpers.run_ticks(manager, int(SEASON * 0.5 / manager.tick_duration))
	window.refresh()
	a.equal(window._seasons_box.get_children(), rows, "rows kept while no season closes")
	Helpers.run_ticks(manager, int(SEASON / manager.tick_duration))
	window.refresh()
	a.is_true(window._seasons_box.get_children() != rows, "built again when one does")
	texts = _tab_texts(window)
	a.equal(str(texts[0]), "Лето · год 1 · идёт", "summer going")
	a.equal(str(texts[2]), "Весна · год 1", "spring under it, closed")
	window.free()
	Helpers.destroy_manager(manager)
	var still = Helpers.create_manager(9410)
	var still_book = _book(still)
	var plain = ChronicleWindowScript.new()
	plain.bind(still_book, still)
	plain.open(-1, "seasons")
	a.equal(_tab_texts(plain), ["В этом мире нет смены сезонов."], "a world without a clock says so")
	plain.free()
	Helpers.destroy_manager(still)
