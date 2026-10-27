class_name ReserveDirector
extends RefCounted

## The living reserve's camera with no one at the controls (`reserve.json` `director`), calm. It
## stays with one scene - a hunt, a ward, a herd - for `scene_seconds`; a hunt until it is over and
## `linger_seconds` after. It leaves a scene early only for a viewer's «!моё» (after
## `asked_dwell_seconds`), for something weightier near (after `near_dwell_seconds`) or for
## something weighty anywhere (after `min_dwell_seconds`). The next scene is the best of: what a
## viewer asked for; a hunt going on among the animals awake; the recent moments (a kill, a ward
## taken, newcomers, a pair or a pack on the hunt, a birth, a territory taken), the near first;
## the wards, those not seen for a while first; the focus herd - not the subject it just left.
## A far scene is reached through the map: the view widens until both places are in it, holds,
## and closes on the new one; a near one is reached by panning. Each scene opens with a caption,
## what and where (`caption_changed`), shown while the view travels and a while after. The herd
## of what it follows becomes the session's focus, so the viewers' powers go where the stream
## looks. An animal asleep far off is reached by going where its group's record has it and
## selecting it once its sector wakes.

signal caption_changed(text: String, seconds: float)

const WEIGHTS := {"adopt": 7, "PredationSuccess": 6, "Release": 5, "PairHunt": 5, "AgentBorn": 3, "HerdAlarm": 3,
	"TerritoryClaimed": 2}
const ASKED_WEIGHT := 10
const HUNT_WEIGHT := 6
const WARD_WEIGHT := 4
const HERD_WEIGHT := 2
## A hunt one can see: the chase itself, a pair's flank, the strike.
const HUNT_STATES := ["chase", "flank", "attack"]
const DEFAULTS := {"scene_seconds": 75.0, "asked_seconds": 20.0, "moment_seconds": 30.0, "hunt_max_seconds": 60.0,
	"linger_seconds": 6.0, "min_dwell_seconds": 30.0, "near_dwell_seconds": 15.0, "asked_dwell_seconds": 8.0,
	"ward_rest_seconds": 180.0, "caption_seconds": 7.0, "pan_seconds": 1.4, "out_seconds": 1.6, "hold_seconds": 1.2,
	"in_seconds": 1.6}
## Farther than this many views across, a scene is reached through the map.
const FAR_VIEWS := 1.2
## Within this many views, a moment counts as near.
const NEAR_VIEWS := 1.0

var manager = null
var camera = null
var session = null
## The world's names and places (`StoryBook`), for the captions; without it they name no one.
var story = null
var settings: Dictionary = {}
## Milliseconds now; a test sets its own.
var clock: Callable = func() -> int: return Time.get_ticks_msec()
## What it follows now, or -1.
var current_id: int = -1
## The scene on: `{kind, id, weight, position, started, until, ended_at?}`; empty before the first.
var scene: Dictionary = {}
var _asked: Array = []
var _moments: Array = []
var _ward_seen: Dictionary = {}
var _recent: Array = []
## The view on its way to the next scene, or empty.
var _move: Dictionary = {}
var _pending_id: int = -1
var _pending_until: int = 0


func configure(new_manager, new_camera, new_session, config: Dictionary) -> void:
	manager = new_manager
	camera = new_camera
	session = new_session
	settings = DEFAULTS.duplicate()
	settings.merge(config.get("director", {}), true)
	if not manager.world_event.is_connected(_hear):
		manager.world_event.connect(_hear)
	if not session.focus_requested.is_connected(ask):
		session.focus_requested.connect(ask)


## A viewer's animal, to be shown as soon as the scene on has had its moment.
func ask(agent_id: int) -> void:
	if agent_id >= 0 and not _asked.has(agent_id):
		_asked.append(agent_id)


func _hear(event: Dictionary) -> void:
	var kind := str(event.get("type", ""))
	var data: Dictionary = event.get("data", {})
	var agent_id := int(event.get("agent_id", -1))
	if kind == "PlayerCommand":
		if str(data.get("power", "")) == "adopt" and bool(data.get("ok", false)):
			kind = "adopt"
			agent_id = int(data.get("agent_id", -1))
		elif str(data.get("power", "")) == "release" and bool(data.get("ok", false)):
			kind = "Release"
	var weight := int(WEIGHTS.get(kind, 0))
	# Nothing to see of what happened asleep, far off: it was settled in aggregate.
	if weight <= 0 or bool(data.get("dormant", false)):
		return
	var at: Dictionary = event.get("position", {})
	var where := Vector2(float(at.get("x", 0.0)), float(at.get("y", 0.0)))
	if kind == "Release":
		where = Vector2(data.get("position", where))
	_moments.append({"kind": kind, "weight": weight, "agent_id": agent_id, "species": str(data.get("species", event.get("species", ""))),
		"other_id": int(event.get("other_agent_id", -1)), "position": where, "at": _now()})
	if _moments.size() > 32:
		_moments = _moments.slice(_moments.size() - 32)


