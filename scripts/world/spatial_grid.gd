class_name SpatialGrid
extends RefCounted

var cell_size: float = 96.0
var _cells: Dictionary = {}
var _agent_cells: Dictionary = {}


func configure(new_cell_size: float) -> void:
	cell_size = max(new_cell_size, 1.0)


func rebuild(living_agents: Array) -> void:
	_cells.clear()
	_agent_cells.clear()
	for agent in living_agents:
		insert(agent)


func clear() -> void:
	_cells.clear()
	_agent_cells.clear()


func insert(agent) -> void:
	if agent == null or not agent.is_alive:
		return
	var cell := _to_cell(agent.position)
	_agent_cells[agent.id] = cell
	var bucket: Array = _cells.get(cell, [])
	bucket.append(agent)
	_cells[cell] = bucket


func remove(agent) -> void:
	if agent == null:
		return
	var cell: Vector2i = _agent_cells.get(agent.id, Vector2i(2147483647, 2147483647))
	if cell.x == 2147483647:
		return
	var bucket: Array = _cells.get(cell, [])
	var index := bucket.find(agent)
	if index != -1:
		bucket.remove_at(index)
	if bucket.is_empty():
		_cells.erase(cell)
	else:
		_cells[cell] = bucket
	_agent_cells.erase(agent.id)


func update_agent(agent, previous_position: Vector2 = Vector2(INF, INF)) -> bool:
	if agent == null:
		return false
	if not agent.is_alive:
		remove(agent)
		return false
	var fallback_position: Vector2 = agent.position if previous_position == Vector2(INF, INF) else previous_position
	var previous_cell: Vector2i = _agent_cells.get(agent.id, _to_cell(fallback_position))
	var next_cell := _to_cell(agent.position)
	if not _agent_cells.has(agent.id):
		insert(agent)
		return true
	if previous_cell == next_cell:
		return false
	var previous_bucket: Array = _cells.get(previous_cell, [])
	var previous_index := previous_bucket.find(agent)
	if previous_index != -1:
		previous_bucket.remove_at(previous_index)
	if previous_bucket.is_empty():
		_cells.erase(previous_cell)
	else:
		_cells[previous_cell] = previous_bucket
	var next_bucket: Array = _cells.get(next_cell, [])
	next_bucket.append(agent)
	_cells[next_cell] = next_bucket
	_agent_cells[agent.id] = next_cell
	return true


func get_agent_cell(agent_id: int) -> Variant:
	if not _agent_cells.has(agent_id):
		return null
	return _agent_cells[agent_id]


func query(position: Vector2, radius: float, species_filter: String = "", exclude_id: int = -1) -> Array:
	var results: Array = []
	query_into(results, position, radius, species_filter, exclude_id)
	return results


func query_into(results: Array, position: Vector2, radius: float, species_filter: String = "", exclude_id: int = -1) -> void:
	results.clear()
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
