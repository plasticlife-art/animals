class_name TerrainTileRenderer
extends Node2D

## Draws the terrain grid as tiles, in whichever projection is active.
##
## Replaces the per-cell `draw_rect` loop that used to live in
## `world_view.gd::_draw_terrain_background()`. That loop reissued thousands of
## draw commands on every refresh; a TileMapLayer hands the grid to the engine
## once and lets it handle culling.
##
## `TerrainSystem` stays the source of truth. This node only reads from it, and
## the simulation never reads back from here. Tile sets are built at runtime
## from `data/config/visuals.json` rather than a `.tres`, so swapping the art
## pack is a change to that manifest and the PNG next to it - no resource to
## keep in sync.
##
## Two layouts:
##
## - Orthogonal: two layers, biomes below obstacles, square tiles.
## - Isometric: one y-sorted layer of diamonds. Elevation is carried by the tile
##   art rather than by the layer transform - each cell picks an alternative
##   whose `texture_origin` lifts it by its height, and whose skirt is as deep
##   as the drop to the neighbours in front of it. One y-sorted layer rather
##   than a layer per level is deliberate: with separate layers a low cell in
##   front could never draw over a high cell behind it.

const BIOME_LAYER_Z := 0
const PROP_Z := 2
const OBSTACLE_LAYER_Z := 1

var simulation_manager: SimulationManager

var _biome_layer: TileMapLayer
var _obstacle_layer: TileMapLayer
var _iso_layer: TileMapLayer
var _source_id: int = -1
var _biome_coords: Dictionary = {}
var _obstacle_coords: Dictionary = {}
var _iso_rows: Dictionary = {}
var _iso_skirt_levels: int = 4
var _iso_level_lift: int = 16
var _props: MultiMeshInstance2D = null
var _subdivisions: int = 1
var _variants: int = 1


func bind_manager(manager: SimulationManager) -> void:
	simulation_manager = manager
	_build_layers()
	rebuild()


## Discard the tile set and build it again from the current visuals.
##
## `rebuild()` only repaints cells onto the existing `TileSet`. A style preset
## changes the atlas, the tile size and whether the grid is square or diamond,
## none of which repainting can express, so the layers themselves are replaced.
func rebuild_layers() -> void:
	for layer in [_biome_layer, _obstacle_layer, _iso_layer, _props]:
		if layer != null:
			remove_child(layer)
			layer.queue_free()
	_biome_layer = null
	_obstacle_layer = null
	_iso_layer = null
	_props = null
	_build_layers()
	rebuild()


## Repaint from the current terrain. Terrain is generated once per world, so
## this only needs calling on bind and after a restart builds a new world.
func rebuild() -> void:
	if simulation_manager == null or simulation_manager.world_state == null:
		return
	var terrain: TerrainSystem = simulation_manager.world_state.terrain_system
	if terrain == null:
		return
	if _iso_layer != null:
		_rebuild_isometric(terrain)
	elif _biome_layer != null:
		_rebuild_orthogonal(terrain)
	_rebuild_props(terrain)


func _rebuild_orthogonal(terrain: TerrainSystem) -> void:
	_biome_layer.clear()
	_obstacle_layer.clear()
	var cols: int = terrain.cols
	for index in range(terrain.get_cell_count()):
		@warning_ignore("integer_division")
		var origin := Vector2i(index % cols, index / cols) * _subdivisions
		var biome_id: String = terrain.get_biome_at_index(index)
		var obstacle_id: String = terrain.get_obstacle_at_index(index)
		var has_biome: bool = _biome_coords.has(biome_id)
		var has_obstacle: bool = obstacle_id != "" and _obstacle_coords.has(obstacle_id)
		if not has_biome and not has_obstacle:
			continue
		for dy in range(_subdivisions):
			for dx in range(_subdivisions):
				var sub := origin + Vector2i(dx, dy)
				# Each subtile picks its own variant row, so a cell drawn as a
				# block of identical stamps does not read as graph paper.
				var variant: int = _cell_hash(index * 31 + dy * 7 + dx) % _variants
				if has_biome:
					var base: Vector2i = _biome_coords[biome_id]
					_biome_layer.set_cell(sub, _source_id, Vector2i(base.x, variant))
				if has_obstacle:
					var over: Vector2i = _obstacle_coords[obstacle_id]
					_obstacle_layer.set_cell(sub, _source_id, Vector2i(over.x, variant))


