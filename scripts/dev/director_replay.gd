extends SceneTree

# The reserve's camera (`ReserveDirector`) over a reserve world, scored on what it showed. Not
# part of the game.
#
#   Godot --headless --path . --script res://scripts/dev/director_replay.gd -- <seed> <seconds> <out.json> [key=value ...]
# The world is the reserve's (its selection, its LOD following the view), stepped inline at x1;
# the camera stands in for the game's - a 1600x900 view at the reserve's zoom, the isometric
# projection, following the animal the director selected - and the director runs once a tick.
# `key=value` overrides the director's settings (`reserve.json` `director`).
#
# Scored: of the hunts begun (`HuntStarted` to its end), how many the view showed for at least
# SEEN seconds of the chase; the kills and births that happened in view; of the hunts the
# director went to, how many were still on when it arrived; and each scene's kind.
const VIEWPORT := Vector2(1600.0, 900.0)
const ZOOM := 0.8
const SEEN := 1.0
const CHASE := ["chase", "flank", "attack"]
const HUNTERS := ["predator", "wolf"]


class ReplayCamera:
	var center := Vector2.ZERO
	var zoom := ZOOM
	var bounds := Rect2()
	var widest := 0.05

	func set_view(world_center: Vector2, zoom_factor: float) -> void:
		zoom = clampf(zoom_factor, widest, 2.5)
		center = Vector2(clampf(world_center.x, bounds.position.x, bounds.end.x), clampf(world_center.y, bounds.position.y, bounds.end.y))

	func view_center() -> Vector2:
		return center

	func zoom_factor() -> float:
		return zoom

	func screen_rect() -> Rect2:
		var size := VIEWPORT / zoom
		return Rect2(WorldProjection.to_screen(center) - size * 0.5, size)

	func zoom_to_fit(rect: Rect2) -> float:
		var screen := Rect2(WorldProjection.to_screen(rect.position), Vector2.ZERO)
		for corner in [Vector2(rect.end.x, rect.position.y), rect.end, Vector2(rect.position.x, rect.end.y)]:
			screen = screen.expand(WorldProjection.to_screen(corner))
		if screen.size.x <= 0.0 or screen.size.y <= 0.0:
			return zoom
		return clampf(minf(VIEWPORT.x / screen.size.x, VIEWPORT.y / screen.size.y), widest, 2.5)

	func view_span() -> float:
		return WorldProjection.world_rect_covering(screen_rect()).size.x

	func sees(point: Vector2) -> bool:
		return screen_rect().has_point(WorldProjection.to_screen(point))


var _director = null
var _camera := ReplayCamera.new()
var _world = null
var _hunts: Dictionary = {}
var _done_hunts: Array = []
var _kills := {"all": 0, "seen": 0}
var _births := {"all": 0, "seen": 0}
var _went: Array = []
var _scenes: Dictionary = {}


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var run_seed := int(args[0])
	var seconds := float(args[1])
	var out := str(args[2])
	var reserve: Dictionary = ConfigLoader._load_json("res://data/config/reserve.json")
	for index in range(3, args.size()):
		var pair := str(args[index]).split("=", true, 1)
		reserve["director"][pair[0]] = float(pair[1])
	var bundle: Dictionary = ConfigLoader.load_reserve_bundle(reserve)
	WorldProjection.configure(bundle.get("visuals", {}))
	var manager = preload("res://scripts/core/simulation_manager.gd").new()
	manager.initialize(bundle, run_seed)
	manager.set_lod_enabled(true)
	_world = manager.world_state
	_camera.bounds = _world.bounds
	_camera.widest = _camera.zoom_to_fit(_world.bounds)
	_camera.center = _world.bounds.get_center()
	var session = preload("res://scripts/reserve/reserve_session.gd").new()
	session.configure(manager, reserve)
	_director = preload("res://scripts/ui/reserve_director.gd").new()
	_director.configure(manager, _camera, session, reserve)
	_director.clock = func() -> int: return int(round(float(manager.simulation_time) * 1000.0))
	_director.caption_changed.connect(_on_caption)
	manager.event_bus.event_emitted.connect(_on_event)
	var dt: float = manager.tick_duration
	var total_ticks := int(ceil(seconds * manager.tick_rate))
	var was_moving := false
	for _tick in range(total_ticks):
		var moving: bool = _director.is_moving()
		if not moving:
			var view := WorldProjection.world_rect_covering(_camera.screen_rect())
			manager.set_lod_view(view, _camera.center, false)
		manager.step_once()
		_director.update()
		moving = _director.is_moving()
		if was_moving and not moving:
			_arrived()
		was_moving = moving
		if not moving and manager.focus_mode != "off":
			var focus = manager.get_focus_position()
			if focus != null:
				_camera.center = _camera.center.lerp(focus, clampf(7.5 * dt, 0.0, 1.0))
		_watch_hunts(dt, moving)
		_watch_prowl()
	var report := _report(run_seed, seconds)
	var file := FileAccess.open(out, FileAccess.WRITE)
	file.store_string(JSON.stringify(report, "  "))
	file.close()
	print(JSON.stringify(report, "  "))
	quit()


