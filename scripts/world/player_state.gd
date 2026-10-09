class_name PlayerState
extends RefCounted

## What the player has done to a world and may still do (`PlayerCommands`): each power's
## charges and cooldown, and the journal of every order carried out or refused. It lives in the
## world the simulation steps, so a power is paid for in simulated time exactly when its order
## is carried out, two orders on one charge cannot both pass, and a headless run keeps the same
## budget as the game. It is saved with the world (`WorldState.export_state()`); the view's copy
## follows the worker's through `presentation_block()`, sent whenever `revision` moves.

const PlayerCommandsScript := preload("res://scripts/core/player_commands.gd")
## A power with no limit on its charges.
const UNLIMITED := -1

## Moves whenever what the view shows of the player changes: a charge or a cooldown spent.
var revision: int = 0
## Every order carried out or refused, oldest first: `{seq, tick, type, params, result}`.
var journal: Array = []
## Per power: `{charges, cooldown_until}`; `charges` is UNLIMITED for no limit.
var budget: Dictionary = {}
## The ponds the player dug, in the order dug: `{position, bank_radius, index}`. Not part of the
## map the seed makes, so a save and the view's copy add them back from here
## (`WorldState._restore_player_ponds()`).
var ponds: Array = []
var _powers: Dictionary = {}


## The powers as `powers.json` (or a scenario over it) gives them, all charges full.
func configure(powers_config: Dictionary) -> void:
	_powers = powers_config.get("powers", {}).duplicate(true)
	budget.clear()
	for power in _powers.keys():
		budget[str(power)] = {"charges": int(_powers[power].get("charges", UNLIMITED)), "cooldown_until": 0.0}
	journal.clear()
	ponds.clear()
	revision = 0


## A power's own settings, beside its charges and cooldown.
func settings(power: String) -> Dictionary:
	return _powers.get(power, {})


## Why `power` cannot be used at `now`, or "" when it can.
func refusal(power: String, now: float) -> String:
	if not budget.has(power):
		return PlayerCommandsScript.REFUSED_UNKNOWN
	var entry: Dictionary = budget[power]
	if int(entry.get("charges", UNLIMITED)) == 0:
		return PlayerCommandsScript.REFUSED_NO_CHARGES
	if now < float(entry.get("cooldown_until", 0.0)):
		return PlayerCommandsScript.REFUSED_COOLING
	return ""


## Pays for one use of `power` at `now`: a charge, if it counts them, and its cooldown.
func spend(power: String, now: float) -> void:
	var entry: Dictionary = budget[power]
	if int(entry.get("charges", UNLIMITED)) > 0:
		entry["charges"] = int(entry["charges"]) - 1
	entry["cooldown_until"] = now + float(settings(power).get("cooldown_seconds", 0.0))
	revision += 1


func add_pond(position: Vector2, bank_radius: float, index: int) -> void:
	ponds.append({"position": position, "bank_radius": bank_radius, "index": index})
	revision += 1


func record(command: Dictionary, tick: int, result: Dictionary) -> void:
	journal.append({"seq": int(command.get("seq", 0)), "tick": tick, "type": str(command.get("type", "")),
		"params": command.get("params", {}).duplicate(true), "result": result.duplicate(true)})


## What the view needs to draw the player's state, whole each time: it is small, and a frame
## that brings it twice must leave the view as one that brought it once.
func presentation_block() -> Dictionary:
	return {"revision": revision, "budget": budget.duplicate(true), "ponds": ponds.duplicate(true)}


func apply_presentation_block(block: Dictionary) -> void:
	revision = int(block.get("revision", revision))
	budget = block.get("budget", budget).duplicate(true)
	ponds = block.get("ponds", ponds).duplicate(true)


func export_state() -> Dictionary:
	return {"revision": revision, "journal": journal.duplicate(true), "budget": budget.duplicate(true),
		"ponds": ponds.duplicate(true)}


## A save from before the player had powers carries none of this: the charges stay as
## configured and the journal empty.
func import_state(data: Dictionary) -> void:
	if data.is_empty():
		return
	revision = int(data.get("revision", 0))
	journal = data.get("journal", []).duplicate(true)
	ponds = data.get("ponds", []).duplicate(true)
	var saved: Dictionary = data.get("budget", {})
	for power in saved.keys():
		budget[str(power)] = saved[power].duplicate(true)