func _rebuild_isometric(terrain: TerrainSystem) -> void:
	_iso_layer.clear()
	var cols: int = terrain.cols
	var rows: int = terrain.rows
	for index in range(terrain.get_cell_count()):
		@warning_ignore("integer_division")
		var coords := Vector2i(index % cols, index / cols)
		var surface: String = terrain.get_obstacle_at_index(index)
		if surface == "":
			surface = terrain.get_biome_at_index(index)
		if not _iso_rows.has(surface):
			continue
		var level: int = terrain.get_height_at_index(index)
		# The two visible faces drop independently: a cell can be a step above
		# its +x neighbour while flush with its +y one. Picking one depth for
		# both drew a wall on flat ground for about a quarter of the map.
		var right_drop := 0
		var left_drop := 0
		if coords.x + 1 < cols:
			right_drop = maxi(0, level - terrain.get_height_at_index(index + 1))
		if coords.y + 1 < rows:
			left_drop = maxi(0, level - terrain.get_height_at_index(index + cols))
		right_drop = clampi(right_drop, 0, _iso_skirt_levels - 1)
		left_drop = clampi(left_drop, 0, _iso_skirt_levels - 1)
		var column: int = left_drop * _iso_skirt_levels + right_drop
		_iso_layer.set_cell(coords, _source_id, Vector2i(column, int(_iso_rows[surface])), level)


