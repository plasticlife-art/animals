extends RefCounted

## The always-on readouts: what the ecology strip says about the land, worked out from
## the stats snapshots, and the Russian words both readouts use.

const Helpers := preload("res://scripts/tests/test_helpers.gd")
const EcologyReadoutScript := preload("res://scripts/ui/ecology_readout.gd")
const EcologyStripScript := preload("res://scripts/ui/ecology_strip.gd")
const HudTextScript := preload("res://scripts/ui/hud_text.gd")
const HerdReadoutScript := preload("res://scripts/ui/herd_readout.gd")
const HerdLossLogScript := preload("res://scripts/ui/herd_loss_log.gd")
const HerdCardScript := preload("res://scripts/ui/herd_card.gd")
const PlayerBarScript := preload("res://scripts/ui/player_bar.gd")


func run(a) -> void:
	_test_reference_is_a_minute_back(a)
	_test_trend_holds_inside_the_band(a)
	_test_species_rows_count_risk_and_kills(a)
	_test_grass_is_read_against_what_each_biome_holds(a)
	_test_strip_reads_the_running_world(a)
	_test_words(a)
	_test_herd_counts_near_and_far(a)
	_test_herd_through_the_worker(a)
	_test_hunters_after_the_herd(a)
	_test_herd_texts(a)
	_test_loss_log_keeps_each_herds_last(a)
	_test_herd_card_follows_the_selection(a)
	_test_numbers_take_the_right_noun(a)
	_test_every_action_and_state_has_words(a)
	_test_main_scene_speaks_russian(a)
	_test_developer_mode_is_the_installations(a)
	_test_player_bar_reports_and_shows(a)


static func _sample(tick: int, seconds: float, extra: Dictionary = {}) -> Dictionary:
	var sample := {"tick": tick, "time_seconds": seconds}
	sample.merge(extra, true)
	return sample


## "Lately" is the last minute: the newest snapshot a minute or more old. Early on, when
## there is less than a minute behind, it is the oldest there is; alone, nothing.
func _test_reference_is_a_minute_back(a) -> void:
	var series: Array = []
	for second in range(0, 121):
		series.append(_sample(second * 18, float(second)))
	var latest: Dictionary = series[series.size() - 1]
	a.near(float(EcologyReadoutScript.reference_sample(series, latest).time_seconds), 60.0, 0.001,
		"a minute before the newest")
	var young: Array = series.slice(0, 31)
	a.near(float(EcologyReadoutScript.reference_sample(young, young[young.size() - 1]).time_seconds), 0.0, 0.001,
		"half a minute in: the oldest there is")
	a.is_true(EcologyReadoutScript.reference_sample([series[0]], series[0]).is_empty(), "alone: nothing to compare")
	a.is_true(EcologyReadoutScript.reference_sample([], {}).is_empty(), "no series: nothing")


## A population holds steady inside a band of 3% or two animals, whichever is wider.
func _test_trend_holds_inside_the_band(a) -> void:
	a.equal(EcologyReadoutScript.trend(100.0, 100.0), 0, "the same: holding")
	a.equal(EcologyReadoutScript.trend(102.0, 100.0), 0, "two up out of a hundred: holding")
	a.equal(EcologyReadoutScript.trend(103.0, 100.0), 1, "three up: rising")
	a.equal(EcologyReadoutScript.trend(97.0, 100.0), -1, "three down: falling")
	a.equal(EcologyReadoutScript.trend(3.0, 2.0), 0, "one up out of two: holding")
	a.equal(EcologyReadoutScript.trend(0.0, 2.0), -1, "the last two gone: falling")


