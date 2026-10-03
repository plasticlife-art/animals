class_name GroundTraces
extends Node2D

## Shows the marks the ecology leaves on the ground, in the normal view.
##
## Two things, both read from the simulation and neither fed back into it: how much
## grass each cell holds, as a ramp from bare earth through dry straw to a richer green
## - the refuges that fear of predators leaves ungrazed - and paths worn where animals
## keep walking. The grass overlay in the debug panel shows the same numbers as a
## chart; this is the same data as scenery. The ramp used to tint only the two ends,
## below 0.4 of a cell's cap and above 0.62, so ground grazed to half looked untouched.
##
## The grids reach the GPU as float textures built straight from the packed arrays, so
## a refresh costs no loop in script. The mesh is one quad per walkable terrain cell,
## placed through `WorldProjection` with the cell's elevation.
##
## Top-down, it is one mesh drawn above the biome tiles and below obstacles, animals and
## overlays. Isometric, ground in front hides ground behind it, which a single mesh
## drawn after the tiles cannot respect: the tint of a low cell painted over the raised
## cell in front of it. There the quads go into the terrain's own y-sorted layer, one
## mesh per diagonal row of cells, each sorted just after its row's tiles and before
## the next row's, so the tiles in front cover it as they cover the ground.

const GROUND_SHADER := preload("res://shaders/ground_traces.gdshader")

## What `visuals.ground` holds when a key is missing, as in a save made before the key
## existed: the bundle a save carries is the one it was made with. Equal to the
## shader's own defaults.
const GROUND_DEFAULTS := {
	"bare_color": [0.50, 0.38, 0.22, 0.70],
	"dry_color": [0.78, 0.68, 0.34, 0.42],
	"mid_color": [0.48, 0.58, 0.26, 0.10],
	"lush_color": [0.12, 0.40, 0.12, 0.42],
	"grass_stops": [0.08, 0.30, 0.55, 0.92],
	"trail_color": [0.86, 0.79, 0.6, 0.6],
	"trail_range": [80.0, 800.0],
	"noise_size": 40.0,
	"noise_strength": 0.16,
}
const GROUND_COLORS := ["bare_color", "dry_color", "mid_color", "lush_color", "trail_color"]

## Layer-local units a row mesh is sorted after the tiles of its own row. Rows are half
## a tile apart, so this lands between one row and the next.
const ROW_SORT_NUDGE := 1.0

var simulation_manager: SimulationManager
var terrain_tiles: TerrainTileRenderer

var _mesh_instance: MeshInstance2D
var _row_meshes: Array = []
var _material: ShaderMaterial
var _grass_texture: ImageTexture
var _trail_texture: ImageTexture
var _interval_ticks: int = 0


func bind_manager(manager: SimulationManager, tiles: TerrainTileRenderer = null) -> void:
	simulation_manager = manager
	terrain_tiles = tiles
	if not manager.tick_completed.is_connected(_on_tick_completed):
		manager.tick_completed.connect(_on_tick_completed)
	rebuild()


## Builds the mesh and the textures again. Needed whenever the world, the projection
## or the style changes; the per-second refresh only replaces texture contents.
func rebuild() -> void:
	if _mesh_instance != null:
		remove_child(_mesh_instance)
		_mesh_instance.queue_free()
		_mesh_instance = null
	# The rows live in the terrain layer, which a style change may already have freed.
	for row in _row_meshes:
		if is_instance_valid(row):
			row.queue_free()
	_row_meshes.clear()
	_grass_texture = null
	_trail_texture = null
	if simulation_manager == null or simulation_manager.world_state == null:
		return
	_interval_ticks = simulation_manager.ground_update_interval_ticks()
	visible = _interval_ticks > 0
	if not visible:
		return
	var started := Time.get_ticks_usec()
	var world = simulation_manager.world_state
	var config: Dictionary = simulation_manager.config_bundle.get("visuals", {}).get("ground", {})
	_material = ShaderMaterial.new()
	_material.shader = GROUND_SHADER
	_apply_config(config)
	var grass: ResourceSystem = world.resource_system
	var trails: TrailField = world.trail_field
	_material.set_shader_parameter("grass_extent", Vector2(grass.cols, grass.rows) * grass.cell_size)
	_material.set_shader_parameter("trail_extent", Vector2(trails.cols, trails.rows) * trails.cell_size)
	_material.set_shader_parameter("cap_tex", ImageTexture.create_from_image(
		_float_image(grass.export_caps(), grass.cols, grass.rows)))
	var iso_layer: TileMapLayer = null if terrain_tiles == null else terrain_tiles.get_iso_layer()
	if iso_layer != null and not WorldProjection.is_identity():
		_build_rows(world.terrain_system, iso_layer)
	else:
		_mesh_instance = MeshInstance2D.new()
		_mesh_instance.mesh = _build_mesh(world.terrain_system, _all_walkable(world.terrain_system))
		_mesh_instance.material = _material
		add_child(_mesh_instance)
	refresh()
	simulation_manager.record_render_phase("ground_rebuild",
		float(Time.get_ticks_usec() - started) / 1000.0)


## Hands the current grass and trail grids to the GPU.
func refresh() -> void:
	if _material == null or simulation_manager == null or simulation_manager.world_state == null:
		return
	var started := Time.get_ticks_usec()
	var world = simulation_manager.world_state
	var grass: ResourceSystem = world.resource_system
	var trails: TrailField = world.trail_field
	_grass_texture = _upload(_grass_texture, "grass_tex", grass.export_cells(), grass.cols, grass.rows)
	_trail_texture = _upload(_trail_texture, "trail_tex", trails.export_cells(), trails.cols, trails.rows)
	simulation_manager.record_render_phase("ground",
		float(Time.get_ticks_usec() - started) / 1000.0)


