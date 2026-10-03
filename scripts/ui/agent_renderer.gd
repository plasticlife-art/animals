class_name AgentSpriteRenderer
extends Node2D

## Draws living agents and carcasses as animated sprites.
##
## Agents are `RefCounted` objects rather than nodes, so there is nothing to
## hang an `AnimatedSprite2D` on - and at 1500 agents that many nodes would be
## the wrong answer anyway. Instead each species gets one `MultiMeshInstance2D`
## and the animation frame travels per instance in custom data, read back by
## shaders/agent_atlas.gdshader.
##
## Nothing here writes to the simulation. The animation frame is derived from
## fields the simulation already maintains - state, action, velocity, id - and
## from the simulation clock, so no visual state is stored on `AgentBase` and
## headless runs stay bit-identical.
##
## The per-species batches keep atlas metadata, while `SceneSpriteBatch` packs
## their textures with props and carcasses into one runtime atlas. That common
## MultiMesh gives exact painter ordering across every visible ground object
## without creating a node per animal or losing cheap art-pack swaps.

const INSTANCE_GROW_CHUNK := 256
## Below this much drawn movement in a tick there is no direction to read, and
## the sprite holds the way it was already facing. 0.05 px is what an animal
## crawling at 1 px/s covers in a tick at the default rate - the same floor the
## old velocity test used, restated in the units that are now measured.
const _DRAWN_STEP_EPSILON_SQ := 0.0025

## Where the ground-distance accumulator behind the walk cycle wraps. The wrap
## is not stride-aligned, so it does skip a frame - once per agent per million
## pixels walked, which is hours of running at species speeds, against a float
## that would otherwise coarsen without bound over a long session.
const _GAIT_WRAP_PX := 1048576.0
const SHADOW_Z := -2
const CARCASS_Z := -1
# Draw layer per species now comes from `visuals.json -> species.<id>.z`, beside
# the atlas it belongs to. A hardcoded table here meant a new species silently
# shared layer 0 with the herbivores and sorted against them by accident.
const DEFAULT_SPECIES_Z := 0
const DyingSpritesScript := preload("res://scripts/ui/dying_sprites.gd")
const EventEffectsScript := preload("res://scripts/ui/event_effects.gd")

var scene_batch = null
## Animals that died in view, played through their `dead` row (`DyingSprites`).
var _dying = DyingSpritesScript.new()
## Dust, the burst of a kill and the marks of a birth (`EventEffects`), drawn on the ground
## under the sprites and in the air above them.
var _effects = null
## Newborns still growing in, by id: when each was first drawn, on the view's clock.
var _born: Dictionary = {}
## Ground covered (`_gait_distance`) when each running animal last kicked up dust.
var _dust_mark: Dictionary = {}
## The view's clock this frame (`SimulationManager.get_display_time()`).
var _now: float = 0.0
## What the last refresh treated as in view, in world space.
var _visible_rect := Rect2()
var _needs_refresh: bool = true
var _last_camera_rect := Rect2()
var _render_positions: Dictionary = {}
var simulation_manager: SimulationManager

var _batches: Dictionary = {}
var _carcass_batch: Dictionary = {}
var _walk_speed_threshold: float = 8.0
var _run_speed_threshold: float = 85.0
var _phase_step: float = 0.37
var _buckets: Dictionary = {}
## Cached per refresh so the height lookups below do not walk the world each
## time. Only read; the simulation never learns this node exists.
var _terrain = null
## Per-agent render state, keyed by agent id. `_history` holds the last four
## tick positions so the curve below has neighbours on both sides; `_phase` is
## the fps-driven animation position; `_facing` is the sticky mirror direction.
##
## `_drawn_speed` and `_gait_distance` are derived from `_history` rather than
## from `agent.velocity`, and everything the eye can compare against the drawn
## motion - which animation plays, how fast the legs cycle, which way the sprite
## looks - reads them. Velocity and drawn motion disagree more often than it
## seems: a body pressed against terrain keeps its velocity while
## `resolve_movement_position()` denies the step, `_resolve_agent_overlap()`
## moves `position` without touching `velocity`, and a paused simulation leaves
## velocity frozen at whatever it was. Animating from velocity made all three
## walk on the spot.
var _history: Dictionary = {}
var _phase: Dictionary = {}
var _drawn_speed: Dictionary = {}
var _gait_distance: Dictionary = {}
var _facing: Dictionary = {}
var _heading: Dictionary = {}
var _direction: Dictionary = {}
var _direction_hysteresis: float = 0.25
var _turn_lerp: float = 9.0
var _facing_deadzone: float = 0.18
var _teleport_distance_sq: float = 220.0 * 220.0
var _age_scale: Dictionary = {}
var _idle_bob_px: float = 0.0
var _shadow_node: MultiMeshInstance2D = null
var _shadow_scale: float = 0.55
var _shadow_bias: float = 2.0
var _shadow_agents: Array = []
var _marker_phase: float = 0.0
var overview_mode: bool = false
var _overview_config: Dictionary = {}
var render_generation: int = 0


func bind_manager(manager: SimulationManager) -> void:
	simulation_manager = manager
	_overview_config = manager.config_bundle.get("visuals", {}).get("overview_lod", {})
	if _batches.is_empty():
		_build_batches()
	# Guarded: the setup screen can start a new simulation on the same manager,
	# and a second unguarded connect is an error, not a no-op.
	if not simulation_manager.tick_completed.is_connected(_on_tick_completed):
		simulation_manager.tick_completed.connect(_on_tick_completed)
	if not simulation_manager.world_event.is_connected(_on_world_event):
		simulation_manager.world_event.connect(_on_world_event)
	refresh()


