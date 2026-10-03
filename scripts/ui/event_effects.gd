class_name EventEffects
extends Node2D

## Draws what just happened where it happened: dust behind the animals in a chase, the
## burst of a kill, a ring at a birth on the ground; the flash of the blow and the
## sparkles of a birth in the air above. The marks live in an `EffectQueue`; the
## `AgentSpriteRenderer` that owns this node adds them and moves the clock.
##
## The node draws on the ground: a child of the renderer just above the shadows and below
## the sprites, darkened at night with the ground it lies on. In a pond the dust is spray.
## The air is a child drawn above the sprites with added light, unshaded like the animals,
## so a flash stays a flash at midnight. Sizes are art pixels scaled by the map's cell
## size, as sprites are. Everything runs on the view's clock and stands still while the
## game is paused. Nothing here touches the simulation.

const EffectQueueScript := preload("res://scripts/ui/effect_queue.gd")
const DUST := EffectQueueScript.Kind.DUST
const BURST := EffectQueueScript.Kind.BURST
const FLASH := EffectQueueScript.Kind.FLASH
const RING := EffectQueueScript.Kind.RING
const SPARKLE := EffectQueueScript.Kind.SPARKLE
## Layers relative to the renderer: shadows draw at -2, the sprites at 0, and `WorldView`'s
## rings and labels above the renderer.
const GROUND_Z := -1
const AIR_Z := 1
## `visuals.effects` when a key is missing. Colours are RGBA; `*_px` are art pixels.
const DEFAULTS := {
	"max_active": 160,
	"dust": {
		"enabled": true, "species": ["herbivore", "predator"], "spacing_px": 8.0, "size_px": 7.0,
		"seconds": 0.75, "rise_px": 6.0, "color": [0.92, 0.87, 0.74, 0.75], "splash_color": [0.88, 0.95, 0.99, 0.7],
	},
	"kill": {
		"enabled": true, "puffs": 8, "size_px": 9.0, "spread_px": 22.0, "seconds": 0.6,
		"color": [0.93, 0.88, 0.76, 0.9], "flash_px": 20.0, "flash_seconds": 0.2,
		"flash_color": [1.0, 0.82, 0.7, 0.8],
	},
	"birth": {
		"enabled": true, "ring_px": 13.0, "seconds": 0.8, "ring_color": [1.0, 0.95, 0.72, 0.85],
		"sparkles": 5, "sparkle_px": 2.0, "sparkle_rise_px": 14.0, "sparkle_color": [1.0, 0.95, 0.72, 0.8],
		"pop_seconds": 0.3, "pop_from": 0.35,
	},
}

var queue = EffectQueueScript.new()
var renderer = null
var dust: Dictionary = {}
var kill: Dictionary = {}
var birth: Dictionary = {}
var dust_species: Dictionary = {}
## Ground an animal covers between two puffs, in world units.
var dust_spacing: float = 27.0
var _scale: float = 1.0
var _now: float = 0.0
var _air: Node2D = null
var _puff: Texture2D = null
## A redraw is owed: marks are alive, or the last one just went and has to be wiped.
var _drawn: bool = false
## A mark was added since the last redraw.
var _dirty: bool = false


func configure(owner_renderer, effects: Dictionary, world_scale: float) -> void:
	renderer = owner_renderer
	_scale = maxf(0.01, world_scale)
	dust = resolve(effects, "dust")
	kill = resolve(effects, "kill")
	birth = resolve(effects, "birth")
	dust_species.clear()
	for species_id in dust.get("species", []):
		dust_species[str(species_id)] = true
	dust_spacing = maxf(1.0, float(dust["spacing_px"]) * _scale)
	queue.capacity = maxi(0, int(effects.get("max_active", DEFAULTS["max_active"])))
	z_index = GROUND_Z
	texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	_puff = soft_puff()
	if _air == null:
		_air = Node2D.new()
		_air.name = "Air"
		_air.z_index = AIR_Z - GROUND_Z
		var material := CanvasItemMaterial.new()
		material.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
		material.light_mode = CanvasItemMaterial.LIGHT_MODE_UNSHADED
		_air.material = material
		_air.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
		_air.draw.connect(_draw_air)
		add_child(_air)


## One block of `visuals.effects` over its defaults, so a save made before a key existed
## still draws.
static func resolve(effects: Dictionary, block: String) -> Dictionary:
	var resolved: Dictionary = DEFAULTS[block].duplicate(true)
	var given = effects.get(block, {})
	if given is Dictionary:
		resolved.merge(given, true)
	return resolved


## A white disc, solid most of the way out and soft at its rim, tinted per mark when drawn.
static func soft_puff() -> Texture2D:
	var gradient := Gradient.new()
	gradient.set_color(0, Color(1.0, 1.0, 1.0, 1.0))
	gradient.set_color(1, Color(1.0, 1.0, 1.0, 0.0))
	gradient.add_point(0.55, Color(1.0, 1.0, 1.0, 0.85))
	var texture := GradientTexture2D.new()
	texture.gradient = gradient
	texture.fill = GradientTexture2D.FILL_RADIAL
	texture.fill_from = Vector2(0.5, 0.5)
	texture.fill_to = Vector2(1.0, 0.5)
	texture.width = 64
	texture.height = 64
	return texture


