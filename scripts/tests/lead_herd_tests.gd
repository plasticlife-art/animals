extends RefCounted

## «Повести стадо» (`WorldState._command_lead_herd()`): a herd walks where the player sent it,
## however poor the grass there and past its own patience, until it arrives or its time runs
## out; hungrier members still follow; its sleeping part goes too, a thirsty one drinking first;
## a split takes the goal along; bad orders are refused with their reason; the walk is saved;
## awake deer actually go; and the feed tells of it.

const Helpers := preload("res://scripts/tests/test_helpers.gd")
const StoryBookScript := preload("res://scripts/story/story_book.gd")

const START := Vector2(800.0, 800.0)
const GOAL := Vector2(1400.0, 800.0)
const KEY := "herbivore:0"


func run(a) -> void:
	_test_a_led_herd_keeps_going(a)
	_test_arriving_ends_the_walk(a)
	_test_hungrier_members_follow(a)
	_test_the_sleeping_part_follows(a)
	_test_a_split_takes_the_goal_along(a)
	_test_bad_orders_are_refused(a)
	_test_a_tired_member_rests(a)
	_test_a_hungry_member_grazes_on_the_way(a)
	_test_the_walk_is_saved(a)
	_test_awake_deer_walk_there(a)
	_test_the_feed_tells_of_it(a)


## A map wide enough to walk on, every animal awake unless a test puts a sector to sleep.
static func _world(seed: int):
	var manager = Helpers.create_manager_with(Helpers.build_large_sector_bundle(seed), seed)
	manager.set_lod_enabled(false)
	return manager


static func _lead(manager, goal: Vector2, group_id: int = 0, species: String = "herbivore") -> Dictionary:
	manager.enqueue_command("lead_herd", {"species": species, "group_id": group_id, "position": goal})
	manager.step_once()
	return manager.world_state.player.journal.back()


static func _heard(manager, types: Array) -> Array:
	var heard: Array = []
	manager.world_event.connect(func(event: Dictionary) -> void:
		if types.has(str(event.get("type", ""))):
			heard.append(event))
	return heard


func _test_a_led_herd_keeps_going(a) -> void:
	var manager = _world(9901)
	var world = manager.world_state
	Helpers.spawn_herd(world, START, 8, 0)
	var heard := _heard(manager, ["HerdLeadEnded", "HerdArrived"])
	var entry := _lead(manager, GOAL)
	a.is_true(bool(entry.result.get("ok", false)), "a herd is led")
	a.equal(int(entry.result.get("size", 0)), 8, "all of it")
	a.is_true(bool(world.herd_migrations[KEY].get("player", false)) and Vector2(world.herd_migrations[KEY]["goal"]) == GOAL,
		"towards the point given")
	a.is_true(world.player.led_herds.has(KEY), "and the player's state says so")
	for index in world.resource_system.query_cells(GOAL, 400.0).map(func(cell): return int(cell.get("index", -1))):
		world.resource_system._cells[index] = 0.0
	world._update_herd_migrations()
	a.is_true(world.herd_migrations.has(KEY), "bare ground at the goal does not stop it")
	world.current_time += 200.0
	world._update_herd_migrations()
	a.is_true(world.herd_migrations.has(KEY), "nor does the herd's own patience")
	world.current_time += 120.0
	world._update_herd_migrations()
	a.is_true(not world.herd_migrations.has(KEY), "its time running out does")
	a.is_true(not world.player.led_herds.has(KEY), "and it is no longer led")
	a.equal(heard.size(), 1, "one event says so")
	a.is_true(str(heard[0].type) == "HerdLeadEnded" and str(heard[0].data.reason) == "timeout", "that it ran out of time")
	Helpers.destroy_manager(manager)


func _test_arriving_ends_the_walk(a) -> void:
	var manager = _world(9902)
	var world = manager.world_state
	var herd: Array = Helpers.spawn_herd(world, START, 6, 0)
	var heard := _heard(manager, ["HerdArrived"])
	_lead(manager, GOAL)
	for deer in herd:
		deer.position += GOAL - START
	world._update_herd_migrations()
	a.is_true(world.herd_migrations.get(KEY, {}).has("rest_until"), "a herd that got there settles to eat")
	a.is_true(not world.player.led_herds.has(KEY), "and is no longer led")
	a.equal(heard.size(), 1, "it arrived")
	Helpers.destroy_manager(manager)


func _test_hungrier_members_follow(a) -> void:
	var manager = _world(9903)
	var world = manager.world_state
	Helpers.spawn_herd(world, START, 4, 0)
	_lead(manager, GOAL)
	a.equal(world.herd_migration_goal("herbivore", 0, 60.0), GOAL, "a member at hunger 60 follows the player's walk")
	a.equal(world.herd_migration_goal("herbivore", 0, 75.0), GOAL, "and one at 75")
	a.equal(world.herd_migration_goal("herbivore", 0, 90.0), null, "one past 85 eats first")
	world.herd_migrations[KEY] = {"goal": GOAL, "since": world.current_time}
	a.equal(world.herd_migration_goal("herbivore", 0, 60.0), null, "a herd moving on its own leaves one at 60 to eat")
	Helpers.destroy_manager(manager)


