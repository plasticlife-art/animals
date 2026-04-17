class_name SpatialGrid
extends RefCounted

var cell_size: float = 96.0
var _cells: Dictionary = {}


func configure(new_cell_size: float) -> void:
	cell_size = max(new_cell_size, 1.0)


func rebuild(living_agents: Array) -> void:
	_cells.clear()
	for agent in living_agents:
		if agent == null or not agent.is_alive:
			continue
		var cell := _to_cell(agent.position)
		if not _cells.has(cell):
			_cells[cell] = []
		_cells[cell].append(agent)


func query(position: Vector2, radius: float, species_filter: String = "", exclude_id: int = -1) -> Array:
	var results: Array = []
	var radius_sq := radius * radius
	var center := _to_cell(position)
	var cell_radius := int(ceil(radius / cell_size))

	for x in range(center.x - cell_radius, center.x + cell_radius + 1):
		for y in range(center.y - cell_radius, center.y + cell_radius + 1):
			var bucket: Array = _cells.get(Vector2i(x, y), [])
			for agent in bucket:
				if agent == null or agent.id == exclude_id:
					continue
				if not agent.is_alive:
					continue
				if species_filter != "" and agent.species_type != species_filter:
					continue
				if agent.position.distance_squared_to(position) <= radius_sq:
					results.append(agent)
	return results


func get_population_density() -> Array:
	var density: Array = []
	for cell in _cells.keys():
		var bucket: Array = _cells[cell]
		density.append({
			"cell": cell,
			"count": bucket.size(),
			"position": Vector2((cell.x + 0.5) * cell_size, (cell.y + 0.5) * cell_size),
			"size": cell_size,
		})
	return density


func get_population_density_in_rect(visible_rect: Rect2) -> Array:
	var density: Array = []
	for cell in _cells.keys():
		var bucket: Array = _cells[cell]
		var rect := Rect2(
			Vector2(cell.x * cell_size, cell.y * cell_size),
			Vector2.ONE * cell_size
		)
		if not visible_rect.intersects(rect):
			continue
		density.append({
			"cell": cell,
			"count": bucket.size(),
			"position": rect.get_center(),
			"size": cell_size,
		})
	return density


func _to_cell(position: Vector2) -> Vector2i:
	return Vector2i(floori(position.x / cell_size), floori(position.y / cell_size))