## A puff of dust kicked up at `position` by an animal running along `heading` (world
## space), drifting back from it and rising; spray in a pond. `seed_a`/`seed_b` scatter it.
func add_dust(position: Vector2, heading: Vector2, start: float, seed_a: int, seed_b: int) -> bool:
	if not bool(dust.get("enabled", true)):
		return false
	var back := Vector2.ZERO
	if heading.length_squared() > 0.0001:
		# Projected, so the puff trails the animal on screen in the isometric view too.
		back = -(renderer._anchor(position + heading.normalized() * 16.0, 0.0) - renderer._anchor(position, 0.0)).normalized()
	var spread := (EffectQueueScript.jitter(seed_a, seed_b) - 0.5) * 2.0
	var drift := (back * 4.0 + Vector2(spread * 3.0, -float(dust["rise_px"]))) * _scale
	var size := float(dust["size_px"]) * (0.8 + 0.4 * EffectQueueScript.jitter(seed_b, seed_a)) * _scale
	return _add(DUST, position, start, float(dust["seconds"]), size, drift, 0.0, _ground_tint(position, dust["color"]))


## The burst of a kill: puffs thrown out along the ground around the body, and a flash
## `lift` above the ground point, where the body is drawn.
func add_kill(position: Vector2, start: float, seed_value: int, lift := 0.0) -> void:
	if not bool(kill.get("enabled", true)):
		return
	var tint := _ground_tint(position, kill["color"])
	var puffs := maxi(0, int(kill["puffs"]))
	for index in range(puffs):
		var angle := TAU * (float(index) + EffectQueueScript.jitter(seed_value, index)) / float(maxi(1, puffs))
		var reach := float(kill["spread_px"]) * (0.7 + 0.6 * EffectQueueScript.jitter(index, seed_value)) * _scale
		# Flattened like the ground it runs along.
		var drift := Vector2(cos(angle), sin(angle) * 0.55) * reach
		_add(BURST, position, start, float(kill["seconds"]), float(kill["size_px"]) * _scale, drift, 0.0, tint)
	_add(FLASH, position, start, float(kill["flash_seconds"]), float(kill["flash_px"]) * _scale, Vector2.ZERO, lift,
		_color(kill["flash_color"]))


## A ring opening on the ground where a young animal was born, and sparkles rising.
func add_birth(position: Vector2, start: float, seed_value: int) -> void:
	if not bool(birth.get("enabled", true)):
		return
	_add(RING, position, start, float(birth["seconds"]), float(birth["ring_px"]) * _scale, Vector2.ZERO, 0.0,
		_color(birth["ring_color"]))
	var sparkles := maxi(0, int(birth["sparkles"]))
	for index in range(sparkles):
		var across := (EffectQueueScript.jitter(seed_value, index) - 0.5) * float(birth["ring_px"]) * 1.4
		var rise := float(birth["sparkle_rise_px"]) * (0.6 + 0.6 * EffectQueueScript.jitter(index, seed_value))
		var delay := 0.25 * float(birth["seconds"]) * EffectQueueScript.jitter(seed_value + 7, index)
		_add(SPARKLE, position, start + delay, float(birth["seconds"]) * 0.75,
			float(birth["sparkle_px"]) * _scale, Vector2(across, -rise) * _scale, 0.0, _color(birth["sparkle_color"]))


func _add(kind: int, position: Vector2, start: float, seconds: float, size: float, drift: Vector2, lift: float,
		tint: Color) -> bool:
	var accepted: bool = queue.add(kind, position, start, seconds, size, drift, lift, tint)
	_dirty = _dirty or accepted
	return accepted


## The colour of what a running animal throws up at `position`: dust, or spray in a pond.
func _ground_tint(position: Vector2, colour) -> Color:
	return _color(dust["splash_color"]) if _in_water(position) else _color(colour)


## Inside a watering hole. Ponds are discs, as `WaterMask` draws them before its noise.
func _in_water(position: Vector2) -> bool:
	if renderer == null or renderer.simulation_manager == null or renderer.simulation_manager.world_state == null:
		return false
	for source in renderer.simulation_manager.world_state.water_sources:
		var radius := float(source.get("radius", 0.0))
		if position.distance_squared_to(source.get("position", Vector2.INF)) <= radius * radius:
			return true
	return false


## How big a newborn is drawn `elapsed` seconds after it was born: from `pop_from` up past
## full size and back, settling at 1 when `pop_seconds` are up.
static func pop_scale(elapsed: float, seconds: float, from: float) -> float:
	if seconds <= 0.0 or elapsed >= seconds:
		return 1.0
	var t := clampf(elapsed / seconds, 0.0, 1.0) - 1.0
	# An ease-out that overshoots by about 3% (easeOutBack with a softer swing).
	var swing := 1.2
	var eased := 1.0 + (swing + 1.0) * t * t * t + swing * t * t
	return lerpf(from, 1.0, eased)


