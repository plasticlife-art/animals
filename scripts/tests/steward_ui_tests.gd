extends RefCounted

## The steward's interface: the powers' buttons with their charges and cooldowns (`PowersBar`),
## aiming a power and giving the order (`PowerAim`), the goals' chips (`GoalChips`), the brief and
## the result (`ResultWindow`), the start page's scenarios (`StartMenu`), and every word of it,
## and of the help it adds, in Russian. Built without a scene, as the other cards' tests are.

const Helpers := preload("res://scripts/tests/test_helpers.gd")
const ConfigLoaderScript := preload("res://scripts/core/config_loader.gd")
const PlayerStateScript := preload("res://scripts/world/player_state.gd")
const StartMenuScript := preload("res://scripts/ui/start_menu.gd")

const DIG_AT := Vector2(64.0, 192.0)
const HERD_AT := Vector2(800.0, 800.0)
const GOAL := Vector2(1400.0, 800.0)
const CHALLENGE := {
	"id": "test",
	"label": "Проба",
	"brief": "Пробный сценарий.",
	"own_herd": {"species": "herbivore", "near": [0.25, 0.25]},
	"result": {"won": "Стадо пережило сушь", "lost": "Стадо не пережило сушь"},
	"chips": ["water"],
	"goals": [
		{"id": "keep_herd", "role": "win", "form": "at_season_start", "season": "autumn", "share_at_least": 0.5, "label": "Сохранить половину стада"},
		{"id": "not_wiped", "role": "lose", "form": "always", "share_at_least": 0.25, "label": "Не меньше четверти"},
		{"id": "no_thirst", "role": "bonus", "form": "always", "thirst_deaths_at_most": 0, "label": "Ни одной смерти от жажды"},
	],
}


func run(a) -> void:
	_test_the_buttons_show_charges_and_cooldowns(a)
	_test_aiming_a_waterhole(a)
	_test_aiming_a_herd(a)
	_test_aiming_a_cull(a)
	_test_the_goals_chips(a)
	_test_ponds_say_how_full(a)
	_test_the_brief_and_the_result(a)
	_test_the_scenarios_page(a)
	_test_every_word_is_russian(a)


func _test_the_buttons_show_charges_and_cooldowns(a) -> void:
	var player = PlayerStateScript.new()
	player.configure({"powers": {"dig_pond": {"charges": 1, "cooldown_seconds": 480.0}, "lead_herd": {"charges": 2, "cooldown_seconds": 60.0}}})
	var bar = PowersBar.new()
	var pressed: Array = []
	bar.power_pressed.connect(func(power: String) -> void: pressed.append(power))
	bar.refresh(player, 0.0, "", "")
	a.is_true(bar.button("dig_pond").text == "Водопой (Q) ×1" and not bar.button("dig_pond").disabled, "a charge left: ready")
	player.spend("lead_herd", 10.0)
	bar.refresh(player, 30.0, "", "")
	a.equal(bar.button("lead_herd").text, "Повести стадо (E) ×1 · 40 с", "a charge spent, cooling down: the seconds to wait")
	a.is_true(bar.button("lead_herd").disabled, "and greyed")
	player.spend("dig_pond", 0.0)
	bar.refresh(player, 600.0, "lead_herd", "Щёлкните, куда вести")
	a.is_true(bar.button("dig_pond").text == "Водопой (Q) ×0" and bar.button("dig_pond").disabled, "none left: greyed, no wait shown")
	a.is_true(bar.button("lead_herd").button_pressed and not bar.button("lead_herd").disabled, "the power aimed is pressed")
	a.equal(bar.message_text(), "Щёлкните, куда вести", "and the line above says how")
	bar.button("lead_herd").pressed.emit()
	a.equal(pressed, ["lead_herd"], "a press is reported")
	var sandbox = PlayerStateScript.new()
	sandbox.configure(ConfigLoaderScript.load_config_bundle()["powers"])
	bar.refresh(sandbox, 0.0, "", "")
	a.equal(bar.button("dig_pond").text, "Водопой (Q)", "the sandbox counts no charges")
	a.is_true(bar.button("cull").visible, "and offers the cull")
	bar.refresh(player, 0.0, "", "")
	a.is_true(not bar.button("cull").visible, "a world without it shows no cull button")
	a.is_true(PowersBar.has_powers(sandbox) and not PowersBar.has_powers(null), "a world with powers shows the bar")
	bar.free()


