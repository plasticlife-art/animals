extends RefCounted

## The reserve's viewers (`ReserveSession`, `ChatCommands`, `ViewerBook`, `VoteRound`,
## `ViewerLink`): chat lines read as commands, names cleaned; a ward taken and told, a second
## asked too soon ignored; a vote won and carried out; a fund's perk; a steward's power on the
## focus herd; «!моё» asking the camera for the ward; the session back from a save; lines of
## JSON read off the local port; the director's shots (`ReserveDirector`); the overlay's text; and
## the reserve's saves, in slots of its own; a species about to be lost rescued; the viewers long
## unseen forgotten; no cull of the last foxes, no newcomers to a crowded species, the reserve's
## own power settings and a shorter story; a ward's death and young told, the banner's order, the
## tables and the year's summary, the wards' tags; an autosave written in the background.

const Helpers := preload("res://scripts/tests/test_helpers.gd")
const ConfigLoaderScript := preload("res://scripts/core/config_loader.gd")
const ReserveCommandTestsScript := preload("res://scripts/tests/reserve_command_tests.gd")
const ReserveSessionScript := preload("res://scripts/reserve/reserve_session.gd")
const ViewerLinkScript := preload("res://scripts/reserve/viewer_link.gd")
const ReserveDirectorScript := preload("res://scripts/ui/reserve_director.gd")
const ReserveOverlayScript := preload("res://scripts/ui/reserve_overlay.gd")
const StoryBookScript := preload("res://scripts/story/story_book.gd")
const SelectionCardScript := preload("res://scripts/ui/selection_card.gd")
const ReserveBannerScript := preload("res://scripts/ui/reserve_banner.gd")
const ReserveRecordsScript := preload("res://scripts/ui/reserve_records.gd")
const WardTagsScript := preload("res://scripts/ui/ward_tags.gd")
const AT := Vector2(1500.0, 1500.0)


func run(a) -> void:
	_test_reading_the_chat(a)
	_test_a_ward(a)
	_test_a_vote_and_a_fund(a)
	_test_a_steward_and_mine(a)
	_test_the_local_port(a)
	_test_the_director(a)
	_test_the_overlay_text(a)
	_test_its_own_slots(a)
	_test_a_rescue(a)
	_test_counting_with_a_worker(a)
	_test_forgetting_viewers(a)
	_test_floors_and_ceilings(a)
	_test_ward_news(a)
	_test_the_banner_and_tables(a)
	_test_saving_in_the_background(a)


## Stands in for the game's camera: where it was sent.
class FakeCamera:
	var moved: Array = []

	func move_to_world_position(position: Vector2, _clear_focus: bool = true) -> void:
		moved.append(position)


static func _config() -> Dictionary:
	return ConfigLoaderScript._load_json("res://data/config/reserve.json")


static func _message(user_id: String, user: String, text: String) -> Dictionary:
	return {"platform": "twitch", "user_id": user_id, "user": user, "text": text}


## A reserve world with a herd at `AT`, its session and the lines it told.
static func _reserve(seed: int, config: Dictionary) -> Array:
	var manager = Helpers.create_manager_with(ReserveCommandTestsScript._bundle(seed), seed)
	manager.set_lod_enabled(false)
	Helpers.spawn_herd(manager.world_state, AT, 6, 0)
	var session = ReserveSessionScript.new()
	session.configure(manager, config)
	var lines: Array = []
	session.told.connect(func(line: Dictionary) -> void: lines.append(str(line["text"])))
	return [manager, session, lines]


func _test_reading_the_chat(a) -> void:
	var config := _config()
	var cases := {"!имя Ветка": ["adopt", "Ветка"], "!ИМЯ   Звёздочка ": ["adopt", "Звёздочка"], "!2": ["vote", "2"],
		"!водопой": ["dig_pond", ""], "!олени": ["team", "herbivore"], "!мое": ["mine", ""], "!моё": ["mine", ""]}
	var right := true
	for text in cases.keys():
		var parsed: Dictionary = ChatCommands.parse(text, config)
		right = right and str(parsed.get("kind", "")) == cases[text][0] and str(parsed.get("arg", "")) == cases[text][1]
	a.is_true(right, "commands read, whatever the case and «ё»")
	a.is_true(ChatCommands.parse("привет всем", config).is_empty() and ChatCommands.parse("!неизвестно", config).is_empty(),
		"talk and unknown words are no commands")
	a.equal([ChatCommands.clean_name("ветка", config), ChatCommands.clean_name("Ве#тка123!", config),
		ChatCommands.clean_name("Абвгдеёжзийклмнопрст", config).length(), ChatCommands.clean_name("Сукин", config),
		ChatCommands.clean_name("123", config)], ["Ветка", "Ветка", 16, "", ""],
		"names cleaned: letters only, capital, cut to length, none of the blocked, nothing from digits")
	a.equal([ViewerBook.clean_shown("  Вася_99 "), ViewerBook.clean_shown("[b]Злой[/b]\n"), ViewerBook.clean_shown("x".repeat(40)).length()],
		["Вася_99", "bЗлой/b", 32], "viewers' names kept clear of markup and cut")


