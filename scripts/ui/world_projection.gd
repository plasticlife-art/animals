class_name WorldProjection
extends RefCounted

## Seam between simulation space and screen space.
##
## The simulation is Cartesian all the way down: `WorldState.bounds`, agent
## positions, the terrain grid and the spatial grid are all plain world
## coordinates. Nothing below this line ever changes what the simulation
## computes - the projection only decides where those coordinates get drawn.
##
## Two modes. `ORTHOGONAL` is the identity transform. `ISOMETRIC` turns the world
## 45 degrees and halves it vertically, and adds a vertical offset per terrain
## elevation level. The mode follows `visuals.projection`, which the default
## style preset sets to orthogonal.
##
## Anything that turns a simulation position into something drawn goes through
## `to_screen()`. Anything that turns a screen position back into simulation
## space - mouse picking, view culling, the LOD focus rect - goes through
## `to_world()` or `world_rect_covering()`.
##
## Known gaps under ISOMETRIC: click picking in `world_view.gd` calls `to_world()`
## once, without the height correction described below, so a click on raised
## ground can pick the wrong animal; and the minimap draws the camera as an
## axis-aligned rectangle rather than the diamond the view actually covers.

enum Mode { ORTHOGONAL, ISOMETRIC }

## Art pixels the terrain rises per elevation level: the skirt step drawn in the
## isometric tile atlas. On screen it is scaled with the art (`art_scale`).
const DEFAULT_LEVEL_HEIGHT_PX := 16.0

static var _mode: int = Mode.ORTHOGONAL
static var _level_height_px: float = DEFAULT_LEVEL_HEIGHT_PX
static var _max_height_level: int = 0


## Called once at boot from `MainController`. `max_height_level` comes from
## `TerrainSystem` and is what `world_rect_covering()` uses to decide how far
## past the visible edge tall ground can still reach. `art_scale` is how much the
## terrain art is enlarged (`TerrainTileRenderer.iso_art_scale()`): the ground rises
## `level_height_px` art pixels per level, so a sprite must rise that many times it.
## Left at 1 while cells grew from 32 to 96 units, sprites rose a third as far as
## the ground.
static func configure(visuals_config: Dictionary, max_height_level: int = 0, art_scale: float = 1.0) -> void:
	var mode_name := str(visuals_config.get("projection", "orthogonal")).to_lower()
	_mode = Mode.ISOMETRIC if mode_name == "isometric" else Mode.ORTHOGONAL
	_level_height_px = maxf(1.0, float(visuals_config.get("level_height_px", DEFAULT_LEVEL_HEIGHT_PX)) * maxf(art_scale, 0.0001))
	_max_height_level = maxi(0, max_height_level)


static func to_screen(world_position: Vector2, height_level: int = 0) -> Vector2:
	if _mode == Mode.ORTHOGONAL:
		return world_position
	return Vector2(
		world_position.x - world_position.y,
		(world_position.x + world_position.y) * 0.5 - float(height_level) * _level_height_px
	)


## Inverse of `to_screen()` for a known elevation.
##
## Note what this cannot do: a screen point maps to a ray, not a point, and
## which cell that ray lands on depends on the elevation there. Callers that do
## not know the height in advance - mouse picking above all - should resolve at
## level 0 first, look up the terrain height at the result, and call again with
## it. One correction is enough in practice; the error is a cell or two only on
## the face of a tall cliff.
static func to_world(screen_position: Vector2, height_level: int = 0) -> Vector2:
	if _mode == Mode.ORTHOGONAL:
		return screen_position
	var ground_y: float = screen_position.y + float(height_level) * _level_height_px
	return Vector2(
		screen_position.x * 0.5 + ground_y,
		ground_y - screen_position.x * 0.5
	)


