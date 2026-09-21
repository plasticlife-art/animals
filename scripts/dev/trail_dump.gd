extends SceneTree

# Writes the trail field to a PNG after a headless run. Not part of the game.
#
#   Godot --headless --path . --script res://scripts/dev/trail_dump.gd -- <seed> <seconds> <out.png> [from] [full] [a.b.c=value ...]
# White is ground worn to `full` or past it, black is ground below `from` - the two ends
# of `visuals.ground.trail_range` - so the picture is what the ground layer would draw,
# without the fifteen minutes a windowed capture takes. Water is drawn blue for bearings.


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var run_seed := int(args[0]) if args.size() > 0 else 3
	var seconds := float(args[1]) if args.size() > 1 else 900.0
	var out := str(args[2]) if args.size() > 2 else "user://trails.png"
	var bundle: Dictionary = ConfigLoader.load_config_bundle()
	var trail_range: Array = bundle.get("visuals", {}).get("ground", {}).get("trail_range", [80.0, 800.0])
	var from := float(args[3]) if args.size() > 3 else float(trail_range[0])
	var full := float(args[4]) if args.size() > 4 else float(trail_range[1])
	for index in range(5, args.size()):
		var pair := str(args[index]).split("=", true, 1)
		if pair.size() == 2:
			_override(bundle, pair[0], pair[1])
	var manager = preload("res://scripts/core/simulation_manager.gd").new()
	manager.initialize(bundle, run_seed)
	manager.set_lod_enabled(true)
	var center: Vector2 = manager.world_state.bounds.get_center()
	manager.set_lod_view(Rect2(center - Vector2.ONE * 0.5, Vector2.ONE), center, true)
	for tick in range(int(ceil(seconds * manager.tick_rate))):
		manager.step_once()
	var world = manager.world_state
	var field = world.trail_field
	var cells: PackedFloat32Array = field.export_cells()
	var image := Image.create(field.cols, field.rows, false, Image.FORMAT_RGB8)
	var worn := 0
	var peak := 0.0
	for index in range(cells.size()):
		var shade: float = smoothstep(from, full, cells[index])
		peak = maxf(peak, cells[index])
		if shade > 0.0:
			worn += 1
		@warning_ignore("integer_division")
		var cell := Vector2i(index % field.cols, index / field.cols)
		var position: Vector2 = (Vector2(cell) + Vector2(0.5, 0.5)) * field.cell_size
		var ground: Color = Color(0.1, 0.16, 0.1) if world.terrain_system.is_walkable_position(position) else Color(0.25, 0.25, 0.28)
		image.set_pixelv(cell, ground.lerp(Color(1.0, 0.9, 0.6), shade))
	for source in world.water_sources:
		var water_position: Vector2 = source.get("position", Vector2.ZERO)
		var radius := int(ceil(float(source.get("radius", 60.0)) / field.cell_size))
		var at := Vector2i(water_position / field.cell_size)
		for dy in range(-radius, radius + 1):
			for dx in range(-radius, radius + 1):
				var pixel := at + Vector2i(dx, dy)
				if dx * dx + dy * dy <= radius * radius and pixel.x >= 0 and pixel.y >= 0 \
						and pixel.x < field.cols and pixel.y < field.rows:
					image.set_pixelv(pixel, image.get_pixelv(pixel).lerp(Color(0.2, 0.45, 0.9), 0.6))
	image.save_png(out)
	# The raw grid beside it, so another range can be tried without another run.
	var raw := FileAccess.open(out + ".f32", FileAccess.WRITE)
	raw.store_buffer(cells.to_byte_array())
	raw.close()
	print("saved %s: %d of %d cells worn, peak %.0f, range %.0f-%.0f" % [out, worn, cells.size(), peak, from, full])
	manager.free()
	quit()


func _override(bundle: Dictionary, path: String, raw: String) -> void:
	var keys := path.split(".")
	var node: Dictionary = bundle
	for index in range(keys.size() - 1):
		if not node.has(keys[index]) or not (node[keys[index]] is Dictionary):
			node[keys[index]] = {}
		node = node[keys[index]]
	node[keys[keys.size() - 1]] = float(raw) if raw.is_valid_float() else raw
