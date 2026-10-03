extends RefCounted

## The marks animals leave on the ground, and the layer that shows them.

const Helpers := preload("res://scripts/tests/test_helpers.gd")
const TrailFieldScript := preload("res://scripts/world/trail_field.gd")
const SimulationWorkerScript := preload("res://scripts/core/simulation_worker.gd")
const GroundTracesScript := preload("res://scripts/ui/ground_traces.gd")
const WaterMaskScript := preload("res://scripts/ui/water_mask.gd")

const HERD_CENTER := Vector2(768.0, 768.0)
const STEP_SECONDS := 0.75


func run(a) -> void:
	_test_wear_lands_in_the_cell_walked_through(a)
	_test_wear_fades_by_half_each_half_life(a)
	_test_a_walking_animal_wears_the_ground(a)
	_test_a_long_step_marks_every_cell_it_crosses(a)
	_test_a_grazing_herd_leaves_no_trail(a)
	_test_a_sleeping_herd_wears_the_ground(a)
	_test_trails_change_nothing_the_animals_do(a)
	_test_trails_survive_a_save(a)
	_test_caps_are_empty_where_nothing_can_walk(a)
	_test_worker_ships_the_ground_on_its_interval(a)
	_test_layer_covers_walkable_ground_only(a)
	_test_layer_is_off_when_switched_off(a)
	_test_grass_ramp_has_no_dead_band(a)
	_test_water_mask_marks_the_ponds(a)
	_test_water_is_drawn_by_default(a)
	_test_isometric_ground_and_sprites_rise_together(a)
	_test_isometric_rows_sort_with_the_tiles(a)


func _field(half_life: float = 10.0) -> TrailField:
	var field: TrailField = TrailFieldScript.new()
	field.initialize({"trails": {"cell_size_in_grass_cells": 0.5, "half_life_seconds": half_life,
		"decay_stride_ticks": 4, "min_speed": 30.0}}, Vector2(256.0, 256.0), 32.0)
	return field


func _total(field: TrailField) -> float:
	var total := 0.0
	for value in field.export_cells():
		total += value
	return total


func _test_wear_lands_in_the_cell_walked_through(a) -> void:
	var field := _field()
	a.equal(field.cell_size, 16.0, "trail cells are sized in grass cells")
	field.deposit(Vector2(40.0, 20.0), 12.0, 0.2)
	field.deposit(Vector2(44.0, 28.0), 3.0, 0.05)
	field.deposit(Vector2(44.0, 28.0), 3.0, 0.5)
	a.near(field.wear_at(Vector2(33.0, 17.0)), 15.0, 0.0001, "steps in one cell add up, and milling about adds nothing")
	a.near(field.wear_at(Vector2(60.0, 20.0)), 0.0, 0.0001, "and stay out of the next one")
	field.deposit(Vector2(-5.0, 20.0), 9.0, 0.1)
	field.deposit(Vector2(20.0, 4000.0), 9.0, 0.1)
	a.near(_total(field), 15.0, 0.0001, "a step off the map marks nothing")
	var off := _field()
	off.enabled = false
	off.deposit(Vector2(40.0, 20.0), 12.0, 0.2)
	a.near(_total(off), 0.0, 0.0001, "a switched-off field stays blank")


func _test_wear_fades_by_half_each_half_life(a) -> void:
	var field := _field(10.0)
	field.deposit(Vector2(40.0, 20.0), 800.0, 1.0)
	var delta := 1.0 / 12.0
	for tick in range(120):
		field.step(delta, tick)
	a.near(field.wear_at(Vector2(40.0, 20.0)), 400.0, 1.0, "wear halves over one half-life")
	for tick in range(120, 120 * 12):
		field.step(delta, tick)
	a.near(field.wear_at(Vector2(40.0, 20.0)), 0.0, 0.0001, "and an unused path heals completely")


const WATER := Vector2(384.0, 384.0)


func _thirsty_herd(world, count: int, thirst: float) -> Array:
	var herd: Array = Helpers.spawn_herd(world, HERD_CENTER, count, 0)
	for agent in herd:
		agent.thirst = thirst
	return herd