## Per species: the count and its trend, the hungry and the thirsty as a share of the
## species, and the kills since the reference as a rate per minute.
func _test_species_rows_count_risk_and_kills(a) -> void:
	var reference := _sample(0, 0.0, {"herbivore_population": 190, "deaths_predation_herbivore": 10,
		"predator_population": 20, "deaths_predation_predator": 0})
	var latest := _sample(1080, 60.0, {"herbivore_population": 200, "starvation_risk_herbivore_count": 30,
		"thirst_risk_herbivore_count": 60, "deaths_predation_herbivore": 16,
		"predator_population": 20, "starvation_risk_predator_count": 1, "thirst_risk_predator_count": 0,
		"deaths_predation_predator": 0})
	var rows: Array = EcologyReadoutScript.species_rows(latest, reference, ["herbivore", "predator"])
	a.equal(rows.size(), 2, "a row per species")
	var deer: Dictionary = rows[0]
	a.equal([deer.population, deer.trend, deer.hungry, deer.thirsty, deer.kills], [200, 1, 30, 60, 6],
		"herbivores: count, rising, hungry, thirsty, killed")
	a.equal([deer.hungry_level, deer.thirsty_level, deer.kills_level],
		[EcologyReadoutScript.Level.WARN, EcologyReadoutScript.Level.BAD, EcologyReadoutScript.Level.WARN],
		"15% hungry is worth a look, 30% thirsty is bad, 3% killed a minute is worth a look")
	var foxes: Dictionary = rows[1]
	a.equal([foxes.trend, foxes.hungry_level, foxes.kills_level],
		[0, EcologyReadoutScript.Level.GOOD, EcologyReadoutScript.Level.GOOD], "predators: holding and fine")
	var first: Dictionary = EcologyReadoutScript.species_rows(latest, {}, ["herbivore"])[0]
	a.equal([first.trend, first.kills], [0, 0], "nothing to compare yet: no trend, no kills")


## A biome's grass is its biomass over the most its cells can hold; the strip reports the
## four that grow grass, in a fixed order, and leaves out one that holds none.
func _test_grass_is_read_against_what_each_biome_holds(a) -> void:
	var manager = Helpers.create_manager(631)
	var world = manager.world_state
	var capacity: Dictionary = EcologyReadoutScript.capacity_by_biome(world.resource_system, world.terrain_system)
	var total := 0.0
	for value in capacity.values():
		total += float(value)
	var caps: PackedFloat32Array = world.resource_system.export_caps()
	var expected := 0.0
	for cap in caps:
		expected += cap
	a.near(total, expected, 0.01, "every cap is counted once, under its biome")
	var rows: Array = EcologyReadoutScript.grass_rows({"grass_biomass_by_biome": {"meadow": 25.0, "forest": 80.0}},
		{"meadow": 100.0, "forest": 100.0, "drought": 0.0}, HudTextScript.BIOME_ORDER)
	a.equal(rows.size(), 2, "a biome that holds no grass is left out")
	a.equal([rows[0].id, rows[0].share, rows[0].level], ["meadow", 0.25, EcologyReadoutScript.Level.WARN],
		"a quarter left is worth a look")
	a.equal([rows[1].id, rows[1].level], ["forest", EcologyReadoutScript.Level.GOOD], "most of it left is fine")
	a.equal(EcologyReadoutScript.grass_level(0.15), EcologyReadoutScript.Level.BAD, "a seventh left is bad")
	a.equal(EcologyReadoutScript.grass_level(0.47), EcologyReadoutScript.Level.GOOD, "where a world starts is fine")
	Helpers.destroy_manager(manager)


## The strip reads the world it is shown, before and after the worker takes the world
## over and hands the view a copy.
func _test_strip_reads_the_running_world(a) -> void:
	var manager = Helpers.create_manager(632)
	Helpers.spawn_herd(manager.world_state, Vector2(120.0, 120.0), 4, 0)
	manager.stats_system.refresh_snapshot(manager.world_state, manager.current_tick, manager.simulation_time)
	var strip = EcologyStripScript.new()
	strip.bind_manager(manager)
	var shown: Dictionary = strip.readout()
	var deer := _row(shown, "herbivore")
	a.equal(int(deer.get("population", -1)), manager.world_state.get_population_metrics().get("herbivore_count", -2),
		"the herd is counted")
	a.is_true(not shown.get("grass", []).is_empty(), "and the grass is read")
	a.equal([strip._hunted.get("herbivore"), strip._hunted.get("predator")], [true, false],
		"nothing hunts predators, so their kills column says so")
	manager.enable_interactive_worker()
	var frame: Dictionary = manager._worker.step(manager.tick_duration, manager.current_tick, manager.simulation_time,
		manager._build_lod_context(), -1, false)
	manager._apply_worker_frame(frame)
	shown = strip.readout()
	a.equal(int(_row(shown, "herbivore").get("population", -1)), int(deer.get("population", -2)),
		"through the worker too")
	a.is_true(strip._capacity_world == manager.world_state, "with the grass caps of the copy it is shown")
	strip.free()
	Helpers.destroy_manager(manager)
	var idle = EcologyStripScript.new()
	a.is_true(idle.readout().is_empty(), "with no world it says nothing")
	idle.free()


