extends RefCounted

## Wolves (`species.wolf`, `role.social` "pack"): packs start at their dens, led by a pair that
## holds the territory, the rest its young; a pack hunts together, the nearest driving and the
## others fanned out to both sides of the prey (`hunt.pack`); a grown young one leaves its pack
## and founds another on an open territory, passing by one it found no way to - and, while
## none has its slot open, stays with its pack, awake or asleep, or goes back to it; a sleeping pack sleeps as one
## group and its grown young leave it asleep too; the worker steps a pack hunt as an inline tick does; and the
## shipped setup has no wolves unless asked.

const Helpers := preload("res://scripts/tests/test_helpers.gd")
const ConfigLoaderScript := preload("res://scripts/core/config_loader.gd")
const AgentBaseScript := preload("res://scripts/agents/agent_base.gd")
const DEER_AT := Vector2(1500.0, 1500.0)


func run(a) -> void:
	_test_packs_start_at_their_dens(a)
	_test_flankers_fan_out(a)
	_test_a_pack_hunts_together(a)
	_test_a_grown_wolf_founds_its_own(a)
	_test_a_grown_wolf_waits_for_room(a)
	_test_a_sleeping_pack(a)
	_test_the_worker_runs_a_pack_alike(a)
	_test_no_wolves_unless_asked(a)


## A small map's world: `count` wolves in `packs` packs at the dens; territories 8 cells across.
static func _world(seed: int, count: int, packs: int, fed := false):
	var bundle := Helpers.build_large_sector_bundle(seed)
	var territory: Dictionary = bundle["species"]["wolf"]["territory"]
	territory["radius_cells"] = 8.0
	territory["water_cells"] = 30.0
	territory["step_cells"] = 2
	if fed:
		bundle["species"]["wolf"]["metabolism"]["hunger_rate"] = 0.0
		bundle["species"]["wolf"]["metabolism"]["thirst_rate"] = 0.0
	bundle["world"]["spawns"]["wolf_count"] = count
	bundle["world"]["spawns"]["wolf_group_count"] = packs
	var manager = Helpers.create_manager_with(bundle, seed)
	manager.set_lod_enabled(false)
	return manager


static func _wolves(world) -> Array:
	var wolves: Array = []
	for agent in world.get_living_agents():
		if agent.species_type == "wolf":
			wolves.append(agent)
	return wolves


func _test_packs_start_at_their_dens(a) -> void:
	var manager = _world(9951, 10, 2)
	var world = manager.world_state
	var registry: TerritoryRegistry = world.territory_registry("wolf")
	var leaders := 0
	var right := true
	for wolf in _wolves(world):
		var held := registry.territory_of(wolf.id)
		if held != -1:
			leaders += 1
			right = right and held == wolf.group_id and registry.partner_of(wolf.id) == wolf.preferred_mate_id \
				and int(registry.get_territory(held)["group"]) == wolf.group_id
		else:
			right = right and wolf.natal_territory_id == wolf.group_id \
				and wolf.age < float(wolf.territory.get("dispersal_age_seconds", 480.0))
	a.equal(leaders, 4, "two packs, each led by a pair holding its den")
	a.is_true(right, "the leaders mates and holders of their pack's territory, the rest its young born there")
	Helpers.destroy_manager(manager)


func _test_flankers_fan_out(a) -> void:
	var manager = _world(9952, 0, 1)
	var world = manager.world_state
	var deer = Helpers.spawn_herbivore(world, DEER_AT, 0)
	deer.velocity = Vector2(100.0, 0.0)
	var pack: Array = []
	for offset in [Vector2(-200.0, 0.0), Vector2(-260.0, 60.0), Vector2(-260.0, -60.0)]:
		var wolf = Helpers.spawn_species(world, "wolf", DEER_AT + offset, 7, AgentBaseScript.SEX_MALE)
		wolf.hunger = 60.0
		wolf.target_agent_id = deer.id
		wolf.state = "chase"
		pack.append(wolf)
	world._rebuild_group_state_cache()
	var roles: Array = []
	for wolf in pack:
		roles.append(wolf._pair_role_for(world, deer))
	a.equal(roles, ["drive", "flank", "flank"], "the nearest drives, the others cut it off")
	var sides: Array = []
	for wolf in pack.slice(1):
		var target: Vector2 = wolf._flank_target(world, deer)
		sides.append(signf(target.y - DEER_AT.y))
	a.is_true(sides[0] * sides[1] < 0.0, "one to each side of it (%s)" % str(sides))
	Helpers.destroy_manager(manager)