func _test_aiming_a_waterhole(a) -> void:
	var manager = Helpers.create_manager(9951)
	var aim := PowerAim.new()
	a.is_true(aim.arm(manager, "dig_pond") and aim.is_armed() and aim.message.begins_with("Щёлкните"), "aimed, with how to")
	a.equal(str(aim.preview(manager, DIG_AT)["reason"]), "", "green where a pond can go")
	a.equal(str(aim.preview(manager, Vector2(4.0, 4.0))["reason"]), "off_map", "red at the edge")
	a.equal(aim.issue(manager, Vector2(4.0, 4.0)), -1, "a click there gives no order")
	a.is_true(aim.is_armed() and aim.message == "Слишком близко к краю карты", "says why and keeps aiming")
	var seq := aim.issue(manager, DIG_AT)
	a.is_true(seq > 0 and not aim.is_armed(), "a click where it can go gives the order and stops aiming")
	var queued: Array = manager.pending_commands()
	a.is_true(queued.size() == 1 and str(queued[0]["type"]) == "dig_pond", "the order is queued")
	manager.step_once()
	a.is_true(not aim.arm(manager, "dig_pond") and aim.message == "Ещё не готово", "cooling down, it cannot be aimed")
	Helpers.destroy_manager(manager)


func _test_aiming_a_herd(a) -> void:
	var manager = Helpers.create_manager_with(Helpers.build_large_sector_bundle(9952), 9952)
	manager.set_lod_enabled(false)
	var world = manager.world_state
	var herd: Array = Helpers.spawn_herd(world, HERD_AT, 6, 0)
	var aim := PowerAim.new()
	a.is_true(not aim.arm(manager, "lead_herd") and aim.message == "Сначала выберите оленя", "no herd chosen: nothing to lead")
	manager.select_agent_by_id(herd[0].id, false)
	a.is_true(aim.arm(manager, "lead_herd") and aim.message.contains("Стадо №1"), "the selected deer's herd, named")
	a.equal(str(aim.preview(manager, GOAL)["reason"]), "", "a goal it can reach")
	a.equal(str(aim.preview(manager, HERD_AT + Vector2(2200.0, 1200.0))["reason"]), "too_far", "one too far")
	var terrain = world.terrain_system
	var goal_cell: Vector2i = terrain.get_cell_coords(terrain.get_index_from_position(GOAL))
	var walled: Array = []
	for index in range(terrain.get_cell_count()):
		var coords: Vector2i = terrain.get_cell_coords(index)
		if maxi(absi(coords.x - goal_cell.x), absi(coords.y - goal_cell.y)) == 2 and terrain.is_walkable_index(index):
			terrain._walkable[index] = 0
			walled.append(index)
	terrain._refresh_navigation_cache()
	terrain._path_cache.clear()
	# Aimed again: the route found is kept per cell while aiming, the ground never changing in play.
	aim.arm(manager, "lead_herd")
	a.equal(str(aim.preview(manager, GOAL)["reason"]), "no_route", "one walled in")
	for index in walled:
		terrain._walkable[index] = 1
	terrain._refresh_navigation_cache()
	terrain._path_cache.clear()
	var seq := aim.issue(manager, GOAL + Vector2(0.0, 64.0))
	var queued: Array = manager.pending_commands()
	a.is_true(seq > 0 and queued.size() == 1 and int(queued[0]["params"]["group_id"]) == 0
		and str(queued[0]["params"]["species"]) == "herbivore", "the order names the herd")
	manager.selected_agent_id = -1
	manager.config_bundle["challenge"] = CHALLENGE.duplicate(true)
	manager._start_scenario()
	var own := PowerAim.herd_to_lead(manager)
	a.is_true(int(own.get("group_id", -1)) == 0 and Vector2(own["center"]).distance_to(HERD_AT) < 120.0,
		"with none selected, in a scenario, the player's own herd")
	Helpers.destroy_manager(manager)


