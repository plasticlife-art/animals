class_name WaterBodies
extends RefCounted

## The map's standing water in natural shapes: a few lakes, marshes and ponds, each made of round
## lobes. A lake is a chain of overlapping circles along a winding spine, broad in the middle and
## narrowing to its ends, with bays and arms off it; a marsh a loose cluster; a pond one to three
## circles - an oval, a kidney. Every lobe is a source of `WorldState.water_sources` carrying its
## body's tag (`body`) and kind (`kind`), so whatever measures a round pond measures a lobe, and
## `WaterSystem` keeps one level for all the lobes of a body.
##
## Lakes are laid first, spread apart; then marshes, most of them off a lake's end, where a lake
## shoals; then ponds, each where the map lies furthest from any water, until nowhere is further
## than `ponds.max_gap` from it (and at least `ponds.count_min` are laid, at most `count_max`).
## Lengths are the large map's, times `scale`, as the map sizes scale the large map.
##
## A generator of its own, seeded from `seed` and the world's seed: the world's stream is not drawn
## from, and each world has its own water. `is_land` (a point -> bool), when given, keeps every
## lobe on land - the island's shore.

const SALT := 0x3A7E5
const KIND_LAKE := "lake"
const KIND_MARSH := "marsh"
const KIND_POND := "pond"
const DEFAULTS := {
	"enabled": false,
	"scale": 1.0,
	"seed": 0,
	# How far from the map's edge every lobe keeps, and from another body's bank.
	"border": 360.0,
	"spacing": 420.0,
	"lakes": {"count": 3, "length_min": 1400.0, "length_max": 2800.0, "radius_min": 240.0, "radius_max": 400.0,
		"arms_max": 3},
	"marshes": {"count": 3, "radius_min": 170.0, "radius_max": 260.0, "lobes_min": 8, "lobes_max": 14,
		"by_lake": 0.6},
	"ponds": {"count_min": 8, "count_max": 18, "radius_min": 130.0, "radius_max": 230.0, "lobes_max": 3,
		"max_gap": 1300.0},
}
const ATTEMPTS := 40
const HALF_ATTEMPTS := 20
const CANDIDATES := 24


## Whether `source` is a marsh's lobe: shallow water that is walked through, not round.
static func is_shallow(source: Dictionary) -> bool:
	return str(source.get("kind", "")) == KIND_MARSH


## `config` merged over `DEFAULTS`, one level deep for the kinds' blocks.
static func settings(config: Dictionary) -> Dictionary:
	var merged: Dictionary = DEFAULTS.duplicate(true)
	for key in config.keys():
		if merged.get(key) is Dictionary and config[key] is Dictionary:
			var block: Dictionary = merged[key]
			block.merge(config[key], true)
		else:
			merged[key] = config[key]
	return merged


