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
	for layer in [_biome_layer, _obstacle_layer, _iso_layer]:
		if layer != null:
			remove_child(layer)
			layer.queue_free()
	_biome_layer = null
	_obstacle_layer = null
	_iso_layer = null
	_build_layers()
	rebuild()


## Repaint from the current terrain. Terrain is generated once per world, so
## this only needs calling on bind and after a restart builds a new world.
func rebuild() -> void:
	if simulation_manager == null or simulation_manager.world_state == null:
		return
	var started := Time.get_ticks_usec()
	var terrain: TerrainSystem = simulation_manager.world_state.terrain_system
	if terrain == null:
		return
	if _iso_layer != null:
		_rebuild_isometric(terrain)
	elif _biome_layer != null:
		_rebuild_orthogonal(terrain)
	# Scenery is rendered by the common scene sprite batch.
	simulation_manager.record_render_phase("terrain",
		float(Time.get_ticks_usec() - started) / 1000.0)


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


## Deterministic per-cell noise, used to pick terrain tile variants. Deliberately
## not `world.rng`: decoration must never be able to shift the simulation's
## random stream.
func _cell_hash(index: int) -> int:
	var value: int = index * 374761393 + 668265263
	value = (value ^ (value >> 13)) * 1274126177
	return absi(value ^ (value >> 16))


func _build_layers() -> void:
	var visuals: Dictionary = {}
	if simulation_manager != null:
		visuals = simulation_manager.config_bundle.get("visuals", {})
	var terrain_config: Dictionary = visuals.get("terrain", {})
	if WorldProjection.is_identity():
		_build_orthogonal_layers(visuals, terrain_config)
	else:
		_build_isometric_layer(visuals, terrain_config)
	# Shared scene batch owns props, so they interleave with animals.


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

	# The art hangs below its top face, so the region is drawn lower until the
	# diamond sits on the cell. One alternative per elevation level then raises it
	# by one skirt step, which is how height reaches the screen at all.
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
			# A tile is drawn at its cell minus `texture_origin`: a negative y moves the
			# art down, a positive one up. The sign was once the other way round, which
			# sank high ground instead of raising it and hid every skirt behind the
			# cells in front.
			for level in range(1, max_level + 1):
				var alternative := source.create_alternative_tile(coords, level)
				source.get_tile_data(coords, alternative).texture_origin = Vector2i(
					0, -base_lift + level * _iso_level_lift)

	# The diamond a cell projects to is twice the cell wide and one cell tall, so
	# the art only sits on the grid unscaled while the world uses 32-unit cells.
	# Deriving the scale keeps larger cells - the cheap way to grow the map -
	# working instead of silently drifting off the grid.
	var iso_scale: float = iso_art_scale(visuals, _cell_size())
	_iso_layer = _make_layer(tile_set, iso_scale, BIOME_LAYER_Z, true)
	# Godot anchors isometric cell (0,0) half a tile to the right of where
	# WorldProjection puts it, a constant offset for every cell. Shifting the
	# layer once keeps tiles, sprites and overlays on the same grid.
	_iso_layer.position = Vector2(-_cell_size(), 0.0)


## How much the isometric tile art is enlarged to fit a terrain cell. A diamond is twice
## the cell wide on screen, so 32-unit cells show the art unscaled and 96-unit cells at
## three times. `WorldProjection` scales `level_height_px` by the same factor: the skirts
## in the art are drawn one step per level, and a sprite has to rise exactly as far as
## the ground under it.
static func iso_art_scale(visuals: Dictionary, cell_size: float) -> float:
	var terrain_config: Dictionary = visuals.get("terrain", {})
	var tile_size = terrain_config.get("iso_tile_size", [64, 32])
	var tile_width := 64.0
	if tile_size is Array and tile_size.size() >= 1:
		tile_width = maxf(1.0, float(tile_size[0]))
	return cell_size * 2.0 / tile_width


## The y-sorted layer the isometric ground is drawn in, or null in the top-down view.
## `GroundTraces` puts its rows in it so that ground in front covers them.
func get_iso_layer() -> TileMapLayer:
	return _iso_layer


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