static func _row(shown: Dictionary, species_id: String) -> Dictionary:
	for row in shown.get("rows", []):
		if row.id == species_id:
			return row
	return {}


func _test_words(a) -> void:
	a.equal(HudTextScript.species_label("predator"), "Хищники", "species")
	a.equal(HudTextScript.group_noun("herbivore"), "Стадо", "a herd")
	a.equal(HudTextScript.group_noun("scavenger"), "Стая", "a flock")
	a.equal(HudTextScript.biome_label("drought"), "Засуха", "biomes")
	a.equal(HudTextScript.cause_label("old_age"), "старость", "causes")
	a.equal(HudTextScript.herd_number(0), 1, "herds are numbered from one")
	a.equal(HudTextScript.ago_text(0.5), "только что", "just now")
	a.equal(HudTextScript.ago_text(40.2), "40 с назад", "seconds")
	a.equal(HudTextScript.ago_text(185.0), "3 мин назад", "minutes")
	a.equal(HudTextScript.ago_text(7300.0), "2 ч назад", "hours")


## A herd counts its awake members from the living agents and its sleeping ones from the
## aggregates of sleeping sectors; another species with the same group id is not in it.
## Its needs are means over all of them.
func _test_herd_counts_near_and_far(a) -> void:
	var manager = Helpers.create_manager(641)
	var world = manager.world_state
	var herd: Array = Helpers.spawn_herd(world, Vector2(120.0, 120.0), 4, 0)
	var calf = Helpers.spawn_herbivore(world, Vector2(160.0, 160.0), 0)
	calf.age = 0.0
	Helpers.spawn_species(world, "scavenger", Vector2(80.0, 80.0), 0)
	Helpers.spawn_herbivore(world, Vector2(200.0, 200.0), 1)
	var awake_hunger := 0.0
	for member in herd:
		member.age = float(member.reproduction.get("maturity_age", 0.0)) + 1.0
	for member in herd + [calf]:
		member.hunger = 20.0
		awake_hunger += member.hunger
	world._sector_states[Vector2i(40, 40)] = {"dormant": true, "dormant_aggregates": [
		{"species_type": "herbivore", "group_id": 0, "count": 5, "mature_males": 1, "mature_females": 2,
			"avg_hunger": 50.0, "avg_thirst": 10.0, "avg_energy": 60.0},
		{"species_type": "scavenger", "group_id": 0, "count": 9},
	]}
	var summary: Dictionary = HerdReadoutScript.summarize(world, "herbivore", 0)
	a.equal([summary.awake, summary.sleeping, summary.total], [5, 5, 10], "five near, five far")
	a.equal(summary.young, 3, "the calf near and two of the five far are young")
	a.near(float(summary.hunger), (awake_hunger + 50.0 * 5.0) / 10.0, 0.001, "hunger is the mean over all ten")
	a.equal(HerdReadoutScript.summarize(world, "scavenger", 0).total, 10, "the flock with the same id is its own")
	a.equal(HerdReadoutScript.summarize(world, "herbivore", 7).total, 0, "a herd that is not there is empty")
	world._sector_states.erase(Vector2i(40, 40))
	Helpers.destroy_manager(manager)


## The view's copy of the world, after the worker took it over, gives the same herd.
func _test_herd_through_the_worker(a) -> void:
	var manager = Helpers.create_manager(642)
	Helpers.spawn_herd(manager.world_state, Vector2(120.0, 120.0), 6, 0)
	var before: int = HerdReadoutScript.summarize(manager.world_state, "herbivore", 0).total
	manager.enable_interactive_worker()
	var frame: Dictionary = manager._worker.step(manager.tick_duration, manager.current_tick, manager.simulation_time,
		manager._build_lod_context(), -1, false)
	manager._apply_worker_frame(frame)
	a.equal(HerdReadoutScript.summarize(manager.world_state, "herbivore", 0).total, before, "six through the worker too")
	Helpers.destroy_manager(manager)


