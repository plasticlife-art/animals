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
	return a.depth < b.depth or (a.depth == b.depth and a.id < b.id)

func refresh_static(world, view: Rect2, visuals: Dictionary) -> void:
	if last_view == view and scenery_source == world.scenery:
		return
	last_view = view
	scenery_source = world.scenery
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
	var reach := size.y * scale * 2.0
	for entry in world.scenery.query_rect(view.grow(reach)):
		var drawn_size: Vector2 = size * scale * float(entry.scale)
		var screen := WorldProjection.to_screen(entry.position, int(entry.level))
		var slot := int(entry.slot)
		static_entries.append({"depth": WorldProjection.depth_sort_key(entry.position, int(entry.level)),
			"id": -int(entry.id), "transform": Transform2D(Vector2(drawn_size.x, 0), Vector2(0, drawn_size.y), screen - Vector2(0, drawn_size.y * 0.5)),
			"color": Color.WHITE, "uv": uv_rect("props", Vector2(slot % columns, int(slot / columns)), size)})
	static_entries.sort_custom(depth_less)

func render(renderer, alpha: float) -> void:
	var world = renderer.simulation_manager.world_state
	var visuals: Dictionary = renderer.simulation_manager.config_bundle.get("visuals", {})
	refresh_static(world, renderer._get_visible_world_rect(world.bounds), visuals)
	var dynamic: Array = []
	for species in renderer._batches:
		var batch: Dictionary = renderer._batches[species]
		var source: MultiMesh = batch.multimesh
		var agents: Array = batch.get("agents", [])
		var pixels: float = float(visuals.species[species].get("frame_px", 32))
		for i in agents.size():
			var agent = agents[i]
			if not agent.is_alive:
				continue
			var point: Vector2 = renderer._curve_position(agent, alpha)
			var frame := source.get_instance_custom_data(i)
			var transform := source.get_instance_transform_2d(i)
			transform.x *= source.mesh.size.x
			transform.y *= source.mesh.size.y
			dynamic.append({"depth": renderer._depth_of(point), "id": agent.id,
				"transform": transform, "color": source.get_instance_color(i),
				"uv": uv_rect(species, Vector2(frame.r, frame.g), Vector2.ONE * pixels)})
	if regions.has("carcass"):
		var config: Dictionary = visuals.carcass
		var pixels: float = float(config.get("frame_px", 32))
		var size: Vector2 = Vector2.ONE * pixels * float(config.get("sprite_scale", 1.0)) * renderer._world_scale()
		for carcass in world.carcasses.values():
			if not last_view.grow(size.y).has_point(carcass.position):
				continue
			var stages := int(config.get("stages", 3))
			var fraction := float(carcass.meat_remaining) / maxf(0.001, float(carcass.meat_total))
			var stage := clampi(int((1.0 - fraction) * stages), 0, stages - 1)
			dynamic.append({"depth": renderer._depth_of(carcass.position), "id": 100000000 + int(carcass.id),
				"transform": Transform2D(Vector2(size.x, 0), Vector2(0, size.y), renderer._anchor(carcass.position, renderer._ground_offset(config))),
				"color": Color.WHITE, "uv": uv_rect("carcass", Vector2(stage, 0), Vector2.ONE * pixels)})
	dynamic.sort_custom(depth_less)
	var count := static_entries.size() + dynamic.size()
	if multimesh.instance_count < count:
		multimesh.instance_count = count + 256
		_last_order.clear()
	var previous_count := _last_order.size()
	_last_order.resize(count)
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
	multimesh.visible_instance_count = count
	_static_changed = false