## Moves the marks to `now` and redraws while any are alive, and once more after the last
## one goes so it does not linger on screen.
func advance(now: float) -> void:
	var moved := not is_equal_approx(now, _now)
	_now = now
	var alive: bool = queue.advance(now)
	if (alive and (moved or _dirty)) or (not alive and _drawn):
		queue_redraw()
		_air.queue_redraw()
	_drawn = alive
	_dirty = false


## Drops every mark and wipes them from the screen: overview, a new world, new art.
func clear() -> void:
	queue.clear()
	if _drawn:
		queue_redraw()
		if _air != null:
			_air.queue_redraw()
	_drawn = false


func _draw() -> void:
	if renderer == null:
		return
	for item in queue.items():
		var t := EffectQueueScript.progress(item, _now)
		if t < 0.0:
			continue
		var kind := int(item["kind"])
		if kind == DUST:
			_draw_puff(item, t, 0.6, 0.7, 0.0)
		elif kind == BURST:
			# Starting a third of the way out, so the burst shows around the body, not under it.
			_draw_puff(item, t, 0.7, 0.6, 0.3)
		elif kind == RING:
			_draw_ring(item, t)


func _draw_air() -> void:
	if renderer == null:
		return
	for item in queue.items():
		var t := EffectQueueScript.progress(item, _now)
		if t < 0.0:
			continue
		var kind := int(item["kind"])
		var colour: Color = item["tint"]
		if kind == FLASH:
			colour.a *= pow(1.0 - t, 2.0)
			var radius := float(item["size"]) * (0.55 + 0.45 * t)
			_air.draw_texture_rect(_puff, Rect2(_ground(item) - Vector2(radius, radius * 1.1),
				Vector2(radius * 2.0, radius * 2.2)), false, colour)
		elif kind == SPARKLE:
			colour.a *= sin(PI * t)
			var centre: Vector2 = _ground(item) + (item["drift"] as Vector2) * t
			var radius := float(item["size"]) * (1.0 - 0.4 * t)
			_air.draw_texture_rect(_puff, Rect2(centre - Vector2(radius, radius), Vector2(radius, radius) * 2.0), false, colour)
			# A thin cross makes the speck glint rather than glow.
			var arm := radius * 1.4
			colour.a *= 0.7
			var width := maxf(1.0, radius * 0.2)
			_air.draw_line(centre - Vector2(arm, 0.0), centre + Vector2(arm, 0.0), colour, width)
			_air.draw_line(centre - Vector2(0.0, arm), centre + Vector2(0.0, arm), colour, width)


## A soft puff thrown out along `drift` over its life - fast at first, from `reach_from`
## of the way out - swelling by `growth` and fading; `flatten` lays it along the ground.
func _draw_puff(item: Dictionary, t: float, growth: float, flatten: float, reach_from: float) -> void:
	var colour: Color = item["tint"]
	# In fast and out slowly, so the puff reads as kicked up rather than switched on.
	colour.a *= smoothstep(0.0, 0.1, t) * (1.0 - t)
	var travelled := lerpf(reach_from, 1.0, 1.0 - pow(1.0 - t, 2.0))
	var radius := float(item["size"]) * (0.7 + growth * t)
	var centre: Vector2 = _ground(item) + (item["drift"] as Vector2) * travelled
	draw_texture_rect(_puff, Rect2(centre - Vector2(radius, radius * flatten),
		Vector2(radius * 2.0, radius * 2.0 * flatten)), false, colour)


## A ring lying on the ground, opening and fading: sampled in world space and projected,
## so it lies in the ground plane as the selection ring does.
func _draw_ring(item: Dictionary, t: float) -> void:
	var colour: Color = item["tint"]
	colour.a *= pow(1.0 - t, 1.3)
	var eased := 1.0 - pow(1.0 - t, 3.0)
	var radius := float(item["size"]) * (0.35 + 0.95 * eased)
	var origin: Vector2 = item["position"]
	var points := PackedVector2Array()
	for step in range(25):
		var angle := TAU * float(step) / 24.0
		points.append(renderer._anchor(origin + Vector2(cos(angle), sin(angle)) * radius, 0.0))
	draw_polyline(points, colour, maxf(1.0, 1.4 * _scale * (1.0 - 0.5 * t)), true)


func _ground(item: Dictionary) -> Vector2:
	return renderer._anchor(item["position"], float(item.get("lift", 0.0)))


static func _color(rgba) -> Color:
	if rgba is Color:
		return rgba
	if rgba is Array and rgba.size() >= 3:
		return Color(float(rgba[0]), float(rgba[1]), float(rgba[2]), float(rgba[3]) if rgba.size() > 3 else 1.0)
	return Color.WHITE