func _test_a_ward(a) -> void:
	var made := _reserve(9931, _config())
	var manager = made[0]
	var session = made[1]
	var book = StoryBookScript.new()
	book.bind(manager)
	book.begin({})
	session.hear(_message("1", "Вася", "!имя Ветка"))
	manager.step_once()
	var ward := -1
	for id in manager.world_state.adoptions.keys():
		if str(manager.world_state.adoptions[id]["viewer"]) == "twitch:1":
			ward = int(id)
	a.is_true(ward != -1 and str(manager.world_state.adoptions[ward]["name"]) == "Ветка", "a viewer's ward, named")
	a.is_true(made[2].size() == 1 and str(made[2][0]).contains("опекун"), "and told (%s)" % str(made[2]))
	var agent = manager.world_state.get_agent(ward)
	a.is_true(book.name_of(agent) == "Ветка" and SelectionCardScript.family_line(book, agent).begins_with("Опекун: Вася"),
		"its card names it and its guardian")
	var feed: Array = book.feed.lines.map(func(line) -> String: return str(line.text))
	a.is_true(feed.has("Вася берёт под опеку: олень Ветка"), "the feed tells it by the viewer's name (%s)" % str(feed))
	session.hear(_message("1", "Вася", "!имя Ещё"))
	a.equal(manager.pending_commands().size(), 0, "a second asked too soon is ignored")
	Helpers.destroy_manager(manager)


func _test_a_vote_and_a_fund(a) -> void:
	var config := _config()
	config["vote"]["every_seconds"] = 1.0
	config["vote"]["open_seconds"] = 1.0
	config["teams"]["every_seconds"] = 3.0
	var made := _reserve(9932, config)
	var manager = made[0]
	var session = made[1]
	var opened := false
	for _tick in range(int(manager.tick_rate * 1.2)):
		manager.step_once()
		session.tick()
		opened = opened or not session.vote.current.is_empty()
	a.is_true(opened and session.vote.current["choices"].size() == 3, "a vote opens on three events")
	session.hear(_message("1", "Вася", "!2"))
	session.hear(_message("2", "Маша", "!2"))
	session.hear(_message("3", "Петя", "!1"))
	session.hear(_message("2", "Маша", "!олени"))
	session.hear(_message("3", "Петя", "!олени"))
	var second_label := str(session.vote.current["choices"][1]["label"])
	for _tick in range(int(manager.tick_rate * 3.5)):
		manager.step_once()
		session.tick()
	var told := "\n".join(made[2])
	a.is_true(told.contains("Голосование: %s" % second_label), "the most votes win and are carried out (%s)" % told)
	a.is_true(told.contains("Фонд оленей"), "the fund with most active members has its perk")
	Helpers.destroy_manager(manager)


func _test_a_steward_and_mine(a) -> void:
	var made := _reserve(9933, _config())
	var manager = made[0]
	var session = made[1]
	var asked: Array = []
	session.focus_requested.connect(func(id: int) -> void: asked.append(id))
	session.hear(_message("5", "Оля", "!водопой"))
	var orders: Array = manager.pending_commands()
	a.is_true(orders.size() == 1 and str(orders[0]["type"]) == "dig_pond"
		and Vector2(orders[0]["params"]["position"]).distance_to(AT) < 1500.0, "a steward's power goes by the focus herd")
	session.hear(_message("5", "Оля", "!имя Тучка"))
	manager.step_once()
	session.hear(_message("5", "Оля", "!моё"))
	a.is_true(asked.size() == 1 and manager.world_state.adoptions.has(asked[0]), "«!моё» asks the camera for the ward")
	var saved: Dictionary = session.export_state()
	var again = ReserveSessionScript.new()
	again.import_state(saved)
	a.equal(again.export_state(), saved, "the session comes back from a save")
	Helpers.destroy_manager(manager)


func _test_the_local_port(a) -> void:
	var config := _config()
	config["link"]["port"] = 47899
	var link = ViewerLinkScript.new()
	a.is_true(link.listen(config), "listens on the local port")
	var client := StreamPeerTCP.new()
	client.connect_to_host("127.0.0.1", 47899)
	var got: Array = []
	var sent := false
	for _step in range(200):
		client.poll()
		if not sent and client.get_status() == StreamPeerTCP.STATUS_CONNECTED:
			client.put_data(("{\"platform\":\"youtube\",\"user_id\":\"9\",\"user\":\"Аня\",\"text\":\"!имя Луна\"}\nне json\n").to_utf8_buffer())
			sent = true
		got.append_array(link.poll())
		if got.size() >= 1:
			break
		OS.delay_msec(5)
	a.is_true(got.size() == 1 and str(got[0]["text"]) == "!имя Луна", "a line of JSON read off it, the rest dropped (%s)" % str(got))
	client.disconnect_from_host()
	link.stop()


func _test_the_director(a) -> void:
	var made := _reserve(9934, _config())
	var manager = made[0]
	var session = made[1]
	var director = ReserveDirectorScript.new()
	director.configure(manager, FakeCamera.new(), session, _config())
	director.update()
	var herd: Dictionary = session.focus_herd()
	var first = manager.get_selected_agent()
	a.is_true(first != null and int(first.group_id) == int(herd["group_id"]) and manager.focus_mode == "flock",
		"with nothing happening it follows the focus herd")
	var deer: Array = manager.world_state.get_living_agents().filter(func(agent): return agent.species_type == "herbivore")
	var other = deer[deer.size() - 1] if deer[deer.size() - 1].id != first.id else deer[0]
	manager.world_event.emit({"type": "PredationSuccess", "agent_id": other.id, "species": "herbivore",
		"position": {"x": other.position.x, "y": other.position.y}, "data": {}})
	director.update()
	a.equal(manager.selected_agent_id, first.id, "a moment waits for the shot to end")
	director._until_msec = 0
	director.update()
	a.equal(manager.selected_agent_id, other.id, "then the camera turns to it")
	session.hear(_message("7", "Лиза", "!имя Искра"))
	manager.step_once()
	session.hear(_message("7", "Лиза", "!моё"))
	director.update()
	var ward := -1
	for id in manager.world_state.adoptions.keys():
		ward = int(id)
	a.is_true(ward >= 0 and manager.selected_agent_id == ward, "«!моё» cuts to the ward at once")
	# The view's world under the worker knows a far sleeper by its group's record only.
	var far := Vector2i(999, 999)
	manager.world_state._sector_states[far] = {"dormant": true, "dormant_aggregates": [
		{"record_ids": [70001, 70002], "record_positions": PackedVector2Array([Vector2(10.0, 20.0), Vector2(123.0, 456.0)])}]}
	a.equal(ReserveDirectorScript.sleeping_position(manager.world_state, 70002), Vector2(123.0, 456.0),
		"a ward asleep far off is found where its group's record has it")
	a.is_true(ReserveDirectorScript.sleeping_position(manager.world_state, 70003) == null, "and one nowhere is not")
	manager.world_state._sector_states.erase(far)
	Helpers.destroy_manager(manager)


func _test_the_overlay_text(a) -> void:
	var config := _config()
	config["vote"]["every_seconds"] = 1.0
	var made := _reserve(9935, config)
	var manager = made[0]
	var session = made[1]
	session.tick()
	a.is_true(ReserveOverlayScript.vote_text(session).begins_with("Следующее голосование через 0:01"), "the time to the next vote")
	for _tick in range(int(manager.tick_rate * 1.2)):
		manager.step_once()
		session.tick()
	session.hear(_message("1", "Вася", "!2"))
	var text: String = ReserveOverlayScript.vote_text(session)
	var second := str(session.vote.current["choices"][1]["label"])
	a.is_true(text.begins_with("Голосование, ещё 1:") and text.contains("!2 %s — 1" % second), "the vote open, with its count (%s)" % text)
	session.hear(_message("2", "Маша", "!лисы"))
	a.is_true(ReserveOverlayScript.funds_text(session).contains("лис 1"), "the funds (%s)" % ReserveOverlayScript.funds_text(session))
	session.config["overlay"] = {"help_every_seconds": 0.0, "help_seconds": 20.0}
	var quiet := not ReserveOverlayScript.help_shown(session)
	session.hear(_message("3", "Петя", "!помощь"))
	a.is_true(quiet and ReserveOverlayScript.help_shown(session), "the commands show when a viewer asks, and not by themselves when told never")
	session.config["overlay"] = {"help_every_seconds": 300.0, "help_seconds": 20.0}
	session.help_asked_at = -INF
	a.is_true(ReserveOverlayScript.help_shown(session), "and at the start of every five minutes (%.1f s)" % session.now())
	a.equal([ReserveOverlayScript.clock(59.2), ReserveOverlayScript.clock(125.0)], ["1:00", "2:05"], "the clock")
	var panel = ReserveOverlayScript.new()
	panel.bind(session)
	session.help_asked_at = -INF
	session.config["overlay"] = {"help_every_seconds": 0.0, "help_seconds": 20.0}
	panel.refresh()
	var full_has_funds: bool = panel._funds.text != ""
	panel.compact = true
	a.is_true(full_has_funds and panel._funds.text == "" and panel._table.text == "" and panel._wards.text == ""
		and panel._hint.text != "", "on a phone: where the rules are, no tables, no counts")
	panel.free()
	Helpers.destroy_manager(manager)