func _test_a_pack_hunts_together(a) -> void:
	var manager = _world(9953, 0, 1)
	var world = manager.world_state
	Helpers.spawn_herd(world, DEER_AT, 6, 0)
	for index in range(4):
		var wolf = Helpers.spawn_species(world, "wolf", DEER_AT + Vector2(-300.0, -90.0 + 60.0 * index), 3,
			AgentBaseScript.SEX_MALE if index % 2 == 0 else AgentBaseScript.SEX_FEMALE)
		wolf.hunger = 70.0
	world._rebuild_group_state_cache()
	var flanking := 0
	for _tick in range(240):
		manager.step_once()
		var now := 0
		for wolf in _wolves(world):
			if wolf.state == "flank":
				now += 1
		flanking = maxi(flanking, now)
	a.is_true(int(manager.stats_system.counters.get("pair_hunts", 0)) >= 2,
		"the pack's hunts are struck up together (%d)" % int(manager.stats_system.counters.get("pair_hunts", 0)))
	a.is_true(flanking >= 2, "two at once cutting the prey off (%d)" % flanking)
	Helpers.destroy_manager(manager)


func _test_a_grown_wolf_founds_its_own(a) -> void:
	var manager = _world(9954, 0, 1)
	var world = manager.world_state
	var registry: TerritoryRegistry = world.territory_registry("wolf")
	var home: Vector2 = registry.get_territory(0)["den"]
	var young = Helpers.spawn_species(world, "wolf", home, 0, AgentBaseScript.SEX_FEMALE)
	young.age = 500.0
	young.natal_territory_id = 0
	world._rebuild_group_state_cache()
	young._seek_ground(world)
	a.equal(young.group_id, -1, "grown, it leaves its pack")
	a.is_true(young._making_for != -1 and young._making_for != 0, "and makes for an open territory not its birthplace")
	young.position = registry.get_territory(young._making_for)["den"]
	var bound: int = young._making_for
	young._seek_ground(world)
	a.equal(registry.territory_of(young.id), bound, "there it takes it")
	a.is_true(young.group_id >= 0 and int(registry.get_territory(bound)["group"]) == young.group_id,
		"and founds a pack of its own there (%d)" % young.group_id)
	Helpers.destroy_manager(manager)


func _test_a_grown_wolf_waits_for_room(a) -> void:
	var manager = _world(9956, 0, 1, true)
	var world = manager.world_state
	var registry: TerritoryRegistry = world.territory_registry("wolf")
	var home: Vector2 = registry.get_territory(0)["den"]
	var young = Helpers.spawn_species(world, "wolf", home, 0, AgentBaseScript.SEX_FEMALE)
	young.age = 500.0
	young.natal_territory_id = 0
	world._rebuild_group_state_cache()
	var nearest := registry.open_slot_near(young.position, young.sex, 0)
	young.mark_unreachable(young.place_key(registry.get_territory(nearest)["den"]), world.current_time, 60.0)
	young._seek_ground(world)
	a.is_true(young._making_for not in [-1, 0, nearest], "of the open territories it passes by one it found no way to")
	young.group_id = 0
	young._making_for = -1
	young._homeless_since = -1.0
	world._rebuild_group_state_cache()
	# Every female's slot taken but at its birthplace.
	for territory_id in range(1, registry.size()):
		registry.claim(territory_id, 90000 + territory_id, AgentBaseScript.SEX_FEMALE)
	young._seek_ground(world)
	a.equal([young.group_id, young._making_for, young._homeless_since], [0, -1, -1.0],
		"with no room anywhere it stays with its pack, its clock not running")
	# One that left and lost its slot goes back to the pack it was born in, while that holds its den.
	registry.claim(0, 91000, AgentBaseScript.SEX_MALE)
	registry.get_territory(0)["group"] = 0
	young.group_id = -1
	young._homeless_since = world.current_time
	world._rebuild_group_state_cache()
	young._seek_ground(world)
	a.equal([young.group_id, young._homeless_since], [0, -1.0], "one that lost its slot goes back to its pack")
	# One whose clock ran out with a slot open goes back too, to set out again.
	registry.release(90002, world.current_time)
	young.group_id = -1
	world.current_time += 1000.0
	young._homeless_since = world.current_time - float(young.territory["emigrate_after_seconds"]) - 1.0
	world._rebuild_group_state_cache()
	var dead: bool = young._seek_ground(world)
	a.equal([dead, young.is_alive, young.group_id], [false, true, 0], "one whose clock ran out goes back to its pack, alive")
	registry.claim(2, 90002, AgentBaseScript.SEX_FEMALE)
	var freed: int = 1 if nearest != 1 else 2
	registry.release(90000 + freed, world.current_time)
	young._looked_for_ground_at = -INF
	young._seek_ground(world)
	a.equal([young.group_id, young._making_for], [-1, freed], "and leaves it when a slot comes free")
	# Asleep alike.
	registry.claim(freed, 90000 + freed, AgentBaseScript.SEX_FEMALE)
	young.group_id = 0
	world._rebuild_group_state_cache()
	var sector_key: Vector2i = world._get_sector_key(home)
	world._sleep_sector(sector_key)
	var step := func() -> int:
		world.current_tick += 9
		world.current_time += 0.75
		world._prepare_navigation_budget()
		world._apply_dormant_sector_step(sector_key, world._sector_states[sector_key], 0.75)
		for record in world._sector_states[sector_key].get("dormant_records", []):
			if int(record["id"]) == young.id:
				return int(record.get("group_id", -2))
		return -2
	var asleep: int = step.call()
	registry.release(90000 + freed, world.current_time)
	a.equal([asleep, step.call()], [0, -1], "asleep it stays while there is no room, and leaves when there is")
	Helpers.destroy_manager(manager)


