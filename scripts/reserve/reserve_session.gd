class_name ReserveSession
extends RefCounted

## The living reserve's viewers acting on its world (`reserve.json`): a chat line in, an order to
## the world out (`SimulationManager.enqueue_command()`), what came of it told back. Kept apart
## from any window, so the same session runs beside a stream now and on a server later.
##
## - «!имя Ветка»: a ward (`adopt`) near the reserve's focus, one living each.
## - «!моё»: `focus_requested` with the viewer's living ward.
## - «!1», «!2»...: a vote (`VoteRound`); the winner is carried out at the close.
## - «!водопой», «!повести», «!отстрел»: the steward's powers, on the focus herd - a pond by it,
##   a walk to the best grass in reach, a cull of the foxes nearest it.
## - «!олени», «!лисы», «!волки»: backing a fund; every so often the fund with most active
##   members has its perk carried out.
##
## Per-viewer cooldowns, in simulated seconds, sit on top of each power's own (`powers.json`).
## `told` carries a line for the overlay: `{text, kind}`.

signal told(line: Dictionary)
signal focus_requested(agent_id: int)

const ViewerBookScript := preload("res://scripts/reserve/viewer_book.gd")
const VoteRoundScript := preload("res://scripts/reserve/vote_round.gd")
const ChatCommandsScript := preload("res://scripts/reserve/chat_commands.gd")
const HudTextScript := preload("res://scripts/ui/hud_text.gd")
const POWER_LABELS := {"dig_pond": "водопой", "lead_herd": "поход", "cull": "отстрел"}

var config: Dictionary = {}
var manager = null
var book = ViewerBookScript.new()
var vote = VoteRoundScript.new()
## The herd the reserve looks at, the target of the viewers' powers: `{species, group_id}`; when
## empty, or gone, the biggest herd of deer.
var focus: Dictionary = {}
var _teams_counted_at: float = -1.0
## Orders given and not yet answered: `{seq: {key, user, kind, label}}`.
var _pending: Dictionary = {}


func configure(new_manager, new_config: Dictionary) -> void:
	manager = new_manager
	config = new_config
	if not manager.world_event.is_connected(_on_world_event):
		manager.world_event.connect(_on_world_event)


func now() -> float:
	return float(manager.simulation_time)


## One chat line from the bridge: `{platform, user_id, user, text}`.
func hear(message: Dictionary) -> void:
	var viewer: Dictionary = book.meet(message, now())
	var key := ViewerBookScript.key_of(message)
	var user := str(viewer.get("name", "")) if str(viewer.get("name", "")) != "" else key
	var command: Dictionary = ChatCommandsScript.parse(str(message.get("text", "")), config)
	if command.is_empty():
		return
	match str(command["kind"]):
		"adopt":
			_adopt(key, user, str(command["arg"]))
		"mine":
			_show_mine(key, user)
		"vote":
			vote.cast(key, int(command["arg"]))
		"team":
			_join(key, user, str(command["arg"]))
		"dig_pond", "lead_herd", "cull":
			_steward(key, user, str(command["kind"]))


## Votes and funds as their times come; call once a tick, or a frame.
func tick() -> void:
	var won: Dictionary = vote.tick(now(), config)
	if not won.is_empty():
		_order(str(won.get("power", "")), won.get("params", {}), {"key": "", "user": "", "kind": "vote",
			"label": str(won.get("label", ""))})
	_count_teams()


func _adopt(key: String, user: String, raw_name: String) -> void:
	var wait: float = book.wait_for(key, "adopt", float(config.get("cooldowns", {}).get("adopt", 30.0)), now())
	if wait > 0.0:
		return
	var name := ChatCommandsScript.clean_name(raw_name, config)
	if name == "":
		_tell("%s, такое имя не подойдёт: только буквы, до %d" % [user, int(config.get("names", {}).get("max_length", 16))], "refused")
		return
	book.note(key, "adopt", now())
	var herd := focus_herd()
	var params := {"viewer": key, "name": name}
	if not herd.is_empty():
		params["position"] = herd["center"]
	_order("adopt", params, {"key": key, "user": user, "kind": "adopt"})