func _test_its_own_slots(a) -> void:
	var shipped_dir: String = SaveSystem.save_dir
	SaveSystem.save_dir = "user://test_reserve_saves"
	for path in SaveSystem.slot_paths() + SaveSystem.slot_paths(SaveSystem.KIND_RESERVE):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	var bundle: Dictionary = ReserveCommandTestsScript._bundle(9936)
	bundle["reserve"] = {"selection": {}}
	var manager = Helpers.create_manager_with(bundle, 9936)
	manager.set_lod_enabled(false)
	Helpers.spawn_herd(manager.world_state, AT, 6, 0)
	var session = ReserveSessionScript.new()
	session.configure(manager, _config())
	session.hear(_message("1", "Вася", "!олени"))
	session.hear(_message("2", "Маша", "!имя Ветка"))
	manager.step_once()
	a.equal(SaveSystem.kind_of(manager), SaveSystem.KIND_RESERVE, "a reserve's world knows its kind")
	SaveSystem.save(manager, {}, "", {}, session.export_state())
	a.is_true(SaveSystem.latest_slot() == "" and SaveSystem.latest_slot(SaveSystem.KIND_RESERVE).get_file() == "reserve_a.dat",
		"it saves to its own slot, which Continue never opens")
	var data: Dictionary = SaveSystem.read(SaveSystem.latest_slot(SaveSystem.KIND_RESERVE))
	var loaded = Helpers.create_manager(9937)
	SaveSystem.restore(loaded, data)
	a.is_true(loaded.world_state.adoptions == manager.world_state.adoptions and loaded.config_bundle.has("reserve")
		and loaded.world_state.player.budget.has("adopt"), "and comes back with its wards and powers")
	a.equal(data.get("reserve", {}), session.export_state(), "and its viewers")
	for path in SaveSystem.slot_paths(SaveSystem.KIND_RESERVE):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	SaveSystem.save_dir = shipped_dir
	Helpers.destroy_manager(manager)
	Helpers.destroy_manager(loaded)


func _test_a_rescue(a) -> void:
	var bundle: Dictionary = ReserveCommandTestsScript._bundle(9938)
	bundle["world"]["spawns"]["herbivore_count"] = 10
	var manager = Helpers.create_manager_with(bundle, 9938)
	manager.set_lod_enabled(false)
	var session = ReserveSessionScript.new()
	session.configure(manager, _config())
	var lines: Array = []
	session.told.connect(func(line: Dictionary) -> void: lines.append(str(line["text"])))
	var before := int(session.census().get("herbivore", 0))
	for _tick in range(int(manager.tick_rate * 2.0)):
		manager.step_once()
		session.tick()
	var arrived := int(session.census().get("herbivore", 0)) - before
	a.is_true(before < 40 and arrived >= 8 and lines.size() == 1 and lines[0].begins_with("Осталось %s" % HudText.animal_count("herbivore", before)),
		"a species about to be lost gets newcomers, told (%d arrived, %s)" % [arrived, str(lines)])
	for _tick in range(int(manager.tick_rate * 35.0)):
		manager.step_once()
		session.tick()
	a.equal(lines.size(), 1, "and no more before the gap")
	a.is_true(not session.census().has("wolf") and manager.world_state.player.journal.filter(
		func(entry) -> bool: return str(entry["params"].get("species", "")) == "wolf").is_empty(),
		"none for a species the world did not begin with")
	Helpers.destroy_manager(manager)