## A hunter is an animal that eats the species, in a hunting state, after one of the herd.
func _test_hunters_after_the_herd(a) -> void:
	var manager = Helpers.create_manager(643)
	var world = manager.world_state
	var herd: Array = Helpers.spawn_herd(world, Vector2(120.0, 120.0), 3, 0)
	var stranger = Helpers.spawn_herbivore(world, Vector2(220.0, 220.0), 1)
	var chasing = Helpers.spawn_predator(world, Vector2(40.0, 40.0))
	chasing.state = "chase"
	chasing.target_agent_id = herd[0].id
	var elsewhere = Helpers.spawn_predator(world, Vector2(40.0, 200.0))
	elsewhere.state = "chase"
	elsewhere.target_agent_id = stranger.id
	var resting = Helpers.spawn_predator(world, Vector2(200.0, 40.0))
	resting.state = "rest"
	resting.target_agent_id = herd[1].id
	a.equal(HerdReadoutScript.summarize(world, "herbivore", 0).hunters, 1, "one is after the herd")
	a.is_true(HerdReadoutScript.has_herd(world, herd[0]), "a grazer has a herd")
	a.is_true(not HerdReadoutScript.has_herd(world, chasing), "a predator keeps to a pair, not a herd")
	stranger.group_id = -1
	a.is_true(not HerdReadoutScript.has_herd(world, stranger), "and a grazer out of any herd has none")
	Helpers.destroy_manager(manager)


func _test_herd_texts(a) -> void:
	a.equal(HerdReadoutScript.title("herbivore", 4), "Травоядные · Стадо №5", "title")
	a.equal(HerdReadoutScript.title("scavenger", 0), "Падальщики · Стая №1", "a flock's title")
	a.equal(HerdReadoutScript.counts_text({"total": 34, "sleeping": 12, "young": 6}), "Голов: 34 (вдали: 12) · Молодых: 6",
		"counts with some far")
	a.equal(HerdReadoutScript.counts_text({"total": 8, "sleeping": 0, "young": 0}), "Голов: 8 · Молодых: 0",
		"counts with none far")
	a.equal(HerdReadoutScript.hunters_text(0), "Охоты нет", "no hunt")
	a.equal(HerdReadoutScript.hunters_text(2), "Охотятся на них: 2", "two hunters")
	a.equal(HerdReadoutScript.loss_text({}, 100.0), "Потерь пока нет", "no loss yet")
	a.equal(HerdReadoutScript.loss_text({"time": 60.0, "cause": "predation"}, 100.0), "Последняя потеря: хищник, 40 с назад",
		"a loss")
	a.equal(HerdReadoutScript.follow_text("herbivore"), "Следить за стадом", "follow a herd")
	a.equal(HerdReadoutScript.follow_text("scavenger"), "Следить за стаей", "follow a flock")


## Each herd's last death and its cause, awake or asleep; a split forgets the id it hands
## out, since ids are reused; past the cap the herd that lost longest ago goes.
func _test_loss_log_keeps_each_herds_last(a) -> void:
	var log = HerdLossLogScript.new()
	log.hear({"type": "AgentDied", "species": "herbivore", "time_seconds": 10.0, "data": {"cause": "starvation", "group_id": 2}})
	log.hear({"type": "AgentDied", "species": "herbivore", "time_seconds": 12.0, "data": {"cause": "predation", "group_id": 2, "dormant": true}})
	log.hear({"type": "AgentDied", "species": "predator", "time_seconds": 13.0, "data": {"cause": "old_age", "group_id": -1}})
	a.equal(log.last_loss("herbivore", 2), {"time": 12.0, "cause": "predation"}, "the latest, asleep or not")
	a.is_true(log.last_loss("scavenger", 2).is_empty(), "another species' herd 2 lost nothing")
	a.equal(log.size(), 1, "a death outside any herd is not kept")
	log.hear({"type": "HerdSplit", "species": "herbivore", "time_seconds": 20.0, "data": {"new_group_id": 2, "size": 4}})
	a.is_true(log.last_loss("herbivore", 2).is_empty(), "a split forgets the id it hands out")
	for index in range(HerdLossLogScript.CAPACITY + 10):
		log.hear({"type": "AgentDied", "species": "herbivore", "time_seconds": float(100 + index),
			"data": {"cause": "thirst", "group_id": 1000 + index}})
	a.equal(log.size(), HerdLossLogScript.CAPACITY, "kept within its cap")
	a.is_true(log.last_loss("herbivore", 1000).is_empty() and not log.last_loss("herbivore", 1265).is_empty(),
		"the oldest went first")