## Wear within `radius` of the straight way from the herd to the water, and all of it.
func _wear_along_the_way(field: TrailField, radius: float) -> Array:
	var cells: PackedFloat32Array = field.export_cells()
	var along := 0.0
	var total := 0.0
	for index in range(cells.size()):
		if cells[index] <= 0.0:
			continue
		@warning_ignore("integer_division")
		var center: Vector2 = (Vector2(index % field.cols, index / field.cols) + Vector2(0.5, 0.5)) * field.cell_size
		var nearest: Vector2 = Geometry2D.get_closest_point_to_segment(center, HERD_CENTER, WATER)
		total += cells[index]
		if center.distance_to(nearest) <= radius:
			along += cells[index]
	return [along, total]


func _test_a_walking_animal_wears_the_ground(a) -> void:
	var manager = Helpers.create_manager_with(Helpers.build_large_sector_bundle(501), 501)
	var world = manager.world_state
	_thirsty_herd(world, 6, 75.0)
	Helpers.run_ticks(manager, 120)
	var wear: Array = _wear_along_the_way(world.trail_field, 260.0)
	a.greater(float(wear[1]), 100.0, "a herd walking to water leaves wear behind")
	a.near(float(wear[0]), float(wear[1]), 0.001, "and only along its way there")
	Helpers.destroy_manager(manager)


## A coarse step is longer than a trail cell. Marked only where it lands, a sleeping
## herd's path would be a row of dots with bare cells between them.
func _test_a_long_step_marks_every_cell_it_crosses(a) -> void:
	var field := _field()
	field.deposit_segment(Vector2(8.0, 40.0), Vector2(200.0, 40.0), 1.0)
	var bare := 0
	for column in range(0, 13):
		if field.wear_at(Vector2(float(column) * 16.0 + 8.0, 40.0)) <= 0.0:
			bare += 1
	a.equal(bare, 0, "no cell between the two ends is left bare")
	a.near(_total(field), 192.0, 0.001, "and the wear adds up to the distance walked")
	field.deposit_segment(Vector2(8.0, 120.0), Vector2(20.0, 120.0), 1.0)
	a.near(_total(field), 192.0, 0.001, "a step slower than travel marks nothing")


## Grazing covers as much ground as travelling and goes nowhere. Counted, it put a blot
## under every herd and no path between them.
func _test_a_grazing_herd_leaves_no_trail(a) -> void:
	var field := _field()
	a.is_true(field.is_travel_action(&"drink") and field.is_travel_action(&"scavenge_carcass"),
		"walking to water or to a carcass is travel")
	a.is_true(not field.is_travel_action(&"graze") and not field.is_travel_action(&"explore")
		and not field.is_travel_action(&"rest"), "grazing, wandering and resting are not")
	a.is_true(field.is_travel_goal("water") and not field.is_travel_goal("grass") and not field.is_travel_goal("wander"),
		"and the same holds for a sleeping herd's goals")
	var bundle: Dictionary = Helpers.build_large_sector_bundle(509)
	bundle["world"]["trails"] = {"travel_actions": [], "travel_goals": []}
	var manager = Helpers.create_manager_with(bundle, 509)
	_thirsty_herd(manager.world_state, 6, 75.0)
	Helpers.run_ticks(manager, 120)
	a.near(_total(manager.world_state.trail_field), 0.0, 0.0001, "movement that is not travel leaves no wear")
	Helpers.destroy_manager(manager)


func _test_a_sleeping_herd_wears_the_ground(a) -> void:
	var manager = Helpers.create_manager_with(Helpers.build_large_sector_bundle(502), 502)
	var world = manager.world_state
	_thirsty_herd(world, 12, 75.0)
	var sector_key: Vector2i = world._get_sector_key(HERD_CENTER)
	world._sleep_sector(sector_key)
	var blank := PackedFloat32Array()
	blank.resize(world.trail_field.get_cell_count())
	world.trail_field.import_cells(blank)
	for step in range(8):
		world.current_tick += int(round(STEP_SECONDS * 12.0))
		world.current_time += STEP_SECONDS
		world._prepare_navigation_budget()
		world._apply_dormant_sector_step(sector_key, world._sector_states[sector_key], STEP_SECONDS)
	var field: TrailField = world.trail_field
	var wear: Array = _wear_along_the_way(field, 260.0)
	a.greater(float(wear[1]), 100.0, "a sleeping herd walking to water wears the ground too")
	a.near(float(wear[0]), float(wear[1]), 0.001, "along its way there")
	Helpers.destroy_manager(manager)