func set_overview_mode(value: bool) -> void:
	if overview_mode == value:
		return
	overview_mode = value
	_needs_refresh = true
	# Overview draws frozen idle frames a few pixels tall; nothing that happens there is shown.
	_dying.clear()
	_born.clear()
	_dust_mark.clear()
	if _effects != null:
		_effects.clear()
	if _shadow_node != null:
		_shadow_node.visible = not (value and bool(_overview_config.get("disable_shadows", true)))


## Throw away the sprite batches and build them again from the current visuals.
##
## `bind_manager` deliberately skips `_build_batches()` once batches exist, so a
## style preset that swaps atlases, frame sizes or animation rows needs this.
## Repainting is not enough - the geometry itself changed.
func rebuild_batches() -> void:
	if scene_batch != null:
		remove_child(scene_batch)
		scene_batch.queue_free()
		scene_batch = null
	for child in [_shadow_node, _effects]:
		if child != null:
			remove_child(child)
			child.queue_free()
	_shadow_node = null
	_effects = null
	for entry in _batches.values():
		var node = entry.get("node")
		if node != null:
			remove_child(node)
			node.queue_free()
	var carcass_node = _carcass_batch.get("node")
	if carcass_node != null:
		remove_child(carcass_node)
		carcass_node.queue_free()
	_batches.clear()
	_carcass_batch.clear()
	_history.clear()
	_phase.clear()
	_drawn_speed.clear()
	_gait_distance.clear()
	_facing.clear()
	_heading.clear()
	_direction.clear()
	_dying.clear()
	_born.clear()
	_dust_mark.clear()
	_build_batches()
	refresh()


func request_refresh() -> void:
	refresh()


## The dying sprites the scene batch draws beside the living (`DyingSprites.states()`).
func transient_sprites() -> Array:
	return _dying.states()


func transient_sprite(key: int) -> Dictionary:
	return _dying.state(key)


## True while the animal that left this carcass is still being shown dying, so the
## scene batch draws the animal falling instead of the body already lying there.
func hides_carcass(source_agent_id: int) -> bool:
	return _dying.hides_carcass(source_agent_id)


## What the view shows of an event, when the player could see it. Only awake animals are
## drawn, so an event from a sleeping sector (`agent_id` -1) has nothing to play on.
func _on_world_event(event: Dictionary) -> void:
	if simulation_manager == null or _batches.is_empty() or overview_mode:
		return
	var agent_id := int(event.get("agent_id", -1))
	if agent_id < 0:
		return
	match str(event.get("type", "")):
		"AgentDied":
			_on_agent_died(event, agent_id)
		"AgentBorn":
			_on_agent_born(event, agent_id)


## An animal drawn in the last refresh died: it falls through its `dead` row, and a kill
## throws up a burst with a flash where the blow fell.
func _on_agent_died(event: Dictionary, agent_id: int) -> void:
	var batch: Dictionary = _batches.get(str(event.get("species", "")), {})
	var agent = _find_batched_agent(batch, agent_id)
	# Not in the last refresh's visible set: it died off screen.
	if agent == null:
		return
	var died_at := _event_position(event)
	var start := _event_start(event)
	var cause := str(event.get("data", {}).get("cause", ""))
	if cause == "predation" and _effects != null:
		_effects.add_kill(died_at, start, agent_id, float(batch.get("ground_offset", 0.0)) * _age_scale_of(agent))
	var spec: Dictionary = batch.get("animations", {}).get("dead", {})
	if spec.is_empty():
		return
	var directions: int = int(batch.get("directions", 1))
	var row := int(spec.get("row", 0)) + (int(_direction.get(agent_id, 0)) if directions > 1 else 0)
	var facing: float = 1.0 if directions > 1 else float(_facing.get(agent_id, 1.0))
	var frames: PackedInt32Array = DyingSpritesScript.frames_for(cause, spec)
	if _dying.begin(agent_id, str(event.get("species", "")), _render_positions.get(agent_id, died_at), died_at,
			row, frames, _age_scale_of(agent), facing, float(batch.get("ground_offset", 0.0)), start,
			simulation_manager.tick_duration * 2.0):
		_needs_refresh = true


## A young animal born in view grows in from small, over a ring and sparkles. Animals made
## any other way - the founders, a test - just appear.
func _on_agent_born(event: Dictionary, agent_id: int) -> void:
	if _effects == null or str(event.get("data", {}).get("reason", "")) != "reproduction":
		return
	var born_at := _event_position(event)
	if not _visible_rect.has_point(born_at) or not bool(_effects.birth.get("enabled", true)):
		return
	var start := _event_start(event)
	_born[agent_id] = start
	_effects.add_birth(born_at, start, agent_id)


static func _event_position(event: Dictionary) -> Vector2:
	var at: Dictionary = event.get("position", {})
	return Vector2(float(at.get("x", 0.0)), float(at.get("y", 0.0)))


## When the view first draws the tick an event happened in. Read from the event rather than
## the clock: the tick alpha is stale while a frame is being applied, and the event's tick
## is the one about to be drawn.
func _event_start(event: Dictionary) -> float:
	return float(event.get("time_seconds", simulation_manager.simulation_time)) + simulation_manager.tick_duration


## How large a newborn is drawn now, as a share of its full size; 1 once it has grown in.
func _pop_of(agent_id: int) -> float:
	if _born.is_empty() or not _born.has(agent_id):
		return 1.0
	var seconds: float = float(_effects.birth.get("pop_seconds", 0.3)) if _effects != null else 0.0
	var elapsed: float = _now - float(_born[agent_id])
	if elapsed >= seconds:
		_born.erase(agent_id)
		return 1.0
	return EventEffectsScript.pop_scale(maxf(elapsed, 0.0), seconds, float(_effects.birth.get("pop_from", 0.35)))