func _test_the_sleeping_part_follows(a) -> void:
	var manager = _world(9904)
	var world = manager.world_state
	Helpers.spawn_herd(world, START, 6, 0)
	world.herd_migrations[KEY] = {"goal": GOAL, "since": world.current_time}
	var sector_key: Vector2i = world._get_sector_key(START)
	world._sleep_sector(sector_key)
	var aggregate: Dictionary = {}
	for group in world._sector_states[sector_key]["dormant_aggregates"]:
		if str(group.get("species_type", "")) == "herbivore":
			aggregate = group
	aggregate["avg_hunger"] = 20.0
	aggregate["avg_thirst"] = 0.0
	aggregate["peak_thirst"] = 0.0
	a.is_true(str(world._select_dormant_goal(sector_key, aggregate).get("goal_kind", "")) != "migrate",
		"asleep, a herd moving on by itself stays (`follow_asleep` off)")
	world.herd_migrations[KEY] = {"goal": GOAL, "since": world.current_time, "player": true}
	var goal: Dictionary = world._select_dormant_goal(sector_key, aggregate)
	a.is_true(str(goal.get("goal_kind", "")) == "migrate" and Vector2(goal.get("goal_position", Vector2.ZERO)) == GOAL,
		"one the player leads goes")
	aggregate["avg_thirst"] = 90.0
	a.equal(str(world._select_dormant_goal(sector_key, aggregate).get("goal_kind", "")), "water", "drinking first when thirsty")
	Helpers.destroy_manager(manager)


func _test_a_split_takes_the_goal_along(a) -> void:
	var manager = _world(9905)
	var world = manager.world_state
	var split_size := int(manager.config_bundle["species"]["herbivore"]["herd"]["split_size"])
	Helpers.spawn_herd(world, START, split_size + 6, 0)
	_lead(manager, GOAL)
	world._split_oversized_herds()
	var led: Array = world.player.led_herds.keys()
	led.sort()
	a.equal(led.size(), 2, "both halves of a split are led")
	var other := str(led[0]) if str(led[0]) != KEY else str(led[1])
	a.is_true(bool(world.herd_migrations.get(other, {}).get("player", false)) and Vector2(world.herd_migrations[other]["goal"]) == GOAL,
		"the half that left walks on to the same goal")
	Helpers.destroy_manager(manager)


func _test_bad_orders_are_refused(a) -> void:
	var manager = _world(9906)
	var world = manager.world_state
	Helpers.spawn_herd(world, START, 4, 0)
	Helpers.spawn_species(world, "scavenger", Vector2(400.0, 400.0), 5)
	var reasons: Array = []
	reasons.append(str(_lead(manager, GOAL, 5, "scavenger").result.get("reason", "")))
	reasons.append(str(_lead(manager, GOAL, 7).result.get("reason", "")))
	reasons.append(str(_lead(manager, Vector2(-50.0, 800.0)).result.get("reason", "")))
	var cell: int = world.terrain_system.get_index_from_position(GOAL)
	world.terrain_system._walkable[cell] = 0
	reasons.append(str(_lead(manager, GOAL).result.get("reason", "")))
	world.terrain_system._walkable[cell] = 1
	reasons.append(str(_lead(manager, START + Vector2(2200.0, 1200.0)).result.get("reason", "")))
	var walled: Array = []
	var terrain = world.terrain_system
	var goal_cell: Vector2i = terrain.get_cell_coords(cell)
	for index in range(terrain.get_cell_count()):
		var coords: Vector2i = terrain.get_cell_coords(index)
		if maxi(absi(coords.x - goal_cell.x), absi(coords.y - goal_cell.y)) == 2 and terrain.is_walkable_index(index):
			terrain._walkable[index] = 0
			walled.append(index)
	terrain._refresh_navigation_cache()
	terrain._path_cache.clear()
	reasons.append(str(_lead(manager, GOAL).result.get("reason", "")))
	for index in walled:
		terrain._walkable[index] = 1
	terrain._refresh_navigation_cache()
	# A ridge across the map with its gap far to the south: the goal is near, the way round is not.
	var ridge: Array = []
	var ridge_column: int = terrain.get_cell_coords(terrain.get_index_from_position(START.lerp(GOAL, 0.5))).x
	for row in range(terrain.rows - 2):
		var index: int = row * terrain.cols + ridge_column
		if terrain.is_walkable_index(index):
			terrain._walkable[index] = 0
			ridge.append(index)
	terrain._refresh_navigation_cache()
	terrain._path_cache.clear()
	reasons.append(str(_lead(manager, GOAL).result.get("reason", "")))
	for index in ridge:
		terrain._walkable[index] = 1
	terrain._refresh_navigation_cache()
	terrain._path_cache.clear()
	a.equal(reasons, ["not_a_herd", "no_herd", "off_map", "blocked", "too_far", "no_route", "too_far"],
		"a flock, a herd that is not there, off the map, a cliff, too far, a walled-in goal and one a long way round are refused")
	a.is_true(world.herd_migrations.is_empty() and world.player.led_herds.is_empty(), "and none of them leads anything")
	Helpers.destroy_manager(manager)


