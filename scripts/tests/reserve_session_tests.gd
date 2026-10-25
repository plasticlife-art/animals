extends RefCounted

## The reserve's viewers (`ReserveSession`, `ChatCommands`, `ViewerBook`, `VoteRound`,
## `ViewerLink`): chat lines read as commands, names cleaned; a ward taken and told, a second
## asked too soon ignored; a vote won and carried out; a fund's perk; a steward's power on the
## focus herd; «!моё» asking the camera for the ward; the session back from a save; and lines of
## JSON read off the local port.

const Helpers := preload("res://scripts/tests/test_helpers.gd")
const ConfigLoaderScript := preload("res://scripts/core/config_loader.gd")
const ReserveCommandTestsScript := preload("res://scripts/tests/reserve_command_tests.gd")
const ReserveSessionScript := preload("res://scripts/reserve/reserve_session.gd")
const ViewerLinkScript := preload("res://scripts/reserve/viewer_link.gd")
const AT := Vector2(1500.0, 1500.0)


func run(a) -> void:
	_test_reading_the_chat(a)
	_test_a_ward(a)
	_test_a_vote_and_a_fund(a)
	_test_a_steward_and_mine(a)
	_test_the_local_port(a)


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


func _test_a_ward(a) -> void:
	var made := _reserve(9931, _config())
	var manager = made[0]
	var session = made[1]
	session.hear(_message("1", "Вася", "!имя Ветка"))
	manager.step_once()
	var ward := -1
	for id in manager.world_state.adoptions.keys():
		if str(manager.world_state.adoptions[id]["viewer"]) == "twitch:1":
			ward = int(id)
	a.is_true(ward != -1 and str(manager.world_state.adoptions[ward]["name"]) == "Ветка", "a viewer's ward, named")
	a.is_true(made[2].size() == 1 and str(made[2][0]).contains("опекун"), "and told (%s)" % str(made[2]))
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