## An animal in a chase: the hunter running its prey down, or the prey running for it.
static func _in_chase(agent) -> bool:
	return agent.ai_state == &"panic" or agent.current_action == &"flee_to_safe_area" \
		or agent.current_action == &"hunt_prey"


## One puff of dust behind a running animal per `dust_spacing` of ground it covers, so a
## faster animal raises more and one held in place raises none.
func _kick_dust(agent, drawn_at: Vector2) -> void:
	var id: int = agent.id
	var covered := float(_gait_distance.get(id, 0.0))
	var mark = _dust_mark.get(id)
	# The first stride of a run, or the distance wrapped: start counting from here.
	if mark == null or covered < float(mark):
		_dust_mark[id] = covered
		return
	if covered - float(mark) < _effects.dust_spacing:
		return
	_dust_mark[id] = covered
	var step: Vector2 = _drawn_step(agent)
	var heading := step.normalized() if step.length_squared() > _DRAWN_STEP_EPSILON_SQ else Vector2.ZERO
	_effects.add_dust(drawn_at - heading * agent.get_body_radius() * 0.6, heading, _now, id, int(covered))


static func _find_batched_agent(batch: Dictionary, agent_id: int):
	for agent in batch.get("agents", []):
		if agent != null and int(agent.id) == agent_id:
			return agent
	return null


func refresh() -> void:
	if simulation_manager == null or simulation_manager.world_state == null:
		return
	if _batches.is_empty():
		return

	var world = simulation_manager.world_state
	_terrain = world.terrain_system
	var visible_rect: Rect2 = _get_visible_world_rect(world.bounds).grow(48.0)
	_visible_rect = visible_rect

	for species_id in _buckets.keys():
		_buckets[species_id].clear()
	for agent in world.get_living_agents():
		if agent == null:
			continue
		if not visible_rect.has_point(agent.position):
			continue
		# An unknown species has no batch to draw into, so it is skipped rather
		# than appended to a throwaway array.
		if not _buckets.has(agent.species_type):
			continue
		_buckets[agent.species_type].append(agent)

	# Depth ordering is decided across the whole visible set, not per species,
	# because a predator standing behind a hill has to be hidden by the animals
	# in front of it regardless of what they are.
	_shadow_agents.clear()
	for species_id in _batches.keys():
		var bucket: Array = _buckets.get(species_id, [])
		_fill_species(species_id, bucket)
		_shadow_agents.append_array(bucket)
	_fill_shadows()

	_fill_carcasses(world, visible_rect)
	render_generation += 1


func _fill_species(species_id: String, agents: Array) -> void:
	var batch: Dictionary = _batches[species_id]
	var multimesh: MultiMesh = batch["multimesh"]
	if agents.is_empty():
		multimesh.visible_instance_count = 0
		batch["node"].visible = false
		return
	# The common scene batch is the visible owner once it exists. Species batches
	# remain as atlas/mesh metadata only; drawing and writing them as well would
	# duplicate every animal and double the per-frame MultiMesh traffic.
	batch["node"].visible = scene_batch == null

	if scene_batch == null:
		# The fallback species batch needs its own painter order. The common scene
		# batch sorts all species with scenery later, so sorting here as well was a
		# duplicate per-species pass on every simulation tick.
		agents.sort_custom(_compare_depth)
		_ensure_capacity(multimesh, agents.size())
		# Only the slowly changing part is written here. Transforms and animation
		# frames belong to `_process`, which runs at the display rate.
		for index in range(agents.size()):
			multimesh.set_instance_color(index, _resolve_tint(agents[index]))
	batch["agents"] = agents
	multimesh.visible_instance_count = agents.size() if scene_batch == null else 0


## Shadows are one batch for every species: they are identical blobs, and the
## fewer canvas items the layer costs, the better. Their transforms are written
## per frame alongside the sprites so they never lag behind an animal.
func _fill_shadows() -> void:
	if _shadow_node == null:
		return
	var multimesh: MultiMesh = _shadow_node.multimesh
	if _shadow_agents.is_empty():
		multimesh.visible_instance_count = 0
		return
	_ensure_capacity(multimesh, _shadow_agents.size())
	for index in range(_shadow_agents.size()):
		multimesh.set_instance_color(index, Color.WHITE)
	multimesh.visible_instance_count = _shadow_agents.size()


func _animate_shadows(alpha: float) -> void:
	if _shadow_node == null or _shadow_agents.is_empty() or not _shadow_node.visible:
		return
	var multimesh: MultiMesh = _shadow_node.multimesh
	for index in range(_shadow_agents.size()):
		var agent = _shadow_agents[index]
		if agent == null or not agent.is_alive:
			continue
		var scale_factor: float = _shadow_scale * _age_scale_of(agent) * _pop_of(agent.id)
		# Anchored to the ground point, never to the sprite: a bobbing animal
		# should look like it is lifting off its shadow, not dragging it.
		var ground: Vector2 = _anchor(_curve_position(agent, alpha), 0.0)
		multimesh.set_instance_transform_2d(index, Transform2D(
			Vector2(scale_factor, 0.0),
			Vector2(0.0, scale_factor),
			ground + Vector2(0.0, _shadow_bias)
		))
	multimesh.visible_instance_count = _shadow_agents.size()


## Young animals are visibly smaller and old ones slightly larger. The stage is
## already tracked by the simulation, so a herd stops looking cloned for free.
func _age_scale_of(agent) -> float:
	if _age_scale.is_empty() or not agent.has_method("get_age_stage"):
		return 1.0
	return float(_age_scale.get(agent.get_age_stage(), 1.0))