## A tired led member rests when it chooses to and walks on once rested: driven past its rest,
## a led herd walked itself to nothing.
func _test_a_tired_member_rests(a) -> void:
	var manager = _world(9910)
	var world = manager.world_state
	var herd: Array = Helpers.spawn_herd(world, START, 4, 0)
	_lead(manager, GOAL)
	var deer = herd[0]
	deer.current_action = &"rest"
	deer.energy = 20.0
	a.is_true(not deer._follow_player_lead(world, manager.tick_duration, []), "tired and resting: it rests")
	deer.energy = 80.0
	a.is_true(deer._follow_player_lead(world, manager.tick_duration, []), "rested: it walks on")
	Helpers.destroy_manager(manager)


## Past `LED_GRAZE_HUNGER`, a led deer standing on grass takes a bite and walks on; below it, or
## on bare ground, it only walks - at half the effort of walking anywhere else.
func _test_a_hungry_member_grazes_on_the_way(a) -> void:
	var manager = _world(9911)
	var world = manager.world_state
	var herd: Array = Helpers.spawn_herd(world, START, 4, 0)
	_lead(manager, GOAL)
	var deer = herd[0]
	var underfoot: int = world.terrain_system.get_index_from_position(deer.position)
	world.resource_system._cells[underfoot] = 300.0
	deer.hunger = 30.0
	a.is_true(deer._follow_player_lead(world, manager.tick_duration, []) and deer.state == "led", "fed enough: it walks, led")
	var walking_energy: float = deer.energy
	deer.update_needs(1.0)
	var led_cost: float = walking_energy - deer.energy
	deer.state = "migrate"
	walking_energy = deer.energy
	deer.update_needs(1.0)
	a.near(led_cost, (walking_energy - deer.energy) * AgentBase.LED_EFFORT, 0.001, "walking led costs half the effort")
	deer.hunger = 60.0
	var before: float = deer.hunger
	a.is_true(deer._follow_player_lead(world, manager.tick_duration, []) and deer.state == "eat" and deer.hunger < before,
		"hungry on grass: a bite on the way")
	a.is_true(deer.interaction_timer > 0.0, "and the pause to chew it")
	deer.interaction_timer = 0.0
	world.resource_system._cells[underfoot] = 0.0
	a.is_true(deer._follow_player_lead(world, manager.tick_duration, []) and deer.state == "led", "on bare ground it walks on")
	Helpers.destroy_manager(manager)


func _test_the_walk_is_saved(a) -> void:
	var manager = _world(9907)
	var world = manager.world_state
	Helpers.spawn_herd(world, START, 4, 0)
	_lead(manager, GOAL)
	var saved: Dictionary = world.export_state()
	var other = _world(9907)
	other.world_state.import_state(saved)
	a.is_true(bool(other.world_state.herd_migrations.get(KEY, {}).get("player", false)), "a led herd is still led after a load")
	a.equal(other.world_state.player.led_herds, world.player.led_herds, "and shown so")
	Helpers.destroy_manager(other)
	Helpers.destroy_manager(manager)


## Awake and fed, a led herd walks there - fed deer that would rest or wander otherwise - and
## arrives within half a minute of 600 units.
func _test_awake_deer_walk_there(a) -> void:
	var manager = _world(9908)
	var world = manager.world_state
	var herd: Array = Helpers.spawn_herd(world, START, 8, 0)
	for deer in herd:
		deer.hunger = 0.0
		deer.thirst = 0.0
	var heard := _heard(manager, ["HerdArrived"])
	_lead(manager, GOAL)
	var ticks := 0
	while heard.is_empty() and ticks < int(30.0 * manager.tick_rate):
		manager.step_once()
		ticks += 1
	a.equal(heard.size(), 1, "the herd arrives (after %.1f s)" % (float(ticks) / manager.tick_rate))
	Helpers.destroy_manager(manager)


func _test_the_feed_tells_of_it(a) -> void:
	var manager = _world(9909)
	var world = manager.world_state
	var herd: Array = Helpers.spawn_herd(world, START, 4, 0)
	var book = StoryBookScript.new()
	book.bind(manager)
	book.begin()
	book.feed.context_provider = func(): return {"view": Rect2(-10, -10, 1, 1)}
	_lead(manager, GOAL)
	var place: String = book.places.at(GOAL)
	var where := "" if place == "" else " " + place
	a.equal(str(book.feed.lines[0]["text"]) if not book.feed.lines.is_empty() else "", "Стадо №1 в пути: цель%s" % where,
		"the feed tells of the walk")
	for deer in herd:
		deer.position += GOAL - START
	world._update_herd_migrations()
	a.equal(str(book.feed.lines[0]["text"]), "Стадо №1 дошло до цели%s" % where, "and of its end")
	Helpers.destroy_manager(manager)