## The field is for the player. If a herd ever read it, this is the test that says so.
func _test_trails_change_nothing_the_animals_do(a) -> void:
	var with_trails = Helpers.create_manager_with(Helpers.build_large_sector_bundle(503), 503)
	var bundle: Dictionary = Helpers.build_large_sector_bundle(503)
	bundle["world"]["trails"] = {"enabled": false}
	var without = Helpers.create_manager_with(bundle, 503)
	_thirsty_herd(with_trails.world_state, 8, 75.0)
	_thirsty_herd(without.world_state, 8, 75.0)
	Helpers.run_ticks(with_trails, 90)
	Helpers.run_ticks(without, 90)
	a.greater(_total(with_trails.world_state.trail_field), 0.0, "one world has trails")
	a.near(_total(without.world_state.trail_field), 0.0, 0.0001, "the other has none")
	a.equal(Helpers.world_fingerprint(with_trails), Helpers.world_fingerprint(without),
		"and the animals did exactly the same in both")
	Helpers.destroy_manager(with_trails)
	Helpers.destroy_manager(without)


func _test_trails_survive_a_save(a) -> void:
	var original = Helpers.create_manager(504)
	original.world_state.trail_field.deposit(Vector2(100.0, 60.0), 250.0, 1.0)
	var saved: Dictionary = original.world_state.export_state()
	var restored = Helpers.create_manager(504)
	restored.world_state.import_state(saved)
	a.equal(restored.world_state.trail_field.export_cells(), original.world_state.trail_field.export_cells(),
		"a loaded world keeps its worn paths")
	Helpers.destroy_manager(original)
	Helpers.destroy_manager(restored)


func _obstacle_bundle(seed: int) -> Dictionary:
	var bundle: Dictionary = Helpers.build_large_sector_bundle(seed)
	bundle["world"]["terrain"]["obstacles"] = {"dense_forest_cluster_count": 3, "dense_forest_radius_min_cells": 1.0,
		"dense_forest_radius_max_cells": 2.0, "cliff_count": 2, "cliff_thickness_min_cells": 1.1,
		"cliff_thickness_max_cells": 2.0, "cliff_gap_radius_cells": 1.6, "border_clearance_cells": 1}
	return bundle


func _test_caps_are_empty_where_nothing_can_walk(a) -> void:
	var manager = Helpers.create_manager_with(_obstacle_bundle(505), 505)
	var world = manager.world_state
	var caps: PackedFloat32Array = world.resource_system.export_caps()
	a.equal(caps.size(), world.resource_system.get_cell_count(), "one cap per grass cell")
	var blocked := 0
	var wrong := 0
	for index in range(caps.size()):
		var walkable: bool = world.terrain_system.is_walkable_index(index)
		if not walkable:
			blocked += 1
		if (caps[index] > 0.0) != walkable:
			wrong += 1
	a.greater(blocked, 0, "the fixture has ground nothing can walk on")
	a.equal(wrong, 0, "caps are positive exactly where animals can graze")
	Helpers.destroy_manager(manager)


func _test_worker_ships_the_ground_on_its_interval(a) -> void:
	var manager = Helpers.create_manager(506)
	var worker = SimulationWorkerScript.new()
	worker.configure(manager.world_state, manager.stats_system, manager.event_bus, manager.rng)
	var delta := 1.0 / 12.0
	var shipped: Array = []
	for tick in range(12):
		var result: Dictionary = worker.step(delta, tick, float(tick) * delta, {}, -1, false, false, 6)
		if result.has("ground"):
			shipped.append(tick + 1)
			a.equal(result.ground.grass.size(), manager.world_state.resource_system.get_cell_count(), "the whole grass grid")
			a.equal(result.ground.trails.size(), manager.world_state.trail_field.get_cell_count(), "and the whole trail grid")
	a.equal(shipped, [6, 12], "the ground is shipped on the ticks the layer redraws")
	var silent: Dictionary = worker.step(delta, 12, 1.0, {}, -1, false, false, 0)
	a.is_true(not silent.has("ground"), "and never while the layer is off")
	Helpers.destroy_manager(manager)