func _test_a_sleeping_pack(a) -> void:
	var manager = _world(9955, 5, 1, true)
	var world = manager.world_state
	var registry: TerritoryRegistry = world.territory_registry("wolf")
	var den: Vector2 = registry.get_territory(0)["den"]
	var grown = null
	for wolf in _wolves(world):
		if registry.territory_of(wolf.id) == -1 and grown == null:
			grown = wolf
	grown.age = 470.0
	var sector_key: Vector2i = world._get_sector_key(den)
	world._sleep_sector(sector_key)
	var keys: Array = []
	for aggregate in world._sector_states[sector_key].get("dormant_aggregates", []):
		keys.append(world._aggregate_key(aggregate))
	a.equal(keys, ["wolf:0"], "a pack sleeps as one group")
	var state_before: int = world.rng.state
	for step in range(40):
		world.current_tick += 9
		world.current_time += 0.75
		world._prepare_navigation_budget()
		world._apply_dormant_sector_step(sector_key, world._sector_states[sector_key], 0.75)
	var left := -2
	for record in world._sector_states[sector_key].get("dormant_records", []):
		if int(record["id"]) == grown.id:
			left = int(record.get("group_id", -2))
	a.is_true(left != 0 and left != -2, "grown asleep, its young one leaves the pack asleep (now %d)" % left)
	a.equal(world.rng.state, state_before, "drawing nothing from the shared stream")
	Helpers.destroy_manager(manager)


func _test_the_worker_runs_a_pack_alike(a) -> void:
	var inline = _world(9956, 0, 1)
	var threaded = _world(9956, 0, 1)
	for manager in [inline, threaded]:
		var world = manager.world_state
		Helpers.spawn_herd(world, DEER_AT, 6, 0)
		for index in range(4):
			var wolf = Helpers.spawn_species(world, "wolf", DEER_AT + Vector2(-300.0, -90.0 + 60.0 * index), 3,
				AgentBaseScript.SEX_MALE if index % 2 == 0 else AgentBaseScript.SEX_FEMALE)
			wolf.hunger = 70.0
		world._rebuild_group_state_cache()
	threaded.enable_interactive_worker()
	threaded.begin_interactive_stepping()
	for _tick in range(60):
		inline.step_once()
		threaded._post_worker_job()
		threaded.synchronize_worker()
	a.equal("\n".join(Helpers.agent_state_lines(threaded.world_state)), "\n".join(Helpers.agent_state_lines(inline.world_state)),
		"the worker's pack is where the inline one is")
	a.equal(threaded.rng.state, inline.rng.state, "with the shared stream drawn alike")
	Helpers.destroy_manager(threaded)
	Helpers.destroy_manager(inline)


func _test_no_wolves_unless_asked(a) -> void:
	var shipped: Dictionary = ConfigLoaderScript.load_config_bundle()
	a.equal(int(shipped["world"]["spawns"].get("wolf_count", -1)), 0, "the shipped setup has no wolves")
	var asked: Dictionary = ConfigLoaderScript.load_config_bundle(ConfigLoaderScript.default_selection().merged({"wolves": "packs"}, true))
	a.equal([int(asked["world"]["spawns"]["wolf_count"]), int(asked["world"]["spawns"]["wolf_group_count"])], [10, 2],
		"«Две стаи»: ten wolves in two packs")
	Helpers.destroy_manager(Helpers.create_manager(9957))