func _test_aiming_a_cull(a) -> void:
	var manager = Helpers.create_manager_with(Helpers.build_large_sector_bundle(9958), 9958)
	manager.set_lod_enabled(false)
	var world = manager.world_state
	for index in range(4):
		Helpers.spawn_predator(world, HERD_AT + Vector2(15.0 * index, 0.0))
	var aim := PowerAim.new()
	a.is_true(aim.arm(manager, "cull") and aim.message.contains("до 3"), "aimed, with how many it takes")
	var shown := aim.preview(manager, HERD_AT)
	a.is_true(str(shown["kind"]) == "cull" and int(shown["count"]) == 4 and str(shown["reason"]) == "", "four foxes in the circle: green")
	a.equal(str(aim.preview(manager, GOAL + Vector2(600.0, 600.0))["reason"]), "no_target", "none there: red")
	world._sleep_sector(world._get_sector_key(HERD_AT))
	a.equal(int(aim.preview(manager, HERD_AT)["count"]), 4, "asleep, still counted")
	var seq := aim.issue(manager, HERD_AT)
	var queued: Array = manager.pending_commands()
	a.is_true(seq > 0 and queued.size() == 1 and str(queued[0]["type"]) == "cull", "a click gives the order")
	Helpers.destroy_manager(manager)


## A scenario world whose own herd is ten, the shipped clock begun in summer.
static func _scenario_world(seed: int):
	var bundle: Dictionary = Helpers.build_large_sector_bundle(seed)
	var climate: Dictionary = ConfigLoaderScript.load_config_bundle()["world"]["climate"].duplicate(true)
	climate["enabled"] = true
	climate["start_season_index"] = 1
	bundle["world"]["climate"] = climate
	bundle["challenge"] = CHALLENGE.duplicate(true)
	var manager = Helpers.create_manager_with(bundle, seed)
	manager.set_lod_enabled(false)
	var herd: Array = Helpers.spawn_herd(manager.world_state, HERD_AT, 10, 0)
	manager._start_scenario()
	return [manager, herd]


func _test_the_goals_chips(a) -> void:
	var made: Array = _scenario_world(9953)
	var manager = made[0]
	var herd: Array = made[1]
	var runner = manager.scenario
	var goals: Array = CHALLENGE["goals"]
	var keep := GoalChips.chip(goals[0], runner, 0.0)
	a.is_true(str(keep["text"]) == "Ваше стадо: 10 из 10, нужно 5 · ещё 2:00" and str(keep["state"]) == "pending",
		"the herd, what it needs and the time left (%s)" % keep["text"])
	a.equal(str(GoalChips.chip(goals[1], runner, 0.0)["text"]), "Не меньше 3 голов", "the floor in heads")
	a.equal(str(GoalChips.chip(goals[2], runner, 0.0)["text"]), "Ни одной смерти от жажды", "the bonus")
	manager.world_state.kill_agent(herd[0], "thirst")
	for index in range(1, 6):
		manager.world_state.kill_agent(herd[index], "predation")
	manager.step_once()
	a.equal(str(GoalChips.chip(goals[0], runner, manager.simulation_time)["state"]), "warning", "four left of ten: amber")
	var thirst := GoalChips.chip(goals[2], runner, manager.simulation_time)
	a.is_true(str(thirst["text"]) == "Смертей от жажды: 1" and str(thirst["state"]) == "failed", "the bonus lost: red")
	a.is_true(str(keep["tooltip"]).contains("Сохранить половину стада"), "the goal's own words in the tooltip")
	var chips = GoalChips.new()
	chips.refresh(runner, manager.simulation_time)
	a.equal(chips.get_child_count(), 3, "a chip a goal")
	for index in range(6, 10):
		herd[index].thirst = 70.0
	var water := GoalChips.herd_water(manager.world_state, runner)
	a.near(water, 30.0, 0.5, "the herd's water: the mean of the four left (%.1f)" % water)
	chips.refresh(runner, manager.simulation_time, manager.world_state)
	a.equal(chips.get_child_count(), 4, "and a chip for it")
	a.is_true(str(GoalChips.water_chip(64.0)["text"]) == "Вода стада: 64" and str(GoalChips.water_chip(64.0)["state"]) == "pending",
		"enough water: ink")
	a.is_true(str(GoalChips.water_chip(45.0)["state"]) == "warning" and str(GoalChips.water_chip(20.0)["state"]) == "failed",
		"low: amber, critical: red")
	runner.challenge.erase("chips")
	chips.refresh(runner, manager.simulation_time, manager.world_state)
	a.equal(chips.get_children().filter(func(chip: Control) -> bool: return chip.visible).size(), 3,
		"no water chip where the scenario does not ask for one")
	runner.challenge["chips"] = ["water"]
	runner.species_now = {"predator": 34}
	runner.species_start = {"predator": 60}
	a.equal(str(GoalChips.chip({"id": "f", "role": "lose", "species_at_least": {"predator": 20}}, runner, 0.0)["text"]),
		"Лисы: 34, не меньше 20", "a species' floor")
	a.equal(str(GoalChips.chip({"id": "f", "role": "lose", "species_share_at_least": {"predator": 0.5}}, runner, 0.0)["text"]),
		"Лисы: 34, не меньше 30", "as a share of its start")
	runner.culled = 5
	a.equal(str(GoalChips.chip({"id": "c", "role": "bonus", "culled_at_most": 12}, runner, 0.0)["text"]), "Отстреляно: 5 из 12",
		"the culls against their limit")
	chips.free()
	Helpers.destroy_manager(manager)


