class_name ScenerySystem
extends RefCounted

## World-owned static scenery. No dependency on the renderer or the ecology RNG.
var _point_cache: Dictionary = {}
var _near_cache: Dictionary = {}
var objects: Array = []
var buckets: Dictionary = {}
var terrain: TerrainSystem
var config: Dictionary = {}
var bucket_size: float = 96.0
var max_extent: float = 0.0
var visibility_checks: int = 0
var local_searches: int = 0

func initialize(world_config: Dictionary, visuals: Dictionary, ground: TerrainSystem, seed_value: int) -> void:
	terrain = ground
	config = world_config.get("scenery", {})
	bucket_size = terrain.cell_size
	objects.clear()
	buckets.clear()
	if not bool(config.get("enabled", true)):
		return
	var rules: Dictionary = config.get("placement", {})
	var groups: Dictionary = visuals.get("props", {}).get("groups", {})
	var scales: Dictionary = visuals.get("props", {}).get("group_scale", {})
	var random := RandomNumberGenerator.new()
	random.seed = seed_value ^ 0x5ce7e
	for index in terrain.get_cell_count():
		var rule: Dictionary = rules.get(terrain.get_biome_at_index(index), {})
		var obstacle: String = terrain.get_obstacle_at_index(index)
		if obstacle != "":
			rule = {"chance": 1.0, "groups": ["stone" if obstacle == "cliff" else "tree_large"]}
		var roll := random.randf()
		var names: Array = rule.get("groups", [])
		if names.is_empty() or roll >= float(rule.get("chance", 0.0)):
			continue
		var kind: String = names[random.randi_range(0, names.size() - 1)]
		var slots: Array = groups.get(kind, [])
		var jitter := Vector2(random.randf_range(-0.22, 0.22), random.randf_range(-0.22, 0.22)) * bucket_size
		var point := terrain.get_cell_center(index) + jitter
		var physics: Dictionary = config.get("types", {}).get(kind, {})
		add_object({"id": index + 1, "position": point, "kind": kind,
			"radius": float(physics.get("radius_cells", 0.0)) * bucket_size,
			"cover_radius": float(physics.get("cover_radius_cells", 0.0)) * bucket_size,
			"opacity": float(physics.get("opacity", 0.0)),
			"move_cost": float(physics.get("move_cost", 1.0)),
			"slot": 0 if slots.is_empty() else int(slots[random.randi_range(0, slots.size() - 1)]),
			"scale": float(scales.get(kind, 1.0)), "level": terrain.get_height_at_index(index)})

func add_object(entry: Dictionary) -> void:
	_point_cache.clear()
	_near_cache.clear()
	objects.append(entry)
	var key := Vector2i((entry.position / bucket_size).floor())
	if not buckets.has(key):
		buckets[key] = []
	buckets[key].append(entry)
	max_extent = maxf(max_extent, maxf(float(entry.get("radius", 0.0)), float(entry.get("cover_radius", 0.0))))

func query_rect(rect: Rect2) -> Array:
	var result: Array = []
	var a := Vector2i((rect.position / bucket_size).floor())
	var b := Vector2i((rect.end / bucket_size).floor())
	for y in range(a.y, b.y + 1):
		for x in range(a.x, b.x + 1):
			for entry in buckets.get(Vector2i(x, y), []):
				if rect.has_point(entry.position):
					result.append(entry)
	return result

func segment_bounds(a: Vector2, b: Vector2, margin: float) -> Rect2:
	return Rect2(a.min(b), a.max(b) - a.min(b)).grow(margin + 0.001)

static func intersects_rect(a: Vector2, b: Vector2, rect: Rect2) -> bool:
	var lo := 0.0
	var hi := 1.0
	var d := b - a
	for axis in 2:
		if absf(d[axis]) < 0.000001:
			if a[axis] < rect.position[axis] or a[axis] > rect.end[axis]:
				return false
		else:
			var t0: float = (rect.position[axis] - a[axis]) / d[axis]
			var t1: float = (rect.end[axis] - a[axis]) / d[axis]
			lo = maxf(lo, minf(t0, t1))
			hi = minf(hi, maxf(t0, t1))
			if lo > hi:
				return false
	return true

func terrain_clear(a: Vector2, b: Vector2, radius: float) -> bool:
	var bounds := Rect2(Vector2.ZERO, terrain.world_size).grow(-radius - 0.01)
	if not bounds.has_point(a) or not bounds.has_point(b):
		return false
	var area := segment_bounds(a, b, radius)
	var low := Vector2i((area.position / terrain.cell_size).floor())
	var high := Vector2i((area.end / terrain.cell_size).floor())
	for y in range(maxi(0, low.y), mini(terrain.rows - 1, high.y) + 1):
		for x in range(maxi(0, low.x), mini(terrain.cols - 1, high.x) + 1):
			var index: int = y * terrain.cols + x
			if not terrain.is_walkable_index(index) and intersects_rect(a, b, terrain.get_cell_rect(index).grow(radius)):
				return false
	var previous := terrain.get_index_from_position(a)
	var steps := maxi(1, int(ceil(a.distance_to(b) / (terrain.cell_size * 0.25))))
	for i in range(1, steps + 1):
		var index := terrain.get_index_from_position(a.lerp(b, float(i) / steps))
		if index != previous and not terrain._is_climbable(previous, index):
			return false
		previous = index
	return true