## In the game the view's world holds the animals about the camera only: the count is the
## worker's, its stats' totals. Counting the view sent newcomers to every species at the start.
func _test_counting_with_a_worker(a) -> void:
	var bundle: Dictionary = ReserveCommandTestsScript._bundle(9939)
	bundle["world"]["spawns"]["herbivore_count"] = 10
	var manager = Helpers.create_manager_with(bundle, 9939)
	var session = ReserveSessionScript.new()
	session.configure(manager, _config())
	var lines: Array = []
	session.told.connect(func(line: Dictionary) -> void: lines.append(str(line["text"])))
	manager._worker = RefCounted.new()
	manager.stats_system.latest_snapshot = {}
	session._rescue()
	a.is_true(session.census().is_empty() and lines.is_empty(), "nothing counted, nobody sent, before the worker's first count")
	manager.stats_system.latest_snapshot = {"tick": 3, "herbivore_population": 160, "predator_population": 30}
	a.is_true(int(session.census().get("herbivore", 0)) == 160 and int(session.census().get("predator", 0)) == 30,
		"the worker's totals: %s" % str(session.census()))
	session._rescue()
	a.is_true(lines.is_empty(), "and none sent where there are plenty: %s" % str(lines))
	manager._worker = null
	Helpers.destroy_manager(manager)


func _test_forgetting_viewers(a) -> void:
	var book = ViewerBook.new()
	for index in range(12):
		book.meet(_message(str(index), "Зритель", "!моё"), float(index))
	book.forget_beyond(10)
	var kept: Array = book.viewers.keys()
	kept.sort()
	a.equal(kept, ["twitch:10", "twitch:11", "twitch:3", "twitch:4", "twitch:5", "twitch:6", "twitch:7", "twitch:8", "twitch:9"],
		"past the limit, the longest unseen are forgotten, down to nine tenths")


func _test_floors_and_ceilings(a) -> void:
	var config := _config()
	config["ceilings"]["herbivore"] = 3
	var made := _reserve(9939, config)
	var manager = made[0]
	var session = made[1]
	session.hear(_message("1", "Вася", "!отстрел"))
	a.is_true(manager.pending_commands().is_empty() and str(made[2][-1]).contains("лис и так мало"),
		"no cull while the foxes are below the floor (%s)" % str(made[2]))
	a.is_true(session._crowded("release", {"species": "herbivore"}, "Голосование: Пришлое стадо")
		and str(made[2][-1]) == "Голосование: Пришлое стадо — но оленей и так много, пришлые не пришли"
		and not session._crowded("release", {"species": "predator"}, "Фонд лис"), "no newcomers to a species at its ceiling")
	Helpers.destroy_manager(manager)
	var bundle: Dictionary = ConfigLoaderScript.load_reserve_bundle(_config())
	a.equal(float(bundle["powers"]["powers"]["cull"]["cooldown_seconds"]), 240.0, "the reserve's own power settings")
	var wolves = Helpers.create_manager_with(bundle, 9943)
	a.equal(wolves.world_state.get_reproductive_capacity("wolf"), 24, "wolves are not born past their ceiling in the reserve")
	Helpers.destroy_manager(wolves)
	var lineage = preload("res://scripts/story/lineage.gd").new()
	lineage.capacity = 10
	for id in range(1, 9):
		lineage.note_birth(id, "herbivore", "female", 0.0, 0, [])
		lineage.note_death(id, float(id), "old_age", -1, Vector2.ZERO)
	for id in range(9, 12):
		lineage.note_birth(id, "herbivore", "female", 10.0, 0, [])
	a.is_true(lineage.size() == 9 and not lineage.knows(1) and not lineage.knows(2) and lineage.knows(3),
		"a shorter story forgets the longest dead first")


## Two wards named in the herd at `AT`, by Вася and Маша: `[manager, session, lines, first, second]`.
static func _two_wards(seed: int) -> Array:
	var made := _reserve(seed, _config())
	var manager = made[0]
	var session = made[1]
	session.hear(_message("1", "Вася", "!имя Ветка"))
	session.hear(_message("2", "Маша", "!имя Буран"))
	manager.step_once()
	var ids: Array = manager.world_state.adoptions.keys()
	ids.sort_custom(func(x, y) -> bool: return str(manager.world_state.adoptions[x]["viewer"]) < str(manager.world_state.adoptions[y]["viewer"]))
	return [manager, session, made[2], int(ids[0]), int(ids[1])]