func _fill_carcasses(world, visible_rect: Rect2) -> void:
	if _carcass_batch.is_empty():
		return
	var multimesh: MultiMesh = _carcass_batch["multimesh"]
	if scene_batch != null:
		multimesh.visible_instance_count = 0
		_carcass_batch["node"].visible = false
		return
	var stages: int = maxi(1, int(_carcass_batch["stages"]))
	var visible_carcasses: Array = []
	for carcass_id in world.carcasses.keys():
		var carcass: Dictionary = world.carcasses[carcass_id]
		var position: Vector2 = carcass.get("position", Vector2.ZERO)
		if not visible_rect.has_point(position):
			continue
		visible_carcasses.append(carcass)

	if visible_carcasses.is_empty():
		multimesh.visible_instance_count = 0
		_carcass_batch["node"].visible = false
		return
	_carcass_batch["node"].visible = true

	_ensure_capacity(multimesh, visible_carcasses.size())
	for index in range(visible_carcasses.size()):
		var carcass: Dictionary = visible_carcasses[index]
		var total: float = maxf(0.001, float(carcass.get("meat_total", 1.0)))
		var remaining: float = clampf(float(carcass.get("meat_remaining", 0.0)) / total, 0.0, 1.0)
		var stage: int = clampi(int((1.0 - remaining) * float(stages)), 0, stages - 1)
		multimesh.set_instance_transform_2d(index, Transform2D(
			0.0,
			_anchor(carcass.get("position", Vector2.ZERO), float(_carcass_batch["ground_offset"]))
		))
		multimesh.set_instance_color(index, Color.WHITE)
		multimesh.set_instance_custom_data(index, Color(float(stage), 0.0, 0.0, 0.0))
	multimesh.visible_instance_count = visible_carcasses.size()


## Collapses the thirteen possible actions onto the five animation rows the
## atlas actually has. Speed is the main signal rather than an action
## whitelist, so adding a new action later degrades to walk/idle instead of
## breaking.
##
## The speed is the one the viewer can see - ground actually covered since the
## last tick - so an animal that wants to run but is not getting anywhere stands
## still instead of sprinting on the spot. That outranks the action override:
## a predator shoving against a body it cannot pass is in `hunt_prey` the whole
## time it is stuck.
func _resolve_animation(agent) -> String:
	if not agent.is_alive or agent.ai_state == &"dead":
		return "dead"
	var speed: float = float(_drawn_speed.get(agent.id, 0.0))
	var moving: bool = speed >= _walk_speed_threshold
	var action: StringName = agent.current_action
	if moving and (agent.ai_state == &"panic" or action == &"flee_to_safe_area" or action == &"hunt_prey"):
		return "run"
	if action == &"graze" or action == &"scavenge_carcass" or action == &"drink":
		return "eat"
	if not moving:
		return "idle"
	if speed >= _run_speed_threshold:
		return "run"
	return "walk"


## Species identity now lives in the art, so the sprite is drawn untinted. The
## LOD debug tint from the old `world_view.gd::_get_agent_draw_color()` is kept,
## since that overlay is the one case where the color has to override the art.
func _resolve_tint(agent) -> Color:
	if not bool(simulation_manager.debug_flags.get("show_lod_overlay", false)):
		return Color.WHITE
	match int(agent.lod_tier):
		1:
			return Color(0.98, 0.8, 0.28)
		2:
			return Color(0.95, 0.45, 0.45)
		_:
			return Color(0.74, 0.93, 0.78)


func _compare_depth(a, b) -> bool:
	return _depth_of(a.position) < _depth_of(b.position)


## Where an agent is being drawn this frame, in simulation space. Anything that
## has to sit on a moving animal - the selection marker, the follow camera -
## must use this rather than `agent.position`: the raw position steps at the
## tick rate while the sprite glides between ticks, and the difference reads as
## jitter around an otherwise smooth animal.
## The selection marker, drawn by this node itself rather than by a sibling.
##
## A CanvasItem paints its own content before its children, so drawing here puts
## the ring beneath the sprite batches while still above the shadows. That is
## what a mark on the ground should do: the animal stands inside it, not behind
## it. Drawn from `WorldView` - a node above the agents - the ring covered the
## animal instead.
func _draw() -> void:
	if simulation_manager == null or simulation_manager.world_state == null:
		return
	var agent = simulation_manager.get_selected_agent()
	if agent == null or not agent.is_alive:
		return

	var origin: Vector2 = get_render_position(agent)
	var level: int = _height_at(origin)
	var pulse: float = 0.5 + 0.5 * sin(_marker_phase * 2.2)
	# Sampled in simulation space and projected, so the ring lies in the ground
	# plane instead of facing the camera like a sticker.
	_draw_ground_ring(origin, level, 15.0 + pulse * 2.0,
		Color(0.98, 0.86, 0.52, 0.34 + pulse * 0.28), 1.6)
	_draw_ground_ring(origin, level, (15.0 + pulse * 2.0) * 0.62,
		Color(0.98, 0.86, 0.52, 0.13 + pulse * 0.1), 1.0)


func _draw_ground_ring(origin: Vector2, level: int, radius: float, color: Color, width: float) -> void:
	var points := PackedVector2Array()
	for step in range(29):
		var angle := TAU * float(step) / 28.0
		points.append(WorldProjection.to_screen(
			origin + Vector2(cos(angle), sin(angle)) * radius, level))
	draw_polyline(points, color, width)


func get_render_position(agent) -> Vector2:
	if agent == null or simulation_manager == null:
		return Vector2.ZERO
	return _curve_position(agent, simulation_manager.get_tick_alpha())


func _height_at(world_position: Vector2) -> int:
	if _terrain == null or WorldProjection.is_identity():
		return 0
	return _terrain.get_height_at_position(world_position)


func _depth_of(world_position: Vector2) -> float:
	return WorldProjection.depth_sort_key(world_position, _height_at(world_position))