## A new scene's caption is told as the view sets out; one told on the way or on the scene (a
## prowl become a hunt) is no new scene.
func _on_caption(text: String, _seconds: float) -> void:
	var kind := str(_director.scene.get("kind", ""))
	if not _director.is_moving() or int(_director._move.get("started", -1)) != int(_director.clock.call()):
		return
	_scenes[kind] = int(_scenes.get(kind, 0)) + 1
	if kind in ["hunt", "prowl"]:
		_went.append({"kind": kind, "id": int(_director.scene["id"]), "caption": text, "at": float(_world.current_time)})


func _arrived() -> void:
	if _went.is_empty() or _went.back().has("on_arrival"):
		return
	var went: Dictionary = _went.back()
	var hunter = _world.get_agent(int(went["id"]))
	went["on_arrival"] = hunter != null and hunter.is_alive and CHASE.has(str(hunter.state))
	went["travel"] = float(_world.current_time) - float(went["at"])


func _on_event(event: Dictionary) -> void:
	var kind := str(event.get("type", ""))
	var id := int(event.get("agent_id", -1))
	if id < 0:
		return
	var at: Dictionary = event.get("position", {})
	var where := Vector2(float(at.get("x", 0.0)), float(at.get("y", 0.0)))
	var in_view: bool = not _director.is_moving() and _camera.sees(where)
	match kind:
		"HuntStarted":
			if HUNTERS.has(str(event.get("species", ""))) and not _hunts.has(id):
				_hunts[id] = {"at": float(event.get("time_seconds", 0.0)), "seen": 0.0}
		"PredationSuccess", "PredationFailed":
			if _hunts.has(id):
				var hunt: Dictionary = _hunts[id]
				hunt["length"] = float(event.get("time_seconds", 0.0)) - float(hunt["at"])
				_done_hunts.append(hunt)
				_hunts.erase(id)
			if kind == "PredationSuccess" and HUNTERS.has(str(event.get("species", ""))):
				_kills["all"] += 1
				_kills["seen"] += 1 if in_view else 0
		"AgentBorn":
			if str(event.get("data", {}).get("reason", "")) == "reproduction":
				_births["all"] += 1
				_births["seen"] += 1 if in_view else 0


## A prowl gone to whose hunter has started its chase while the scene was on.
func _watch_prowl() -> void:
	if _went.is_empty() or str(_went.back()["kind"]) != "prowl" or _went.back().has("became_hunt"):
		return
	if int(_director.scene.get("id", -1)) == int(_went.back()["id"]) and str(_director.scene.get("kind", "")) == "hunt":
		_went.back()["became_hunt"] = float(_world.current_time) - float(_went.back()["at"])


func _watch_hunts(dt: float, moving: bool) -> void:
	if moving:
		return
	for id in _hunts.keys():
		var hunter = _world.get_agent(int(id))
		if hunter != null and hunter.is_alive and CHASE.has(str(hunter.state)) and _camera.sees(hunter.position):
			_hunts[id]["seen"] += dt


func _report(run_seed: int, seconds: float) -> Dictionary:
	var seen := 0
	var seen_seconds := 0.0
	var all_seconds := 0.0
	for hunt in _done_hunts:
		seen += 1 if float(hunt["seen"]) >= SEEN else 0
		seen_seconds += float(hunt["seen"])
		all_seconds += float(hunt.get("length", 0.0))
	var arrived := 0
	var in_time := 0
	var travel := 0.0
	for went in _went:
		if went.has("on_arrival"):
			arrived += 1
			in_time += 1 if bool(went["on_arrival"]) else 0
			travel += float(went["travel"])
	var by_kind := {}
	for went in _went:
		var kind := str(went["kind"])
		if not by_kind.has(kind):
			by_kind[kind] = {"went": 0, "chasing_on_arrival": 0, "became_hunt": 0, "became_hunt_after": []}
		by_kind[kind]["went"] += 1
		by_kind[kind]["chasing_on_arrival"] += 1 if bool(went.get("on_arrival", false)) else 0
		if went.has("became_hunt"):
			by_kind[kind]["became_hunt"] += 1
			by_kind[kind]["became_hunt_after"].append(snappedf(float(went["became_hunt"]), 0.1))
	return {"seed": run_seed, "seconds": seconds,
		"hunts": {"all": _done_hunts.size(), "seen": seen, "chase_seconds_seen": snappedf(seen_seconds, 0.1),
			"chase_seconds_all": snappedf(all_seconds, 0.1)},
		"kills": _kills, "births": _births,
		"went_to_hunts": by_kind, "mean_travel": snappedf(travel / maxf(1.0, float(arrived)), 0.01),
		"scenes": _scenes}