func _show_mine(key: String, user: String) -> void:
	for id in manager.world_state.adoptions.keys():
		var ward: Dictionary = manager.world_state.adoptions[id]
		if str(ward.get("viewer", "")) == key and float(ward.get("died_at", -1.0)) < 0.0:
			focus_requested.emit(int(id))
			_tell("%s: ваш подопечный — %s" % [user, str(ward.get("name", ""))], "mine")
			return
	_tell("%s, подопечного нет: «!имя Имя» возьмёт под опеку зверя" % user, "refused")


func _join(key: String, user: String, team: String) -> void:
	var funds: Dictionary = config.get("teams", {}).get("funds", {})
	if not funds.has(team):
		return
	if book.wait_for(key, "team", float(config.get("cooldowns", {}).get("team", 60.0)), now()) > 0.0:
		return
	book.note(key, "team", now())
	book.join(key, team)
	_tell("%s — в «%s»" % [user, str(funds[team].get("label", team))], "team")


func _steward(key: String, user: String, power: String) -> void:
	if book.wait_for(key, "power", float(config.get("cooldowns", {}).get("power", 180.0)), now()) > 0.0:
		return
	var herd := focus_herd()
	if herd.is_empty():
		return
	var params := _steward_target(power, herd)
	if params.is_empty():
		_tell("%s: %s сейчас некуда" % [user, POWER_LABELS.get(power, power)], "refused")
		return
	book.note(key, "power", now())
	_order(power, params, {"key": key, "user": user, "kind": power,
		"label": HudTextScript.herd_name(str(herd["species"]), int(herd["group_id"]))})


## Where a steward's power goes for the focus herd, as the order's params; {} when nowhere will do.
func _steward_target(power: String, herd: Dictionary) -> Dictionary:
	var world = manager.world_state
	var center: Vector2 = herd["center"]
	match power:
		"dig_pond":
			for ring in range(1, 10):
				for index in range(ring * 6):
					var spot: Vector2 = center + Vector2.from_angle(TAU * float(index) / float(ring * 6)) \
						* world.player_pond_radius() * 1.5 * float(ring)
					if world.dig_pond_refusal(spot) == "":
						return {"position": spot}
		"cull":
			var foxes: Array = world.cull_candidates(center, world.resource_system.world_size.length(),
				world.player.settings("cull").get("species", ["predator"]))
			if not foxes.is_empty():
				var nearest: Array = foxes[0]
				return {"position": nearest[2].position if nearest[2] != null else Vector2(nearest[4].get("position", center))}
		"lead_herd":
			var goal := _best_grass_in_reach(center)
			if goal.is_finite():
				return {"position": goal, "species": str(herd["species"]), "group_id": int(herd["group_id"])}
	return {}


## The point within the lead's reach, round the herd, with most grass near it that the herd can walk
## to; `Vector2.INF` when none.
func _best_grass_in_reach(center: Vector2) -> Vector2:
	var world = manager.world_state
	var settings: Dictionary = world.player.settings("lead_herd")
	var reach := float(settings.get("max_distance", 2400.0)) * 0.8
	var radius: float = world._pasture_radius("herbivore")
	var candidates: Array = []
	for ring in [0.5, 1.0]:
		for index in range(12):
			var goal: Vector2 = world.clamp_position(center + Vector2.from_angle(TAU * float(index) / 12.0) * reach * ring)
			if world.terrain_system.is_walkable_position(goal):
				candidates.append([world._forage_within(goal, radius), index + int(ring * 100.0), goal])
	candidates.sort_custom(func(a, b): return a[0] > b[0] or (a[0] == b[0] and a[1] < b[1]))
	var start: Vector2 = world.get_nearest_walkable_position(center)
	for candidate in candidates.slice(0, 4):
		var route: Dictionary = world.terrain_system.find_path(start, candidate[2])
		if bool(route.get("reachable", false)) and float(route.get("cost", INF)) <= float(settings.get("max_route", INF)):
			return candidate[2]
	return Vector2.INF