## The lobes, `{position, radius, body, kind}`, body after body: each body's lobes together, its
## largest first.
static func generate(config: Dictionary, bounds: Rect2, world_seed: int, is_land: Callable = Callable()) -> Array:
	var cfg := settings(config)
	var random := RandomNumberGenerator.new()
	random.seed = (int(world_seed) ^ SALT) + int(cfg["seed"])
	var scale := maxf(0.01, float(cfg["scale"]))
	var inner := bounds.grow(-float(cfg["border"]) * scale)
	if inner.size.x <= 0.0 or inner.size.y <= 0.0:
		return []
	var spacing := float(cfg["spacing"]) * scale
	var bodies: Array = []
	var kinds: Array = []
	# Lakes: the best of several random centres, the one furthest from the lakes before it.
	var lakes: Dictionary = cfg["lakes"]
	for _lake in range(int(lakes["count"])):
		for _attempt in range(ATTEMPTS):
			var centre := _far_point(random, inner, bodies, is_land)
			var lobes := _fit(_lake_lobes(random, centre, scale, lakes), inner)
			if _placeable(lobes, inner, bodies, spacing, is_land):
				bodies.append(lobes)
				kinds.append(KIND_LAKE)
				break
	# Marshes: off a lake's end, where its spine runs out into the shallows, or on their own.
	var marshes: Dictionary = cfg["marshes"]
	var lake_count := bodies.size()
	for marsh in range(int(marshes["count"])):
		for attempt in range(ATTEMPTS):
			var centre := _far_point(random, inner, bodies, is_land)
			var exempt := -1
			var radius := random.randf_range(float(marshes["radius_min"]), float(marshes["radius_max"])) * scale
			if lake_count > 0 and attempt < HALF_ATTEMPTS and random.randf() < float(marshes["by_lake"]):
				exempt = (marsh + attempt) % lake_count
				var end: Array = _lake_end(bodies[exempt], random.randi() % 2)
				centre = end[0] + end[1] * (float(end[2]) + radius * 0.9)
			var lobes := _fit(_marsh_lobes(random, centre, radius, marshes), inner)
			if _placeable(lobes, inner, bodies, spacing, is_land, exempt):
				bodies.append(lobes)
				kinds.append(KIND_MARSH)
				break
	# Ponds: where the map is driest, until it is nowhere dry enough.
	var ponds: Dictionary = cfg["ponds"]
	var step := maxf(1.0, 240.0 * scale)
	var candidates := PackedVector2Array()
	var y := inner.position.y + step * 0.5
	while y < inner.end.y:
		var x := inner.position.x + step * 0.5
		while x < inner.end.x:
			if not is_land.is_valid() or bool(is_land.call(Vector2(x, y))):
				candidates.append(Vector2(x, y))
			x += step
		y += step
	var gaps := PackedFloat32Array()
	gaps.resize(candidates.size())
	for index in range(candidates.size()):
		gaps[index] = _gap(candidates[index], bodies)
	var max_gap := float(ponds["max_gap"]) * scale
	var placed := 0
	while placed < int(ponds["count_max"]) and not candidates.is_empty():
		var best := 0
		for index in range(1, gaps.size()):
			if gaps[index] > gaps[best]:
				best = index
		if gaps[best] == -INF or (gaps[best] < max_gap and placed >= int(ponds["count_min"])):
			break
		var centre := candidates[best] + Vector2(random.randf_range(-0.3, 0.3), random.randf_range(-0.3, 0.3)) * step
		var lobes := _fit(_pond_lobes(random, centre, scale, ponds), inner)
		if not _placeable(lobes, inner, bodies, spacing, is_land):
			gaps[best] = -INF
			continue
		bodies.append(lobes)
		kinds.append(KIND_POND)
		placed += 1
		for index in range(candidates.size()):
			if gaps[index] != -INF:
				gaps[index] = minf(gaps[index], _gap(candidates[index], [lobes]))
	# Out, each body's largest lobe first, no two lobes at one point: a pond is found by its centre.
	var sources: Array = []
	var taken := {}
	for body in range(bodies.size()):
		var lobes: Array = bodies[body]
		lobes.sort_custom(func(a, b): return float(a[1]) > float(b[1]))
		for lobe in lobes:
			var position: Vector2 = lobe[0]
			while taken.has(position):
				position += Vector2(0.5, 0.0)
			taken[position] = true
			sources.append({"position": position, "radius": float(lobe[1]), "body": body, "kind": kinds[body]})
	return sources