func _test_layer_covers_walkable_ground_only(a) -> void:
	var manager = Helpers.create_manager_with(_obstacle_bundle(507), 507)
	var world = manager.world_state
	var walkable := 0
	for index in range(world.terrain_system.get_cell_count()):
		if world.terrain_system.is_walkable_index(index):
			walkable += 1
	WorldProjection.configure({"projection": "orthogonal"})
	var layer = GroundTracesScript.new()
	layer.bind_manager(manager)
	a.is_true(layer.visible and layer._mesh_instance != null, "the layer is on by default")
	var arrays: Array = layer._mesh_instance.mesh.surface_get_arrays(0)
	a.equal(arrays[Mesh.ARRAY_VERTEX].size(), walkable * 4, "one quad per walkable cell")
	a.equal(arrays[Mesh.ARRAY_VERTEX], arrays[Mesh.ARRAY_TEX_UV], "top-down, a quad sits where its ground is")
	a.equal(layer._grass_texture.get_size(), Vector2(world.resource_system.cols, world.resource_system.rows),
		"grass reaches the GPU one texel per cell")
	a.equal(layer._trail_texture.get_size(), Vector2(world.trail_field.cols, world.trail_field.rows),
		"and so do trails")
	WorldProjection.configure({"projection": "isometric", "level_height_px": 16}, world.terrain_system.get_max_height_level())
	layer.rebuild()
	var iso: Array = layer._mesh_instance.mesh.surface_get_arrays(0)
	var lifted := true
	for vertex_index in range(0, iso[Mesh.ARRAY_VERTEX].size(), 4):
		var corner: Vector2 = iso[Mesh.ARRAY_TEX_UV][vertex_index]
		var level: int = world.terrain_system.get_height_at_position(corner + Vector2.ONE)
		if not (iso[Mesh.ARRAY_VERTEX][vertex_index] as Vector2).is_equal_approx(WorldProjection.to_screen(corner, level)):
			lifted = false
			break
	a.is_true(lifted, "in the isometric view each quad rides at its ground's height")
	WorldProjection.configure({"projection": "orthogonal"})
	layer.free()
	Helpers.destroy_manager(manager)


func _test_layer_is_off_when_switched_off(a) -> void:
	var bundle: Dictionary = Helpers.build_test_bundle(508)
	bundle["visuals"]["ground"] = {"enabled": false}
	bundle["visuals"]["water"] = {"enabled": false}
	var manager = Helpers.create_manager_with(bundle, 508)
	a.equal(manager.ground_update_interval_ticks(), 0, "a switched-off layer asks the worker for nothing")
	var layer = GroundTracesScript.new()
	layer.bind_manager(manager)
	a.is_true(not layer.visible and layer._mesh_instance == null, "and with water off too, draws nothing")
	layer.free()
	Helpers.destroy_manager(manager)


## The water field is negative inside a pond, crosses zero at its edge, and holds
## `reach` everywhere water is not near. Ponds that overlap join; one on the map's edge
## is cut off, not wrapped.
func _test_water_mask_marks_the_ponds(a) -> void:
	var mask: Dictionary = WaterMaskScript.bake([{"position": Vector2(500, 400), "radius": 100.0}],
		Vector2(1000, 800), 10.0, 40.0)
	a.equal(Vector2i(mask["cols"], mask["rows"]), Vector2i(100, 80), "one texel per ten units")
	a.is_true(WaterMaskScript.sample(mask, Vector2(500, 400)) < -90.0, "deep in the middle of the pond")
	a.near(WaterMaskScript.sample(mask, Vector2(600, 400)), 0.0, 1.0, "about zero on its edge")
	a.near(WaterMaskScript.sample(mask, Vector2(900, 100)), 40.0, 0.0001, "and dry land far from it")
	var pair: Dictionary = WaterMaskScript.bake([{"position": Vector2(300, 400), "radius": 100.0},
		{"position": Vector2(420, 400), "radius": 60.0}], Vector2(1000, 800), 10.0, 40.0)
	a.is_true(WaterMaskScript.sample(pair, Vector2(360, 400)) < -30.0, "two ponds that overlap are one water")
	a.is_true(WaterMaskScript.sample(pair, Vector2(470, 400)) < 0.0, "out to the far edge of the smaller one")
	var corner: Dictionary = WaterMaskScript.bake([{"position": Vector2.ZERO, "radius": 50.0}],
		Vector2(1000, 800), 10.0, 40.0)
	a.is_true(WaterMaskScript.sample(corner, Vector2(5, 5)) < 0.0, "a pond on the edge of the map is water there")
	a.near(WaterMaskScript.sample(corner, Vector2(995, 795)), 40.0, 0.0001, "and nowhere it does not reach")