## The card shows the selected animal's herd, goes for a predator, while the start menu is
## up and when the animal dies, and hears what the herd lost.
func _test_herd_card_follows_the_selection(a) -> void:
	var manager = Helpers.create_manager(644)
	var world = manager.world_state
	var herd: Array = Helpers.spawn_herd(world, Vector2(120.0, 120.0), 4, 0)
	var fox = Helpers.spawn_predator(world, Vector2(40.0, 40.0))
	var card = HerdCardScript.new()
	card.bind_manager(manager)
	a.is_true(not card.visible, "nothing selected: no card")
	manager.selected_agent_id = herd[0].id
	card.refresh()
	a.is_true(card.visible, "a grazer selected: its herd's card")
	a.equal(int(card.summary.get("total", -1)), 4, "with its four")
	world.kill_agent(herd[1], "predation")
	card.refresh()
	a.equal(card.losses.last_loss("herbivore", 0).get("cause", ""), "predation", "the kill is heard")
	a.equal(card._loss.text, "Последняя потеря: хищник, только что", "and told")
	card.set_follow_state("flock")
	a.is_true(card._follow.button_pressed, "pressed while the camera follows the herd")
	card.set_follow_state("agent")
	a.is_true(not card._follow.button_pressed, "not while it follows the animal alone")
	card.set_allowed(false)
	a.is_true(not card.visible, "hidden under the start menu")
	card.set_allowed(true)
	manager.selected_agent_id = fox.id
	card.refresh()
	a.is_true(not card.visible, "a predator has no herd card")
	manager.selected_agent_id = herd[0].id
	world.kill_agent(herd[0], "old_age")
	card.refresh()
	a.is_true(not card.visible, "the selected animal died: the card goes")
	card.bind_manager(manager)
	a.equal(card.losses.size(), 0, "a new world starts with no losses")
	card.free()
	Helpers.destroy_manager(manager)


## A noun after a number takes the form Russian gives it: one, two to four, five and more,
## with eleven to fourteen as many.
func _test_numbers_take_the_right_noun(a) -> void:
	var forms := ["голова", "головы", "голов"]
	var said: Array = []
	for count in [1, 2, 4, 5, 11, 12, 14, 21, 22, 25, 101, 112]:
		said.append(HudTextScript.plural(count, forms))
	a.equal(said, ["голова", "головы", "головы", "голов", "голов", "голов", "голов", "голова", "головы", "голов",
		"голова", "голов"], "one, few and many")
	a.equal(HudTextScript.animal_count("herbivore", 3), "3 оленя", "three deer")
	a.equal(HudTextScript.animal_count("herbivore", 5, true), "5 оленят", "five fawns")
	a.equal(HudTextScript.animal_noun("predator", "female"), "лиса", "a vixen")
	a.equal(HudTextScript.verb("female", "умер", "умерла"), "умерла", "a verb in her gender")
	a.equal(HudTextScript.herd_name("herbivore", 2, "genitive"), "Стада №3", "from herd three")
	a.equal(HudTextScript.herd_name("scavenger", 0, "instrumental"), "Стаей №1", "became flock one")


## Whatever an animal does or is in the middle of has Russian words; nothing falls through
## to its code name.
func _test_every_action_and_state_has_words(a) -> void:
	var actions: Script = load("res://scripts/agents/ai/agent_action.gd")
	for constant in actions.get_script_constant_map().values():
		a.is_true(HudTextScript.ACTIONS.has(String(constant)), "a word for the action %s" % constant)
	for state in ["idle", "wander", "seek_food", "eat", "drink", "seek_water", "rest", "flee", "regroup",
			"migrate", "reproduce", "seek_prey", "chase", "search_last_seen", "attack", "seek_carcass",
			"feed_carcass", "investigate_water", "pair_cohesion", "patrol", "dead"]:
		a.is_true(HudTextScript.STATES.has(state), "a word for the state %s" % state)
	var labels: Array = []
	for entry in _vitals_of_a_deer():
		labels.append(entry.label)
	a.equal(labels, ["Силы", "Сытость", "Вода"], "the card's bars")