## A lake's lobes, `[centre, radius]`: a spine walked both ways from `centre`, its lobes broadest in
## the middle; one in three lakes short and broad with more arms, one in four bent like a crescent.
static func _lake_lobes(random: RandomNumberGenerator, centre: Vector2, scale: float, cfg: Dictionary) -> Array:
	var length := random.randf_range(float(cfg["length_min"]), float(cfg["length_max"])) * scale
	var width := random.randf_range(float(cfg["radius_min"]), float(cfg["radius_max"])) * scale
	var arms := random.randi_range(0, int(cfg["arms_max"]))
	var shape := random.randf()
	var bend := 0.0
	if shape < 0.33:
		length *= 0.5
		arms += 1
	elif shape < 0.58:
		bend = random.randf_range(0.12, 0.2) * (1.0 if random.randf() < 0.5 else -1.0)
	var heading := random.randf() * TAU
	var spine: Array = []
	for direction: float in [1.0, -1.0]:
		var point := centre
		var facing := heading if direction > 0.0 else heading + PI
		var curve := bend * direction
		var walked := 0.0
		var half := length * 0.5
		while walked <= half:
			var t := walked / maxf(half, 1.0)
			var radius := width * (0.42 + 0.58 * pow(maxf(0.0, 1.0 - t * t), 0.7)) * random.randf_range(0.82, 1.18)
			if direction > 0.0 or walked > 0.0:
				if direction > 0.0:
					spine.append([point, radius])
				else:
					spine.push_front([point, radius])
			var step := maxf(radius, width * 0.4) * 0.55
			facing += curve + random.randf_range(-0.28, 0.28)
			if bend == 0.0:
				curve = clampf(curve + random.randf_range(-0.08, 0.08), -0.22, 0.22)
			point += Vector2.from_angle(facing) * step
			walked += step
	var lobes: Array = spine.duplicate()
	# Arms and bays: off the spine's middle, out to one side, each lobe smaller than the last.
	for _arm in range(arms):
		if spine.size() < 3:
			break
		var at := random.randi_range(maxi(1, int(spine.size() * 0.15)), mini(spine.size() - 2, int(spine.size() * 0.85)))
		var along: Vector2 = (spine[at + 1][0] - spine[at - 1][0]).normalized()
		var out := along.orthogonal() * (1.0 if random.randf() < 0.5 else -1.0)
		out = out.rotated(random.randf_range(-0.5, 0.5))
		var point: Vector2 = spine[at][0]
		var radius := float(spine[at][1]) * random.randf_range(0.55, 0.8)
		point += out * (float(spine[at][1]) * 0.7)
		for _lobe in range(random.randi_range(1, 3)):
			lobes.append([point, radius])
			out = out.rotated(random.randf_range(-0.4, 0.4))
			point += out * radius * 0.6
			radius *= random.randf_range(0.8, 0.92)
	return _unburied(lobes)


## A marsh's lobes: one of `radius` at `centre`, the rest each off a lobe before it, overlapping.
static func _marsh_lobes(random: RandomNumberGenerator, centre: Vector2, radius: float, cfg: Dictionary) -> Array:
	var lobes: Array = [[centre, radius]]
	for _lobe in range(random.randi_range(int(cfg["lobes_min"]), int(cfg["lobes_max"])) - 1):
		var base: Array = lobes[random.randi() % lobes.size()]
		var size := radius * random.randf_range(0.35, 0.9)
		var offset := Vector2.from_angle(random.randf() * TAU) * (float(base[1]) + size) * random.randf_range(0.5, 0.85)
		lobes.append([base[0] + offset, size])
	return _unburied(lobes)


## A pond's lobes: one, or two or three overlapping - an oval, a kidney, a clover gone soft.
static func _pond_lobes(random: RandomNumberGenerator, centre: Vector2, scale: float, cfg: Dictionary) -> Array:
	var radius := random.randf_range(float(cfg["radius_min"]), float(cfg["radius_max"])) * scale
	var lobes: Array = [[centre, radius]]
	var angle := random.randf() * TAU
	var extra := 0 if random.randf() < 0.2 else random.randi_range(1, maxi(1, int(cfg["lobes_max"]) - 1))
	for _lobe in range(extra):
		var size := radius * random.randf_range(0.55, 0.85)
		lobes.append([centre + Vector2.from_angle(angle) * radius * random.randf_range(0.45, 0.8), size])
		angle += random.randf_range(1.6, 2.6)
	return _unburied(lobes)


## The lobes but those wholly inside the others, which add nothing and give no shore.
static func _unburied(lobes: Array) -> Array:
	var kept: Array = []
	for index in range(lobes.size()):
		var exposed := false
		for probe in range(12):
			var rim: Vector2 = lobes[index][0] + Vector2.from_angle(TAU * float(probe) / 12.0) * float(lobes[index][1])
			var covered := false
			for other in range(lobes.size()):
				if other != index and rim.distance_to(lobes[other][0]) < float(lobes[other][1]) - 1.0:
					covered = true
					break
			if not covered:
				exposed = true
				break
		if exposed:
			kept.append(lobes[index])
	return kept


