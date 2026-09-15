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


## Random-walk heading.
##
## The jitter is applied on every call, so at `tick_rate` 18 the default 0.75-0.85 rad
## decorrelates the heading in well under a second - a persistence length of a few dozen
## units. That is fine for milling around inside a herd, and useless for covering
## ground. Callers that need to travel pass a much smaller `jitter_override`: for a
## persistence length L at speed v, jitter is about `sqrt(1 / (L / v * tick_rate))`.
static func wander(agent, rng: RandomNumberGenerator, jitter_override: float = -1.0) -> Vector2:
	var jitter := jitter_override if jitter_override >= 0.0 else float(agent.movement.get("wander_jitter", 0.8))
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


## Push away from crowding neighbours, with a magnitude that grows as they close in.
##
## Unlike the other primitives here this one deliberately does NOT return a unit
## vector. It used to, and that was the main reason herds packed: an animal two
## units from its neighbour pushed exactly as hard as one eighty units away, so
## crowding could never escalate its own response. Since `combine()` normalizes
## the weighted sum, magnitude is what decides whether separation wins the
## direction vote, and it has to be free to exceed 1.0 when animals overlap.
static func separation(position: Vector2, neighbors: Array, separation_radius: float) -> Vector2:
	if separation_radius <= 0.0:
		return Vector2.ZERO
	var total := Vector2.ZERO
	var closest := separation_radius
	for neighbor in neighbors:
		var offset: Vector2 = position - neighbor.position
		var distance: float = offset.length()
		if distance > separation_radius:
			continue
		if distance <= 0.001:
			# Exactly coincident: there is no offset to point along. Derive a
			# direction from the neighbour's id so the pair breaks apart instead
			# of staying welded, and so it does so identically on every replay.
			total += Vector2.RIGHT.rotated(float(int(neighbor.id) * 2654435761 % 6283) * 0.001)
			closest = 0.0
			continue
		closest = minf(closest, distance)
		total += offset.normalized() * (1.0 - distance / separation_radius)
	if total.length_squared() <= 0.0001:
		return Vector2.ZERO
	# Squared so the push stays gentle at conversational distance and turns
	# insistent only once animals are genuinely overlapping.
	var urgency: float = 1.0 - closest / separation_radius
	return total.normalized() * urgency * urgency * 3.0


static func combine(vectors: Array) -> Vector2:
	var total := Vector2.ZERO
	for item in vectors:
		total += item["vector"] * float(item["weight"])
	if total.length_squared() <= 0.0001:
		return Vector2.ZERO
	return total.normalized()


## Hot two-vector form used by herd movement. It avoids allocating an Array and
## two Dictionaries for every moving animal on every simulation tick.
static func combine_two(first: Vector2, first_weight: float, second: Vector2, second_weight: float) -> Vector2:
	var total := first * first_weight + second * second_weight
	if total.length_squared() <= 0.0001:
		return Vector2.ZERO
	return total.normalized()
