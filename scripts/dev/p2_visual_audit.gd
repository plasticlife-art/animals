extends SceneTree

## Deterministic P2 chase/cover scene.
## -- style output_directory [seed]
const REQUESTED_RESOLUTION := Vector2i(1600, 900)
const SETTLE_FRAMES := 30

var main = null
var manager = null
var style := "topdown_kenney"
var output := "/private/tmp/animals-p2-visual"
var seed := 2301
var frames := 0
var staged := false
var anchor := Vector2.ZERO
var roles: Array = []


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	style = args[0] if args.size() > 0 else style
	output = args[1] if args.size() > 1 else output
	seed = int(args[2]) if args.size() > 2 else seed
	DirAccess.make_dir_recursive_absolute(output)
	DisplayServer.window_set_size(REQUESTED_RESOLUTION)
	main = load("res://scenes/main/main.tscn").instantiate()
	root.add_child(main)


func _process(_delta: float) -> bool:
	frames += 1
	if frames == 2:
		var selection := {"style": style, "map_size": "small", "mix": "balanced",
			"scenario": "normal", "rules": "normal", "difficulty": "normal"}
		main._selection = selection
		main._start_simulation(selection, seed)
		main._autosave_interval = 0
		manager = main.simulation_manager
		manager.synchronize_worker()
		manager.set_paused(true)
		_stage_scene()
		staged = true
	if staged and frames >= 2 + SETTLE_FRAMES:
		_capture()
		manager.shutdown()
		return true
	return false


func _stage_scene() -> void:
	var world = manager.world_state
	if not WorldProjection.is_identity():
		for index in world.terrain_system.get_cell_count():
			world.terrain_system._heights[index] = 0
		world.terrain_system.height_levels = 1
		WorldProjection.configure(manager.config_bundle.visuals, 0)
		main.terrain_tiles.rebuild()
	anchor = _find_clear_anchor(world)
	var herbivores: Array = []
	var predators: Array = []
	var scavengers: Array = []
	for agent in world.get_living_agents():
		agent.position = Vector2(48, 48)
		if agent.species_type == "herbivore" and herbivores.size() < 2:
			herbivores.append(agent)
		elif agent.species_type == "predator" and predators.size() < 2:
			predators.append(agent)
		elif agent.species_type == "scavenger" and scavengers.size() < 1:
			scavengers.append(agent)
	var placements := [
		[herbivores[0], Vector2(-230, -85), "fleeing_behind_tree", "flee"],
		[predators[0], Vector2(-230, 45), "occluded_hunter", "search_last_seen"],
		[scavengers[0], Vector2(0, 30), "inside_bush", "flee"],
		[predators[1], Vector2(185, 45), "searching_last_seen", "search_last_seen"],
		[herbivores[1], Vector2(250, -45), "last_confirmed_prey", "flee"],
	]
	roles.clear()
	for placement in placements:
		var agent = placement[0]
		agent.position = anchor + placement[1]
		agent.velocity = Vector2.ZERO
		agent.direction = Vector2.RIGHT
		agent.state = placement[3]
		agent.current_action = &"hunt_prey" if agent.species_type == "predator" else &"flee_to_safe_area"
		roles.append({"id": agent.id, "species": agent.species_type,
			"role": placement[2], "state": placement[3], "position": agent.position})

	_clear_scenery(world)
	_add_prop(world, 1, "tree_large", anchor + Vector2(-230, -20))
	_add_prop(world, 2, "bush", anchor + Vector2(0, 30))
	_add_prop(world, 3, "tree_large", anchor + Vector2(220, 5))
	predators[0].search_anchor = herbivores[0].position
	predators[0].target_position = herbivores[0].position
	predators[0].target_agent_id = herbivores[0].id
	predators[1].search_anchor = anchor + Vector2(250, -45)
	predators[1].target_position = predators[1].search_anchor
	predators[1].target_agent_id = herbivores[1].id
	world.spatial_grid.rebuild(world.get_living_agents())

	manager.selected_agent_id = -1
	main.debug_panel.visible = false
	main.charts_panel.visible = false
	main.minimap.visible = false
	main.climate_indicator.visible = false
	main.ecology_strip.visible = false
	main.selection_tag.visible = false
	main.selection_card.visible = false
	main.herd_card.set_allowed(false)
	main.agent_renderer.rebuild_batches()
	main.agent_renderer.request_refresh()
	main.world_camera.global_position = WorldProjection.to_screen(anchor,
		world.terrain_system.get_height_at_position(anchor))
	main.world_camera.zoom = Vector2.ONE * (1.8 if WorldProjection.is_identity() else 1.55)


func _clear_scenery(world) -> void:
	world.scenery.objects.clear()
	world.scenery.buckets.clear()
	world.scenery._point_cache.clear()
	world.scenery._near_cache.clear()
	world.scenery.max_extent = 0.0


func _add_prop(world, object_id: int, kind: String, position: Vector2) -> void:
	var physics: Dictionary = manager.config_bundle.world.scenery.types.get(kind, {})
	var props: Dictionary = manager.config_bundle.visuals.props
	var slots: Array = props.groups.get(kind, [])
	world.scenery.add_object({"id": object_id, "position": position, "kind": kind,
		"radius": float(physics.get("radius_cells", 0.0)) * world.terrain_system.cell_size,
		"cover_radius": float(physics.get("cover_radius_cells", 0.0)) * world.terrain_system.cell_size,
		"opacity": float(physics.get("opacity", 0.0)),
		"move_cost": float(physics.get("move_cost", 1.0)),
		"slot": 0 if slots.is_empty() else int(slots[0]),
		"scale": float(props.group_scale.get(kind, 1.0)),
		"level": 0})


func _find_clear_anchor(world) -> Vector2:
	var center: Vector2 = world.bounds.get_center()
	var terrain = world.terrain_system
	var best: Vector2 = terrain.get_cell_center(terrain.find_nearest_walkable_index(
		terrain.get_index_from_position(center)))
	for ring in range(0, 20):
		for y in range(-ring, ring + 1):
			for x in range(-ring, ring + 1):
				if ring > 0 and abs(x) != ring and abs(y) != ring:
					continue
				var candidate: Vector2 = best + Vector2(x, y) * terrain.cell_size
				if world.bounds.grow(-340.0).has_point(candidate):
					return candidate
	return best


func _capture() -> void:
	var world = manager.world_state
	var image := root.get_texture().get_image()
	var image_path := "%s/p2-%s.png" % [output, style]
	image.save_png(image_path)
	var report := {"style": style, "seed": seed,
		"resolution": [image.get_width(), image.get_height()], "anchor": anchor,
		"roles": roles, "scenery": world.scenery.objects.duplicate(true),
		"depth_order": main.agent_renderer.scene_batch._last_order.duplicate(),
		"screenshot": image_path}
	var file := FileAccess.open("%s/p2-%s.json" % [output, style], FileAccess.WRITE)
	file.store_string(JSON.stringify(report, "\t"))
	file.close()
	print("P2_VISUAL=" + JSON.stringify(report))