## Scenery: trees, bushes, tufts and stones scattered over the terrain.
##
## Static, so it is written once per world rather than per frame. Placement is
## derived from the cell index by a plain integer hash, not from the world RNG -
## decoration must never be able to shift the simulation's random stream.
##
## Obstacle cells are always dressed. That is the point of the layer: a cell the
## simulation refuses to walk through should look like a thicket or a boulder
## field, not like open ground.
func _rebuild_props(terrain: TerrainSystem) -> void:
	if _props == null:
		return
	var visuals: Dictionary = simulation_manager.config_bundle.get("visuals", {})
	var config: Dictionary = visuals.get("props", {})
	var groups: Dictionary = config.get("groups", {})
	var obstacle_rules: Dictionary = config.get("obstacles", {})
	var biome_rules: Dictionary = config.get("biomes", {})
	var columns: int = maxi(1, int(config.get("columns", 8)))
	var group_scale: Dictionary = config.get("group_scale", {})

	var placements: Array = []
	var cols: int = terrain.cols
	for index in range(terrain.get_cell_count()):
		var noise: int = _cell_hash(index)
		var slots: Array = []
		var chance: float = 0.0
		var group_name: String = ""
		var obstacle_id: String = terrain.get_obstacle_at_index(index)
		if obstacle_id != "" and obstacle_rules.has(obstacle_id):
			var rule: Dictionary = obstacle_rules[obstacle_id]
			group_name = str(rule.get("group", ""))
			slots = groups.get(group_name, [])
			chance = float(rule.get("chance", 0.0))
		elif terrain.is_walkable_index(index):
			var biome_id: String = terrain.get_biome_at_index(index)
			if biome_rules.has(biome_id):
				var rule2: Dictionary = biome_rules[biome_id]
				var names: Array = rule2.get("groups", [])
				group_name = str(names[_cell_hash(index + 17) % maxi(1, names.size())]) if not names.is_empty() else ""
				slots = groups.get(group_name, [])
				chance = float(rule2.get("chance", 0.0))
		if slots.is_empty() or float(noise % 1000) / 1000.0 >= chance:
			continue
		@warning_ignore("integer_division")
		var coords := Vector2i(index % cols, index / cols)
		var centre := Vector2((float(coords.x) + 0.5) * terrain.cell_size,
			(float(coords.y) + 0.5) * terrain.cell_size)
		# Nudged off the exact centre so a field of props does not read as a grid.
		var jitter := Vector2(
			float((noise / 1000) % 100) / 100.0 - 0.5,
			float((noise / 100000) % 100) / 100.0 - 0.5) * terrain.cell_size * 0.45
		placements.append({
			"position": centre + jitter,
			"slot": int(slots[(noise / 7) % slots.size()]),
			"level": terrain.get_height_at_index(index),
			"scale": float(group_scale.get(group_name, 1.0)),
		})

	var multimesh: MultiMesh = _props.multimesh
	if placements.is_empty():
		multimesh.visible_instance_count = 0
		return
	# Drawn back to front: a MultiMesh has no depth sorting of its own.
	placements.sort_custom(func(a, b):
		return WorldProjection.depth_sort_key(a["position"], a["level"]) \
			< WorldProjection.depth_sort_key(b["position"], b["level"]))
	multimesh.instance_count = placements.size()
	var half_height: float = _props.multimesh.mesh.size.y * 0.5
	for i in range(placements.size()):
		var entry: Dictionary = placements[i]
		var point: Vector2 = WorldProjection.to_screen(entry["position"], int(entry["level"]))
		# Scaled about its base, not its centre, so a shrunk prop stays planted
		# on the ground instead of floating above it.
		var factor: float = float(entry["scale"])
		multimesh.set_instance_transform_2d(i, Transform2D(
			Vector2(factor, 0.0), Vector2(0.0, factor),
			point - Vector2(0.0, half_height * factor)))
		# The shader multiplies the sampled texel by the instance colour, and an
		# unset colour is transparent black - which draws nothing at all.
		multimesh.set_instance_color(i, Color.WHITE)
		multimesh.set_instance_custom_data(i, Color(
			float(int(entry["slot"]) % columns), float(int(entry["slot"]) / columns), 0.0, 0.0))
	multimesh.visible_instance_count = placements.size()


## Deterministic per-cell noise. Deliberately not `world.rng`: pulling from the
## simulation's stream to decide where a bush goes would make the ecology depend
## on the decoration.
func _cell_hash(index: int) -> int:
	var value: int = index * 374761393 + 668265263
	value = (value ^ (value >> 13)) * 1274126177
	return absi(value ^ (value >> 16))


func _build_props_layer(visuals: Dictionary) -> void:
	var config: Dictionary = visuals.get("props", {})
	if config.is_empty():
		return
	var texture: Texture2D = _load_atlas(config.get("atlas", ""))
	if texture == null:
		return
	var cell: Vector2i = _config_vector(config.get("cell_px", [52, 66]), Vector2i(52, 66))
	var columns: int = maxi(1, int(config.get("columns", 8)))
	var rows: int = maxi(1, int(texture.get_height() / maxi(1, cell.y)))
	var scale_factor: float = float(config.get("scale", 0.8)) * _cell_size() / 32.0

	var quad := QuadMesh.new()
	quad.size = Vector2(float(cell.x), float(cell.y)) * scale_factor

	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_2D
	multimesh.use_colors = true
	multimesh.use_custom_data = true
	multimesh.mesh = quad
	multimesh.instance_count = 0

	var material := ShaderMaterial.new()
	material.shader = preload("res://shaders/agent_atlas.gdshader")
	material.set_shader_parameter("frame_size_uv",
		Vector2(1.0 / float(columns), 1.0 / float(rows)))

	_props = MultiMeshInstance2D.new()
	_props.multimesh = multimesh
	_props.texture = texture
	_props.material = material
	_props.z_index = PROP_Z
	_props.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	add_child(_props)


