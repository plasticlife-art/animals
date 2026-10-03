class_name SceneSpriteBatch
extends MultiMeshInstance2D

## A runtime-packed atlas permits exact painter ordering across every texture.
## Scenery records are static; moving sprites are merged into that sorted list.
var _last_order: Array[int] = []
var _static_changed: bool = true
var regions: Dictionary = {}
var static_entries: Array = []
var atlas_size := Vector2.ONE
var last_view := Rect2()
var scenery_source = null
var owner_renderer = null
var last_counts: Dictionary = {}
var _last_generation: int = -1
var _last_overview: bool = false
var _dynamic_slots: Array = []
## Slots of the dying sprites (`AgentSpriteRenderer.transient_sprites()`), rewritten every
## frame like `_dynamic_slots`: they move and change frame between two order rebuilds.
var _transient_slots: Array = []
var _last_dynamic_signature := PackedInt64Array()
var _last_depth_tick: int = -9999

func configure(renderer, visuals: Dictionary) -> void:
	owner_renderer = renderer
	var sources: Dictionary = {}
	for key in visuals.get("species", {}):
		sources[key] = visuals.species[key]
	sources["carcass"] = visuals.get("carcass", {})
	sources["props"] = visuals.get("props", {})
	var images: Dictionary = {}
	var width := 1
	var height := 0
	for key in sources:
		var tex: Texture2D = load(str(sources[key].get("atlas", "")))
		if tex == null:
			continue
		var source := tex.get_image()
		source.convert(Image.FORMAT_RGBA8)
		images[key] = source
		regions[key] = Rect2(Vector2(0, height), source.get_size())
		width = maxi(width, source.get_width())
		height += source.get_height() + 2
	var packed := Image.create(width, maxi(1, height), false, Image.FORMAT_RGBA8)
	packed.fill(Color.TRANSPARENT)
	for key in images:
		packed.blit_rect(images[key], Rect2i(Vector2i.ZERO, images[key].get_size()), Vector2i(regions[key].position))
	atlas_size = Vector2(width, maxi(1, height))
	texture = ImageTexture.create_from_image(packed)
	var quad := QuadMesh.new()
	quad.size = Vector2.ONE
	multimesh = MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_2D
	multimesh.use_colors = true
	multimesh.use_custom_data = true
	multimesh.mesh = quad
	var mat := ShaderMaterial.new()
	mat.shader = preload("res://shaders/scene_atlas.gdshader")
	material = mat
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	z_index = 0

func uv_rect(key: String, frame: Vector2, frame_size: Vector2) -> Color:
	var region: Rect2 = regions[key]
	var offset := (region.position + frame * frame_size) / atlas_size
	var extent := frame_size / atlas_size
	return Color(offset.x, offset.y, extent.x, extent.y)

static func depth_less(a: Dictionary, b: Dictionary) -> bool:
	if a.depth != b.depth:
		return a.depth < b.depth
	var a_tie := int(a.get("depth_tie", 1))
	var b_tie := int(b.get("depth_tie", 1))
	return a_tie < b_tie or (a_tie == b_tie and a.id < b.id)


static func quantize_view(view: Rect2, step: float) -> Rect2:
	step = maxf(1.0, step)
	var quantized_start := (view.position / step).floor() * step
	var quantized_end := (view.end / step).ceil() * step
	return Rect2(quantized_start, quantized_end - quantized_start)


static func scenery_visible(entry: Dictionary, overview: bool, overview_config: Dictionary) -> bool:
	if not overview:
		return true
	var kind := str(entry.get("kind", ""))
	if overview_config.get("hide_groups", []).has(kind):
		return false
	if overview_config.get("thin_groups", []).has(kind):
		var keep_percent := clampi(int(round(float(overview_config.get("bush_keep_fraction", 0.35)) * 100.0)), 0, 100)
		return posmod(int(entry.get("id", 0)) * 37, 100) < keep_percent
	return true


