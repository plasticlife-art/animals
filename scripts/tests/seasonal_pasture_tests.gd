extends RefCounted

## Seasonal pastures (`species.herbivore.herd.migration.seasonal`): a herd that settles after a
## walk remembers the place for the season; on its first look in that season a year on it goes
## back, if the place is still good - not to bare ground, nor out of reach of water; the memory
## goes with both halves of a split and through a save; nothing is drawn from the stream; and
## without the block no herd remembers anything.

const Helpers := preload("res://scripts/tests/test_helpers.gd")
const ConfigLoaderScript := preload("res://scripts/core/config_loader.gd")
const SEASONAL := {"memory_bonus": 1.5, "switch_ratio": 1.3, "replace_share": 0.8, "forget_years": 2}
const HOME := Vector2(900.0, 900.0)
const SUMMER_SPOT := Vector2(2100.0, 2100.0)
const KEY := "herbivore:0"


func run(a) -> void:
	_test_a_settled_herd_remembers(a)
	_test_it_goes_back_next_year(a)
	_test_not_to_a_spoiled_pasture(a)
	_test_the_memory_is_kept(a)


static func _world(seed: int, seasonal: bool):
	var bundle := Helpers.build_large_sector_bundle(seed)
	bundle["world"]["climate"] = ConfigLoaderScript.load_config_bundle()["world"]["climate"].duplicate(true)
	if seasonal:
		bundle["species"]["herbivore"]["herd"]["migration"]["seasonal"] = SEASONAL.duplicate(true)
	var manager = Helpers.create_manager_with(bundle, seed)
	manager.set_lod_enabled(false)
	Helpers.spawn_herd(manager.world_state, HOME, 9, 0)
	return manager


## The world's clock at `seconds`, the climate sampled there.
static func _at(world, seconds: float) -> void:
	world.current_time = seconds
	world.climate.sample(seconds)


## Grass within `radius` of `center` taken down to `share` of what it holds.
static func _graze(world, center: Vector2, radius: float, share: float) -> void:
	for cell in world.resource_system.query_cells(center, radius):
		var index: int = int(cell.get("index", -1))
		world.resource_system.consume_cell(index, float(cell.get("biomass", 0.0)) * (1.0 - share))


func _test_a_settled_herd_remembers(a) -> void:
	var on = _world(9961, true)
	var off = _world(9961, false)
	for manager in [on, off]:
		var world = manager.world_state
		_at(world, 130.0)
		world.herd_migrations[KEY] = {"goal": HOME, "since": 100.0}
		world._update_herd_migrations()
	var memory: Dictionary = on.world_state.herd_pastures.get(KEY, {}).get("seasons", {})
	a.is_true(memory.has("summer") and Vector2(memory["summer"]["position"]).distance_to(HOME) < 120.0,
		"arrived in summer, the herd remembers the place for summer (%s)" % str(memory))
	a.is_true(off.world_state.herd_pastures.is_empty(), "without the block it remembers nothing")
	Helpers.destroy_manager(on)
	Helpers.destroy_manager(off)


## A herd at home in spring a year on that remembers a summer pasture far off.
static func _remembering(seed: int):
	var manager = _world(seed, true)
	var world = manager.world_state
	_at(world, 480.0 + 130.0)
	world.herd_pastures[KEY] = {"seen": -1, "seasons": {"summer": {"position": SUMMER_SPOT, "forage": 9999.0, "year": 0}}}
	_graze(world, HOME, world._pasture_radius("herbivore"), 0.6)
	return manager


func _test_it_goes_back_next_year(a) -> void:
	var manager = _remembering(9962)
	var world = manager.world_state
	var state_before: int = world.rng.state
	world._update_herd_migrations()
	var migration: Dictionary = world.herd_migrations.get(KEY, {})
	a.is_true(bool(migration.get("remembered", false)) and Vector2(migration.get("goal", Vector2.INF)).distance_to(SUMMER_SPOT) < 120.0,
		"in summer it goes back to its summer pasture (%s)" % str(migration))
	a.equal(world.rng.state, state_before, "drawing nothing from the shared stream")
	world.herd_migrations.erase(KEY)
	world._update_herd_migrations()
	a.is_true(not bool(world.herd_migrations.get(KEY, {}).get("remembered", false)), "only on its first look in the season")
	Helpers.destroy_manager(manager)


func _test_not_to_a_spoiled_pasture(a) -> void:
	var bare = _remembering(9963)
	_graze(bare.world_state, SUMMER_SPOT, bare.world_state._pasture_radius("herbivore") * 1.5, 0.0)
	bare.world_state._update_herd_migrations()
	a.is_true(not bool(bare.world_state.herd_migrations.get(KEY, {}).get("remembered", false)), "not to a pasture grazed bare")
	var dry = _remembering(9964)
	dry.world_state.config_bundle["species"]["herbivore"]["perception"]["water_search_radius"] = 200.0
	dry.world_state._update_herd_migrations()
	a.is_true(not bool(dry.world_state.herd_migrations.get(KEY, {}).get("remembered", false)), "nor to one out of reach of water")
	Helpers.destroy_manager(bare)
	Helpers.destroy_manager(dry)


func _test_the_memory_is_kept(a) -> void:
	var manager = _remembering(9965)
	var world = manager.world_state
	world.config_bundle["species"]["herbivore"]["herd"]["split_size"] = 4
	world._split_oversized_herds()
	var halves := 0
	for key in world.herd_pastures.keys():
		if world.herd_pastures[key].get("seasons", {}).has("summer"):
			halves += 1
	a.equal(halves, 2, "both halves of a split remember it")
	var saved: Dictionary = world.export_state()
	var other = _world(9965, true)
	other.world_state.import_state(saved)
	a.equal(other.world_state.herd_pastures, world.herd_pastures, "and it comes back with a save")
	Helpers.destroy_manager(other)
	Helpers.destroy_manager(manager)