func _build_layers() -> void:
	var visuals: Dictionary = {}
	if simulation_manager != null:
		visuals = simulation_manager.config_bundle.get("visuals", {})
	var terrain_config: Dictionary = visuals.get("terrain", {})
	if WorldProjection.is_identity():
		_build_orthogonal_layers(visuals, terrain_config)
	else:
		_build_isometric_layer(visuals, terrain_config)
	_build_props_layer(visuals)


func _build_orthogonal_layers(visuals: Dictionary, terrain_config: Dictionary) -> void:
	var texture: Texture2D = _load_atlas(terrain_config.get("atlas", ""))
	if texture == null:
		return
	var tile_px: int = maxi(1, int(visuals.get("tile_px", 32)))
	# One simulation cell may be drawn as a block of tiles. That is what keeps a
	# terrain texel the same size on screen as a sprite texel when the art is
	# finer than the cell; matching those two is what stops the ground from
	# looking blockier than the animals standing on it.
	_subdivisions = maxi(1, int(terrain_config.get("subdivisions", 1)))
	_variants = maxi(1, int(terrain_config.get("variants", 1)))
	var source := TileSetAtlasSource.new()
	source.texture = texture
	source.texture_region_size = Vector2i(tile_px, tile_px)

	# Tiles are created only after the source belongs to a TileSet. A source
	# with no owning tile set silently refuses to build usable tile data, and
	# the resulting layer draws nothing at all without a single error.
	var tile_set := TileSet.new()
	tile_set.tile_size = Vector2i(tile_px, tile_px)
	_source_id = tile_set.add_source(source)

	_biome_coords = _register_tiles(source, terrain_config.get("biomes", {}))
	_obstacle_coords = _register_tiles(source, terrain_config.get("obstacles", {}))

	var layer_scale: float = _cell_size() / float(tile_px * _subdivisions)
	_biome_layer = _make_layer(tile_set, layer_scale, BIOME_LAYER_Z, false)
	_obstacle_layer = _make_layer(tile_set, layer_scale, OBSTACLE_LAYER_Z, false)


