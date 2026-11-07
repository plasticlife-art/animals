extends SceneTree

## The map a world is built on, without running it: how much of it is land, how much of that is
## walkable, its ponds, rivers and dens, and (with an output path) a picture of it - to size an
## island (`terrain.island`) against the rectangle it replaces.
##
##   Godot --headless --path . --script res://scripts/dev/island_map.gd -- [reserve|sandbox] seed
##       [out.png] [section.path.to.key=value ...]
##
## Trailing `key=value` pairs override the bundle, as in `ecology_audit.gd`.


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var kind := str(args[0]) if args.size() > 0 else "reserve"
	var run_seed := int(args[1]) if args.size() > 1 else 7
	var picture := ""
	var overrides: Array = []
	for index in range(2, args.size()):
		if "=" in str(args[index]):
			overrides.append(str(args[index]))
		else:
			picture = str(args[index])
	var bundle: Dictionary
	if kind == "reserve":
		bundle = ConfigLoader.load_reserve_bundle(ConfigLoader.load_reserve_config())
	else:
		bundle = ConfigLoader.load_config_bundle()
	for item in overrides:
		var parts: PackedStringArray = str(item).split("=", false, 1)
		var path: PackedStringArray = parts[0].split(".")
		var target: Dictionary = bundle
		for step in range(path.size() - 1):
			if not target.has(path[step]) or not (target[path[step]] is Dictionary):
				target[path[step]] = {}
			target = target[path[step]]
		var parsed: Variant = JSON.parse_string(parts[1])
		target[path[path.size() - 1]] = parsed if parsed != null else parts[1]
	var manager = preload("res://scripts/core/simulation_manager.gd").new()
	var started := Time.get_ticks_msec()
	manager.initialize(bundle, run_seed)
	var built := Time.get_ticks_msec() - started
	var world: WorldState = manager.world_state
	var terrain: TerrainSystem = world.terrain_system
	var cells := terrain.get_cell_count()
	var land := 0
	var walkable := 0
	var beach := 0
	for index in range(cells):
		if not terrain.is_sea_index(index):
			land += 1
		if terrain.is_ground_index(index):
			walkable += 1
		if terrain.coast_cells_at_index(index) <= 1.5 and not terrain.is_sea_index(index):
			beach += 1
	var dens := {}
	for species_id in bundle.get("species", {}).keys():
		var registry = world.territory_registry(str(species_id))
		if registry != null:
			dens[species_id] = registry.size()
	var mouths: Array = []
	for river in terrain.rivers:
		var points: PackedVector2Array = river["points"]
		mouths.append([Vector2i(points[points.size() - 1] / terrain.cell_size), terrain.is_sea_position(points[points.size() - 1])])
	var counts := {}
	for agent in world.agents.values():
		counts[agent.species_type] = int(counts.get(agent.species_type, 0)) + 1
	print("%s seed %d: map %dx%d cells (%.0fx%.0f), land %d (%.2f), walkable %d, beach %d, ponds %d, rivers %d %s, dens %s, built %d ms" % [
		kind, run_seed, terrain.cols, terrain.rows, terrain.world_size.x, terrain.world_size.y, land,
		float(land) / float(cells), walkable, beach, world.pond_count(), terrain.rivers.size(), str(mouths), str(dens), built])
	print("  animals %s, land rect %s" % [str(counts), str(terrain.land_rect)])
	if picture != "":
		var image := Image.create(terrain.cols, terrain.rows, false, Image.FORMAT_RGB8)
		for index in range(cells):
			var coords := terrain.get_cell_coords(index)
			var color := terrain.get_biome_color_at_index(index)
			if terrain.is_sea_index(index):
				color = Color(0.12, 0.25, 0.45)
			elif terrain.is_water_index(index) or terrain.is_flooded_index(index):
				color = Color(0.25, 0.5, 0.8)
			elif not terrain.is_walkable_index(index):
				color = terrain.get_obstacle_color(terrain.get_obstacle_at_index(index))
			image.set_pixel(coords.x, coords.y, color)
		for source in world.water_sources:
			var at := Vector2i(Vector2(source["position"]) / terrain.cell_size)
			if at.x >= 0 and at.y >= 0 and at.x < terrain.cols and at.y < terrain.rows:
				image.set_pixel(at.x, at.y, Color(0.4, 0.8, 1.0))
		for species_id in dens.keys():
			var registry = world.territory_registry(str(species_id))
			for territory in registry.territories:
				var at := Vector2i(Vector2(territory["den"]) / terrain.cell_size)
				image.set_pixel(at.x, at.y, Color(1, 0.2, 0.1) if species_id == "wolf" else Color(1, 0.6, 0.1))
		for agent in world.agents.values():
			var at := Vector2i(agent.position / terrain.cell_size)
			if at.x >= 0 and at.y >= 0 and at.x < terrain.cols and at.y < terrain.rows and agent.species_type == "herbivore":
				image.set_pixel(at.x, at.y, Color(1, 1, 1))
		image.resize(terrain.cols * 4, terrain.rows * 4, Image.INTERPOLATE_NEAREST)
		image.save_png(picture)
	quit(0)