## The lobes moved, all together, as little as puts every one inside `inner`, or as they were when
## they cannot all fit.
static func _fit(lobes: Array, inner: Rect2) -> Array:
	if lobes.is_empty():
		return lobes
	var box := Rect2(lobes[0][0], Vector2.ZERO)
	for lobe in lobes:
		box = box.merge(Rect2(lobe[0] - Vector2.ONE * float(lobe[1]), Vector2.ONE * float(lobe[1]) * 2.0))
	if box.size.x > inner.size.x or box.size.y > inner.size.y:
		return lobes
	var shift := Vector2(maxf(0.0, inner.position.x - box.position.x) - maxf(0.0, box.end.x - inner.end.x),
		maxf(0.0, inner.position.y - box.position.y) - maxf(0.0, box.end.y - inner.end.y))
	var moved: Array = []
	for lobe in lobes:
		moved.append([lobe[0] + shift, lobe[1]])
	return moved


## Whether a body of `lobes` lies inside `inner`, on land, and `spacing` clear of every body's bank
## but `exempt`'s, which it may touch but not reach into past half its own lobes' radii.
static func _placeable(lobes: Array, inner: Rect2, bodies: Array, spacing: float, is_land: Callable,
		exempt: int = -1) -> bool:
	if lobes.is_empty():
		return false
	for lobe in lobes:
		var centre: Vector2 = lobe[0]
		var radius := float(lobe[1])
		if not inner.grow(-radius).has_point(centre):
			return false
		if is_land.is_valid():
			for probe in range(9):
				var point := centre if probe == 0 else centre + Vector2.from_angle(TAU * float(probe) / 8.0) * radius
				if not bool(is_land.call(point)):
					return false
		for body in range(bodies.size()):
			for other in bodies[body]:
				var gap: float = centre.distance_to(other[0]) - radius - float(other[1])
				if body == exempt:
					if gap < -radius * 0.5:
						return false
				elif gap < spacing:
					return false
	return true


## The best of `CANDIDATES` random points of `inner`: the one furthest from every lobe so far - of
## those on land, given `is_land`: furthest from the island's lakes was out at sea, and a body
## centred there was never laid.
static func _far_point(random: RandomNumberGenerator, inner: Rect2, bodies: Array, is_land: Callable = Callable()) -> Vector2:
	var best := inner.get_center()
	var best_gap := -INF
	for _candidate in range(CANDIDATES):
		var point := Vector2(random.randf_range(inner.position.x, inner.end.x), random.randf_range(inner.position.y, inner.end.y))
		if is_land.is_valid() and not bool(is_land.call(point)):
			continue
		var gap := _gap(point, bodies)
		if gap > best_gap:
			best_gap = gap
			best = point
	return best


## How far `point` lies from the nearest bank of `bodies`, INF with none.
static func _gap(point: Vector2, bodies: Array) -> float:
	var nearest := INF
	for lobes in bodies:
		for lobe in lobes:
			nearest = minf(nearest, point.distance_to(lobe[0]) - float(lobe[1]))
	return nearest


## One end of a lake: `[the end lobe's centre, outwards, its radius]`, the end lobe the one furthest
## from the lake's middle on side `side` (0 or 1) of its longest axis.
static func _lake_end(lobes: Array, side: int) -> Array:
	var middle := Vector2.ZERO
	for lobe in lobes:
		middle += lobe[0]
	middle /= float(maxi(1, lobes.size()))
	var first: Array = lobes[0]
	for lobe in lobes:
		if (lobe[0] as Vector2).distance_to(middle) > (first[0] as Vector2).distance_to(middle):
			first = lobe
	var end: Array = first
	if side == 1:
		var second: Array = first
		for lobe in lobes:
			if (lobe[0] as Vector2).distance_to(first[0]) > (second[0] as Vector2).distance_to(first[0]):
				second = lobe
		end = second
	var outwards: Vector2 = ((end[0] as Vector2) - middle).normalized()
	if outwards == Vector2.ZERO:
		outwards = Vector2.RIGHT
	return [end[0], outwards, float(end[1])]