## A pond's name on the map says how full it is while ponds have levels, and that it is dry.
func _test_ponds_say_how_full(a) -> void:
	var water = WaterSystem.new()
	var sources := [{"position": Vector2(0.0, 0.0), "radius": 100.0}, {"position": Vector2(500.0, 0.0), "radius": 100.0}]
	water.initialize({"enabled": true, "initial_level": 0.35}, sources, 840.0, 120.0, true, 1)
	a.equal(PlaceLabels.pond_text("Тихая заводь", water, 0), "Тихая заводь · 35 %", "how full")
	water.levels[1] = 0.0
	water._settle(1)
	a.equal(PlaceLabels.pond_text("Тёмный плёс", water, 1), "Тёмный плёс · сухо", "dry")
	var still = WaterSystem.new()
	still.initialize({"enabled": false}, [{"position": Vector2.ZERO, "radius": 100.0}], 840.0, 120.0, true, 1)
	a.equal(PlaceLabels.pond_text("Тихая заводь", still, 0), "Тихая заводь", "the name alone while ponds never change")


func _test_the_brief_and_the_result(a) -> void:
	var window = ResultWindow.new()
	var heard: Array = []
	for name in ["brief_closed", "watch_on_requested", "restart_requested", "menu_requested"]:
		window.connect(name, func() -> void: heard.append(name))
	window.show_brief(CHALLENGE)
	a.is_true(window.mode() == "brief" and window.text().contains("Пробный сценарий.") and window.text().contains("• Сохранить половину стада"),
		"the brief: what is asked and the goals")
	a.equal(window.button_labels(), ["Начать"], "and one way on")
	window._buttons.get_child(0).pressed.emit()
	a.equal(heard, ["brief_closed"], "which closes it")
	var made: Array = _scenario_world(9954)
	var manager = made[0]
	var herd: Array = made[1]
	manager.world_state.kill_agent(herd[0], "thirst")
	manager.world_state.kill_agent(herd[1], "predation")
	manager.enqueue_command("dig_pond", {"position": HERD_AT + Vector2(300.0, 0.0)})
	manager.step_once()
	var runner = manager.scenario
	var summary: Dictionary = runner.summary(manager)
	window.show_result(true, summary, runner, CHALLENGE)
	var text: String = window.text()
	a.is_true(text.begins_with("Стадо пережило сушь"), "the scenario's own title")
	a.is_true(text.contains("Осталось 8 из 10 (80 %)") and text.contains("Погибли: жажда 1, хищник 1"), "the herd left and its dead (%s)" % text)
	a.is_true(text.contains("Силы: Водопой 1") or text.contains("Силы не понадобились"), "the powers used")
	a.is_true(text.contains("Дополнительно: Ни одной смерти от жажды — не выполнено"), "and the bonus")
	a.equal(window.button_labels(), ["Смотреть дальше", "Заново", "В меню"], "three ways on")
	heard.clear()
	for button in window._buttons.get_children():
		button.pressed.emit()
	a.equal(heard, ["watch_on_requested", "restart_requested", "menu_requested"], "each says so")
	a.equal(ResultWindow.result_title(false, CHALLENGE), "Стадо не пережило сушь", "and a loss its own")
	window.free()
	Helpers.destroy_manager(manager)