## The scene batch entry of a dying sprite, from its `DyingSprites` state: the species'
## own atlas row and quad, scaled and mirrored like the living animal it was.
func transient_entry(renderer, state: Dictionary, visuals: Dictionary) -> Dictionary:
	var species := str(state.get("species", ""))
	var batch: Dictionary = renderer._batches.get(species, {})
	if batch.is_empty() or not regions.has(species):
		return {}
	var pixels: float = float(visuals.get("species", {}).get(species, {}).get("frame_px", 32))
	var position: Vector2 = state["position"]
	return {"depth": renderer._depth_of(position), "id": int(state["key"]), "depth_tie": 1,
		"transform": transient_transform(renderer, state, batch.multimesh.mesh.size),
		"color": Color(1.0, 1.0, 1.0, float(state["alpha"])),
		"uv": uv_rect(species, Vector2(float(state["frame"]), float(state["row"])), Vector2.ONE * pixels),
		"transient": true, "pixels": pixels}


static func transient_transform(renderer, state: Dictionary, mesh_size: Vector2) -> Transform2D:
	var scale := float(state["scale"])
	return Transform2D(Vector2(float(state["facing"]) * scale * mesh_size.x, 0.0),
		Vector2(0.0, scale * mesh_size.y),
		renderer._anchor(state["position"], float(state["ground_offset"]) * scale))


static func needs_order_rebuild(last_generation: int, generation: int, static_changed: bool) -> bool:
	return static_changed or last_generation != generation


static func overview_order_rebuild_due(last_tick: int, current_tick: int,
		interval_ticks: int, membership_changed: bool) -> bool:
	return membership_changed or current_tick - last_tick >= maxi(1, interval_ticks)


func _dynamic_membership_signature(renderer, world) -> PackedInt64Array:
	var count := 0
	var id_sum := 0
	var id_xor := 0
	for species in renderer._batches:
		for agent in renderer._batches[species].get("agents", []):
			if agent == null or not agent.is_alive:
				continue
			var entry_id := int(agent.id)
			count += 1
			id_sum += entry_id
			id_xor ^= entry_id
	if renderer.overview_mode:
		for sector in world._sector_states.values():
			if not bool(sector.get("dormant", false)):
				continue
			for aggregate in sector.get("dormant_aggregates", []):
				for id_value in aggregate.get("record_ids", []):
					var entry_id := int(id_value)
					count += 1
					id_sum += entry_id
					id_xor ^= entry_id
	for carcass_id_value in world.carcasses.keys():
		var entry_id := 100000000 + int(carcass_id_value)
		count += 1
		id_sum += entry_id
		id_xor ^= entry_id
	return PackedInt64Array([count, id_sum, id_xor])


## Where a sleeping animal stands. The coarse step keeps each record's real position
## and the worker ships it beside the id, so the overview shows the herd's actual
## formation. Only an aggregate saved before `record_positions` existed falls back to
## its centre, until its sector's next coarse step fills them in.
static func dormant_member_position(aggregate: Dictionary, index: int) -> Vector2:
	var positions: PackedVector2Array = aggregate.get("record_positions", PackedVector2Array())
	if index < positions.size():
		return positions[index]
	return aggregate.get("center", Vector2.ZERO)


