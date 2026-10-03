extends SceneTree

## Deterministic P1 occlusion scene.
## -- style output_directory [seed]
const REQUESTED_RESOLUTION := Vector2i(1600, 900)
const SETTLE_FRAMES := 30

var main = null
var manager = null
var style := "topdown_kenney"
var output := "/private/tmp/animals-p1-visual"
var seed := 1337
var frames := 0
var staged := false
var anchor := Vector2.ZERO
var staged_agents: Array = []


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
	# The audit compares painter order, so keep its ground plane flat in both
	# styles. Otherwise different elevation lifts can make equal simulation
	# depth look like different screen rows and obscure what the scene tests.
	if not WorldProjection.is_identity():
		for index in world.terrain_system.get_cell_count():
			world.terrain_system._heights[index] = 0
		world.terrain_system.height_levels = 1
		WorldProjection.configure(manager.config_bundle.visuals, 0)
		main.terrain_tiles.rebuild()
	anchor = _find_clear_anchor(world)
	var by_species := {"herbivore": [], "predator": [], "scavenger": []}
	for agent in world.get_living_agents():
		agent.position = Vector2(48, 48)
		if by_species.has(agent.species_type) and by_species[agent.species_type].size() < 3:
			by_species[agent.species_type].append(agent)
	var same_depth := [Vector2(-80, 130), Vector2(0, 130), Vector2(80, 130)]
	if not WorldProjection.is_identity():
		# Equal x+y is equal painter depth in the isometric projection. These
		# positions also form one horizontal row on screen, which makes ordering
		# across species and a carcass easy to inspect.
		same_depth = [Vector2(-120, 110), Vector2(0, -10), Vector2(120, -130)]
	var placements := [
		[by_species.herbivore[0], Vector2(-190, -92), "behind_tree"],
		[by_species.predator[0], Vector2(-190, 20), "before_tree"],
		[by_species.scavenger[0], Vector2(0, -40), "inside_bush"],
		[by_species.herbivore[1], same_depth[0], "same_depth_herbivore"],
		[by_species.predator[1], same_depth[1], "same_depth_predator"],
		[by_species.herbivore[2], Vector2(190, -92), "behind_stone"],
	]
	staged_agents.clear()
	for placement in placements:
		var agent = placement[0]
		agent.position = anchor + placement[1]
		agent.velocity = Vector2.ZERO
		agent.direction = Vector2.DOWN
		agent.state = "rest"
		agent.current_action = &"rest"
		staged_agents.append({"id": agent.id, "species": agent.species_type,
			"role": placement[2], "position": agent.position})

	world.scenery.objects.clear()
	world.scenery.buckets.clear()
	world.scenery._point_cache.clear()
	world.scenery._near_cache.clear()
	world.scenery.max_extent = 0.0
	_add_prop(world, 1, "tree_large", anchor + Vector2(-190, -40))
	_add_prop(world, 2, "bush", anchor + Vector2(0, -40))
	_add_prop(world, 3, "stone", anchor + Vector2(190, -40))

	world.carcasses.clear()
	for sector in world._sector_states.values():
		sector["carcass_ids"] = []
	var carcass_position: Vector2 = anchor + same_depth[2]
	world.carcasses[1] = {"id": 1, "position": carcass_position,
		"created_at": world.current_time, "ttl_seconds": 120.0,
		"source_species": "herbivore", "death_cause": "visual_audit",
		"meat_total": 80.0, "meat_remaining": 52.0, "max_feeders": 3,
		"active_feeder_ids": [], "source_agent_id": -1}
	world.next_carcass_id = 2
	world._register_carcass_sector(1, carcass_position)
	world.spatial_grid.rebuild(world.get_living_agents())

	manager.selected_agent_id = -1
	main.debug_panel.visible = false
	main.charts_panel.visible = false
	main.minimap.visible = false
	main.climate_indicator.visible = false
	main.ecology_strip.visible = false
	main.story_feed.visible = false
	main.player_bar.visible = false
	main.pinned_bar.set_allowed(false)
	main.selection_tag.visible = false
	main.selection_card.visible = false
	main.herd_card.set_allowed(false)
	main.agent_renderer.rebuild_batches()
	main.agent_renderer.request_refresh()
	main.world_camera.global_position = WorldProjection.to_screen(anchor,
		world.terrain_system.get_height_at_position(anchor))
	main.world_camera.zoom = Vector2.ONE * (2.0 if WorldProjection.is_identity() else 1.7)


func _find_clear_anchor(world) -> Vector2:
	var offsets := [Vector2(-190, -92), Vector2(-190, 20), Vector2(0, -40),
		Vector2(-80, 130), Vector2(0, 130), Vector2(80, 130),
		Vector2(190, -92), Vector2(190, -40)]
	var center: Vector2 = world.bounds.get_center()
	var terrain = world.terrain_system
	var best: Vector2 = terrain.get_cell_center(terrain.find_nearest_walkable_index(
		terrain.get_index_from_position(center)))
	for ring in range(0, 24):
		for y in range(-ring, ring + 1):
			for x in range(-ring, ring + 1):
				if ring > 0 and abs(x) != ring and abs(y) != ring:
					continue
				var candidate: Vector2 = best + Vector2(x, y) * terrain.cell_size
				var clear := true
				for offset in offsets:
					var point: Vector2 = candidate + offset
					if not world.bounds.grow(-22.0).has_point(point) \
							or not world.scenery.terrain_clear(point, point, 20.0):
						clear = false
						break
				if clear:
					return candidate
	return best


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
		"level": world.terrain_system.get_height_at_position(position)})


func _capture() -> void:
	var image := root.get_texture().get_image()
	var image_path := "%s/p1-%s.png" % [output, style]
	image.save_png(image_path)
	var report := {"style": style, "seed": seed,
		"resolution": [image.get_width(), image.get_height()],
		"anchor": anchor, "agents": staged_agents,
		"scenery": manager.world_state.scenery.objects.duplicate(true),
		"carcass_position": manager.world_state.carcasses[1].position,
		"depth_order": main.agent_renderer.scene_batch._last_order.duplicate(),
		"screenshot": image_path}
	var file := FileAccess.open("%s/p1-%s.json" % [output, style], FileAccess.WRITE)
	file.store_string(JSON.stringify(report, "\t"))
	file.close()
	print("P1_VISUAL=" + JSON.stringify(report))