## Where a sprite is pinned. Top-down art is centred on the agent, but under an
## angled projection an animal stands on the ground rather than hovering over
## it, so the quad is lifted by half its height to put its feet on the cell.
func _anchor(world_position: Vector2, ground_offset: float) -> Vector2:
	var point: Vector2 = WorldProjection.to_screen(world_position, _height_at(world_position))
	point.y -= ground_offset
	return point


## `instance_count` reallocates and drops the instance buffer, so it is grown in
## chunks and never shrunk. `visible_instance_count` carries the per-refresh
## count instead.
func _ensure_capacity(multimesh: MultiMesh, needed: int) -> void:
	if multimesh.instance_count >= needed:
		return
	var grown: int = multimesh.instance_count + INSTANCE_GROW_CHUNK
	multimesh.instance_count = maxi(needed, grown)


func _build_batches() -> void:
	var visuals: Dictionary = {}
	if simulation_manager != null:
		visuals = simulation_manager.config_bundle.get("visuals", {})
	var animation_config: Dictionary = visuals.get("animation", {})
	_turn_lerp = maxf(0.1, float(animation_config.get("turn_lerp_per_second", 9.0)))
	_facing_deadzone = clampf(float(animation_config.get("facing_deadzone", 0.18)), 0.0, 0.9)
	_direction_hysteresis = maxf(0.0, float(animation_config.get("direction_hysteresis", 0.25)))
	var teleport: float = maxf(1.0, float(animation_config.get("teleport_distance", 220.0)))
	_teleport_distance_sq = teleport * teleport
	_idle_bob_px = maxf(0.0, float(animation_config.get("idle_bob_px", 0.0)))
	_age_scale = visuals.get("age_scale", {})
	_walk_speed_threshold = float(animation_config.get("walk_speed_threshold", 8.0))
	_run_speed_threshold = float(animation_config.get("run_speed_threshold", 85.0))
	_phase_step = float(animation_config.get("phase_step", 0.37))
	_dying.configure(visuals.get("effects", {}).get("death", {}))

	var species_config: Dictionary = visuals.get("species", {})
	for species_id in species_config.keys():
		var config: Dictionary = species_config[species_id]
		var animations: Dictionary = config.get("animations", {})
		var species_directions: int = maxi(1, int(config.get("directions", 1)))
		var rows: int = 1
		var columns: int = 1
		for animation_id in animations.keys():
			var spec: Dictionary = animations[animation_id]
			rows = maxi(rows, int(spec.get("row", 0)) + species_directions)
			columns = maxi(columns, int(spec.get("frames", 1)))
		var node := _make_batch_node(config, columns, rows, int(config.get("z", DEFAULT_SPECIES_Z)))
		if node == null:
			continue
		_batches[str(species_id)] = {
			"node": node,
			"multimesh": node.multimesh,
			"animations": animations,
			"ground_offset": _ground_offset(config),
			"stride_length": float(config.get("stride_length", 26.0)),
			"directions": maxi(1, int(config.get("directions", 1))),
			"species": str(species_id),
			"agents": [],
			"scene_transforms": [],
			"scene_frames": [],
			"scene_colors": [],
		}
		_buckets[str(species_id)] = []

	_build_shadow_batch(visuals.get("shadow", {}))
	_effects = EventEffectsScript.new()
	_effects.name = "EventEffects"
	_effects.configure(self, visuals.get("effects", {}), _world_scale())
	add_child(_effects)

	var carcass_config: Dictionary = visuals.get("carcass", {})
	if not carcass_config.is_empty():
		var stages: int = maxi(1, int(carcass_config.get("stages", 1)))
		var carcass_node := _make_batch_node(carcass_config, stages, 1, CARCASS_Z)
		if carcass_node != null:
			_carcass_batch = {
				"node": carcass_node,
				"multimesh": carcass_node.multimesh,
				"stages": stages,
				"ground_offset": _ground_offset(carcass_config),
			}

	scene_batch = preload("res://scripts/ui/scene_sprite_batch.gd").new()
	scene_batch.configure(self, visuals)
	add_child(scene_batch)


## Half the drawn sprite height, or zero while the projection is the identity -
## the top-down view wants the sprite centred, not standing.
## Art is authored against a 32-unit cell. When the world uses larger cells the
## terrain tiles scale up with them, so sprites have to as well - otherwise one
## terrain pixel is three times the size of one animal pixel and the two read as
## different games.
func _world_scale() -> float:
	if simulation_manager == null or simulation_manager.world_state == null:
		return 1.0
	var terrain = simulation_manager.world_state.terrain_system
	if terrain == null:
		return 1.0
	return terrain.cell_size / 32.0


func _ground_offset(config: Dictionary) -> float:
	if WorldProjection.is_identity():
		return 0.0
	return float(config.get("frame_px", 32)) * float(config.get("sprite_scale", 1.0)) * _world_scale() * 0.5


func _build_shadow_batch(shadow_config: Dictionary) -> void:
	if shadow_config.is_empty():
		return
	var texture: Texture2D = load(str(shadow_config.get("texture", "")))
	if texture == null:
		push_error("Failed to load shadow texture; shadows disabled")
		return
	_shadow_scale = float(shadow_config.get("scale", 0.55)) * _world_scale()
	_shadow_bias = float(shadow_config.get("ground_bias", 2.0))
	var size: Array = shadow_config.get("size_px", [48, 24])
	var quad := QuadMesh.new()
	quad.size = Vector2(float(size[0]), float(size[1]))

	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_2D
	multimesh.use_colors = true
	multimesh.mesh = quad
	multimesh.instance_count = INSTANCE_GROW_CHUNK
	multimesh.visible_instance_count = 0

	_shadow_node = MultiMeshInstance2D.new()
	_shadow_node.multimesh = multimesh
	_shadow_node.texture = texture
	_shadow_node.modulate = Color(1.0, 1.0, 1.0, float(shadow_config.get("alpha", 0.55)))
	_shadow_node.z_index = SHADOW_Z
	_shadow_node.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	add_child(_shadow_node)


