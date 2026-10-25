class_name ReserveDirector
extends RefCounted

## The living reserve's camera with no one at the controls (`reserve.json` `director`). Every
## `shot_seconds` of real time it turns to what is worth seeing and follows it:
## 1. an animal a viewer asked for («!моё», `ReserveSession.focus_requested`), for `asked_seconds`;
## 2. the weightiest moment of the last `moment_seconds` whose animal is still about - a kill, an
##    arrival, a hunt as a pair or a pack, an alarm, a territory taken, a birth;
## 3. by turns, each living ward and then the reserve's focus herd.
## The herd of what it follows becomes the session's focus, so the viewers' powers go where the
## stream looks. An animal asleep far off is reached by moving the camera there and selecting it
## once its sector wakes.

const WEIGHTS := {"PredationSuccess": 6, "Release": 5, "PairHunt": 5, "HerdAlarm": 4, "TerritoryClaimed": 3,
	"AgentBorn": 2, "adopt": 7}

var manager = null
var camera = null
var session = null
var settings: Dictionary = {}
## What it follows now, or -1.
var current_id: int = -1
var _until_msec: int = 0
var _asked: Array = []
var _moments: Array = []
var _ward_turn: int = 0
var _pending_id: int = -1
var _pending_until_msec: int = 0


func configure(new_manager, new_camera, new_session, config: Dictionary) -> void:
	manager = new_manager
	camera = new_camera
	session = new_session
	settings = config.get("director", {})
	if not manager.world_event.is_connected(_hear):
		manager.world_event.connect(_hear)
	if not session.focus_requested.is_connected(ask):
		session.focus_requested.connect(ask)


## Turn to `agent_id` at once.
func ask(agent_id: int) -> void:
	_asked.append(agent_id)
	_until_msec = 0


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
	if weight <= 0:
		return
	var at: Dictionary = event.get("position", {})
	var where := Vector2(float(at.get("x", 0.0)), float(at.get("y", 0.0)))
	if kind == "Release":
		where = Vector2(data.get("position", where))
	_moments.append({"weight": weight, "agent_id": agent_id, "species": str(data.get("species", event.get("species", ""))),
		"position": where, "at_msec": Time.get_ticks_msec()})
	if _moments.size() > 24:
		_moments = _moments.slice(_moments.size() - 24)


func update() -> void:
	if manager == null or manager.world_state == null:
		return
	var now := Time.get_ticks_msec()
	if _pending_id >= 0:
		if manager.select_agent_by_id(_pending_id, true):
			_follow_herd_of(manager.world_state.get_agent(_pending_id))
			_pending_id = -1
		elif now > _pending_until_msec:
			_pending_id = -1
			_until_msec = 0
	if current_id >= 0 and _pending_id < 0:
		var followed = manager.world_state.get_agent(current_id)
		if followed == null or not followed.is_alive:
			current_id = -1
			_until_msec = mini(_until_msec, now + 1500)
	if now < _until_msec:
		return
	_next_shot(now)


func _next_shot(now: int) -> void:
	while not _asked.is_empty():
		if _show(int(_asked.pop_front()), float(settings.get("asked_seconds", 15.0))):
			return
	var window := int(float(settings.get("moment_seconds", 20.0)) * 1000.0)
	var best := -1
	var best_id := -1
	for index in range(_moments.size()):
		var moment: Dictionary = _moments[index]
		if now - int(moment["at_msec"]) > window:
			continue
		var agent = manager.world_state.get_agent(int(moment["agent_id"])) if int(moment["agent_id"]) >= 0 \
			else _awake_near(moment["position"], str(moment["species"]))
		if agent == null or not agent.is_alive or agent.id == current_id:
			continue
		if best < 0 or int(moment["weight"]) >= int(_moments[best]["weight"]):
			best = index
			best_id = agent.id
	if best >= 0:
		_moments.remove_at(best)
		if _show(best_id, float(settings.get("shot_seconds", 25.0))):
			return
	var wards: Array = []
	for id in manager.world_state.adoptions.keys():
		if float(manager.world_state.adoptions[id].get("died_at", -1.0)) < 0.0:
			wards.append(int(id))
	wards.sort()
	_ward_turn += 1
	var turn := _ward_turn % (wards.size() + 1)
	if turn < wards.size() and _show(int(wards[turn]), float(settings.get("shot_seconds", 25.0))):
		return
	var herd: Dictionary = session.focus_herd()
	if herd.is_empty():
		_until_msec = now + 5000
		return
	var nearest = null
	for agent in manager.world_state.get_living_agents():
		if agent.is_alive and agent.species_type == str(herd["species"]) and int(agent.group_id) == int(herd["group_id"]) \
				and (nearest == null or agent.position.distance_squared_to(herd["center"]) < nearest.position.distance_squared_to(herd["center"])):
			nearest = agent
	if nearest != null:
		_show(nearest.id, float(settings.get("shot_seconds", 25.0)))
		manager.set_focus_mode("flock")
	else:
		current_id = -1
		camera.move_to_world_position(herd["center"])
		_until_msec = now + 3000


## Follows `agent_id` for `seconds`: selected at once if it is awake, else the camera goes where it
## sleeps and selects it when it wakes. False when it is nowhere.
func _show(agent_id: int, seconds: float) -> bool:
	if agent_id < 0:
		return false
	_until_msec = Time.get_ticks_msec() + int(seconds * 1000.0)
	current_id = agent_id
	if manager.select_agent_by_id(agent_id, true):
		_follow_herd_of(manager.world_state.get_agent(agent_id))
		return true
	for sector in manager.world_state._sector_states.values():
		for record in sector.get("dormant_records", []):
			if int(record.get("id", -1)) == agent_id:
				camera.move_to_world_position(Vector2(record.get("position", Vector2.ZERO)))
				_pending_id = agent_id
				_pending_until_msec = Time.get_ticks_msec() + 4000
				return true
	current_id = -1
	return false


## The awake animal of `species` (any, when "") nearest `position`, within 400 px; null when none.
func _awake_near(position: Vector2, species: String):
	var nearest = null
	for agent in manager.world_state.get_living_agents():
		if agent.is_alive and (species == "" or agent.species_type == species) and agent.position.distance_to(position) <= 400.0 \
				and (nearest == null or agent.position.distance_squared_to(position) < nearest.position.distance_squared_to(position)):
			nearest = agent
	return nearest


func _follow_herd_of(agent) -> void:
	if agent != null and int(agent.group_id) >= 0 and manager.world_state.species_registry.social(agent.species_type) == "herd":
		session.focus = {"species": agent.species_type, "group_id": int(agent.group_id)}