func _on_tick_completed(tick: int, _snapshot) -> void:
	if _interval_ticks > 0 and tick % _interval_ticks == 0:
		refresh()


func _upload(texture: ImageTexture, parameter: String, cells: PackedFloat32Array, cols: int, rows: int) -> ImageTexture:
	var image := _float_image(cells, cols, rows)
	if texture != null and texture.get_width() == cols and texture.get_height() == rows:
		texture.update(image)
		return texture
	texture = ImageTexture.create_from_image(image)
	_material.set_shader_parameter(parameter, texture)
	return texture


static func _float_image(cells: PackedFloat32Array, cols: int, rows: int) -> Image:
	if cells.size() != cols * rows:
		cells = PackedFloat32Array()
		cells.resize(cols * rows)
	return Image.create_from_data(cols, rows, false, Image.FORMAT_RF, cells.to_byte_array())


func _apply_config(config: Dictionary) -> void:
	var ground := resolve_ground_config(config)
	for key in GROUND_COLORS:
		_material.set_shader_parameter(key, ground[key])
	var stops: Array = ground["grass_stops"]
	_material.set_shader_parameter("grass_stops", Vector4(stops[0], stops[1], stops[2], stops[3]))
	var trail_range: Array = ground["trail_range"]
	_material.set_shader_parameter("trail_range", Vector2(trail_range[0], trail_range[1]))
	for key in ["noise_size", "noise_strength"]:
		_material.set_shader_parameter(key, float(ground[key]))


## `visuals.ground` with every key the layer reads, colours as `Color`. A key missing or
## malformed takes its default, so a save made before it existed still draws the ramp.
static func resolve_ground_config(config: Dictionary) -> Dictionary:
	var resolved := {}
	for key in GROUND_DEFAULTS.keys():
		var fallback = GROUND_DEFAULTS[key]
		var value = config.get(key, fallback)
		if fallback is Array and not (value is Array and value.size() >= fallback.size()):
			value = fallback
		if GROUND_COLORS.has(key):
			resolved[key] = Color(value[0], value[1], value[2], value[3])
		elif value is Array:
			resolved[key] = value.duplicate()
		else:
			resolved[key] = float(value)
	return resolved


## The shader's `grass_tint()`: the colour, alpha included, a grass share is drawn with
## before trails go over it. For tests and anything else that has to know; keep the
## two in step.
static func grass_tint(share: float, ground: Dictionary) -> Color:
	var stops: Array = ground["grass_stops"]
	var low: Color = ground["mid_color"]
	var high: Color = ground["lush_color"]
	var t := smoothstep(float(stops[2]), float(stops[3]), share)
	if share <= float(stops[1]):
		low = ground["bare_color"]
		high = ground["dry_color"]
		t = smoothstep(float(stops[0]), float(stops[1]), share)
	elif share <= float(stops[2]):
		low = ground["dry_color"]
		high = ground["mid_color"]
		t = smoothstep(float(stops[1]), float(stops[2]), share)
	var mixed := _premultiplied(low).lerp(_premultiplied(high), t)
	var alpha := maxf(mixed.a, 0.0001)
	return Color(mixed.r / alpha, mixed.g / alpha, mixed.b / alpha, mixed.a)


static func _premultiplied(color: Color) -> Color:
	return Color(color.r * color.a, color.g * color.a, color.b * color.a, color.a)


## One mesh per diagonal row of cells (x + y), each a child of the terrain layer so it
## is y-sorted with the tiles. A row's node sits just after that row's tiles; its
## vertices are laid out in the same space as everything else `WorldProjection` places,
## offset by where the node itself lands, so the layer's scale and shift cancel out.
func _build_rows(terrain: TerrainSystem, iso_layer: TileMapLayer) -> void:
	var rows: Dictionary = {}
	for index in range(terrain.get_cell_count()):
		if not terrain.is_walkable_index(index):
			continue
		var coords: Vector2i = terrain.get_cell_coords(index)
		var row := coords.x + coords.y
		if not rows.has(row):
			rows[row] = PackedInt32Array()
		rows[row].append(index)
	var to_parent: Transform2D = iso_layer.transform
	for row in rows.keys():
		var anchor_local := Vector2(0.0, iso_layer.map_to_local(Vector2i(row, 0)).y + ROW_SORT_NUDGE)
		var anchor := to_parent * anchor_local
		var node := MeshInstance2D.new()
		node.mesh = _build_mesh(terrain, rows[row], anchor)
		node.material = _material
		node.position = anchor_local
		node.scale = Vector2.ONE / iso_layer.scale
		node.set_meta("row", row)
		iso_layer.add_child(node)
		_row_meshes.append(node)


static func _all_walkable(terrain: TerrainSystem) -> PackedInt32Array:
	var cells := PackedInt32Array()
	for index in range(terrain.get_cell_count()):
		if terrain.is_walkable_index(index):
			cells.append(index)
	return cells


## One quad per listed cell, less `origin`. UV holds the world position, which is all
## the shader needs to find its place in either grid.
static func _build_mesh(terrain: TerrainSystem, cells: PackedInt32Array, origin: Vector2 = Vector2.ZERO) -> ArrayMesh:
	var vertices := PackedVector2Array()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()
	for index in cells:
		var rect: Rect2 = terrain.get_cell_rect(index)
		var level: int = terrain.get_height_at_index(index)
		var base := vertices.size()
		for corner in [rect.position, Vector2(rect.end.x, rect.position.y), rect.end, Vector2(rect.position.x, rect.end.y)]:
			vertices.append(WorldProjection.to_screen(corner, level) - origin)
			uvs.append(corner)
		indices.append_array(PackedInt32Array([base, base + 1, base + 2, base, base + 2, base + 3]))
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	if not vertices.is_empty():
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh
