class_name Steering
extends RefCounted


static func seek(current: Vector2, target: Vector2) -> Vector2:
	var offset: Vector2 = target - current
	if offset.length_squared() <= 0.0001:
		return Vector2.ZERO
	return offset.normalized()


static func flee(current: Vector2, threat: Vector2) -> Vector2:
	var offset: Vector2 = current - threat
	if offset.length_squared() <= 0.0001:
		return Vector2.ZERO
	return offset.normalized()


static func wander(agent, rng: RandomNumberGenerator) -> Vector2:
	var jitter := float(agent.movement.get("wander_jitter", 0.8))
	agent.wander_angle += rng.randf_range(-jitter, jitter)
	return Vector2.RIGHT.rotated(agent.wander_angle)


static func cohesion(position: Vector2, neighbors: Array) -> Vector2:
	if neighbors.is_empty():
		return Vector2.ZERO
	var center := Vector2.ZERO
	for neighbor in neighbors:
		center += neighbor.position
	center /= neighbors.size()
	return seek(position, center)


static func alignment(neighbors: Array) -> Vector2:
	if neighbors.is_empty():
		return Vector2.ZERO
	var average := Vector2.ZERO
	for neighbor in neighbors:
		average += neighbor.direction
	if average.length_squared() <= 0.0001:
		return Vector2.ZERO
	return average.normalized()


static func separation(position: Vector2, neighbors: Array, separation_radius: float) -> Vector2:
	var total := Vector2.ZERO
	for neighbor in neighbors:
		var offset: Vector2 = position - neighbor.position
		var distance: float = offset.length()
		if distance <= 0.001 or distance > separation_radius:
			continue
		total += offset.normalized() / maxf(distance, 1.0)
	if total.length_squared() <= 0.0001:
		return Vector2.ZERO
	return total.normalized()


static func combine(vectors: Array) -> Vector2:
	var total := Vector2.ZERO
	for item in vectors:
		total += item["vector"] * float(item["weight"])
	if total.length_squared() <= 0.0001:
		return Vector2.ZERO
	return total.normalized()