## Every label in the main scene is Russian: a Latin word left in it is an English label
## nobody translated. «LOD» is the one term kept, and key names are what is on the keys.
func _test_main_scene_speaks_russian(a) -> void:
	var scene := FileAccess.get_file_as_string("res://scenes/main/main.tscn")
	var labels := RegEx.create_from_string('(?m)^text = "(.*)"$')
	var latin := RegEx.create_from_string("[A-Za-z]{2,}")
	var english: Array = []
	for found in labels.search_all(scene):
		var text := found.get_string(1)
		for kept in ["LOD", "Esc", "Tab"]:
			text = text.replace(kept, "")
		if latin.search(text) != null:
			english.append(found.get_string(1))
	a.equal(english, [], "no English label in the main scene")


## Whether the developer panel is offered comes from the installation's debug.json, not from
## the bundle a save was made with.
func _test_developer_mode_is_the_installations(a) -> void:
	var saved := {"debug": {"developer_mode": true, "lod": {"enabled": true}}, "visuals": {}}
	var restored: Dictionary = Helpers.ConfigLoaderScript.with_shipped_presentation(saved,
		{"debug": {"developer_mode": false}, "visuals": {"props": {}}})
	a.equal(restored.debug.get("developer_mode"), false, "the installation says off")
	a.equal(restored.debug.lod, saved.debug.lod, "the rest of the debug block is the save's")
	var unsaid: Dictionary = Helpers.ConfigLoaderScript.with_shipped_presentation(saved, {"debug": {}, "visuals": {}})
	a.is_true(not unsaid.debug.has("developer_mode"), "an installation without the flag leaves it off")
	a.equal(Helpers.ConfigLoaderScript.load_config_bundle({}).debug.get("developer_mode"), false, "shipped off")


## The player's bar offers the configured speeds and three layers, reports what is pressed
## and shows what was set elsewhere without reporting it back.
func _test_player_bar_reports_and_shows(a) -> void:
	var bar = PlayerBarScript.new()
	var heard: Array = []
	bar.speed_selected.connect(func(multiplier: float) -> void: heard.append(["speed", multiplier]))
	bar.overlay_toggled.connect(func(flag: String, on: bool) -> void: heard.append([flag, on]))
	bar.pause_toggled.connect(func(paused: bool) -> void: heard.append(["pause", paused]))
	bar.configure([1.0, 2.0, 4.0, 10.0], 2.0, {"show_fear": true})
	a.equal(bar._speeds.size(), 4, "a button per speed")
	a.is_true(bar._speeds[1].button.button_pressed, "the current speed is pressed")
	a.is_true(bar._overlays["show_fear"].button_pressed and not bar._overlays["show_grass_density"].button_pressed,
		"the layers as they are")
	bar._speeds[2].button.pressed.emit()
	bar._overlays["show_chase_lines"].button_pressed = true
	bar._pause.button_pressed = true
	a.equal(heard, [["speed", 4.0], ["show_chase_lines", true], ["pause", true]], "what was pressed is reported")
	heard.clear()
	bar.set_paused_state(false)
	bar.set_overlay_state("show_fear", false)
	bar.set_speed(10.0)
	a.equal(heard, [], "what is set from elsewhere is not reported back")
	a.is_true(bar._speeds[3].button.button_pressed and not bar._speeds[1].button.button_pressed, "the speed shown")
	a.equal(bar._pause.text, "Пауза", "running: the button offers the pause")
	bar.set_paused_state(true)
	a.equal(bar._pause.text, "Пуск", "paused: it offers to go on")
	bar.free()


static func _vitals_of_a_deer() -> Array:
	var manager = Helpers.create_manager(661)
	var deer = Helpers.spawn_herbivore(manager.world_state, Vector2(60.0, 60.0), 0)
	var vitals: Array = AgentReadout.vitals(deer)
	Helpers.destroy_manager(manager)
	return vitals