## Whether the view is on its way to the next scene.
func is_moving() -> bool:
	return not _move.is_empty()


func update() -> void:
	if manager == null or manager.world_state == null:
		return
	var now := _now()
	if not _move.is_empty():
		_advance(now)
		return
	if _pending_id >= 0:
		if manager.select_agent_by_id(_pending_id, true):
			_settle(manager.world_state.get_agent(_pending_id))
			_pending_id = -1
		elif now > _pending_until:
			_pending_id = -1
			scene["until"] = now
	var next := next_scene(now)
	if not next.is_empty():
		_go(next, now)


# --- Choosing -----------------------------------------------------------------------------------

## The scene to cut to now, or {} to stay: `{kind, id, weight, position, caption}`.
func next_scene(now: int) -> Dictionary:
	var over := scene.is_empty() or scene_over(now)
	var dwell: int = now - int(scene.get("started", 0)) if not scene.is_empty() else 1 << 30
	if not _asked.is_empty() and (over or dwell >= _ms("asked_dwell_seconds")):
		while not _asked.is_empty():
			var asked := _subject("asked", int(_asked.pop_front()), ASKED_WEIGHT)
			if not asked.is_empty():
				return asked
	var best := {}
	var best_score := -INF
	for candidate in candidates(now):
		if int(candidate["id"]) == current_id and not over:
			continue
		var score := float(candidate["weight"]) - _distance_cost(candidate["position"])
		if _recent.has(int(candidate["id"])):
			score -= 3.0
		if score > best_score:
			best_score = score
			best = candidate
	if best.is_empty():
		return {}
	if over:
		return best
	var near := _views_away(best["position"]) <= NEAR_VIEWS
	if int(best["weight"]) >= HUNT_WEIGHT and int(best["weight"]) > int(scene.get("weight", 0)) and dwell >= _ms("min_dwell_seconds"):
		return best
	if near and int(best["weight"]) >= WARD_WEIGHT and int(best["weight"]) > int(scene.get("weight", 0)) \
			and dwell >= _ms("near_dwell_seconds"):
		return best
	return {}


## Whether the scene on has had its time: its time is up, its animal is gone, or its hunt is over
## and lingered on.
func scene_over(now: int) -> bool:
	if now >= int(scene.get("until", 0)):
		return true
	var id := int(scene.get("id", -1))
	if id < 0 or _pending_id >= 0:
		return false
	var agent = manager.world_state.get_agent(id)
	var ended: bool = agent == null or not agent.is_alive \
		or (str(scene.get("kind", "")) == "hunt" and not HUNT_STATES.has(str(agent.state)))
	if not ended:
		scene.erase("ended_at")
		return false
	if not scene.has("ended_at"):
		scene["ended_at"] = now
	return now - int(scene["ended_at"]) >= _ms("linger_seconds")


## What could be shown next: hunts on among the animals awake, the recent moments whose animal is
## still about, the living wards and the focus herd.
func candidates(now: int) -> Array:
	var found: Array = []
	var world = manager.world_state
	var hunters := {}
	for agent in world.get_living_agents():
		if agent != null and agent.is_alive and HUNT_STATES.has(str(agent.state)) and int(agent.target_agent_id) >= 0:
			hunters[agent.id] = true
			var hunt := _subject("hunt", agent.id, HUNT_WEIGHT)
			if not hunt.is_empty():
				found.append(hunt)
	var window := _ms("moment_seconds")
	var kept: Array = []
	for moment in _moments:
		if now - int(moment["at"]) > window:
			continue
		kept.append(moment)
		var id := int(moment["agent_id"])
		if str(moment["kind"]) == "HerdAlarm":
			# An alarm is a hunt starting: the hunter near it, if one is awake.
			id = _hunter_near(moment["position"])
			if id < 0 or hunters.has(id):
				continue
		var chosen := _subject(str(moment["kind"]), id, int(moment["weight"]), moment)
		if not chosen.is_empty():
			found.append(chosen)
	_moments = kept
	for id in world.adoptions.keys():
		if float(world.adoptions[id].get("died_at", -1.0)) >= 0.0:
			continue
		var rested: bool = now - int(_ward_seen.get(int(id), -(1 << 30))) >= _ms("ward_rest_seconds")
		var ward := _subject("ward", int(id), WARD_WEIGHT + (2 if rested else 0))
		if not ward.is_empty():
			found.append(ward)
	var herd: Dictionary = session.focus_herd() if session != null else {}
	if not herd.is_empty():
		var nearest = null
		for agent in world.get_living_agents():
			if agent.is_alive and agent.species_type == str(herd["species"]) and int(agent.group_id) == int(herd["group_id"]) \
					and (nearest == null or agent.position.distance_squared_to(herd["center"]) < nearest.position.distance_squared_to(herd["center"])):
				nearest = agent
		if nearest != null:
			found.append(_subject("herd", nearest.id, HERD_WEIGHT))
	return found