## The focus herd as `{species, group_id, center, count}`: the one set, while it has anyone, else
## the biggest herd of deer (the lower id on a tie); {} without any.
func focus_herd() -> Dictionary:
	var world = manager.world_state
	if not focus.is_empty():
		var located: Dictionary = HerdReadout.locate(world, str(focus.get("species", "")), int(focus.get("group_id", -1)))
		if int(located["count"]) > 0:
			return {"species": str(focus["species"]), "group_id": int(focus["group_id"]), "center": located["center"],
				"count": int(located["count"])}
	var census := {}
	for agent in world.get_living_agents():
		if agent != null and agent.is_alive and agent.species_type == "herbivore" and int(agent.group_id) >= 0:
			census[int(agent.group_id)] = int(census.get(int(agent.group_id), 0)) + 1
	for sector in world._sector_states.values():
		for record in sector.get("dormant_records", []):
			if str(record.get("species_type", "")) == "herbivore" and int(record.get("group_id", -1)) >= 0:
				census[int(record["group_id"])] = int(census.get(int(record["group_id"]), 0)) + 1
	var best := -1
	for group in census.keys():
		if best < 0 or int(census[group]) > int(census[best]) or (int(census[group]) == int(census[best]) and int(group) < best):
			best = int(group)
	if best < 0:
		return {}
	var where: Dictionary = HerdReadout.locate(world, "herbivore", best)
	return {"species": "herbivore", "group_id": best, "center": where["center"], "count": int(where["count"])}


## Every `teams.every_seconds` each fund counts its members active since the last count; the fund
## with most (at least `min_members`, the first in `funds` on a tie) has its perk carried out.
func _count_teams() -> void:
	var settings: Dictionary = config.get("teams", {})
	var every := float(settings.get("every_seconds", 300.0))
	if _teams_counted_at < 0.0:
		_teams_counted_at = now()
		return
	if now() < _teams_counted_at + every:
		return
	var counts: Dictionary = book.active_teams(_teams_counted_at)
	_teams_counted_at = now()
	var funds: Dictionary = settings.get("funds", {})
	var winner := ""
	for team in funds.keys():
		var members := int(counts.get(team, 0))
		if members >= int(settings.get("min_members", 1)) and (winner == "" or members > int(counts.get(winner, 0))):
			winner = str(team)
	if winner == "":
		return
	var perk: Dictionary = funds[winner].get("perk", {})
	_order(str(perk.get("power", "")), perk.get("params", {}), {"key": "", "user": "", "kind": "team",
		"label": str(funds[winner].get("label", winner)), "members": int(counts[winner])})


func _order(power: String, params: Dictionary, about: Dictionary) -> void:
	if power == "":
		return
	var seq: int = manager.enqueue_command(power, params)
	_pending[seq] = about


func _on_world_event(event: Dictionary) -> void:
	if str(event.get("type", "")) != "PlayerCommand":
		return
	var data: Dictionary = event.get("data", {})
	var seq := int(data.get("seq", -1))
	if not _pending.has(seq):
		return
	var about: Dictionary = _pending[seq]
	_pending.erase(seq)
	var ok := bool(data.get("ok", false))
	var user := str(about.get("user", ""))
	match str(about.get("kind", "")):
		"adopt":
			if ok:
				var noun: String = HudTextScript.animal_noun(str(data.get("species", "")), "")
				_tell("%s — опекун: %s %s" % [user, noun, str(data.get("name", ""))], "adopt")
			elif str(data.get("reason", "")) == PlayerCommands.REFUSED_HAS_WARD:
				_tell("%s, у вас уже есть подопечный — «!моё» покажет его" % user, "refused")
			else:
				_tell("%s, рядом нет зверя без опекуна" % user, "refused")
		"vote":
			_tell("Голосование: %s%s" % [str(about.get("label", "")), "" if ok else " — не вышло"], "vote")
		"team":
			_tell("%s: %s%s" % [str(about.get("label", "")), _perk_text(data), "" if ok else " — не вышло"], "team")
		_:
			var kind := str(about.get("kind", ""))
			_tell("%s: %s — %s%s" % [user, POWER_LABELS.get(kind, kind), str(about.get("label", "")), "" if ok else ", не вышло"], "power")


static func _perk_text(data: Dictionary) -> String:
	match str(data.get("power", "")):
		"bloom":
			return "буйная трава"
		"release":
			return "с края карты пришли новые звери"
	return str(data.get("power", ""))


func _tell(text: String, kind: String) -> void:
	told.emit({"text": text, "kind": kind, "time": now()})


func export_state() -> Dictionary:
	return {"book": book.export_state(), "vote": vote.export_state(), "focus": focus.duplicate(true),
		"teams_counted_at": _teams_counted_at}


func import_state(data: Dictionary) -> void:
	book.import_state(data.get("book", {}))
	vote.import_state(data.get("vote", {}))
	focus = data.get("focus", {}).duplicate(true)
	_teams_counted_at = float(data.get("teams_counted_at", -1.0))
