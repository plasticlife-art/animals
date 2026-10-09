class_name PowerAim
extends RefCounted

## The power the player is aiming and where it may go: what «Водопой» and «Повести стадо» do
## between the button and the click, kept apart from the drawing (`PowerTargeting`) so it is
## tested without a scene. It asks the world the view is shown the questions the simulation will
## ask (`WorldState.dig_pond_refusal()`, the herd's reach, the route search), so a green mark is
## an order the simulation carries out - unless the world moved in the tick between.
##
## The herd led is the selected animal's, if it is one the player may lead
## (`WorldState.can_lead()`); with none selected, in a scenario, the biggest part of the
## player's own herd.

const HerdReadoutScript := preload("res://scripts/ui/herd_readout.gd")
const HudTextScript := preload("res://scripts/ui/hud_text.gd")
const POWERS := ["dig_pond", "lead_herd"]
const LABELS := {"dig_pond": "Водопой", "lead_herd": "Повести стадо"}
const KEYS := {"dig_pond": "Q", "lead_herd": "E"}
const REFUSALS := {
	"unknown_power": "Такой силы нет",
	"no_charges": "Эта сила кончилась",
	"cooling_down": "Ещё не готово",
	"bad_target": "Сюда нельзя",
	"off_map": "Слишком близко к краю карты",
	"blocked": "Туда не пройти",
	"too_close": "Слишком близко к другому пруду",
	"overgrown": "На берегу деревья или камни",
	"not_a_herd": "Это животное не ходит стадом",
	"no_herd": "Сначала выберите оленя",
	"too_far": "Слишком далеко для стада",
	"no_route": "Стадо не найдёт туда дороги",
}

## The power aimed, or "".
var power: String = ""
## What to tell the player beside the bar: how to aim, or why the last try would not do.
var message: String = ""
## The route last asked for, by its start and goal cells, and whether there was one: the search
## runs once per cell the pointer enters, not every frame.
var _route_cells := Vector2i(-1, -1)
var _route_found := false
var _route_cost := 0.0


func is_armed() -> bool:
	return power != ""


## Aims `power_id`, if it can be used now; otherwise says why and aims nothing.
func arm(manager, power_id: String) -> bool:
	cancel()
	var reason: String = manager.world_state.player.refusal(power_id, float(manager.simulation_time))
	if reason == "" and power_id == "lead_herd" and herd_to_lead(manager).is_empty():
		reason = "no_herd"
	if reason != "":
		message = refusal_text(reason)
		return false
	power = power_id
	if power_id == "lead_herd":
		var herd := herd_to_lead(manager)
		message = "Щёлкните, куда вести %s. Правая кнопка или Esc — отмена" \
			% HudTextScript.herd_name(str(herd["species"]), int(herd["group_id"]))
	else:
		message = "Щёлкните, где копать. Правая кнопка или Esc — отмена"
	return true


func cancel() -> void:
	power = ""
	message = ""
	_route_cells = Vector2i(-1, -1)


## What a click at `world_position` would do: `{kind, position, reason}` - `kind` "pond" with
## its `radius`, or "flag" with the herd's centre as `from`; `reason` is "" when the order would
## be carried out. {} with nothing aimed.
func preview(manager, world_position: Vector2) -> Dictionary:
	var world = manager.world_state
	match power:
		"dig_pond":
			return {"kind": "pond", "position": world_position, "radius": world.player_pond_radius(),
				"reason": world.dig_pond_refusal(world_position)}
		"lead_herd":
			var herd := herd_to_lead(manager)
			return {"kind": "flag", "position": world_position, "from": herd.get("center", Vector2.INF),
				"reason": _lead_refusal(manager, herd, world_position)}
	return {}


## Gives the order for a click at `world_position` and stops aiming: the order's number. -1 when
## the place will not do - the reason in `message`, still aiming.
func issue(manager, world_position: Vector2) -> int:
	var shown := preview(manager, world_position)
	if shown.is_empty():
		return -1
	if str(shown["reason"]) != "":
		message = refusal_text(str(shown["reason"]))
		return -1
	var params := {"position": world_position}
	if power == "lead_herd":
		var herd := herd_to_lead(manager)
		params["species"] = str(herd["species"])
		params["group_id"] = int(herd["group_id"])
	var seq: int = manager.enqueue_command(power, params)
	cancel()
	return seq


## The herd «Повести стадо» would lead: `{species, group_id, center}`, or {}.
static func herd_to_lead(manager) -> Dictionary:
	var world = manager.world_state
	if world == null:
		return {}
	var species := ""
	var group_id := -1
	var agent = manager.get_selected_agent()
	if agent != null and agent.is_alive and int(agent.group_id) >= 0 and world.can_lead(agent.species_type):
		species = agent.species_type
		group_id = int(agent.group_id)
	elif manager.scenario != null and manager.scenario.is_active() and world.can_lead(manager.scenario.species):
		species = manager.scenario.species
		var biggest := 0
		var ids: Array = manager.scenario.groups.keys()
		ids.sort()
		for candidate in ids:
			var members := int(HerdReadoutScript.locate(world, species, int(candidate))["count"])
			if members > biggest:
				biggest = members
				group_id = int(candidate)
	if group_id < 0:
		return {}
	var center: Vector2 = HerdReadoutScript.locate(world, species, group_id)["center"]
	if not center.is_finite():
		return {}
	return {"species": species, "group_id": group_id, "center": center}


static func refusal_text(reason: String) -> String:
	return str(REFUSALS.get(reason, "Сюда нельзя"))


func _lead_refusal(manager, herd: Dictionary, goal: Vector2) -> String:
	if herd.is_empty():
		return "no_herd"
	var world = manager.world_state
	if not world.bounds.has_point(goal):
		return "off_map"
	if not world.terrain_system.is_walkable_position(goal):
		return "blocked"
	var center: Vector2 = herd["center"]
	if center.distance_to(goal) > float(world.player.settings("lead_herd").get("max_distance", 2400.0)):
		return "too_far"
	var start: Vector2 = world.get_nearest_walkable_position(center)
	var cells := Vector2i(world.terrain_system.get_index_from_position(start), world.terrain_system.get_index_from_position(goal))
	if cells != _route_cells:
		_route_cells = cells
		var route: Dictionary = world.terrain_system.find_path(start, goal)
		_route_found = bool(route.get("reachable", false))
		_route_cost = float(route.get("cost", 0.0))
	if not _route_found:
		return "no_route"
	return "too_far" if _route_cost > float(world.player.settings("lead_herd").get("max_route", INF)) else ""