## A scene of `id`: where it is (awake, or where its group's record has it asleep) and what the
## caption says; {} when it is nowhere to be found.
func _subject(kind: String, id: int, weight: int, moment: Dictionary = {}) -> Dictionary:
	if id < 0:
		return {}
	var agent = manager.world_state.get_agent(id)
	var position = null
	if agent != null and agent.is_alive:
		position = agent.position
	else:
		position = sleeping_position(manager.world_state, id)
	if position == null:
		return {}
	return {"kind": kind, "id": id, "weight": weight, "position": position, "caption": caption_for(kind, id, agent, position, moment)}


func _hunter_near(position: Vector2) -> int:
	var best := -1
	var best_distance := INF
	for agent in manager.world_state.get_living_agents():
		if agent != null and agent.is_alive and HUNT_STATES.has(str(agent.state)):
			var distance: float = agent.position.distance_to(position)
			if distance < best_distance and distance < 600.0:
				best = agent.id
				best_distance = distance
	return best


# --- Captions -----------------------------------------------------------------------------------

## What a scene is and where: «Охота: лиса Рыжик гонит оленя · у Тихой заводи».
func caption_for(kind: String, id: int, agent, position: Vector2, moment: Dictionary = {}) -> String:
	var who := _who(id, agent)
	var sex := str(agent.sex) if agent != null else ""
	var what := ""
	match kind:
		"hunt":
			var prey = manager.world_state.get_agent(int(agent.target_agent_id)) if agent != null else null
			var prey_words: Dictionary = HudText.ANIMALS.get(str(prey.species_type) if prey != null else "", {})
			# «гонит оленя»: an animal's accusative is its genitive.
			what = "Охота: %s гонит %s" % [who, str(prey_words["count"][1])] if not prey_words.is_empty() else "Охота: %s" % who
		"PredationSuccess":
			what = "Добыча: %s" % who
		"PairHunt":
			what = "Охота вдвоём: %s" % who if int(agent.group_id if agent != null else -1) < 0 else "Стая на охоте: %s" % who
		"adopt", "ward", "asked":
			var ward: Dictionary = manager.world_state.adoptions.get(id, {})
			if ward.is_empty():
				what = who
			else:
				what = "%s %s (%s)" % [HudText.verb(sex, "Подопечный", "Подопечная") if kind != "adopt" else "Новый подопечный:", who,
					str(ward.get("viewer_name", ""))]
		"AgentBorn":
			what = "Пополнение: %s" % who
		"Release":
			what = "С края карты пришли новые звери"
		"TerritoryClaimed":
			what = "Пара заняла участок: %s" % who
		"herd":
			what = HudText.herd_name(str(agent.species_type), int(agent.group_id)) if agent != null else who
		_:
			what = who
	var place := ""
	if story != null and story.get("places") != null:
		place = str(story.places.at(position))
	return what if place == "" else "%s · %s" % [what, place]


func _who(id: int, agent) -> String:
	var name := ""
	var species := ""
	var sex := ""
	if agent != null:
		species = str(agent.species_type)
		sex = str(agent.sex)
	if story != null:
		name = str(story.name_of(agent)) if agent != null else str(story.name_of_id(id))
		if agent == null:
			# Asleep far off: what the family tree knows of it.
			var entry: Dictionary = story.lineage.entry(id)
			species = str(entry.get("species", ""))
			sex = str(entry.get("sex", ""))
	if species == "":
		return name
	var noun := HudText.animal_noun(species, sex)
	return noun if name == "" else "%s %s" % [noun, name]


# --- Moving -------------------------------------------------------------------------------------

