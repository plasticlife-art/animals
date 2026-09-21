class_name GroundTraces
extends Node2D

## Shows the marks the ecology leaves on the ground, in the normal view.
##
## Three things, all read from the simulation and none fed back into it: earth showing
## through where grass is grazed down, a richer green where it stands tall - the
## refuges that fear of predators leaves ungrazed - and paths worn where animals keep
## walking. The grass overlay in the debug panel shows the same numbers as a chart;
## this is the same data as scenery.
##
## The grids reach the GPU as float textures built straight from the packed arrays, so
## a refresh costs no loop in script. The mesh is one quad per walkable terrain cell,
## placed through `WorldProjection` with the cell's elevation, so the tint sits on
## raised ground in the isometric view as it does on flat ground in the top-down one.
## It draws above the biome tiles and below obstacles, animals and overlays.

const GROUND_SHADER := preload("res://shaders/ground_traces.gdshader")

var simulation_manager: SimulationManager

var _mesh_instance: MeshInstance2D
var _material: ShaderMaterial
var _grass_texture: ImageTexture
var _trail_texture: ImageTexture
var _interval_ticks: int = 0


func bind_manager(manager: SimulationManager) -> void:
	simulation_manager = manager
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
	_mesh_instance = MeshInstance2D.new()
	_mesh_instance.mesh = _build_mesh(world.terrain_system)
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
	for key in ["bare_color", "lush_color", "trail_color"]:
		var value = config.get(key)
		if value is Array and value.size() >= 4:
			_material.set_shader_parameter(key, Color(value[0], value[1], value[2], value[3]))
	for key in ["bare_range", "lush_range", "trail_range"]:
		var value = config.get(key)
		if value is Array and value.size() >= 2:
			_material.set_shader_parameter(key, Vector2(value[0], value[1]))
	for key in ["noise_size", "noise_strength"]:
		if config.has(key):
			_material.set_shader_parameter(key, float(config[key]))


## One quad per walkable cell. UV holds the world position, which is all the shader
## needs to find its place in either grid.
static func _build_mesh(terrain: TerrainSystem) -> ArrayMesh:
	var vertices := PackedVector2Array()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()
	for index in range(terrain.get_cell_count()):
		if not terrain.is_walkable_index(index):
			continue
		var rect: Rect2 = terrain.get_cell_rect(index)
		var level: int = terrain.get_height_at_index(index)
		var base := vertices.size()
		for corner in [rect.position, Vector2(rect.end.x, rect.position.y), rect.end, Vector2(rect.position.x, rect.end.y)]:
			vertices.append(WorldProjection.to_screen(corner, level))
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