## Water is on by default, also in a save made before the setting existed, independent
## of the grass and trails, and every watering hole is wet in the middle.
func _test_water_is_drawn_by_default(a) -> void:
	var manager = Helpers.create_manager(512)
	var world = manager.world_state
	WorldProjection.configure({"projection": "orthogonal"})
	var layer = GroundTracesScript.new()
	layer.bind_manager(manager)
	a.equal(layer._material.get_shader_parameter("water_enabled"), 1.0, "water is drawn by default")
	var mask: Dictionary = layer._water_mask
	var texture: Texture2D = layer._material.get_shader_parameter("water_tex")
	a.equal(texture.get_size(), Vector2(mask["cols"], mask["rows"]), "the field reaches the GPU one texel per texel")
	a.equal(layer._material.get_shader_parameter("water_extent"), Vector2(mask["cols"], mask["rows"]) * float(mask["texel"]),
		"and the shader knows how much world it covers")
	var dry := 0
	for source in world.water_sources:
		if WaterMaskScript.sample(mask, source["position"]) >= 0.0:
			dry += 1
	a.greater(world.water_sources.size(), 0, "fixture: the world has water")
	a.equal(dry, 0, "every watering hole is water in the middle")
	layer.free()
	Helpers.destroy_manager(manager)

	var legacy: Dictionary = Helpers.build_test_bundle(513)
	legacy["visuals"].erase("water")
	manager = Helpers.create_manager_with(legacy, 513)
	layer = GroundTracesScript.new()
	layer.bind_manager(manager)
	a.equal(layer._material.get_shader_parameter("water_enabled"), 1.0, "a save without the setting still shows water")
	layer.free()
	Helpers.destroy_manager(manager)

	var dry_bundle: Dictionary = Helpers.build_test_bundle(514)
	dry_bundle["visuals"]["water"] = {"enabled": false}
	manager = Helpers.create_manager_with(dry_bundle, 514)
	layer = GroundTracesScript.new()
	layer.bind_manager(manager)
	a.equal(layer._material.get_shader_parameter("water_enabled"), 0.0, "switched off, no water")
	a.is_true(layer._water_mask.is_empty(), "and nothing is baked")
	layer.free()
	Helpers.destroy_manager(manager)

	var bare_bundle: Dictionary = Helpers.build_test_bundle(515)
	bare_bundle["visuals"]["ground"] = {"enabled": false}
	manager = Helpers.create_manager_with(bare_bundle, 515)
	layer = GroundTracesScript.new()
	layer.bind_manager(manager)
	a.is_true(layer.visible and layer._mesh_instance != null, "with grass and trails off, water is still drawn")
	a.equal(layer._material.get_shader_parameter("ground_enabled"), 0.0, "without them")
	a.equal(manager.ground_update_interval_ticks(), 0, "and the worker still ships no ground")
	layer.free()
	Helpers.destroy_manager(manager)


## The ground follows the grass all the way down: between bare earth and lush grass no
## share is drawn like its neighbour, the tint never jumps, and the ends keep their
## hues. The old ramp tinted only below 0.4 of a cell's cap and above 0.62, so ground
## grazed to half looked untouched.
func _test_grass_ramp_has_no_dead_band(a) -> void:
	var ground: Dictionary = GroundTracesScript.resolve_ground_config({})
	var stops: Array = ground["grass_stops"]
	var flat := 0
	var jumps := 0
	var previous: Color = GroundTracesScript.grass_tint(0.0, ground)
	for step in range(1, 101):
		var share := float(step) / 100.0
		var tint: Color = GroundTracesScript.grass_tint(share, ground)
		var change := maxf(maxf(absf(tint.r - previous.r), absf(tint.g - previous.g)),
			maxf(absf(tint.b - previous.b), absf(tint.a - previous.a)))
		if share > float(stops[0]) + 0.005 and share < float(stops[3]) - 0.005 and change < 0.0002:
			flat += 1
		if change > 0.08:
			jumps += 1
		previous = tint
	a.equal(flat, 0, "every grass share between bare and lush is drawn unlike the next")
	a.equal(jumps, 0, "and the tint never jumps")
	var bare: Color = GroundTracesScript.grass_tint(0.0, ground)
	var dry: Color = GroundTracesScript.grass_tint(float(stops[1]), ground)
	var mid: Color = GroundTracesScript.grass_tint(float(stops[2]), ground)
	var lush: Color = GroundTracesScript.grass_tint(1.0, ground)
	a.is_true(bare.r > bare.g and bare.g > bare.b, "bare ground is earth-coloured")
	a.is_true(dry.r >= dry.g and dry.g > dry.b, "grass eaten to a third is straw")
	a.is_true(lush.g > lush.r and lush.g > lush.b, "lush grass is green")
	# Laid over a meadow tile, as the layer is drawn, the stages must read apart.
	var meadow := Color(0.45, 0.62, 0.30)
	var over := func(tint: Color) -> Vector3:
		var shown := meadow.lerp(Color(tint.r, tint.g, tint.b), tint.a)
		return Vector3(shown.r, shown.g, shown.b)
	a.greater(over.call(bare).distance_to(over.call(lush)), 0.15, "bare and lush ground look different")
	a.greater(over.call(dry).distance_to(over.call(mid)), 0.1, "and so do half-eaten and untouched grass")
	var manager = Helpers.create_manager(509)
	WorldProjection.configure({"projection": "orthogonal"})
	var layer = GroundTracesScript.new()
	layer.bind_manager(manager)
	var shipped: Dictionary = GroundTracesScript.resolve_ground_config(manager.config_bundle["visuals"]["ground"])
	var shipped_stops: Array = shipped["grass_stops"]
	a.equal(layer._material.get_shader_parameter("grass_stops"),
		Vector4(shipped_stops[0], shipped_stops[1], shipped_stops[2], shipped_stops[3]), "the shader gets the stops")
	a.equal(layer._material.get_shader_parameter("dry_color"), shipped["dry_color"], "and the colours")
	a.equal(GroundTracesScript.resolve_ground_config({"dry_color": [1, 2]})["dry_color"], ground["dry_color"],
		"a malformed key falls back to its default")
	layer.free()
	Helpers.destroy_manager(manager)


## A world with relief, the isometric projection set up the way `MainController` sets
## it, and the terrain layer built.
func _isometric_fixture(seed: int) -> Array:
	var bundle: Dictionary = _obstacle_bundle(seed)
	bundle["world"]["terrain"]["height"] = {"levels": 4, "frequency": 0.004, "octaves": 2,
		"max_climb_step": 1, "slope_cost": 0.35}
	bundle["visuals"]["projection"] = "isometric"
	var manager = Helpers.create_manager_with(bundle, seed)
	var terrain = manager.world_state.terrain_system
	var visuals: Dictionary = manager.config_bundle["visuals"]
	WorldProjection.configure(visuals, terrain.get_max_height_level(),
		TerrainTileRenderer.iso_art_scale(visuals, terrain.cell_size))
	var tiles := TerrainTileRenderer.new()
	tiles.bind_manager(manager)
	return [manager, tiles]


## The tile art rises one skirt step per level, scaled with the art; a sprite placed
## through `WorldProjection` has to rise exactly as far. The tiles used to sink by
## three steps per level while sprites rose by one, so everything on raised ground
## stood a cell or more away from it and no relief showed at all.
func _test_isometric_ground_and_sprites_rise_together(a) -> void:
	var fixture := _isometric_fixture(510)
	var manager = fixture[0]
	var tiles: TerrainTileRenderer = fixture[1]
	var terrain = manager.world_state.terrain_system
	var layer: TileMapLayer = tiles.get_iso_layer()
	var terrain_config: Dictionary = manager.config_bundle["visuals"]["terrain"]
	@warning_ignore("integer_division")
	var base_lift: int = (int(terrain_config["iso_region_size"][1]) - int(terrain_config["iso_tile_size"][1])) / 2
	var checked := {}
	var worst := 0.0
	for index in range(terrain.get_cell_count()):
		var level: int = terrain.get_height_at_index(index)
		if checked.has(level):
			continue
		var coords: Vector2i = terrain.get_cell_coords(index)
		var source: TileSetAtlasSource = layer.tile_set.get_source(layer.get_cell_source_id(coords))
		var data: TileData = source.get_tile_data(layer.get_cell_atlas_coords(coords), layer.get_cell_alternative_tile(coords))
		# A tile is drawn centred on its cell less `texture_origin`, and its top face
		# sits `base_lift` above the centre of the art.
		var face: Vector2 = layer.transform * (layer.map_to_local(coords) - Vector2(data.texture_origin) - Vector2(0, base_lift))
		var sprite := WorldProjection.to_screen(terrain.get_cell_center(index), level)
		worst = maxf(worst, face.distance_to(sprite))
		checked[level] = face.y - WorldProjection.to_screen(terrain.get_cell_center(index), 0).y
	a.greater(checked.size(), 2, "the fixture has ground at three levels or more")
	a.near(worst, 0.0, 0.5, "at every level a cell's top face is where a sprite on it is drawn")
	var rises := true
	for level in checked.keys():
		if level > 0 and float(checked[level]) >= 0.0:
			rises = false
	a.is_true(rises, "raised ground is drawn higher on screen, not lower (%s)" % str(checked))
	tiles.free()
	WorldProjection.configure({"projection": "orthogonal"})
	Helpers.destroy_manager(manager)


## Ground in front hides ground behind it. Drawn as one mesh over the tiles, the tint of
## a low cell painted over the raised cell in front; in the terrain layer's own y-sort
## the tiles in front cover it.
func _test_isometric_rows_sort_with_the_tiles(a) -> void:
	var fixture := _isometric_fixture(511)
	var manager = fixture[0]
	var tiles: TerrainTileRenderer = fixture[1]
	var terrain = manager.world_state.terrain_system
	var layer: TileMapLayer = tiles.get_iso_layer()
	var layer_node = GroundTracesScript.new()
	layer_node.bind_manager(manager, tiles)
	a.is_true(layer_node._mesh_instance == null, "no mesh drawn over the whole terrain")
	var walkable := 0
	var rows := {}
	for index in range(terrain.get_cell_count()):
		if terrain.is_walkable_index(index):
			walkable += 1
			var coords: Vector2i = terrain.get_cell_coords(index)
			rows[coords.x + coords.y] = true
	a.equal(layer_node._row_meshes.size(), rows.size(), "one mesh per diagonal row with ground to tint")
	var quads := 0
	var misplaced := 0
	var missorted := 0
	var elsewhere := 0
	for node in layer_node._row_meshes:
		if node.get_parent() != layer:
			elsewhere += 1
		var row: int = node.get_meta("row")
		var own_y: float = layer.map_to_local(Vector2i(row, 0)).y
		var next_y: float = layer.map_to_local(Vector2i(row + 1, 0)).y
		if not (node.position.y > own_y and node.position.y < next_y):
			missorted += 1
		var arrays: Array = node.mesh.surface_get_arrays(0)
		var anchor: Vector2 = layer.transform * node.position
		quads += arrays[Mesh.ARRAY_VERTEX].size() / 4
		for vertex_index in range(0, arrays[Mesh.ARRAY_VERTEX].size(), 4):
			var corner: Vector2 = arrays[Mesh.ARRAY_TEX_UV][vertex_index]
			var level: int = terrain.get_height_at_position(corner + Vector2.ONE)
			var drawn: Vector2 = arrays[Mesh.ARRAY_VERTEX][vertex_index] + anchor
			if not drawn.is_equal_approx(WorldProjection.to_screen(corner, level)):
				misplaced += 1
	a.equal(elsewhere, 0, "rows live in the terrain layer")
	a.equal(quads, walkable, "every walkable cell is in exactly one row")
	a.equal(missorted, 0, "each row sorts after its own tiles and before the next row's")
	a.equal(misplaced, 0, "and each quad lands where its ground is drawn")
	layer_node.free()
	tiles.free()
	WorldProjection.configure({"projection": "orthogonal"})
	Helpers.destroy_manager(manager)