func _go(next: Dictionary, now: int) -> void:
	var id := int(next["id"])
	var kind := str(next["kind"])
	var from: Vector2 = camera.view_center()
	var to: Vector2 = next["position"]
	var far := from.distance_to(to) > FAR_VIEWS * maxf(1.0, camera.view_span())
	var travel := _ms("pan_seconds") if not far else _ms("out_seconds") + _ms("hold_seconds") + _ms("in_seconds")
	var length := _ms("hunt_max_seconds") if kind == "hunt" else (_ms("asked_seconds") if kind == "asked" else _ms("scene_seconds"))
	scene = {"kind": kind, "id": id, "weight": int(next["weight"]), "position": to, "started": now + travel,
		"until": now + travel + length}
	current_id = id
	_recent.append(id)
	if _recent.size() > 2:
		_recent = _recent.slice(_recent.size() - 2)
	if kind in ["ward", "asked", "adopt"]:
		_ward_seen[id] = now
	manager.clear_focus()
	var zoom: float = camera.zoom_factor()
	_move = {"id": id, "kind": kind, "from": from, "to": to, "zoom": zoom, "far": far, "started": now,
		"wide": minf(zoom, camera.zoom_to_fit(Rect2(from, Vector2.ZERO).expand(to).grow(from.distance_to(to) * 0.25 + 200.0)))}
	caption_changed.emit(str(next.get("caption", "")), float(travel) / 1000.0 + float(settings["caption_seconds"]))


func _advance(now: int) -> void:
	var t := float(now - int(_move["started"])) / 1000.0
	var to := _move_target()
	var from: Vector2 = _move["from"]
	var zoom: float = _move["zoom"]
	if not bool(_move["far"]):
		var pan := float(settings["pan_seconds"])
		camera.set_view(from.lerp(to, _smooth(t / pan)), zoom)
		if t >= pan:
			_arrive(now)
		return
	var out := float(settings["out_seconds"])
	var hold := float(settings["hold_seconds"])
	var close := float(settings["in_seconds"])
	var wide: float = _move["wide"]
	var middle := from.lerp(to, 0.5)
	if t < out:
		var k := _smooth(t / out)
		camera.set_view(from.lerp(middle, k), _zoom_between(zoom, wide, k))
	elif t < out + hold:
		camera.set_view(middle, wide)
	elif t < out + hold + close:
		var k := _smooth((t - out - hold) / close)
		camera.set_view(middle.lerp(to, k), _zoom_between(wide, zoom, k))
	else:
		_arrive(now)


## Where the move is headed: the animal where it is drawn now, or where it was found.
func _move_target() -> Vector2:
	var agent = manager.world_state.get_agent(int(_move["id"]))
	return agent.position if agent != null and agent.is_alive else Vector2(_move["to"])


func _arrive(now: int) -> void:
	var id := int(_move["id"])
	camera.set_view(_move_target(), float(_move["zoom"]))
	_move = {}
	if manager.select_agent_by_id(id, true):
		_settle(manager.world_state.get_agent(id))
	else:
		_pending_id = id
		_pending_until = now + 4000


## Following it now: its herd the session's focus, the whole herd followed for a herd's scene.
func _settle(agent) -> void:
	if agent == null:
		return
	if session != null and int(agent.group_id) >= 0 and manager.world_state.species_registry.social(agent.species_type) == "herd":
		session.focus = {"species": agent.species_type, "group_id": int(agent.group_id)}
	if str(scene.get("kind", "")) == "herd":
		manager.set_focus_mode("flock")


# --- Helpers ------------------------------------------------------------------------------------

## Where an animal asleep in a far sector lies, or null. The view's world under the worker has no
## sleeping records, only each sleeping group's (`dormant_aggregates`: its members' ids and where
## each lies); stepped inline, as in a test, the records themselves are there.
static func sleeping_position(world, agent_id: int):
	for sector in world._sector_states.values():
		for aggregate in sector.get("dormant_aggregates", []):
			var index: int = Array(aggregate.get("record_ids", [])).find(agent_id)
			if index >= 0 and index < aggregate.get("record_positions", PackedVector2Array()).size():
				return Vector2(aggregate["record_positions"][index])
		for record in sector.get("dormant_records", []):
			if int(record.get("id", -1)) == agent_id:
				return Vector2(record.get("position", Vector2.ZERO))
	return null


## How many views away a place is from the camera's centre.
func _views_away(position: Vector2) -> float:
	return camera.view_center().distance_to(position) / maxf(1.0, camera.view_span())


## Up to 2 off a scene's weight for being far: the near first, all else being equal.
func _distance_cost(position: Vector2) -> float:
	return clampf(_views_away(position) / 4.0, 0.0, 1.0) * 2.0


static func _smooth(k: float) -> float:
	var x := clampf(k, 0.0, 1.0)
	return x * x * (3.0 - 2.0 * x)


## A zoom between two, even to the eye: in proportion rather than in steps.
static func _zoom_between(a: float, b: float, k: float) -> float:
	return exp(lerpf(log(maxf(a, 0.0001)), log(maxf(b, 0.0001)), k))


func _ms(key: String) -> int:
	return int(float(settings.get(key, DEFAULTS.get(key, 0.0))) * 1000.0)


func _now() -> int:
	return int(clock.call())