func _build_isometric_layer(visuals: Dictionary, terrain_config: Dictionary) -> void:
	var texture: Texture2D = _load_atlas(terrain_config.get("iso_atlas", ""))
	if texture == null:
		return
	var tile_size := _config_vector(terrain_config.get("iso_tile_size", [64, 32]), Vector2i(64, 32))
	var region := _config_vector(terrain_config.get("iso_region_size", [64, 80]), Vector2i(64, 80))
	_iso_skirt_levels = maxi(1, int(terrain_config.get("iso_skirt_levels", 4)))
	_iso_level_lift = int(visuals.get("level_height_px", 16))

	var source := TileSetAtlasSource.new()
	source.texture = texture
	source.texture_region_size = region

	# Same rule as above: the source joins the tile set before any tile or
	# alternative is created on it.
	var tile_set := TileSet.new()
	tile_set.tile_shape = TileSet.TILE_SHAPE_ISOMETRIC
	# DIAMOND_DOWN, not DIAMOND_RIGHT: measured, its cell steps are (32,16) and
	# (-32,16), which is exactly what WorldProjection produces. DIAMOND_RIGHT is
	# the mirrored convention and puts the grid on a different axis pair.
	tile_set.tile_layout = TileSet.TILE_LAYOUT_DIAMOND_DOWN
	tile_set.tile_size = tile_size
	_source_id = tile_set.add_source(source)

	_iso_rows = {}
	for group_key in ["biomes", "obstacles"]:
		var entries: Dictionary = terrain_config.get(group_key, {})
		for entry_id in entries.keys():
			_iso_rows[str(entry_id)] = int(entries[entry_id].get("iso_row", 0))

	# The art hangs below its top face, so the whole region has to be lifted
	# until the diamond sits on the cell. One alternative per elevation level
	# then lifts it further, which is how height reaches the screen at all.
	var max_level: int = 0
	if simulation_manager != null and simulation_manager.world_state != null:
		var terrain: TerrainSystem = simulation_manager.world_state.terrain_system
		if terrain != null:
			max_level = terrain.get_max_height_level()
	# The region is taller than the tile because the skirt hangs below the top
	# face; half that surplus is what lifts the diamond back onto the cell.
	@warning_ignore("integer_division")
	var base_lift: int = (region.y - tile_size.y) / 2
	var row_count: int = 0
	for row_value in _iso_rows.values():
		row_count = maxi(row_count, int(row_value) + 1)
	for row in range(row_count):
		for skirt in range(_iso_skirt_levels * _iso_skirt_levels):
			var coords := Vector2i(skirt, row)
			source.create_tile(coords)
			source.get_tile_data(coords, 0).texture_origin = Vector2i(0, -base_lift)
			for level in range(1, max_level + 1):
				var alternative := source.create_alternative_tile(coords, level)
				source.get_tile_data(coords, alternative).texture_origin = Vector2i(
					0, -base_lift - level * _iso_level_lift)

	# The diamond a cell projects to is twice the cell wide and one cell tall, so
	# the art only sits on the grid unscaled while the world uses 32-unit cells.
	# Deriving the scale keeps larger cells - the cheap way to grow the map -
	# working instead of silently drifting off the grid.
	var iso_scale: float = _cell_size() * 2.0 / float(tile_size.x)
	_iso_layer = _make_layer(tile_set, iso_scale, BIOME_LAYER_Z, true)
	# Godot anchors isometric cell (0,0) half a tile to the right of where
	# WorldProjection puts it, a constant offset for every cell. Shifting the
	# layer once keeps tiles, sprites and overlays on the same grid.
	_iso_layer.position = Vector2(-_cell_size(), 0.0)


func _cell_size() -> float:
	if simulation_manager != null and simulation_manager.world_state != null:
		var terrain: TerrainSystem = simulation_manager.world_state.terrain_system
		if terrain != null:
			return terrain.cell_size
	return 32.0


func _load_atlas(path_value) -> Texture2D:
	var atlas_path := str(path_value)
	if atlas_path == "":
		push_error("Terrain atlas is not configured; terrain tiles disabled")
		return null
	var texture: Texture2D = load(atlas_path)
	if texture == null:
		push_error("Failed to load terrain atlas: %s" % atlas_path)
	return texture


func _config_vector(value, fallback: Vector2i) -> Vector2i:
	if value is Array and value.size() >= 2:
		return Vector2i(int(value[0]), int(value[1]))
	return fallback


func _register_tiles(source: TileSetAtlasSource, entries: Dictionary) -> Dictionary:
	var mapping: Dictionary = {}
	for entry_id in entries.keys():
		var entry: Dictionary = entries[entry_id]
		var raw_coords: Array = entry.get("atlas_coords", [])
		if raw_coords.size() < 2:
			push_error("visuals: %s has no valid atlas_coords" % entry_id)
			continue
		var coords := Vector2i(int(raw_coords[0]), int(raw_coords[1]))
		# Every variant row of this surface needs a tile, not just the one the
		# manifest names: the fill loop picks a row per subtile.
		for variant in range(_variants):
			var variant_coords := Vector2i(coords.x, variant)
			if not source.has_tile(variant_coords):
				source.create_tile(variant_coords)
		mapping[str(entry_id)] = coords
	return mapping


func _make_layer(tile_set: TileSet, layer_scale: float, layer_z: int, y_sorted: bool) -> TileMapLayer:
	var layer := TileMapLayer.new()
	layer.tile_set = tile_set
	layer.scale = Vector2.ONE * layer_scale
	layer.z_index = layer_z
	layer.y_sort_enabled = y_sorted
	layer.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	add_child(layer)
	return layer