func _make_batch_node(config: Dictionary, columns: int, rows: int, layer_z: int) -> MultiMeshInstance2D:
	var atlas_path: String = str(config.get("atlas", ""))
	var texture: Texture2D = load(atlas_path) if atlas_path != "" else null
	if texture == null:
		push_error("Failed to load sprite atlas: %s" % atlas_path)
		return null

	var frame_px: float = float(config.get("frame_px", 32))
	var sprite_scale: float = float(config.get("sprite_scale", 1.0)) * _world_scale()
	var quad := QuadMesh.new()
	quad.size = Vector2.ONE * frame_px * sprite_scale

	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_2D
	multimesh.use_colors = true
	multimesh.use_custom_data = true
	multimesh.mesh = quad
	multimesh.instance_count = INSTANCE_GROW_CHUNK
	multimesh.visible_instance_count = 0

	var material := ShaderMaterial.new()
	material.shader = preload("res://shaders/agent_atlas.gdshader")
	material.set_shader_parameter("frame_size_uv", Vector2(1.0 / float(columns), 1.0 / float(rows)))
	var outline: Dictionary = {}
	if simulation_manager != null:
		outline = simulation_manager.config_bundle.get("visuals", {}).get("outline", {})
	if bool(outline.get("enabled", false)):
		material.set_shader_parameter("outline_width", float(outline.get("width_px", 1.0)))
		var rgba: Array = outline.get("color", [0.1, 0.08, 0.06, 0.9])
		material.set_shader_parameter("outline_color",
			Color(float(rgba[0]), float(rgba[1]), float(rgba[2]), float(rgba[3])))

	var node := MultiMeshInstance2D.new()
	node.multimesh = multimesh
	node.texture = texture
	node.material = material
	node.z_index = layer_z
	node.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	add_child(node)
	return node


## Runs on every tick, deliberately ungated. The UI refresh interval still
## throttles the HUD and the charts, but sprite positions cannot be sampled at
## 3.6 Hz and then shown at 60 fps without visible teleporting - the history fed
## to the curve has to advance in step with the simulation.
func _on_tick_completed(_tick: int, _snapshot: Dictionary) -> void:
	if simulation_manager == null or simulation_manager.world_state == null:
		return
	_advance_histories(simulation_manager.world_state)
	_needs_refresh = true


## Positions, facings and animation frames are written every drawn frame, not
## every tick: that is what turns a 18 Hz simulation into smooth motion.
func _process(delta: float) -> void:
	if simulation_manager == null or simulation_manager.world_state == null or _batches.is_empty():
		return
	var started := Time.get_ticks_usec()
	var view := _get_visible_world_rect(simulation_manager.world_state.bounds)
	_now = simulation_manager.get_display_time()
	# A dying sprite that starts fading or finishes changes the draw order: the body
	# appears under it, or it goes.
	if not _dying.is_empty() and _dying.advance(_now):
		_needs_refresh = true
	# Overview uses a frozen atlas frame and tiny sprites. Rewriting every visible
	# transform between two simulation results only burns the main thread and
	# competes with the worker. Refresh on a completed tick or while the camera is
	# moving; normal zoom keeps per-frame interpolation.
	var update_dynamic := not overview_mode or _needs_refresh or view != _last_camera_rect
	var phase_started := Time.get_ticks_usec()
	if _needs_refresh or view != _last_camera_rect:
		refresh()
		_needs_refresh = false
		_last_camera_rect = view
	simulation_manager.record_render_phase("culling", float(Time.get_ticks_usec() - phase_started) / 1000.0)
	if update_dynamic:
		_render_positions.clear()
	var alpha: float = simulation_manager.get_tick_alpha()
	if simulation_manager.paused:
		delta = 0.0
	if simulation_manager.selected_agent_id != -1:
		_marker_phase += delta
		queue_redraw()
	phase_started = Time.get_ticks_usec()
	if update_dynamic:
		_animate_shadows(alpha)
	simulation_manager.record_render_phase("shadows", float(Time.get_ticks_usec() - phase_started) / 1000.0)
	phase_started = Time.get_ticks_usec()
	if update_dynamic:
		for species_id in _batches.keys():
			_animate_species(_batches[species_id], alpha, delta)
	simulation_manager.record_render_phase("animation", float(Time.get_ticks_usec() - phase_started) / 1000.0)
	phase_started = Time.get_ticks_usec()
	if scene_batch != null and update_dynamic:
		scene_batch.render(self, alpha)
	elif scene_batch != null:
		scene_batch.last_counts["multimesh_writes"] = 0
		scene_batch.last_counts["order_rebuilt"] = false
	simulation_manager.record_render_phase("scene_batch", float(Time.get_ticks_usec() - phase_started) / 1000.0)
	if _effects != null:
		phase_started = Time.get_ticks_usec()
		_effects.advance(_now)
		simulation_manager.record_render_phase("effects", float(Time.get_ticks_usec() - phase_started) / 1000.0)
	var visible_animals := 0
	for batch in _batches.values():
		visible_animals += batch.get("agents", []).size()
	var counts := {"visible_animals": visible_animals,
		"visible_shadows": 0 if _shadow_node == null or not _shadow_node.visible else _shadow_agents.size(),
		"visible_effects": 0 if _effects == null else _effects.queue.items().size(),
		"overview": overview_mode}
	if scene_batch != null:
		counts.merge(scene_batch.last_counts, true)
	simulation_manager.set_render_counts(counts)
	simulation_manager.render_times.add(float(Time.get_ticks_usec() - started) / 1000.0)