## Bounding box in simulation space of everything the given screen rect covers.
##
## Under ISOMETRIC an axis-aligned screen rect maps to a rotated diamond, so the
## honest answer is that diamond's bounding box, which is deliberately larger
## than the visible area. The box is then grown again by the elevation offset:
## ground high enough to be lifted into view sits outside the flat projection.
##
## `main_controller.gd` feeds this rect to `set_lod_focus_rect()`, which drives
## sector dormancy - simulation behavior, not just visuals. Erring larger costs
## a little performance; erring smaller would put live sectors to sleep.
static func world_rect_covering(screen_rect: Rect2) -> Rect2:
	if _mode == Mode.ORTHOGONAL:
		return screen_rect
	var corners := [
		to_world(screen_rect.position),
		to_world(Vector2(screen_rect.end.x, screen_rect.position.y)),
		to_world(Vector2(screen_rect.position.x, screen_rect.end.y)),
		to_world(screen_rect.end),
	]
	var minimum: Vector2 = corners[0]
	var maximum: Vector2 = corners[0]
	for corner in corners:
		minimum = minimum.min(corner)
		maximum = maximum.max(corner)
	var reach: float = float(_max_height_level) * _level_height_px
	minimum -= Vector2.ONE * reach
	maximum += Vector2.ONE * reach
	return Rect2(minimum, maximum - minimum)


## Fraction of the world's ground plane visible through a screen-space camera
## rectangle. The inverse AABB from `world_rect_covering()` deliberately
## overestimates an isometric diamond and can report 100% while only its middle
## is on screen. Clipping the projected world polygon keeps overview thresholds
## honest in both projections.
static func visible_world_fraction(screen_rect: Rect2, world_bounds: Rect2) -> float:
	if screen_rect.get_area() <= 0.0 or world_bounds.get_area() <= 0.0:
		return 0.0
	var polygon: Array = [
		to_screen(world_bounds.position),
		to_screen(Vector2(world_bounds.end.x, world_bounds.position.y)),
		to_screen(world_bounds.end),
		to_screen(Vector2(world_bounds.position.x, world_bounds.end.y)),
	]
	var total_area := _polygon_area(polygon)
	if total_area <= 0.0:
		return 0.0
	polygon = _clip_polygon_axis(polygon, 0, screen_rect.position.x, true)
	polygon = _clip_polygon_axis(polygon, 0, screen_rect.end.x, false)
	polygon = _clip_polygon_axis(polygon, 1, screen_rect.position.y, true)
	polygon = _clip_polygon_axis(polygon, 1, screen_rect.end.y, false)
	return clampf(_polygon_area(polygon) / total_area, 0.0, 1.0)


static func _clip_polygon_axis(points: Array, axis: int, boundary: float, keep_greater: bool) -> Array:
	var clipped: Array = []
	if points.is_empty():
		return clipped
	var previous: Vector2 = points.back()
	var previous_value: float = previous.x if axis == 0 else previous.y
	var previous_inside := previous_value >= boundary if keep_greater else previous_value <= boundary
	for value in points:
		var current: Vector2 = value
		var current_value: float = current.x if axis == 0 else current.y
		var current_inside := current_value >= boundary if keep_greater else current_value <= boundary
		if current_inside != previous_inside:
			var denominator := current_value - previous_value
			var weight := 0.0 if is_zero_approx(denominator) else (boundary - previous_value) / denominator
			clipped.append(previous.lerp(current, weight))
		if current_inside:
			clipped.append(current)
		previous = current
		previous_value = current_value
		previous_inside = current_inside
	return clipped


static func _polygon_area(points: Array) -> float:
	if points.size() < 3:
		return 0.0
	var twice_area := 0.0
	for index in points.size():
		var current: Vector2 = points[index]
		var next: Vector2 = points[(index + 1) % points.size()]
		twice_area += current.x * next.y - next.x * current.y
	return absf(twice_area) * 0.5


## Sort key for painter's-algorithm ordering. Sprites are drawn in ascending
## order, so a larger key means "further forward, drawn later, on top".
##
## Elevation is only a tie-breaker. Two agents at the same ground depth should
## keep their order regardless of the ground under them; what hides an agent
## behind a hill is the terrain layer's own z_index, not this key.
static func depth_sort_key(world_position: Vector2, height_level: int = 0) -> float:
	if _mode == Mode.ORTHOGONAL:
		return world_position.y
	return (world_position.x + world_position.y) * 0.5 + float(height_level) * 0.001


## True while the projection is a no-op.
static func is_identity() -> bool:
	return _mode == Mode.ORTHOGONAL