func _test_the_scenarios_page(a) -> void:
	var menu = StartMenuScript.new()
	menu._ready()
	var first: Button = null
	for child in menu._root_page.get_child(0).get_child(0).get_children():
		if child is Button:
			first = child
			break
	a.is_true(first != null and first.text == "Сценарии", "«Сценарии» first on the front page")
	first.pressed.emit()
	a.is_true(menu._scenarios_page.visible and not menu._root_page.visible, "it opens the page")
	var texts: Array = []
	var play: Button = null
	for child in menu._scenarios_page.get_child(0).get_child(0).get_children():
		if child is Label:
			texts.append(child.text)
		elif child is Button and child.text == "Играть" and play == null:
			play = child
	a.is_true(texts.has("Долгая сушь") and play != null, "«Долгая сушь» with its brief and a button")
	var asked: Array = []
	menu.scenario_requested.connect(func(scenario_id: String, style: String) -> void: asked.append([scenario_id, style]))
	play.pressed.emit()
	a.equal(asked, [["long_drought", ConfigLoaderScript.default_selection()["style"]]], "played in the chosen style")
	menu.show_root()
	a.is_true(menu._root_page.visible and not menu._scenarios_page.visible, "and back to the front")
	menu.free()


func _test_every_word_is_russian(a) -> void:
	var latin := RegEx.create_from_string("[A-Za-z]")
	var words: Array = []
	words.append_array(PowerAim.LABELS.values())
	words.append_array(PowerAim.REFUSALS.values())
	words.append_array(PowersBar.DESCRIPTIONS.values())
	words.append_array(ResultWindow.DEFAULT_TITLES.values())
	words.append(GoalChips.heads_genitive(21))
	words.append(str(GoalChips.water_chip(50.0)["text"]))
	words.append(str(GoalChips.water_chip(50.0)["tooltip"]))
	words.append(PlaceLabels.pond_text("Тихая заводь", null, 0))
	words.append(GoalChips.heads_genitive(11))
	var scenarios: Dictionary = ConfigLoaderScript._load_json(ConfigLoaderScript.SCENARIOS_FILE).get("scenarios", {})
	for scenario in scenarios.values():
		words.append(str(scenario.get("label", "")))
		words.append(str(scenario.get("brief", "")))
		for goal in scenario.get("challenge", {}).get("goals", []):
			words.append(str(goal.get("label", "")))
		words.append_array(scenario.get("challenge", {}).get("result", {}).values())
	var tags := RegEx.create_from_string("\\[/?b\\]")
	# Keys keep their own letters: «(Q)», «(R)», «Esc».
	var keys := RegEx.create_from_string("\\((Q|E|R)\\)|Esc")
	for section in ConfigLoaderScript.list_help_sections():
		if str(section["id"]) in ["powers", "scenarios"]:
			words.append(str(section["label"]))
			words.append(keys.sub(tags.sub(str(section["body"]), "", true), "", true))
	var foreign: Array = []
	for text in words:
		if latin.search(str(text)) != null:
			foreign.append(str(text).substr(0, 40))
	a.equal(foreign, [], "every word the player reads is Russian")
	var help_ids: Array = ConfigLoaderScript.list_help_sections().map(func(section: Dictionary) -> String: return str(section["id"]))
	a.is_true(help_ids.has("powers") and help_ids.has("scenarios"), "the help tells of powers and scenarios")
