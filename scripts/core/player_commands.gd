class_name PlayerCommands
extends RefCounted

## The player's orders to the simulation: one shape for every power, from the click that gives
## one (`SimulationManager.enqueue_command()`) to the tick that carries it out
## (`WorldState._apply_player_commands()`) and the journal that keeps it (`PlayerState`).
##
##     {seq, type, params}
##
## `seq` numbers the orders of one session in the order they were given; `type` names the power
## (`powers.json`); `params` is the power's own, deep-copied when the order is given so nothing
## the view changes afterwards reaches the worker. An order is carried out at the start of the
## next tick the simulation runs - on a paused game, the first after it resumes.
##
## Why an order was refused, as the journal and the `PlayerCommand` event carry it.
const REFUSED_UNKNOWN := "unknown_power"
const REFUSED_NO_CHARGES := "no_charges"
const REFUSED_COOLING := "cooling_down"
const REFUSED_BAD_TARGET := "bad_target"


static func make(seq: int, type: String, params: Dictionary = {}) -> Dictionary:
	return {"seq": seq, "type": type, "params": params.duplicate(true)}


## A position an order names, as a `Vector2`: given as one, or as `{x, y}` or `[x, y]` by a
## script; `fallback` when it names none.
static func position_of(params: Dictionary, key: String = "position", fallback := Vector2.INF) -> Vector2:
	var value = params.get(key, null)
	if value is Vector2:
		return value
	if value is Dictionary and value.has("x") and value.has("y"):
		return Vector2(float(value["x"]), float(value["y"]))
	if value is Array and value.size() >= 2:
		return Vector2(float(value[0]), float(value[1]))
	return fallback