func _advance_histories(world) -> void:
	_render_positions.clear()
	var seen := {}
	var tick_duration: float = maxf(0.0001, simulation_manager.tick_duration)
	for agent in world.get_living_agents():
		if agent == null:
			continue
		var id: int = agent.id
		seen[id] = true
		var samples = _history.get(id)
		# A fresh agent, or one that jumped further than any tick could carry it,
		# starts flat instead of sweeping a curve across the map.
		if samples == null or samples[3].distance_squared_to(agent.position) > minf(_teleport_distance_sq, pow(float(agent.movement.get("sprint_speed", 128.0)) * tick_duration * 3.0, 2.0)):
			_history[id] = PackedVector2Array([agent.position, agent.position, agent.position, agent.position])
			_drawn_speed[id] = 0.0
			continue
		var step: float = samples[3].distance_to(agent.position)
		samples[0] = samples[1]
		samples[1] = samples[2]
		samples[2] = samples[3]
		samples[3] = agent.position
		_history[id] = samples
		# Measured across the whole window rather than off the last step alone,
		# so an agent on a coarse LOD tier - which only takes a full tick every
		# second or fifth one - does not flicker between idle and walk.
		_drawn_speed[id] = samples[0].distance_to(samples[3]) / (3.0 * tick_duration)
		# Ground covered, in world pixels. `_advance_frame()` turns it into a
		# frame index once it knows the species stride, which keeps this loop
		# free of per-species state. Wrapped so a session left running for hours
		# cannot drift into coarse float steps.
		_gait_distance[id] = fmod(float(_gait_distance.get(id, 0.0)) + step, _GAIT_WRAP_PX)
	for id in _history.keys():
		if not seen.has(id):
			_history.erase(id)
			_phase.erase(id)
			_drawn_speed.erase(id)
			_gait_distance.erase(id)
			_facing.erase(id)
			_heading.erase(id)
			_direction.erase(id)
			_dust_mark.erase(id)
			_born.erase(id)


## Catmull-Rom through the four samples, evaluated on the segment between the
## middle two. That leaves the drawn position one tick behind the simulation -
## about 55 ms, imperceptible - and buys a curve with real neighbours on both
## sides instead of a straight line whose corners are as sharp as the steering.
func _curve_position(agent, alpha: float) -> Vector2:
	if _render_positions.has(agent.id):
		return _render_positions[agent.id]
	var point := _safe_curve_position(agent, alpha)
	_render_positions[agent.id] = point
	return point