func refresh_static(world, view: Rect2, visuals: Dictionary) -> void:
	var reach_config: Dictionary = visuals.get("props", {})
	var reach_cell: Array = reach_config.get("cell_px", [52, 66])
	var reach_scale: float = float(reach_config.get("scale", 0.8)) * world.terrain_system.cell_size / 32.0
	var reach := float(reach_cell[1]) * reach_scale * 2.0
	var requested := view.grow(reach)
	var quantized := quantize_view(requested, world.scenery.bucket_size)
	var overview: bool = owner_renderer.overview_mode
	if last_view == quantized and scenery_source == world.scenery and _last_overview == overview:
		return
	last_view = quantized
	scenery_source = world.scenery
	_last_overview = overview
	_static_changed = true
	static_entries.clear()
	if not regions.has("props"):
		return
	var props: Dictionary = visuals.get("props", {})
	var cell: Array = props.get("cell_px", [52, 66])
	var size := Vector2(cell[0], cell[1])
	var scale: float = float(props.get("scale", 0.8)) * world.terrain_system.cell_size / 32.0
	var columns := maxi(1, int(props.get("columns", 8)))
	# Extend by the tallest canopy, including the large-tree per-kind scale.
	var overview_config: Dictionary = visuals.get("overview_lod", {})
	for entry in world.scenery.query_rect(quantized):
		if not scenery_visible(entry, overview, overview_config):
			continue
		var drawn_size: Vector2 = size * scale * float(entry.scale)
		var screen := WorldProjection.to_screen(entry.position, int(entry.level))
		var slot := int(entry.slot)
		static_entries.append({"depth": WorldProjection.depth_sort_key(entry.position, int(entry.level)),
			# At an identical base point the prop paints over an animal. This is
			# visible for passable bushes and makes standing inside cover read as
			# cover rather than as an animal pasted on top of the foliage.
			"id": -int(entry.id), "depth_tie": 2,
			"transform": Transform2D(Vector2(drawn_size.x, 0), Vector2(0, drawn_size.y), screen - Vector2(0, drawn_size.y * 0.5)),
			"color": Color.WHITE, "uv": uv_rect("props", Vector2(slot % columns, int(slot / columns)), size)})
	static_entries.sort_custom(depth_less)