func segment_clear(a: Vector2, b: Vector2, radius: float = 0.0) -> bool:
	var ai := terrain.get_index_from_position(a)
	var bi := terrain.get_index_from_position(b)
	var short_move := ai >= 0 and ai == bi and radius + max_extent < terrain.cell_size
	var safe_cell := short_move and terrain.is_walkable_index(ai) and terrain.get_cell_rect(ai).grow(-radius - 0.01).has_point(a) and terrain.get_cell_rect(ai).grow(-radius - 0.01).has_point(b)
	if not safe_cell and not terrain_clear(a, b, radius):
		return false
	var nearby: Array
	if short_move:
		if not _near_cache.has(ai):
			_near_cache[ai] = query_rect(terrain.get_cell_rect(ai).grow(terrain.cell_size))
		nearby = _near_cache[ai]
	else:
		nearby = query_rect(segment_bounds(a, b, radius + max_extent))
	for entry in nearby:
		var solid := float(entry.get("radius", 0.0))
		if solid <= 0.0:
			continue
		var closest := Geometry2D.get_closest_point_to_segment(entry.position, a, b)
		if closest.distance_squared_to(entry.position) < pow(solid + radius, 2.0):
			return false
	return true

func resolve_motion(a: Vector2, b: Vector2, radius: float) -> Vector2:
	if segment_clear(a, b, radius):
		return b
	# Stop at first contact, then project the remaining displacement along its tangent.
	var lo := 0.0
	var hi := 1.0
	for iteration in 9:
		var t := (lo + hi) * 0.5
		if segment_clear(a, a.lerp(b, t), radius):
			lo = t
		else:
			hi = t
	var contact := a.lerp(b, maxf(0.0, lo - 0.001))
	var remainder := b - contact
	var best := contact
	var candidates: Array[Vector2] = [Vector2(remainder.x, 0.0), Vector2(0.0, remainder.y)]
	for entry in query_rect(segment_bounds(contact, b, radius + max_extent)):
		if float(entry.get("radius", 0.0)) <= 0.0:
			continue
		var normal: Vector2 = (contact - entry.position).normalized()
		candidates.append(remainder - normal * minf(0.0, remainder.dot(normal)))
	for displacement in candidates:
		var candidate := contact + displacement
		if candidate.distance_squared_to(b) < best.distance_squared_to(b) and segment_clear(contact, candidate, radius):
			best = candidate
	return best

func nearest_free(point: Vector2, radius: float) -> Vector2:
	if segment_clear(point, point, radius):
		return point
	var step := maxf(radius, terrain.cell_size * 0.125)
	for ring in range(1, 33):
		for spoke in 16:
			var candidate := point + Vector2.from_angle(float(spoke) * TAU / 16.0) * step * ring
			if segment_clear(candidate, candidate, radius):
				return candidate
	return point

func movement_cost(point: Vector2) -> float:
	var cost := 1.0
	for entry in query_rect(Rect2(point, Vector2.ZERO).grow(max_extent + 0.01)):
		if point.distance_squared_to(entry.position) <= pow(float(entry.get("cover_radius", 0.0)), 2.0):
			cost = maxf(cost, float(entry.get("move_cost", 1.0)))
	return cost

func visible(a: Vector2, b: Vector2, view_radius: float) -> bool:
	visibility_checks += 1
	var distance := a.distance_to(b)
	if distance > view_radius or not terrain_clear(a, b, 0.0):
		return false
	var attenuation := 1.0
	for entry in query_rect(segment_bounds(a, b, max_extent)):
		var nearest := Geometry2D.get_closest_point_to_segment(entry.position, a, b)
		if nearest.distance_squared_to(entry.position) < pow(float(entry.get("radius", 0.0)), 2.0):
			return false
		if nearest.distance_squared_to(entry.position) < pow(float(entry.get("cover_radius", 0.0)), 2.0):
			attenuation *= 1.0 - clampf(float(entry.get("opacity", 0.0)), 0.0, 0.95)
	return distance <= maxf(terrain.cell_size * float(config.get("close_detection_cells", 0.65)), view_radius * attenuation)

func local_path(a: Vector2, b: Vector2, radius: float) -> PackedVector2Array:
	local_searches += 1
	var spacing := terrain.cell_size * 0.25
	var origin := Vector2i((a / spacing).floor()) - Vector2i(12, 12)
	var grid := AStarGrid2D.new()
	grid.region = Rect2i(origin, Vector2i(25, 25))
	grid.cell_size = Vector2.ONE * spacing
	grid.offset = Vector2.ONE * spacing * 0.5
	grid.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_ONLY_IF_NO_OBSTACLES
	grid.update()
	for y in range(origin.y, origin.y + 25):
		for x in range(origin.x, origin.x + 25):
			var key := Vector2i(x, y)
			var point := grid.get_point_position(key)
			var cache_key := Vector3i(x, y, int(ceil(radius * 100.0)))
			if not _point_cache.has(cache_key):
				_point_cache[cache_key] = not segment_clear(point, point, radius + spacing * 0.15)
			grid.set_point_solid(key, _point_cache[cache_key])
	var start := Vector2i((a / spacing).floor())
	var end := Vector2i((b / spacing).floor()).clamp(origin + Vector2i.ONE, origin + Vector2i(23, 23))
	if grid.is_point_solid(end):
		return PackedVector2Array()
	grid.set_point_solid(start, false)
	var raw := grid.get_point_path(start, end)
	if raw.is_empty():
		return raw
	var path := PackedVector2Array([a])
	for i in range(1, raw.size()):
		if not segment_clear(path[-1], raw[i], radius):
			return PackedVector2Array()
		path.append(raw[i])
	if segment_clear(path[-1], b, radius):
		path.append(b)
	return path