func _safe_curve_position(agent, alpha: float) -> Vector2:
	var samples = _history.get(agent.id)
	if samples == null:
		return agent.position
	var p0: Vector2 = samples[0]
	var p1: Vector2 = samples[1]
	var p2: Vector2 = samples[2]
	var p3: Vector2 = samples[3]
	if p0 == p1 and p1 == p2 and p2 == p3:
		return p1
	var t2: float = alpha * alpha
	var t3: float = t2 * alpha
	var curved: Vector2 = 0.5 * ((2.0 * p1)
		+ (p2 - p0) * alpha
		+ (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * t2
		+ (p3 - p0 + 3.0 * (p1 - p2)) * t3)
	var scenery = simulation_manager.world_state.scenery
	if scenery.segment_clear(p1, curved, agent.get_body_radius()):
		return curved
	var linear := p1.lerp(p2, alpha)
	return scenery.resolve_motion(p1, linear, agent.get_body_radius())


## World-space displacement across the segment `_curve_position()` is currently
## drawing: what the animal visibly did, as opposed to what its velocity says it
## is trying to do. Taken from the same pair of samples as the drawn position so
## the facing cannot lead or lag the motion it belongs to.
func _drawn_step(agent) -> Vector2:
	var samples = _history.get(agent.id)
	if samples == null:
		return Vector2.ZERO
	return samples[2] - samples[1]


## Which drawn direction row an animal should use, 0..3 in the pack's own order:
## 0 south (toward the viewer), 1 north, 2 west, 3 east.
##
## The choice is made in screen space, not world space. Under the isometric
## projection a world heading of +x runs diagonally down-right on screen, so
## picking the row from the world vector would face every animal wrongly.
## Projecting a short step and reading the result keeps this correct in both
## projections without a special case.
##
## The step projected is the one being drawn - the `_history` segment behind
## `_curve_position()` - not `agent.direction`. They part company whenever something other than the
## animal's own velocity moved it, and a sprite that faces one way while sliding
## the other is the single most obvious rendering fault there is.
func _resolve_direction(agent) -> int:
	var id: int = agent.id
	var current: int = int(_direction.get(id, 0))
	var step: Vector2 = _drawn_step(agent)
	if step.length_squared() < _DRAWN_STEP_EPSILON_SQ:
		return current
	var level := _height_at(agent.position)
	var here: Vector2 = WorldProjection.to_screen(agent.position, level)
	var ahead: Vector2 = WorldProjection.to_screen(agent.position + step.normalized() * 16.0, level)
	var screen_dir: Vector2 = ahead - here
	if screen_dir.length_squared() < 0.0001:
		return current
	# Hysteresis: the new axis has to win by a margin, otherwise an animal
	# running along a diagonal would alternate rows every frame.
	var horizontal: bool = absf(screen_dir.x) > absf(screen_dir.y) * (1.0 + _direction_hysteresis)
	var vertical: bool = absf(screen_dir.y) > absf(screen_dir.x) * (1.0 + _direction_hysteresis)
	if horizontal:
		current = 3 if screen_dir.x > 0.0 else 2
	elif vertical:
		current = 0 if screen_dir.y > 0.0 else 1
	_direction[id] = current
	return current


## Mirror direction with hysteresis, used only by atlases that draw a single
## side and rely on flipping. The drawn step jitters around zero whenever an
## animal moves nearly vertically, and flipping on the raw sign made the sprite
## snap back and forth every refresh.
func _resolve_facing(agent, delta: float) -> float:
	var id: int = agent.id
	var current: float = float(_facing.get(id, 1.0))
	# A standing animal keeps whatever way it was facing. Otherwise the jitter
	# `wander()` puts into the steering would spin a sprite that is not moving.
	var step: Vector2 = _drawn_step(agent)
	if step.length_squared() < _DRAWN_STEP_EPSILON_SQ:
		return current

	# The decision is made on a heading that lags the raw step, not on the raw
	# step itself. Its x component crosses zero constantly while an animal walks
	# a near-vertical line; deciding on it directly is what made sprites flicker.
	var target: float = step.angle()
	var heading: float = float(_heading.get(id, target))
	heading = lerp_angle(heading, target, clampf(_turn_lerp * delta, 0.0, 1.0))
	_heading[id] = heading

	# The dead zone is the second half of the guard: within it the sprite holds
	# its current facing rather than picking one, so a heading hovering near
	# vertical cannot oscillate.
	var heading_x: float = cos(heading)
	if heading_x > _facing_deadzone:
		current = 1.0
	elif heading_x < -_facing_deadzone:
		current = -1.0
	_facing[id] = current
	return current


func _animate_species(batch: Dictionary, alpha: float, delta: float) -> void:
	var agents: Array = batch.get("agents", [])
	if agents.is_empty():
		return
	var multimesh: MultiMesh = batch["multimesh"]
	var animations: Dictionary = batch["animations"]
	var stride: float = maxf(1.0, float(batch.get("stride_length", 26.0)))
	var directions: int = int(batch.get("directions", 1))
	var ground_offset: float = float(batch["ground_offset"])
	var dusty: bool = _effects != null and not overview_mode and _effects.dust_species.has(str(batch.get("species", "")))
	var scene_transforms: Array = batch["scene_transforms"]
	var scene_frames: Array = batch["scene_frames"]
	var scene_colors: Array = batch["scene_colors"]
	scene_transforms.resize(agents.size())
	scene_frames.resize(agents.size())
	scene_colors.resize(agents.size())
	for index in range(agents.size()):
		var agent = agents[index]
		if agent == null or not agent.is_alive:
			continue
		# An atlas with real direction rows never mirrors: it already has both
		# sides drawn, and flipping would fight the artwork.
		var simplified := overview_mode and bool(_overview_config.get("freeze_animation", true))
		var facing: float = 1.0 if directions > 1 or simplified else _resolve_facing(agent, delta)
		var direction_row: int = 0 if simplified else (_resolve_direction(agent) if directions > 1 else 0)
		var animation_id: String = "idle" if simplified else _resolve_animation(agent)
		var frame: Vector2 = Vector2(0.0, float(animations.get("idle", {}).get("row", 0))) \
			if simplified else _advance_frame(agent, animations, stride, delta, animation_id)
		frame.y += float(direction_row)
		var scale_factor: float = _age_scale_of(agent) * _pop_of(agent.id)
		var drawn_at: Vector2 = _curve_position(agent, alpha)
		var point: Vector2 = _anchor(drawn_at, ground_offset * scale_factor)
		if dusty:
			if animation_id == "run" and _in_chase(agent):
				_kick_dust(agent, drawn_at)
			elif _dust_mark.has(agent.id):
				_dust_mark.erase(agent.id)
		# A standing animal that is perfectly still reads as frozen, so idle and
		# eat breathe. Walking already has the leg cycle and needs no help.
		if not simplified and _idle_bob_px > 0.0 and (animation_id == "idle" or animation_id == "eat"):
			point.y += sin(float(_phase.get(agent.id, 0.0)) * TAU) * _idle_bob_px
		var transform := Transform2D(
			Vector2(facing * scale_factor, 0.0),
			Vector2(0.0, scale_factor),
			point
		)
		if scene_batch == null:
			multimesh.set_instance_transform_2d(index, transform)
			multimesh.set_instance_custom_data(index, Color(frame.x, frame.y, 0.0, 0.0))
		scene_transforms[index] = transform
		scene_frames[index] = frame
		scene_colors[index] = _resolve_tint(agent)


## Walk and run advance by ground actually covered rather than by wall clock, so
## feet stop sliding when an animal speeds up, when the simulation runs at a
## speed multiplier, or when it is pushed instead of walking. Standing still is
## the same statement: no ground, no step. Idle and eat keep a fixed rate,
## offset per agent so a herd does not breathe in unison.
func _advance_frame(agent, animations: Dictionary, stride: float, delta: float, animation_id: String) -> Vector2:
	var spec: Dictionary = animations.get(animation_id, {})
	if spec.is_empty():
		return Vector2.ZERO
	var frames: int = maxi(1, int(spec.get("frames", 1)))
	var row: float = float(spec.get("row", 0))
	if frames <= 1:
		return Vector2(0.0, row)
	if animation_id == "walk" or animation_id == "run":
		# Accumulated per tick in `_advance_histories()`, which is also why a
		# paused simulation holds its pose instead of marching on the spot.
		var covered: float = float(_gait_distance.get(agent.id, 0.0))
		var gait: float = covered / stride * float(frames) + float(agent.id) * _phase_step
		return Vector2(float(int(gait) % frames), row)
	var phase: float = float(_phase.get(agent.id, float(agent.id) * _phase_step))
	phase += float(spec.get("fps", 4.0)) * delta
	_phase[agent.id] = fmod(phase, float(frames) * 1024.0)
	return Vector2(float(int(phase) % frames), row)


func _get_visible_world_rect(world_bounds: Rect2) -> Rect2:
	var camera := get_viewport().get_camera_2d()
	if camera is GameCamera:
		return WorldProjection.world_rect_covering(camera.get_visible_screen_rect())
	return world_bounds