func render(renderer, alpha: float) -> void:
	var world = renderer.simulation_manager.world_state
	var visuals: Dictionary = renderer.simulation_manager.config_bundle.get("visuals", {})
	var static_started := Time.get_ticks_usec()
	refresh_static(world, renderer._get_visible_world_rect(world.bounds), visuals)
	renderer.simulation_manager.record_render_phase("static_culling",
		float(Time.get_ticks_usec() - static_started) / 1000.0)
	var needs_rebuild := needs_order_rebuild(
		_last_generation, renderer.render_generation, _static_changed)
	var dynamic_signature := PackedInt64Array()
	if needs_rebuild and renderer.overview_mode and not _static_changed:
		dynamic_signature = _dynamic_membership_signature(renderer, world)
		var interval := int(visuals.get("overview_lod", {}).get(
			"depth_order_interval_ticks", 6))
		needs_rebuild = overview_order_rebuild_due(_last_depth_tick,
			renderer.simulation_manager.current_tick, interval,
			dynamic_signature != _last_dynamic_signature)
	if not needs_rebuild:
		_last_generation = renderer.render_generation
		var write_started := Time.get_ticks_usec()
		_update_dynamic(renderer)
		renderer.simulation_manager.record_render_phase("multimesh_write",
			float(Time.get_ticks_usec() - write_started) / 1000.0)
		return
	_last_generation = renderer.render_generation
	if renderer.overview_mode:
		if dynamic_signature.is_empty():
			dynamic_signature = _dynamic_membership_signature(renderer, world)
		_last_dynamic_signature = dynamic_signature
		_last_depth_tick = renderer.simulation_manager.current_tick
	else:
		_last_dynamic_signature = PackedInt64Array()
	var order_started := Time.get_ticks_usec()
	var dynamic: Array = []
	var visible_carcasses := 0
	var visible_active_animals := 0
	var visible_dormant_animals := 0
	for species in renderer._batches:
		var batch: Dictionary = renderer._batches[species]
		var agents: Array = batch.get("agents", [])
		var transforms: Array = batch.get("scene_transforms", [])
		var frames: Array = batch.get("scene_frames", [])
		var colors: Array = batch.get("scene_colors", [])
		var pixels: float = float(visuals.species[species].get("frame_px", 32))
		for i in agents.size():
			var agent = agents[i]
			if not agent.is_alive or i >= transforms.size():
				continue
			visible_active_animals += 1
			var point: Vector2 = renderer._curve_position(agent, alpha)
			var frame: Vector2 = frames[i]
			var transform: Transform2D = transforms[i]
			var mesh_size: Vector2 = batch.multimesh.mesh.size
			transform.x *= mesh_size.x
			transform.y *= mesh_size.y
			dynamic.append({"depth": renderer._depth_of(point), "id": agent.id, "depth_tie": 1,
				"transform": transform, "color": colors[i],
				"uv": uv_rect(species, frame, Vector2.ONE * pixels),
				"species": species, "source_index": i, "pixels": pixels})
	var visible_transient := 0
	for state in renderer.transient_sprites():
		var entry := transient_entry(renderer, state, visuals)
		if not entry.is_empty():
			dynamic.append(entry)
			visible_transient += 1
	if renderer.overview_mode:
		for sector_key in world._sector_states:
			var sector: Dictionary = world._sector_states[sector_key]
			if not bool(sector.get("dormant", false)):
				continue
			for aggregate in sector.get("dormant_aggregates", []):
				var species := str(aggregate.get("species_type", ""))
				if not regions.has(species) or not visuals.get("species", {}).has(species):
					continue
				var config: Dictionary = visuals.species[species]
				var pixels: float = float(config.get("frame_px", 32))
				var sprite_size: Vector2 = Vector2.ONE * pixels * float(config.get("sprite_scale", 1.0)) * renderer._world_scale()
				var idle_row: float = float(config.get("animations", {}).get("idle", {}).get("row", 0))
				var record_ids: Array = aggregate.get("record_ids", [])
				for member_index in range(record_ids.size()):
					var agent_id := int(record_ids[member_index])
					var point := dormant_member_position(aggregate, member_index)
					if not last_view.grow(sprite_size.y).has_point(point):
						continue
					dynamic.append({"depth": renderer._depth_of(point), "id": agent_id, "depth_tie": 1,
						"transform": Transform2D(Vector2(sprite_size.x, 0), Vector2(0, sprite_size.y),
							renderer._anchor(point, renderer._ground_offset(config))),
						"color": Color.WHITE,
						"uv": uv_rect(species, Vector2(0.0, idle_row), Vector2.ONE * pixels)})
					visible_dormant_animals += 1
	if regions.has("carcass"):
		var config: Dictionary = visuals.carcass
		var pixels: float = float(config.get("frame_px", 32))
		var size: Vector2 = Vector2.ONE * pixels * float(config.get("sprite_scale", 1.0)) * renderer._world_scale()
		for carcass in world.carcasses.values():
			if not last_view.grow(size.y).has_point(carcass.position):
				continue
			# The animal is still being shown falling where this body will lie.
			if renderer.hides_carcass(int(carcass.get("source_agent_id", -1))):
				continue
			var stages := int(config.get("stages", 3))
			var fraction := float(carcass.meat_remaining) / maxf(0.001, float(carcass.meat_total))
			var stage := clampi(int((1.0 - fraction) * stages), 0, stages - 1)
			dynamic.append({"depth": renderer._depth_of(carcass.position), "id": 100000000 + int(carcass.id),
				"depth_tie": 0,
				"transform": Transform2D(Vector2(size.x, 0), Vector2(0, size.y), renderer._anchor(carcass.position, renderer._ground_offset(config))),
				"color": Color.WHITE, "uv": uv_rect("carcass", Vector2(stage, 0), Vector2.ONE * pixels)})
			visible_carcasses += 1
	dynamic.sort_custom(depth_less)
	renderer.simulation_manager.record_render_phase("depth_order",
		float(Time.get_ticks_usec() - order_started) / 1000.0)
	var write_started := Time.get_ticks_usec()
	var count := static_entries.size() + dynamic.size()
	if multimesh.instance_count < count:
		multimesh.instance_count = count + 256
		_last_order.clear()
	var previous_count := _last_order.size()
	_last_order.resize(count)
	_dynamic_slots.clear()
	_transient_slots.clear()
	var s := 0
	var d := 0
	for i in count:
		var entry: Dictionary
		if s < static_entries.size() and (d >= dynamic.size() or depth_less(static_entries[s], dynamic[d])):
			entry = static_entries[s]
			s += 1
		else:
			entry = dynamic[d]
			d += 1
		if entry.id < 0 and not _static_changed and i < previous_count and _last_order[i] == entry.id:
			continue
		_last_order[i] = entry.id
		multimesh.set_instance_transform_2d(i, entry.transform)
		multimesh.set_instance_color(i, entry.color)
		multimesh.set_instance_custom_data(i, entry.uv)
		if entry.has("species"):
			_dynamic_slots.append({"slot": i, "id": int(entry.id),
				"species": str(entry.species), "source_index": int(entry.source_index),
				"pixels": float(entry.pixels)})
		elif entry.has("transient"):
			_transient_slots.append({"slot": i, "key": int(entry.id), "pixels": float(entry.pixels)})
	multimesh.visible_instance_count = count
	_static_changed = false
	last_counts = {"visible_scenery": static_entries.size(),
		"visible_scene_dynamic": dynamic.size(), "visible_carcasses": visible_carcasses,
		"visible_animals": visible_active_animals + visible_dormant_animals,
		"visible_dormant_animals": visible_dormant_animals,
		"visible_transient": visible_transient,
		"multimesh_writes": count,
		"order_rebuilt": true}
	renderer.simulation_manager.record_render_phase("multimesh_write",
		float(Time.get_ticks_usec() - write_started) / 1000.0)