func _test_ward_news(a) -> void:
	var made := _two_wards(9940)
	var manager = made[0]
	var lines: Array = made[2]
	manager.world_event.emit({"type": "AgentReproduced", "agent_id": 999, "data": {"parent_a_id": made[3], "parent_b_id": -1}})
	manager.world_event.emit({"type": "AgentReproduced", "agent_id": 1000, "data": {"parent_a_id": made[3], "parent_b_id": -1}})
	a.is_true(lines.count("Потомство у подопечного: Ветка (Вася)") == 1, "a ward's young told once a litter (%s)" % str(lines))
	manager.world_state.kill_agent(manager.world_state.get_agent(made[4]), "old_age")
	manager.step_once()
	a.is_true(lines.has("Подопечный умер от старости: Буран (Маша)"), "a ward's death told with its cause (%s)" % str(lines))
	Helpers.destroy_manager(manager)


func _test_the_banner_and_tables(a) -> void:
	var banner = ReserveBannerScript.new()
	banner.hear({"text": "фонд", "kind": "team"})
	banner.hear({"text": "реплика", "kind": "adopt"})
	banner.hear({"text": "смерть", "kind": "ward_death"})
	banner.hear({"text": "голос", "kind": "vote"})
	a.equal(banner.waiting().map(func(item) -> String: return str(item["text"])), ["смерть", "голос", "фонд"],
		"the banner shows the weightiest news first, and only news")
	banner.free()
	var made := _two_wards(9941)
	var manager = made[0]
	var session = made[1]
	var world = manager.world_state
	world.get_agent(made[3]).age = 500.0
	world.get_agent(made[4]).age = 100.0
	var eldest: Array = ReserveRecordsScript.longest_lived(world, 3)
	a.is_true(eldest.size() == 2 and str(eldest[0]["name"]) == "Ветка", "the eldest ward first")
	var book = StoryBookScript.new()
	book.bind(manager)
	book.begin({})
	book.lineage.note_animal(made[4], "herbivore", "male")
	book.lineage.note_birth(5001, "herbivore", "female", 1.0, 0, [made[4]])
	var page: String = ReserveRecordsScript.page_text(1, world, book, session, [120.0, 4])
	a.equal(page, "Большие семьи\nБуран (Маша) — 1 потомок", "the biggest families")
	session._count_perk("predator")
	a.is_true(ReserveRecordsScript.page_text(2, world, book, session, [120.0, 4]).contains("Фонд лис — 1 подарок"), "the funds' perks this year")
	a.equal(ReserveRecordsScript.year_summary(1, world, book, session),
		"Итоги года 1: дольше всех живёт Ветка (Вася), больше всех потомков — Буран (Маша), фонд года — лис", "the year's summary")
	a.equal(WardTagsScript._label(world.adoptions[made[3]]), "Ветка · Вася", "a ward's tag names it and its guardian")
	Helpers.destroy_manager(manager)


func _test_saving_in_the_background(a) -> void:
	var shipped_dir: String = SaveSystem.save_dir
	SaveSystem.save_dir = "user://test_reserve_saves"
	for path in SaveSystem.slot_paths(SaveSystem.KIND_RESERVE):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	var bundle: Dictionary = ReserveCommandTestsScript._bundle(9942)
	bundle["reserve"] = {"selection": {}}
	var manager = Helpers.create_manager_with(bundle, 9942)
	manager.set_lod_enabled(false)
	Helpers.spawn_herd(manager.world_state, AT, 6, 0)
	var session = ReserveSessionScript.new()
	session.configure(manager, _config())
	session.hear(_message("1", "Вася", "!имя Ветка"))
	manager.step_once()
	var heard: Array = []
	manager.world_exported.connect(func(world: Dictionary) -> void:
		heard.append(world)
		SaveSystem.save_exported(manager, world, {}, {}, session.export_state()))
	manager.request_world_export()
	SaveSystem.finish_writing()
	var slot := SaveSystem.latest_slot(SaveSystem.KIND_RESERVE)
	var data := SaveSystem.read(slot) if slot != "" else {}
	a.is_true(heard.size() == 1 and not data.is_empty() and data["world"].get("adoptions", {}).size() == 1
		and int(data["tick"]) == manager.current_tick and not FileAccess.file_exists(slot + ".part"),
		"an autosave taken on request and written in the background, whole")
	for path in SaveSystem.slot_paths(SaveSystem.KIND_RESERVE):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	SaveSystem.save_dir = shipped_dir
	Helpers.destroy_manager(manager)
