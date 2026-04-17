class_name Perception
extends RefCounted


static func get_nearby_agents(world, position: Vector2, radius: float, species_filter: String = "", exclude_id: int = -1) -> Array:
	return world.query_agents(position, radius, species_filter, exclude_id)


static func get_nearest_agent(world, position: Vector2, radius: float, species_filter: String = "", exclude_id: int = -1) -> AgentBase:
	var nearest: AgentBase = null
	var best_distance: float = INF
	for candidate in world.query_agents(position, radius, species_filter, exclude_id):
		var distance: float = candidate.position.distance_squared_to(position)
		if distance < best_distance:
			best_distance = distance
			nearest = candidate
	return nearest


static func find_nearest_water(world, position: Vector2, radius: float) -> Dictionary:
	var nearest := {}
	var best_distance: float = INF
	for source in world.query_water_sources(position, radius):
		var distance: float = position.distance_squared_to(source["position"])
		if distance < best_distance:
			best_distance = distance
			nearest = source
	return nearest


static func find_nearest_carcass(world, position: Vector2, radius: float) -> Dictionary:
	var nearest := {}
	var best_distance: float = INF
	var best_meat: float = -INF
	for carcass in world.query_carcasses(position, radius):
		var distance: float = position.distance_squared_to(carcass["position"])
		var meat_remaining: float = float(carcass.get("meat_remaining", 0.0))
		if distance < best_distance or (is_equal_approx(distance, best_distance) and meat_remaining > best_meat):
			best_distance = distance
			best_meat = meat_remaining
			nearest = carcass
	return nearest


static func find_best_grass(world, position: Vector2, radius: float, min_biomass: float = 0.0) -> Dictionary:
	return world.query_grass_cells(position, radius, min_biomass)