func _update_dynamic(renderer) -> void:
	var writes := 0
	for source in _dynamic_slots:
		var batch: Dictionary = renderer._batches.get(source.species, {})
		if batch.is_empty():
			continue
		var index := int(source.source_index)
		var agents: Array = batch.get("agents", [])
		var transforms: Array = batch.get("scene_transforms", [])
		var frames: Array = batch.get("scene_frames", [])
		var colors: Array = batch.get("scene_colors", [])
		if index >= agents.size() or index >= transforms.size() or int(agents[index].id) != int(source.id):
			continue
		var transform: Transform2D = transforms[index]
		var mesh_size: Vector2 = batch.multimesh.mesh.size
		transform.x *= mesh_size.x
		transform.y *= mesh_size.y
		var slot := int(source.slot)
		multimesh.set_instance_transform_2d(slot, transform)
		if not renderer.overview_mode or bool(renderer.simulation_manager.debug_flags.get(
			"show_lod_overlay", false)):
			multimesh.set_instance_color(slot, colors[index])
		if not renderer.overview_mode:
			multimesh.set_instance_custom_data(slot, uv_rect(source.species,
				frames[index], Vector2.ONE * float(source.pixels)))
		writes += 1
	for source in _transient_slots:
		var slot := int(source.slot)
		var state: Dictionary = renderer.transient_sprite(int(source.key))
		if state.is_empty():
			# Finished since the last order rebuild; the next one drops the slot.
			multimesh.set_instance_color(slot, Color.TRANSPARENT)
			writes += 1
			continue
		var species := str(state.get("species", ""))
		var batch: Dictionary = renderer._batches.get(species, {})
		if batch.is_empty():
			continue
		multimesh.set_instance_transform_2d(slot, transient_transform(renderer, state, batch.multimesh.mesh.size))
		multimesh.set_instance_color(slot, Color(1.0, 1.0, 1.0, float(state["alpha"])))
		multimesh.set_instance_custom_data(slot, uv_rect(species,
			Vector2(float(state["frame"]), float(state["row"])), Vector2.ONE * float(source.pixels)))
		writes += 1
	last_counts["multimesh_writes"] = writes
	last_counts["order_rebuilt"] = false
